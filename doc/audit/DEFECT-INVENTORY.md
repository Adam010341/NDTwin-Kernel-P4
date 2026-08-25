# Defect inventory — what was inherited, and what we broke ourselves

[Co-developed with claude code -- Adam]

Standing reference, written 2026-08-25 for report use. Two parts, deliberately separated:
**Part A** is defects that exist on `main` and were found by this work — the ones a report can
cite as "the simulator was not sound before the P4 work". **Part B** is defects *this work
introduced*, kept because a report that lists only the first half is not honest, and because the
patterns in it are the more transferable finding.

`main` is at `5297d24` (2026-07-23); this branch is 472 commits ahead. Every Part A row carries a
command you can re-run — none of this is reconstructible from commit messages, which is why it is
written down rather than left to be re-derived.

---

## Part A — defects present on `main`

### A-1. The boot-ring deadlock (both edges are on main)

The highest-severity finding. `load_static_topology()` runs **inside** the `EventSwitchEnter`
handler, so a slow walk stops that app draining its own event queue; the queue is a 128-slot
`hub.Queue` + semaphore shared with 10 datapaths' packet-ins; when it fills, everything trying to
post to it parks in `_events_sem.acquire()` — **including the `Switches` app announcing its first
`EventLinkAdd`**. The other half of the ring is the readiness gate calling `get_all_host()` as an
untimed request-reply into the now-dead app.

```bash
git show main:intelligent_router.py | grep -n "load_static_topology()"   # -> :179, inside the handler
git show main:intelligent_router.py | grep -c "HOST_QUERY_TIMEOUT_S"     # -> 0, the gate is untimed
```

Observed: 6 of 10 default boots failed to converge (2026-08-24). Signature — 288 edges **288**
down (not 256), `Switch entered:` truncated at 2 of 10 while `connected (EventOFPStateChange)`
stays 10 of 10, `/v1.0/topology/links` empty for the whole boot, and the data plane **forwards
correctly throughout**. Caught at frame level via a SIGUSR2 greenlet dump.

⚠️ **Status: real but not currently attributable to a fix.** Two fixes exist on this branch
(`d1d973d` bounds the gate, `72fbae6` moves the walk off the handler, default off) and **neither
has been validated**, because the defect became unreproducible for ~24h and then returned. Do not
write "fixed" in a report. See `doc/audit/2026-08-24_boot-ring-verify/` and `..._boot-ring-summon/`.

### A-2. Four notification sites report rejection as success

`requests` does not raise on 4xx/5xx — only on transport failure. All four notify sites log
`"Notified NDT..., status: %s"` unconditionally, so **HTTP 500 reads exactly like 200**, and the
`Failed to notify` warning underneath covers the network layer only. Counting that string measures
*reachability*, not *acceptance*.

```bash
git show main:intelligent_router.py | grep -c "Notified NDT"      # -> 4
git show main:intelligent_router.py | grep -c "raise_for_status"  # -> 0
```

Found by the post-commit shadow reviewer (agy 0450, R-1). Fixed on this branch 2026-08-25 —
additive warning at `status_code >= 400`, no control-flow change.

### A-3. `get_path_switch_count` answers 404 before its path map fills

The kernel populates the path map from a control-plane fetch on a timer; a query arriving first
gets 404, and the contract harness runs right after bring-up — i.e. inside exactly that window.
Measured on a clean boot: `t+0 → 404`, `t+30 → 200`, `t+90 → 200`.

```bash
git show main:src/ndt_core/http/HttpSession.cpp | grep -c "Path not found for the given IPs"  # -> 1
```

⚠️ The *recovery* is measured; the *mechanism* is not — nobody has watched the map populate.
Allowlisted, not fixed (`tools/contract_test/spec.py`, `expect_status=[200, 404]`), with the
post-09-03 fix specified as a readiness distinction (503 while never filled, 404 for a genuinely
unknown pair).

### A-4. Rejected flow installs still act; paths fetched once with no retry

Both present on main, both documented in earlier rounds rather than found tonight:

```bash
git show main:src/ndt_core/http/HttpSession.cpp | grep -c "makeInstallJob"                       # -> 2
git show main:src/ndt_core/collection/FlowLinkUsageCollector.cpp | grep -c "all_destination_paths" # -> 3
```

`install_flow_entry` without `priority` answers **400 and installs the rule anyway** (the job is
built and enqueued before `.at()` throws). And the kernel fetches destination paths **once, never
retrying** — sampling a known non-monotonic series, so a fetch landing in a trough leaves the path
set permanently incomplete with no log line.

### A-5. The 11 pre-existing defects at the fork point

Verified present at `28b8b13` (2026-04-20), the parent of the first P4 commit — *before* any work
here. All silent: nothing crashes, every endpoint answers 200, all 128 hosts read green. Includes
the unlocked flow-table read on every sampled packet, two `uint64_t` underflows to 1.8e19, the
elephant-flow flag whose clearing branch is commented out, `setAllPaths` that only ever adds, and
`poll()` with a 0 ms timeout burning 100% CPU at idle.

Full list and provenance: memory `inherited-simulator-had-silent-bugs`.

