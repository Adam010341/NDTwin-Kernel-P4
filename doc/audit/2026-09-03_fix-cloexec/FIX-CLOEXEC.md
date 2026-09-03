# Fix: the kernel's listening sockets must not survive an exec

[Co-developed with claude code -- Adam]

Branch `fix/cloexec-listening-sockets`, off `integrate/2026-09-03-auditor-merge` at `5c64d432`.
Not pushed.

Defect: `doc/audit/2026-09-03_night-rounds/FINDINGS-ALL.md` #47, measured in
`round3-restart-concurrency/03_port_inherited_by_forked_children.log`. **Cited, not re-derived**,
and re-measured here against a binary built from the same commit.
---

## 0. Where the raw evidence is, and why it is not in this commit

`.gitignore:74` (`doc/audit/**/raw*/*`) and `tools/githooks/pre-commit` between them keep raw out of
every branch but `audit-raw`, so **only this write-up is committed here.** The 128 raw files it
cites -- four experiment logs, four directories of per-kernel stdout, the gate run, the fabric
bring-up and teardown, and the two completeness scans -- are on disk at:

```
/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-03_fix-cloexec/raw/
```

which is where every other round's raw lives (`round3-restart-concurrency/raw/` is untracked there
too). They were produced in the branch worktree and copied there because a scratchpad directory is
not a safe home for evidence: `scratchpad/wt-before` -- the BEFORE binary's whole worktree -- was
deleted from under this run while the machine was being freed of disk. Every claim below names the
file it rests on; nothing here is derived from a file that is not in that directory.

---

## 1. One sentence

The kernel created both of its listening sockets without `SOCK_CLOEXEC`, so every `sh` and `curl`
it forked through `popen()` inherited them and kept `:8000` and `:6343` bound for ~2 s after the
kernel itself was gone -- and the restart that then failed blamed a second kernel that did not
exist.

---

## 2. Before and after

### 2.1 What was wrong, at the descriptor

| | before | after |
|---|---|---|
| sFlow UDP socket | `::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)` | `utils::cloexecSocket(...)` -> `SOCK_DGRAM \| SOCK_CLOEXEC` |
| API acceptor | `make_unique<tcp::acceptor>(ioc, {v4(), 8000})` | `openApiAcceptor()`: same construction, then `FD_CLOEXEC` on the native handle |
| accepted connections | whatever `::accept()` returned | `adoptAcceptedSocket()`: `FD_CLOEXEC` before the session gets it |
| `execArgv`'s child | inherited every open descriptor | `close_range(3, ~0U, 0)` after the `dup2`, before `execvp` |

Boost.Asio 1.83 is the reason the acceptor needs a second line rather than a flag:
`/usr/include/boost/asio/detail/impl/socket_ops.ipp:1830` calls `::socket(af, type, protocol)` and
line 101 calls `::accept(...)` -- not `accept4(..., SOCK_CLOEXEC)`. Confirmed in the linked binary:
it imports `accept`, never `accept4`.

`SOCK_CLOEXEC` is passed to `::socket()` rather than set with a following `fcntl()` on purpose.
Between those two calls another thread can fork -- and this kernel forks from its poll threads --
so the two-call form leaves a window the one-call form does not have.

### 2.2 What was wrong, in the message

The old line, printed without looking at anything:

> `bind() to sFlow port 6343 failed: Address already in use. Another NDTwin kernel is almost
> certainly still running and holding it; ...`

In the six measured failures there was no other kernel. The holder was the dead kernel's own
orphaned `curl`. The message now reports what `/proc` says, and has four separate answers:

| /proc says | message |
|---|---|
| a holder named `ndtwin_kernel` | "One of them is another ndtwin_kernel: stop it before starting this one." |
| holders, none named that | names each pid and comm, then "None of them is a ndtwin_kernel ... A process holding a socket it never opened inherited it across an exec" |
| socket bound, no readable holder | names the uid, then "This is **NOT** evidence that another ndtwin_kernel is running." |
| no socket bound at all | "No socket is bound to UDP port 6343 in /proc right now, so the cause is not visible here" |

