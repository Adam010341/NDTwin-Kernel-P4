# Judge report — P3-E round 10 (head bc1db4c0), 2026-09-24

Judge: `fable-judge` definition run as Opus 5.5 (Fable rate-limited on 09-19; Adam 09-24 reserves Fable for hard rulings). Read-only (Read/Grep/Glob). Saved verbatim by the orchestrator from the agent's final message; the orchestrator's disposition is ruling 40 in TICKET-P3 §9.

**Verdict: MERGE AFTER FIXES.** Ruling 38, all nine items of ruling 39, the red runs, the mutation gate and the fifth-campaign numbers are backed by the logs. Two defects need fixing: the code still prints a bare "H-C2" label that the worker's own rule forbids, and bmv2 can still receive an H-C0 label. Several claims can only be checked with git, which the judge could not run (the orchestrator checked them: 106a06bf touches only tests/; test_analyse.py changed +2/−2 in 308cc6a5; the seven instrument scripts are tracked at bc1db4c0; the worker's summary.json sha256 d48fa3ca6beefbe5 matches).

## 1. Ruling 38: group-level H-B labels — SUPPORTED, with two untested edges
- H-B1: PREREG :251 "三個速率的 median|ratio−1| 都落在 [0.5, 2.0] × 0.674/√N" ↔ analyse.py:66 REGISTERED_RATES_MBIT, band at :459-463, `h_b1 = all_registered_rates(positions, "inside")` at :507; helper :486-491 returns False/None/True as claimed.
- H-B2: :252 "100 Mbit/s 那格 > 2.0× 預測，且 三個視窗的 ratio−1 同號" ↔ :69, :512.
- H-B4: :254 ↔ per rate :557, decided once :582-583.
- Per-cell description kept (:455-471, :558-560); both levels in summary.json (:1048-1051).
- UNTESTED: three-window count not enforced (same_sign at :453-454 counts however many valid windows); missing-rate "not decided" asserted (SUMMARY:1442) but untested.

## 2. Red-first — logs SUPPORTED; "106a06bf is tests only" UNVERIFIABLE without git
- red-38-hb-group-level.p3e-106a06bf.log :123/:135/:79 match; "Ran 16 tests / FAILED (failures=11)".
- red-C-hc-level.p3e-106a06bf.log :43/:61/:70/:32/:79 match; "Ran 13 tests / FAILED (failures=5)"; :18 shows the level-pinning test green on old code.
- Reproduced logs at bc1db4c0 show the same 11 and 5 failures.
- Not disclosed: tests/test_analyse.py hash 939afc84323f in the 106a06bf red runs vs a232540c77d2 at bc1db4c0.

## 3. Mutation gate — SUPPORTED
mutate.p3e-bc1db4c0.log: Ran 94 / OK (skipped=1); "mutations: 43 survivors: 0 drifted: 0"; both controls stayed green; M-E37 at mutate_analyse.sh:675-679 bound to test_two_rates_inside_and_one_outside_is_NOT_H_B1_for_the_group and caught by it (:129-130). Tallies recounted: 16 "no other case/cell went red", 73 "also red". Gate self-test 14/0.

## 4. Ruling 39, item by item — all SUPPORTED (measured where the ruling asked for measurement)
① synthetic.py:198-208 rewritten. ② anchor sweep 45/13 at head, 38/11 retro, self-check 2 BAD rc 1. ③ sum→max/first measured at e222176d (76 tests OK, 34/0/0 both patches) and at head ("42.0 != 150.0 … rung 1.0"). ④ citations fixed (drive_e.sh :647/:648, rows :72-85 in an 85-line file, inventory.py :133/:102-105). ⑤ recount "rows: 14 (4 keys missing, 10 cardinality)". ⑥ real get_window_extent: 9.36 pt text box, 206.4880 pt axes before/after, tightest margin +0.82 pt, 9/9 inside, both campaigns. ⑦ FINDINGS §6 items 6–7 present (:209-216); item 7's premise now false. ⑧ scan_onpath_edges.py: fourth {"0": 9, "4": 18}, fifth {"0": 9, "4": 16, "5": 2}. ⑨(a) gate log :125-128. ⑨(b) scripts filed; red-37-1 reproduces round 9's four lines; inventory re-extraction 0 differences (fourth), 1 (fifth). ⑨(c) test_plot.py:290-307, M-E41, guard-equivalence log :25-30. ⓪(b) telescoping log :41-44: increments [7, 8, …], sum 120 = last − first, result 150.000000.

