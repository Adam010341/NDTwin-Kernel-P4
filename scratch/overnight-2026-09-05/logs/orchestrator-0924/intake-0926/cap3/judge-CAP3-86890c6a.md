# JUDGE: third cut kernel 86890c6a

**Kernel `feat/kernel-capabilities-0927` @ 86890c6a: MERGE AFTER FIXES.**
- **What holds:** the code does what Appendix A says, the locking is correct, the bmv2 liveness path is unchanged, and the red → green → mutation evidence stands up.
- **Blocking (two items):**
  - **B1:** the repo's own L4 OVS/P4 differential gate will fail on the first P4 capture taken with this kernel. The fix is one allowlist line.
  - **B2:** nobody has built or tested the actual merge with trunk 18c83aba. All the evidence is from GCC with `-O0` and no debug info, on the old base 3d740be0.

**GUI `draft/p4-capabilities-0924` @ 4494473: the draft is sound; not for merge now.** Before any PR:
- rerun the node tests at the committed sha;
- confirm the commit contains no `node_modules/` or `dist/` (the worktree has no `.gitignore`).

**How I checked:** read-only (Read/Grep/Glob), no git, nothing executed.
- I compared the summary's claims against:
  - the head files in `wt-third-cut-0927`;
  - the base code in the main checkout;
  - the logs;
  - the contract: I read only TICKET-P4-roles.md Appendix A (:182-189), §2.5-2 (:116-126) and ruling 5(b) (:246).
- I spot-read the raw live `switch_state` JSON files the summary cites.
- Claims that only git could settle are marked UNTESTED below.

## 1. What holds (your checks 1–9)

**1. Contract fidelity: holds.**
- **Copied verbatim:** `out.emplace(*dpid, *capsIt)` (P4Capabilities.cpp:75) copies the whole object. Unknown keys and `null` values survive (tests :225-240, :264-278).
- **Switch nodes only** (P4Capabilities.cpp:83-86). A host whose dpid collides with a described switch is tested both in the pure function (:317-325) and on the wire (:512-515, :529-533).
- **Absence rules:**

| Case | Code | Test / mutant |
|---|---|---|
| OVS fabric | DCPM.cpp:792 | test :462-474, :575-589 |
| Before the first answer | empty by default (DCPM.hpp:1200) | no dedicated test (trivially true) |
| Last read failed | DCPM.cpp:800-804 replaces the record on every tick, including nullopt | test :476-489, M12 |
| `capabilities` is null or not an object | P4Capabilities.cpp:63, :71 | test :250-262, M2 |
| dpid not in the record | P4Capabilities.cpp:87-91 | test :307-315, M9 |
| Key not plain decimal | P4Capabilities.cpp:19-42 | "0x2", "+3", " 4", "5x", "", 2^64 at test :280-292; M5, M6 |

- **Nothing is invented:** no code path creates `{}` or `null`. M7 and M9, the two mutants that do, are killed.
- **The proxy really sends null** for a dpid it has no record for (api_routes.py:805).
- **Nothing the GUI relies on differs.** The GUI treats absent, `null` and `{}` as "nothing disabled" (p4Capabilities.ts:79-85, :102-103). The body the GUI tests against is the kernel's own output (the xml property at :1700 equals `p4Capabilities.kernel-graph.json`).

**2. Concurrency: correct.**
- There are exactly two accesses to `m_p4Capabilities`, both under `m_p4CapabilitiesMutex`:
  - the write (DCPM.cpp:801-804): the new map is built outside the lock (:800) and moved in under it;
  - the copy-out read (:811-812).
- **No nested locks:** the graph copy (HttpSession.cpp:1416) and the snapshot (:1423-1426) happen one after the other.
- **Destruction is safe:** the destructor calls `stop()`, which joins the ping thread (DCPM.cpp:187-190, :221-224) before the members are destroyed.
- **Liveness is unchanged.** Base DCPM.cpp:959-963 against branch :994 plus :789-806 shows:
  - same guard, one fetch, and the same payload reaches `p4VerdictFor` (:1052);
  - the only line that calls `fetchP4SwitchState` is :794;
  - the only added work is a parse and a lock, which can only throw on allocation.
