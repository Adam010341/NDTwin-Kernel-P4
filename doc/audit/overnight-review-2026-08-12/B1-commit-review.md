# B1 — Commit review, `b0a7bdc..5d53cf0` (2026-08-12 overnight)

Reviewer: agent B1 (static review). Base: `5d53cf0`, verified in an isolated worktree.
Interpreter for all Python: `/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python` (3.13, grpc 1.82.1).
C++ built fresh in-worktree at `build-b1/` (main tree's `build/` untouched).

## TL;DR

**All 16 commits reviewed. No P0 and no P1. Nothing in this range is broken, and no commit claims
something its diff does not do — with one exception, `3fc42ed`, whose conclusion is right but whose
stated mechanism is wrong.**

The range is unusually honest work: **five** of the sixteen commits exist wholly or partly to retract
or correct something the same author wrote earlier the same day (`14065b4`, `d1998f5`, `3a312e3`,
`caa6d5b`, `5d53cf0`), each naming the earlier defect explicitly rather than quietly overwriting it.
Three code fixes were checked by running the mutations their messages claim to survive
(`eace67c`, `e7d564b`, `32afeb9`); **every one of those claims held exactly.**

| Commit | Kind | Verdict | Severity |
|---|---|---|---|
| `902d1ab` | comments | 相符 | note |
| `c0f70d3` | doc | 相符 (superseded by its own follow-ups) | note |
| `78be6b6` | code (dead param removal) | 相符 | note |
| `3a63ce4` | merge | 相符 | note |
| `eace67c` | code (`--fail-with-body`) | 相符, mutation-verified | note |
| `14065b4` | doc (self-correction) | 相符 | note |
| `d1998f5` | doc (cadence attribution) | 相符 | note |
| `3a312e3` | code (502 message) | 相符 | note |
| `e7d564b` | code (subchannel pool) | 相符, both mutants verified | note |
| `949fcba` | merge | 相符 | note |
| `caa6d5b` | doc | 相符 | note |
| `32afeb9` | code (`connected_switch_dpids`) | 相符, mutation-verified | note |
| `c4505e9` | doc | 相符 | note |
| `3fc42ed` | file moves | **誇大／不精確 on mechanism**, right on conclusion | note |
| `f3759ae` | test guard | 相符 | note |
| `5d53cf0` | comments | 相符 | note |

**Things worth an eye, none urgent**

1. **`3fc42ed` cites the wrong branch of the test runner.** It justifies not putting manual scripts
   in `p4_proxy/tests/` on the grounds that "NO TESTS RAN" is a failure there. It is not — that
   branch (`l1_unit_tests.sh:194-197`) does not increment `FAILURES`. The one that does is at lines
   322-324 and covers a *different* directory. The placement decision is still correct, for a reason
   the message does not give. Details in the `3fc42ed` section.
2. **`eace67c`'s token helpers have a bundled-flag hole.** `keepsTheFailureBody` would report
   success for `curl --fail-with-body -sSf …`, where curl's last-one-wins would actually discard the
   body. The realistic regression is still caught. Note only.
3. **`3a312e3` still asserts on wording** (`msg.find("not work either")`) in a test whose stated
   purpose is to pin properties rather than wording. Brittleness only.
4. **F1 — pre-existing, not from this range:** `add_switch` silently discards a replacement client
   for an existing dpid. Currently unreachable as a bug; see Cross-cutting findings.
5. **F2 — the "385 Python tests" line is a snapshot**, and it already misled the brief for this
   review. See below.

**Baseline numbers (see "Opening checks" for the discrepancy analysis)**

- Python: **517 ran / 3 skipped / 0 failed** across 18 files. The briefed figure of **385 is stale
  and partial** — traced to `caa6d5b`, counts `p4_proxy/tests` only and predates `32afeb9`. Not a
  wrong-tree or wrong-interpreter symptom. Details in Opening check 5.
- C++: **546 tests / 68 test suites ran, 546 passed, 0 skipped, 0 failed** (exit 0), built fresh
  in-worktree. Matches the briefed expectation exactly.

---

## Opening checks

### 0. Worktree base — the trap two agents already hit

**[Observation]** The worktree's default branch head was `8b61cdc Add sharding`, with **no
`tests/` directory** — i.e. the upstream lab codebase, exactly as warned. `git reset --hard
5d53cf0` fixed it; `ls tests/` then showed 48 entries.

**[Inference]** Any agent that skips this step reviews a different codebase and every conclusion
is void. All findings below are against `5d53cf0`.

### 1. `grpc.use_local_subchannel_pool` — string and value

**[Observation]** `p4_proxy/proxy_agent/p4_client.py:68`:

```python
            grpc_addr, options=[("grpc.use_local_subchannel_pool", 1)])
```

The literal `grpc.use_local_subchannel_pool` appears verbatim in the installed gRPC C-core binary
(`venv/lib/python3.13/site-packages/grpc/_cython/cygrpc.cpython-313-x86_64-linux-gnu.so`), adjacent
to `src/core/client_channel/local_subchannel_pool.cc`. grpc version 1.82.1.

**[Inference]** The option name is spelled correctly and will be honoured rather than silently
ignored. It is an integer-valued arg (`GRPC_ARG_USE_LOCAL_SUBCHANNEL_POOL`); `1` = use a
channel-local pool, which is the intended "do not inherit global backoff" semantics. **PASS.**

### 2. `connected_switch_dpids()` — genuinely wired, not merely present

**[Observation]** Full chain verified by opening each link, not by grep alone:

- Definition: `p4_proxy/proxy_agent/topology_manager.py:1002-1031`. Body does real filtering under
  `self._liveness_lock`, returning dpids whose last probe `.get("ok") is not False` — a three-state
  rule (absent/None ≠ False).
- Caller: `p4_proxy/proxy_agent/api_routes.py:49`, inside the `@router.get("/v1.0/topology/switches")`
  handler at line 40.
- Consumer: `p4_proxy/proxy_agent/ryu_topology.py:76-84`, `render_switches(switch_dpids)` iterates
  the argument (`for d in sorted(switch_dpids)`) — it does not ignore it and re-derive the list.

**[Inference]** The endpoint really is fed by liveness state. **PASS.**

### 3. `curl --fail-with-body`

**[Observation]** `grep -Fn -- '--fail-with-body'` on the source (not just a loose `-f` match):
`src/ndt_core/power_management/P4PowerStrategy.cpp:82` issues
`curl -sS --fail-with-body -X POST --max-time 30 http://…`. There is no bare `-f`/`--fail` on that
command line.

**[Inference]** **PASS.** Note the in-source caveat at line 80: the option needs curl >= 7.76, and
an older curl rejects it. Followed up in the `eace67c` section.

### 4. Upstream drift

**[Observation]** After `git fetch origin`: `origin/main` = `8b61cdc Add sharding`;
`git log --oneline 28b8b13..origin/main | wc -l` = **1**.

**[Inference]** Upstream has **not** moved since the last check. The recorded merge state
(divergence at `28b8b13`, one upstream commit landing on the collector) is still current. **PASS.**

### 5. Test baseline — and why 385 is the wrong target number

**[Observation]** Python, venv interpreter, all 18 files, every file exit code 0:

| Set | Files | Ran | Skipped |
|---|---|---|---|
| `p4_proxy/tests/` (harness section 3) | 14 | 389 | 3 |
| `tests/python/` (harness section 3b) | 4 | 128 | 0 |
| **Total** | **18** | **517** | **3** |

The briefed expectation was 385. Provenance traced rather than assumed:

- `git log -S'385 條 Python 測試'` attributes the claim to **`caa6d5b`**, at
  `doc/p4_bmv2_support_plan.md:521`.
- At `caa6d5b`, `test_switch_state.py` had **20** test methods; at `5d53cf0` it has **24** —
  `32afeb9` added 4. `389 - 4 = 385`.
- `test_p4_client_writes.py` went 58 → 61 in `e7d564b`, which is *before* `caa6d5b`, so those 3
  were already counted in the 385.

**[Inference]** 385 is a correct-at-the-time count of **`p4_proxy/tests` only**. It (a) excludes the
128 tests in `tests/python/`, which the same harness runs as section 3b, and (b) predates
`32afeb9`. The live figure at `5d53cf0` is 389 / 517. **This is not evidence of a wrong tree or a
broken interpreter** — the arithmetic reconciles exactly and every file exits 0.

The 3 skips are each accounted for:

- `test_sflow_emitter.py` ×2 — `'p4info not built; run tools/test_workflow/l0_build_check.sh p4'`.
  A gitignored build artifact: absent in this worktree, **present in the main tree** at
  `p4_proxy/p4_src/build/ndtwin_switch.p4info.txt` (dated Aug 10). Worktree artifact, not a defect.
- `test_p4_client.py` ×1 — the declared `NDTWIN_L1_OPT_IN` live-switch test. Its skip message
  reports the proxy is currently up on :8081 and holds mastership, consistent with the live
  environment being held by another agent tonight.


---

## Per-commit review

Chronological (oldest first). 16 commits in range, none skipped.

### `902d1ab` — Warn that fixing VLAN on one side of the classifier key breaks the other

**Claim.** `vlanTci` is in the flow key but neither producer sets it; ingest guards on `vlan_vid`
while Ryu sends `dl_vlan`; the sFlow walk builds its key with no VLAN. Both are 0, so they agree.
Comments only, no behaviour change.

**Implementation.** Two comment blocks, one at the `vlan_vid` branch in `Classifier.cpp`, one at the
`FlowKey` construction in `FlowLinkUsageCollector::calFlowPathByQueried`. Zero executable lines
changed — verified: the diff touches only comment lines.

**[Observation]** Every factual assertion checks out at `5d53cf0`:
- `src/ndt_core/collection/Classifier.cpp:771` — `if (match.contains("vlan_vid"))`, the guard.
- `grep -rn "dl_vlan" src/ include/` returns **only comment lines**; no code reads it.
- `src/ndt_core/collection/Classifier.cpp:168` — `writeU16Be(out.bytes, 20, k.vlanTci);`, inside
  `packKey` (defined line 154). The "line 168" citation was accurate when written.
- The sFlow-side `FlowKey fk{}` sets `ipProto`, `ipv4Dst`, … and no VLAN field.

**Verdict: 相符 (accurate).** Severity: **note**. The asymmetry it documents is real and the
"half a fix is worse than none" framing is correct — populating the ingest side alone would make
VLAN-tagged rules unfindable from the walk.

**[Inference]** One self-inflicted defect, fixed later the same day by `5d53cf0`: the comment this
commit added cited `FlowLinkUsageCollector.cpp:2534`, but the *other* comment block in this same
commit pushed that line to **2542**. See `5d53cf0`.

### `c0f70d3` — Record what the live power-cycle actually did, including the three failures

**Claim.** Live power-cycle of s6; core requirement passed (9000/9000 packets on surviving
switches); three failures found: powerOn fails first attempt, the 502 step detail never reaches
either log, the twin briefly reports a dead switch as up (2 occurrences "exactly 120s apart",
mechanism unestablished).

**Implementation.** Doc-only, `doc/phase7_power_mechanism_design.md` +71 lines.

**Verdict: 相符 (accurate) at time of writing.** Severity: **note**. Two of its three findings were
subsequently *corrected by the author's own re-runs* — `14065b4` retracts "powerOn always fails the
first time", `d1998f5` retires the "120s apart" note as a 1 Hz sampling artefact. The commit
explicitly labels the mechanism "unestablished", so this is honest recording, not overclaiming.

### `78be6b6` — Stop asking callers for a routing manager the collector never held

**Claim.** The ctor took `shared_ptr<FlowRoutingManager>` and the class declared the member, but
the initializer list skipped it, so it was a default-constructed null for the collector's life;
nothing ever read it. Removing beats wiring: `FlowRoutingManager` already owns the collector, so a
back-pointer would close an ownership cycle.

**Implementation.** Parameter + member removed from header, ctor, `main.cpp`, and six test fixtures;
forward declaration dropped; §4.6 of `doc/test_coverage_gaps.md` rewritten.

**[Observation]** Every claim verified against the pre-state at `b0a7bdc`:
- The initializer list at `b0a7bdc` reads `m_sockfd, m_topologyAndFlowMonitor,
  m_deviceConfigurationAndPowerManager, m_eventBus, m_mode, m_classifier` — `m_flowRoutingManager`
  is genuinely **absent**.
- `git show b0a7bdc:src/…/FlowLinkUsageCollector.cpp | grep m_flowRoutingManager` → **no hits**.
  The name appears exactly once in the whole class, at the header declaration (line 325). "Never
  read" is exact.
- The cycle claim is real: `include/ndt_core/routing_management/FlowRoutingManager.hpp:193` holds
  `std::shared_ptr<sflow::FlowLinkUsageCollector> m_flowLinkUsageCollector;`.
- Six test fixtures updated — counted in the diff: `test_AllDestinationPaths`,
  `test_FlowTableConcurrency`, `test_GoldenFixture`, `test_SFlowEmitterRoundtrip`,
  `test_SFlowParsing`, `test_TopologyUrlAndPathJson`. Exactly six, as stated.

**Verdict: 相符 (accurate).** Severity: **note** (dead-parameter removal, net safety improvement —
it removes a null that would have crashed on first use). Suite is green at 546/546 after it.

**[Inference]** The reasoning for removal over wiring is sound on both counts given. No caller
outside the repo can be affected: this is a C++ constructor signature, so any external user would
fail to compile rather than silently misbehave.

### `3a63ce4` — Merge the collector's dropped routing-manager parameter removal

Merge commit for `78be6b6`. Verdict: **相符**, severity **note**.

### `c0f70d3` follow-ups: `14065b4` and `d1998f5`

**`14065b4` — Correct the live power-on account.** Retracts the "powerOn always fails the first
time" generalisation (it depends on how long the switch was down: straight off-and-on succeeds
first try; held down four minutes it fails at the pipeline step). Also flags that `2abf1e3`'s
replacement recovery instruction was itself never live-tested and returns 500.
Doc-only, +26/-5. **Verdict: 相符**, severity **note**. This is a self-correction that names the
earlier commit's defect precisely ("the same defect wearing different clothes").

