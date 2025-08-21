CREATE OR ALTER PROCEDURE dbo.Build_Rollups @PeriodKey int AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  DECLARE @PeriodDate date = DATEFROMPARTS(@PeriodKey / 100, @PeriodKey % 100, 1);

  ;WITH ActiveVersion AS (
    SELECT civ.complianceitemid
    FROM dbo.ComplianceItemVersions civ
    JOIN dbo.ComplianceItems ci ON ci.complianceitemid = civ.complianceitemid
    WHERE ci.active = 1 AND civ.active = 1
      AND civ.effectivestartdate <= @PeriodDate
      AND (civ.effectiveenddate IS NULL OR @PeriodDate < civ.effectiveenddate)
    GROUP BY civ.complianceitemid
  ),
  ActiveMetrics AS (
    SELECT complianceitemid FROM ActiveVersion
  ),
  Roster AS (
    SELECT DISTINCT rp.person_id
    FROM dbo.Roster_Period rp
    WHERE rp.period_key = @PeriodKey
  ),
  PersonMap AS (
    SELECT r.person_id, po.mpo_id, po.area_id, po.region_id
    FROM Roster r
    JOIN dbo.PersonOrg po ON po.person_id = r.person_id
  ),
  FactAgg AS (
    SELECT
      ss.person_id,
      ss.complianceitemid,
      SUM(ss.weighted_points) AS sum_wp,
      SUM(ss.weight_basis)    AS sum_w
    FROM dbo.ScoreSnapshot ss
    WHERE ss.period_key = @PeriodKey
    GROUP BY ss.person_id, ss.complianceitemid
  )

  /* ========== MPO level ========== */
  DELETE FROM dbo.Agg_MPO_Metric WHERE period_key = @PeriodKey;

  INSERT dbo.Agg_MPO_Metric (period_key, mpo_id, complianceitemid, sum_weighted_pts, total_weight)
  SELECT
    @PeriodKey,
    pm.mpo_id,
    am.complianceitemid,
    SUM(ISNULL(fa.sum_wp, 0.0)) AS sum_weighted_pts,
    SUM(ISNULL(fa.sum_w,  0.0)) AS total_weight
  FROM PersonMap pm
  CROSS JOIN ActiveMetrics am
  LEFT JOIN FactAgg fa
    ON fa.person_id = pm.person_id
   AND fa.complianceitemid = am.complianceitemid
  GROUP BY pm.mpo_id, am.complianceitemid;

  /* ========== Area level ========== */
  DELETE FROM dbo.Agg_Area_Metric WHERE period_key = @PeriodKey;

  INSERT dbo.Agg_Area_Metric (period_key, area_id, complianceitemid, sum_weighted_pts, total_weight)
  SELECT
    @PeriodKey,
    pm.area_id,
    am.complianceitemid,
    SUM(ISNULL(fa.sum_wp, 0.0)),
    SUM(ISNULL(fa.sum_w,  0.0))
  FROM PersonMap pm
  CROSS JOIN ActiveMetrics am
  LEFT JOIN FactAgg fa
    ON fa.person_id = pm.person_id
   AND fa.complianceitemid = am.complianceitemid
  GROUP BY pm.area_id, am.complianceitemid;

  /* ========== Region level ========== */
  DELETE FROM dbo.Agg_Region_Metric WHERE period_key = @PeriodKey;

  INSERT dbo.Agg_Region_Metric (period_key, region_id, complianceitemid, sum_weighted_pts, total_weight)
  SELECT
    @PeriodKey,
    pm.region_id,
    am.complianceitemid,
    SUM(ISNULL(fa.sum_wp, 0.0)),
    SUM(ISNULL(fa.sum_w,  0.0))
  FROM PersonMap pm
  CROSS JOIN ActiveMetrics am
  LEFT JOIN FactAgg fa
    ON fa.person_id = pm.person_id
   AND fa.complianceitemid = am.complianceitemid
  GROUP BY pm.region_id, am.complianceitemid;
END
GO



-- Run once per database
IF TYPE_ID('dbo.PersonRosterTVP') IS NULL
    CREATE TYPE dbo.PersonRosterTVP AS TABLE (
        person_id int NOT NULL PRIMARY KEY
    );