- **Making `fetchP4SwitchState` virtual is safe:**
  - the constructor (DCPM.cpp:45-61) doesn't call it, and the destructor only joins threads;
  - the class already had virtual functions (DCPM.hpp:683, :1031-1037), so the only change is one more vtable slot;
  - overriding a private virtual is legal (test :342-347);
  - the class can't be copied (it holds mutexes), so slicing is impossible;
  - the test peer class name is unique (HttpSession.hpp:144; test :72).
  - One older hazard remains: a derived object that was *started* and then destroyed without an explicit `stop()` would make virtual calls from the ping thread during its own destruction. `ProxyStandIn` is never started (test :33-37).

**3. Red-first and mutation: holds.**
- **Red run:** unit-red.cap3-91fa028d.log (head 91fa028d, clean tree) shows 15 run, 6 pass, 9 fail, rc 1 (:8, :103-117). Every failure is an empty record or a missing key, not a fixture load problem. The data-plane-kind and vertex-count asserts passed.
- **Mutation gate:** mutate_p4_capabilities.cap3-86890c6a.log (head 86890c6a, clean tree) reports baseline green with 15 tests (:5), 15 mutations, 0 survived, control green, rc 0 (:74-75).
  - The gate enforces the *named* killer, not just "something went red" (sh:413-418). A mutant that fails to compile, or whose anchor isn't unique, counts as a survivor (:370-373, :389-394).
  - Every one of the 15 tests has been seen red at least once. The six that were green on the stub went red under M2, M7, M8, M9 and M10.
  - All 15 mutations target real contract behaviour. M6 and M7 only create a dpid-0 entry, so they are caught at the parser level and would not show on the wire. The realistic wrong implementations you listed are all killed: keeping the last good read (M12), attaching `{}` (M9), attaching to hosts (M8), and accepting "+3" or " 4" (M5).
  - Survivors I expect are listed under N4.

**4. The `pingWorker` call line and the build type.**
- **Call line:** the summary is right that it can't be tested offline. Its argument for why that doesn't matter is wrong: see N3.
- **Build type:** the deviation doesn't affect the results.
  - Debug adds only `-g` and `-DDEBUG_BUILD` (CMakeLists.txt:75), and `DEBUG_BUILD` appears in no source file.
  - GCC's `-g` does not change the generated code.
  - `NDEBUG` is undefined in both build types.
  - The red, green and mutation runs all used the same build directory.

**5. API doc (doc/2026-01-02_ndt_api.md:599-637): accurate.** I checked each claim against the code:
- the 501 and 409 refusals match api_routes.py:172-219 and :537-540 / :610-613 / :643-646;
- "200 queued" matches HttpSession.cpp:1948-1990 and :2443;
- the value lists match main.py:1151-1171 and :1284-1293.

It promises nothing the code doesn't do. Wording gaps are in N7.

**7. Logs.** Every number in §4 and §5 is present in the named log and tagged with the right sha. Exceptions: N9, and the internal inconsistencies in section 5.

**8. Discipline: holds.**
- **Co-developed tags:** present on every new file and every changed block.
- **No pkill/pgrep:** none anywhere. The three self-kills were by process group and are logged (build-red:5, :11; webgui-build wt log:6).
- **Temp paths:**
  - the test uses `TempDir()` plus the process id (:384-386), and deletes the file in TearDown;
  - the gate uses `mktemp -d` (:289-290) and cleans up in its exit trap.
- **Gate safety:**
  - the exit trap restores the three source files and touches them so ninja rebuilds (:293-307);
  - the baseline must build and be green first (:348-360);
  - at the end the tree is rebuilt, compared byte-for-byte to the snapshot, and rerun green (:427-446).
  - It does not survive SIGKILL. It relies on the wrapper's "dirty: 0" header rather than checking the tree itself. No mutant residue remains in the worktree.

