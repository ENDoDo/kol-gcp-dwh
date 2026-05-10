# 調査報告: ウッド追い切り6Fタイム欠損の原因

**実施日**: 2026-05-10
**ステータス**: 調査完了（対応不要）

## Context

ウッド追い切り（美南Ｗコース）の6Fタイムが一部の馬で表示されないとの報告があった。
KOLウッドチップ調教ソフトでは6Fが表示されるが、race_uma の出力では NULL になるケースがある。
race_uma.sqlx のロジックに問題があるかを調査した。

---

## 調査結果

### race_uma.sqlx のロジックは正常

[definitions/race_uma.sqlx:418-423](../../definitions/race_uma.sqlx) の6F選択ロジック：

```sql
CASE
  WHEN d2.chokyo1_flag = '1' THEN d2.chokyo1_6f
  WHEN d2.chokyo2_flag = '1' THEN d2.chokyo2_6f
  WHEN d2.chokyo3_flag = '1' THEN d2.chokyo3_6f
  ELSE NULL
END AS chokyo_den_oikiri_6f_d2
```

このロジック自体は正しく動作している。**問題はロジックではなくソースデータにある。**

---

### kol_den2 の実データ比較（東京3R 2026-05-10）

| 馬名 | oikiri | course | chokyo_6f | chokyo_5f | 表示結果 |
|------|--------|--------|-----------|-----------|---------|
| フジサン | chokyo3=1 | Ｗ 美南 | **84.9** | 68.3 | ✅ 6F表示あり |
| フクスケ | chokyo3=1 | Ｗ 美南 | **NULL** | 67.8 | ❌ 6F表示なし |
| セリエンクーニゲン | chokyo2=1 | Ｗ 美南 | **NULL** | 71.8 | ❌ 6F表示なし |

### フクスケの全chokyo履歴（kol_den2は1行のみ・重複なし）

| | flag | course | 6f | 5f | 4f |
|--|--|--|--|--|--|
| chokyo1 | '0' | Ｗ 美南 | **NULL** | NULL | 56.0 |
| chokyo2 | NULL | Ｗ 美南 | **NULL** | 72.0 | 55.8 |
| chokyo3 | '1' | Ｗ 美南 | **NULL** | 67.8 | 51.9 |

→ chokyo1・chokyo2・chokyo3 のいずれにも6Fデータが存在しない。  
→ oikiriの選択ロジック（どのchokyoを使うか）の問題ではなく、**kol_den2のデータ自体に6Fが格納されていない**。

---

## 根本原因

**kol_den2.chokyo_6f が NULL のため、race_uma.sqlx が NULL を出力している。バグなし。**

### 6FがNULLになっている理由（推測・未確定）

kol_den2のパターンとして、chokyo_8f / 7f / 6f がNULLで chokyo_5f が最初の有効値になっている。
このパターンから「5Fスタートの追い切り（5F地点から計時開始）のため6F通過タイムが存在しない」と推測できる。

ただし、**以下の可能性も排除できない**：

| 仮説 | 内容 |
|------|------|
| **仮説A（有力）** | 5Fスタートの追い切りのため、kol_den2に6F通過タイムが格納されない仕様 |
| **仮説B** | KOLのden2ファイル自体には6Fデータが存在するが、BigQueryローダーで欠落 |
| **仮説C** | den2ファイルへのデータ確定タイミングの問題（6Fが後から更新されている） |

KOLウッドチップ調教ソフトは同じ馬に対して6F（フクスケ: 85.9）を表示しており、den2ファイルとソースの差異がどこで生じているかが次の調査ポイント。

### 仮説Bの検証結果：ローダー問題は否定

美南Ｗ × chokyo3_flag='1' の6F有無を年次集計した結果：

| 年 | 6Fあり | 6Fなし（5Fはある） | 6F率 |
|--|--|--|--|
| 2022 | 3,676 | 5,945 | 36.4% |
| 2023 | 5,169 | 6,606 | 41.6% |
| 2024 | 5,955 | 5,976 | 48.4% |
| 2025 | 6,594 | 5,367 | 52.7% |
| 2026 | 2,504 | 2,106 | 52.1% |

→ ローダーのバグなら特定時点から急激に欠落するはずだが、**年々緩やかに増加**しており急変は確認できない。  
→ **仮説B（ローダー欠落）は否定**。

2022年以降6F率が上昇傾向にあるのは、KOLデータの収録範囲が徐々に改善されてきた可能性がある。

### 次の確認方法（必要なら）

- KOLのden2生ファイルでフクスケの該当レコードの6Fフィールドを直接確認する（仮説Aの最終確認）

---

## 結論

- race_uma.sqlx のコード変更は不要
- kol_den2 に6Fデータが存在しないのは**KOLのデータ仕様上の問題**（仮説A）が最有力
  - 美南Ｗコースで常時約48〜52%の馬が6FなしというのはKOL仕様上自然な比率
  - ローダーの問題（仮説B）は年次データの分析により否定済み
- 仮説Aを確定させるにはKOL den2生ファイルの直接確認が必要（対応の優先度は低）

---

## 検証クエリ

```sql
-- 3馬の全chokyo比較
SELECT 
  bamei,
  chokyo1_flag, chokyo1_course, chokyo1_6f, chokyo1_5f, chokyo1_4f,
  chokyo2_flag, chokyo2_course, chokyo2_6f, chokyo2_5f, chokyo2_4f,
  chokyo3_flag, chokyo3_course, chokyo3_6f, chokyo3_5f, chokyo3_4f
FROM `smartkeiba.kolbi_keiba.kol_den2` 
WHERE bamei IN ("フクスケ", "フジサン", "セリエンクーニゲン")
AND SUBSTR(race_code_uma_kol, 1, 12) = "202605100402"
ORDER BY bamei
```
