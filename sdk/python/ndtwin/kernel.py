"""The client: topology, link usage, power (off and on), locks, moving the routes of a table off a
switch, and the `p4` namespace.

[Co-developed with claude code -- Adam]

It calls the kernel's `/ndt/...` routes (port 8000) and nothing else; the P4 proxy's own routes are
not used.
"""
import contextlib
from dataclasses import dataclass

from . import reroute
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


def _owned_by_ndtwin(switch):
    """Whether every table of the switch belongs to NDTwin: its own pipeline, which the proxy
    reports as `ipv4_route` "ndtwin" with `binding_source` "baseline". A package that gives its
    route table to NDTwin reports "ndtwin" too, with `binding_source` "package": one table only.
    [Co-developed with claude code -- Adam]"""
    caps = switch.capabilities or {}
    return caps.get("ipv4_route") == "ndtwin" and caps.get("binding_source") == "baseline"


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
        On a P4 (bmv2) switch `reachable` in the state returned is already False: the kernel marks
        the switch down when it records the command.
        """
        return self._set_power(dpid, "off")

    def power_on(self, dpid):
        """POST /ndt/set_switches_power_state (§8) with action=on, then read the state back (§7).

        The twin of `power_off`, with the same errors: it returns the state, which is "on", or
        raises PowerError (`may_have_landed` True) when the kernel failed the command or the
        state read afterwards is not "on". A switch the twin already knows to be on, and that it
        has not been told to power off, is left alone and reported on.

        On a P4 (bmv2) switch the kernel starts the switch's bmv2 again (the root helper
        `ndtwin-p4-power`, as for a power-off) and has the P4 proxy re-adopt it, and answers only
        after both: the switch then runs its pipeline again, pushed afresh, which empties every
        table. What goes back into the tables: on a fabric brought up with an app package
        (`ndt up p4 --app`), the package's own entries and then the writes made through
        `p4.write`, `p4.modify` and `p4.modify_all` since the proxy started (the proxy's
        table-entry journal, when it is on, which is the default), before `power_on` returns.
        On NDTwin's own pipeline the proxy refuses those writes (409, "owned by NDTwin"), and
        NDTwin's routes are put back by the re-adoption while the proxy still has paths through
        the switch, or else by its link watchdog once the switch's links are seen again, after
        `power_on` has returned (seen on bmv2 1.15.5: back at the return after 12 s off, about
        2 s after it after 90 s off; with no link watchdog on the fabric, never): do not write
        them yourself. Rules installed through
        `/ndt/install_flow_entry` are never put back. So read the switch's tables after a
        power-on (`p4.read_table`) and send again what your app wrote and does not find.

        A PowerError here can also mean bmv2 is running again but its re-adoption did not finish:
        the switch may not forward, and sending the power-on again does not retry the re-adoption
        (the kernel log names the step that failed and the recovery). The kernel gives the
        re-adoption up to 30 s, longer than the client's default `timeout` of 20 s: a slow one
        then raises OutcomeUnknown, and the switch may still come up.
        [Co-developed with claude code -- Adam]
        """
        return self._set_power(dpid, "on")

    def _set_power(self, dpid, action):
        ip = self._mgmt_ip(dpid)
        self._http.call("POST", "/ndt/set_switches_power_state", {"ip": ip, "action": action})
        try:
            state = self.power_state(dpid)
        except NDTwinError as err:
            raise PowerError(f"s{dpid} ({ip}) was told to power {action}; reading its state "
                             f"failed: {err}", nothing_written=None) from err
        if state.admin_state != action:
            raise PowerError(f"s{dpid} ({ip}) was told to power {action} and reports "
                             f"admin_state {state.admin_state!r}", nothing_written=None)
        return state

    # --- moving routes off a switch ------------------------------------------------------------

    def plan_routes_off(self, dpid, table, *, port_param="port", mac_param=None,
                        match_field="hdr.ipv4.dstAddr", topo=None):
        """The modifies that move every route of `table` leaving towards switch `dpid` onto
        another way, as a `RoutePlan`; nothing is written (this is the dry run).

        `port_param` is the action parameter that holds the egress port, `match_field` the
        match field that holds the destination address, and `mac_param`, when given, the action
        parameter that holds the next hop's MAC address; the SDK cannot read these names from
        the kernel, so name yours when they differ. It reads the topology (or takes `topo`) and
        the table of every usable switch but `dpid`. An entry leaves towards `dpid` when its
        `port_param` leads there over a link that is up. For each such entry it takes the hosts
        its destination holds, and of the switch's other ports the one whose neighbour reaches
        the switches of all of them without passing `dpid` or coming back, the fewest hops in
        all first, then the lowest port. With `mac_param`, the moved entry takes the MAC address
        of the switch's other entries that leave on the new port; without it, the entry keeps
        the one it had.

        Then it follows the packets of every switch with a host to every host not on `dpid`
        through the tables as they will be, and refuses unless each one is delivered without
        passing `dpid`. It refuses, raising NoDetour (nothing written) with the entry named,
        rather than guess, when: `dpid` is off or unreachable; a default entry sends packets to
        `dpid`; an entry has a priority (the check follows longest prefixes only) or a match
        key besides `match_field`; an entry's action has parameters but no `port_param` (or no
        `mac_param`, when that is named); a destination is not an IPv4 address or prefix, holds
        no known host, or holds a host on `dpid` or on the entry's own switch; no other port has
        a way; `mac_param` finds no MAC address, or two. The check does not follow a default
        entry whose action has parameters, or an entry that matches every address, so a packet
        that needs one is refused as "not followed". One table per call: a pipeline that
        forwards through several tables is not followed. A table that cannot be read in full
        raises the NDTwinError of that read. Hold the lock you write under from before this call
        to after the write: the plan is only as good as the tables it read.
        [Co-developed with claude code -- Adam]
        """
        topo = self.topology() if topo is None else topo
        if dpid not in topo.switches:
            raise NotFound(f"no switch {dpid} in the topology", nothing_written=True)
        if not topo.switches[dpid].usable:
            raise reroute.refusal(table, dpid, reroute.OFF)
        tables = {d: self.p4.read_table(d, table) for d, sw in topo.switches.items()
                  if sw.usable and d != dpid}
        return reroute.plan(topo, tables, dpid, table, port_param=port_param,
                            mac_param=mac_param, match_field=match_field)

    def move_routes_off(self, dpid, table, *, port_param="port", mac_param=None,
                        match_field="hdr.ipv4.dstAddr", topo=None, verify=True):
        """`plan_routes_off`, then `p4.modify_all` of the plan with `verify`: returns the
        `RoutePlan` of the entries as read back (as sent when `verify` is False), whose `old`
        holds them as they were. Raises what those two raise; a NoDetour means nothing was sent.
        A write that fails (also a read-back that fails, or Ctrl-C between two writes) is raised
        as it is, with the plan on it as `err.plan`: `k.p4.modify_all(err.plan.old)` moves the
        routes back. After a refused write `err.written` lists the entries that landed; after a
        failed read-back every entry was sent.

        It makes the plan first (it only reads), then refuses, before the first write, when a
        switch the plan would write runs NDTwin's own pipeline (`capabilities` `ipv4_route`
        `"ndtwin"` and `binding_source` `"baseline"`): every table there belongs to NDTwin and
        the proxy refuses the write. The refusal is a NoDetour (nothing written), and
        `plan_routes_off` still shows the plan. A package started with `--table-owner ndtwin`
        also reports `ipv4_route` `"ndtwin"`, but with `binding_source` `"package"`: only its
        route-role table belongs to NDTwin, so the first write to that table is refused
        (`Refused`, nothing written) and its other tables can be written. A table a package
        leaves to an external control plane is not told by the topology either; the first write
        finds out. Catch both `NoDetour` and `Refused`, or test `nothing_written`.
        [Co-developed with claude code -- Adam]
        """
        topo = self.topology() if topo is None else topo
        plan = self.plan_routes_off(dpid, table, port_param=port_param, mac_param=mac_param,
                                    match_field=match_field, topo=topo)
        owned = sorted({e.dpid for e in plan if _owned_by_ndtwin(topo.switches[e.dpid])})
        if owned:
            raise reroute.refusal(
                table, dpid, f"the tables of s{owned[0]} belong to NDTwin (capabilities "
                             f"ipv4_route 'ndtwin', binding_source 'baseline'), so the proxy "
                             f"does not let an app write them; plan_routes_off still shows the "
                             f"plan")
        try:
            done = self.p4.modify_all(plan, verify=verify)
        except (NDTwinError, KeyboardInterrupt) as err:
            err.plan = plan
            raise
        return reroute.RoutePlan(done, plan.old, dpid, table)

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
