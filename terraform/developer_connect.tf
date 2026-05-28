# -----------------------------------------------------------------------------
# Developer Connect - GitHub App ベースの Git 認証
# PAT（github-token シークレット）の代替として使用
# -----------------------------------------------------------------------------

# Developer Connect サービスエージェント (P4SA) の作成
# OAuth トークンを Secret Manager に書き込む権限が必要
resource "google_project_service_identity" "devconnect_p4sa" {
  provider   = google-beta.beta
  project    = var.project_id
  service    = "developerconnect.googleapis.com"
  depends_on = [google_project_service.developerconnect]
}

# P4SA に Secret Manager Admin 権限を付与
# Developer Connect がシークレットを動的に作成・管理するため roles/secretmanager.admin が必要。
# シークレット作成前は特定シークレットにスコープできないため、プロジェクト全体への付与は GCP の要件。
resource "google_project_iam_member" "devconnect_secret_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = google_project_service_identity.devconnect_p4sa.member
}

# Dataform サービスエージェントに Developer Connect トークン読み取り権限を付与
resource "google_project_iam_member" "dataform_devconnect_token_accessor" {
  project = var.project_id
  role    = "roles/developerconnect.tokenAccessor"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"
}

# Dataform サービスエージェントに Developer Connect Git プロキシ使用権限を付与
resource "google_project_iam_member" "dataform_devconnect_git_proxy_user" {
  project = var.project_id
  role    = "roles/developerconnect.gitProxyUser"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"
}

# Developer Connect 接続 (GitHub App ベース)
# NOTE: stg ワークスペースでのみ作成。Developer Connect はプロジェクトスコープのため
#       STG/PRD 両 Dataform リポジトリが同一接続を共有する。
#
# 初回 apply 後に以下の手動ステップが必要:
#   gcloud developer-connect connections describe kol-dataform-github \
#     --location=asia-northeast1 --project=smartkeiba \
#     --format="json(installationState)"
#   → actionUri をブラウザで開き、GitHub App OAuth を承認する
resource "google_developer_connect_connection" "dataform_github" {
  count         = terraform.workspace != "prd" ? 1 : 0
  provider      = google-beta.beta
  project       = var.project_id
  location      = var.region
  connection_id = "kol-dataform-github"

  github_config {
    github_app = "DEVELOPER_CONNECT"
    # OAuth 完了後に app_installation_id を設定する
    # https://github.com/settings/installations で "Google Cloud Developer Connect" の
    # Configure URL 末尾の数字を確認して設定
    # app_installation_id = 0  # TODO: OAuth 後に追記してから ignore_changes を削除
  }

  lifecycle {
    ignore_changes = [github_config]
  }

  depends_on = [
    google_project_iam_member.devconnect_secret_admin,
    google_project_service.developerconnect,
  ]
}

# GitHub リポジトリリンク
# OAuth 承認 (installation_state = COMPLETE) 後に apply すること
resource "google_developer_connect_git_repository_link" "kol_dataform_repo" {
  count                  = terraform.workspace != "prd" ? 1 : 0
  provider               = google-beta.beta
  project                = var.project_id
  location               = var.region
  parent_connection      = google_developer_connect_connection.dataform_github[0].connection_id
  git_repository_link_id = "kol-gcp-dwh"
  clone_uri              = "https://github.com/ENDoDo/kol-gcp-dwh.git"

  depends_on = [google_developer_connect_connection.dataform_github]
}

# Dataform サービスエージェントに Developer Connect OAuth トークンシークレットの読み取り権限を付与
# これにより Dataform が Developer Connect 管理の GitHub OAuth トークンで認証できる
resource "google_secret_manager_secret_iam_member" "dataform_devconnect_oauth_accessor" {
  project   = var.project_id
  secret_id = local.devconnect_oauth_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"

  depends_on = [google_developer_connect_connection.dataform_github]
}

# GitHub App OAuth の状態確認用 output
# action_uri が表示された場合はブラウザで OAuth を完了させること
output "devconnect_installation_state" {
  description = "Developer Connect GitHub App OAuth の状態。action_uri が表示された場合はブラウザで承認が必要。"
  value       = length(google_developer_connect_connection.dataform_github) > 0 ? google_developer_connect_connection.dataform_github[0].installation_state : []
}
