# JUDGE: 930 deck r3

**READY AFTER FIXES.** Fixes 1–6 below block the deck. Two items still narrow the open privilege item's location despite this round's F1 work (items 1a and 1b). The H1 footer that was newly stamped "RAN IT" includes an item its own raw contradicts. They are edits plus two regenerations; a grep and a look at the PNGs is enough to verify them, not a full new round.

Path roots used below:
- D = `/home/adam/Desktop/NDTwin slide material/NDTwin slide material 930`
- K = `/home/adam/Desktop/NDTwin-Kernel`
- S = `K/scratch/overnight-2026-09-05/logs/slides930`
- W = `K/scratch/overnight-2026-09-05/wt-audit-raw`
- E = `K/doc/audit/2026-09-04_p4-tutorial-exercise-prep`
- T = template v1.2, R = README-930.md, F = FIXED-SINCE-916.md

**How I checked:** read-only. I read T, R, F, the figure `.md`s these items touch, all 30 on-deck PNGs plus the archived r1 and n1, the changed generators, and every S harness and log from this round. I spot-checked cited raw under E and in W.
- I did not read any `judge-*.md` or the 17:55Z incident report.
- I could not run anything, so I did not hash any file, regenerate anything, or use git.
- File ages come from Glob's modification-time order (oldest first; it matches the timestamps in S's log names). I compared across folders with brace globs.
- This report names no subsystem.

## 1. The 18 items

**1. F1 privilege tile — CONTRADICTED.** The tile itself is right; the folder still locates it.
- Verified:
  - In `fig_f1_fixed_since_916.png` the KJL tile is white with grey hatch and has no legend entry; the legend reads 2/5/4/24/0 = 35 of 36.
  - F:61-66 and §4.4 (:158-164) match.
  - `make_fixed_since_916.py:150` and `:206-208` do what is claimed; `fig_f1.md:52` defines the exception.
  - The r2b mutation log (:13) prints layers {2, 5, 4, 24, neutral 1}.
  - No leak from tile position (§4.4 is parsed last, so the tile is drawn last), from legend arithmetic, from stale section numbers, or from old per-layer counts anywhere in D or S.
- Still locating it:
  - **a. `D/README-930.md:304`.** Item 1's "落在" cell cites, as a line item 1 changed, one single layer's §1 count row (the first `F:` citation). Since item 1 was "take the tile out of its layer", naming the edited layer-count row names the layer. This is the strongest leak and it is new this round.
  - **b. `D/figures/engineering/fig_q3_review_catches.md:80`.** It says row (e)'s catch type recurred on the KJL branch. Row (e)'s evidence at `:48` names the code area involved, so the sentence tells a reader where that branch changed code.
  - **c. `D/FIXED-SINCE-916.md:164`.** The KJL row itself says "同一分支另含 ruling J（測試 fixture 的來源規則）". That puts a layer-evoking word inside the one row that must carry none.
  - **d. `S/mutation_check_fixed_since_916.py:36` (M11).** It hard-codes one specific legend layer's name as the replacement for the neutral heading.
  - **e. Neutrality is not enforced.** A tile's layer comes only from its heading (`:150`), and only the §1 counts are checked (`:206-208`).
    - M11 dies only because §1 was left stale (log :12, "tests=24, the tables have 25").
    - Moving the row back under a layer heading and updating §1 would pass silently.
    - R:304's "腳本多兩條對帳（…中性標題）" overstates this: there is no heading check.
  - **f. UNTESTED.** The CVD r2 log compares the hatch colour with the fills, not how the tile looks overall. By my estimate, white with a dense 1 pt grey hatch averages to a light grey close to the pale legend fills, so from a distance it may read as a layer.

**2. flowcache — SUPPORTED.**
- Raw in `E/runs/2026-09-27T081256Z_flowcache_solution_ndtwin/link_usage/`:
  - `twin_integral.txt:3` = 31787577.5 on s1-eth3; `:7-9` are all 0.
  - `netdev` line 7 goes 3151 → 4596340; line 3 goes 3531 → 3804 (+273).
  - The server file has no report row; `iperf_client.txt:10` shows no ack; `onpath.txt:1` lists s1-eth3 only.
  - W holds the same bytes.
