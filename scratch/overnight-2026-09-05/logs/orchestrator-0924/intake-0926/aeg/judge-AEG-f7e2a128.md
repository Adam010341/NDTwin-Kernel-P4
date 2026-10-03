# JUDGE: AEG fix round f7e2a128

**Verdict: MERGE.** Nothing blocks.
- F1 and F2 are fixed, and both were seen red on ebe17f7c's code before they went green.
- N1, N2 and N4 are dealt with.
- Every number in the §0 table is in its log, and every gate log's first line is `f7e2a12874d2218d72b10769e1cf3967c51b5c5f`.
- Note N-1 is an older bug, not caused by this round. It should still be fixed before 08 is next run live, because a run stopped with TERM can end `PASS 08_heartbeat`.

**Scope:** read-only, and I had no git.
- I read summary §0 (the report under audit), the changed regions of the nine files, and every aeg5/aeg6 log. I also read the aeg4 logs only to check the "corrections" bullet.
- I did not read the previous judge report. One repo-wide grep happened to show lines from older audit documents; I did not use them.
- Without git I cannot diff, so I cannot prove that nothing outside F1/F2/N1/N2/N4 changed.

**Path shorthand:**
- WT = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-rulings-aeg-0927`
- LIVE = `WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1`
- `08:` = LIVE/08_heartbeat.sh, `02:` = LIVE/02_app_basic.sh, `common:` = LIVE/_common.sh, `README:` = LIVE/README.md
- `main:` = WT/p4_proxy/proxy_agent/main.py, `thf:` = WT/p4_proxy/tests/test_heartbeat_fabric.py
- `tlc:` / `mlc:` / `mhw:` = WT/tests/shell/{test_live_p1_common, mutate_live_p1_common, mutate_p4_heartbeat_w}.sh
- L = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`
- `X.aeg6` = L/X.aeg6-f7e2a128.log; `rf` = L/redfirst_aeg5.aeg5-f7e2a128.log
- `pu.sh` = L/scripts-aeg6-f7e2a128/proxy_unit.sh; `tw` = L/scripts-aeg6-f7e2a128/tripwire.log

## Answers to the seven checks

**1. F1**
- **Every exit path is concluded.** w_finish is the trap for EXIT, INT and TERM (08:2002). The first thing it does after clearing the traps is conclude any pending cycles (08:684-686). cut_cycle records which phase the cycles belong to (08:1124-1126). All of these reach that code:
  - H1's two early exits (08:2145, 08:2160);
  - the H3 window (08:2203-2207);
  - `set -e` and `set -u` deaths;
  - INT and TERM.
  - The exceptions are signals that cannot be caught, and the narrow windows in N-2.
- **It cannot conclude twice on the normal path.**
  - strict_conclude zeroes the tally (08:1146) before w_finish checks it (08:684).
  - A double conclusion would also turn the first st_h1 cell red (08:1823-1832), because the "cut short" NOTE would then be the line above PASS.
- **The NOTE is directly above the last line on PASS and FAIL.** finish prints `raw:`, then the NOTE lines, then the verdict (common:296-305).
  - The only exception is finish's REFUSED branch (common:288-292). It exits before the NOTE loop.
  - That branch needs rc 2 with no failure recorded. Nothing after the claim can produce that in practice.
- **st_h1_exit uses the real EXIT trap.**
  - It sets `trap w_finish EXIT` in its subshell, runs the real cut_cycle on the OVER fixture, then does `fail …; exit 1` (08:1860-1884).
  - It goes red without the fix:
    - L63 was caught (mutate_p4_heartbeat_w.aeg6:219).
    - Run against the base w_finish, it was red (rf:10-17). In the kept output `f1_08_hybrid.out:111`, the line above the FAIL is `raw: …`.
  - Caveat: the "failing restore" is imitated by the loop's two failure statements (08:1875). restore_cycle and the live loop itself are not run.
- **The two cited stale sentences are fixed.**
  - The summary cites ebe17f7c line numbers. Base 2089 and 2120 are now 08:2134 and 08:2165-2166, and both read correctly.
  - The label at base 1867 is now 08:1912 and is accurate.
  - Other stale text remains (N-3, N-4, N-7).

**2. F2**
- **Nothing between the decision and the new print can disagree.**
  - The only other output in that span is `_start_heartbeat_watchdog`'s own line (main:1403-1404 or main:1409-1411), and it states the same decision.
  - The printed list is `sorted(set(skipped))`. The served list is `sorted(skipped)` (main:716, recorded at main:2312).
  - `skipped` is never changed after main:2235 (its only changes are at main:2170, 2180 and 2235) and cannot hold duplicates, so the two lists are equal.
