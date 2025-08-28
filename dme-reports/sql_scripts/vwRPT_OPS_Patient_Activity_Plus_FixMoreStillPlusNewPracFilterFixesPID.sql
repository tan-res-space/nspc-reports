USE [DataWarehouse]
GO

/****** Object:  View [dbo].[vwRPT_OPS_Patient_Activity_Plus_FixMore]    Script Date: 8/19/2025 10:24:29 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


/****** vwRPT_OPS_Patient_Activity_Plus_FixMoreStill  ******/
CREATE  OR ALTER  VIEW [dbo].[vwRPT_OPS_Patient_Activity_Plus_FixMoreStill] AS
SELECT CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.Region_Operations_LastSched ELSE seen_ds_out.Region_Operations_LastSeen END Region_Operations,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.Company_LastSched ELSE seen_ds_out.Company_LastSeen END Company,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.Practice_LastSched ELSE seen_ds_out.Practice_LastSeen END Practice,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.Facility_LastSched ELSE seen_ds_out.Facility_LastSeen END Facility,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.ScheduledProvider_LastSched ELSE seen_ds_out.ScheduledProvider_LastSeen END ScheduledProvider,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.PatientSched ELSE seen_ds_out.PatientSeen END Patient,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.LatestPatNum ELSE seen_ds_out.LatestPatNum END PatientNumber,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.EncounterCode_LastSched ELSE seen_ds_out.EncounterCode_LastSeen END EncounterCode,
	   CASE WHEN seen_ds_out.PatientPersonID IS NULL THEN sched_ds_out.EncounterName_LastSched ELSE seen_ds_out.EncounterName_LastSeen END EncounterName,
	   CASE WHEN LastSeenApptOut IS NULL THEN NULL 
			ELSE CAST(YEAR(LastSeenApptOut) AS CHAR(4)) + FORMAT(MONTH(LastSeenApptOut),'00')
	   END LastApptMonth, LastSeenApptOut LastAppt,
	   NextApptOut NextAppt,
	   CASE WHEN LastSchedApptOut IS NULL THEN NULL 
			ELSE CAST(YEAR(LastSchedApptOut) AS CHAR(4)) + FORMAT(MONTH(LastSchedApptOut),'00')
	   END LastSchedApptMonth, LastSchedApptOut LastSchedAppt,
	   CASE WHEN (sched_ds_out.NextApptOut IS NULL OR sched_ds_out.NextApptOut = CAST('12-31-9999' AS DATE)) AND
				 LastSeenApptOut IS NOT NULL AND DATEDIFF(MONTH, CAST(GETDATE() AS DATE), LastSeenApptOut) >= -12 
			THEN 1 ELSE 0 END RecentPatNoApptCnt, --Dataset already has filtered where NextAppt = NULL
	   CASE WHEN (sched_ds_out.NextApptOut IS NULL OR sched_ds_out.NextApptOut = CAST('12-31-9999' AS DATE)) AND
				 LastSeenApptOut IS NOT NULL AND DATEDIFF(MONTH, CAST(GETDATE() AS DATE), LastSeenApptOut) < -12 
			THEN 1 ELSE 0 END InactivePatientCnt, --Dataset already has filtered where NextAppt = NULL
	   CASE WHEN LastSchedApptOut IS NOT NULL AND NextApptOut IS NULL AND LastSeenApptOut IS NULL
			THEN 1 ELSE 0 END PatNeverSeenCnt,
	   CASE WHEN sched_ds_out.NextApptOut IS NULL OR sched_ds_out.NextApptOut = CAST('12-31-9999' AS DATE)
			THEN 1 
			ELSE 0
	   END TotNoFutureApptCnt,
	   --We should be able to remove ActivePatientCnt when there is time to refactor as it shouldn't be used
	   --and sees to be redundant with other calcs depending on how it is defined.
	   CASE WHEN LastSeenApptOut IS NOT NULL AND DATEDIFF(MONTH, CAST(GETDATE() AS DATE), LastSeenApptOut) >= -12 OR
				 (sched_ds_out.NextApptOut IS NOT NULL AND sched_ds_out.NextApptOut <> CAST('12-31-9999' AS DATE))
			THEN 1 
			ELSE 0
	   END ActivePatientCnt,
	   1 TotalPatientCnt,
	   CASE WHEN LastSeenApptOut IS NOT NULL AND DATEDIFF(MONTH, CAST(GETDATE() AS DATE), LastSeenApptOut) >= -12 
			THEN 1 ELSE 0 END TotalRecentPatCnt, --Dataset already has filtered where NextAppt = NULL
	   CASE WHEN LastSeenApptOut IS NOT NULL AND DATEDIFF(MONTH, CAST(GETDATE() AS DATE), LastSeenApptOut) < -12 
			THEN 1 ELSE 0 END TotalInactivePatCnt, --Dataset already has filtered where NextAppt = NULL
	   CASE WHEN (LastSchedApptOut IS NOT NULL OR NextApptOut IS NOT NULL) AND LastSeenApptOut IS NULL
			THEN 1 ELSE 0 END TotalPatNotSeenCnt
