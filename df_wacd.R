# ============================================================
# KENYA NATIONAL DEBT COUNTER — INTEREST PAYMENTS PIPELINE (df_wacd.R)
# ============================================================
#
# 1. Finds CBK's "Revenue and Expenditure" CSV on the Government Finance
#    Statistics page (the link changes with every upload)
# 2. Takes monthly domestic and foreign interest paid (KSh million,
#    cumulative within each fiscal year), fills gaps, forecasts to the next
#    June and smooths so each fiscal year ends on its June total, then
#    forecasts one month past the current month (auto.arima) -- the same
#    method as before
# 3. Estimates today's value and the interest rate implied by the latest
#    debt stock in df_debt_current (int_rate = interest / debt x 100)
# 4. Replaces df_wacd (date, int_dom, int_for, source) and df_wacd_metrics
#
# Run: Rscript df_wacd.R             (DRY_RUN=true Rscript df_wacd.R to only print)
# Scheduled: .github/workflows/cbk-indicators.yml, Mondays 08:12 Nairobi.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
  library(forecast)
  library(purrr)
  library(zoo)
})
source("pipeline_helpers.R")

url <- find_cbk_link(CBK_GFS_PAGE, "Revenue and Expenditure\\.csv$")
notice("Revenue and expenditure file (interest): ", URLdecode(url))

raw <- clean_names(read.csv(download_cbk(url), skip = 5, stringsAsFactors = FALSE))
need <- c("x", "x_1", "domestic_interest", "foreign_interest")
if (!all(need %in% names(raw))) {
  fail("Revenue and expenditure file layout changed: missing column(s) ",
       paste(setdiff(need, names(raw)), collapse = ", "), ". Columns now: ", paste(names(raw), collapse = ", "))
}

to_num <- function(x) suppressWarnings(as.numeric(gsub("[^0-9.-]", "", as.character(x))))
df_raw <- raw %>%
  transmute(year = suppressWarnings(as.integer(x)), month = suppressWarnings(as.integer(x_1)),
            int_dom = to_num(domestic_interest), int_ext = to_num(foreign_interest)) %>%
  filter(!is.na(year), !is.na(month), month %in% 1:12) %>%
  mutate(date = make_date(year, month, 1)) %>%
  distinct(date, .keep_all = TRUE) %>%
  select(date, int_dom, int_ext) %>%
  arrange(date)

if (nrow(df_raw) < 36) fail("Only ", nrow(df_raw), " usable interest rows; refusing to update.")
latest_actual <- max(df_raw$date[!is.na(df_raw$int_dom)])
check_fresh("Interest payments", latest_actual)

# --- Fill, forecast to next June and smooth one variable (unchanged method) ---
smooth_var <- function(df, var) {
  df_interp <- data.frame(date = seq(min(df$date), max(df$date), by = "month")) %>%
    left_join(df, by = "date") %>%
    arrange(date) %>%
    mutate(val = interp_linear(.data[[var]]))

  ts_data <- ts(df_interp$val, start = c(year(min(df_interp$date)), month(min(df_interp$date))), frequency = 12)
  model <- auto.arima(ts_data)
  last <- max(df_interp$date)
  next_june <- as.Date(paste0(year(last) + ifelse(month(last) >= 6, 1, 0), "-06-01"))
  months_ahead <- interval(last, next_june) %/% period(1, "month")
  if (months_ahead > 0) {
    fc <- forecast(model, h = months_ahead)$mean
    df_interp <- bind_rows(df_interp, data.frame(
      date = seq(last %m+% months(1), by = "month", length.out = months_ahead), val = as.numeric(fc)))
  }

  df_interp <- df_interp %>%
    mutate(fy = if_else(month(date) >= 7, paste0(year(date), "/", year(date) + 1), paste0(year(date) - 1, "/", year(date))))

  june_vals <- df_interp %>%
    filter(month(date) == 6) %>%
    transmute(fy_next = paste0(as.numeric(substr(fy, 1, 4)) + 1, "/", as.numeric(substr(fy, 6, 9)) + 1), june = val)

  df_final <- df_interp %>%
    left_join(june_vals, by = c("fy" = "fy_next")) %>%
    mutate(diff = if_else(month(date) == 6, val - june, NA_real_),
           diff = na.locf(diff, fromLast = TRUE, na.rm = FALSE))

  first_june <- as.Date(paste0(year(min(df_final$date)) + ifelse(month(min(df_final$date)) >= 6, 1, 0), "-06-01"))

  df_final %>%
    filter(date >= first_june) %>%
    group_by(fy) %>%
    mutate(inc = val - lag(val),
           inc = if_else(is.na(inc), val, inc),
           inc = if_else(is.na(june), NA_real_, inc),
           prop = inc / sum(inc, na.rm = TRUE),
           final = accumulate(prop * diff, ~ .x + .y, .init = first(june))[-1]) %>%
    ungroup() %>%
    mutate(final = if_else(is.na(final), val, final)) %>%
    select(date, !!paste0(var, "_smooth") := final)
}

