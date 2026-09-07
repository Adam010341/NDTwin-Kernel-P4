# E-23／E-25／E-30 — 被豁免的交換機：短路電源管理器六處，並讓記號上 wire

[Co-developed with claude code -- Adam]

分支 `fix/e23-e25-exempt-switch-on-wire`，base＝`fix/bug17-mixed-dataplane-refused`@`c4d81eeb`。
2026-09-07。**沒 push、沒 merge、沒 rebase、沒碰 lab、沒動 `setting/`、
沒碰主 checkout 與其他 worktree。**

⚠️ **base 是 BUG-17 的 tip，不是 HANDOFF 原寫的 W15b tip `4bc93d00`。**
orchestrator 09-07 改的，理由是讓這條鏈保持線性：
`W15 → W15b → BUG-17 → 本單`，避免在同一個 worktree 上分叉。

---

## 0. 這一單為什麼存在：前一單自己在 §7 問的兩題，Adam 都裁了「做」

`FIX-SWITCH-KIND-EXEMPTION.md`（W15-2）讓「未知 `brand_name` ＋明確 `switch_kind`」的交換機
被收下，並在圖上標 `power_path`／`telemetry_path` 為 `none`。它的 §5／§7 自己寫下了兩個缺口：

> 🔴 **電源管理器沒有改成「對未知 brand 拒絕作答」。** 記號是**宣告**：被豁免的交換機在 TESTBED
> 模式下**仍然會**掉進那個 `else` 分支、仍然會被打 Brocade 的 OID／SSH 取電（它不會回答）。

> **這兩個 key 要不要也出現在 `/ndt/get_graph_data`？** 這一單只放在 §38 ⋯ 但外部 app 讀圖多半走
> `get_graph_data`。

Adam 2026-09-07 grill §4E 兩題都裁了（`scratch/overnight-2026-09-05/DECISIONS.md`）：

> **E-23** 豁免只是記號：**開單，`power_path=none` 就短路電源管理器那六處**。（`:261`）

> **E-25（含 E-30）**：白話重講＋回答「baseline 怎麼處理」後裁
> **開單：`get_graph_data` 加 `power_path`／`telemetry_path`＋進契約＋啟動一行 WARN**。（`:269`）

🔴 **這一單的內容不是「多加兩個欄位」，是把一個只有自己聽得見的宣告變成一個外面看得見的事實。**
記號被寫下來的那一天起，有兩件事同時為真：碼沒有讀它，而程序外看不到它。

---

## 1. 實測的起點（🔵 引用，本輪沒有重跑）

round 2 的 **lw17c**（`scratch/overnight-2026-09-05/rounds/08-round2.md`）：
帶豁免的分支二進位 `85822a97`，餵一份把 dpid 7 的 `brand_name` 改成 `NOT_A_REAL_KIND`
並加上 `"switch_kind": "ovs"` 的檔 ⇒ **ACCEPTED**（14 nodes／40 edges，dpid 7 在圖裡）。
而：

- `/ndt/get_graph_data` 的那個節點只有 `brand_name`／`admin_state`／`is_up`——
  **沒有 `power_path`、沒有 `telemetry_path`**（分支與 trunk 都一樣）；
- log 裡 grep `unmanaged`／`power_path`／`admitted` ⇒ **0 行**。

⇒ **記號只在記憶體裡。**

### 1.1 🔑 為什麼會這樣：那是兩段不同的序列化

工單要求先確認 lw17c 的觀測跟 `TopologyAndFlowMonitor.cpp` 裡那段已經有
`{"power_path", v.powerPath}` 的碼是不是同一條路徑。**不是。**

| 端點 | 誰序列化節點 | W15-2 有沒有動它 |
|---|---|---|
| `/ndt/get_static_topology_json`（手冊 §38） | `TopologyAndFlowMonitor::getStaticTopologyJson()` 裡**手寫的兩個初始化列**（TESTBED／非 TESTBED 各一份） | ✅ 有（兩個分支都加了） |
| `/ndt/get_graph_data`（手冊 §3） | `HttpSession::handleGetGraphData` 的 `result["nodes"].push_back(graph[vd])` ⇒ `GraphTypes.hpp` 的 `to_json(json&, const VertexProperties&)` | ❌ 沒有 |

兩段各寫各的，**沒有共用**。所以記號進了少有人讀的那個端點，沒進**四個外部 app 讀的**那個
（Energy-Saving-App、Network-Traffic-Visualizer、Web-GUI、Traffic-Engineering-App）。
本單改的是 `to_json`，也就是第二列。§38 那段**一個字沒動**。

