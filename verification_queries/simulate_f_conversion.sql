-- 変換ロジックのシミュレーション確認用クエリ
-- 実際のテーブルに '３Ｆ' のデータがなくても、ロジックが正しいことを証明できます

WITH mock_data AS (
  SELECT '１角' AS val UNION ALL
  SELECT '２角' AS val UNION ALL
  SELECT '３Ｆ' AS val UNION ALL
  SELECT '向正面' AS val UNION ALL
  SELECT 'スタンド前' AS val
)
SELECT
  val AS input_value,
  -- race_kekka_keika.sqlx に実装したのと同じロジック
  TRANSLATE(val, '０１２３４５６７８９Ｆ', '0123456789F') AS output_value
FROM
  mock_data;
