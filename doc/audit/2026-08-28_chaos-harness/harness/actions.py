#!/usr/bin/env python3
"""What the harness does TO the system: G1 positive controls, and the chaos injections.

Two absolute rules, both from `04`:

**G2 — every injection asserts its own success.** Without it, "no violation found" and "the
fault never happened" are the same log line. Each action below carries `verify`, an independent
check that the fault really landed; a round whose injection fails to verify is ABORTED, never
scored. Deletion leaves a hole and is loud; renaming leaves a plausible wrong answer and is
silent -- so the check has to look for the fault, not for the absence of an error.

**§4 — five actions destroy the testbed instead of perturbing it.** Encoded as code, not as a
comment, because a warning in prose gets skipped:

  * never `pkill -f` / `pgrep -f` to kill -- seven self-kills to date. Pids are recorded at
    spawn and only those pids are signalled.
  * never `ifconfig <iface> down` -- it breaks the whole BMv2 switch, not one link. `tc netem`
    instead.
  * no casual `tcpdump` -- AppArmor shields it from SIGKILL even as root, so it survives and
    contaminates every later round. Counter deltas from /proc/net/dev instead.
  * every shell-out is timed out (probes.run enforces it).
  * restarting the proxy is DESTRUCTIVE, not a neutral bounce: it silently destroys every rule
    installed since bring-up.

**§5.2 — the allow path needs a dry run.** A guard that refuses is cheap to test, because
refusing has no side effect. Testing the ALLOW branch by letting it run performs the very thing
the guard exists to gate. So every destructive action here has a `dry_run` mode that prints its
intent and touches nothing, and the runner exercises it.

[Co-developed with claude code -- Adam]
"""
from __future__ import annotations

import sys
import time
from dataclasses import dataclass, field
from typing import Callable

import probes


@dataclass
class ActionResult:
    ok: bool
    detail: str
    evidence: dict = field(default_factory=dict)
    dry_run: bool = False


@dataclass
class Action:
    id: str
    targets: str            # which invariant this is meant to make fire, or "" for chaos
    description: str
    destructive: bool
    apply: Callable[[bool], ActionResult]     # apply(dry_run)
    verify: Callable[[], ActionResult]        # G2: did the fault actually land?
    undo: Callable[[], None] | None = None
    note: str = ""
    # An action whose UNDO has never been proven to work must not run just because someone
    # asked for "the controls". Naming the flag per action keeps the opt-in specific: a blanket
    # --force would be granted once and then cover everything added later.
    needs_opt_in: str | None = None


def _dry(msg: str, **ev) -> ActionResult:
    return ActionResult(True, f"DRY RUN, nothing touched: {msg}", ev, dry_run=True)


# ============================================================================================
# G1 POSITIVE CONTROLS -- real, catalogued defects. Each must make its invariant go RED.
#
# The spec is explicit that these must be REAL defects rather than simulated ones. A mock
# violation proves the assertion works; only a real one proves the whole path works -- probe,
# parse, threshold and all. An invariant that stays green through its own positive control is
# decorative, and a harness full of decorative invariants is indistinguishable from one that
# checks nothing.
# ============================================================================================

# s1's management address, from the graph's `ip` field (raw uint32 192653504, little-endian --
# same encoding as the flow endpoint, see probes.decode_ip). The endpoint keys on `ip`, not on
# dpid; see below for how much that cost.
S1_MGMT_IP = "192.168.123.11"


def _c01_apply(dry: bool) -> ActionResult:
    """A-1: power a switch off, then immediately on. The second call early-returns success
    because the vertex is still marked up, so it answers in ~0.01 s having done nothing.

    🔴 THIS CONTROL NEVER TOUCHED THE SYSTEM, and its own G2 verify confirmed it had. Found on
    the first live run, 2026-08-29. Two independent defects, either one fatal:

      1. It sent **GET**. `HttpSession.cpp:177` routes `/ndt/set_switches_power_state` under
         `http::verb::post` only, so no route matched.
      2. It sent **`dpid=1`**. The handler reads `ip` (`HttpSession.cpp:653`) and answers
         400 `Missing or invalid ip/action` without it. Even as a POST it would have done
         nothing.

    🔑 And the reason it went unnoticed for a whole build is the part worth keeping. A-1's
    signature is "success, suspiciously fast". An unrouted request is also fast. So
    `_c01_verify` timed a request that never reached the power code, measured 0.0069 s, and
    reported *"fast path reached"* -- the instrument's own failure mode is byte-identical to
    the defect it hunts (`instrument-must-not-mimic-its-own-finding`). The pre-state capture,
    the restore path and the `setsid` were all correct precautions around an action that was
    inert.

    Fixed here, which makes it genuinely destructive for the first time -- so it is now behind
    `--allow-poweroff` and has not been run. See `_c01_undo` for why that gate is not caution
    theatre: off-then-on is documented not to recover a P4 switch.
    """
    if dry:
        return _dry(f"would POST set_switches_power_state ip={S1_MGMT_IP} off, then on")
    off = probes.api_post(f"/ndt/set_switches_power_state?ip={S1_MGMT_IP}&action=off", {})
    # The handler answers `{"<ip>": "Success"}` (HttpSession.cpp:665). Checked by content, not
    # by status -- which is the whole reason probes.api_post does not return one.
    if not (isinstance(off, dict) and off.get(S1_MGMT_IP) == "Success"):
        # G2 up front: if the switch did not actually go down there is no A-1 to observe, and
        # the timing below would be measuring a healthy early-return instead of a lie.
        return ActionResult(False,
                            f"power-off did not report success ({off!r}); refusing to score a "
                            f"fault that never landed")
    time.sleep(0.5)
    _, dt = probes.api_post_timed(f"/ndt/set_switches_power_state?ip={S1_MGMT_IP}&action=on", {})
    return ActionResult(True, f"power-off accepted, power-on returned in {dt:.4f}s",
                        {"elapsed_s": dt})


