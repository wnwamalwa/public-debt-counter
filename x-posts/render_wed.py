"""
Wednesday posts, in turn: Kenya's debt service in the latest fiscal year, and
when the domestic debt falls due (end June of that year). Same data as Chart 6
on the dashboard (Debt service and Maturity views):

  service:  /api/debt/service (National Treasury, Annual Public Debt Reports,
            via the `debt_service` tab of the IEA sheet)
  maturity: /api/debt/site-inputs (Annual Public Debt Report figures entered
            in the site's `site_inputs` table)

render_service(row, out_png)       row = the latest year from /api/debt/service
render_maturity(inputs, out_png)   inputs = rows from /api/debt/site-inputs
"""
from __future__ import annotations

from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402
from PIL import Image  # noqa: E402

HERE = Path(__file__).resolve().parent
HEADER = "#15803d"
DARK = "#0b0b0b"
GREY = "#52514e"
EXT, EXT_L = "#e85d2f", "#f2a888"
DOM, DOM_L = "#2a6fd6", "#8fb6ea"
TOT, TOT_L = "#1ba672", "#86d3b2"
APDR_BUCKETS = [("lt1", "Within 1 year", "#b91c1c"), ("1_5", "1 to 5 years", "#eb6834"),
                ("6_9", "6 to 9 years", "#96bcea"), ("ge10", "10 years or more", "#2a78d6")]


def _font_family() -> list[str]:
    have = {f.name for f in font_manager.fontManager.ttflist}
    return [n for n in ("Inter", "Arial", "Helvetica", "DejaVu Sans") if n in have] or ["sans-serif"]


def _frame(title: str, takeaway: str, source_lines: list[str]):
    plt.rcParams.update({"font.family": _font_family(), "font.size": 11})
    fig = plt.figure(figsize=(8, 5), dpi=200)
    fig.patch.set_facecolor("white")
    fig.add_artist(plt.Rectangle((0, 0.915), 1, 0.085, transform=fig.transFigure, color=HEADER, zorder=5))
    fig.text(0.5, 0.957, title, fontsize=12, fontweight="bold", color="white", ha="center", va="center", zorder=6)
    fig.add_artist(plt.Rectangle((0, 0.845), 1, 0.07, transform=fig.transFigure, color="#ecfdf3", zorder=4))
    fig.text(0.5, 0.88, takeaway, fontsize=9.6, fontweight="bold", color="#14532d", ha="center", va="center",
             zorder=6, wrap=True)
    logo = HERE / "assets" / "iea-kenya.png"
    if logo.exists():
        lax = fig.add_axes([0.01, 0.012, 0.075, 0.075])
        lax.imshow(Image.open(logo))
        lax.axis("off")
    for i, line in enumerate(source_lines):
        fig.text(0.095, 0.062 - i * 0.024, line, fontsize=6.8 if len(line) > 150 else 7.1, color=GREY, va="center")
    return fig


def _fy(fy: str) -> str:  # "FY2025/26" -> "FY 2025/26"
    return fy.replace("FY", "FY ") if fy.startswith("FY") and not fy.startswith("FY ") else fy


def service_values(r: dict) -> dict:
    total = r["total"]
    v = {
        "service_fy": _fy(r["fiscal_year"]),
        "service_total": f"KSh {total / 1e9:,.0f} billion",
        "service_principal": f"KSh {r['principal'] / 1e9:,.0f} billion",
        "service_interest": f"KSh {r['interest'] / 1e9:,.0f} billion",
        "service_interest_share": f"{r['interest'] / total * 100:.0f}%",
        "service_domestic_share": f"{r['domestic'] / total * 100:.0f}%",
        "service_pct_gdp": f"{total / r['gdp'] * 100:.1f}%" if r.get("gdp") else None,
        "service_pct_revenue": f"{total / r['revenue'] * 100:.1f}%" if r.get("revenue") else None,
        "service_per_100": f"KSh {round(total / r['revenue'] * 100)}" if r.get("revenue") else None,
    }
    return v


