#!/usr/bin/env python3
"""
Supabase check-up for the Kenya Debt Counter.

  audit (default)
    Lists every table and view in the project with its row count and latest
    date, says what reads it (the website, a pipeline, or only the retired
    DigitalOcean API), flags tables that have stopped updating, and writes SQL
    to move unused tables into an `archive` schema (reversible: nothing is
    deleted). Report: watch/supabase_report.md (also the run's summary).

  --sync-legacy
    Makes df_debt_metrics (read only by the old R API on DigitalOcean) hold
    exactly one row: the site's current figures from df_debt_current and
    df_debt_growth_per_sec. The old API reads the table's first row when it
    starts, so it shows the right figures after its next restart.

Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE.
"""
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("SUPABASE_URL", "").strip().rstrip("/").removesuffix("/rest/v1")
KEY = os.environ.get("SUPABASE_SERVICE_ROLE", "").strip()
HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "supabase_report.md")
TODAY = dt.datetime.now(dt.timezone(dt.timedelta(hours=3))).date()

# What reads each table, and how many days it may go without a new row.
# "site" = kenyadebtcounter.vercel.app; "pipeline" = a script in this repo or
# the quarterly report; "legacy" = only the retired DigitalOcean R API.
KNOWN = {
    "df_debt_current": ("site, debt-bulletin and CBK pipelines", 10),
    "df_debt_growth_per_sec": ("site, debt-bulletin and CBK pipelines", 10),
    "df_debt_historical": ("site (charts), quarterly report", 75),
    "df_debt": ("CBK public debt pipeline, quarterly report", 75),
    "df_finance": ("site (revenue), quarterly report", 75),
    "df_finance_metrics": ("site (revenue projection)", 75),
    "df_forex": ("site, quarterly report", 7),
    "df_gdp": ("site (debt-to-GDP)", 130),
    "df_gdp_metrics": ("site", 130),
    "df_pop": ("site, quarterly report", 400),
    "df_pop_metrics": ("site (per capita)", 400),
    "df_wacd": ("site (cost of borrowing)", 75),
    "df_wacd_metrics": ("site", 75),
    "web_daily": ("site (visitors), readership pipeline", 3),
    "web_daily_breakdown": ("site (visitors), readership pipeline", 3),
    "web_monthly": ("site (view over web_daily)", None),
    "web_monthly_breakdown": ("site (view over web_daily_breakdown)", None),
    "visitor_metrics_summary_vercel": ("site (view: visitor totals)", None),
    "visitor_metrics_summary": ("site /api/visitors/summary (view, now reads visitor_metrics_summary_vercel)", None),
}
LEGACY = {
    "df_debt_metrics": "only the retired DigitalOcean R API (replaced by df_debt_current + df_debt_growth_per_sec)",
    "visitor_metrics": "old visitor counter's raw data (replaced by web_daily); keep as history",
    "visitor_metrics_summary_legacy": "old visitor counter's totals (view over visitor_metrics); keep as history",
}
KEEP = {"visitor_metrics", "visitor_metrics_summary_legacy"}  # historical: never suggested for archiving
DATE_COLS = ["date", "as_at", "month", "created_at", "updated_at"]


def req(path, method="GET", body=None, headers=None):
    h = {"apikey": KEY, "Authorization": f"Bearer {KEY}", "Accept": "application/json"}
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    if data is not None:
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(f"{URL}{path}", data=data, method=method, headers=h)
    with urllib.request.urlopen(r, timeout=60) as resp:
        raw = resp.read().decode("utf-8")
        return resp.status, dict(resp.headers), (json.loads(raw) if raw.strip() else None)


def tables():
    """Tables and views exposed by PostgREST (from its OpenAPI description)."""
    _, _, spec = req("/rest/v1/", headers={"Accept": "application/openapi+json"})
    defs = spec.get("definitions", {})
    return {name: list((d.get("properties") or {}).keys()) for name, d in defs.items()}


def count(name):
    try:
        _, h, _ = req(f"/rest/v1/{name}?select=*&limit=1", headers={"Prefer": "count=exact", "Range": "0-0"})
        cr = h.get("Content-Range") or h.get("content-range") or ""
        return int(cr.split("/")[-1]) if "/" in cr and cr.split("/")[-1].isdigit() else None
    except Exception:
        return None


def latest(name, cols):
    col = next((c for c in DATE_COLS if c in cols), None)
    if not col:
        return None, None
    try:
        _, _, rows = req(f"/rest/v1/{name}?select={col}&order={col}.desc.nullslast&limit=1")
        return col, (str(rows[0][col])[:10] if rows else None)
    except Exception:
        return col, None


