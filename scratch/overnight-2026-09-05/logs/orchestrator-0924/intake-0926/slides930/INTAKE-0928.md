# 930 deck — intake of the F-list fix round (2026-09-28 01:4x +08)

- Worker delivered (nothing committed or staged; the slide repo is public). The template is now v1.1; the report says F-1..F-21 are all applied.
- The worker said the three 09-19 morning 06 runs (052518Z, 063235Z, 083257Z) were not in audit-raw.
  - Archived them, with their 161 arm-report entries, as audit-raw 5cf0364c (`copy-audit-raw-0928b.sh`, secret scan 0/3).
  - Adam010341 is public at 5cf0364c. ndtwin-lab timed out at 600 s; the retry at 02:00 went through, and both are public at 5cf0364c (unauthenticated ls-remote).
- A re-judge was launched with the F-list pasted in (the judge may not read `judge-SLIDES930.md`).
- Before 09-30, re-run: Q4 (CI), Q5 (PR state), F1 (main sha + review states), N1, and the ndt serve v2 state in the S4 table.
- Open from the worker:
  - flowcache is "no evidence" on T1 but "IPv4 only" on T7. The re-judge is asked which run T7's label rests on.
  - The archived `fig_r1.md` names ebe17f7c as the detect-only tip; the real tip is 17e40e29. The deck no longer uses it; fix it with the re-judge's list.

## Re-judge (02:4x) → READY AFTER FIXES — `judge-SLIDES930-r2.md`
- 15/21 fixed, 6 partly. Blocking: (1) the F1 tile still puts the open privilege item in a layer; (2) the flowcache label.
- I checked myself:
  - flowcache netdev in T06: s1-eth3 +4,593,189 B, s3-eth1 +273 B, so the twin read correctly. My "no evidence" ruling was wrong; the cell is now "IPv4 only" on T1 and T7, still pending Adam.
  - f9be5842^{tree} == fed37cff^{tree} == e7e61a33.
  - 58 first-parent merges since 09-16 on fed37cff; 45 name a judge in the full message, only 23 in the subject.
  - The 916 folder's `*_0927` files are untracked. Its 6 modified tracked fig_t1 files date 09-16 12:26 (pre-existing).
- The fix list (18 items: the judge's 17 plus fig_r1's tip) went to the worker. detect-only is off N1/N3 pending Adam (MORNING-QUESTIONS 10).

## Round 2 delivered (03:1x) — template v1.2
- The worker reports all 18 items done; README §7 maps them.
- I viewed F1 and T1c myself:
  - F1: the KJL tile is white with a grey hatch and sits in no layer's legend or count.
  - T1c: flowcache is orange inside the pending box, the twin count is 6/4/3, and the 09-16 row is in a background band labelled "read 09-08, trunk 1a284f75".
- A focused third judge (r3) was launched.
- Open from the worker: 7 generators have no red check (T:45 now says so); 052251Z_05 is not in audit-raw (disclosed).

## r3 judge (03:4x) → READY AFTER FIXES — `judge-SLIDES930-r3.md`
- Blocking 1–4: residual locating text near the privilege item (R:304, fig_q3.md:80, F:164, harness M11) and no neutral-placement stop. Blocking 5: the H1 footer contradicts its own raw (defect E). Blocking 6: the T1 legend for read-only cells.
- **Public audit-raw check** (judge item 13): the two `secret-scan.kjl-*.log` files hold only sha ranges and file/line counts, no paths.
  - The 31 files mentioning the function are CI/L1 logs, where one failing assertion prints the public source of p4_testbed_topo.py.
  - Nothing describes the open bug, so no action.
- The fix list plus my rulings on the open design points (all applied for consistency) went to the worker.

## Round 3 delivered (04:0x) — accepted
- I checked:
  - F §4.4 and the rows around it (no layer words near the item);
  - R:304 (cites only the unlayered row and the §4.4 heading);
  - the F1 gate r3b 17/17 and without-placement-stop 6 survived, so the stop is load-bearing;
  - the h0 footer red check 5/5, t1c 11/11, and the H1 PNG footer "RAN IT · 09-24, before the heartbeat".
