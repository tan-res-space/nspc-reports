# DME Fulfillment: Facility Mapping Audit

## Objective
Identify and quantify facility mapping issues between EMA staging and Data Warehouse that may be causing DME orders to not match with their corresponding claims.

## Business Questions
- Which facilities have the highest rates of unmatched DME orders?
- Are facility name inconsistencies causing systematic matching failures?
- What is the impact of the commented-out facility join that "drops ~10% of records"?
- How can we create a reliable facility crosswalk for improved matching?

## Background
The current view includes this commented line:
```sql
-- INNER JOIN [DataWarehouse].[dbo].[Dim_Location] dl ON fac.[name] = dl.facility --Drops ~10% of recs
```

This suggests facility mapping challenges that need investigation.

## Analysis Steps

### Step 1: EMA Facility Inventory
```sql
-- Catalog all facilities in EMA with DME order activity
WITH ema_facilities AS (
  SELECT 
    fac.facility_id,
    fac.name as ema_facility_name,
    fac.facility_state,
    fac.address1,
    fac.city,
    fac.zip_code,
    COUNT(DISTINCT ol.order_number) as dme_order_count,
    COUNT(DISTINCT ol.patient_id) as unique_patients,
    MIN(ol.order_date) as earliest_order,
    MAX(ol.order_date) as latest_order
  FROM [Staging_EMA_NSPC].[dbo].[facility] fac
  LEFT JOIN [Staging_EMA_NSPC].[dbo].[order_log] ol ON fac.facility_id = ol.facility_id
  WHERE ol.order_type = 'DMEPOS'
    AND CONVERT(DATE, LEFT(ol.order_date, 10)) >= DATEADD(month, -12, GETDATE())
  GROUP BY fac.facility_id, fac.name, fac.facility_state, fac.address1, fac.city, fac.zip_code
)
SELECT *
FROM ema_facilities
ORDER BY dme_order_count DESC;
```

### Step 2: Data Warehouse Facility Inventory
```sql
-- Catalog facilities in Data Warehouse with DME claim activity
WITH dw_facilities AS (
  SELECT 
    dl.LocationKey,
    dl.Facility as dw_facility_name,
    dl.FacilityAddress_State,
    dl.FacilityAddress_City,
    dl.FacilityAddress_Zip,
    dl.Region_Operations,
    COUNT(DISTINCT f.ClaimID) as dme_claim_count,
    COUNT(DISTINCT dpat.PatientNumber) as unique_patients,
    MIN(dda.DateValue) as earliest_claim,
    MAX(dda.DateValue) as latest_claim
  FROM [DataWarehouse].[dbo].[Dim_Location] dl
  LEFT JOIN [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f ON dl.LocationKey = f.LocationKey_Service
  LEFT JOIN [DataWarehouse].[dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [DataWarehouse].[dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  LEFT JOIN [DataWarehouse].[dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -12, GETDATE())
    AND ((dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
         OR dpr.ProcedureCode LIKE 'E%')
  GROUP BY dl.LocationKey, dl.Facility, dl.FacilityAddress_State, dl.FacilityAddress_City, 
           dl.FacilityAddress_Zip, dl.Region_Operations
)
SELECT *
FROM dw_facilities
ORDER BY dme_claim_count DESC;
```

### Step 3: Facility Name Matching Analysis
```sql
-- Attempt various matching strategies to identify mapping opportunities
WITH facility_matching AS (
  SELECT 
    e.ema_facility_name,
    e.facility_state as ema_state,
    e.dme_order_count,
    d.dw_facility_name,
    d.FacilityAddress_State as dw_state,
    d.dme_claim_count,
    -- Exact match
    CASE WHEN e.name = d.Facility THEN 1 ELSE 0 END as exact_match,
    -- Case-insensitive match
    CASE WHEN UPPER(e.name) = UPPER(d.Facility) THEN 1 ELSE 0 END as case_insensitive_match,
    -- Trimmed match (remove extra spaces)
    CASE WHEN LTRIM(RTRIM(UPPER(e.name))) = LTRIM(RTRIM(UPPER(d.Facility))) THEN 1 ELSE 0 END as trimmed_match,
    -- Partial match (contains)
    CASE WHEN UPPER(e.name) LIKE '%' + UPPER(d.Facility) + '%' 
              OR UPPER(d.Facility) LIKE '%' + UPPER(e.name) + '%' THEN 1 ELSE 0 END as partial_match,
    -- State consistency
    CASE WHEN e.facility_state = d.FacilityAddress_State THEN 1 ELSE 0 END as state_match
  FROM (
    SELECT DISTINCT name, facility_state, dme_order_count
    FROM ema_facilities
  ) e
  FULL OUTER JOIN (
    SELECT DISTINCT Facility, FacilityAddress_State, dme_claim_count
    FROM dw_facilities
  ) d ON 1=1  -- Cross join to evaluate all combinations
  WHERE e.name IS NOT NULL OR d.Facility IS NOT NULL
)
SELECT 
  COUNT(*) as total_combinations,
  SUM(exact_match) as exact_matches,
  SUM(case_insensitive_match) as case_insensitive_matches,
  SUM(trimmed_match) as trimmed_matches,
  SUM(partial_match) as partial_matches,
  SUM(CASE WHEN exact_match = 1 AND state_match = 1 THEN 1 ELSE 0 END) as exact_with_state,
  SUM(CASE WHEN trimmed_match = 1 AND state_match = 1 THEN 1 ELSE 0 END) as trimmed_with_state
FROM facility_matching;
```

