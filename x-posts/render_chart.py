"""
Render the "Trends in Kenya's public debt" chart posted under each video:
total, domestic and external debt since 2003 (KSh trillion; X_POSTS_CHART_START), with the latest
point set to the live figures and an "As at ..." callout, in the style of
Figure 1 of the IEA Kenya quarterly macro & debt report.

render_chart()        a still PNG (the finished chart)
render_chart_video()  an MP4 in which the three lines draw themselves from 2003
                      up to today, then the "As at" callout and the % of GDP
                      labels appear and the finished chart holds; also saves
                      the last frame as a PNG

Usage (local preview):
  python render_chart.py --history ../webapp/src/data/debt-data.json --out chart.mp4
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from datetime import date, datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402
from PIL import Image  # noqa: E402

HERE = Path(__file__).resolve().parent
# First month shown: the row for Dec 2002 is the stock at the end of 2002, i.e. the start of 2003.
CHART_START = os.getenv("X_POSTS_CHART_START", "2002-12-01")

# Same series colours as the quarterly report (iea_blue / iea_green / iea_gold)
SERIES = [("total", "Total", "#1565C0"), ("domestic", "Domestic", "#2E7D32"), ("external", "External", "#C8A415")]
IEA_GREEN = "#18AA4F"
DARK = "#231F20"
GREY = "#555555"
GRID = "#D0D0D0"
FPS = 30


def _font_family() -> list[str]:
    have = {f.name for f in font_manager.fontManager.ttflist}
    return [n for n in ("Inter", "Arial", "Helvetica", "DejaVu Sans") if n in have] or ["sans-serif"]


def ordinal(day: int) -> str:
    if day in (11, 12, 13):
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(day % 10, "th")


def as_at_label(d: date) -> str:
    return f"As at {d.day}{ordinal(d.day)} {d:%B %Y}"


def _rows(history: list[dict], live: dict | None) -> list[dict]:
    rows = sorted(({"date": str(r["date"])[:10], **{k: float(r[k]) for k, _, _ in SERIES}}
                   for r in history if all(r.get(k) is not None for k, _, _ in SERIES)),
                  key=lambda r: r["date"])
    rows = [r for r in rows if r["date"] >= CHART_START]
    if live:
        rows = [r for r in rows if r["date"] < live["date"]] + [live]
    if len(rows) < 12:
        raise ValueError(f"only {len(rows)} months of debt history; need at least 12 for the chart")
    return rows


class _Chart:
    """The figure with everything that does not move; update() draws the lines
    up to a given point and the labels at their tips."""

    def __init__(self, rows: list[dict], gdp: float | None):
        self.rows, self.gdp = rows, gdp
        self.xs = [datetime.strptime(r["date"], "%Y-%m-%d") for r in rows]
        self.tip_date = self.xs[-1].date()
        xs = self.xs

        plt.rcParams.update({"font.family": _font_family(), "font.size": 11})
        fig = self.fig = plt.figure(figsize=(8, 4.5), dpi=150)  # 1200 x 675 px, 16:9
        fig.patch.set_facecolor("white")
        fig.add_artist(plt.Rectangle((0, 0.985), 1, 0.015, transform=fig.transFigure, color=IEA_GREEN, zorder=5))
        fig.text(0.035, 0.925, "Kenya's public debt since 2003 (KSh trillion)", fontsize=15,
                 fontweight="bold", color=DARK, va="center")
        logo_path = HERE / "assets" / "iea-kenya.png"
        if logo_path.exists():
            lax = fig.add_axes([0.875, 0.855, 0.10, 0.12])
            lax.imshow(Image.open(logo_path))
            lax.axis("off")
        fig.text(0.035, 0.035, "Source: Kenya Debt Counter (kenyadebtcounter.vercel.app), "
                 "Institute of Economic Affairs Kenya", fontsize=9, color=GREY, va="center")

        ax = self.ax = fig.add_axes([0.105, 0.14, 0.55 if gdp else 0.665, 0.70])
        top = max(r[k] for r in rows for k, _, _ in SERIES) / 1e12
        self.step = 2
        self.y_top = (int(top // self.step) + 1) * self.step
        ax.set_ylim(0, self.y_top * 1.08)
        ax.set_yticks(range(0, self.y_top + 1, self.step))
        ax.set_yticklabels([f"KSh {t:02d} T" for t in range(0, self.y_top + 1, self.step)], fontsize=9.5, color=DARK)
        ax.set_xlim(xs[0], xs[-1])
        # Year labels counted back from the current year, so the last one is always this year
        every = 4 if gdp else 2
        years = [y for y in range(self.tip_date.year, xs[0].year - 1, -every) if datetime(y, 1, 1) >= xs[0]]
        ax.set_xticks([datetime(y, 1, 1) for y in reversed(years)])
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))
        ax.tick_params(axis="x", labelsize=9.5, colors=DARK, length=0, pad=6)
        ax.tick_params(axis="y", length=0, pad=6)
        ax.grid(True, color=GRID, linewidth=0.7)
        ax.set_axisbelow(True)
        for side in ("top", "right", "left"):
            ax.spines[side].set_visible(False)
        ax.spines["bottom"].set_color("#888888")

        # Big faint year in the plot area, shown while the lines are drawing
        self.year_text = ax.text(0.03, 0.93, "", transform=ax.transAxes, fontsize=30, fontweight="bold",
                                 color="#BBBBBB", va="top", ha="left")
        self.lines = [ax.plot([], [], color=c, linewidth=2.0, solid_capstyle="round")[0] for _, _, c in SERIES]
        self.dots = [ax.plot([], [], "o", color=c, markersize=5)[0] for _, _, c in SERIES]
        self.labels = [ax.annotate("", xy=(xs[0], 0), xytext=(8, 0), textcoords="offset points", va="center",
                                   ha="left", fontweight="bold", color=c, annotation_clip=False)
                       for _, _, c in SERIES]
        tip_y = rows[-1]["total"] / 1e12
        span = xs[-1] - xs[0]
        self.as_at = ax.annotate(
            as_at_label(self.tip_date), xy=(xs[-1], tip_y), xytext=(xs[-1] - span * 0.13, self.y_top - self.step * 0.2),
            fontsize=10, fontstyle="italic", color="#444444", ha="right", va="center",
            arrowprops=dict(arrowstyle="-|>", color="#444444", lw=1.0, connectionstyle="arc3,rad=-0.3",
                            shrinkA=3, shrinkB=3, relpos=(1.0, 0.5)))

    def update(self, upto: float, final: bool, as_at_alpha: float = 1.0) -> None:
        """upto: how far along the history to draw (0..len(rows)-1, may be fractional)."""
        n = len(self.rows)
        whole = int(upto)
        frac = upto - whole
        xs_num = mdates.date2num(self.xs)
        x_end = xs_num[whole] + (xs_num[min(whole + 1, n - 1)] - xs_num[whole]) * frac
        ends = []
        for (key, name, colour), line, dot in zip(SERIES, self.lines, self.dots):
            ys = [r[key] / 1e12 for r in self.rows]
            y_end = ys[whole] + (ys[min(whole + 1, n - 1)] - ys[whole]) * frac
            line.set_data(list(xs_num[:whole + 1]) + [x_end], ys[:whole + 1] + [y_end])
            dot.set_data([x_end], [y_end])
            dot.set_visible(not final)
            ends.append((y_end, name))
        # Labels at the tips, nudged apart if they would overlap
        min_gap = (self.y_top * 1.08) * 0.065
        # stacked from the lowest upwards, so no label drops below the axis
        order = sorted(range(len(SERIES)), key=lambda i: ends[i][0])
        prev = None
        for i in order:
            v, name = ends[i]
            y = max(v, min_gap * 0.4) if prev is None else max(v, prev + min_gap)
            prev = y
            share = f" ({v * 1e12 / self.gdp * 100:.1f}% of GDP)" if final and self.gdp else ""
            lab = self.labels[i]
            lab.set_text(f"KSh {v:.2f} T {name}{share}")
            lab.xy = (x_end, y)
            lab.set_fontsize(9.5 if self.gdp else 10.5)
        date_now = mdates.num2date(x_end)
        self.year_text.set_text("" if final else str(date_now.year))
        self.as_at.set_visible(final and as_at_alpha > 0)
        self.as_at.set_alpha(as_at_alpha)
        if self.as_at.arrow_patch is not None:
            self.as_at.arrow_patch.set_alpha(as_at_alpha)

    def save(self, path: Path) -> None:
        self.fig.savefig(path, dpi=150, facecolor="white")

    def close(self) -> None:
        plt.close(self.fig)


def render_chart(history: list[dict], live: dict | None, out_png: Path, gdp: float | None = None) -> Path:
    """history: rows with date (YYYY-MM-DD), total, domestic, external in KSh.
    live: today's point {date, total, domestic, external}; replaces any row
    dated today or later so the chart ends on the same figure as the video.
    gdp: today's nominal GDP in KSh; if given, each end label adds its share of GDP."""
    rows = _rows(history, live)
    c = _Chart(rows, gdp)
    c.update(len(rows) - 1, final=True)
    out_png = Path(out_png)
    c.save(out_png)
    c.close()
    return out_png


