# FIX-TOPOLOGY-INPUT — FINDINGS #61／#62：錯的拓樸檔要當場被拒，而且不准只套用一半

分支 `fix/topology-input-is-validated`（自 `trunk` `92a79392`）。純載入路徑，沒有 lab、沒有實驗。

[Co-developed with claude code -- Adam]

---

## 1. 兩個缺陷，其實是同一個

兩條都是「檔案描述了一個不存在的 fabric，而 kernel 收下了」。

### #61 — dpid 對不到交換機的 host edge 被靜默丟棄

`round5-topology-repro/topo/m1_host_edge_ghost_dpid.json` 是**出貨的 P4 4-host 拓樸只改一個欄位**：
第 32 條 edge 的 `dst_dpid` 由 1 改成 99（`dst_ip` 一併改成 `192.168.123.99`），也就是**一條主機線
插在一台不存在的交換機上**。

載入器的行為是：印一行 `[warning] ... Skipping edge:`，然後**照常把剩下的圖端出去**。

### #62 — `src_interface` 完全沒有範圍檢查

`m4a_port_zero.json`（`src_interface` 1 → 0）與 `m4b_port_six_digits.json`（1 → 999999），
兩者都改在**交換機側**的 port。兩個都載入成功，而且被 `get_graph_data` **原樣公布**。

它不只是被公布：`FlowLinkUsageCollector.cpp:3124` 的
`path.push_back(std::make_pair(flowKey.srcIP, graph[edge].dstInterface))`
把這個值當作一條流的**路徑第一跳**推進去（我親自讀過那一段）。也就是說，
拓樸檔裡一個打錯的 port，會變成流量歸屬的路徑元素。

### 🔴 為什麼這兩條算嚴重

不是「有一條線壞了」，是**壞掉的那條線在所有對外通道上都看不見**。少一條線的 fabric 與健康的
fabric，從 `get_graph_data`、從各端點的狀態碼、從 `ndt status` 看起來完全一樣——唯一的差別是
kernel log 裡的**一行 warning**，而那一行不會讓任何檢查變紅。

---

## 2. 決定：**(a) 啟動時拒絕整個檔案，exit 非 0，訊息指名那一條 edge**

brief 給了兩個選項；我選 (a)，理由是**讀完 code 之後 (b) 需要新建的東西 (a) 已經有了**：

1. **契約已經在那裡，而且是為了同一件事寫的。** `TopologyAndFlowMonitor::loadStaticTopology()`
   已經會接住 `loadStaticTopologyFromFile` 丟出的例外、印一行 CRITICAL，然後回 `false`；
   那行 CRITICAL 的原文就是
   > 「Refusing to start: a kernel whose topology did not load answers every query confidently
   > and wrongly. No port has been opened.」

   `src/main.cpp:376` 接的是 `if (!topologyAndFlowMonitor->loadStaticTopology()) return EXIT_FAILURE;`，
   而它在 `main.cpp:462` 的 `start()`／`handler->start()` **之前**——也就是**任何 socket 綁定之前**。
   我要做的只是讓這兩種錯誤走進那條既有的路，不必新增機制。

2. **同一個載入器裡已經有三個同類的 throw。** switch 的 `ip` 是空陣列、`switch_kind` 認不得、
   IP 位址解不開——三個都是 load 時 throw，而且各自的註解都寫著同一個理由（「load 時失敗遠比
   runtime 誤導好」）。#61／#62 走同一條路才是一致的，額外開一條回報管道反而是新的不一致。

3. **(b) 的成本落在今晚正在被改的檔案上。** (b) 需要在 `get_graph_data` 上加 `load_warnings`
   與一個非 200／明確旗標——那是 `HttpSession.cpp` 與 `GraphTypes.hpp` 的 `to_json`，正好是
   `fix/is-up-split-admin-state-reachable` 今晚在寫的兩個檔。

4. **最重要的：(b) 保不住「拒絕的輸入不准只套用一半」。** (b) 的形狀是「載進來、把丟掉的記下來」，
   而 39/40 的圖**本身就是半套用**。一個知道自己拿到錯拓樸還繼續服務的 kernel，正是這條規則反對的。

