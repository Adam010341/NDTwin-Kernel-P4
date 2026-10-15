# Review: Cut A of the P4 generic table writer (ternary/range/optional + priority, no V7), head 1b16b0a0, round 1

[Co-developed with claude code -- Adam]

Paths used below:
- W = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-writer-a (code, tests, gates and DESIGN r3 at the worktree head)
- L = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/ternary-cut-a
- A0 = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/ternary-a0
- R = the handback, /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/ternary/REPORT-cut-a-1b16b0a0.handback.txt
- MC = the main checkout /home/adam/Desktop/NDTwin-Kernel

## Scope and method

- **What I read.** R; DESIGN r3 (§1.5, §2, §3.1, §4, §6.1–6.4, §7, §10, Q2); every changed source and test file at W; the three gate scripts; under L, INDEX, the red logs and TSV, the before/after/gate logs, s0-run/probe.log, agree_bmv2.py with its header and the stock and fast outputs; A0 INDEX plus stock/12–15.
- **The "before" state.** I read it from MC's working tree. This is an observation of a shared, uncommitted tree. At session start git status showed no modification under p4_proxy/proxy_agent or tools/p4_exercise, and MC's line numbers match the dd8022fa tracebacks in red-dd8022fa.log: p4_client.py:1205, :1296, :1346.
- **What I did not do.** I did not read the design's judge reviews or any handoff notes, and I used no git history. I executed nothing.
- **What that leaves unverified.** Claims that need git (commit contents and messages, push state, test-file identity since b822506a) are marked UNTESTED or UNDER-EVIDENCED below.

## Verdict on each claim in the report

