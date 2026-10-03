# JUDGE: 930 deck re-review

**Verdict: READY AFTER FIXES.** 15 of 21 items are fixed and 6 are partly fixed. Two things still block. First, the F1 canvas still tells the audience which layer holds the open privilege bug. Second, the new T1 flowcache label is contradicted by the raw it cites and disagrees with T7. Both are small edits and neither needs a new run.

**How I worked.** Read-only; nothing executed, no git.
- I read the whole template, README and FIXED-SINCE-916, and looked at all 30 on-deck PNGs.
- I read the .md and generator for T1, T7, M1, D1, Q2 and F1, plus the raw they cite. Other .md files I only grepped.
- For F-1 I grepped only the verdict lines of the judge files that fig_q2.md lists.
- I did not open judge-SLIDES930.md. I did not open the uncited INCIDENT file that sits next to the H5 log.

**Path roots used below:**
- D = `/home/adam/Desktop/NDTwin slide material/NDTwin slide material 930`
- T = D/NDTwin-slide-template-930.md, R = D/README-930.md, F = D/FIXED-SINCE-916.md
- K = `/home/adam/Desktop/NDTwin-Kernel`
- E = K/doc/audit/2026-09-04_p4-tutorial-exercise-prep
- FC = E/runs/2026-09-27T081256Z_flowcache_solution_ndtwin
- S = K/scratch/overnight-2026-09-05/logs/slides930
- AR = K/scratch/overnight-2026-09-05/wt-audit-raw

## 1. The F-items

| F | Status | Evidence |
|---|---|---|
| F-1 | FIXED | See the note below this table. |
| F-2 | PARTLY | Fixed: the 13×16 matrix is gone (T:118); READ and RAN panels have titles; the 4 pending cells have dashed boxes (T:125); flowcache is no longer green. Not fixed: see the note below. |
| F-3 | PARTLY | Fixed: the generic phrase is used everywhere (T:40, :305, :311, :331, :365; F:146; R:232). main is f9be5842 (F:221; D/figures/engineering/_net/pulls_Adam010341.json:39-40). sudo d57f90f1 is MERGE AFTER FIXES (F:152; I confirmed the verdict at line :3). The KJL judge files are cited directly (F:146; I confirmed :14 and :3). The "live or CI first" overclaim is gone (T:330, F:123-124). **Not fixed:** D/figures/fixed-since-916/fig_f1_fixed_since_916.md:50 defines tile fill as "the layer where the defect sits". The "rulings KJL" tile carries a layer fill whose legend entry names a subsystem, and F:142 (section heading) plus F:59 (layer count) file it there. That is a Rule 6 violation. R:285's claim that the rows were rewritten so they no longer point to a location (「相關列改寫不指位置」) is CONTRADICTED. |
| F-4 | FIXED | D1 canvas now has the grey band "BEFORE 09-16 · BACKGROUND", the dates 09-03 and 08-24, and grey "yes". Minor: the band also covers the READ cells, which were read at trunk 3d740be0 (D/figures/flow-api/fig_d1_flow_api_matrix.md:33). fig_d1.md:44 still describes audit-raw coverage the old way. |
| F-5 | FIXED | R1 is a table (T:169-174). "07, twice" holds: both E/live-p1/runs/2026-09-24T160256Z_07_roles_basic/21_proxy_roles_lines.txt:2 and …/2026-09-26T202055Z…/21_proxy_roles_lines.txt:2 say "16 of 16", and both 12_preflight_basic_roles.txt:29 say PASS. The refusal is offline-only, the "derivable" half sits under "not done yet", and ④ says "basic only". |
| F-6 | PARTLY | T06 and FC are present in AR. GAP-2b is not in AR and not committed (T:28; D/figures/p4-tutorials/fig_t9_custom_headers.md:24), and no hash of it is recorded. T1, T7 and N3 rest on it. |
| F-7 | FIXED | A2: hollow grey square labelled "not run", drawn below 0. |
| F-8 | FIXED | T5 has no kicker, verdict or caption; "rc 1" appears only in the notes (T:150). |
| F-9 | FIXED | Checked against raw: E/live-p1/runs/2026-09-26T152605Z_08_heartbeat/30_cycles.tsv gives detect 12.204–16.827 and ψ 1.493–1.755; 64_cycle.tsv:2 gives φ 0.017, 16.607 and ψ 1.474. Spike runs K/doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T{023021Z,052148Z}_S_heartbeat/20_cycles.tsv: 18 cuts at 14.197–14.382, plus 13.275 and 13.298. The de-phased runs give 10.077–14.904 and 10.668–14.791. The inset labels match. |
| F-10 | FIXED | Canvas says "17 heartbeat sessions"; T:231 discloses there is no live positive control. In 50_samples.tsv: 1645 data rows, 1063 "running", no row with a non-zero `forwarded_to_hosts`. I could not count the distinct sessions (17) myself. |
| F-11 | FIXED | D/figures/ndt-serve/fig_s1_serve_path.md:39, :54; T:248. |
| F-12 | FIXED | S3 canvas reads "4 (+4 fixture gap)". |
| F-13 | FIXED | S4 and Q3 are tables (T:266-270, :303-309); the card figures are archive-only (T:419). |
| F-14 | FIXED | No pps pair anywhere in D. The raw checks out: K/doc/audit/2026-09-19_telemetry-three-groups/raw/2026-09-19T130352Z_G2/G2/cooperative_f64_a.log :8 (0.2532%, clean=yes), :15, :17 (0.5276%), :18 (kernel sha). …/2026-09-19T115737Z_full/summary.json:1946-1960 gives band top 0.2853, median 0.2953, position "above". The hollow point and band-top label are drawn. Minor points are in §3. |
| F-15 | FIXED | Q1's CI step is red, with legend "CI red (same 12 groups)". |
| F-16 | PARTLY | Canvases are fine (R4 shows "· dirty"). The notes still give bare run shas at T:112 (dfb9d0d7, cbc968d8, 7242e127, 1ea07e7b, f3b6d09c) and T:114 (580767a8, cafd518a, 3f8c2abf, 5dc7fc9a), which T:31 forbids. fig_d1.md:29 gives the 08-24 run as bare `e89fd4b`. |
| F-17 | FIXED | 219 files, 17 .py, 34 figure .md, 34 `_hires`, no `__pycache__`. |
| F-18 | FIXED | Every +08 left in D is a quoted raw value with its UTC conversion. Only code comments still say 09-28 (D/figures/p4-tutorials/make_coverage_0930.py:3, :14, :96). |
| F-19 | FIXED in text | R:196-197, T:295, fig_q2.md:81-83. The Q2 canvas itself is still unlabelled (§3, item 7). |
| F-20 | FIXED | Scripts and logs are in S (git-ignored, not in AR). The o1-o2-t6-t9 log was produced from a /tmp scratchpad copy (run_mutations.log:4, :10, :14), but the archived script now resolves its own directory (run_mutations.py:5). |
| F-21 | FIXED | T3 shows four name-only boxes. |