### Step 4: Unmatched Facility Analysis
```sql
-- Identify EMA facilities with no apparent DW counterpart
WITH unmatched_ema_facilities AS (
  SELECT 
    e.ema_facility_name,
    e.facility_state,
    e.dme_order_count,
    e.unique_patients,
    -- Look for potential matches in DW
    (SELECT TOP 1 d.dw_facility_name 
     FROM dw_facilities d 
     WHERE d.FacilityAddress_State = e.facility_state
       AND (UPPER(d.dw_facility_name) LIKE '%' + UPPER(e.ema_facility_name) + '%'
            OR UPPER(e.ema_facility_name) LIKE '%' + UPPER(d.dw_facility_name) + '%')
     ORDER BY d.dme_claim_count DESC) as potential_dw_match,
    -- Calculate impact
    ROUND(100.0 * e.dme_order_count / SUM(e.dme_order_count) OVER(), 2) as pct_of_total_orders
  FROM ema_facilities e
  WHERE NOT EXISTS (
    SELECT 1 FROM dw_facilities d 
    WHERE LTRIM(RTRIM(UPPER(e.ema_facility_name))) = LTRIM(RTRIM(UPPER(d.dw_facility_name)))
      AND e.facility_state = d.FacilityAddress_State
  )
)
SELECT *
FROM unmatched_ema_facilities
ORDER BY dme_order_count DESC;
```

### Step 5: Impact of Facility Join Enforcement
```sql
-- Simulate the impact of enforcing facility mapping (the commented INNER JOIN)
WITH order_claim_matches AS (
  SELECT 
    ol.order_number,
    ol.order_date,
    fac.name as ema_facility_name,
    fac.facility_state,
    pat.mrn,
    -- Current join key
    (fac.facility_state + '_' + pat.mrn) as join_key,
    -- Check if facility has DW counterpart
    CASE WHEN EXISTS (
      SELECT 1 FROM [DataWarehouse].[dbo].[Dim_Location] dl 
      WHERE LTRIM(RTRIM(UPPER(fac.name))) = LTRIM(RTRIM(UPPER(dl.Facility)))
    ) THEN 1 ELSE 0 END as has_facility_mapping,
    -- Check if order has matching claim
    CASE WHEN EXISTS (
      SELECT 1 FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
      LEFT JOIN [DataWarehouse].[dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
      LEFT JOIN [DataWarehouse].[dbo].[Dim_Location] dl ON f.LocationKey_Service = dl.LocationKey
      LEFT JOIN [DataWarehouse].[dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
      LEFT JOIN [DataWarehouse].[dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
      WHERE (dl.FacilityAddress_State + '_' + dpat.PatientNumber) = (fac.facility_state + '_' + pat.mrn)
        AND dda.DateValue >= CONVERT(DATE, LEFT(ol.order_date, 10))
        AND ((dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
             OR dpr.ProcedureCode LIKE 'E%')
    ) THEN 1 ELSE 0 END as has_matching_claim
  FROM [Staging_EMA_NSPC].[dbo].[order_log] ol
  LEFT JOIN [Staging_EMA_NSPC].[dbo].[patient] pat ON ol.patient_id = pat.patient_id
  LEFT JOIN [Staging_EMA_NSPC].[dbo].[facility] fac ON ol.facility_id = fac.facility_id
  WHERE ol.order_type = 'DMEPOS'
    AND CONVERT(DATE, LEFT(ol.order_date, 10)) >= DATEADD(month, -12, GETDATE())
)
SELECT 
  COUNT(*) as total_orders,
  SUM(has_facility_mapping) as orders_with_facility_mapping,
  SUM(has_matching_claim) as orders_with_matching_claims,
  SUM(CASE WHEN has_facility_mapping = 1 AND has_matching_claim = 1 THEN 1 ELSE 0 END) as mapped_orders_with_claims,
  -- Current approach (no facility mapping requirement)
  ROUND(100.0 * SUM(has_matching_claim) / COUNT(*), 2) as current_match_rate_pct,
  -- With facility mapping enforcement
  ROUND(100.0 * SUM(CASE WHEN has_facility_mapping = 1 AND has_matching_claim = 1 THEN 1 ELSE 0 END) / 
        SUM(has_facility_mapping), 2) as enforced_mapping_match_rate_pct,
  -- Impact of enforcement
  ROUND(100.0 * (COUNT(*) - SUM(has_facility_mapping)) / COUNT(*), 2) as pct_orders_dropped_by_enforcement
FROM order_claim_matches;
```

