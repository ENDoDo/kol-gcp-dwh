# kol-gcp-dwh — Dataform プロジェクト

GCP上に構築された競馬データパイプラインの**データ変換（Transformation）**・**データエクスポート（Reverse ETL）**リポジトリ。  
KOL競馬データをBigQueryで分析用マートに変換し、FTP・Bubble APIへ連携する。

---

## クイックリファレンス

| 操作 | コマンド |
|------|---------|
| Dataform コンパイル確認 | `cd /path/to/repo && npx @dataform/cli compile` |
| Staging デプロイ | `cd terraform && terraform workspace select stg && terraform apply -var-file="stg.tfvars" -auto-approve` |
| Production デプロイ | `cd terraform && terraform workspace select prd && terraform apply -var-file="prd.tfvars" -auto-approve` |
| Terraform 差分確認 | `cd terraform && terraform plan -var-file="stg.tfvars"` |

---

## アーキテクチャ概要

```
KOLデータ(ZIP)
  → GCS
    → Loader CF (Scope Out)
      → BigQuery Raw (kol_keiba.* / kol_keiba_stg.*)
        → Dispatcher CF + Cloud Tasks (デバウンス5分)
          → Cloud Workflows
            → Dataform → BigQuery Mart (kolbi_analysis.*)
              → Export CFs → FTP / Bubble API
```

### 実行トリガー2種
1. **ファイルアップロード・トリガー**: KOLデータ更新時、Eventarc → Dispatcher → Cloud Tasks（5分デバウンス）→ Workflows → Dataform
2. **スケジュール・トリガー**: Cloud Scheduler（6,9,12,15,20時）→ Workflows → Dataform（`tags: odds`のみ実行）

---

## ディレクトリ構成

```
.
├── definitions/          # Dataform SQLXファイル（テーブル定義本体）
│   ├── sources/          # ソース宣言（kol_sources.js）
│   ├── race.sqlx         # レースマスター
│   ├── race_uma.sqlx     # 出走馬ワイドテーブル（最大ファイル 92KB）
│   ├── race_hit.sqlx     # 的中判定・配当テーブル
│   ├── race_kekka_haraimodoshi.sqlx # 払戻情報テーブル
│   ├── race_kekka_hassojokyo.sqlx  # 発走状況（hasso_jokyo1〜6 アンピボット）
│   ├── race_kekka_keika.sqlx       # レース経過情報（race_keika1〜9 アンピボット）
│   ├── race_kekka_time.sqlx        # ラップタイム・通過・上り・ペース
│   ├── schedule.sqlx     # スケジュールテーブル
│   ├── cross_chokyoshi_*.sqlx  # 調教師軸クロス集計テーブル群
│   ├── cross_ketto_f_*.sqlx    # 父馬軸クロス集計テーブル群
│   ├── race_uma_detail_bubble.sqlx  # Bubble向け詳細ビュー
│   ├── race_uma_detail_looker.sqlx  # Looker向け詳細テーブル（Dataform管理）
│   └── race_uma_detail_looker_mv.sqlx  # Looker向けMV（Dataform operations で自動再作成）
├── includes/             # 共通ロジック（JavaScript）
│   ├── race_uma_detail_bubble.js
│   └── race_uma_detail_looker.js
├── functions/            # Cloud Functions ソースコード（Python）
│   ├── dispatcher/       # Dataform起動用ディスパッチャ
│   ├── export_schedules/ # スケジュールexport → FTP/Bubble
│   ├── export_races/     # レース情報export → FTP/Bubble
│   └── export_race_uma_detail_bubble/  # 馬詳細export → Bubble
├── terraform/            # GCPインフラ定義（Terraform）
│   ├── dataform.tf       # Dataformリポジトリ・リリース設定
│   ├── workflows.tf      # Cloud Workflows定義
│   ├── triggers.tf       # Eventarcトリガー
│   ├── functions.tf      # Cloud Functions定義
│   ├── stg.tfvars        # Staging環境変数
│   └── prd.tfvars        # Production環境変数
├── dataform.json         # Dataform設定
└── verification_queries/ # 検証用クエリ（ad-hoc）
```

---

## GCPリソース / スキーマ対応

| 項目 | Staging | Production |
|------|---------|------------|
| GCPプロジェクト | `smartkeiba` | `smartkeiba` |
| Dataformデフォルトスキーマ | `kolbi_analysis_stg` | `kolbi_analysis` |
| ソーススキーマ（変数名: `source_schema`） | `kolbi_keiba_stg` | `kolbi_keiba` |
| Terraform Workspace | `stg` | `prd` |
| Bubble API | `enable_bubble_api = true/false` | `enable_bubble_api = true/false` |

