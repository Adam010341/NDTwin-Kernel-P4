# L2 契約測試與 log 檢查

實作 [doc/2026-07-27_testing_workflow.md](../../doc/2026-07-27_testing_workflow.md) 的 **L2 層**：把「打開元件看看有沒有 error」變成機器判斷的 pass/fail。

不需要安裝任何套件，只要 `python3`。

---

## 為什麼需要這個

Workspace 裡 7 個 tool/app 跟 kernel 之間**唯一**的介面就是 `/ndt/*` HTTP API。所以 kernel 的 API 只要形狀變了，所有元件會同時壞掉，但每個壞的樣子都不一樣，很難從單一元件的畫面看出來。

在一個地方把契約驗過，等於一次驗證了所有元件的地基。

---

## 四支工具

| 工具 | 層 | 檢查什麼 |
|---|---|---|
| `run_contract_test.py` | L2 | kernel 的 API 回應：結構、語意不變量、錯誤路徑 |
| `l3_component_check.py` | L3 | 各元件依賴的端點是否都在、契約是否成立 |
| `compare_baseline.py` | L4 | P4 跟 OVS baseline 的差異 |
| `check_logs.py` | — | kernel 的 log：未預期的 warning/error |

啟動編排與 L0／L1 在 [../test_workflow/](../test_workflow/)。

---

## 快速開始

```bash
cd tools/contract_test

# 1. 先確認測試腳本本身是對的（不需要 kernel 在跑）
./run_contract_test.py --self-test

# 2. kernel 跑起來之後，做唯讀檢查（不會改到網路狀態）
./run_contract_test.py --topology ../../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json

# 3. 開始產生流量後，加上 telemetry 相關檢查
./run_contract_test.py --topology <拓撲檔> --with-traffic

# 4. 檢查 log
./check_logs.py /path/to/kernel.log
```

兩支都是**成功才回傳 exit code 0**，可以直接接進 CI。

---

## run_contract_test.py

### 三種檢查

**1. 結構** — 回應是合法 JSON、欄位存在、型別正確。失敗訊息會指到確切位置：

```
nodes[3].is_up: expected bool, got str ('true')
```

**2. 語意不變量** — 這是把「看一眼」變成「可判定」的關鍵。期望值**從拓撲檔推導**，不是寫死的，所以換拓撲會自動適應（OVS 10 switch/128 host、P4 10 switch/4 host 都能用同一套）：

```
switch(es) not enabled (not connected to a controller): s3(dpid=3)
  -- in P4 mode this usually means the proxy never called /ndt/inform_switch_entered

3 flow(s) with an empty path: 10.0.0.1->10.0.0.4
  -- the Classifier has no flow-table data (check /stats/flow/<dpid>)
```

**3. 錯誤路徑** — 餵壞的輸入，要回合理的 4xx，不能回 500 也不能假裝成功。這類檢查會抓到：未知 dpid 被安靜轉給 Ryu、非數字 dpid 造成 500、lock 沒有正確回 423/412。

### 重要參數

| 參數 | 說明 |
|---|---|
| `--topology <檔案>` | **必填**。kernel 啟動時用的拓撲檔，不變量的期望值由它推導 |
| `--with-traffic` | 額外要求「有 flow、path 非空、速率非零」。沒有流量時不要加，否則會誤報 |
| `--allow-mutations` | 才會執行會改動網路的端點（裝規則、改電源、改名稱）。**預設不執行** |
| `--url` | kernel 位址，預設 `http://localhost:8000`（或環境變數 `NDT_API_URL`） |
| `--save-json <目錄>` | 把每個回應存檔。這就是 L4 做 OVS/P4 差異比對的 baseline |
| `--only <名稱>` | 只跑指定檢查，除錯時用。可重複 |
| `--self-test` | 用 `doc/2026-01-02_ndt_api.md` 的範例驗證 schema 本身，不需要 kernel |

### 鎖的檢查用 `graph_lock`（不是自訂型別）

`LockManager::stringToLockType` 只認得 `routing_lock` / `graph_lock` / `power_lock`，其他一律回 `Unknown`，而 `acquireLock`／`renew` 對 `Unknown` 直接回 false。所以**自訂一個假的 lock type 會讓每個鎖檢查都失敗，而且互斥邏輯從頭到尾沒被驗到**。

