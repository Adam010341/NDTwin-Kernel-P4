# 2026-09-02 whole-machine live round -- CHECKPOINT

> ⚠️ Read `ADDENDUM-01-viz-orphan-contamination.md` beside this file first: an orphaned viz JVM
> was running at >100% CPU from step C27 (21:44) onward, so measurements taken after that point
> must not be compared against the idle baseline without accounting for it.

[Co-developed with claude code -- Adam]

Written from the raw logs alone (`raw/A0..A8`, `B1..B21`, `C1..C51`, `D1..D2`, `E1..E5`, plus
`raw/contract_p4/`, `raw/cpu/`, `raw/harness/20260902T134522Z/`). The agent that produced
steps A0-D2 died on a rate limit before writing anything; every verdict below was re-derived
by reading the log named in its row. **UNVERIFIED means the log does not settle it** -- it is
not a soft PASS. "NOT RUN" means no run evidence exists anywhere under `raw/`.
Nothing here is inferred from code reading: "ran" and "read but not executed" are never mixed.

**Round state: STOPPED after PHASE 1.** The P4 half is done and torn down. The OVS half was
**not** run: the coordinator halted the round at 23:21 so the machine could be handed to fix
compilation until 01:30, and then to a series of role-play test rounds which will absorb the
OVS half and the untested tools. Section (a)/(b) REMAINING and section (e) are the handover.

Five E-steps exist and are teardown/plumbing only -- **no new measurement was taken.**

---

## E-series (this session; teardown and plumbing only)

| Step | Log | What it proves | Result |
|---|---|---|---|
| E1 | `raw/E1_down_clean.log` | `ndt down` and `ndt clean` both run and both assert the machine is clean | **RAN, both report `not clean` rc=1** -- 4/5 assertions ok (0 bmv2, 0 host/switch procs, no topo session, no manifest); the 5th is `:8081 still listening -- the next up would measure it`, correctly refused because the stack did not start it |
| E2 | `raw/E2_stray_8081.log` | who holds `:8081`, and is it ours to reap | pid 925466, `p4_proxy/venv/bin/python3 proxy_agent/main.py`, started **22:06:04**, PPid 2859 -- i.e. the proxy restarted by hand for the A-4c test (C51), never registered in a pidfile. Ours; `.test_run/pids/` is empty |
| E3 | `raw/E3_down_deep.log` | `ndt down --deep` reaps a stray the plain `down` refuses to touch | **PASS** -- `killing python3 (pid 925466) holding :8081 -- not started by this stack`, `deep sweep removed 1 stray listener(s)`, then `clean` / `DEEP_RC=0`. Standalone `ndt clean` then also `clean` / `CLEAN_RC=0`. All four ports 8000/8080/8081/9000 free. No `pkill -f` used |
| E4 | `raw/E4_systemdrun_kills_fabric.log` | `ndt up ovs4` cannot be run under `systemd-run --user --collect` | **ABORTED, fabric half-built then destroyed by systemd.** See finding 17 in section (c). No OVS measurement was taken from it |
| E5 | `raw/E5_teardown_stop.log` | the machine is quiet again before the compile window | **PASS** -- `topo stopped`, `deep sweep: nothing left holding the ports`, all five assertions ok, `DEEP_RC=0` and `CLEAN_RC=0`; `ndt status` shows 0 bmv2, 0 host/switch, no topo session, no manifest, all ports closed |

---

## (a) Tool table

Verdict is about **the tool's own run**: PASS = it ran and did its job; FAIL = it ran and
came back red; UNVERIFIED = it ran but the log does not settle whether its job was done.
A red *product* verdict from a healthy instrument is recorded in section (c), not here.

