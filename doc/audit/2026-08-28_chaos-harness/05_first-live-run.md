# The chaos harness's first live run — 2026-08-29

Dispatched by `8/29 auditor`. Scope was exactly two things: the null round, and the four
existing G1 positive controls run live. The follow-on work (controls for INV-02/03/05, CPU
threshold calibration, wider action coverage) was explicitly deferred and is **not** done here.

Lab held by `開機手冊`, `exclusive_cpu=yes`, 13:08–16:08. Fabric: p4, 128 hosts, 10 bmv2 on the
**fast** build. Raw JSON for every run is in `raw/`.

---

## The headline

**The null round's false-positive floor is 0** — after nine defects were removed from the
harness. It was **1** on the first run, and that one violation was a fluent, confident,
completely fabricated claim about NDTwin:

> `INV-01 FAIL: graph claims 11 switches up, only 10 BMv2 processes exist — the twin is
> certifying dead switches (A-1 shape)`

Nothing was wrong with the fabric. The harness could not tell a host from a switch.

**Of the four positive controls, one fires. One is mis-paired, one was never implemented, and
one had never executed a single line against the system.** G1 is unmet, so `--full` refuses —
that refusal was left in place, as instructed.

| | before this run | after |
| :--- | :--- | :--- |
| false-positive floor, quiet | 1 (fabricated) | **0** |
| false-positive floor, under traffic | never measured | **0** |
| invariants reaching a verdict | 4 of 8 | **7 of 8** |
| controls demonstrated to fire | 0 (never run) | **1 of 7** (INV-06) |

---

## H-1 🔴 The harness counted hosts as switches, and the arithmetic error had the exact shape of its own finding

`switch_flags` keyed every graph node by `dpid`, with no type filter. On this fabric **all 128
hosts carry `dpid: 0`**, so they collapsed into one dict entry — last writer winning, `h128`,
`is_up: true` — and that survivor was counted as an eleventh switch.

Three rules broken at once, each sufficient on its own:

1. **The instrument produced its own finding's shape.** INV-01 hunts for "graph claims more
   switches up than exist". A +1 on the numerator manufactures precisely that.
2. **The error was constant, so the invariant had no resolving power at all.** +1 fires on a
   healthy fabric and a broken one, in the null round and every injection round alike. An
   invariant that answers FAIL regardless of input is not a weak check, it is not a check.
3. **The silent drop looked like coverage.** 127 of 128 hosts vanished into a dict collision
   while the evidence field printed a confident `"total": 11`.

Fixed by filtering on `vertex_type` (`GraphTypes.hpp:23` — `enum class VertexType { SWITCH,
HOST }`; `HttpSession.cpp:1219` states it outright). The helper now **raises `SchemaDrift`**
rather than coping: `.get("vertex_type", 0)` would have re-created the bug the first time the
field was renamed, silently and in the optimistic direction.

`test_probes.py` pins it against a **real captured payload** (`raw/graph_data_1309.json`), not a
hand-written fixture — a fixture I wrote would have contained one host with `dpid: 0` and
passed, because I would have written down what I believed rather than what the kernel sends. The
last check is the mutation gate: it confirms the numerator still tracks a switch going down, so
the fix did not turn INV-01 into a constant PASS.

## H-2 🔴 G1 never ran the invariant it existed to validate — and printed "FIRED"

`gate_g1_controls` applied each control, called `ctl.verify()`, and reported **FIRED**. But
`ctl.verify()` asks *"did the defect reproduce?"* — that is G2. Whether the **invariant
noticed** was never asked; no invariant function was called anywhere in the gate.

So G1 could report all-green while every invariant was blind — the exact condition G1 exists to
rule out. The distinguishing question, "if the invariant were deleted entirely, would this gate
go red?", answered **no**.

This is `verify-the-purpose-not-the-mechanism` at one function's distance: the mechanism (the
fault landed) was checked; the purpose (the check catches it) was not. The word "FIRED" named
the thing that had not been measured.

Now both are recorded separately — `reproduced_g2` and `invariant_before` / `invariant_after` —
and a control passes only when the invariant goes red **because of it**.

**Payoff:** under the old code this run would have reported **2 of 4 controls "FIRED"**. Both
were blind.

## H-3 🔴 The only destructive control had never touched the system, and its own G2 confirmed success

`_c01_apply` (A-1, power a switch off then on) had two independent defects, either one fatal:

1. It sent **GET**. The route is `http::verb::post` only (`HttpSession.cpp:177`) — nothing
   matched.
2. It sent **`dpid=1`**. The handler reads `ip` (`HttpSession.cpp:653`) and answers
   `400 Missing or invalid ip/action` without it. Even as a POST it would have done nothing.