**`d1998f5` — Pin down which thread reports a dead switch as up.** Doc-only, +50/-8.

**[Observation]** Its central code claim is verifiable and **true**:
`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:565-566`, inside `updateSwitches` (line 514),
sets `isUp = true` **and** `isEnabled = true` for every dpid the control plane lists, with no
liveness test on that path. The only `isUp = false` writes for a *vertex* are the topology-load
initialiser (line 243) and `setVertexDown` (line 2209), the latter called from the power strategies
and `DeviceConfigurationAndPowerManager` — i.e. a different thread, which is exactly the race
described.

**[Inference]** The method used — establishing the writer by its 5s→30s cadence changeover at
t≈90s rather than by picking a plausible call site — is the right one, and the commit says so.
Retiring the "120s apart" note is correct and prevents a wild-goose chase.

**Verdict: 相符 (accurate).** Severity: **note** as a doc commit; the *underlying defect* it
documents is real and is addressed proxy-side by `32afeb9` (below).

### `eace67c` — Let the proxy's account of a failed readopt reach the kernel log

**Claim.** `curl -sS -f` discarded the readopt 502's body, so the step name (mastership/pipeline/
clone/routes) never reached the kernel log, while the comment above the call claimed the opposite.
`--fail-with-body` keeps the body and still exits 22, so control flow is unchanged. The old
assertion could not have protected this because `-f` is a substring of `--fail-with-body`.

