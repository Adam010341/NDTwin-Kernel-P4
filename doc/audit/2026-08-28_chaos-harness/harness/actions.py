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


def _link_netem_apply(iface: str):
    def f(dry: bool) -> ActionResult:
        if dry:
            return _dry(f"would run: tc qdisc add dev {iface} root netem loss 100%",
                        iface=iface)
        try:
            rc, _, err = probes.run(
                ["sudo", "tc", "qdisc", "add", "dev", iface, "root", "netem", "loss", "100%"],
                timeout=5)
            return ActionResult(rc == 0, f"netem applied to {iface}" if rc == 0 else f"tc failed: {err.strip()}",
                                {"iface": iface})
        except probes.Timeout as e:
            return ActionResult(False, str(e))
    return f


def _link_netem_verify(iface: str):
    def f() -> ActionResult:
        """G2: read the qdisc back. `tc` returning 0 is a status; the qdisc actually being
        there is the state."""
        try:
            rc, out, _ = probes.run(["tc", "qdisc", "show", "dev", iface], timeout=5)
        except probes.Timeout as e:
            return ActionResult(False, str(e))
        landed = "netem" in out and "loss 100%" in out
        return ActionResult(landed, f"qdisc on {iface}: {out.strip()[:120]}", {"qdisc": out.strip()})
    return f


def _link_netem_undo(iface: str):
    def f() -> None:
        try:
            probes.run(["sudo", "tc", "qdisc", "del", "dev", iface, "root"], timeout=5)
        except probes.Timeout:
            pass
    return f


def link_blackhole(iface: str) -> Action:
    """Break one link. `tc netem`, never `ifconfig down` -- the latter takes down the entire
    BMv2 switch rather than the one link, which destroys the testbed instead of perturbing it
    and makes every subsequent invariant meaningless."""
    return Action(f"T-netem:{iface}", "INV-02/INV-05",
                  f"100% loss on {iface} via tc netem",
                  destructive=True,
                  apply=_link_netem_apply(iface), verify=_link_netem_verify(iface),
                  undo=_link_netem_undo(iface),
                  note="reversible; undo removes the qdisc")


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
