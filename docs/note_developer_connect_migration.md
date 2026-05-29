# DataformのGitHub認証をPATからDeveloper Connectに移行した話

---

## はじめに：Dataformが突然動かなくなった日

ある朝、Cloud Schedulerで起動したDataformワークフローがエラーを返してきた。

```
Error: failed to fetch remote repository
authentication failed
```

原因はすぐわかった。**GitHubのPersonal Access Token（PAT）の有効期限が切れていた。**

PATを再発行してSecret Managerに登録し直す。15分で解決はしたが、「次はいつ同じことが起きるんだろう」という不安が残った。

PAT運用には3つの課題がある。

1. **有効期限切れ** — GitHubのPATには有効期限があり、切れると即座にDataformの同期が止まる
2. **手動ローテーション** — 更新のたびに人間がSecret Managerに値を入れ直す必要がある
3. **個人アカウント依存** — PATは発行した人のアカウントに紐づくため、その人が退職・権限変更されると連鎖的に壊れる

このときから **Google Cloud Developer Connect** への移行を検討し始め、実際に移行した。この記事はその記録だ。

---

## Developer Connectとは

**Developer Connect** はGoogleが提供するマネージドなソースコード接続サービスだ。GitHub AppベースのOAuth認証を使い、GCPがトークンの発行・ローテーションを自動管理してくれる。

移行後のフローはこうなる。

```
GitHub リポジトリ
  ↑ HTTPS（GitHub App経由）
Developer Connect
  ↓ OAuthトークンを自動生成・ローテーション
Secret Manager（versions/latest で常に最新を参照）
  ↓
Dataform サービスエージェント
  ↓
Dataform リポジトリ（GitHub と自動同期）
```

ポイントは **「人間がトークンを触らない」** という点だ。Developer ConnectのサービスエージェントがSecret Managerにトークンを書き込み、自動でローテーションする。DataformはSecret Managerから `versions/latest` で常に有効なトークンを読む。PAT運用で発生していた手動作業がゼロになる。

---

## 移行手順（Terraform）

以下のTerraformコードをそのまま使って移行できる。プレースホルダーは自分の環境に合わせて置き換えること。

| プレースホルダー | 置き換え例 |
|----------------|-----------|
| `YOUR_PROJECT_ID` | `my-gcp-project` |
| `YOUR_REGION` | `asia-northeast1` |
| `YOUR_GITHUB_REPO_URL` | `https://github.com/your-org/your-repo.git` |
| `YOUR_DATAFORM_REPO_NAME` | `my-dataform-repo` |
| `YOUR_DATAFORM_SA_EMAIL` | `dataform-runner@my-gcp-project.iam.gserviceaccount.com` |

---

### Step 1: APIの有効化

```hcl
resource "google_project_service" "developerconnect" {
  project            = var.project_id
  service            = "developerconnect.googleapis.com"
  disable_on_destroy = false
}
```

---

### Step 2: Developer ConnectのサービスエージェントとIAM設定

```hcl
# Developer Connect サービスエージェント（P4SA）の作成
resource "google_project_service_identity" "devconnect_p4sa" {
  provider   = google-beta
  project    = var.project_id
  service    = "developerconnect.googleapis.com"
  depends_on = [google_project_service.developerconnect]
}

# P4SA に Secret Manager Admin 権限を付与
# Developer Connect がトークンをSecret Managerに自動書き込みするために必要
resource "google_project_iam_member" "devconnect_secret_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = google_project_service_identity.devconnect_p4sa.member
}

# Dataform SAに Developer Connect トークン取得権限を付与
resource "google_project_iam_member" "dataform_token_accessor" {
  project = var.project_id
  role    = "roles/developerconnect.tokenAccessor"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"
}

# Dataform SAに Git Proxy 使用権限を付与
resource "google_project_iam_member" "dataform_git_proxy_user" {
  project = var.project_id
  role    = "roles/developerconnect.gitProxyUser"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"
}

data "google_project" "project" {}
```

---

### Step 3: Developer Connect接続の作成

```hcl
resource "google_developer_connect_connection" "github" {
  provider      = google-beta
  project       = var.project_id
  location      = var.region  # 例: "asia-northeast1"
  connection_id = "my-dataform-github"

  github_config {
    github_app = "DEVELOPER_CONNECT"
    # OAuth完了後に app_installation_id を設定する（後述）
  }

  lifecycle {
    ignore_changes = [github_config]
  }

  depends_on = [
    google_project_iam_member.devconnect_secret_admin,
    google_project_service.developerconnect,
  ]
}

# GitHubリポジトリリンク（OAuth承認完了後に apply する）
resource "google_developer_connect_git_repository_link" "repo" {
  provider               = google-beta
  project                = var.project_id
  location               = var.region
  parent_connection      = google_developer_connect_connection.github.connection_id
  git_repository_link_id = "my-repo-link"
  clone_uri              = "YOUR_GITHUB_REPO_URL"

  depends_on = [google_developer_connect_connection.github]
}
```

