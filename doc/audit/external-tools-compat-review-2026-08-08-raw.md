# 第 1 節：受影響矩陣

下表列出「**外部工具 × 端點**」組合中，**可基於給定材料明確判定影響**的項目。  
對於材料不足、無法給予四種判定（BREAKS/DEGRADES/SAFE/DEAD）的組合，另於第 6 節集中說明。

| 工具 | 端點 | 呼叫行號 | kernel 主要改動 | 判定 | 後果 | 客戶端要不要改 |
|------|------|----------|------------------|------|------|----------------|
| **Web‑GUI** | `/ndt/get_graph_data` | `index.ts:36` | 無（handler 未變） | SAFE | – | 否 |
| | `/ndt/get_cpu_utilization` | `index.ts:40` | 無 | SAFE | – | 否 |
| | `/ndt/get_memory_utilization` | `index.ts:44` | 無 | SAFE | – | 否 |
| | `/ndt/get_temperature` | `index.ts:48` | 無 | SAFE | – | 否 |
| | `/ndt/get_nickname` | `index.ts:69` | dpid 改嚴格解析 (tryParseUint64) | SAFE | 前端傳入的 dpid 為十進位正整數，不會被拒絕 | 否 |
| | `/ndt/get_detected_flow_data` | `index.ts:76` | 無 | SAFE | – | 否 |
| | `/ndt/get_detected_top_k_flow_data` | `index.ts:83` | 無 | SAFE | – | 否 |
| | `/ndt/modify_device_name` | `index.ts:107` | MAC 改嚴格解析 (tryMacToUint64) | SAFE | 前端 MAC 格式符合 `xx:xx:xx:xx:xx:xx` | 否 |
| | `/ndt/modify_nickname` | `index.ts:116` | 同上 | SAFE | 同上 | 否 |
| | `/ndt/install_…batch` | `index.ts:154` | processFlowBatch 改動（增加 dpid 檢查、回應內容改變） | SAFE | 合法請求仍回 200；非法 dpid 回 404，前端 `handleResponse` 拋錯並 alert，屬改善 | 否 |
| | `/ndt/get_switch_openflow_table_entries` | `index.ts:163` | 無 | SAFE | – | 否 |
| | `/ndt/intent_translator/text` | `LLM.ts:20` | 僅 log level 變更 | SAFE | – | 否 |
| **Energy‑Saving‑App** | `/ndt/install_flow_entry` | `http.cpp:158` | 無（handler 未變） | SAFE | 正常回 200 | 否 |
| | `/ndt/delete_flow_entry` | `http.cpp:201` | 無 | SAFE | – | 否 |
| | `/ndt/set_switches_power_state` | `http.cpp:127` | 無 | SAFE | – | 否 |
| | `/ndt/get_switch_openflow_table_entries` | `http.cpp:308` | 無 | SAFE | App 檢查 `code != 200`，能處理任何非 200 | 否 |
| | `/ndt/get_graph_data` | `http.cpp:337` | 無 | SAFE | 同上 | 否 |
| | `/ndt/get_detected_flow_data` | `http.cpp:366` | 無 | SAFE | 同上 | 否 |
| | `/ndt/get_average_link_usage` | `http.cpp:395` | 無（內容層數值修正） | SAFE | 數值從荒謬變正確，App 有檢查 code；決策可能改變但屬改善 | 否 |
| | `/ndt/acquire_lock` | `http.cpp:423` | 無 | SAFE | 有檢查 code，並解析 body 中的 `status` | 否 |
| | `/ndt/release_lock` | `http.cpp:459` | 無 | SAFE | 同上 | 否 |
| **Network‑State‑Recorder** | `/ndt/get_detected_flow_data` | `recorder.py:183` | 無 | SAFE | 僅檢查 `status_code == 200`；handler 無變，持續回 200 | 否 |
| | `/ndt/get_graph_data` | `recorder.py:183` | 無 | SAFE | 同上 | 否 |
| **Network‑Traffic‑Generator** | `/ndt/get_graph_data` | `distance_seperate.py:24` | 無 | SAFE | handler 無變 | 否 |
| **Network‑Traffic‑Visualizer** | `/ndt/get_graph_data` | `NDTApiClient.java:33` | 無 | SAFE | handler 無變，回 200；Visualizer 不檢查狀態碼，解析正常 | 否 |
| | `/ndt/get_detected_flow_data` | `NDTApiClient.java:49` | 無 | SAFE | 同上 | 否 |
| | `/ndt/get_detected_top_k_flow_data` | `NDTApiClient.java:71` | 無 | SAFE | 同上 | 否 |
| | `/ndt/get_cpu_utilization` | `NDTApiClient.java:92` | 無 | SAFE | 同上 | 否 |
| | `/ndt/get_memory_utilization` | `NDTApiClient.java:110` | 無 | SAFE | 同上 | 否 |
| **Traffic‑Engineering‑App** | `/ndt/get_graph_data` | `TE-App.py:51` | 無（內容層改善） | SAFE | 不檢查狀態碼，但 handler 仍回 200；內容欄位新增／修正不影響解析與邏輯（TE 未使用 ipv4，link usage 正常化可能改變決策但非回歸） | 否 |
| | `/ndt/get_detected_flow_data` | `TE-App.py:61` | 無（path 從空變有值） | SAFE | path 有值使遷移邏輯真正運作，無崩潰風險 | 否 |
| | `/ndt/acquire_lock` | `TE-App.py:71` | 無 | SAFE | 依據 body 的 `status` 欄位，與狀態碼無關 | 否 |
| | `/ndt/release_lock` | `TE-App.py:85` | 無 | SAFE | 同上 | 否 |
| | `/ndt/install_flow_entry` | `TE-App.py:345` | 無 | SAFE | – | 否 |
| | `/ndt/install_…batch` | `TE-App.py:572` | processFlowBatch 改動 | SAFE | TE 不檢查回應；合法請求仍回 200，對 TE 無新增影響 | 否 |

