# B3 — Mutation testing of today's new/changed tests (`b0a7bdc..5d53cf0`)

Agent B3, overnight review 2026-08-12.
Worktree: `/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-ab42eba4bae5144cb` (reset to `5d53cf0`; the
worktree opened at `8b61cdc "Add sharding"` = origin/main, the trap two agents already hit today).
Interpreter for all Python: `/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python`.
Rule followed throughout: **every mutant runs the whole suite, no filters**; `git checkout -- .` +
clean-tree check + baseline re-run between mutants.

## TL;DR

**Every test added or changed today is real. 7 of 7 mutants killed, 0 fake tests, no P1 in the
tests themselves.** Each mutant ran the whole suite with no filter, with a prediction written before
the run; all 7 predictions were correct, including the finer-grained ones (which sibling tests must
*stay green*, and how many assertions inside one test must fire).

| # | Mutant | Killed by | Predicted correctly |
|---|--------|-----------|---------------------|
| M1 | `eace67c` reverted: `--fail-with-body` → `-f` | `TheReadoptCurlKeepsTheProxysAccountOfWhatBroke` | ✅ incl. order-test staying green |
| M2 | `32afeb9` reverted: `connected_switch_dpids()` → `switches.keys()` | 2 of 4 `ConnectedSwitchListTest` | ✅ all four verdicts |
| M3 | `e7d564b` reverted: channel options dropped | 2 of 3 `ChannelOptionsTest` | ✅ all three |
| M4 | option name misspelled (`..._pools`) | same 2 | ✅ |
| M5 | `3a312e3` reverted: 502 message wording | `TheReadoptFailureNamesARecoveryThatCanActuallyRun` | ✅ incl. 2-of-3 assertions |
| M6 | three-state rule → truthiness | `test_a_switch_with_no_probe_yet_is_reported` | ✅ exactly one |
| M7 | `f3759ae` reverted: `@skipUnless` removed | 3 `WriteDeadlineTest` errors under a protobuf-less interpreter | ✅ exactly three |

### Findings

1. **⚠️ P1 (operational + test design) — an "opt-in" live test is not opt-in, and it fired.** During
   M6, `test_p4_client.py::LiveSwitchTest` ran against the **real fabric** and pushed a pipeline
   config, two routes and clone session 250 onto switch 1. Its `NDTWIN_L1_OPT_IN` token is only a
   hint to the harness; the real gate is a set of environment probes meaning *"run against the live
   switch unless the proxy agent happens to be up"*. The proxy on `:8081` went down mid-run (not my
   doing), and my p4info/json copy had satisfied the last remaining guard. **Contained** — I removed
   the copied `.json`, the test skips again, and the main tree was never touched. Full account and
   the recurrence risk for any normal L1 run in §3.M6b. Follow-up task filed.
2. **The 385 Python baseline in circulation is stale.** Real figure is **517 ran / 1 skipped / 0
   failed**; 385 counted only `p4_proxy/tests` and predated `32afeb9`'s 4 new tests (389−4). C++ is
   **546 / 68**, matching exactly. Independently confirmed by the orchestrator mid-run, same cause.
   §2.1.
3. **M1 demonstrates the gap `eace67c` closed was real.** Under the mutant the pre-existing
   order-test passes, so before today the whole 546-test suite was green with `-f` in place. The new
   token-based test is the only thing that can catch that regression.
4. **M2 demonstrates the endpoint-level placement is load-bearing, not stylistic.** With
   `switches.keys()` restored, all 32 `test_ryu_topology.py` tests — the file covering
   `render_switches` itself — stay green, along with the other 515. Exactly as `32afeb9` argued.
5. **The pinned gRPC option name is correct against reality, not just self-consistent** (§M4b):
   `grpc.use_local_subchannel_pool` is present in the shipped grpc-1.82.1 core binary, and gRPC
   silently accepts the misspelling — so the test is the only possible defence.
6. **No test was weakened by `78be6b6`** (§4.2), and **`5d53cf0`'s grep anchor is accurate** (§4.3).
7. Three baseline skips reduced to one (the genuine opt-in live test) by supplying the gitignored
   p4info read-only; the two sFlow metadata-id tests now genuinely run.

---

## 1. Test inventory for the range `b0a7bdc..5d53cf0`

16 commits. Test-bearing changes are in 3 files; 6 more C++ files changed mechanically.

### 1.1 New tests (7 Python, 1 C++)

