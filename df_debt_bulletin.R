# ============================================================
# KENYA NATIONAL DEBT COUNTER — WEEKLY BULLETIN NOWCAST (df_debt_bulletin.R)
# ============================================================
#
# What this script does
#   1. Reads the "debt_bulletin" tab of the IEA Kenya Google Sheet, where the
#      figures from each CBK Weekly Bulletin are entered by hand:
#        bulletin_date | domestic_bn | domestic_as_at | external_usd_bn | external_month | note
#      (Table 8 "Government Domestic Debt": the latest gross domestic debt and
#       its date; Table 11 "Public Debt": the latest external debt in US$.)
#   2. Checks the latest row (dates, plausible values, not a jump from the
#      previous row) so a typo never reaches the counter.
#   3. Works out the debt right now:
#        domestic = latest weekly figure + domestic growth × time since its date
#        external = US$ figure × TODAY's CBK KSh/US$ rate (read from the CBK
#                   home page on every run; df_forex as a fallback)
#                   + external growth × time since the end of its month
#      Growth rates come from the bulletin rows themselves once they cover
#      8+ weeks, otherwise from the last 12 months of CBK actuals
#      (df_debt_historical), and are checked against the budget deficit of
#      the last 12 months (df_finance): within 0.5-2x the deficit pace the
#      observed trend is used; outside it, the deficit pace.
#   4. Adds a row to df_debt_current and df_debt_growth_per_sec (the two
#      tables the website ticks the counter from), unless nothing changed
#      since the last run.
#
# If the newest row is more than STALE_DAYS old the script writes nothing,
# so the monthly method (df_debt.R) stays in charge until a new row is added.
#
# Run: Rscript df_debt_bulletin.R        (DRY_RUN=true to print only)
#      FORCE=true                        write even if nothing changed
# Testing without Google/Supabase: BULLETIN_CSV, HISTORY_CSV, FINANCE_CSV, FX_VALUE
# (or FX_HTML_FILE, a saved CBK home page).
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
def <- tryCatch(deficit_12m(), error = function(e) { log_msg("Deficit unavailable (", conditionMessage(e), ")."); NULL })
if (!is.null(def)) {
  gps_deficit <- def$value / (365.25 * 86400)
  ratio <- gps_trend / gps_deficit
  if (isTRUE(ratio >= 0.5 && ratio <= 2)) {
    growth_basis <- sprintf("observed trend (%.2fx the deficit pace: consistent)", ratio)
  } else {
    # Far from the deficit pace (a one-off loan, a revaluation...): grow at the
    # deficit pace instead, split between domestic and external as the debt is.
    share_dom <- latest$domestic / (latest$domestic + latest$external_usd * fx$value)
    gps_dom <- gps_deficit * share_dom
    gps_ext <- gps_deficit * (1 - share_dom)
    growth_basis <- sprintf("budget deficit pace (observed trend was %.2fx it, outside 0.5-2x)", ratio)
  }
  cat(sprintf("Deficit, 12 months to %s: KSh %s bn = KSh %s/sec\n", format(def$to, "%b %Y"), bn(def$value),
              format(round(gps_deficit), big.mark = ",")))
} else {
  log_msg("No deficit figures; growth from the observed trend only.")
}

# ------------------------------------------------------------
# 4. THE DEBT RIGHT NOW
# ------------------------------------------------------------
now_time <- now(tzone = TZ)
dom_from <- force_tz(as_datetime(latest$domestic_as_at + 1), TZ)                 # end of that day
ext_from <- force_tz(as_datetime(latest$external_month %m+% months(1)), TZ)      # end of that month
secs <- function(from) max(0, as.numeric(difftime(now_time, from, units = "secs")))
debt_dom <- latest$domestic + gps_dom * secs(dom_from)
debt_ext <- latest$external_usd * fx$value + gps_ext * secs(ext_from)
debt_ttl <- debt_dom + debt_ext
gps_ttl  <- gps_dom + gps_ext

last_actual_ttl <- tail(hist$debt_dom + hist$debt_ext, 1)
if (!isTRUE(debt_ttl > 5e12 && debt_ttl < 60e12)) fail("Total debt ", bn(debt_ttl), " bn is implausible.")
if (isTRUE(abs(debt_ttl / last_actual_ttl - 1) > 0.15))
  fail(sprintf("Total %s bn is more than 15%% away from the last CBK monthly figure (%s bn); check the sheet.",
               bn(debt_ttl), bn(last_actual_ttl)))

stamp <- sub("(\\d{2})(\\d{2})$", "\\1:\\2", format(now_time, "%Y-%m-%dT%H:%M:%S%z"))
signature <- paste(latest$bulletin_date, latest$domestic, latest$domestic_as_at, latest$external_usd,
                   latest$external_month, fx$value, fx$date, sep = "|")
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
cat("=================================================\n")

if (DRY_RUN) { log_msg("DRY RUN - nothing written."); quit(save = "no", status = 0) }
if (unchanged && !FORCE) { log_msg("Same bulletin row and exchange rate as last run - nothing to write."); quit(save = "no", status = 0) }
if (!nzchar(supabase_url) || !nzchar(supabase_key)) fail("SUPABASE_URL and SUPABASE_SERVICE_ROLE must be set.")

sb_insert("df_debt_current", data.frame(date = stamp, debt_dom = debt_dom, debt_ext = debt_ext, debt_ttl = debt_ttl))
sb_insert("df_debt_growth_per_sec", data.frame(date = stamp, gps_dom = gps_dom, gps_ext = gps_ext, gps_ttl = gps_ttl))
dir.create(dirname(STATE_FILE), showWarnings = FALSE, recursive = TRUE)
writeLines(signature, STATE_FILE)
log_msg("Counter updated from the ", format(latest$bulletin_date), " bulletin.")
