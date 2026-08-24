# The stock/fast control: identical ladders, so "zero new failures" is now a measurement

[Co-developed with claude code -- Adam]

Run 2026-08-22 at `9702d2c`. Raw: `stock_ladder.txt`, `raw/{stock,fast}_ladder.out`,
`raw/{stock,fast}_up.out`. Driver: `stock_ladder.sh`.

## What was missing

B2 ③'s verdict on 2026-08-21 was deliberately narrow: *the fast build introduced zero new
failures*, not *the ladder passes*. That wording was only defensible because each residual red
was attributed by argument -- and the control that would have turned the argument into a
measurement, the same ladder on the stock binary, was never run. Adam's ruling: control green
-> promote fast to default.

## Method, and the comparison that was almost made instead

The first version of this ran only the stock arm, to be diffed against the 2026-08-21 fast
ladder. That would have been worthless. Between those two runs the invocation changed
(`--traffic` dropped, `TOPO_P4` corrected), the OVS L4 baseline was re-banked, and the settle
default moved -- four variables, one of them the binary. **A control varies one thing**, so both
arms run here, back to back, through one code path.

Each arm verifies from `/proc/<pid>/cmdline` which binary the live switches actually run, and
sha256s it against `bmv2-binary-provenance.md`, refusing to run the ladder on a mismatch. This
is not ceremony: both installs answer `--version` with `1.15.3-f0b7d201`, and this exact pair
has already been confused once in an A/B where both numbers looked plausible. An arm that
silently ran the other binary would produce a perfect "identical failures" result meaning
nothing.

## Result

| layer | stock (-O0) | fast (-O3) |
|---|---|---|
| L0 build | PASS | PASS |
| L1 unit tests | PASS | PASS |
| L2 API contract (p4) | PASS | PASS |
| L3 component contract (p4) | PASS | PASS |
| log allowlist | **FAIL** | **FAIL** |
| capture p4 responses | PASS | PASS |
| L4 OVS/P4 differential | PASS | PASS |

Boot: 36 s stock, 34 s fast. Failed contract checks: none on either arm.

**Identical, including the one failure.** The log allowlist red is a property of the plane and
the harness, not of the fast build. "The fast build introduces zero new failures" is no longer
an argument.

## Last night's five "P4-plane gaps" and four L4 diffs were the harness, not the plane

Last night's ladder left five P4-plane contract gaps (`/stats/flow` `[]` stub, `get_power_report`
empty, cpu/memory/temperature null) and four L4 diffs. Tonight, on **both** binaries, L2/L3/L4
all pass. The difference is not the binary -- it is the invocation:

* `TOPO_P4` now names the 128-host model. Left at its 4-host default under a 128-host fabric,
  every graph-shape check compares a *correct* answer against the wrong declared file. This
  script hit that defect on its own first run, despite it being documented the previous night,
  because it invoked `run_layers.sh` directly without setting it.
* `--traffic` is dropped. It requires flows/paths/rates and was passed with no generator
  running, which failed every flow-presence check by construction.

So the honest revision of last night's report: of its residual reds, exactly **one** survives a
corrected invocation on **both** binaries -- the log allowlist, which is not one of the five gaps.
All five gaps and all four L4 diffs pass once TOPO_P4 names the right model and --traffic is
dropped. (An earlier heading here said "two of five", a number matching no set in the evidence.)

## Promotion

Licensed by the above and applied in the same commit:

* `DEFAULT_BMV2_BINARY` is now `/usr/local/bmv2-fast/bin/simple_switch_grpc`, not the bare name
  `simple_switch_grpc` (PATH lookup -> stock).
* **The fallback is removed in both directions.** `resolve_bmv2_launcher` now raises when the
  override file is absent or carries no directive. Promoting fast to default does not remove
  the silent-binary trap, it *inverts* it: silence would hand the fast binary to someone who
  wanted stock. Neither direction is left silent, so the binary in use is always something a
  human wrote down.
* Three tests that asserted the old fallback now assert the refusal, including that the message
  names the offending file. Mutating the refusal back into `return DEFAULT_BMV2_BINARY, None`
  is killed by two of them.

## Still red

The log allowlist, identically on both arms. Not investigated here -- it is now known to be
binary-independent, which is all this run was for.
