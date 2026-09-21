# ============================================================
# KENYA NATIONAL DEBT COUNTER
# DATA PROCESSING ENGINE
# ============================================================
#
# Purpose:
# Central data service responsible for:
#
# - Supabase Integration
# - Data Retrieval
# - Counter Initialization
# - Growth Calculations
# - Historical Data Preparation
# - Economic Simulations
# - AI Context Preparation
#
# Architecture:
#
# Supabase
#     ↓
# Data Loader
#     ↓
# Calculation Engine
#     ↓
# Route Layer
#     ↓
# Frontend
#
# ============================================================
library(dplyr)
library(tidyr)
library(lubridate)
library(httr)
library(jsonlite)
library(readr)
library(rvest)

# ============================================================
# ENVIRONMENT & SUPABASE CONFIGURATION
# ============================================================

readRenviron(".Renviron")

supabase_url      <- Sys.getenv("SUPABASE_URL")
supabase_api      <- Sys.getenv("SUPABASE_API")
anthropic_api_key <- Sys.getenv("ANTHROPIC_API_KEY")

if (supabase_url == "" || supabase_api == "") {
  warning("Supabase credentials are missing. Using mock data for testing.")
}

# ============================================================
# DATA ACCESS LAYER
# ============================================================
#
# Purpose:
# Provides secure access to Supabase datasets.
#
# Datasets:
# - Debt
# - Finance
# - GDP
# - Population
# - Forex
# - Interest Rates
#
# ============================================================

fetch_supabase_data <- function(table_name) {
  if (supabase_url == "" || supabase_api == "") {
    return(NULL)
  }

  url      <- paste0(supabase_url, "/rest/v1/", table_name, "?select=*")
  response <- GET(
    url = url,
    add_headers(
      apikey          = supabase_api,
      Authorization   = paste("Bearer", supabase_api),
      `Content-Type`  = "application/json"
    )
  )

  if (status_code(response) == 200) {
    data <- fromJSON(content(response, as = "text", encoding = "UTF-8"), flatten = TRUE)
    return(data)
  } else {
    warning("Failed to fetch ", table_name)
    return(NULL)
  }
}

# ============================================================
# LOAD ALL DATASETS
# ============================================================

cat("Loading data from Supabase...\n")

df_debt          <- fetch_supabase_data("df_debt")
df_debt_metrics  <- fetch_supabase_data("df_debt_metrics")
df_finance       <- fetch_supabase_data("df_finance")
df_finance_metrics <- fetch_supabase_data("df_finance_metrics")
df_wacd          <- fetch_supabase_data("df_wacd")
df_wacd_metrics  <- fetch_supabase_data("df_wacd_metrics")
df_gdp           <- fetch_supabase_data("df_gdp")
df_gdp_metrics   <- fetch_supabase_data("df_gdp_metrics")
df_forex         <- fetch_supabase_data("df_forex")
df_pop           <- fetch_supabase_data("df_pop")
df_pop_metrics   <- fetch_supabase_data("df_pop_metrics")

# ============================================================
# DEBT COUNTER INITIALIZATION
# ============================================================

if (!is.null(df_debt_metrics) && nrow(df_debt_metrics) > 0) {
  start_time_debt    <- as.POSIXct(df_debt_metrics$date[1], tz = "Africa/Nairobi")
  initial_debt_ttl   <- df_debt_metrics$debt_ttl[1]
  initial_debt_dom   <- df_debt_metrics$debt_dom[1]
  initial_debt_ext   <- df_debt_metrics$debt_ext[1]
  gps_ttl            <- df_debt_metrics$gps_ttl[1]
  gps_dom            <- df_debt_metrics$gps_dom[1]
  gps_ext            <- df_debt_metrics$gps_ext[1]
} else {
  # Mock data for testing
  start_time_debt  <- Sys.time() - days(30)
  initial_debt_ttl <- 12413783629093
  initial_debt_dom <- 6796199239963
  initial_debt_ext <- 5617584685863
  gps_ttl          <- 500000
  gps_dom          <- 300000
  gps_ext          <- 200000
}

# ============================================================
# EXPENDITURE COUNTER INITIALIZATION
# ============================================================

if (!is.null(df_finance_metrics) && nrow(df_finance_metrics) > 0) {
  start_time_finance   <- as.POSIXct(df_finance_metrics$date[1], tz = "Africa/Nairobi")
  initial_finance_exp  <- df_finance_metrics$exp[1]
  initial_finance_rev  <- df_finance_metrics$rev[1]
  gps_exp              <- df_finance_metrics$gps_exp[1]
  gps_rev              <- df_finance_metrics$gps_rev[1]
} else {
  start_time_finance  <- Sys.time() - days(30)
  initial_finance_exp <- 4650000000000
  initial_finance_rev <- 2960000000000
  gps_exp             <- 150000
  gps_rev             <- 90000
}

