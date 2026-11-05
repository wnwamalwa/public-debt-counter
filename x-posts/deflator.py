"""
Kenya's GDP deflator (2016 = 100), monthly, to express debt in today's prices.

The GDP deflator is the price level of everything produced in Kenya (nominal
GDP / real GDP), published once a year by KNBS; here via the World Bank
(NY.GDP.DEFL.ZS). Each year's value is placed at mid-year and spread across
the months (log-linear). Months after the last published mid-year are
extended at the last published year's rate, until KNBS publishes the next
year (Economic Survey, May): figures for the latest months are therefore
provisional.

monthly_deflator() returns ({(year, month): index}, info) where info has the
last published year, the assumed growth rate and the source used.
If the World Bank cannot be reached, the copy below (as at 5 Nov 2026) is used.
"""
from __future__ import annotations

import math
from datetime import date

import requests

WB_URL = "https://api.worldbank.org/v2/country/KEN/indicator/NY.GDP.DEFL.ZS?format=json&per_page=200&date=1995:2100"

ANNUAL_FALLBACK = {
    1999: 23.9671331735388, 2000: 25.4242985577041, 2001: 25.8242533586918, 2002: 26.0652467258036,
    2003: 27.6805917119225, 2004: 29.6533436247326, 2005: 31.1062535927873, 2006: 38.4255965125675,
    2007: 41.5493998462851, 2008: 47.8446221135969, 2009: 61.0960592465264, 2010: 62.0975456346528,
    2011: 68.3476716551131, 2012: 74.85640143407, 2013: 80.3490364751316, 2014: 86.4837110425477,
    2015: 94.473642463645, 2016: 100.0, 2017: 107.581934028202, 2018: 112.116543116457,
    2019: 116.909787955755, 2020: 122.695481308957, 2021: 128.009112870216, 2022: 136.914776561639,
    2023: 144.329814758812, 2024: 148.898786348343, 2025: 154.10001586802,
}


def _annual() -> tuple[dict[int, float], str]:
    try:
        r = requests.get(WB_URL, timeout=30, headers={"User-Agent": "kdc-x-posts"})
        r.raise_for_status()
        out = {int(x["date"]): float(x["value"]) for x in r.json()[1] if x.get("value") is not None}
        if len(out) >= 20:
            return out, "World Bank"
    except Exception:
        pass
    return dict(ANNUAL_FALLBACK), "stored copy"


def monthly_deflator(until: date) -> tuple[dict[tuple[int, int], float], dict]:
    annual, src = _annual()
    years = sorted(annual)
    last = years[-1]
    growth = annual[last] / annual[last - 1] - 1
    pts = [(y + 0.5, math.log(annual[y])) for y in years]
    out: dict[tuple[int, int], float] = {}
    y, m = years[0], 1
    while (y, m) <= (until.year, until.month):
        x = y + (m - 0.5) / 12
        if x <= pts[0][0]:
            v = annual[years[0]]
        elif x >= pts[-1][0]:  # after the last published year: extended at its rate
            v = annual[last] * (1 + growth) ** (x - pts[-1][0])
        else:
            for (x0, l0), (x1, l1) in zip(pts, pts[1:]):
                if x0 <= x <= x1:
                    v = math.exp(l0 + (l1 - l0) * (x - x0) / (x1 - x0))
                    break
        out[(y, m)] = v
        y, m = (y, m + 1) if m < 12 else (y + 1, 1)
    info = {"last_year": last, "growth": growth, "source": src, "annual": annual}
    return out, info


def deflator(index: dict[tuple[int, int], float]):
    """f(date_iso, value) -> value in the latest month's prices."""
    latest = max(index)
    base = index[latest]

    def f(d: str, v: float) -> float:
        return v * base / index.get((int(d[:4]), int(d[5:7])), base)
    return f


SHEET_HEADER = ["month", "gdp_deflator_2016_100", "annual_change_pct", "source", "annual_value_world_bank"]


def sheet_rows(index: dict[tuple[int, int], float], info: dict) -> list[list]:
    annual, last = info["annual"], info["last_year"]
    rows = []
    for (y, m) in sorted(index):
        prev = index.get((y - 1, m))
        provisional = y + (m - 0.5) / 12 > last + 0.5
        src = (f"Extended at {last}'s rate ({info['growth'] * 100:.1f}%) until KNBS publishes {last + 1}"
               if provisional else "KNBS via the World Bank, annual, spread across the months")
        rows.append([f"{y}-{m:02d}", round(index[(y, m)], 3),
                     round((index[(y, m)] / prev - 1) * 100, 2) if prev else "", src,
                     round(annual[y], 3) if m == 7 and y in annual else ""])
    return rows