> **註**：未出現在上表中的工具 × 端點組合（例如 Energy‑Saving‑App 的 `/ndt/modify_flow_entry`、`/ndt/disable_switch`，Network‑Traffic‑Generator 的 `/ndt/get_path_switch_count`，以及 Simulation‑Platform‑Manager 相關端點）皆因材料不足而無法給予確切判定，完整分析見 **第 6 節**。

---

# 第 2 節：BREAKS 逐項展開

**本次 kernel 改動未發現可直接宣告為 BREAKS（功能完全失效、崩潰或資料毀損）的具體項目。**  
所有潛在重大風險均涉及「客戶端未提供完整調用鏈」或「請求格式無法從材料確認」，因此下列僅就最接近 BREAKS 的情境進行說明，並明確標示證據缺口。

### 潛在 BREAKS 1：Energy‑Saving‑App 的流量修改操作被忽略

- **kernel 側證據**  
  `processFlowBatch`（用於 `/ndt/modify_flow_entry` 與 batch 端點）現在會對請求中的 dpid 進行存在性檢查（`HttpSession.cpp` 第 949‑990 行）。若 dpid 不存在，回應 **404 Not Found**，body 為 `{"status":"error","error":"unknown dpid",...}`；成功時回 **200**，但 body 由原本的 `"Flows installed, modified and deleted"` 改為 `"queued"` 及接受數量。  
  在 baseline 中，這些端點無論 dpid 是否存在均回 **200** 且宣稱成功。

- **客戶端側證據**  
  `Energy-Saving-App/src/app/http.cpp` 第 176‑197 行 (`modify_flow_entry`) 與第 219‑261 行 (`install_modify_delete_flow_entries`) 透過 `send_post_json_request` 取得 `std::pair<uint32_t, json>`，但 **完全未檢查 `code` 是否等於 200**；它們僅記錄狀態碼與 body，並將狀態碼回傳給調用者。  
  函式本身不會因非 200 而崩潰，但 **調用者若未檢查返回值，將會把失敗操作視為成功**。

- **觸發情境**  
  若 Energy‑Saving‑App 因任何原因發送了不存在於拓撲中的 dpid（例如使用了過時的拓撲資訊、或 dpid 拼寫錯誤），kernel 會回 404。原本 baseline 會回 200（假成功），App 無論如何都會認為成功。現在 kernel 誠實回報 404，但如果 App 的調用者仍忽略狀態碼，則 **功能失效**：實際未修改任何流條目，但 App 內部狀態可能已更新，導致後續節能決策基於錯誤的網路狀態。

