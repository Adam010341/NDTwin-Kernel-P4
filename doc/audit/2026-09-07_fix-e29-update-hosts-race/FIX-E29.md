# FIX-E29 — `updateHosts` 讀圖沒有持鎖：先要證據，然後才修

[Co-developed with claude code -- Adam]

裁決正本：`scratch/overnight-2026-09-05/DECISIONS.md` grill §4E 第七輪 **E-29「開單，但先要獨立的
race 證據」**。來歷：`fix/R2-W18-SUMMARY.md` §7 第 2 題。
分支 `fix/e29-update-hosts-race-evidence`，base＝trunk `1a284f75`。
逐字 log：`scratch/overnight-2026-09-05/fix/r3-e29-logs/`（檔名對照見 §4.6）。

---

## 1. 缺陷本體

`src/ndt_core/collection/TopologyAndFlowMonitor.cpp`，`updateHosts` 的「附著交換機」分支，
base `1a284f75` 的第 **1726–1729** 行：

```cpp
auto vertexOpt2 = findSwitchByDpid(*attachDpidOpt);   // 進去拿 shared_lock，回傳前就放掉
if (vertexOpt2.has_value())
{
    auto edgeRevOpt = findEdgeBySrcAndDstIp((*m_graph)[*vertexOpt2].ip[0], ip);
    //                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 一把鎖都沒有
```

`findSwitchByDpid`（同檔 2340–2352）在 `return` 之前就把 `shared_lock` 放掉了，所以它交出來的
descriptor 是在**所有鎖之外**被解參考的。`updateHosts` 其他每一個碰圖的地方都在鎖裡
（1597、1679、1732 三個 `unique_lock`），只有這一行不是——**這是全函式唯一的無鎖圖存取**。

不能直接把鎖罩到 `findEdgeBySrcAndDstIp` 外面：那支自己會再拿一次 `shared_lock`
（同檔 2930），而 `m_graphMutex` 是普通的 `std::shared_mutex`、不可重入；同一條執行緒第二次
`shared_lock` 在有 writer 排隊時就死鎖——`parseStaticTopologyFile` 自己的寫鎖旁邊記著同一個坑
（同檔 676–688，那也正是那把寫鎖曾經被註解掉的原因）。

---

## 2. 階段一：證據（跑過）

### 2.1 儀器

新檔 `tests/test_UpdateHostsRace.cpp`，四個案例，**各自獨立跑一個行程**（一個判決不能污染另一個）。
TSAN 建置目錄 `build-tsan`，只建這一支目標。

| 案例 | 讀者 | 寫者 | 這個案例能說什麼 |
|---|---|---|---|
| 1 `LiveShape_UpdateHostsAgainstRealReaders` | `getGraph` / `getStaticTopologyJson` / `findEdgeByHostIp` / `findSwitchByIp` / `findVertexByMac` / `getAllPathsBetweenTwoHosts` / `getTopKCongestedLinksJson` | **`updateHosts` 自己**（無合成寫者） | **今天會不會真的撞** |
| 2 `ProbeWriter_UpdateHostsUnlockedReadOfSwitchIp` | `updateHosts`（原封不動的產品碼） | 探針：持**寫鎖**改 s1 的 `ip[0]` | 缺陷的**形狀**：這個讀是無同步的 |
| 3 `Control_LockedReaderOfTheSameBytes` | `findSwitchByIp`（產品碼，`shared_lock` 讀**同一段 bytes**） | 同一個探針 | ⭐ **鑑別力**：只有鎖不同 |
| 4 `Control_UpdateSwitchesAgainstTheSameWriter` | `updateSwitches`（單子點名的「已知有鎖」路徑） | 同一個探針 | 單子要求的對照 |

