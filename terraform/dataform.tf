# -----------------------------------------------------------------------------
# Dataform Resources
# -----------------------------------------------------------------------------

# --- 動的命名のためのローカル変数 ---
locals {
  # prd環境ではsuffixを付けず、stg環境では "-stg" を付与する
  env_suffix = terraform.workspace == "prd" ? "" : "-${terraform.workspace}"

  # Dataformの出力先スキーマを環境によって切り替える
  # prdの場合はvar.prd_schemaを、それ以外(stg)の場合はvar.stg_schemaを使用する
  dataform_output_schema = terraform.workspace == "prd" ? var.prd_schema : var.stg_schema

  # Dataformのソーススキーマを環境によって切り替える
  # prdの場合は "kolbi_keiba" を、それ以外(stg)の場合は "kolbi_keiba_stg" を使用する
  dataform_source_schema = terraform.workspace == "prd" ? "kolbi_keiba" : "kolbi_keiba_stg"

  # Developer Connect が自動生成・管理する GitHub OAuth トークンのシークレット名
  # 接続を再作成するとサフィックスが変わるため、ここで一元管理する
  devconnect_oauth_secret_id = "kol-dataform-github-oauthtoken-89081c"
}

# --- API Services ---
resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dataform" {
  project            = var.project_id
  service            = "dataform.googleapis.com"
  disable_on_destroy = false
}

# --- BigQuery Dataset for Dataform Output ---
resource "google_bigquery_dataset" "dataform_output" {
  dataset_id  = local.dataform_output_schema
  project     = var.project_id
  location    = var.region
  description = "Dataset for Dataform output (${terraform.workspace} environment)"
}

# --- Service Account for Dataform Runner ---
# DataformがBigQueryなどのGCPリソースにアクセスするためのサービスアカウント。
resource "google_service_account" "dataform" {
  account_id   = "dataform-runner${local.env_suffix}"
  display_name = "Dataform Runner Service Account${local.env_suffix}"
  project      = var.project_id
}

# サービスアカウントにBigQueryを操作するためのロールを付与
resource "google_project_iam_member" "dataform_bigquery_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.dataform.email}"
}

resource "google_project_iam_member" "dataform_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataform.email}"
}

# Dataform Runnerに自身の出力先データセットへの権限を明示的に付与
# プロジェクトレベルの権限だけではINFORMATION_SCHEMAの参照などでエラーになる場合があるため
resource "google_bigquery_dataset_iam_member" "runner_output_data_editor" {
  project    = var.project_id
  dataset_id = local.dataform_output_schema
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dataform.email}"
}

# stg環境のDataform Runnerがprd環境のデータセット(kolbi_analysis)のメタデータを参照できるようにする
# これにより、INFORMATION_SCHEMAへのアクセスが可能になる
resource "google_bigquery_dataset_iam_member" "stg_runner_prd_metadata_viewer" {
  count      = terraform.workspace == "prd" ? 0 : 1
  project    = var.project_id
  dataset_id = var.prd_schema
  role       = "roles/bigquery.metadataViewer"
  member     = "serviceAccount:${google_service_account.dataform.email}"
}

# --- Dataform Repository and Configurations ---
# --- Dataform Repository and Configurations (Staging) ---
resource "google_dataform_repository" "repository_stg" {
  count    = terraform.workspace != "prd" ? 1 : 0
  provider = google-beta.beta
  project  = var.project_id
  region   = var.region
  name     = "${var.dataform_repository_id}-stg"

  git_remote_settings {
    url            = "https://github.com/ENDoDo/kol-gcp-dwh.git"
    default_branch = "main"
    # Developer Connect が管理する GitHub OAuth トークンを使用（手動 PAT ではない）
    # Developer Connect がトークンをローテーションすると新バージョンが作成され、
    # versions/latest で常に有効なトークンを参照できる
    authentication_token_secret_version = "projects/${data.google_project.project.number}/secrets/${local.devconnect_oauth_secret_id}/versions/latest"
  }

  depends_on = [
    google_project_iam_member.dataform_bigquery_data_editor,
    google_project_iam_member.dataform_bigquery_job_user,
    google_project_service.dataform,
    google_developer_connect_git_repository_link.kol_dataform_repo,
    google_secret_manager_secret_iam_member.dataform_devconnect_oauth_accessor,
  ]
}

