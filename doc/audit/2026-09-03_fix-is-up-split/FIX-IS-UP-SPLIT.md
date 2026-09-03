# FIX-IS-UP-SPLIT — Q12（`admin_state` ＋ `reachable`），含 #80、#81

分支 `fix/is-up-split-admin-state-reachable`，基底 `trunk` @ `b57736cd`。
[Co-developed with claude code -- Adam]

## ① 一句話

**`is_up` 一個 bit 回答兩個問題，現在兩個問題各有名字**——`admin_state`（"on"／"off"，
只有電源策略寫）與 `reachable`（bool，只有 liveness 寫）；`is_up` 留著當 `reachable` 的
**已棄用別名**，四個外部 consumer 一行都不用改。順手把 #80 的 distrust window 從**時間**
界定改成**證據**界定，並替 #81 做出裁決（附證據）。

## ② 缺陷與裁決

### 2.1 缺陷

一個 bool 同時表示「沒有人下令關掉它」與「twin 連得到它」。兩者**寫者不同、生命週期不同，
而且可以合理地互相矛盾**（被命令關掉、卻被人帶外重啟的交換機，兩件事同時為真）。後果是量到的：

| # | 後果 | 出處 |
|---|---|---|
| 1 | `/ndt/get_switches_power_state` 的 ON／OFF 是從這個 bit 導出的 ⇒ **兩台同樣死透的交換機答案不同**：被命令關的報 OFF，自己死掉的報 ON——而且只在 liveness 追上之前，之後兩台都報 OFF | Q12 原文；本次 `queryMininet` 讀碼 |
| 2 | A-8 三態檢查**比較的兩邊讀同一個 bit** ⇒ 真實 kernel 上 `unexplained_down` 結構上恆空，最高價值的 invariant 開不了火 | `tools/contract_test/spec.py:418` |
| 3 | #46 只在**內部**分開（`adminPoweredOff`），對外 JSON 一個 key 沒動 | `FIX-POLL-RESURRECT.md` §2 row 9、§6.1 |
| 4 | #80：`kPostPowerOffDistrustWindow{15}` 用**時間**遮住 kill 之後 8–13 s 的假 `is_up=true` | `FINDINGS-ALL` row 80；`FIX-POLL-RESURRECT.md` §3.3.2 |
| 5 | #81：`handleInformSwitchEntered` 無條件 `setVertexUp` | `FINDINGS-ALL` row 81 |

### 2.2 裁決

**Adam 2026-09-03 21:1x（表單）：(a) 拆成 `admin_state` ＋ `reachable`；`is_up` 先留著當
`reachable` 的別名，consumer 分批改。** 派 `fix/is-up-split-admin-state-reachable`
（含 #80 的 distrust window 改證據界定、#81 順手）。

### 2.3 為什麼 `admin_state` 是字串不是 bool

`"on"`／`"off"` 是電源 API 本來就在講的話（`?action=on|off`），caller 不必記一個叫
`admin_powered_off` 的 bool 是哪一邊；而字串留了第三個狀態的位置（例如某個平面上 twin 根本
不知道），不必再加一個 key。

## ③ 對外形狀：前 → 後

### 3.1 `/ndt/get_graph_data` 的一個 vertex

**前**（只列相關欄位）：

```json
{ "dpid": 1, "is_up": false, "is_enabled": true, "admin_disabled": false,
  "down_reason": "none", "device_name": "s1" }
```

`is_up=false` 這一格**同時**可能表示「被命令關掉」或「死了」，讀者分不出來。

**後**：

```json
{ "dpid": 1, "admin_state": "off", "reachable": false, "is_up": false,
  "is_enabled": true, "admin_disabled": false, "down_reason": "none",
  "device_name": "s1" }
```

四種組合現在都說得出口：

| `admin_state` | `reachable` | 意思 |
|---|---|---|
| `on` | `true` | 正常 |
| `off` | `false` | 我們關的，而且它確實不在了 |
| **`on`** | **`false`** | **它死了，沒有人叫它死**——這是修法前說不出口的那一格，也是 A-8 要抓的故障 |
| `off` | `true` | 被命令關掉、但有人帶外把它重啟了（`inform_switch_entered` 會走到這裡，見 ⑤） |