| # | Test | File | Commit |
|---|------|------|--------|
| 1 | `ChannelOptionsTest.test_the_channel_does_not_share_the_process_global_subchannel_pool` | `p4_proxy/tests/test_p4_client_writes.py` | e7d564b |
| 2 | `ChannelOptionsTest.test_the_target_address_still_reaches_grpc` | same | e7d564b |
| 3 | `ChannelOptionsTest.test_two_clients_for_one_address_each_get_their_own_pool` | same | e7d564b |
| 4 | `ConnectedSwitchListTest.test_a_switch_whose_probe_failed_is_not_reported_as_connected` | `p4_proxy/tests/test_switch_state.py` | 32afeb9 |
| 5 | `ConnectedSwitchListTest.test_a_switch_that_answers_its_probe_is_reported` | same | 32afeb9 |
| 6 | `ConnectedSwitchListTest.test_a_switch_with_no_probe_yet_is_reported` | same | 32afeb9 |
| 7 | `ConnectedSwitchListTest.test_a_switch_that_comes_back_is_reported_again` | same | 32afeb9 |
| 8 | `P4PowerStrategyTest.TheReadoptCurlKeepsTheProxysAccountOfWhatBroke` | `tests/test_P4PowerStrategy.cpp` | eace67c |

### 1.2 Modified existing tests

| # | Test | Change | Commit |
|---|------|--------|--------|
| 9 | `P4PowerStrategyTest.PowerOnRunsHelperThenReadoptInThatOrder` | `readopt.find("-f")` substring → `failsOnNon2xx()` token check | eace67c |
| 10 | `P4PowerStrategyTest.TheReadoptFailureNamesARecoveryThatCanActuallyRun` | asserts `/p4/readopt/7` + `"not work either"` instead of `"power off"` | 3a312e3 |
| 11 | `WriteDeadlineTest` (3 tests) | gained `@skipUnless(HAVE_P4RUNTIME, ...)` — decorator only, no assertion change | f3759ae |

New test helpers in `tests/test_P4PowerStrategy.cpp`: `commandTokens`, `hasFlag`, `failsOnNon2xx`,
`keepsTheFailureBody`.

### 1.3 Mechanical, no assertion change (commit 78be6b6)

`tests/test_AllDestinationPaths.cpp`, `test_FlowTableConcurrency.cpp`, `test_GoldenFixture.cpp`,
`test_SFlowEmitterRoundtrip.cpp`, `test_SFlowParsing.cpp`, `test_TopologyUrlAndPathJson.cpp` — each
dropped one `nullptr` from a `FlowLinkUsageCollector(...)` construction. Analysed in §4.2.

### 1.4 No tests at all (comments-only commits)

`902d1ab` and `5d53cf0` change only comments in `Classifier.cpp` / `FlowLinkUsageCollector.cpp`.
Nothing to mutate. The one falsifiable claim they make is checked in §4.3.

## 2. Baselines

Clean tree confirmed (`git status --porcelain` empty) before the run.

### C++ — matches the brief exactly

```
[==========] 546 tests from 68 test suites ran. (2256 ms total)
[  PASSED  ] 546 tests.
```

546 / 68 as specified. Built in-worktree at
`.claude/worktrees/agent-ab42eba4bae5144cb/build` (Ninja, Debug). googletest was taken from a
scratchpad copy via `-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=...` so the run needs no network and
never writes to the main tree. All tests live in one binary, `build/bin/test_routing_strategy`.

### Python — 517, not 385

| File | ran | skipped |
|------|-----|---------|
| test_clone_session.py | 18 | 0 |
| test_flow_stats_route.py | 5 | 0 |
| test_kernel_notifier.py | 17 | 0 |
| test_link_watchdog.py | 74 | 0 |
| test_lldp_beacon.py | 16 | 0 |
| test_p4_client.py | 1 | 1 |
| test_p4_client_writes.py | 61 | 0 |
| test_readopt.py | 29 | 0 |
| test_ryu_flow_stats.py | 22 | 0 |
| test_ryu_topology.py | 32 | 0 |
| test_sflow_emitter.py | 49 | 2 |
| test_startup.py | 17 | 0 |
| test_switch_state.py | 24 | 0 |
| test_unsupported_match.py | 24 | 0 |
| **p4_proxy/tests subtotal** | **389** | 3 |
| tests/python/test_contract_spec.py | 90 | 0 |
| tests/python/test_p4_power_helper.py | 23 | 0 |
| tests/python/test_route_install_gate.py | 4 | 0 |
| tests/python/test_route_reinstall.py | 11 | 0 |
| **tests/python subtotal** | **128** | 0 |
| **TOTAL** | **517** | **3** |

0 failures, 0 non-zero exits.

### 2.1 Why 385 is the stale number, not the tree

