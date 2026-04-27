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

## 各ファイルの役割

| ファイル | 役割 | カラム追加時の作業 |
|---------|------|-----------------|
| `race_uma.sqlx` | マスターテーブル定義 | columns定義 + SQL実装 |
| `race_uma_detail_bubble.sqlx` | Bubble向けビュー（.sqlxは薄いラッパー） | 不要（JSに委譲） |
| `race_uma_detail_looker.sqlx` | Looker向けビュー（同上） | 不要（JSに委譲） |
| `includes/race_uma_detail_bubble.js` | Bubble向けのcolumns定義とquery関数 | **columns定義の追加必須** |
| `includes/race_uma_detail_looker.js` | Looker向けのcolumns定義とquery関数 | **columns定義の追加必須** |
| `functions/export_race_uma_detail_bubble/main.py` | BubbleへのCSVエクスポート | 通常不要（動的スキーマ取得） |
