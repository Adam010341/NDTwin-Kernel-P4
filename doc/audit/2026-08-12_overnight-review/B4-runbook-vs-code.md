# B4 — `doc/2026-08-10_p4_manual_test_runbook.md` vs code @ `5d53cf0`

Base: `5d53cf0`（worktree 開場是 `8b61cdc Add sharding`，已 `git reset --hard 5d53cf0`；`tests/` 48 項、`doc/` 17 項確認）。
純讀，未執行任何 live 指令。

## TL;DR

核對完 runbook 全部 9 節 1030 行。**沒有 P0 級的「毀環境」雷；但有一個 P0 級的「會得到相反結論」雷。**
路徑／port／端點／方法／預期數值這一整層**零雷**——雷全部集中在「文件沒跟上今天的程式碼」。

### 🔴 P0 —— 跑之前就該改，否則會誤判

1. **§6h 的步驟用 `ifconfig down`，判準卻是 `tc netem` 的判準。**
   步驟 L692 `sudo -n ifconfig s6-eth4 down`；判準 L855「ping 會短暫中斷再自己恢復（約 15 秒），**永遠不恢復代表 failover 沒生效**」。
   但文件自己在 L764-803 已經證明 `ifconfig down` 會讓整台 switch 停止轉發、ping **永遠不恢復**——那是方法的產物。
   兩者相距約 160 行、**步驟在前判準在後**，照順序跑的人必然得到「failover 壞了」的錯誤結論。
   → **把 §6h L683-695 的 `ifconfig` 換成 L810-816 已驗證的 `tc netem`（雙向）再跑。**（§6a L563 的 `ifconfig` 可以留，那一節只驗偵測，但要標明用途。）

2. **§6h 說「還沒修」的 `reroutable_down_endpoints()` 漏洞，已經修好了。**
   `topology_manager.py:451-455` 的 `and (dst, dst_port, src, src_port) not in down_links` 就是 runbook 列為待決定的第二個候選方向；`test_link_watchdog.py:816` 已鎖住 `{(5,4),(10,1)}`。
   → 別去修一個修好的東西。

3. **§6h L729-731 的「根因」整段過期。** `install_initial_routes()` 今天有 **3 個** production 呼叫點（`:941` 發現、`:813` readopt、**`:1312` 鏈路轉換**），不是「只有一個」；定義在 `:665` 不是 `:655`。停在那段讀的人會得到與文件後半相反的結論。

### 🟡 P1 —— 會浪費時間

4. **`sFlow ingest healthy` 那行，runbook 三處都在描述已被改掉的行為**（檔頭 L12、§5b L402、檔尾孤兒 L1025）。
   現在 INFO **只在 `rx > 0` 時發**（`FlowLinkUsageCollector.cpp:1836-1841`），`rx=0`／「啟動瞬間的值」已不可能。
   **且 idle 時完全沒有 sFlow datagram**（P4 emitter 只送 flow sample、無 counter sample；beacon 兩端都被排除在取樣外）→ **idle 期 grep 會是零行**，而且 kernel.log 會在約 60 秒後冒一條 WARN「no sFlow datagram has arrived in 60s」，**runbook 完全沒提**。§9 L968 的「rx 是 counter sample（週期性）」在 P4 模式不成立。
5. **runbook 自稱「Phase 7 還不存在，本文件不涵蓋它」（L5），但 Phase 7 已完成**（`2026-07-27_p4_bmv2_support_plan.md:480` ✅ 已完成）。跑完全綠**不代表** power management／readopt 路徑健康——今天的 3a312e3、eace67c 改的正是那一塊，runbook 一個字都沒測。
6. **§2 的測試檔案數是舊的**：p4_proxy「12 個檔案」→ 實際 **14**；kernel-side「2 個檔案」→ 實際 **4**。檔案數既然錯，426／312／101 這三個條數也不能照抄（以 B3 今晚實跑為準）。
7. **§6b「大約 11 秒後偵測到」不可能**：`LINK_BEACON_TIMEOUT_S = 15`（`topology_manager.py:155`），原始碼註解逐字寫「takes between LINK_BEACON_TIMEOUT_S and that plus one scan interval -- **15 to 20 s**」。應改成 15–20 秒（與 §6c、§6 L856 一致）。
8. **五處行號漂掉**（見第 3 批表）。其中 **§5g L499 `HttpSession.cpp:1734-1739` 最危險**——實際在 `:1811-1814`，而 `:1773` 另有一段**長得一模一樣**的 `if (e.dstDpid == dpid)`（屬於別的端點），照行號翻會翻到錯的函式。
9. **§9 缺一列新失敗模式**：32afeb9 之後，probe 回報 definite false 的 bmv2 會**整台從 `/v1.0/topology/switches` 消失**，症狀是 `switches` 本身 < 10，不再是 `enabled` < 10。
10. **檔尾 L1015-1026 有一份 §5b 的孤兒副本**（在「## 收尾」之後），與正文說法互相矛盾，建議直接刪。
11. （附加）**`stack.sh` 檔頭 `:9-11` 的依賴順序註解**把 OVS 順序寫成通例，與同檔 usage `:731-733` 和 P4 實作矛盾。

### ✅ 已核對通過，明早不必再查

