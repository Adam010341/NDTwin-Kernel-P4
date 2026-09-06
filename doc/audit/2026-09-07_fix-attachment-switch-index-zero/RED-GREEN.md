# FINDINGS #88 / W18：紅 → 綠與變異閘門的逐字輸出

[Co-developed with claude code -- Adam]

本檔只放**跑出來的東西**，不放推導；推導在同目錄的 `FIX-ATTACHMENT-SWITCH-INDEX-ZERO.md`。
全部在 `fix/w18-eighth-index-zero`（base＝`fix/w14-index-zero-guards`@`e62c8d6f`）之上、
worktree `scratch/overnight-2026-09-05/wt-w2`、`build/` 為 Debug＋Ninja、
每一次建置都走 `tools/build_guard/guarded_build.sh`（`LOCK_WAIT=10800`）。

**「跑過」與「讀過未執行」分開**：本檔每一段都是**跑過**的，raw 檔名逐段點名，都在 `raw/` 底下
（`.gitignore:84` 是 `doc/audit/**/raw*/*`，所以 raw 不進版控，跟兩個姊妹目錄一樣）。

---

## 1. RED：把 subscript 放回去（手動重現閘門的 M1，取 gtest 逐字）

閘門本身只印它自己的裁決行（`caught … went red`），那是**對紅的宣稱**，不是紅本身。
所以另外手動把 M1 放回去跑一次。還原用 `cp` 快照，**不是 `git checkout --`**（共用 worktree）。

raw：`raw/W18-06-red-verbatim.log`（04:22:53–04:49:29）。建置 `guarded_build: exit 0`（3/3）。

### 1.1 RUN A — 只跑 death test：**被關住、有名字的紅**

```text
[ RUN      ] AddresslessAttachmentSwitchTest.AnAddresslessAttachmentSwitchDoesNotKillTheProcess
tests/test_AddresslessAttachmentSwitch.cpp:375: Failure
Death test: pollHostsThenExitZero()
    Result: died but not with expected exit code:
            Terminated by signal 11 (core dumped)
Actual msg:
[  DEATH   ]
updateHosts read `(*m_graph)[*vertexOpt2].ip[0]` on the switch a hosts entry says the host is
attached to. findSwitchByDpid checks the datapath id and nothing else, so nothing between it and
this subscript looks at the address list it indexes.
[  FAILED  ] AddresslessAttachmentSwitchTest.AnAddresslessAttachmentSwitchDoesNotKillTheProcess (1083 ms)
...
 1 FAILED TEST
RUN_A_RC=1
```

**`Terminated by signal 11 (core dumped)`——缺陷本人，關在子行程裡。**

### 1.2 🔴 RUN B — 同一顆 binary、同一個變異、只是把 filter 放寬到整個 suite

```text
[==========] Running 6 tests from 1 test suite.
[ RUN      ] AddresslessAttachmentSwitchTest.AnAddresslessAttachmentSwitchDoesNotKillTheProcess
...
[  FAILED  ] AddresslessAttachmentSwitchTest.AnAddresslessAttachmentSwitchDoesNotKillTheProcess (1084 ms)
[ RUN      ] AddresslessAttachmentSwitchTest.TheHostOnAnAddresslessAttachmentSwitchIsStillMarkedUp
reproduce_red.sh: line 53: 1176936 Segmentation fault      (core dumped) stdbuf -oL -eL "$BIN" \
    --gtest_filter='AddresslessAttachmentSwitchTest.*'
RUN_B_RC=139
```

**這一段就是整份設計的理由，而且是在這個檔案自己身上量到的，不是引述別人的。**
第二支測試是 in-process 的，它在**測試行程裡**碰到同一個空 `ip` ⇒ 整個行程 SIGSEGV，
**後面四支測試一個裁決都沒有**。

⇒ 兩件事同時被證明：
* **為什麼要 death test**：普通 build 上這個缺陷不產生紅線，它把 binary 帶走。
  RUN A 有名字、RUN B 只有一個 shell 印的 `Segmentation fault`。
* **為什麼閘門的 GROUP 1 要收窄 filter**：`run_suite` 的 stdout 是重導向的（block-buffered），
  一個死在中途的行程可以把已經印出去的裁決丟掉，計分器就會讀到「沒有裁決」而判 SURVIVED——
  那是對**測試**說謊，不是對程式碼說謊。

### 1.3 RUN C — 修法放回去

```text
[==========] 6 tests from 1 test suite ran. (2 ms total)
[  PASSED  ] 6 tests.
RUN_C_RC=0
```
`file restored byte-identical`（`cmp` 對 `cp` 快照），重建 `guarded_build: exit 0`。

### 1.4 ⚠️ 這次手動重現與閘門 M1 的**唯一**差異：縮排

