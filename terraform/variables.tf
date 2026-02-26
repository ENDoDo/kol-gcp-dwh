# -----------------------------------------------------------------------------
# Input Variables
#
# このファイルは、Terraform構成で使用されるすべての入力変数を定義します。
# デフォルト値を設定することで、実行時に毎回指定する必要がなくなります。
# 環境ごとに設定を変更したい場合は、`.tfvars`ファイルを使用するのが一般的です。
# -----------------------------------------------------------------------------

# リソースを作成するGCPプロジェクトのID。
variable "project_id" {
  description = "The GCP project ID."
  type        = string
  default     = "smartkeiba"
}

# リソースをデプロイするGCPリージョン。
variable "region" {
  description = "The GCP region to deploy resources in."
  type        = string
  default     = "asia-northeast1"
}

# Dataformリポジトリの名前。
variable "dataform_repository_id" {
  description = "The ID of the Dataform repository."
  type        = string
  default     = "kol-dataform-repo"
}

# Dataformワークスペースの名前。
variable "dataform_workspace_id" {
  description = "The ID of the Dataform workspace."
  type        = string
  default     = "kol-dataform-ws"
}

# Dataformがテーブルを作成するBigQueryデータセット（スキーマ）。
variable "prd_schema" {
  description = "The BigQuery schema for the production environment."
  type        = string
  default     = "kolbi_analysis"
}

variable "stg_schema" {
  description = "The BigQuery schema for the staging environment."
  type        = string
  default     = "kolbi_analysis_stg"
}

# Bubble APIを有効にするかどうか。
variable "enable_bubble_api" {
  description = "Enable calling Bubble API."
  type        = bool
  default     = true
}

# GCSバケットへのアップロードを許可するユーザーのメールアドレスリスト
variable "client_upload_users" {
  description = "List of user email addresses granted upload access to the GCS bucket."
  type        = list(string)
  default     = []
}