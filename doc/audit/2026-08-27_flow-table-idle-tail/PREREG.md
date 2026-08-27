# 工單 W 預註冊：`get_detected_flow_data` 有 92% 是已經結束的流

**2026-08-27 23:2x，`8/27 mainDev`。從工單 M 的 pre-flight 掉出來的獨立發現。**
**照審查員裁定：不塞進 M（援工單 E `29.49` 先例——「以上皆非」要獨立記錄）。**

---

## W-0-bis. 🔑 **主張是一個公式，不是一個數字**

> **膨脹倍率 ≈ `1 + 15 s × 新流速率 / 平均併發流數`**

**13.3× 是這個公式在 churn 工作點（1.6 新流/秒、平均併發 4.7）的一個實例，不是「那個數字」。**

⇒ 公式**做出預測、因此可被否證**：長流工作點下應趨近 **1**（量不到），
高 churn 下應該量得到。**任何人可以換一個工作點來打它。**

## W-0. 觀察（實測，不是推測）

`check_denominator.py` 拿 churn schedule 逐秒對 API：

| | |
|---|---|
| mean **expected_alive**（當下真的在送封包的流） | **4.7** |
| mean **api_flows**（`/ndt/get_detected_flow_data` 列出的） | **63.0** |
| **比值** | **13.3×** |

⇒ **那個端點回報的流，約 92% 已經結束了。**

## W-1. 機制（讀碼，已確認）

`FLOW_IDLE_TIMEOUT = 15000 ms`（`include/ndt_core/collection/FlowLinkUsageCollector.hpp:35`）。
流停止之後**留在表裡 15 秒**才被 `purgeIdleFlows` 清掉。
churn 每秒起 1.6 條 ⇒ 15 s 尾巴 × 1.6 ≈ **25 條殭屍**，加上真正活著的 ~5 條。

⇒ **這不是 bug，是設計** ——**但端點的名字與型別沒有把它說出來。**
回傳的每一筆長得像「一條被偵測到的流」，**沒有欄位說「這條已經死了 12 秒」**。

📌 **本 repo 的已知形狀，時間版**：[[replace-vs-add-bug-shape]]（「該取代卻只會新增」，已 7 例）。
**這裡舊資料不是被覆蓋，是被留著直到超時，而讀的人不知道。**

## W-2. 🔴 **它有真實消費者，而且在 repo 外**

審查員要我查「誰在讀」，因為**「沒人用」和「沒查」是兩件事**：

| 消費者 | 位置 | 做什麼 |
|---|---|---|
| 🔴 **Energy-Saving-App** | `~/Energy-Saving-App/src/app/energy_saving_app.cpp:741` | `json flow_data = get_detected_flow_data();` → 塞進 `json2sim["flowDataList"]` **餵給模擬** |
| | `~/Energy-Saving-App/src/app/http.cpp`、`include/app/http.hpp` | 傳輸層 |
| `tools/twin_audit/twin_audit.py:91` | 本 repo | 稽核工具（**其檔頭已記錄過一次「流宣稱在流動但實際沒有」的事件，2026-08-13**） |
| `tools/contract_test/*` | 本 repo | 契約測試的 fixture |

⇒ **省電決策的輸入裡，有 92% 是已經結束的流。** 若那個模擬按「有多少流在跑」決定要不要關交換機，
**它看到的負載比真實高一個數量級。**

⚠️ **我沒有讀 Energy-Saving-App 的模擬如何使用 `flowDataList`** ——
**「餵進去」不等於「據以決策」**。這是 W-3 的第一件事。

📌 `twin_audit.py` 的檔頭寫著 2026-08-13 OVS 過夜輪就遇過
「`get_detected_flow_data` 回報一條流正在流動，而實際沒有」。**那可能就是這個。未對帳。**

## W-2-bis. 🔴 對帳 2026-08-13 的觀察：**確認不同源，而且那一個更嚴重**

