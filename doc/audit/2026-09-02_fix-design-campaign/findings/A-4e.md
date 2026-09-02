# A-4e re-verification + gate-anchor drift matrix

Agent worktree: `/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a0c8400b7727aeeb0`
Branch: `verify/a-4e-and-gate-drift`, based on `4cbec52d`.
Commit made: `71ea3cef` — adds `tests/shell/check_gate_anchors.py` (only file touched).
No build was run at any point. `doc/KNOWN-ISSUES.md` was not edited.

Base gates (all three step-0 checks passed):
- `git log --oneline -1` → `4cbec52d Keep the one line that names the restore failure`
- `grep -n '^### A-4e' doc/KNOWN-ISSUES.md` → one hit, line 303
- `ls tests/shell/ | grep -c mutate_` → `6`

---

## §A — A-4e (`modify_flow_entry` ignored `priority`)

### A.1 Is the fix in base? — CONFIRMED (RUN)

```
$ git merge-base --is-ancestor c46c51e 4cbec52d ; echo $?
0
```

`git show --stat c46c51e` → `c46c51eb0d686966219ca866090b9c09352f2df1`, Adam010341,
Mon Aug 31 11:28:52 2026 +0800, *"modify_flow_entry: a priority names an entry, so send it
strict"*. Five files, 159 insertions / 3 deletions:

| file | ± |
|---|---|
| `doc/2026-01-02_ndt_api.md` | 14 |
| `include/ndt_core/routing_management/HttpRoutingStrategyBase.hpp` | 15 |
| `include/ndt_core/routing_management/P4RoutingStrategy.hpp` | 20 |
| `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp` | 41 |
| `tests/test_RoutingStrategies.cpp` | 72 |

### A.2 Which gate covers it — REFUTED as posed; the gate is not in `tests/shell/` (RUN)

```
$ grep -ln 'modify_strict\|strictModifyPath\|modifyAnEntry' tests/shell/mutate_*.sh
(no output)
```

**No `tests/shell/mutate_*.sh` gate covers A-4e.** The four mutations the entry credits
("四顆全殺") live in a python harness under the audit tree:
`doc/audit/2026-08-30_known-issues-wave/11b_mutation-harness/mutations.py`, entries **M6,
M7, M8, M9**. All five of their anchors resolve **exactly once** at base, counted with
python `.count()` (script: `…/254e6209…/scratchpad/a4e_anchors.py`):

| mutation | file | anchors | count |
|---|---|---|---|
| M6 post the literal `/stats/flowentry/modify` instead of `strictModifyPath()` | `src/…/HttpRoutingStrategyBase.cpp` | 1 | 1 ✅ |
| M7 delete the `if (priority == -1)` branch | same | 1 | 1 ✅ |
| M8 delete `P4RoutingStrategy::strictModifyPath()` | `include/…/P4RoutingStrategy.hpp` | 1 | 1 ✅ |
| M9 hoist `body["priority"]` above the -1 branch | `src/…/HttpRoutingStrategyBase.cpp` | 2 | 1, 1 ✅ |

Total non-unique anchors: **0**. The gate was not run (it compiles).

#### 🔴 A.2 defect in the instrument (RUN) — the A-4e gate is not re-runnable as committed

Two hard-coded paths, both committed into the repo:

- `mutations.py:13` — `W = "/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a2c2a6601f812a7eb"`
  and `run_one.sh:19` the same. `cmd_apply` reads and writes `os.path.join(W, path)`, so
  re-running the gate from any other checkout **mutates a different worktree than the one
  under test**, while the build happens wherever the driver runs. That worktree still
  exists (it is a live shared checkout another session writes to).
- `driver.sh:6` — `S=/tmp/claude-1000/…/258e9ef7-6035-4abb-b378-8b2ab1aa8200/scratchpad/mutrun`,
  a session-local scratchpad. `ls` → **No such file or directory**. `driver.sh` sources
  `"$S/run_one.sh"`, so the committed driver cannot run at all today.

Read-only cross-check: `diff -q` says this worktree's and `agent-a2c2a6601f812a7eb`'s
`HttpRoutingStrategyBase.cpp` are byte-identical right now — so a re-run would *appear* to
work while pointing at the wrong tree. **This is an observation of another session's working
tree, not of a commit.**

