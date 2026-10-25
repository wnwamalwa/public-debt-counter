# ============================================================
# KENYA NATIONAL DEBT COUNTER — EXCHANGE RATE PIPELINE (df_forex.R)
# ============================================================
#
# 1. Finds CBK's "Monthly exchange rate (end period)" CSV on the Exchange
#    Rates statistics page (the link changes with every upload)
# 2. Takes the KSh per US dollar series, fills any missing months
#    (linear interpolation), and forecasts (auto.arima) up to this month
# 3. Adds today's CBK indicative rate from the CBK home page when it can be
#    read (optional: skipped with a warning if the page layout changes)
# 4. Replaces df_forex in Supabase (date, value, source = Actual/Forecast)
#
# Run: Rscript df_forex.R            (DRY_RUN=true Rscript df_forex.R to only print)
# Scheduled: .github/workflows/cbk-indicators.yml, Mondays 08:12 Nairobi.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
  library(forecast)
  library(rvest)
})
source("pipeline_helpers.R")

url <- find_cbk_link(CBK_FX_PAGE, "Monthly exchange rate \\(end period\\)\\.csv$")
notice("Exchange rate file: ", URLdecode(url))
raw <- read.csv(download_cbk(url), skip = 1, check.names = TRUE, stringsAsFactors = FALSE)

usd_col <- grep("United.States", names(raw), value = TRUE)[1]
if (is.na(usd_col) || !all(c("Year", "Month") %in% names(raw))) {
  fail("Exchange rate file layout changed: expected Year, Month and a 'United States dollar' column; got ",
       paste(head(names(raw), 6), collapse = ", "))
}

df_raw <- raw %>%
  transmute(year = suppressWarnings(as.integer(Year)),
            month = suppressWarnings(as.integer(Month)),
            value = suppressWarnings(as.numeric(gsub(",", "", .data[[usd_col]])))) %>%
  filter(!is.na(year), !is.na(month), month %in% 1:12, !is.na(value)) %>%
  mutate(date = make_date(year, month, 1)) %>%
  distinct(date, .keep_all = TRUE) %>%
  arrange(date)

if (nrow(df_raw) < 24) fail("Only ", nrow(df_raw), " usable exchange rate rows; refusing to update.")
if (any(df_raw$value < 20 | df_raw$value > 500)) fail("Implausible KSh/USD values in the CBK file; refusing to update.")
latest_actual <- max(df_raw$date)
check_fresh("Exchange rate", latest_actual)

# Fill missing months
df_actual <- data.frame(date = seq(min(df_raw$date), latest_actual, by = "month")) %>%
  left_join(df_raw %>% select(date, value), by = "date") %>%
  mutate(value = interp_linear(value), source = "Actual")

# Forecast the gap up to the current month
current_month <- floor_date(Sys.Date(), "month")
months_gap <- interval(latest_actual, current_month) %/% period(1, "month")
df_forex <- df_actual
if (months_gap > 0) {
  ts_fx <- ts(df_actual$value, start = c(year(min(df_actual$date)), month(min(df_actual$date))), frequency = 12)
  fc <- forecast(auto.arima(ts_fx), h = months_gap)$mean
  df_forex <- bind_rows(df_forex, data.frame(
    date = seq(latest_actual %m+% months(1), current_month, by = "month"),
    value = as.numeric(fc),
    source = "Forecast"
  ))
}

# Latest daily indicative rate from the CBK home page (best effort).
# The home page shows a small "Daily KES Exchange Rates" table:
#   US DOLLAR | 129.89 ... Posted On: 23-10-2026
# The rate is stored on its "Posted On" date (CBK does not post at weekends).
today_rate <- tryCatch({
  page <- read_html(GET(CBK_HOME, user_agent(UA), timeout(60)))
  tbls <- html_elements(page, "table")
  tbls <- tbls[grepl("US\\s*DOLLAR", html_text2(tbls), ignore.case = TRUE)]
  if (!length(tbls)) stop("no exchange rate table")
  rows <- html_elements(tbls[[1]], "tr")
  txt  <- html_text2(rows)
  usd  <- rows[grepl("US\\s*DOLLAR", txt, ignore.case = TRUE)]
  if (!length(usd)) stop("no US DOLLAR row")
  cells <- html_text2(html_elements(usd[[1]], "td"))
  v <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", cells)))
  v <- v[!is.na(v) & v > 20 & v < 500][1]
  if (is.na(v)) stop("no plausible rate")
  posted <- grep("Posted On", txt, value = TRUE, ignore.case = TRUE)[1]
  d <- if (is.na(posted)) NA else suppressWarnings(dmy(sub("(?i).*posted on:?\\s*", "", posted, perl = TRUE)))
  if (is.na(d) || d > Sys.Date() || d < Sys.Date() - 10) d <- Sys.Date()
  list(value = v, date = d)
}, error = function(e) NULL)
if (is.null(today_rate)) {
  warn("Could not read the daily CBK indicative rate from the home page; using the monthly series only.")
} else {
  df_forex <- bind_rows(df_forex, data.frame(date = today_rate$date, value = today_rate$value, source = "Actual"))
}

df_forex <- df_forex %>%
  arrange(date, source != "Actual") %>%   # an actual rate wins over a forecast on the same date
  distinct(date, .keep_all = TRUE) %>%
  mutate(date = format(date, "%Y-%m-%d"), value = round(value, 4)) %>%
  select(date, value, source)

notice(sprintf("Exchange rate: latest actual month %s at KSh %.2f/USD; %d forecast month(s); today's rate %s; %d rows.",
               format(latest_actual, "%b %Y"), tail(df_actual$value, 1), max(months_gap, 0),
               if (is.null(today_rate)) "not read" else sprintf("%.2f (posted %s)", today_rate$value, format(today_rate$date, "%d %b %Y")), nrow(df_forex)))

sb_replace("df_forex", df_forex)