**Reconciliation with the earlier observation.** `doc/audit/2026-09-02_manual-usertest/run-04-sonnet/
VERIFICATION.md` line 110 recorded this same message as *honest and specific* -- and it was, because
in that run a second kernel really was holding the port. Round 3 hit the case where it was false.
The fix keeps the first case sayable (row 1 above) and removes the second; a message that could
never name a second kernel would be the opposite error, and `M8` in the gate exists to catch it.

### 2.3 What was measured

Two binaries, **same commit, same compiler, same machine, differing only by this fix**:

| | worktree | sha256 |
|---|---|---|
| BEFORE | `wt-before`, detached at `5c64d432` | `de20d071b5148cd6…47e49224` |
| AFTER | this branch | `12769502b5535e63…5e2b66549` |

Discriminator at the binary level, before a single measurement: the AFTER kernel's dynamic imports
contain `close_range`; the BEFORE kernel's do not. Neither imports `accept4`. (`raw/symbol_attribution.txt`.)

#### The precondition, which the finding does not state and the first run of this experiment found

**The window is exactly as wide as the kernel's longest-lived child, and nothing else.** The first
run, with nothing listening on `:8081`, showed the *unfixed* binary releasing both ports in
**1-2 ms**: every poll `curl` had failed with `Couldn't connect to server` in 0 ms, so at the moment
the kernel was killed it had no living child, and a socket nobody inherited dies with the process.

