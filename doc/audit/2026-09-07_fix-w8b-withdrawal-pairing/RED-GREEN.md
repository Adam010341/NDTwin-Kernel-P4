# W8b — 看紅的逐字紀錄

分支 `fix/w8b-withdrawal-needs-observed-failure`，base＝`fix/w8-declared-link-failure-sticky`@`017c060f`。
worktree `scratch/overnight-2026-09-05/wt-integrate`。
[Co-developed with claude code -- Adam]

> **本檔全部 🟢 跑過**（2026-09-07 02:3x–03:3x，`JOBS=2 LOCK_WAIT=10800` 走
> `tools/build_guard/guarded_build.sh`，四個 agent 共用同一把 `/tmp/ndtwin-build.lock`）。
> 逐字 log 在 session scratchpad（`logs/gate-w8b.log`、`logs/gate-b6-rerun.log`、
> `logs/red-verbatim.log`）——**那是 scratch，不進版控**；本檔是它的可引用摘錄。

---

## §0 「在未修的樹上必須紅」這句話，在這張單上是什麼意思

工單要的是「至少一個 mutation 把修法拿掉 ⇒ 測試紅，逐字留檔」。本單的三個修法各有一顆
**與未修狀態逐字等價**的變異：

| 變異 | 它把樹變回什麼 |
|---|---|
| **M1** `if (!eprop.failureReported && eprop.declaredDown)` → `if (false)` | **base 分支 `fix/w8-declared-link-failure-sticky` 的行為**：recovery 無條件撤回宣告。lw8b 臂量到的就是這一顆。 |
| **M6** `return srcDpid != 0 && dstDpid != 0;` → `return true;` | **W8-7 的缺陷逐字**：四個端點都收 dpid 0。 |
| **M8** `if (!found.empty())` → `if (false)` | **W8-4 裁決指名的那一顆**：掃到了，但不說。 |

⚠️ **不是「把整個修法從樹上拿掉再跑」**：本單新增的單元測試呼叫
`applyReportedLinkRecovery`／`getEdgeFailureReported`／`mininetLinkInterfaces`，這些在 base 分支上
**不存在，編不過**，而編不過**不是**工單要的那種紅（🔴 編不過在本單的閘門裡算 SURVIVOR，
不算 skip——見 §3 的自我揭露）。
🔵 **一個例外**：`DeclaredLinkFailureWireTest.ARyuRestartDoesNotWithdrawAnInjectedLinkFailure`
只用 base 分支上就有的端點（`inject_link_failure` → `link_recovery_detected` → `get_graph_data`），
**單獨放到 base 分支上是編得過、會紅的**——但**我沒有真的在 base 上跑它**（要再開一棵樹、再全建一次）。
M1 之下的逐字紅（§1）與那個假設的紅是同一個斷言、同一個原因。

---

## §1 M1：撤回不再需要對得上 ⇒ 逐字紅 🟢 跑過

`src/ndt_core/collection/TopologyAndFlowMonitor.cpp::applyReportedLinkRecovery` 的
`if (!eprop.failureReported && eprop.declaredDown)` 改成 `if (false)`。

**走真的 HTTP 端點的那個（lw8b 那一幕的離線重演）**：

```
/…/tests/test_HttpSessionRouting.cpp:1068: Failure
Value of: fwd.value("is_up", true)
  Actual: true
Expected: false
a bare rediscovery ended an injection: restarting the control plane withdrew a declaration nothing ever reported broken, and on MININET the tc netem that accompanies /ndt/inject_link_failure would still be attached (B-6, W8b)
/…/tests/test_HttpSessionRouting.cpp:1072: Failure
Value of: rev.value("is_up", true)
  Actual: true
Expected: false
the reverse direction was withdrawn
/…/tests/test_HttpSessionRouting.cpp:1073: Failure
Expected equality of these values:
  fwd.value("down_reason", "")
    Which is: "none"
  "declared"
/…/tests/test_HttpSessionRouting.cpp:1080: Failure
Value of: body.value("declaration_retained", false)
  Actual: false
Expected: true
the recovery was declined and the reply did not say so: {"status":"link recovery processed"}
[  FAILED  ] DeclaredLinkFailureWireTest.ARyuRestartDoesNotWithdrawAnInjectedLinkFailure (2 ms)
```