- T1 and T7 both show flowcache as orange "IPv4 only"; T1 keeps the dashed box and the 6/4/3 count; notes at T:134 and T:175.
- The corrections (T:136, `fig_t1c.md:22`) match GAP-2b:206, which cites T06's `sol:588-604` first.
- The new stop (`make_coverage_0930.py:67-101`) has red cases in the t1c r2b log (:3-4).
- Small gaps:
  - "s1→s3" depends on the s1-eth3↔s3 link, which is not cited.
  - The archived `fig_t1b_…_0927.md:10` still says "已知的儀器缺陷".

**3. audit-raw 5cf0364c — CONTRADICTED in one place (minor).**
- It is cited correctly at T:29-30, :121, :144; R:95-96, :249; F:46-48; `fig_o2.md:38`; `fig_t5.md:64`.
- W has all three `00_table.tsv`; `052251Z_05` is absent there and the deck says so (T:30, R:96, F:45/48).
- But the docstring at `D/figures/overview/make_overview_figs.py:29-31` still calls those three runs "uncommitted observations".

**4. T1 09-16 row as background — SUPPORTED** (PNG, and `make_coverage_0930.py:157-164`).
- Template rule T:16 ("背景帶只蓋「跑過」的舊格子") contradicts this band, which covers an old read-the-code row. Reword the rule.

**5. Q3 row 3 — SUPPORTED** (T:326; `E/live-p1/runs/2026-09-27T074635Z_06_thirteen/00_table.tsv:27` shows PASS 5/5).
- `fig_q3.md:71-72` and `:81` still list only three kinds of catcher.

**6. N3 flowcache evidence — SUPPORTED.** T:384 matches the raw above.

**7. Q2 — SUPPORTED.** The PNG shows the READ and RAN bands and "≥ 49"; the recount command is at `fig_q2.md:32`. I re-added the per-file table (:45-76) and got 23 / 23 / 3 = 49. Stale side statements are listed in §3.

**8. detect-only — SUPPORTED.** The N1 PNG has no detect-only step; the archive exists; the flag works as described (`make_roadmap.py:42-43`).

**9. CVD claim — SUPPORTED.** The r2 log gives a minimum of 14.6 across the four tiled fills, tests vs docs 6.6–6.8 (`cvd_layer_fills.log:10`), and hatch vs ndt fill 4.4–6.3.

**10. New red cases and the coverage statement at T:45 — UNDER-EVIDENCED.**
- The M1 and T1c cases exist and pass (§4), and T:51 names 7 generators without red checks.
- But T1 imports `make_tutorial_figs_0927.py` (`make_coverage_0930.py:35`, `:105-112`), which does the GAP-2/GAP-2b parsing and the T06 cross-check and has about 68 exit points.
- Nothing in S red-checks it, and neither T:45-51 nor R:37-41 lists it.

**11. M1 binary shas — SUPPORTED.**
- `G2/cooperative_f64_a/arm.meta:12-15` and `G3/link_f64_a/arm.meta:12-15` both show kernel be70b5dd… and bmv2 3ff54b5c…; the script asserts they match.
- Nuance: the plotted `se_*` windows have no `arm.meta` of their own and inherit these values from the same bring-up. `fig_m1.md:21` says so.

**12. +N — SUPPORTED.**
- Spot checks against arm reports: dfb9d0d7 +47, 67b64869 +64, 580767a8 +83, 5dc7fc9a +95.
- `five_tuple_live.txt:2` records only "commit: e89fd4b", matching "not recorded".

**13. Rule-3 labels — present, but H1 is CONTRADICTED.**
- All five labels are on the canvases as claimed (T1 "JUDGED", H1 footer and panels, H3 "(inferred)", no run numbers on T3, one result cell per step on Q1).
- The H1 footer lists `link_watchdog` as skipped (`E/runs/2026-09-27T074826Z_basic_solution_ndtwin.md:58` and `:236`).
- The same switch_state shows `"watchdog": "running"` (:301), and :202-203 show the heartbeat started ("a cut link is detected").
- F:156 lists exactly this misreport as defect E on the unmerged AEG branch.
- So the item newly stamped "RAN IT" is contradicted by its own raw and by the deck's own fix list, and it clashes with H2–H5 and T3.
- `make_heartbeat_extra_figs.py:136-141` only checks the list.
- A pre-heartbeat source where all three items were true exists: `E/live-p1/runs/2026-09-24T160256Z_07_roles_basic/70_up_plain.txt:63`.