- **`foreign_note` can be set and never printed only if startup itself dies** between main:2191 and main:2236.
  - The seed, the route install and the `start()` call are each wrapped in a try.
  - `_heartbeat_reading()` (main:1406) is outside the try at main:1399-1405. If `evidence.last()` raised, startup would die, and the foreign line would be lost. Under the old order it was printed first.
  - This affects the crash path only.
- **The new test goes red on the old order.**
  - Against the real base main.py it fails with "Lists differ: ['link_watchdog', 'lldp_discovery'] != ['lldp_discovery']" (rf:18-25).
  - Mutant F2 was caught (mutate_p4_heartbeat_w.aeg6:94).
  - The test covers only the owned fabric (thf:190-196).

**3. N1**
- **heartbeat_skips_verdict fails correctly in all three cases:**
  - no heartbeat block → BAD (common:367-369);
  - watchdog ≠ `running` → BAD, naming `heartbeat.error` (common:370-373);
  - wrong list → BAD (common:374-376).
- **Evidence:**
  - four fixtures in tlc:1167-1177;
  - exactly 5 cells red against the base `_common.sh` (rf:26-52);
  - M50–M53 caught (mutate_live_p1_common.aeg6:317-329).
- **Fallback:** see N-5.
- **jqp comment: confirmed.**
  - common:350 is jqp's one-line comment.
  - The new doc comment follows at common:351-356 and the function at common:357-380.
  - `jqp()` at common:382 has no comment of its own.
  - Nothing reads it (a repo grep finds only these two lines). It is cosmetic: move line 350 to just above line 382.

**4. N2 and N4**
- **The docs are consistent in the header (08:54-58) and README:296.**
  - The run's own note (08:2134) states the 35 s FAIL but not that restore is still strict.
  - The per-cycle restore line does print "(bound 20 s)" or "over the 20 s bound" (08:1185 via 08:376-378).
  - The "hard ceiling" is imprecise (N-4).
- **E1b is now a different and meaningful mutation.**
  - It adds `… and routes_owned:` (mhw:697-701). E1 deletes the removal (mhw:691-694).
  - `routes_owned` is defined in that scope (main:2164), so the mutant cannot be "caught" by a NameError.
- **The mutant count is honest.**
  - The caught lines add up to 29+24+32+7+8+39+63 = 202 (mutate_p4_heartbeat_w.aeg6:20-233).
  - aeg4's 200 counted E1b twice (mutate_p4_heartbeat_w.aeg4-ebe17f7c.log:90-91), so it was 199 distinct.
  - 199 + the new E1b + F2 + L63 = 202.

**5. Logs**
- Every aeg6 log and rf start with the head sha on line 1, and rf:9 names base ebe17f7c.
- The driver refuses to run if HEAD moved or tracked files changed (gates_aeg6.sh:20-21, :45). It ignores untracked files; the 46 test files on disk match the 46 that ran.
- The numbers:

| Gate | Evidence |
|---|---|
| redfirst | rf:63 ALL-AS-EXPECTED, rf:65 rc=0 |
| selftest_08 | selftest_08.aeg6:139 SELF-TEST PASS, :141 rc=0 |
| proxy_unit | proxy_unit.aeg6:57 "46 file(s), 1661 test(s): 1660 passed, 1 skipped" — I summed the per-file lines :11-56 and they agree |
| mutate_p4_heartbeat_w | mutate_p4_heartbeat_w.aeg6:239 202/0, :236 106 of 106, :166 57 ndt checks with 12 controls |
| mutate_roles_binding | mutate_roles_binding.aeg6:622 179/0 |
| test_live_p1_common | test_live_p1_common.aeg6:231 191/0 |
| mutate_live_p1_common | mutate_live_p1_common.aeg6:346 54/0, 4 controls, 0 red |
| check_gate_anchors | check_gate_anchors.aeg6:138 121/121 |
| nolab_tripwire | nolab_tripwire.aeg6:22-23 — 1969 lines, 0 lab calls |

- Nothing in the gate table lacks a log. The offline dev runs are correctly labelled as not gates.
- The aeg5 selftest_08 reason text is a note added by hand after the driver's `# rc=143` (selftest_08.aeg5-f7e2a128.log:9).

**6. Regressions**
- In the files I read, every change maps to F1, F2, N1, N2 or N4.
- The foreign startup line now comes after the seed, route and heartbeat lines in p4_proxy.log. This does not affect 02: 02:146 greps the first 40 log lines with `grep -m1 'app package'`, and that matches profile.py:41's import-time line first. Nothing else parses the foreign line.
- `_common.sh` changed, but selftest_07, test_live_p1_thirteen and mutate_live_p1_thirteen, which source it, were not rerun. The change only adds code, so the risk is low.

