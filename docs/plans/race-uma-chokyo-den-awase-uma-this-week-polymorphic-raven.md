# Plan: chokyo_den_awase_uma_this_week_race_code_uma_jvd カラム追加

## Context
竹内さんから「調教の併せ馬が今週出走するかどうか」の検証依頼。  
今週出走する相手との先着は本気仕上げの証拠になりうるという仮説を検証するため、  
まず最小限のカラム（`race_code_uma_jvd`）を追加し、集計はデータスタジオの計算フィールドで行う方針。

## カラム仕様

**カラム名**: `chokyo_den_awase_uma_this_week_race_code_uma_jvd`  
**型**: STRING  
**説明**: 調教併せ馬が今週出走する場合のrace_code_uma_jvd。該当しない場合はnull。

### 「今週出走する」の判定条件

| 当該馬の開催曜日 | 条件 |
|---|---|
| **土曜日**（DAYOFWEEK=7） | 当日（同じ土曜）に併せ馬と同名の出走馬がいる **OR** 翌日（日曜）の特別・重賞（ippan_tokubetsu_kubun IN ('1','2','3')）に出走 |
| **日曜日**（DAYOFWEEK=1） | 当日（日曜）または前日（土曜）に同名の出走馬がいる |

## 修正ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `definitions/race_uma.sqlx` | ①config columnsに追加 ②新CTE追加 ③final SELECTに追加 ④JOINに追加 |
| `includes/race_uma_detail_bubble.js` | columnsに追加（line 112直後） |
| `includes/race_uma_detail_looker.js` | columnsに追加（line 112直後） |

---

## 実装詳細

### 1. `race_uma.sqlx` — config block（line 107直後）

```javascript
chokyo_den_awase_uma_this_week_race_code_uma_jvd: "出馬表出走馬データ 調教併せ馬 今週出走する場合のrace_code_uma_jvd（土曜開催：当日または翌日特別/重賞、日曜開催：当日または前日）今週出走しない場合はnull",
```

### 2. `race_uma.sqlx` — 新CTE（partner_lookup終端 line 1045直後）

`partner_lookup`（既存、併せ当時クラス取得）とは別に、今週の出走を探す専用CTEを追加する。

```sql
  this_week_partner_lookup AS (
    SELECT
      z.race_code_uma_kol,
      SUBSTR(p.race_code_uma_kol, 1, 8)
      || CASE SUBSTR(p.race_code_uma_kol, 9, 2)
           WHEN '08' THEN '01' WHEN '09' THEN '02' WHEN '06' THEN '03'
           WHEN '07' THEN '04' WHEN '04' THEN '05' WHEN '05' THEN '06'
           WHEN '02' THEN '07' WHEN '00' THEN '08' WHEN '01' THEN '09'
           WHEN '03' THEN '10' ELSE NULL
         END
      || SUBSTR(p.race_code_uma_kol, 11, 8) AS this_week_race_code_uma_jvd
    FROM
      with_zensou_data AS z
    INNER JOIN
      ${ref("kol_den2")} AS p
      ON z.chokyo_den_oikiri_awase_uma_bamei = p.bamei
    LEFT JOIN
      ${ref("kol_den1")} AS d1
      ON SUBSTR(p.race_code_uma_kol, 1, 16) = d1.race_code_kol
    WHERE
      z.chokyo_den_oikiri_awase_uma_bamei IS NOT NULL
      AND z.chokyo_den_oikiri_awase_uma_bamei != ''
      AND (
        -- 土曜日開催の場合
        (
          EXTRACT(DAYOFWEEK FROM PARSE_DATE('%Y%m%d', z.kaisai_nengappi)) = 7
          AND (
            p.kaisai_nengappi = z.kaisai_nengappi
            OR (
              p.kaisai_nengappi = FORMAT_DATE('%Y%m%d', DATE_ADD(PARSE_DATE('%Y%m%d', z.kaisai_nengappi), INTERVAL 1 DAY))
              AND d1.ippan_tokubetsu_kubun IN ('1', '2', '3')
            )
          )
        )
        OR
        -- 日曜日開催の場合
        (
          EXTRACT(DAYOFWEEK FROM PARSE_DATE('%Y%m%d', z.kaisai_nengappi)) = 1
          AND (
            p.kaisai_nengappi = z.kaisai_nengappi
            OR p.kaisai_nengappi = FORMAT_DATE('%Y%m%d', DATE_SUB(PARSE_DATE('%Y%m%d', z.kaisai_nengappi), INTERVAL 1 DAY))
          )
        )
      )
    QUALIFY
      ROW_NUMBER() OVER (PARTITION BY z.race_code_uma_kol ORDER BY p.kaisai_nengappi ASC, p.race_num ASC) = 1
  ),
```

