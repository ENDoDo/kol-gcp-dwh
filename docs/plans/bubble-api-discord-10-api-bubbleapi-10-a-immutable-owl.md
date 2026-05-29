# Plan: Bubble API 実行時の Discord 通知（10分デバウンス）

## Context

3つの Cloud Functions（`export_schedules`, `export_races`, `export_race_uma_detail_bubble`）が Bubble API を叩いている。
これらのどれかが Bubble API 呼び出しに成功したとき、Discord の #keiba-kolbi-bubble-alert チャンネルに通知を送りたい。
ただし同じ API が 10 分以内に連続して叩かれた場合は重複通知しない。異なる API は独立して通知する。

**デバウンス仕様（確定）:**
- API が叩かれるたびに `last_called_at` をリセット
- 前回の `last_called_at` から 10 分以上経過していれば通知（初回含む）
- 通知しなかった場合も `last_called_at` は更新する（次の呼び出しのタイマーリセット）

```
T=0  → 通知 ✅ (last_called_at = T+0)
T=6  → スキップ (6分 < 10分, last_called_at = T+6)
T=14 → スキップ (8分 < 10分, last_called_at = T+14)
T=24 → 通知 ✅ (10分経過, last_called_at = T+24)
```

---

## 方針

- **Discord 通知手段**: `requests.post()` でDiscord Webhook URL を直接 POST（新規ライブラリ不要、既存 `requests==2.34.2` を流用）
- **デバウンス状態管理**: 既存パターンに従い BigQuery テーブル `discord_notification_state` で管理（`api_name`, `last_called_at`）
- **通知タイミング**: Bubble API が 1 件以上成功した場合のみ、各関数の処理末尾で 1 回通知（チャンク毎ではなく呼び出し単位）
- **Webhook URL の管理**: Secret Manager に `kol_discord_webhook_url` として格納し、`DISCORD_WEBHOOK_URL_SECRET_ID` 環境変数で参照

---

## 事前準備（手動）

1. Discord サーバー「スマート競馬」→ #keiba-kolbi-bubble-alert → 設定 → 連携サービス → ウェブフック → 新しいウェブフック を作成してURLをコピー
2. Secret Manager に登録:
   ```bash
   echo -n "https://discord.com/api/webhooks/..." | gcloud secrets create kol_discord_webhook_url --data-file=- --project=smartkeiba
   ```

---

## 実装手順

### 1. 各 `main.py` に定数・関数を追加

**対象ファイル（3つ）:**
- [functions/export_schedules/main.py](functions/export_schedules/main.py)
- [functions/export_races/main.py](functions/export_races/main.py)
- [functions/export_race_uma_detail_bubble/main.py](functions/export_race_uma_detail_bubble/main.py)

**追加する定数（各ファイルの先頭環境変数セクション）:**
```python
DISCORD_WEBHOOK_URL_SECRET_ID = os.environ.get("DISCORD_WEBHOOK_URL_SECRET_ID")
DISCORD_NOTIFICATION_TABLE = "discord_notification_state"
DISCORD_API_NAME = "スケジュール同期"  # 各関数で異なる（下記参照）
```

各関数の `DISCORD_API_NAME`:
| 関数 | `DISCORD_API_NAME` |
|------|-------------------|
| export_schedules | `"スケジュール同期"` |
| export_races | `"レース情報同期"` |
| export_race_uma_detail_bubble | `"馬詳細同期"` |