df_smooth <- smooth_var(df_raw, "int_dom") %>%
  left_join(smooth_var(df_raw, "int_ext"), by = "date") %>%
  # Months after the latest CBK figure come from the forecast-to-June step.
  mutate(source = if_else(date > latest_actual, "forecast", "actual"))

# --- Forecast each series one month past the current month ---
current_month <- floor_date(Sys.Date(), "month")
next_month <- current_month %m+% months(1)
last_date <- max(df_smooth$date)
months_ahead <- interval(last_date, next_month) %/% period(1, "month")

forecast_series <- function(x) {
  ts_x <- ts(x, start = c(year(min(df_smooth$date)), month(min(df_smooth$date))), frequency = 12)
  as.numeric(forecast(auto.arima(ts_x), h = months_ahead)$mean)
}
df_all <- df_smooth
if (months_ahead > 0) {
  df_all <- bind_rows(df_smooth, tibble(
    date = seq(last_date %m+% months(1), by = "month", length.out = months_ahead),
    int_dom_smooth = forecast_series(df_smooth$int_dom_smooth),
    int_ext_smooth = forecast_series(df_smooth$int_ext_smooth),
    source = "forecast"
  ))
}

# --- Today's value: interpolate between this month and next ---
this_and_next <- df_all %>% filter(date %in% c(current_month, next_month)) %>% arrange(date)
if (nrow(this_and_next) < 2) fail("Could not find this month and next month in the interest series.")
gps_wacd_dom <- (this_and_next$int_dom_smooth[2] - this_and_next$int_dom_smooth[1]) / this_and_next$int_dom_smooth[1]
gps_wacd_ext <- (this_and_next$int_ext_smooth[2] - this_and_next$int_ext_smooth[1]) / this_and_next$int_ext_smooth[1]
fraction <- day(Sys.Date()) / days_in_month(current_month)
int_dom_now <- this_and_next$int_dom_smooth[1] * (1 + gps_wacd_dom * fraction)
int_ext_now <- this_and_next$int_ext_smooth[1] * (1 + gps_wacd_ext * fraction)

df_wacd <- bind_rows(df_all, tibble(date = Sys.Date(), int_dom_smooth = int_dom_now, int_ext_smooth = int_ext_now, source = "forecast")) %>%
  arrange(date) %>%
  distinct(date, .keep_all = TRUE) %>%
  transmute(date = format(date, "%Y-%m-%d"), int_dom = int_dom_smooth, int_for = int_ext_smooth, source)

# --- Implied interest rate against the latest debt stock ---
debt <- if (nzchar(SUPABASE_KEY)) sb_get("df_debt_current", "select=*&order=date.desc&limit=1") else NULL
if (is.data.frame(debt) && nrow(debt)) {
  df_wacd_metrics <- data.frame(
    date = format(Sys.Date(), "%Y-%m-%d"),
    int_dom = int_dom_now, int_ext = int_ext_now, int_ttl = int_dom_now + int_ext_now,
    debt_dom = debt$debt_dom[1], debt_ext = debt$debt_ext[1], debt_ttl = debt$debt_ttl[1]
  ) %>%
    mutate(int_rate_dom = int_dom * 1e6 / debt_dom * 100,
           int_rate_ext = int_ext * 1e6 / debt_ext * 100,
           int_rate_ttl = int_ttl * 1e6 / debt_ttl * 100,
           gps_wacd_dom = gps_wacd_dom, gps_wacd_ext = gps_wacd_ext)
  notice(sprintf("Interest: latest actual month %s; %d rows; implied rate domestic %.2f%%, external %.2f%%.",
                 format(latest_actual, "%b %Y"), nrow(df_wacd), df_wacd_metrics$int_rate_dom, df_wacd_metrics$int_rate_ext))
} else {
  df_wacd_metrics <- NULL
  warn("No debt stock available (no Supabase key or empty df_debt_current); df_wacd_metrics not updated.")
  notice(sprintf("Interest: latest actual month %s; %d rows.", format(latest_actual, "%b %Y"), nrow(df_wacd)))
}

sb_replace("df_wacd", df_wacd)
if (!is.null(df_wacd_metrics)) sb_replace("df_wacd_metrics", df_wacd_metrics)
