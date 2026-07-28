# NDTwin 整體測試 Workflow

目的：把「打開所有元件、看一下有沒有 error」變成**機器可以判斷 pass/fail 的檢查**。

---

## 為什麼要這樣設計

先看清楚一件事：**每個 tool / app 跟 kernel 之間唯一的溝通方式，就是 `/ndt/*` HTTP API。**
沒有共享記憶體、沒有直接讀檔、沒有其他偷偷的管道。

所以：
- kernel 的 API 只要形狀變了（少一個欄位、型別變了、回空陣列），**所有下游元件會同時壞掉**，但每個元件壞的樣子都不一樣，很難從單一元件的畫面看出來。
- 反過來，如果我們能在一個地方把 API 的「契約」驗過，就等於一次驗證了所有元件的地基。

這就是下面 L2 那一層存在的理由，也是你目前最缺的一塊。

### 各元件實際依賴的 API（實測掃出來的）

| 元件 | 語言/技術 | 依賴的 `/ndt/*` endpoint | 會寫入嗎 |
|---|---|---|---|
| **Energy-Saving-App** | C++ | `get_graph_data`, `get_detected_flow_data`, `get_switch_openflow_table_entries`, `get_average_link_usage`, `install_flow_entry`, `modify_flow_entry`, `delete_flow_entry`, `install_flow_entries_modify_..._and_delete_flow_entries`, `set_switches_power_state`, `acquire_lock`, `release_lock`, `app_register`, `received_a_simulation_case`, `disable_switch` | ✅ 會改網路 |
| **Traffic-Engineering-App** | Python | `get_graph_data`, `get_detected_flow_data`, `install_flow_entry`, `acquire_lock`, `release_lock` | ✅ 會改網路 |
| **Web-GUI** | React + Node + Postgres (Docker) | `get_graph_data`, `get_detected_flow_data`, `get_detected_top_k_flow_data`, `get_switch_openflow_table_entries`, `get_cpu_utilization`, `get_memory_utilization`, `get_temperature`, `get_nickname`, `modify_nickname`, `modify_device_name`, `install_flow_entries_..._and_delete_flow_entries`, `intent_translator` | ✅ 會改網路 |
| **Network-Traffic-Visualizer** | JavaFX (JDK 21) | `get_graph_data`, `get_detected_flow_data`, `get_detected_top_k_flow_data`, `get_cpu_utilization`, `get_memory_utilization` | ❌ 只讀 |
| **Network-State-Recorder** | Python | `get_graph_data`, `get_detected_flow_data` | ❌ 只讀 |
| **Network-Traffic-Generator** | Python | `get_graph_data`, `get_path_switch_count` | ❌ 只讀（但會產生真實流量） |
| **Simulation-Platform-Manager** | C++ | `app_register`, `received_a_simulation_case`, `simulation_completed` | ❌ 只讀 |

**重點觀察：**
- `get_graph_data` 被 **7 個元件**全部使用 → 它壞掉等於全系統壞掉，是最高優先的檢查對象。
- `get_detected_flow_data` 被 5 個元件使用 → 第二優先。這兩個剛好都是 P4 模式下最可能出問題的（因為依賴 sFlow telemetry）。
- Energy-Saving-App 和 Web-GUI 依賴面最廣（12-14 個），是最好的「整合測試探針」。

### 啟動順序（有依賴關係，順序錯了測不出東西）

```
1. 控制層     Ryu (OVS 模式)  或  P4 proxy agent (P4 模式)
2. 資料層     Mininet 拓撲 (testbed_topo.py / p4_testbed_topo.py)
3. Kernel     ndtwin_kernel                        ← 等它把拓撲載入完成再往下
4. 唯讀工具   Visualizer / NSR / Web-GUI
5. 產流量     NTG
6. 應用程式   Energy-Saving-App / Traffic-Engineering-App  ← 最後才開，它們會改網路
```

第 3 步到第 4 步之間**必須等**。之前很多「看起來壞掉」其實只是還沒收斂。

---

## 五層測試架構

| 層 | 測什麼 | 何時跑 | 需時 | 需要 Mininet？ |
|---|---|---|---|---|
| **L0** | 每個元件建置得起來 | 每次 commit | ~2 分 | ❌ |
| **L1** | Kernel 單元測試 | 每次 commit | 秒級 | ❌ |
| **L2** | **Kernel API 契約** | 每個 phase 結束 | ~1 分 | ✅ |
| **L3** | 各元件對自己用到的 API 的契約 | 換元件/改 API 時 | ~5 分 | ✅ |
| **L4** | 端到端場景 + **OVS/P4 差異比對** | 每個 phase 結束 | ~20 分 | ✅ |

