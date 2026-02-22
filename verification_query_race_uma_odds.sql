-- race_uma_odds.sqlx の修正確認用クエリ
-- KeibajyoCode が置換されずにそのまま race_code_uma_kol (9,10文字目) に含まれているかを確認します。

SELECT
  SUBSTR(race_code_uma_kol, 9, 2) AS track_code_in_id,
  COUNT(*) AS record_count,
  ANY_VALUE(race_code_uma_kol) AS sample_race_code_uma_kol,
  MIN(hasso_date) AS min_hasso_date,
  MAX(hasso_date) AS max_hasso_date
FROM
  `smartkeiba.kolbi_analysis.race_uma_odds`
GROUP BY
  track_code_in_id
ORDER BY
  track_code_in_id;

-- ソーステーブルとの不一致がないか確認するクエリ
-- (KeibajyoCode が既に KOL 仕様であるという前提の確認)
/*
SELECT
  s.KeibajyoCode AS source_code,
  SUBSTR(t.race_code_uma_kol, 9, 2) AS target_code,
  t.race_code_uma_kol,
  t.hasso_date
FROM
  `smartkeiba.kolbi_analysis.race_uma_odds` AS t
JOIN
  `smartkeiba.kolbi_keiba.races_uma_odds_jvd_new` AS s
ON
  t.race_code_uma_kol = s.Year || s.MonthDay || s.KeibajyoCode || s.Kaiji || s.Nichiji || s.RaceNum || s.Umaban
WHERE
  s.KeibajyoCode != SUBSTR(t.race_code_uma_kol, 9, 2)
LIMIT 100;
*/
