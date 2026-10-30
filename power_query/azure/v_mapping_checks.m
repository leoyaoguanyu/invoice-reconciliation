// Pulls recon.v_mapping_checks from Azure SQL. All logic lives in the database view;
// Excel only refreshes the result (Data -> Refresh All).
let
    Source = Sql.Database(ServerName, DatabaseName),
    View   = Source{[Schema = "recon", Item = "v_mapping_checks"]}[Data]
in
    View
