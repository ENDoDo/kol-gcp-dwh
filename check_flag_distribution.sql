-- 調教フラグと併せフラグの分布状況を確認するクエリ
-- 現状、どのようなフラグの組み合わせが存在するかを把握します。

SELECT
  chokyo2_flag,
  chokyo3_flag,
  chokyo_awase_flag,
  COUNT(*) as count
FROM
  `smartkeiba.kolbi_keiba_stg.kol_den2`
GROUP BY
  1, 2, 3
ORDER BY
  1, 2, 3;

-- また、併せフラグがNULLや空文字でないデータのサンプルを確認
SELECT
  kaisai_nengappi,
  race_code_uma_kol,
  bamei,
  chokyo2_flag,
  chokyo3_flag,
  chokyo_awase_flag,
  chokyo_awase
FROM
  `smartkeiba.kolbi_keiba_stg.kol_den2`
WHERE
  chokyo_awase_flag IN ('2', '3')
LIMIT 20;