**Report framing this supports**: the work is *two* things, not one. "P4 support added on top of a
working OVS simulator" is wrong — fixing shared-path correctness was a prerequisite, because a
baseline that lies cannot validate a new data plane.

---

## Part B — defects this work introduced

Almost all are in **measurement harnesses**, not production. That distribution is itself the
finding: the instruments were less trustworthy than the system under test, and every one of these
had to be caught before its measurement could be believed.

### B-1. Harness defects (2026-08-24/25 session)

| # | Defect | Consequence |
|---|---|---|
| 1 | `workers_up=$(load_start)` — command substitution waits for background children to close stdout | **18 minutes, zero boots.** Run reported as live when it was deadlocked |
| 2 | `$!` after `setsid` is *setsid*, not the worker | `kill -0` said dead, `kill -TERM` killed nothing. **Two smokes each reported "0 alive" while leaking 14 workers** |
| 3 | `grep -c … \|\| echo 0` emits `"0\n0"` | Arithmetic dies. **Introduced 3×**: fixed in `load_count`, reintroduced 150 lines later *in the same commit*, and a third instance missed by the sweep that claimed to have found them all |
| 4 | `probe_persistence.sh` had no teardown | **Leaked a full fabric for ~12 hours** (139 processes + kernel + Ryu) |
| 5 | The *fix* for #4 defined its trap at end-of-file | Early exits still leaked. **A cleanup handler defined after the code that can fail is not a cleanup handler** |
| 6 | `ndt down` status swallowed, "torn down" printed unconditionally | A failed teardown read as success |
| 7 | `PROBE_HOLD=0` is a non-empty string | The obvious way to say "do not hold" turned the hold **on** |
| 8 | `greenlet_dump_smoke.py`: dead scratchpad path; unconditional `DUMPS DONE`; parked count printed but never asserted; print-path-then-unlink; unlink after three `sys.exit(1)` | A tool whose entire purpose is capturing parked frames **could not fail**, and its failure paths destroyed the evidence |
| 9 | `verify_allowlist.sh` swallowed `ndt up` non-zero | An acceptance ran on a degraded fabric without saying so |
| 10 | Provenance check used `git diff` (worktree vs **index**); `git checkout <c> -- <path>` stages | Printed `matches HEAD` while running a reverted router — **the check existed solely to catch that** |
| 11 | `wedge_watch.sh` required `switches` non-empty as a "liveness sanity check" | On a wedge, `switches` is empty too. **The sanity check excluded the only case being hunted**; two wedges went undumped |
| 12 | `pkill -f "<pattern>"` matched the wrapper shell's own argv | Killed my own shell. **Twice**, with the lesson already in memory both times |
| 13 | Edited `intelligent_router.py` while a run using it was in flight | Experiment's subject changed mid-run; boots 1–3 certain, boot 4 provenance-uncertain. Recorded in `2026-08-25_host-learning-curve/PROVENANCE-NOTE.md` |

### B-2. Wrong conclusions that reached a report or memory

Seven mechanism claims were asserted and later refuted **by my own follow-up**, not by review:

1. "The 600 s deadline was evaded" → the laptop had **suspended** for 7569 s
2. "`d1d973d` fixed the wedge" → the same-day control at the baseline commit converged 10/10
3. "Duplicate `EventSwitchEnter` is the trigger" → direction inverted; the count was **truncation**
4. "A truncated retry loop" → there is no retry; two handlers each notify once
5. "Quiet learns hosts, loaded does not" → an artifact of diffing **sorted line shapes**
6. "Loaded does more MAC learning (197 vs 93)" → both learn **128 distinct** MACs; the table is dumped once per install. **Reached a commit and memory**
7. "`settle=40` is not robust under load" → the gate times out at 0/128 on **all 19 boots including every healthy one**. **Reached a commit, memory, and an escalation to Adam**

### B-3. The patterns worth carrying forward

**Numbers were right; labels were wrong.** In #5, #6 and #7 every figure re-derived exactly. What
failed was what the figure was *called*. Re-checking arithmetic cannot catch this class.

**What did catch them: using the conclusion to design the next experiment.** #6 was caught when a
reviewer asked for provenance; #7 when I went to build the experiment it implied and found the
knob was not connected to the outcome. Neither was caught by re-reading. **The strongest review of
a conclusion is to try to build on it.**

**Fixing the instance you are debugging is not fixing the bug** (#3, three times). Sweep the file
for the shape — and note the sweep itself was overclaimed once, so *"swept" is not "found"*.

**A check that cannot fail is not a check** (#8, #10, #11). Three separate guards each reported
success in exactly the situation they existed to detect.

**Do not modify the subject of a running experiment**, however harmless the change appears (#13).
Deciding a change is harmless is the failure mode, not the change.

**A shadow reviewer found what self-review did not.** An advisory Gemini review runs per-commit
into `.git/agy-reviews/` (installed 2026-07-28, 450+ reports). It caught #9 and #8's later half.
Weigh that against its cost: it runs with `--dangerously-skip-permissions`, and it wrote six stray
files into the repo root in violation of its own read-only instruction.
