---
name: telemetry-cost-is-fixed-not-per-sample
description: 🔴 遙測成本 46/57 點在最低取樣率就付掉、且集中在單一執行緒；「206 µs/樣本」只是尾巴——✅ 08-25 工單 A 已指認執行緒＝`calFlowPathByQueried`（46.31%，取樣 ×32 只動 ×1.01）；`run` 才是 ingest（×3.48）
metadata: 
  node_type: memory
  type: project
  originSessionId: eafec5bf-e5ef-4c82-8845-f24921cbe297
  modified: 2026-08-31T07:18:21.683Z
---

（2026-08-25，Adam 看圖起疑 → 審查用**既有 raw** 分析，零實驗室時間）

## 已量到的（三點三角）
| 條件 | kernel 全部執行緒 | 最忙那條 |
|---|---|---|
| 取樣**開**、**無流量**（idle 1/256） | 2.3% | 1.1% |
| 取樣**關**、200 Mbit/s（`mzero_poll`） | 10.6% | 7.6% |
| 取樣 **1/1024**（34.7 樣本/s）、200 Mbit/s | **55.4%** | **45.0%** |
| 取樣 **1/64**（556 樣本/s，16×） | 67.9% | **46.6%** |

🔑 **兩個獨立結論**：
1. **成本不是取樣率的函數**——樣本多 16 倍，那條熱執行緒只從 45.0 → 46.6（+1.5 點）。
   57 點裡有 46 點在最低取樣率就付清（＝擬合截距 48.5% vs 冷啟零點 2.89% 的真身）。
2. **只有「取樣開 ∧ 有流量」才貴**：單獨開取樣（idle）2.3%、單獨有流量（mzero）10.6%
   ⇒ 貴的是**流記錄存在之後**的處理，不是 clone session 裝著或封包本身。
⇒ **「206 µs/樣本」是尾巴不是主體**；由它外推的容量天花板早已撤回（[[ab-control-deleted-nothing]]）。

## 候選機制（讀碼，**未證實**）
`FlowLinkUsageCollector::calFlowPathByQueried()`（`src/ndt_core/collection/`，迴圈尾
`sleep_for(microseconds(1000))`）——**每毫秒重算每一條被追蹤流的路徑**，程式自己的註解就這樣寫
（那段註解還記載它曾寫出 270,991 行重複 warning／41 MB log）。表空＝幾乎免費，一有流就
1000 次/秒的實工作 ⇒ 形狀完全吻合。**血緣：baseline `28b8b13` 就有這個函式與 1000µs 睡眠**
（`git show 28b8b13:…FlowLinkUsageCollector.cpp` 內 `microseconds(1000)` 唯一命中在該函式）
⇒ **繼承缺陷、不是我們造成的**。

## 逐執行緒行為指紋（08-25 追加，比 tid 算術有力）
拿 1/1024 對 1/64（樣本 ×16）逐執行緒比對，**角色由「會不會隨樣本放大」直接分開**：
- **+9 偏移那條 0.21 → 2.16（10×）** ＝ ingest；**worker pool 十餘條各 0.03 → 0.47** ＝ 也隨樣本走。
  ⇒ **真正處理樣本的工作在 556 樣本/秒時合計仍 < 9 點。**
- **那條大的 45.09 → 46.48（1.03×）＝完全不隨樣本走**，卻獨自佔 46 點。
- 另有一條約 7.5 點的角色在兩次 run 換了 tid（+26 ↔ +29），與樣本無關。
⇒ **「成本不是取樣造成的」已由行為指紋確立，不再依賴任何名字。**
**消去法補強**：kernel 內唯一**毫秒級**週期迴圈就是 `calFlowPathByQueried`（1 ms）；
其餘 `sleep_for` 皆 200 ms–1 s ⇒ 能燒 46 點又不隨樣本走的候選只剩它。（**這是消去法、
不是觀察**——同族錯誤參見 [[arithmetic-that-fits-is-not-the-mechanism]]。）