## 2. Findings

### Blocking

**B1. The L4 differential will fail on the first P4 capture taken with this kernel.**
- **Why it fails:**
  - `compare_baseline.py` records every field path in both captures (`shape()`, :54-85).
  - It reports any field that exists only on the P4 side as `extra field in P4: nodes[].capabilities.<key>` (:349-352).
  - Any difference not in the allowlist makes it exit 1 (:400-405). The allowlist header (:5) says so: "fails on any difference not listed here".
  - `run_layers.sh full p4` runs L4 whenever both captures exist (:669-670).
  - Captures save the raw response body (run_contract_test.py:716-718).
- **Result:** OVS never carries the key, so this produces five failures by design. The branch neither fixes nor mentions this.
- **Fix:** one line in `tools/contract_test/baseline_diff_allowlist.txt`, for example:
  `get_graph_data | extra field in P4: nodes\[\]\.capabilities\. | per-switch capabilities exist only on bmv2 (API doc §3); OVS never carries the key`
  This still leaves a type change or a missing key visible.
- This is inferred from reading the code; I did not run it.

**B2. The merged tree has no evidence.**
- Every build and test ran on base 3d740be0 with GCC, `-O0`, no debug info.
- Trunk 18c83aba's last merge exists because clang's `-Wdelete-non-abstract-non-virtual-dtor`, an error under `-Werror`, rejected `make_shared` of this exact class and a derived test probe (main checkout DCPM.hpp:153-161).
- This branch adds another derived probe built with `std::make_shared<ProxyStandIn>` (test :333, :411). On the branch alone the destructor is still non-virtual (wt DCPM.hpp:157).
- On the merged tree trunk's virtual destructor should cover it, but "merges without conflict" is not "builds green".
- **Required before merge:** run the full `test_routing_strategy` on the merge commit under GCC and under trunk's clang and TSan jobs, plus `check_gate_anchors.py` and `mutate_p4_capabilities.sh` on the merge head.

### Notes (should fix; not blocking)

**N3. The §6 argument is wrong (summary :149).**
- Deleting DCPM.cpp:994 does not compile, because `p4SwitchState` is used at :1052. So "delete it and liveness breaks too" is not a change anyone could ship.
- The realistic regression is reverting that line to a direct `fetchP4SwitchState()` call, for example while resolving a conflict with a branch that still has the old block (base :959-963).
  - Liveness keeps working and capabilities silently disappear.
  - No offline test catches that, and no live liveness check does either; only the live checks C1–C4 in §7 would.
- **Cheap guard:** a static wiring check in the style of the existing `mutate_rule_journal_is_wired.sh`: `fetchP4SwitchState(` has exactly one call site, inside `pollP4SwitchState`, and `pingWorker` calls `pollP4SwitchState()`.

**N4. Mutants I expect would survive today:**
- **Lookup by `vertex.mac` instead of `dpid`:** every switch fixture has mac equal to dpid (test :189, :361).
- **Copying capabilities only for switches with `probe_ok` true:** every fixture entry has `probe_ok` true (:143).
- **Removing either lock:** nothing runs the poll and the snapshot concurrently, and the tests are single-threaded, so TSan wouldn't see it either.
- **Keeping the old record when the proxy answers 200 with a body that has no `switches`:** only the nullopt case is tested (:483).

**N5. Nothing bounds the age of the record.**
- It is only refreshed when the ping loop ticks. If the loop stalls, the last answer is served indefinitely.
- One way to stall it: `sudo ovs-vsctl list-br` runs every tick in MININET mode, P4 fabrics included (DCPM.cpp:915-927), and it has no deadline (comment :919-922).
- The doc says the key is absent "whenever the kernel's most recent read of the proxy failed" (API doc :628; DCPM.hpp:340-344). That doesn't cover "no read happened at all".
- Liveness already has the same weakness. Timestamp the record, or document it.