### 檢查的規則（(b) 那半題：port 範圍）

| 位置 | 規則 | 依據 |
|---|---|---|
| **交換機側**（該端 `dpid != 0`） | `1 ≤ interface ≤ 65535` | 13 個出貨檔的交換機側**最小 1、最大 67**，無一為 0 |
| **主機側**（該端 `dpid == 0`） | `interface ≤ 65535`（**0 合法**） | 見下 |

🔴 **主機側的 0 不能擋，這是這支修法最容易做錯的地方。**
`doc/2026-01-02_ndt_api.md:233` 寫著：*"At the edge between the switch and host, the dpid and interface
on the host side are set to 0."* 而**五個出貨的 TESTBED 檔**（`StaticNetworkTopology_ipAlias4_*`）
每一條 host edge 都真的填 0（各 32～96 條），另外八個 OVS／P4／Mininet 檔則填 1。
所以「port 一定要 ≥ 1」**不是規則**，那是**交換機那一側**的規則。寫錯的話會**擋掉五個出貨檔**——
比 #62 本身造成的破壞還大。這一條在 gtest 與閘門裡各釘了一次（測試 `AZeroInterfaceOnTheHostSideIsStillAccepted`、
閘門 M8）。

### 上限 65535 的誠實說明

`kMaxTopologyInterface = 65535` 是**理智檢查，不是協定推導**，doc comment 裡也是這樣寫的：
本專案講 OpenFlow 1.3（`Classifier.cpp` 的註解），1.3 的 port 是 32-bit、只保留 `0xffffff00` 以上，
所以 **999999 其實是一個合法的 OF 1.3 port 號**，沒有任何協定規則會拒絕它。
真正拒絕它的是這批機器：13 個出貨檔的最大 interface 是 **67**，而 65535 是 OF 1.0 十六位元
port 空間的天花板——夠寬鬆到不會擋到任何一台現有交換機，又能擋掉一個一眼就是錯的數字。

🔴 **它抓不到的：把 port 4 打成 port 5。** 這一點必須講清楚，因為 `make_topology.py` 的
`validate()` 存在的理由（2026-08-17 那次）正是這種「看起來合理但是錯的」port。這個界線抓的是
打字錯誤與產生器 bug，不是判斷錯誤。

### 為什麼會有兩層

修法在**兩個地方**擋：驗證函式（先跑，拒絕整個檔）＋ edge builder 原本那個 else 分支（改成 throw）。
第二層在正常情況下**不可能被走到**——驗證已經把每條 edge 都解析過了。它還是留著並且會 throw，
理由是：**要修的病是「靜默丟棄」**，所以「驗證器與 builder 意見不一致」不可以變成唯一還能悄悄丟
一條線的路。原本那裡是 WARN + `continue`，那就是 40 變 39 的地方。

---

## 3. before／after：真的 `ndtwin_kernel` binary

跑法：`--mode mininet --topology <file> --no-ai`，沒有 lab、沒有 sudo、沒有 Mininet。
**四個檔逐一跑，中間等 `:8000` 淨空**——第一次我平行跑，四個 kernel 搶 `:8000`，
三個以 exit 1 死掉而那是**port 衝突不是拓樸拒絕**；那批資料已作廢重跑。

### BEFORE（trunk 的碼，binary sha `120242a3…`）

| 拓樸 | :8000 | `get_graph_data` | 端出的 edges | 公布的 interface 值 | exit |
|---|---|---|---|---|---|
| `m0_baseline`（對照） | 0.50 s 開 | 200 | **40 / 40** | `[1,2,3,4]` | 143（我送的 SIGTERM）|
| `m1_host_edge_ghost_dpid` | 0.50 s 開 | 200 | **39 / 40** 🔴 | `[1,2,3,4]` | 143 |
| `m4a_port_zero` | 0.50 s 開 | 200 | 40 / 40 | **`[0,1,2,3,4]`** 🔴 | 143 |
| `m4b_port_six_digits` | 0.50 s 開 | 200 | 40 / 40 | **`[1,2,3,4,999999]`** 🔴 | 143 |

三個壞檔全部「ACCEPTED」，全部印出 `Server Listening`，全部要我送 SIGTERM 才會停。
`m1` 的 kernel log 裡就只有那一行：

