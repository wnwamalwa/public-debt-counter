#!/usr/bin/env python3
"""
Daily health check for the Kenya Debt Counter: is everything that should
update itself actually updating?

  1. GitHub Actions in each repository: the latest run of every workflow
     failed, timed out, was cancelled after hanging, or has been running for
     over 2 hours.
  2. The quarterly PDF report: latest.json on the `report` branch should be
     dated today (after 15:00 Nairobi) and never more than 2 days old.
  3. The website: key API routes answer with data, the latest debt figure
     is not more than 60 days old, and CBK's latest monthly figure (the last
     "actual" row) is not more than 150 days past its month-end.
  4. One source of truth: every other address that serves the counter
     gives the same figures as the site: www.kenyadebtcounter.or.ke, the
     old api.kenyadebtcounter.or.ke, and the Public Debt Counter box on
     ieakenya.or.ke (its WordPress route, /wp-json/iea/v1/debt-counter,
     which once served a cached 30 October figure for days unnoticed).
     An address that cannot be read is reported too, not skipped.

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

# Other addresses that serve the counter; each must match SITE.
MIRRORS = [m.strip().rstrip("/") for m in os.environ.get(
    "HEALTH_MIRRORS",
    "https://api.kenyadebtcounter.or.ke,https://www.kenyadebtcounter.or.ke,https://ieakenya.or.ke/wp-json/iea/v1/debt-counter",
).split(",") if m.strip()]

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
        # The newest rows are estimates; CBK's own monthly figure is the last "actual"
        # row (dated the 1st, = end of that month). CBK publishes about 3-4 months late.
        actual = [dt.date.fromisoformat(str(r["date"])[:10]) for r in rows if r.get("kind") == "actual"]
        if actual:
            m = max(actual)
            month_end = (m.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
            lag = (now.astimezone(EAT).date() - month_end).days
            if lag > 150:
                problems.append(f"**Website**: CBK's latest monthly debt figure on the site is for {m:%B %Y}, {lag} days ago "
                                "(CBK usually publishes within about 4 months). Check the CBK public debt watch.")
        elif rows and "kind" not in rows[0]:
            problems.append("**Website** `/api/debt/historical`: rows have no `kind`, so the last CBK monthly figure cannot be checked.")
    except Exception as e:
        problems.append(f"**Website** `/api/debt/historical`: could not check the latest date ({e}).")
    return problems


def _num(v):
    """A number, also when wrapped in a one-item list (the old api.kenyadebtcounter.or.ke
    answers {"total": [13593708521665.4]})."""
    if isinstance(v, list):
        v = v[0] if v else None
    return float(v)


def figures(base):
    """(total debt now, growth per second, domestic share %) from an address, or None.

    Most addresses serve the site's API (/api/debt/current and /api/debt/growth).
    The IEA Kenya box is a single WordPress route giving total, growth, domestic,
    external and timestamp in one object."""
    try:
        if "/wp-json/" in base:
            cur = get_json(base + ("&" if "?" in base else "?") + "_nocache=" + str(int(dt.datetime.now().timestamp())), timeout=40)
            cur = cur.get("data", cur)
            growth = _num(cur["growth"])
        else:
            cur = get_json(base + "/api/debt/current", timeout=40)["data"]
            growth = _num(get_json(base + "/api/debt/growth?unit=sec", timeout=40)["data"]["total"])
        total = _num(cur["total"])
        ts = cur.get("timestamp") or cur.get("as_of") or cur.get("asOf")
        if isinstance(ts, list):
            ts = ts[0] if ts else None
        # Bring the total to this instant, so addresses read seconds apart compare fairly.
        if ts:
            lag = (dt.datetime.now(dt.timezone.utc) - parse_time(ts)).total_seconds()
            total += growth * max(0.0, lag)
        dom, ext = _num(cur["domestic"]), _num(cur["external"])
        return total, growth, 100 * dom / (dom + ext)
    except Exception:
        return None


def check_same_source():
    """Every mirror must give the site's figures (total within 0.05%, rate within 1%)."""
    ref = figures(SITE)
    if not ref:
        return []  # the site's own problems are reported by check_site
    problems = []
    for base in MIRRORS:
        got = figures(base)
        host = base.replace("https://", "")
        if got is None:
            problems.append(f"**{host}** could not be read, so it could not be compared with the site. Check that it is up and still serves the counter (or remove it from HEALTH_MIRRORS if it has been retired).")
            continue
        t, g, d = got
        if abs(t / ref[0] - 1) > 0.0005 or abs(g / ref[1] - 1) > 0.01 or abs(d - ref[2]) > 0.2:
            problems.append(
                f"**{host}** gives different figures from the site: KSh {t / 1e12:,.3f} trn at KSh {g:,.0f}/sec "
                f"(domestic {d:.1f}%) against KSh {ref[0] / 1e12:,.3f} trn at KSh {ref[1]:,.0f}/sec (domestic {ref[2]:.1f}%). "
                + ("It is not reading the same source, or is serving a cached figure; check the WordPress route's caching."
                 if "/wp-json/" in base else "It is not reading the same source; point it to Vercel.")
            )
    return problems


def main():
    now = dt.datetime.now(dt.timezone.utc)
    problems = check_actions(now) + check_report(now) + check_site(now) + check_same_source()
    stamp = now.astimezone(EAT).strftime("%d %b %Y, %H:%M EAT")
    sig = hashlib.sha1("\n".join(sorted(p.split(" (")[0] for p in problems)).encode()).hexdigest()[:10]
    if problems:
        body = (f"The daily health check on {stamp} found {len(problems)} problem{'s' if len(problems) != 1 else ''}:\n\n"
                + "\n".join(f"- [ ] {p}" for p in problems)
                + "\n\nThis issue closes itself on the first day everything is back to normal."
                + f"\n\n<!-- health-signature: {sig} -->\n")
    else:
        body = f"All clear on {stamp}: workflows, the quarterly report and the website are all up to date, and every counter address matches the site.\n"
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