FROM
(
	--*** Patients Sched Dataset ***--
	SELECT PatientPersonID
		  ,MAX(Region_Operations_LastSched) Region_Operations_LastSched
		  ,MAX(Company_LastSched) Company_LastSched
		  ,MAX(Practice_LastSched) Practice_LastSched
		  ,MAX(Facility_LastSched) Facility_LastSched
		  ,MAX(ScheduledProvider_LastSched) ScheduledProvider_LastSched
		  ,MAX(EncounterCode_LastSched) EncounterCode_LastSched
		  ,MAX(EncounterName_LastSched) EncounterName_LastSched
		  ,MAX(PatientSched) PatientSched
		  ,MAX(LatestPatientNumber) LatestPatNum--Src+MRN
		  ,CASE WHEN MAX(NextApptIn) = CAST('12-31-9999' AS DATE) THEN NULL ELSE MAX(NextApptIn) END NextApptOut
		  ,CASE WHEN MAX(LastSchedApptIn) = CAST('01-01-1900' AS DATE) THEN NULL ELSE MAX(LastSchedApptIn) END LastSchedApptOut
	FROM
	(
		SELECT PatientPersonID
			   ,FIRST_VALUE(dl.Region_Operations) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Region_Operations_LastSched
			  ,FIRST_VALUE(dl.Company) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Company_LastSched
			  ,FIRST_VALUE(dl.Practice) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Practice_LastSched
			  ,FIRST_VALUE(dl.Facility) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Facility_LastSched
			  ,FIRST_VALUE(dp.ProviderFullName_FirstLast) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) ScheduledProvider_LastSched
			  ,FIRST_VALUE(dat.ApptEncounterType) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) EncounterCode_LastSched
			  ,FIRST_VALUE(dat.ApptEncounterTypeName) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) EncounterName_LastSched
			  ,FIRST_VALUE(dpat.PatientName) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) PatientSched
			  ,FIRST_VALUE(dss.SourceSystemShortName + '-' + dpat.PatientNumber) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) LatestPatientNumber --Source+MRN
			  ,MIN(CASE WHEN dda.DateValue > GETDATE() 
								THEN dda.DateValue ELSE CAST('12-31-9999' AS DATE) END --Push non-qualifying forward out of range
						  ) OVER (PARTITION BY dpat.PatientPersonID) NextApptIn
			  ,MAX(CASE WHEN dda.DateValue <= GETDATE() 
								THEN dda.DateValue ELSE CAST('01-01-1900' AS DATE) END --Push non-qualifying backward out of range
						  ) OVER (PARTITION BY dpat.PatientPersonID) LastSchedApptIn
		  FROM [DataWarehouse].[dbo].[Fact_Appointments] f LEFT JOIN
			   [dbo].[Dim_Location] dl ON f.LocationKey_Service = dl.LocationKey LEFT JOIN
			   [dbo].[Dim_Region_Lookup] drl ON dl.Region_Operations = drl.Region LEFT JOIN
			   [dbo].[Dim_Practice_Lookup] dpl ON dl.Practice = dpl.Practice LEFT JOIN
			   [dbo].[Dim_Provider] dp ON f.ProviderKey_Scheduled = dp.ProviderKey LEFT JOIN
			   [dbo].[Dim_Date] dda on f.DateKey_ApptDate = dda.DateKey LEFT JOIN
			   [dbo].[Dim_ApptType] dat ON f.ApptTypeKey = dat.ApptTypeKey LEFT JOIN
			   [dbo].[Dim_ApptStatus] das ON f.ApptStatusKey = das.ApptStatusKey LEFT JOIN
			   [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey LEFT JOIN
			   [dbo].[Dim_SourceSystem] dss ON dpat.SourceSystemKey = dss.SourceSystemKey
		 WHERE 1=1 --filter to include only:
		   AND f.ApptCancelReasonKey <= 1 --non-cancelled appointments.
		   AND dpat.isDeceased LIKE '%NOT%' --non-dead patients
		   AND dpat.isDischarged = 'No' --no discharged patients
		   AND dpat.DischargeReason <> '<Inactive>'
		   AND dda.DateValue >= DATEADD(MONTH, -24, CAST(GETDATE() AS DATE)) --appointments for last year.
		   AND das.ApptStatusCategory IN ('Scheduled','Confirmed') --appt statuses of Scheduled, Seen, or Confirmed
		   AND das.ApptStatus NOT IN ('PRN','DISCHARGED')
		   AND drl.Active = 1 --only include active regions
		   AND dpl.Active = 1 --only include active practices.
		   AND dat.ApptEncounterType NOT IN ('Anc','NA','<No Value Provided>') --Exclude ancillary, supplemental, and non-applicable appts.
	) sched_ds_in
	GROUP BY PatientPersonID
) sched_ds_out
FULL OUTER JOIN
(
	--*** Patients Seen Dataset ***--
	SELECT PatientPersonID
		  ,MAX(Region_Operations_LastSeen) Region_Operations_LastSeen
		  ,MAX(Company_LastSeen) Company_LastSeen
		  ,MAX(Practice_LastSeen) Practice_LastSeen
		  ,MAX(Facility_LastSeen) Facility_LastSeen
		  ,MAX(ScheduledProvider_LastSeen) ScheduledProvider_LastSeen
		  ,MAX(EncounterCode_LastSeen) EncounterCode_LastSeen
		  ,MAX(EncounterName_LastSeen) EncounterName_LastSeen
		  ,MAX(PatientSeen) PatientSeen
		  ,MAX(LatestPatientNumber) LatestPatNum --MRN
		  ,CASE WHEN MAX(LastSeenApptIn) = CAST('01-01-1900' AS DATE) THEN NULL ELSE MAX(LastSeenApptIn) END LastSeenApptOut
	FROM
	(
		SELECT  dpat.PatientPersonID
			   ,FIRST_VALUE(dl.Region_Operations) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Region_Operations_LastSeen
			  ,FIRST_VALUE(dl.Company) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Company_LastSeen
			  ,FIRST_VALUE(dl.Practice) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Practice_LastSeen
			  ,FIRST_VALUE(dl.Facility) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) Facility_LastSeen
			  ,FIRST_VALUE(dp.ProviderFullName_FirstLast) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) ScheduledProvider_LastSeen
			  ,FIRST_VALUE(dat.ApptEncounterType) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) EncounterCode_LastSeen
			  ,FIRST_VALUE(dat.ApptEncounterTypeName) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) EncounterName_LastSeen
			  ,FIRST_VALUE(dpat.PatientName) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) PatientSeen
			  ,FIRST_VALUE(dss.SourceSystemShortName + '-' + dpat.PatientNumber) 
				OVER (PARTITION BY dpat.PatientPersonID --Push future appointments back to favor last actual scheduled appointment.
					  ORDER BY CASE WHEN dda.DateValue > GETDATE() THEN CAST('01-01-1900' AS DATE) ELSE dda.DateValue END DESC) LatestPatientNumber --Source+MRN
			  ,MAX(CASE WHEN dda.DateValue <= GETDATE() 
								THEN dda.DateValue ELSE CAST('01-01-1900' AS DATE) END  --Push non-qualifying backward out of range
						  ) OVER (PARTITION BY dpat.PatientPersonID) LastSeenApptIn
		  FROM [DataWarehouse].[dbo].[Fact_Appointments] f LEFT JOIN
			   [dbo].[Dim_Location] dl ON f.LocationKey_Service = dl.LocationKey LEFT JOIN
			   [dbo].[Dim_Region_Lookup] drl ON dl.Region_Operations = drl.Region LEFT JOIN
			   [dbo].[Dim_Practice_Lookup] dpl ON dl.Practice = dpl.Practice LEFT JOIN
			   [dbo].[Dim_Provider] dp ON f.ProviderKey_Scheduled = dp.ProviderKey LEFT JOIN
			   [dbo].[Dim_Date] dda on f.DateKey_ApptDate = dda.DateKey LEFT JOIN
			   [dbo].[Dim_ApptType] dat ON f.ApptTypeKey = dat.ApptTypeKey LEFT JOIN
			   [dbo].[Dim_ApptStatus] das ON f.ApptStatusKey = das.ApptStatusKey LEFT JOIN
			   [dbo].[Dim_Patient] dpat ON f.PatientKey = dpat.PatientKey LEFT JOIN
			   [dbo].[Dim_SourceSystem] dss ON dpat.SourceSystemKey = dss.SourceSystemKey
		 WHERE 1=1 --filter to include only:
		   AND f.ApptCancelReasonKey <= 1 --non-cancelled appointments.
		   AND dpat.isDeceased LIKE '%NOT%' --non-dead patients
		   AND dpat.isDischarged = 'No' --no discharged patients
		   AND dpat.DischargeReason <> '<Inactive>'
		   AND dda.DateValue >= DATEADD(MONTH, -24, CAST(GETDATE() AS DATE)) --patients seen over last 2 years.
		   AND das.ApptStatusCategory IN ('Seen') --appt statuses of Scheduled, Seen, or Confirmed
		   AND das.ApptStatus NOT IN ('PRN','DISCHARGED')
		   AND drl.Active = 1 --only include active regions
		   AND dpl.Active = 1 --only include active practices.
		   AND dat.ApptEncounterType NOT IN ('Anc','NA','<No Value Provided>') --Exclude ancillary, supplemental, and non-applicable appts.
		   AND dda.DateValue <= GETDATE() -->>DC For now filter out any future seen appointments which will be handled separately.
	) seen_ds_in
	GROUP BY PatientPersonID
) seen_ds_out ON sched_ds_out.PatientPersonID = seen_ds_out.PatientPersonID


GO


