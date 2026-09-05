# W6／OV-2＋OV-3：查不到的東西被翻譯成別的東西

工單：`scratch/overnight-2026-09-04/recon/fixplan.md` §W6。
修的人：夜巡「修法 agent」session，worktree `wt-integrate`。日期：2026-09-04。

[Co-developed with claude code -- Adam]

---

## 1. 一句話結論

兩個缺陷共用一個形狀：**「我不認得這個識別碼」被翻譯成別的東西**——
一個翻成**伺服器故障**（OV-2：未知 IP → 500），一個翻成**零**（OV-3：未知 dpid → 200 ＋ 0）。
修法是在兩處各加一次**與正確答案那一側完全相同的查找**：
OV-2 用 `DeviceConfigurationAndPowerManager::knowsSwitchIp()`（新增，把 GET 那側已經在做的查找抽出來），
OV-3 用 `TopologyAndFlowMonitor::getSwitchKind()`（既有，`install_flow_entry` 對同一個問題已經在用）。

## 2. 座標（🟢 全部自己開檔核對過，對 trunk `f943de8f`）

### OV-2

| 位置 | 內容 |
|---|---|
| `src/ndt_core/http/HttpSession.cpp:189-192` | 路由（`POST`／`starts_with`） |
| 同上 `:861` | `handleSetSwitchesPowerState` |
| 同上 `:869-874` | 既有的 400 守衛（`ip.empty()` 或 action 不是 on/off）——**它不驗 IP 是不是已知的 switch** |
| 同上 `:876-885` | 🔴 缺陷本體：`bool ok = …setSwitchPowerState(ip, action); … else internal_server_error` |
| 同上 `:841` `:846-857` | **對照組**：GET 那側 catch `std::runtime_error` → 404 ＋ `{"error": e.what()}` ＋ WARN |
| `DeviceConfigurationAndPowerManager.cpp:421-426` | GET 在 MININET 丟的那個 throw（`findSwitchByIp` → `"Unknown switch IP"`） |
| 同上 `:304-308` | TESTBED 版（`switchSmartPlugTable` 的 `find_if`） |
| 同上 `:1961-1967`（trunk 行號） | `setPowerStateMininet` 找不到節點就 `return false`，**無 log、無理由** |
| 同上 `:1889/:1908/:1922/:1953` | 🔴 **四條真的是 500 的 `return false`**：action 不認得、relay 不接受、vertex 不見、例外 |

### OV-3

| 位置 | 內容 |
|---|---|
| `HttpSession.cpp:310-319` | 兩條路由 |
| 同上 `:2274` `:2313` | `handleGetTotalInputTrafficLoadPassingASwitch`／`handleGetNumOfFlowsPassingASwitch` |
| 同上（修法前）`:2317-2331` | 🔴 缺陷本體：`int numOfFlows = 0;` → `if (e.dstDpid == dpid)` → 回 200 ＋ 初值 |
| 同上 `:2300-2308`／`:2332-2339` | 缺 `dpid` 的 400（**這條已經對了，沒有動；閘門 M6 守著它**） |
| `TopologyAndFlowMonitor.hpp:307` / `.cpp:2242` | `getSwitchKind(uint64_t) -> std::optional<SwitchKind>`（`shared_lock` ＋ hash 查找，**不複製圖**） |
| `TopologyAndFlowMonitor.hpp:302-304` | 它的 Doxygen 已經寫著這兩個端點違反的那條契約 |
| `HttpSession.cpp:1280-1302` | `install_flow_entry` 對**同一個問題**早就回 404，措辭沿用它的 |

## 3. 根因

**OV-2**：handler 把下游**所有**失敗原因塌縮成一個 `bool`。
「這個 IP 不是我認得的交換機」（客戶端錯誤）與「繼電器不接受」（伺服器錯誤）在那個 bool 裡沒有差別。
而 GET 那側對同一個問題用的是**例外**，所以答案是 404——**兩個 handler 各寫一份查找，答案就分岔了**。

**OV-3**：🔴 **根本沒有一個查找會失敗。** dpid 只被當成 edge 掃描裡的比較運算元，
不存在的 dpid 誰都不匹配，累加器停在初值。
⇒ `424242` 與「一台真的但沒流量的交換機」在回應上**完全不可分辨**。

## 4. 修法

### OV-2：新增 `knowsSwitchIp`，而不是放寬那個 bool