```
[warning] [TopologyAndFlowMonitor.cpp:593 parseStaticTopologyFile] Skipping edge: src_dpid=0 dst_dpid=99, src_ip=16777226 dst_ip=1669048512
```

### AFTER（同一支腳本、同一批拓樸檔，只換 binary）

| 拓樸 | :8000 | 幾秒後死 | `Server Listening` | exit |
|---|---|---|---|---|
| `m0_baseline`（對照） | 0.50 s 開，**40/40 edges、`[1,2,3,4]`、HTTP 200** | 沒死 | 有 | 143（我送的 SIGTERM）|
| `m1_host_edge_ghost_dpid` | **NEVER** | 0.25 s | **0 行** | **1** |
| `m4a_port_zero` | **NEVER** | 0.25 s | **0 行** | **1** |
| `m4b_port_six_digits` | **NEVER** | 0.25 s | **0 行** | **1** |

🔴 **`:8000` 是 NEVER，不是「開了又關」。** 這是整條 (a) 的重點：一個開過 port 的行程已經
對所有健康檢查做出了一個收不回來的宣告。before 那三個在 0.50 s 就開了 port 並印了
`Server Listening`。

三行 CRITICAL（路徑縮寫，其餘逐字）：

```
edge #32 src_ip=["10.0.0.1"] dst_ip=["192.168.123.99"] src_dpid=0 dst_dpid=99:
  "dst_dpid" is 99 and no switch node in this file declares that dpid. Refusing the file: this
  link used to be dropped with one warning and the rest of the topology served as though it were
  complete. Refusing to start: ... No port has been opened.

edge #0 src_ip=["192.168.123.11"] dst_ip=["192.168.123.15"] src_dpid=1 dst_dpid=5:
  "src_interface" is 0 on the side attached to switch dpid 1, and 0 is not a switch port. It IS
  the documented value on the host side of a host edge, where the dpid is 0, and it is accepted
  there. ...

edge #0 ... : "src_interface" is 999999, above the largest interface index this loader accepts
  (65535). It used to be republished verbatim by get_graph_data and used to attribute flow to a
  port that does not exist. ...
```

訊息裡有**檔名、edge 序號、兩端的 IP 與 dpid、出問題的欄位名與值**——`jq '.edges[32]'` 就到位。
第二條還順便告訴讀者「host 側的 0 是合法的」，因為那正是看到這個錯誤的人最可能誤修的方向。

---

## 4. 紅 → 綠

新檔 `tests/test_TopologyInputValidation.cpp`，14 個 case。

### 紅（在 **trunk 的 `src/`** 上，只加測試不改碼；`git status src/ include/` 當時是空的）

```
[==========] 14 tests from 1 test suite ran. (158 ms total)
[  PASSED  ] 5 tests.
[  FAILED  ] 9 tests, listed below:
[  FAILED  ] TopologyInputValidationTest.AnEdgeNamingADpidNoSwitchHasIsRefused
[  FAILED  ] TopologyInputValidationTest.TheRefusalNamesTheDpidThatMatchedNothing
[  FAILED  ] TopologyInputValidationTest.AGhostDpidEdgeLeavesNoPartiallyLoadedGraph
[  FAILED  ] TopologyInputValidationTest.AHostEdgeWhoseAddressMatchesNoNodeIsRefused
[  FAILED  ] TopologyInputValidationTest.AZeroInterfaceOnTheSwitchSideIsRefused
[  FAILED  ] TopologyInputValidationTest.ASixDigitInterfaceIsRefused
[  FAILED  ] TopologyInputValidationTest.TheRefusalNamesTheInterfaceThatWasOutOfRange
[  FAILED  ] TopologyInputValidationTest.ADestinationInterfaceIsCheckedToo
[  FAILED  ] TopologyInputValidationTest.OneAboveTheLargestInRangeInterfaceIsRefused
```

40 → 39 那一條在測試裡長這樣：

```
AGhostDpidEdgeLeavesNoPartiallyLoadedGraph
  Expected equality of these values:
    out.edges
      Which is: 39
    0u
  the refused topology left 39 edges in the graph (the measured defect left 39 of 40)
    out.vertices
      Which is: 14
```