**14. H6 stray-iperf disclosure — SUPPORTED.**
- The p4runtime arm (`2026-09-26T175425Z…md:613`) carried 4,735,073 B against T06's 4,361,273 B (:612), i.e. +8.57%.
- The flowcache arm (`175515Z…md:593-594`) is not doubled.
- The "+8.6%" baseline is not named at T:247 or `fig_h4.md:19`. The attribution to the stray iperf rests on the incident record, which I did not read.

**15. 916 folder untouched — SUPPORTED for this round.**
- Every top-level, `.md`, `.py` and PNG file in the 916 folder is older than 930's `fig_s1` PNG (15:42Z).
- Caveat: the 916 folder already holds 09-27 files from earlier that day (`make_tutorial_figs_0927.py`, `fig_t1b_…_0927.*`). I did not check PDFs or SVGs.

**16. D1 — SUPPORTED** (PNG; `make_flow_api_matrix.py:193-202`).

**17. Regeneration and shas — SUPPORTED, within limits.**
- All 34 figure `.md`s end with a 最後產出 line.
- For the 10 regenerated scripts, the `.md` sha equals the one in `regen-r2…log`.
- Hashes computed at run time by other harness logs match the `.md` for 8 scripts: coverage, sampling_error, serve_s2_s4, exercise_path, overview, roles, queued_readback, tutorial_figs_0927.
- Every generator is older than its PNG. The one exception is the archived `n1_with_detect_only`, and the deck discloses it.
- I could not hash anything myself.

**18. Archived fig_r1.md names 17e40e29 — SUPPORTED** as text (`fig_r1_four_rulings.md:25`). I cannot check the tip without git.

## 2. T1's "8 / 6 / 2"

- **Consistent with GAP-2b.** GAP-2b:105 says "做得到 8、部分 6、做不到 2". The two 做不到 are meters (:93) and digest (:95), both "只有讀碼" (read only), and they are exactly the two read-only cells.
- **Not consistent with the legend.**
  - The legend lists "cannot" (plain grey) and "read only" (grey with ×) as separate entries.
  - The 09-27 row has no plain grey cell, so a literal reading gives 8 / 6 / 0 plus 2 read-only.
  - The swatch is the "cannot" fill plus × (`make_coverage_0930.py:172-173`, `:206-209`) but is labelled only "read only".
  - Nothing asserts that the read-only cells are "cannot" (:114-118).

## 3. Regressions and cross-document inconsistencies

- **clang/TSan review status is stale.** T:339, T:351, R:217 and F:144 all say "尚無判官" (no judge yet). The worker's own regen log (:58) lists `…/intake-0926/cicxx/judge-CICXX-a956fd78.md`, named for the tip given at F:22.
- **Q2 cutoff count and last-run pointer.**
  - T:312 and `fig_q2.md:19-21` say two judge files fell after the cutoff; the latest run lists four.
  - `fig_q2.md:118` and `fig_q3.md:90` point to the 17:05Z run log as "the last run", not `regen-r2`.
- **Smaller stale text:**
  - R:13 still says the template is v1.1.
  - R:224 still lists "cut 2b".
  - `fig_o1.md:65` gives only f4dd9f22 for the telemetry run; G2–G6 are 4d3f294f, as M1 says.
  - `make_heartbeat_figs.py:14-15` cites audit-raw 543a3aa2 instead of 797c34ab.
  - T:32 and R:97 give the dirty-checkout range as +47…+95, while F1's own evidence starts at +29 (F:85-96).
- **Background rule applied unevenly.** S3 shows the 09-10/09-11 old/new rows unbanded, while D1 and T1 put pre-09-16 evidence in a band.
- **Minor Rule-3 asymmetries:**
  - H4's band and 20 s line are derived from constants but not marked, while H3 now is.
  - T3 and Q1 mix run-derived and read-derived elements without labels.
  - T1's 09-27 row is labelled "RAN IT" although its cells are GAP-2b judgements, like the twin column next to it that is now "JUDGED".

## 4. Rule 1 (all 36 pages)

- No violations: 30 pages carry one canvas each and 5 pages one table each.
- A0 is title-only, which is the template's declared "title" form.
- Borderline but allowed as key annotations: R3 "recorded, not asserted", T6 "name recorded, not copied", S2's legend "held / did not hold", and T5's callout text.

