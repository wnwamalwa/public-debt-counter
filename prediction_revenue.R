# ============================================================================
# Revenue and Expenditure Prediction using XGBoost and Dynamic ARDL in R
# Central Bank of Kenya Data Analysis
# ============================================================================

# ============================================================================
# PART 1: SETUP AND DATA LOADING
# ============================================================================

# Install and load required packages
packages <- c("xgboost", "ARDL", "dplyr", "ggplot2", "tseries", "lmtest",
              "forecast", "tidyr", "readr", "rvest", "caret")

# Install packages if not already installed
new_packages <- packages[!(packages %in% installed.packages()[,"Package"])]
if(length(new_packages)) install.packages(new_packages)

# Load libraries
lapply(packages, library, character.only = TRUE)

# Load data from CBK
load_cbk_data <- function() {
  cat("\n=============================================================\n")
  cat("Loading Data from Central Bank of Kenya\n")
  cat("=============================================================\n")

  # Load Revenue and Expenditure
  revenue_exp <- read_csv("https://www.centralbank.go.ke/uploads/government_finance_statistics/1142265704_Revenue%20and%20Expenditure.csv")

  # Load Public Debt
  debt <- read_csv("https://www.centralbank.go.ke/uploads/government_finance_statistics/42346012_Public%20Debt.csv")

  # Scrape GDP data (you may need to adjust column names based on actual data)
  # gdp_page <- read_html("https://www.centralbank.go.ke/annual-gdp/")
  # gdp <- html_table(gdp_page)[[1]]

  # For demonstration, let's assume you have GDP data
  # Merge datasets (adjust column names as needed)
  data <- revenue_exp %>%
    left_join(debt, by = "Year") %>%
    arrange(Year)

  cat("Data loaded successfully!\n")
  cat("Years available:", min(data$Year), "to", max(data$Year), "\n")
  cat("Number of observations:", nrow(data), "\n")

  return(data)
}

# ============================================================================
# PART 2: FEATURE ENGINEERING
# ============================================================================

create_features <- function(data) {
  cat("\n=============================================================\n")
  cat("Creating Features for Modeling\n")
  cat("=============================================================\n")

  df <- data %>%
    arrange(Year) %>%
    mutate(
      # Lag features
      Revenue_lag1 = lag(Revenue, 1),
      Revenue_lag2 = lag(Revenue, 2),
      Revenue_lag3 = lag(Revenue, 3),

      Expenditure_lag1 = lag(Expenditure, 1),
      Expenditure_lag2 = lag(Expenditure, 2),
      Expenditure_lag3 = lag(Expenditure, 3),

      Debt_lag1 = lag(Total_Debt, 1),
      Debt_lag2 = lag(Total_Debt, 2),

      # Growth rates
      Revenue_growth = (Revenue - lag(Revenue)) / lag(Revenue),
      Expenditure_growth = (Expenditure - lag(Expenditure)) / lag(Expenditure),
      GDP_growth = (GDP - lag(GDP)) / lag(GDP),

      # Ratios (if GDP available)
      Revenue_to_GDP = Revenue / GDP,
      Expenditure_to_GDP = Expenditure / GDP,
      Debt_to_GDP = Total_Debt / GDP,

      # Fiscal indicators
      Fiscal_Balance = Revenue - Expenditure,
      Fiscal_Balance_lag1 = lag(Fiscal_Balance, 1),

      # Rolling averages
      Revenue_ma2 = (Revenue + lag(Revenue, 1)) / 2,
      Revenue_ma3 = (Revenue + lag(Revenue, 1) + lag(Revenue, 2)) / 3,

      Expenditure_ma2 = (Expenditure + lag(Expenditure, 1)) / 2,
      Expenditure_ma3 = (Expenditure + lag(Expenditure, 1) + lag(Expenditure, 2)) / 3
    )

  cat("Features created successfully!\n")
  return(df)
}

# ============================================================================
# PART 3: XGBOOST MODEL
# ============================================================================

