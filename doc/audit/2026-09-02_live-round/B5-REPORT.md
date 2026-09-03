# B-5: `terminate called without an active exception` on kernel shutdown

2026-09-02, branch `fix/b5-kernel-shutdown`, based on trunk `72fdc5b0` (which descends from
`6283ff5e`, the rev the pre-fix binary was built from; nothing under `src/ include/` differs
between them).
[Co-developed with claude code -- Adam]

**Reproduced: yes, deterministically — 7 runs out of 7.** Root cause found, fixed, and put
through a mutation gate that saw the tests red before it saw them green. The abort was never a
race: it fired on every clean shutdown the kernel has ever performed. What made it look
intermittent is that the shutdown path which crashes is not the one `ndt down` takes.

Two things found alongside it are larger than it. **§3**: the log gate that is supposed to catch
crashes could not see twelve of the thirty-two ways a run can die — including SIGKILL, which is
what systemd-oomd does to this machine several times a day. **§6**: the fix makes shutdown
correct, and measurably slower — 81 s in one run of seven — which decides how the SIGTERM branch
has to be built.

---

## 1. What the abort is

`DeviceConfigurationAndPowerManager::start()` launches **three** workers
(`DeviceConfigurationAndPowerManager.cpp:132-135` at `6283ff5e`):

```
132:    m_pingThread = thread(&...::pingWorker, this, 1);
133:    m_statusUpdateThread = thread(&...::statusUpdateWorker, this);
134-135: m_openflowTablesUpdateThread = thread(&...::openflowTablesUpdateWorker, this);
```

`stop()` (`:139-154`) joined **two** of them — `m_pingThread` at `:147`, `m_statusUpdateThread`
at `:152`. `m_openflowTablesUpdateThread` (declared at
`include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp:824`) was never joined
and never detached, and the class declared **no destructor at all** — the only long-running
component in the kernel that did not.

So the implicit destructor destroyed a `std::thread` that was still joinable. That is
`std::terminate()` with no exception in flight, which libstdc++ reports as
`terminate called without an active exception`, then `abort()` → SIGABRT → wait status 134.

Note the failure does not depend on the worker still running: a thread that has *finished* is
still joinable until someone joins it. The abort is unconditional on destruction.

### Evidence, not inference

gdb on the live kernel (SIGINT sent from outside, `handle SIGINT nostop pass noprint`):

```
#7  std::terminate ()
#8  std::__terminate () at .../c++config.h:322
#9  std::thread::~thread (this=0x555555ae1738) at /usr/include/c++/13/bits/std_thread.h:173
#10 DeviceConfigurationAndPowerManager::~DeviceConfigurationAndPowerManager (this=0x555555ae16d0)
#19 sflow::FlowLinkUsageCollector::~FlowLinkUsageCollector (...)   FlowLinkUsageCollector.cpp:174
#28 HttpSession::~HttpSession (...)                                HttpSession.hpp:48
#57 boost::asio::io_context::~io_context (...)
#58 main (...) at src/main.cpp:449
```

`0x555555ae1738 − 0x555555ae16d0 = 104`, and `ptype /o DeviceConfigurationAndPowerManager` puts
`m_pingThread` at offset 24, `m_statusUpdateThread` at 96 and **`m_openflowTablesUpdateThread` at
104**. The aborting thread object is named, not guessed.

The rest of the stack is worth reading too: the last reference to the manager was held by an
`HttpSession` still alive inside an asio operation that `~io_context` abandoned, so the abort
landed at the closing brace of `main`, after `"All subsystems stopped. Exiting."` had already been
logged. Every log line the operator sees says the shutdown succeeded.

## 2. Why tonight's live round did not see it

`main()` registers a handler for **SIGINT only** (`src/main.cpp:314`). `ndt down` →
`stack.sh stop_one` → `kill -TERM -$pid`. Nothing handles SIGTERM, so the default action kills
the process immediately: no destructors, no abort, wait status 143.

