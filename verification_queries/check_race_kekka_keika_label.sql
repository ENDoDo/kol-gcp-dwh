-- race_kekka_keikaテーブルのラベル変換（数値の半角化）を確認するクエリ
-- 期待値: keika_midashi2 が '１角' のとき、keika_sort_label が '1角' になっていること
-- 期待値: keika_midashi2 が '３Ｆ' のとき、keika_sort_label が '3Ｆ' になっていること（Fは全角のまま）

SELECT
  keika_midashi2,
  keika_sort_label,
  COUNT(*) AS record_count
FROM
  `smartkeiba.kolbi_analysis.race_kekka_keika`
GROUP BY
  keika_midashi2,
  keika_sort_label
ORDER BY
  keika_midashi2;

/* 
-- 個別のサンプルを確認する場合
SELECT
  race_code_kol,
  keika_sort_num,
  keika_midashi2,
  keika_sort_label
FROM
  `smartkeiba.kolbi_analysis.race_kekka_keika`
WHERE
  keika_midashi2 != keika_sort_label
LIMIT 50;
*/