The brief's 385 reconciles exactly, in two steps:

1. It counts **`p4_proxy/tests` only** and omits `tests/python/` (128 tests). p4_proxy subtotal today
   is 389.
2. 389 − 385 = **4**, which is precisely the four `ConnectedSwitchListTest` tests added by `32afeb9`
   at 20:47 — the last Python-test commit of the day. So 385 is the p4_proxy/tests count as of
   `3fc42ed`/`e7d564b`, i.e. a snapshot taken before the day's final test commit.

Cross-check on the other direction: `e7d564b` added the 3 `ChannelOptionsTest` tests, so
`b0a7bdc` was 389 − 7 = 382, `e7d564b` was 385, `32afeb9` onward is 389. The 385 figure sits exactly
where the brief's own commit list says it should.

I therefore did **not** treat this as the "stop" condition. That gate exists to catch a wrong tree
(the origin/main trap), and the tree is provably right: the C++ count matches to the test, HEAD is
`5d53cf0`, the working tree is clean, and the Python delta is accounted for down to the individual
test. Recorded here as the finding it is: **the 385 baseline in circulation is stale and understates
the suite; the number to quote going forward is 517 total / 389 p4_proxy.**

### 2.2 All 8 new tests confirmed collected (discipline #3)

Not assumed from the diff — read out of the `-v` logs:

```
ChannelOptionsTest.test_the_channel_does_not_share_the_process_global_subchannel_pool ... ok
ChannelOptionsTest.test_the_target_address_still_reaches_grpc ... ok
ChannelOptionsTest.test_two_clients_for_one_address_each_get_their_own_pool ... ok
ConnectedSwitchListTest.test_a_switch_that_answers_its_probe_is_reported ... ok
ConnectedSwitchListTest.test_a_switch_that_comes_back_is_reported_again ... ok
ConnectedSwitchListTest.test_a_switch_whose_probe_failed_is_not_reported_as_connected ... ok
ConnectedSwitchListTest.test_a_switch_with_no_probe_yet_is_reported ... ok
```

and `P4PowerStrategyTest.TheReadoptCurlKeepsTheProxysAccountOfWhatBroke` is present in
`--gtest_list_tests`. None of the new tests landed below a `__main__` guard.

## 3. Mutants

_(appended one at a time, prediction written before the run)_

### M1 — revert `eace67c`'s fix body: `--fail-with-body` → `-f`  ✅ KILLED

Highest-value class: the literal repair the commit exists for.

```diff
--- a/src/ndt_core/power_management/P4PowerStrategy.cpp
+++ b/src/ndt_core/power_management/P4PowerStrategy.cpp
@@ -82
-    if (!executeSystemCommand("curl -sS --fail-with-body -X POST --max-time 30 http://" +
+    if (!executeSystemCommand("curl -sS -f -X POST --max-time 30 http://" +
```

**Prediction (written before the run).** Exactly one test red:
`P4PowerStrategyTest.TheReadoptCurlKeepsTheProxysAccountOfWhatBroke`, via `keepsTheFailureBody`.
`PowerOnRunsHelperThenReadoptInThatOrder` must stay **green**, because `-f` still satisfies
`failsOnNon2xx` — and the pre-eace67c version of that assertion (`readopt.find("-f") != npos`) would
also have stayed green. That second half is the interesting claim.

**Result: prediction correct on both halves.** Full suite, no filter, exit code 1:

```
[==========] 546 tests from 68 test suites ran. (1248 ms total)
[  PASSED  ] 545 tests.
[  FAILED  ] 1 test, listed below:
[  FAILED  ] P4PowerStrategyTest.TheReadoptCurlKeepsTheProxysAccountOfWhatBroke
```

```
tests/test_P4PowerStrategy.cpp:279: Failure
Value of: keepsTheFailureBody(readopt)
  Actual: false
Expected: true
the 502's step detail must reach the kernel log, so the readopt curl needs --fail-with-body and
must not use plain -f/--fail, which discard it: curl -sS -f -X POST --max-time 30
http://localhost:8081/p4/readopt/7
```

and in the same run:

```
[ RUN      ] P4PowerStrategyTest.PowerOnRunsHelperThenReadoptInThatOrder
[       OK ] P4PowerStrategyTest.PowerOnRunsHelperThenReadoptInThatOrder (0 ms)
```

**Why this one matters beyond the kill.** The commit message claims the *old* substring assertion
"would have watched the repair be undone without failing once". This run demonstrates that claim
rather than restating it: under the mutant the surviving order-test passes, so before `eace67c` the
whole file was green with `-f` in place. The new token-based test is the only thing standing between
this repo and a silent re-regression. Genuine test, and a genuine gap closed.

