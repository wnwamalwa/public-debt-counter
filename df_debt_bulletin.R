# ============================================================
# KENYA NATIONAL DEBT COUNTER — WEEKLY BULLETIN NOWCAST (df_debt_bulletin.R)
# ============================================================
#
# What this script does
#   1. Reads the "debt_bulletin" tab of the IEA Kenya Google Sheet, where the
#      figures from each CBK Weekly Bulletin are entered by hand:
#        bulletin_date | domestic_bn | domestic_as_at | external_usd_bn | external_month | note
#      ("Government Domestic Debt", Table 7 in recent bulletins: the latest gross
#       domestic debt and its date; "Public Debt", Table 10: the latest external
#       debt in US$. CBK sometimes renumbers the tables.)
#   2. Checks the latest row (dates, plausible values, not a jump from the
#      previous row) so a typo never reaches the counter.
#   3. Works out the debt right now:
#        domestic = latest weekly figure + domestic growth × time since its date
#        external = US$ figure × cross-currency factor × TODAY's CBK KSh/US$
#                   rate (read from the CBK home page on every run; df_forex
#                   as a fallback) + external growth × time since its month
#      The cross-currency factor revalues the euro, yuan, yen and sterling
#      parts of the external debt (Treasury's currency shares) from the end
#      of the bulletin's month to today (ECB reference rates, Frankfurter API).
#      Growth rates come from the bulletin rows themselves once they cover
#      8+ weeks, otherwise from the last 12 months of CBK actuals
#      (df_debt_historical). External growth is measured at a constant
#      exchange rate (US$ change × today's rate), so currency moves are not
#      counted twice. The pace is checked against the underlying pace of the
#      last 12 months = budget deficit + other adjustments (cash balances,
#      debt taken over, arrears...), i.e. the 12-month change in debt at a
#      constant exchange rate: within 0.5-2x it, the observed trend is used;
#      outside it, the underlying pace.
#   4. Adds a row to df_debt_current and df_debt_growth_per_sec (the two
#      tables the website ticks the counter from), unless nothing changed
#      since the last run.
#   5. Rebuilds the months after CBK's latest monthly figure in
#      df_debt_historical so the charts' history runs into today's figure
#      instead of stepping up to it: each month-end (and today) is read off a
#      path from the last CBK monthly figure through the bulletin's domestic
#      figure (at its date) and external figure (at the end of its month),
#      continued at the growth rates above. These rows are labelled
#      source = "estimate" (CBK actuals stay "actual"); they replace df_debt.R's
#      ARIMA "forecast" rows and its "current" row. Without this the months
#      from July 2026 were ~KSh 280 bn below the bulletin by October.
#
# If the newest row is more than STALE_DAYS old the script writes nothing,
# so the monthly method (df_debt.R) stays in charge until a new row is added.
#
# Run: Rscript df_debt_bulletin.R        (DRY_RUN=true to print only)
#      FORCE=true                        write even if nothing changed
# Testing without Google/Supabase: BULLETIN_CSV, HISTORY_CSV, FINANCE_CSV, FOREX_CSV,
# FX_VALUE (or FX_HTML_FILE, a saved CBK home page), CROSS_FX_THEN and CROSS_FX_NOW
# (e.g. "EUR=0.92,CNY=7.1,JPY=150,GBP=0.78", units per US$), CROSS_FX=off.
# Scheduled: .github/workflows/debt-bulletin.yml (every 3 hours), and right
# after df_debt.R in cbk-debt-watch.yml so a fresh bulletin always wins.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
  library(httr)
  library(jsonlite)
})

