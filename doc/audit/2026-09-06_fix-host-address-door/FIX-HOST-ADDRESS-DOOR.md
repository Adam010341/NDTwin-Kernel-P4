# W3 門 3d／#90 — 拓樸驗證器的第四扇 node 門：沒有位址的 **host**

工單：`scratch/overnight-2026-09-05/fix/TICKETS-0906/W3-3b-and-W15-validator.md`（分支 1）。
裁決正本：`scratch/overnight-2026-09-05/DECISIONS.md` 第五輪——
「**W3 門 3b 也擋 host `ip:[]`**（補一道，W3 續）」。
修的人：09-06 下半場「W3-3b／W15 修法 agent」session，worktree `wt-val`，
分支 `fix/w3-door3b-host-empty-ip`，base＝trunk `1536ff17`。日期：2026-09-06。

[Co-developed with claude code -- Adam]

---

## 1. 一句話，以及為什麼它叫「門 3d」而不是「門 3b」

**#89 的門 3b 寫成 `vertexType == VertexType::SWITCH && addresses.empty()`，
而 R0b 量到的缺陷是同一句話的另外一半：同樣的檔案錯誤放在 host 上就被收下。**

工單稱它「門 3b（host）」，但 **`3b` 這個代號在碼裡、閘門裡、測試裡都已經是交換機那一扇**
（`AnAddresslessSwitchLeavesNoPartiallyLoadedGraph`、閘門 M11、anchor `door3b-noip`）。
沿用同一個字母會讓「M11 抓的是哪一扇」變成要靠上下文猜。
⇒ **碼與閘門裡一律叫 `door 3d`**（3a switch_kind／3b switch ip／3c bridge_name 之後的下一個字母），
文件與 SUMMARY 兩個名字都寫，指的是同一件事。

## 2. 缺陷（🟢 這一扇是**量到的**，不是讀碼推的）

`scratch/overnight-2026-09-05/rounds/05-R0b-postmerge2.md`，2026-09-05 19:31–19:41，
kernel binary `862c4bf8efa048bc`，trunk `2285c63c`，OVS4 平面。六個壞檔的第 **a** 個：

| # | 壞法 | R3（kernel `4c9e0be1`） | R0b（kernel `862c4bf8`） | 一個字 |
|---|---|---|---|---|
| **a** | 多一台 `"ip": []` 的 **host** | ❌ 收下 rc=124，**零訊息** | ❌ **收下 rc=124**，零訊息 | **未修** |
| **b** | **switch** 的 `"ip"` 留空 | ✅ 拒絕 rc=1 | ✅ **拒絕 rc=1** | 成立 |

同一輪 §2 的實測：`ip:[]` 的 host **進得了圖**，9 支端點打下去 kernel 不炸
（SIGSEGV 0、`[error]` 0），`get_graph_data` 把它回成 **`('h9', [])`**。
R0b 自己在「要問 Adam 的」第 7 題把這件事寫成問題：
「**門 3b 的條件寫死 `vertexType == VertexType::SWITCH`，是刻意的嗎？**」
⇒ 這份文件是那一題的答案：**不是刻意的，補上。**

### 2.1 為什麼「不炸」不等於「可以收」

#88（W2）給十六處 `ip.front()` 加了守衛，所以 R0b 打端點時 kernel 沒有崩——
**那是執行層「不炸」，不是檔案層「不收」。** 而 #88 自己的盤點（`W2-SUMMARY.md` §2.2）
用 `ip[0]` 又找到**七處**沒有守衛的解參考，其中 **五處在 host 側而且產線走得到**：

| 檔案:行 | 運算式 | 型別 |
|---|---|---|
| `IntentTranslator.cpp:665` | `ipToString(vprop.ip[0])` | **HOST** |
| `IntentTranslator.cpp:702` | `ipToString(vprop.ip[0])` | **HOST** |
| `LLMAgent.cpp:243` | `ipToString(vprop.ip[0])` | **HOST** |
| `FlowLinkUsageCollector.cpp:2986` | `graph[*srcHostOpt].ip[0]` | **HOST** |
| `FlowLinkUsageCollector.cpp:2987` | `graph[*dstHostOpt].ip[0]` | **HOST** |

**這五處 W2 明講沒有修**（`W2-SUMMARY.md` §6）。它們假設的那個不變式
——「圖裡的 host 至少有一個位址」——今天**只有這扇門能讓它成真**。

### 2.2 🔴 可達的形狀只有一種：**多一台沒有位址的 host**，不是「把現有 host 的位址拿掉」

