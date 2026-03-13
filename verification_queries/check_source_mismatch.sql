-- 1. ソースデータ(kol_den2)内に不一致パターンが存在するか全期間で探す
-- (どの程度の頻度で発生しているかを確認)
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
  (
    (chokyo3_flag = '1' AND chokyo_awase_flag = '2' AND chokyo2_flag = '0')
    OR
    (chokyo2_flag = '1' AND chokyo_awase_flag = '3' AND chokyo3_flag = '0')
  )
ORDER BY
  kaisai_nengappi DESC
LIMIT 50;

-- 2. 上記の不一致パターンが1つでも見つかった場合、その race_code_uma_kol を使って
-- race_uma テーブルでの変換結果を確認する
/*
SELECT
  d2.race_code_uma_kol,
  ru.chokyo_den_awase_kubun,
  ru.chokyo_den_awase,
  ru.chokyo_den_awase_flag
FROM
  `smartkeiba.kolbi_keiba_stg.kol_den2` AS d2
JOIN
  `smartkeiba.kolbi_analysis_stg.race_uma` AS ru
  ON d2.race_code_uma_kol = ru.race_code_uma_kol
WHERE
  d2.race_code_uma_kol = '見つかったID'
*/
