-- zensou_kankaku_num（前走間隔整数型）の追加を確認するクエリ
-- 期待値: zensou_kankaku（ラベル）と zensou_kankaku_num（整数）が一致していること
--   初出走=0, 連闘=1, 中1週=2, 中2週=3, ..., 中N週=N+1

-- 1. ラベルと整数の対応分布を確認（不一致があればここに現れる）
SELECT
  zensou_kankaku,
  zensou_kankaku_num,
  COUNT(*) AS record_count
FROM
  `smartkeiba.kolbi_analysis.race_uma`
GROUP BY
  zensou_kankaku,
  zensou_kankaku_num
ORDER BY
  zensou_kankaku_num;

/*
-- 2. 不整合レコードの確認（期待値と異なる組み合わせを抽出）
SELECT
  race_code_uma_kol,
  zensou_kankaku,
  zensou_kankaku_num
FROM
  `smartkeiba.kolbi_analysis.race_uma`
WHERE
  NOT (
    (zensou_kankaku = '初出走'   AND zensou_kankaku_num = 0)  OR
    (zensou_kankaku = '連闘'     AND zensou_kankaku_num = 1)  OR
    (zensou_kankaku = '中1週'    AND zensou_kankaku_num = 2)  OR
    (zensou_kankaku = '中2週'    AND zensou_kankaku_num = 3)  OR
    (zensou_kankaku = '中3週'    AND zensou_kankaku_num = 4)  OR
    (zensou_kankaku = '中4週'    AND zensou_kankaku_num = 5)  OR
    (zensou_kankaku = '中5週'    AND zensou_kankaku_num = 6)  OR
    (zensou_kankaku = '中6週'    AND zensou_kankaku_num = 7)  OR
    (zensou_kankaku = '中7週'    AND zensou_kankaku_num = 8)  OR
    (zensou_kankaku = '中8週'    AND zensou_kankaku_num = 9)  OR
    (zensou_kankaku = '中9週'    AND zensou_kankaku_num = 10) OR
    (zensou_kankaku = '中10週'   AND zensou_kankaku_num = 11) OR
    (zensou_kankaku = '中11週'   AND zensou_kankaku_num = 12) OR
    (zensou_kankaku = '中12週'   AND zensou_kankaku_num = 13) OR
    (zensou_kankaku = '中13週'   AND zensou_kankaku_num = 14) OR
    (zensou_kankaku = '中14週'   AND zensou_kankaku_num = 15) OR
    (zensou_kankaku = '中15週以上' AND zensou_kankaku_num >= 16)
  )
LIMIT 50;
*/
