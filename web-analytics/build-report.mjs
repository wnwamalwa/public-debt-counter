// Builds the monthly readership report for the Kenya National Debt Counter as
// an A4 PDF: an at-a-glance infographic, world and Africa maps, monthly and
// daily trends, what people read and how they arrived, and notes.
//
//   node build-report.mjs --sample [--month 2026-10] [--out file.pdf]
//   node build-report.mjs [--month 2026-10] [--out file.pdf] [--upload]
//
// Without --sample it reads Supabase (SUPABASE_URL, SUPABASE_SERVICE_ROLE).
// --month defaults to last month. --upload puts the PDF in the public
// Supabase Storage bucket "reports" as readers/<month>.pdf and readers/latest.pdf.
// Chromium: CHROME_PATH, else the system Chrome (GitHub runners have one).

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { geoNaturalEarth1, geoMercator, geoPath } from "d3-geo";
import { feature } from "topojson-client";
import countries from "i18n-iso-countries";
import { loadSample, loadSupabase, addMonths, monthRange } from "./data.mjs";

const require = createRequire(import.meta.url);
countries.registerLocale(require("i18n-iso-countries/langs/en.json"));

/* ------------------------------------------------------------------ options */
const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : dflt;
};
const flag = (name) => args.includes(`--${name}`);
const lastMonth = addMonths(new Date().toISOString().slice(0, 7), -1);
const MONTH = opt("month", lastMonth);
const SAMPLE = flag("sample");
const OUT = opt("out", `readers-report-${MONTH}.pdf`);

/* ------------------------------------------------------------------- tokens */
// Sequential ramp (validated: one hue, monotone, visible steps, light end >= 2:1).
const RAMP = ["#7cc292", "#4aa567", "#2a874d", "#1a6b3b", "#0d4e29"];
const NO_DATA = "#e4e8e5";
const BAR = "#1a6b3b";
const BAR_MUTED = "#c4ccc6";
// Categorical slots 1-3 (validated all-pairs) for the three device types.
const CAT = ["#2a78d6", "#eb6834", "#1baf7a"];

/* ------------------------------------------------------------------ helpers */
const nf = new Intl.NumberFormat("en-GB");
const fmt = (n) => nf.format(Math.round(n));
const pct = (n, d = 1) => `${(n * 100).toFixed(d)}%`;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const monthName = (m, style = "long") =>
  new Date(`${m}-15T00:00:00Z`).toLocaleDateString("en-GB", { month: style, year: "numeric", timeZone: "UTC" });
const monthShort = (m) => ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][Number(m.slice(5, 7)) - 1];
const dayLabel = (iso) =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" });
const countryName = (code) =>
  ({ US: "United States", GB: "United Kingdom", AE: "UAE", CD: "DR Congo", TZ: "Tanzania", KR: "South Korea" })[code] ||
  countries.getName(code, "en", { select: "alias" }) ||
  countries.getName(code, "en") ||
  code;
const change = (now, before) => (before > 0 ? now / before - 1 : null);
const changeText = (c) => (c === null ? "new" : `${c >= 0 ? "▲" : "▼"} ${Math.abs(c * 100).toFixed(0)}%`);
const changeClass = (c) => (c === null ? "flat" : c >= 0 ? "up" : "down");

const AFRICA = new Set(
  ("DZ AO BJ BW BF BI CV CM CF TD KM CG CD CI DJ EG GQ ER SZ ET GA GM GH GN GW KE LS LR LY MG MW ML MR MU MA MZ NA NE NG RW " +
    "ST SN SC SL SO ZA SS SD TZ TG TN UG EH ZM ZW").split(" "),
);

function binOf(v, edges) {
  if (!v) return -1;
  let b = 0;
  while (b < edges.length && v >= edges[b]) b++;
  return Math.min(b, RAMP.length - 1);
}
function niceEdges(max) {
  return [10, 50, 200, 1000];
}
function niceEdgesAuto(max) {
  // Four cut points on a rough log scale, so a few big countries don't wash out the rest.
  const cand = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000];
  const top = Math.max(10, max);
  const steps = cand.filter((c) => c < top);
  const pick = [0.15, 0.35, 0.6, 0.85].map((q) => steps[Math.min(steps.length - 1, Math.floor(q * steps.length))]);
  return [...new Set(pick)].sort((a, b) => a - b);
}

/* --------------------------------------------------------------------- maps */
const world110 = JSON.parse(readFileSync(require.resolve("world-atlas/countries-110m.json")));
const world50 = JSON.parse(readFileSync(require.resolve("world-atlas/countries-50m.json")));
const withCode = (topo) =>
  feature(topo, topo.objects.countries).features.map((f) => ({
    ...f,
    code: countries.numericToAlpha2(String(f.id).padStart(3, "0")) || (f.properties?.name === "Kosovo" ? "XK" : null),
  }));
const WORLD = withCode(world110).filter((f) => f.properties?.name !== "Antarctica");
const AFR = withCode(world50).filter((f) => f.code && AFRICA.has(f.code));