DRY_RUN    <- tolower(Sys.getenv("DRY_RUN", "false")) %in% c("true", "1", "yes")
FORCE      <- tolower(Sys.getenv("FORCE", "false")) %in% c("true", "1", "yes")
TZ         <- "Africa/Nairobi"
SHEET_URL  <- "https://docs.google.com/spreadsheets/d/11Y_EoYqFJOTTubbBCQkh1gV3kbX1cVQHapdzbwWUXK4"
SHEET_TAB  <- "debt_bulletin"
STALE_DAYS <- 28          # newest domestic figure older than this: leave the counter to df_debt.R
MAX_WEEKLY_CHANGE <- 0.05 # domestic may not move more than 5% from the previous row
MAX_USD_CHANGE    <- 0.10 # external US$ may not move more than 10% from the previous row
TREND_MONTHS      <- 12
# Conservative cap: the counter never grows faster than the Budget's planned
# net borrowing for the current fiscal year (domestic and external separately).
# Budget Statement FY 2026/27 (June 2026): deficit KSh 1,146.2 bn, financed by
# net domestic borrowing KSh 1,030 bn and net external financing KSh 116.2 bn.
# Update each June (or after a Supplementary Budget), or set
# BUDGET_NET_DOM_BN / BUDGET_NET_EXT_BN; CONSERVATIVE=false switches it off.
CONSERVATIVE      <- !tolower(Sys.getenv("CONSERVATIVE", "true")) %in% c("false", "0", "no", "off")
BUDGET_FY         <- Sys.getenv("BUDGET_FY", "FY 2026/27")
BUDGET_NET_DOM_BN <- as.numeric(Sys.getenv("BUDGET_NET_DOM_BN", "1030"))
BUDGET_NET_EXT_BN <- as.numeric(Sys.getenv("BUDGET_NET_EXT_BN", "116.2"))
# Currency composition of external debt (share of the US$ total). Source:
# National Treasury, Annual Public Debt Report 2025/26, section 6.4, end June
# 2026 (USD 54.9%, EUR 26.5%, CNY 11.5%, JPY 4.7%, GBP 2.3%, others 0.1%
# counted with USD). Update when the Treasury publishes a new composition, or
# set CURRENCY_SHARES="USD=0.55,EUR=0.265,...".
CURRENCY_SHARES <- c(USD = 0.550, EUR = 0.265, CNY = 0.115, JPY = 0.047, GBP = 0.023)
STATE_FILE <- Sys.getenv("STATE_FILE", "watch/debt_bulletin.applied")

`%||%` <- function(a, b) if (is.null(a)) b else a
log_msg <- function(...) cat(format(Sys.time(), "[%H:%M:%S] "), ..., "\n", sep = "")
fail    <- function(...) stop(paste0(...), call. = FALSE)
bn      <- function(x) format(round(x / 1e9, 2), big.mark = ",", nsmall = 2)

script_dir <- function() {
  a <- sub("^--file=", "", commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))])
  if (length(a)) dirname(normalizePath(a)) else getwd()
}
SCRIPT_DIR <- script_dir()
renv <- file.path(SCRIPT_DIR, ".Renviron")
if (file.exists(renv)) readRenviron(renv)
supabase_url <- sub("/+$", "", Sys.getenv("SUPABASE_URL"))
supabase_key <- Sys.getenv("SUPABASE_SERVICE_ROLE")

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
sb_headers <- function(prefer = NULL) {
  h <- c(apikey = supabase_key, Authorization = paste("Bearer", supabase_key),
         `Content-Type` = "application/json")
  if (!is.null(prefer)) h <- c(h, Prefer = prefer)
  add_headers(.headers = h)
}
sb_get <- function(table, query) {
  res <- GET(paste0(supabase_url, "/rest/v1/", table), sb_headers(), query = query, timeout(60))
  if (http_error(res)) fail("Reading ", table, " failed (HTTP ", status_code(res), ")")
  fromJSON(content(res, as = "text", encoding = "UTF-8"))
}
sb_insert <- function(table, df) {
  res <- POST(paste0(supabase_url, "/rest/v1/", table), sb_headers("return=minimal"),
              body = toJSON(df, dataframe = "rows", digits = NA), timeout(60))
  if (http_error(res)) fail("Insert into ", table, " failed (HTTP ", status_code(res), "): ",
                            substr(content(res, as = "text", encoding = "UTF-8"), 1, 300))
}
sb_delete <- function(table, query) {
  res <- DELETE(paste0(supabase_url, "/rest/v1/", table), sb_headers("return=minimal"), query = query, timeout(60))
  if (http_error(res)) fail("Delete from ", table, " failed (HTTP ", status_code(res), "): ",
                            substr(content(res, as = "text", encoding = "UTF-8"), 1, 300))
}

# Dates typed in Google Sheets arrive as Date, POSIXct, a serial number or text.
as_day <- function(x) {
  if (inherits(x, "Date")) return(x)
  if (inherits(x, "POSIXt")) return(as_date(x))
  if (is.list(x)) x <- vapply(x, function(v) if (is.null(v) || length(v) == 0) NA_character_ else {
    if (inherits(v, "POSIXt") || inherits(v, "Date")) format(as_date(v)) else as.character(v)
  }, character(1))
  x <- trimws(as.character(x))
  out <- suppressWarnings(as_date(parse_date_time(x, c("Ymd", "dmY", "mdY", "dbY", "Ym", "bY"), quiet = TRUE)))
  serial <- suppressWarnings(as.numeric(x))
  out[is.na(out) & !is.na(serial)] <- as_date(serial[is.na(out) & !is.na(serial)], origin = "1899-12-30")
  out
}
as_num <- function(x) {
  if (is.list(x)) x <- vapply(x, function(v) if (is.null(v) || length(v) == 0) NA_character_ else as.character(v), character(1))
  suppressWarnings(as.numeric(gsub("[^0-9.\\-]", "", as.character(x))))
}

