// Pulls recon.v_vendor_summary from Azure SQL. All logic lives in the database view;
// Excel only refreshes the result (Data -> Refresh All).
let
    Source = Sql.Database(ServerName, DatabaseName),
    View   = Source{[Schema = "recon", Item = "v_vendor_summary"]}[Data],
    Sorted = Table.Sort(View, {{"Outstanding", Order.Descending}})
in
    Sorted
