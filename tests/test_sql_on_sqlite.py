"""Run the T-SQL scripts on SQLite (via a small dialect translation) and compare
every result with the Python pipeline in output/. This checks the SQL *logic*;
the scripts themselves are meant for Azure SQL Database.

Usage:  python python/reconcile.py && python tests/test_sql_on_sqlite.py
"""
import datetime as dt
import re
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "sql"


def tsql_date(text, style):
    if text is None:
        return None
    try:
        if style == 23:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
                return None
            return dt.date.fromisoformat(text).isoformat()
        if style == 107:
            return dt.datetime.strptime(text, "%b %d, %Y").date().isoformat()
    except ValueError:
        return None
    raise ValueError(style)


def tsql_dec(text):
    try:
        return round(float(text), 2)
    except (TypeError, ValueError):
        return None


def translate(batch: str) -> str:
    b = batch.replace("recon.", "")
    b = b.replace("CREATE OR ALTER VIEW", "CREATE VIEW")
    b = re.sub(r"TRY_CONVERT\(date,\s*(\w+),\s*(\d+)\)", r"tsql_date(\1, \2)", b)
    b = re.sub(r"TRY_CAST\((\w+)\s+AS decimal\(12,2\)\)", r"tsql_dec(\1)", b)
    b = re.sub(r"DATEADD\(day,\s*(COALESCE\([^)]*\)),\s*([\w.]+)\)", r"date(\2, '+' || \1 || ' days')", b)
    b = b.replace("SET NOCOUNT ON;", "")
    return b


def batches(path):
    return [b for b in re.split(r"^\s*GO\s*$", path.read_text(encoding="utf-8"), flags=re.M) if b.strip()]


def main():
    con = sqlite3.connect(":memory:")
    con.create_function("tsql_date", 2, tsql_date, deterministic=True)
    con.create_function("tsql_dec", 1, tsql_dec, deterministic=True)
    for f in ("01_create_tables.sql", "02_load_data.sql", "03_views.sql"):
        for b in batches(SQL / f):
            if "sys.schemas" in b or b.lstrip().startswith("DROP"):
                continue                      # schema/drop batches are Azure-only housekeeping
            con.executescript(translate(b))

    bad = con.execute("SELECT COUNT(*) FROM v_invoices_clean WHERE InvoiceDate IS NULL OR NetAmount IS NULL "
                      "OR Tax IS NULL OR InvoiceTotal IS NULL").fetchone()[0]
    sql_issues = pd.read_sql("SELECT * FROM v_issues_summary ORDER BY IssueOrder", con)
    py_issues = pd.read_csv(ROOT / "output" / "issues_summary.csv")
    sql_vs = pd.read_sql("SELECT * FROM v_vendor_summary", con)
    py_vs = pd.read_csv(ROOT / "output" / "vendor_summary.csv")
    checks = pd.read_sql("SELECT * FROM v_invoice_checks", con)

    ok = True
    print(f"unparsed values after cleaning: {bad}"); ok &= bad == 0
    for (_, s), (_, p) in zip(sql_issues.iterrows(), py_issues.iterrows()):
        same = int(s.IssueCount) == int(p.Count) and (
            pd.isna(p.DollarValue) or abs(float(s.DollarValue or 0) - p.DollarValue) < 0.005)
        ok &= same
        print(f"{'OK' if same else 'XX'}  {s.Issue:<42} sql={int(s.IssueCount):>3} py={int(p.Count):>3}  "
              f"${(s.DollarValue or 0):>11,.2f}")
    m = sql_vs.merge(py_vs, on="VendorID", suffixes=("_sql", "_py"))
    for col in ("Invoiced", "Paid", "Outstanding"):
        diff = (m[f"{col}_sql"] - m[f"{col}_py"]).abs().max()
        print(f"{'OK' if diff < 0.005 else 'XX'}  vendor {col:<12} max diff {diff:.4f}"); ok &= diff < 0.005
    n_issue = int((checks.IssueCount > 0).sum())
    print(f"{'OK' if n_issue == 42 else 'XX'}  invoices with an issue: {n_issue} of {len(checks)}")
    ok &= n_issue == 42 and len(sql_vs) == len(py_vs)
    print("\nALL CHECKS PASSED" if ok else "\nMISMATCH FOUND")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