function mapSvg(features, values, edges, { width, height, projection, label = [], focus = null }) {
  projection.fitExtent([[4, 4], [width - 4, height - 4]], { type: "FeatureCollection", features: focus ?? features });
  const path = geoPath(projection);
  const shapes = features
    .map((f) => {
      const v = values.get(f.code) || 0;
      const b = binOf(v, edges);
      const fill = b < 0 ? NO_DATA : RAMP[b];
      const d = path(f);
      if (!d) return "";
      const kenya = f.code === "KE";
      return `<path d="${d}" fill="${fill}" stroke="${kenya ? "#0b0b0b" : "#ffffff"}" stroke-width="${kenya ? 1.4 : 0.5}"><title>${esc(
        countryName(f.code || "") + ": " + fmt(v),
      )}</title></path>`;
    })
    .join("");
  const labels = label
    .map(({ code, text, dx = 0, dy = 0, anchor = "start", inside = false, minArea = 0 }) => {
      const f = features.find((x) => x.code === code);
      if (!f || path.area(f) < minArea) return "";
      const [x, y] = path.centroid(f);
      if (inside) return `<g class="maplabel in"><text x="${x}" y="${y + 3.5}" text-anchor="middle">${esc(text)}</text></g>`;
      return `<g class="maplabel"><line x1="${x}" y1="${y}" x2="${x + dx}" y2="${y + dy}" stroke="#0b0b0b" stroke-width="0.8"/>
        <circle cx="${x}" cy="${y}" r="2.2" fill="#0b0b0b"/>
        <text x="${x + dx + (anchor === "start" ? 3 : -3)}" y="${y + dy + 3.5}" text-anchor="${anchor}">${esc(text)}</text></g>`;
    })
    .join("");
  return `<svg viewBox="0 0 ${width} ${height}" width="100%" role="img">${shapes}${labels}</svg>`;
}

function mapLegend(edges) {
  const ranges = [`1–${fmt(edges[0] - 1)}`];
  for (let i = 0; i < edges.length - 1; i++) ranges.push(`${fmt(edges[i])}–${fmt(edges[i + 1] - 1)}`);
  ranges.push(`${fmt(edges[edges.length - 1])}+`);
  return `<div class="legend"><span class="legend-unit">Readers:</span>
    <span class="sw" style="background:${NO_DATA}"></span><span>none</span>
    ${ranges.map((r, i) => `<span class="sw" style="background:${RAMP[i]}"></span><span>${r}</span>`).join("")}
</div>`;
}

/* ------------------------------------------------------------------- charts */
function columnChart(rows, { key, width = 520, height = 170, highlight, fmtV = fmt }) {
  const pad = { l: 8, r: 8, t: 18, b: 22 };
  const max = Math.max(1, ...rows.map((r) => r[key]));
  const w = (width - pad.l - pad.r) / rows.length;
  const bw = Math.min(30, w * 0.62);
  const ih = height - pad.t - pad.b;
  const bars = rows
    .map((r, i) => {
      const x = pad.l + i * w + (w - bw) / 2;
      const h = (r[key] / max) * ih;
      const y = pad.t + ih - h;
      const hi = r.month === highlight;
      const lab = r.hasData === false ? "–" : fmtV(r[key]);
      const showVal = hi || i === rows.length - 2 || r[key] === max;
      return `${h > 0 ? `<path d="M${x},${pad.t + ih} V${y + 4} q0,-4 4,-4 h${bw - 8} q4,0 4,4 V${pad.t + ih} Z" fill="${hi ? BAR : BAR_MUTED}"><title>${esc(monthName(r.month))}: ${lab}</title></path>` : ""}
        ${showVal || r.hasData === false ? `<text class="val" x="${x + bw / 2}" y="${h > 0 ? y - 4 : pad.t + ih - 4}" text-anchor="middle">${lab}</text>` : ""}
        <text class="tick" x="${x + bw / 2}" y="${height - 6}" text-anchor="middle">${monthShort(r.month)}</text>`;
    })
    .join("");
  return `<svg viewBox="0 0 ${width} ${height}" width="100%">
    <line x1="${pad.l}" x2="${width - pad.r}" y1="${pad.t + ih}" y2="${pad.t + ih}" stroke="#9aa19c" stroke-width="1"/>${bars}</svg>`;
}

function calendar(daily) {
  // Weeks as rows (Mon-Sun), so the month reads like a wall calendar.
  const max = Math.max(...daily.map((d) => d.visitors));
  const sorted = [...daily.map((d) => d.visitors)].sort((a, b) => a - b);
  const q = (p) => sorted[Math.floor(p * (sorted.length - 1))];
  const edges = [q(0.2), q(0.4), q(0.6), q(0.8)];
  const first = new Date(`${daily[0].date}T00:00:00Z`);
  const offset = (first.getUTCDay() + 6) % 7;
  const cells = [];
  for (let i = 0; i < offset; i++) cells.push(`<div class="cal-cell empty"></div>`);
  for (const d of daily) {
    let b = 0;
    while (b < edges.length && d.visitors > edges[b]) b++;
    const dark = b >= 2;
    const peak = d.visitors === max;
    cells.push(`<div class="cal-cell${peak ? " peak" : ""}" style="background:${RAMP[b]};color:${dark ? "#fff" : "#0b0b0b"}" title="${esc(dayLabel(d.date))}: ${fmt(d.visitors)} readers">
      <span class="cal-day">${Number(d.date.slice(8))}</span><span class="cal-n">${fmt(d.visitors)}</span></div>`);
  }
  const head = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((x) => `<div class="cal-head">${x}</div>`).join("");
  const legend = `<div class="legend small">
    <span>fewer</span>${RAMP.map((c) => `<span class="sw" style="background:${c}"></span>`).join("")}<span>more readers per day</span></div>`;
  return `<div class="cal">${head}${cells.join("")}</div>${legend}`;
}

