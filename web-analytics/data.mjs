// Data for the monthly readership report.
//
//   loadSupabase(month)  reads web_daily + web_daily_breakdown (filled daily
//                        from Vercel Web Analytics by ../web_analytics.R)
//   loadSample(month)    made-up but realistic figures, for the layout sample
//
// Both return the same shape:
// {
//   month: "2026-10", sample: bool,
//   daily:   [{ date, pageviews, visitors }]            this month, every day
//   monthly: [{ month, pageviews, visitors, kenya }]    last 12 months, oldest first (kenya = readers in Kenya)
//   breakdown: { page|country|referrer|device|utm_source: [{ value, pageviews, visitors }] }  this month
//   prevBreakdown: { page|country: [...] }              last month, for "change" columns
// }

const DIMENSIONS = ["page", "country", "referrer", "device", "utm_source"];

export function monthRange(month) {
  const [y, m] = month.split("-").map(Number);
  const first = new Date(Date.UTC(y, m - 1, 1));
  const last = new Date(Date.UTC(y, m, 0));
  return { first, last, days: last.getUTCDate() };
}
export const iso = (d) => d.toISOString().slice(0, 10);
export function addMonths(month, n) {
  const [y, m] = month.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + n, 1));
  return d.toISOString().slice(0, 7);
}

/* ------------------------------------------------------------------ Supabase */

async function sbGet(table, query) {
  const url = `${process.env.SUPABASE_URL}/rest/v1/${table}?${query}`;
  const key = process.env.SUPABASE_SERVICE_ROLE;
  const out = [];
  for (let offset = 0; ; offset += 1000) {
    const res = await fetch(url, {
      headers: { apikey: key, Authorization: `Bearer ${key}`, Range: `${offset}-${offset + 999}` },
    });
    if (!res.ok) throw new Error(`Reading ${table} failed: HTTP ${res.status} ${await res.text()}`);
    const rows = await res.json();
    out.push(...rows);
    if (rows.length < 1000) return out;
  }
}

function sumBy(rows, key) {
  const m = new Map();
  for (const r of rows) {
    const k = r[key];
    const cur = m.get(k) ?? { value: k, pageviews: 0, visitors: 0 };
    cur.pageviews += Number(r.pageviews) || 0;
    cur.visitors += Number(r.visitors) || 0;
    m.set(k, cur);
  }
  return [...m.values()].sort((a, b) => b.visitors - a.visitors || b.pageviews - a.pageviews);
}

export async function loadSupabase(month) {
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE) {
    throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE must be set (or use --sample).");
  }
  const { first, last } = monthRange(month);
  const yearStart = monthRange(addMonths(month, -11)).first;
  const prev = monthRange(addMonths(month, -1));

  const days = await sbGet("web_daily", `select=date,pageviews,visitors&date=gte.${iso(yearStart)}&date=lte.${iso(last)}&order=date.asc`);
  const bd = await sbGet(
    "web_daily_breakdown",
    `select=date,dimension,value,pageviews,visitors&date=gte.${iso(prev.first)}&date=lte.${iso(last)}`,
  );

  const ke = await sbGet(
    "web_daily_breakdown",
    `select=date,visitors&dimension=eq.country&value=eq.KE&date=gte.${iso(yearStart)}&date=lte.${iso(last)}`,
  );
  const byDate = new Map(days.map((d) => [String(d.date).slice(0, 10), d]));
  const daily = [];
  for (let d = new Date(first); d <= last; d.setUTCDate(d.getUTCDate() + 1)) {
    const r = byDate.get(iso(d));
    daily.push({ date: iso(d), pageviews: Number(r?.pageviews) || 0, visitors: Number(r?.visitors) || 0 });
  }
  const monthly = [];
  for (let i = 11; i >= 0; i--) {
    const mo = addMonths(month, -i);
    const rows = days.filter((d) => String(d.date).startsWith(mo));
    monthly.push({
      month: mo,
      pageviews: rows.reduce((s, r) => s + (Number(r.pageviews) || 0), 0),
      visitors: rows.reduce((s, r) => s + (Number(r.visitors) || 0), 0),
      hasData: rows.length > 0,
      kenya: ke.filter((r) => String(r.date).startsWith(mo)).reduce((s, r) => s + (Number(r.visitors) || 0), 0),
    });
  }
  const inMonth = (r, mo) => String(r.date).startsWith(mo);
  const breakdown = {};
  const prevBreakdown = {};
  for (const dim of DIMENSIONS) {
    breakdown[dim] = sumBy(bd.filter((r) => r.dimension === dim && inMonth(r, month)), "value");
    prevBreakdown[dim] = sumBy(bd.filter((r) => r.dimension === dim && inMonth(r, addMonths(month, -1))), "value");
  }
  return { month, sample: false, daily, monthly, breakdown, prevBreakdown };
}

/* -------------------------------------------------------------------- Sample */

