# Judge: Cut B of the P4 table-entry journal, head 166b11ac (code adcb9081), r1

**Roots:**
- W = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-journal-b
- L = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/ternary-cut-b
- H = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/ternary/REPORT-cut-b-adcb9081.handback.txt

**Method.** Read-only. I executed nothing, so every finding comes from reading code and logs.
- The branch ref is 166b11ac. I could not run git, so the working tree under W being equal to 166b11ac is assumed, not verified.
- DESIGN.md: I read only the sections H cites (§5.1–5.6, §6.1, §6.3–6.4, §7 row B, §10).
- Not read, by my remit: judge-ternary-design-*.md, SUMMARY-cut-b.md, expected_today.tsv, git history.

**Short version.**
- The core is sound. These all match H, and no surface can claim an entry survives a restart today:
  - write ordering
  - the per-switch lock
  - record() never raising
  - torn-line repair
  - the fold table
  - records_from_net
  - the snapshot sequence
- Four small things must change before merge:
  - one `journaled` that bypasses the constant
  - a NOT_FOUND branch that compares the raw `op`
  - the header wiring, which has no red
  - a `recorded` counter whose docstring a test contradicts

## BLOCKER
None.

## MAJOR
None.

## MINOR, fix before merge

**m1. A second `journaled`, outside the constant.**
- W/p4_proxy/proxy_agent/api_routes.py:829-835 is the switch_state fallback, used for a switch that main.table_entries_report does not list. It emits a literal `"journaled": False` at :831.
- Cut C's flip of W/p4_proxy/proxy_agent/rule_journal.py:325 will not reach this line. After the flip, such a switch would say `journaled: false` next to `journal.record_complete: true`.
- The effect is false-RED only, and only before startup has recorded the switch (W/p4_proxy/proxy_agent/main.py:2077).
- It still breaks the brief's "the flip happens in one place", and it contradicts H line 24 ("Every journaled is computed through it").
- No flipped-constant test covers it: TheClaimFlipsInOnePlace (W/p4_proxy/tests/test_table_entry_journal.py:1049-1094) never reaches the fallback.
- Fix: `table_journals.journaled(dpid) if table_journals is not None else False`, plus one patched-True test on a fallback switch.

**m2. The NOT_FOUND branch reads the raw op.**
- rule_journal.py:705 tests `op == "delete"` against the request's own spelling. The route passes `data.get("op", "insert")` through unchanged (api_routes.py:1045).
- The writer normalizes the op (W/p4_proxy/proxy_agent/p4_client.py:1229), so `"DELETE"` or `" Delete"` is accepted as a delete.
- When the switch answers such a delete with NOT_FOUND, nothing is recorded. That goes against DESIGN 10-4 (W/doc/audit/2026-10-04_p4-ternary-journal/DESIGN.md:797-799). Multicast does normalize its op (api_routes.py:1283).
- Fix: normalize once in the route, and add an upper-case-delete NOT_FOUND test.

**m3. The header provider's wiring has no red (finding #71's shape).**
- main.build_table_journals passes `header_for=table_journal_header` (main.py:801). TableJournals.journal_for wraps it per dpid (rule_journal.py:663-665).
- No test covers either step. Tests call table_journal_header directly (test_table_entry_journal.py:1243-1291), and every TableJournals in the tests is built without header_for.
- Either of these mutants would leave the gate green while every production header comes out all-null:
  - dropping `header_for=` at main.py:801
  - turning rule_journal.py:664 into `if False:`
- L/probe-r10-new.log:9 shows exactly that all-null header (the probe skips header_for too).
- It fails safe today, because nothing reads headers yet.
- Fix: one test (build through main.build_table_journals with `NDTWIN_TABLE_JOURNAL_DIR` set to a temp dir, write once, read(), assert boot_id == BOOT_ID and the p4info digest), plus the two mutants.

**m4. `journal.recorded` does not count what its docstring says.**
- report() documents `recorded` as "accepted API writes of this boot that reached the file" and `failures` the same way (rule_journal.py:747-749).
- But _record also counts not_found deletes (:709 → :717-724), and those answer 502. The unit test pins this: recorded == 1 after a NOT_FOUND (test_table_entry_journal.py:590).
- So `journal.recorded` stops reconciling with `table_entries.api_writes`.
- DESIGN §5.6 called this field `writes` (DESIGN.md:518).
- Fix now, while the field is new: document "records, including not_found deletes", or count not_found separately.

## MINOR, can wait (carry m5–m7, m9, m12, m13 into Cut C's acceptance)

