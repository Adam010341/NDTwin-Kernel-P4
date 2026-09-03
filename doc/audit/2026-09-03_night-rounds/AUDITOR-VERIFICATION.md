# Auditor verification of the morning fix branches

2026-09-03, 10:30–10:50，＋12:2x 的解糾纏後重驗。[Co-developed with claude code -- Adam]

Each fix agent reported its own gate. This file records what the **auditor re-ran
independently**, in a throwaway worktree of the branch, without the agent present. An agent's
own "0 survived" is a claim; the rows below are observations.

Method for every row: `git worktree add --detach <scratch> <branch>` (the shared worktree's
HEAD is never moved), run the gate there, read the exit code, keep the named-test detail.

| Branch | Re-run | Observed |
|---|---|---|
| `fix/deterministic-path-tiebreak` (`966734be`) | `tests/shell/mutate_path_determinism.sh` | baseline 10 tests green; **5 mutations, 0 survived**, exit 0; each mutant reddened *the test the script names* (M1→`test_every_host_pair_is_insertion_order_independent`, M2→`test_topology_manager_all_pairs_is_stable`, M3→`test_no_switch_on_a_shortest_path_is_left_dark`, M4→`test_advertised_hops_match_each_switch_own_next_hop`, M5→`test_same_answer_under_different_hash_seeds`); baseline byte-identical afterwards |
| `fix/ports-that-block-restart` (`62a3aea8`) | `tests/shell/mutate_ports_that_block_restart.sh` | baseline 18 checks, 0 failed; **9 mutations, 0 survived**; `ports.sh` and `ndt` byte-identical afterwards |
| `fix/topology-load-fails-before-listen` (`896f6674`) | `tests/python/test_make_topology.py`, plus the generator both ways | 29 tests OK as a script and under `unittest` discovery; `--hosts 300` → rc=1 naming the 254-address ceiling; control `--hosts 8` → rc=0, still emits a full model |
| `fix/p4-priority-not-silently-dropped` (`9d64a36a`) | `tests/shell/mutate_p4_priority_refusal.sh` | **7 mutations, 0 survived**, exit 0; each caught by the test the script names, including the four that must NOT fire (the kernel's priority-less delete, `makeModifyJob`'s absent-priority 0, the -1 non-strict sentinel, a five-tuple match); `api_routes.py` byte-identical afterwards |

## 12:2x — 解糾纏後的重驗（新 sha，不是上面那批）

`fix/ports-that-block-restart` 與 `fix/p4-priority-not-silently-dropped` 原本指向同一顆
`9d64a36a`。解開的做法是：ports 那三顆 rebase 到 trunk，p4 那顆單獨 cherry-pick 到 trunk。
**rebase／cherry-pick 產生的是沒有人驗過的新 commit**，所以兩支的閘門在新 sha 上重跑：

| Branch | 新 sha | Re-run | Observed |
|---|---|---|---|
| `fix/ports-that-block-restart` | `2fe70075` | `tests/shell/mutate_ports_that_block_restart.sh` | baseline `Ran 18 checks, 0 failed`；**9 mutations, 0 survived**（M1…M9 逐一寫出是哪一個 check 變紅）；`baseline byte-identical: yes (ports.sh and ndt)` |
| `fix/p4-priority-not-silently-dropped` | `4c5a92da` | `tests/shell/mutate_p4_priority_refusal.sh` | **7 mutations, 0 survived**, exit 0；四個「必須不觸發」的仍然不觸發；`api_routes.py` byte-identical |

另外補了一顆 `2fe70075`：`tests/shell/{mutate_,test_}ports_that_block_restart.sh` 從 `100644`
改成 `100755`。兩支都帶 `#!/usr/bin/env bash`，而 `tests/shell/` 底下每一支被直接呼叫的同類都是
`100755`。**變異 harness 遮住了這件事**——它用 `bash "$TEST"` 呼叫，所以閘門一直是綠的，而
`./tests/shell/test_ports_that_block_restart.sh` 這條路徑根本跑不起來。改完後直接呼叫實測
`Ran 18 checks, 0 failed`。`tools/test_workflow/ports.sh` 刻意留在 `100644`：`ndt` 是 source 它，
mutant builder 也只 `chmod +x` 旁邊的 `ndt`。

🔴 **一個 setsid 的坑順手記著**：`setsid <cmd> > log` 在背景執行時會**立刻返回 rc=0**（setsid fork
後父行程就退了），工具因此回報「completed, exit code 0」，而閘門其實才跑到 M3。**那個 rc 是 setsid
的，不是閘門的。** 判定一律讀 log 的結尾行，不要讀 exit code。

## 12:4x — 我複驗 `FINDINGS-COVERAGE.md` 推翻的三件事

那張總帳是一支 subagent 產的。它推翻了三件既有記載，而推翻會改變裁決 ⇒ 三件我都自己重跑了一次。