🔑 **最後那一段是這張單的重點**：未修的樹回的是逐字的
`{"status":"link recovery processed"}`——**200，而且說「處理好了」**，同時邊被撤回。
修好之後同一個呼叫回 `declaration_retained: true` 並把 caller 指向 `/ndt/inject_link_recovery`。

**狀態機那一層**：

```
/…/tests/test_PollDoesNotResurrect.cpp:1154: Failure
Expected equality of these values:
  m_monitor->applyReportedLinkRecovery(fwd())
    Which is: 4-byte object <00-00 00-00>
  LinkRecoveryOutcome::Retained
    Which is: 4-byte object <01-00 00-00>
/…/tests/test_PollDoesNotResurrect.cpp:1156: Failure
Value of: m_monitor->getEdgeDeclaredDown(fwd())
  Actual: false
Expected: true
a bare rediscovery withdrew a declaration nothing ever reported broken; a control plane restart therefore ends every standing injection in the fabric, and for an injection made through /ndt/inject_link_failure the netem stays attached (B-6, W8b)
/…/tests/test_PollDoesNotResurrect.cpp:1160: Failure
Value of: edgeIsUp(fwd())
  Actual: true
Expected: false
the edge was marked up while its declaration still stands, which publishes is_up: true with down_reason: declared
[  FAILED  ] DeclaredLinkFailureTest.ARediscoveryDoesNotWithdrawADeclarationNothingReportedBroken (17 ms)
```

## §1b M6：dpid 0 放行 ⇒ 逐字紅 🟢 跑過

`src/ndt_core/http/HttpSession.cpp` 的 `namesTwoSwitches` 改成 `return true;`。

```
/…/tests/test_HttpSessionRouting.cpp:1148: Failure
Expected equality of these values:
  res.result_int()
    Which is: 200
  400u
    Which is: 400
/ndt/link_failure_detected accepted a link addressed by dpid 0. Without a refusal it resolves to an arbitrary host edge of the other switch: {"status":"link failure processed","down_reason":"declared","until":"/ndt/link_recovery_detected"}
```

🔑 **`200 {"status":"link failure processed","down_reason":"declared"}` 就是缺陷本身**：
呼叫端寫了 `dst_dpid: 0`，端點挑了「s1 的第一條 host 邊」宣告下去，然後回報成功。
同一顆之下另一個案子確認**它真的動了那條邊**：

```
[ RUN      ] DeclaredLinkFailureWireTest.ARefusedHostEdgeRequestLeavesTheHostEdgeAlone
/…/tests/test_HttpSessionRouting.cpp:1174: Failure
Expected equality of these values:
  peer.send(http::verb::post, endpoint, kHostEdgeBody).result_int()
    Which is: 200
  400u
```

## §1c M8：啟動掃到了但不說 ⇒ 逐字紅 🟢 跑過

`warnAboutResidualNetem` 的 `if (!found.empty())` 改成 `if (false)`。
**回傳值不變（`found` 仍然是那兩個介面），變的只有那一行 WARN**——這正是裁決要的那顆變異。

```
/…/tests/test_NetemLinkFault.cpp:595: Failure
Expected: (text.find("s1-eth1")) != (std::string::npos), actual: 18446744073709551615 vs 18446744073709551615
the startup sweep found residual netem and said nothing an operator could act on. A kernel restart forgets standing declarations and the tc qdisc that accompanied one outlives it, so with no warning the graph's clean down_reason is the only thing anybody reads (B-6, W8-4). Log was:

/…/tests/test_NetemLinkFault.cpp:601: Failure
Expected: (text.find("s5-eth1")) != (std::string::npos), actual: 18446744073709551615 vs 18446744073709551615
the warning named one end of the cut and not the other:
[  FAILED  ] ResidualNetemSweepTest.ResidualNetemIsNamedInOneWarningAtStartup (0 ms)
```

**三顆做完之後的還原**（同一個腳本自己驗的，不是目測）：

```
############ restore + rebuild
rebuilt ok
TopologyAndFlowMonitor.cpp restored byte-identically: sha256 2ccfebb1abf0f443
HttpSession.cpp restored byte-identically: sha256 cba3cad6cff8c8a2
[==========] 37 tests from 3 test suites ran. (287 ms total)
[  PASSED  ] 37 tests.
```

---

## §2 新閘門 `tests/shell/mutate_withdrawal_needs_observed_failure.sh` 🟢 跑過

**2026-09-07 02:36–02:51，`guarded_build: exit 0`：**