🔴 **`is_up` 是 `reachable` 的別名，不是 `admin_state` 的**。四個 consumer 讀 `is_up`，其中
Energy-Saving-App 用 `j.at("is_up")`（**缺 key 會丟例外**）⇒ 拿掉這一行不是 deprecation，
是另一個 repo 的硬解析失敗。把它接到 `admin_state` 則是把舊的歧義換個名字放回去
（閘門 M3 就是這一條）。

### 3.2 `/ndt/get_switches_power_state`

**前**：`{"192.168.123.11": "OFF", "192.168.123.12": "ON"}`
——名字叫 power state，回的是 `isUp` 這個觀測。

**後**：

```json
{ "192.168.123.11": {"admin_state": "off", "reachable": false},
  "192.168.123.12": {"admin_state": "on",  "reachable": false} }
```

🔴 **這是唯一一處 breaking change**（scalar → object）。in-repo 的 consumer 已改
（見 ④），外部 consumer 的盤點也在 ④——**Energy-Saving-App 不讀這支**。

TESTBED（實體排插）那條路徑改成同一個形狀並多一個 `outlet`（PDU 自己的讀數，既不是命令也不是
twin 的可達性）；查不到對應 vertex 時 `admin_state`／`reachable` 給 `null` 而不是猜。
🔴 **TESTBED 分支沒有量過**（實體 testbed 停用中），這句寫在碼裡也寫在這裡。

### 3.3 `from_json` 的向後相容

`reachable` 優先、缺了才讀 `is_up`（用 `.at()`，兩個都沒有仍然是有訊息的錯誤而不是預設值）；
`admin_state` 缺席預設 `"on"`——舊 payload 沒講過命令，「沒講」就是「沒有人關它」。反過來預設
會把每一份存檔的圖讀成一個被人刻意關暗的 fabric（閘門 M7）。

## ④ Consumer 盤點

### 4.1 in-repo（已改）

| 檔案 | 讀什麼 | 這次的處置 |
|---|---|---|
| `tools/contract_test/spec.py` `inv_all_switches_up`（A-8） | 兩邊都讀 `is_up` | **改成讀 node 自己的 `admin_state`／`reachable`**；全部 switch 都有 `admin_state` 才走這條，否則退回舊的 power endpoint 路徑（部分有部分沒有＝不可據以行動，與 `classify_power_state` 的部分覆蓋規則同一條紀律）。`unexplained_down` 現在**開得了火** |
| `tools/contract_test/spec.py` `classify_power_state` | `{ip: "ON"/"OFF"}` | 兩種形狀都吃；`off_dpids` 只跟**命令**走，另出 `unreachable_dpids` |
| `tools/contract_test/spec.py` `GRAPH_NODE` schema | — | 加 optional `admin_state`（詞彙鎖 `on`／`off`）與 `reachable`；`is_up` 仍為必要（它是別名不是遺跡） |
| `tools/contract_test/spec.py` `inv_power_state_values`、endpoint table | scalar | `OneOf(Str, Obj)`，兩種形狀都合法 |
| `tools/contract_test/selftest_fixtures.py` | `{"10.10.10.10": "ON"}` | 樣本換成新形狀（self-test 的工作是「證明 schema 吃得下 kernel 真的送的東西」） |
| `tools/contract_test/compare_baseline.py` `facts_power_state` | `values_are_on_off` | 兩種形狀都歸約到同一組 fact name，並多一個 `reports_admin_state_separately` |
| `tests/python/test_contract_spec.py` | — | 新增兩個 class 共 14 例 |
| `tests/test_PollDoesNotResurrect.cpp` | `TheEmittedVertexShapeGainsNoNewKey` | 依裁決**改寫成釘新形狀**並更名為 `TheEmittedVertexShapeCarriesAdminStateAndReachable`（`mutate_poll_does_not_resurrect.sh` M1 的期待名同步更新） |

