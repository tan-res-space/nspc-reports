# DME Fulfillment: Match Rate and Latency Analysis

## Objective
Measure the percentage of EMA DME orders that successfully match to Data Warehouse claims, and analyze the time between order placement and claim generation.

## Business Questions
- What percentage of DME orders have corresponding claims within 0-90 days? 91-180 days?
- How long does it typically take from order to first claim?
- Which facilities or providers have the highest/lowest match rates?
- Are there patterns in unmatched orders that suggest systematic issues?

## Data Sources
- **EMA Staging**: `order_log`, `patient`, `facility` (DMEPOS orders, last 12-18 months)
- **Data Warehouse**: `Fact_FinancialTrans_Actual` + dimensions (DME-related claims)

## Analysis Steps

### Step 1: Extract EMA DME Orders
```sql
-- Create temporary table of DME orders with normalized identifiers
WITH ema_orders AS (
  SELECT 
    ol.order_number,
    ol.order_date,
    ol.provider_name,
    fac.facility_state,
    fac.name as facility_name,
    pat.mrn,
    UPPER(TRIM(REPLACE(REPLACE(pat.mrn, '-', ''), ' ', ''))) as mrn_normalized,
    pat.first_name + ' ' + pat.last_name as patient_name,
    (fac.facility_state + '_' + pat.mrn) as current_join_key
  FROM [Staging_EMA_NSPC].[dbo].[order_log] ol
  LEFT JOIN [Staging_EMA_NSPC].[dbo].[patient] pat ON ol.patient_id = pat.patient_id
  LEFT JOIN [Staging_EMA_NSPC].[dbo].[facility] fac ON ol.facility_id = fac.facility_id
  WHERE ol.order_type = 'DMEPOS'
    AND CONVERT(DATE, LEFT(ol.order_date, 10)) >= DATEADD(month, -18, GETDATE())
)
SELECT * FROM ema_orders;
```

### Step 2: Extract Relevant Claims
```sql
-- Create temporary table of DME claims with patient identifiers
WITH dw_claims AS (
  SELECT 
    f.ClaimID,
    dda.DateValue as service_date,
    dpat.PatientNumber,
    UPPER(TRIM(REPLACE(REPLACE(dpat.PatientNumber, '-', ''), ' ', ''))) as mrn_normalized,
    dl.FacilityAddress_State as facility_state,
    dl.Facility as facility_name,
    dpr.ProcedureCode,
    dss.SourceSystemName,
    (dl.FacilityAddress_State + '_' + dpat.PatientNumber) as current_join_key
  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
  LEFT JOIN [dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  LEFT JOIN [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [dbo].[Dim_Location] dl ON f.LocationKey_Service = dl.LocationKey
  LEFT JOIN [dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  LEFT JOIN [dbo].[Dim_SourceSystem] dss ON dpat.SourceSystemKey = dss.SourceSystemKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -18, GETDATE())
    AND ((dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
         OR dpr.ProcedureCode LIKE 'E%')
)
SELECT * FROM dw_claims;
```

### Step 3: Match Analysis - Current Method
```sql
-- Analyze matches using current join logic (facility_state + MRN)
WITH matched_current AS (
  SELECT 
    o.*,
    c.service_date,
    c.ProcedureCode,
    CASE 
      WHEN c.ClaimID IS NOT NULL THEN 1 
      ELSE 0 
    END as has_claim,
    CASE 
      WHEN c.service_date >= CONVERT(DATE, LEFT(o.order_date, 10)) THEN 1 
      ELSE 0 
    END as valid_timing,
    DATEDIFF(day, CONVERT(DATE, LEFT(o.order_date, 10)), c.service_date) as days_to_claim
  FROM ema_orders o
  LEFT JOIN dw_claims c ON o.current_join_key = c.current_join_key
    AND c.service_date >= CONVERT(DATE, LEFT(o.order_date, 10))
    AND c.service_date <= DATEADD(day, 180, CONVERT(DATE, LEFT(o.order_date, 10)))
)
SELECT 
  COUNT(*) as total_orders,
  SUM(has_claim) as matched_orders,
  ROUND(100.0 * SUM(has_claim) / COUNT(*), 2) as match_rate_pct,
  AVG(CASE WHEN has_claim = 1 THEN days_to_claim END) as avg_days_to_claim,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_claim) as median_days_to_claim,
  PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY days_to_claim) as p90_days_to_claim
FROM matched_current;
```

