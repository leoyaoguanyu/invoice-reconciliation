let
    Source   = Excel.Workbook(File.Contents(FolderPath & "05_app_doctype_vendor_map.xlsx"), null, true),
    Sheet    = Source{[Item = "Mapping", Kind = "Sheet"]}[Data],
    Promoted = Table.PromoteHeaders(Sheet, [PromoteAllScalars = true]),
    // Blank cells come in as null; turn them into "" so the gap checks can test for empty text
    NoNulls  = Table.ReplaceValue(Promoted, null, "", Replacer.ReplaceValue,
                 {"PrintVendorID", "MailVendorID", "Owner"})
in
    NoNulls