function weekdayBars(daily) {
  const names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const sums = Array(7).fill(0);
  const counts = Array(7).fill(0);
  for (const d of daily) {
    const i = (new Date(`${d.date}T00:00:00Z`).getUTCDay() + 6) % 7;
    sums[i] += d.visitors;
    counts[i]++;
  }
  const avg = sums.map((s, i) => (counts[i] ? s / counts[i] : 0));
  const max = Math.max(...avg);
  return {
    best: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][avg.indexOf(max)],
    html: `<div class="bars compact">${avg
      .map(
        (a, i) => `<div class="bar-row"><span class="bar-label">${names[i]}</span>
          <span class="bar-track"><span class="bar-fill" style="width:${(a / max) * 100}%;background:${a === max ? BAR : BAR_MUTED}"></span></span>
          <span class="bar-val">${fmt(a)}</span></div>`,
      )
      .join("")}</div>`,
  };
}

function barList(rows, { total, label = (r) => r.value, prev = null, n = 10, valueKey = "visitors" }) {
  const top = rows.slice(0, n);
  // When the leader is more than 3x the next (Kenya, the home page), scale the
  // bars to the runner-up and draw the leader as a broken bar, so the rest stay readable.
  const broken = top.length > 2 && top[0][valueKey] > 3 * top[1][valueKey];
  const max = Math.max(1, ...(broken ? top.slice(1) : top).map((r) => r[valueKey])) * (broken ? 1.15 : 1);
  const prevMap = prev ? new Map(prev.map((r) => [r.value, r[valueKey]])) : null;
  return `<div class="bars">${top
    .map((r) => {
      const c = prevMap ? change(r[valueKey], prevMap.get(r.value) || 0) : undefined;
      return `<div class="bar-row"><span class="bar-label">${esc(label(r))}</span>
        <span class="bar-track">${broken && r === top[0]
          ? `<span class="bar-fill broken" style="width:100%"></span>`
          : `<span class="bar-fill" style="width:${(r[valueKey] / max) * 100}%"></span>`}</span>
        <span class="bar-val">${fmt(r[valueKey])}</span>
        <span class="bar-share">${total ? pct(r[valueKey] / total, 1) : ""}</span>
        ${prevMap ? `<span class="bar-chg ${changeClass(c)}">${changeText(c)}</span>` : ""}</div>`;
    })
    .join("")}</div>`;
}

function stacked(rows, total) {
  const order = ["mobile", "desktop", "tablet"];
  const segs = order
    .map((k, i) => ({ k, v: rows.find((r) => r.value === k)?.visitors || 0, c: CAT[i] }))
    .filter((s) => s.v > 0);
  return `<div class="stack">${segs
    .map((s) => `<span class="seg" style="flex:${s.v};background:${s.c}" title="${s.k}: ${fmt(s.v)}"></span>`)
    .join("")}</div>
    <div class="stack-legend">${segs
      .map((s) => `<span><i style="background:${s.c}"></i>${s.k[0].toUpperCase() + s.k.slice(1)} <b>${pct(s.v / total, 0)}</b></span>`)
      .join("")}</div>`;
}

function monthTable(rows) {
  const shown = rows.filter((m) => m.hasData !== false);
  return `<table class="mt"><thead><tr><th>Month</th><th>Readers</th><th>Change</th><th>Page views</th><th>Pages per reader</th><th>In Kenya</th></tr></thead><tbody>
    ${shown
      .map((m, i) => {
        const c = i ? change(m.visitors, shown[i - 1].visitors) : null;
        return `<tr class="${m.month === MONTH ? "cur" : ""}"><td>${monthName(m.month)}</td><td>${fmt(m.visitors)}</td>
          <td class="${i ? changeClass(c) : "flat"}">${i ? changeText(c) : "–"}</td><td>${fmt(m.pageviews)}</td>
          <td>${m.visitors ? (m.pageviews / m.visitors).toFixed(1) : "–"}</td><td>${m.visitors ? pct((m.kenya || 0) / m.visitors, 0) : "–"}</td></tr>`;
      })
      .join("")}</tbody></table>`;
}

