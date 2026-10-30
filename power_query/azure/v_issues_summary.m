// Pulls recon.v_issues_summary from Azure SQL. All logic lives in the database view;
// Excel only refreshes the result (Data -> Refresh All).
let
    Source = Sql.Database(ServerName, DatabaseName),
    View   = Source{[Schema = "recon", Item = "v_issues_summary"]}[Data],
    Sorted = Table.Sort(View, {{"IssueOrder", Order.Ascending}})
in
    Sorted