**N6. `spec.py` convention.**
- Leaving the values unpinned is right.
- But every other key added to `GRAPH_NODE` is listed in `optional` specifically to pin its type and vocabulary (spec.py:437-477, especially :469-470).
- With no entry, the live L2 contract test cannot catch a kernel that serves `capabilities: null` or a string, which is exactly the invariant this feature depends on.
- Add `"capabilities": Obj({}, strict=False)`.

**N7. API doc wording** (not wrong, just loose):
- `heartbeat` is listed (:623) without saying what it means.
- "neither checks nor rewrites" (:604): the kernel does drop anything that isn't an object (P4Capabilities.cpp:71).
- The absence list (:626-630) leaves out TESTBED mode, mixed OVS+bmv2 fabrics (the proxy is never asked; DCPM.cpp:141, :792), and a stalled poll (N5).
- "Verbatim" means equal as JSON values; nlohmann re-sorts the keys, so a byte-for-byte diff would not match.

**N8. The test file changed after the red run, and the summary doesn't say so.**
- The summary (:20) describes c0347b15 as implementation plus API doc plus gate. `tests/test_P4Capabilities.cpp` also changed in that commit. The evidence:
  - the red log reports failing asserts at lines :539 and :568 (unit-red :84-88, :91-95);
  - at head the same asserts are at :542 and :571, and every line up to :503 is unchanged;
  - build-green :13 recompiles `test_P4Capabilities.cpp.o`.
- The three extra lines match the `RecordProperty` block at :521-523, which asserts nothing, so red-first still holds.
- Confirm with `git diff 91fa028d c0347b15 -- tests/test_P4Capabilities.cpp` and disclose it.

**N9. Evidence storage.**
- "63 sudo calls refused" (summary :104) rests only on `…/scratchpad/third-cut/nosudo/attempts.log`: 63 identical lines, no timestamps, outside `logs/gates-0910`, in a scratchpad that won't persist. Copy it next to the unit-full log.
- The `ANCHOR_CHECK=1` run has no log of its own. The gate log's per-mutation anchor counts effectively replace it.
- build-red:2 has a stray `rc=0` from a killed attempt. The summary discloses this.

**N10. Nits.**
- The test and the gate cite `doc/audit/.../TICKET-P4-roles.md` (test :7, sh :4). PRs to main exclude `doc/audit/**/*.md` under CLAUDE.md; API doc §3 is the public spec, so cite that instead.
- The test unsets `NDTWIN_TOPO_FILE` (:421) instead of restoring its previous value. This matches two existing tests.
- The test header says "Nothing here shells out" (:33), but starting the monitor launches a Ryu poll thread. The header acknowledges this at :34-37.

## 3. The five §8 readings

**(1) Fail-open for about 1 s after one failed read: reasonable, and it is the literal reading.**
- The ticket says that in P4 mode, if the kernel can't read the proxy, it doesn't carry the field (TICKET :184).
- Cost: the GUI offers an operation the proxy then refuses (501 or 409), and the failure shows in `get_flow_dispatch_status`.
- The GUI polls at 1 Hz with no smoothing (GraphDataManager.tsx:31), so one failed read un-greys roughly one frame.
- Liveness does the opposite on the same failure, holding the last state as Unknown (DCPM.cpp:1085-1090). That is deliberate: each falls back to its own documented default.
- Nothing in the repo contradicts this reading. The real gap is the opposite case (N5).

**(2) A non-object value is treated as absent: reasonable.**
- It is needed in practice, since the proxy sends null for dpids it has no record for (api_routes.py:805).
- The GUI already treats null as absent (test.ts:71-74).

**(3) Mixed OVS+bmv2 fabric carries no key: reasonable.**
- It inherits the existing all-bmv2 rule (DCPM.cpp:141) and fails open.
- The ticket's "mixed fabric" (:126) means mixed pipelines on bmv2. That is still all-bmv2 and does get the key, so there is no contradiction.
- It belongs in the doc (N7).

