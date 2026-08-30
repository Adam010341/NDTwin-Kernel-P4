# Agent D — testing doc update (doc/2026-08-07_testing_tools_overview.md)

## TL;DR
- **Status**: DONE. `doc/2026-08-07_testing_tools_overview.md` 266 -> 570 lines (+~330/-40). **Only that one repo file changed** (`git status --porcelain` shows exactly `M doc/2026-08-07_testing_tools_overview.md`), plus the one-line pointer in `TESTING-INVENTORY.md`.
- **Base trap hit**: worktree HEAD was `8b61cdc "Add sharding"` (the origin/main trap). Fetched `p4`, `reset --hard 3794ac1`. Verified `tests/`, `tools/twin_audit/`, `tools/test_workflow/faults.sh` all present. Everything below was read at `3794ac1`.
- **All seven tools now covered**, each with what it catches / prerequisites / how to run / verdict criterion / **what it structurally cannot see**. Eight tiers documented; L6 soak explicitly marked as not existing.
- **All eight traps written in**, each verified against source before quoting. Trap 5 (`PYTHONDONTWRITEBYTECODE=1`) turned out to be recorded **nowhere in the repo** — the doc is now its only home.
- **Three stale counts found and removed** (`tests/python/` "2 files/101 tests" is now 7 files; `tests/shell/` "1 test" is now 6; `doc/audit/` "2 mutation-evidence" is now 4). These were missed by `7eddd68`; replaced with counting commands per that commit's decision.
- **Structural finding worth Adam's attention**: `run_layers.sh` contains **zero** references to L5 / twin_audit / fuzz, and `tools/test_workflow/README.md` mentions **none** of the seven tools. Orchestration is now genuinely two-headed and partly manual; the doc says so explicitly rather than letting "I ran `full`" read as "I ran everything".
- **Nothing live touched.** One shell test run (`test_qdisc_snapshot.sh`, pure stub, verified as such before running). No `local_ci.sh`, no `stack.sh`, no `tc`/`mnexec`/`ovs-vsctl`, no connection to :8000/:8081/:50051-50060.

## Log

### Step 0 — worktree base
- `git log --oneline -1` -> `8b61cdc Add sharding`. Wrong base. Worktree was clean (`git status --porcelain` empty), nothing lost.
- `git fetch p4` then `git reset --hard 3794ac1` -> HEAD is now `3794ac1 Drive the topology graph with random link events`.
- Confirmed present: `tests/` (43 tracked top-level `test_*.cpp` plus `fixtures/ fuzz/ manual/ python/ shell/`), `tools/twin_audit/{criteria.py,twin_audit.py}`, `tools/test_workflow/faults.sh` (20027 bytes, executable) alongside `faults.txt`, `local_ci.sh`, `p4_coverage_gate.sh`, `p4_coverage_baseline.txt`, `qdisc_snapshot.sh`.
  - Self-correction worth recording: my first eyeball count off `ls` said 46. `ls tests/test_*.cpp | wc -l` and `git ls-files 'tests/test_*.cpp' | wc -l` both say **43**, and a diff of the two lists is empty. I miscounted a visual listing — which is exactly why the doc gives counting commands rather than numbers.

### Step 1 — read the existing doc
- `doc/2026-08-07_testing_tools_overview.md` is 266 lines, Chinese, organised on two axes: test levels L0-L4 + a verdict-criteria layer, and cross-cutting gate mechanism shapes.
- Quality is genuinely high in the methodology sections (allowlist gates, known-good-as-spec, self-validating tests, orchestration, mutation testing). Those are being preserved verbatim per instructions.
- Confirmed by grep that none of the seven new tools appear: 0 hits for `local_ci`, `p4_coverage`, `fuzz_sflow`, `twin_audit`, `faults.sh`, `qdisc_snapshot`, `hypothesis`.
- It already does the right thing on numbers (L1 section refuses to bake in counts and gives counting commands instead) — that convention gets extended, not broken.

### Step 2 — source reading, every claim checked against the file

Everything below was read at `3794ac1`, not recalled.