重現腳本用 `read -r -d '' ANCHOR <<'EOF'` 讀 anchor，而 `read` 會依 IFS 去掉**開頭的空白**，
所以我的 anchor 少了第一行的 16 個空格 ⇒ 放回去的那一行落在第 33 欄而不是第 17 欄
（log 第 2 行 `now reads: 1749:` 看得到）。**只有空白，語意與編出來的碼與閘門的 M1 相同**，
而且事後是從 `cp` 快照還原、`cmp` 驗過逐位元組相同。記在這裡而不是省略。

---

## 2. 變異閘門：`tests/shell/mutate_attachment_switch_index_zero.sh`

raw：`raw/W18-03-gate.log`（**01:57:49–04:22:21**，2 小時 24 分，其中絕大部分是等 lock：
今晚 `wt-integrate`／`wt-val`／`wt-w10` 都在排同一把 `/tmp/ndtwin-build.lock`）。

```
9 mutations, 0 survived, 0 invalid
PASS
```

```
  ok       baseline green ([  PASSED  ] 6 tests.), 1 death test present
```

（閘門自己先斷言那支 death test 在——少了它就代表這一處沒有被關住的紅線。）

| | 變異 | 必須紅的測試 | 結果 |
|---|---|---|---|
| M1 | attachment-switch-subscript-restored | `AnAddresslessAttachmentSwitchDoesNotKillTheProcess` | **caught** |
| M2 | fabricates-an-address-for-the-attachment-switch | `TheWarningNamesTheHostAndTheSwitchAndNotTheTopologyFile` | **caught** |
| M3 | the-guard-says-nothing | 同上 | **caught** |
| M4 | guard-hoisted-above-the-host-side-edge | `TheHostSideEdgeIsStillRaisedWhenTheAttachmentSwitchHasNoAddress` | **caught** |
| M5 | guard-hoisted-above-the-host-vertex-update | `TheHostOnAnAddresslessAttachmentSwitchIsStillMarkedUp` | **caught** |
| M6 | no-reverse-edge-is-ever-found | `TheReverseEdgeOfAnAddressedAttachmentSwitchIsStillRaised` | **caught** |
| C1 | helper-spelled-out-at-the-call-site | ——（對照） | **留綠** |
| C2 | attachment-properties-hoisted-to-a-reference | ——（對照） | **留綠** |
| C3 | **warning-reworded-same-two-identifiers** | ——（對照） | **留綠** |

讀法：

* **M1＝缺陷本身**；**M2／M3＝守衛在、答案說謊**（捏位址／默默跳過），sanitizer 永遠看不到這一組。
* 🔴 **M4／M5＝同一個守衛搬高一格與兩格。** 它們證明的是 fixture 有鑑別力：
  M4 紅的是 host 側 edge 那一支、M5 紅的是 host 存活那一支，**兩支不是同一句話**。
  這一族缺陷的形狀就是「一個分支補了、旁邊那個沒補」，而「整筆丟掉」是最順手的錯誤修法。
* **M6＝過度守衛**：對誰都不查 ⇒ 對照組紅。
* 🔴 **C3 是本閘門最重要的對照組。** 它把 WARN 的句子整個改寫、只留下兩個參數（mac、dpid），
  而 `TheWarningNames…` **必須留綠**。這就是「那支測試釘的是識別碼，不是我寫的句子」的證據——
  一個只認死句子的斷言，會在下一個人改善措辭時變紅，並教會他把斷言刪掉。

```
all mutated files restored byte-identical to the working tree they started from.
```

### 2.1 🔴 第一次跑就 PASS，而這不是運氣

W2 的母閘門第一次是 FAIL（兩個問題都在閘門自己：一個變異碰不到缺陷、一個 anchor 不唯一），
一輪 17 分鐘。W14 記取教訓做了 anchor 預檢。本單做了**兩層**預檢，**在排隊之前**：

| 預檢 | 檢什麼 | raw | 結果 |
|---|---|---|---|
| 1 | 解析閘門自己的 9 個 `mutate_must_*` 呼叫：`uniq` 那一行**逐行**唯一（`grep -c -F` 語意，比 `check_gate_anchors.py` 的 `str.count()` 嚴）、整個 anchor 全檔出現剛好 1 次、套用之後檔案真的變了 | `raw/W18-09-preflight-anchors.log` | `9 mutations parsed, 0 problems` |
| 2 | **每一顆變異體都要編得起來**：把 9 個 mutant 各自套到一份記憶體副本，用 ninja 記錄的旗標跑 `-fsyntax-only`（含 `-Werror -Wall -Wextra -Wpedantic`） | `raw/W18-01-preflight-compile.log` | `9 mutants + baseline checked, 0 do not compile` |
| 2b | 新測試 TU 也 `-fsyntax-only`（用 sibling test TU 的旗標） | `raw/W18-02-preflight-testfile-syntax.log` | `syntax-only exit 0` |

第 2 層的理由很具體：一顆編不起來的變異體會被判 INVALID、整輪 FAIL，**而發現它要付一次完整建置**，
今晚有四五個 agent 在排同一把鎖。