---

## L0：建置檢查

每個元件都能編譯/啟動起來。不需要開 Mininet，純檢查沒有把別人的 build 弄壞。

| 元件 | 指令 | 判定 |
|---|---|---|
| NDTwin-Kernel | `cmake --build build -j$(nproc)` | exit 0，**0 個 warning**（本專案開了 `-Werror`） |
| Energy-Saving-App | `make -C /home/adam/Energy-Saving-App` | exit 0 |
| Simulation-Platform-Manager | `make -C /home/adam/Simulation-Platform-Manager` | exit 0 |
| Network-Traffic-Visualizer | `./mvnw -q compile` | exit 0 |
| Web-GUI | `pnpm install --frozen-lockfile && pnpm build` | exit 0 |
| NTG / NSR / TE-App | `python -m py_compile <主程式>` | exit 0 |
| P4 pipeline | `p4c-bm2-ss --arch v1model ndtwin_switch.p4` | exit 0 |

---

## L1：Kernel 單元測試

```bash
cd build && ctest --output-on-failure
./bin/test_routing_strategy          # ← 一定要「另外」直接跑一次
```

**為什麼要跑兩次**：`ctest` 會把每個測試放在獨立的 process 執行，所以整個 test suite 層級的失敗（例如 fixture 初始化爆掉）它看不到。我們就是這樣才發現 P4 的 2 個測試其實從來沒執行過，而 `ctest` 一路顯示綠燈。

判定：`ctest` 全過 **且** 直接執行 exit code = 0 **且**「實際執行數 = 應有測試數」（不是 SKIPPED）。

---

## L2：Kernel API 契約測試 ← 最重要，你現在缺的

一支腳本，把 40 個 `/ndt/*` endpoint 全部打一遍。

**關鍵：不是檢查 HTTP 200，而是檢查三件事：**

**(1) 結構** — 回應是合法 JSON，必要欄位存在，型別正確
```
get_graph_data  →  必須有 nodes[] 和 edges[]
                   每個 node 有 dpid(int) / device_name(str) / is_up(bool) / vertex_type(int)
                   每個 edge 有 src / dst / left_link_bandwidth_bps(int)
```

**(2) 語意不變量** — 這是把「看一眼」變成「可判定」的核心
```
✓ switch 數量 == 拓撲檔裡的數量（OVS=10, P4=10）
✓ 每一台 switch 的 is_up == true      ← P4 模式最容易在這裡掛
✓ edge 數量 == 拓撲檔裡的數量
✓ 沒有 dpid 重複
✓ get_average_link_usage 回傳 0~100 之間
✓ 有流量時 get_detected_flow_data 的 flows 數量 > 0
✓ 有流量時每個 flow 的 path 陣列非空       ← P4 模式最容易在這裡掛
✓ get_switch_openflow_table_entries 每台 switch 的表非空
```

**(3) 錯誤路徑** — 給壞的輸入，要回合理的錯誤碼而不是 500 或假裝成功
```
✓ install_flow_entry 給不存在的 dpid   → 4xx（不是 200）
✓ get_path_switch_count 給亂 IP        → 4xx 或空結果（不是 crash）
✓ acquire_lock 連續拿兩次              → 第二次回 423
✓ release_lock 用過期的 lock           → 412
```

### 順手抓到的現有破口

做這份對照表時發現：**Energy-Saving-App 會 POST 到 `/ndt/disable_switch`，但 kernel 根本沒有實作這個 endpoint**（`src/app/http.cpp:269` 打過去，kernel 的 40 個註冊 endpoint 裡沒有它）。這支呼叫應該一直在拿 404，而 app 把錯誤吃掉了，所以從畫面上看不出來。

另外有 4 個 endpoint 有實作但 `doc/ndt_api.md` 沒寫：`intent_translator`（Web-GUI 在用）、`get_openflow_capacity`、`historical_logging`、`inform_all_destination_paths`。

**這正是 L2 存在的價值**：這種「呼叫了不存在的 API 但沒人發現」的問題，眼睛看 log 幾乎不可能抓到，但契約測試第一次跑就會噴出來。

---

## L3：各元件契約子集

用上面那張依賴表，每個元件只驗**它自己真的會用到的** endpoint。

