# Judge: P4 ternary writer + table-entry journal design, a3c46bb0 (r2, scoped)

## Scope and method
- I reviewed only the three things asked:
  - §8;
  - whether each r1 MAJOR and each "fix before the form" MINOR is fixed, at the sections §11 names;
  - whether every 【A0 NN】 claim is supported by the raw A0 file it cites.
- I raise new findings only where a §8 statement becomes false. There are no BLOCKERs.
- Read-only. I executed nothing and ran no git.
  - The worktree file has 848 lines; the brief says 845.
  - I reviewed the worktree file as it is and could not check that it matches a3c46bb0.
- Raw A0 files read:
  - INDEX.txt;
  - stock/01, 07 and 08 in full or by status lines;
  - status/error/read lines of stock/03, 04, 05, 06, 09 and 11;
  - the optional section of stock/10;
  - ternary_a0.py:148-160.
- The author's archive (descriptor, pi_strings and grep logs): present, and the first line of each is the commit.
- Files:
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-design/doc/audit/2026-10-04_p4-ternary-journal/DESIGN.md
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/ternary-a0/INDEX.txt
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/ternary-a0/stock/ (01–11)
  - /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/ternary-design/

## 1. r1 items: fixed?
| r1 item | Status |
|---|---|
| M1 (Q1) | FIXED. Q1 now says the proxy *can* tell a warm restart from a fresh fabric. The cookie option is the recommendation and rests on measured facts (A0 08). (c) states the stack.sh gap and withdraws "first call site". One residual hole → N2. |
| M2.1 flow_5tuple fact | FIXED (§0, §1.1, §1.5; Q2 (a), (b), (c)). |
| M2.2 default-action carve-out | FIXED as a sub-choice, (a-i)/(a-ii). Its scope is now ambiguous → N1. |
| M2.3 where V7 lives | FIXED. V7 sits in `write_table_entry`, so boot and replay pass through it (§2.2, §4, §5.2:408). |
| M2.4 fixture cost, ticket rule | FIXED (§1.5, (a-iii)). |
| M2.5 (b) needs readopt replay | FIXED (§5.5:492, Q2 (b)/(c)). |
| M3 | FIXED. See the detail below. |
| M4 | FIXED. See the detail below. |
| Fix-before-form MINORs | All FIXED: Q3; Q4(b); Q5(b); S0 (two checks, PROBE-BROKEN, A only with D: §1.7, §6.4, §7); boot_identity (§5.6); entries sha (§5.2, R15); evidence labels (archived logs, 【A0】 tags, docstring discrepancy, §1.8). The Q3 rewrite introduced one small inaccuracy → N3. |

M3 detail:
- One journal file per switch (§5.2).
- The write path is a single `run_in_threadpool` callable holding a `threading.Lock`; the client is looked up inside the lock; `pending` is checked both before and inside the lock (§5.3).
- Startup needs no 503, and the note cites the right code: main.py:2441-2443, :2469-2511 (§5.4).
- readopt sets `pending` and takes the lock before `topology.readopt_switch`, re-reads the file, and clears `pending` in `finally` (§5.5).

M4 detail:
- §6.1 sets the "red for its own reason" principle and the A1/A2 split.
- R4 now goes red through the empty-match path.
- R12 and R12b cover Q4(a) and the computed `journaled`.
- R13 has one test per fold outcome, plus M-J14.
- R14 checks the entry is present after restart and the quarantine file's bytes, which kills M-J4 and M-J15.
- R20–R22 cover the concurrency hazards; R23 the remaining 501.
- R18 asserts the new sentence.
- M-J7–M-J9 moved to Cut A.

## 2. §8, question by question
- **Q1:** Every option's consequence matches the code and A0 08:
  - push with a cookie, read it back with COOKIE_ONLY (stock/08:8-10);
  - a push without a cookie clears it (:13-14);
  - a fresh bmv2 answers FAILED_PRECONDITION before any push, whether started with the JSON on the command line or with --no-p4 (:4-5, :26-27, :31-32).
  - (b)'s citations hold: power helper p4_power_helper.py:222 and :342; p4_testbed_topo.py:1309.
  - Exception: N2.
- **Q2:** Correct, except N1. I checked whether a baseline default changed to drop would recreate §1.5's catch-all. It does not:
  - ingress applies ipv4_lpm whenever flow_5tuple misses (ndtwin_switch.p4:392-394);
  - `drop` only marks the packet (:288-290).
- **Q3:** Correct and supported by:
  - stock/04:34-40 (lpm /0 refused, nothing stored);
  - stock/04:111-137 (omitted lpm field OK);
  - stock/05:40-46 and :279-285 (mask 0 and whole range refused with "omit…", nothing stored).
  - Exception: N3.
- **Q4:** Correct.
  - The (a) fold example matches A0 02 (MODIFY of an absent entry → NOT_FOUND).
  - The (b) infeasibility argument is right (p4_client.py:1356-1359).
- **Q5:** Correct (p4_client.py:932-946, :1026-1046; main.py:2024-2048).
- No A0 result contradicts a §8 statement.

## 3. New findings (each makes a §8 statement false) — all "fix before the form"

### N1. Q2 (a-i)'s scope is ambiguous, and two statements are false under it
(a-i) says (:681): "owner 為 ndtwin 的表上，default action 開機與 API 都可以寫".
- **The literal reading includes baseline tables.**
  - The baseline binding's owner is "ndtwin" (test_route_binding.py:144).
  - (a) puts every baseline table under V7 (:669-672).
  - So the API could rewrite the defaults of baseline ipv4_lpm and l2_forward. Both are send_to_cpu, which feeds NDTwin's packet-in path (p4_client.py:21-23; ndtwin_switch.p4:377-380).
  - That makes §5.5:491 false ("Q2 (a) 底下 baseline 沒有能寫的表，所以不需要"):
    - a journaled baseline default is replayed at startup, because §5.4's condition includes baseline;
    - it is lost at readopt, which returns at main.py:1743 before any replay.