The crash is therefore reachable **only** from Ctrl-C in a terminal — which is exactly how the
manual usertest on the VM stops the kernel, and how the user manual tells an operator to run it
(`sudo -E bin/ndtwin_kernel`). The one shutdown path a human takes is the one that crashes; the
one automation takes cannot crash because it never runs the shutdown code at all.

`D2_b5_kernel_exit.log`'s "zero occurrences" is honest evidence and its collection is sound —
`start_bg` redirects the component's stderr into the log with `2>&1`, and the runtime's abort
message does land there (that is how the reproduction below captured it). What the zero means is
"this run did not execute the shutdown path", not "the shutdown path is clean".

## 3. The bigger finding: the crash detector could not see the crashes

This section is ahead of the reproduction on purpose. B-5 is one defect in one class; what
follows is the reason a whole category of deaths has been passing a gate that exists to catch
them — **including the one that is biting this project today.**

`tools/contract_test/check_logs.py` replaces "scroll the log and see if anything looks bad" with
a pass/fail gate, and its `CRASH_PATTERNS` table is documented as the part that "cannot be
allowlisted" — the most important signal it carries. Twelve of the thirty-two fatal messages a
run can produce were absent from it. Two of them matter more than the rest:

* **`Killed` — SIGKILL, which is what systemd-oomd leaves behind.** This is not hypothetical and
  it is not about the kernel: today systemd-oomd killed Adam's application and three builds on
  this laptop. A killed process prints *nothing about itself* — the only trace is the shell's
  `<pid> Killed` line — so if the kernel is ever the thing oomd picks, `check_logs.py` returns
  **green** on the log of a run whose kernel was executed mid-flight. The gate was blind to the
  failure mode this machine actually produces, several times a day.
* `terminate called without an active exception` — B-5's own message. A log carrying the abort
  would have passed. The gate ran, returned green, and never had the ability to see it.

### The method, so the next person re-runs it instead of re-deriving it

The mistake is not one missing string. It is a hand-written list standing in for a whole class,
where **a gap presents itself as exhaustiveness** — the list looks complete because nobody can
see what is not on it. The fix was to enumerate the class from its *producers* rather than guess
entries one at a time. There are exactly three, and each has a finite vocabulary:

1. **The C++ runtime (libstdc++).** Everything it prints before dying: the three
   `terminate called …` wordings (after throwing / recursively / without an active exception),
   the `  what():` detail line, `pure virtual method called`. Source: `libstdc++`'s
   `__verbose_terminate_handler`. A catch-all `terminate called` is included for a fourth
   wording that does not exist yet.
2. **glibc.** Everything routed through `__libc_message` plus the fortify traps: the allocator
   family (`free()/malloc()/realloc()/munmap_chunk()/malloc_consolidate(): …`, the tcache
   double-free wording, `corrupted size vs. prev_size`, `corrupted double-linked list`),
   `*** stack smashing detected ***`, `*** buffer overflow detected ***`, `Fatal glibc error`,
   and `assert()`'s `Assertion … failed`.
3. **The shell**, for deaths the process cannot report because it is already gone: the
   job-control notice `<pid> Killed | Aborted | Segmentation fault | Bus error | Illegal
   instruction | Floating point exception`, with or without `(core dumped)`. **This is the only
   category that can catch a SIGKILL at all**, which is why leaving it out was the expensive
   omission rather than a tidy one.

Re-running the audit is mechanical: for each producer, list what it can print, add a case to
`tests/shell/test_check_logs_crash_patterns.sh`, and see whether it goes red. The test is the
enumeration — the table in `check_logs.py` is only its consequence.

`tests/shell/test_check_logs_crash_patterns.sh` asserts every member, with negative controls
asserting the patterns are not so wide that ordinary prose trips them.

**Red then green, by pointing the same test at the two versions of the checker** (`CHECK_LOGS=`
override; the old one taken from `git show HEAD:tools/contract_test/check_logs.py`):

| | checks | failed |
|---|---|---|
| `HEAD` (before) | 32 | **12** |
| this branch (after) | 32 | 0 |

The red run is kept verbatim in `raw/b5-fix/test_crash_patterns_vs_HEAD.red.txt`.

