# Judge D, round 1: feat/p4-health-ternary-d @ 6dc8b9a4 (code 76e3b468)

> Saved 2026-10-11 13:45 by the session that dispatched the review, from the reviewer's final message, unchanged below this note. Dispatcher notes: (1) the reviewer did not read judge-cut-a-0d070625-r3.md; its Hold 1 / MAJOR B ask for "Cut A and D land together, S0 COMPLETE at that head" plus D's file list, which this review covers through ternary DESIGN §7. (2) m6's "trunk at 64338970" is the local trunk (it carries other sessions' unpublished commits and is never pushed); the public trunk is still 18c81892 (unauthenticated ls-remote 13:45), which is D's base.

**Verdict: MERGE AFTER FIXES.** The code does what the hand-back says, every gate number checks out against its log, and S0 is COMPLETE at 76e3b468. Four things still need work: the T4–T7 GREEN flips have no live evidence, which the cited design rule asks for; S0's "ternary entry present" check is narrower than claimed; the gate does not watch a new suite input; and a few design and test texts describe behaviour the code no longer has.

**Scope.** Everything here was read only; nothing was executed and git was not used. What I read:
- the patch and commit-bodies.txt;
- every log in `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-ternary-d/` (LOG below);
- the code in `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-health-ternary-d/` (WT below);
- only the cited design rows: health-check DESIGN.md:293, :423 and :577-578; ternary DESIGN.md §1.7, §6.4 (:638-647) and §7 (:654).

**I did not read `judge-cut-a-0d070625-r3.md` (§7 Hold 1, §11 MAJOR B).** My role excludes prior review documents. So I cannot certify D against those two items. Instead I checked D against the D scope listed in ternary DESIGN §7 (:654): the S0 PF-T checks, expected_today.tsv, the PF-T RED path, and the T4–T7 oracles. Please cross-check Hold 1 and MAJOR B against the findings below.

## Classification

| # | Claim | Class |
|---|---|---|
| 1 | classify_pft and PF-T cell semantics | SUPPORTED as code. Design basis UNDER-EVIDENCED. The "continuation row" half is UNTESTED. |
| 2 | S0's PF-T checks; pft_verdict wants GREEN | SUPPORTED. The protection is narrower than stated (MINOR m1). |
| 3 | T4 body 10.0.4.0/24; tsv flips | Body change SUPPORTED. T4–T7 flips UNDER-EVIDENCED against §5.1. PF-T flip SUPPORTED by S0. |
| 4 | T4–T7 oracles unchanged; C2-OA2 / AD10 / C2-OA3 | SUPPORTED |
| 5 | Fixtures recaptured | SUPPORTED. g5 provenance UNDER-EVIDENCED (immaterial). |
| 6 | FakeFabric writes ternary and uses the real match_shape | SUPPORTED. It adds a gate blind spot (m2). |
| 7 | lab.py:60 reads the new key | SUPPORTED. The branch cannot be reached in run_lab (m4). |
| 8 | Gates at 76e3b468 | Each number SUPPORTED. "Every new/changed behaviour seen red" is UNDER-EVIDENCED. |
| 9 | Open items | SUPPORTED as disclosures. The V7 inference can be strengthened. |
| – | Commit messages, co-developed marks, p4_proxy/ and tools/p4_exercise/ untouched | SUPPORTED |
| – | Trunk readiness | SUPPORTED at 76e3b468. Not yet established at the head that will land (m6). |

## Claim 1: classify_pft and the cell

**Code** [read]:
- `WT/tools/p4_health/s0.py:149-162`: classify_pft counts a line as a ternary refusal when it starts with `  FAIL` and matches `(?<![\w])<where>:`. `where` comes from `pft_entries`. The "G5 not done" text is no longer tested.
- `WT/tools/p4_health/cells/table.py:403-417`:
  - RED needs `rc ∉ {None, 0}`, `ternary_rows ≥ 1` and `other_fail_rows == 0`;
  - any other rc ≠ 0 is PROBE-BROKEN;
  - **rc 0 alone is GREEN**.
- "No FAIL rows and the entry present" are S0 checks, not cell conditions. The combined behaviour still matches the claim, because the lab reads PF-T only from a COMPLETE S0 (`lab.py:324-325`) [read].