**紅的 9 條與綠的 5 條剛好是對的形狀**：新檢查全紅，而五條「不可以退步」的對照
（`TheLargestInRangeInterfaceIsAccepted`、`TheSmallestInRangeSwitchInterfaceIsAccepted`、
`AZeroInterfaceOnTheHostSideIsStillAccepted`、`EveryShippedTopologyStillLoadsWithNothingDropped`、
`TheTwoMininetCapableTopologiesStillLoadInMininetMode`）在 trunk 上本來就該綠。

### 綠

同一支測試、同一個 filter，只差在 `src/` 套了修法（`guarded_build: exit 0`，
`-Wall -Wextra -Wpedantic -Werror` 沒有半個警告）：

```
[==========] 14 tests from 1 test suite ran. (499 ms total)
[  PASSED  ] 14 tests.
```

**9 紅 → 0 紅。**

🔴 **一個必須講清楚的細節：紅的那一次跑的測試檔，與綠的這一次差一個地方。**
紅之後我改了兩條斷言——`TheRefusalNamesTheDpidThatMatchedNothing` 與
`TheRefusalNamesTheInterfaceThatWasOutOfRange` 原本在**整條**訊息裡找 `99`／`999999`，
而整條訊息開頭是 `topology file "<path>": ...`，那個 path 是帶著本行程 pid 的暫存檔名——
**pid 若是 199843，找 `99` 就會中，而那跟診斷訊息一點關係都沒有**（儀器自己生出答案）。
現在改成先把 path 從訊息裡拿掉再找。

這**不影響紅的有效性**：那兩條在 trunk 上是死在前面那行 `ASSERT_TRUE(out.threw)`
（根本沒有 throw），**還沒走到字串搜尋**。而且真正嚴謹的紅在第 6 節——
**變異閘門是拿最終版測試檔跑的**，M2 就是把 40 → 39 原樣裝回去。

---

## 5. 「合法拓樸載入結果不變」怎麼證的

兩個層次，都不靠會過期的 golden 數字：

1. **gtest `EveryShippedTopologyStillLoadsWithNothingDropped`**——把 `setting/` 底下 13 個
   `StaticNetworkTopology*.json` 全部載入，斷言 `num_vertices == 檔案的 nodes 數`、
   `num_edges == 檔案的 edges 數`。拿檔案自己當期望值，所以任何一個檔開始掉 edge 就會紅。
   （另有一條在 MININET 模式下跑 `ndt up` 真正會用的那兩個檔；五個 `_ipAlias4_` 檔的 switch 沒有
   `bridge_name`，結構上只能走 TESTBED。）
2. **真 binary 的 `get_graph_data` 對比**：`m0_baseline` 在 before／after 兩邊都是
   `nodes=14 edges=40`、interface 值 `[1,2,3,4]`、HTTP 200。

事前也用 Python 照著載入器的解析邏輯掃過 13 個檔：**dropped 全部 0，且不同 edge 解析出來的
(src,dst) 頂點對全部相異**（`Graph` 用 `boost::setS` 存 out-edge，平行邊會被吃掉，所以
「edges 數 == 檔案 edges 數」這個斷言必須先確認沒有重複對）。

---

## 6. 變異閘門

`tests/shell/mutate_topology_input_is_validated.sh`，形狀照 `mutate_poll_does_not_resurrect.sh`：
唯一錨點、`cp -p` 快照 + EXIT trap 還原 + `touch`、結束時斷言檔案 byte 相同**且測試 binary sha 沒變**、
**編不過的變異算存活**。

**最終結果（第三次跑，`guarded_build: exit 0`）：9 個變異 0 個存活、3 個 widening 0 個誤殺。**

### 錨點與基準

```
=== anchor uniqueness (exact substring count must be 1) ===
  ok  validate-call / dpid-known / dpid-refusal / host-addr / iface-ceiling
      iface-floor / max-constant / builder-refuse / gate-comment      ← 9 個，全部 x1
=== baseline (unmutated working tree) must build and be green ===
  ok  baseline green (14 cases in TopologyInputValidationTest.*)
  ok  test_routing_strategy sha256 6800520f8bac9ef8
```

