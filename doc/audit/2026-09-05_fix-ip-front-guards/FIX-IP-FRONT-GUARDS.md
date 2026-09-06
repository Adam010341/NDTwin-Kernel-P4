# W2／#88：無守衛的 `ip.front()`——那扇門比靠它的呼叫點窄

工單：`scratch/overnight-2026-09-04/recon/fixplan.md` §W2。
修的人：夜巡「W2 修法 agent」session，worktree `scratch/overnight-2026-09-05/wt-w2`，
分支 `fix/w2-ip-front-guards`（base：trunk `f0687b34`）。日期：2026-09-05。

[Co-developed with claude code -- Adam]

---

## 1. 一句話結論

「每個節點至少有一個位址」這條不變式，由**另一個子系統的一行 `if`** 撐著
（`TopologyAndFlowMonitor.cpp:664`，只擋 `vertexType == SWITCH` 的**節點**），
而依賴它的呼叫點涵蓋**任意端點＋edge**——**條件比依賴它的集合窄**。
修法不是「到處加 `empty()`」，而是分成兩種語意：
**搜尋時**沒有位址的候選就是**不匹配**（正確答案，不是降級）；
**取值時**拿不到位址就**跳過並把跳過這件事說出來**（不可以靜靜跳過，更不可以編一個 `0.0.0.0`）。

🔴 **可達性分兩級，不可混寫**（詳見 §8）：
A／B 兩組**產線走不到**（照 #85 的降級口徑）；
**C 組（HOST）與 D 組（edge）產線走得到**——載入端的門不管 HOST，也一個字都沒查 edge 的
`srcIp`／`dstIp`。**這一份不可以照抄 #85 的「缺陷成立、線上不可達」。**

## 2. 座標

### 2.1 🔴 工單的行號有三處漂移，這是實測對帳後的正本

工單 §W2 的座標是對 trunk `f943de8f` 開檔讀的；本分支 base 是 `f0687b34`，
**`TopologyAndFlowMonitor.cpp:2626` 之後整段位移 +60，`DeviceConfigurationAndPowerManager.cpp:410`
之後位移 +30**。工單開頭已列的三條更正（#88 點名的「同檔三處」其實在 DCPM、edge 那組是十處不是九處、
C 組產線走得到）我全部複驗成立，**再加這一條行號漂移**。

| 組 | 工單寫的行 | `f0687b34` 實際行 |
|---|---|---|
| A `findSwitchByIp`／`NoLock` | `:3377`／`:3391` | **`:3437`／`:3451`** |
| B `getSingleSwitchPowerReport` | `:2319` | **`:2349`** |
| B `getSingleSwitchCpuReport` | `:2348` | **`:2378`** |
| C `getTopKCongestedLinksJson` | `:4178`／`:4179` | **`:4238`／`:4239`** |
| B `queryMininet`、D 全部十處 | `:410`、`:2127`…`:2626` | **完全相符，沒有漂移** |

### 2.2 修到的十六處（工單口徑：C 組兩行算一處）

**A 組——vertex，搜尋時的比對（`TopologyAndFlowMonitor.cpp`）**

| 行 | 函式 | 修法 |
|---|---|---|
| `:3437` | `findSwitchByIp` | 加 `!vprop.ip.empty() &&` |
| `:3451` | `findSwitchByIpNoLock` | 同上 |

**B 組——vertex，取值（`DeviceConfigurationAndPowerManager.cpp`）**

| 行 | 函式 | 修法 |
|---|---|---|
| `:410` | `queryMininet` | `firstAddressOf`，`nullopt` 跳過該台 |
| `:2349` | `getSingleSwitchPowerReport` | `firstAddressOf`，`nullopt` 回空物件（與「找不到」同口徑） |
| `:2378` | `getSingleSwitchCpuReport` | 加 `!vp.ip.empty() &&`，**`== deviceIdentifier` 一個字不動** |

⚠️ `:2378` 的 `==` 是 shell-injection 防線（`deviceIdentifier` 之後流進 `execArgv`／`snmpget`）。
**修法沒有放寬它**，而且這件事有自己的紅線測試（M7）。

**C 組——🔴 HOST 也走得到（`TopologyAndFlowMonitor.cpp:4238-4239`）**

