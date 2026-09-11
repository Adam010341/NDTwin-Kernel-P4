# W3／#89・W-TOPO-THREE-DOORS：拓樸輸入驗證的其他三扇門

工單：`scratch/overnight-2026-09-04/recon/fixplan.md` §W3（第 616 行起）。
修的人：夜巡「W3 修法 agent」session，worktree `wt-integrate`，分支 `fix/w3-topology-three-doors`，
base＝trunk `f0687b34`。日期：2026-09-05。

[Co-developed with claude code -- Adam]

---

## 1. 一句話結論，以及 #89 的措辭要下修

**#61／#62 立的規矩是「整份先驗、再建」——但那條規矩的涵蓋面是手抄的，抄漏了四個欄位。**
這一輪把漏掉的補進同一個 `validateStaticTopologyJson`：
三個原本還坐在**建構迴圈裡**的 node 側 throw（門 3），加上**從頭到尾沒被看過**的
`ecmp_groups[].port_id`（門 2）。門 1（`from_json` 旁路）這一輪**只釘現狀、不改行為**。

### 🔴 #89 原本的措辭不成立，這是下修不是升格

`doc/audit/2026-09-03_night-rounds/WORK-ITEMS.md:149-151` 把 #89 記成
「contract test 看得見、kernel 看不見」的形狀。**那個框架在 40→39 這個實例上已經不成立**：

- 40→39 是 #61／#62，**已經修掉了**（`2b2dcaa0`，`validateStaticTopologyJson`）。
- `inv_graph_matches_topology`（`tools/contract_test/spec.py:380-405`，🟢 我開檔讀過）
  比的是 switch 數、host 數、edge 數三個**基數**，加上 switch dpid 的**集合恆等**
  （無重複、無多出、無缺少）。**它不比對每條 edge 的身分**，也**不讀 `ecmp_groups`**。
  ⇒ 它抓得到 40→39，抓不到「40 條但有一條接錯 port」。
- 🔴 **這三扇門，`inv_graph_matches_topology` 全部會回綠。**

⇒ 成立的宣稱是：**「還有四個輸入路徑，沒有任何一邊在檢查」**——
不是「檢查器比 kernel 聰明」。照 `02-recurring-mistakes` 的「揭露≠下修」：
**這是把 #89 的宣稱調弱，要明講，不可以拿新證據去撐舊措辭。**

## 2. 座標（🔵 讀碼，全部自己開檔核對過，對 trunk `f0687b34` 的工作樹）