- **證據缺口**  
  我們僅持有 `http.cpp`，沒有 Energy‑Saving‑App 的主迴圈或演算法模組（即調用 `modify_flow_entry` 等函式的程式碼）。因此 **無法確證該 App 的最終行為是否真的會導致資料錯誤或流程中斷**。此項目歸入第 6 節「無法判定」。

### 潛在 BREAKS 2：Network‑Traffic‑Generator 的路徑查詢失效

- **kernel 側證據**  
  `handleGetPathSwitchCount` 現在對查詢參數 `src_ip` 與 `dst_ip` 使用 `tryIpStringToUint32`（`HttpSession.cpp` 第 1639‑1650 行），若格式不符或為空則回 **400 Bad Request**。Baseline 中相同狀況會因 `ipStringToUint32` 拋例外而回 **500**。

- **客戶端側證據**  
  `Network-Traffic-Generator/Utilis/distance_seperate.py` 第 64 行以 `requests.get(GET_PATHS)` 發出請求，**未攜帶任何查詢參數**。這代表該請求必然觸發 kernel 的參數解析失敗。

- **觸發情境**  
  若 Generator 確實以無參數方式呼叫，則無論 kernel 新舊，請求均會失敗（原為 500，現為 400）。但若 Generator 原本仰賴 kernel 在無參數時返回所有主機對資料（若 kernel 曾有該行為），則此改動可能導致功能中斷。

- **證據缺口**  
  `GET_PATHS` 變數可能在 Generator 的其他模組中被賦予完整查詢字串（如 `?src_ip=...&dst_ip=...`），但該設定碼未提供。因此無法判定請求的真實格式，亦無法判定 kernel 改動是否造成回歸。歸入第 6 節。

---

# 第 3 節：狀態碼相容性專章

kernel HEAD 可能回傳的非 2xx 狀態碼包括 **400, 404, 412, 423, 501, 502, 500** 以及透傳的控制器狀態碼。以下逐工具分析其錯誤處理路徑。

### 1. Web‑GUI (`api/index.ts` 與 `LLM.ts`)

- **核心處理**：`handleResponse` (第 7‑14 行) 在 `!response.ok` 時執行 `await response.json()` 取得 `errorData`，並拋出 `Error(errorData?.error || "API Error: ...")`。  
  新 kernel 錯誤 body 格式為 `{"status":"error","error":"...","controller_status":N}`，**恰好包含 `error` 欄位**。因此當 kernel 回 400/404/501/502 時，前端能顯示具體錯誤訊息，用戶體驗提升。
- **LLM.ts** (第 34‑36 行) 自行檢查 `!response.ok`，拋出 `` Error(`HTTP error! status: ${response.status}`) ``。它不使用 body 中的 `error` 欄位，但同樣能將錯誤傳播至上層元件。
- **各元件 catch**：`DeviceInformation.tsx` 等顯示 `alert`，`SwitchFlowTable.tsx` 顯示錯誤訊息，均為優雅的錯誤呈現，不會導致整頁崩潰。
- **結論**：所有非 2xx 狀態碼均被妥善捕獲並轉為用戶提示。**無 BREAKS 或 DEGRADES**；原為 200（假成功）現為 4xx/5xx 的場景，前端反而能偵測到失敗。

### 2. Energy‑Saving‑App (`http.cpp`)

此 App 可分為兩類端點處理：

#### a) 有明確檢查 `code != 200` 的函式
包括 `get_switch_openflow_table_entries` (L321), `get_graph_data` (L351), `get_detected_flow_data` (L379), `get_average_link_usage` (L407), `acquire_lock` (L437), `release_lock` (L473)。  
對於這些端點，任何非 200 狀態碼都會觸發 `SPDLOG_LOGGER_ERROR` 並返回安全預設值（`json::object()`、`-1`、`false`）。即使 kernel 因本次改動開始回 400/404/502，App 亦能正確識別並進入錯誤分支，不會崩潰。**行為比 baseline 更正確。**

