let
    Source   = Excel.Workbook(File.Contents(FolderPath & "01_vendor_master.xlsx"), null, true),
    Sheet    = Source{[Item = "Vendors", Kind = "Sheet"]}[Data],
    Promoted = Table.PromoteHeaders(Sheet, [PromoteAllScalars = true]),
    Typed    = Table.TransformColumnTypes(Promoted, {
                 {"VendorID", type text}, {"VendorName", type text}, {"Category", type text},
                 {"PaymentTerms", type text}, {"Status", type text}, {"Province", type text}}),
    // "Net30" -> 30
    TermDays = Table.AddColumn(Typed, "TermDays",
                 each Number.From(Text.Select([PaymentTerms], {"0".."9"})), Int64.Type)
in
    TermDays
