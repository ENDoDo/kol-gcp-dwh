# Bubble API ON/OFF管理仕様（管理画面PJ向け）

kol-gcp-dwh の Export Cloud Functions による Bubble API 通知を、  
管理画面から Secret Manager 経由で動的に ON/OFF するための仕様書です。

---

## 概要

各 Export CF は起動時に Secret Manager から最新の ON/OFF フラグを取得します。  
管理画面から新バージョンを登録するだけで、**CF の再デプロイ・Terraform apply なしに即時反映**されます。

### フラグ優先度

| 優先度 | ソース | 用途 |
|--------|--------|------|
| 1（最高） | `force_resend=true` パラメータ | 手動再送時は常に ON（フラグ無視） |
| 2 | Secret Manager 最新バージョン | 管理画面から動的変更 |
| 3（最低） | 環境変数 `ENABLE_BUBBLE_API = "false"` | フォールバック（Secret Manager 不達時） |

> **フォールバック挙動**: Secret Manager が一時的に取得できない場合、安全側として Bubble API は **OFF** になります。

---

## 対象シークレット一覧

GCPプロジェクト: `smartkeiba`（プロジェクト番号: `56638639323`）

| 環境 | シークレットID | 初期値 |
|------|--------------|--------|
| PRD | `kol_bubble_api_enabled` | `"false"` |
| STG | `kol_bubble_api_enabled_stg` | `"false"` |

1つのシークレットで対象環境の **全 Export CF（schedules / races / race_uma_detail）** を一括制御します。

---

## 設定値の仕様

| 設定値 | 動作 |
|--------|------|
| `"true"` | Bubble API 通知 **ON** |
| `"false"` | Bubble API 通知 **OFF** |

- 大文字小文字は区別しません（`"True"` / `"TRUE"` も有効）
- 前後の空白は自動的に除去されます

---

## 管理画面側の実装

### 必要な IAM

管理画面のサービスアカウントに対して、対象シークレット単位で以下のロールを付与してください：

```
roles/secretmanager.secretVersionAdder
```

対象シークレット（環境に応じて付与）:
- `kol_bubble_api_enabled`（PRD）
- `kol_bubble_api_enabled_stg`（STG）

### Python 実装例

```python
from google.cloud import secretmanager

client = secretmanager.SecretManagerServiceClient()

def set_bubble_api_enabled(enabled: bool, env: str = "stg", project: str = "56638639323"):
    """
    Bubble API の ON/OFF を Secret Manager に新バージョンとして登録する。
    登録後、次回の CF 起動から即時反映される。

    Args:
        enabled: True で ON、False で OFF
        env: "prd" または "stg"
        project: GCP プロジェクト番号
    """
    secret_id = "kol_bubble_api_enabled" if env == "prd" else "kol_bubble_api_enabled_stg"
    parent = f"projects/{project}/secrets/{secret_id}"
    value = "true" if enabled else "false"

    version = client.add_secret_version(
        request={
            "parent": parent,
            "payload": {"data": value.encode("utf-8")},
        }
    )
    return version.name  # 例: projects/56638639323/secrets/.../versions/2


# 使用例: STG を ON にする
set_bubble_api_enabled(True, env="stg")

# 使用例: PRD を OFF にする
set_bubble_api_enabled(False, env="prd")
```

### REST API 実装例

Secret Manager REST API を直接使用する場合：

```
POST https://secretmanager.googleapis.com/v1/projects/56638639323/secrets/{SECRET_ID}/versions:add
Authorization: Bearer {ACCESS_TOKEN}
Content-Type: application/json

{
  "payload": {
    "data": "<base64エンコードした "true" または "false">"
  }
}
```

`"true"` の base64: `dHJ1ZQ==`  
`"false"` の base64: `ZmFsc2U=`

---

## 現在の設定値の確認方法

### Python

```python
from google.cloud import secretmanager

client = secretmanager.SecretManagerServiceClient()

def get_bubble_api_enabled(env: str = "stg", project: str = "56638639323") -> str:
    secret_id = "kol_bubble_api_enabled" if env == "prd" else "kol_bubble_api_enabled_stg"
    name = f"projects/{project}/secrets/{secret_id}/versions/latest"
    version = client.access_secret_version(request={"name": name})
    return version.payload.data.decode("utf-8")

print(get_bubble_api_enabled("stg"))  # "true" または "false"
```

### gcloud CLI

```bash
# STG
gcloud secrets versions access latest \
  --secret="kol_bubble_api_enabled_stg" \
  --project="smartkeiba"

# PRD
gcloud secrets versions access latest \
  --secret="kol_bubble_api_enabled" \
  --project="smartkeiba"
```

---

## 注意事項

- **反映タイミング**: 新バージョン登録後、**次回の CF リクエストから即時反映**されます（再デプロイ不要）
- **force_resend との関係**: `force_resend=true` でのリクエストはこのフラグに関係なく常に Bubble API を呼び出します
- **フォールバック**: Secret Manager 取得失敗時は安全側として **OFF** になります（CF はクラッシュしません）
- **バージョン管理**: 古いバージョンは自動削除されません。バージョン数が増える場合は古いものを手動で無効化してください
- **STG/PRD 分離**: STG と PRD は別シークレット ID で管理されています。誤った環境に登録しないよう注意してください
- **関連ドキュメント**:
  - CF の呼び出し仕様全般: [`bubble-sync-cf-api.md`](./bubble-sync-cf-api.md)
  - Bubble API エンドポイント URL 管理: [`bubble-api-url-secret-manager.md`](./bubble-api-url-secret-manager.md)
