# ============================================================
# Shared plumbing for the scheduled CBK indicator pipelines
# (df_forex.R, df_wacd.R, df_finance.R).
#
#   * credentials: .Renviron locally, repository secrets in GitHub Actions
#   * DRY_RUN: set the environment variable DRY_RUN=true to calculate and
#     print everything without writing to Supabase
#   * CBK links are looked up on the page every run, because CBK re-uploads
#     files under a new numeric prefix (1142265704_... -> 611925682_...) and
#     has written the same link both with "%20" and with literal spaces
#   * table writes back the table up first and restore it if the upload fails
#   * notice()/fail() also post GitHub Actions annotations, so a run's key
#     results can be read from the run page without opening the full log
# ============================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
})

if (file.exists(".Renviron")) readRenviron(".Renviron")

in_actions <- nzchar(Sys.getenv("GITHUB_ACTIONS"))
DRY_RUN <- tolower(Sys.getenv("DRY_RUN", "false")) %in% c("true", "1", "yes")

SUPABASE_URL <- sub("/+$", "", Sys.getenv("SUPABASE_URL"))
# SUPABASE_SERVICE_ROLE is what the workflows and df_debt.R use; SUPABASE_API
# is the name these scripts used before, still accepted for local runs.
SUPABASE_KEY <- Sys.getenv("SUPABASE_SERVICE_ROLE", Sys.getenv("SUPABASE_API"))

notice <- function(...) {
  msg <- paste0(...)
  if (in_actions) cat("::notice::", msg, "\n", sep = "") else message(msg)
}
warn <- function(...) {
  msg <- paste0(...)
  if (in_actions) cat("::warning::", msg, "\n", sep = "") else message("WARNING: ", msg)
}
fail <- function(...) {
  msg <- paste0(...)
  if (in_actions) cat("::error::", msg, "\n", sep = "")
  stop(msg, call. = FALSE)
}

if (!DRY_RUN && (!nzchar(SUPABASE_URL) || !nzchar(SUPABASE_KEY))) {
  fail("SUPABASE_URL and SUPABASE_SERVICE_ROLE must be set (or run with DRY_RUN=true).")
}

UA <- "Mozilla/5.0 (compatible; KenyaDebtCounterBot/1.0; +https://kenyadebtcounter.vercel.app)"

#' Find the current link to a CBK file on one of its statistics pages.
#' `file_regex` is matched against the decoded file name after the numeric
#' prefix, e.g. "Revenue and Expenditure\\.csv$".
find_cbk_link <- function(page, file_regex) {
  res <- tryCatch(GET(page, user_agent(UA), timeout(60)), error = function(e) fail("Could not open ", page, ": ", conditionMessage(e)))
  if (status_code(res) >= 400) fail("CBK page ", page, " answered HTTP ", status_code(res))
  html <- content(res, as = "text", encoding = "UTF-8")
  hrefs <- regmatches(html, gregexpr("href=[\"']([^\"']+)[\"']", html))[[1]]
  hrefs <- unique(gsub("^href=[\"']|[\"']$", "", hrefs))
  decoded <- vapply(hrefs, function(h) URLdecode(gsub(" ", "%20", h)), "")
  hit <- hrefs[grepl(paste0("/[0-9]+_", file_regex), decoded, perl = TRUE)]
  if (!length(hit)) fail("No link matching '", file_regex, "' on ", page, " (page layout may have changed)")
  url <- hit[1]
  if (!grepl("^https?://", url)) url <- paste0(CBK_BASE, if (startsWith(url, "/")) "" else "/", url)
  gsub(" ", "%20", url)
}

#' Download a URL to a temporary file and return its path.
download_cbk <- function(url) {
  tmp <- tempfile(fileext = ".csv")
  res <- tryCatch(GET(url, user_agent(UA), timeout(120), write_disk(tmp, overwrite = TRUE)),
                  error = function(e) fail("Could not download ", url, ": ", conditionMessage(e)))
  if (status_code(res) >= 400) fail("Download of ", url, " answered HTTP ", status_code(res))
  tmp
}

