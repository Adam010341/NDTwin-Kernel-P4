# Judge: P4 ternary writer + table-entry journal, design 521a95d1 (r1)

## Scope and method
- This was a read-only review. I executed nothing and ran no git. All line numbers come from the worktree files as they are now. I could not confirm those files are byte-identical to 521a95d1; the hand-back says the commit adds only the note.
- What I read:
  - the note and the hand-back;
  - the cited code;
  - the parts of the health-check DESIGN.md the note cites (:280-291, :655-664, :820-833);
  - the T4–PF-T rows of expected_today.tsv;
  - `~/tutorials` simple_controller.py:150-188 and helper.py:80-170;
  - the replace-vs-add memory.
- What I did not check: the note's 【轉述】 sources (TICKET-P2, PLAN-0917).
- Files:
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/doc/audit/2026-10-04_p4-ternary-journal/DESIGN.md (called "the note" below)
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/ternary/REPORT-design-521a95d1.handback.txt
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/p4_proxy/proxy_agent/{p4_client.py,api_routes.py,main.py,rule_journal.py,rule_install_times.py,route_binding.py,topology_manager.py,boot_identity.py}
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/p4_proxy/tests/test_table_entry_route.py
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/tools/p4_exercise/preflight.py
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/tools/p4_health/{s0.py,cells/table.py,exercise/src/hc_main.p4,exercise/runtime/s1-runtime.json}
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/tools/test_workflow/stack.sh
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/tests/shell/{mutate_table_entry.sh,mutate_rule_journal_is_wired.sh}
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/doc/audit/2026-10-03_p4-health-check/DESIGN.md (called "health DESIGN" below)

## BLOCKER
None. The overall approach holds up:
- only API writes are journaled;
- the log is folded by canonical key;
- a p4info-sha guard limits replay;
- boot entries are recomputed from the package file.

The problems below can be fixed without changing what the five questions ask. But Q1 and Q2 are not ready to put on the form as written.

## MAJOR

### M1. Q1 starts from a false premise, misses an option, and (a) promises more than it delivers. Fix before the form.
- **The premise is false.** The background says "proxy 自己分不出 warm 重啟與全新 fabric". [CONTRADICTED by option (b) itself]
  - Today's proxy does not tell them apart, but it could.
  - Option (b) is already a proxy-side signal.
  - There is a second signal the note never mentions: the ForwardingPipelineConfig cookie.
    - The proxy already sends COOKIE_ONLY on every probe (p4_client.py:704-717).
    - It pushes the pipeline without setting a cookie (p4_client.py:732-739).
    - Setting a fabric-generation cookie on push, and reading it before the next push, would tell "same bmv2, proxy restarted" from "fresh bmv2". It needs no shell change and no manifest.
    - [My inference: PI keeps and returns the cookie. topology_manager.py:1375-1376 says bmv2 answers COOKIE_ONLY even with no pipeline loaded. Measure it in A0.]
- **(a)'s stated consequence is broader than it is.** "新的 fabric 從空的開始" only holds for bring-ups that go through the step being hooked. [UNDER-EVIDENCED]
  - The note says itself that it did not read the insertion point (§9).
  - The other documented P4 bring-up path is tools/test_workflow/stack.sh. There the operator starts Mininet by hand (stack.sh:88-99, :1040-1043).
  - A fabric brought up that way would not be quarantined. It would replay yesterday's rules if the p4info sha matches — which is exactly (c)'s failure, but under (a).
  - The program that actually starts every bmv2 and writes the manifest is p4_testbed_topo.py (:33, :494-532). A hook there would cover both paths.
- **(a)'s selling point "quarantine 第一次有呼叫點" is doubtful.**
  - `RuleJournal.quarantine` is a Python method that renames the file (rule_journal.py:280-296). A shell step in `ndt up` would not call it.
  - §5.5 step 5 already adds a second mechanism (hard link, then `os.replace`).

