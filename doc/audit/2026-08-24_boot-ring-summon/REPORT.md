# Summoning round — CPU contention does not summon the ring, but it breaks settle

**Headline: the boot ring did not reproduce in 16 boots. What CPU contention reproduces, 8 out
of 8, is a different and permanent failure — `settle=40` closing with zero host IPv4s learned.**

## Why this experiment, and not "dirty vs cold"

The brief was dirty-vs-cold. That framing died on inspection: teardown verifies clean (0 network
namespaces, 0 OVS bridges, 0 orphan processes) and 30 fabric cycles earlier the same evening did
not reproduce the wedge. The variable that actually separates the two populations is **boot
session**:

| boot session | span | uptime at test | result |
|---|---|---|---|
| `-1` | Aug 21 21:14 → **Aug 24 16:46** | **~67 h** | 6/10 failed |
| `0` | **Aug 24 17:01** → now | < 5 h | **0 ring wedges in 50 boots** |

The machine was rebooted at 16:46–17:01, between the review session's failures and every clean run
since. Session 0 now holds **50 boots** — 30 across the three verification arms, 3 smoke, 16 in this
round, 1 probe — of which 40 were unloaded. **Not one produced the ring**, including 10 at the
baseline commit with the router reverted. (10 of the 50 were deliberately loaded and failed as
`SETTLE-HOSTS`; that is this round's treatment, not the ring.)

67 hours cannot be manufactured, so this round tests the **proximate** mechanism the frame
dump already established: the ring closes when `load_static_topology` blocks inside
`EventSwitchEnter` long enough to fill the app's 128-slot queue. Anything that slows the walk
widens that window — and CPU contention is the controllable version of that.

## Design

8 pairs, 16 boots, **loaded and quiet alternating boot-by-boot**. Blocked arms would let drift in
machine condition masquerade as the treatment effect, which is exactly the trap the 12:23-vs-18:00
comparison fell into. Load is 14 busy-loop workers on 14 cores. Every boot archives `ryu.log`
(review note N-1: the previous round kept logs only on failure, had no failures, and left a claim
resting on one spot-check), records the enter/state-change decomposition, and is checked against
`journalctl` for suspend.

## Result

| arm | class | n | wall |
|---|---|---|---|
| loaded | `SETTLE-HOSTS` — `hosts=0/128`, 288e/**256**d | **8 / 8** | 77–93 s |
| quiet | `HEALTHY` / `HEALTHY-XX` — `hosts=128/128`, 288e/**0**d | **8 / 8** | 52–53 s |
| either | **`RING-WEDGE`** | **0 / 16** | — |

Zero overlap between arms. Quiet wall time is pinned at 52–53 s, identical to the `t_only` arm
hours earlier, so the harness is measuring the same thing it was then.

**It is not the ring, on three independent discriminators.** Every loaded boot shows 256 edges down
(not 288), `entered=10/10` (no enter-handler truncation), and a USR2 dump with **0 greenlets in
`_events_sem.acquire`**. This was also `7f7de4a`'s first run against a real failure, and its finding
is a negative one — which is what it is for.

## Permanent, not late — the probe

The run scores boots from twin reads at t+0 and t+20 only, which cannot distinguish "never learned"
from "learned after t+20". `probe_persistence.sh` settles it: one loaded boot, then sampling every
15 s for 20 minutes, with the load **dropped at t+609 s**.

**80 of 80 samples at `hosts=0/128, down=256`.** Ten minutes under load, then ten minutes idle —
no recovery at any point. Removing the cause does not undo the effect.

So "FAILED" is the right word, and this matches the settle-*value* regression's known shape: once
the learning window closes empty, it stays closed. That property was established for the settle
value and is now independently confirmed for the load-induced case rather than inherited.

## The finding that matters

**`settle=40` is not robust under CPU contention — 8/8, permanently, producing a twin blind to all
128 hosts.** §5-P already recorded that this default came from a bisect curve with one sample per
point and that "選值的依據比它看起來的弱". This is direct evidence it does not hold off an idle machine.

**And `ndt` reports `up. ready` while it happens.** Its `[4/4] verify` passes all three checks,
because "kernel graph matches the model file: 128 hosts, 288 edges" counts **edges**, not their
up/down state or host learning. A boot that leaves the twin blind to every host is reported as
success. That is a defect in the verification, separate from the defect in the default.

## Mechanism: open, deliberately

Loaded boots do **more** host learning and **more** route recomputation than quiet ones:

| | MAC→port entries | all-pair installs | hosts with IPv4 | down |
|---|---|---|---|---|
| loaded | **197** | 3–4 | **0** | 256 |
| quiet | 93 | 2 | 128 | 0 |

So "load shortens the learning window" **does not fit** — a slower walk should widen it, and MAC
learning is abundant. The failure is specific to **IPv4 association**, which is a different table
from MAC→port: `hosts=N/128` counts `/v1.0/topology/hosts` entries carrying an `ipv4` field, and per
the punt-window mechanism that field is only populated from IP packet-ins, with ARP blocked by
static ARP.

Connecting the extra all-pair reinstalls to zero IPv4 would be a story that fits the numbers. The
next step is to open the code that populates that field, not to write the story. **Do not cite a
mechanism for this until someone has.**

En route I nearly recorded the opposite of the table above: a normalized `diff` of the two logs put
the MAC→port lines in the "only in quiet" column, because the diff was over sorted line *shapes*
whose MAC values differ. Counting refuted it. That was the fifth wrong mechanism killed in this
session's work.

## Caveats, recorded rather than left to be found

- **The quiet arm is not pristine.** Interleaving means every quiet boot immediately follows a
  *failed* loaded boot. 2 of 8 quiet boots show a verify transient (`kernel: 10 switches, 0 up,
  0 enabled` on a fabric with 128/128 hosts, 288e/0d, forwarding fine) that appeared **0 times in
  30 consecutive boots** earlier the same evening. Treat that as a carryover artifact, not a
  property of quiet boots; the earlier 30-boot run is the better pristine baseline. Interleaving
  buys decorrelation from time drift by paying in order effects.
- **Ambient load is recorded, not assumed.** `raw/ambient_load.tsv` samples every 5 s. `load1` is a
  lagging one-minute average and spans 1.43–17.11 while injected workers are 0, because it decays
  from the preceding loaded boot — so it cannot characterize the quiet arm. The exact guarantee is
  the **asserted worker count: 0 before every quiet boot**. The `top_nonmine_cpu` column excludes
  only busy-loop workers, so its peak (500 % `python3`) is this experiment's own fabric, not a
  foreign process; it is not evidence of third-party load.
- **One reboot, n=1.** "Long uptime" is the only surviving covariate, and it rests on a single
  reboot boundary. It is a correlation, not a mechanism.

## Harness defects, all three found on the first live run

All three were in the load lifecycle, and all three are the reason the file looks paranoid:

1. **Command-substitution deadlock.** `workers_up=$(load_start)` hangs forever — `$(...)` waits for
   every background child to close stdout and the busy-loops inherit that pipe. **18 minutes, zero
   boots.** Found only because an ambient sampler added for an unrelated reason read 28 workers
   where 14 were expected.
2. **`$!` is not the worker.** `setsid cmd &` sets `$!` to *setsid*, which forks the real child and
   exits. `kill -0 $!` reports dead immediately; `kill -TERM $!` kills nothing. **Two smokes each
   reported "0 still alive" while leaking 14 workers.** Had the run proceeded, leaked workers would
   have run through the following quiet boot — producing a confident wrong answer rather than an
   obvious failure.
3. **`pgrep -c` prints `0` and exits non-zero**, so `|| echo 0` emits `"0\n0"` and the quiet-arm
   guard would have errored instead of guarding.

Fixes: unique argv marker with fresh scans instead of remembered pids, `EXIT`/`INT`/`TERM` trap,
and quiet boots **assert** zero workers rather than trusting `load_stop`'s own report — that report
was wrong twice. Note `pgrep -f` self-matches from an interactive shell (a pattern matching nothing
real returned 1, then 3); living in a script file is what makes the counts correct.

## What this means for the ring

Three hypotheses are now dead: `d1d973d` fixed it (refuted by the same-day control), leftover
P4/telemetry state (30 clean cycles), and CPU contention (this round). The wedge is real — six
preserved `ryu.log`s — but it is currently **un-targetable**, and neither fix can be validated
against it.

Recommendation: shelve it with its evidence intact rather than spend further lab time summoning it,
and take the settle robustness question next. That one is reproducible on demand, mechanically
open, and lands on a default that is queued to ship.
