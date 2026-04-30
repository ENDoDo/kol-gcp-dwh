# BQ → FTP → Bubble データ連携フロー 詳細ドキュメント

## 1. 全体アーキテクチャ概要

```
KOLデータ更新
    ↓
BigQuery (kolbi_keiba.*) ←── ローダーCF（別リポジトリ）
    ↓ [Logging Sink → Pub/Sub]
Dispatcher CF（デバウンス5分）
    ↓ [Cloud Tasks]
Cloud Workflows
    ↓ [ポーリングで完了待機]
Dataform（BQマートテーブル生成）
    ↓ [完了後、順次HTTP呼び出し]
Export CF群（3本）
    ↓ [FTP STOR]
FTP サーバー (smartkb.mixh.jp)
    ↓ [CSV URL通知]
Bubble Workflow API → Bubble DB取り込み
```

---

## 2. トリガー：BQテーブル更新の検知

### 仕組み

Cloud Logging の **Logging Sink** が BigQuery のジョブ完了ログを監視。以下テーブルへの書き込み完了を検知すると Pub/Sub トピックにメッセージを publish する。

**監視対象テーブル（ソーススキーマ）:**

| テーブル | 内容 |
|---------|------|
| `kol_den1` | レース情報（出馬表レース面） |
| `kol_den2` | 出走馬情報（出馬表馬面） |
| `kol_ket` | 血統情報 |
| `kol_sei1` | 競走成績レース面 |
| `kol_sei2` | 競走成績出走馬面 |

- stg: `kolbi_keiba_stg.*`
- prd: `kolbi_keiba.*`

**Logging Sink フィルタ条件:**
- `resource.type = "bigquery_resource"`
- `protoPayload.methodName = "jobservice.jobcompleted"`
- Load ジョブの場合は `totalLoadOutputBytes > 0`（空ロードは無視）

---

## 3. Dispatcher CF：デバウンス処理

**Cloud Function 名:** `dispatcher`
**ソース:** `functions/dispatcher/main.py`

Pub/Sub メッセージが来るたびに呼ばれるが、短時間に連続してデータが来ても Dataform を何度も起動しないためのデバウンス機構。

### ロジック

1. Eventarc が Pub/Sub トピックのメッセージを受信し、Dispatcher CF を HTTP で呼び出す
2. Dispatcher は現在時刻を `DEBOUNCE_SECONDS`（デフォルト **300秒 = 5分**）で割り、ウィンドウ番号を計算
3. そのウィンドウ番号を名前とした Cloud Tasks タスク（`dataform-debounce-{window_index}`）を **現在時刻 + 5分後** に実行するよう登録
4. 同じウィンドウ内に再度呼ばれた場合、タスク名が衝突して `AlreadyExists` → **スキップ（デバウンス成立）**
5. 5分後に Cloud Tasks がタスクを実行 → Cloud Workflows を起動

**効果:** 5分以内に複数ファイルが届いても Dataform は1回だけ実行される。

---

## 4. Cloud Workflows：Dataform実行 → Export順次呼び出し

**Workflow 名:**
- stg: `dataform-trigger-workflow-stg`
- prd: `dataform-trigger-workflow`

**ソース:** `terraform/workflows.tf`

### ステップ詳細

```
Step 1: createCompilationResult
  → Dataform API: compilationResults 作成
  → gitCommitish: "main"（mainブランチのコードを使用）
  → vars.source_schema: "kolbi_keiba" or "kolbi_keiba_stg"

Step 2: createWorkflowInvocation
  → Dataform API: workflowInvocations 作成（非同期）
  → includedTags: argsで渡されたタグ（スケジュール起動時は ["odds"]）

Step 3: waitForDataform（30秒 sleep → ポーリング）
  → Dataform の state が "RUNNING"/"CANCELING" の間、30秒待機を繰り返す
  → "SUCCEEDED" になるまで待機
  → それ以外（FAILED など）は Workflow を終了

Step 4: callExportScheduleFunction（timeout: 600秒）

Step 5: callExportRacesFunction（timeout: 600秒）

Step 6: callExportRaceUmaDetailBubbleFunction（timeout: 1800秒）

Step 7: returnResult
  → 各ステップの結果をまとめて返す
```