initial_finance_def <- initial_finance_exp - initial_finance_rev
gps_def             <- gps_exp - gps_rev

# ============================================================
# GDP COUNTER INITIALIZATION
# ============================================================

if (!is.null(df_gdp_metrics) && nrow(df_gdp_metrics) > 0) {
  start_time_gdp <- as.POSIXct(df_gdp_metrics$date[1], tz = "Africa/Nairobi")
  initial_gdp    <- df_gdp_metrics$gdp[1]
  gps_gdp        <- df_gdp_metrics$gps_gdp[1]
} else {
  start_time_gdp <- Sys.time() - days(30)
  initial_gdp    <- 15000000000000
  gps_gdp        <- 500000
}

# ============================================================
# POPULATION COUNTER INITIALIZATION
# ============================================================

if (!is.null(df_pop_metrics) && nrow(df_pop_metrics) > 0) {
  start_time_pop <- as.POSIXct(df_pop_metrics$date[1], tz = "Africa/Nairobi")
  initial_pop    <- df_pop_metrics$pop[1]
  gps_pop        <- df_pop_metrics$gps_pop[1]
} else {
  start_time_pop <- Sys.time() - days(30)
  initial_pop    <- 55000000
  gps_pop        <- 1.5
}

# ============================================================
# FOREX & INTEREST RATES
# ============================================================

forex_today <- tryCatch({
  forex_page   <- read_html("https://www.centralbank.go.ke/forex/")
  forex_tables <- html_table(forex_page)
  if (length(forex_tables) >= 7) {
    as.numeric(forex_tables[[7]][[3]][[1]])
  } else {
    128.50
  }
}, error = function(e) {
  warning("Could not fetch forex rate, using default")
  128.50
})

if (!is.null(df_wacd_metrics) && nrow(df_wacd_metrics) > 0) {
  int_rate_dom <- df_wacd_metrics$int_rate_dom[1]
  int_rate_ext <- df_wacd_metrics$int_rate_ext[1]
} else {
  int_rate_dom <- 12.5
  int_rate_ext <- 6.8
}

if (!is.null(df_wacd_metrics) && nrow(df_wacd_metrics) > 0) {
  gps_wacd_ttl <- (df_wacd_metrics$gps_wacd_dom[1] + df_wacd_metrics$gps_wacd_ext[1]) * 1e6
} else {
  gps_wacd_ttl <- 0
}

# ============================================================
# INDICATOR FUNCTIONS
# ============================================================

calculate_exchange_rate <- function() {
  ifelse(is.null(forex_today) || is.na(forex_today), 128.5, forex_today)
}

calculate_domestic_rate <- function() {
  ifelse(is.null(int_rate_dom) || is.na(int_rate_dom), 12.5, int_rate_dom)
}

calculate_external_rate <- function() {
  ifelse(is.null(int_rate_ext) || is.na(int_rate_ext), 6.8, int_rate_ext)
}

# ============================================================
# START TIMES FOR CALCULATIONS
# ============================================================

start_current_month <- floor_date(Sys.time() %>% with_tz("Africa/Nairobi"), "month")

# ============================================================
# REACTIVE CALCULATION FUNCTIONS
# ============================================================

seconds_elapsed <- function(start_time) {
  current_time <- Sys.time() %>% with_tz("Africa/Nairobi")
  as.numeric(difftime(current_time, start_time, units = "secs"))
}

calculate_total_debt <- function() {
  initial_debt_ttl + (gps_ttl * seconds_elapsed(start_time_debt))
}

calculate_domestic_debt <- function() {
  initial_debt_dom + (gps_dom * seconds_elapsed(start_time_debt))
}

calculate_external_debt <- function() {
  initial_debt_ext + (gps_ext * seconds_elapsed(start_time_debt))
}

calculate_expenditure <- function() {
  initial_finance_exp + (gps_exp * seconds_elapsed(start_time_finance))
}

calculate_revenue <- function() {
  initial_finance_rev + (gps_rev * seconds_elapsed(start_time_finance))
}

calculate_deficit <- function() {
  calculate_expenditure() - calculate_revenue()
}

calculate_gdp <- function() {
  initial_gdp + (gps_gdp * seconds_elapsed(start_time_gdp))
}

calculate_population <- function() {
  initial_pop + (gps_pop * seconds_elapsed(start_time_pop))
}

# ============================================================
# GROWTH MULTIPLIER
# ============================================================

