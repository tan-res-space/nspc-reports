/****** Script for SelectTopNRows command from SSMS  ******/
CREATE OR ALTER VIEW [dbo].[vwRPT_OPS_DME_Fulfillment_2] AS
	SELECT  [Facility_State]
		  ,[Facility_Name]
		  ,[Provider_Name]
		  ,[Patient_Name]
		  ,[Patient_Number]
		  ,MAX(CASE WHEN [order_number] IS NOT NULL THEN 1 ELSE 0 END) DME_Ordered
		  ,MAX(CASE WHEN [cpt_product] IS NOT NULL THEN 1 ELSE 0 END) DME_Filled
	  FROM [DataWarehouse].[dbo].[RPT_OPS_DME_Details_2]
	GROUP BY [Facility_State]
		  ,[Facility_Name]
		  ,[Provider_Name]
		  ,[Patient_Name]
		  ,[Patient_Number]
GO