**(4) GUI shows no hint for `heartbeat`: reasonable.**
- The proxy only says `heartbeat` when the heartbeat reading is usable, and otherwise falls back to `declared` (main.py:1287-1293). So the `declared` hint comes back by itself when detection stops.
- `reroute` is still hinted independently.
- `none` is hint-only, as ruling 5(b) says (p4Capabilities.ts:127; M30).
- The proxy's own vocabulary comment (main.py:1088) still omits `heartbeat`, but that is a proxy-side staleness.

**(5) Not pinning `capabilities` in the contract test.**
- On values: agreed.
- On the type: the repo's own `spec.py` convention says to list it (N6).

## 4. Each claim in the summary

| Claim (summary line) | Class | Basis |
|---|---|---|
| Appendix A met literally, no deviation (:11) | SUPPORTED | P4Capabilities.cpp:50-92; DCPM.cpp:789-806; tests plus gate |
| One proxy request per tick feeds both capabilities and liveness (:43) | SUPPORTED | DCPM.cpp:994; :794 is the only call |
| Mutex; ping thread writes, HTTP reads (:44) | SUPPORTED, by inspection only | :801-804, :811-812; nothing tests it concurrently |
| No existing key changed, compared "bit by bit" (:45) | SUPPORTED, overstated | test :550-573 compares JSON values against a session with no power manager at the same head, not bytes against the old binary |
| Kernel output for fixtures ①–④ (:51-70) | SUPPORTED | xml:1700 |
| ②③④ equal the live proxy output (:72) | SUPPORTED | 20_switch_state.json:193-199; 30_…:92-98; 71_…:93-99 |
| GRAPH_NODE is non-strict, so the new key passes (:49) | SUPPORTED as a fact | spec.py:425-478 (see N6, B1) |
| Red run: 9 red, 6 green, for the right reasons (:101) | SUPPORTED | unit-red:8, :12-117 |
| The six stub-green tests get their red from widening mutants (:102) | SUPPORTED after the fact | gate log :11-45 |
| Full suite 1381/1381 at c0347b15 (:103) | SUPPORTED | unit-full:1, :7, :3285, :3287; not rerun at 86890c6a |
| 63 sudo calls refused, suite still green (:104) | UNDER-EVIDENCED | N9 |
| Gate result "not yet available" (:107) | Now SUPPORTED as a pass | gate log :1, :74-75 |
| Expected killers match the red/green pattern, inferred (:108) | SUPPORTED after the fact | every named killer went red |
| 16 anchors unique, 13 distinct (:110) | SUPPORTED indirectly | gate log shows 16 anchors at 1 occurrence each; anchors log :98 `ok(13)` |
| check_gate_anchors ×4 and both builds rc 0 (:135-140) | SUPPORTED | the logs' summary lines |
| No-debug-info `-O0` gives the same results as Debug, inferred (:143) | SUPPORTED | §1 item 4 |
| The `pingWorker` line can't be tested offline (:149) | SUPPORTED | it needs `start()`, which shells out |
| …but deleting it breaks liveness too, so a live check catches it (:149) | CONTRADICTED | N3 |
| c0347b15 contents (:20) | UNDER-EVIDENCED | N8 |
| 3 commits, message style, not pushed (:17, :20, :22) | UNTESTED by me | git-only |
| GUI: red 2/21; kernel-body red 2/2; green 23/23; 31 mutants killed, 2 controls green; files restored (:114-127) | SUPPORTED | GUI logs, but the green run is on "1abd9dc + uncommitted" |
| GUI type-check and build "not yet available" (:128) | Now SUPPORTED as a pass | webgui-build.cap3-4494473.log:1, :27-28 |
| pnpm install with frozen lockfile; hashes unchanged (:129) | SUPPORTED | install log :1, :31-32 |
| GUI components will show the new hint automatically (:150) | UNTESTED (acknowledged) | the wiring exists (FlowTablePanel.tsx:268-271; LinkInformation.tsx:443-445) |
| Live behaviour (:148) | UNTESTED (acknowledged) | the §7 plan |

