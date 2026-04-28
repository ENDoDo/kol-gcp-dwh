# 実装プラン: kishu_norikawari_kubun_label null統一修正

**実施日**: 2026-04-29
**ステータス**: 実施中

## Context

`kishu_norikawari_kubun_label` は騎手乗り替わりフラグで、現在は非該当時に `'いいえ'` を返していた。
`chokyo_sei_batsugun_flag` や `tenkai_ittai_flag` などの同種フラグは非該当時に `NULL` を返すルールに統一されており、この不統一を解消する。

## 仕様

| 項目 | 変更前 | 変更後 |
|------|--------|--------|
| 該当時の値 | `'はい'` | `'はい'` |
| 非該当時の値 | `'いいえ'` | `NULL` |
| columns説明文 | `"騎手乗り替わり はい/いいえ"` | `"騎手乗り替わり 該当する場合「はい」該当しない場合はnull"` |

## 変更ファイル

### `definitions/race_uma.sqlx`

**SQL実装（line 1332-1335）**
```sql
-- 変更前
CASE
  WHEN z.kishu_norikawari_kubun = '1' THEN 'はい'
  ELSE 'いいえ'
END AS kishu_norikawari_kubun_label,

-- 変更後
CASE
  WHEN z.kishu_norikawari_kubun = '1' THEN 'はい'
  ELSE NULL
END AS kishu_norikawari_kubun_label,
```

**columns定義（line 65）**
```javascript
// 変更前
kishu_norikawari_kubun_label: "騎手乗り替わり はい/いいえ",

// 変更後
kishu_norikawari_kubun_label: "騎手乗り替わり 該当する場合「はい」該当しない場合はnull",
```

### `includes/race_uma_detail_bubble.js`（line 55）

```javascript
// 変更前
kishu_norikawari_kubun_label: "騎手乗り替わり はい/いいえ",

// 変更後
kishu_norikawari_kubun_label: "騎手乗り替わり 該当する場合「はい」該当しない場合はnull",
```

### `includes/race_uma_detail_looker.js`（line 55）

```javascript
// 変更前
kishu_norikawari_kubun_label: "騎手乗り替わり はい/いいえ",

// 変更後
kishu_norikawari_kubun_label: "騎手乗り替わり 該当する場合「はい」該当しない場合はnull",
```

## 検証

### Dataform コンパイル
✅ `npx @dataform/cli compile` — 10 action(s) エラーなし

### STG 検証クエリ
```sql
SELECT
  kishu_norikawari_kubun_label,
  COUNT(*) AS cnt
FROM `smartkeiba.kolbi_analysis_stg.race_uma`
WHERE schedule_id >= '20250101'
GROUP BY kishu_norikawari_kubun_label
ORDER BY kishu_norikawari_kubun_label NULLS LAST
```
期待: `'はい'` と `NULL` の2グループのみ（`'いいえ'` が消えること）

### PRD 検証クエリ
同クエリを `kolbi_analysis` で実行し、STG と同様の分布を確認。
