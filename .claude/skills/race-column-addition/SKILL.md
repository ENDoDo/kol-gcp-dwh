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

## 各ファイルの役割

| ファイル | 役割 | カラム追加時の作業 |
|---------|------|-----------------|
| `definitions/race.sqlx` | レースマスターテーブル定義 | columns定義 + SQL実装 |
| `includes/race_uma_detail_bubble.js` | Bubble向けdetailのcolumns定義とquery | **columns定義の追加必須** |
| `includes/race_uma_detail_looker.js` | Looker向けdetailのcolumns定義とquery | **columns定義の追加必須** |

## なぜJSの修正が必要か

両JSファイルの `query` 関数は `r.* EXCEPT(...)` でraceの全カラムを取得する。  
SQLレベルでは新カラムは自動的に含まれるが、`columns` オブジェクト（Dataformのカラムドキュメント）は手動管理のため、追記しないと説明なしのカラムになる。