---

## 主要テーブル

### `race_uma.sqlx`
- 出走馬ごとの**ワイドテーブル**（1900行超、最重要テーブル）
- ソース: `kol_den2`（出馬表）+ `kol_sei2`（成績）+ `kol_sei1` + `kol_uma_ketto`（血統）+ `kol_den1`（レース）+ `kol_yosou_odds`（予想オッズ）
- `hasso_date_utc`でパーティション分割（BigQuery）
- 主な特徴的ロジック：
  - **調教動的選択**: `chokyo1_flag` → `chokyo2_flag` → `chokyo3_flag` の優先ordem
  - **KOL→JRA-VAN コード変換**: `keibajo_code`の変換マッピング
  - **調教騎乗者区分の日付ロジック**: `kaisai_nengappi <= '20251219'` で変換ルールが切り替わる（KOLデータ仕様変更に対応）
  - **ラップグループ判定**: A1-A3/B1-B3/C1-C3 のグループ化ロジック
  - **調教タイム標準クリア判定**: 栗東/美南・坂路/CW/Wコースごとに閾値が異なる

### `race.sqlx`
- レース単位のマスター（開催情報・コース・天候・距離・条件）
- `kyoso_joken_kubun` → クラスラベル変換（新馬/未勝利/1勝/2勝/3勝/オープン）
- `race_name`生成: `kyosomei_15moji`がある場合はそちらを優先

### `schedule.sqlx`
- 開催日スケジュール（`schedule_id = YYYYMMDD`）

### `race_kekka_hassojokyo.sqlx`
- `kol_sei1.hasso_jokyo1～6`（発走状況）をアンピボットして行展開
- ソース: `kol_sei1` + `kol_den1`（JOIN on `race_code_kol`）
- `schedule_date` でパーティション分割、2023-01-01 以降のデータのみ保持

### `race_kekka_keika.sqlx`
- `kol_sei1.race_keika1～9`（経過情報）をアンピボットして行展開
- `keika_midashi1`（周回等）・`keika_midashi2`（コーナー等）を数値コード → 日本語ラベルに変換
- `keika_sort_label`：`keika_midashi2` を全角数字・全角Ｆ → 半角に変換（`TRANSLATE` 関数使用）
- `schedule_date` でパーティション分割、2023-01-01 以降のデータのみ保持

### `race_kekka_time.sqlx`
- `kol_sei1` のラップタイム（`lap_time1～18`）・ペース・上り1哩を保持
- KOLソース値は0.1秒単位（整数）のため `/10.0` で秒変換して格納
- `lap_time_label`：有効ラップをハイフン区切りでラベル化（例: `12.4-11.8-11.3`）
- `time_agari_label`：上り 6F-5F-4F-3F の累積タイム
- `time_tsuka_label`：通過 3F-4F-5F-6F の累積タイム
- `average_1f` / `average_3f`：1F・3F 平均タイム
- `pace_kekka_label`：`0→H / 1→M / 2→S`
- `schedule_date` でパーティション分割、2023-01-01 以降のデータのみ保持

### `cross_chokyoshi_*.sqlx` / `cross_ketto_f_*.sqlx`
- 調教師軸・父馬軸のクロス集計テーブル群
- 類似テーブルを追加する際は既存の同系列ファイルを参考にする
- 追加時はtags設定を他テーブルと揃えること（`default: true`の有無に注意）

---

## ソーステーブル（`definitions/sources/kol_sources.js`）

| テーブル名 | 内容 |
|-----------|------|
| `kol_den1` | レース情報（出馬表レース面） |
| `kol_den2` | 出走馬情報（出馬表馬面） |
| `kol_sei1` | 競走成績レース面 |
| `kol_sei2` | 競走成績出走馬面 |
| `kol_com1` | 騎手厩舎コメント |
| `kol_uma_ketto` | 血統情報 |
| `kol_yosou_odds` | 予想オッズ |

環境に応じて `source_schema` 変数で `kolbi_keiba` or `kolbi_keiba_stg` が動的に切り替わる。

---

## Cloud Functions

| Function | トリガー | 役割 |
|----------|---------|------|
| `dispatcher` | Eventarc (BigQuery更新ログ) | Cloud Tasksにタスクを5分後登録（デバウンス） |
| `export_schedules` | HTTP (Workflows経由) | スケジュールをFTP+Bubble API通知 |
| `export_races` | HTTP (Workflows経由) | レース情報をFTP+Bubble API通知 |
| `export_race_uma_detail_bubble` | HTTP (Workflows経由) | 馬詳細をBubble API通知 |