function rng(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

function spread(total, shares, r, jitter = 0.08) {
  const w = shares.map(([, s]) => s * (1 + (r() - 0.5) * jitter));
  const sum = w.reduce((a, b) => a + b, 0);
  return shares.map(([value], i) => ({ value, n: Math.round((total * w[i]) / sum) }));
}

export function loadSample(month) {
  const r = rng(20261025);
  const { first, days } = monthRange(month);

  // Monthly growth since launch (mid-2026), with a spike in the budget month (June).
  const base = { "-11": 0, "-10": 0, "-9": 0, "-8": 0, "-7": 0, "-6": 0, "-5": 1850, "-4": 6900, "-3": 5200, "-2": 7400, "-1": 9600, "0": 12400 };
  const monthly = Object.entries(base)
    .sort((a, b) => Number(a[0]) - Number(b[0]))
    .map(([k, v]) => ({
      month: addMonths(month, Number(k)),
      visitors: v,
      pageviews: Math.round(v * (2.3 + r() * 0.4)),
      hasData: v > 0,
      kenya: Math.round(v * (0.71 + r() * 0.07)),
    }));
  const cur = monthly[monthly.length - 1];

  // Daily: weekday rhythm, two news spikes (CBK release; a TV interview).
  const daily = [];
  const weights = [];
  for (let i = 0; i < days; i++) {
    const d = new Date(first);
    d.setUTCDate(i + 1);
    const dow = d.getUTCDay();
    let w = [0.55, 1.05, 1.1, 1.08, 1.0, 0.92, 0.6][dow] * (0.9 + r() * 0.2);
    if (i === 15) w *= 2.6; // 16th: new CBK debt figures
    if (i === 16) w *= 1.7;
    if (i === 21) w *= 1.9; // 22nd: media mention
    weights.push(w);
  }
  const wsum = weights.reduce((a, b) => a + b, 0);
  weights.forEach((w, i) => {
    const d = new Date(first);
    d.setUTCDate(i + 1);
    const visitors = Math.round((cur.visitors * w) / wsum);
    daily.push({ date: iso(d), visitors, pageviews: Math.round(visitors * (2.3 + r() * 0.5)) });
  });

  const withPv = (rows, ratio) =>
    rows.map(({ value, n }) => ({ value, visitors: n, pageviews: Math.round(n * ratio * (0.85 + r() * 0.3)) }));
  const ratio = cur.pageviews / cur.visitors;

  const countryShares = [
    ["KE", 74.0], ["US", 5.2], ["GB", 3.6], ["UG", 2.1], ["TZ", 1.7], ["ZA", 1.3], ["NG", 1.1], ["DE", 0.9],
    ["IN", 0.8], ["RW", 0.7], ["ET", 0.6], ["AE", 0.6], ["CA", 0.5], ["NL", 0.45], ["FR", 0.4], ["GH", 0.35],
    ["SS", 0.3], ["BE", 0.3], ["CH", 0.25], ["SE", 0.25], ["CN", 0.22], ["SO", 0.2], ["BI", 0.18], ["ZM", 0.17],
    ["CD", 0.15], ["EG", 0.15], ["AU", 0.14], ["IT", 0.12], ["QA", 0.12], ["SA", 0.11], ["ZW", 0.1], ["MW", 0.1],
    ["MZ", 0.08], ["SN", 0.08], ["CM", 0.07], ["BR", 0.06], ["JP", 0.06], ["IE", 0.06], ["NO", 0.05], ["BW", 0.05],
    ["NA", 0.04], ["MA", 0.04], ["CI", 0.04], ["SG", 0.04], ["ES", 0.04], ["DK", 0.03], ["FI", 0.03], ["MG", 0.02],
  ];
  const pageShares = [
    ["/", 58], ["/explore", 21], ["/methodology", 6.5], ["/about", 3.2], ["/embed-counter", 1.6],
    ["/c/chart-gdp", 3.1], ["/c/chart-nominal", 2.4], ["/present", 1.1], ["/c/chart-deficit", 1.6], ["/home", 1.5],
  ];
  const refShares = [
    ["(direct)", 38], ["google.com", 22], ["x.com", 11], ["facebook.com", 7], ["linkedin.com", 5.5],
    ["nation.africa", 4.2], ["the-star.co.ke", 3.1], ["ieakenya.or.ke", 2.8], ["whatsapp.com", 2.6],
    ["citizen.digital", 1.9], ["bing.com", 0.9],
  ];
  const deviceShares = [["mobile", 71], ["desktop", 27], ["tablet", 2]];
  const utmShares = [["(none)", 91.5], ["embed", 6.1], ["newsletter", 2.4]];

  const mk = (shares, total, rat) => withPv(spread(total, shares, r), rat).sort((a, b) => b.visitors - a.visitors);
  const prevTotal = monthly[monthly.length - 2].visitors;
  const prevRatio = monthly[monthly.length - 2].pageviews / prevTotal;
  const breakdown = {
    country: mk(countryShares, cur.visitors, ratio),
    page: mk(pageShares, cur.visitors * 1.25, ratio * 0.8),
    referrer: mk(refShares, cur.visitors, ratio),
    device: mk(deviceShares, cur.visitors, ratio),
    utm_source: mk(utmShares, cur.visitors, ratio),
  };
  const prevBreakdown = {
    country: mk(countryShares, prevTotal, prevRatio),
    page: mk(
      pageShares.map(([v, s]) => [v, v === "/explore" ? s * 0.7 : s]),
      prevTotal * 1.2,
      prevRatio * 0.8,
    ),
  };
  return { month, sample: true, daily, monthly, breakdown, prevBreakdown };
}
