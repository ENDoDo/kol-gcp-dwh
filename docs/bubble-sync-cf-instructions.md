# kol-gcp-dataform Export CF 改修指示書

## 目的

kol-gcp-management ポータルから手動で Bubble 連携を実行できるよう、
既存 Export CF 群に「日付範囲指定 + 強制再送モード」と「SSE プログレスストリーム」を追加する。

## 背景

kol-gcp-management に「Bubble 連携」タブを新設した。ポータルのユーザーが対象期間・テーブルを
選択して「連携実行」を押すと、ポータルの API が各 Export CF を HTTP POST で呼び出す。
CF は SSE ストリームでリアルタイムに進捗を返し、UI に「何日まで完了 / X%」が表示される。

ポータルからの呼び出しは以下の JSON ボディを持つ：

```json
{
  "from_date": "2026-01-01",
  "to_date":   "2026-03-31",
  "force_resend": true
}
```

これらパラメータが**ない場合（省略時）は既存の自動フロー通りに動作する**（後方互換性を維持）。

---

## 変更対象 CF（3 本）

| CF 名 | ソースファイル |
|-------|--------------|
| export_schedules | `functions/export_schedules/main.py` |
| export_races | `functions/export_races/main.py` |
| export_race_uma_detail_bubble | `functions/export_race_uma_detail_bubble/main.py` |

---

## 変更内容（3 本共通）

### 1. リクエストパラメータ追加

HTTP リクエストの JSON ボディで以下を受け付ける。全て省略可能：

| パラメータ | 型 | 例 | 説明 |
|-----------|----|----|------|
| `from_date` | str | `"2026-01-01"` | YYYY-MM-DD 形式の開始日 |
| `to_date` | str | `"2026-03-31"` | YYYY-MM-DD 形式の終了日 |
| `force_resend` | bool | `true` | 強制再送モード（差分検知スキップ） |

```python
request_json = request.get_json(silent=True) or {}
from_date    = request_json.get("from_date")            # Optional[str]
to_date      = request_json.get("to_date")              # Optional[str]
force_resend = request_json.get("force_resend", False)  # bool
```

---

### 2. BQ クエリへの WHERE 句追加

`force_resend=True` かつ `from_date`/`to_date` が指定されている場合、
以下のフィールドでフィルタしてデータを絞り込む。

| CF | 追加 WHERE 句 | 備考 |
|----|--------------|------|
| export_schedules | `DATE(period1_start) BETWEEN @from_date AND @to_date` | `period1_start` は TIMESTAMP 型 |
| export_races | `DATE(hasso_date_utc) BETWEEN @from_date AND @to_date` | `hasso_date_utc` は DATETIME 型 |
| export_race_uma_detail_bubble | `schedule_date BETWEEN @from_date AND @to_date` | `schedule_date` は DATE 型（変換不要） |

BigQuery パラメータの追加例：
```python
from google.cloud import bigquery

query_params = [
    bigquery.ScalarQueryParameter("from_date", "DATE", from_date),
    bigquery.ScalarQueryParameter("to_date",   "DATE", to_date),
]
```

---

### 3. 差分検知スキップ（force_resend=True 時）

通常フローでは `*_export_state` テーブルと LEFT JOIN してハッシュ比較を行うが、
`force_resend=True` の場合はこの JOIN を外し、**全件を「差分あり（要送信）」として扱う**。

```python
if force_resend:
    # export_state との JOIN なし。対象期間の全件を送信対象とする
    query = f"""
        SELECT * FROM `{dataset}.{table}`
        WHERE DATE({date_field}) BETWEEN @from_date AND @to_date
        ORDER BY {date_field}
    """
else:
    # 既存の差分検知クエリ（変更なし）
    query = existing_diff_query
```

---

### 4. ENABLE_BUBBLE_API の扱い

`force_resend=True` の場合、`ENABLE_BUBBLE_API` 環境変数に関わらず
FTP アップロードおよび Bubble API 通知を実行する。
ポータルから手動実行が呼ばれた場合は「連携を実行する意図がある」ため、常に実行する。

```python
# force_resend の場合は ENABLE_BUBBLE_API を無視して常に実行する
enable_bubble = force_resend or (os.environ.get("ENABLE_BUBBLE_API", "false").lower() == "true")
```

---

### 5. 処理開始時の総件数取得

プログレス % を計算するため、処理開始前に `COUNT(*)` クエリを実行する。

```python
count_query = f"""
    SELECT COUNT(*) AS total
    FROM `{dataset}.{table}`
    WHERE DATE({date_field}) BETWEEN @from_date AND @to_date
"""
count_job = bq_client.query(count_query, job_config=bigquery.QueryJobConfig(
    query_parameters=[
        bigquery.ScalarQueryParameter("from_date", "DATE", from_date),
        bigquery.ScalarQueryParameter("to_date",   "DATE", to_date),
    ]
))
total = list(count_job.result())[0].total
```

---

### 6. SSE ストリーミングレスポンス（force_resend=True 時）

通常フローはジョブ完了後に JSON を一括返却するが、
`force_resend=True` の場合は Flask の `stream_with_context` を使って SSE 形式でプログレスをストリームする。

