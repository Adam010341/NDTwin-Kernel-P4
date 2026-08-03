import json
import os
import threading
import time

import networkx as nx

# Shared so the two loaders cannot disagree about which topology file is authoritative.
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
class UnsupportedMatchError(ValueError):
    """Raised when a match asks for something ipv4_lpm cannot express."""

    def __init__(self, fields):
        self.fields = sorted(fields)
        super().__init__(
            "ipv4_lpm keys on the destination address only; cannot honour: "
            + ", ".join(self.fields)
        )


#: The only match fields the table actually keys on.
HONOURED_MATCH_FIELDS = frozenset({"nw_dst", "ipv4_dst"})

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
    bad = []
    for field, value in (match_dict or {}).items():
        if field in HONOURED_MATCH_FIELDS:
            continue
        if field in ETH_TYPE_FIELDS:
            try:
                if int(value) != IPV4_ETH_TYPE:
                    bad.append(field)
            except (TypeError, ValueError):
                bad.append(field)
            continue
        bad.append(field)
    return sorted(bad)


#: How often each switch broadcasts an LLDP beacon on its inter-switch ports.
#: The kernel's liveness policy allows one missed round (kLldpFreshSeconds = 12 s), so changing this
#: means changing that. [Co-developed with claude code -- Adam]
LLDP_BEACON_INTERVAL_S = 5

#: Used only when the topology file cannot be read. The previous unconditional behaviour, kept as a
#: fallback so discovery still works, but reported rather than silent.
LLDP_FALLBACK_PORTS = tuple(range(1, 7))

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


