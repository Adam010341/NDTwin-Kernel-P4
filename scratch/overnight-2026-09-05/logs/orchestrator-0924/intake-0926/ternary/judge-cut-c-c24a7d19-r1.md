MERGE AFTER FIXES

Scope and limits: I worked read-only and executed nothing, so none of the gates or the trial were re-run. Everything below is judged from the code at c24a7d19 (its code is identical to fd208fbd; c24a7d19 only adds SUMMARY-cut-c.md) and from the logs in logs/gates-0910/p4-ternary-replay-c/. My auditor role forbids reading other review reports, so I did not open judge-cut-b-c7798953-r3.md. I checked each Cut B item the delivery says it closed against the code, using SUMMARY-cut-c.md's own description of the item. In DESIGN.md I read only the sections the summary cites (§5, §6, §8 Q1/Q4/Q5, §10).

## BLOCKER
None.

## MAJOR

**M-1. The M1 ruling brings back a package boot entry whose delete was answered NOT_FOUND.**
- Code: rule_journal.py:459 `before = f.get("op") != "insert" and not _was_absent(f)`.
- Pinned by test_table_entry_journal.py:303-306: `self.assertEqual(fold_records([rec("delete", "A", outcome="not_found")]), [])`.
- This contradicts api_routes.py:1022-1024: "A delete the switch answered NOT_FOUND is recorded too (a delete whose answer was lost may have landed, and a retry meets NOT_FOUND); it only ever makes its entry absent." That is DESIGN §10-4's purpose.
- Failure scenario:
  1. A package boot entry B sits on a writable foreign table.
  2. POST delete B lands on the switch, but the answer is lost (DEADLINE_EXCEEDED, a 502, nothing recorded).
  3. The retry gets NOT_FOUND, which is recorded as `delete/not_found`.
  4. On restart or readopt, apply_package_entries re-installs B (main.py:2219, :1941).
  5. The fold of B is now "nothing", so B stays on the switch. B does not appear anywhere in the replay report (not in attempted, failed or restored).
- Under the Cut B fold, that history folded to a net delete, which removed B again. A net delete that meets NOT_FOUND already counts as done (rule_journal.py:1061-1066), so the non-boot case was harmless.
- A second, visible variant: `[delete/not_found, insert]` on a boot entry is replayed as an insert. It meets ALREADY_EXISTS, is reported as failed, and is dropped from the live journal, so the user's spec is lost.
- The implementation does exactly what M1 says (only the first record counts; an accepted first delete still starts present). The ruling itself has the hole.
- Smallest fix (this amends M1): compute `after` first, then `before = f.get("op") != "insert" and not (_was_absent(f) and after)`.
  - `[not_found]` alone becomes a tolerant net delete again.
  - `[not_found, insert]` stays an insert, so the review's p10/p20 sequence is unchanged.
  - Flip the test at :303-306 and key C at :330-335.
  - Add a replay test: the stub applies the DELETE then raises DEADLINE_EXCEEDED; the retry gets NOT_FOUND; after a restart, B must be absent.
  - Add a mutant that restores today's line.

**M-2. The note for a failed journal write (Q4 (a)) is now wrong for delete and modify.**
- api_routes.py:932-936: "the entry is on the switch but the journal write failed: it is lost when the proxy restarts … a later replay of this entry, or of a later write to it, may fail".
- The docstring also says, at :1021-1022, "A confirmed write is always in the journal." and, at :1027, "the rule IS on the switch".
- Failure scenario:
  1. The disk is full; POST delete E, where E was journaled earlier as an insert.
  2. The answer is a 200 carrying this note.
  3. The disk is freed and the proxy restarts. Step 0 confirms the cookie, and E folds to an insert.
  4. E is back. The report says "complete", `journaled` is true, and nothing flags it.
- For a modify, the old spec comes back. DESIGN §5.3 names exactly this outcome ("delete 掉的規則會復活", deleted rules come back to life), and §10-5 requires the cost to be stated in the note.
- The same mismatch hits TABLE_ENTRY_NOT_JOURNALED (api_routes.py:968, "lost when the proxy restarts") on a journal-off boot under §7-1 (a): a delete made while the journal is off is undone at the next normal start.
- Smallest fix: one sentence that covers all three ops, e.g. "the switch took this write but the journal did not record it: a later restart or readopt puts this entry back as the journal last knew it — an insert does not come back, a modified entry reverts, a deleted entry returns — and the replay report will not flag it".
  - Drop "always" at :1022.
  - Change "the rule IS" to "the write IS" at :1027.
  - Only the substring "journal write failed" is pinned (test_table_entry_journal.py:1226), so the change is cheap.

## minor

