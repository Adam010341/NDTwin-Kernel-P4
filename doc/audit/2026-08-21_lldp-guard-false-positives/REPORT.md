# Faster LLDP probing invented zero link failures — and the failover walk is 0.24 s

[Co-developed with claude code -- Adam]

Run 2026-08-21 night at `f151100`, full 128-host OVS stack (kernel polling, sFlow — the
realistic idle, not a bare Ryu). Raw output `fp_study.txt`, script `fp_study.sh`.

## Why this was the gate

The 3.9× detection speedup (`NDTWIN_RYU_LLDP_GUARD=0.01`, `DETECTION.md`) and the
never-answered-port backoff (`NDTWIN_RYU_LLDP_BACKOFF`, `e44e956`) both argue their safety
from the same fact: `link_loop`'s six-consecutive-misses threshold is untouched. But that is
an argument, not a measurement — a 5× LLDP packet rate is 5× the pressure on the same control
channel the probes themselves ride on, and nobody had measured whether that pressure makes a
healthy link miss six probes in a row. B2 ②'s own criterion says the false-positive rate is
the decision number. n=3 detection runs over five minutes was not that measurement.

## Result

| cell | knobs (proven from the log's announce lines) | false deletions, 20 min idle | links | positive control |
|---|---|---:|---|---|
| A | Ryu defaults | **0** | 32 → 32 | detected in 42.6 s |
| B | guard 0.01 | **0** | 32 → 32 | detected in 12.8 s |
| C | guard 0.01 + backoff 10 | **0** | 32 → 32 | detected in 14.8 s |

Zero `Link deleted:` lines in every idle window, zero `topology changed` events, link count
unchanged — and each cell then detected a real netem failure, so the zeros are not a fabric
that would also have missed a real death (smoke the accept path, not just refusals).

Exposure per window at guard 0.01: a ~1.6 s sweep over 160 ports ⇒ each of the 64 directed
sw-sw link ends probed ~750 times ⇒ ~48 000 probe opportunities, none of which produced even
one false deletion, let alone six consecutive misses. Cell C's backoff raises the per-link
probe rate further (host ports skipped) and still produced none.

**Cell C also live-validates the backoff feature end to end**: announce line present, fabric
discovered normally (32 links), 20 min of stable operation, real failure still detected.

### Detection times in the controls (n=1 each — context, not headline)

42.6 / 12.8 / 14.8 s land where `DETECTION.md`'s n=3 cells predict (44.86 and 11.51 s).
C reading higher than B is inside the noise this method carries: `link_loop` wakes every
`TIMEOUT_CHECK_PERIOD` = 5 s, so single measurements carry up-to-5-s phase jitter, and these
are polled at 0.2 s besides. Whether backoff further speeds detection needs the n=3
tail-stamped protocol; this study's job was the false-positive column.

## The bonus: the failover-path walk, three times

Every positive control triggers `_route_reinstall_worker` — the call site `WALK_SWEEP.md`
still owed a number for. All three cells:

```
walk=0.242s install=0.092s report=0.151s   (A)
walk=0.241s install=0.090s report=0.151s   (B)
walk=0.244s install=0.090s report=0.153s   (C)
```

**0.24 s, indistinguishable from the startup walk's 0.25 s** (n=3, `walk_sweep_o1-token.txt`).
"Same function, same graph, same cost" was an assumption; now it is a measurement.

## What this does and does not license

* **Does**: retire "誤判率完全沒量" as the blocker on the 3.9× claim. The idle false-positive
  rate at guard 0.01, with and without backoff, is zero across ~10⁵ probe opportunities.
* **Does not**: license changing the defaults on its own. This is the *idle* fabric; a loaded
  fabric (NTG traffic saturating the shared-CPU bmv2/OVS host) is the harder case and remains
  unmeasured. Defaults stay put; the knobs stay knobs.

## Method notes

* Knob proof is read from the log, not from env: this repo has shipped a setter with no
  reader and a reader with no setter, and both produced runs that looked configured.
* Detection here is polled (±0.3 s), unlike `DETECTION.md`'s tail-stamped numbers.
* One window per cell, sequential, same evening, same machine — no interleaving, so slow
  drift between cells is not controlled for. Three cells × zero events leaves nothing for
  that confound to act on.