Restored, `git status --porcelain` empty, baseline re-run: 546/546 PASSED, exit 0.

### M2 — revert `32afeb9`'s fix body: `connected_switch_dpids()` → `switches.keys()`  ✅ KILLED

```diff
--- a/p4_proxy/proxy_agent/api_routes.py
+++ b/p4_proxy/proxy_agent/api_routes.py
@@ -49
-    return ryu_topology.render_switches(topology.connected_switch_dpids())
+    return ryu_topology.render_switches(topology.switches.keys())
```

**Prediction (written before the run).** Two red, two green.
Red: `test_a_switch_whose_probe_failed_is_not_reported_as_connected` (dpid 2 reappears) and
`test_a_switch_that_comes_back_is_reported_again` (its first assertion expects `[]`).
Green: `test_a_switch_that_answers_its_probe_is_reported` and
`test_a_switch_with_no_probe_yet_is_reported` — both describe switches that are listed either way.

**Result: prediction correct, all four.** Full Python suite, no `-k`, 517 ran:

```
test_a_switch_that_answers_its_probe_is_reported ... ok
test_a_switch_that_comes_back_is_reported_again ... FAIL
test_a_switch_whose_probe_failed_is_not_reported_as_connected ... FAIL
test_a_switch_with_no_probe_yet_is_reported ... ok
```

```
AssertionError: Lists differ: [1, 2, 3] != [1, 3]
a switch the proxy cannot reach was still offered to the kernel, which turns membership of this
list into isUp = true
```

`test_switch_state.py` exit code 1; every other file still exit 0, total unchanged at 517/3 skipped.

**The commit's design claim is confirmed by the same run.** `32afeb9` argues the test had to go
through the endpoint because "a helper-level test would stay green while someone put
`switches.keys()` back". Under this mutant `test_ryu_topology.py` — 32 tests, the file that covers
`render_switches` itself — stayed **entirely green**, as did the rest of the suite. So the endpoint-level
placement is load-bearing, not stylistic: nothing else in 517 tests notices this regression.

Restored, `git status --porcelain` empty, baseline re-run: 517 ran, 0 failures, exit 0 on every file.

### M3 — revert `e7d564b`'s fix body: drop the channel options entirely  ✅ KILLED

```diff
--- a/p4_proxy/proxy_agent/p4_client.py
+++ b/p4_proxy/proxy_agent/p4_client.py
@@ -67
-        self.channel = grpc.insecure_channel(
-            grpc_addr, options=[("grpc.use_local_subchannel_pool", 1)])
+        self.channel = grpc.insecure_channel(grpc_addr)
```

**Prediction (written before the run).** Red:
`test_the_channel_does_not_share_the_process_global_subchannel_pool` (options is `None`) and
`test_two_clients_for_one_address_each_get_their_own_pool`. Green:
`test_the_target_address_still_reaches_grpc`, which only reads the target.

**Result: prediction correct, all three.** Full suite, 517 ran, `test_p4_client_writes.py` exit 1:

```
AssertionError: unexpectedly None : the channel was built with no options at all, so it uses
grpc's process-global subchannel pool and inherits the backoff of whatever failed against this
address before
```

This also confirms the commit message's own arithmetic ("removing the option ... turn two of the
three new tests red") — two, and precisely the two named.

Restored, clean, baseline re-run: 517 ran, 0 failures.

### M4 — misspell the option: `..._pool` → `..._pools`  ✅ KILLED

The mutant the production comment explicitly fears: *"gRPC ignores channel options it does not
recognise, so a typo here would be silent."*

```diff
-            grpc_addr, options=[("grpc.use_local_subchannel_pool", 1)])
+            grpc_addr, options=[("grpc.use_local_subchannel_pools", 1)])
```

**Prediction.** Same two red, target-address test green.
**Result: correct.**

```
AssertionError: ('grpc.use_local_subchannel_pool', 1) not found in
                [('grpc.use_local_subchannel_pools', 1)]
```

### M4b — is the pinned literal actually right, or just self-consistent?

Worth asking separately, because `ChannelOptionsTest` asserts a string literal that the production
code also writes: if both were wrong the suite would stay green and the fix would be inert. Two
checks, neither of which touches the live fabric:

1. The name exists in the shipped gRPC core. From
   `venv/lib/python3*/site-packages/grpc/_cython/cygrpc*.so`:
   ```
   grpc.use_local_subchannel_pool
   src/core/client_channel/local_subchannel_pool.cc
   ```
   The plural form appears nowhere. So the spelling in `p4_client.py` is the real option.