`include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp`（宣告）
＋ `.cpp`（定義）：依模式分岔到**GET 那側自己在用的那個查找**
（TESTBED → `switchSmartPlugTable` 的同一個述詞；其餘 → 同一支 `findSwitchByIp`）。
handler 在 400 守衛之後、呼叫 manager 之前問一次，不成立就 404 ＋ **與 GET 一字不差的 `Unknown switch IP`**。

🔴 **為什麼不就地放寬那個 bool**：`setPowerStateTestbed` 另有**四條真的是 500** 的 `return false`。
把它們一起放寬，等於把四個真故障重新標成「查無此機」——**反方向的缺陷，而且更難發現**。
閘門的 M2 就是那個變異，由 `ARealPowerFailureIsStillA500` 抓。

### OV-3：兩個 handler 各加一次 `getSwitchKind(dpid).has_value()`

不成立回 404，body 帶 `unknown_dpids` 與 `detail`，**措辭沿用 `install_flow_entry:1288-1302`**。
🔴 **雙胞胎各改各的、閘門也各給一個變異**（M3／M4）：
一個變異涵蓋兩支，會被「只測了其中一支」的測試滿足——那正是複製貼上缺陷活下來的方式。

## 5. 🔴 我改了兩支既有測試的期望值（200 → 404）

**改測試期望值是最容易把缺陷合法化的動作**，所以逐字留紀錄。

| 原本 | 位置 | 它斷言什麼 |
|---|---|---|
| `LockEndpointTest.TotalInputTrafficLoadWithADpidStillAnswers200` | `tests/test_HttpSessionStatusCodes.cpp:608`（trunk） | 空圖 ＋ `{"dpid":1}` ⇒ **200 ＋ `status == success`** |
| `LockEndpointTest.NumOfFlowsWithADpidStillAnswers200` | 同上 `:618` | 同上 |

它們自己的註解寫著：*"The graph is empty, so the answer is zero, but the status is what is under
test here."* ⇒ **那就是把缺陷寫成了規格**：空拓樸裡 dpid 1 不是交換機，
它們斷言的正是 OV-3 被開單的那個答案。

**改之前先證明它們是綠的**（我的指令要求，也是這一節存在的理由）：

```
$ sha256sum build/bin/test_routing_strategy | cut -c1-16
d05cd399683d8a24
$ ./build/bin/test_routing_strategy --gtest_filter='LockEndpointTest.TotalInputTrafficLoadWithADpidStillAnswers200:LockEndpointTest.NumOfFlowsWithADpidStillAnswers200:LockEndpointTest.*WithoutADpid*'
[ RUN      ] LockEndpointTest.TotalInputTrafficLoadWithoutADpidIsABadRequestNotA200
[       OK ] LockEndpointTest.TotalInputTrafficLoadWithoutADpidIsABadRequestNotA200 (0 ms)
[ RUN      ] LockEndpointTest.NumOfFlowsWithoutADpidIsABadRequestNotA200
[       OK ] LockEndpointTest.NumOfFlowsWithoutADpidIsABadRequestNotA200 (0 ms)
[ RUN      ] LockEndpointTest.TotalInputTrafficLoadWithADpidStillAnswers200
[       OK ] LockEndpointTest.TotalInputTrafficLoadWithADpidStillAnswers200 (0 ms)
[ RUN      ] LockEndpointTest.NumOfFlowsWithADpidStillAnswers200
[       OK ] LockEndpointTest.NumOfFlowsWithADpidStillAnswers200 (0 ms)
[  PASSED  ] 4 tests.
```

⚠️ **口徑**：那顆 binary 是**這棵工作樹 14:30 建的**（我這一輪開工時就在 `build/bin/`），
不是我為了這件事重建的一顆。我開工後只 commit 過 shell／doc（W7、W4），沒有動過 C++，
但**我沒有辦法逐位元證明 14:30 那次建置與現在的原始碼完全相同**——
那是為了不多花一次 30 分鐘的全樹重編所做的取捨，寫在這裡讓讀的人自己判斷。
**補強證據**：閘門的 M3／M4 把檢查拿掉之後（＝改動前的行為），新的 404 測試逐一變紅
——那就是「未修的碼確實回 200」的獨立證明。

**它們原本的職責沒有被丟掉**：那兩支存在的理由是「別讓『一律 400』滿足上面兩支缺 dpid 的測試」。
這個職責移到了 `KnownSwitchEndpointTest.AKnownButIdleSwitchStillAnswersZero`——
它問的是**真的在拓樸裡**的 dpid，要求 200 ＋ 0。
**兩對合起來才是「零與不存在可分辨」**，任何一對單獨都說不出這句話。