def _c01_verify() -> ActionResult:
    """G2: the fault is "the twin certifies a switch that is not running", so verify it on
    STATE -- process count against the graph -- and use the latency only as corroboration.

    The old version verified on latency ALONE, which is why a 404 passed as a reproduction.
    """
    live = probes.bmv2_process_count()
    graph = probes.graph_data()
    try:
        up = sum(1 for n in probes.switch_flags(graph).values() if n.get("is_up") is True)
    except probes.SchemaDrift as e:
        return ActionResult(False, f"cannot read the graph to verify: {e}")
    _, dt = probes.api_post_timed(f"/ndt/set_switches_power_state?ip={S1_MGMT_IP}&action=on", {})
    landed = up > live
    return ActionResult(landed,
                        f"graph says {up} up, {live} bmv2 processes alive; power-on {dt:.4f}s "
                        f"({'A-1 reproduced: the twin is certifying a dead switch' if landed else
                           'no discrepancy, so A-1 did NOT reproduce'})",
                        {"graph_up": up, "processes": live, "elapsed_s": dt})


def _c01_undo() -> None:
    """🔴 THIS UNDO WAS MISSING, and its absence is worse than the control it guards.

    `_c01_apply` powers a P4 switch off and then on. `P4PowerStrategy.cpp:100-114` records, from
    a live fabric on 2026-08-12, that this exact sequence **does not recover the switch**: the
    proxy's liveness prober keeps hammering the dead port, grpc-python's process-global
    subchannel pool hands that address's accumulated backoff to the fresh channel readopt
    builds, and the power-on returns 502. The process comes back; the pipeline does not. The
    1 Hz probe then marks the switch UP and it cannot forward a single packet.

    So the control's failure mode is to leave the fabric quietly broken in precisely the shape
    the harness exists to detect -- a switch certified up that is dead. Anything measured
    afterwards would be measuring the harness's own wreckage.

    The recovery is the one the source names: POST the proxy's readopt directly, several times
    if needed, because it is the only call that re-attempts adoption without passing through
    powerOn's `getVertexIsUp` early return. Verified against a healthy s1 before this control
    was ever run live (`routes_installed: 32/32`) -- a restore path first exercised during an
    emergency has not been tested, it has been hoped for.

    🔴 THE HELPER POWER-ON INSIDE THIS LOOP WAS THE SAME DEFECT AS `_c01_apply`'s, and it
    outlived the fix to `_c01_apply` by five days. Found 2026-09-03 sweeping FINDINGS-ALL #17
    across the whole harness rather than only the line the finding named -- it is the FIFTH
    instance of the family and no finding mentions it.

    It read `probes.api_get("/ndt/set_switches_power_state?dpid=1&action=on")`: GET at a
    POST-only route, `dpid` at an ip-keyed handler, through the LENIENT wrapper, with the
    return value discarded. So the branch that exists to bring a dead switch back has never
    executed a single line of power-on code, and could not have said so -- the 404 became
    `None` and `None` was never read.

    What that costs is worse here than in a check. This is the RESTORE path of a control that
    is documented not to recover a P4 switch on its own, so its failure leaves the fabric in
    the exact state the harness exists to detect -- a switch certified up that forwards
    nothing -- and every later round measures that wreckage. `_c01_undo` cannot raise (it is
    the cleanup path, and an exception here would strand the fabric mid-restore), so it says
    so on stdout beside the readopt attempts it already reports.
    """
    for attempt in range(1, 6):
        live = 0
        try:
            live = probes.bmv2_process_count()
        except Exception:
            pass
        if live < 10:
            # helper-on itself failed; the process is gone, so readopt has nothing to adopt.
            try:
                probes.api_post_checked(
                    f"/ndt/set_switches_power_state?ip={S1_MGMT_IP}&action=on", {})
            except (probes.NotAnswered, probes.HarnessBug) as e:
                print(f"    [undo] helper power-on did NOT land ({e}); readopt below is the "
                      f"only remaining recovery")
            time.sleep(3.0)
        r = probes.api_post("/p4/readopt/1", {}, base=probes.PROXY)
        installed = r.get("routes_installed") if isinstance(r, dict) else None
        if isinstance(installed, int) and installed > 0:
            print(f"    [undo] readopt attempt {attempt}: routes_installed={installed}")
            return
        print(f"    [undo] readopt attempt {attempt} did not adopt: {r}")
        time.sleep(5.0)
    print("    [undo] 🔴 s1 NOT RECOVERED after 5 attempts -- do not trust later rounds")


