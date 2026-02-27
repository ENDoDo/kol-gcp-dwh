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
  ru.chokyo_den_awase_kubun
FROM
  `smartkeiba.kolbi_keiba_stg.kol_den2` AS d2
JOIN
  `smartkeiba.kolbi_analysis_stg.race_uma` AS ru
  ON d2.race_code_uma_kol = ru.race_code_uma_kol
WHERE
  (
    -- パターン1: 調教3が追い切りだが、併せフラグが2（調教2の併せ）
    (d2.chokyo3_flag = '1' AND d2.chokyo_awase_flag = '2' AND d2.chokyo2_flag = '0')
    OR
    -- パターン2: 調教2が追い切りだが、併せフラグが3（調教3の併せ）
    (d2.chokyo2_flag = '1' AND d2.chokyo_awase_flag = '3' AND d2.chokyo3_flag = '0')
  )
  -- 直近のデータに絞る
  AND ru.hasso_date >= '2025-01-01'
ORDER BY
  ru.hasso_date DESC
LIMIT 100;
