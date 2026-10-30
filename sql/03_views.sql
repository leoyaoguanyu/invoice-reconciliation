/* ============================================================
   03_views.sql  –  Azure SQL Database (T-SQL)
   Cleaning views, validation checks and summaries.
   Excel connects to v_issues_summary, v_vendor_summary and v_invoice_checks.
   ============================================================ */

/* ---------- 1. Vendors with term days and tax rate ---------- */
CREATE OR ALTER VIEW recon.v_vendors AS
SELECT
    v.VendorID, v.VendorName, v.Category, v.PaymentTerms, v.Status, v.Province,
    CAST(SUBSTRING(v.PaymentTerms, 4, 5) AS int) AS TermDays,       -- 'Net30' -> 30
    t.TaxRate
FROM recon.stg_vendors AS v
LEFT JOIN recon.ref_tax_rates AS t ON t.Province = v.Province;
GO

/* ---------- 2. Clean the AP export ---------- */
CREATE OR ALTER VIEW recon.v_invoices_clean AS
WITH s AS (
    SELECT
        SourceRow,
        TRIM(InvoiceNo)                                        AS InvoiceNo,
        Vendor                                                 AS VendorRaw,
        UPPER(TRIM(Vendor))                                    AS VendorKey,
        NULLIF(TRIM(PO), '')                                   AS PO_Number,
        REPLACE(TRIM(InvoiceDate), '/', '-')                   AS DateText,   -- 2026/06/10 -> 2026-06-10
        REPLACE(REPLACE(TRIM(NetAmount), '$', ''), ',', '')    AS NetText,    -- '$7,976.03' -> '7976.03'
        REPLACE(REPLACE(TRIM(Tax), '$', ''), ',', '')          AS TaxText,
        REPLACE(REPLACE(TRIM(InvoiceTotal), '$', ''), ',', '') AS TotalText
    FROM recon.stg_ap_invoices
)
SELECT
    SourceRow, InvoiceNo, VendorRaw, VendorKey, PO_Number,
    COALESCE(TRY_CONVERT(date, DateText, 23),       -- yyyy-mm-dd
             TRY_CONVERT(date, DateText, 107))      -- Mon dd, yyyy
                                                    AS InvoiceDate,
    TRY_CAST(NetText   AS decimal(12,2))            AS NetAmount,
    TRY_CAST(TaxText   AS decimal(12,2))            AS Tax,
    TRY_CAST(TotalText AS decimal(12,2))            AS InvoiceTotal
FROM s;
GO

/* ---------- 3. Clean bank payments ---------- */
CREATE OR ALTER VIEW recon.v_payments_clean AS
SELECT
    PaymentRef, InvoiceRef, PaidDate, PaidAmount, Currency,
    CASE WHEN InvoiceRef LIKE '%-%' THEN InvoiceRef
         ELSE CONCAT('INV-', SUBSTRING(InvoiceRef, 4, 20))      -- 'INV10041' -> 'INV-10041'
    END AS InvoiceNo_Key
FROM recon.stg_bank_payments;
GO

