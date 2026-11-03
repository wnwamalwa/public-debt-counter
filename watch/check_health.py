#!/usr/bin/env python3
"""
Daily health check for the Kenya Debt Counter: is everything that should
update itself actually updating?

  1. GitHub Actions in each repository: the latest run of every workflow
     failed, timed out, was cancelled after hanging, or has been running for
     over 2 hours.
  2. The quarterly PDF report: latest.json on the `report` branch should be
     dated today (after 15:00 Nairobi) and never more than 2 days old.
  3. The website: key API routes answer with data, and the latest debt
     figure is not more than 60 days old.

Writes to $GITHUB_OUTPUT:
    problems=true|false
    signature=<short hash of the problem list, to tell new problems from old>
and the issue body (markdown) to watch/health.md.

Usage: python3 watch/check_health.py            (normal)
       python3 watch/check_health.py --print    (just print)
"""
import datetime as dt
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

REPOS = [r.strip() for r in os.environ.get(
    "HEALTH_REPOS",
    "wnwamalwa/public-debt-counter,wnwamalwa/quarterly-macro-debt-report,wnwamalwa/kenya-debt-counter-web",
).split(",") if r.strip()]
SITE = os.environ.get("SITE_URL", "https://kenyadebtcounter.vercel.app").rstrip("/")
REPORT_JSON = "https://raw.githubusercontent.com/wnwamalwa/quarterly-macro-debt-report/report/latest.json"
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
EAT = dt.timezone(dt.timedelta(hours=3))
UA = "KenyaDebtCounterHealth/1.0"
HERE = os.path.dirname(os.path.abspath(__file__))
BODY = os.path.join(HERE, "health.md")

# Site routes that must answer {success: true}.
ROUTES = ["/api/debt/current", "/api/debt/service", "/api/debt/spending", "/api/debt/tax-revenue", "/api/debt/site-inputs"]


def get_json(url, auth=False, timeout=40):
    headers = {"User-Agent": UA, "Accept": "application/json"}
    if auth and TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def parse_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def check_actions(now):
    problems = []
    for repo in REPOS:
        try:
            wfs = get_json(f"https://api.github.com/repos/{repo}/actions/workflows?per_page=100", auth=True)["workflows"]
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue  # no Actions or not readable: nothing to check
            problems.append(f"**{repo}**: could not read GitHub Actions ({e.code}).")
            continue
        except Exception as e:
            problems.append(f"**{repo}**: could not read GitHub Actions ({e}).")
            continue
        for wf in wfs:
            if wf.get("state") != "active" or "dynamic/" in wf.get("path", ""):
                continue
            try:
                runs = get_json(
                    f"https://api.github.com/repos/{repo}/actions/workflows/{wf['id']}/runs?per_page=5&exclude_pull_requests=true",
                    auth=True,
                )["workflow_runs"]
            except Exception as e:
                problems.append(f"**{repo} · {wf['name']}**: could not read runs ({e}).")
                continue
            if not runs:
                continue
            r = runs[0]
            started = parse_time(r.get("run_started_at") or r.get("created_at"))
            updated = parse_time(r.get("updated_at"))
            link = r.get("html_url", "")
            when = started.astimezone(EAT).strftime("%d %b %H:%M") if started else "?"
            if r["status"] != "completed":
                if started and now - started > dt.timedelta(hours=2):
                    problems.append(f"**{repo} · {wf['name']}**: running for over 2 hours since {when} EAT, probably stuck ([run]({link})).")
                continue
            c = r.get("conclusion")
            if c in ("failure", "timed_out", "startup_failure"):
                problems.append(f"**{repo} · {wf['name']}**: last run {c.replace('_', ' ')} ({when} EAT, [run]({link})).")
            elif c == "cancelled" and started and updated and updated - started > dt.timedelta(minutes=50):
                problems.append(f"**{repo} · {wf['name']}**: last run hung and was cancelled after {int((updated - started).total_seconds() // 3600)} h ({when} EAT, [run]({link})).")
    return problems


def check_report(now):
    try:
        e = get_json(REPORT_JSON)
        published = dt.date.fromisoformat(e["published"])
    except Exception as ex:
        return [f"**Quarterly report**: could not read latest.json ({ex})."]
    today = now.astimezone(EAT).date()
    age = (today - published).days
    if age >= 2 or (age >= 1 and now.astimezone(EAT).hour >= 15):
        return [f"**Quarterly report**: last rebuilt {published:%d %b %Y} ({age} day{'s' if age != 1 else ''} ago); the website card shows that date. Check the *Render Quarto PDF Report* workflow."]
    return []


def check_site(now):
    problems = []
    for route in ROUTES:
        try:
            b = get_json(SITE + route, timeout=60)
            if not b.get("success"):
                problems.append(f"**Website** `{route}`: answered without data.")
        except urllib.error.HTTPError as e:
            problems.append(f"**Website** `{route}`: HTTP {e.code}.")
        except Exception as e:
            problems.append(f"**Website** `{route}`: no answer ({e}).")
    try:
        rows = get_json(SITE + "/api/debt/historical", timeout=60)["data"]
        last = max(dt.date.fromisoformat(str(r["date"])[:10]) for r in rows)
        age = (now.astimezone(EAT).date() - last).days
        if age > 60:
            problems.append(f"**Website**: the latest debt figure is dated {last:%d %b %Y}, {age} days ago. Check the CBK watch workflows.")
    except Exception as e:
        problems.append(f"**Website** `/api/debt/historical`: could not check the latest date ({e}).")
    return problems


def main():
    now = dt.datetime.now(dt.timezone.utc)
    problems = check_actions(now) + check_report(now) + check_site(now)
    stamp = now.astimezone(EAT).strftime("%d %b %Y, %H:%M EAT")
    sig = hashlib.sha1("\n".join(sorted(p.split(" (")[0] for p in problems)).encode()).hexdigest()[:10]
    if problems:
        body = (f"The daily health check on {stamp} found {len(problems)} problem{'s' if len(problems) != 1 else ''}:\n\n"
                + "\n".join(f"- [ ] {p}" for p in problems)
                + "\n\nThis issue closes itself on the first day everything is back to normal."
                + f"\n\n<!-- health-signature: {sig} -->\n")
    else:
        body = f"All clear on {stamp}: workflows, the quarterly report and the website are all up to date.\n"
    print(body)
    if "--print" in sys.argv:
        return
    with open(BODY, "w") as f:
        f.write(body)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"problems={'true' if problems else 'false'}\n")
            f.write(f"signature={sig}\n")


if __name__ == "__main__":
    main()
