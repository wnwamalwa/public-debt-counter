# CBK data watch

CBK re-uploads its files at irregular times. The pipelines check every two weeks
(1st and 15th of the month), one script per slot so they never overlap, and
only run when a file has actually changed:

| Workflow | Checks (Nairobi) | Watches | Runs |
|---|---|---|---|
| `cbk-debt-watch.yml` | 1st & 15th, 09:02 | Public Debt CSV | `df_debt.R` |
| `cbk-indicators.yml` | 1st & 15th, 09:17 | Monthly exchange rate CSV; daily rate on the CBK home page | `df_forex.R` |
| `cbk-indicators.yml` | 1st & 15th, 09:32 | Revenue and Expenditure CSV; Public Debt CSV | `df_wacd.R` |
| `cbk-indicators.yml` | 1st & 15th, 09:47 | Revenue and Expenditure CSV | `df_finance.R` |

`watch/check_cbk.sh <name> <link-pattern> [page]` finds the current link on the
CBK page (the numeric prefix changes with every upload), downloads the file and
compares link + SHA-256 with `watch/<name>.state`. Each script keeps its own state
files, so two scripts watching the same CBK file each run once per new version.
A state file is only updated (and committed by the workflow) after its script
succeeds, so a failure is retried at the next check, and scheduled failures open
a GitHub issue.

Run by hand: GitHub → Actions → the workflow → **Run workflow** (tick *force*
to run even with no new file; CBK indicators also has *dry_run*, on by default).

Repository secrets required: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE`.

## New reports to enter in the Google Sheet (`reports-watch.yml`)

Every Monday at 09:07 Nairobi time, `check_reports.py` looks for new:

| Source | Where it looks | Sheet tabs / inputs it feeds |
|---|---|---|
| Controller of Budget, National Government Budget Implementation Review Report, **full year** | https://cob.go.ke/publications/ | `debt_service`, `external_debt_currency`, `domestic_debt_instrument` |
| Same, **three, six or nine months** | same | `domestic_debt_instrument` (and `external_debt_currency` if the report has it) |
| National Treasury, Annual Public Debt Report | likely file names on treasury.go.ke | `pv_indicators` |
| National Treasury, Medium Term Debt Management Strategy | likely file names on treasury.go.ke | the quarterly report's `treasury-inputs` chunk |

When something new appears it opens an issue, labelled "sheet update" and
assigned to the repository owner (GitHub emails them), with a checklist of
what to enter. What has been seen is kept in `reports.json`; the first run
only records what exists. Run it any time from Actions → "New reports to
enter in the sheet" → Run workflow.