train_xgboost <- function(data, target = "Revenue", predict_horizon = 1) {
  cat("\n=============================================================\n")
  cat("Training XGBoost Model for", target, "\n")
  cat("=============================================================\n")

  # Prepare data
  df <- create_features(data) %>%
    na.omit()

  # Create future target
  df[[paste0(target, "_future")]] <- lead(df[[target]], predict_horizon)
  df <- na.omit(df)

  # Select features
  exclude_cols <- c("Year", "Revenue", "Expenditure", "Total_Debt", "GDP",
                    "Domestic_Debt", "External_Debt", paste0(target, "_future"))

  feature_cols <- setdiff(names(df), exclude_cols)

  # Prepare matrices
  X <- as.matrix(df[, feature_cols])
  y <- df[[paste0(target, "_future")]]

  # Time series split (80-20)
  train_size <- floor(0.8 * nrow(X))

  X_train <- X[1:train_size, ]
  X_test <- X[(train_size + 1):nrow(X), ]
  y_train <- y[1:train_size]
  y_test <- y[(train_size + 1):length(y)]

  # Train XGBoost
  dtrain <- xgb.DMatrix(data = X_train, label = y_train)
  dtest <- xgb.DMatrix(data = X_test, label = y_test)

  params <- list(
    objective = "reg:squarederror",
    max_depth = 4,
    eta = 0.05,
    subsample = 0.8,
    colsample_bytree = 0.8
  )

  watchlist <- list(train = dtrain, test = dtest)

  model <- xgb.train(
    params = params,
    data = dtrain,
    nrounds = 100,
    watchlist = watchlist,
    early_stopping_rounds = 20,
    verbose = 0
  )

  # Predictions
  pred_train <- predict(model, dtrain)
  pred_test <- predict(model, dtest)

  # Evaluation metrics
  cat("\n=============================================================\n")
  cat("Model Performance\n")
  cat("=============================================================\n")
  cat(sprintf("Training R²: %.4f\n", cor(y_train, pred_train)^2))
  cat(sprintf("Testing R²: %.4f\n", cor(y_test, pred_test)^2))
  cat(sprintf("Training MAE: %,.2f\n", mean(abs(y_train - pred_train))))
  cat(sprintf("Testing MAE: %,.2f\n", mean(abs(y_test - pred_test))))
  cat(sprintf("Training RMSE: %,.2f\n", sqrt(mean((y_train - pred_train)^2))))
  cat(sprintf("Testing RMSE: %,.2f\n", sqrt(mean((y_test - pred_test)^2))))

  # Feature importance
  importance <- xgb.importance(feature_names = feature_cols, model = model)
  cat("\n=============================================================\n")
  cat("Top 10 Most Important Features\n")
  cat("=============================================================\n")
  print(head(importance, 10))

  # Plot importance
  xgb.plot.importance(importance_matrix = head(importance, 10))

  return(list(
    model = model,
    X_train = X_train,
    X_test = X_test,
    y_train = y_train,
    y_test = y_test,
    pred_train = pred_train,
    pred_test = pred_test,
    feature_cols = feature_cols,
    df = df
  ))
}

# Forecast future values
forecast_xgboost <- function(model_results, data, target = "Revenue", periods = 5) {
  cat("\n=============================================================\n")
  cat("Forecasting Future", target, "\n")
  cat("=============================================================\n")

  df_forecast <- data
  predictions <- numeric(periods)

  for (i in 1:periods) {
    # Create features for latest data
    df_temp <- create_features(df_forecast) %>% na.omit()

    # Get latest features
    X_latest <- as.matrix(df_temp[nrow(df_temp), model_results$feature_cols])
    dlatest <- xgb.DMatrix(data = X_latest)

    # Predict
    pred <- predict(model_results$model, dlatest)
    predictions[i] <- pred

    # Add prediction for next iteration
    next_year <- max(df_forecast$Year) + 1
    new_row <- df_forecast[nrow(df_forecast), ]
    new_row$Year <- next_year
    new_row[[target]] <- pred

    df_forecast <- rbind(df_forecast, new_row)
  }

  # Print predictions
  last_year <- max(data$Year)
  for (i in 1:periods) {
    cat(sprintf("%d: KES %,.2f\n", last_year + i, predictions[i]))
  }

  return(predictions)
}

# ============================================================================
# PART 4: DYNAMIC ARDL MODEL
# ============================================================================

