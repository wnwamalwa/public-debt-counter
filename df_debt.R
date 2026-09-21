# ============================================================
# KENYA NATIONAL DEBT COUNTER — PUBLIC DEBT PIPELINE (df_debt.R)
# ============================================================
#
# What this script does
#   1. Downloads CBK's monthly Public Debt series (domestic, external, total)
#   2. Validates it (columns, freshness, plausible values)
#   3. Fills gaps between months (linear interpolation)
#   4. Forecasts TOTAL debt to next month (auto.arima), then splits it into
#      domestic/external using CBK's latest actual proportion
#   5. Works out growth per second for this month and the value right now,
#      with a sanity check against the last 12 months' actual trend
#   6. Uploads to Supabase:
#        df_debt_historical        full monthly series (actual / interpolated / forecast)
#        df_debt_current           one new row: current debt levels
#        df_debt_growth_per_sec    one new row: current growth per second
#                                  both stamped with the exact time (Africa/Nairobi)
#   7. Prints a summary
#
# The website (kenyadebtcounter.vercel.app) reads the LATEST df_debt_current
# and df_debt_growth_per_sec rows and ticks the counter forward from them:
# value + gps × seconds since `date`.
#
# How to run
#   In Positron/RStudio: open this file and click Source, or
#   in a terminal:       Rscript df_debt.R
#   Set DRY_RUN <- TRUE below to calculate and print without uploading.
#
# Credentials (.Renviron next to this script)
#   SUPABASE_URL           https://<project>.supabase.co
#   SUPABASE_SERVICE_ROLE  service_role key (needed to write once RLS is on)
#   Never commit .Renviron or share the service_role key.
#
# One-time Supabase setup: see rename_debt_tables.sql (df_debt -> df_debt_historical,
# df_debt_metrics split into df_debt_current + df_debt_growth_per_sec). The `source`
# column and timestamptz `date` column from the old setup carry over automatically.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(lubridate)
  library(zoo)
  library(forecast)
  library(readr)
  library(httr)
  library(jsonlite)
})

# ------------------------------------------------------------
# SETTINGS
# ------------------------------------------------------------

DRY_RUN <- FALSE  # TRUE = calculate and print only, no upload

# CBK re-uploads the file under a NEW name each time (e.g. 42346012_Public Debt.csv
# -> 1071243323_Public Debt.csv), so the link is looked up on this page every run.
CBK_PAGE     <- "https://www.centralbank.go.ke/statistics/government-finance-statistics/"
CBK_FILE_KEY <- "Public%20Debt.csv"   # matches ..._Public%20Debt.csv (not "Domestic Debt by Instrument")
TZ      <- "Africa/Nairobi"

MAX_DATA_AGE_MONTHS  <- 9     # stop if CBK's latest month is older than this
WARN_DATA_AGE_MONTHS <- 4     # warn if older than this
TREND_MONTHS         <- 12    # window for the sanity-check trend
GPS_RATIO_LIMITS     <- c(0.25, 4)  # ARIMA growth must be within these × trend
UPLOAD_BATCH         <- 500

log_msg <- function(...) cat(format(Sys.time(), "[%H:%M:%S] "), ..., "\n", sep = "")

# ------------------------------------------------------------
# 1. CREDENTIALS
# ------------------------------------------------------------

script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
  if (length(file_arg)) return(dirname(normalizePath(file_arg)))
  for (i in rev(seq_len(sys.nframe()))) {                  # source("df_debt.R")
    of <- sys.frame(i)$ofile
    if (!is.null(of)) return(dirname(normalizePath(of)))
  }
  if (requireNamespace("rstudioapi", quietly = TRUE) &&    # Positron / RStudio
      isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))) {
    p <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) "")
    if (nzchar(p)) return(dirname(normalizePath(p)))
  }
  getwd()
}

renv_path <- file.path(script_dir(), ".Renviron")
if (file.exists(renv_path)) readRenviron(renv_path) else if (file.exists(".Renviron")) readRenviron(".Renviron")

supabase_url <- sub("/+$", "", Sys.getenv("SUPABASE_URL"))
supabase_key <- Sys.getenv("SUPABASE_SERVICE_ROLE")
if (!nzchar(supabase_key)) {
  supabase_key <- Sys.getenv("SUPABASE_API")
  if (nzchar(supabase_key)) {
    warning("SUPABASE_SERVICE_ROLE not set; using SUPABASE_API. Writes will fail once RLS is enabled.",
            call. = FALSE)
  }
}
if (!DRY_RUN && (!nzchar(supabase_url) || !nzchar(supabase_key))) {
  stop("SUPABASE_URL and SUPABASE_SERVICE_ROLE must be set in ", renv_path, call. = FALSE)
}