const pageName = (p) =>
  ({
    "/": "Home: the live counter",
    "/home": "Home (alternate address)",
    "/explore": "Explore: all charts",
    "/methodology": "Methodology",
    "/about": "About & contact",
    "/embed-counter": "Embed the counter",
    "/present": "Presentation mode",
  })[p] || (p.startsWith("/c/") ? `Shared chart: ${p.slice(3).replace(/^chart-/, "").replace(/-/g, " ")}` : p);
const refName = (r) => (r === "(direct)" || r === "" || r == null ? "Direct / apps / bookmarks" : r);

/* ------------------------------------------------------------------- report */
const data = SAMPLE ? loadSample(MONTH) : await loadSupabase(MONTH);
const { daily, monthly, breakdown, prevBreakdown } = data;
const cur = monthly[monthly.length - 1];
const prev = monthly[monthly.length - 2];
const readers = daily.reduce((s, d) => s + d.visitors, 0);
const views = daily.reduce((s, d) => s + d.pageviews, 0);
const prevReaders = prev?.visitors || 0;
if (!readers) {
  console.error(`No readership data for ${MONTH} in Supabase (web_daily). Run the daily copy first (collect.mjs).`);
  process.exit(1);
}
const countryRows = breakdown.country.filter((r) => r.value && r.value !== "Others");
const countryMap = new Map(countryRows.map((r) => [r.value, r.visitors]));
const nCountries = countryRows.length;
const kenya = countryMap.get("KE") || 0;
const outside = readers - kenya;
const africaOther = countryRows.filter((r) => AFRICA.has(r.value) && r.value !== "KE").reduce((s, r) => s + r.visitors, 0);
const peak = daily.reduce((a, b) => (b.visitors > a.visitors ? b : a), daily[0]);
const wk = weekdayBars(daily);
const embed = breakdown.utm_source.find((r) => r.value === "embed")?.visitors || 0;
const mobile = breakdown.device.find((r) => r.value === "mobile")?.visitors || 0;
const deviceTotal = breakdown.device.reduce((s, r) => s + r.visitors, 0) || 1;
const refTotal = breakdown.referrer.reduce((s, r) => s + r.visitors, 0) || 1;
const search = breakdown.referrer.filter((r) => /google|bing|duckduckgo|yahoo/.test(r.value)).reduce((s, r) => s + r.visitors, 0);
const social = breakdown.referrer.filter((r) => /x\.com|twitter|facebook|linkedin|whatsapp|instagram|tiktok|t\.co/.test(r.value)).reduce((s, r) => s + r.visitors, 0);
const news = breakdown.referrer.filter((r) => /nation\.africa|the-star|citizen|standardmedia|kenyans\.co\.ke|businessdailyafrica|capitalfm/.test(r.value)).reduce((s, r) => s + r.visitors, 0);
const growth = change(readers, prevReaders);
const yearRows = monthly.filter((m) => m.hasData !== false);
const best = yearRows.reduce((a, b) => (b.visitors > a.visitors ? b : a), yearRows[0] || cur);
const ytdReaders = yearRows.reduce((s, m) => s + m.visitors, 0);

const worldEdges = niceEdges(Math.max(...countryRows.filter((r) => r.value !== "KE").map((r) => r.visitors), 10));
const worldMap = mapSvg(WORLD, countryMap, worldEdges, {
  width: 720,
  height: 360,
  projection: geoNaturalEarth1(),
  label: [{ code: "KE", text: `Kenya ${pct(kenya / readers, 0)}`, dx: 40, dy: 36 }],
});
const afrRows = countryRows.filter((r) => AFRICA.has(r.value));
const africaMap = mapSvg(AFR, countryMap, worldEdges, {
  width: 360,
  height: 400,
  projection: geoMercator(),
  label: afrRows
    .filter((r) => r.value !== "KE")
    .slice(0, 6)
    .map((r) => ({ code: r.value, text: `${countryName(r.value)} ${fmt(r.visitors)}`, inside: true, minArea: 900 })),
});

const fontCss = ["inter-latin-400", "inter-latin-500", "inter-latin-600", "inter-latin-700", "manrope-latin-700", "manrope-latin-800"]
  .map((f) => {
    const [fam, , w] = f.split("-");
    const file = require.resolve(`@fontsource/${fam}/files/${f}-normal.woff2`);
    return `@font-face{font-family:"${fam === "inter" ? "Inter" : "Manrope"}";font-weight:${w};src:url(data:font/woff2;base64,${readFileSync(file).toString("base64")}) format("woff2")}`;
  })
  .join("\n");

const M = monthName(MONTH);
const pageHead = (n, title) => `<header class="ph"><span class="ph-brand">Kenya National Debt Counter · Readership report · ${M}</span><span class="ph-n">${n}</span></header>
  <h2 class="pt">${title}</h2>`;
const sampleMark = data.sample ? `<div class="watermark">SAMPLE · ILLUSTRATIVE FIGURES</div>` : "";
const sampleNote = data.sample
  ? `<div class="sample-note"><b>Sample layout.</b> The figures in this report are made up to show the design. The real report uses the site's Vercel Web Analytics data.</div>`
  : "";