def render_service(r: dict, out_png: Path) -> Path:
    v = service_values(r)
    total = r["total"]
    take = (f"In {v['service_fy']}, debt service took {v['service_pct_revenue']} of ordinary revenue: "
            f"{v['service_per_100']} of every KSh 100 collected." if v["service_pct_revenue"]
            else f"In {v['service_fy']}, Kenya spent {v['service_total']} servicing its public debt.")
    fig = _frame(f"Kenya's public debt service, {v['service_fy']} (% of total debt service)", take, [
        f"Source: National Treasury, Annual Public Debt Report {v['service_fy']} (debt service); ordinary revenue: National "
        "Treasury; GDP: KNBS.",
        "Kenya Debt Counter (kenyadebtcounter.vercel.app), Institute of Economic Affairs Kenya. Principal = repayments; "
        "interest = interest and other charges.",
    ])
    ax = fig.add_axes([0.13, 0.36, 0.72, 0.43])
    bars = [("External", r["external_principal"], r["external_interest"], EXT, EXT_L),
            ("Domestic", r["domestic_principal"], r["domestic_interest"], DOM, DOM_L),
            ("Total", r["principal"], r["interest"], TOT, TOT_L)]
    for i, (name, p, it, c, cl) in enumerate(bars):
        y = 2.25 - i if i < 2 else 0
        pp, ip = p / total * 100, it / total * 100
        ax.barh(y, pp, color=c, height=0.62, edgecolor="white", lw=1.2)
        ax.barh(y, ip, left=pp, color=cl, height=0.62, edgecolor="white", lw=1.2)
        if pp > 5:
            ax.text(pp / 2, y, f"{pp:.1f}%", ha="center", va="center", fontsize=9, fontweight="bold", color="white")
        if ip > 5:
            ax.text(pp + ip / 2, y, f"{ip:.1f}%", ha="center", va="center", fontsize=9, fontweight="bold", color=DARK)
        ax.text(pp + ip + 1.2, y, f"{pp + ip:.1f}%", ha="left", va="center", fontsize=9, fontweight="bold", color=DARK)
        ax.text(-1.5, y, name, ha="right", va="center", fontsize=10, fontweight="bold", color=DARK)
    ax.axhline(0.62, color="#9aa19c", lw=0.8)
    ax.set_xlim(0, 100)
    ax.set_ylim(-0.5, 2.7)
    ax.set_yticks([])
    ax.set_xticks(range(0, 101, 20))
    ax.set_xticklabels([f"{t}%" for t in range(0, 101, 20)], fontsize=8, color="#64748b")
    ax.tick_params(axis="x", length=0)
    ax.grid(True, axis="x", color="#e5e7eb", lw=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left", "bottom"):
        ax.spines[side].set_visible(False)
    fig.text(0.13, 0.81, "Darker: principal (repayments)   Lighter: interest", fontsize=7.8, color=GREY, va="center")
    # key figures
    boxes = [(v["service_total"], "debt service in total"), (v["service_principal"], "principal"),
             (v["service_interest"], f"interest ({v['service_interest_share']})"),
             (v["service_pct_gdp"] or "–", "of GDP"), (v["service_pct_revenue"] or "–", "of ordinary revenue")]
    for i, (n, l) in enumerate(boxes):
        x0 = 0.04 + i * 0.19
        fig.add_artist(plt.Rectangle((x0, 0.135), 0.175, 0.15, transform=fig.transFigure, fc="white", ec="#dfe4e0", lw=0.9))
        fig.text(x0 + 0.0875, 0.235, n, ha="center", va="center", fontsize=10.5, fontweight="bold", color=DARK)
        fig.text(x0 + 0.0875, 0.175, l, ha="center", va="center", fontsize=7.6, color=GREY)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=200, facecolor="white")
    plt.close(fig)
    return out_png


def _fy_of(y: int) -> str:
    return f"FY {y - 1}/{str(y)[2:]}"


