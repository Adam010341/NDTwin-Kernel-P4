# Judge: Cut C round 4, scoped (feat/p4-ternary-replay-c, 7f69609b..2621a34a)

(Opus judge, read-only, 2026-10-15 ~19:2x. Saved by the orchestrator from the hand-back; content as delivered, lightly condensed in §4-§6 tables' prose only.
🔴 Discusses loss shapes in unmerged branch code: keep off public refs until fixed and public.)

MERGE AFTER FIXES

I executed nothing and only read files. Line numbers are at 2621a34a. rj = p4_proxy/proxy_agent/rule_journal.py; rp = p4_proxy/tests/test_table_entry_replay.py; sh = tests/shell/mutate_table_journal.sh; E = logs/gates-0910/p4-ternary-replay-c/r4.

## BLOCKER
None.

## MAJOR
None. A does what the ruling says. I found no history in which it writes something that contradicts the journal's last record.

## minor
**1. The rewritten test drops the only pin on "a package entry that did not go back on, plus a journaled modify". A now changes that outcome, on a premise the code states as the only cause.**
- Where: rp:1069-1086 now refuses the MODIFY instead of the boot entry's INSERT. rj:1145-1147 and DESIGN.md:342 say a NOT_FOUND means "the key's earlier existence was wiped by the push".
- Scenario: the package declares B at K. The operator modifies K to S, so the journal is `[modify/ok S]`. At the next start the switch refuses B's boot insert. Before this round: the modify met NOT_FOUND, failed, and was dropped. Now: the insert of S lands, `retried_as_insert == [K]`, and the status is complete. I judge the outcome right: S is the last word, and an insert cannot overwrite [inferred]. But no test asserts it, and the stated cause is wrong for this case.
- Fix: re-add the old hook (refuse an INSERT whose port is 9) as a new test asserting: port 5 present, `retried_as_insert == [K]`, (attempted, succeeded) == (2, 2), live ops `[modify, insert]`. Add "or the package's own entry did not go back on" to rj:1145-1147 and DESIGN.md:342.

**2. An entry restored by A is dropped at the first start after any change to this switch's entries file, and this round's API text says it comes back.**
- Where: the stale check at rj:1116-1119 is unchanged (as ruled). The item stays a modify for ever (rj:1183-1185, :514-515). api_routes.py:1022-1024 says only "a modify or delete aimed at one of the package's own entries" is dropped; api_routes.py:1032-1033 now promises the insert; `_STALE_ENTRIES` (rj:386-387) says "this write was aimed at one of its entries".
- Scenario: (1) journal `[delete/ok K, insert S]`, K never a package entry. (2) Boot N: A restores S; live file `[modify/ok S]`. (3) The operator edits the entries file (any line) and restarts. (4) Boot N+1: step 0 keeps the old entries digest (rj:1034-1037), so `entries_changed` is true; the modify is stale: never sent, `kept` False, dropped from the live file. (5) S is gone from the switch and from the journal; it survives only in a set-aside copy for about five boots (rj:345-347). The reported reason is false for K.
- Not a regression: before A, S was lost at the first restart.
- Smallest fix, inside the ruling: disclose it — one clause in api_routes.py:1022-1024 and in DESIGN.md:818; reword `_STALE_ENTRIES` to "may have been aimed".
- Closing it needs a ruling, e.g. snapshot a fallback-restored item as `[not_found delete, insert S]`. That also re-inserts a key from case 3 (§2) that the new entries file removed, so it is a trade-off, not a free fix.

## nit
1. api_routes.py:1032-1033: the new clause sits inside the NOT_FOUND-delete sentence, where an unknown-start key never folds to a modify. It is also unconditional: no default-entry exclusion, no entries-file exception. Fix: its own sentence with both conditions (same edit as minor 2).
2. Statements this round made false or incomplete (one clause each):
   - sh:946, the M-J91c label, says "a later insert … is replayed as a modify and lost". At this head that modify meets NOT_FOUND and A inserts it. M-J91c is now killed only by the op assertions (rp:619-620, :660-663; log :1142-1146). The MAJOR-1 loss is no longer visible on its own in the unit suite; the m1 trial's "nothing retried / two inserts" checks would still see it.
   - rj:1070-1073: "a net modify … which was aimed at a boot entry of the old file". A's own premise is a net modify of a key that was never a package entry.
   - rj:1275-1276: `report()` (what switch_state serves) documents `failed[].kept` but not the new `failed[].retried_as`.
   - DESIGN.md:493 still gives NOT_FOUND as an example failure reason; a non-default modify's NOT_FOUND is now retried.
