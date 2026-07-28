import networkx as nx

class TopologyManager:
    """Maintains the network state and computes shortest paths via BFS"""
    def __init__(self):
        self.net = nx.DiGraph()
        self.switches = {} # dpid -> P4RuntimeClient
        self.dest_paths = {} # To match Ryu's format

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
            
        client = self.switches[dpid]
        ipv4_dst = match_dict.get("nw_dst") or match_dict.get("ipv4_dst")
        if not ipv4_dst:
            return False
            
        # [Co-developed with claude code -- Adam] -- as above: report the real outcome.
        return bool(client.delete_ipv4_route(ipv4_dst, 32))

    def modify_flow(self, dpid, match_dict, actions_dict):
        if dpid not in self.switches:
            return False
            
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
        src_mac = bytes.fromhex(f"0000000000{dpid:02x}")
        ethertype = bytes.fromhex("88cc")
        payload = f"DPID:{dpid},PORT:{port}".encode('utf-8')
        return dst_mac + src_mac + ethertype + payload

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
        lldp_info = self.parse_lldp_packet(payload)
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

    def start_lldp_discovery(self):
        import threading
        import time
        def _loop():
            while True:
                for dpid, client in self.switches.items():
                    # Broadcast LLDP on ports 1 to 6
                    for port in range(1, 7): 
                        pkt = self.create_lldp_packet(dpid, port)
                        client.send_packet_out(port, pkt)
                time.sleep(5) # Send every 5 seconds
        t = threading.Thread(target=_loop, daemon=True)
        t.start()
