import json
import os
import threading
import time

import networkx as nx

# Shared so the two loaders cannot disagree about which topology file is authoritative.
from proxy_agent import ryu_topology  # no cycle: ryu_topology imports nothing from here
from proxy_agent.sflow_emitter import DEFAULT_TOPO_FILE

# [Co-developed with claude code -- Adam]
#
# The ipv4_lpm table keys on the destination address and nothing else, so every other match
# field a caller sends is unrepresentable in it. Those fields used to be read past in silence:
# route_flow picked out nw_dst and dropped the rest, so a rule sent as
#
#   {"ipv4_src": "10.0.0.1", "ipv4_dst": "10.0.0.4", "ip_proto": 17,
#    "udp_src": 35909, "udp_dst": 5001}   priority 100
#
# was installed as "10.0.0.4/32 -> port N" and the proxy answered 200. Verified live: the rule
# took effect and traffic followed the new port, but it applied to *all* traffic to 10.0.0.4
# rather than the one flow the caller named, and the table read back priority 0 rather than 100.
# A Traffic-Engineering rule aimed at one flow silently became a rule for a whole destination.
#
# The plan's own rule is "where P4 genuinely cannot honour a semantic, the proxy returns an
# explicit error the kernel logs -- never a silent success", so these are rejected now. The
# pipeline does have a ternary flow_5tuple table with real priority (Phase 4); wiring route_flow
# to it is the proper fix and remains Phase 3 work. Until then, refusing beats pretending.
#: How many offending field names are echoed back. The match dict comes from an unauthenticated
#: REST body, so a caller can send thousands of keys; without a cap every one of them is sorted,
#: joined, printed to stdout and echoed in the 400 body. Small amplification, but free to remove.
#: [Co-developed with claude code -- Adam]
MAX_REPORTED_FIELDS = 12


class UnsupportedMatchError(ValueError):
    """Raised when a match asks for something no table in the pipeline can express."""

    def __init__(self, fields):
        self.fields = sorted(fields)
        shown = self.fields[:MAX_REPORTED_FIELDS]
        extra = len(self.fields) - len(shown)
        # The message used to read "ipv4_lpm keys on the destination address only", which was
        # true when that was the only table written and became misleading the moment
        # flow_5tuple was wired up: a caller sending ip_proto was told the destination-only
        # table could not honour it, when in fact it now can be honoured, and a caller sending
        # dl_dst was told the right thing for the wrong reason. Name both tables and what they
        # cover, so the error says which rules are worth rewriting.
        # [Co-developed with claude code -- Adam]
        super().__init__(
            "no table can honour: "
            + ", ".join(shown)
            + (f" (+{extra} more)" if extra > 0 else "")
            + " -- ipv4_lpm keys on the destination address, flow_5tuple on "
              "in_port/src/dst/proto/L4 ports"
        )


class MalformedMatchError(UnsupportedMatchError):
    """
    Raised when `match` is not a JSON object at all.

    [Co-developed with claude code -- Adam]
    A subclass so the existing `except UnsupportedMatchError` in api_routes still answers 400 --
    which is the right status, and what this used to get wrong. `(match_dict or {}).items()` raised
    AttributeError for a list, string or number, that escaped the handler's only catch, and FastAPI
    turned a malformed request into **500 Internal Server Error**. Same defect class as the three
    500s already fixed on the kernel side. Found by agy-review 0072.
    """

    def __init__(self, value):
        # Deliberately does not echo the value: it is attacker-controlled and may be huge. The type
        # is what the caller needs.
        ValueError.__init__(self, f"match must be a JSON object, got {type(value).__name__}")
        self.fields = []


def parse_eth_type(value):
    """
    An ethertype as an int, or None if it is not one.

    [Co-developed with claude code -- Adam]
    `int(value)` was used here, and it raises ValueError on `"0x0800"` -- so a caller writing the
    ethertype the way OpenFlow tooling usually writes it had a perfectly valid IPv4 rule **rejected
    with 400**. The falsely-rejected direction is the worse one: it breaks a working client rather
    than merely letting something through. Found by agy-review 0072.

    bool is excluded before int because `True == 1` in Python and `{"eth_type": true}` is not a
    request to match ethertype 1.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        text = value.strip()
        try:
            return int(text, 16) if text.lower().startswith("0x") else int(text, 10)
        except ValueError:
            return None
    return None


#: The only match fields the table actually keys on.
HONOURED_MATCH_FIELDS = frozenset({"nw_dst", "ipv4_dst"})

#: OpenFlow match field -> the flow_5tuple key it becomes. The table is six ternary keys
#: (ndtwin_switch.p4:307) and has existed since the pipeline was written; nothing on the proxy
#: side ever compiled to it, so every match richer than a destination was refused with a 400 and
#: the table sat empty. [Co-developed with claude code -- Adam]
#:
#: Both spellings of each field are accepted because both are in use: OF1.0-era names (nw_src,
#: tp_dst) come from the kernel's own JSON, OF1.3 names (ipv4_src, tcp_dst) from Ryu-shaped
#: callers. Mapping them to one P4 key rather than picking a winner means a caller never has to
#: know which vocabulary this proxy prefers.
#:
#: `tcp_*` and `udp_*` collapse onto the same key on purpose: the pipeline parses either L4
#: header into meta.l4_src_port / meta.l4_dst_port, so the protocol is what distinguishes them
#: and it is a key in its own right.
FIVE_TUPLE_FIELD_MAP = {
    "in_port":   "standard_metadata.ingress_port",
    "nw_src":    "hdr.ipv4.srcAddr",
    "ipv4_src":  "hdr.ipv4.srcAddr",
    "nw_dst":    "hdr.ipv4.dstAddr",
    "ipv4_dst":  "hdr.ipv4.dstAddr",
    "nw_proto":  "hdr.ipv4.protocol",
    "ip_proto":  "hdr.ipv4.protocol",
    "tp_src":    "meta.l4_src_port",
    "tcp_src":   "meta.l4_src_port",
    "udp_src":   "meta.l4_src_port",
    "tp_dst":    "meta.l4_dst_port",
    "tcp_dst":   "meta.l4_dst_port",
    "udp_dst":   "meta.l4_dst_port",
}

#: The fields that, when present, mean this match cannot be an ipv4_lpm entry. Destination alone
#: still goes to ipv4_lpm: that is the path every existing route takes, it is exact today, and
#: routing all of them through a ternary table instead would change the behaviour of the entire
#: fabric to deliver a feature nobody asked it for.
FIVE_TUPLE_ONLY_FIELDS = frozenset(FIVE_TUPLE_FIELD_MAP) - HONOURED_MATCH_FIELDS

#: Sent on essentially every IPv4 rule. Validated below, but not a key: ipv4_lpm is IPv4 by
#: construction, so eth_type 0x0800 is a tautology and anything else is unrepresentable.
ETH_TYPE_FIELDS = frozenset({"dl_type", "eth_type"})

IPV4_ETH_TYPE = 0x0800


def unsupported_match_fields(match_dict):
    """
    Names the match fields this table cannot honour, sorted. Empty means the match is expressible.

    A wrong eth_type is reported under its own field name rather than ignored: a caller asking to
    match ARP or IPv6 must not have it quietly serviced as IPv4.

    [Co-developed with claude code -- Adam]
    """
    if match_dict is None:
        return []
    if not isinstance(match_dict, dict):
        # A list, string or number here used to raise AttributeError out of .items() and become a
        # 500. [Co-developed with claude code -- Adam]
        raise MalformedMatchError(match_dict)

    bad = []
    for field, value in match_dict.items():
        if field in HONOURED_MATCH_FIELDS:
            continue
        if field in FIVE_TUPLE_FIELD_MAP:
            # Expressible since the flow_5tuple table was wired up. Before that these were
            # refused with a 400 naming ipv4_lpm, which was accurate about the table being
            # written and misleading about the pipeline's capability -- the table was there the
            # whole time. [Co-developed with claude code -- Adam]
            continue
        if field in ETH_TYPE_FIELDS:
            if parse_eth_type(value) != IPV4_ETH_TYPE:
                bad.append(field)
            continue
        bad.append(field)
    return sorted(bad)


def p4_priority(openflow_priority):
    """
    OpenFlow priority -> P4Runtime priority for a ternary entry.

    [Co-developed with claude code -- Adam]
    Both are "higher wins", so the mapping is order-preserving by construction. The +1 exists
    because OpenFlow's range starts at 0 and P4Runtime rejects priority 0 on a ternary table:
    shifting the whole scale keeps every relative ordering the caller intended while making the
    lowest band expressible. Clamping 0 to 1 instead would collapse priorities 0 and 1 onto each
    other, which is a silent reordering of exactly the rules a caller was most careful about.

    A missing priority becomes 0 -> 1, the lowest band, which is the right default for a table
    that sits in FRONT of ipv4_lpm: an unprioritised 5-tuple rule should still win over the
    destination-only fallback, but lose to anything anyone bothered to rank.
    """
    try:
        of = int(openflow_priority) if openflow_priority is not None else 0
    except (TypeError, ValueError):
        of = 0
    return max(0, of) + 1


def needs_five_tuple(match_dict):
    """
    Whether this match must go to flow_5tuple rather than ipv4_lpm.

    True as soon as any field beyond the destination appears. Destination-only matches keep
    going to ipv4_lpm unchanged -- see FIVE_TUPLE_ONLY_FIELDS for why that split rather than
    sending everything through the ternary table. [Co-developed with claude code -- Adam]
    """
    if not isinstance(match_dict, dict):
        return False
    return any(f in FIVE_TUPLE_ONLY_FIELDS for f in match_dict)


def five_tuple_keys(match_dict):
    """
    The flow_5tuple keys this match sets, as {p4_field_name: value}, sorted by field name.

    Collapses the accepted spellings onto one P4 key each. A match that sets the same key twice
    under two spellings with DIFFERENT values is a contradiction the caller has to resolve --
    silently keeping whichever dict order surfaced last would install a rule the caller did not
    ask for, and this table is precisely the one people reach for when they need exactness.
    [Co-developed with claude code -- Adam]
    """
    keys = {}
    for field, value in sorted(match_dict.items()):
        p4_field = FIVE_TUPLE_FIELD_MAP.get(field)
        if p4_field is None:
            continue
        if p4_field in keys and keys[p4_field] != value:
            raise UnsupportedMatchError([field])
        keys[p4_field] = value
    return keys


#: How often each switch broadcasts an LLDP beacon on its inter-switch ports.
#: The kernel's liveness policy allows one missed round (kLldpFreshSeconds = 12 s), so changing this
#: means changing that. [Co-developed with claude code -- Adam]
LLDP_BEACON_INTERVAL_S = 5

# [Co-developed with claude code -- Adam]
# Experiment knob for KNOWN-ISSUES D-2 (sweep the beacon interval, measure detection AND false
# positives). Placed before the derived constants below so timeout, watchdog and startup grace
# all follow the override -- that derivation chain is the cheap part of the change and splitting
# it would be a fourth constant to keep in sync.
#
# What does NOT follow: kLldpFreshSeconds = 12.0 is a C++ constant
# (DeviceConfigurationAndPowerManager.hpp) -- at 2.5 s the switch-liveness window tolerates 4.8
# beacons instead of 2.4, and above 12 s it would start declaring live switches dead. The knob
# refuses the latter; the former is part of what D-2's experiment is for.
#
# The override announces itself, same rule as NDTWIN_RYU_LLDP_GUARD: this repo has shipped a
# setter with no reader and a reader with no setter, and both produced runs that looked
# configured and were not.
_beacon_env = os.environ.get("NDTWIN_P4_BEACON_S")
if _beacon_env:
    try:
        _beacon = float(_beacon_env)
        if not 0 < _beacon <= 12:
            raise ValueError
        LLDP_BEACON_INTERVAL_S = _beacon
        print(f"NDTWIN: LLDP_BEACON_INTERVAL_S overridden to {LLDP_BEACON_INTERVAL_S}s "
              f"(default 5); timeout/watchdog/grace derive from it", flush=True)
    except ValueError:
        print(f"NDTWIN: ignoring NDTWIN_P4_BEACON_S={_beacon_env!r} (want 0 < s <= 12; above 12 "
              f"the kernel's kLldpFreshSeconds would declare live switches dead); keeping "
              f"{LLDP_BEACON_INTERVAL_S}s", flush=True)

#: Used only when the topology file cannot be read. The previous unconditional behaviour, kept as a
#: fallback so discovery still works, but reported rather than silent.
LLDP_FALLBACK_PORTS = tuple(range(1, 7))

#: How long a discovered link may go without a beacon before it is reported as failed.
#:
#: [Co-developed with claude code -- Adam]
#: Three beacon intervals, so two consecutive misses are tolerated. One interval would report a
#: failure every time a scan happened to land just before a beacon did, and a flapping link report
#: is worse than a slow one: each one makes the kernel tear down the edge, drop it out of BFS and
#: recompute paths.
#:
#: Detection therefore takes between LINK_BEACON_TIMEOUT_S and that plus one scan interval -- 15 to
#: 20 s. Deliberately not tied to the kernel's kLldpFreshSeconds (12 s): that is the freshness
#: window for deciding a *switch* is alive, which is a different question with a different cost of
#: being wrong.
LINK_BEACON_TIMEOUT_S = 3 * LLDP_BEACON_INTERVAL_S

#: How often the watchdog looks for links that have gone quiet.
LINK_WATCHDOG_INTERVAL_S = LLDP_BEACON_INTERVAL_S

#: How long a link that has *never* delivered a beacon is given before it is called down. Only
#: applies to links seeded from the topology file; see TopologyManager.seed_expected_links.
#:
#: [Co-developed with claude code -- Adam]
#: Longer than LINK_BEACON_TIMEOUT_S because silence before the first beacon has an innocent
#: explanation the steady state does not: the far switch may still be loading its pipeline, and
#: until it does it cannot forward a beacon to its CPU port. Reporting that as a link failure would
#: make every link flap once at startup.
LINK_STARTUP_GRACE_S = 6 * LLDP_BEACON_INTERVAL_S

#: First four bytes of the LLDP beacon source MAC.
#:
#: [Co-developed with claude code -- Adam]
#: The beacon used to be sourced from `00:00:00:00:00:{dpid:02x}`, which **is** the host MAC range:
#: main.py registers hosts as 00:00:00:00:00:01 through :04, so the beacons from s1-s4 carried the
#: exact source addresses of h1-h4. Whatever learns from those addresses -- the pipeline, another
#: controller, a capture someone is reading -- is told those hosts live on every inter-switch port.
#:
#: 0x0e has the locally-administered bit set and the multicast bit clear, so this is a valid unicast
#: address that no vendor can be assigned and nothing else here uses. The dpid goes in the low two
#: bytes, which also removes a crash: `bytes.fromhex(f"...{dpid:02x}")` raises for any dpid >= 256,
#: because three hex digits is an odd-length string.
LLDP_SOURCE_MAC_PREFIX = bytes.fromhex("0e000000")


def lldp_source_mac(dpid: int) -> bytes:
    """The six-byte source address for this switch's beacons. See LLDP_SOURCE_MAC_PREFIX."""
    # Masked rather than allowed to overflow: the dpid a receiver acts on comes from the payload,
    # not from here, so two switches 65536 apart sharing a source MAC costs nothing.
    return LLDP_SOURCE_MAC_PREFIX + (int(dpid) & 0xFFFF).to_bytes(2, "big")


