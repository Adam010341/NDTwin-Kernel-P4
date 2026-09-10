# tests/shell — the gates, and what makes one count as wired

Three kinds of file live here:

| | what it is |
|---|---|
| `test_*.sh` | ordinary shell tests. The script under test is driven with fakes on `PATH` and its output is read back; most need no build and no compiler. |
| `mutate_*.sh` | mutation gates. Each edits a source file by exact text, rebuilds, and requires the suite it protects to go **red**. A gate that cannot make its suite fail is protecting nothing. |
| `check_gate_anchors.py` | read-only anchor accounting over every gate. For a given rev it counts each gate's anchor strings in the files that gate mutates. It never writes a file, never builds, never runs a gate. |

The gates are this project's evidence that a test would notice the defect coming back — `CLAUDE.md`
states the rule they exist for: **a test nobody has seen fail is not delivered.**

## Wiring a new mutation gate

Writing the script is not wiring it. Four things have to be true, and each one has cost us
something to learn.

### 1. `check_gate_anchors.py` saying `ok` does not mean the gate runs

The checker answers one question: can each anchor still be found, the number of times its gate
declares? A gate whose every anchor resolves can still be unable to apply a single mutation — and
the gtest suite it protects stays green throughout, so nothing else says so either.

Two instances, both on 2026-09-05, both found by running the gate:

- **W3 / #89, gate M1.** `validateStaticTopologyJson` gained a third parameter; the gate's
  `validate-call` anchor still read `(j, where)`. That round M1 reported
  `SURVIVED (anchor could not be applied)` — a *survivor*, which is what a hole in the tests looks
  like — **while the whole suite was green and no test would ever have said a word.** Fixed in
  `1d376070`, and the lesson is now in that gate's own M1 header: change the signature of an
  anchored function and the thing to run is the anchor checker, not the tests.
  See `doc/audit/2026-09-05_fix-topology-three-doors/FIX-TOPOLOGY-THREE-DOORS.md`, §anchor 對帳.
- **W2 / #88, gate M7.** The mutation passed a **two-line** anchor without a uniq line, and the
  gate refused it: `anchor matches 2 times` → M7 INVALID. **`check_gate_anchors.py` called the same
  gate `ok(10)` at the same moment**, and both tools were right. The checker counts with
  `str.count()` over the whole file, where that two-line anchor really does occur exactly once;
  the gate's `assert_unique` counts with `grep -c -F`, which is per line, so two lines are two
  patterns matching once each. **The gate is the stricter instrument, and the gate's verdict is
  the one we ship.** Fixed in `e1bf73ba`.
  See `doc/audit/2026-09-05_fix-ip-front-guards/FIX-IP-FRONT-GUARDS.md`, the M7 entry.

⇒ **A new gate is wired only when it has been run for real, every mutant has been seen red, and
that run is pasted into the FIX document.** A clean `check_gate_anchors.py` is a precondition of
delivery, never the delivery.

### 2. Count anchors with the checker from the same rev

`check_gate_anchors.py` and the gates evolve together, so an old checker against newer gates
invents damage. On 2026-09-05 the checker from merge-base `f0687b34` run over the gates at
`68c1dde4` produced one extra bad cell out of thin air — `mutate_redirection_order.sh`,
`tools/remote-lab/ndtwin-vm.sh`, count 2 want 1 — which was a version mismatch between checker and
gate, not a broken anchor. With that rev's own checker the same tree read `73/73 cells ok`, exit 0.

So when the question is "did my branch break an anchor":

```
git show <rev>:tests/shell/check_gate_anchors.py > tests/shell/_probe_checker.py   # remove it after
python3 tests/shell/_probe_checker.py <rev>            # the question
python3 tests/shell/_probe_checker.py <known-good-rev> # the control, whose number you already know
```

Without the control you cannot tell a regression you caused from a version effect you inherited.
(Measured in the W2+W3 pre-merge check, 2026-09-05 17:2x; the run log is that night's scratch,
`scratch/overnight-2026-09-05/fix/VERIFY-W2W3.md` §4, which is outside version control.)

### 3. Guard or bare — read the gate first, and never nest

Every build on this laptop goes through `tools/build_guard/guarded_build.sh`, which takes
`/tmp/ndtwin-build.lock` via `flock`. Some gates call the guard themselves, once per build; the
rest do not. Which one you have decides how you launch it, and getting it wrong deadlocks:

| the gate | how to run it |
|---|---|
| calls the guard itself | **bare** — `JOBS=1 LOCK_WAIT=10800 ./tests/shell/<gate>.sh` |
| does not | **wrapped** — `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh ./tests/shell/<gate>.sh` |

Tell them apart before launching:

```
grep -n 'guarded_build\|"\$GUARD"' tests/shell/<gate>.sh
```

Read the hits. An executable `"$GUARD" ...` line means it self-guards; hits only inside the header
comment (a `Usage:` line saying to wrap it) mean it does not.

🔴 **Never both.** On 2026-09-04 `guarded_build.sh ./tests/shell/mutate_cpu_report_no_ip.sh` — a
self-guarding gate wrapped in an outer guard — held the build lock for **3 hours**: the outer guard
took the lock, the script's inner guard waited on the same lock, and the tree sat there until the
inner `flock -w 10800` gave up at 17:57 with
`guarded_build: another build has held /tmp/ndtwin-build.lock for 10800s -- giving up`, which the
gate reported as a failed baseline build. That round's M2 verdict was void — it was the self-lock
talking, not the mutation. Two gates carry
the warning in their own headers: `mutate_unknown_identifier_is_not_zero.sh:39-40` and
`mutate_nickname_does_not_rewrite_the_file.sh:31`.

`NO_GUARD=1` is the escape hatch for a machine where the guard is not installed. It is not a way to
skip the guard here, and any run that uses it says so in its log.

### 4. A gate that holds the lock for the whole round starves everyone else

This is **W-GATE-LOCK** (`scratch/overnight-2026-09-04/recon/fixplan.md` §0.2, item 3): a gate
wrapped in the guard for its entire round holds `/tmp/ndtwin-build.lock` from first build to last.
Measured in the early hours of 2026-09-04: **1 h 33 m held continuously, 7 waiters.** It happened
again on 2026-09-05 16:24, when the W3 gate ran under an outer guard for its whole round and the W2
gate queued about 17 minutes on `flock` behind it.

The shape that does not starve anyone is the one `mutate_first_address_of.sh` uses: **take the lock
inside `build()`, per build**, so other sessions get the gaps between compiles. Prefer that for a
new gate; where an outer wrap is unavoidable, say in the FIX document how long the round held the
lock, and do not launch two C++ gates at once.

Whichever shape you have, pass `LOCK_WAIT=10800` when other sessions are active. The default is
3600 seconds, and a gate that gives up on the lock has built nothing and proved nothing.

## Before you call a new gate wired

1. `check_gate_anchors.py` clean, run from the rev's own checker, with a control rev (§1, §2).
2. The gate ran for real: every mutant **caught**, `0 survived`, `0 invalid`, no skipped round.
   A skipped round is not a pass — the gates that have two rounds exit non-zero for exactly this.
3. Controls stayed green. Behaviour-preserving edits that go red mean the harness reports red for
   any edit, and `N/N caught` from such a harness says nothing.
4. Restore verified: files byte-identical to the pre-run snapshot, suite green again after restore,
   test binary sha unchanged.
5. That run — the reds, verbatim — pasted into the FIX document. This is the step that turns a
   script in this directory into a gate the project relies on.
6. How it was launched (bare or wrapped) and how long it held the build lock, in the same document.

[Co-developed with claude code -- Adam]