# ------------------------------------------------------------
# 1b. PRE-FLIGHT CREDENTIAL CHECK
#     Two different Supabase projects were confused for hours in
#     this pipeline's history because a key can be a perfectly
#     well-formed JWT and STILL be signed for the wrong project,
#     or be an anon key masquerading as service_role. Both look
#     fine until Supabase silently rejects every request. This
#     check decodes the key's PUBLIC claims (never the secret
#     signature) and refuses to run against a mismatched key.
#     See scripts/check-supabase-key.sh to test a key by hand.
# ------------------------------------------------------------
decode_jwt_claims <- function(key) {
  parts <- strsplit(key, ".", fixed = TRUE)[[1]]
  if (length(parts) != 3) return(NULL)
  b64 <- chartr("-_", "+/", parts[2])
  rem <- nchar(b64) %% 4
  if (rem == 2) b64 <- paste0(b64, "==") else if (rem == 3) b64 <- paste0(b64, "=")
  raw <- tryCatch(rawToChar(jsonlite::base64_dec(b64)), error = function(e) NULL)
  if (is.null(raw)) return(NULL)
  tryCatch(jsonlite::fromJSON(raw), error = function(e) NULL)
}

if (nzchar(supabase_key) && nzchar(supabase_url)) {
  claims <- decode_jwt_claims(supabase_key)
  expected_ref <- sub("^https?://([^.]+)\\..*$", "\\1", supabase_url)
  if (is.null(claims)) {
    warning("Could not decode the Supabase key as a JWT -- skipping the project/role pre-flight check.",
            call. = FALSE)
  } else {
    got_ref  <- if (is.null(claims$ref))  "?" else claims$ref
    got_role <- if (is.null(claims$role)) "?" else claims$role
    if (!identical(got_ref, expected_ref)) {
      stop(sprintf(
        "CREDENTIAL MISMATCH: the key in %s is signed for project '%s', but SUPABASE_URL points at '%s'.\n  This key belongs to a DIFFERENT Supabase project -- fix .Renviron before continuing.\n  Verify a candidate key with: scripts/check-supabase-key.sh <key> %s service_role",
        renv_path, got_ref, expected_ref, expected_ref
      ), call. = FALSE)
    }
    if (!identical(got_role, "service_role")) {
      stop(sprintf(
        "CREDENTIAL MISMATCH: the key in %s has role '%s', not 'service_role'.\n  Writes need the service_role key -- copy it from Settings -> API for project '%s'.",
        renv_path, got_role, expected_ref
      ), call. = FALSE)
    }
    cat(sprintf("Credential check OK -- key matches project '%s' with role 'service_role'.\n", expected_ref))
  }
}

# ------------------------------------------------------------
# 2. DOWNLOAD + VALIDATE CBK DATA
# ------------------------------------------------------------

find_cbk_file <- function(page, key) {
  html <- tryCatch(content(GET(page, timeout(60)), as = "text", encoding = "UTF-8"),
                   error = function(e) stop("Could not open ", page, ": ", conditionMessage(e), call. = FALSE))
  links <- regmatches(html, gregexpr('href=["\']([^"\']+)["\']', html))[[1]]
  links <- gsub('^href=["\']|["\']$', "", links)
  links <- unique(gsub(" ", "%20", links))
  hit <- links[grepl(paste0("/[0-9]+_", key, "$"), links, fixed = FALSE)]
  if (!length(hit)) stop("No '", URLdecode(key), "' link found on ", page, call. = FALSE)
  if (!grepl("^https?://", hit[1])) hit[1] <- paste0("https://www.centralbank.go.ke", hit[1])
  hit[1]
}

log_msg("Finding latest CBK public debt file ...")
CBK_URL <- find_cbk_file(CBK_PAGE, CBK_FILE_KEY)
log_msg("Using ", URLdecode(CBK_URL))
log_msg("Downloading CBK public debt series ...")
raw <- tryCatch(
  read.csv(CBK_URL, skip = 3, check.names = FALSE, stringsAsFactors = FALSE),
  error = function(e) stop("Could not download CBK data: ", conditionMessage(e), call. = FALSE)
)