# ------------------------------------------------------------
# 1. READ THE debt_bulletin TAB
# ------------------------------------------------------------
read_bulletin <- function() {
  if (nzchar(Sys.getenv("BULLETIN_CSV"))) return(read.csv(Sys.getenv("BULLETIN_CSV"), colClasses = "character"))
  suppressPackageStartupMessages(library(googlesheets4))
  creds <- c(file.path(SCRIPT_DIR, "gsheets.json"),
             if (dir.exists(file.path(SCRIPT_DIR, ".secrets")))
               list.files(file.path(SCRIPT_DIR, ".secrets"), "\\.json$", full.names = TRUE))
  creds <- creds[file.exists(creds)]
  if (length(creds)) gs4_auth(path = creds[1]) else if (interactive()) gs4_auth() else
    fail("No Google Sheets credentials (gsheets.json next to this script).")
  as.data.frame(read_sheet(SHEET_URL, sheet = SHEET_TAB, range = paste0(SHEET_TAB, "!A:F"), col_types = "c"))
}

log_msg("Reading the '", SHEET_TAB, "' tab ...")
raw <- read_bulletin()
names(raw) <- tolower(trimws(names(raw)))
need <- c("bulletin_date", "domestic_bn", "domestic_as_at", "external_usd_bn", "external_month")
if (length(setdiff(need, names(raw)))) fail("'", SHEET_TAB, "' is missing column(s): ",
                                            paste(setdiff(need, names(raw)), collapse = ", "))
b <- data.frame(
  bulletin_date   = as_day(raw$bulletin_date),
  domestic        = as_num(raw$domestic_bn) * 1e9,
  domestic_as_at  = as_day(raw$domestic_as_at),
  external_usd    = as_num(raw$external_usd_bn) * 1e9,
  external_month  = floor_date(as_day(raw$external_month), "month")
) %>%
  filter(!is.na(bulletin_date) | !is.na(domestic)) %>%
  arrange(domestic_as_at, bulletin_date)

if (!nrow(b)) { log_msg("No bulletin rows yet; nothing to do."); quit(save = "no", status = 0) }
latest <- b[nrow(b), ]
today  <- as_date(now(tzone = TZ))

# ------------------------------------------------------------
# 2. CHECK THE LATEST ROW
# ------------------------------------------------------------
row_no <- nrow(b) + 1  # its sheet row (after the header), for messages
problems <- character(0)
if (anyNA(c(latest$bulletin_date, latest$domestic, latest$domestic_as_at, latest$external_usd, latest$external_month)))
  problems <- c(problems, "a value is missing or not a number/date")
if (isTRUE(latest$domestic < 1000e9 || latest$domestic > 50000e9))
  problems <- c(problems, sprintf("domestic_bn %s is outside 1,000-50,000", bn(latest$domestic)))
if (isTRUE(latest$external_usd < 5e9 || latest$external_usd > 200e9))
  problems <- c(problems, sprintf("external_usd_bn %s is outside 5-200", bn(latest$external_usd)))
if (isTRUE(latest$domestic_as_at > today)) problems <- c(problems, "domestic_as_at is in the future")
if (isTRUE(latest$external_month > floor_date(today, "month"))) problems <- c(problems, "external_month is in the future")
if (isTRUE(latest$domestic_as_at > latest$bulletin_date)) problems <- c(problems, "domestic_as_at is after bulletin_date")
if (nrow(b) > 1) {
  prev <- b[nrow(b) - 1, ]
  if (isTRUE(latest$domestic_as_at < prev$domestic_as_at)) problems <- c(problems, "domestic_as_at is earlier than the previous row")
  if (isTRUE(abs(latest$domestic / prev$domestic - 1) > MAX_WEEKLY_CHANGE))
    problems <- c(problems, sprintf("domestic moved %.1f%% from the previous row (limit %d%%) - typo?",
                                    100 * (latest$domestic / prev$domestic - 1), 100 * MAX_WEEKLY_CHANGE))
  if (isTRUE(abs(latest$external_usd / prev$external_usd - 1) > MAX_USD_CHANGE))
    problems <- c(problems, sprintf("external US$ moved %.1f%% from the previous row (limit %d%%) - typo?",
                                    100 * (latest$external_usd / prev$external_usd - 1), 100 * MAX_USD_CHANGE))
}
if (length(problems)) fail("Row ", row_no, " of '", SHEET_TAB, "' was not used: ", paste(problems, collapse = "; "),
                           ". Fix the row; the counter keeps its previous figures meanwhile.")

