# Export CF API仕様書（kol-gcp-management 連携用）

kol-gcp-management の Bubble連携タブから各 Export CF を呼び出す際の仕様です。

---

## 対象 CF 一覧

| CF名 | 用途 |
|------|------|
| `export_schedules` | スケジュールテーブルを FTP + Bubble へ連携 |
| `export_races` | レース情報テーブルを FTP + Bubble へ連携 |
| `export_race_uma_detail_bubble` | 馬詳細テーブルを FTP + Bubble へ連携 |

各 CF の URL は Terraform の outputs または Cloud Functions コンソールから取得してください。

---

## リクエスト仕様

### メソッド・ヘッダー

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
| `from_date` | string | force_resend時は必須 | 対象期間の開始日（YYYY-MM-DD） |
| `to_date` | string | force_resend時は必須 | 対象期間の終了日（YYYY-MM-DD） |
| `force_resend` | bool | いいえ | `true` のとき差分検知をスキップして全件送信 + SSEストリームで進捗を返す |

**パラメータをすべて省略した場合**は既存の自動フロー（差分検知）として動作し、JSONレスポンスを返します（後方互換）。

---

## レスポンス仕様

### force_resend=true のとき：SSE ストリーム

`Content-Type: text/event-stream` で進捗をリアルタイムに返します。

#### progress イベント（1,000件チャンクごとに送信）

```
event: progress
data: {"current_date": "2026-02-14", "processed": 2000, "total": 5200, "pct": 38}

```

| フィールド | 型 | 説明 |
|-----------|----|----|
| `current_date` | string | 直近処理したチャンクの最大日付（YYYY-MM-DD） |
| `processed` | int | 累積処理件数 |
| `total` | int | 対象期間の総件数 |
| `pct` | int | 進捗率（0〜100） |

#### result イベント（完了時）

```
event: result
data: {"status": "success", "records": 5200}

```

#### result イベント（エラー時）

```
event: result
data: {"status": "error", "message": "エラーメッセージ"}

```

### force_resend=false（省略時）のとき：JSON レスポンス

```
HTTP 200  "成功。 N 行をエクスポートしました。"
HTTP 200  "更新はありませんでした。"
HTTP 500  "FTPアップロード失敗: ..."
HTTP 500  "内部サーバーエラー: ..."
```

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

## 備考

- `force_resend=true` のとき `ENABLE_BUBBLE_API` 環境変数の値に関わらず FTP + Bubble の両方が実行されます。
- FTP 送信完了後に状態管理テーブル（`*_export_state`）を更新するため、手動再送後に自動フローが同一データを再送することはありません。
- Cloud Functions のデフォルトタイムアウトは60秒です。大きな日付範囲を指定する場合はタイムアウトを延長してください（Terraform の `timeout_seconds` を変更）。
