"""Vendor invoice reconciliation – Python version of the Excel checks.

Reads the five raw files, cleans them, runs the same validation checks as the
Excel workbook and writes:
  output/invoice_checks.csv   one row per invoice with every flag
  output/issues_summary.csv   count and dollar value per issue type
  output/vendor_summary.csv   invoiced / paid / outstanding per vendor

Usage:  python python/reconcile.py            (run from the repo root)
"""
from __future__ import annotations

import datetime as dt
import re
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
OUT = ROOT / "output"
AS_OF = dt.date(2026, 9, 30)
TAX_RATE = {"ON": 0.13, "QC": 0.14975, "BC": 0.12, "AB": 0.05}  # assumption for this exercise


# ---------- cleaning helpers ----------
def to_number(text: str) -> float:
    """'$7,976.03' / ' 7,070.60 ' / '2199.23' -> 7976.03"""
    return float(re.sub(r"[^\d.\-]", "", text))


def to_date(text: str) -> dt.date:
    """'2026-05-16' / '2026/06/10' / 'Sep 05, 2026' -> date"""
    text = text.strip()
    for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%b %d, %Y"):
        try:
            return dt.datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    raise ValueError(f"Unrecognised date: {text!r}")


def normalise_ref(ref: str) -> str:
    """Bank file drops the hyphen: 'INV10041' -> 'INV-10041'"""
    return ref if "-" in ref else "INV-" + ref[3:]


# ---------- load ----------
def load():
    vendors = pd.read_excel(RAW / "01_vendor_master.xlsx")
    vendors["TermDays"] = vendors.PaymentTerms.str.extract(r"(\d+)").astype(int)
    vendors["TaxRate"] = vendors.Province.map(TAX_RATE)

    pos = pd.read_csv(RAW / "02_purchase_orders.csv")

    ap = pd.read_csv(RAW / "03_ap_invoices_export.csv", dtype=str, keep_default_na=False)
    inv = pd.DataFrame({
        "InvoiceNo": ap["Invoice #"].str.strip(),
        "VendorRaw": ap["Vendor"],
        "VendorKey": ap["Vendor"].str.strip().str.upper(),
        "PO_Number": ap["PO"].str.strip(),
        "InvoiceDate": pd.to_datetime(ap["Invoice Date"].map(to_date)),
        "NetAmount": ap["Net Amount"].map(to_number),
        "Tax": ap["Tax"].map(to_number),
        "InvoiceTotal": ap["Invoice Total"].map(to_number),
    })

    pay = pd.read_csv(RAW / "04_bank_payments.csv")
    pay["InvoiceNo_Key"] = pay.InvoiceRef.map(normalise_ref)

    mapping = pd.read_excel(RAW / "05_app_doctype_vendor_map.xlsx").fillna("")
    aliases = pd.read_csv(RAW.parent / "reference" / "vendor_aliases.csv")
    return vendors, pos, inv, pay, mapping, aliases


# ---------- checks ----------
def run_checks(vendors, pos, inv, pay, mapping, aliases):
    v = vendors.set_index("VendorID")
    po = pos.set_index("PO_Number")
    alias = dict(zip(aliases.AliasKey, aliases.VendorID))

    c = inv.copy()
    c["VendorID"] = c.VendorKey.map(alias).fillna("UNKNOWN")
    c["VendorStatus"] = c.VendorID.map(v.Status).fillna("")
    c["PO_VendorID"] = c.PO_Number.map(po.VendorID)
    c["PO_Approved"] = c.PO_Number.map(po.Approved_Amount)
    c["DueDate"] = c.InvoiceDate + pd.to_timedelta(c.VendorID.map(v.TermDays).fillna(30), unit="D")
    c["Is_Duplicate"] = c.duplicated("InvoiceNo").astype(int)

    first = c[c.Is_Duplicate == 0]
    po_invoiced = first[first.PO_Number != ""].groupby("PO_Number").NetAmount.sum()
    c["PO_Invoiced_ToDate"] = c.PO_Number.map(po_invoiced)
    c["PaidAmount"] = c.InvoiceNo.map(pay.groupby("InvoiceNo_Key").PaidAmount.sum()).fillna(0.0)
    expected_tax = (c.NetAmount * c.VendorID.map(v.TaxRate)).round(2)
    has_po = c.PO_Number != ""
    known_po = c.PO_Number.isin(po.index)
    not_dup = c.Is_Duplicate == 0

    flags = {
        "Flag_UnknownVendor":     c.VendorID == "UNKNOWN",
        "Flag_MissingPO":         ~has_po,
        "Flag_PO_NotFound":       has_po & ~known_po,
        "Flag_PO_VendorMismatch": known_po & (c.PO_VendorID != c.VendorID),
        "Flag_OverPO":            not_dup & known_po & (c.PO_Invoiced_ToDate > c.PO_Approved),
        "Flag_TotalMismatch":     (c.NetAmount + c.Tax - c.InvoiceTotal).abs() > 0.01,
        "Flag_TaxRate":           expected_tax.notna() & ((c.Tax - expected_tax).abs() > 0.01),
        "Flag_InactiveVendor":    c.VendorStatus == "Inactive",
        "Flag_PaymentMismatch":   not_dup & (c.PaidAmount > 0) & ((c.PaidAmount - c.InvoiceTotal).abs() > 0.01),
        "Flag_OverdueUnpaid":     not_dup & (c.PaidAmount == 0) & (c.DueDate < pd.Timestamp(AS_OF)),
    }
    for name, mask in flags.items():
        c[name] = mask.astype(int)
    flag_cols = ["Is_Duplicate", *flags]
    c["IssueCount"] = c[flag_cols].sum(axis=1)

    # payment and mapping checks
    orphan = ~pay.InvoiceNo_Key.isin(c.InvoiceNo)
    inactive = set(vendors.loc[vendors.Status == "Inactive", "VendorID"])
    map_flags = {
        "Mapping row missing mail vendor": (mapping.MailVendorID == "").sum(),
        "Mapping row missing owner": (mapping.Owner == "").sum(),
        "Mapping row uses an Inactive vendor":
            (mapping.PrintVendorID.isin(inactive) | mapping.MailVendorID.isin(inactive)).sum(),
    }
    return c, flag_cols, orphan, pay, map_flags


