# Run this once on the server to install all required R packages
packages <- c(
  "plumber",
  "jsonlite",
  "dplyr",
  "tidyr",
  "lubridate",
  "httr",
  "readr",
  "rvest",
  # Added for df_gdp.R / df_pop.R, which now read their actual/interpolated/
  # forecast series from the Google Sheet instead of scraping CBK / a local
  # CSV -- same auth pattern as quarterly_macro_debt_report_ieakenya.qmd.
  "googlesheets4",
  "gargle"
)

install.packages(packages, repos = "https://cloud.r-project.org")
cat("All packages installed successfully.\n")