resource "google_dataform_repository_release_config" "release_config_stg" {
  count         = terraform.workspace != "prd" ? 1 : 0
  provider      = google-beta.beta
  project       = google_dataform_repository.repository_stg[0].project
  region        = google_dataform_repository.repository_stg[0].region
  repository    = google_dataform_repository.repository_stg[0].name
  name          = "production-release-stg"
  git_commitish = "main"

  code_compilation_config {
    default_database = var.project_id
    default_schema   = var.stg_schema
    vars = {
      source_schema = "kolbi_keiba_stg"
    }
  }
}

resource "google_dataform_repository_workflow_config" "workflow_stg" {
  count          = terraform.workspace != "prd" ? 1 : 0
  provider       = google-beta.beta
  project        = google_dataform_repository.repository_stg[0].project
  region         = google_dataform_repository.repository_stg[0].region
  repository     = google_dataform_repository.repository_stg[0].name
  name           = "daily-race-table-update-stg"
  release_config = google_dataform_repository_release_config.release_config_stg[0].id

  invocation_config {
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_uma"
    }

    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_uma_detail_bubble"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_uma_detail_looker"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_uma_detail_looker_mv"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "schedule"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_hit"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_kekka_hassojokyo"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_kekka_keika"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_kekka_time"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "race_kekka_haraimodoshi"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "tokubetsu_race"
    }
    included_targets {
      database = var.project_id
      schema   = var.stg_schema
      name     = "tokubetsu_race_uma"
    }
    service_account = google_service_account.dataform.email
  }

  time_zone = "Asia/Tokyo"
}

# --- Dataform Repository and Configurations (Production) ---
resource "google_dataform_repository" "repository_prd" {
  count    = terraform.workspace == "prd" ? 1 : 0
  provider = google-beta.beta
  project  = var.project_id
  region   = var.region
  name     = var.dataform_repository_id # kol-dataform-repo

  git_remote_settings {
    url            = "https://github.com/ENDoDo/kol-gcp-dwh.git"
    default_branch = "main"
    # Developer Connect が管理する GitHub OAuth トークンを使用（手動 PAT ではない）
    authentication_token_secret_version = "projects/${data.google_project.project.number}/secrets/${local.devconnect_oauth_secret_id}/versions/latest"
  }

  depends_on = [
    google_project_iam_member.dataform_bigquery_data_editor,
    google_project_iam_member.dataform_bigquery_job_user,
    google_project_service.dataform,
    google_secret_manager_secret_iam_member.dataform_devconnect_oauth_accessor,
  ]
}

resource "google_dataform_repository_release_config" "release_config_prd" {
  count         = terraform.workspace == "prd" ? 1 : 0
  provider      = google-beta.beta
  project       = google_dataform_repository.repository_prd[0].project
  region        = google_dataform_repository.repository_prd[0].region
  repository    = google_dataform_repository.repository_prd[0].name
  name          = "production-release"
  git_commitish = "main"

  code_compilation_config {
    default_database = var.project_id
    default_schema   = var.prd_schema
    vars = {
      source_schema = "kolbi_keiba"
    }
  }
}

resource "google_dataform_repository_workflow_config" "workflow_prd" {
  count          = terraform.workspace == "prd" ? 1 : 0
  provider       = google-beta.beta
  project        = google_dataform_repository.repository_prd[0].project
  region         = google_dataform_repository.repository_prd[0].region
  repository     = google_dataform_repository.repository_prd[0].name
  name           = "daily-race-table-update"
  release_config = google_dataform_repository_release_config.release_config_prd[0].id

  invocation_config {
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_uma"
    }

    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_uma_detail_bubble"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_uma_detail_looker"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_uma_detail_looker_mv"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "schedule"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_hit"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_kekka_hassojokyo"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_kekka_keika"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_kekka_time"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "race_kekka_haraimodoshi"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "tokubetsu_race"
    }
    included_targets {
      database = var.project_id
      schema   = var.prd_schema
      name     = "tokubetsu_race_uma"
    }
    service_account = google_service_account.dataform.email
  }

  time_zone = "Asia/Tokyo"
}

# Dataformサービスエージェントの権限設定に必要なプロジェクト情報を取得
data "google_project" "project" {}

# Dataformサービスエージェントに、カスタムSA(dataform-runner)として振る舞う権限を付与
resource "google_service_account_iam_member" "dataform_agent_impersonator" {
  provider           = google-beta.beta
  service_account_id = google_service_account.dataform.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"
}

# --- Outputs ---
output "dataform_repository_url" {
  description = "URL of the created Dataform repository."
  value       = "https://console.cloud.google.com/bigquery/dataform/locations/${var.region}/repositories/${terraform.workspace == "prd" ? google_dataform_repository.repository_prd[0].name : google_dataform_repository.repository_stg[0].name}?project=${var.project_id}"
}