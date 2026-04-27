---
name: race-uma-column-addition
description: Use when adding or modifying columns in race_uma.sqlx in the kol-gcp-dwh project. Covers required downstream file updates.
---

# race_uma.sqlx カラム追加時のチェックリスト

## 概要

`race_uma.sqlx` にカラムを追加・変更すると、下流の3ファイルに影響する。SQL層はワイルドカード（`SELECT ru.*`）で自動伝播するが、**JSのメタデータ定義は手動追加が必須**。

## 必須チェックリスト

### 1. `race_uma.sqlx`
- [ ] `columns` オブジェクトにカラム説明を追加（ファイル上部の config ブロック内）
- [ ] CTE内でカラムを計算・定義
- [ ] 最終 SELECT に追加

### 2. `includes/race_uma_detail_bubble.js`
- [ ] `columns` オブジェクトに同じカラムの説明を追加
- 追加位置: 対応する既存カラム（例: `zensou_kankaku`）の直後
- **SQLの修正は不要**（クエリは `SELECT ru.*` のため自動伝播）

### 3. `includes/race_uma_detail_looker.js`
- [ ] `columns` オブジェクトに同じカラムの説明を追加（bubble.js と同じ内容）
- **SQLの修正は不要**（同上）

### 4. `functions/export_race_uma_detail_bubble/main.py`
- [ ] 確認のみ（通常修正不要）
- テーブルスキーマを動的に取得しているため新カラムは自動的にCSV出力に含まれる
- ハッシュ計算の除外リスト（`EXCEPT(...)`）への追加が必要かどうかだけ確認する

### 5. Dataform コンパイル確認
- [ ] `npx @dataform/cli compile` でエラーがないか確認

### 6. Dataform 手動実行 STG → 完了待ち
- [ ] GCP Dataform コンソール > `kol-dataform-repo-stg` からワークフローを手動実行
- [ ] 実行完了（race_uma テーブルの更新）を確認してから次へ進む

### 7. BigQuery 検証 STG
- [ ] 分布確認クエリを `kolbi_analysis_stg` に対して実行（下記参照）
- [ ] 全区分・全値に期待通りのデータが入っているか確認
- [ ] NULL が意図通りか確認

### 8. Dataform 手動実行 PRD → 完了待ち
- [ ] GCP Dataform コンソール > `kol-dataform-repo` からワークフローを手動実行
- [ ] 実行完了を確認してから次へ進む

### 9. BigQuery 検証 PRD
- [ ] 同じクエリを `kolbi_analysis` に対して実行
- [ ] STG と同様の分布になっているか確認

### 10. Notion DB仕様を更新
- [ ] 検証結果をもとに Notion 用テキストを作成し追記（下記参照）

## 各ファイルの役割

| ファイル | 役割 | カラム追加時の作業 |
|---------|------|-----------------|
| `race_uma.sqlx` | マスターテーブル定義 | columns定義 + SQL実装 |
| `race_uma_detail_bubble.sqlx` | Bubble向けビュー（.sqlxは薄いラッパー） | 不要（JSに委譲） |
| `race_uma_detail_looker.sqlx` | Looker向けビュー（同上） | 不要（JSに委譲） |
| `includes/race_uma_detail_bubble.js` | Bubble向けのcolumns定義とquery関数 | **columns定義の追加必須** |
| `includes/race_uma_detail_looker.js` | Looker向けのcolumns定義とquery関数 | **columns定義の追加必須** |
| `functions/export_race_uma_detail_bubble/main.py` | BubbleへのCSVエクスポート | 通常不要（動的スキーマ取得） |

## 検証クエリ（STG / PRD 両方で実行）

`mcp__claude_ai_Google_Cloud_BigQuery__execute_sql_readonly` で実行し、**クエリと結果を必ずプランファイルと会話内に記録する**。STG で確認後、PRD でも同じクエリを実行して分布を比較する。

| 環境 | dataset |
|------|---------|
| STG | `kolbi_analysis_stg` |
| PRD | `kolbi_analysis` |

```sql
-- 区分・ラベル系カラムの場合：分布確認（STGは kolbi_analysis_stg、PRDは kolbi_analysis に変更）
SELECT
  <追加したカラム名>,
  COUNT(*) AS cnt,
  MIN(<元の数値カラム名>) AS val_min,
  MAX(<元の数値カラム名>) AS val_max
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE schedule_id >= '20250101'
GROUP BY <追加したカラム名>
ORDER BY val_min NULLS LAST
```

```sql
-- 数値・フラグ系カラムの場合：サンプル確認
SELECT
  race_code_uma_jvd,
  bamei,
  <追加したカラム名>,
  kyoso_joken_kubun_label
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE schedule_id >= '20250101'
ORDER BY hasso_date DESC
LIMIT 100
```

確認ポイント:
- 全区分に期待件数のデータがあるか（分布が極端に偏っていないか）
- val_min / val_max が仕様の境界値と一致しているか
- NULL が意図通りか（NULL 行が別グループとして表示される）
- STG と PRD で同様の分布になっているか
- 前走データが存在する行と初出走行で正しく値が分岐しているか（前走系カラムの場合）

## Notion用テキスト

検証後、DB仕様のNotionページに以下の形式で追記する。**検証結果（件数・分布）も合わせてコメントとして記録する。**

```
| <カラム名> | | - | - | <説明文（race_uma.sqlxのcolumns定義と同じ内容）> |
```

例:
```
| yosou_tansho_odds_kubun | | - | - | yosou_tansho_odds_floatを元に判定 1.0〜1.4/1.5〜1.9/2.0〜2.9/3.0〜3.9/4.0〜4.9/5.0〜6.9/7.0〜9.9/10.0〜14.9/15.0〜19.9/20.0〜29.9/30.0〜49.9/50以上 |
```

追記先: DB仕様 > race_umaテーブルのカラム一覧（関連カラムの直後）