- **路徑**：runbook 引用的 6 個檔全部存在；**3fc42ed 搬走的 5 個腳本 runbook 從沒引用過，零影響**。
- **Port**：kernel **8000**、proxy **8081**、Ryu **8080**（僅 OVS）——runbook 每一處都對，**沒有 8080/8000 混淆**。
- **9 個 HTTP 端點**全部在註冊處確認存在且方法一致；§4e「加 `?dpid=` 會 404 因為是 `==` 精確匹配」逐字正確；§5g「是 POST」正確。
- **預期值**：10 switch／4 host／**40 edges**／**12 paths**／**32 declared links**／**1/256 取樣**／flow **2 秒** TTL／TTL **59**／path_len **7** —— 全部對得上程式碼。
- **電力 33466–147622 mW**：我照 `syntheticPowerMilliwattsFor` 的公式算了 dpid 1–10，min/max **逐位元組吻合**，且是純函式所以必然跨輪詢不變。
- **`LINK_BEACON_TIMEOUT_S` 15s／15–20 秒中斷窗**：與原始碼註解逐字吻合。
- **「ping 有沒有停」判準句還在**（L677、L699、L855 三處）。
- **§6e 的 poll 間隔引用（只留符號名 `kWhileConverging`／`kOnceConverged`／`kConvergingFor`）是全文唯一沒腐爛的引用** —— 5d53cf0 改用符號名的做法有效，其餘幾處該照辦。
- `stack.sh` usage 區塊與實作完全一致。

---

## 第 1 批：路徑、port、HTTP 端點

### 路徑存在性（3fc42ed 搬檔的影響）

【觀察】`3fc42ed` 搬走的 5 個檔：`check_env.py`、`dump_table.py`、`test_modify.py`、`test_modify_error.py`、`p4_proxy/test_10_routes.py` → 全部進 `p4_proxy/reference/`。

【觀察】`grep -n -E "check_env|dump_table|test_modify|test_10_routes|reference/" doc/2026-08-10_p4_manual_test_runbook.md` → **零命中**。

**verdict: OK** —— runbook 從來沒引用過這 5 個腳本，搬檔對它沒有影響。

runbook 實際引用的路徑全部存在（`ls` 逐一確認）：

| runbook 位置 | 路徑 | verdict |
|---|---|---|
| §1 L74, §2 L95, §3b L176, 收尾 L1002 | `tools/test_workflow/stack.sh` | OK |
| §2 L98 | `tools/test_workflow/l1_unit_tests.sh` | OK |
| §2 L124 | `tools/test_workflow/l0_build_check.sh` | OK |
| §3a L151 | `p4_proxy/mininet/p4_testbed_topo.py` | OK |
| 檔頭 L15 | `doc/2026-07-29_environment_gotchas.md` | OK |
| 檔頭 L15、§0 L42、L1025 | `doc/2026-07-30_full_test_runbook.md` | OK |

### Port

以程式碼為準，三個 port 全部對得上 runbook：

| port | 程式碼出處（重新 grep 過） | runbook 寫什麼 | verdict |
|---|---|---|---|
| kernel **8000** | `include/ndt_core/event_handling/ControllerAndOtherEventHandler.hpp:37` `#define NDT_PORT 8000`；`tools/test_workflow/stack.sh:607` `wait_for_port 8000 "kernel API" 40 kernel` | §3b L199 `waiting for kernel API on :8000`、§4 L228「kernel 聽在 `localhost:8000`」、所有 `curl` 都打 8000 | **OK** |
| proxy **8081** | `p4_proxy/proxy_agent/main.py:303` `uvicorn.run(app, host="0.0.0.0", port=8081)`；`stack.sh:585` `wait_for_port 8081 "P4 proxy agent" 30 p4_proxy` | §3b L193 `:8081`、§4 L228「proxy 聽在 `localhost:8081`」、§4g/§4h/§6f/§6g 都打 8081 | **OK** |
| Ryu **8080** | `stack.sh:564` `wait_for_port 8080 "Ryu REST" 40 ryu`（只在 OVS 分支） | §3b L208 把 `:8080` 描述成「kernel 第一次誤問 Ryu port」的預期自癒失敗；§1 L81、§9 L984、收尾 L1011 把 8080 列進 port 掃描 | **OK** |

【觀察】orchestrator 開場實測 `stack.sh` 印 kernel API 在 `:8000`——與 runbook 一致，**runbook 這裡沒有 8080/8000 混淆**。記憶裡「多處寫 :8080」的疑慮在這份 runbook 上不成立。

【觀察】`test_10_routes.py` 今天從 8080 改 8081（3fc42ed commit message：「pointed at port 8080 since it was written while the agent has always bound 8081」）——那是 `p4_proxy/reference/` 底下的手跑腳本，runbook 沒引用，**不影響 runbook**。

### HTTP 端點（在註冊處核對，不是 grep 字串）

kernel 端 —— 全部在 `src/ndt_core/http/HttpSession.cpp` 的 dispatch chain：