| # | Claim (R line) | Class | Evidence / what is missing |
|---|---|---|---|
| 1 | A1: builds ternary/range/optional; `_match_as_dict` shared; optional branch; 501 tests reversed (R:6) | SUPPORTED (head state) | p4_client.py:1110-1132, 1169-1204, 1367; rule_install_times.py:115-119; red-a1 log builds them (:332, :340-345 ok). Commit boundaries not checkable without git. |
| 2 | A2: V1–V6, V8, V9; E1; 200 carries `priority`; "pre-flight runs the same match_shape code" (R:7) | SUPPORTED, except the last clause is partial (m5) | match_shape.py:236-402; api_routes.py:246-282, 1010-1015, 1022; preflight.py:214-295 |
| 3 | one 501 guard, mutants, reversals (R:8) | SUPPORTED | match_shape.py:248-254; mutate_table_entry.sh:586-851 |
| 4 | the install-time gate was already red at dd8022fa, fixed by linking `setting/` (R:9) | red baseline SUPPORTED; cause UNDER-EVIDENCED | L/gate-mutate_p4_rule_install_time.BEFORE-dd8022fa.log:7-9 prints no cause. The green run is at head (gate-…log:1,8-9); there is no run of dd8022fa plus the link. The mechanism in mutate_p4_rule_install_time.sh:78-84 is plausible. |
| 5 | commit messages carry no trailer and none of the forbidden words (R:11) | UNTESTED | nothing logged |
| 6 | Gates table (R:16-23) | SUPPORTED | before-p4_proxy.log:2637, after-p4_proxy.log:2662; the p4_exercise logs :8; gate logs :446 / BEFORE :257 / :260 / :40; check_gate_anchors_HEAD.log:145; check_test_tmpdirs.log:6; test_l1_shell_scoring.log:190 |
| 7 | reversals and new mutants (R:25-33) | SUPPORTED | script plus log lines R cites; one test-strength nit (m9) |
| 8 | M-B7/14/20 not retired (R:34) | SUPPORTED | api_routes.py:1024 still `journaled: False` |
| 9 | the test files are unchanged since b822506a (R:35) | UNDER-EVIDENCED | the red logs hash the overlays (red-dd8022fa.log:7-11); no log hashes head's five files |
| 10 | 50 red + 14 red at dd8022fa (R:41) | SUPPORTED | red-dd8022fa.log:1762, :2580 |
| 11 | R1–R3 (R:46) | SUPPORTED | red-table.tsv:2-10 |
| 12 | R4 red for its own reason (R:47) | UNDER-EVIDENCED as worded | Coverage is fine; the wording is not. `test_modify_and_delete_need_the_priority_as_well` is red at dd8022fa only through the 501 (red-dd8022fa.log:913-929; tsv:13) and is own-reason red only at A1 (red-a1:169). The int32 test is red through a ValueError, not "not raised" (tsv:16). |
| 13 | R5, R6a (R:48-49) | SUPPORTED | tsv:17-20 |
| 14 | R7, R7b (R:50) | R7 partial; R7b SUPPORTED | the mixed-table V8 test is red at dd8022fa only through the 501 (tsv:38, red-dd8022fa.log:1294) |
| 15 | R8, R9 "the match is dropped ({})" (R:51) | R8 partial; R9 SUPPORTED | `test_a_written_entry_is_findable…` is 501 at dd8022fa and green at A1 (tsv:41). It has been seen red only as collateral of mutants (gate log :53, :134, :347, :388, :426). |
| 16 | R18 (R:52) | SUPPORTED | tsv:44-57; red-dd8022fa.log:1999-2044 |
| 17 | R25 (R:53) | SUPPORTED | tsv:61-62 (KeyError 'p4rt_error') |
| 18 | R6b–f red only through the 501, own reason at A1 (R:54-55) | SUPPORTED (honest) | tsv:21-32. R6e reads "?" in the TSV, but the log shows FAIL (red-a1:321, :1093). |
| 19 | R6g (R:56) | SUPPORTED | tsv:33-36; gate log :328-333 |
| 20 | R23 (R:57) | SUPPORTED | tsv:58-60; gate log :428-431 |
| 21 | side find: priority 2^31 was a bare ValueError (HTTP 500), now 400 (R:59) | SUPPORTED at the client; the HTTP 500 is inferred | red-dd8022fa.log:932-947. MC api_routes.py:942-945 re-raises non-gRPC errors. No route test pins the new 400. |
| 22 | A0 items 12–15 (R:63-66) | SUPPORTED | stock/12:40-41, :98; stock/13:33, :86-87, :488-512; stock/14:32-33; stock/15:36-37; A0/INDEX.txt:39-50 |
| 23 | "no result contradicts the V-rules"; V6 also covers modify/delete on exact/lpm (R:67) | SUPPORTED | stock/15:115-117, :143-145. This was already the writer's behaviour (test green at dd8022fa, red-dd8022fa.log:162). |
| 24 | 52 cases: 48 agree, 4 local-only, 0 disagree; stock = fast (R:71) | SUPPORTED | agree-stock/agree.txt:64; agree-fast/agree.tsv is row-for-row identical |
| 25 | accepted locally → switch accepted; refused locally (A1 build) → switch refused (R:72) | SUPPORTED with a caveat | the A1 module's `shape_priority` was patched to be lenient (agree.header.txt:2; agree_bmv2.py:47-50) |
| 26 | "the 4 local-only cases have no wire form" (R:73) | CONTRADICTED for n09 | An over-width bytes mask has a wire form; A1 itself put one through `write_table_entry` (red-a1:176, "TableEntryInvalid not raised"). It was marked local_only by hand (agree_bmv2.py:185). True for the V1 ×2 and 2^31 cases. |
| 27 | E1 checked against real trailers (R:74) | SUPPORTED | agree-stock/agree.txt:59-62 (NOT_FOUND ×2, ALREADY_EXISTS) |
| 28 | S0: PF-T pre-flight rc 0, no G5; PF-T verdict check FAIL; PROBE-BROKEN; every other row ok (R:78-81) | SUPPORTED | probe.log:23, :50, :51, :2-49; tools/p4_health/s0.py:273-277, :574-583, :598-599 |
| 29 | "A cannot merge without D"; D = s0.py:275-277, pft_verdict, expected_today.tsv (R:81) | SUPPORTED but incomplete | A also needs V7/Q2 (M1). Per DESIGN §7:651, D also covers `classify_pft` (s0.py:124-133), `pft_cannot` (cells/table.py:390-395), tests/python/fixtures/p4_health/preflight_pft.txt:26, and the T4–T7 oracles. |
| 30 | S0 at b75448cd still holds at head ("later commits touch only gates and a comment") (R:77) | UNDER-EVIDENCED | plausible; nothing logged |
| 31 | Q3 (a) implemented (R:84) | SUPPORTED | match_shape.py:58, 224-227, 307-310, 327-331. R does not say whether Q3 was ruled or the recommendation was taken. |
| 32 | Q2 open; no binding changed; the empty-match pin (R:85) | bindings SUPPORTED | The pin test's stated rationale is false (m1). The SUMMARY says no fixture changed (m2). R omits that named-field writes to flow_5tuple went from 501 to 200 (M1). |
| 33 | default-entry key deferred to Cut B (R:86) | SUPPORTED as a deferral | the collision already exists today (m10) |
| 34 | test_ndt_app_package.sh:1001 has no G5 coupling (R:87) | SUPPORTED | :187-197 is an echo stub; :1001 is a switch_state fixture line |
| 35 | requirements.txt (R:88) | SUPPORTED | requirements.txt:98-105 |
| 36 | "only V5/V9 are added for lpm" in pre-flight (R:89) | SUPPORTED but incomplete | V8 and the empty-match rule are re-implemented, not shared (preflight.py:220-224, 285-290) |
| 37 | V7 follow-up list (R:91-105) | partly CONTRADICTED | V7 lives in `write_table_entry` (DESIGN:277), so `BuildTableEntryTest`, which only calls `build_table_entry`, will not flip. Missing from the list: the success paths of `TheShapeRulesTest` and `TheReadSideKnowsEveryMatchTypeTest` (all baseline `a_client` writes). |
| 38 | scratch copies deleted; no lab/sudo (R:110) | SUPPORTED / self-attested | old-tern-a/ is gone; A0/INDEX.txt:2 |

