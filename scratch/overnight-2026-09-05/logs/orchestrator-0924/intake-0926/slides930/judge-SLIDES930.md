# JUDGE: 930 deck material (read-only audit, 2026-09-28)

Path roots used below:
- **M** = `/home/adam/Desktop/NDTwin slide material/NDTwin slide material 930`
- **K** = `/home/adam/Desktop/NDTwin-Kernel`
- **L** = `K/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs`
- **E** = `K/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs`
- **I** = `K/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926`

How I worked: I only read files. I ran nothing and did no git queries. So any claim whose evidence is `git log` or `merge-base` is listed as unverifiable. I looked at all 33 300-dpi PNGs and all 47 pages of the 916 deck PDF.

## 1. Summary verdict

**FIX. This is not ready to go to the professor.** Of the 36 pages, 22 are OK and 14 need fixes; 5 of those fixes are blocking. No page needs to be dropped outright, but T1 should come out of the core unless it is re-cut.

The special-attention numbers all reproduce from raw except one:

| Item | Result | Raw I checked |
|---|---|---|
| 06 per-run arm counts 2/20/23/26/25/26/26/26/26/26 | SUPPORTED | I recomputed from the ten 26-row `L/*_06_thirteen/00_table.tsv`, using the rules at `live-p1/06_thirteen.sh:107-115, :142-155`. Exercise counts come out 0/8/10/13/12/13×5. |
| First 26/26 at 09-19 14:43Z | SUPPORTED | `L/2026-09-19T144328Z_06_thirteen/00_table.tsv`. No earlier 06 run exists; the 052518Z/063235Z/083257Z runs give 2/20/23. |
| Detection 12.204–16.827 s, restore 4.623–5.099 s | SUPPORTED | `L/2026-09-26T152605Z_08_heartbeat/30_cycles.tsv` rows 2–7. Also every `strict_20s` = yes, pingall during the cut 12/12 (`34_pingall_cut.txt`), and "4 routes moved" at `I/hbw-live/h14-20260926T152605Z.log:72`. |
| Bound 14.972 + 1.610 + 0.245 = 16.827 | SUPPORTED | Row 4 of that file: last_heard 72142.316, cut 72142.344, pass_start 72158.926, graph_down 72159.171. |
| Sampler 1645 vs 1617 | SUPPORTED | `L/2026-09-26T172912Z_08_heartbeat/50_samples.tsv` has 1645 data rows, all with `forwarded_to_hosts`=0. Data row 1617 (file line 1618) is 1790445370.3 = 17:56:10.3Z. `L/2026-09-26T175610Z_01_baseline/` exists. The last row is 17:56:38Z. `I/hbw-live/h5b-20260926T172912Z.log:48` says "1617 samples". There are 17 distinct running sessions. |
| Telemetry 0.2953/0.0274/0.0154 vs 0.0746/0.0344/0.0229 | SUPPORTED | `K/doc/audit/2026-09-19_telemetry-three-groups/raw/2026-09-19T115737Z_full/summary.json:2153-2243`. Ratios 0.253/1.255/1.489 at `:2274-2295`. Kernel and bmv2 sha in `G4/link_f64_b/arm.meta:12-15`. |
| Live 07: 8/12 → 3/12 during the cut; 12/12 at bring-up and after | SUPPORTED | `54_pingall_during_cut.txt`, `32_pingall.txt`, `61_pingall_after_recovery.txt` in both 07 runs. L-line counts are 20 and 21 in `K/scratch/.../live-0925/07_roles_basic.log` and `I/live07/07.log`. |
| FIXED-SINCE-916 32/0/4, layers 2/6/4/24/0 | Counts SUPPORTED; some row states are **stale** (F-3) | Rows in §2–§4 match the bricks. Public trunk = `fed37cff` from unauthenticated evidence (`M/figures/fixed-since-916/public-check-20260927.log:17-18`). Ancestry not re-run (no git). |
| "43 judge verdicts (18/22/3)" | **CONTRADICTED** | The true count is at least 49 (23/23/3). See F-1. |
| "57 merges, 45 naming a judge" | Not verifiable here (needs `git log`) | 57 does agree with FIXED §0's 58 at `fed37cff` minus the `fed37cff` merge. |
| CI L1 14→15→14→12 | SUPPORTED | All 28 `I/ci-*-gcc.raw.log` and `intake-0925/ci-*-gcc.log` `L1 FAILED (N …)` lines match the table in `fig_q4_ci_state.md`. |

