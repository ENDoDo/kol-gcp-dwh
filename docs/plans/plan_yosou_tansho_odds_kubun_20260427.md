# 実装プラン: yosou_tansho_odds_kubun カラム追加

**実施日**: 2026-04-27
**ステータス**: 実施中

## Context

予想オッズ（`yosou_tansho_odds_float`）について、値ベースで区分分けした `yosou_tansho_odds_kubun` カラムを追加する。土日にリアルタイム観戦できないユーザーが前日予想で馬券購入する際、予想オッズを値ベースで参照するニーズに対応。

## 仕様

`yosou_tansho_odds_float` の値をもとに以下の区分ラベルを付与する。

| 下限（以上） | 上限（未満） | ラベル |
|------------|------------|--------|
| 1.0 | 1.5 | '1.0〜1.4' |
| 1.5 | 2.0 | '1.5〜1.9' |
| 2.0 | 3.0 | '2.0〜2.9' |
| 3.0 | 4.0 | '3.0〜3.9' |
| 4.0 | 5.0 | '4.0〜4.9' |
| 5.0 | 7.0 | '5.0〜6.9' |
| 7.0 | 10.0 | '7.0〜9.9' |
| 10.0 | 15.0 | '10.0〜14.9' |
| 15.0 | 20.0 | '15.0〜19.9' |
| 20.0 | 30.0 | '20.0〜29.9' |
| 30.0 | 50.0 | '30.0〜49.9' |
| 50.0 | 上限なし | '50以上' |
| NULL | - | NULL |

## 変更ファイル

### 1. `definitions/race_uma.sqlx`

**① columns config ブロック（L199の直後）**
```js
yosou_tansho_odds_kubun: "yosou_tansho_odds_floatを元に判定 1.0〜1.4/1.5〜1.9/2.0〜2.9/3.0〜3.9/4.0〜4.9/5.0〜6.9/7.0〜9.9/10.0〜14.9/15.0〜19.9/20.0〜29.9/30.0〜49.9/50以上",
```

**② 最終 SELECT（`z.yosou_tansho_odds_float_raw AS yosou_tansho_odds_float,` の直後）**
```sql
CASE
  WHEN z.yosou_tansho_odds_float_raw IS NULL THEN NULL
  WHEN z.yosou_tansho_odds_float_raw < 1.5 THEN '1.0〜1.4'
  WHEN z.yosou_tansho_odds_float_raw < 2.0 THEN '1.5〜1.9'
  WHEN z.yosou_tansho_odds_float_raw < 3.0 THEN '2.0〜2.9'
  WHEN z.yosou_tansho_odds_float_raw < 4.0 THEN '3.0〜3.9'
  WHEN z.yosou_tansho_odds_float_raw < 5.0 THEN '4.0〜4.9'
  WHEN z.yosou_tansho_odds_float_raw < 7.0 THEN '5.0〜6.9'
  WHEN z.yosou_tansho_odds_float_raw < 10.0 THEN '7.0〜9.9'
  WHEN z.yosou_tansho_odds_float_raw < 15.0 THEN '10.0〜14.9'
  WHEN z.yosou_tansho_odds_float_raw < 20.0 THEN '15.0〜19.9'
  WHEN z.yosou_tansho_odds_float_raw < 30.0 THEN '20.0〜29.9'
  WHEN z.yosou_tansho_odds_float_raw < 50.0 THEN '30.0〜49.9'
  ELSE '50以上'
END AS yosou_tansho_odds_kubun,
```

### 2. `includes/race_uma_detail_bubble.js`（L241の直後）

```js
yosou_tansho_odds_kubun: "予想単勝オッズ区分",
```

### 3. `includes/race_uma_detail_looker.js`（L241の直後）

```js
yosou_tansho_odds_kubun: "予想単勝オッズ区分",
```

## 検証結果

→ 実装後に `verification_queries/` に追記予定