| 它的宣稱 | 我怎麼查 | 結果 |
|---|---|---|
| `fix/g6-ndt-apps-liveness` **沒有**修 viz 的孤兒（#6／#48） | 讀那支分支上的 `app_spawn` 與 `pid_is_app` | ✅ **成立**。`app_spawn` 仍是 `( cd "$dir" && exec nohup "$@" … ) &`——**沒有 `setsid`、沒有自己的 process group**，stop 仍只對單一 pid 送 TERM。而 `pid_is_app` 比對的是 argv 元素等於 `network_traffic_visualizer.sh`；那個腳本 exec 掉 java 之後 argv 裡就沒有它了（09-02 存檔記到兩個行程的 comm 都是 `java`）⇒ 那個假陰性原封不動。g6 改善的是**存活回報**，不是**停止**。 |
| `fix/telemetry-health-visible` × `fix/flow-rate-denominator` 在 `FlowLinkUsageCollector.hpp` 硬衝突 | `git merge-tree --write-tree` | ✅ **成立**，`CONFLICT (content)` 在 `.hpp`；`.cpp` 兩邊自動合得起來。**沒有任何審查文件提過這個衝突。** |
| `fix/d15` × `fix/b5` 只衝 `tests/CMakeLists.txt`，`6ad6811b` 預告的 `DeviceConfigurationAndPowerManager.cpp` 文字衝突不存在 | 同上 | ✅ **成立**。唯一 `CONFLICT` 是 `tests/CMakeLists.txt`；`DeviceConfigurationAndPowerManager.{hpp,cpp}` 兩個都 `Auto-merging` 成功。 |

順帶自己驗的兩項：`fix/ports-that-block-restart` × `fix/p4-priority-not-silently-dropped` 現在 **乾淨合併、無衝突**（解糾纏的驗收）；`refs/heads/` 底下 33 支 `fix*` 分支裡**未併的是 13 支**。

🔑 **而我在 `t8-t10-fixes` 上先問錯了問題。** 我用 `git merge-base --is-ancestor t8-t10-fixes trunk` 得到「否」，差點把總帳的「它已經在 trunk 上」記成誤判。正確的工具是 `git cherry -v trunk t8-t10-fixes`——**10 顆 commit 全部標 `-`**，也就是 trunk 已經有每一顆的等價 patch（它是被 cherry-pick／rebase 進去的，所以血緣說否而內容說是）。
**`--is-ancestor` 問的是「這顆 commit 在不在歷史裡」，`git cherry` 問的是「這份工作在不在 trunk 上」。判斷一支分支還要不要留，要問後者。**

## 12:5x — `fix/ndt-sudo-surface`（finding #7），auditor 重跑

| Re-run | Observed |
|---|---|
| `tests/shell/mutate_ndt_sudo_surface.sh`，在 `git worktree add --detach` 出來的乾淨樹裡 | baseline `Ran 33 checks, 0 failed`；**14 mutations, 0 survived**；`baseline byte-identical: yes (sudo_surface.sh and ndt)`。M1–M10 各自指名一條變紅的 check；**N1–N4 是反向控制**——四種「什麼都拒絕」的寫法，它們通得過全部十條 M，只有 control 案例抓得到。少了 N1–N4，這道閘門會替一個永遠起不了 fabric 的 `ndt` 背書 |
| `git merge-tree --write-tree` 對三支同樣動 `ndt` 的分支 | 🔴 **與 `fix/ports-that-block-restart` 在 `tools/test_workflow/ndt` 衝突**；vs `fix/g6-ndt-apps-liveness`、`fix/g9-cleanup-no-pkill-f` 乾淨 |
| 這台機器自己的 `sudo -n -l`（唯讀） | 帶著 `(ALL : ALL) ALL`，**證實該分支自己指出的儀器問題**：`sudo -n -l -- <cmd>` 回答的是「這個 user 可不可以跑」，不是「要不要密碼」⇒ 在這台機器上對 NOPASSWD 這個問題**鑑別力為零**。而 `ovs-vsctl`／`mnexec` **在本機的 NOPASSWD 清單裡**，這正是四輪 usertest 看不見 #7 的原因 |
| 網站 repo `174beca` 的 `content/` | 全站 `NOPASSWD` 只有兩行、都只涵蓋 `ndtwin-lab` — **成立**。但分支文件原本寫「沒有任何一頁提到 `ovs-vsctl`／`mnexec`」，**不成立**：Installation Manual 的 `…/Native-Linux Excution Environment.md:339` 就在教 `sudo ovs-vsctl show`。已在分支上補 `20d834aa` 更正 |

🔑 **那個更正讓 #7 更利，不是更鈍。** 手冊叫讀者跑 `sudo ovs-vsctl show`，讀者當場會成功（互動式 sudo 問密碼），
於是他有充分理由相信 `ovs-vsctl` 在 sudo 下是通的；而 `ndt` 用的是 `sudo -n`。
**縫隙不在「指令沒被提過」，在「互動式可以問密碼、非互動式不能」**——照手冊親手操作的人必然看不見，只咬工具。

## What this does NOT establish