用 `graph_lock` 的理由：它是 kernel 真的認得的型別，而全 workspace 掃過只有 `routing_lock` 被 app 使用（Energy-Saving-App、Traffic-Engineering-App）。所以這些檢查跑的是真正的互斥語意，又不可能干擾正在跑的 app。

驗證的是一條完整生命週期：

```
acquire → 第二次 acquire 必須 423 → renew → release → 再 acquire 必須成功 → cleanup
```

其中「再 acquire 必須成功」會抓到「release 回報成功但其實沒放開」這種 bug。

### known_gap：已知的 kernel 缺陷

有些檢查會失敗，原因是 kernel 真的有缺陷、而且短期內不會修。這種在 `spec.py` 標上 `known_gap`（附原因），行為是：

- 失敗 → 顯示黃色 `GAP`，**不計入失敗**（否則測試永遠是紅的，就沒人看了）
- 哪天它**通過了** → 顯示 `FIXED`，並提醒你把標記拿掉

目前唯一一條是 `release_lock_not_held`：`HttpSession::handleReleaseLock` 不管鎖有沒有被持有、型別有沒有效，**一律回 200**，所以「釋放一個沒持有的鎖」跟正常釋放無法區分。`doc/2026-07-27_testing_workflow.md` 寫的「應該回 412」目前並未實作。

### 為什麼預設不跑 mutation

`--allow-mutations` 會真的下流量規則、改電源狀態。對正在跑的系統來說這是破壞性的，所以必須明確開啟。唯讀檢查可以隨時對生產環境跑。

（例外：lock 相關檢查會執行，但它用 `graph_lock` —— 一個 kernel 認得、但沒有任何 app 在用的型別，所以不會干擾正在跑的 app。詳見上面一節。）

### --self-test 是什麼

它拿 `doc/2026-01-02_ndt_api.md` 裡的實際回應範例去驗證 schema。**如果 schema 連文件裡的範例都不接受，那是 schema 寫錯了** — 在這裡發現比對著真系統 debug 便宜太多。

它同時檢查每個不變量的**兩個方向**：好資料要安靜、壞資料要噴錯。這樣才知道檢查不是「永遠都過」的假綠燈。

目前 47 個 self-test 檢查。

---

## check_logs.py

### 核心概念

沒有 allowlist 的話，「檢查 log 有沒有 warning」在 warning 超過幾個之後就失效了 — 真正新出現的問題會被你已經決定接受的那些淹沒。

有了 allowlist，**沒列在裡面的就是失敗**，所以 regression 藏不住。

### 判定規則

| 情況 | 結果 |
|---|---|
| `error` / `critical` 等級 | **失敗**，除非明確列在 allowlist |
| `warning` 等級 | **失敗**，除非列在 allowlist |
| 符合 `FORBID` 樣式 | **失敗，不管什麼等級**（包含 info/debug） |
| allowlist 有列但這次沒對到 | 提示（方便清理過期項目） |

### 崩潰偵測（不受 allowlist 影響）

crash 訊息是 runtime 印的，不是 spdlog 印的，所以**不符合 log 格式**，原本會被 `--ignore-unparsed` 整批丟掉 — 等於把最重要的訊號放在盲區。

現在會先掃過**每一行**（不管解析得出來與否）尋找：

```
terminate called after throwing / what():        ← std::terminate
Segmentation fault / core dumped / SIGSEGV       ← 記憶體錯誤
Floating point exception / SIGFPE                ← 整數除以零
Assertion ... failed / std::bad_alloc            ← 斷言、配置失敗
AddressSanitizer / double free / 純虛擬呼叫       ← 其他致命錯誤
```

這些**永遠失敗，而且不能被 allowlist 放行**。Phase 0 修掉的兩個 bug 剛好各是一種（`std::terminate` 和 SIGFPE），以前的工具抓不到，現在會。

### 錯誤路徑會污染 log 檢查 — 用 `--to-line` 解

L2 的錯誤路徑檢查會**故意**讓 kernel 寫 ERROR／WARN（畸形 JSON、未知 dpid、非數字 dpid、不存在的端點）。如果檢查整份 log，這一層就會永遠是紅的，而且原因是測試自己造成的 — 那會訓練你忽略它，正好是這個機制最不該發生的事。

