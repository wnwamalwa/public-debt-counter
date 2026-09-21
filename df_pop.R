# ============================================================
# KENYA NATIONAL DEBT COUNTER — POPULATION PIPELINE (df_pop.R)
# ============================================================
#
# What this script does
#   1. Reads the "population" tab of the IEA Kenya Google Sheet
#      (https://docs.google.com/spreadsheets/d/11Y_EoYqFJOTTubbBCQkh1gV3kbX1cVQHapdzbwWUXK4/)
#      -- date / value / source (actual | interpolated | forecast) columns,
#      already monthly and already run right up through "today" (a weekly
#      scheduled task keeps that sheet's "actual" anchors current from KNBS
#      and rebuilds the interpolated/forecast rows every run).
#   2. Validates it (columns present, monthly, not stale).
#   3. Works out growth per second for this month and the value right now,
#      using the same compound monthly rate already embedded in the sheet's
#      own forecast tail (see step 4 below) -- no separate spline/ARIMA model
#      here, because the sheet is now the single source of truth for the
#      growth curve, not just the anchors.
#   4. Uploads to Supabase:
#        df_pop            full monthly series (actual / interpolated / forecast)
#        df_pop_metrics    one new row: date (timestamp), pop, gps_pop
#   5. Prints a summary
#
# The website (kenyadebtcounter.vercel.app / api.kenyadebtcounter.or.ke)
# reads the LATEST df_pop_metrics row and ticks the population counter
# forward from it: pop + gps_pop × seconds since `date`.
# /api/indicators/population/historical reads df_pop directly for the chart.
#
# How to run
#   In Positron/RStudio: open this file and click Source, or
#   in a terminal:       Rscript df_pop.R
#   Set DRY_RUN <- TRUE below to calculate and print without uploading.
#
# Credentials (.Renviron next to this script)
#   SUPABASE_URL           https://<project>.supabase.co
#   SUPABASE_SERVICE_ROLE  service_role key (needed to write once RLS is on)
#   Never commit .Renviron or share the service_role key.
#
# Google Sheets credentials (same file the Quarto report uses)
#   gsheets.json            service-account JSON, next to this script (or in
#                            a .secrets/ folder). Created from the same
#                            GSHEET_SERVICE_ACCOUNT value used by the
#                            quarterly-macro-debt-report repo's CI. Never
#                            commit this file either.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(lubridate)
  library(httr)
  library(jsonlite)
  library(googlesheets4)
})

# ------------------------------------------------------------
# SETTINGS
# ------------------------------------------------------------

DRY_RUN <- TRUE   # first run: TRUE (print only). Flip to FALSE once the dry-run output looks right.

SHEET_URL  <- "https://docs.google.com/spreadsheets/d/11Y_EoYqFJOTTubbBCQkh1gV3kbX1cVQHapdzbwWUXK4"
SHEET_TAB  <- "population"
TZ         <- "Africa/Nairobi"

MAX_TODAY_ROW_AGE_DAYS <- 10  # the sheet's last row should be ~today; older means it's stale
UPLOAD_BATCH           <- 500

log_msg <- function(...) cat(format(Sys.time(), "[%H:%M:%S] "), ..., "\n", sep = "")

# ------------------------------------------------------------
# 1. CREDENTIALS
# ------------------------------------------------------------