def load_switch_links(path=None):
    """
    Every inter-switch link the topology JSON declares, as (src_dpid, src_port, dst_dpid, dst_port).

    [Co-developed with claude code -- Adam]
    One directed tuple per edge, which is the same shape a received LLDP beacon proves and the same
    shape /ndt/link_failure_detected takes -- so a beacon can be matched against a declared link
    without either side translating.

    Host-facing edges are excluded: a beacon sent at a host is answered by nothing and, before the
    source MAC was fixed, actively poisoned learning with a host's own address.

    Reads the kernel's own file, and honours NDTWIN_TOPO_FILE, for the same reason
    load_switch_agent_ips does -- the two must not disagree about the topology. Returns [] when it
    cannot be read, and callers fall back loudly.
    """
    path = path or os.environ.get("NDTWIN_TOPO_FILE") or DEFAULT_TOPO_FILE
    try:
        with open(path) as fh:
            topology = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"[TopologyManager] could not read topology {path}: {e}")
        return []

    switch_dpids = {
        node.get("dpid")
        for node in topology.get("nodes", [])
        if node.get("vertex_type") == 0 and node.get("dpid")
    }
    links = []
    for edge in topology.get("edges", []):
        src, dst = edge.get("src_dpid"), edge.get("dst_dpid")
        # `src_interface`, not `src_port` -- the field is named for the physical interface.
        src_port, dst_port = edge.get("src_interface"), edge.get("dst_interface")
        if src in switch_dpids and dst in switch_dpids and src and dst and src_port and dst_port:
            links.append((int(src), int(src_port), int(dst), int(dst_port)))
    return links


def load_switch_link_ports(path=None):
    """
    dpid -> sorted tuple of ports that face another switch.

    Derived from load_switch_links rather than parsing the file a second time: two readers of the
    same JSON are two chances to disagree about which ports face a switch, and the beacon sender and
    the beacon watchdog disagreeing would make every link look failed.
    [Co-developed with claude code -- Adam]
    """
    ports = {}
    for src, src_port, _dst, _dst_port in load_switch_links(path):
        ports.setdefault(src, set()).add(src_port)
    return {dpid: tuple(sorted(p)) for dpid, p in ports.items()}


#: How often the liveness poller round-trips a P4Runtime RPC to each switch, in seconds.
#: Independent of how often the kernel asks: the kernel polls at 1 Hz and reads the cache, so the
#: probe rate is not multiplied by the number of readers. [Co-developed with claude code -- Adam]
LIVENESS_PROBE_INTERVAL_S = 2.0

#: Per-probe gRPC deadline. Must stay well below the interval so a hung switch cannot make the
#: poller fall behind on the other nine.
LIVENESS_PROBE_TIMEOUT_S = 1.5