兩層預檢用的腳本本身也留在 `raw/`（`preflight_anchors.py`、`preflight_compile.py`、
`syntax_test_file.sh`、`reproduce_red.sh`、`build_all_and_ctest.sh`），
因為「我預檢過了」跟閘門的裁決一樣，是**跑出來的東西**，要能重跑。
`preflight_compile.py` 的編譯旗標不是自己寫的，是從 `ninja -C build -t commands` 抓的那一條——
自己抄一份旗標就是「儀器長得像自己的發現」。

---

## 3. anchor checker

`python3 tests/shell/check_gate_anchors.py e62c8d6f fix/w18-eighth-index-zero`
（raw：`raw/W18-04-anchor-check.log`，唯讀、不建置）：

```
                                               c0            c1
mutate_attachment_switch_index_zero.sh         absent        ok(8)
...
149/150 cells ok  (1 not ok, of which 0 were NOT CHECKED AT ALL)
```

* 唯一那一格「not ok」是**新閘門在 base 上不存在**（`absent`），不是壞掉。
* **其餘每一格 c0 與 c1 完全相同** ⇒ **沒有動到任何既有閘門的 anchor。**
* `ok(8)` 而不是 `ok(9)`：checker 數的是**相異** anchor，而 C1 與 C2 共用同一個 anchor
  （`const auto attachIpOpt = utils::firstAddressRaw((*m_graph)[*vertexOpt2].ip);`）。

---

## 4. 重掃（工單第 3 條）

raw：`raw/W18-05-rescan.log`（唯讀，跑在閘門開始變異之前的乾淨樹上，HEAD `9b6b6f97`）。

`grep -rn '\.ip\[0\]\|ip\.front()\|ip\.at(0)\|ip[0]' src include`，**去掉純註解行**之後剩七行，
**七行全部有守衛**（守衛位置見 FIX §1.2）：

```
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3597   findSwitchByIp        !vprop.ip.empty() &&
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3612   findSwitchByIpNoLock  同上
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3834   buildDpidIpMaps       props.ip.empty() continue
src/ndt_core/intent_translator/IntentTranslator.cpp:781   BlockHostTask         hostProp.ip.empty() 早退
src/ndt_core/power_management/DCPM.cpp:1235               managementIpOf 本體    vp.ip.empty() 早退
src/ndt_core/power_management/DCPM.cpp:2277               smart-plug table      vp.ip.empty() continue
src/ndt_core/power_management/DCPM.cpp:2395               device lookup         !vp.ip.empty() &&
```

⇒ **修完之後，`src/`／`include/` 底下沒有無守衛的 ip 首元素解參考。**
`TopologyAndFlowMonitor.cpp:1730` 現在只是一行**註解**裡提到 `ip[0]`。

---

## 5. 全建與 ctest

raw：`raw/W18-07-buildall-ctest.log`（04:49:56–04:50:28，一次 guarded 呼叫、一次取鎖）。

| 什麼 | 結果 |
|---|---|
| `cmake --build build -j2`（**全部 target**，含 `bin/ndtwin_kernel`） | `BUILD_ALL_RC=0`，四個步驟、**輸出裡一句診斷都沒有** |
| `./build/bin/test_routing_strategy --gtest_filter='AddresslessAttachmentSwitchTest.*'`（最終 binary） | `[  PASSED  ] 6 tests.` |
| `ctest --test-dir build -j2 --output-on-failure` | **`100% tests passed, 0 tests failed out of 1109`**（9.72 s），`CTEST_RC=0` |

新的六支在 ctest 裡是 #1104–#1109，全部 `Passed`。**1109 ＝ W14 交付時的 1103 ＋ 本單 6 支。**

最終 binary sha256：

```
f2d304c453988937d767df01cf1a530a38f458d7ee2ea40faaff221a8ed87493  build/bin/test_routing_strategy
878576954e0a5d8a349675839dcaf099c2bc4565762709c122ad3d92babb4aa0  build/bin/ndtwin_kernel
```

### 5.1 🔴 兩個要講清楚的口徑

1. **腳本裡那個「第二次全建 + 數 warning」的檢查是空的，不要拿它當證據。**
   第一次全建已經把東西建完了，第二次的輸出是 `ninja: no work to do.`
   （raw `W18-08-second-build-noop.log`，一行），所以 `warning lines: 0`／`error lines: 0`
   是**在一個沒有編譯任何東西的 log 上數出來的**——它成立，但它不代表任何事。
   真正的證據是**第一次**全建的完整輸出：只有四行 build step，沒有任何 `warning:`／`error:`，
   而這棵樹是 `-Werror`。
2. **這是增量建置，不是 from-scratch 全建。** `build/` 沿用 W2／W14 那棵樹；本單重編的是
   `TopologyAndFlowMonitor.cpp`（＋新測試 TU）與其下游連結，全部零診斷；沒有重編的 TU
   是先前乾淨編出來的。**本單沒有做冷全建**（要獨占 lock 約 40 分鐘，今晚四五個 agent 在排隊）。
   `build-asan/` **完全沒有動**——本單的紅來自 containment，不是 sanitizer。
