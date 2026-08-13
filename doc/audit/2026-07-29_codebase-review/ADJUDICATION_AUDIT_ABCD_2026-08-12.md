# 裁決：AUDIT A/B/C/D 四主題審查

裁決時間：2026-08-12
裁決基準：`feat/phase7-p4-power` @ `09a7a81`（審查產出時 HEAD 是 `9afd647`／`b0c82df`）
方法：**不採信 audit 的引文**。每一條重新打開被引用的檔案與行號，claim 與 reality 兩側都自己核。

## 總結

| | 條數 | 實質成立 | 引用正確 |
|---|---|---|---|
| A 幻覺／假斷言 | 28 | 28 | 27 |
| B 測試完整性 | 6 | 6 | 6 |
| C 寫死假設 | 9 | 9 | 8 |
| D 吞掉的錯誤 | 12 | 12 | 12 |
| **合計** | **55** | **55** | **53** |

**55 條實質全部成立，零誤判。** 這是四份 audit 少見的命中率——對照 `ADJUDICATION_agy-reviews_0157-0201.md` 那輪 47 個 HIGH 裡有相當比例是誤判。差別在 prompt 形狀（見 `PROMPT_Fable_CodebaseAudit.md`），不在模型。

兩處引用瑕疵，都不影響結論，但既然主題就是「引用會腐爛」，記在下面。

### 引用瑕疵 1（唯一一條實質引用錯誤）— C 主題「Kernel configuration paths are cwd-relative」

Audit 寫 `include/ndt_core/intent_translator/IntentTranslator.hpp:324-326`。
**那個檔案只有 56 行。** 兩個 prompt 路徑實際在：

```
52:        std::string m_answerAgentPromptFilePath = "../src/ndt_core/intent_translator/answer_agent_prompt.txt";
54:        std::string m_validationAgentPromptFilePath = "../src/ndt_core/intent_translator/validation_agent_prompt.txt";
```

全 repo 只有這一個 `IntentTranslator.hpp`（`find` 確認），`answer_agent_prompt.txt` 全 repo 只出現在 :52。
`AppConfig.hpp:5/:16/:18` 那半邊完全正確。**實質成立，引用是編的。**

### 引用瑕疵 2 — A 主題「Test-count claims are stale」

Audit 說 p4_proxy 有 13 個測試檔。**現在是 14 個**——`09a7a81` 加了 `test_readopt.py`，落在 audit 產出之後。
Audit 當時是對的，48 小時腐爛率再次得證（這正是該條自己的論點）。

### 措辭需要注意 — A 主題「Four flow-write endpoint sections omit the 404」

Audit 寫「Grep of the whole doc for `unknown_dpids|rejected_dpids`: zero hits」。
`doc/2026-01-02_ndt_api.md` 確實 0 hits（實測），但 `doc/audit/2026-08-09_integration-runbook.md` 有 6 hits，該契約在那裡記載得很完整。
「the whole doc」指的是 2026-01-02_ndt_api.md，不是 `doc/`。結論不變。

---

## 動作清單（按該不該現在動排序，不按 audit 順序）

### Tier 1 — 真缺陷，會在活路徑上造成錯誤行為 ✅ 四條全修完

| # | 位置 | 問題 | commit |
|---|---|---|---|
| 1 | `TopologyAndFlowMonitor.cpp:480` | 缺 `dpid` 的控制平面回應 → `stoull("")` 拋 `std::invalid_argument` → **殺掉整個 kernel** | `f21d7a0`、`0d3bc9c` |
| 2 | `DeviceConfigurationAndPowerManager.cpp:1396` | live TESTBED 電源路徑 `return rc == 0`，`curl` 沒 `-f`；修好的版本（:808）零呼叫點 | `3292653` |
| 3 | `Classifier.cpp:771-773` | guard 用 `vlan_vid`、讀 `vlan_id` → 一條 VLAN 規則永久毒化後續每一次 flow-stats 輪詢 | `5054249` |
| 4 | `TopologyAndFlowMonitor.cpp:1152,1174,2541` | `boost::edge().first` 沒查 `.second` → 無效 descriptor 包在 engaged optional 裡，sFlow 熱路徑寫穿它 | `cbb504a`、`6dd0485` |

修的時候多發現兩件 audit 沒抓到的：