def maturity_data(rows: list[dict]) -> dict | None:
    """All years of the APDR maturity figures (end June), for the trend picture."""
    def at(series: str, period: str):
        return next((float(r["value"]) for r in rows if r["series"] == series and str(r["period"]) == period), None)
    mix_years = sorted({str(r["period"]) for r in rows if r["series"] == "apdr_mat_lt1"})
    mix_years = [y for y in mix_years if all(at(f"apdr_mat_{k}", y) is not None for k, _, _ in APDR_BUCKETS)]
    due_years = sorted({str(r["period"]) for r in rows if r["series"] == "apdr_due1y_gdp_total"})
    if not mix_years or not due_years:
        return None
    y = mix_years[-1]
    src = next(r for r in rows if r["series"] == "apdr_mat_lt1" and str(r["period"]) == y)
    d = {"year": int(y),
         "mix": [{"year": int(m), "pct": {k: at(f"apdr_mat_{k}", m) for k, _, _ in APDR_BUCKETS}} for m in mix_years],
         "due": [{"year": int(m), **{k: at(f"apdr_due1y_gdp_{k}", m) for k in ("external", "domestic", "total")}}
                 for m in due_years],
         "atm": {int(m): at("apdr_atm_total", m) for m in due_years if at("apdr_atm_total", m) is not None},
         "atm_dom": {int(m): at("apdr_atm_domestic", m) for m in due_years if at("apdr_atm_domestic", m) is not None},
         "due_share": at("apdr_due1y_total", y),
         "source": src.get("source", "National Treasury, Annual Public Debt Report")}
    pdd = [r for r in rows if r["series"] == "principal_due_domestic"]
    if pdd:
        last = sorted(pdd, key=lambda r: r["period"])[-1]
        ext = at("principal_due_external", last["period"])
        if ext is not None:
            d["principal_due"] = {"fy": _fy(last["period"]), "domestic": float(last["value"]), "external": ext}
    return d


def maturity_values(d: dict) -> dict:
    mix, due = d["mix"], d["due"]
    last, first_mix = mix[-1], mix[0]
    dl = due[-1]
    low = min(due[:-1], key=lambda r: r["total"]) if len(due) > 1 else dl  # lowest earlier year
    v = {"mat_fy": _fy_of(d["year"]), "mat_end": f"end June {d['year']}",
         "mat_lt1": f"{last['pct']['lt1']:.1f}%", "mat_lt1_from": f"{first_mix['pct']['lt1']:.1f}%",
         "mat_from_fy": _fy_of(first_mix["year"]),
         "mat_within5": f"{last['pct']['lt1'] + last['pct']['1_5']:.1f}%", "mat_ge10": f"{last['pct']['ge10']:.1f}%",
         "due1y_gdp": f"{dl['total']:.1f}%", "due1y_gdp_low": f"{low['total']:.1f}%", "due1y_low_fy": _fy_of(low["year"]),
         "due1y_dom_gdp": f"{dl['domestic']:.1f}%", "due1y_dom_from": f"{due[0]['domestic']:.1f}%",
         "due_from_fy": _fy_of(due[0]["year"]),
         "atm_total": f"{d['atm'].get(d['year'], 0):.1f}", "atm_domestic": f"{d['atm_dom'].get(d['year'], 0):.1f}"}
    pd = d.get("principal_due")
    v["principal_due"] = f"KSh {round(pd['domestic'] + pd['external'])} billion" if pd else None
    v["principal_due_fy"] = pd["fy"] if pd else None
    return v


