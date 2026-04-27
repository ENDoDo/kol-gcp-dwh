# 実装プラン: zensou_kankaku_num（前走間隔整数型）追加

**実施日**: 2026-04-27  
**ステータス**: 完了

---

## Context

ユーザーからの要望で、前走間隔（`zensou_kankaku`）の「中15週以上」をさらに細分化したいというニーズがあった。ラベル分類はニーズがバラバラになるため、整数型カラム `zensou_kankaku_num` を追加し、ユーザー側で自由にグルーピングできるようにした。

データベース仕様には反映済みの状態で実装依頼を受けた。

---

## 仕様

| zensou_kankaku（既存ラベル） | zensou_kankaku_num（新規整数） |
|---|---|
| 初出走 | 0 |
| 連闘 | 1 |
| 中1週 | 2 |
| 中N週 | N+1 |
| 中15週以上 | 16〜（実績値: 最大173） |

---

## 変更ファイル

### `definitions/race_uma.sqlx`
1. `columns` オブジェクトに定義追加（ファイル上部）
2. `with_zensou_kankaku` CTE 内で `COALESCE(DATE_DIFF(...), 0)` を使って計算
3. 最終 SELECT に `z.zensou_kankaku_num` を追加

```sql
-- 前走間隔（整数）: 初出走=0、連闘=1、中1週=2、中N週=N+1
COALESCE(
  DATE_DIFF(DATE_TRUNC(DATE(hasso_date), WEEK(MONDAY)), LAG(DATE_TRUNC(DATE(hasso_date), WEEK(MONDAY))) OVER (PARTITION BY ketto_toroku_bango ORDER BY hasso_date), WEEK),
  0
) AS zensou_kankaku_num
```

### `includes/race_uma_detail_bubble.js`
- `columns` オブジェクトに `zensou_kankaku_num` の説明を追加（SQL修正不要: `SELECT ru.*` で自動伝播）

### `includes/race_uma_detail_looker.js`
- 同上

### `functions/export_race_uma_detail_bubble/main.py`
- 修正不要（動的スキーマ取得のため自動対応）

### `.claude/skills/race-uma-column-addition/SKILL.md`
- カラム追加時のチェックリストをプロジェクトスキルとして登録

---

## 検証結果

→ [verification_queries/result_zensou_kankaku_num_20260427.md](../verification_queries/result_zensou_kankaku_num_20260427.md) 参照

**判定: ✅ 正常**  
ラベルと整数の対応はすべて期待値どおり。`zensou_kankaku = NULL / num = 0` の225件は既存データ品質の問題で今回の追加とは無関係。
