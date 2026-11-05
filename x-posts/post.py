"""
Kenya Debt Counter -> X (Twitter): post scheduled tweets with live figures.

How it works
  1. Reads the "x_posts" tab of the X posts Google Sheet (X_POSTS_SHEET_ID).
     Each row is one post you write in advance:
        post_at   when to post, Nairobi time, e.g. 2026-11-02 09:00
        text      the tweet, with {placeholders} for live figures (see below)
        visual    counter | per_person | chart | terms | terms_real | counter+chart | per_person+chart | none
                  (terms_real: the same picture in today's shillings, adjusted for
                   inflation, with explanatory notes under the chart)
                  (chart: the animated debt-trend chart as the post's own video;
                   terms: a picture of the debt by president, as on the
                   dashboard, with the total projected to 31 December)
                  (+chart: also reply with the debt-trend chart and the
                   dashboard link; +card is accepted as the same thing)
        status    ready -> the job posts it. Anything else (draft, hold) is ignored.
        posted_at, post_url, note   filled in by the job
        repeat    (optional) weekly -> once the row has gone out (or failed, or
                  was missed), the job adds the same post again 7 days later
                  as a new "ready" row. To stop the series, set that next
                  row's status to anything other than ready (e.g. stop).
  2. When a "ready" row is due, it fetches the live figures the website shows
     (kenyadebtcounter.vercel.app/api/debt/summary, falling back to Supabase),
     fills in the placeholders, renders the video if asked, and posts to X.
  3. Writes the result back to the sheet (posted / failed / missed + a note).

Placeholders
  {debt_total}        KSh 13.05 trillion
  {debt_total_full}   KSh 13,051,000,191,850
  {debt_per_person}   KSh 241,200
  {growth_per_second} KSh 38,370
  {growth_per_day}    KSh 3.32 billion
  {domestic}          KSh 7.37 trillion      {domestic_share}  56%
  {external}          KSh 5.68 trillion      {external_share}  44%
  {population}        54.1 million
  {debt_to_gdp}       63.4%   (public debt as a share of GDP, as on the dashboard)
  {date}              29 Oct 2026
  {time}              04:18 EAT  (when the post went out)
  {since_increase}    KSh 4.91 tn   net rise in total debt since August 2022 (X_POSTS_BASELINE_MONTH)
  {since_from}        KSh 8.66 tn   total debt in August 2022
  {since_to}          KSh 13.57 tn  total debt now
  {since_per_year}    KSh 1.18 tn      average rise per year since then
  {projection_year_end}  KSh 13.91 trillion  total by 31 Dec at today's rate (as on the home page)
  {added_by_year_end}    KSh 197 billion    added between now and then
  {year_end}             31 Dec 2026        {days_to_year_end}  56
  {ruto_added}  {ruto_per_year}      KSh 5.01 tn, KSh 1,199 bn: debt added under each
  {uhuru_added} {uhuru_per_year}     president and the average a year, as in "Debt by
  {kibaki_added} {kibaki_per_year}   president" on the dashboard (to today for Ruto)
  {ruto_added_real} {ruto_per_year_real} ... {kibaki_per_year_real}  the same, adjusted for
                      inflation (today's shillings; see cpi.py); {prices_month} = Oct 2026
  {link}              https://kenyadebtcounter.vercel.app/?utm_source=x&utm_content=20261029
                      (clickable; X charges more for posts with a link)

Safeguards
  - Only rows marked "ready" are posted, at most MAX_POSTS_PER_RUN per run.
  - A row more than MISSED_AFTER_HOURS late is marked "missed", not posted.
  - Figures must pass sanity checks (positive, within plausible ranges), or
    nothing is posted and the row is marked "failed" with the reason.
  - The filled-in text must fit X's 280-character limit.
  - The row is set to "posting" before the call, so a re-run never double-posts.
  - DRY_RUN=true renders and prints everything but posts and writes nothing.

Environment
  X_API_KEY, X_API_SECRET, X_ACCESS_TOKEN, X_ACCESS_TOKEN_SECRET   (OAuth 1.0a)
  X_POSTS_SHEET_ID, GSHEET_SERVICE_ACCOUNT_FILE (path to the service-account JSON)
  SUPABASE_URL, SUPABASE_SERVICE_ROLE  (fallback only)
  DRY_RUN, ONLY_ROW (post one sheet row now, ignoring its time), LOCAL_CSV, SUMMARY_JSON_FILE (testing)
"""
from __future__ import annotations

import csv
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import warnings
warnings.filterwarnings("ignore", message=".*OpenSSL.*")  # harmless on older macOS Python
import requests

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from render_video import render  # noqa: E402
from render_chart import render_chart_video  # noqa: E402
from render_terms import append_notes, render_terms_chart, rows_with_live, term_stats  # noqa: E402
import cpi as cpi_mod  # noqa: E402

EAT = timezone(timedelta(hours=3))
SITE = "https://kenyadebtcounter.vercel.app"
LINK_BASE = os.getenv("X_POSTS_LINK", f"{SITE}/?utm_source=x")
# Debt "since the 2022 election" is measured from this month's figure in the history.
BASELINE_MONTH = os.getenv("X_POSTS_BASELINE_MONTH", "2022-08")
# Text of the automatic reply for "+chart" visuals, posted with the
# animated debt-trend chart (render_chart.py) under the video.
CARD_REPLY = os.getenv("X_POSTS_CARD_REPLY",
                       "Since the August 2022 election, the net increase in overall public debt is "
                       "{since_increase} ({since_to} − {since_from}), approximately {since_per_year} a year, "
                       "without accounting for inflation.\n\nFor more insights, visit 👉 {link}")
