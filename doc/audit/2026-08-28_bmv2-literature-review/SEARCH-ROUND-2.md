# 系統性檢索第二輪（2026-08-28 深夜）：外部模型回憶掃描＋逐條上網驗證

**方法**：DeepSeek v4 Pro（effort=max）與 Muse Spark 1.2 Contributor 各做一次「訓練記憶回憶掃描」
（原文全文見同目錄 `external-recall-deepseek.md`／`external-recall-muse.md`；兩者皆自標信心與覆蓋邊界），
危險線索由本輪**逐條上網驗證**——模型回憶一律不直接採信。
執行＝Adam 指派（「更大力翻一下有沒有漏掉」）；同時計入 8/28 auditor 的系統性檢索派工。

## 1. 危險線索驗證結果

| # | 線索（來源、自標信心） | 驗證動作 | 裁決 |
|---|---|---|---|
| 1 | **Gallenmüller TUM 博論 2021 含 bmv2 build 對照（-O0 vs -O3、5–10×）**（Muse #13，中偏高） | 找到博論本體（*Data-Driven Analysis and Modeling of Packet Processing Systems*，NET-2021-02-1）、抓 PDF、pdftotext 全文 7,818 行、grep | ❌ **REFUTED＝記憶捏造**：`bmv2`/`behavioral model` 全文 **0 命中**；`P4` 僅 2 次、皆在結語前瞻段（txt 7067–7069）。博論量的是 DPDK/MoonGen 系，無任何 bmv2 內容 |
| 2 | **T4P4S 系列對 bmv2 做過封包大小掃描、圖上 pps 水平**（Muse #16，中） | 搜尋＋抓 ELTE T4P4S 課程投影片（Lecture-6.pdf） | ⚠️ **UNCONFIRMED**：投影片無 bmv2 量測；HPSR'18 原文未取得全文。列**觀察名單**（full paper 前補驗）。即使屬實，形狀＝「圖裡有、結論沒寫」＝ TSSA 同型，是展品不是先行 |
| 3 | **folklore 通道**（README/issues/SO/部落格都知道 build 影響大；兩家皆高信心） | ~~README 原文確認~~ **08-29 更正（poster 外審抓到）：我 08-28 標的「README 原文確認」是拼裝引文＝假確認**——README **無** "massive impact"，該句在 `docs/performance.md`＝"which flags were used to build bmv2: this can have a massive impact."（08-29 對 main 與 `f0b7d201` 逐字重驗）；README 實句＝`--disable-logging-macros` 的效能說明；issues #311/#823 本就已知 | ✅ **CONFIRMED——folklore 論點不變（知識在官方文件、規範不在文獻），但引文出處與字串已更正**：知識存在於專案文件與論壇，**規範不存在於文獻**（17 篇 0 報告）。審稿人「已知 folklore 不算新」的反駁，答案就是這個落差本身 |
| 4 | MoonGen IMC'15 曾量 bmv2 ~40–50 kpps（Muse #2，高） | 未驗（優先級後移） | ⚠️ 觀察名單（2015 年 bmv2 尚極早期，疑年代錯置混淆） |
| 5 | DeepSeek 全清單（47 條，多為泛型標題、自標低信心） | 抽樣搜尋無一命中具體文獻 | 🗄️ 歸檔為噪聲；其高信心項（README/SO）與 #3 重複 |

## 2. 🆕 本輪新增 corpus 候選（第 18 篇）

**P4sim: Programming Protocol-independent Packet Processors in ns-3**（arXiv 2503.17554，2025）——
以 BMv2+Mininet 為 baseline，報 **bmv2 飽和 ~43 Mbps**；**變體、版本、build 全未載明**；無封包大小/流數軸。
⇒ 完全 on-pattern：spread 表新增一列（43 Mbps 落在 0.57–1400 Mbps 區間內），三個宣稱維持存活。
（**08-29 已親驗、轉述標記解除**：PDF 入庫（MANIFEST `P4SIM25`，sha256 `aba393ab…`）、全文 724 行逐字掃——「saturate at around 43 Mbps」原句屬 **Mininet（bmv2）baseline 臂**且為飽和量；build 關鍵詞 **0 命中**、變體/版本未載明；作者 Ma & Nguyen（TU Dresden）。）

## 3. 檢索後宣稱狀態（累計 18 篇）

- ①：**18 篇裡 0 篇給 flags、0 篇做 build 對照**（質性敘述仍僅 ICNCC 一句）。
- ②：18 篇裡仍無 bmv2 封包大小掃描＋pps 結論（T4P4S 圖示疑點在觀察名單）。
- ③：18 篇裡仍無隔離流數＋對照平面的量測。

## 4. 覆蓋邊界（誠實聲明）

兩個模型的知識截止：DeepSeek 自報 ~2024 上半、Muse 自報 2026-01-04 ⇒ **2026 年材料兩者皆盲**（由本輪 WebSearch 部分補足）。
兩者共同盲區：付費庫（CNKI/CiNii 全文）、私有歸檔（P4 Slack）、低流通部落格、2024 後 GitHub 討論。
本輪僅驗證了危險線索；中文/日文學位論文庫**未實查**（兩家都點名此類「可能存在」）——列 full paper 前的待辦。

[Co-developed with claude code -- Adam]
