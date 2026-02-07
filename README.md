# KOL競馬データ処理・変換パイプライン on GCP

このリポジトリは、GCP上に構築された競馬データパイプラインの**データ変換（Transformation）**および**データエクスポート（Reverse ETL）**部分を担います。

GCSにアップロードされ、BigQueryの生テーブルに格納されたKOL競馬データをソースとして、**Dataform**を使い分析用のデータマートを構築し、外部システムへ連携します。

このリポジトリでは、主に以下の2点をコードで管理しています。
1.  **データ変換ロジック**: `definitions/`ディレクトリに格納された、Dataform SQLXファイル。
2.  **インフラストラクチャ (IaC)**: `terraform/`ディレクトリに格納された、GCPリソース定義。

**Note**: データ取り込み（Ingestion）部分（Cloud FunctionによるGCSからのデータロード）は、このリポジトリの管理範囲外です。

## アーキテクチャ

本パイプラインには、大きく分けて2つの実行トリガーが存在します。

### 1. ファイルアップロード・トリガー（データ更新時）

KOLから提供されるデータファイルが更新された際に実行されるフローです。

```mermaid
graph TD
    subgraph "データ取り込み (Ingestion - Scope Out)"
        User[ユーザー] -->|ZIPアップロード| GCS(GCS Bucket);
        GCS -->|Eventarc| LoaderCF(Loader Function);
        LoaderCF -->|ロード| Raw[(BigQuery Raw Tables<br>kol_keiba.*)];
    end

    subgraph "データ変換トリガー (Trigger & Debounce)"
        Raw -- "テーブル更新検知" --> L{Cloud Logging Sink};
        L -- "ログエントリ" --> P(Pub/Sub Topic);
        P -- "メッセージ送信" --> E{Eventarc};
        E -- "トリガー" --> Dis[Dispatcher Function];
        Dis -- "タスク作成 (5分後)" --> Q[Cloud Tasks Queue];
        Q -- "デバウンス実行" --> W{Cloud Workflows};
    end

    subgraph "データ変換 (Transformation)"
        W -- "Dataform実行" --> R{Dataform Repository};
        R -- "SQLX実行" --> Mart[(BigQuery Mart Tables<br>kolbi_analysis.*)];
    end

    subgraph "データエクスポート (Reverse ETL)"
        Mart -->|完了後| ExportCF{Export Cloud Functions};
        ExportCF -->|CSV| FTP[FTP Server];
        ExportCF -->|通知| Bubble[Bubble API];
    end
```

### 2. スケジュール・トリガー（リアルタイムオッズ更新）

オッズ情報など、時間経過とともに変化するデータを定期的に更新するフローです。

```mermaid
graph TD
    subgraph "スケジュール実行"
        Scheduler[Cloud Scheduler<br>odds-update] -- "cron: 0 6,9,12,15,20 * * *" --> W{Cloud Workflows};
    end

    subgraph "データ変換"
        W -- "Dataform実行<br>(tags: odds)" --> R{Dataform Repository};
        R -- "SQLX実行<br>(race_uma_oddsのみ)" --> Odds[(race_uma_odds)];
    end
```

## 技術スタック

- **クラウド**: Google Cloud Platform
  - **コンピューティング**: Cloud Functions (Gen2), Cloud Workflows, Cloud Scheduler
  - **非同期処理**: Cloud Tasks
  - **DWH**: BigQuery
  - **データ変換**: Dataform
  - **イベント**: Eventarc, Pub/Sub, Cloud Logging
- **IaC**: Terraform
- **言語**: Python (Functions), SQLX (Dataform), YAML (Workflows)

## 重要なテーブル定義

`definitions/` 配下で定義されている主要なテーブルです。

### `race.sqlx`
- レース単位のマスターテーブル。
- 開催情報、コース条件、天候などを集約。

### `race_uma.sqlx`
- 出走馬ごとの詳細データを統合した分析用ワイドテーブル。
- 成績、過去走、血統、調教データを結合。
- **特徴的なロジック**:
  - **調教併せ馬判定**: パートナー馬の特定と、クラス格付け（格上/同格/格下）判定。

### `race_uma_odds.sqlx`
- **リアルタイムオッズ情報**。
- `races_uma_odds_jvd_new` をソースとし、KOL仕様のレースID等を付与。
- **更新頻度**: 毎日 06:00, 09:00, 12:00, 15:00, 20:00 (JST)。

### `race_hit.sqlx`
- 的中判定・配当金テーブル。
- 単勝・複勝を除く券種の配当情報を保持。

## ディレクトリ構成

```
.
├── definitions/        # Dataform SQLXファイル
│   ├── sources/        # データソースdeclarations
│   ├── race.sqlx
│   ├── race_uma.sqlx
│   ├── race_uma_odds.sqlx
│   └── ...
├── functions/          # Cloud Functions ソースコード
│   ├── dispatcher/     # Dataform起動用Dispatcher
│   ├── export_races/   # レース情報エクスポート
│   ├── export_schedules/ # スケジュール情報エクスポート
│   └── export_race_uma_details/ # 馬詳細情報エクスポート
├── terraform/          # GCPインフラ定義
│   ├── main.tf
│   ├── scheduler.tf    # Cloud Scheduler定義
│   ├── workflows.tf    # Cloud Workflows定義
│   └── ...
├── dataform.json       # Dataform設定
└── README.md
```

## セットアップとデプロイ手順

### 1. 前提条件
- Google Cloud SDK (gcloud CLI)
- Terraform
- GitHub Personal Access Token (PAT)

### 2. 環境設定
GitHub PATやBubble/FTPの認証情報は **Secret Manager** に以下の名前で登録する必要があります。
- `github-token`: Dataform用GitHub Token
- `kol_ftp_bubble_username`, `kol_ftp_bubble_password`: FTP認証
- `kol_bubble_workflow_api_key`: Bubble API Token

### 3. インフラのデプロイ (Terraform)

```bash
cd terraform

# Staging環境
terraform workspace select stg
terraform apply -var-file="stg.tfvars"

# Production環境
terraform workspace select prd
terraform apply -var-file="prd.tfvars"
```

## 運用時の注意点

- **自動デプロイ**: `main` ブランチへのマージ時、Dataformリポジトリは自動的に更新されますが、Terraformの変更（スケジューラや関数の設定変更）は手動で `apply` する必要があります。
- **デバウンス**: ファイルアップロード時のトリガーは、連続したアップロードをまとめて処理するため、最後のファイル検知から約5分後に処理が開始されます。