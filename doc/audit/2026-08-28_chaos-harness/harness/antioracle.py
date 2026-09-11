#!/usr/bin/env python3
"""The anti-oracle: things that WILL look like violations and are not.

The centrepiece is `CpuGate`. Everything else in this harness could be right and the run would
still be worthless without it, because **the chaos actions manufacture the violations the
chaos harness is looking for** -- and only while injecting, so the false positive is aligned
with the treatment rather than spread across it.

Measured 2026-08-28, bmv2, 16 flows x 3 Mbit/s (a clean working point):

    no burner                              loss median 0.000%
    10 CPU burners that send ZERO packets  loss median 2.192%   (16/16 arms over 0.5%)

Not one of those burners put a packet on the wire. BMv2's datapath is a user-space process and
the whole switch shares one per-packet CPU budget, so forwarding competes with any load at all.
⇒ Any CPU-consuming chaos action makes INV-04 (rate conservation) and INV-05 (path) fire on a
system that is behaving perfectly.

⚠️ This does NOT hold on OVS: load1 43 with 10 burners still gave 0.037% loss. The two
forwarding planes need separately calibrated anti-oracles; sharing one is a correctness bug in
the harness, not a shortcut.

[Co-developed with claude code -- Adam]
"""
from __future__ import annotations

from dataclasses import dataclass, field

from probes import cpu_busy_fraction

# Busy-fraction rise, relative to the round's own baseline, above which INV-04/05 cannot be
# adjudicated. From `04` §2. Relative to a per-round baseline rather than absolute, because the
# machine is shared and the neighbours' load is not ours to subtract.
CPU_VOID_DELTA = 0.15

# Verdicts. INCONCLUSIVE_CPU is deliberately NOT a pass: calling it PASS asserts "checked, and
# it was fine", which is a claim the measurement cannot support.
PASS = "PASS"
FAIL = "FAIL"
INCONCLUSIVE_CPU = "INCONCLUSIVE-CPU"
SKIPPED = "SKIPPED"
# NOT-MEASURED is a fourth answer, and it is deliberately not any of the other three
# (FINDINGS-ALL #75). A check can be wired, called, and still have had nothing to measure --
# INV-01's latency half needs a power-on that OUGHT to do work, and on a healthy fabric there
# is none. PASS would claim "checked, and it was fine"; FAIL would accuse the system of the
# harness's own missing precondition; SKIPPED already means "this check did not run", which is
# the opposite fact and the one #17 chose for a refused request. Keeping them apart is what
# stops a reader -- or a grep over a round's JSON -- reading "no power-on happened this round"
# as "the power-on was honest".
NOT_MEASURED = "NOT-MEASURED"

# Invariants whose evidence is rate- or path-shaped, and therefore CPU-contention-sensitive.
CPU_SENSITIVE = {"INV-04", "INV-05"}


@dataclass
class CpuGate:
    """Baseline once per round; sample around each action; void the sensitive invariants."""

    baseline: float = 0.0
    peak: float = 0.0
    samples: list[float] = field(default_factory=list)

    def take_baseline(self) -> float:
        self.baseline = cpu_busy_fraction(1.0)
        self.peak = self.baseline
        self.samples = [self.baseline]
        return self.baseline

    def sample(self) -> float:
        b = cpu_busy_fraction(1.0)
        self.samples.append(b)
        self.peak = max(self.peak, b)
        return b

    @property
    def delta(self) -> float:
        return self.peak - self.baseline

    def verdict_for(self, inv_id: str, raw_verdict: str) -> tuple[str, str]:
        """Apply the gate. Returns (verdict, why).

        Only downgrades FAIL. A PASS under CPU pressure stays a PASS: contention makes these
        invariants fire spuriously, it does not suppress real violations, so a clean reading
        under load is if anything stronger evidence.
        """
        if inv_id not in CPU_SENSITIVE or raw_verdict != FAIL:
            return raw_verdict, ""
        if self.delta >= CPU_VOID_DELTA:
            return (INCONCLUSIVE_CPU,
                    f"busy fraction rose {self.delta:+.3f} over this round's baseline "
                    f"({self.baseline:.3f} -> {self.peak:.3f}), at or past the {CPU_VOID_DELTA} "
                    f"void threshold; on bmv2 that alone produces this violation")
        return raw_verdict, ""


