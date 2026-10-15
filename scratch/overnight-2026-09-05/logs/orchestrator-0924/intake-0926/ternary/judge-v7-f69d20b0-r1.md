**Verdict: MERGE AFTER FIXES.** No logic change is needed. Against the rulings as your brief quotes them, the owner rule and the boot exception are correct, the contextvar can't leak, and no other production writer can produce the empty-match catch-all. Three things before the squash to public main:
- **Fix the 409 wording.** The message and remedy claim more than the code does, and they become public API text once merged.
- **Get Adam to confirm commit 3 as well as commit 4.** Both go beyond (a-iii) as quoted.
- **Correct the module counts in the intake record.** The handbacks say "43"; the logs show 46, 47 and 47.

**Scope I did not cover.** I did not read INTAKE.md, the judge-ternary-design r2 file or DESIGN.md, because my operating rules bar audit documents. The spec I judged against is the brief's quotation of the rulings, so **the N1 scope correction is unchecked**. Quote N1 to me, or have it checked separately. I did read the two worker handbacks, because they are the report under audit. Nothing was executed.

## Findings

**MEDIUM 1. The 409 text overclaims on NDTwin's own pipeline.**
- `p4_client.py:1429-1431` says "<table> is written by NDTwin itself". `api_routes.py:938-939` says "this table is written by NDTwin itself; write a table of your own pipeline instead".
- NDTwin's pipeline has three tables (`ndtwin_switch.p4:329,350,366`). Production writes only `ipv4_lpm` and `flow_5tuple`. Nothing in `proxy_agent/` writes `l2_forward`.
- Scenario: on the default fabric, an operator POSTs an ARP entry into `MyIngress.l2_forward`. They get 409 saying NDTwin writes that table (false). They are told to use "your own pipeline", which doesn't exist on a baseline switch: every table there is refused.
- Fix:
  - Message: "is owned by NDTwin (every table of NDTwin's own pipeline is NDTwin's)".
  - Remedy, keyed by binding source:
    - baseline: "NDTwin's own pipeline takes routes through /stats/flowentry/*; this endpoint writes a package pipeline's tables"
    - package: "roles.ipv4_route gives this table to NDTwin; write another table of the package's pipeline"
  - Keep the remedy short so the 200-byte test still holds.

**MEDIUM 2. Ruling scope: commit 3 (`ab430cdb`) is also outside (a-iii).**
- It adds `bind_routes(None)` to `test_exact_one_element_list.py`'s `a_client`.
- Handback 1, Flag 1 says the design named only two doubles and missed this one.
- The "A+B" decision came from the orchestrator, not from Adam. The worker flagged only commit 4 for Adam.
- The edit itself is faithful (basic_tunnel without roles, so None). It still needs the same confirmation as commit 4.

**LOW. Comments and text that claim more than the code does:**
- `p4_client.py:140-144` describes `replay` as "a stored API entry being put back". No such replay exists (`ENTRY_SOURCE_REPLAY` has no caller), and `/p4/table_entry` is explicitly not journaled (`api_routes.py:841`). Reword it as reserved.
- `p4_client.py:1451-1454` credits `tests/test_p4_client_writes.py` with the owned-table "no request" assertion. That assertion is in `tests/test_table_entry_owner.py`.
- `tests/test_foreign_pipeline.py:194-195` says None-bound NDTwin p4info is "a switch … production can never produce". It can: `app_package.py:344` compares resolved paths, so a package that carries its own copy of NDTwin's compiled program is foreign, and with no roles it binds None.
- `p4_client.py:130-131`: "a rule in ipv4_lpm is rewritten by the next route install" only holds for (switch, host)/32 entries. The real reason is ownership.
- `api_routes.py:856-861`: the docstring example is a POST into `MyIngress.ipv4_lpm`. FastAPI publishes the docstring as the OpenAPI description, and on NDTwin's pipeline that example is now a 409.
- `p4_client.py:1504-1505` (pre-existing) labels any empty match "(default action)". Log 12:23 shows `table entry insert: MyIngress.flow_5tuple (default action)` for exactly the catch-all this PR is about (on an unbound switch). Choose the label from `entry.is_default_action`.
- No CHANGELOG line. The worker's reason ("would have to describe the defect") doesn't hold, because the PR's own code comments already describe it. The behaviour change deserves one line: every table of NDTwin's pipeline, including `l2_forward`, now answers 409.

**LOW. Consequences to confirm (they follow the ruling):**
- On NDTwin's pipeline `l2_forward` is now writable by nobody. Before, only the generic API could fill it.
- On a fabric that skips routes, an owner-ndtwin route table is written by nobody either: NDTwin skips it and the API refuses it (`main.py:1794-1806` already discloses this).