拓撲 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`（14 vertex／40 edge，s1=dpid 1
=192.168.123.11，h2=mac 2=10.0.0.2）。餵進去的 hosts 回覆：

```json
[{"mac": "00:00:00:00:00:02", "ipv4": ["10.0.0.2"], "port": {"dpid": "1"}}]
```

探針寫者（`probeWriteSwitchIp`）在**持寫鎖**的區塊裡把 s1 的 `ip[0]` 先寫成 s2 的位址、再寫回
s1 自己的，**放鎖前就還原**。所以：任何守規矩（持鎖）的讀者，**永遠不可能**看到
`s1.ip[0] == 192.168.123.12`。

### 2.2 兩個互相獨立的讀數

1. **ThreadSanitizer**：兩邊 stack。**這一個是判決**（exit code 66）。
2. **不需要 sanitizer 的不變量**（比較不靈敏，見 §4.2）：讀到正確值（192.168.123.11）時
   `findEdgeBySrcAndDstIp(192.168.123.11, 10.0.0.2)` 找不到邊 ⇒ 什麼都不寫；讀到探針值
   （192.168.123.12）時**找得到** s2 → h2 那條邊 ⇒ 把它標成 up。
   **那條邊被抬起來＝無鎖讀看到了一個守規矩的讀者看不到的值。**
   案例 2 開頭有單執行緒的陰性對照：同一份回覆、沒有任何併發，先斷言那條邊仍然是 down
   （否則這個偵測器分不出 race 與「這份回覆本來就會抬它」）。

### 2.3 結果——**(a)，但寫者是探針**

| 案例 | 迭代（每讀者執行緒 × 執行緒數） | 耗時 | TSAN | gtest | exit | log |
|---|---|---|---|---|---|---|
| 2 探針 vs `updateHosts` | 4 000 × 4 | 2 416 ms | **1 筆 data race** | **FAILED** | **66** | `10-case2-probe-updatehosts.log` |
| 3 探針 vs `findSwitchByIp`（對照） | 4 000 × 4 | 34 ms | 乾淨 | OK | 0 | `11-…` |
| 3 對照（拉長） | 400 000 × 4 | 1 591 ms | 乾淨 | OK | 0 | `11b-…` |
| 3 對照（再拉長，**耗時已超過案例 2**） | 1 200 000 × 4 | 3 463 ms | 乾淨 | OK | 0 | `11c-…` |
| 4 探針 vs `updateSwitches`（對照） | 4 000 × 4 | 2 018 ms | 乾淨 | OK | 0 | `12-…` |
| 1 live shape（無探針） | 4 000 × 4 | 5 019 ms | 乾淨 | OK | 0 | `13-…` |
| 1 live shape（拉長） | 20 000 × 6 | 27 700 ms | 乾淨 | OK | 0 | `13b-…` |

binary sha256 `e71ed9ca7fde09e6…`（七次全部同一顆）。

### 2.4 TSAN 報告逐字（案例 2，`10-case2-probe-updatehosts.log`，兩邊 stack）

⚠️ 這是**第一次**觀測，跑的是**未修法的產品碼**（`TopologyAndFlowMonitor.cpp:1729`）。
引用裡 `test_UpdateHostsRace.cpp` 的行號是那一刻的檔案；測試檔頭之後補了兩段說明，
行號位移了。**與最終 commit 對得上的同型報告在 §4.2。**

```
WARNING: ThreadSanitizer: data race (pid=1769685)
  Write of size 4 at 0x7204000007f0 by thread T1 (mutexes: write M0):
    #0 probeWriteSwitchIp .../tests/test_UpdateHostsRace.cpp:273
    #1 operator() .../tests/test_UpdateHostsRace.cpp:431
    #2 __invoke_impl<void, ...UpdateHostsUnlockedReadOfSwitchIp_Test::TestBody()::<lambda()> > /usr/include/c++/13/bits/invoke.h:61
    #3 __invoke<...> /usr/include/c++/13/bits/invoke.h:96
    #4 _M_invoke<0> /usr/include/c++/13/bits/std_thread.h:292
    #5 operator() /usr/include/c++/13/bits/std_thread.h:299
    #6 _M_run /usr/include/c++/13/bits/std_thread.h:244
    #7 <null> <null> (libstdc++.so.6+0xecdb3)

  Previous read of size 4 at 0x7204000007f0 by thread T3:
    #0 TopologyAndFlowMonitor::updateHosts(std::__cxx11::basic_string<...> const&) .../src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1729
    #1 operator() .../tests/test_UpdateHostsRace.cpp:439
    #2 __invoke_impl<void, ...> /usr/include/c++/13/bits/invoke.h:61
    #3 __invoke<...> /usr/include/c++/13/bits/invoke.h:96
    #4 _M_invoke<0> /usr/include/c++/13/bits/std_thread.h:292
    #5 operator() /usr/include/c++/13/bits/std_thread.h:299
    #6 _M_run /usr/include/c++/13/bits/std_thread.h:244
    #7 <null> <null> (libstdc++.so.6+0xecdb3)

  Location is heap block of size 4 at 0x7204000007f0 allocated by main thread:
    #0 operator new(unsigned long)
    ...
    #6 VertexProperties::VertexProperties(VertexProperties const&) .../include/common_types/GraphTypes.hpp:273
    ...
    #10 TopologyAndFlowMonitor::parseStaticTopologyFile(...) .../TopologyAndFlowMonitor.cpp:775
    #11 TopologyAndFlowMonitor::loadStaticTopologyFromFile(...) .../TopologyAndFlowMonitor.cpp:617

  Mutex M0 (0x7214000002e0) created at:
    #0 pthread_rwlock_rdlock
    ...
    #5 TopologyAndFlowMonitor::parseStaticTopologyFile(...) .../TopologyAndFlowMonitor.cpp:642