綁的是 `ipToString` 的 **vector 多載**（`include/utils/Utils.hpp`，**傳值**、回 `vector<string>`），
空進空出 ⇒ `.front()` 是在**剛做出來的空 vector** 上。而 `v1`／`v2` 來自對 `boost::edges` 的走訪，
**完全沒有 `vertexType` 過濾** ⇒ 一個 `"ip": []` 的 HOST 節點在這裡炸。
修法：兩端任一取不到位址就**跳過這條 link**，並在回應加 `links_skipped_no_address`。

**D 組——edge `srcIp`／`dstIp`，十處（`TopologyAndFlowMonitor.cpp`）**

| 行 | 函式 | 形狀 |
|---|---|---|
| `:2127` | `updateLinkInfo` | 取值 → 空就記一次 WARN 後返回 |
| `:2437` | `findEdgeByAgentIpAndPort` | 比對 → 加 `!props.srcIp.empty() and` |
| `:2457` | `findEdgeToHostByAgentIpAndPort` | 同上 |
| `:2483` | `findReverseEdgeByAgentIpAndPortNoLock` | 同上 |
| `:2534` | `findReverseEdgeByAgentIpAndPort` | 同上 |
| `:2584` | `findEdgeByAgentIpAndPortNoLock` | 同上 |
| `:2604` | `getAgentKeyFromTheOtherSide` | 比對（`dstIp`） |
| `:2607` | 同上 | 取值（`srcIp`）→ 空就回 `nullopt` |
| `:2623` | `getAgentKeyFromTheOtherSideNoLock` | 比對（`dstIp`） |
| `:2626` | 同上 | 取值（`srcIp`）→ 空就回 `nullopt` |

`:2437/2457/2483/2534/2584` 是**先解參考再過濾**（host 判定 `dstDpid == 0` 在 `.front()` 之後）
⇒ **一條 `srcIp` 為空的邊，弄壞的是整趟掃描，不只是那一條邊。**

## 3. 根因

不變式的**執行點**與**依賴點**不在同一個子系統，而且執行點的條件比依賴點窄三層：

1. 只擋 `VertexType::SWITCH`——HOST 直接過（⇒ C 組）；
2. 只看**節點**的 `vp.ip`——edge 的 `srcIp`／`dstIp` 是另外兩個 vector，載入端零檢查（⇒ D 組）；
3. `validateStaticTopologyJson` 只在 `dpid == 0` 的分支查位址，`dpid != 0` 的端點從未被檢查。

`TopologyAndFlowMonitor.cpp:655-663` 的註解自己寫著「十處靠這一扇門」
「Rejected here rather than guarding each call site」——**那句話成立的前提，正是這三個缺口不存在。**

## 4. 修法

### 4.1 新增兩支自由函式（`include/utils/Utils.hpp`）

```cpp
inline std::optional<std::string> firstAddressOf(const std::vector<uint32_t>& ips);
inline std::optional<uint32_t>    firstAddressRaw(const std::vector<uint32_t>& ips);
```

語意與 `DeviceConfigurationAndPowerManager::managementIpOf` 一字不差——**空就回 `nullopt`，
不回 `"0.0.0.0"`**（假位址是這個檔已經被燒過兩次的失敗模式）。
`managementIpOf` 本身用不上：它是 DCPM 的 **`protected static`** 成員，
`TopologyAndFlowMonitor` 不是它也不是它的衍生類別，**編不過**。

⚠️ `Utils.hpp` 是共用 header，被 **70 個 TU** include ⇒ 動它＝全樹重編。
本輪兩個 build dir 都是新配置的（原本不存在），**第一次全建本來就要付這個成本，所以這一步實際上是零額外代價**；
之後的閘門只 mutate `.cpp`，都是增量。

### 4.2 三種形狀，不是同一個

| 組 | 形狀 | 理由 |
|---|---|---|
| A、D 的比對點 | `!x.empty() && x.front() == y` | **搜尋時的候選不匹配就是不匹配**。沒有位址的候選「不等於我要找的那個」——這是正確答案，不是降級 |
| B、D 的取值點 | `firstAddressOf(...)`，`nullopt` 跳過該筆 | 「要把位址拿出來用」，拿不到就沒有正確答案可給 |
| C | 兩端任一取不到 ⇒ **跳過該 link 並計數** `links_skipped_no_address` | top-k 是排名，少一條要說出來 |

