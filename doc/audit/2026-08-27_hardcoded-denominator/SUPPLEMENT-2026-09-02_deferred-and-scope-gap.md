# 工單 Q 增補（2026-09-02，`9/1 mainDev`）：延後的那一半，與掃描漏掉的那條路

PREREG 是 append-only，所以這是增補，不改本文。兩件事：**(B) 被裁定延後**，
以及**當初界定範圍的方式漏掉了每條流那條路**。

[Co-developed with claude code -- Adam]

---

## 1. `sleep_until` 延後（auditor 2026-09-02 夜裁）

PREREG §Q-1 註冊的是 **(A)+(B) 兩者都做**：

- **(A)** 除以實測經過時間 → **已落地**，`f5e35561`。
- **(B)** `sleep_until` 讓穩態週期真的等於 1 s → **沒有落地**。
  `FlowLinkUsageCollector.cpp:1851` 至今仍是 `this_thread::sleep_for(chrono::seconds(1))`，
  而且在本體之前，所以週期 ＝ 1 s ＋ 本體耗時。

**裁決**：今晚不做，排到測試輪結束之後。理由三條，第三條是硬的：

1. 正確性不欠——分母用的是實測間隔，週期多長都除得對，延後的代價有界且已知。
2. 它要重編，而重編會換掉 `build/bin/ndtwin_kernel`，那正是 09-02 夜間四輪測試正在量的那顆。
   半夜換掉它，已跑完的輪次會變成量了一個不存在的組態。
3. 它要 live 驗週期行，而 lab 到 07:34 被測試輪佔滿。

### 🔴 延後期間必須揭露的兩件事

**不寫出來，這兩件會被當成結果讀。**

1. **分身發布的是 1.03–1.25 s 的平均，不是 1 s 的平均**，而且**視窗隨負載變長**
   （08-27 量到 16 流 1.033–1.040 s、64 流 1.032–1.061 s，第一代 fabric 64 流 1.249 s；
   那是當時那顆 binary 的讀數，今天沒有重量）。
   ⇒ **最忙的時候數字最舊。** 任何引用「每秒」速率的頁面都要講成「約一秒」。
2. **兩條臂本體成本不同時，平均視窗也不同。**
   ⇒ 那是**系統性的臂間差異，不是處理效果**。配對比較若一臂的本體較重，
   它的視窗較長，兩臂就不是在同一個時間尺度上被量。不揭露會被當成結果。

⚠️ 單獨做 (B) 而不做 (A) 是危險的：本體一旦超過 1 s，週期又會溢出，
而那時候碼裡沒有除法保護它。現在落地的剛好是安全的那一半——**值永遠對，節奏不準**。

---

## 2. 🔴 範圍是用一個 grep 界定的，而每條流那條路不叫那個名字

PREREG 的增補（§「兩處都要修」那張表）是這樣界定範圍的：

```
grep -n "MultiplySampingRate" FlowLinkUsageCollector.cpp
```

表裡兩列都是 `累加器 * 8` 送進 `updateLinkInfoLeftLinkBandwidth`，兩處都修了。
**但每條流的速率用的是另一個變數，所以那個 grep 從來沒看到它**：

`FlowLinkUsageCollector.cpp:1934`（唯讀查證，2026-09-02）

```cpp
stats.avgByteRateInBps =
    sflow::counterDelta(byte_count_current, byte_count_previous) * 8 * currentSamplingRate;
```

`:1952` 的封包速率同形，`counterDelta(...) * currentSamplingRate`，同樣沒有除法。

**兩件事使它與鏈路那條路等價地脆弱**：

- 它與鏈路的 drain **在同一個迴圈裡**（`while` 在 `:1849`、`sleep_for` 在 `:1851`、
  流速率 `:1934`、鏈路 drain `:2050`、迴圈結束 `:2195`）⇒ **同一個週期**。
- 差分取的是**這個迴圈相鄰兩輪**的計數器（`:1968-1972` 在底部更新 `Previous`）
  ⇒ 真實間隔就是迴圈週期，不是 1 s。

⇒ **高估倍數 ＝ 週期 / 1 s，與鏈路修好之前完全相同，而且同樣隨流數成長。**

**它會被使用者看到**：`info.estimatedFlowSendingRatePeriodically`（`:2008`）；
大象流分類（`:2020` 拿它跟 `MICE_FLOW_UNDER_THRESHOLD` 比）；
以及 top-k 的排序（同檔 `:1993` 的註解自述 `getTopKFlowInfoJson` 用這個欄位排序）。

### 這不是延後，是漏掉

Q 的 commit message 界定的標的是 `updateLinkInfoLeftLinkBandwidth` 的兩個呼叫端；
PREREG §Q-10「本節不宣稱」四條裡也沒有一條把流那條路排除在外。
⇒ **它不在範圍裡，是因為界定範圍的 grep 用了一個它不叫的名字**，
不是因為有人評估過然後決定不修。

📌 **教訓**：用單一識別字的 grep 界定修法範圍，會漏掉「同一個缺陷、不同變數名」的實例。
Q 自己就示範過一次正確的做法——改簽章讓漏掉的呼叫端變成編譯錯誤——
但那只保護得到已經在名單上的那條路。

### 本增補**不**宣稱

- 不宣稱今天的高估幅度是多少：1.03–1.25 s 是 08-27 那顆 binary 的讀數，本次沒有重量。
- 不宣稱 `:2206-2236` 的 Immediately 路徑有同樣的缺陷：它讀的是 `AutoRefreshQueue`
  的滑動視窗（`getSum()`／`size()`），時間語意不同，**沒有讀過那個類別就不下判斷**。
- 不宣稱修法形狀：那是 auditor 派出的查證交付
  （`doc/audit/2026-09-02_live-round/FLOW-RATE-DENOMINATOR.md`）要回答的。
