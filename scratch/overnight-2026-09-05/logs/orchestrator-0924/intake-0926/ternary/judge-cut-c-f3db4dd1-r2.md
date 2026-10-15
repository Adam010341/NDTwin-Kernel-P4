# Judge: Cut C round 2 (feat/p4-ternary-replay-c, c24a7d19..f3db4dd1)

(Opus judge, read-only, 2026-10-15 ~14:3x. Saved by the orchestrator from the hand-back; content as delivered.
🔴 Describes a data-loss defect in unmerged branch code: keep off public refs until the fix is merged and public.)

MERGE AFTER FIXES

I executed nothing. Line numbers are at f3db4dd1.
- WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-replay-c
- R2 = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r2

This review describes a data-loss defect that is not fixed yet. Under the project rule, keep this review, and any record that quotes it, off the public refs (trunk on p4/lab) until the fix is merged and public.

## BLOCKER
None in the code. One process condition: only the journal mutation gate has run at f3db4dd1. R2/STOPPED says so, and R2/mutate_table_entry.log is a partial run with no rc line. Every other gate has to run after the MAJOR fix.

## MAJOR

**MAJOR-1. The snapshot turns an "unknown start" into an accepted delete, so a later insert of that key is lost at the next restart or readopt. This is a regression against round 1.**

Where:
- WT/p4_proxy/proxy_agent/rule_journal.py:479-480 sets `unknown_before` only when the net op is an insert.
- A net delete that began with a NOT_FOUND delete therefore carries no mark. It is kept as restored (:1112-1117) and written by records_from_net as `{"op":"delete","outcome":"ok"}` (:502-503, :1135-1137).
- At the next fold (:467-473), a first `delete/ok` means "there", so `[delete/ok, insert S]` becomes a modify.

Failure scenario: the round-1 review's own ternary sequence, with one restart in the middle. It applies to any key that the package's entries file does not declare.
1. Insert at prio 10 → 200. Delete at prio 20 → 502 NOT_FOUND, recorded as `delete/not_found`.
2. Restart. Key20 folds to a net delete; the replay's delete gets NOT_FOUND and counts as restored. The snapshot writes key20 as `delete/ok`.
3. Insert at prio 20 → 200, with `journaled: true`.
4. Restart. Key20 is now `[delete/ok, insert]`, which folds to a modify. The push has emptied the table, so the modify gets NOT_FOUND [inferred: the stub at WT/p4_proxy/tests/test_table_entry_replay.py:209-210 and DESIGN model bmv2 this way]. It is recorded as failed with `kept: false` and dropped from the snapshot. The entry is now gone from both the switch and the journal.

Round 1 folded a lone NOT_FOUND to nothing, so step 4 replayed an insert. The same loss follows `[nf, insert S, delete]` plus a later insert, and also happens through readopt (main.py:1972-1973).

Smallest fix:
- Change rule_journal.py:479 from `if unknown and op == "insert":` to `if unknown:`. records_from_net needs no change: it then writes `[delete/nf, delete/ok]`, which folds back to a marked delete, and with an insert appended it folds to an insert marked unknown_before.
- Flip the assertion at WT/p4_proxy/tests/test_table_entry_journal.py:310.
- Add a fold test: `fold(records_from_net(fold([nf K])) + [insert K])` is an insert marked unknown_before.
- Add a replay test for the four steps above.
- Re-anchor the retired M-J91c and keep it as a live mutant (it is not equivalent, see Q5).

## minor

1. **The fallback skips the stale_entries guard** (rule_journal.py:1094-1110).
   - Scenario: package v1 has boot entry K→port 9. K is deleted with a lost answer, the retry gets NOT_FOUND, then K→5 is inserted. v2 of the package declares K→7. On restart, the insert gets ALREADY_EXISTS and the modify fallback writes K→5 over v2.
   - The same history with an accepted delete nets to a modify, which is dropped as stale_entries.
   - This contradicts api_routes.py:1022-1024.
   - Fix: add `and not entries_changed` to the retry condition at :1104, plus one test.
2. **DESIGN now contradicts itself.**
   - DESIGN.md:340 says the replay has no MODIFY fallback.
   - :487 says the same.
   - :489-490 says failed records never enter the new file and that a NOT_FOUND delete "只是從折疊裡消掉" (only drops out of the fold).
   - All three conflict with :806-809 and with m-5.
   - §10-4 also does not say how a net delete with an unknown start is snapshotted, which is the gap behind MAJOR-1.