`run_layers.sh` 的解法：跑 L2 **之前**先記下 log 行數，最後只檢查那之前的部分。

```bash
./check_logs.py kernel.log --to-line 120   # 只看前 120 行
./check_logs.py kernel.log --from-line 50  # 跳過前 50 行（例如上一輪的殘留）
```

崩潰偵測不受 window 影響 — 它一律掃全部。

### FORBID 為什麼存在

有些訊息的嚴重性跟它被記錄的等級不符。例如 `Unsupported SFlow Version` 是用 `WARN` 記的，但它代表**所有 telemetry 都被丟掉了** — 整個數位孿生的資料全部是空的。

FORBID 讓這種訊息不管記在哪個等級都會讓測試失敗。

而且 FORBID 的違規**不會**被 `--suggest-allowlist` 建議加進白名單 — 那種訊息要修，不是要放行。

### allowlist 格式

`warning_allowlist.txt`，三欄用**前後有空白的 pipe**（`" | "`）分隔：

```
LEVEL | python regex | 為什麼可以接受
```

不是裸的 `|`，這樣 regex 的 alternation 才能用（寫成 `(int|float)`，pipe 兩側不加空白）。

比對的是**訊息本文**（時間戳、等級、檔名行號、函式名都會先被剝掉，ANSI 色碼也會清掉），所以不用自己處理前綴。

### 導入到現有的 log

現有的 log 大概本來就有一堆 warning。用這個產生起始清單：

```bash
./check_logs.py kernel.log --suggest-allowlist
```

它會輸出可以直接貼的 allowlist 行（數字會自動泛化成 `\d+`，一條規則涵蓋多個實例）。

**但不要無腦貼上。** 這個機制的價值在於逼你逐條決定「這個 warning 到底可不可以接受」，而不是把所有 warning 消音。每一條都要填上理由。

### 清理機制

工具會報告「列在 allowlist 但這次沒對到」的項目，避免清單長期累積垃圾。

FORBID 規則不會被列為未使用 — FORBID 沒對到代表系統健康，那正是我們要的。

---

## l3_component_check.py

L2 問的是「kernel 的 API 對不對」；L3 問的是「**哪些元件會壞**」。改完某個端點之後，不用把七個工具都開起來，就能知道影響範圍。

```bash
./l3_component_check.py --map                          # 離線：依賴地圖
./l3_component_check.py --blast-radius get_graph_data  # 離線：影響哪些元件
./l3_component_check.py --topology <拓撲檔>             # 完整檢查
./l3_component_check.py --topology <拓撲檔> --component Web-GUI
```

### 兩種檢查

**1. 存在性** — 元件呼叫的每個端點都必須存在。404 就代表元件在打一個 kernel 沒實作的東西。

這是怎麼抓到 `disable_switch` 的：Energy-Saving-App 一直在 POST `/ndt/disable_switch`，kernel 從來沒註冊過，所以一直拿 404，而 app 把錯誤吃掉了。

探測時**必須用正確的 HTTP method** —— kernel 是用 `(method, target)` 一起比對的，所以用 GET 去打一個只收 POST 的端點會落到 404，看起來像端點不存在。

**2. 契約** — 對 `spec.py` 涵蓋的端點跑 L2 的檢查，並把失敗歸屬到依賴它的元件。

### `--check-drift`：防止手抄表腐化

`components.py` 的 `KERNEL_ENDPOINTS`（41 筆）是從 `HttpSession.cpp` 的 if/else 鏈**人工轉錄**的。新增端點卻忘了更新這張表時，L3 反而會把新端點報成「不在 dispatch table」。

```bash
./l3_component_check.py --check-drift
```

直接讀 `HttpSession.cpp` 原始碼比對，三種漂移都會抓到：漏列、方法寫錯（會導致探測用錯 method 而誤判成 404）、多列了已移除的端點。`--map` 也會在表過期時先印警告。

### 5xx 不算「端點存在」

存在性探測原本只要不是 404 就算通過 — 於是一個「POST 空 body 就 500」的端點在 L3 眼中是健康的。現在 5xx 會被判定為問題：路由存在，但它對最小請求就丟例外，consumer 收到的還是 5xx。

