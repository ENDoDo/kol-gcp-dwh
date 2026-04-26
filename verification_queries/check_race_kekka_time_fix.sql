-- race_kekka_time の修正結果確認用クエリ
-- 添付画像1枚目に記載されていた不一致レースを中心に抽出します。

SELECT
  race_code_jvd,
  schedule_id AS 日付,
  -- レース名の取得（raceテーブルと結合する場合）
  -- r.race_name,
  lap_time_label AS ラップ,
  time_tsuka_label AS 通過タイム_トレヨミ
FROM
  `smartkeiba.kolbi_analysis.race_kekka_time`
WHERE
  race_code_jvd IN (
    '2026041209020611', -- 桜花賞 (8F) -> 期待値: 34.1-45.7-57.2-68.7
    '2026041209020610', -- 京橋S (10F) -> 期待値: 36.9-49.4-61.4-73.4
    '2026041209020612', -- 梅田S (10F) -> 期待値: 35.5-49.4-62.7-75.4
    '2026041206030611', -- 春雷S (6F)  -> 期待値: 33.7-44.8-55.8-67.6
    '2026040406030304'  -- 障害レース -> 期待値: null
  )
ORDER BY
  race_code_jvd;