...
SUMMARY: ThreadSanitizer: data race .../tests/test_UpdateHostsRace.cpp:273 in probeWriteSwitchIp
```

讀那份報告的三件事：

* 寫者那一行 TSAN 自己註明 **`(mutexes: write M0)`**；讀者那一行**沒有任何 mutex 註記**。
  不對稱是 TSAN 講的，不是我講的。
* 讀者 stack frame #0 就是 **`TopologyAndFlowMonitor.cpp:1729`**——產品碼，不是測試碼。
* `Location is heap block …` 指回 `parseStaticTopologyFile:775` 的 `add_vertex`：出事的那 4 個
  byte 就是拓撲檔載進來的 `VertexProperties::ip[0]`。

同一份 log 裡的不變量讀數（逐字）：

```
.../tests/test_UpdateHostsRace.cpp:456: Failure
Value of: fix.edgeIsUp(*detector)
  Actual: true
Expected: false
updateHosts marked the s2 -> h2 edge up. Reaching that edge requires reading 192.168.123.12 out of
s1's address slot, and 192.168.123.12 is only ever in that slot while the write lock is held. The
unlocked read at the findEdgeBySrcAndDstIp call in updateHosts observed a value no lock-respecting
reader could see.
[  FAILED  ] UpdateHostsRaceTest.ProbeWriter_UpdateHostsUnlockedReadOfSwitchIp (2416 ms)
ThreadSanitizer: reported 1 warnings
```

⇒ 它不只是「理論上的 race」：`updateHosts` **真的去改了一條它無權碰的邊**。

### 2.5 儀器有沒有鑑別力（controls decide what you learn）

* **對照 3 是關鍵的那個**：同一個寫者、**同一段 bytes**、同樣的執行緒數，唯一換掉的是讀者持不持鎖
  （`findSwitchByIp` 在 `shared_lock` 裡讀 `vprop.ip.front()`，同檔 3560–3566）。乾淨。
  而且拉到 480 萬次讀（3 463 ms，**比報紅的案例 2 跑得還久**）仍然乾淨。
  ⇒ 案例 2 報紅與案例 3 不報，差別只有鎖。
* **函式內部還有一個更緊的對照**：`updateHosts` 自己在 1653 行呼叫 `findSwitchByIp(ip)`，那支會
  在 `shared_lock` 裡把**每一顆**交換機的 `ip.front()` 讀一遍——也就是同一次呼叫裡，同一段 bytes
  被**持鎖讀了一次、無鎖讀了一次**。TSAN 只報了無鎖那一次。
* 對照 4（單子點名的 `updateSwitches`）也乾淨；但它比對照 3 弱：`updateSwitches` 讀的是
  `.dpid`／`.vertexType`，跟探針寫的 bytes 不重疊，**光靠 byte-disjoint 就能解釋它乾淨**。
  它在這裡是因為單子要求，不是因為它自己有鑑別力。

### 2.6 「今天會不會真的撞」——不會，而且我查得出為什麼

案例 1（live shape）**乾淨**，20 000 × 6 迭代、27.7 s 也乾淨。這與靜態盤點一致：

```
$ grep -rn "\.ip\s*=\|\.ip\[" --include=*.cpp --include=*.hpp src/ include/ \
    | grep -v "smartPlugIp\|srcIp\|dstIp\|agentIp"          # 修法之後跑的，所以是修法後的行號