**Implementation.** One flag changed in `P4PowerStrategy.cpp:82`; the misleading comment corrected;
`tests/test_P4PowerStrategy.cpp` gains token-based helpers (`commandTokens`, `hasFlag`,
`failsOnNon2xx`, `keepsTheFailureBody`) and one new test,
`TheReadoptCurlKeepsTheProxysAccountOfWhatBroke`. The pre-existing substring assertion
`readopt.find("-f")` was replaced with `failsOnNon2xx(readopt)`.

**[Observation] — mutation, run rather than reasoned.** I reverted the flag to `curl -sS -f` in
this worktree, rebuilt, and ran the whole 546-test suite:

```
[  FAILED  ] P4PowerStrategyTest.TheReadoptCurlKeepsTheProxysAccountOfWhatBroke (0 ms)
[==========] 546 tests from 68 test suites ran.
[  PASSED  ] 545 tests.
[  FAILED  ] 1 test
```

Exactly the new test dies; `PowerOnRunsHelperThenReadoptInThatOrder` still passes, which is correct
— `-f` genuinely does satisfy the fail-on-non-2xx property that test asserts. Mutation reverted;
worktree confirmed clean afterwards.

**Verdict: 相符 (accurate), and the claim about the old assertion is demonstrably true.**
Severity: **note** (this is a fix, and a well-tested one).