**這是我第一版測試量錯的地方，記在這裡讓下一個人不用重踩。**
把出貨檔裡**現有**的 host 的 `"ip"` 清空 ⇒ 那台 host 的兩條 edge（`src_dpid: 0`，用位址解）
從此解不到任何節點 ⇒ **#61 的 edge 門先把整份檔案擋下來**。修法前後都擋、都 `vertices == 0`
⇒ 拿這個形狀寫的測試對門 3d **零鑑別力**。

🟢 逐字（2026-09-06，trunk `1536ff17` 原始碼＋新測試）：

```
the refusal does not name the offending host: topology file "": edge #38 src_ip=["10.0.0.4"]
dst_ip=["192.168.123.14"] src_dpid=0 dst_dpid=4: "src_dpid" is 0, so this end is resolved by
address, and no node in this file carries 10.0.0.4. Refusing the file: ...
```

而閘門從另一邊講了同一句話：**M17（門 3d 不觸發）判 `SURVIVED`**，因為那一支照樣綠。
**R0b §2 其實已經寫過為什麼**：「沒有位址就沒有 edge 指得到它」——
所以 R0b 的壞檔 `a` 是「**多**一台」而不是「改一台」。
⇒ 測試改成 `appendAddresslessHost()`：**複製最後一台 host、改名 `h9`、`ip` 清空、加在最後面**，
沒有任何 edge 指向它。修法前它會整份載入（15 節點／40 邊），修法後 0／0。

**副產物**：既有 host 被拿掉位址時，修法前後都拒絕，但**訊息從指著 edge 變成指著 host**
（門 3d 在 node 迴圈，整段跑完才輪到 edge 迴圈）。那是一個**診斷品質**的宣稱，不是
「有沒有收下」的宣稱，用 `AnExistingHostLosingItsAddressNowNamesTheHostNotTheEdge` 釘住，
兩條斷言缺一不可（第二條 `不含 "no node in this file carries"` 才擋得住舊訊息蒙混過關）。

### 2.3 而且 host 比 switch 更需要位址

switch 用 dpid 找（`dpidToVertex`、`switchDpids`），位址是**附帶**的。
host 的 `"dpid"` 是 **0**（`doc/2026-01-02_ndt_api.md:233` 就是這樣定義的），
所以**位址是它唯一的身分**：edge 迴圈那一半（`dpid == 0` ⇒ 用 `src_ip`/`dst_ip` 解）、
`findVertexByIpNoLock`、以及上面那五處，全部靠它。
一台沒有位址的 host 是**沒有任何東西叫得動的節點**。

## 3. 修法

`src/ndt_core/collection/TopologyAndFlowMonitor.cpp`，
`validateStaticTopologyJson` 的 node 迴圈裡，**在共用的 `at("ip")` 讀取之前**：

```cpp
if (vertexType == VertexType::HOST)
{
    const char* fault = nullptr;
    if (!nodeJson.contains("ip"))                 { fault = "declares no \"ip\" key at all"; }
    else if (!nodeJson.at("ip").is_array())       { fault = "declares an \"ip\" that is not an array…"; }
    else if (nodeJson.at("ip").empty())           { fault = "declares an empty \"ip\" array"; }
    if (fault != nullptr) { throw std::runtime_error(who + " " + fault + "; every host needs…"); }
}
```

三件事值得說明：

1. 🔴 **放在共用讀取之前，是為了訊息不是為了拒絕。**
   「缺 key」與「非陣列」**本來就會被拒絕**——被下面那行共用的
   `nodeJson.at("ip").get<std::vector<std::string>>()` 拒絕，而且同樣在第一個 `add_vertex` 之前，
   所以 `threw` 與 `vertices == 0` 對這兩種**修法前就是綠的**。
   變的只有操作者看到什麼：`[json.exception.out_of_range.403] key 'ip' not found`
   → 一句人話。**這正是 R0b 對門 3c 的 `bridge_name` 記的同一條抱怨**
   （R0b 第 1 項 d：「訊息從 nlohmann 例外改寫成人話」）。
   ⇒ 這兩種的可量測宣稱**只有訊息那一條**，測試就照這樣寫（§5），閘門 M18／M19 就是證明它承重。
2. 🔴 **`switch` 的規則一個字都沒動。** 工單要我讀 FIX 文件確認「W3 是不是裁過 switch 可以沒 ip」——
   **沒有裁過那件事，剛好相反**：`FIX-TOPOLOGY-THREE-DOORS.md` §2 的門 3b 就是
   「空 `"ip"` 的 SWITCH ⇒ 拒絕」，來源是 #85。所以 switch 側**本來就是拒絕**，
   這一輪不需要也沒有改它；改的只有 host 側從「收下」變成「拒絕」。
