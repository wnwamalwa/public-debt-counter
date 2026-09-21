library(tidyverse)

df <- read.csv("data/gdp_g.csv") %>% 
    mutate(date = case_when(
             Q == 1 ~ paste0(year, "-03-01"),
             Q == 2 ~ paste0(year, "-06-01"),
             Q == 3 ~ paste0(year, "-09-01"),
             Q == 4 ~ paste0(year, "-12-01")
           )) %>% ymd()

  # --- Forecast setup ---
  last_date <- max(df$date)

  # Use last quarter as reference
  last_year <- year(last_date)
  last_q    <- case_when(
    month(last_date) == 3  ~ 1,
    month(last_date) == 6  ~ 2,
    month(last_date) == 9  ~ 3,
    TRUE ~ 4
  )

  # Build quarterly time series
  ts_gdp_g <- ts(df$value,
                 start = c(year(min(df$date)), 1),
                 frequency = 4)

  # Fit exponential smoothing model
  model_gdp_g <- ets(ts_gdp_g)

  # How many quarters ahead? (forecast until next quarter after Sys.Date)
  quarters_ahead <- interval(last_date, Sys.Date() + months(3)) %/% months(3)
  quarters_ahead <- max(1, quarters_ahead)  # at least 1

  # Forecast
  forecast_vals <- forecast(model_gdp_g, h = quarters_ahead)$mean %>% as.numeric()

  # --- Build forecast tibble ---
  future_quarters <- tibble(
    year = last_year + ((last_q + seq_len(quarters_ahead) - 1) %/% 4),
    Q    = ((last_q + seq_len(quarters_ahead) - 1) %% 4) + 1,
    value = forecast_vals
  ) %>%
    mutate(date = case_when(
      Q == 1 ~ ymd(paste0(year, "-03-01")),
      Q == 2 ~ ymd(paste0(year, "-06-01")),
      Q == 3 ~ ymd(paste0(year, "-09-01")),
      Q == 4 ~ ymd(paste0(year, "-12-01"))
    ),
    source = "forecast")

  # --- Merge with original data ---
  df <- df %>%
    mutate(source = "actual") %>%
    bind_rows(future_quarters) %>%
    arrange(date) %>%
    select(date, value,source)

  t

  full_dates <- tibble(date = seq(min(df$date), max(df$date), by = "month"))
  df_forecast <- full_dates %>%
    left_join(df %>% select(date, value), by = "date") %>%
    mutate(source = ifelse(is.na(value),"interpolated","actual")) %>%
    mutate(value = na_interpolation(value, option = "spline"))

  now_time      <- now()
  start_month   <- floor_date(now_time, "month")
  seconds_mtd   <- as.numeric(difftime(now_time, start_month, units = "secs"))
  seconds_total <- as.numeric(difftime(start_month %m+% months(1), start_month, units = "secs"))

  last_two <- df_forecast %>% filter(date == start_month | date ==  start_month %m+% months(1))

  gps_gdp_g <- (last_two$value[2] - last_two$value[1]) / seconds_total
  current_vals_gdp_g <- last_two$value[1] + gps_gdp_g * seconds_mtd

  df_current <- tibble(
    date = Sys.Date(),
    value = current_vals_gdp_g,
    source = "forecast")
  df_gdp_g <- bind_rows(df_forecast, df_current) %>%
    arrange(date) %>%
    filter(date <= start_month %m+% months(1))
