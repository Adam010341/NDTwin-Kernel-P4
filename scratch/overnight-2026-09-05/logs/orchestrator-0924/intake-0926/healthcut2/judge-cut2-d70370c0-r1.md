# Judge r1: P4 health check, Cut 2 offline half (`feat/p4-health-cut2` @ d70370c0, code 50c3379d)

[Co-developed with claude code -- Adam]

**How this was judged.** Read-only. I executed nothing, used no git, and read no other audit, intake or handback documents.
- **Read in full:**
  - the worker's handback (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/REPORT-50c3379d.handback.txt`), including the SUMMARY it carries;
  - DESIGN.md r6 with §12–§14, and expected_today.tsv;
  - every file the live path executes: hostside, collect/{hosts,runner,thrift,sniff,fabric,proxy,kernel,ps,config}, observe, observe_a, round_a, round_b, controller_ext, attribution, ctrl_trial, lab, probe, run.sh, report, expected, cells/{verdict,table}, lab_round, the head of recover.sh, the changed parts of s0.py, and exercise/{hc_main.p4,gen_runtime.py,mycontroller.py};
  - the Cut 2 test classes and the Cut 2 block of `tests/shell/mutate_p4_health.sh`;
  - every gate log cited.
- **Spot-read where the design cites them:** `p4_proxy/mininet/p4_testbed_topo.py` (BMv2Switch, host rename, offloads), `tools/p4_exercise/run_external_controller.py`, `p4_client.py:553-586`, `main.py:512-521`, and one function each from convert.py and preflight.py.
- **Confidence:** MAJOR-1 and MAJOR-2 rest on documented iproute2 and Linux behaviour that I could not run. Each is marked [inferred, high confidence] with the one check that settles it.

## Summary
- **What is sound:** the verdict machinery, B's attribution logic, the seal and the 43 new mutants. The new decision paths that have mutants are pinned well.
- **What is wrong:** three defects sit exactly where the gates cannot see:
  - the TP1 fabric oracle;
  - the sniffer's filter;
  - the composition of two bring-ups.
  
  In the first two, the fake fabric shares the code's wrong assumptions. The third has no test.
- **Consequence:** as delivered, the first live run cannot produce the predicted table:
  - TP1 reads a false RED;
  - once that is fixed, SC-fwd fails on a healthy fabric;
  - the see-red run cannot see red for the stated reasons;
  - a failed teardown in A destroys A's recovery record, and B is brought up anyway.
- **Merge itself is harmless.** Nothing here harms the lab until it is run.

## BLOCKER
None.

## MAJOR (fix with a test seen red before the first live run)

### MAJOR-1: TP1's fabric oracle sees no switch-to-switch link on a Mininet fabric (false RED; K1, TTL1 and the see-red run go with it)
**Where.** `veth_peers` matches only the `N: name@ifK:` form (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/collect/fabric.py:30`). `fabric_view` takes its switch edges only from that map (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/observe_a.py:591-607`).

**Why it fails live.** [inferred, high confidence]
- BMv2Switch subclasses Mininet's `Switch` (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/p4_proxy/mininet/p4_testbed_topo.py:182`), so switch interfaces live in the root namespace.
- Both ends of every switch-to-switch veth (`addLink`, same file, :384) are therefore in the root namespace.
- iproute2 prints a same-namespace peer by name: `15: s1-eth4@s2-eth1:`. It prints `@ifK` only when the peer is in another namespace, which is only on host-facing ports.
- Result: the oracle gets the 6 host edges and 0 switch edges, while `get_graph_data` has both.
- `tp1()` (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/cells/table.py:632-639`) then returns RED "edges differ", attributed structural and counted. The core rollup reads topology = cannot.

**Cascade.**
- SC-fwd is gated on TP1 (same table.py, :948), so SC-fwd, SC-count and SC-reg are NOT RUN, and K1 is NOT RUN.
- SC-ttl is gated on TP1, so TTL1 is NOT RUN.
- `links_from` is empty, so `hops_from_lpm` would return 1, not 2.
- The see-red run gives K1 and TTL1 NOT RUN and COMPLETE with rc 0, so §5.2-④ is not met.
- The full run is "publishable" with a false topology RED.

**Why the gates are green.**
- The fake fabric writes switch-to-switch peers as `@if<N>` (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tests/python/test_p4_health_collect.py:1288-1293`), a form a root namespace never prints for them.
- The only veth fixture (same file, :587) is a host-facing line.
- No mutant touches `fabric_view`.