```
=== verdict ===
  18 mutations, 0 survived
  3 widenings, 0 wrongly caught
  W8b gate: a withdrawal cannot be unpaired from a reported break by any of five routes,
  dpid 0 cannot be let back in at the helper or at one door, the startup sweep cannot go
  silent or blind, and eight ways of over-correcting past any of the three are caught too.
```

```
=== restore ===
  all 2 file(s) byte-identical to the pre-run snapshot
  rebuilt from the restored tree
  suite green again after restore
  test binary sha unchanged: 0971e468aad0f43c
```

工單指名的三顆，逐字：

```
=== M1. the defect verbatim: any recovery report withdraws any declaration (= w8 branch) ===
  expect red: DeclaredLinkFailureTest.ARediscoveryDoesNotWithdrawADeclarationNothingReportedBroken DeclaredLinkFailureTest.ARecoveryReportIsSpentAndDoesNotWithdrawTheNextDeclaration DeclaredLinkFailureTest.TheInjectionWithdrawalAlsoSpendsAStandingReport DeclaredLinkFailureWireTest.ARyuRestartDoesNotWithdrawAnInjectedLinkFailure
  ✅ caught  red: DeclaredLinkFailureTest.ARediscoveryDoesNotWithdrawADeclarationNothingReportedBroken DeclaredLinkFailureTest.ARecoveryReportIsSpentAndDoesNotWithdrawTheNextDeclaration DeclaredLinkFailureTest.TheInjectionWithdrawalAlsoSpendsAStandingReport DeclaredLinkFailureWireTest.ARyuRestartDoesNotWithdrawAnInjectedLinkFailure

=== M6. dpid 0 is let through, so a host edge is addressable after all ===
  ✅ caught  red: DeclaredLinkFailureWireTest.EveryLinkEndpointRefusesAHostEdgeAddressedByDpidZero DeclaredLinkFailureWireTest.ARefusedHostEdgeRequestLeavesTheHostEdgeAlone

=== M8. the startup sweep finds the netem and says nothing ===
  ✅ caught  red: ResidualNetemSweepTest.ResidualNetemIsNamedInOneWarningAtStartup
```

**方向 2（修過頭）八顆全被抓到**——這是這支閘門存在的理由：

```
=== M11. no recovery report ever withdraws anything ===
  ✅ caught  red: … AReportedFailureIsWithdrawnByItsMatchingRecovery … ARecoveryStillRaisesAnEdgeNobodyDeclaredDown … AReportedFailureIsStillWithdrawnByItsOwnRecovery
=== M12. the pairing rule also refuses edges nobody declared down ===
  ✅ caught  red: DeclaredLinkFailureTest.ARecoveryStillRaisesAnEdgeNobodyDeclaredDown
=== M13. the injection withdrawal needs the control plane's agreement too ===
  ✅ caught  red: DeclaredLinkFailureTest.TheInjectionWithdrawalNeedsNoReportToPairWith DeclaredLinkFailureWireTest.InjectRecoveryStillWithdrawsAfterARefusedRediscovery
=== M14. the observation writer manufactures a control-plane failure report ===
  ✅ caught  red: DeclaredLinkFailureTest.ObservationWritersNeitherSetNorClearTheFailureReport
=== M15. the dpid guard refuses every link, not just dpid 0 ===
  ✅ caught  red: DeclaredLinkFailureWireTest.TheDpidZeroRefusalDoesNotTouchOrdinarySwitchToSwitchLinks
=== M16. the startup sweep reads host-facing interfaces too ===
  ✅ caught  red: ResidualNetemSweepTest.TheSweepCoversBothEndsOfEverySwitchToSwitchLinkAndNothingElse
=== M17. the startup sweep clears the netem it finds ===
  ✅ caught  red: ResidualNetemSweepTest.TheSweepNeverRunsACommandThatChangesTheTree
=== M18. the startup sweep runs tc on a non-MININET deployment ===
  ✅ caught  red: ResidualNetemSweepTest.ATestbedDeploymentRunsNoTcAtAll
```

三個對照全部留綠（W1 一句註解、W2 拒絕訊息改寫、W3 配對規則寫成等價式）。

---

## §3 🔴 自我揭露：這支閘門第一次跑是 `1 survived`，而那是**我的錯，不是它的**

02:19–02:34 的第一次跑：