`tools/twin_audit/twin_audit.py` 檔頭記錄的事件：

> 2026-08-13 OVS 過夜輪。`get_detected_flow_data` 回報一條流「以 9–15 Mbps 流動」；
> **那條流已經 291 秒沒有帶過任何封包。**

### 判準是一個硬上界，不是相似度

`purgeIdleFlows`（`FLUC:2238-2248`）：`idle_time = now − info.endTime`，`>= FLOW_IDLE_TIMEOUT` 就移除。
而 `info.endTime` 在 **`:1520` 與 `:1527` 每次樣本抵達時被更新**。

⇒ **一條流在最後一個樣本之後 15 秒被清掉。W 的機制在結構上有 15 秒的上界。**
⇒ **291 秒是那個上界的 19 倍。W 解釋不了它。**

| | W（今晚） | 2026-08-13 |
|---|---|---|
| 流被正確標成 idle 了嗎 | ✅ 是，然後保留 15 s | ❌ **從來沒有**——`endTime` 一直在被更新 |
| 上界 | **15 秒（硬）** | **291 秒且仍在繼續** |
| 平面 | P4 | OVS |

🔴 **裁決：確認不同源。** 不是「症狀像所以同源」，也不是「資料不足」——
**是 W 的機制帶著一個 15 秒的硬上界，而觀察值是 291 秒。**

⚠️ **兩者共有的是後果不是成因**：讀的人都拿到一條「看起來活著」而實際沒有流量的紀錄。
**成因不同 ⇒ 修 W 不會修掉 08-13 那個。**

### 🆕 而追這件事時發現了一個 08-13 的候選成因（未驗證）

`FLUC:2242`：

```cpp
if (now <= info.endTime) { continue; }   // 跳過，永不清除
```

`now` 來自 **`getCurrentTimeMillisSystemClock()` —— 系統時鐘，不是 steady clock**。

⇒ **若系統時鐘往回跳（NTP 校正、VM 暫停/恢復、手動改時間），
`now <= endTime` 會成立，那條流就被 `continue` 跳過——而且每一輪都跳過，直到 wall clock 追上。**
**那會產生一條沒有上界的殭屍紀錄**，正好是 291 秒那個形狀。

🔴 **未驗證，我不宣稱這就是 08-13 的成因。** 但它是一個**具名、可測**的候選：
把系統時鐘往回撥、看那條流是否永不消失。**這比「ingest 重播舊紀錄」那個描述更具體。**
⇒ 建議**開成 W 的子項或獨立工單**，因為它與 15 秒尾巴是**兩個不同的缺陷**。

## W-2-ter. 🔴 **Energy-Saving-App 讀了它,而嚴重度取決於在哪個分支上跑**

審查員要的三個答案:

### ① `flowDataList` 有沒有進到會影響輸出的計算? —— **有**

`energy_saving_app.cpp:743` 把整包塞進 `json2sim["flowDataList"]`,
再經 `send_case` 送給 **`energy_saving_simulator`(獨立 ELF,無原始碼)**。
**app 自己的決策(`findRedundantNodes`)只讀 `Graph`**,不讀 flowDataList
⇒ **它是給模擬器用的,而模擬器的裁決決定要不要真的關機。**

### ② 逐流還是聚合? —— **逐流**

`strings energy_saving_simulator` 命中 `flowDataList`,以及:

```
flow ip:{}->{}, port:{}->{} NOT allocated.
flow ip:{}->{}, port:{}->{} NOT in any link
flow not found ip:{}->{}, port:{}->{}
flow:{}->{}, port:{}->{}, oldband={}, newband={}, diff={}
flowPathDiffs        flows are EMPTY!
```

⇒ **它按 5-tuple 逐流處理,而且做每條流的頻寬差分(`oldband`/`newband`/`diff`)。**
⇒ **92% 的死流會被當成活流逐一處理。**

