# Export CF — 期間指定・強制再送（force_resend）仕様

別プロジェクトへの共有用ドキュメントです。  
`export_schedules` / `export_races` / `export_race_uma_detail_bubble` の3つの Cloud Functions (Gen2) に共通して実装されている、**期間指定 + 強制再送 + SSE プログレスストリーム**機能の仕様をまとめます。

---

## 概要

各 Export CF は通常、BigQuery 上の状態管理テーブルとのハッシュ比較による**差分検知**モードで動作します。  
`force_resend: true` を渡すことで、差分に関わらず指定期間のデータを全件再送する**強制再送モード**に切り替わります。

### 重要な挙動

- `ENABLE_BUBBLE_API` 環境変数が `false` でも、`force_resend: true` であれば **FTP + Bubble API の両方が実行される**
- 強制再送完了後は状態管理テーブル（`*_export_state`）を MERGE 更新するため、**次回の自動フローで同一データが重複送信されることはない**
- レスポンスは通常モードの JSON と異なり、**SSE（Server-Sent Events）ストリーム**で進捗をリアルタイムに返す

---

## CF 一覧

| CF名 | 対象テーブル | 日付フィルターカラム | 状態管理テーブル |
|------|------------|-------------------|----------------|
| `export-schedules-function` | `schedule` | `DATE(period1_start)` | `schedules_export_state` |
| `export-races-function` | `race` | `DATE(hasso_date_utc)` | `races_export_state` |
| `export-race-uma-details-function` | `race_uma_detail_bubble` | `schedule_date` | `race_uma_detail_bubble_export_state` |

### エンドポイント URL

| CF名 | STG | PRD |
|------|-----|-----|
| `export-schedules-function` | `https://export-schedules-function-stg-3bjqesjq2q-an.a.run.app` | `https://export-schedules-function-3bjqesjq2q-an.a.run.app` |
| `export-races-function` | `https://export-races-function-stg-3bjqesjq2q-an.a.run.app` | `https://export-races-function-3bjqesjq2q-an.a.run.app` |
| `export-race-uma-details-function` | `https://export-race-uma-details-function-stg-3bjqesjq2q-an.a.run.app` | `https://export-race-uma-details-function-3bjqesjq2q-an.a.run.app` |

---

## リクエスト仕様

```
POST {CF_URL}
Content-Type: application/json
Authorization: Bearer {OIDC_TOKEN}
```

### リクエストボディ

```json
{
  "from_date": "2026-01-01",
  "to_date":   "2026-03-31",
  "force_resend": true
}
```

| パラメータ | 型 | 必須 | 説明 |
|-----------|----|----|------|
| `from_date` | string | force_resend 時は必須 | 対象期間の開始日（`YYYY-MM-DD`） |
| `to_date` | string | force_resend 時は必須 | 対象期間の終了日（`YYYY-MM-DD`） |
| `force_resend` | bool | いいえ | `true` のとき差分検知をスキップして全件送信 + SSE で進捗を返す |

> **パラメータをすべて省略した場合**は差分検知モードで動作し、通常の JSON レスポンスを返します（後方互換）。

---

## レスポンス仕様

### force_resend=true のとき：SSE ストリーム

`Content-Type: text/event-stream` で進捗をリアルタイムに返します。1,000 件チャンクごとに `progress` イベント、完了時に `result` イベントが送信されます。

#### progress イベント

```
event: progress
data: {"current_date": "2026-02-14", "processed": 2000, "total": 5200, "pct": 38}

```

| フィールド | 型 | 説明 |
|-----------|----|----|
| `current_date` | string | 直近処理チャンクの最大日付（`YYYY-MM-DD`） |
| `processed` | int | 累積処理件数 |
| `total` | int | 対象期間の総件数 |
| `pct` | int | 進捗率（0〜100） |

#### result イベント（成功時）

```
event: result
data: {"status": "success", "records": 5200}

```

#### result イベント（エラー時）

```
event: result
data: {"status": "error", "message": "エラーメッセージ"}

```

### force_resend=false（省略）のとき：JSON レスポンス

```
HTTP 200  "成功。 N 行をエクスポートしました。"
HTTP 200  "更新はありませんでした。"
HTTP 500  "FTPアップロード失敗: ..."
HTTP 500  "内部サーバーエラー: ..."
```

---

## 処理フロー（force_resend=true）

```
1. BQ: 対象期間の件数を COUNT クエリで取得（total）
2. BQ: 対象期間のデータを全件取得
3. データを 1,000 件単位でチャンク分割
4. チャンクごとに:
   a. CSV 生成 → FTP アップロード
   b. Bubble API に CSV の URL を POST
   c. SSE で progress イベントを送信
5. BQ: 状態管理テーブルを MERGE 更新
6. SSE で result イベントを送信（完了 or エラー）
```

---

## FTP ファイル命名規則

| 条件 | ファイル名パターン |
|------|----------------|
| チャンクが1ファイルのとき | `{table}_{from_yyyymmdd}_{to_yyyymmdd}.csv` |
| チャンクが複数のとき | `{table}_{from_yyyymmdd}_{to_yyyymmdd}_part001.csv` |

例: `race_20260101_20260331.csv` / `race_20260101_20260331_part001.csv`

---

## Bubble API レスポンスの注意点

- HTTP 200 OK でも `response.is_import_success == false` を返すことがあるため、**レスポンスボディを必ず検証**
- キーの表記ゆれあり: `is_import_success`（アンダースコア）と `is import success`（スペース）の両方をチェック
- `"短時間で同じファイルの取り込みを検知したため中止"` エラーは重複検知による正常系扱いで、WARNING ログのみ出力（例外にしない）

---

## 環境変数と ENABLE_BUBBLE_API の関係

```python
# CF 内部ロジック（3つの CF 共通）
force_resend  = request_json.get("force_resend", False)
enable_bubble = force_resend or ENABLE_BUBBLE_API
```

| `ENABLE_BUBBLE_API` | `force_resend` | Bubble API 実行 |
|--------------------|----------------|----------------|
| true | false | 実行する（通常フロー） |
| false | false | スキップ |
| false | true | **実行する** |
| true | true | 実行する |

---

## SSE クライアント実装例（Next.js API Route）

```typescript
// app/api/bubble-sync/route.ts

export async function POST(req: Request) {
  const { cfUrl, fromDate, toDate } = await req.json();

  const token = await getIdToken(cfUrl); // OIDC トークン取得

  const cfRes = await fetch(cfUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ from_date: fromDate, to_date: toDate, force_resend: true }),
  });

  // CF の SSE をそのままクライアントへ透過
  return new Response(cfRes.body, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "X-Accel-Buffering": "no",
    },
  });
}
```

---

## デプロイ状況

| 環境 | CF 最終更新 | `ENABLE_BUBBLE_API` |
|------|-----------|-------------------|
| stg | 2026-04-29 | false |
| prd | 2026-04-29 | false |

stg・prd ともに force_resend 機能はデプロイ済み。`ENABLE_BUBBLE_API=false` でも `force_resend: true` で利用可能。
