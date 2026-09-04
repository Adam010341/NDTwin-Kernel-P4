# FINDINGS #85：紅 → 綠與變異閘門的逐字輸出

[Co-developed with claude code -- Adam]

本檔只放**跑出來的東西**，不放推導；推導在同目錄的 `FIX-CPU-REPORT-NO-IP.md`。
所有輸出都在 `f138b767` 之上、worktree `wt-noip`、`build/` 為 Debug＋Ninja，
每一次 build 都走 `tools/build_guard/guarded_build.sh`（`JOBS=1`、`LOCK_WAIT=10800`）。

🔴 **本檔記錄一次 SURVIVOR，而且它是真的。** 見 §4：閘門在 09-04 11:54 抓出我的
**測試**有洞（不是碼有洞），我補了第二個 death test。第二支的紅／綠由 auditor 的
merged-tree 閘門執行來證明，**不是由本檔證明**——本檔到 M2 為止。

---

## 1. RED：trunk 的四個解參考放回去

紅碼怎麼造的：把四個守衛換回 trunk 的那一行，**helper 定義留著**（新測試會呼叫
`reportKeyForSwitchWithoutIp`，拿掉會變成 link error 而不是紅）。
產生器自己對帳過：

```
trunk has 8 such reads; the red source has 9 (want 8 + 1 = 9)
```

多的那一個是 `managementIpOf` 自己那句**已經被空檢查守住**的 `ip.front()`。

`build/bin/test_routing_strategy --gtest_filter='NoIpSwitchTest.*'`，逐字：

```text
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-noip/build/_deps/googletest-src/googletest/src/gtest_main.cc
Note: Google Test filter = NoIpSwitchTest.*
[==========] Running 8 tests from 1 test suite.
[----------] Global test environment set-up.
[----------] 8 tests from NoIpSwitchTest
[ RUN      ] NoIpSwitchTest.UpdateSwitchesInventsNoVertexForADpidTheTopologyDoesNotDeclare
[       OK ] NoIpSwitchTest.UpdateSwitchesInventsNoVertexForADpidTheTopologyDoesNotDeclare (0 ms)
[ RUN      ] NoIpSwitchTest.AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess
/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-noip/tests/test_CpuReportNoIpSwitch.cpp:301: Failure
Death test: oneStatusRoundThenExitZero()
    Result: died but not with expected exit code:
            Terminated by signal 11 (core dumped)
Actual msg:
[  DEATH   ] 
a switch with no management address must not be able to end the process. The status worker runs these four in one round every 10 s, and an unhandled SIGSEGV on that thread ends the kernel, not just the round.
[  FAILED  ] NoIpSwitchTest.AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess (1122 ms)
[ RUN      ] NoIpSwitchTest.TheAddresslessSwitchKeepsAKeyAtTheDocumentedSentinel
```

行程退出碼 **139**（SIGSEGV，core dumped）。

**要讀的是這一段的形狀，不只是它紅了**：

* 第 1 個測試（可達性）**綠**——它本來就不依賴這個修，它是降級的證據。
* 第 2 個測試 **紅，而且有名字**：`[  FAILED  ] NoIpSwitchTest.AStatusRound...`，
  原因印成 `Result: died but not with expected exit code: Terminated by signal 11 (core dumped)`。
* 第 3 個測試 `[ RUN      ]` 之後**沒有下文**——log 到那裡就斷了。那是行程死掉、
  後面 5 個測試連跑都沒跑，也沒有任何 `[  FAILED  ]` 行。

第 3 行就是為什麼第 2 個測試要 fork：**同一個缺陷，包在 death test 裡是一行具名的紅，
不包就是「這次執行死了」**，而且會把 `test_routing_strategy` 裡後面每一個 suite 一起帶走。

---

## 2. GREEN：修回去

