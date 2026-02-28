-- shirushi_awase_senchaku_flag の修正確認用クエリ
-- 目的: 「併せ先着」でありながらフラグが「-」(NULL) になっているデータがないか確認する

SELECT
  race_code_uma_kol,
  bamei,
  chokyo_den_awase_kubun,
  shirushi_awase_senchaku_flag,
  shirushi_point,
  -- 以前のバグ条件: 「併せ先着」かつ「ポイント0」だと NULL になっていた
  CASE
    WHEN chokyo_den_awase_kubun = '併せ先着' AND (shirushi_point = 0 OR shirushi_point IS NULL) AND shirushi_awase_senchaku_flag IS NULL THEN 'NG (修正前と同様の不具合あり)'
    WHEN chokyo_den_awase_kubun = '併せ先着' AND shirushi_awase_senchaku_flag = 'はい' THEN 'OK'
    ELSE 'その他'
  END AS validation_status
FROM
  `${ref("race_uma")}` -- Dataform環境で実行する場合
WHERE
  chokyo_den_awase_kubun = '併せ先着'
ORDER BY
  shirushi_point ASC -- ポイント0（タイムが最速でない）のケースを優先的に確認
LIMIT 100;
