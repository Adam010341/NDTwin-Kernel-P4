# B-2b + B-4：單引號家族 fix design

作業 ID：**B-2b+B-4**（同一家族）
worktree：`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a6f9792013e8d6d7b`（隔離）
分支：**`fix/b-2b-b-4-no-shell-strings`**
狀態：**完成（含 Adam 對 Q1 的裁決：全母體清掃）**。4 個 commit：
`c28a5c29` → `8084c6fc` → `bd823a40` → `051faf12`。**未 push**，工作樹乾淨。

⚠️ **§2 的母體數字是錯的，正確版在 §9.0**（漏了兩個裸 `popen(`）。看 §9 的表，不要看 §2.5 的。

🔴 **一句話的交付範圍**：機制建好、三個請求可控的注入點搬完、B-2b 的誤指與 B-4 的早退都修了；
**Python 守衛測試過了變異閘（先紅後綠）**，但 **C++ 的部分從未編譯、從未看過紅**
——依專案守則那一半**不算交付**，細節在 §5.3 與 §6。

---

## 1. Base 驗證

worktree 初始 HEAD 是 `f5db629b update sleeping time`（＝ brief 預期的 `origin/main` 上游狀態，不是指定 base）。
依 brief 第 0 節 detach 到指定 commit：

```
$ git checkout --detach 4cbec52d45bd85e0e972110e35f51693d6ce137f
HEAD is now at 4cbec52d Keep the one line that names the restore failure
$ git log --oneline -1
4cbec52d Keep the one line that names the restore failure
```

交叉檢查（實際執行，非轉述）：

```
$ sed -n '593p' doc/KNOWN-ISSUES.md
### B-2b 🔴 一個單引號讓 kernel 指控一個健康的元件 —— 而且訊息與真實故障無法區分
$ sed -n '758p' doc/KNOWN-ISSUES.md
### B-4 模擬案例：任一欄位含單引號 → 回 202 但請求從沒送出
```

兩行都吻合 ⇒ **base 正確**，往下進行。

---

## 2. 機制

### 2.0 共同的底層：`utils::execCommand` 就是一個 `/bin/sh -c`

`include/utils/Utils.hpp:544-567`：

```cpp
FILE* pipe = popen(cmd.c_str(), "r");     // :548
```

`popen()` 的語意是 `execl("/bin/sh", "sh", "-c", cmd, ...)`。⇒ **每一個走 `execCommand` 的呼叫點，
它的字串都是 shell 程式碼，不是命令列。** 同一個標頭自己的 `@warning`（`:540-541`）就寫著
「Do not pass untrusted input into cmd unless properly escaped/sanitized」——而下面三個呼叫點
全部傳的是 untrusted input，全部沒有 escape。

而且 `execCommand` **只回傳 stdout**（`:553-556` 只讀 pipe），`pclose` 的 rc 只印到 `std::cerr`
（`:558-566`）**不回傳給呼叫端**。⇒ 呼叫端在型別上沒有能力分辨「命令沒跑成」與「命令跑了但沒輸出」。
**這是 B-2b 誤指健康元件的直接成因**，見 2.1。

### 2.1 B-2b：引號 → shell 語法錯誤 → 「對方沒回應」

**引號從哪裡進來**：北向 flow-entry 請求的 `match`／`actions` JSON
⇒ `FlowDispatcher` ⇒ `HttpRoutingStrategyBase::installAnEntry/deleteAnEntry/modifyAnEntry`
（`src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:150-229`）⇒ `post()`（`:74`）。

**怎麼被內插**（`src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:82-84`）：

```cpp
cmd << "curl -s -w '\\n%{http_code}' --max-time " << REQUEST_TIMEOUT_SECONDS
    << " -X POST http://" << apiUrl() << path
    << " -H \"Content-Type: application/json\" -d '" << body.dump() << "'";
```

🔑 **為什麼 `dump()` 擋不住**：`nlohmann::json::dump()` 逃脫的是 **JSON** 的元字元（`"`、`\`、控制字元）。
**`'` 在 JSON 裡不是元字元**，所以 `dump()` **原樣輸出**它——它做對了它的工作，只是那份工作
與 shell 無關。「已經 dump 過了所以安全」是這一族最容易犯的誤讀。

**失敗鏈**：`'` 關掉 `-d '` 開的引號 ⇒ `/bin/sh` 語法錯誤 ⇒ **curl 從沒被 exec** ⇒
sh 把 `Syntax error` 寫到 **stderr**（`popen(…, "r")` 不捕捉）⇒ `execCommand` 回傳**空字串**。

**為什麼歸咎到錯的元件**（同檔 `:19-42`／`:88-101`）：

| 步驟 | 位置 | 發生什麼 |
|---|---|---|
| 1 | `:88` | `output` == `""` |
| 2 | `:21-26` | `find_last_of('\n')` == npos ⇒ `return {output, 0}` |
| 3 | `:91` | `status == 0` |
| 4 | `:93-95` | `OpResult::unreachable("no response from " + describe() + " at " + apiUrl() + " within 5s")` |

而 `status == 0` **同時**是 curl 連不上時 `%{http_code}` 回 `000` 的結果（`:17` 註解自承）。
⇒ **兩個成因在 `:91` 合流成同一個判決**。控制器真的死了、和我送了一個壞字串，
產出**逐字相同**的一行——這正是 KNOWN-ISSUES 說的「把除錯的人送去錯的地方」。

🔑 **鑑別資訊是存在的，只是被丟掉了**：`pclose` 的 rc（sh 語法錯誤 = exit 2）足以分辨這兩件事，
但 `execCommand` 只把它印到 cerr（`Utils.hpp:558-566`）。**誠實修法必須把它帶回呼叫端**，
而不是只換一個訊息字串。

### 2.2 B-4：引號 → 202 Accepted 但請求沒送出

**路由**：`src/ndt_core/http/HttpSession.cpp:244-246` ⇒ `handleReceivedSimulationCase`（`:1339`）。

| 步驟 | 位置 | 發生什麼 |
|---|---|---|
| 1 | `:1348` | `validateRequestBody()` —— **只驗形狀**（五個欄位都在、都是 string），引號照過 |
| 2 | `:1359` | `requestSimulation(m_req.body())` ——傳的是**原始 body 字串**，不是重新序列化的 |
| 3 | `SimulationRequestManager.cpp:124-125` | `curl -s -X POST "<URL>" -H "…" -d '<body>'`，字串內插 |
| 4 | `SimulationRequestManager.cpp:127` | `execCommand` ⇒ popen ⇒ sh 語法錯誤 ⇒ 回傳 `""` |
| 5 | `HttpSession.cpp:1361` | **`res.result(http::status::accepted)` 無條件執行**——`resp` 從頭到尾沒被檢查 |
| 6 | `HttpSession.cpp:1363` | `std::string("{\"status\":\"") + resp + "\"}"` ⇒ 回 `{"status":""}` |

**吞掉的位置精確在 `:1359-1361` 之間**：`requestSimulation` 回傳 `std::string`，
而那個型別**無法表達失敗**（見 2.0）；即使它能，`:1361` 也沒有看它。
回應裡**沒有 id**，所以呼叫端事後也查不到。⇒ 失效方向＝**靜默**。

📌 **`:1363` 是同一站點的第二個缺陷、KNOWN-ISSUES 沒寫**：`{"status":"…"}` 是**手工串接的 JSON**，
`resp` 是 curl 的原始輸出、未跳脫。模擬伺服器只要回一個含 `"` 或換行的 body，
**kernel 的 202 回應本身就是壞掉的 JSON**。與引號家族同形（手工組字串 vs. 用函式庫），
所以一併修。

### 2.3 第三站：`onSimulationResult`，同形且更糟

