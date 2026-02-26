# -----------------------------------------------------------------------------
# Storage IAM Configurations
# -----------------------------------------------------------------------------

# クライアントへGCSバケットに対するアップロード権限（作成のみ）を付与
resource "google_storage_bucket_iam_member" "client_object_creator" {
  for_each = toset(var.client_upload_users)

  bucket = "kol-keiba-bucket${local.env_suffix}"
  role   = "roles/storage.objectCreator"
  member = "user:${each.value}"
}

# クライアントがGCPコンソールのブラウザ画面でバケット内を確認できるように閲覧権限を付与
resource "google_storage_bucket_iam_member" "client_object_viewer" {
  for_each = toset(var.client_upload_users)

  bucket = "kol-keiba-bucket${local.env_suffix}"
  role   = "roles/storage.objectViewer"
  member = "user:${each.value}"
}
