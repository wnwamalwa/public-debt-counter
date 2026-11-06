"""
Friday posts, in turn with the debt-per-person video: who Kenya owes.
Public debt by lender at the end of the latest fiscal year, at home
(domestic debt by holder) and abroad (external debt by creditor).

Figures: National Treasury, Annual Public Debt Report (APDR) 2025/26,
end June 2026:
  domestic  Table 6, Domestic Debt by Investor Category (KSh million)
  external  Table 10, External Debt Stock by Creditor Type (total and
            Eurobond holders, KSh million) and Figure 12, External Debt by
            Major Creditors (% of external debt)
  currency  Section 6.4, Currency Composition of External Debt (%)

Update LENDERS once a year, when the next APDR is out (usually October).

render_lenders(out_png)   the chart, with reading notes underneath
lenders_values()          the {placeholders} for the post text
"""
from __future__ import annotations

from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from render_terms import append_notes  # noqa: E402
from render_wed import DARK, DOM, EXT, GREY, _frame  # noqa: E402

LENDERS = {
    "fy": "FY 2025/26",
    "as_of": "June 2026",
    "source": "National Treasury, Annual Public Debt Report 2025/26 (Tables 6 and 10, Figure 12)",
    # KSh billion, end June 2026 (APDR Table 6)
    "domestic": [
        ("Commercial banks", 2538.622),
        ("Pension funds", 1028.357),
        ("Insurance companies", 1009.762),
        ("Other investors", 919.400),
        ("Government bodies", 894.573),
        ("Households", 451.180),
        ("Non-residents", 297.411),
        ("Central Bank of Kenya", 187.897),
    ],
    "domestic_total": 7327.202,
    "external_total": 5793.666,  # APDR Table 10, incl. guaranteed debt
    "eurobonds": 1361.431,       # APDR Table 10, ISB holders
    # % of external debt (APDR Figure 12)
    "external_pct": [
        ("World Bank (IDA)", 30.5),
        ("Eurobond holders", 23.5),
        ("China", 10.7),
        ("African Development Bank", 9.8),
        ("IMF", 7.8),
        ("World Bank (IBRD)", 5.3),
        ("Japan", 2.6),
        ("France", 1.7),
        ("Trade and Development Bank", 1.4),
        ("Other bilateral", 3.1),
        ("Other commercial", 1.8),
        ("Other multilateral", 1.6),
        ("Suppliers' credit", 0.2),
    ],
    "shown_external": 6,  # the rest are grouped as "Other external lenders"
    "currency_pct": [("US dollar", 54.9), ("Euro", 26.5), ("Chinese yuan", 11.5), ("Japanese yen", 4.7),
                     ("Pound sterling", 2.3)],
}


def _external(d: dict = LENDERS) -> list[tuple[str, float]]:
    out = []
    for name, pct in d["external_pct"]:
        amt = d["eurobonds"] if name == "Eurobond holders" else pct / 100 * d["external_total"]
        out.append((name, amt))
    return out


def _bars(d: dict = LENDERS) -> list[tuple[str, float, str]]:
    ext = _external(d)
    k = d["shown_external"]
    rows = [(n, a, "dom") for n, a in d["domestic"]] + [(n, a, "ext") for n, a in ext[:k]]
    rows.sort(key=lambda r: -r[1])
    rows.append(("Other external lenders", sum(a for _, a in ext[k:]), "ext"))
    return rows


def _money(bn: float) -> str:
    return f"KSh {bn / 1000:.2f} tn" if bn >= 1000 else f"KSh {bn:,.0f} bn"


def lenders_values(d: dict = LENDERS) -> dict:
    total = d["domestic_total"] + d["external_total"]
    ext = dict(_external(d))
    dom = dict(d["domestic"])
    cur = dict(d["currency_pct"])
    return {
        "lenders_as_of": d["as_of"],
        "lenders_fy": d["fy"],
        "lenders_total": _money(total),
        "dom_total": _money(d["domestic_total"]),
        "ext_total": _money(d["external_total"]),
        "dom_share": f"{d['domestic_total'] / total * 100:.0f}%",
        "ext_share": f"{d['external_total'] / total * 100:.0f}%",
        "banks": _money(dom["Commercial banks"]),
        "banks_share": f"{dom['Commercial banks'] / d['domestic_total'] * 100:.0f}%",
        "pensions": _money(dom["Pension funds"]),
        "ida": _money(ext["World Bank (IDA)"]),
        "isb": _money(ext["Eurobond holders"]),
        "china": _money(ext["China"]),
        "usd_share": f"{cur['US dollar']:.0f}%",
    }