def _c04_apply(dry: bool) -> ActionResult:
    """Capacity clamp: drive a link declared at 1 Gbps past 1 Gbps. The twin pins at exactly
    1e9 because linkBandwidthUsage is clamped to linkBandwidth on both code paths.

    🔴 NOT IMPLEMENTED, and the way it was not implemented is the finding. The live branch
    returned `ActionResult(False, "requires a live iperf3; wired up by the runner, not here")`
    -- and the runner does not wire it up. `STATUS.md` counted this among "4 of 7 controls
    written", so the tally said 4 while the number that could ever fire was 3.

    Left refusing rather than quietly dropped, because NOT-APPLIED is a loud answer and a
    missing row is a silent one. Implementing it needs traffic generation the harness does not
    yet own (iperf3 inside a mininet netns via `mnexec -a <recorded pid>`); until then the
    honest state is that INV-04 has no working positive control, exactly like INV-02/03/05.
    """
    if dry:
        return _dry("would run iperf3 h2->h1 at ~2 Gbit/s to exceed the declared 1 Gbps")
    return ActionResult(False,
                        "NOT IMPLEMENTED: the live path needs an iperf3 inside a mininet netns "
                        "and no caller supplies one. INV-04 therefore has no positive control "
                        "that can fire, and its PASS carries no more weight than INV-02/03/05's")


def _c04_verify() -> ActionResult:
    flows = probes.flow_data()
    total = sum(f.get("estimated_flow_sending_rate_bps_in_the_last_sec", 0) for f in flows)
    pinned = abs(total - 1_000_000_000) < 1
    return ActionResult(pinned,
                        f"twin total {total/1e9:.3f} Gbit/s "
                        f"({'pinned at the clamp' if pinned else 'not at the clamp'})",
                        {"twin_bps": total})


def _c06_apply(dry: bool) -> ActionResult:
    """B-2: renew a lock that has already expired. `renew` never compares now against
    expiryTime, so it extends a lock nobody holds."""
    if dry:
        return _dry("would acquire ttl=1, sleep 2, then renew the expired lock")
    probes.acquire_lock(probes.PROBE_LOCK, ttl=1)
    time.sleep(2.0)
    r = probes.renew_lock(probes.PROBE_LOCK, ttl=30)
    return ActionResult(True, f"renew of an expired lock answered: {r}", {"renew": r})


def _c06_verify() -> ActionResult:
    """State, not status: if renew really extended an expired lock, a fresh acquire is blocked.

    🔴 THE RELEASE USED TO LIVE HERE, and it made the control unobservable. `verify` confirmed
    B-2 had reproduced and then, one line later, released the lock -- so by the time INV-06 ran
    it found a healthy system and returned PASS. The gate read BLIND: "the defect landed and the
    invariant missed it", when the truth was that the harness had cleaned the defect up before
    anyone looked.

    G2 must OBSERVE the fault, never repair it. Repair belongs in `undo`, which runs after the
    invariant has had its turn. Same family as the baseline-ordering bug found an hour earlier:
    both are the check standing in the wrong place in time rather than being wrong.
    """
    a = probes.acquire_lock(probes.PROBE_LOCK, ttl=3)
    blocked = not probes.lock_acquired(a)
    return ActionResult(blocked,
                        "a third party is blocked by the resurrected lock -- B-2 reproduced"
                        if blocked else "lock was free; B-2 did not reproduce here",
                        {"acquire_after_renew": a})


def _c06_undo() -> None:
    """Release the resurrected lock.

    ❌ **RETRACTED, and the retraction is the lesson.** This used to read "`lockName` does NOT
    namespace -- acquiring alpha blocks beta, there is one global routing lock". That was a
    misdiagnosis of *this harness's own bug*: it sent `lockName`, the handler reads `type`
    (`HttpSession.cpp:1925`), so both requests carried no type and both defaulted to
    `routing_lock`. Names work fine -- `stringToLockType` (`LockManager.hpp:38-43`) returns
    `Unknown` for anything unrecognised and the acquire is refused. Corrected by `8/29 auditor`
    reading the code.

    ✅ **The consequence I stated survives the retraction, by a different route**: only three
    lock types exist and all three are real, so there is no private lock to hold. This control
    does hold something that matters, and it must come back off even if the round aborts.
    ⇒ `disclosure-is-not-downgrading`: the mechanism was wrong, the conclusion was not.
    """
    probes.release_lock(probes.PROBE_LOCK)


# The route, spelled once. POST /ndt/historical_logging with `state` as a QUERY parameter --
# the handler reads utils::queryParam(target, "state") and IGNORES the body
# (HttpSession.cpp:2084), which is why nothing is sent in it.
#
# 🔴 RETRACTED AND REWRITTEN 2026-09-03 -- KNOWN-ISSUES G-3, and this is the whole of the
# retraction at doc/audit/2026-08-28_chaos-harness/05_first-live-run.md:203.
#
# This control used to call THREE routes that the kernel has never registered:
# /ndt/set_historical_logging, /ndt/get_historical_data and /ndt/set_historical_logging_state.
# All three answer 404, confirmed live on 2026-09-02 (raw/C8_b3_historical_logging.log). Three
# independently fatal ingredients then lined up:
#
#   * the routes 404, so nothing was ever enabled and nothing was ever read;
#   * `probes.api_get` discarded the status, so a 404 came back as None;
#   * the criterion was `rows == 0 ⇒ reproduced`, and None counts as zero rows.
#
# Product: a positive control that returns "B-3 reproduced" whether or not B-3 exists -- on a
# healthy kernel, on a kernel with the defect, and on no kernel at all. Fixing only the route
# would leave the shape intact for the next route that moves, so both halves change here.
HISTORICAL_LOGGING = "/ndt/historical_logging"


