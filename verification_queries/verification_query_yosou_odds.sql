-- =================================================================
-- 予想オッズと人気順位の検証クエリ (Google Cloud コンソール実行用)
-- =================================================================
-- 説明:
-- race_umaテーブルの yosou_tansho_odds_float および yosou_tansho_ninkijun_num が、
-- ソーステーブル kol_yosou_odds のデータから正しく変換・計算されているかを確認します。

WITH sample_race AS (
  -- 検証対象のレースIDを指定
  SELECT '2023122805050904' AS race_code_kol -- ここを検証したいレースIDに書き換えてください
)
SELECT
  ru.race_code_kol,
  ru.umaban,
  ru.bamei,
  -- ソーステーブルの生データ（比較用）
  -- 注意: ここでは便宜上 馬番1〜5のカラムのみをSELECTしていますが、検証対象の馬番に応じて適宜参照してください
  yo.yosou_odds_tansho_1,
  yo.yosou_odds_tansho_2,
  yo.yosou_odds_tansho_3,
  yo.yosou_odds_tansho_4,
  yo.yosou_odds_tansho_5,
  -- 算出された値
  ru.yosou_tansho_odds_float AS calculated_odds,
  ru.yosou_tansho_ninkijun_num AS calculated_rank,
  -- 検証用（SQLで再度計算）
  RANK() OVER (PARTITION BY ru.race_code_kol ORDER BY ru.yosou_tansho_odds_float ASC) AS validation_rank
FROM
  `smartkeiba.kolbi_analysis.race_uma` AS ru
LEFT JOIN
  `smartkeiba.kolbi_keiba.kol_yosou_odds` AS yo ON ru.race_code_kol = yo.race_code_kol
WHERE
  ru.race_code_kol IN (SELECT race_code_kol FROM sample_race)
ORDER BY
  ru.umaban_num ASC;