`SimulationRequestManager.cpp:150-153`（`POST /ndt/simulation_completed` ⇒
`HttpSession.cpp:1391` 呼叫 `onSimulationResult`）：同樣的 `-d '<body>'` 內插，
但跑在 **detached thread** 裡（`SimulationRequestManager.cpp:140` 的 `std::thread(...).detach()`），
結果只進 log；`HttpSession.cpp:1393-1395` 已經無條件回了 `200 {"status":"result forwarded"}`。
⇒ B-4 的失效形狀在這裡是**結構性的**（非同步），不只是「忘了看回傳值」。

### 2.4 B-2b 與 B-4 是同一個根嗎？

**不是同一個 helper，是同一個構造。** 三個站點各自獨立地把結構化的值（JSON）
攤平成 shell 程式碼，然後交給同一個 `/bin/sh`。共用的元件只有 `utils::execCommand`——
而它**本身沒有錯**，錯的是「拿它當 HTTP client」這個決定。

⇒ **修法不是修一個函式，是引入一個缺席的機制**（argv 執行器），再把站點搬過去。
這與 KNOWN-ISSUES 兩處註解「不要零星加消毒」一致：**逐點加跳脫**才是錯的，
**逐點改用 argv** 是正確的搬遷方式，因為它在那一點**移除 shell**、不是「防禦」shell。

### 2.5 同構站點全表（本輪逐一開檔確認）

#### (a) 把**請求可控**的 JSON body 內插進單引號 —— B-2b/B-4 的本體，共 3 處

| # | file:line | 內插的值 | 來源 |
|---|---|---|---|
| 1 | `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:82-84` | `body.dump()` | 北向 flow-entry 的 match／actions |
| 2 | `src/ndt_core/application_management/SimulationRequestManager.cpp:124-125` | 原始 request body | `POST /ndt/received_a_simulation_case` |
| 3 | `src/ndt_core/application_management/SimulationRequestManager.cpp:150-151` | 原始 request body | `POST /ndt/simulation_completed` |

#### (b) 走 shell、但內插的是設定／拓樸值 —— 同構造，可達性較低

⚠️ **先講清楚母體怎麼數的**，因為 KNOWN-ISSUES 自己記載「原文那個 14 是用什麼母體數的，
本輪查不出來」。**手數會再錯一次**，所以這裡給的是**可重跑的指令**：

```
grep -rn "utils::execCommand(\|std::system(\|executeSystemCommand(" \
     --include=*.cpp --include=*.hpp src/ include/
```

在 `4cbec52d` 上的結果（扣掉 seam 的宣告與定義本身）：

- **`utils::execCommand` 的呼叫點 19 個**：`HttpRoutingStrategyBase.cpp:70`、
  `SimulationRequestManager.cpp:127`／`:153`、`TopologyAndFlowMonitor.cpp:493`、
  `FlowLinkUsageCollector.cpp:2528`，以及 **`DeviceConfigurationAndPowerManager.cpp` 的 14 個**
  （`:228`、`:326`、`:500`、`:953`、`:967`、`:1055`、`:1297`、`:1386`、`:1554`、`:1568`、
  `:1631`、`:1716`、`:1816`、`:1828`）
- **`executeSystemCommand` 的呼叫點 5 個**：`OVSPowerStrategy.cpp:85`／`:142`、
  `P4PowerStrategy.cpp:83`／`:121`／`:190`（兩者的實作都是 `std::system`）
- **直接 `std::system` 5 個**：`ApplicationManager.cpp:253`／`:279`／`:309`／`:321`／`:436`
  （其中 `:253`／`:279`／`:436` 是**常數字串**，不在本族）

⇒ **29 個 shell 執行點**，其中帶非常數字串的是 26 個。

📌 **「14」的來歷，一個有證據的假說（標為假說，不是結論）**：
`DeviceConfigurationAndPowerManager.cpp` 的 `execCommand` 呼叫點**恰好是 14 個**，
而該檔 `:579` 自己的註解寫著「**13 snmpget/snmpwalk sites that reach it through execCommand**」
（`Utils.hpp:415` 有同一句）。13 個 snmp ＋ `:1386` 的 relay ＝ **14**。
⇒ 原文的 14 很可能是**這一個檔案**的呼叫點數，被寫成了「南向 curl 呼叫點」。
**這仍然是推測**——但它是一個**可以被否證**的推測，而原文那個數字不是。

**建構點（把非常數值攤進 shell 字串的地方）**，本族關心的是這些：

| # | file:line | 執行器 | 內插的值 | 可控性 |
|---|---|---|---|---|
| 4 | `SimulationRequestManager.cpp:124` | `execCommand` | `SIM_SERVER_URL`（**雙引號內**） | 設定 |
| 5 | `SimulationRequestManager.cpp:150` | `execCommand` | `apiUrl`（**雙引號內**） | 🔴 **北向可控**，見 2.6 |
| 6 | `TopologyAndFlowMonitor.cpp:475`（`buildTopologyFetchCommand`，執行在 `:493`） | `execCommand` | url | 設定 |
| 7 | `FlowLinkUsageCollector.cpp:2524`（執行在 `:2528`） | `execCommand` | `controlPlaneHostAndPort()` | 設定 |
| 8 | `DeviceConfigurationAndPowerManager.cpp:225`（執行在 `:228`） | `execCommand` | `GW_IP` ＋ relay 參數 | 設定 |
| 9 | `DeviceConfigurationAndPowerManager.cpp:823`／`:838`／`:851` | `execCommand` | proxy ip/port、dpid | 設定 |
| 10 | `DeviceConfigurationAndPowerManager.cpp:1386`（`buildRelayPowerCommand`） | `execCommand` | `GW_IP`、switch index、action | 設定 |
| 11 | `DeviceConfigurationAndPowerManager.cpp` 的 13 個 snmp 建構點 | `execCommand` | community string、OID、IP | 設定 |
| 12 | `P4PowerStrategy.cpp:83`／`:190` | `std::system` | `swName`，**且前綴 `sudo -n`** | 拓樸（`bridgeNameForMininet`，來自控制平面回報的拓樸，見下） |
| 13 | `P4PowerStrategy.cpp:121` | `std::system` | proxy ip/port、dpid | 設定 |
| 14 | `OVSPowerStrategy.cpp:85`／`:142` | `std::system` | bridge 名等，**且前綴 `sudo`** | 拓樸 |
| 15 | `ApplicationManager.cpp:197`（`buildUnexportCommand`）／`:219`（`buildExportsPurgeCommand`），執行在 `:309`／`:321` | `std::system` | `folder`，**且前綴 `sudo`** | 設定（`m_nfsExportDir` ＋ 整數 appId） |

📌 **#12 的可控性本輪查到一半就停**：`swName` 來自
`DeviceConfigurationAndPowerManager.cpp:1455` 的 `g[node].bridgeNameForMininet`，
不是北向 `set_device_name` 寫的 `deviceName`（那是另一個欄位）。
⇒ **不是直接請求可控**，但它的值來自控制平面回報的拓樸 JSON，**而那不是可信輸入**。
`sudo -n` 前綴讓這一格的後果比其他格嚴重。**本輪未追到拓樸解析端，標為未完成。**

⚠️ **本輪自己在這張表上犯過一次這一族的錯，記下來**：初稿把
`TopologyAndFlowMonitor.cpp:567` 列為執行點。開檔一看，那是一行
**log 訊息裡建議操作者手動執行的 curl**（`SPDLOG_LOGGER_WARN` 的格式字串），
不是被執行的東西。⇒ **`grep "curl"` 的命中數不等於執行點數**，
這正是原文那個 14 數不回來的同一種失誤。