Proposed test (auditor decides): make `W` default to
`git rev-parse --show-toplevel` of the harness's own location, and have `run_one.sh` assert
that the tree it mutates is the tree it builds (compare the resolved paths, refuse on
mismatch). Nothing needs to be fixed here for the batch.

### A.3 Mechanism sentences — CONFIRMED, with two stale line references (READ)

At `4cbec52d`:

| entry claim | verdict | evidence |
|---|---|---|
| delete decides strict on `priority == -1` | ✅ | `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:158-164` |
| modify used to set `priority` then post non-strict | ✅ (historical) | now `:222-228`; the -1 branch posts `/stats/flowentry/modify`, otherwise `body["priority"]` + `post(strictModifyPath(), …)` |
| `strictModifyPath()` is virtual, base returns `modify_strict` | ✅ | `:236-239` returns `"/stats/flowentry/modify_strict"`; declared `include/…/HttpRoutingStrategyBase.hpp:90` |
| `P4RoutingStrategy` overrides it to keep non-strict | ✅ | `include/ndt_core/routing_management/P4RoutingStrategy.hpp:60` — `const char* strictModifyPath() const override { return "/stats/flowentry/modify"; }` |
| the proxy serves no `modify_strict` route | ✅ | `p4_proxy/proxy_agent/api_routes.py` has `/stats/flowentry/add` (:201), `/delete` + `/delete_strict` (:242-243, one handler), `/modify` (:276). No `modify_strict`. |
| the proxy reads `priority` from the body | ✅ | `api_routes.py:288-289` → `topology.modify_flow(dpid, match, actions, data.get("priority"))` |
| `topology_manager.modify_flow` uses `priority` on P4 | ✅ **partially** | `p4_proxy/proxy_agent/topology_manager.py:957`; used at `:986` via `p4_priority(priority)` on the ternary `flow_5tuple` path. On the `ipv4_lpm` path (`:999`) priority is **not** used — correct, an LPM table tiebreaks on prefix length. |

**Ryu, read from the installed env** `/home/adam/miniconda3/envs/ryu-env/lib/python3.8/site-packages/ryu`:
- `app/ofctl_rest.py:686-689` registers `POST /stats/flowentry/{cmd}` → `mod_flow_entry`;
  `:425-431` maps `'modify_strict' → OFPFC_MODIFY_STRICT`; the route comment is at `:147`.
  The 2026-07-29 guide's route list was simply incomplete — **the entry's §3.3 blocking
  check is discharged statically here.**
- `lib/ofctl_v1_3.py:1049-1071` `mod_flow_entry` reads `cookie` (default 0), `cookie_mask`
  (**default 0**), `table_id` (**default 0**), `idle_timeout`, `hard_timeout`, `priority`
  (default 0), `match`, `actions`.

**Does the strict body carry everything `modify_strict` needs?** The kernel sends
`dpid`, `match`, `actions`, `priority` only. Therefore:
- `cookie_mask = 0` ⇒ per OF1.3 no cookie filtering, i.e. cookie is not compared. Fine.
- `table_id = 0` ⇒ **the modify is scoped to table 0**. This is consistent, not a defect:
  `installAnEntry` (`:168-187`) also omits `table_id`, so every entry the kernel writes is
  in table 0 and every strict modify looks in table 0. It is an *unstated assumption* — an
  entry an app installed in another table could never be modified — worth one sentence in
  the API reference, not a fix.
- `priority` + full `match` are both present, which is exactly what OFPFC_MODIFY_STRICT
  compares. ✅

### A.4 Residual-risk hunt — NO NEW DEFECT OF THE A-4e SHAPE FOUND (READ)

Sites read, all at `4cbec52d`:

