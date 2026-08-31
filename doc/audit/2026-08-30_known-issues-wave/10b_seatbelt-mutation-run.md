# Demo-seatbelt wave, bundle 1 — the mutation gate, EXECUTED

Companion to `10_seatbelt-evidence.md`, whose §0 says every verdict in it was **read, not
executed**. This file is the execution. Run 2026-08-31 in the worktree
`.claude/worktrees/agent-aaf83a756cda5386e` (branch `fix-demo-seatbelt`, based on `1208d22`).

Predictions are quoted from `10_seatbelt-evidence.md` §5 and were **not edited** — per
`prereg-amendment-before-data`, deviations are recorded underneath instead.

Nothing was committed. The fabric, `ndt` and the lab claim were not touched: every suite here is
a pure unit/shell suite, and the shell one sources `stack.sh` behind its
`[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0` guard and drives `start_bg` with `true`/`echo`
inside a `mktemp -d`.

---

## 0. 🔴 Two findings that are not about the mutations

### 0.1 `git checkout -- <file>` would have DESTROYED the entire fix

`10_seatbelt-evidence.md` §6 step 5 says to restore between mutations with
`git stash / git checkout -- <file>`. **The seatbelt changes are entirely unstaged** —
`git status --porcelain` shows ` M` (worktree-modified, index clean) for all six files, and
`git diff --cached --stat` is empty. `git checkout -- <file>` restores from the *index*, which
here is `1208d22`. Following the documented recipe would have reverted `topology_manager.py`,
both test files and `stack.sh` to the pre-fix commit and silently deleted the whole of bundle 1.

**This run therefore restored from a checksummed pristine copy** taken before the first
mutation, and verified each restore with `cmp` against that copy rather than trusting `git`.

⚠️ §6 step 5 must be corrected before anyone else follows it.

### 0.2 The root filesystem hit 100%, and a plain `cp` truncated a source file to 0 bytes

Mid-run, `/` (98 G, `/dev/nvme0n1p5`) reached **6.6 MB free**. The first M-1 attempt died on
ENOSPC, and the harness's own restore — a plain `cp` — **truncated
`p4_proxy/proxy_agent/topology_manager.py` to 0 bytes** and
`p4_proxy/tests/test_unsupported_match.py` to 16384 bytes (a partial 4-block write) out of
27198. `cp` reported nothing usable because stdout capture was itself on the full filesystem.

Recovered in full: the pristine backup verified clean against its SHA-256 sums, and both files
were restored byte-identical. **No work was lost.** But this is the
`failures-that-report-success` shape again — the restore step, whose entire job is to undo a
mutation, is exactly the step that corrupted the file it was restoring.

Hardening applied for the rest of the run, and worth keeping in any future mutation harness:

- mutation writes go to `<file>.mutant-tmp` with `fsync` + a size check, then `os.replace`;
- restores go to `<file>.restore-tmp`, are `cmp`-verified, then `mv`-ed into place — a short
  write never reaches the real path;
- a `require_disk` precondition aborts a mutation if `/` has under 512 MB free.

**Disk state, for whoever owns the machine.** `/` is still at **98% (2.6 GB free)**. The largest
disposable items found are stale, not active:

| Path | Size | mtime | Growing? |
|---|---|---|---|
| `scratch/lab/logs/viz.log` | 2.90 GB | 2026-08-18 20:59 | **no** (size identical 5 s apart) |
| `scratch/lab/logs/viz_p4.log` | 534 MB | 2026-08-18 21:18 | **no** |

3.4 GB of Visualizer `[DEBUG]` spew from the 08-18 round. **Not deleted** — they sit in the main
repo under another party's lab area and that is not this dispatch's call, but they are the
cheapest 3.4 GB on the disk. Note the relevance to A-5 itself: `start_bg` bounds rotation by
*generation count*, not by size, so one era can be arbitrarily large.

---

## 1. Negative control — the unmutated baseline

Run before the first mutation and again after **every** restore (9 times total). Verbatim, final
run:

```
Ran 49 tests in 0.008s          # p4_proxy/tests/test_unsupported_match.py
OK

Ran 8 tests in 0.022s           # p4_proxy/tests/test_flowentry_endpoints.py
OK

Ran 13 checks, all passed       # tests/shell/test_start_bg_log_rotation.sh
```

Interpreter `/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python` (3.13.13), cwd
`<worktree>/p4_proxy`, `PYTHONPATH=.`, per §6.

### The prereg's expected counts — two right, one wrong

