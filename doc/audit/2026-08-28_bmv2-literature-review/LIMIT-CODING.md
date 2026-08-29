# 逐篇編碼：有沒有人「檢查過自己的量測被什麼限制」

**建立日 2026-08-29。** 觸發＝poster 外審 A8：「none of the 18/12 papers states what limited
its measurement」這句在磁碟上沒有 per-paper 證據。本檔補上編碼，宣稱句同步銳化為
「**no measuring paper reports a *check* of what limited its measurement**」。

**判準**（先於編碼寫死）：
- **儀器檢查（check）**＝量測過的儀器效度證據：發送端/產生器餘裕、harness 天花板、
  「我們的設備可到 X、遠高於讀值」之類——**任何一種都算**。
- **事後歸因（attribution）**＝對落差或現象給了原因但**沒有量測那個原因**
  （例：把 1000× 落差歸給 VM 規格）。歸因**不算**檢查。
- 系統的飽和/瓶頸敘述（「throughput saturates at X」＝發現本身）兩者皆不算。

**方法**：`sweep` 正則
`limited by|bottleneck|saturat|is the limit|generator[- ]limited|sender[- ]limited|cpu[- ]bound|constrained by`
掃 18 篇 pdftotext（重生法＝`raw/README.md`），命中行逐行判讀＋先前逐篇閱讀補判。
⚠️ **覆蓋邊界**：關鍵詞初篩對散文同義詞盲（零命中≠沒講——五篇零命中者以先前
全文閱讀補判）；判讀為單人編碼、未雙人覆核。

## 量測 bmv2 的 12 篇

| 篇 | 命中 | 判讀 | 儀器檢查 | 事後歸因 |
|---|---|---|---|---|
| TOMACS'25 | 3 | :322/:934＝bmv2 飽和/瓶頸＝發現本身；:72＝動機句 | ✗ | ✅ ring 掉速歸「容器多工/資源競爭」（未量測；GAP §③） |
| PADS'23 | 1 | :181＝同上飽和敘述 | ✗ | ✅ 同組同歸因 |
| PADS'24 | 0 | —（全文閱讀補判：環境比較，無儀器效度段） | ✗ | ✗ |
| PADS'26 | 9 | :39/:423 等＝CPU saturation 作為被研究現象；:52＝host 規格描述 | ✗ | 🟡 CPU 飽和敘事（現象機制，非量測檢查） |
| ICNCC'23 | 0 | —（有把量測條件寫細，但無儀器極限檢查） | ✗ | ✗ |
| TSSA'23 | 0 | —（詞彙盲區的實例：txt 340–354 把與官方數字 ~1000× 的落差**歸給 VM 規格**，未量測） | ✗ | ✅ VM 規格歸因 |
| Whippersnapper'17 | 0 | — | ✗ | ✗ |
| P4CEP'18 | 1 | :133＝CEP window 語意，無關 | ✗ | ✗ |
| P4-NIDS | 0 | —（且自報三場景 CPU 恆 0.3%＝量測假象嫌疑，census 已記） | ✗ | ✗ |
| PoliTO 碩論 | 4 | 比喻/相關工作/SRAM 限制（研究對象）＋鏈路飽和觀察 | ✗ | ✗ |
| MDPI Network'25 | 9 | :494 "attempted to saturate the links"＝加載敘述；餘＝現象/背景 | ✗ | 🟡 加載努力有敘述、無餘裕量測 |
| P4sim'25 | 2 | :500–501＝baseline 飽和＝發現本身 | ✗ | ✗ |

**統計：儀器檢查 0/12；事後（未量測）歸因 3/12（＋2 邊緣 🟡）。**

## 不量測的 6 篇（僅存查）

CompNet 16 命中／NetSoft 4＝**它們反而有** per-switch 瓶頸分析方法學（受測非 bmv2，
是我們的對照組）；TUM/HotSDN/vSDNEmul/P4Docker＝比喻或背景。

## 宣稱句的最終口徑（稿內用）

> **None of the 12 measuring papers reports a check of what limited its own
> measurement; three attribute discrepancies after the fact, none measures the bound.**

（對照：我們三輪各有註冊的儀器極限檢查——② 發送端 gate 9.6×、①b 停止規則定梯頂、
③ 雙讀值——且兩輪抓到自己儀器差點成為結果。）

[Co-developed with claude code -- Adam]