同時收緊了 `tools/contract_test/spec.py`：
`get_num_of_flows__unknown_dpid` 從 `expect_status=[200, 400, 404]` 改成 `[404]`
（三個都收＝無論 kernel 回哪個它都同意），並補上一支從來不存在的雙胞胎
`get_total_input_traffic_load__unknown_dpid`。
⚠️ **修法之前的 kernel 從此在這條檢查上判紅——那是刻意的。**
`tests/python/test_contract_spec.py` 141 支全綠（`python3 tests/python/test_contract_spec.py`）。

## 6. 測試

進既有的 `tests/test_HttpSessionStatusCodes.cpp`（不開新檔）。三個 fixture：

- `LockEndpointTest`（既有，**空圖**）——所有 dpid 都是未知的，兩支 404 測試放這裡。
- `KnownSwitchEndpointTest`（新增）——🔴 **必須載入一份拓樸**：`getSwitchKind` 的答案來自
  `m_dpidToSwitchKind`，而**全 repo 只有載入器（`TopologyAndFlowMonitor.cpp:689`）會寫它**。
  用 `LoadingMonitor` 開放 protected 的 `loadStaticTopologyFromFile`（抄
  `test_TopologyInputValidation.cpp` 的接縫），以 TESTBED 模式載入
  `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`（**只讀**），dpid 1–10 因此為已知。
- `PowerStateEndpointTest`（新增）——手工建一個 graph switch（`192.168.123.1`／dpid 1）
  ＋一個真的 `DeviceConfigurationAndPowerManager`。
  🔴 **不起執行緒、不碰機器**：建構子只建兩個 power strategy、`start()` 從沒被呼叫，
  而失敗那支停在 `getPowerStrategyForDpid` 回 `nullptr`——**在任何指令被組出來之前**。
  今晚實驗室有別的角色在用，這一點不可協商。

| 測試 | 斷言 |
|---|---|
| `SetSwitchesPowerStateWithAnUnknownIpIsA404NotA500` | 404 ＋ `error == "Unknown switch IP"`（**與 GET 那側同一句**） |
| `SetSwitchesPowerStateWithAKnownIpStillReachesTheManager` | 對照：已知 IP **不是** 404 |
| `ARealPowerFailureIsStillA500` | 🔴 鑑別力：已知 IP ＋ 下游失敗 ⇒ **仍然 500** |
| `SetSwitchesPowerStateWithABadActionIsStillA400` | 新的 404 沒有搶在既有的 400 前面 |
| `NumOfFlowsForAnUnknownDpidIsA404NotAZero` | 404、body 帶 `unknown_dpids:[1]`、**且不帶 `num_of_flows`** |
| `TotalInputTrafficLoadForAnUnknownDpidIsA404NotAZero` | 同型（**且不帶 `total_input_traffic_load_bps`**） |
| `AKnownButIdleSwitchStillAnswersZero` | 🔴 對照：真的存在但沒流量 ⇒ **200 ＋ 0**（兩個端點都測） |

「拒絕的 body 不可以同時帶一個數字」那兩條是刻意的：
一個 404 帶著 `"num_of_flows": 0`，對只讀 body 的客戶端來說**還是給了一個量測值**。

## 7. 閘門

`tests/shell/mutate_unknown_identifier_is_not_zero.sh`——6 變異＋2 對照，只 mutate `HttpSession.cpp`。
log：`scratch/overnight-2026-09-04/fix/W6-gate.log`。

| # | 變異 | 必死測試 |
|---|---|---|
| M1 | OV-2 的 404 前置檢查拿掉 | `SetSwitchesPowerStateWithAnUnknownIpIsA404NotA500` |
| M2 | 🔴 過度：所有 power 失敗都回 404 | `ARealPowerFailureIsStillA500` |
| M3 | OV-3 的檢查拿掉（num_of_flows） | `NumOfFlowsForAnUnknownDpidIsA404NotAZero` |
| M4 | 同上（traffic load）——雙胞胎各一個 | `TotalInputTrafficLoadForAnUnknownDpidIsA404NotAZero` |
| M5 | 🔴 過度：條件反過來（已知的才 404） | `AKnownButIdleSwitchStillAnswersZero` |
| M6 | 缺 dpid 的 400 改成 404 | `NumOfFlowsWithoutADpidIsABadRequestNotA200`（既有測試） |
| C1 | 對照：`json::object({…})` 寫成 `json{…}` | 留綠 |
| C2 | 對照：`has_value()` 寫成 `== std::nullopt` | 留綠 |

