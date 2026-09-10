# FINDINGS #88 / W14：紅 → 綠與變異閘門的逐字輸出

[Co-developed with claude code -- Adam]

本檔只放**跑出來的東西**，不放推導；推導在同目錄的 `FIX-INDEX-ZERO-GUARDS.md`。
全部在 `fix/w14-index-zero-guards`（base：trunk `1536ff17`）之上、worktree
`scratch/overnight-2026-09-05/wt-w2`、`build/` 為 Debug＋Ninja，
每一次 build 都走 `tools/build_guard/guarded_build.sh`（`LOCK_WAIT=10800`）。

**「跑過」與「讀過未執行」分開**：本檔每一段都是跑過的，raw 在 `raw/` 底下。

---

## 1. RED：把 M1 的 subscript 放回去（手動重現，取逐字）

閘門本身只印它自己的裁決行（`caught … went red`），所以另外手動重現**一個**變異取
gtest 的逐字輸出。動的是 `IntentTranslator.cpp` 的 `GET_NETWORK_TOPOLOGY` `hosts[]` 一處，
其餘六處守衛留著。還原用 `cp` 快照，**不是 `git checkout --`**（共用 worktree）。

raw：`raw/W14-09-red-verbatim.log`（06:56:01–06:56:52）。建置 `exit 0`（1/6…6/6）。

```text
[==========] Running 7 tests from 1 test suite.
[----------] Global test environment set-up.
[----------] 7 tests from AddresslessNodeTest
[ RUN      ] AddresslessNodeTest.TheTopologyReplyOverAnAddresslessHostDoesNotKillTheProcess
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-w2/tests/test_AddresslessNodeReplies.cpp:387: Failure
Death test: networkTopologyThenExitZero()
    Result: died but not with expected exit code:
            Terminated by signal 11 (core dumped)
Actual msg:
[  DEATH   ]
GET_NETWORK_TOPOLOGY read vprop.ip[0] on a HOST whose address list is empty. The loop filters on vertexType and nothing else, and the load-time gate that keeps `ip` non-empty covers SWITCH vertices only.
[  FAILED  ] AddresslessNodeTest.TheTopologyReplyOverAnAddresslessHostDoesNotKillTheProcess (1079 ms)
[ RUN      ] AddresslessNodeTest.TheHostListingOverAnAddresslessHostDoesNotKillTheProcess
[       OK ] AddresslessNodeTest.TheHostListingOverAnAddresslessHostDoesNotKillTheProcess (2 ms)
[ RUN      ] AddresslessNodeTest.TheAgentPromptOverAnAddresslessHostDoesNotKillTheProcess
[       OK ] AddresslessNodeTest.TheAgentPromptOverAnAddresslessHostDoesNotKillTheProcess (2 ms)
[ RUN      ] AddresslessNodeTest.APathQueryFromAnAddresslessHostDoesNotKillTheProcess
[       OK ] AddresslessNodeTest.APathQueryFromAnAddresslessHostDoesNotKillTheProcess (1 ms)
[ RUN      ] AddresslessNodeTest.APathQueryToAnAddresslessHostDoesNotKillTheProcess
[       OK ] AddresslessNodeTest.APathQueryToAnAddresslessHostDoesNotKillTheProcess (1 ms)
[ RUN      ] AddresslessNodeTest.ResolvingAnAddresslessSwitchByNameDoesNotKillTheProcess
[       OK ] AddresslessNodeTest.ResolvingAnAddresslessSwitchByNameDoesNotKillTheProcess (1 ms)
[ RUN      ] AddresslessNodeTest.TheTopologyReplyOverAnAddresslessSwitchDoesNotKillTheProcess
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-w2/tests/test_AddresslessNodeReplies.cpp:439: Failure
Death test: networkTopologyThenExitZero()
    Result: died but not with expected exit code:
            Terminated by signal 11 (core dumped)
Actual msg:
[  DEATH   ]
GET_NETWORK_TOPOLOGY's switches[] branch read vprop.ip[0] with no check of its own.
[  FAILED  ] AddresslessNodeTest.TheTopologyReplyOverAnAddresslessSwitchDoesNotKillTheProcess (1081 ms)
[----------] 7 tests from AddresslessNodeTest (2171 ms total)

[==========] 7 tests from 1 test suite ran. (2171 ms total)
[  PASSED  ] 5 tests.
[  FAILED  ] 2 tests, listed below:
[  FAILED  ] AddresslessNodeTest.TheTopologyReplyOverAnAddresslessHostDoesNotKillTheProcess
[  FAILED  ] AddresslessNodeTest.TheTopologyReplyOverAnAddresslessSwitchDoesNotKillTheProcess

 2 FAILED TESTS
```
`=== gtest rc 1 ===`，還原後 `restored byte-identical`。