class TopologyManager:
    """Maintains the network state and computes shortest paths via BFS"""

    def __init__(self, kernel_notifier=None, clock=time.monotonic):
        # [Co-developed with claude code -- Adam]
        # `kernel_notifier` is optional so the many tests that build a bare TopologyManager keep
        # working, and because bookkeeping-only is a genuinely useful mode: without one the beacon
        # watchdog still tracks link state and reports it through switch_liveness(), it just tells
        # nobody. `clock` is injected because every freshness decision in here is arithmetic on it,
        # and a test that has to sleep for fifteen seconds to check a fifteen-second timeout is a
        # test nobody will run.
        self._kernel = kernel_notifier
        self._clock = clock

        self.net = nx.DiGraph()
        self.switches = {} # dpid -> P4RuntimeClient
        self.dest_paths = {} # To match Ryu's format

        # --- Graph structure lock. [Co-developed with claude code -- Adam]
        #
        # `net` is written by the gRPC stream-receive threads (`handle_packet_in` -> `add_link`
        # when LLDP discovers a neighbour) and by startup (`add_switch`/`add_host`), while the
        # link watchdog thread reads the whole thing to recompute destination paths.
        #
        # The graph is append-only -- nothing anywhere calls `remove_node`/`remove_edge` -- so a
        # reader can never observe a deletion. What it *can* observe is an insertion partway
        # through its own traversal, and networkx traversals iterate the adjacency dicts
        # directly: `RuntimeError: dictionary changed size during iteration`. In
        # `push_destination_paths` that lands inside a `except Exception` whose job is to keep the
        # watchdog thread alive, so the failure mode is a silently skipped push -- exactly the
        # stale-paths window the push exists to close.
        #
        # Separate from `_liveness_lock`, and the two are never held at once (see
        # `push_destination_paths`): they guard unrelated state and nesting them would be an
        # ordering hazard for no gain.
        #
        # ⚠️ Scope, as of 2026-08-11. Taken by: the writers below, `push_destination_paths`, and
        # `calculate_all_paths` (which copies under it and then walks the copy).
        #
        # Still unlocked, deliberately and with different risk:
        #
        #   - `api_routes.py` — `render_links`, `render_hosts` and `render_destination_paths` all
        #     iterate `topology.net` straight off the HTTP thread. Same RuntimeError is possible,
        #     but uvicorn turns an exception in a handler into a 500 for that one request; it does
        #     not lose a thread. A caller retries and gets an answer.
        #   - `install_initial_routes` — reads `net.nodes[x]` / `net.edges[x, y]` one key at a time
        #     rather than iterating, and a single dict lookup is atomic under the GIL. It is the
        #     *iteration* that raises "dictionary changed size", which is why `calculate_all_paths`
        #     was the one that had to move and these did not.
        #
        # Separate from `_liveness_lock`, and the two are never held at once (see
        # `push_destination_paths`).
        self._net_lock = threading.RLock()

        # --- What we have actually written to the switches. [Co-developed with claude code -- Adam]
        #
        # (dpid, dst_host_ip) -> out_port, recorded only when the write succeeded. This exists
        # because `net` and the rules in the switches are allowed to disagree, and until now
        # nothing noticed: routes are installed when a link is *discovered* and never again, so
        # after a link fails the graph grows a new shortest path that no switch has been told
        # about. Advertising that path told consumers a route existed when the packets were being
        # dropped. Guarded by _net_lock, which is an RLock, so the install path may hold it already.
        self._installed_routes = {}

        # --- Liveness evidence. [Co-developed with claude code -- Adam]
        #
        # Guarded by its own lock rather than sharing one with the graph: it is written by the LLDP
        # receive path and the probe thread, and read by an HTTP handler, and none of those should
        # wait on a BFS.
        #
        # monotonic() rather than time(): a wall-clock step (ntp, suspend/resume) would otherwise
        # make a switch look stale or impossibly fresh.
        self._liveness_lock = threading.Lock()

        #: dpid -> monotonic timestamp of the last CPU packet received *from* that switch. Proves
        #: its stream and CPU port are working.
        self._last_packet_in = {}

        #: dpid -> monotonic timestamp of the last LLDP beacon seen that *originated* from that
        #: dpid, wherever it was received. Proves it is forwarding, which the gRPC probe does not.
        self._last_lldp_from = {}

        #: dpid -> {"ok": bool, "detail": str, "at": monotonic}. Last probe result.
        self._last_probe = {}

        #: (src_dpid, src_port, dst_dpid, dst_port) -> {"at": monotonic, "down": bool, "acked": bool}
        #:
        #: [Co-developed with claude code -- Adam]
        #: One entry per *direction*, created the first time a beacon proves that direction carries
        #: frames. A link the proxy has never seen a beacon on is absent rather than down: the twin
        #: cannot distinguish "this link is broken" from "this link was already broken when I
        #: started", and claiming the former would be inventing evidence.
        #:
        #: `down` is what the watchdog believes; `acked` is whether the kernel has been told the
        #: current belief. Two fields rather than one because the report can fail -- a kernel that
        #: is restarting must not cost us the notification permanently, which is how a failed link
        #: would show as up for the rest of the run.
        self._link_beacons = {}

        self._liveness_thread = None
        self._liveness_running = False
        # Event rather than time.sleep so stop() returns promptly instead of after a whole interval.
        self._liveness_stop = threading.Event()

        self._lldp_thread = None
        self._lldp_running = False
        self._lldp_stop = threading.Event()

        self._link_watchdog_thread = None
        self._link_watchdog_running = False
        self._link_watchdog_stop = threading.Event()

        #: dpid -> ports facing another switch, read once from the topology file. See
        #: load_switch_link_ports. [Co-developed with claude code -- Adam]
        self._link_ports = load_switch_link_ports()
        self._link_ports_warned = False

        # Serialises readopt_switch. Power operations are operator-paced, so contention is
        # not expected; the lock exists so that two concurrent readopts of the same dpid
        # cannot interleave their build/swap/stop sequences and leave a stopped client in
        # the switches map. [Co-developed with claude code -- Adam]
        self._readopt_lock = threading.Lock()

    def add_switch(self, dpid, client):
        if dpid not in self.switches:
            self.switches[dpid] = client
            with self._net_lock:
                self.net.add_node(dpid, type='switch')
            client.packet_in_callback = self.handle_packet_in

    def add_link(self, src_dpid, dst_dpid, src_port, dst_port):
        # Both directions under one acquisition: a reader that saw only the forward edge would
        # compute a path the reverse of which does not exist yet.
        with self._net_lock:
            self.net.add_edge(src_dpid, dst_dpid, port=src_port)
            self.net.add_edge(dst_dpid, src_dpid, port=dst_port)

    def add_host(self, ip, mac, switch_dpid, port):
        with self._net_lock:
            self.net.add_node(ip, type='host', mac=mac)
            self.net.add_edge(switch_dpid, ip, port=port)
            self.net.add_edge(ip, switch_dpid, port=0)

    def reroutable_down_endpoints(self):
        """
        The `(dpid, port)` down reports that justify moving traffic, as opposed to reporting it.

        [Co-developed with claude code -- Adam]
        Not the same set as `down_link_endpoints`, and deliberately so. That one answers "what
        should the twin stop claiming", where over-reporting is the safe direction. This one
        answers "what should we reprogram switches because of", where over-reacting moves traffic
        off links that are carrying it perfectly well.

        The difference is one measured failure mode. Taking a bmv2 interface down stalls that
        switch's entire packet-in path, so *every* link into it goes quiet at once and the
        watchdog reports them all: one real break produced five down directions, of which three
        were healthy links whose beacons simply had nowhere to be delivered. Rerouting on those
        three would have pulled traffic off working links, and put it back when the interface
        returned.

        The signature is distinguishable, because the two causes differ in what else is true:

          - a genuine single link failure leaves the switch's *other* inbound links beaconing;
          - a stalled CPU path silences all of them together, while the switch still answers
            P4Runtime -- `probe_ok` stayed true throughout the measurement.

        So an all-inbound-quiet switch that is still answering gRPC is treated as a switch-level
        symptom and its links are left in the routing graph. If it stops answering gRPC the switch
        really is gone, and its links are excluded like any other failure.

        **The amnesty is per link, not per switch**, because the switch that stalled is also the
        switch whose interface was taken down -- so the one genuinely broken link is always among
        the reports being forgiven, and forgiving it too would go on routing traffic into a link
        that is physically dead. The two are separable by the same asymmetry that defines the
        stall: a stalled CPU path stops the switch *receiving*, so only the inbound direction goes
        quiet and the outbound one keeps beaconing; a real break kills both directions. Checked
        against the five reports the measured fault produced -- the three false ones each had a
        live reverse, and both directions of the real break were down.

        An unknown reverse (never discovered) is treated as live, which keeps the conservative
        direction: this set decides what to reprogram, where doing nothing costs less than moving
        traffic off a link that was working.
        """
        with self._liveness_lock:
            down_links = {link for link, e in self._link_beacons.items() if e["down"]}
            inbound = {}
            for (src, src_port, dst, dst_port) in self._link_beacons:
                inbound.setdefault(dst, set()).add((src, src_port, dst, dst_port))
            probe_ok = {dpid: (p or {}).get("ok") for dpid, p in self._last_probe.items()}

        suspect = set()
        for dpid, links in inbound.items():
            if links and all(link in down_links for link in links) and probe_ok.get(dpid) is True:
                suspect.add(dpid)

        reroutable = set()
        for (src, src_port, dst, dst_port) in down_links:
            if dst in suspect and (dst, dst_port, src, src_port) not in down_links:
                continue  # inbound-only silence at a stalled switch: the link itself is fine
            reroutable.add((src, src_port))
        return reroutable

    def calculate_all_paths(self, exclude_endpoints=()):
        """
        Calculates all-pairs shortest paths using BFS.

        [Co-developed with claude code -- Adam]
        `exclude_endpoints` -- `(dpid, port)` sources whose link must not be used -- exists because
        this feeds `install_initial_routes`, and it used to search the whole graph including links
        the watchdog had already reported down. That is why calling the installer after a failure
        would have changed nothing: it recomputed the identical route, straight back into the dead
        link.

        Walks a snapshot, not the live graph, for the reason `push_destination_paths` does: this
        runs on a *gRPC receive thread*. `handle_packet_in` discovers a link, calls `add_link`, then
        calls `install_initial_routes` -- which lands here -- while the other switches' receive
        threads are calling `add_link` of their own. A concurrent insert during the traversal raises
        `RuntimeError: dictionary changed size during iteration`, and `_stream_receiver` only
        catches `grpc.RpcError`, so the exception escapes and that switch's receive thread is gone
        for the rest of the run.

        What made it worth fixing over any other race is how it fails. The dead thread stops
        delivering packet-ins, so every inbound link into that switch goes quiet at once while the
        switch keeps answering P4Runtime -- which is exactly the signature `reroutable_down_endpoints`
        forgives. The watchdog would decline to reroute and the twin would report stale state
        indefinitely, with nothing logged. The suppression built for a bmv2 measurement artefact was
        also, silently, hiding this.
        """
        paths_dict = {}

        # Copied under the lock, then released: the traversal below is pure CPU over a frozen
        # structure, and `install_initial_routes` follows it with up to 40 blocking gRPC writes
        # that must not be holding the graph lock while they wait.
        with self._net_lock:
            search = self.net.copy()

        nodes = list(search.nodes())
        drop = ryu_topology.down_edges(search, exclude_endpoints)
        if drop:
            search = nx.restricted_view(search, [], drop)

        for dst in nodes:
            paths_dict[dst] = {}
            for src in nodes:
                if src == dst:
                    continue
                try:
                    # BFS shortest path
                    path = nx.shortest_path(search, source=src, target=dst)
                    paths_dict[dst][src] = {
                        "path": path,
                        "length": len(path) - 1
                    }
                except nx.NetworkXNoPath:
                    pass
                    
        self.dest_paths = paths_dict
        return self.dest_paths

    def get_all_destination_paths_formatted(self):
        """Formats exactly like intelligent_router.py for NDTwin compatibility"""
        data = []
        for node, paths in self.dest_paths.items():
            if type(node) == str:
                formatted_node = node
            else:
                formatted_node = str(node)
                
            # format the keys of paths (the source nodes) to string if they are DPIDs
            formatted_paths = {}
            for src, path_info in paths.items():
                if type(src) == str:
                    formatted_src = src
                else:
                    formatted_src = str(src)
                formatted_paths[formatted_src] = path_info
                
            data.append({"node": formatted_node, "paths": formatted_paths})
        return data

    def route_flow(self, dpid, match_dict, actions_dict, priority=None):
        """
        Translates OpenFlow match/actions into P4 Client commands.
        Called when NDTwin POSTs to /stats/flowentry/add

        [Co-developed with claude code -- Adam]
        The body's `priority` and `idle_timeout` never reach here, and the source review of
        2026-08-17 settled why neither is a defect -- written down because "silently
        ignored" reads like one:

        `priority` is not expressible. ipv4_lpm is a single-key LPM table holding one entry
        per destination, and P4Runtime gives priority only to ternary and range matches; the
        prefix length is the entire tiebreak. delete_flow_entry's docstring depends on the
        same fact. The consequence is a real asymmetry worth knowing: under OVS a TE
        migration at priority 100 *layers over* the default rule at 10, while here it
        *replaces* the destination's only entry.

        `idle_timeout` has no producer. The kernel omits the field for 0 and -1
        (HttpRoutingStrategyBase.cpp:181), the TE app's live path sends no timeout key at all
        and its disabled path sends 0, and the OVS control plane never sets one either -- so
        nothing in this system asks for ageing in either fabric. Honouring it would mean
        annotating ipv4_lpm in ndtwin_switch.p4 (all ten tables compile with
        support_timeout: false), recompiling, re-pushing every pipeline, and handling
        P4Runtime IdleTimeoutNotification here, because P4Runtime notifies the controller
        rather than deleting the entry the way OpenFlow does.

        Either way a migration written through this method survives only until the next link
        transition: install_initial_routes rewrites every (switch, host) entry on any
        transition and on discovery. Anything built on top of "the rule stays until it ages
        out" needs that fact first.
        """
        if dpid not in self.switches:
            print(f"[TopologyManager] Switch {dpid} not found for routing!")
            return False
            
        client = self.switches[dpid]

        # [Co-developed with claude code -- Adam] Refuse what ipv4_lpm cannot express; see
        # UnsupportedMatchError above for what silently dropping these actually did.
        bad = unsupported_match_fields(match_dict)
        if bad:
            print(f"[TopologyManager] Refusing rule for DPID {dpid}: "
                  f"neither table can honour {bad}")
            raise UnsupportedMatchError(bad)

        # Parse match (OpenFlow JSON)
        # NDTwin sends: {"dl_type": 2048, "nw_dst": "10.0.0.1"}
        ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")

        # Parse actions
        # NDTwin sends: [{"type": "OUTPUT", "port": 1}]
        out_port = None
        for action in actions_dict:
            if action.get("type") == "OUTPUT":
                out_port = action.get("port")

        if out_port is None:
            print("[TopologyManager] No OUTPUT action found")
            return False

        # ---- the 5-tuple branch -----------------------------------------------------------
        # [Co-developed with claude code -- Adam]
        # A match naming anything beyond the destination goes to flow_5tuple, which sits in
        # front of ipv4_lpm and has real priority. Note this is NOT recorded in
        # _installed_routes: that map is keyed (dpid, ipv4_dst) and answers "which port does
        # this switch use for this destination", which a 5-tuple rule does not have a
        # single-valued answer to -- two rules can send the same destination different ways on
        # different L4 ports. Writing one in would make render_destination_paths confidently
        # wrong rather than silent, and silent is the honest state until the renderer grows a
        # notion of finer-grained rules.
        if needs_five_tuple(match_dict):
            keys = five_tuple_keys(match_dict)
            prio = p4_priority(priority)
            next_hop_mac = "00:00:00:00:00:00"
            if ipv4_dst and ipv4_dst in self.net.nodes:
                next_hop_mac = self.net.nodes[ipv4_dst].get("mac", "00:00:00:00:00:00")
            print(f"[TopologyManager] Pushing 5-tuple rule to DPID {dpid} "
                  f"prio={prio} keys={sorted(keys)} -> port {out_port}")
            return bool(client.insert_5tuple_rule(keys, prio, next_hop_mac, out_port))

        if not ipv4_dst:
            print("[TopologyManager] Unsupported match criteria (needs nw_dst)")
            return False
            
        # For a full implementation, we need to know the destination MAC if routing to a host.
        # NDTwin OF rules just output to a port. In P4 we require next_hop_mac.
        # Let's find the MAC from our topology if the destination is a host
        next_hop_mac = "00:00:00:00:00:00" # Default fallback
        if ipv4_dst in self.net.nodes:
            next_hop_mac = self.net.nodes[ipv4_dst].get("mac", "00:00:00:00:00:00")
            
        # Push rule via P4 client
        print(f"[TopologyManager] Pushing P4 rule to DPID {dpid}: {ipv4_dst}/32 -> Port {out_port} (MAC: {next_hop_mac})")
        # [Co-developed with claude code -- Adam]
        # Was `insert_ipv4_route(...)` followed by an unconditional `return True`, so the
        # REST layer answered {"status":"success"} even when the gRPC write was rejected or
        # the switch was unreachable. Return what actually happened.
        success = bool(client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port))
        if success:
            # [Co-developed with claude code -- Adam]
            # `_installed_routes` had exactly one writer before this: install_initial_routes.
            # Traffic-Engineering and Energy-Saving both reroute through this endpoint --
            # /stats/flowentry/add -- and every one of those rewrites was invisible to the map,
            # so render_destination_paths kept reporting the *old* hop the switch no longer had.
            # This is the same lie decision B (installed_routes existing at all) was written to
            # stop, walking back in through the REST door instead of the watchdog.
            with self._net_lock:
                self._installed_routes[(dpid, ipv4_dst)] = out_port
        return success

    def unroute_flow(self, dpid, match_dict, priority=None):
        if dpid not in self.switches:
            return False

        # [Co-developed with claude code -- Adam] As route_flow: a delete whose match names
        # fields we ignored would remove a broader rule than the caller asked to remove, which
        # is worse than refusing.
        bad = unsupported_match_fields(match_dict)
        if bad:
            print(f"[TopologyManager] Refusing delete for DPID {dpid}: "
                  f"neither table can honour {bad}")
            raise UnsupportedMatchError(bad)

        client = self.switches[dpid]
        ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")

        # [Co-developed with claude code -- Adam]
        # The priority is part of a ternary entry's identity, so a delete that omits it removes
        # nothing and reports success -- the same shape as the OVS-side defect where
        # modify_flow_entry ignored priority and edited someone else's rule. The caller must
        # send the priority it installed with; p4_priority maps both through the same shift, so
        # a delete matching the install's OpenFlow priority hits the same entry.
        if needs_five_tuple(match_dict):
            keys = five_tuple_keys(match_dict)
            prio = p4_priority(priority)
            print(f"[TopologyManager] Deleting 5-tuple rule on DPID {dpid} "
                  f"prio={prio} keys={sorted(keys)}")
            return bool(client.delete_5tuple_rule(keys, prio))

        if not ipv4_dst:
            return False
            
        # [Co-developed with claude code -- Adam] -- as above: report the real outcome.
        success = bool(client.delete_ipv4_route(ipv4_dst, 32))
        if success:
            # Withdraw the record along with the rule. Left in place, the twin would keep
            # advertising a route to a destination the switch no longer has one for at all --
            # worse than the stale-port case route_flow's write closes, because there is nothing
            # left on the switch for the packet to reach.
            with self._net_lock:
                self._installed_routes.pop((dpid, ipv4_dst), None)
        return success

    def modify_flow(self, dpid, match_dict, actions_dict, priority=None):
        if dpid not in self.switches:
            return False

        # [Co-developed with claude code -- Adam] As route_flow.
        bad = unsupported_match_fields(match_dict)
        if bad:
            print(f"[TopologyManager] Refusing modify for DPID {dpid}: "
                  f"neither table can honour {bad}")
            raise UnsupportedMatchError(bad)

        client = self.switches[dpid]
        ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")

        out_port = None
        for action in actions_dict:
            if action.get("type") == "OUTPUT":
                out_port = action.get("port")

        if out_port is None:
            return False

        # As unroute_flow: on a ternary table the priority identifies the entry. A modify with
        # the wrong one edits nothing and says it worked. [Co-developed with claude code -- Adam]
        if needs_five_tuple(match_dict):
            keys = five_tuple_keys(match_dict)
            prio = p4_priority(priority)
            next_hop_mac = "00:00:00:00:00:00"
            if ipv4_dst and ipv4_dst in self.net.nodes:
                next_hop_mac = self.net.nodes[ipv4_dst].get("mac", "00:00:00:00:00:00")
            return bool(client.modify_5tuple_rule(keys, prio, next_hop_mac, out_port))

        if not ipv4_dst:
            return False

        next_hop_mac = "00:00:00:00:00:00"
        if ipv4_dst in self.net.nodes:
            next_hop_mac = self.net.nodes[ipv4_dst].get("mac", "00:00:00:00:00:00")

        success = client.modify_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port)
        if success:
            # As route_flow: the port just changed, so the record has to move with it or a
            # renderer reading _installed_routes sends packets down the pre-modify hop.
            with self._net_lock:
                self._installed_routes[(dpid, ipv4_dst)] = out_port
        return success