好處：kernel 改了某個 endpoint 之後，能立刻知道「這會影響 Web-GUI 和 Visualizer，但不影響 NTG」，而不用把所有元件都開起來試。

做法（不用真的啟動 GUI）：
```
對每個元件：
  1. 取它的 endpoint 清單
  2. 逐個呼叫，用該元件實際需要的欄位去驗證
     例：Visualizer 需要 get_graph_data 裡有座標可對應的 node id
         Web-GUI 需要 get_temperature 回傳 {ip: int} 的扁平 map
  3. 任何一個欄位缺失 → 標記「元件 X 會壞」
```

---

## L4：端到端場景 + OVS/P4 差異比對

### 4-A：固定場景腳本

每個 phase 結束跑同一套動作，結果要可重現：

| # | 動作 | 通過條件 |
|---|---|---|
| 1 | 啟動全套（依上面順序） | kernel log 中 ERROR 數 = 0 |
| 2 | 等拓撲收斂 30s，抓 `get_graph_data` | 10 台 switch 全部 `is_up: true`，edge 數正確 |
| 3 | NTG 產生 h1→h4 的流量 | `get_detected_flow_data` 出現該 flow，`path` 非空，速率 > 0 |
| 4 | 抓 `get_average_link_usage` | > 0 |
| 5 | 裝一條 flow rule（指定 5-tuple + priority） | `get_switch_openflow_table_entries` 看得到，且流量真的改走新 port |
| 6 | 關掉一台 switch (`set_switches_power_state`) | 那台變 down 且**維持** down；其餘 9 台仍能轉送 |
| 7 | 打開 Visualizer / Web-GUI | 畫面 node 數 = API 回傳的 node 數（用數字比，不是「看起來有東西」） |
| 8 | NSR 錄 60 秒 | 產生的 zip 內 JSON 筆數 ≈ 60/取樣間隔，且能被 Visualizer playback 載入 |
| 9 | 跑 Energy-Saving-App 一輪 | 有成功 `acquire_lock`、下規則、`release_lock`；kernel 無 ERROR |
| 10 | 殺掉 Ryu/proxy 再下規則 | kernel 要**回報失敗**（不是回 200） |

### 4-B：OVS / P4 差異比對 ← P4 開發最有效的技巧

你有一個巨大優勢：**OVS 那條路是已知正常的**。所以：

```
1. 在 OVS 模式跑完 4-A，把每個 API 的回應存成 baseline/ovs/*.json
2. 在 P4 模式跑完同一套 4-A，存成 result/p4/*.json
3. 機器比對兩者差異
```

差異分三類處理：

| 類別 | 例子 | 處理 |
|---|---|---|
| **允許的 P4 限制** | group/meter 回傳 unsupported、`temperature` 是假值 | 寫進 allowlist，明確記錄「這裡本來就不同」 |
| **數值容忍範圍** | 流量速率差 ±10%（取樣本來就有誤差） | 設容忍度比較，不比絕對值 |
| **其他任何差異** | switch 少一台、path 空的、欄位型別不同 | **就是 bug** |

這個做法的好處：不用自己想「P4 模式應該長什麼樣」，直接拿 OVS 的行為當規格。而且 allowlist 會強迫你把每個「P4 做不到的事」明確寫下來，而不是含糊地讓它靜靜壞掉。

---

## 判定標準：取代「看有沒有 error」

### log 判定
```
✓ ERROR 數量 == 0
✓ WARN 只允許出現在 allowlist（例如「P4 power on 是 stub」）
   → 出現 allowlist 以外的 WARN = 失敗
✓ 不能有 "Unsupported SFlow Version" / "Cannot open topology file" / "No matching node in JSON"
```
把 allowlist 明確寫成檔案的好處：新出現的 warning 會自動變成失敗，而不是被淹沒在 100 行既有 warning 裡。

### 行程健康度
```
✓ 全程沒有 crash（特別注意 SIGFPE / std::terminate，我們剛修掉兩個）
✓ 記憶體用量在 10 分鐘內穩定（抓 RSS，成長 < 10% → 沒有洩漏）
✓ thread 數量穩定（不會一直長）
✓ 關閉時 exit code == 0（不是被信號殺掉）
```

### 為什麼要量記憶體和 thread
我們剛修的兩個 bug 就是這類：`m_ifIndexToOfportMap` 會無上限成長（記憶體）、`m_flushEdgeFlowLoop` 沒 join 會讓關閉時 `std::terminate`（exit code 非 0）。這兩個從 GUI 完全看不出來，但用上面兩個指標一測就現形。

