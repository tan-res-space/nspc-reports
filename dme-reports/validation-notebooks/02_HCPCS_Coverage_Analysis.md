# DME Fulfillment: HCPCS Code Coverage Analysis

## Objective
Identify DME-related procedure codes that are currently excluded from fulfillment reporting but may represent legitimate DME fulfillment activities.

## Business Questions
- What DME-related HCPCS codes are we missing with the current E*/L* filter?
- How frequently do A-codes and K-codes appear in DME-related claims?
- What is the potential impact of expanding the code set on fulfillment rates?
- Which specific codes should be added to the governed DME reference list?

## Current Filter Logic
```sql
-- Current DME HCPCS filter in vwRPT_OPS_DME_Details_2
WHERE ((dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
       OR (dpr.ProcedureCode LIKE 'E%'))
```

## Analysis Steps

### Step 1: Identify All Potential DME-Related Claims
```sql
-- Find claims that might be DME-related based on various indicators
WITH potential_dme_claims AS (
  SELECT 
    dpr.ProcedureCode,
    dpr.ProcedureDescription,
    COUNT(*) as claim_count,
    COUNT(DISTINCT dpat.PatientNumber) as unique_patients,
    COUNT(DISTINCT dl.Facility) as unique_facilities,
    MIN(dda.DateValue) as earliest_service_date,
    MAX(dda.DateValue) as latest_service_date,
    -- Categorize by code prefix
    CASE 
      WHEN dpr.ProcedureCode LIKE 'A%' THEN 'A-Codes (Medical/Surgical Supplies)'
      WHEN dpr.ProcedureCode LIKE 'E%' THEN 'E-Codes (DME Equipment)'
      WHEN dpr.ProcedureCode LIKE 'K%' THEN 'K-Codes (Temporary Codes)'
      WHEN dpr.ProcedureCode LIKE 'L%' THEN 'L-Codes (Prosthetics/Orthotics)'
      WHEN dpr.ProcedureCode LIKE 'B%' THEN 'B-Codes (Enteral/Parenteral)'
      ELSE 'Other'
    END as code_category,
    -- Flag if currently included
    CASE 
      WHEN (dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
           OR dpr.ProcedureCode LIKE 'E%'
      THEN 1 ELSE 0 
    END as currently_included
  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
  LEFT JOIN [dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  LEFT JOIN [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [dbo].[Dim_Location] dl ON f.LocationKey_Service = dl.LocationKey
  LEFT JOIN [dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -12, GETDATE())
    AND (
      -- Current DME codes
      (dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
      OR dpr.ProcedureCode LIKE 'E%'
      -- Potential additional DME codes
      OR dpr.ProcedureCode LIKE 'A%'  -- Medical/surgical supplies
      OR dpr.ProcedureCode LIKE 'K%'  -- Temporary codes (often wheelchairs)
      OR dpr.ProcedureCode LIKE 'B%'  -- Enteral/parenteral therapy
    )
  GROUP BY dpr.ProcedureCode, dpr.ProcedureDescription
)
SELECT * FROM potential_dme_claims
ORDER BY code_category, claim_count DESC;
```

### Step 2: Analyze Excluded Code Volume and Impact
```sql
-- Focus on high-volume excluded codes that might be legitimate DME
WITH excluded_codes AS (
  SELECT 
    dpr.ProcedureCode,
    dpr.ProcedureDescription,
    COUNT(*) as claim_count,
    COUNT(DISTINCT dpat.PatientNumber) as unique_patients,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) as pct_of_excluded_volume,
    -- Try to identify DME-related patterns in descriptions
    CASE 
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%WHEELCHAIR%' THEN 'Wheelchair'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%CPAP%' OR UPPER(dpr.ProcedureDescription) LIKE '%SLEEP%' THEN 'Sleep Equipment'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%OXYGEN%' OR UPPER(dpr.ProcedureDescription) LIKE '%CONCENTRATOR%' THEN 'Oxygen Equipment'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%WALKER%' OR UPPER(dpr.ProcedureDescription) LIKE '%CANE%' THEN 'Mobility Aids'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%MASK%' OR UPPER(dpr.ProcedureDescription) LIKE '%TUBING%' THEN 'DME Supplies'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%BATTERY%' OR UPPER(dpr.ProcedureDescription) LIKE '%CHARGER%' THEN 'DME Accessories'
      ELSE 'Other/Unknown'
    END as dme_category
  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
  LEFT JOIN [dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  LEFT JOIN [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -12, GETDATE())
    -- Exclude currently included codes
    AND NOT ((dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
             OR dpr.ProcedureCode LIKE 'E%')
    -- Focus on potential DME codes
    AND (dpr.ProcedureCode LIKE 'A%' OR dpr.ProcedureCode LIKE 'K%' OR dpr.ProcedureCode LIKE 'B%')
  GROUP BY dpr.ProcedureCode, dpr.ProcedureDescription
  HAVING COUNT(*) >= 10  -- Only codes with meaningful volume
)
SELECT *
FROM excluded_codes
ORDER BY claim_count DESC;
```