> Export CF の3本は**順次実行**（並列ではない）。前の CF が完了してから次が呼ばれる。

---

## 5. Export CF群：BQ → CSV → FTP → Bubble通知

3本の Export CF はすべて同じパターンを踏む。

### 共通フロー

```
1. BigQuery クエリ（差分抽出）
2. 差分行の CSV 生成（チャンク単位）
3. FTP アップロード（CSV ファイル）
4. Bubble Workflow API へ URL 通知（CSVチャンクごと）
5. BigQuery 状態管理テーブル更新（MERGE）
```

---

### 5-1. export_schedules（スケジュール）

**ソース:** `functions/export_schedules/main.py`

| 項目 | 値 |
|------|---|
| 対象BQテーブル | `kolbi_analysis.schedule` |
| 状態管理テーブル | `schedules_export_state`（主キー: `schedule_id`） |
| チャンクサイズ | 1,000件/ファイル |
| メモリ | 512MB |
| タイムアウト | 540秒 |
| FTPディレクトリ | `/production` or `/development` |
| Bubble API endpoint (prd) | `https://member.kol-bi.jp/api/1.1/wf/import_schedule` |
| Bubble API endpoint (stg) | `https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_schedule` |

**ハッシュ除外フィールド:** `created`, `modified`（毎回変わるため差分検知から除外）

**CSVファイル名パターン:**
- 分割なし: `schedule_{min_id}_{max_id}.csv`
- 分割あり: `schedule_{min_id}_{max_id}_part001.csv`

**Bubble通知タイミング:** FTPアップロード完了後、まとめて通知（全チャンクの最後のファイルのURLを送信）

---

### 5-2. export_races（レース情報）

**ソース:** `functions/export_races/main.py`

| 項目 | 値 |
|------|---|
| 対象BQテーブル | `kolbi_analysis.race` |
| 状態管理テーブル | `races_export_state`（主キー: `race_code_kol`） |
| チャンクサイズ | 1,000件/ファイル |
| メモリ | 512MB |
| タイムアウト | 540秒 |
| FTPディレクトリ | `/production` or `/development` |
| Bubble API endpoint (prd) | `https://member.kol-bi.jp/api/1.1/wf/import_race` |
| Bubble API endpoint (stg) | `https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_race` |

**ハッシュ除外フィールド:** `created`, `modified`

**日付抽出:** `hasso_date`（datetime オブジェクト）から `YYYYMMDD` を抽出してファイル名に使用

**CSVファイル名パターン:**
- 分割なし: `race_{from_date}_{to_date}.csv`
- 分割あり: `race_{from_date}_{to_date}_part001.csv`

**Bubble通知タイミング:** チャンクごとにFTPアップロード直後に通知（チャンク1件ごとにBubble APIを叩く）

---

### 5-3. export_race_uma_detail_bubble（馬詳細）

**ソース:** `functions/export_race_uma_detail_bubble/main.py`

| 項目 | 値 |
|------|---|
| 対象BQテーブル | `kolbi_analysis.race_uma_detail_bubble` |
| 状態管理テーブル | `race_uma_detail_bubble_export_state`（主キー: `race_code_uma_kol`） |
| チャンクサイズ | 1,000件/ファイル |
| メモリ | **8192MB（8GB）** |
| CPU | **4コア** |
| タイムアウト | **3600秒（1時間）** |
| FTPディレクトリ | `/production` or `/development` |
| Bubble API endpoint (prd) | `https://member.kol-bi.jp/api/1.1/wf/import_race_uma_detail` |
| Bubble API endpoint (stg) | `https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_race_uma_detail` |

**データ量が多いためメモリ・時間が大幅に大きく設定されている。**

