#!/usr/bin/env python3
"""
Watch for new external reports whose figures are typed into the IEA macro
data Google Sheet (or the quarterly report's "Treasury inputs" block), and
say which tabs each one feeds.

  Office of the Controller of Budget (OCOB)
    National Government Budget Implementation Review Reports, listed at
    https://cob.go.ke/publications/ (three months, six months, nine months,
    full year). New titles in that list = a new report.

  National Treasury
    Annual Public Debt Report and Medium Term Debt Management Strategy.
    The Treasury site has no stable listing page, so the next edition's
    likely file names are probed (HEAD) each run.

State lives in watch/reports.json. The first run only records what exists
(no alert). Writes to $GITHUB_OUTPUT:
    new=true|false
    title=<one-line issue title>
and the issue body (markdown) to watch/new_reports.md.

Usage: python3 watch/check_reports.py            (normal)
       python3 watch/check_reports.py --dry-run  (print, don't save state)
"""
import datetime as dt
import html
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "reports.json")
BODY = os.path.join(HERE, "new_reports.md")
UA = "Mozilla/5.0 (compatible; KenyaDebtCounterBot/1.0; +https://kenyadebtcounter.vercel.app)"
SHEET = "https://docs.google.com/spreadsheets/d/11Y_EoYqFJOTTubbBCQkh1gV3kbX1cVQHapdzbwWUXK4"

OCOB_PAGES = [
    "https://cob.go.ke/publications/",
    "https://cob.go.ke/publications/?&cp_national-government=2",
]

# "FY 2025/2026", "Nine months FY 2025/26", "First quarter FY 2024/25", "First half FY 2022/23" ...
TITLE_RE = re.compile(
    r"((?:(?:First|Second|Third)\s+)?(?:three|six|nine)\s+months|First\s+(?:quarter|half)|Half\s+year)?"
    r"\s*(?:of\s+)?(?:the\s+)?FY\s*(20\d\d)\s*[/-]\s*(\d{2,4})",
    re.I,
)


def get(url, method="GET", timeout=60):
    req = urllib.request.Request(url, method=method, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, (r.read().decode("utf-8", "ignore") if method == "GET" else "")


def page_text(raw):
    raw = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", raw)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", raw)))


def canonical(m):
    """('Nine months', '2025', '26') -> 'Nine months FY 2025/26' (full year -> 'Full year FY 2025/26')."""
    period = (m.group(1) or "").strip().lower()
    start = int(m.group(2))
    end = m.group(3)[-2:]
    if int(end) != (start + 1) % 100:
        return None
    if not period:
        label = "Full year"
    elif "nine" in period:
        label = "Nine months"
    elif "six" in period or "half" in period:
        label = "Six months"
    else:
        label = "Three months"
    return f"{label} FY {start}/{end}"


def ocob_titles():
    titles = set()
    for url in OCOB_PAGES:
        try:
            _, raw = get(url)
        except Exception as e:  # one page down shouldn't hide the other
            print(f"OCOB: could not read {url}: {e}", file=sys.stderr)
            continue
        text = page_text(raw)
        # Keep only the National Government section when its heading is found.
        a = re.search(r"National Government Budget Implementation Review Reports?", text, re.I)
        b = re.search(r"(Consolidated\s+)?County Budget Implementation Review Reports?", text[a.end():], re.I) if a else None
        if a:
            text = text[a.end(): a.end() + b.start()] if b else text[a.end():]
        for m in TITLE_RE.finditer(text):
            t = canonical(m)
            if t:
                titles.add(t)
    return titles


def treasury_candidates(today):
    """Likely URLs of the next Annual Public Debt Report and MTDS."""
    y = today.year
    out = {}
    for fy in (y - 1, y):  # APDR for FY (y-1)/y is published around Sept-Nov of y
        name = f"Annual Public Debt Report {fy}/{str(fy + 1)[2:]}"
        out[name] = [
            f"https://www.treasury.go.ke/sites/default/files/Annual-Public-Debt-Report-{fy}-{fy + 1}.pdf",
            f"https://www.treasury.go.ke/sites/default/files/Annual%20Public%20Debt%20Report%20{fy}-{fy + 1}.pdf",
        ]
    for yr in (y, y + 1):  # MTDS is tabled with the Budget Policy Statement (Feb)
        name = f"{yr} Medium Term Debt Management Strategy"
        out[name] = [
            f"https://www.treasury.go.ke/sites/default/files/{yr}%20MTDS%20FINAL.pdf",
            f"https://www.treasury.go.ke/sites/default/files/{yr}-Medium-Term-Debt-Management-Strategy.pdf",
        ]
    return out