**只讀 `is_up` 的 in-repo reader（別名讓它們原封不動）**：`tools/test_workflow/stack.sh`（兩處
統計）、`tools/contract_test/compare_baseline.py` 的 `all_switches_up`／`all_edges_up`、
`p4_proxy` 與 edge 相關路徑（**edge 沒有 `admin_state`**——邊沒有電源命令這回事，只有 vertex 有）。

### 4.2 repo 外

| Consumer | 位置 | 讀什麼 | 別名夠不夠 |
|---|---|---|---|
| **Energy-Saving-App** | `/home/adam/Energy-Saving-App`（**不是** `~/Desktop/…`；本次唯讀 grep 確認） | 自己的 `include/common/GraphTypes.hpp:41` `v.isUp = j.at("is_up").get<bool>();`、`:87` 邊的同一行；`src/sim/energy_saving_simulator.cpp:295` 走 `!g[v].isUp \|\| !g[v].isEnabled` | ✅ **夠**。它用 `j.at("is_up")`，別名在就不會丟例外；它的 `from_json` 只 `.at()` 九個 key，多出來的鍵一律惰性——**這不是推論**：trunk 現在就已經在送 `admin_disabled`、`down_reason`、`nickname`、`ecmp_groups` 四個它不讀的鍵，而它一直在跑。**它不讀 `/ndt/get_switches_power_state`**（`src/app/http.cpp` 只有 `set_switches_power_state` 與 `get_graph_data`）⇒ ③.2 的 breaking change 碰不到它 |
| Network-Traffic-Visualizer／Web-GUI／Traffic-Engineering-App | 不在本機 | 依 `GraphTypes.hpp` 既有註解，讀 `is_up`／`is_enabled` | ✅ 別名在就不動。**未親自讀過那三個 repo**——這是轉述既有註解，不是第一手查證 |

## ⑤ #80 與 #81

### 5.1 #80：distrust window 從時間改成證據

**原本**：`poweredOffWithinDistrustWindow` ＝ `now() - lastPowerOff < 15s`。那 15 s 的推導**自己**
就說明了它為什麼該退場：「kill 之後 worker 從 proxy 還沒過期的 `probe_ok` 答 Up，直到最後一個
LLDP beacon 超過 12 s 才轉 Unknown ⇒ 圖最多錯 12 s 加一個 tick」——**每一句都是在講一個觀測
變舊**，而計時器不知道觀測有沒有被更新，它只能假設。

**現在**：window 由 `notePowerOff` 開（確認停掉時），由**兩種 kill 之後的證據**關：
1. helper `on` exit 0（原本就有的 `clearPowerOffRecord`）；
2. **一次 probe 時刻晚於 kill 的 liveness Up**（新增 `P4PowerStrategy::acceptLivenessUp`）。

`acceptLivenessUp(swName, observedAt)` 收的是**那次 probe 被取樣的時刻**，不是被讀到的時刻：
proxy 會連 `probe_age_s` 一起送，若用「現在」給每一筆讀數蓋時戳，快取就是這樣把自己洗成當前
證據的。沒有時戳的 Up（proxy 換 schema）＝不算證據——與 `p4LivenessFor` 對「不可信讀數不下
判決」同一條政策。

**沒有保留時間上界，這是決定不是遺漏。** 上界的唯一效果就是「在沒有任何佐證的情況下宣布圖可信」，
正是本條要換掉的機制。沒有上界的失敗模式有界而且大聲：一台從此沒人再觀測到的交換機，下次
power-on 會真的跑 helper；若它其實活著，helper 拒絕啟第二個實例 → 500。這正是本檔案既有的
方向（powerOn 對帶外重啟的註解）：**用大聲的錯答案換掉安靜的錯答案。**

**1 Hz worker 那一側**：BMV2 分支的 `Up` 現在先問 `acceptP4LivenessUp`，被拒就**什麼都不寫**
（跟 payload 不可信時的 Unknown 同一個處置），並 edge-triggered 印一行 WARN，恢復時也印一行
INFO——只印開始不印結束，讀者分不出「復原了」與「log 不再提它」。