3. 🔴 **建構迴圈裡沒有加第二份，這是刻意的偏離 #89 的兩層作法。**
   #89 留著建構迴圈那三份，理由是「它們本來就在，刪掉會失去 backstop」。
   門 3d **沒有既有的建構迴圈版本**（那裡的 `vp.vertexType == VertexType::SWITCH && vp.ip.empty()`
   也是 switch-only），而一個**新加的** backstop 只可能在 `0..N-1` 已進圖之後才觸發
   ——那正是 #61 要廢掉的半套用。門 3d 的第二層是 **#88 的執行層守衛**，
   是**另一種**層（「不炸」而不是「拒絕」），兩層都留，這也是工單寫的口徑。
   碼裡在建構迴圈那個 switch throw 上面留了註解說明這件事。

### 3.1 訊息長什麼樣

```
topology file "…/x.json": node #13 "h4" ip=[]: host "h4" declares an empty "ip" array; every host
needs at least one address. A host carries "dpid": 0, so an address is the only thing that
identifies it -- to the link resolution below, and to the top-K, intent and last-hop paths, which
read the first one without checking that there is one
```

## 4. 🔴 我把一支既有的綠測試**反轉**了，這一節專門講它

`tests/test_SwitchKindDispatch.cpp` 的
`TopologyIpValidationTest.AHostWithNoAddressIsStillAllowed` 斷言 `EXPECT_NO_THROW`，
註解寫的理由是：

> "The invariant belongs to switches only. Hosts are discovered by Ryu and legitimately have no
> address until then -- **rejecting them would refuse every topology that lists hosts before
> discovery, which is all of them**."

前半是設計主張，後半是**關於出貨檔的事實主張，而它是假的**（🟢 我自己掃了十三份）：

| 檔案數 | 每台 host 的位址數 | 沒有位址的 host |
|---|---|---|
| 8（OVS／P4／Mininet） | **1** | **0** |
| 5（`_ipAlias4_*` TESTBED） | **4** | **0** |
| **13** | — | **0** |

`tools/make_topology.py:126` 產生器也是每台 host 一定給 `["10.0.0.<i>"]`。
⇒ **沒有任何一份出貨拓樸列了沒有位址的 host，所以拒絕它拒絕不到任何人手上的檔案。**
而「Ryu 之後才發現」那條路走的是另一段碼（`updateHosts`），
`validateStaticTopologyJson` 從頭到尾只看**靜態檔**，動不到它。

⇒ 測試改名為 `AHostWithNoAddressIsRefusedAtLoad`，斷言反過來，
**舊註解逐字抄進新註解裡並註明是哪一天、依據什麼反轉的**，
另外補一支對照 `AHostWithAnAddressStillLoads`。
**這是這一輪唯一一支被改掉斷言的既有測試**，其餘一支未動。

## 5. 測試（全部進既有檔案，沒開新檔）

`tests/test_TopologyInputValidation.cpp`（沿用 `MutatedTopology`／`LoadOutcome`／`loadFile`），
新增 helper `lastHostNodeIndex`（理由與 `lastSwitchNodeIndex` 相同：要有節點排在它前面）。

| 測試 | 形狀 | 斷言 | 修法前紅在哪 |
|---|---|---|---|
| `AnAddresslessHostLeavesNoPartiallyLoadedGraph` | **多一台** `h9` | `threw`、`vertices == 0`、`edges == 0` | **三條全紅**（檔案本來整份載入） |
| `TheAddresslessHostRefusalNamesTheHost` | **多一台** `h9` | 訊息含 `host "h9"` | `ASSERT_TRUE(threw)` |
| `AnExistingHostLosingItsAddressNowNamesTheHostNotTheEdge` | 清空既有 host | 訊息含 `host "h4"` **且不含** `no node in this file carries` | 兩條都紅（訊息是 edge 門的） |
| `AHostWithNoIpKeyAtAllIsRefusedInPlainLanguage` | 刪 `ip` 鍵 | `threw`、`vertices == 0`、訊息**不含** `json.exception` | **只有最後一條**（見 §3.1） |
| `AHostWhoseIpIsNotAnArrayIsRefusedInPlainLanguage` | `ip` 給字串 | 同上 | 同上 |
| `AHostWithMoreThanOneAddressStillLoads` | 加第二個位址 | 對照：仍載入，14 節點／40 邊 | 修法前後都綠 |
| `TopologyIpValidationTest.AHostWithNoAddressIsRefusedAtLoad` | 無 edge 的兩節點檔 | 反轉（§4），訊息含 `host "h1"` | `EXPECT_NO_THROW` 變 `FAIL()` |
| `TopologyIpValidationTest.AHostWithAnAddressStillLoads` | 同上但有位址 | 對照 | 都綠 |

