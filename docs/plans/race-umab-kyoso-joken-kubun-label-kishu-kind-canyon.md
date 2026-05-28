# Plan: kishu_tennori_flag が新馬戦（3歳）で null になるバグ修正

## Context

担当者から、`kyoso_joken_kubun_label = '新馬'` のレコード約2,809件で `kishu_tennori_flag` が null になっているとの報告。新馬戦は初出走のため、常にテン乗り（'はい'）が期待値。

## 調査結果

BigQuery で確認した内訳：

| barei_num | null件数 | 原因 |
|-----------|---------|------|
| 3（3歳新馬） | 2,902 | **バグ**: `uma_min_barei = 3` で条件不合致 |
| 2（2歳新馬） | 13 | **正常**: 同馬×同騎手の2回目の新馬戦（`kishu_uma_rn = 2`） |

### 現在のロジック

```sql
-- definitions/race_uma.sqlx line 1411-1414
CASE
  WHEN z.kishu_uma_rn = 1 AND z.uma_min_barei = 2 THEN 'はい'
  ELSE NULL
END AS kishu_tennori_flag,
```

- `kishu_uma_rn`: 馬×騎手の出走順（1=初騎乗）
- `uma_min_barei`: データ内でその馬の最小馬齢

**バグの根本原因**: `uma_min_barei = 2` は「2歳デビューのデータが揃っている馬のみ判定」を意図。しかし3歳でデビューする3歳新馬の場合、`uma_min_barei = 3` となり条件を満たせない。新馬戦は定義上初出走のため、`uma_min_barei` チェックは不要。

## 修正内容

### 1. `definitions/race_uma.sqlx`

**① CASE式修正 (line 1411-1414)**

```sql
-- 修正前
CASE
  WHEN z.kishu_uma_rn = 1 AND z.uma_min_barei = 2 THEN 'はい'
  ELSE NULL
END AS kishu_tennori_flag,

-- 修正後
CASE
  WHEN z.kishu_uma_rn = 1 AND (z.kyoso_joken_kubun = '00001' OR z.uma_min_barei = 2) THEN 'はい'
  ELSE NULL
END AS kishu_tennori_flag,
```

`z.kyoso_joken_kubun` は `base_data`（line 639）で SELECT され、途中のCTEはすべて `SELECT *` で引き継ぐため参照可能。

**② カラム説明更新 (line 67)**

```
-- 修正前
kishu_tennori_flag: "テン乗り(騎手がこの馬に初めて騎乗)の場合は「はい」該当しない場合はnull。デビュー時からのデータが揃っている馬のみ対象（データ範囲2018年以降のため、馬の最小馬齢が2歳の場合のみ判定）"

-- 修正後
kishu_tennori_flag: "テン乗り(騎手がこの馬に初めて騎乗)の場合は「はい」、該当しない場合はnull。新馬戦は初出走のため常に判定対象。新馬戦以外は、デビュー時からのデータが揃っている馬のみ対象（データ範囲2018年以降のため、馬の最小馬齢が2歳の場合のみ判定）"
```

### 2. `includes/race_uma_detail_bubble.js` (line 57)

カラム説明を同様に更新（race_uma.sqlx ②と同文）。

### 3. `includes/race_uma_detail_looker.js` (line 57)

カラム説明を同様に更新（race_uma.sqlx ②と同文）。

## 修正ファイル一覧

| ファイル | 変更箇所 |
|---------|---------|
| `definitions/race_uma.sqlx` | line 67: カラム説明、line 1411-1414: CASE式 |
| `includes/race_uma_detail_bubble.js` | line 57: カラム説明 |
| `includes/race_uma_detail_looker.js` | line 57: カラム説明 |

## 検証クエリ（STG）

```sql
-- 修正後、3歳新馬でnullが0件になることを確認
SELECT COUNT(*)
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE kyoso_joken_kubun = '00001'
  AND barei_num = 3
  AND kishu_tennori_flag IS NULL;
-- 期待値: 0

-- 修正後、新馬戦全体のテン乗りフラグ分布
SELECT kishu_tennori_flag, COUNT(*) AS cnt
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE kyoso_joken_kubun = '00001'
GROUP BY kishu_tennori_flag;
-- 期待: はい が大多数、null は同馬×同騎手の2回目新馬戦のみ
```
