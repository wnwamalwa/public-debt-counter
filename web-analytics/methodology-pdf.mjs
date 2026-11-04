// Prints the site's Methodology page to PDF and puts it in Supabase Storage
// (reports/methodology/kenya-debt-counter-methodology.pdf), which the page's
// "Download PDF" card links to.
//
//   node methodology-pdf.mjs [--out file.pdf] [--upload]
//
// Uses the page as published, with print styles (no floating panels), so the
// PDF always matches the site, including today's figures.
import { existsSync, readFileSync } from "node:fs";

const SITE = (process.env.SITE_URL || "https://kenyadebtcounter.vercel.app").replace(/\/$/, "");
const arg = (n) => {
  const i = process.argv.indexOf(`--${n}`);
  return i > 0 ? process.argv[i + 1] : undefined;
};
const OUT = arg("out") || "kenya-debt-counter-methodology.pdf";
const today = new Date().toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "Africa/Nairobi" });

const { chromium } = await import("playwright-core");
const exe =
  process.env.CHROME_PATH ||
  ["/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"].find((p) => existsSync(p));
const browser = await chromium.launch(exe ? { executablePath: exe } : { channel: "chrome" });
const page = await browser.newPage({ viewport: { width: 1200, height: 1600 } });
await page.goto(`${SITE}/methodology`, { waitUntil: "load", timeout: 120_000 });
await page.waitForTimeout(4000); // let live figures and fonts settle
const text = await page.locator("main").innerText();
if (!/Methodology/.test(text) || text.length < 5000) throw new Error("The Methodology page looks incomplete; not publishing.");
await page.emulateMedia({ media: "print" });

// Dress the page like the monthly readership report: a full-width dark green
// cover band (kicker, title, subtitle), the site's own intro heading hidden
// under it, Manrope headings, and the same page margins (no top margin on
// page 1 so the band reaches the top edge).
await page.evaluate(({ today }) => {
  const main = document.querySelector("main");
  const intro = main.querySelector("section h1")?.closest("section");
  const lead = intro?.querySelector("p:not(:first-of-type)")?.textContent?.trim();
  if (intro) intro.style.display = "none";
  const band = document.createElement("header");
  band.className = "pdf-cover";
  band.innerHTML = `
    <div class="kicker">Methodology · as at ${today}</div>
    <h1>How the Kenya National Debt Counter works</h1>
    <p>Where every figure comes from and how it is calculated: data sources, the live estimate,
    forecasts, debt service, the budget and debt sustainability. Institute of Economic Affairs (IEA Kenya).</p>`;
  main.prepend(band);
  if (lead) {
    const p = document.createElement("p");
    p.className = "pdf-lead";
    p.textContent = lead;
    band.after(p);
  }
  const css = document.createElement("style");
  css.textContent = `
    @page { size: A4; margin: 14mm 0 16mm 0 }
    @page :first { margin-top: 0 }
    html, body { background: #fff !important }
    main { padding: 0 14mm !important }
    main > *:not(.pdf-cover) { max-width: 100% !important }
    .pdf-cover { margin: 0 -14mm 7mm; padding: 13mm 14mm 10mm; background: #0d4e29; color: #fff;
      -webkit-print-color-adjust: exact; print-color-adjust: exact }
    .pdf-cover .kicker { text-transform: uppercase; letter-spacing: .14em; font-size: 7.8pt; color: #b9e2c6; font-weight: 600 }
    .pdf-cover h1 { font-family: Manrope, Inter, sans-serif; font-size: 25pt; line-height: 1.08; margin: 2mm 0 2.5mm;
      font-weight: 800; letter-spacing: -.015em; color: #fff; max-width: 150mm }
    .pdf-cover p { margin: 0; color: #dcefe2; font-size: 10.5pt; line-height: 1.45; max-width: 150mm }
    .pdf-lead { font-size: 10.5pt; color: #334155; margin: 0 0 6mm; max-width: 165mm }
    h2, h3 { break-after: avoid }
    footer, [aria-label="Sections"] { display: none !important }`;
  document.head.append(css);
}, { today });
await page.waitForTimeout(500);
await page.pdf({
  path: OUT,
  format: "A4",
  printBackground: true,
  preferCSSPageSize: true,
  displayHeaderFooter: true,
  headerTemplate: "<div></div>",
  footerTemplate: `<div style="width:100%;font-size:8px;color:#5b625e;padding:0 14mm;display:flex;justify-content:space-between;font-family:Arial,sans-serif">
    <span>Kenya National Debt Counter · Methodology · ${SITE.replace(/^https?:\/\//, "")}/methodology · as at ${today}</span>
    <span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>`,
});
await browser.close();
console.log(`Wrote ${OUT}`);

if (process.argv.includes("--upload")) {
  const key = process.env.SUPABASE_SERVICE_ROLE;
  const res = await fetch(`${process.env.SUPABASE_URL}/storage/v1/object/reports/methodology/kenya-debt-counter-methodology.pdf`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/pdf", "x-upsert": "true", "cache-control": "max-age=3600" },
    body: readFileSync(OUT),
  });
  if (!res.ok) throw new Error(`Upload failed: HTTP ${res.status} ${await res.text()}`);
  console.log("Uploaded reports/methodology/kenya-debt-counter-methodology.pdf");
}
