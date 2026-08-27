# 工單 W 預註冊：`get_detected_flow_data` 有 92% 是已經結束的流

**2026-08-27 23:2x，`8/27 mainDev`。從工單 M 的 pre-flight 掉出來的獨立發現。**
**照審查員裁定：不塞進 M（援工單 E `29.49` 先例——「以上皆非」要獨立記錄）。**

---

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