**F-1 detail.** My own tally over the 38 files gives 23 MERGE; 20 MERGE AFTER FIXES + 3 READY AFTER FIXES; 2 READY FOR ADAM'S DECISION + 1 other (judge-REQ…:12). That is 49, line for line equal to fig_q2_review_path.md:44-77. There are 40 judge-*.md files in total, and the two past the cutoff are the ones fig_q2.md:19 names. The snapshot is one: fed37cff plus mtime ≤ 15:55Z. The 58 merges agree with F:67 (32+20+6 rows); I could not verify the 45.

**F-2 residuals.**
- The flowcache replacement label is contradicted by its own raw (§3, item 1).
- The "NDTwin 09-16" row is cell for cell the "NDTwin today" row of 916 page 3 (I checked K/../NDTWIN slide material 916/NDTwin_deck_916.pdf page 3). It is drawn full-colour as "READ THE CODE · 09-16". But the reading behind it is GAP-2 of **09-08** at trunk 1a284f75 (E/GAP-2b-ndtwin-p4-capabilities-2026-09-27.md:6, :109). It is not given the deck's own background treatment (T:13).
- The "RAN IT · 09-27" panel holds 2 read-only cells and 2 judgement cells. The other 14 only "include" ran evidence (fig_t1c.md:37).

## 2. Rule 1, all 36 pages

No page has a paragraph or a real bullet list.