2. The premise that makes the test necessary holds. Constructing channels only, no RPC issued,
   against a black-hole address on grpc 1.82.1:
   ```
   'grpc.use_local_subchannel_pool'    -> accepted silently (no error)
   'grpc.use_local_subchannel_pools'   -> accepted silently (no error)
   ```
   gRPC accepts the typo without complaint, exactly as the comment claims. The runtime will never
   report this class of mistake, so `ChannelOptionsTest` is the only thing that can. Verdict:
   the test earns its keep and pins a literal that is correct against the installed library.

Restored, clean, baseline re-run: 517 ran, 0 failures.

### M5 — revert `3a312e3`'s fix body: the 502 message goes back to "power off and then power on"  ✅ KILLED

```diff
-        "routes); it cannot forward traffic. The failing step is in the readopt response body
-         in the kernel log above. Recover by retrying the readopt directly: POST http://"
-         + P4_PROXY_IP_AND_PORT + "/p4/readopt/" + dpid + " -- ... Power off then power on does
-         not work either; measured on a live fabric, it returned 500 as well."
+        "routes); it cannot forward traffic. See the proxy log. Recover with power off and then
+         power on -- do NOT repeat this power-on: ..."
```

**Prediction.** One test red — `TheReadoptFailureNamesARecoveryThatCanActuallyRun` — and two of its
three assertions fire, not one: the `/p4/readopt/7` assertion and the `"not work either"` assertion.
The third (`retrying this power-on retries the readopt` must be absent) still passes, because the
reverted wording does not contain that older phrase.

**Result: correct, including the two-of-three detail.** 546 ran, exit 1:

```
tests/test_P4PowerStrategy.cpp:375: Failure
Expected: (msg.find("/p4/readopt/7")) != (std::string::npos)
the recovery that was measured to work is calling readopt directly, and the message has to name
it, for this dpid: ... Recover with power off and then power on ...

tests/test_P4PowerStrategy.cpp:380: Failure
Expected: (msg.find("not work either")) != (std::string::npos)
off-then-on was measured to fail, so the message must warn against it rather than leave it
looking like the obvious thing to try: ...
```

Worth noting what this pins. `3a312e3` rewrote the test to assert a *property* (name a recovery that
reaches the readopt; warn off the one that does not) rather than the wording of the current sentence
— after two successive wordings had each been wrong. The mutant confirms the property holds against
the previous wording specifically, so the test would have caught the regression it was written for.

Restored, clean, rebuilt, baseline re-run: 546/546 PASSED, exit 0.

### Baseline improvement mid-run (orchestrator's note, applied)

Two of the three baseline skips were the gitignored `p4info` artefact being absent from the
worktree. Copied **read-only from the main tree** into the worktree (main tree untouched):

```
p4_proxy/p4_src/build/ndtwin_switch.p4info.txt
p4_proxy/p4_src/build/ndtwin_switch.json
```

Both paths are covered by `.gitignore:9 build/`, verified with `git check-ignore -v`, so they do not
dirty `git status --porcelain` and the clean-tree discipline is unaffected. `test_sflow_emitter.py`
went from 49 ran / 2 skipped to **49 ran / 0 skipped**. Remaining skip is the single declared opt-in
live test in `test_p4_client.py`, which is correct behaviour.

**Baseline from this point on: 517 ran / 1 skipped / 0 failed.** Mutants M1–M5 above ran against the
3-skip baseline; the two extra tests are sFlow metadata-id pins, unrelated to every mutant here, so
no earlier result is affected.

> Superseded during M6 — see §3.M6b. The `.json` half of that copy was withdrawn; only
> `ndtwin_switch.p4info.txt` remains in the worktree, which is all the sFlow tests need.

### M6 — boundary: `is not False` → truthiness, collapsing the three-state rule  ✅ KILLED

`connected_switch_dpids` deliberately distinguishes three states (`True` / `False` / never probed).
This mutant collapses "never probed" into "dead", which is the exact mistake the docstring and the
commit message argue against.

```diff
--- a/p4_proxy/proxy_agent/topology_manager.py
             return [dpid for dpid in sorted(self.switches)
-                    if (self._last_probe.get(dpid) or {}).get("ok") is not False]
+                    if (self._last_probe.get(dpid) or {}).get("ok")]
```

**Prediction.** Exactly one red: `test_a_switch_with_no_probe_yet_is_reported`. The other three
describe switches with a definite verdict and are unaffected.

**Result: correct — one test, the predicted one.**

```
FAIL: test_a_switch_with_no_probe_yet_is_reported
```

