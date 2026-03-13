-- chokyo_den_oikiri_lap_3f の計算ロジック確認用クエリ
-- 期待される計算式: chokyo_den_oikiri_3f_float - chokyo_den_oikiri_1f_float

SELECT
  race_code_uma_jvd,
  chokyo_den_oikiri_course_kubun,
  chokyo_den_oikiri_3f_float,
  chokyo_den_oikiri_1f_float,
  chokyo_den_oikiri_lap_3f,
  -- 検算：期待値 (小数点第一位で丸める)
  ROUND(chokyo_den_oikiri_3f_float - chokyo_den_oikiri_1f_float, 1) AS expected_lap_3f,
  -- 実測値との差分
  ROUND(chokyo_den_oikiri_lap_3f - (chokyo_den_oikiri_3f_float - chokyo_den_oikiri_1f_float), 1) AS diff
FROM
  `race_uma` -- データセット名は環境に合わせて確認してください
WHERE
  chokyo_den_oikiri_lap_3f IS NOT NULL
  AND chokyo_den_oikiri_3f_float IS NOT NULL
  AND chokyo_den_oikiri_1f_float IS NOT NULL
  -- 誤差があるものを抽出 (浮動小数点誤差を考慮して少し余裕を持たせるか、ROUND後の比較)
  AND ROUND(chokyo_den_oikiri_lap_3f, 1) != ROUND(chokyo_den_oikiri_3f_float - chokyo_den_oikiri_1f_float, 1)
LIMIT 100;