- **第 1 條有第三個實例**：`updateHosts` 的 `host["port"]["dpid"]`。在 **const** json 上
  `operator[]` 缺 key 是 **UB 不是例外**（bounds check 是 `JSON_ASSERT`，NDEBUG 下被編掉），
  所以連 catch 都接不到。連同 `ipStringToUint32` 和兩個在錯誤路徑裡的
  `host["mac"].dump()` 一起修。由我自己的新測試撞出來——它在第二筆**格式正確**的資料上崩了。
- **第 2 條不能照抄**：那個零呼叫點的 overload URL 已經漂掉，少了 `resource=outlet`
  （活路徑和電源報告都有帶）。直接把它接上去會**悄悄改掉真實硬體收到的請求**。
  所以是把邏輯搬進活路徑、保留原本的 URL，只加 `--max-time` 和 `-w '%{http_code}'`。
- **第 4 條的 UB 是真的會崩**：mutation 把 `getLinkBandwidthBetweenSwitches` 的
  `.second` 檢查拿掉之後，測試程序 **segfault（rc=139, core dumped）**，正好停在
  單向連結那條測試上。

Mutation：7 個 mutant 全 KILLED。其中 T6（bandwidth 端點的 `.second`）第一輪報 NO-FAILURE
——是真缺口，補了兩條測試才咬得住。

第 1 條的傳播路徑我自己追過：`updateSwitches`（catch 只收 `json::exception`）→ `updateGraph`（`pollControlPlaneTopology:461` 呼叫，**在三個 try 之外**）→ `run()`（無 try）→ thread 進入點 → `std::terminate`。

### Tier 1b — Phase 7 新程式碼，live 驗證前要修

| # | 位置 | 問題 |
|---|---|---|
| 5 | `tools/p4_power_helper.py:302-311` | `on` 逾時時 `proc.pid` 沒寫進 manifest（只寫在 port-open 分支裡）→ 產生 helper 自己再也定址不到的 orphan；之後每次 `off` 都回 `already-stopped` exit 0，而 bmv2 還活著並佔著 gRPC port |
| 6 | `P4PowerStrategy.cpp:79-83` | 502 訊息承諾「retrying this power-on retries the readopt」，但 readopt 失敗後 process 還在跑 → probe 成功 → pingWorker `setVertexUp` → 重試撞上 :46-49 的 early-return success。真正的復原路徑是 off-then-on，訊息沒說 |
| 7 | `topology_manager.py:803-810` + `main.py:288` | readopt 換掉 `topology.switches[dpid]`，但 main 的 module-global `p4_clients` 還指著舊的；shutdown 停舊的、新的永遠不停。**設計文件 :83-84 寫「持有 clients 引用的只有 api_routes 和 main（grep 過…），swap 安全」——被點名的 main 就是反例** |

第 5 條會直接在 live 驗證那天咬人：只要 bmv2 啟動超過 15 秒，就會留下一個關不掉的 switch。

### Tier 2 — 靜默失敗與設定寫死（重部署才咬）

`HistoricalDataManager.cpp:27,61,117`（寫進 root-owned 的 `/home/of-controller-sflow-collector/LinkData`，**實測 `drwxr-xr-x root root`**，TESTBED 每次跑都寫進死掉的 stream，零 log）、
`ControllerAndOtherEventHandler.cpp:51`（收下 `HistoricalDataManager` 不存 → 端點永久 500，且 main.cpp 另外建了第二個實例，且 `m_loggingEnabled` 沒人讀——三層各自獨立死掉）、
`LLMAgent.cpp:29`（`OPENAI_API_KEY` INFO 明文，且在 null check 之前）、
`Utils.hpp:570`（`set_verify_mode` 全 repo 不存在 → OpenAI 通道零憑證驗證，載入 verify paths 是裝飾）、
`IntentTranslator.cpp:272,282`（電源失敗仍回 `"ok"`，同檔案 DISABLE/ENABLE 就有回錯誤，所以是逐 case 的不一致不是設計）、
`HttpSession.cpp:1937`（release_lock 無條件 200）、`:1778,:1805`（缺 dpid → 200 帶 error body）、
`sflow_emitter.py:93`（collector 寫死 127.0.0.1:6343，唯一沒有 env override 的 kernel-bound 通道）、
`main.py:25-28`（四台 host 寫死）、`intelligent_router.py:25,31,283/311/788/846`、
`TopologyAndFlowMonitor.cpp:47`（`RYU_BASE_URL` 繞過 AppConfig）、`:2387,:2401`（每台 switch 都掛同一個假 smart plug）、
`FlowLinkUsageCollector.cpp:273`（`popen("sudo ovs-vsctl …")`，失敗時每個 ofport 靜默變 0）、
`p4_client.py:433,449`（`read_egress_counter` 把三種狀況折成 `(0,0)`）、
`ApplicationManager.cpp:132,210,217,254`（四個 `system()` 全丟回傳值，其中兩個改 `/etc/exports`）、
`FlowLinkUsageCollector.cpp:2427,2441`（錯誤路徑回 JSON 字串、成功回物件，caller 雙重編碼）、
`sflow_emitter.py:283-285`（docstring 說「reports failure by return value」，但唯一 caller `p4_client.py:101-102` 把回傳值丟掉）。