## 5. Red-check logs from this round

| Log | Control | Mutations | Each reaches its named stop? |
|---|---|---|---|
| T1c `t1c-coverage-redcheck-r2b` | rc 0 | 10/10 rc 1 | Yes |
| M1 `m1-sampling-error-redcheck-r2b` | rc 0 | 7/7 rc 1 | Yes (the rates case gets past the position check first, as it should) |
| F1 `mutation_check_fixed_since_916.r2b` | green | 12/12 | Not all: M4 dies at the merge-set check rather than the public-ancestry stop (M5 does exercise that stop); M11 dies at the per-layer count, since no neutral-heading stop exists |
| Engineering verdict regex r2 | 3 controls pass | 6 red as expected | Yes (covers the regex only) |
| ndt-serve s2/s4 r2 | rc 0 | 9 red | Yes |

All five logs are newer than their scripts.

## 6. Tests I would have run

1. For the neutral tile: a stop requiring the row with the approved phrase to sit under 不標層, plus a mutation that moves the row back and updates §1 consistently, which must go red.
2. A scan of D and the S harnesses for layer words or single §1 layer-row citations near the privilege item.
3. How the hatched tile actually looks on screen or projector next to the pale legend fills.
4. For H1: compare `skipped[]` against `heartbeat.watchdog` in the same switch_state.
5. For T1: assert that read-only cells are "cannot".
6. A red check of `make_tutorial_figs_0927.py`'s stops.
7. `sha256sum` of all 17 scripts.
8. Cite the s1-eth3↔s3 link.
9. Re-query the review status at regeneration time.

## 7. Outside the deck (flag only)

- W, which you said is public at 5cf0364c, contains `scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/secret-scan.kjl-53246917.log` and `…/secret-scan.kjl-15217241.log`.
- I did not open them. If they list the branch's changed paths, they locate the open item in a public ref.
- No `*rkjl*` gate logs are in W.

## Fix list

1. `R:304`: drop the single-layer §1 row citation; cite only the 不標層 row and the §4.4 heading.
2. `fig_q3_review_catches.md:80`: delete the sentence.
3. `F:164`: drop the ruling-J clause. In the harness at `:36`, make M11 loop over all five layer names or use a string that is not a layer name; then re-run it and update `fig_f1.md:33-35`.
4. `make_fixed_since_916.py`: add the neutral-placement stop and the matching mutation (test 1 above), and correct R:304's "two new reconciliations" claim.
5. H1 (fig_h0):
   - Re-source the footer to the 09-24 run (572d9462 +61, `70_up_plain.txt:63`) with its date, or drop `link_watchdog`.
   - Add a check that `skipped[]` agrees with `heartbeat.watchdog`.
   - Update T:214, regenerate, and update the sha in the `.md`.
6. T1: relabel the swatch "cannot · read only" and assert read-only ⊆ cannot. Regenerate, update the sha, and re-run the t1c red check.
7. clang/TSan review status (T:339, T:351, R:217, F:144): add the snapshot time or update it.
8. Q2: fix the cutoff count ("two" should be four) at T:312 and `fig_q2.md:19-21`, and the last-run pointers at `fig_q2.md:118` and `fig_q3.md:90`.
9. `make_overview_figs.py:29-31`: change the docstring to say 5cf0364c and re-run the o1/o2/t6–t9 self-check, or note the stale docstring in `fig_o2.md`.
10. T:45-51 and R:37-41: list `make_tutorial_figs_0927.py`'s stops as not red-checked, or add a red check for them.
11. Minor text:
    - R:13 (v1.1 → v1.2), R:224 (remove cut 2b)
    - `fig_o1.md:65` (add 4d3f294f)
    - `make_heartbeat_figs.py:14-15` (543a3aa2 → 797c34ab)
    - `fig_q3.md:71-72` and `:81` (four catcher kinds)
    - `fig_t1b…md:10` (drop "已知的儀器缺陷")
    - T:247 and `fig_h4.md:19`: name the +8.6% baseline
    - T:16: reword the band rule
    - T:32 and R:97: fix the +N range
12. For you to decide: whether S3's pre-09-16 rows need the band, and whether H4, T3, Q1 and the T1 09-27 row need RAN/READ/derived labels.
13. Outside the deck: check the two `secret-scan.kjl` logs in the public audit-raw.