#### b) 僅記錄狀態碼而未檢查的函式
包括 `install_flow_entry` (L170‑173), `modify_flow_entry` (L193‑196), `delete_flow_entry` (L213‑216), `install_modify_delete_flow_entries` (L257‑260), `set_switches_power_state` (L137‑140), `disable_switch` (L283‑294)。  
這些函式**不自行判斷成敗**，僅將狀態碼回傳給調用者。因此 kernel 回非 200 時，函式本身不會 crash，但調用者若忽略返回值，可能誤判成功。詳細風險見第 2 節（潛在 BREAKS 1）及第 6 節。

### 3. Network‑State‑Recorder (`network_state_recorder.py`)

- 第 184 行：`if response.status_code == 200` 才處理資料；否則 `response.raise_for_status()` 拋出 `HTTPError`。
- `request_data` 函式的最外層 catch (L212) 會記錄錯誤並 `return None`，**導致該請求執行緒終止**。  
  然而，它所呼叫的兩個端點（`/ndt/get_detected_flow_data`、`/ndt/get_graph_data`）handler 均未改動，正常情況仍回 200，因此**不會觸發此錯誤路徑**。無影響。

### 4. Network‑Traffic‑Generator (`distance_seperate.py`)

- `get_hosts` (L24‑43)：檢查 `status_code == 200`，否則返回 `None`。端點未改動，安全。
- `distance_partition` (L64‑74)：對 `/ndt/get_path_switch_count` 同樣僅在 `status_code == 200` 時處理，否則 `raise ConnectionError`。此端點 handler 已改動，但因請求格式無法確認（見第 6 節），無法判定是否會常態收到 400/500。

### 5. Network‑Traffic‑Visualizer (`NDTApiClient.java`)

- **完全不檢查 HTTP 狀態碼**。每個方法直接讀取 `EntityUtils.toString(entity)` 並用 `ObjectMapper` 解析成對應類別（如 `GraphData.class`）。
- 若 kernel 因故回非 200（例如 4xx 或 5xx），body 為錯誤 JSON（如 `{"error":"..."}`），則 `objectMapper.readValue` 可能：
  - 若目標類別無對應欄位，設定為 `null` 或預設值（因 `FAIL_ON_UNKNOWN_PROPERTIES = false`）。
  - 若缺少必要欄位（例如 `GraphData` 需要 `nodes` 陣列），可能拋出 `JsonMappingException`，被 `catch` 捕捉，方法返回 `null`，UI 局部空白。
- 由於這些端點的 handler 均未改動，正常操作**不會觸發非 200**。因此現有改動對 Visualizer 無新增風險。

### 6. Traffic‑Engineering‑App (`TE-App.py`)

- **完全不檢查 HTTP 狀態碼**，直接呼叫 `requests.get(...).json()` 或 `requests.post(...).json()`。
- 若 kernel 回非 200，但 body 為合法 JSON，`.json()` 成功，但後續邏輯可能因缺少預期欄位而拋 `KeyError` 等。所幸其呼叫的端點 handler 多未改動，正常仍回 200。
- 對於 `acquire_lock`/`release_lock`，即使 kernel 回 423/412，TE 僅檢查 body 中的 `"status"` 欄位，故狀態碼不影響其判斷。其他如 `install_flow_entry` 等未變。

---

# 第 4 節：輸入嚴格度提高造成的回歸

kernel 新增了三種嚴格輸入解析：
- `tryParseUint64`：僅接受純數字（無正負號、前導空白、尾隨文字）。
- `tryMacToUint64`：要求恰好 17 字元，分隔符為 `:` 或 `-`，每兩位十六進位。
- `tryIpStringToUint32`：使用 `inet_aton`，標準點分十進位 IPv4。

**逐一檢查各客戶端實際送出的參數值：**