§5 predicted `test_unsupported_match.py` **+18**, `test_flowentry_endpoints.py` **+2**,
`test_start_bg_log_rotation.sh` **8 checks → 13**.

| Suite | HEAD | now | delta | prereg | verdict |
|---|---|---|---|---|---|
| `test_unsupported_match.py` | 31 | 49 | **+18** | +18 | ✅ |
| `test_flowentry_endpoints.py` | 6 | 8 | **+2** | +2 | ✅ |
| `test_start_bg_log_rotation.sh` | **7** | 13 | **+6** | "8 → 13" / "+5 checks" | ❌ |

The shell suite's *end* state (13) is right, but its stated starting point is not: `git show
HEAD:tests/shell/test_start_bg_log_rotation.sh | grep -c '^check '` is **7**, not 8, so the
change adds **6** checks, not the "+5" in §4's diff inventory. Documentation error only — no
test is missing, and `Ran 13` is correct. It matters because §5's own rule is that an `OK` with
a smaller `Ran` than expected is a failure: a reader checking "8 + 5 = 13" would confirm a total
that is right for the wrong reason, and would not notice a check going missing.

For the two Python suites, `Ran N` equals the count of `    def test_` in the file (49 and 8), so
nothing is stranded below the `__main__` guard.

---

## 2. Results — 7 applied, 7 killed, 0 survivors, 0 CRASH-RED, 0 SKIP-ANCHOR

Every mutation was applied, **grep-asserted present on disk by line number**, run, judged, then
restored and re-baselined before the next.

| # | Mutation | Anchor on disk | Judging suite | rc | `Ran` | State | Prediction |
|---|---|---|---|---|---|---|---|
| M-1 | value gate never called from `route_flow` | `topology_manager.py:843` | unsupported | 1 | 49 | **RED** | ✅ exact |
| M-2 | subclass `UnsupportedMatchError` → `ValueError` | `:109` | unsupported + flowentry | 1 / 1 | 49 / 8 | **RED** | ✅ exact |
| M-3 | message echoes the substituted value | `:143` | unsupported | 1 | 49 | **RED** | ✅ + 2 extra |
| M-4 | `_describe_match_value` bound removed | `:102` | unsupported | 1 | 49 | **RED** | ✅ exact |
| M-5 | validator stricter than the encoder | `:261` | unsupported | 1 | 49 | **RED** | ✅ exact |
| M-6 | rotation depth 2 → 1 | `stack.sh:361` | shell | 1 | 13 | **RED** | ✅ exact |
| M-7 | rotation removed entirely | `stack.sh:360` | shell | 1 | 13 | **RED** | ✅ (1 hedge resolved) |

No mutation exited on a signal (no rc > 128), and every run produced its `Ran N` summary, so no
verdict rests on a missing summary line.

### M-1 — the one that matters
> "If the two named tests do not go red, the fix is not wired and the helper tests were
> measuring nothing."

Exactly two reds, exactly the two named:

```
FAIL: test_route_flow_refuses_a_cidr_destination_before_any_write (RefusalReachesTheEntryPointsTest)
FAIL: test_a_cidr_source_is_refused_on_the_five_tuple_path_too   (RefusalReachesTheEntryPointsTest)
```

All 14 `MalformedMatchValueTest` helper tests stayed green, as predicted — which is the point of
M-1: the helper suite alone cannot tell whether the gate is connected. The unroute/modify
entry-point tests stayed green because their call sites were untouched. **The gate is wired into
`route_flow`, and the two paths (`ipv4_lpm` destination and `flow_5tuple` source) are separately
pinned.**

### M-2 — the 400 depends only on the subclass relationship
Predicted 1 red in `unsupported` and 2 (one with 3 subtests) in `flowentry`. Got exactly that:
`test_it_is_an_unsupported_match_error_so_the_existing_catch_answers_400`, plus
`test_it_answers_400_on_every_write_endpoint` erroring on all three subtests
(`add`/`delete`/`modify`) and `test_the_400_body_names_the_field_and_the_value_the_caller_sent`.
The endpoint-side pin does its stated job: break inheritance and the other file stays green
while the endpoint reverts to a 500.

### M-3 — three predicted reds, two extra
Predicted red and red: `test_the_message_never_names_the_substituted_value`,
`test_the_message_quotes_what_the_caller_sent_and_names_what_did_not_happen`,
`test_a_huge_value_produces_a_bounded_message`. The prediction's note that non-string values
would raise `AttributeError` also held — `test_a_non_string_value_is_reported_by_type_not_by_
content` errored on all four subtests.

**Deviation (extra red, recorded not amended):** two more went red that §5 did not name —
`test_the_bound_is_the_declared_constant` (the substituted value is unbounded, so the
`assertNotIn` fires) and, in the suite §5 did not name for M-3,
`test_flowentry_endpoints.MalformedMatchValueIsA400Test.test_the_400_body_names_the_field_and_the_value_the_caller_sent`.
Both are the sensitive direction — the mutation is over-detected, not under-detected — so
neither weakens the gate.

### M-4 — exact
`test_a_huge_value_produces_a_bounded_message`, `test_the_bound_is_the_declared_constant`, and
`test_a_non_string_value_is_reported_by_type_not_by_content` (4 subtests). Nothing else.

### M-5 — the accept-path control, and it works
> "This is the control: it proves the accept path is actually asserted, not just the refusals."

`test_forms_inet_aton_already_accepts_are_not_newly_refused` errored on all four subtests
(`10.1`, `10.0.1`, `0x0a000001`, `127.1`) and **everything else stayed green**, exactly as
predicted. Per `smoke-the-accept-path-not-just-refusals`: a guard that refused everything would
have passed every refusal test in this suite, and this control is what stops that.

### M-6 — exact, and the backwards-compatibility claim holds
Exactly two reds — `the oldest of three eras survives in .prev2` and `the oldest era is now the
one that was in .prev`. §5 said the four original depth-1 checks must stay green "deliberately:
… if any of them goes red the change broke the old contract". **None of them went red.** Depth 2
is backwards-compatible with the depth-1 contract.

### M-7 — exactly 6 red, and the hedge resolves to green
§5 predicted "**≥6 red**", naming four originals plus "all four new depth-2 checks", with
`the newer era is in the main log` marked "(partially)". Actual: **6 red, 7 green.**

Red: `previous log rotated to .prev`, `.prev holds the previous era's content`, `the older era
survives in .prev`, `the oldest of three eras survives in .prev2`, `the middle era is in .prev`,
`the oldest era is now the one that was in .prev`.

**Deviation:** the hedged `the newer era is in the main log` stayed **green**, and so did the
three new checks that assert an *absence* (`two eras produce no third generation yet`, `a fourth
era does not create a .prev3`) or the current era (`the newest era is in the main log`). The
reason is structural, not a gap: with rotation removed the `>` redirect still creates the log
holding the newest era, and checks asserting "no `.prev2`/`.prev3` exists" are trivially
satisfied when nothing rotates. `≥6` was met on the nose.

---

## 3. What this run does and does not license

**Does.** All three of bundle 1's testable claims are pinned by tests that fail when the claim is
broken: the B-2c gate is called from the verbs (M-1) and not merely present; the 400 comes from
the subclass relationship (M-2); the message discipline and its bound are enforced (M-3, M-4);
the guard is not a refuse-everything (M-5); and A-5's depth-2 rotation is pinned both at its new
depth (M-6) and against total removal (M-7), without breaking the depth-1 contract.

**Does not.** This is the unit/shell seam only. Untouched by this run, and still exactly as
`10_seatbelt-evidence.md` left them:

- the **live** recipes in §6 (A-5's three-era `ndt up`/`down` sequence, A-6's startup banner,
  and the B-2c `curl` against a running proxy on :8081, including the accept-path 200 and the
  B-2c-b 500). A-5 and A-6 have no unit seam at all, so these remain the only real checks of
  them. Not run: the machine's fabric is under another agent's claim.
- the **seven cross-repo callers** (§3), still `🔴 unknown` — in particular
  `Traffic-Engineering-App` and `Energy-Saving-App`, both named flow writers.
- **B-2c-b**, the numeric 5-tuple keys still answering 500, still awaiting Adam's ruling.

## 4. Reproduce

Harness in
`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/258e9ef7-6035-4abb-b378-8b2ab1aa8200/scratchpad/`:
`mutate.py` (7 anchored mutations, atomic write, self-verifying), `lib.sh` (suite runner, judge,
atomic restore, disk precondition), `baseline.sh`, `mutrun.sh` (the five steps). Per-mutation
logs in `runs/<M-id>/`.

Final state: `git status --porcelain` is byte-identical to the pre-run state (the six ` M` files
plus the three `??` entries); no `MUTANT-M` marker survives anywhere under `p4_proxy/`, `tools/`
or `tests/`; no `.mutant-tmp`/`.restore-tmp` left behind; the pristine backup still verifies
against its SHA-256 sums; and the three suites close green at 49 / 8 / 13.

[Co-developed with claude code -- Adam]