`terraform apply` 後、接続はまだ `PENDING` 状態だ。次のステップでOAuth承認を行う。

---

### Step 4: GitHubでOAuth承認（手動・初回のみ）

```bash
gcloud developer-connect connections describe my-dataform-github \
  --location=YOUR_REGION \
  --project=YOUR_PROJECT_ID \
  --format="json(installationState)"
```

出力された `actionUri` をブラウザで開き、GitHubアカウントでサインインして **Google Cloud Developer Connect** アプリへのアクセスを承認する。

承認後、GitHub の [Settings > Installed GitHub Apps](https://github.com/settings/installations) を開き、**Google Cloud Developer Connect** の `Configure` ボタンのURLに含まれる数字（`installation_id`）を確認する。

```hcl
# developer_connect.tf の github_config を更新
github_config {
  github_app          = "DEVELOPER_CONNECT"
  app_installation_id = 12345678  # ← 確認した数字
}
```

`lifecycle { ignore_changes = [github_config] }` を削除して再度 `terraform apply` する。

---

### Step 5: DataformリポジトリにOAuthトークンを紐づける

Developer Connectが自動生成したOAuthトークンのシークレット名を `locals` で管理する。

```hcl
locals {
  # Developer Connectが自動生成するシークレット名
  # 接続作成後、Secret Managerコンソールで "oauthtoken" を含むシークレットを確認して設定する
  devconnect_oauth_secret_id = "my-dataform-github-oauthtoken-XXXXXX"
}

# Dataform SAにシークレットの読み取り権限を付与
resource "google_secret_manager_secret_iam_member" "dataform_oauth_accessor" {
  project   = var.project_id
  secret_id = local.devconnect_oauth_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"

  depends_on = [google_developer_connect_connection.github]
}

# Dataformリポジトリ
resource "google_dataform_repository" "repo" {
  provider = google-beta
  project  = var.project_id
  region   = var.region
  name     = "YOUR_DATAFORM_REPO_NAME"

  git_remote_settings {
    url            = "YOUR_GITHUB_REPO_URL"
    default_branch = "main"
    # versions/latest で常に有効なトークンを参照
    authentication_token_secret_version = "projects/${data.google_project.project.number}/secrets/${local.devconnect_oauth_secret_id}/versions/latest"
  }

  depends_on = [
    google_secret_manager_secret_iam_member.dataform_oauth_accessor,
    google_developer_connect_git_repository_link.repo,
  ]
}
```

シークレット名の `XXXXXX` 部分は接続作成後に Secret Manager コンソールで確認できる。`oauthtoken` というキーワードで検索すれば一発で見つかる。

---

## ハマりポイント3選

移行中に詰まった点をまとめる。

### 1. `roles/secretmanager.admin` はプロジェクト全体に付与が必要

Developer ConnectのP4SAは、OAuthトークン格納用のシークレットを**自分で作成する**。そのため `roles/secretmanager.secretAccessor` ではなく `roles/secretmanager.admin` が必要になる。

「管理者権限をプロジェクト全体に付与するのは広すぎでは？」と感じるかもしれないが、これはGCPの仕様だ。シークレット作成前は特定シークレットにスコープできないため、プロジェクト全体への付与が避けられない。逆にDataform SAへのアクセス権はシークレット単位で絞っているのでバランスは取れている。

### 2. 接続を再作成するとシークレット名のサフィックスが変わる

`kol-dataform-github-oauthtoken-89081c` の末尾 `89081c` は接続ごとに変わるランダムなサフィックスだ。接続を削除・再作成すると別のシークレット名で新しいトークンが生成される。

`locals` でシークレット名を一元管理しておき、再作成時は必ずその値を更新すること。Dataformリポジトリが古いシークレットを参照したままになると認証エラーになる。

### 3. `versions/latest` が肝心

`authentication_token_secret_version` に特定のバージョン（`versions/1`など）を指定してはいけない。Developer Connectはトークンをローテーションするたびに新しいバージョンをSecret Managerに追加する。`versions/latest` を指定することで、常に有効なトークンを自動で参照できる。

---

## まとめ

Developer Connectへの移行後、GitHub認証まわりの運用コストはほぼゼロになった。

| | PAT運用 | Developer Connect |
|--|--------|-------------------|
| トークン有効期限切れ | 定期的に発生 | なし（自動ローテーション） |
| 手動更新作業 | 毎回必要 | 不要 |
| 個人アカウント依存 | あり | なし（GCPマネージド） |
| Terraform管理 | シークレット値の手動登録が別途必要 | 接続リソースのみ管理 |

初回セットアップでブラウザ操作が1回だけ必要なのは変わらないが、それ以降は完全に自動だ。Dataformを本番運用しているチームなら早めに移行しておくことをお勧めする。

---

*本記事のTerraformコードは `google-beta` プロバイダーを使用しています（2025年時点でDeveloper Connect関連リソースはbetaチャンネルのみ提供）。本番適用前に必ず `terraform plan` で差分を確認してください。*
