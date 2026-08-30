# COMMIT-PLAN — A-7 dispatch visibility

[Co-developed with claude code -- Adam]

Written by 8/29 mainDev during the live-traffic measurement window (claim to 01:24). **Nothing in
this package has been compiled, run, added or committed.** Base `1208d22`.

## Before the first commit

```bash
ndt status
```

`measuring` must be empty and the claim released. Do not infer the window from `pgrep`
(`12_auditor-rulings.md` §5.0).

Then, in order — **each is a gate, and a red one stops the plan**:

1. **Build.** `cmake --build build -j4` — this is prediction P1 (no `CMakeLists` change needed
   beyond the one test source). A failure here means the header-only assumption was wrong.
2. **Run the new tests.**
   ```bash
   ./build/bin/test_routing_strategy --gtest_filter='DispatchOutcomeLogTest.*:ControllerTest.*'
   ```
   Expect **`Ran 20`** — **read the count, not just `OK`**
   (`memory: tests-below-the-main-guard-are-not-collected`).
   🔴 This line first said `./build/tests/…` and `Ran 12`, and **both were wrong**: the binary is
   in `bin/`, and 12 is the number of *new* cases while the filter also picks up the 8 pre-existing
   `ControllerTest`s. A gate whose expected value is wrong reads as a failure when the system is
   fine. Verify the expected value separately from the command
   (`memory: verify-the-purpose-not-the-mechanism`).
3. **Mutations.** `FINDINGS.md` §3, M1–M13. **M11 first** — it is the only one that proves the
   thing is wired at all, and P4 says it turns exactly 3 tests red and none in the unit file.
4. **The green control, C1** — default capacity `256` → `512`, all 12 tests must stay green. A
   suite that reddens on everything has no discriminating power.
5. **Rebuild, then full suite.** The rebuild is not optional and not a formality: restoring a
   mutated *source* does not restore the *binary*, and a mutation run that ends by copying the
   pristine file back leaves the mutant artifact on disk. Observed here — the full suite failed
   M11's exact three tests while `git diff` showed a clean tree. **The gate is "rebuild, then
   baseline green", not "the source looks right".**
6. **Live**, `FINDINGS.md` §5 — including step 3, the force-**green** control. M14/M15 are only
   reachable here.

Record the actual results in `FINDINGS.md` under a new §8; **do not edit §0**, whose value is that
it was written blind.

## Commits

Ordered: commit 1 must precede commit 2 (the handler calls `dispatchOutcomes()`).

### Commit 1 — the seam and its wiring

New file, so it needs an explicit add first. Pathspec-limited, never `git add -A`
(`memory: two-writers-one-worktree`).

```bash
git add -- include/ndt_core/routing_management/DispatchOutcomeLog.hpp tests/test_DispatchOutcomeLog.cpp
git commit -- include/ndt_core/routing_management/DispatchOutcomeLog.hpp include/ndt_core/routing_management/Controller.hpp src/ndt_core/routing_management/Controller.cpp tests/test_DispatchOutcomeLog.cpp tests/test_Controller.cpp tests/CMakeLists.txt
```

Message:

> Keep a dispatched job's outcome somewhere a program can read
>
> Controller's sender is the last place a FlowJob and its OpResult exist together. It logged
> failures and dropped them, so kernel.log said `dispatched install failed` while every API
> surface, and the contract suite, reported a healthy system (KNOWN-ISSUES A-7).
>
> The ring holds failures only — a 2000-job success burst would otherwise evict the evidence —
> and publishes its eviction count, because a silently truncated failure list reads exactly like
> a healthier system. Successes still route through record(), which is the seam T-11 needs to
> answer "has this entry been confirmed by the southbound?" without re-threading call sites.
>
> Mutations M1-M13 and the C1 green control: doc/audit/2026-08-30_a7-dispatch-visibility/
>
> [Co-developed with claude code -- Adam]

### Commit 2 — the endpoint

```bash
git commit -- src/ndt_core/http/HttpSession.cpp include/ndt_core/http/HttpSession.hpp tools/contract_test/components.py
```

Message:

> Add GET /ndt/get_flow_dispatch_status, and stop telling callers the log is the only record
>
> Served from the dispatcher's own counters rather than through
> DeviceConfigurationAndPowerManager: that cache refreshes on a 10 s sleep plus one southbound
> poll, so a failure counter behind it would answer "no failures" for the whole window in which
> a caller is asking whether its write failed.
>
> install_flow_entry's `detail` now names the endpoint. Safe to reword — both in-repo consumers
> log this body without parsing it (auditor cross-repo check 2026-08-30) — and leaving it would
> have made the answer undiscoverable to exactly the caller that needs it. `status` and
> `accepted` are unchanged.
>
> Registered in KERNEL_ENDPOINTS only, not in any Component's list: nothing consumes it yet and
> listing it there would assert a consumer that does not exist.
>
> [Co-developed with claude code -- Adam]

### Commit 3 — the evidence

```bash
git add -- doc/audit/2026-08-30_a7-dispatch-visibility/
git commit -- doc/audit/2026-08-30_a7-dispatch-visibility/
```

> Record A-7's chain, the mutation list, and a correction owed to FINDING-06
>
> [Co-developed with claude code -- Adam]

## Not in this plan, deliberately

- **`doc/KNOWN-ISSUES.md` is untouched.** Three branches are mid-merge on that file and the
  auditor is stacking them by hand. The A-7 entry's status text belongs to whoever lands that
  merge; the wording to fold in is below.
- **FINDING-06 is not edited.** §4 of `FINDINGS.md` is a correction to another line's in-flight
  document; it goes to the auditor as a report item, not as an edit to their file.

### Wording offered for the A-7 ledger entry, for whoever lands the merge

> **狀態**：部分關閉 2026-08-30。失敗現在有計數器與 `GET /ndt/get_flow_dispatch_status`，
> 明細（dpid／match／controller status／原因）可事後查詢，`droppedAfterStop` 一併公開。
> **仍未關**：呼叫端拿到的仍是 `200 queued`，per-entry 結果送不回原請求——那需要同步路徑或
> completion handle，是架構決定。證據：`doc/audit/2026-08-30_a7-dispatch-visibility/`

## Hooks

`post-commit` is already `.disabled`, so no agy review fires. Do **not** set `core.hooksPath` to an
empty directory to suppress anything — that silently disables the `pre-commit` audit-raw guard
too, which is how five commits went out unguarded on 08-29
(`memory: two-writers-one-worktree`).
