# -----------------------------------------------------------------------------
# スケジュールエクスポート用 Cloud Function
# -----------------------------------------------------------------------------

# --- ソースコードバケット ---
resource "google_storage_bucket" "function_source_bucket" {
  name                        = "kol-function-source-${var.project_id}${local.env_suffix}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false
}

# --- サービスアカウント ---
resource "google_service_account" "export_schedules_sa" {
  account_id   = "export-schedules-sa${local.env_suffix}"
  display_name = "Service Account for Schedule Export Function${local.env_suffix}"
  project      = var.project_id
}

# --- SA用 IAM ロール ---
# BigQuery Data Editor, Job User
resource "google_project_iam_member" "export_schedules_bq_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

resource "google_project_iam_member" "export_schedules_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

# --- ソースコードのアーカイブ ---
data "archive_file" "export_schedules_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/export_schedules"
  output_path = "${path.module}/../functions/export_schedules.zip"
}

# --- ソースコードのアップロード ---
resource "google_storage_bucket_object" "export_schedules_object" {
  name   = "export_schedules-${data.archive_file.export_schedules_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.export_schedules_zip.output_path
}

# --- Cloud Function Gen2 ---
resource "google_cloudfunctions2_function" "export_schedules" {
  name        = "export-schedules-function${local.env_suffix}"
  location    = var.region
  description = "Exports schedule updates to FTP"
  project     = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "export_schedules" # main.py 内の関数名と一致させる必要があります
    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.export_schedules_object.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "512M"
    timeout_seconds    = 540
    environment_variables = {
      PROJECT_ID               = var.project_id
      DATASET_ID               = terraform.workspace == "prd" ? var.prd_schema : var.stg_schema
      SECRET_USER              = "projects/56638639323/secrets/kol_ftp_bubble_username"
      SECRET_PASS              = "projects/56638639323/secrets/kol_ftp_bubble_password"
      FTP_DIRECTORY            = terraform.workspace == "prd" ? "/production" : "/development"
      BUBBLE_API_URL           = terraform.workspace == "prd" ? "https://member.kol-bi.jp/api/1.1/wf/import_schedule" : "https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_schedule"
      BUBBLE_API_URL_SECRET_ID = terraform.workspace == "prd" ? "projects/56638639323/secrets/kol_bubble_schedule_api_url" : "projects/56638639323/secrets/kol_bubble_schedule_api_url_stg"
      BUBBLE_API_KEY_SECRET_ID = "projects/56638639323/secrets/kol_bubble_workflow_api_key"
      CSV_BASE_URL             = "https://kol-bi.jp/umasiri.dev"
      ENABLE_BUBBLE_API           = "false"
      ENABLE_BUBBLE_API_SECRET_ID = terraform.workspace == "prd" ? "projects/56638639323/secrets/kol_bubble_api_enabled" : "projects/56638639323/secrets/kol_bubble_api_enabled_stg"
    }
    service_account_email = google_service_account.export_schedules_sa.email
  }

  depends_on = [
    google_project_iam_member.export_schedules_bq_editor,
    google_project_iam_member.export_schedules_bq_job_user
  ]
}

# Workflows SAにCloud Function呼び出し権限を付与 (Cloud Run Serviceに対して付与)
resource "google_cloud_run_service_iam_member" "workflows_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.export_schedules.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.workflows_sa.email}"
}

# Workflows用に出力するURI
output "export_schedules_function_uri" {
  value = google_cloudfunctions2_function.export_schedules.service_config[0].uri
}

# -----------------------------------------------------------------------------
# レース詳細エクスポート用 Cloud Function
# -----------------------------------------------------------------------------

# --- サービスアカウント ---
resource "google_service_account" "export_race_uma_detail_bubble_sa" {
  account_id   = "export-race-uma-bubble-sa${local.env_suffix}"
  display_name = "SA for Race Uma Details Export Function${local.env_suffix}"
  project      = var.project_id
}

# --- SA用 IAM ロール ---
resource "google_project_iam_member" "export_race_uma_detail_bubble_bq_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.export_race_uma_detail_bubble_sa.email}"
}

resource "google_project_iam_member" "export_race_uma_detail_bubble_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.export_race_uma_detail_bubble_sa.email}"
}

# --- ソースコードのアーカイブ ---
data "archive_file" "export_race_uma_detail_bubble_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/export_race_uma_detail_bubble"
  output_path = "${path.module}/../functions/export_race_uma_detail_bubble.zip"
}

# --- ソースコードのアップロード ---
resource "google_storage_bucket_object" "export_race_uma_detail_bubble_object" {
  name   = "export_race_uma_detail_bubble-${data.archive_file.export_race_uma_detail_bubble_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.export_race_uma_detail_bubble_zip.output_path
}

