"""Generate the synthetic raw data (fixed seed, so output is identical every run)."""
import random, json, datetime as dt
import pandas as pd
from pathlib import Path
RAW = Path(__file__).resolve().parents[1] / "data" / "raw"
RAW.mkdir(parents=True, exist_ok=True)
random.seed(42)
ASOF = dt.date(2026,9,30)
vendors = [
 ("V001","Northbridge Print Services","Print","Net30","Active","ON"),
 ("V002","Maple Mailing Solutions","Mail Processing","Net30","Active","ON"),
 ("V003","Lakeshore Envelope Co.","Envelope Supply","Net45","Active","ON"),
 ("V004","Summit Digital Print Inc.","Print","Net30","Active","QC"),
 ("V005","Harbourview Postage Ltd.","Postage","Net15","Active","ON"),
 ("V006","Cedarline Paper Supply","Paper","Net45","Active","ON"),
 ("V007","Redwood Document Services","Print","Net30","Inactive","BC"),
 ("V008","ClearPath Fulfillment","Fulfillment","Net30","Active","ON"),
 ("V009","Granite Press Ltd.","Print","Net60","Active","AB"),
 ("V010","Bluewater Data Mail","Mail Processing","Net30","Inactive","ON"),
]
vdf = pd.DataFrame(vendors, columns=["VendorID","VendorName","Category","PaymentTerms","Status","Province"])
tax = {"ON":0.13,"QC":0.14975,"BC":0.12,"AB":0.05}
variants = {
 "V001":["Northbridge Print Services","NORTHBRIDGE PRINT SERVICES","Northbridge Print","Northbridge Print Services Inc "],
 "V002":["Maple Mailing Solutions","Maple Mailing","MAPLE MAILING SOLUTIONS "],
 "V003":["Lakeshore Envelope Co.","Lakeshore Envelope Company","lakeshore envelope co."],
 "V004":["Summit Digital Print Inc.","Summit Digital Print","SUMMIT DIGITAL PRINT INC."],
 "V005":["Harbourview Postage Ltd.","Harbourview Postage","Harbor View Postage Ltd."],
 "V006":["Cedarline Paper Supply","Cedarline Paper","CEDARLINE PAPER SUPPLY"],
 "V007":["Redwood Document Services","Redwood Docs"],
 "V008":["ClearPath Fulfillment","Clear Path Fulfillment","CLEARPATH FULFILMENT"],
 "V009":["Granite Press Ltd.","Granite Press","GRANITE PRESS LTD"],
 "V010":["Bluewater Data Mail","Bluewater Datamail"],
}
apps = ["Individual Insurance","Group Benefits","Group Retirement","Wealth & Asset Mgmt","Banking"]
docs = {"Print":["Annual Statement","Policy Package","Tax Slip (T4A/T5)","Renewal Notice","Welcome Kit"],
        "Mail Processing":["Mail Insertion"],"Envelope Supply":["Envelopes"],"Postage":["Postage"],
        "Paper":["Paper Stock"],"Fulfillment":["Welcome Kit"]}
pos=[]; pn=4500
for i in range(60):
    v = vendors[6] if i<2 else vendors[9] if i<4 else random.choice(vendors[:6]+vendors[7:9])
    pn+=random.randint(1,4)
    d = dt.date(2026,1,5)+dt.timedelta(days=random.randint(0,220))
    pos.append(dict(PO_Number=f"PO-{pn}",VendorID=v[0],Application=random.choice(apps),
        DocumentType=random.choice(docs[v[2]]),Approved_Amount=round(random.randint(40,400)*50,2),
        PO_Date=d.isoformat(),Approver=random.choice(["T. Abebe","R. Singh","M. Chen","L. Martin"])))
podf=pd.DataFrame(pos)
inv=[]; n=10000
over_po = set(random.sample(list(podf.PO_Number[4:]),4))
for _,p in podf.iterrows():
    k = 2 if random.random()<0.45 else 1
    share = [1.0] if k==1 else [0.5,0.4]
    for s in share:
        n+=random.randint(1,3)
        frac = s*random.uniform(0.85,0.99)
        if p.PO_Number in over_po: frac = s*1.18 if k==1 else s*1.3
        amt = round(p.Approved_Amount*frac,2)
        prov = vdf.set_index("VendorID").Province[p.VendorID]
        t = round(amt*tax[prov],2)
        d = dt.date.fromisoformat(p.PO_Date)+dt.timedelta(days=random.randint(5,40))
        if d>ASOF: d=ASOF-dt.timedelta(days=random.randint(0,5))
        inv.append(dict(InvoiceNo=f"INV-{n}",VendorID=p.VendorID,PO_Number=p.PO_Number,InvoiceDate=d,Amount=amt,Tax=t,Total=round(amt+t,2)))
