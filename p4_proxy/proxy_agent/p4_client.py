import threading
import queue
import grpc
import socket
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2
from google.protobuf import text_format

from proxy_agent.sflow_emitter import PKTIN_META_INGRESS_PORT, sample_from_packet_in

# [Co-developed with claude code -- Adam]
#
# Must match ndtwin_switch.p4. SAMPLE_SESSION is the clone session the pipeline clones telemetry
# samples to; nothing arrives until it is programmed, because a clone to an unconfigured session
# is silently dropped by bmv2.
SAMPLE_SESSION_ID = 250
CPU_PORT = 255


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

        # Declared up front rather than probed with hasattr, so a missing assignment is a
        # None check rather than a silently skipped branch.
        self.packet_in_callback = None   # (device_id, ingress_port, payload) -> None
        self.sample_callback = None      # (device_id, SampledPacket) -> None

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
        """
        Routes a CPU packet to either the telemetry path or the discovery path.

        [Co-developed with claude code -- Adam]

        Telemetry samples and genuine packet-ins share this one channel, and are told apart by
        the `reason` field of packet_in_header_t rather than by inspecting the frame. They cannot
        be separate controller headers -- see the header comment in ndtwin_switch.p4.

        Sampled traffic is high-rate by design, so a sample must never reach the LLDP parser:
        that would try to read every sampled packet as a beacon and, at 1-in-256 of all traffic,
        drown discovery in work it cannot use.
        """
        sample = sample_from_packet_in(packet)
        if sample is not None:
            if self.sample_callback:
                self.sample_callback(self.device_id, sample)
            return

        ingress_port = 0
        for meta in packet.metadata:
            if meta.metadata_id == PKTIN_META_INGRESS_PORT:
                ingress_port = int.from_bytes(meta.value, byteorder='big')

        if self.packet_in_callback:
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

            # Only when we pushed the pipeline ourselves. The clone session lives in the
            # pipeline's PRE, so bmv2 rejects it with FAILED_PRECONDITION ("No forwarding
            # pipeline config set for this device") if no pipeline is loaded yet.
            #
            # [Co-developed with claude code -- Adam]
            # This used to sit outside the branch, which broke the one caller that matters:
            # main.py starts every switch with push_config=False so it can batch the pipeline
            # pushes, so every clone session was attempted before any pipeline existed and all
            # ten failed. When push_config is False the caller owns the ordering and must call
            # write_clone_session() itself after pushing -- main.py does, in its telemetry
            # setup.
            self.write_clone_session()

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

    # [Co-developed with claude code -- Adam]
    def write_clone_session(self, session_id=SAMPLE_SESSION_ID, egress_port=CPU_PORT):
        """
        Programs the PRE clone session the pipeline samples into.

        Without this, `clone_preserving_field_list` targets a session that does not exist and
        bmv2 drops the copy without an error anywhere -- the pipeline looks correct, the proxy
        looks correct, and no telemetry ever appears. So this is a hard failure, not a warning.

        Falls back to MODIFY when INSERT fails, so a proxy restart against live switches
        reconfigures the session instead of refusing to start.

        The fallback deliberately triggers on *any* INSERT failure rather than on
        ALREADY_EXISTS. Measured against a real bmv2: inserting an existing session returns
        **UNKNOWN with an empty details string**, not ALREADY_EXISTS, so a code-specific check
        never fired -- every switch reported "clone session failed, NO telemetry from it" on
        restart while the session was in fact fine. MODIFY on the same session then succeeds.
        Nothing is masked by being less specific: a genuine failure fails the MODIFY too and is
        reported.

        `Replica.port_kind` is a oneof: `egress_port` is the uint32 form and `port` a
        bytestring. Only one may be set. class_of_service must stay 0 -- PI rejects anything
        else as unsupported. packet_length_bytes 0 means no truncation on the switch; the
        emitter truncates instead, since it is the side with tests covering it.
        """
        def build(update_type):
            req = p4runtime_pb2.WriteRequest()
            req.device_id = self.device_id
            req.election_id.low = 1
            update = req.updates.add()
            update.type = update_type
            session = update.entity.packet_replication_engine_entry.clone_session_entry
            session.session_id = session_id
            session.class_of_service = 0
            session.packet_length_bytes = 0
            replica = session.replicas.add()
            replica.egress_port = egress_port
            replica.instance = 1
            return req

        try:
            self.stub.Write(build(p4runtime_pb2.Update.INSERT))
            print(f"[{self.device_id}] Clone session {session_id} -> port {egress_port} installed")
            return True
        except grpc.RpcError as insert_error:
            # Any INSERT failure, not just ALREADY_EXISTS -- see the docstring. bmv2 reports a
            # duplicate session as UNKNOWN with empty details, so a code-specific check silently
            # never fired.
            try:
                self.stub.Write(build(p4runtime_pb2.Update.MODIFY))
                print(f"[{self.device_id}] Clone session {session_id} already present, updated "
                      f"(INSERT said {insert_error.code().name})")
                return True
            except grpc.RpcError as modify_error:
                # Both failed, so this is a real problem. The status code goes in the message,
                # not just details(): bmv2 returns some failures with an empty details() string,
                # leaving nothing to diagnose from. PERMISSION_DENIED usually means this client
                # never won mastership -- e.g. another controller is attached with the same
                # election_id.
                print(f"[{self.device_id}] Clone session {session_id} could not be programmed: "
                      f"INSERT {insert_error.code().name}: {insert_error.details()} / "
                      f"MODIFY {modify_error.code().name}: {modify_error.details()} "
                      f"-- no telemetry samples will be produced by this switch")
                return False

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

    # --- Reading tables back -------------------------------------------------------
    # [Co-developed with claude code -- Adam]

    def _table_name(self, table_id):
        for table in self.p4info.tables:
            if table.preamble.id == table_id:
                return table.preamble.name
        return None

    def _action_name(self, action_id):
        for action in self.p4info.actions:
            if action.preamble.id == action_id:
                return action.preamble.name
        return None

    def _match_field_name(self, table_id, field_id):
        for table in self.p4info.tables:
            if table.preamble.id == table_id:
                for match in table.match_fields:
                    if match.id == field_id:
                        return match.name
        return None

    def _action_param_name(self, action_id, param_id):
        for action in self.p4info.actions:
            if action.preamble.id == action_id:
                for param in action.params:
                    if param.id == param_id:
                        return param.name
        return None

    def read_table_entries(self):
        """
        Every table entry on this switch, with p4info ids resolved to names.

        Returns a list of dicts:

            {"table": "MyIngress.ipv4_lpm",
             "priority": 0,
             "is_default": False,
             "match": {"hdr.ipv4.dstAddr": {"type": "lpm",
                                            "value": b"\\n\\x00\\x00\\x04",
                                            "prefix_len": 32}},
             "action": {"name": "MyIngress.ipv4_forward",
                        "params": {"port": b"\\x03", "dstAddr": b"..."}}}

        Ids are resolved here rather than by the caller because the caller would then need the
        p4info too, and a numeric id in the output is unreadable in a log.

        Raises nothing on a missing name -- an entry referring to an id this p4info does not
        describe is returned with None for that name, so a pipeline/p4info mismatch shows up as
        data instead of an exception on the polling path.
        """
        req = p4runtime_pb2.ReadRequest()
        req.device_id = self.device_id
        # table_id 0 means "every table", which is what dump_table.py at the repo root does.
        req.entities.add().table_entry.table_id = 0

        entries = []
        for response in self.stub.Read(req):
            for entity in response.entities:
                if not entity.HasField("table_entry"):
                    continue
                te = entity.table_entry

                match = {}
                for m in te.match:
                    name = self._match_field_name(te.table_id, m.field_id)
                    if m.HasField("exact"):
                        match[name] = {"type": "exact", "value": m.exact.value}
                    elif m.HasField("lpm"):
                        match[name] = {"type": "lpm",
                                       "value": m.lpm.value,
                                       "prefix_len": m.lpm.prefix_len}
                    elif m.HasField("ternary"):
                        match[name] = {"type": "ternary",
                                       "value": m.ternary.value,
                                       "mask": m.ternary.mask}
                    elif m.HasField("range"):
                        match[name] = {"type": "range",
                                       "low": m.range.low,
                                       "high": m.range.high}

                action = None
                if te.action.HasField("action"):
                    a = te.action.action
                    action = {
                        "name": self._action_name(a.action_id),
                        "params": {self._action_param_name(a.action_id, p.param_id): p.value
                                   for p in a.params},
                    }

                entries.append({
                    "table": self._table_name(te.table_id),
                    "priority": te.priority,
                    # A default action has no match fields; the kernel's Classifier would
                    # otherwise read it as a match-everything rule.
                    "is_default": te.is_default_action,
                    "match": match,
                    "action": action,
                })
        return entries

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
            return True
        except grpc.RpcError as e:
            # [Co-developed with claude code -- Adam]
            #
            # This used to `pass` on every UNKNOWN and return None either way, on the theory
            # that UNKNOWN only means "entry already exists". bmv2 does report duplicates that
            # way -- UNKNOWN with no details -- but it also returns UNKNOWN for genuine
            # failures such as a bad table name or an out-of-range action parameter, so every
            # real write error was being discarded as a harmless duplicate.
            #
            # The two cannot be told apart from the status alone, so rather than guessing from
            # the message we resolve it by doing what the caller meant: retry as a MODIFY. If
            # the entry existed, the modify succeeds and the write is genuinely done -- which
            # also fixes a second bug, since the old code left the existing entry untouched, so
            # a recalculated (better) path never actually took effect. If the modify fails too,
            # this was a real error and is reported as one.
            if e.code() in (grpc.StatusCode.ALREADY_EXISTS, grpc.StatusCode.UNKNOWN):
                if self.modify_ipv4_route(dst_ip, prefix_len, next_hop_mac, port):
                    return True

            print(f"[{self.device_id}] Failed to add route: {e.code()} - {e.details()}")
            return False

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
            return True
        except grpc.RpcError as e:
            # [Co-developed with claude code -- Adam]
            # NOT_FOUND means the entry is already gone, which is what the caller wanted, so
            # it counts as success. Anything else is a real failure and must be reported --
            # previously every outcome returned None and route_flow answered "success".
            if e.code() == grpc.StatusCode.NOT_FOUND:
                return True
            print(f"[{self.device_id}] Failed to delete route: {e.code()} - {e.details()}")
            return False

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
        
        # [Co-developed with claude code -- Adam]
        # The success path had no `return True`, so it fell off the end returning None.
        # topology_manager.modify_flow passed that straight through and api_routes raised
        # HTTPException(400) -- every *successful* modify answered HTTP 400.
        try:
            self.stub.Write(req)
            print(f"[{self.device_id}] Modified route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")
            return True
        except grpc.RpcError as e:
            print(f"[{self.device_id}] Failed to modify route: {e.code()} - {e.details()}")
            return False

# Developed in collaboration with Gemini 3.1 Pro.