**Red evidence** [read]:
- AD1 and AD7 were caught by `test_pft_refused_in_any_words_is_red_and_never_green` (shard2:77-81, shard0:89-93).
- AD2 and D12 were caught by `test_pft_is_the_ternary_answer_only_when_nothing_else_failed` (shard3:77-81, shard1:77-81).

**Wording is slightly overstated** [read]. A FAIL line that names the entry under some *other* labelled row counts as both ternary and other, so the cell is PROBE-BROKEN, not RED. RED needs the naming line to sit in the "entries match p4info" row.

**The continuation-row clause is UNTESTED** [read]. The docstring says "the labelled row or a continuation under it" counts (s0.py:153). But:
- every fixture names the entry on the labelled row;
- the `cont` case adds a continuation line that does *not* name the entry;
- so a labelled-only mutant would survive.

Pre-flight does print later problems as continuation rows (`WT/tools/p4_exercise/preflight.py:1170-1176`), so the case is real.

**Design basis.** DESIGN.md:293's GREEN column ("a boot entry naming a ternary field passes pre-flight") does support "the cell measures a pass, not a sentence" [read]. However:
- the RED column of the same row names the G5 FAIL;
- ternary DESIGN.md:647 says that after A+D, PF-T "can only be GREEN or PROBE-BROKEN";
- D re-creates a RED label. :293 does not establish that choice.

In practice the choice only affects wording. S0 requires a GREEN verdict (`s0.py:746`) and is COMPLETE only when every check passes (`s0.py:768-769`). So any refusal makes S0 PROBE-BROKEN, and the RED label appears only inside that failed check's detail [read]. The worker flagged this choice; it needs a one-line note in the design (m5).

## Claim 2: S0's PF-T checks

SUPPORTED [read]:
- `s0.py:346-358`: "PF-T package carries one ternary boot entry" (`len(wheres)==1`), and "pre-flight PF-T PASSes with the ternary entry in" (`rc==0 and not fails and len(wheres)==1`).
- `s0.py:738-748`: pft_verdict wants GREEN.
- `LOG/s0-run/probe.log:24-25,58` shows all three checks ok.
- `s0.json:867-875` records `ternary_entries ["s2 entry 23"]`.
- The red tests are those named in the patch; mutants AD3, AD4, AD5 and AD6 were caught (shard0:83-87, shard1:83-87, shard2:83-87, shard3:83-87).

**Gap (m1)** [read]. `pft_entries` (s0.py:143) filters on the table name only. Pre-flight accepts a t_ternary entry that has a priority and no `match` at all: it is a legal catch-all on a priority table (preflight.py:220-224), and V6 is satisfied (:292-295). Such an entry passes both checks and gives GREEN without any entry naming a ternary field, which is :293's GREEN condition. "A PASS cannot hide a dropped entry" holds; "cannot hide a dropped match" does not.

## Claim 3: T4 body change and the tsv flips

**The body change is right** [read]:
- V3 (`WT/p4_proxy/proxy_agent/match_shape.py:314-318`) refuses 10.0.4.4/255.255.255.0.
- The route turns TableEntryInvalid into a 400 (`WT/p4_proxy/proxy_agent/api_routes.py:1014-1017`). The worker marked this as inferred; it can be marked [read].
- `write_then_read` turns any non-200 into RED structural (`table.py:363-366`), so T4 would have been RED, or UNATTRIBUTED without B.
- The oracle's value and mask are numerically unchanged. The old code masked the value to 10.0.4.0 (patch :643-644).

**Nothing else depends on the old value** [read]:
- In the worktree, every other 10.0.4.4 is h4's host address (topologies, lpm routes, markers, digest fixtures), or the new AD9 mutant and its test.
- B's controller already writes 10.0.4.0/255.255.255.0 (`WT/tools/p4_health/controller_ext.py:47-48`). That is bring-up B, so it cannot collide with A's write.
- `observe_a.py` is the only consumer of `T4_BODY`.
- A grep of the main repo's non-ignored files finds the old body only in trunk's own `tools/p4_health/observe_a.py`.
- `meta.t_mark` is assigned but never read (`hc_main.p4:403,428,466`). So T4–T7 entries that now really land on s2 cannot disturb other cells' traffic.

