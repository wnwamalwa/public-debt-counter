# Kenya National Debt Counter — Data Pipeline

R scripts and GitHub Actions workflows that keep the Kenya Debt Counter's
Supabase tables (and, through them, `api.kenyadebtcounter.or.ke` and
`kenyadebtcounter.vercel.app`) up to date.

## Pipelines

| Script | Source data | Supabase tables | Workflow |
|---|---|---|---|
| `df_debt.R` | CBK public debt CSV | `df_debt_historical`, `df_debt_current`, `df_debt_growth_per_sec` | `.github/workflows/cbk-debt-watch.yml` |
| `df_gdp.R` | Google Sheet `gdp` tab | `df_gdp`, `df_gdp_metrics` | `.github/workflows/gdp-population-sheet-sync.yml` |
| `df_pop.R` | Google Sheet `population` tab | `df_pop`, `df_pop_metrics` | `.github/workflows/gdp-population-sheet-sync.yml` |
| `df_forex.R` | CBK monthly exchange rate (end period) CSV | `df_forex` | `.github/workflows/cbk-indicators.yml` |
| `df_wacd.R` | CBK revenue & expenditure CSV (interest columns) | `df_wacd`, `df_wacd_metrics` | `.github/workflows/cbk-indicators.yml` |
| `df_finance.R` | CBK revenue & expenditure CSV | `df_finance`, `df_finance_metrics` | `.github/workflows/cbk-indicators.yml` |
| `gdp_g.R` | various | corresponding tables | not scheduled |
| `web-analytics/collect.mjs` | Vercel Web Analytics (kenyadebtcounter.vercel.app) | `web_daily`, `web_daily_breakdown` | `.github/workflows/web-analytics.yml` (daily) |
| `web-analytics/build-report.mjs` | `web_daily`, `web_daily_breakdown` | PDF in Storage `reports/readers/` | same workflow, 2nd of each month |

`df_forex.R`, `df_wacd.R` and `df_finance.R` share `pipeline_helpers.R`: they
find the current CBK file link on the page each run (CBK renames files on every
upload), back a table up before replacing it and restore it if the upload
fails, and post their key results as annotations on the GitHub Actions run.
Run any of them with `DRY_RUN=true` to calculate without writing; manual runs
of the workflow are dry runs unless you untick the box.

`df_gdp.R`/`df_pop.R` read the same IEA Kenya Google Sheet
(`quarterly_macro_debt_report_ieakenya`) that the `quarterly-macro-debt-report`
repo's Quarto report reads. That sheet's own `gdp`/`population` tabs are kept
current by a separate weekly scheduled task (KNBS actuals in, monthly
interpolation + forecast rebuilt fresh every run) — these two scripts simply
mirror that series into Supabase so the live site's counters and charts stay
in sync with it.

`data_loader.R`, `api.R` and `routes.R` are the plumber API server itself
(runs continuously via `debtcounter-api.service` + `nginx-api.conf` on the
production host) — not part of either scheduled pipeline above.

## Readership (Vercel Web Analytics)

`web-analytics/collect.mjs` copies the site's Vercel Web Analytics into
Supabase every day (the last 3 days, re-fetched so late data settles), so the
history is kept whatever Vercel's reporting window is (one month on Hobby).
`visitor_metrics_summary_vercel` adds it up, and `visitor_metrics_summary` now
reads from it (the old session-tracker version is kept as
`visitor_metrics_summary_legacy`). On the 2nd of each month the same workflow
builds the PDF readership report (`build-report.mjs`) and uploads it to the
public Storage bucket `reports` as `readers/<YYYY-MM>.pdf` and
`readers/latest.pdf`; the site's `/readers` page links to it.

One-off setup: run `sql/web_analytics.sql` in the Supabase SQL editor, add the
`VERCEL_TOKEN` secret, then run the workflow by hand with **days = 31** to fill
the past month. `npm run sample` in `web-analytics/` builds a sample report with
made-up figures, to check the layout.

## Required repository secrets

Settings → Secrets and variables → Actions:

- `SUPABASE_URL` — `https://peoibpmmyflplirzjefk.supabase.co`
- `SUPABASE_SERVICE_ROLE` — service_role key for that project (write access,
  bypasses RLS). Verify any candidate key first with
  `scripts/check-supabase-key.sh` before pasting it here (script lives
  alongside this project, not in this repo).
- `VERCEL_TOKEN` — a Vercel access token that can read the `iea-kenya` team
  (Vercel → Account Settings → Tokens; scope it to that team). Used only by the
  readership workflow.
- `GSHEET_SERVICE_ACCOUNT` — base64-encoded service-account JSON
  (`iea-kenya-ci-reports@iea-pipeline.iam.gserviceaccount.com`), already
  shared as Viewer on the sheet. Same value used by the
  `quarterly-macro-debt-report` repo's `render-pdf.yml`.

Never commit `.Renviron`, `gsheets.json`, or anything under `secrets/` /
`.secrets/` — all already covered by `.gitignore`.

## First real run

Both `df_gdp.R` and `df_pop.R` currently default to `DRY_RUN <- TRUE` (prints
a summary, uploads nothing) since they're new. Once a dry run's output looks
right, flip that line to `FALSE` and commit — the scheduled workflow will
then actually upsert into Supabase on its next run (or trigger it manually
from the Actions tab to confirm immediately).