| site | file:line | verdict |
|---|---|---|
| `deleteAnEntry` | `src/…/HttpRoutingStrategyBase.cpp:150-165` | ✅ correct; the reference implementation |
| `installAnEntry` | `:168-187` | ✅ always sends `priority`; OpenFlow has no strict add |
| `modifyAnEntry` | `:190-229` | ✅ fixed |
| group add/delete/modify | `:246, :252, :258` | ✅ no strict/non-strict choice exists — `ofctl_rest.py:461-466` maps only `OFPGC_ADD/MODIFY/DELETE`; a group is named by `group_id`, not priority |
| meter add/delete/modify | `:264, :270, :276` | ✅ same, named by `meter_id` |
| `Controller` dispatch | `src/…/Controller.cpp:31-50` | ✅ passes `job.priority` to all three verbs |
| `FlowRoutingManager` | `src/…/FlowRoutingManager.cpp:99-133` | ✅ pass-through |
| `makeInstallJob` / `makeModifyJob` / `makeDeleteJob` | `src/ndt_core/http/HttpSession.cpp:910, :927, :940` | ✅ modify defaults `priority` to 0 (⇒ strict), delete to -1 (⇒ non-strict); documented in the fix comment at `HttpRoutingStrategyBase.cpp:213-221` |
| IntentTranslator install | `src/…/IntentTranslator.cpp:364-368`, `:733` | ✅ passes `priority` |
| IntentTranslator modify | `:394-398` | ✅ passes `priority` (`uint16_t`, so never -1 ⇒ always strict) |
| IntentTranslator **delete** | `:417-418` | ⚠️ see below |
| P4 delete on the proxy | `api_routes.py:242-243` | ✅ the proxy serves `delete_strict`, so the base class's strict delete does **not** 404 on P4 — the asymmetry with modify is real and handled |
| `p4_proxy` unroute/modify | `topology_manager.py:936-941`, `:984-990` | ✅ priority used on the ternary path, ignored on LPM, both documented in place |

**⚠️ Not a new defect, but the one live asymmetry worth naming:**
`IntentTranslator.cpp:417-418` calls `deleteAnEntry(dpid, match)` with the priority argument
omitted, so it defaults to `-1` (`include/…/FlowRoutingManager.hpp:90`) and goes **non-strict**
— an LLM-driven "delete this flow entry" removes *every* entry matching, at any priority.
This is by design and already written down at `p4_proxy/proxy_agent/api_routes.py:249-252`.
It is not a dropped priority: `DeleteFlowEntryTask`
(`include/ndt_core/intent_translator/LLMResponseTypes.hpp:722-732`) carries **no priority
field at all**, so there is nothing to drop. Reported for completeness only.

Minor, low confidence, no action proposed: `ModifyFlowEntryTask::priority`
(`LLMResponseTypes.hpp:674`) is a `uint16_t` with no default member initialiser and the
constructor sets only `type`; every construction path observed goes through `from_json`
(`:705`), which always assigns it.

### A.5 Heading vs status — CONFIRMED inconsistent; proposed wording (NOT applied)

Line 303 reads `### A-4e 🔴 …` while line 305 says `🟢 **RESOLVED（2026-08-31）**`.
Two further staleness items in the same entry:

1. The `機制` code block cites `HttpRoutingStrategyBase.cpp:195-201 —— 錯`. Post-fix, lines
   195-201 are `json body; body["dpid"] …` and the opening of the explanatory comment; the
   wrong code is gone. The block describes the **pre-fix** file.
