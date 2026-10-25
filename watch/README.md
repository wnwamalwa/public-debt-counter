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
