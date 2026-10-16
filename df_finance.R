# ============================================================
# KENYA NATIONAL DEBT COUNTER — REVENUE & EXPENDITURE PIPELINE (df_finance.R)
# ============================================================
#
# 1. Finds CBK's "Revenue and Expenditure" CSV on the Government Finance
#    Statistics page (the link changes with every upload)
# 2. Takes monthly total revenue and total expenditure (KSh million,
#    cumulative within each fiscal year), fills gaps, forecasts to the next
#    June (auto.arima), and smooths the forecast so each fiscal year ends on
#    its June total -- the same method as before
# 3. Works out growth per second from the last three fiscal year-ends and
#    projects month by month up to the current month
# 4. Replaces df_finance (date, expenditure, revenue, deficit; KSh) and
#    df_finance_metrics (date, exp, rev, gps_exp, gps_rev) in Supabase
#
# Run: Rscript df_finance.R          (DRY_RUN=true Rscript df_finance.R to only print)
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
notice("Revenue and expenditure file: ", URLdecode(url))

# The file has a 3-row header (lines 5-7); column names are built from all three.
tmp <- read.csv(download_cbk(url), header = FALSE, skip = 4, stringsAsFactors = FALSE)
colnames(tmp) <- paste(tmp[1, ], tmp[2, ], tmp[3, ], sep = "_")
tmp <- clean_names(tmp[-c(1, 2), ])
need <- c("year", "na_na_na", "total_expenditure", "total_revenue")
if (!all(need %in% names(tmp))) {
  fail("Revenue and expenditure file layout changed: missing column(s) ",
       paste(setdiff(need, names(tmp)), collapse = ", "), ". Columns now: ", paste(names(tmp), collapse = ", "))
}

df_cbk <- tmp %>%
  transmute(
    Date = suppressWarnings(make_date(as.integer(year), as.integer(na_na_na), 1)),
    Expenditure = suppressWarnings(as.numeric(gsub(",", "", total_expenditure))),
    Revenue = suppressWarnings(as.numeric(gsub(",", "", total_revenue)))
  ) %>%
  filter(!is.na(Date)) %>%
  distinct(Date, .keep_all = TRUE) %>%
  arrange(Date)

if (nrow(df_cbk) < 36) fail("Only ", nrow(df_cbk), " usable revenue/expenditure rows; refusing to update.")
latest_actual <- max(df_cbk$Date[!is.na(df_cbk$Revenue)])
check_fresh("Revenue and expenditure", latest_actual)

# --- Fill, forecast to next June and smooth one variable (unchanged method) ---
process_variable <- function(df, varname) {
  df_merged <- data.frame(Date = seq(min(df$Date), max(df$Date), by = "month")) %>%
    left_join(df, by = "Date") %>%
    arrange(Date) %>%
    mutate(var_imp = interp_linear(.data[[varname]]))

  ts_var <- ts(df_merged$var_imp, start = c(year(min(df_merged$Date)), month(min(df_merged$Date))), frequency = 12)
  arima_model <- auto.arima(ts_var)
  last_date <- max(df_merged$Date)
  next_june <- as.Date(paste0(year(last_date) + ifelse(month(last_date) >= 6, 1, 0), "-06-01"))
  months_to_june <- interval(last_date, next_june) %/% period(1, "month")

  df_final <- df_merged
  if (months_to_june > 0) {
    fc <- forecast(arima_model, h = months_to_june)$mean
    df_final <- bind_rows(df_merged, data.frame(
      Date = seq(last_date %m+% months(1), by = "month", length.out = months_to_june),
      var_imp = as.numeric(fc)
    ))
  }

  df_final <- df_final %>%
    select(Date, !!varname := var_imp) %>%
    mutate(Year = year(Date), Month = month(Date),
           FY = if_else(Month >= 7, paste0(Year, "/", Year + 1), paste0(Year - 1, "/", Year)))

  june_var <- df_final %>%
    filter(Month == 6) %>%
    select(FY, June_Var = !!varname) %>%
    mutate(FY_next = paste0(as.numeric(substr(FY, 1, 4)) + 1, "/", as.numeric(substr(FY, 6, 9)) + 1))

  df <- df_final %>%
    left_join(june_var %>% select(FY_next, June_Var), by = c("FY" = "FY_next")) %>%
    mutate(diff = if_else(Month == 6, .data[[varname]] - June_Var, NA_real_),
           diff = na.locf(diff, fromLast = TRUE, na.rm = FALSE))

  start_date <- min(df$Date)
  first_june <- as.Date(paste0(year(start_date) + ifelse(month(start_date) >= 6, 1, 0), "-06-01"))

  df %>%
    filter(Date >= first_june) %>%
    group_by(FY) %>%
    mutate(
      incr = .data[[varname]] - lag(.data[[varname]]),
      incr = if_else(is.na(incr), .data[[varname]], incr),
      incr = if_else(is.na(June_Var), NA_real_, incr),
      prop = incr / sum(incr, na.rm = TRUE),
      final = accumulate(.x = prop * diff, .f = function(prev, current) prev + current, .init = first(June_Var))[-1]
    ) %>%
    ungroup() %>%
    mutate(final = if_else(is.na(final), .data[[varname]], final)) %>%
    select(Date, !!paste0(varname, "_final") := final)
}