3. The commit message lists mutant IDs and talks about process (cut-c-r4.commits.txt:13-16: "single-fault M-J91k, code-anchored M-J110 and M-J126", "comments that pointed at past reviews"). CLAUDE.md asks for no lists of test numbers. Fix: "…tighten the journal gate's mutants and reword a few comments."
4. No bmv2 run triggers A. All 42 `retried_as_insert` occurrences in E/trial-r4.json are empty. The premise is evidenced: E/trial-r4red.json:2429 (stock) and :5003 (fast) show a replayed MODIFY of an absent ternary entry answered `NOT_FOUND: Cannot find match entry`, read by the same per-update parser `_is_not_found` uses (api_routes.py:950-953, main.py:888-895), so A should fire on bmv2 [inferred]. Fix: add an m2 sequence to the trial.

## 1. Round-3 findings
| Finding | Status | At 2621a34a |
|---|---|---|
| minor 1 | FIXED | DESIGN.md:497, its own "not a failure" bullet beside 例外一 :496 |
| nit 1: retried_as_modify | FIXED | rj:1266-1269 |
| nit 1: stale_entries | FIXED | rj:1278-1279 |
| nit 1: api_routes unconditional | FIXED; the added clause brings its own problem (nit 1) | api_routes.py:1031-1032 |
| nit 1: records count | FIXED | rj:501-502 |
| nit 2 | FIXED | rj:1125. No mutant; equivalent (no DELETE or MODIFY answers ALREADY_EXISTS, and no modify carries the mark) |
| nit 3 | FIXED | rj:1140, :1174-1176; rp:1307-1309; M-J134 at sh:1577-1581, log :1905 |
| nit 4 | FIXED | sh:949-955 `if True:`; log :1147-1157 |
| nit 5 | FIXED | M-J127 (log :1884); M-J128a/b/c (:1886, :1888, :1890); M-J129 (:1892) |
| nit 6 | FIXED | rp:1224-1243; E/trial-r4.log:114-149 |
| nit 7 | FIXED | DESIGN.md:816 |
| nit 8 | FIXED | sh:1227-1231 `        elif i in broken:` (main.py:2260, unique); M-J126 at sh:1500-1504 |
| nit 9 | FIXED | also api_routes.py:127 and sh:507. api_routes.py:1456 still has "finding #71" (untouched; "older than the branch" unverified) |

## 2. A in depth
| # | History | Fold | Replay | Snapshot, then the next boot |
|---|---|---|---|---|
| 1 | `[delete/ok K, insert S]`, K absent after the push | modify S, unmarked | Modify → per-update NOT_FOUND → K named (:1152) → S inserted. Restored, op modify | `[modify/ok S]`, one record; next boot identical (rp:1386-1390 asserts both boots) |
| 2 | Same, K a package entry | modify S | B is back; modify succeeds; no retry | `[modify/ok S]`, identical |
| 3 | `[modify S]`, B's boot insert refused | modify S | NOT_FOUND → insert of S lands | `[modify/ok S]`; repeats until B installs. Unpinned (minor 1) |
| 4 | Insert S with lost answer, then modify T | Cannot be in the journal: a write that raises is not recorded, except a NOT_FOUND delete (rj:951-959) | If S never landed, modify T is NOT_FOUND, not recorded (M-J33c): K absent, consistent. If S landed, journal `[modify/ok T]` and A inserts T (before: T lost) | — |
| 5 | Default entry | modify | NOT_FOUND hits the guard (:1143): failed, no retry, dropped | — |
| 6 | Case 1, entries file changed | modify S | Stale before the write, `kept` False | Dropped (minor 2) |
| 7 | Case 1, pipeline changed | modify S | stale_pipeline | Dropped; by design |

- Insert an entry the user deleted? Only when the delete is missing from the journal (an unanswered, never-retried delete). Not a new class: the same history already resurrects S when K is a package entry or the net op is an insert; api_routes.py:1025-1027 promises nothing to an unanswered write [inferred].
- Insert over something? No: INSERT never overwrites (ALREADY_EXISTS → failed with retried_as insert); both writes run under the switch lock.
- Insert a spec the journal does not end with? No: last record's spec (rj:472), passed unchanged (:1153); the writer has no fallback of its own.
- Stable? Yes while both digests hold: one record, `retried_as_insert == [K]` every boot, only `t` changes; a modify never carries `unknown_before`. Breaks at the first entries-file change (minor 2).
- Readopt reaches it the same way (main.py:2275 and :1972-1973 → replay_table_journal with the same callbacks). No readopt test of A [inferred works; M-J98b reddens (i), (ii), (vi)].
- Modify NOT_FOUND where insert is wrong? Case 3 (insert right, stated premise wrong: minor 1); external reload (S is still the last word); unknown table/action (insert fails the same way, reported); defaults excluded.