| Pages | Form | Result |
|---|---|---|
| A0 | title | Title only (the deck's declared exception, same as 916) |
| A1, A2, T1–T7 | figure | OK |
| R1 | table | OK |
| R2, R4 | figure | OK |
| R3 | figure | OK. Borderline: "recorded, not asserted" is a caveat on the canvas. |
| H1 | figure | Borderline: the footer sentence "skipped on a foreign fabric: …" reads like a caption. |
| H2–H6, D1, D2, S1–S3 | figure | OK |
| S4 | table | OK |
| M1 | figure | OK |
| Q1 | figure | Borderline: each step has a column of dot-prefixed result lines. They read as bullet lists even though the dots are coded in the legend. |
| Q2, Q4, Q5, F1 | figure | OK |
| Q3 | table | OK |
| N1 | figure | OK. The state words under the boxes are chip-like but factual. |
| N2, N3 | table | OK |

## 3. New problems and inconsistencies

**1. (Blocking) The flowcache twin cell.**

*(a) Which run T7's label rests on:* T06, arm FC.md:591 (a plain `iperf -u -b 2M`) and FC.md:604 (`LINK_USAGE … rc=0`), per fig_t9_custom_headers.md:22.

*Is the date on the canvas?* Only through the left panel, "RAN IT · 09-27". The right panel says "SAME RUNS' RAW · JUDGED", and T06 is not named on T7.

*Does the raw support T7's label?* Yes, under T7's own definition (fig_t9 .md:62). FC.md:592-593 shows the twin integrated 31,787,577.5 bit on s1-eth3, the only interface that moved bytes (4,593,189 B). Lines 595-602 show 0.000 on the other eight, which matches ground truth: s3-eth1 moved only 273 B (FC/link_usage/netdev.before:3 against netdev.after:3). The flow was never delivered: FC/link_usage/iperf_server.txt has no report, and iperf_client.txt:10 shows no final ack. T7's .md discloses this (:32, :69).

*T1's "no evidence" is CONTRADICTED by the same lines:*
- The s3 zeros that T:124 cites are the twin reading correctly; they are not a twin failure.
- T1's own legend defines "no evidence" as "G1 NOT RUN … and no other raw" (D/figures/p4-tutorials/fig_t1b_requirements_matrix_0927.md:63). Flowcache's G1 ran.
- T1 draws multicast green with the same evidence shape: one primary link, zeros elsewhere (E/runs/2026-09-27T075305Z_multicast_solution_ndtwin.md:491-498).
- GAP-2b reads these same lines as the twin following the bytes (GAP-2b:206, :221).
- Q3's own note says it is not the twin's fault (T:313).
- The generator docstring says the flow "never left s1" (make_coverage_0930.py:13). netdev shows 4,593,189 B leaving s1 on s1-eth3, which is a switch link.
- fig_t1c.md:20 says the change makes T1 consistent with T7 (「與 T7 一致」). That is false.
- T:124 and fig_t1c.md:39 say GAP-2b's green used the 09-26 run's raw. In fact GAP-2b cites T06 flowcache/sol:588-604 first.

*Unify them?* Yes: same run, same raw, same exercise. The label the evidence supports is T7's "IPv4 only" (orange) on both pages, keeping T1's dashed pending box. T1's twin count becomes 6/4/3. Both pages' notes should say: "T06 reached s1→s3 only; not delivered." If Adam instead wants a G1 PASS without delivery to count as void, give it its own legend entry on both pages. Do not call it "no evidence".

*(b) Is 6/3/4 vs GAP-2b's 7/3/3 explained where the viewer sees it?* No, only in the notes (T:123-124, fig_t1c.md:38-39, R:108). By Rule 4 that is the right place, and GAP-2b is never on a canvas. But that explanation misstates GAP-2b's basis. And what the viewer does see — flowcache hatched on T1 and orange on T7, both from the same run — is explained on neither canvas.

**2. (Blocking) The layer attribution of the privilege bug.** See F-3 above.

**3. audit-raw statements are out of date.** The three 09-19 morning 06 runs and all their arm reports are now in AR: AR/doc/audit/…/live-p1/runs/2026-09-19T{052518Z,063235Z,083257Z}_06_thirteen and runs/2026-09-19T05*/06*/08*. T:27, T:112, T:132, R:91 and F:45 still say they are not. I did not check whether the containing commit is public.

**4. Q3 row 3 "caught by: live run" is CONTRADICTED.** That live run reported PASS (E/live-p1/runs/2026-09-27T074635Z_06_thirteen/00_table.tsv:27). The table's own source says it was caught by reading the raw and written down in GAP-2b:239 (D/figures/engineering/fig_q3_review_catches.md:42-43).

**5. N3's flowcache evidence is UNDER-EVIDENCED.** "0 datagrams reached h3" cites only iperf_client.txt :10 (T:362; changed per R:287). That line shows a missing final ack, not zero delivered datagrams. It needs netdev (s3-eth1 +273 B) and iperf_server.txt, as fig_q3 .md:65 already does.

**6. The T1 "09-16" row is misdated** (see F-2 residuals).

**7. Q2 has two gaps.**
- The canvas mixes READ counts (49/58/45) with RAN example figures (103/103, 183/183, 1658 OK, L1 14→15) without READ/RAN labels, contrary to T:23.
- The count covers only `logs/**/judge-*.md` (fig_q2.md:18). F cites six more judge files from the same window: K/scratch/overnight-2026-09-05/hunt-0911/fix/{P2-F,P3-A,P3-B,P3-C,P3-D,P3-E}-JUDGE.md (F:75, :83-84, :92, :100-102). So 49 is a scoped minimum.

**8. The detect-only branch is on two canvases.** N1 and N3 show the unmerged detect-only branch, but T:179 and F:198 say not to describe it externally (「不對外描述／對外不可說」). T:35 leaves the lab meeting to Adam. This needs Adam's explicit decision.

**9. The CVD claim is CONTRADICTED.** "≥14.6" (T:41, fig_f1.md:65) is wrong: S/cvd_layer_fills.log:10 gives 6.6–6.8 for #E6E9EC against #FFFFFF. It only collides in the legend, because docs has 0 tiles.

**10. M1's binary sha comes from another generation.** It is cited from the G4 arm (fig_m1.md:21). The plotted points are G2/G3 data, and …/2026-09-19T115737Z_full/G2/cooperative_f64_a/arm.meta:12-15 carries the same shas, so that is the better citation.

**11. Pre-existing Rule 3 mixes** (not introduced by this round, and not in the F-list):
- H1: the footer is the only RAN element (T:201) and it is unlabelled.
- H3: the "frame lost" markers are inferred but unmarked.
- T3: ran numbers sit on a read diagram.
- T1: the twin column is titled "RAN IT", while T7 titles the same kind of evidence "JUDGED".

**12. A stray iperf in H6's third column is not disclosed.** F:114 records a 2 Mbit/s iperf at 09-26 17:55 between hosts of a live 06 arm, inside the 17:29Z run that H6 uses. The 17:55:15Z flowcache arm shows no doubling (E/runs/2026-09-26T175515Z_flowcache_solution_ndtwin.md:593-594), but H6's notes and .md say nothing about it.

**13. The 916 folder was modified on 09-27.** K/../NDTWIN slide material 916/figures/p4-tutorials/ now holds `fig_t1b_requirements_matrix_0927.*`, which quote GAP-2b before Adam's review. Its remote is public (R:6). Confirm those files are untracked.

**14. S3's old/new rows (09-10/09-11) are pre-09-16 evidence** shown without the background treatment T:13 describes. They are not a 916 re-show; the two cells appear nowhere in the 916 material.

**Checked and consistent:** 36 = 30 + 5 + 1; ✅30 / ○6; 58 = 32 + 20 + 6; 17 = 26 − 9; the A2 and T2 counts; the H-page numbers; 1645 = 1617 + 28; p4runtime 14,000 B = 3,500 × 4 B; the M1 values.

## 4. Red checks

**M1** (S/m1-sampling-error-redcheck.sh, S/m1-sampling-error-redcheck-20260927T1710Z.log).
- The control passes (log :2).
- Mutations touch only a temp copy of summary.json, which the generator reads through `NDTWIN_REPO` (make_sampling_error_fig.py:41-43). Output lands next to a temp copy of the generator (:45).
- Each mutation reaches its own `die()` (log :3-6, script :62-63, :74-75, :82-83). None can stop for an unrelated reason.
- Not exercised: `die()` at :76-77. fig_m1.md:72-73 says all four stop conditions went red; in fact three were tested (one of them in both directions).

**T1c** (S/t1c-coverage-redcheck.sh, S/t1c-coverage-redcheck-20260927T1735Z.log).
- The control passes (log :2).
- The four mutations hit make_coverage_0930.py :65-66, :68-70, :71-72 and :91-93 respectively (log :3-6). Earlier checks pass in every mutated tree, so none stops for an unrelated reason.
- Not exercised: `die()` at :81-82 and :89-90. So T:42's claim that every generator's stop conditions have all been seen red (「每支產生器的停止條件都看過紅」) overclaims.
- The substantive gap: all three flowcache assertions pin *non-delivery*. None reads the twin's own reading (FC/link_usage/twin_integral.txt:3). Zeroing that reading, which would be a genuine no-evidence case, would leave the figure unchanged. So the check proves the stop fires; it cannot support the label.

**The others** each show a green control and every mutation killed for its named reason:
- roles-flowapi-redcheck-20260927T1704Z.log:16: 12/12 plus 2 controls.
- ndt-serve-s2s4-red-checks.log:30: 9 plus control.
- o1-o2-t6-t9/run_mutations.log:17: 14/14.
- mutation_check_fixed_since_916.log:13-14: 10/10 plus control.
- engineering-verdict-regex-redcheck-20260927T1706Z.log:10 tests that the new regex catches the six missed verdicts, not that it avoids false positives. My independent tally covers that.

## 5. Numbers I could not verify

- The 45 merges that name a judge.
- That f9be5842's tree equals fed37cff's.
- Blob-equality with 797c34ab, and whether any audit-raw commit is public.
- 17 distinct heartbeat sessions.
- T2's counts beyond T06; T5's per-check counts and the "21–25"; R3's L-cell check counts and 8/12→3/12.
- T4's multicast numbers; the Q1 and Q4 test and CI numbers; the S2 and S3 live values (seen only in red-check logs).
- The Dependabot closures (no raw exists, by design); the +N values beyond what is quoted.

## 6. Tests I would have run

1. A single source function that feeds both T1 and T7, asserting the two flowcache labels are equal.
2. A mutation that zeroes FC's twin reading on s1-eth3.
3. Red cases for M1 :76-77 and T1c :81-82 and :89-90.
4. A distinct-session count on 50_samples.tsv.
5. `git log` on fed37cff to check the 45.
6. An unauthenticated HTTPS check on the audit-raw commit being cited.
7. A scan of every canvas and F for layer or subsystem attribution of the privilege row.
8. GAP-2 at 70615ec5 against 1a284f75, to see whether the row may be dated "09-16".

## Fix list

1. **(Blocking, Rule 6)** Remove the layer attribution of the privilege item:
   - give its F1 tile a neutral fill;
   - move the row out of the heading at F:142 and drop it from the layer counts (F:59, R:210, the F1 legend);
   - amend fig_f1.md:50 and regenerate F1.
2. **(Blocking)** Unify the flowcache cell on T1 and T7:
   - recommended: "IPv4 only" with the pending box, T1 count 6/4/3;
   - correct fig_t1c.md:20 and :39, T:124 and :162, R:108/:246/:263, T:380, and make_coverage_0930.py:13;
   - add a stop condition that reads twin_integral.txt.
3. Update the audit-raw status of the three 09-19 morning runs (T:27, :112, :132; R:91; F:45) and cite the commit that holds them, once you have checked it is public.
4. Re-date T1's 09-16 row as background: "as shown 09-16; read 09-08, trunk 1a284f75".
5. Change Q3 row 3's "caught by" to raw review.
6. Replace N3's flowcache evidence with the netdev lines and iperf_server.txt.
7. Label Q2's bands READ and RAN, and scope the 49 or write "≥ 49".
8. Get Adam's decision on detect-only, then align N1, N3, T:179 and F:198.
9. Correct the CVD claim at T:41 and fig_f1.md:65.
10. Either add the missing red cases or soften T:42 and fig_m1.md:72-73.
11. Cite G2's own arm.meta for M1's binary sha.
12. Add +N at T:112 and T:114; give the checkout state at fig_d1.md:29.
13. Rule 3 labels:
    - T1's twin column: "JUDGED";
    - H1's footer: mark as RAN;
    - H3's "frame lost" markers: mark as inferred;
    - T3: label or drop the ran numbers.
14. Disclose F:114's stray iperf in H6's notes.
15. Confirm that the 916 folder's `*_0927` files are untracked in the public slide repo.
16. Take the READ cells out of D1's background band (or date them 3d740be0) and refresh fig_d1.md:44.
17. Regenerate every figure and record the script sha next to its "last produced" line. For example, fig_t1c.md:67 says 16:4xZ, but the red check at 17:35Z ran sha 30ef2f79.