def _c07_apply(dry: bool) -> ActionResult:
    """B-3: historical_logging accepts "enable" and no row is ever written.

    G2 up front: if the enable did not land there is no B-3 to observe, and scoring the round
    would report the absence of a request as a property of the system.
    """
    if dry:
        return _dry(f"would POST {HISTORICAL_LOGGING}?state=enable and read the "
                    f"recording state back")
    try:
        r = probes.api_post_checked(f"{HISTORICAL_LOGGING}?state=enable", {})
    except probes.NotAnswered as e:
        # 500 is a documented answer here (no HistoricalDataManager -- section 39, and
        # spec.py pins [200, 500]), and it is NOT the defect: it means the request never
        # reached the flag. Refusing is the honest verdict for both that and a 404.
        return ActionResult(False, f"the enable did not land, so there is no B-3 to observe: {e}",
                            {"error": str(e), "status": e.status})
    if not isinstance(r, dict):
        return ActionResult(False, f"enable answered a non-object ({r!r}); nothing to judge",
                            {"response": r})
    return ActionResult(True, f"enable accepted: {r}", {"response": r})


def _c07_verify() -> ActionResult:
    """G2: does this deployment actually write rows, or only say yes?

    Read back through the real route rather than counting rows, because THERE IS NO ROW-READ
    ROUTE -- the kernel registers 42 endpoints and none of them serves historical data
    (HistoricalDataManager writes CSV straight to a hard-coded, root-owned OUTPUT_DIR). The
    invented /ndt/get_historical_data is where the 404 came from. So the state this can read
    is the recorder's own, and the reply carries it in a machine-readable form:

        recording : bool  -- will a row appear?
        reason    : one of recording / disabled-by-request / not-available-in-mininet-mode /
                    recorder-not-running / writes-failing   (HistoricalDataManager::reasonCode)

    `recording is False` is B-3: enable was accepted and no row will be written. `recording is
    True` is a deployment that really does record -- which is why this criterion has two sides
    where `rows == 0` had one. On this project's two lab stacks the answer is MININET, so the
    control is expected to reproduce; on a TESTBED kernel with the recorder up it is expected
    NOT to, and that difference is the whole point of a positive control.

    Stated limit: this reads the kernel's own disclosure of whether it will write. It can tell
    "will not write" from "is writing"; it cannot independently confirm that a row landed on
    disk. The five seconds are so a run of failed writes has time to set WRITES_FAILING, which
    would otherwise still read as RECORDING at the instant of the enable.

    A reply with no `recording` field is a kernel that predates the disclosure, and it makes
    the two cases indistinguishable again -- so it is refused, not guessed. Same rule as
    probes.SchemaDrift: a verdict-shaped parse problem is indistinguishable from a finding.
    """
    time.sleep(5.0)
    try:
        r = probes.api_post_checked(f"{HISTORICAL_LOGGING}?state=enable", {})
    except probes.NotAnswered as e:
        return ActionResult(False, f"cannot read the recording state back, so B-3 is neither "
                                   f"confirmed nor ruled out: {e}",
                            {"error": str(e), "status": e.status})
    if not isinstance(r, dict) or not isinstance(r.get("recording"), bool):
        return ActionResult(
            False, f"the reply carries no boolean `recording`, so it cannot say whether a row "
                   f"will be written; refusing to score B-3 either way. body: {r!r}",
            {"response": r})

    recording = r["recording"]
    reason = r.get("reason")
    ev = {"recording": recording, "reason": reason, "status_field": r.get("status")}
    if recording:
        return ActionResult(False,
                            f"the recorder is live (reason={reason!r}); enable really does "
                            f"produce rows here, so B-3 did NOT reproduce", ev)
    return ActionResult(True,
                        f"enable was accepted and no row will be written (reason={reason!r}) "
                        f"-- B-3 reproduced", ev)


def _c07_undo() -> None:
    """Put the flag back. It was left on before: a control that changes a global setting and
    does not restore it hands every later round a different system than the null round measured,
    and the difference is invisible because nothing reports the flag.

    And a restore that silently fails is the same defect one layer down, so this one says so.
    """
    try:
        probes.api_post_checked(f"{HISTORICAL_LOGGING}?state=disable", {})
    except probes.NotAnswered as e:
        print(f"    [undo] 🔴 historical logging was NOT restored to disabled: {e}")
        print("    [undo] every later round now runs with a setting this control changed")


# Ordered least-destructive first, and the ordering is load-bearing rather than tidy: G1-01
# powers a switch down, and if it leaves the fabric degraded (see _c01_undo) every control
# after it would run against wreckage and report the wreckage as a result.
POSITIVE_CONTROLS: list[Action] = [
    Action("G1-06", "INV-06", "B-2: renew an already-expired lock",
           destructive=False, apply=_c06_apply, verify=_c06_verify, undo=_c06_undo),
    Action("G1-07", "INV-07", "B-3: historical_logging reports enabled and writes nothing",
           destructive=False, apply=_c07_apply, verify=_c07_verify, undo=_c07_undo),
    Action("G1-04", "INV-04", "capacity clamp: exceed a link's declared 1 Gbps",
           destructive=False, apply=_c04_apply, verify=_c04_verify),
    Action("G1-01", "INV-01", "A-1: power off then immediately on; success returns in ~0.01s",
           destructive=True, apply=_c01_apply, verify=_c01_verify, undo=_c01_undo,
           needs_opt_in="allow-poweroff",
           note="destructive and its undo is UNPROVEN. Until 2026-08-29 this control was inert "
                "(GET at a POST route, dpid at an ip-keyed handler), so 'it ran fine before' is "
                "not evidence -- it never ran at all. Off-then-on is documented NOT to recover a "
                "P4 switch (P4PowerStrategy.cpp:100-114); the undo drives the proxy readopt "
                "instead, and that path has only ever been exercised against a HEALTHY switch, "
                "where it answered 'mastership not granted'. Runs last, and only on request."),
]

