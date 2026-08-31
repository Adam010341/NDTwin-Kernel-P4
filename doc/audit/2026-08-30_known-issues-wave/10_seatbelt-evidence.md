# Demo-seatbelt wave, bundle 1 — A-5, A-6, B-2c

Opened 2026-08-30 on Adam's approval of "bundle 1". Branch `fix-demo-seatbelt`, based on
`1208d22` ("Auditor acceptance: a hand-applied mutation, and what '13 OK' does and does not
prove") via `git checkout --detach 1208d22`.

Follows the shape of `doc/audit/2026-08-28_chaos-harness/08_t7b-evidence.md` §0-bis, and for the
same reason: everything here was produced inside a measurement window and **none of it has been
built, run, or committed**.

---

## 0. Status: code complete, **not built, not run, not committed**

🔴 **Every verdict in this file below §0.2 is READ, NOT EXECUTED.** No compiler, no interpreter,
no test runner, and no `git commit` was invoked. Not even `python -m py_compile` — the dispatch
said "no processes beyond file reads/greps/writes", and a syntax check is a process. The Python
edits have been re-read by eye instead, which is weaker and is labelled as such.

The mutation gate in §5 has **not** been executed. §6 states exactly what to run.

### 0.0 The window state is itself second-hand

The dispatch brief said a `live-traffic-round` claim holds the lab until ~01:24. **I did not read
`ndt status`.** That is deliberate under the no-processes instruction, but it means the one fact
gating this whole file is taken from a message rather than from the source of truth — and a
claim's `owner` field says who the lab belongs to, not whether anything is currently measuring.

⚠️ **Whoever picks this up must re-read `ndt status` themselves before running anything in §6.**
Do not treat "the brief said it clears at 01:24" as a release; a cross-session status is stale by
the time it is read.

### 0.1 What is actually verified, and how

| Claim | How | Strength |
|---|---|---|
| `1208d22` is the stated commit | `git log -1` — subject matches "Auditor acceptance…" | **verified** |
| Branch `fix-demo-seatbelt` exists at that commit | `git rev-parse`, `git log -1` | **verified** |
| A-5's mechanism was already fixed | read `stack.sh:349-353` at HEAD; `git log -S` → `b2e5b04` | **verified (read)** |
| A-6's banner was already fixed | read `main.py:259-279` at HEAD; `git log -S` → `11789e0` | **verified (read)** |
| B-2c still reproduces at HEAD | traced `route_flow` → `insert_ipv4_route` → `socket.inet_aton` | **read only — not reproduced** |
| Nothing in-repo expects 500 from `/stats/flowentry/*` | full read of `spec.py` + `run_contract_test.py` + `l3_component_check.py` | **verified (read)** |
| A run separator would not turn `check_logs.py` red | read its level gate | **verified (read), and moot** — no separator was added |
| The seven cross-repo callers do not depend on 500 | **not checked at all** | 🔴 **unknown** |

### 0.2 The two findings that changed the job

**Two of the three tickets were already fixed, and their KNOWN-ISSUES entries still said OPEN.**

This is the load-bearing result of the night, and it is worth more than the code:

- **A-5** was fixed by `b2e5b04`. The dispatch brief pointed at `src/utils/Logger.cpp`
  ("likely an ofstream/freopen with trunc semantics"). That hypothesis is **wrong in both
  halves**: `Logger.cpp:62` already opens with `/*truncate=*/false`, and it writes `netdt.log`,
  which `stack.sh` **never asks for** (no `--logfile` on the kernel's command line — the flag
  exists only in `main.cpp`'s help text). Had I taken the brief's premise on trust I would have
  "fixed" an append-mode sink on a dead path and reported A-5 closed.
- **A-6** was fixed by `11789e0`. The corrected message and the bounded retry are both present at
  HEAD, and `main.py:267-269` even records the original harm in a comment.

Neither entry was updated when the fix landed. The failure mode is the one already in the
ledger — **a conclusion that lives only in a commit, while the document a reader consults still
says the opposite** — and it very nearly produced two confident, redundant, untested changes
during a freeze.

`doc/2026-08-14_cross-component-integration-matrix.md:170` had the A-5 mechanism right the whole
time ("launcher 的 `>` 重導所致"). Two documents in this repo disagreed, and the wrong one was
the one the dispatch quoted.

---

## 1. A-5 — what was left, and what was changed

### What was already true at `1208d22`

`start_bg` rotates a non-empty log to `<log>.prev` before the `>` redirect. All three services
(`kernel.log`, `p4_proxy.log`, `ryu.log`) go through that one function, so all three were covered.
`tests/shell/test_start_bg_log_rotation.sh` pins it.

### The residual, and why it is the one A-5 actually describes

Depth 1 survives **one** restart. A-5's own scenario is the demo one: A-2's documented workaround
is "restart the kernel", so when the symptom recurs you restart again — and the second restart
overwrites `.prev` (the era holding the evidence) with the short restart era that holds none.

**Change:** depth 1 → 2 (`.prev` → `.prev2`, then `<log>` → `.prev`).

### Failure modes this covers / does not cover

**Covers**
- Kernel, proxy or Ryu restarted twice: both prior eras readable.
- Every file stays single-era (the property `b2e5b04` chose it for).
- Disk stays bounded — 3 files per log, not unbounded timestamped rotation. This is why I did
  **not** take the brief's "rotate to a timestamped name" option: `b2e5b04`'s comment records
  bounded disk as a deliberate choice, and depth 2 tunes that choice rather than reversing it.

**Does not cover**
- **Three or more restarts.** The oldest era is still dropped. A-5's copy-it-elsewhere workaround
  remains correct for long demo sequences, and the entry now says so.
- **A kernel started by hand**, as the User Manual tells operators to. Its output goes to the
  operator's terminal; there is no file for `start_bg` to rotate. `run_layers.sh:120` already
  documents this case.
- **`netdt.log` / `--logfile`.** Untouched deliberately: append-only already, no run separator,
  and no producer in the tree. Adding a separator there would be decorating a path nothing uses.
- **Anything about log *content*.** A-7 (queued-write failures invisible to every API) is
  untouched and unrelated.

### Consumers checked before changing rotation

Instructed, and it mattered. Surveyed `doc/audit/*/harness`, `tools/`, `tests/`:

- **T-4 harness** = `doc/audit/2026-08-30_live-full-stack-round/harness/`. Greps `kernel.log`
  through `lib.sh`'s pattern registry (`kernel_error_line` = `\[(error|critical)\]`,
  `kernel_dispatch_failed`, `kernel_reserved_port_out`, …), and takes freshness signatures via
  `require_absent_or_fresh`.
- `run_layers.sh` is the gating consumer: `LOG_MARK=$(wc -l …)` then
  `check_logs.py --to-line "$LOG_MARK"`.
- Several audit scripts mark with a live `wc -l` and `tail -n +N`.

**None of them reads `.prev`, and none is affected**: adding a `.prev2` sibling changes no path
any consumer opens. Every positional consumer computes its offset live, so nothing shifts.

(The separator-line option would also have been safe — `check_logs.py` only fails on
`error`/`critical` levels, `FORBID` patterns and crash patterns, so an `[info]` line stays green —
but it was not needed once rotation turned out to already exist. Recorded because the analysis was
done and someone will ask.)

### A pre-existing defect found while surveying, not fixed

`doc/audit/2026-08-30_live-full-stack-round/harness/40_r5_p4.sh:201` narrates
`"kernel.log is $KLOG_LINES_BEFORE lines before the experiment (all counts below are deltas)"`,
but `count_matches` at `:230` counts the **whole file**. They are not deltas. Unrelated to this
wave, untouched, registered here.

---

## 2. A-6 — verified fixed, entry corrected, one half still open

`main.py:259-279` is conditional on the real condition (`if not not_entered`), the else branch
states what is actually known at startup, and `renotify_until_acknowledged` makes the claim true.
**No code change.** The entry was rewritten to record the fix and its commit.

⚠️ **The entry's second half is untouched and unverified**: `cleanupAppFolder`'s 17 warnings with
false consequences, and 9 bare sudo prompts on stderr. I did not look at them. They are carried
forward verbatim from the original entry, and are explicitly *not* covered by `11789e0`.

---

## 3. B-2c — the only real code fix

### Mechanism, confirmed by reading (not reproduced)

`unsupported_match_fields` validates field **names**. `nw_dst` is an honoured name, so
`{"nw_dst": "10.0.0.5/32"}` passes, and the value reaches `socket.inet_aton` unexamined:

| verb | topology_manager | sink |
|---|---|---|
| `route_flow` | `:767` `insert_ipv4_route(ipv4_dst, 32, …)` | `p4_client.py:819` |
| `unroute_flow` | `:813` `delete_ipv4_route(ipv4_dst, 32)` | `p4_client.py:899` |
| `modify_flow` | `:862` `modify_ipv4_route(ipv4_dst, 32, …)` | `p4_client.py:948` |
| any 5-tuple match | `five_tuple_keys` → `insert_5tuple_rule` | `p4_client.py:687` (`_encode_5tuple_value`) |

`OSError` is uncaught in all four ⇒ FastAPI 500.

### Two things the entry did not say, both found here

1. **The source side has the same hole.** `_encode_5tuple_value` calls the same `inet_aton` for
   `hdr.ipv4.srcAddr`. Fixing only the destination would have left `nw_src: "10.0.0.0/16"` a 500
   **while the endpoint looked handled** — the B-2b trap ("don't patch one call site of
   fourteen"), one scale down.
2. **There is an in-repo producer.** `IntentTranslator.cpp:359-362` copies the validation agent's
   `ipv4_dst` into `nw_dst` verbatim, and `validation_agent_prompt.txt:113` tells the model:
   *"ipv4_src and ipv4_dst can be exact IP address …, or CIDR prefix (e.g. 192.168.0.0/16)"*.
   So the malformed value is a **sanctioned output of our own prompt**, not a hand-crafted curl.
   The entry read as if only a careless human could trigger it.

### The fix

One gate, three call sites, zero changes to `api_routes.py`:

- `check_match_values(match_dict, action)` in `topology_manager.py`, called immediately after
  the existing `unsupported_match_fields` check in all three verbs.
- Raises `MalformedMatchValueError(UnsupportedMatchError)` — a **subclass**, so `api_routes`'
  existing `except UnsupportedMatchError` turns it into a 400 with no new catch. Same trick, and
  the same reason, as `MalformedMatchError`.
- Validated **by calling `socket.inet_aton` itself**, not by a stricter parser. `inet_aton`
  accepts `"10.1"` as 10.0.0.1 and `"0x0a000001"`; a hand-written dotted-quad check would newly
  refuse callers that work today. Falsely rejecting a working client is the worse direction —
  the trade `parse_eth_type` was written for. Using the real sink as the oracle also means the
  validator cannot drift from it.

### Message discipline (T-7b / `LockManager::describeError`)

`describeError`'s rule is *"quotes what the caller sent, never what the server would have
substituted"*. It bites precisely here, because `route_flow` **does** substitute: it forces
prefix `/32`. So the message:

- **quotes the caller's own string** (`"10.0.0.5/32"`), bounded at `MAX_REPORTED_VALUE_CHARS`
  for the amplification reason `MAX_REPORTED_FIELDS` already carries — the body is
  unauthenticated, and the text is echoed into stdout, the proxy's 400 body **and** the kernel's
  northbound 400 body via `HttpSession::respondToOpResult`;
- **never names the stripped address**, which is the value the server would have substituted;
- **names what did not happen** — `"No rule was installed/deleted/modified"` — because after a
  400 the caller's next question is always "did it do it anyway?";
- describes a non-string **by type only**, as `MalformedMatchError` does.

### 🔴 What this does NOT cover

**The numeric flow_5tuple keys.** `in_port`, `ip_proto`, `tp_src`/`tcp_src`/`udp_src`,
`tp_dst`/`tcp_dst`/`udp_dst` reach `int(value).to_bytes(width, "big")` in `_encode_5tuple_value`.
A non-numeric string still raises `ValueError`; an out-of-range number still raises
`OverflowError`. **Both are still uncaught 500s.**

Deliberately excluded: covering them means duplicating or importing `_FIVE_TUPLE_KEY_BYTES`, and
a width table cannot be validated by eye during a freeze. Registered rather than silently left,
because a partial fix that looks total is the failure this file is otherwise about.

**Registered for Adam's ruling as B-2c-b.**

### Cross-repo contract

`/stats/flowentry/*` is the proxy's southbound-facing surface, but the status **is** visible
northbound: `HttpSession.cpp:735-758` passes 4xx and 5xx through verbatim, so
`/ndt/install_flow_entry` in P4 mode changes from 500 to 400, and my message text becomes the
kernel's `"error"` field.

(Note: the dispatch called this "the `/ndt/` flow endpoint". The defect is on the **proxy's**
`/stats/flowentry/*` on :8081; `/ndt/` is where it surfaces.)

**In-repo: nothing expects 500.** Read in full —
- `tools/contract_test/spec.py`: the only `expect_status=[200, 500]` entries are
  `historical_logging_{enable,disable}`, unrelated. `flowentry` appears zero times; every
  `ipv4_dst` in the file is a bare dotted quad. spec.py **cannot generate** the CIDR request.
- `run_contract_test.py:243` and `l3_component_check.py:104` both treat ≥500 as the thing being
  hunted.
- Southbound, `HttpRoutingStrategyBase.cpp:103` collapses everything outside 2xx into one branch,
  so kernel retry/logging behaviour is **identical** for 400 and 500.
- `tests/test_RoutingStrategies.cpp` uses 500 only as a canned string and asserts the same
  `EXPECT_FALSE(r.ok)` for 400/404/500.

**🔴 Cross-repo callers I could NOT check** — from `tools/test_workflow/components.env`, all
seven present on disk at `/home/adam/<name>`, none opened:

| Variable | Repo | Flow writer? |
|---|---|---|
| `TE_APP_DIR` | `Traffic-Engineering-App` | 🔴 **yes** — named as a flow writer by `spec.py:534` and `topology_manager.py:24` |
| `ENERGY_APP_DIR` | `Energy-Saving-App` | 🔴 **yes** — same two citations |
| `SIM_MGR_DIR` | `Simulation-Platform-Manager` | unknown |
| `VISUALIZER_DIR` | `Network-Traffic-Visualizer` | unknown |
| `WEBGUI_DIR` | `Web-GUI` | unknown |
| `NSR_DIR` | `Network-State-Recorder` | unknown |
| `NTG_DIR` | `Network-Traffic-Generator` | unknown |

The two marked 🔴 are the ones that matter: both write flows through this path. The argument that
they are unaffected is that a 500 and a 400 are both non-2xx failures and neither app can have
been succeeding with a CIDR (it never installed anything) — **that is an argument, not a check.**

---

## 4. Diff inventory

| File | Change | Ticket |
|---|---|---|
| `tools/test_workflow/stack.sh` | rotation depth 1 → 2 | A-5 |
| `tests/shell/test_start_bg_log_rotation.sh` | +5 checks (3-era, 4-era bound) | A-5 |
| `p4_proxy/proxy_agent/topology_manager.py` | `import socket`; `MAX_REPORTED_VALUE_CHARS`; `_describe_match_value`; `MalformedMatchValueError`; `IPV4_VALUED_MATCH_FIELDS`; `check_match_values`; 3 call sites | B-2c |
| `p4_proxy/tests/test_unsupported_match.py` | `MalformedMatchValueTest` (14 tests) + 4 entry-point tests | B-2c |
| `p4_proxy/tests/test_flowentry_endpoints.py` | `RaisingTopology`; `MalformedMatchValueIsA400Test` (2 tests) | B-2c |
| `doc/KNOWN-ISSUES.md` | A-5 + A-6 corrected to fixed; B-2c expanded | all three |
| `COMMIT-PLAN.md` (worktree root, **not to be committed**) | per-fix commit messages | — |

**No C++ was changed.** `test_HttpSessionStatusCodes.cpp` was **not** touched: the dispatch
suggested it, but B-2c lives entirely in the Python proxy, and the analogous seam is
`test_flowentry_endpoints.py`, which is where the tests went.

---

## 5. PREDICTIONS — the mutation gate, registered before running it

Pre-registered per `prereg-amendment-before-data`: each mutation names the file, the edit, and
**exactly which tests must go red**. A mutation that produces a different failure set than
predicted is a finding about the tests, not a pass.

🔴 **None of these has been run.** Predictions are written **before** any execution, and must not
be edited after the run — record deviations underneath instead.

### M-1 — the value gate is never called (B-2c, the whole fix)
**Edit:** in `topology_manager.py::route_flow`, comment out `check_match_values(match_dict, "installed")`.
**Predict RED:**
- `test_unsupported_match.MalformedMatchValueTest` — **all still green** (they call the helper directly; this is the point of M-1)
- `RefusalReachesTheEntryPointsTest.test_route_flow_refuses_a_cidr_destination_before_any_write` — **RED**
- `…test_a_cidr_source_is_refused_on_the_five_tuple_path_too` — **RED**
- unroute/modify entry-point tests — **green** (their call sites are untouched)

**This is the mutation that matters.** If the two named tests do not go red, the fix is not wired
and the helper tests were measuring nothing.

### M-2 — the subclass relationship is broken (B-2c, the 400)
**Edit:** `class MalformedMatchValueError(UnsupportedMatchError)` → `(ValueError)`.
**Predict RED:**
- `MalformedMatchValueTest.test_it_is_an_unsupported_match_error_so_the_existing_catch_answers_400` — **RED**
- `test_flowentry_endpoints.MalformedMatchValueIsA400Test.test_it_answers_400_on_every_write_endpoint` — **RED** (3 subtests; the exception escapes instead of becoming an HTTPException)
- `…test_the_400_body_names_the_field_and_the_value_the_caller_sent` — **RED**
- everything in `MalformedMatchValueTest` that only asserts the raise — **green**

### M-3 — the message echoes the substituted value (B-2c, describeError discipline)
**Edit:** in `MalformedMatchValueError.__init__`, replace `_describe_match_value(value)` with
`f'"{value.split("/")[0]}"'` (i.e. quote the stripped address — the server's substitution).
**Predict RED:**
- `test_the_message_never_names_the_substituted_value` — **RED**
- `test_the_message_quotes_what_the_caller_sent_and_names_what_did_not_happen` — **RED** (`10.0.0.5/32` gone)
- `test_a_huge_value_produces_a_bounded_message` — **RED**, and note it will raise `AttributeError` on the non-string cases, which is itself the point

### M-4 — the bound is removed (B-2c, amplification)
**Edit:** `_describe_match_value` → always `return f'"{value}"'`.
**Predict RED:**
- `test_a_huge_value_produces_a_bounded_message` — **RED**
- `test_the_bound_is_the_declared_constant` — **RED**
- `test_a_non_string_value_is_reported_by_type_not_by_content` — **RED** (4 subtests)

### M-5 — the validator becomes stricter than the encoder (B-2c, false-rejection guard)
**Edit:** replace the `socket.inet_aton(value)` call with
`if value.count(".") != 3 or not all(p.isdigit() for p in value.split(".")): raise …`.
**Predict RED:**
- `test_forms_inet_aton_already_accepts_are_not_newly_refused` — **RED** (4 subtests: `10.1`, `10.0.1`, `0x0a000001`, `127.1`)
- everything else — **green**

This is the control: it proves the accept path is actually asserted, not just the refusals.

### M-6 — rotation depth back to 1 (A-5)
**Edit:** in `stack.sh`, delete the `[[ -s "$log.prev" ]] && mv -f "$log.prev" "$log.prev2"` line.
**Predict RED** in `tests/shell/test_start_bg_log_rotation.sh`:
- `the oldest of three eras survives in .prev2` — **RED**
- `the oldest era is now the one that was in .prev` — **RED**
- the four original depth-1 checks — **green** (deliberately: the change is backwards-compatible, and if any of them goes red the change broke the old contract)

### M-7 — rotation removed entirely (A-5, the original defect)
**Edit:** in `stack.sh`, replace the whole `if [[ -s "$log" ]]; then … fi` block with nothing.
**Predict RED:** `previous log rotated to .prev`, `.prev holds the previous era's content`,
`the older era survives in .prev`, `the newer era is in the main log` (partially), and all four
new depth-2 checks. **≥6 red.**

### Negative control
Run the full suites **unmutated** first. Everything must be green, including
`Ran N tests` counts — per `tests-below-the-main-guard-are-not-collected`, an `OK` with a
smaller `Ran` than expected is a failure. Expected new counts:
`test_unsupported_match.py` +18 tests, `test_flowentry_endpoints.py` +2 tests,
`test_start_bg_log_rotation.sh` 8 checks → 13.

---

## 6. Post-window commands for the auditor

**Re-read `ndt status` first** (§0.0). Nothing below should start while `measuring` is set.

```bash
# 0. confirm the lab is actually free -- the claim, not the brief
tools/test_workflow/ndt status

# 1. syntax + import, the cheapest gate, and the one never run tonight
cd /home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-aaf83a756cda5386e/p4_proxy
python3 -m py_compile proxy_agent/topology_manager.py \
                      tests/test_unsupported_match.py \
                      tests/test_flowentry_endpoints.py

# 2. the two proxy suites, the way l1_unit_tests.sh runs them
#    (cwd p4_proxy, PYTHONPATH=., unittest, -v -- the harness parses "Ran N tests")
PYTHONPATH=. python3 tests/test_unsupported_match.py -v
PYTHONPATH=. python3 tests/test_flowentry_endpoints.py -v

# 3. the shell suite for A-5
bash /home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-aaf83a756cda5386e/tests/shell/test_start_bg_log_rotation.sh

# 4. the rest of the proxy suite, to catch anything the new import broke
cd /home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-aaf83a756cda5386e
tools/test_workflow/l1_unit_tests.sh

# 5. mutations M-1..M-7 from section 5, one at a time.
#    🔴 CORRECTED 2026-08-31 (the original line here said `git stash / git checkout -- <file>`
#    and that is a landmine: this bundle's files are UNSTAGED, so `git checkout -- <file>`
#    restores the INDEX = 1208d22 and silently deletes the whole fix. Caught by the mutation
#    runner before any damage; see 10b_seatbelt-mutation-run.md.)
#    Correct restore: before the first mutation, copy each target to a pristine backup and
#    record its SHA-256; restore = `cmp` the backup, then copy it over the target. Never
#    touch git for restores while the bundle is uncommitted.
#    (mutation-harness-must-guard-its-baseline; restore semantics depend on where the
#    baseline lives -- working tree, index, or HEAD -- ask before writing the restore step.)
```

**Live verification recipes, for when a fabric is up** — A-5 and A-6 have no unit seam at all, so
these are the only real checks:

```bash
# A-5: two restarts must leave three readable generations
tools/test_workflow/ndt up p4          # era 1
tools/test_workflow/ndt down && tools/test_workflow/ndt up p4   # era 2
tools/test_workflow/ndt down && tools/test_workflow/ndt up p4   # era 3
ls -l .test_run/logs/kernel.log .test_run/logs/kernel.log.prev .test_run/logs/kernel.log.prev2
head -1 .test_run/logs/kernel.log.prev2   # must be era 1's first line, not era 2's
# remember: ndt down/up kills the calling shell (exit 144). Wrap in setsid and verify
# the log's "up. ready", not the return code.

# A-6: the startup banner must not claim a ruined round
grep -n "did not acknowledge\|acknowledged all\|stay partly disabled" .test_run/logs/p4_proxy.log
# expect: one of the first two. "stay partly disabled" must have zero hits.

# B-2c: the actual defect, against the proxy alone -- the kernel is not needed
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.5/32"},"actions":[{"type":"OUTPUT","port":1}]}'
# before: 500      after: 400
curl -s -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.5/32"},"actions":[{"type":"OUTPUT","port":1}]}' | head -c 400
# the body must contain nw_dst and 10.0.0.5/32, and must NOT contain a bare "10.0.0.5"

# B-2c accept path -- smoke it, do not only test the refusal
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.4"},"actions":[{"type":"OUTPUT","port":1}]}'
# must still be 200 -- a guard that refuses everything passes every refusal test

# B-2c-b, the registered non-fix: this must STILL be 500 until it is ruled on
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.4","tp_dst":"not-a-port"},"actions":[{"type":"OUTPUT","port":1}]}'
```

---

## 7. For Adam — four rulings

1. **A-5 depth 2**: keep, or revert the `stack.sh` change and only correct the doc? The main
   mechanism was already fixed; depth 2 closes the two-restart case that A-5 actually describes.
   *Recommend keep* — 2 lines, bounded disk preserved, backwards-compatible with the old test.
2. **B-2c-b** (numeric 5-tuple keys still 500): fix now, or register and defer?
   *Recommend register and defer* — it needs the encoder width table, which cannot be checked
   without running anything.
3. **The stale-entry class**: A-5 and A-6 both sat OPEN after being fixed. Worth a sweep of the
   remaining OPEN entries against HEAD before the professor's demo? *Recommend yes* — two out of
   three sampled tonight were wrong, which is not a rate that should be extrapolated from n=3,
   but is enough to justify looking.
4. **Cross-repo check**: someone with the other seven repos should confirm
   `Traffic-Engineering-App` and `Energy-Saving-App` do not branch on 500 from a flow install.
   I could not, and the argument in §3 is an argument.
