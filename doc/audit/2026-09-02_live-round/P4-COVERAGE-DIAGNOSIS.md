# p4_coverage_gate.sh is red at 0.836364 — why

2026-09-02. Diagnosis only. **The gate was not run with `--update-baseline`, the baseline file
was not touched, and `MIN_COVERAGE` was not changed.** The recommendation at the end is a
recommendation; the decision is Adam's / the auditor's.

Evidence: `raw/B10_p4_coverage_gate.log` (tonight's gate run, rc=1) and the instrument log that
run left behind, `.test_run/logs/p4_coverage_gate.log`, written 21:13 — which is where the
numbers below come from. That file is p4testgen's own output, not a re-derivation.

[Co-developed with claude code -- Adam]

## Answer in one line

Coverage did not fall. **The denominator grew by one**, and the one statement added is inside the
block the baseline file itself documents as unreachable in principle.

## The numbers

| | statements covered | total | ratio | uncovered lines |
|---|---|---|---|---|
| baseline (`p4_coverage_baseline.txt`) | 46 | 54 | 0.851852 | 414–421 (8) |
| now | 46 | 55 | 0.836364 | 436–443, **447** (9) |

`46/54 = 0.851852` and `46/55 = 0.836364` exactly, and p4testgen prints the second as a raw
count, not a fraction to be reverse-engineered:

```
============ Test 53: Nodes covered: 0.836364 (46/55) ============
Not covered program nodes:
	ndtwin_switch.p4\436: hdr.packet_in.setValid();
	...
	ndtwin_switch.p4\443: hdr.packet_out.setInvalid();
	ndtwin_switch.p4\447: truncate(128);
error: The tests did not achieve requested coverage of 0.85, the coverage is 0.836364.
```

**The covered count is identical: 46 before, 46 now.** Nothing that used to be reached stopped
being reached. Lines 436–443 are the baseline's 414–421 — the same eight statements, renumbered
because the same commit inserted a 22-line comment block earlier in the file. Line 447 is new.

## Which of the three it is

**Did coverage genuinely fall? No.** Same 46 nodes. No test was deleted, disabled or made to
skip; no reachable statement lost its test.

**Did the denominator change? Yes — this is the whole cause.** `f64897b7` (2026-08-25 19:30:23,
*Truncate sampled copies to 128 B…*) added one statement, `truncate(SAMPLE_TRUNC_BYTES);`, at
what is now line 447. It sits inside

```p4
if (standard_metadata.instance_type == BMV2_INSTANCE_TYPE_INGRESS_CLONE) {   // line 428
```

which is the exact branch `p4_coverage_baseline.txt` already describes: a clone is a second
egress execution, the symbolic engine walks one packet down one path, so a branch keyed on
`instance_type` is unreachable *in principle, not by omission*. The 08-13 cross-check against
p4lang/tutorials pinned that to the condition rather than to the presence of clone. Line 447 is
in that block, so it inherits the same unreachability for the same reason as its eight
neighbours. It is not new debt; it is one more line of the debt that was already recorded.

**Did the measurement change? No.**
- `p4testgen` is unchanged: `/usr/local/bin/p4testgen`, mtime 2026-07-13 17:26,
  sha256 `5150cb4488ad07af195484e409638bd64bd1b72686889e48b2eb8de536042619`. It predates the
  baseline.
- `p4_coverage_gate.sh` and `p4_coverage_baseline.txt` last changed on 2026-08-13
  (`bc904f88`, `2cb70e07`) — twelve days *before* the commit that moved the number. Same flags,
  same file, same binary.

## When it crossed

**`f64897b7`, 2026-08-25 19:30:23 +0800.** Only two commits have touched the `.p4` since the
baseline was recorded, so this is settled by reading them rather than by bisecting:

| commit | date | effect on the `.p4` | gate |
|---|---|---|---|
| `9e3874c2` | 2026-08-13 19:16 | two **comment** lines: `doc/p4_bmv2_support_plan.md` → `doc/2026-07-27_…`, `doc/ndt_api.md` → `doc/2026-01-02_…` | still green — but no longer a no-op |
| `f64897b7` | 2026-08-25 19:30 | `+const SAMPLE_TRUNC_BYTES` and `+truncate(SAMPLE_TRUNC_BYTES);` in the clone branch | **red, 0.836364** |

`9e3874c2` is worth naming even though it moved nothing measurable. The gate only measures when
`git hash-object` disagrees with the recorded `sha`, and that comment-only edit landed four and a
half hours after the baseline was written on the same day. From 08-13 19:16 the gate ran its full
measurement on every invocation and passed; from 08-25 19:30 it failed. Nothing about tonight's
20-branch integration is involved, which is what `raw/B10`'s verdict line already said.

## Recommendation

**1. `--update-baseline` would not make this green, so it is not even the lazy fix.** It rewrites
`sha`, `coverage` and `uncovered`, but `MIN_COVERAGE=0.85` is a separate constant that the gate
hands to p4testgen as `--assert-min-coverage`. p4testgen fails first and returns nonzero, and the
gate exits at that check — before the uncovered-set comparison ever runs. Recording the new
baseline would leave the run red at the same number.

**2. The decision the gate is actually asking for is a one-line factual one:** is line 447
`truncate(128)` intended to be unreachable by any generated test? By the baseline file's own
argument, yes — same block, same `instance_type` condition, same reason. The honest record is
"nine known-unreachable lines, not eight". That is a decision, and per this repo's rules it is
Adam's or the auditor's to make, not mine; I have not made it.

**3. The structural problem, which will recur.** The floor is an absolute constant on a ratio
whose denominator counts provably-unreachable code. The headroom it had was
`0.851852 − 0.85 = 0.0019` — *one* unreachable statement. Any line added to the clone branch
crosses it, and the next one will too, no matter how well tested the program is.

The quantity that is actually stable here is coverage of the **reachable** program:

```
baseline:  46 / (54 − 8) = 46/46 = 1.000
now:       46 / (55 − 9) = 46/46 = 1.000
```

Unchanged, and it is the true statement about this `.p4`. Suggested shape of a repair, for
whoever takes the decision: stop passing p4testgen a fixed `--assert-min-coverage`, let the gate
compare what it measures against the baseline's own numbers, and keep the existing uncovered-set
shape check — which is the part that carries the real signal — as the thing that refuses new
unreachable code until someone records it deliberately. That check already had the right verdict
for tonight; the floor merely got there first with a less informative message.

**4. Is the fix "write tests for X, Y, Z"? No, and it is worth saying why not.** No host-side
test can move this number: line 447 is unreachable by generated tests for the same structural
reason as 436–443, so writing tests would leave 0.836364 exactly where it is. Anyone who "fixes"
the gate by writing tests is measuring the wrong thing.

There is a genuine gap next door, and it is not a coverage gap. `SAMPLE_TRUNC_BYTES` appears
nowhere outside the `.p4` — nothing asserts that the P4 `truncate()` extern took effect.
`tests/test_SFlowEmitterRoundtrip.cpp:227` does test a 128-byte truncation, but that is the
proxy-side sFlow emitter's own truncation: same number, different mechanism. And `f64897b7`'s own
comment flags this as the failure mode that already bit once — bmv2's runtime
`packet_length_bytes=128` on the mirror session silently killed telemetry on 08-20, every edge
reading zero with no error anywhere — so PREREG-D §2 requires independent proof that truncation
happened before climbing the ladder. That proof is a live-run artefact, not something this gate
can produce. Recording it is a separate job from this one and is not blocked on the gate.