| 位置 | 內容 |
|---|---|
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:130` | `kMaxTopologyInterface = 65535` |
| 同上 `:166-263`（修法前） | `validateStaticTopologyJson(json&, std::string&)`，匿名 namespace |
| 同上 `:589` | 它的唯一呼叫點，在第一個 `add_vertex` 之前 |
| 同上 `:636` | 🔴 門 3a：`switchKindFromString(nodeJson.at("switch_kind")…)` |
| 同上 `:652` | `vp.ecmpGroups = nodeJson.value("ecmp_groups", …)`（門 2 的入口） |
| 同上 `:664-669` | 🔴 門 3b：空 `"ip"` 的 SWITCH（＝#85 那扇門本身） |
| 同上 `:672-674` | 🔴 門 3c：MININET 模式下 `nodeJson.at("bridge_name")` |
| 同上 `:680` | `boost::add_vertex`，在迴圈**體的最底下**——三個 throw 都在它上面 |
| `include/common_types/GraphTypes.hpp:184-187` | `struct PortMember { int portId = 0; }`，**有號** |
| 同上 `:436-439` | 🔴 門 2：`from_json(json, PortMember&)`，`j.at("port_id").get<int>()`，**零檢查** |
| 同上 `:479-505` | 門 1：`from_json(json, VertexProperties&)` |
| 同上 `:676` | 門 1 的 `EdgeProperties` 版 |
| `TopologyAndFlowMonitor.cpp:702`／`DeviceConfigurationAndPowerManager.cpp:2259` | 兩處**被註解掉**的 `.get<VertexProperties>()`＋手寫抽欄位碼 |
| `tests/test_IsUpSplit.cpp:309`／`:339` | 門 1 今天**唯一的活呼叫者**，兩支都是測試 |
| `tools/contract_test/spec.py:380-405` | `inv_graph_matches_topology`——三個基數＋dpid 集合，如上 |

## 3. 根因

`validateStaticTopologyJson` 的**結構**是對的（整份先驗、再建），
但它的**涵蓋面**是一項一項手抄進去的：edge 的兩個端點驗了、node 的 ip 字串解析驗了，
**`ecmp_groups` 沒驗**、**`from_json` 那條旁路沒驗**，
而**三個舊的 node throw 還留在建構迴圈裡**。
所以「refused ⇒ 圖沒被動過」這個保證，有三個例外和一個死角。

🔴 **門 3 三扇的後果與 #61 一模一樣，只是走另一個門**：對第 N 個節點觸發時，
第 0…N−1 個已經 `add_vertex` 進去了。**`threw` 在修法前就已經是 true**——
只斷言「有沒有 throw」的測試，對整個門 3 會全綠。

## 4. 修法

### 門 3：三個條件上移到 `validateStaticTopologyJson`，**建構迴圈那三份留著**

🔴 **我沒有照工單寫的「建構迴圈只留 assert 或直接移除」做，這是刻意的偏離。**
理由與 #61 的 edge 守衛同一條（閘門檔頭 §「THE FIX HAS TWO LAYERS」已經寫過）：
兩層若哪天分歧，建構迴圈那一層**拒絕**仍然勝過**建半張圖**。
留著的代價是「單點變異無法完全復原缺陷」，而那正好是我要的鑑別力——
變異只拿掉驗證器那一份時，檔案**仍然被拒絕**，但是在 N−1 個節點進圖之後，
於是三支測試紅在 `vertices == 0` 而 `threw` 保持 true。
**這就是這張單與「讓 loader 會 throw」那種修法的差別，也是它唯一可被量測的差別。**

### 門 3c：這張單唯一的簽名變更

```cpp
validateStaticTopologyJson(json& j, std::string& where, utils::DeploymentMode mode)
```
呼叫點傳 `m_mode`。**非傳不可**：`bridge_name` 只有 MININET 分支會讀，
而**五份 `_ipAlias4_*` TESTBED 出貨檔的每一台交換機都沒有 `bridge_name`**——
一個不分模式的檢查會讓那五份全部載不進來，**比它要修的缺陷更大的停機**。
（這是 M8 那個「fleet-breaking」形狀在門 3c 上的複製品，閘門 M13 就是它。）

### 門 2：`ecmp_groups[].port_id` 加 `1..kMaxTopologyInterface`

**放在 `.cpp` 的 `validateStaticTopologyJson`，不放進 `from_json`**（照工單）：
`from_json` 也給 API／測試用，在那裡 throw 會改到別條路的行為，那是門 1 的範圍。

作法是在驗證器裡用**建構迴圈等一下會用的同一支 `from_json`** 先解一次
（`nodeJson.value("ecmp_groups", std::vector<EcmpGroup>{})`），再對解出來的 `portId` 檢查範圍。
副作用是**格式壞掉的 ecmp 群組也提前到 add_vertex 之前**——同一個門 3 形狀，順手關掉。

🔴 **不套用 host 側的「port 0 合法」豁免。** 那條豁免屬於 host **edge** 的 host 側
（`dpid == 0` 那一端，`doc/2026-01-02_ndt_api.md:233`）。
`ecmp_groups` **只長在 switch 節點上**，每個 member 指的都是交換機的 port，0 從來不合法。
把豁免搬過來是「因錯誤類比而過寬」，閘門 M16 專門抓它。

### 門 1：這一輪只釘現狀，不改行為

`from_json(VertexProperties&)` 今天**在生產碼沒有呼叫者**：
`src/`＋`include/` 兩處 `.get<VertexProperties>()` 都是**被註解掉的**，上面是手寫抽欄位碼。
唯一的活呼叫者是 `tests/test_IsUpSplit.cpp:309` 與 `:339`。
在它上面加 throw 會改到那兩支的行為 ⇒ **這一輪不加**，改成加一支結構斷言
`FromJsonHasNoProductionCallers` 當絆線：**哪天有人把 `from_json` 接進 kernel，它就紅**，
門 1 從此必須被裁決，而不是被繼承。**要不要真的加驗證，是給 Adam 的問題（§9）。**

🔴 **我沒有動 `include/common_types/GraphTypes.hpp`，一個字都沒有**（工單建議在 `:479` 上方加註解）。
理由是**排程**不是設計：那顆 header 幾乎被全樹 include，改一個註解就是全樹重編，
`HttpSession.cpp` 一個 TU 就約 1.6 GB，`JOBS=1`，而今晚 18:30 之後全機禁止建置。
門 1 的說明因此全部寫在這份文件與 `test_TopologyInputValidation.cpp` 的測試註解裡。
**這是刻意的取捨，不是漏掉。**

## 5. 我改了誰的東西

### 5.1 既有測試：**一支都沒改斷言**

⚠️ **交辦單說「工單說門 1 會動 `test_IsUpSplit.cpp:309,339`」——那是誤讀工單。**
工單原文說的是「**如果**在 `from_json` 上面加 throw，**就會**改到那兩支」，
而它同一段的建議是「這一輪只寫測試釘住現狀、不改行為」。
我照建議做 ⇒ **那兩支一個字都沒動**。

即使如此，我還是照指令先證明了它們在**未修的樹**上是綠的
（`scratch/overnight-2026-09-05/fix/W3-baseline-before-any-edit.log`，
binary sha256 `c953e233811b9cbb…`，rc=0，16 tests passed，其中兩支就是它們）。

### 5.2 既有閘門 `tests/shell/mutate_topology_input_is_validated.sh`

- **改了 1 個既有 anchor**：`validate-call` 從 `validateStaticTopologyJson(j, where);`
  改成 `…(j, where, m_mode);`——因為簽名變了。**判定不變**（M1 仍然是「整個驗證不被呼叫」）。
- 新增 5 個 anchor、7 個變異（M10–M16）、1 個對照（W4）。**既有 9 個變異與 3 個對照一字未改。**
- 🔴 **所有新變異只 mutate `.cpp`，而且只 mutate 驗證器那一份**，理由寫在腳本 §「#89」的檔頭。

### 5.3 沒有碰到的

`GraphTypes.hpp`（見 §4）、`tests/CMakeLists.txt`（沒開新檔，測試進既有的
`test_TopologyInputValidation.cpp`，所以 W1/W2/W4/W6 的那個序列化點我沒有排隊）、
`setting/` 底下任何檔案（commit 前 `git status --porcelain setting/` 為空）。

## 6. 測試

全部進既有的 `tests/test_TopologyInputValidation.cpp`（**沒開新檔**），
沿用它的 `TestableMonitor`／`MutatedTopology`／`LoadOutcome` 三件套。

🔴 **新增兩支選節點的 helper，`lastSwitchNodeIndex`／`lastEcmpNodeIndex`，選的是「最後一個」。**
這不是風格：門 3 每一支都斷言 `vertices == 0`，而**壞掉的第一個節點即使缺陷還在也會留下 0 個 vertex**
——拿第一個節點寫的測試，對它要量的缺陷會是綠的。**只有前面還有別的節點，才分得出
「拒絕了」與「拒絕了，而且圖已經建好一大半」。**

| 測試 | 斷言 | 門 |
|---|---|---|
| `AMalformedSwitchKindLeavesNoPartiallyLoadedGraph` | `threw` 且 `vertices == 0`、`edges == 0` | 3a |
| `AnAddresslessSwitchLeavesNoPartiallyLoadedGraph` | 同上 | 3b |
| `AMissingBridgeNameInMininetLeavesNoPartiallyLoadedGraph` | 同上（MININET 模式） | 3c |
| `AMissingBridgeNameIsNotCheckedInTestbedMode` | 🔴 對照：**同一份檔案在 TESTBED 仍然載得進來** | 3c |
| `AnOutOfRangeEcmpPortIdIsRefusedAtLoad` | `threw`、訊息**指名 999999**、`vertices == 0` | 2 |
| `AZeroEcmpPortIdIsRefusedAtLoad` | `threw`、`vertices == 0` | 2 下界 |
| `ANegativeEcmpPortIdIsRefusedAtLoad` | 同上（`portId` 是有號 int） | 2 下界 |
| `TheLargestInRangeEcmpPortIdIsAccepted` | 對照：65535 **不**被拒，14 vertices／40 edges | 2 上界 |
| `FromJsonHasNoProductionCallers` | 掃 `src/`＋`include/`，剝掉行註解後 `get<VertexProperties>`／`get<EdgeProperties>` 命中數為 0 | 1 |

既有的 `EveryShippedTopologyStillLoadsWithNothingDropped`（十三份出貨檔）
與 `TheTwoMininetCapableTopologiesStillLoadInMininetMode` **必須留綠**，是門 2／門 3c 的無回歸對照。

⚠️ **`FromJsonHasNoProductionCallers` 的限制寫在測試註解裡**：只剝行註解、不剝區塊註解，
所以用 `/* */` 註解掉的呼叫會被讀成活的、測試會為了錯的理由變紅。**那個方向是安全的那一邊。**

## 7. 閘門與看紅

`tests/shell/mutate_topology_input_is_validated.sh`（**擴充既有的，沒另開一支**）：
**16 變異＋4 對照**（原本 9＋3）。log：`scratch/overnight-2026-09-05/fix/W3-gate.log`。

| # | 變異 | 必死測試 |
|---|---|---|
| M10 | 門 3a 的檢查換成 `(void)0;`（驗證器那份） | `AMalformedSwitchKindLeavesNoPartiallyLoadedGraph` |
| M11 | 門 3b 的條件 `&& false` | `AnAddresslessSwitchLeavesNoPartiallyLoadedGraph` |
| M12 | 門 3c 的條件永不成立 | `AMissingBridgeNameInMininetLeavesNoPartiallyLoadedGraph` |
| M13 | 🔴 **過寬／錯模式**：`MININET` 寫成 `TESTBED` | 上面那支＋`AMissingBridgeNameIsNotCheckedInTestbedMode`＋`EveryShippedTopologyStillLoadsWithNothingDropped` |
| M14 | 門 2 上界拿掉 | `AnOutOfRangeEcmpPortIdIsRefusedAtLoad` |
| M15 | 門 2 下界拿掉（0 與負數都進得來） | `AZeroEcmpPortIdIsRefusedAtLoad`＋`ANegativeEcmpPortIdIsRefusedAtLoad` |
| M16 | 🔴 **過寬**：host 側的 port-0 豁免搬到 ecmp member（只有 0 進得來） | `AZeroEcmpPortIdIsRefusedAtLoad` |
| W4 | 對照：`portId < 1 \|\| … kMaxTopologyInterface` 改寫成 `portId <= 0 \|\| … 65535` | **留綠** |

🔴 **M12／M13 不可以把 `mode` 參數的唯一使用點刪掉**：`-Werror` 把 unused parameter 變成編譯錯誤，
而編不過的變異在這支閘門裡算 SURVIVED（正確——測試根本沒跑）。
那個 survivor 會是閘門自己的產物，不是測試的。腳本 §#89 檔頭寫了這條。

### 看紅（逐字）

🔴 **這一段的紅不是變異體造出來的，是「把 `TopologyAndFlowMonitor.cpp` 還原成 trunk `f0687b34`
原封不動那一份、只留新測試」跑出來的。**
log：`scratch/overnight-2026-09-05/fix/W3-run-03-RED-prefix-source.log`
（`src` sha256 `e858a637ecc883ee…`＝`git show f0687b34:` 那份；build rc=0、test rc=1；
**23 支跑、17 綠、6 紅**）。

**門 3（三支全部同一個形狀）——`threw` 沒紅，紅的是 `vertices`：**

```
[ RUN      ] TopologyInputValidationTest.AnAddresslessSwitchLeavesNoPartiallyLoadedGraph
tests/test_TopologyInputValidation.cpp:659: Failure
Expected equality of these values:
  out.vertices
    Which is: 9
  0u
    Which is: 0
