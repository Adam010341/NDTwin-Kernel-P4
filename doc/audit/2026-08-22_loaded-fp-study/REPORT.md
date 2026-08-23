# Loaded false-positive study: zero, but the interesting result is a boot that never converged

[Co-developed with claude code -- Adam]

Run 2026-08-22/23 at `8aba6af`+. Raw: `loaded_fp_study.txt`, `raw/`. Driver: `loaded_fp_study.sh`,
traffic config `loaded_flow.json`.

## What this was for

The idle study (`2026-08-21_lldp-guard-false-positives/`) measured zero false link deletions
across three 20-minute cells and was explicit that it could not settle the question: the worry
about `NDTWIN_RYU_LLDP_GUARD=0.01` is that it multiplies LLDP rate on the control channel ~5x,
and an idle channel is exactly where that pressure cannot show. Adam's ruling: run a loaded
round before 8/27, and **the loaded false-positive count is the number that decides whether the
guard becomes a default**.

Same three cells, so the two studies are directly comparable:

| cell | configuration |
|---|---|
| A | Ryu defaults |
| B | `NDTWIN_RYU_LLDP_GUARD=0.01` |
| C | `guard=0.01` + `NDTWIN_RYU_LLDP_BACKOFF=10` |

## The load was real, and asserted from outside NTG

NTG drove it (`flow --config loaded_flow.json` into the topo session, 4 flows/s arriving plus 8
sustained, TCP and UDP, middle and far host pairs). The fabric moved **2.5--3.7 GiB per 15 s**
at the check, and **219--264 GiB across a full 20-minute window**.

That assertion reads `/proc/net/dev` rather than NTG's own output, on the same principle that a
config file is not evidence of which binary ran. It earned its place immediately: the first
smoke run reported 0 MiB while NTG's own logs showed 112 successful flows at 11 MB each. See
"three faults the smoke runs found" below.

## The false-positive counts

| cell | load in window | false link deletions | `topology changed` | links at end | positive control |
|---|---|---|---|---|---|
| A (defaults) | 264 GiB | **0** | 0 | 32 | 49.3 s |
| B (guard 0.01) | 219 GiB | **0** | 0 | 32 | 15.9 s |
| C (guard + backoff) | 265 GiB | **0** | 0 | 32 | 11.6 s |

Every cell's positive control detected a real netem failure, so none of the zeros is the vacuous
kind that a fabric incapable of detecting anything would also produce.

**Zero loaded false positives at every configuration**, matching the idle study. On the question
it was commissioned to answer, the guard is clean under ~1.7 Gbps of aggregate traffic.

A second result falls out of the positive controls: the detection speedup **survives load**.
49.3 s -> 15.9 s is 3.1x for the guard alone, against 3.9x measured idle, and the backoff cell
lands at 11.6 s (4.3x). The guard does what it claims when the control channel is busy, which is
the case that mattered — and the backoff's extra gain is real, which is what makes the bootstrap
defect below worth fixing rather than abandoning.

## The result that should actually drive the decision

**Cell C failed to boot on its first attempt.** Not the window -- the boot. Its Ryu log:

```
NDTWIN: LLDP_SEND_GUARD overridden to 0.01s
NDTWIN: LLDP backoff enabled: never-answered ports probed every 10th sweep
10 switches connected
0 link events
0 all-pairs walks
```

Ten switches connected and **not one link was ever discovered**, so `load_static_topology` never
fired, no routes were installed, and `ndt`'s own verification caught it: *"data plane: h1 cannot
reach 10.0.0.2 -- fabric is up but not forwarding"*, with the kernel reporting 10 switches,
0 up. The rerun of the same cell booted normally (32 links) and produced the clean window above.

So it is **transient, not deterministic** -- and that is not reassuring, because the mechanism is
plausible rather than mysterious. `NDTWIN_RYU_LLDP_BACKOFF=10` probes never-answered ports every
tenth sweep. **At bootstrap every port is a never-answered port**, including every inter-switch
link, so the backoff cuts initial probing tenfold exactly when discovery has nothing yet to go
on. Combined with `guard=0.01` shortening each sweep, the first probe of a given port can land
late enough that discovery does not bootstrap inside the convergence window.

Counting every boot known at this configuration: idle study cell C (ok), loaded run 1 (**failed**),
loaded run 2 (ok). **One bootstrap failure in three.**

## Verdict

* **`guard=0.01` (cell B): the gate is passed.** Zero loaded false positives, positive control
  3.1x faster under load, and no boot has ever failed at this setting.
* **`backoff=10` (cell C): the gate is NOT passed, on a criterion this study was not designed to
  test.** Whatever its false-positive count turns out to be, a knob that prevents the fabric from
  converging one boot in three cannot become a default on the strength of a clean 20-minute
  window. The failure is silent in the worst way -- the fabric is up, every process is running,
  and only an end-to-end reachability check notices. Its window did come back zero, and its
  detection is the fastest of the three at 11.6 s; neither changes the recommendation, because
  the objection is to a knob that sometimes leaves the fabric unable to forward at all.

Recommendation: promote the guard, hold the backoff. Fixing the backoff is not obviously hard --
exempting ports that have never been probed *at all* from the deprioritisation, rather than
treating "never answered" and "never asked" as the same state, would address the bootstrap case
directly -- but that is a change plus its own round of evidence, not a footnote to this one.

## Three faults the smoke runs found

Recorded because each would have produced a plausible-looking study rather than an error:

1. **The topo session was in Mininet CLI mode.** `ndt up ovs` runs NTG's `testbed_topo.py`, but
   `setting/Mininet.yaml` ships `mode: "cli"`, and Mininet's CLI answers `flow --config` with
   `*** Unknown command`. Only `custom_command` gives the NTG prompt. The driver flips it and
   restores it on every exit path.
2. **The load assertion read the wrong columns.** `/proc/net/dev` right-aligns interface names,
   so `lo` is padded and `s10-eth3` starts at column 0 -- shifting every positional field by one
   depending on the name. `-F'[: ]+'` with `$3`/`$11` summed *packet counts*, reporting ~0 MiB
   against 11 MB per flow. It had been "verified" against `lo`, the one interface whose padding
   differs from the ones the study needs: a known-good check that could not fail.
3. **NTG's interval outlives the window**, and its iperf3 processes make `ndt down` refuse --
   correctly, since tearing a fabric out from under a live measurement loses the run silently.
   Cells now end their own load first.

Fault 2 is the one that mattered: without it this report would say "zero false positives under
load" about a fabric that was idle and believed otherwise -- precisely the conclusion the study
exists to rule out.