age_days <- as.numeric(today - latest$domestic_as_at)
if (age_days > STALE_DAYS) {
  log_msg(sprintf("Newest bulletin figure is %d days old (limit %d): leaving the counter to the monthly method.",
                  age_days, STALE_DAYS))
  quit(save = "no", status = 0)
}

# ------------------------------------------------------------
# 3. EXCHANGE RATE + GROWTH RATES
# ------------------------------------------------------------
# Today's CBK indicative KSh/US$ rate, read from the CBK home page on every run
# ("Daily KES Exchange Rates": US DOLLAR | 129.89 ... Posted On: 23-10-2026),
# so the external debt follows the shilling day by day. Falls back to the
# latest rate stored in df_forex (updated on the 1st and 15th) if the page
# can't be read.
cbk_daily_rate <- function() {
  tryCatch({
    suppressPackageStartupMessages(library(rvest))
    page <- if (nzchar(Sys.getenv("FX_HTML_FILE"))) read_html(Sys.getenv("FX_HTML_FILE")) else
      read_html(GET("https://www.centralbank.go.ke/", timeout(60),
                    user_agent("Mozilla/5.0 (compatible; KenyaDebtCounterBot/1.0; +https://kenyadebtcounter.vercel.app)")))
    tbls <- html_elements(page, "table")
    tbls <- tbls[grepl("US\\s*DOLLAR", html_text2(tbls), ignore.case = TRUE)]
    if (!length(tbls)) stop("no exchange rate table")
    rows <- html_elements(tbls[[1]], "tr"); txt <- html_text2(rows)
    usd  <- rows[grepl("US\\s*DOLLAR", txt, ignore.case = TRUE)]
    if (!length(usd)) stop("no US DOLLAR row")
    v <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", html_text2(html_elements(usd[[1]], "td")))))
    v <- v[!is.na(v) & v > 50 & v < 500][1]
    if (is.na(v)) stop("no plausible rate")
    posted <- grep("Posted On", c(txt, html_text2(page)), value = TRUE, ignore.case = TRUE)[1]
    d <- if (is.na(posted)) NA else suppressWarnings(dmy(regmatches(posted, regexpr("[0-9]{1,2}[-/][0-9]{1,2}[-/][0-9]{4}", posted))))
    if (!length(d) || is.na(d) || d > today || d < today - 10) d <- today
    list(value = v, date = d, source = "CBK home page (daily indicative rate)")
  }, error = function(e) { log_msg("Could not read today's CBK rate (", conditionMessage(e), "); using df_forex."); NULL })
}
fx <- if (nzchar(Sys.getenv("FX_VALUE"))) {
  list(value = as.numeric(Sys.getenv("FX_VALUE")), date = today, source = "FX_VALUE (test)")
} else {
  cbk_daily_rate() %||% {
    r <- sb_get("df_forex", list(select = "date,value,source", date = paste0("lte.", today),
                                 order = "date.desc", limit = 5))
    if (!length(r) || !nrow(r)) fail("No exchange rate from CBK or df_forex.")
    list(value = as.numeric(r$value[1]), date = as_date(substr(r$date[1], 1, 10)), source = "df_forex")
  }
}
if (!isTRUE(fx$value > 50 && fx$value < 500)) fail("Implausible KSh/US$ rate ", fx$value, " in df_forex.")
if (as.numeric(today - fx$date) > 14) warning("Exchange rate is from ", fx$date, " (more than two weeks old).", call. = FALSE)