### M2. Q2's consequences are wrong or missing in five places. Fix before the form.
1. **flow_5tuple is not "blocked by 501 today".** The note (§1.5, Q2(b)) and the hand-back say it is. [CONTRADICTED]
   - The 501 is raised only for match fields the caller names (p4_client.py:1199-1208).
   - An entry with `"match": {}` on flow_5tuple builds anyway. All six of its fields are ternary (ndtwin_switch.p4:329-347). It passes the priority branch, because the table honours priority (:1284-1296), and reaches `stub.Write` (:1368).
   - So today this POST works on any baseline switch: `{"table":"MyIngress.flow_5tuple","match":{},"action_name":"MyIngress.drop","priority":1}`.
     - It installs a catch-all ahead of ipv4_lpm and answers 200.
     - [Inference: PI accepts an all-wildcard ternary entry. Omitted ternary fields mean don't-care, which is the note's own §2.1 premise.]
   - Consequences for the note:
     - the most dangerous flow_5tuple write is already open on trunk;
     - (b) does not "only block the table this cut opens", and it does change existing behaviour;
     - §1.1's "priority 0 on a priority table is unreachable today" is false by the same path.
   - The hand-back's "outside this cut" list misses this live trunk defect.
2. **(a) as written is broader than ruling 8-1.** (a) says "一律回 409" and claims "等於把 ruling 8-1 延伸到 runtime API".
   - Ruling 8-1, as implemented, keeps a package's default action on an owned table (preflight.py:475-477, :498-500, :514-517).
   - main.py:1770 relies on it: "After the package's entries, so the table's default action is in place first".
   - "一律" refuses default actions too. The form needs a sub-choice for default actions.