The twelve the gate could not see:

* `terminate called without an active exception` — **B-5's own message**
* `free(): double free detected in tcache 2` (the common wording; only "double free or
  corruption" was listed)
* `realloc(): invalid pointer`, `munmap_chunk(): invalid pointer`
* `corrupted size vs. prev_size`, `corrupted double-linked list`
* `*** stack smashing detected ***`, `*** buffer overflow detected ***`
* `Fatal glibc error: …`
* **SIGKILL** — the shell's `12345 Killed` notice. A killed process prints nothing itself, and on
  this laptop systemd-oomd is a routine source of exactly that; the machine's OOM kills were
  invisible to the log gate.
* `Bus error`, `Illegal instruction`

The false-positive direction is asserted too: `Killed` and `Aborted` are ordinary English, so the
pattern requires a pid in front of them, and the five negative controls (`… terminated
normally`, `killed the switch process for dpid 5`, `12 aborted requests were retried`, …) must
still pass. The existing `tests/python/test_check_logs_powered_off.py` (22 tests) is unaffected.

## 4. Reproduction

Fabric-free: the kernel starts, complains that it cannot reach Ryu/the proxy, and still brings up
every subsystem and opens :8000. The defect is a property of the object's own lifetime, so no
Mininet, no controller and no lab claim were needed. Ten runs per binary, the same script
(`repro.sh`: start → wait for :8000 → optional load → signal → `wait` for the exact status),
one kernel at a time.

| condition | pre-fix `a8ba99c2` | post-fix `ae8b752f` |
|---|---|---|
| SIGINT, idle, 8 s after startup (×3) | 134 + 1× abort message, all 3 | 0 + no message, all 3 |
| SIGINT, with HTTP requests in flight (×2) | 134 + message, both | 0 + no message, both |
| SIGINT, 1 s after :8000 opened (×1) | 134 + message | 0 + no message |
| SIGINT, 20 s after startup (×1) | 134 + message | 0 + no message |
| SIGTERM, idle (×2) | 143, no message | 143, no message |
| SIGTERM, with requests in flight (×1) | 143, no message | 143, no message |

**7/7 abort before, 0/7 after. The SIGTERM column is unchanged on purpose** — this fix does not
alter what `ndt down` does or what it returns.

Binaries, archived at `.test_run/binaries/b5-2026-09-02/` with `PROVENANCE.md`:

* pre-fix `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06` — the live round's
  kernel, source `f41a06a6`, identical under `src/ include/` to trunk `6283ff5e`.
* post-fix `ae8b752f8d6d693317c0ea3f9a230e7d0f0c5616acb6e4f5191417e2858feb4a` — the same tree plus
  the two-file fix below.

Raw, in `raw/b5-fix/` beside this file: `matrix_pre.txt`, `matrix_post.txt` (one line per run,
with the exact wait status), `kernel_pre_sigint_tail.log` (the abort, after
`"All subsystems stopped. Exiting."`), `kernel_post_sigint_tail.log`, `gdb_backtrace_top.txt`.

## 5. The fix

Two files, both on `fix/b5-kernel-shutdown`:

* `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp` — `stop()` now joins
  `m_openflowTablesUpdateThread` as well, and the class gets
  `~DeviceConfigurationAndPowerManager() { stop(); }`.
* `include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp` — declares it.

The destructor is not belt-and-braces: `stop()` being called is a property of *callers*, and the
same class is reachable from paths that do not call it (an early return, a throw during startup,
or simply the last `shared_ptr` going away first). `TopologyAndFlowMonitor`,
`FlowLinkUsageCollector`, `HistoricalDataManager`, `ControllerAndOtherEventHandler` and
`FlowDispatcher` all already own their threads this way. This class was the exception, and the
exception is where the abort was.

**Risk: LOW.** No caller's behaviour changes. `ndt down` still produces 143, every log line is
what it was, and the only observable difference is that a process which used to abort now exits 0.

### What was deliberately NOT done here

Registering a SIGTERM handler would make `ndt down` run the clean shutdown for the first time.
That is a change of shutdown *semantics*, not a correctness fix: today SIGTERM is guaranteed to
kill the kernel instantly, and after such a change it would run teardown code that has never run
in automation — including `ApplicationManager::cleanupNFS`, which unmounts NFS paths and can
block. If that path ever hangs, `ndt down` goes from "always works" to "waits 10 s and then
SIGKILLs".

That "if" is no longer hypothetical: §6 measures the clean path at 81 s in one run of seven. The
handler belongs on its own branch (`fix/b5-sigterm-clean-shutdown`), **behind a bounded poll**,
with Adam's decision — not inside a correctness fix.

## 6. How long the clean path takes, measured

The one thing standing between "a SIGTERM handler is obviously right" and "a SIGTERM handler is
a risk" is whether the clean path can hang. After the fix, **SIGINT runs the clean path**, and
seven of them were already recorded — so the number exists without a new measurement round.

From `"Shutdown requested. Cleaning up…"` (logged by `main` within one 200 ms poll of the
signal) to the last line the process wrote:

| run | condition | shutdown duration |
|---|---|---|
| post_int_idle_1 / _2 / _3 | idle | 2.40 s, 2.40 s, 2.53 s |
| post_int_long | idle, 20 s uptime | 2.40 s |
| post_int_fast | idle, 1 s uptime | 6.40 s |
| post_int_busy_2 | requests in flight | 3.00 s |
| **post_int_busy_1** | **requests in flight** | **81.09 s** |

Six of seven are seconds. The seventh is the answer, and it is the unwelcome one.

### Where the 81 seconds went

The tail of that run, with the gaps:

```
+ 0.00s  ControllerAndOtherEventHandler.cpp:189  ControllerAndOtherEventHandler stopped.
+ 0.00s  DeviceConfigurationAndPowerManager.cpp:153  Collector Stops        <- stop() entered
+ 7.01s  DeviceConfigurationAndPowerManager.cpp:1142 no flow-table response from ...
+72.09s  DeviceConfigurationAndPowerManager.cpp:2040 serving 10 switch(es) from their previous ...
+ 0.00s  main.cpp:446  All subsystems stopped. Exiting.
```

Every one of those 79 seconds is spent **inside the join this fix added**, waiting for
`m_openflowTablesUpdateThread` to finish a poll round it had already started: ten switches, one
HTTP request each, against a control plane that was not answering. The worker checks `m_running`
only between rounds and during its 10 s sleep, never inside a round, so `stop()` waits for the
whole round no matter how long it takes.

**This is a cost the fix introduces, and it should be read as one.** Before it, `stop()` returned
at once and the process aborted; now it returns correctly and can take up to a full poll round.
The trade is unambiguously worth making — a crash is not a fast shutdown — but the number is not
small and it is not stated anywhere else.

What it does and does not touch:

* **`ndt down` today: nothing.** SIGTERM is unhandled, so the kernel never reaches this code.
* **Ctrl-C, the operator's path: up to ~80 s**, where it used to be an instant abort. Slower,
  and correct.
* **A future SIGTERM handler: this is the blocker.** `stop_one` waits 10 s and then sends
  SIGKILL. A shutdown that needs 79 s would be killed at 10 s — turning "always dies instantly"
  into "waits 10 s, then dies anyway", which is worse than today on both counts.

So the answer to "can the clean path hang?" is **yes, measured: 79 s in 1 run of 7, with the
control plane unreachable** — which is precisely the state a teardown is heading into. The
remedy is not to skip the join; it is to make the round interruptible (check `m_running` between
switches in `fetchOpenFlowTablesInternal`, and give its per-switch HTTP call a deadline) so the
join has a bound. That is the first commit `fix/b5-sigterm-clean-shutdown` should contain, before
the handler.

Caveat on the measurement, so it is not read as more than it is: the clock is the kernel's own
log, so it covers "shutdown flag noticed → last line written", plus up to 200 ms of poll latency
before it and the unmeasured microseconds of process teardown after it. Nothing recorded the
wall-clock instant the signal was sent. Raw: `raw/b5-fix/shutdown_durations.txt`.

## 7. Making the failure observable (task 1)

Before this, "the kernel exited" and "the kernel exited cleanly" were the same observation.
`start_bg` launched components with `setsid "$@" &` and never waited; `stop_one` polled `kill -0`
until the number disappeared. A pid disappearing is all either of them knew. **A kernel that
aborted on shutdown and a kernel that stopped cleanly left byte-identical evidence**, which is
why a defect that fires on 100 % of clean shutdowns survived this long.

Changes:

* **`tools/test_workflow/supervise.sh`** (new). Runs the component, waits for it, and writes
  `<pidfile-prefix>.exit` (`status`, `signal`, `child_pid`, `supervisor_pid`, `at`, `command`,
  `reason`) plus an appended line in `<prefix>.exit.log`, then exits with the child's status.
* **`stack.sh: start_bg`** launches through it. The pid it records is unchanged — the supervisor
  is the process-group leader, which is what `stop_one`'s `kill -TERM -$pid` and
  `port_owner_verdict`'s pgid comparison both rely on. The pid of the process actually doing the
  work is written separately to `<name>.child.pid`.
* **`stack.sh: report_exit`**, called from `stop_one` after the process is gone: prints the
  recorded ending, in red when it is a fatal signal.
* **`stack.sh`: the kernel is now started with `exec ./bin/ndtwin_kernel …`** inside its wrapper
  shell. Without `exec`, that shell stays alive as the kernel's parent and every pid anyone
  recorded for "the kernel" was the shell's (this is the parent pid 2859 seen tonight). With it,
  `<name>.child.pid` is the kernel's own pid, `/proc/<pid>/comm` reads `ndtwin_kernel`, and the
  recorded status is the kernel's own.
(The log gate's blind spot, found the same way, is §3.)

**Risk: LOW, with one named exception.** The recording commit changes what nothing returns; the
exception is adding `exec`, which changes the recorded command string, so the first `ndt up`
after it restarts a kernel that is already running (`start_bg`'s own documented rule).

### Acting on it: `down` fails on a fatal signal (separate commit, behaviour change)

Recording an ending and acting on it are two decisions, so they are two commits. The second one
(`stack.sh: a component that died of a fatal signal fails 'down', and is named`) makes cmd_down
return non-zero, naming the component and its status, for

    132 SIGILL   134 SIGABRT   135 SIGBUS   136 SIGFPE   137 SIGKILL   139 SIGSEGV

and **not** for 143 or 130. That exclusion is the whole care taken: 143 is SIGTERM's default
action, which is how `ndt down` stops every healthy kernel today, and 130 is an operator's
Ctrl-C. Calling non-zero a failure would have turned every teardown red for a defect nobody has.
137 is in the list deliberately — see §3 on what systemd-oomd does to this machine daily.

The verdict is delivered **once**: the `.exit` file is removed as it is reported, so a crash that
has already been surfaced does not fail every later teardown. The durable record is the appended
line in `<component>.exit.log`, which nothing rewrites.

Acceptance criteria, asserted in `tests/shell/test_supervise_exit_status.sh` (39 checks):

| injected ending | `down` | asserted |
|---|---|---|
| 134 (abort) | **non-zero**, and names `kernel(134)` | yes |
| 137 (OOM kill) | **non-zero** | yes |
| 143 (SIGTERM — today's normal path) | zero | yes |
| 0 (clean) | zero | yes |
| the same 134, reported a second time | zero | yes |

`cmd_down`'s other failure mode — a port still listening — is held constant through the
`port_open` seam, so these cases are about the endings and nothing else. **This is the piece to
review before merge**, because it is the only change here that can make a command fail that did
not fail before.

Covered by `tests/shell/test_supervise_exit_status.sh` (22 checks). The existing
`test_start_bg_log_rotation.sh` (13), `test_wait_for_port.sh` (6) and `test_teardown_guards.sh`
(14) still pass unchanged.

## 8. The test and its mutation gate

`tests/test_PowerManagerShutdown.cpp`, three death tests in `test_routing_strategy`:

1. `DestroyingAJoinableThreadIsVisibleToThisHarness` — the **instrument control**. Destroys a
   joinable `std::thread` on purpose and asserts the child dies by SIGABRT *with the B-5 message*.
   Without it, the other two pass by not observing an abort, which is also what a harness that
   cannot observe one does.
2. `AStoppedManagerIsDestroyedWithoutAborting` — start, stop, destroy: the kernel's own path.
3. `AManagerNeverStoppedIsDestroyedWithoutAborting` — start, destroy: the destructor alone.

They assert the **shape** (nothing this object owns is still joinable when it is destroyed), not
the one member. Asserting "`m_openflowTablesUpdateThread` is joined" would be the fix restated,
and would not notice the next worker someone adds — which is exactly how B-5 happened.

Death tests because the failure *is* process death: an `EXPECT` inside the process that aborts
never runs. `threadsafe` style, so the child re-execs rather than forking a process that holds
other suites' threads and spdlog's mutex.

### Mutation gate

`tests/shell/mutate_b5_power_manager_shutdown.sh`, run with `BUILD_DIR=build-b5`. Baseline must
build and be green; every source is snapshotted, restored on any exit, and asserted
byte-identical at the end. An anchor that is not unique, a mutation that cannot be applied and a
mutant that does not compile all count as **SURVIVOR**, never as a warning.

**Result: 3 mutations, 0 survivors.** Full log: `raw/b5-fix/mutation_gate.log`.

| # | mutation | went red | verdict |
|---|---|---|---|
| baseline | — | nothing | 3 tests green |
| 1 | `stop()` forgets the third worker — B-5 exactly as it shipped | `AStoppedManagerIsDestroyedWithoutAborting` **and** `AManagerNeverStoppedIsDestroyedWithoutAborting` | caught |
| 2 | the destructor no longer calls `stop()` | `AManagerNeverStoppedIsDestroyedWithoutAborting` only | caught, and by the right one: the stopped case must stay green here, and did |
| 3 | **a fourth worker, started and never joined** (header + `start()`) | both lifecycle tests | caught — the suite notices a thread it was never told about |
| restore | — | — | sources byte-identical, tree builds |

The instrument control stayed green throughout, which is what it is for: it fails only if the
harness stops being able to see an abort at all.

Mutation 3 is the one that matters for the future. Under a test that asserted "the openflow
thread is joined", mutation 3 would have passed — a new worker, a new hole, a green suite. That
is the exact sequence that produced B-5.

Run it with `BUILD_DIR=build-b5 tests/shell/mutate_b5_power_manager_shutdown.sh`, under the
shared build lock and the `-j2` shim. It was run in a private build directory rather than
`build/`, because `build/` is shared output and rebuilding it replaces the binary another
session may be measuring (§9.3). That directory was deleted afterwards; the gate rebuilds it.

One gap, named rather than left implicit: `tests/shell/check_gate_anchors.py` — the tool that
catches a gate whose anchors have rotted — discovers anchors by parsing each gate's own helper
calls, and does not know this gate's `edit <file> <anchor> <repl>` shape. It is being rewritten
by another session right now, so this branch does not touch it. Until it is taught the shape,
this gate's own uniqueness check (a non-unique or missing anchor is scored SURVIVOR, not a
warning) is the only thing guarding it.

## 9. Findings that are NOT B-5, raised separately

1. **`ndt down` has never executed the kernel's shutdown code.** SIGTERM is unhandled
   (`src/main.cpp:314` registers SIGINT only), so on the normal stop path no destructor, no
   `stop()`, no flush and no join has ever run in automation. Everything the documentation
   describes about an orderly shutdown is, on that path, unexercised. Fixing it changes semantics
   — see §5, and the measured cost in §6 — so it is a separate branch and a decision for Adam.
2. **`stop_one`'s first line reads the caller's variable, not its argument.**
   `local name="$1" pidfile="$PID_DIR/$name.pid"` — bash expands both right-hand sides *before*
   `local` runs, so `$name` is whatever `name` held in the caller. It has always worked by
   coincidence: `cmd_down`'s loop variable and `start_bg`'s local are both called `name` and hold
   the same value, so the wrong reading and the right one agreed.

   That is the worst kind of correct, and the cost when they disagree is silent: `stop_one`'s own
   `err`/`info` lines print `$name`, which by then *is* the argument, so it reports the component
   it was asked for while reading the pidfile of — and sending SIGTERM to the process **group**
   of — a different one.

   `tests/shell/test_stop_one_targets_its_argument.sh` drives it with two real processes and a
   caller holding `name=ryu` that asks for the kernel. Red then green, same test, `STACK=`
   pointed at each version:

   | | checks | failed | what happened |
   |---|---|---|---|
   | `HEAD` (before) | 5 | **4** | Ryu was stopped, the kernel survived; and with no `name` in scope at all the teardown died under `set -u` (rc=1) without stopping anything |
   | this branch (after) | 5 | 0 | the kernel is stopped, Ryu is untouched, in both callers |

   The red run: `raw/b5-fix/test_stop_one_vs_HEAD.red.txt`.

   Fixed by splitting it into two statements. LOW-RISK: no current caller's behaviour changes,
   because no current caller was in the disagreeing case. Its own commit.
3. **A shared worktree with a shared build directory means any rebuild replaces the object
   someone else is measuring, and nothing tells them.** `build/bin/ndtwin_kernel` was rebuilt at
   23:35 while a round was measuring it; the round noticed only because it reads `/proc/<pid>/exe`
   itself. The pre-fix binary was recoverable only because this session had copied it aside — all
   three backups held a different build. Both binaries are now archived under
   `.test_run/binaries/b5-2026-09-02/`, and this session's builds go to `build-b5/`.
4. **The manual path collects no stderr.** `sudo -E bin/ndtwin_kernel` in a terminal — what the
   manual teaches and what the usertest tester does — sends the runtime's abort message to a
   scrollback nobody keeps. That path is both the only one that can produce the abort and the only
   one with no log to find it in.

## 10. Decided, and what is still open

Ruled by the auditor on 2026-09-03, recorded here with what was done about each.

**(a) A fatal signal fails `down`; 143 does not. — DONE, on this branch.** Implemented as its own
commit with the acceptance criteria asserted (§7). Not applied to trunk tonight, because it is
the one change here that can make a command fail that did not fail before. Review it against the
table in §7: an injected 134 red, an injected 137 red, 143 green, 0 green.

**(b) The SIGTERM handler waits — and the condition it was waiting on is now measured.** §6: six
of seven post-fix SIGINT shutdowns finished in 2.4–6.4 s, and the seventh took **81 s**, spent
inside the join this fix adds, waiting for one openflow poll round against an unreachable control
plane. So the clean path *can* take far longer than the 10 s `stop_one` allows before SIGKILL.
That flips the order of work on `fix/b5-sigterm-clean-shutdown`: **bound the poll first** (check
`m_running` between switches, deadline the per-switch request), *then* register the handler. A
handler alone would convert "always dies instantly" into "waits 10 s and is killed anyway".

No new measurement round was run to obtain this; it came from the seven runs already recorded.

**(c) `build/bin/ndtwin_kernel`** — the auditor swaps `a8ba99c2` back between rounds with a
handoff script that refuses to run while a fabric is live. This session did not touch it after
the archive. Both binaries and their provenance: `.test_run/binaries/b5-2026-09-02/`.

### Still open, for whoever picks up the branch

* **Merge order.** Commits 1, 2, 3 and 5 are corrections and evidence; commit 6 (the exit-code
  behaviour change) is the only one that needs a policy decision from Adam before it lands.
* **The bounded poll** described in (b), as the first commit of the SIGTERM branch.
* **`tests/shell/check_gate_anchors.py`** does not yet know this gate's `edit <file> <anchor>
  <repl>` helper shape, so the new gate's anchors are not covered by the anchor-rot checker. That
  tool was being rewritten in the shared worktree tonight, so this branch left it alone (§8).