🔴 **名字保留**：`poweredOffWithinDistrustWindow(swName)` 這個簽章一個字沒動，因為
`mutate_poll_does_not_resurrect.sh` 的 `p4-on-guard` anchor 逐字錨在 powerOn 的那個 if 上。
它仍然是一個 window，只是**結束條件從時鐘換成事件**。

### 5.2 #81：`inform_switch_entered` 的裁決（有證據）

**做法：保留 `setVertexUp`，但它不得清掉 `adminPoweredOff`（有測試釘住），並在命令仍然
站著時印一行 WARN。**

證據來自 caller 而不是品味：

- `intelligent_router.py:1202` 由 `ofp_event.EventOFPStateChange` 在 datapath 進 `MAIN_DISPATCHER`
  時發——**握手完成**；
- `intelligent_router.py:1059` 對 `_pending_switch_dpids` 排空後逐一發，那個 set 由
  `EventSwitchEnter` 填——**也是 transition**；
- `p4_proxy/proxy_agent/kernel_notifier.py:96` 是 P4 那一側的同一件事，proxy adopt 時推。

三個都是**由一個完成的 session 邊緣觸發**。這與 #46 擋掉的東西**類別不同**：#46 擋的是
**清單成員資格**（proxy 在交換機死後還列它 D=3.06 s），那是快取；死掉的行程不會完成握手，
所以這是關於「現在」的證據，擋掉它等於 twin 說一台明明在回話的交換機不可達。

**而它不是「有人撤銷了關機命令」的證據**，所以旗標不能動。拆欄之後 twin 不必二選一：
報 `admin_state=off` ＋ `reachable=true`，大聲說出「有人沒問過我們就把它開回來了」。

## ⑥ 紅 → 綠

🔴 **原始輸出全部在 `audit-raw` 分支的 `089f7776`**（CLAUDE.md：raw 進 audit-raw），路徑
`doc/audit/2026-09-03_fix-is-up-split/raw/`，**十六個檔，逐一以 sha256 對過內容**。
這個 doc 目錄只留這一份 write-up。讀某一份：

```
git show audit-raw:doc/audit/2026-09-03_fix-is-up-split/raw/09_gate_is_up_split_run2.log
```

| 檔 | 內容 |
|---|---|
| `10_red_python_contract_spec.log` | Python 先紅（7/141） |
| `01_red_cpp.log` | C++ 先紅（4 條具名 ＋ 一次 abort；帶 stub，見 6.2 的但書） |
| `08_` / `09_` | 新閘第一次（16 抓 2 活，我在 W2 停掉）／修好後 18/0 ＋ 3/0 |
| `10_gate_poll_rerun.log` / `11_` | 舊閘 10/3 ／ 修好後 10/0 ＋ 3/0 |
| `03_` `04_` `05_` `12_` `13_` | 新套件、全量 gtest（972→974）、ctest |
| `06_` `06b_` `07_` | `tests/python` 29 個模組、`p4_proxy` 25 個模組 |
| `02_` | 產生受測 binary 的那次 build |
| `apply_verdict_refactor.py` | 修兩個閘門存活者的那支腳本 |


### 6.1 Python（先紅）

`python3 tests/python/test_contract_spec.py`，在 **trunk 的 `spec.py`** 上（測試已改、production 未改）：

```
Ran 141 tests
FAILED (failures=7)
  test_off_dpids_follows_the_command_not_the_observation
  test_the_new_object_shape_maps_commanded_off_switches_onto_dpids
  test_the_schema_pins_the_admin_state_vocabulary
  test_a_switch_that_is_unreachable_while_commanded_off_is_accounted_for
  test_reachable_beats_the_deprecated_alias_when_they_disagree
  test_the_node_fields_are_used_even_when_no_power_reading_was_taken
  test_the_two_dead_switches_are_reported_differently
```

其中最能說明缺陷的一條：`test_the_two_dead_switches_are_reported_differently` 的紅是

```
AssertionError: True is not false : ['switch(es) not up: s5(dpid=5), s7(dpid=7)']
```