## 3. The changed test
Keeps: the switch's reason in `failed` (M-J100's killer), a refused write leaves the live file (M-J99), attempted/succeeded/partial; now also pins "INVALID_ARGUMENT is not retried" (red under M-J131). Loses: the scenario "package entry that did not go back on + journaled modify"; its new outcome is asserted nowhere (minor 1). NOT_FOUND as a modify's reason is still pinned by (v).

## 4. Tests and mutants
(i) red :1832, M-J130; (ii) red :1848, M-J130/M-J98; (iii) KeyError only, behavioural red M-J135 [inferred]; (iv) KeyError only, M-J131 [inferred]; (v) KeyError only, M-J132 [inferred]; (vi) red :1857, M-J133 [inferred]; nit 3 KeyError 'retried_as' (the absence is the behaviour), M-J134/M-J127; nit 6 green on old code as expected, red under M-J91f :1120, M-J91i :1133, M-J17 :1718.
The red run used the committed test files (traceback lines match 2621a34a). New mutants: anchors unique, single edits, also-red lists 1-4 tests, all caught at 2621a34a tracked-dirty=0. 189 = 178 + 11 holds. Re-anchored M-J110/M-J126 caught for their own reason [inferred].
Gap [inferred]: no test has two failed items where the first is a failed retry; a mutant hoisting `retried_as = None` (rj:1120) above the loop would survive.

## 5. bmv2 trial
MAJOR-1 restart-in-the-middle exercised on stock and fast (one_m1, four proxy processes per binary; thrift after every boot, P4Runtime inside each boot); all pass (trial-r4.log:114-149); :124/:142 and :125/:143 show the MAJOR-1 path, not A. Red control at f3db4dd1: exactly six FAILs per binary (:28-33, :46-51). The six-boot series is unchanged from r2 (trial_boot.py differs only by m1a/m1b).

## 6. Claims
SUPPORTED: commit/files/no trailers; A's code and report shape; no `retried_as` text in api_routes; tests and the rewritten test; red log (rc=1, 214, 3F/4E); M-J127-135 lines; 189; nit fixes; anchors 137/137 ok(172) vs r3 ok(164); 214 OK; cells 187 OK; tsv :1247; wait.log timeline (rc values unreliable, disclosed); trial and red control; clones deleted.
UNEVIDENCED: quickmut.py runs; api_routes.py:1456 older than the branch; git status; no sudo/lab/push/pkill.
CONTRADICTED (trivial): "25 places" (28); (iii)/(iv)/(v) line order; stock FAIL range :28-33; ":56, :90" are M-J1/M-J1b; "no build" (p4c compiles only).

## 7. Public safety
No credentials/tokens/home paths; no review/finding IDs or "round N" in added lines; message has no trailers but see nit 3; no added text describes an unfixed weakness (minor 2's residual is described nowhere; disclosing it documents a durability limit, not a hole [inferred]).

## 8. Health check
openapi_probe reads untouched main.py; api_routes changes are a comment and the POST docstring; no route change. S0 unchanged. T8: `journaled` (rj:1244-1247) unchanged in inputs. tsv :19 cites rj:1247 = `return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS`; :331 = `TABLE_JOURNAL_REPLAYS = True`. Nothing under tools reads the replay report. No new reason for the deferred gates.

## Tests I would have run
1. A bmv2 run of A (insert K straight through the client as the `lostanswer` plan does; POST delete K, POST insert S, restart twice; variant restarting after the delete): expect `retried_as_insert == [K]`, S read back by thrift and P4Runtime, live file `[modify/ok S]`.
2. Case 3 as a replay test (minor 1).
3. An A-restored key, then an entries-file change not touching K, then a p4info change.
4. A through readopt.
5. An insert retry answered DEADLINE_EXCEEDED: kept True, retried_as insert, back at the next start.
6. The two-failure `retried_as` leak.
7. A mutant that snapshots a fallback-restored item as an insert, to see rp:1386 go red.