the file was refused only after 9 vertices were already in the graph -- a partial application of a rejected file
[  FAILED  ] TopologyInputValidationTest.AnAddresslessSwitchLeavesNoPartiallyLoadedGraph (2 ms)
```

🔴 **這一段就是這張單的全部論點。** `EXPECT_TRUE(out.threw)` 那一行**沒有出現在失敗清單裡**
——修法前檔案**本來就會被拒絕**。紅的是 `out.vertices Which is: 9`：14 個節點的檔案，
拒絕發生時前 9 個已經在圖裡。**「有沒有 throw」與「有沒有留下半張圖」是兩個宣稱，
只有第二個會紅**，而只斷言第一個的測試對整個門 3 會全綠。
`AMalformedSwitchKindLeavesNoPartiallyLoadedGraph`（`:638`）與
`AMissingBridgeNameInMininetLeavesNoPartiallyLoadedGraph`（`:679`）逐字同形，同樣是 `9` vs `0`。

**門 2——反過來，`threw` 才是紅的，因為根本沒有任何檢查：**

```
[ RUN      ] TopologyInputValidationTest.AnOutOfRangeEcmpPortIdIsRefusedAtLoad
tests/test_TopologyInputValidation.cpp:717: Failure
Value of: out.threw
  Actual: false