**The tsv flips** [read]. DESIGN.md:577-578 (§5.1) says each fix PR names the cells it flips, **attaches health.json**, and changes the expected file in the same PR. D names the cells and changes the file; there is no health.json for T4–T7. PF-T's flip *is* observed, because the cell's oracle is S0 (`s0.json` pft GREEN). T4–T7 GREEN remains a prediction, as the worker discloses (MAJOR M1).

## Claim 4: oracles

SUPPORTED [read]:
- `observe_a.py:222-223`: `thrift_priority = 2^31-1 - p`.
- `observe_a.py:271`: T6 looks for `entries_with((17, 0xFF))`.
- `observe_a.py:296-297`: T7 requires the narrow entry's number to be the smaller (`n < w`).
- C2-OA2 (`mutate_p4_health.sh:1622-1626`) and C2-OA3 (`:1628-1632`) exist.
- C2-OA2 (shard0:359-363), C2-OA3 (shard1:359-363) and AD10 (shard3:89-93) were all caught by `test_a_proxy_that_writes_ternary_turns_t4_to_t7_green`.

**Extra evidence the worker did not cite** [read]. S0's ctrl_trial at 76e3b468 confirmed the ternary, range, optional and priority attributions on throwaway stock and bmv2-fast switches (`probe.log:52-53`). It used `attribution.py:39-106`, which applies the same three conventions and the same T7 value/priority pair. So the oracles agree with bmv2's dumps of P4Runtime writes at this commit. Those writes came from controller_ext, not from the proxy.

## Claim 5: fixtures

SUPPORTED [read]:
- `LOG/capture_pft.py` builds the packages the way S0 does, copies PF-T, and sets entry 23's mask to 255.255.255.0.
- `capture_pft.log`: commit 95a8972b, tracked-dirty 0, pft rc 0, pft_refused rc 1, index 23. Both stderr files are empty.
- `capture/pft.raw.txt` and `pft_refused.raw.txt` match the WT fixtures line for line, except the added `#` header and the `<run>` substitution.
- `preflight_pft_g5.txt` agrees with the old fixture's lines as far as the patch context shows. Its "(fixture of cc805894)" provenance cannot be checked without git, and does not matter.

## Claim 6: FakeFabric

SUPPORTED [read]:
- `WT/tests/python/test_p4_health_collect.py:1397-1412` loads the real match_shape; `:1473-1474` defaults to writing ternary; `:1575-1592` runs `shape_field` and `shape_priority` and answers 400 on a refusal.
- AD9 shows that 400 path seen red in five tests (shard2:89-93).
- The old 501 path is still exercised:
  - `test_without_b_every_bmv2_red_is_unattributed` (explicit False);
  - `test_a_call_the_controller_lost_is_unattributed_in_a`;
  - the new `test_a_proxy_before_the_ternary_writer_is_t4_to_t6_red_and_t7_not_run` (T7 NOT RUN, 501 in the reason).
- The "RED with bmv2 attribution in a full lab run" assertion moved from T4 to MT1. The attribution merge is the same generic `AT.for_cells` path, so nothing is lost.
- Dropping `& mask` from the fake's stored key changes nothing, because V3 now guarantees the value is already masked.

**Side effect (m2)** [read]. The collect suite, and so every gate baseline and mutant verdict, now reads `p4_proxy/proxy_agent/match_shape.py`. That file is not in the gate's WATCHED list (`mutate_p4_health.sh:64-74`).

## Claim 7: lab.py:60

SUPPORTED [read] (`lab.py:57-62`; AD8 caught at shard1:89-93).

However, run_lab only calls `pft_observation` when S0 is COMPLETE (`lab.py:263-267,324-325`), and S0 is COMPLETE only with PF-T GREEN. So the key is never consulted on a branch run_lab can reach, and AD8 guards dead code. The new test's name `..._is_pft_red_in_the_lab` (collect:2621) describes an outcome run_lab cannot produce: in the lab that S0 means INCOMPLETE with PF-T unobserved (m4).

## Claim 8: gates

