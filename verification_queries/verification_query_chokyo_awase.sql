-- 調教併せ情報の表示条件修正の検証用クエリ
-- 追い切りフラグ（調教2/3）と併せフラグ（2/3）が不一致なケースを検出し、
-- 修正後のテーブルで正しく NULL / 「単走」 になっているかを確認します。

SELECT
  d2.race_code_uma_kol,
  d2.bamei,
  -- ソースデータ（KOL2）のフラグ
  d2.chokyo2_flag,
  d2.chokyo3_flag,
  d2.chokyo_awase_flag,
  d2.chokyo_awase AS raw_chokyo_awase,
  -- 修正後の変換結果（race_uma）
  ru.chokyo_den_awase_flag,
  ru.chokyo_den_awase,
  ru.chokyo_den_awase_kubun,
  -- 判定ロジック
  CASE
    -- 1. フラグが一致している場合
    WHEN (d2.chokyo2_flag = '1' AND d2.chokyo_awase_flag = '2') OR (d2.chokyo3_flag = '1' AND d2.chokyo_awase_flag = '3') THEN
      IF(ru.chokyo_den_awase IS NOT NULL, 'OK (Matched/Shown)', 'NG (Should show data)')

    -- 2. フラグが不一致（片方が追い切りだが併せフラグが別）な場合
    WHEN (d2.chokyo2_flag = '1' AND d2.chokyo_awase_flag = '3' AND d2.chokyo3_flag = '0')
      OR (d2.chokyo3_flag = '1' AND d2.chokyo_awase_flag = '2' AND d2.chokyo2_flag = '0') THEN
      IF(ru.chokyo_den_awase IS NULL AND ru.chokyo_den_awase_kubun = '単走', 'OK (Mismatched -> Solo)', 'NG (Should be Solo)')

    -- 3. そもそもソースに併せ情報がない場合
    WHEN d2.chokyo_awase IS NULL OR d2.chokyo_awase = '' THEN
      IF(ru.chokyo_den_awase IS NULL AND ru.chokyo_den_awase_kubun = '単走', 'OK (No source -> Solo)', 'NG (Should be Solo)')

    ELSE 'Other Pattern (Check manually)'
  END AS validation_result
FROM
  `smartkeiba.kolbi_keiba_stg.kol_den2` AS d2
JOIN
  `smartkeiba.kolbi_analysis_stg.race_uma` AS ru
  ON d2.race_code_uma_kol = ru.race_code_uma_kol
WHERE
  -- 最近のデータに絞る
  ru.hasso_date >= '2024-12-01'
  AND (
    -- 不一致パターン
    (d2.chokyo3_flag = '1' AND d2.chokyo_awase_flag = '2' AND d2.chokyo2_flag = '0')
    OR (d2.chokyo2_flag = '1' AND d2.chokyo_awase_flag = '3' AND d2.chokyo3_flag = '0')
    -- 一致パターン（正常表示の確認用）
    OR (d2.chokyo_awase_flag IN ('2', '3') AND d2.chokyo_awase IS NOT NULL)
  )
ORDER BY
  validation_result DESC, ru.hasso_date DESC
LIMIT 200;