- **The tie-break is not confirmed live.** No fabric was brought up; the eight-bring-up
  reproduction that produced the defect has not been re-run against the fix. The gate proves
  the selector is a pure function of the topology, not that a real bring-up now agrees.
- **`fix/topology-load-fails-before-listen` has an unbuilt C++ half.** `src/main.cpp` and
  `TopologyAndFlowMonitor.{hpp,cpp}` on that branch have never been compiled. The ordering
  claim ("no port is bound when the load fails") has no test, because the test needs the
  binary. Treat the C++ half as a design, not a delivery.
- **No branch in this batch was confirmed against a live fabric.** Every gate above is offline:
  unit level for the Python, script level for the shell. The lab ran test rounds all night, so
  none of these fixes has met real traffic.

## Defect found while verifying

`tests/shell/mutate_ports_that_block_restart.sh` and `tests/shell/test_ports_that_block_restart.sh`
are committed mode `100644`. Invoking them the way every other gate in `tests/shell/` is invoked
fails with `Permission denied`; they only run via an explicit `bash`. `mutate_path_determinism.sh`
on the sibling branch is `100755`. Fix with `git update-index --chmod=+x` before merging.

---

## The two branches whose gates had never been run (11:00-11:30)

Both were built by the auditor in a throwaway worktree, `-j2`, in their own systemd unit.
**Both results contradict the branch author's prediction**, which is the whole reason for
building them.

### `fix/d15-dataplane-kind-race` — compiles, gate **3 of 4**

Build: clean, 98 targets, zero `FAILED:` lines. The author predicted 4/4 PASS.

```
[  PASSED  ] 3 tests.
[  FAILED  ] DataPlaneKindOrderingTest.TheStartupSequenceMainUsesYieldsABmv2Verdict
tests/test_DataPlaneKindOrdering.cpp:202: Value of: m_manager->dataPlaneKindDetermined()
  Actual: false   Expected: true
```

**Diagnosis, verified first-hand** (a Muse Spark agent reached the same conclusion
independently; these are the lines I read myself):

- `src/main.cpp:409` `topologyAndFlowMonitor->start();` … `:432`
  `deviceConfigurationAndPowerManager->start();`
- `DeviceConfigurationAndPowerManager.cpp:165` — `start()` calls `refreshDataPlaneKind()`
- the failing test calls **only** `startMonitor()` (fixture: `m_monitor->start()`), then asserts.
  It never calls `m_manager->start()` — the step in main's sequence that computes the verdict.

⇒ **The fix is not what failed.** The test's *second* assertion, `dataPlaneIsBmv2()`, passed in
the same run — the lazy re-derive works. Only the passive getter is false, and the design says
that is legitimate ("not yet known" ≠ "not bmv2"). The sibling test that passes,
`AVerdictTakenBeforeTheTopologyExistsIsNotCached`, differs only in **assertion order**: it calls
`dataPlaneIsBmv2()` first, which triggers the re-derive.

🔴 **And the repair is coupled to another branch.** Making the test do what its name says means
calling `m_manager->start()`. On this branch that spawns **three** threads
(`m_pingThread`, `m_statusUpdateThread`, `m_openflowTablesUpdateThread`) while `stop()` joins
**two** — the B-5 defect, still present here; `fix/b5-kernel-shutdown` is the branch that adds the
third join. A test that starts the manager would therefore `std::terminate` on teardown.
⇒ **D15's gate cannot be closed on D15's own branch. B-5 has to land first.**

I did **not** edit the test to make it pass. A test edited until it is green proves nothing.

### `fix/telemetry-health-visible` — **did not compile**

```
tests/test_TelemetryHealth.cpp:19:19: error: 'FlowLinkUsageCollector' does not name a type
```

Cause: the class is declared inside `namespace sflow`
(`include/ndt_core/collection/FlowLinkUsageCollector.hpp:30`), and every sibling test that
compiles qualifies it (`test_SFlowParsing.cpp:140`). The rescued file did not.
Two-line qualification applied by the auditor (`b7aad224`), then rebuilt: **it compiles, and the
gate is 17 of 18.**

```
TelemetryHealth.AppDropsAloneMoveTheVerdict
  classifyIngestHealth(true, 900, 0, 100, 1.0)  ->  loss 100/1000 = exactly 0.10
  expected "severe_loss", got "lossy"
```

Bands are `kIngestLossyFraction = 0.01` / `kIngestSevereLossFraction = 0.10`
(`FlowLinkUsageCollector.hpp:373,375`), applied strictly (`lossFraction > …`, `.cpp:1780`).
The failing case is the **only** one that lands on the edge — `TheBandsAreOrderedAndDistinct`
probes 0.5%, 5%, 50%. ⇒ **no green test constrains the boundary**, and `>` → `>=` would break
nothing currently passing. The test's own comment predicted the shape — "an unexercised path is
where a wrong constant survives" — without knowing it had caught itself, because it was never run.
Not decided here: it is a published `status` value, so it belongs to whoever owns the branch.

This is the same file that broke another agent's build in the shared tree at 84/86 and forced it
to hand-link its gate binary. One uncompiled file cost two other rounds real time.