# 🔴 Honest gap, stated rather than left for the next reader to discover:
# INV-02, INV-03 and INV-05 have NO executable positive control here yet.
#   INV-02 needs the topology poll actually wedged (A-2) -- reproducing that means stalling the
#          control plane, which on this fabric means stalling something a neighbour may be using.
#   INV-03 needs B-1 (ghost rule) or A-4e (non-strict modify), both of which mutate a live
#          switch's table and need a restore path that has itself been tested.
#   INV-05 needs A-4d (install then delete the same prefix), which blackholes a destination.
# Per G1 those three invariants are NOT YET DELIVERED, and the runner marks them so. An
# invariant nobody has watched fail is not evidence of anything.
UNCONTROLLED_INVARIANTS = ["INV-02", "INV-03", "INV-05"]


# ============================================================================================
# CHAOS ACTIONS -- the safe subset of `01`'s table
# ============================================================================================

def _h5_apply(dry: bool) -> ActionResult:
    """H5: acquire_lock with a body that is not JSON. The parse failure is swallowed and
    defaults are used, so garbage can take the default lock.

    🔴 THE ONE CALL IN THIS HARNESS THAT BYPASSES `probes._request`, and it has to: the whole
    injection is a body that is not JSON, and `_request` builds its body with `json.dumps`.
    So the route guard `_request` runs for everyone else cannot run for this one, and it is
    called by hand here instead. A chokepoint with one hole in it, and no marker on the hole,
    is how #17's family survived the fix to its own third instance.
    """
    if dry:
        return _dry("would POST '{{{' to acquire_lock")
    try:
        import subprocess
        probes.assert_route("POST", "/ndt/acquire_lock")
        p = subprocess.run(
            ["curl", "-s", "--max-time", "3", "-X", "POST",
             "-H", "Content-Type: application/json", "--data-binary", "@-",
             f"{probes.KERNEL}/ndt/acquire_lock"],
            input="{{{", capture_output=True, text=True, timeout=5)
        return ActionResult(True, "malformed body sent", {"body": p.stdout[:200]})
    except probes.HarnessBug as e:
        return ActionResult(False, f"refusing to send: {e}")
    except Exception as e:
        return ActionResult(False, f"send failed: {e}")


def _h5_verify() -> ActionResult:
    """G2: did the garbage body actually take a lock? Judged by whether a legitimate client is
    now blocked -- not by what the malformed request was told."""
    a = probes.acquire_lock("routing_lock", ttl=2)
    took = not (isinstance(a, dict) and str(a.get("status", "")).lower() in ("locked", "acquired"))
    probes.release_lock("routing_lock")
    return ActionResult(took, "default lock is held after a malformed body" if took
                        else "default lock free; H5 did not land", {"probe": a})


def _h23_apply(dry: bool) -> ActionResult:
    """H23: publish an EMPTY all_destination_paths. setAllPaths refuses empty snapshots on
    purpose, so the correct outcome is that the path map is UNCHANGED."""
    if dry:
        return _dry("would POST inform_all_destination_paths with an empty list")
    r = probes.api_post("/ndt/inform_all_destination_paths", {"all_destination_paths": []})
    return ActionResult(True, f"empty snapshot posted: {r}", {"response": r})


def _h23_verify() -> ActionResult:
    """G2 inverted: here the injection is meant to be REFUSED, so 'landed' means the path map
    survived. A wiped map is the defect.

    ⚠️ SAME FAMILY AS G-3, found while fixing it and NOT fixed here. /ndt/get_all_destination_paths
    is not one of the kernel's 42 registered routes, so this read has always been a 404. With
    the status discarded that came back as None, `n` fell to 0, and the control reported "the
    path map was wiped" on every run -- the mirror image of _c07's false pass. Switched to the
    checked probe so it now REFUSES instead of accusing; naming the route this should read
    instead is a separate ticket, because the kernel exposes no such endpoint at all and the
    proxy's /ryu_server/all_destination_paths is a different population.

    🔧 2026-09-03: the refusal now also arrives as `HarnessBug`. `probes.assert_route` knows
    this route is unregistered and stops it before curl runs, so the refusal is reached
    without a round trip -- but it is a different exception type, and catching only
    `NotAnswered` would have turned this deliberate refusal into a traceback.
    """
    try:
        d = probes.api_get_checked("/ndt/get_all_destination_paths")
    except (probes.NotAnswered, probes.HarnessBug) as e:
        return ActionResult(False, f"cannot read the path map back, so nothing is claimed "
                                   f"about the empty publish: {e}", {"error": str(e)})
    n = len(d) if isinstance(d, (list, dict)) else 0
    return ActionResult(n > 0, f"path map holds {n} entries after the empty publish",
                        {"paths": n})