# Normalise column names (e.g. "Domestic Debt" -> "domestic_debt")
names(raw) <- tolower(gsub("[^A-Za-z0-9]+", "_", trimws(names(raw))))
names(raw) <- gsub("^_|_$", "", names(raw))
required <- c("year", "month", "domestic_debt", "external_debt", "total")
missing_cols <- setdiff(required, names(raw))
if (length(missing_cols)) {
  stop("CBK file format changed. Missing columns: ", paste(missing_cols, collapse = ", "),
       "\nColumns found: ", paste(names(raw), collapse = ", "), call. = FALSE)
}

month_num <- function(m) {
  m <- trimws(as.character(m))
  n <- suppressWarnings(as.integer(m))
  by_name <- match(tolower(substr(m, 1, 3)), tolower(month.abb))
  ifelse(is.na(n), by_name, n)
}

actual <- raw %>%
  transmute(
    date     = make_date(suppressWarnings(as.integer(year)), month_num(month), 1),
    debt_dom = parse_number(as.character(domestic_debt)) * 1e6,  # CBK reports KSh million
    debt_ext = parse_number(as.character(external_debt)) * 1e6,
    debt_ttl = parse_number(as.character(total)) * 1e6
  ) %>%
  filter(!is.na(date), !is.na(debt_ttl)) %>%
  distinct(date, .keep_all = TRUE) %>%
  arrange(date)

if (nrow(actual) < 36) stop("CBK series too short (", nrow(actual), " rows).", call. = FALSE)
if (any(actual$debt_ttl <= 0 | actual$debt_dom < 0 | actual$debt_ext < 0, na.rm = TRUE)) {
  stop("CBK series contains zero/negative debt values.", call. = FALSE)
}

# Published total vs domestic + external: rescale the split onto the total so
# the three always add up (keeps CBK's total exact and its dom:ext ratio).
gap <- abs(actual$debt_dom + actual$debt_ext - actual$debt_ttl) / actual$debt_ttl
if (max(gap, na.rm = TRUE) > 0.02) {
  warning(sprintf("Domestic + external differs from total by up to %.1f%% in the CBK file.",
                  100 * max(gap, na.rm = TRUE)), call. = FALSE)
}
actual <- actual %>%
  mutate(share    = debt_dom / (debt_dom + debt_ext),
         debt_dom = debt_ttl * share,
         debt_ext = debt_ttl - debt_dom) %>%
  select(-share)

now_time    <- now(tzone = TZ)
this_month  <- as_date(floor_date(now_time, "month"))
next_month  <- this_month %m+% months(1)
last_actual <- max(actual$date)
data_age    <- interval(last_actual, this_month) %/% months(1)

log_msg("Latest CBK month: ", format(last_actual, "%b %Y"), " (", data_age, " months ago)")
if (data_age > MAX_DATA_AGE_MONTHS) {
  stop("CBK data is ", data_age, " months old; refusing to forecast that far. Check ", CBK_PAGE,
       call. = FALSE)
}
if (data_age > WARN_DATA_AGE_MONTHS) {
  warning("CBK data is ", data_age, " months old; forecast uncertainty is higher.", call. = FALSE)
}

# ------------------------------------------------------------
# 3. FILL GAPS + 4. FORECAST TOTAL DEBT TO NEXT MONTH
# ------------------------------------------------------------
# Only the TOTAL is forecast. Domestic and external are then split out of that
# total using the latest ACTUAL domestic:external proportion from CBK, so the
# split always reflects published data rather than three separate forecasts.

monthly <- tibble(date = seq(min(actual$date), last_actual, by = "month")) %>%
  left_join(actual, by = "date") %>%
  mutate(source = if_else(is.na(debt_ttl), "interpolated", "actual"),
         across(c(debt_dom, debt_ext, debt_ttl), ~ na.approx(.x, x = date, na.rm = FALSE)))

latest_actual_row <- actual %>% filter(date == last_actual)
share_dom <- latest_actual_row$debt_dom / latest_actual_row$debt_ttl
share_ext <- 1 - share_dom
log_msg(sprintf("Actual split at %s: domestic %.1f%%, external %.1f%%",
                format(last_actual, "%b %Y"), 100 * share_dom, 100 * share_ext))

h <- interval(last_actual, next_month) %/% months(1)