### Step 6: Proposed Facility Crosswalk
```sql
-- Create a proposed facility crosswalk based on analysis
WITH facility_crosswalk_proposal AS (
  SELECT 
    e.facility_id as ema_facility_id,
    e.ema_facility_name,
    e.facility_state as ema_state,
    e.dme_order_count,
    d.LocationKey as dw_location_key,
    d.dw_facility_name,
    d.FacilityAddress_State as dw_state,
    d.dme_claim_count,
    -- Confidence score for the mapping
    CASE 
      WHEN LTRIM(RTRIM(UPPER(e.ema_facility_name))) = LTRIM(RTRIM(UPPER(d.dw_facility_name)))
           AND e.facility_state = d.FacilityAddress_State THEN 'High'
      WHEN UPPER(e.ema_facility_name) LIKE '%' + UPPER(d.dw_facility_name) + '%'
           AND e.facility_state = d.FacilityAddress_State THEN 'Medium'
      WHEN UPPER(d.dw_facility_name) LIKE '%' + UPPER(e.ema_facility_name) + '%'
           AND e.facility_state = d.FacilityAddress_State THEN 'Medium'
      ELSE 'Low'
    END as mapping_confidence,
    -- Business impact
    LEAST(e.dme_order_count, d.dme_claim_count) as potential_matches
  FROM ema_facilities e
  LEFT JOIN dw_facilities d ON (
    -- Try multiple matching strategies
    (LTRIM(RTRIM(UPPER(e.ema_facility_name))) = LTRIM(RTRIM(UPPER(d.dw_facility_name)))
     AND e.facility_state = d.FacilityAddress_State)
    OR
    (UPPER(e.ema_facility_name) LIKE '%' + UPPER(d.dw_facility_name) + '%'
     AND e.facility_state = d.FacilityAddress_State)
    OR
    (UPPER(d.dw_facility_name) LIKE '%' + UPPER(e.ema_facility_name) + '%'
     AND e.facility_state = d.FacilityAddress_State)
  )
  WHERE d.LocationKey IS NOT NULL
)
SELECT *
FROM facility_crosswalk_proposal
ORDER BY mapping_confidence DESC, potential_matches DESC;
```

## Expected Outputs

### Key Metrics
- **Facility Coverage**: Percentage of EMA facilities with DW counterparts
- **Order Impact**: Percentage of orders affected by facility mapping issues
- **Match Quality**: Distribution of mapping confidence levels
- **Business Impact**: Volume of orders/claims affected by mapping gaps

### Deliverables
- **Exception Report**: EMA facilities with no DW mapping
- **Crosswalk Table**: Proposed facility mappings with confidence scores
- **Impact Analysis**: Quantified effect of enforcing facility mapping
- **Remediation Plan**: Prioritized list of mapping fixes

## Business Impact Assessment

### High-Impact Unmapped Facilities
- Facilities with >100 DME orders but no DW counterpart
- Facilities representing >5% of total DME order volume
- Facilities with recent activity but missing from DW

### Medium-Impact Mapping Issues
- Facilities with partial name matches requiring manual review
- Facilities with state mismatches (potential data quality issues)
- Facilities with low confidence mappings

### Low-Impact Items
- Facilities with <10 orders per year
- Inactive facilities with only historical data
- Facilities with clear non-DME focus

## Recommended Actions

### Immediate (Next 30 Days)
1. **Create Facility Crosswalk Table**: Implement high-confidence mappings
2. **Manual Review Process**: Establish workflow for medium-confidence mappings
3. **Exception Handling**: Define process for unmapped facilities

### Short-term (30-90 Days)
1. **Data Governance**: Establish facility master data management
2. **Automated Matching**: Implement fuzzy matching algorithms for ongoing maintenance
3. **Quality Monitoring**: Create alerts for new unmapped facilities

### Long-term (90+ Days)
1. **System Integration**: Improve facility identifier consistency across systems
2. **Master Data Management**: Implement enterprise facility registry
3. **Ongoing Maintenance**: Establish quarterly crosswalk review process

## Success Metrics
- **Coverage Target**: 95%+ of DME orders from mapped facilities
- **Quality Target**: 90%+ high-confidence mappings
- **Impact Target**: <2% order volume lost to mapping issues
- **Maintenance Target**: New facilities mapped within 30 days of first activity

## Next Steps
1. **Stakeholder Review**: Present findings to data governance and operations teams
2. **Pilot Implementation**: Test crosswalk with subset of high-volume facilities
3. **Impact Validation**: Measure improvement in match rates with crosswalk
4. **Full Deployment**: Roll out complete facility crosswalk solution
5. **Ongoing Monitoring**: Establish regular crosswalk maintenance and quality checks
