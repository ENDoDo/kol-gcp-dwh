-- 修正後のtrack_code***カラム確認用クエリ
-- 対象: 2026-03-14 (未来のレースデータ)
-- 期待結果: track_code1_dirtsiba_label, track_code2_LRS_label, track_code3_inout_label が正しく表示されること

SELECT
  race_code_kol,
  schedule_id,
  race_name,
  -- track_code1 (芝/ダ)
  track_code1_dirtsiba,
  track_code1_dirtsiba_label,
  -- track_code2 (右/左/直線)
  track_code2_LRS,
  track_code2_LRS_label,
  -- track_code3 (内/外など)
  track_code3_inout,
  track_code3_inout_label
FROM
  `smartkeiba.kolbi_analysis.race`
WHERE
  schedule_id = '20260314'
ORDER BY
  race_code_kol
LIMIT 100;