# ============================================================================================
# T-netem: cutting one link WITHOUT destroying the interface's shaping
#
# [Co-developed with claude code -- Adam]
#
# 🔴 W8-8, 2026-09-07. `tc qdisc add dev X root netem loss 100%` does not stack a layer on a
# Mininet TCLink interface. It REPLACES htb -- the bandwidth shaping INV-04 and every link-usage
# reading depend on -- and `tc qdisc del dev X root` then restores the KERNEL DEFAULT rather
# than htb. Measured, verbatim, on 2026-08-13
# (doc/audit/2026-08-12_overnight-review/C-live-ovs-runbook.md, P1):
#
#     $ tc qdisc show dev s1-eth2
#     qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 0 direct_qlen 1000
#     $ sudo -n tc qdisc add dev s1-eth2 root netem loss 100%      # no error output at all
#     $ tc qdisc show dev s1-eth2
#     qdisc netem 8005: root refcnt 15 limit 1000 loss 100%        # htb 5: and class 5:1 gone
#     $ sudo -n tc qdisc del dev s1-eth2 root
#     $ tc qdisc show dev s1-eth2
#     qdisc noqueue 0: root refcnt 2                               # neither netem nor htb
#
# and the sudoers NOPASSWD grant on this machine does not cover putting htb back, so the damage
# is not repairable through the path this harness has. That cost a whole overnight OVS round.
#
# What made it invisible HERE is the same shape §4 of the spec is about: the old verify looked
# for `"netem" in out and "loss 100%" in out`, which is true of BOTH outcomes -- the safe leaf
# and the shaper-replacing root -- so the check could not tell the fault from the damage, and
# the action's note read "reversible; undo removes the qdisc". A destructive action whose own
# G2 check cannot see the destruction is worse than no action.
#
# 🔴 The rule below is NOT invented here. It is a straight port of
# `tools/test_workflow/faults.sh`'s netem_attach_point / netem_delete_point, the file that came
# out of that round, and of `include/utils/NetemLinkFault.hpp`'s planAttach / findExistingNetem,
# which is the same rule inside the kernel. Reimplementing it would make a third place for the
# answer to be wrong:
#
#   * netem already on the interface -> REFUSE. Stacking makes the undo ambiguous, and an
#     injector that corrupts the next round is worse than one that does nothing.
#   * root qdisc is htb (a TCLink interface) -> attach at `parent <handle><default>`, UNDER the
#     shaper, so the shaper survives and the undo can name exactly what was added.
#   * anything else (unshaped) -> `root` is correct, and is why the P4 runbook's root-netem
#     recipe is valid on that fabric.
#
# and the undo reads the tree AGAIN to find where the netem actually is rather than assuming
# root: the tree is the state. `del ... root` on a shaped interface is precisely the command
# that takes htb with it.
# ============================================================================================

# `tc qdisc show dev X` prints the qdisc lines for one device. Two spellings of the same line
# occur in this repo's evidence -- with the device named and without --
#
#   qdisc htb 5: root refcnt 15 r2q 10 default 0x1 ...          (live capture, 2026-08-13)
#   qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 1     (tests/shell/test_faults.sh)
#
# so nothing below indexes a fixed column past the handle: `root` and `parent` are found as
# TOKENS. faults.sh is agnostic the same way (it greps for ` root ` and takes $2/$3).
_QDISC_KIND = 1
_QDISC_HANDLE = 2

# The root qdiscs the kernel puts back BY ITSELF once whatever replaced them is deleted. That
# is the whole difference between the two outcomes of a root netem: on an unshaped interface
# `del ... root` gave back `qdisc noqueue 0: root refcnt 2` (2026-08-13, verbatim), so the
# P4 runbook's root-netem recipe is safe there; on a TCLink interface the same delete gave back
# that same noqueue instead of `htb 5:` with its class, and the NOPASSWD grants on this machine
# cannot rebuild htb.
#
# 🔴 The list is what is SAFE to lose, not what is dangerous, so an unrecognised root qdisc is
# protected rather than sacrificed. Fail-closed: a shaper this harness has never met is exactly
# the case where guessing costs somebody an overnight round.
_KERNEL_DEFAULT_ROOT_QDISCS = ("noqueue", "pfifo_fast", "pfifo", "fq_codel", "fq", "mq")


def _qdisc_lines(tree: str) -> list[list[str]]:
    """Every non-blank line of a `tc qdisc show` reply, split into words."""
    return [line.split() for line in tree.splitlines() if line.split()]


def _root_qdisc(tree: str) -> list[str] | None:
    """The words of the line describing this interface's ROOT qdisc, or None."""
    for words in _qdisc_lines(tree):
        if len(words) > _QDISC_HANDLE and words[0] == "qdisc" and "root" in words[3:]:
            return words
    return None


def netem_attach_point(tree: str) -> tuple[list[str] | None, str]:
    """Where netem may be attached on this interface without destroying its shaping.

    Returns (tc argv words, "") or (None, why not). Port of faults.sh's netem_attach_point;
    `why` is returned rather than logged because this refuses far more often than it fails and
    a caller cannot tell those two apart from a boolean.
    """
    lines = _qdisc_lines(tree)
    if not lines:
        return None, "the qdisc tree for this interface is empty or could not be read"

    for words in lines:
        if len(words) > _QDISC_KIND and words[0] == "qdisc" and words[_QDISC_KIND] == "netem":
            return None, ("netem is already attached to this interface -- residue from an "
                          "earlier round. Refusing to stack a second one, because the undo "
                          "could then not tell them apart. Remove the existing one first")

    root = _root_qdisc(tree)
    if root is None:
        return None, "no root qdisc line in the tree for this interface"

    kind, handle = root[_QDISC_KIND], root[_QDISC_HANDLE]
    if kind == "htb":
        # TCLink's shaper. netem hangs off the default class, so `del parent H:D` later removes
        # the netem and leaves htb standing. `default` is printed in hex on some kernels
        # (`default 0x1`, the 2026-08-13 capture) and in decimal on others; tc parses either,
        # so the token is concatenated verbatim rather than reformatted -- faults.sh and
        # NetemLinkFault.hpp both do exactly this and have the live evidence.
        for i, word in enumerate(root[:-1]):
            if word == "default":
                return ["parent", handle + root[i + 1]], ""
        return None, ("the interface is shaped by htb but its root line names no default "
                      "class, so there is nowhere to attach netem without replacing the shaper")

    return ["root"], ""