⚠️ **#15 值得單獨看一眼**：`buildExportsPurgeCommand`（`ApplicationManager.cpp:202-220`）
**做了 BRE 跳脫（`.*[]^$\/`）但沒有做 shell 跳脫**，而結果被放進 `'…'` 裡。
`'` 不在那份跳脫表中 ⇒ **一個做了跳脫的地方，跳脫的是錯的那一層**。
今天 `folder` 是 `m_nfsExportDir + "/" + to_string(appId)`（`ApplicationManager.cpp:51`），
appId 是 `int` ⇒ **目前不可從請求觸發**。但這是這一族最好的教學範例：
**「有跳脫」不等於「跳脫了會被解讀的那一層」。**

#### (c) 手工串接 JSON（同族的另一半：不用函式庫組結構化輸出），共 23 處

`src/ndt_core/intent_translator/IntentTranslator.cpp` 的 `:280`、`:289`、`:293`、`:295`、
`:303`、`:308`、`:312`、`:314`、`:353`、`:383`、`:413`、`:575`、`:596`、`:687`、`:697`、
`:703`、`:739`（兩個欄位）、`:770`、`:813`、`:829`、`:838`、`:1038`，
以及 `src/ndt_core/http/HttpSession.cpp:1363`。

🔑 **同一個檔案裡兩種寫法並存**：`IntentTranslator.cpp:235-265`
（`switchNotFoundReply`／`powerReply`／`:255`）**用 `json{...}.dump()` 做對了**，
其餘 22 處手工串接。⇒ 這不是「還沒學會」，是**已經有正確做法但沒有被貫徹**。
含 `"` 或反斜線的 `deviceName`／`host_id`／`formType` 會產出**壞掉的 JSON 回應**。

#### (d) Python proxy：**不在這一族裡**（本輪查核結果）

`grep -rn "subprocess|os.system|shell=True|popen|check_output|Popen" p4_proxy/ --include=*.py`
在 `proxy_agent/` 底下**零命中**；命中的只有 `mininet/*_topo.py`（實驗腳本，`sudo mn -c`／
`sudo pkill -f`，常數字串）與 `tests/`。`api_routes.py` 全程用 FastAPI ＋ `JSONResponse`，
沒有手工 JSON、沒有 shell。
⇒ **B-2b／B-4 是純 kernel 側缺陷，proxy 不涉入。** brief 把 `api_routes.py` 列為線索，
本輪的答案是「查過了，乾淨」。

### 2.6 🔴 注入嚴重度判定：**是命令注入，不是引號 bug**

問題「攻擊者能不能透過 API 執行任意命令」的答案是 **能**。四個環節逐一在本輪親自開檔確認：

| # | 環節 | 本輪確認的位置 |
|---|---|---|
| 1 | 北向監聽 `0.0.0.0:8000`，**無認證** | `ControllerAndOtherEventHandler.cpp:90` `tcp::endpoint{tcp::v4(), NDT_PORT}`；`NDT_PORT 8000` 在 `ControllerAndOtherEventHandler.hpp:37`。`HttpSession.cpp` 內 `grep Authorization` 只命中 **CORS 標頭白名單**（`:127`），**沒有任何驗證** |
| 2 | 請求欄位流進 shell 字串 | 2.1／2.2 兩條鏈 |
| 3 | `dump()` 不跳脫 `'` | 2.1 |
| 4 | `popen` ⇒ `/bin/sh -c` | 2.0 |

**最短路徑（推理自碼，本輪未建置、未執行、未發送任何請求）**：
`POST /ndt/received_a_simulation_case`，五個必填欄位都給字串（通過 `:1348` 的形狀驗證），
其中任一個內容形如 `x'; <command>; echo '` ⇒ `-d 'x'; <command>; echo ''`
⇒ `<command>` 以 kernel 的 uid 執行。

🔴 **本輪新發現、KNOWN-ISSUES 未記載的一條，而且它比上面那條更難防：**
`app_register` 的 `simulation_completed_url`（`HttpSession.cpp:1489` 取值、
`:1492` 存進 `ApplicationManager`）之後被內插進
`SimulationRequestManager.cpp:150` 的 **雙引號** 裡：

```cpp
cmd << "curl -s -X POST \"" << apiUrl << "\" " ...
```

**雙引號內 `$(...)` 與反引號仍會被 shell 展開。**
⇒ 這條路徑**一個引號都不需要**。任何「拒絕 `'`」的輸入過濾都擋不住它，
而那正是最可能被順手加上的「修法」。
⇒ **本條是「不要零星加跳脫」這個既有規則的獨立證據**：
零星修法會照著已知的字元表做，而這條不在那張表上。

**嚴重度**：未認證遠端命令執行（RCE）。與 KNOWN-ISSUES 2026-08-28 增補的判定一致，
本輪**加一條新的入口**與**「不需要引號」這個新性質**。

### 2.7 KNOWN-ISSUES 對帳

| 條目所寫 | 本輪（`4cbec52d`）觀察 | 判定 |
|---|---|---|
| B-2b：`HttpRoutingStrategyBase::post` 把 `body.dump()` 內插進單引號、註解自承 | `:76-84`，註解在 `:77-81` | ✅ 仍然成立 |
| B-2b：status 0 ⇒ `no response from <component>` | `:91-95` | ✅ 仍然成立、逐字相同 |
| B-2b：`utils::execCommand` 用裸 `popen()` | `Utils.hpp:548` | ✅ 仍然成立 |
| B-2b：北向 `0.0.0.0` | `ControllerAndOtherEventHandler.cpp:90`（條目寫的是同名檔在 `event_handler/`，**實際路徑是 `event_handling/`**） | ✅ 成立，**目錄名需更正** |
| B-2b：「11 個走 `execCommand` 的 curl 構造點」 | 條目列的 `TopologyAndFlowMonitor.cpp:472/485/498` 現在只對應**一個**構造點（`:475`，執行在 `:493`）；`FlowLinkUsageCollector.cpp:2496` ⇒ **`:2524`**；`DeviceConfigurationAndPowerManager.cpp:222/820/835/848` ⇒ **`:225`／`:823`／`:838`／`:851`**。**`execCommand` 的呼叫點總數是 19**（見 2.5(b) 的可重跑指令） | ⚠️ **行號全數漂移，且 11 這個數也數不回來**。本輪改為給**指令**不給數字 |
| B-2b：「原文那個 14 是用什麼母體數的，本輪查不出來」 | `DeviceConfigurationAndPowerManager.cpp` 的 `execCommand` 呼叫點**恰好 14 個**，且該檔 `:579` 註解寫「13 snmpget/snmpwalk sites」＋ relay 1 個 | 🆕 **提供一個可否證的假說**（見 2.5(b)） |
| B-2b：第 12 個走 `std::system`（`P4PowerStrategy.cpp:82`） | 現在是 **`:83`**，且**還有 `:190`（powerOff）與 `:121`** ⇒ 該檔 **3 處**不是 1 處 | ⚠️ **低估**：條目只記了 powerOn 那一支 |
| B-2b：`validateRequestBody()` 只檢查形狀 | `SimulationRequestManager.cpp:53-108`，`HttpSession.cpp:1348` | ✅ 仍然成立 |
| B-4：內插逐字在 `SimulationRequestManager.cpp:124-125`，第二處在 `:150-151` | ✅ 兩處都在，行號**精確吻合** | ✅ 仍然成立 |
| B-4：回 `202 {"status":""}` | `HttpSession.cpp:1361-1363` | ✅ 仍然成立 |
| — | **`HttpSession.cpp:1363` 手工串接 JSON**（見 2.2） | 🆕 **條目未記載** |
| — | **`app_register` 的 URL ⇒ 雙引號注入，不需引號**（見 2.6） | 🆕 **條目未記載** |
| — | **`IntentTranslator.cpp` 22 處手工 JSON**（見 2.5(c)） | 🆕 **條目未記載** |
| — | **`ApplicationManager` 跳脫了 BRE 但沒跳脫 shell**（見 2.5(a) #15） | 🆕 **條目未記載** |

