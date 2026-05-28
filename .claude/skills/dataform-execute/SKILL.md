---
name: dataform-execute
description: Use when manually triggering a Dataform workflow run for this project (STG or PRD), polling for completion, and running BigQuery verification queries. gcloud does not have a native dataform command — use the Python REST API approach documented here.
---

# Dataform 手動実行スキル

## ⚠️ 実行前の必須チェック（BLOCKING）

**Dataform は main ブランチのコードを実行する。feature ブランチのままでは変更が反映されない。**

Dataform を実行する前に必ず以下を確認すること：

```bash
git branch --show-current
git log --oneline origin/main..HEAD
```

- **現在のブランチが `main` 以外** → まず PR を作成してマージしてから実行する
- **`origin/main` より先にコミットがある** → まず PR をマージしてから実行する

どちらかに該当する場合は **STOP**。ユーザーにマージを依頼し、確認が取れてから実行に進む。

---

## 概要

このプロジェクトの Dataform ワークフローは `gcloud` に `dataform` サブコマンドがないため、**Python + REST API** で実行する。ADC（Application Default Credentials）から OAuth2 トークンを取得し、Dataform API と BigQuery API を直接呼び出す。

## 環境情報

| 項目 | 値 |
|------|----|
| GCP プロジェクト | `smartkeiba` |
| リージョン | `asia-northeast1` |
| STG リポジトリ | `kol-dataform-repo-stg` |
| PRD リポジトリ | `kol-dataform-repo` |
| STG ワークフロー | `daily-race-table-update-stg` |
| PRD ワークフロー | `daily-race-table-update` |
| ADC ファイル | `~/.config/gcloud/application_default_credentials.json` |

## 共通ヘルパー

```python
import json, urllib.request, urllib.parse, time

with open('/Users/endodo/.config/gcloud/application_default_credentials.json') as f:
    creds = json.load(f)

def get_token():
    data = urllib.parse.urlencode({
        'client_id': creds['client_id'],
        'client_secret': creds['client_secret'],
        'refresh_token': creds['refresh_token'],
        'grant_type': 'refresh_token'
    }).encode()
    req = urllib.request.Request('https://oauth2.googleapis.com/token', data=data,
        headers={'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)['access_token']
```

## Dataform ワークフロー実行

**必ず以下の手順で実行すること。workflowConfig 経由は compilationResult が古い場合があるため、常に新規 compilationResult を作成して使う。**

```python
import subprocess

# ENV: 'stg' or 'prd'
ENV = 'stg'
REPO = 'kol-dataform-repo-stg' if ENV == 'stg' else 'kol-dataform-repo'
WF   = 'daily-race-table-update-stg' if ENV == 'stg' else 'daily-race-table-update'
LOC  = 'asia-northeast1'

# 環境ごとの codeCompilationConfig
COMPILE_CONFIG = {
    'stg': {
        "defaultDatabase": "smartkeiba",
        "defaultSchema": "kolbi_analysis_stg",
        "vars": {"source_schema": "kolbi_keiba_stg"}
    },
    'prd': {
        "defaultDatabase": "smartkeiba",
        "defaultSchema": "kolbi_analysis",
        "vars": {"source_schema": "kolbi_keiba"}
    }
}

# Step 1: 現在の main SHA を取得
sha = subprocess.check_output(
    ['git', 'rev-parse', 'main'],
    cwd='/Users/endodo/Source/kol-gcp-dwh'
).decode().strip()
print(f"main SHA: {sha}")

# Step 2: 新規 compilationResult を作成（環境固有の config を指定）
body = json.dumps({
    "gitCommitish": sha,
    "codeCompilationConfig": COMPILE_CONFIG[ENV]
}).encode()
req = urllib.request.Request(
    f'https://dataform.googleapis.com/v1beta1/projects/smartkeiba/locations/{LOC}/repositories/{REPO}/compilationResults',
    data=body, method='POST',
    headers={'Authorization': f'Bearer {get_token()}', 'Content-Type': 'application/json'}
)
with urllib.request.urlopen(req) as resp:
    comp = json.load(resp)
comp_name = comp['name']
resolved_sha = comp.get('resolvedGitCommitSha', sha)
print(f"compilationResult: {comp_name}")
print(f"resolvedGitCommitSha: {resolved_sha}")

# SHA の一致を確認（不一致の場合は STOP してユーザーに報告）
if resolved_sha != sha:
    print(f"⚠️ SHA mismatch! Expected {sha}, got {resolved_sha}. STOP.")
    exit(1)
if comp.get('compilationErrors'):
    print(f"⚠️ compilationErrors: {comp['compilationErrors']}")
    exit(1)
print("✓ compilationResult is fresh and matches main")

# Step 3: workflowConfig の invocationConfig を取得
req = urllib.request.Request(
    f'https://dataform.googleapis.com/v1beta1/projects/smartkeiba/locations/{LOC}/repositories/{REPO}/workflowConfigs/{WF}',
    headers={'Authorization': f'Bearer {get_token()}'}
)
with urllib.request.urlopen(req) as resp:
    wf_config = json.load(resp)
invocation_config = wf_config['invocationConfig']

# Step 4: 新規 compilationResult + workflowConfig の invocationConfig で実行
body = json.dumps({
    "compilationResult": comp_name,
    "invocationConfig": invocation_config
}).encode()
req = urllib.request.Request(
    f'https://dataform.googleapis.com/v1beta1/projects/smartkeiba/locations/{LOC}/repositories/{REPO}/workflowInvocations',
    data=body, method='POST',
    headers={'Authorization': f'Bearer {get_token()}', 'Content-Type': 'application/json'}
)
with urllib.request.urlopen(req) as resp:
    inv = json.load(resp)

invocation_name = inv['name']
print(f"Started: {inv['state']}")

# Poll until done (30s intervals)
for i in range(40):
    time.sleep(30)
    req2 = urllib.request.Request(
        f'https://dataform.googleapis.com/v1beta1/{invocation_name}',
        headers={'Authorization': f'Bearer {get_token()}'}
    )
    with urllib.request.urlopen(req2) as resp:
        status = json.load(resp)
    state = status['state']
    print(f"[{(i+1)*30}s] {state}")
    if state not in ('RUNNING', 'PENDING'):
        break
```

