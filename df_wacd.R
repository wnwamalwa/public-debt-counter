# Load credentials
readRenviron(".Renviron")

supabase_url <- Sys.getenv("SUPABASE_URL")
supabase_api <- Sys.getenv("SUPABASE_API")

fetch_supabase_data <- function(table_name) {
  url <- paste0(supabase_url, "/rest/v1/", table_name, "?select=*")
    response <- GET(url = url,
    add_headers(apikey = supabase_api,
      Authorization = paste("Bearer", supabase_api),
      `Content-Type` = "application/json" ))
  data <- fromJSON(content(response, as = "text", encoding = "UTF-8"), flatten = TRUE)
  return(data)}


df_debt_metrics    <- fetch_supabase_data("df_debt_metrics")

seconds_elapsed_debt <- reactive({
  req(input$current_page == "debt-status-counter")
  invalidateLater(1000, session)
  current_time <- as.POSIXct(format(Sys.time()), tz = "Africa/Nairobi")
  as.numeric(difftime(current_time, start_time_debt, units = "secs"))
})

start_time_debt    <- as.POSIXct(df_debt_metrics$date, tz = "Africa/Nairobi")
initial_debt_ttl   <- df_debt_metrics$debt_ttl[1]
initial_debt_dom   <- df_debt_metrics$debt_dom[1]
initial_debt_ext   <- df_debt_metrics$debt_ext[1]
gps_ttl            <- df_debt_metrics$gps_ttl[1]
gps_dom            <- df_debt_metrics$gps_dom[1]
gps_ext            <- df_debt_metrics$gps_ext[1]

total    = reactive({initial_debt_ttl + (gps_ttl * seconds_elapsed_debt())})
domestic = reactive({initial_debt_dom + (gps_dom * seconds_elapsed_debt())})
external = reactive({initial_debt_ext + (gps_ext * seconds_elapsed_debt())})


# Load and clean interest data
url <- "https://www.centralbank.go.ke/uploads/government_finance_statistics/1142265704_Revenue%20and%20Expenditure.csv"

df_raw <- read.csv(url, skip = 5) %>%
  clean_names() %>%
  select(year = x, month = x_1, int_dom = domestic_interest, int_ext = foreign_interest) %>%
  filter(!is.na(year)) %>%
  mutate(
    date = make_date(year, month, 1),
    int_dom = parse_number(int_dom),
    int_ext = parse_number(int_ext)
  ) %>%
  select(date, int_dom, int_ext) %>%
  arrange(date)

# Smoothing and forecasting function
smooth_var <- function(df, var) {
  full_dates <- seq(min(df$date), max(df$date), by = "month")
  df_full <- data.frame(date = full_dates)

  df_interp <- df_full %>%
    left_join(df, by = "date") %>%
    arrange(date) %>%
    mutate(val = na_interpolation(.data[[var]], option = "linear"))

  ts_data <- ts(df_interp$val, start = c(year(min(df_interp$date)), month(min(df_interp$date))), frequency = 12)
  model <- auto.arima(ts_data)

  last <- max(df_interp$date)
  next_june <- as.Date(paste0(year(last) + ifelse(month(last) >= 6, 1, 0), "-06-01"))
  months_ahead <- interval(last, next_june) %/% months(1)

  if (months_ahead > 0) {
    forecast_vals <- forecast(model, h = months_ahead)$mean
    future_dates <- seq(last %m+% months(1), by = "month", length.out = months_ahead)
    df_forecast <- data.frame(date = future_dates, val = as.numeric(forecast_vals))
    df_interp <- bind_rows(df_interp, df_forecast)
  }

  df_interp <- df_interp %>%
    mutate(
      fy = if_else(month(date) >= 7, paste0(year(date), "/", year(date) + 1),
                   paste0(year(date) - 1, "/", year(date)))
    )

  june_vals <- df_interp %>%
    filter(month(date) == 6) %>%
    select(fy, val) %>%
    rename(june = val) %>%
    mutate(fy_next = paste0(as.numeric(substr(fy, 1, 4)) + 1, "/", as.numeric(substr(fy, 6, 9)) + 1))

  df_final <- df_interp %>%
    left_join(june_vals, by = c("fy" = "fy_next")) %>%
    mutate(
      diff = if_else(month(date) == 6, val - june, NA_real_),
      diff = zoo::na.locf(diff, fromLast = TRUE, na.rm = FALSE)
    )

  next_june <- as.Date(paste0(year(min(df_final$date)) + ifelse(month(min(df_final$date)) >= 6, 1, 0), "-06-01"))

  df_final <- df_final %>%
    filter(date >= next_june) %>%
    group_by(fy) %>%
    mutate(
      inc = val - lag(val),
      inc = if_else(is.na(inc), val, inc),
      inc = if_else(is.na(june), NA_real_, inc),
      prop = inc / sum(inc, na.rm = TRUE),
      final = accumulate(prop * diff, ~ .x + .y, .init = first(june))[-1]
    ) %>%
    ungroup() %>%
    mutate(final = if_else(is.na(final), val, final)) %>%
    select(date, !!paste0(var, "_smooth") := final)

  return(df_final)
}