**m-1. `read()` can stop the proxy from starting.**
- rule_journal.py:734 opens the file as text (`encoding="utf-8"`); :751-754 catch only FileNotFoundError and OSError, although :727 says "A torn line is skipped and counted, never raised".
- One non-UTF-8 byte in any switch's file raises UnicodeDecodeError out of confirm_fabric (main.py:860, no try). The startup event fails and the proxy exits.
- This is new in Cut C, because startup now reads every file. It needs outside corruption, since the proxy's own writer only writes ASCII.
- Fix: read bytes and decode each line inside the existing try.

**m-2. A step-0 failure is untested, has no mutant, and its reason is never reported.**
- rule_journal.py:996 stores `self._fabric[key]["error"]`, but nothing reads it; `_blank_replay` (:1091-1096) copies only `fresh_fabric` and `cookie`.
- The only failure test (test_table_entry_replay.py:1059-1072) mocks `write_snapshot`. The confirmed path of `settle` uses `reheader` (:991) instead, so that branch is never exercised.
- Failure scenario: `reheader` fails on a confirmed switch, so the file keeps the old boot_id. The startup replay then sets it aside as `unconfirmed_header` while `cookie` says "confirmed". The entries are not put back, and nothing says why beyond `failures: 1`.
- SUMMARY §2-1's "報告帶 snapshot_error" (the report carries snapshot_error) is true only for the replay's own snapshot.
- Fix: copy the step-0 error into the report, add a test where `reheader` raises OSError, and add a mutant that removes the failure count in `settle`.

**m-3. Stale claims left in the code.**
- main.py:958-962: "it is False because nothing replays the journal … False until rule_journal's TABLE_JOURNAL_REPLAYS is flipped by the change that replays".
- test_app_package_proxy.py:417-419: "nothing replays them".

**m-4. The T8 basis in expected_today.tsv.**
- expected_today.tsv:19 cites "trial-h1.json, an audit-raw log outside the repo", but SUMMARY §8 says the evidence is "還沒歸檔到 audit-raw" (not yet archived to audit-raw). Archive it before merging, or reword.
- "RED only when the journal is off, external, or missed a record" there, and in cells/table.py:390-397, leaves out a failed step-0 or replay snapshot. That also makes `journaled` false (rule_journal.py:997-998 and 1103-1104, feeding :1135-1136).

**m-5. Replay writes with an unknown outcome are dropped from the journal (the design allows this).**
- rule_journal.py:1073-1080: any exception goes to `failed` and stays out of the snapshot.
- DESIGN §5.4 step 6's reason, "它們不在交換機上" (they are not on the switch), does not hold for DEADLINE_EXCEEDED or UNAVAILABLE. p4_client.py:32-33 itself says writes can land after a deadline.
- Scenario: the switch is busy right after the push, a replayed insert times out but lands, and the next restart silently loses it.
- Optional fix: keep failures that carry no per-update reason in the snapshot.

**m-6. Test isolation depends on future tests remembering it.**
- The guard in journal_isolation.py:31 only fires if the module is imported after main.
- A new test file that imports main and never imports the isolation module writes into the checkout's `.run` during per-file CI.
- check_no_stray_table_journal.sh is not in CI (SUMMARY §8 says so). Wire it into l1.

**m-7. The summary understates the port-guard hazard.**
- SUMMARY §8 says "C 之後它至少不會再碰 journal" (after C it at least no longer touches the journal).
- The PortFreeTest proxy (test_port_guard.py:100-136) gets through step 0 before SIGTERM arrives; red_m5_perfile_port_guard.log shows headers written for s1–s10.
- On a host with bmv2 switches running and no proxy, it now also pushes its own cookie. The real proxy's next start then sets every journal aside. Open a ticket.

## nit
- REPLAYED_WHEN (rule_journal.py:334-335) and boot_identity.py:35 say entries come back "on a switch whose pipeline cookie confirms" the journal. A readopt never reads the cookie (it checks only boot_id, :1034), and it does replay onto a power-cycled switch whose cookie is gone.
- api_routes.py:1065-1067 says "the 503 comes before any 400 or 409 above", but the dpid 400 (:1085-1089) and the unknown-switch 404 come first.
- `_pending` is a set (rule_journal.py:858, 963, 966). With two overlapping readopts of one switch, the first clears the flag the second set, so POSTs wait and get "switch busy" instead of "replay pending". No record is lost; a counter fixes it.
- The guard at `_replace_with` (:657) checks that someone holds the lock, not that the caller does. Its docstring says exactly this, so it is acceptable.
- Replay order is first occurrence (:446-452). For a key deleted and re-inserted after another key, this differs from the switch's pre-restart insertion order. That matters only for overlapping ternary entries at equal priority [inferred: the winner is then up to the target].
- boot_identity.py:33-34 "EXCEPT the entries … restored lists": `restored` also lists net deletes, which are not installed entries.
- SUMMARY §2 says "其他每一行 byte 不動" (every other line byte-for-byte unchanged), but `reheader` drops blank lines and adds "\n" to a torn last line (rule_journal.py:651-653). The set-aside copy keeps the original bytes.
- mutate_table_journal.sh:15 says M-J30c is gone; it is present at :460-463.
- check_no_stray_table_journal.sh:90-91 prints the single-process explanation for a per-file stray as well (red_m5_perfile_port_guard.log:10).
- The body of commit 06a3f55b names a review item ("the M1 fold").