def summarise(c, flag_cols, orphan, pay, map_flags, vendors):
    labels = {
        "Is_Duplicate": "Duplicate invoice",
        "Flag_UnknownVendor": "Vendor not in vendor master",
        "Flag_MissingPO": "Invoice has no PO number",
        "Flag_PO_NotFound": "PO number not found in PO system",
        "Flag_PO_VendorMismatch": "Invoice vendor differs from PO vendor",
        "Flag_OverPO": "Cumulative invoices exceed PO amount",
        "Flag_TotalMismatch": "Net + Tax does not equal Invoice Total",
        "Flag_TaxRate": "Tax not at expected provincial rate",
        "Flag_InactiveVendor": "Invoice from Inactive vendor",
        "Flag_PaymentMismatch": "Paid amount differs from invoice total",
        "Flag_OverdueUnpaid": "Unpaid and past due",
    }
    value_col = {"Flag_TaxRate": "Tax", "Flag_PaymentMismatch": "PaidAmount"}
    rows = [(labels[f], int(c[f].sum()), round(c.loc[c[f] == 1, value_col.get(f, "InvoiceTotal")].sum(), 2))
            for f in flag_cols]
    rows.append(("Payment with no matching invoice", int(orphan.sum()), round(pay.loc[orphan, "PaidAmount"].sum(), 2)))
    rows += [(k, int(n), None) for k, n in map_flags.items()]
    issues = pd.DataFrame(rows, columns=["Issue", "Count", "DollarValue"])

    first = c[c.Is_Duplicate == 0]
    vs = (first.groupby("VendorID")
               .agg(Invoices=("InvoiceNo", "count"), Invoiced=("InvoiceTotal", "sum"),
                    Paid=("PaidAmount", "sum"))
               .reset_index())
    vs["Outstanding"] = vs.Invoiced - vs.Paid
    vs["InvoicesWithIssues"] = vs.VendorID.map(c[c.IssueCount > 0].groupby("VendorID").size()).fillna(0).astype(int)
    vs = vs.merge(vendors[["VendorID", "VendorName", "Status"]], on="VendorID", how="left").round(2)
    return issues, vs.sort_values("Outstanding", ascending=False)


def main():
    vendors, pos, inv, pay, mapping, aliases = load()
    c, flag_cols, orphan, pay, map_flags = run_checks(vendors, pos, inv, pay, mapping, aliases)
    issues, vs = summarise(c, flag_cols, orphan, pay, map_flags, vendors)

    OUT.mkdir(exist_ok=True)
    c.to_csv(OUT / "invoice_checks.csv", index=False)
    issues.to_csv(OUT / "issues_summary.csv", index=False)
    vs.to_csv(OUT / "vendor_summary.csv", index=False)

    print(issues.to_string(index=False))
    print(f"\nInvoices with at least one issue: {(c.IssueCount > 0).sum()} of {len(c)}")
    print(f"Invoiced (excl. duplicates): ${vs.Invoiced.sum():,.2f}   Outstanding: ${vs.Outstanding.sum():,.2f}")


if __name__ == "__main__":
    main()
