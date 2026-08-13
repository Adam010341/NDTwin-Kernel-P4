from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER, DEAD_DISPATCHER
from ryu.controller.handler import set_ev_cls
from ryu.ofproto import ofproto_v1_3
from ryu.topology import event, switches
from ryu.topology.api import get_switch, get_link
from ryu.lib.packet import packet, ethernet, ipv4, ether_types, arp, tcp, udp, icmp
import networkx as nx
from ryu.controller import dpset
import requests
import json
from ryu.app.wsgi import ControllerBase, WSGIApplication, route
from webob import Response
from time import time
import ipaddress
import hashlib
from pathlib import Path
import threading
import random
from ryu.lib import hub

# TODO: Change it
# (1) Static topology JSON path (update to your local file path)
static_topology_file_path = Path("/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json")

# (2) Deployment mode
# [Co-developed with claude code -- Adam]
# ⚠️ EDITING THIS LINE DOES NOTHING. `is_mininet` is unconditionally reassigned to True further
# down in this same module-level block (search for the second `is_mininet = True`), so whatever
# you set here is overwritten before anything reads it. It reads as configuration and behaves as a
# constant.
#
# What it would control if it worked: exactly one thing, `if is_mininet: hub.sleep(60)` at the end
# of `load_static_topology` -- a settle delay before the all-destination route walk. A
# physical-testbed operator who flips this line still waits the 60 s.
#
# Both assignments date to the original import (6f32bca) and neither carries a reason, so the
# override was left in place rather than deleted: making the knob live would change startup timing
# for a testbed deployment, and nothing here records whether the second assignment was a deliberate
# "always settle" or an editing accident. To actually change the behaviour today, edit the second
# assignment or the `if is_mininet:` guard, and decide the question this comment cannot.
is_mininet = True   # True: Mininet, False: physical testbed -- SEE ABOVE, this value is discarded

RYU_SERVER_INSTANCE_NAME = "ndt_ryu_app"
switch_num = 10
detecting_time = 60

# [Co-developed with claude code -- Adam]
# How long the topology must be quiet before routes are recomputed. One `link a b down` raises an
# EventLinkDelete per direction, and a switch joining raises a burst, so recomputing on each event
# would repeat the whole 16256-pair walk several times for one operator action. 3s is well past the
# gap between the paired events while still recovering promptly.
reinstall_quiet_period = 3

# [Co-developed with claude code -- Adam]
# How long the reinstall worker will wait for the *initial* install before recomputing anyway. The
# initial walk is ~60s on the 128-host topology and is preceded by a 60s settle sleep in Mininet
# mode, so this has to clear both with room to spare. On expiry it proceeds rather than giving up:
# an initial install that late has probably thrown, and then there are no routes at all.
initial_install_wait_limit = 240
is_all_dst_biased = False
all_dst_ecmp_biased_factor = 1

# [Co-developed with claude code -- Adam]
# THIS is the assignment that wins -- it silently overrides the documented "(2) Deployment mode"
# knob above. Left in place deliberately (removing it would change startup timing for a
# physical-testbed deployment, and neither assignment records why there are two), but no longer
# unlabelled. If you are making the knob real, delete this line; see the comment on the first
# assignment for what that changes.
is_mininet = True


def normalize_sort_key(v):
    if isinstance(v, str) and "." in v:
        try:
            return (1, ipaddress.IPv4Address(v))  # host IP
        except:
            return (2, v)  # fallback for weird strings
    elif isinstance(v, int):
        return (0, v)  # switch ID
    else:
        return (2, str(v))  # other types as string fallback


