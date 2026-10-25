// Copies the Kenya Debt Counter's Vercel Web Analytics into Supabase, one row
// per day (web_daily) and per day x dimension value (web_daily_breakdown), so
// the history is kept permanently whatever the Vercel plan's reporting window.
//
//   node collect.mjs                 last 3 complete days (re-fetched: late data settles)
//   DAYS=31 node collect.mjs         backfill (Hobby keeps about a month)
//   DRY_RUN=true node collect.mjs    fetch and print, write nothing
//
// Env: VERCEL_TOKEN (read access), VERCEL_PROJECT (default kenyadebtcounter),
//      VERCEL_TEAM (team slug, default iea-kenya), SUPABASE_URL, SUPABASE_SERVICE_ROLE.
// Days are UTC days, as Vercel reports them.

const env = (k, d = "") => (process.env[k] ?? d).trim();
const TOKEN = env("VERCEL_TOKEN");
const PROJECT = env("VERCEL_PROJECT", "kenyadebtcounter");
const TEAM = env("VERCEL_TEAM", "iea-kenya");
const SB_URL = env("SUPABASE_URL").replace(/\/+$/, "");
const SB_KEY = env("SUPABASE_SERVICE_ROLE");
const DAYS = Math.max(1, Math.min(400, Number(env("DAYS", "3")) || 3));
const DRY_RUN = /^(1|true|yes)$/i.test(env("DRY_RUN"));

// Our name -> Vercel dimension, and the label stored when Vercel has no value.
const DIMENSIONS = {
  page: ["requestPath", "(unknown)"],
  country: ["country", "(unknown)"],
  referrer: ["referrerHostname", "(direct)"],
  device: ["deviceType", "(unknown)"],
  utm_source: ["utmSource", "(none)"],
};

const notice = (msg) => console.log(process.env.GITHUB_ACTIONS ? `::notice::${msg}` : msg);
const fail = (msg) => {
  console.log(process.env.GITHUB_ACTIONS ? `::error::${msg}` : `ERROR: ${msg}`);
  process.exit(1);
};
if (!TOKEN) fail("VERCEL_TOKEN is not set.");
if (!DRY_RUN && (!SB_URL || !SB_KEY)) fail("SUPABASE_URL and SUPABASE_SERVICE_ROLE must be set (or DRY_RUN=true).");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = (d) => d.toISOString().slice(0, 10);

// Breakdowns the Vercel plan doesn't include (HTTP 402, e.g. UTM on Hobby) are
// skipped with one warning instead of failing the run.
const PLAN_LIMITED = new Set();