get_growth_multiplier <- function(unit = "sec") {
  switch(unit,
    sec   = 1,
    min   = 60,
    hour  = 3600,
    day   = 86400,
    week  = 604800,
    month = 2629746,
    year  = 31556952,
    1
  )
}

calculate_growth <- function(unit = "sec") {
  mult <- get_growth_multiplier(unit)
  list(
    total       = gps_ttl * mult,
    domestic    = gps_dom * mult,
    external    = gps_ext * mult,
    expenditure = gps_exp * mult,
    revenue     = gps_rev * mult,
    deficit     = gps_def * mult,
    gdp         = gps_gdp * mult,
    population  = gps_pop * mult
  )
}

# ============================================================
# EXPENDITURE GROWTH FUNCTION
# ============================================================

calculate_expenditure_growth <- function(unit = "sec") {
  mult <- get_growth_multiplier(unit)
  list(
    expenditure = gps_exp * mult,
    revenue     = gps_rev * mult,
    deficit     = gps_def * mult,
    formatted   = list(
      expenditure = format_ksh(gps_exp * mult),
      revenue     = format_ksh(gps_rev * mult),
      deficit     = format_ksh(gps_def * mult)
    )
  )
}

# ============================================================
# INDICATORS GROWTH FUNCTION
# ============================================================

calculate_indicators_growth <- function(unit = "sec") {
  mult <- get_growth_multiplier(unit)
  list(
    gdp        = gps_gdp * mult,
    population = gps_pop * mult,
    formatted  = list(
      gdp        = format_ksh(gps_gdp * mult),
      population = format_population(gps_pop * mult)
    )
  )
}

# ============================================================
# HISTORICAL DATA FOR PLOTS
# ============================================================

get_debt_historical <- function() {
  if (is.null(df_debt)) return(NULL)
  df_debt %>%
    mutate(date = as.character(date)) %>%
    select(date, domestic = debt_dom, external = debt_ext, total = debt_ttl)
}

get_finance_historical <- function() {
  if (is.null(df_finance)) return(NULL)
  df_finance %>%
    mutate(date = as.character(date)) %>%
    select(date, expenditure, revenue, deficit)
}

get_gdp_historical <- function() {
  if (is.null(df_gdp)) return(NULL)
  df_gdp %>% mutate(date = as.character(date))
}

get_population_historical <- function() {
  if (is.null(df_pop)) return(NULL)
  df_pop %>% mutate(date = as.character(date))
}

get_forex_historical <- function() {
  if (is.null(df_forex)) return(NULL)
  df_forex %>% mutate(date = as.character(date))
}

# ============================================================
# SIMULATION FUNCTION
# ============================================================

run_simulation <- function(end_year, rev_growth, exp_growth, int_rate, primary_bal) {
  nyears <- end_year - 2025

  debt        <- initial_debt_ttl
  gdp         <- initial_gdp
  rev         <- initial_finance_rev
  exp         <- initial_finance_exp
  pop         <- initial_pop

  r_rev              <- rev_growth  / 100
  r_exp              <- exp_growth  / 100
  r_int              <- int_rate    / 100
  target_primary_pct <- primary_bal / 100

  years   <- 2026:end_year
  results <- list()

  for (i in 1:nyears) {
    gdp      <- gdp * 1.06
    rev      <- rev * (1 + r_rev)
    exp      <- exp * (1 + r_exp)
    interest <- debt * r_int
    desired_primary <- target_primary_pct * gdp
    fiscal_deficit  <- exp - rev
    new_borrowing   <- fiscal_deficit - desired_primary
    debt <- debt + new_borrowing
    pop  <- pop  * 1.022

    results[[i]] <- list(
      year        = years[i],
      debt        = debt / 1e12,
      debt_gdp    = (debt / gdp) * 100,
      int_rev     = (interest / rev) * 100,
      per_capita  = debt / pop,
      revenue     = rev / 1e12,
      expenditure = exp / 1e12,
      gdp         = gdp / 1e12,
      population  = pop / 1e6
    )
  }

  return(results)
}

# ============================================================
# AI FISCAL ASSISTANT - ANTHROPIC / CLAUDE
# ============================================================

FISCAL_SYSTEM_PROMPT <- "
You are an AI assistant specialising in Kenya's public finance, including:
- National debt and debt sustainability analysis
- Budget execution and county finances
- Auditor General reports and recommendations
- Revenue collection (KRA data)
- Economic indicators (inflation, GDP, etc.)
- Public Financial Management (PFM) Act compliance
- Contingent liabilities and loan guarantees

You do NOT provide legal or investment advice. Always respond in first person.