All at commit 76e3b468, tracked-dirty 0 [read]:
- cells: 183 OK (`a.cells.log:199-201`, `a.cells.py38.log:134-136`);
- collect: 186 OK on both interpreters;
- recover: 163/0; gate_scripts: 68/0;
- GATE.log:3 matches the claimed line exactly;
- shards: 121+121+121+120 = 483. Each shard has a green baseline, a green negative control, byte-identical originals, and "0 survived";
- the four shards ran one after another in a single chain process with LANG=en_US.UTF-8 and the same cwd (`chain_mut.sh`, `mut_driver.log:1-10`);
- S0: 57 "ok" lines (`probe.log:2-58`) and S0 COMPLETE;
- AD1–AD10 and D12 were each caught by their named test;
- tsv revert: the two named tests fail, listing flips `['PF-T','T4','T5','T6','T7']` (`red.tsv_reverted.collect.log`).

"Every new or changed behaviour was seen red" is UNDER-EVIDENCED:
- the continuation clause (claim 1) has no red test;
- the check line at s0.py:352 has no mutant of its own (a test would catch it, but it is not seen red as a line);
- pft_entries' unreadable-package and multi-switch handling has no test.

## Claim 9: open items

- "Only a prediction" is accurate.
- **V7 inference, strengthened** [read]:
  - package A has no `roles` (`LOG/s0-run/packages/A/package.json`);
  - `route_binding_for` returns None for a foreign pipeline without roles (`main.py:297-313`);
  - `table_owned_by_ndtwin(None)` is False (`p4_client.py:1287-1289`);
  - existing unit tests cover both steps: `p4_proxy/tests/test_route_binding.py:507` and `test_table_entry_owner.py:458` ("a foreign switch with no roles owns nothing"). Their runs are not in D's logs.
  - The one remaining unread step is that `pipeline_is_ndtwin` is false for hc_main, which is a path comparison [inferred].
- `runtime_cli.py:57` still says "(G5)" [read].

## Other checks

- **Commit messages** [read commit-bodies.txt]: each has one subject line and plain sentences. None contains judge, intake, ruling, report, orchestrator, opus or ticket, and none has a Co-Authored-By or co-developed trailer.
- **Co-developed marks** [read]: every changed .py/.sh file carries the file-level mark, and the new AD block in mutate_p4_health.sh carries it inline.
- **Untouched paths** [read]: the 13 diff headers include nothing under `p4_proxy/` or `tools/p4_exercise/`.
- **Trunk readiness**: met at 76e3b468 [read]. 6dc8b9a4 is said to add only the SUMMARY section [inferred from driver.done]. For the head that actually lands, see m6.

## Findings, ranked