**`tools/test_workflow/local_ci.sh`** (147 lines). Six jobs: `gcc python asan tsan clang p4cov`. Header says it mirrors `.github/workflows/ci.yml` and exists because Actions has been out of quota since `b0a7bdc`. Confirmed in source, not just the header:
- not fail-fast — `main()` loops all jobs and only sets `failed=1`; exit 1 if any failed, 2 for an unknown job name (`local_ci.sh:119-138`).
- `job_gcc` runs the binary **and** ctest (`:47-48`), with the comment that ctest's per-case process hides `SetUpTestSuite` failures.
- `job_tsan` uses `setarch "$(uname -m)" -R` (`:75`); comment says without it you get "unexpected memory mapping" before main.
- `job_asan` sets `abort_on_error=1` because a UBSan report otherwise prints and still exits 0 (`:62-65`).
- `job_clang` is a **build only**, a rot guard — clang once could not compile the project at all (`:84-92`).
- Sourcing defines functions without running (`:142-144`) — that is the seam `tests/shell/test_local_ci.sh` drives.

**`p4_coverage_gate.sh` + `p4_coverage_baseline.txt`**. Gate skips unless `git hash-object` of the `.p4` differs from the recorded sha (`:85-88`); a missing `p4testgen` is a **skip, not a failure** (`:75-78`), reasoning given as "failing the whole run for a missing optional tool is how a CI stops being read". `MIN_COVERAGE` default 0.85. The gate compares the **shape** of the uncovered set both ways: new uncovered lines are a FAIL (`:121-126`), lines that became covered are a note asking for `--update-baseline` (`:127-129`).
- Baseline file records `coverage 0.851852`, `uncovered 414 415 416 417 418 419 420 421`.
- The baseline header states the cause precisely and it matches the task brief: the branch is keyed on **`instance_type`**, not on the presence of clone. Cross-check recorded there: p4lang/tutorials `flowcache/solution` also clones and still reaches 100%, because its egress branch keys on `egress_port`, which the solver can choose. Those 8 lines are guarded only by live runs and `test_SFlowEmitterRoundtrip.cpp`.

**`tests/fuzz/fuzz_sflow.cpp`** (122 lines). Target is `FlowLinkUsageCollector::handlePacket(char*, size_t)`, reachable by anything that can send UDP to :6343; it has produced a heap-buffer-overflow before. Oracle is **clean rejection, not silence** — the parser has an explicit `reportMalformedDatagram` path, so crash/sanitizer report/hang is the finding and nothing asserts on parse results. `tests/fixtures` (**31** `.bin`, verified by `ls | wc -l`) is the seed corpus. Build gate: `tests/CMakeLists.txt:90` `option(FUZZING ... OFF)` and `:93` `FATAL_ERROR "FUZZING=ON requires clang"`. Two design notes worth carrying: collector recycled every 512 inputs so accumulated flow-table growth is not misread as a parser OOM, and the last collector is deliberately never deleted because `~FlowLinkUsageCollector` touches a possibly-destroyed spdlog registry.

