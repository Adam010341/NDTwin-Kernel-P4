#!/usr/bin/env python3
"""INV-01..08.

Structure and coverage come from `02_oracle_muse.md`. The *independent paths* and the
tolerances are rewritten here against `03` and `04`, because that is precisely the column an
external model cannot supply -- it reads the repo, it does not know what we have tripped over.
Three of the eight are deliberately narrower than the oracle wrote them, and one is half
deleted. Each divergence is marked 🔧 and says why.

Every check judges STATE through a path the kernel does not write. None reads an HTTP status.

[Co-developed with claude code -- Adam]
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable

import probes
from antioracle import FAIL, PASS, SKIPPED


@dataclass
class Finding:
    inv: str
    verdict: str
    detail: str
    evidence: dict = field(default_factory=dict)


@dataclass
class Context:
    """What a round knows. `expected_switches` is captured before any injection: without it,
    'the process count is N' cannot be turned into 'N is wrong'."""
    expected_switches: int = 0
    plane: str = "p4"
    round_name: str = "?"
    notes: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------------------------
def inv01_power_state_agreement(ctx: Context) -> Finding:
    """Graph is_up must agree with the process table and the data plane, not with its own 200.

    A-1: P4PowerStrategy::powerOn returns success when getVertexIsUp is already true, so the
    graph can read UP with the bmv2 pid gone. The honest path takes ~1.27 s; the lie takes
    ~0.01 s, so latency is part of the signature.

    🔧 Independent path rewritten. The oracle specified `pgrep -a simple_switch_grpc`, which
    matches nothing at all -- see probes.bmv2_process_count.
    """
    graph = probes.graph_data()
    if graph is None:
        return Finding("INV-01", SKIPPED, "graph unreadable (body did not parse)")

    try:
        flags = probes.switch_flags(graph)
    except probes.SchemaDrift as e:
        return Finding("INV-01", SKIPPED, f"cannot tell switches from hosts in the graph: {e}")
    up_in_graph = sum(1 for n in flags.values() if n.get("is_up") is True)
    try:
        live = probes.bmv2_process_count()
    except (RuntimeError, probes.Timeout) as e:
        return Finding("INV-01", SKIPPED, f"process count unavailable: {e}")

    ev = {"graph_up": up_in_graph, "bmv2_processes": live, "expected": ctx.expected_switches}

    # Only the optimistic direction is a lie. Fewer graph-up than processes means the twin is
    # behind, which is a different (and much less dangerous) shape than claiming health.
    if up_in_graph > live:
        return Finding("INV-01", FAIL,
                       f"graph claims {up_in_graph} switches up, only {live} BMv2 processes "
                       f"exist -- the twin is certifying dead switches (A-1 shape)", ev)
    return Finding("INV-01", PASS, f"graph {up_in_graph} up vs {live} live processes", ev)


def inv01_powercycle_latency(dpid: str | int) -> Finding:
    """The A-1 fingerprint directly: power-on that returns far too fast to have done anything.

    Latency as evidence, not the status code. ~0.01 s is the documented lie; ~1.27 s is the
    documented honest path.
    """
    _, dt = probes.api_get_timed(f"/ndt/set_switches_power_state?dpid={dpid}&action=on")
    ev = {"elapsed_s": round(dt, 4)}
    if dt < 0.1:
        return Finding("INV-01", FAIL,
                       f"power-on answered in {dt:.4f}s; the honest path measures ~1.27s, so "
                       f"nothing was attempted (A-1 early return)", ev)
    return Finding("INV-01", PASS, f"power-on took {dt:.3f}s, consistent with real work", ev)


# --------------------------------------------------------------------------------------------
def inv02_edge_liveness(ctx: Context) -> Finding:
    """🔧 NARROWED. The oracle said "the two flags disagree ⇒ violation". That fires on correct
    behaviour: `is_up=false, is_enabled=true` is the normal steady state of a switch that has
    been powered off (round 6 correction).

    The A-2 fingerprint is the *specific* pair `is_up=true, is_enabled=false` -- a graph frozen
    by a wedged topology poll while the fabric still forwards. Only that pair is reported.
    """
    graph = probes.graph_data()
    if graph is None:
        return Finding("INV-02", SKIPPED, "graph unreadable")

    try:
        flags = probes.switch_flags(graph)
    except probes.SchemaDrift as e:
        return Finding("INV-02", SKIPPED, f"cannot tell switches from hosts in the graph: {e}")
    bad = [k for k, n in flags.items()
           if n.get("is_up") is True and n.get("is_enabled") is False]
    benign = [k for k, n in flags.items()
              if n.get("is_up") is False and n.get("is_enabled") is True]

    ev = {"a2_fingerprint": bad, "powered_off_normal": len(benign), "total": len(flags)}
    if bad:
        return Finding("INV-02", FAIL,
                       f"{len(bad)} switch(es) show the A-2 fingerprint is_up=true, "
                       f"is_enabled=false: {bad[:8]} -- topology poll wedged while forwarding "
                       f"continues", ev)
    return Finding("INV-02", PASS,
                   f"no A-2 fingerprint ({len(benign)} switch(es) in the benign "
                   f"powered-off state, which is not a violation)", ev)


# --------------------------------------------------------------------------------------------
def inv03_flow_table_identity(ctx: Context, dpid: str | int) -> Finding:
    """Twin's cached table vs what the switch actually holds.

    B-1 ghost rules: the kernel answers 200 "queued" and updates its own cache before the
    southbound result exists, so a rule can be in the twin and nowhere else.

    ⚠️ Reads liveness FIRST. `getOpenFlowTables` respects liveness, so a switch marked down
    reads as an empty table even when it holds rules -- scoring that as "cache diverged" would
    be a false positive produced by the gate rather than by the data.
    """
    graph = probes.graph_data()
    try:
        flags = probes.switch_flags(graph) if graph else {}
    except probes.SchemaDrift as e:
        return Finding("INV-03", SKIPPED, f"cannot tell switches from hosts in the graph: {e}")
    node = flags.get(dpid) or flags.get(str(dpid)) or flags.get(int(dpid) if str(dpid).isdigit() else dpid)
    if node is not None and node.get("is_up") is False:
        return Finding("INV-03", SKIPPED,
                       f"dpid {dpid} is down; tables read empty by design, so nothing is decidable")

    twin = probes.api_get(f"/ndt/get_switch_openflow_table_entries?dpid={dpid}")
    real = probes.api_get(f"/stats/flow/{dpid}", base=probes.PROXY)
    if twin is None or real is None:
        return Finding("INV-03", SKIPPED,
                       f"twin={'ok' if twin is not None else 'unreadable'} "
                       f"real={'ok' if real is not None else 'unreadable'}")

    def keyset(payload) -> set:
        rows = payload if isinstance(payload, list) else payload.get("entries", []) if isinstance(payload, dict) else []
        out = set()
        for r in rows if isinstance(rows, list) else []:
            if isinstance(r, dict):
                out.add((r.get("priority"), repr(sorted((r.get("match") or {}).items()))))
        return out

    t, r = keyset(twin), keyset(real)
    ghosts, missing = t - r, r - t
    ev = {"twin_only": len(ghosts), "switch_only": len(missing)}
    if ghosts:
        return Finding("INV-03", FAIL,
                       f"{len(ghosts)} rule(s) exist in the twin's cache and not on the switch "
                       f"(B-1 ghost rule)", ev)
    if missing:
        return Finding("INV-03", FAIL,
                       f"{len(missing)} rule(s) on the switch are absent from the twin", ev)
    return Finding("INV-03", PASS, f"{len(t)} rule(s), twin and switch agree", ev)


# --------------------------------------------------------------------------------------------
def inv04_rate_conservation(ctx: Context, iface: str, window_s: float = 5.0) -> Finding:
    """Twin's reported rate against wire bytes, with a tolerance that inherits sFlow's noise.

    🔧 Two narrowings, both from `04` §3:
      * tolerance is 196/sqrt(c), not a flat ±5%. A derived quantity's tolerance has to be as
        wide as the noise it inherits, or a correct system fails.
      * **below 3 Mbit/s no verdict is returned at all.** The estimate quantises to a single
        quantum there (F-9), so the comparison has no resolving power. SKIPPED, not PASS.

    🔴 The bounded-quantity trap is checked separately and first: link_bandwidth_usage_bps is
    CLAMPED to the declared capacity, so at exactly 1e9 the twin's number is a model constant
    wearing a measurement's clothes. Comparing a clamped value to wire and calling the gap a
    rate error would misattribute a known clamp.
    """
    b0 = probes.iface_bytes().get(iface)
    if b0 is None:
        return Finding("INV-04", SKIPPED, f"{iface} not present in /proc/net/dev")
    time.sleep(window_s)
    b1 = probes.iface_bytes().get(iface)
    if b1 is None:
        return Finding("INV-04", SKIPPED, f"{iface} disappeared mid-window")

    wire_bps = (b1[1] - b0[1]) * 8.0 / window_s
    flows = probes.flow_data()
    twin_bps = sum(f.get("estimated_flow_sending_rate_bps_in_the_last_sec", 0) for f in flows)
    samples = len(flows)
    ev = {"iface": iface, "wire_bps": int(wire_bps), "twin_bps": int(twin_bps), "flows": samples}

    if abs(twin_bps - 1_000_000_000) < 1:
        if wire_bps > 1_050_000_000:
            return Finding("INV-04", FAIL,
                           f"twin pinned at exactly 1.000 Gbit/s while wire carries "
                           f"{wire_bps/1e9:.2f} Gbit/s -- capacity clamp publishing a model "
                           f"constant as a measurement", ev)
        return Finding("INV-04", SKIPPED,
                       "twin sits exactly on the declared capacity; the value is clamped and "
                       "therefore decorative, so nothing is decidable here", ev)

    if wire_bps < probes.LOW_RATE_FLOOR_BPS:
        return Finding("INV-04", SKIPPED,
                       f"wire {wire_bps/1e6:.2f} Mbit/s is below the {probes.LOW_RATE_FLOOR_BPS/1e6:.0f} "
                       f"Mbit/s quantisation floor; the sFlow estimate has no resolving power here", ev)

    tol = probes.sflow_tolerance_pct(samples)
    err = abs(twin_bps - wire_bps) / wire_bps * 100.0 if wire_bps else float("inf")
    ev.update({"error_pct": round(err, 2), "tolerance_pct": round(tol, 2)})
    if err > tol:
        return Finding("INV-04", FAIL,
                       f"twin {twin_bps/1e6:.1f} vs wire {wire_bps/1e6:.1f} Mbit/s = {err:.1f}% "
                       f"error, past the {tol:.1f}% sampling band for c={samples}", ev)
    return Finding("INV-04", PASS, f"{err:.1f}% error within the {tol:.1f}% band (c={samples})", ev)


# --------------------------------------------------------------------------------------------
def inv05_path_consistency(ctx: Context, src: str, dst: str,
                           settle_s: float = 5.0) -> Finding:
    """🔧 The endpoint is changed. The oracle judged path changes with `get_path_switch_count`;
    on OVS that returns 5 for all three states (before install, after install, after delete) --
    zero discriminating power. `get_detected_flow_data`'s `path` names the actual switches.

    🔧 Tolerance for lag: the data plane switches sub-second, the twin's path follows in about
    3-5 s. Judging sooner reports a race as a defect, so the caller must let it settle.
    """
    time.sleep(settle_s)
    flows = probes.flow_data()
    mine = [f for f in flows if probes.flow_pair(f) == (src, dst)]
    if not mine:
        return Finding("INV-05", SKIPPED,
                       f"no flow {src}->{dst} in the table; with FLOW_IDLE_TIMEOUT at 15 s this "
                       f"means the traffic stopped, not that the path is wrong")

    paths = {tuple((h.get("node"), h.get("interface")) for h in (f.get("path") or [])) for f in mine}
    ev = {"distinct_paths": len(paths), "records": len(mine),
          "path": [list(p) for p in list(paths)[:2]]}

    empty = [p for p in paths if not p]
    if empty:
        return Finding("INV-05", FAIL,
                       "a flow is reported with an EMPTY path while it is actively sampled -- "
                       "the twin cannot say where its own traffic goes", ev)
    if len(paths) > 1:
        return Finding("INV-05", FAIL,
                       f"{len(paths)} different paths reported for one 5-tuple within a single "
                       f"snapshot -- the twin disagrees with itself", ev)
    return Finding("INV-05", PASS, f"one consistent {len(next(iter(paths)))}-hop path", ev)


# --------------------------------------------------------------------------------------------
def inv06_lock_mutual_exclusion(ctx: Context, lock: str = "chaos_probe") -> Finding:
    """Mutual exclusion judged by OUTCOME, never by status code -- the oracle is explicit here
    and it is right: LockManager has no owner field, unlock clears any lock, and renew never
    compares against the expiry, so every one of acquire/renew/release can answer 200 and lie.

    The only observable truth is whether a second client can take a lock it should not be able
    to take.
    """
    got_a = probes.api_post("/ndt/acquire_lock", {"lockName": lock, "ttl": 3})
    if got_a is None:
        return Finding("INV-06", SKIPPED, "lock endpoint unreachable")

    b_during = probes.api_post("/ndt/acquire_lock", {"lockName": lock, "ttl": 3})
    b_took_it = isinstance(b_during, dict) and str(b_during.get("status", "")).lower() in ("locked", "acquired")
    ev = {"b_acquired_inside_ttl": b_took_it}
    if b_took_it:
        probes.api_post("/ndt/release_lock", {"lockName": lock})
        return Finding("INV-06", FAIL,
                       "a second client acquired the same lock inside the first TTL -- mutual "
                       "exclusion does not hold (B-2 family)", ev)

    # Now the expiry: after the TTL lapses with no renew, a fresh acquire MUST succeed. If it
    # does not, the lock is stuck -- the other half of the same ownership blindness.
    time.sleep(4.0)
    b_after = probes.api_post("/ndt/acquire_lock", {"lockName": lock, "ttl": 3})
    b_after_ok = isinstance(b_after, dict) and str(b_after.get("status", "")).lower() in ("locked", "acquired")
    ev["b_acquired_after_expiry"] = b_after_ok
    probes.api_post("/ndt/release_lock", {"lockName": lock})
    if not b_after_ok:
        return Finding("INV-06", FAIL,
                       "the lock was still held ~1 s after its TTL expired with no renew -- "
                       "stuck lock", ev)
    return Finding("INV-06", PASS, "exclusive inside the TTL, released after it", ev)


# --------------------------------------------------------------------------------------------
def inv07_telemetry_freshness(ctx: Context, quiet_s: float = 20.0,
                              iface: str | None = None) -> Finding:
    """Idle must be distinguishable from dead. After traffic stops, the flow table should decay
    to empty ~15 s later (FLOW_IDLE_TIMEOUT). Entries that outlive that while still claiming a
    non-zero rate are the N-1 zombie shape.

    Measured 2026-08-29 on a healthy fabric: last record at t+312 s, empty at t+317 s, client
    having exited at ~t+302 s. So the decay itself is confirmed working -- this check exists to
    catch it NOT working.

    🔴 THE PRECONDITION IS NOW CHECKED, because it was load-bearing and unenforced. This
    invariant assumes traffic has STOPPED -- the name `quiet_s` says so and nothing verified it.
    Run against a fabric with an iperf3 flowing, it reported (2026-08-29, measured, not
    reasoned):

        "2 flow(s) still report a non-zero rate 16s after traffic stopped, past the 15 s idle
         timeout -- zombie entries (N-1 shape)"

    on a completely healthy system, because traffic had not stopped at all. That is not a small
    problem: `--full` needs traffic for INV-04 and INV-05 to have any resolving power, so every
    injection round would carry live traffic and this invariant would FAIL in every one of them
    -- a false positive perfectly aligned with the treatment, which is the hardest kind to
    catch and the easiest to write up as a discovery.

    An invariant that cannot tell "the table is stale" from "the table is busy" must say so
    rather than pick the accusatory reading. SKIPPED, not FAIL.
    """
    if iface:
        b0 = probes.iface_bytes().get(iface)
        time.sleep(1.0)
        b1 = probes.iface_bytes().get(iface)
        if b0 and b1:
            moved = (b1[1] - b0[1]) + (b1[0] - b0[0])
            if moved > 125_000:            # ~1 Mbit/s in either direction
                return Finding("INV-07", SKIPPED,
                               f"{iface} moved {moved/125_000:.1f} Mbit in the last second, so "
                               f"the fabric is NOT quiet; this check can only distinguish stale "
                               f"from fresh once traffic has stopped",
                               {"iface": iface, "bytes_moved_1s": moved})
    else:
        return Finding("INV-07", SKIPPED,
                       "no --iface, so 'has traffic actually stopped?' cannot be established; "
                       "running anyway would report a busy table as a stale one")
    t0 = time.monotonic()
    last_nonempty = None
    while time.monotonic() - t0 < quiet_s:
        flows = probes.flow_data()
        if flows:
            last_nonempty = time.monotonic() - t0
            live = [f for f in flows
                    if f.get("estimated_flow_sending_rate_bps_in_the_last_sec", 0) > 0]
            if (time.monotonic() - t0) > 16.0 and live:
                return Finding("INV-07", FAIL,
                               f"{len(live)} flow(s) still report a non-zero rate "
                               f"{time.monotonic()-t0:.0f}s after traffic stopped, past the 15 s "
                               f"idle timeout -- zombie entries (N-1 shape)",
                               {"live": len(live)})
        time.sleep(1.0)
    return Finding("INV-07", PASS,
                   f"table drained; last non-empty at t+{last_nonempty:.0f}s"
                   if last_nonempty is not None else "table empty throughout",
                   {"last_nonempty_s": last_nonempty})


# --------------------------------------------------------------------------------------------
def inv08_reset_safety(ctx: Context) -> Finding:
    """🔧 HALF DELETED, on `03`'s must-fix.

    The oracle asserted `get_average_link_usage` must be non-decreasing as busy links increase.
    That is arithmetic, not a defect: the endpoint averages over BUSY links only (F-17), so a
    new link becoming busy at below the current mean pulls the mean DOWN. The invariant would
    fire on a perfectly correct system -- and the irony is worth keeping, because it was written
    to catch a wrong denominator and used a wrong denominator to do it.

    To actually detect F-17, compare the endpoint against a mean recomputed over *usable* edges
    with idle edges in the denominator. That comparison lives in INV-04's evidence, where the
    oracle already wrote it correctly. Not duplicated here.

    What survives is the half that is sound: unsigned underflow. A counter that wraps publishes
    ~1.8e19 bps and can flag a tiny flow as an elephant.
    """
    flows = probes.flow_data()
    SPIKE = 1e12
    bad = [(probes.flow_pair(f), f.get("estimated_flow_sending_rate_bps_in_the_last_sec", 0))
           for f in flows
           if f.get("estimated_flow_sending_rate_bps_in_the_last_sec", 0) > SPIKE]
    ev = {"flows": len(flows), "spikes": len(bad)}
    if bad:
        return Finding("INV-08", FAIL,
                       f"{len(bad)} flow(s) publish a rate above 1e12 bps, the unsigned "
                       f"underflow signature: {bad[:3]}", ev)
    return Finding("INV-08", PASS, f"no underflow spike across {len(flows)} flow(s)", ev)


# Registry. INV-03/04/05 need arguments a round supplies, so they are wrapped by the runner.
ALWAYS_ON: list[tuple[str, Callable[[Context], Finding]]] = [
    ("INV-01", inv01_power_state_agreement),
    ("INV-02", inv02_edge_liveness),
    ("INV-08", inv08_reset_safety),
]
