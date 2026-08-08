# 外部工具相容性審查（baseline 28b8b13 → HEAD）

**問題**：共用 kernel 的改動會不會讓七個獨立維護的外部工具失效？

**方法**：把 kernel HTTP 層完整 diff（含狀態碼清單、`OpResult`、`respondToOpResult`、Utils
嚴格化）與**七個工具全部接觸 HTTP 的原始碼**（加行號）一起送 `deepseek-v4-pro -e max`，
164 KB / 3792 行。原始回覆見 `doc/audit/external-tools-compat-review-2026-08-08-raw.md`。

前一輪的 change-magnitude review 在建議中寫「需確認所有用戶端已更新或容忍新狀態碼」——
那句是它在說「這件事我做不到」，因為它當時看不到任何一行客戶端程式碼。這一輪就是做那個「需確認」。

---

## 結論

**七個工具都沒有 BREAKS。** 兩個 DEGRADES、一個 DEAD，其餘 SAFE。

先講最重要的前提，這件事把受影響面壓得比「幅度大」聽起來窄很多：

**逐函式 md5 比對 baseline 與 HEAD，外部工具會碰到的 14 個 handler 位元相同：**

    handleGetGraphData, handleGetDetectedFlowData, handleGetDetectedTopKFlowData,
    handleGetCpuUtilization, handleGetMemoryUtilization, handleGetTemperature,
    handleGetAverageLinkUsage, handleGetSwitchOpenflowTableEntries,
    handleAppRegister, handleAcquireLock, handleReleaseLock,
    handleSetSwitchesPowerState, handleInstallFlowEntry, handleDeleteFlowEntry

**Network-State-Recorder 與 Network-Traffic-Visualizer 碰到的端點一個都沒改。**

dispatch 層（`buildResponse` 的抽出）是純重構：`m_res = buildResponse(); writeResponse();`，
OPTIONS 204 與 JSON 400 的 body 形狀都沒變 —— **受影響面沒有因為這個重構而擴大**。

---

## 兩個 DEGRADES

### D1. 批次端點的「全批拒絕」對上兩個丟掉回應的客戶端

`processFlowBatch` 新增：任一 dpid 不在拓撲中 → **404，且整批拒絕**（`HttpSession.cpp:949-990`）。
baseline 是一律 200，壞 dpid 的條目進佇列後在下游失敗，**好的 dpid 照樣裝上**。

兩個客戶端**完全丟掉回應**：

| 客戶端 | 呼叫點 | 怎麼丟掉的 |
|---|---|---|
| Energy-Saving-App | `energy_saving_app.cpp:225`、`:241` | `install_modify_delete_flow_entries(entries_to_send);` —— 回傳型別是 `std::optional<uint32_t>`，沒有接收 |
| Traffic-Engineering-App | `Traffic-engineering-App.py:572` | `requests.post(...)` 沒有賦值，送出即忘 |

所以行為變化是：**一批混一個壞 dpid，以前部分生效，現在完全不生效，而這兩個客戶端都看不到 404。**

這不是「回歸到壞掉」—— 以前那個 200 也是假的。但這是**我把部分成功換成了全部失敗**，
而那個換法的理由（「部分套用的 200 讓呼叫者無法知道哪一半生效」）只對**會看狀態碼的**
客戶端成立。對這兩個瞎的客戶端，我拿走了它們原本能得到的部分效果。

TEA 那條更值得注意：它送的是 `modify_flow_entries`，做的是流量遷移決策，靜默失效的後果是
網路停在它以為已經改掉的狀態。

**待決**：要嘛保留 all-or-nothing 並接受這兩個客戶端需要改，要嘛改成「拒絕壞的、套用好的、
在 body 裡列出被拒的 dpid」。前者正確但需要別人配合，後者不需要任何人配合但回到了
「200 但只有一半生效」。**這是設計決定，不是實作細節，需要 Adam 決定。**

### D2. Network-State-Recorder 的錯誤路徑會殺掉記錄執行緒（既有脆弱性，非本次造成）

`network_state_recorder.py:200` 的 `else: response.raise_for_status()` 拋出後，被
**while 迴圈之外**的 `except requests.RequestException` 接住（`:212`）→ `return None`
→ **該端點的記錄執行緒永久結束**，只留一行 log。

它的兩個端點（`get_detected_flow_data`、`get_graph_data`）都沒改，所以**現在不會觸發**。
但這代表：這兩個端點未來任何一次非 200 都會靜默終止錄影。列為既有風險，不是本次回歸。

---

## 一個 DEAD

`/ndt/disable_switch`（`Energy-Saving-App/src/app/http.cpp:269`）：kernel 從未註冊這個端點，
而該客戶端函式**零呼叫點**，活的路徑走 `/ndt/set_switches_power_state`。
兩邊都是死的，所以 kernel 怎麼改都不影響。詳見 memory `existence-is-not-wiring`。

---

## 逐項查證：它引用的行號全部正確

| 它的主張 | 查證 |
|---|---|
| Energy-Saving 的六個讀取函式檢查 `code != 200` | ✅ `http.cpp` 321/351/379/407/437/473 全部是 `if (code != 200 \|\| body.is_null())` |
| NSR `:184` 只在 200 時處理，否則 `raise_for_status` → `:212` 接住 → `return None` 使執行緒終止 | ✅ 完全正確，含「執行緒終止」這個推論 |
| Web-GUI 批次失敗會 alert 出真正的錯誤 | ✅ `SwitchFlowTable.tsx:973-999` 是 `try { await …; alert('成功') } catch { alert(\`Error …: ${error.message}\`) }`，而 `error.message` 來自 `handleResponse` 的 `errorData?.error`，kernel 的錯誤 body 正好有 `"error"` 欄位 |
| TEA `:288` 有 `if len(path) < 2: continue` | ✅ path 從 `[]` 變有值 → 遷移邏輯開始真的執行。這是**功能啟用**，不是回歸 |
| TEA `:572` 呼叫批次端點 | ✅ **這是它抓到、我漏掉的**（見下） |

