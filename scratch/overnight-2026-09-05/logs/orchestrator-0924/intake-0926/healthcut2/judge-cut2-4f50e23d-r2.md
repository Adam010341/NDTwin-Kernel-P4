# Judge r2: P4 health check, Cut 2 offline half, fix diff only (`feat/p4-health-cut2` @ 4f50e23d, code fa7fcb83; r1 was d70370c0)

[Co-developed with claude code -- Adam]

**How this was judged.** Read-only. I ran nothing and used no git. I read no audit, intake or handback document except the three this pass is about. I did not read DESIGN.md, so anything that turns on the design's exact wording is marked as such.
- **Read in full:**
  - the r1 review: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/judge-cut2-d70370c0-r1.md
  - the worker's handback: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/REPORT-r2-fa7fcb83.handback.txt
  - the committed SUMMARY: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/doc/audit/2026-10-03_p4-health-check/SUMMARY-cut2-offline.md (the same text as the copy in the handback)
  - expected_today.tsv, next to the SUMMARY
- **Code read under /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/:**
  - collect/fabric.py, collect/hosts.py, collect/config.py, collect/runner.py, collect/thrift.py (show_ports, pvs)
  - hostside.py, frames.py, observe_a.py, round_a.py, round_b.py
  - lab.py, lab_round.py, probe.py, identity.py, expected.py, report.py, run.sh
  - cells/verdict.py, the rows and self-checks of cells/table.py, s0.py:560-661
- **Tests:**
  - every new Cut 2 class in tests/python/test_p4_health_collect.py and test_p4_health_cells.py, including the fake fabric;
  - the r2 block of tests/shell/mutate_p4_health.sh.
- **Logs:** every r2 log the handback cites, under /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/r2/.
- **Spot-read for interactions only:**
  - recover.sh:1-240 (how each phase is handled);
  - p4_testbed_topo.py:183-229 (BMv2Switch launch);
  - the proxy's control_plane.mode (p4_proxy/proxy_agent/main.py:705,715);
  - tools/test_workflow/ndt:6769-6824 (`status --measuring`);
  - venv_fingerprint.sh.
- **Confidence:** N1 to N3 come from reading the code [high confidence]. Each names the test that settles it.

## Summary
- **What is sound.**
  - All three MAJORs and m1 to m7 and w1 are fixed as r1 asked. Each has a red on the pre-fix code for its own reason (m3 and m5 only coarsely, as the handback says), and every mutant is caught.
  - The fake fabric now prints both of iproute2's veth forms, and veth_format.log backs them.
  - For every marker it delivers, the fake fabric now sends back an ICMP port-unreachable quoting the marker. The fake sniffer uses hostside's own `record()`.
  - The orchestrator's three decisions are implemented as stated.
  - The §6 verdict lists and rollups match when I recompute them.
- **What is not.** There are two new defects on the first live run's path. Both sit where this diff now decides:
  - **N1:** after a stop signal in A, the new gate lets the probe claim the lab and bring up B. A signal that arrives during an HTTP call or a sniffer wait is swallowed entirely.
  - **N2:** when B's controller is refused by the new external check, or never starts, never gets ready or writes no result, the run still reads COMPLETE with rc 0. Three dimensions then read `can` on missing B evidence.
  - **Smaller items:** the dirty-tree refusal fails open, a TP1 NOT RUN leaves nothing to diagnose, and the §6 text disagrees with the code in five places.
- **The merge itself is harmless.** Nothing here acts before a live run.

## BLOCKER
None.

## MAJOR (new; fix with a test seen red before the first live run)

### N1: a stop signal during bring-up A does not stop the run, and B is claimed and brought up next
**Where.**
- **The round returns after a signal.** LabRound.run turns SIGTERM, SIGINT and SIGHUP into SignalAbort. It records "aborted by signal N", tears down, and then returns the record (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/lab_round.py:357-370).
- **The new gate still passes.** `ended_clean` (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/lab.py:73-89, used at :118-123) checks only:
  - the phase;
  - down_rc and release_rc;
  - "could not stop";
  - the leftover lists.
  After a clean teardown all of these pass, so lab.py:124-131 runs B: `ndt claim`, `ndt up p4 --app packages/B`, then the controller.
