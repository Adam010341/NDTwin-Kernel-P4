"""
Pushes state to the NDTwin kernel's northbound API, the way Ryu does.

[Co-developed with claude code -- Adam]

The kernel does not discover P4 switches on its own. In OVS mode Ryu actively *pushes*:
`intelligent_router.py` calls `/ndt/inform_switch_entered` when a switch connects and
`/ndt/link_failure_detected` / `link_recovery_detected` when LLDP beacons stop or resume. The
proxy pushed nothing, which is why the graph stayed inert in P4 mode -- see Phase 6 of
doc/2026-07-27_p4_bmv2_support_plan.md.

`inform_switch_entered` is the *fast* path that sets `isEnabled` on a vertex
(HttpSession::handleInformSwitchEntered sets both isUp and isEnabled). It is not the only one:
the kernel's own topology poll does the same per reported switch
(TopologyAndFlowMonitor::updateSwitches, TopologyAndFlowMonitor.cpp:566), which is why every
stack.sh P4 round ever run had enabled switches even though this push always fired before the
kernel existed and got connection-refused (the kernel deliberately starts last there). What the
push buys is latency and explicitness -- enabling on the transition instead of on the next
poll. This paragraph used to claim "only path"; the 2026-08-15 overnight audit believed it and
concluded a whole era had run on an empty twin. [Co-developed with claude code -- Adam]

Every method here returns a bool and never raises. These are called from the gRPC receive
thread and the LLDP discovery thread; an exception on either kills that thread and takes the
feature with it, silently. Failures are logged loudly instead, because a kernel that never
learns about a switch looks exactly like a switch that is down.
"""

from __future__ import annotations

import os
from typing import Optional

import requests

# Where the kernel's northbound API lives. Matches NDT_URL in tools/test_workflow/components.env
# so the harness and the proxy cannot disagree.
DEFAULT_KERNEL_URL = "http://localhost:8000"

# Short: these calls sit on threads that have other work to do, and the kernel is local. A slow
# kernel should not stall LLDP discovery or the packet-in path.
DEFAULT_TIMEOUT_SECONDS = 3.0


