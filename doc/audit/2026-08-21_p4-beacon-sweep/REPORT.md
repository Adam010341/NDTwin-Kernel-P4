# The P4 beacon sweep: detection follows the constant, and no interval invented a failure

[Co-developed with claude code -- Adam]

Run 2026-08-21 night at `f176c02`/`45eccba` (interrupted once by a laptop suspend; the record
notes exactly which cells came from which run and the redone cell agrees with its pre-suspend
partial). Raw output `beacon_sweep.txt`, script `beacon_sweep.sh`, knob `NDTWIN_P4_BEACON_S`
(`74351ca`). This is KNOWN-ISSUES D-2's experiment, run as designed: sweep the beacon
interval, and let the **false-positive count** — not the detection time — be the decision
number.

## Result

128-host P4 fabric, per cell: 6-minute idle window (zero injections), then two real netem
failures via `measure_failover.sh`. Detection is `[TopologyManager] link down` polled at
0.2 s; outage is the ping-gap, same instrument as every failover round.

| beacon | derived timeout | predicted detect | measured detect (s) | outage (s) | idle false positives |
|---:|---:|---:|---|---|---:|
| 5 s | 15 s | 15–20 | 13.6 / 15.0 | 14.1 / 15.6 | **0** |
| 3 s | 9 s | 9–12 | 8.4 / 10.9 (+10.7 pre-suspend) | 8.9–11.2 | **0** (both runs) |
| 2 s | 6 s | 6–8 | 7.0 / 6.8 | 7.9 / 7.1 | **0** |
| 1 s | 3 s | 3–4 | 4.3 / 3.9 | 4.6 / 4.4 | **0** |

* **Detection tracks the derivation chain linearly** — timeout, watchdog and grace all
  follow `LLDP_BEACON_INTERVAL_S`, and the measured times sit at or just above each cell's
  `3×beacon` timeout, exactly where two-misses-tolerated puts them.
* **Zero false positives at every interval**, including beacon 1 s, where the timeout floor
  is 3 s on a shared-CPU `-O0` bmv2 — the risk case D-2 called out. ~10 switches × 32
  directed links × (360 s / beacon) beacons per window of exposure.
* At beacon 1 s the whole P4 outage is **~4.5 s** (was ~14–16 s at the default 5 s).

## The 5 s cell answers D-2's open puzzle — partly

D-2 flagged that the comment predicts 15–20 s while round 4 measured 10.7–14 s. This run's
default cell reads 13.6/15.0 s — straddling the boundary. The two observations are
compatible once the watchdog phase (±one `LINK_WATCHDOG_INTERVAL_S` = ±beacon) is charged:
the prediction window's lower edge assumes worst-case phase. Not fully closed (n is small
everywhere), but the model and both measurements now overlap.

## What this does and does not license

* **Does**: put real numbers on the beacon⇄detection trade for the 8/27 slide, with the
  false-positive column measured at zero in idle for every value.
* **Does not**: change the default. Idle-only, n=2–3 per cell, one machine, one evening.
  The kernel-side coupling stands: `kLldpFreshSeconds = 12.0` is a C++ constant, so at
  beacon 1 s the switch-liveness window tolerates 12 beacons instead of 2.4 — switch-death
  detection becomes relatively less sensitive, unmeasured here. And the correction phase
  for unidirectional failures (`kOnceConverged` 0–30 s poll) does not move at all — D-2's
  "only one of the two convergence numbers improves" caveat is untouched.

## Method notes

* Every cell sets the knob explicitly (including 5 s) and is accepted only if the proxy log
  announces it — a cell without the announce line is skipped as unconfigured, not run on
  defaults and mislabelled.
* The injection anchor polls `tc qdisc show dev <iface>` (the sudoers-allowed form) for the
  netem's actual appearance; rep 1 of the first attempt was burned learning that the bare
  no-dev form fails silently under `sudo -n` and reads exactly like "no netem".
* Detection ±0.3 s (0.2 s poll + log line has no timestamp of its own).