**ハッシュ計算の特徴:**
- Python側でなく **BQ側（SQL）でハッシュ計算**（`MD5(TO_JSON_STRING(...))`）することでメモリ負荷を軽減
- ハッシュ除外フィールド: `created`, `modified`, `shirushi_shirushi_label`, `shirushi_shirushi_num`, `torikeshi_tosu_num`, `toroku_tosu_num`, `yosou_tansho_ninkijun_num`, `yosou_tansho_odds_float`（頻繁に変わる予想系・集計系を除外して不要な再送を防ぐ）

**ストリーミング処理:** BQクエリ結果を全件 `list()` せず **イテレータで1件ずつ**処理してメモリを節約。1000件溜まるたびにFTPアップロード＋Bubble通知。

**CSVファイル名パターン（常に part 番号付き）:**
- `race_uma_detail_bubble_{from_date}_{to_date}_part001.csv`

---

## 6. FTPサーバー詳細

| 項目 | 値 |
|------|---|
| ホスト | `smartkb.mixh.jp` |
| 認証情報 | Secret Manager: `kol_ftp_bubble_username` / `kol_ftp_bubble_password` |
| prd ディレクトリ | `/production/` |
| stg ディレクトリ | `/development/` |
| CSV公開URL ベース | `https://kol-bi.jp/umasiri.dev` |
| 接続方式 | plain FTP（`ftplib.FTP`）、`STOR` コマンドでバイナリ転送 |

**公開URLの構成例:**
```
https://kol-bi.jp/umasiri.dev/production/race_uma_detail_bubble_20260401_20260430_part001.csv
```

---

## 7. Bubble Workflow API 通知の仕組み

### リクエスト形式

```http
POST {BUBBLE_API_URL}
Authorization: Bearer {kol_bubble_workflow_api_key}
Content-Type: application/json

{
  "csv_url": "https://kol-bi.jp/umasiri.dev/production/race_{from}_{to}.csv"
}
```

FTP にアップロードした CSV の **公開URL** を Bubble に渡す。Bubble 側がその URL から CSV を取得してインポートする構造。

### レスポンス処理

Bubble API は HTTP 200 でも内部的にインポートが失敗することがある。以下を確認している：

```json
{
  "response": {
    "is_import_success": false,
    "error_text": "..."
  }
}
```

キーの表記ゆれに注意: `"is_import_success"` と `"is import success"`（スペース区切り）、`"error_text"` と `"error text"` の両方を考慮済み。

**特例処理:** `"短時間で同じファイルの取り込みを検知したため中止"` というエラーは Bubble 側の重複防止機能。例外扱いにせず `WARNING` ログだけ出して続行する。

---

## 8. 差分検知（状態管理）の仕組み

3本の CF すべてが同じパターンで差分検知を行う。

### 状態管理テーブル構造

```sql
-- 例: races_export_state
race_code_kol  STRING    NOT NULL  -- 主キー
content_hash   STRING    NOT NULL  -- SHA256 or MD5 ハッシュ
exported_at    TIMESTAMP NOT NULL  -- 最終エクスポート日時
```

### 差分検知ロジック

```
1. BQ の現在データを全件取得
2. 状態管理テーブルと LEFT JOIN
3. old_hash が NULL（新規） or 現在ハッシュと不一致（更新）の行を抽出
4. 抽出行のみ CSV 化・FTP 送信・Bubble 通知
5. 処理後に状態管理テーブルを MERGE（UPSERT）で更新
```

### 一時テーブルを使った MERGE パターン

大量の状態更新を効率的に行うため：
1. 更新データを `temp_*_state_updates` テーブルに `WRITE_TRUNCATE` でロード
2. `MERGE` 文で本体テーブルに UPSERT
3. 一時テーブルを削除

---

## 9. 認証・シークレット管理

| シークレット名 | 用途 | 参照している CF |
|-------------|------|----------------|
| `kol_ftp_bubble_username` | FTP 認証ユーザー名 | 全 Export CF |
| `kol_ftp_bubble_password` | FTP 認証パスワード | 全 Export CF |
| `kol_bubble_workflow_api_key` | Bubble API Bearer Token | export_races, export_race_uma_detail_bubble |