## 5. Task C: H-C
PREREG :262 common rungs; :270 H-C1; :271 H-C2 two conditions; :272 H-C3; :273 H-C0; :276-277 bmv2 ratio. Code: cpu_verdict :885-891 checks H-C1 first, returns H-C2 on share ≤ 0.2 alone (docstring :872-878 says so); common rungs :800-814; bmv2 ratio :848-866; H-C0 :824-837.
- Link "H-C2" rests on one of two conditions — SUPPORTED (hc2-second-condition-data log :41-45: m 79.00, share 0.0623, delta ratio 31.505 vs S ratio 58.680).
- bmv2 unlabelled in the fifth-campaign output — SUPPORTED (reconcile log :39-44).
- "bmv2 gets no H-C label" in general — CONTRADICTED: :832-837 assigns "H-C0 not resolved …" before the `if registered:` check at :839; the bmv2 test (test_analyse.py:544-555) never reaches that branch.
- A bare H-C2 label still ships (analyse-115737Z log :79; summary.json cpu_kernel.fits.link.verdict and reconciliation (b) row :967).

## 6. Fifth-campaign verdicts — SUPPORTED
Cooperative 2 Mbit/s median 0.29528 above [0.071329, 0.285318], mixed signs; 20 and 100 inside; label "neither H-B1 nor H-B2 holds as registered". Link "H-B1" (20/100 Mbit/s bands on 5 edges). Link/coop 0.25265, 1.2555, 1.4893 → "not H-B4 … at 2 Mbit/s". Kernel shares 0.0722 (coop) / 0.0623 (link). bmv2 ratio outside at 12 kpps (1.513) and 45 kpps (1.164), 9/11 inside. "1424 identical": reconcile log reads so; the judge compared 64 numeric values by hand (6 medians, 12 fit values, 2 marginals, 44 delta_percent) — all byte-identical.

## 7. Anchor sweep — SUPPORTED; commit status UNVERIFIABLE (orchestrator: tracked)
45 anchors + 13 external at bc1db4c0 = e222176d's 10 + the 7(c) grep + two red-run patches; positive control at anchor_sweep.py:84-91.

## 8. Claims without evidence, and internal inconsistencies
- SUMMARY:1442/:1686 rule ("a label starts with a hypothesis name only when it holds") vs the H-C2 output at analyse.py:889-890.
- SUMMARY:1489 and docstrings (:30-32, :768-770) vs :832-837 (bmv2 H-C0).
- Under-evidenced: "last cell" roll-up claim (SUMMARY:1457-1458) has no mutation; SUMMARY:1673 says M-E41 caught with a ZeroDivisionError but the gate log does not show the exception type.
- Small: "six" instruments vs seven listed; FINDINGS cited as :209-217 (ends :216); gate prints "(N cell(s) went red)" using bound cells; a test comment says 0.2854 (actual 0.285318).
- UNVERIFIABLE without git: 25-commit merge without conflict; only the round directory changed; the trailer; c1f4174f as source of FINDINGS text; 06e47cae/bc1db4c0 differing only in scan_onpath_edges.py; summary.json sha; the negative claims (no sudo/lab/live).

## Findings, most severe first
1. Medium — bare H-C2 label on one of two registered conditions (analyse.py:889-890).
2. Medium-low — bmv2 can still get an H-C0 label (:832-837 before :839).
3. Medium, for FINDINGS — cooperative's "neither H-B1 nor H-B2" matches no PREREG branch (:249-255, :391-394); ruling 38's "doesn't affect results" held for the fourth campaign, not the fifth.
4. Low — red-first provenance: test_analyse.py changed after the tests-only commit without disclosure.
5. Low — untested: missing-rate path, last-cell roll-up, three-window count.
6. Low — FINDINGS staleness: §6 item 7 premise; :154 expects a single bmv2 ratio.
7. Trivial — wording/count issues above.

## Fixes needed before merge
1. H-C0 branch behind the `registered` check; bmv2 no-rung-resolves test seen failing first; mutation bound.
2. Stop emitting a string starting with "H-C2" while condition 2 is unevaluated ("not decided: …" or a machine-readable flag), tested — or an explicit orchestrator ruling.
3. Attach git evidence for 106a06bf being tests only; disclose the later test_analyse.py change; confirm the seven scripts are committed.
Recommended: missing-rate and three-window tests, last-cell mutation.

Rulings the orchestrator needs to make before FINDINGS §3/§4: H-C2 tolerance; H-C1 vs H-C2 precedence; H-C0 spread; how FINDINGS reports cooperative's unregistered outcome; refreshing FINDINGS §6 items 6 and 7. (All made in ruling 40.)