- Not verifiable here: how the hatched tile looks on a projector (judge 1f), so Adam should look at it on screen.
- Last task sent: red checks for the 8 generators plus the S3 date stop, with no figure changes unless a real bug turns up.
- Before 09-30, refresh: in-review states (AEG, KJL, sudo), CI (#9 is green on clang/TSan/ASan), PR list, main sha, N1.

## Red-check harness round (04:3x) — accepted; findings sent back
- All 17 scripts are covered: 7 new harnesses, plus tutorial 68/68, engineering 129/129, and the S3 date stop 3/3. Each stops with its named reason and each control passes.
- The foreign_p4 stop was added. Its PNG is byte-identical, so it was not regenerated.
- Findings sent back to fix:
  - Q4's quiet "no record" fallback (on the deck);
  - GAP-1 §2 duplicate rows (archived t1b only);
  - unnamed crashes, to become named stops;
  - cosmetic items.
- Process: the engineering sub-agent deleted two of its own superseded logs (T2017Z, T2018Z) because of wording near the withheld block. The results were recorded in the worker's report first. From now on, logs are marked superseded, not deleted.

## Generator-findings fix round (04:5x) — accepted
- Q4's quiet fallback is now named stops. The control shows that an absent record still draws "no record".
- GAP-1 duplicate and missing rows now stop, and the unnamed crashes became named stops (grab(), l1_of(), guarded opens).
- engineering harness 153/153, tutorial 69/69, t1c 11/11. The regen check shows 14/14 PNGs byte-identical, so no figure was replaced.
- Last small items approved: t1b write_md (keep the round-3 wording, UTC stamp), and a named stop for a renamed API field.
- R:244's "kernel 層級" is about the heartbeat, not the withheld item, so no change.
- The deck is done after that. The 09-29 refresh of time-dependent states comes as a separate request.
- **05:0x Final:**
  - t1b write_md keeps the round-3 wording and a UTC stamp (the generated md now matches the disk apart from the stamp).
  - API-snapshot fields are checked at load (9 new red cases).
  - engineering 162/162, tutorial 69/69, t1c 11/11. PNGs 14/14 byte-identical; nothing regenerated in the folder.
  - Still left, recorded in R: short markdown rows and a non-integer rc in T06 raise unnamed exceptions (rc 1, no figure). They cannot draw a wrong figure, so I stopped here (diminishing returns).
  - Deck material is **done**. Generator shas: engineering 3c44f472, tutorial e6fd01ce. The worker stands down until the 09-29 refresh.

## 09-28 afternoon refresh (Adam 14:0x: "新的東西記得更新到簡報裡") — delivered 07:37Z, judge launched
- Paused for Adam's reboot at 06:59Z, resumed 15:0x +08. Template 810e5b6c, README fbde4505, FIXED db300595 (sha256/16). Nothing staged.
- Changed: Q4, Q5, F1 (37/0/2, was 32/0/4), N1 (+archive), T1, t1b archive. 56 other PNGs unchanged; sweep 70/70 byte-identical.
- Figures pinned at trunk 85bec430 + API snapshot 06:45Z with as-of stamps; proposal: re-pin once after PR #15 squashes (also serves as the 09-29 pass).
- Beyond the brief (to judge / Adam): N3 row 6 rewritten ("CI green = checked on the lab" — doubtful; CI is GitHub-hosted); FIXED §0 lists 7 judge files
  missing from audit-raw; regen-check harness F1 path fix; GAP-2b summary line 7/3/3 -> 6/4/3 (I read the diff; committed c8433963).
- Worker's f253ed08 finding: explained — test_apps_residue.sh flake (also hit PR #15 twice); worker ticket open.
- 16:0x judge (refresh) -> READY AFTER FIXES, text only. Wrong: withheld-item proximity (subsystem words near it in R/T/fig_q3 .md and the Q3/N3 tables);
  CI "09-28 起全綠" stated as standing fact (f253ed08 red inside the window; PR #15 3/4 red). Also F §0 list (6 judge files + an INTAKE, AEG judge
  probably missing), T:363 date, F1 re-check header, 1233a explanation, T:3 pin text. My rulings sent: word list = layer + subsystem nouns + aggregates;
  drop every "second instance still open" (it was fixed on the same branch, now on public trunk); never cite PR #15 by number in the deck;
  neutral-tile rule lifted only after #15 squashes and both mains sync. Q4 relabel (PR #11/#12, one "no log" key) approved.
- 17:0x re-pin delivered and ACCEPTED (I viewed F1 and Q4 myself): pinned to trunk 3368412d / main eef173a9; the #15 item is an ordinary proxy-layer
  tile; F1 39/0/1 (the 1 = residue-clock fix branch, still with its worker; the list counts every unmerged fix branch — kept); Q4 56 runs, PR #11/#12
  labels, one "no log" key, red rings on PR #15's earlier red attempts; 70/70 PNGs match; F1 harness 13/13 (neutral-tile stops removed, M10b/M11b added);
  engineering 181/181. No deck document cites intake-0926/kjl/ any more; "second instance" and follow-up hints removed.
- Accepted as is: make_engineering_figs.py still reads two kjl judge files' verdict lines (paths only in code, prints nothing). The slide repo is
  never staged, so this stays local; if the generators are ever published, strip those paths first.
- Template 3afdfe8e, README ab434562, FIXED d9887430 (sha256/16). Next: one more pass before 09-30 only if main/trunk move (residue fix, B).
- 21:2x (13:21Z) final top-up ACCEPTED (I viewed F1): second in-review tile "spawn helpers" (dfdb2121); F1 39/0/2, layers 2/6/5/28/0, merges 66;
  F1 check 13/13 (two anchors moved), regen-check-all 70/70 identical; template v1.6 50f9788b, README 2ec1d21c, FIXED 26ff3d6a.
  Known stale detail: FIXED §4.2 cites residue tip 74d1383f; the branch is now 571fa6fd (noted in §0 and README §12). Deck pinned: main eef173a9 / trunk 3368412d.