🔑 **Why a whole build went by without anyone noticing is the reusable part.** A-1's signature is
*"success, suspiciously fast"*. An unrouted request is also fast. `_c01_verify` timed a request
that never reached the power code, measured **0.0069 s**, and reported *"fast path reached"* —
the instrument's failure mode is byte-identical to the defect it hunts.
`instrument-must-not-mimic-its-own-finding`, seventh form.

The pre-state capture, the restore path, the `setsid` and the ordering were all correct
precautions taken around an action that was inert.

Fixed — which makes it genuinely destructive for the first time, so it is now behind
`--allow-poweroff` and **has not been run**. `verify` now judges on **state** (graph `is_up`
count vs live process count) with latency only as corroboration.

## H-4 🔴 …and it had no undo, for an action documented not to be self-recovering

`P4PowerStrategy.cpp:100-114` records, from a live fabric on 2026-08-12, that power-off →
power-on **does not recover a P4 switch**: the proxy's prober keeps hammering the dead port,
grpc-python's process-global subchannel pool hands that address's accumulated backoff to the
fresh channel readopt builds, and the power-on returns 502. The process comes back; the pipeline
does not, and the 1 Hz probe then marks the switch **up** while it cannot forward a packet —
the harness's own target defect, self-inflicted.

An `undo` now drives the documented recovery (`POST /p4/readopt/<dpid>`, retried). It was
smoke-tested against a **healthy** s1 first (`routes_installed: 32/32`) — a restore path first
exercised during an emergency has not been tested, it has been hoped for.

⚠️ **Still unproven against a switch that is actually off**, which is why the opt-in stays.

## H-5 🔴 The claim gate worked only because nobody had followed the documented protocol

`ndt status` renders the claim line *relative to* `NDT_OWNER`: `claim yours -- 171m left` when it
matches, the owner's literal name when it does not. `gate_g3_claim` substring-matched the name —
so it passed only because this session never exported `NDT_OWNER`.

`ndt`'s own help tells every user to do exactly that: `export NDT_OWNER='my-session-name'`.
Anyone following it would have been **refused access to their own lab, by a message naming
themselves as the blocker**:

```
old:  require_ours not in 'yours -- 169m left'   -> True  (REFUSE)
```

Fixed by running `ndt status` under the identity passed to `--owner`, so `yours` means exactly
"the claim belongs to who I said I am" — the tool doing the comparison instead of us
re-implementing it. Both directions re-tested: a foreign `--owner` still refuses; a caller whose
shell exports a *different* `NDT_OWNER` now correctly passes.

This is the **second** defect found in this one gate — the first, last week, was
"a claim exists" being confused with "the claim is mine".

## H-6 🔴 Two defects of my own, both about *when* a check runs rather than what it checks

- **The baseline was taken after the fault.** My first cut of the G1 rewrite ran
  `probe_one_invariant` *after* `ctl.apply`. The very first live run caught it: G1-06's "before"
  reading was already FAIL, because `_c06_apply` had run and left a lock behind. A control
  credited with a failure it inherited proves nothing, and one blamed for a pre-existing failure
  is just as wrong.
- **The G2 verify repaired the fault it had just confirmed.** `_c06_verify` ended with
  `release_lock`. So it confirmed B-2 had reproduced, cleaned it up, and *then* the invariant
  ran and found a healthy system — reported as `BLIND`, "the invariant missed it", when the
  truth was the harness had tidied the evidence away. **G2 must observe, never repair**; repair
  belongs in `undo`, after the invariant has had its turn.

With both fixed, **G1-06 FIRED** — clean PASS baseline, FAIL under the injected defect, lock
verified free afterwards. The first control in this harness demonstrated to work.

## H-7 🔴 INV-07 fails on a perfectly healthy system whenever traffic is flowing

Measured, not reasoned. Null round with an iperf3 running:

> `INV-07 FAIL: 2 flow(s) still report a non-zero rate 16s after traffic stopped, past the 15 s
> idle timeout — zombie entries (N-1 shape)`

Traffic had not stopped. The invariant's `quiet_s` precondition was **stated in the parameter
name and enforced nowhere**.

This is not a small problem. `--full` *needs* traffic for INV-04 and INV-05 to have any
resolving power, so every injection round would carry live traffic and INV-07 would fail in
every one of them — **a false positive perfectly aligned with the treatment**, the hardest kind
to catch and the easiest to write up as a discovery.

Fixed: INV-07 now measures the interface itself and returns SKIPPED when the fabric is busy. An
invariant that cannot tell *stale* from *busy* must say so rather than pick the accusatory
reading. Mutation-gated both ways — SKIPPED under 1.1 Gbit/s, and still reaching a real verdict
when quiet.