# Cross-currency factor: the bulletin gives external debt in US$ at the end
# of its month. Since then the euro, yuan, yen and sterling have moved
# against the dollar, which changes the US$ value of debt owed in them.
#   factor = sum over currencies of share x (units per US$ then / units per US$ now)
# Rates: ECB reference rates via the Frankfurter API (no key). If they can't
# be read, the factor is 1 (US$ figure unchanged), as before.
parse_rates <- function(x) {
  kv <- strsplit(trimws(strsplit(x, ",")[[1]]), "=")
  setNames(as.numeric(vapply(kv, `[`, "", 2)), vapply(kv, `[`, "", 1))
}
if (nzchar(Sys.getenv("CURRENCY_SHARES"))) CURRENCY_SHARES <- parse_rates(Sys.getenv("CURRENCY_SHARES"))
CURRENCY_SHARES <- CURRENCY_SHARES / sum(CURRENCY_SHARES)
frankfurter <- function(day) {
  syms <- setdiff(names(CURRENCY_SHARES), "USD")
  urls <- c(sprintf("https://api.frankfurter.dev/v1/%s?base=USD&symbols=%s", day, paste(syms, collapse = ",")),
            sprintf("https://api.frankfurter.app/%s?from=USD&to=%s", day, paste(syms, collapse = ",")))
  for (u in urls) {
    r <- tryCatch(GET(u, timeout(30)), error = function(e) NULL)
    if (!is.null(r) && !http_error(r)) {
      j <- fromJSON(content(r, as = "text", encoding = "UTF-8"))
      v <- unlist(j$rates)
      if (all(syms %in% names(v))) return(list(rates = v[syms], date = as_date(j$date)))
    }
  }
  NULL
}
cross_fx <- function() {
  one <- list(factor = 1, note = "not applied")
  if (tolower(Sys.getenv("CROSS_FX")) %in% c("off", "false", "0")) return(one)
  month_end <- (latest$external_month %m+% months(1)) - 1
  then <- if (nzchar(Sys.getenv("CROSS_FX_THEN"))) list(rates = parse_rates(Sys.getenv("CROSS_FX_THEN")), date = month_end) else
    frankfurter(format(month_end))
  now_r <- if (nzchar(Sys.getenv("CROSS_FX_NOW"))) list(rates = parse_rates(Sys.getenv("CROSS_FX_NOW")), date = today) else
    frankfurter("latest")
  if (is.null(then) || is.null(now_r)) { log_msg("Cross-currency rates unavailable; US$ figure used as is."); return(one) }
  syms <- setdiff(names(CURRENCY_SHARES), "USD")
  rel <- then$rates[syms] / now_r$rates[syms]
  if (anyNA(rel)) { log_msg("Cross-currency rates incomplete; US$ figure used as is."); return(one) }
  f <- unname(CURRENCY_SHARES["USD"] %||% 0) + sum(CURRENCY_SHARES[syms] * rel)
  if (!isTRUE(f > 0.85 && f < 1.15)) { log_msg(sprintf("Cross-currency factor %.4f implausible; not applied.", f)); return(one) }
  list(factor = f, note = sprintf("%.4f (%s to %s; %s)", f, format(then$date), format(now_r$date),
                                  paste(sprintf("%s %+.1f%%", syms, 100 * (rel - 1)), collapse = ", ")))
}
xfx <- cross_fx()
ext_usd_now <- latest$external_usd * xfx$factor

hist <- if (nzchar(Sys.getenv("HISTORY_CSV"))) read.csv(Sys.getenv("HISTORY_CSV")) else
  sb_get("df_debt_historical", list(select = "date,debt_dom,debt_ext,source", source = "eq.actual",
                                    order = "date.asc", limit = 1000))
hist <- hist %>% mutate(date = as_date(substr(date, 1, 10))) %>% arrange(date) %>% distinct(date, .keep_all = TRUE)
recent <- tail(hist, TREND_MONTHS + 1)
if (nrow(recent) < 7) fail("Too little CBK monthly history in df_debt_historical for growth rates.")
span <- as.numeric(difftime(max(recent$date), min(recent$date), units = "secs"))
gps_ext <- (last(recent$debt_ext) - first(recent$debt_ext)) / span
gps_dom <- (last(recent$debt_dom) - first(recent$debt_dom)) / span
dom_basis <- sprintf("%d-month CBK trend", TREND_MONTHS)
# External growth at a CONSTANT exchange rate: the shilling's effect is
# already in the external LEVEL (today's rate), so the growth rate should
# count only new borrowing net of repayments. Convert each month's KSh
# figure to US$ with CBK's end-month rate (df_forex), take the change in
# US$, and value it at today's rate. Falls back to the KSh trend if the
# monthly rates are missing.
ext_basis <- "KSh trend (includes exchange-rate moves)"
forex <- tryCatch({
  r <- if (nzchar(Sys.getenv("FOREX_CSV"))) read.csv(Sys.getenv("FOREX_CSV")) else
    sb_get("df_forex", list(select = "date,value,source", order = "date.asc", limit = 2000))
  if (!"source" %in% names(r)) r$source <- "Actual"
  r %>% mutate(date = floor_date(as_date(substr(date, 1, 10)), "month"), value = as.numeric(value),
               actual = tolower(source) == "actual") %>%
    arrange(date, desc(actual)) %>% distinct(date, .keep_all = TRUE)
}, error = function(e) { log_msg("df_forex unavailable (", conditionMessage(e), ")."); NULL })
fx_first <- forex$value[match(floor_date(first(recent$date), "month"), forex$date)]
fx_last  <- forex$value[match(floor_date(last(recent$date), "month"), forex$date)]
if (length(fx_first) && length(fx_last) && isTRUE(fx_first > 50 && fx_first < 500 && fx_last > 50 && fx_last < 500)) {
  usd_change <- last(recent$debt_ext) / fx_last - first(recent$debt_ext) / fx_first
  gps_ext <- usd_change * fx$value / span
  ext_basis <- sprintf("US$ change over %d months x today's rate", TREND_MONTHS)
}
gps_underlying <- gps_dom + gps_ext   # 12-month change in debt at a constant exchange rate
# Once the bulletin rows cover 8+ weeks, use their own (more current) domestic pace.
wk <- b %>% filter(!is.na(domestic), domestic_as_at >= latest$domestic_as_at - 182) %>% distinct(domestic_as_at, .keep_all = TRUE)
if (nrow(wk) >= 2 && as.numeric(max(wk$domestic_as_at) - min(wk$domestic_as_at)) >= 56) {
  gps_dom <- (last(wk$domestic) - first(wk$domestic)) /
    as.numeric(difftime(max(wk$domestic_as_at), min(wk$domestic_as_at), units = "secs"))
  dom_basis <- sprintf("bulletins %s to %s", min(wk$domestic_as_at), max(wk$domestic_as_at))
}
if (!isTRUE(gps_dom > -1e6 && gps_dom < 1e6 && gps_ext > -1e6 && gps_ext < 1e6)) fail("Implausible growth rates.")

