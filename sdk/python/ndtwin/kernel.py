"""The client: topology, link usage, power, locks, and the `p4` namespace.

[Co-developed with claude code -- Adam]

It calls the kernel's `/ndt/...` routes (port 8000) and nothing else; the P4 proxy's own routes are
not used.
"""
import contextlib
from dataclasses import dataclass

from ._http import Transport
from .errors import NDTwinError, NotFound, PowerError
from .p4 import P4
from .topology import Topology


@dataclass(frozen=True)
class PowerState:
    admin_state: str     # "on" / "off": what the twin was commanded
    reachable: bool      # whether the twin can reach the switch now


class LinkUsage(float):
    """The average link usage (a 0..1 fraction) as a float, with the kernel's `telemetry_health`
    (the sFlow collector's own state for the window, §24) attached; None when the reply has none.
    The average alone does not say whether the samples behind it were complete: a healthy window
    has `telemetry_health["status"] == "ok"`."""

    telemetry_health = None


class Lease:
    """A held lock, as `Kernel.lock` yields it: `name`, `id` (the kernel's lease number) and
    the `ttl` in seconds of the last acquire or renew."""

    def __init__(self, http, name, id, ttl):
        self._http, self.name, self.id, self.ttl = http, name, id, ttl

    def renew(self, ttl=None):
        """Extend the lock to `ttl` seconds from now (§28); the TTL of the acquire when omitted.

        Raises Refused (nothing was extended) when the lease ran out (412) or the lock moved on
        to another lease (409); the lock is then no longer held, so stop writing.
        """
        ttl = self.ttl if ttl is None else ttl
        self._http.call("POST", "/ndt/renew_lock",
                        body={"type": self.name, "ttl": ttl, "lease": self.id})
        self.ttl = ttl


class Kernel:
    """A client for one kernel.

    `timeout` is the socket timeout of one request in seconds; it is longer than the kernel's own
    15 s deadline on the /ndt/p4 table routes. A request is sent up to `retries + 1` times, `retry_wait`
    seconds apart, and only when sending it again cannot write anything twice (see `_http.retryable`).
    A negative `retries`, and a negative, infinite or NaN `retry_wait`, raise ValueError.
    """

    def __init__(self, url="http://localhost:8000", timeout=20.0, retries=2, retry_wait=1.0):
        self._http = Transport(url, timeout, retries, retry_wait)
        self.p4 = P4(self._http)
        self._switch_of = {}

    # --- reads -------------------------------------------------------------------------------

    def topology(self):
        """GET /ndt/get_graph_data (§3). Also remembers each switch's management address.

        A reply without the fields the SDK reads is an NDTwinError (nothing_written True)."""
        path = "/ndt/get_graph_data"
        body = self._http.call("GET", path).body
        try:
            topo = Topology.from_graph(body)
        except (KeyError, IndexError, TypeError, ValueError, AttributeError) as exc:
            raise NDTwinError(f"GET {path}: a graph the SDK cannot read: {exc!r}", method="GET",
                              path=path, status=200, body=body, nothing_written=True) from exc
        self._switch_of = dict(topo.switches)
        return topo

    def average_link_usage(self):
        """GET /ndt/get_average_link_usage (§24): a `LinkUsage`, a 0..1 fraction that also
        carries the reply's `telemetry_health`."""
        body = self._http.call("GET", "/ndt/get_average_link_usage").body
        usage = LinkUsage(body["avg_link_usage"])
        usage.telemetry_health = body.get("telemetry_health")
        return usage

    def power_report(self):
        """GET /ndt/get_power_report (§6): {dpid: milliwatts}. -1: nobody manages that switch."""
        return {p["dpid"]: p["power_consumed"]
                for p in self._http.call("GET", "/ndt/get_power_report").body}

    def power_state(self, dpid):
        """GET /ndt/get_switches_power_state (§7) for one switch, addressed by dpid."""
        ip = self._mgmt_ip(dpid)
        state = (self._http.call("GET", "/ndt/get_switches_power_state", {"ip": ip}).body or {}).get(ip)
        if not isinstance(state, dict):
            raise NDTwinError(f"no power state for s{dpid} ({ip})", nothing_written=True)
        return PowerState(state.get("admin_state"), state.get("reachable"))

    # --- writes ------------------------------------------------------------------------------

    def power_off(self, dpid):
        """POST /ndt/set_switches_power_state (§8), then read the state back (§7).

        Returns the state, which is "off", or raises an NDTwinError: PowerError when the kernel
        failed the command or the state read afterwards is not "off", NotFound for an unknown
        switch, KernelUnreachable when nothing connected, OutcomeUnknown for a connection that
        broke after the command went out. A PowerError always has `may_have_landed` True: the
        kernel's 500 does not tell a power helper that never touched the switch from one that
        signalled it and gave up waiting, nor a plug that was switched before the kernel gave up.
        `reachable` in the state returned lags behind the command (§7).
        """
        ip = self._mgmt_ip(dpid)
        self._http.call("POST", "/ndt/set_switches_power_state", {"ip": ip, "action": "off"})
        try:
            state = self.power_state(dpid)
        except NDTwinError as err:
            raise PowerError(f"s{dpid} ({ip}) was told to power off; reading its state failed: "
                             f"{err}", nothing_written=None) from err
        if state.admin_state != "off":
            raise PowerError(f"s{dpid} ({ip}) was told to power off and reports "
                             f"admin_state {state.admin_state!r}", nothing_written=None)
        return state

    @contextlib.contextmanager
    def lock(self, name, ttl=5):
        """Hold the advisory lock `name` (§27) for the `with` block; yields the `Lease`.

        The lock is released with its lease (§29) when the block ends, also when it raises; a
        failed release does not replace the exception that is already on its way. After Ctrl-C
        (any exception that is not an `Exception`) the release is tried once, without the retries.
        Raises LockBusy when the lock is held. The lock is not renewed by itself: keep the block
        shorter than `ttl`, or call `lease.renew()` (§28) before a step that must still hold it.
        """
        reply = self._http.call("POST", "/ndt/acquire_lock", body={"type": name, "ttl": ttl}).body
        lease = Lease(self._http, name, reply["lease"], ttl)
        try:
            yield lease
        except Exception:
            with contextlib.suppress(NDTwinError):
                self._release(lease)
            raise
        except BaseException:
            with contextlib.suppress(NDTwinError):
                self._release(lease, retries=0)
            raise
        self._release(lease)

    def _release(self, lease, retries=None):
        self._http.call("POST", "/ndt/release_lock", body={"type": lease.name, "lease": lease.id},
                        retries=retries)

    # --- helpers -----------------------------------------------------------------------------

    def _mgmt_ip(self, dpid):
        """The switch's management address; the topology is read first if it is not known yet."""
        if dpid not in self._switch_of:
            self.topology()
        ip = self._switch_of[dpid].mgmt_ip if dpid in self._switch_of else None
        if not ip:
            raise NotFound(f"no switch {dpid} with a management address in the topology",
                           nothing_written=True)
        return ip
