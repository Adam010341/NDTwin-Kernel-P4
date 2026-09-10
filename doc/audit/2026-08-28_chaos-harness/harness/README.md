# Chaos harness — implementation

**建立日 2026-08-29.** Implements `04_harness-spec.md` over the action surface in `01` and the
oracle in `02`, with `03`'s two must-fixes applied.

`01` and `02` supply structure and coverage. **Everything environment-specific in here is
ours** — the independent paths, the tolerances, and the list of actions that would destroy the
testbed rather than perturb it. Per `03`: *they can read the repo, they cannot read the traps
we have stepped in.* Divergences from the oracle are marked 🔧 in the source, each with a reason.

## Files

| file | what it holds |
| :--- | :--- |
| `probes.py` | measurement. No function returns an HTTP status; every shell-out is timed out |
| `antioracle.py` | `CpuGate` (the important one) + AO-01…13 as data |
| `invariants.py` | INV-01…08. Three narrowed, one half deleted, each marked 🔧 |
| `actions.py` | G1 positive controls and the chaos injections, with dry runs and self-assertions |
| `chaos.py` | runner: gates → null round → injection rounds → JSON report |

## Running it

```bash
python3 test_probes.py                          # parser self-test; offline, no fabric needed
python3 chaos.py --gates                        # G1/G2/G3 pre-flight only
python3 chaos.py --dry-run  --iface s1-eth3     # default; prints intent, touches nothing
python3 chaos.py --dry-run  --iface s1-eth3 --allow-link-blackhole   # ... incl. the tc netem one
python3 chaos.py --null     --iface s1-eth3 --pair 10.0.0.2,10.0.0.1 --dpid 1 --slow
python3 chaos.py --controls --owner "<your session>" --iface s1-eth3
python3 chaos.py --full     --owner "<your session>" --iface s1-eth3 --pair 10.0.0.2,10.0.0.1

./traffic.sh start 120   # h2 -> h1, asserts the traffic actually landed
./traffic.sh stop        # kills by RECORDED pid; never pkill -f
```

`--controls` runs the G1 positive controls **live** and checks each target invariant goes red.
It applies real faults, so it is gated exactly like `--full`. `--null` is read-only.

`--full` refuses unless `--owner` matches the live claim **and** the claim declares
`exclusive_cpu=yes`. Injection without that perturbs whoever else is measuring, invisibly to
them — that is the mechanism that voided a six-arm block on 2026-08-28.

**Per-action opt-ins (2026-09-07, E-4).** Two actions name a flag of their own and are REFUSED
without it, in **every** mode including `--dry-run` — the refusal is a row in the report saying
which flag would allow it, never a silent skip:

| flag | action | why it is gated |
| :--- | :--- | :--- |
| `--allow-poweroff` | G1-01 | really powers a switch down; its undo has never met a switch that was actually off |
| `--allow-link-blackhole` | T-netem | `tc netem loss 100%` on a live link; the undo's `parent` form has never been observed to be accepted by this machine's sudoers |

The flags are per action on purpose: a blanket `--force` is granted once and then covers
everything added afterwards. `link_blackhole` is **not** in `CHAOS_ACTIONS` and stays out
(Adam's ruling), so `--full` does not reach it — the dry run does, which is why the dry run is
inside the gate: an opt-in that exempted the only path to an action would gate nothing.

## The three things that make this more than a checklist

**1. `CpuGate` — the harness manufactures the violations it looks for.** Measured: ten CPU
burners that send **zero packets** take bmv2 loss from 0.000% to 2.192%, because the datapath is
a user-space process sharing one per-packet CPU budget. So any CPU-consuming action makes INV-04
and INV-05 fire on a correct system, and only while injecting — a false positive aligned with
the treatment. Busy fraction is sampled from `/proc/stat` (**not** `load1`, which is a lagging
composite on 14 cores and counts uninterruptible sleep) around every action; a rise of ≥0.15
over the round's baseline marks those invariants `INCONCLUSIVE-CPU`, never `PASS`. **The
`INCONCLUSIVE-CPU` rate is a reported result**: if it is high, these invariants are structurally
unmeasurable on bmv2 under chaos, and that is a finding.

⚠️ **Does not hold on OVS** (load1 43, ten burners, loss still 0.037%). The two planes need
separately calibrated anti-oracles. Sharing one is a correctness bug.

**2. The null round is the yardstick.** It injects nothing, so every FAIL it reports is a defect
in *this code*. Its count is printed as `false_positive_floor`, and any later round with fewer
violations than the floor has found nothing.

**3. Both gate branches have been run.** The allow-path dry run was exercised 2026-08-29 (it
only reads). The refuse path was exercised three ways against a live foreign claim. That matters
because a guard tested only by watching it refuse has never executed its dangerous branch — and
the moment a guard fails is the moment the thing it guards happens. 🔴 **2026-09-07:** for the
two actions behind an opt-in this now reads "*with its flag*" — their allow path is reached by
`--dry-run --allow-…`, and the default `--dry-run` records a refusal instead.

## 🔴 Not delivered — read this before trusting a green run

- 🔴 **Only INV-06 has a control demonstrated to fire — 1 of 7.** After the first live run
  (2026-08-29, [`../05_first-live-run.md`](../05_first-live-run.md)): INV-02/03/05 have no
  control at all; G1-04 is not implemented; G1-07 is paired with an invariant its defect cannot
  turn red; G1-01 is fixed but unrun, behind `--allow-poweroff`, because its undo has never met
  a switch that was actually off. `--full` refuses. **An invariant nobody has watched fail is
  not evidence** — and that now applies to six of the eight.
- **The null round HAS been run**: floor **0** quiet and **0** under traffic. It was 1 on the
  first attempt, and that violation was fabricated by the harness's own parser.
- ⚠️ **A green run still means little.** Nine defects came out of two rounds, and the two most
  dangerous — a control that never touched the system while reporting success, and an invariant
  that fails on a healthy fabric whenever traffic flows — were invisible to every check that
  existed before that day.
- **Deliberately not implemented**, with reasons in `actions.py`: H13/H15/H16 (live shell
  injection — real RCE on this host, needs a disposable VM), H17 (writes `/etc/exports` and
  reloads nfs-server), `01` §8.4 lifecycle abuse (hardest to reconcile with G2 — once the
  process is dead nothing is left to assert the injection landed), and the N-1 NTP step (a
  wall-clock jump hits every other session on this machine).
- **P4/BMv2 only.** See the OVS caveat above.
- **Inherited coverage ceiling:** `02` self-reports that its Chinese term searches were
  incomplete and 213 agy reviews are uncategorised, so this harness covers roughly the same
  ~70% of the known inventory that the oracle does. It cannot exceed its oracle.

## What the first real run cost, and what it bought

Run 2026-08-29. **Nine defects, all in the harness, none in NDTwin.** That is the expected yield
and it is the reason the null round goes first — but two of them are worth carrying forward
because no amount of code review had found them:

- A control that had **never executed a single line** against the system, for an entire build,
  while its own success-assertion confirmed it had. Its failure mode (a fast response) was
  identical to the defect it was hunting (a suspiciously fast success).
- An invariant that **fails on a perfectly healthy fabric whenever traffic is flowing** — i.e.
  in every injection round — because its stated precondition was enforced nowhere.

Both were found by running, not by reading. `live-runs-find-what-tests-cannot`.

[Co-developed with claude code -- Adam]