### 已知缺口 vs 新缺口

跟其他 allowlist 一樣的原則：已知缺口登記在 `components.py` 的 `KNOWN_MISSING_ENDPOINTS`（附理由），這樣**新出現的**缺失端點才會失敗，而不是被淹沒在已經容忍的那些裡面。

- 已知缺口 → 黃色 `KNOWN GAPS`／`DEGRADED`，exit 0
- 未登記的缺口 → 紅色 `UNACKNOWLEDGED`，exit 1

### 為什麼這張地圖有用

```
 * get_graph_data          6  (全部 6 個會讀資料的元件)
 * get_detected_flow_data  5
```

`get_graph_data` 壞掉等於全系統壞掉。這兩個剛好都依賴 sFlow telemetry，也就是 P4 模式下最脆弱的部分 —— 所以測試重心應該壓在這裡。

---

## compare_baseline.py

P4 開發最省時間的技巧：**OVS 那條路是已知正常的**，所以直接拿它的行為當規格，不用自己想「P4 應該長什麼樣」。

```bash
# 在健康的 OVS 環境擷取一次
./run_contract_test.py --topology <ovs 拓撲> --with-traffic --save-json baseline/ovs

# P4 用同樣方式擷取，然後比對
./run_contract_test.py --topology <p4 拓撲> --with-traffic --save-json result/p4
./compare_baseline.py baseline/ovs result/p4
```

### 為什麼不能直接做 JSON diff

兩邊的拓撲本來就不同（128 host vs 4 host），而且速率／計數器／時間戳每秒都在變。所以只比對「不管哪種資料平面都應該一樣」的兩件事：

**1. 形狀（shape）** — 遞迴的「欄位路徑 → 型別」集合。抓得到欄位消失、型別改變，以及最關鍵的：**一邊有資料另一邊是空的**，這正是 P4 各種 stub 的表現形式。

list 的索引會收斂成 `[]`，所以 4 host 和 128 host 產生相同的簽名。

**2. 行為事實（facts）** — 每個端點的布林判斷：switch 是不是全部 up？flow 的 path 有沒有填？速率是不是非零？表格是不是非空？這些答案就算數值不同也必須一致。

### 空 list 的處理

早期版本會在 P4 回傳 `[]` 時，把 OVS 元素的每一個欄位都報一次「欄位消失」—— 20 行雜訊，而真正的發現只有一件事。現在會收斂成單一結論：

```
[empty] list is empty in P4 but populated in OVS: <root list>
```

### allowlist

`baseline_diff_allowlist.txt`，格式跟 log allowlist 一樣（`endpoint | regex | 理由`）。

差異只有三種歸類：
1. **允許的 P4 限制** → 寫進 allowlist，附上「哪個 Phase 會移除它」
2. **數值容忍範圍內** → 工具自動處理（含 `_bps`／`_rate`／`_count` 等欄位只比型別）
3. **其他** → **就是 bug**

沒有第四類。這樣每個「P4 做不到的事」都會被寫下來，而不是靜靜地壞掉。

檔案末尾用註解列出了**不可以**加進 allowlist 的例子（例如 `all_switches_enabled`），因為那正是我們要抓的 Phase 6 bug，放行等於自廢武功。

工具會報告「登記了但這次沒用到」的項目 —— 那通常代表對應的 Phase 已經完成，該把那行刪掉了。

---

## 建議節奏

| 時機 | 執行 |
|---|---|
| 改完程式碼 | `--self-test`（秒級，不需要 kernel） |
| 每個 phase 結束 | 唯讀檢查 + `check_logs.py` |
| 產生流量後 | 加 `--with-traffic` |
| 要驗證寫入路徑 | 加 `--allow-mutations` |
| 準備 demo 前 | OVS 和 P4 各跑一次，用 `--save-json` 存下來比對 |

---

## 檔案

| 檔案 | 用途 |
|---|---|
| `run_contract_test.py` | L2 主程式（CLI、HTTP、報表） |
| `spec.py` | 端點定義與語意不變量 |
| `schema.py` | 極簡 schema 驗證器（零依賴） |
| `selftest_fixtures.py` | `doc/2026-01-02_ndt_api.md` 的範例，供 self-test 使用 |
| `components.py` | 各元件的端點依賴表 + kernel 的 dispatch table + 已知缺口 |
| `l3_component_check.py` | L3 元件契約檢查 |
| `compare_baseline.py` | L4 OVS/P4 差異比對 |
| `baseline_diff_allowlist.txt` | 可接受的 OVS/P4 差異清單 |
| `check_logs.py` | log 檢查器 |
| `warning_allowlist.txt` | 可接受的 warning 清單 |