# Developed in collaboration with Gemini 3.1 Pro.
    def install_initial_routes(self, only_dpid=None):
        """
        Installs routing rules in all switches for all hosts, avoiding links believed down.

        [Co-developed with claude code -- Adam]
        Called on discovery and, since failover, on a link transition. A destination that has no
        route at all once the failed links are excluded is simply not written: the switch keeps
        the rule it already has, so traffic for it continues into the dead link and starts working
        again by itself when the link returns. Deleting the rule instead would make the drop
        explicit at the switch, but it needs a reinstall on recovery, and the twin already reports
        the loss honestly -- `render_destination_paths` withdraws any path whose installed route
        is broken.

        `only_dpid` restricts the writes to one switch, for `readopt_switch`: a freshly
        restarted bmv2 has empty tables, and rewriting the other nine switches' rules along
        with it would be forty gRPC round trips to say what those switches already know.
        Returns `(accepted, attempted)`: accepted alone cannot distinguish "nothing was
        routable" (honest, the watchdog reinstalls later) from "the switch refused every
        write" (its tables stay empty and nothing schedules a refill) -- readopt needs the
        difference (live 2026-08-13).
        """
        self.calculate_all_paths(self.reroutable_down_endpoints())
        print("[TopologyManager] Installing initial routes proactively...")
        installed = 0
        attempted = 0
        for dst, src_paths in self.dest_paths.items():
            # We only care about routing TO hosts
            if self.net.nodes[dst].get('type') != 'host':
                continue

            ipv4_dst = dst
            next_hop_mac = self.net.nodes[dst].get("mac", "00:00:00:00:00:00")

            for src, path_info in src_paths.items():
                # We only need to install a rule on the switch if it's a switch
                if self.net.nodes[src].get('type') != 'switch':
                    continue
                if only_dpid is not None and src != only_dpid:
                    continue

                path = path_info['path']
                # The next node in the path
                next_node = path[path.index(src) + 1]
                # The port connecting src to next_node
                out_port = self.net.edges[src, next_node]['port']

                client = self.switches[src]
                print(f"[TopologyManager] Proactive Rule: DPID {src}: {ipv4_dst}/32 -> Port {out_port} (MAC: {next_hop_mac})")
                # [Co-developed with claude code -- Adam]
                # Record only what the switch accepted. The return value was discarded here, so a
                # failed write was indistinguishable from a successful one, and every consumer
                # went on being told the route existed.
                attempted += 1
                if client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port):
                    with self._net_lock:
                        self._installed_routes[(src, ipv4_dst)] = out_port
                    installed += 1
        return installed, attempted

    def installed_routes(self):
        """
        Snapshot of the rules actually written to the switches: (dpid, dst_ip) -> out_port.

        [Co-developed with claude code -- Adam]
        The honest answer to "where will a packet for this host go", as opposed to the answer
        `net` gives, which is "where would it go if the switches had been programmed with the
        current shortest path". Those two are the same thing only until the first link failure.
        """
        with self._net_lock:
            return dict(self._installed_routes)

    def readopt_switch(self, dpid, client_factory, sample_callback=None, settle_s=1.0):
        """
        Re-adopt one bmv2 switch after its process was restarted (Phase 7 powerOn).

        [Co-developed with claude code -- Adam]
        A restarted bmv2 comes back with nothing: no pipeline, no clone session, no table
        entries, and no P4Runtime mastership -- the old client's stream died with the old
        process and nothing re-establishes it. Meanwhile the liveness probe is a unary RPC on
        a channel gRPC quietly reconnects, and bmv2 answers COOKIE_ONLY without any pipeline
        loaded, so `p4LivenessFor` would certify the switch Up while it cannot forward a
        single packet. This method is what makes "powered on" true rather than merely
        reported: doc/2026-08-11_phase7_power_mechanism_design.md, decision 2.

        A *new* client rather than restarting the old one: stop() closes the channel, poisons
        the outbound queue with its None sentinel, and lets the receiver thread die -- every
        step of resurrecting that object is a trap, and a fresh client is the path `startup()`
        already proves works. The sequence mirrors startup()'s for one switch: callbacks are
        wired before start() so no packet-in arrives to a None callback, the pipeline settles
        for `settle_s` (bmv2 accepts arbitration before it finishes electing, and a config
        push in that window is rejected), and the clone session goes in only after the
        pipeline it lives in.

        Route counts of zero are possible and honest: right after a power-on the link
        watchdog may still believe this switch's links are down (its beacons have not resumed
        yet), and `install_initial_routes` excludes those links. The watchdog's recovery path
        re-installs routes when the beacons return; this call installs what is believed
        routable *now*.

        Returns a dict rather than raising, so the HTTP layer decides status codes:
          {"status": "success", "dpid": ..., "clone_session": bool, "routes_installed": int}
          {"status": "unknown-switch", ...} | {"status": "failed", "step": ..., "error": ...}
        """
        if dpid not in self.switches:
            return {"status": "unknown-switch", "dpid": dpid,
                    "detail": f"the proxy has no client for dpid {dpid}; readopt can only "
                              f"replace a connection that startup once established"}

        with self._readopt_lock:
            old = self.switches.get(dpid)

            try:
                new = client_factory(dpid)
            except Exception as e:  # noqa: BLE001 -- report, never take the handler down
                return {"status": "failed", "step": "build",
                        "error": f"{type(e).__name__}: {e}"}

            # Before start(): the receiver thread runs from the moment the stream opens, and
            # handle_packet_in drops packets whose callback is still None.
            new.packet_in_callback = self.handle_packet_in
            if sample_callback is not None:
                new.sample_callback = sample_callback

            try:
                new.start(push_config=False)
                time.sleep(settle_s)
                # [Co-developed with claude code -- Adam]
                # Destructive gate. SetForwardingPipelineConfig erases every table on the
                # switch, and a refused arbitration does not stop the switch from accepting
                # it: every client bids the same hardcoded election_id (0, 1), so against a
                # healthy switch this "new" client presents the incumbent's own credentials.
                # bmv2 kills the duplicate *stream* (leaving mastership_confirmed false) but
                # still honours the unary push, because P4Runtime identifies a unary sender by
                # the 3-tuple in the message, not by its connection.
                #
                # The route writes that would refill the tables are then refused with "Not
                # primary" -- but only because old.stop() below runs before
                # install_initial_routes, so by then no primary is left to impersonate. Not
                # because Write is checked more strictly than the push; measured, both are
                # accepted while the incumbent is still up.
                #
                # Unguarded, that sequence wiped the tables, installed nothing, and reported
                # success (live 2026-08-13, s1 and s6). If this stream did not become primary
                # inside the settle window there is nothing readopt can safely do; leave the
                # switch untouched and say why.
                # doc/2026-08-13_p4runtime-mastership-spec-check.md, scenarios 2 and 3.
                if not getattr(new, "mastership_confirmed", False):
                    try:
                        new.stop()
                    except Exception:  # noqa: BLE001 -- already reporting the first failure
                        pass
                    return {"status": "failed", "step": "mastership",
                            "error": "arbitration was not granted within the settle window; "
                                     "the old client (or another controller) likely still "
                                     "holds mastership. The switch was not touched."}
                new.set_forwarding_pipeline_config()
            except Exception as e:  # noqa: BLE001
                try:
                    new.stop()
                except Exception:  # noqa: BLE001 -- already reporting the first failure
                    pass
                # The old client stays in place: it is just as dead, but the liveness poller
                # keeps probing it, so the switch keeps reporting Down instead of vanishing.
                return {"status": "failed", "step": "pipeline",
                        "error": f"{type(e).__name__}: {e}"}

            # Same policy as startup(): a failed clone session costs telemetry, not the
            # switch. It forwards fine; it just reports zero traffic, and the caller is told.
            clone_ok = bool(new.write_clone_session()) if sample_callback is not None else True

            # The swap. switch_liveness reads self.switches under this lock; everything else
            # does single-key lookups, which the GIL keeps atomic.
            with self._liveness_lock:
                self.switches[dpid] = new

            if old is not None and old is not new:
                try:
                    old.stop()
                except Exception as e:  # noqa: BLE001
                    print(f"[TopologyManager] readopt {dpid}: old client refused to stop "
                          f"cleanly ({type(e).__name__}: {e}); continuing with the new one")

            routes, attempted = self.install_initial_routes(only_dpid=dpid)

        # [Co-developed with claude code -- Adam]
        # Zero installed is still honest when zero were *attempted* (the watchdog may hold
        # this switch's links down until its beacons resume; its recovery path reinstalls).
        # Zero installed out of several attempted means the switch refused every write after
        # accepting the pipeline: its tables are empty, nothing schedules a refill, and
        # calling that success is how a healthy switch went dark with a 200 (live
        # 2026-08-13).
        if attempted > 0 and routes == 0:
            return {"status": "failed", "step": "routes", "dpid": dpid,
                    "clone_session": clone_ok,
                    "error": f"the switch refused all {attempted} route writes after "
                             f"accepting the pipeline; its tables are empty until a proxy "
                             f"restart or a link-watchdog recovery reinstalls them"}

        print(f"[TopologyManager] readopt {dpid}: pipeline pushed, clone_session={clone_ok}, "
              f"{routes} of {attempted} routes installed")
        result = {"status": "success", "dpid": dpid, "clone_session": clone_ok,
                  "routes_installed": routes, "routes_attempted": attempted}

        # [Co-developed with claude code -- Adam]
        # Nothing was even attempted: this switch's links are still down, so no path in
        # dest_paths crosses it and there is nothing to write. The adoption did succeed --
        # mastership, pipeline and clone session are all in place -- but the tables are empty
        # for as long as rediscovery takes, and the caller is entitled to know that rather
        # than to read "success" as "forwarding".
        #
        # Measured live 2026-08-13: readopt returned in 2 s with attempted=0 and the switch
        # held no rules; the link-watchdog's recovery path installed all four about 30 s later.
        # Reporting it as a failure was the other option and is worse -- rediscovery genuinely
        # takes time, so every ordinary power-on would report failure, and a status nobody can
        # act on is one everybody learns to ignore.
        if attempted == 0:
            result["routes_pending"] = True
            result["note"] = ("adopted, but no route was installable yet: this switch's links "
                              "are still down, so no path crosses it. The link watchdog "
                              "installs them when the beacons resume.")
        return result

    # --- LLDP Discovery Logic ---
    def create_lldp_packet(self, dpid, port):
        dst_mac = bytes.fromhex("0180c200000e")
        src_mac = lldp_source_mac(dpid)
        ethertype = bytes.fromhex("88cc")
        payload = f"DPID:{dpid},PORT:{port}".encode('utf-8')
        return dst_mac + src_mac + ethertype + payload

    def lldp_ports_for(self, dpid):
        """
        The ports this switch should beacon on: its inter-switch links from the topology file.

        [Co-developed with claude code -- Adam]
        Was `range(1, 7)` for every switch. On this topology s1-s4 have three interfaces and s5-s10
        have four, so between two and three of every switch's beacons went to a port that does not
        exist -- and the two that do exist on s1-s4 are the only ones that could ever discover a
        link anyway, because port 3 faces a host.

        Falls back to the old range when the topology cannot be read, because beaconing on nothing
        means no discovery at all, but says so: a silent fallback here would look like a working
        topology-derived list.
        """
        ports = self._link_ports.get(dpid)
        if ports:
            return ports
        if not self._link_ports_warned:
            self._link_ports_warned = True
            print("[TopologyManager] no inter-switch ports in the topology file; beaconing on "
                  f"{LLDP_FALLBACK_PORTS[0]}..{LLDP_FALLBACK_PORTS[-1]} on every switch, which "
                  "sends to ports that may not exist")
        return LLDP_FALLBACK_PORTS

    def parse_lldp_packet(self, packet_bytes):
        if len(packet_bytes) < 14:
            return None
        ethertype = packet_bytes[12:14].hex()
        if ethertype != "88cc":
            return None
        try:
            payload = packet_bytes[14:].decode('utf-8')
            if payload.startswith("DPID:"):
                parts = payload.split(",")
                dpid = int(parts[0].split(":")[1])
                port = int(parts[1].split(":")[1])
                return dpid, port
        except:
            pass
        return None

    def handle_packet_in(self, device_id, ingress_port, payload):
        # [Co-developed with claude code -- Adam]
        # Recorded before anything else, and unconditionally. Every packet that arrives here is
        # proof that `device_id`'s stream and CPU port are working *right now*, and the beacon's own
        # DPID field is proof that switch is still forwarding -- which the gRPC probe cannot show,
        # because bmv2 answers control-plane RPCs whether or not its pipeline moves packets.
        #
        # Previously all of this evidence was thrown away: the only action taken was adding a link,
        # and the `if not edge_exists` guard below means that after the first beacon of each pair
        # every subsequent one did nothing at all. The topology converges in seconds and then
        # thousands of proofs-of-life per minute were discarded.
        now = self._clock()
        lldp_info = self.parse_lldp_packet(payload)
        with self._liveness_lock:
            self._last_packet_in[device_id] = now
            if lldp_info:
                self._last_lldp_from[lldp_info[0]] = now
                if lldp_info[0] != device_id:
                    # This beacon is proof that this exact link carried a frame just now, and the
                    # four values are exactly what /ndt/link_failure_detected wants. Recorded here
                    # and reported by the watchdog, never reported from here: this is the gRPC
                    # stream receive thread, and an HTTP call on it with a three-second timeout
                    # would stall packet-in for every switch behind this one.
                    # [Co-developed with claude code -- Adam]
                    link = (lldp_info[0], lldp_info[1], device_id, ingress_port)
                    entry = self._link_beacons.get(link)
                    if entry is None:
                        # acked=True: a link the kernel has never been told is down needs no telling
                        # that it is up.
                        #
                        # This comment used to credit inform_switch_entered with enabling the edges
                        # too. It does not: HttpSession::handleInformSwitchEntered calls
                        # setVertexUp and setVertexEnable on the switch vertex and nothing else.
                        # Switch-to-switch edges are enabled by the kernel's topology poll --
                        # updateLinks, keyed on (src dpid, src port), reading the Ryu-shaped
                        # /v1.0/topology/links this proxy serves. `enableSwitchAndEdges` does what
                        # the old comment described, but its only caller is IntentTranslator's
                        # ENABLE_SWITCH task branch.
                        #
                        # That poll is *not* 1 s, which this comment also used to say: see
                        # down_link_endpoints below for the interval and why the difference
                        # matters.
                        #
                        # Both claims above are unchanged and still true -- exactly those two
                        # flags, exactly one caller. What is gone is their line numbers
                        # (HttpSession.cpp:1080-1081 and IntentTranslator.cpp:227), which were
                        # exact when written and had drifted by two commits later. This comment
                        # exists to be the accurate correction of an earlier wrong one, so it is
                        # the last place that should carry a pointer with a shelf life.
                        #
                        # The conclusion survives the correction: the poll brings a newly discovered
                        # link up on its own. What the wrong reason hid is that the same poll also
                        # brings a *failed* link back up, which is why down_link_endpoints exists.
                        self._link_beacons[link] = {"at": now, "down": False, "acked": True,
                                                    "seen": True}
                    else:
                        entry["at"] = now
                        # A seeded link that has now spoken graduates to the steady-state timeout;
                        # without this it would keep the startup grace period for the whole run.
                        entry["seen"] = True

        if lldp_info:
            src_dpid, src_port = lldp_info

            # Avoid self-loops and ignore if edge already exists
            if src_dpid == device_id:
                return

            edge_exists = self.net.has_edge(src_dpid, device_id)
            if not edge_exists:
                print(f"[TopologyManager] Discovered link: S{src_dpid}-p{src_port} -> S{device_id}-p{ingress_port}")
                self.add_link(src_dpid, device_id, src_port, ingress_port)
                self.install_initial_routes()

    # --- Liveness. [Co-developed with claude code -- Adam]
    #
    # The kernel's pingWorker used to mark every bmv2 switch UP once a second with no evidence at
    # all, so a switch that had been killed reported healthy within one second and the twin could
    # never show a fault. `is_up` also gates power, CPU, temperature and getAvgLinkUsage, so one
    # fabricated field made several others meaningless.
    #
    # This side reports *facts* and leaves the verdict to the kernel, which applies a three-state
    # policy with its own thresholds (Up / Down / Unknown, where Unknown leaves the graph alone).
    # Deciding here would put the policy in the process that cannot be unit-tested against the
    # graph, and would hide the distinction that matters: "I asked and it said no" is not the same
    # as "I could not ask".

    def start_liveness_polling(self):
        """Starts the background prober. Idempotent."""
        if self._liveness_running:
            return
        self._liveness_running = True

        def _loop():
            while self._liveness_running:
                # Snapshot the dict: add_switch can insert while we iterate.
                for dpid, client in list(self.switches.items()):
                    if not self._liveness_running:
                        break
                    try:
                        result = client.probe(timeout_s=LIVENESS_PROBE_TIMEOUT_S)
                    except Exception as e:  # noqa: BLE001
                        # A probe that raises must not kill the poller, or every switch freezes at
                        # its last known state and the kernel is told stale facts forever.
                        result = {"ok": False, "detail": f"probe raised {type(e).__name__}: {e}"}
                    with self._liveness_lock:
                        self._last_probe[dpid] = {
                            "ok": bool(result.get("ok")),
                            "detail": str(result.get("detail", "")),
                            "at": time.monotonic(),
                        }
                if self._liveness_stop.wait(LIVENESS_PROBE_INTERVAL_S):
                    break

        self._liveness_stop.clear()
        self._liveness_thread = threading.Thread(target=_loop, daemon=True, name="liveness-probe")
        self._liveness_thread.start()

    def stop_liveness_polling(self, timeout=2.0):
        """
        Stops the prober and waits for it.

        [Co-developed with claude code -- Adam]
        The flag alone left the thread inside `time.sleep`, so shutdown continued and tore down the
        P4RuntimeClients this loop was about to probe. Joining it is what makes the three background
        loops actually symmetric, rather than symmetric-looking.
        """
        self._liveness_running = False
        self._liveness_stop.set()
        thread, self._liveness_thread = self._liveness_thread, None
        if thread is not None and thread.is_alive():
            thread.join(timeout)

    def connected_switch_dpids(self):
        """
        The switches this proxy currently holds a working session with, for
        `GET /v1.0/topology/switches`.

        [Co-developed with claude code -- Adam]
        `self.switches` is not that set. It is every client `startup` ever built, and killing a
        switch's process does not remove its entry -- so serving its keys made that endpoint
        claim a dead switch was connected while `/p4/switch_state`, from this same object at the
        same moment, reported `probe_ok: false` and `stream_alive: false`. Two endpoints of one
        process disagreeing, and the kernel believes this one: `updateSwitches` sets
        `isUp = true` unconditionally for every dpid listed here, so the twin announced a
        powered-off bmv2 as alive once per topology poll until the 1 Hz liveness worker corrected
        it a second later. Measured 2026-08-12 at 10 Hz: an up-blip every poll, tracking the
        poll's own 5s-then-30s cadence exactly.

        Only a definite `False` excludes a switch. A probe that has never completed leaves `ok`
        absent, and that is *not* evidence of death -- reporting it as disconnected would black
        out the whole fabric for the first seconds of every run. It is the same three-state rule
        the kernel's own `p4LivenessFor` applies, kept the same on purpose so the two processes
        cannot disagree about what "no reading" means.

        Staleness is deliberately not re-checked here. If the prober stalls, the last verdict
        stands; a stale `False` keeps a switch out of this list, which only withholds the claim
        that it is up, and withholding a claim is the safe direction for an endpoint whose sole
        consumer turns membership into liveness.
        """
        with self._liveness_lock:
            return [dpid for dpid in sorted(self.switches)
                    if (self._last_probe.get(dpid) or {}).get("ok") is not False]

    def switch_liveness(self):
        """
        The evidence for each switch the proxy knows about, for `GET /p4/switch_state`.

        Ages are seconds since the event, or None when it has never happened -- which is why they
        are ages rather than timestamps: the reader has no way to align its own monotonic clock with
        this process's, and "never" has to be representable as something other than "very old".

        `probe_ok` is None when no probe has completed yet, so the kernel can tell startup from a
        failure. Reporting a not-yet-probed switch as down would mark the whole fabric dead for the
        first two seconds of every run.
        """
        now = time.monotonic()

        def age(then):
            return None if then is None else round(now - then, 3)

        with self._liveness_lock:
            dpids = sorted(set(self.switches) | set(self._last_probe) | set(self._last_lldp_from))
            out = {}
            for dpid in dpids:
                probe = self._last_probe.get(dpid)
                client = self.switches.get(dpid)
                out[str(dpid)] = {
                    "probe_ok": None if probe is None else probe["ok"],
                    "probe_detail": "" if probe is None else probe["detail"],
                    "probe_age_s": None if probe is None else age(probe["at"]),
                    "last_packet_in_age_s": age(self._last_packet_in.get(dpid)),
                    "last_lldp_age_s": age(self._last_lldp_from.get(dpid)),
                    "stream_alive": bool(client.stream_alive) if client is not None else False,
                    "grpc_addr": getattr(client, "grpc_addr", None),
                }

        return {
            "status": "success",
            "probe_interval_s": LIVENESS_PROBE_INTERVAL_S,
            "switches": out,
            # Additive, and the kernel reads only "switches" (DeviceConfigurationAndPowerManager
            # looks that key up by name), so this cannot change how it parses the reply. It is here
            # so the link watchdog's state can be seen without waiting for a POST to arrive at the
            # kernel. [Co-developed with claude code -- Adam]
            "links": self.link_liveness(),
        }

    def start_lldp_discovery(self):
        """
        Starts the beacon sender. Idempotent; stop it with stop_lldp_discovery().

        [Co-developed with claude code -- Adam]
        The thread used to be `while True:` with its handle assigned to a local that was
        immediately discarded, so there was no way to stop it and no way to reach it. main.py's
        shutdown handler stopped the liveness poller and then tore down every P4RuntimeClient
        underneath this loop, which kept calling send_packet_out on them.
        """
        if self._lldp_running:
            return
        self._lldp_running = True
        self._lldp_stop.clear()

        def _loop():
            while self._lldp_running:
                # list() so a switch registering mid-pass cannot raise "changed size during
                # iteration" in here. [Co-developed with claude code -- Adam]
                for dpid, client in list(self.switches.items()):
                    for port in self.lldp_ports_for(dpid):
                        pkt = self.create_lldp_packet(dpid, port)
                        client.send_packet_out(port, pkt)
                # Beacon first, then wait: a stop during the wait breaks out immediately instead of
                # after a full interval.
                if self._lldp_stop.wait(LLDP_BEACON_INTERVAL_S):
                    break

        self._lldp_thread = threading.Thread(target=_loop, daemon=True, name="lldp-beacon")
        self._lldp_thread.start()

    def stop_lldp_discovery(self, timeout=2.0):
        """Stops the beacon sender and waits for it, so no beacon can outlive the clients."""
        self._lldp_running = False
        self._lldp_stop.set()
        thread, self._lldp_thread = self._lldp_thread, None
        if thread is not None and thread.is_alive():
            thread.join(timeout)

    # --- Link failure detection. [Co-developed with claude code -- Adam]
    #
    # The other half of LLDP. Beacons arriving is how a link is discovered; beacons *stopping* is how
    # a link failure is detected, and only the first half was ever wired up -- KernelNotifier had
    # working link_failure/link_recovery methods that nothing called, so a link that went down stayed
    # up in the twin for the rest of the run. Ryu's side has done this all along
    # (intelligent_router.py's on_link_delete), which is what made the P4 path quietly worse rather
    # than visibly incomplete.
    #
    # Evidence lives on the receive thread, decisions live here, and reporting lives on this
    # thread rather than the receive thread: an HTTP POST with a three-second timeout on the gRPC
    # stream thread would stall packet-in for every switch behind it.

    def seed_expected_links(self, path=None):
        """
        Enter every link the topology file declares, so one that was already down when the proxy
        started can be reported rather than presumed up.

        [Co-developed with claude code -- Adam]
        ✅ **The receive-side assumption below was verified live on 2026-08-10** (10 bmv2 switches).
        Two independent checks, both clean:
          - Static: every one of the 32 declared switch-to-switch directions matches the wiring in
            p4_testbed_topo.py combined with bmv2's own `-i <port>@<iface>` mapping, which is the
            identity (port N == sX-ethN) on all ten switches.
          - Live: all 16 `Discovered link: S<a>-p<x> -> S<b>-p<y>` lines the proxy logged carry an
            ingress port equal to the topology file's `dst_interface`. Zero contradictions. (Only
            16 appear because add_link builds both directions from one beacon, so the reverse never
            logs as newly discovered.)
        So enabling this no longer risks reporting the whole fabric down, and main.py now passes
        seed_expected=True. The parameter still defaults to False so that a caller which has not
        thought about startup behaviour does not acquire it by accident.

        The assumption the verification above was about: that the topology file's
        `src_interface`/`dst_interface` numbers are the numbers bmv2 uses for those ports. If that
        were false, every seeded link would time out while the real beacons created separate
        entries, and the twin would report the whole fabric failed. It holds on this topology; a
        differently-wired one has to be checked again, since nothing enforces it.

        Returns the number of links seeded -- 0 means the topology file gave us nothing, which the
        caller must treat as a failure to seed, not as a fabric with no links.
        """
        links = load_switch_links(path)
        now = self._clock()
        with self._liveness_lock:
            for link in links:
                if link not in self._link_beacons:
                    self._link_beacons[link] = {"at": now, "down": False, "acked": True,
                                                "seen": False}
        return len(links)

    def _link_timeout(self, entry):
        """How long this link may stay silent. Longer if it has never spoken; see the constants."""
        return LINK_BEACON_TIMEOUT_S if entry.get("seen", True) else LINK_STARTUP_GRACE_S

    def check_link_beacons(self, now=None):
        """
        One watchdog pass: report links that have gone quiet, and links whose beacons have returned.

        Split from the thread so it can be driven directly with an injected clock. A test for a
        fifteen-second timeout that actually waits fifteen seconds does not get run.

        Reports are retried until the kernel accepts one. A kernel that is restarting would
        otherwise cost us the notification permanently, and the symptom -- a failed link shown as
        up for the rest of the run -- is indistinguishable from the bug this whole method fixes.

        Returns {"down": [...], "up": [...], "unacked": [...]}: links reported failed in this pass,
        links reported recovered, and links whose report the kernel did not accept and which will be
        retried on the next pass. With no notifier the first two still list the transitions, so the
        bookkeeping is observable without a kernel.
        """
        now = self._clock() if now is None else now

        with self._liveness_lock:
            for entry in self._link_beacons.values():
                down = (now - entry["at"]) > self._link_timeout(entry)
                if down != entry["down"]:
                    entry["down"] = down
                    # The kernel has not been told this yet, whatever it was told before.
                    entry["acked"] = False
            # Snapshot what still needs telling and drop the lock before any HTTP happens: holding
            # it across a three-second timeout would block the receive thread recording beacons,
            # which is how a slow kernel would manufacture the link failures it is being told about.
            unacked = [(link, entry["down"]) for link, entry in self._link_beacons.items()
                       if not entry["acked"]]

        reported_down, reported_up, still_unacked = [], [], []
        for link, down in unacked:
            if self._notify_link(link, down):
                with self._liveness_lock:
                    entry = self._link_beacons.get(link)
                    # Only acknowledge the belief we actually reported.
                    #
                    # Currently unreachable, and the comment here used to claim otherwise: "a beacon
                    # can arrive while the POST is in flight, flipping `down` back". It cannot. A
                    # beacon only refreshes `at`; the belief is flipped in the loop above and
                    # nowhere else, and there is one watchdog thread, so `entry["down"]` cannot
                    # differ from `down` by the time the report returns. A mutation removing this
                    # comparison survived all 34 tests for exactly that reason.
                    #
                    # Kept, because the moment a second reporter exists -- a retry worker, a
                    # second watchdog, an HTTP handler that forces a re-report -- acknowledging a
                    # belief someone else has already replaced would leave the kernel holding
                    # "down" with nothing remaining to correct it. Cheap, and the failure it
                    # prevents is silent and permanent.
                    if entry is not None and entry["down"] == down:
                        entry["acked"] = True
                (reported_down if down else reported_up).append(link)
            else:
                still_unacked.append(link)

        return {"down": reported_down, "up": reported_up, "unacked": still_unacked}

    def _notify_link(self, link, down):
        """Tell the kernel about one link transition. True when it accepted it, or when there is no
        kernel to tell -- bookkeeping-only mode must not accumulate an unacked backlog forever."""
        if self._kernel is None:
            return True
        src_dpid, src_port, dst_dpid, dst_port = link
        report = self._kernel.link_failure if down else self._kernel.link_recovery
        try:
            return bool(report(src_dpid, src_port, dst_dpid, dst_port))
        except Exception as e:  # noqa: BLE001 -- KernelNotifier promises not to raise; do not rely
            print(f"[TopologyManager] link report raised {type(e).__name__}: {e}")
            return False

    def start_link_watchdog(self, seed_expected=False, path=None):
        """Starts the beacon-timeout watchdog. Idempotent. See seed_expected_links for the flag."""
        if seed_expected:
            seeded = self.seed_expected_links(path)
            if seeded:
                print(f"[TopologyManager] link watchdog seeded with {seeded} declared links")
            else:
                # Seeding is the only reason the watchdog knows about a link that has been down
                # since before we started, so seeding nothing means that whole capability is off
                # again -- silently, and at exactly the moment an operator believes it is on.
                # load_switch_links prints when the file cannot be read, but says nothing when the
                # file parses and simply yields no switch-to-switch edges, which a schema change
                # would do.
                print("[TopologyManager] WARNING: seeding was requested but the topology file "
                      "declared no switch-to-switch links. Links already down at startup will "
                      "NOT be reported; only links that beacon at least once are watched.")
        if self._link_watchdog_running:
            return
        self._link_watchdog_running = True
        self._link_watchdog_stop.clear()

        def _loop():
            # Waits first: at startup nothing has been discovered yet, so an immediate pass has
            # nothing to say.
            while not self._link_watchdog_stop.wait(LINK_WATCHDOG_INTERVAL_S):
                if not self._link_watchdog_running:
                    break
                self.run_watchdog_pass()

        self._link_watchdog_thread = threading.Thread(target=_loop, daemon=True, name="link-watchdog")
        self._link_watchdog_thread.start()

    def stop_link_watchdog(self, timeout=2.0):
        self._link_watchdog_running = False
        self._link_watchdog_stop.set()
        thread, self._link_watchdog_thread = self._link_watchdog_thread, None
        if thread is not None and thread.is_alive():
            thread.join(timeout)

    def run_watchdog_pass(self):
        """
        One full watchdog iteration: check beacons, log the transitions, push fresh paths if any.

        [Co-developed with claude code -- Adam]
        Split out of the thread for the same reason `check_link_beacons` was: what the thread does
        *with* the result is behaviour, and behaviour that only exists inside a `while` loop with a
        five-second wait in it does not get tested. It was not, and a mutation proved it -- deleting
        the push call left all 48 tests green, because every test called `push_destination_paths`
        directly and nothing asserted the loop calls it.

        Returns the `check_link_beacons` result, or None when the pass raised.
        """
        try:
            result = self.check_link_beacons()
        except Exception as e:  # noqa: BLE001
            # A pass that raises must not kill the watchdog, or link failures stop being reported
            # with no signal that they have.
            print(f"[TopologyManager] link watchdog pass failed: {type(e).__name__}: {e}")
            return None
        for link in result["down"]:
            print(f"[TopologyManager] link down (no beacon for {LINK_BEACON_TIMEOUT_S}s): {link}")
        for link in result["up"]:
            print(f"[TopologyManager] link back up: {link}")
        if result["down"] or result["up"]:
            # [Co-developed with claude code -- Adam]
            # Reprogram first, announce second. The push advertises the routes that are installed,
            # so pushing first would publish a snapshot that is honest but already out of date, and
            # the corrected one would not arrive until the next transition. Installing is
            # idempotent -- insert_ipv4_route falls back to MODIFY -- so a pass whose links did not
            # actually move rewrites the same rules rather than doing damage.
            try:
                self.install_initial_routes()
            except Exception as e:  # noqa: BLE001
                # A failed reinstall must not cost the kernel its failure notification, which is
                # the part that worked before failover existed.
                print(f"[TopologyManager] reroute after transition failed: {type(e).__name__}: {e}")
            self.push_destination_paths()
        return result

    def push_destination_paths(self):
        """
        Recompute host-to-host paths and push them to the kernel. Returns True when it accepted them.

        [Co-developed with claude code -- Adam]
        Called on a link transition, not on a timer: the kernel's own
        `refreshDestinationPathsPeriodically` already pulls this every 60 s once loaded, so the only
        thing missing was latency. Without the push, `get_path_switch_count` answers from routes over
        a dead link for up to a minute after the watchdog reports it.

        The failed links are excluded from the search here for the same reason they are excluded from
        the pull -- pushing paths that traverse the link we just reported as down would contradict the
        report in the same breath.
        """
        if self._kernel is None:
            return False
        try:
            # Snapshot inside the lock, compute outside it. The search walks every host pair, and
            # holding the graph lock across that would block the LLDP receive threads that feed it.
            # The copy is cheap here for a reason worth stating: this proxy serves the P4 topology
            # (10 switches, 4 hosts), so the walk is 12 ordered host pairs over a 14-node graph --
            # not the 128-host OVS fabric, which this side never sees.
            with self._net_lock:
                snapshot = self.net.copy()
            # Deliberately after the graph lock is released: `down_link_endpoints` takes
            # `_liveness_lock`, and holding both at once would fix an order that nothing else here
            # promises to respect.
            down = self.down_link_endpoints()
            body = ryu_topology.render_destination_paths(snapshot, down, self.installed_routes())
            return bool(self._kernel.all_destination_paths(body["all_destination_paths"]))
        except Exception as e:  # noqa: BLE001 -- must not kill the watchdog thread
            print(f"[TopologyManager] destination-path push failed: {type(e).__name__}: {e}")
            return False

    def down_link_endpoints(self):
        """
        `(dpid, port)` for every link direction the watchdog believes is down.

        [Co-developed with claude code -- Adam]
        Exists because reporting a link failure is not enough on its own. `updateLinks` on the kernel
        side only ever sets `isUp`/`isEnabled` to **true** -- it has no path that sets either false --
        and it runs on a topology poll keyed on (src dpid, src port). This side never forgets a
        link either: `add_link` has no counterpart, so a link discovered once is reported forever.
        So the sequence was: watchdog reports the failure, the kernel takes the edge down, and the
        next poll puts it straight back up because the proxy was still listing it.
        The failure report was real, its effect did not outlive one poll, and nothing anywhere said so.

        The poll interval is 5 s for the kernel process's first 90 s and 30 s thereafter --
        `kWhileConverging`, `kOnceConverged` and `kConvergingFor` in `TopologyAndFlowMonitor.cpp`'s
        `run()`. This comment used to say 1 s, which was a misreading of the 1 s sleep slice in the
        same loop; that slice exists so `stop()` need not wait out a whole interval. The defect is
        unchanged; only the size of the window is.

        The correction had been made here and nowhere else: `api_routes.topology_links`,
        `ryu_topology.render_links` and this class's own `handle_packet_in` all still asserted the
        1 s figure -- the three places that actually serve or feed the endpoint. Fixed 2026-08-12.
        If you change this number again, grep the package for "topology poll" before you stop.

        Filtering the topology reply is the fix that works with the kernel as it stands, rather than
        against it: an edge the poll never mentions keeps whatever state it was last given. Keyed on
        the source endpoint because that is the key the kernel enables on -- both directions are
        tracked separately, so a one-way failure removes one direction and leaves the other.

        Fifth instance of "should replace, can only add" on this project, and the first one I shipped
        myself: the two halves each only added, so together they could never take anything away.
        """
        with self._liveness_lock:
            down = set()
            for (src, src_port, dst, dst_port), entry in self._link_beacons.items():
                if not entry["down"]:
                    continue
                down.add((src, src_port))

                # The far end of the same physical link, withheld too unless its own direction has
                # live evidence. `add_link` creates *both* directions from a single beacon, so the
                # reverse edge often exists as an inference rather than an observation -- and an
                # inferred direction can never be reported down, because no beacon tuple for it was
                # ever created to time out. Left in, it keeps half the edge lit on a link that is
                # wholly dead: exactly the case where the far switch died, so its beacons never
                # arrived anywhere to be missed.
                #
                # A reverse direction that is genuinely still passing beacons stays reported. That
                # is the one-way failure, and telling the kernel less than we know about it would be
                # its own error.
                reverse = self._link_beacons.get((dst, dst_port, src, src_port))
                if reverse is None or reverse["down"]:
                    down.add((dst, dst_port))
            return down

    def link_liveness(self):
        """
        Per-link beacon evidence, for `GET /p4/switch_state`. Ages, not timestamps, for the same
        reason switch_liveness reports ages. [Co-developed with claude code -- Adam]
        """
        now = self._clock()
        with self._liveness_lock:
            return {
                f"{s}:{sp}->{d}:{dp}": {
                    "last_beacon_age_s": None if not e.get("seen", True) else round(now - e["at"], 3),
                    "down": e["down"],
                    "reported_to_kernel": e["acked"],
                }
                for (s, sp, d, dp), e in sorted(self._link_beacons.items())
            }