⚠️ 上述全部是**讀碼**（2026-08-31／09-02，基準 `4cbec52d`）。**本輪沒有建置、沒有執行 kernel、
沒有發送任何請求**，所以「會發生什麼」的每一句都是從碼推論，不是實測。

---

## 3. Fix 設計

### 3.1 一句話

**引入缺席的機制（argv 執行器），把三個站點搬過去；再把「沒送出」與「對方沒回」拆成兩個判決。**
不是加跳脫——KNOWN-ISSUES 兩處註解都明文反對，而 2.6 給了它們為什麼對的**具體證據**
（雙引號那條路徑不需要引號，任何字元黑名單都會漏掉它）。

### 3.2 新機制：`utils::execArgv`（`include/utils/Utils.hpp`）

```cpp
struct CommandOutcome { std::string output; bool ran; int status; bool succeeded() const; };
CommandOutcome execArgv(const std::vector<std::string>& argv);   // fork + execvp，無 shell
std::string    describeArgv(const std::vector<std::string>& argv); // 只給人看，明確不是 quoter
```

三個設計決定，各自有理由：

1. **`fork` + `execvp`，不是 `posix_spawn`／不是 `popen`。**
   child 在 `fork()` 與 `execvp()` 之間**只呼叫 async-signal-safe 的函式**，
   `char*` 陣列在 fork **之前**就建好——因為這個 kernel **會從執行緒裡 fork**
   （`SimulationRequestManager` 有 detached thread）。碼裡寫了這個約束。
2. **回傳 `CommandOutcome` 不是 `std::string`。**
   `ran` 就是 B-2b 一直握在手裡卻丟掉的鑑別資訊。**它刻意不是「exit 0」**——
   curl 遇到 HTTP 404 時 exit 22，那叫做**跑得很好**。
3. **`describeArgv` 命名為 describe 不是 join。**
   它的輸出**不能**餵回 shell（含空格的參數不會 round-trip）。
   名字本身就是防止下一個人把它當成命令列的護欄，並有測試釘住這件事。

⚠️ **`execArgv` 沒有取代 `execCommand`**——`execCommand` 留著，但加了
「**不要新增呼叫點**」的 `@warning`，並由 Python 測試的 ratchet 執行。

### 3.3 B-2b 的誠實修法（兩層，缺一不可）

**第一層（移除 shell）** `HttpRoutingStrategyBase.cpp:109-121`：`post()` 改建 argv。
引號現在會被**送到控制器**，不再讓命令列爆炸 ⇒ 那個失效模式**不存在了**，不是被改名。

**第二層（把合流的判決拆開）** —— 這一層**不是**移除 shell 附帶送的，必須另外做：

| 情況 | 舊 | 新 | HTTP |
|---|---|---|---|
| fork 失敗／curl 沒裝 | `unreachable("no response from <component>…")` | `notSent("this kernel could not run curl, so the <component> … was never asked: …")` | **500** |
| curl 沒寫 status line | 同上（無法區分） | `notSent("curl produced no status line …")` | **500** |
| curl 回 `000`（真的連不上） | 同上（無法區分） | `unreachable("no response from <component>…")` **不變** | 0 ⇒ 502 |

實作上靠兩個東西：`CommandOutcome::ran`，以及新增的
`CurlOutput::statusLinePresent`（`HttpRoutingStrategyBase.cpp:26-57`）。
🔑 **`statusLinePresent` 為什麼可靠**：`-w '\n%{http_code}'` 的輸出
**curl 只要跑完就一定會寫**，包含連線失敗（寫 `000`）。所以「沒有 status line」
是「curl 自己沒跑完」的可靠訊號。舊碼把這兩件事都塞進 `{output, 0}`（`:25`／`:39`），
**那一行就是誤指健康元件的機械原因**。

**狀態碼的選擇**：`notSent` 用 **500 不用 0**。因為 `httpStatus == 0` 會讓
`noResponse()` 為真，而 `HttpSession.cpp:801-803` 把它映成 **502 Bad Gateway**
——「閘道壞了」正是要收回的那句指控。500 走既有的 `400..599` 直通分支（`:805-807`），
**`HttpSession` 一行都不用改**。

### 3.4 B-4 的修法

1. **argv 化**（`SimulationRequestManager.cpp:165-177`／`:242-254`）。
2. **加 `-w '\n%{http_code}'` 與 `--max-time 30`。**
   ⚠️ **原本兩個 curl 都沒有任何 timeout**——`--max-time` 與 `--connect-timeout` 都沒有。
   拓樸輪詢與 routing strategy 早就修過同一個缺陷，**只剩這條路徑沒修**。本輪順手補上。
3. **`requestSimulation` 回傳型別從 `std::string` 換成 `Dispatch`**
   （`sent` / `answered` / `httpStatus` / `response` / `failureReason`）。
   `sent` 與 `answered` **分開存不用推導**，因為呼叫端要在 500 與 502 之間選，
   而「從空字串推導」正是當初把兩者搞混的做法。
4. **202 只在模擬伺服器回答之後才送**（`HttpSession.cpp:1381-1412`）：

| 情況 | 新 HTTP | body |
|---|---|---|
| 沒送出去 | **500** | `{"status":"error","error":"Simulation case was not accepted","details":…}` |
| 送出去但沒人回 | **502** | 同上，details 說明是 simulator 沒回 |
| simulator 拒絕（非 2xx） | **原樣透傳** | 含 `simulator_status`、`simulator_response` |
| simulator 接受 | **202** | `json{{"status", response}}.dump()` |

5. **手工 JSON 換成函式庫**：`std::string("{\"status\":\"") + resp + "\"}"`
   ⇒ `json{{"status", dispatch.response}}.dump()`。

### 3.5 被否決的替代方案

| 方案 | 為什麼否決 |
|---|---|
| **在呼叫點加 shell 跳脫**（`'` ⇒ `'\''`） | KNOWN-ISSUES 兩處明文反對；且 2.6 證明它會**漏掉雙引號那條路徑**（`$(...)` 不需要引號）。而且它讓其餘站點看起來已被處理 |
| **在 `validateRequestBody` 拒絕含引號的欄位** | 既有測試的註解就預先反對過。`inputfile` 是**路徑**，路徑可以合法含引號 ⇒ 會拒絕今天會動的輸入；而且**保護不到 `match` 那條路徑**（不同的驗證函式） |
| **修 `execCommand` 讓它自己跳脫** | 它收到的是**已經組好的一整條 shell 程式碼**，此時已無從得知哪幾段是資料。訊息在進入它之前就丟失了 |
| **加 `executeArgv` 多載、保留 `executeCommand`** | 🔴 **最危險的那個。** 測試的 `RecordingStrategy` 會繼續編譯、繼續 override 一個沒人呼叫的函式 ⇒ **測試改成真的去打 localhost:8080 而且照樣綠**。改名讓它變成**編譯錯誤**。見 MEMORY `existence-is-not-wiring` |
| **一次搬完全部 26 個站點** | 不能建置的情況下，26 個站點的盲改是不可驗證的風險；而且其餘站點內插的是**設定值**不是請求欄位。改為：機制建好、三個請求可控的站點搬完、其餘用 ratchet 測試釘住不准增加 |
| **用 `posix_spawn`** | 可行且更短，但 fork/exec 讓「child 只能做 async-signal-safe 的事」這個約束**寫得出來也讀得到**。這個 codebase 的風格是把約束寫進碼裡 |

### 3.6 受影響的呼叫端（普查過，不是假設）