| 客戶端 | 參數 | 送出的格式 | 是否會被新解析拒絕 |
|--------|------|------------|-------------------|
| Web‑GUI | `dpid` (query / body) | `params.dpid.toString()` → 十進位整數字串，例如 `"12345"` | 否 |
| | `mac` (body) | 來自 UI 或裝置資訊，標準 `"xx:xx:xx:xx:xx:xx"` | 否 |
| Energy‑Saving‑App | `dpid` (JSON body) | `json{{"dpid", dpid}}` → JSON 數字，非字串，不經過 `tryParseUint64`（該函式僅用於 query string 解析） | 否 |
| | `ip` (query) | `utils::ip_to_string(ip)` → 標準點分十進位，如 `"10.10.10.1"` | 否 |
| | MAC | 未使用於受影響的端點 | – |
| Network‑Traffic‑Generator | `src_ip`, `dst_ip` (query) | 若存在，來自 `ipaddress` 模組產生的點分十進位 | 否（若提供） |
| Traffic‑Engineering‑App | `dpid` (JSON body) | JSON 數字 | 否 |
| (Simulation 相關) | `app_id` (body) | 未知（見第 6 節） | – |

**結論：現有客戶端在正常使用情況下，送出的參數格式均符合新解析規則，未被更嚴格的檢查拒絕。**  
唯一可能出現問題的情境是客戶端因 bug 傳入負數 dpid 或格式錯誤的 MAC，此時被 kernel 明確拒絕，屬正面改善。

---

# 第 5 節：內容層（非 shape 層）的相容性

### 5.1 主機 `ipv4` 欄位從空變為有值

- **Web‑GUI**：拓樸顯示可能使用 `ipv4`；若原本為空則顯示空白，現有值則顯示 IP，無崩潰風險。
- **Energy‑Saving‑App**：`get_graph_data` 僅將回應存檔，後續處理未知；但 `http.cpp` 本身無直接使用此欄位，函式安全。
- **Network‑Traffic‑Generator** (`get_hosts`)：讀取的是節點 `"ip"` 欄位，非 `"ipv4"`，不受此變更影響。
- **Traffic‑Engineering‑App**：不使用 `ipv4`。
- **無破壞性影響**。

### 5.2 流的 `path` 從 `[]` 變為有值

- **Web‑GUI**：流表格或路徑視圖可能開始顯示路徑；前端若以 `map` 渲染空陣列亦無問題。
- **Energy‑Saving‑App**：`get_detected_flow_data` 存檔；後續若解析 path 且假設可為空則安全，否則有潛在風險（見第 6 節）。
- **Network‑State‑Recorder**：僅儲存原始 JSON，無影響。
- **Network‑Traffic‑Visualizer**：`DetectedFlowData` 類別應包含 `List<PathHop> path`；空陣列與有值陣列均可解析，無影響。
- **Traffic‑Engineering‑App**：`construct_flow_dict` 保留整個 flow 物件，並在遷移邏輯中檢查 `len(path) < 2` (TE‑App.py L288)。以前 path 為 `[]` 會跳過，現在有值則可能開始執行遷移──這是**功能啟用**，非回歸。
- **無破壞性影響**。

### 5.3 `get_average_link_usage` 數值變正確

- **Energy‑Saving‑App** 使用此數值（`http.cpp:416`）並回傳 `double`。原本可能因整數下溢出現天文數字，導致節能演算法誤判；現在得到正確值，**可能改變決策行為，但屬修正，不構成功能失效**。App 本身有檢查 `code != 200`，故若 kernel 回錯誤仍能 fallback。

**結論：內容層的所有變化均為修正／改善，未發現會導致任何客戶端崩潰、解析失敗或進入錯誤分支的證據。**

---

# 第 6 節：無法從給定材料判定的事項

下列項目因缺乏客戶端完整調用鏈、請求格式細節或 kernel 對應端點的實作代碼，**無法僅憑本回顧給予確切判定**。

### 6.1 Energy‑Saving‑App 的 modify / batch 端點之最終影響

- **位置**：`http.cpp` 的 `modify_flow_entry` (L176)、`install_modify_delete_flow_entries` (L219)。
- **問題**：這些函式將 HTTP 狀態碼直接回傳，但**未自行判斷成功與否**。調用這些函式的上層模組（未提供）如何處理返回值（是否檢查 `code == 200`、是否據以回退）決定了 kernel 狀態碼改變（例如 404）是否會造成流程中斷或資料錯誤。
- **需要材料**：Energy‑Saving‑App 的主控制迴圈或策略模組原始碼。

### 6.2 Energy‑Saving‑App 的 `/ndt/disable_switch` 端點

