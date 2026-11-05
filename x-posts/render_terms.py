"""
Render "Kenya's public debt by president": total, domestic and external debt
(KSh trillion, nominal) with each president's term shaded and labelled with
the debt added and the average a year, as in Chart 1 on the dashboard
(Explore -> Evolution of Kenya's Debt Stock, "Debt by president"), plus the
total projected at today's pace to 31 December (dashed).

term_stats()          the per-president figures (same method as the site's
                      termStats(): figure at or before the start of the term
                      against the figure at or before its end, or today)
render_terms_chart()  a PNG of the chart
"""
from __future__ import annotations

from datetime import date, datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402
from PIL import Image  # noqa: E402

HERE = Path(__file__).resolve().parent

# The dashboard's terms and colours (webapp/src/components/DebtNominalChart.tsx)
REGIMES = [
    ("Moi", None, "2002-12-30", "#ede9fe"),
    ("Kibaki", "2002-12-30", "2013-04-09", "#dcfce7"),
    ("Uhuru", "2013-04-09", "2022-09-13", "#fef3c7"),
    ("Ruto", "2022-09-13", None, "#fce7f3"),
]
SERIES = [("total", "Total", "#1baf7a"), ("domestic", "Domestic", "#2a78d6"), ("external", "External", "#eb6834")]
HEADER = "#15803d"
DARK = "#0b0b0b"
GREY = "#52514e"
GRID = "#e1e0d9"
YEAR_DAYS = 365.25


def _font_family() -> list[str]:
    have = {f.name for f in font_manager.fontManager.ttflist}
    return [n for n in ("Inter", "Arial", "Helvetica", "DejaVu Sans") if n in have] or ["sans-serif"]


def _d(s: str) -> date:
    return datetime.strptime(s[:10], "%Y-%m-%d").date()


def rows_with_live(history: list[dict], live: dict | None) -> list[dict]:
    rows = sorted(({"date": str(r["date"])[:10], **{k: float(r[k]) for k, _, _ in SERIES}}
                   for r in history if all(r.get(k) is not None for k, _, _ in SERIES)),
                  key=lambda r: r["date"])
    if live:
        rows = [r for r in rows if r["date"] < live["date"]] + [live]
    if len(rows) < 24:
        raise ValueError(f"only {len(rows)} months of debt history")
    return rows


def term_stats(rows: list[dict]) -> list[dict]:
    """Debt added under each president: total at (or just before) the start
    of the term against the total at (or just before) its end, or today."""
    first, last = rows[0], rows[-1]

    def at_or_before(day: date) -> dict | None:
        found = None
        for r in rows:
            if _d(r["date"]) <= day:
                found = r
            else:
                break
        return found

    out = []
    for label, start, end, fill in REGIMES:
        s_day = _d(start) if start else _d(first["date"])
        e_day = _d(end) if end else _d(last["date"])
        if e_day <= _d(first["date"]):
            continue
        s_row = at_or_before(s_day) or first
        e_row = (at_or_before(e_day) or last) if end else last
        years = (_d(e_row["date"]) - _d(s_row["date"])).days / YEAR_DAYS
        if years <= 0:
            continue
        added = e_row["total"] - s_row["total"]
        out.append({"label": label, "fill": fill, "start": start, "end": end,
                    "partial": not start or _d(first["date"]) > _d(start),
                    "added": added, "per_year": added / years, "years": years})
    return out