---

## 2. 改了什麼

### 2.1 E-23：六處短路（`DeviceConfigurationAndPowerManager.cpp`）

| # | 函式 | 未修前對豁免交換機做的事 | 現在 |
|---|---|---|---|
| 1 | `fetchMemoryReportInternal` | Brocade 記憶體 OID `1.3.6.1.4.1.1991.1.1.2.1.53.0` | 不打，`-1` |
| 2 | `fetchPowerReportInternal`（TESTBED） | **SSH `show power`**（`getPowerReportViaSsh`，10 s connect timeout） | 不打，`{"dpid":d,"power_consumed":-1}` |
| 3 | `fetchCpuReportInternal` | Brocade CPU OID `…1991.1.1.2.1.52.0` | 不打，`-1` |
| 4 | `fetchTemperatureReportInternal` | 🔴 **本來就沒有外呼**（見下） | `-1` |
| 5 | `getSingleSwitchPowerReport` | SSH `show power` | 不打，回 `{dpid, power_consumed:-1, exempt:"…"}` |
| 6 | `getSingleSwitchCpuReport` | Brocade CPU OID（argv 版） | 不打，回 `{dpid, cpu_usage:-1, exempt:"…"}` |

🔴 **第 4 處是誠實地不同的一格，分開寫而不是混進另外五格。**
溫度報告本來就在 `vp.brandName != kBrandHPE5520 && m_mode != MININET` 那個分支**提前 return**，
所以它**從來沒有**對豁免交換機外呼過。E-23 在這裡改的是**它說什麼**，不是它做什麼：
`"The temperature function only supports the HPE 5520."` 對一台 Brocade 是真的，
對一台被豁免的機器是半真——它讀起來像「我們有路徑，只是不是為這個型號寫的」，
而事實是這個 build 對這台機器**完全沒有路徑、而且一次也沒問過它**。
現在它回 `-1`，跟 CPU／記憶體同型（這也是這個檔案自 down-switch 那個字串改成 `-1` 以來的方向）。
**Brocade 那句話一個字沒動**——那是閘門的 widening 對照格。

🔴 **第 1、3 處寫成「提前 return」而不是 `else if` 分支，而那不是排版偏好**（第 2、4、5、6 處本來就是）。
第一版把它們寫成 mode 判定後的 `else if`，body 是 `memory = kHealthMetricUnavailable;`／
`cpu = kHealthMetricUnavailable;`——**而那兩行（12 空格縮排）正是
`tests/shell/mutate_f1_mininet_health_metrics.sh` 的 M1／M2／M5 的單行錨**。
多出第二個同樣的字串，那三顆變異體就會變成「錨匹配 2 次」而**不再被套用到它們原本針對的那個位置**，
`SimulatedDeviceMetricsTest` 卻照樣全綠——**F-1 的閘門會安靜地停止檢查任何東西**。
`python3 tests/shell/check_gate_anchors.py HEAD` 在第一版就抓到了（`count : 2 (want 1)`，兩行）。
改成提前 return 之後那兩個錨恢復唯一，而且這也正是它上面兩道守衛（沒有位址、交換機 down）
已經在用的形狀。**這一格是那支工具存在的理由的實例，寫進來當證據。**

**放置規則（三條，都寫在碼裡）**：

1. **在 mode 判定之後**，只擋會外呼的那條路。MININET 沒有東西可打 ⇒ 一個字沒改。
2. **在位址守衛之後**。「沒有管理位址」是模型的缺陷、比較嚴重，它那條邊緣觸發的 WARN
   必須繼續從同一個報告發出來；豁免只決定「模型沒問題之後要不要撥號」。
3. 第 2 處**排在 `SPDLOG_INFO("Getting power report from DPID …")` 之前**：
   宣告一次不會發生的讀取，是 log 停止成為證據的方式。

**回什麼**：四個 map／array 報告回 `kHealthMetricUnavailable`（＝`-1`，手冊 §12／§13 從寫下來
就說它是「查詢失敗或資料不可得」）；**兩個 single-switch 端點另外純新增一個 `exempt` 鍵**，
裡面是一句說清楚的話。那兩個是回答呼叫者（Intent Translator，會把它變成給人看的句子）的端點，
**不是 500、不是「裝置沒回應」**——後者是對一台沒有人嘗試聯絡的機器說謊。