class KernelNotifier:
    """Northbound client for the kernel's /ndt/ push endpoints."""

    def __init__(self,
                 base_url: Optional[str] = None,
                 timeout: float = DEFAULT_TIMEOUT_SECONDS,
                 session: Optional[requests.Session] = None):
        self.base_url = (base_url
                         or os.environ.get("NDT_URL")
                         or DEFAULT_KERNEL_URL).rstrip("/")
        self.timeout = timeout
        # Injectable so tests need no HTTP server, and so connections are reused in production.
        self._session = session or requests.Session()
        self.failures = 0

    # --- internals ----------------------------------------------------------------

    def _report(self, what: str, ok: bool, detail: str = "") -> bool:
        if ok:
            print(f"[Kernel] {what}: ok")
            return True
        self.failures += 1
        print(f"[Kernel] {what}: FAILED {detail}")
        return False

    def _get(self, path: str, what: str) -> bool:
        try:
            r = self._session.get(f"{self.base_url}{path}", timeout=self.timeout)
            return self._report(what, r.status_code == 200, f"HTTP {r.status_code}")
        except Exception as e:  # requests raises a family of these; none may escape
            return self._report(what, False, f"{type(e).__name__}: {e}")

    def _post(self, path: str, body: dict, what: str) -> bool:
        try:
            r = self._session.post(f"{self.base_url}{path}", json=body, timeout=self.timeout)
            # The kernel answers 200 for these; anything else means it did not act on it.
            return self._report(what, r.status_code == 200, f"HTTP {r.status_code}")
        except Exception as e:
            return self._report(what, False, f"{type(e).__name__}: {e}")

    # --- northbound calls ---------------------------------------------------------

    def switch_entered(self, dpid: int) -> bool:
        """
        Tell the kernel a switch is now under control-plane management.

        Sets `isEnabled` immediately instead of waiting for the kernel's next topology poll
        (which reaches the same state on its own; see the module docstring). Sent once the
        switch is genuinely usable -- mastership held, pipeline pushed -- rather than on
        mastership alone, because a switch with no pipeline cannot forward and the flag means
        "the control plane can drive this switch".
        """
        return self._get(f"/ndt/inform_switch_entered?dpid={dpid}",
                         f"switch {dpid} entered")

    def link_failure(self, src_dpid: int, src_port: int,
                     dst_dpid: int, dst_port: int) -> bool:
        """Report a link that has stopped carrying LLDP beacons."""
        return self._post("/ndt/link_failure_detected",
                          self._link_body(src_dpid, src_port, dst_dpid, dst_port),
                          f"link failure {src_dpid}:{src_port}->{dst_dpid}:{dst_port}")

    def link_recovery(self, src_dpid: int, src_port: int,
                      dst_dpid: int, dst_port: int) -> bool:
        """Report a link whose LLDP beacons have resumed."""
        return self._post("/ndt/link_recovery_detected",
                          self._link_body(src_dpid, src_port, dst_dpid, dst_port),
                          f"link recovery {src_dpid}:{src_port}->{dst_dpid}:{dst_port}")

    @staticmethod
    def _link_body(src_dpid: int, src_port: int, dst_dpid: int, dst_port: int) -> dict:
        """
        The exact shape the kernel parses.

        Field names come from intelligent_router.py, which is the working reference -- the
        kernel reads `src_interface`/`dst_interface`, not `src_port`/`dst_port`, and a rename
        here would be accepted with a 200 and then ignored.
        """
        return {
            "src_dpid": src_dpid,
            "src_interface": src_port,
            "dst_dpid": dst_dpid,
            "dst_interface": dst_port,
        }

    def all_destination_paths(self, paths: list) -> bool:
        """
        Push a fresh host-to-host path snapshot.

        [Co-developed with claude code -- Adam]
        The plan called for this because `fetchAllDestinationPaths` used to run exactly once at
        startup, before discovery had converged, and its own empty guard made that a permanent
        silent no-op. That pull now retries at 5 s until it has paths and refreshes every 60 s
        (`refreshDestinationPathsPeriodically`), so this is no longer load-bearing for
        correctness -- what it buys is latency. After a link fails, the pull leaves the kernel
        answering `get_path_switch_count` from routes over the dead link for up to a minute;
        pushing on the transition closes that to one HTTP call.

        An empty list is not sent. `setAllPaths` would discard it anyway (it refuses an empty
        snapshot, deliberately, because before convergence "no paths" is a transient), so sending
        one would only produce a misleading "ok" in the log.
        """
        if not paths:
            return self._report("destination paths", False, "refusing to push an empty snapshot")
        return self._post("/ndt/inform_all_destination_paths",
                          {"all_destination_paths": paths},
                          f"destination paths ({len(paths)} paths)")


def renotify_until_acknowledged(notify, dpids, *, attempts=30, interval_s=10.0,
                                sleep=None, log=print):
    """
    Keep re-pushing switch-entered for the dpids a startup attempt could not deliver.

    [Co-developed with claude code -- Adam]
    Under stack.sh's P4 ordering the kernel deliberately starts last, so the startup push
    always fires into a closed port and every dpid lands here. The kernel's own topology poll
    enables switches anyway (TopologyAndFlowMonitor.cpp:566), so nothing is broken while this
    retries -- the retry just makes the push path deliver instead of dying on its first and
    only attempt. Bounded: 30 x 10 s covers the kernel's convergence-gated start with room to
    spare, and a kernel that never appears stops costing anything after five minutes.

    `notify` is called once per remaining dpid per round and must return truthiness for
    "acknowledged" (KernelNotifier.switch_entered fits). Sleeps BEFORE each round: the caller
    just finished a full attempt. Returns the dpids that were never acknowledged.
    """
    import time as _time
    do_sleep = sleep if sleep is not None else _time.sleep
    remaining = list(dpids)
    for _ in range(attempts):
        if not remaining:
            break
        do_sleep(interval_s)
        remaining = [d for d in remaining if not notify(d)]
    if remaining:
        log(f"[Proxy Agent] switch-entered was never acknowledged for {remaining} "
            f"after {attempts} retries; the kernel's topology poll remains the "
            f"operative enable path")
    else:
        log("[Proxy Agent] switch-entered acknowledged for all remaining switches on retry")
    return remaining
