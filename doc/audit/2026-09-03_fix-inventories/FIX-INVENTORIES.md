# FIX-INVENTORIES：兩張手抄表跟上今天的 merge

分支 `fix/inventories-follow-the-merges`，base `65d4a32f`。沒有 C++ 改動、沒有 build、沒有 lab。

兩個測試在 trunk 上是紅的。兩個都是**靜態讀 C++ 原始碼的清單測試**：merge 改了原始碼，
但被 merge 的分支只跑了 C++ 測試、沒跑 `tests/python/`。**兩個都不是測試的 bug。**

---

## 紅（改動前，在 base `65d4a32f` 實測）

```
$ python3 tests/python/test_l3_dispatch_drift.py
FAIL: test_no_drift_against_the_hand_transcribed_table
AssertionError: Lists differ: ['kernel registers GET /ndt/get_sflow_stats but KERNEL_ENDPOINTS omits it'] != []
Ran 12 tests in 0.646s
FAILED (failures=1)

$ python3 tests/python/test_shell_command_construction.py
FAIL: test_no_shell_site_is_reached_by_a_request_controlled_string
FAIL: test_the_site_inventory_matches_the_classification
AssertionError: ... 'src/ndt_core/collection/TopologyAndFlowMonitor.cpp: return
  utils::execCommand(buildTopologyFetchCommand(url));  (classified 1, found 0)'
Ran 7 tests in 2.436s
FAILED (failures=2)
```

完整輸出：session scratchpad 的 `evidence/red_dispatch_drift.txt`、`evidence/red_shell_sites.txt`。

---

## 題目一：dispatch drift

**起因** merge `ea139d1c`（`fix/telemetry-health-visible`，findings #53/#56）在
`HttpSession.cpp:306` 註冊了 `GET /ndt/get_sflow_stats`（`utils::pathIs` 那種拼法），
但沒動 `tools/contract_test/components.py` 的手抄表 `KERNEL_ENDPOINTS`。

**改動** 在 `get_average_link_usage` 後面補一列 `"get_sflow_stats": "GET"`——
位置照 dispatch chain 的順序，跟原始碼一致。

**沒有加進任何 Component 的 endpoint 清單。** 那些清單記的是「哪個 sibling repo 真的在呼叫什麼」，
而現在沒有任何東西呼叫它。這跟 `get_flow_dispatch_status` 已經寫在表裡的理由是同一條。

### spec.py 這一列 — 🔴 刻意沒做，理由在此

`tools/contract_test/spec.py` 的 `ENDPOINTS`（contract tester 的逐端點期望表）**我沒有加**。三個理由：

1. **沒有任何測試要求它。** `tests/python/` 裡沒有東西拿 `KERNEL_ENDPOINTS` 去比對 `spec.ENDPOINTS`。
   照 README 自己的重算指令：**43 registered / 33 covered**，`get_sflow_stats` 加入的是一個
   **已經存在的**未涵蓋集合（另外九個是 group/meter 六個、`link_failure_detected`、
   `link_recovery_detected`、`inform_all_destination_paths`），README 也已經把 group/meter 那六個
   寫成「這是決定，不是疏漏」。

2. **`tests/python/test_sflow_stats_endpoint.py` 推不出這一列。** 那個測試測的是
   **p4_proxy 的 FastAPI `/sflow/stats`**（`proxy_agent/api_routes.py`），跟 kernel 的
   `/ndt/get_sflow_stats` 是**兩個不同的面**，回應形狀也完全不同
   （`datagrams_sent`／`samples_sent`／`send_errors`／`batch_size`／`t`）。拿它來當 kernel 這一列的
   依據會是憑空捏造。

3. **handler 有兩個分支，我判不出 live 會走哪個。** `HttpSession.cpp:2221` 的
   `handleGetSflowStats`：有 collector 回 200 `{"status":"success","telemetry_health":{…}}`，
   **沒有 collector 回 503** `{"status":"error","message":"no sFlow collector in this deployment"}`。
   哪個 deployment 有 collector 要 live 跑才知道，我沒有 lab。寫 `expect_status=[200]` 會讓沒有
   collector 的部署整套 contract 變紅；寫成接受 503 則是替別人發明一個沒人裁決過的容忍度。

**留給後人**：`telemetry_health` 的形狀是靜態就讀得出來的，在
`FlowLinkUsageCollector::ingestHealthJson()`（`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1811`），
12 個鍵：`status`、`samples_in_window`、`offered_in_window`、`dropped_in_window`、
`socket_drops_in_window`、`app_drops_in_window`、`loss_fraction`、`window_seconds`、
`rx_total`、`addressed_total`、`sock_ovfl_total`、`app_drop_total`。
**要補這一列的人只差「live 走哪個分支」這一個答案，不必重讀一次原始碼。**

`check_logs.py` 不需要改：整個 `tools/contract_test/` 原本就沒有任何 `sflow` 字串，
它是逐 log 行檢查、不是逐端點表；新 handler 只多一行 INFO。

---

## 題目二：shell site — **先重讀 provenance，才動清單**

**起因** merge `d00fa57c`（`fix/topology-round-reads-status`）把呼叫包進 `classifyEndpointReply`，
並在指令裡加了 `--write-out`，所以 `SHELL_SITES` 的 key（舊行文字）classified 1 / found 0。