3. **A measurement was committed without evidence.** l1_unit_tests.sh:547-548 ("77 s … 2069 tests") and f3db4dd1's commit message rest only on the lost dev logs. Re-measure in the pending stray-check run and archive the result, or drop the numbers.
4. **Test and gate gaps.**
   - (a) test_table_entry_journal.py:316-318 has only gone red through M-J14's IndexError (R2/mutate_table_journal.log:221). No mutant targets `unknown and` at rule_journal.py:479. Add one that changes it to `if op == "insert":`.
   - (b) The overlap test at :1638-1639 relies on `sleep(0.1)`. If the second readopt registers only after the first has ended, the test still passes and M-J123 would survive [inferred]. Wait until `_pending["1"] == 2` instead.
   - (c) M-1's readopt path is not tested. All four ALostAnswer tests use a restart, and the "end-to-end" trial is lost.

## nit
- api_routes.py:1039-1041 says "the next start sets every switch's journal aside". In fact the off boot's own start does it (main.py:862-868, asserted at test_table_entry_replay.py:1221-1230).
- rule_journal.py:601 still says "because the rule IS on the switch".
- When the fallback modify fails, the failed item reports op "insert" with the modify's reason and adds nothing to `retried_as_modify` (:1100-1129).
- Stale failures (:1090-1099) have no `kept` key, although the docstring documents one at :1223-1224.
- On an off boot, a broken switch is reported as "a readopt of this switch replays its journal" (main.py:2260-2262). With the journal off, a readopt replays nothing (main.py:920-921).
- Stale labels:
  - the section header at test_table_entry_journal.py:287 ("says the entry was absent");
  - the class name ANotFoundDeleteMeansAbsentTest (test_table_entry_replay.py:605);
  - the uncommitted SUMMARY §3 M1 line ("從「不在」開始", starts from "absent").
- The M-J91b label (mutate_table_journal.sh:938) overstates the harm. With the fallback, a boot entry ends up the same; only the fold's op differs.
- expected_today.tsv:19 cites rule_journal.py:1141 for `journaled`. It is now at :1196-1199, and the tsv does ship in the PR.
- Code bound for the PR carries review IDs: "m-1 (round 2)", "M-2 (round 2)", "m-5 (round 2)" and "# Round 2 (2026-10-12)" in both test files, and "(m-1)" and "(§7-1 (b))" in mutant labels. Nothing leaks, but they mean nothing to outside readers.
- The worker's report leaves out R2/mutate_table_entry.log (a partial run: six mutants, no rc line) and R2/driver.stdout ("driver rc=143"). The resume steps do not say to discard the partial log.

## 1. Round-1 items

| Item | Status | Where |
|---|---|---|
| M-1 | FIXED BUT WRONG | The asked scenario is fixed: tests at journal.py:304-318 and 340-353, replay.py:1134-1215; mutants M-J91e and M-J91f (one per half). The snapshot half regresses (MAJOR-1). |
| M-2 | FIXED | api_routes.py:926-940, 973, 1027 ("always" dropped), 1035 ("write IS"). Two nits above. |
| m-1 | FIXED | rule_journal.py:742-778; journal.py:468; replay.py:1319; M-J117 |
| m-2 / §2-1 | FIXED | rule_journal.py:1027-1033, 1153; replay.py:1268; M-J118, M-J119 |
| m-3 | FIXED | main.py:981-985; test_app_package_proxy.py:417-420 |
| m-4 | NOT FIXED (outside code) | tsv:19 still says "an audit-raw log outside the repo", and the SUMMARY says the evidence is still not archived |
| m-5 | FIXED | main.py:905-910, 925; rule_journal.py:1118-1137; replay.py:1292-1317 |
| m-6 | FIXED | l1_unit_tests.sh:541-563 |
| m-7 | PARTLY | Only an uncommitted SUMMARY edit (diff line 70) |
| §2-3 | FIXED | p4_client.py:686, 696-697; replay.py:1261; M-J116 |
| §2-4 | FIXED | rule_journal.py:345-346 |
| §7-1 (b) | FIXED | main.py:862-868 |
| §7-2 | FIXED | main.py:2263-2268 |
| nit: REPLAYED_WHEN / boot_identity | FIXED | rule_journal.py:334-336; boot_identity.py:35-41 |
| nit: 503 docstring | FIXED | api_routes.py:1073-1080 |
| nit: `_pending` counter | FIXED | rule_journal.py:879-882, 956-1000 |
| nit: M-J30c comment | FIXED | mutate_table_journal.sh:14-17 |
| nit: stray-check message | FIXED | check_no_stray_table_journal.sh:60, 83-97 |

## 2. The amended M1, walked through fold → replay → snapshot → next fold