- **Even scoped to the package's owned route table, (a)'s consequence at :675 is false.** "journal 和 kernel routing 永遠不在同一張表上": under (a-i) the journal holds that table's default while NDTwin writes its routes into the same table. The true statement is "never the same entry", and it rests on the 【推論】 that NDTwin's writers never write defaults.
- **(a-i)'s reason covers only half of it.** "C 依賴它" justifies the boot default. The API half ("開機與 API 都可以寫") has no stated reason.
- **Fix:**
  - scope (a-i) to tables bound by a package's `roles.ipv4_route`;
  - baseline defaults stay 409;
  - reword :675;
  - add an R: an API default write on a baseline table answers 409.

### N2. Q1(a) "ndt up 與 stack.sh 這兩條 bring-up 路徑都涵蓋" (:645) fails for a switch that was down at startup
- **Why it fails:**
  - The cookie check runs only for switches that pass `i not in broken` (:447).
  - readopt skips the check by design: it pushes the header's cookie on the premise that readopt means "同一個 fabric 上這一台剛 power-cycle" (:483).
- **What goes wrong:**
  - A switch that is unreachable, or whose push fails, when a fresh fabric starts keeps the previous fabric's file untouched.
  - Broken switches keep their client (main.py:1988-1995), so they can be readopted later.
  - The later readopt replays that old file. The sha checks don't stop it when the package is unchanged.
  - The readopt push then writes the old cookie onto the switch, so every later restart treats the stale file as current.
- **Related inconsistency in §5.4:**
  - step 2 says it runs "在 push 之前" (:451);
  - but §5.4 places all steps in the entries loop "after apply_package_entries" (:446), and that loop runs after the push (main.py:1977-1986 runs before :2011).
- **Fix:**
  1. Read the cookie for every switch before the push loop.
  2. Quarantine the file of any switch whose cookie isn't confirmed, unreachable ones included. Q1(a) already accepts this trade-off for a power-cycled, not-yet-readopted switch.
  3. Let readopt replay only a file whose header was written or confirmed in this boot. The header already carries `boot_id`. A single fabric-wide generation, as Q1's wording "fabric 世代號" implies (instead of §5.4's per-switch mint), would make the readopt check trivial.
  4. Add the "down at startup" case to Q1(a)'s consequences, and add an R.

### N3. Q3(a) "今天是 502 UNKNOWN（§1.8）" (:702) holds only for lpm /0
- lpm /0 builds today (p4_client.py:1249) and comes back as 502 UNKNOWN.
- A mask-0 ternary field or a whole-range field is a named TERNARY/RANGE field, so today it gets 501 (:1199-1208).
- Fix: one clause.

## 4. 【A0 NN】 claims the raw files do not support
All four are outside §8, so they can wait.
1. **A0 07 tested 13 values**, from 1 to 2^31-1 with both ends included (stock/07:7-733). These overstate it:
   - "全部 OK" (:194);
   - "對每個 priority 都沒有 abort" (:200);
   - "量過整段範圍" (:273);
   - "整段 int32" (§10-7).
   - Say "13 values, both ends included". `PRIORITY_MAX` = 2^31-1 still follows.
2. **§1.5:182's priority-0 claim was not measured for its case.** It says the empty-match path at priority 0 gets INVALID_ARGUMENT 【A0 01、07】. Both items had a ternary field in the match. The no-field entry is unmeasured, and §7 itself lists it as such. Add priority 0 to the Cut A follow-up measurement.
3. **§2.2:282 overstates V6.** It says V6 only repeats bmv2's refusal 【A0 01-07】, but no A0 item tests a non-zero priority on an exact/lpm table.
4. **§0:27 overstates coverage.** It says every local refusal was measured on bmv2 【A0】, but V3 was not, as the note itself says at :193 and :285.

Trivial: stock/06 has no read-back after the two refused INSERTs of a default entry (:119-147, :264-292). So "什麼都沒寫進去" for that case is implied, not shown.

Everything else I checked holds:
- 01/02: NOT_FOUND "Cannot find match entry" and INVALID_ARGUMENT "Zero priority…"; the entry is untouched.
- 03: "Missing non-ternary field…"; nothing stored.
- 06: "Non-zero priority for default entry"; "Cannot use INSERT for default entry"; a wildcard Read skips the default entry.
- 08: as in §2.
- 09: host bits refused on insert and on delete.
- 10: optional reads back as optional (stock/10:452-458).
- 11: the priority-20 entry wins (handle 1, set_mark 0x14).
- §1.8 matches stock/01:89-90 and ternary_a0.py:148-160: top-level UNKNOWN with an empty message, the real code in a per-update error.
- `_grpc_status_name` reads only `code()` (api_routes.py:235-242); nothing in proxy_agent parses trailing metadata.

## 5. Remaining MINORs, sorted
- **Fix before the form:** N1, N2, N3.
- **Can wait:** the §4 wording items 1–4 and the stock/06 note.

Verdict: READY AFTER FIXES
- Q1(a), Q2(a-i)/(a) and Q3(a) each need a scoping or wording fix.
- §5.4/§5.5 need the confirmed-cookie rule for switches that were down at startup and for readopt.
- Nothing else in §8 changes.