### 這一段裡有三件事值得單獨指出來

1. **`Terminated by signal 11 (core dumped)`** —— 缺陷本人。它落在**子行程**裡，
   所以父行程活著、印得出有名字的紅線。這正是這套測試存在的理由：
   在普通 build 上 UB 不會產生紅線，它會把整個 binary 帶走、什麼裁決都不留。
2. **只有兩支紅，另外五支綠。** M1 只還原一處 subscript，而那一處與 switches[] 那一處在
   **同一個迴圈**裡（同一次 `networkTopologyThenExitZero()` 走過兩者）⇒ 這兩支一起紅是對的。
   其餘五處守衛沒被動，所以那五支必須綠——**它們綠，就是「紅不是被整體污染出來的」的證據。**
3. **紅那一行帶著測試自己的 `<<` 訊息**，撞到的人不必回頭讀原始碼就知道是哪一個站點。

---

## 2. 閘門：`tests/shell/mutate_index_zero_guards.sh`

raw：`raw/W14-04-gate.log`（05:45:03–06:55:21，**單輪、一個 build 目錄**）。
🔴 **第一次跑就 PASS**（母閘門 `mutate_first_address_of.sh` 第一次是 FAIL；
本單事前用一支 preflight 把 16 條 anchor 的**逐行唯一性**與**多行 anchor 出現次數**全部核過，
就是為了不重蹈 W2 §4.2 的 M7／M5）。

```text
=== GROUP 1: the defect restored, one site at a time (filter: AddresslessNodeTest.*DoesNotKillTheProcess) ===
baseline (unmutated) must build and be green in build:
  ok       baseline green ([  PASSED  ] 17 tests.), 7 death tests present

mutations:
  caught   M1 topology-reply-hosts-subscript-restored       (TheTopologyReplyOverAnAddresslessHostDoesNotKillTheProcess went red)
  caught   M2 host-listing-subscript-restored               (TheHostListingOverAnAddresslessHostDoesNotKillTheProcess went red)
  caught   M3 agent-prompt-subscript-restored               (TheAgentPromptOverAnAddresslessHostDoesNotKillTheProcess went red)
  caught   M4 path-source-subscript-restored                (APathQueryFromAnAddresslessHostDoesNotKillTheProcess went red)
  caught   M5 path-destination-subscript-restored           (APathQueryToAnAddresslessHostDoesNotKillTheProcess went red)
  caught   M6 switch-ip-by-name-subscript-restored          (ResolvingAnAddresslessSwitchByNameDoesNotKillTheProcess went red)
  caught   M7 topology-reply-switches-subscript-restored    (TheTopologyReplyOverAnAddresslessSwitchDoesNotKillTheProcess went red)

=== GROUP 2: guarded, defined, and wrong (filter: AddresslessNodeTest.*) ===
mutations:
  caught   M8 fabricates-0.0.0.0-in-the-topology-reply      (TheTopologyReplyGivesTheAddresslessNodesNullAndNotAnAddress went red)
  caught   M9 drops-the-addressless-host-from-the-listing   (TheHostListingKeepsTheAddresslessHostWithANullAddress went red)
  caught   M10 fabricates-an-address-in-the-agent-prompt    (ThePromptDescribesTheAddresslessHostWithoutGivingItAnAddress went red)
  caught   M11 path-refusal-does-not-name-the-host          (APathQueryFromAnAddresslessHostIsRefusedAndSaysWhich went red)
  caught   M12 switch-lookup-answers-nullopt-for-everything (ASwitchWithAnAddressStillResolves went red)
  caught   M13 every-path-query-refused                     (APathBetweenTwoAddressedHostsStillAnswers went red)
  ok       C1 helper-inlined-at-the-host-listing            (control stayed green, as it must)
  ok       C2 path-guard-written-the-other-way              (control stayed green, as it must)
  ok       C3 prompt-substitute-built-in-two-steps          (control stayed green, as it must)

all mutated files restored byte-identical to the working tree they started from.

16 mutations, 0 survived, 0 invalid
PASS
```