**Blocking fixes** (details in §3):
1. **F-1, Q2:** the verdict count is wrong.
2. **F-2, T1:** it repeats the 916 matrix, mixes ran/read/judged in one unlabelled table, has 4 cells still waiting for Adam's review, and its flowcache cell is sourced from a different run.
3. **F-3, F1 and FIXED-SINCE-916:** the wording names the subsystem of the open privilege bug; the public state of main is stale and contradicts Q5; some review states are stale.
4. **F-4, D1:** two rows are pre-09-16 background data, shown with no date.
5. **F-5, R1:** status chips, and two "done" labels that overclaim.

There is also a process gap (F-6): the T06 raw and GAP-2b are not archived, yet about 10 pages depend on them.

## 2. Per-page table

| # | Page | Verdict | What I checked, and how the key claim classifies |
|---|---|---|---|
| 1 | A0 | OK | Title only. |
| 2 | A1 `fig_o1` | OK | Marker x-positions match the UTC times in the .md. The 7 run directories exist. Merge dates depend on git (unverified). Minor: dates are UTC here but +08 on F1 (F-18). |
| 3 | A2 `fig_o2` | FIX (minor) | Values 0/8/10/13/12/13×5 SUPPORTED. The 09-08 "0" is "0/13 **run** on the NDTwin fabric" (916 template `:257`), but it is plotted on a "both arms as expected" axis (F-7). The note at template `:103` says "two heartbeat-on runs", but there were three (see `:120`, `:202`). |
| 4 | T1 `fig_t1b` | **FIX, or drop from core** | Counts 1/9/6 (GAP-2 `:39`), 8/6/2 (GAP-2b `:105`) and 13/13, 7/3/3 (GAP-2b `:208`) SUPPORTED. It breaks rule 1 and rule 3, and has pending and contradicted cells (F-2). |
| 5 | T2 `fig_t5` | OK | Every cell recomputed. The 17 heartbeat arms and the 9 without heartbeat (4 single-switch, 3 external, 2 unbuilt skeletons) are consistent. Minor: "as expected" vs "not as expected" is encoded only by red/green, which colour-blind viewers cannot separate. |
| 6 | T3 `fig_a1` | OK (minor) | 21–25 is computed from raw. I verified 07 = 25 PASS (`12_preflight_basic_roles.txt`), multicast = 24, and `basic_solution` lines `:191-214`. Minor: a 4-line bullet list sits inside the "P4 proxy" box, and the box existence (ran) and the arrows (read from code) are in one unlabelled panel. |
| 7 | T4 `fig_t6` | OK | All SUPPORTED: `E/2026-09-27T075305Z_multicast_solution_ndtwin.md` `:77`, `:182`, `:198`, `:332-336`, `:345-351`, `:464-467`, `:589-594`, `:695`; skeleton `:18`, `:467`. |
| 8 | T5 `fig_t7` | FIX (minor) | 9 problems, 7 FAIL lines and rc 1 SUPPORTED (`E/2026-09-27T075454Z_basic_tunnel_skeleton_ndtwin.md:113-119, :127, :239`). Kicker and caption text on the canvas (F-8). |
| 9 | T6 `fig_t8` | OK | 10 files = 8 copies + 2 new; read-back ok (`E/2026-09-27T074826Z_basic_solution_ndtwin.md:78-89`). |
| 10 | T7 `fig_t9` | OK | PASS n/n values match T06 lines 5/7/11/17/23/25/27. 14,000 B = 3,500 × 4 SUPPORTED (`onpath.txt:1-2`, `iperf_client.txt:9`). The "yes" cell is inferred (no pcap), but its panel is titled "JUDGED". |
| 11 | R1 `fig_r1` | **FIX** | Rulings SUPPORTED by `ANALYSIS.md:401-406`. Chips plus two overclaiming "done" labels (F-5). |
| 12 | R2 `fig_r2` | OK | 16 removed (4+4+4+4) and 16 of 16 written SUPPORTED (`10_convert_roles.txt:6`, `21_proxy_roles_lines.txt:2`, `01_binaries.txt`). Ran and read are split into two panels. |
| 13 | R3 `fig_r3` | OK | SUPPORTED (see §1). "Recorded, not asserted" is correctly shown. |
| 14 | R4 `fig_r4` | OK | All four rows match the `L6 capabilities` lines in both 07 logs. |
| 15 | H1 `fig_h0` | OK (minor) | The skipped list is SUPPORTED (`E/…074826Z_basic_solution_ndtwin.md:58`). The two mechanism panels are read from code, and the right panel shows a packet-out the proxy never sends. |
| 16 | H2 `fig_h0b` | OK | Constants confirmed at `K/tools/test_workflow/ndtwin-lab:715, :734` and `K/p4_proxy/proxy_agent/topology_manager.py:373, :419, :422`. |
| 17 | H3 `fig_h1` | OK | 16.8 s and 4.6 s, the two watchdog passes (+11.58, +16.58) and first-heard at +2.90 all SUPPORTED. |
| 18 | H4 `fig_h2` | FIX (minor) | The 7 points SUPPORTED (H3 point from `64_cycle.tsv:2`, 16.607 s at φ 0.017). Overlapping markers, and the phase-lock numbers cite a report instead of raw (F-9). |
| 19 | H5 `fig_h3` | OK | The decomposition is SUPPORTED. The design-worst bar is correctly labelled as design, not measurement. |
| 20 | H6 `fig_h4` | FIX (minor) | 26/26 identical and 1645/0/17 SUPPORTED. The big "0" has no live positive control, and the notes don't say so (F-10). |
| 21 | D1 `fig_d1` | **FIX** | The foreign-P4 rows are SUPPORTED (`L/…202055Z_07_roles_basic/40–45`, `74`, `75`, `76d`). The OVS log is checked (`d9-d11-flow-mutation.log:5-29`), but that row and the own-P4 row are undated pre-09-16 data (F-4). |
| 22 | D2 `fig_d2` | OK | 200 queued, accepted 1, request_id 1 in both; accepted vs rejected; 10.0.9.9 → OUTPUT:3; 501 `unsupported_on_p4`/unbound — all SUPPORTED. Minor: the theme overlaps 916 pages 26/28/32; frame the page as the new P4-plane evidence. |
| 23 | S1 `fig_s1` | FIX (.md only) | BIND, port, header and 600 s confirmed in `K/tools/ndt_serve/serve.py:72, :73, :94, :1163`. `fig_s1.md:36` is stale (F-11). |
| 24 | S2 `fig_s2` | OK | Listener, 403 host, P4 rc 5 in 0.1 s, and OVS rc 0 "fabric came up" SUPPORTED (`…/live-fixes-20260924T2249/01-listen-and-token.txt:2`, `a2/summary.json:22-25`, `a/summary.json:185-187`, `b/04-probe-foreign-host.http:8-17`). It names attack classes against ndt serve, but these are defences that held, not the open bug. The red-check log lives in an ephemeral scratchpad (F-20). |
| 25 | S3 `fig_s3` | FIX (minor) | 4 and 8 red→green, still_red empty, CELL PASS all SUPPORTED (walk JSONs `…/12-GET…`, `…/46-GET…`). But "8" includes 4 fixture gaps, and the cell concept was already in 916 (F-12). |
| 26 | S4 `fig_s4` | FIX (minor) | Read-only material. Verdict-style labels (F-13); the sha will be stale by 09-30. |
| 27 | M1 `fig_m1` | FIX (minor) | Values SUPPORTED. Problems with the notes and the .md, and the key marker is hard to read (F-14). |
| 28 | Q1 `fig_q1` | OK (minor) | 1557+187 (`intake-0925/rerun-REQ-851cefd7.summary.log:1-2`); gates 5/6 (`I/pb5-merge/rerun-summary.ac0c3b64.txt:1-6`); 1658+187, 4 descriptors identical, VERIFIED (`migrate.log:25-28, :136-139, :146`); 01 PASS and 06 26/26 (`live-accept.log:3, :6`); trial runs (`pb5-trial/JOURNAL.txt:4-7`). CI is drawn in neutral grey (F-15). |
| 29 | Q2 `fig_q2` | **FIX** | The example numbers are SUPPORTED (`gates-0910/mutate_p4_heartbeat_w…log:213, :216`; `I/hbw/rerun3-summary.7b600ab0.txt:1`). "43 (18/22/3)" is CONTRADICTED (F-1). |
| 30 | Q3 `fig_q3` | FIX (minor) | Card facts SUPPORTED (`judge-KJL-4a96f894.md:14` MERGE AFTER FIXES; H5 FAIL at `I/hbw-live/h5-20260926T153259Z.log:59`). Chips (F-13). Security wording is correct. |
| 31 | Q4 `fig_q4` | OK | 28 of 28 L1 values verified; the table has 29 rows (28 logs + 1 API-only). |
| 32 | Q5 `fig_q5` | OK | `_net/pulls_Adam010341.json:39-40, :418-419, :797-798` (#8 at 16:13:10Z → f9be5842; #7 → f347a588; #6 → ce6a9832) and `branch_Adam010341_main.json:4`. |
| 33 | F1 `fig_f1` | **FIX** | Brick placement and counts match FIXED §2–§4. Security wording and staleness in the .md and in FIXED (F-3). |
| 34 | N1 `fig_n1` | OK | Git-derived states, not verified by me. |
| 35 | N2 table | OK | "≈15.5 s" is inferred, and the notes say so. |
| 36 | N3 table | OK | Every row is a negated claim. The KJL row is backed by `judge-KJL-4a96f894.md:14` (MERGE AFTER FIXES = not merged). |

## 3. Findings

**F-1 (Q2, blocking): the verdict count is wrong.**
- The tally regex anchors verdicts at the start of a line (`M/figures/engineering/make_engineering_figs.py:304-308`). It therefore misses verdicts written inside a "一句話：…**合併裁決：X**" line.
- Six verdicts are missed:
  - `K/scratch/.../intake-0925/judge-HB-r4-e1245b40.md:3` — MERGE
  - `I/judge-HBR4-79670365.md:5` — MERGE
  - `I/judge-HBR6-3d297c34.md:7` — MERGE
  - `I/judge-HBR7-a77b8fe2.md:5` — MERGE AFTER FIXES
  - `I/judge-HBR7b-96abb9b0.md:6` — MERGE
  - `I/judge-HBR8-3a724b87.md:6` — MERGE
- `fig_q2.md:42`, `:48` and `:88` claim these files carry no verdict. Only `judge-HB-r3-01ff8368.md` actually has none.
- FIXED-SINCE-916 `:101` itself attributes MERGE AFTER FIXES → MERGE to HBR7/HBR7b, so the material contradicts itself.
- Minimum correct figure: **49 = 23 MERGE / 23 AFTER FIXES / 3 other** across 38 files.
- To do: fix the regex, regenerate Q2, and update template `:254`, README `:187` and `fig_q2.md`.
- Also use one snapshot: "57 merges" is counted at `3d740be0`, while FIXED §0 counts 58 at `fed37cff`.

**F-2 (T1, blocking): the requirements matrix page.**
- **Rule 1 (delta only):** `fig_t1b.md:38` says the 13×16 matrix is cell-for-cell identical to the 09-16 figure. It is page 3 of the 916 deck, and the "NDTwin 09-16" row is 916's "NDTwin today" row (916 template `:261`).
- **Rule 3 (ran vs read):** a single unlabelled matrix holds:
  - read-from-code rows (`:38-39`);
  - a mixed 09-27 row (14 cells include a run, 2 are read-only, `:40`);
  - ran-plus-judgement right-hand columns.
  There are no titled ran/read panels, which template rule 5 requires.
- **Pending review:** 4 judgement cells still await Adam (template `:41`, `:107`).
- **The flowcache "twin sees it" cell is green**, but in T06 the only primary path was s1-eth3 and every s3 edge read 0.000 bit (`E/2026-09-27T081256Z_flowcache_solution_ndtwin.md:592-602`). The green comes from the 09-26 run (`fig_t1b.md:188`), and T7 shows the same exercise as "IPv4 only".
- To do: keep only the two NDTwin rows plus the right-hand columns, split ran from read, and hatch the pending cells. If that isn't done before 09-30, move the page to backup.

**F-3 (F1 and FIXED-SINCE-916, blocking): security wording and staleness.**
- **Security wording.** `fig_f1.md:54` and `FIXED-SINCE-916.md:135` name the specific subsystem of the open privilege bug. That is narrower than the approved wording ("cleanup 路徑的權限缺陷", template `:31`; used in Q3 and README `:217`). The same document's fixed rows `:75` and `:92` describe that subsystem's cleanup bookkeeping. Read together, they narrow the location of a bug whose second instance is still open. Use the generic phrase in both files.
- **Stale public state of main.** FIXED `:212-215` says Adam010341 main is `ce6a9832` and that `fed37cff`'s content is not in main; `fig_f1.md:53` says the same. `_net/pulls_Adam010341.json:39-40` shows PR #8 (the claim-note content) squash-merged as `f9be5842` at 16:13:10Z, which is what `fig_q5.md:41-42` shows.
- **Stale review state.** FIXED `:141` says "d57f90f1 未再審" (not re-reviewed), but `I/sudo2/judge-SUDOPROBE-d57f90f1.md:3` exists with MERGE AFTER FIXES. FIXED `:135` calls the KJL re-review hearsay, while `fig_q3.md:21` reads `judge-KJL-15217241.md:3` directly.
- **Overclaim in the notes.** Template `:277` says the 24 instrument fixes were "caught first by live runs or CI". Several were caught by judges or gates (FIXED `:105`, `:107`, `:108`, `:111`, `:112`).

**F-4 (D1, blocking): undated background rows.** The OVS row is 09-03 data (`fig_d1.md:19`, with no kernel binary sha recorded). The own-P4 row is 08-24 data (`:20`). Both are drawn in the same "yes" green as the 09-26 rows, with no date on the canvas. 916 pages 32–33 already showed the OVS flow endpoints. Mark these two rows as dated background, or drop them.

**F-5 (R1, blocking): chips and overclaims.**
- The status chips break rule 2; template `:157` itself admits this.
- "done" on ruling ① overclaims. The second half of the ruling (`ANALYSIS.md:403`, rerouted table derivable from the declaration) is unverified (`fig_r1.md:51`). The live evidence is the PASS path (`12_preflight_basic_roles.txt:29`), not an actual refusal.
- "ipv4_route: done" for "seven same-shape programs" overclaims. Only basic ran live; the other 6 were offline only (`fig_r1.md:55`).
- To do: turn the page into a ruling → scoped-state table.

**F-6 (process, blocking under the evidence rules):** T06 is not in audit-raw (template `:22`, README `:87`) and GAP-2b is uncommitted (`??`). They underpin A2, T1, T3–T7, H6 and Q1. Push both before presenting.

**F-7 (A2):** relabel the 09-08 point as "not run" (the generator's own docstring, `make_overview_figs.py:23`, says "0 of 13 run"), or drop it. It is also a fact from the 916 deck.

**F-8 (T5):** "ONE REAL REFUSAL" (a kicker), "rc 1 · never brought up" (a verdict) and "number = how many of the 26…" (a caption) all break rule 2.

**F-9 (H4):**
- Four of the 7 points sit at φ≈0.02 (16.52/16.60/16.83/16.61), so only about 5 dots are visible under a "7 live cuts" title. The H3 point is not distinguished from the H1 points.
- The notes (`:193`) cite P4-HB-SPIKE.md for the phase-lock numbers. The raw matches: `K/doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T{023021Z,052148Z,085020Z,085506Z}_S_heartbeat/20_cycles.tsv` gives 13.275–14.382 and 10.077–14.904. Cite the raw.
- "20 cuts all the same phase" is loose: the raw has 18 at 14.197–14.382 plus two cycle-1 cuts at 13.275 and 13.298.
- README `:135` gives ψ as 1.49–1.76, which covers H1 only; H3's ψ is 1.474.

**F-10 (H6):**
- `fig_h4.md:38` says the side-effect detectors have no live positive control. The notes should say so next to the "0".
- The 1645 samples are 1 Hz polls, and only 1063 have status=running. The unit is 17 sessions, 0 frames.

**F-11 (S1):** `fig_s1.md:36` says the TMPDIR fix is unmerged. It merged as `fed37cff` (FIXED `:113`).

**F-12 (S3):** the "8" includes 4 fixture-gap assertions (`fig_s3.md:65`); show "4 (+4 fixture gap)". The old/new cell concept was already on 916 page 7.

**F-13 (S4, Q3):** status chips and verdict text ("resolve first", "open", "fixed merged", and so on). Use tables instead.

**F-14 (M1):**
- `fig_m1.md:48` quotes the pps pair "link 30→16". That is a telemetry ceiling factor in disguise, which the avoid-phrase rule forbids. Remove the numbers.
- Template `:242` and README `:174` cite 0.2532%/0.5276% to a report with sha "—". Rule 3 needs raw plus sha.
- The 29.5% marker sits on the band's top edge (band max 0.2853 vs 0.2953, `summary.json:2159-2166`), so "above the band" is not visible on the chart.

**F-15 (Q1):** the CI step uses a neutral "same as before" marker; say "red". The Dependabot closure is authenticated hearsay with no saved raw (the page does disclose this).

**F-16 (cross-cutting):** every arm report's code line is a dirty checkout. Examples: `E/2026-09-19T144329Z_basic_skeleton_ndtwin.md:473` shows "+61 file(s)"; `E/2026-09-27T074826Z_basic_solution_ndtwin.md:446` shows "+95". `h14…log:14-17` names 2 files that can change behaviour. The deck shows bare shas.

**F-17:** README `:32` says "13 generators, 206 files". Its own table (`:20-30`) lists 16 scripts, and 207 files are on disk.

**F-18:** A1 and N1 use UTC dates; F1 and FIXED use +08. So `0c96c1d0` is on 09-24 in A1 but 09-25 in F1, and `572d9462` is 09-24 in N1 but 09-25 in FIXED §6.

**F-19:** template `:254` labels 57/45 as "ran it"; README `:188` labels them "read".

**F-20:** red-check and self-test logs live in an ephemeral scratchpad (`fig_s2.md:37`, `fig_f1.md:32`, `fig_s3.md:31`).

**F-21 (T3):** trim the bullet list inside the proxy box to box names.

**Security and wording scan:**
- No attack mechanics for the open privilege bug appear on any slide, in the notes, or in any figure .md. The only issue is F-3's subsystem naming.
- Every avoid-phrase occurrence is negated (template `:26-29`, `:89`, `:128`, `:152`, `:158`, `:304-306`), apart from the pps pair in F-14.
- No venue names and no private repo. The phrase "論文 app" appears only in `fig_n1.md:22`, quoting ANALYSIS; consider rewording it.
- All titles are 45 characters or fewer; H2 is exactly 45.

## 4. Tests I would have run

1. Recount verdicts with an unanchored pattern and reconcile against FIXED's per-row judge attributions.
2. `git log --first-parent --merges --since=2026-09-16 fed37cff -i --grep=judge`, to check 45/57 and settle on one snapshot.
3. `git merge-base --is-ancestor` for all 32 rows in FIXED §2.
4. On 09-30, re-check both trunks, both mains and P4-public without authentication, then regenerate F1/Q4/Q5/N1/S4.
5. Check that the public `claude-memory` branch on both public repos (`public-check-20260927.log:13-14, :17-18`) and `audit-raw` contain nothing about the open privilege bug.
6. A live positive control for the host-port heartbeat detector.
7. A heartbeat run at worst-case ψ.
8. A live re-run of OVS `up` under a foreign claim after `68ace017`.
9. flowcache G1 with a delivery assertion, to settle the T1 vs T7 disagreement.
10. Diff the uncommitted files between runs that are presented as "identical".
11. Compare the `_hires` PNGs and the PDFs against the 300-dpi PNGs; I only viewed the latter.

## 5. Numbers I could not verify

- 57/45 merges; the 32 ancestry claims; the 58-merge reconciliation; "82 direct commits"; "17 unmerged refs"; the A1 merge timestamps; "0 commits 09-20 to 09-23". All need git.
- The Dependabot closure at 08:20Z (authenticated only).
- GAP-2b cell-level judgements. I checked only the count lines.
- R1's "6 offline pre-flight PASS" (`merged-R-572d9462.offline_5-3.log` not opened).
- S1's 11-step API compare.
- Q2's "public 2×200" (`push-cafd518a.log` not opened).
- The per-run job colours in Q4. I checked all 28 L1 lines but not the jobs files.
- Whether T06 is really absent from audit-raw.
