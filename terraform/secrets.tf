# -----------------------------------------------------------------------------
# Secret Manager アクセス設定
# -----------------------------------------------------------------------------

# スケジュールエクスポート用関数SAに対して、特定のシークレットへのアクセス権(Secret Accessor)を付与

resource "google_secret_manager_secret_iam_member" "ftp_user_accessor" {
  project   = "56638639323" # シークレットを所有するプロジェクト番号/ID
  secret_id = "kol_ftp_bubble_username"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "ftp_pass_accessor" {
  project   = "56638639323"
  secret_id = "kol_ftp_bubble_password"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

# レース詳細エクスポート関数への権限付与

resource "google_secret_manager_secret_iam_member" "ftp_user_accessor_race_uma" {
  project   = "56638639323"
  secret_id = "kol_ftp_bubble_username"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_race_uma_detail_bubble_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "ftp_pass_accessor_race_uma" {
  project   = "56638639323"
  secret_id = "kol_ftp_bubble_password"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_race_uma_detail_bubble_sa.email}"
}
resource "google_secret_manager_secret_iam_member" "bubble_api_key_accessor" {
  project   = "56638639323"
  secret_id = "kol_bubble_workflow_api_key"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "bubble_api_key_accessor_race_uma" {
  project   = "56638639323"
  secret_id = "kol_bubble_workflow_api_key"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_race_uma_detail_bubble_sa.email}"
}

# -----------------------------------------------------------------------------
# Bubble API URL シークレット（管理画面から動的更新用）
# バージョン未登録時は env var BUBBLE_API_URL にフォールバックするため
# 初期バージョンは Terraform 管理外（管理画面または手動で登録）
# -----------------------------------------------------------------------------

resource "google_secret_manager_secret" "bubble_schedule_api_url" {
  project   = var.project_id
  secret_id = "kol_bubble_schedule_api_url"
  replication { auto {} }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "bubble_schedule_api_url_stg" {
  project   = var.project_id
  secret_id = "kol_bubble_schedule_api_url_stg"
  replication { auto {} }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "bubble_races_api_url" {
  project   = var.project_id
  secret_id = "kol_bubble_races_api_url"
  replication { auto {} }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "bubble_races_api_url_stg" {
  project   = var.project_id
  secret_id = "kol_bubble_races_api_url_stg"
  replication { auto {} }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "bubble_race_uma_detail_api_url" {
  project   = var.project_id
  secret_id = "kol_bubble_race_uma_detail_api_url"
  replication { auto {} }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "bubble_race_uma_detail_api_url_stg" {
  project   = var.project_id
  secret_id = "kol_bubble_race_uma_detail_api_url_stg"
  replication { auto {} }
  depends_on = [google_project_service.secretmanager]
}

# --- Accessor: export_schedules_sa（schedule + races 両関数で使用）---

resource "google_secret_manager_secret_iam_member" "bubble_schedule_url_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.bubble_schedule_api_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "bubble_schedule_url_accessor_stg" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.bubble_schedule_api_url_stg.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "bubble_races_url_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.bubble_races_api_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "bubble_races_url_accessor_stg" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.bubble_races_api_url_stg.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_schedules_sa.email}"
}

# --- Accessor: export_race_uma_detail_bubble_sa ---

resource "google_secret_manager_secret_iam_member" "bubble_race_uma_detail_url_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.bubble_race_uma_detail_api_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_race_uma_detail_bubble_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "bubble_race_uma_detail_url_accessor_stg" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.bubble_race_uma_detail_api_url_stg.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.export_race_uma_detail_bubble_sa.email}"
}