### Bubble API連携の注意点
- `ENABLE_BUBBLE_API` 環境変数（`stg.tfvars`/`prd.tfvars`の`enable_bubble_api`）で有効/無効を切り替え
- Bubble APIはHTTP 200でも `response.is_import_success == false` を返すことがある → **必ずレスポンスボディを確認すること**
- レスポンスキーの表記ゆれあり: `is_import_success` と `is import success`（スペース区切り）の両方を考慮済み
- 「短時間で同じファイルの取り込みを検知したため中止」エラーは例外扱いせず `WARNING` ログのみ

### ポータルからの手動実行（force_resend）
- kol-gcp-management の Bubble連携タブから HTTP POST で `from_date` / `to_date` / `force_resend: true` を渡すと手動再送できる
- `force_resend=true` 時は差分検知をスキップ・`ENABLE_BUBBLE_API` を無視して全件送信し、SSE ストリームで進捗を返す
- FTP 送信完了後は `*_export_state` テーブルを MERGE 更新するため、次回の自動差分検知には影響しない
- パラメータ省略時は従来の自動フローとして動作（後方互換）
- ポータル向け API 仕様は `docs/bubble-sync-cf-api.md` を参照

---

## Secret Manager の登録名

| シークレット名 | 用途 |
|-------------|------|
| `github-token` | DataformのGitHub連携用 |
| `kol_ftp_bubble_username` | FTP認証ユーザー名 |
| `kol_ftp_bubble_password` | FTP認証パスワード |
| `kol_bubble_workflow_api_key` | Bubble API Token |

---

## 開発時のポイント・Gotchas

- **Dataformのデプロイ**: `main`ブランチへのマージでDataformリポジトリは自動更新。ただし**Terraform変更（関数・スケジューラ設定変更）は手動で`apply`が必要**。
- **cross_*テーブル追加**: 既存の同系列ファイル（`cross_chokyoshi_chokyo_awase.sqlx`など）を参考にし、`tags`の`default: true`設定を忘れずに揃える。
- **KOL→JRA-VAN コード変換**: `keibajo_code`の変換マッピングは`race_uma.sqlx`のbase_data CTE内に一元定義されている。
- **調教騎乗者の日付切り替え**: `kaisai_nengappi <= '20251219'`かどうかで変換ロジックが変わる（KOL仕様変更対応）。
- **ポリトラック判定**: `chokyo_course = 'Ｐ'`（全角P）で判定。半角Pではないことに注意。
- **`race_uma_detail_bubble.sqlx` と `race_uma_detail_looker.sqlx`**: ロジック本体はそれぞれ`includes/`の対応JSファイルに分離済み。
- **`race_uma_detail_looker_mv`**: `race_uma_detail_looker` と同内容の BigQuery Materialized View（STG・PRD 両環境に存在）。`type: "operations"` として `included_targets` に含め、Dataform が `race_uma_detail_looker` 再作成後に自動で **DROP → CREATE** する（`CREATE OR REPLACE` では MV が無効状態のままになるため不十分）。`AS SELECT * FROM race_uma_detail_looker` でフルクエリ重複を避けている。
- **Dataform MV非対応**: Dataform 3.0.x は BigQuery Materialized View をネイティブサポートしない（`type: "view"` + `bigquery: { materialized: true }` はコンパイルエラー）。MV が必要な場合は `type: "operations"` で DROP → CREATE DDL を記述し、`included_targets` に追加して Dataform に管理させること。
- **状態管理テーブル**: Export CF群は差分検知のためBigQuery上に`*_export_state`テーブルを維持している（初回実行時に自動作成）。
- **ラップタイム単位**: KOLソース（`kol_sei1.lap_time*`）は0.1秒単位の整数格納 → `race_kekka_time.sqlx` で `/10.0` して秒単位に変換している。
- **全角文字のTRANSLATE変換**: `race_kekka_keika` の `keika_sort_label` では `TRANSLATE` 関数で全角数字・全角Ｆを半角に変換（`０～９Ｆ` → `0～9F`）。他テーブルで同種の変換が必要な場合も同パターンを使用する。
- **払戻テーブル（race_kekka_haraimodoshi）**: `race_kekka_haraimodoshi.sqlx` で定義。券種ごとの払戻金・組み合わせを格納。