**Settle with:** `ip link add a type veth peer name b; ip -o link show a` prints `a@b:`.

**Fix.**
- Parse both forms: `@ifK` as an index, `@name` as a name.
- Make the fake emit the real form.
- Add a mutant that drops the name form; it must turn `test_bring_up_a_reads_as_predicted` red.
- Keep a negative case where both the oracle and the graph lack switch links. That is the mirror-image false GREEN.

### MAJOR-2: the sniffer counts ICMP port-unreachable errors as received markers; with `--until`, the pingall sniffers stop early and SC-fwd fails on a healthy fabric
**Where.** `record()` (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/hostside.py:84-94`) accepts any frame whose payload carries magic + token + cell. For non-UDP frames, `frames.parse` searches for the magic anywhere past the IP header (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/frames.py:167-170`).

**Mechanism.** [inferred, high confidence]
- Every marker reaches a closed UDP port carrying the host's own IP and MAC (gen_runtime `host_mac` equals topology.json `mac`).
- The host answers with ICMP port unreachable, and Linux copies the whole 53-byte datagram into it, marker included.
- Nothing in `p4_proxy/mininet` suppresses ICMP.

**Impact.**
- In the pingall every host also sniffs for "SCfwd" with `until=15` (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/round_a.py:122-123`).
- I walked the send order (h1→all, then h2→all, and so on). ICMP records fill the sniffers before later senders' markers arrive. h1 and h6 see 5 sources each, h2 sees 4, h3 3, h4 3, h5 4: 24 of 30.
- `sc_fwd` therefore fails, giving PROBE-BROKEN for SC-fwd, then for K1 and TTL1, and the run ends PROBE-BROKEN with rc 1.
- The see-red run would then fail with the reason "SC-fwd", not "SC-count" and "SC-ttl".
- MAJOR-1 currently hides this, because SC-fwd is NOT RUN by its gate.
- Other windows are unaffected: a receiver's own ICMP is outgoing and skipped, and B's h4 sniffer filters on cell P3.

**Settle with:** send 3 markers to any host while sniffing on the sender.

**Fix.**
- Count only UDP frames whose dport is the cell's, ideally also with ip_dst equal to the receiver's IP.
- Add `record()` tests with an ICMP-embedded marker.
- Make the fake emit ICMP echoes.
- Add a mutant on the UDP filter.

### MAJOR-3: `lab.run_lab` brings up B whatever A's teardown left, and both bring-ups write the same `<run>/LAB_STATE.json`
**Where.**
- B runs unconditionally after A (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/lab.py:83-95`).
- Both rounds use `cfg.lab_state_path` (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/collect/config.py:139-140`).
- B's LabRound starts from a fresh state and writes it at its first step (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/lab_round.py:125-130,263,266`).
- `recover.sh` reads only that one file (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/recover.sh:58-61`).

**Failure cases.**
- If A ended in any of these states, B erases A's phase, knob snapshot, package and leftover pids:
  - down-failed (lab_round.py:388-392: not released, fabric possibly up);
  - claim-lost (:340-351: stopped before the knobs or the down);
  - a failed kill that was kept for recover.sh.
- In the down-failed case the claim is still our own and live, so `check_lab` passes. B then claims and runs `ndt up p4 --app packages/B` over the fabric A could not take down, unless ndt up itself refuses.
- The B controller then dials localhost:30051-30054. The adapter's mode check reads only the package file (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_exercise/run_external_controller.py:104-112`), not what is actually up.

**Coverage.** No test exercises this. The only failure test fails B's claim, not A's teardown.

