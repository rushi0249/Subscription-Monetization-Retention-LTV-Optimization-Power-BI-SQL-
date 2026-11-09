/* ============================================================================
   PROJECT: Subscription Monetization, Retention & LTV Optimization (SQL Server)
   SOURCE TABLE: [dbo].[Telco_Customer$]
   ============================================================================ */

-- ----------------------------------------------------------------------------
-- STEP 1: DATA CLEANING & FEATURE ENGINEERING VIEW
-- Run this section first (or run the whole script; GO separates the batches)
-- ----------------------------------------------------------------------------
IF OBJECT_ID('[dbo].[vw_telco_clean]', 'V') IS NOT NULL
    DROP VIEW [dbo].[vw_telco_clean];
GO

CREATE VIEW [dbo].[vw_telco_clean] AS
SELECT 
    [customerID] AS customer_id,
    [gender],
    CASE WHEN [SeniorCitizen] = 1 THEN 'Senior' ELSE 'Non-Senior' END AS age_segment,
    [Partner] AS has_partner,
    [Dependents] AS has_dependents,
    CAST([tenure] AS INT) AS tenure_months,
    CASE 
        WHEN [tenure] = 0 THEN '0. Month 0 (Trial)'
        WHEN [tenure] BETWEEN 1 AND 6 THEN '1. 1-6 Months (Early Risk)'
        WHEN [tenure] BETWEEN 7 AND 12 THEN '2. 7-12 Months'
        WHEN [tenure] BETWEEN 13 AND 24 THEN '3. 13-24 Months'
        ELSE '4. 24+ Months (Mature)'
    END AS tenure_cohort,
    [PhoneService] AS phone_service,
    [MultipleLines] AS multiple_lines,
    [InternetService] AS internet_service,
    [OnlineSecurity] AS online_security,
    [OnlineBackup] AS online_backup,
    [DeviceProtection] AS device_protection,
    [TechSupport] AS tech_support,
    [StreamingTV] AS streaming_tv,
    [StreamingMovies] AS streaming_movies,
    -- Feature Adoption Score (0 to 6 add-ons)
    (CASE WHEN [OnlineSecurity] = 'Yes' THEN 1 ELSE 0 END +
     CASE WHEN [OnlineBackup] = 'Yes' THEN 1 ELSE 0 END +
     CASE WHEN [DeviceProtection] = 'Yes' THEN 1 ELSE 0 END +
     CASE WHEN [TechSupport] = 'Yes' THEN 1 ELSE 0 END +
     CASE WHEN [StreamingTV] = 'Yes' THEN 1 ELSE 0 END +
     CASE WHEN [StreamingMovies] = 'Yes' THEN 1 ELSE 0 END) AS active_addons_count,
    [Contract] AS contract_type,
    [PaperlessBilling] AS paperless_billing,
    [PaymentMethod] AS payment_method,
    CAST([MonthlyCharges] AS DECIMAL(10,2)) AS monthly_charges,
    -- Safely handles NULLs and blank strings in Excel imports using TRY_CAST
    COALESCE(TRY_CAST(NULLIF(LTRIM(RTRIM(CAST([TotalCharges] AS VARCHAR(50)))), '') AS DECIMAL(10,2)), 0.00) AS total_charges,
    [Churn] AS churn_status,
    CASE WHEN [Churn] = 'Yes' THEN 1 ELSE 0 END AS is_churned
FROM [dbo].[Telco_Customer$];
GO


-- ----------------------------------------------------------------------------
-- QUERY 1: EXECUTIVE KPI BASELINE (LOGO CHURN VS. MRR REVENUE CHURN)
-- ----------------------------------------------------------------------------
SELECT 
    COUNT(customer_id) AS total_users,
    SUM(is_churned) AS churned_users,
    CAST(ROUND(100.0 * SUM(is_churned) / COUNT(customer_id), 2) AS DECIMAL(5,2)) AS logo_churn_rate_pct,
    CAST(ROUND(SUM(monthly_charges), 2) AS DECIMAL(12,2)) AS total_mrr,
    CAST(ROUND(SUM(CASE WHEN is_churned = 1 THEN monthly_charges ELSE 0 END), 2) AS DECIMAL(12,2)) AS churned_mrr,
    CAST(ROUND(100.0 * SUM(CASE WHEN is_churned = 1 THEN monthly_charges ELSE 0 END) / SUM(monthly_charges), 2) AS DECIMAL(5,2)) AS mrr_churn_rate_pct,
    CAST(ROUND(AVG(CASE WHEN is_churned = 1 THEN monthly_charges END), 2) AS DECIMAL(10,2)) AS avg_arpu_churned,
    CAST(ROUND(AVG(CASE WHEN is_churned = 0 THEN monthly_charges END), 2) AS DECIMAL(10,2)) AS avg_arpu_retained