run_ardl_analysis <- function(data, target = "Revenue") {
  cat("\n=============================================================\n")
  cat("Dynamic ARDL Analysis for", target, "\n")
  cat("=============================================================\n")

  # Prepare data for ARDL
  df <- data %>%
    arrange(Year) %>%
    select(Year, Revenue, Expenditure, Total_Debt, GDP) %>%
    na.omit()

  # Convert to time series
  ts_data <- ts(df[, -1], start = min(df$Year), frequency = 1)

  # Test for stationarity
  cat("\n--- Unit Root Tests (ADF) ---\n")
  for (col in colnames(ts_data)) {
    adf_test <- adf.test(ts_data[, col], alternative = "stationary")
    cat(sprintf("%s: p-value = %.4f %s\n",
                col, adf_test$p.value,
                ifelse(adf_test$p.value < 0.05, "(Stationary)", "(Non-stationary)")))
  }

  # Determine optimal lag order
  if (target == "Revenue") {
    # Revenue as dependent variable
    ardl_formula <- Revenue ~ Expenditure + Total_Debt + GDP
  } else {
    # Expenditure as dependent variable
    ardl_formula <- Expenditure ~ Revenue + Total_Debt + GDP
  }

  # Auto ARDL to find best model
  cat("\n--- Searching for Optimal ARDL Model ---\n")
  ardl_model <- auto_ardl(
    ardl_formula,
    data = df,
    max_order = 3,
    selection = "AIC"
  )

  cat("\n=============================================================\n")
  cat("Best ARDL Model Summary\n")
  cat("=============================================================\n")
  print(summary(ardl_model))

  # Bounds test for cointegration
  cat("\n=============================================================\n")
  cat("Bounds Test for Cointegration\n")
  cat("=============================================================\n")
  bounds <- bounds_f_test(ardl_model, case = 3)
  print(bounds)

  # Long-run coefficients
  cat("\n=============================================================\n")
  cat("Long-Run Coefficients\n")
  cat("=============================================================\n")
  lr_mult <- multipliers(ardl_model, type = "lr")
  print(lr_mult)

  # Short-run coefficients
  cat("\n=============================================================\n")
  cat("Short-Run Coefficients\n")
  cat("=============================================================\n")
  sr_mult <- multipliers(ardl_model, type = "sr")
  print(sr_mult)

  # Error Correction Model
  cat("\n=============================================================\n")
  cat("Error Correction Model\n")
  cat("=============================================================\n")
  ecm <- recm(ardl_model, case = 3)
  print(summary(ecm))

  # Forecasting with ARDL
  cat("\n=============================================================\n")
  cat("ARDL Forecast (Next 5 Years)\n")
  cat("=============================================================\n")

  # Simple forecast using the model
  forecast_periods <- 5
  last_values <- tail(df, 1)

  cat("\nNote: ARDL forecasting requires assumptions about future values\n")
  cat("of independent variables. For illustration, we assume they grow\n")
  cat("at their historical average rates.\n\n")

  # Calculate average growth rates
  if (target == "Revenue") {
    exp_growth <- mean(diff(df$Expenditure) / head(df$Expenditure, -1), na.rm = TRUE)
    debt_growth <- mean(diff(df$Total_Debt) / head(df$Total_Debt, -1), na.rm = TRUE)
    gdp_growth <- mean(diff(df$GDP) / head(df$GDP, -1), na.rm = TRUE)

    # Forecast
    forecast_df <- data.frame(
      Year = (max(df$Year) + 1):(max(df$Year) + forecast_periods),
      Expenditure = last_values$Expenditure * (1 + exp_growth)^(1:forecast_periods),
      Total_Debt = last_values$Total_Debt * (1 + debt_growth)^(1:forecast_periods),
      GDP = last_values$GDP * (1 + gdp_growth)^(1:forecast_periods)
    )
  } else {
    rev_growth <- mean(diff(df$Revenue) / head(df$Revenue, -1), na.rm = TRUE)
    debt_growth <- mean(diff(df$Total_Debt) / head(df$Total_Debt, -1), na.rm = TRUE)
    gdp_growth <- mean(diff(df$GDP) / head(df$GDP, -1), na.rm = TRUE)

    forecast_df <- data.frame(
      Year = (max(df$Year) + 1):(max(df$Year) + forecast_periods),
      Revenue = last_values$Revenue * (1 + rev_growth)^(1:forecast_periods),
      Total_Debt = last_values$Total_Debt * (1 + debt_growth)^(1:forecast_periods),
      GDP = last_values$GDP * (1 + gdp_growth)^(1:forecast_periods)
    )
  }

  # Predict using ARDL model
  ardl_predictions <- predict(ardl_model, newdata = forecast_df)

  for (i in 1:forecast_periods) {
    cat(sprintf("%d: KES %,.2f\n", forecast_df$Year[i], ardl_predictions[i]))
  }

  return(list(
    model = ardl_model,
    bounds_test = bounds,
    lr_coefficients = lr_mult,
    sr_coefficients = sr_mult,
    ecm = ecm,
    forecast = ardl_predictions,
    forecast_data = forecast_df
  ))
}

# ============================================================================
# PART 5: VISUALIZATION
# ============================================================================