So the experiment was run in two conditions. `raw/blackhole_8081.py` accepts on `:8081` and never
answers -- which is what `curl -s --max-time 3 http://localhost:8081/p4/switch_state` meets when the
proxy is busy or wedged, and what round 3 was plainly measuring at 02:02 (its `ss` output shows two
`sh` and two `curl` still holding `:8000` a second and a half after the kernel's pid was gone).

#### The four arms

| arm | `:8081` | who holds the ports **while the kernel is alive** | `:8000` freed after | `:6343` freed after | restart at +0.2 s | control at +3.0 s |
|---|---|---|---|---|---|---|
| **before-wedgedproxy** | wedged | `curl`, `sh`, **and** `ndtwin_kernel` -- all on the kernel's own fd | 0.663-0.808 s (mean 0.775) | 1.646-1.789 s (mean **1.757**) | **0/6** | 3/3 |
| **after-wedgedproxy** | wedged | `ndtwin_kernel` **only** | **0.001 s** (8/8) | **0.001 s** (8/8) | **6/6** | 3/3 |
| before-noproxy | refused | `ndtwin_kernel` only (no child alive to inherit) | 0.001-0.002 s | 0.001-0.002 s | 6/6 | 3/3 |
| after-noproxy | refused | `ndtwin_kernel` only | 0.001-0.002 s | 0.001-0.002 s | 6/6 | 3/3 |

n = 8 release measurements per arm, polled every 50 ms from the instant `/proc/<pid>` reported the
kernel gone; 6 restart trials and 3 controls per arm. Raw: `raw/{before,after}-{wedged,no}proxy.log`
and the per-kernel stdout under `raw/<arm>/`.

**One artefact is gone and its measurements are not.** The BEFORE worktree
(`scratchpad/wt-before`, detached at `5c64d432`) and its build were deleted on 2026-09-03 by the
auditor while freeing disk (the machine was at 92%). Every raw log in `raw/` records the binary it
ran by `sha256` in its own header (`de20d071b5148cd6…47e49224`), so the measurements stand as
recorded; what is lost is the ability to re-run *that* build. To reproduce it:
`git worktree add --detach <path> 5c64d432` and build `ndtwin_kernel` under the guard. The rebuilt
binary will not have the same sha -- the worktree path is baked into the debug info -- so a
reproduction should record its own.

The two rows that matter are the first two: **same wedged proxy, same machine, 1.757 s -> 0.001 s
and 0/6 -> 6/6.** The bottom two rows are the condition under which the defect is invisible, and
they are here so that "the fix works" is not read off a comparison that had no defect in it.

What the failed restarts printed, verbatim, six times out of six (`raw/before-wedgedproxy.log`):

> `bind() to sFlow port 6343 failed: Address already in use. Another NDTwin kernel is almost
> certainly still running and holding it` -- while `ss` showed the holders were `curl` and `sh`.

#### On the real stack

`ndt up p4 4` on the P4 plane with the fixed kernel (`raw/fabric_up.log`): 10 bmv2 switches, 12/12
destination paths, `h1 -> 10.0.0.2` forwarding, kernel API up. Ten samples one second apart while
the 1 Hz poll was running (`raw/fabric_holders.log`): `:8000` and `:6343` held by `ndtwin_kernel`
and nothing else, every time. Killing the kernel by the exact pid from `.test_run/pids`
(`raw/fabric_kill_release.log`): both ports free after **0.001 s**. Teardown verified clean
(`raw/fabric_down.log`).

**This live run is corroboration, not the discriminator.** A healthy proxy answers in milliseconds,
so the unfixed binary would look fine here too -- which is the whole point of the wedged-proxy arm.

#### Reconciliation with round 3

Round 3 reported 2.01-2.22 s over 48 trials and 6/6 restart failures. This run reproduces the
mechanism exactly -- `ss` naming `curl` and `sh` as users of the kernel's own fd, 0/6 restarts --
at 0.66-1.79 s rather than 2.0-2.2 s. The difference is the child's remaining `--max-time` at the
instant of the kill, which is not controlled in either run. Round 3's numbers are **not**
contradicted; they are the same phenomenon with a different phase.

---

## 3. Gate evidence

### 3.1 The unit layer

`tests/test_CloseOnExecSockets.cpp`, 16 cases in two suites, all binding **port 0** so the suite is
safe to run while a kernel is up on `:8000`/`:6343` -- and cannot be defeated by one.

| what it asserts | why it is not enough on its own |
|---|---|
| `openSflowSocket(0)` and `openApiAcceptor(ioc, 0)` return a descriptor with `FD_CLOEXEC` | the flag is the mechanism, not the property |
| a real child, `posix_spawn`ed `sh -c 'ls -l /proc/self/fd'`, cannot see either socket's inode | this is the property |
| 🔴 the same probe **can** see a socket deliberately created without the flag | without this control the probe could be looking at nothing and still pass |
| a handler that was actually `start()`ed has a close-on-exec acceptor, and a connection the running server accepted is marked too | a correct helper with no caller is this repository's most-repeated defect |
| `execArgv`'s child cannot see an unmarked descriptor -- **and still has a working stdout** | the second half is what stops "close everything" passing as a fix |
| the four message states, plus the real `/proc` scan against a socket the test itself holds, plus the whole bind-failure path end to end | the pure renderer would pass over a scan that always found nobody |

### 3.2 The mutation gate

`tests/shell/mutate_cloexec_listening_sockets.sh`, run under `tools/build_guard/guarded_build.sh`.
Shape copied from `tests/shell/mutate_logfile_takes_a_path.sh`: `BUILD_DIR` overridable and
defaulting to `build`, every anchor asserted unique **before** anything is touched, an EXIT trap
that restores all four files, and a byte-identity check at the end.

**Verdict, `raw/gate_run.log` (`guarded_build: exit 0`):**

```
  12 mutations, 0 survived
  3 widenings, 0 wrongly caught
  all 4 files byte-identical to the pre-run snapshot
  suite green again after restore
```

Two process notes, because a gate result is only worth what the run behind it was:

- **This is the third run, and the first two are why the numbers can be trusted.** Run 1 refused
  outright on a drifted anchor (below). Run 2 reported `12 mutations, 0 survived / 3 widenings,
  **1 wrongly caught**`: W1, a comment-only change, turned
  `AConnectionAcceptedByTheRunningServerIsCloseOnExec` red. That was not a fix regression -- it was
  **a race in my own test**. The accepted descriptor exists the moment Asio's `::accept()` returns,
  which is strictly before the completion handler that adopts it runs, so a single `isCloseOnExec`
  read on a loaded machine could sample the gap. The test now polls for up to 2 s. A flaky test
  that reddens on a comment is a broken instrument, and reporting run 2 as a pass would have been
  exactly the failure this repository keeps finding elsewhere.
- **Run 2's machine also died under it.** At 17:50 `systemd-oomd` killed the desktop application
  under user-slice pressure while this gate was the heavy load, and the session went with it. The
  guard's `MemoryMax` bounds the build's *own* usage and does nothing about the pressure it puts
  on everything else. Run 3 was executed under the trunk guard's new limits
  (`MemoryHigh=3G`, `MemoryMax=4G`) -- **that is the copy to use, not the one in this branch,
  which is still the 5 G version inherited from the base commit.**

**It refused to render a verdict once, on its first run, and that is the point of the anchor
check.** `raw/gate_anchor_refusal.log`: the `fd-comment` anchor named a doc comment that lives in
`FdHygiene.hpp`, not `FdHygiene.cpp`, so it matched 0 times. The gate printed `REFUSE ... x0` and
exited 2 rather than reporting an unapplied mutation as a catch.

Three families, and the third is the one a gate written only against the first would wave through:

| | mutation | caught by |
|---|---|---|
| **1. the descriptor becomes inheritable again** | M1 `cloexecSocket` drops `SOCK_CLOEXEC`; M2 `setCloseOnExec` returns true without setting it; M3 the sFlow socket goes back to a bare `::socket()`; M4 the acceptor is left as Asio made it | the child-visibility cases |
| **1b. the WIRING** | M5 `start()` builds its own acceptor instead of calling `openApiAcceptor`; M6 `doAccept()` stops adopting what it accepted | only the two cases that drive a *running* server |
| **2. the message claims more than it found** | M7 the old hard-coded sentence returns; M8 the renderer can no longer recognise a real second kernel; M9 the `/proc` walk attributes nothing; M10 the collector stops consulting `/proc` | the four message states and the end-to-end bind-failure case |
| **3. the OVER-BROAD "fix"** | M11 `execArgv` stops closing unmarked descriptors; **M12 closes stdin/stdout/stderr too** | M12 is red only on `ExecArgvChildKeepsTheDescriptorsItNeeds`, which reads the child's stdout |

And three behaviour-preserving changes that **must** survive, or every catch above is measuring
"a file was edited and rebuilt" rather than "the behaviour changed": W1 a comment; W2 the same bit
test written `== FD_CLOEXEC` instead of `!= 0`; W3 the prose around the discriminating phrase in
the second-kernel sentence reworded.

### 3.3 Full suite

`build/bin/test_routing_strategy`: **940 tests from 123 test suites, all green**, including the 16
new ones. No existing case changed behaviour.

---

## 4. Every place this process can start another process

The finding says explicitly that this repository has fixed the observed site and missed the rest of
its class before, and that `grep` will miss some of them. So the list below was built three ways,
and they agree.

### 4.1 How completeness was established

**(a) A comment- and string-stripped source scan, not `grep`.** Raw `grep` over-reports (every doc
comment that mentions `popen()`; every `boost::system::error_code`) and under-reports (a call
reached through a wrapper). `raw/scan_spawn_sites.py` blanks out comments and literals first, keeps
line structure, and then matches the libc entry points **and the two in-tree wrappers**. Output:
`raw/spawn_sites.txt`.

**(b) The object code, which cannot be fooled by a wrapper, a macro, or a name built by string
concatenation.** Any process this binary starts must go through a libc entry point, so the
undefined-symbol list of the linked kernel is an upper bound on the mechanisms in use:

```
$ nm -D --undefined-only build/bin/ndtwin_kernel | awk '{print $NF}' | sed 's/@.*//' | sort -u \
    | grep -E '^(popen|pclose|system|fork|vfork|clone|exec.*|posix_spawn.*|daemon)$'
execvp    fork    pclose    popen    system
```

Three mechanisms, and no others: **no `posix_spawn`, no `execve`, no `vfork`, no `daemon`, no
`clone`.** The same run over every object file attributes each import to a translation unit:

| symbol | translation units that reference it |
|---|---|
| `popen` | `FlowLinkUsageCollector.cpp`, `TopologyAndFlowMonitor.cpp`, `DeviceConfigurationAndPowerManager.cpp`, `OVSPowerStrategy.cpp` |
| `system` | `ApplicationManager.cpp`, `OVSPowerStrategy.cpp`, `P4PowerStrategy.cpp` |
| `fork` + `execvp` | `ApplicationManager.cpp`, `SimulationRequestManager.cpp`, `DeviceConfigurationAndPowerManager.cpp`, `OVSPowerStrategy.cpp`, `HttpRoutingStrategyBase.cpp` |
| `close_range` | the same five as `fork`/`execvp` -- which is the check that the hardening reached **every** inlined copy of `execArgv`, not just the header |
| `accept` | `ControllerAndOtherEventHandler.cpp` (and `accept4` appears nowhere) |

Raw: `raw/symbol_attribution.txt`.

**(c) Boost.Process is not in the tree.** `grep -rniE 'boost/process|boost::process|subprocess'`
over `src/` and `include/` returns nothing, and (b) independently rules it out: it would have to
call `fork`/`posix_spawn` from a TU other than the five above.

**What this does not cover, and I am not claiming it does.** `p4_proxy/` (Python) spawns processes
of its own, and `tools/test_workflow/*.sh` spawns a great many. Neither shares a descriptor table
with the kernel, so neither can inherit the kernel's sockets; they are a different question and are
out of scope here.

### 4.2 The table

32 call sites, three mechanisms. Line numbers are on `fix/cloexec-listening-sockets`.

| # | site | mechanism | reached from |
|---|---|---|---|
| 1 | `include/utils/Utils.hpp:789` (`utils::execCommand`) | `popen` | the wrapper for rows 6-18 |
| 2 | `include/utils/Utils.hpp:676`/`:709` (`utils::execArgv`) | `fork`+`execvp` | the wrapper for rows 19-28 |
| 3 | `include/utils/SSHHelper.hpp:52` (`getPowerReportViaSsh`) | `popen` | `DeviceConfigurationAndPowerManager.cpp:1469`, `:1912`, i.e. **inside the `/ndt/…power` request handler** |
| 4 | `src/ndt_core/collection/FlowLinkUsageCollector.cpp:276` | `popen` | `sudo ovs-vsctl list interface` |
| 5 | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:704` | `popen` | `sudo ovs-vsctl list-br` |
| 6 | `src/ndt_core/power_management/OVSPowerStrategy.cpp:53` | `popen` | OVSDB read |
| 7 | `src/ndt_core/power_management/OVSPowerStrategy.cpp:15` | `std::system` | OVSDB write |
| 8 | `src/ndt_core/power_management/P4PowerStrategy.cpp:28` | `std::system` | P4 port enable/disable |
| 9-11 | `src/ndt_core/application_management/ApplicationManager.cpp:260`, `:286`, `:447` | `std::system` | `exportfs -ra`, NFS reload |
| 12-24 | `execCommand` call sites: `FlowLinkUsageCollector.cpp:2795`; `TopologyAndFlowMonitor.cpp:724`; `DeviceConfigurationAndPowerManager.cpp:298, 396, 570, 1039, 1053, 1178, 1456, 1717, 1731, 1813, 1898` | `popen` via row 1 | the 1 Hz proxy ping, the topology poll, every SNMP read |
| 25-32 | `execArgv` call sites: `ApplicationManager.cpp:318, 331`; `SimulationRequestManager.cpp:179, 256`; `DeviceConfigurationAndPowerManager.cpp:1545, 2019, 2032`; `OVSPowerStrategy.cpp:37, 109`; `HttpRoutingStrategyBase.cpp:85` | `fork`+`execvp` via row 2 | relay power, snmpget, flow-rule dispatch |

**Not one of these call sites was changed.** That is the point of fixing this at the socket: the
descriptor cannot be inherited by any of the 32, nor by the 33rd somebody adds next month. Row 2 is
additionally hardened at the spawn side (`close_range`), which is the only one of the three
mechanisms where that is possible -- glibc's `popen()` and `system()` fork a child this process
never gets to touch.

### 4.3 On `posix_spawn` + `POSIX_SPAWN_CLOEXEC_DEFAULT`

The finding suggests replacing bare `popen()` with `posix_spawn` plus
`POSIX_SPAWN_CLOEXEC_DEFAULT`. **That flag does not exist on Linux.** It is an Apple extension
(`spawn.h` on macOS); glibc 2.39 on this machine has no equivalent flag, and `man 3 posix_spawn`
lists none. The portable-on-Linux equivalent is `posix_spawn_file_actions_addclosefrom_np()`
(glibc >= 2.34), or `close_range()` in a `fork`ed child -- which is what row 2 now does, at one
site instead of ten. Converting the four bare `popen()` sites to `execArgv` is a worthwhile
separate change (it also removes `/bin/sh` from those paths, which is `KNOWN-ISSUES` B-2b/B-4
territory) but it is **not** what closes this finding, and it touches files three other branches
are editing right now. Listed in section 7.

---

## 5. Merge order and conflicts

Measured with `git merge-tree --write-tree --messages`, not predicted.

### 5.1 Into the integration branch: clean

```
$ git merge-tree --write-tree --messages integrate/2026-09-03-auditor-merge 0d5fff9b
07db0fe3d5c3618fd175fdcfd6db6d3b8b0d1687      # exit 0, no conflict messages
```

against `integrate/2026-09-03-auditor-merge` at `431d98a5`, merge-base `5c64d432`. The integration
branch has advanced since this branch was cut, but only in `doc/audit/**`,
`tests/python/test_ovs4_sflow.py`, `tests/shell/mutate_ovs4_has_sflow.sh`,
`tests/shell/test_ovs4_sflow_verify.sh`, `tools/test_workflow/{ndt,ovs_4host_topo.py}` -- **no file
this branch touches**.

### 5.2 Against every other live branch: one conflict, and it is one line

Each local branch was diffed against its merge-base with this one, restricted to the eleven files
this branch changes. Exactly one branch overlaps:

| branch | overlapping file | `merge-tree` |
|---|---|---|
| `fix/poll-does-not-resurrect` | `tests/CMakeLists.txt` | **CONFLICT (content)**, exit 1 |
| every other branch | none | not applicable |

The conflict is textual and trivial: both branches append a new test file to the end of the same
`add_executable(test_routing_strategy ...)` source list.

- it adds `test_PollDoesNotResurrect.cpp` (FINDINGS #46/#35/#36)
- this one adds `test_CloseOnExecSockets.cpp` (FINDINGS #47)

**Resolution: keep both, in either order.** They are two independent entries in a list; there is no
semantic interaction, and neither test touches the other's code. Whichever branch merges second
resolves it by taking both hunks.

### 5.3 Recommended order

Merge order between these two does not matter. Merging this branch **before**
`fix/poll-does-not-resurrect` means the conflict is resolved once, in that branch, by someone who
already has to touch the same list; merging it after costs the same one-line resolution here. No
other ordering constraint exists: `utils/FdHygiene.{hpp,cpp}` are new files with no other
consumers, and nothing else on any branch calls `openSflowSocket`, `openApiAcceptor`,
`adoptAcceptedSocket` or `boundPort`.

---

## 6. Rollback

The change is additive: two new files, and edits at five call sites. Nothing was deleted, no
signature lost a caller, and `start()`'s new parameter has a default of `NDT_PORT`, so
`main.cpp:459`'s `handler->start()` compiles and behaves exactly as before.

**Whole-branch revert.** `git revert -m 1 <merge>` if merged, or simply do not merge. Nothing else
on the integration branch depends on `utils/FdHygiene.hpp`.

**Partial rollback, in the order least likely to be wanted first.**

| if this misbehaves | revert this alone | what you lose | what still works |
|---|---|---|---|
| a child needs an inherited descriptor | `include/utils/Utils.hpp`: drop `close_range(3, ~0U, 0)` from `execArgv`'s child | belt-and-braces only | both listening sockets stay close-on-exec; the finding stays fixed |
| the /proc scan is too slow, or noisy in a container | `FdHygiene.cpp`: make `findPortOwnership()` `return {}` | the message degrades to "no socket is bound … not visible here" -- which is still not a false accusation | the sockets stay close-on-exec |
| the acceptor must be inheritable for something | `ControllerAndOtherEventHandler.cpp`: drop the `setCloseOnExec` call in `openApiAcceptor` | `:8000` strands again | `:6343` stays fixed |

The scan runs **only on the failure path** -- one `bind()` that returned `EADDRINUSE`, once, on a
process that is about to exit. It is not on any hot path, and there is no polling loop that reaches
it.

**What a rollback cannot restore, and should not:** the old sentence. If any operator runbook is
keyed on the literal string "Another NDTwin kernel is almost certainly still running", it is keyed
on an assertion that was measured false 6 times out of 6. `grep` over the repo finds no script or
test that matches on it -- only this branch's own gate, and three `doc/audit` records of having
seen it.

---

## 7. Not handled

**Descriptors this change does not mark, and why each is a smaller problem than the two it does.**
Established by the same object-code scan, not by reading: `socket` is referenced by exactly three
production translation units.

1. `LLMAgent.cpp` -- the outbound HTTPS client socket in `utils::httpsPost` (Boost.Beast, so again
   a bare `::socket()`). A `curl` forked while an LLM request is in flight inherits it. It is a
   *client* socket: nothing binds a port, so it cannot block a restart. It can hold a TCP
   connection to the LLM endpoint open past the kernel's death. **Not fixed here.**
2. `ControllerAndOtherEventHandler::stop()`'s "poke" socket -- one client connection to loopback,
   during shutdown, closed immediately. **Not fixed here.**
3. Non-socket descriptors: the spdlog file sink opened by `--logfile`, and the `pipe()` inside
   `execCommand`/`execArgv`. The log file is inherited by children; it cannot block a port, but it
   does hold an unlinked file's blocks if the log is rotated. **Not fixed here.** `execArgv`'s
   children are now covered by `close_range`; `popen`'s are not, and cannot be without replacing
   `popen`.

**Not attempted.**

- **Converting the four bare `popen()` sites and five `std::system()` sites to `execArgv`.** It is
  the right end state -- it removes `/bin/sh` from those paths, which is what `KNOWN-ISSUES` B-2b
  and B-4 are about, and it would bring them under `close_range` too. It is *not* what closes this
  finding (the socket fix already covers them), it is a behaviour change at nine sites, and
  `DeviceConfigurationAndPowerManager.cpp`, `FlowLinkUsageCollector.cpp` and
  `TopologyAndFlowMonitor.cpp` are all being edited on other branches right now.
- **The `p4_proxy` (Python) side.** It spawns processes and binds `:8081`. Different descriptor
  table, so it cannot inherit the kernel's sockets -- but whether *it* leaks its own is an
  unanswered question of the same shape. Not measured.
- **`NDT_PORT` / `SFLOW_PORT` are still `#define`s.** `start()` now takes a port so the wiring test
  can bind an ephemeral one, and `openSflowSocket()` likewise, but the kernel's own ports are still
  compile-time constants. Making them configurable is a separate change with its own consumers
  (`tools/test_workflow/ports.sh` has a table of them).
- **The window is now bounded by the socket, not by the children.** Orphaned `curl` processes still
  outlive the kernel by up to `--max-time` (3 s or 8 s); they simply no longer hold anything the
  next kernel needs. Whether the kernel should reap them at all is a separate finding.