VISUALS = ("counter", "per_person", "chart", "terms", "terms_real", "counter+chart", "per_person+chart",
           "counter+card", "per_person+card", "none", "")  # +card = +chart (older name)
API_HISTORY = f"{SITE}/api/debt/historical"  # monthly total / domestic / external, newest first
API_SUMMARY = f"{SITE}/api/debt/summary"
API_RATIO = f"{SITE}/api/debt/ratio"  # last row = today's live debt-to-GDP
X_API = os.getenv("X_API_BASE", "https://api.x.com")
SHEET_TAB = "x_posts"
HEADERS = ["post_at", "text", "visual", "status", "posted_at", "post_url", "note"]
OPTIONAL = ["repeat"]  # added to the tab automatically if it is missing
MAX_POSTS_PER_RUN = int(os.getenv("MAX_POSTS_PER_RUN", "2"))
MISSED_AFTER_HOURS = float(os.getenv("MISSED_AFTER_HOURS", "6"))
DRY_RUN = os.getenv("DRY_RUN", "false").lower() in ("true", "1", "yes")
ONLY_ROW = os.getenv("ONLY_ROW", "").strip()
OUT_DIR = Path(os.getenv("OUT_DIR", "x-posts-out"))


def log(msg: str) -> None:
    print(msg, flush=True)