⚠️ `HttpSession.cpp` 是 ~1.6 GB 的 TU ⇒ 每個變異重編一次、重連一顆 230 MB 的 binary。
變異數壓在 8 個以內就是為了這件事，而**每一次 build 都走 `guarded_build.sh`＋`JOBS=1`**
（閘門自己包了，**不要再從外面包一層**，會與自己的鎖對死）。
🔴 **兩個 handler 是複製貼上的雙胞胎**，`if (!…getSwitchKind(dpid).has_value())` 在檔案裡出現兩次
⇒ 每個碰它們的 anchor 都是多行、而且帶著**那一支自己的 log 訊息行**，唯一性斷言就下在那一行。

### 看紅（逐字，把修法拿掉之後在同一顆 binary 上跑的）

**OV-2**（把 404 前置檢查換成 `if (false)`）：

```
[ RUN      ] PowerStateEndpointTest.SetSwitchesPowerStateWithAnUnknownIpIsA404NotA500
tests/test_HttpSessionStatusCodes.cpp:826: Failure
Expected equality of these values:
  res.result_int()
    Which is: 500
  404u
    Which is: 404
body: {"error":"Failed to change switch power state"}
tests/test_HttpSessionStatusCodes.cpp:829: Failure
Expected equality of these values:
  nlohmann::json::parse(res.body()).value("error", "")
    Which is: "Failed to change switch power state"
  "Unknown switch IP"
[  FAILED  ] PowerStateEndpointTest.SetSwitchesPowerStateWithAnUnknownIpIsA404NotA500 (0 ms)
```

🔴 **`500` ＋ `{"error":"Failed to change switch power state"}` 逐字就是 auditor 今晚在 OVS 上量到的那一串**
（`FINDINGS-CANDIDATES.md` OV-2）。假交換機重現的是同一個回應，不是一個像它的東西。

**OV-3**（把 `getSwitchKind` 檢查換成 `if (false)`）：

```
[ RUN      ] LockEndpointTest.NumOfFlowsForAnUnknownDpidIsA404NotAZero
tests/test_HttpSessionStatusCodes.cpp:780: Failure
Expected equality of these values:
  res.result_int()
    Which is: 200
  404u
    Which is: 404
body: {"num_of_flows":0,"status":"success"}
```

🔴 **`200 {"num_of_flows":0,"status":"success"}`**——同樣逐字對上今晚 `{"dpid":424242}` 的實測。
兩段紅之後都把 `HttpSession.cpp` 還原並重建，`cmp` 逐位元相同。

## 8. 可達性口徑

🟠 **兩條都是產線走得到，今晚都實測過**（`FINDINGS-CANDIDATES.md` OV-2／OV-3，
含對照組：同 IP 的 GET 回 404、`action=sideways` 回 400、`install_flow_entry` 對同一個 dpid 回 404）。
**那是 auditor 跑的，我沒有複驗**；我這一輪的證據是 gtest 與閘門，**不是 live**。
OV-2 的實務衝擊小（ESA 把狀態碼丟掉）**但對人有差**；
OV-3 是「算得出來不等於機制」——不存在的交換機被報成零流量。

## 9. 沒修的同型

- **`set_switches_power_state` 在 TESTBED 模式下我沒有實跑過。** `knowsSwitchIp` 的 TESTBED 分支
  是照 `queryTestbed:304-308` 抄的同一個述詞（讀碼🔵），但這台機器上沒有 testbed 可測，
  gtest 走的是 MININET 分支。**這是這張單最弱的一格。**
- **`setPowerStateMininet:1963-1967` 的 `return false` 仍然無 log、無理由**。前置檢查讓 handler
  不再需要它來分辨，但那條路自己還是啞的。沒改：改它要動 DCPM 的錯誤傳遞，是另一張單。
- 其他「查不到就回預設值」的端點**沒有盤點**。這一輪只修今晚量到的兩個，
  **不宣稱同型的其他實例不存在**。
- `get_path_switch_count__bad_ip`（`spec.py:1190`）仍然收 `[200, 400, 404]`，形狀相同但今晚沒量到。

## 10. 給 Adam 的一格

`spec.py` 收緊成 `[404]` 之後，**舊 kernel 跑契約測試會判紅**。
這是刻意的（契約現在要求這個修法），但如果有人拿 spec.py 去測還沒併這顆 commit 的 kernel，
那一列會紅——**要不要在 spec 裡標一個「since」版本**，是一個一般性問題，不只這一列。