---

## 建議的實際節奏

| 時機 | 跑哪幾層 | 需時 |
|---|---|---|
| 每次改完程式碼 | L0 + L1 | ~2 分 |
| 每個 phase 結束 | L0 + L1 + L2 + L4 | ~30 分 |
| 動到 kernel API 形狀時 | 再加 L3 | +5 分 |
| 準備 demo / 交付前 | 全部，OVS 和 P4 各跑一次 | ~1.5 時 |

---

## 實作位置

全部已實作，零外部依賴（只需要 `python3` 和 `bash`），每支都是**成功才 exit 0**。

| 層 | 工具 | 說明 |
|---|---|---|
| L0 | [tools/test_workflow/l0_build_check.sh](../tools/test_workflow/l0_build_check.sh) | 10 個建置目標 |
| L1 | [tools/test_workflow/l1_unit_tests.sh](../tools/test_workflow/l1_unit_tests.sh) | ctest **加上**直接執行，並檢查 SKIPPED |
| L2 | [tools/contract_test/run_contract_test.py](../tools/contract_test/run_contract_test.py) | 結構 + 不變量 + 錯誤路徑 |
| L3 | [tools/contract_test/l3_component_check.py](../tools/contract_test/l3_component_check.py) | 各元件依賴檢查、blast radius |
| L4 | [tools/contract_test/compare_baseline.py](../tools/contract_test/compare_baseline.py) | OVS baseline 差異比對 |
| log | [tools/contract_test/check_logs.py](../tools/contract_test/check_logs.py) | allowlist 判定 |
| 編排 | [tools/test_workflow/stack.sh](../tools/test_workflow/stack.sh) | 依序啟動 + 等收斂 |
| 驅動 | [tools/test_workflow/run_layers.sh](../tools/test_workflow/run_layers.sh) | 把各層組合起來 |

三份 allowlist：`warning_allowlist.txt`（可接受的 log warning）、`baseline_diff_allowlist.txt`（可接受的 OVS/P4 差異）、`components.py` 的 `KNOWN_MISSING_ENDPOINTS`（已知缺失的端點）。

使用說明：[tools/test_workflow/README.md](../tools/test_workflow/README.md)、[tools/contract_test/README.md](../tools/contract_test/README.md)。

### 常用指令

```bash
cd tools/test_workflow
./run_layers.sh selftest              # 完全離線，秒級
./run_layers.sh quick                 # L0 + L1，約 2 分鐘
./stack.sh up p4 && ./stack.sh wait   # 依序啟動並等收斂
./run_layers.sh api p4 --traffic      # L2 + L3 + log 檢查
./stack.sh down
```

### 實測驗證過的事

這些工具本身也經過反向驗證（不只驗「會通過」，也驗「該失敗時真的會失敗」）：

- **L1 抓到了 ctest 的謊言**：把 `Logger::init` 的修正暫時移除後，`ctest` 回報 `100% tests passed, 0 tests failed out of 12`，而直接執行是 `FAIL, ran=12 passed=10 skipped=2`。
- **L2 的 47 個 self-test 檢查**用 `doc/ndt_api.md` 的實際範例驗證 schema，並驗證每個不變量的兩個方向（好資料要安靜、壞資料要噴錯）。
- **L3 離線就證實了 `/ndt/disable_switch` 的缺口**。
- **L4 對只有已知 P4 限制的情況回 PASS，對真 bug（`all_switches_enabled` 不一致）回 FAIL**。
- **log 檢查在 INFO 等級抓到 `Unsupported SFlow Version`**（FORBID 規則）。

---

## 這些工具「沒有」涵蓋什麼

上面說的是這套工具能證明什麼。反過來的那一面——綠燈不代表什麼、哪些輸入面完全沒被
碰過——整理在 [test_coverage_gaps.md](test_coverage_gaps.md)。

那份文件原本的 §1 列出「工具本身會誤判」的問題，**已於 2026-07-28 全部修掉**
（鎖型別、log 污染、`--save-json` 重複請求、L3 把 5xx 當存在、手抄表漂移）。
剩下的是真正的涵蓋缺口，最大的兩塊是 **sFlow UDP 輸入面**（kernel 的第二個外部輸入面，
五層都沒碰過）和**行程健康度**（RSS／thread 洩漏；崩潰現在會被 `check_logs.py` 抓到）。
