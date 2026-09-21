library(tidyverse)
library(lubridate)
library(imputeTS)
library(forecast)
library(rvest)

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


url <- 'https://www.centralbank.go.ke/uploads/exchange_rates/560562670_Monthly%20exchange%20rate%20(end%20period).csv'

# Load & clean
df_raw <- read.csv(url, skip = 1) %>%
  select(year = Year, month = Month, value = contains("United.States")) %>%
  drop_na() %>%
  mutate(date = as.Date(paste(year, month, "01", sep = "-")))

# Fill missing months
all_dates <- seq(min(df_raw$date), max(df_raw$date), by = "month")
df_full <- data.frame(date = all_dates)

df_actual <- df_full %>%
  left_join(df_raw, by = "date") %>%
  arrange(date) %>%
  mutate(value_filled = na_interpolation(value, option = "linear"),
         source = "Actual")

# Time series
ts_forex <- ts(df_actual$value_filled,
               start = c(year(min(df_actual$date)), month(min(df_actual$date))),
               frequency = 12)

# Fit ARIMA
model_arima <- auto.arima(ts_forex)

# Forecast to cover gap up to current month
last_data_month <- floor_date(max(df_actual$date), "month")
current_month   <- floor_date(Sys.Date(), "month")
months_gap      <- interval(last_data_month, current_month) %/% months(1)

if (months_gap > 0) {
  forecast_vals <- forecast(model_arima, h = months_gap)$mean
  df_forecast <- data.frame(
    date = seq(last_data_month %m+% months(1), current_month, by = "month"),
    value_filled = as.numeric(forecast_vals),
    source = "Forecast"
  )
  df_forex <- bind_rows(df_actual, df_forecast)
} else {
  df_forex <- df_actual
}
df_forex <- df_forex %>% select(date,value = value_filled,source)
# Scrape today's latest CBK rate
df_today <- read_html("https://www.centralbank.go.ke/") %>%
  html_table() %>% .[[10]] %>% select(3)

df_today <- data.frame(
  date  = Sys.Date(),
  value = as.numeric(df_today$`Key New CBK Indicative Exchange Rates`[1]),
  source = "Actual"
)


# Replace current month in df_forex with scraped value
df_forex <- df_forex %>% bind_rows(df_today)

# Replace entire table contents
# Step 1: Delete all existing records
httr::DELETE(
  url = paste0(supabase_url, "/rest/v1/df_forex?id=gte.0"),
  httr::add_headers(
    apikey = supabase_api,
    Authorization = paste("Bearer", supabase_api)
  )
)

# Step 2: Insert new data
httr::POST(
  url = paste0(supabase_url, "/rest/v1/df_forex"),
  httr::add_headers(
    apikey = supabase_api,
    Authorization = paste("Bearer", supabase_api),
    `Content-Type` = "application/json",
    Prefer = "return=representation"
  ),
  body = jsonlite::toJSON(df_forex, auto_unbox = TRUE, null = "null")
)