| 被改的東西 | 呼叫端 | 處理 |
|---|---|---|
| `HttpRoutingStrategyBase::executeCommand` ⇒ `executeArgv` | **唯一的 override 在 `tests/test_RoutingStrategies.cpp:53`** | 同一個 commit 改掉 |
| `requestSimulation` 回傳型別 | **唯一呼叫端 `HttpSession.cpp:1359`** | 同一個 commit 改掉 |
| `OpResult::notSent`（新增） | 無既有呼叫端 | — |
| `OpResult` 的解讀 | `HttpSession.cpp:797-812`、`Controller.cpp:69`、`DispatchOutcomeLog.hpp:119`、`IntentTranslator.cpp:261` | **都不用改**：500 走既有的 `400..599` 分支 |
| `utils::execCommand` | 16 個呼叫點 | **一個都沒動** |

⚠️ **一個既有測試的期望被反轉了，這件事要講清楚**：
`test_RoutingStrategies.cpp` 的 `HandlesOutputWithNoStatusLine` 原本斷言
`EXPECT_TRUE(r.noResponse())`——**那個期望本身就是 B-2b**：
「curl 沒跑」被記錄成「控制器沒回應」。**測試把缺陷釘在原地，而且看起來像覆蓋率。**
現在斷言相反的事，並在碼裡留下這段來歷。

---

## 4. Patch

```
$ git log --oneline -2
8084c6fc Keep the source guard's failure readable when the executor is gone
c28a5c29 Give the kernel a way to run a command without writing shell code

$ git show --stat c28a5c29
 .../SimulationRequestManager.hpp                   |  74 +++++++-
 .../routing_management/HttpRoutingStrategyBase.hpp |  27 ++-
 include/ndt_core/routing_management/OpResult.hpp   |  22 +++
 include/utils/Utils.hpp                            | 194 +++++++++++++++++++++
 .../SimulationRequestManager.cpp                   | 179 +++++++++++++++++--
 src/ndt_core/http/HttpSession.cpp                  |  56 +++++-
 .../routing_management/HttpRoutingStrategyBase.cpp | 111 +++++++++---
 tests/CMakeLists.txt                               |   2 +
 tests/python/test_shell_command_construction.py    | 181 +++++++++++++++++++
 tests/test_ExecArgv.cpp                            | 170 ++++++++++++++++++
 tests/test_RoutingStrategies.cpp                   | 127 +++++++++++++-
 tests/test_SimulationRequestValidation.cpp         |  41 +++--
 12 files changed, 1108 insertions(+), 76 deletions(-)
```

分支：detached HEAD on `4cbec52d`（隔離 worktree）。**沒有 push。**
commit 用逐檔 pathspec（12 個檔案全部列出，沒有用目錄）。

---

## 5. 測試證據

### 5.1 🟢 可執行、已過變異閘：`tests/python/test_shell_command_construction.py`

**這是唯一在「不准建置」下能真的跑的東西，而它是原始碼掃描，不是行為測試。**
綠燈的意思是「產生 B-2b／B-4 的那個構造不在樹上」，**不是**「注入被修好了」。
這個窄度是刻意的，寫在檔頭。

四個測試：`no_source_builds_a_curl_body_inside_single_quotes`（禁止 `-d '` 構造）、
`execCommand_call_sites_do_not_grow`（ratchet ≤ 16）、
`the_argv_executor_exists_and_does_not_use_a_shell`（釘住替代品本身存在且真的不走 shell）、
`the_simulation_case_reply_is_not_built_by_concatenation`。

**變異閘（先紅後綠，rc 都是不經 pipe 直接取的）**：

```
# RED —— 把四個原始碼檔還原成未修版本（測試檔留著）
$ git checkout 4cbec52d -- include/utils/Utils.hpp \
      src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp \
      src/ndt_core/application_management/SimulationRequestManager.cpp \
      src/ndt_core/http/HttpSession.cpp
$ python3 tests/python/test_shell_command_construction.py -v
   ... FAIL / FAIL / FAIL / FAIL          ← 四個全紅
   Exit code 1
```

紅的內容是實際命中，不是空斷言：

- `-d '` 命中 **3 處**：`SimulationRequestManager.cpp:125`／`:151`、`HttpRoutingStrategyBase.cpp:84`
- `execCommand` 呼叫點 **19 > 16**
- `HttpSession.cpp:1363: std::string bodyStr = std::string("{\"status\":\"") + resp + "\"}";`
- `execArgv` 不存在

```
# GREEN —— 還原修法
$ git checkout HEAD -- <同四個檔>
$ python3 tests/python/test_shell_command_construction.py
   Ran 4 tests in 0.011s / OK             ← rc 0
```

📌 **這一輪自己也吃了一次教訓，記下來**：第一次跑的時候
`the_simulation_case_reply_is_not_built_by_concatenation` **在修好的樹上就是紅的**——
因為它命中了**解釋這個修法的那行註解**。⇒ 加了 `_is_comment()` 過濾。
**一個禁止「描述」缺陷的守衛，會逼下一個人刪掉解釋。**

### 5.2 🟡 迴歸：`tests/python/` 全套

```
$ python3 -m unittest discover -s tests/python -p 'test_*.py'
Ran 336 tests in 59.583s
FAILED (errors=1, skipped=27)
```

**唯一那個 error 與本修法無關、且先前就存在**：`test_sflow_stats_endpoint.py:22`
`ModuleNotFoundError: No module named 'fastapi'`——系統 python3 沒有 fastapi
（那個檔本輪未修改）。其餘 **335 綠**。
⚠️ `skipped=27` 未逐一查因（見 §6）。

### 5.3 🔴 **UNVERIFIED —— C++ 測試從未被編譯，更沒看過紅**

`tests/test_ExecArgv.cpp`（9 個測試，新檔，已註冊進 `tests/CMakeLists.txt`）與
`tests/test_RoutingStrategies.cpp` 新增的 2 個測試：

> **NOT COMPILED。沒有跑過。沒有看過紅。依專案的變異閘標準，這兩者都不算交付。**

理由是 brief 的硬性限制（量測窗開著，不准建置）。**這不是「應該會過」的意思**：
一份沒編譯過的 C++ patch，語法錯誤的機率不是零。已知的具體風險列在 §6。

C++ 測試涵蓋的性質（**設計意圖，非已驗證事實**）：

| 測試 | 釘住什麼 |
|---|---|
| `PassesAnArgumentThroughUnchangedNoMatterWhatIsInIt` | 惡意字串原樣通過 ⇒ 沒有東西在解析它 |
| `KeepsArgumentsSeparateEvenWhenTheyContainSpacesAndQuotes` | 參數邊界沒有被壓平再切開 |
| `DoesNotInterpretShellMetacharactersInAnyPosition` | 含 `$(id)`、反引號、`\|`、`*`、換行——**刻意包含不需引號的那些** |
| `ReportsThatItRanEvenWhenTheProgramFailed` | `ran` ≠ `succeeded`（curl 對 404 exit 22） |
| `ReportsExitOneTwentySevenWhenTheProgramIsNotThere` | curl 沒裝 ⇒ 不可報成「元件沒回應」 |
| `CapturesLargeOutputWithoutTruncatingOrDeadlocking` | 200 kB > 64 kB pipe 容量 ⇒ 手寫 read loop 的兩個經典死法 |
| `RunsAShellOnlyWhenTheCallerNamesOneAsTheProgram` | 逃生門是**決定**不是意外 |
| `AQuoteInAMatchValueIsSentAsDataAndDoesNotBreakTheRequest` | B-2b 的注入面 |
| `ARequestThatNeverRanDoesNotAccuseTheController` | B-2b 的誠實面：**兩個判決互相比較**，不比對固定字串 |

---

## 6. 未驗證 / 需要人做的事

**按風險排序。**