2. The blocking `modify_strict` existence check (line 310 / the entry's §3.3) is now
   discharged in the installed Ryu source, not merely "live 200".

Proposed (auditor applies, or whoever owns the doc pass):

```
### A-4e 🟢 `modify_flow_entry` 忽略 `priority`，會改到別人的規則而且傷害存活（已修）
```

and, in the `機制` block, retitle the two snippets as *修前* / *修後*, replacing the second
with the shipped shape and its current line numbers:

```cpp
// HttpRoutingStrategyBase.cpp:222-228 —— 修後
if (priority == -1) return post("/stats/flowentry/modify", ...);  // 非 strict
body["priority"] = priority;
return post(strictModifyPath(), body, ...);   // OVS: modify_strict；P4 override 保 modify
```

Add one line: *變異閘不在 `tests/shell/`，在
`doc/audit/2026-08-30_known-issues-wave/11b_mutation-harness/`（M6–M9），且其 `W`／`S` 路徑
寫死，現況不可重跑。*

---

## §B — Gate-anchor drift across the campaign

Tool: `tests/shell/check_gate_anchors.py` (committed as `71ea3cef`). Read-only; no build.

```
python3 tests/shell/check_gate_anchors.py --revs-file <revs> # own gates per rev
python3 tests/shell/check_gate_anchors.py --gates-from <BR> --merge-with-base 4cbec52d \
        --revs-file <revs>                                   # simulate the batch
```

### Matrix (RUN) — rows = gates, columns = revs; cell = anchors resolved

`c0` `4cbec52d` · `c1` f-1 · `c2` b3 · `c3` f13 · `c4` f-6 · `c5` f14-f16-f4 · `c6` bx ·
`c7` F-8 · `c8` a-9 · `c9` a-4f · `c10` b-2b-b-4 · `c11` f15 · `c12` a4c · `c13` a-4d ·
`c14` t9-t10 · `c15` b-1-verify

Each gate read from the rev it is checked in (i.e. "does this branch, alone, hold together"):

| gate | c0 | c1 | c2 | c3 | c4 | c5 | c6 | c7 | c8 | c9 | c10-c15 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| mutate_ep4_gate_and_abort_evidence.sh | ok(7) | ok | ok | ok | ok | ok | ok | ok | ok | ok | ok |
| mutate_gate_exit_code.sh | ok(4) | ok | ok | ok | ok | ok | ok | ok | ok | ok | ok |
| mutate_lock_renew_expiry.sh | ok(6) | ok | ok | ok | ok | ok | ok | ok | ok | ok | ok |
| mutate_log_suffix_idempotent.sh | ok(6) | ok | ok | ok | ok | ok | ok | ok | ok | ok | ok |
| mutate_rate_denominator.sh | ok(6) | ok | ok | ok | ok | ok | ok | ok | ok | ok | ok |
| **mutate_topk_recursive_lock.sh** | ok(5) | ok | ok | ok | ok | ok | **MISSING:3** | ok | ok | ok | ok |
| mutate_a4f_sflow_power_cycle.sh | – | – | – | – | – | – | – | – | – | ok(6) | – |
| mutate_b3_historical_logging.sh | – | – | ok(10) | – | – | – | – | – | – | – | – |
| mutate_bx_flow_liveness.sh | – | – | – | – | – | – | ok(7) | – | – | – | – |
| mutate_f13_group_meter_existence.sh | – | – | – | ok(9) | – | – | – | – | – | – | – |
| mutate_f1_mininet_health_metrics.sh | – | ok(9) | – | – | – | – | – | – | – | – | – |
| mutate_f6_stale_table_carry_forward.sh | – | – | – | – | ok(8) | – | – | – | – | – | – |
| mutate_f8_declared_link_capacity.sh | – | – | – | – | – | – | – | ok(14) | – | – | – |
| mutate_harness_instruments.sh | – | – | – | – | – | – | – | – | – | – | ok(12) @c14 |
| mutate_lock_lease_all.sh | – | – | – | – | – | – | – | – | NO-ANCHORS | – | – |
| mutate_lock_lease_expiry.sh | – | – | – | – | – | – | – | – | ok(9) | – | – |
| mutate_lock_ownership.sh | – | – | – | – | – | – | – | – | ok(8) | – | – |
| mutate_optimistic_topology_reporting.sh | – | – | – | – | – | ok(20) | – | – | – | – | – |

`–` = the gate does not exist in that rev. 95/96 cells ok for the six pre-existing gates.

### Ranked collisions

**1 · 🔴 REAL, SILENT, SURVIVES EVERY MERGE ORDER**
`mutate_topk_recursive_lock.sh` × `fix/bx-flow-liveness`.
This is the gate over the KNOWN-ISSUES §E-2 fix (the recursive `shared_lock` deletion) — a
gate over a *deletion*, i.e. the one kind that cannot be replaced by a green suite.
`fix/bx-flow-liveness` adds a `sflow::FlowLivenessFilter filter` parameter:

| anchor (base) | branch replacement | file:line on bx |
|---|---|---|
| `    nlohmann::json flowInfo = getFlowInfoJson();` | `… = getFlowInfoJson(filter);` | `src/ndt_core/collection/FlowLinkUsageCollector.cpp:2433` |
| `FlowLinkUsageCollector::getFlowInfoJson()\n{\n    shared_lock lock(m_flowInfoTableMutex);` | `getFlowInfoJson(sflow::FlowLivenessFilter filter)` | `:2320` |
| `nlohmann::json flowInfo = getFlowInfoJson();` (mutation 3) | as above | `:2433` |

3 of 5 anchors dead. Mutations 4 and 5 still resolve. Under `--merge-with-base` this cell is
`MISSING:3` in **every** column — merge order cannot save it.
**Action: `fix/bx-flow-liveness` must re-point those three anchors before it merges.**

**2 · 🟡 ORDERING ARTEFACT — self-healing, but only if a-9's gate edit ships with a-9's code**
`mutate_lock_renew_expiry.sh` × `fix/a-9-lock-lease`. All **6** anchors are gone against
a-9's `include/ndt_core/lock_management/LockManager.hpp`. This is the collision already
found. `fix/a-9-lock-lease` ships a re-pointed copy of that gate, and **no other branch
touches `tests/shell/mutate_lock_renew_expiry.sh` or `LockManager.hpp`**, so after the merge
the repaired gate is what lands: `--gates-from fix/a-9-lock-lease --merge-with-base 4cbec52d`
is `ok(6)` in all 16 columns. It breaks **only** if a-9's gate edit is dropped or reverted
while its code change is kept.

**3 · 🟠 TEXTUAL MERGE CONFLICTS — git will stop, so these are loud, not silent**
- `fix/f-1-mininet-health-metrics` × `fix/f-6-stale-table-carry-forward` in
  `include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp` (1 conflict).
  `…/DeviceConfigurationAndPowerManager.cpp` and `tests/CMakeLists.txt` merge clean.
- `fix/F-8-declared-link-capacity` × `fix/a-4f-sflow-lost-on-power-cycle` in
  `tools/contract_test/spec.py` (1 conflict). `GraphTypes.hpp`,
  `TopologyAndFlowMonitor.cpp` and `HttpSession.cpp` merge clean between that pair.

Everything else — including `src/ndt_core/http/HttpSession.cpp`, which **8** of the 15
branches touch — merges clean pairwise with every gate anchor intact.

### Recommended merge order

1. Merge everything except `fix/bx-flow-liveness` in any order, **keeping the two conflict
   pairs apart** so the conflicts are resolved one at a time:
   `f-1` before `f-6` (resolve the `.hpp` conflict), and `F-8` before `a-4f` (resolve
   `spec.py`).
2. `fix/a-9-lock-lease` must merge **with its `tests/shell/mutate_lock_renew_expiry.sh`
   change**. Verify after merging:
   `python3 tests/shell/check_gate_anchors.py <merge-head> --gates mutate_lock_renew_expiry.sh`
3. `fix/bx-flow-liveness` last, and **only after its owner re-points the three
   `mutate_topk_recursive_lock.sh` anchors** to the `filter`-carrying signatures.
4. After the batch: `python3 tests/shell/check_gate_anchors.py <merge-head>` must exit 0.

Caveat (READ, not RUN): every merge above was simulated **pairwise** against the base.
Pairwise-clean does not prove all-together-clean; step 4 is the check that does.

### Tool self-evidence (RUN)

```
$ python3 tests/shell/check_gate_anchors.py 4cbec52d ; echo exit=$?
6/6 cells ok
exit=0

$ python3 tests/shell/check_gate_anchors.py fix/bx-flow-liveness \
      --gates mutate_topk_recursive_lock.sh ; echo exit=$?
mutate_topk_recursive_lock.sh  MISSING:3
  file  : src/ndt_core/collection/FlowLinkUsageCollector.cpp
  count : 0 (want 1)
  anchor:     nlohmann::json flowInfo = getFlowInfoJson();
  … (3 anchors)
0/1 cells ok
exit=1
```

Seen red on a real collision, not a fabricated one. Two states are deliberately **not**
passes and exit 2: a construct the parser cannot read, and a gate that yields no anchors at
all. `mutate_lock_lease_all.sh` hits the latter honestly — it is a driver that runs the
three lock gates and has no anchors of its own; those three are checked separately and are
`ok(9)`, `ok(8)`, `ok(6)`.

Known limits of the extractor, stated so the auditor can spot-check: it resolves the
gate's own applier idioms (`mutate`, `mutate_must_die`, `apply_exact`, `add_anchor`,
`run_mutation`, perl `s///`, `sed -i s///`, python heredocs and `s.replace()`), honours a
declared expected count, and where it cannot pin an anchor to one file it counts across all
paths the gate declares. Anchor totals were hand-checked against the six base gates
(7/4/6/6/6/5) before any branch was scanned.