| runbook 位置 | 端點 | runbook 說的方法 | 註冊處 | verdict |
|---|---|---|---|---|
| §4a/§4b/§6c/§6d/§7 | `/ndt/get_graph_data` | GET | `HttpSession.cpp:153` `verb::get && target == "/ndt/get_graph_data"` | OK |
| §4c | `/ndt/get_power_report` | GET | `:169` `verb::get && target ==` | OK |
| §4d/§5d | `/ndt/get_average_link_usage` | GET，不加 query/body | `:288` `verb::get && target.starts_with(...)` | OK |
| §4e/§5f | `/ndt/get_switch_openflow_table_entries` | GET，**加 `?dpid=` 會 404，因為是 `==` 精確匹配不是 `starts_with`** | `:165` `verb::get && target == "/ndt/get_switch_openflow_table_entries"` | **OK —— 「精確匹配」這個理由逐字正確** |
| §4f/§5c/§6h | `/ndt/get_detected_flow_data` | GET | `:157` `verb::get && target ==` | OK |
| §5g | `/ndt/get_num_of_flows_passing_a_switch` | **POST**，body `{"dpid": N}` | `:297-298` `verb::post && target.starts_with(...)` | **OK** |

proxy 端 —— 全部在 `p4_proxy/proxy_agent/api_routes.py`：

| runbook 位置 | 端點 | runbook 說的方法 | 註冊處 | verdict |
|---|---|---|---|---|
| §4g | `/p4/switch_state` | GET | `api_routes.py:197` `@router.get("/p4/switch_state")` | OK |
| §4h/§6f/§6g | `/ryu_server/all_destination_paths` | GET | `:76` `@router.get(...)` | OK |
| §6h L701, L719 | `/stats/flow/{dpid}`（`localhost:8081/stats/flow/6`） | GET | `:220` `@router.get("/stats/flow/{dpid}")` | OK |

【觀察】proxy 完整路由表（`grep -n "@router\.\(get\|post\)"`）：`/v1.0/topology/switches`、`/v1.0/topology/links`、`/v1.0/topology/hosts`、`/ryu_server/all_destination_paths`、`/stats/flowentry/add`、`/stats/flowentry/delete_strict`、`/stats/flowentry/modify`、`/p4/readopt/{dpid}`(POST)、`/p4/switch_state`、`/stats/flow/{dpid}`。runbook 用到的三個都在裡面。

**第 1 批小結：路徑、port、端點、方法——零雷。**

---

## 第 2 批：sFlow ingest 那一行 —— 🔴 三處都在描述已經被改掉的行為

這是目前最實質的一個發現。runbook 有三處講「`sFlow ingest healthy` 這行」，**三處都是舊行為**。

### 【觀察】程式碼現況（重新開檔讀，非憑記憶）

`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1836-1841`：

```cpp
const bool announceNow = rx > 0 && !announcedHealthy;
if (announceNow)
{
    announcedHealthy = true;
}
const auto level = announceNow ? spdlog::level::info : spdlog::level::trace;
```

同檔 `:1637-1641` 的註解把改動寫得很白：

> `"sFlow ingest healthy: rx=0" used to be printed on the first pass, one second after start,`
> `when rx is necessarily still zero ... Health is now claimed when it is observed, and its`
> `absence is reported rather than left silent.`

且 `:1855-1866` 新增一條 WARN：`announcedHealthy` 仍為 false 且超過 `kNoSampleGrace`（`:1645` = **60 秒**）時，印
`"no sFlow datagram has arrived in 60s. Every flow rate and link utilisation will read zero, which is indistinguishable from an idle network..."`。

實際的 log 呼叫在 **`:1842-1849`**，格式 `sFlow ingest healthy: rx={}, app_drop={}, addressed={}, sock_ovfl_total={}`。

### 【觀察】runbook 三處寫什麼

| # | 位置 | 原文摘要 | verdict |
|---|---|---|---|
| a | 檔頭 L12 | 「那行只在第一輪是 INFO…所以只會出現一次，**且 `rx=0`**。見 `FlowLinkUsageCollector.cpp:1798-1801`」 | 🔴 **雷**：INFO 現在只在 `rx > 0` 時發，`rx=0` 已不可能 |
| b | §5b L400-402 | 「✅ 預期：至少一行…**這行在 `FlowLinkUsageCollector.cpp:1798-1801`**：第一輪是 INFO，之後是 TRACE」 | 🔴 行號錯（實際 `:1842-1849`）；「第一輪」錯（是「第一個 rx>0 的輪」） |
| c | 檔尾孤兒 L1022-1025 | 「`rx=` 和 `addressed=` 反映的是**啟動瞬間**的值（**通常都是 0**）」 | 🔴 **雷**：與程式碼直接矛盾 |

【觀察】`:1798-1801` 今天是**被註解掉的 `getsockopt(SO_RXQ_OVFL)` 那五行**（開檔確認）。runbook 檔頭 L27 已經自己承認這個行號漂了——**但 L12、L402、L1025 三處仍原封不動帶著它**。檔頭的更正沒有傳播到正文。

### 🔴 更嚴重的一條：P4 模式沒有 counter sample

runbook §9 L968 的排錯表寫：

> \| `addressed=0` 但 `rx` 在漲 \| 沒有真實流量——**rx 是 counter sample（週期性）**，addressed 只對 flow sample 遞增 \| 不是 sFlow 壞掉 \|

【觀察】`p4_proxy/proxy_agent/sflow_emitter.py` 全檔**沒有任何 counter-sample 路徑**（`grep -n -iE "counter"` 零命中）。只有 `build_flow_sample`（`:166`）與 `build_datagram`（`:220`），後者 docstring 明寫「carries one or more **flow samples**」，`:231` 更是 `raise ValueError("a datagram must carry at least one sample")`。