```
=== M16. the startup sweep reads host-facing interfaces too ===
  🔴 SURVIVED (mutant does not compile) -- the suite never ran
=== verdict ===
  18 mutations, 1 survived
```

原因：M16 原本只把條件裡的 `(*m_graph)[dst].vertexType != VertexType::SWITCH ||` 拿掉，
於是 `const auto dst = ...` 變成未使用的變數，而這棵樹是 `-Werror` ⇒ **mutant 編不過**。
閘門把「編不過」記成 **SURVIVOR 而不是 skip**（腳本檔頭那條紅字規矩），所以它**抓到了我自己**：
一顆編不過的變異什麼都沒證明。修法是讓 anchor 連 `dst` 那一行一起換掉，02:36 重跑整支 ⇒
`18 mutations, 0 survived`。**§2 引用的是那一次完整的跑，不是拼起來的。**

---

## §4 base 那支閘門（W8）在我改完之後仍然 0 survived 🟢 跑過

我動了 `clearEdgeDeclaredDown`，所以 `mutate_declared_link_failure_survives_poll.sh` 的
`declared-clear` anchor 不再唯一（`eprop.declaredDown = false;` 在 W8b 之後出現兩次），
而它的 M3 期望紅名單裡那個 wire 案子走的端點也換了人（`clearEdgeDeclaredDown` 現在只有
`/ndt/inject_link_recovery` 到得了）。兩處都改了，重跑：

```
=== M3. recovery does not withdraw the declaration ===
  ✅ caught  red: DeclaredLinkFailureTest.ADeclaredRecoveryLetsThePollRaiseTheEdgeAgain DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery DeclaredLinkFailureWireTest.InjectRecoveryOutsideMininetWithdrawsTheDeclaration
=== verdict ===
  8 mutations, 0 survived
  3 widenings, 0 wrongly caught
```

baseline 那一行也一起記下來，因為它證明我的新案子沒有把舊 suite 變紅：
`ok       baseline green (29 cases in DeclaredLinkFailureTest.*:DeclaredLinkFailureWireTest.*)`
（W8 交付時是 9＋6＝15 個；本單把這兩個 suite 加到 17＋12＝**29**，另外新開
`ResidualNetemSweepTest` 8 個 ⇒ **本單新增 22 個 gtest 案子**。）

---

## §5 補一顆（2026-09-07，E-22 ／ `WAKEUP.md` §3-52）：M19、M20 與新的對照 W4 🟢 跑過

同一支閘門 **18 → 20 變異、3 → 4 對照**，整支重跑（不是補跑那兩顆）：

```
  ok       baseline green (40 cases in DeclaredLinkFailureTest.*:DeclaredLinkFailureWireTest.*:ResidualNetemSweepTest.*)
  ok       test_routing_strategy sha256 7af2a08a49d7ce21
```

（40 ＝ §4 那次的 37 ＋ 本輪新增的 3。）

```
=== M19. the recovery log moves back in front of the outcome (3-52 verbatim) ===
  ✅ caught  red: DeclaredLinkFailureWireTest.ADeclinedRecoveryIsNotLoggedAsARecovery DeclaredLinkFailureWireTest.ARecoveryForAnEdgeTheGraphDoesNotHoldSaysThatInstead

=== M20. the three outcomes are one sentence again, just logged later ===
  ✅ caught  red: DeclaredLinkFailureWireTest.ADeclinedRecoveryIsNotLoggedAsARecovery DeclaredLinkFailureWireTest.AnAppliedRecoveryLogsThatTheDeclarationWentAway DeclaredLinkFailureWireTest.ARecoveryForAnEdgeTheGraphDoesNotHoldSaysThatInstead

=== W4. the declined recovery sentence is reworded (it still says the declaration was retained) (MUST stay green) ===
  ✅ survived -- behaviour unchanged, so the catches above are about behaviour

=== restore ===
  all 2 file(s) byte-identical to the pre-run snapshot
  rebuilt from the restored tree
  suite green again after restore
  test binary sha unchanged: 7af2a08a49d7ce21

=== verdict ===
  20 mutations, 0 survived
  4 widenings, 0 wrongly caught
```

### §5.1 M19 的紅，逐字（另跑一次同樣的 anchor 把 gtest 訊息抓下來）