🔴 **`TheAddresslessHostRefusalNamesTheHost` 找的是 `host "h9"` 而不是 `h9`。**
rethrow 會在每一則訊息前面加上 `describeTopologyItem` 的 `node #14 "h9" ip=[]`，
所以找裸名字的斷言**會被前綴滿足**、在訊息完全沒有指名的情況下照樣綠。
這與這個檔案頂端 `without()` 存在的理由是同一條：**儀器不可以自己生出答案。**

既有的 `EveryShippedTopologyStillLoadsWithNothingDropped`（十三份）與
`TheTwoMininetCapableTopologiesStillLoadInMininetMode` 是**無回歸對照**，必須留綠。

### 5.1 看紅（逐字）

🔴 **這一段的紅不是變異體造出來的**，是把 `TopologyAndFlowMonitor.cpp` 還原成
trunk `1536ff17` 那一份、**只留新測試**跑出來的。
log：`scratch/overnight-2026-09-05/fix/w3d-logs/02-w3d-redgreen2.log`
（base 檔 sha256 `3aaafb6650ac6afe…`＝`git show 1536ff17:` 那一份，兩者逐位元組相同；
修法版 sha256 `deeb5d0b7bbc00b8…`）。
**33 支跑、27 綠、6 紅**；修法後同一組 **33 支全綠**。

**主張本身（多一台沒有位址的 host）：**

```
[ RUN      ] TopologyInputValidationTest.AnAddresslessHostLeavesNoPartiallyLoadedGraph
tests/test_TopologyInputValidation.cpp:954: Failure
Value of: out.threw
  Actual: false
Expected: true
a host with an empty "ip" array was accepted; the measured consequence was a node served as ('h9', []) on :8000
tests/test_TopologyInputValidation.cpp:956: Failure
Expected equality of these values:
  out.vertices
    Which is: 15
  0u
    Which is: 0
the file was refused only after 15 vertices were already in the graph -- a partial application of a rejected file
tests/test_TopologyInputValidation.cpp:959: Failure
Expected equality of these values:
  out.edges
    Which is: 40
  0u
    Which is: 0
[  FAILED  ] TopologyInputValidationTest.AnAddresslessHostLeavesNoPartiallyLoadedGraph (3 ms)
```

`vertices == 15`／`edges == 40` ＝ **十四個節點的檔案加上那一台，整份完整載入**。
🔴 **這與門 3a–3c 的紅不同形**：那三扇修法前 `threw` 就已經是 true（拒絕發生在建構迴圈裡），
紅的只有 `vertices`；門 3d **連 `threw` 都是紅的**，因為檔案根本沒有被拒絕。

**診斷品質那一支（清空既有 host）——紅在「訊息指著 edge」：**

```
[ RUN      ] TopologyInputValidationTest.AnExistingHostLosingItsAddressNowNamesTheHostNotTheEdge
tests/test_TopologyInputValidation.cpp:1003: Failure
Expected: (out.messageSansPath.find("host \"" + name + "\"")) != (std::string::npos), actual: … vs …
the refusal still points at the edge rather than at the host: topology file "": edge #38
src_ip=["10.0.0.4"] dst_ip=["192.168.123.14"] src_dpid=0 dst_dpid=4: "src_dpid" is 0, so this end
is resolved by address, and no node in this file carries 10.0.0.4. …
```

**訊息品質那兩支（缺 key／非陣列）——`threw` 與 `vertices` 都沒紅，只有訊息紅：**

```
tests/test_TopologyInputValidation.cpp:971: Failure
Expected equality of these values:
  out.messageSansPath.find("json.exception")
    Which is: 34
  std::string::npos
the refusal is a raw nlohmann exception, not a diagnostic: topology file "": node #13 "h4":
[json.exception.out_of_range.403] key 'ip' not found
```

⇒ **三種宣稱，三種不同的紅**，而兩支對照組（`AHostWithMoreThanOneAddressStillLoads`、
`AHostWithAnAddressStillLoads`）與其餘 27 支從頭到尾是綠的
——**一支「改什麼都紅」的 harness 造不出這個 6 紅 27 綠的分佈。**

## 6. 閘門

