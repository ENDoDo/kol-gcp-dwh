
# -----------------------------------------------------------------------------
# race_uma_odds 更新用 Cloud Scheduler
# -----------------------------------------------------------------------------

locals {
  workflow_name = terraform.workspace == "prd" ? "dataform-trigger-workflow" : "dataform-trigger-workflow-stg"
  # Workflow execution argument: {"tags": ["odds"]}
  # The API expects: {"argument": "{\"tags\": [\"odds\"]}"}
  workflow_arg_json = "{\"argument\": \"{\\\"tags\\\": [\\\"odds\\\"]}\"}"
}

# 1. レース前日 20:00 (JST)
resource "google_cloud_scheduler_job" "odds_update_day_before" {
  name             = "odds-update-day-before-${local.env_suffix}"
  description      = "race_uma_odds update (Day before race 20:00 JST)"
  schedule         = "0 20 * * *"
  time_zone        = "Asia/Tokyo"
  attempt_deadline = "320s"
  region           = var.region
  project          = var.project_id

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/workflows/${local.workflow_name}/executions"
    body        = base64encode(local.workflow_arg_json)

    oauth_token {
      service_account_email = google_service_account.workflows_sa.email
    }
  }
}

# 2. レース当日 06:00, 09:00, 12:00, 15:00 (JST)
resource "google_cloud_scheduler_job" "odds_update_race_day" {
  name             = "odds-update-race-day-${local.env_suffix}"
  description      = "race_uma_odds update (Race day 06:00, 09:00, 12:00, 15:00 JST)"
  schedule         = "0 6,9,12,15 * * *"
  time_zone        = "Asia/Tokyo"
  attempt_deadline = "320s"
  region           = var.region
  project          = var.project_id

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/workflows/${local.workflow_name}/executions"
    body        = base64encode(local.workflow_arg_json)

    oauth_token {
      service_account_email = google_service_account.workflows_sa.email
    }
  }
}