**m5. Lock held across the gRPC write (worker point 8): agreed, and understated.**
- RPC_TIMEOUT_S is 5 s (p4_client.py:32) and the lock acquire has no timeout (rule_journal.py:698).
- So the k-th POST queued behind a hung switch holds a threadpool thread for up to k×5 s.
- That pool is AnyIO's default (40 tokens), and the flowentry endpoints share it.
- Before this cut, the same POSTs held a thread for at most 5 s each, in parallel.
- This needs a ruling (for example acquire(timeout) → 503) before the code reaches trunk. It is not a deviation from §5.3.

**m6. write_snapshot contract gaps** (rule_journal.py:543-581; no caller yet):
- (a) It neither takes nor documents `lock`, but §5.2 says the lock covers append AND snapshot (DESIGN.md:385). A record() that races a snapshot lands in the old inode and drops out of the live file.
- (b) Two header schemas. The snapshot header keeps only the caller's keys (:560-561); _header_line nulls the missing ones (:503-505).
- (c) A crash between link and replace leaves the quarantine name aliased to the live inode, so that "set-aside generation" keeps growing. This contradicts the docstring at :545.
- (d) A temp file left by a crash is never swept.
- (e) After a snapshot the live file has mkstemp's 0600 mode.
- (f) Nothing tests the default keep of 10 (:339).

**m7. fold() throws the unreadable count away** (:635-638). The "no complete with unreadable lines" rule (:41-43) then depends on Cut C remembering to call read() as well.

**m8. An unlisted deviation in the fold.**
- §5.4 says a default always nets to modify (DESIGN.md:480). The code nets a default whose last record is a delete to nothing (:411-415).
- The result is right: after a push the default is the program's own.
- The stated premise ("a switch refuses to delete a default", :387-389, and the test at :289-290) is unverified. The writer does send that DELETE (p4_client.py:1243-1257; test :1178-1179).

**m9. A lone not_found delete nets to an active delete** (:416-423; test :249-254). Cut C's replay must treat NOT_FOUND on a net delete as having reached its target state.

**m10. Install-time effects H leaves out.**
- `switch_state.rules_timed` now counts a default and a priority-0 catch-all as two (W/p4_proxy/proxy_agent/topology_manager.py:1822).
- The catch-all's /stats/flow age no longer inherits the default's stamp. That is a fix.
- The default's stamp is never read: W/p4_proxy/proxy_agent/ryu_flow_stats.py:406-407 passes no default flag, and default rows are skipped at :266-267.
- The entry_key docstring example is wrong (W/p4_proxy/proxy_agent/rule_install_times.py:147-151). A ternary catch-all needs priority ≥1, so it never collided. The real collision is on tables with no priority column, which is what the test uses (:872-883).

**m11. Tests and mutants whose names over-claim:**
- :427-434 "hard link" also passes under rename. M-J11b reddens only the crash test (L/gate-mutate_table_journal.log:175-176).
- :885-888 compares no response count.
- :1183-1186 never consults the install times.
- M-J1b says "answers 200", but its mutant would produce a 500 (W/tests/shell/mutate_table_journal.sh:163-169; api_routes.py:1109).
- M-J56's scenario cannot happen in production: an accepted API write always lands in `_api_writes` (main.py:866-871).
- M-J11 is killed because the os.replace fault hook disappears, not by a demonstrated half-written file (:375-382).
- M-B14b and M-B20b duplicate M-B14 and M-B20 in W/tests/shell/mutate_table_entry.sh (:366-381), so 2 of the 85 are repeats.

**m12. A placeholder is pinned.**
- TheClaimFlipsInOnePlace pins `replay == "implemented"` (:1083; rule_journal.py:758; api_routes.py:941).
- The file docstring says the replay cut edits only the constant (:13-15). H line 28 says replay must become a real report.
- Pin "not the Cut B string" instead.

**m13. `.run/` isolation is by convention only.**
- Every test that POSTs isolates its journal: test_table_entry_route.py:240-258, test_table_entry_journal.py:788-803 and :1097-1112.
- No `.run/` exists under W/p4_proxy now. That is an observation of the current tree, not timestamped.
- Before replay exists, add a guard: set NDTWIN_TABLE_JOURNAL_DIR in the test bootstrap, or check before/after the suite that `.run/table_entry_journal` did not change.

**m14. The gate's mutant() ignores a failed anchor assert** (mutate_table_journal.sh:129-136). A control whose anchor vanished would still print "green". Today check_gate_anchors ok(78) covers this (L/check_gate_anchors_HEAD.log:137); 78 = 91 calls minus 13 shared anchors.

**m15. Staleness and provenance.**
- api_routes.py:1286 (a multicast comment) and the T8 RED text at W/tools/p4_health/cells/table.py:379 are stale; the latter belongs to the health line.
- The REFUSE logs were deleted (H line 83). It is disclosed, but raw data should be kept.

## Checks asked for

**1. Correctness of the journal**

