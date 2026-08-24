# Boot-ring fix verification — 2026-08-24 evening (`8/21 mainDev v3`)

**Headline: the verification §5-P asked for could not be completed, because the defect did not
occur. The baseline commit converges 10/10 today.** One real result did come out of it: the async
flag halves boot time.

## The four arms

| Arm | `intelligent_router.py` | Failed | Boot time | When |
|---|---|---|---|---|
| baseline (review session) | `79cd66a`, sha `d192329b` | **6 of 10** | 414s wedged / 58s ok | 12:23 |
| `t_only` | HEAD `8340367`, sha `d19020b1` | **0 of 10** | 52–53s | 17:48 |
| `async` (+`ASYNC_TOPOLOGY_INSTALL=1`) | HEAD, sha `d19020b1` | **0 of 10** | **26s** | 18:00 |
| **control** | **`79cd66a` reverted, sha `d192329b`** | **0 of 10** | 52–53s | 18:12 |

Thirty boots today, zero failures, across both the fixed and the unfixed router.

**Which second is which** (two numbers exist for every boot and they must not be cited
interchangeably — the review round independently recomputed from the same raws and got the other
one, reporting control 47–48s and async 20–21s):

| metric | source | control | async | ratio |
|---|---|---|---|---|
| `wall=` — the whole `ndt up ovs` | this report's tables | 52–53s | 26s | 2.00× |
| `converged after Ns` — the convergence wait only | `await_convergence`, inside the up.out | 47–48s | 20–21s | 2.28× |

The ~5s delta is Ryu start, fabric build, kernel start and verify — real work, outside the
convergence window. **Both are correct; neither is the other.** The 2× headline survives either
choice, which is why the async result is safe to state, but an unlabelled "26s" and an unlabelled
"20-21s" describing the same run is exactly how this repo's walk figure went through three
contradictory generations.

## What this establishes

**1. The wedge does not reproduce today, at the commit that produced it.** The control ran the
baseline router — timeout absent, async absent, SIGUSR2 absent, settle already 40 — on the same
machine, same fabric, same harness, and converged 10 for 10. Under the baseline's own 60% failure
rate, ten clean boots is p ≈ 1×10⁻⁴.

**2. Therefore the `t_only` 10/10 cannot be credited to `d1d973d`.** Two readings were live when
that arm finished — "the timeout fixed it" and "today doesn't trigger it" — and the control picks
the second. Neither fix is validated against the wedge, because no wedge appeared to validate them
against. **§5-P item 4's verification remains open, not passed.**

There was a second, independent reason to doubt the attribution before the control ran: `d1d973d`
only acts when `get_all_host` stalls past 5s, and it announces itself in the log when it does.
No boot showed signs of having been rescued — every one matched the timing of the baseline's
*successes*, not a ride-out.

⚠️ **Correction (review round, N-1): the log half of that claim is much thinner than first written.**
An earlier draft said "no boot in any arm logged that warning". The archiving policy here keeps
`ryu.log` only on FAILURE, and there were no failures — so **almost no logs were retained**. The
actual disk evidence is a *single* live spot-check during the async arm (`grep -c` → 0). The control
arm cannot contribute at all: its router has the timeout code reverted out, so the warning is
impossible there by construction, not by observation. The 20 HEAD-code boots left no log behind.

**The load-bearing evidence for "d1d973d did not fire" is therefore the timing signature, not the
logs.** That signature is strong (30/30 boots at success-timing, two distinct modes 52–53s and 26s
with no intermediate) and the control is independent of both. The conclusion stands; its support is
narrower than stated. **Harness fix for next time: archive `ryu.log` on every boot, not just failures.**

**3. The async flag halves boot time: 26s vs 52s.** This one *is* attributable — same day, same
machine, same harness, single variable, n=10 each, and the banner was asserted present in `ryu.log`
on all 10 boots so the flag is known to have reached Ryu. Taking `load_static_topology` off the
event handler removes a wait the boot previously paid in full. This says nothing about the wedge.

## What this does not establish, and one hypothesis that died

- **Whether either fix cuts the ring.** Untested. Both remain theoretically motivated only.
- **The greenlet-dump path is still unexercised against a real wedge.** Zero failures ⇒ zero dumps.
  The mechanism (pid parse, SIGUSR2, `_events_sem.acquire` grep) was validated in isolation, never
  against the live defect.
- **What differs between 12:23 and 18:00.** This is now the central open question.

**Refuted en route — duplicate `EventSwitchEnter`.** All 6 failing baseline boots showed 12
switch-enter notifications for 10 unique dpids, suspiciously consistent, and the ring is documented
to start inside that handler. But the matched control — a *successful* boot on the same baseline
router — shows **20 notifications / 10 unique**, i.e. two per switch. Successful boots have *more*
of these, not fewer. The failing boots' 12 is a **truncated** count: the app stops notifying when
it wedges. Symptom, not trigger. The comparison only worked because a successful-boot log was
captured to compare against; the failing logs alone would have supported the wrong conclusion.

