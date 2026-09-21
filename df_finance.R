library(dplyr)
library(lubridate)
library(imputeTS)
library(forecast)
library(janitor)
library(purrr)
library(zoo)
library(httr)
library(dplyr)
library(lubridate)
library(janitor)

get_cbk_finance <- function(url,
                            local_file = "cbk_finance.csv",
                            meta_file  = "cbk_finance_meta.rds") {

  resp <- httr::HEAD(url)
  remote_time_header <- resp$headers[["last-modified"]]
  remote_size_header <- resp$headers[["content-length"]]

  # parse headers safely
  if (!is.null(remote_time_header) && nzchar(remote_time_header)) {
    # Use parse_http_date() instead of http_date()
    remote_time_parsed <- httr::parse_http_date(remote_time_header)
  } else {
    remote_time_parsed <- as.POSIXct(NA)  # NA but correct class
  }

  if (!is.null(remote_size_header) && nzchar(remote_size_header)) {
    remote_size_num <- as.numeric(remote_size_header)
  } else {
    remote_size_num <- NA_real_
  }

  meta <- list(time = as.POSIXct(NA), size = NA_real_)
  if (file.exists(meta_file)) meta <- readRDS(meta_file)

  need_download <- !file.exists(local_file) ||
    (!is.na(remote_time_parsed) && remote_time_parsed > meta$time) ||
    (!is.na(remote_size_num) && remote_size_num != meta$size)

  if (need_download) {
    download.file(url, local_file, mode = "wb")
    saveRDS(list(time = remote_time_parsed, size = remote_size_num), meta_file)
    message("✅ Downloaded new version from server.")
  } else {
    message("📂 Using cached version.")
  }

  # --- Read and clean CSV exactly like your code
  tmp <- read.csv(local_file, header = FALSE, skip = 4, stringsAsFactors = FALSE)
  colnames(tmp) <- paste(tmp[1, ], tmp[2, ], tmp[3, ], sep = "_")

  df_finance <- tmp[-c(1, 2), ] %>%
    clean_names() %>%
    select(Year = year, Month = na_na_na,
           Expenditure = total_expenditure, Revenue = total_revenue) %>%
    transmute(
      Date = make_date(as.integer(Year), as.integer(Month), 1),
      Expenditure = as.numeric(gsub(",", "", Expenditure)),
      Revenue = as.numeric(gsub(",", "", Revenue))
    ) %>%
    filter(!is.na(Date))

  return(df_finance)
}

cbk_url <- 'https://www.centralbank.go.ke/uploads/government_finance_statistics/1142265704_Revenue%20and%20Expenditure.csv'
df_finance <- get_cbk_finance(cbk_url)


# --- Function to process a variable (Revenue or Expenditure) ---
process_variable <- function(df, varname) {
  # Fill missing months and interpolate
  full_dates <- seq(min(df_finance$Date), max(df_finance$Date), by = "month")
  df_full <- data.frame(Date = full_dates)
  df_merged <- df_full %>%
    left_join(df, by = "Date") %>%
    arrange(Date) %>%
    mutate(var_imp = na_interpolation(.data[[varname]], option = "linear"))

  # Forecast to next June
  ts_var <- ts(df_merged$var_imp, start = c(year(min(df_merged$Date)), month(min(df_merged$Date))), frequency = 12)
  arima_model <- auto.arima(ts_var)
  last_date <- max(df_merged$Date)
  next_june <- as.Date(paste0(year(last_date) + ifelse(month(last_date) >= 6, 1, 0), "-06-01"))
  months_to_june <- interval(last_date, next_june) %/% months(1)

  if (months_to_june > 0) {
    forecast_values <- forecast(arima_model, h = months_to_june)$mean
    future_dates <- seq(last_date %m+% months(1), by = "month", length.out = months_to_june)
    forecast_df <- data.frame(Date = future_dates, var_imp = as.numeric(forecast_values))
    df_final <- bind_rows(df_merged, forecast_df)
  } else {
    df_final <- df_merged
  }

  df_final <- df_final %>%
    select(Date, !!varname := var_imp) %>%
    mutate(
      Year = year(Date),
      Month = month(Date),
      FY = if_else(Month >= 7, paste0(Year, "/", Year + 1), paste0(Year - 1, "/", Year))
    )

  # Compute June value per FY
  june_var <- df_final %>%
    filter(Month == 6) %>%
    select(FY, !!varname) %>%
    rename(June_Var = !!varname) %>%
    mutate(FY_next = paste0(as.numeric(substr(FY, 1, 4)) + 1, "/", as.numeric(substr(FY, 6, 9)) + 1))

  # Join June value and compute diff
  df <- df_final %>%
    left_join(june_var, by = c("FY" = "FY_next")) %>%
    mutate(
      diff = if_else(Month == 6, .data[[varname]] - June_Var, NA_real_),
      diff = zoo::na.locf(diff, fromLast = TRUE, na.rm = FALSE)
    )

  # Filter from next June onward
  start_date <- min(df$Date)
  next_june <- as.Date(paste0(year(start_date) + ifelse(month(start_date) >= 6, 1, 0), "-06-01"))

  df <- df %>%
    filter(Date >= next_june) %>%
    group_by(FY) %>%
    mutate(
      incr = .data[[varname]] - lag(.data[[varname]]),
      incr = if_else(is.na(incr), .data[[varname]], incr),
      incr = if_else(is.na(June_Var), NA_real_, incr),
      prop = incr / sum(incr, na.rm = TRUE),
      final = accumulate(
        .x = prop * diff,
        .f = function(prev, current) prev + current,
        .init = first(June_Var)
      )[-1]
    ) %>%
    ungroup() %>%
    mutate(final = if_else(is.na(final), .data[[varname]], final)) %>%
    select(Date, !!paste0(varname, "_final") := final)

  return(df)
}