Expected: true
an ecmp port_id of 999999 was accepted
tests/test_TopologyInputValidation.cpp:718: Failure
Expected: (out.messageSansPath.find("999999")) != (std::string::npos), actual: 18446744073709551615 vs 18446744073709551615
the refusal does not name the offending value: 
tests/test_TopologyInputValidation.cpp:720: Failure
Expected equality of these values:
  out.vertices
    Which is: 14
  0u
    Which is: 0
```

`vertices == 14` ＝ **整份檔案完整載入**，`port_id = 999999` 一路進到圖裡。
`AZeroEcmpPortIdIsRefusedAtLoad`（`:738`）與 `ANegativeEcmpPortIdIsRefusedAtLoad` 同形。

**三支對照組在修法前後都是綠的**（`AMissingBridgeNameIsNotCheckedInTestbedMode`、
`TheLargestInRangeEcmpPortIdIsAccepted`、`FromJsonHasNoProductionCallers`）——
**一支「改什麼都紅」的 harness 造不出這個 6 紅 3 綠的分佈。**

### 閘門的紅（M10–M16，變異體造的）

**驗收**：`16 mutations, 0 survived` ／ `4 widenings, 0 wrongly caught` ／ `GATE EXIT rc=0`
（16:33:51；還原後 `all 1 files byte-identical to the pre-run snapshot`、
`suite green again after restore`、`test binary sha unchanged: 1768429c6c1fb7f7`）。

M11 只拿掉**驗證器那一份**門 3b 檢查，逐字紅：

```
    | Expected equality of these values:
    |   out.vertices
    |     Which is: 9
    |   0u
    |     Which is: 0
    | the file was refused only after 9 vertices were already in the graph -- a partial application of a rejected file
