let
    Source   = Csv.Document(File.Contents(FolderPath & "04_bank_payments.csv"),
                 [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Typed    = Table.TransformColumnTypes(Promoted, {
                 {"PaidDate", type date}, {"PaidAmount", type number}}, "en-US"),
    // Bank file drops the hyphen on some references: "INV10041" -> "INV-10041"
    AddKey   = Table.AddColumn(Typed, "InvoiceNo_Key",
                 each if Text.Contains([InvoiceRef], "-") then [InvoiceRef]
                      else "INV-" & Text.Middle([InvoiceRef], 3), type text)
in
    AddKey