if (h > 0) {
  log_msg("Forecasting total debt ", h, " month(s) ahead with auto.arima ...")
  ts_total <- ts(monthly$debt_ttl,
                 start = c(year(min(monthly$date)), month(min(monthly$date))), frequency = 12)
  fc_total <- as.numeric(forecast(auto.arima(ts_total), h = h)$mean)
  future <- tibble(
    date     = seq(last_actual %m+% months(1), by = "month", length.out = h),
    debt_ttl = fc_total,
    debt_dom = fc_total * share_dom,
    debt_ext = fc_total * share_ext,
    source   = "forecast"
  )
  series <- bind_rows(monthly, future)
} else {
  series <- monthly
}

# ------------------------------------------------------------
# 5. GROWTH PER SECOND + CURRENT VALUE (with sanity check)
# ------------------------------------------------------------

row_for <- function(d) {
  r <- series %>% filter(date == d)
  if (nrow(r) != 1) stop("No value for ", format(d, "%b %Y"), " in the series.", call. = FALSE)
  r
}
cur <- row_for(this_month)
nxt <- row_for(next_month)

secs_in_month <- as.numeric(difftime(force_tz(as_datetime(next_month), TZ),
                                     force_tz(as_datetime(this_month), TZ), units = "secs"))
secs_elapsed  <- as.numeric(difftime(now_time, force_tz(as_datetime(this_month), TZ), units = "secs"))

# Growth in TOTAL debt per second: this month -> next month.
gps_arima_ttl <- (nxt$debt_ttl - cur$debt_ttl) / secs_in_month

# Sanity check against the last TREND_MONTHS of ACTUAL total debt.
recent    <- monthly %>% filter(source == "actual") %>% tail(TREND_MONTHS + 1)
span_sec  <- as.numeric(difftime(max(recent$date), min(recent$date), units = "secs"))
gps_trend_ttl <- (last(recent$debt_ttl) - first(recent$debt_ttl)) / span_sec

ratio     <- if (gps_trend_ttl != 0) gps_arima_ttl / gps_trend_ttl else NA_real_
plausible <- !is.na(ratio) && ratio >= GPS_RATIO_LIMITS[1] && ratio <= GPS_RATIO_LIMITS[2]

if (plausible) {
  gps_ttl <- gps_arima_ttl
  gps_method <- "arima"
} else {
  warning(sprintf(
    "ARIMA growth (KSh %s/s) is implausible vs the %d-month trend (KSh %s/s); using the trend.",
    format(round(gps_arima_ttl), big.mark = ","), TREND_MONTHS,
    format(round(gps_trend_ttl), big.mark = ",")), call. = FALSE)
  gps_ttl <- gps_trend_ttl
  gps_method <- "trend"
}

# Split total growth and the current total using the latest actual proportion.
gps <- c(debt_dom = gps_ttl * share_dom, debt_ext = gps_ttl * share_ext)
current_ttl <- cur$debt_ttl + gps_ttl * secs_elapsed
current <- c(debt_dom = current_ttl * share_dom, debt_ext = current_ttl * share_ext)

# ------------------------------------------------------------
# 6. BUILD UPLOAD TABLES
# ------------------------------------------------------------

stamp <- sub("(\\d{2})(\\d{2})$", "\\1:\\2", format(now_time, "%Y-%m-%dT%H:%M:%S%z"))  # +03:00

df_debt_upload <- series %>%
  filter(date <= next_month) %>%
  transmute(date = format(date, "%Y-%m-%d"), debt_dom, debt_ext, debt_ttl, source) %>%
  bind_rows(tibble(date = format(as_date(now_time), "%Y-%m-%d"),
                   debt_dom = current[["debt_dom"]], debt_ext = current[["debt_ext"]],
                   debt_ttl = current_ttl, source = "current")) %>%
  arrange(date)

df_debt_current_upload <- tibble(
  date     = stamp,
  debt_dom = current[["debt_dom"]],
  debt_ext = current[["debt_ext"]],
  debt_ttl = current_ttl
)

df_debt_growth_upload <- tibble(
  date    = stamp,
  gps_dom = gps[["debt_dom"]],
  gps_ext = gps[["debt_ext"]],
  gps_ttl = gps_ttl
)

# ------------------------------------------------------------
# SUPABASE HELPERS (every call is checked)
# ------------------------------------------------------------

sb_headers <- function(prefer = NULL) {
  h <- c(apikey = supabase_key, Authorization = paste("Bearer", supabase_key),
         `Content-Type` = "application/json")
  if (!is.null(prefer)) h <- c(h, Prefer = prefer)
  add_headers(.headers = h)
}