**7. Discipline**
- Every new block carries `[Co-developed with claude code -- Adam]`:
  - 08:54, 08:184, 08:680, 08:1857;
  - main:2166, main:2186;
  - thf:184;
  - common:353;
  - 02:26, 02:63;
  - tlc:1150, mlc:1001;
  - mhw:686, 704, 1434;
  - README:305.
- There is no `pkill` or `pgrep` in any changed file; the only mentions are "never pkill" comments.

## Findings

**Blocking: none.**

**Notes**

**N-1 — a run stopped with TERM can PASS.** This predates the round. Fix it before the next live 08, as a separate item.
- w_finish takes its rc from `$?` (08:677, passed on at 08:697). finish only turns a non-zero rc into a FAIL (common:293).
- Suppose TERM is sent to the 08 shell's own pid — this project stops things by pid. Bash waits for the running child to finish, then runs the trap with that child's `$?`, which is usually 0.
- With no earlier failure, the result is `PASS 08_heartbeat`. It has a "cut short" NOTE above it only if some cycle was OVER.
- This round's header (08:51-53) promises the NOTE "stands above the FAIL". That is not guaranteed.
- Fix: give INT and TERM their own traps that force rc 130 or 143 before calling w_finish.

**N-2 — residual F1 windows (minor).**
- (a) A signal can land between 08:1118 and 08:1124-1126, which includes the `verdict budget` python call at 08:1122. The cycle's line is then already in the over-list but not counted.
  - If it is the first cycle, w_finish skips the conclusion (08:684).
  - Otherwise the count and the list disagree.
- (b) finish's REFUSED branch (common:288-292) drops the disclosures. In practice nothing after the claim reaches it.
- (c) When a restore fails, that cycle's row never reaches 30_cycles.tsv, because the printf at 08:2163 runs after restore_cycle. The NOTE text still points to `strict_20s in 30_cycles.tsv` (08:1148).

**N-3 — comment now false.** 08:674 says "netem this run added comes off FIRST", but the conclusion now runs before the revert (08:684 vs 08:687-693). Either move the conclusion to just before `finish` or fix the comment.

**N-4 — the "hard ceiling of 35 s" is approximate** (08:55-56, README:296).
- v_strict (08:449-461) has no upper bound.
- The 35 s limit only stops graph_until's polling loop (08:1100). The loop counts whole seconds from its own start (08:859), after a poll whose curl can take up to 5 s (08:842).
- So a detection seen by a poll that started before the cutoff is recorded as an OVER NOTE even if detect_s is over 35 s. The cutoff can also trigger at about 34 s.
- The cycle heading still says "down in the kernel's graph within 20 s" (08:2143).
- Suggested fix: make v_strict return BAD when `d > b + 15`.

**N-5 — the `|| echo BAD` fallback** (common:358).
- It is reachable only when python exits non-zero, for example:
  - the top-level JSON is not an object;
  - `control_plane` is non-empty but not a dict;
  - `skipped` holds values that cannot be sorted together;
  - the interpreter dies.
- From 02 these cases stop the script earlier:
  - 02's own jqp calls (02:159-170) abort under `set -e`;
  - `$PY` is checked at common:324.
- Its polarity is correct (it reports BAD). Its output is not: with `2>&1` the traceback comes before the BAD line.
  - V then starts with "Traceback", and `fail "${V#BAD }"` (02:187) records a multi-line reason.
  - The run's last line is then not the FAIL line, and the doc's "one line" (common:351-352) is false on this path.
- No test covers it. Fix: catch Exception inside the python and print one BAD line.

**N-6 — jqp comment misplaced** (common:350 vs common:382). Cosmetic.

**N-7 — test gaps and a stale comment in 02.**
- Pin 1 (tlc:1178-1179) pins only the call line. Deleting the consumer line 02:187 survives every gate, because 02 has no self-test.
- Pin 2 (tlc:1180-1181) matches only one spelling.
- M50 and M52 are caught by the message text, not by an OK/BAD flip: their fixtures carry the three-name list, so the mutants still print a BAD, just a different one.
  - No fixture covers "not_started with the two-name list" or "no block with the two-name list". Those are the cases M50 and M52 would actually let through.
- 02:184 still says "THE FABRIC-WIDE LIST IS THE THREE".