| # | Tool / script / feature | Evidence under `raw/` | Verdict | Basis |
|---|---|---|---|---|
| 1 | `ndt claim` | A4_ndt_claim.log | PASS | claimed 300m as `auditor`, status then reads `claim yours` |
| 2 | `ndt status` | A2_ndt_status_pre.log | PASS | full pre-round readout, kernel/proxy/ryu all closed |
| 3 | `ndt status --check` | C2_ndt_status_check_p4.log; C43_f14_recovery.log; C44_stop_energy.log | PASS | `check: ok` RC=0 on a healthy fabric; RC=1 with `2 problem(s)` on a degraded one (C44) |
| 4 | `ndt up p4 128` | C1_ndt_up_p4_128.log | PASS | 10 switches up in 18 s, manifest written, 16256 paths, `h1 -> 10.0.0.2 forwards` |
| 5 | `ndt up ovs4` | E4_systemdrun_kills_fabric.log | NOT RUN (aborted) | reached `up. ready` inside a systemd unit, then systemd killed the kernel it had just started (finding 17). **No OVS measurement exists.** Must be re-run under `setsid` |
| 6 | `ndt down` | E1_down_clean.log; E5_teardown_stop.log; (D1/D2 for the P4 half) | PASS | E1: `DOWN_RC=1`, correctly `not clean` because an unregistered `:8081` listener survived and the plain `down` refuses to kill what it did not start. E5: `DOWN_RC=0`, `topo stopped`, all five assertions ok. In D1/D2 the P4 kernel did exit under it, but no transcript was captured there |
| 6b | `ndt down --deep` | E3_down_deep.log; E5_teardown_stop.log | PASS | E3 reaped the stray proxy (`deep sweep removed 1 stray listener(s)`); E5 `deep sweep: nothing left holding the ports`. Both `DEEP_RC=0` |
| 7 | `ndt clean` | E1_down_clean.log; E3_down_deep.log; E5_teardown_stop.log | PASS | standalone assertion run three times: `CLEAN_RC=1` while `:8081` was held, `CLEAN_RC=0` twice after. It discriminates |
| 8 | `ndt release` | n/a | DELIBERATELY NOT RUN | round is continuing; claim held until 01:51 |
| 9 | `ndt apps sim` / `energy` | C24_ndt_apps.log | PASS | tmux session + `:9000` listener + app pane output asserted per app |
| 10 | `ndt apps nsr` | C24_ndt_apps.log | PASS | `nsr started (pid 892681)`, RC=0 |
| 11 | `ndt apps viz` | C25_ndt_apps_te_viz.log | PASS | `viz started (pid 893606)`, maven build visible in the app log |
| 12 | `ndt apps te` | C25_ndt_apps_te_viz.log | FAIL | `XX te exited immediately`, RC=1 -- `EOFError` from `input()` in `ask_mode` (this is the known app defect, and `ndt` reported it honestly) |
| 13 | `ndt apps stop <name>` / `stop all` | C26_apps_stop_falseok.log; C44_stop_energy.log; D1_teardown.log | FAIL | false ok for never-started apps -- see finding F-1 in section (c) |
| 14 | `ndt apps orphans` | none | NOT RUN | A-1 orphan rider not exercised |
| 15 | `ndt ntg` | none | NOT RUN | |
| 16 | `ndt check` (telemetry double-count tripwire) | none | NOT RUN | |
| 17 | `stack.sh up / wait / down` | C1_ndt_up_p4_128.log (`stack.sh prompt is answered immediately`) | UNVERIFIED | only reached through `ndt up`; never invoked directly, no rc captured |
| 18 | `run_layers.sh selftest` | B14_run_layers_selftest_quick.log:113 | PASS | `SELFTEST_RC=0` |
| 19 | `run_layers.sh quick` (L0+L1) | B14:544-551 | FAIL | `QUICK_RC=1`, `L1 FAILED (6 problem group(s))`; L0 PASS |
| 20 | `run_layers.sh api p4` (L2/L3 path) | C38_r5_p4.log -> harness/20260902T134522Z/f2_run_layers.txt | FAIL | `run_layers.sh exited rc=1`; C39 shows the red is a 4-host-model-vs-128-host-fabric mismatch, not a product failure |
| 21 | `l0_build_check.sh` | B14:115-116, 547 | PASS | `PASS L0 build check` |
| 22 | `l1_unit_tests.sh` | B14:361-544; B15; B16; B18 | FAIL | 6 problem groups; 5 are l1's own `^Ran N` scoring defect (B16), 1 is a venv problem (B17) -- see (c) |
| 23 | `local_ci.sh gcc python p4cov` | B18_local_ci.log | FAIL | `PASS gcc` (870/870 gtest), `FAIL python`, `FAIL p4cov`; `local CI FAILED` |
| 24 | `cpu_probe.py` | B21_cpu_probe_idle.log; C47_cpu_under_load.log; cpu/*.jsonl | PASS | 60 samples/30 s idle and 80 samples/40 s under load, both `PROBE_RC=0` |
| 25 | `cpu_report.py` | B21; C47 | PASS | idle 6.0% machine-wide; under load 15.1%, proxy 9.1% / kernel 5.3% of one core |
| 26 | `faults.sh list` | C45_faults.log | PASS | `LIST_RC=0`, three catalogue entries with their retirement history |
| 27 | `faults.sh run L-2` | C46_faults_L2.log | PASS | `PASS L-2: before=moving during=moving after=moving, qdisc clean`, RC=0 |
| 28 | `faults.sh run L-3` / `N-4` | none | NOT RUN | |
| 29 | `qdisc_snapshot.sh` save/diff | B9_qdisc_snapshot_nofabric.log | PASS | `SAVE_RC=0`, `DIFF_RC=0`, plus its own unit test 9/9 |
| 30 | `p4_coverage_gate.sh` | B10_p4_coverage_gate.log | FAIL | `P4COV_RC=1`, coverage 0.836364 < floor 0.85 -- the log's own verdict line says the red is **pre-existing on trunk**, see (c) |
| 31 | `test_ndt_lab_session.sh` | B12 | PASS | 14 passed, 0 failed |
| 32 | `test_teardown_guards.sh` | B11 | PASS | 14 passed, 0 failed |
| 33 | `manifest_backfill.sh` | B13 | PASS | `MANIFEST_RC=0`; sha256/size/buildid recovered, non-recoverable fields named as such |
| 34 | `derive_p4_topology_json.py` | B5 | PASS | round-trip == shipped P4 128-host **and** shipped P4 4-host, `derive_rc=0` |
| 35 | `test_topo_from_json.py` | B3 | PASS | `PASS -- derived wiring is identical to the hard-coded lists` |
| 36 | `test_topo_model_guards.py` | B4 (miniconda); B4b (system python) | PASS | B4 aborts with `No module named 'mininet'`; B4b runs the full G1/G3/G5 set, `PASS`. **Requires the system interpreter, not miniconda.** |
| 37 | `greenlet_dump_smoke.py` | B8 | PASS | `2 dumps, 6 parked frames, 4622 bytes`, `GREENLET_RC=0` (ryu-env py3.8) |
| 38 | `ovs_4host_topo.py` | none | NOT RUN | comes up with `ndt up ovs4` |
| 39 | `build_bmv2_fast.sh` | none | NOT RUN | would rebuild bmv2; out of scope for this round |
| 40 | `ndtwin-lab` (sudo wrapper) | C24; C28; B14 (repeated `ndtwin-lab status` in the sudo log) | PASS | exercised throughout by `ndt`; never invoked standalone |
| 41 | `run_contract_test.py --self-test` | B1 | PASS | `Self-test passed: 66 checks`, `SELFTEST_RC=0` |
| 42 | `run_contract_test.py` live L2, P4 | C4_contract_l2_p4.log; contract_p4/*.json | PASS | `40/40 passed`, `L2_RC=0` |
| 43 | `run_contract_test.py --only` / power-aware | C10; C34; C34b; C36 | PASS | `--only get_flow_dispatch_status` 1/1; power-aware `accounted for:` lines fire on a fabric with 3 switches OFF |
| 44 | `run_contract_test.py` live, OVS plane | none | NOT RUN | |
| 45 | `l3_component_check.py` | C5_contract_l3_p4.log | PASS | `L3_RC=0`, 7 components, 1 DEGRADED by the known `/ndt/disable_switch` gap |
| 46 | `l3_component_check.py --check-drift` | C6_l3_check_drift.log | FAIL | `DRIFT_RC=1`; C6 shows the two "missing" endpoints answer 200 live -- false positive, see (c) |
| 47 | `check_logs.py` (default allowlist) | C7_check_logs_p4.log | PASS (instrument) | `CHECKLOGS_RC=1` on a real ERROR line + an un-allowlisted sFlow warning; the tool did its job |
| 48 | `check_logs.py --powered-off 5,7,9` | C37_check_logs_powered_off.log | PASS (instrument) | the WHEN-POWERED-OFF scope moved the dpid-9 read failure into `EXPECTED`; unscoped re-run stayed red (`RC_UNSCOPED=1`) |
| 49 | `compare_baseline.py` | none | NOT RUN | |
| 50 | `twin_audit.py` offline | B7_twinaudit_p4power_offline.log | PASS | `FLOWS_RC_OFFLINE=2`, "could not reach the twin" |
| 51 | `twin_audit.py` live (flows/hosts/audit/--pair) | C27_twin_audit_live.log | PASS | all four modes RC=0; `1 pair(s) audited, 0 contradiction(s)` |
| 52 | `make_topology.py --check` / `--hosts N --stdout` | B6_make_topology.log | PASS | `CHECK_RC=0`, `setting/` unchanged; **defect recorded**: `--stdout` prints its report ahead of the JSON so a redirect is not valid JSON |
| 53 | `p4_power_helper.py` | B7 (usage/refusal only, `NOARG_RC=2`, `HELP_RC=2`) | UNVERIFIED | never used to power a switch; the live power cycling in C32/C42 went through the kernel API |
| 54 | `tests/shell/check_gate_anchors.py HEAD` | B2_check_gate_anchors.log | PASS (instrument) | ran over 24 gates; 1 broken anchor + 4 UNPARSED gates reported -- see (c) |
| 55 | harness `00_preflight.sh` | C28_harness_00_preflight.log; C29_preflight_triage.log | PASS (ran) | `21 check(s), 9 FAIL`, `PREFLIGHT_RC=0`; all 9 FAILs triaged in C29 -- see (c) |
| 56 | harness `10_r1_endpoint_callers.sh` | none | NOT RUN | |
| 57 | harness `20_apps_lifecycle.sh` | none | NOT RUN | |
| 58 | harness `25_apps_energy.sh` | none | NOT RUN | -- and its absence is why 90_restore aborted |
| 59 | harness `30_r2_r3_sample.py` / `35_r2_r3_analyse.py` | none | NOT RUN | |
| 60 | harness `40_r5_p4.sh` | C38_r5_p4.log; C39_r5_triage.log; harness/.../r5_verdicts.tsv | PASS (ran) | `16 check(s), 2 FAIL`; both FAILs triaged in C39 as instrument confounds |
| 61 | harness `50_r5_ovs.sh` | none | NOT RUN | F-5b's differential cannot close without it |
| 62 | harness `90_restore.sh` | C41_r5_90_restore.log | UNVERIFIED | `ABORT no .../graph_energy_before.json` -- refused correctly, but restored nothing; `RESTORE_RC=0` |
| 63 | chaos `test_probes.py` (offline parser self-test) | C48_chaos_smoke.log | PASS | `all parser checks passed`, `PROBES_RC=0` |
| 64 | chaos `chaos.py --dry-run` | C48 | PASS | `DRYRUN_RC=0`, every destructive allow path printed intent and touched nothing |
| 65 | chaos `chaos.py --gates --owner auditor` | C48 | PASS (ran) | `GATES_RC=0`; INV-02/03/05 report `NO-CONTROL` -- their PASS means nothing, by their own text |
| 66 | chaos `chaos.py` live (non-dry-run) | none | NOT RUN | |
| 67 | T-9 instrument `assert_window_span` | B15 (test_harness_instruments.sh, 34/34 ok) | PASS (offline) | live path is `25_apps_energy.sh`, the only caller -- NOT RUN, so live is UNVERIFIED |
| 68 | T-10 instrument `LISTENER-OWNER-HIDDEN` three-state | B15; C28 (`:9000 HAS a listener whose owner is not visible to this uid`) | PASS | the hidden-owner branch fired live in preflight, not just in its unit test |
| 69 | `rider_a2-max-time.md` (Ryu stopped, 10-line listener on :8080) | none | NOT RUN | needs the OVS/Ryu plane |
| 70 | `rider_app-orphan-stop.md` | none | NOT RUN | |
| 71 | `analyse_app_te_log.py` (live-recipes) | none | NOT RUN | |

### REMAINING -- tool surface with NO run evidence

**23 items.** Each must be *run*, not read. Named individually; there is no "and the rest".
Priority order is the brief's: OVS plane first, then unrun tools, then unverified fixes.

**T-1 .. T-9 -- the OVS plane (the brief's `ovs4` half). All nine need one `ovs4` window.**

| id | what to run | why it is not covered by the P4 half |
|---|---|---|
| T-1 | `ndt up ovs4` | brings `ovs_4host_topo.py` with it -- that file's ONLY run path |
| T-2 | `ndt status --check` on the OVS plane | the P4 capture (C2) says nothing about OVS health fields |
| T-3 | `run_contract_test.py` live L2, OVS plane | C4 is P4 only |
| T-4 | `l3_component_check.py` live, OVS plane | C5 is P4 only; the `/ndt/disable_switch` gap may read differently |
| T-5 | `check_logs.py` against the OVS kernel log (with and without `--powered-off`) | C7/C37 are P4 logs; the allowlist has 9 entries that are OVS-only and went `UNUSED` on P4 |
| T-6 | harness `50_r5_ovs.sh` | closes the **F-5b differential**; **R-5 F-1** and **R-5 F-5** are reachable ONLY here |
| T-7 | `doc/audit/2026-08-31_live-recipes/rider_a2-max-time.md` (stop Ryu, hold `:8080` with the stall listener) | A-2's `--max-time 5` arm has never been hit live; the 08-31 injection dropped SYNs and only exercised `--connect-timeout`. **Run this LAST in the window -- it destroys the control plane** |
| T-8 | `doc/audit/2026-08-31_live-recipes/rider_app-orphan-stop.md` | the A-1 orphan-app rider |
| T-9 | `tools/ryu_apps/rest_topology_bounded.py` actually loaded | evidence must be `ryu-manager` **argv** showing our vendored copy, not the packaged one |

**T-10 .. T-20 -- tools with no run evidence on either plane.**

| id | what to run | note |
|---|---|---|
| T-10 | `ndt apps orphans` | exits 1 if an untracked app is running; the A-1 guard |
| T-11 | `ndt ntg [cli\|prompt]` | never invoked |
| T-12 | `ndt check` (telemetry double-count tripwire) | never invoked |
| T-13 | `tools/test_workflow/stack.sh up` / `wait` / `down`, invoked **directly** with rc captured | only ever reached through `ndt up` |
| T-14 | `tools/contract_test/compare_baseline.py` | never invoked; `baseline_diff_allowlist.txt` therefore also unexercised |
| T-15 | `tools/p4_power_helper.py` used to **actually power a switch** | B7 only exercised its usage/refusal path (rc=2) |
| T-16 | `tools/test_workflow/faults.sh run L-3` | gray-failure 30% both-directions; expect=moving |
| T-17 | `tools/test_workflow/faults.sh run N-4` | SIGSTOP/CONT; expect=moving |
| T-18 | harness `10_r1_endpoint_callers.sh` | |
| T-19 | harness `20_apps_lifecycle.sh` | it is the script that gives `te` a pty, so it is the only path on which `te` can survive |
| T-20 | harness `25_apps_energy.sh` | writes `graph_energy_before.json`; **without it `90_restore.sh` aborts** (C41), and it is the only live caller of the T-9 instrument `assert_window_span` |

**T-21 .. T-23 -- remaining harness / analysis.**

| id | what to run | note |
|---|---|---|
| T-21 | harness `30_r2_r3_sample.py` + `35_r2_r3_analyse.py` | |
| T-22 | harness `90_restore.sh` **re-run after** `25_apps_energy.sh` | C41 ran but aborted with nothing to restore to |
| T-23 | `doc/audit/2026-08-28_chaos-harness/harness/chaos.py` live (non-dry-run), incl. `_c07` after the route fix | C48 covered only `test_probes.py`, `--dry-run` and `--gates`. Note C8: the three routes `_c07` calls (`/ndt/set_historical_logging`, `/ndt/get_historical_data`, `/ndt/set_historical_logging_state`) all 404 |

**Declared out of scope -- recorded so the skip is a decision, not an omission:**
- `tools/test_workflow/build_bmv2_fast.sh` -- would rebuild and reinstall bmv2; the installed
  artifact is the artifact of record (`raw/B13`). Not run deliberately.
- `tools/remote-lab/*` (`rlab`, `ndtwin-vm.sh`, `ndtwin-virt-root.sh`, `host_witness.sh`,
  `vm-install-stack.sh`, `p4_patch_preflight.sh`, `test_claim_guard_identity.sh`,
  `test_vm_coordination.sh`) -- these drive remote machines. `server1-8`, `cc2`, `gw`, `gw2`
  are out of service; `nslab` needs its own usage rules (R1 = register before the run).
- `tools/git-hooks/post-commit`, `tools/githooks/{install.sh,pre-commit}` -- installing a hook
  in a worktree shared with other sessions is not this round's call.
- `doc/audit/2026-08-31_live-recipes/analyse_app_te_log.py` -- needs a `te` crash-loop log,
  which only `20_apps_lifecycle.sh` (T-19) produces.

---

## (b) Fix table

| Fix | Evidence under `raw/` | Verdict | Basis |
|---|---|---|---|
| A-1 (orphan app rider) | none | UNVERIFIED | `ndt apps orphans` never run |
| A-2 (`topology-round-partial`; `--max-time` rider; vendored Ryu app loaded) | A8_strings_check.log | UNVERIFIED | the string is in the new binary and absent from `e3bad23c`, but no live half-answer was produced and Ryu was never up on the P4 plane |
| A-4c (proxy restart -> new `boot_id` / `table_generation`) | C49_a4c.log; C50_a4c_markers.log; C51_a4c_after_restart.log | PASS | negative control E: two reads 25 s apart, tokens identical; after restart `boot_id` changed and `table_generation` changed on 10/10; both planted markers gone (rows 130 -> 128) |
| A-4d (delete restores the control-plane route) + 3 negative controls | C14; C15_a4d_main.log; C16_a4d_control_A.log; C17+C19; C18_a4d_control_C.log | PASS | main arm: install OUTPUT:4 -> delete -> entry back at OUTPUT:3. Control A (off-topology 192.168.99.9): delete leaves 0 entries, so delete really deletes. Control B: all 286 lost packets attributable to the black hole, none to a post-delete gap. Control C: 200/200 probes hit the migrated rule's counter |
| A-4f (telemetry silence / `telemetry_status`) -- P4 half | C34b_a8_graph_only.log; C36_a4f_telemetry_with_traffic.log; contract_p4/get_graph_data.json | PASS | the silence check fires with no traffic (10 `is silent` edges) and clears with traffic (`1/1 passed`). Field present on 288/288 edges, value `unknown` in the idle capture |
| A-4f -- OVS power-cycle half | none | UNVERIFIED | requires `ndt up ovs4` |
| A-7 (`get_flow_dispatch_status`: `dispatcher_running`, `counters_cover`, bad port -> failed+1) | C10_a7_bx.log; C11; C12; C23_a7_b1_joined.log; C40 | PASS | idle: all counters 0, `dispatcher_running: true`, `counters_cover` names 4 routes and excludes boot-time/intent. After the bad-port write: `dispatched 1 / failed 1`, and `recent_failures[0]` carries dpid, match, `requested_priority: 915` and the proxy's message. C11/C12 add the `priority_honoured` disclosure (`ipv4_lpm` false / `flow_5tuple` true), read back at priority 0 and 916 |
| A-8 (R5 three-state: down+OFF is ACCOUNTED-FOR) | C34_a8_three_state.log; C34b; C36 | PASS | with s5/s7/s9 genuinely OFF the check prints `accounted for: 3 switch(es) ... -- a powered-down switch is the Energy-Saving-App doing its job` and `accounted for: 20 edge(s)`. The one FAIL is A-4f telemetry silence, not the power-off; it clears under traffic. Literal `switch(es) not up` count = 0 (C39) |
| A-9 (lease expiry event; `release_lock` on a dead lease) | C20_a9_lock_lease.log | PASS | 423 while held; after TTL `reclaimed_expired_lease: true`; release AND renew naming the dead lease 4 both 409 `lease_mismatch`; the three A-9 kernel log lines present. Also records that a **bare release naming no lease still succeeds** (`setRequireLeaseId` off by design) |
| B-1 (P4 ghost rules filtered) | C22_b1_p4_probe.log; C23 | PASS | port 999 on s1: `first_sighting=never (absent for the whole 25.0s)`, table total unchanged at 1280, and the rejection is visible in `get_flow_dispatch_status` |
| B-1 (OVS half) | none | UNVERIFIED | read-code inference only; the brief says it must be measured |
| B-2b (single-quoted body: no component accusation, no shell execution) | none | UNVERIFIED | no step exercised it |
| B-3 (MININET -> `status=not_applicable` + reason) | C8_b3_historical_logging.log | PASS | `POST /ndt/historical_logging?state=enable` -> `{"status":"not_applicable","reason":"not-available-in-mininet-mode","recording":false}`; the boot WARN naming the same reason is in the log and matched allowlist line 87 |
| B-4 (simulation case containing a single quote is really sent) | none | UNVERIFIED | no step exercised it |
| B-5 (shutdown abort) | D2_b5_kernel_exit.log | **did NOT reproduce** | see finding 3 in section (c). Kernel exit code UNKNOWN |
| B-x (`get_detected_flow_data` default = active only) | C35_bx_live_traffic.log; C10 | PASS | sample 3 discriminates: `default 0 flow(s)` vs `liveness=all 6 flow(s)`. C10 also shows `pathIs` rejecting `/ndt/get_detected_flow_dataXYZ` (404) and `/ndt/get_detected_flow_data/` (404) while `?x=1` still serves |
| F-1 (MININET three metrics = -1 sentinel; `ndt status` note) | C9_f8_f14_f1.log; C2; C38 | PASS | all 30 keys across cpu/memory/temperature read `-1`; `ndt status` carries `note /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py`; R-5 records F-3 FIXED with `Num(min=-1, max=100)` at 2 sites |
| F-6 (read-failure switch stays in the table, marked stale) -- log line | C32_energy_powered_off.log | PASS | `serving 1 switch(es) from their previous flow table; each is marked with stale_since/stale_polls/last_error`, immediately after a `DEADLINE_EXCEEDED` read failure on switch 9 |
| F-6 -- the `stale_since` field on the endpoint | C33_f6_f14_live.log; C43 | UNVERIFIED | no captured `get_switch_openflow_table_entries` response contains `stale_since` (grep over all of `raw/` finds it only in A8's strings table, the C32 log line and f2_run_layers.txt). C33 lists 7 switches, the 3 powered-off ones already dropped |
| F-8 (`left_link_bandwidth_source`; 10G core edges) | C9_f8_f14_f1.log | PASS | 288 edges: 16 at 10e9, 272 at 1e9, `left_link_bandwidth_source` = `declared` on all 288, 0 edges missing the key |
| F-13 (six group/meter endpoints refuse on P4) | C21_f13_p4.log | PASS (P4 arm) | all six `/ndt/{install,modify,delete}_{group,meter}_entry` return **501** with a body naming why, plus `withOutcome("unsupported_on_p4")` in the source |
| F-13 (the full 12-cell matrix: exists / does-not-exist x 6, both planes) | C21 covers 6 cells | UNVERIFIED | the "already exists" arm and the OVS plane were not run |
| F-14 / F-16 / F-4 (switch out 2 polls -> edges down with `down_reason`; recovery is not proactive) | C9; C33_f6_f14_live.log; C43_f14_recovery.log | PASS | healthy: `down_reason` `none` on 288/288. Degraded: 20 edges `switch-unreachable`, matching `is_up False: 20`. Recovery: `down_reason` lags `is_up` by ~40 s and the settled reading has **0 edges that are DOWN carrying `down_reason=none`** |
| F-15 (gRPC port block vs ephemeral range) | B19_f15_port_preflight.log | PASS | `ip_local_port_range 32768 60999`, `GRPC_PORT_BASE=30050`, ports 30051-30060 all free -- the block sits below the ephemeral range |
| NDT sample rate line | C1; C2; B14/B18 (`test_ndt_sample_rate_reads_both_bounds.sh PASS 6`) | PASS | `sample rate 1/256 (compiled into ndtwin_switch.json)` on both `ndt up` and `ndt status` |
| R-5 F-2 | C38_r5_p4.log | STILL PRESENT | suite failed rc=1, but not with the 08-18 wording -- C39 attributes it to a topology mismatch, so the harness's own instruction ("say which invariant fired; do not assume") is unmet |
| R-5 F-3 | C38 | FIXED | `spec.py:502/507` read `Num(min=-1, max=100)`; 30 keys carry -1 on a live degraded fabric |
| R-5 F-4 | C38 | FIXED | old comment gone; the `Str()` branch survives at 1 site, documented as back-compat; `get_temperature` returns 0 string values |
| R-5 F-5 | C38 | NO LONGER REACHABLE ON P4 | negative control for the OVS half; the P4 proxy writes synchronously inside its 200 |
| R-5 F-5b | C38 | STILL PRESENT (P4 arm only) | kernel logs the rejection (1 line). **A differential -- one arm is half a finding**; needs `50_r5_ovs.sh` |
| R-5 F-1 (reserved out-port diagnosis) | C38 | NOT REACHABLE ON P4 | guard sites 0, but P4 has no `OFPP_CONTROLLER` equivalent; only reachable in `50_r5_ovs.sh` |

### REMAINING -- fixes with no live verdict

**12 items.** Named individually. The fix-design docs live in
`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/254e6209-ad64-4371-9042-829d52c1575f/scratchpad/`
(A-2.md, A-4c.md, A-4d.md, A-4f.md, A-7.md, A-8.md, A-9.md, B-1-VERIFY.md, B-2b-B-4.md, B-3.md,
B-x.md, F-13.md, F-14-F-16-F-4.md, F-15.md, F-1.md, F-6.md, F-8.md) -- **that is a scratchpad of
a dead session; if it is gone, the recipes are also in each finding's §6.**

| id | fix | what is still missing | needs |
|---|---|---|---|
| X-1 | **A-2** (a) | a live half-answered topology round emitting `topology-round-partial` | OVS/Ryu plane |
| X-2 | **A-2** (b) | the `--max-time 5` arm: Ryu stopped, a user-level listener accepting on `:8080` and never answering; assert `topology poll got no answer` in the kernel log and ~15 s (3x5 s), not ~6 s | T-7 rider; run LAST |
| X-3 | **A-2** (c) | the vendored Ryu app is the one loaded -- evidence is `ryu-manager` argv | T-9 |
| X-4 | **A-1** | orphan-app rider: an app running that no pidfile names, `ndt apps orphans` exits 1 | T-8 / T-10 |
| X-5 | **B-1 OVS half** | the phantom rule window that structurally cannot exist on P4 (proxy writes synchronously inside its 200). Re-run the 08-31 force-red probe recipe against OVS | OVS plane |
| X-6 | **B-2b** | a request body containing a single quote must NOT accuse a component and must NOT execute shell | either plane; never attempted |
| X-7 | **B-4** | a simulated case whose text contains a single quote is really sent (not silently dropped) | either plane; never attempted |
| X-8 | **A-4f OVS half** | power-cycle an OVS switch, then assert the sFlow record came back and `telemetry_status` leaves `unknown`. `sudo -n -l` already grants `ovs-vsctl` (`raw/A1`) | OVS plane |
| X-9 | **F-6 endpoint half** | read `stale_since` / `stale_polls` / `last_error` back off `/ndt/get_switch_openflow_table_entries` while a switch is unreadable. The kernel log line fired (C32) but no captured response ever contained the fields | either plane |
| X-10 | **F-13 cells 7-12** | the "group/meter already exists" arm, and the whole matrix on OVS (where groups/meters are real, so the answers should NOT be 501) | OVS plane |
| X-11 | **R-5 F-5b / F-5 / F-1** | all three are OVS-side arms. F-5b is a **differential** and one arm is half a finding; F-1 and F-5 are literally unreachable on P4 (C38's own verdict lines) | T-6 `50_r5_ovs.sh` |
| X-12 | **B-5** | in this run the abort did NOT reproduce (finding 3). What is still missing is the **kernel exit code**: it runs under a wrapper (parent pid 2859), so the status was never captured. Either drive the shutdown from a parent that waits, or have `stack.sh`/`ndt down` record it | either plane |

---

## (c) Findings -- red or surprising

**1. `ndt apps stop all` reports ok for apps that were never started.**
`raw/C26_apps_stop_falseok.log`, `raw/D1_teardown.log`. Asking to stop `viz` (already stopped)
and `te` (never started -- it died on `EOFError`) both print `<app> not running (no live instance
found by pid or by scan)` with `RC=0`, and `ndt apps stop all` in D1 exits `APPS_STOP_ALL_RC=0`
having "stopped" two apps that were not running. This is the usertest run-01 false-ok,
reproduced. C26 also names the mechanism: `ndt:1928-1929` checks only the rc of
`sudo -n ndtwin-lab <app>-start`, and `ndtwin-lab`'s `*-start` is `tmux new-session -d ...; echo`,
which returns 0 even if the child dies in the first second. The `app_spawn` path (nsr/viz/te)
does check -- the contrast is visible in the same transcript: `te` -> `XX te exited immediately`,
rc=1 (honest) vs `sim` -> `ok sim started`, rc=0 (true here only because the binary exists).

**2. bmv2 switch count fell 10 -> 7 mid-round; the Energy-Saving-App powered s5/s7/s9 off.**
`raw/C30_bmv2_loss.log`, `raw/C31_topo_pane.log`, `raw/C32_energy_powered_off.log`.
C30: gRPC listeners gone on :30055/:30057/:30059, 7 surviving `simple_switch_grpc` processes,
**no** OOM and **no** oomd action in dmesg or the journal. C31: the topo pane shows all 10
started cleanly at bring-up. C32 closes it: `/ndt/get_switches_power_state` reports
`192.168.123.15/17/19 = OFF`, and the kernel log carries three
`POST /ndt/set_switches_power_state?ip=...&action=off` requests at 21:43:52, 21:44:52 and
21:45:52 -- one per minute, starting 1 s after the Energy app registered at 21:43:51 --
each followed by `MININET: switch sN -> off`. Not a crash: the app doing its job.
C42 then shows P4 power-**on** is no longer a stub (3x `Success`, bmv2 back to 10, listeners
back), contradicting the harness header's claim that it is.

**3. B-5: the run-01 shutdown abort did NOT reproduce.**
`raw/D2_b5_kernel_exit.log`. In this run the kernel log contains **ZERO** occurrences of
`terminate called without an active exception`; the kernel exited under `ndt down` (pid 845333
gone, log grew 48325 -> 48508 bytes, last five lines are ordinary request handlers).
**The kernel's exit code was NOT captured because it runs under a wrapper (parent pid 2859,
still alive), so the exit status is UNKNOWN.** It must not be written or implied as 0.

**4. `p4_coverage_gate.sh` is RED, and the red is pre-existing on trunk.**
`raw/B10_p4_coverage_gate.log`. `P4COV_RC=1`, coverage 0.836364 against a 0.85 floor and a
0.851852 baseline. The log's own verdict line: *"p4_coverage_gate.sh red is PRE-EXISTING on
trunk, not caused by the 09-02 integration"* -- baseline sha `77f18bc0` vs current `a872d22a`;
the `.p4` last changed in `f64897b7` (2026-08-25), which is an ancestor of the pre-integration
base `06bc60ac`, and the integration touched neither the `.p4` nor the baseline. Recorded, not
fixed; `--update-baseline` is an auditor/Adam call.

**5. L1 is RED on a fully green tree -- an instrument defect in `l1_unit_tests.sh`.**
`raw/B16_l1_no_tests_ran_diagnosis.log`, `raw/B14`, `raw/B18`. `l1_unit_tests.sh:319` scores a
test by `grep -oE '^Ran [0-9]+'`. Five shell tests (`test_cell_gate_suspect_wiring.sh`,
`test_ep4_gate_and_abort_evidence.sh`, `test_gate_exit_code_not_tee.sh`,
`test_harness_instruments.sh`, `test_log_suffix_idempotent.sh`) exit 0 with every check ok but
print `N passed, 0 failed` instead, so l1 scores them `ran=0` and counts each as a FAILURE.
The sixth group, `test_sflow_stats_endpoint.py`, fails only because miniconda has no fastapi;
`raw/B17` shows it passing 5/5 under the proxy venv. Product-clean, instrument-red.

**6. `l3_component_check.py --check-drift` produces a false positive.**
`raw/C6_l3_check_drift.log`. `DRIFT_RC=1` claiming the kernel no longer registers
`/ndt/get_detected_flow_data` and `/ndt/get_detected_top_k_flow_data` -- but both answer
**200 live** in the same log. Cause: they are registered through `utils::pathIs(...)` in
`HttpSession.cpp:164/169`, not as the literal string the drift scanner greps for.

**7. `check_logs.py` is red on the live P4 kernel log.**
`raw/C7_check_logs_p4.log`: `FAIL: 2 problem line(s)` -- an `[ERROR] Read error: Connection
reset by peer` (line 73) and an un-allowlisted sFlow warning (`no sFlow datagram has arrived in
60s`). `raw/C37`: with `--powered-off 5,7,9`, 25 problem lines across 23 messages, including
three `[ERROR] Read error: body limit exceeded` and three `N switch(es) unusable for 2+ polls`
warnings that are not in the allowlist. Note `--powered-off 5,7,9` reports
`dpid(s) declared powered off produced no matching log line: [5, 7]` -- only dpid 9's read
failure appeared. Also: 84 lines in the kernel log did not match the expected format
("stdout from a subprocess?").

**8. `check_gate_anchors.py HEAD` -- one broken anchor and four gates not checked at all.**
`raw/B2_check_gate_anchors.log`. `mutate_ryu_rest_topology_bounded.sh` -> `MISSING:1` (its
anchor `${MUT_LABEL[$i]}` matches 0 times in `tools/ryu_apps/rest_topology_bounded.py`, wanted 1).
Four gates are `UNPARSED`/`NO-ANCHORS` and therefore **not checked**:
`mutate_a2_poll_round.sh`, `mutate_a7_dispatch_status.sh`, `mutate_lock_lease_all.sh`,
`mutate_ndt_sample_rate_reads_both_bounds.sh`.

**9. The 40_r5_p4 harness's A-8 detector is confounded, and its F-5b control is structurally
guaranteed to fail on P4.** `raw/C39_r5_triage.log`. (i) `40_r5_p4.sh` decides "is A-8 present"
by grepping for the literals `switch(es) not up` and `BROKEN`. A-8's own string counted 0, but
`BROKEN` counted 1 -- and `BROKEN` is `l3_component_check.py`'s generic per-endpoint verdict
word, fired here by `run_layers.sh api p4` using the default 4-host model against a 128-host
fabric (`host count is 128, topology file says 4`). (ii) `40_r5_p4.sh:204/209` installs a
destination-only rule at priority 902 and then greps the table for `902`. Per A-7/FINDING-07 a
destination-only match compiles to `ipv4_lpm`, which has no priority column, so the rule lands
at priority 0 and the literal `902` can never appear. C39 proves the rule IS there, at
priority 0, on 7 switches. Consequence in C38: `CONTROL FAILED: a valid rule is not visible.
... STOP -- do not record an F-5/F-5b verdict from this run.`

**10. `00_preflight.sh` reported 9 FAILs; C29 triages all of them.**
`raw/C28_harness_00_preflight.log`, `raw/C29_preflight_triage.log`.
(a) "the lab is claimed by someone else: auditor" -- the harness runs `ndt` **without**
`NDT_OWNER`, so its own claim reads as a stranger's.
(b) "no bmv2 switches are already running [observed: 8]" vs `ndt status` 10 -- the harness's
`ps -eo comm= | grep -cx 'simple_switch_g'` counted 7 at triage time; the "8" was the count
before the power-offs settled. Both instruments were reading a fabric that was losing switches.
(c) a `qemu-system-x86` process (29:19 CPU, 1552 MB) was running the whole round -- an
invisible load source that `measuring` cannot see.
(d) ":8000 held by pid ... (curl ...)" -- the preflight attributed the port to a *client*
socket; `ss` shows the LISTEN owner is `ndtwin_kernel` pid 845333 and the curls are fd=8
client sockets on the same line.
(e) ":9000 HAS a listener whose owner is not visible to this uid (root-owned)" -- the
LISTENER-OWNER-HIDDEN three-state firing correctly.
(f) also FAIL: `/tmp/ndtwin_p4_switches.json` already existed at preflight (H-20 hazard: a
failed fabric would let the manifest check read the stale file and pass).

**11. `make_topology.py --hosts N --stdout` cannot be redirected to a JSON file.**
`raw/B6_make_topology.log`. `--stdout` prints the round-trip report **ahead of** the JSON, so
`make_topology.py --hosts 12 --stdout > f.json` yields a file that is not valid JSON
(`JSONDecodeError: Expecting value: line 1 column 1`). Stripping the leading report parses
fine (`nodes: 22, edges: 56`). `setting/` was not written to. Recorded, not fixed.

**12. `/ndt/historical_logging` takes `state` as a QUERY parameter, and three routes the chaos
harness calls do not exist.** `raw/C8_b3_historical_logging.log`. `{"state":true}` and
`{"state":"enable"}` in the body both return **400**; `?state=enable` returns 200 with the B-3
`not_applicable` payload. `POST /ndt/set_historical_logging`, `/ndt/get_historical_data` and
`/ndt/set_historical_logging_state` all return **404** -- the LEDGER's "0-hit" note confirmed live.

**13. `/ndt/disable_switch` is missing from the kernel dispatch table.**
`raw/C5_contract_l3_p4.log`. `MISSING /ndt/disable_switch not in the kernel's dispatch table`,
leaving `Energy-Saving-App` DEGRADED. Recorded as a known gap by the tool itself.

**14. The Energy-Saving-App spams `release_lock` failures.**
`raw/C32_energy_powered_off.log`, energy pane: repeated
`release_lock: bad HTTP code 412 or null body: {"detail":"Lock 'routing_lock' is not held",...}`
-- it releases a lock it does not hold, on every switch cycle.

**15. A-9 records a deliberate hole.** `raw/C20_a9_lock_lease.log` step 6: a **bare release
naming no lease** succeeds (200) against a lock held on lease 5. `setRequireLeaseId` is off by
design; recorded so the B-2(2) hole is not mistaken for closed.

**16. A stale pidfile survived from an earlier session.**
`raw/C3_running_kernel_identity.log`: `app_viz.pid = 286486 ; alive? NO (stale pidfile from an
earlier session)`.

**17. `ndt up` must NOT be launched inside `systemd-run --user --collect` -- systemd kills the
kernel it just started.** `raw/E4_systemdrun_kills_fabric.log`. Two separate defects, one after
the other:
(a) `systemd-run --user` does **not** inherit the caller's cwd, so a relative
`tools/test_workflow/ndt` exits 127 (`No such file or directory`). Needs
`--working-directory=/home/adam/Desktop/NDTwin-Kernel` plus an absolute path.
(b) With that fixed the bring-up **succeeded** (`up. ready`, `data plane: h1 -> 10.0.0.2
forwards`) -- and then, because the unit's main process *is* the bring-up command, systemd tore
down the cgroup the moment it returned: `Killing process 969362 (ndtwin_kernel) with signal
SIGKILL`. The root-owned tmux topo session survived (`Failed to kill control group ...
Operation not permitted`), so the machine was left with 15 host/switch processes and no control
plane. `raw/E5_teardown_stop.log` cleans that up.
**Rule for the next round: bring the fabric up with `setsid` (detached, not owned by a unit).
`systemd-run` remains right for long *runs* -- builds, `local_ci.sh`, `run_layers.sh`, a fault
round -- because those are commands that end.** The P4 half got away with it (`raw/C1`) only
because its kernel ended up under the root tmux server, outside the unit's cgroup.

**18. A concurrent writer was committing to the shared worktree during the round.**
`raw/B20_concurrent_writer.log`: `4206c2cb` landed at 20:52:52 (mid-build) and `913a7284` at
21:13:02, both while this round was running. B20 verifies `src/ include/ tools/ p4_proxy/
setting/` were untouched, so the binary provenance still holds -- but `ndt status` reports a
different `code` sha at different points in the round (f41a06a6 -> 913a7284 -> ace018b3).

---

## (d) Environment

**Kernel under test (the integrated binary):**
- path `build/bin/ndtwin_kernel`
- sha256 `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`
- size 75990144, build type **Debug** (Ninja), built 2026-09-02 20:52:20 -> 20:58:02,
  `cmake --build build -j2` under `systemd-run --user --unit=ndt-live-kernelbuild2`,
  83/83 targets, `BUILD_RC=0`, no oomd kill in the window (`raw/A6`, `raw/A7`)
- **source commit `f41a06a65daf86d12a2e0b24845f261328e59350`** (trunk HEAD at 20:50:48,
  `raw/A0`), descendant of `36d832f5` "Merge trunk into the 09-02 integration branch".
  Caveat from `raw/B20`: `4206c2cb` was committed at 20:52:52, inside the build window, but it
  touches only `tests/shell/test_ep4_gate_and_abort_evidence.sh`; `src/ include/ tools/
  p4_proxy/ setting/` were unchanged, so the binary corresponds to f41a06a6's kernel sources.
  `raw/C28` (21:45) records HEAD as `913a7284` -- that is a later HEAD, not the build commit.
- discriminator (`raw/A8`): 8 fix strings present in this binary and absent from the production
  binary -- `topology-round-partial`, `left_link_bandwidth_source`, `stale_since`, `stale_polls`,
  `counters_cover`, `telemetry_status`, `down_reason`, `not_applicable`. `priority_honoured`
  and `table_generation` are 0 in **both** because they live in the Python proxy, not the kernel.
- runtime identity confirmed (`raw/C3`): `/proc/845333/exe` and the on-disk file are the same
  inode (66309/1443760), and the live kernel served `left_link_bandwidth_source` in
  `get_graph_data`.

**Production kernel backups -- four copies, all sha256 `e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94`** (`raw/A1`, `raw/A3`, `raw/A5`):
1. `.test_run/binaries/e-round/ndtwin_kernel.production-backup`
2. `~/ndtwin-artifacts/production-kernel/ndtwin_kernel.production-2026-08-31` (+ README)
3. `.test_run/binaries/pre-integ-2026-09-02/ndtwin_kernel.e3bad23c` (+ `.provenance`, made this round)
4. the live copy itself, which this round **replaced** in `build/bin/`.
Restore = `cp .test_run/binaries/pre-integ-2026-09-02/ndtwin_kernel.e3bad23c build/bin/ndtwin_kernel`.

**Topology used:** `setting/StaticNetworkTopologyP4_10Switches_128Hosts.json` --
10 BMv2 switches, 128 hosts, 288 edges, 138 host/switch namespaces, 16256 destination paths.
bmv2 binary `/usr/local/bmv2-fast/bin/simple_switch_grpc` (sha256
`3ff54b5c1901c9d3ffd80ac05dc3dc7d0e696e3df73174c1616fb87ac9aedb4a`, `raw/B13`).
Sample rate 1/256, compiled into `ndtwin_switch.json`.

**Machine:** 14 cores, 15412 MB RAM + 20479 MB swap, `/` 92% full with 8.3 G free (`raw/A0`).
`ip_local_port_range 32768 60999`. A `qemu-system-x86` VM (1552 MB) ran throughout -- an
invisible covariate (`raw/C28`, `raw/C30`).

**Currently torn down vs running** (verified live at 2026-09-02T23:21 by
`raw/E5_teardown_stop.log`, after `ndt down --deep` + `ndt clean` both returned 0):
- kernel `:8000` **closed**; `:8081` proxy **closed**; `:8080` ryu **closed**; `:9000` free.
- bmv2 switches **0**; topo session **absent**; manifest **absent**; host/switch namespaces **0**;
  no apps running; no tc netem. `ndt clean` says **clean**.
- `build/bin/ndtwin_kernel` is the **integrated** binary `a8ba99c2...`, left in place as the
  demo candidate. The production binary is NOT installed; restore it with the `cp` above.
- `ovs-vswitchd` is **active** -- it is the host daemon, it was already running before this
  round started, and nothing in this round started or stopped it. Leave it alone.
- lab claim: **`auditor`, until 01:51:28. Do NOT release it** -- it is being held for the
  rounds that follow.
- repo HEAD keeps moving under this worktree (`f41a06a6` -> `913a7284` -> `ace018b3` ->
  `6a3a8135` -> `6283ff5e` during the round). Other sessions commit here; nothing in this round
  was committed, and nothing was pushed.
- Note at 23:12, before E1: `:8081` was still held by a proxy this stack had not registered
  (pid 925466, our own A-4c restart). E3 reaped it with `ndt down --deep`.

---

## (e) Resume-from-here

Written for someone with **zero context**. Type it as written.

### 0. State you are inheriting

The round stopped after PHASE 1. The machine is quiet (`raw/E5_teardown_stop.log`): no kernel,
no proxy, no Ryu, no bmv2, no topo session, no apps, ports 8000/8080/8081/9000 free.
`ovs-vswitchd` is running -- that is the host daemon, leave it alone.
`build/bin/ndtwin_kernel` is the **integrated** binary `a8ba99c2...`, not the production one.
The **lab is already claimed by `auditor` until 01:51:28. Do not release it.**
Next log number is **E6**.

### 1. Preamble for every session

```bash
cd /home/adam/Desktop/NDTwin-Kernel
export NDT_OWNER=auditor                      # every single ndt invocation needs this
RAW=doc/audit/2026-09-02_live-round/raw
NDT=tools/test_workflow/ndt

$NDT status                                   # claim must read "yours"; measuring must read "nothing"
```

If the claim has expired (after 01:51) or reads as someone else's, take it again -- do not
work under a stranger's claim:

```bash
$NDT claim 240 "auditor live round part 2: ovs4, remaining tools and fixes"
```

### 2. Bring the fabric up

**P4 plane (the one the A-D steps used):**

```bash
setsid $NDT up p4 128 < /dev/null > $RAW/E6_ndt_up_p4.log 2>&1 &
```

**OVS plane (what the REMAINING list needs -- T-1):**

```bash
setsid $NDT up ovs4 < /dev/null > $RAW/E6_ndt_up_ovs4.log 2>&1 &
# wait for the last line to read "up. ready", then:
$NDT status --check
```

🔴 **Use `setsid`, not `systemd-run`, for `ndt up`.** Finding 17: `systemd-run --user --collect`
SIGKILLs the kernel the moment the bring-up command returns, because the kernel is in the
unit's cgroup. `systemd-run --user --unit=... --collect --nice=10` is still the right wrapper
for long *runs* that end -- builds, `local_ci.sh`, `run_layers.sh`, a fault round -- and those
need `--working-directory=/home/adam/Desktop/NDTwin-Kernel` plus absolute paths, because it
does not inherit cwd.

### 3. Log convention

One file per step under `doc/audit/2026-09-02_live-round/raw/`, numbered `E6`, `E7`, ...
Each file starts with a header line:

```
#### <what this step proves> ####
```

Every number gets the binary sha beside it: `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`,
built from commit `f41a06a65daf86d12a2e0b24845f261328e59350`.
**Update this CHECKPOINT after every step, before starting the next one.**

### 4. Work order

Do **T-1 first** -- eight of the nine OVS items need that one window, and **T-7 destroys the
control plane, so it is the last thing in the window before teardown.**

1. `T-1 .. T-9` -- the OVS plane (section (a) REMAINING, first table). Suggested order inside
   the window: T-1, T-2, T-9, T-3, T-4, T-5, T-6, then `X-5` (B-1 OVS), `X-8` (A-4f OVS),
   `X-10` (F-13 on OVS), `X-11` (via T-6), then T-8, and **T-7 last**.
2. `T-10 .. T-23` -- tools with no run evidence (second and third tables). `T-19`/`T-20` unlock
   `T-22` and the live half of the `assert_window_span` instrument; `T-20` writes the
   `graph_energy_before.json` that `90_restore.sh` aborted without.
3. `X-1 .. X-12` -- section (b) REMAINING. `X-6` (B-2b) and `X-7` (B-4) work on **either**
   plane and have never been attempted; they are the cheapest items on the list.

### 5. Teardown at the end of a window

```bash
$NDT down            # plain down first: it refuses to kill what it did not start, which is the check
$NDT clean           # the assertion on its own; exit 1 if anything survived
$NDT down --deep     # only if a stray listener remains, and only after identifying it
```
Then write `.test_run/lab.handoff`. **Do not `ndt release`** -- the claim is being held.

### 6. Rules that still bind

- `NDT_OWNER=auditor` on **every** `ndt` invocation. Before touching the lab, check the
  `measuring` column, not the claim line.
- **Never `pkill -f` or `pgrep -f`.** To reap a stray listener use `ndt down --deep`, which
  names the pid and the port it is killing. To break a link use `tc netem` on **both** ends;
  never `ifconfig down` (it breaks the whole switch).
- Long-lived services: `setsid`. Long runs that end: `systemd-run --user --unit=... --collect
  --nice=10`.
- Any compile goes through the PATH shim (forces `-j2`); a wide build makes systemd-oomd kill
  Adam's app. Shim verified present at 23:2x:
  `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/4e0e8cb4-1c72-4731-b5fe-2989d7af1d65/scratchpad/shim`
  (a `cmake` and a `ninja` wrapper). It belongs to a dead session's scratchpad, so **check it
  still exists** and recreate the two wrappers forcing `-j2` if it has been cleaned up.
- **Do not `git commit`, do not push, do not release the claim.** The auditor session commits.
  This worktree is shared: HEAD moved five times during this round.
- Physical testbed, PDU API, switches and physical NICs are off limits. `server1-8`, `cc2`,
  `gw`, `gw2` are out of service.
- "Ran" and "read but not executed" never share a table. Write UNVERIFIED rather than infer.

### 7. Counts as of this checkpoint

**Tools -- 72 rows in the section (a) table:**
- **42 PASS** (incl. 3 "PASS (instrument)" -- the tool ran and correctly went red on the
  product; 3 "PASS (ran)" -- a harness stage that ran and reported its own FAILs; 1 "PASS
  (offline)")
- **8 FAIL**: `ndt apps te`; `ndt apps stop`; `run_layers.sh quick`; `run_layers.sh api p4`;
  `l1_unit_tests.sh`; `local_ci.sh`; `p4_coverage_gate.sh`; `l3_component_check.py --check-drift`
- **3 UNVERIFIED**: `stack.sh` (never invoked directly); `p4_power_helper.py` (usage path only);
  harness `90_restore.sh` (ran, aborted with nothing to restore to)
- **18 NOT RUN** (one of them, `ndt up ovs4`, aborted mid-way -- see finding 17), plus
  `ndt release` deliberately not run
- **23 REMAINING work items** `T-1 .. T-23`, plus 4 groups declared out of scope
  (`build_bmv2_fast.sh`, `tools/remote-lab/*`, the git hooks, `analyse_app_te_log.py`)

**Fixes -- 31 rows in the section (b) table:**
- **16 PASS** (incl. 1 "PASS (P4 arm)" -- F-13's six P4 cells)
- **8 UNVERIFIED**
- **1 explicitly did-NOT-reproduce**: B-5, with the kernel exit code UNKNOWN
- **6 R-5 verdicts**: F-3 FIXED, F-4 FIXED, F-2 STILL PRESENT, F-5b STILL PRESENT (P4 arm
  only -- it is a differential and needs the OVS arm), F-5 NO LONGER REACHABLE on P4,
  F-1 NOT REACHABLE on P4
- **12 REMAINING work items** `X-1 .. X-12`

**Findings: 18**, each with its log path.

**The three reds a human should look at first:** `ndt apps stop` false ok (finding 1);
`p4_coverage_gate.sh` red, pre-existing on trunk and needing an auditor/Adam call on
`--update-baseline` (finding 4); `l1_unit_tests.sh` scoring five green tests as failures
(finding 5), which is what makes `local_ci.sh` red.