### 它抓到一個我漏掉的呼叫點

`Traffic-engineering-App.py:572` POST 批次端點。我的 grep 用 `/ndt/` 當 pattern，
而這一行是 `ndt_url + "install_flow_entries_..."`，`ndt_url` 本身已經帶著 `/ndt/`，
所以那一行**不含** `/ndt/` 字串，被我漏掉。它讀完整檔案，所以看到了。

教訓：**用字面 pattern grep 端點會漏掉字串拼接的呼叫點。** 要找完整清單得看 base URL 變數
（這裡是 `ndt_url`），不是端點路徑。

---

## 它錯的一條

**它的「潛在 BREAKS 2」說 NTG 無參數呼叫 `get_path_switch_count`「必然觸發 kernel 的參數解析失敗」。
這是錯的。**

`handleGetPathSwitchCount` 的嚴格化在 `if (!srcIpStr.empty() && !dstIpStr.empty())` 裡面
（`HttpSession.cpp:1634`）。無參數走 `:1684` 的 else 分支「回傳全部路徑數」，**200，且與
baseline 完全相同**。所以 NTG 是 SAFE。

它自己在 §6.4 明確說了缺 `handleGetPathSwitchCount` 的完整函式才能確認 —— **這是我的材料缺口，
不是它的紀律問題**：diff 只帶 ±3 行 context，那個 guard 在 hunk 外面。它把不確定的東西
放進「無法判定」而不是斷言，這是對的做法；但它敘述機制時用了「必然」，那個詞不該出現。

**下次的做法**：涉及控制流的判斷，附上**完整函式**，不要只給 diff。

---

## 它的六個「無法判定」，我關掉四個

| 它的缺口 | 我補上的材料 | 結論 |
|---|---|---|
| §6.1 Energy-Saving 的上層呼叫者怎麼處理回傳值 | `energy_saving_app.cpp:225`、`:241` | **丟掉回傳值** → D1 成立 |
| §6.2 `/ndt/disable_switch` 是否存在 | kernel 無此端點，客戶端函式零呼叫點 | **DEAD** |
| §6.4 NTG 的請求格式 | `distance_seperate.py:64` 確實無參數，且 kernel 有 else 分支 | **SAFE** |
| §6.5 simulation 端點的請求內容 | `Energy-Saving-App/include/app/types.hpp:26-33` 的 `to_json` | **SAFE**（見下） |
| §6.3 Energy-Saving 消費存檔 JSON 的其他模組 | 未查 | 仍未判定 |
| §6.6 NTV 的 UI 層如何處理 `null` | 未查 | 仍未判定（端點未改，不觸發） |

### §6.5 的細節：simulation 端點是 SAFE，而且對得剛剛好

`handleReceivedSimulationCase` 新增 `validateRequestBody`，要求五個**字串**欄位：
`simulator, version, app_id, case_id, inputfile`（`SimulationRequestManager.cpp:46-50`）。

Energy-Saving-App 的 `request_manager_ip/port` 是 `localhost:8000` —— **就是 kernel**
（`include/app/settings.hpp:20-21`）。它送的是 `json body_json = task;`，而
`SimulationRequest` 的 `to_json` 吐出的正好是那五個欄位，型別全部 `std::string`
（`include/app/types.hpp:7-33`）。**逐一對上，不多不少。**

---

## 其他值得記下的

### 內容層改動沒有破壞任何客戶端

- **`ipToString` 從 `inet_ntoa` 換 `inet_ntop`**：對同一個 `s_addr` 產生的字串**完全相同**。
  純可攜性改動。所以 NTG 的 `hosts[path["src_ip"]]` 直接 dict 索引不會 KeyError。
- **MAC 的 round-trip**：Web-GUI 把 `get_graph_data` 給的 MAC 原封送回 `modify_nickname`，
  而 kernel 的 `macToString`（`Utils.hpp:676-690`）一律零填充成兩位十六進位、`:` 分隔
  → 恆為 17 字元 → `tryMacToUint64` 的長度檢查永遠通過。
- **批次成功 body 換形狀**（`"Flows installed, modified and deleted"` → `{"status":"queued","accepted":N}`）：
  grep 過七個 repo，**沒有任何人比對那個字串**。

### 最清楚的使用者可見改善

Web-GUI 對一個不存在的 dpid 裝流表，以前跳 **「Flow added successfully!」**。
現在跳 **「Error adding flow: unknown dpid」**。同一段 `try/catch` 沒動過一個字。

---

## 待決與待查

1. **D1 的設計決定**（all-or-nothing vs 部分套用＋列出被拒 dpid）—— 需要 Adam 決定。
2. §6.3：Energy-Saving-App 消費 `Graph.json` / `FlowDataList.json` 的模組沒查，
   `ipv4` 從空變有值、`path` 從 `[]` 變有值對它的影響未知。
3. §6.6：NTV 的 UI 層對 `null` 的處理沒查（端點未改，目前不觸發）。
4. 通知 Energy-Saving-App 與 Traffic-Engineering-App 的維護者：批次端點現在會回 404，
   而他們兩邊都丟掉了回應。