plot_comparison <- function(data, xgb_results, ardl_results, target = "Revenue") {
  # Historical plot
  df <- xgb_results$df
  train_size <- length(xgb_results$y_train)

  plot_df <- data.frame(
    Year = df$Year,
    Actual = df[[target]],
    XGB_Train = c(xgb_results$pred_train, rep(NA, length(xgb_results$y_test))),
    XGB_Test = c(rep(NA, train_size), xgb_results$pred_test)
  )

  p1 <- ggplot(plot_df, aes(x = Year)) +
    geom_line(aes(y = Actual, color = "Actual"), size = 1.2) +
    geom_point(aes(y = Actual, color = "Actual"), size = 3) +
    geom_line(aes(y = XGB_Train, color = "XGBoost Train"), size = 1, linetype = "dashed") +
    geom_line(aes(y = XGB_Test, color = "XGBoost Test"), size = 1, linetype = "dashed") +
    labs(title = paste("XGBoost:", target, "- Actual vs Predicted"),
         y = paste(target, "(KES)"),
         x = "Year") +
    theme_minimal() +
    theme(legend.position = "bottom")

  print(p1)

  # Future forecast comparison
  last_year <- max(data$Year)
  future_years <- (last_year + 1):(last_year + 5)

  # Note: You'll need to get XGBoost forecasts separately
  # This is a placeholder

  cat("\nPlots generated successfully!\n")
}

# ============================================================================
# PART 6: MAIN EXECUTION
# ============================================================================

main <- function() {
  cat("\n")
  cat("===================================================================\n")
  cat("REVENUE AND EXPENDITURE PREDICTION\n")
  cat("XGBoost vs Dynamic ARDL Analysis\n")
  cat("===================================================================\n")

  # Load data
  data <- load_cbk_data()

  # ========================
  # REVENUE ANALYSIS
  # ========================
  cat("\n\n")
  cat("###################################################################\n")
  cat("#                    REVENUE PREDICTION                           #\n")
  cat("###################################################################\n")

  # XGBoost for Revenue
  cat("\n--- METHOD 1: XGBoost ---\n")
  revenue_xgb <- train_xgboost(data, target = "Revenue")
  revenue_xgb_forecast <- forecast_xgboost(revenue_xgb, data, target = "Revenue", periods = 5)

  # ARDL for Revenue
  cat("\n--- METHOD 2: Dynamic ARDL ---\n")
  revenue_ardl <- run_ardl_analysis(data, target = "Revenue")

  # ========================
  # EXPENDITURE ANALYSIS
  # ========================
  cat("\n\n")
  cat("###################################################################\n")
  cat("#                  EXPENDITURE PREDICTION                         #\n")
  cat("###################################################################\n")

  # XGBoost for Expenditure
  cat("\n--- METHOD 1: XGBoost ---\n")
  exp_xgb <- train_xgboost(data, target = "Expenditure")
  exp_xgb_forecast <- forecast_xgboost(exp_xgb, data, target = "Expenditure", periods = 5)

  # ARDL for Expenditure
  cat("\n--- METHOD 2: Dynamic ARDL ---\n")
  exp_ardl <- run_ardl_analysis(data, target = "Expenditure")

  # ========================
  # COMPARISON
  # ========================
  cat("\n\n")
  cat("===================================================================\n")
  cat("FORECAST COMPARISON\n")
  cat("===================================================================\n")

  last_year <- max(data$Year)

  cat("\n--- Revenue Forecasts ---\n")
  cat(sprintf("%-6s | %-20s | %-20s\n", "Year", "XGBoost", "ARDL"))
  cat(strrep("-", 55), "\n")
  for (i in 1:5) {
    cat(sprintf("%-6d | KES %15,.2f | KES %15,.2f\n",
                last_year + i,
                revenue_xgb_forecast[i],
                revenue_ardl$forecast[i]))
  }

  cat("\n--- Expenditure Forecasts ---\n")
  cat(sprintf("%-6s | %-20s | %-20s\n", "Year", "XGBoost", "ARDL"))
  cat(strrep("-", 55), "\n")
  for (i in 1:5) {
    cat(sprintf("%-6d | KES %15,.2f | KES %15,.2f\n",
                last_year + i,
                exp_xgb_forecast[i],
                exp_ardl$forecast[i]))
  }

  cat("\n--- Fiscal Balance Forecasts ---\n")
  cat(sprintf("%-6s | %-20s | %-20s\n", "Year", "XGBoost", "ARDL"))
  cat(strrep("-", 55), "\n")
  for (i in 1:5) {
    xgb_balance <- revenue_xgb_forecast[i] - exp_xgb_forecast[i]
    ardl_balance <- revenue_ardl$forecast[i] - exp_ardl$forecast[i]
    cat(sprintf("%-6d | KES %15,.2f | KES %15,.2f\n",
                last_year + i,
                xgb_balance,
                ardl_balance))
  }

  cat("\n")
  cat("===================================================================\n")
  cat("Analysis Complete!\n")
  cat("===================================================================\n")

  return(list(
    revenue_xgb = revenue_xgb,
    revenue_ardl = revenue_ardl,
    exp_xgb = exp_xgb,
    exp_ardl = exp_ardl
  ))
}

# Run the analysis
results <- main()