* **M1–M7 = 七處站點各一個紅**（工單只要求「五處走得到的至少各一個」；兩處走不到的也有）。
* **M8–M13 = 守衛在、答案說謊**：捏 `0.0.0.0`（兩處）、把節點從清單裡丟掉、拒絕不說是哪一台、
  兩種 over-guard。**這一組是 sanitizer 永遠看不到的那一半。**
* **C1–C3 全綠** ⇒ 上面 13 個 `caught` 不是「這個 harness 對任何編輯都報紅」。

---

## 3. anchor checker

`tests/shell/check_gate_anchors.py trunk fix/w14-index-zero-guards`，raw：
`raw/W14-05-anchors-trunk-vs-branch.log`。

```text
147/148 cells ok  (1 not ok, of which 0 were NOT CHECKED AT ALL)
```

唯一那一格是 `mutate_index_zero_guards.sh` 在 trunk 上 `absent`（新閘門，trunk 沒有），
在本分支 `ok(13)`。**其餘 147 格 trunk 與本分支逐格相同** ⇒ 本單沒有動到任何既有閘門的 anchor。

> 13 不是 16：`check_gate_anchors.py` 以 anchor 文字去重，而 M4／M5、M13／C2、M10／C3
> 各共用一條 anchor。閘門自己跑的是 16 個變異。
> 🔴 而且照 W2 §4.2 的教訓：**checker 回 `ok` 不代表閘門跑得動**——真正的證明是 §2 那一輪。

---

## 4. GREEN：全建與全套

| 什麼 | 結果 | raw |
|---|---|---|
| 增量建置（`--target test_routing_strategy`，含 trunk delta＋本單改動＋新測試 TU） | `exit 0`，**0 error / 0 warning** | `W14-01-build1.log` |
| 還原後重建（閘門跑完，binary 是最後一個 control 建的 ⇒ 必須重建） | `exit 0` | `W14-06-build2.log` |
| **全部 target**（`cmake --build build`，含 `src/main.cpp` 與 `bin/ndtwin_kernel`） | `exit 0`，**0 error / 0 warning** | `W14-10-build-all-targets.log` |
| `ctest -j2 --output-on-failure` | **`100% tests passed, 0 tests failed out of 1103`**（9.37 s） | `W14-08-ctest.log` |

🔴 **為什麼要多跑一次「全部 target」**：本單改了 `include/…/IntentTranslator.hpp`，
而 **`src/main.cpp` include 它、又不屬於 `test_routing_strategy`** ⇒
只建測試 target 的話，那個 header 改動**從來沒有被編進 kernel 本體**，
而這棵樹是 `-Werror`。`W14-10` 的 `[1/9] Building … src/main.cpp.o` 就是補上的那一格。

最終 binary（`W14-07-binary-sha-final.txt`）：

```text
04d2fef55d0be5ffe820d7dc5c7ef0863c6ee484271be85fafc343b4fa5bcad4  build/bin/test_routing_strategy
90304800a8c1f6e3a0feecee7d6fb47a1fd02c8609cf0d04098eca82fe9e9a86  build/bin/ndtwin_kernel
```

新測試在**最終** binary 上重跑：`20 tests from 2 test suites ran … [  PASSED  ] 20 tests.`

⚠️ **口徑**：以上都是**增量**建置（`build/` 沿用 W2 那棵樹，本分支只重建了受影響的 TU）。
**本單沒有做 from-scratch 全建**——那要獨占 build lock 約 40 分鐘，而今晚有多個 agent 在排隊。
受本單改動影響的每一個 TU 都重編過且零診斷；沒重編的 TU 是先前乾淨編出來的。