def summary_line(msg: str) -> None:
    path = os.getenv("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(msg + "\n")


# ---------------------------------------------------------------- figures
def fetch_figures() -> dict:
    if os.getenv("SUMMARY_JSON_FILE"):
        s = json.loads(Path(os.environ["SUMMARY_JSON_FILE"]).read_text())
        return figures_from_summary(s, source="local file")
    try:
        r = requests.get(API_SUMMARY, timeout=30, headers={"User-Agent": "kdc-x-posts"})
        r.raise_for_status()
        return figures_from_summary(r.json(), source=API_SUMMARY)
    except Exception as e:  # fall back to Supabase, same maths as the website
        log(f"Website summary unavailable ({e}); using Supabase.")
        return figures_from_supabase()


def fetch_gdp() -> float | None:
    """Today's nominal GDP as the dashboard uses it for debt-to-GDP: the last
    (live) row of /api/debt/ratio, falling back to Supabase df_gdp_metrics
    (gdp + gps_gdp x seconds since its date). None if neither is available."""
    if os.getenv("GDP_VALUE"):  # testing
        return float(os.environ["GDP_VALUE"])
    if os.getenv("SUMMARY_JSON_FILE"):
        return None
    try:
        r = requests.get(API_RATIO, timeout=30, headers={"User-Agent": "kdc-x-posts"})
        r.raise_for_status()
        rows = r.json().get("data") or []
        gdp = float(rows[-1]["gdp"]) if rows and rows[-1].get("gdp") else None
        if gdp:
            return gdp
    except Exception as e:
        log(f"Website debt-to-GDP unavailable ({e}); trying Supabase.")
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE") or os.environ.get("SUPABASE_API", "")
    if not url or not key:
        return None
    try:
        h = {"apikey": key, "Authorization": f"Bearer {key}"}
        r = requests.get(f"{url}/rest/v1/df_gdp_metrics?select=*&order=date.desc&limit=1", headers=h, timeout=30)
        r.raise_for_status()
        row = r.json()[0]
        s = max(0.0, (datetime.now(timezone.utc) - parse_eat(row["date"])).total_seconds())
        return float(row["gdp"]) + float(row.get("gps_gdp") or 0) * s
    except Exception as e:
        log(f"GDP unavailable from Supabase too ({e}).")
        return None


def add_gdp(f: dict) -> None:
    """Adds f['debt_to_gdp'] (per cent), or None if GDP is missing or implausible."""
    gdp = fetch_gdp()
    ratio = f["total"] / gdp * 100 if gdp else None
    if ratio is not None and not 20 <= ratio <= 200:
        log(f"Debt-to-GDP {ratio:.1f}% looks wrong; leaving it out.")
        ratio = None
    f["gdp"], f["debt_to_gdp"] = gdp, ratio


def since_baseline(history: list[dict] | None, f: dict, now: datetime) -> dict:
    """Net change in total debt since the BASELINE_MONTH figure (August 2022 by default,
    the month of the 2022 general election), and the average per year."""
    keys = ("since_increase", "since_from", "since_to", "since_per_year")
    row = None
    for r in history or []:
        if str(r.get("date", ""))[:7] == BASELINE_MONTH and r.get("total") is not None:
            row = r
            break
    if not row:
        return dict.fromkeys(keys)
    start = float(row["total"])
    # A monthly figure is the stock at the END of that month (e.g. the August 2022
    # row is "as at end of August 2022", KSh 8,663.20 bn in the Treasury bulletin),
    # so the years are counted from the last day of the month.
    y, m = int(row["date"][:4]), int(row["date"][5:7])
    d0 = datetime(y + (m == 12), m % 12 + 1, 1, tzinfo=EAT) - timedelta(days=1)
    years = (now - d0).total_seconds() / (365.25 * 86400)
    inc = f["total"] - start
    return {
        "since_increase": f"KSh {inc / 1e12:.2f} tn",
        "since_from": f"KSh {start / 1e12:.2f} tn",
        "since_to": f"KSh {f['total'] / 1e12:.2f} tn",
        "since_per_year": f"KSh {inc / years / 1e12:.2f} tn" if years > 0.5 else None,
    }


def live_row(f: dict, now: datetime) -> dict | None:
    if not (f.get("domestic") and f.get("external")):
        return None
    return {"date": now.astimezone(EAT).strftime("%Y-%m-%d"), "total": f["total"],
            "domestic": f["domestic"], "external": f["external"]}


def terms_values(history: list[dict] | None, f: dict, now: datetime) -> dict:
    """Debt added under each president and the average a year (as on the dashboard)."""
    keys = [f"{n}_{k}" for n in ("ruto", "uhuru", "kibaki") for k in ("added", "per_year")]
    out = {k: None for k in keys}
    if not history:
        return out
    try:
        for t in term_stats(rows_with_live(history, live_row(f, now))):
            n = t["label"].lower()
            if f"{n}_added" in out:
                out[f"{n}_added"] = f"KSh {t['added'] / 1e12:.2f} tn"
                out[f"{n}_per_year"] = f"KSh {t['per_year'] / 1e9:,.0f} bn"
    except Exception as e:
        log(f"Debt by president unavailable ({e}).")
    return out


REAL_KEYS = [f"{n}_{k}_real" for n in ("ruto", "uhuru", "kibaki") for k in ("added", "per_year")] + ["prices_month"]


def _bn(x: float) -> str:
    return f"{'−' if x < 0 else ''}KSh {abs(x) / 1e9:,.0f} bn"


def _tn(x: float) -> str:
    return f"{'−' if x < 0 else ''}KSh {abs(x) / 1e12:.2f} tn"


def real_terms(history: list[dict] | None, f: dict, now: datetime) -> dict | None:
    """Debt by president in today's shillings: the values for the text, the
    deflator for the picture and the notes printed under it."""
    if not history:
        return None
    cpi, latest, src = cpi_mod.monthly_cpi()
    deflate = cpi_mod.deflator(cpi, latest)
    rows = rows_with_live(history, live_row(f, now))
    real = [{"date": r["date"], **{k: deflate(r["date"], r[k]) for k in ("total", "domestic", "external")}}
            for r in rows]
    nom = {t["label"]: t for t in term_stats(rows)}
    rl = {t["label"]: t for t in term_stats(real)}
    month = datetime(latest[0], latest[1], 1).strftime("%B %Y")
    v = {"prices_month": datetime(latest[0], latest[1], 1).strftime("%b %Y")}
    for n in ("Ruto", "Uhuru", "Kibaki"):
        if n in rl:
            v[f"{n.lower()}_added_real"] = _tn(rl[n]["added"])
            v[f"{n.lower()}_per_year_real"] = _bn(rl[n]["per_year"])
    ruto_n, ruto_r, kib_n, kib_r = nom.get("Ruto"), rl.get("Ruto"), nom.get("Kibaki"), rl.get("Kibaki")
    first_cpi = cpi.get((2005, 6))
    notes = [
        f"Every month's debt is shown in {month} shillings: it is scaled up by how much consumer prices have "
        f"risen since that month (the consumer price index, CPI)."
        + (f" A shilling in mid-2005 bought about {cpi[latest] / first_cpi:.1f} times what it buys today." if first_cpi else ""),
        "Net increase = debt in today's shillings when a president left office (Ruto: today) minus debt in today's "
        "shillings when he took office; per year = that divided by the years in office. Moi is not assessed: the "
        "monthly data start in 1999, partway through his term.",
    ]
    if kib_n and kib_r:
        notes.append(
            f"Kibaki: debt rose from {_tn(kib_n['from_total'])} to {_tn(kib_n['to_total'])} in shillings of the day, "
            f"but prices roughly tripled over his term (including a 26% jump in 2008), so in today's money it was "
            f"roughly unchanged ({_tn(kib_r['added'])}).")
    if ruto_n and ruto_r:
        notes.append(
            f"Ruto: the {_tn(ruto_n['from_total'])} he inherited in September 2022 is worth about "
            f"{_tn(ruto_r['from_total'])} at today's prices, so the real rise is {_tn(ruto_r['added'])}, not "
            f"{_tn(ruto_n['added'])}.")
    notes.append(
        "Not adjusted for inflation, the net increases are: "
        + ", ".join(f"{n} {_tn(nom[n]['added'])} ({_bn(nom[n]['per_year'])} a year)"
                    for n in ("Kibaki", "Uhuru", "Ruto") if n in nom) + ".")
    notes.append(
        "Caveats: the figures still include exchange-rate effects on foreign debt, and depend on the price index "
        "used (the GDP deflator would give somewhat different numbers). The projection to 31 December is at "
        "today's prices.")
    notes.append(
        "Prices: KNBS consumer price index via the World Bank (annual, spread across the months) and CBK monthly "
        "inflation rates for the latest months.")
    log(f"Inflation adjustment: prices to {month} ({src}).")
    return {"values": v, "deflate": deflate, "month": month, "notes": notes}


def projection_point(f: dict, now: datetime) -> dict:
    local = now.astimezone(EAT)
    year_end = datetime(local.year, 12, 31, 23, 59, 59, tzinfo=EAT)
    left = max(0.0, (year_end - now).total_seconds())
    return {"date": f"{local.year}-12-31", "total": f["total"] + f["gps"] * left}


def fetch_history() -> list[dict]:
    """Monthly debt history (date, total, domestic, external in KSh) for the chart:
    the site's /api/debt/historical, falling back to Supabase df_debt_historical."""
    if os.getenv("HISTORY_JSON_FILE"):  # testing: a list of rows, or the site's debt-data.json
        d = json.loads(Path(os.environ["HISTORY_JSON_FILE"]).read_text())
        return d["history"] if isinstance(d, dict) and "history" in d else d.get("data", d) if isinstance(d, dict) else d
    try:
        r = requests.get(API_HISTORY, timeout=60, headers={"User-Agent": "kdc-x-posts"})
        r.raise_for_status()
        rows = r.json().get("data") or []
        if rows:
            return rows
    except Exception as e:
        log(f"Website debt history unavailable ({e}); trying Supabase.")
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE") or os.environ.get("SUPABASE_API", "")
    if not url or not key:
        raise RuntimeError("debt history unavailable from the website, and Supabase is not configured")
    h = {"apikey": key, "Authorization": f"Bearer {key}"}
    out: dict[str, dict] = {}
    for offset in range(0, 50_000, 1000):
        r = requests.get(f"{url}/rest/v1/df_debt_historical?select=id,date,debt_dom,debt_ext,debt_ttl"
                         f"&order=date.asc,id.asc&limit=1000&offset={offset}", headers=h, timeout=60)
        r.raise_for_status()
        batch = r.json()
        for b in batch:  # later rows (higher id) win, as on the site
            if None not in (b.get("debt_dom"), b.get("debt_ext"), b.get("debt_ttl")):
                d = str(b["date"])[:10]
                out[d] = {"date": d, "domestic": b["debt_dom"], "external": b["debt_ext"], "total": b["debt_ttl"]}
        if len(batch) < 1000:
            break
    return list(out.values())


def figures_from_summary(s: dict, source: str) -> dict:
    s = s.get("data", s) if isinstance(s.get("data"), dict) else s  # site wraps it as { success, data }
    return {
        "total": float(s["totalDebt"]),
        "gps": float(s["increasePerSecond"]),
        "per_person": float(s["debtPerCapita"]),
        "population": float(s.get("population") or 0),
        "domestic": float(s.get("domesticDebt") or 0),
        "external": float(s.get("externalDebt") or 0),
        "as_of": s.get("asOf"),
        "source": source,
    }


def parse_eat(v: str) -> datetime:
    # Google Sheets turns "2026-11-09 09:00" into a date and shows it as
    # "2026-11-09 9:00" or "2026-11-09 9:00:00": accept those too.
    m = re.fullmatch(r"\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?\s*", v)
    if m:
        y, mo, d, h, mi, sec = (int(x) if x else 0 for x in m.groups())
        return datetime(y, mo, d, h, mi, sec, tzinfo=EAT)
    v = v.strip().replace(" ", "T")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        v += "T00:00:00"
    if not re.search(r"(Z|[+-]\d{2}:?\d{2})$", v):
        v += "+03:00"
    return datetime.fromisoformat(v.replace("Z", "+00:00"))


def figures_from_supabase() -> dict:
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE") or os.environ.get("SUPABASE_API", "")
    if not url or not key:
        raise RuntimeError("Could not read the live figures from the website, and SUPABASE_URL / SUPABASE_SERVICE_ROLE are not set for the fallback.")
    h = {"apikey": key, "Authorization": f"Bearer {key}"}

    def latest(table: str) -> dict:
        r = requests.get(f"{url}/rest/v1/{table}?select=*&order=date.desc&limit=1", headers=h, timeout=30)
        r.raise_for_status()
        rows = r.json()
        if not rows:
            raise RuntimeError(f"{table} is empty")
        return rows[0]

    now = datetime.now(timezone.utc)
    c, g, p = latest("df_debt_current"), latest("df_debt_growth_per_sec"), latest("df_pop_metrics")
    s = max(0.0, (now - parse_eat(c["date"])).total_seconds())
    sp = max(0.0, (now - parse_eat(p["date"])).total_seconds())
    total = float(c["debt_ttl"]) + float(g["gps_ttl"]) * s
    pop = float(p["pop"]) + float(p.get("gps_pop") or 0) * sp
    return {
        "total": total,
        "gps": float(g["gps_ttl"]),
        "per_person": total / pop if pop else 0,
        "population": pop,
        "domestic": float(c["debt_dom"]) + float(g["gps_dom"]) * s,
        "external": float(c["debt_ext"]) + float(g["gps_ext"]) * s,
        "as_of": now.isoformat(),
        "source": "Supabase",
    }


def check_figures(f: dict) -> None:
    problems = []
    if not 5e12 <= f["total"] <= 60e12:
        problems.append(f"total debt {f['total']:,.0f} is outside KSh 5-60 trillion")
    if not 0 < f["gps"] < 1e6:
        problems.append(f"growth per second {f['gps']:,.0f} is not between 0 and KSh 1 million")
    if not 50_000 <= f["per_person"] <= 2_000_000:
        problems.append(f"debt per person {f['per_person']:,.0f} is outside KSh 50,000-2,000,000")
    if problems:
        raise ValueError("; ".join(problems))


def trillion(x: float) -> str:
    return f"KSh {x / 1e12:.2f} trillion"


def placeholders(f: dict, now: datetime) -> dict:
    share = f["domestic"] + f["external"]
    # Year-end projection, as on the home page: today's total plus today's
    # rate per second for every second left to 31 Dec, 23:59:59 EAT.
    local = now.astimezone(EAT)
    year_end = datetime(local.year, 12, 31, 23, 59, 59, tzinfo=EAT)
    left = max(0.0, (year_end - now).total_seconds())
    added = f["gps"] * left
    return {
        "projection_year_end": trillion(f["total"] + added),
        "added_by_year_end": f"KSh {added / 1e9:,.0f} billion",
        "year_end": f"31 Dec {local.year}",
        "days_to_year_end": f"{int(left // 86400)}",
        "debt_total": trillion(f["total"]),
        "debt_total_full": f"KSh {f['total']:,.0f}",
        "debt_per_person": f"KSh {round(f['per_person'], -2):,.0f}",
        "growth_per_second": f"KSh {f['gps']:,.0f}",
        "growth_per_day": f"KSh {f['gps'] * 86400 / 1e9:.2f} billion",
        "domestic": trillion(f["domestic"]),
        "external": trillion(f["external"]),
        "domestic_share": f"{f['domestic'] / share * 100:.0f}%" if share else "",
        "external_share": f"{f['external'] / share * 100:.0f}%" if share else "",
        "population": f"{f['population'] / 1e6:.1f} million" if f["population"] else "",
        "debt_to_gdp": f"{f['debt_to_gdp']:.1f}%" if f.get("debt_to_gdp") else None,
        "date": now.astimezone(EAT).strftime("%-d %b %Y"),
        "time": now.astimezone(EAT).strftime("%H:%M EAT"),
        # A new date in the link each day makes X fetch a fresh preview card
        # (X caches cards per link), so the card always shows the current figure.
        "link": f"{LINK_BASE}{'&' if '?' in LINK_BASE else '?'}utm_content={now.astimezone(EAT):%Y%m%d}",
    }


def fill(text: str, values: dict) -> str:
    unknown = sorted(set(re.findall(r"\{(\w+)\}", text)) - set(values))
    if unknown:
        raise ValueError("unknown placeholder(s): " + ", ".join("{" + u + "}" for u in unknown))
    empty = sorted(k for k in set(re.findall(r"\{(\w+)\}", text)) if values.get(k) is None)
    if empty:
        raise ValueError("no live figure available today for " + ", ".join("{" + k + "}" for k in empty))
    return text.format(**values)


def x_length(text: str) -> int:
    # X counts every link as 23 characters.
    return len(re.sub(r"https?://\S+|\b[\w-]+\.(?:app|com|org|ke|net)\S*", "x" * 23, text))


# ---------------------------------------------------------------- sheet
class Sheet:
    """The x_posts tab (or a local CSV for testing)."""

    def __init__(self) -> None:
        self.local = os.getenv("LOCAL_CSV")
        if self.local:
            with open(self.local, newline="", encoding="utf-8") as fh:
                self.rows = list(csv.DictReader(fh))
            return
        import gspread
        gc = gspread.service_account(filename=os.environ["GSHEET_SERVICE_ACCOUNT_FILE"])
        sh = gc.open_by_key(os.environ["X_POSTS_SHEET_ID"])
        try:
            self.ws = sh.worksheet(SHEET_TAB)
        except gspread.WorksheetNotFound:
            self.ws = sh.add_worksheet(SHEET_TAB, rows=200, cols=len(HEADERS))
            self.ws.append_row(HEADERS)
            log(f"Created the '{SHEET_TAB}' tab with its headers.")
        values = self.ws.get_all_values()
        header = [h.strip().lower() for h in values[0]] if values else HEADERS
        missing = [h for h in HEADERS if h not in header]
        if missing:
            raise RuntimeError(f"Sheet tab '{SHEET_TAB}' is missing columns: {missing}")
        for h in OPTIONAL:
            if h not in header:
                if self.ws.col_count < len(header) + 1:
                    self.ws.add_cols(len(header) + 1 - self.ws.col_count)
                self.ws.update_cell(1, len(header) + 1, h)
                header.append(h)
                log(f"Added the '{h}' column to the '{SHEET_TAB}' tab.")
        self.header = header
        self.col = {h: header.index(h) + 1 for h in HEADERS + OPTIONAL}
        self.rows = [dict(zip(header, r + [""] * (len(header) - len(r)))) for r in values[1:]]

    def update(self, i: int, **fields) -> None:
        if DRY_RUN:
            return
        self.rows[i].update(fields)
        if self.local:
            self._write_local()
            return
        cells = []
        import gspread
        for k, v in fields.items():
            cells.append(gspread.Cell(i + 2, self.col[k], v))
        self.ws.update_cells(cells, value_input_option="USER_ENTERED")

    def _write_local(self) -> None:
        with open(self.local, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=HEADERS + OPTIONAL, extrasaction="ignore")
            w.writeheader()
            w.writerows(self.rows)

    def append(self, row: dict) -> None:
        """Add a new row at the bottom (used for the next post of a weekly series)."""
        if DRY_RUN:
            return
        self.rows.append(row)
        if self.local:
            self._write_local()
            return
        # RAW, so "2026-11-09 09:00" stays text and is read back exactly.
        self.ws.append_row([row.get(h, "") for h in self.header], value_input_option="RAW")


def schedule_next(sheet: "Sheet", i: int, now: datetime) -> str:
    """For a row with repeat = weekly, add the same post 7 days after its
    post_at (skipping weeks already past) as a new ready row. Returns a note."""
    row = sheet.rows[i]
    if (row.get("repeat") or "").strip().lower() != "weekly":
        return ""
    try:
        nxt = parse_eat(row["post_at"]) + timedelta(days=7)
    except Exception:
        return "Not repeated: could not read post_at."
    while nxt <= now:
        nxt += timedelta(days=7)
    when = nxt.astimezone(EAT).strftime("%Y-%m-%d %H:%M")
    sheet.append({"post_at": when, "text": row.get("text", ""), "visual": row.get("visual", ""),
                  "status": "ready", "repeat": "weekly",
                  "note": "Weekly repeat. Set status to stop to end the series."})
    log(f"Row {i + 2}: next weekly post added for {when}.")
    return f"Next weekly post: {when}"


# ---------------------------------------------------------------- X API
def x_auth():
    from requests_oauthlib import OAuth1
    return OAuth1(os.environ["X_API_KEY"], os.environ["X_API_SECRET"],
                  os.environ["X_ACCESS_TOKEN"], os.environ["X_ACCESS_TOKEN_SECRET"])


def x_check(r: requests.Response, what: str) -> dict:
    if r.status_code >= 300:
        raise RuntimeError(f"X {what} failed: HTTP {r.status_code} {r.text[:300]}")
    return r.json() if r.content else {}


def upload_media(path: Path, mime: str, category: str) -> str:
    auth = x_auth()
    data = path.read_bytes()
    init = x_check(requests.post(f"{X_API}/2/media/upload/initialize", auth=auth, json={
        "media_type": mime, "total_bytes": len(data), "media_category": category},
        timeout=60), "media initialize")
    media_id = init["data"]["id"]
    chunk = 4 * 1024 * 1024
    for idx, start in enumerate(range(0, len(data), chunk)):
        x_check(requests.post(f"{X_API}/2/media/upload/{media_id}/append", auth=auth,
                              data={"segment_index": str(idx)},
                              files={"media": (path.name, data[start:start + chunk], "application/octet-stream")},
                              timeout=120), f"media append {idx}")
    fin = x_check(requests.post(f"{X_API}/2/media/upload/{media_id}/finalize", auth=auth, timeout=60),
                  "media finalize")
    info = (fin.get("data") or {}).get("processing_info")
    waited = 0
    while info and info.get("state") in ("pending", "in_progress") and waited < 300:
        wait = int(info.get("check_after_secs", 5))
        time.sleep(wait)
        waited += wait
        st = x_check(requests.get(f"{X_API}/2/media/upload", auth=auth,
                                  params={"command": "STATUS", "media_id": media_id}, timeout=60),
                     "media status")
        info = (st.get("data") or {}).get("processing_info")
    if info and info.get("state") != "succeeded":
        raise RuntimeError(f"X media processing did not succeed: {info}")
    return media_id


def set_alt_text(media_id: str, text: str) -> None:
    """Description read out by screen readers (X allows up to 1,000 characters)."""
    x_check(requests.post(f"{X_API}/2/media/metadata", auth=x_auth(), timeout=60, json={
        "id": media_id, "metadata": {"alt_text": {"text": text[:1000]}}}), "alt text")


def alt_text(style: str, f: dict, values: dict, as_of: str) -> str:
    gdp = f" That is equal to {values['debt_to_gdp']} of Kenya's GDP." if values.get("debt_to_gdp") else ""
    if style == "per_person":
        main = (f"Animated figure: Kenya's public debt per person counts up to {values['debt_per_person']}, "
                f"owed for every man, woman and child in Kenya. Total public debt: {values['debt_total']}.")
    else:
        main = (f"Animated counter: Kenya's public debt ticking up from {values['debt_total_full']}, "
                f"rising by {values['growth_per_second']} every second. "
                f"About {values['debt_per_person']} for every Kenyan.")
    return (f"{main}{gdp} {as_of}. Kenya Debt Counter by the Institute of Economic Affairs (IEA Kenya), "
            "kenyadebtcounter.vercel.app")


def terms_alt_text(v: dict, real: bool = False) -> str:
    sfx = "_real" if real else ""
    parts = [f"{n}: net increase {v.get(f'{n.lower()}_added{sfx}')}, about {v.get(f'{n.lower()}_per_year{sfx}')} a year"
             for n in ("Kibaki", "Uhuru", "Ruto") if v.get(f"{n.lower()}_added{sfx}")]
    units = (f"adjusted for inflation, in {v.get('prices_month')} shillings" if real
             else "not adjusted for inflation")
    return (f"Chart of Kenya's public debt since 2000 by president (KSh trillion, {units}), "
            "with total, domestic and external debt. " + "; ".join(parts) + ". Total today "
            f"{v['debt_total']}; at today's pace about {v['projection_year_end']} by {v['year_end']} (dashed line). "
            "Source: Kenya Debt Counter, IEA Kenya.")[:1000]


def chart_alt_text(f: dict, values: dict) -> str:
    def part(name: str, key: str, shown: str) -> str:
        share = f" ({f[key] / f['gdp'] * 100:.1f}% of GDP)" if f.get("gdp") and f.get("debt_to_gdp") else ""
        return f"{name} {shown}{share}"
    return ("Animated line chart of Kenya's public debt since 1999, in KSh trillion: total, domestic and "
            f"external debt drawing year by year, rising steeply over the last decade. As at {values['date']}: "
            f"{part('total', 'total', values['debt_total'])}, {part('domestic', 'domestic', values['domestic'])}, "
            f"{part('external', 'external', values['external'])}. "
            "Source: Kenya Debt Counter (kenyadebtcounter.vercel.app), Institute of Economic Affairs Kenya.")


def create_post(text: str, media_id: str | None = None, reply_to: str | None = None) -> str:
    body = {"text": text}
    if media_id:
        body["media"] = {"media_ids": [media_id]}
    if reply_to:
        body["reply"] = {"in_reply_to_tweet_id": reply_to}
    res = x_check(requests.post(f"{X_API}/2/tweets", auth=x_auth(), json=body, timeout=60), "create post")
    return res["data"]["id"]


# ---------------------------------------------------------------- main
def main() -> int:
    now = datetime.now(timezone.utc)
    if not os.getenv("LOCAL_CSV") and not os.getenv("X_POSTS_SHEET_ID"):
        # Not set up yet (no sheet / X keys in the repository secrets): do nothing, quietly.
        log("X posts are not set up yet (X_POSTS_SHEET_ID is not set); nothing to do.")
        summary_line("X posts are not set up yet: add the secrets listed in x-posts/README.md.")
        return 0
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    sheet = Sheet()
    due = []
    for i, row in enumerate(sheet.rows):
        if (row.get("status") or "").strip().lower() != "ready":
            continue
        if ONLY_ROW:
            if str(i + 2) == ONLY_ROW:
                due.append(i)
            continue
        try:
            when = parse_eat(row["post_at"])
        except Exception:
            sheet.update(i, status="failed", note=f"Could not read post_at '{row.get('post_at')}'. Use e.g. 2026-11-02 09:00")
            continue
        if when > now:
            continue
        if now - when > timedelta(hours=MISSED_AFTER_HOURS):
            nxt = schedule_next(sheet, i, now)
            sheet.update(i, status="missed", note=f"Not posted: more than {MISSED_AFTER_HOURS:g} hours late. Set a new time and status 'ready' to post it." + (f" {nxt}" if nxt else ""))
            log(f"Row {i + 2}: missed.")
            continue
        due.append(i)

    if not due:
        log("Nothing due.")
        summary_line("Nothing due.")
        return 0

    figures = fetch_figures()
    check_figures(figures)
    add_gdp(figures)
    values = placeholders(figures, now)
    history, history_error = None, None
    if any((sheet.rows[i].get("visual") or "").strip().lower().endswith(("chart", "+card", "terms"))
           or re.search(r"\{(since|ruto|uhuru|kibaki)_", sheet.rows[i].get("text", "")) for i in due[:MAX_POSTS_PER_RUN]):
        try:
            history = fetch_history()
        except Exception as e:
            history_error = f"debt history unavailable ({e})"
    values.update(since_baseline(history, figures, now))
    values.update(terms_values(history, figures, now))
    real = None
    if any((sheet.rows[i].get("visual") or "").strip().lower() == "terms_real"
           or re.search(r"_real\}|\{prices_month\}", sheet.rows[i].get("text", "")) for i in due[:MAX_POSTS_PER_RUN]):
        real = real_terms(history, figures, now)
    values.update(real["values"] if real else {k: None for k in REAL_KEYS})
    log(f"Figures ({figures['source']}): total {values['debt_total_full']}, "
        f"+{values['growth_per_second']}/s, per person {values['debt_per_person']}, "
        f"debt-to-GDP {values['debt_to_gdp'] or 'n/a'}, since {BASELINE_MONTH}: {values['since_increase'] or 'n/a'}")

    failures = 0
    for i in due[:MAX_POSTS_PER_RUN]:
        row = sheet.rows[i]
        label = f"Row {i + 2}"
        try:
            text = fill(row["text"].strip(), values)
            if not text:
                raise ValueError("text is empty")
            if x_length(text) > 280:
                raise ValueError(f"text is {x_length(text)} characters after filling in figures; X allows 280")
            visual = (row.get("visual") or "none").strip().lower()
            if visual not in VISUALS:
                raise ValueError("visual must be counter, per_person, chart, counter+chart, per_person+chart "
                                 f"or none (got '{visual}')")
            with_chart = visual.endswith(("+chart", "+card"))
            style = visual.split("+")[0]
            video = alt = reply = reply_skipped = chart = chart_alt = None
            if with_chart:
                try:
                    if history is None:
                        raise RuntimeError(history_error or "debt history unavailable")
                    reply = fill(CARD_REPLY, values)
                    if x_length(reply) > 280:
                        raise ValueError(f"the reply text is {x_length(reply)} characters; X allows 280")
                    today = now.astimezone(EAT).strftime("%Y-%m-%d")
                    live = {"date": today, "total": figures["total"],
                            "domestic": figures["domestic"], "external": figures["external"]}
                    chart, _ = render_chart_video(history,
                                                  live if live["domestic"] and live["external"] else None,
                                                  OUT_DIR / f"row{i + 2}_chart.mp4", gdp=figures.get("gdp"))
                    chart_alt = chart_alt_text(figures, values)
                except Exception as e:  # never reply with an old link card instead of the chart
                    log(f"{label}: chart reply unavailable ({e}); posting without the reply.")
                    reply = None
                    reply_skipped = f"Reply skipped: {str(e)[:150]}"
            image = None
            if visual == "terms_real":
                if history is None:
                    raise RuntimeError(history_error or "debt history unavailable")
                if not real:
                    raise RuntimeError("prices for the inflation adjustment unavailable")
                image = render_terms_chart(
                    history, live_row(figures, now), projection_point(figures, now),
                    OUT_DIR / f"row{i + 2}_terms_real.png", deflate=real["deflate"],
                    title=f"Kenya's public debt by president, adjusted for inflation (KSh trillion, {real['month']} prices)",
                    units_note="Source: Kenya Debt Counter (kenyadebtcounter.vercel.app), IEA Kenya, from CBK debt data "
                               "and KNBS consumer prices. See the notes below.")
                append_notes(image, "How to read this chart", real["notes"])
                alt = terms_alt_text(values, real=True)
            elif visual == "terms":
                if history is None:
                    raise RuntimeError(history_error or "debt history unavailable")
                image = render_terms_chart(history, live_row(figures, now), projection_point(figures, now),
                                           OUT_DIR / f"row{i + 2}_terms.png")
                alt = terms_alt_text(values)
            elif visual == "chart":
                # The debt-trend chart is the post's own video (no reply).
                if history is None:
                    raise RuntimeError(history_error or "debt history unavailable")
                today = now.astimezone(EAT).strftime("%Y-%m-%d")
                live = {"date": today, "total": figures["total"],
                        "domestic": figures["domestic"], "external": figures["external"]}
                video, _ = render_chart_video(history,
                                              live if live["domestic"] and live["external"] else None,
                                              OUT_DIR / f"row{i + 2}_chart.mp4", gdp=figures.get("gdp"))
                alt = chart_alt_text(figures, values)
            elif style in ("counter", "per_person"):
                as_of = "As at " + now.astimezone(EAT).strftime("%-d %b %Y, %H:%M EAT")
                video, gif = render(style, figures["total"], figures["gps"], figures["per_person"],
                                    OUT_DIR / f"row{i + 2}.mp4", as_of=as_of,
                                    debt_to_gdp=figures.get("debt_to_gdp"))
                alt = alt_text(style, figures, values, as_of)
            log(f"{label}: {text!r} visual={visual or 'none'}")
            summary_line(f"**{label}** ({visual or 'none'}): {text}")
            if reply:
                log(f"{label}: reply with chart {chart}: {reply!r}")
                summary_line(f"Reply (with the debt-trend chart): {reply}")
            if alt:
                log(f"{label}: video alt text: {alt!r}")
            if DRY_RUN:
                log(f"{label}: dry run, not posted.")
                continue
            sheet.update(i, status="posting", note="Posting...")
            media_id = (upload_media(video, "video/mp4", "tweet_video") if video
                        else upload_media(image, "image/png", "tweet_image") if image else None)
            notes = [reply_skipped] if reply_skipped else []
            if media_id and alt:
                try:
                    set_alt_text(media_id, alt)
                except Exception as e:  # nice to have; post the video anyway
                    notes.append(f"Alt text not added: {str(e)[:200]}")
                    log(f"{label}: {notes[-1]}")
            post_id = create_post(text, media_id)
            url = f"https://x.com/i/web/status/{post_id}"
            if reply:
                try:
                    chart_id = upload_media(chart, "video/mp4", "tweet_video")
                    try:
                        set_alt_text(chart_id, chart_alt)
                    except Exception:
                        pass
                    reply_id = create_post(reply, chart_id, reply_to=post_id)
                    notes.append(f"Chart reply: https://x.com/i/web/status/{reply_id}")
                except Exception as e:  # the main post is out; never repost it
                    notes.append(f"Posted, but the chart reply failed: {str(e)[:300]}")
                    log(f"{label}: {notes[-1]}")
            nxt = schedule_next(sheet, i, now)
            if nxt:
                notes.append(nxt)
            note = " | ".join(notes)
            sheet.update(i, status="posted", posted_at=now.astimezone(EAT).strftime("%Y-%m-%d %H:%M"),
                         post_url=url, note=note)
            log(f"{label}: posted {url}")
            summary_line(f"Posted: {url}")
        except Exception as e:
            failures += 1
            log(f"{label}: FAILED - {e}")
            summary_line(f"**{label} failed:** {e}")
            nxt = schedule_next(sheet, i, now)  # a failed week never ends the series
            sheet.update(i, status="failed", note=(str(e)[:400] + (f" | {nxt}" if nxt else "")))
    if len(due) > MAX_POSTS_PER_RUN:
        log(f"{len(due) - MAX_POSTS_PER_RUN} more due; they will go in the next run.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