src/ndt_core/intent_translator/LLMAgent.cpp:243              utils::ipToString(vprop.ip[0])   讀，在 getGraph() 深拷貝上
src/ndt_core/intent_translator/IntentTranslator.cpp:212      utils::ipToString(vertex.ip[0])  讀，同上
src/ndt_core/intent_translator/IntentTranslator.cpp:657/665/702/738                           讀，同上
src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:2268  vp.ip = ...        寫，但 vp 是區域變數（fetchSmartPlugInfoFromFile），沒進圖
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:707       vp.ip = ...          🔴 圖裡 ip 的唯一寫者
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1762      attachIp = (*m_graph)[*vertexOpt2].ip[0]   ← 本案的讀（已在鎖裡）
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3837      utils::ipToString(props.ip[0])   讀，在 shared_lock 裡
include/common_types/GraphTypes.hpp:483   from_json(json, VertexProperties&) 裡的 v.ip = ...
        → 這支 from_json **沒有活著的呼叫者**：唯一提到它的是載入器裡註解掉的
          `// VertexProperties vp = nodeJson.get<VertexProperties>();`（同檔 702）。
```

全樹只有 `parseStaticTopologyFile:707` 會寫圖裡的 `VertexProperties::ip`，它**整段載入都持著寫鎖**
（同檔 690），而且第二次呼叫會被自己的守衛擋掉（同檔 640–652，`num_vertices > 0` 就 return）。
`boost::add_vertex`／`add_edge` 也只出現在那一段（775、875）。所以今天沒有第二個寫者，
`updateHosts` 那個無鎖讀**目前撞不到東西**。

**這一條要講清楚，不能含混：本單的證據證明的是「那個讀是無同步的」，不是「今天會出事」。**
探針寫者是產品碼沒有的東西。這是「形狀是真的、liveness 是潛伏的」。

**那為什麼還是修？** 三個理由，都寫在這裡讓 Adam 好推翻：

1. 這是**規則的例外**，不是安全的設計。`TopologyAndFlowMonitor` 對每一個查找都備了 `NoLock`
   雙胞胎，就是為了讓「碰圖一定在鎖裡」成為可檢查的規則；1729 是全類唯一破例的地方，
   而破例的代價是**下一個寫者出現的那天才會被發現**。
2. 下一個寫者是有路線圖的：`parseStaticTopologyFile` 自己的註解寫著
   「Reconciling properly would be the better answer」——真正的拓撲 reload 一旦落地，
   寫者就存在了；而 vertex 存的是 `boost::vecS`，`add_vertex` 會搬動整個 vertex 陣列，
   到時候這一行不只是 race，是 use-after-free。
3. 修法是一個 uint32 的複製，成本＝每一個帶 attachment dpid 的 hosts entry 多一次
   **無競爭的 shared_lock**；沒有行為改變（同一個值），推翻成本＝revert 一顆小 commit。

---

## 3. 階段二：修法（跑過）

`src/ndt_core/collection/TopologyAndFlowMonitor.cpp`，`updateHosts`：

```cpp
uint32_t attachIp = 0;
{
    std::shared_lock lock(*m_graphMutex);
    attachIp = (*m_graph)[*vertexOpt2].ip[0];
}
auto edgeRevOpt = findEdgeBySrcAndDstIp(attachIp, ip);
```

**把值抄出臨界區**，而且那個 scope 在呼叫 `findEdgeBySrcAndDstIp` 之前就結束。三件事逼出這個形狀
（碼裡的註解寫了同樣三點）：

1. 鎖不能罩過 `findEdgeBySrcAndDstIp`——它自己會再拿 `shared_lock`，非重入，有 writer 排隊就死鎖。
2. 出去的必須是**值**不是 reference。`const auto& ips = …` 再在區塊外讀，是同一個缺陷換個寫法；
   而且 vertex 存的是 `boost::vecS`，指進去的 reference 連 `add_vertex` 都撐不過。
3. 讀的是一個 `uint32_t`、用 shared lock：併發的 poll 與讀者照樣同時進行。

**這一顆沒有處理**「`ip` 是空陣列時 `ip[0]` 是 UB」——那是 W18／FINDINGS #88 的事（見 §6）。

---

## 4. 閘門：紅→綠→紅→綠（全部跑過）

### 4.1 綠（修法之上）

binary sha256 `9d32e1834a5e6f0d…`（`20-` … `24-` 五次）。

| 案例 | 迭代 | 耗時 | TSAN | gtest | exit | log |
|---|---|---|---|---|---|---|
| 2 探針 vs `updateHosts` | 4 000 × 4 | 2 282 ms | 乾淨 | OK | 0 | `20-green-case2-after-fix.log` |
| 2 同上，**10 倍迭代** | 40 000 × 4 | 22 364 ms | 乾淨 | OK | 0 | `21-…-40k.log` |
| 1 live shape | 4 000 × 4 | 5 006 ms | 乾淨 | OK | 0 | `22-…` |
| 3 對照 | 400 000 × 4 | 1 203 ms | 乾淨 | OK | 0 | `23-…` |
| 4 對照 | 4 000 × 4 | 1 946 ms | 乾淨 | OK | 0 | `24-…` |

不只 TSAN 轉綠：案例 2 的不變量斷言也轉綠——s2 → h2 那條邊再也沒有被抬起來過。

### 4.2 變異（把鎖拿掉，其他不動）⇒ 紅

⚠️ **這一組是拿最終要 commit 的檔案重跑的**（`32-`／`33-`／`34-`）。§2.4 與 §4.1 的行號是更早那幾次
跑當下的檔案——測試檔頭後來補了「修法已落地」與「兩個讀數靈敏度不同」的說明，行號因此位移。
**與 commit 內容對得上的是這一節。**

變異體只把那五行換成一行，別的一個字都沒改：

```cpp
// MUTANT (R3-E29 mutation gate): the shared_lock removed, nothing else.
uint32_t attachIp = (*m_graph)[*vertexOpt2].ip[0];
```

binary sha256 `553dc15b783af587…`，4 000 × 4，2 480 ms。**逐字：**

```
WARNING: ThreadSanitizer: data race (pid=1776032)
  Write of size 4 at 0x7204000007f0 by thread T1 (mutexes: write M0):
    #0 probeWriteSwitchIp .../tests/test_UpdateHostsRace.cpp:289
    #1 operator() .../tests/test_UpdateHostsRace.cpp:447
    ...
  Previous read of size 4 at 0x7204000007f0 by thread T2:
    #0 TopologyAndFlowMonitor::updateHosts(std::__cxx11::basic_string<...> const&) .../src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1760
    #1 operator() .../tests/test_UpdateHostsRace.cpp:455
    ...
  Location is heap block of size 4 at 0x7204000007f0 allocated by main thread:
    ...
    #10 TopologyAndFlowMonitor::parseStaticTopologyFile(...) .../TopologyAndFlowMonitor.cpp:775
    #11 TopologyAndFlowMonitor::loadStaticTopologyFromFile(...) .../TopologyAndFlowMonitor.cpp:617