### allowlist 的欄位分隔符

三個 allowlist 檔都用 **前後有空白的 pipe**（`" | "`）分隔欄位，不是裸的 `|`。這樣 regex 的 alternation 才能用 —— 寫成 `(int|float)`（pipe 兩側不加空白）就不會被誤判成欄位分隔。

### 要新增一個端點檢查

編輯 `spec.py` 的 `ENDPOINTS`，加一筆 dict：`name`、`method`、`path`、`category`（`READ`／`MUTATE`／`ERRORPATH`）、`schema`，需要的話再加 `invariants`。

如果新增了 schema，順手在 `selftest_fixtures.py` 加一筆範例，這樣 self-test 才守得住它。

---

## 已知限制

涵蓋率：**41 個註冊端點中的 30 個**有 contract（用下面的指令可隨時重算）。剩下 11 個裡，10 個沒有任何 consumer，唯一有 consumer 的是刻意排除的 `intent_translator/text`。

- **`--with-traffic` 的不變量假設流量正在跑。** 用在流量剛停的系統上會誤報。
- **`intent_translator/text` 刻意沒有 contract** — 需要 OpenAI token、每次呼叫要花錢、回應由模型決定，contract 會既不穩定又昂貴。Web-GUI 對它的依賴只靠 L3 的存在性檢查。這是決定，不是疏漏。
- **模擬相關端點只驗錯誤路徑。** `received_a_simulation_case` / `simulation_completed` 的成功路徑需要 Simulation-Platform-Manager 在跑，會讓檢查不穩定；但它們的輸入驗證（畸形 JSON 不能回 500）是可以驗的，也已經在驗。
- **group / meter 端點沒有 contract**（六個，無 consumer）。值得注意的是它們在 P4 模式下會**無條件走 OVS strategy** — `FlowRoutingManager` 的 group/meter 方法直接用 `m_ovsStrategy`，完全不看 dpid，所以對 bmv2 下的 group/meter 規則會被送到 Ryu。這是 kernel 的缺陷（P4 計畫 Phase 3 會修），現在沒有任何測試會抓到。
- **不變量的嚴格度有上限。** `inv_graph_matches_topology` 只比對 node/edge **數量**與 dpid 集合，不驗 edge 的接線是否正確（數量對但接錯不會被抓）。`inv_flow_paths_non_empty` 只驗 path 非空，不驗它是否連通、是否與 edge 一致。`inv_topk_bounded` 只驗數量 ≤ k，不驗真的是前 k 大。
- **HTTP 協定層沒驗**：CORS / `OPTIONS`（Web-GUI 直接依賴）、keep-alive、request body 大小上限、`k` 參數的邊界值。
- **併發沒驗**。kernel 的 HTTP server 是**單執行緒**（`main.cpp` 的 `net::io_context ioc{1}`），任何慢的 handler（SNMP、SSH、對 Ryu 的同步 curl）會阻塞所有其他請求。而 L2/L3 是序列發請求的，永遠碰不到這個情境。
- **sFlow UDP 輸入面完全沒被碰過**。kernel 有兩個外部輸入面（`/ndt/*` HTTP 和 :6343 sFlow UDP），這裡只涵蓋前者。
- **行程健康度（RSS / thread 數 / exit code）沒有工具。** 崩潰訊息現在會被 `check_logs.py` 抓到，但記憶體洩漏與 thread 洩漏不會。

### 重算涵蓋率

```bash
python3 -c "
import sys; sys.path.insert(0,'.')
import spec, components
covered = {e['path'].removeprefix('/ndt/') for e in spec.ENDPOINTS}
kernel = set(components.KERNEL_ENDPOINTS)
print('registered:', len(kernel), 'covered:', len(covered & kernel))
for e in sorted(kernel - covered):
    print('  UNCOVERED', e, components.blast_radius(e) or '-')"
```