【觀察】`p4_proxy/p4_src/ndtwin_switch.p4`：
- `:52` `const bit<16> SAMPLE_RATE = 256;` → runbook「1/256 取樣」**OK**
- `:384-385` `random(meta.sample_rand, 0, SAMPLE_RATE - 1); if (meta.sample_rand == 0)` → 隨機取樣而非每 N 個，與 `:24` 註解一致
- `:363` 「Controller-injected packet: obey the requested egress port and **do not sample**」
- `:381` 「Never sample a packet already destined for the CPU」

【推論】兩條「不取樣」規則把 LLDP beacon 排除在取樣之外（送出端是 controller-injected、接收端是 destined for CPU）。**所以 idle 時完全不會有 sFlow datagram**，`rx` 恆為 0。

**對 Adam 明早的實際後果**：
1. 跑 §4 一系列 idle 檢查時，kernel.log 會在 stack 起來約 60 秒後冒出一條 **WARN**「no sFlow datagram has arrived in 60s…」。**runbook 完全沒提這條**，字面讀起來像 sFlow 壞了。實際上 idle 無流量時它是預期的。
2. 若照孤兒 §5b（L1015-1025）在 idle 期 `grep "sFlow ingest healthy"`，**會是零行**，而 runbook 寫「✅ 預期：至少一行」。
3. §9 L968 那一列的「rx 是 counter sample（週期性）」在 P4 模式下不成立，會把人導向錯誤結論。

**建議修法**：§5b 只保留「灌流量後才 grep，且應有一行、`addressed > 0`」，刪掉 `rx=0`／「啟動瞬間」的說法與 `:1798-1801` 行號（照 runbook 自己 L33 的方針改用符號名 `announceNow`／`kNoSampleGrace`），並在 §4 或 §9 補一列說明 idle 的 60s WARN 是預期的。

### 順帶：`FlowLinkUsageCollector.cpp:507` —— **OK，但理由跟 runbook 寫的不一樣**

檔頭 L34 說 `:507` 和當時「一模一樣（都是一段 docblock 的 `@details` 行），沒漂」。

【觀察】`:506-522` 是 `refreshDestinationPathsPeriodically()` 的 docblock；嚴格說 `:507` 是空的 ` *` 行、`@details` 在 `:508`。但**這個 docblock 確實就是 §3b L208 所引的那段解釋**，`:513-516` 逐字寫著：

> `**Ordering.** start() runs before loadStaticTopologyFromFile, so the switch kinds are not`
> `known and controlPlaneHostAndPort() cannot tell Ryu from the P4 proxy. The first attempt`
> `therefore asks the wrong host, gets nothing...`

且 `controlPlaneHostAndPort()`（`:210-218`）確實是「非 bmv2 就回 `AppConfig::RYU_IP_AND_PORT`」。

**verdict: OK** —— §3b L208「第一筆對 `:8080` 的 curl 失敗是預期且自癒」這個宣稱**成立**。

---

## 第 3 批：行號引用逐一開檔核對

runbook 檔頭 L26-35 已經做過一輪自我重核，並宣示「行號在這個檔案裡已經腐爛兩次，第三次不會例外，所以這裡只留符號名」。
**正文並沒有照辦**——底下每一條都是重新開檔讀出來的（不是憑記憶）。

| runbook 位置 | 引用 | 實際位置 | verdict |
|---|---|---|---|
| §5a L379 | 「`getAvgLinkUsage` 今天在 **`:2600`**，host 排除的判斷式在 **`:2626-2627`**」 | `TopologyAndFlowMonitor.cpp:2704` 是函式，host 排除在 **`:2730-2731`** | 🔴 **第三次腐爛**（漂 ~104 行）。runbook 在同一句宣告「這次不換數字，直接把行號拿掉」，**卻還是留了兩組數字** |
| §5g L499 | 「`if (e.dstDpid == dpid) numOfFlows += e.flowSet.size()`（**`HttpSession.cpp:1734-1739`**）」 | 實際在 **`:1811-1814`**，回應在 `:1816` | 🔴 漂 ~77 行。**而且危險**：`:1734-1739` 今天是 `handleSetHistoricalLoggingState`，`:1773` 另有一段**長得一模一樣**的 `if (e.dstDpid == dpid)`（那是 `get_total_input_traffic_load_passing_a_switch`），照行號翻會翻到錯的函式 |
| §5h L517 | `flow_set` 老化「（**`TopologyAndFlowMonitor.cpp:2680-2692`**）」 | `flushEdgeFlowLoop()` 在 **`:2946-2983`**，TTL 判斷在 **`:2958-2970`**。`:2680-2692` 今天是靜態 topo JSON 的 catch 區塊 | 🔴 漂 ~270 行 |
| §5h L517 | `touchEdgeFlow`（**`FlowLinkUsageCollector.cpp:1544/1553`**） | 實際 **`:1543` / `:1552`** | 🟡 各差 1 行（無害） |
| §5h L518 | `link_bandwidth_usage_bps` 重算（**`TopologyAndFlowMonitor.cpp:895-907`**） | `:890-912` 今天是 `updateGraph()`；重算在 **`:1094-1095`** | 🔴 漂 ~200 行 |
| §7 L881 | `admin_disabled` 定義在 `GraphTypes.hpp:215` | 欄位宣告在 **`:217`**（`bool adminDisabled = false;`），`:215` 是同一段 docblock 內文 | 🟡 差 2 行（無害） |
| §7 L883 | `is_enabled = isEnabled && !adminDisabled`（**`HttpSession.cpp:530` 和 `GraphTypes.hpp:323`**） | edge 版在 **`HttpSession.cpp:567`**、vertex 版在 **`GraphTypes.hpp:346`**。`HttpSession.cpp:530` 今天是 `result["edges"] = json::array();` | 🔴 兩個都漂 |
| §7 L887 | kernel 以 `--no-ai` 啟動（**`stack.sh:606`**） | **`stack.sh:606`** 就是 `bash -c "... --mode mininet --topology '$topo' --no-ai"` | ✅ **OK，逐字命中** |
| §7 L887 | `IntentTranslator` 是 nullptr（**`main.cpp:346-362`**） | `main.cpp:343` `std::shared_ptr<IntentTranslator> intentTranslator = nullptr;`、`:344 if (config.useToken)`、else 分支到 `:359` | ✅ **OK**（指到正確區塊） |
| §6e L630 | poll 間隔常數 `kWhileConverging`／`kOnceConverged`／`kConvergingFor`，**不寫行號** | `TopologyAndFlowMonitor.cpp:2004` `= 5s`、`:2005` `= 30s`、`:2006` `= 90s`，使用處 `:2039-2041` | ✅ **OK —— 這是全文唯一「只留符號名」的引用，也是唯一沒腐爛的。5d53cf0 的做法有效** |
| §6h L783 | 「`p4_testbed_topo.py:154`：`addLink(switches[2], switches[5], port1=1, port2=2)`」 | 該行實際在 **`:155`**；`:154` 是 `addLink(switches[1], switches[6], port1=2, port2=1)` | 🟡 差 1 行（引的**程式碼文字本身正確**） |
| §3b L208 | `FlowLinkUsageCollector.cpp:507` 的註解解釋第一筆 `:8080` curl 失敗 | `:506-522` docblock，`:513-516` 就是那段 Ordering 解釋 | ✅ **OK** |
| §5h L532 | `LinkInformation.tsx:198-199` | 本 repo 內不存在（Web-GUI 是別的 repo） | ⚪ 無法核對，非本 repo |