class IntelligentRyu(app_manager.RyuApp):
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]
    _CONTEXTS = {
        "dpset": dpset.DPSet,
        "topology_api_app": switches.Switches,
        "wsgi": WSGIApplication, 
        "topology": event.EventHostRequest,
    }

    def __init__(self, *args, **kwargs):
        super(IntelligentRyu, self).__init__(*args, **kwargs)
        self.topology_api_app = kwargs["topology_api_app"]
        self.is_dynamically_detect_topo = False
        self.static_net = nx.DiGraph()
        self.dynamic_net = nx.DiGraph()
        self.switches = {}
        self.ip_to_mac = {}
        self.flow_stats_reply = {}  # dpid -> latest flow stats list

        wsgi = kwargs["wsgi"]
        wsgi.register(RyuServerController, {RYU_SERVER_INSTANCE_NAME: self})

        self.install_initial_openflow_entries_completed = False
        self.all_destination_paths = []

        # [Co-developed with claude code -- Adam]
        # Debounce state for recomputing routes after a topology change. See
        # _schedule_route_reinstall for why this exists at all.
        self.topology_change_seq = 0
        self.reinstall_worker_running = False
        

    # [Co-developed with claude code -- Adam]
    #
    # Until these existed, a link failure changed nothing. on_link_delete logged the event and
    # POSTed /ndt/link_failure_detected to the digital twin, and stopped there:
    #
    #   - nothing removed the edge from the graph paths are computed from -- there was no
    #     remove_edge anywhere in this file -- so the graph kept reporting a link that was down; and
    #   - install_all_pair_paths ran exactly once per process, because
    #     install_initial_openflow_entries_completed is set on the line immediately before the call.
    #
    # So the rules installed ~60s after startup were the final state for the life of the run.
    # Observed: `link s1 s5 down` with a flow crossing that link -- traffic stopped arriving, was
    # never rerouted, and the twin (correctly) showed the edge down while Ryu's own graph still had
    # it. See doc/HANDOFF.md section 1g.
    def _active_net(self):
        """The graph routes are computed from: whichever of the two this run is using."""
        return self.dynamic_net if self.is_dynamically_detect_topo else self.static_net

    def _schedule_route_reinstall(self, reason):
        """
        Recompute and reinstall all-pair routes, once, shortly after the topology stops changing.

        Debounced rather than immediate for two reasons. `link a b down` raises one EventLinkDelete
        per direction, and a switch coming up raises a burst, so an immediate recompute would run
        several times over for one operator action. And install_all_pair_paths walks every host pair
        -- 16256 of them on the 128-host topology -- which is far too much work to do inline in an
        event handler, where it would stall LLDP discovery and every other Ryu greenlet.
        """
        self.topology_change_seq += 1
        self.logger.warning("topology changed (%s); route reinstall scheduled", reason)
        if self.reinstall_worker_running:
            return
        self.reinstall_worker_running = True
        hub.spawn(self._route_reinstall_worker)

    def _route_reinstall_worker(self):
        try:
            # The outer loop exists because _schedule_route_reinstall returns early while this worker
            # is running, so a change arriving during install_all_pair_paths is *dropped* -- and the
            # only place it can still be noticed is here, after the walk.
            #
            # Without it the window was the duration of the walk: 16256 host pairs, about 60s (see
            # doc/HANDOFF.md 1g). A second link failing in that window was never recomputed, which is
            # the same silent non-recovery 2c81b26 was written to fix -- and the log said "route
            # reinstall done", meaning the *previous* change. Found by review, not by a test; the
            # tests below cover the debounce but nothing yet drives a change into the walk.
            while True:
                # Wait for the graph to stop moving: if another change arrives while we sleep, start
                # the quiet period again.
                while True:
                    seen = self.topology_change_seq
                    hub.sleep(reinstall_quiet_period)
                    if self.topology_change_seq == seen:
                        break

                if not self.install_initial_openflow_entries_completed:
                    # [Co-developed with claude code -- Adam]
                    # Waits rather than returning. The old comment claimed "the initial install will
                    # cover the current graph when it does" -- but the initial walk may have *started
                    # before* this change arrived, in which case it is walking a graph that predates
                    # it and will not cover it at all. Returning here dropped the change silently,
                    # which is the same class of loss as the mid-walk window above.
                    #
                    # Bounded, and on expiry it proceeds anyway: if the initial install is that late
                    # it has probably thrown, and in that case there are no routes at all and a walk
                    # is exactly what is wanted.
                    self.logger.warning(
                        "route reinstall waiting for the initial install to finish")
                    waited = 0
                    while (not self.install_initial_openflow_entries_completed
                           and waited < initial_install_wait_limit):
                        hub.sleep(1)
                        waited += 1
                    if not self.install_initial_openflow_entries_completed:
                        self.logger.error(
                            "initial install still not done after %ds; recomputing anyway",
                            waited)
                    # Falls through to the walk either way. `continue`-ing here was an infinite
                    # loop when the flag never arrives: the outer loop re-checks it, waits again,
                    # and never walks. Caught by the test for that case, not by reading.

                self.logger.warning("recomputing all-pair routes after topology change")
                self.install_all_pair_paths(self._active_net())
                self.logger.warning("route reinstall done")

                if self.topology_change_seq == seen:
                    return
                # Anything that arrived mid-walk was silently discarded by the early return in
                # _schedule_route_reinstall. Go round again rather than leaving those rules stale.
                self.logger.warning(
                    "topology changed again during the recompute (seq %d -> %d); recomputing",
                    seen, self.topology_change_seq)
        except Exception as e:
            # A greenlet that dies takes its traceback with it and nothing else notices, which is
            # how a silent non-recovery would come back.
            self.logger.error("route reinstall failed: %s", e, exc_info=True)
        finally:
            self.reinstall_worker_running = False

    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def switch_features_handler(self, ev):
        # Install table-miss flow entry
        datapath = ev.msg.datapath
        parser = datapath.ofproto_parser
        ofproto = datapath.ofproto

        self.logger.info(f"Datapath ID: {datapath.id}")

        match = parser.OFPMatch()
        actions = [
            parser.OFPActionOutput(ofproto.OFPP_CONTROLLER, ofproto.OFPCML_NO_BUFFER)
        ]
        self.add_flow(datapath, 0, match, actions)

    def add_flow(self, datapath, priority, match, actions):
        ofproto = datapath.ofproto
        parser = datapath.ofproto_parser

        inst = [parser.OFPInstructionActions(ofproto.OFPIT_APPLY_ACTIONS, actions)]
        mod = parser.OFPFlowMod(
            datapath=datapath, priority=priority, match=match, instructions=inst
        )
        datapath.send_msg(mod)

    def safe_add_or_modify_flow(self, datapath, priority, match, actions):
        ofproto = datapath.ofproto
        parser = datapath.ofproto_parser

        inst = [parser.OFPInstructionActions(ofproto.OFPIT_APPLY_ACTIONS, actions)]

        # Try MODIFY_STRICT first
        mod = parser.OFPFlowMod(
            datapath=datapath,
            command=ofproto.OFPFC_MODIFY_STRICT,
            priority=priority,
            match=match,
            instructions=inst,
        )
        datapath.send_msg(mod)

        # Also try ADD — if MODIFY failed (no existing flow), ADD will succeed
        mod_add = parser.OFPFlowMod(
            datapath=datapath, priority=priority, match=match, instructions=inst
        )
        datapath.send_msg(mod_add)

    @set_ev_cls(event.EventSwitchEnter)
    def get_topology_data(self, ev):
        # ------ Update topology info ------
        self.logger.info("Topology update triggered")

        start = time()
        switch_list = []
        while time() - start < 20:
            switch_list = get_switch(self.topology_api_app, None)
            if switch_list:
                break
            hub.sleep(1)

        if not switch_list:
            self.logger.warning(
                "Switch list is empty after timeout — aborting topology update"
            )
            return

        self.logger.info("Complete get_switch")
        self.switches = {sw.dp.id: sw.dp for sw in switch_list}
        
        
        for sw in switch_list:
            if not self.dynamic_net.has_node(sw.dp.id):
                self.dynamic_net.add_node(sw.dp.id)

        links_list = get_link(self.topology_api_app, None)
        self.logger.info("Complete get_link")
        
        for link in links_list:
            src, dst = link.src.dpid, link.dst.dpid
            src_port, dst_port = link.src.port_no, link.dst.port_no
            # self.logger.info(f"Add edge ({src},{src_port}) -> ({dst},{dst_port})")
            # Add forward and reverse edges
            self.dynamic_net.add_edge(src, dst, port=src_port)
            self.dynamic_net.add_edge(dst, src, port=dst_port)

        # ------ Update switch is_up state ------
        dpid = ev.switch.dp.id
        api_url = f"http://localhost:8000/ndt/inform_switch_entered?dpid={dpid}"
        self.logger.info("Switch entered: %s", dpid)

        try:
            # [Co-developed with claude code -- Adam] (connect, read) -- see _state_change_handler.
            response = requests.get(api_url, timeout=(2, 5))
            self.logger.info(
                "Notified NDT (switch enter), status: %s", response.status_code
            )
        except Exception as e:
            self.logger.warning("Failed to notify NDT (switch enter): %s", str(e))

        # After connecting to all switches, try to read static topology file first, if it dose not exist, then try to detect topolody dynamically
        self.logger.info(f"len(self.switches) {len(self.switches)}")
        if len(self.switches) >= switch_num:
            if not self.install_initial_openflow_entries_completed:
                self.load_static_topology()
        elif not self.install_initial_openflow_entries_completed:
            # [Co-developed with claude code -- Adam]
            # The gate is deliberately unchanged: `switch_num` is a fixed 10 rather than the
            # count the topology file declares, and whether that threshold is right is a
            # deployment question, not a code one.
            #
            # What is being fixed is the silence. `load_static_topology` behind this gate is the
            # only trigger for the initial route install, so a fabric with fewer switches
            # connects, reports healthy, answers every liveness probe -- and never installs a
            # single route, saying nothing about why. The INFO line above prints the count with
            # no indication that the count is load-bearing.
            self.logger.warning(
                "%d of %d switches connected; no initial routes will be installed until all %d "
                "are up. Nothing is wrong yet -- but if this is the final size of the fabric, "
                "no route will ever be installed and traffic will not be forwarded.",
                len(self.switches), switch_num, switch_num,
            )
                
    @set_ev_cls(ofp_event.EventOFPStateChange,
                [CONFIG_DISPATCHER, MAIN_DISPATCHER, DEAD_DISPATCHER])
    def _state_change_handler(self, ev):
        dp = ev.datapath
        if ev.state == MAIN_DISPATCHER:
            if dp.id == None:
                return
            self.logger.info("Switch %016x connected (EventOFPStateChange)", dp.id)
            # ------ Update switch is_up state ------
            dpid = ev.datapath.id
            api_url = f"http://localhost:8000/ndt/inform_switch_entered?dpid={dpid}"
            # self.logger.info("Switch entered: %s", dpid)
            try:
                # [Co-developed with claude code -- Adam]
                # (connect, read) timeout. This call had none, and it is the worst place in the file
                # to be missing one: it runs inside an *OpenFlow event handler*, once per switch that
                # connects. When Ryu is started against an already-running Mininet all ten switches
                # reconnect at once -- they have been retrying -- so ten of these fire together,
                # each blocking that datapath's event processing until the kernel answers.
                #
                # A datapath greenlet parked here does not drain its socket. Measured on a wedged Ryu
                # after exactly that startup order: 88 KB of unread data per OpenFlow connection,
                # every /stats/flow request timing out at 1.001s and returning an empty table, LLDP
                # packet-ins never delivered so no link event ever fired, and HTTP connections left
                # in CLOSE-WAIT. It never recovered, not when the walk finished and not when the only
                # client stopped.
                #
                # NOT PROVEN to be the cause -- that needs a py-spy dump taken at the moment of the
                # wedge, and the wedge does not reproduce with the correct startup order (Ryu first):
                # 125 samples over four minutes stayed at a 0.025s mean with Recv-Q at zero. But the
                # timeout is correct regardless, and the two notification POSTs in this file had the
                # identical defect.
                response = requests.get(api_url, timeout=(2, 5))
                self.logger.info(
                    "Notified NDT (switch enter), status: %s", response.status_code
                )
            except Exception as e:
                self.logger.warning("Failed to notify NDT (switch enter): %s", str(e))
        elif ev.state == DEAD_DISPATCHER:
            if dp.id == None:
                return
            self.logger.info("Switch %016x disconnected (EventOFPStateChange)", dp.id)
    
    def _dynamic_topology_worker(self):
        self.logger.info("No static topo file, falling back to dynamic detection. Waiting 60s...")
        hub.sleep(detecting_time)  # this will NOT block the main Ryu thread

        self.print_all_hosts(self.dynamic_net)
        try:
            self.install_all_pair_paths(self.dynamic_net)
            self.install_initial_openflow_entries_completed = True
            self.logger.info("Dynamic topology initialized, all-destination paths installed.")
        except Exception as e:
            self.logger.error(f"Dynamic topology init failed: {e}")
            
    def find_target_by_src_port(self, G, src_node, src_port_attr, attr_name="port"):
        for _, v, data in G.out_edges(src_node, data=True):
            if data.get(attr_name) == src_port_attr:
                return v
        return None
    
    def int_to_mac(self, n: int) -> str:
        if not (0 <= n < (1 << 48)):
            raise ValueError("MAC int must be in [0, 2^48)")
        return ":".join(f"{(n >> (8*i)) & 0xff:02x}" for i in reversed(range(6)))

            
    def load_static_topology(self, path: Path = static_topology_file_path):
        if not path.exists():
            self.logger.info(f"Static topology file not found: {path}")
            self.is_dynamically_detect_topo = True
            self.logger.info(f"self.is_dynamically_detect_topo {self.is_dynamically_detect_topo}")

            # Start background thread instead of blocking with sleep
            t = threading.Thread(target=self._dynamic_topology_worker, daemon=True)
            t.start()

            return None

        try:
            with path.open("r") as f:
                topo = json.load(f)
            self.logger.info(f"Loaded static topology from {path}")
            
            
            # Add nodes and edges to net
            for node in topo.get("nodes", []):
                if not node: continue
                # self.logger.info(f"n {node.get('nickname', '')}")
                if node.get("vertex_type", "") == 0:    # switch
                    ecmp_groups = node.get("ecmp_groups", [])
                    self.static_net.add_node(int(node.get("dpid")), ecmp_groups=ecmp_groups)
                elif node.get("vertex_type", "") == 1: # host
                    ip_list = node.get("ip")
                    mac = node.get("mac")
                    self.static_net.add_node(self.int_to_mac(mac), ip_list=ip_list)
                    for ip in ip_list:
                        self.ip_to_mac[ip] = mac
                    
            for edge in topo.get("edges", []):
                if not edge: continue
                # self.logger.info(f"e src_dpid {edge.get('src_dpid', '')} -> dst_dpid {edge.get('dst_dpid', '')}")
                if edge.get("src_dpid") == 0:   # host to sw
                    # self.logger.info("host to sw")
                    # Look up mac from vertex
                    first_src_ip = edge.get("src_ip")[0]
                    mac = self.int_to_mac(self.ip_to_mac[first_src_ip])
                    # self.logger.info(f"src mac {mac} target dst_dpid {edge.get('dst_dpid')} port 0")
                    self.static_net.add_edge(mac, edge.get("dst_dpid"), port=0)
                elif edge.get("dst_dpid") == 0: # sw to host
                    # self.logger.info("sw to host")
                    # Look up mac from vertex
                    first_dst_ip = edge.get("dst_ip")[0]
                    mac = self.int_to_mac(self.ip_to_mac[first_dst_ip])
                    # self.logger.info(f"src src_dpid {edge.get('src_dpid')} target mac {mac} port {edge.get('src_interface')}")
                    self.static_net.add_edge(edge.get("src_dpid"), mac, port=edge.get("src_interface"))
                else:
                    # self.logger.info("sw to sw")
                    self.static_net.add_edge(edge.get("src_dpid"), edge.get("dst_dpid"), port=edge.get("src_interface"))
            # Install all-destination routing entries
            if is_mininet:
                hub.sleep(60)
            # [Co-developed with claude code -- Adam]
            # The flag is set AFTER the walk, matching the dynamic path above. It used to be set
            # before, so it was True for the whole ~60 s of the initial install -- and the reinstall
            # worker's guard is `if not ...completed: return`. A link event during the walk therefore
            # passed the guard and started a *second* concurrent walk. hub is cooperative so nothing
            # corrupts, but both walks issue OFPFC_ADD for the same (switch, ipv4_dst) at the same
            # priority, which overwrites -- so whichever finished last won, and the one that started
            # first was walking the pre-failure graph. Each also assigns its own local list to
            # self.all_destination_paths, which the kernel then pulls. Nondeterministic routing and a
            # nondeterministic answer to get_path_switch_count, with nothing logging a conflict.
            self.install_all_pair_paths(self.static_net)
            self.install_initial_openflow_entries_completed = True
            self.logger.info("Static topology initialized, all-destination paths installed.")
            
        except Exception as e:
            self.logger.error(f"Failed to load static topology file {path}: {e}")


    def print_all_hosts(self, net):
        # Sort nodes by first IP
        sorted_nodes = sorted(
            net.nodes,
            key=lambda node: (
                ipaddress.IPv4Address(net.nodes[node]["ip_list"][0])
                if "ip_list" in net.nodes[node]
                else ipaddress.IPv4Address("255.255.255.255")
            ),  # Put at the end
        )

        # Create a new graph
        ordered_net = nx.DiGraph()

        # Add nodes and edges in order
        for node in sorted_nodes:
            ordered_net.add_node(node, **net.nodes[node])

        ordered_net.add_edges_from(net.edges(data=True))

        # Replace self.net
        net = ordered_net

        all_ips_num = 0
        self.logger.info("All IPs in all hosts (sorted):")
        for node in net.nodes:
            node_data = net.nodes[node]
            if "ip_list" in node_data:
                # Sort all collected IPs
                node_data["ip_list"] = sorted(
                    node_data["ip_list"], key=lambda ip: ipaddress.IPv4Address(ip)
                )
                self.logger.info(f"{node_data['ip_list']}")
                all_ips_num += len(node_data["ip_list"])

        print(f"all_ips_num: {all_ips_num}")


    
    def find_host_by_ip(self, net, target_ip):
        for node in net.nodes:
            node_data = net.nodes[node]
            if "ip_list" in node_data:
                if target_ip in node_data["ip_list"]:
                    return node
        return None


    
    def find_connected_switch(self, net, host):
        return list(net.neighbors(host))[0]

    
    def get_host_port(self, net, host, switch):
        return net[switch][host]["port"]

    def is_switch(self, node):
        return isinstance(node, int) and node in self.switches

    def hash_dst_ip(self, str):
        # Use SHA256 or any hash to make it deterministic
        return int(hashlib.sha256(str.encode()).hexdigest(), 16)

    def debug_print_graph(self, net):
        print(f"=== NODES {len(net.nodes)} ===")
        for n, data in net.nodes(data=True):
            print(f"{n}: {data}")

        print(f"\n=== EDGES {len(net.edges)} ===")
        for u, v, data in net.edges(data=True):
            print(f"{u} -> {v}: {data}")


    def install_all_pair_paths(self, net):
        self.logger.info("install_all_pair_paths")
        self.debug_print_graph(net)
        all_hosts_ip_list = []
        all_destination_paths = []
        for node in net.nodes:
            node_data = net.nodes[node]
            if "ip_list" in node_data:
                all_hosts_ip_list.extend(node_data["ip_list"])

        for dst_ip in all_hosts_ip_list:
            dst_host = self.find_host_by_ip(net, dst_ip)
            dst_switch = self.find_connected_switch(net, dst_host)
            # self.logger.info("Installing paths toward host %s via BFS", dst_ip)
            parent_hash = {}
            parent_hash[dst_ip] = None


            # BFS traversal starting from dst_switch
            visited = set()
            queue = [(dst_switch, None)]  # (current_switch, previous_switch)

            while queue:
                current_switch, prev_switch = queue.pop(0)
                if current_switch in visited:
                    continue
                visited.add(current_switch)

                # Determine out_port toward dst_host
                if prev_switch is not None:
                    # [Co-developed with claude code -- Adam]
                    # Enqueue already proved this edge existed, but add_flow yields to the event
                    # loop, so a link event can remove it mid-walk. Losing one switch's entry for
                    # one round is recoverable -- whatever removed the edge also schedules another
                    # recompute. Losing the whole round to a KeyError is what froze routing.
                    edge = net[current_switch].get(prev_switch)
                    if edge is None:
                        self.logger.warning(
                            "edge %s->%s vanished mid-recompute; skipping switch %s for dst %s",
                            current_switch, prev_switch, current_switch, dst_ip)
                        continue
                    out_port = edge["port"]
                    parent_hash[current_switch] = prev_switch
                else:
                    out_port = self.get_host_port(net, dst_host, current_switch)
                    parent_hash[current_switch] = dst_ip

                # Install OpenFlow entry for forwarding to dst_ip
                # self.logger.info(f"current_switch type {type(current_switch)}")
                # self.logger.info(f"current_switch {current_switch}")
                datapath = self.switches.get(current_switch)
                # [Co-developed with claude code -- Adam]
                # None once this runs on link events rather than only at startup: a switch can be
                # gone from self.switches while still present in the graph. Reaching straight for
                # .ofproto_parser raised AttributeError, which aborted the whole recompute part-way
                # and left routes half-installed.
                if datapath is None:
                    self.logger.warning(
                        "skipping switch %s while installing routes to %s: not connected",
                        current_switch,
                        dst_ip,
                    )
                    continue
                parser = datapath.ofproto_parser
                match = parser.OFPMatch(eth_type=0x0800, ipv4_dst=dst_ip)
                actions = [parser.OFPActionOutput(out_port)]
                self.add_flow(datapath, priority=10, match=match, actions=actions)

                # self.logger.info(
                #     "Installing flow on switch %s: match(ipv4_dst=%s) -> output(port=%d)",
                #     current_switch,
                #     dst_ip,
                #     out_port,
                # )


                
                # Add neighbors to BFS queue randomly
                # neighbors = list(net.neighbors(current_switch))
                # print(f"neighbors {neighbors}")
                # random.shuffle(neighbors)  # Randomize neighbor order

                # Add neighbors to BFS queue deterministically
                neighbors = list(net.neighbors(current_switch))
                # self.logger.info(f"neighbors {neighbors}")

                        
                # Sort neighbors based on hash of (dst_ip + neighbor)
                neighbors.sort(key=lambda neighbor: (self.hash_dst_ip(dst_ip + str(neighbor))))
                # self.logger.info(f"sorted neighbors {neighbors}")
                
                
                if is_all_dst_biased:
                    ecmp_groups = net.nodes[current_switch]["ecmp_groups"]
                    ecmp_groups_member_in_neighbors = []
                    if ecmp_groups != []:
                        for group in ecmp_groups:
                            members = group["members"]
                            temp = [] 
                            for member in members:
                                port_id = member["port_id"]
                                target_node = self.find_target_by_src_port(net, current_switch, port_id, "port")
                                self.logger.info(f"target_node {target_node}")
                                
                                if target_node in neighbors:
                                    temp.append(target_node)
                                    
                            ecmp_groups_member_in_neighbors.append(temp)
                                
                    self.logger.info(f"ecmp_groups_member_in_neighbors {ecmp_groups_member_in_neighbors}")
                    
                    for group in ecmp_groups_member_in_neighbors:
                        r = random.random()
                        r2 = int((random.random() * 10)) % len(group)-1
                        self.logger.info(f"r {r} r2 {r2}")
                        temp = 0
                        if r <= all_dst_ecmp_biased_factor: # choose first element
                            temp = group[0]
                        else:   # choose others
                            temp = group[r2+1]
                        group.remove(temp)
                        group.append(temp)
                        
                
                    for group in ecmp_groups_member_in_neighbors:
                        for ele in group:
                            neighbors.remove(ele)
                            neighbors.insert(0,ele)
                
                    self.logger.info(f"biased neighbors {neighbors}")
                
                # [Co-developed with claude code -- Adam]
                # Only walk a link that exists in BOTH directions. The graph is a DiGraph kept in
                # sync by per-direction LLDP events, and a unidirectional dataplane failure removes
                # exactly one of the two directed edges -- the paired EventLinkDelete never fires,
                # so the asymmetry is a steady state, not a transient. The entry installed at
                # `neighbor` forwards neighbor -> current and needs the neighbor->current edge for
                # its out port; walking the half-dead link crashed the whole recompute at that
                # lookup (KeyError), which froze every route while the twin kept reporting the
                # flow as healthy (live 2026-08-13: 291 s blackhole, zero self-heal). Skipping the
                # pair lets BFS reach the switch through any healthy neighbor instead, so traffic
                # routes around the dead direction.
                for neighbor in neighbors:
                    if (neighbor not in visited and self.is_switch(neighbor)
                            and net.has_edge(neighbor, current_switch)):
                        queue.append((neighbor, current_switch))


            # Reconstruct path from any switch back to dst_switch
            for switch in parent_hash:
                path = []
                node = switch
                # [Co-developed with claude code -- Adam]
                # Same mid-walk hazard as the install loop above: these lookups re-read the graph
                # after every yield, so a vanished edge must cost this one reported path, not the
                # whole recompute.
                try:
                    while node is not None:
                        if parent_hash.get(node) is not None:
                            next_hop = parent_hash[node]
                            if self.is_switch(next_hop):
                                out_port = net[node][next_hop]["port"]
                            else:
                                host = self.find_host_by_ip(net, next_hop)
                                out_port = net[node][host]["port"]
                            path.append((node, out_port))
                        else:
                            path.append((node, 0))
                        node = parent_hash.get(node)
                except KeyError:
                    self.logger.warning(
                        "edge vanished mid-recompute while reporting the path via switch %s to "
                        "%s; dropping that path for this round", switch, dst_ip)
                    continue


                # print(f"Flow path to {dst_ip} through switch {switch}: {' -> '.join(str(n) for n in path)}")
                full_path = []
                for src_ip in all_hosts_ip_list:
                    if src_ip == dst_ip:
                        continue
                    src_host = self.find_host_by_ip(net, src_ip)
                    src_switch = self.find_connected_switch(net, src_host)
                    out_port = net[src_switch][src_host]["port"]
                    # print(f"src out_port {out_port}")
                    if src_switch == switch:
                        full_path = [(src_ip, out_port)] + path
                        # self.logger.info("Flow path from %s to %s path %s\n\n\n\n\n", src_ip, dst_ip, full_path)
                        all_destination_paths.append(full_path)
        
        self.all_destination_paths = all_destination_paths
                        


    @set_ev_cls(ofp_event.EventOFPPacketIn, MAIN_DISPATCHER)
    def _packet_in_handler(self, ev):
        msg = ev.msg
        datapath = msg.datapath
        dpid = datapath.id
        ofproto = datapath.ofproto
        parser = datapath.ofproto_parser
        in_port = msg.match["in_port"]

        pkt = packet.Packet(msg.data)
        eth = pkt.get_protocol(ethernet.ethernet)

        # Ignore LLDP packets
        if eth.ethertype == ether_types.ETH_TYPE_LLDP:
            # self.logger.info("LLDP from switch %s", dpid)
            return

        # Ignore ARP packets
        arp_pkt = pkt.get_protocol(arp.arp)
        if arp_pkt:
            return

        # Ignore mDNS, SSDP, LLMNR
        if eth.ethertype == ether_types.ETH_TYPE_IP:
            ip_pkt = pkt.get_protocol(ipv4.ipv4)

            # Define a set of multicast IPs to ignore.
            # This is more efficient than multiple 'if' statements.
            multicast_ips_to_ignore = {
                "224.0.0.251",  # mDNS (Multicast DNS)
                "224.0.0.252",  # LLMNR (Link-Local Multicast Name Resolution)
                "239.255.255.250",  # SSDP (Simple Service Discovery Protocol)
            }

            # If the destination IP is in our ignore list, simply drop the packet and return.
            if ip_pkt.dst in multicast_ips_to_ignore:
                # self.logger.debug(f"Ignoring multicast packet to {ip_pkt.dst} from DPID {dpid}")
                return

        # self.logger.info("Packet in triggered")

        eth_dst = eth.dst
        eth_src = eth.src

        ip_pkt = pkt.get_protocol(ipv4.ipv4)

        if not ip_pkt:
            return  # Only process IPv4 packets

        ip_dst = ip_pkt.dst
        ip_src = ip_pkt.src

        tcp_pkt = pkt.get_protocol(tcp.tcp)
        udp_pkt = pkt.get_protocol(udp.udp)
        icmp_pkt = pkt.get_protocol(icmp.icmp)

        if icmp_pkt:  # Use ping to let Ryu detect all IPs (IP alias)
            port_no = in_port
            # print(f"ip_src {ip_src} packet in")
            host_id = eth_src
            # if self.install_initial_openflow_entries_completed == True:
            #     print(f"ip_src {ip_src} packet in")
            
            # self.logger.info(f"self.is_dynamically_detect_topo {self.is_dynamically_detect_topo}")
            if self.is_dynamically_detect_topo:
                # self.logger.info(f"packet in host_id {host_id}")
                if not self.dynamic_net.has_node(host_id):
                    # self.logger.info("self.dynamic_net.add_node")
                    self.dynamic_net.add_node(host_id, ip_list=[ip_src])
                else:
                    # self.logger.info("else self.dynamic_net.add_node")
                    ip_list = self.dynamic_net.nodes[host_id]["ip_list"]
                    if ip_src not in ip_list:
                        ip_list.append(ip_src)

                if not self.dynamic_net.has_edge(dpid, host_id):
                    self.dynamic_net.add_edge(dpid, host_id, port=port_no)

                if not self.dynamic_net.has_edge(host_id, dpid):
                    self.dynamic_net.add_edge(host_id, dpid, port=0)
           

    @set_ev_cls(event.EventLinkDelete)
    def on_link_delete(self, ev):
        self.logger.warning("Link deleted: %s", ev.link)
        link = ev.link
        src_dpid = link.src.dpid
        src_port = link.src.port_no
        dst_dpid = link.dst.dpid
        dst_port = link.dst.port_no

        # [Co-developed with claude code -- Adam]
        # Our own state first, the remote notification second.
        #
        # The graph is a DiGraph and EventLinkDelete fires once per direction, so removing the one
        # directed edge named by this event is exactly right -- when both directions die, the
        # paired event removes the other. A unidirectional failure fires only this one event and
        # the asymmetry is then a steady state, which is why install_all_pair_paths refuses to
        # walk a link that is missing its reverse edge (live 2026-08-13: recompute crashed on the
        # asymmetric graph and traffic blackholed until the link recovered).
        # Without this the graph kept a link that was down, and every path computed from it was
        # wrong, silently.
        #
        # This used to sit *below* the notification, which meant it inherited an unbounded
        # `requests.post`. A refused connection returns at once, but a process that accepts and never
        # answers blocks forever and raises nothing, so the `except` below does not help -- and
        # HANDOFF 1j records a wedged kernel holding :8000 biting three times. The edge would never
        # have been removed and no reinstall scheduled: exactly the pre-2c81b26 behaviour, silently.
        # Beyond the hang, this graph is this application's own state and has no business being
        # conditional on a remote call at all.
        net = self._active_net()
        if net.has_edge(src_dpid, dst_dpid):
            net.remove_edge(src_dpid, dst_dpid)
            self.logger.warning("removed edge %s -> %s from the routing graph", src_dpid, dst_dpid)
        self._schedule_route_reinstall(f"link {src_dpid} -> {dst_dpid} down")

        # Notify NDT
        api_url = "http://localhost:8000/ndt/link_failure_detected"

        headers = {"Content-Type": "application/json"}

        data = {
            "src_dpid": src_dpid,
            "src_interface": src_port,
            "dst_dpid": dst_dpid,
            "dst_interface": dst_port,
        }

        try:
            # (connect, read). Without a timeout this blocks indefinitely against a listener that
            # accepts and never replies, parking the greenlet.
            response = requests.post(api_url, json=data, headers=headers, timeout=(2, 5))
            self.logger.warning("Notified NDT, status code: %s", response.status_code)
        except Exception as e:
            self.logger.warning("Failed to notify NDT: %s", str(e))

    @set_ev_cls(event.EventLinkAdd)
    def on_link_add(self, ev):
        self.logger.warning("Link added: %s", ev.link)
        link = ev.link
        src_dpid = link.src.dpid
        src_port = link.src.port_no
        dst_dpid = link.dst.dpid
        dst_port = link.dst.port_no

        # [Co-developed with claude code -- Adam]
        # Applied to whichever graph this run computes routes from. It used to update dynamic_net
        # only, so in static-topology mode -- the mode the user manual documents -- a link coming
        # back was never reflected, and after on_link_delete started removing edges that would have
        # made the loss permanent.
        #
        # Only the direction this event names is added, matching on_link_delete. The reverse arrives
        # as its own event; adding it here from dst_port would guess at a link that may not be up.
        net = self._active_net()
        if not net.has_edge(src_dpid, dst_dpid):
            net.add_edge(src_dpid, dst_dpid, port=src_port)
            self.logger.info(
                "Added edge to the routing graph: %s:%s -> %s:%s",
                src_dpid,
                src_port,
                dst_dpid,
                dst_port,
            )

        # [Co-developed with claude code -- Adam] As on_link_delete: a link coming back is a
        # topology change, and routes that were moved off it should be able to move back.
        #
        # Scheduled before the notification, for the same reason the edge removal in on_link_delete
        # is: this is local state and must not be conditional on a remote call. It used to sit below
        # an unbounded requests.post, so a kernel that accepted the connection and never answered
        # would block here forever -- raising nothing, so the `except` did not help -- and the routes
        # would never move back onto the recovered link.
        self._schedule_route_reinstall(f"link {src_dpid} -> {dst_dpid} up")

        # Notify NDT link is recovered
        api_url = "http://localhost:8000/ndt/link_recovery_detected"

        headers = {"Content-Type": "application/json"}

        data = {
            "src_dpid": src_dpid,
            "src_interface": src_port,
            "dst_dpid": dst_dpid,
            "dst_interface": dst_port,
        }

        try:
            response = requests.post(api_url, json=data, headers=headers, timeout=(2, 5))
            self.logger.warning("Notified NDT, status code: %s", response.status_code)
        except Exception as e:
            self.logger.warning("Failed to notify NDT: %s", str(e))

    @set_ev_cls(ofp_event.EventOFPFlowStatsReply, MAIN_DISPATCHER)
    def flow_stats_reply_handler(self, ev):
        dpid = ev.msg.datapath.id
        stats = []

        for stat in ev.msg.body:
            # Safely extract match
            try:
                match = {k: v for k, v in stat.match.items()}
            except Exception as e:
                self.logger.error("Failed to extract match for DPID %s: %s", dpid, e)
                match = {}

            # Extract instructions and actions
            actions_list = []
            for instruction in stat.instructions:
                if hasattr(instruction, "actions"):
                    for action in instruction.actions:
                        action_info = {
                            "type": action.__class__.__name__,
                            "port": getattr(action, "port", None),
                            "max_len": getattr(action, "max_len", None),
                        }
                        actions_list.append(action_info)

            entry = {
                "table_id": stat.table_id,
                "priority": stat.priority,
                "match": match,
                "instructions": actions_list,
                "duration_sec": stat.duration_sec,
                "packet_count": stat.packet_count,
                "byte_count": stat.byte_count,
            }
            stats.append(entry)

        self.flow_stats_reply[dpid] = stats
        # self.logger.info(
        #     "Flow stats for DPID %s: %s", dpid, json.dumps(stats, indent=2)
        # )




# For NDT API
class RyuServerController(ControllerBase):
    # use the same key you passed to wsgi.register()
    def __init__(self, req, link, data, **config):
        super().__init__(req, link, data, **config)
        self.ndt_app = data[RYU_SERVER_INSTANCE_NAME]

    @route("ndt", "/ryu_server/all_destination_paths", methods=["GET", "POST"])
    def get_all_paths(self, req, **kwargs):
        print("all_destination_paths in")
        payload = {
            "status": "success",
            "all_destination_paths": self.ndt_app.all_destination_paths
        }
        return Response(
            content_type="application/json",
            body=json.dumps(payload).encode('utf-8')
        )
