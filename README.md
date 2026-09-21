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
| `df_finance.R`, `df_forex.R`, `df_wacd.R`, `gdp_g.R` | various | corresponding tables | not yet scheduled |

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

## Required repository secrets

Settings → Secrets and variables → Actions:

- `SUPABASE_URL` — `https://peoibpmmyflplirzjefk.supabase.co`
- `SUPABASE_SERVICE_ROLE` — service_role key for that project (write access,
  bypasses RLS). Verify any candidate key first with
  `scripts/check-supabase-key.sh` before pasting it here (script lives
  alongside this project, not in this repo).
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
