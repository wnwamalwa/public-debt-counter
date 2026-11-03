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
await page.pdf({
  path: OUT,
  format: "A4",
  printBackground: true,
  displayHeaderFooter: true,
  headerTemplate: "<div></div>",
  footerTemplate: `<div style="width:100%;font-size:8px;color:#64748b;padding:0 12mm;display:flex;justify-content:space-between;font-family:Arial,sans-serif">
    <span>Kenya National Debt Counter (IEA Kenya) · Methodology · ${SITE.replace(/^https?:\/\//, "")}/methodology · as at ${today}</span>
    <span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>`,
  margin: { top: "14mm", bottom: "16mm", left: "12mm", right: "12mm" },
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