——被命令關掉的 s5 與自己死掉的 s7 **被報成同一件事**。

🔴 **有幾條新案例在 trunk 上就是綠的**，我說清楚：`test_a_switch_that_is_unreachable_while_commanded_on_is_reported`、
`test_a_healthy_split_fabric_reports_nothing`、`test_a_kernel_that_predates_the_split_still_uses_the_power_reading`、
`test_a_mixed_graph_falls_back_rather_than_guessing`。前者在 trunk 上是**因為別的理由**綠的
（舊碼讀別名 `is_up`，而 `Ctx()` 的預設 power_state 是 `all_on()`）；它們的鑑別力由變異閘給，
不由這一次的紅給。

### 6.2 C++（先紅）

`build/bin/test_routing_strategy --gtest_filter='IsUpSplitTest.*:InformSwitchEnteredTest.*:PollDoesNotResurrectTest.TheEmittedVertexShapeCarriesAdminStateAndReachable'`，
在 **trunk 的 production 碼**上（測試已寫、`src/`／`include/` 未改）：

```
[  FAILED  ] IsUpSplitTest.AVertexCarriesAdminStateReachableAndTheIsUpAlias
[  FAILED  ] IsUpSplitTest.TheIsUpAliasEqualsReachableInBothDirections
[  FAILED  ] InformSwitchEnteredTest.TheResultingVertexReportsTheDisagreementRatherThanPickingOne
[  FAILED  ] PollDoesNotResurrectTest.TheEmittedVertexShapeCarriesAdminStateAndReachable
... 然後行程在 ACommandedOffSwitchAndACrashedSwitchAreDistinguishableOnTheWire 裡 abort
    （core dumped，rc=134）
```

🔴 **兩件事要說清楚，不能當成一次乾淨的紅**：

1. **那次紅不完整。** 缺 key 時我原本用 `j["admin_state"]`，在 const json 上是 UB／丟例外，
   行程直接 abort，後面的案例**一次都沒跑**。測試已改成全部走 `.value()`（一個 abort 會把整個
   binary 的回報一起帶走），但**改完之後我沒有再回 trunk 跑一次**——那要再一次全量重建，而
   排隊中的 build lock 今晚由三個 session 共用。
2. **`acceptLivenessUp` 在 trunk 上根本不存在**，所以 #80 那四條案例在 trunk 上是**編不過**，
   不是紅。上面那次紅是**用一個 stub 跑的**：把 `acceptLivenessUp` 加進去、實作成 trunk 的語意
   （無條件回 true ＝ 每個 Up 都寫），這樣行為斷言才跑得起來。**這是 stub，不是 trunk。**

⇒ **這幾條的紅以變異閘為準**（⑦）：M10 把 window 換回 15 s 計時器、M13 讓 worker 不問就寫、
M14 丟掉 probe 年齡、M15／M16 是兩種過度修正——每一條都指名它該弄紅哪一個案例，並實際弄紅。
變異閘是這個 repo 對「紅」的標準，而它比一次性的 trunk 紅嚴格。

### 6.3 綠

```
$ build/bin/test_routing_strategy --gtest_filter='IsUpSplitTest.*:InformSwitchEnteredTest.*:PollDoesNotResurrectTest.*'
[==========] 32 tests from 3 test suites ran.
[  PASSED  ] 32 tests.

$ python3 tests/python/test_contract_spec.py
Ran 141 tests ... OK
```

新增的案例：C++ **20 個 `IsUpSplitTest`** ＋ **3 個 `InformSwitchEnteredTest`**，
Python **14 例**（兩個新 class）。

## ⑦ 變異閘

### 7.1 新閘 `tests/shell/mutate_is_up_split.sh`

`JOBS=1 tools/build_guard/guarded_build.sh ./tests/shell/mutate_is_up_split.sh`

```
=== verdict ===
  18 mutations, 0 survived
  3 widenings, 0 wrongly caught
=== restore ===
  all 4 files byte-identical to the pre-run snapshot
  rebuilt from the restored tree / suite green again after restore
  test binary sha unchanged: 7a5a8105eaf38836
guarded_build: exit 0
```