def render_chart_video(history: list[dict], live: dict | None, out_mp4: Path, gdp: float | None = None,
                       draw_seconds: float = 6.0, hold_seconds: float = 5.0) -> tuple[Path, Path]:
    """MP4 of the lines drawing from 2003 to today, then the finished chart.
    Returns (mp4, png of the final frame)."""
    from render_video import ffmpeg_exe
    rows = _rows(history, live)
    c = _Chart(rows, gdp)
    tmp = Path(tempfile.mkdtemp(prefix="xpost_chart_"))
    n_draw = int(draw_seconds * FPS)
    last = len(rows) - 1
    i = 0
    for f in range(n_draw):
        t = f / (n_draw - 1)
        eased = t * t * (3 - 2 * t)  # smooth start and finish
        c.update(eased * last, final=False)
        c.save(tmp / f"f{i:04d}.png")
        i += 1
    fade = int(0.5 * FPS)
    for f in range(fade):  # callout and % of GDP labels fade in
        c.update(last, final=True, as_at_alpha=(f + 1) / fade)
        c.save(tmp / f"f{i:04d}.png")
        i += 1
    final_png = Path(out_mp4).with_suffix(".png")
    c.save(final_png)
    for _ in range(int(hold_seconds * FPS)):  # hold the finished chart
        shutil.copyfile(final_png, tmp / f"f{i:04d}.png")
        i += 1
    c.close()
    out_mp4 = Path(out_mp4)
    subprocess.run([
        ffmpeg_exe(), "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(tmp / "f%04d.png"),
        "-vf", "scale=1200:676:flags=lanczos", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out_mp4)], check=True)
    shutil.rmtree(tmp, ignore_errors=True)
    return out_mp4, final_png


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--history", required=True, help="JSON: a list of rows, or the site's debt-data.json")
    ap.add_argument("--gdp", type=float, default=None, help="nominal GDP in KSh, for the %% of GDP labels")
    ap.add_argument("--out", default="chart.mp4", help=".mp4 for the animation, .png for a still")
    a = ap.parse_args()
    data = json.loads(Path(a.history).read_text())
    if isinstance(data, dict):
        data = data.get("history") or data.get("data") or []
    if a.out.endswith(".png"):
        print(render_chart(data, None, Path(a.out), gdp=a.gdp))
    else:
        print(render_chart_video(data, None, Path(a.out), gdp=a.gdp))