🔴 **為什麼另外四個沒有 `exempt` 鍵**：它們是 map，key 是位址、value 是整數，
**四個外部 app 在讀**。把字串塞進整數欄位正是這個檔案被燙過的傷（`data[ip] + 0`
在交換機 down 掉之前都能用）。⇒ **理由放在 log 與 `get_graph_data` 的 `power_path` 裡**，
這也正是 E-23 與 E-25 是同一張單的原因：**wire 上的記號讓那個 `-1` 讀得懂**。

**log**：一行 INFO，**邊緣觸發**（`m_switchesExemptFromBrandPaths`，形狀與理由完全比照
`noteSwitchMissingManagementIp`）。status worker 每 10 秒跑四個報告，不邊緣觸發就是
**每十秒四行、永遠**（brand 不會變）——那是把 3596 行 sudo 錯誤塞進一次 run 的形狀。
⚠️ **兩個 single-switch 端點刻意不碰那個 set**：它們跑在 HTTP／IntentTranslator 執行緒上，
而那個 set 的執行緒安全前提是「只有 status worker 碰它」。它們每個請求印一行，這不是洪水。

### 2.2 三個傳輸縫（同檔）

「不打」是一個關於**沒有發生的呼叫**的宣稱，唯一能斷言它的方法是**數呼叫**。
六處原本直接呼叫 `utils::execCommand`／`utils::execArgv`／`getPowerReportViaSsh`，
所以測試只能靠「讓單元測試真的去跑 `snmpget` 和 `ssh`」——那什麼也證明不了，而且一格十秒。

```cpp
virtual std::string readFromDevice(const std::string& cmd);                 // utils::execCommand
virtual std::string readFromDeviceArgv(const std::vector<std::string>&);    // utils::execArgv().output
virtual std::string readPowerOverSsh(const std::string& ip, const std::string& user);
```

形狀與理由同兩個 power strategy 的 `executeSystemCommand`：**production 各只有一個實作**，
而且就是原本那個自由函式。

🔴 **三個縫，而 double 必須三個都換。** 這是 `OVSPowerStrategy.hpp` 對 `executeArgvCommand`
給過的同一個警告：只覆寫 `readFromDevice` 的 double 仍然會讓 `getSingleSwitchCpuReport` 的
argv 呼叫與電力報告的 SSH 漏到真機器上，而它報出來的次數會是一個很舒服的謊。

⚠️ **`tests/python/test_shell_command_construction.py` 跟著改了，而且它是自己抓到的。**
那份清冊有一格是 `"std::string snmp_result = utils::execCommand(cmd);"`，**數量 7**——
就是這六處裡的七行。全部改走 `readFromDevice` 之後那一格變 0，而新的
`return utils::execCommand(cmd);` 是一個沒有分類的 shell site ⇒ 預設判為 `REQUEST` ⇒ 紅。
清冊改成一格、數量 1、判 `NUMERIC`，並在原地寫下**為什麼是重新推導而不是繼承**
（七條命令字串逐位元組沒變，變的是誰把字串交給 `/bin/sh`）。
那份檔頭寫著「**a shell site must not be able to leave this list by being renamed**」，
這次就是那句話生效的樣子。

### 2.3 E-25／E-30：記號上 wire（`GraphTypes.hpp`）

- `to_json(json&, const VertexProperties&)` 尾端 **純新增**：
  ```cpp
  if (v.vertexType == VertexType::SWITCH)
  {
      j["power_path"] = v.powerPath;
      j["telemetry_path"] = v.telemetryPath;
  }
  ```
  **只在 switch 節點**，與 `getStaticTopologyJson` 同一條規則：host 沒有 brand、沒有插座、
  沒有 OID，對它發 `none` 會讓人以為**別的** host 可能有路徑。
- 新增 `kPathNone`（`"none"` 的單一來源）與
  `isExemptFromBrandPaths(const VertexProperties&)`（`vertexType == SWITCH && powerPath == kPathNone`）。
  ⚠️ `vertexType` 那一半不是裝飾：`powerPath` 的預設值就是 `"none"`，
  不加的話每個 host 都會回答一個只對交換機有意義的問題。
- `powerPathForBrandName`／`telemetryPathForBrandName` 的 `"none"` 分支改回傳 `kPathNone.data()`
  ——避免第五種拼法。

### 2.4 E-30：載入時一行 WARN（`TopologyAndFlowMonitor.cpp`）

