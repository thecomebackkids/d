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