**Fix.**
- Start B only if A has down_rc 0, release_rc 0 and no kill failures (that is, phase released with empty process lists).
- Make LabRound refuse to overwrite a non-terminal LAB_STATE.json, or use per-bring-up state files and teach recover.sh to read them.
- Before spawning the controller, read `switch_state` and require the external control plane.
- Tests: A's down fails, A loses its claim, A's kill fails. In each, there must be no second claim or up, and LAB_STATE.json must still be A's. Add a mutant that removes the gate.

## MINOR — fix before the first live run
- **m1. The Δ column reads "flipped" for every cell this run did not observe.** Neither `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/expected.py:38-42` nor `report.py:12-30` handles phase "unobserved". That is about 28 cells in the full run. SUMMARY §6 step 7 ("only R3 flipped") is wrong.
- **m2. `ARound.body` has no per-step guard** (round_a.py:140-142). An unexpected live shape raises out of TP1, the second step, and every later cell reads "not observed". Example: `mac_from_kernel(None)` (observe_a.py:567). Catch per step, record the exception, and leave that observation unreadable.
- **m3. `hostside.py`, the only code that runs as root, has no test and no mutant.** No test references it. Cover the `record()` filters, the outgoing skip, the SENT/READY/DONE format against collect/sniff.py, and `pick_iface`.
- **m4. Gaps in the live procedure:**
  - (a) Abort if tools/p4_health is dirty. Root executes hostside.py, frames.py and `__init__.py` from a shared working tree, and probe.py:44-48 only records "+uncommitted".
  - (b) Capture the Q6(a) gate fingerprint and the `system_under_test` record (DESIGN §4.3). health.json (report.py:56-72) has neither, and without the first authorized run's record the standing authorization can never apply.
  - (c) Archive the run dir to audit-raw.
  - (d) Run the see-red run only if PL1, T1 and TP1 are GREEN and both teardowns were clean.
  - (e) Pre-check that no bmv2 is up.
  - (f) On rc 2, read each bring-up's record; today only B's is kept (MAJOR-3).