- **位置**：`http.cpp` L269。
- **問題**：kernel HTTP 路由清單與 handler 列表中未見 `handleDisableSwitch` 或 `/ndt/disable_switch` 端點。若該端點根本不存在於 kernel，則任何 kernel 改動均與其無關；若存在但未提供實作，則無法評估其行為變化。
- **需要材料**：kernel 中對應 handler 的原始碼（baseline 與 HEAD）。

### 6.3 Energy‑Saving‑App 的內容層依賴

- **問題**：`get_graph_data` 與 `get_detected_flow_data` 回應內容中，`ipv4`、`path` 等欄位的變化，是否會影響 Energy‑Saving‑App 後續邏輯（例如讀取存檔 JSON 的解析程式碼）？`http.cpp` 僅負責請求與存檔，未使用這些欄位。
- **需要材料**：Energy‑Saving‑App 中消費這些 JSON 檔案的其他模組。

### 6.4 Network‑Traffic‑Generator 對 `/ndt/get_path_switch_count` 的請求格式

- **位置**：`distance_seperate.py` L64 (`response = requests.get(GET_PATHS)`)。
- **問題**：`GET_PATHS` 在該檔案中僅被賦值為基礎路徑（L52），無查詢參數。但該變數為 global，可能在其他未提供的模組中被設定為包含 `?src_ip=...&dst_ip=...` 的完整 URL。若 Generator 確實以無參數方式呼叫，則 kernel 改動前後請求均會失敗，無法判定是否為回歸；若有參數，則需確認其 IP 格式是否合法。
- **需要材料**：Network‑Traffic‑Generator 的啟動腳本或其他引用 `distance_partition` 的模組，以及 kernel `handleGetPathSwitchCount` 的 baseline 完整代碼（以確認原行為是否支援無參數請求）。

### 6.5 Simulation‑Platform‑Manager 相關端點

- **端點**：`/ndt/received_a_simulation_case`、`/ndt/simulation_completed`。
- **客戶端**：Energy‑Saving‑App（或其他 App，見 `settings.hpp` 中的 `request_manager_target_for_app`）與 Simulation‑Platform‑Manager（`sim_server.hpp` 中的 `request_manager_target`）。
- **問題**：這兩個端點的 handler 分別增加了 request body 驗證 (`validateRequestBody`) 及 `app_id` 嚴格解析 (`tryParseUint64`)。但**客戶端實際發送的請求內容、欄位格式及對回應的處理程式碼均未提供**，無法判斷是否會被新驗證拒絕，或狀態碼變化是否影響其流程。
- **需要材料**：Energy‑Saving‑App 中發送 `/ndt/received_a_simulation_case` 的函式；Simulation‑Platform‑Manager 中發送 `/ndt/simulation_completed` 的 HTTP 客戶端程式碼。

### 6.6 其他工具的隱含風險

- **Network‑Traffic‑Visualizer**：雖然正常端點未改動，但若任何未預期的全域變化（如 dispatch 層對未知錯誤的新處理）導致正常端點開始回非 200，Visualizer 會因不檢查狀態碼而可能將錯誤 JSON 映射到領域物件，導致 `null` 回傳或局部崩潰。目前無證據顯示此情況會發生，但材料未包含 Visualizer 的 UI 層如何處理 `null` 回傳。
- **Traffic‑Engineering‑App**：對 `install_modify_delete_flow_entries` 不檢查回應，若因 kernel 改動開始收到 404（非法 dpid），TE 將毫無感知地繼續執行，可能做出無效的流遷移。雖然以前也是假成功，但這類「安靜失敗」的影響取決於 TE 的後續邏輯；TE 完整原始碼已在手，其行為是**忽略回應**（L572-576），故對 TE 本身無新崩潰，但可能對網路狀態造成非預期後果，屬 DEGRADES 潛勢，但因 TE 是「發送即忘」設計，嚴格來說並未「壞掉」。此處仍提列以備後續驗證。

---

**總結**：本次 kernel 改動在給定材料範圍內，對七個外部工具的直接功能**未發現明確的 BREAKS**。主要風險集中於 Energy‑Saving‑App 的流量操作端點與 Network‑Traffic‑Generator 的路徑查詢，均因客戶端完整調用鏈或請求格式缺失而無法確證。誠實揭露這些未知項，較猜測答案更有價值。