**`tools/twin_audit/{twin_audit,criteria}.py`** (442 + 619 lines). Founding case: 2026-08-13 OVS round, twin said "flowing at 9-15 Mbps", edges_up 287/288, flow had carried zero packets for 291 s.
- Three channels: `ping` (both directions), `paths` (control plane's `all_destination_paths`), `counters` (peer-side rx growth). `QUORUM = 2`, and **any dissent is DISPUTED, never a majority vote** (`criteria.py:502-522`).
- **Evidence vs claim — verified in source, this is trap #8 and it is real.** `EVIDENCE_CHECKS = ("ping", "counters")`, `CLAIM_CHECKS = ("paths",)` (`criteria.py:470-471`); `combine()` filters with `voting = [o for o in observations if o.check not in CLAIM_CHECKS]` (`:513`). The comment at `:458-469` records the measured incident: with h1's access link cut, ping=still, counters=still, paths=moving, verdict came out DISPUTED with exit 0 — the first version would have missed its own founding case. Claim channels are still run and printed, they just do not vote.
- Deliberate scope limit, stated at `twin_audit.py:16-24`: connectivity only, **no rate reconciliation**, because at 1/256 sFlow sampling the error floor is 196*sqrt(1/c) and a wrong rate is not separable from an honestly-sampled one.
- `path_match` is a **reserved** check that raises `NotImplementedError` rather than quietly returning UNKNOWN (`criteria.py:445-446, 473-477`).
- `PATHS_URL` default is `http://localhost:8080` (Ryu); header line `criteria.py:57-58` says P4 must point it at the proxy :8081. Trap #7 confirmed.
- Exit codes 0/1/2/3/4 = moving/still/usage/inconclusive/disputed.
- `counters` sends its own probe between the two samples (`:385-403`) — a comment records that pure passive sampling read STILL on an idle link, producing permanent DISPUTED and a fault harness that refused to inject.

**`faults.sh` + `faults.txt`** (L5). Catalogue is **data**: `faults.txt` is parsed in `faults.sh` and nowhere else (`:141`), format `ID | ACTION key=value ... | reason` with a `" | "` separator, same shape as `warning_allowlist.txt` / `baseline_diff_allowlist.txt`. Two mechanisms only — `link_loss`, `proc_signal`; an unknown mechanism is a usage error with the message "a new mechanism needs code, not just a catalogue line" (`:361-365`). **Where** the fault lands is a command-line argument, not a catalogue field, which is what keeps "add a fault type" to "add a line".
- Round protocol verified in `run_round()` (`:350-425`): qdisc snapshot → `before` must be `moving` or nothing is injected ("a fault round on a network that is already broken proves nothing") → inject → settle → `during` compared against `expect` → revert **always** → settle → `after` must be `moving` → qdisc diff **last, and it overrides everything** ("ROUND VOID ... Discard the result").
- Trap #6 confirmed twice over. `netem_attach_point()` (`:187-210`) reads the live qdisc tree: under htb it returns `parent <handle><default>`, on an unshaped interface `root`. The header at `:47-55` and the error path at `:242-252` both record the measured sudoers grant: NOPASSWD covers only `qdisc add dev s*-eth* root netem *`, `del dev s*-eth* root`, `show` — i.e. **only the destructive root form**, not the safe `parent` form the script computes. Workaround is `FAULTS_TC="sudo -n mnexec -a $(pgrep -f '[t]estbed_topo.py'|head -1) tc"`. There is a second, subtler instance at `:276-282`: the revert must be `qdisc del dev X root` with **no trailing `netem`**, because sudo matches the argument list literally and one extra token fails the revert while leaving the fault in place.
- `proc_signal` takes a PID, never a pattern — Mininet nodes share a PID namespace so `pkill -f simple_switch_grpc` kills all ten switches (`:314-316`).
- `resolve_pid()` (`:109-112`) asks `twin_audit.py hosts` for the IP→PID map. Comment records the first live run: without it every probe ran in the root namespace, the counter read the host's own NIC, and the round refused to inject "a self-inflicted refusal that looked exactly like a real finding".
- Catalogue currently holds **3** live entries (`L-2`, `L-3`, `N-4`) with 3 more sketched in a TODO block and mastership collision explicitly recorded as *not* covered "so the gap stays visible instead of looking covered". `N-4` is labelled THEORY ONLY, never verified against real bmv2.
- **L-3 instability** is consistent with the source, and I can name the mechanism rather than only the arithmetic: `TWIN_AUDIT_PING_COUNT` defaults to 3 (`criteria.py:59`) and `ping_once` treats rc==0 as success (`:270-277`), so at 30% loss in both directions one direction losing all 3 echoes reads as "asymmetric, one direction dead" → STILL. The fix knob exists (raise `TWIN_AUDIT_PING_COUNT`); nothing in the repo sets it. The 13% figure comes from the brief; I did not re-measure it and have labelled it as such in the doc.

**`qdisc_snapshot.sh`** (49 lines). `save`/`diff` over `tc qdisc show | sort`; `diff` exits 1 on any drift, 2 on operator error. Seam is `QDISC_SNAPSHOT_TC`. Header records the reason: `tc qdisc add dev X root netem` replaces TCLink's htb rather than stacking, `del root` restores the kernel default not htb, and the customary "netem residue = 0" check is blind to that.

**`p4_proxy/tests/test_topology_properties.py`** (147 lines). Hypothesis `RuleBasedStateMachine` over `TopologyManager`, 4 switches / 4 links / 2 hosts, `max_examples=150`, `stateful_step_count=25`. Rules: `link_up`, `link_down_both_ways`, `link_down_one_way`. Header explicitly rejects the obvious design (driving the live stack) as too slow to reach the step counts stateful testing needs. The load-bearing invariant is `recompute_never_raises` because the live defect was an exception, not a wrong answer. `hypothesis==6.165.5` confirmed at `p4_proxy/requirements.txt:28`.

### Step 3 — traps, each verified before writing

1. **Two Python dirs, two interpreters.** `components.env:45` sets `P4_PROXY_PY` default to `$KERNEL_DIR/p4_proxy/venv/bin/python`; `l1_unit_tests.sh:152-160` probes that first for an interpreter carrying the P4Runtime protobufs. `tests/python/` runs under plain `python3` (`:279`) and the comment at `:260-263` says so explicitly — "no gRPC, no networkx". `:291-293`: nothing in that directory may skip for an environment reason, so a skip there is a FAIL.
2. **`Ran N checks`.** Parsed at `l1_unit_tests.sh:294` as `grep -oE '^Ran [0-9]+'`; `ran==0` prints `NO TESTS RAN` and increments `FAILURES` (`:322-324`). All six files in `tests/shell/` end with `echo "Ran $((PASS + FAIL)) checks, ..."`. Note the anchor is `^Ran` — leading whitespace breaks it.
3. **TSan needs `setarch -R`** — `local_ci.sh:72-75`, with the FATAL message quoted in the comment.
4. **gtest both ways** — `local_ci.sh:44-48`, plus the existing doc's L1 section which already covers it well.
5. **`PYTHONDONTWRITEBYTECODE=1` for Python mutants** — ⚠️ **grep finds this nowhere in the repo** (searched `*.md`, `*.sh`, `*.py`). It exists only in Adam's memory. So this is a genuine gap the doc closes rather than a restatement; flagged in the doc as measured-but-not-otherwise-recorded.
6. **`tc netem`, not `ifconfig down`; sudoers only grants the destructive form** — see faults.sh notes above, two independent code sites.
7. **`PATHS_URL`** — `criteria.py:57-58`, default `:8080`.
8. **Evidence vs claim** — `criteria.py:470-471` and `:513`.

### Step 4 — stale content found in the existing doc

- Asset table said `tests/python/` is "2 個 Python 檔、101 個測試" — it is now **7** files. Said `tests/shell/` is "1 個 shell 測試" — now **6**. Said `doc/audit/` has "2 份 mutation-evidence" — now **4**. All three are exactly the rot `7eddd68 "Stop baking test counts into three testing docs"` was meant to stop; the asset table was missed by that commit. Replaced with counting commands.
- The doc's opening claims "五層測試架構（L0–L4）". Now eight tiers.
- The doc presents `run_layers.sh` as *the* orchestrator. Verified `run_layers.sh` modes are only `quick api baseline compare full` — grep for `faults|L5|twin_audit|qdisc` in it returns **nothing**. So orchestration is now genuinely two-headed (`run_layers.sh` for the stack-facing layers, `local_ci.sh` for the workflow jobs) with L5 and the audit driven by hand. `tools/test_workflow/README.md` also mentions **none** of the seven (0 grep hits), which is worth a follow-up but is out of scope for a single-file task.

### Step 5 — verification runs (nothing live touched)

- Ran exactly one shell test, after first reading it to confirm it is a pure stub: `tests/shell/test_qdisc_snapshot.sh` exports `QDISC_SNAPSHOT_TC` to a fake `tc` (`:35-41`). Result `Ran 9 checks, all passed`, exit 0, sub-second.
- No `local_ci.sh`, no `stack.sh`, no `tc`/`mnexec`/`ovs-vsctl`, no connection to :8000/:8081/:50051-50060. The bmv2 environment was not touched.
- Before generalising "`tests/shell/` are pure stubs" into the doc I checked all six, not just the one I ran: `grep -ln 'sudo\|mnexec\|ovs-vsctl'` hits only `test_faults.sh`, and there both occurrences are inside a comment and an assertion string — the file `source`s `faults.sh` (which returns early when sourced) and overrides `show_qdisc`, `run_tc`, `run_signal`, `settle`, `qdisc_save`, `check_pair`. The generalisation holds.

### Step 6 — what the doc now says

Structure (570 lines): intro (five questions, the third being "what can this layer structurally not see") -> design theme -> **axis 1: the eight tiers** with an overview table whose last column is the blind spot, a run-command quick reference, then one section each for L0 / L1 / L1-fuzz / L1.5 / L2 / L3 / L4 / L5 / twin lie detector / property testing / verdict criteria / orchestration -> **axis 2: gate mechanism shapes** -> mutation testing -> test assets -> **trap quick-reference table** -> what is not covered.

Kept verbatim (per instruction — the methodology prose is good): the allowlist-gate section, known-good-as-spec, self-validating tests, the L1 "run gtest twice" argument with its measured table, the L3 dead-code correction, L4's shape/facts design, `check_logs.py`, `stack.sh`, and the mutation-testing chapter's core.

Added or rewritten:
- Eight-tier overview table with a **blind-spot column**, plus an explicit "**L6 soak does not exist**" note so the gap is visible rather than looking covered.
- Full sections for the seven new tools, each following the same five-part shape the brief asked for.
- Two new mechanism-shape sections: **catalogue-shaped gates** (data-not-code, parameterised dimensions stay off the file, unused entries get reported, "not yet covered" gets written down) and **independent channels + quorum** (multiple causally-independent channels, no majority vote, evidence separated from claim).
- A **seams** paragraph in the orchestration section — this is what makes `tests/shell/` runnable with nothing running, and it was previously undocumented.
- The `local_ci.sh` job table with the reason for each job's flags, and the warning that it mirrors `.github/workflows/ci.yml` with nothing guarding the sync.
- Rewrote the asset table from "how many" to "**what form, which interpreter, who runs it**", including the fact that `tests/python/` and `tests/shell/` are **not** ctest-registered — so "ctest is green" does not include them.
- Expanded "what is not covered" from 7 items to 17, grouped as: tiers that do not exist / principled tool limits / known-unstable / manual invariants nobody guards / environment-dependent coverage gaps / out of this doc's scope.

Numbers policy: no test counts anywhere. Counting commands given in the L1 section (including a build-free `grep -rhE '^(TEST|TEST_F|TEST_P)\(' tests --include='*.cpp' | wc -l`), plus `faults.sh list` for the fault catalogue and `ls doc/audit/*_mutation-evidence-*.md | wc -l` for the evidence docs. The two figures I did keep are **not** counts of a growing thing: 85.2% / 8 uncovered lines (a recorded baseline the gate itself asserts on) and 196·√(1/c) (a formula). The 13% for the L-3 instability is labelled as coming from the brief and not re-measured here.

### Step 7 — TESTING-INVENTORY.md

Added exactly one blockquote line at the top, above the `**用途**` line, nothing else touched:

> 權威技術描述在 repo 的 `doc/2026-08-07_testing_tools_overview.md`（層級架構、判準、各層的盲點、陷阱）；本檔是報告用的結果摘要，兩者衝突時以 repo 為準。

### Follow-ups for Adam (not done — out of a single-file task's scope)

1. `tools/test_workflow/README.md` mentions none of the seven tools. It is the Chinese walkthrough of the workflow scripts, so it is the natural second home for the run instructions; the two docs' division of labour needs a decision.
2. `run_layers.sh` has no L5 stage. Whether L5 should ever be scriptable from there is a real design question (it needs an operator to choose the interface and PID), but right now "I ran `full p4`" silently excludes L5, fuzz and the audit.
3. `L-3`'s verdict instability has an existing knob (`TWIN_AUDIT_PING_COUNT`) that nothing sets. A one-line fix in `faults.sh` or the catalogue entry would stabilise it, but it changes what the entry measures, so I left it alone.