**[Inference] — one small residual hole in the token helpers.** `commandTokens` splits on
whitespace, so it only sees *separate* tokens. `keepsTheFailureBody` returns true for a command
containing a **bundled** short flag, e.g. `curl -sSf --fail-with-body …`: the token is `-sSf`, so
`hasFlag(cmd, "-f")` is false and the "must not use plain -f" guard does not fire. Since curl treats
`-f` and `--fail-with-body` as mutually exclusive with last-one-wins, `curl --fail-with-body -sSf …`
would discard the body while the helper still reported it kept. Severity: **note** — the plausible
regression (someone bundling `f` into `-sS` and dropping the long flag) *is* caught, because
`failsOnNon2xx` also goes token-wise and would then return false, failing two tests. Recording it
because the helper's stated purpose is precisely to tell these two flags apart.

### `3a312e3` — Name the recovery that was measured to work, not the second one that was not

**Claim.** The 502 has now named two recoveries that do not work. Off-then-on was written from
reasoning, never run, and returns 500 live. What recovered the switch was POSTing the readopt
endpoint directly (four tries, ~75s). The mechanism is the global subchannel pool inheriting
backoff. The test now pins the property rather than the wording.

**Implementation.** The `OpResult::failure(502, …)` message now names
`POST http://{P4_PROXY_IP_AND_PORT}/p4/readopt/{dpid}` explicitly, warns off both bad recoveries,
and points at the response body for the failing step. Test assertions changed from
`msg.find("power off")` to `msg.find("/p4/readopt/7")` plus a new `msg.find("not work either")`.