**LOW. Test and gate gaps:**
- No mutant targets alias handling, explicit-`source` resolution (`:1466`), the unknown-source `ValueError`, or reset-outside-`finally`.
- `test_an_explicit_boot_source_installs_the_default` and `test_an_unknown_source_is_a_valueerror_and_writes_nothing` have only ever been red for `TypeError` (log 01; handback 1 says so), never for their own reason.
- The C1 control's application is unchecked. The shell ignores the Python assert's exit code (no `set -e`), so a missing anchor would print "held". `check_gate_anchors` offsets this (log 05: ok(16)).
- The remedy test (`test_table_entry_owner.py:523`) checks only where the key starts, not where the value ends.
- The owner suite's package binding is hand-built (`:164-167`). `route_binding.resolve` would refuse it on its own `a_p4info` (no action_refs; `route_binding.py:268-272`). So no owner test goes through `main.build_p4_client` with a real roles package.

## Your seven questions

**1. Owner rule.** Correct.
- insert, modify and delete are all refused, for named-field entries and defaults alike.
- Aliases are resolved by `_table_by_name` and compared against the resolved table's name and alias (`:1391`).
- Baseline: every table is refused. Package: only the bound table when its owner is ndtwin. Owner package or no roles: nothing is refused.
- Two deliberate widenings, both still refusals with nothing written: a malformed spec on an owned table gets 409 rather than 400, and a truthy non-bool default is refused even at boot (handback flags 3 and 4).
- The boot exception is exactly (a-i): boot source, package binding, `default_action is True`, empty match, insert or modify (`:1419-1424`).
- The contextvar is safe:
  - The API passes no source (`api_routes.py:926`).
  - The with-block wraps one synchronous call (`main.py:661-662`) and the reset is in `finally`.
  - Startup runs the block with no await inside it.
  - Readopt is a sync `def` endpoint (`api_routes.py:657`). anyio 4.15.1 runs every threadpool call in a fresh `copy_context()` (`anyio/_backends/_asyncio.py:2698-2705, 1100`), so the boot marking can't reach a concurrent request. FastAPI's threadpool is not a risk.
  - Latent hazard: a task created *inside* the block would inherit "boot". None is created today.

**2. Other writers.** None can produce an empty match.
- Route writes are always /32 (`topology_manager.py:1067,1211,1348`).
- 5-tuple writes need at least one key (`needs_five_tuple` / `five_tuple_keys`, `topology_manager.py:336-367`) and use all-ones masks (`p4_client.py:1799`).
- The remaining `Write` sites are PRE objects (clone sessions, multicast groups). `reference/*.py` and `tools/p4_health/vs_trial.py` are not proxy paths.
- `/stats/flowentry/add` can still write a broad rule (e.g. `ip_proto` only). That is NDTwin's own OpenFlow writer, outside (a).

**3. Regressions.** None found.
- `install_initial_routes` and route updates go through `insert_ipv4_route`, not the generic writer, so the owner check never sees them.
- Package boot entries are applied only on foreign switches (`main.py:2020`, `:1762`). The `foreign` set (`:1907`) uses the same predicate as `route_binding_for`.
- p4_health bring-up C: `convert.py:728-734` strips the owned table's match entries and keeps the default, which the exception admits.
- Readopt after a power-cycle: the baseline route refill is untouched. Foreign owner-ndtwin switches get the package entries (default allowed) and then `install_initial_routes(only_dpid)`.
- Logs 12 and 13 are green, including startup, readopt and the real converter package (13/5/5/5 applied, defaults sent as MODIFY).

**4. Commit 4 (`6435f75a`).**
- The new expectation is what the ruling implies: BASELINE plus "every table" means 409 before the builder runs.
- The TERNARY refusal on the real compiled p4info is still asserted at the builder (`test_foreign_pipeline.py:215-218`). The writer-level 501 is still covered through the route (`test_table_entry_route.py:351-357`).
- The only thing lost is "real ternary p4info + `write_table_entry` + 501", which production can no longer produce on NDTwin's pipeline.
- Log 11's red is genuine. Its traceback line numbers (1350/1209) match main's file, not the branch's (1472/1258).

**5. Fixture edits.** All three `bind_routes(None)` edits model what `route_binding_for` builds for a foreign switch with no roles (`main.py:311-313`). One caveat: `test_foreign_pipeline`'s shared BASELINE `a_client` holds foreign p4infos, which production can't build. It's harmless only because those tests call `build_table_entry` alone.

**6. Gate.**
- Each mutant asserts its anchor occurs exactly once (`mutate_table_entry_owner.sh:143-149`). A miss leaves an unmodified copy, which is reported as SURVIVED (fail-safe).
- A kill requires the *named* test to appear in FAIL/ERROR (`:111`). I traced all 17 mutants and each is killed for the intended reason. M7b is killed by exception class (400 versus 409), not by a write going through: the builder already refuses a default that carries a match.
- M16 with `p4_src/build` absent: the named test skips, so it is not FAIL/ERROR, so it counts as SURVIVED and the gate exits 1, plus the note at `:82`. Not silent. This is from reading the code; no log shows that run.
- M16 is the same mutant as M1 (same anchor and replacement).