## H-8 G1-04 was counted as written and cannot fire

`_c04_apply`'s live branch returned `ActionResult(False, "…wired up by the runner, not here")`,
and the runner does not wire it up. `STATUS.md` counted it among "4 of 7 controls written", so
the tally said 4 while the number that could ever fire was 3. Left refusing loudly rather than
quietly dropped. `traffic.sh` (added here) is the missing piece.

## H-9 G1-07 is paired with an invariant it cannot make fire

The control reproduces **B-3** — `historical_logging` reports enabled and writes zero rows. It
verified true. But INV-07 is about **flow-table freshness**. They are about different subsystems,
so no amount of B-3 will ever turn INV-07 red. Not a blindness bug; a mis-pairing in the oracle
map. **Unfixed** — it needs either a different control for INV-07 or a new invariant for B-3, and
that is new-control work, which this round was told not to do.

## H-10 My own undo raised a false alarm, in the session's signature shape

`_c01_undo` retried readopt five times, got `mastership not granted` each time, and printed
**`🔴 s1 NOT RECOVERED after 5 attempts`**. The fabric was fine — s1 had never gone down (H-3),
so readopt correctly refused: there was nothing to re-adopt. My success criterion
(`routes_installed > 0`) could not distinguish *"repaired"* from *"nothing needed repairing"*.

Same family as everything else here: a check whose failure branch is indistinguishable from
"no action required".

---

## Observations about NDTwin, not the harness

These came out of the run; none is a chaos finding, and none was injected.

- **S-1 🔑 `lockName` does not namespace anything.** Measured directly:
  ```
  acquire alpha(ttl=30) -> {'status': 'locked', 'ttl': 30, 'type': 'routing_lock'}
  acquire beta (ttl=5 ) -> {'error': 'Lock acquisition failed',
                            'detail': 'System busy or invalid lock type: routing_lock'}
  ```
  Every name maps to a single global `routing_lock`. The parameter is accepted and ignored, so a
  caller who thinks they took a private lock has taken the one real routing operations use. The
  error string also conflates two different conditions — *busy* and *invalid lock type* — in one
  message.
- **S-2 INV-04's tolerance at c=2 is ±138.6%.** The 196/√c band is correct and honest, but with
  two flows it will accept almost anything (the observed errors were 3.3% and 5.9%). INV-04 has
  near-zero resolving power until the flow count is much higher — worth stating so a PASS is not
  over-read.
- **S-3 INV-03 passed vacuously**: `0 rule(s), twin and switch agree`. Two empty sets agree.
  Zero is both a legitimate value and the default-on-failure, which is the first form of
  `instrument-must-not-mimic-its-own-finding`.
- **S-4 One iperf3 alone takes CPU busy fraction from 0.045 to 0.33–0.39.** The inherited
  anti-oracle threshold of 0.15 is therefore exceeded by ordinary traffic before any chaos is
  injected. Calibration was deferred this round; this is the datum it should start from.
- **Pre-existing, not caused here:** cross-fabric ping (`h1 → 10.0.0.65`) fails, and the proxy
  reports 3968 of 16256 destination paths. Both were true before the run and identical after.
  Recorded in `raw/pre-state_controls.txt` and `raw/post-state_controls.txt` so no later round
  attributes them to chaos.

---

## H-11 🔴 Not one artefact from this run named the binary it measured

Found after the fact, by a sibling session asking a one-line question: *is this fabric on stock
or fast?*

Nothing in `raw/` could answer it. `ndt status` had said `bmv2-fast` and the argv had said
`bmv2-fast`, but **the JSON reports recorded neither**, and my own pre-state capture piped the
argv through an `awk` that stripped the path — leaving `3436314 255`, a pid and a port number.
By the time the question arrived the fabric had been rebuilt (the current bmv2 processes start
at 13:55; mine were pid 3436314 and are gone), so the processes could no longer be interrogated
either. The evidence existed **only in a session transcript**, which is precisely what
`evidence-must-outlive-the-handoff` rules out.

What can still be said, and at what strength:

| | |
| :--- | :--- |
| `ndt status` during the run reported `binary /usr/local/bmv2-fast/bin/simple_switch_grpc` | contemporaneous, quoted in the release note — but it is the kernel's own reporting |
| `pgrep -af` at 13:18 showed `/usr/local/bmv2-fast/bin/simple_switch_grpc -i 3@s1-eth3 …` | contemporaneous and independent, **but only in the transcript, not in `raw/`** |
| the two builds are genuinely different files | `3ff54b5c…` (fast) vs `327fa7d1…` (stock) |
| pid 3436314 was the same process from pre-state to post-state | recorded, so nothing swapped mid-run |

