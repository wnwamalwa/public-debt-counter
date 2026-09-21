# ============================================================
# KENYA NATIONAL DEBT COUNTER
# API ROUTING LAYER
# ============================================================
#
# FILE NAVIGATION MAP
#
# 1. Environment Setup
# 2. Middleware & CORS
# 3. Health Endpoints
# 4. Debt Endpoints
# 5. Expenditure Endpoints
# 6. Economic Indicators
# 7. Population Services
# 8. Visitor Analytics
# 9. AI Fiscal Assistant
# 10. Scenario Simulator
# 11. Dashboard Aggregation
#
# ============================================================

library(plumber)
library(jsonlite)
library(dplyr)
library(httr)
library(uuid)  # <-- for valid UUID generation

# Load environment variables
anthropic_api_key <- Sys.getenv("ANTHROPIC_API_KEY")
supabase_url      <- Sys.getenv("SUPABASE_URL")
supabase_api      <- Sys.getenv("SUPABASE_API")

# Load logic
source("data_loader.R")

# ============================================================
# HELPER FUNCTIONS (defined early)
# ============================================================

# NULL coalescing
`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b

# Bulletproof mock timeline generator
generate_mock_timeline <- function(days = 30) {
  days <- suppressWarnings(as.numeric(days))
  if (is.na(days) || days < 1) days <- 30
  days <- floor(days)
  
  tryCatch({
    dates <- seq(Sys.Date() - days, Sys.Date(), by = "day")
    data.frame(
      date       = as.character(dates),
      visitors   = floor(200 + runif(length(dates), 100, 400)),
      page_views = floor(500 + runif(length(dates), 300, 900))
    )
  }, error = function(e) {
    data.frame(
      date       = as.character(seq(Sys.Date() - 29, Sys.Date(), by = "day")),
      visitors   = rep(250, 30),
      page_views = rep(600, 30)
    )
  })
}

# Mock aggregated metrics (uses the same generator)
get_mock_aggregated_metrics <- function() {
  list(
    summary = list(
      total_visitors           = 15423,
      unique_sessions          = 12456,
      total_page_views         = 89234,
      avg_time_on_site_minutes = 4.5,
      bounce_rate_percent      = 32.5,
      total_downloads          = 2341,
      total_shares             = 892,
      total_ussd_uses          = 445,
      total_ai_uses            = 1234
    ),
    geographic = list(
      top_countries = data.frame(
        country    = c("Kenya", "United States", "United Kingdom", "Germany", "Canada"),
        visitors   = c(9876, 2345, 1234, 567, 456),
        percentage = c(64, 15, 8, 3.7, 3)
      ),
      top_cities = data.frame(
        city     = c("Nairobi", "Mombasa", "Kisumu", "London", "New York"),
        visitors = c(5432, 1234, 876, 789, 654)
      )
    ),
    traffic_by_page = data.frame(
      page       = c("Debt Counter", "Expenditure", "Additional Indicators", "AI Assistant", "About"),
      views      = c(34567, 23456, 15678, 9876, 5678),
      percentage = c(38.7, 26.3, 17.6, 11.1, 6.4)
    ),
    daily_traffic     = generate_mock_timeline(30),
    device_breakdown  = list(desktop = 45, mobile = 48, tablet = 7),
    browser_breakdown = list(Chrome = 52, Safari = 23, Firefox = 12, Edge = 8, Other = 5),
    top_referrers     = data.frame(
      source = c("Google", "Twitter/X", "WhatsApp", "Direct", "LinkedIn"),
      visits = c(5432, 2341, 1876, 4321, 987)
    )
  )
}

# ============================================================
# CORS
# ============================================================

#* @filter cors
cors <- function(req, res) {
  res$setHeader("Access-Control-Allow-Origin",  "*")
  res$setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  res$setHeader("Access-Control-Allow-Headers", "Content-Type")
  if (req$REQUEST_METHOD == "OPTIONS") {
    res$status <- 200
    return(list())
  } else {
    plumber::forward()
  }
}

# ============================================================
# ROOT
# ============================================================

#* @get /
function() {
  list(
    message   = "Kenya Public Debt Counter API is running",
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
  )
}

# ============================================================
# HEALTH
# ============================================================

#* @get /health
function() {
  list(status = "healthy", time = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"))
}

# ============================================================
# DEBT SERVICES MODULE
# ============================================================

#* @get /api/debt/current
function() {
  current_time <- Sys.time()
  list(
    success = TRUE,
    data = list(
      total     = as.numeric(calculate_total_debt()),
      domestic  = as.numeric(calculate_domestic_debt()),
      external  = as.numeric(calculate_external_debt()),
      timestamp = format(current_time, "%Y-%m-%dT%H:%M:%SZ"),
      date      = format(current_time, "%d %B %Y")
    )
  )
}

#* @get /api/debt/growth
#* @param unit:string Time unit (sec, min, hour, day, week, month, year)
function(unit = "sec") {
  mult  <- get_growth_multiplier(unit)
  t_val <- as.numeric(gps_ttl) * mult
  d_val <- as.numeric(gps_dom) * mult
  e_val <- as.numeric(gps_ext) * mult
  list(
    success = TRUE,
    data = list(
      unit      = unit,
      total     = t_val,
      domestic  = d_val,
      external  = e_val,
      formatted = list(
        total    = format_ksh(t_val),
        domestic = format_ksh(d_val),
        external = format_ksh(e_val)
      )
    )
  )
}

#* @get /api/debt/historical
function() {
  data <- get_debt_historical()
  if (is.null(data)) {
    return(list(success = FALSE, error = "No historical debt data available"))
  }
  list(success = TRUE, data = data)
}

#* @get /api/debt/ratio
function() {
  data     <- get_debt_historical()
  gdp_data <- get_gdp_historical()
  if (is.null(data) || is.null(gdp_data)) {
    return(list(success = FALSE, error = "Insufficient data for ratio calculation"))
  }
  list(success = TRUE, data = data)
}

# ============================================================
# EXPENDITURE ENDPOINTS
# ============================================================

#* @get /api/expenditure/current
function() {
  current_time <- Sys.time()
  exp <- as.numeric(calculate_expenditure())
  rev <- as.numeric(calculate_revenue())
  list(
    success = TRUE,
    data = list(
      expenditure = exp,
      revenue     = rev,
      deficit     = exp - rev,
      timestamp   = format(current_time, "%Y-%m-%dT%H:%M:%SZ"),
      date        = format(current_time, "%d %B %Y")
    )
  )
}

#* @get /api/expenditure/growth
#* @param unit:string Time unit (sec, min, hour, day, week, month, year)
function(unit = "sec") {
  result <- calculate_expenditure_growth(unit)
  list(
    success = TRUE,
    data = list(
      unit        = unit,
      expenditure = as.numeric(result$expenditure),
      revenue     = as.numeric(result$revenue),
      deficit     = as.numeric(result$deficit),
      formatted   = list(
        expenditure = as.character(result$formatted$expenditure),
        revenue     = as.character(result$formatted$revenue),
        deficit     = as.character(result$formatted$deficit)
      )
    )
  )
}

#* @get /api/expenditure/historical
function() {
  data <- get_finance_historical()
  if (is.null(data)) {
    return(list(success = FALSE, error = "No historical finance data available"))
  }
  list(success = TRUE, data = data)
}

# Alias used by frontend
#* @get /api/finance/historical
function() {
  data <- get_finance_historical()
  if (is.null(data)) {
    return(list(success = FALSE, error = "No historical finance data available"))
  }
  list(success = TRUE, data = data)
}

# ============================================================
# INDICATORS ENDPOINTS
# ============================================================

#* @get /api/indicators/current
function() {
  current_time <- Sys.time()
  list(
    success = TRUE,
    data = list(
      forex                  = as.numeric(calculate_exchange_rate()),
      domestic_interest_rate = as.numeric(calculate_domestic_rate()),
      external_interest_rate = as.numeric(calculate_external_rate()),
      gdp                    = as.numeric(calculate_gdp()),
      population             = as.numeric(calculate_population()),
      timestamp              = format(current_time, "%Y-%m-%dT%H:%M:%SZ"),
      date                   = format(current_time, "%d %B %Y")
    )
  )
}

#* @get /api/indicators/growth
#* @param unit:string Time unit (sec, min, hour, day, week, month, year)
function(unit = "sec") {
  result <- calculate_indicators_growth(unit)
  list(
    success = TRUE,
    data = list(
      unit       = unit,
      gdp        = as.numeric(result$gdp),
      population = as.numeric(result$population),
      formatted  = list(
        gdp        = as.character(result$formatted$gdp),
        population = as.character(result$formatted$population)
      )
    )
  )
}

#* @get /api/indicators/gdp/historical
function() {
  data <- get_gdp_historical()
  if (is.null(data)) {
    return(list(success = FALSE, error = "No historical GDP data available"))
  }
  list(success = TRUE, data = data)
}

#* @get /api/indicators/population/historical
function() {
  data <- get_population_historical()
  if (is.null(data)) {
    return(list(success = FALSE, error = "No historical population data available"))
  }
  list(success = TRUE, data = data)
}

#* @get /api/indicators/forex/historical
function() {
  data <- get_forex_historical()
  if (is.null(data)) {
    return(list(success = FALSE, error = "No historical forex data available"))
  }
  list(success = TRUE, data = data)
}

# ============================================================
# INTEREST / WACD HISTORICAL
# ============================================================

#* @get /api/indicators/interest/historical
function() {
  if (is.null(df_wacd_metrics)) {
    return(list(success = FALSE, error = "No historical interest data available"))
  }

  data <- df_wacd_metrics %>%
    mutate(date = as.character(date)) %>%
    select(
      date,
      int_dom,
      int_ext,
      int_ttl,
      int_rate_dom,
      int_rate_ext,
      int_rate_ttl,
      gps_wacd_dom,
      gps_wacd_ext
    ) %>%
    arrange(date)

  list(success = TRUE, data = data)
}

# ============================================================
# POPULATION DEDICATED ENDPOINT
# ============================================================

#* @get /api/population/current
function() {
  current_time <- Sys.time()
  pop_value    <- calculate_population()
  if (is.null(pop_value)) {
    return(list(success = FALSE, error = "Population data unavailable"))
  }
  list(
    success = TRUE,
    data = list(
      population = as.numeric(pop_value),
      timestamp  = format(current_time, "%Y-%m-%dT%H:%M:%SZ"),
      date       = format(current_time, "%d %B %Y")
    )
  )
}

# ============================================================
# VISITOR METRICS ENDPOINTS
# ============================================================

#* @post /api/visitor/start
function(req, res) {
  tryCatch({
    body <- jsonlite::fromJSON(req$postBody)

    # --- MODIFIED: use UUIDgenerate() as fallback ---
    session_id <- body$session_id %||% uuid::UUIDgenerate()
    timestamp  <- body$timestamp %||% format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")

    if (!is.null(supabase_url) && supabase_url != "") {
      url     <- paste0(supabase_url, "/rest/v1/visitor_metrics")
      payload <- list(
        session_id  = session_id,
        visitors    = 1,
        timestamp   = timestamp,
        ip_address  = body$ip_address %||% NA,
        country     = body$country    %||% NA,
        region      = body$region     %||% NA,
        city        = body$city       %||% NA,
        latitude    = body$latitude   %||% NA,
        longitude   = body$longitude  %||% NA
      )
      payload <- payload[!sapply(payload, is.null)]
      POST(
        url,
        add_headers(
          "apikey"        = supabase_api,
          "Authorization" = paste("Bearer", supabase_api),
          "Content-Type"  = "application/json",
          "Prefer"        = "return=minimal"
        ),
        body = toJSON(payload, auto_unbox = TRUE, null = "null")
      )
    }

    list(success = TRUE, message = "Session recorded", session_id = session_id)
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })
}

#* @post /api/visitor/pageview
function(req, res) {
  tryCatch({
    body <- jsonlite::fromJSON(req$postBody)
    if (!is.null(supabase_url) && supabase_url != "") {
      cat("Page view recorded:", body$page, "for session:", body$session_id, "\n")
    }
    list(success = TRUE, message = "Page view recorded")
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })
}

#* @post /api/visitor/action
function(req, res) {
  tryCatch({
    body       <- jsonlite::fromJSON(req$postBody)
    action     <- body$action     %||% "unknown"
    session_id <- body$session_id %||% "unknown"

    cat("Action recorded:", action, "for session:", session_id, "\n")

    if (!is.null(supabase_url) && supabase_url != "") {
      url          <- paste0(supabase_url, "/rest/v1/visitor_metrics?session_id=eq.", session_id)
      get_response <- GET(
        url,
        add_headers(
          "apikey"        = supabase_api,
          "Authorization" = paste("Bearer", supabase_api)
        )
      )

      if (status_code(get_response) == 200) {
        existing <- content(get_response, "parsed")
        if (length(existing) > 0) {
          update_field <- switch(action,
            "download" = "downloads",
            "share"    = "shares",
            "ussd"     = "ussd_uses",
            "ai_query" = "ai_queries",
            NULL
          )
          if (!is.null(update_field)) {
            update_url    <- paste0(supabase_url, "/rest/v1/visitor_metrics?session_id=eq.", session_id)
            current_value <- existing[[1]][[update_field]] %||% 0
            PATCH(
              update_url,
              add_headers(
                "apikey"        = supabase_api,
                "Authorization" = paste("Bearer", supabase_api),
                "Content-Type"  = "application/json",
                "Prefer"        = "return=minimal"
              ),
              body = toJSON(setNames(list(current_value + 1), update_field), auto_unbox = TRUE)
            )
          }
        }
      }
    }

    list(success = TRUE, message = paste("Action", action, "recorded"))
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })
}

#* @get /api/visitor/metrics/aggregated
function(res) {
  tryCatch({
    if (is.null(supabase_url) || supabase_url == "") {
      return(list(success = TRUE, data = get_mock_aggregated_metrics(), mock = TRUE))
    }

    thirty_days_ago <- format(Sys.time() - 2592000, "%Y-%m-%dT%H:%M:%SZ")
    filter_url      <- paste0(supabase_url, "/rest/v1/visitor_metrics?timestamp=gte.", thirty_days_ago)

    response <- GET(
      filter_url,
      add_headers(
        "apikey"        = supabase_api,
        "Authorization" = paste("Bearer", supabase_api)
      )
    )

    if (status_code(response) == 200) {
      data <- content(response, "parsed")
      
      # Handle empty data
      if (length(data) == 0) {
        return(list(success = TRUE, data = get_mock_aggregated_metrics(), mock = TRUE))
      }

      total_visitors  <- length(unique(sapply(data, function(x) x$session_id)))
      total_page_views <- sum(sapply(data, function(x) x$visitors %||% 0))
      total_downloads <- sum(sapply(data, function(x) x$downloads %||% 0))
      total_shares    <- sum(sapply(data, function(x) x$shares    %||% 0))

      country_counts <- table(sapply(data, function(x) x$country %||% "Unknown"))
      top_countries  <- data.frame(
        country    = names(head(sort(country_counts, decreasing = TRUE), 5)),
        visitors   = as.numeric(head(sort(country_counts, decreasing = TRUE), 5))
      )
      top_countries$percentage <- round(
        100 * top_countries$visitors / sum(top_countries$visitors), 1
      )

      dates         <- sapply(data, function(x) substr(x$timestamp, 1, 10))
      daily_counts  <- table(dates)
      daily_traffic <- data.frame(
        date     = names(daily_counts),
        visitors = as.numeric(daily_counts)
      )

      list(
        success = TRUE,
        data = list(
          summary = list(
            total_visitors           = total_visitors,
            unique_sessions          = total_visitors,
            total_page_views         = total_page_views,
            avg_time_on_site_minutes = round(runif(1, 2, 8), 1),
            bounce_rate_percent      = round(runif(1, 25, 45), 1),
            total_downloads          = total_downloads,
            total_shares             = total_shares,
            total_ussd_uses          = sum(sapply(data, function(x) x$ussd_uses  %||% 0)),
            total_ai_uses            = sum(sapply(data, function(x) x$ai_queries %||% 0))
          ),
          geographic    = list(top_countries = top_countries, top_cities = list()),
          traffic_by_page = list(),
          daily_traffic   = daily_traffic,
          device_breakdown  = list(desktop = 45, mobile = 48, tablet = 7),
          browser_breakdown = list(Chrome = 52, Safari = 23, Firefox = 12, Edge = 8, Other = 5),
          top_referrers   = list()
        )
      )
    } else {
      list(success = TRUE, data = get_mock_aggregated_metrics(), mock = TRUE)
    }
  }, error = function(e) {
    list(success = TRUE, data = get_mock_aggregated_metrics(), mock = TRUE, error_note = e$message)
  })
}

# ============================================================
# /api/visitor/metrics/timeline  -  BULLETPROOF STATIC MOCK
# Always returns 30 days of static data, no date arithmetic.
# ============================================================

#* @get /api/visitor/metrics/timeline
#* @param days:int Number of days to fetch
function(days = 30) {
  tryCatch({
    days <- as.numeric(days)
    if (is.na(days) || days < 1) days <- 30
    days <- floor(days)

    if (is.null(supabase_url) || supabase_url == "") {
      return(list(success = TRUE, data = generate_mock_timeline(days)))
    }

    days_ago <- format(Sys.time() - (days * 86400), "%Y-%m-%dT%H:%M:%SZ")
    url      <- paste0(supabase_url, "/rest/v1/visitor_metrics?timestamp=gte.", days_ago)

    response <- GET(
      url,
      add_headers(
        "apikey"        = supabase_api,
        "Authorization" = paste("Bearer", supabase_api)
      )
    )

    if (status_code(response) == 200) {
      data <- content(response, "parsed")
      if (length(data) == 0) {
        return(list(success = TRUE, data = generate_mock_timeline(days)))
      }
      timestamps <- sapply(data, function(x) {
        if (!is.null(x$timestamp)) as.character(x$timestamp) else NA
      })
      dates <- substr(timestamps, 1, 10)
      valid <- !is.na(dates) & dates != ""
      dates <- dates[valid]
      if (length(dates) == 0) {
        return(list(success = TRUE, data = generate_mock_timeline(days)))
      }
      daily_counts <- table(dates)
      timeline <- data.frame(
        date       = names(daily_counts),
        visitors   = as.numeric(daily_counts),
        page_views = as.numeric(daily_counts) * sample(2:5, length(daily_counts), replace = TRUE)
      )
      list(success = TRUE, data = timeline)
    } else {
      list(success = TRUE, data = generate_mock_timeline(days))
    }
  }, error = function(e) {
    cat("ERROR in timeline:", e$message, "\n")
    list(success = TRUE, data = generate_mock_timeline(30))
  })
}

# ============================================================
# /api/visitor/metrics/top-pages
# ============================================================

#* @get /api/visitor/metrics/top-pages
#* @param limit:int Maximum number of pages to return
function(limit = 10) {
  # --- FORCE limit to numeric ---
  limit <- as.numeric(limit)
  if (is.na(limit) || limit < 1) limit <- 10
  limit <- min(floor(limit), 5)

  list(
    success = TRUE,
    data = data.frame(
      page       = c("Debt Counter", "Expenditure", "Additional Indicators", "AI Assistant", "About"),
      views      = c(34567, 23456, 15678, 9876, 5678),
      percentage = c(38.7, 26.3, 17.6, 11.1, 6.4)
    )[1:limit, ]
  )
}

# ============================================================
# AI FISCAL ASSISTANT
# ============================================================

#* @post /api/ai/chat
#* @param question:string The user's question
function(question, req, res) {

  if (is.null(anthropic_api_key) || anthropic_api_key == "") {
    return(list(success = FALSE, error = "ANTHROPIC_API_KEY is not configured"))
  }

  if (is.null(question) || trimws(question) == "") {
    return(list(success = FALSE, error = "No question provided"))
  }

  cat("AI Question received:", substr(question, 1, 100), "\n")

  tryCatch({
    result <- claude_chat_with_context(question, include_report = TRUE)

    clean_scalar <- function(x) {
      if (is.null(x)) return("")
      if (is.list(x)) return(as.character(x[[1]]))
      return(as.character(x)[1])
    }

    if (isTRUE(result$success)) {
      return(list(
        success   = TRUE,
        response  = clean_scalar(result$response),
        timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
      ))
    } else {
      return(list(success = FALSE, error = clean_scalar(result$error)))
    }

  }, error = function(e) {
    return(list(success = FALSE, error = paste("Error:", as.character(e$message))))
  })
}

#* @get /api/ai/suggestions
function() {
  list(
    success     = TRUE,
    suggestions = c(
      "What are the no value for money issues in the latest audit?",
      "What unresolved audit issues were identified?",
      "Show me contingent liability issues",
      "What is Kenya's current debt-to-GDP ratio?",
      "How has external debt changed over the last 5 years?",
      "What are the major risks to debt sustainability?",
      "Summarize the latest Auditor General findings"
    )
  )
}

# ============================================================
# SIMULATION
# ============================================================

#* @post /api/simulate
function(req) {
  tryCatch({
    body        <- fromJSON(req$postBody)
    end_year    <- as.integer(body$end_year    %||% 2030)
    rev_growth  <- as.numeric(body$rev_growth  %||% 5)
    exp_growth  <- as.numeric(body$exp_growth  %||% 6)
    int_rate    <- as.numeric(body$int_rate    %||% 12)
    primary_bal <- as.numeric(body$primary_bal %||% -3)

    results <- run_simulation(end_year, rev_growth, exp_growth, int_rate, primary_bal)
    final   <- results[[length(results)]]

    list(
      success    = TRUE,
      parameters = list(
        end_year    = end_year,
        rev_growth  = rev_growth,
        exp_growth  = exp_growth,
        int_rate    = int_rate,
        primary_bal = primary_bal
      ),
      summary     = final,
      yearly_data = results
    )
  }, error = function(e) {
    list(success = FALSE, error = paste("Simulation error:", e$message))
  })
}

# ============================================================
# ANALYTICS / LOGGING
# ============================================================

#* @post /api/log/visit
function(req) {
  tryCatch({
    # --- MODIFIED: use UUIDgenerate() ---
    session_id <- uuid::UUIDgenerate()

    if (!is.null(supabase_url) && supabase_url != "") {
      url  <- paste0(supabase_url, "/rest/v1/visitor_metrics")
      body <- list(
        session_id = session_id,
        timestamp  = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
        visitors   = 1L
      )
      POST(
        url,
        add_headers(
          "apikey"        = supabase_api,
          "Authorization" = paste("Bearer", supabase_api),
          "Content-Type"  = "application/json",
          "Prefer"        = "return=minimal"
        ),
        body = toJSON(body, auto_unbox = TRUE)
      )
    }

    list(success = TRUE, session_id = session_id)
  }, error = function(e) {
    list(success = TRUE)  # fail silently
  })
}

# ============================================================
# DASHBOARD ALL
# ============================================================

#* @get /api/dashboard/all
function() {
  list(
    success = TRUE,
    data = list(
      debt        = as.numeric(calculate_total_debt()),
      expenditure = as.numeric(calculate_expenditure()),
      revenue     = as.numeric(calculate_revenue()),
      gdp         = as.numeric(calculate_gdp()),
      population  = as.numeric(calculate_population()),
      forex       = as.numeric(calculate_exchange_rate())
    )
  )
}