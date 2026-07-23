import threading
import queue
import grpc
import socket
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2
from google.protobuf import text_format

class P4RuntimeClient:
    """Encapsulates P4Runtime gRPC connection to a single BMv2 switch"""
    def __init__(self, device_id, grpc_addr, p4info_path, json_path=None):
        self.device_id = device_id
        self.grpc_addr = grpc_addr
        self.p4info = self._build_p4info(p4info_path)
        self.json_path = json_path
        
        self.channel = grpc.insecure_channel(grpc_addr)
        self.stub = p4runtime_pb2_grpc.P4RuntimeStub(self.channel)
        
        self.stream_out_q = queue.Queue()
        self.stream_recv_thread = None
        self.is_running = False

    def _build_p4info(self, p4info_path):
        p4info = p4info_pb2.P4Info()
        with open(p4info_path, "r") as f:
            text_format.Merge(f.read(), p4info)
        return p4info

    def _stream_iterator(self):
        """Generator that reads from queue and yields StreamMessageRequest"""
        while self.is_running:
            try:
                # Block for a short time to allow checking is_running
                msg = self.stream_out_q.get(timeout=1.0)
                if msg is None:
                    break
                yield msg
            except queue.Empty:
                continue

    def _stream_receiver(self, stream):
        """Background thread to read StreamMessageResponse (e.g. Packet-In)"""
        try:
            for response in stream:
                if response.HasField("packet"):
                    self.handle_packet_in(response.packet)
                elif response.HasField("arbitration"):
                    print(f"[{self.device_id}] Received arbitration response: Mastership confirmed.")
                else:
                    print(f"[{self.device_id}] Received unknown stream message.")
        except grpc.RpcError as e:
            if self.is_running:
                print(f"[{self.device_id}] Stream receiver error: {e.details()}")

    def handle_packet_in(self, packet):
        """To be overridden or connected to a callback by the topology manager"""
        ingress_port = 0
        for meta in packet.metadata:
            if meta.metadata_id == 1: # ingress_port
                ingress_port = int.from_bytes(meta.value, byteorder='big')
        
        # print(f"[{self.device_id}] PACKET-IN received on port {ingress_port}, length {len(packet.payload)}")
        if hasattr(self, 'packet_in_callback') and self.packet_in_callback:
            self.packet_in_callback(self.device_id, ingress_port, packet.payload)

    def send_packet_out(self, egress_port, payload):
        req = p4runtime_pb2.StreamMessageRequest()
        packet_out = req.packet
        packet_out.payload = payload
        
        # egress_port
        meta = packet_out.metadata.add()
        meta.metadata_id = 1 
        meta.value = egress_port.to_bytes(2, byteorder='big')
        
        # _pad
        meta_pad = packet_out.metadata.add()
        meta_pad.metadata_id = 2
        meta_pad.value = (0).to_bytes(1, byteorder='big')
        
        self.stream_out_q.put(req)

    def start(self, push_config=True):
        """Start the P4Runtime session and claim mastership"""
        self.is_running = True
        
        # 1. Open Stream and claim mastership
        req = p4runtime_pb2.StreamMessageRequest()
        req.arbitration.device_id = self.device_id
        req.arbitration.election_id.high = 0
        req.arbitration.election_id.low = 1
        self.stream_out_q.put(req)
        
        self.stream = self.stub.StreamChannel(self._stream_iterator())
        
        # Start receiver thread
        self.stream_recv_thread = threading.Thread(target=self._stream_receiver, args=(self.stream,))
        self.stream_recv_thread.daemon = True
        self.stream_recv_thread.start()
        
        # 2. Push pipeline config if provided
        if push_config:
            import time
            time.sleep(1.0)
            if self.json_path:
                self.set_forwarding_pipeline_config()

    def stop(self):
        self.is_running = False
        self.stream_out_q.put(None)
        if self.stream_recv_thread:
            self.stream_recv_thread.join(timeout=2.0)
        self.channel.close()

    def set_forwarding_pipeline_config(self):
        print(f"[{self.device_id}] Setting Forwarding Pipeline Config...")
        req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
        req.device_id = self.device_id
        req.election_id.low = 1
        req.action = p4runtime_pb2.SetForwardingPipelineConfigRequest.VERIFY_AND_COMMIT
        with open(self.json_path, "rb") as f:
            req.config.p4_device_config = f.read()
        req.config.p4info.CopyFrom(self.p4info)
        self.stub.SetForwardingPipelineConfig(req)

    # --- Helper methods for lookups ---
    def _get_table_id(self, name):
        for table in self.p4info.tables:
            if table.preamble.name == name: return table.preamble.id
        raise KeyError(f"Table {name} not found")

    def _get_action_id(self, name):
        for action in self.p4info.actions:
            if action.preamble.name == name: return action.preamble.id
        raise KeyError(f"Action {name} not found")

    def _get_match_field_id(self, table_name, match_name):
        for table in self.p4info.tables:
            if table.preamble.name == table_name:
                for match in table.match_fields:
                    if match.name == match_name: return match.id
        raise KeyError(f"Match field {match_name} not found")

    def _get_action_param_id(self, action_name, param_name):
        for action in self.p4info.actions:
            if action.preamble.name == action_name:
                for param in action.params:
                    if param.name == param_name: return param.id
        raise KeyError(f"Action parameter {param_name} not found")

    # --- Table Operations ---
    def read_egress_counter(self, port):
        counter_id = None
        for counter in self.p4info.counters:
            if counter.preamble.name == "MyEgress.egress_port_counter":
                counter_id = counter.preamble.id
                break
                
        if not counter_id:
            return 0, 0
            
        req = p4runtime_pb2.ReadRequest()
        req.device_id = self.device_id
        entity = req.entities.add()
        counter_entry = entity.counter_entry
        counter_entry.counter_id = counter_id
        counter_entry.index.index = port
        
        try:
            for response in self.stub.Read(req):
                for entity in response.entities:
                    if entity.HasField("counter_entry"):
                        data = entity.counter_entry.data
                        return data.byte_count, data.packet_count
        except Exception as e:
            pass
        return 0, 0

    def insert_ipv4_route(self, dst_ip, prefix_len, next_hop_mac, port):
        """Inserts a rule into MyIngress.ipv4_lpm"""
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        req.election_id.low = 1
        
        update = req.updates.add()
        update.type = p4runtime_pb2.Update.INSERT
        
        entry = update.entity.table_entry
        entry.table_id = self._get_table_id("MyIngress.ipv4_lpm")
        
        # Match: hdr.ipv4.dstAddr (LPM)
        match = entry.match.add()
        match.field_id = self._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr")
        match.lpm.value = socket.inet_aton(dst_ip)
        match.lpm.prefix_len = prefix_len
        
        # Action: MyIngress.ipv4_forward
        action = entry.action.action
        action.action_id = self._get_action_id("MyIngress.ipv4_forward")
        
        # Param: dstAddr (macAddr_t 48 bits)
        param1 = action.params.add()
        param1.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "dstAddr")
        param1.value = bytes.fromhex(next_hop_mac.replace(':', ''))
        
        # Param: port (bit<9>)
        param2 = action.params.add()
        param2.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "port")
        param2.value = port.to_bytes(2, byteorder='big')
        
        try:
            self.stub.Write(req)
            print(f"[{self.device_id}] Added route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")
        except grpc.RpcError as e:
            # BMv2 returns UNKNOWN without details when trying to insert a duplicate rule.
            # Since LLDP triggers full routing table recalculation on every new link,
            # we safely ignore duplicate insertion errors to keep logs clean.
            if e.code() == grpc.StatusCode.UNKNOWN:
                pass
            else:
                print(f"[{self.device_id}] Failed to add route: {e.code()} - {e.details()}")

    def delete_ipv4_route(self, dst_ip, prefix_len):
        """Deletes a rule from MyIngress.ipv4_lpm"""
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        req.election_id.low = 1
        
        update = req.updates.add()
        update.type = p4runtime_pb2.Update.DELETE
        
        entry = update.entity.table_entry
        entry.table_id = self._get_table_id("MyIngress.ipv4_lpm")
        
        # Match: hdr.ipv4.dstAddr (LPM)
        match = entry.match.add()
        match.field_id = self._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr")
        match.lpm.value = socket.inet_aton(dst_ip)
        match.lpm.prefix_len = prefix_len
        
        try:
            self.stub.Write(req)
            print(f"[{self.device_id}] Deleted route: {dst_ip}/{prefix_len}")
        except grpc.RpcError as e:
            if e.code() != grpc.StatusCode.NOT_FOUND:
                print(f"[{self.device_id}] Failed to delete route: {e.code()} - {e.details()}")

    def modify_ipv4_route(self, dst_ip, prefix_len, next_hop_mac, port):
        """Modifies a rule in MyIngress.ipv4_lpm"""
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        req.election_id.low = 1
        
        update = req.updates.add()
        update.type = p4runtime_pb2.Update.MODIFY
        
        entry = update.entity.table_entry
        entry.table_id = self._get_table_id("MyIngress.ipv4_lpm")
        
        # Match: hdr.ipv4.dstAddr (LPM)
        match = entry.match.add()
        match.field_id = self._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr")
        match.lpm.value = socket.inet_aton(dst_ip)
        match.lpm.prefix_len = prefix_len
        
        # Action: MyIngress.ipv4_forward
        action = entry.action.action
        action.action_id = self._get_action_id("MyIngress.ipv4_forward")
        
        # Param: dstAddr (macAddr_t 48 bits)
        param1 = action.params.add()
        param1.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "dstAddr")
        param1.value = bytes.fromhex(next_hop_mac.replace(':', ''))
        
        # Param: port (bit<9>)
        param2 = action.params.add()
        param2.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "port")
        param2.value = port.to_bytes(2, byteorder='big')
        
        try:
            self.stub.Write(req)
            print(f"[{self.device_id}] Modified route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")
        except grpc.RpcError as e:
            print(f"[{self.device_id}] Failed to modify route: {e.code()} - {e.details()}")
            return False

# Developed in collaboration with Gemini 3.1 Pro.