⇒ **I am confident the run was on `bmv2-fast`, and I cannot prove it from the committed raw.**
Stated that way round on purpose.

Fixed forward: `probes.bmv2_provenance()` now goes into **every** report, including `--dry-run` —
running paths with counts, sha256 of each, the override file's declaration, and loud
`MIXED_BUILD` / `OVERRIDE_MISMATCH` / `OVERRIDE_UNREADABLE` keys. Provenance is one level below
the strongest form and says so in the payload: `/proc/<pid>/exe` is unreadable as this uid, so
it is argv cross-checked against the override file — the same compromise ticket ① settled on.

🔑 **And writing the mutation test for it immediately found a defect in it.** Run from
`harness/`, the override cross-check `open()`ed a cwd-relative path, failed, and **skipped the
comparison entirely** — the check quietly became no check, for exactly the people who ran it the
normal way. It now resolves the file by walking up from `__file__`, and an unlocatable file
raises a loud key instead of reading like a match. `harness-cd-hides-working-directory-defects`,
on the same afternoon it was cited in a different fix.

## ⚠️ One run overlapped a background CPU job

`8/29 auditor` flagged afterwards that a `post-commit` `agy` review ran **13:16–13:22**.
Timeline from the reports' own `started` fields:

```
13:09:12  null-01      before
13:13:08  null-02      before
13:20:00  controls-01  🔴 OVERLAPS
13:30:24  controls-02  after
13:32:23  controls-03  after      <- G1-06 FIRED
13:33:49  null-03      after
13:35:37  null-04      after
13:38:59  null-05      after      <- the quoted floor
13:39:31  controls-04  after      <- the quoted G1 state
```

Only `controls-01` overlaps. Nothing quoted anywhere in this document rests on it: every floor
and every G1 verdict comes from a run that started after 13:30, and `controls-01`'s findings
(wrong HTTP method, mis-paired control, unimplemented control) are structural — confirmed by
reading the routing table, not by timing. The one timing number it produced, 0.0069 s, is
corroboration for H-3, whose proof is `HttpSession.cpp:177` and `:653`. The auditor also
re-measured that `agy` round at **0.7% of one core**, not the 207% the standing warning cites.

## Where G1 stands now

| invariant | control | state |
| :--- | :--- | :--- |
| INV-01 | G1-01 | fixed, **never run** — destructive, undo unproven, behind `--allow-poweroff` |
| INV-02 | — | no control |
| INV-03 | — | no control |
| INV-04 | G1-04 | not implemented; `traffic.sh` is now available to build it |
| INV-05 | — | no control |
| INV-06 | G1-06 | ✅ **FIRED** — baseline clean, invariant red under the fault, state restored |
| INV-07 | G1-07 | mis-paired; B-3 cannot make this invariant fire |

**1 of 7.** `--full` refuses, correctly.

## Next, in order

1. Re-pair G1-07, or write an invariant that B-3 can actually turn red.
2. Implement G1-04 on `traffic.sh` — it already drives 1.1 Gbit/s past a link declared at 1 Gbps,
   which is the clamp condition.
3. Run G1-01 with `--allow-poweroff`, **after** designing a restore that has been tested against
   a switch that is genuinely off.
4. Controls for INV-02, INV-03, INV-05.
5. Calibrate the CPU threshold, starting from S-4 rather than from the inherited 0.15.

## Reproducing

```bash
cd doc/audit/2026-08-28_chaos-harness/harness
python3 test_probes.py                                     # parser self-test, offline
python3 chaos.py --null --iface s1-eth3 --pair 10.0.0.2,10.0.0.1 --dpid 1 --slow
./traffic.sh start 120 && python3 chaos.py --null --iface s1-eth3 \
    --pair 10.0.0.2,10.0.0.1 --dpid 1 --slow ; ./traffic.sh stop
python3 chaos.py --controls --owner "<your session>" --iface s1-eth3
```

| raw file | what it is |
| :--- | :--- |
| `null-01_no-traffic.json` | **the fabricated finding**, floor = 1 |
| `null-02_after-inv01-fix.json` | floor = 0, but 4 of 8 invariants asleep |
| `null-04_under-traffic.json` | **INV-07's false FAIL**, floor = 1 |
| `null-05_final_under-traffic.json` | floor = **0**, 7 of 8 with a verdict |
| `controls-01.json` | first live controls: 0 fired, old G1 would have said 2 |
| `controls-03_g2-no-repair.json` | **G1-06 FIRED** |
| `controls-04_final.json` | final state |
| `pre-state_controls.txt` / `post-state_controls.txt` | fabric identical before and after |

[Co-developed with claude code -- Adam]