/* ---------- 4. One row per invoice with every validation flag ---------- */
CREATE OR ALTER VIEW recon.v_invoice_checks AS
WITH i AS (
    SELECT
        c.*,
        COALESCE(a.VendorID, 'UNKNOWN') AS VendorID,
        ROW_NUMBER() OVER (PARTITION BY c.InvoiceNo ORDER BY c.SourceRow) AS OccurrenceNo
    FROM recon.v_invoices_clean AS c
    LEFT JOIN recon.ref_vendor_aliases AS a ON a.AliasKey = c.VendorKey
),
d AS (
    SELECT i.*, CASE WHEN OccurrenceNo > 1 THEN 1 ELSE 0 END AS Is_Duplicate
    FROM i
),
po_total AS (       -- cumulative net invoiced per PO, duplicates excluded
    SELECT PO_Number, SUM(NetAmount) AS PO_Invoiced_ToDate
    FROM d
    WHERE Is_Duplicate = 0 AND PO_Number IS NOT NULL
    GROUP BY PO_Number
),
paid AS (
    SELECT InvoiceNo_Key, SUM(PaidAmount) AS PaidAmount
    FROM recon.v_payments_clean
    GROUP BY InvoiceNo_Key
),
j AS (
    SELECT
        d.SourceRow, d.InvoiceNo, d.VendorRaw, d.VendorID, d.PO_Number, d.InvoiceDate,
        d.NetAmount, d.Tax, d.InvoiceTotal, d.Is_Duplicate,
        v.Status                         AS VendorStatus,
        v.TaxRate,
        p.VendorID                       AS PO_VendorID,
        p.Approved_Amount                AS PO_Approved,
        t.PO_Invoiced_ToDate,
        COALESCE(pd.PaidAmount, 0)       AS PaidAmount,
        DATEADD(day, COALESCE(v.TermDays, 30), d.InvoiceDate) AS DueDate
    FROM d
    LEFT JOIN recon.v_vendors           AS v  ON v.VendorID = d.VendorID
    LEFT JOIN recon.stg_purchase_orders AS p  ON p.PO_Number = d.PO_Number
    LEFT JOIN po_total                  AS t  ON t.PO_Number = d.PO_Number
    LEFT JOIN paid                      AS pd ON pd.InvoiceNo_Key = d.InvoiceNo
),
f AS (
    SELECT
        j.*,
        CASE WHEN VendorID = 'UNKNOWN' THEN 1 ELSE 0 END                                   AS Flag_UnknownVendor,
        CASE WHEN PO_Number IS NULL THEN 1 ELSE 0 END                                      AS Flag_MissingPO,
        CASE WHEN PO_Number IS NOT NULL AND PO_VendorID IS NULL THEN 1 ELSE 0 END          AS Flag_PO_NotFound,
        CASE WHEN PO_VendorID IS NOT NULL AND PO_VendorID <> VendorID THEN 1 ELSE 0 END    AS Flag_PO_VendorMismatch,
        CASE WHEN Is_Duplicate = 0 AND PO_Approved IS NOT NULL
                  AND PO_Invoiced_ToDate > PO_Approved THEN 1 ELSE 0 END                   AS Flag_OverPO,
        CASE WHEN ABS(NetAmount + Tax - InvoiceTotal) > 0.01 THEN 1 ELSE 0 END             AS Flag_TotalMismatch,
        CASE WHEN TaxRate IS NOT NULL
                  AND ABS(Tax - ROUND(NetAmount * TaxRate, 2)) > 0.01 THEN 1 ELSE 0 END    AS Flag_TaxRate,
        CASE WHEN VendorStatus = 'Inactive' THEN 1 ELSE 0 END                              AS Flag_InactiveVendor,
        CASE WHEN Is_Duplicate = 0 AND PaidAmount > 0
                  AND ABS(PaidAmount - InvoiceTotal) > 0.01 THEN 1 ELSE 0 END              AS Flag_PaymentMismatch,
        CASE WHEN Is_Duplicate = 0 AND PaidAmount = 0
                  AND DueDate < (SELECT MAX(AsOfDate) FROM recon.config) THEN 1 ELSE 0 END AS Flag_OverdueUnpaid
    FROM j
)
SELECT
    f.*,
    Is_Duplicate + Flag_UnknownVendor + Flag_MissingPO + Flag_PO_NotFound + Flag_PO_VendorMismatch
    + Flag_OverPO + Flag_TotalMismatch + Flag_TaxRate + Flag_InactiveVendor
    + Flag_PaymentMismatch + Flag_OverdueUnpaid AS IssueCount
FROM f;
GO

/* ---------- 5. Payments that match no invoice ---------- */
CREATE OR ALTER VIEW recon.v_payment_checks AS
SELECT
    p.PaymentRef, p.InvoiceRef, p.InvoiceNo_Key, p.PaidDate, p.PaidAmount,
    CASE WHEN NOT EXISTS (SELECT 1 FROM recon.v_invoices_clean AS c WHERE c.InvoiceNo = p.InvoiceNo_Key)
         THEN 1 ELSE 0 END AS Flag_OrphanPayment
FROM recon.v_payments_clean AS p;
GO

/* ---------- 6. Gaps in the application / document-type / vendor map ---------- */
CREATE OR ALTER VIEW recon.v_mapping_checks AS
SELECT
    m.Application, m.DocumentType, m.PrintVendorID, m.MailVendorID, m.Owner,
    CASE WHEN COALESCE(m.MailVendorID, '') = '' THEN 1 ELSE 0 END AS Flag_MissingMailVendor,
    CASE WHEN COALESCE(m.Owner, '') = '' THEN 1 ELSE 0 END        AS Flag_MissingOwner,
    CASE WHEN pv.Status = 'Inactive' OR mv.Status = 'Inactive' THEN 1 ELSE 0 END AS Flag_InactiveVendorMapped
FROM recon.stg_app_doc_map AS m
LEFT JOIN recon.stg_vendors AS pv ON pv.VendorID = m.PrintVendorID
LEFT JOIN recon.stg_vendors AS mv ON mv.VendorID = m.MailVendorID;
GO

/* ---------- 7. Issue log: count, dollar value, suggested action ---------- */
CREATE OR ALTER VIEW recon.v_issues_summary AS
SELECT 1 AS IssueOrder, 'Duplicate invoice' AS Issue, SUM(Is_Duplicate) AS IssueCount,
       SUM(CASE WHEN Is_Duplicate = 1 THEN InvoiceTotal ELSE 0 END) AS DollarValue,
       'Hold payment on the duplicate; ask AP to void it.' AS SuggestedAction