def load_switch_link_ports(path=None):
    """
    dpid -> sorted tuple of ports that face another switch, from the topology JSON the kernel loads.

    [Co-developed with claude code -- Adam]
    Host-facing ports are excluded: a beacon sent at a host is answered by nothing and, before the
    source MAC was fixed, actively poisoned learning with a host's own address.

    Reads the kernel's own file, and honours NDTWIN_TOPO_FILE, for the same reason
    load_switch_agent_ips does -- the two must not disagree about the topology. Returns {} when it
    cannot be read, and the caller falls back loudly.
    """
    path = path or os.environ.get("NDTWIN_TOPO_FILE") or DEFAULT_TOPO_FILE
    try:
        with open(path) as fh:
            topology = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"[TopologyManager] could not read topology {path}: {e}")
        return {}

    switch_dpids = {
        node.get("dpid")
        for node in topology.get("nodes", [])
        if node.get("vertex_type") == 0 and node.get("dpid")
    }
    ports = {}
    for edge in topology.get("edges", []):
        src, dst = edge.get("src_dpid"), edge.get("dst_dpid")
        # `src_interface`, not `src_port` -- the field is named for the physical interface.
        port = edge.get("src_interface")
        if src in switch_dpids and dst in switch_dpids and src and dst and port:
            ports.setdefault(src, set()).add(int(port))
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
    def __init__(self):
        self.net = nx.DiGraph()
        self.switches = {} # dpid -> P4RuntimeClient
        self.dest_paths = {} # To match Ryu's format

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

        self._liveness_thread = None
        self._liveness_running = False

        #: dpid -> ports facing another switch, read once from the topology file. See
        #: load_switch_link_ports. [Co-developed with claude code -- Adam]
        self._link_ports = load_switch_link_ports()
        self._link_ports_warned = False

    def add_switch(self, dpid, client):
        if dpid not in self.switches:
            self.switches[dpid] = client
            self.net.add_node(dpid, type='switch')
            client.packet_in_callback = self.handle_packet_in

    def add_link(self, src_dpid, dst_dpid, src_port, dst_port):
        self.net.add_edge(src_dpid, dst_dpid, port=src_port)
        self.net.add_edge(dst_dpid, src_dpid, port=dst_port)

    def add_host(self, ip, mac, switch_dpid, port):
        self.net.add_node(ip, type='host', mac=mac)
        self.net.add_edge(switch_dpid, ip, port=port)
        self.net.add_edge(ip, switch_dpid, port=0)

    def calculate_all_paths(self):
        """Calculates all-pairs shortest paths using BFS"""
        paths_dict = {}
        nodes = self.net.nodes()
        
        for dst in nodes:
            paths_dict[dst] = {}
            for src in nodes:
                if src == dst:
                    continue
                try:
                    # BFS shortest path
                    path = nx.shortest_path(self.net, source=src, target=dst)
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

    def route_flow(self, dpid, match_dict, actions_dict):
        """
        Translates OpenFlow match/actions into P4 Client commands.
        Called when NDTwin POSTs to /stats/flowentry/add
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
                  f"ipv4_lpm cannot honour {bad}")
            raise UnsupportedMatchError(bad)

        # Parse match (OpenFlow JSON)
        # NDTwin sends: {"dl_type": 2048, "nw_dst": "10.0.0.1"}
        ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")
        if not ipv4_dst:
            print("[TopologyManager] Unsupported match criteria (needs nw_dst)")
            return False
            
        # Parse actions
        # NDTwin sends: [{"type": "OUTPUT", "port": 1}]
        out_port = None
        for action in actions_dict:
            if action.get("type") == "OUTPUT":
                out_port = action.get("port")
                
        if out_port is None:
            print("[TopologyManager] No OUTPUT action found")
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
        return bool(client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port))

    def unroute_flow(self, dpid, match_dict):
        if dpid not in self.switches:
            return False

        # [Co-developed with claude code -- Adam] As route_flow: a delete whose match names
        # fields we ignored would remove a broader rule than the caller asked to remove, which
        # is worse than refusing.
        bad = unsupported_match_fields(match_dict)
        if bad:
            print(f"[TopologyManager] Refusing delete for DPID {dpid}: "
                  f"ipv4_lpm cannot honour {bad}")
            raise UnsupportedMatchError(bad)

        client = self.switches[dpid]
        ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")
        if not ipv4_dst:
            return False
            
        # [Co-developed with claude code -- Adam] -- as above: report the real outcome.
        return bool(client.delete_ipv4_route(ipv4_dst, 32))

    def modify_flow(self, dpid, match_dict, actions_dict):
        if dpid not in self.switches:
            return False

        # [Co-developed with claude code -- Adam] As route_flow.
        bad = unsupported_match_fields(match_dict)
        if bad:
            print(f"[TopologyManager] Refusing modify for DPID {dpid}: "
                  f"ipv4_lpm cannot honour {bad}")
            raise UnsupportedMatchError(bad)

        client = self.switches[dpid]
        ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")
        if not ipv4_dst:
            return False
            
        out_port = None
        for action in actions_dict:
            if action.get("type") == "OUTPUT":
                out_port = action.get("port")
                
        if out_port is None:
            return False
            
        next_hop_mac = "00:00:00:00:00:00"
        if ipv4_dst in self.net.nodes:
            next_hop_mac = self.net.nodes[ipv4_dst].get("mac", "00:00:00:00:00:00")
            
        return client.modify_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port)

# Developed in collaboration with Gemini 3.1 Pro.
    def install_initial_routes(self):
        """Proactively installs routing rules in all switches for all hosts."""
        self.calculate_all_paths()
        print("[TopologyManager] Installing initial routes proactively...")
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
                
                path = path_info['path']
                # The next node in the path
                next_node = path[path.index(src) + 1]
                # The port connecting src to next_node
                out_port = self.net.edges[src, next_node]['port']
                
                client = self.switches[src]
                print(f"[TopologyManager] Proactive Rule: DPID {src}: {ipv4_dst}/32 -> Port {out_port} (MAC: {next_hop_mac})")
                client.insert_ipv4_route(ipv4_dst, 32, next_hop_mac, out_port)

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
        now = time.monotonic()
        lldp_info = self.parse_lldp_packet(payload)
        with self._liveness_lock:
            self._last_packet_in[device_id] = now
            if lldp_info:
                self._last_lldp_from[lldp_info[0]] = now

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
                time.sleep(LIVENESS_PROBE_INTERVAL_S)

        self._liveness_thread = threading.Thread(target=_loop, daemon=True)
        self._liveness_thread.start()

    def stop_liveness_polling(self):
        self._liveness_running = False

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
        }

    def start_lldp_discovery(self):
        def _loop():
            while True:
                # list() so a switch registering mid-pass cannot raise "changed size during
                # iteration" in here. [Co-developed with claude code -- Adam]
                for dpid, client in list(self.switches.items()):
                    for port in self.lldp_ports_for(dpid):
                        pkt = self.create_lldp_packet(dpid, port)
                        client.send_packet_out(port, pkt)
                time.sleep(LLDP_BEACON_INTERVAL_S)
        t = threading.Thread(target=_loop, daemon=True)
        t.start()