# --- Apply to both Revenue and Expenditure ---
df_revenue <- process_variable(df_finance, "Revenue")
df_expenditure <- process_variable(df_finance, "Expenditure")

# --- Combine results ---
df_finance <- df_revenue %>%
  left_join(df_expenditure, by = "Date") %>%
  select(Date,Expenditure = Expenditure_final,Revenue = Revenue_final)  %>%
  mutate(Expenditure = Expenditure * 1e6,
         Revenue = Revenue * 1e6) %>%
  mutate(Deficit = Expenditure - Revenue)



gps_finance <- df_finance %>%
  filter(Date > Sys.Date() %m-% years(3)) %>%
  filter(month(Date) == 6) %>%
  arrange(Date) %>%
  summarize(
    start_date = first(Date),
    end_date   = last(Date),
    total_exp_increase = last(Expenditure) - first(Expenditure),
    total_rev_increase = last(Revenue) - first(Revenue),
    n_seconds = as.numeric(difftime(end_date, start_date, units = "secs"))
  ) %>%
  transmute(
    Expenditure = total_exp_increase / n_seconds,
    Revenue     = total_rev_increase / n_seconds
  )



library(tidyverse)
library(lubridate)

# inputs: your historical monthly df and per-second growth rates tibble
# df_finance  -> tibble with Date, Expenditure, Revenue, Deficit (monthly)
# gps_finance -> tibble 1x2 with columns Expenditure, Revenue (growth per second)

# example names (replace if different)
# df_finance <- your existing tibble
# gps_finance <- tibble(Expenditure = 9890.0, Revenue = 7815.0)

extend_monthly_projection <- function(df_finance, gps_finance, as_of = today(tzone = "UTC")) {
  # ensure sorted and get last observed row
  df_finance <- df_finance %>% arrange(Date)
  last_row <- df_finance %>% slice_tail(n = 1)
  last_date <- last_row$Date
  last_exp  <- last_row$Expenditure
  last_rev  <- last_row$Revenue

  # start projection from first day of next month after last_date
  start_proj <- (last_date %m+% months(1)) %>% floor_date(unit = "month")
  # final projection month is the first day of current month (or floor of as_of)
  end_proj <- as_of %>% floor_date(unit = "month")
  if (start_proj > end_proj) {
    # nothing to project
    return(df_finance)
  }

  # build target monthly dates (first of each month)
  proj_dates <- seq.Date(from = start_proj, to = end_proj, by = "month")

  # seconds between last observed timestamp and each projection date
  # treat Date as midnight UTC to compute seconds accurately
  last_posix <- as.POSIXct(last_date, tz = "UTC")
  proj_df <- tibble(
    Date = proj_dates
  ) %>%
    mutate(
      target_posix = as.POSIXct(Date, tz = "UTC"),
      seconds_since_last = as.numeric(difftime(target_posix, last_posix, units = "secs"))
    ) %>%
    # apply per-second growth to extend values
    mutate(
      Expenditure = last_exp + seconds_since_last * gps_finance$Expenditure[1],
      Revenue     = last_rev + seconds_since_last * gps_finance$Revenue[1],
      Deficit     = Expenditure - Revenue
    ) %>%
    select(Date, Expenditure, Revenue, Deficit)

  # combine historical + projections
  df_extended <- bind_rows(df_finance, proj_df) %>%
    arrange(Date)

  return(df_extended)
}


df_finance <- extend_monthly_projection(df_finance, gps_finance) %>%
  select(date = Date    , expenditure =     Expenditure , revenue =      Revenue  ,deficit =   Deficit)



df_finance_metrics <- tribble(
  ~date,        ~exp,                        ~rev,                        ~gps_exp,         ~gps_rev,
  Sys.Date(),   as.numeric(last(df_finance$Expenditure)), as.numeric(last(df_finance$Revenue)),
  as.numeric(gps_finance$Expenditure[1]), as.numeric(gps_finance$Revenue[1]))



# Load credentials
readRenviron(".Renviron")

supabase_url <- Sys.getenv("SUPABASE_URL")
supabase_api <- Sys.getenv("SUPABASE_API")

httr::POST(
  url = paste0(supabase_url, "/rest/v1/df_finance"),
  httr::add_headers(
    apikey = supabase_api,
    Authorization = paste("Bearer", supabase_api),
    `Content-Type` = "application/json",
    Prefer = "return=representation,resolution=merge-duplicates"
  ),
  body = jsonlite::toJSON(df_finance, auto_unbox = TRUE, null = "null")
)



httr::PATCH(
  url = paste0(supabase_url, "/rest/v1/df_finance_metrics?date=eq.2025-11-01"),
  httr::add_headers(
    apikey = supabase_api,
    Authorization = paste("Bearer", supabase_api),
    `Content-Type` = "application/json",
    Prefer = "return=representation"
  ),
  body = jsonlite::toJSON(df_finance_metrics, auto_unbox = TRUE, null = "null")
)