FROM recon.v_invoice_checks
UNION ALL
SELECT 2, 'Vendor not in vendor master', SUM(Flag_UnknownVendor),
       SUM(CASE WHEN Flag_UnknownVendor = 1 THEN InvoiceTotal ELSE 0 END),
       'Confirm with Vendor Governance whether to onboard or reject.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 3, 'Invoice has no PO number', SUM(Flag_MissingPO),
       SUM(CASE WHEN Flag_MissingPO = 1 THEN InvoiceTotal ELSE 0 END),
       'Ask the requester for the PO; no PO means no payment approval.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 4, 'PO number not found in PO system', SUM(Flag_PO_NotFound),
       SUM(CASE WHEN Flag_PO_NotFound = 1 THEN InvoiceTotal ELSE 0 END),
       'Check for a typo or a PO raised in another system.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 5, 'Invoice vendor differs from PO vendor', SUM(Flag_PO_VendorMismatch),
       SUM(CASE WHEN Flag_PO_VendorMismatch = 1 THEN InvoiceTotal ELSE 0 END),
       'Possible mis-keyed PO; confirm with the requester.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 6, 'Cumulative invoices exceed PO amount', SUM(Flag_OverPO),
       SUM(CASE WHEN Flag_OverPO = 1 THEN InvoiceTotal ELSE 0 END),
       'Needs a PO amendment or approver sign-off.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 7, 'Net + Tax does not equal Invoice Total', SUM(Flag_TotalMismatch),
       SUM(CASE WHEN Flag_TotalMismatch = 1 THEN InvoiceTotal ELSE 0 END),
       'Request a corrected invoice from the vendor.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 8, 'Tax not at expected provincial rate', SUM(Flag_TaxRate),
       SUM(CASE WHEN Flag_TaxRate = 1 THEN Tax ELSE 0 END),
       'Check the vendor''s tax registration and place of supply.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 9, 'Invoice from Inactive vendor', SUM(Flag_InactiveVendor),
       SUM(CASE WHEN Flag_InactiveVendor = 1 THEN InvoiceTotal ELSE 0 END),
       'Confirm whether the vendor should be reactivated.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 10, 'Paid amount differs from invoice total', SUM(Flag_PaymentMismatch),
       SUM(CASE WHEN Flag_PaymentMismatch = 1 THEN PaidAmount ELSE 0 END),
       'Short or over payment; reconcile with Treasury.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 11, 'Unpaid and past due', SUM(Flag_OverdueUnpaid),
       SUM(CASE WHEN Flag_OverdueUnpaid = 1 THEN InvoiceTotal ELSE 0 END),
       'Escalate to AP for the next payment run.'
FROM recon.v_invoice_checks
UNION ALL
SELECT 12, 'Payment with no matching invoice', SUM(Flag_OrphanPayment),
       SUM(CASE WHEN Flag_OrphanPayment = 1 THEN PaidAmount ELSE 0 END),
       'Trace with Treasury; possible misapplied payment.'
FROM recon.v_payment_checks
UNION ALL
SELECT 13, 'Mapping row missing mail vendor', SUM(Flag_MissingMailVendor), NULL,
       'Fill in with Production Ops.'
FROM recon.v_mapping_checks
UNION ALL
SELECT 14, 'Mapping row missing owner', SUM(Flag_MissingOwner), NULL,
       'Assign an owner team.'
FROM recon.v_mapping_checks
UNION ALL
SELECT 15, 'Mapping row uses an Inactive vendor', SUM(Flag_InactiveVendorMapped), NULL,
       'Re-map to an active vendor.'
FROM recon.v_mapping_checks;
GO

/* ---------- 8. Invoiced / paid / outstanding by vendor ---------- */
CREATE OR ALTER VIEW recon.v_vendor_summary AS
SELECT
    c.VendorID,
    COALESCE(v.VendorName, 'Not in vendor master')        AS VendorName,
    v.Status,
    SUM(CASE WHEN c.Is_Duplicate = 0 THEN 1 ELSE 0 END)   AS Invoices,
    SUM(CASE WHEN c.Is_Duplicate = 0 THEN c.InvoiceTotal ELSE 0 END) AS Invoiced,
    SUM(CASE WHEN c.Is_Duplicate = 0 THEN c.PaidAmount  ELSE 0 END)  AS Paid,
    SUM(CASE WHEN c.Is_Duplicate = 0 THEN c.InvoiceTotal - c.PaidAmount ELSE 0 END) AS Outstanding,
    SUM(CASE WHEN c.IssueCount > 0 THEN 1 ELSE 0 END)     AS InvoicesWithIssues
FROM recon.v_invoice_checks AS c
LEFT JOIN recon.stg_vendors AS v ON v.VendorID = c.VendorID
GROUP BY c.VendorID, v.VendorName, v.Status;
GO