**N-8 — "E1b turns only the unbound test red" is not shown by the log.** report() (mhw:169-185) checks only that the named test went red, not that the others stayed green. By reading, it is plausible.

**N-9 — the gate driver counts failures as passed** (pu.sh:34 prints `ran - skipped` as passed). rf:57-58 shows one test FAILED and the summary line still says "1661 test(s): 1660 passed, 1 skipped -- SOME FAILED" (also kept n4_unit_base_main.out:16-17, :48). The script is outside the commit.

**N-10 — summary misstatements.**
- The tripwire log is "all `curl -s --max-time 5 file://`": only lines 1-130 use `--max-time 5`; lines 131-1969 use `--max-time 10`. All are `file://`.
- "Disk at every gate start was 2.3–4.6 GB": the free space measured under the lock went up to 4982 MB (proxy_unit.aeg6:10; also selftest_08.aeg6:10 at 4914 and mutate_p4_heartbeat_w.aeg6:10 at 4884). The low end, 2294 MB, matches mutate_roles_binding.aeg6:10.
- 08:2089, 2120 and 1867 are base line numbers. At the head they are 2134, 2165 and 1912.

**N-11 — stale docstring from ruling E.** main:1804-1805 still says `control_plane.skipped` "carries the FABRIC-wide three only". This predates the round.

## Each verdict in §0, classified

**Head and commits (46c0da1f, f7e2a128 on ebe17f7c)**
- UNDER-EVIDENCED for me, since I had no git.
- The logs and rf:9 agree on the head and the base.

**F1**
- The w_finish conclusion: SUPPORTED.
- "INT and TERM take this path": SUPPORTED by reading, but no cell sends a signal (UNTESTED as a behaviour); see N-1.
- The new cell: SUPPORTED, with the restore imitated rather than run.
- The stale sentences: SUPPORTED for the ones named.

**F2** — SUPPORTED.

**N1**
- The code, the cells (tlc:1167-1181) and M50–M53: SUPPORTED.

**N2**
- SUPPORTED for the header and README.
- "Hard ceiling": UNDER-EVIDENCED (N-4).
- The run's own note line states only half of it.

**N4**
- E1b is different: SUPPORTED.
- "Only the unbound test goes red": UNDER-EVIDENCED.
- The proxy_unit handling of skips: SUPPORTED.
- The proxy_unit counts: CONTRADICTED on the failure path (rf:58).

**Corrections**
- aeg4 was 1659 passed and 1 skipped: SUPPORTED (proxy_unit.aeg4-ebe17f7c.log:24, :35, :55).
- "200 counted E1 and E1b twice": SUPPORTED (mutate_p4_heartbeat_w.aeg4-ebe17f7c.log:90-91, :235).
- "3 commits, not 4" and the aeg3 M11 claim: not checked (no git, and I did not read the aeg3 logs).

**Gate table**
- redfirst, selftest_08, proxy_unit, mutate_p4_heartbeat_w, mutate_roles_binding, test_live_p1_common, mutate_live_p1_common, check_gate_anchors: SUPPORTED.
- tripwire, "0 lab calls, 1969 lines, all file://": SUPPORTED.
- tripwire, "all `--max-time 5`": CONTRADICTED.
- Disk range: CONTRADICTED at the high end.
- aeg5 selftest stopped at rc 143 and never ran: SUPPORTED.

## Places where the numbers disagree

- rf:57-58: one test failed, yet the summary line reports 1660 passed.
- Summary vs tw: `--max-time 5` vs mostly `--max-time 10`.
- Summary vs the aeg6 log headers: a disk range of 2.3–4.6 GB vs a measured 2.3–5.0 GB.
- 08:51-53 says the NOTE stands "above the FAIL"; README:295 says "above the last line", and a TERM'd run can end PASS.

## Tests I would have run

1. TERM sent to the bash pid in the middle of H1 with no earlier failure, expecting the last line to be FAIL. It would PASS today.
2. An H3 "cut short" cell. A mutant that hard-codes "H1" in w_finish survives today.
3. An early exit where every cycle was within 20 s, and a clean run that prints no "cut short" at all. A mutant that removes the check at 08:684 survives today.
4. heartbeat_skips_verdict on an unreadable file and on top-level JSON that is a list, expecting exactly one BAD line.
5. A pin on 02:187, or a mutant on 02's side.
6. The F2 test on the unbound fabric.
7. A detection seen after 35 s by a slow last poll.
8. proxy_unit with one failing file, checking that the passed count excludes it.
9. The full set of tests E1b turns red.
10. Reruns of selftest_07, test_live_p1_thirteen and mutate_live_p1_thirteen at f7e2a128.