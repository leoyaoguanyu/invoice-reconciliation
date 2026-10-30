// AP export is the messy source: vendor spelling drift, three date formats,
// amounts stored as text with "$", commas and spaces, and duplicate rows.
// Duplicates are NOT removed here: they are flagged in the Checks sheet so they can be reported.
let
    Source   = Csv.Document(File.Contents(FolderPath & "03_ap_invoices_export.csv"),
                 [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Renamed  = Table.RenameColumns(Promoted, {
                 {"Invoice #", "InvoiceNo"}, {"Vendor", "VendorRaw"}, {"PO", "PO_Number"},
                 {"Invoice Date", "InvoiceDateText"}, {"Net Amount", "NetText"},
                 {"Tax", "TaxText"}, {"Invoice Total", "TotalText"}}),
    Trimmed  = Table.TransformColumns(Renamed, {{"InvoiceNo", Text.Trim}, {"PO_Number", Text.Trim}}),

    // "$7,976.03" / " 7,070.60 " / "2199.23" -> number
    ToNumber = (t as text) as number => Number.From(Text.Remove(Text.Trim(t), {"$", ",", " "}), "en-US"),
    // "2026-05-16" / "2026/06/10" / "Sep 05, 2026" -> date
    ToDate   = (t as text) as date => Date.FromText(Text.Replace(Text.Trim(t), "/", "-"), [Culture = "en-US"]),

    AddDate  = Table.AddColumn(Trimmed, "InvoiceDate",  each ToDate([InvoiceDateText]), type date),
    AddNet   = Table.AddColumn(AddDate, "NetAmount",    each ToNumber([NetText]),   type number),
    AddTax   = Table.AddColumn(AddNet,  "Tax",          each ToNumber([TaxText]),   type number),
    AddTotal = Table.AddColumn(AddTax,  "InvoiceTotal", each ToNumber([TotalText]), type number),
    // Key used to look the vendor up in the Vendor_Aliases reference table
    AddKey   = Table.AddColumn(AddTotal, "VendorKey",   each Text.Upper(Text.Trim([VendorRaw])), type text),
    Result   = Table.SelectColumns(AddKey, {
                 "InvoiceNo", "VendorRaw", "VendorKey", "PO_Number", "InvoiceDate",
                 "NetAmount", "Tax", "InvoiceTotal", "Currency"})
in
    Result