**【推論】所有這些引用的「宣稱內容」都仍然正確，錯的只有指標。** 但 §5g 那條因為隔壁有同形狀的程式碼，是唯一會把人導向**錯誤結論**的。

## 第 4 批：預期值／常數（全部對到程式碼）

| runbook 宣稱 | 程式碼 | verdict |
|---|---|---|
| §4a/§8 switch **10**、host **4**、edges **40** | `p4_testbed_topo.py`：16 條 switch-switch `addLink`（`:153-169`）＋ 4 條 host `addLink`（`:181-184`）= 20 條無向 → **40 條有向**；switches[1..10]、hosts[0..3] | ✅ OK |
| §4i L366 watchdog seeded with **32** declared links | 16 條 switch-switch × 2 方向 = **32**（host 邊不算）。訊息格式 `topology_manager.py:1246` `"[TopologyManager] link watchdog seeded with {seeded} declared links"` | ✅ OK |
| §4h/§8 paths **12** | 4 台 host × 3 個對象 = 12（單向計） | ✅ OK |
| §4c power **33466–147622 mW**、跨輪詢不變 | `DeviceConfigurationAndPowerManager::syntheticPowerMilliwattsFor`（`:545-564`）= `30000 + splitmix64(dpid) % 120000`；MININET 模式走這條（`:1236-1238`）。**我照公式算了 dpid 1–10：`{1:92465, 2:98110, 3:49053, 4:73978, 5:68618, 6:100592, 7:44487, 8:147622, 9:142228, 10:33466}` → min 33466、max 147622，10 個全不同** | ✅ **OK —— 逐位元組吻合，且是純函式所以必然跨輪詢不變** |
| §4c「10 個元素」 | `:1230-1233`：`!isUp` 的 switch 仍會被 push，只是 `power_consumed: 0` | ✅ OK（就算有 switch down 也還是 10 筆） |
| §5a L391 sFlow **1/256** 取樣 | `ndtwin_switch.p4:52` `SAMPLE_RATE = 256` | ✅ OK |
| §5a L389「flow 幾秒內老化歸零」 | `flushEdgeFlowLoop`：TTL `std::chrono::seconds(2)`（`:2964`），掃描週期 1000 ms（`:2979`）→ 2–3 秒 | ✅ OK |
| §5e TTL **59**（64 − 5 台） | h1(s1)→h4(s4) 必經 s1→(s5\|s6)→(s9\|s10)→(s7\|s8)→s4 = 5 台；§5c 的 `path_len 7` = 5 台 + 2 個 host IP | ✅ OK，兩處自洽 |
| §6 L856 中斷 ≈ `LINK_BEACON_TIMEOUT_S`（**15s**）+ 一個掃描週期 → **15–20 秒** | `topology_manager.py:137` `LLDP_BEACON_INTERVAL_S = 5`、`:155` `LINK_BEACON_TIMEOUT_S = 3 * LLDP_BEACON_INTERVAL_S` = **15**；`:157` `LINK_WATCHDOG_INTERVAL_S = 5`。原始碼註解逐字寫「Detection therefore takes between LINK_BEACON_TIMEOUT_S and that plus one scan interval -- **15 to 20 s**」 | ✅ **OK，逐字吻合** |
| §6b L573/581 偵測「大約 **11 秒**後」 | 同上：下限是 15 s | 🟡 **雷（小）**：11 < 15，在現行常數下不可能。等到 11 秒沒看到會以為壞了。應改成 **15–20 秒**，與 §6c L583 的「約 15 秒」和 §6 L856 一致 |
| §4i L364 `[N] Clone session 250 -> port 255 installed` ×10 | `p4_client.py:29` `SAMPLE_SESSION_ID = 250`、`:30` `CPU_PORT = 255`、`:301` `print(f"[{self.device_id}] Clone session {session_id} -> port {egress_port} installed")` | ✅ OK |
| §4i L365 0 行 `clone session failed` / `NO telemetry` | `main.py:199` `print(f"[Proxy Agent] Switch {i}: clone session failed, NO telemetry from it")` —— 字串仍在，檢查有效 | ✅ OK |
| §1 L86「`wait_for_port` 現在會檢查 socket 擁有者」 | `stack.sh:405-425`：`port_owner_verdict "$port" "$component"` → `ours`／`stray`，`stray` 直接 return 1 | ✅ OK |
| §2 L104 通過標準 `L1 passed: N test binary/binaries, clean under ctest and direct execution.` | `l1_unit_tests.sh:352` 逐字相同 | ✅ OK |
| §2 L107「`NO TESTS RAN` 是失敗」 | `l1_unit_tests.sh:196` 與 `:323` 都印這個字串 | ✅ OK |
| §2 L119 `test_p4_client.py` 整份 skip 是預期，有 `NDTWIN_L1_OPT_IN` 標記 | `p4_proxy/tests/test_p4_client.py:23` 有該 token；`l1_unit_tests.sh:214-216` 讀它 | ✅ OK |
| §2 L114 p4_proxy Python 測試「分布在 **12 個檔案**」 | `ls p4_proxy/tests/test_*.py` = **14 個** | 🔴 **雷**：12 → 14 |
| §2 L115 kernel-side Python「分布在 **2 個檔案**（`tests/python/`）」 | `tests/python/` 有 **4 個**：`test_contract_spec.py`、`test_p4_power_helper.py`、`test_route_install_gate.py`、`test_route_reinstall.py` | 🔴 **雷**：2 → 4 |
| §2 L115「+ 1 個 shell」 | `tests/shell/test_wait_for_port.sh`，1 個 | ✅ OK |