### 9 個變異 ＋ 3 個 widening

| # | 變異 | 結果 | 變紅的測試 |
|---|---|---|---|
| M1 | **validation removed**：整個驗證 pass 不再被呼叫 | ✅ | 半套用那條＋全部 #62 |
| M2 | **error swallowed into a WARN again**（兩層一起）：40 → 39 原樣裝回 | ✅ | #61 三條全紅 |
| M3 | 未知 dpid 的檢查永遠不會成立 | ✅ | `AGhostDpidEdgeLeavesNoPartiallyLoadedGraph` |
| M4 | host edge 的位址不再對照檔案 | ✅ | `AHostEdgeWhoseAddressMatchesNoNodeIsRefused` |
| M5 | interface 範圍檢查整個拿掉 | ✅ | #62 四條 |
| M6 | **range check off by one**（天花板多收一個值） | ✅ | `OneAboveTheLargestInRangeInterfaceIsRefused` |
| M7 | **range check off by one**（地板連 port 1 一起擋） | ✅ | 邊界那條＋**13 個出貨檔那條**＋MININET 那條 |
| M8 | 🔴 **地板套到 host 側**（到處都不准 port 0） | ✅ | `AZeroInterfaceOnTheHostSideIsStillAccepted`＋出貨檔那條 |
| M9 | 天花板收到現有機器的最大值（67） | ✅ | `TheLargestInRangeInterfaceIsAccepted` |
| W1 | 只改一行註解 | ✅ 存活 | — |
| W2 | 把拒絕訊息**整段改寫**（數字留著） | ✅ 存活 | — |
| W3 | dpid 查找寫成否定比較 | ✅ 存活 | — |

**M7／M8 是這張表裡最重要的兩列**：其他每一個 #62 的案例在它們底下**都還是綠的**，
只有「port 1 要能過」「host 側的 0 要能過」「13 個出貨檔要能載」這三條看得見它們。
沒有這三條測試，一個把整批機器擋掉的修法會拿到綠燈。

**W2 存活**證明測試斷言的是「**那個數字**有沒有傳到操作者手上」，不是訊息的措辭——
所以下一個人要改善這段診斷不必先改測試。

### 還原

```
  all 1 files byte-identical to the pre-run snapshot
  rebuilt from the restored tree
  suite green again after restore
  test binary sha unchanged: 6800520f8bac9ef8
```

（另外我自己再確認一次：閘門跑完後 `git diff --stat src/` 是空的。）

### 🔴 第一次跑，閘門抓到的是**我自己**

M1 第一版寫成把呼叫換成 `(void)j;`。那讓 `validateStaticTopologyJson` 變成
**匿名 namespace 裡一個沒有人用的函式** ⇒ `-Wunused-function` ⇒ 這個專案是 `-Werror`
⇒ **變異編不過**，閘門判它 **SURVIVED**（第一次跑：9 個變異 1 個存活，`guarded_build: exit 1`）。

那個判法是對的，也正是這條規則存在的理由：**編不過的變異等於那一輪測試根本沒跑，證明不了任何事**。
改成把呼叫留在 `if (false)` 的死碼裡——驗證一樣不會執行，但函式仍然被引用——量到的才是
「檢查不見了」而不是「編譯器抱怨了」。
第一次的完整輸出留在 audit-raw 的 `gate_run1_m1_did_not_compile.log`。

---

## 7. 其他測試套件

### Python：**54 個模組全綠，0 紅**（`tests/python` 29 ＋ `p4_proxy/tests` 25）

**逐模組跑，不用 `unittest discover`**——discover 會把 54 個模組收斂成一個判定，而一個
**import 就失敗**的模組跟一個「沒有測試」的模組在那個判定裡長得一模一樣。
`test_sflow_stats_endpoint.py` 用 `p4_proxy/venv/bin/python`，`p4_proxy/tests/*` 全部用它。

brief 點名的四個直接消費者**沒有改，而且是綠的**：

```
  ok    test_make_topology.py           Ran 29 tests   OK
  ok    test_twin_audit.py              Ran 39 tests   OK
  ok    test_twin_audit_criteria.py     Ran 63 tests   OK
  ok    test_contract_spec.py           Ran 126 tests  OK
```