- **A second kill has no handler.** From A's `_restore_handlers()` (lab_round.py:366) until B's `_handlers(True)` (:338, after B's claim), SIGTERM has its default action. A second kill in that window can leave B's claim held, with phase "claiming" and nothing recover.sh can act on.
- **(b) The signal is swallowed on the way.** SignalAbort subclasses Exception (lab_round.py:49). Three `except Exception` blocks on the round's path catch it:
  - HttpClient.request (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/collect/config.py:59): the signal becomes an "unreachable" reply;
  - Hosts.sniff_wait (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/collect/hosts.py:152): it becomes "the sniffer did not end";
  - BRound.body (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/round_b.py:137).

  The pingall's sniffer wait alone can block for up to 150 s, so a kill during A is likely to be swallowed. Every remaining step then runs, A tears down, and B comes up.

**Why the gates are green.**
- `test_a_signal_still_ends_the_round` raises SignalAbort directly out of an observer and runs ARound only (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tests/python/test_p4_health_collect.py:1948-1953).
- R2-m2b pins only the re-raise in `run_step`.
- No test sends a signal through `Hosts.window`, an HTTP call or `run_lab`.

**Not introduced by this diff.** r1's code also ran B after an aborted A. But this diff's gate is now the one place that decides whether B may claim the lab. SUMMARY §1.1 also says "收到訊號仍然結束這一輪" (a signal still ends the round).

**Fix.**
- A record that carries "aborted by signal" ends the run: B is not brought up, health.json is still written, and rc is 2.
- Make SignalAbort derive from BaseException. LabRound.run's explicit `except SignalAbort` and `run_step`'s re-raise keep working.
- **Tests:**
  - SignalAbort from an observer through `run_lab` gives one claim, one up, and INCOMPLETE;
  - SignalAbort raised inside `FakeSniffer.wait` ends the round, and no later step is observed.
- **Mutants:**
  - drop the signal clause from the gate;
  - make SignalAbort an Exception again.

### N2: a B that never runs its controller leaves the run COMPLETE with rc 0, and the rollups show false `can`s
**Where.**
- **B's body returns normally.** The new external check returns `self.finish(None, None)` (round_b.py:100-104). So do the earlier exits: no spawn (:110-112) and no ready file (:118-120). A missing result only adds a problem (:130-131). In every case the body returns normally, so LabRound marks the round complete (lab_round.py:349-356).
- **B's problems go nowhere else.** They are written only to B/attributions.json (round_b.py:150-153).
- **The run reads COMPLETE.** `run_lab`'s `complete` looks only at the records and at its own `problems` (lab.py:138). `run_verdict` therefore returns COMPLETE with rc 0 (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/cells/verdict.py:364-371).
- **The rollups change.** Every RED that needs a bmv2 attribution now reads UNATTRIBUTED, and UNATTRIBUTED is not counted (verdict.py:319-333). Recomputed from §6's verdicts with B unconfirmed:

  | rollup | predicted | with B unconfirmed | dimensions that read `can` on missing B evidence |
  |---|---|---|---|
  | core | 9/1/3/3 | 10/0/1/5 | packet_io (on P1 alone) |
  | full | 6/4/3/3 | 9/1/1/5 | pre_clone, counters, packet_io |

**The code's own precedent is INCOMPLETE.** When B's claim is refused, the run reads INCOMPLETE and T4 is UNATTRIBUTED because "B never ran" (test_p4_health_collect.py:2400-2417). A B that claimed the lab but did nothing should read the same.

**Why it matters now.** The first live run is the first time controller_ext.py runs through the adapter; S0 only dry-runs it (m5). §6 steps 6 and 7 would show the problem, but the headline and the rollups would not.

**Why the gates are green.** `test_b_spawns_no_controller_on_a_fabric_that_is_not_external` (:2248-2253) and `test_no_result_file_confirms_nothing` (:2255-2259) drive `BRound.body` only. No `run_lab` test covers a B body that bails out.

**Fix.**
- When the controller was not started, never got ready, or wrote no result, end B's body with an exception after `finish()` has written attributions.json, or have `run_lab` add `b.problems` to `problems`.
- **Test:** `run_lab` reads INCOMPLETE with rc 2 when B's fabric stays at mode "ndtwin", and again when the controller never writes its ready file.
- **Mutant:** drop the propagation.

## MINOR — fix before the first live run
- **N3. probe.py lab's checks before the lab fail open.**
  - **The dirty check passes when git fails.** `_git` returns "" when git fails, times out or is missing (/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/probe.py:36-41). The dirty-tree refusal (:105-109) therefore reads a failed `git status` as a clean tree. Use the return code and refuse when it is not 0. Test: `_git` failing gives rc 2 and S0 does not start.
  - **A missing identity record does not stop the run.** Neither a missing `system_under_test` nor an "incomplete" fingerprint stops the run (:128-138). §6 step 8 calls the first authorized run's record the baseline for the standing authorization. Check the records before the lab, not afterwards in step 1.
- **N4. A TP1 NOT RUN on the live fabric leaves nothing to diagnose.**
  - **Nothing is kept.** `fabric_view` returns None from five places (observe_a.py:617, 624, 640, 644, 648) and keeps none of what it read. The real Runner keeps no stdout (collect/runner.py:43-56).
  - **Step 4 cannot be followed.** §6 step 4 says to look at `ip -o link show` when the oracle is null, but `ndt down` has removed the fabric by then. These veth forms are exactly what §3.1 lists as inferred.
  - **Fix:** keep in A/TP1.json the raw `ip -o link show`, every `show_ports` and every host's link and address text. At the least, keep the unplaced ports and which read failed.
  - **r1's test 10 is still open** (`show_ports` with `--cpu-port 510`). With this fix, a CPU port that `show_ports` lists turns TP1 into NOT RUN rather than RED, and takes SC-fwd, K1 and TTL1 with it.
- **N5. The see-red run's rc 1 hides an unclean teardown.**
  - `run_verdict` checks PROBE-BROKEN before INCOMPLETE (verdict.py:366-370). The run that passes on "PROBE-BROKEN, rc 1" therefore reports rc 1 even when A's `ndt down` or `ndt release` failed.
  - §6 step 2 is written for the full run (it names LAB_STATE.B.json). Make it apply to the see-red run as well:
    - LAB_STATE.A.json is released and empty;
    - `bringups[0]` has down_rc 0 and release_rc 0;
    - `ndt status` shows no claim and no bmv2.
- **N6. §6 and §2 against the code.**
  - **"delta：same 30、not observed 26" is off by one.** The table has 57 cells. The full run observes 30 of them (the 28 A cells, CP1 and PF-T), so 27 read "not observed". That is r1's "about 28" less VS1. The two control rows add 2 more "same". 30 + 26 = 56 matches neither 57 nor 59.
  - **The pre-check command cannot show what its comment asks for.** The comment wants "measuring nothing, no claim, bmv2 switches 0", but `ndt status --measuring` prints only the declared and measuring rows ("no OVS or bmv2 query", /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/test_workflow/ndt:6769-6824). Use plain `ndt status` (:6992). As written, r1's m4(e) is not met.
  - **§2 claims a red log and a mutant for every MAJOR and for m1 to m7** ("每一項都有…紅的 log…也都有 mutant"). m6 is wording only and has neither. m3's and m5's reds are interface errors, as the handback itself says.
  - **§2 says every observation is at fa7fcb83** ("都在 fa7fcb83"). In fact:
    - veth_format.log is at 1340729f;
    - fingerprint_offline.log and anchors_197_vs_201.log are at 91ec19c0.

    Say whether identity.py changed after 91ec19c0.
- **N7. m1 does not cover the controls.** `Control.judge(None)` returns phase "control" (cells/table.py:142-143). In a `--only` run, an unobserved control therefore reads "flipped" against its GREEN prediction; in the see-red run that is T3-neg. Give an unobserved control phase "unobserved", and add the case to the m1 test.
- **N8. §6's "run in the main checkout" (在主 checkout 跑) works against two new mechanisms.**
  - **The dirty check is taken only at the start** (probe.py:105). Root then runs hostside.py, frames.py and `__init__.py` from that shared tree for about 13 to 18 minutes. `system_under_test` and the fingerprint also record only the starting state.
  - **The fingerprint will change from run to run.** `repo_untracked` hashes every untracked file that is not ignored, outside .test_run/ and scratch/ (identity.py:89-100). In the main checkout, this session's git status (an uncommitted observation) shows WAKEUP.md, AGENTS.md, .agents/, .codex/, build-telemetry-telemetry/ and other sessions' doc/audit logs. A rerun's fingerprint will differ for reasons unrelated to the system, so the first run's record will never grant the standing authorization. This fails closed, but it defeats the record's purpose.
  - **Fix:** run from a dedicated clean worktree at the merged trunk sha, or copy the three files root runs into the run directory and execute those copies.

## MINOR — can wait
- **w-a. A failed knob restore does not keep B out.**
  - `ended_clean` ignores `knobs_restored`, and a failed restore leaves the round complete (lab_round.py:447-450, Cut 1 code).
  - recover.sh does nothing to the knobs for a released phase (recover.sh:164-171).
  - So B runs, snapshots A's unrestored bytes, and later "restores" those.
  - LAB_STATE.A.json now keeps the original bytes, so they can still be restored by hand.
- **w-b.** A tracked file that cannot be read hashes as "absent" (identity.py:98). "An unreadable part is not a match" therefore does not hold for tracked files.
- **w-c.** `run_step` also catches OSError from `lab_round.register` and `write_state` (round_a.py:158). A failed LAB_STATE write no longer stops the round, which keeps starting root sniffers it cannot record. Their windows bound how long they run.
- **w-d. Three mutant names claim more than the mutant does:**
  - R2-M3a is killed by StateInUse escaping `run_lab` (an ERROR). LabRound's refusal already keeps B out, so the mutant never shows "B is brought up".
  - R2-m7 inverts the "absent" check; it does not move the read after a write. VS1 writes nothing today, so before and after are the same read.
  - R2-w1 keeps `pycache_prefix`, so its .pyc files land under the run directory, not beside the sources.
- **w-e.** hostside's `cmd_send`, `cmd_sniff` and `main` have no test. The fake parses Hosts' argv with its own `opts()` (test file:1588-1594), so a flag renamed on only one side would stay green. Reading both sides, today's flags match.

## Per item: fixed as asked, red for its own reason, mutant faithful
| item | fixed as r1 asked | red on pre-fix code | mutants |
|---|---|---|---|
| MAJOR-1 | Yes. Both forms are parsed (fabric.py:37-43). Switch edges are linked by peer name, and every listed port must be placed or the oracle is None (observe_a.py:629-648). The fake prints the real forms (test file:1490-1510, 1603). The mirror case is pinned (:2083-2090). | Yes: major1.OLD_red.log:2-3 (TP1 RED), :18-19 (see-red K1 and TTL1 NOT RUN), :16-17 (parser). | R2-M1a and R2-M1b are caught by the tests r1 named. |
| MAJOR-2 | Yes. Only UDP to the cell's dport with ip_dst equal to the receiver counts (hostside.py:117). hosts.py passes both (:108-111), and round_a and round_b pass the dports (round_a.py:107,115; round_b.py:133). The fake sends ICMP type 3 code 3 for every delivered marker (test file:1647-1650, 1677-1688) and its sniffer uses `HS.record` and `--until` (:1714-1719). | Yes at face value: major2.OLD_red.log:3, 7 ((20,30)), 15 (ICMP quote recorded). It came from an uncommitted intermediate test that called the old 3-argument `record()`; the committed tests reproduce only the coarse major2_m3 red. | M2a to M2d are faithful. |
| MAJOR-3 | Yes, for the three cases r1 listed (lab.py:73-96, 118-123; lab_round.py:63-87, 163-167; round_b.py:98-104). Still open: N1 and N2. | Yes: major3.OLD_red.log:26-31 ((2, 2) != (1, 1)) and :24 (controller started on an ndtwin fabric). | M3b to M3e are faithful; M3a's name claims too much (w-d). |
| m1 | Yes for cells and aliases (expected.py:41-49; verdict.py:309-313). Not for controls (N7). | Yes: m1_m2.OLD_red.log:2-3; m1_alias.OLD_red.log:2-3. | m1 and m1b are faithful. |
| m2 | Yes (round_a.py:150-161). | Yes: m1_m2.OLD_red.log:6-7. | m2a and m2b are faithful. The signal claim is wider than the test (N1b). |
| m3 | Yes, for the four pieces r1 named. | Coarse (interface errors), as disclosed. | m3a to m3d are faithful. |
| m4 | (a) Yes, but fails open (N3). (b) Recorded in health.json (test file:2328-2336). (c) to (e) are §6 steps, and (e)'s command does not do it (N6). (f) Each bring-up keeps its own LAB_STATE.<X>.json. | (a) yes: m4.OLD_red.log:4-5. (b) is a new module, so the mutants are its red. | m4a to m4d and m4f are faithful. |
| m5 | Yes. S0 dry-runs the adapter (s0.py:598-616; s0-final/probe.log:53), and A-MUT's drop check is pinned (probe.log:27). | Coarse: m5.OLD_red.log:2-3 (the method does not exist). | m5a to m5c are faithful. |
| m6 | Yes (frames.py:7-10; SUMMARY §1.2 and §3). | n/a | n/a (but §2 claims one; N6). |
| m7 | Implemented as decided: tsv:5, 30, 57-60; the table's cut fields, pinned by test_p4_health_cells.py:1075-1076; `observe_vs1` in STATIC (round_a.py:48). `pvs_get` on both builds is covered by S0's vs_trial (vs_trial.py:120-121; probe.log:50). | Yes: m7.OLD_red.log:2-3, 6-7. | Caught; name off (w-d). |
| w1 | Yes (hosts.py:69-74). | n/a (the test checks the flags) | Caught; name off (w-d). |
| w12 | Explained, and the arithmetic holds: 201−5+1 = 197 and 252−11+1 = 242 (anchors_197_vs_201.log:3-21; check_gate_anchors.HEAD.log:109). | — | — |

## The fake fabric and the format evidence
- **The forms.**
  - veth_format.log (iproute2-6.1.0, unprivileged namespaces) shows:
    - a same-namespace peer printed by name (:5-6);
    - a peer in another namespace printed by index (`s1-eth1@if2`, :10);
    - the child's `h1-eth0@if3` (:13).
  - The fake prints exactly these forms.
- **What is still inferred.** That every switch port of a Mininet fabric sits in the root namespace is still read from the code, as §3.1 says. BMv2Switch passes only ports without an IP as `-i` (p4_testbed_topo.py:209-211), and that excludes `lo`.
- **ICMP.** Every delivered marker gets a type 3 code 3 back, quoting the whole datagram. That is a worst case compared with Linux's ICMP rate limit, which is the right direction for this test.
- **Not modelled:**
  - the sender's own outgoing frames (the `sniff_loop` unit test covers them);
  - a CPU port in `show_ports` (N4).

## New code: lab safety and false greens
- **fabric_view.** No false green: a port it cannot place makes the oracle unreadable. The diagnosis gap is N4.
- **hostside's `record()` filter.** It only narrows what counts, so it cannot create a GREEN. The root argv has the same shape plus `-B -X -I`.
- **`ended_clean`.** It closes r1's three cases. It is still open after a signal (N1), and it ignores the knobs (w-a).
- **LabRound's `state_in_use`.** It refuses before anything is touched. The terminal phases are right, and "claim-unverified" is conservatively not terminal. I found no hole.
- **round_b's external check.** It reads the field the proxy actually reports (main.py:705,715). Its refusal path leaves the run COMPLETE (N2).
- **identity.py.** It only reads, and runs git, venv_fingerprint.sh (importlib.metadata only) and the three interpreters; nothing touches the lab. See w-b and N8.
- **probe.py's dirty refusal.** It fails open (N3) and is checked only at the start (N8).
- **round_a's per-step guard.**
  - An observation with every field None reads NOT RUN for every kind of cell: at step 0, at the control step, at step 3 or at step 4. I checked every `needs_answer=False` and `needs_oracle=False` row. So there is no false green.
  - See w-c and N1b.

## Audit of the worker's verdicts
| claim (handback or SUMMARY) | class |
|---|---|
| Head fa7fcb83; every gate rerun there and green | SUPPORTED. Checked: test_cells.py3.8.20.log:1, 37-40; test_collect.hermetic.py3.8.20.log:1, 5-8; seal_report.green.py3.8.20.json; mutate_p4_health.log:1, 1526-1535; s0.run.log:1-5; s0-final/probe.log:1-57; check_gate_anchors.HEAD.log:109, 142; H5:1271; H6:671. |
| The merge alone was green | SUPPORTED (merge.suites.log; one interpreter only, 3.12.3) |
| Both iproute2 forms settled without root | SUPPORTED (veth_format.log:5, 10, 13) |
| MAJOR-1 fixed; red; mutants; "covers the mirror-image false GREEN" | SUPPORTED. On the old code the mirror case read RED (ports differ), not GREEN; the new test pins the stronger "unreadable". |
| MAJOR-2 fixed; red "for its own reason"; mutants | SUPPORTED; the test text behind that red is not archived. |
| MAJOR-3 fixed; red; mutants | SUPPORTED for the three named cases. R2-M3a's kill is an ERROR via StateInUse. |
| m1, including the alias follow-up; "no cell reads flipped" | SUPPORTED for cells and aliases. Controls in `--only` runs still read flipped (N7). |
| m2 as built (exception recorded, observation unreadable, SignalAbort re-raised) | SUPPORTED |
| SUMMARY §1.1 "收到訊號仍然結束這一輪" (a signal still ends the round) | CONTRADICTED outside the tested case: config.py:59, hosts.py:152 and round_b.py:137 swallow it, and the run goes on to B (N1). |
| m3 | SUPPORTED (coarse red disclosed; the mutants carry it) |
| m4(a) "refuses (rc 2) if git status … is non-empty" | SUPPORTED as stated; fails open when git fails (N3). |
| m4(b) "one digest per part of Q6(a)'s must-be-same set; an unreadable part makes it incomplete" | UNDER-EVIDENCED. No test maps the parts to the design's list, and an unreadable tracked file reads "absent" (w-b). |
| "A read-only run took about 5 s" | UNDER-EVIDENCED: fingerprint_offline.log has no timing, and it ran on a worktree with 0 untracked files. |
| m4(c) to (f) | SUPPORTED, except (e): its command cannot show bmv2 or a claim (N6). |
| m5, m6, m7, w12 | SUPPORTED |
| w1 flags; "checked by hand that sniff --help runs with -B -I" | Flags SUPPORTED; the hand check is UNDER-EVIDENCED (no output). |
| "H5 and H6: two more non-hermetic copies" (listed as beyond the list) | UNDER-EVIDENCED. r1 already audited H5 (38 failures) and H6 (40) at d70370c0; now 45 and 47. The handback does not say whether they were rebuilt or are new. |
| Housekeeping: no leftover processes, 2987 MB free | UNDER-EVIDENCED (no output quoted) |
| §2 "every MAJOR and m1 to m7 has a red, a green and a mutant" | CONTRADICTED for m6; coarse for m3 and m5. |
| §2 "all observed at fa7fcb83" | CONTRADICTED for three rows (N6) |
| §4 "the end-to-end fake test matches the tsv; nothing flipped" | SUPPORTED (test file:1865-1883, 2350-2353) |
| §6 verdict lists, controls, self-checks, see-red prediction | SUPPORTED (recomputed; test file:2419-2431) |
| §6 rollups 9/1/3/3, 6/4/3/3, 0/0/0/6 | SUPPORTED by recomputing each dimension, provided B runs (N2) |
| §6 "same 30, not observed 26, flipped 0" | CONTRADICTED: the count is 27 (N6) |
| §6 "COMPLETE, rc 0" as the success signal | UNDER-EVIDENCED: a B that never ran gives the same (N2) |
| §6 pre-check line and step 4 | CONTRADICTED by ndt's `--measuring` output and by what the run records (N6, N4) |
| §6 see-red "PROBE-BROKEN, rc 1 is what §5.2-④ wants" | SUPPORTED as a prediction; not enough on its own as a pass signal (N5) |

## Tests I would have run
1. SignalAbort raised from an observer, inside `FakeSniffer.wait` and inside an HTTP call, each through `run_lab`. Count the `ndt claim` and `ndt up` calls and read the run verdict.
2. `run_lab` with B's fabric left at mode "ndtwin", and with a controller that never writes its ready file. Read the run verdict and the rollups.
3. `probe.main(["lab", …])` with `_git` failing (rc 128, or a timeout). It must give rc 2 before S0.
4. The delta counts in the full fake run's 00_table.tsv.
5. The control rows of an `--only` run.
6. hostside's own argument parser on the exact argv that `Hosts.send` and `Hosts.sniff_start` build.
7. A simple_switch_grpc started like BMv2Switch (data ports as `-i`, `--cpu-port 510`): what `show_ports` lists (r1's test 10).
8. A knob-restore failure in A, through `run_lab`.
9. `fabric_view` on a fake with one extra unlinked port: does the observation say which port?
10. Live only: `find tools/p4_health -user root` and `-newer <run>/probe.log` after the run (r1's test 9).

## Internal inconsistencies
- §6's delta counts sum to 56, but the table has 57 cells plus 2 controls.
- §2 claims a red and a mutant for every item, but m6 has neither and the handback calls the m3 and m5 reds coarse.
- §2 says everything was observed at fa7fcb83, but line 1 of veth_format.log names 1340729f, and line 1 of fingerprint_offline.log and anchors_197_vs_201.log names 91ec19c0.
- §1.1 says a signal still ends the round; config.py:59, hosts.py:152 and round_b.py:137 say otherwise.
- §1.3 says the whole run is INCOMPLETE when B does not come up ("否則 B 不起，整輪 INCOMPLETE"). That holds for the gate's conditions, but a B that starts and then does nothing reads COMPLETE (N2).
- §6's pre-check comment asks `ndt status --measuring` to show things it never prints.
- The handback calls H5 and H6 additions, but r1 audited them at d70370c0.
- The names of R2-M3a, R2-m7 and R2-w1 do not match what their mutations do (w-d).
- Consistent: I recomputed the rollups from §6's verdicts and they match.

## Verdict
**Conditions:**
- Fix N1 and N2, each with a test seen red and a mutant.
- Fix N3, N4 and N7, and the §6 and §2 text (N5, N6, N8).
- Rerun the gates. Run them once more after the next run-identity head lands, as the handback already says.
- A judge pass on that diff only.
- No live run before that.
- w-a to w-e can wait.

MERGE AFTER FIXES