**Verdict: 相符 (accurate).** Severity: **note**. The commit is unusually honest — it names its own
predecessor's defect ("the same defect wearing different clothes") rather than quietly replacing the
sentence. The dpid interpolation is real, so the message names the actual switch, and the test
pins that (`/p4/readopt/7` for dpid 7) rather than a generic substring.

**[Inference] — mild irony, worth one line.** The commit says the test "pins the property … rather
than the wording of whichever sentence is current", but `EXPECT_NE(msg.find("not work either"),
npos)` is still a wording match: rephrasing to "off-then-on also fails" would redden the test
without any property changing. The other two assertions are genuinely property-shaped. Severity:
**note**, brittleness only.

### `e7d564b` — Stop a readopted switch inheriting the dead client's reconnect backoff

**Claim.** The root cause of "powerOn succeeds after 1s down, fails after 4 minutes" is gRPC's
process-global subchannel pool. The liveness poller probes the dead client every 2s, so a 4-minute
outage is ~120 failed connects driving that address's backoff toward the 120s cap; `readopt_switch`'s
fresh client inherits it. `grpc.use_local_subchannel_pool` gives each client its own pool. Measured
0.00s vs 32.56s to READY on grpc 1.82.1. Costs nothing because each switch has its own address.
"Both mutants die — removing the option and misspelling it each turn two of the three new tests red."

**Implementation.** One-line change to `p4_client.py` (`grpc.insecure_channel(grpc_addr,
options=[("grpc.use_local_subchannel_pool", 1)])`) plus a long rationale comment, and a new
`ChannelOptionsTest` class with three tests that exercise the **real** `__init__` (the rest of the
file bypasses it with `__new__`).

**[Observation] — supporting constants verified.**
- `p4_proxy/proxy_agent/topology_manager.py:249` — `LIVENESS_PROBE_INTERVAL_S = 2.0`. The "every 2s
  / ~120 connects over four minutes" arithmetic is sound.
- `p4_proxy/proxy_agent/main.py:54,71` — `DEFAULT_GRPC_PORT_BASE = 50050` and
  `grpc_addr=f'localhost:{port_base + dpid}'`, so dpids 1..10 give localhost:50051..50060. The
  "each switch has its own address, nothing legitimate was being shared" claim holds.
- New tests sit **above** the `if __name__ == "__main__"` guard, so they are collected. (This repo
  has shipped uncollected tests before; checked explicitly.)

**[Observation] — mutation, both run rather than reasoned.** Against the venv interpreter:

| Mutant | Result |
|---|---|
| option removed → `grpc.insecure_channel(grpc_addr)` | `Ran 61 tests … FAILED (failures=2)` |
| option misspelled → `..._poool` | `Ran 61 tests … FAILED (failures=2)` |

Both kill exactly `test_the_channel_does_not_share_the_process_global_subchannel_pool` and
`test_two_clients_for_one_address_each_get_their_own_pool`, leaving
`test_the_target_address_still_reaches_grpc` green. **"two of the three" is exact.** Both mutations
reverted; `git diff` clean afterwards.

**[Observation] — the silent-ignore premise is real.** The commit justifies pinning the literal
option string on the grounds that gRPC ignores unrecognised options without error. Checked directly
on grpc 1.82.1: constructing a channel with `grpc.use_local_subchannel_poool` **and** with
`grpc.total_nonsense_option_xyz` both succeed with no exception and no warning.

**Verdict: 相符 (accurate).** Severity: **note** — this is the highest-quality commit in the range:
root cause identified by measurement, one mechanism changed, and the test genuinely resists both
the obvious regressions.

### `949fcba` — Merge the gRPC subchannel-pool fix for Phase 7 powerOn

Merge commit for `e7d564b`. Verdict: **相符**, severity **note**.

### `caa6d5b` — Close out Phase 7 in the plan, and correct what the live run disproved

**Claim.** Phase 7 live verification done; subchannel-pool mechanism promoted from hypothesis to
measurement; two corrections to earlier same-day text; `intelligent_router.py` removed from the
Phase 8 "stray scripts" list because `stack.sh` runs it, `test_route_install_gate.py` reads it by
relative path, `.env` points at it, and "sixteen documents" mention it.

**Implementation.** Doc-only, +57/-16 across two plan documents.

**[Observation]** The "not stray" argument is verifiable and every limb of it holds:
- `tests/python/test_route_install_gate.py:35` —
  `ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")`, which
  from `tests/python/` resolves to the repo root. Relative-path read confirmed.