# Cross-check against the budget deficit. Debt grows by roughly the deficit
# (which already includes interest payments) plus currency revaluation of
# external debt; the shilling effect is in the external LEVEL above, so the
# growth rate should be close to the deficit pace. df_finance holds CBK's
# revenue and expenditure, cumulative within each July-June fiscal year; the
# last 12 months' deficit = this year so far + last full year - last year to
# the same month.
deficit_12m <- function() {
  f <- if (nzchar(Sys.getenv("FINANCE_CSV"))) read.csv(Sys.getenv("FINANCE_CSV")) else
    sb_get("df_finance", list(select = "date,expenditure,revenue", order = "date.asc", limit = 2000))
  if (!length(f) || !nrow(f)) return(NULL)
  f <- f %>% mutate(date = floor_date(as_date(substr(date, 1, 10)), "month"),
                    cum = as.numeric(expenditure) - as.numeric(revenue)) %>%
    filter(!is.na(cum), date <= floor_date(today, "month")) %>% distinct(date, .keep_all = TRUE)
  at <- function(d) { v <- f$cum[f$date == d]; if (length(v)) v[1] else NA_real_ }
  L <- max(f$date)
  june <- make_date(if (month(L) >= 7) year(L) else year(L) - 1, 6, 1)  # end of the previous fiscal year
  d12 <- if (month(L) == 6) at(L) else at(L) + at(june) - at(L %m-% months(12))
  if (!is.finite(d12) || d12 < 100e9 || d12 > 5000e9) return(NULL)
  list(value = d12, to = L)
}
gps_trend <- gps_dom + gps_ext
growth_basis <- "observed trend"
share_dom <- latest$domestic / (latest$domestic + ext_usd_now * fx$value)
set_pace <- function(gps) { gps_dom <<- gps * share_dom; gps_ext <<- gps * (1 - share_dom) }
def <- tryCatch(deficit_12m(), error = function(e) { log_msg("Deficit unavailable (", conditionMessage(e), ")."); NULL })
if (!is.null(def)) {
  gps_deficit <- def$value / (365.25 * 86400)
  # Underlying pace = deficit + other adjustments (cash balances, debt taken
  # over, arrears, loans outside the budget) = the 12-month change in debt at
  # a constant exchange rate. Used as the benchmark when it is close enough to
  # the deficit (0.5-2.5x); otherwise the deficit itself is the benchmark.
  adj <- (gps_underlying - gps_deficit) * 365.25 * 86400
  u_ratio <- gps_underlying / gps_deficit
  if (isTRUE(u_ratio >= 0.5 && u_ratio <= 2.5)) {
    gps_bench <- gps_underlying; bench_name <- "underlying pace (deficit + other adjustments)"
  } else {
    gps_bench <- gps_deficit; bench_name <- sprintf("deficit pace (underlying pace was %.2fx it)", u_ratio)
  }
  ratio <- gps_trend / gps_bench
  if (isTRUE(ratio >= 0.5 && ratio <= 2)) {
    growth_basis <- sprintf("observed trend (%.2fx the %s: consistent)", ratio, bench_name)
  } else {
    # Far from the benchmark (a one-off loan, a lumpy repayment...): grow at the
    # benchmark pace instead, split between domestic and external as the debt is.
    set_pace(gps_bench)
    growth_basis <- sprintf("%s (observed trend was %.2fx it, outside 0.5-2x)", bench_name, ratio)
  }
  cat(sprintf("Deficit, 12 months to %s: KSh %s bn = KSh %s/sec\n", format(def$to, "%b %Y"), bn(def$value),
              format(round(gps_deficit), big.mark = ",")))
  cat(sprintf("Other adjustments, 12 months: KSh %s bn (underlying pace KSh %s/sec = %.2fx the deficit)\n",
              bn(adj), format(round(gps_underlying), big.mark = ","), u_ratio))
} else {
  log_msg("No deficit figures; growth from the observed trend only.")
}

