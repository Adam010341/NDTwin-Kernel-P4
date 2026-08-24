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
sustained, TCP and UDP, middle and far host pairs). The fabric moved **2.5--3.6 GiB per 15 s**
at the check, and **214--265 GiB across a full 20-minute window**.
(All GiB figures are MiB/1024 -- an earlier revision divided some by 1000 and some by 1024 in the
same table, a <=2.4% inconsistency that touched no decision number since every cell scored 0.)

That assertion reads `/proc/net/dev` rather than NTG's own output, on the same principle that a
config file is not evidence of which binary ran. It earned its place immediately: the first
smoke run reported 0 MiB while NTG's own logs showed 112 successful flows at 11 MB each. See
"three faults the smoke runs found" below.

## The false-positive counts

| cell | load in window | false link deletions | `topology changed` | links at end | positive control |
|---|---|---|---|---|---|
| A (defaults) | 258 GiB | **0** | 0 | 32 | 49.3 s |
| B (guard 0.01) | 214 GiB | **0** | 0 | 32 | 15.9 s |
| C (guard + backoff) | 265 GiB | **0** | 0 | 32 | 11.6 s |

Every cell's positive control detected a real netem failure, so none of the zeros is the vacuous
kind that a fabric incapable of detecting anything would also produce.

**Zero loaded false positives at every configuration**, matching the idle study. On the question
it was commissioned to answer, the guard is clean under **1.5--1.9 Gbps** of aggregate traffic
(derived from the same MiB totals; the earlier "~1.7 Gbps" came from the mixed-divisor figures
corrected above).

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

So it is **transient, not deterministic**.

### 🔴 CORRECTION, 2026-08-24: this was NOT the backoff's fault

The paragraph that stood here blamed `NDTWIN_RYU_LLDP_BACKOFF=10`, reasoning that it probes
never-answered ports every tenth sweep and that *at bootstrap every port is a never-answered
port*, so it starves discovery exactly when discovery has nothing to go on. The mechanism is
plausible and the arithmetic fits. **It is also unsupported, and the next default-configuration
boot refuted it.**

While running P1-3 two days later, an OVS boot at **plain defaults** — no `guard`, no `backoff`,
`settle=40` — failed with the identical signature:

```
XX  kernel: 10 switches, 0 up, 0 enabled (want 10)
XX  data plane: h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding
```

⚠️ **That transcript no longer exists.** `repro_404.sh` wrote each boot's output to a name it
reused, so a second invocation of the driver overwrote `raw/boot2_up.out` with a *successful*
boot — this citation briefly pointed at the opposite of what it claims. Caught by the review
session on 2026-08-24 (correction C-1b); the driver now archives each run under a sequence
number instead. The surviving evidence for the defaults failures is the 3-of-5 table in
[`2026-08-24_path-switch-count-404/REPORT.md`](../2026-08-24_path-switch-count-404/REPORT.md),
whose first-round rows exist **only in prose** for the same reason.

The failure is therefore a property of OVS bring-up on this machine, not of the backoff knob.
Attributing it to the knob was the classic error: one failure, in the cell carrying a
distinctive environment variable, and no defaults control run to check it against.

**Rate — superseded, read the second line.** This block first said "across roughly twenty OVS
boots this week … two failed to converge … a low, real, intermittent rate". That was written
before the P1-3 runs and is now the optimistic half of a contradiction: those runs saw **three
failures in five known-outcome boots at plain defaults**. Cite the 404 report's figure, not this
one. What survives from the original sentence is the part that mattered — **no evidence the rate
differs between configurations** — and the attribution correction stands on three defaults
failures rather than one.

**The recommendation below does not change, but its reason must.** Holding the backoff is still
right — it is a knob whose safety is unproven — but "it prevents the fabric converging one boot
in three" was never established, and anyone who went hunting for a bootstrap bug inside the
backoff patch on the strength of it would be looking in the wrong place.

## Verdict

* **`guard=0.01` (cell B): the gate is passed.** Zero loaded false positives, positive control
  3.1x faster under load, and no boot has ever failed at this setting.
* **`backoff=10` (cell C): hold it, but see the correction above for why.** Its window came back
  zero and its detection is the fastest of the three at 11.6 s, so nothing in *this study's own
  measurements* argues against it. The reason to hold is narrower than first written: it is an
  unproven knob with no independent evidence behind it, and the bootstrap failure once cited
  against it turns out to happen at plain defaults too. Promote it only on its own evidence, not
  on the absence of a fault it was wrongly charged with.

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
