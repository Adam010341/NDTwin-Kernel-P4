# Judge: Cut C round 3, scoped (feat/p4-ternary-replay-c, f3db4dd1..7f69609b)

(Opus judge, read-only, 2026-10-15 ~16:2x. Saved by the orchestrator from the hand-back; content as delivered.
🔴 Discusses the MAJOR-1 data-loss defect (fixed only on this unmerged branch) and an older loss shape (Q2): keep off public refs until fixed and public.)

MERGE AFTER FIXES

I executed nothing and read the files only. Line numbers are at 7f69609b.
- WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-replay-c
- E = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r3

This review discusses the MAJOR-1 data-loss defect, which is fixed only on this unmerged branch. Keep it off public refs until the fix is merged and public.

## BLOCKER
None in the code.

Round 2's process condition is still open.
- **What ran at 7f69609b:**
  - mutate_table_journal.sh, 178/0 (E/mutate_table_journal.log:1787)
  - check_gate_anchors, 137/137 (E/gate_anchors.log:150)
  - the two journal test files, 207 OK (E/two_test_files_whole.log:1612-1614)
  - the stray check, 2075 tests OK (E/stray_check_timing_at_final_head.log:13)
- **What did not run:**
  - Twelve other mutate_*.sh gates reference main.py, api_routes.py or rule_journal.py, all three changed here. Among them are mutate_table_entry.sh (R2's run was partial), _owner, rule_journal_is_wired, app_package, roles_binding, telemetry_by_name, priority_refusal and rule_install_time. None has a log at this head.
  - tests/python/test_p4_health_*.py has not run either, although expected_today.tsv changed.
- **Why it matters:** the anchors exist (137/137), but whether those mutants are still killed is unknown.
- **Fix:** run them at 7f69609b and archive the logs.
- **Risk:** low [inferred]. This round's edits to main.py and api_routes.py are a comment, a docstring and one conditional string.

## MAJOR
None.

## minor
1. **DESIGN.md:490-492 mis-scopes what step 6 keeps.**
   - "例外二" keeps only an unknown-start net delete answered NOT_FOUND, and frames it as an exception to "failures do not enter the new file".
   - The code keeps every net delete answered NOT_FOUND and counts it as succeeded (rule_journal.py:1133-1138, :1153).
   - test_table_entry_replay.py:1090-1107 asserts this for an accepted, unmarked delete.
   - Scenario: a reader of DESIGN expects `[delete/ok K]` answered NOT_FOUND at replay to leave the journal, so that the next boot does not delete K again. The code keeps it, and the next boot deletes K again. The two disagree on what the next boot replays. There is no runtime effect.
   - Fix: state it for every net delete ("counted in succeeded and kept; an unknown-start one is written as two records, §10-4"), outside the list of failure exceptions.

## nit
1. **Untouched statements this round made false:**
   - rule_journal.py:1239-1240: `retried_as_modify` "went back as a modify". Since :1130-1131 the list also holds keys whose modify failed, and replay.py:1285-1287 asserts such a key is also in `failed`.
   - rule_journal.py:1247-1248: `stale_entries` is described as "net modifies/deletes". It now also counts unknown-start inserts (:1118-1126).
   - api_routes.py:1030-1032: "the replay's insert falls back to a modify when the package already put one there" is unconditional, but there is no fallback when the entries file changed. This text is in the OpenAPI description.
   - rule_journal.py:500-502: "`records` count is of course 1 each". A marked item folds back with 2, and deletes are now marked too. `records` is never read.
   - Fix: one clause each.
2. **The fallback guard at rule_journal.py:1115-1117 no longer implies an insert.**
   - Marked deletes now reach `is_already_exists(exc)`.
   - If that ever returned True for a delete, the replay would send a MODIFY with the delete's spec and list the key in `retried_as_modify`.
   - This is unreachable [inferred]: `_already_exists` (main.py:898-902) reads only the per-update code, `_p4rt_error` never raises (api_routes.py:284-305), and a switch does not answer a DELETE with ALREADY_EXISTS.
   - Fix: add `item["op"] == "insert" and`.
3. **Round 2's "failed fallback" nit is half done.** The key is now named in `retried_as_modify`, but the failed item still says op "insert" (:1100) with the modify's reason (:1148-1150).
4. **M-J91k (mutate_table_journal.sh:950-956) is a compound mutant at this head.**
   - Changing `if unknown:` to `if op == "insert":` both marks ordinary inserts and unmarks unknown-start deletes. Log :1071 shows test_a_lone_not_found_delete_is_a_net_delete red too.
   - The label names only the first fault. The single-fault form is `if True:`.
5. **The gate does not cover this round's report-shape fixes.**
   - No mutant reverts the append-before-modify order (:1130-1131).
   - No mutant flips the stale `kept` to True (:1105, :1109, :1125).
   - No mutant forces the `if journals.enabled` branch at main.py:2264.
   - Each of these was seen red once, against the f3db4dd1 code. The two `kept` assertions went red only as `KeyError: 'kept'`, so the value False was never set against True.
6. **minor-4(c) is only partly covered.**
   - The new readopt test (replay.py:640-652) has no boot entry, so the ALREADY_EXISTS → modify path is still exercised only through restarts.
   - No bmv2 trial of the restart-in-the-middle sequence exists.
7. **DESIGN.md:810** (§10-4, the insert half) still states the retry unconditionally. The entries-changed exception appears only at :340 and :487.
8. **The M-J110 anchor (sh:1228-1232) is keyed on a comment**, although `        elif i in broken:` is unique (main.py:2260). Comment edits forced both of this round's re-anchors.
9. **Leftover IDs in touched files, not added by this round:**
   - "finding #71" at test_table_entry_journal.py:1876
   - "finding #71" in the label at sh:566
   - "round 2's log" at sh:116

   Whether these come from this branch is unverified.

## 1. Round-2 findings at 7f69609b
| Finding | Status | Where |
|---|---|---|
| Process (all gates after the MAJOR fix) | NOT FIXED | see BLOCKER |
| MAJOR-1 | FIXED | rule_journal.py:489-490; docstrings :436-441, :502-505; tests journal.py:304-312, :322-330 and replay.py:623-638, :640-652 (helper :654-663); M-J91c at sh:942-948, log :1065; DESIGN.md:809 |
| minor-1 | FIXED, matches the ruling | rule_journal.py:1118-1126, :386-387; replay.py:1247-1269; M-J126 at sh:1503-1509, log :1731 |
| minor-2 | FIXED, with a new mis-scope (minor 1, nit 7) | DESIGN.md:340, :487, :489-492, :809 |
| minor-3 | FIXED (re-measured) | l1_unit_tests.sh:547-548; E/stray_check_timing.log:1, 12-13, 19 (e53ebb40). "14-core" is nproc 14. The log sits in E, not audit-raw (same open item as m-4). |
| minor-4(a) | FIXED (see nit 4) | sh:950-956; log :1070 |
| minor-4(b) | FIXED | journal.py:1651-1660 |
| minor-4(c) | PARTLY | nit 6 |
| nit: api_routes "next start" | FIXED | api_routes.py:1039-1042 |
| nit: "rule IS on the switch" | FIXED | rule_journal.py:612 |
| nit: failed fallback | PARTLY | nit 3 |
| nit: stale failures lack `kept` | FIXED | :1105, :1109, :1125; replay.py:831-832, :847, :1267 |
| nit: off-boot broken switch | FIXED | main.py:2260-2266; replay.py:1327-1335 |
| nit: stale labels | FIXED | journal.py:287; replay.py:601, :605; SUMMARY line 65 (uncommitted) |
| nit: M-J91b label | FIXED | sh:938 |
| nit: tsv:19 | FIXED | now :1220, verified to be the `journaled` return |
| nit: review IDs in code | FIXED for every ID listed | nit 9 |
| nit: R2 partial logs / resume steps | NOT ADDRESSED | moot once the gates run |

## 2. MAJOR-1 in depth
Notation: nf = delete/not_found; M = the `unknown_before` mark.

| History | Fold | Replay | Snapshot | Next fold | With a later insert appended, folded again |
|---|---|---|---|---|---|
| `[nf]` | delete, M (:477-490) | delete returns ok or NOT_FOUND; restored either way (:1133-1138) | `[nf, delete/ok]` (:510-514) | delete, M | insert S, M on both sides |
| `[nf, insert S]` | insert S, M | insert; on ALREADY_EXISTS, a modify, or stale if entries changed | `[nf, insert/ok S]` | same | a duplicate insert is refused and not recorded; after a delete, insert T, M on both sides |
| `[nf, insert S, delete D]` | delete D, M (round 2: unmarked) | as `[nf]` | `[nf D, delete/ok D]` | same | insert T, M on both sides |
| `[nf, delete/ok]` | delete, M | as `[nf]` | `[nf, delete/ok]` | same | insert T, M on both sides |
| `[insert, delete/nf]` | nothing (only the first record marks) | not replayed | absent | absent | plain insert T on both sides |

- **Is the snapshot's fold identical to the original's?** Yes, in key, op, spec and mark, for all five, including after the appended insert.
  - For any history that leaves an item, the snapshot's first record has the same class as the original's: nf, or the item's own op, which is an insert exactly when the history began with an insert. The fold reads op and spec from the last record.
  - Only a history that folds to nothing, followed by an appended accepted delete or modify, differs. That predates this round, and the snapshot side is the one that matches the switch [inferred].
- **Does a marked delete behave differently at replay?** Not observably.
  - The stale checks are the same (:1101-1110), NOT_FOUND counts as restored, and `failed` and `kept` are the same.
  - `restored` and `failed[].entry` do not carry the mark (:1100, :1154-1155).
  - There are only two code-path differences. `_already_exists` is now evaluated for a marked delete, which is harmless (nit 2). The snapshot writes two records, which is the point of the fix.
- **New resurrection or loss?** None found.
  - The mark only turns a later insert's fold from a modify into an insert.
  - A marked delete removes the boot entry again, as before.
- **Out of scope, predates this round [inferred].** The same loss shape remains when the first record is an accepted delete of an entry the replay cannot restore:
  1. An insert of K lands but its answer is lost, so nothing is recorded.
  2. `delete/ok K` is recorded.
  3. An insert of S at K is recorded, and its 200 says journaled.
  4. On restart, `[delete/ok, insert S]` folds to a modify, and the emptied switch answers NOT_FOUND. S is lost.

  Worth a ticket. A possible direction is to snapshot any net delete that met NOT_FOUND at replay as marked.

## 3. minor-1 against the ruling
The implementation matches the ruling exactly.
- :1118-1126 adds 1 to `stale_entries` and uses `_STALE_ENTRIES`, whose text equals the old literal.
- It sets `"kept": False` and `continue`s before :1130, so no modify is sent.
- The failed entry's op is "insert", which is inherent. The refused insert did reach the switch: replay.py:1260 asserts `["insert", "insert"]`.
- **kept_unknown:** no interaction. The `continue` precedes the outer handler, and ALREADY_EXISTS is a per-update answer anyway.
- **retried_as_modify:** not appended (replay.py:1263).
- **Snapshot set:** the item is in neither `restored` nor `kept_unknown`, so it is excluded (:1156-1158; replay.py:1269 asserts an empty live file).

## 4. Tests and mutants
Red for its own reason, from E/red_new_tests_on_f3db4dd1.log (commit f3db4dd1, tracked-dirty=2):

| Test line | Log line | Message |
|---|---|---|
| journal.py:312 | :1635 | `AssertionError: None is not True` |
| journal.py:329 | :1646 | `[('modify', None, {'port': 4})] != [('insert', True, {'port': 4})]` |
| replay.py:656, via :638 and :652 | :1715, :1703 | `0 != 1 : the entry inserted at 20` |
| replay.py:1260 | :1682 | `['insert', 'insert', 'modify'] != ['insert', 'insert']` |
| replay.py:1285 | :1671 | `0 != 1 : the retry was made, and failed` |
| replay.py:1334 | :1662 | `'journal is off' not found in 'the pipeline push failed; a readopt of this switch replays its journal'` |
| replay.py:831, :847 | :1617, :1626 | `KeyError: 'kept'` (shows the key was absent; the value was never tested) |
| journal.py:1665 under M-J123 | E/red_minor4b_under_MJ123.log:16 | `False is not true : the second readopt is still under way` |
| journal.py:320 (M-J91k's killer) | gate :1070 | own reason [inferred]: net has one item, so the assertNotIn fails |

**Caveat on the red run.** It used a draft of the tests. The traceback lines (journal.py:328; replay.py:637/650/654/829/845/1257/1281/1330) are 1-4 below the committed lines. The offsets match exactly the `[Co-developed…]` lines later added at journal.py:323 and replay.py:624/642/1248/1272, so the differences are comment-only [inferred]. Against the committed files, the gate reddens these tests again:
- MAJOR-1: :1065-1069
- minor-1: :1731-1732
- the failed fallback: :1046, :1058, :1717
- the overlap test: :1722-1723

**Mutants**
- Anchors: M-J91c and M-J91k sit on rule_journal.py:489-490, and M-J126 on :1118-1119. Uniqueness is asserted at sh:138, and an anchor that failed to apply would show as SURVIVED.
- All three are caught at commit 7f69609b with tracked-dirty=0 (log :1-2): M-J91c at :1065, M-J91k at :1070, M-J126 at :1731.
- 178 = 175 + 3 holds: the log has 178 "caught" lines, the script has 178 `report '` calls, the 8 green controls are separate, and log :1787 confirms 178.
- Re-anchored old mutants:
  - M-J110 (sh:1228-1234) is caught at :1569-1571 by its unchanged named test.
  - M-J114 (sh:1414-1420) is caught at :1700-1702. The worker does not mention this re-anchor.
  - Both are caught for their own reason [inferred]; the gate prints only test names.
- **Bounded wait:** deterministic.
  - It polls under the same `_registry_lock` that the increment uses (rule_journal.py:991-992), so seeing `== 2` proves the second readopt registered before the first released the lock.
  - M-J123 (sh:1480-1485) changes only the decrement, so the wait still exits. The first readopt's drop then pops the key, and :1665 fails every time.
  - A timeout can only give a false red, never a false green.

## 5. The worker's claims
**SUPPORTED**
- The commits, with no trailers or IDs in their messages.
- `if unknown:` at :489.
- The test locations and the class rename.
- The red log: rc=1, 207 run, 7 failures, 2 errors, and every quoted failure (subject to the draft caveat above).
- Green after the fix (two_test_files_whole.log:1612-1614, :1669).
- M-J91c, M-J91k and M-J126 at the cited log lines.
- The minor-1 code, including the `_STALE_ENTRIES` text being identical.
- The DESIGN edit locations.
- The timings: 1:31.50 at e53ebb40, 1:19.92 at the final head, 2075 tests, 50 files, nproc 14, load about 2.2.
- The l1 comment change is two lines.
- The bounded wait, and M-J123 red.
- The nit fixes at the cited lines.
- tsv 1141 → 1220.
- The gate: 178/0, rc=0, tracked-dirty=0.
- Anchors 137/137.
- The venv interpreter (mutate log :7).
- The throwaway clones are gone: no files under scratchpad/c-replay.
- M-J91k is red for its own reason (labelled [read] by the worker; I agree).

**UNEVIDENCED**
- The reset --soft history.
- "e53ebb40 differs from the final head only in the l1 comment."
- "The anchor check first showed 136/137."
- The other gate's driver.log.
- "Only the §3 M1 line of SUMMARY changed this round."
- Which edit the manual M-J123 run applied: the log shows only tracked-dirty=1.
- "No sudo, lab, build or push."

**CONTRADICTED**
- "The E/at_03d8dd78 anchors were 136/137." E/at_03d8dd78/gate_anchors.log:150 says 137/137, at commit e53ebb40 (:1).
- "minor-4(c) is covered by (d)." Test (d) has no boot entry and never reaches the fallback.
- "Started at 15:13:34." Trivial: wait.log:8 has the empty probe at 15:13:34 and wait.log:9 the start at 15:13:39.

## 6. Public safety
- The added lines carry no credentials, tokens or /home paths.
- Every review ID round 2 listed has been removed, and no added line carries a new one. The leftovers are in nit 9.
- DESIGN's self-references (§5.4, §10-4) are inside DESIGN.md, which the PR excludes.
- Branch-wide and older than this round: code cites "DESIGN 5.4", "ruling Q1 (a)" and "R13-R26", but DESIGN.md (doc/audit/**/*.md) will not be in the PR.
- Both commit messages read like an ordinary engineer's: no trailers, no Co-developed mark, no IDs. The body of 03d8dd78 describes the defect, but the same commit fixes it.

## 7. Health check
Nothing this round changes what S0 or openapi_probe observes.
- **openapi_probe:**
  - It parses `app = FastAPI(` at main.py:42, before both main.py hunks (:860 and :2258).
  - It imports api_routes. The only module-level addition there is the `_STALE_ENTRIES` string constant. p4_client and boot_identity are untouched.
  - No route was added or removed. The api_routes hunk only changes the POST description, which the probe does not print (openapi_probe.py:71-74).
- **S0** checks the status, openapi_url and path count (s0.py:756-758).
- **T8** (cells/table.py:390-404) reads `journaled`, computed at rule_journal.py:1207-1220. None of its inputs changed, and the new stale branch does not add to `_failures`.
- **The tsv edit** is in the `basis` column. expected.py:56 reads only `expected`, and test_p4_health_cells.py:1215 only requires basis to be non-empty. Nothing under tools/ reads the changed report strings or fields.

## Tests I would have run
- The remaining gates at 7f69609b (see BLOCKER), including tests/python/test_p4_health_cells.py and test_p4_health_collect.py.
- A stock and fast bmv2 trial of: insert p10, delete p20 (NOT_FOUND), restart, insert p20, restart.
- The lost-answer boot-entry case through readopt.
- The boot-entry variant of the MAJOR-1 sequence.
- Fold tests for `[nf, insert S, delete]` and `[nf, delete/ok]`, each snapshotted with an insert appended.
- A marked delete whose replay times out: the live file should be `[nf, delete/ok]`.
- An unknown-start insert under a changed entries file whose new package does not declare K.
- The mutants listed in nit 5.
- A replay test for the out-of-scope loss in Q2.

## Internal inconsistencies
- 136/137 in the report against 137/137 in the archived log. The directory is named at_03d8dd78 but holds logs at e53ebb40.
- The red evidence ran pre-final test files, which the report presents as the committed ones.
- The report says only M-J110 was re-anchored; the patch also re-anchors M-J114.
- The l1 comment's 1:31 was measured at e53ebb40 under load; the final head took 1:20. The report discloses this.