- `tools/test_workflow/components.env:81` — `: "${RYU_APP:=$KERNEL_DIR/intelligent_router.py}"`.
- Markdown files mentioning `intelligent_router` → **exactly 16.** The "sixteen documents" figure is
  precise, not rounded.

**Verdict: 相符 (accurate).** Severity: **note**.

**[Inference]** This commit is the source of the stale "385" figure (Opening check 5). The claim was
true when written; it has since drifted by 4 because `32afeb9` added tests. Not a defect in this
commit — but it is why the overnight brief carried a wrong target number, so it is worth knowing
that this line is a snapshot and not a maintained invariant.

### `32afeb9` — Stop offering the kernel switches the proxy cannot reach

**Claim.** `topology_switches` passed `switches.keys()` — every client startup ever built — breaking
`render_switches`' documented contract. Killing a process does not remove its entry, so a dead bmv2
was reported connected while `/p4/switch_state` on the same object said `probe_ok: false`. Only a
definite `False` excludes; "never probed" is not death (three-state, matching `p4LivenessFor`).
Tested through the endpoint because the defect was in the caller.

**Implementation.** New `TopologyManager.connected_switch_dpids()` (filters under
`self._liveness_lock`); `api_routes.topology_switches` switched to it; new `ConnectedSwitchListTest`
with 4 tests driven through `asyncio.run(api_routes.topology_switches())`.

**[Observation] — mutation, run rather than reasoned.** I restored `switches.keys()` in
`api_routes.py` and ran the file:

```
FAIL: test_a_switch_that_comes_back_is_reported_again
FAIL: test_a_switch_whose_probe_failed_is_not_reported_as_connected
Ran 24 tests … FAILED (failures=2)
```

So the stated design goal — "a helper-level test would stay green while someone put
`switches.keys()` back" — is **demonstrably achieved**. Mutation reverted.

**[Observation] — the accept path is covered.** `test_a_switch_that_answers_its_probe_is_reported`
and `test_a_switch_with_no_probe_yet_is_reported` both assert a switch **is** listed. This matters:
a filter bug that returned `[]` unconditionally would pass a refusals-only suite while blacking out
the entire fabric.

**Verdict: 相符 (accurate).** Severity: **note**. Correct fix, correctly placed (proxy side), well
tested.

**[Inference] — "should replace, can only add", checked as instructed.** Asked of every ingest path
this commit touches:
- `self.switches` — entries are never removed, which is precisely the defect being worked around
  rather than fixed. The commit is explicit about this and filters at read time instead. Acceptable:
  the dict doubles as "switches startup knew about", which `readopt_switch` needs (it returns
  `unknown-switch` for a dpid not in it).