它們不需要改，因為**這支修法沒有動任何一個它們斷言的東西**：`get_graph_data` 的形狀沒變、
合法拓樸端出的內容沒變、`make_topology.py` 產生的 port（host 側 1、交換機側 3 起跳）
全部落在新規則之內。

### C++：整支 gtest binary 與 ctest 都全綠

```
整支 binary   [==========] 979 tests from 125 test suites ran. (107468 ms)
              [  PASSED  ] 979 tests.                                rc=0

ctest         100% tests passed, 0 tests failed out of 979
              Total Test time (real) = 129.97 sec                    rc=0
```

（979 包含我新加的 14 條；`gtest_discover_tests` 讓 ctest 逐案跑，所以兩邊數字一致。）

**兩支最可能被我弄壞的既有測試都是綠的**：`test_TopologyAndFlowMonitor.cpp`／
`_mininet.cpp`（它們載入的就是出貨的 P4 檔），以及 `test_LeftBandwidthCapacity.cpp`
——後者自己寫了一份 inline 拓樸，我事先讀過：它宣告的三台交換機 dpid 5／9／10 與 edge 引用的
完全一致，interface 是 1／3／4，全部落在新規則內。

---

## 8. `git merge-tree`

分支兩個 commit：`2b2dcaa0`（碼＋測試＋閘門）、`f0ca0aa3`（閘門 M1 修正＋本文件）。

```
$ git merge-tree --write-tree trunk fix/topology-input-is-validated
d4c526108283e09965cda527af374c8e933c1357
rc=0            ← 沒有衝突
```

🔴 **注意：`trunk` 在我開工之後動過。** 我從 `92a79392` 開分支，最後一次跑這條指令時 `trunk` 已經是
`dae65b85`（今晚它動了好幾次）。上面那個 rc=0 是對**那個當下的 trunk** 跑的。

順帶對兩條被點名會重疊的分支也跑了。**它們在我開工時還停在 `b57736cd`（一個 commit 都還沒有），
現在兩條都推進了，所以下面是對「它們真的寫出來的東西」跑的**：

| 對象 | rc | 衝突在哪 |
|---|---|---|
| `fix/is-up-split-admin-state-reachable` (`76b8313e`) | 1 | **只有 `tests/CMakeLists.txt`** |
| `fix/kernel-stop-is-bounded` (`535f8f4b`) | 1 | **只有 `tests/CMakeLists.txt`** |

🔴 **兩邊唯一的衝突都是同一個檔案的同一個位置**：三個 agent 各自把自己的測試檔**接在
`test_routing_strategy` 那份來源清單的結尾**。這是三行併三行，保留全部即可，不是語意衝突。

🔴 **真正要看的是沒有衝突的那一行**：與 `fix/kernel-stop-is-bounded` 合併時，
`src/ndt_core/collection/TopologyAndFlowMonitor.cpp` 與 `src/main.cpp` 都是
**`Auto-merging`（自動合併成功）**——我們動的是同一個 `.cpp` 檔的**不同函式**
（它動 poll thread／`stop()`，我動 `parseStaticTopologyFile` 與檔案上方的匿名 namespace）。
「把 hunk 侷限在載入器裡」這條指示，在這裡是有實測結果的。
而 `GraphTypes.hpp`／`HttpSession.cpp` 我一個字都沒動，所以 is-up 那條連碰都沒碰到。

另外 `tests/shell/check_gate_anchors.py HEAD --gates mutate_topology_input_is_validated.sh`：
**`ok(11)`，1/1 cells ok，0 個沒被檢查**——閘門的錨點是那支工具讀得懂的寫法（FINDINGS #19
講的就是「閘門可以安靜地停止變異任何東西」，所以這一步不能省）。

---

## 9. 我**沒有**做的事

1. **沒有動 `include/common_types/GraphTypes.hpp` 的 `from_json`。** 那裡（`:662`／`:665`）
   也是原樣讀 `src_interface`／`dst_interface`、一樣沒有範圍檢查——但**它不是拓樸檔的載入路徑**
   （載入器是手寫抽取，不走 `from_json`），而那個檔今晚由 `fix/is-up-split-admin-state-reachable`
   在改。**我整份 diff 只碰 `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` 與 `tests/`**，
   沒有碰 `GraphTypes.hpp`、`HttpSession.cpp`、`main.cpp`。