**MAJOR M1: T4–T7 flip in expected_today.tsv with no health.json.** DESIGN.md:578, the rule D cites, requires one in the same PR.
- Smallest fix, either:
  - (a) one lab run at the final head, narrowed with `--only T4,T5,T6,T7 --bringups A` (the form lab.py:11-12 documents), under NDT_OWNER with a claim, archiving health.json; or
  - (b) a recorded deferral (Adam's call), with the four basis cells saying "predicted from code; no live run".
- Smallest re-run: (a) S0 plus that lab run; (b) the collect suite once.
- If the earlier Cut A review already waived health.json, this drops to MINOR.

**MINOR**

- **m1: match-less PF-T entry.**
  - Fix: in `pft_entries`, also require `not e.get("default_action")` and that `hdr.ipv4.srcAddr` is in `e.get("match") or {}`. Add a cells test where the 24th entry is `{"table": "HcIngress.t_ternary", "priority": 10}` and both checks are False. Add an AD11 mutant.
  - Re-run: cells on both interpreters, `ONLY_LABEL_PREFIX=AD11`, S0.
- **m2: gate WATCHED list misses match_shape.py.**
  - Fix: add `p4_proxy/proxy_agent/match_shape.py` to WATCHED, plus a gate_scripts check and a C2R6-6-style mutant.
  - Re-run: gate_scripts and that mutant. A new GATE line needs the full gate (about 6.5 h, judging by mut_driver.log), so bundle it with the next p4_health change. This run is unaffected, because the clone was clean.
- **m3: continuation clause not seen red.**
  - Fix: a fixture or test whose first problem is another entry, with the ternary refusal on a continuation row, plus a labelled-only mutant. Also decide whether "ternary refused and another entry refused in the same row" should be RED (as now) or PROBE-BROKEN.
  - Re-run: cells on both interpreters and that mutant.
- **m4: misleading lab test; unreachable branch.**
  - Fix: rename collect:2621 to say what it tests (pft_observation on an S0 record). Add a run_lab assertion: an S0 with verdict PROBE-BROKEN and a refused PF-T gives INCOMPLETE rc 2, PF-T NOT RUN, and the failed check named.
  - Re-run: collect on both interpreters.
- **m5: design-doc drift.**
  - DESIGN.md:423 still says the S0 PF-T variant "必須 FAIL" (must FAIL).
  - :293's RED column still describes the G5 FAIL.
  - Ternary DESIGN.md:647 says "only GREEN or PROBE-BROKEN".
  - Fix: a dated "Cut A + D" note at those spots, stating that S0 now requires PASS and that any refusal naming the entry is labelled RED. Re-run: none.
- **m6: the landing head is not yet verified.**
  - Cut A r5 is still to be merged in.
  - The session's git status snapshot shows trunk at 64338970 "Merge commit '18c81892' into trunk", which suggests trunk has moved past D's base [inferred].
  - collect reads match_shape.py and S0 runs preflight.py, so r5's edits feed these suites.
  - Re-run at the final head: S0, cells and collect on both interpreters, recover, gate_scripts. Run the full GATE only if the subject sha (ea7e5536494a03ff) or the gate scripts change. Re-check the tsv line references (match_shape.py:239-319/321-335/344, api_routes.py:1006-1013, preflight.py:235-244) after r5 shifts lines.

**NIT**

- `runtime_cli.py:57`: "(G5)" is now false. Reword it to say this translator does not carry priority entries.
- Process accounting:
  - S0 starts 10 throwaway switches plus 5 drop-check switches (s0.py:628-630, 656-659, 682-688);
  - `s0_procs.log` records 7;
  - the vs_trial bmv2-fast switch and both show_ports switches are unrecorded and not explained (only the drop checks are);
  - the sampling loop forks per /proc entry, so "every second" is optimistic [inferred].
  - The "nothing left" claim stands on the post-run scan [read].
- `s0_prescan.log` has no script in the evidence, so what it scanned is not shown.
- `a.cells.log` and `a.collect.log` do not print the venv's Python version; "3.13" is unlogged.
- `s0.json` `repo.dirty_paths: 1` versus the log's tracked-dirty=0: the two counters differ (porcelain including untracked, versus tracked only). The untracked path is not named; it is probably the venv symlink [inferred].
- expected_today.tsv line 6 still calls the predictions "today's trunk (995bdfd0)".
- The 400 mapping can be marked [read], as noted in claim 3.

## Internal inconsistencies

- The SUMMARY D section says only the drop check's 5 switches went unsampled. The code and log say 3 more were missed. CONTRADICTED by its own evidence.
- The patch is described as 758 lines; the file reads as 759. Trivial.
- Everything else adds up: +4 cells tests, +3 collect tests and +10 mutants give 183/186/483 against the stated trunk 179/183/473. The trunk figures are not in the evidence [inferred].

## Tests I would have run

1. **Proxy writer on a throwaway switch.** A S0-style trial driving the proxy's own `P4RuntimeClient.write_table_entry` (package A's p4info, binding None) against throwaway simple_switch_grpc, stock and bmv2-fast, posting T4_BODY, T5_BODY, T6_BODY and T7_BODIES, then applying the T4–T7 observers' find/checks to `table_dump`. This turns T4–T7 GREEN into an observation without the lab. The alternative is M1(a).
2. classify_pft with the ternary refusal on a continuation row, plus the labelled-only mutant (m3).
3. S0 `preflight()` on a PF-T package whose t_ternary entry has no match. I expect "carries one" to be False; today it is True (m1).
4. The gate header with an uncommitted edit to match_shape.py. I expect no "+UNCOMMITTED" mark today (m2).
5. run_lab with a PROBE-BROKEN S0 whose PF-T was refused: INCOMPLETE rc 2, PF-T NOT RUN (m4).
6. A byte comparison of `preflight_pft_g5.txt` (without line 1) against `preflight_pft.txt` at 95a8972b.
7. After the r5 merge: S0, cells and collect on both interpreters, recover and gate_scripts at the final head (m6).
