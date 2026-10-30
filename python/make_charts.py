"""Draw the two README charts from output/*.csv (run reconcile.py first)."""
from pathlib import Path
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

ROOT = Path(__file__).resolve().parents[1]
OUT, IMG = ROOT / "output", ROOT / "images"
SURFACE, INK, INK2, GRID, SERIES = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df", "#2a78d6"
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "text.color": INK,
                     "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2})

def style(ax):
    ax.set_facecolor(SURFACE)
    for s in ("top", "right", "left"): ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.tick_params(length=0)

issues = pd.read_csv(OUT / "issues_summary.csv")
inv = issues[issues.DollarValue.notna() & (issues.Count > 0)].sort_values("Count")
fig, ax = plt.subplots(figsize=(8, 4.4), facecolor=SURFACE); style(ax)
bars = ax.barh(inv.Issue, inv.Count, height=0.6, color=SERIES)
for b, n in zip(bars, inv.Count):
    ax.text(b.get_width() + 0.3, b.get_y() + b.get_height() / 2, str(n), va="center", color=INK2)
ax.xaxis.grid(True, color=GRID, linewidth=0.8); ax.set_axisbelow(True)
ax.set_xlabel("Invoices or payments flagged"); ax.xaxis.set_major_locator(MaxNLocator(integer=True))
ax.set_title("Data-quality issues found (96 invoices, 68 payments)", loc="left", fontsize=12, fontweight="bold", pad=12)
fig.tight_layout(); fig.savefig(IMG / "issues_by_type.png", dpi=160); plt.close(fig)

vs = pd.read_csv(OUT / "vendor_summary.csv")
vs["Label"] = vs.VendorName.fillna("Not in master")
vs = vs[vs.Outstanding > 0.005].sort_values("Outstanding")
fig, ax = plt.subplots(figsize=(8, 4.4), facecolor=SURFACE); style(ax)
bars = ax.barh(vs.Label, vs.Outstanding / 1000, height=0.6, color=SERIES)
for b, v in zip(bars, vs.Outstanding):
    ax.text(b.get_width() + 0.8, b.get_y() + b.get_height() / 2, f"${v/1000:,.1f}K", va="center", color=INK2)
ax.xaxis.grid(True, color=GRID, linewidth=0.8); ax.set_axisbelow(True)
ax.set_xlabel("Outstanding balance (CAD thousands)")
ax.set_title("Outstanding balance by vendor, as of 2026-09-30", loc="left", fontsize=12, fontweight="bold", pad=12)
fig.tight_layout(); fig.savefig(IMG / "outstanding_by_vendor.png", dpi=160); plt.close(fig)
print("charts written")