GO



CREATE OR ALTER PROCEDURE dbo.Recompute_Scores
  @PeriodKey int,                                  -- e.g., 202508
  @Roster    dbo.PersonRosterTVP READONLY = NULL   -- optional: pass MLOs in scope
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @PeriodDate date = DATEFROMPARTS(@PeriodKey / 100, @PeriodKey % 100, 1);

  BEGIN TRAN;

  /* -------- Active metric versions for the period -------- */
  ;WITH ActiveVersion AS (
    SELECT
      civ.complianceitemversionid,
      civ.complianceitemid,
      CAST(civ.weight AS decimal(18,6))        AS weight,
      CAST(civ.escalatorrate AS decimal(18,6)) AS escalatorrate,
      CAST(ISNULL(civ.escalatorpenaltycappct,1.0) AS decimal(18,6)) AS escalatorpenaltycappct
    FROM dbo.ComplianceItemVersions civ
    JOIN dbo.ComplianceItems ci ON ci.complianceitemid = civ.complianceitemid
    WHERE ci.active = 1
      AND civ.active = 1
      AND civ.effectivestartdate <= @PeriodDate
      AND (@PeriodDate < ISNULL(civ.effectiveenddate, '9999-12-31'))
  ),
  WeightDenominator AS (
    SELECT SUM(weight) AS total_weight FROM ActiveVersion
  ),
  NormalizedPoints AS (
    SELECT
      av.complianceitemid,
      av.complianceitemversionid,
      CAST(CASE WHEN wd.total_weight > 0 THEN 100.0 * av.weight / wd.total_weight ELSE 0 END AS decimal(18,6)) AS norm_points,
      av.escalatorrate,
      av.escalatorpenaltycappct
    FROM ActiveVersion av
    CROSS JOIN WeightDenominator wd
  ),

  /* -------- People in scope for the period (roster-aware) -------- */
  PersonInScope AS (
    SELECT DISTINCT person_id, @PeriodKey AS period_key
    FROM (
      -- If a roster is provided, use it
      SELECT r.person_id FROM @Roster r
      UNION ALL
      -- Always include anyone with any evaluation this month (safety net if roster is empty)
      SELECT me.mlo_id FROM dbo.MetricEvaluations me WHERE me.period_key = @PeriodKey
    ) u
  ),

  /* -------- Force Person × ActiveMetric combos -------- */
  AllCombos AS (
    SELECT
      pis.person_id,
      np.complianceitemid,
      pis.period_key,
      np.complianceitemversionid,
      np.norm_points,
      np.escalatorrate,
      np.escalatorpenaltycappct
    FROM PersonInScope pis
    CROSS JOIN NormalizedPoints np
  ),

  /* -------- Attempts / failures / daysover for period -------- */
  Attempts AS (
    SELECT
      me.mlo_id                AS person_id,
      me.complianceitemid,
      me.period_key,
      COUNT_BIG(*)             AS attempts,
      SUM(CASE
            WHEN (TRY_CONVERT(int, me.outcome) = 1)
              OR (UPPER(LTRIM(RTRIM(CONVERT(nvarchar(50), me.outcome)))) IN (N'FAIL', N'FAILURE'))
            THEN 1 ELSE 0 END) AS failures,
      SUM(CAST(ISNULL(me.daysover,0) AS bigint)) AS total_daysover
    FROM dbo.MetricEvaluations me
    WHERE me.period_key = @PeriodKey
    GROUP BY me.mlo_id, me.complianceitemid, me.period_key
  ),

  /* -------- Score math (zero-attempt handling baked in) -------- */
  Calc AS (
    SELECT
      ac.person_id,
      ac.complianceitemid,
      ac.period_key,
      ac.complianceitemversionid,
      ac.norm_points,
      ISNULL(a.attempts,0)      AS attempts,
      ISNULL(a.failures,0)      AS failures,
      ISNULL(a.total_daysover,0)AS total_daysover,

      CAST( CASE WHEN ISNULL(a.attempts,0)=0
                 THEN 0.0
                 ELSE a.failures * 1.0 / NULLIF(a.attempts,0) END AS decimal(18,6) ) AS failure_rate,

      CAST( CASE WHEN ISNULL(a.attempts,0)=0
                 THEN ac.norm_points
                 ELSE ac.norm_points * (1.0 - (a.failures * 1.0 / NULLIF(a.attempts,0))) END AS decimal(18,6) ) AS base_score,

      CAST( CASE WHEN ISNULL(a.attempts,0)=0
                 THEN 0.0
                 ELSE ac.norm_points * ISNULL(ac.escalatorrate,0) * ISNULL(a.total_daysover,0) END AS decimal(19,6) ) AS escalator_penalty_raw,

      CAST( ac.norm_points * ISNULL(ac.escalatorpenaltycappct,1.0) AS decimal(19,6) ) AS escalator_penalty_cap
    FROM AllCombos ac
    LEFT JOIN Attempts a
      ON a.person_id = ac.person_id
     AND a.complianceitemid = ac.complianceitemid
     AND a.period_key = ac.period_key
  ),

  Final AS (
    SELECT
      person_id,
      complianceitemid,
      period_key,
      complianceitemversionid,

      -- penalty = min(raw, cap)
      CAST( CASE WHEN escalator_penalty_raw < escalator_penalty_cap
                 THEN escalator_penalty_raw ELSE escalator_penalty_cap END AS decimal(19,6) ) AS penalties,

      -- final = max(0, base - penalty)
      CAST( CASE
              WHEN base_score - CASE WHEN escalator_penalty_raw < escalator_penalty_cap
                                     THEN escalator_penalty_raw ELSE escalator_penalty_cap END < 0
              THEN 0
              ELSE base_score - CASE WHEN escalator_penalty_raw < escalator_penalty_cap
                                     THEN escalator_penalty_raw ELSE escalator_penalty_cap END
            END AS decimal(18,6) ) AS final_score,

      CAST(base_score AS decimal(18,6)) AS raw_points,
      CAST(ISNULL(NULLIF(attempts,0),0) AS decimal(18,6)) AS weight_basis
    FROM Calc
  )

  MERGE dbo.ScoreSnapshot AS tgt
  USING (
    SELECT
      f.person_id,
      f.complianceitemid,
      f.period_key,
      f.raw_points,
      f.penalties,
      f.final_score,
      f.weight_basis,
      CAST(f.final_score * f.weight_basis AS decimal(19,6)) AS weighted_points,
      f.complianceitemversionid
    FROM Final f
  ) AS src
  ON  tgt.person_id        = src.person_id
  AND tgt.complianceitemid = src.complianceitemid
  AND tgt.period_key       = src.period_key
  WHEN MATCHED AND tgt.locked_bit = 0 THEN
    UPDATE SET
      raw_points              = src.raw_points,
      penalties               = src.penalties,
      final_score             = src.final_score,
      weight_basis            = src.weight_basis,
      weighted_points         = src.weighted_points,
      complianceitemversionid = src.complianceitemversionid,
      calc_utc                = SYSUTCDATETIME(),
      source_run_id           = NEWID()
  WHEN NOT MATCHED THEN
    INSERT (person_id, complianceitemid, period_key,
            raw_points, penalties, final_score,
            weight_basis, weighted_points,
            complianceitemversionid, calc_utc, locked_bit, source_run_id)
    VALUES (src.person_id, src.complianceitemid, src.period_key,
            src.raw_points, src.penalties, src.final_score,
            src.weight_basis, src.weighted_points,
            src.complianceitemversionid, SYSUTCDATETIME(), 0, NEWID());

  COMMIT;
END
GO


DECLARE @PeriodKey int = 202508;

-- Build a roster TVP from your Roster_Period table
DECLARE @Roster dbo.PersonRosterTVP;
INSERT INTO @Roster(person_id)
SELECT DISTINCT person_id
FROM dbo.Roster_Period
WHERE period_key = @PeriodKey;

-- Run the scorer for the month with the roster applied
EXEC dbo.Recompute_Scores
  @PeriodKey = @PeriodKey,
  @Roster    = @Roster;