## Findings

### BLOCKER
None.

### MAJOR (neither blocks the merge to the hold; both must be settled before the hold is released)

**M1. Without V7, Cut A opens NDTwin's own `flow_5tuple` to any ternary write, and the delivery's disclosure understates this.**
- **What changed.** Before this cut, any POST naming a flow_5tuple field got a 501 (MC p4_client.py:1204-1208). Only the empty-match road reached the wire. At head these are built and answered 200. The test test_table_entry_route.py:298-309 pins exactly that, for `MyIngress.flow_5tuple` through a baseline `a_client` (:189-205, never `bind_routes`).
- **What the design says.** The design sanctions this change only together with V7, which makes these writes 409 (DESIGN §2.2 :275-281, Q2 (a) :693-704). Without V7 the delivered state is Q2 (c) in practice. The design's own stated cost of (c) applies (:719-720): `insert_5tuple_rule`'s MODIFY fallback (p4_client.py:1678-1680) silently overwrites an operator's entry with the same key. A partial-mask drop can also now be installed in front of ipv4_lpm on a baseline fabric.
- **What the delivery says instead.** R:81 says "A cannot merge without D". SUMMARY-cut-a.md:40 tells Adam the flow_5tuple behaviour is unchanged ("現況行為照舊").
- **Fix.** State that the hold is on Q2/V7 as well as on D, and correct the SUMMARY. Keeping 501/409 for baseline-bound tables until V7 lands would be a stop-gap, but that is a design decision, not something this review requires.