**7. Text.** See MEDIUM 1 and the LOW wording items above. Defect descriptions shipping with the fix are fine.

## Evidence audit

| # | Claim | Verdict |
|---|---|---|
| 1 | Log 01: 35 failures, 9 errors (7 TypeError + 2 real-p4info) | SUPPORTED (01:352). Head is truncated, so some blocks aren't visible. |
| 2 | Production at 9fdf9cf6 equals 60d11501 | UNDER-EVIDENCED (no hash or diff logged) |
| 3 | M7 test added in commit 2, seen red via M7 | SUPPORTED (39 → 40 tests, +11 lines at owner `:386-396`, log 04:14) |
| 4 | L/00: "All 43 modules rc=0" | rc=0 SUPPORTED; the count is CONTRADICTED (46 modules). Skip cause UNDER-EVIDENCED (86 skips in `test_fabric_bring_up`, 3 in the foreign suite). |
| 5 | L/03: "41 of 43 rc=0" | CONTRADICTED on the count (45 of 47); the two red suites SUPPORTED (03:606-607, 1340-1354) |
| 6 | L/04 17/0; L/05 135/135 ok(16); L/06; L/07; L/09 rc=2; L/10 41/0 | SUPPORTED. ok(16) against 17 mutants is explained by M3 and M5 sharing an anchor. |
| 7 | L/08: 9 lane failures not caused by the change | UNDER-EVIDENCED (labelled INFERRED, not rerun on main). The 11-group total is SUPPORTED. |
| 8 | Commit messages: no forbidden words, no trailers | UNDER-EVIDENCED (no log of the check) |
| 9 | L/12: 40/26/161/14/17 OK, foreign suite with no skips | SUPPORTED (sum 258 matches the gate baseline) |
| 10 | L/13: "all 43 modules rc=0" | all rc=0 SUPPORTED; the count is CONTRADICTED (47) |
| 11 | L/14: 18 mutations, 0 survived | SUPPORTED. 18 = 1 control + 16 distinct mutants + M16 repeating M1. |
| 12 | L/15: baseline green, 41/0 | SUPPORTED by inference (tail-only log; rc=0 implies a green baseline under the gate's exit-2 convention) |
| 13 | L/16 135/135; L/17 0 temp paths | SUPPORTED. 16 is tail-only, so the owner gate's own row isn't in it. |
| 14 | L/11: ERROR, `TableEntryUnsupported` instead of `TableOwnedByNDTwin` | SUPPORTED. The checkout and restore is attested only by the header, but the line numbers corroborate it. |
| 15 | M16 reports a survivor without the build | SUPPORTED by code; UNTESTED (no such run) |
| 16 | Worktree cleaned, patch deleted | SUPPORTED (none of those files remain) |
| 17 | L1 lane at f69d20b0 | UNTESTED (disclosed). Production code is the same as at ff9147a0. |

**Inconsistencies in the numbers:**
- "43 modules" appears three times; the logs show 46, 47 and 47.
- Your brief's commit-2 description leaves out the test it added. Handback 1 discloses it.
- The main baseline (log 00) ran without `p4_src/build`, so the before and after full runs aren't like for like.

## Tests I would have run
1. A concurrency test. Thread A is inside `entry_source("boot")` with `stub.Write` blocked. Thread B POSTs the owned package default: it must get 409. Then release A: its default must be applied. Also pin the hazard that a task created inside the block inherits "boot".
2. An end-to-end owner test through `main.build_p4_client` with a real roles package (renamed_route fixture, or `convert.py --role-ipv4-route`):
   - API full name and alias both get 409; another table gets 200.
   - `run_startup` gives applied N, failed 0, with the default applied.
   - `readopt_switch` re-applies the default and refills the routes.
3. A pre-flight versus proxy agreement test for owner-ndtwin entries, including the truthy non-bool default and default-plus-match edge cases.
4. The missing mutants: compare `spec["table"]` instead of the resolved name, ignore an explicit `source`, drop the `ValueError`, move `reset` out of `finally`. Plus a check that C1 was actually applied.
5. The owner gate run without `p4_src/build`, to observe the M16 survivor and exit 1.
6. The L1 lane at f69d20b0, and the 9 "not caused by my change" failures rerun on 60d11501.
7. A live bmv2 check:
   - An empty-match POST into `flow_5tuple` gets 409 and `table_dump MyIngress.flow_5tuple` is unchanged.
   - Bring-up C keeps its default after a power-cycle readopt.
8. A unit test pinning that the OpenFlow path can't produce an empty `flow_5tuple` key set.

Key paths: `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-writer-owned/p4_proxy/proxy_agent/{p4_client,api_routes,main}.py`, `.../wt-p4-writer-owned/tests/shell/mutate_table_entry_owner.sh`, `.../wt-p4-writer-owned/p4_proxy/tests/test_table_entry_owner.py`, `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-writer-owned/`.