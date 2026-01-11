
# -----------------------------------------------------------------------------
# Dataformトリガー デバウンス用 Dispatcher Function & Cloud Tasks
# -----------------------------------------------------------------------------

# --- Cloud Tasks Queue ---
resource "google_cloud_tasks_queue" "dataform_trigger_queue" {
  name     = "dataform-trigger-queue${local.env_suffix}"
  location = var.region
  project  = var.project_id
}

# --- Service Account for Dispatcher ---
resource "google_service_account" "dispatcher_sa" {
  account_id   = "dataform-dispatcher-sa${local.env_suffix}"
  display_name = "SA for Dataform Dispatcher Function${local.env_suffix}"
  project      = var.project_id
}

# --- IAM: Dispatcher SA needs to enqueue tasks ---
resource "google_project_iam_member" "dispatcher_cloudtasks_enqueuer" {
  project = var.project_id
  role    = "roles/cloudtasks.enqueuer"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# --- IAM: Dispatcher SA needs to ActAs Workflows SA (for OIDC token) ---
resource "google_service_account_iam_member" "dispatcher_act_as_workflows_sa" {
  service_account_id = google_service_account.workflows_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# --- Dispatcher Source Code ---
# Creating zip here locally for this file
data "archive_file" "dispatcher_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/dispatcher"
  output_path = "${path.module}/../functions/dispatcher.zip"
}

resource "google_storage_bucket_object" "dispatcher_object" {
  name   = "dispatcher-${data.archive_file.dispatcher_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.dispatcher_zip.output_path
}

# --- Dispatcher Function ---
resource "google_cloudfunctions2_function" "dispatcher_function" {
  name        = "dataform-dispatcher-function${local.env_suffix}"
  location    = var.region
  description = "Dispatches Dataform workflow with debounce"
  project     = var.project_id

  build_config {
    runtime     = "python311"
    entry_point = "dispatch_workflow"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.dispatcher_object.name
      }
    }
  }

  service_config {
    max_instance_count = 10
    available_memory   = "256Mi"
    timeout_seconds    = 60
    environment_variables = {
      PROJECT_ID      = var.project_id
      REGION          = var.region
      QUEUE_NAME      = google_cloud_tasks_queue.dataform_trigger_queue.name
      WORKFLOW_NAME   = terraform.workspace == "prd" ? google_workflows_workflow.dataform_trigger_workflow_prd[0].name : google_workflows_workflow.dataform_trigger_workflow_stg[0].name
      DEBOUNCE_SECONDS = "300" # 5 minutes
      WORKFLOW_SERVICE_ACCOUNT_EMAIL = google_service_account.workflows_sa.email
    }
    service_account_email = google_service_account.dispatcher_sa.email
  }
}

# --- Eventarc needs to invoke Dispatcher ---
# Note: google_service_account.workflows_sa is used as trigger identity in triggers.tf
resource "google_cloud_run_service_iam_member" "dispatcher_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.dispatcher_function.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.workflows_sa.email}"
}