FROM [dbo].[vw_telco_clean];


-- ----------------------------------------------------------------------------
-- QUERY 2: TENURE COHORT SURVIVAL & CUMULATIVE LOST MRR (WINDOW FUNCTIONS)
-- ----------------------------------------------------------------------------
WITH cohort_summary AS (
    SELECT 
        tenure_cohort,
        COUNT(customer_id) AS users_in_cohort,
        SUM(is_churned) AS churned_users,
        SUM(monthly_charges) AS cohort_mrr,
        SUM(CASE WHEN is_churned = 1 THEN monthly_charges ELSE 0 END) AS lost_mrr
    FROM [dbo].[vw_telco_clean]
    GROUP BY tenure_cohort
),
cohort_shares AS (
    SELECT 
        tenure_cohort,
        users_in_cohort,
        churned_users,
        CAST(ROUND(100.0 * churned_users / users_in_cohort, 2) AS DECIMAL(5,2)) AS cohort_churn_pct,
        CAST(ROUND(lost_mrr, 2) AS DECIMAL(12,2)) AS lost_mrr,
        100.0 * lost_mrr / SUM(lost_mrr) OVER () AS pct_share
    FROM cohort_summary
)
SELECT 
    tenure_cohort,
    users_in_cohort,
    churned_users,
    cohort_churn_pct,
    lost_mrr,
    CAST(ROUND(pct_share, 2) AS DECIMAL(5,2)) AS pct_of_total_lost_mrr,
    CAST(ROUND(SUM(pct_share) OVER (ORDER BY tenure_cohort), 2) AS DECIMAL(5,2)) AS cumulative_lost_mrr_pct
FROM cohort_shares
ORDER BY tenure_cohort;


-- ----------------------------------------------------------------------------
-- QUERY 3: ROOT-CAUSE ANALYSIS (RCA) — TOP 10 REVENUE LOSS SEGMENTS
-- ----------------------------------------------------------------------------
WITH segment_metrics AS (
    SELECT 
        contract_type,
        internet_service,
        payment_method,
        COUNT(*) AS segment_users,
        SUM(is_churned) AS churned_users,
        CAST(ROUND(100.0 * SUM(is_churned) / COUNT(*), 2) AS DECIMAL(5,2)) AS churn_rate_pct,
        CAST(ROUND(SUM(CASE WHEN is_churned = 1 THEN monthly_charges ELSE 0 END), 2) AS DECIMAL(12,2)) AS at_risk_mrr
    FROM [dbo].[vw_telco_clean]
    GROUP BY contract_type, internet_service, payment_method
    HAVING COUNT(*) >= 50
)
SELECT TOP 10
    contract_type,
    internet_service,
    payment_method,
    segment_users,
    churned_users,
    churn_rate_pct,
    at_risk_mrr,
    DENSE_RANK() OVER (ORDER BY at_risk_mrr DESC) AS revenue_loss_rank
FROM segment_metrics
ORDER BY revenue_loss_rank;


-- ----------------------------------------------------------------------------
-- QUERY 4: PRODUCT STICKINESS — ADD-ON ADOPTION VS. CHURN & ARPU LIFT
-- ----------------------------------------------------------------------------
SELECT 
    active_addons_count,
    COUNT(*) AS total_users,
    CAST(ROUND(AVG(monthly_charges), 2) AS DECIMAL(10,2)) AS avg_arpu,
    CAST(ROUND(100.0 * SUM(is_churned) / COUNT(*), 2) AS DECIMAL(5,2)) AS churn_rate_pct,
    CAST(ROUND(AVG(CAST(tenure_months AS FLOAT)), 1) AS DECIMAL(5,1)) AS avg_tenure_months
FROM [dbo].[vw_telco_clean]
WHERE internet_service <> 'No'
GROUP BY active_addons_count
ORDER BY active_addons_count;


-- ----------------------------------------------------------------------------
-- QUERY 5: ACTIONABLE RETENTION TARGET LIST (HIGH-RISK ACTIVE USERS)
-- ----------------------------------------------------------------------------
SELECT TOP 25
    customer_id,
    tenure_months,
    contract_type,
    internet_service,
    payment_method,
    active_addons_count,
    monthly_charges,
    total_charges
FROM [dbo].[vw_telco_clean]
WHERE is_churned = 0
  AND contract_type = 'Month-to-month'
  AND internet_service = 'Fiber optic'
  AND payment_method = 'Electronic check'
  AND active_addons_count = 0
ORDER BY monthly_charges DESC;