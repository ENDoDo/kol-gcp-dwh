-- レースごとの経過ラベルの流れ（3Fの半角化など）を確認するクエリ
-- 期待値: 経過ラベルのリストの中に '3F' などの半角化された値が含まれていること

SELECT
  race_code_kol,
  -- 修正後のラベル（半角化済み）を順番に並べる
  ARRAY_TO_STRING(ARRAY_AGG(keika_sort_label ORDER BY keika_sort_num), ' -> ') AS flow_labels,
  -- 修正前の見出し（比較用）を順番に並べる
  ARRAY_TO_STRING(ARRAY_AGG(keika_midashi2 ORDER BY keika_sort_num), ' -> ') AS flow_midashi2
FROM
  `smartkeiba.kolbi_analysis.race_kekka_keika`
GROUP BY
  race_code_kol
-- '3F' または '3Ｆ' を含むレースを優先的に表示
HAVING
  flow_labels LIKE '%3F%' OR flow_midashi2 LIKE '%３Ｆ%'
LIMIT 20;