def lenders_notes(d: dict = LENDERS) -> list[str]:
    v = lenders_values(d)
    total = d["domestic_total"] + d["external_total"]
    ext = dict(_external(d))
    others = ", ".join(n if n[0] in "JFT" else n.lower() for n, _ in d["external_pct"][d["shown_external"]:])
    cur = ", ".join(f"{n} {p:g}%" for n, p in d["currency_pct"][:3])
    return [
        f"Each bar is what the Government owed that lender at the end of {d['as_of']}, in KSh billion. Left (blue): "
        f"lenders in Kenya (domestic debt). Right (orange): lenders abroad (external debt). Both panels use the same "
        "scale, so bars can be compared across them.",
        f"The strip at the top splits the total of {_money(total)}: {v['dom_share']} owed at home ({v['dom_total']}) "
        f"and {v['ext_share']} abroad ({v['ext_total']}). This is the Treasury's definition, which includes "
        "government-guaranteed external debt; CBK's figure for the same date (KSh 13.01 tn) is lower, partly for that reason.",
        f"Domestic lenders mostly hold Treasury bills and bonds. Commercial banks are the largest single lender, with "
        f"{v['banks']} ({v['banks_share']} of domestic debt). Government bodies include parastatals and public pension "
        "funds; other investors include companies, investment banks and money market funds.",
        f"IDA and IBRD are both parts of the World Bank; together they are owed {_money(ext['World Bank (IDA)'] + ext['World Bank (IBRD)'])}. "
        "Eurobond holders are investors in Kenya's international sovereign bonds. China is mainly the Export-Import "
        "Bank of China, which financed the SGR among other projects.",
        f"External amounts are each lender's share of external debt (APDR Figure 12) applied to the external total; "
        f"Eurobonds are as reported. Other external lenders: {others}.",
        f"External debt is owed in foreign currency ({cur}), so a weaker shilling raises what Kenya owes in shillings "
        f"even without new borrowing.",
        f"These are {d['fy']} year-end figures. The live counter is higher today because borrowing has continued since "
        f"{d['as_of']}.",
    ]


def render_lenders(out_png: Path, d: dict = LENDERS) -> Path:
    v = lenders_values(d)
    total = d["domestic_total"] + d["external_total"]
    ext = _external(d)
    k = d["shown_external"]
    dom_rows = sorted(d["domestic"], key=lambda r: -r[1])
    ext_rows = sorted(ext[:k], key=lambda r: -r[1]) + [("Other external lenders", sum(a for _, a in ext[k:]))]
    take = (f"{v['dom_share']} of Kenya's public debt is owed to lenders at home. Commercial banks are the "
            f"largest single lender ({v['banks']}).")
    fig = _frame(f"Who Kenya owes: public debt by lender, end {d['as_of']} (KSh billion)", take, [
        f"Source: {d['source']}. Domestic: by holder; external: by creditor, incl. guaranteed debt.",
        "Kenya Debt Counter (kenyadebtcounter.vercel.app), Institute of Economic Affairs Kenya. Both panels use the same scale.",
    ])
    fig.set_size_inches(8, 5.6)
    # split strip
    sx = fig.add_axes([0.2, 0.765, 0.75, 0.04])
    dp = d["domestic_total"] / total * 100
    sx.barh(0, dp, color=DOM, height=1, edgecolor="white", lw=1.2)
    sx.barh(0, 100 - dp, left=dp, color=EXT, height=1, edgecolor="white", lw=1.2)
    sx.text(dp / 2, 0, f"At home {dp:.1f}%", ha="center", va="center", fontsize=8.4, fontweight="bold", color="white")
    sx.text(dp + (100 - dp) / 2, 0, f"Abroad {100 - dp:.1f}%", ha="center", va="center", fontsize=8.4,
            fontweight="bold", color="white")
    sx.set_xlim(0, 100)
    sx.axis("off")
    fig.text(0.19, 0.785, f"Total {_money(total)}", ha="right", va="center", fontsize=8.6, fontweight="bold",
             color=DARK)
    top = max(a for _, a in dom_rows + ext_rows)
    n = max(len(dom_rows), len(ext_rows))
    panels = [(0.2, dom_rows, DOM, f"Lenders in Kenya: {v['dom_total']}"),
              (0.695, ext_rows, EXT, f"Lenders abroad: {v['ext_total']}")]
    for x0, rows, c, head in panels:
        ax = fig.add_axes([x0, 0.165, 0.255, 0.5])
        fig.text(x0 - 0.17 if x0 < 0.5 else x0 - 0.185, 0.705, head, fontsize=9.6, fontweight="bold", color=c,
                 va="center")
        for i, (name, amt) in enumerate(rows):
            y = n - 1 - i
            ax.barh(y, amt, color=c, height=0.68)
            ax.text(amt + top * 0.02, y, f"{amt:,.0f}", ha="left", va="center", fontsize=7.6, fontweight="bold",
                    color=DARK)
            ax.text(-top * 0.025, y, name, ha="right", va="center", fontsize=7.9, color=DARK,
                    fontweight="bold" if amt >= 1000 else "normal")
        ax.set_xlim(0, top * 1.17)
        ax.set_ylim(-0.6, n - 0.4)
        ax.set_yticks([])
        ticks = list(range(0, int(top) + 1, 1000))
        ax.set_xticks(ticks)
        ax.set_xticklabels([f"{t:,}" for t in ticks], fontsize=7.3, color="#64748b")
        ax.tick_params(axis="x", length=0)
        ax.grid(True, axis="x", color="#e5e7eb", lw=0.8)
        ax.set_axisbelow(True)
        for side in ("top", "right", "left", "bottom"):
            ax.spines[side].set_visible(False)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=200, facecolor="white")
    plt.close(fig)
    append_notes(out_png, "How to read this chart", lenders_notes(d))
    return out_png


if __name__ == "__main__":
    import json
    import sys
    p = render_lenders(Path(sys.argv[1] if len(sys.argv) > 1 else "lenders.png"))
    print(p)
    print(json.dumps(lenders_values(), indent=1))
