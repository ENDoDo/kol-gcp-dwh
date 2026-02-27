-- =================================================================
-- rating_rank カラムの検証用クエリ
-- 説明: 各レースにおいて rating_rank が正しく算出されているか確認する。
-- 1. レイティング順位が1位から順に並んでいるか
-- 2. 同値の場合に同じ順位が付与され、次がスキップされているか
-- 3. NULL の場合は順位も NULL になっているか
-- =================================================================

WITH check_rank AS (
  SELECT
    race_code_kol,
    bamei,
    rating_float,
    rating_rank,
    -- 同一レース内での検証用フラグ
    COUNT(*) OVER(PARTITION BY race_code_kol) as horse_count,
    COUNT(rating_float) OVER(PARTITION BY race_code_kol) as rated_horse_count
  FROM
    `smartkeiba.kolbi_analysis.race_uma`
  WHERE
    hasso_date >= '2025-01-01' -- 直近のデータで確認
)

-- 確認用ケース1: 順位が正しく付いているか（上位10レース分をサンプリング）
SELECT
  race_code_kol,
  bamei,
  rating_float,
  rating_rank
FROM
  check_rank
WHERE
  race_code_kol IN (
    SELECT DISTINCT race_code_kol
    FROM check_rank
    WHERE rated_horse_count > 0
    LIMIT 10
  )
ORDER BY
  race_code_kol,
  rating_rank;


-- 確認用ケース2: 同順位・スキップの発生しているレースを特定して確認
SELECT
  race_code_kol,
  bamei,
  rating_float,
  rating_rank
FROM
  check_rank
WHERE
  race_code_kol IN (
    -- 同じ順位が重複しているレースを抽出
    SELECT
      race_code_kol
    FROM
      check_rank
    WHERE
      rating_rank IS NOT NULL
    GROUP BY
      race_code_kol, rating_rank
    HAVING
      COUNT(*) > 1
    LIMIT 5
  )
ORDER BY
  race_code_kol,
  rating_rank;