# Conservative cap (see BUDGET_NET_*_BN above): each part grows at the lower of
# its observed pace and the Budget's planned net borrowing.
cap_note <- "off"
if (CONSERVATIVE && isTRUE(BUDGET_NET_DOM_BN > 0 && BUDGET_NET_EXT_BN >= 0)) {
  cap_dom <- BUDGET_NET_DOM_BN * 1e9 / (365.25 * 86400)
  cap_ext <- BUDGET_NET_EXT_BN * 1e9 / (365.25 * 86400)
  was <- c(gps_dom, gps_ext)
  gps_dom <- min(gps_dom, cap_dom)
  gps_ext <- min(gps_ext, cap_ext)
  cap_note <- sprintf("%s Budget net borrowing: domestic KSh %s/sec (trend %s), external KSh %s/sec (trend %s)",
                      BUDGET_FY, format(round(cap_dom), big.mark = ","), format(round(was[1]), big.mark = ","),
                      format(round(cap_ext), big.mark = ","), format(round(was[2]), big.mark = ","))
}

# ------------------------------------------------------------
# 4. THE DEBT RIGHT NOW
# ------------------------------------------------------------
now_time <- now(tzone = TZ)
dom_from <- force_tz(as_datetime(latest$domestic_as_at + 1), TZ)                 # end of that day
ext_from <- force_tz(as_datetime(latest$external_month %m+% months(1)), TZ)      # end of that month
secs <- function(from) max(0, as.numeric(difftime(now_time, from, units = "secs")))
debt_dom <- latest$domestic + gps_dom * secs(dom_from)
debt_ext <- ext_usd_now * fx$value + gps_ext * secs(ext_from)
debt_ttl <- debt_dom + debt_ext
gps_ttl  <- gps_dom + gps_ext

last_actual_ttl <- tail(hist$debt_dom + hist$debt_ext, 1)
if (!isTRUE(debt_ttl > 5e12 && debt_ttl < 60e12)) fail("Total debt ", bn(debt_ttl), " bn is implausible.")
if (isTRUE(abs(debt_ttl / last_actual_ttl - 1) > 0.15))
  fail(sprintf("Total %s bn is more than 15%% away from the last CBK monthly figure (%s bn); check the sheet.",
               bn(debt_ttl), bn(last_actual_ttl)))

stamp <- sub("(\\d{2})(\\d{2})$", "\\1:\\2", format(now_time, "%Y-%m-%dT%H:%M:%S%z"))
signature <- paste(latest$bulletin_date, latest$domestic, latest$domestic_as_at, latest$external_usd,
                   latest$external_month, fx$value, fx$date, round(xfx$factor, 4),
                   if (CONSERVATIVE) paste0("cap", BUDGET_NET_DOM_BN, "/", BUDGET_NET_EXT_BN) else "nocap", sep = "|")
unchanged <- file.exists(STATE_FILE) && identical(readLines(STATE_FILE, warn = FALSE)[1], signature)

cat("\n============ WEEKLY BULLETIN NOWCAST ============\n")
cat("Bulletin          :", format(latest$bulletin_date), "(sheet row", row_no, ")\n")
cat("Domestic          :", bn(latest$domestic), "bn as at", format(latest$domestic_as_at),
    "->", bn(debt_dom), "bn now\n")
cat("External          : US$", bn(latest$external_usd), "bn (", format(latest$external_month, "%b %Y"), ") x",
    fx$value, "KSh/US$ (", format(fx$date), ",", fx$source, ") ->", bn(debt_ext), "bn now\n")
cat("Total now         :", bn(debt_ttl), "bn  (last CBK monthly:", bn(last_actual_ttl), "bn)\n")
cat("Growth per second : KSh", round(gps_ttl), "(domestic", round(gps_dom), "; external", round(gps_ext), ")\n")
cat("Growth basis      :", growth_basis, "| domestic trend from", dom_basis, "\n")
cat("Cross-currency    :", xfx$note, "| external growth:", ext_basis, "\n")
cat("Conservative cap  :", cap_note, "\n")
cat("=================================================\n")