【推論】檔案數 12→14、2→4 既然錯了，**條數 426／312／101 也必然是舊的**。B3 手上有今晚的實跑數字，以 B3 為準；此處只證明 runbook 的數字不能照抄。

---

## 第 5 批：runbook 有沒有跟上今天的行為變更

### 32afeb9 —— 死 switch 從 `/v1.0/topology/switches` 消失

【觀察】`p4_proxy/proxy_agent/api_routes.py:42-50`：

```python
@router.get("/v1.0/topology/switches")
async def topology_switches():
    if topology is None:
        return []
    return ryu_topology.render_switches(topology.connected_switch_dpids())
```

【觀察】`topology_manager.py:1002` `connected_switch_dpids()` 存在且就是這個呼叫點的被呼叫者（**不是只有定義沒接線**）。docstring `:1018-1022`：只有 **definite `False`** 才排除；probe 從未完成（`ok` 缺席）不算死。

**verdict: runbook 不必改，但 §9 少一列。**
- runbook 從頭到尾**沒有直接查 `/v1.0/topology/switches`**，所以沒有直接矛盾。
- §4a／§6c／§3c 查的 switch 數（10）在 runbook 的所有情境下都不會受影響：`ifconfig down` 之後 `probe_ok` 仍是 `true`（runbook L547 自己實測記載），所以那台不會被排除，仍然是 10。**兩份文件在這裡是一致的。**
- 🟡 **新的失敗模式沒被寫進 §9**：以前一台 bmv2 死掉會顯示 `up=10 / enabled<10`，現在是 **`switches` 本身 < 10**。§9 L963 只寫「`enabled` 不是 10」。建議補一列：「`switches` 不是 10 → 有 bmv2 的 probe 回報 definite false，看 `/p4/switch_state` 的 `probe_ok`」。

### 3a312e3（502 訊息改指直接打 `/p4/readopt/{dpid}`）與 eace67c（readopt 失敗細節進 kernel log）

【觀察】兩者都改在 `src/ndt_core/power_management/P4PowerStrategy.cpp`（powerOn／readopt 路徑）。

【觀察】runbook 對 `readopt`、`502`、`/ndt/set_switches_power_state`、`powerOn/powerOff` 的命中數：**全部為 0**（`grep -n -E "readopt|502|switches_power_state|powerOn|power on|power off"` 只命中 L5／L17／L914 三處泛談 Phase 7 的句子）。

**verdict: 沒有矛盾，但有一個更上位的雷 —— 見下。**

### 🔴 runbook 的適用範圍宣告已經過期

【觀察】runbook **L5**：

> 「…以及開始 Phase 7（power management）之前。**Phase 7 還不存在，本文件不涵蓋它。**」

【觀察】`doc/2026-07-27_p4_bmv2_support_plan.md:480`：

> `## Phase 7 — 讓電源管理真的能用 ✅ 已完成`

同檔 `:159` 也把 P4 關機的兩個舊缺陷標成「**✅ 已於 Phase 7 修掉（`624946d`／`1978292`）**」。