### ③ 有沒有把流當負載指標? —— **有,而且這是分支相依的**

**逐流頻寬差分就是負載指標。** 那麼死流帶什麼速率?

| 分支 | 停掉的流回報的速率 | 後果 |
|---|---|---|
| **本分支**(`fix/flow-rate-divide-by-zero`) | **0**(`FLUC:1911`,guard `31b357a`) | 死流貢獻 0 頻寬 ⇒ **沒有幻影負載** |
| 🔴 **`origin/main`(baseline)** | **保留最後一個非零值** | **幻影負載是真的** |

`git merge-base --is-ancestor 31b357a origin/main` ⇒ **不是祖先,baseline 沒有這個 guard。**

而 `FLUC:1896-1910` 的註解逐字記著 baseline 的行為與實測:

> 一條停掉的流**永遠保留它最後的非零速率、一直被標成 elephant、永遠不離開 top-k**。
> 實測:iperf3 結束後 5 秒與 10 秒,top-k 仍回報**逐位元相同**的 20.3 Mbps / 10496 pps。
> **樂觀型失敗:它顯示不存在的負載,而且看起來像穩定不像陳舊。**

⇒ 🔴 **在 baseline 上,W 的 13× 尾巴 × 陳舊非零速率 = 送給省電模擬器的幻影負載。**
**方向是「看到不存在的負載」⇒ 拒絕關掉其實閒置的交換機 ⇒ 正好抵銷這個 app 的目的。**
✅ **在本分支上,尾巴仍在(13×),但死流速率是 0 ⇒ 頻寬不被高估。**

⚠️ **我不宣稱的**:
- **模擬器讀哪一個速率欄位**(`_in_the_last_sec` 對 `_in_the_proceeding_1sec_timeslot`)。
  baseline 上**只有後者**會保留陳舊值,前者讀 0。**無原始碼,未確認。**
- **模擬器是否用「流的數量」本身當指標**(`flows are EMPTY!` 暗示有計數檢查)。
  **若有,13× 在兩個分支上都會咬人,與速率無關。**

## W-2-quater. 🔑 這是給今晚 chaos 差異臂的一個**預先寫下的預測**

chaos 要跑 baseline 對現版做差異比對。**上面那張表就是一個可否證的預測:**

> **baseline 的 `get_detected_top_k_flow_data` 在流量停止後仍會回報非零速率(且逐位不變);
> 本分支會回報 0。**

**流量停止後 5–10 秒查兩邊的 top-k 即可。** 若 baseline 沒有重現,
**上面整段對 baseline 的歸因就要撤回。**

## W-3. 待做（**都不需要實驗室，除了最後一項**）

1. **讀 Energy-Saving-App 的模擬**：`flowDataList` 是否影響關機決策？影響到什麼程度？
2. **對帳 2026-08-13 那次觀察**：是不是同一個成因。
3. **API 契約**：`doc/2026-01-02_ndt_api.md` §4 有沒有說這個端點包含已結束的流？沒有 ⇒ 文件缺陷。
4. **（需要實驗室）** 量穩定負載下的膨脹倍率——churn 是最壞情況，長流下尾巴佔比小得多。
   **本工單的 13.3× 只在 churn 工作點成立，不得外推。**

## W-4. 🔴 本工單**不**宣稱

- **不**宣稱這是 bug。**15 秒的保留可能是刻意的**（讓短流不要一閃就消失）。
  **缺陷在於端點沒有把它表達出來**，不在於保留本身。
- **不**宣稱 Energy-Saving-App 有錯。**未讀它怎麼用。**
- **不**宣稱 13.3× 是普遍值。**那是 churn 工作點（1.6 flows/s）的值**，
  倍率 ≈ `1 + 15 × 新流速率 / 平均併發`。長流下趨近 1。
- **不**宣稱與工單 M 有因果關係。**M 只是撞見它。**

[Co-developed with claude code -- Adam]