# --- Cloud Function Gen2 ---
resource "google_cloudfunctions2_function" "export_race_uma_detail_bubble" {
  name        = "export-race-uma-details-function${local.env_suffix}"
  location    = var.region
  description = "Exports race uma details (delta) to FTP"
  project     = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "export_race_uma_detail_bubble"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.export_race_uma_detail_bubble_object.name
      }
    }
  }

  service_config {
    max_instance_count               = 5
    max_instance_request_concurrency = 10
    available_memory                 = "8192M" # メモリ不足解消のため増強
    available_cpu                    = "4"     # 4GB以上のメモリには2CPU以上が必要、8GBなら4CPU推奨
    timeout_seconds                  = 3600
    environment_variables = {
      PROJECT_ID               = var.project_id
      DATASET_ID               = terraform.workspace == "prd" ? var.prd_schema : var.stg_schema
      SECRET_USER              = "projects/56638639323/secrets/kol_ftp_bubble_username"
      SECRET_PASS              = "projects/56638639323/secrets/kol_ftp_bubble_password"
      FTP_DIRECTORY            = terraform.workspace == "prd" ? "/production" : "/development"
      BUBBLE_API_URL           = terraform.workspace == "prd" ? "https://member.kol-bi.jp/api/1.1/wf/import_race_uma_detail" : "https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_race_uma_detail"
      BUBBLE_API_URL_SECRET_ID = terraform.workspace == "prd" ? "projects/56638639323/secrets/kol_bubble_race_uma_detail_api_url" : "projects/56638639323/secrets/kol_bubble_race_uma_detail_api_url_stg"
      BUBBLE_API_KEY_SECRET_ID = "projects/56638639323/secrets/kol_bubble_workflow_api_key"
      CSV_BASE_URL             = "https://kol-bi.jp/umasiri.dev"
      ENABLE_BUBBLE_API           = "false"
      ENABLE_BUBBLE_API_SECRET_ID = terraform.workspace == "prd" ? "projects/56638639323/secrets/kol_bubble_api_enabled" : "projects/56638639323/secrets/kol_bubble_api_enabled_stg"
    }
    service_account_email = google_service_account.export_race_uma_detail_bubble_sa.email
  }

  depends_on = [
    google_project_iam_member.export_race_uma_detail_bubble_bq_editor,
    google_project_iam_member.export_race_uma_detail_bubble_bq_job_user
  ]
}

# Workflows用に出力するURI
output "export_race_uma_detail_bubble_function_uri" {
  value = google_cloudfunctions2_function.export_race_uma_detail_bubble.service_config[0].uri
}

# Workflows SAにCloud Function呼び出し権限を付与
resource "google_cloud_run_service_iam_member" "workflows_invoker_race_uma_details" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.export_race_uma_detail_bubble.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.workflows_sa.email}"
}

# -----------------------------------------------------------------------------
# レースエクスポート用 Cloud Function
# -----------------------------------------------------------------------------

# --- ソースコードのアーカイブ ---
data "archive_file" "export_races_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/export_races"
  output_path = "${path.module}/../functions/export_races.zip"
}

# --- ソースコードのアップロード ---
resource "google_storage_bucket_object" "export_races_object" {
  name   = "export_races-${data.archive_file.export_races_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.export_races_zip.output_path
}

# --- Cloud Function Gen2 ---
resource "google_cloudfunctions2_function" "export_races" {
  name        = "export-races-function${local.env_suffix}"
  location    = var.region
  description = "Exports race updates to FTP"
  project     = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "export_races"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.export_races_object.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "512M"
    timeout_seconds    = 540
    environment_variables = {
      PROJECT_ID               = var.project_id
      DATASET_ID               = terraform.workspace == "prd" ? var.prd_schema : var.stg_schema
      SECRET_USER              = "projects/56638639323/secrets/kol_ftp_bubble_username"
      SECRET_PASS              = "projects/56638639323/secrets/kol_ftp_bubble_password"
      FTP_DIRECTORY            = terraform.workspace == "prd" ? "/production" : "/development"
      BUBBLE_API_URL           = terraform.workspace == "prd" ? "https://member.kol-bi.jp/api/1.1/wf/import_race" : "https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_race"
      BUBBLE_API_URL_SECRET_ID = terraform.workspace == "prd" ? "projects/56638639323/secrets/kol_bubble_races_api_url" : "projects/56638639323/secrets/kol_bubble_races_api_url_stg"
      BUBBLE_API_KEY_SECRET_ID = "projects/56638639323/secrets/kol_bubble_workflow_api_key"
      CSV_BASE_URL             = "https://kol-bi.jp/umasiri.dev"
      ENABLE_BUBBLE_API           = "false"
      ENABLE_BUBBLE_API_SECRET_ID = terraform.workspace == "prd" ? "projects/56638639323/secrets/kol_bubble_api_enabled" : "projects/56638639323/secrets/kol_bubble_api_enabled_stg"
    }
    service_account_email = google_service_account.export_schedules_sa.email # 同じSAを使用
  }

  depends_on = [
    google_project_iam_member.export_schedules_bq_editor,
    google_project_iam_member.export_schedules_bq_job_user
  ]
}

# Workflows SAにCloud Function呼び出し権限を付与
resource "google_cloud_run_service_iam_member" "workflows_invoker_races" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.export_races.service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.workflows_sa.email}"
}

output "export_races_function_uri" {
  value = google_cloudfunctions2_function.export_races.service_config[0].uri
}