## 5. Tests I would have run, and inconsistencies in the summary

**Tests I would have run:**
1. The full suite at 86890c6a. Only the 15 new tests ran at the final head.
2. The merged tree under GCC, clang and TSan (B2).
3. `compare_baseline.py` on a saved OVS/P4 pair with the key present (B1).
4. A two-thread poll-versus-snapshot test under TSan.
5. Fixtures with mac different from dpid, an entry with `probe_ok` false, and a second poll that returns `{}`.
6. The `pingWorker` wiring check (N3).
7. `tests/shell/check_test_tmpdirs.py tests/test_P4Capabilities.cpp`. It should pass, since the path includes the process id.
8. The L2 contract test with the N6 entry.
9. Live checks C1–C6. C6 is the only check for the fail-open window.
10. The GUI tests at 4494473.

**Inconsistencies in the summary's own text:**
- §0 (:11) says there are three "Appendix A is silent" readings; §8 (:171-175) lists five.
- Free disk at start of work is 4.8 G in §5 (:143) but 5.4 G in §10 (:184). The log headers show 4.8G at 15:38Z.
- §2 (:45) says "bit-by-bit"; the test does JSON-value equality (:572).
- The "no evidence yet" entries at :107 and :128 are now out of date.
- These are internally consistent:
  - the diff stat (per-file changes sum to 1358 = 1350 + 8);
  - the new-file line counts (61, 95, 454, 589).

## 6. GUI (separate; not being merged now)

**Verdict:** the draft is sound. Before any PR, do the two checks in the opening lines.
- **Rules match Appendix A and ruling 5(b):**
  - absent, `null` or a missing key disables nothing (p4Capabilities.ts:79-85, :102-103, :173-186);
  - `ipv4_route != "ndtwin"` greys route writes (:105-108);
  - `five_tuple != true` greys 5-tuple writes (:109-112);
  - link-failure injection is never disabled (:113);
  - hints come from `reroute`, `declared` and `none` (:124-127).
- **Red-first:**
  - 2 of 21 tests were red against the old module, for the right reasons (unit-red :113-128, :152-158);
  - the `heartbeat` test gets its red from mutant M29 (mutants log :33);
  - the kernel-body tests were 2/2 red against a synthetic body with `capabilities` stripped out.
- **Mutation and build:**
  - 31 mutants killed, 2 controls green, 5 files restored (mutants log :39-47);
  - `tsc -b && vite build` rc 0 at 4494473 with no tracked changes.
- **Unit and mutant runs are not tied to the commit:** they ran on "1abd9dc + uncommitted", not on 4494473. The per-file sha256 values in the mutants log (:39-43) can be matched against the commit's blobs.
- **Commit hygiene:** the worktree has no `.gitignore`; the install log (:37) shows `?? node_modules/`, and the build created `dist/`.
- **Tooltip wording:** in external mode the proxy reports `unbound` or `package` (main.py:1153-1157), so the route-write tooltip gives that reason instead of "external control plane". The separate `no_link_discovery` hint does name it.

## Files
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/src/ndt_core/power_management/P4Capabilities.cpp
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/src/ndt_core/http/HttpSession.cpp
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/tests/test_P4Capabilities.cpp
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/tests/shell/mutate_p4_capabilities.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/doc/2026-01-02_ndt_api.md
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/tools/contract_test/compare_baseline.py
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/tools/contract_test/baseline_diff_allowlist.txt
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/tools/contract_test/spec.py
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-third-cut-0927/tools/test_workflow/run_layers.sh
- /home/adam/Desktop/NDTwin-Kernel/include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp (trunk, virtual destructor :153-161)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/ (the `*.cap3-*` logs)
- /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/third-cut/nosudo/attempts.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-webgui-third-cut-0927/src/utils/p4Capabilities.ts
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/THIRD-CUT-SUMMARY.md