# Apply smoothing
df_dom <- smooth_var(df_raw, "int_dom")
df_ext <- smooth_var(df_raw, "int_ext")

# Final output
df_wacd <- df_dom %>%
  left_join(df_ext, by = "date")





# Load your data
df <- df_wacd

# Create time series
ts_data <- ts(df$int_dom_smooth, start = c(year(min(df$date)), month(min(df$date))), frequency = 12)

# Fit ARIMA model
model   <- auto.arima(ts_data)

# Forecast to current month + 1
last_date       <- max(df$date)
current_month   <- floor_date(Sys.Date(), "month")
next_month      <- current_month %m+% months(1)
months_ahead    <- interval(last_date, next_month) %/% months(1)

forecast_vals   <- forecast(model, h = months_ahead)$mean
forecast_dates  <- seq(last_date %m+% months(1), by = "month", length.out = months_ahead)

df_forecast_dom <- tibble(
  date           = forecast_dates,
  int_dom_smooth = as.numeric(forecast_vals),
  source         = "forecast")


# Create time series
ts_data <- ts(df$int_ext_smooth , start = c(year(min(df$date)), month(min(df$date))), frequency = 12)

# Fit ARIMA model
model <- auto.arima(ts_data)

# Forecast to current month + 1
last_date <- max(df$date)
current_month <- floor_date(Sys.Date(), "month")
next_month    <- current_month %m+% months(1)
months_ahead  <- interval(last_date, next_month) %/% months(1)

forecast_vals  <- forecast(model, h = months_ahead)$mean
forecast_dates <- seq(last_date %m+% months(1), by = "month", length.out = months_ahead)

df_forecast_ext <- tibble(
  date = forecast_dates,
  int_ext_smooth = as.numeric(forecast_vals),
  source = "forecast")

df <- df_wacd %>% mutate(source = "actual")

df_forecast <- inner_join(df_forecast_ext,df_forecast_dom) %>%
  select( date   ,    int_dom_smooth, int_ext_smooth, source)

df_forecast_final <- rbind(df,df_forecast)


# Estimate current value using fraction of days into current month
days_in_month <- days_in_month(current_month)
days_elapsed <- day(Sys.Date())
fraction <- days_elapsed / days_in_month

forecast_vals_dom <- tail(df_forecast_final,2)$int_dom_smooth
forecast_vals_ext <- tail(df_forecast_final,2)$int_ext_smooth

gps_wacd_dom <- (forecast_vals_dom[2] - forecast_vals_dom[1]) / forecast_vals_dom[1]
gps_wacd_ext <- (forecast_vals_ext[2] - forecast_vals_ext[1]) / forecast_vals_ext[1]

current_value_int_dom <- forecast_vals_dom[1] * (1 + gps_wacd_dom * fraction)
current_value_int_ext <- forecast_vals_ext[1] * (1 + gps_wacd_ext * fraction)

df_wacd_current <- tibble(
  date = Sys.Date(),
  int_dom_smooth = current_value_int_dom,
  int_ext_smooth = current_value_int_ext,
  source = "forecast")



# Final output
df_wacd <- bind_rows(df_forecast_final, df_wacd_current) %>%
  arrange(date) %>%
  select(date,int_dom = int_dom_smooth,int_ext = int_ext_smooth, source)




httr::POST(
  url = paste0(supabase_url, "/rest/v1/df_wacd"),
  httr::add_headers(
    apikey = supabase_api,
    Authorization = paste("Bearer", supabase_api),
    `Content-Type` = "application/json",
    Prefer = "return=representation,resolution=merge-duplicates"
  ),
  body = jsonlite::toJSON(df_wacd, auto_unbox = TRUE, null = "null")
)

df_wacd_metrics <- df_wacd_current %>%
  select(date,int_dom = int_dom_smooth,int_ext = int_ext_smooth) %>%
  mutate(int_ttl = int_dom + int_ext) %>%
  mutate(debt_dom = df_debt_metrics$debt_dom,
         debt_ext = df_debt_metrics$debt_ext,
         debt_ttl = df_debt_metrics$debt_ttl) %>%
  mutate(int_rate_dom  = (int_dom*10^6/debt_dom) * 100,
         int_rate_ext  = (int_ext*10^6/debt_ext) * 100,
         int_rate_ttl  = (int_ttl*10^6/debt_ttl) * 100) %>%
  mutate(gps_wacd_dom = gps_wacd_dom,
         gps_wacd_ext = gps_wacd_ext)


# Replace entire table contents
# Step 1: Delete all existing records
httr::DELETE(
  url = paste0(supabase_url, "/rest/v1/df_wacd_metrics?id=gte.0"),
  httr::add_headers(
    apikey = supabase_api,
    Authorization = paste("Bearer", supabase_api)
  )
)

# Step 2: Insert new data
httr::POST(
  url = paste0(supabase_url, "/rest/v1/df_wacd_metrics"),
  httr::add_headers(
    apikey = supabase_api,
    Authorization = paste("Bearer", supabase_api),
    `Content-Type` = "application/json",
    Prefer = "return=representation"
  ),
  body = jsonlite::toJSON(df_wacd_metrics, auto_unbox = TRUE, null = "null")
)

