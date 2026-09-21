# CBK data watch

`.github/workflows/cbk-debt-watch.yml` runs every Friday at 16:00 EAT on GitHub Actions:

1. `watch/check_cbk.sh` finds the current **Public Debt** CSV link on
   https://www.centralbank.go.ke/statistics/government-finance-statistics/
   and hashes the file.
2. If the link or contents differ from `watch/public_debt.state`, it runs
   `df_debt.R`, which updates Supabase (`df_debt`, `df_debt_metrics`). The site
   picks up the new figures within 30 seconds.
3. After a successful update it commits the new `public_debt.state`.
   If anything fails, the state isn't saved (so next week retries) and GitHub
   emails the repo owner.

Run it by hand: GitHub → Actions → *CBK public debt watch* → **Run workflow**
(tick *force* to re-run `df_debt.R` even with no new file).

Repository secrets required (Settings → Secrets and variables → Actions):
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE`.

To watch another file later (e.g. Revenue and Expenditure), add another
check step with its own name and pattern, e.g.
`watch/check_cbk.sh revenue_expenditure 'Revenue%20and%20Expenditure\.csv'`.