`parseStaticTopologyFile` 尾端、**在 BUG-17／E-26 那兩層資料平面判定之後**：
一份被拒的檔案不能被摘要成好像它要被服務一樣。

```
N switch(es) exempt from power/telemetry (power_path=none): dpid 7 (brand_name "CiscoC9300"). …
```

**零台不印**（每次啟動都印的一行就是沒有人讀的一行）。
**WARN 不是 INFO**：這是模型裡一台這個 twin 讀不到電力與健康的機器。它是**被支援的組態**
（Adam 2026-09-06 讓它變成的），而它同時是一個有洞的 fabric——那是警告形狀的事實。

🔴 **`…NoLock` 這個字尾是承重的**：`parseStaticTopologyFile` 整段持有 `m_graphMutex` 的
`unique_lock`，而那個 mutex **不可重入**——在這裡再拿一次 `shared_lock` 就是啟動時死鎖，
而那正是那個 `unique_lock` 上面的註解記載**已經透過 `findVertexByIp` 發生過一次**的 bug。

### 2.5 契約（`tools/contract_test/spec.py`）— **第六邊**

`GRAPH_NODE` 的 `optional` 加兩欄，並**釘死值域**：
`power_path ∈ {synthetic, snmp, ssh, none}`、`telemetry_path ∈ {snmp, none}`。

**optional 而不是 required，兩個理由而且不是同一個理由**：
① 2026-09-07 之前建的 kernel 兩個都不發，結構檢查必須照樣過（同
`left_link_bandwidth_source`／`telemetry_status` 的規矩）；
② **host 節點永遠不帶**，而這個 schema 會套到 list 裡的每一個節點。

**兩個值域大小不同不是筆誤**：電力有四種機制，健康遙測只有 `snmp` 與 `none`——
軟體交換機沒有溫度計可讀（F-1）。⇒ **`telemetry_path == "none"` 不標記豁免，只有 `power_path` 標記。**

---

## 3. 🔴 baseline（`28b8b13`）怎麼處理 —— Adam 一定會問的那一段

Adam 在 E-25 的白話重講裡自己給了對照：

> `28b8b13` 沒有 `switch_kind`、brand 只是字串、非 HPE 且非 MININET 一律走 Brocade SSH
> ——**baseline 從不對外承認「不會讀」**；W15b 是第一次承認但只有自己聽見；本單讓它上 wire。

拆成三句話，因為它們常被混成一句：

1. **「這個 build 讀不了某些交換機」不是這一週才有的。** baseline 就是這樣：
   `brand_name` 只是一個字串，任何**不是** `HPE5520`、又**不是**在 MININET 下跑的東西，
   都掉進為 Brocade 寫的 `else`。差別只在 baseline **沒有詞彙可以說這件事**——
   圖上沒有欄位、log 裡沒有句子、契約裡沒有值。
2. **W15-2 是第一次承認**：它替這種機器造了 `power_path`／`telemetry_path` 兩個詞，
   但只寫進記憶體和一個少有人讀的端點。**承認了，而只有自己聽得見。**
3. **本單是第一次說出口**：兩個詞上 `/ndt/get_graph_data`、進契約、啟動印一行，
   而且六處**行為上**也停止假裝讀得到。

⇒ **這一單沒有讓 kernel 少收任何一份檔案，也沒有讓任何一台交換機少被管理。**
它讓一件一直為真的事第一次可被觀測。**舊消費者要能忽略新欄位**，而它們可以：
純新增，既有鍵的名字、型別、值一個字沒動。

⚠️ **不要把它說成「新的限制」。** 唯一在行為上改變的是：那六處不再對一台
`power_path == "none"` 的機器發 SNMP／SSH；那些請求本來就沒有人會回答。

---

## 4. 測試與閘門

- **15 支單元測試**：`tests/test_ExemptSwitchIsNotDialled.cpp`。
  六處各一格「不打＋答什麼」、兩格非豁免對照（Brocade 照打）、兩格 MININET widening、
  一格 log 邊緣觸發、一格 `get_graph_data`（switch 帶／host 不帶／Brocade 的值對得上）、
  兩格載入（有豁免印一行、沒有豁免不印）、一格前提（記號真的分得開兩台交換機）。
- 🔴 **記號一律由 `powerPathForBrandName` 推導，從不手寫**。在 fixture 裡寫
  `powerPath = "none"` 會讓整組測試對一個「loader 已經不再設這個欄位」的 build 保持綠——
  那正是這個記號最重要的失效點。載入那一半另外由
  `TheLoadedExemptSwitchIsMarkedAndAnnounced` 用真檔案釘。
