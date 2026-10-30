/* ============================================================
   01_create_tables.sql  –  Azure SQL Database (T-SQL)
   Creates the recon schema, raw staging tables and reference tables.
   Safe to re-run: drops and recreates everything.
   Run order: 01 -> 02 -> 03
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'recon')
    EXEC('CREATE SCHEMA recon');
GO

DROP VIEW IF EXISTS recon.v_vendor_summary, recon.v_issues_summary, recon.v_mapping_checks,
                    recon.v_payment_checks, recon.v_invoice_checks, recon.v_payments_clean,
                    recon.v_invoices_clean, recon.v_vendors;
DROP TABLE IF EXISTS recon.stg_vendors, recon.stg_purchase_orders, recon.stg_ap_invoices,
                     recon.stg_bank_payments, recon.stg_app_doc_map,
                     recon.ref_vendor_aliases, recon.ref_tax_rates, recon.config;
GO

/* ---------- staging: loaded as-is from the source systems ---------- */

-- Vendor master (procurement system) – clean, treated as the source of truth
CREATE TABLE recon.stg_vendors (
    VendorID      varchar(10)   NOT NULL PRIMARY KEY,
    VendorName    varchar(100)  NOT NULL,
    Category      varchar(50)   NULL,
    PaymentTerms  varchar(10)   NULL,      -- e.g. 'Net30'
    Status        varchar(10)   NULL,      -- Active / Inactive
    Province      char(2)       NULL
);

-- Purchase orders (PO system)
CREATE TABLE recon.stg_purchase_orders (
    PO_Number        varchar(20)    NOT NULL PRIMARY KEY,
    VendorID         varchar(10)    NOT NULL,
    Application      varchar(50)    NULL,
    DocumentType     varchar(50)    NULL,
    Approved_Amount  decimal(12,2)  NOT NULL,
    PO_Date          date           NULL,
    Approver         varchar(50)    NULL
);

-- AP invoice export – kept as raw TEXT on purpose; cleaning happens in v_invoices_clean
CREATE TABLE recon.stg_ap_invoices (
    SourceRow     int           NOT NULL PRIMARY KEY,   -- row order in the export file
    InvoiceNo     varchar(30)   NULL,
    Vendor        varchar(100)  NULL,                   -- free text, many spellings
    PO            varchar(20)   NULL,
    InvoiceDate   varchar(30)   NULL,                   -- 3 formats
    NetAmount     varchar(30)   NULL,                   -- '$7,976.03', ' 7,070.60 '
    Tax           varchar(30)   NULL,
    InvoiceTotal  varchar(30)   NULL,
    Currency      char(3)       NULL
);

-- Bank payments (treasury)
CREATE TABLE recon.stg_bank_payments (
    PaymentRef   varchar(20)    NOT NULL PRIMARY KEY,
    InvoiceRef   varchar(30)    NULL,                   -- sometimes missing the hyphen
    PaidDate     date           NULL,
    PaidAmount   decimal(12,2)  NULL,
    Currency     char(3)        NULL
);

-- Application / document type / vendor map (maintained by hand)
CREATE TABLE recon.stg_app_doc_map (
    Application    varchar(50)  NOT NULL,
    DocumentType   varchar(50)  NOT NULL,
    PrintVendorID  varchar(10)  NULL,
    MailVendorID   varchar(10)  NULL,
    Owner          varchar(50)  NULL
);

/* ---------- reference tables ---------- */

-- Data catalog: every vendor spelling seen in AP (UPPER + TRIM) -> master VendorID
CREATE TABLE recon.ref_vendor_aliases (
    AliasKey  varchar(100)  NOT NULL PRIMARY KEY,
    VendorID  varchar(10)   NOT NULL
);

-- Combined sales-tax rate by province (assumption for this exercise)
CREATE TABLE recon.ref_tax_rates (
    Province  char(2)       NOT NULL PRIMARY KEY,
    TaxRate   decimal(6,5)  NOT NULL
);

-- Run settings
CREATE TABLE recon.config (
    AsOfDate  date  NOT NULL
);
GO
