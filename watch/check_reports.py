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

  KNBS
    Leading Economic Indicators (monthly), listed at
    https://www.knbs.or.ke/leading-economic-indicators/ : Table 19(d) has
    SGR passenger and freight revenue (site_inputs tab, Chart 14).

  OCOB county reports
    County Governments Budget Implementation Review Reports: county pending
    bills (site_inputs tab, Chart 15).

  National Treasury Annual Borrowing Plan: principal due (site_inputs, Chart 6).

  Yearly reminders for figures with no listing to watch: Kenya Railways'
  accounts (November) and payments to Chinese lenders (August).

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


def ocob_county_titles():
    """Titles in the County section of the OCOB publications pages."""
    titles = set()
    for url in OCOB_PAGES + ["https://cob.go.ke/publications/?&cp_county-governments=2"]:
        try:
            _, raw = get(url)
        except Exception as e:
            print(f"OCOB county: could not read {url}: {e}", file=sys.stderr)
            continue
        text = page_text(raw)
        a = re.search(r"(Consolidated\s+)?County (Governments\s+)?Budget Implementation Review Reports?", text, re.I)
        if not a:
            continue
        for m in TITLE_RE.finditer(text[a.end(): a.end() + 20000]):
            t = canonical(m)
            if t:
                titles.add(t)
    return titles


KNBS_LEI_PAGES = [
    "https://www.knbs.or.ke/leading-economic-indicators/",
    "https://new.knbs.or.ke/leading-economic-indicators/",
]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
LEI_RE = re.compile(r"(?:Leading\s+Economic\s+Indicators|LEI)[\s,–-]*(" + "|".join(MONTHS) + r")[\s,]*(20\d\d)"
                    r"|(" + "|".join(MONTHS) + r")[\s,]*(20\d\d)[\s,–-]*(?:Leading\s+Economic\s+Indicators|LEI)", re.I)


def knbs_lei():
    """{'2026-08': pdf_url_or_page, ...} for every LEI edition listed."""
    found = {}
    for url in KNBS_LEI_PAGES:
        try:
            _, raw = get(url)
        except Exception as e:
            print(f"KNBS: could not read {url}: {e}", file=sys.stderr)
            continue
        pdfs = re.findall(r'href="([^"]+\.pdf)"', raw, re.I)
        for m in LEI_RE.finditer(page_text(raw)):
            mon, yr = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
            mi = next(i for i, x in enumerate(MONTHS) if x.lower() == mon.lower()) + 1
            key = f"{yr}-{mi:02d}"
            pdf = next((p for p in pdfs if mon.lower() in p.lower() and yr in p), url)
            found.setdefault(key, pdf)
        if found:
            break
    return found


def abp_candidates(today):
    y = today.year
    out = {}
    for fy in (y, y + 1):  # the plan for FY fy/fy+1 comes out around June-July of fy
        name = f"Annual Borrowing Plan FY {fy}/{str(fy + 1)[2:]}"
        out[name] = [
            f"https://www.treasury.go.ke/sites/default/files/Annual%20borrowing/Annual%20Borrowing%20Plan%20FY%20{fy}-{fy + 1}.pdf",
            f"https://www.treasury.go.ke/sites/default/files/Annual-Borrowing-Plan-FY-{fy}-{fy + 1}.pdf",
        ]
    return out


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
    "Medium Term Debt Management Strategy": f"""In the quarterly report (`quarterly_macro_debt_report_ieakenya.qmd`, the `treasury-inputs` chunk):
- [ ] `mtds_year`, the DSA table `dsa_indicators` (Latest values), and the weighted average interest rates `wair_domestic` / `wair_external`.

In the **`site_inputs`** tab of the [IEA macro data sheet]({SHEET}) (Chart 6, Maturity view), one row each with `period` = the end-June year (e.g. 2026):
- [ ] Table "Domestic Debt Securities by Maturity Profile": `dom_sec_lt1`, `dom_sec_y2_3`, `dom_sec_y4_5`, `dom_sec_y6_10`, `dom_sec_gt10` (unit `USD m`).
- [ ] Table "Cost and Risk Indicators": `atm_external`, `atm_domestic`, `atm_total` (unit `years`); `due1y_external`, `due1y_domestic`, `due1y_total` (debt maturing in 1 yr, % of total, unit `%`); `due1y_total_gdp` (% of GDP, unit `%`).""",
    "Annual Borrowing Plan": f"""In the **`site_inputs`** tab of the [IEA macro data sheet]({SHEET}) (Chart 6, Maturity view), `period` = the plan's fiscal year (e.g. FY2027/28), unit `KSh bn`, from the gross financing table:
- [ ] `principal_due_domestic` (domestic principal, excluding Treasury bills) and `principal_due_external`.""",
}

KNBS_LEI = f"""In the **`site_inputs`** tab of the [IEA macro data sheet]({SHEET}) (Chart 14, the SGR), from Table 19(d) "Standard Gauge Railway" (revenue, KSh):
- [ ] one `sgr_passenger_revenue` row and one `sgr_freight_revenue` row for each new month, `period` = YYYY-MM, unit `KSh`. If KNBS revised earlier months, correct those rows too.
The chart moves to the new fiscal year by itself once all 12 months of a year are in."""

