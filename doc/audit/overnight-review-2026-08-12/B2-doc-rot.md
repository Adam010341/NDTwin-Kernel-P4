# B2 — Documentation rot scan (2026-08-12 overnight)

Base commit: `5d53cf0` (worktree was created at `8b61cdc` = upstream lab tree; reset to `5d53cf0`, `tests/` present, 60+ files).
Range scanned: `b0a7bdc..5d53cf0` (17 commits).
Mandate: **record only, no edits.** VLAN item already filed as issue #3.

## TL;DR

**Scan complete.** Every reference was opened, not trusted. Scope: 4 documents changed in `b0a7bdc..5d53cf0` (`doc/p4_bmv2_support_plan.md`, `doc/phase7_power_mechanism_design.md`, `doc/test_coverage_gaps.md`, `p4_proxy/reference/README.md`), the comments/message strings touched by the same range, and one transitive hop.

**The three mandated items all pass.** `5d53cf0` (VLAN symbols), `3a312e3` (502 readopt message) and `c4505e9` (twin-liveness) each verify clean — every symbol definition, endpoint, HTTP method, constant and quoted docstring exists and says what the prose claims. `5d53cf0` in particular did what it set out to do: `calFlowPathByQueried` and `packKey` are real definitions, and the grep anchor it supplies has **exactly one hit**, as advertised.

**Fix before working from the docs (P1 — these misdirect an operation):**

1. `doc/p4_bmv2_support_plan.md:398` — "**專案根目錄的** `dump_table.py`". Moved today; now `p4_proxy/reference/dump_table.py`.
2. `doc/test_coverage_gaps.md:430` — "`p4_proxy/test_10_routes.py`". Now `p4_proxy/reference/test_10_routes.py`.

**Worth a look (P2 — conclusion right, stated mechanism wrong or superseded):**

3. `p4_proxy/reference/README.md:16-18` — "NO TESTS RAN … counts as a failure" is **not true of the runner it names**: `l1_unit_tests.sh:194-197` does not increment `FAILURES`; the branch that does is the *other* runner at `:322-324`. The decision to keep the scripts out of `p4_proxy/tests/` is still right, via `rc != 0` at `:190-193`.
4. `doc/phase7_power_mechanism_design.md` — **all three** `計劃 §` cross-references (`§452`, `§456` ×2, `§479` ×2) land on unrelated plan lines; correct targets are **507 / 511 / 537**. Already wrong before today's range.
5. `doc/test_coverage_gaps.md:452-459` — asserts crash messages sit in the log-check blind spot. `--ignore-unparsed` is **no longer passed at all** by `run_logcheck`, and the same document contradicts this at line 391.
6. `doc/test_coverage_gaps.md:484-487` — the `printf`-into-stdin fragility no longer exists; `stack.sh:606` launches the kernel with `--mode/--topology/--no-ai`.

**Not rot, deliberately cleared:** the plan doc's 未修 twin-liveness entry vs phase7's 已修 — **both correct**, the fix was proxy-side only and `TopologyAndFlowMonitor.cpp:565` still sets `isUp = true` unconditionally. Port layout across all four docs is clean (kernel `:8000`, proxy `:8081`); every surviving `8080` is explicitly framed as history. The `p4_proxy/venv/bin/python` command in the new README is valid — it only looks missing from a worktree because `venv/` is gitignored.

**Everything else is locator drift, not misinformation:** ~15 rotted line numbers in the plan's `6f32bca`-era bug table and ~4 in `test_coverage_gaps.md`, where the *claims* still hold and only the line numbers moved (details in §7). Three stale test counts (§8). One dead link (`tests/test_P4RoutingStrategy.cpp`) and one out-of-range range (`P4RoutingStrategy.cpp#L29-L33` into a 30-line file).

---

## 1. Mandated item A — VLAN warning re-pointed at symbols (`5d53cf0`)

Verdict: **OK, all four anchors hold.** This commit did exactly what it claimed.