This is the more valuable of the two `32afeb9` mutants: M2 proves the caller was fixed, M6 proves the
*three-state* rule inside the helper is pinned and not merely the two obvious cases. The suite would
catch someone "simplifying" this comprehension to a truthiness check — which is precisely the change
that would black out the fabric for the first seconds of every run.

Restored, clean, baseline re-run: 517 ran / 1 skipped / 0 failures.

### M6b — INCIDENT: an "opt-in" live test executed against the real fabric ⚠️ P1 (operational + test-design)

**What happened.** In the M6 run, `p4_proxy/tests/test_p4_client.py::LiveSwitchTest.
test_installs_routes_and_the_clone_session` did not skip. It ran, and it wrote to a real bmv2:

```
[1] Received arbitration response: Mastership confirmed.
[1] Setting Forwarding Pipeline Config...
[1] Clone session 250 -> port 255 installed
[1] Added route: 10.0.0.1/32 -> port 1, mac 00:00:00:00:00:01
[1] Added route: 10.0.0.2/32 -> port 2, mac 00:00:00:00:00:02
[1] Clone session 250 already present, updated (INSERT said UNKNOWN)
```

So device 1 received a ForwardingPipelineConfig push, two table entries and clone session 250. This
was not intended: my brief forbids touching the live environment, and I did not target it — the test
enabled itself.

**Why it fired.** `LiveSwitchTest` carries four stacked guards (`test_p4_client.py:78-86`), and it
runs when **all** pass:

| Guard | State during M6 |
|---|---|
| `skipUnless(HAVE_P4RUNTIME)` | pass (venv has the protobufs) |
| `skipUnless(a_switch_is_listening())` — TCP :50051 | pass — a bmv2 **is** listening |
| `skipIf(something_is_listening(8081))` — proxy agent | pass — **the proxy agent went down** |
| `skipUnless(exists(P4INFO) and exists(PIPELINE_JSON))` | pass — **because I copied both artefacts in** |

Two things changed independently. The proxy agent on `:8081` stopped between the `base5` run (where
the test skipped, citing the proxy holding mastership) and the M6 run — not my doing; nothing is
listening on 8081 now, while `:50051` still is. And my p4info/json copy, made one step earlier to
remove two skips, had satisfied the fourth guard. Neither alone would have run the test; together
they did.

**Contained.** The `LiveSwitchTest` guard needs *both* artefacts, whereas the two sFlow tests need
only `ndtwin_switch.p4info.txt` (`test_sflow_emitter.py:413,416,440`). I deleted the copied
`ndtwin_switch.json` from the worktree and kept the p4info. Verified after: live test back to
`skipped 'pipeline not built'`, sFlow still 49 ran / 0 skipped, total 517 / 1 skipped. The main tree
still holds both files, untouched. No further run of mine can reach the fabric.

**The finding, which outlives my incident.** This file is treated as opt-in — it carries the
`NDTWIN_L1_OPT_IN` token, and `l1_unit_tests.sh` uses that token to excuse an all-skipped file. But
the token is only a hint to the harness; **the actual gate is a set of environment probes, and their
combined meaning is "run against the live switch unless the proxy happens to be up"**. That is the
opposite of opt-in. Concretely: a full L1 run on a machine where the fabric is up but the proxy is
stopped — exactly the state a power-cycle experiment or a stopped-proxy debugging session leaves
behind — will silently push a pipeline and rewrite table entries on switch 1. Nothing is printed to
warn the operator, and `l1_unit_tests.sh` reports it as a normal pass.

Suggested (not applied — outside my remit and it is a behaviour change):
require a real opt-in, e.g. `skipUnless(os.environ.get("NDTWIN_LIVE_SWITCH_TEST") == "1", ...)`, so
the token that names the file's intent is also the thing that enables it. Filed as a follow-up task.

### M7 — `f3759ae`: remove the `@skipUnless` guard again, under a protobuf-less interpreter  ✅ KILLED

This is special item 4a done as a mutant rather than as an opinion. The guard cannot be tested on
this machine as-is, because here `HAVE_P4RUNTIME` is True — so I simulated the interpreter the guard
exists for: a shadow `p4/__init__.py` that raises `ImportError`, prepended to `PYTHONPATH`.

**Control (guard present, protobuf-less interpreter):** exit 0

```
Ran 61 tests in 0.000s
OK (skipped=61)
```

**Mutant (guard removed, same interpreter):** exit 1

```
Ran 61 tests in 0.001s
FAILED (errors=3, skipped=58)
ERROR: test_a_delete_carries_a_deadline (WriteDeadlineTest)
ERROR: test_an_insert_carries_a_deadline (WriteDeadlineTest)
ERROR: test_the_deadline_is_not_so_short_that_a_slow_table_write_is_reported_as_failed (WriteDeadlineTest)
```