script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
  if (length(file_arg)) return(dirname(normalizePath(file_arg)))
  for (i in rev(seq_len(sys.nframe()))) {                  # source("df_pop.R")
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

SCRIPT_DIR <- script_dir()

renv_path <- file.path(SCRIPT_DIR, ".Renviron")
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
# 1b. PRE-FLIGHT SUPABASE CREDENTIAL CHECK (same check as df_debt.R)
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
# 1c. GOOGLE SHEETS AUTHENTICATION
#     Same pattern as quarterly_macro_debt_report_ieakenya.qmd and df_gdp.R:
#     look for a service-account JSON at gsheets.json (project root) or in
#     .secrets/, the same file CI creates from the GSHEET_SERVICE_ACCOUNT
#     secret. This script WRITES to Supabase from whatever it reads, so a
#     missing credential is a hard stop rather than a silent fallback.
# ------------------------------------------------------------
local_secret_files <- if (dir.exists(file.path(SCRIPT_DIR, ".secrets"))) {
  list.files(file.path(SCRIPT_DIR, ".secrets"), pattern = "\\.json$", full.names = TRUE)
} else {
  character(0)
}
credential_candidates <- c(file.path(SCRIPT_DIR, "gsheets.json"), local_secret_files)
credential_candidates <- credential_candidates[file.exists(credential_candidates)]

if (length(credential_candidates) > 0) {
  gs4_auth(path = credential_candidates[1])
} else if (interactive()) {
  gs4_auth()
} else {
  stop(
    "No Google Sheets service-account credentials found (looked for 'gsheets.json' ",
    "next to this script and '.secrets/*.json'). Place the same service-account ",
    "JSON used for GSHEET_SERVICE_ACCOUNT in the quarterly-macro-debt-report repo ",
    "at ", file.path(SCRIPT_DIR, "gsheets.json"), " (never commit it), or run ",
    "interactively to authenticate with gs4_auth().",
    call. = FALSE
  )
}

# ------------------------------------------------------------
# 2. READ + VALIDATE THE SHEET
# ------------------------------------------------------------

log_msg("Reading '", SHEET_TAB, "' tab from the Google Sheet ...")
# Restricted to A:C explicitly -- the tab's used range extends to column E
# (a spacer column D plus the hidden raw-data-blob column E that the sheet's
# own ARRAYFORMULA spills from), so letting read_sheet infer the range from
# sheet_properties returns 5 columns and col_types="cdc" (3 types) errors out.
raw <- tryCatch(
  read_sheet(ss = SHEET_URL, sheet = SHEET_TAB, range = paste0(SHEET_TAB, "!A:C"), col_types = "cdc"),
  error = function(e) stop(
    "\n\nFailed to read the '", SHEET_TAB, "' tab from Google Sheets.\n",
    "This is almost always one of:\n",
    "  1. Missing/invalid credentials -> place a service-account JSON at\n",
    "     'gsheets.json' next to this script.\n",
    "  2. The service account lacks Viewer access to the sheet -> share\n",
    "     the sheet with the client_email in that JSON.\n",
    "  3. No network access from this machine/runner right now.\n\n",
    "Sheet: ", SHEET_URL, "\n",
    "Original error: ", conditionMessage(e), "\n",
    call. = FALSE
  )
)

required_cols <- c("date", "value", "source")
missing_cols <- setdiff(required_cols, names(raw))
if (length(missing_cols)) {
  stop("'", SHEET_TAB, "' tab is missing column(s): ", paste(missing_cols, collapse = ", "),
       ". Found: ", paste(names(raw), collapse = ", "), call. = FALSE)
}

series <- raw %>%
  transmute(
    date   = as_date(date),
    value  = as.numeric(value),
    source = as.character(source)
  ) %>%
  filter(!is.na(date), !is.na(value), nzchar(source)) %>%
  distinct(date, .keep_all = TRUE) %>%
  arrange(date)

if (nrow(series) < 24) stop("'", SHEET_TAB, "' series is too short (", nrow(series), " rows) -- refusing to upload.", call. = FALSE)
if (!"actual" %in% series$source) stop("'", SHEET_TAB, "' has no rows labelled 'actual' -- refusing to upload.", call. = FALSE)

now_time   <- now(tzone = TZ)
last_date  <- max(series$date)
data_age_days <- as.numeric(difftime(as_date(now_time), last_date, units = "days"))
log_msg("Sheet's last row: ", format(last_date, "%Y-%m-%d"), " (", round(data_age_days, 1), " day(s) ago)")
if (data_age_days > MAX_TODAY_ROW_AGE_DAYS) {
  stop("The sheet's last row is ", round(data_age_days, 1), " days old (expected roughly 'today'). ",
       "The weekly KNBS watch/rebuild may not be running -- check it before uploading stale data.",
       call. = FALSE)
}

# ------------------------------------------------------------
# 3. GROWTH PER SECOND + CURRENT VALUE
#    The sheet already carries the monthly compound growth rate implied by
#    its own forecast tail (every consecutive pair of monthly rows in that
#    tail shares the same rate by construction -- see the scheduled task
#    that rebuilds this sheet). Re-derive that same rate from the last two
#    first-of-month rows rather than re-fetching/re-modelling anything, so
#    the counter's live growth matches exactly what the chart shows.
# ------------------------------------------------------------

start_month <- as_date(floor_date(now_time, "month"))

monthly <- series %>% filter(day(date) == 1) %>% arrange(date)
this_month_row <- monthly %>% filter(date == start_month)
if (nrow(this_month_row) != 1) {
  stop("No monthly row for the first of the current month (", format(start_month, "%Y-%m-%d"),
       ") in '", SHEET_TAB, "'. The sheet's forecast tail may not have been rebuilt yet this month.",
       call. = FALSE)
}
prev_month_row <- monthly %>% filter(date == start_month %m-% months(1))
if (nrow(prev_month_row) != 1) {
  stop("No monthly row for the month before the current one in '", SHEET_TAB, "' -- cannot derive a growth rate.",
       call. = FALSE)
}

r_monthly <- (this_month_row$value / prev_month_row$value) - 1
next_month_value <- this_month_row$value * (1 + r_monthly)

seconds_in_month <- as.numeric(difftime(force_tz(as_datetime(start_month %m+% months(1)), TZ),
                                        force_tz(as_datetime(start_month), TZ), units = "secs"))
seconds_elapsed   <- as.numeric(difftime(now_time, force_tz(as_datetime(start_month), TZ), units = "secs"))

gps_pop     <- (next_month_value - this_month_row$value) / seconds_in_month
current_pop <- this_month_row$value + gps_pop * seconds_elapsed

# ------------------------------------------------------------
# 4. BUILD UPLOAD TABLES
# ------------------------------------------------------------

stamp <- sub("(\\d{2})(\\d{2})$", "\\1:\\2", format(now_time, "%Y-%m-%dT%H:%M:%S%z"))  # +03:00

df_pop_upload <- series %>%
  transmute(date = format(date, "%Y-%m-%d"), value, source)

df_pop_metrics_upload <- tibble(
  date    = stamp,
  pop     = current_pop,
  gps_pop = gps_pop
)

# ------------------------------------------------------------
# SUPABASE HELPERS (same as df_debt.R)
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

# df_pop has a UNIQUE constraint on `date` (unlike df_debt_historical, which
# has no such constraint and can hold duplicate dates briefly -- see
# df_debt.R). A blind INSERT here 409s on every date already in the table, so
# every row is upserted (INSERT ... ON CONFLICT (date) DO UPDATE) instead.
# Each batch is one statement/transaction, so a conflict inside a batch would
# still be atomic -- but with upsert there is no conflict to begin with.
sb_upsert <- function(table, df, conflict_col) {
  for (i in seq(1, nrow(df), by = UPLOAD_BATCH)) {
    chunk <- df[i:min(i + UPLOAD_BATCH - 1, nrow(df)), ]
    res <- POST(paste0(supabase_url, "/rest/v1/", table),
                sb_headers("resolution=merge-duplicates,return=minimal"),
                query = list(on_conflict = conflict_col),
                body = toJSON(chunk, dataframe = "rows", digits = NA, na = "null"))
    sb_check(res, paste("Upsert into", table))
  }
}

# All existing values of one column, paginated past Supabase's 1000-row cap.
sb_get_column <- function(table, column) {
  out <- character(0)
  offset <- 0
  repeat {
    res <- GET(paste0(supabase_url, "/rest/v1/", table), sb_headers(),
               query = list(select = column, limit = 1000, offset = offset))
    sb_check(res, paste("Reading", table))
    page <- fromJSON(content(res, as = "text", encoding = "UTF-8"))
    page_vals <- if (is.data.frame(page) && nrow(page) > 0) as.character(page[[column]]) else character(0)
    out <- c(out, page_vals)
    if (length(page_vals) < 1000) break
    offset <- offset + 1000
  }
  out
}

# ------------------------------------------------------------
# 5. UPLOAD
# ------------------------------------------------------------

if (DRY_RUN) {
  log_msg("DRY RUN - nothing uploaded.")
} else {
  log_msg("Upserting ", nrow(df_pop_upload), " rows into df_pop (by date) ...")
  sb_upsert("df_pop", df_pop_upload, conflict_col = "date")

  # Clean up stale rows: every date in df_pop that ISN'T in this run's series
  # (chiefly a *previous* day's one-off "today" forecast row -- each run adds
  # exactly one non-first-of-month date, so yesterday's leftover would
  # otherwise accumulate forever since no future run's date matches it again).
  existing_dates <- sb_get_column("df_pop", "date")
  stale_dates <- setdiff(existing_dates, df_pop_upload$date)
  if (length(stale_dates) > 0) {
    log_msg("Removing ", length(stale_dates), " stale row(s) from df_pop ...")
    for (i in seq(1, length(stale_dates), by = 200)) {
      chunk <- stale_dates[i:min(i + 199, length(stale_dates))]
      res <- DELETE(paste0(supabase_url, "/rest/v1/df_pop"), sb_headers("return=minimal"),
                    query = list(date = paste0("in.(", paste(chunk, collapse = ","), ")")))
      sb_check(res, "Removing stale df_pop rows")
    }
  }

  log_msg("Adding current value to df_pop_metrics ...")
  invisible(sb_insert("df_pop_metrics", df_pop_metrics_upload))
}

# ------------------------------------------------------------
# 6. SUMMARY
# ------------------------------------------------------------

fmt_pop <- function(x) format(round(x), big.mark = ",", scientific = FALSE)
cat("\n============== POPULATION PIPELINE SUMMARY ==============\n")
cat("Sheet tab           :", SHEET_TAB, "\n")
cat("Rows read           :", nrow(series), "\n")
cat("Sheet's last row    :", format(last_date, "%Y-%m-%d"), "\n")
cat("Latest actual anchor:", format(max(series$date[series$source == "actual"]), "%Y-%m-%d"),
    fmt_pop(series$value[series$date == max(series$date[series$source == "actual"])]), "\n")
cat("As at               :", format(now_time, "%d %b %Y %H:%M:%S %Z"), "\n")
cat("Current population  :", fmt_pop(current_pop), "\n")
cat("Growth per second   :", round(gps_pop, 4), "\n")
cat("Rows in df_pop      :", nrow(df_pop_upload), "\n")
cat("Uploaded            :", if (DRY_RUN) "NO (dry run)" else "yes", "\n")
cat("===========================================================\n")