🔴 **C 組沒有改成報 `"0.0.0.0"` 或空字串**，那會讓 top-k 出現一條看起來合法的鏈路。
🔴 **C 組也沒有「一有問題就整個回空」**，那是過度守衛，會把崩潰修成靜默失去資料。

## 5. 🔴 我在 C 組多改了一行，而它不是加守衛

`getTopKCongestedLinksJson` 原本的迴圈是 `for (i = 0; i < links_to_return; ++i)`，
`links_to_return = min(k, all_links.size())`。**如果在迴圈裡 `continue`，回傳的筆數會少於 k，
即使後面還有排得上的鏈路。** 那等於把「跳過一條壞的」變成「整份榜單短一截」，
是另一種說謊。所以迴圈改成走完 `all_links`、以 `links_array.size() < links_to_return` 收斂，
`rank` 也從 `i + 1` 改為 `links_array.size() + 1`。

**這一行不是守衛，是守衛的副作用的修正**，單獨列出來，不要混進「加了 empty 檢查」那一類。

## 6. 測試

擴充 `tests/test_CpuReportNoIpSwitch.cpp`（**不開新檔**——#85 的 fixture 已有 `ReportProbe`／
`SwitchListingMonitor`／`LogCapture` 三個接縫）。它缺的是**建 HOST 與 edge 的能力**
（#85 只需要 switch），所以新增四支建構器：
`addSwitchVertex`／`addHostVertex`／`addDirectedEdge`／`addBidirectionalLink`。

| 測試 | 守什麼 |
|---|---|
| `AnAddresslessSwitchDoesNotMatchEveryIpLookup` | A 組：無位址的 switch 不會被當成命中，有位址的那台照樣找得到 |
| **`AnAddresslessHostDoesNotEndTheTopKReport`** | 🔴 主測試。回得來、排得出有位址那條、`links_skipped_no_address >= 1`、body 不含 `0.0.0.0` |
| `ALinkWithAddressesOnBothEndsStillRanks` | **過度守衛的對照**：別條 link 有問題，不可以害這條掉出榜單 |
| `AnEdgeWithNoSourceAddressDoesNotBreakTheWholeScan` | D 組：壞的是那條邊，不是整趟掃描 |
| `TheSingleSwitchCpuReportStillMatchesOnTheAddressItHas` | injection 防線：查 `10.0.0.2`、switch 持 `10.0.0.20`，子字串會中、`==` 不可以中 |

## 7. 🔴 看紅（兩段，逐字）

### 7.1 BEFORE——asan build 上，修法**還沒進去**時的逐字輸出

binary：`build-asan/bin/test_routing_strategy`，
sha256 `e28315504eee25496e692a67d19a95e2536ff0d6e41eadb4d0c96322aed164f3`
（**這顆是「Utils.hpp 已加 helper、測試已加、但十六處呼叫點全部未改」的狀態**）。
指令：`ASAN_OPTIONS=detect_leaks=0 build-asan/bin/test_routing_strategy --gtest_filter=NoIpSwitchTest.<T>`，
四支各跑一次（**分開跑**，否則第一支就把 binary 帶走、後面三支不會執行）。
raw：`scratch/overnight-2026-09-05/fix/W2-03-asan-BEFORE.log`。

```
[ RUN      ] NoIpSwitchTest.AnAddresslessHostDoesNotEndTheTopKReport
/usr/include/c++/13/bits/stl_iterator.h:1100:17: runtime error: reference binding to null pointer of type 'struct basic_string'
rc=1

[ RUN      ] NoIpSwitchTest.AnEdgeWithNoSourceAddressDoesNotBreakTheWholeScan
/usr/include/c++/13/bits/stl_iterator.h:1100:17: runtime error: reference binding to null pointer of type 'const unsigned int'
rc=1

[ RUN      ] NoIpSwitchTest.AnAddresslessSwitchDoesNotMatchEveryIpLookup
/usr/include/c++/13/bits/stl_iterator.h:1100:17: runtime error: reference binding to null pointer of type 'const unsigned int'
rc=1

[ RUN      ] NoIpSwitchTest.TheSingleSwitchCpuReportStillMatchesOnTheAddressItHas
/usr/include/c++/13/bits/stl_iterator.h:1100:17: runtime error: reference binding to null pointer of type 'const unsigned int'
rc=1
```