def netem_delete_point(tree: str) -> tuple[list[str] | None, str]:
    """Where the netem on this interface is attached, for the delete that removes it.

    Read from the live tree rather than remembered: `del ... root` on a shaped interface takes
    htb with it, so "where I put it" is not good enough -- the answer has to come from the
    interface. Port of faults.sh's netem_delete_point.
    """
    for words in _qdisc_lines(tree):
        if len(words) <= _QDISC_KIND or words[0] != "qdisc" or words[_QDISC_KIND] != "netem":
            continue
        if "root" in words[3:]:
            # 🔴 No trailing `netem` on this form. The NOPASSWD grant is the exact argument
            # list `qdisc del dev s*-eth* root`; one extra token and the revert dies with
            # "a password is required", leaving the fault in place. Measured 2026-08-13.
            return ["root"], ""
        for i, word in enumerate(words[:-1]):
            if word == "parent":
                # Also no trailing `netem`: the grant for this form is
                # `qdisc del dev s*-eth* parent *`, and NetemLinkFault.hpp's restore -- written
                # against a `sudo -n -l` read on 2026-09-06 -- omits it. faults.sh appends one;
                # omitting it is the strict subset, and it deletes the same qdisc either way.
                return ["parent", words[i + 1]], ""
        return None, "a netem qdisc is present but its attach point could not be read"
    return None, "no netem qdisc is attached to this interface"


class _LinkNetem:
    """apply / verify / undo for one interface, sharing what apply read off the live tree.

    A class rather than three independent closures because verify's job is now to compare the
    tree AFTER the injection with the tree BEFORE it. "netem is present" is true in both the
    safe outcome and the destructive one, so on its own it cannot tell them apart -- which is
    exactly how the old version passed while replacing the shaper.
    """

    def __init__(self, iface: str):
        self.iface = iface
        self.before = ""                    # the qdisc tree as apply found it
        self.attached: list[str] = []       # the tc words the netem was actually added with

    def _show(self) -> tuple[bool, str, str]:
        """(ok, tree, why not). `tc qdisc show` reads; it needs no sudo and changes nothing."""
        try:
            rc, out, err = probes.run(["tc", "qdisc", "show", "dev", self.iface], timeout=5)
        except probes.Timeout as e:
            return False, "", str(e)
        if rc != 0:
            return False, "", f"tc qdisc show dev {self.iface} exited {rc}: {err.strip()[:120]}"
        return True, out, ""

    def apply(self, dry: bool) -> ActionResult:
        ok, tree, why = self._show()
        if not ok:
            if dry:
                # §5.2: a dry run makes no claim about the system, so being unable to read the
                # tree is not a failure here -- but it is also not a plan, and saying "would run
                # <command>" without having read the tree is how the old version printed a line
                # that was false on every shaped interface.
                return _dry(f"no attach point could be planned for {self.iface}: {why}. On a "
                            f"live fabric this reads the qdisc tree and attaches under the "
                            f"shaper", iface=self.iface, planned=None)
            return ActionResult(False, why, {"iface": self.iface})

        # Recorded BEFORE anything is attached, and unconditionally: it is the only thing
        # verify can compare against, and a verify with nothing to compare against is back to
        # "netem is present", which was true of the destructive outcome too.
        self.before = tree

        where, refused = netem_attach_point(tree)
        if where is None:
            detail = (f"refusing to touch {self.iface}: {refused}. Attaching at root here would "
                      f"replace TCLink's htb and the shaping cannot be restored "
                      f"(doc/2026-07-29_environment_gotchas.md)")
            if dry:
                return _dry(detail, iface=self.iface, planned=None, qdisc_before=tree.strip())
            return ActionResult(False, detail, {"iface": self.iface, "qdisc_before": tree.strip()})

        argv = ["sudo", "-n", "tc", "qdisc", "add", "dev", self.iface] + where + \
               ["netem", "loss", "100%"]
        if dry:
            return _dry(f"would run: {' '.join(argv)}", iface=self.iface,
                        planned=" ".join(where), qdisc_before=tree.strip())

        try:
            rc, _, err = probes.run(argv, timeout=5)
        except probes.Timeout as e:
            return ActionResult(False, str(e), {"iface": self.iface})
        if rc != 0:
            return ActionResult(False, f"tc failed at {' '.join(where)}: {err.strip()[:160]}",
                                {"iface": self.iface, "attach_point": " ".join(where)})
        self.attached = where
        return ActionResult(True, f"netem applied to {self.iface} at {' '.join(where)}",
                            {"iface": self.iface, "attach_point": " ".join(where),
                             "qdisc_before": tree.strip()})

    def verify(self) -> ActionResult:
        """G2, both halves: the fault landed, AND the shaping the fabric depends on survived.

        `tc` returning 0 is a status; the qdisc tree is the state. The second half is the one
        the 2026-08-13 round needed and did not have: a root qdisc that used to be htb and is
        now netem is not a successful injection, it is a destroyed interface that happens to
        drop packets.
        """
        ok, tree, why = self._show()
        if not ok:
            return ActionResult(False, why, {"iface": self.iface})
        if not self.before:
            return ActionResult(False,
                                f"no pre-injection qdisc tree was recorded for {self.iface}, so "
                                f"this check cannot tell a netem attached under the shaper from "
                                f"one that replaced it -- and those are the fault and the damage",
                                {"iface": self.iface, "qdisc": tree.strip()})

        netem = [w for w in _qdisc_lines(tree)
                 if len(w) > _QDISC_KIND and w[0] == "qdisc" and w[_QDISC_KIND] == "netem"]
        landed = bool(netem) and "loss" in tree and "100%" in tree

        was, now = _root_qdisc(self.before), _root_qdisc(tree)
        was_kind = was[_QDISC_KIND] if was else None
        now_kind = now[_QDISC_KIND] if now else None
        evidence = {"iface": self.iface, "qdisc": tree.strip(),
                    "qdisc_before": self.before.strip(),
                    "root_qdisc_before": was_kind, "root_qdisc_after": now_kind,
                    "attach_point": " ".join(self.attached)}

        # 🔴 Judged on the tree, never on what this object INTENDED. Excusing the replacement
        # whenever `self.attached == ["root"]` would let the one mutation that matters -- the
        # attach point going back to root on a shaped interface -- excuse itself.
        if (was_kind is not None and now_kind != was_kind
                and was_kind not in _KERNEL_DEFAULT_ROOT_QDISCS):
            return ActionResult(False,
                                f"the injection REPLACED the root qdisc on {self.iface}: it was "
                                f"{was_kind} before and is {now_kind} now. {was_kind} is not a "
                                f"qdisc the kernel puts back, so the shaping is gone and "
                                f"`del root` restores the kernel default instead "
                                f"(C-live-ovs-runbook.md P1, 2026-08-13)", evidence)
        if not landed:
            return ActionResult(False, f"no netem with 100% loss on {self.iface}: "
                                       f"{tree.strip()[:120]}", evidence)
        return ActionResult(True, f"netem loss 100% on {self.iface} at "
                                  f"{' '.join(self.attached) or 'an unrecorded point'}, root "
                                  f"qdisc still {now_kind}", evidence)

    def undo(self) -> None:
        ok, tree, why = self._show()
        if not ok:
            print(f"🔴 undo could not read the qdisc tree for {self.iface} ({why}); the netem "
                  f"may still be in place", file=sys.stderr)
            return
        where, refused = netem_delete_point(tree)
        if where is None:
            # Not an error when there is simply nothing there; loud when there is something
            # this cannot name, because the alternative is `del root` -- the command that takes
            # htb with it.
            if "no netem qdisc" not in refused:
                print(f"🔴 undo cannot locate the netem on {self.iface} ({refused}); leaving it "
                      f"alone rather than deleting the root qdisc", file=sys.stderr)
            return
        try:
            rc, _, err = probes.run(
                ["sudo", "-n", "tc", "qdisc", "del", "dev", self.iface] + where, timeout=5)
        except probes.Timeout as e:
            print(f"🔴 undo timed out removing the netem on {self.iface}: {e}", file=sys.stderr)
            return
        if rc != 0:
            print(f"🔴 undo failed to remove the netem on {self.iface} at {' '.join(where)}: "
                  f"{err.strip()[:160]}", file=sys.stderr)