## BigQuery 検証クエリ実行

```python
DATASET = 'kolbi_analysis_stg' if ENV == 'stg' else 'kolbi_analysis'

def run_bq(query):
    body = json.dumps({
        "configuration": {"query": {"query": query, "useLegacySql": False}},
        "jobReference": {"projectId": "smartkeiba", "location": "asia-northeast1"}
    }).encode()
    req = urllib.request.Request(
        'https://bigquery.googleapis.com/bigquery/v2/projects/smartkeiba/jobs',
        data=body, method='POST',
        headers={'Authorization': f'Bearer {get_token()}', 'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(req) as resp:
        job = json.load(resp)
    job_id = job['jobReference']['jobId']

    for _ in range(20):
        time.sleep(3)
        req2 = urllib.request.Request(
            f'https://bigquery.googleapis.com/bigquery/v2/projects/smartkeiba/jobs/{job_id}?location=asia-northeast1',
            headers={'Authorization': f'Bearer {get_token()}'}
        )
        with urllib.request.urlopen(req2) as resp:
            status = json.load(resp)
        if status['status']['state'] == 'DONE':
            break

    if 'errorResult' in status['status']:
        print("ERROR:", status['status']['errorResult'])
        return

    req3 = urllib.request.Request(
        f'https://bigquery.googleapis.com/bigquery/v2/projects/smartkeiba/queries/{job_id}?location=asia-northeast1&maxResults=100&timeoutMs=30000',
        headers={'Authorization': f'Bearer {get_token()}'}
    )
    with urllib.request.urlopen(req3) as resp:
        results = json.load(resp)

    fields = [f['name'] for f in results['schema']['fields']]
    print('\t'.join(fields))
    for row in results.get('rows', []):
        vals = [v.get('v', '') if v.get('v') is not None else 'NULL' for v in row['f']]
        print('\t'.join(vals))
```

## 注意点

- `gcloud auth print-access-token` はセッション外で認証エラーになる → 必ず ADC ファイルから直接トークンを取得する
- BigQuery ジョブのリージョンは `asia-northeast1`（US ではない）→ `location` パラメータを必ず指定する
- STG → PRD の順番で実行し、両環境で検証してから Notion を更新する
- Dataform 実行は通常 30 秒以内に SUCCEEDED になる
- **compilationResult の鮮度**: `workflowConfig` のみを指定する実行は `releaseConfig` が古い compilationResult を使う場合があり、マージ直後でも旧コードで動く。上記の手順では常に最新 main SHA から compilationResult を新規作成するため、この問題を回避できる。SHA の不一致が検出された場合は STOP すること。
- **ADC トークン期限切れ**: RAPT エラー（`invalid_rapt`）が出た場合は `gcloud auth application-default login` で再認証が必要