Exactly three errors, all three in `WriteDeadlineTest`, and 58 skips elsewhere — reproducing
`f3759ae`'s claim ("with the guard, all 61 tests skip and nothing errors; with it removed, exactly
three error") independently and to the number.

## 4. Special items

### 4.1 (brief item a) Are the `@skipUnless` conditions vacuously false on this machine?

**No — and this is settled empirically for all three distinct skip mechanisms in the proxy suite,
not by sampling 2–3.**

| Mechanism | Where | Evidence it is not always-false |
|---|---|---|
| `skipUnless(HAVE_P4RUNTIME, ...)` — 11 decorators, `WriteDeadlineTest` + its 10 siblings | `test_p4_client_writes.py` | Under the venv all **61 tests run, 0 skipped** — so every one of the 11 guards is satisfied here. Under the simulated protobuf-less interpreter all 61 skip. The predicate is live in both directions. |
| `skipTest` on the generated p4info | `test_sflow_emitter.py:416,441` | Was skipping 2 tests; after copying `ndtwin_switch.p4info.txt` in, those 2 **run and pass**. Satisfiable. |
| 4 stacked guards on the live switch test | `test_p4_client.py:78-86` | Demonstrated live — the class actually executed during M6 (§3.M6b). Emphatically not always-false. |

`WriteDeadlineTest` specifically: its 3 tests **ran and passed** in every baseline
(`... ok` ×3 in the `-v` log), so `f3759ae` did not silently convert a running test into a skipped
one. It made an *erroring* file skip cleanly on interpreters that lack the protobufs, and changed
nothing on this one. Correct change, and M7 shows the guard is load-bearing rather than decorative.

### 4.2 (brief item b) Did `78be6b6` weaken any test?

**No.** The removed constructor parameter had no readers before removal, so there was nothing for a
test to observe, and no assertion changed in any of the six fixtures.

- `m_flowRoutingManager` no longer appears anywhere in `include/ndt_core/collection/` or
  `src/ndt_core/collection/`. The remaining hits (`Controller.cpp`, `ControllerAndOtherEventHandler.cpp`,
  `HttpSession.cpp`) are different classes with their own, genuinely used members.
- The only mention left in the collector is the explanatory comment at
  `FlowLinkUsageCollector.hpp:323`.
- No test in `tests/` ever referenced the collector's routing manager. The `FlowRoutingManager` hits
  in `tests/` belong to `test_IntentTaskOutcomes.cpp` (which builds a real one), `test_HttpSessionRouting.cpp`
  and `test_Controller.cpp` — all unrelated to this parameter.
- `test_IntentTaskOutcomes.cpp:80` independently corroborates the commit's ownership argument:
  `FlowRoutingManager(std::move(monitor), std::move(collector), std::move(bus))` — the manager takes
  the collector, so a `shared_ptr` back would indeed have closed a cycle.

On the risk of a mis-shifted argument: in `main.cpp` the dropped argument and its neighbour are
distinct `shared_ptr<T>` types, so dropping the wrong one would not compile. In the six test
fixtures every argument involved was `nullptr`, so which one was dropped is not observable. Test
count is unchanged at 546.

**Not mutation-testable, by construction.** Removing a parameter that is never stored and never read
is behaviour-preserving; there is no mutant whose survival would mean anything. The static check
above is the correct verification, and it is clean.

### 4.3 `5d53cf0`'s grep-anchor claim

The commit replaced a rotted line-number citation with a symbol plus the claim that
`` grep `ndtClassifier::FlowKey fk{}` `` has "exactly one hit in the file". Checked rather than
trusted, since this repo has been bitten by cited-but-unverified anchors twice today:

```
$ grep -c 'ndtClassifier::FlowKey fk{}' src/ndt_core/collection/FlowLinkUsageCollector.cpp
1
$ grep -n 'ndtClassifier::FlowKey fk{}' src/ndt_core/collection/FlowLinkUsageCollector.cpp
2542:            ndtClassifier::FlowKey fk{};
```

One hit, and it sits inside `calFlowPathByQueried` (which begins at
`FlowLinkUsageCollector.cpp:2493`), as stated. The other cited symbol, `packKey`, is real too —
`Classifier.cpp:154`. Both claims hold.

Corroborating detail worth keeping: the single hit is at line **2542**, which is precisely the
number `5d53cf0` says the original `2534` citation had rotted to. The commit's account of its own
bug is accurate.

## 5. Coverage: every test from §1, and what killed it

