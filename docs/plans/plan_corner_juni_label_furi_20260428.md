# 実装プラン: コーナー順位ラベル修正 & furi列追加（race_uma）

**実施日**: 2026-04-28
**ステータス**: 実施中

## Context

コーナー順位（corner[1/2/3/4]_juni）のラベル列が期待通りに動作していなかった。
現状は `LPAD(value, 2, '0')` で値をそのまま返すため、`43` → `"43"` になってしまう。
KOLデータでは40以上の値は「不利あり + 実順位」を表すため、40を引いた値がラベル表示に必要（例: 43 → 3）。
また、落馬(31)・中止(32)・不利(40以上)を示す `corner[1/2/3/4]_juni_furi` 列が存在しないため新規追加する。

## 仕様

| corner_juni 値 | corner_juni_label | corner_juni_furi |
|---|---|---|
| 1〜28 | 整数のまま（例: 3） | null |
| 31 | null | 落馬 |
| 32 | null | 中止 |
| 40以上 | 値 - 40（例: 43→3, 50→10） | 不利 |
| それ以外 | null | null |

## 変更ファイル

### 1. `definitions/race_uma.sqlx`

#### 1-a. config block columns（L234〜L241付近）

```javascript
// 変更後
corner1_juni: "1角順位",
corner1_juni_label: "corner1_juniをもとに対応 01〜28 40以上の場合は40を差し引く",
corner1_juni_furi: "corner1_juniをもとに対応 31:落馬 32:中止 40以上:不利",
corner2_juni: "2角順位",
corner2_juni_label: "corner2_juniをもとに対応 01〜28 40以上の場合は40を差し引く",
corner2_juni_furi: "corner2_juniをもとに対応 31:落馬 32:中止 40以上:不利",
corner3_juni: "3角順位",
corner3_juni_label: "corner3_juniをもとに対応 01〜28 40以上の場合は40を差し引く",
corner3_juni_furi: "corner3_juniをもとに対応 31:落馬 32:中止 40以上:不利",
corner4_juni: "4角順位",
corner4_juni_label: "corner4_juniをもとに対応 01〜28 40以上の場合は40を差し引く",
corner4_juni_furi: "corner4_juniをもとに対応 31:落馬 32:中止 40以上:不利",
```

#### 1-b. with_zensou_data CTE（L930〜L942付近）

`corner3_juni_label_zensou` と `corner4_juni_label_zensou` の LAG ロジックを新仕様に合わせて更新。

```sql
-- 変更後（corner3例、corner4も同様）
LAG(
  CASE
    WHEN SAFE_CAST(corner3_juni AS INT64) BETWEEN 1 AND 28
      THEN CAST(SAFE_CAST(corner3_juni AS INT64) AS STRING)
    WHEN SAFE_CAST(corner3_juni AS INT64) >= 40
      THEN CAST(SAFE_CAST(corner3_juni AS INT64) - 40 AS STRING)
    ELSE NULL
  END, 1
) OVER (PARTITION BY ketto_toroku_bango ORDER BY hasso_date) AS corner3_juni_label_zensou,
```

#### 1-c. 最終 SELECT（L1820〜L1839付近）

```sql
-- 変更後（corner1例、corner2/3/4も同様）
z.corner1_juni,
CASE
  WHEN SAFE_CAST(z.corner1_juni AS INT64) BETWEEN 1 AND 28
    THEN CAST(SAFE_CAST(z.corner1_juni AS INT64) AS STRING)
  WHEN SAFE_CAST(z.corner1_juni AS INT64) >= 40
    THEN CAST(SAFE_CAST(z.corner1_juni AS INT64) - 40 AS STRING)
  ELSE NULL
END AS corner1_juni_label,
CASE
  WHEN SAFE_CAST(z.corner1_juni AS INT64) = 31 THEN '落馬'
  WHEN SAFE_CAST(z.corner1_juni AS INT64) = 32 THEN '中止'
  WHEN SAFE_CAST(z.corner1_juni AS INT64) >= 40 THEN '不利'
  ELSE NULL
END AS corner1_juni_furi,
```

### 2. `includes/race_uma_detail_bubble.js`

config block の corners 定義を race_uma.sqlx と同様の内容に更新・追加。

### 3. `includes/race_uma_detail_looker.js`

bubble.js と同内容を同箇所に追加・更新。

## 検証結果

→ 実施後に追記予定

### 検証クエリ

```sql
SELECT
  corner1_juni,
  corner1_juni_label,
  corner1_juni_furi,
  COUNT(*) AS cnt
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE schedule_id >= '20250101'
GROUP BY 1, 2, 3
ORDER BY SAFE_CAST(corner1_juni AS INT64) NULLS LAST
LIMIT 50
```