1. 🔴 **編譯。** 整個 C++ patch 沒有經過編譯器。量測窗關掉之後第一件事就是
   `cmake --build` ＋ 跑 `test_routing_strategy`。**已知的具體風險**：
   - `HttpRoutingStrategyBase.hpp` 新增 `#include "utils/Utils.hpp"`
     ⇒ 把 boost（asio/beast/ssl/url）拉進每個 include 它的 TU。**編譯時間會變長**；
     若有循環 include 會在這裡爆。
   - `SimulationRequestManager::REQUEST_TIMEOUT_SECONDS` 是 `static constexpr int`；
     C++17 起隱含 inline，**若本專案的標準低於 C++17 會出現 undefined reference**（未查證標準版本）。
   - `res.result(static_cast<http::status>(dispatch.httpStatus))` 沿用既有寫法
     （`HttpSession.cpp:807` 一模一樣），但模擬伺服器回一個 Beast 不認識的碼時行為未驗。
2. 🔴 **變異閘。** C++ 測試**沒看過紅**。要補：把 `execArgv` 換回 `execCommand`
   應該讓 `AQuoteInAMatchValue…` 紅；把 `notSent` 換回 `unreachable`
   應該讓 `ARequestThatNeverRan…` 紅。**兩顆都殺過才算交付。**
3. 🟠 **`-w` 加在模擬 curl 上改變了 202 的 body。**
   舊：`{"status":"<curl 原始輸出>"}`；新：`{"status":"<回應 body，已剝掉 status 行>"}`。
   **本輪沒有找到 `received_a_simulation_case` 的消費端**（Energy-Saving-App 是否讀
   這個 body 未查）。若有消費端在讀 `status` 字串，這是一個**契約變更**。
4. 🟠 **`--max-time 30` 是我挑的，沒有量測支撐。** 模擬案例可能跑很久——
   但這是 curl 的**回應**逾時，不是模擬本身的執行時間（伺服器應該立刻回 202/200 再非同步跑）。
   **若模擬伺服器是同步回覆的，30 秒會太短，而後果是本來會成功的請求變成 502。**
   這一條需要知道 Simulation-Platform-Manager 的行為才能定，**我不知道**。
5. 🟡 **`onSimulationResult` 的 200 仍然是早退的。** argv 化與 log 誠實化都做了，
   但那條路徑是 detached thread、HTTP 回應早就送出去了。
   **真正的修法需要一個可查詢的 job id**，是設計變更，不在本 patch。
6. 🟡 **其餘 23 個走 shell 的建構點沒動**（2.5(b)），只被 ratchet 釘住不准增加。
7. 🟡 **`IntentTranslator.cpp` 的 22 處手工 JSON 沒動**（2.5(c)）。
   **同一個檔案裡已經有正確做法**（`:235-265`），所以這是低風險的機械活。
8. 🟡 **`tests/python` 的 `skipped=27` 沒有逐一查因。**
   依 MEMORY「skipped 會報成 passing」，這 27 個應該有人看一眼。
9. 🟡 **`P4PowerStrategy` 的 `swName`**（2.5(b) #12）追到 `bridgeNameForMininet` 就停了，
   **沒有追到拓樸解析端**。它前面有 `sudo -n`。
10. ⚪ **完全沒有 live 驗證**：沒有跑 kernel、沒有發請求、沒有碰 lab。
    「一個引號現在會被送到控制器」是**讀碼推論**。

---

## 7. 給 Adam 的未決問題（每題附後果）

### Q1. 其餘 23 個 shell 建構點怎麼辦？（**這題最需要裁**）

| 選項 | 後果 |
|---|---|
| **(a) 建議：本輪停在這裡**，ratchet 守住不增加，另開工單分批搬 | 三個請求可控的站點已無注入；其餘內插設定值，遠端不可達。**但 KNOWN-ISSUES 的「一次做完」沒有做完**，而且 `sudo` 前綴那幾個（`ApplicationManager`、`OVS`／`P4PowerStrategy`）後果最重 |
| (b) 本輪一次搬完 26 個 | 盲改（不能編譯）26 個站點。**風險與這個 patch 不成比例**，且其中 13 個 snmp 站點我完全沒讀過它們的語意 |
| (c) 只再搬 `sudo` 那 4 個 | 後果最重的先處理。但 `ApplicationManager` 的 `folder` 目前不可從請求觸發 ⇒ 收益是「防未來」不是「堵現在」 |

### Q2. `--max-time 30` 對模擬伺服器夠嗎？

- **(a) 建議：先確認 Simulation-Platform-Manager 是同步還是非同步回覆再定。**
  我沒有這個資訊，30 是猜的。
- (b) 先放大到 300 秒 —— 安全但把「掛住一個 HttpSession thread」的窗開回 5 分鐘。
- (c) 拿掉 timeout —— 回到修法前的狀態，**不建議**（那正是 A-2 修過的缺陷形狀）。

### Q3. 202 的 body 形狀變了（§6.3），要不要保持相容？

- **(a) 建議：先查有沒有消費端**（我沒查到，但也沒證明沒有）。R-1 那一輪的
  `PRE-ROUND-R1-determination.md` 就是用「七個 repo 掃過沒有消費端」來判 UNTESTABLE 的，同一招可用。
- (b) 保留舊形狀（把 status 行一起放回字串）—— 相容，但把剛修好的「回應是合法 JSON」又弄回去。
- (c) 直接改，記進 contract spec。

### Q4. 這個 patch 要不要現在就進 `trunk`？

- **(a) 建議：不要，等編譯 ＋ 變異閘。** 依專案守則「測試沒看過紅就不算交付」，
  本 patch 的 C++ 部分**明確不符**。
- (b) 先進，因為它堵的是未認證 RCE —— 可以理解，但一個編譯不過的 commit 擋住所有人。

### Q5. `IntentTranslator.cpp` 的 22 處手工 JSON 算不算這一族？

- **(a) 建議：算，但另立條目。** 同一個「不用函式庫組結構化輸出」的根，
  後果不同（壞掉的回應 vs. 命令執行）。
- (b) 併入 B-2b —— 會讓一個 RCE 條目混進 22 個外觀缺陷，**稀釋嚴重度**。

📌 **Q1 與 Q5 已由 Adam 裁決：全掃完才能併，且 22 處 JSON 一併處理。見 §9。**

---

## 9. 全面清掃（Adam 對 Q1 的裁決：全掃完才能併）

分支：`fix/b-2b-b-4-no-shell-strings`（自 `8084c6fc` 建立）。
commit `bd823a40` ＋ `051faf12`。**未 push。** 工作樹乾淨。

### 9.0 🔴 先講一件事：§2 的母體是錯的

§2.5 用的 grep 是 `utils::execCommand|std::system|executeSystemCommand`，得到 26 個點，
而我當時把它當成完整母體。**它不完整**：

| 漏掉的 | 為什麼漏 |
|---|---|
| `src/ndt_core/power_management/OVSPowerStrategy.cpp:34`（`executeListPorts`） | **直接呼叫 `popen(`**，不經過任何具名 helper |
| `include/utils/SSHHelper.hpp:52`（`getPowerReportViaSsh`） | 同上 |

⇒ 真實母體是 **28 個執行點、20 條相異原始碼行**。

🔑 **可轉移的形式**：`grep` 的完整性上限＝**你想到的拼法的聯集**。
「我 grep 過了」不是「這個類別不存在」的證據。這正是 MEMORY 那條
「grep 給不完整答案的九種漏法」——而我在同一份文件裡一邊引用它、一邊犯了它。
兩個漏掉的點**都不是請求可控**，所以結論沒變——**但那是運氣，不是方法。**

### 9.1 判準

| 判定 | 意思 | 處置 |
|---|---|---|
| `CONSTANT` | 字串常值，沒有內插 | 留 |
| `CONFIG` | `AppConfig` 或磁碟上的靜態拓樸 JSON | 留 |
| `NUMERIC` | 由整數重新算繪出來的文字（`ipToString(uint32)`、`to_string(dpid)`） | 留 |
| `SEAM` | 收到已組好的字串，分類看它的呼叫端 | 留 |
| `REQUEST` | 能從 HTTP 請求帶任意位元組進來 | **必須遷** |

