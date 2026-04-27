# 実装プラン: race テーブルへ kyoso_hiraba_tokubetsu_kubun カラム追加

**実施日**: 2026-04-27
**ステータス**: 完了

## Context

`kyoso_joken_kubun_label` で新馬/未勝利/1勝クラス…とクラス分けしているが、同クラス内でも**平場と特別**では傾向が大きく異なるため、分析用に判別カラムが必要になった。

KOLデータに直接的なフラグはないが、`kyosomei_15moji`（競走名15文字）の有無で判別できる：
- `kyosomei_15moji IS NOT NULL` → 特別競走
- `kyosomei_15moji IS NULL` → 平場

## 仕様

| カラム名 | 型 | 値 | ロジック |
|----------|----|----|----------|
| `kyoso_hiraba_tokubetsu_kubun` | STRING | `特別` / `平場` | `IF(kyosomei_15moji IS NOT NULL, '特別', '平場')` |

## 変更ファイル

### `definitions/race.sqlx`

**columns ブロック**（`kyoso_joken_kubun_label` の直後）:
```js
kyoso_hiraba_tokubetsu_kubun: "kyosomei_15mojiに値がある場合は特別、そうでない場合は平場",
```

**SELECT句**（`kyoso_joken_kubun_label` の直後）:
```sql
IF(kyosomei_15moji IS NOT NULL, '特別', '平場') AS kyoso_hiraba_tokubetsu_kubun,
```

## 検証

```sql
SELECT
  race_code_kol,
  kyosomei_15moji,
  kyoso_hiraba_tokubetsu_kubun,
  kyoso_joken_kubun_label
FROM `smartkeiba.kolbi_analysis_stg.race`
LIMIT 100
```

→ `kyosomei_15moji IS NOT NULL` の行が `特別`、NULL の行が `平場` であることを確認
