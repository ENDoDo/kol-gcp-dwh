---
name: race-column-addition
description: Use when adding or modifying columns in race.sqlx in the kol-gcp-dwh project. Covers required downstream JS file updates.
---

# race.sqlx カラム追加時のチェックリスト

## 概要

`race.sqlx` にカラムを追加・変更すると、detailビュー用のJSファイルにも影響する。SQLは `r.*` で自動伝播するが、**JSのメタデータ定義は手動追加が必須**。

## 必須チェックリスト

### 1. `definitions/race.sqlx`
- [ ] `columns` オブジェクトにカラム説明を追加（config ブロック内）
- [ ] `labels` CTEまたは最終SELECT内でカラムを定義
- [ ] 最終SELECT に追加

### 2. `includes/race_uma_detail_bubble.js`
- [ ] `columns` オブジェクトの `--- raceテーブル由来のカラム ---` セクションに説明を追加
- **SQLの修正は不要**（クエリは `r.*` のため自動伝播）

### 3. `includes/race_uma_detail_looker.js`
- [ ] `columns` オブジェクトの同セクションに同じ説明を追加（bubble.js と同じ内容）
- **SQLの修正は不要**（同上）

### 4. Dataform コンパイル確認
- [ ] `npx @dataform/cli compile` でエラーがないか確認

### 5. Dataform 手動実行 STG → 完了待ち
- [ ] GCP Dataform コンソール > `kol-dataform-repo-stg` からワークフローを手動実行
- [ ] 実行完了（race テーブルの更新）を確認してから次へ進む

### 6. BigQuery 検証 STG
- [ ] 分布確認クエリを `kolbi_analysis_stg` に対して実行（下記参照）
- [ ] 値が期待通りか確認（**クエリと結果を必ずプランファイルと会話内に記録する**）

### 7. Dataform 手動実行 PRD → 完了待ち
- [ ] GCP Dataform コンソール > `kol-dataform-repo` からワークフローを手動実行
- [ ] 実行完了を確認してから次へ進む

### 8. BigQuery 検証 PRD
- [ ] 同じクエリを `kolbi_analysis` に対して実行
- [ ] STG と同様の分布になっているか確認

### 9. Notion DB仕様を更新
- [ ] 検証結果をもとに Notion 用テキストを作成し追記（下記参照）

## 各ファイルの役割

| ファイル | 役割 | カラム追加時の作業 |
|---------|------|-----------------|
| `definitions/race.sqlx` | レースマスターテーブル定義 | columns定義 + SQL実装 |
| `includes/race_uma_detail_bubble.js` | Bubble向けdetailのcolumns定義とquery | **columns定義の追加必須** |
| `includes/race_uma_detail_looker.js` | Looker向けdetailのcolumns定義とquery | **columns定義の追加必須** |

## なぜJSの修正が必要か

両JSファイルの `query` 関数は `r.* EXCEPT(...)` でraceの全カラムを取得する。  
SQLレベルでは新カラムは自動的に含まれるが、`columns` オブジェクト（Dataformのカラムドキュメント）は手動管理のため、追記しないと説明なしのカラムになる。

## 検証クエリ（STG / PRD 両方で実行）

`mcp__claude_ai_Google_Cloud_BigQuery__execute_sql_readonly` で実行し、**クエリと結果を必ずプランファイルと会話内に記録する**。

| 環境 | dataset |
|------|---------|
| STG | `kolbi_analysis_stg` |
| PRD | `kolbi_analysis` |

```sql
-- 区分・ラベル系カラムの場合：分布確認（STGは kolbi_analysis_stg、PRDは kolbi_analysis に変更）
SELECT
  <追加したカラム名>,
  COUNT(*) AS cnt
FROM `smartkeiba.kolbi_analysis_stg.race`
WHERE schedule_id >= '20250101'
GROUP BY <追加したカラム名>
ORDER BY cnt DESC
```

```sql
-- 数値・フラグ系カラムの場合：サンプル確認
SELECT
  race_code_kol,
  kyosomei_15moji,
  <追加したカラム名>,
  kyoso_joken_kubun_label
FROM `smartkeiba.kolbi_analysis_stg.race`
WHERE schedule_id >= '20250101'
ORDER BY hasso_date DESC
LIMIT 100
```

確認ポイント:
- 値が期待通りか（NULLがないか、分布がおかしくないか）
- `kyosomei_15moji IS NOT NULL` の行と NULL の行で値が正しく分岐しているか（平場/特別系カラムの場合）
- STG と PRD で同様の分布になっているか

## Notion用テキスト

検証後、DB仕様のNotionページに以下の形式で追記する。**検証結果（件数・分布）も合わせてコメントとして記録する。**

```
| <カラム名> | | - | - | <説明文（race.sqlxのcolumns定義と同じ内容）> |
```

例:
```
| kyoso_hiraba_tokubetsu_kubun | | - | - | kyosomei_15mojiに値がある場合は特別、そうでない場合は平場 |
```

追記先: DB仕様 > raceテーブルのカラム一覧（`kyoso_joken_kubun_label` の直後）