**M2. Cut A makes a known rendering gap reachable on NDTwin's own pipeline: `/stats/flow` shows a partial-mask ternary field as an exact match, and a range field as 0.**
- **The gap.** In ryu_flow_stats.py:125-133 only `lpm` gets a prefix suffix. Ternary renders `value` and drops the mask. Range has no `value` key, so it renders as `_int(b"")`, i.e. 0, or "0.0.0.0". FIELD_TO_RYU (:53-61) covers dstAddr, srcAddr, protocol, the l4 ports, ingress_port and dl_dst.
- **Why it was safe before.** Every ternary row NDTwin itself wrote came from `_encode_5tuple_value`, which always uses full masks (p4_client.py:1546).
- **What Cut A changes.** The generic writer can now install partial masks and ranges on those fields: through the API on baseline flow_5tuple, and through boot or API entries on ndtwin-mode foreign pipelines with these field names and a recognised action. Before, only external controllers could. test_ryu_flow_stats.py:102-110 covers only zero and full masks. The module's own rule (:260-273) is "absent and counted, never described wrongly".
- **The design is silent here.** It needs a ruling: render CIDR-shaped masks as /n and leave non-CIDR masks and range rows out (counted), or file the gap with a test that pins the current rendering.

### MINOR — fix before merge
- **m1. The flow_5tuple pin test is accurate, but the reason it gives is false.**
  - test_p4_client_writes.py:2245-2251 says the catch-all "is refused elsewhere (V7)". Nothing refuses it at this head.
  - Rename or re-comment it as "§1.5 defect, pinned pending Q2".
  - Move the shape-rule property it wants ("every field omitted, priority ≥ 1, passes V1–V9") to a table that is not NDTwin's, so that property survives V7 untouched.
  - The same pattern exists, unlisted, in `test_leaving_the_lpm_field_out_is_the_way_to_say_any_address` (:2104-2107): a catch-all on NDTwin's own ipv4_lpm through a baseline client.