idf=pd.DataFrame(inv)
miss = random.sample(range(len(idf)),6); idf.loc[miss,"PO_Number"]=""
cand=[i for i in range(len(idf)) if i not in miss]
taxm = random.sample(cand,4)
for i in taxm: idf.loc[i,"Total"]=round(idf.loc[i,"Total"]+random.choice([25,-40,112.5,60]),2)
idf["VendorRaw"]=[random.choice(variants[v]) for v in idf.VendorID]
extra=[]
for nm in ["Apex Print Partners","QuickPost Couriers"]:
    n+=2; a=round(random.uniform(1500,6000),2); t=round(a*0.13,2)
    extra.append(dict(InvoiceNo=f"INV-{n}",VendorID=None,VendorRaw=nm,PO_Number="",InvoiceDate=dt.date(2026,8,random.randint(1,28)),Amount=a,Tax=t,Total=round(a+t,2)))
idf=pd.concat([idf,pd.DataFrame(extra)],ignore_index=True)
dups = random.sample(cand,4)
idf=pd.concat([idf,idf.loc[dups].copy()],ignore_index=True).sample(frac=1,random_state=7).reset_index(drop=True)
pay=[]; pr=880000
unique_inv = idf.drop_duplicates("InvoiceNo")
termdays = {r.VendorID:int(r.PaymentTerms[3:]) for r in vdf.itertuples()}
paymm=[]
for r in unique_inv.itertuples():
    terms = termdays.get(r.VendorID,30)
    if random.random()<0.78:
        pd_ = r.InvoiceDate+dt.timedelta(days=random.randint(max(5,terms-10),terms+5))
        if pd_>ASOF: continue
        amt=r.Total
        if random.random()<0.06 and len(paymm)<5:
            amt=round(r.Total*random.choice([0.5,0.9,1.1]),2); paymm.append(r.InvoiceNo)
        pr+=random.randint(1,9)
        ref = r.InvoiceNo if random.random()<0.7 else r.InvoiceNo.replace("-","")
        pay.append(dict(PaymentRef=f"EFT{pr}",InvoiceRef=ref,PaidDate=pd_.isoformat(),PaidAmount=amt,Currency="CAD"))
for ref in ["INV-99001","INV99017"]:
    pr+=5; pay.append(dict(PaymentRef=f"EFT{pr}",InvoiceRef=ref,PaidDate="2026-09-12",PaidAmount=round(random.uniform(800,3000),2),Currency="CAD"))
paydf=pd.DataFrame(pay).sample(frac=1,random_state=3).reset_index(drop=True)
def fmt_date(d): return random.choice([d.isoformat(), d.strftime("%b %d, %Y"), d.strftime("%Y/%m/%d")])
def fmt_amt(a): return random.choice([f"{a:.2f}", f"${a:,.2f}", f" {a:,.2f} "])
ap = pd.DataFrame({"Invoice #":idf.InvoiceNo,"Vendor":idf.VendorRaw,"PO":idf.PO_Number,
    "Invoice Date":[fmt_date(d) for d in idf.InvoiceDate],"Net Amount":[fmt_amt(a) for a in idf.Amount],
    "Tax":idf.Tax.map(lambda x:f"{x:.2f}"),"Invoice Total":[fmt_amt(a) for a in idf.Total],"Currency":"CAD"})
ap.to_csv(RAW / "03_ap_invoices_export.csv",index=False)
vdf.to_excel(RAW / "01_vendor_master.xlsx",index=False,sheet_name="Vendors")
podf.to_csv(RAW / "02_purchase_orders.csv",index=False)
paydf.to_csv(RAW / "04_bank_payments.csv",index=False)
mp=[]
for a in apps:
    for dtp in ["Annual Statement","Policy Package","Tax Slip (T4A/T5)","Renewal Notice","Welcome Kit"]:
        if random.random()<0.6:
            mp.append(dict(Application=a,DocumentType=dtp,PrintVendorID=random.choice(["V001","V004","V009","V007"]),
                MailVendorID=random.choice(["V002","V002","V010",""]),Owner=random.choice(["Production Ops","Vendor Governance",""])))
pd.DataFrame(mp).to_excel(RAW / "05_app_doctype_vendor_map.xlsx",index=False,sheet_name="Mapping")
print("raw files written to", RAW)