🔑 **`NUMERIC` 是這次最有用的一格**：它不問「值從哪來」，問「值**能不能**含元字元」。
一個從請求來的 IP，只要中間被 `ipStringToUint32` → `ipToString` 走過一趟，
就**結構上**不可能帶 `'`。這比追來源省事、而且更可靠。

### 9.2 全表

**A. 已遷到 `execArgv`（Y）**

| # | file:line（遷移前） | 什麼請求可控的字串會到 shell | 處置 |
|---|---|---|---|
| 1 | `HttpRoutingStrategyBase.cpp:82-84` | flow-entry 的 `match`／`actions`（北向 body） | **Y**（前一輪） |
| 2 | `SimulationRequestManager.cpp:124-125` | `received_a_simulation_case` 原始 body | **Y**（前一輪） |
| 3 | `SimulationRequestManager.cpp:150-151` | `simulation_completed` body ＋ `app_register` 的 URL | **Y**（前一輪） |
| 4 | `DeviceConfigurationAndPowerManager.cpp:807-830`（`buildRelayPowerCommand`），執行在 `:1386` | **`action`** ＝ `POST /ndt/set_switches_power_state` 的 query 參數（`HttpSession.cpp:712`） | **Y** |
| 5 | `DeviceConfigurationAndPowerManager.cpp:1814-1816`／`:1826-1828`（`getSingleSwitchCpuReport`） | `deviceIdentifier`（該函式自己的 `std::string` 參數） | **Y** |
| 6 | `ApplicationManager.cpp:197`（`buildUnexportCommand`），執行在 `:309` | 無（`m_nfsExportDir` ＋ 整數） | **Y**，理由見 9.3 |
| 7 | `ApplicationManager.cpp:219`（`buildExportsPurgeCommand`），執行在 `:321` | 無（同上） | **Y**，理由見 9.3 |

⚠️ **#4 與 #5 本來就不可利用，而兩者的「安全」都是偶然的**：

- #4 的 `action` 在到 `popen` 前被比對過 `{"on","off"}` **兩次**
  （`HttpSession.cpp:714`、`DeviceConfigurationAndPowerManager.cpp:1371`）
  ⇒ 防護是「兩個 call frame 之外的二元白名單」，不是本地性質。
- #5 的 `deviceIdentifier` 只有在 `utils::ipToString(vp.ip.front()) == deviceIdentifier`
  成立時才走到 shell（`:1784-1785`）⇒ **那是一個查表迴圈的副作用**，二十行外，
  沒有任何標記說它承重。**把那個 `==` 換成任何更寬鬆的比對，
  就會把「查表變寬」變成「shell injection」，而且無聲。**

**B. 留在 `execCommand`／`std::system`／`popen`（N，附理由）**

| # | file（行為） | 判定 | 到 shell 的是什麼 |
|---|---|---|---|
| 8 | `ApplicationManager.cpp:260` `exportfs -ra && systemctl reload` | `CONSTANT` | 字串常值。`&&` 是呼叫端真的要的 shell 語法，兩邊都是常值 |
| 9-10 | `ApplicationManager.cpp:286`／`:447` `sudo exportfs -ra` ×2 | `CONSTANT` | 字串常值 |
| 11 | `FlowLinkUsageCollector.cpp:273` `sudo ovs-vsctl list interface` | `CONSTANT` | 字串常值 |
| 12 | `DeviceConfigurationAndPowerManager.cpp:634` `sudo ovs-vsctl list-br 2>/dev/null` | `CONSTANT` | 字串常值 |
| 13 | `FlowLinkUsageCollector.cpp:2528` | `CONFIG` | `controlPlaneHostAndPort()` ⇒ `AppConfig::{P4_PROXY,RYU}_IP_AND_PORT`（`:216`／`:218`） |
| 14 | `TopologyAndFlowMonitor.cpp:493` | `CONFIG` | `"http://" + AppConfig::… + 常值路徑`；timeout 是 `constexpr int` |
| 15 | `DeviceConfigurationAndPowerManager.cpp:500` | `CONFIG` | `buildSwitchStateCommand(AppConfig::P4_PROXY_IP_AND_PORT)` |
| 16 | `DeviceConfigurationAndPowerManager.cpp:1067` | `CONFIG` | `buildFlowStatsCommand(AppConfig 常數, uint64 dpid)` |
| 17 | `DeviceConfigurationAndPowerManager.cpp:228`（relay 狀態 GET） | `CONFIG` | `GW_IP`（AppConfig）、`si.plugIp`（靜態拓樸 JSON）、`si.plugIdx`（`int`）。**請求自己的 `ip=` 只當查表鍵**（`:210`），不進命令 |
| 18-24 | `DeviceConfigurationAndPowerManager.cpp` snmpget／snmpwalk ×7 | `NUMERIC` | community string 與 OID 寫死；唯一變數是 `ip_str = utils::ipToString(vp.ip.front())` |
| 25 | `DeviceConfigurationAndPowerManager.cpp:326`（`pingSwitch`） | `NUMERIC` | 唯一呼叫端傳 `utils::ipToString(ip)`（`:691`）；timeout 是 `to_string(int)` |
| 26 | `OVSPowerStrategy.cpp:34`（`executeListPorts`，**裸 popen**） | `CONFIG` | `bridgeNameForMininet`，來自磁碟上的靜態拓樸檔 |
| 27 | `OVSPowerStrategy.cpp:85`／`:142` | `CONFIG` | `swName`（同上）、`port`（**本機自己的 `ovs-vsctl list-ports` 輸出**）、dpid 十六進位 |
| 28 | `P4PowerStrategy.cpp:83`／`:190` `sudo -n <helper> on\|off <swName>` | `CONFIG` | `kPowerHelper` 是 `constexpr`；`swName` 同上 |
| 29 | `P4PowerStrategy.cpp:121` readopt curl | `CONFIG` | `AppConfig::P4_PROXY_IP_AND_PORT` ＋ `to_string(dpid)` |
| 30 | `OVSPowerStrategy.cpp:15`／`P4PowerStrategy.cpp:28` `std::system(cmd)` | `SEAM` | 收到已組好的字串；分類看上面的呼叫端 |

**C. 無法遷（附原因）**

| # | file:line | 為什麼 |
|---|---|---|
| 31 | `include/utils/SSHHelper.hpp:52`（`getPowerReportViaSsh`） | 命令是 **shell pipeline**：`(echo …; sleep 1; echo …) \| ssh …`。拿掉 shell＝改成餵 ssh 的 stdin ⇒ **重新設計、不是替換**。輸入是 `NUMERIC`（`ipToString`）＋常值 `"admin"`，所以不急 |
| 32 | `include/utils/Utils.hpp:750` | `utils::execCommand` 本體，就是那個 `/bin/sh` |

📌 **`bridgeNameForMininet` 查證結果（我原本以為是控制平面回報的）**：
它只在 `TopologyAndFlowMonitor.cpp:294` 由**磁碟上的靜態拓樸 JSON** 指派，**沒有任何 HTTP setter**
——`modify_device_name` 寫的是 `deviceName`（不同欄位，`TopologyAndFlowMonitor.cpp:1933`），
而 `VertexProperties` 的 `from_json`（`GraphTypes.hpp:316-332`）根本不含這個欄位。
⇒ §2.5(b) #12 標的「拓樸」應更正為 **CONFIG**。

**D. 同一個錯誤指向 JSON（非 shell）**

`IntentTranslator.cpp` 的 **22 處**手工串接全部改成 `json{...}.dump()`。
`deviceName` 來自 LLM，而 LLM 吃的是 `POST /ndt/intent_translator/text` 的文字 ⇒ **請求可影響**。
剩下 **8 處**（`return "{\"error\": \"Task cast failed\"}"` 之類）**沒有內插**、是恆定合法的 JSON，
刻意不動。