- **`[nf]`**: folds to a net delete with no mark. The replay deletes the boot entry, or gets NOT_FOUND and counts it restored. The snapshot writes `delete/ok`. On its own the next fold is the same, but with an insert appended it becomes a modify (MAJOR-1).
- **`[nf, insert S]` on a boot entry**: folds to insert S marked unknown_before. The replay gets ALREADY_EXISTS and modifies to S, adding the key to `retried_as_modify`. The snapshot is `[delete/nf S, insert/ok S]`, and the next fold is identical. Tested at replay.py:1162.
- **`[nf, insert S]` on a non-boot key**: the insert succeeds. The snapshot uses the same two-record form and folds the same.
- **`[nf, insert S, delete]`**: folds to a net delete with no mark (round 1 folded it to nothing). It is laundered exactly like `[nf]`.
- **`[insert, delete/nf]`**: folds to nothing. Not in the snapshot. Unchanged from round 1.
- **`[nf, insert S]` where the modify fallback fails**:
  - With a per-update refusal, the item is failed with `kept: false` and is dropped together with its unknown start. The boot entry stays as the package declares it, and S is lost (reported).
  - With DEADLINE_EXCEEDED or UNAVAILABLE, the item is kept and the snapshot is `[nf, insert S]`. The next boot retries.

Your three questions:
- **Can the modify retry happen for any other key?** Only for keys whose first record in the live file is a NOT_FOUND delete. `unknown_before` is built by the fold (:478-480) and never read from disk, and ordinary inserts are excluded (M-J91g). Two deviations: an unknown-start key whose NOT_FOUND was laundered cannot get the retry (MAJOR-1), and the retry does reach entries of a changed package entries file (minor-1).
- **Can the two-record form fold differently from the original history?** For inserts, no: key, op, spec and mark all match, also after later appends. For deletes, yes: the one-record `delete/ok` folds differently as soon as anything is appended.
- **New resurrection or loss?** Loss: MAJOR-1. An override of a changed package entry: minor-1. I found no new way for a deleted entry to come back.

## 3. §7-1 (b) as implemented

What is set aside on an off boot: every switch in `clients`, including broken ones and ones with no json_path. External fabrics are not touched (main.py:2184), and neither is any switch missing from `clients`.
- The COOKIE_ONLY read and the file read still happen.
- The verdicts are then overridden to unconfirmed with the reason "the table-entry journal is off".
- With no switch confirmed, a new G is minted.
- `settle` then runs `write_snapshot(header_now, [])` for each switch: the live file is hard-linked to `.q<ns>`, and the new live file is a header naming this boot, G_off and today's digests.

On the off boot:
- Nothing is replayed (main.py:920-921).
- The report shows fresh_fabric true, cookie "journal is off", skipped_reason "journal is off" and `journaled` false. Broken switches get the wrong text instead (nit).

On the next on boot:
- A switch that holds G_off is confirmed against a file that is empty, so nothing is replayed and the report says "confirmed" with 0 attempted. The set-aside of the pre-off journal is visible only in the off boot's in-memory report and in the `.q` file.
- A switch that was not pushed during the off boot still holds G_on, which does not match the header, so its file is set aside again.
- If the off boot's own set-aside failed with an OSError, the switch now holds G_off, so the old file stays unconfirmed [inferred].

Nothing is replayed wrongly.

## 4. Concurrency

- **Counter:** `_pending` is incremented before the switch lock is waited for (:980-981). The `dropped` latch guarantees exactly one decrement (:982-992), done before the lock is released (:995-998). With overlapping readopts the count stays above zero, and a POST already waiting for the lock is refused at its second check (:935).
- **Deadlock:** none. The lock order is always switch lock first, registry lock second (drop, settle :1031, _snapshot :1161). Nothing takes the switch lock while holding the registry lock.
- **Records:** none lost or doubled. The retry calls `apply` twice under the caller's lock and appends nothing.
- **Startup:** runs before uvicorn serves, under each switch's lock.

## 5. Mutants

