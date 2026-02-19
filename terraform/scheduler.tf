
# -----------------------------------------------------------------------------
# race_uma_odds 更新用 Cloud Scheduler
# -----------------------------------------------------------------------------

locals {
  workflow_name = terraform.workspace == "prd" ? "dataform-trigger-workflow" : "dataform-trigger-workflow-stg"
  # Workflow execution argument: {"tags": ["odds"]}
  # The API expects: {"argument": "{\"tags\": [\"odds\"]}"}
  workflow_arg_json = "{\"argument\": \"{\\\"tags\\\": [\\\"odds\\\"]}\"}"
}


# race_uma_odds 更新用 Cloud Scheduler (06, 09, 12, 15, 20:00 JST)
resource "google_cloud_scheduler_job" "odds_update" {
  name             = "odds-update-${local.env_suffix}"
  description      = "race_uma_odds update (08:30, 11:30, 14:30, 17:30, 20:30 JST)"
  schedule         = "30 8,11,14,17,20 * * *"
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
