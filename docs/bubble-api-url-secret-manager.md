# Bubble APIエンドポイントURL管理仕様（管理画面PJ向け）

kol-gcp-dwh の Export Cloud Functions が参照する Bubble API エンドポイント URL を、  
管理画面から Secret Manager 経由で動的に変更するための仕様書です。

---

## 概要

各 Export CF は起動時に Secret Manager から最新の Bubble API エンドポイント URL を取得します。  
管理画面から新バージョンを登録するだけで、**CF の再デプロイなしに即時反映**されます。

### エンドポイント優先度

| 優先度 | ソース | 用途 |
|--------|--------|------|
| 1（最高） | リクエストパラメータ `bubble_api_url` | 一時的な手動上書き |
| 2 | Secret Manager 最新バージョン | 管理画面から動的変更 |
| 3（最低） | 環境変数 `BUBBLE_API_URL` | Terraform デフォルト（フォールバック） |

---

## 対象シークレット一覧

GCPプロジェクト: `smartkeiba`（プロジェクト番号: `56638639323`）

| CF | 環境 | シークレットID |
|----|------|--------------|
| `export_schedules` | PRD | `kol_bubble_schedule_api_url` |
| `export_schedules` | STG | `kol_bubble_schedule_api_url_stg` |
| `export_races` | PRD | `kol_bubble_races_api_url` |
| `export_races` | STG | `kol_bubble_races_api_url_stg` |
| `export_race_uma_detail_bubble` | PRD | `kol_bubble_race_uma_detail_api_url` |
| `export_race_uma_detail_bubble` | STG | `kol_bubble_race_uma_detail_api_url_stg` |

### 現在の登録値（初期値）

| 環境 | URL |
|------|-----|
| PRD（schedule） | `https://member.kol-bi.jp/api/1.1/wf/import_schedule` |
| PRD（races） | `https://member.kol-bi.jp/api/1.1/wf/import_race` |
| PRD（race_uma_detail） | `https://member.kol-bi.jp/api/1.1/wf/import_race_uma_detail` |
| STG（schedule） | `https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_schedule` |
| STG（races） | `https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_race` |
| STG（race_uma_detail） | `https://temp-toreyomi-20260228.bubbleapps.io/version-test/api/1.1/wf/import_race_uma_detail` |

---

## 管理画面側の実装

### 必要なIAM

管理画面のサービスアカウントに対して、対象シークレット単位で以下のロールを付与してください：

```
roles/secretmanager.secretVersionAdder
```

対象は上記6件のシークレットそれぞれに付与が必要です（プロジェクトレベルで付与すると全シークレットに適用されます）。

### Python実装例

```python
from google.cloud import secretmanager

client = secretmanager.SecretManagerServiceClient()

def update_bubble_api_url(secret_id: str, new_url: str, project: str = "56638639323"):
    """
    Bubble APIエンドポイントURLをSecret Managerに新バージョンとして登録する。
    登録後、次回のCF起動から即時反映される。
    """
    parent = f"projects/{project}/secrets/{secret_id}"
    version = client.add_secret_version(
        request={
            "parent": parent,
            "payload": {"data": new_url.encode("utf-8")},
        }
    )
    return version.name  # 例: projects/56638639323/secrets/.../versions/2


# 使用例: PRD の全エンドポイントを一括更新
PRD_SECRETS = {
    "kol_bubble_schedule_api_url": "https://member.kol-bi.jp/api/1.1/wf/import_schedule",
    "kol_bubble_races_api_url": "https://member.kol-bi.jp/api/1.1/wf/import_race",
    "kol_bubble_race_uma_detail_api_url": "https://member.kol-bi.jp/api/1.1/wf/import_race_uma_detail",
}

for secret_id, url in PRD_SECRETS.items():
    version_name = update_bubble_api_url(secret_id, url)
    print(f"Updated: {version_name}")
```

### REST API実装例

Secret Manager REST API を直接使用する場合：

```
POST https://secretmanager.googleapis.com/v1/projects/56638639323/secrets/{SECRET_ID}/versions:add
Authorization: Bearer {ACCESS_TOKEN}
Content-Type: application/json

{
  "payload": {
    "data": "<base64エンコードしたURL>"
  }
}
```

---

## 現在のURL確認方法

### Python

```python
from google.cloud import secretmanager

client = secretmanager.SecretManagerServiceClient()

def get_bubble_api_url(secret_id: str, project: str = "56638639323") -> str:
    name = f"projects/{project}/secrets/{secret_id}/versions/latest"
    version = client.access_secret_version(request={"name": name})
    return version.payload.data.decode("utf-8")

print(get_bubble_api_url("kol_bubble_schedule_api_url"))
```

### gcloud CLI

```bash
gcloud secrets versions access latest \
  --secret="kol_bubble_schedule_api_url" \
  --project="smartkeiba"
```

---

## 注意事項

- **反映タイミング**: 新バージョン登録後、**次回のCF起動から即時反映**されます（再デプロイ不要）
- **フォールバック**: Secret未取得の場合は Terraform の env var `BUBBLE_API_URL` にフォールバックします（CF は止まりません）
- **バージョン管理**: 古いバージョンは自動削除されません。バージョン数が増える場合は古いものを手動で無効化してください
- **STG/PRD分離**: STG と PRD は別シークレットIDで管理されています。誤った環境に登録しないよう注意してください
- **関連ドキュメント**: CF の呼び出し仕様全般は [`bubble-sync-cf-api.md`](./bubble-sync-cf-api.md) を参照してください
