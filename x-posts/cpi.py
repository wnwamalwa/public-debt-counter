"""
Consumer prices for Kenya, monthly, to express debt in today's shillings.

  annual CPI (2010 = 100), KNBS via the World Bank (FP.CPI.TOTL), placed at
  mid-year and spread across the months (log-linear); months after the last
  annual mid-year come from CBK's 12-month inflation rates (the site's
  /api/debt/market-rates): CPI(month) = CPI(same month a year earlier) x (1 + rate).

monthly_cpi() returns ({(year, month): index}, (year, month) of the latest).
If either source cannot be reached, the copy below (as at 5 Nov 2026) is used.
"""
from __future__ import annotations

import math

import requests

WB_URL = "https://api.worldbank.org/v2/country/KEN/indicator/FP.CPI.TOTL?format=json&per_page=200&date=1995:2100"
RATES_URL = "https://kenyadebtcounter.vercel.app/api/debt/market-rates"

ANNUAL_FALLBACK = {
    1999: 34.6316272236208, 2000: 38.0878723316079, 2001: 40.2735822660957, 2002: 41.0634713445186,
    2003: 45.0941346535517, 2004: 50.3358928940491, 2005: 55.5269219624651, 2006: 63.5526356768982,
    2007: 69.7546612757899, 2008: 88.0581564955536, 2009: 96.1895575526589, 2010: 100.0,
    2011: 114.02249130147, 2012: 124.715258324442, 2013: 131.845845200422, 2014: 140.914406784821,
    2015: 150.189610460249, 2016: 159.647425011301, 2017: 172.428238576215, 2018: 180.514789261213,
    2019: 189.973110678512, 2020: 200.241465217838, 2021: 212.472085832077, 2022: 228.74715584593,
    2023: 246.295256788022, 2024: 257.35339300785, 2025: 267.825894204192,
}
RATES_FALLBACK = {
    "2024-12": 2.99,
    "2025-01": 3.28, "2025-02": 3.45, "2025-03": 3.62, "2025-04": 4.11, "2025-05": 3.75, "2025-06": 3.82,
    "2025-07": 4.15, "2025-08": 4.53, "2025-09": 4.58, "2025-10": 4.56, "2025-11": 4.46, "2025-12": 4.49,
    "2026-01": 4.40, "2026-02": 4.25, "2026-03": 4.39, "2026-04": 5.59, "2026-05": 6.68, "2026-06": 6.41,
    "2026-07": 6.49, "2026-08": 6.59, "2026-09": 6.76, "2026-10": 7.32,
}


def _annual() -> tuple[dict[int, float], str]:
    try:
        r = requests.get(WB_URL, timeout=30, headers={"User-Agent": "kdc-x-posts"})
        r.raise_for_status()
        rows = r.json()[1]
        out = {int(x["date"]): float(x["value"]) for x in rows if x.get("value") is not None}
        if len(out) >= 20:
            return out, "World Bank"
    except Exception:
        pass
    return dict(ANNUAL_FALLBACK), "stored copy"


def _rates() -> tuple[dict[str, float], str]:
    try:
        r = requests.get(RATES_URL, timeout=30, headers={"User-Agent": "kdc-x-posts"})
        r.raise_for_status()
        d = r.json()
        d = d.get("data", d)
        out = {str(m.get("month") or m.get("date"))[:7]: float(m["inflation"])
               for m in d.get("months", []) if m.get("inflation") is not None}
        if out:
            return out, "CBK via the site"
    except Exception:
        pass
    return dict(RATES_FALLBACK), "stored copy"


def monthly_cpi() -> tuple[dict[tuple[int, int], float], tuple[int, int], str]:
    annual, a_src = _annual()
    rates, r_src = _rates()
    pts = sorted((y + 0.5, math.log(v)) for y, v in annual.items())
    cpi: dict[tuple[int, int], float] = {}
    for y in range(int(pts[0][0]), int(pts[-1][0]) + 1):
        for m in range(1, 13):
            x = y + (m - 0.5) / 12
            for (x0, l0), (x1, l1) in zip(pts, pts[1:]):
                if x0 <= x <= x1:
                    cpi[(y, m)] = math.exp(l0 + (l1 - l0) * (x - x0) / (x1 - x0))
                    break
    first = min(annual)
    for m in range(1, 7):
        cpi.setdefault((first, m), annual[first])
    for ym in sorted(rates):
        y, m = map(int, ym.split("-"))
        if (y, m) not in cpi and (y - 1, m) in cpi:
            cpi[(y, m)] = cpi[(y - 1, m)] * (1 + rates[ym] / 100)
    latest = max(cpi)
    return cpi, latest, f"annual CPI: {a_src}; monthly inflation: {r_src}"


def deflator(cpi: dict[tuple[int, int], float], latest: tuple[int, int]):
    """f(date_iso, value) -> value in the latest month's prices."""
    base = cpi[latest]

    def f(d: str, v: float) -> float:
        k = (int(d[:4]), int(d[5:7]))
        return v * base / cpi.get(k, base)
    return f
