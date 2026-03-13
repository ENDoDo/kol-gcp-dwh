-- 今回追加した「中1週勝負パターン」フラグの確認用クエリです。

-- 1. 条件に合致してフラグが「はい」になっているレコードの確認
SELECT
  schedule_id,
  race_bango_num,
  bamei,
  zensou_kankaku,
  yosou_tansho_ninkijun_num,
  bataiju_zensou,
  barei_num,

  -- 成績用の調教データ確認
  chokyo_sei_basho_course_label,
  chokyo_sei_4f_float,
  chokyo_sei_naka1week_fight_flag,

  -- 出馬表用の調教データ確認
  chokyo_den_oikiri_basho_course_label,
  chokyo_den_oikiri_4f_float,
  chokyo_den_oikiri_naka1week_fight_flag
FROM
  `smartkeiba.kolbi_analysis.race_uma`
WHERE
  chokyo_sei_naka1week_fight_flag = 'はい'
  OR chokyo_den_oikiri_naka1week_fight_flag = 'はい'
ORDER BY
  schedule_id DESC, race_bango_num
LIMIT 100;

-- 2. 条件を1つだけ満たしていない（フラグが立たない）レコードの確認
-- サンプルとして、中1週、前走460kg以上、馬齢2～4歳、好時計（ウッド50.9以下 または 坂路52.9以下）だが、
-- KOLオッズの順位が「3位以下」のために弾かれているレコードを確認します。
SELECT
  schedule_id,
  race_bango_num,
  bamei,
  zensou_kankaku,
  yosou_tansho_ninkijun_num,
  bataiju_zensou,
  barei_num,
  chokyo_sei_basho_course_label,
  chokyo_sei_4f_float,
  chokyo_sei_naka1week_fight_flag
FROM
  `smartkeiba.kolbi_analysis.race_uma`
WHERE
  zensou_kankaku = '中1週'
  AND bataiju_zensou >= 460
  AND barei_num IN (2, 3, 4)
  AND (
    (chokyo_sei_course_kubun = 'コース' AND chokyo_sei_4f_float <= 50.9)
    OR (chokyo_sei_course_kubun = '坂路' AND chokyo_sei_4f_float <= 52.9)
  )
  -- 意図的に3位以下を抽出してフラグがnullであることを確認
  AND yosou_tansho_ninkijun_num >= 3
ORDER BY
  schedule_id DESC, race_bango_num
LIMIT 100;
