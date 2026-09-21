# ============================================================
# KENYA NATIONAL DEBT COUNTER
# API BOOTSTRAP
# ============================================================
#
# Purpose:
# Entry point for the backend API.
#
# Architecture:
#
# api.R
#    ↓
# routes.R
#    ↓
# data_loader.R
#    ↓
# Supabase
#    ↓
# Frontend Dashboard
#
# Responsibilities:
# - Initialize Plumber API
# - Load route definitions
# - Start HTTP service
# - Expose REST endpoints
#
# ============================================================

library(plumber)

cat("Starting Kenya Debt Counter API...\n")

pr <- plumber::plumb("routes.R")

pr$run(
  host = "0.0.0.0",
  port = as.numeric(Sys.getenv("PORT", unset = "8000"))
)