- **m2. SUMMARY-cut-a.md:40 says no existing fixture changed ("沒有改任何既有 fixture"). The shared p4info fixtures did change.** They gained tables: test_p4_client_writes.py:218-246 (Synthetic.unspecified_table, Synthetic.mixed_table) and test_table_entry_route.py:147-158. The bindings are unchanged, which R:85 says correctly. Q2 (a-iii) is precisely about fixture edits, so say exactly what changed.
- **m3. n09 does have a wire form (claim #26).**
  - Either send n09 with the A1 build, the way every other refused case was sent, or relabel it "not reachable from JSON; bmv2 verdict unmeasured".
  - Then soften match_shape.py:29-30, which says every rule "repeats a refusal bmv2 already makes".

### MINOR — can wait
- **m4.** The R4, R7 and R8 rows in R's table overstate their dd8022fa reds (claims #12, #14, #15). The TSV itself is accurate.
- **m5. Pre-flight and the writer do not fully share one check.**
  - Shared: the ternary/range/optional field shapes (`shape_field`), V6 (`shape_priority`), V5/V9 on lpm (`check_lpm`), and the priority-column test.
  - Not shared:
    1. V8 is re-implemented in pre-flight with its own condition and sentence (preflight.py:285-290).
    2. An empty-match entry on an LPM-only table: the writer accepts it and so does bmv2 (test :2104-2107; agree h30), while pre-flight FAILs it (preflight.py:220-224; test_preflight.py:433-437). DESIGN §4:363 sanctions this, but nothing lists it as a divergence.
    3. The exact/lpm encoder stays separate (disclosed).
    4. Only pre-flight checks the table's action_refs (pre-existing).
- **m6.** The V7 flip list needs correcting (claim #37).
- **m7.** D's file list needs completing (claim #29).
- **m8. Stale comments:**
  - test_foreign_pipeline.py:207-209 ("the refusal above")
  - test_table_entry_route.py:128-132
  - test_p4_client_writes.py:196-203 (range and optional "reach the refusal")
  - the return keys in the `write_table_entry` docstring (p4_client.py:1211-1213)
- **m9. Test-strength nits.**
  - M-S2a's case `[6, 256]` truncates to mask 0. It is then killed by V5's sentence, not by the entry being accepted; a value like 0x1ff would show acceptance.
  - No mutant truncates the ternary value side or the range low side (match_shape.py:305, 322). They were seen red only as errors under M-B5.
  - `test_a_written_entry_is_findable…` feeds the written bytes back unstripped, so it does not model bmv2's leading-zero stripping.
- **m10.** The default-entry key (§10-2) is deferred. A default entry and an all-omitted LPM entry already share the key `(dpid, table, 0, ())` in rule_install_times today (pre-existing).
- **m11.** Several side claims rest on nothing logged: claims #4, #5, #9, #30, and the HTTP half of #21.

## Answers to the five questions

**1. Behaviour against the design.**
- **Every V-rule matches §2.2 exactly.**
  - V1: match_shape.py:300-304, 319-321, 335-340.
  - V2: :193-208 plus `encode_value`.
  - V3: :311-315.
  - V4: :324-326.
  - V5, all three spellings, each saying "omit the field": :307-310, :327-331, :224-227.
  - V6: :370-402 (1..2^31-1, default takes 0, exact/lpm takes 0, no +1 shift).
  - V8: :359-366.
  - V9: :228-233.
- **All refuse before `stub.Write`, with the stated error.** Every rule raises `TableEntryInvalid`, which the route turns into 400 (api_routes.py:992-995). The raise happens inside `build_table_entry` (p4_client.py:1110-1165); `write_table_entry` calls it at :1234, before `stub.Write` at :1256. Every refusal test asserts `stub.requests == []`.
- **One extension beyond §2.2.** V2 adds a bytes-above-width check, but only for the three new types.
- **Encodings match A0.**
  - Values are written full-width; the install-time key is int-based, so bmv2 stripping leading zeros does not matter (rule_install_times.py:72-87).
  - PRIORITY_MAX = 2^31-1 with a floor of 1 (A0 07).
  - Priority is part of the key (rule_install_times.py:146).
  - agree shows 0 disagreements on 52 cases, on both binaries.
- **E1 decodes the real trailer shape correctly.** It walks key/value pairs, parses the `-bin` bytes into a Status, unpacks p4.v1.Error, takes the first non-OK, and never raises. It was checked live (agree.txt:59-62).
- **The read side and `_built_entry_match` spell entries the same way.** There is one function for both (p4_client.py:1169-1204, :1367), and M-J9d proves the guard.
- **Pre-flight and the writer share only part of the check.** See m5.

**2. Regressions on existing paths.** None, apart from M1 and M2.
- **Kernel routing.** The kernel builders (p4_client.py:1576-1905) do not touch `build_table_entry`. The byte-identical capture test and the 27-mutant install-time gate are green.
- **Boot entries.** `apply_package_entries` is unchanged (main.py:618-664). The `failed` count means the same thing as before. Entries bmv2 would refuse now fail locally with a named reason. Ternary, range and optional entries now apply, as intended.
- **readopt.** M-B12 is green.
- **External mode (409).** `_refuse_write` still runs first (p4_client.py:1232), and M-B13 is green.
- **200 that now answer differently.**
  - No request a real bmv2 accepts is newly refused.
  - Former 502 UNKNOWN answers (and former 200s against the fake stub) are now 400, as designed.
  - Priority 2^31 went from 500 to 400.
  - The only change the design does not sanction is flow_5tuple going from 501 to 200 (M1).
  - Negligible: `priority_honoured` flips from True to False for an UNSPECIFIED-only table.

**3. Red evidence.**
- **Own-reason reds hold**, with the R4/R7/R8 nuances in claims #12, #14 and #15.
- **The A1-only reds are honest.** At A1 the request reached the wire ("not raised"), which is exactly the design's A1 premise.
- **Every mutant falsifies what its name says.** The reversed M-B6 builds a ternary as exact; the reversed M-B25 puts the tuple back to EXACT/LPM.
- **Decision paths that have never been seen red:**
  1. pre-flight's UNSPECIFIED branch (preflight.py:242);
  2. pre-flight V8's `match or has_priority_column` clause (:288);
  3. the ternary value-side and range low-side encoding (m9);
  4. `_p4rt_error`'s outer guard and its unknown-code fallback (api_routes.py:261-264, 275-278);
  5. the rule that names are resolved before shapes, so a 404 comes before a 400 (p4_client.py:1101-1111).

**4. S0.** The result is correct and is what the design predicted (§6.4:644). "A must land with D" is true but incomplete: A also needs Q2/V7 (M1), and D's file list is longer than R states.

**5. The pin test.** As a pin of today's behaviour it is correct: green at dd8022fa (red-dd8022fa.log:167), and bmv2 accepts the entry (stock/13:488-512; agree n01). Its rationale is wrong and its home table is wrong (m1).

## Tests I would have run
1. A pre-flight/writer agreement table: run the same entries through `check_entry` and `build_table_entry` and assert FAIL ⇔ raise. It would have surfaced m5.
2. Live findability: after each accepted insert in agree, read the real switch and assert `age_seconds` is not None. That exercises stripped read-back for optional, ternary and range.
3. Send n09 to bmv2 with the A1 build.
4. A route test: priority 2^31 on flow_5tuple → 400 with `stub.requests == []`.
5. ryu_flow_stats with a partial-mask ternary row and a range row (M2).
6. A unit test running pre-flight on the real PF-T runtime file (tools/p4_health/exercise/runtime/s2-runtime-pft.json).
7. Pre-flight with an UNSPECIFIED field, and V8 on a mixed table with an empty match.
8. `_p4rt_error` with an exception that has no `trailing_metadata`, and with an unknown canonical code.
9. sha256 of head's five test files compared with red-dd8022fa.log:7-11.
10. The §10-2 test that the default entry and the all-omitted LPM entry get different keys, as a pin now.

## Internal inconsistencies
- The R4, R7 and R8 rows of R:47-51 versus red-table.tsv:13, 16, 38, 41.
- "No wire form" (R:73) versus red-a1:176.
- The TSV shows "?" for R6e (tsv:29); the log shows FAIL (red-a1:1093).
- R:112 calls the summary "SUMMARY-ternary-cut-a.md"; the committed file is SUMMARY-cut-a.md.
- The agree IDs skip h32. The total is still 52.
- R:85 calls the pin test an empty-match "POST", but it is a client-level test.
- SUMMARY says no fixture changed; the fixtures were extended.
- R lists `BuildTableEntryTest` among the V7 flips, but V7 sits in `write_table_entry`.
- R's D list is shorter than DESIGN §7's.

Numbers that do reconcile:
- Suite counts: 1734→1788 and 196→210.
- dd8022fa reds: 50 = 45 R rows + 5 acceptance tests; 14 = the 14 R18 rows.
- A1 reds: 28 = the TSV's 28 (25 failures + 3 errors).
- Mutants: 76 = 41 + 35 new.
- agree: 52 = 48 + 4.

## 摘要（繁體中文）
程式本身符合設計 §2.2：每條 V 規則都在 `stub.Write` 之前回 400。E1 用真的 trailer 驗過。讀取側與寫入側共用同一個 `_match_as_dict`。kernel routing、開機 entry、readopt 與 external 409 都沒有退化。紅燈證據大致誠實，只有 R4、R7、R8 的摘要說得比 TSV 滿。

兩個 MAJOR 都不擋併入 hold，但解除 hold 前要先處理：
- **M1**：沒有 V7 的 Cut A 會讓 baseline 上 `flow_5tuple` 的具名欄位寫入從 501 變成 200。hold 條件要加上 Q2/V7，交付報告與 SUMMARY 裡「現況照舊」的說法要更正。
- **M2**：`/stats/flow` 會把部分遮罩的 ternary 顯示成精確比對、把 range 顯示成 0。這個缺口以前就有，但 Cut A 之後 NDTwin 自己就寫得出這種 entry；設計沒有涵蓋，需要裁定。

另有三個小項要先修：
- 空 match 的 pin 測試註解寫「由 V7 擋」，目前並不成立。
- SUMMARY 說「沒有改任何既有 fixture」，實際上 p4info fixture 加了 synthetic 表。
- n09（遮罩超出欄位寬度）其實有線上形式，只是沒有送到 bmv2。

MERGE AFTER FIXES