📌 **這個檔案自己早就知道**：`:230-233` 的註解寫著「json{}.dump() is used rather than the
string concatenation the DISABLE/ENABLE cases above use」——**點名了受影響的 case，然後留著**。
而測試只測 renderer，測不到那 22 處。

### 9.3 為什麼 `ApplicationManager` 那兩個「不是請求可控」卻還是遷了

這是本輪**唯一**違反「不要為改而改」的地方，理由必須寫清楚：

`buildExportsPurgeCommand` 對 `.*[]^$\/` 做了 **BRE 跳脫**——對 sed 的 address 語法**完全正確**。
然後把結果放進 `'...'`，交給 `std::system`。
⇒ 它**同時跨兩層**（sed 與 shell），而 `'` 兩張表都不在：
對 BRE 它不是元字元（正確），對 shell 它是（沒人考慮）。

🔑 **「有跳脫」不等於「跳脫了會被解讀的那一層」。**
一個瞄準錯層的跳脫**比沒有跳脫更糟**，因為它讓讀碼的人以為這裡處理過了。
改成 argv 之後**只剩 sed 一層**，既有的跳脫剛好正確。**沒有加任何東西，是移除了一層。**
兩個命令都跑在 `sudo` 底下，這是加碼的理由。

### 9.4 統計

| | 數 |
|---|---|
| 本輪掃描時樹上的 shell 執行點 | **28**（20 條相異原始碼行） |
| **本輪遷走** | **4**（#4 relay、#5 兩個 snmpget、#6/#7 兩個 sudo）⇒ 涵蓋 5 個舊執行點 |
| 前一輪已遷走 | **3**（#1-#3） |
| **留下（N，附理由）** | **21** |
| **無法遷（附原因）** | **2** |
| **剩餘 `REQUEST` 判定** | **0** |
| 額外：JSON 手工串接遷移 | **22**（另 8 處常值刻意不動） |

⚠️ **21 ＋ 2 ＝ 23**，是今天樹上仍走 shell 的點；另外 5 個舊點已成 argv 呼叫。
28 − 5 ＝ 23 ✓。**這個數字必須能被重數**，所以判準與清單放在測試裡，不是只放在這裡
——KNOWN-ISSUES 的 14 與 11 就是因為只放在文件裡而數不回來。

### 9.5 測試證據

**`tests/python/test_shell_command_construction.py`（4 → 7 個測試）**

核心設計：`SHELL_SITES` 是全母體＋每點判定；`_verdict_for()` 對**不認識的點回傳 `REQUEST`**
⇒ **新增一個 shell 呼叫而不寫下它吃什麼，測試就紅。未分類＝推定有罪。**

鍵用**原始碼行文字**不用行號：行號會因無關改動漂移，訓練人「改數字不讀內容」；
行文字只在**那一行被改時**才變，而那正是需要重新分類的時刻。帶 count，因為同一個檔案裡
有 7 行長得一模一樣。

**變異閘（rc 皆不經 pipe 直接取）**：

```
# RED —— 把六個被掃的原始碼檔 stash 回掃描前
$ git stash push -- <6 files>
$ python3 tests/python/test_shell_command_construction.py -v
  test_intent_replies_are_not_built_by_concatenation ............ FAIL
  test_the_sudo_nfs_commands_are_argument_vectors ............... FAIL
  test_no_shell_site_is_reached_by_a_request_controlled_string .. FAIL
  test_the_site_inventory_matches_the_classification ............ FAIL
  FAILED (failures=4)     ← 4/7 紅；另 3 個是前一輪已 commit 的，正確地維持綠
```

紅的內容是**具名的實際命中**，不是空斷言：

- 未分類 ⇒ 推定 `REQUEST`：
  `interpretRelayResponse(utils::execCommand(buildRelayPowerCommand(GW_IP, si, action)));`、
  `unexportWhy = describeCommandFailure(std::system(cmd.c_str()));`、
  `sedWhy = describeCommandFailure(std::system(sedCmd.c_str()));`
- 數量對不上：`std::string snmp_result = utils::execCommand(cmd);` **classified 7, found 9**
  （多的 2 個正是 `getSingleSwitchCpuReport` 的那兩個）

```
# GREEN
$ git stash pop
$ python3 tests/python/test_shell_command_construction.py
  Ran 7 tests in 0.042s / OK          ← rc 0
```

**迴歸**：`python3 -m unittest discover -s tests/python -p 'test_*.py'`
⇒ `Ran 339 tests` / `FAILED (errors=1, skipped=27)`。
唯一 error 仍是既有的 `test_sflow_stats_endpoint.py:22 ModuleNotFoundError: fastapi`
（本輪未改該檔）。

**🔴 C++ 測試一樣 NOT COMPILED、沒看過紅。** 本輪新增 3 個，
每個都在註解裡寫了 **「WHICH LINE MAKES THIS RED」**：

| 測試 | 檔案 | 復原哪一行會紅 |
|---|---|---|
| `ADeviceNameContainingAQuoteCannotInjectKeysIntoADisableReply` | `test_IntentTaskOutcomes.cpp` | `IntentTranslator.cpp` DISABLE_SWITCH 的 `return "{\"error\": \"Switch not found\", …" + disableTask->deviceName + …` |
| `AHostileActionValueStaysInsideOneArgument` | `test_RelayResponse.cpp` | `buildRelayPowerCommand` 的 `cmd << … << "&method=" << action << "\"";`（連同 `std::string` 回傳型別） |
| `AFolderContainingASpaceStaysOneArgument` | `test_ApplicationManager.cpp` | `buildUnexportCommand` 的 `return "sudo exportfs -u " + folder;` |

### 9.6 本輪新增的「未驗證」項（接續 §6）

11. 🔴 **`buildRelayPowerCommand`／`buildUnexportCommand`／`buildExportsPurgeCommand`
    改了回傳型別**，8 個測試呼叫點被改（5 個包成 `utils::describeArgv(...)`）。**全部沒編譯過。**
    `describeArgv` 以空白 join，我逐一確認過既有的 `find()` 斷言
    （`-X POST`、`%{http_code}`、`--max-time`、`ip=`、`index=`、`method=`、`resource=outlet`）
    在 join 後仍成立——**但那是讀出來的，不是跑出來的。**
12. 🟠 **`IntentTranslator` 的 22 處改動改變了輸出的空白**
    （`{"error": "X"}` ⇒ `{"error":"X"}`）。既有測試都用 `json::parse` ＋ `.value()` 所以不受影響，
    **但 repo 外的消費端（Web-GUI）若在比對字串就會壞。未查證。**
13. 🟡 **`ApplicationManager.hpp` 的類別註解仍寫著舊的 issue #2 措辭**（部分已改），
    以及 `test_ApplicationManager.cpp:1` 的檔頭仍說「what std::system()'s return value is taken to
    mean」——**描述已經只對一半**。未改，因為那是文字不是行為。

📌 **原本我打算把 `purgeSurvivors` 的編譯錯誤留給編譯器發現**（它做
`std::system(cmd.substr(5))`，而回傳型別已變成 vector）。**那是錯的**：它會讓整個
`test_routing_strategy` target 編不起來。已在 `051faf12` 修掉，改成 `argv.erase(argv.begin())`
＋ `utils::execArgv`。**知道會壞而留給別人踩，不叫計畫。**

### 9.7 §2 需要更正的兩處

| §2 寫的 | 更正 |
|---|---|
| 母體 26 個執行點（2.5(b) 的 grep） | **28 個**，漏了兩個裸 `popen(` |
| `bridgeNameForMininet` 標為「拓樸（控制平面回報）」（2.5(b) #12） | **CONFIG**：只由磁碟上的靜態拓樸 JSON 指派（`TopologyAndFlowMonitor.cpp:294`），無 HTTP setter |