#### イベント形式

**progress イベント**（1,000 件チャンクを FTP 送信するたびに送信）：
```
event: progress
data: {"current_date": "2026-02-14", "processed": 2345, "total": 5200, "pct": 45}

```
（最後の空行 `\n\n` を含むこと）

**result イベント**（全完了時）：
```
event: result
data: {"status": "success", "records": 5200}

```

**result イベント**（致命的エラー時）：
```
event: result
data: {"status": "error", "message": "エラーメッセージ"}

```

#### Python 実装例

```python
from flask import Response, stream_with_context
import json

def generate_sse(total, bq_rows_iter, date_field_key):
    """SSE ジェネレータ: 1,000 件ごとに FTP+Bubble して progress を yield する"""
    processed = 0
    chunk = []

    try:
        for row in bq_rows_iter:
            chunk.append(row)
            if len(chunk) >= 1000:
                upload_chunk_and_notify(chunk)  # 既存の FTP+Bubble ロジックを流用
                processed += len(chunk)
                current_date = str(max(r[date_field_key] for r in chunk))[:10]
                pct = int(processed / total * 100) if total > 0 else 100
                yield (
                    f"event: progress\n"
                    f"data: {json.dumps({'current_date': current_date, 'processed': processed, 'total': total, 'pct': pct})}\n\n"
                )
                chunk = []

        # 残りチャンクを処理
        if chunk:
            upload_chunk_and_notify(chunk)
            processed += len(chunk)
            current_date = str(max(r[date_field_key] for r in chunk))[:10]

        yield f"event: result\ndata: {json.dumps({'status': 'success', 'records': processed})}\n\n"

    except Exception as e:
        logging.exception("force_resend 処理中にエラー")
        yield f"event: result\ndata: {json.dumps({'status': 'error', 'message': str(e)})}\n\n"


# メイン処理内
if force_resend:
    return Response(
        stream_with_context(generate_sse(total, rows_iter, date_field_key)),
        mimetype="text/event-stream",
        headers={
            "X-Accel-Buffering": "no",   # nginx バッファリングを無効化
            "Cache-Control":     "no-cache",
        },
    )
else:
    # 既存の JSON レスポンス処理（変更なし）
    ...
```

---

### 7. 状態管理テーブルの扱い

`force_resend=True` の場合でも、FTP 送信完了後は `*_export_state` テーブルを MERGE で更新する。
これにより次回の自動差分検知が正しく動作する（手動再送済みのデータを再送しない）。

既存の MERGE ロジックはそのまま流用できる。

---

## CF 別の変更詳細

### export_schedules

| 項目 | 値 |
|------|---|
| 日付フィールド | `period1_start`（TIMESTAMP 型） |
| WHERE 句 | `DATE(period1_start) BETWEEN @from_date AND @to_date` |
| current_date の取得 | `str(max(r['period1_start'] for r in chunk))[:10]` |

### export_races

| 項目 | 値 |
|------|---|
| 日付フィールド | `hasso_date_utc`（DATETIME 型） |
| WHERE 句 | `DATE(hasso_date_utc) BETWEEN @from_date AND @to_date` |
| current_date の取得 | `str(max(r['hasso_date_utc'] for r in chunk))[:10]` |

### export_race_uma_detail_bubble

| 項目 | 値 |
|------|---|
| 日付フィールド | `schedule_date`（DATE 型） |
| WHERE 句 | `schedule_date BETWEEN @from_date AND @to_date` |
| current_date の取得 | `str(max(r['schedule_date'] for r in chunk))` |

---

## ポータル側の IAM 設定（参考）

kol-gcp-management 側の Terraform（`terraform/main.tf`）で、ポータルの Cloud Run SA から
各 CF への `roles/cloudfunctions.invoker` 権限を付与済み。kol-gcp-dataform 側の Terraform 変更は不要。

**ポータル SA:**
- stg: `kol-management-sa-stg@smartkeiba.iam.gserviceaccount.com`
- prd: `kol-management-sa-prd@smartkeiba.iam.gserviceaccount.com`

---

## テスト確認事項

| # | 確認内容 | 期待結果 |
|---|---------|---------|
| 1 | `force_resend` なしで CF を呼び出す | 既存の差分検知ロジックが変わらず動作する |
| 2 | `force_resend=true` + 日付範囲で呼び出す | 指定期間の全件が FTP 送信 + Bubble 通知される |
| 3 | SSE イベントの確認 | 1,000 件ごとに `event: progress` が流れる |
| 4 | 全完了後の確認 | `event: result` + `{"status": "success", "records": N}` が返る |
| 5 | `*_export_state` の確認 | force_resend 後もテーブルが更新されている |
| 6 | `ENABLE_BUBBLE_API=false` + `force_resend=true` | FTP + Bubble が実行される（ENABLE_BUBBLE_API を無視） |
| 7 | エラー発生時 | `event: result` + `{"status": "error", "message": "..."}` が返る |

---

## 質問・確認事項

kol-gcp-dataform 側の実装で不明点があれば kol-gcp-management の担当者に確認してください。
ポータル側の実装（SSE クライアント・プロキシ）は `app/api/bubble-sync/route.ts` を参照。
