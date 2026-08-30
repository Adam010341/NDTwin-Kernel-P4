# Pre-registration — live traffic round (full-stack #3), registered 2026-08-30 evening

[Co-developed with claude code -- Adam]

Registered by `8/29 auditor` **before any data**, while the harness repairs (T-10) are still
in flight. Nothing here has run. Reference rounds: 08-18 (`04b8933`) and T-4
(`doc/audit/2026-08-30_live-full-stack-round/`, kernel `89c1754`≡`faffdbe`).

## §0 Why this round exists

T-4's own closing finding: the whole round ran on a **quiet network**, and that single
condition weakened three results at once — R-2 was unfalsifiable (1800/1800 samples with
`flows` empty: a static path set answers identically at 1 kHz and 1 Hz), F-1 had no
table-miss to reach, and F-5's queue window had nothing competing with it. The registered
"single most valuable change" was traffic, not more samples and not a denser grid
(`assert-invariants-not-repro-rates`: when A/B cannot discriminate, move the working point
first). This round is that change, and nothing else: same stack, same checks, traffic on.

## §1 Working point

- **Arm 1 (primary): P4, 128 hosts** — the manual's own §6.5 example configuration.
  Dual-purpose, registered as two separate deliverables: (a) the round's checks run on it;
  (b) **TR-6**: the Installation Manual's 128-host example works as printed — a wiring
  claim only, no timing quoted.
- **Arm 2 (if the window allows, else third-branch): OVS** — solely because F-1
  (OFPP_CONTROLLER punt path) is only reachable there. Time-boxed like T-4's was; if not
  run, F-1 stays "unreachable this round", not "passed".
- Kernel: current tip at round start, built fresh, identified by commit sha **and** the
  identifier kind, plus one behavioural marker (the T-4 reverse-identification recipe).

## §2 Traffic design

- Base load: the chaos harness's `traffic.sh` pattern (previously measured able to offer
  >1 Gbit/s aggregate) as a background iperf3 mesh across N≥8 host pairs.
- **Churn**: one *new, never-before-used* src→dst pair started every ~30 s (this is what
  gives F-1 its table-miss events and R-2 a changing flow set).
- Idle guard windows before and after the traffic block, for contrast.
- 🔑 The offered rate is recorded **through the datapath** (per-arm `agg_sent` style), not
  from a loopback calibration — the OvS-control round's gate lesson, applied forward.

## §3 Registered checks

**TR-1 — R-2 with discriminating power.** Hard precondition gate: the sampled `flows`
array is non-empty during the traffic block. If it is still empty with traffic running,
that is a FINDING about the telemetry path, and TR-1 is otherwise untestable — it must not
be scored as a pass. Given the gate holds: does the path set change with the churn, and is
the 1 Hz recompute cadence visible in path freshness? Null branch: no observable
difference *with a changing flow set* is now an informative result (the opposite of T-4).

**TR-2 — F-1 on OVS (arm 2 only).** The churn must produce punt-path evidence (controller
packet-in / rule installation traceable to a new pair). Break condition: new pairs pass
traffic with no punt-path evidence anywhere — meaning the punt path is bypassed or the
instrument cannot see it; the two are distinguished before scoring.

**TR-3 — F-5 window under contention.** Repeat the FINDING-03 t=0 probe (structural
fingerprints: field count, absent counters, caller-vocabulary match) while the dispatch
queue is busy with churn-driven writes. Registered question: does the
queued-but-unprogrammed exposure window grow under contention? Any number is reported as
an observation bound, not a performance figure.

**TR-4 — `tools/contract_test` against the live kernel.** Discharges the one verification
T-7b could not run (its §0.0). Pass/fail per `spec.py` as written; the known
`release_lock_not_held` tolerance (`[412, 400, 404]`) is noted, not re-litigated.

**TR-5 — T-12's observation base (no claim made).** Energy watch on both arms with the
T-10 clocks, sim observable via its new disk log, ≥2 decision cycles per arm, zero
in-window commits, no VM, no invisible load. This round only *collects*; the P4/OVS
asymmetry question stays with T-12 and is not scored here.

**TR-6 — the manual's 128-host example** (see §1). Works / does not work / blocked-by,
with the manual's own words as the procedure.

## §4 Preconditions — the round must not start until all hold

1. **T-10 landed and auditor-reviewed** (running a knowingly-broken instrument twice is
   not replication), including the FINDING-04 restore-chain fix force-tested in both
   directions.
2. T-8's sim disk log landed (TR-5 is blind without it).
3. Lab claim exclusive, note names this round; `measuring` empty; **no VM anywhere in the
   window**; **no `git commit` repo-wide during the window** (rule retained on its
   post-agy rationale: recording the experiment is an intervention).
4. Binary identification recorded per `benchmark-must-name-the-binary-it-measured`.
5. Offered-rate gate measured through the datapath (§2), recorded per arm.

## §5 Out of scope, stated so it is not read as covered

- Any throughput/latency number as a performance claim — wiring and correctness only.
- The 128-host arm's timing (T_stack at 128 hosts is recorded as context, not compared).
- The poster line, entirely.
- T-12 adjudication (this round only feeds it).
