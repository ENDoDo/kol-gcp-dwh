-- race_hit テーブルの抽出結果を確認するためのクエリ

-- 1. 券種ごとの件数集計
SELECT
  kensyu_kubun,
  COUNT(*) AS hit_count,
  MIN(hasso_date) AS min_date,
  MAX(hasso_date) AS max_date
FROM
  `smartkeiba.kolbi_analysis.race_hit`
GROUP BY
  kensyu_kubun
ORDER BY
  hit_count DESC;

-- 2. 具体的な買い目と印の組み合わせを確認 (最新100件)
SELECT
  hasso_date,
  keibajo_name,
  race_bango_num,
  race_name,
  kensyu_kubun,
  umaban_kumiban,
  yosou_shirushi,
  haitou
FROM
  `smartkeiba.kolbi_analysis.race_hit`
ORDER BY
  hasso_date DESC
LIMIT 100;

-- 3. 券種ごとのサンプルを抽出して条件を満たしているか確認
WITH samples AS (
  SELECT
    *,
    ROW_NUMBER() OVER(PARTITION BY kensyu_kubun ORDER BY hasso_date DESC) as rn
  FROM
    `smartkeiba.kolbi_analysis.race_hit`
)
SELECT
  kensyu_kubun,
  hasso_date,
  umaban_kumiban,
  yosou_shirushi,
  haitou
FROM
  samples
WHERE
  rn <= 5
ORDER BY
  kensyu_kubun, hasso_date DESC;