- `_last_probe` — written only by the prober (`topology_manager.py:975`), never cleared on
  re-adoption. After a successful readopt a stale `False` withholds the switch for up to
  `LIVENESS_PROBE_INTERVAL_S` (2.0s) until the next probe. **Safe direction** and documented.
- `readopt_switch` genuinely **replaces**: `self.switches[dpid] = new` under `_liveness_lock`, then
  stops the old client. It does *not* go through `add_switch`. Verified by reading, because this is
  exactly where the repo's habitual bug would sit.

### `c4505e9` — Record the twin-liveness fix and the one transient it does not cover

**Claim.** Re-ran the 10 Hz / 150 s experiment after `32afeb9`: eighteen up-blips became one, and
the dead switch no longer appears in `/v1.0/topology/switches`. The remaining blip is a bounded
transient at power-off, attributed to two composing policies. The attribution is labelled
"consistent rather than measured".

**Implementation.** Doc-only, +36/-1.

**Verdict: 相符 (accurate).** Severity: **note**. Notable for what it does *not* claim: it separates
the measured result (18 → 1) from the unproven attribution, and gives its actual evidence for the
latter (two transients of 9.2s and 8.1s, both under the 12s cap and unequal — the signature of a
randomly-phased window rather than a fixed timer). This is the observation/inference split the
project asks for, applied without being asked.

### `3fc42ed` — Give the hand-run diagnostics a home that is not the repository root

**Claim.** Five manual scripts move to `p4_proxy/reference/`. Deliberately **not** `p4_proxy/tests/`,
because `l1_unit_tests.sh` globs that directory and "reports a file that runs no tests as NO TESTS
RAN — **a failure in that runner**, not a skip". `test_10_routes.py` pointed at port 8080 while the
agent binds 8081, so it had never run. `test_modify_error.py` resolved paths from the repo root.

**Implementation.** Five files moved, `p4_proxy/reference/README.md` added, port 8080→8081, both
paths in `test_modify_error.py` re-resolved from `__file__`, and two stale comment references to
`dump_table.py at the repo root` updated (in `p4_client.py` and `test_p4_client_writes.py` —
comment-only, no behaviour).

**Verdict: 誇大／不精確 (overstated on the mechanism, right on the conclusion).** Severity: **note**.

**[Observation]** The runner does **not** behave as described *for the directory the message names*.
In `tools/test_workflow/l1_unit_tests.sh`, section 3 (the `p4_proxy/tests/test_*.py` glob):

```
194	        elif [[ $ran -eq 0 ]]; then
195	            # Nothing was collected at all.
196	            echo "${Y}NO TESTS RAN${N} ${D}(missing dependency? see $log)${N}"
197	            grep -E "SkipTest|ModuleNotFound" "$log" | head -3 | sed 's/^/      /'
```

There is **no `FAILURES=$((FAILURES + 1))`** in that branch — it is yellow and informational. The
`NO TESTS RAN` branch that *does* increment `FAILURES` is at lines 322-324, and that one belongs to
**section 3b**, which globs `tests/python/` and `tests/shell/` — a different directory from the one
the commit message is arguing about.

**[Inference]** The conclusion ("that would have broken the suite") is nonetheless **correct**, via a
route the message does not name: these scripts talk to a live fabric with `requests`, so with no
fabric they exit non-zero and hit the `rc -ne 0` branch at line 190, which *does* increment
`FAILURES`. With a fabric up they would exit 0 and be merely yellow. So the decision is right and
the file placement is right; only the stated mechanism is wrong. Recording it because this repo has
been bitten repeatedly by reasoning that fits the outcome without being the actual mechanism.

**[Observation] — the port claim.** `test_10_routes.py` targeted 8080; `components.env:52` declares
`P4_PROXY_URL:=http://localhost:8081`. The claim that the script could never have worked is
consistent with the configured port. I did **not** re-verify by connecting — the live environment is
held by another agent tonight.

### `f3759ae` — Let WriteDeadlineTest skip like its ten siblings instead of erroring

**Claim.** Every other test class in the file carries `@skipUnless(HAVE_P4RUNTIME, …)`; this one did
not, so on a protobuf-less interpreter its three tests raise instead of skipping, and the runner
reports a failed file rather than a partial skip. "With the guard, all 61 tests skip and nothing
errors; with it removed, exactly three error, all in WriteDeadlineTest."