const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Readership report ${M}</title><style>
${fontCss}
@page { size: A4; margin: 0 }
* { box-sizing: border-box }
html, body { margin: 0; padding: 0; background: #fff; color: #0b0b0b; font-family: Inter, "DejaVu Sans", sans-serif; font-size: 9.6pt; line-height: 1.42 }
.page { width: 210mm; height: 297mm; padding: 13mm 14mm 12mm; position: relative; overflow: hidden; page-break-after: always; display: flex; flex-direction: column }
.page:last-child { page-break-after: auto }
h1, h2, h3, .kpi-n { font-family: Manrope, Inter, sans-serif }
.ph { display: flex; justify-content: space-between; font-size: 7.6pt; color: #5b625e; border-bottom: 1px solid #dfe4e0; padding-bottom: 2.4mm; letter-spacing: .02em }
.pt { font-size: 17pt; margin: 5mm 0 1mm; font-weight: 800; letter-spacing: -.01em }
.lede { color: #3f4541; margin: 0 0 4mm; font-size: 10pt; max-width: 160mm }
h3 { font-size: 10.5pt; margin: 0 0 2mm; font-weight: 700 }
.sub { color: #5b625e; font-size: 8pt; margin: -1.5mm 0 2.5mm }
.cover-band { margin: -13mm -14mm 0; padding: 12mm 14mm 9mm; background: #0d4e29; color: #fff }
.cover-band .kicker { text-transform: uppercase; letter-spacing: .14em; font-size: 7.8pt; color: #b9e2c6; font-weight: 600 }
.cover-band h1 { font-size: 25pt; line-height: 1.08; margin: 2mm 0 2mm; font-weight: 800; letter-spacing: -.015em }
.cover-band p { margin: 0; color: #dcefe2; font-size: 10.5pt; max-width: 150mm }
.headline { display: flex; align-items: baseline; gap: 4mm; margin: 6mm 0 1mm }
.headline .big { font-family: Manrope, sans-serif; font-size: 40pt; font-weight: 800; letter-spacing: -.02em; line-height: 1 }
.headline .what { font-size: 12pt; color: #2a312c }
.headline .chg { font-size: 10pt; font-weight: 600 }
.up { color: #1a6b3b } .down { color: #b3261e } .flat { color: #5b625e }
.kpis { display: grid; grid-template-columns: repeat(4, 1fr); gap: 3mm; margin: 4mm 0 4mm }
.kpi { border: 1px solid #dfe4e0; border-radius: 3mm; padding: 3mm 3.4mm }
.kpi-n { font-size: 17pt; font-weight: 800; letter-spacing: -.01em; line-height: 1.1 }
.kpi-l { color: #3f4541; font-size: 8pt; margin-top: .6mm }
.kpi-s { color: #5b625e; font-size: 7.4pt; margin-top: .8mm }
.card { border: 1px solid #dfe4e0; border-radius: 3mm; padding: 4mm }
.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 4mm }
.grid-map { display: grid; grid-template-columns: 1.05fr 1fr; gap: 5mm; align-items: start }
.legend { display: flex; flex-wrap: wrap; align-items: center; gap: 1.2mm 1.6mm; font-size: 7.4pt; color: #3f4541; margin-top: 1.5mm }
.legend .sw { width: 3.6mm; height: 2.6mm; border-radius: .6mm; display: inline-block }
.legend .legend-unit { margin-right: .6mm; color: #5b625e }
.legend.small { font-size: 7pt; margin-top: 2mm }
.maplabel text { font-size: 10px; font-weight: 600; font-family: Inter, sans-serif; paint-order: stroke; stroke: #fff; stroke-width: 3px }
.bars { display: flex; flex-direction: column; gap: 1.3mm }
.bar-row { display: grid; grid-template-columns: 34mm 1fr 13mm 11mm auto; align-items: center; gap: 2mm; font-size: 8.2pt }
.bars.compact .bar-row { grid-template-columns: 9mm 1fr 11mm; }
.bar-label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #1d231f }
.bar-track { height: 2.8mm; background: #f1f3f1; border-radius: 1mm; overflow: hidden }
.bar-fill { display: block; height: 100%; background: ${BAR}; border-radius: 0 1mm 1mm 0 }
.bar-val { text-align: right; font-variant-numeric: tabular-nums; font-weight: 600 }
.bar-fill.broken { background: linear-gradient(90deg, ${BAR} 0 78%, #fff 78% 80%, ${BAR} 80% 83%, #fff 83% 85%, ${BAR} 85%) }
.bar-share { text-align: right; color: #5b625e; font-variant-numeric: tabular-nums }
.bar-chg { font-size: 7.4pt; font-weight: 600; min-width: 10mm; text-align: right }
.wide .bar-row { grid-template-columns: 52mm 1fr 14mm 12mm 12mm }
.tick { font-size: 9px; fill: #5b625e; font-family: Inter, sans-serif }
.val { font-size: 9.5px; fill: #1d231f; font-weight: 600; font-family: Inter, sans-serif }
.cal { display: grid; grid-template-columns: repeat(7, 1fr); gap: 1mm }
.cal-head { font-size: 7pt; color: #5b625e; text-align: center }
.cal-cell { height: 8.6mm; border-radius: 1.2mm; padding: .8mm 1.2mm; display: flex; flex-direction: column; justify-content: space-between }
.cal-cell.empty { background: transparent }
.cal-cell.peak { outline: 1.6px solid #0b0b0b; outline-offset: 0 }
.cal-day { font-size: 6.6pt; opacity: .85 }
.cal-n { font-size: 7.8pt; font-weight: 700; text-align: right; font-variant-numeric: tabular-nums }
.stack { display: flex; gap: 2px; height: 6mm; border-radius: 1.2mm; overflow: hidden; margin: 1mm 0 2mm }
.seg { display: block; height: 100% }
.stack-legend { display: flex; gap: 5mm; font-size: 8.4pt }
.stack-legend i { display: inline-block; width: 3mm; height: 3mm; border-radius: .7mm; margin-right: 1.4mm; vertical-align: -0.4mm }
.insights { margin: 0; padding: 0; list-style: none; display: grid; gap: 1.8mm }
.insights li { padding-left: 4.5mm; position: relative; font-size: 9.2pt }
.insights li::before { content: ""; position: absolute; left: 0; top: 1.7mm; width: 2mm; height: 2mm; border-radius: 50%; background: #2a874d }
.split { display: grid; grid-template-columns: repeat(4, 1fr); gap: 3mm }
.split .kpi-n { font-size: 14pt }
.notes { columns: 2; column-gap: 7mm; font-size: 8.6pt; color: #2a312c }
.notes h4 { font-family: Manrope, sans-serif; font-size: 9.4pt; margin: 0 0 1mm; break-after: avoid }
.notes p { margin: 0 0 3mm; break-inside: avoid }
.foot { margin-top: auto; padding-top: 3mm; border-top: 1px solid #dfe4e0; font-size: 7.2pt; color: #5b625e; display: flex; justify-content: space-between }
.watermark { position: absolute; top: 46%; left: -10%; width: 120%; text-align: center; transform: rotate(-28deg); font: 800 34pt Manrope, sans-serif; color: rgba(179, 38, 30, .08); letter-spacing: .08em; pointer-events: none; z-index: 5 }
.sample-note { background: #fff4e5; border: 1px solid #f3c78b; color: #6b3d00; border-radius: 2mm; padding: 2mm 3mm; font-size: 8pt; margin-top: 3mm }
.muted { color: #5b625e }
.mt { width: 100%; border-collapse: collapse; font-size: 8.4pt; font-variant-numeric: tabular-nums }
.mt th { text-align: right; font-weight: 600; color: #5b625e; font-size: 7.6pt; border-bottom: 1px solid #dfe4e0; padding: 1mm 1.5mm }
.mt td { text-align: right; padding: .7mm 1.5mm; border-bottom: 1px solid #f0f2f0 }
.mt th:first-child, .mt td:first-child { text-align: left }
.mt tr.cur td { font-weight: 700; background: #f2f8f4 }
</style></head><body>

<!-- 1. At a glance ------------------------------------------------------- -->
<section class="page">${sampleMark}
  <div class="cover-band">
    <div class="kicker">Readership report · ${M}</div>
    <h1>Who read the Kenya<br>National Debt Counter</h1>
    <p>Monthly figures on readers, where they are, what they read and how they found the site. Institute of Economic Affairs (IEA Kenya).</p>
  </div>
  ${sampleNote}
  <div class="headline"><span class="big">${fmt(readers)}</span><span class="what">people read the counter in ${monthName(MONTH, "long").split(" ")[0]}</span>
    <span class="chg ${changeClass(growth)}">${growth === null ? "" : `${changeText(growth)} on ${monthName(addMonths(MONTH, -1)).split(" ")[0]}`}</span></div>
  <div class="kpis">
    <div class="kpi"><div class="kpi-n">${fmt(views)}</div><div class="kpi-l">page views</div><div class="kpi-s">${(views / readers).toFixed(1)} pages per reader</div></div>
    <div class="kpi"><div class="kpi-n">${nCountries}</div><div class="kpi-l">countries reached</div><div class="kpi-s">${fmt(outside)} readers outside Kenya</div></div>
    <div class="kpi"><div class="kpi-n">${pct(kenya / readers, 0)}</div><div class="kpi-l">of readers in Kenya</div><div class="kpi-s">${fmt(africaOther)} elsewhere in Africa</div></div>
    <div class="kpi"><div class="kpi-n">${pct(mobile / deviceTotal, 0)}</div><div class="kpi-l">read on a phone</div><div class="kpi-s">${fmt(embed)} arrived via the embedded counter</div></div>
  </div>
  <h3>Readers by country</h3>
  <div class="sub">Each country shaded by its readers in ${M}. Kenya is outlined.</div>
  ${worldMap}
  ${mapLegend(worldEdges)}
  <div class="grid2" style="margin-top:4mm">
    <div><h3>Top five countries</h3>${barList(countryRows, { total: readers, label: (r) => countryName(r.value), n: 5 })}</div>
    <div><h3>In brief</h3><ul class="insights">
      <li>Busiest day: <b>${dayLabel(peak.date)}</b>, with ${fmt(peak.visitors)} readers.</li>
      <li>${wk.best}s are the busiest day of the week on average.</li>
      <li>${pct(search / refTotal, 0)} came from search engines, ${pct(social / refTotal, 0)} from social media and ${pct(news / refTotal, 0)} from news sites.</li>
      <li>${fmt(ytdReaders)} readers since ${monthName(yearRows[0]?.month || MONTH)}; the best month was ${monthName(best.month)}.</li>
    </ul></div>
  </div>
  <div class="foot"><span>kenyadebtcounter.vercel.app</span><span>Source: Vercel Web Analytics. Readers are counted once a day per device.</span></div>
</section>

<!-- 2. Where readers are -------------------------------------------------- -->
<section class="page">${sampleMark}
  ${pageHead(2, "Where readers are")}
  <p class="lede">${pct(kenya / readers, 0)} of readers were in Kenya. Outside Kenya, the largest audiences were in ${countryRows
    .filter((r) => r.value !== "KE")
    .slice(0, 3)
    .map((r) => countryName(r.value))
    .join(", ")
    .replace(/, ([^,]*)$/, " and $1")}. Readers came from ${afrRows.length} African countries.</p>
  <div class="grid-map">
    <div><h3>Africa</h3><div class="sub">Same shading as the world map; the largest African audiences are labelled.</div>${africaMap}${mapLegend(worldEdges)}</div>
    <div><h3>Top 20 countries</h3><div class="sub">Readers, share of all readers, and change on ${monthName(addMonths(MONTH, -1)).split(" ")[0]}.</div>
      ${barList(countryRows, { total: readers, label: (r) => countryName(r.value), prev: prevBreakdown.country, n: 20 })}</div>
  </div>
  <div class="split" style="margin-top:6mm">
    <div class="kpi"><div class="kpi-n">${fmt(kenya)}</div><div class="kpi-l">Kenya</div></div>
    <div class="kpi"><div class="kpi-n">${fmt(africaOther)}</div><div class="kpi-l">Rest of Africa</div></div>
    <div class="kpi"><div class="kpi-n">${fmt(outside - africaOther)}</div><div class="kpi-l">Rest of the world</div></div>
    <div class="kpi"><div class="kpi-n">${nCountries}</div><div class="kpi-l">Countries in total</div></div>
  </div>
  <div class="foot"><span>Country comes from the reader's internet connection, so VPN users appear where their VPN is.</span><span>2</span></div>
</section>

<!-- 3. Trends ----------------------------------------------------------- -->
<section class="page">${sampleMark}
  ${pageHead(3, "Monthly and daily trends")}
  <p class="lede">${growth === null ? "" : `Readers ${growth >= 0 ? "rose" : "fell"} ${Math.abs(growth * 100).toFixed(0)}% on ${monthName(addMonths(MONTH, -1)).split(" ")[0]}. `}Spikes usually follow new CBK debt figures, the budget, and media coverage of the counter.</p>
  <div class="grid2">
    <div class="card"><h3>Readers per month</h3><div class="sub">Last 12 months. – means the site was not yet tracked.</div>
      ${columnChart(monthly, { key: "visitors", width: 340, height: 140, highlight: MONTH })}</div>
    <div class="card"><h3>Page views per month</h3><div class="sub">Shown separately, as it is a different measure.</div>
      ${columnChart(monthly, { key: "pageviews", width: 340, height: 140, highlight: MONTH })}</div>
  </div>
  <div class="grid-map" style="margin-top:4mm;grid-template-columns:1.55fr 1fr">
    <div class="card"><h3>Readers each day, ${M}</h3><div class="sub">Darker means more readers; the busiest day is outlined.</div>${calendar(daily)}</div>
    <div class="card"><h3>Average readers by weekday</h3><div class="sub">${M}</div>${wk.html}
      <div style="margin-top:3mm"><h3>Pages per reader</h3><div class="sub">How deeply people read, last 6 months</div>
      ${columnChart(
        monthly.slice(-6).map((m) => ({ ...m, ratio: m.visitors ? m.pageviews / m.visitors : 0 })),
        { key: "ratio", width: 240, height: 95, highlight: MONTH, fmtV: (v) => (v ? v.toFixed(1) : "–") },
      )}</div></div>
  </div>
  <div class="card" style="margin-top:4mm"><h3>Month by month</h3><div class="sub">The figures behind the charts above.</div>
    ${monthTable(monthly)}</div>
  <div class="foot"><span>Monthly totals add up the daily figures.</span><span>3</span></div>
</section>

<!-- 4. What they read --------------------------------------------------- -->
<section class="page">${sampleMark}
  ${pageHead(4, "What people read and how they found it")}
  <p class="lede">The live counter on the home page is the main draw; ${pct(
    (breakdown.page.find((r) => r.value === "/explore")?.visitors || 0) / readers,
    0,
  )} of readers also opened the charts on Explore.</p>
  <div class="card wide"><h3>Most-read pages</h3><div class="sub">Readers per page, share of readers, and change on ${monthName(addMonths(MONTH, -1)).split(" ")[0]}.</div>
    ${barList(breakdown.page, { total: readers, label: (r) => pageName(r.value), prev: prevBreakdown.page, n: 12 })}</div>
  <div class="grid2" style="margin-top:4mm">
    <div class="card"><h3>Where readers came from</h3><div class="sub">Website or app that sent them</div>
      ${barList(breakdown.referrer, { total: refTotal, label: (r) => refName(r.value), n: 12 })}</div>
    <div class="card"><h3>Device</h3><div class="sub">Share of readers</div>${stacked(breakdown.device, deviceTotal)}
      <div style="margin-top:6mm"><h3>Arrivals by channel</h3>
      <div class="split" style="grid-template-columns:1fr 1fr;gap:2.5mm">
        <div class="kpi"><div class="kpi-n">${pct(search / refTotal, 0)}</div><div class="kpi-l">Search</div></div>
        <div class="kpi"><div class="kpi-n">${pct(social / refTotal, 0)}</div><div class="kpi-l">Social media</div></div>
        <div class="kpi"><div class="kpi-n">${pct(news / refTotal, 0)}</div><div class="kpi-l">News sites</div></div>
        <div class="kpi"><div class="kpi-n">${fmt(embed)}</div><div class="kpi-l">Via embedded counter</div></div>
      </div></div></div>
  </div>
  <div class="foot"><span>"Direct" covers typed addresses, bookmarks and apps (e.g. WhatsApp) that don't pass on where the link was.</span><span>4</span></div>
</section>

<!-- 5. Notes ------------------------------------------------------------ -->
<section class="page">${sampleMark}
  ${pageHead(5, "About these figures")}
  <div class="notes">
    <h4>Source</h4><p>Vercel Web Analytics, which runs on every page of kenyadebtcounter.vercel.app except the embeddable counter (<i>/embed</i>), so that reading a news article that embeds the counter is not counted as a visit to the site. Figures are copied each day into IEA Kenya's database, where they are kept permanently.</p>
    <h4>Readers</h4><p>A reader is a device that opened at least one page on a given day. Vercel identifies devices without cookies, from a fingerprint that changes every day, so the same person reading on two days counts twice. Monthly readers are the sum of daily readers. They are a fair measure of reach, not a count of unique people.</p>
    <h4>Page views</h4><p>Every page opened, including several pages by the same reader. Pages per reader is page views ÷ readers.</p>
    <h4>Country</h4><p>From the reader's internet connection. Readers using a VPN or some mobile networks can appear in another country. Country is not available below national level, so county figures cannot be shown.</p>
    <h4>Where readers came from</h4><p>The site that linked to the counter, when the browser passes it on. Messaging apps and many mobile apps don't, so their readers appear as "Direct". Links in the embedded counter carry the tag <i>utm_source=embed</i>.</p>
    <h4>What is not counted</h4><p>Bots and crawlers, preview and test versions of the site, readers who block analytics scripts, and the embedded counter itself.</p>
    <h4>Privacy</h4><p>No cookies are set and no personal data is stored. Only totals are kept: per day, and per page, country, referring site, device and campaign tag.</p>
    <h4>Contact</h4><p>Institute of Economic Affairs (IEA Kenya), ACK Garden House, 5th Floor, 1st Ngong Avenue, P.O. Box 53989-00200, Nairobi. admin@ieakenya.or.ke</p>
  </div>
  ${sampleNote}
  <div class="foot"><span>Report generated ${new Date().toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}</span><span>5</span></div>
</section>
</body></html>`;

/* --------------------------------------------------------------------- PDF */
const htmlOut = OUT.replace(/\.pdf$/, ".html");
writeFileSync(htmlOut, html);

const { chromium } = await import("playwright-core");
const exe =
  process.env.CHROME_PATH ||
  ["/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"].find((p) => existsSync(p));
const browser = await chromium.launch(exe ? { executablePath: exe } : { channel: "chrome" });
const page = await browser.newPage();
await page.setContent(html, { waitUntil: "load" });
await page.pdf({ path: OUT, format: "A4", printBackground: true, preferCSSPageSize: true });
await browser.close();
console.log(`Wrote ${OUT} (${data.sample ? "sample data" : "Supabase data"}, ${M}: ${fmt(readers)} readers, ${fmt(views)} page views)`);

/* ------------------------------------------------------------------ upload */
if (flag("upload")) {
  const key = process.env.SUPABASE_SERVICE_ROLE;
  const pdf = readFileSync(OUT);
  for (const name of [`readers/${MONTH}.pdf`, "readers/latest.pdf"]) {
    const res = await fetch(`${process.env.SUPABASE_URL}/storage/v1/object/reports/${name}`, {
      method: "POST",
      headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/pdf", "x-upsert": "true", "cache-control": "max-age=3600" },
      body: pdf,
    });
    if (!res.ok) throw new Error(`Uploading ${name} failed: HTTP ${res.status} ${await res.text()}`);
    console.log(`Uploaded reports/${name}`);
  }
}