| Anchor in the comment | Verification | Result |
|---|---|---|
| `FlowLinkUsageCollector::calFlowPathByQueried` | `grep -rn calFlowPathByQueried src/ include/` → **definition** at `src/ndt_core/collection/FlowLinkUsageCollector.cpp:2493`; declaration `include/ndt_core/collection/FlowLinkUsageCollector.hpp:294` | **OK** (def, not just call site) |
| grep anchor `` `ndtClassifier::FlowKey fk{}` -- the only hit in the file `` | `grep -c` in that file → **1**; located at line 2542 | **OK** — "only hit" is literally true |
| `packKey` … "serialised into the key by **packKey above**" | def at `src/ndt_core/collection/Classifier.cpp:154`; the VLAN comment sits at line 797 → 154 < 797, so "above" is correct | **OK** |
| Commit msg: "the companion note … pushed the line to 2542" | anchor found at exactly 2542 | **OK** — the commit's own account of the rot is accurate |

**Note (not rot, but worth Adam's eye) — the fix is one-sided.**
`5d53cf0` touched **only** `Classifier.cpp` (`git show --stat 5d53cf0` → 1 file, +10/−4). The *other half* of the same warning pair, added by `902d1ab` inside `calFlowPathByQueried`, still cites a **line number** into the other file:

```
src/ndt_core/collection/FlowLinkUsageCollector.cpp:2538
    // agreement is load-bearing -- vlanTci is serialised into the key (Classifier.cpp:168),
```

Checked that line: `awk 'NR==168' src/ndt_core/collection/Classifier.cpp` →
`    writeU16Be(out.bytes, 20, k.vlanTci);`

- **Observation:** the citation is **currently correct** — 168 really is the vlanTci serialisation line.
- **Inference:** it survived only by luck. `5d53cf0`'s +6 net lines all landed at ~794-806, i.e. *below* 168. The next edit above line 168 rots it, and it is the exact citation style `5d53cf0` was written to eliminate. Symmetric treatment would be to name `packKey` here too.
- Severity: **note** (cosmetic today, latent tomorrow). Records only — issue #3 covers the VLAN topic.

## 2. Mandated item B — the 502 readopt message (`3a312e3`)

Verdict: **OK — endpoint exists, path and method both match.**

Checked at the **route registration**, not by grepping the assembled URL (the message builds it by concatenation, so a whole-URL grep would have missed it):

| Claim in the 502 string | Verification | Result |
|---|---|---|
| endpoint `/p4/readopt/{dpid}` exists | `grep -rn readopt p4_proxy/proxy_agent/` → `p4_proxy/proxy_agent/api_routes.py:161: @router.post("/p4/readopt/{dpid}")`, handler `def readopt(dpid: int)` at :162 | **OK** |
| method is **POST** | decorator is `@router.post`; kernel sends `curl -sS --fail-with-body -X POST` (`P4PowerStrategy.cpp:82`) | **OK** — both POST |
| path is not silently prefixed | `p4_proxy/proxy_agent/api_routes.py:8: router = APIRouter()` (no `prefix=`) and `p4_proxy/proxy_agent/main.py:33: app.include_router(api_routes.router)` (no `prefix=`) → mounted at root | **OK** |
| host:port resolves correctly | `setting/AppConfig.hpp.example:10: P4_PROXY_IP_AND_PORT = "localhost:8081"`; proxy binds `p4_proxy/proxy_agent/main.py:303: uvicorn.run(app, host="0.0.0.0", port=8081)` | **OK** — 8081 both sides |

Assembled string an operator would paste: `POST http://localhost:8081/p4/readopt/<dpid>` — **valid**.
The same URL is built identically at the actual call site (`src/ndt_core/power_management/P4PowerStrategy.cpp:82-84`) and in the failure message (`:120-122`), so advice and behaviour cannot drift apart.

## 3. Mandated item C — twin-liveness record (`c4505e9`)

Verdict: **OK — every claim in the doc matches the code, including the "not covered" transient.**

| Claim in `doc/phase7_power_mechanism_design.md` | Verification | Result |
|---|---|---|
| fix adds `TopologyManager.connected_switch_dpids()` | **def** at `p4_proxy/proxy_agent/topology_manager.py:1002` | **OK** |
| the caller was the contract-breaker, now fixed | `p4_proxy/proxy_agent/api_routes.py:49: return ryu_topology.render_switches(topology.connected_switch_dpids())` — no longer `switches.keys()` | **OK** |
| "只有明確的 `False` 才排除" | `topology_manager.py:1031: if (self._last_probe.get(dpid) or {}).get("ok") is not False` | **OK** — literally `is not False` |
| read under `_liveness_lock` | `topology_manager.py:1029: with self._liveness_lock:` immediately wraps it | **OK** |
| `render_switches`' docstring "was always right" (quoted) | `p4_proxy/proxy_agent/ryu_topology.py:81`: "…a switch the proxy cannot reach does not appear, so the…" | **OK** — quote is accurate |
| residual transient bounded by `kLldpFreshSeconds = 12.0` | `include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp:259: static constexpr double kLldpFreshSeconds = 12.0;` | **OK** — value is exactly 12.0, so the "9.2 s / 8.1 s both under 12 s" argument stands |
| `p4LivenessFor` three-state, fresh beacon + failed probe → Unknown | **def** `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:367`; policy documented at `…hpp:365` ("`probe_ok` false, but a beacon … within kLldpFreshSeconds ->") | **OK** |

**Cross-doc consistency check (the one that could have gone wrong).**
`doc/phase7_power_mechanism_design.md` marks this **fixed** (`32afeb9`), while `doc/p4_bmv2_support_plan.md:503-504` still lists it as **未修** ("拓樸輪詢對死掉的 switch 週期性寫回 `is_up=true`（`updateSwitches` 無條件標 up…）"). These look contradictory but are **both correct**, because the fix was proxy-side only:

- proxy side fixed — verified above.
- kernel side **still unconditional**, verified: `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:514` is `updateSwitches`, and at **:565** it does `(*m_graph)[*vertexSwitchOpt].isUp = true;` with no liveness predicate (only a `findSwitchByDpidNoLock` success check).

So the plan doc's "機制已釘死，修法待裁決" is accurate about the kernel, and phase7's "已修" is accurate about the proxy. **No rot.** (Observation: both statements true. Inference: a reader skimming only one file could conclude the other is stale — worth one clarifying clause, but nothing is wrong.)

---

## 4. P1 — stale file paths left by today's relocation (`3fc42ed`)

`3fc42ed` moved five hand-run scripts from the repo root to `p4_proxy/reference/`. Verified the new home:

```
ls p4_proxy/reference/
  README.md  check_env.py  dump_table.py  test_10_routes.py  test_modify.py  test_modify_error.py
ls test_modify_error.py            # repo root
  ls: cannot access 'test_modify_error.py': No such file or directory
```

Two documents still point at the old location. **Both are P1: an operator following them runs a command that cannot find its file.**

| # | Document | Reference | How checked | Verdict |
|---|---|---|---|---|
| **P1-1** | `doc/p4_bmv2_support_plan.md:398` | "**專案根目錄的 `dump_table.py`** 已經有 P4Runtime 讀表的邏輯" | path check: no `dump_table.py` at repo root; it is at `p4_proxy/reference/dump_table.py` | **ROT** — "專案根目錄" is now false |
| **P1-2** | `doc/test_coverage_gaps.md:430` | "`p4_proxy/tests/test_p4_client.py` 和 **`p4_proxy/test_10_routes.py`** 存在" | `p4_proxy/test_10_routes.py` does not exist; it is at `p4_proxy/reference/test_10_routes.py`. (The sibling `p4_proxy/tests/test_p4_client.py` **does** exist — that half is fine) | **ROT** — one of the two paths |

Swept the whole repo for the other three names; the remaining hits are in `doc/audit/` (`00-workflow-plan.md:1113,1137`, `commit-review-2026-08-08/p4-proxy.md:119-120,276,339`). Those are dated audit records and `3fc42ed` deliberately left them alone ("Several audit documents cite them and those are historical records") — **classified as history, not rot**, consistent with the commit's stated policy.

### Also verified clean in the same area

- `doc/p4_bmv2_support_plan.md:517` — the Phase 8 entry describing the move: new path `p4_proxy/reference/`, "port 已修成 8081", "`__file__` 解析" — **all three confirmed** (`p4_proxy/reference/test_10_routes.py:9: PROXY_URL = "http://127.0.0.1:8081/stats/flowentry/add"`; `test_modify_error.py` resolves from `__file__`). **OK.**
- `p4_proxy/reference/README.md:42` run command `p4_proxy/venv/bin/python …` — absent in this worktree, but `p4_proxy/venv/` is gitignored (`.gitignore:16`) and the interpreter **does exist** in the real checkout (`/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python`). **OK — not rot.** Flagging that I nearly recorded a false positive here; a worktree cannot see gitignored files.
- README's "none of them contains a single test case" — `grep -c "def test_\|unittest\|TestCase"` on all three `test_*.py` → **0, 0, 0**. **OK.**
- README's glob claim — `tools/test_workflow/l1_unit_tests.sh:176: for testfile in "$PROXY_DIR"/tests/test_*.py; do`. **OK.**

## 5. P2 — claims whose conclusion is right but whose stated mechanism is wrong

These will not misdirect a command, but each one teaches the next reader something untrue.

### P2-1. `p4_proxy/reference/README.md:16-18` — "NO TESTS RAN … counts as a failure"

The README (and `3fc42ed`'s commit message) justify keeping the scripts out of `p4_proxy/tests/` like this:

> "…reports a file that runs no tests as **NO TESTS RAN** — which that runner counts as a failure, not a skip."

**Observation.** `tools/test_workflow/l1_unit_tests.sh` has **two** python runners and they disagree on exactly this point:

| Runner | Location | `ran -eq 0` branch | Counts as failure? |
|---|---|---|---|
| `p4_proxy/tests/test_*.py` (the one cited) | glob at :176, branch at **:194-197** | prints yellow `NO TESTS RAN` | **No** — `FAILURES` is *not* incremented |
| `tests/python` + `tests/shell` | branch at **:322-324** | prints yellow `NO TESTS RAN` | **Yes** — `FAILURES=$((FAILURES + 1))` at :324 |

`FAILURES` is what decides the exit status (`:348 if [[ $FAILURES -gt 0 ]]`). So for the runner the README names, NO TESTS RAN is a warning, not a failure.

**Inference (not measured — I did not run the suite).** The *decision* is still correct, by a different route: three of the five are plain scripts with no `unittest` wrapper, so `python <file>.py -v` **executes** them; without a live fabric they raise and exit non-zero, hitting the `rc -ne 0` branch at **:190-193**, which *does* increment `FAILURES`. `check_env.py` would instead land in the silent yellow branch.

Severity **P2** — same shape as the "arithmetic that fits is not the mechanism" trap: the outcome matches, the cited cause does not. Recorded only; no edit made.

### P2-2. `doc/phase7_power_mechanism_design.md` — all three `§` cross-references into the plan are stale

The phase7 doc navigates the plan by line number (`計劃 §NNN`). Opened each cited line:

| Cite | Appears at | Plan line actually says | Where the cited text really is | Δ |
|---|---|---|---|---|
| `§452` | phase7:59 — "只寫「等 gRPC port 開起來」" | `452: 當時更危險的是 twin 還在宣稱一切正常：all_destination_paths 維持 12 條…` | **plan:507** | +55 |
| `§456` | phase7:14 and :147 — OVSPowerStrategy seam / mock `executeSystemCommand`, 絕不含 `pkill -f` | `456: **已修（2026-08-10）**：render_destination_paths 多收一份 installed…` | **plan:511** | +55 |
| `§479` | phase7:142 and :152 — "步驟 6" live off/on acceptance | `479: ` *(blank line)* | **plan:537** | +58 |

All three are **ROT**. Consistent +55/+58 offsets say they were written against a much older revision of the plan. Checked `git show b0a7bdc:doc/p4_bmv2_support_plan.md` — **already wrong before today's range** (plan was 539 lines then, 548 now), so this rot predates the overnight window but lives in a file the window touched. Severity **P2** (navigation only; a reader lands in the wrong section and has to grep).

### P2-3. `doc/test_coverage_gaps.md:452-459` — the log-check blind spot has been closed

Doc asserts: "`run_logcheck` 傳了 `--ignore-unparsed`（run_layers.sh:86）… **crash 訊息剛好落在 log 檢查的盲區裡**."

- `awk NR==86 tools/test_workflow/run_layers.sh` → `# permanently red for reasons the test itself caused -- which trains you to ignore the` — unrelated comment. **Line ROT.**
- `grep -rn "ignore-unparsed" tools/test_workflow/run_layers.sh` → **no hits at all.** `run_logcheck` is defined at :165 and invokes `check_logs.py` at :211/:213 with `--to-line "$LOG_MARK"` or bare — **the flag is never passed.**
- `--ignore-unparsed` now only exists as an argparse option of `tools/contract_test/check_logs.py:154`, and that file states at **:213** that crash detection is "unaffected by `--ignore-unparsed`".

So the conclusion is **stale, not just the citation**. The same document already contradicts it at **line 391** ("崩潰現在會被 `check_logs.py` 抓到"), which is the newer and correct statement — §5.3's body was never struck through. Severity **P2**: acting on it means fixing a problem that is already fixed.

### P2-4. `doc/test_coverage_gaps.md:484-487` — the stdin-feeding fragility no longer exists

Doc: "`stack.sh` 用 `printf '1\n%s\n2\n'` 餵 kernel 的 stdin（stack.sh:236）… 症狀是 kernel 載入錯的拓樸".

- `grep -n "printf '1" tools/test_workflow/stack.sh` → **no hits.**
- `awk NR==236` → a comment about blanking a progress line. **Line ROT.**
- stack.sh now launches with CLI flags: `stack.sh:606: bash -c "cd '$KERNEL_DIR/build' && ./bin/ndtwin_kernel --mode mininet --topology '$topo' --no-ai"`.

The doc's own parenthetical predicted this ("已知，Phase 1 的 CLI 參數會解掉"), and the plan marks **Phase 1 ✅ 完成** — so this is a resolved item left unstruck. Severity **P2**.

### P2-5. `doc/test_coverage_gaps.md:436` — wrong line range into `testing_workflow.md`

Doc: "`testing_workflow.md` **第 204-213 行**列出四項判定標準", then quotes a process-health block (crash / RSS / thread / exit code).

- `doc/testing_workflow.md:204-213` is a different block entirely (語意不變量 + 錯誤路徑: `✓ edge 數量 == 拓撲檔裡的數量`, `✓ acquire_lock 連續拿兩次 → 第二次回 423`).
- The quoted four criteria are at **`doc/testing_workflow.md:319-322`**. **ROT** (~115 lines off). The quoted *text* is accurate; only the locator is wrong.

## 6. Missing targets — references to files that no longer exist

| Document | Reference | Check | Verdict |
|---|---|---|---|
| `doc/p4_bmv2_support_plan.md:162` | markdown link `[test_P4RoutingStrategy.cpp:27-32](../tests/test_P4RoutingStrategy.cpp#L27-L32)` | no such file anywhere in the repo; the surviving suite is `tests/test_RoutingStrategies.cpp` | **ROT — dead link**, P2 |
| `doc/p4_bmv2_support_plan.md:155` | "`P4RoutingStrategy.cpp` 是 `OpenFlowRoutingStrategy.cpp` 的複製品" | `src/ndt_core/routing_management/` contains **no** `OpenFlowRoutingStrategy.cpp` — only the header `include/.../OpenFlowRoutingStrategy.hpp`. The duplication was dissolved into `HttpRoutingStrategyBase.cpp`, exactly as Phase 3 planned | **superseded** (historical bug entry), note |
| `doc/p4_bmv2_support_plan.md:155` | link range `P4RoutingStrategy.cpp#L29-L33` | file is **30 lines long** → L31-L33 do not exist | **ROT — out of range**, P2 |

Deliberately *not* flagged: `setting/AppConfig.hpp` (gitignored by design, and the doc says so), `p4_src/build/ndtwin_switch.p4.p4info.txt` (the doc's instruction was to *delete* it — absence is compliance), `pytest.ini` / `__init__.py` (doc marks that half 作廢), `/tmp/ndtwin_p4_switches.json` (runtime artefact).

## 7. Line-number rot in `doc/p4_bmv2_support_plan.md`

Every line below was opened before being judged. **Pattern: the prose claims are almost all still true; it is the locators that have rotted.** Most sit in the "目前實際壞掉的地方" table (a snapshot of `6f32bca`), so this is historical drift rather than misinformation — severity **note** unless marked.

| Plan line | Cites | What that line actually contains now | Where the subject really is | Sev |
|---|---|---|---|---|
| 22 | `main.py:142` for `inform_switch_entered` | a comment (`# switches lost their telemetry…`) | call at `p4_proxy/proxy_agent/main.py:215` (`kernel.switch_entered(i)`); def `kernel_notifier.py:81` | note |
| 57 | `FlowLinkUsageCollector.cpp:953` for `sampleType == 2` | blank line | **:1031** `if (sampleType == 2 \|\| sampleType == 4)` | note |
| 72 | `p4_client.py:414` for `read_egress_counter` | `match = {}` | **def at :453** | note |
| 154 | `FlowLinkUsageCollector.cpp:1309,:1322`, "第 1424 行的姊妹函式" | `{` / `else` / `{` | `hopsCounter` lives at **:1658-1718** and **:1885-1915** | note |
| 160 | `topology_manager.py:108` for `route_flow` returning `True` | a docstring about unsupported match fields | **def `route_flow` at :536** | note |
| 184 | `FlowLinkUsageCollector.cpp:1303` (Phase 0 divide-by-zero) | `protocol = ntohl(data[index + 12 + 6 + 7]) & 0xFF;` | as above, ~:1658 | note |
| 230 | `FlowRoutingManager.cpp:96` — "那句「沒有指定 DPID」的註解跟事實不符" | a *different* comment ("The three flow methods share the same shape…") | the offending comment is **gone**; the honest text is now at **:157** | note (claim resolved) |
| 275 | `intelligent_router.py:365` for hash-biased ECMP | `#` | `hash_dst_ip` def at **:538**, `ecmp_groups` at **:429-430** | note |
| 298 | `FlowLinkUsageCollector.cpp:691-760` for the sFlow decoder | `run()` / a poll-loop comment | **`handlePacket` def at :915**; the two quoted guards are at **:921** and **:925** (text verified identical) | note |
| 327 | `HttpSession.cpp:1080-1081` = `setVertexUp` + `setVertexEnable` | `res.result(http::status::bad_request)` / `"Missing dpid parameter"` | **:1120-1121** — and they are the *only* two `setVertex*` calls in the file, so **the claim is correct** | note |
| 330 | `IntentTranslator.cpp:227` as the **sole** call site of `enableSwitchAndEdges` | `}` | **:310** — and `grep -rn enableSwitchAndEdges src/ include/` returns exactly one caller, so **"唯一的呼叫點" is correct** | note |
| 343 | `intelligent_router.py:597,624` for link failure/recovery | `if datapath is None:` / `neighbors = list(...)` | **:826** `/ndt/link_failure_detected`, **:884** `/ndt/link_recovery_detected` | note |
| 378 | `FlowLinkUsageCollector.cpp:517` for `refreshDestinationPathsPeriodically` | a doc-comment line ("**Convergence.**") | **def at :524** — 7 lines off, still lands inside the right comment block | cosmetic |
| 398 | `Classifier.cpp:824-896` for `parseActionsArrayIntoEffect` | 824 is blank | **def at :882** — the range starts 58 lines early. The symbol name is also given, so it stays greppable | note |
| 511 | `OVSPowerStrategy.cpp:49` "直接呼叫 `utils::execCommand`" | `ports.push_back(p);` | **already fixed** — `OVSPowerStrategy.cpp:98` says so explicitly ("It previously called `utils::execCommand` directly"); the plan's own Phase 7 table marks it ✅ | note (superseded) |

Same pattern in `doc/test_coverage_gaps.md`: `:399` cites `FlowLinkUsageCollector.cpp:683` for the sFlow parser (real def **:915**), `:407` cites "第 709 行" for `sampleCount` (real **:961**), `:422` cites `:380` for `m_q.size() >= m_capacity` (real **:101**), `:255` cites `main.cpp:140` for `net::io_context ioc{1}` (real **:316** — the claim "HTTP 伺服器是單執行緒的" is still true). All **note**.

## 8. Numeric claims checked against code

| Doc | Claim | Check | Verdict |
|---|---|---|---|
| plan:344, 423 | `test_link_watchdog.py`（**34**） | `grep -c "def test_"` → **74** | **stale count** (note) |
| plan:420 | `test_kernel_notifier.py`（**13**） | → **17** | **stale count** (note) |
| plan:422 | `test_startup.py`（**13**） | → **17** | **stale count** (note) |
| plan:397 | `/stats/flow/{dpid}`，**22** 個測試 | `test_ryu_flow_stats.py` → **22** | **OK** |
| phase7:217 | prober 每 **2** 秒 (`LIVENESS_PROBE_INTERVAL_S`) | `topology_manager.py:249: LIVENESS_PROBE_INTERVAL_S = 2.0` | **OK** |
| phase7:214-215, 223 | fix is `grpc.use_local_subchannel_pool` | `p4_client.py:68: grpc_addr, options=[("grpc.use_local_subchannel_pool", 1)])`; pinned literally by `test_p4_client_writes.py:927,942` | **OK** |
| phase7:250 | `eace67c` changed the flag to `--fail-with-body` | `P4PowerStrategy.cpp:82` uses `curl -sS --fail-with-body -X POST` | **OK** |
| phase7:48-51 | helper install commands | identical text at `tools/p4_power_helper.py:16-20`; kernel constant `P4PowerStrategy.cpp:21: "/usr/local/sbin/ndtwin-p4-power"` | **OK** |
| phase7:11 | manifest writer `write_manifest` | **def** `p4_proxy/mininet/p4_testbed_topo.py:206` | **OK** |
| plan:276, 303 | sampling **1/256** | `sflow_emitter.py:8` "clones 1-in-256 packets to the CPU" | **OK** |
| plan:155, 231 | proxy 沒有實作 `/stats/flowentry/delete`（非 strict） | `api_routes.py` registers only `/stats/flowentry/delete_strict` (:123) — non-strict still absent | **OK — still true** |
| plan:522 | `CHANGELOG.md` 已有 `Unreleased — P4/bmv2 support` | `CHANGELOG.md:9` | **OK** |
| plan:518 | `l1_unit_tests.sh:176` globs `p4_proxy/tests/test_*.py` | exact match at that line | **OK** |
| plan:519 | `tests/python/test_route_install_gate.py:35` reads `intelligent_router.py` by relative path | exact match at that line | **OK** |

### Ports — all clean

Swept every port mention in the four in-scope docs. **No document claims the kernel API is on `:8080`.** Verified against code: kernel API **:8000** (`stack.sh:607,633,637`; `intelligent_router.py:826` posts to `localhost:8000`), proxy **:8081** (`main.py:303`, `AppConfig.hpp.example:10`), sFlow **:6343**, bmv2 gRPC **:50051+**. The only `8080` references are in `p4_proxy/reference/README.md:33` and `plan:517`, and both are correctly framed as *history* ("pointed at port 8080 … Fixed 2026-08-12").
