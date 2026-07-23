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
is_mininet = True   # True: Mininet, False: physical testbed

RYU_SERVER_INSTANCE_NAME = "ndt_ryu_app"
switch_num = 10
detecting_time = 60
is_all_dst_biased = False
all_dst_ecmp_biased_factor = 1

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
            response = requests.get(api_url)
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
                response = requests.get(api_url)
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
            self.install_initial_openflow_entries_completed = True
            self.install_all_pair_paths(self.static_net)
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
                    out_port = net[current_switch][prev_switch]["port"]
                    parent_hash[current_switch] = prev_switch
                else:
                    out_port = self.get_host_port(net, dst_host, current_switch)
                    parent_hash[current_switch] = dst_ip

                # Install OpenFlow entry for forwarding to dst_ip
                # self.logger.info(f"current_switch type {type(current_switch)}")
                # self.logger.info(f"current_switch {current_switch}")
                datapath = self.switches.get(current_switch)
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
                
                for neighbor in neighbors:
                    if neighbor not in visited and self.is_switch(neighbor):
                        queue.append((neighbor, current_switch))


            # Reconstruct path from any switch back to dst_switch
            for switch in parent_hash:
                path = []
                node = switch
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
            response = requests.post(api_url, json=data, headers=headers)
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

        # Add the edge from self.net
        if self.is_dynamically_detect_topo:
            if not self.dynamic_net.has_edge(src_dpid, dst_dpid):
                self.dynamic_net.add_edge(src_dpid, dst_dpid, port=src_port)
                self.logger.info(
                    "Added edge from net: %s %s -> %s %s",
                    src_dpid,
                    dst_dpid,
                    src_port,
                    dst_port,
                )
            # If bidirectional, Add reverse link too
            if not self.dynamic_net.has_edge(dst_dpid, src_dpid):
                self.dynamic_net.add_edge(dst_dpid, src_dpid, port=dst_port)
                self.logger.info("Added reverse edge: %s -> %s", dst_dpid, src_dpid)

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
            response = requests.post(api_url, json=data, headers=headers)
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