Secret Manager のパス形式: `projects/56638639323/secrets/{シークレット名}/versions/latest`

---

## 10. 環境別設定サマリー

| 項目 | Staging (stg) | Production (prd) |
|------|--------------|-----------------|
| BQ データセット | `kolbi_analysis_stg` | `kolbi_analysis` |
| ソーススキーマ | `kolbi_keiba_stg` | `kolbi_keiba` |
| FTP ディレクトリ | `/development` | `/production` |
| Bubble API ドメイン | `temp-toreyomi-20260228.bubbleapps.io` | `member.kol-bi.jp` |
| **ENABLE_BUBBLE_API** | **false**（現在無効） | **false**（現在無効） |

> **注意:** 現時点（2026-04-29）では stg・prd ともに `enable_bubble_api = false` になっており、FTPアップロードは行われるが Bubble への通知は**スキップ**されている。有効化する場合は各環境の `.tfvars` を `true` に変更して `terraform apply` が必要。

---

## 11. トラブルシューティング

| 症状 | 確認ポイント |
|------|-------------|
| Dataform が起動しない | Cloud Logging Sink / Pub/Sub / Eventarc / Dispatcher CF のログを確認 |
| Export CF が起動しない | Cloud Workflows のログ・ステップを確認（Dataform が SUCCEEDED になっているか）|
| FTP アップロード失敗 | `smartkb.mixh.jp` の接続確認、Secret Manager のパスワード確認 |
| Bubble API が 4xx | API Key（`kol_bubble_workflow_api_key`）の有効期限・権限を確認 |
| Bubble が `is_import_success: false` | CSV URL が公開アクセス可能か確認。短時間の重複送信は WARNING 扱いで無視される |
| Export は動いているが Bubble に届かない | `ENABLE_BUBBLE_API` 環境変数が `false` になっていないか確認 |

---

## 12. Dispatcher の Cloud Tasks 詳細

**ソース:** `terraform/dispatcher.tf`

### Cloud Tasks キュー

| 項目 | 値 |
|------|---|
| キュー名 (prd) | `dataform-trigger-queue` |
| キュー名 (stg) | `dataform-trigger-queue-stg` |
| リージョン | `asia-northeast1` |

### Dispatcher Cloud Function のスペック

| 項目 | 値 |
|------|---|
| CF 名 (prd) | `dataform-dispatcher-function` |
| CF 名 (stg) | `dataform-dispatcher-function-stg` |
| メモリ | 256Mi |
| タイムアウト | 60秒 |
| 最大インスタンス数 | 10（同時多発のイベントに対応） |
| SA | `dataform-dispatcher-sa` |

### IAM 権限の連鎖

```
Dispatcher SA
  → roles/cloudtasks.enqueuer（タスクをキューに積む権限）
  → roles/iam.serviceAccountUser on Workflows SA（OIDC トークン生成のための ActAs）

Workflows SA
  → roles/workflows.invoker（Cloud Workflows を実行する権限）
  → roles/run.invoker on Dispatcher CF（Eventarc からの呼び出し用）
```

---

## 13. Dataform リポジトリ・ワークフロー設定

**ソース:** `terraform/dataform.tf`

### リポジトリ

| 項目 | 値 |
|------|---|
| GitHub リポジトリ | `https://github.com/ENDoDo/kol-gcp-dataform.git` |
| ブランチ | `main` |
| 認証 | Secret Manager: `github-token` |
| リポジトリ名 (prd) | `kol-dataform-repo` |
| リポジトリ名 (stg) | `kol-dataform-repo-stg` |

### Dataform Workflow Config（Terraform 管理のスケジュール設定）

Terraform で `google_dataform_repository_workflow_config` として定義されている定時実行設定（`daily-race-table-update`）。Export の起点となる Cloud Workflows とは別物。

**対象テーブル（included_targets）:**