這一題的重點**不是**把 key 換成新行文字。**照新行文字改清單，跟把一個命令注入標成 CONFIG，
是同一個動作**——所以 provenance 是重新推導的，不是沿用的。

### 實際讀到的行（`src/ndt_core/collection/TopologyAndFlowMonitor.cpp`）

```
:985-987  const EndpointReply switchesReply = fetchTopologyEndpoint(m_ryuUrl[0]);   // hosts[1] / links[2]
:724      return classifyEndpointReply(utils::execCommand(buildTopologyFetchCommand(url)));
:161-165  setTopologyApiUrls(base) { m_ryuUrl[0] = base + "/switches"; [1] "/hosts"; [2] "/links"; }
:157      建構子     setTopologyApiUrls(ryuTopologyBaseUrl());
:143      ryuTopologyBaseUrl() { return "http://" + AppConfig::RYU_IP_AND_PORT + "/v1.0/topology"; }
:198-199  configureTopologyApiUrls() { base = "http://" + AppConfig::P4_PROXY_IP_AND_PORT + "/v1.0/topology"; setTopologyApiUrls(base); }
```

- `m_ryuUrl` 的**唯一**寫入點是 `setTopologyApiUrls`（`grep -rn m_ryuUrl src/ include/` 全部 11 處已逐一看過）。
- `setTopologyApiUrls` 的呼叫者只有三個：上面兩個 production 路徑，加上
  `tests/test_TopologyUrlAndPathJson.cpp:110`（單元測試）。
- `AppConfig::RYU_IP_AND_PORT`／`P4_PROXY_IP_AND_PORT` 是 build-time 的
  `static const std::string`（`setting/AppConfig.hpp.example:8,10`）。
- **沒有任何 HTTP handler 碰得到它們。**
- 新加的 `--write-out` 只內插 `kHttpStatusSentinel`，是
  `static constexpr const char*` 字面值（`TopologyAndFlowMonitor.hpp:559`）；
  兩個 timeout 是 `static constexpr int`（`:652`、`:654`）。
- `classifyEndpointReply` 包的是 `execCommand` 的**回傳值**，沒有東西被送進 shell。

### 裁決

`git diff d00fa57c^1 d00fa57c -- src/ndt_core/collection/TopologyAndFlowMonitor.cpp` 顯示
**provenance 完全沒變**：那個 merge 改的是回傳型別與分類邏輯，`url` 的來源一個字都沒動。

⇒ **provenance 未變、非 request-controlled**，所以走「更新行文字」那一路：
verdict 維持 `CONFIG`、count 維持 `1`，note 補上完整的呼叫鏈，讓下一個讀的人**重查而不是重信**。

**這不是命令注入。** 如果 `url` 變成從 HTTP request 到得了，正確做法是留紅、停手、報缺陷——不是改清單。

---

## 綠（改動後）

| 檢查 | 結果 |
|---|---|
| `test_l3_dispatch_drift.py` | rc=0，Ran 12，**OK** |
| `test_shell_command_construction.py` | rc=0，Ran 7，**OK** |
| `test_contract_spec.py`（規定要維持） | rc=0，**Ran 126，OK** |
| `check_gate_anchors.py <branch> --gates mutate_l3_dispatch_drift.sh` | rc=0，**ok(5)**，5 個 anchor 都還在 |

### mutation probe（新那一列真的有被比對，不是擺著好看）

用 `NDT_CONTRACT_DIR` 指到 `tools/contract_test` 的**複本**（不寫共用 worktree）：

| 突變 | 結果 |
|---|---|
| `"get_sflow_stats"` 的 verb 改成 `POST` | **FAIL**（verb 不符被抓到） |
| 整列刪掉 | **FAIL** — `kernel registers GET /ndt/get_sflow_stats but KERNEL_ENDPOINTS omits it` |

題目二的 mutation 就是改動前那次紅本身：舊 key 對上新原始碼 = `classified 1, found 0`。

### 全量：`tests/python` 28 個模組 + `p4_proxy/tests` 25 個模組，全綠

全部 rc=0、全部 OK。逐模組表在 session scratchpad 的
`evidence/table_tests_python.txt`、`evidence/table_p4proxy.txt`。

**skip 是既有的，這是量出來的不是假設的**：在 base `65d4a32f` 另開 detached worktree 跑過同樣模組，
skip 數字一模一樣 —— `test_check_gate_anchors`(2)、`test_find_host_by_ip`(5)、
`test_topology_read_timeouts`(5)、`test_topology_worker_coalescing`(7)、`test_walk_instrumentation`(10)、
`p4_proxy/test_p4_client`(1)、`p4_proxy/test_sflow_emitter`(2)。
（工單預期的 skip 清單少列了後面三個，那三個確認為既有。）

---

## 沒做的事

- **`spec.py` 的 `get_sflow_stats` 一列** —— 理由與交接資料見上面「題目一」。
- **沒有 push。**
- **沒碰 C++。** 兩個都是靜態掃描器，改的是掃描器旁邊的手抄表，kernel 行為零改動。
- **沒有擴大範圍**：沒有重構、沒有改名、沒有順手修別的 finding。
- **沒有 live 驗證。** 這裡綠的意思是「原始碼文字與清單一致」，不是「kernel 行為正確」——
  這條界線是 `test_shell_command_construction.py` 自己的 docstring 就寫明的。

[Co-developed with claude code -- Adam]