**Sharpened**: every one of those lines, in both logs, is a `Failed to notify NDT (switch enter)`
**retry** — 12/12 and 20/20, zero successful notifications, because the kernel is not listening yet
at that point in the boot. Both logs carry the same 10 unique dpids. So the difference is not which
switches appeared, it is **how far the retry loop got**: the healthy boot completes a second round
for all ten, the wedged boot manages a second attempt for only two before the app stops draining.
That is the truncation, measured directly.

⚠️ **Unreconciled with the review round (N-2).** The review reports this same 12 decomposing as
`entered 2 + stateChange 10`, matching a USR2 frame dump's `entered=2/10`. That does not reproduce
here: `grep -c "inform_switch_entered"` is **12**, not 2, and is homogeneous — every line is a
`Failed to notify` retry, with `state_change` lines counting **10 in both** the failing and the
successful log. Two possibilities: they are measuring a different quantity (plausibly the dump's
internal counters rather than these log lines), or one decomposition is wrong. **Both sides agree
on the direction and on the refutation** — this affects only the finer mechanism. Query sent; do
not cite the decomposition until it reconciles.

## Leading hypothesis for the non-reproduction (untested)

The baseline's failures cluster at the **start** of its run: `F F F F S F S S F S`. Four
consecutive failures opening the sequence is unlikely if boots were i.i.d. at 60% (p ≈ 0.13), and
it fits a machine-state effect that decayed as the run went on. The 12:23 run directly followed a
full day of 5-tuple and 404 work; this repo has prior form for state surviving teardown
(orphan bmv2 switches outliving `mn -c`, clone replicas accumulating across proxy restarts,
tcpdump surviving SIGKILL under AppArmor).

**A cheap discriminating experiment for the next session**: reproduce the wedge deliberately by
running the boot rate immediately after a heavy P4/telemetry workload, versus on a cold machine.
If the wedge returns on the dirty arm only, the trigger is identified and both fixes finally become
testable. Until then, do not tune anything against a defect that cannot be summoned.

⚠️ **Confound I introduced**: all three of today's arms ran under `systemd-inhibit --what=idle:sleep`;
the 12:23 baseline did not. It blocks the idle/sleep timer only and should not touch scheduling or
CPU frequency, but it is a difference between the baseline run and every arm here, and it is not
ruled out.

## Consequences for decisions already on the books

- **Flipping the async default**: §5-P set the bar at "翻預設要有數據". There is now data for
  **speed** (2×, n=10, single variable) and **none** for the wedge. If the default flips, it must
  be on the speed argument, and the commit must not claim it fixes the boot failures.
- **The deck's "no boot seconds" ruling stands, and for a stronger reason than when it was made.**
  Today's 0/30 next to this morning's 6/10 means the failure rate is not stable over hours. Citing
  "52s" or "26s" would be the same survivorship error §5-P already warns about — the number is real
  but the population it came from is not characterised.
- **The 6/10 baseline stands as a real observation.** Six preserved `ryu.log`s show the wedge. It is
  not a measurement artifact; it is condition-dependent.

## Harness notes

Not a rerun of `boot_rate.sh`, which would have (a) truncated the 15 raws behind the 6/10 baseline
despite a header claiming C-1 immunity — the numbering disambiguates within a run, not across runs;
(b) claimed the lab as `review-0824`; (c) produced more suspend-inflated wall times.

**Baseline boot 8's `CONVERGED wall=7626s` was the laptop suspending** (`journalctl`: `PM: suspend
entry 13:04:58` → `exit 15:11:07`, 7569s; the raw's mtime is 3s post-resume). It is a genuine ~50s
convergence, so **6/10 stands as 6/10** and it is *not* evidence about self-healing. No deadline was
evaded: `CONVERGE_WAIT` defaults to 400 (`ndt:760`, which is what the 413–415s failures are) and
every wait-loop curl carries `--max-time 3`. `await_convergence` tests success *before* the
deadline, so a post-resume iteration returns through the success branch without consulting the
clock — which is why 2 hours of sleep was reported as a clean convergence.

**A defect in this harness, found by this run.** The provenance line printed `matches HEAD` while
the control arm ran the reverted router — the check whose only job was to catch exactly that.
`git diff --quiet -- <path>` compares worktree to **index**, and `git checkout <commit> -- <path>`
stages what it writes, so both sides agreed. Fixed to `git diff --quiet HEAD --`; the affected
output file carries an appended correction rather than an edit. The `sha256` on the same line was
correct throughout, and the revert was independently grep-verified before the run and sha-verified
after.