🔴 **注意 C 組那一行的型別是 `struct basic_string`，另外三支是 `const unsigned int`。**
這不是巧合，是**機制不同的直接證據**：C 組 `.front()` 是取在 `ipToString` **vector 多載傳值回來的
`vector<string>` 暫時物件**上（空進空出），另外三支才是取在 `VertexProperties::ip`／
`EdgeProperties::srcIp` 這種 `vector<uint32_t>` 上。工單 §C 的推論在這裡被 sanitizer 逐字證實。

⚠️ **口徑**：這是 🟢 **我親自跑過的**。UBSan 的 `-fno-sanitize-recover=all` 讓它 abort（rc=1）；
`detect_leaks=0` 是我加的（漏記憶體不是這張單的題目，開著會蓋掉訊號）。

### 7.2 AFTER——同一個 build dir，修法進去之後

raw：`scratch/overnight-2026-09-05/fix/W2-06-asan-AFTER.log`。

```
[----------] 14 tests from NoIpSwitchTest (539 ms total)
[==========] 14 tests from 1 test suite ran. (540 ms total)
[  PASSED  ] 14 tests.
rc=0
```

**14/14 綠、sanitizer 一句話都沒有。** 14 支＝#85 原有 9 支＋#88 新增 5 支。

### 7.3 閘門

`tests/shell/mutate_first_address_of.sh`，兩輪。anchor 檢查：

```
mutate_cpu_report_no_ip.sh           ok(12)
mutate_f1_mininet_health_metrics.sh  ok(8)
mutate_first_address_of.sh           ok(10)
3/3 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)
```

（後兩支是**鄰居**：我動了 `DeviceConfigurationAndPowerManager.cpp`，照工單 §衝突要一起驗，
證明我的修法沒有打散它們的 anchor。raw：`W2-07-anchors.log`。）

**最終結果**（raw：`W2-10-gate-rerun.log`）：

```
=== ROUND 1: ordinary build (build) -- mutants that stay defined and lie ===
  ok       baseline green ([  PASSED  ] 14 tests.)
  caught   M4 over-guard-empties-the-whole-topk           (NoIpSwitchTest.ALinkWithAddressesOnBothEndsStillRanks went red)
  caught   M5 substitutes-0.0.0.0-for-a-missing-address   (NoIpSwitchTest.AnAddresslessHostDoesNotEndTheTopKReport went red)
  caught   M6 skips-the-link-without-reporting-it         (NoIpSwitchTest.AnAddresslessHostDoesNotEndTheTopKReport went red)
  caught   M7 identifier-comparison-widened-to-substring  (NoIpSwitchTest.TheSingleSwitchCpuReportStillMatchesOnTheAddressItHas went red)
  ok       C1 helper-inlined-at-the-call-site             (control stayed green, as it must)
  ok       C2 topk-skip-condition-written-the-other-way   (control stayed green, as it must)
  ok       C3 cpu-report-guard-written-with-size          (control stayed green, as it must)

=== ROUND 2: asan build (build-asan) -- the undefined behaviour itself ===
  ok       baseline green ([  PASSED  ] 14 tests.)
  caught   M1 topk-dereferences-empty-address-vector      (sanitizer reported; ...)
             /usr/include/c++/13/bits/stl_iterator.h:1100:17: runtime error: reference binding to null pointer of type 'struct basic_string'
  caught   M2 edge-scan-dereferences-empty-srcip          (sanitizer reported; ...)
             /usr/include/c++/13/bits/stl_iterator.h:1100:17: runtime error: reference binding to null pointer of type 'const unsigned int'
  caught   M3 findSwitchByIp-guard-removed                (sanitizer reported; ...)
             /usr/include/c++/13/bits/stl_iterator.h:1100:17: runtime error: reference binding to null pointer of type 'const unsigned int'

all mutated files restored byte-identical to the working tree they started from.
10 mutations, 0 survived, 0 invalid, 0 rounds skipped
PASS
```

### 7.4 🔴 第一次跑不是 PASS，而那兩個問題是閘門自己抓出來的

**不要把上面那張 PASS 讀成「一次就過」。** 第一次跑（`W2-08-gate.log`，16:24–16:41）
是 `10 mutations, 1 survived, 1 invalid` ⇒ `FAIL`。兩個問題都在**閘門自己**，不在修法：