- **m5. The live B adapter path has never run with controller_ext.py.** ctrl_trial connects explicitly (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-cut2/tools/p4_health/ctrl_trial.py:71`). Add `run_external_controller.py <run>/packages/B controller_ext.py --dry-run` to S0. Also pin S0's new safety checks with tests: dropping A-MUT from the drop-check list (s0.py:291) is caught by nothing, and that is the package that goes live in the see-red run.
- **m6. SUMMARY corrections:**
  - the §6 predictions depend on MAJOR-1 and MAJOR-2;
  - §1.2 calls the DigestList and packet-in checks "a reading that does not go through the controller", but they are the controller's own report matched against fields the probe chose (design-sanctioned, but say so);
  - frames.py:7-9 still says the live sender uses scapy.
- **m7. Two decider items, not blocking: R3, and AP1/AS1/IT1/VS1.** Settle both before the live run (see Q5).

## MINOR — can wait
- **w1. Root writes outside the run dir.** The root python writes and reads .pyc in tools/p4_health/__pycache__, and the script directory is sys.path[0] for a root process. Use `-B -X pycache_prefix=<run>` (and `-I`) in hosts.py:86-101.
- **w2. LAB_STATE records the sudo front-end, not the root python.** SIGTERM is relayed, so normal stops work. Two edge cases leave a root process unrecorded:
  - a subprocess timeout or abort SIGKILLs sudo and orphans the root sender (bounded by count/pps);
  - a failed `register()` leaves a sniffer running unrecorded (bounded by its window, up to 180 s).
- **w3. Seal gaps.** AF_PACKET sockets are not refused. `Config.p4dev_python` is not in DEFAULTED (config.py:96-97,118); it is covered only because spawns are refused.
- **w4. Decision paths with no red of their own:**
  - `fabric_view`, and `graph_view` beyond byte order;
  - controller_ext.py (S0 integration only);
  - S0's A-MUT and ctrl_trial checks;
  - `lab.expectations()`;
  - round_a's step order;
  - the C2, R3 and T7 negative reads;
  - the MT3 no-handle path;
  - `sniff_wait` and `wait_ready`;
  - `BRound.finish`'s expected values.
- **w5. §2.1's per-window "alive" marker is not implemented and not disclosed.** No Cut 2 GREEN rests on "nothing arrived", so there is no false green from it today.
- **w6. The pingall ignores ip_dst** (round_a.py:126-131), so a program that floods would pass SC-fwd.
- **w7. Smaller observer gaps:**
  - `--only T8` runs without T3's POST;
  - MT1 posts meter_id 1 but reads m_in[0];
  - T2's RED reason blames the default when any s2 entry failed;
  - TP1's fabric `ports` includes every show_ports port, so a listed CPU or unlinked port would read RED.
- **w8. §7.3 omits `sudo -n mnexec -a 1 kill -TERM`** (lab_round.py:318, recover.sh:111). This is Cut 1 code, now live.
- **w9. S0 has no signal-cleanup for its throwaway processes,** and Cut 2 adds ctrltrial's bmv2 and controller.
- **w10. S0 requires the register write to fail** (s0.py:576,594). A bmv2 that learns RegisterEntry writes would block the lab run.
- **w11. A's D1 and P2 stimuli carry no Cut 2 verdict,** but they push 50 punts into the proxy's discovery path (p4_client.py:579-586).
- **w12. check_gate_anchors reports `ok(197)` against 201 mutations,** unexplained (the same in the e71dab93 round).

## The six questions
1. **Lab safety.**
   - **sudo surface:** Cut 2 adds only `sudo -n mnexec -a <host pid>` running the p4dev python with hostside.py send/sniff, `ethtool -k eth0`, and `ip -o link|addr show dev eth0` (hosts.py:69-81). That is exactly §7.3's "mnexec runs python, ethtool, ip".
   - **Other tools:** no tc runs in Cut 2. Thrift is read-only and the test asserts READ_COMMANDS. The controller runs unprivileged.
   - **LAB_STATE:**
     - sniffers are recorded by pid + start time + token right after Popen (hosts.py:107-115);
     - the controller is recorded by pid + start time + run dir (round_b.py:95-103);
     - every signal is identity-checked first;
     - the remaining gaps are w2 and MAJOR-3.
   - **Writes outside the run dir:** only the root .pyc (w1).
   - **Lab writes:** A's POSTs and B's writes cannot perturb the marker cells. They run after them and touch only metadata or objects nothing uses.
2. **False greens and confident reds.**
   - **Hold:** PL1, T1, T2, T3, M1, M2, C1, K1, P1, CS1, TTL1, K1-neg, T3-neg, SC-count, SC-reg, SC-ttl.
   - **Reds and UNATTRIBUTED as designed:** T4–T6, T8, C2, K2, MT1–MT3, R2, D1, P2, P3; T7 is NOT RUN; R3 is UNATTRIBUTED.
   - **Broken:** TP1 (false RED, MAJOR-1) and SC-fwd (false fail, MAJOR-2; false pass on a flooding program, w6).
   - **Oracle independence:** every oracle bypasses NDTwin. D1's oracle is the probe's own fields; P2 and P3 have none, and step 1 decides them today.
3. **B attributions.** Twelve items in code.
   - ternary, range, optional, priority, meter, direct_meter, clone and register each need the call plus thrift.
   - direct_counter needs the controller's read to equal thrift and be non-zero.
   - packet_out needs the call plus h4's sniffer.
   - digest and packet_in need content matching fields the probe chose, read from the controller's own report, as the design defines.
   - So all 11 hold as designed. AT1–AT12 pin them. B's fabric being external is assumed, not checked (MAJOR-3).
4. **Seal and tests.**
   - **Seal:** spawns, INET connects and 8 defaults are refused. H5 (38 failures) and H6 (40) trip the sudo stub. The gaps are w3.
   - **Mutants:** all 43 falsify what their names say, and the named test catches each one.
   - **Unpinned paths:** see w4. That is exactly where MAJOR-1, 2 and 3 live.
   - **Old-code red:** the whole-tree ImportError red is coarse, as the worker says.
5. **The 17 choices.**
   - **§9:** none touches a decision in §9.
   - **Verdict effects:**
     - choice 12 changes the Δ column (m1);
     - choice 15's fabric half is MAJOR-1;
     - choice 10 omits the alive marker (w5);
     - choice 1 adds a root-path `__pycache__` (w1).
   - **R3 does not block.** §2.3 anticipates UNATTRIBUTED, the code already encodes it twice, and VS1 was changed on the same kind of evidence. Recommend making R3 UNATTRIBUTED, citing the ctrl_trial, before the live run.
   - **AP1/AS1/IT1/VS1 do not block.** Either schedule them (VS1 is cheap) or change their tsv `cut` column in a reviewed commit.
6. **Live procedure.**
   - **Correct:** the commands and owner plumbing.
   - **Not runnable as written:**
     - the predictions are contradicted (MAJOR-1, MAJOR-2);
     - step 7 is wrong (m1);
     - step 2 cannot show A's end state (MAJOR-3);
     - steps are missing (m4).

## Audit of the worker's verdicts
| claim | class |
|---|---|
| Cells 110 OK, collect 97 OK + seal report zeros, recover 72/0, on all three interpreters | SUPPORTED |
| H1–H6 red; H5/H6 catch the new spawn paths | SUPPORTED |
| Mutation gate 201/0, control green, byte-identical | SUPPORTED |
| S0 rc 0, 54 ok, 109 s, ctrl_trial on both builds | SUPPORTED |
| anchors ok(197), tmpdirs 414/0, l1 163/0 | SUPPORTED; the 197 vs 201 gap is unexplained |
| Old-code red (ImportError; verdict.py alone) | SUPPORTED |
| "Per decision path" coverage | UNDER-EVIDENCED (see w4) |
| Pre-gate survivors fixed | UNDER-EVIDENCED (the earlier logs were deleted) |
| "None of the 17 choices changes a design verdict" | UNDER-EVIDENCED (m1, MAJOR-1, w5) |
| Priority = INT32_MAX − p; optional shows as TERNARY &&& ff; 10 of 11 confirmed; register code 12 | SUPPORTED |
| Sniffers record pid + start + token and end by themselves | UNDER-EVIDENCED (the fake records the child process, not sudo) |
| B controller runs through the adapter | UNTESTED (ctrl_trial bypasses it) |
| "Sniffers stop early once they have every marker" | CONTRADICTED (MAJOR-2) |
| §6 predictions for TP1, K1, TTL1, SC-fwd (30,30), rollups and see-red | CONTRADICTED (MAJOR-1, MAJOR-2) |
| §6 step 7: only R3 flipped | CONTRADICTED (m1) |
| §6 step 2: LAB_STATE shows the run is clean | UNDER-EVIDENCED (MAJOR-3) |
| R3 reads UNATTRIBUTED, rollup unaffected | SUPPORTED |
| No leftover processes; disk free | UNDER-EVIDENCED (no output quoted) |

## Tests I would have run
1. `ip -o link show` on a Mininet fabric.
2. A fake fabric that prints veth peers by name.
3. ICMP echoes in the fake fabric, plus `record()` unit tests.
4. A's down failing, A's claim lost, A's kill failing, with B kept out in each case.
5. One observer raising, with the rest of A still observed.
6. Δ for unobserved cells.
7. S0 with A-MUT dropped from the drop-check list.
8. The adapter's `--dry-run` on packages/B.
9. `find tools/p4_health -user root` after a run.
10. `show_ports` with `--cpu-port 510`.
11. A real `get_graph_data` host node.

## Internal inconsistencies
- SUMMARY §6 steps 5 and 7, and its predictions, against the code (above).
- 197 vs 201.
- tsv R3 says RED; the test override and S0's `want_false` say UNATTRIBUTED.
- §1.2's wording against attribution.py.
- frames.py's docstring against choice 1.
- I recomputed the rollups 9/1/3/3, 6/4/3/3 and 0/0/0/6 from the predicted verdicts. They are consistent with those verdicts, and are wrong only through MAJOR-1/2.

## Verdict
**Conditions:**
- Fix MAJOR-1, 2 and 3 and m1–m6, each with a red-then-green test.
- Make the fake fabric model the real `ip -o link` format and host ICMP.
- Rerun the gates.
- Run a judge pass on the fix diff only; a full re-review is not needed.
- No live run before that.

MERGE AFTER FIXES
