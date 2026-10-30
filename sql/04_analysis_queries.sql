/* ============================================================
   04_analysis_queries.sql  –  ad-hoc questions answered from the views
   Run any query on its own after 01–03.
   ============================================================ */

-- Q1. Which 5 vendors have the largest outstanding balance?
SELECT TOP 5 VendorID, VendorName, Invoices, Invoiced, Paid, Outstanding, InvoicesWithIssues
FROM recon.v_vendor_summary
ORDER BY Outstanding DESC;

-- Q2. Ageing of unpaid invoices as of the run date (duplicates excluded)
SELECT
    CASE WHEN DaysPastDue <= 0  THEN '0 Not yet due'
         WHEN DaysPastDue <= 30 THEN '1-30 days'
         WHEN DaysPastDue <= 60 THEN '31-60 days'
         ELSE '60+ days' END                AS AgeingBucket,
    COUNT(*)                                AS Invoices,
    SUM(InvoiceTotal)                       AS Amount
FROM (
    SELECT InvoiceTotal,
           DATEDIFF(day, DueDate, (SELECT MAX(AsOfDate) FROM recon.config)) AS DaysPastDue
    FROM recon.v_invoice_checks
    WHERE Is_Duplicate = 0 AND PaidAmount = 0
) AS u
GROUP BY CASE WHEN DaysPastDue <= 0  THEN '0 Not yet due'
              WHEN DaysPastDue <= 30 THEN '1-30 days'
              WHEN DaysPastDue <= 60 THEN '31-60 days'
              ELSE '60+ days' END
ORDER BY AgeingBucket;

-- Q3. Invoices with more than one issue – the ones to review first
SELECT InvoiceNo, VendorID, PO_Number, InvoiceTotal, IssueCount,
       Is_Duplicate, Flag_UnknownVendor, Flag_MissingPO, Flag_OverPO,
       Flag_TotalMismatch, Flag_InactiveVendor, Flag_PaymentMismatch, Flag_OverdueUnpaid
FROM recon.v_invoice_checks
WHERE IssueCount > 1
ORDER BY IssueCount DESC, InvoiceTotal DESC;

-- Q4. POs billed beyond their approved amount
SELECT PO_Number, VendorID, PO_Approved, PO_Invoiced_ToDate,
       PO_Invoiced_ToDate - PO_Approved AS OverBy
FROM recon.v_invoice_checks
WHERE Flag_OverPO = 1
GROUP BY PO_Number, VendorID, PO_Approved, PO_Invoiced_ToDate
ORDER BY OverBy DESC;