### Step 3: Common DME Supply Codes Analysis
```sql
-- Focus specifically on A-codes that are commonly DME supplies
WITH a_code_analysis AS (
  SELECT 
    dpr.ProcedureCode,
    dpr.ProcedureDescription,
    COUNT(*) as claim_count,
    COUNT(DISTINCT dpat.PatientNumber) as unique_patients,
    -- Flag likely DME supplies based on common patterns
    CASE 
      WHEN dpr.ProcedureCode IN (
        'A7030', 'A7031', 'A7032', 'A7033', 'A7034', 'A7035', 'A7036', 'A7037', 'A7038', 'A7039',  -- CPAP supplies
        'A7044', 'A7045', 'A7046',  -- CPAP masks
        'A4604', 'A4605', 'A4606', 'A4608',  -- Tubing and connectors
        'A4611', 'A4612', 'A4613', 'A4614', 'A4615', 'A4616', 'A4617', 'A4618', 'A4619', 'A4620'   -- Batteries and supplies
      ) THEN 'High Confidence DME'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%CPAP%' 
           OR UPPER(dpr.ProcedureDescription) LIKE '%MASK%'
           OR UPPER(dpr.ProcedureDescription) LIKE '%TUBING%'
           OR UPPER(dpr.ProcedureDescription) LIKE '%FILTER%'
           OR UPPER(dpr.ProcedureDescription) LIKE '%BATTERY%'
      THEN 'Likely DME Supply'
      ELSE 'Review Required'
    END as dme_confidence
  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
  LEFT JOIN [dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  LEFT JOIN [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -12, GETDATE())
    AND dpr.ProcedureCode LIKE 'A%'
  GROUP BY dpr.ProcedureCode, dpr.ProcedureDescription
)
SELECT 
  dme_confidence,
  COUNT(*) as code_count,
  SUM(claim_count) as total_claims,
  SUM(unique_patients) as total_patients
FROM a_code_analysis
GROUP BY dme_confidence
ORDER BY total_claims DESC;
```

### Step 4: K-Code Analysis (Wheelchair and Mobility)
```sql
-- Analyze K-codes which often include wheelchair-related items
WITH k_code_analysis AS (
  SELECT 
    dpr.ProcedureCode,
    dpr.ProcedureDescription,
    COUNT(*) as claim_count,
    COUNT(DISTINCT dpat.PatientNumber) as unique_patients,
    CASE 
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%WHEELCHAIR%' THEN 'Wheelchair'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%MOBILITY%' OR UPPER(dpr.ProcedureDescription) LIKE '%SCOOTER%' THEN 'Mobility Device'
      WHEN UPPER(dpr.ProcedureDescription) LIKE '%CUSHION%' OR UPPER(dpr.ProcedureDescription) LIKE '%SEAT%' THEN 'Wheelchair Accessory'
      ELSE 'Other K-Code'
    END as k_code_category
  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
  LEFT JOIN [dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  LEFT JOIN [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -12, GETDATE())
    AND dpr.ProcedureCode LIKE 'K%'
  GROUP BY dpr.ProcedureCode, dpr.ProcedureDescription
  HAVING COUNT(*) >= 5
)
SELECT *
FROM k_code_analysis
ORDER BY k_code_category, claim_count DESC;
```