**verdict: 🔴 雷。** runbook 自稱是「Phase 7 開工前跑的那一份」，但 Phase 7 已完成、Phase 8 過半。實際後果：
1. Adam 照這份跑完全綠，**不代表今天的 power management 路徑健康**——那一整塊（`powerOff`／`powerOn`／`readopt`／`/ndt/set_switches_power_state`）runbook 一個字都沒測。3a312e3 和 eace67c 改的正是這一塊。
2. §7 L914「Phase 7 引入 power management 後…那時候這條檢查才真正有意義」是未來式，但那個「那時候」已經到了——`admin_disabled` 的不變量檢查現在**可能**已經不再空洞成立（`/ndt/set_switches_power_state` 已註冊於 `HttpSession.cpp:177`）。runbook 仍教人預期「全部 false」。
3. runbook L17 自己寫的方針是「**之後每個 phase 應該延伸這一份**」——Phase 7 完成時沒有延伸。

### 🔴 §6h 的「根因」段落已經完全過期

runbook **L729-731**：

> 「根因很單純：`install_initial_routes()` 全專案只有**一個**呼叫點，在 `topology_manager.py:655`，條件是 `if not edge_exists`…鏈路**消失**時沒有任何東西呼叫它。」

【觀察】今天 `topology_manager.py`：
- 定義在 **`:665`**（不是 `:655`），docstring `:670` 逐字寫「Called on discovery and, **since failover, on a link transition.**」
- production 呼叫點有 **三個**：
  - `:941` —— `if not edge_exists` 的發現路徑（runbook 講的那個）
  - `:813` —— readopt 路徑，`install_initial_routes(only_dpid=dpid)`
  - **`:1312`** —— `if result["down"] or result["up"]:` 的**鏈路轉換**路徑，正是 runbook 說「不存在」的那個

**verdict: 🔴 雷（中）。** runbook 後面確實有自我更正（L802-803「**已解決 —— 用 `tc netem`**」、L766「failover 已經實作」、L853「failover 至此為『規則層 ＋ 端到端』皆已驗證」），但 L729-739 這一整段仍以現在式陳述一個已經不成立的根因。停在那裡讀的人會得到相反的結論。

### 🔴 §6h 末尾說「還沒修」的漏洞，已經修好了

runbook **L859-873** 描述 `reroutable_down_endpoints()` 的漏洞（suspect switch 的赦免範圍涵蓋了真正斷掉的那條鏈路），結論是：

> 「**還沒修，怎麼修是 Adam 的決定**…候選方向：…或想辦法從證據裡分辨哪一條是真的。」

【觀察】`topology_manager.py:451-455`（重新開檔讀）：

```python
reroutable = set()
for (src, src_port, dst, dst_port) in down_links:
    if dst in suspect and (dst, dst_port, src, src_port) not in down_links:
        continue  # inbound-only silence at a stalled switch: the link itself is fine
    reroutable.add((src, src_port))
return reroutable
```

那個 `and (dst, dst_port, src, src_port) not in down_links` 就是「用反向是否也 down 來分辨真假」——**正是 runbook 列為待決定的第二個候選方向**。docstring `:428-437` 也明寫「**The amnesty is per link, not per switch**」並說明理由。

【觀察】測試已鎖住：`p4_proxy/tests/test_link_watchdog.py:816` `self.assertEqual(self.topo.reroutable_down_endpoints(), {(5, 4), (10, 1)})` —— `(10,1)` 正是 runbook 說「被錯誤保留」的那一筆，現在**確實**進了 reroutable 集合。

**verdict: 🔴 雷。** Adam 明早若照 runbook 把這條當待辦，會去修一個已經修好的東西。

### ✅ 「ping 有沒有停」判準句還在

【觀察】三處都在：
- **L677-678**：「⚠️ **判準一定要包含「ping 有沒有停」。** 只看 API 會被騙——實測時 twin 的每一個數字都正常，封包卻已經在被丟掉了。」
- **L699**：「**ping 不中斷**（最重要的一項，其他都是輔證）」
- **L855-857**：「✅ **這一節的通過判準**：ping **會短暫中斷再自己恢復**（約 15 秒）…**永遠不恢復**代表 failover 沒生效，**完全不中斷**代表你斷的鏈路根本不在流量路徑上。」

**verdict: OK。**

### 🔴🔴 P0：§6a 與 §6h 的**可執行步驟**仍然是 `ifconfig down`

【觀察】runbook 裡教人實際下 `ifconfig down` 的地方有兩處（不含說明與歷史紀錄）：

| 行 | 指令 | 所屬步驟 |
|---|---|---|
| **L563** | `sudo -n ifconfig s1-eth1 down` | §6a「斷線」——§6 的主流程第一步 |
| **L692** | `sudo -n ifconfig s6-eth4 down` | §6h 步驟 2「斷掉『中段』的一跳」 |

（L645 是對應的 `up` 恢復；其餘 11 處 `ifconfig` 都是說明或歷史紀錄，不是指令。）

【觀察】文件自己在 **L798-803** 下的結論：

> 「**結論：`ifconfig down` 讓整台 switch 停止搬運流量，不只是停止 packet-in。** 既然任何繞路都救不了一台不轉發的 switch，這個方法就驗不了 failover…**已解決 —— 用 `tc netem`**」