```text
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-noip/build/_deps/googletest-src/googletest/src/gtest_main.cc
Note: Google Test filter = NoIpSwitchTest.*
[==========] Running 8 tests from 1 test suite.
[----------] Global test environment set-up.
[----------] 8 tests from NoIpSwitchTest
[ RUN      ] NoIpSwitchTest.UpdateSwitchesInventsNoVertexForADpidTheTopologyDoesNotDeclare
[       OK ] NoIpSwitchTest.UpdateSwitchesInventsNoVertexForADpidTheTopologyDoesNotDeclare (0 ms)
[ RUN      ] NoIpSwitchTest.AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-noip/build/_deps/googletest-src/googletest/src/gtest_main.cc
[       OK ] NoIpSwitchTest.AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess (10 ms)
[ RUN      ] NoIpSwitchTest.TheAddresslessSwitchKeepsAKeyAtTheDocumentedSentinel
[       OK ] NoIpSwitchTest.TheAddresslessSwitchKeepsAKeyAtTheDocumentedSentinel (0 ms)
[ RUN      ] NoIpSwitchTest.TheSentinelIsNotSomethingAReaderWouldTakeForAMeasurement
[       OK ] NoIpSwitchTest.TheSentinelIsNotSomethingAReaderWouldTakeForAMeasurement (0 ms)
[ RUN      ] NoIpSwitchTest.TheMissingAddressWarnsOncePerEpisodeAndNamesTheDpid
[       OK ] NoIpSwitchTest.TheMissingAddressWarnsOncePerEpisodeAndNamesTheDpid (0 ms)
[ RUN      ] NoIpSwitchTest.ANewEpisodeWarnsAgain
[       OK ] NoIpSwitchTest.ANewEpisodeWarnsAgain (0 ms)
[ RUN      ] NoIpSwitchTest.TestbedPowerReportsTheSentinelForAnAddresslessSwitch
[       OK ] NoIpSwitchTest.TestbedPowerReportsTheSentinelForAnAddresslessSwitch (0 ms)
[ RUN      ] NoIpSwitchTest.MininetPowerStillReportsARealFigureForAnAddresslessSwitch
[       OK ] NoIpSwitchTest.MininetPowerStillReportsARealFigureForAnAddresslessSwitch (0 ms)
[----------] 8 tests from NoIpSwitchTest (11 ms total)

[----------] Global test environment tear-down
[==========] 8 tests from 1 test suite ran. (12 ms total)
[  PASSED  ] 8 tests.
```

鄰居 suite（同兩個檔）與整顆 binary：

```text

[----------] Global test environment tear-down
[==========] 26 tests from 3 test suites ran. (1433 ms total)
[  PASSED  ] 26 tests.


[----------] Global test environment tear-down
[==========] 1007 tests from 128 test suites ran. (9202 ms total)
[  PASSED  ] 1007 tests.
```

| 範圍 | 結果 |
|---|---|
| `NoIpSwitchTest.*`（本支新增） | **8/8 PASSED** |
| `SimulatedDeviceMetricsTest` ＋ `PowerManagerShutdown` ＋ `TopologyInputValidation` | **26/26 PASSED** |
| 整顆 `test_routing_strategy` | **1007 tests / 128 suites，全綠** |

---

## 3. 閘門：`tests/shell/mutate_cpu_report_no_ip.sh`

**這一輪沒有跑完。** M3 從 11:54 起卡在 `/tmp/ndtwin-build.lock`（閘門每一個變異都自己
走一次 guard，而 auditor 的 merged-tree pipeline 在前面），auditor 於 12:58 送 TERM；
腳本的 EXIT trap 復原了兩個原始檔（`git status` dirty=0，auditor 確認）。
**M3–M9 與 C1–C3 的判定由 merged-tree 那一輪產生，不在本檔。**

逐字（到被停為止）：

```text
baseline (unmutated) must build and be green:
  ok       baseline green ([  PASSED  ] 8 tests.)

mutations:
tests/shell/mutate_cpu_report_no_ip.sh: line 111: 3722641 Segmentation fault      (core dumped) "$BIN" --gtest_filter="$FILTER" > "$BK/run.log" 2>&1
  caught   M1 cpu-dereferences-empty-ip-again             (NoIpSwitchTest.AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess went red)
tests/shell/mutate_cpu_report_no_ip.sh: line 111: 3736232 Segmentation fault      (core dumped) "$BIN" --gtest_filter="$FILTER" > "$BK/run.log" 2>&1
  SURVIVED M2 testbed-power-dereferences-empty-ip         (process DIED with no verdict line -- the death test was
                                                           meant to contain this; NoIpSwitchTest.AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess never reported)
             [       OK ] NoIpSwitchTest.TheSentinelIsNotSomethingAReaderWouldTakeForAMeasurement (0 ms)
             [ RUN      ] NoIpSwitchTest.TheMissingAddressWarnsOncePerEpisodeAndNamesTheDpid
             [       OK ] NoIpSwitchTest.TheMissingAddressWarnsOncePerEpisodeAndNamesTheDpid (0 ms)
             [ RUN      ] NoIpSwitchTest.ANewEpisodeWarnsAgain
             [       OK ] NoIpSwitchTest.ANewEpisodeWarnsAgain (0 ms)
             [ RUN      ] NoIpSwitchTest.TestbedPowerReportsTheSentinelForAnAddresslessSwitch
```

