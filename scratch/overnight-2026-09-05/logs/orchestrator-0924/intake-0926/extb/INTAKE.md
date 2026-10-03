# B: external detect-only (feat/external-detect-only-0927) — intake
- **08:0x Delivered** 17e40e29: 8 commits on f7e2a128, 20 files, +1286/−88. Merges cleanly onto trunk 149c8234.
  - The worker reports 18 gates rc 0 and tripwire 0.
  - Product diff read:
    - main.py: `declared` before `external`; an external+foreign branch seeds declared links; reroute stays external_control_plane;
    - ndt: heartbeat_wanted = foreign:*.
  - Secret scan 0/3.
- **Side-effect question:** heartbeat frames 0x88B5 now enter the exercise's own pipeline on the external arms (p4runtime ×2, flowcache solution).
  - The planned live 06 comparison vs 074635Z (external_evidence.py compare) must show no difference on those arms.
  - Known caveat: flowcache's controller died after 6 packet-ins in 074635Z (the G1 defect).
- **Judge launched** (with an explicit question on what the live run must show).
- **Live 06 plan** (after the judge):
  - from B's worktree, with NDT_OWNER set;
  - claim first and check `measuring`;
  - the topology comes from the lab tree (main checkout); ndt and the proxy come from B's tree.
- H4 (08) waits for the N-1 fix: TERM can end PASS.
- **08:2x Judge: MERGE AFTER FIXES** (`judge-EXTB-17e40e29.md`).
  - Code correct: no write path on external, and reroute stays external_control_plane.
  - The three measured programs drop 0x88B5 (read from the P4 sources).
  - The live plan was insufficient:
    - F1: an A/A run could pass vacuously;
    - F2: the baseline is not same-code and is noisy, so a same-session control is needed;
    - F4: H4 must assert reported_to_kernel.
  - Disclosure gaps: F3 (any punting or flooding external program), F5 (the twin's path table on external becomes a guess).
- **Sent** F1–F9 plus the AEG 08 follow-ups (N-1 must, N-3..N-7, N-11, extra cells) to the worker. Live comparison per the judge's §5 after that round.
- **For Adam:** should B apply to every external package on its own pipeline, or get an opt-out/opt-in? (MORNING-QUESTIONS 13)
- **11:3x Round 2 delivered** as 14921f98: merged trunk 9ef10250, then 6 commits.
  - External judge F1–F9 addressed, plus the AEG N-1 (TERM'd 08 cannot PASS), N-3..N-7 and N-11, and the extra cells.
  - extb2: 19 gates rc 0 per the worker; tripwire 0.
  - F3 disclosed with no opt-out (waiting for Adam's Q13).
- **Focused re-judge launched.** Then the live comparison per the README procedure (C1/C2 without the heartbeat on trunk, T on B, compare with --control2/--samples).
- **12:0x Round-2 re-judge: MERGE AFTER FIXES** (`judge-EXTB-14921f98.md`).
  - M1: the live procedure is not executable (T can't run from B's worktree without root re-pointing the lab).
  - M2: compare can still be fooled (the pre-pipeline markers, a stale "running").
  - M3: N-1 ends rc 1, not 143; plus the _common.sh window.
- **Sent** M1–M3, S1–S4 and m1–m4. Procedure plan (a) is proposed to Adam as Q15.

## 14:5x — round 3 PARTIAL at 480e9f2e (stopped for Adam's reboot)
- Worker stopped its driver at 14:48: 19/23 gates rc 0 (logs gates-0910/*.extb3-480e9f2e.log); left: mutate_app_package, mutate_ndt_app_package,
  check_gate_anchors, nolab_tripwire (script gates_b3r.sh, TAG extb3r, ~2.5 h). mutate_roles_binding stopped at mutation 54 (not a result).
- Self-found gap: 11 evidence-gate cells never seen red; E50-E60 added; the gate now reports coverage (103/103) and its coverage report was seen red.
- Scratchpad is wiped on reboot; the worker copied its driver/red-first/frozen/shims to logs/gates-0910/worker-extb-0928/ (copy back first).
- Round 4 plan (Adam 14:2x "fix both"): SUMMARY §R3.9-§R3.10. Offline check = throwaway bmv2 --use-files, no controller, no entries; all _out.pcap empty.
- Worker's two questions, my rulings (send on resume):
  1. 5 new /home/adam/... lines in the README procedure: keep. doc/audit .md never reaches main; trunk already carries the same path in 525 files.
  2. A throwaway `simple_switch --use-files` in a gate is not "touching the lab", on conditions: no root; its own TMPDIR for ipc and pcaps;
     a thrift port proven free right before start and outside the lab's ports; device-id unique; killed by exact pid in a trap, never by name;
     logged in the tripwire as an allowed launch; and the product-side check (at `ndt up`) must not be counted or reaped by ndt's orphan/by-name
     logic, nor collide with the fabric it is about to bring up -- test that.

## 18:1x — stopped for Adam's budget
- Round 3 DELIVERED 480e9f2e (all 23 gates rc 0 + tripwire 0 lab calls).
- Round 4 implemented and committed, head faf6eb41 (trunk 3368412d merged, no conflicts): 03bb1880 (external: no guessed destination paths),
  1ece97ab/ec04eb95/89615935 (heartbeat only after an offline bmv2 drop check). extb4: 21 gates rc 0 (redfirst_b4 ALL-AS-EXPECTED,
  mutate_p4_heartbeat_w 256/0); 5 left: gates_b4r.sh (TAG extb4r). Then judge round 4, then the live comparison (procedure a).

## 2026-10-01 — round 4 DELIVERED at faf6eb41
- The last 5 gates ran after the reboot (sonnet-worker; frozen gates_b4r.sh sha256 ef8d41d5…, TAG extb4r, logs
  logs/gates-0910/<gate>.extb4r-faf6eb41.log, each first line faf6eb41, last line `# rc=0`; driver ALL-AS-EXPECTED):
  mutate_app_package 48/0; mutate_ndt_app_package 77/0 (M28, M28b caught on named checks); mutate_heartbeat_drop_check 39/0,
  61/61 non-control checks seen red; check_gate_anchors 128/128; nolab_tripwire 0 lab calls, 1585 allowed launches, 0 left.
  With the 21 extb4 gates, all 26 rc 0. Spot-checked: script diff = path, tag, cp name, 22 run lines removed.
- `git merge-tree --write-tree d452d111 faf6eb41`: clean, tree 62979b4d. Merging trunk changes the tree => full rerun after.
- Next: round-4 review, then merge trunk + rerun, then the live comparison (procedure a), which needs Adam's lab authorisation
  in this session.
- **Review of rounds 3–4 (opus-judge): MERGE AFTER FIXES**, extb/judge-EXTB-faf6eb41.md. Product code (a) and (b) sound and seen red;
  27 gates (22 + 5, not 26) sound for faf6eb41. Blocking: M-1 OLD_06=<C1> (4 arms) makes every T run print an H5 FAIL; M-2 the local
  merge in the shared main checkout is unprotected; M-3 treatment can be vacuous (frames heard never checked); M-4 drop-check mutants
  D16/D16b/D17/D18 launched 64 switches outside the ruling's conditions and the tripwire cannot see it; M-5 merge trunk + rerun.
  Plus S-1..S-9 (counts, LIMITS, the S1 sentence, checker hardening, per-arm log, end-to-end ndt cell, D10, l1 runner, 2/5 false-fail).
- My rulings for round 5: M-4 confirmed (the tripwire enforces every condition; mutants assert on argv, no launch). /home/adam: the
  fixture README prose -> `~/`; p4c JSON stays verbatim (precedent tools/p4_exercise/tests/fixtures on main). M-2: I freeze trunk pushes
  for the live window; rollback must be `git reset --keep`, never --hard (the main checkout carries others' uncommitted files).
  S-9: pre-register a decision rule with a stated no-effect false-fail rate before any live data. Fix-over-disclose: S-1..S-9 this round.
  Live run waits for Adam's lab authorisation in this session.
- 2026-10-02 round 5 DELIVERED 4c18bf3d (merged trunk 1e350bf2; 11 own commits). 39 gates rc 0 (extb5c), tripwire over 4 drivers:
  0 lab calls, 0 condition breaks. Report extb/REPORT-r5-4c18bf3d.handback.txt; §R5 appended to the SUMMARY. Scan 0; own commit
  messages clean (hits only in merged trunk commits). Live-run command list in the report; needs Adam's lab authorisation.
  Cleanup by me: two orphaned until-loops of the worker (pids 60601, 244567, waiting forever on dev-hbw.out) killed by pid; the four
  D21 dirs and /tmp/bmv2-951150-notifications.ipc removed. Scoped re-review sent to the same judge.
- **Re-review r5 (same judge): MERGE AFTER FIXES, not yet ready for live** (extb/judge-EXTB-4c18bf3d-r5.md). Must, before any live data:
  (1) procedure order (H1–H4 under the local merge, before push/rollback), ancestor pre-check, HEAD==T pre-check before reset --keep,
  pre-registered outcomes for merge refusal / identity refusal by someone else's edit / rerun rc 1 on another field, rc 2, rc 3;
  (2) identity: ~/tutorials, bmv2 libs, compiled-JSON and p4c sha equal across arms, C identity before and after, T tree vs merge-tree;
  (3) heard rule: window from pipeline push/first entry to last write, ≥1 round per direction, too-short lifetime = UNDECIDED rc 2,
  real-cadence fixture; (4) S-9: freeze the 34 survey inputs (paths+sha, no-heartbeat check), state the family-wise bound (~52% by
  the README's own per-check bounds) and what a PASS does not show.
- My rulings for round 6:
  - Freeze: trunk commits, merges and pushes are frozen for the live window (I announce it). The uncommitted comparison is narrowed to
    code paths: exclude doc/**/*.md and doc/audit/**/*.tsv; everything else tracked is compared.
  - S-9 accepted as an orchestrator ruling, with disclosure: decisive fields varied 0 times in 34 rounds; the ~52% family-wise figure is
    a conservative sum of per-check 95% upper bounds, not an estimate; a FAIL costs a documented investigation (one pre-registered T
    rerun), never a silent reject or repeated reruns. README states the point estimate, the bound, the demoted fields and the p² power.
    Adam may override.
  - S-8: l1 launching throwaway switches on the lab machine is covered by the 09-28 ruling 2, enforced by the in-process guard; and the
    suite must declare-skip when the lab is claimed by someone else or a measurement is declared (read the claim file), so it never
    adds switches during a measurement.
  - Before the final gate run, merge the then-current trunk (GUI v2 is about to move ndt) and re-check trunk right before the driver.
  Sent to the round-5 worker (same agent) as round 6.
- 2026-10-02 16:4x round 6 DELIVERED 5311f3f6 (merge of trunk 67ec9f9e onto 1cf0692c; tree 2f6f20bc == merge-tree, checked by me).
  extb6m 44 gates rc 0, driver "ALL-AS-EXPECTED", trunk 67ec9f9e throughout; I checked all 44 logs: first line 5311f3f60add,
  last line "# rc=0". Tripwire 0 lab calls. Own commits 4c18bf3d..1cf0692c: scan 0 (control 3), messages clean. The first run
  (extb6 on 1cf0692c) was stopped by the worker when trunk moved and is not counted. Report REPORT-r6-5311f3f6.handback.txt,
  §R6 in the SUMMARY (line 933). Diff diff-r6-4c18bf3d..1cf0692c.patch. Scoped re-review sent to the same judge (a562cf66).
  Adam authorised B live (RULINGS-1001 form 8); it starts only after this re-review says MERGE.
- **Re-review r6 (same judge a562cf66): MERGE AFTER FIXES, README-only** (judge-EXTB-5311f3f6-r6.md). Musts 1–4 and S-8 met; 44 gates
  and seen-red SUPPORTED. Blocking, all in live-p1/README.md: F1 step-6 rollback (reset --keep refusal not registered + wrong message;
  target must be $T_MERGE^1 not $C_HEAD; step 7 unfreezes unconditionally); F2 step-2 STOP has no outcome (pre-merge HEAD==C_HEAD);
  F3 rc 3 on the first compare has no cap; F4 shell vars lost between agent calls (empty C_HEAD makes reset a silent no-op).
  N1–N6 operational; N6 = GUI v2 tests + ndt_serve mutate gates on the merged head before any PASS push.
- My rulings for round 7: F1–F4 as the judge wrote them; N1–N4 into the README; N6 run now (no lab). Commit the README fix on the
  branch (new B head; diff vs 5311f3f6 must be README.md only, so the 44 gates stand). Rehearse steps 0/2/6 in a separate throwaway
  clone (never a worktree of $M: a reset there would move the real trunk), old text red / new text green; code_identity pre-flight
  twice. No further judge round unless decision rules change (judge's own condition); I read the README diff myself.
  Live starts on my GO after that, within form 8 (one run; ~1–2 h of lab). Worker estimates the live wall time first.
- 2026-10-02 18:0x round 7 DELIVERED 9054d0c4 (README-only, +140/-35; I read the whole diff: F1–F4 as the judge wrote them, plus
  a staged-changes branch and an "already at C_HEAD" branch in step 6, both justified by the rehearsal). Rehearsal in throwaway
  clones: cases A–D old text wrong / new text right (logs/gates-0910/extb7-rehearsal.log). Identity pre-flight: unchanged_reasons
  empty. Wall time inferred ~1.7 h for one clean run (06 ≈ 27 min each); any rerun path 2.2–3.2 h ⇒ ask Adam before a rerun.
  N6 found a real blocker for the push, not for live: on B's merged head test_ndt_serve.py 75 run / 2 failed (RcProvenance line
  citations into ndt; B moved ndt 11110 → 11227 lines), so mutate_ndt_serve refuses (rc 2). Trunk 67ec9f9e passes 75 OK.
- My ruling: fix the GUI citations ON B before live (one commit, GUI files only), so the live T is exactly the tree that will be
  pushed; rerun the GUI suites and gates plus B's ndt_status_measuring / anchors gates on that head. Then live on the new B_SHA.
  Live operator: a fresh opus-worker running the README procedure as written (also a test that the README is operator-runnable);
  I do step 0's freeze announcement and step 2's merge myself.
- 2026-10-02 19:1x GUI citation fix DELIVERED 9b5c0607 (6 GUI files only; RcProvenance red on 9054d0c4 / green here; GUI suites
  75/35/39/18 on 3.12+3.8, mutate_ndt_serve 198/0 both, page 32, page gate 58/0+3, anchors 131/131, measuring 102 + 19/0; scan 0).
  I checked every extb8 log's first line (9b5c0607) and last line (# rc=0), and three of the new ndt line targets by reading them.
- 19:17 FREEZE ANNOUNCED (to Adam in chat): trunk no commit/merge/push, $M no staging and no edits to B's files, no figure
  regeneration, no lab claims by others, no gate drivers, until step 7. B_SHA = 9b5c06078d367b67d95521361da651e50ae08794.
  Pre-state: $M on trunk 67ec9f9e, nothing staged, 11 tracked files modified by others (none in B's list per the r7 pre-flight),
  lab "measuring nothing", no gate processes. Live operator: fresh opus-worker, NDT_OWNER=extb-live; I do step 2.
- 20:1x live step 1 done (operator a852d513, NDT_OWNER extb-live): C1 2026-10-02T111831Z_06_thirteen and C2 ...T114559Z_06_thirteen,
  both 06 rc 0 (26 arms, same table), both identity checks "did not change", C1/C2 identities equal, no STOP. Pre-state in
  scratch/live-extb-pre/status-before.txt (no claim, measuring nothing). Adam lifted the time window (RULINGS form 8 addendum).
- 20:1x step 2 by me, README block verbatim: MERGED, T_MERGE=acd84fdcdd4b447da25f7a14fedfb627a1cb46e9 (local, not pushed;
  50 files = B's list; nothing staged). Steps 3–5 sent to the operator; it hands back after the compare, no rollback/rerun.
- Noted, not mine: pid 2981250 (child of claude pid 10087, xhigh, up 33 h) has looped 27 h on `until ! pgrep -x chrome ...`;
  it never ends while Adam's Chrome is open. Read-only waiter; left alone.
- 20:5x live steps 3–5 (operator): T = 2026-10-02T121504Z_06_thirteen, H5 = ...T121502Z_08_heartbeat (08 h5 rc 0: SAME CODE APART
  FROM B; 26 arms identical to C1; heartbeat on exactly the 20 expected arms; 01 PASS). H1–H4 = ...T124313Z_08_heartbeat, rc 0
  (H1 6/6 within 20 s; H3 16.6 s; H4 both directions reported_to_kernel True; writes 409; ruling-4 counts 0).
  **Step 5 compare: rc 2 UNREADABLE, no verdict.** First problem: C1's p4runtime_solution controller log, "last counter block had
  not settled ... s1 ingress 100 = 3504 is not yet every packet the round sent (3505)". `show` gives the same reason on C2 and T;
  the final block is byte-identical in all three (3504 / 4346248 B both directions; 200: 6). iperf "Sent 3500", 5 pings.
  Operator's inference, unverified: the expected-count rule is off by one, so the registered "rerun that run once" repeats.
- 20:5x step 6 by me, README block verbatim: ROLLED-BACK (HEAD = C_HEAD 67ec9f9e, nothing staged); identity after rollback equals
  C1's after (unchanged_reasons empty). Lab vs pre-state: claim none, 0 switches, ports closed, no apps, measuring nothing; only
  differences are the heartbeat report (stopped by SIGTERM, as 08 leaves it) and kernel.exit. Step 7: freeze lifted 20:5x; vars
  moved to $T/00_procedure.vars. Raw: six untracked run dirs under $M live-p1/runs/2026-10-02T1[12]* (to archive to audit-raw).
- Outcome under form 8: one run of the procedure done, no verdict. A further live run needs Adam. Next: read-only investigation of
  the 3504/3505 rule against pre-existing rounds (the 34 survey rounds, earlier live-p1 runs) before any tool change; changing a
  rule after it blocked us needs its reason shown on pre-existing data only (memory prereg-amendment-before-data).
- 21:1x investigation (read-only, INVESTIGATE-unreadable-1002.handback.txt): diagnosis (a), a reader bug, nothing changed today.
  settled() (EE:344-357, from a8d11f02, round 3) wants s1 ingress 100 == pings + iperf "Sent" exactly. iperf 2.1.9's "Sent 3500"
  is one more than the datagrams on the wire: server reports 0/3499 in 8/8 acked rounds; s1 bytes = 5x98 + 3499x1242 exactly.
  On the 12 frozen p4runtime/solution rounds the current rule reads 11 UNREADABLE; the one that settled (09-27T081205Z, the rule's
  only real-data check) had a FIN retransmission. The survey never called settled(); it had found the same sum held 1/12 and made
  the invariant descriptive, but the gate kept it exact. Rerun path would almost surely repeat. I checked EE:333-357 and one old
  round's iperf files (Sent 3500 / 0/3499) myself.
  Proposed rule (from the 12 frozen rounds only): repeat of the previous block, OR (acked AND s2e == s1 AND pings+Total <= s1 <=
  pings+Total+10). Settles the 7 after-traffic rounds, still rejects 175425Z (really mid-traffic) and the 4 failed 09-19 rounds.
  Today's decision fields remain unseen (compare stopped at the first Unreadable; investigator masked them).
- My ruling: fix the reader on B now (both paths need it): real-data cells from the frozen rounds, seen red on the current rule,
  scoped re-review. Path after that is Adam's (form 9): fresh live run with the fixed rule registered first (recommended), or
  re-compare today's data with the fixed reader.
- Adam form 9: fresh live run after the fix (recommended option). Today's data is not re-compared. Fix worker a18e2585 running.
- 22:3x settled() fix DELIVERED 75b5dd0e (EE, TS, MG only; +462/-37; scan 0; message clean). Real-data cells from the 12 frozen
  rounds (today's three not used). Red on 9b5c0607's EE: 232 checks / 21 failed (redfirst_b9:287); new head 232/0; MG 134/0,
  232/232 seen red (E21 survived on a first commit d08713cc, fixed by moving t_trunc to the skeleton arm; d08713cc logs void).
  Survey body unchanged; anchors 131/131. New settled() on the 12 frozen rounds = the investigator's proposed.out one for one.
  I checked every extb9 log's first/last line and the four key count lines. Scoped re-review sent to the same judge (a562cf66).
- **Re-review r8 (same judge): MERGE AFTER FIXES, README-only** (judge-EXTB-75b5dd0e-r8.md). Code correct and meets the amendment
  bar (real.txt verbatim vs all 12 rounds, no 10-02 data; no parameter settable from 10-02). Blocking: F1 README:681-684 still says
  no live data exists, register the 10-02 run + Adam's form 9 + the amendment; F2 exclude 10-02 raw dirs from the fresh run (START
  stamp in $V; "沿用" at :541/:631 must not reach them); F3 register the outcome if the fresh compare hits another reader defect.
  Not blocking: N1 +10 disclosure (probably +9 max); N2 per-arm unreadability later; N3 lost count in the message; N4 Sent-based
  invariant note; N5 pin EE sha256 at step 0, record at step 5; N6 survey manifest lacks iperf_client hash. Expected: ~1 in 3 that
  some run needs its one registered rerun.
- My rulings for round 8b: F1–F3 plus N1, N4, N5 as README text, one commit. F3's registered outcome = the 10-02 precedent: stop,
  report to Adam, no re-compare under a changed reader. Approved the judge's test 1 as a readiness check on the 10-02 data: run only
  the compare stages that never ran live (programs_same, read_samples, check_roles/heard window, settled on every arm), print stage
  + pass/fail (+ the readability reason on a fail), never call the decisive-field comparison. This is not a compare of C vs T and
  gives no verdict (consistent with form 9). Also rerun redfirst_b..b6 on the new head before any push. N2/N3/N6 later.
- 22:4x round 8b DELIVERED bcdeca0e (README only, +57/-10; I read the whole diff: F1 round-8 entry, F2 START stamp + recovery
  and "沿用" limited to this run, F3 reader-defect outcome verbatim, N1/N4/N5 incl. EE sha256 69bccf77 pinned at step 0 and
  re-checked at step 5; scan 0; message clean). Readiness on 10-02 data: 0 FAIL, decisive comparison not called. redfirst_b..b6
  ALL-AS-EXPECTED on bcdeca0e; tripwire 0 lab calls. EE sha on disk = 69bccf77 (checked).
- 22:4x pre-check for the fresh run: $M trunk 67ec9f9e, nothing staged, no edits to B's 50 files, lab measuring nothing, no gate
  processes, 2638 MB free; B's file list vs 67ec9f9e unchanged. 10-02 leftovers C1/C2.before.json moved out of scratch/live-extb/
  to scratch/live-extb-pre/1002-leftovers/. FRESH RUN (form 9): B_SHA = bcdeca0e3c025c93005c2c0963981b705cca8cdc, same operator
  (a852d513), NDT_OWNER extb-live; freeze announced now.
- 23:4x fresh run step 1 (operator): START=2026-10-02T144937Z, EE_SHA 69bccf77 (no STOP); C1 2026-10-02T144952Z_06_thirteen and
  C2 ...T151709Z_06_thirteen, both 06 rc 0 (26 arms), identity checks pass, C1/C2 identities equal, both newer than START.
- 23:4x step 2 by me, README block verbatim: MERGED, T_MERGE=995bdfd0b7f2a81a357a480551ff82df4f6fc9b4 (local, not pushed;
  nothing staged). Steps 3–5 sent to the operator.
- 00:19 fresh run steps 3–5 (operator): T = 2026-10-02T154517Z_06_thirteen, H5 = ...T154516Z_08_heartbeat (08 h5 rc 0; SAME CODE
  APART FROM B; heartbeat on exactly the 20 expected arms; 01 PASS). H1–H4 = ...T161244Z_08_heartbeat, rc 0, all OK (H1 6/6 within
  20 s, H3 16.54 s, H4 both directions reported_to_kernel True, writes 409, ruling-4 counts 0; the 7 "FAIL" matches are the
  "past 35 s a FAIL" descriptor text, checked). Step 5: START and reader-sha checks passed; **compare rc 0, "NO DIFFERENCE in the
  external arms' own evidence (2 controls)"** (scratch/live-extb-pre/compare-2.out). Under "判定": H5 OK, H1–H4 pass, no reader
  defect, compare rc 0 ⇒ **PASS**.
- 00:2x PASS push by me. Scan 67ec9f9e..995bdfd0: 0 hits, control 3, 0 binaries. Messages: two old-wording hits left as they are
  (45ca199e body "H4 judges the restore", 09-28; b01ad9b9 "Merge fix/rulings-aeg-0927 ...", 09-28) because rewriting 54 commits
  would replace the tested T_MERGE; public trunk already carries 711 such messages; the squash message will be clean.
  Pushed 995bdfd0 to Adam010341 and ndtwin-lab trunk; both verified unauthenticated (push-extb-995bdfd0-1003.log). Step 7 done:
  freeze lifted, vars moved to $T/00_procedure.vars. Lab after: claim none, measuring nothing, 0 switches, ports closed.
- PR tree 27eef08d = main 0965ccaa + trunk's non-md changes (49 files; 7 audit md reset; non-md diff vs trunk identical).
  CI prediction being written (sonnet) before the PR push.
- 00:3x CI prediction written before the PR push (ci-prediction-pr25.txt, sonnet; I checked baseline :7056 = 191 and the new L1
  glob at l1_unit_tests.sh:591). Headlines: 8/8 green; drop-check suite DECLARED SKIP in CI (no simple_switch); external_evidence
  232; common 220; thirteen 47; shell_scoring 162; app_package 404; ndt_heartbeat 91; heartbeat_fabric 46; anchors 131; GCC
  ~23-25 min of 30.
- PR commit d00276bf (tree 27eef08d, parent main 0965ccaa; scan 0) pushed to Adam010341 pr/external-detect-only; PR #25
  "proxy, ndt: detect link cuts on external control planes" opened and bound (push-pr25-1003.log). 8 checks pending.
- 2026-10-03 13:3x PR #25 CI (finished 01:00; I noticed only at 13:2x — see memory): 8/8 green, every predicted item MATCH except GCC
  wall time 22m45s/22m57s (predicted 23–25) and two small per-suite timing edges; 7a NOTE not visible in CI output. Spot-checked by me
  (ctest, anchors 131, external_evidence 232, drop-check DECLARED SKIP, 4 skipped, L1 passed, 0 FAILED). ci-compare-pr25.txt.
  Squashed as 9d5ebd06 (parent 0965ccaa, tree = PR tree 27eef08d, invariant vs trunk 0); ndtwin-lab main fast-forwarded; both repos
  main 9d5ebd06, trunk 995bdfd0, verified unauthenticated (push-pr25-1003.log). **B is done.**