def exists(url):
    try:
        status, _ = get(url, method="HEAD", timeout=30)
        return 200 <= status < 300
    except urllib.error.HTTPError as e:
        if e.code == 405:  # HEAD not allowed: try a GET
            try:
                return 200 <= get(url)[0] < 300
            except Exception:
                return False
        return False
    except Exception:
        return False


# What to type into the sheet for each kind of report.
OCOB_FULL_YEAR = f"""Full-year OCOB report (figures at 30 June). In the [IEA macro data sheet]({SHEET}):
- [ ] **`debt_service`**: add one row for the year: external principal, external interest, domestic principal, domestic interest (KSh bn), from the public debt service table. Feeds the site's Debt Service chart, the Thresholds chart and the home page.
- [ ] **`external_debt_currency`**: add one row per currency with *As at* = 30 June (table "External Debt Composition by Currency", KSh). Feeds the External Debt by Currency chart.
- [ ] **`domestic_debt_instrument`**: add one row per instrument with *As at* = 30 June (Treasury bonds, Treasury bills, CBK overdraft, ...; KSh bn). Feeds the Domestic Debt by Instrument chart."""

OCOB_QUARTER = f"""Quarterly OCOB report. In the [IEA macro data sheet]({SHEET}):
- [ ] **`domestic_debt_instrument`**: if the report has domestic debt by instrument, add one row per instrument with *As at* = the quarter's last day (KSh bn).
- [ ] **`external_debt_currency`**: likewise, if it has external debt by currency.
- Debt service on the site uses full-year figures only, so `debt_service` waits for the full-year report."""

TREASURY = {
    "Annual Public Debt Report": f"""In the [IEA macro data sheet]({SHEET}):
- [ ] **`pv_indicators`**: add the present-value ratios (PV of public debt / GDP, PV of external debt / GDP, PV of external debt / exports) with `fiscal_year`, `value_pct`, `threshold_pct`, `source`, `published`. Feeds the Thresholds chart.""",
    "Medium Term Debt Management Strategy": """In the quarterly report (`quarterly_macro_debt_report_ieakenya.qmd`, the `treasury-inputs` chunk):
- [ ] `mtds_year`, the DSA table `dsa_indicators` (Latest values), and the weighted average interest rates `wair_domestic` / `wair_external`.""",
}


def main():
    dry = "--dry-run" in sys.argv
    today = dt.date.today()
    state = {}
    if os.path.exists(STATE):
        with open(STATE) as f:
            state = json.load(f)
    first_run = not state

    found_ocob = ocob_titles()
    if not found_ocob:
        print("OCOB: no report titles found (page layout changed or site down); nothing recorded.", file=sys.stderr)
    seen_ocob = set(state.get("ocob_national", []))
    new_ocob = sorted(found_ocob - seen_ocob)

    seen_tsy = set(state.get("treasury", []))
    new_tsy = []
    for name, urls in treasury_candidates(today).items():
        if name in seen_tsy:
            continue
        hit = next((u for u in urls if exists(u)), None)
        if hit:
            new_tsy.append((name, hit))

    print("OCOB national reports listed:", ", ".join(sorted(found_ocob)) or "none")
    print("New OCOB:", new_ocob or "none")
    print("New Treasury:", [n for n, _ in new_tsy] or "none")

    alert = (new_ocob or new_tsy) and not first_run
    parts = []
    if alert:
        parts.append("New reports are out. Update the sheet so the site and the daily PDF report pick them up "
                     "(the site re-reads the sheet within about 10 minutes; the PDF on its next daily run).\n")
        for t in new_ocob:
            parts.append(f"## OCOB: National Government Budget Implementation Review Report, {t}\n"
                         "Find it under *National Government Budget Implementation Review Reports* at https://cob.go.ke/publications/\n\n"
                         + (OCOB_FULL_YEAR if t.startswith("Full year") else OCOB_QUARTER) + "\n")
        for name, url in new_tsy:
            kind = next(k for k in TREASURY if k in name)
            parts.append(f"## National Treasury: {name}\n{url}\n\n{TREASURY[kind]}\n")
        parts.append("Close this issue once the sheet is updated.")
        with open(BODY, "w") as f:
            f.write("\n".join(parts))
    elif first_run:
        print("First run: recorded what exists now; future runs alert on anything new.")

    names = new_ocob + [n for n, _ in new_tsy]
    title = "New report to enter in the sheet: " + "; ".join(
        (f"OCOB {n}" if n in new_ocob else n) for n in names
    ) if names else ""

    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"new={'true' if alert else 'false'}\n")
            f.write(f"title={title[:240]}\n")

    if not dry and (found_ocob or new_tsy):
        state["ocob_national"] = sorted(seen_ocob | found_ocob)
        state["treasury"] = sorted(seen_tsy | {n for n, _ in new_tsy})
        with open(STATE, "w") as f:
            json.dump(state, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