**M1 caught。** 這是「把崩潰放回去」——trunk 在那個站點的原句，一字不差——而且它是
**一行具名的紅**，不是 crash-by-luck。它證明 death test 真的把 fault 關住了。

---

## 4. 🔴 M2 SURVIVED（09-04 11:54），以及它抓到的是什麼

**閘門抓到的不是碼的洞，是我的測試的洞。**

M2 把 **TESTBED power 路徑**的解參考放回去。原本 M2 指名的必死測試是
`AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess`——而那個測試
`buildManager(utils::MININET)`。**MININET 的 power 報表根本不讀位址**
（`syntheticPowerMilliwattsFor(dpid)`，只吃 dpid），所以那個 death test
**永遠碰不到 M2 改的那一行**。

結果 fault 落在 `TestbedPowerReportsTheSentinelForAnAddresslessSwitch`——一個
**在行程內**直接呼叫的測試——於是 binary 當場死掉、一行 `[  FAILED  ]` 都沒有。
閘門自己的規則把這種情況印成 SURVIVED 而不是 caught：

> `SURVIVED M2 ... (process DIED with no verdict line -- the death test was meant to contain this)`

**這條規則是我寫閘門時特地加的**，就是為了不讓「crash 但沒有判定行」被讀成乾淨的紅。
它在第一次真的遇到這種情況時就發揮作用了。

**修法**：加第二個 death test

```
NoIpSwitchTest.ATestbedStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess
```

在 TESTBED 模式下跑同一輪四份報表，**宣告位置在所有行程內 TESTBED 測試之前**
（gtest 依宣告順序跑；擺在後面等於把洞放回去）。閘門的 M2 已改指這一支。
圖裡只放那台沒有位址的 switch，所以不會 shell out 到 ssh／snmpget。

⚠️ **這一支的紅／綠尚未由我證明。** 只做了 `-fsyntax-only`（見 §5）；
紅綠由 auditor 在 merged tree 上重跑 `mutate_cpu_report_no_ip.sh` 產生。
**在那個結果出來之前，第二個 death test 屬於「沒看過紅」，照規矩不算交付。**

---

## 5. 這一輪只做到編譯檢查的部分

lock 保留給 integrate pipeline 與今晚的 kernel rebuild，所以第二個 death test
**沒有 build、沒有跑閘門**，只用該 TU 在 `build/build.ninja` 裡的真實旗標做
`-fsyntax-only`（含 `-Werror`）：

```
g++ -fsyntax-only -DBOOST_SYSTEM_DYN_LINK ... -std=c++23 -Wall -Wextra -Wpedantic -Werror ... tests/test_CpuReportNoIpSwitch.cpp
→ rc 0
```

`build/compile_commands.json` 在這個 build 樹裡不存在（沒開
`CMAKE_EXPORT_COMPILE_COMMANDS`），旗標改從 `build.ninja` 的該 TU 條目取得，
內容與 auditor 指定的來源等價。

---

## 6. 對帳

| 主張 | 憑什麼 |
|---|---|
| 缺陷會殺掉行程 | §1 的 `Terminated by signal 11`，加上 stop agent 的 gdb 堆疊（audit-raw） |
| death test 把它變成具名的紅 | §1 第 2 個測試 vs 第 3 個測試的差別 |
| 修完全綠 | §2，1007/1007 |
| M1（放回崩潰）被抓 | §3 |
| 我的測試曾有洞 | §4，閘門自己印的 SURVIVED |
| 第二個 death test 有效 | **尚未證明**，等 merged-tree 閘門 |
