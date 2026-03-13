-- 修正ロジック（CASE文）が正しく動作するかを、擬似データを使って確認するクエリ
-- 実際のテーブルを更新する前に、SQLの論理だけをテストします。

WITH mock_data AS (
  -- テスト用：不一致パターンのデータを擬似的に作成
  SELECT '馬A' as bamei, '0' as chokyo2_flag, '1' as chokyo3_flag, '2' as chokyo_awase_flag, '相手馬Xに0.1秒先着' as chokyo_awase
  UNION ALL
  SELECT '馬B' as bamei, '1' as chokyo2_flag, '1' as chokyo3_flag, '2' as chokyo_awase_flag, '相手馬Yと同入' as chokyo_awase
  UNION ALL
  SELECT '馬C' as bamei, '1' as chokyo2_flag, '0' as chokyo3_flag, '3' as chokyo_awase_flag, '相手馬Zに遅れ' as chokyo_awase
),
logic_test AS (
  SELECT
    bamei,
    chokyo2_flag,
    chokyo3_flag,
    chokyo_awase_flag,
    chokyo_awase as raw_awase,
    -- ここに race_uma.sqlx に実装した修正ロジックを適用
    CASE
      WHEN chokyo2_flag = '1' AND chokyo_awase_flag = '2' THEN chokyo_awase
      WHEN chokyo3_flag = '1' AND chokyo_awase_flag = '3' THEN chokyo_awase
      ELSE NULL
    END AS fixed_chokyo_den_oikiri_awase
  FROM
    mock_data
)
SELECT
  *,
  -- 最終的な区分判定（race_uma.sqlx の末尾付近のロジック）
  CASE
    WHEN fixed_chokyo_den_oikiri_awase IS NULL THEN '単走'
    WHEN fixed_chokyo_den_oikiri_awase LIKE '%同入%' THEN '併せ同入'
    WHEN fixed_chokyo_den_oikiri_awase LIKE '%外併走%' THEN '併せ同入'
    WHEN fixed_chokyo_den_oikiri_awase LIKE '%内併走%' THEN '併せ同入'
    WHEN fixed_chokyo_den_oikiri_awase LIKE '%遅れ%' THEN '併せ遅れ'
    WHEN fixed_chokyo_den_oikiri_awase LIKE '%先着%' THEN '併せ先着'
    ELSE '単走'
  END AS fixed_chokyo_den_awase_kubun
FROM
  logic_test;