def render_maturity(rows: list[dict], out_png: Path) -> Path:
    d = maturity_data(rows)
    if not d:
        raise ValueError("no maturity figures in the site inputs")
    v = maturity_values(d)
    take = (f"Debt due within a year rose to {v['due1y_gdp']} of GDP in {v['mat_fy']}, from "
            f"{v['due1y_gdp_low']} in {v['due1y_low_fy']}, driven by domestic debt.")
    fig = _frame(f"Kenya's repayment pressure, {v['due_from_fy']} to {v['mat_fy']}", take, [
        f"Source: {d['source']} (Figures 6, 18 and 19; domestic securities: Central Bank of Kenya).",
        "Kenya Debt Counter (kenyadebtcounter.vercel.app), Institute of Economic Affairs Kenya. Fiscal years end in June.",
    ])
    # Left: the maturity mix of domestic securities, year by year
    fig.text(0.04, 0.80, "Domestic Treasury bills and bonds by time left to run, %", fontsize=8.6,
             fontweight="bold", color="#334155", va="center")
    ax = fig.add_axes([0.11, 0.25, 0.42, 0.52])
    mix = d["mix"]
    for i, m in enumerate(mix):
        yy = len(mix) - 1 - i
        acc = 0.0
        for k, label, c in APDR_BUCKETS:
            w = m["pct"][k]
            ax.barh(yy, w, left=acc, color=c, height=0.66, edgecolor="white", lw=1.2)
            if w >= 9:
                ax.text(acc + w / 2, yy, f"{w:.1f}", ha="center", va="center", fontsize=8.2, fontweight="bold",
                        color=DARK if k == "6_9" else "white")
            acc += w
        ax.text(-2, yy, _fy_of(m["year"]), ha="right", va="center", fontsize=8.6,
                fontweight="bold" if i == len(mix) - 1 else "normal", color=DARK)
    ax.set_xlim(0, 100)
    ax.set_ylim(-0.6, len(mix) - 0.4)
    ax.axis("off")
    for j, (k, label, c) in enumerate(APDR_BUCKETS):
        fig.add_artist(plt.Rectangle((0.11 + j * 0.105, 0.205), 0.012, 0.018, transform=fig.transFigure, color=c))
        fig.text(0.125 + j * 0.105, 0.214, label, fontsize=7.2, color="#334155", va="center")
    # Right: debt due within a year, % of GDP
    fig.text(0.60, 0.80, "Debt due within a year, % of GDP", fontsize=8.6, fontweight="bold", color="#334155",
             va="center")
    bx = fig.add_axes([0.62, 0.25, 0.33, 0.52])
    due = d["due"]
    xs = list(range(len(due)))
    for key, label, c, lw in (("total", "All debt", "#b91c1c", 2.4), ("domestic", "Domestic", DOM, 1.8),
                              ("external", "External", EXT, 1.8)):
        ys = [r[key] for r in due]
        bx.plot(xs, ys, color=c, lw=lw, marker="o", ms=4)
        bx.text(xs[-1] + 0.12, ys[-1], f"{ys[-1]:.1f}", color=c, fontsize=8.6, fontweight="bold", va="center")
        bx.text(xs[0] - 0.12, ys[0], label, color=c, fontsize=7.4, ha="right", va="center")
    bx.set_xticks(xs)
    bx.set_xticklabels([f"{r['year'] - 1}/{str(r['year'])[2:]}" for r in due], fontsize=7.6, color="#64748b")
    bx.set_ylim(0, max(r["total"] for r in due) * 1.25)
    bx.set_xlim(-0.9, len(due) - 0.5)
    bx.tick_params(axis="y", labelsize=7.6, colors="#64748b", length=0)
    bx.tick_params(axis="x", length=0)
    bx.grid(True, axis="y", color="#e5e7eb", lw=0.8)
    bx.set_axisbelow(True)
    for side in ("top", "right", "left"):
        bx.spines[side].set_visible(False)
    bx.spines["bottom"].set_color("#c3c2b7")
    # What else changed, in fairness
    atm = d["atm"]
    prev = sorted(y for y in atm if y < d["year"])
    note = (f"Share due within a year: {v['mat_lt1_from']} ({v['mat_from_fy']}) to {v['mat_lt1']} ({v['mat_fy']}). "
            f"Average time to maturity {v['atm_total']} years"
            + (f" ({atm[prev[-1]]:.1f} a year earlier), after new long bonds including a 30-year issue." if prev else ".")
            + (f" Principal to repay in {v['principal_due_fy']}: {v['principal_due']} (excl. T-bills)." if v["principal_due"] else "")
            + " FY 2022/23 maturity mix not shown: its shares add up to 112.7% in the report.")
    import textwrap
    fig.text(0.04, 0.135, "\n".join(textwrap.wrap(note, 160)), fontsize=7.4, color="#1f2937", va="center",
             linespacing=1.35)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=200, facecolor="white")
    plt.close(fig)
    return out_png