**Implementation.** One line: the decorator added above `class WriteDeadlineTest`.

**[Observation]** Both counts are exact:
- `p4_proxy/tests/test_p4_client_writes.py` has **11** `unittest.TestCase` classes and **11**
  `@unittest.skipUnless(HAVE_P4RUNTIME` decorators at `5d53cf0` — so before this commit exactly
  **ten** siblings carried the guard. "Ten siblings" is literally right.
- `WriteDeadlineTest` (line 809) contains exactly **3** test methods, matching "exactly three error".
- The file's total is 61, matching "all 61 tests skip".

**Verdict: 相符 (accurate).** Severity: **note**.

### `5d53cf0` — Point the VLAN warning at symbols, after its line number rotted the same hour

**Claim.** The comment cited `FlowLinkUsageCollector.cpp:2534`; the companion note added in the same
commit (`902d1ab`) pushed it to 2542, so the citation was stale before anyone read it. Now names
`FlowLinkUsageCollector::calFlowPathByQueried` with a grep anchor having exactly one hit, and
`packKey` rather than "line 168". "Both symbols were checked to exist — the first two names this
commit tried, `calculatePathsForFlows` and `serialiseKey`, were invented and neither is in the
codebase."

**Implementation.** Comment-only, `Classifier.cpp` +6/-4 net.

**[Observation]** Every claim independently re-verified at `5d53cf0`:
- Grepping `ndtClassifier::FlowKey fk{}` in `src/ndt_core/collection/FlowLinkUsageCollector.cpp` →
  **exactly one hit, line 2542.** Both the "only hit" promise and the "pushed to 2542" diagnosis are
  correct.
- `FlowLinkUsageCollector::calFlowPathByQueried` is real: declared
  `include/ndt_core/collection/FlowLinkUsageCollector.hpp:294`, defined
  `src/ndt_core/collection/FlowLinkUsageCollector.cpp:2493` — and 2542 is inside it.
- `packKey` is real: `src/ndt_core/collection/Classifier.cpp:154`, and the `vlanTci` write at line
  168 is inside its body.
- Searching `src/` and `include/` for `calculatePathsForFlows` and `serialiseKey` → **no hits.** The
  commit's self-report that it invented two names before checking is accurate.

**Verdict: 相符 (accurate).** Severity: **note**. The right repair: it replaces a line number with a
grep anchor whose uniqueness was verified, which is the only form of citation that does not rot.

---

## Cross-cutting findings

### F1 — Pre-existing latent: `add_switch` silently drops a replacement client

**Not introduced in this range.** `p4_proxy/proxy_agent/topology_manager.py:379-384`:

```python
    def add_switch(self, dpid, client):
        if dpid not in self.switches:
            self.switches[dpid] = client
```

If the dpid is already present the new `client` is **discarded with no error and no log** — the
canonical "should replace, can only add" shape. Severity: **note**, because it is not currently
reachable as a bug: the only non-test caller is `main.py:128` during startup, once per dpid, and the
one path that legitimately replaces a client (`readopt_switch`) assigns
`self.switches[dpid] = new` directly and never goes through this method. Recorded so that anyone who
later routes a re-registration through `add_switch` knows it will fail silently.

### F2 — The "385 Python tests" line is a snapshot, not an invariant

`doc/p4_bmv2_support_plan.md:521` states 385 Python tests run. That was exact at `caa6d5b` and is
now 389 for that directory (517 counting `tests/python/`). It has already misled one consumer — the
overnight brief. Severity: **note**. Either drop the number or say which directory and which commit
it was counted at.

### What I did not check

- Nothing was run against the live fabric: no `stack.sh`, `tc`, `mnexec`, `ndtwin-p4-power`, and no
  curl to any localhost service. The live environment is held by another agent tonight, and every
  live-dependent claim in these commits is therefore reported as **consistent with configuration**
  rather than re-measured.
- CI status was not treated as evidence: all 8 checks have been red since `b0a7bdc` because the
  GitHub Actions quota is exhausted ("Failing after 2s"), which is not a code signal.
- The worktree was left clean. Every mutation described above was reverted and confirmed with
  `git status` / `git diff`; the only untracked path is my own `build-b1/` build directory.
