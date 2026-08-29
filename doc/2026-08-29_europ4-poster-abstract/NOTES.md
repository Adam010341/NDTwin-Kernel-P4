# EuroP4'26 poster abstract——投稿前必讀（草稿狀態，未投）

**建立日 2026-08-29。** 依 Adam 08-29 裁示重開 poster（08-28「放棄」裁示作廢）。
正文數字全部出自 `doc/2026-08-29_bmv2-performance-study.md` 與三個收案 audit 目錄；
**改任何宣稱句之前先讀下方紅線。**

## 投稿前的三道關（缺一不投）

1. **教授**：同意＋署名（外審條件 C1）。`abstract.tex` 的第二作者欄與 Chi-Yen 的
   affiliation 措辭都是 TODO——**等教授確認，不要替他決定**。
2. **入口**：官方頁沒有 poster 投稿連結；已去信兩位 TPC chair
   （h.mostafaei@tue.nl、vaddank@purdue.edu，08-28 自 Purdue 信箱）。**回信給入口才投。**
   ⚠️ 「2 頁 ACM 格式」是從 EuroP4'23 歷屆推的慣例，**格式與頁限以 chairs 回覆為準**。
3. **到場**：12/7 Utrecht（CoNEXT 共站）。歷屆 poster 進 ACM proceedings 帶 DOI，
   **no-show 會被抽掉**——確認能到（或問 chairs 遠端選項）再投。

另：投前確認 dual-submission——2 頁帶 DOI 的 abstract 通常不擋後續 full paper，
但**以目標 full-paper venue（EuroP4'27／CCR）的政策為準**，別靠通常。

## 編譯

本機無 TeX 工具鏈（無 pdflatex、無 acmart）——丟 **Overleaf**（acmart 自帶）。
`\documentclass[sigconf,nonacm]{acmart}`；camera-ready 時移除 `nonacm`。
**超過 2 頁時的裁切順序**：§4 checklist 內文 → §1 的 lineage 細節（1.7× 句）→
§3 第二段（保留統一威脅段）。**§2 的數字與但書不裁。**

## 措辭紅線（從研究報告原樣繼承，教授改稿時也要守住）

- 「mutually incomparable」不是「irreproducible」——我們沒做過重現實驗。
- 否定句主詞＝「the 18 surveyed papers」，不是「the literature」。
- **① 三禁**：不准只報 12×；不准報 8.0× 不講單跳；不准把差額歸因給路徑或控制平面。
- ③ 不用「collapse」、不用比值；口徑＝每流最高乾淨速率單調下降。
- OvS 那半句維持「earlier measurement; same-ladder control planned」的誠實狀態。
- build 差異一律「複合 build 組態」，不是單一 flag。

## refs.bib 待辦

- `fernando2025network`：題名與作者名 TODO（`network-05-00021.pdf` 首頁 pdftotext
  抽不出文字，要開 PDF 目視）。
- `kohler2018p4cep`：作者清單 TODO（同上）。
- 其餘題名已逐篇對 PDF 首頁驗過（08-29）。

## 標題備選

- 現行：*Mind the Build: Why Published BMv2 Throughput Figures Cannot Be Compared*
- 備一：*An Unreported 8× Variable: A Measurement Study of BMv2 Performance Reporting*
- 備二：*Same Switch, 2,500× Apart: Build, Unit, and Flow Effects in BMv2 Benchmarks*

## 若空間允許的加值項

單張小圖：③ 的每流乾淨速率曲線（兩臂）——資料在
`doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md` §1，圖可日後補，非必要。

[Co-developed with claude code -- Adam]