async function vercel(path, params, { optional = false } = {}) {
  const url = new URL(`${env("VERCEL_API", "https://api.vercel.com")}/v1/query/web-analytics/${path}`);
  url.searchParams.set("projectId", PROJECT);
  if (TEAM) url.searchParams.set(TEAM.startsWith("team_") ? "teamId" : "slug", TEAM);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
  for (let attempt = 1; ; attempt++) {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${TOKEN}` } });
    if (res.status === 429 && attempt <= 5) {
      await sleep(Number(res.headers.get("retry-after")) * 1000 || 2000 * attempt);
      continue;
    }
    if (res.status === 402 && optional) {
      if (!PLAN_LIMITED.has(params.by)) {
        PLAN_LIMITED.add(params.by);
        console.log(`::warning::Vercel's current plan doesn't include the "${params.by}" breakdown (HTTP 402); skipping it. ${(await res.text()).slice(0, 160)}`);
      }
      return null;
    }
    if (!res.ok) fail(`Vercel ${path} failed: HTTP ${res.status} ${(await res.text()).slice(0, 300)}`);
    const body = await res.json();
    return Array.isArray(body.data) ? body.data : [];
  }
}

// --- which days -------------------------------------------------------------
const today = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), new Date().getUTCDate()));
const dates = [];
for (let i = DAYS; i >= 1; i--) dates.push(iso(new Date(today.getTime() - i * 86400000)));
const since = `${dates[0]}T00:00:00.000Z`;
const until = `${dates[dates.length - 1]}T23:59:59.999Z`;

// --- totals per day -----------------------------------------------------------
const dayRows = await vercel("visits/aggregate", { since, until, by: "day", limit: 100 });
const byDay = new Map(dayRows.map((r) => [String(r.timestamp ?? r.day).slice(0, 10), r]));
const daily = dates.map((date) => ({
  date,
  pageviews: Number(byDay.get(date)?.pageviews) || 0,
  visitors: Number(byDay.get(date)?.visitors) || 0,
}));

// --- breakdowns per day (one query per day and dimension, top 100 + "Others") ---
const breakdown = [];
for (const date of dates) {
  for (const [dim, [vDim, empty]] of Object.entries(DIMENSIONS)) {
    if (PLAN_LIMITED.has(vDim)) continue;
    const rows = await vercel("visits/aggregate", {
      since: `${date}T00:00:00.000Z`,
      until: `${date}T23:59:59.999Z`,
      by: vDim,
      limit: 100,
    }, { optional: dim !== "page" && dim !== "country" });
    if (rows === null) continue;
    const merged = new Map();
    for (const r of rows) {
      const raw = r[vDim];
      const value = raw === null || raw === undefined || raw === "" ? empty : String(raw);
      const cur = merged.get(value) ?? { date, dimension: dim, value, pageviews: 0, visitors: 0 };
      cur.pageviews += Number(r.pageviews) || 0;
      cur.visitors += Number(r.visitors) || 0;
      merged.set(value, cur);
    }
    breakdown.push(...[...merged.values()].filter((r) => r.pageviews > 0 || r.visitors > 0));
    await sleep(120);
  }
}

const tot = daily.reduce((a, d) => ({ pv: a.pv + d.pageviews, v: a.v + d.visitors }), { pv: 0, v: 0 });
notice(`Vercel ${PROJECT}: ${dates[0]} to ${dates[dates.length - 1]} — ${tot.v} readers, ${tot.pv} page views, ${breakdown.length} breakdown rows.`);
if (tot.pv === 0) console.log("::warning::No page views in this window. Is Web Analytics enabled, and are VERCEL_PROJECT/VERCEL_TEAM right?");

if (DRY_RUN) {
  console.table(daily);
  console.log(breakdown.filter((r) => r.date === dates[dates.length - 1]).slice(0, 40));
  notice("DRY RUN: nothing written.");
  process.exit(0);
}

// --- write: replace these days in both tables -----------------------------------
const sb = (path, init = {}) =>
  fetch(`${SB_URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json", Prefer: "return=minimal", ...(init.headers || {}) },
  });
const inDates = `date=in.(${dates.join(",")})`;

async function replace(table, rows) {
  const backup = await (await sb(`${table}?select=*&${inDates}`, { headers: { Prefer: "" } })).json().catch(() => []);
  const del = await sb(`${table}?${inDates}`, { method: "DELETE" });
  if (!del.ok) fail(`Clearing ${table} for ${dates[0]}..${dates[dates.length - 1]} failed: HTTP ${del.status} ${await del.text()}`);
  for (let i = 0; i < rows.length; i += 500) {
    const res = await sb(table, { method: "POST", body: JSON.stringify(rows.slice(i, i + 500)) });
    if (!res.ok) {
      const msg = await res.text();
      let restored = false;
      if (Array.isArray(backup) && backup.length) {
        await sb(`${table}?${inDates}`, { method: "DELETE" });
        const clean = backup.map(({ id, updated_at, ...r }) => r);
        restored = (await sb(table, { method: "POST", body: JSON.stringify(clean) })).ok;
      }
      fail(`Writing ${table} failed (HTTP ${res.status}: ${msg}); previous rows ${restored ? "restored" : "NOT restored"}.`);
    }
  }
  notice(`Replaced ${table}: ${rows.length} rows for ${dates.length} day(s).`);
}

await replace("web_daily", daily);
await replace("web_daily_breakdown", breakdown);