閘門本身只印「哪一格紅了」，所以這兩段是**另外跑一次**同樣的兩個 anchor 抓來的
（同一支 guard、同一顆 binary、跑完 `restored: BYTE-IDENTICAL` 且 40 個案子全綠；
腳本在 session scratchpad，**不進版控**）。

```
/…/tests/test_HttpSessionRouting.cpp:1219: Failure
Expected equality of these values:
  logged.find("link recovered on")
    Which is: 147
  std::string::npos
    Which is: 18446744073709551615
a recovery report the pairing rule DECLINED logged the sentence an applied one logs, so kernel.log says the injection ended while the graph still holds it down. Measured verbatim on arm lw8b2 at 04:33:37.198 (3-52). Log was:
[…] [info] [HttpSession.cpp:646] Handle Link Recovery
[…] [info] [HttpSession.cpp:669] link recovered on 1:1 -> 5:1
[…] [warning] [TopologyAndFlowMonitor.cpp:3147] the control plane reports link 1 -> 5 recovered, but nothing ever reported it broken and a link failure is declared for it, so the declaration stands and the edge is left down. POST /ndt/inject_link_recovery to withdraw it
[…] [warning] [TopologyAndFlowMonitor.cpp:3147] the control plane reports link 5 -> 1 recovered, …
[…] [warning] [HttpSession.cpp:619] link recovery declined on 1:1 -> 5:1: a link failure is declared here and nothing ever reported this link broken, so the declaration was retained and the link is still down. POST /ndt/inject_link_recovery to withdraw it

[  FAILED  ] DeclaredLinkFailureWireTest.ADeclinedRecoveryIsNotLoggedAsARecovery (3 ms)
```

🔴 **這一段紅本身就是 §3-52 的樣子**：mutant 的 log 裡**兩行互相矛盾**——
`link recovered on 1:1 -> 5:1`（INFO，說撤回了）緊接著三行說「沒撤、宣告還在」。
缺陷從來不是「什麼都沒說」，是**宣稱結果的那一行說錯了，而且它在最前面**。

同一顆 mutant 的第二格：

```
/…/tests/test_HttpSessionRouting.cpp:1275: Failure
Expected equality of these values:
  logged.find("link recovered on")
    Which is: 147
  std::string::npos
    Which is: 18446744073709551615
a report naming a link this topology does not hold was logged as a recovery:
[…] [info] [HttpSession.cpp:669] link recovered on 1:1 -> 9:1

/…/tests/test_HttpSessionRouting.cpp:1278: Failure
Expected: (logged.find("no such edge")) != (std::string::npos), actual: 18446744073709551615 vs 18446744073709551615
the 404 went out with nothing in the log to say the caller had named a link that is not in the graph:
[  FAILED  ] DeclaredLinkFailureWireTest.ARecoveryForAnEdgeTheGraphDoesNotHoldSaysThatInstead (0 ms)
```

### §5.2 M20 的紅，逐字（位置對、字不對）

```
/…/tests/test_HttpSessionRouting.cpp:1224: Failure
Expected: (logged.find("declaration was retained")) != (std::string::npos), actual: 18446744073709551615 vs 18446744073709551615
the endpoint declined the report and said so only in the reply body, which is not what anyone reads afterwards:
[…] [info] [HttpSession.cpp:612] link recovered on 1:1 -> 5:1

/…/tests/test_HttpSessionRouting.cpp:1247: Failure
Expected: (logged.find("was withdrawn")) != (std::string::npos), actual: 18446744073709551615 vs 18446744073709551615
the recovery that DID withdraw a declaration did not say so, so an applied report and a declined one are once again told apart only by the reply body:
[…] [info] [HttpSession.cpp:612] link recovered on 1:1 -> 5:1

 3 FAILED TESTS
```

⚠️ **M20 是這一顆修法最容易只做一半的地方**：呼叫點搬對了、每種結果各有一個呼叫點、
也真的印在判定之後——**結構性質全部成立**，只有字沒改。
所以只有讀「內容」的案子分得出 M20 與修法；讀位置或讀結構的案子在 M20 下全綠。

### §5.3 W4 是這三格的對照

W4 把被拒那句改寫（`the link is still down. POST /ndt/inject_link_recovery to withdraw it`
→ `the link stays down. Use POST /ndt/inject_link_recovery to take the injection back`），
保留 `declaration was retained` ⇒ **必須留綠，而且留綠了**。
沒有它，這三格就可能是在釘一句散文，下一個想把訊息寫好的人得先改測試。
