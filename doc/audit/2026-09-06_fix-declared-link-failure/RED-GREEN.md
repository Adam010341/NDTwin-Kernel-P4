# RED-GREEN — B-6：宣告的 link failure 必須贏過拓樸輪詢

分支 `fix/w8-declared-link-failure-sticky`，基底 trunk `1536ff17`。
[Co-developed with claude code -- Adam]

🔴 **本檔只放本 session 親自跑過的東西，逐字。** 讀過未執行的推論一律不進這個檔。

---

## 0. 「未修的 trunk 上必須紅」怎麼做的——與它為什麼不是一次 `git checkout trunk`

工單 §5 要求「未修 trunk 上跑 `ADeclaredLinkFailureSurvivesATopologyPoll` 必須紅」。
**這個案子在 trunk 上編不過**，因為它呼叫 `setEdgeDownByDeclaration`，而那個 API 是修法帶進來的
——而「編不過」不是這裡要的紅（工單自己寫了：紅的原因要是 `isUp` 是 `true`）。

所以紅是用**兩顆變異**取得的，兩顆都在變異閘裡、都逐字留在下面：

| 變異 | 它把樹變成什麼 | 為什麼等價於 trunk |
|---|---|---|
| **M1** | `updateLinks` 的否決分支關掉（`if (false)`），寫回無條件 `isUp = true` | 這就是 trunk 的 `updateLinks`，一行不差 |
| **M4** | `setEdgeDownByDeclaration` 不再設旗標，只寫 `isUp = false` | 這就是 trunk 的 `setEdgeDown`，也就是 trunk 的推播路徑實際呼叫的那一個 |

**兩顆分別關掉修法的兩端**（否決端＝M1、宣告端＝M4），而任一端關掉就是 B-6 回來。
除此之外還有一顆更接近 trunk 的證據：`DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy`
**只用 trunk 上就存在的公開端點**（`POST /ndt/link_failure_detected` → 一次 poll →
`GET /ndt/get_graph_data`），所以**把它單獨放到 trunk 上是編得過、跑得動、而且會紅的**
（🔵 這一句是推的：我沒有真的在 trunk 上跑它，因為那要再開一棵樹、再全建一次）。
⚠️ **同一個 suite 的另外四個案子不行**——它們打 `/ndt/inject_link_*`，trunk 上那兩條路由不存在，
會拿到 404。「這個 suite 在 trunk 上編得過」是不成立的說法，成立的是「這一個案子」。
它在 M1／M4 之下都紅，逐字在 §2。

---

## 1. 逐字：變異閘全文

指令（🟢 2026-09-06 06:06–06:09 跑的）：

```
JOBS=2 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh \
    ./tests/shell/mutate_declared_link_failure_survives_poll.sh
```

⚠️ **一句話的自我揭露**：閘門**檔頭註解**裡「哪幾顆屬於哪個方向」的編號在 06:06（閘門還在等
build lock 時）用原子 rename 改過一次——`(M1,M2,M4,M5)/(M3,M6,M7,M8)` 改成
`(M1..M4)/(M5..M8)`，因為**印出來的編號是依序的**。**只有註解，沒有動任何變異或斷言**；
下面的逐字輸出以它自己印的 M1..M8 為準。閘門的 W1 對照（改註解必須留綠）正是這件事的證據。
跑完後的檔案 sha256 `5ce7bea35e991f7bc2b2a84f893cb997f0833058ec0a009d7fb0a7b4b10415f1`。