def audit():
    tbl = tables()
    lines = [f"# Supabase check-up, {TODAY:%d %b %Y}", "", f"{len(tbl)} tables and views.", ""]
    lines += ["| Table | Rows | Latest | Read by | Status |", "|---|---:|---|---|---|"]
    stale, unused = [], []
    for name in sorted(tbl):
        n = count(name)
        col, last = latest(name, tbl[name])
        if name in KNOWN:
            who, max_age = KNOWN[name]
            status = "ok"
            if n == 0:
                status = "**empty**"
                stale.append(name)
            elif max_age and last:
                age = (TODAY - dt.date.fromisoformat(last)).days
                if age > max_age:
                    status = f"**stale: {age} days** (expected ≤ {max_age})"
                    stale.append(name)
        elif name in LEGACY:
            who = LEGACY[name]
            status = "legacy: keep (history)" if name in KEEP else "legacy: can be archived"
            if name not in KEEP:
                unused.append(name)
        else:
            who, status = "nothing known", "check, then archive"
            unused.append(name)
        lines.append(f"| `{name}` | {'' if n is None else f'{n:,}'} | {last or '–'} | {who} | {status} |")
    missing = [t for t in KNOWN if t not in tbl]
    if missing:
        lines += ["", "**Expected but missing:** " + ", ".join(f"`{t}`" for t in missing)]
    lines += ["", "## Needs attention", ""]
    lines += [f"- `{t}` has stopped updating: check the workflow that writes it." for t in stale] or ["- Nothing: every table the site reads is up to date."]
    if unused:
        lines += [
            "", "## Archive unused tables (optional)", "",
            "Moves them out of sight without deleting anything. Paste into Supabase → SQL Editor. "
            "Leave out `df_debt_metrics` until the DigitalOcean server is switched off. To undo, "
            "`alter table archive.<name> set schema public;`.", "", "```sql", "create schema if not exists archive;",
        ]
        lines += [f"alter table if exists public.{t} set schema archive;" for t in unused if not t.startswith("visitor_metrics_summary")]
        lines += [f"-- {t} looks like a view; drop or move it in the Table Editor if unused" for t in unused if t.startswith("visitor_metrics_summary")]
        lines += ["```"]
    text = "\n".join(lines) + "\n"
    open(REPORT, "w").write(text)
    print(text)
    s = os.environ.get("GITHUB_STEP_SUMMARY")
    if s:
        open(s, "a").write(text)
    return 1 if stale else 0


def sync_legacy():
    _, _, cur = req("/rest/v1/df_debt_current?select=*&order=date.desc&limit=1")
    _, _, gro = req("/rest/v1/df_debt_growth_per_sec?select=*&order=date.desc&limit=1")
    if not cur or not gro:
        sys.exit("df_debt_current or df_debt_growth_per_sec is empty: nothing to copy.")
    c, g = cur[0], gro[0]
    row = {
        "date": c["date"], "debt_ttl": c["debt_ttl"], "debt_dom": c["debt_dom"], "debt_ext": c["debt_ext"],
        "gps_ttl": g["gps_ttl"], "gps_dom": g["gps_dom"], "gps_ext": g["gps_ext"],
    }
    _, _, old = req("/rest/v1/df_debt_metrics?select=*&limit=1")
    if old:  # keep any extra columns the table has, with today's values where we have them
        row = {k: row.get(k, v) for k, v in old[0].items() if k not in ("id",)} | row
    req("/rest/v1/df_debt_metrics?date=not.is.null", method="DELETE")
    req("/rest/v1/df_debt_metrics?date=is.null", method="DELETE")
    req("/rest/v1/df_debt_metrics", method="POST", body=[row], headers={"Prefer": "return=minimal"})
    msg = (f"df_debt_metrics now holds one row: KSh {row['debt_ttl'] / 1e12:,.3f} trn on {str(row['date'])[:10]}, "
           f"KSh {row['gps_ttl']:,.0f}/sec. The DigitalOcean API picks it up when it is next restarted.")
    print(msg)
    s = os.environ.get("GITHUB_STEP_SUMMARY")
    if s:
        open(s, "a").write(msg + "\n")


if __name__ == "__main__":
    if not URL or not KEY:
        sys.exit("SUPABASE_URL and SUPABASE_SERVICE_ROLE must be set.")
    if "--sync-legacy" in sys.argv:
        sync_legacy()
    else:
        sys.exit(audit())