| Item | Verdict | Evidence |
|---|---|---|
| Order: switch, then record, then answer | SUPPORTED | write :703, record :713-714, answer after the threadpool returns (api_routes.py:1058-1060, 1106-1116); M-J1 caught |
| Lock | SUPPORTED | one per switch (:491, :698); client fetched inside it (:699); one threadpool callable; M-J2, M-J2b, M-J23 caught (gate log :52-59). Readopt does not take this lock yet; that is Cut C |
| record never raises | SUPPORTED | the line is encoded before open (:519); except clause at :540; header errors caught separately (:499-502) |
| Torn lines | SUPPORTED | newline repair (:529-533), count (:616-622). Residual: a torn header is never rewritten (:526-527); Cut C step 0 already treats that as unconfirmed (DESIGN.md:464) |
| Fold outcomes and records_from_net | SUPPORTED | :403-426 and :430-441; fold(snapshot) == net for every op (tests :304-316, :469-474). Exception: m8 |
| write_snapshot | SUPPORTED for "never no live file" | mkstemp, fsync, link, replace, dir fsync, prune (:557-580); fault test :436-453. Gaps: m6 |
| Default key | as stated | rule_install_times.py:154-155; p4_client.py:1261-1266, 1283-1305. Effects: m10 |

**2. False greens and disclosure**
- No false green exists.
  - POST: `journaled` is always False (rule_journal.py:356; api_routes.py:937) and the note is present (:942-948).
  - switch_state: main.py:861 (computed) and api_routes.py:831 (literal).
  - T8 turns GREEN only on `journaled is True` (table.py:385). Nothing in tools/ reads `journal` or `record_complete`.
- "T8 stays RED" is UNDER-EVIDENCED.
  - The cell needs `a:journaled` (table.py:991), and no observer in tools/p4_health produces it. A round today would show T8 as NOT RUN.
  - "T8 cannot go GREEN" is SUPPORTED.
- `record_complete` is exactly the three conditions: enabled ∧ ¬read_only ∧ failures == 0 (:735-736). These match DESIGN.md:517, and read_only is read at call time (main.py:800). M-J13a–c are caught.
  - Note for Cut C: it is vacuously true for a switch with no writes, and it says nothing about the file itself.
- Single flip constant: partly CONTRADICTED by m1. No module keeps a stale copy of the constant.

**3. Regressions**
- Existing writes keep the same refusals and status codes. New: per-switch serialization and an fsync on every write (m5).
- Multicast's text is unchanged: api_routes.py:905-906 matches the old tree's note (L/probe-r10-old.log:7) and :1289 still emits it.
- NOT_FOUND delete: recorded, then re-raised unchanged, answered 502 (:704-710; test :908-915). The exception is m2.
- `_p4rt_error` never raises (api_routes.py:283-304), so delete refusals made before the wire still map correctly.
- `.run/`: every POSTing test isolates (m13).

**4. Tests and the gate**
- On the old code all 103 tests fail at import (L/red-526dd41c.log:586-595), so none goes red for its own reason there, as H says.
  - That run used fe0172b6's copy of the test file (log line 1), but the outcome does not depend on which copy.
- The two edited assertions are own-reason reds: KeyError 'journal' (L/red-526dd41c.log:599-614).
- R10's old-code evidence is the probe, and its "dir empty" carries no information on the old tree (L/probe_r10.py:35-37).
- I checked all 103 test names against the gate log: each goes red under at least one mutant (SUPPORTED). Four are red only incidentally:
  - :569-575 never for "own lock"
  - :427-434 green under rename
  - :774-779 never for "asked late"
  - :469-474 only under M-J37f
- Gate totals: 85 mutants, 0 survivors (gate log :382). Names fit except those in m11.
- The 6 controls are green (:374-379). N2 is a behaviour-preserving operand swap, not a comment-only edit (mutate_table_journal.sh:800-803).
- Decision paths with no red:
  - the header wiring (m3)
  - the raw op (m2)
  - the TypeError branch of record()'s except clause: test :389-390 exists, but its "not raised" half was never seen red
  - the default keep of 10
  - wire op vs requested op: a test exists, but no direct mutant
  - the fallback literal: pinned only by W/p4_proxy/tests/test_app_package_proxy.py:383-384
- fold, write_snapshot, records_from_net and read() have no production caller. Confirmed: in proxy_agent they appear only at rule_journal.py:374, 430, 543 and 635-638.
- That should not block a merge to the hold: §7 row B puts them in this cut (DESIGN.md:652), and every surface says replay is not implemented.
- Two conditions on that:
  - It must not reach trunk without Cut C.
  - Cut C's acceptance must include a test that startup and readopt call fold and write_snapshot, with one mutant deleting each call.