18 條的兩個方向：

| | 內容 |
|---|---|
| **放回歧義**（M1–M10、M12–M14、M17） | M1 `admin_state` 又從 `isUp` 導出（**缺陷逐字放回**）、M2 拿掉 `reachable`、M3 別名改接 `admin_state`、M4 拿掉別名、M5 `from_json` 只讀別名、M6 `reachable` 變必要（舊 payload 爆）、M7 缺席預設 `off`、M8 endpoint 回單一 scalar、M9 endpoint 的 `admin_state` 從觀測填、M10 **distrust window 換回 15 s 計時器**、M12 無時戳的 Up 算證據、M13 worker 不問就寫、M14 丟掉 probe 年齡、M17 `inform_switch_entered` 清掉命令 |
| **過度修正**（M15、M16、M18，以及 M11 的另一半） | M11 證據比較反向（兩個方向一次）、M15 連沒被關過的交換機也不信（**整座 fabric 變黑**）、M16 window 只能由 power-on 關、M18 控制平面推播拒絕記錄可達性 |

三個放寬（必須全綠）：W1 註解、W2 log 措辭、W3 `admin_state` 三元式寫成否定式。

🔴 **第一次跑不是 18/0，我照實寫**（原始 log `08_gate_is_up_split.log`）：

- **M13 存活**，而且它是對的：那時檢查寫在 `pingWorker` 的 switch 裡，而 worker 需要活的 proxy
  ⇒ **沒有任何測試碰得到那一行**，刪掉它當然活下來。**能開不了火的政策就是沒有被閘門守住的政策。**
  修法是把它抽成 `p4VerdictFor()`（跟 `ovsLivenessFor`／`p4LivenessFor` 同一個理由與同一個位置），
  並補兩個案例：stale 的 Up 要變成 **Unknown**（worker 唯一不寫的那個判決）、**Down 要原封不動**
  （這個檢查是防「舊讀數把交換機抬起來」，不是防 twin 發現一台死掉的）。
- **M15 存活**，是我瞄錯：它指名了一個**有**關機紀錄的測試，卻去改「沒有紀錄」才會走的分支；
  而且 `if (false)` 的寫法會越過 guard 去解參考 `end()` 迭代器。改成它本來要表達的那個窄的
  過度修正（沒有紀錄時回 `false`），並只指名走得到那條分支的兩個案例。
- 第一次跑**沒有跑完**：我在 W2 停掉了它。原因見 7.3。

### 7.2 舊閘 `tests/shell/mutate_poll_does_not_resurrect.sh` 重跑

**第一次重跑 10/3**——三個存活全是同一個案例
`PowerOnActuatesWhenACommandedOffIsStillStanding` 沒紅（M2、M3、M8）。

🔴 **那是我這次改動造成的，不是舊閘壞掉。** 那個案例的前提是「過了 15 s 窗口之後，只有命令能
讓 power-on 動作」，它用 `advance(60)` 製造那個狀態。**window 改成證據界定之後，時間不再關窗**
⇒ 這通 power-on 是靠**窗口**而不是靠**命令**才動作的，案例照樣綠，但它對那個旗標**一句話都沒說**。

修法：兩個案例（`test_PollDoesNotResurrect.cpp` 與 `test_P4PowerStrategy.cpp` 裡同型的那個）
都改成**用碼自己的關窗方式關窗**——一次時刻晚於 kill 的 probe。這也正是它們描述的情境：
交換機被帶外重啟、twin 看到它在服務、而命令還沒被撤銷。

```
=== verdict ===
  10 mutations, 0 survived
  3 widenings, 0 wrongly caught
=== restore ===
  all 3 files byte-identical to the pre-run snapshot
  test binary sha unchanged: 91350b170d3f20d5
guarded_build: exit 0
```

### 7.3 一個關於這台機器的量測（順手記下來）

