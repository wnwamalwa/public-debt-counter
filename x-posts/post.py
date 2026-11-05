"""
Kenya Debt Counter -> X (Twitter): post scheduled tweets with live figures.

How it works
  1. Reads the "x_posts" tab of the X posts Google Sheet (X_POSTS_SHEET_ID).
     Each row is one post you write in advance:
        post_at   when to post, Nairobi time, e.g. 2026-11-02 09:00
        text      the tweet, with {placeholders} for live figures (see below)
        visual    counter | per_person | counter+chart | per_person+chart | none
                  (+chart: also reply with the debt-trend chart and the
                   dashboard link; +card is accepted as the same thing)
        status    ready -> the job posts it. Anything else (draft, hold) is ignored.
        posted_at, post_url, note   filled in by the job
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
VISUALS = ("counter", "per_person", "counter+chart", "per_person+chart",
           "counter+card", "per_person+card", "none", "")  # +card = +chart (older name)
API_HISTORY = f"{SITE}/api/debt/historical"  # monthly total / domestic / external, newest first
API_SUMMARY = f"{SITE}/api/debt/summary"
API_RATIO = f"{SITE}/api/debt/ratio"  # last row = today's live debt-to-GDP
X_API = os.getenv("X_API_BASE", "https://api.x.com")
SHEET_TAB = "x_posts"
HEADERS = ["post_at", "text", "visual", "status", "posted_at", "post_url", "note"]
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
    return {
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
        self.col = {h: header.index(h) + 1 for h in HEADERS}
        self.rows = [dict(zip(header, r + [""] * (len(header) - len(r)))) for r in values[1:]]

    def update(self, i: int, **fields) -> None:
        if DRY_RUN:
            return
        self.rows[i].update(fields)
        if self.local:
            with open(self.local, "w", newline="", encoding="utf-8") as fh:
                w = csv.DictWriter(fh, fieldnames=HEADERS)
                w.writeheader()
                w.writerows(self.rows)
            return
        cells = []
        import gspread
        for k, v in fields.items():
            cells.append(gspread.Cell(i + 2, self.col[k], v))
        self.ws.update_cells(cells, value_input_option="USER_ENTERED")


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
            sheet.update(i, status="missed", note=f"Not posted: more than {MISSED_AFTER_HOURS:g} hours late. Set a new time and status 'ready' to post it.")
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
    if any((sheet.rows[i].get("visual") or "").strip().lower().endswith(("+chart", "+card"))
           or "{since_" in sheet.rows[i].get("text", "") for i in due[:MAX_POSTS_PER_RUN]):
        try:
            history = fetch_history()
        except Exception as e:
            history_error = f"debt history unavailable ({e})"
    values.update(since_baseline(history, figures, now))
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
                raise ValueError("visual must be counter, per_person, counter+chart, per_person+chart "
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
            if style in ("counter", "per_person"):
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
            media_id = upload_media(video, "video/mp4", "tweet_video") if video else None
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
            note = " | ".join(notes)
            sheet.update(i, status="posted", posted_at=now.astimezone(EAT).strftime("%Y-%m-%d %H:%M"),
                         post_url=url, note=note)
            log(f"{label}: posted {url}")
            summary_line(f"Posted: {url}")
        except Exception as e:
            failures += 1
            log(f"{label}: FAILED - {e}")
            summary_line(f"**{label} failed:** {e}")
            sheet.update(i, status="failed", note=str(e)[:450])
    if len(due) > MAX_POSTS_PER_RUN:
        log(f"{len(due) - MAX_POSTS_PER_RUN} more due; they will go in the next run.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