SUMMARY: ThreadSanitizer: data race .../tests/test_UpdateHostsRace.cpp:289 in probeWriteSwitchIp
ThreadSanitizer: reported 1 warnings
EXIT=66
```

`1760` 就是變異體那一行（修法的註解讓行號從 base 的 1729 移下來）。
**閘門接在這一行上，不是接在別處。** log：`33-final-mutant-lock-removed.log`。

🔴 **這一次 gtest 印的是 `[  OK  ]`，只有 exit code 是 66。** 兩個讀數的靈敏度不一樣：
TSAN 只要兩次存取沒有先後關係就報，不變量斷言則還要求那次無鎖讀**真的**讀到探針值、而且解析到
s2 → h2 那條邊。三次對無鎖碼的跑裡，**兩次**（`10-`、`30-`）兩個讀數都紅，**一次**（`33-`）
只有 TSAN 紅。⇒ **這支測試的判決是 exit code，不是 gtest 那一行**；測試檔頭寫了同一句話，
免得後面的人看到 `[  OK  ]` 就以為碼是對的。

### 4.3 還原後再綠

把檔案從備份複製回來、重建、重跑：exit 0、0 筆報告、2 292 ms
（`34-final-green-after-restore.log`）。還原後的 binary sha256 是 `f6ec38bc2e1add1e…`，
**與同一輪修法版（`32-final-green-case2.log`）逐 byte 相同**——證明還原是精確的，不是「看起來像」。
（更早那一輪的還原也一樣：`31-` 與 `20-`…`24-` 都是 `9d32e1834a5e6f0d…`。）

### 4.4 沒有 shell 閘門，理由

`tests/shell/mutate_*.sh` 那一族是給普通 build 的秒級閘門；這一支要 TSAN 建置、要幾秒到幾十秒的
多執行緒跑、而且四個案例要分行程。單子把「拿掉鎖 ⇒ TSAN 紅」本身指定為 mutation gate，
所以本單的閘門是 §4.2 這次手跑，逐字留在上面與 `30-…` log 裡。復現指令寫在測試檔頭。

### 4.5 工具鏈（`00-toolchain.log`）

* `g++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`（**建置與 TSAN 用的就是它**）
* `libtsan2:amd64 14.2.0-4ubuntu2~24.04.1`（ThreadSanitizer runtime）
* `clang 18.1.3`（**只執行了 `--version`，沒有拿來建置任何東西**）
* `cmake 3.28.3`、`ninja 1.11.1`、`Linux 7.0.0-30-generic`（Ubuntu 24.04）

🔴 **TSAN 二進位一定要 `setarch $(uname -m) -R` 跑**（關掉 ASLR）。直接跑會在 `main()` 之前就死：

```
FATAL: ThreadSanitizer: unexpected memory mapping 0x797552a72000-0x797552f00000
```

**這條不是我發現的，repo 早就記著了**——`tools/test_workflow/local_ci.sh:72-75` 的 `job_tsan`
把它寫死在指令裡，`doc/2026-08-17_testing-manual.md:725` 也列在「環境陷阱」。
我第一次跑就踩到，是因為我沒有走 `local_ci.sh` 而是直接跑二進位。核心的 `vm.mmap_rnd_bits`
與 TSAN 固定的 shadow 佈局衝突；正規解 `sysctl vm.mmap_rnd_bits=28` 要 root，`setarch -R` 不用。
測試檔頭與 `scratch/…/fix/r3-e29-logs/*.log` 的表頭都複述了這一行，
**所以這裡不需要新的手冊條目或新的記憶。**

### 4.6 log 對照

| 檔 | 內容 |
|---|---|
| `00-toolchain.log` | 編譯器／sanitizer runtime 版本 |
| `01-configure-tsan.log` | `cmake -S . -B build-tsan … -DSANITIZER=tsan`（guarded，exit 0） |
| `02-build-tsan.log` | 四次 guarded TSAN 建置（初建／改常數／上修法／變異／還原） |
| `10-` … `13b-` | 階段一七次跑（未修法的碼） |
| `20-` … `24-` | 階段二五次跑（修法之上） |
| `30-mutant-lock-removed.log` | 變異＝紅（第一輪） |
| `31-green-again-after-restore.log` | 還原＝綠（第一輪） |
| `32-` / `33-` / `34-` | **最終那一輪**：綠 → 變異紅 → 還原綠，跑的是要 commit 的檔案 |
| `40-ordinary-build-and-ctest.log` | 一般 build ＋ ctest |

---

## 5. 這支測試進不進 ctest：**不進**（單子的預設，本單維持）

`tests/CMakeLists.txt` 加了獨立目標 `test_update_hosts_race`，**沒有** `gtest_discover_tests`：

* 案例 2 在**設計上就是要讓 TSAN 報紅**（它是缺陷的示範）；在修法之上它是綠的，但它的價值只有在
  sanitizer 下才存在，普通 build 跑它只是一個壓力迴圈。
* 四個案例必須分行程跑，`ctest` 的預設不是這樣。
* 一次完整跑要幾十秒到幾分鐘。

但它**進 ALL**（一般 build 會編它），所以不會爛掉沒人發現。獨立目標還有一個實際理由：
只連 Collection／EventSystem／Utils，TSAN 建置就不必編 `HttpSession.cpp` 與 `LLMAgent.cpp`
（那兩個檔**未加 sanitizer** 就各吃 1.6 GB）。

---

## 6. 與 W18 的衝突：**同一行，兩個修法**（必讀）

`fix/w18-eighth-index-zero`（`8a3746e3`）改的就是這一行，處理的是**另一個**缺陷
（FINDINGS #88：`ip` 空陣列時 `ip[0]` 是 UB）。它的版本仍然是**無鎖讀**：

```cpp
const auto attachIpOpt = utils::firstAddressRaw((*m_graph)[*vertexOpt2].ip);   // ← 還是沒有鎖
if (!attachIpOpt.has_value()) { SPDLOG_LOGGER_WARN(...); continue; }
auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);
```

⇒ **兩顆會衝突，而且兩顆都要留。** 合併後應該長這樣（`utils::firstAddressRaw` 在 base
`1a284f75` 就有，`include/utils/Utils.hpp:153`）：

```cpp
std::optional<uint32_t> attachIpOpt;
{
    std::shared_lock lock(*m_graphMutex);
    attachIpOpt = utils::firstAddressRaw((*m_graph)[*vertexOpt2].ip);
}
if (!attachIpOpt.has_value())
{
    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "host {} attaches to switch dpid {}, which carries no IP address in this "
                       "topology; the reverse edge is keyed by that address, so it cannot be "
                       "looked up and is left as it was",
                       macStr,
                       *attachDpidOpt);
    continue;
}
auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);
```

（W18 的 WARN ＋ `continue` 原封不動，只是把讀搬進 `shared_lock` 的 scope 裡；`continue` 放在
scope 外面，所以不會帶著鎖跳走。）本單**故意沒有**先把 W18 的守衛抄過來：那會讓「誰修了
FINDINGS #88」變得說不清楚。

其他無衝突：本單只碰 `updateHosts` 一個 hunk、`tests/CMakeLists.txt` 的檔尾、一支新測試檔。

---

## 7. 沒做的

* **沒有**把 `updateHosts` 其他地方的 TOCTOU 收掉。`findVertexByMac` → 放鎖 → 再拿
  `unique_lock` 這種「查完再鎖」的間隙還在（1594–1600、1671–1679）：那不是 data race
  （每一次存取都在鎖裡），是**原子性**問題，另一個題目、另一種證據。
* **沒有**碰 `m_switchIpsOfferedAsHosts`（1655 行的無鎖 `std::set::insert`）。今天只有 poll
  執行緒會呼叫 `updateHosts`，所以它是單寫者；但那是一個**沒有被任何東西保證**的前提。記在這裡。
* **沒有**在 live shape 案例裡跑 HTTP 層（`HttpSession::handleGetGraphData` 等）。理由是連
  `NdtCore_HttpLib` 會讓 TSAN 建置多編 `HttpSession.cpp`／`LLMAgent.cpp`；而那些 handler 都是
  從 `getGraph()`（`shared_lock` 下的深拷貝，同檔 3079）出發的，形狀已經被案例 1 涵蓋。
  **這是推理，不是實測**——寫在這裡當作案例 1 的覆蓋界線。