## The summary's own numbers and claims
- **SUPPORTED:**
  - The §4 gate lines. Each log's first line is commit fd208fbd and its last is rc=0. Counts match: 158/0, 79/0, 27/0, 27/0, 194/0, 14/0, 48/0, 23/0, 6/0. GATE's 494/0 is the health check's four shards, not a sum of the others.
  - Every §2 line reference I spot-checked.
  - 9 commits, 31 files, +3074 (the stat minus the summary's own 170 lines).
  - Both m5 red logs, and the final no-stray log (2051 tests, 50 files).
  - The trial's per-boot claims, including priorities 2147483637 and 2147483627 in the thrift dumps (trial-h1.json lines 22, 416, 933, 1327).
- **SUPPORTED in a weaker sense than stated — "183 seen red":** seen_red.py:6-7 and :17 count a test as red if its id appears in any "also red" line, or its bare name is any mutant's named killer. That means "red at least once", not "red for its own reason". 140 + 43 test defs = 183, so the count itself is consistent.
- **CONTRADICTED:**
  - §5 "25 項檢查" (25 checks): trial.py:129-166 produces 23 per binary, and trial-final.log has 46 ok lines.
  - §2-1's snapshot_error claim for a `reheader` failure (see m-2).
  - The tsv's "audit-raw" (see m-4).
- **UNDER-EVIDENCED:**
  - §3 m4 says every log starts with the commit and ends with rc=N, exceptions listed in §8. journal_tests_seen_red.txt has no rc line and is not listed.
  - "+645" and "+449" are insertions plus deletions, not insertions.
- **UNTESTED:** the OSError branch of `settle`; step 0 on a journal-off boot (§7-1); the replay of a client with no json_path (§7-2).

## Answers to 2–5 and 7

**2. Replay correctness.**
- **Re-install an entry the user deleted?** Yes, in three ways: M-1; a delete whose journal record failed (accepted under Q4 (a), but the note misstates it, M-2); and a journal-off boot (§7-1 (a)).
- **Install into the wrong pipeline?** No. A changed or unknown p4info sha makes everything stale_pipeline (rule_journal.py:1040-1051, M-J5).
- **Drop one that should come back?** Yes, in four ways:
  - the M-1 boot-entry insert;
  - m-5 (unknown-outcome replay writes);
  - m-2 (a failed `reheader`);
  - a COOKIE_ONLY read that takes longer than 2 s (§7 ruling below).
- **Cookie verdict:** sound. Every unconfirmed case sets the file aside (:797-814, :992). A fabric whose confirmed switches disagree gets a new generation (:826-837, M-J97). A switch missing from `clients` is caught later by the boot_id check at :1034.
- **Quarantine:** it cannot lose bytes. The set-aside is a hard link taken under the lock before `os.replace` (:675-678). Bytes leave only by pruning.
- **First-occurrence order:** safe for distinct priorities, because priority is part of the key (M-J92/92b); see the nit for equal priorities.
- **M1 implementation:** matches the ruling exactly and does nothing more; the ruling has the M-1 hole.

**3. Concurrency.**
- No lost or doubled record:
  - pending is checked before and inside the lock (:909, :911);
  - the client is looked up inside the lock;
  - the replay re-reads the file (:1032, M-J17);
  - the replay's own writes go around write_and_journal (M-J4).
- No deadlock:
  - lock order is always journal lock, then `_registry_lock`;
  - readopt takes the journal lock, then TopologyManager's `_readopt_lock` (main.py:1819, topology_manager.py:1425), and nothing takes them the other way;
  - no journal lock is held across an await.
- Startup cannot interleave with requests. The socket is pre-bound, but uvicorn serves only after lifespan startup (main.py:2694-2731) [inferred from uvicorn's ordering].

**4. Disclosure.**
- Mismatches: M-2, m-3, m-4, and the REPLAYED_WHEN, 503-ordering and restored-includes-deletes nits.
- The T8 basis is otherwise accurate: observed offline at e8d91655 (trial-h1.log line 1, ALL CHECKS PASS, rc=0), again at fd208fbd, and "no live health.json" is stated.
- T8 reads only the `journaled` flag (observe_a.py:305-311), so a live GREEN would not itself demonstrate a restart.

**5. Tests.**
- Mutants spot-checked against the code they claim to break; in each case the anchor is the cited code and the change breaks what the label says:
  - M-J91 (k1, rule_journal.py:459), M-J91b (k1b, :407), M-J91d (k1d, :459);
  - M-J22c (g3c, :807-808), M-J27 (h13, :1034), M-J18b (p1b, :908-910), M-J103 (q1, :657-658);
  - M-J104 (g8, main.py:867-868), M-J95b (g2b), M-J26 (g5).
- M-J104, M-J94b and M-J20b are killed only through the lock guard's RuntimeError. That still counts as their own reason.
- The m5 isolation holds for today's 15 files (see m-6 for future files).
- Gaps: the three UNTESTED items above.

**7. Public safety.**
- No credential, token, or absolute /home path in any added line. A grep of the diff found only `import secrets` and `secrets.randbits`.
- Borderline: SUMMARY-cut-c.md:166 (diff line 206) describes an unfixed test hazard — the suite can push a pipeline onto a live local fabric. It is an operational hazard, not something an attacker can use; publishing it is your call.
- Commit messages carry no trailers.

## Rulings on the worker's seven open choices
- **§2-1 (a failed snapshot withdraws `journaled`): keep the policy, change the disclosure.** It matches Q4 (a)'s conservatism. Surface step 0's error in the report and add a test and mutant (m-2).
- **§2-2 (all-stale is reported as `failed`): keep.** Entries existed and did not come back, and "nothing-to-replay" would hide that; `stale_*` and the per-entry reasons say why.
- **§2-3 (COOKIE_ONLY timeout 2 s): change to `RPC_TIMEOUT_S` (5 s).** A false "did not answer" here sets the journal aside for good, whereas a probe's false is transient. p4_client.py:32-34 already chose 5 s because bmv2 is slow under load. The cost is up to 3 s more per dead switch at startup.
- **§2-4 (two set-asides per boot, keep=10 ≈ 5 boots): keep.** DESIGN 10-11 counts files, not boots. Add one line to the QUARANTINE_KEEP comment saying a boot uses two.
- **§7-1 (journal off, step 0 still runs): change to (b)** — when the journal is off, step 0 treats every switch as unconfirmed.
  - Reason: an off boot records nothing, so under (a) the next normal start re-installs entries deleted while the journal was off — the "yesterday's entries" failure that Q1 (a) exists to prevent.
  - This amends DESIGN.md:457 ("步驟 0 只要求 not read_only", step 0 only requires not read_only).
  - If you want Adam's sign-off, the question is: "Should turning the journal off for one boot discard the replayable journal?" With (a), deletes and modifies made while off are undone at the next normal start. With (b), entries POSTed before the off boot are not put back; they stay only in the set-aside file.
- **§7-2 (client with no json_path is still replayed): change.** Skip the replay when `not client.json_path`, the same test the push loop uses (main.py:2181). This makes the comment at :2230-2231 ("on every switch whose pipeline this startup pushed") true. Without it, each replayed insert meets ALREADY_EXISTS and the snapshot then drops entries that are still on the switch.
- **§7-3 (default entry whose last record is a delete folds to nothing): keep.** A delete of a default entry is refused for a reason other than NOT_FOUND, so no such record can ever be written [inferred].

## Tests I would have run
1. **Boot-entry lost-answer delete:** delete lands but the answer is lost, the retry gets NOT_FOUND, restart → B must be absent. I expect this red today.
2. **Failed journal write on a delete (Q4 (a)):** restart → check what the note promised. Today E comes back.
3. **Journal off for one boot, then on:** an entry deleted while off must stay deleted. I expect this red under (a).
4. **One invalid UTF-8 byte in a switch's journal file:** startup must complete. I expect this red today.
5. **`reheader` raising OSError on a confirmed switch:** check what the report says.
6. **Live readopt on throwaway stock and fast bmv2:** restart the bmv2 process and readopt through the real TopologyManager. Assert the entries are back, the push carries G, and a concurrent POST gets 503 replay pending. The trial covered startup only.
7. **Two overlapping readopts of one switch with a POST during the second.**
8. **A live two-switch fabric with one switch restarted.**
9. **COOKIE_ONLY latency on a loaded multi-switch fabric**, to size the timeout.
10. **The trial's "same entries as after boot 1" check:** it compares counts only; compare action params too.