```

**與上面「未修的 trunk」那一段一字不差**——這就是「兩層」設計的可量測後果：
變異只動驗證器，建構迴圈那一份照樣拒絕，所以紅的仍然只有 `vertices`。M10／M12 同形。

M13（門 3c 套到錯的模式）把出貨檔打掉，逐字：

```
    | setting/StaticNetworkTopology_ipAlias4_10Switches.json no longer loads: topology file "…": node #0 "s1" ip=["10.10.10.4"]: switch dpid 106225808402492 has no "bridge_name" string, and MININET mode attaches every switch to a bridge by that name
```

🔴 **這正是 M8 為 port 0 守的那個「比缺陷更大的停機」形狀**，在門 3c 上被抓住。

M16（host 側 port-0 豁免被搬到 ecmp member）逐字：

```
    | Value of: out.threw
    |   Actual: false
    | Expected: true
    | an ecmp port_id of 0 was accepted
```

**全套**：`build/bin/test_routing_strategy`（sha256 `1768429c6c1fb7f7…`，閘門還原後重建的那顆）
**1078 tests from 134 test suites ran / 1078 passed / rc=0**（`W3-run-04-full-suite.log`）。
改動前這棵樹是 1069 支 ⇒ **＋9 支，就是這張單新增的九支，沒有別的東西被動到。**

### anchor 對帳

`python3 tests/shell/check_gate_anchors.py 1d376070 --gates mutate_topology_input_is_validated.sh`
⇒ **`ok(16)`，`1/1 cells ok`，rc=0**（`W3-anchors.log`）。

🔴 **第一次跑是 rc=1，而且它抓到了一個真的 bug**：#89 把 `validateStaticTopologyJson` 加了第三個參數，
M1 的 anchor 還寫著 `(j, where)` ⇒ 16:01 那一輪 M1 判 `SURVIVED (anchor could not be applied)`，
**而整個測試套件是綠的**。這就是那支工具存在的理由
（`mutate_lock_renew_expiry.sh` 上一輪就是這樣掉了六個 anchor）。修在 `1d376070`。
**教訓寫進閘門 M1 的檔頭：動到被 anchor 的函式簽名，要跑的是 anchor checker，不是測試。**

## 8. 可達性口徑

**產線走得到。** 四扇門的輸入來源都是**拓樸檔**，而拓樸檔是使用者自己寫的
（`ndt up` 會餵、手冊教人改）。門 3 的後果是「kernel 帶著半張圖繼續跑，或退出時狀態不明」；
門 2 的後果是「一個超界或 0／負數的 `port_id` 進到 flow 路徑」。

⚠️ 🔵 **四扇門今晚一次都沒有量到，證據全部是讀碼＋新測試＋這支閘門。**
#61／#62 是在 :8000 上實測的（`round5-topology-repro`），**#89 不是**。
引用這份文件的人**不可以**把它們升格成 live 觀測。

## 9. 給 Adam 的問題

1. 🔴 **門 1 要不要真的加驗證？** `from_json` 今天沒有生產呼叫者，但它是一條**完全沒有守衛**的
   第二抽欄位路徑，而 `DeviceConfigurationAndPowerManager.cpp:2259` 也有一份同型的手抄碼
   （＝這個 codebase 有**三份**「同一件事的抽欄位邏輯」）。三個選項：
   (a) 維持現狀＋絆線（**這一輪做的**）；
   (b) 在 `from_json` 加同樣的檢查——會改到 `test_IsUpSplit.cpp:309,339` 的行為，要一起裁；
   (c) 反過來，把載入器改成**呼叫 `from_json`**，只留一份抽欄位邏輯——最乾淨，但那是重構單，
   而且會讓 `validateStaticTopologyJson` 與 `from_json` 的職責重新劃分。
2. **`kMaxTopologyInterface` 現在同時當 edge interface 與 ecmp port_id 的上界。**
   兩者確實都是交換機 port 索引，但這件事我是用同一個常數表達的；
   要不要拆成兩個具名常數（即使值相同），是可讀性 vs. 一致性的取捨。
3. **`GraphTypes.hpp` 我一個字都沒改**（§4 末）。若要補那段指向門 1 的註解，
   請排在**沒有建置禁令**的時段——那是全樹重編。

## 10. 沒做的

- **門 1 的行為沒有改**（見 §4、§9）。
- **`GraphTypes.hpp` 沒有動**（見 §4）。
- **同型盤點沒有做**：`validateStaticTopologyJson` 之外還有沒有別的「檢查坐在建構迴圈裡」，
  這一輪只處理工單點名的三處＋順手的 ecmp 格式。**不宣稱同型的其他實例不存在。**
- **`inv_graph_matches_topology` 沒有收緊**：它現在對這四扇門一律回綠（§1）。
  要不要讓契約測試也看 per-edge 身分與 `ecmp_groups`，是另一張單——
  這一輪只把「它看不見」這件事寫清楚。

## 11. FIX-DOORS-2（2026-09-11）：又四扇門，而這一輪的證據是 live

[Co-developed with claude code -- Adam]

§2 的門清單是**列舉**不是導出（09-11 夜巡 recon B §1 S2 把這件事寫成一個復發形狀），
而 ROLE-3 那天早上在 :8000 上把縫隙**跑出來了**。這一節記四扇新門、一個裁決、一個沒關的門。

### 11.1 四扇門

| 門 | 守什麼 | 位置 | 條目 |
|---|---|---|---|
| 4 | `link_bandwidth_bps` 必須存在、是整數、非負、且 **> 0** | `checkDeclaredLinkBandwidth`，驗證器 edge 迴圈開頭 | B-13 |
| 5 | `vertex_type` 只收 0／1，**在 `static_cast` 之前** | 節點迴圈第一件事 | B-14 |
| 6 | 6a 位址必須寫成點分四段；6b 全檔不得有兩個節點持同一個（parse 後的）位址 | 節點迴圈共用讀取處＋`checkEndpoint` 開頭 | B-15 |
| 7 | 非 HOST 節點的 `ip` 缺鍵／非陣列，改用門 3d 那種句子 | 門 3d 之後 | — |

### 11.2 「0 是不是合法的未知」——這一輪的裁決是**不是**（要 Adam 複核，見 SUMMARY §7）

三個理由，都可查：
1. **這個 repo 的未知慣例是 `-1`**（DCAPM 三個回報函式），而這一欄是 `uint64_t`，表達不了；
   ROLE-3 實測 `-1` 被 `get<uint64_t>()` 靜靜變成 `18446744073709551615`。
2. **手冊只有一種讀法**：`doc/2026-01-02_ndt_api.md` 的 `left_link_bandwidth_source`＝`declared`
   那一列寫「the figure is the topology file's `link_bandwidth_bps`」，沒有第三種狀態。
   要允許 0 就得同時教會 `leftBandwidth`／`leftBandwidthFromFlowSample`／`BandwidthSource`
   與利用率算式「未知」是什麼——那是一張新單，不是一扇門。
3. **十三份出貨檔只有 1 Gbit/s 與 10 Gbit/s**（逐檔對帳過，含五份 `_ipAlias4_`）⇒ 這扇門對艦隊零成本。

⚠️ **另一半沒做**：`link_bandwidth` 也會被 **sFlow counter sample** 寫入
（`updateLinkInfo` 的 `edgeProps.linkBandwidth = interfaceSpeed`），而 `ifSpeed = 0`
是 SNMP／sFlow 對「速度未知」的標準值，**那條路徑零檢查、而且就在同一個除法旁邊**。
⇒ **檔案不能再宣告 0，交換機還是可以回報 0。** 那是 runtime 門，不是這張單。
（這正是 recon B §1 S7「除數沒有人守」那一條，這一輪只關了它的檔案這一半。）

### 11.3 `get_average_link_usage` 為什麼對 `null` 免疫（ROLE-3 §6.3 沒追，這裡追完）

`TopologyAndFlowMonitor::getAvgLinkUsage` 的累加條件是
`linkBandwidthUsage != 0 && 兩端都不是 HOST`。而容量 0 的邊，
`linkBandwidthUsage = leftIn > linkBandwidth ? 0 : linkBandwidth - leftIn` 兩條路都給 **0**
⇒ **那些邊被 `!= 0` 跳過**，`noneZeroEdgeNum` 停在 0，函式回 `0`。
⇒ **它不是「把 NaN 當 0 吃掉」，是整批邊根本沒進累加器。**
🔴 **免疫來自算術巧合，不是來自任何人注意到**——而 `0` 同時是
「沒有量到」與「量到 0」的答案（B-8 那個形狀），所以
`{"avg_link_usage":0.0,"status":"success"}` 與「四十條邊全壞」在回應上不可分辨。
**這一輪沒有改它**（門 4 讓檔案面到不了這個狀態；sFlow 面到得了，見 11.2）。

### 11.4 寬鬆位址：拒絕，不是 warning＋正規化寫回

`inet_aton` 對 `"10.1"`／`"167772161"`／`"0x0a000001"` 都回 10.0.0.1。選拒絕，因為：
- **repo 已經為同一個理由裁過一次**：`utils::tryParseUint64` 之所以取代 `std::stoull`，
  逐字理由是「a mistyped dpid must be refused, not silently redirected to a different switch」。
- **正規化寫回＝載入器改寫使用者的文件語意**，而這整支函式的立場是「拒絕，不修補」
  （#61 的註解自己寫：refused 要意味著圖沒被碰過，而不是「refused, and also here is most of it」）。
- 十三份出貨檔（節點與邊兩側）**零非標準拼法**。
⇒ 但這是**政策**不是事實，SUMMARY §7 列給 Adam 覆蓋。

### 11.5 門 7 為什麼在門 3d 之後、而且跳過 HOST

門 7 與門 3d 講同樣兩件事（缺鍵／非陣列），差別只有**名詞**。
若把門 7 寫成「每一種節點」，它會**先跑**，門 3d 的兩條臂就再也到不了
⇒ 閘門的 **M18／M19 會從 caught 變成 survived**，而所有測試照樣綠。
所以新增 `AHostWithNoIpKeyIsStillNamedAsAHost`（斷言訊息裡有 `host "<name>"`）＋ **M48**
把「順序」變成可量測的宣稱，而不是一句描述。

### 11.6 閘門

`mutate_topology_input_is_validated.sh` 由 33 顆變異 ＋ 9 個 widening 加到
**48 顆變異 ＋ 12 個 widening**（M34–M48、W10–W12），13 個新 anchor。
其中 **M45 是 `mutate2`**：ROLE-3 的 `b5-loose.json` 被 6a 與 6b **各自**攔得住，
所以任何單點編輯都復原不了那個檔——照 M2／M31 的前例，一顆變異改兩處並且明說它改了兩處。