def render_terms_chart(history: list[dict], live: dict | None, projection: dict | None,
                       out_png: Path) -> Path:
    """projection: {"date": "2026-12-31", "total": ...} drawn dashed from today."""
    rows = rows_with_live(history, live)
    stats = {t["label"]: t for t in term_stats(rows)}
    xs = [datetime.strptime(r["date"], "%Y-%m-%d") for r in rows]
    x0 = datetime(2000, 1, 1)
    x_proj = datetime.strptime(projection["date"], "%Y-%m-%d") if projection else xs[-1]
    x_end = max(xs[-1], x_proj)

    plt.rcParams.update({"font.family": _font_family(), "font.size": 11})
    fig = plt.figure(figsize=(8, 5), dpi=200)  # 1600 x 1000 px
    fig.patch.set_facecolor("white")
    fig.add_artist(plt.Rectangle((0, 0.915), 1, 0.085, transform=fig.transFigure, color=HEADER, zorder=5))
    fig.text(0.5, 0.957, "Kenya's public debt by president (KSh trillion, not adjusted for inflation)",
             fontsize=12.5, fontweight="bold", color="white", ha="center", va="center", zorder=6)
    logo_path = HERE / "assets" / "iea-kenya.png"
    if logo_path.exists():
        lax = fig.add_axes([0.01, 0.015, 0.075, 0.075])
        lax.imshow(Image.open(logo_path))
        lax.axis("off")
    fig.text(0.095, 0.052, "Source: Kenya Debt Counter (kenyadebtcounter.vercel.app), Institute of Economic Affairs Kenya, "
             "from Central Bank of Kenya data.", fontsize=7.2, color=GREY, va="center")
    fig.text(0.095, 0.027, "Debt added: from the month a president took office to the month they left (Ruto: to today). "
             "Red dashes: today's pace continued to 31 Dec.", fontsize=7.2, color=GREY, va="center")

    ax = fig.add_axes([0.075, 0.13, 0.78, 0.765])
    top = max(max(r["total"] for r in rows), projection["total"] if projection else 0) / 1e12
    y_top = (int(top // 2) + 1) * 2 + 2  # room for the term labels
    ax.set_ylim(0, y_top)
    ax.set_xlim(x0, x_end)
    ax.set_yticks(range(0, y_top + 1, 2))
    ax.set_yticklabels([str(t) for t in range(0, y_top + 1, 2)], fontsize=8.5, color="#898781")
    ax.xaxis.set_major_locator(mdates.YearLocator(2))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))
    ax.tick_params(axis="x", labelsize=8.5, colors="#898781", length=0, pad=5)
    ax.tick_params(axis="y", length=0, pad=4)
    ax.grid(True, axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color("#c3c2b7")

    # Shaded terms with their labels
    for label, start, end, fill in REGIMES:
        a = max(x0, datetime.strptime(start, "%Y-%m-%d")) if start else x0
        b = datetime.strptime(end, "%Y-%m-%d") if end else x_end
        ax.axvspan(a, b, color=fill, zorder=0, lw=0)
        if start:
            ax.axvline(a, color="#c3c2b7", lw=0.8, zorder=1)
        mid = a + (b - a) / 2
        ax.text(mid, y_top - 0.45, label, ha="center", va="top", fontsize=10.5, fontweight="bold", color=DARK)
        t = stats.get(label)
        if t and not t["partial"]:
            ax.text(mid, y_top - 1.25, f"+KSh {t['added'] / 1e12:.2f} tn", ha="center", va="top",
                    fontsize=8, fontweight="bold", color="#1e293b")
            ax.text(mid, y_top - 1.85, f"{t['per_year'] / 1e9:,.0f} bn a year", ha="center", va="top",
                    fontsize=7.5, color="#334155")

    # The three series, and their values today at the right
    for key, name, colour in SERIES:
        ys = [r[key] / 1e12 for r in rows]
        ax.plot(xs, ys, color=colour, lw=1.6, solid_capstyle="round", zorder=3)
        ax.plot([xs[-1]], [ys[-1]], "o", color=colour, ms=3.5, zorder=4)
    labels = [(rows[-1][k] / 1e12, f"{rows[-1][k] / 1e12:.2f} {n}", c) for k, n, c in SERIES]
    if projection:
        p = projection["total"] / 1e12
        pdate = datetime.strptime(projection["date"], "%Y-%m-%d")
        ax.plot([xs[-1], x_proj], [rows[-1]["total"] / 1e12, p], color="#b91c1c", lw=1.8,
                ls=(0, (2, 1.5)), zorder=3)
        ax.plot([x_proj], [p], "o", color="#b91c1c", ms=5, mfc="white", mew=1.6, zorder=5)
        labels[0] = (rows[-1]["total"] / 1e12, f"{rows[-1]['total'] / 1e12:.2f} Total\ntoday", SERIES[0][2])
        # The projection is only a few weeks wide on a 25-year chart, so call it out.
        ax.annotate(f"Projected, {pdate:%-d %b %Y}:\nKSh {p:.2f} trillion\n(today's pace continued)",
                    xy=(x_proj, p), xytext=(datetime(2017, 1, 1), y_top - 5.6), fontsize=8.5,
                    fontweight="bold", color="#b91c1c", ha="center", va="center", linespacing=1.15,
                    bbox=dict(boxstyle="round,pad=0.35", fc="white", ec="#b91c1c", lw=0.9),
                    arrowprops=dict(arrowstyle="-|>", color="#b91c1c", lw=1.0,
                                    connectionstyle="arc3,rad=0.3", shrinkA=2, shrinkB=4), zorder=6)
    for y, text, colour in labels:
        ax.annotate(text, xy=(x_end, y), xytext=(6, 0), textcoords="offset points", va="center", ha="left",
                    fontsize=8.5, fontweight="bold", color=colour, annotation_clip=False, linespacing=1.1)

    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=200, facecolor="white")
    plt.close(fig)
    return out_png