# --------------------------------------------------------------------------------------------
# AO-01..13, from `02` §3, as data so a violation can be checked against them mechanically.
#
# Usage rule (`02`): an AO item ALONE is dismissed without further analysis. An AO item plus an
# INV violation that an INDEPENDENT path confirms is escalated -- the anti-oracle never cancels
# an invariant when independent measurement disagrees.
# --------------------------------------------------------------------------------------------
@dataclass(frozen=True)
class AntiOracleItem:
    id: str
    looks_like: str
    why_expected: str
    cheap_dismissal: str


ANTI_ORACLE: list[AntiOracleItem] = [
    AntiOracleItem("AO-01", "many nodes is_up=false, is_enabled=false, path 404 in the first seconds",
                   "topology loads with both flags false, then discovery populates; the path refresher sleeps its first interval",
                   "wait 5 s then 30 s and re-poll; converging means ignore"),
    AntiOracleItem("AO-02", "P4 proxy startup warnings, cleanupAppFolder false warnings",
                   "known startup chatter (A-6); inform_switch_entered retries and succeeds",
                   "look for the readopt outcome, not this line"),
    AntiOracleItem("AO-03", "per-link utilisation swinging +/-40% under steady iperf",
                   "sFlow 1/256 resolution floor 196/sqrt(c) dominates at low window or load",
                   "compare variance against the 1/sqrt(c) band; widen window or raise load and it shrinks as predicted"),
    AntiOracleItem("AO-04", "get_detected_flow_data ~92% duplicates with zero rates",
                   "designed 15 s idle retention (FLOW_IDLE_TIMEOUT)",
                   "age <= 15 s and rates zero is the expected tail; only >15 s with non-zero rates is real"),
    AntiOracleItem("AO-05", "get_average_link_usage 0.0 on an idle fabric drives an EA-App power-off",
                   "correct: it returns 0.0 when no edges are busy",
                   "if no host edge is up+enabled, 0.0 is right"),
    AntiOracleItem("AO-06", "~40 Mbit/s stock vs ~726 Mbit/s fast for the same workload",
                   "bmv2 -O0 full-logging build is the bottleneck, not the kernel",
                   "record which binary via bmv2_binary_override; only compare within one binary"),
    AntiOracleItem("AO-07", "OVS 4-host cell reports no flows and zero usage despite 50 Mbit/s",
                   "ovs_4host_topo.py configures no sFlow at all (A-4)",
                   "repeat on the 128-host topology; recovery means not a kernel fault"),
    AntiOracleItem("AO-08", "get_cpu_utilization and get_memory_utilization byte-identical",
                   "synthetic MININET metrics: 10 + hash(ip) % 50, a constant function of IP (F-1)",
                   "never gate on these values; assert only that power is 0 when is_up is false"),
    AntiOracleItem("AO-09", "left_link_bandwidth 1 Gbps for every core edge before the first sample",
                   "MININET_INTERFACE_SPEED default; Mininet silently ignores bw>1000 so 16 core edges are unshaped",
                   "wait one sFlow interval; compare only access edges, treat core as capacity-unknown"),
    AntiOracleItem("AO-10", "one ovs-vsctl warning then silence while liveness is frozen",
                   "FailureRun throttles to first failure by design",
                   "run ovs-vsctl list-br directly; a single warning line proves frozen, not healthy"),
    AntiOracleItem("AO-11", "P4 power-off leaves probe_ok true for ~3 s, then Unknown oscillation",
                   "p4LivenessFor: stale success -> Up, stale failure -> Unknown; beacon 12 s vs probe 15 s",
                   "do not judge power-off for 15 s; require probe DEADLINE_EXCEEDED plus no fresh beacon"),
    AntiOracleItem("AO-12", "empty qdisc on ~4 interfaces after a power cycle",
                   "OVSPowerStrategy::powerOff saves ports but not qdisc/sFlow (A-4f)",
                   "pre-record tc qdisc show; only the saved ports should be missing"),
    AntiOracleItem("AO-13", "sudo prompts, mn -c killing the caller, a name-matched kill taking "
                            "the wrapper with it (KNOWN-ISSUES G-9 carries the exact command)",
                   "documented operation traps (KNOWN-ISSUES G) -- run killers, not defects",
                   "follow the runbook; kill by recorded pid, never by pattern"),
]

AO_BY_ID = {a.id: a for a in ANTI_ORACLE}