sb_check <- function(res, what) {
  if (http_error(res)) {
    body <- content(res, as = "text", encoding = "UTF-8")
    stop(what, " failed (HTTP ", status_code(res), "): ", substr(body, 1, 500), call. = FALSE)
  }
  invisible(res)
}

sb_insert <- function(table, df) {
  ids <- integer(0)
  for (i in seq(1, nrow(df), by = UPLOAD_BATCH)) {
    chunk <- df[i:min(i + UPLOAD_BATCH - 1, nrow(df)), ]
    res <- POST(paste0(supabase_url, "/rest/v1/", table), sb_headers("return=representation"),
                body = toJSON(chunk, dataframe = "rows", digits = NA, na = "null"))
    sb_check(res, paste("Insert into", table))
    out <- fromJSON(content(res, as = "text", encoding = "UTF-8"))
    if (is.data.frame(out) && "id" %in% names(out)) ids <- c(ids, out$id)
  }
  ids
}

sb_has_column <- function(table, column) {
  res <- GET(paste0(supabase_url, "/rest/v1/", table), sb_headers(),
             query = list(select = column, limit = 1))
  !http_error(res)
}

# ------------------------------------------------------------
# 7. UPLOAD
# ------------------------------------------------------------

if (DRY_RUN) {
  log_msg("DRY RUN - nothing uploaded.")
} else {
  if (!sb_has_column("df_debt_historical", "source")) {
    warning("df_debt_historical has no `source` column; uploading without it (see one-time SQL at top).",
            call. = FALSE)
    df_debt_upload <- select(df_debt_upload, -source)
  }

  # df_debt: insert the new series FIRST, then remove every older row. The
  # table is never empty, and old duplicates are cleaned up on the first run.
  #
  # IMPORTANT: `id` is a Supabase-generated UUID, not a sequential integer --
  # "id < min(new id)" is a lexicographic string comparison on a UUID and has
  # NO relationship to insertion order, so it silently deletes the wrong rows
  # (this is why df_debt accumulated 2500+ duplicate rows in production before
  # this fix). `created_at` is a real timestamp and is the only reliable way
  # to identify "every row from before this run".
  log_msg("Uploading ", nrow(df_debt_upload), " rows to df_debt_historical ...")
  run_started <- format(now(tzone = "UTC"), "%Y-%m-%dT%H:%M:%OS3Z")
  sb_insert("df_debt_historical", df_debt_upload)
  res <- DELETE(paste0(supabase_url, "/rest/v1/df_debt_historical"), sb_headers("return=minimal"),
                query = list(created_at = paste0("lt.", run_started)))
  sb_check(res, "Removing old df_debt_historical rows")

  log_msg("Adding current values to df_debt_current and df_debt_growth_per_sec ...")
  invisible(sb_insert("df_debt_current", df_debt_current_upload))
  invisible(sb_insert("df_debt_growth_per_sec", df_debt_growth_upload))
}

# ------------------------------------------------------------
# 8. SUMMARY
# ------------------------------------------------------------

ksh <- function(x) paste0("KSh ", format(round(x), big.mark = ",", scientific = FALSE))
cat("\n================ DEBT PIPELINE SUMMARY ================\n")
cat("CBK file          :", basename(URLdecode(CBK_URL)), "\n")
cat("Latest CBK month  :", format(last_actual, "%B %Y"), "\n")
cat("Forecast months   :", h, "\n")
cat("As at             :", format(now_time, "%d %b %Y %H:%M:%S %Z"), "\n")
cat("Total debt        :", ksh(current_ttl), "\n")
cat("  Domestic        :", ksh(current[["debt_dom"]]),
    sprintf("(%.1f%%)", 100 * current[["debt_dom"]] / current_ttl), "\n")
cat("  External        :", ksh(current[["debt_ext"]]),
    sprintf("(%.1f%%)", 100 * current[["debt_ext"]] / current_ttl), "\n")
cat("Growth per second :", ksh(gps_ttl), paste0("(", gps_method, "; ",
    TREND_MONTHS, "-month trend ", ksh(gps_trend_ttl), ")"), "\n")
cat("Rows in df_debt_historical:", nrow(df_debt_upload), "\n")
cat("Uploaded          :", if (DRY_RUN) "NO (dry run)" else "yes", "\n")
cat("========================================================\n")