**注意点**:
- `race_code_uma_jvd` の構築は既存の `race_code_uma_jvd_zensou`（lines 1243-1252）と同じパターン（SUBSTR + CASE変換）
- 土曜の翌日特別判定のみ `kol_den1.ippan_tokubetsu_kubun` が必要（d1 LEFT JOINで取得）
- QUALIFY で重複除去（同名馬が複数いる場合に備え）

### 3. `race_uma.sqlx` — final SELECT（`chokyo_den_awase_uma_kakuue_win_flag` の後）

```sql
  CASE WHEN z.chokyo_den_oikiri_awase IS NOT NULL THEN twpl.this_week_race_code_uma_jvd ELSE NULL END AS chokyo_den_awase_uma_this_week_race_code_uma_jvd,
```

### 4. `race_uma.sqlx` — FROM句（`partner_lookup AS pl` の後）

```sql
LEFT JOIN
  this_week_partner_lookup AS twpl
  ON z.race_code_uma_kol = twpl.race_code_uma_kol
```

### 5. `includes/race_uma_detail_bubble.js`（`chokyo_den_awase_uma_kakuue_win_flag` の直後）

```javascript
    chokyo_den_awase_uma_this_week_race_code_uma_jvd: "出馬表出走馬データ 調教併せ馬 今週出走する場合のrace_code_uma_jvd（土曜開催：当日または翌日特別/重賞、日曜開催：当日または前日）今週出走しない場合はnull",
```

### 6. `includes/race_uma_detail_looker.js`（同上）

（bubble.js と同じ内容）

---

## 検証

### Dataform コンパイル
```
npx @dataform/cli compile
```

### STG 検証クエリ（実行タイミング：STG Dataform完了後）

```sql
-- 今週出走フラグの分布確認
SELECT
  CASE
    WHEN chokyo_den_awase_uma_this_week_race_code_uma_jvd IS NOT NULL THEN '今週出走あり'
    WHEN chokyo_den_awase_uma_bamei IS NOT NULL THEN '今週出走なし（併せ馬あり）'
    ELSE '併せ馬なし'
  END AS status,
  COUNT(*) AS cnt
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE schedule_id >= '20250101'
GROUP BY 1
ORDER BY 1;
```

```sql
-- サンプル確認（今週出走あり馬）
SELECT
  schedule_id,
  bamei,
  chokyo_den_awase_uma_bamei,
  chokyo_den_awase_uma_this_week_race_code_uma_jvd,
  chokyo_den_awase_uma_kaku_kubun,
  chokyo_den_awase_uma_kakuue_win_flag
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE schedule_id >= '20250101'
  AND chokyo_den_awase_uma_this_week_race_code_uma_jvd IS NOT NULL
ORDER BY hasso_date DESC
LIMIT 50;
```

確認ポイント:
- `chokyo_den_awase_uma_bamei` が NOT NULL かつ今週出走ありの件数が合理的か
- `schedule_id` と `chokyo_den_awase_uma_this_week_race_code_uma_jvd` の日付部分（先頭8文字）が同一週（土日）に収まっているか
- 土曜開催行 → 同日または翌日特別のみ
- 日曜開催行 → 同日または前日のみ