# ------------------------------------------------------------
# 5. MONTHS AFTER THE LAST CBK MONTHLY FIGURE, ANCHORED ON THE BULLETIN
# ------------------------------------------------------------
# A row dated the 1st of a month holds the stock at the END of that month
# (CBK's convention in df_debt_historical). The path for each part runs
# through: the last CBK monthly figure (end of its month), then the bulletin
# figure (domestic at the end of its date; external at the end of its month,
# at today's rate), then on at the growth rate per second.
last_hist <- tail(hist, 1)
t_actual  <- force_tz(as_datetime(last_hist$date %m+% months(1)), TZ)
path_at <- function(times, t_pts, v_pts, gps) {
  ok <- as.numeric(t_pts) >= as.numeric(t_actual)        # a bulletin older than the CBK month is ignored
  t_pts <- as.numeric(t_pts[ok]); v_pts <- v_pts[ok]
  o <- order(t_pts); t_pts <- t_pts[o]; v_pts <- v_pts[o]
  x <- as.numeric(times); t_end <- max(t_pts); v_end <- v_pts[which.max(t_pts)]
  out <- if (length(t_pts) > 1) approx(t_pts, v_pts, xout = pmin(x, t_end), rule = 2)$y else rep(v_end, length(x))
  out + ifelse(x > t_end, gps * (x - t_end), 0)
}
# Completed months only (their end has passed), then a row for today; the
# current month's row would be its future month-end and plot after today.
last_full  <- floor_date(as_date(now_time), "month") %m-% months(1)
est_months <- if (last_full > last_hist$date) seq(last_hist$date %m+% months(1), last_full, by = "month") else as.Date(character(0))
t_rows <- c(force_tz(as_datetime(est_months %m+% months(1)), TZ), now_time)
est_dom <- path_at(t_rows, c(t_actual, dom_from), c(last_hist$debt_dom, latest$domestic), gps_dom)
est_ext <- path_at(t_rows, c(t_actual, ext_from), c(last_hist$debt_ext, ext_usd_now * fx$value), gps_ext)
# Today's row is the counter's own figure, so the history ends exactly where the counter is.
est_dom[length(est_dom)] <- debt_dom
est_ext[length(est_ext)] <- debt_ext
est_rows <- data.frame(
  date = c(format(est_months, "%Y-%m-%d"), format(as_date(now_time), "%Y-%m-%d")),
  debt_dom = est_dom, debt_ext = est_ext, debt_ttl = est_dom + est_ext, source = "estimate"
)
est_rows <- est_rows[!duplicated(est_rows$date, fromLast = TRUE), ]  # a month's 1st = today: keep today's row
cat("Months after the last CBK figure (", format(last_hist$date, "%b %Y"), "), anchored on the bulletin:\n", sep = "")
for (i in seq_len(nrow(est_rows))) cat(sprintf("  %s  KSh %s bn (domestic %s, external %s)\n", est_rows$date[i],
                                               bn(est_rows$debt_ttl[i]), bn(est_rows$debt_dom[i]), bn(est_rows$debt_ext[i])))

if (DRY_RUN) { log_msg("DRY RUN - nothing written."); quit(save = "no", status = 0) }
if (unchanged && !FORCE) { log_msg("Same bulletin row and exchange rate as last run - nothing to write."); quit(save = "no", status = 0) }
if (!nzchar(supabase_url) || !nzchar(supabase_key)) fail("SUPABASE_URL and SUPABASE_SERVICE_ROLE must be set.")

sb_insert("df_debt_current", data.frame(date = stamp, debt_dom = debt_dom, debt_ext = debt_ext, debt_ttl = debt_ttl))
sb_insert("df_debt_growth_per_sec", data.frame(date = stamp, gps_dom = gps_dom, gps_ext = gps_ext, gps_ttl = gps_ttl))
# Replace the estimated months: insert the new rows first, then remove every
# older non-actual row after the last CBK month (ARIMA forecasts, earlier
# estimates, "current" rows), so the table is never left without them.
if (nrow(est_rows)) {
  run_started <- format(now(tzone = "UTC"), "%Y-%m-%dT%H:%M:%OS3Z")
  sb_insert("df_debt_historical", est_rows)
  sb_delete("df_debt_historical", list(source = "in.(forecast,current,estimate)",
                                       date = paste0("gt.", format(last_hist$date, "%Y-%m-%d")),
                                       created_at = paste0("lt.", run_started)))
  log_msg("df_debt_historical: ", nrow(est_rows), " estimated rows after ", format(last_hist$date, "%b %Y"), " rebuilt from the bulletin.")
}
dir.create(dirname(STATE_FILE), showWarnings = FALSE, recursive = TRUE)
writeLines(signature, STATE_FILE)
log_msg("Counter updated from the ", format(latest$bulletin_date), " bulletin.")
