# Developer Connect — Dataform GitHub 連携 セットアップガイド

## 概要

このプロジェクトでは、DataformのGitHub認証に **Google Cloud Developer Connect**（GitHub Appベース）を使用しています。手動PAT（Personal Access Token）は廃止されており、Developer ConnectがOAuthトークンのライフサイクルを自動管理します。

---

## アーキテクチャ

```
GitHub (ENDoDo/kol-gcp-dwh)
  ↑ HTTPS clone
Developer Connect (GitHub App: DEVELOPER_CONNECT)
  ↓ OAuthトークンを自動生成・ローテーション
Secret Manager (kol-dataform-github-oauthtoken-89081c / versions/latest)
  ↓ secretAccessor
Dataform サービスエージェント (gcp-sa-dataform.iam.gserviceaccount.com)
  ↓ git_remote_settings.authentication_token_secret_version
Dataform Repository (STG: kol-dataform-repo-stg / PRD: kol-dataform-repo)
```

---

## Terraform リソース構成

### `terraform/developer_connect.tf`

| リソース | 説明 |
|---------|------|
| `google_project_service_identity.devconnect_p4sa` | Developer Connect のサービスエージェント（P4SA）を作成 |
| `google_project_iam_member.devconnect_secret_admin` | P4SAに `roles/secretmanager.admin` を付与（OAuthトークンを Secret Manager に自動書き込みするため） |
| `google_project_iam_member.dataform_devconnect_token_accessor` | Dataform SAに `roles/developerconnect.tokenAccessor` を付与 |
| `google_project_iam_member.dataform_devconnect_git_proxy_user` | Dataform SAに `roles/developerconnect.gitProxyUser` を付与 |
| `google_developer_connect_connection.dataform_github` | Developer Connect 接続（`connection_id: kol-dataform-github`）。**stgワークスペースのみ作成**（プロジェクトスコープのためSTG/PRD両Dataformで共有） |
| `google_developer_connect_git_repository_link.kol_dataform_repo` | GitHubリポジトリリンク（`https://github.com/ENDoDo/kol-gcp-dwh.git`） |
| `google_secret_manager_secret_iam_member.dataform_devconnect_oauth_accessor` | Dataform SAにOAuthトークンシークレットの `roles/secretmanager.secretAccessor` を付与 |

### `terraform/dataform.tf` — 認証トークン参照

Dataformリポジトリ（STG/PRD両方）の `git_remote_settings` で以下のように参照します：

```hcl
authentication_token_secret_version = "projects/${data.google_project.project.number}/secrets/${local.devconnect_oauth_secret_id}/versions/latest"
```

- `local.devconnect_oauth_secret_id = "kol-dataform-github-oauthtoken-89081c"`
- `versions/latest` を指定することで、Developer Connectがトークンをローテーションしても常に有効なトークンを参照できます

---

## 初回セットアップ手順

Developer Connect接続の初回作成には、Terraformによる自動化だけでは完結しない**手動OAuth承認ステップ**があります。

### Step 1: `stg` ワークスペースで `terraform apply`

```bash
cd terraform
terraform workspace select stg
terraform apply -var-file="stg.tfvars" -auto-approve
```

`google_developer_connect_connection.dataform_github` が作成されますが、この時点ではGitHub Appのインストールが未承認のため接続は `PENDING` 状態です。

### Step 2: インストール状態の確認

```bash
gcloud developer-connect connections describe kol-dataform-github \
  --location=asia-northeast1 \
  --project=smartkeiba \
  --format="json(installationState)"
```

`installationState.stage` が `PENDING_USER_OAUTH` の場合、`actionUri` が返されます。

### Step 3: ブラウザでOAuth承認

`actionUri` をブラウザで開き、GitHubアカウントでサインインして **Google Cloud Developer Connect** アプリへのアクセスを承認します。

### Step 4: `app_installation_id` の確認と設定

承認後、GitHub の [Settings > Installations](https://github.com/settings/installations) を開き、**Google Cloud Developer Connect** の `Configure` URL末尾の数字を確認します。

`developer_connect.tf` の `app_installation_id` にその値を設定し、`ignore_changes = [github_config]` を削除してから再度 `terraform apply` を実行します。

```hcl
github_config {
  github_app          = "DEVELOPER_CONNECT"
  app_installation_id = 12345678  # 実際のIDに置き換える
}
```

### Step 5: インストール完了確認

```bash
gcloud developer-connect connections describe kol-dataform-github \
  --location=asia-northeast1 \
  --project=smartkeiba \
  --format="json(installationState)"
```

`installationState.stage` が `COMPLETE` になれば接続完了です。

### Step 6: GitHubリポジトリリンクの作成

`google_developer_connect_git_repository_link.kol_dataform_repo` が `COMPLETE` 後に自動作成されます。`depends_on` が設定されているため、通常は同一 `apply` で連続して作成されます。

### Step 7: `prd` ワークスペースで `terraform apply`

```bash
terraform workspace select prd
terraform apply -var-file="prd.tfvars" -auto-approve
```

PRD環境のDataformリポジトリは、STGで作成済みのDeveloper Connect接続・OAuthトークンシークレットを共有します（Developer ConnectはプロジェクトスコープのためSTGのみ作成）。

---

## トークン管理

| 項目 | 詳細 |
|------|------|
| シークレット名 | `kol-dataform-github-oauthtoken-89081c` |
| 管理主体 | Developer Connect（GCPマネージド） |
| ローテーション | Developer Connectが自動実行（新バージョンとして追記） |
| Dataformの参照方式 | `versions/latest` — 常に最新バージョンを参照 |
| 手動操作 | 不要（手動PAT廃止済み） |

> **注意**: 接続を再作成するとOAuthトークンのシークレット名のサフィックスが変わります（`89081c` の部分）。再作成した場合は `dataform.tf` の `local.devconnect_oauth_secret_id` を新しい名前に更新してください。

---

## IAM権限まとめ

| プリンシパル | ロール | 理由 |
|-------------|--------|------|
| Developer Connect P4SA | `roles/secretmanager.admin`（プロジェクト） | OAuthトークンをSecret Managerに自動書き込み・管理するため |
| Dataform SA (`gcp-sa-dataform`) | `roles/developerconnect.tokenAccessor` | Developer Connectトークンの取得 |
| Dataform SA (`gcp-sa-dataform`) | `roles/developerconnect.gitProxyUser` | Developer Connect Git Proxyの使用 |
| Dataform SA (`gcp-sa-dataform`) | `roles/secretmanager.secretAccessor`（シークレット単位） | OAuthトークンシークレットの読み取り |

---

## トラブルシューティング

### Dataformがリポジトリを同期しない

1. OAuthトークンの最新バージョンが存在するか確認：
   ```bash
   gcloud secrets versions list kol-dataform-github-oauthtoken-89081c --project=smartkeiba
   ```
2. Dataform SAにシークレットのアクセス権があるか確認：
   ```bash
   gcloud secrets get-iam-policy kol-dataform-github-oauthtoken-89081c --project=smartkeiba
   ```
3. Developer Connect接続のステータス確認：
   ```bash
   gcloud developer-connect connections describe kol-dataform-github \
     --location=asia-northeast1 --project=smartkeiba
   ```

### `installationState.stage` が `PENDING_USER_OAUTH` のまま

[Step 3](#step-3-ブラウザでoauth承認) を再実行してください。`actionUri` は `terraform output devconnect_installation_state` でも確認できます。