### Step 5: Impact Assessment - Expanded Code Set
```sql
-- Estimate the impact of including additional codes on fulfillment rates
WITH current_fulfillment AS (
  -- Current logic fulfillment count
  SELECT COUNT(DISTINCT dpat.PatientNumber) as patients_with_current_codes
  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
  LEFT JOIN [dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  LEFT JOIN [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -12, GETDATE())
    AND ((dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
         OR dpr.ProcedureCode LIKE 'E%')
),
expanded_fulfillment AS (
  -- Expanded logic fulfillment count (including high-confidence A and K codes)
  SELECT COUNT(DISTINCT dpat.PatientNumber) as patients_with_expanded_codes
  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f
  LEFT JOIN [dbo].[Dim_Procedure] dpr ON f.ProcedureKey = dpr.ProcedureKey
  LEFT JOIN [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey
  LEFT JOIN [dbo].[Dim_Date] dda ON f.DateKey_DateOfService = dda.DateKey
  WHERE f.ClaimID IS NOT NULL
    AND dda.DateValue >= DATEADD(month, -12, GETDATE())
    AND (
      -- Current codes
      (dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
      OR dpr.ProcedureCode LIKE 'E%'
      -- High-confidence additional codes
      OR dpr.ProcedureCode IN (
        'A7030', 'A7031', 'A7032', 'A7033', 'A7034', 'A7035', 'A7036', 'A7037', 'A7038', 'A7039',
        'A7044', 'A7045', 'A7046',
        'A4604', 'A4605', 'A4606', 'A4608'
      )
      OR (dpr.ProcedureCode LIKE 'K%' AND UPPER(dpr.ProcedureDescription) LIKE '%WHEELCHAIR%')
    )
)
SELECT 
  c.patients_with_current_codes,
  e.patients_with_expanded_codes,
  e.patients_with_expanded_codes - c.patients_with_current_codes as additional_patients,
  ROUND(100.0 * (e.patients_with_expanded_codes - c.patients_with_current_codes) / c.patients_with_current_codes, 2) as pct_increase
FROM current_fulfillment c
CROSS JOIN expanded_fulfillment e;
```

## Expected Outputs

### Key Findings
- **Code Volume Analysis**: Top 25 excluded HCPCS codes by claim volume
- **DME Category Breakdown**: Distribution of excluded codes by equipment type
- **Impact Quantification**: Estimated increase in fulfillment rates with expanded code set
- **High-Confidence Additions**: Specific codes recommended for immediate inclusion

### Recommended Code Additions

#### High Priority (Immediate Inclusion)
- **A7030-A7039**: CPAP supplies and accessories
- **A7044-A7046**: CPAP masks
- **A4604-A4608**: Tubing and connectors
- **K-codes with "WHEELCHAIR"**: Wheelchair-related temporary codes

#### Medium Priority (Review Required)
- **A4611-A4620**: Batteries and power supplies
- **B-codes**: Enteral/parenteral therapy supplies (if applicable to DME program)
- **Other A-codes**: Based on description analysis and clinical review

#### Low Priority (Monitor)
- **Infrequent codes**: Codes with <10 claims per year
- **Ambiguous descriptions**: Codes requiring clinical interpretation

## Business Impact Assessment

### Potential Benefits of Expansion
- **Improved Accuracy**: More complete capture of DME fulfillment activities
- **Better Vendor Management**: Visibility into supply chain performance
- **Enhanced Revenue Cycle**: Identification of coding opportunities
- **Compliance Support**: More comprehensive DME program reporting

### Implementation Considerations
- **Clinical Review**: Engage DME specialists to validate code relevance
- **System Impact**: Assess performance implications of expanded queries
- **Historical Adjustment**: Consider retroactive application for trend analysis
- **Governance Process**: Establish ongoing code set maintenance procedures

## Next Steps
1. **Clinical Validation**: Review findings with DME clinical team
2. **Stakeholder Approval**: Present recommendations to revenue cycle and compliance
3. **Phased Implementation**: Start with high-confidence codes, expand gradually
4. **Impact Monitoring**: Track changes in fulfillment rates and identify new patterns
5. **Quarterly Review**: Establish regular code set review and update process

## Success Metrics
- **Coverage Improvement**: Target 95%+ of legitimate DME activities captured
- **False Positive Rate**: Keep non-DME codes below 5% of expanded set
- **Clinical Validation**: 90%+ agreement from DME specialists on code relevance
- **Business Value**: Measurable improvement in fulfillment rate accuracy and actionable insights
