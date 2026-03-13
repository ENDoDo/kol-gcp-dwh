-- chokyo_den_awase_uma_kakuue_win_flag の修正確認用クエリ
-- 目的: 「格上勝利」が「はい」の場合に、必ず「格上区分」が「格上」になっているか確認する

-- 1. 個別レコードの整合性チェック
SELECT
  race_code_uma_kol,
  bamei,
  chokyo_den_awase_uma_class,
  chokyo_den_awase_uma_kaku_kubun,
  chokyo_den_awase_uma_kakuue_win_flag,
  CASE
    WHEN chokyo_den_awase_uma_kakuue_win_flag = 'はい' AND chokyo_den_awase_uma_kaku_kubun = '格上' THEN 'OK'
    WHEN chokyo_den_awase_uma_kakuue_win_flag = 'はい' AND chokyo_den_awase_uma_kaku_kubun IS NULL THEN 'NG (不整合あり)'
    ELSE 'その他'
  END AS validation_status
FROM
  `smartkeiba.kolbi_analysis.race_uma`
WHERE
  chokyo_den_awase_uma_kakuue_win_flag = 'はい'
ORDER BY
  validation_status DESC
LIMIT 100;

-- 2. 集計による全体状況の確認
-- 期待値: win_flag='はい' かつ kaku_kubun=NULL のレコードが 0 件であること
SELECT
  chokyo_den_awase_uma_kakuue_win_flag,
  chokyo_den_awase_uma_kaku_kubun,
  COUNT(*) as cnt
FROM
  `smartkeiba.kolbi_analysis.race_uma`
WHERE
  chokyo_den_awase_uma_kakuue_win_flag = 'はい'
GROUP BY 1, 2;