### Tier 3 — 測試缺口（B 主題六條全中）

最值得動的兩條：
- `OVSPowerStrategy.cpp:15` / `P4PowerStrategy.cpp:29` 的 `if (rc != 0)` **改成 `if (false)` 沒有任何測試會紅**——所有測試都 override 掉 seam。這正是「失敗看起來像成功」那個歷史 bug 的原址。補法：每個 strategy 一條測試，跑真 seam 打 `/bin/false` 和 `/bin/true`。
- `test_readopt.py:271` 只 `assertIn("step", result)` 不驗值 → 把所有失敗都標 `"step": "start"` 照樣全綠。真正的 label（`build`／`pipeline`，`topology_manager.py:774,794`）沒被釘住。**這是我委派出去的測試，漏在我這關。**

其餘：`test_SFlowParsing.cpp:192`（版本守衛只驗 `EXPECT_NO_THROW`，刪掉守衛全綠）、
`emitted_multi.bin` 沒有 drift guard 而 generator docstring 宣稱有、
`l1_unit_tests.sh:203`（部分 skip 的 Python suite 印 PASS exit 0，gtest 那側同條件是 hard FAIL）、
`test_RelayResponse.cpp`（mutation 驗證過的測試在釘一個只有死碼會呼叫的函式——與 Tier 1 第 2 條同源）。

### Tier 4 — 文件腐爛（A 主題後半）

`2026-01-02_ndt_api.md` 五處行號漂移、`2026-07-29_p4_status_and_test_guide.md` 三處、`2026-07-27_p4_bmv2_support_plan.md` 說 Phase 7 半成品（已完成）、
`2026-07-29_HANDOFF.md` 三個 ❌ 已有測試、三份文件的測試數字（31/414、12/312 → 實際 34、14）、
`get_power_report` 文件寫 watts + random（實際是確定性毫瓦，例值 851157966 不可能出現）、
liveness 表寫 Up 需要 fresh probe（實際 `probe_ok` 單獨成立就回 Up）、
`release_lock` 的 423／412 兩種狀態碼都產不出來、
`get_nickname` 缺參數文件寫 404（實際 400）、`inform_switch_entered` 的 400 body 從未在 src 出現過、
`set_switches_power_state` 的 400 body 錯且真正的 500 body 完全沒記載、
`2026-07-28_test_coverage_gaps.md` §1.2 描述的紅色 L3 在它自己的更正 pass 之前就被拆掉了。

---

## 額外發現（audit 沒抓到，我核對時看到）

`TopologyAndFlowMonitor.cpp` 的 `get_static_topology_json` 兩個分支裡，`{"brand_name", v.brandName}` 各出現**兩次**（TESTBED 分支 ~:2380 和 :2384；else 分支 ~:2390 和 :2393）。nlohmann 會直接覆蓋，行為無害，但是死碼，而且就在 C 主題點名的假 smart_plug 那兩行旁邊。

---

## 我在裁決過程中犯的錯

核 B 主題「relay tests pin dead code」那條時，我第一次的 `grep -rn "interpretRelayResponse" src/ include/ tests/ | head` 輸出裡沒有 `src/` 那行，我一度以為 audit 說錯了（它宣稱唯一呼叫點在 `DCPM.cpp:826`）。重跑不帶 `head` 的完整 grep：17 個命中，`src/…:826` 確實在。**Audit 是對的，我的第一次讀取是錯的。**

記在這裡是因為它剛好是 `fresh-grep-before-confirmed-quote` 那條教訓的正面版本：我沒有拿第一次的印象去下判斷，而是因為出現分歧就重跑，然後推翻自己。要是我當時直接寫「audit 這條誤判」，就會有一個假裁決進入文件鏈。

[Co-developed with claude code -- Adam]