新閘第一次跑在 W2 卡住 **40 分鐘沒有前進**。查證：兩個 `cc1plus`（`HttpSession.cpp`、
`LLMAgent.cpp`）各 **RSS 1.6 GB**、各 **21% CPU**——build guard 的 cgroup 是
`MemoryHigh=3G`，兩個一起 **3.15 GB 超過上限**，kernel 就對整個 cgroup 施加回收節流，
兩邊互相拖死。**`JOBS=1` 之後單一 TU 塞得進 3G，全速跑完。**

⇒ 這兩支閘門的用法都寫成 `JOBS=1`，並在腳本 header 寫明理由。**`MemoryHigh` 沒有動**——
它是 09-03 為了保護 Adam 的 app 才加的，被節流的應該是 build。

## ⑧ 套件

全部我自己在這台機器上跑的，不是轉述。

| 套件 | 指令 | 結果 |
|---|---|---|
| gtest 全量 | `build/bin/test_routing_strategy`（無 filter） | **974 tests from 126 suites，974 PASSED** |
| ctest | `ctest --test-dir build --output-on-failure` | **100% tests passed, 0 failed out of 974** |
| `tests/python` | 每個模組單獨 `python3 tests/python/test_X.py` | **29 個模組全綠**（`test_contract_spec.py` Ran 141） |
| `p4_proxy/tests` | `cd p4_proxy && <venv>/bin/python -m unittest tests/test_X.py` | **25 個模組全綠** |
| contract tool 自測 | `python3 tools/contract_test/run_contract_test.py --self-test` | **Self-test passed: 66 checks**（新的 endpoint schema 與 fixture 都走過） |

🔴 **`test_sflow_stats_endpoint.py` 的但書**：它要 `p4_proxy/venv`，而 venv 不進版控 ⇒
**worktree 裡沒有**，第一次跑 rc=127（找不到直譯器）。改用主 checkout 的
`/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python` 跑**我這份 worktree 的測試檔**，
Ran 5、OK。p4_proxy 那 25 個模組同樣借主 checkout 的直譯器。**借的是直譯器與相依套件，
不是被測的碼。**

## ⑨ live

🔴 **跳過，沒有跑。**

交辦時就說了 live 是最後一項、可略——實際情況比預期更緊：整晚 `/tmp/ndtwin-build.lock` 上有
四到五個 session 在排隊跑變異閘，本分支光是等鎖就等掉一個多小時，兩支閘門跑完已是 05:10。
**`ndt up p4 4` 一次都沒起過，`ndt` claim 也沒有動過**（因此也沒有動到 `.test_run/lab.claim`）。

**沒有量到的東西，逐項寫在 ⑪.1。** 最重要的一條：#80 的修法是針對一段**量到的** 8–13 s 快取
窗口設計的，但**它在那段窗口上的實際表現沒有被觀測**——只有單元測試與變異閘。

## ⑩ 合併

```
$ git merge-tree --write-tree --messages trunk fix/is-up-split-admin-state-reachable
b1b7fcf976d5af491cb6e940ad9f8f94bd752b3b
rc=0
```

**零衝突。** 開工時 trunk 在 `b57736cd`，這一次量的時候已經前進到 `74daa200`
（run-06 的十一條驗證），仍然乾淨。

會不會跟別人撞：本分支動到的 production 檔是 `GraphTypes.hpp`、
`DeviceConfigurationAndPowerManager.{hpp,cpp}`、`P4PowerStrategy.{hpp,cpp}`、`HttpSession.cpp`。
`tests/CMakeLists.txt` 加了一行（那是 `fix/poll-does-not-resurrect` 併入時唯一衝突過的檔案，
同一種「清單尾端各加一筆」的衝突，兩塊都留即可）。

## ⑪ 沒做的事

1. 🔴 **沒有跑 live。** 交辦時就說了實驗室今晚排給另外兩個 session，且 live 是最後一項、可略。
   實際情況更緊：`/tmp/ndtwin-build.lock` 今晚同時有四到五個 session 在排隊跑變異閘，
   光是本分支的閘門就等了超過一小時才拿到鎖。⇒ **`ndt up p4 4`、API 關機、帶外 kill、
   distrust window 在第一次真 probe 關窗——四項都沒有量。** 這是本次最大的空缺：#80 的修法
   有單元測試與變異閘，但**沒有活體佐證**它在真的 8–13 s 快取窗口上表現如預期。
   建議下一輪補，配方照 `FIX-POLL-RESURRECT.md` §3.3（同一支 harness、同一個相位參考）。