- **閘門**：`tests/shell/mutate_exempt_switch_is_not_dialled.sh`。
  M1–M6 六處各拿掉一處、M7／M8 兩個 key 各拿掉一個、M9／M13 啟動那行的兩個方向、
  M10–M12 三個**必須被抓到的 widening**（全部交換機都當豁免／MININET 失去合成值／log 每輪都印）、
  W1–W3 三個必須維持綠的對照。
- ⚠️ **`GraphTypes.hpp` 被 43 個 TU include** ⇒ M7／M8／W1 各觸發一次全樹重編，
  這支閘門因此天生慢。仍然留著：另一種做法是把 wire 格式的閘門放在比「真正決定它的地方」
  更便宜的地方，而那就是閘門開始討好自己的方式。

---

## 5. 沒做的與為什麼

- **MININET 下的豁免沒有短路**。合成電力值是 dpid 的函數、從來不是問機器的問題；
  在那裡短路會拿掉一個真實（雖然是合成的）答案，換不到任何東西。閘門 M11 釘這一格。
- **`switch_kind` 選出來的致動路徑一個字沒動**（`getPowerStrategyForDpid`：
  BMV2 → P4 proxy、OVS 與 HARDWARE → `OVSPowerStrategy`）。E-23 講的是**依 brand 分支**的讀取，
  不是依 `SwitchKind` 派工的開關機。被豁免的交換機**照樣**拿得到它宣告的那條致動路徑。
- **`getStaticTopologyJson`（§38）那段沒動**：它 2026-09-07 起就已經在發這兩個 key 了。
- **沒有 live 驗證**：這一輪一個 kernel 都沒起（lab 空著、不歸這個 session 碰）。
  §1 的 lw17c 是**引用，沒有重跑**。
- **同型盤點沒做**：這個 codebase 還有幾處「寫下一個記號然後沒有人讀」。
  這一單只處理工單點名的這一個。**不宣稱不存在。**

---

## 6. 跟哪些單／文件要一起看

1. 🔴 **依賴鏈**：`fix/w3-door3b-host-empty-ip` → `fix/w15-unknown-brand-rejected`
   → `fix/w15b-switch-kind-exemption` → `fix/bug17-mixed-dataplane-refused` → **本分支**。
   五支都改 `TopologyAndFlowMonitor.cpp` 的同一區，**必須照這個順序併**。
2. `doc/KNOWN-ISSUES.md` 新增 **C-5c**（接在 C-5b 之後）。⚠️ 同一個檔今晚有三支分支各自插條目
   （R2-PY 的 #90／#91、BUG-17 的 C-5／C-5b、本條），**E-27 已裁「知悉，併時照序留兩份」**。
3. `doc/2026-01-02_ndt_api.md` 動了四處：§3 新增〈`power_path` and `telemetry_path`〉小節、
   §6 電力報告、§12 CPU（§13 記憶體與溫度在同一段裡點名）、§38 兩段 `⚠️ Changed 2026-09-07`。
   ⚠️ §38 今晚已經被三支分支動過，併的時候要看那幾處。
4. `tools/contract_test/spec.py` 是**第六邊**：kernel、圖的序列化、電源管理器、啟動那行、手冊，
   加上契約。**只有契約這一邊是外部消費者實際被對照的那一邊**——
   一個 kernel 發明出來、而這裡沒有列的值會在契約跑裡靜靜地過去。
5. **跨 repo（本輪沒開、沒改、沒建）**：`/ndt/get_graph_data` 的節點欄位有四個 app 在讀。
   這一單是**純新增**，所以不需要它們改；但如果要讓 Web-GUI 把 `-1` 顯示成
   「沒人管」而不是「查詢失敗」，那是它們那邊的事。同 W8-6 的形狀。
6. **`tools/contract_test/baseline_diff_allowlist.txt` 不需要改，而理由要寫下來。**
   `compare_baseline.py` 比的是**同一顆二進位**跑 OVS 拓樸與 P4 拓樸各一次的 capture，
   兩邊的 switch 節點都會多出同型別（`str`）的兩個欄位 ⇒ 形狀相同、沒有新的差異。
   ⚠️ **但如果有人拿 2026-09-07 之前存下來的 baseline 去比新的 candidate**，
   會看到 `field missing in OVS: nodes[].power_path`——那是 baseline 過期，不是缺陷。
   重抓 baseline 即可。