**這是本次審查最實質的雷，理由是判準與方法錯配：**

- §6h 的通過判準（**L855**）是「ping 會短暫中斷再自己恢復（約 15 秒）；**永遠不恢復**代表 failover 沒生效」。
- 但 §6h 的可執行步驟（**L692**）是 `ifconfig down`，而文件自己（**L764-803**）已經證明這個方法會讓 ping **永遠不恢復**——那是方法的產物，不是 failover 壞掉。
- 兩者相距約 160 行，**判準在後、步驟在前**。照順序執行的人會先跑 L692，再讀到 L855，然後得到「failover 沒生效」的**錯誤結論**。

runbook 記載的正確做法（**L810-816**，且已端到端驗證）是：

```bash
sudo -n tc qdisc add dev s5-eth4  root netem loss 100%
sudo -n tc qdisc add dev s10-eth1 root netem loss 100%
# 恢復
sudo -n tc qdisc del dev s5-eth4  root
sudo -n tc qdisc del dev s10-eth1 root
```

**建議在 Adam 跑之前就改**：把 §6h L683-695 那段程式碼區塊的 `ifconfig` 換成 `tc netem`（雙向都要），並在 §6a 標明「§6a-§6g 用 `ifconfig` 只為了**重現並認識那個陷阱**；要驗 failover 一律用 §6h 末的 `tc netem`」。

### 🟡 文件結構：§5b 在檔尾有一份孤兒副本

【觀察】L998「## 收尾」→ L1014「✅ 全部無輸出。」之後，**L1015 直接冒出 `### 5b. 確認流量有被觀測到（terminal A）`**，內容到 L1026，然後才是 `---` 和頁尾。

這是 §5b（L393-402）的第二份副本，而且**兩份說法不一致**：
- 正文 L400：「idle 時 `addressed=0` 是正常的；**有 traffic 時應該 > 0**」
- 孤兒 L1025：「`rx=` 和 `addressed=` 反映的是**啟動瞬間**的值（**通常都是 0**）」

【推論】看起來是編輯時貼錯位置留下的殘骸。**兩份都帶著已經腐爛的 `:1798-1801`**（見第 2 批）。建議直接刪掉 L1015-1026 這一段，把要保留的句子併回正文 §5b。

---

## 第 6 批（附加）：`tools/test_workflow/stack.sh` 的 usage／註解 vs 實作

| 項目 | usage／註解說什麼 | 實作 | verdict |
|---|---|---|---|
| `up` 順序 | usage `:731-733`：「ovs: Ryu → Mininet → wait → kernel（switches dial out to Ryu）／p4: Mininet → proxy → wait → kernel（proxy dials out to bmv2）」 | OVS：`:541` `[1/3] control plane (Ryu)`、`:567` `[2/3] data plane (Mininet, needs sudo)`；P4：`:570` `[1/3] data plane (bmv2 Mininet, needs sudo)`、`:575` `[2/3] control plane (P4 proxy agent)`；共同 `:599` `[3/3] kernel` | ✅ **OK，逐字吻合**，也和 runbook §3 的表一致 |
| 檔頭依賴順序註解 | `:9-11`：「1. control plane　Ryu (OVS) or the P4 proxy agent (P4)／2. data plane　Mininet topology／3. kernel」——**單一固定順序，沒有分模式** | P4 模式實際是 data plane 先（`:570`） | 🟡 **輕微腐爛**：檔頭把 OVS 的順序寫成通例，與同檔 `:731-733` 的 usage 和 P4 實作**互相矛盾**。runbook §3 L139-146 特別強調「P4 的啟動順序和 OVS 相反」，只讀 stack.sh 檔頭的人會得到相反印象 |
| `wait [secs]` 預設 90s | usage `:734`「block until every switch is up AND enabled (default 90s)」 | `:460` `local timeout="${1:-90}"`；`:474` 印 `waiting for topology convergence (expect $expected switches up+enabled, timeout ${timeout}s)` | ✅ OK |
| `wait` 的「10 台」哪來 | — | `:468-471` 從 topology JSON 數 `vertex_type == 0`，**不是寫死 10**。所以 runbook §3c 的 `expect 10` 是拓撲檔決定的 | ✅ OK（比 runbook 寫死數字更穩健） |
| `down` | usage `:736`「stop kernel, proxy/Ryu (Mininet needs 'sudo mn -c')」 | runbook 收尾 L1003-1004 就是 `./stack.sh down` 後接 `sudo mn -c` | ✅ OK，兩邊一致 |
| 收斂訊息字串 | — | `:204` `waiting for link discovery: want ${want_a} destination paths`、`:221` `paths=%s`、`:232`／`:497` `converged after Ns` | ✅ 全部對得上 runbook §3b L195-201／§3c L219-222 |
| `wait_for_port` 擁有者檢查 | `:386-392` 註解描述 stray kernel 讓「288 edges、128 hosts」這種 OVS 數字混進 P4 session | `:405-425` `port_owner_verdict` → `ours`／`stray`／`unknown`，`stray` 直接 return 1 | ✅ OK，註解與實作一致 |

**stack.sh 小結：usage 區塊與實作完全一致；只有檔頭 `:9-11` 的依賴順序註解沒跟上 P4 模式。**

---

*B4 完成於 2026-08-12 深夜。全程純讀，未執行任何 live 指令、未跑測試、未改動 repo 任何檔案。*
