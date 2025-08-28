USE [DataWarehouse]
GO

/****** Object:  View [dbo].[vwRPT_OPS_NoAuth_Appts]    Script Date: 7/22/2025 9:54:07 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/****** vwRPT_OPS_NoAuth_Appts  ******/
CREATE  OR ALTER VIEW [dbo].[vwRPT_OPS_NoAuth_Appts] AS
SELECT dl.Region_Operations
		,dl.Company
		,dl.Practice
		,dl.Facility
		,dp.ProviderFullName_FirstLast ScheduledProvider
		,CASE WHEN dat.ApptEncounterType NOT IN ('NP','FU','Proc') 
			  THEN 'Other' 
			  ELSE dat.ApptEncounterType 
		 END EncounterTypeCode
		,CASE WHEN dat.ApptEncounterType NOT IN ('NP','FU','Proc') 
			  THEN 'Other' 
			  ELSE dat.ApptEncounterTypeName
		 END EncounterTypeName
		,dpat.PatientName Patient
		,(dss.SourceSystemShortName + '-' + dpat.PatientNumber) AS PatientNumber --MRN
		,dda.DateValue ApptDate
	FROM [DataWarehouse].[dbo].[Fact_Appointments] f LEFT JOIN
		[dbo].[Dim_Location] dl ON f.LocationKey_Service = dl.LocationKey LEFT JOIN
		[dbo].[Dim_Region_Lookup] drl ON dl.Region_Operations = drl.Region LEFT JOIN
		[dbo].[Dim_Provider] dp ON f.ProviderKey_Scheduled = dp.ProviderKey LEFT JOIN
		[dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey LEFT JOIN
		[dbo].[Dim_Date] dda on f.DateKey_ApptDate = dda.DateKey LEFT JOIN
		[dbo].[Dim_ApptType] dat ON f.ApptTypeKey = dat.ApptTypeKey LEFT JOIN
		[dbo].[Dim_ApptStatus] das ON f.ApptStatusKey = das.ApptStatusKey LEFT JOIN
		[dbo].[Dim_ApptStatus_NoAuths] dasn ON das.ApptStatus = dasn.ApptStatus LEFT JOIN
		[dbo].[Dim_SourceSystem] dss ON dpat.SourceSystemKey = dss.SourceSystemKey
	WHERE 1=1 --filter to include only:
	AND f.ApptCancelReasonKey <= 1 --non-cancelled appointments.
	AND dpat.isDeceased LIKE '%NOT%' --non-dead patients
	AND dda.DateValue >= DATEADD(MONTH, -48, CAST(GETDATE() AS DATE)) --appointments in the last 4 years.
	AND das.ApptStatusCategory IN ('Scheduled') --appt statuses of Scheduled.
	AND dasn.ApptStatus IS NOT NULL --Only include No Auth statuses.
	AND drl.Active = 1 --only include active regions
GO