**追加する関数:**
```python
def ensure_discord_notification_table(bq_client, dataset_id):
    schema = [
        bigquery.SchemaField("api_name", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("last_called_at", "TIMESTAMP", mode="REQUIRED"),
    ]
    table_ref = f"{PROJECT_ID}.{dataset_id}.{DISCORD_NOTIFICATION_TABLE}"
    bq_client.create_table(bigquery.Table(table_ref, schema=schema), exists_ok=True)

def maybe_send_discord_notification(bq_client, dataset_id):
    """
    Bubble API 呼び出し成功後に呼ぶ。
    - 前回の last_called_at から 10 分以上経過していれば Discord 通知を送る
    - 通知しない場合も last_called_at は必ず更新（タイマーリセット）
    """
    if not DISCORD_WEBHOOK_URL_SECRET_ID:
        return
    try:
        rows = list(bq_client.query(f"""
            SELECT last_called_at
            FROM `{PROJECT_ID}.{dataset_id}.{DISCORD_NOTIFICATION_TABLE}`
            WHERE api_name = '{DISCORD_API_NAME}'
        """).result())

        should_notify = True
        if rows:
            elapsed = datetime.datetime.now(datetime.timezone.utc) - rows[0].last_called_at
            if elapsed < datetime.timedelta(minutes=10):
                logger.info(f"Discord通知スキップ（前回呼び出しから{elapsed.seconds // 60}分経過）: {DISCORD_API_NAME}")
                should_notify = False

        if should_notify:
            webhook_url = get_secret(DISCORD_WEBHOOK_URL_SECRET_ID)
            env_label = "PRD" if dataset_id == "kolbi_analysis" else "STG"
            now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            requests.post(webhook_url, json={
                "content": f"**[{env_label}] Bubble API 実行**\nAPI: **{DISCORD_API_NAME}**\n実行時刻: {now_str}"
            }, timeout=10).raise_for_status()
            logger.info(f"Discord通知を送信しました: {DISCORD_API_NAME}")

        # 通知有無に関わらず last_called_at を更新（タイマーリセット）
        bq_client.query(f"""
            MERGE `{PROJECT_ID}.{dataset_id}.{DISCORD_NOTIFICATION_TABLE}` T
            USING (SELECT '{DISCORD_API_NAME}' AS api_name, CURRENT_TIMESTAMP() AS last_called_at) S
            ON T.api_name = S.api_name
            WHEN MATCHED THEN UPDATE SET T.last_called_at = S.last_called_at
            WHEN NOT MATCHED THEN INSERT (api_name, last_called_at) VALUES (S.api_name, S.last_called_at)
        """).result()
    except Exception as e:
        logger.warning(f"Discord通知処理に失敗しました（スキップ）: {e}")
```

### 2. テーブル作成と通知呼び出しを main フローに組み込む

各関数で以下を変更:

**テーブル作成（既存 `ensure_state_table` 呼び出しの直後に追加）:**
```python
ensure_discord_notification_table(bq_client, DATASET_ID)
```

**通知フラグの追加（処理開始直後）:**
```python
bubble_api_called = False
```

**成功時にフラグを立てる（Bubble API 成功確認後、または duplicate warning 後）:**
```python
bubble_api_called = True
```

**状態テーブル更新の直後に通知呼び出し（関数末尾）:**
```python
if bubble_api_called:
    maybe_send_discord_notification(bq_client, DATASET_ID)
```

### 3. Terraform に環境変数を追加

**対象**: [terraform/functions.tf](terraform/functions.tf)  
3つの関数ブロック（`export_schedules`, `export_race_uma_detail_bubble`, `export_races`）それぞれの `env_variables` に追加:

```hcl
DISCORD_WEBHOOK_URL_SECRET_ID = "projects/56638639323/secrets/kol_discord_webhook_url"
```

（STG/PRD 共通で同じ Secret を参照。通知先は同じ Discord チャンネル）

---

## 検証方法

1. STG 環境で Dataform ワークフローを手動実行し、Bubble API が呼ばれるフローを動かす
2. Discord #keiba-kolbi-bubble-alert に通知が届くことを確認
3. 10分以内に再実行 → 通知が来ないことを確認、BigQuery の `last_called_at` が更新されていることを確認
4. 10分後（前回 `last_called_at` から）に再実行 → 通知が届くことを確認

---

## デプロイ手順

```bash
# Terraform apply（STG → PRD の順）
cd terraform
terraform workspace select stg && terraform apply -var-file="stg.tfvars" -auto-approve
terraform workspace select prd && terraform apply -var-file="prd.tfvars" -auto-approve
```

（`requirements.txt` 変更不要 — `requests` は既に依存関係に含まれている）