3. **Where V7 lives is undecided, and both placements have consequences the form does not state.**
   - The note lists V7 with V1–V6 in §2.2, but puts only V1–V6 into match_shape (§2.3), and says `apply_package_entries` is unchanged (§4).
   - **If V7 is in `write_table_entry`** (shared with boot entries): a package's default action for an owned table is refused at boot.
     - The health check's own bring-up C binds `HcIngress.ipv4_lpm` with owner ndtwin (s0.py:50-51).
     - The exercise runtime files carry a default for that table (runtime/s1-runtime.json:20-25).
     - So C would come up with `failed > 0`. [Inference: convert keeps the default, as pre-flight does; S0 expects C's pre-flight to PASS, s0.py:269-271.]
   - **If V7 is in the route only:** replay calls `write_table_entry` directly. §5.2's "replay 時再走一次 write_table_entry，所以驗證、409 … 都會再套一次" is then false for V7.
     - Example: a binding changes from owner package to owner ndtwin while the p4info stays the same. Replay then writes API entries into an NDTwin-owned table.
   - What the note should state: V7 in `write_table_entry`, with the 8-1 default-action carve-out.
4. **The cost of (a) is already knowable from the code.** The note marks "假 client 綁的是不是 baseline" as 【推論】, but p4_client.py:254-260 answers it.
   - `route_binding = BASELINE` is a class default.
   - `a_client` builds the double with `__new__` and never calls `bind_routes` (test_table_entry_route.py:159-175).
   - So under (a), every success-path test that posts AN_LPM_ENTRY (:202-205) becomes 409. If V7 sits in the client, test_p4_client_writes' doubles flip too.
   - The same comment (p4_client.py:255-257) records that the roles ticket forbade editing existing fixtures. The form should say whether that rule still applies.
5. **(b) also needs a readopt replay.**
   - A baseline readopt returns at main.py:1743, before any replay could run.
   - (b) leaves baseline ipv4_lpm writable and journaled.
   - §5.6 says only "(c)" needs the extra replay.

### M3. §5's concurrency design breaks its own rule "被確認過的一定在 journal 裡". Fix in the note; no question changes.
- **The snapshot races with appends.**
  - The lock that orders writes is per dpid (§5.3), but the snapshot replaces the whole file (§5.5 step 5).
  - readopt is a `def` route, so it runs on the threadpool (api_routes.py:656-692) while every other switch keeps accepting POSTs.
  - Any append for another switch, made between readopt's read and its `os.replace`, lands in the old inode. Step 5 hard-links that inode into quarantine, so the live journal loses a write that was answered `journaled: true`.
  - `record()` opens the path on every call (rule_journal.py:171), so nothing prevents this.
- **readopt would fold a stale list.** §5.6 gives readopt "§5.5 的步驟 2–5", which skips step 1 (the read). Its snapshot would drop everything written since startup.
- **At startup, the per-switch snapshot can drop other switches' records.** If step 5 runs per switch inside the loop the note names (:2009-2020), the content rule must keep every other switch's records. The stated rule ("成功重放的淨紀錄＋沒有嘗試的那些") does not say so.
- **The readopt window between client swap and replay is unguarded.**
  - The new client is swapped in at topology_manager.py:1503-1506.
  - A POST for that switch then lands on the freshly emptied switch, through the new client, and is journaled.
  - The replay then either collides with it (ALREADY_EXISTS or UNKNOWN, so the entry is dropped from the snapshot), or the snapshot erases its line.
  - §5.5 holds the lock only "replay 期間".
- **The 503 sits where it can never fire, and is missing where it is needed.** [CONTRADICTED for startup]
  - §5.5 justifies it by citing a comment (main.py:1805-1806) saying the endpoint answers before startup finishes.
  - But startup is awaited inside the lifespan (main.py:2441-2443), and uvicorn serves only after the lifespan completes (main.py:2474-2476; `claim_listen_socket` :2469-2511).
  - So no POST is processed during the startup replay. readopt is where the 503 is needed, and there the note does not specify it.
- **Fix:**
  - Either one journal file per dpid, so the per-dpid lock covers both append and snapshot, or a journal-wide lock held by `record()` and across read → fold → replace.
  - readopt takes the dpid lock (or sets pending → 503) before the push, and releases it after the snapshot.
  - The locked block runs as one `run_in_threadpool` callable on a `threading.Lock`, with the client looked up inside the lock. Today the client is fetched at api_routes.py:902. Holding a `threading.Lock` across `await run_in_threadpool` (:919) would block the event loop on the second POST.

### M4. §6: several decision paths have no valid red, and one planned mutant cannot be killed. Fix in the note.
- **Some reds are red for the wrong reason, and have no mutant.** On 229ed30c these tests fail only because of the 501 (the note's own column says "先撞到 501"), which is not seeing them red for the check they target:
  - R4 (V6, priority required);
  - R6's halves for mask 0, full range, value&~mask and low>high;
  - V1 arity, including optional with two elements;
  - V2 for the new types;
  - R19's flow_5tuple half.
  - Only M-J7 exists, and it covers V3 only.
  - Missing mutants: V1, V4, V5 (each spelling), V6-required, V7, EXACT-omission, and the 503 gate.
  - R18's two FAIL assertions are green today unless they match the new sentence, because pre-flight already FAILs every ternary row with "G5 not done".
- **The fold's decision table is almost untested.**
  - §5.5 step 2 has four outcomes plus the default-entry rule. Only R13's absent→absent outcome is tested.
  - R13 expects an empty snapshot, which a fold that returns nothing would also produce.
  - No R checks that an entry POSTed before a restart is on the switch after it. R14 compares restart 2 with restart 1, which a replay that restores nothing also passes.
- **M-J4 ("重放時又 append") would survive R14, given the note's own step order.**
  - Replay appends land in the old inode. Step 5 hard-links that inode away, and `os.replace` installs the in-memory snapshot. The live file's length does not change.
  - To kill it: compute the snapshot by re-reading after the replay, or assert on the quarantine file.
  - The same fact means the "防線" in §0 and §3.2-1 is really fold + snapshot, not the no-append rule.
- **Q4(a) and the computed `switch_state.journaled` have no R.**
  - Nothing tests `record → False` ⇒ 200 with `journaled:false`, `failures + 1`, and `journaled:false` in switch_state.
  - Nothing tests the three conditions §5.4 puts into the computed `journaled`.
- **Neither concurrency hazard in M3 has an R.**
- **The remaining 501 path loses its red.** Once M-B6 and M-B25 retire, nothing tests the 501 for UNSPECIFIED/other.
- **Per-test check of §6.1's red reasons:**

| R | Verdict |
|---|---|
| R1–R3 | SUPPORTED (:1204-1208 is the behaviour under test) |
| R4 | wrong reason (501) |
| R5 | SUPPORTED |
| R6 | lpm /0 half SUPPORTED (:1249 allows 0); the other four halves wrong reason (501) |
| R7 | SUPPORTED |
| R8 | SUPPORTED only if the test builds the TableEntry directly; via `build_table_entry` it hits Unsupported today |
| R9, R10 | SUPPORTED |
| R11, R12, R15, R16 | SUPPORTED, as mutant-only reds |
| R13 | SUPPORTED for M-J3, but cannot tell a correct fold from an empty one |
| R14 | see M-J4 above |
| R17 | SUPPORTED |
| R18 | PF-T-pass half SUPPORTED; the two FAIL halves are vacuous today |
| R19 | ipv4_lpm half SUPPORTED (200 today); flow_5tuple half wrong reason — use the empty-match POST, which is 200 today |
| R20 | the startup state it tests cannot happen in production (see M3) |

## MINOR — fix before the form
- **Q3:**
  - **The cost of (a) is misattributed.**
    - health DESIGN :828 describes the thrift script `s1.sh:21`.
    - The same passage says the P4Runtime form leaves the don't-care fields out and keeps only the two IP fields (:829-831).
    - It also says pre-flight refuses "two ternary fields" (:822).
    - So the cited source shows no P4Runtime entry with mask 0x0000. As far as the evidence goes, (a) costs nothing on an existing file.
  - **(b)'s "tutorials 風格的檔案直接能用" is misleading.** Tutorials' own controller would send such a file to PI and be refused too (if the observed string fires). So (b) makes NDTwin more lenient than the reference — the opposite of ruling 23②'s worry.
  - **"lpm /0 今天是 502" is an inference** from a string, not an observation.
- **Q4(b): rollback only works for inserts.**
  - Rolling back a modify needs the previous spec, which the proxy never reads.
  - Rolling back a delete needs the action, and a delete may omit it (p4_client.py:1356-1359).
  - So (b) is not feasible for two of the three ops. The form should say so.
- **Q5(b) is not simpler than table entries.**
  - `write_multicast_group` falls back from INSERT to MODIFY (p4_client.py:932-946, :1026-1046).
  - Package PRE entries are applied on every switch at boot (main.py:2024-2048).
  - A replayed group would therefore silently replace a package's group with the same id — the replace-vs-add shape the note designs against.
- **The S0 conflict (item 5) is understated.**
  - Two S0 checks assert that PF-T fails, not one: s0.py:275-277, and `pft_verdict` at s0.py:574-583 ("PF-T verdict RED").
  - If either fails, S0's whole verdict becomes PROBE-BROKEN (s0.py:598-599).
  - PF-T's only RED path keys on the "G5 not done" string (s0.py:124-133; cells/table.py:350-355), which this cut deletes. Afterwards the cell can only be GREEN or PROBE-BROKEN.
  - §7's "A 可以單獨合併" contradicts §6.4's "要和健檢那條線一起改". A has to land together with D.
- **§5.7: replay breaks a published contract.**
  - boot_identity.py:27-33 says a changed boot_id or table_generation means "assume everything you installed on that switch is gone". Replay makes that false for API entries, yet the note cites these fields as how an app can tell.
  - On bmv2 a duplicate insert answers UNKNOWN (p4_client.py:1802-1804), so the app sees 502 UNKNOWN, not ALREADY_EXISTS.
- **The sha guard does not cover the package's entries file.**
  - The note's own reason for not journaling boot entries (§4: "package 檔一改，舊的那份 journal 會把舊 entry 寫回去") applies equally to journaled API modify/delete on boot keys, and to default-entry modifies.
  - Either record the entries file's sha as well, or ask the owner as part of Q1.
- **Evidence labels (item 1):**
  - §1.6's 【觀測】 rows (descriptor, strings with their sha16, readelf output) have no archived artifact, although V5, V6 and Q3 rest on them. CLAUDE.md requires raw data in audit-raw.
  - These are stated as fact without a 【推論】 mark:
    - §2.1 "回 502" for an omitted EXACT field;
    - Q3 "lpm /0 今天是 502";
    - the hand-back's "which PI refuses" (twice);
    - §3.1 "priority 錯了，交換機回 NOT_FOUND".
  - The NOT_FOUND claim also contradicts the docstring the note cites as agreeing. p4_client.py:1847-1850 says a wrong-priority delete "removes nothing and reports success". Add both cases to A0.

## MINOR — can wait to implementation
1. **`table_honours_priority` is tied to `BUILDABLE_MATCH_TYPES`.**
   - It tests `not in BUILDABLE_MATCH_TYPES` (p4_client.py:1144-1145).
   - §6.2's reverse mutant implies that tuple grows. That would make it return False on every ternary table, breaking V6, the §3.1 identity, and `priority_honoured` (:1385-1386).
   - R1 would catch it, but the note should say: redefine it as "any field is TERNARY, RANGE or OPTIONAL".
2. **`entry_key` is not what §3.1 says.**
   - It is `(str(dpid), str(table), int(priority or 0), normalise_match(match))` (rule_install_times.py:141): raw priority, values as ints rather than bytes (:72-87), and ternary mask-0 fields already dropped (:90-100, :127).
   - It equals §3.1's formula only because the writer refuses non-zero priority on exact/lpm tables.
   - The default-entry key has to be built separately. `entry_key` gives `(dpid, table, 0, ())` both for the default entry and for an LPM entry with every field omitted.
3. **`RuleJournal.replay` cannot be handed the folded list.** It re-reads the file (rule_journal.py:260) and applies every raw line, and its `attempted` counts raw lines. TableEntryJournal needs its own replay.
4. **§5.3 only analyses the insert case.**
   - An unconfirmed delete or modify reverts at restart, which can resurrect a rule.
   - p4_client.py:27-28 expects DEADLINE_EXCEEDED on writes that actually landed. Example: a delete that lands but times out answers 502; the retry gets NOT_FOUND (also 502); neither is journaled; the rule comes back on restart.
   - Journaling a NOT_FOUND delete is safe under the fold.
5. **Q4(a) can lose a later `journaled:true` write.**
   - Sequence: an insert's journal write fails, then a delete of that entry is journaled, then a re-insert is journaled.
   - The fold reads the first journaled op (the delete) as "the entry existed at boot", so it replays a modify, which fails NOT_FOUND.
   - Either answer `journaled:false` for that switch for the rest of the boot, or state this in the consequence.
6. **LPM host bits.** "One key per entry" (§3.2-2) needs LPM values with host bits set (beyond `prefix_len`) to be refused or canonicalised. [Inference; PI's behaviour was not observed.]
7. **`PRIORITY_MAX` = int32 until A0 is risky.**
   - The string `from <= BM_MAX_PRIORITY` reads like an assert expression [inference]. An over-limit priority might abort bmv2 rather than return an error.
   - Make A depend on A0 explicitly; §7 lists only C → B → A.
8. **Pre-flight and the writer still diverge.**
   - preflight.py:213-215 FAILs a non-default entry with no match. That is a legal all-wildcard ternary entry, and the writer accepts it.
   - The EXACT-omission rule (§2.1) is not one of V1–V6, so match_shape will not carry it to pre-flight.
9. **The retire / re-anchor list is incomplete.** Missing:
   - test_preflight.py:191-200 and :347+;
   - test_table_entry_route.py:343+, plus the range and optional 501 tests;
   - M-B1 (:205-209), M-B5 (:235-241) and M-B16 (:275-279), whose anchor lines §2.3 moves into match_shape.py;
   - in mutate_rule_journal_is_wired.sh, anchors m6/m7 (in rule_journal.py) and n2/n3 (main.py's `base_dir` line). These go non-unique if TableEntryJournal or the new path helper copies those lines.
10. **Durability against a host crash** (not a process crash): fsync the directory after `os.replace`, and after first creating the file.
11. **Retention:** step 5 leaves one quarantine file per startup in `.run/`, forever.
12. **Rename vs hard link.** §3.2-3 says startup "改名留存". Renaming first and then writing leaves no live journal during a crash window. §5.5's hard-link order is the safe one; align the text.

## Code facts checked
- **SUPPORTED as cited:**
  - p4_client.py:
    - :133 and :1204-1208;
    - :1284-1296 (except the "unreachable today" clause);
    - :1300-1316, :1327-1335 and :1344;
    - :1353-1356 and :1368-1377;
    - :1487-1494 (optional is dropped);
    - :1655-1662, :495-506 and :455-467;
    - :1801-1809.
    - Also :136-217, although the refusal itself is at :210-216, not :152-157.
  - api_routes.py:
    - :413-470;
    - :837-838 and :841-957;
    - :866-886 and :919;
    - :925-930, :954-957 and :765-767;
    - :1130.
  - main.py:
    - :51-53, :62-82, :97 and :111;
    - :511-523 and :618-665;
    - :794-807 and :818-819;
    - :1743, :1754-1760 and :1978;
    - :2015.
  - rule_journal.py:
    - :135-136 and :144/:167-178;
    - :247-276 and :280-296.
  - app_package.py: :95 and :298-300.
  - route_binding.py: :10-12 and :51-57.
  - preflight.py:
    - :33-34 and :59-60;
    - :153-185 and :224-235;
    - :470-517.
  - ndtwin_switch.p4:329-347.
  - s2-runtime-pft.json:267-280.
    - `t_ternary` has the single field `hdr.ipv4.srcAddr` (hc_main.p4:406-411), so the PF-T fixture passes the proposed rules.
  - cells/table.py:306-363 and :916-928.
  - expected_today.tsv, the T4–PF-T rows.
  - tutorials: simple_controller.py:150-168 and helper.py:85-108.
  - The grep claim: `.replay(` and `.quarantine(` are called only from p4_proxy/tests/test_rule_journal.py.
- **Citation slips that change nothing:**
  - §1.4-4 cites :1800-1808 for `insert_ipv4_route`'s fallback, but that range is `insert_5tuple_rule`'s; `insert_ipv4_route`'s is at :1907-1912.
  - "stack.sh" means tools/test_workflow/stack.sh.
- **§6.4's predictions:**
  - T4–T7 GREEN: UNDER-EVIDENCED, and the note flags it (the priority oracle must account for bmv2's inversion, and the collectors are not written).
  - T8 static: SUPPORTED.
  - PF-T GREEN: SUPPORTED.

## Places where the note contradicts itself
1. §7 ships V3, V6-default and read-side optional in Cut A, but their mutants M-J7–M-J9 are in Cut B's acceptance — while also saying "A 可以單獨合併".
2. §7 "A 可以單獨合併" vs §1.7/§6.4: S0 turns red on merge, so the change must go with the health line.
3. §3.2-3 says "rename"; §5.5 step 5 says hard link. Q1(a) says "rename, first call site of quarantine".
4. §5.6 gives readopt "steps 2–5", but step 1 is the only read.
5. §5.6 says only (c) needs a replay before :1743; Q2(b) also leaves baseline ipv4_lpm journaled.
6. §0 and §3.2-1 credit the no-append rule; under §5.5's step order the snapshot erases replay appends anyway.
7. §2.1 says "兩種拼法就是兩種身分", but under §3.2-2 the fold key is spelling-independent.
8. §1.1 says priority 0 on a priority table is unreachable today; the empty-match path in M2.1 reaches it.

The totals agree: §7's line counts add up (300+200+250 = 750; 400+300+400 = 1,100), and the 20 R and 11 M-J are each assigned once.

## Tests and measurements the note should add
- **A0, on a throwaway bmv2:**
  - delete and modify with the wrong priority on `t_ternary`;
  - an omitted EXACT field;
  - lpm /0, mask 0, full range, and a default entry carrying a priority;
  - priority = BM_MAX + 1: error, or process abort;
  - a cookie set on push: read it back with COOKIE_ONLY, and check that a fresh bmv2 has none;
  - an LPM value with host bits set;
  - the byte form of ternary, range and optional values read back.
- **Unit tests:**
  - the empty-match flow_5tuple POST: 200 today, 409 under V7;
  - a POST to switch B while readopt replays switch A;
  - a POST to switch A between readopt's client swap and its replay;
  - an entry POSTed before a restart is present after it (presence, not length);
  - each fold outcome, plus the default-entry rule;
  - `record → False` ⇒ the POST response and switch_state;
  - with V7 in place, an owner-ndtwin table still gets the package's boot default (bring-up C).
- **The mutants listed in M4.**

Verdict: READY AFTER FIXES