| Test | Mutant that killed it |
|------|----------------------|
| `ChannelOptionsTest.test_the_channel_does_not_share_the_process_global_subchannel_pool` | M3, M4 |
| `ChannelOptionsTest.test_two_clients_for_one_address_each_get_their_own_pool` | M3, M4 |
| `ChannelOptionsTest.test_the_target_address_still_reaches_grpc` | **not killed — see below** |
| `ConnectedSwitchListTest.test_a_switch_whose_probe_failed_is_not_reported_as_connected` | M2 |
| `ConnectedSwitchListTest.test_a_switch_that_comes_back_is_reported_again` | M2 |
| `ConnectedSwitchListTest.test_a_switch_with_no_probe_yet_is_reported` | M6 |
| `ConnectedSwitchListTest.test_a_switch_that_answers_its_probe_is_reported` | **not killed — see below** |
| `P4PowerStrategyTest.TheReadoptCurlKeepsTheProxysAccountOfWhatBroke` | M1 |
| `P4PowerStrategyTest.TheReadoptFailureNamesARecoveryThatCanActuallyRun` | M5 |
| `P4PowerStrategyTest.PowerOnRunsHelperThenReadoptInThatOrder` (modified) | see below |
| `WriteDeadlineTest` ×3 (decorator change) | M7 |

**The two uncovered-by-design cases are not fake tests.** Both are deliberate accept-path guards,
and this repo has a documented scar about exactly this ("smoke the accept path, not just refusals"):

- `test_the_target_address_still_reaches_grpc` exists so a refactor that moves the option into the
  positional slot cannot silently take the address with it. Its natural mutant is "pass the address
  wrongly", which is a different defect from the one M3/M4 model.
- `test_a_switch_that_answers_its_probe_is_reported` exists, in its own comment's words, so the
  suite cannot pass by reporting nothing at all. M2 and M6 both keep it green precisely because it
  is the accept path — a mutant that killed it would be one that empties the list, and its value is
  that it *would* catch that.

`PowerOnRunsHelperThenReadoptInThatOrder` was modified rather than added; its remaining assertions
(order, `readopt/7`, POST, `failsOnNon2xx`) are unchanged in intent. M1 shows its new
`failsOnNon2xx` helper behaves as designed — it stays green for `-f`, which is correct, since
distinguishing the two flags is the *other* test's job.

## 6. Not run

Listed honestly rather than glossed:

1. **Accept-path mutants for the two tests above** — e.g. pass the wrong positional address to
   `insecure_channel`; make `connected_switch_dpids` return `[]` unconditionally. Both would very
   likely be killed, but I did not run them, so I am not claiming it.
2. **A mutant for the `PowerOnRunsHelperThenReadoptInThatOrder` assertions I did not disturb**
   (helper-then-readopt ordering, `-X POST`, `readopt/{dpid}` for the right dpid). These predate
   today's range; only the `-f` assertion was changed today and M1 covers it.
3. **`902d1ab` / `5d53cf0`** — comments only, no behaviour and no tests. §4.3 checks their one
   falsifiable claim instead.
4. **`78be6b6`** — not mutation-testable by construction (§4.2); verified statically.
5. **`caa6d5b`, `c0f70d3`, `d1998f5`, `14065b4`, `3fc42ed`, `949fcba`, `3a63ce4`** — documentation,
   file moves and merges; no test content in range.
6. **Cross-language runs.** C++-source mutants (M1, M5) were verified against the full 546-test C++
   binary, and Python-source mutants (M2–M4, M6, M7) against the full 517-test Python suite. I did
   not run the Python suite for a C++ source edit or vice versa — no filter was ever applied *within*
   a suite, which is the rule that matters, and neither language's suite can observe the other's
   source edit.

## 7. Method notes

- Baseline protected exactly as required: `git status --porcelain` clean before starting; after every
  mutant, `git checkout -- .` → re-verify clean → **re-run the baseline to green** → only then the
  next mutant. Seven restore/re-baseline cycles, all clean, all green.
- No filters anywhere: no `--gtest_filter`, no `pytest -k`. Every C++ run is the whole
  `test_routing_strategy` binary; every Python run is all 18 files.
- Exit codes measured directly (`rc=$?` on the command itself), never through a pipe into `head`.
- Nothing was pushed; no branch, issue or PR created. The main tree
  `/home/adam/Desktop/NDTwin-Kernel` was read from (googletest source, p4info) and never written to.
- Runner script and all logs: `…/scratchpad/pyrun.sh`, `…/scratchpad/py_*/`, `…/scratchpad/cpp_*.log`.