You have access to the full text of the Auditor-General's Popular Report
on the National Government for FY 2023/2024, which has been preloaded into
the system. Your data is current as of FY 2023/2024.

AUDIENCE:
Your users include policymakers, journalists, and informed citizens.
Use plain English and avoid excessive jargon unless the user appears technical.

WHEN ANSWERING QUESTIONS:
1. Prefer information found in the preloaded report.
2. Where possible, cite the specific page or section of the report.
3. If the answer is NOT in the report, say:
   'The Auditor-General\\'s Popular Report for 2023/2024 does not contain
   this information.'
4. If you are uncertain about something, say so explicitly.
5. If asked about future projections, clarify that estimates are based
   on historical trends only.
6. If asked a politically sensitive question, remain neutral and stick
   strictly to data.
7. If asked about data beyond FY 2023/2024, state that your information
   does not cover that period.
8. Do NOT fabricate information.

OUTPUT FORMAT:
- Use bullet points for lists
- Use tables for numerical comparisons
- Keep responses under 300 words unless the user asks for more detail
- Bold key figures and monetary amounts
- Always express monetary values in Kenya Shillings using the symbol KSh
  (e.g. KSh 1,200,000)
- Always separate large numbers with commas (e.g. 1,000,000 not 1000000)
- If a value is 100 or above, display no decimal places (e.g. KSh 4,500)
- If a value is below 100, display exactly 2 decimal places (e.g. KSh 45.67)
- Keep responses concise, factual, and tied to Kenya's fiscal context.
"

claude_chat <- function(question,
                        system_prompt = FISCAL_SYSTEM_PROMPT,
                        model         = "claude-opus-4-7",
                        max_tokens    = 1024) {

  if (is.null(anthropic_api_key) || anthropic_api_key == "") {
    return(list(
      success = FALSE,
      error   = "ANTHROPIC_API_KEY not configured. Please add it to .Renviron file."
    ))
  }

  url <- "https://api.anthropic.com/v1/messages"

  response <- POST(
    url = url,
    add_headers(
      "x-api-key"         = anthropic_api_key,
      "anthropic-version" = "2023-06-01",
      "Content-Type"      = "application/json"
    ),
    body = toJSON(list(
      model      = model,
      max_tokens = max_tokens,
      system     = system_prompt,
      messages   = list(list(role = "user", content = question))
    ), auto_unbox = TRUE)
  )

  if (status_code(response) == 200) {
    res_text <- content(response, as = "text", encoding = "UTF-8")
    parsed   <- fromJSON(res_text, simplifyVector = FALSE)
    text_out <- parsed$content[[1]]$text
    return(list(success = TRUE, response = text_out))
  } else {
    err <- content(response, as = "text", encoding = "UTF-8")
    return(list(success = FALSE, error = err))
  }
}

# Load OAG report text if available
oag_report_text <- ""
oag_file        <- "data/oag_report_2023_24.txt"
if (file.exists(oag_file)) {
  oag_report_text <- paste(readLines(oag_file, warn = FALSE), collapse = "\n")
  cat("Loaded OAG report text. Characters:", nchar(oag_report_text), "\n")
}

claude_chat_with_context <- function(question, include_report = TRUE) {
  if (include_report && nchar(oag_report_text) > 0) {
    report_excerpt    <- substr(oag_report_text, 1, 50000)
    enhanced_question <- paste0(
      "Based on the Auditor-General's Popular Report for FY 2023/2024:\n\n",
      "REPORT EXCERPT:\n", report_excerpt, "\n\n---\n\n",
      "USER QUESTION: ", question, "\n\n",
      "Please answer based on the report excerpt above. ",
      "If the information is not in the excerpt, state that clearly."
    )
    return(claude_chat(enhanced_question))
  } else {
    return(claude_chat(question))
  }
}

# ============================================================
# FORMATTING UTILITIES  (KSh throughout)
# ============================================================

format_ksh <- function(value) {
  v         <- round(value, 0)
  formatted <- format(v, big.mark = ",", scientific = FALSE, trim = TRUE)
  paste0("KSh ", formatted)
}

# Legacy alias kept so any existing frontend references still resolve
format_kes <- format_ksh

format_ksh_trillion <- function(value) {
  v <- value / 1e12
  paste0("KSh ", round(v, 2), " Trillion")
}

format_percent <- function(value) {
  paste0(round(value, 1), "%")
}

format_population <- function(value) {
  if (value < 1e6) {
    paste0(round(value / 1e3, 1), "K")
  } else {
    paste0(round(value / 1e6, 2), "M")
  }
}

# NULL coalescing
`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b

cat("Data loader initialised successfully.\n")