擴充既有的 `tests/shell/mutate_topology_input_is_validated.sh`（**沒另開一支**）：
**新增 4 個 anchor、4 個變異（M17–M20）、1 個對照（W5）**，並把五支新測試加進 M1 的必死清單。
既有的 16 個變異、4 個對照**一字未改**。

| # | 變異 | 必死測試 |
|---|---|---|
| M17 | 門 3d 整扇不觸發（`&& false`） | 五支全部 |
| M18 | 只拿掉「缺 key」那一臂 ⇒ 落到門內自己的 `at("ip")`，回 nlohmann 例外 | 只有 `…NoIpKeyAtAll…` |
| M19 | 只拿掉「非陣列」那一臂 ⇒ 落到共用讀取，回 `type_error.302` | 只有 `…NotAnArray…` |
| M20 | 🔴 **過窄／打爆出貨檔**：`empty()` 寫成 `size() != 1` | `EveryShippedTopologyStillLoads…` ＋ `AHostWithMoreThanOneAddressStillLoads` |
| W5 | 對照：`empty()` 寫成 `size() == 0` | **留綠** |

**M20 是這一組的 M8／M13**：五份 `_ipAlias4_` 檔每台 host 給四個位址（那就是檔名的意思），
「host 需要一個位址」讀成「host 有**一個**位址」會讓 160 台 host、五份檔案載不進來
——比它要修的缺陷更大的停機。而 **M20 的兩支必死測試裡沒有任何一支是「沒有位址」的案例**
（0 也 `!= 1`，那些照樣被擋），所以只有對照組看得見它。

### 🔴 6.1 這支閘門今天抓到的是**我的測試**，不是產品碼

**第一輪 M17 判 `SURVIVED`**（`20 mutations, 1 survived`，
`scratch/overnight-2026-09-05/fix/w3d-logs/01-w3d-redgreen.log`），逐字：

```
🔴 SURVIVED -- these stayed green: TopologyInputValidationTest.AnAddresslessHostLeavesNoPartiallyLoadedGraph
   (something else went red: …AHostWhoseIpIsNotAnArray… …AHostWithNoIpKeyAtAll… …TheAddresslessHostRefusalNamesTheHost
    -- the gate fires, but not for the reason this mutation claims)
```

原因就是 §2.2：那一支用「清空既有 host」的形狀，**門關掉它照樣綠**。
**整個測試套件當時是綠的（1089/1089），只有閘門說了話**——與 #89 那次
「`check_gate_anchors.py` 抓到 anchor 漂移而測試全綠」同一個形狀，今晚第二次。
修法是換掉 fixture（`appendAddresslessHost`），不是放寬閘門。
教訓寫進 M17 的檔頭與那支 helper 的註解：**不要把 fixture「簡化」回去。**

## 7. 可達性口徑

**產線走得到，而且走過了。** 輸入是使用者自己寫的拓樸檔（`ndt up` 會餵、手冊教人改）。
🟢 **空陣列那一半是 :8000 實測**（R0b，kernel `862c4bf8`，`('h9', [])`）。
🔵 **缺 key／非陣列那兩半沒有 live 量過**，而且它們**本來就會被拒絕**——
那兩條的宣稱是**訊息**，不是「有沒有收下」。**引用時不可以把三者混成一句「host 側沒有檢查」。**

## 8. 沒做的

- **沒有動 `switchKindFromBrandName`／`GraphTypes.hpp`**（那是同一個 agent 的分支 2／W15）。
- **沒有修 W2 §2.2 那七處 `ip[0]`**：不是這張單的範圍，而且門 3d 讓其中五處的前提成真並不等於
  它們有守衛——**哪天有人繞過載入器建圖，那五處還是裸的**。
- **`inv_graph_matches_topology` 沒有收緊**：它比的是 switch／host／edge 三個基數與 dpid 集合
  （`tools/contract_test/spec.py:380-405`），**對這扇門一樣回綠**——一台 host 少不少位址它不看。
  同 #89 的 §10，這仍然是另一張單。
- **`tools/contract_test/spec.py` 的 `GRAPH_NODE["ip"] = IP_LIST` 沒有動**：那是
  `get_graph_data` **輸出**的契約（允許空陣列），與拓樸**輸入檔**的規則是兩件事。
  真要收緊是另一張單，而且要先確認沒有 Ryu-discovered host 會短暫回空陣列。
- **沒有 live 驗證這次的修法**：這一輪一個 kernel 都沒有跑（lab 空著、也不歸我碰）。
  §2 引的是 R0b 的量測，不是我的。