```
guarded_build: jobs=2 mem_high=3G mem_max=4G lock=/tmp/ndtwin-build.lock
guarded_build: $ ./tests/shell/mutate_declared_link_failure_survives_poll.sh
=== anchor uniqueness (exact substring count must be 1) ===
  ok     link-veto        src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1
  ok     link-lifts       src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1
  ok     link-enables     src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1
  ok     declared-down    src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1
  ok     declared-clear   src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1
  ok     derived-down     src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1
  ok     link-warn-text   src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1
  ok     link-comment     src/ndt_core/collection/TopologyAndFlowMonitor.cpp   x1

=== baseline (unmutated working tree) must build and be green ===
  ok       baseline green (15 cases in DeclaredLinkFailureTest.*:DeclaredLinkFailureWireTest.*)
  ok       test_routing_strategy sha256 d226ec6c744fb23e

=== M1. the defect verbatim: the poll lifts every link it is told about ===
  expect red: DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll DeclaredLinkFailureTest.EveryLaterPollDeclinesTheDeclaredLinkToo DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy
  ✅ caught  red: DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll DeclaredLinkFailureTest.EveryLaterPollDeclinesTheDeclaredLinkToo DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy

=== M2. the veto is inverted: only a declared link is raised ===
  expect red: DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown
  ✅ caught  red: DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown

=== M3. recovery does not withdraw the declaration ===
  expect red: DeclaredLinkFailureTest.ADeclaredRecoveryLetsThePollRaiseTheEdgeAgain DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery DeclaredLinkFailureWireTest.ARecoveryWithdrawsTheDeclarationAndTheNextPollRaisesTheLink
  ✅ caught  red: DeclaredLinkFailureTest.ADeclaredRecoveryLetsThePollRaiseTheEdgeAgain DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery DeclaredLinkFailureWireTest.ARecoveryWithdrawsTheDeclarationAndTheNextPollRaisesTheLink

=== M4. the push path records an observation instead of a declaration (= trunk) ===
  expect red: DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll DeclaredLinkFailureTest.EveryLaterPollDeclinesTheDeclaredLinkToo DeclaredLinkFailureTest.ObservationWritersNeitherSetNorClearTheDeclaration DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy
  ✅ caught  red: DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll DeclaredLinkFailureTest.EveryLaterPollDeclinesTheDeclaredLinkToo DeclaredLinkFailureTest.ObservationWritersNeitherSetNorClearTheDeclaration DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy

=== M5. the poll never raises any link ===
  expect red: DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack
  ✅ caught  red: DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack

=== M6. the veto blocks isEnabled as well as isUp ===
  expect red: DeclaredLinkFailureTest.ADeclaredDownEdgeIsStillAdministrativelyEnabled
  ✅ caught  red: DeclaredLinkFailureTest.ADeclaredDownEdgeIsStillAdministrativelyEnabled

=== M7. the derived liveness pass marks its edges as declared ===
  expect red: DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack
  ✅ caught  red: DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack

=== M8. the veto reads isUp instead of the declaration ===
  expect red: DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack
  ✅ caught  red: DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack

=== W1. a comment, nothing else (MUST stay green) ===
  ✅ survived -- behaviour unchanged, so the catches above are about behaviour

=== W2. the declined-resurrection warning is reworded (MUST stay green) ===
  ✅ survived -- behaviour unchanged, so the catches above are about behaviour

=== W3. the veto is written as an equivalent expression (MUST stay green) ===
  ✅ survived -- behaviour unchanged, so the catches above are about behaviour

=== restore ===
  all 1 file(s) byte-identical to the pre-run snapshot
  rebuilt from the restored tree
  suite green again after restore
  test binary sha unchanged: d226ec6c744fb23e

=== verdict ===
  8 mutations, 0 survived
  3 widenings, 0 wrongly caught
  B-6 gate: the defect cannot be put back by any of four routes, a poll that stops raising
  links is caught by four more, and three behaviour-preserving edits were left alone.
guarded_build: exit 0
GATE_EXIT=0
```


---

## 2. 逐字：把缺陷放回去之後，紅在哪一行

🟢 2026-09-06 跑的。做法：把變異套上去 → `cmake --build build --target test_routing_strategy`（走 guard）→ 跑指名的案子 → 用 `cp -p` 快照還原、sha256 對過、重建、確認全綠。腳本在 session scratchpad，不進版控。

### 2.1 M1 —— 否決分支拿掉（＝ trunk 的 `updateLinks`）

```
[ RUN      ] DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-integrate/tests/test_PollDoesNotResurrect.cpp:900: Failure
Value of: edgeIsUp(fwd())
  Actual: true
Expected: false
a topology poll lifted a link an operator declared failed; the injection ends when the control plane's list is next applied rather than when it is withdrawn (B-6)
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-integrate/tests/test_PollDoesNotResurrect.cpp:903: Failure
Value of: edgeIsUp(rev())
  Actual: true
Expected: false
the reverse direction was resurrected by the poll, so the link is half up and no caller asked for that
[  FAILED  ] DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll (17 ms)
```