- **M5 SURVIVED**：那個變異**碰不到自己要證的缺陷**。它只換掉兩行 `ip_str` 指派，
  卻把上面的 `if (!ip1Opt || !ip2Opt) { ++skipped; continue; }` 留著 ⇒ `"0.0.0.0"` 那條分支
  **永遠走不到**，變異其實是行為等價的。`cmp` 的 no-op 檢查抓不到它，因為**檔案真的變了、
  只有程式沒變**。修法：anchor 連 skip 區塊一起吃掉。
  🔴 **一個到不了自己缺陷的變異，對測試什麼都沒證明**——SURVIVED 是正確的保守判定。
- **M7 INVALID**（`anchor matches 2 times`）：我傳了**兩行**的 anchor 卻沒給第六個參數（uniq 行）。
  `assert_unique` 用 `grep -c -F`，那是**逐行**的：兩行＝兩個 pattern，各中一次 ⇒ 報 2。
  而 `check_gate_anchors.py` 對同一支閘門說 `ok(10)`，因為它用 `str.count()` 掃整個檔案，
  那個兩行 anchor 在檔案裡確實只出現一次。
  🔴 **兩個工具各自都對，但問的是不同的問題，而閘門那個比較嚴。**
  ⇒ **`check_gate_anchors.py` 回 `ok` 不代表閘門跑得動。** 這一條建議寫進閘門慣例。

修法在 `e1bf73ba`，兩條理由都寫進閘門檔頭。

### 7.5 全套回歸（§5 那個迴圈改動的對帳）

`getTopKCongestedLinksJson` 有既有消費者測試
（`tests/test_AdminDisableConsumers.cpp:710` `TopKCongestedLinksOmitsLinkWhenOneDirectionAdminDisabled`，
用 `getTopKCongestedLinksJson(100000)`），而我改了它的迴圈邊界，所以**必須**跑全套而不是只跑 `NoIpSwitchTest`。
raw：`W2-09-fullsuite.log`。

```
[==========] 1074 tests from 134 test suites ran. (8894 ms total)
[  PASSED  ] 1074 tests.
FULL_SUITE_RC=0
```

兩件事讓它不受影響：`k = 100000` 時 `links_to_return` 仍是 `all_links.size()`，沒有 link 被跳過時
新舊迴圈**逐筆等價**；而那支測試用的 `findLinkArray` 只挑 array 欄位，
新增的整數欄 `links_skipped_no_address` 它會略過。

## 8. 可達性口徑（🔴 與 #85 不同，分兩級）

| 組 | 口徑 | 依據 |
|---|---|---|
| A（2 處）、B（3 處） | **缺陷成立、產線走不到** | 照 #85 §3：載入端 `:664` 自 `2da6954f` 起拒絕空 ip 的 SWITCH，`updateSwitches` 不造節點。仍然修，理由照 #85 §4 |
| **C（HOST）** | 🔴 **產線走得到** | 門只擋 SWITCH；`getTopKCongestedLinksJson` 對 `boost::edges` 零 `vertexType` 過濾 |
| **D（十處 edge）** | 🔴 **產線走得到** | 載入端對 edge 的 `srcIp`／`dstIp` 零檢查 |

⚠️ C／D 的「走得到」是 🔵 **讀碼推的**——我**沒有**做出那樣一份拓樸檔跑進 live kernel。
**不要寫成「已在 live 觀測到」。** 反向的證據我也記在這裡：
`validateStaticTopologyJson:215-233` 對 `dpid == 0` 的 edge 端點會要求「這個位址要有節點持有」，
所以**一份「host 空 ip ＋ 該 host 以位址被 edge 指名」的檔案會在載入時被拒**。
⇒ C 組的可達性取決於**還有沒有別的路徑造出空 ip 的 HOST**（`dpid != 0` 的端點完全沒被檢查是其中一條）。
**這一格我沒有跑出結論，列為給 Adam 的第 1 題（§10）。**

## 9. 🔴 沒修的同型——工單漏掉七處，其中五處是 HOST

工單說十六處。我用 grep 盤點**全部** `.front()` 與 `[0]` 對 ip 向量的存取，
對帳結果：**工單的十六處全部成立**（座標修正見 §2.1），但**另有七處無守衛的同型缺陷不在工單裡**。

