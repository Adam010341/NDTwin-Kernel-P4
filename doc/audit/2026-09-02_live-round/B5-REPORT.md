# B-5: `terminate called without an active exception` on kernel shutdown

2026-09-02, branch `fix/b5-kernel-shutdown`, based on trunk `72fdc5b0` (which descends from
`6283ff5e`, the rev the pre-fix binary was built from; nothing under `src/ include/` differs
between them).
[Co-developed with claude code -- Adam]

**Reproduced: yes, deterministically — 7 runs out of 7.** Root cause found, fixed, and put
through a mutation gate that saw the tests red before it saw them green. The abort was never a
race: it fired on every clean shutdown the kernel has ever performed. What made it look
intermittent is that the shutdown path which crashes is not the one `ndt down` takes.

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

## 3. Reproduction

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

## 4. The fix

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
SIGKILLs". That belongs on its own branch (`fix/b5-sigterm-clean-shutdown`) with Adam's decision,
not inside a correctness fix. It is listed in §8.

## 5. Making the failure observable (task 1)

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
  recorded ending, and prints it in red when the status is 134.
* **`stack.sh`: the kernel is now started with `exec ./bin/ndtwin_kernel …`** inside its wrapper
  shell. Without `exec`, that shell stays alive as the kernel's parent and every pid anyone
  recorded for "the kernel" was the shell's (this is the parent pid 2859 seen tonight). With it,
  `<name>.child.pid` is the kernel's own pid, `/proc/<pid>/comm` reads `ndtwin_kernel`, and the
  recorded status is the kernel's own.
(The log gate's blind spot, found the same way, is a finding of its own — §6.)

**Risk: LOW, with one named exception.** Nothing changes what any command returns; three endings
(0 clean / 134 abort / 143 SIGTERM's default action) are *recorded and reported*, never used to
decide pass or fail — deliberately, because **143 is the normal, healthy result of `ndt down`
today**, and a pipeline that called non-zero a failure would turn every teardown red tomorrow
morning. The exception: adding `exec` changes the recorded command string, so the first
`ndt up` after this restarts a kernel that is already running (`start_bg`'s own documented rule).

Covered by `tests/shell/test_supervise_exit_status.sh` (22 checks). The existing
`test_start_bg_log_rotation.sh` (13), `test_wait_for_port.sh` (6) and `test_teardown_guards.sh`
(14) still pass unchanged.

## 6. Independent finding: the crash detector could not see our crash

`tools/contract_test/check_logs.py` exists so that "scroll the log and see if anything looks
bad" is replaced by a pass/fail gate, and its `CRASH_PATTERNS` table is explicitly documented as
the part that "cannot be allowlisted" — the most important signal it carries. That table listed

* `terminate called after throwing`
* `terminate called recursively`

and **not** `terminate called without an active exception` — the one the kernel actually printed.
Had the abort landed in a log this gate examined, the gate would have said the log was clean.
The gate existed, ran, and returned green, and it never had the ability to see the thing it is
for.

The mistake is not one missing string. It is a hand-written list standing in for a whole class —
every fatal message a C++ runtime, glibc, or the shell can print — where **a gap presents itself
as exhaustiveness**. So the class was enumerated rather than the one string patched, and
`tests/shell/test_check_logs_crash_patterns.sh` asserts every member of it, with negative
controls asserting the patterns are not so wide that ordinary prose trips them.

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

## 7. The test and its mutation gate

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
session may be measuring (§8.3). That directory was deleted afterwards; the gate rebuilds it.

One gap, named rather than left implicit: `tests/shell/check_gate_anchors.py` — the tool that
catches a gate whose anchors have rotted — discovers anchors by parsing each gate's own helper
calls, and does not know this gate's `edit <file> <anchor> <repl>` shape. It is being rewritten
by another session right now, so this branch does not touch it. Until it is taught the shape,
this gate's own uniqueness check (a non-unique or missing anchor is scored SURVIVOR, not a
warning) is the only thing guarding it.

## 8. Findings that are NOT B-5, raised separately

1. **`ndt down` has never executed the kernel's shutdown code.** SIGTERM is unhandled
   (`src/main.cpp:314` registers SIGINT only), so on the normal stop path no destructor, no
   `stop()`, no flush and no join has ever run in automation. Everything the documentation
   describes about an orderly shutdown is, on that path, unexercised. Fixing it changes semantics
   — see §4 — so it is a separate branch and a decision for Adam.
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

## 9. For the auditor to decide

* Should `ndt down` (or `stack.sh down`) **fail** when a component's recorded ending is 134? Today
  it only reports. Making it fail is a one-line change and would make a crash-on-shutdown
  impossible to ignore — but 143 must stay a success or every teardown turns red.
* Does `fix/b5-sigterm-clean-shutdown` (a SIGTERM handler) get written now or after someone
  establishes whether the clean path can hang? The independent report of a kernel that logged a
  full clean shutdown and was still serving 14 minutes later suggests it can.
* `build/bin/ndtwin_kernel` currently holds `ae8b752f` (the fixed build). Restoring `a8ba99c2`
  would be a second mid-round swap, so this session did not do it; the file and its sha are in
  `.test_run/binaries/b5-2026-09-02/` for whoever owns that round.
