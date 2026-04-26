-- 'F'（全角Ｆから半角F）の変換結果のみを抽出して確認するクエリ
-- 期待値: original_labelが '３Ｆ' のとき、converted_labelが '3F' となっていること

SELECT
  keika_midashi2 AS original_label,
  keika_sort_label AS converted_label,
  COUNT(*) AS count
FROM
  `smartkeiba.kolbi_analysis.race_kekka_keika`
WHERE
  keika_midashi2 LIKE '%Ｆ%' OR keika_sort_label LIKE '%F%'
GROUP BY
  1, 2
ORDER BY
  count DESC;
