CREATE OR ALTER   VIEW [dbo].[vwRPT_OPS_DME_Details_2] AS

SELECT ord.facility_state Facility_State,
	   ord.facility_name Facility_Name,
	   ord.provider_name Provider_Name,
	   ord.patient_name Patient_Name,
	   ord.patient_number Patient_Number,
	   ord.preferred_number Preferred_Number,
	   ord.phone_type Phone_Type,
	   ord.message_ok Message_Ok,
	   ord.order_number, ord.order_name, ord.order_date, --order-specific info
	   NULL service_from, NULL service_to, --charge service date range
	   NULL coverage_type, Latest_ProcedureCode cpt_product, NULL cpt_product_description --other charge columns
FROM
(
SELECT MAX(fac.facility_state) facility_state, MAX(fac.[name]) facility_name, 
	   MAX(ol.provider_name) provider_name, MAX(pat.mrn) patient_number,
	   MAX(pat.first_name + ' ' + pat.last_name) patient_name, 
	   MAX(pat.preferred_phone_number) preferred_number, 
	   MAX(pat.preferred_phone) phone_type, MAX(pat.ok_to_leave_detailed_message) message_ok, 
	   MAX(ol.order_number) order_number, MAX(ol.order_name) order_name, MAX(ol.order_date) order_date, 
	   (fac.facility_state + '_' + pat.mrn) ord_key_calc
  FROM [Staging_EMA_NSPC].[dbo].[order_log] ol  LEFT JOIN
	   [Staging_EMA_NSPC].[dbo].[patient] pat ON ol.patient_id = pat.patient_id LEFT JOIN
	   [Staging_EMA_NSPC].[dbo].[facility] fac ON ol.facility_id = fac.facility_id
	   -- INNER JOIN [DataWarehouse].[dbo].[Dim_Location] dl ON fac.[name] = dl.facility --Drops ~10% of recs
 WHERE 1=1
   AND CONVERT(DATE,LEFT(ol.order_date,10)) >= DATEADD(year, -1, GETDATE()) --only pull orders from a year ago forward.
   AND ol.order_type = 'DMEPOS' --only pull DME orders
   GROUP BY (fac.facility_state + '_' + pat.mrn)
) ord
LEFT JOIN
(   --make sure you only get one row per patient / date
	SELECT MAX(dl.FacilityAddress_State) Facility_State, MAX(dl.Facility) Facility,
		   --Region_Operations, Company, Practice, Facility, 
		   --dp.ProviderFullName_FirstLast ScheduledProvider, 
			--dpat.PatientName_LastFirst PatientName, 
			dpat.PatientNumber, 
			MAX(dpr.ProcedureCode) Latest_ProcedureCode,
			MAX(dda.DateValue) Latest_ServiceDate
		  FROM [DataWarehouse].[dbo].[Fact_FinancialTrans_Actual] f LEFT JOIN
			   [dbo].[Dim_Location] dl ON f.LocationKey_Service = dl.LocationKey LEFT JOIN
			   [dbo].[Dim_Region_Lookup] drl ON dl.Region_Operations = drl.Region LEFT JOIN
			   [dbo].[Dim_Provider] dp ON f.ProviderKey_Attending = dp.ProviderKey LEFT JOIN
			   [dbo].[Dim_Date] dda on f.DateKey_DateOfService = dda.DateKey LEFT JOIN
			   [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey LEFT JOIN
			   [dbo].[Dim_SourceSystem] dss ON dpat.SourceSystemKey = dss.SourceSystemKey LEFT JOIN 
			   [dbo].[Dim_Procedure] dpr ON F.ProcedureKey = dpr.ProcedureKey
		 WHERE 1=1 --filter to include only:
		   AND dpat.isDeceased LIKE '%NOT%' --non-dead patients
		   AND dda.DateValue >= DATEADD(MONTH, -12, CAST(GETDATE() AS DATE)) --claims from last 12 months.
		   AND drl.Active = 1 --only include active regions
		   AND ((dpr.ProcedureCode LIKE 'L%' AND dpr.ProcedureCode NOT LIKE 'L8680')
		    OR (dpr.ProcedureCode LIKE 'E%'))
		   AND f.ClaimID IS NOT NULL --Only consider transactions with a claim.
	GROUP BY dpat.PatientNumber
) chg ON ord.ord_key_calc = (chg.facility_state + '_' + chg.PatientNumber)