All anchors are unique. Each new mutant is caught by its named test, and for the reason its label states.
- M-J91e: log :967-970
- M-J91f: :971-972 (S is not on the switch)
- M-J91g: :973-974
- M-J91h: :975-977
- M-J91i: :978-979
- M-J91j: :980-981
- M-J114: :1552-1554 (fails first at the off boot's fresh_fabric check)
- M-J115: :1555-1556
- M-J116: :1557-1558
- M-J117: :1559-1561 (ERROR: UnicodeDecodeError)
- M-J118: :1562-1563 (failures is 0)
- M-J119: :1564-1565 (ERROR: TypeError on None)
- M-J120: :1566-1567
- M-J121: :1568-1570
- M-J122: :1571-1572
- M-J123: :1573-1574 (the timing caveat in minor-4b)
- M-J124: :1575-1577
- M-J125: :1578-1581

The re-anchored mutants (M-J37a, M-J38, M-J48, M-J91, M-J91b, M-J91d, M-J15, M-J99, M-J100, M-J18e) are all caught, and the N1–N8 controls stay green. The count checks out: 158 + 18 − 1 = 175, matching log :1634.

**M-J91c is not equivalent.** The real snapshot of `[nf K]` plus a later insert folds to a modify. The retired mutant's `[delete/nf K]` plus the same insert folds to an insert marked unknown_before. The mutant's behaviour is the correct one (MAJOR-1).

## 6. The worker's claims

| Claim | Verdict | Evidence |
|---|---|---|
| 175/0 at f3db4dd1 | SUPPORTED | R2/mutate_table_journal.log:1-2 (commit, tracked-dirty=0), :1633-1635; driver.log:7. The dev-run 175/0 is UNEVIDENCED but superseded. |
| `check_gate_anchors` 137/137 | UNEVIDENCED | — |
| 77 s and 2069 tests | UNEVIDENCED | "50 files" matches the 50 `test_*.py` files at f3db4dd1. |
| seen_red 201/201 | UNEVIDENCED | The denominator is consistent: 146 + 55 `def test_`, which is 140 + 43 + 6 + 12. All 18 new tests are red somewhere in R2's log, one only through an IndexError. |
| 35 checks per binary | UNEVIDENCED | — |
| One unit test and one startup test for m-1; one test each for m-5 | SUPPORTED | — |
| No route added or removed; `FastAPI(...)` line unchanged | SUPPORTED | The patch has no @router, FastAPI or include_router lines. main.py hunks start at :859; `app = FastAPI(` is at :42. |
| M-J91c is equivalent | CONTRADICTED | See Q5. |
| Every other mutant re-anchored | SUPPORTED [inferred] | A bad anchor leaves an unmutated copy (mutant(), .sh:134-141), which would show as SURVIVED; there are none. |
| Driver waited about 10 minutes | SUPPORTED | driver.log, 17:02:38 to 17:13:38. |
| `git diff --stat fd208fbd HEAD` over the health paths is empty | Partly | SUPPORTED for c24a7d19..f3db4dd1; UNEVIDENCED for fd208fbd..c24a7d19. |

## 7. Public safety

- No credentials, tokens or /home paths in the added lines. The one "token" hit is the existing "table_generation token" docstring.
- Both commit messages have no trailers and no review, judge, ticket or finding IDs.
- The review IDs in code comments are a nit (above).
- The uncommitted SUMMARY m-7 paragraph describes a test hazard that another ticket tracks and that is not fixed. It is not a security issue, but decide before pushing trunk.

## 8. Merge readiness for the health check

- **Changed this round, and imported through api_routes:** api_routes.py, rule_journal.py, p4_client.py (a default argument), and boot_identity.py (docstring only) [inferred: api_routes imports it].
- **Unchanged this round:** topology_manager.py, route_binding.py, match_shape.py, grpc_ports.py, bmv2_binary_override.
- **main.py:** only its line 42 is parsed (by `ast`), so the constructor kwargs and `main_py_line` are unchanged.
- **S0 / openapi_probe:**
  - The probe prints status, openapi_url, kwargs and the paths with their methods (openapi_probe.py:71-74).
  - S0 checks the status, openapi_url and the path count (s0.py:749-758).
  - None of this changes. The new POST docstring changes the OpenAPI description, but the probe does not print descriptions.
- **T8** (cells/table.py:391-404) reads only `journaled`, and this round does not change how that is computed (rule_journal.py:1186-1199).

## Tests I would add or run
- The MAJOR-1 fold test and the restart sequence (the round-1 ternary sequence with a restart in the middle), plus the same through readopt.
- An unknown-start insert when the entries file has changed.
- The modify fallback failing with a per-update refusal, and with a deadline (check the report shape).
- An off boot with a broken switch, and an off boot whose set-aside raises OSError.
- A deterministic version of the overlap test.
- A fold-side mutant for the insert-only mark.
- A readopt variant of the lost-answer boot-entry scenario.

## Internal inconsistencies
- The SUMMARY's own definition of "seen red" makes 201/201 an "at least once" count, not "for its own reason".
- The report's list of R2 files leaves out the partial mutate_table_entry.log and driver.stdout.
- SUMMARY §3 still says M1 means "starts absent", while the code now says "unknown".