### Step 4: Match Analysis by Time Windows
```sql
-- Break down matches by different time windows
WITH windowed_matches AS (
  SELECT 
    o.*,
    c.service_date,
    DATEDIFF(day, CONVERT(DATE, LEFT(o.order_date, 10)), c.service_date) as days_to_claim,
    CASE 
      WHEN c.service_date IS NOT NULL 
           AND c.service_date >= CONVERT(DATE, LEFT(o.order_date, 10))
           AND DATEDIFF(day, CONVERT(DATE, LEFT(o.order_date, 10)), c.service_date) BETWEEN 0 AND 90
      THEN 1 ELSE 0 
    END as matched_0_90,
    CASE 
      WHEN c.service_date IS NOT NULL 
           AND c.service_date >= CONVERT(DATE, LEFT(o.order_date, 10))
           AND DATEDIFF(day, CONVERT(DATE, LEFT(o.order_date, 10)), c.service_date) BETWEEN 91 AND 180
      THEN 1 ELSE 0 
    END as matched_91_180,
    CASE 
      WHEN c.service_date IS NOT NULL 
           AND c.service_date < CONVERT(DATE, LEFT(o.order_date, 10))
      THEN 1 ELSE 0 
    END as claim_before_order
  FROM ema_orders o
  LEFT JOIN dw_claims c ON o.current_join_key = c.current_join_key
)
SELECT 
  COUNT(*) as total_orders,
  SUM(matched_0_90) as matched_0_90_days,
  SUM(matched_91_180) as matched_91_180_days,
  SUM(matched_0_90 + matched_91_180) as total_matched,
  SUM(claim_before_order) as claims_before_order,
  ROUND(100.0 * SUM(matched_0_90) / COUNT(*), 2) as match_rate_0_90_pct,
  ROUND(100.0 * SUM(matched_91_180) / COUNT(*), 2) as match_rate_91_180_pct,
  ROUND(100.0 * SUM(matched_0_90 + matched_91_180) / COUNT(*), 2) as total_match_rate_pct
FROM windowed_matches;
```

### Step 5: Facility-Level Analysis
```sql
-- Identify facilities with match rate issues
WITH facility_matches AS (
  SELECT 
    o.facility_state,
    o.facility_name,
    COUNT(*) as total_orders,
    SUM(CASE WHEN c.ClaimID IS NOT NULL THEN 1 ELSE 0 END) as matched_orders,
    ROUND(100.0 * SUM(CASE WHEN c.ClaimID IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*), 2) as match_rate_pct
  FROM ema_orders o
  LEFT JOIN dw_claims c ON o.current_join_key = c.current_join_key
    AND c.service_date >= CONVERT(DATE, LEFT(o.order_date, 10))
    AND c.service_date <= DATEADD(day, 180, CONVERT(DATE, LEFT(o.order_date, 10)))
  GROUP BY o.facility_state, o.facility_name
  HAVING COUNT(*) >= 10  -- Only facilities with meaningful volume
)
SELECT *
FROM facility_matches
ORDER BY match_rate_pct ASC, total_orders DESC;
```

## Expected Outputs

### Key Metrics
- **Overall Match Rate**: Percentage of orders with claims within 0-180 days
- **Time Window Breakdown**: 0-90 days vs 91-180 days match rates
- **Latency Distribution**: P50, P90, P95 days from order to first claim
- **Data Quality Flags**: Claims with service date before order date (should be 0)

### Business Insights
- Facilities with consistently low match rates (potential mapping issues)
- Seasonal patterns in order-to-claim timing
- Provider-level variations in fulfillment patterns
- Volume vs match rate correlations

### Red Flags to Investigate
- Match rates below 70% (industry benchmark varies, but this suggests systematic issues)
- High percentage of claims with service dates before order dates
- Significant facility-to-facility variation in match rates
- Unusual latency patterns (very fast or very slow claim generation)

## Recommended Actions Based on Results

### If Match Rate < 80%
- Investigate patient identifier normalization
- Review facility mapping accuracy
- Consider expanding claim lookback window

### If High Latency (P90 > 60 days)
- Analyze vendor performance and billing processes
- Review authorization and approval workflows
- Consider separate reporting for "pending" vs "unfilled" orders

### If Facility Variation > 20 percentage points
- Audit facility crosswalk mappings
- Review local billing and coding practices
- Investigate cross-state patient care patterns

## Next Steps
1. Run baseline analysis with current logic
2. Compare results with proposed improved matching logic
3. Identify top 10 facilities for detailed mapping review
4. Present findings to operations and revenue cycle teams
5. Establish ongoing monitoring cadence (monthly/quarterly)