df_finance <- process_variable(df_cbk, "Revenue") %>%
  left_join(process_variable(df_cbk, "Expenditure"), by = "Date") %>%
  transmute(Date, Expenditure = Expenditure_final * 1e6, Revenue = Revenue_final * 1e6) %>%
  mutate(Deficit = Expenditure - Revenue)

# --- Growth per second over the last three fiscal year-ends ---
gps_finance <- df_finance %>%
  filter(Date > Sys.Date() %m-% years(3), month(Date) == 6) %>%
  arrange(Date) %>%
  summarize(start_date = first(Date), end_date = last(Date),
            exp_inc = last(Expenditure) - first(Expenditure),
            rev_inc = last(Revenue) - first(Revenue),
            n_seconds = as.numeric(difftime(end_date, start_date, units = "secs"))) %>%
  transmute(Expenditure = exp_inc / n_seconds, Revenue = rev_inc / n_seconds)
if (!is.finite(gps_finance$Revenue) || !is.finite(gps_finance$Expenditure)) {
  fail("Could not work out growth per second (need at least two June figures in the last three years).")
}

# --- Project month by month from the last row up to the current month ---
last_row <- df_finance %>% arrange(Date) %>% slice_tail(n = 1)
start_proj <- floor_date(last_row$Date %m+% months(1), "month")
end_proj <- floor_date(today(tzone = "UTC"), "month")
if (start_proj <= end_proj) {
  secs <- as.numeric(difftime(as.POSIXct(seq(start_proj, end_proj, by = "month"), tz = "UTC"),
                              as.POSIXct(last_row$Date, tz = "UTC"), units = "secs"))
  df_finance <- bind_rows(df_finance, tibble(
    Date = seq(start_proj, end_proj, by = "month"),
    Expenditure = last_row$Expenditure + secs * gps_finance$Expenditure,
    Revenue = last_row$Revenue + secs * gps_finance$Revenue
  ) %>% mutate(Deficit = Expenditure - Revenue))
}

df_finance <- df_finance %>%
  arrange(Date) %>%
  transmute(date = format(Date, "%Y-%m-%d"), expenditure = Expenditure, revenue = Revenue, deficit = Deficit)

df_finance_metrics <- data.frame(
  date = format(Sys.Date(), "%Y-%m-%d"),
  exp = tail(df_finance$expenditure, 1),
  rev = tail(df_finance$revenue, 1),
  gps_exp = gps_finance$Expenditure,
  gps_rev = gps_finance$Revenue
)

notice(sprintf("Revenue & expenditure: latest actual month %s; %d rows to %s; revenue now KSh %.2f bn, growing KSh %.0f/sec.",
               format(latest_actual, "%b %Y"), nrow(df_finance), tail(df_finance$date, 1),
               df_finance_metrics$rev / 1e9, df_finance_metrics$gps_rev))

sb_replace("df_finance", df_finance)
sb_replace("df_finance_metrics", df_finance_metrics)