2. **③.1 的 payload 範例是照 `to_json` 寫出來的，不是從活體 API 抓的**（沒有 live）。
   欄位與值是對的；**鍵的順序不是**——`nlohmann::json` 預設用 `std::map`，實際輸出是字典序。
3. **TESTBED（實體排插）那條路徑改了但沒量。** 實體 testbed 停用中，碼裡與 ③.2 都寫了。
4. **邊（edge）沒有拆。** `EdgeProperties::isUp` 仍是單一欄位，沒有 `admin_state`——邊沒有
   「被命令關機」這回事。`inv_edges_enabled` 因此仍走 power endpoint 那條路（已能吃新形狀）。
5. **OVS 平面的 `poweredOffWithinDistrustWindow` 沒有對應物。** distrust 的記錄與證據判定只在
   `P4PowerStrategy`；OVS 的 `powerOn` 只問圖與 `adminPoweredOff`。#46 的 ⑥.3 已列了 OVS
   `powerOff` 的同型缺陷，同一塊沒動。
6. **`is_up` 沒有訂棄用期限**，也沒有在 API 文件裡加 deprecation 標記（見 ⑫.2）。
7. **沒有回頭在 trunk 的碼上重跑一次乾淨的 C++ 紅**（見 ⑥.2 的兩點但書）。
9. **新閘的判決是在 binary `7a5a8105` 上量的，而最終的 binary 是 `91350b17`。** 差別**只有測試檔**
   ——`test_PollDoesNotResurrect.cpp` 與 `test_P4PowerStrategy.cpp` 各改一個**新閘不指名的**案例
   （⑦.2）；production 的四個檔一個 byte 都沒動。沒有重跑新閘（那是再一次約兩個半小時），
   改以最終 binary 上的 **974/974 gtest ＋ 974/974 ctest** 佐證。這是我的取捨，寫出來讓你能推翻。
8. **`p4_proxy/venv` 借主 checkout**（⑧ 的但書）。worktree 要能獨立跑 python 套件需要自己建一份。

## ⑫ 要問 Adam 的

1. 🔴 **`/ndt/get_switches_power_state` 的 breaking change 要不要先通知外部 consumer？**
   scalar → object 是本次唯一一處會讓外部讀者爆掉的改動。我查過 **Energy-Saving-App 不讀它**
   （只呼叫 `set_switches_power_state`）；另外三個 app 我**沒有第一手查過**（不在本機）。
   要不要我先出一份「哪個 repo 讀哪支 endpoint」的盤點再併？
2. **`is_up` 這個別名要留多久？** 現在是無限期。選項：(a) 留到四個 consumer 都改完再拿掉；
   (b) 訂一個版本；(c) 永久保留當相容層。**建議 (a)**，並在 `doc/2026-01-02_ndt_api.md` 標
   deprecated ＋ 指向 `reachable`。**我沒有改那份 API 文件**——它是對外正本，改它前想先問你。
3. **#80 沒有保留時間上界，你認不認這個取捨？** 理由寫在 ⑤.1：上界的唯一效果是「在沒有佐證的
   情況下宣布圖可信」。代價是：一台從此沒人再觀測到的交換機，power-on 會真的跑 helper，
   若它其實活著就 500。這與 #46 既有的方向一致（大聲的錯換掉安靜的錯），但它是**行為改變**。
4. **#81 我裁成「保留 `setVertexUp`」**（⑤.2 有三個 caller 的證據）。若你認為控制平面的推播
   不該抬 `reachable`，改法是照 `updateSwitches` 的 edge-triggered 拒絕；一行的事，測試已經
   把「不得清 `adminPoweredOff`」釘住，改方向不會鬆掉那一條。