**5. The 12 design points**
1. Agree. T8 also has no observer yet.
2. Agree.
3. Agree.
4. Agree, and add rules_timed (m10).
5. Agree.
6. Agree. The header's digests are also those of the file's first creation.
7. Agree, and confirmed. Not blocking.
8. Agree, and the impact is larger than stated (m5).
9. Agree. I verified it and want a structural guard (m13).
10. Agree. The edits are narrow (test_app_package_proxy.py:372-384; W/p4_proxy/tests/test_startup.py:686-690).
11. Agree. Pre-existing.
12. Agree. Cut C's step-0 quarantine must use the same `.q<ns>` naming, or prune will miss it.

Missing from the list: m4, m6(a) and m8.

## Per-verdict classification (H)

| # | H's claim | Class | Evidence or gap |
|---|---|---|---|
| 1 | "Every journaled is computed through it" (l.24) | CONTRADICTED in part | api_routes.py:831 |
| 2 | POST 200 shape and the three notes (l.25) | SUPPORTED | api_routes.py:928-948; probe-r10-new.log:5-7; tests :817-827, :953-981 |
| 3 | switch_state block; record_complete = 3 conditions (l.26) | SUPPORTED | main.py:861-862; rule_journal.py:728-758 |
| 4 | T8 stays RED (l.27) | UNDER-EVIDENCED | no `a:journaled` observer, no round run |
| 5 | The flip = the constant; pinned by tests (l.28) | SUPPORTED for the response and main's report; CONTRADICTED for the fallback (m1); "T8 GREEN" UNDER-EVIDENCED | |
| 6 | 1805 → 1908, +103, skipped=1 (l.35) | SUPPORTED | before-p4_proxy.with-build.log:2661-2663; after-p4_proxy.log:2692-2694; 103 `def test_` |
| 7 | "1908 at fe0172b6-equivalent" (l.34) | CONTRADICTED (label) | L/superseded-0050bdcd/after-p4_proxy.log:1 and :2397-2399 are at 0050bdcd |
| 8 | Gate 85/0, 6 controls, byte-identical (l.40) | SUPPORTED | gate log :374-382 |
| 9 | Other gate rows (l.41-48) | SUPPORTED | cited lines match; the heartbeat proxy half was caught (log :15-201) |
| 10 | "133/133 (Cut A)" | UNDER-EVIDENCED | no before-log; 134/134 at HEAD (:146) |
| 11 | All 103 seen red; 11 added (l.52) | SUPPORTED | gate log; 74 mutants at first (superseded-0050bdcd/try1-gate-mutate_table_journal.log:326) |
| 12 | Old-code reds (l.56-57) | SUPPORTED | red-526dd41c.log:586-614 |
| 13 | R10 probe (l.58) | SUPPORTED for the key; the dir claim is vacuous | |
| 14 | R10–R13 mutant lines (l.59-63) | SUPPORTED | every cited line matches; M-J11 is a mechanism kill |
| 15 | "Control ... comment-only" (l.50) | CONTRADICTED (label) | N2 |
| 16 | No production caller (point 7) | SUPPORTED | grep |
| 17 | Commit-message check, "git status clean" | UNDER-EVIDENCED | not logged; log headers say "0 modified tracked files" |

## Tests I would have run
1. An upper-case `DELETE` answered NOT_FOUND, expecting a not_found record (fails today).
2. Header wiring through main.build_table_journals, with the two mutants (m3).
3. switch_state's fallback with the constant patched True (m1).
4. The full suite with a before/after listing of `p4_proxy/.run/table_entry_journal/`.
5. N concurrent POSTs against a 5 s stub Write, timing an unrelated threadpool endpoint (m5).
6. A crash between link and replace followed by record(), checking the quarantine copy is unchanged; and write_snapshot racing record().
7. Mutants: drop TypeError from :540; `QUARANTINE_KEEP = 1`; `written["op"]` replaced by `op`; one lock shared by all switches.
8. rules_timed for a default plus an LPM catch-all.
9. The T8 cell fed a real Cut-B switch_state document.

## Internal inconsistencies
1. fe0172b6 is listed as a live commit (H l.13) and also called a pre-rewrite sha (l.15).
2. The no-build count is labelled fe0172b6, but its log is at 0050bdcd.
3. L/INDEX.txt:3 says no fe0172b6 log runs the changed files, but red-526dd41c.log:1 ran fe0172b6's test_table_entry_journal.py.
4. H l.24 vs api_routes.py:831.
5. All controls are called "comment-only", but N2 is not.
6. "check_test_tmpdirs.log:8" is the rc line; the count is at :6.
7. test_table_entry_journal.py:13-15 vs H l.28 (the replay field must change).
8. rule_journal.py:747 vs test :590.

**Verdict: MERGE AFTER FIXES** (to the branch's hold). Fix m1–m4, each with its test, and carry the can-wait items into Cut C as listed.