| テーブル | 備考 |
|---------|------|
| `race` | レースマスター |
| `race_uma` | 出走馬ワイドテーブル |
| `race_uma_detail_bubble` | Bubble 向け詳細ビュー |
| `race_uma_detail_looker` | Looker 向け詳細ビュー |
| `schedule` | 開催スケジュール |
| `race_hit` | 的中判定・配当 |
| `race_kekka_hassojokyo` | 発走状況 |
| `race_kekka_keika` | レース経過情報 |
| `race_kekka_time` | ラップタイム |
| `race_kekka_haraimodoshi` | 払戻情報 |

**タイムゾーン:** `Asia/Tokyo`

### Dataform Runner SA の権限

| ロール | 対象 |
|-------|------|
| `roles/bigquery.dataEditor` | プロジェクト全体 |
| `roles/bigquery.jobUser` | プロジェクト全体 |
| `roles/bigquery.dataEditor` | 出力先データセット（明示付与） |
| `roles/bigquery.metadataViewer` | prd データセット（stg Runner のみ） |

---

## 14. サービスアカウント一覧

| SA 名 (prd) | 役割 |
|------------|------|
| `dataform-runner@smartkeiba.iam.gserviceaccount.com` | Dataform 実行・BQ 書き込み |
| `dataform-workflows-sa@smartkeiba.iam.gserviceaccount.com` | Cloud Workflows 実行・Export CF 呼び出し |
| `dataform-dispatcher-sa@smartkeiba.iam.gserviceaccount.com` | Dispatcher CF・Cloud Tasks エンキュー |
| `export-schedules-sa@smartkeiba.iam.gserviceaccount.com` | export_schedules / export_races CF 共用 |
| `export-race-uma-bubble-sa@smartkeiba.iam.gserviceaccount.com` | export_race_uma_detail_bubble CF |

stg 環境では各 SA 名の末尾に `-stg` が付く（例: `dataform-runner-stg`）。

---

## 15. デプロイ・変更手順

### Dataform SQL の変更（definitions/ 以下）

```bash
# main にマージするだけで Dataform リポジトリが自動更新される
# Terraform 操作は不要
git push origin main  # PR マージ後、Dataform が main ブランチを参照
```

### Cloud Functions の変更（functions/ 以下）

```bash
# Terraform apply で関数を再デプロイ
cd terraform
terraform workspace select stg
terraform apply -var-file="stg.tfvars"

# または prd
terraform workspace select prd
terraform apply -var-file="prd.tfvars"
```

### Bubble API の有効化・無効化

`terraform/stg.tfvars` または `terraform/prd.tfvars` を編集して `terraform apply`：

```hcl
# 有効化する場合
enable_bubble_api = true

# 無効化する場合
enable_bubble_api = false
```

`ENABLE_BUBBLE_API` は Cloud Function の環境変数として注入される。`false` の場合、FTP アップロードは実行されるが Bubble への HTTP リクエストはスキップされる。

### Workflows の変更

`terraform/workflows.tf` を編集して `terraform apply`。Workflow のソースはインライン YAML で定義されているため、Terraform 管理下にある。

---

## 16. GCP リソース名まとめ（prd）

| リソース種別 | 名前 |
|------------|------|
| Dataform リポジトリ | `kol-dataform-repo` |
| Cloud Workflows | `dataform-trigger-workflow` |
| Cloud Tasks キュー | `dataform-trigger-queue` |
| Dispatcher CF | `dataform-dispatcher-function` |
| export_schedules CF | `export-schedules-function` |
| export_races CF | `export-races-function` |
| export_race_uma_detail_bubble CF | `export-race-uma-details-function` |
| Logging Sink | `bq-kol-den1-update-sink` |
| Pub/Sub トピック | `dataform-trigger-topic` |
| Eventarc トリガー | `dataform-workflow-trigger` |
| CF ソースバケット | `kol-function-source-smartkeiba` |

stg 環境では各リソース名末尾に `-stg` が付く。