同一顆變異之下，那個只走 trunk 上就存在的公開端點的案子（見 §0 的但書：**這一個**編得過，同 suite 打 `inject_link_*` 的四個不行）：

```
[ RUN      ] DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-integrate/tests/test_HttpSessionRouting.cpp:876: Failure
Value of: fwd.value("is_up", true)
  Actual: true
Expected: false
a topology poll resurrected a link an operator declared failed -- the injection ends when the control plane's list is next applied rather than when it is withdrawn (B-6)
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-integrate/tests/test_HttpSessionRouting.cpp:879: Failure
Value of: rev.value("is_up", true)
  Actual: true
Expected: false
the reverse direction came back
[  FAILED  ] DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy (1 ms)
```

### 2.2 M4 —— 推播路徑改回叫觀測版（＝ trunk 的 `handleLinkFailure`）

```
[ RUN      ] DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-integrate/tests/test_PollDoesNotResurrect.cpp:900: Failure
Value of: edgeIsUp(fwd())
  Actual: true
Expected: false
a topology poll lifted a link an operator declared failed; the injection ends when the control plane's list is next applied rather than when it is withdrawn (B-6)
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-integrate/tests/test_PollDoesNotResurrect.cpp:903: Failure
Value of: edgeIsUp(rev())
  Actual: true
Expected: false
the reverse direction was resurrected by the poll, so the link is half up and no caller asked for that
/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-integrate/tests/test_PollDoesNotResurrect.cpp:906: Failure
Expected equality of these values:
  edgeDownReason(fwd())
    Which is: "none"
  "declared"
an edge that is down because somebody said so must say so: that is the whole difference between this fix and an internal flag
[  FAILED  ] DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll (16 ms)
```

### 2.3 還原之後，同一批案子全綠

```
[       OK ] NetemLinkFaultTest.ARestoreThatLeftNetemBehindIsReportedAsAFailure (0 ms)
[----------] 17 tests from NetemLinkFaultTest (0 ms total)

[----------] Global test environment tear-down
[==========] 32 tests from 3 test suites ran. (150 ms total)
[  PASSED  ] 32 tests.
```


---

## 3. 逐字：全建 ＋ ctest

`cmake --build build`（**全部 target，不只測試**）。只剩兩步，是因為同一次 guard 之內前面幾步
已經把測試那一半建完了——`ndtwin_kernel` 這個主二進位是這次才被 `GraphTypes.hpp` 帶著重編的：

```
[1/2] Building CXX object CMakeFiles/ndtwin_kernel.dir/src/main.cpp.o
[2/2] Linking CXX executable bin/ndtwin_kernel
```

整份 build log 的計數（🟢 腳本自己算的，不是我目測）：

```
warnings: 0  errors: 0
```

還原之後 `TopologyAndFlowMonitor.cpp` 與變異前 byte-identical：

```
restored byte-identically: sha256 c649ea5c4034afff
```

```
1111/1115 Test #1111: NetemLinkFaultTest.ABadInterfaceNameNeverReachesTc ......................................................   Passed    0.01 sec
          Start 1113: NetemLinkFaultTest.RestoringDeletesTheNetemWhereItActuallyIs
1112/1115 Test #1112: NetemLinkFaultTest.AnUnreadableTreeStopsTheCut ..........................................................   Passed    0.01 sec
          Start 1114: NetemLinkFaultTest.RestoringACleanInterfaceIsANoopNotAnError
1113/1115 Test #1113: NetemLinkFaultTest.RestoringDeletesTheNetemWhereItActuallyIs ............................................   Passed    0.01 sec
          Start 1115: NetemLinkFaultTest.ARestoreThatLeftNetemBehindIsReportedAsAFailure
1114/1115 Test #1114: NetemLinkFaultTest.RestoringACleanInterfaceIsANoopNotAnError ............................................   Passed    0.01 sec
1115/1115 Test #1115: NetemLinkFaultTest.ARestoreThatLeftNetemBehindIsReportedAsAFailure ......................................   Passed    0.01 sec

100% tests passed, 0 tests failed out of 1115

Total Test time (real) =   9.73 sec
```