## 改進空間（08-25 追加）
`flowPath` 的**直接讀者只有一個**：`getFlowInfoJson()`（`FlowLinkUsageCollector.cpp:2194`），
序列化進 `/ndt/get_detected_flow_data` 的回應 ⇒ **每秒算 1000 次的東西、以約 1 Hz 被讀**。
⚠️ 設計修法前要查的兩件事：(1) `getFlowInfoTable()`（`:2158`）把整張表交出去，
**間接讀者未清點**；(2) **不要改成請求時才算**——北向 API 是序列化的
（[[northbound-api-serialises]]），把 walk 搬進請求路徑會擋住所有其他請求。
較安全的方向＝維持背景執行緒但把週期拉到 ~1 s，或改成拓撲/路由變更時失效重算
（**動它之前先寫下那 1 ms 在保護什麼**＝[[speedups-pass-the-wrong-test]]）。

✅ **08-25 夜已指認（sFlow experiment 工單 A，讀同輪 kernel.log 不用偏移法）**：`calFlowPathByQueried` **46.31% → 46.84%（取樣 ×32 只動 1.01×）**＝那條大的就是它，**機制確認**；`run` **3.98% → 13.86%（×3.48）**＝ingest，與我的行為指紋三形狀吻合；`testCalAvgFlowSendingRatesRandomly`／`purgeIdleFlows` **從不執行**。46.31 落在我發表的 45.0/46.6 之間＝單位換算獨立佐證。

（以下為當時未指認的紀錄）🔴 **原本失敗的方法**：用 tid−pid 偏移比對失敗（trace 是 **+13**、08-25 build 的 log 是
**+11**，執行緒建立順序跨版本會變）。**這個對不上反而救了我**——差一點就用「算得通」當機制
（[[arithmetic-that-fits-is-not-the-mechanism]]）。**確認法很便宜**：任何一次 live 跑同時保留
`kernel.log`（開機就印 `[calFlowPathByQueried] pid=… tid=…`）＋ `cpu_probe` 的 thread 欄位，
一次比對即定案。

**Why:** 這改寫「取樣要多密」的整個結論——**邊際成本極低、固定成本極高**，所以「能不能取樣更密」
的答案是「可以，而且幾乎免費」，貴的是「有沒有開遙測」。也是 9/03 報告更好講的一句話。
**How to apply:** 交由實驗 session 補一次帶 log 的 live 跑指認執行緒；若確認，修法方向＝
把 1 kHz 迴圈改成事件驅動或拉長週期（**動它前先寫下它在保護什麼**＝[[speedups-pass-the-wrong-test]]）。
相關：[[large-scale-concurrent-never-measured]]（多流會放大這條迴圈的成本，該輪會順帶檢驗）。

## 取樣率上限實測（08-25 夜，工單 B，單流 200 Mbit/s、300 s/格）
| cell | ratio | gt Mb/s | lost% | λ單邊 | spread | floor |
|---|---|---|---|---|---|---|
| 1/32 | 1.000 | 206.0 | 0.03 | 558 | 4.73 | 4.23 |
| 1/16 | 0.997 | 206.0 | 0.03 | 1112 | 5.22 | 3.00 |
| 1/8 | 1.000 | 196.0 | **5.09** | 2123 | 7.91 | 2.17 |
| 1/4 | 1.005 | 109.8 | **45.3** | 2394 | 22.91 | 2.04 |
| 1/1 | 0.998 | 29.52 | **85.2** | 2554 | 30.65 | 1.98 |
🔑 **1/16 之後往上取樣買不到精度**（spread 單調上升而地板下降）；**牆是資料面的**
（零 SATURATED、七格 ratio 全 ≈1.00）；**λ 平台單邊 ≈2550／全邊 ≈5100**，
且平台完全由吞吐崩塌解釋（審查複算三格差 0.36–0.64%）。quantum 七格反推 frame 皆 1442 B。
🔴 **不得寫成「撤回的 ~4,900 其實是對的」**（同數字不同機制：那個預測 CPU 天花板、
實測是吞吐崩塌）；**不得寫成「bmv2 撐不住」**（機制未指認）。

## ✅ 08-25 夜：工單 A 收掉「未指認執行緒」那一格（機制確認）

每格保留自己的 `kernel.log` 在 cpu trace 旁邊，**讀出**而非用偏移推。今日 build 對照表：

| tag | pid 偏移 | 1/32 | 1/1 | 取樣 ×32 的放大 |
|---|---|---|---|---|
| **`calFlowPathByQueried`** | +11 | **46.31%** | **46.84%** | **×1.01（完全不放大）** |
| `run` | +7 | 3.98% | 13.86% | **×3.48 ＝ ingest** |
| `calAvgFlowSendingRatesPeriodically` | +8 | 0.06% | 0.11% | ×2.00 |
| `testCalAvgFlowSendingRatesRandomly` | +9 | 0.00% | 0.00% | **從不執行** |
| `purgeIdleFlows` | +10 | 0.00% | 0.00% | **從不執行** |

