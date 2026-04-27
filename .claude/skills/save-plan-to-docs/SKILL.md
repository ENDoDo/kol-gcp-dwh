---
name: save-plan-to-docs
description: Use when creating or completing an implementation plan in the kol-gcp-dwh project. Plans must be saved to docs/plans/ for future reference.
---

# プラン保存ルール

実装プランは必ず `docs/plans/` に保存する。

## ファイル名規則

```
docs/plans/plan_<feature_name>_YYYYMMDD.md
```

例: `docs/plans/plan_zensou_kankaku_num_20260427.md`

## プランファイルの構成

```markdown
# 実装プラン: <タイトル>

**実施日**: YYYY-MM-DD
**ステータス**: 完了 / 実施中

## Context
なぜこの変更をするか（背景・ニーズ）

## 仕様
変更内容の仕様（テーブル、ロジック等）

## 変更ファイル
各ファイルへの変更内容（コードスニペット含む）

## 検証結果
→ verification_queries/ の対応ファイルへのリンク、または結果サマリー
```

## タイミング

- 実装**完了後**に `docs/plans/` へ保存（実装前の一時プランは `~/.claude/plans/` に置いてよい）
- 検証結果が出た場合はプランファイルに追記する