2. **沒有收緊 `tools/contract_test/spec.py`。** 那裡 `src_interface`／`dst_interface` 是
   `Int(min=0)`，**沒有上限**——這正是 999999 通得過 contract test 的原因。我沒有加 `max=65535`，
   因為 spec.py 描述的是 **API 可以回什麼**，而 API 上的 interface 還有第二個來源：控制平面輪詢
   （`updateLinks`）。OF 1.3 的保留 port（`OFPP_LOCAL` = `0xfffffffe` 等）從 Ryu 回來是合法的，
   收緊 spec.py 會把那個變成假紅。**這是拓樸檔的規則，不是 API 的規則。**（見 §10 Q2）
3. **沒有實作「≤ 交換機的 port 數」那一半。** 出貨拓樸檔的 node 上**沒有任何 port 數欄位**
   （switch node 的鍵只有 `brand_name`／`bridge_name`／`device_layer`／`device_name`／`dpid`／
   `ecmp_groups`／`ip`／`mac`／`nickname`／`smart_plug_ip`／`smart_plug_outlet`／`vertex_type`），
   所以這個規則沒有輸入。**我沒有自己發明一個上限來假裝有檢查。**（見 §10 Q3）
4. **沒有檢查 `ecmp_groups[].members[].port_id`。** 那也是 port 欄位（出貨檔全部落在 1..24），
   但它不在 #61／#62 的重現路徑上，也不是 `get_graph_data` 端出的 edge 欄位。加它會讓 diff 溢出
   到 node 解析。（見 §10 Q3）
5. **node 迴圈裡既有的三個 throw 仍然是半套用。** `switch_kind` 認不得、switch `ip` 空陣列
   ——這兩個是在**加了一部分 vertex 之後**才 throw 的，圖上會留下殘骸。我的驗證只把 **edge 的**
   兩類錯誤提前到任何 `add_vertex` 之前。把那兩個也搬進驗證階段是對的，但那會改到三段不屬於
   #61／#62 的碼，我留著。
6. **沒有跑 lab、沒有跑 Mininet、沒有起 fabric。** 純載入路徑，brief 也說不需要。
7. **沒有 push。**

---

## 10. 給 Adam 的問題

**Q1（上限值）** `kMaxTopologyInterface = 65535` 是我挑的：夠寬鬆（現有最大 67）、又能擋六位數。
但它**不是協定推導出來的**——OF 1.3 底下 999999 是合法 port。要不要改成別的？三個候選：
(a) 維持 65535；(b) 依 OF 1.3 用 `0xffffff00`（那樣**擋不掉 999999**，#62 等於沒修）；
(c) 收到某個「這批機器合理的上限」例如 256 或 512。我選 (a)，因為它是唯一同時「擋得掉 999999」
且「不會擋到還沒買的交換機」的。

**Q2（contract spec）** `tools/contract_test/spec.py` 的 `src_interface: Int(min=0)` 要不要加上限？
我沒加，理由在 §9.2（控制平面輪詢會送保留 port）。但這代表**contract test 現在仍然會放行一個
999999**——只是拓樸檔那條路已經進不來了。要不要改成「只對拓樸檔來源的欄位設上限」？

**Q3（要不要收更多門）** 三個我看到但沒動的同類門：`from_json`（§9.1）、`ecmp_groups` 的
`port_id`（§9.4）、node 迴圈那兩個半套用的 throw（§9.5）。要不要另開工單？

**Q4（順便發現的）** `tools/contract_test/spec.py:348` 的 `inv_graph_matches_topology`
**本來就會比對「端出的 edge 數」與「拓樸檔的 edge 數」**——也就是說 40 → 39 這件事，
**檢查器早就知道怎麼看，只是 kernel 自己不知道**。這與 FINDINGS 第 22～24 條是同一個形狀
（知識存在，但不在會被執行的那段碼裡）。要不要把它記進 FINDINGS？