#' Column names in the style of janitor::clean_names(): lower snake_case,
#' leading/trailing underscores trimmed, duplicates suffixed _2, _3, ...
clean_names <- function(df) {
  n <- tolower(names(df))
  n <- gsub("[^a-z0-9]+", "_", n)
  n <- gsub("^_+|_+$", "", n)
  n[n == ""] <- "x"
  n <- ifelse(grepl("^[0-9]", n), paste0("x", n), n)
  seen <- list()
  for (i in seq_along(n)) {
    k <- n[i]
    cnt <- if (is.null(seen[[k]])) 0 else seen[[k]]
    seen[[k]] <- cnt + 1
    if (cnt > 0) n[i] <- paste0(k, "_", cnt + 1)
  }
  names(df) <- n
  df
}

#' Linear interpolation of interior gaps, carrying the ends flat
#' (what imputeTS::na_interpolation(option = "linear") does).
interp_linear <- function(x) zoo::na.approx(x, na.rm = FALSE, rule = 2)

sb_headers <- function(prefer = NULL) {
  h <- c(apikey = SUPABASE_KEY, Authorization = paste("Bearer", SUPABASE_KEY), `Content-Type` = "application/json")
  if (!is.null(prefer)) h <- c(h, Prefer = prefer)
  add_headers(.headers = h)
}

#' Read a whole table (or a filtered slice via `query`, e.g. "order=date.desc&limit=1").
sb_get <- function(table, query = "select=*") {
  res <- GET(paste0(SUPABASE_URL, "/rest/v1/", table, "?", query), sb_headers(), timeout(60))
  if (status_code(res) >= 300) fail("Reading ", table, " failed: HTTP ", status_code(res), " ", content(res, as = "text", encoding = "UTF-8"))
  fromJSON(content(res, as = "text", encoding = "UTF-8"), flatten = TRUE)
}

sb_post <- function(table, df) {
  POST(paste0(SUPABASE_URL, "/rest/v1/", table), sb_headers("return=minimal"),
       body = toJSON(df, auto_unbox = TRUE, null = "null", digits = NA, Date = "ISO8601"), timeout(120))
}

#' Replace the whole contents of a table with `df`, safely: the current rows
#' are read first, and if the new upload fails they are written back.
sb_replace <- function(table, df) {
  if (!nrow(df)) fail("Refusing to replace ", table, " with an empty table.")
  if (DRY_RUN) {
    # DUMP_DIR=some/folder also saves what would have been written, for checking.
    if (nzchar(Sys.getenv("DUMP_DIR"))) write.csv(df, file.path(Sys.getenv("DUMP_DIR"), paste0(table, ".csv")), row.names = FALSE)
    notice("DRY RUN: would replace ", table, " with ", nrow(df), " rows.")
    return(invisible(FALSE))
  }
  backup <- sb_get(table)
  del <- DELETE(paste0(SUPABASE_URL, "/rest/v1/", table, "?id=gte.0"), sb_headers("return=minimal"), timeout(60))
  if (status_code(del) >= 300) fail("Clearing ", table, " failed: HTTP ", status_code(del), " ", content(del, as = "text", encoding = "UTF-8"))
  res <- sb_post(table, df)
  if (status_code(res) >= 300) {
    msg <- content(res, as = "text", encoding = "UTF-8")
    restored <- if (is.data.frame(backup) && nrow(backup)) status_code(sb_post(table, backup)) < 300 else FALSE
    fail("Uploading ", table, " failed (HTTP ", status_code(res), ": ", msg, "); previous rows ",
         if (restored) "restored." else "COULD NOT BE RESTORED -- check the table.")
  }
  notice("Replaced ", table, ": ", nrow(df), " rows.")
  invisible(TRUE)
}

#' Warn when the latest actual figure is older than `max_months` months.
check_fresh <- function(label, latest_actual, max_months = 4) {
  age <- lubridate::interval(latest_actual, Sys.Date()) %/% lubridate::period(1, "month")
  if (age > max_months) {
    warn(label, ": latest actual figure is ", format(latest_actual, "%B %Y"), " (", age,
         " months old). CBK may not have published newer data yet.")
  }
}

# CBK_BASE overrides the site root, for testing against a local copy of the pages.
CBK_BASE     <- sub("/+$", "", Sys.getenv("CBK_BASE", "https://www.centralbank.go.ke"))
CBK_GFS_PAGE <- paste0(CBK_BASE, "/statistics/government-finance-statistics/")
CBK_FX_PAGE  <- paste0(CBK_BASE, "/statistics/exchange-rates/")
CBK_HOME     <- paste0(CBK_BASE, "/")