| 檔案:行 | 運算式 | 頂點型別 | 可達性同級於 |
|---|---|---|---|
| `IntentTranslator.cpp:212` | `ipToString(vertex.ip[0])` | SWITCH | A／B（走不到） |
| `IntentTranslator.cpp:657` | `ipToString(vprop.ip[0])` | SWITCH | A／B（走不到） |
| **`IntentTranslator.cpp:665`** | `ipToString(vprop.ip[0])` | **HOST** | **C（走得到）** |
| **`IntentTranslator.cpp:702`** | `ipToString(vprop.ip[0])` | **HOST** | **C（走得到）** |
| **`LLMAgent.cpp:243`** | `ipToString(vprop.ip[0])` | **HOST** | **C（走得到）** |
| **`FlowLinkUsageCollector.cpp:2986`** | `graph[*srcHostOpt].ip[0]` | **HOST** | **C（走得到）** |
| **`FlowLinkUsageCollector.cpp:2987`** | `graph[*dstHostOpt].ip[0]` | **HOST** | **C（走得到）** |

🔴 **`operator[]` 與 `front()` 的 UB 完全相同**，`[0]` 只是換了個寫法，工單的 grep 口徑漏掉了它。
⇒ **無守衛的 ip 解參考實際是 23 處，不是 16 處；產線走得到的那一級從 1 組變成 6 處。**

> 🔴 **2026-09-07 更正（W18 加註，原文保留）：這裡的「23 處」仍然少算一處，正確是 24。**
> 第八處是 `TopologyAndFlowMonitor.cpp:1729`（`updateHosts` 裡的
> `findEdgeBySrcAndDstIp((*m_graph)[*vertexOpt2].ip[0], ip)`，SWITCH 級）——
> 它在**本單自己的 base `f0687b34`** 就已經存在（當時 `:1634`），而且就在本單大改的那個檔案裡；
> 上表的 grep 口徑（`.ip[0]` 前面接 `vertex`／`vprop`／`graph[...]`）沒有涵蓋
> `(*m_graph)[*vertexOpt2].ip[0]` 這種寫法。
> W14 的重掃找到它、依工單只列不修；**W18（分支 `fix/w18-eighth-index-zero`）已修並附閘門**，
> 見 `doc/audit/2026-09-07_fix-attachment-switch-index-zero/`。24 處到齊之後，
> `src/`／`include/` 底下沒有無守衛的 ip 首元素解參考。
> ⇒ **這個教訓比數字本身重要：盤點的口徑是 grep 的 pattern，而 pattern 漏掉的東西不會出現在
> 「我盤點過了」這句話裡。** 同一份 grep 連續兩張單都漏掉同一行。

**這七處我沒有修**，理由：它們在三個不同的子系統（intent translator、LLM agent、flow collector），
各自需要自己的 fixture 與必死測試，而**沒看過紅就不算修完**——
在沒有閘門覆蓋的情況下順手加守衛，會讓「已修」這句話涵蓋到沒有證據的部分，
正是 `02-recurring-mistakes` 記的「揭露≠下修」的反面。**建議另開一張單**（§10 第 2 題）。

以下**已複驗為有守衛、不是缺陷**，列出來是為了讓下一個人不用重查：
`TopologyAndFlowMonitor.cpp:224`（`addresses.empty()` 早退）、`:748`／`:762`（`!ep.srcIp.empty()` 分支）、
`:3673`（`props.ip.empty()` continue）、`DeviceConfigurationAndPowerManager.cpp:1230`（`managementIpOf` 本體）、
`:2272`（`vp.ip.empty()` continue）、`HttpSession.cpp:588`（`!e.dstIp.empty()`）、
`IntentTranslator.cpp:738`（`hostProp.ip.empty()` 早退）、`FlowLinkUsageCollector.cpp:2713`（`path.empty()`，且不是 ip 向量）。

## 10. 給 Adam 的三格

1. **C 組的可達性要不要實測？** §8 記了一條反向證據（載入端對 `dpid == 0` 的 edge 端點會做位址交叉檢查），
   我沒跑出「到底做不做得出一份載得進去、且含空 ip HOST 的拓樸檔」。
   要的話我下一輪做一份檔案跑 `loadStaticTopologyFromFile` 驗，**這會把 C 組從 🔵 升成 🟢 或降成「走不到」。**
2. **§9 那七處（五處 HOST）要不要今晚一起修？** 需要三個子系統各自的 fixture 與閘門，估 2–3 h。
3. **`links_skipped_no_address` 是新的回應欄位**，API 文件 §top-k 那節要不要同步補一句？我沒有動 API 文件。