**46.31% 落在本檔上表的 45.0/46.6 之間 ⇒ 單位換算獨立獲證。** PREREG 判準是 ≥40 ⇒ 機制確認。
驗證方式：`doc/audit/2026-08-25_sampling-rounds/ticket_a.py`（commit `8c0516d`），
資料在 `doc/audit/2026-08-20_sampling-rate-and-cpu/raw/r0NN_poll_{kernel.log,cpu.jsonl.gz}`。

🔴 **偏移法是死路，不要再用**：08-20 那輪**沒有歸檔 kernel.log**，而偏移跨 build 不穩
（該 trace +13、今日 +11）⇒ 舊 trace 的執行緒身分**永遠對不回名字**。只能靠新一輪同時留兩份。

🔴 **`ticket_a.py` 第一版是錯的**：對 `thread` 欄取平均，但 `cpu_probe.py:190` 存的是
**累計** utime+stime。平均一個 0→1193 的計數器得到的數字**隨 trace 長度增長、不是速率**，
它印出「7002 points」——**一個沒有單位、但看起來夠合理可以發表的量**。
正解＝`(末-初)/elapsed/clk_tck×100`。抓到它的方法是**拿它去對已發表的 45.0/46.6**。

## 🔴 08-31：**本條與「天花板 ≈1/16」都是改動前那顆 binary 的性質，改動後從沒重量過**

Adam 問「merge 與 1 kHz→1 Hz 之後天花板有沒有抬高」＝**沒量**。查證：
`a3bb761`（sflow batching）08-27 **16:31**、`2f57ba5`（path recompute 1 kHz→1 Hz）08-27 **22:22**
落地；

🔴 **同日稍晚更正——「兩顆改動」其實只有一顆在生產線上跑**：`a3bb761` 的 batching
**碼進了版控，但旗標 `NDTWIN_SFLOW_BATCH` 從來沒有被設過**（`main.py:82` 預設 1 ＝關閉、
全 repo 零設定點，而 `KNOWN-ISSUES.md:1018` 早就白紙黑字寫著）。⇒ **batching 這一軸，
生產行為從 08-27 到現在完全沒變**，本檔對它的描述仍然有效；真正變了的只有
`2f57ba5`（1 kHz→1 Hz），而那顆正好動到本檔那條佔 46 點的執行緒 ⇒ **E 輪要問的主要問題
是 recompute period，batching 是「要不要打開」的決策問題，不是「已經變了」的量測問題。**
🔑 我犯的錯：預註冊裡寫「MP ＝現行生產組態、已在生產線上跑了一週」，
**而反面記載就寫在 KNOWN-ISSUES 裡，我沒查**（同族＝[[existence-is-not-wiring]]、
[[no-in-repo-callers-is-not-dead-code]]）。**「碼進了版控」≠「那條路徑在跑」**——
派工與預註冊裡每一個「現行／已啟用／在跑」都要有一個查得到的啟用點，不能只有實作點。
而該線的量測目錄（`doc/audit/2026-08-25_sampling-rounds/`）**08-27 之後再無新檔**——
要重量的計畫（`BRIEF-E-merge.md`，08-26 寫好，E-P1〜E-P4＋三道閘門＋py-spy 附掛＋中止條款
全齊）**從來沒跑**，被手術／手冊／週四吃掉了。
⇒ **本檔的「成本固定、不隨取樣率」是 pre-change 的性質，引用時要標。**
E 輪 prereg 已落＝`doc/audit/2026-08-31_sampling-ceiling-after-merge/PREREG.md`（v0.2-stamped）：
**2×2（batching × recompute period）拆糾纏**——兩顆改動隔六小時落地，混一起量會得到不可歸屬
的數字；並預先凍結誠實出口「**只有 both-on 格動 ⇒ 報交互作用、不挑功臣**」。
🔑 一般化：**「某某是系統的性質」這種記憶，會在改動落地那天靜默過期**，而記憶不會自己知道
——所以改動落地時要回頭問「這推翻／更新了哪一條記憶」（[[check-against-prior-experiments]]
的記憶版）。