OCOB_COUNTY = f"""County Governments Budget Implementation Review Report. In the **`site_inputs`** tab of the [IEA macro data sheet]({SHEET}) (Chart 15):
- [ ] `county_pending_bills`: total pending bills of the 47 counties at the report's end date (`period` = YYYY-MM-DD, unit `KSh bn`), with the report's link in `source_url`."""

REMINDERS = {
    # month: (key, title, body)
    8: ("china_payments", "Payments to Chinese lenders for the fiscal year just ended",
        f"""When the National Treasury's figures for the year to June are out (Budget Review and Outlook Paper, Quarterly Economic and Budget Review, or press reports of Treasury data), in the **`site_inputs`** tab of the [IEA macro data sheet]({SHEET}):
- [ ] `china_payments`: total paid to Chinese lenders, principal + interest, all loans, `period` = the fiscal year (e.g. FY2026/27), unit `KSh bn` (Chart 14)."""),
    11: ("krc_accounts", "Kenya Railways' annual accounts (SGR revenue and interest)",
         f"""Kenya Railways' financial statements for the fiscal year to June usually appear (or are reported) from October. In the **`site_inputs`** tab of the [IEA macro data sheet]({SHEET}) (Chart 14), `period` = the fiscal year:
- [ ] `krc_sgr_freight_revenue` and `krc_sgr_interest` (unit `KSh bn`; put "Capitalised (added to the debt), not paid" in `note` if the interest was capitalised).
- [ ] `krc_arrears`: the unpaid balance to the Treasury on the on-lent SGR loan at 30 June (`period` = YYYY-06-30)."""),
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

    # ABP: same probing as the Treasury reports, same state list.
    for name, urls in abp_candidates(today).items():
        if name in seen_tsy:
            continue
        hit = next((u for u in urls if exists(u)), None)
        if hit:
            new_tsy.append((name, hit))

    # Sources added later have their own "first run": record silently.
    found_county = ocob_county_titles()
    county_first = "ocob_county" not in state
    new_county = [] if county_first else sorted(found_county - set(state.get("ocob_county", [])))

    found_lei = knbs_lei()
    lei_first = "knbs_lei" not in state
    # Only editions newer than the newest already seen (older ones resurface as the listing pages).
    newest_seen = max(state.get("knbs_lei", []) or ["0000-00"])
    new_lei = [] if lei_first else sorted(k for k in found_lei if k > newest_seen)

    reminders = state.get("reminders", [])
    due = []
    if today.month in REMINDERS:
        key, rtitle, rbody = REMINDERS[today.month]
        tag = f"{key}-{today.year}"
        if tag not in reminders:
            due.append((tag, rtitle, rbody))

    print("OCOB county reports listed:", ", ".join(sorted(found_county)) or "none")
    print("KNBS LEI editions listed:", ", ".join(sorted(found_lei)) or "none")
    print("OCOB national reports listed:", ", ".join(sorted(found_ocob)) or "none")
    print("New OCOB:", new_ocob or "none")
    print("New Treasury:", [n for n, _ in new_tsy] or "none")

    alert = (new_ocob or new_tsy or new_county or new_lei or due) and not first_run
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
        for t in new_county:
            parts.append(f"## OCOB: County Governments Budget Implementation Review Report, {t}\n"
                         "Find it under *County Budget Implementation Review Reports* at https://cob.go.ke/publications/\n\n"
                         + OCOB_COUNTY + "\n")
        for k in new_lei:
            y, mth = k.split("-")
            parts.append(f"## KNBS: Leading Economic Indicators, {MONTHS[int(mth) - 1]} {y}\n{found_lei[k]}\n\n{KNBS_LEI}\n")
        for _, rtitle, rbody in due:
            parts.append(f"## Reminder: {rtitle}\n{rbody}\n")
        parts.append("Close this issue once the sheet is updated.")
        with open(BODY, "w") as f:
            f.write("\n".join(parts))
    elif first_run:
        print("First run: recorded what exists now; future runs alert on anything new.")

    names = new_ocob + [n for n, _ in new_tsy] + [f"OCOB county {t}" for t in new_county] + [f"KNBS LEI {k}" for k in new_lei] + [r[1] for r in due]
    title = "New data to enter in the sheet: " + "; ".join(
        (f"OCOB {n}" if n in new_ocob else n) for n in names
    ) if names else ""

    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"new={'true' if alert else 'false'}\n")
            f.write(f"title={title[:240]}\n")

    if not dry:
        if found_ocob:
            state["ocob_national"] = sorted(seen_ocob | found_ocob)
        state["treasury"] = sorted(seen_tsy | {n for n, _ in new_tsy})
        if found_county or "ocob_county" in state:
            state["ocob_county"] = sorted(set(state.get("ocob_county", [])) | found_county)
        if found_lei or "knbs_lei" in state:
            state["knbs_lei"] = sorted(set(state.get("knbs_lei", [])) | set(found_lei))
        if due and alert:
            state["reminders"] = sorted(set(reminders) | {t for t, _, _ in due})
        with open(STATE, "w") as f:
            json.dump(state, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