def link_blackhole(iface: str) -> Action:
    """Break one link. `tc netem`, never `ifconfig down` -- the latter takes down the entire
    BMv2 switch rather than the one link, which destroys the testbed instead of perturbing it
    and makes every subsequent invariant meaningless.

    The netem goes UNDER the interface's shaper when it has one, never over it; see the block
    above for what "over it" costs and why the note below no longer says "reversible" flatly.
    """
    netem = _LinkNetem(iface)
    return Action(f"T-netem:{iface}", "INV-02/INV-05",
                  f"100% loss on {iface} via tc netem",
                  destructive=True,
                  apply=netem.apply, verify=netem.verify,
                  undo=netem.undo,
                  note="the attach point is read from the live qdisc tree: under htb when the "
                       "interface is shaped, at root only when it is not, and refused outright "
                       "when a netem is already there. undo removes exactly the netem it finds, "
                       "so the shaper it was hung under survives")


CHAOS_ACTIONS: list[Action] = [
    Action("H5", "INV-06", "acquire_lock with a malformed body", destructive=False,
           apply=_h5_apply, verify=_h5_verify),
    Action("H23", "INV-05", "publish an empty all_destination_paths (must be refused)",
           destructive=False, apply=_h23_apply, verify=_h23_verify),
]

# 🔴 Deliberately NOT implemented, with the reason, so the boundary survives the handoff:
#   H13/H15/H16 (shell injection through interpolated bodies) -- these are live RCE paths
#       (B-2b). Firing them is a real command execution on this machine, not a simulation.
#       They belong in a disposable VM with an owner who has agreed to it.
#   H17 (1000x app_register) -- each registration writes /etc/exports and synchronously runs
#       `exportfs -ra && systemctl reload nfs-server`. That is a host-level side effect that
#       outlives the harness.
#   L1-L5 (`01` §8.4 lifecycle abuse) -- flagged in `04` §6 as the hardest to reconcile with
#       G2: once the process is dead, nothing is left to assert the injection succeeded. Needs
#       its own design, not a wrapper here.
#   N-1 NTP step -- needs a wall-clock jump, which hits every other session on this machine.
#       Single-occupancy window only.
