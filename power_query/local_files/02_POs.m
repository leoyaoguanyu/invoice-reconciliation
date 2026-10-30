let
    Source   = Csv.Document(File.Contents(FolderPath & "02_purchase_orders.csv"),
                 [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Trimmed  = Table.TransformColumns(Promoted, {{"PO_Number", Text.Trim}, {"VendorID", Text.Trim}}),
    Typed    = Table.TransformColumnTypes(Trimmed, {
                 {"Approved_Amount", type number}, {"PO_Date", type date}}, "en-US")
in
    Typed
