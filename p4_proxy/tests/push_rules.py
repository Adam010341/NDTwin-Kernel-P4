import sys
import grpc
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2
from google.protobuf import text_format
import socket
import struct

def build_p4info(p4info_file_path):
    p4info = p4info_pb2.P4Info()
    with open(p4info_file_path, "r") as f:
        text_format.Merge(f.read(), p4info)
    return p4info

def get_table_id(p4info, name):
    for table in p4info.tables:
        if table.preamble.name == name:
            return table.preamble.id
    raise Exception(f"Table {name} not found")

def get_action_id(p4info, name):
    for action in p4info.actions:
        if action.preamble.name == name:
            return action.preamble.id
    raise Exception(f"Action {name} not found")

def get_action_param_id(p4info, action_name, param_name):
    for action in p4info.actions:
        if action.preamble.name == action_name:
            for param in action.params:
                if param.name == param_name:
                    return param.id
    raise Exception(f"Action {action_name} or param {param_name} not found")

def get_match_field_id(p4info, table_name, match_name):
    for table in p4info.tables:
        if table.preamble.name == table_name:
            for match in table.match_fields:
                if match.name == match_name:
                    return match.id
    raise Exception(f"Match {match_name} not found")

def mac_to_bytes(mac):
    return bytes.fromhex(mac.replace(':', ''))

def ip_to_bytes(ip):
    return socket.inet_aton(ip)

def insert_route(stub, p4info, device_id, dst_ip, prefix_len, next_hop_mac, port):
    table_id = get_table_id(p4info, "MyIngress.ipv4_lpm")
    match_id = get_match_field_id(p4info, "MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr")
    action_id = get_action_id(p4info, "MyIngress.ipv4_forward")
    dstAddr_param_id = get_action_param_id(p4info, "MyIngress.ipv4_forward", "dstAddr")
    port_param_id = get_action_param_id(p4info, "MyIngress.ipv4_forward", "port")

    req = p4runtime_pb2.WriteRequest()
    req.device_id = device_id
    req.election_id.low = 1
    
    update = req.updates.add()
    update.type = p4runtime_pb2.Update.INSERT
    
    entry = update.entity.table_entry
    entry.table_id = table_id
    
    # Match
    match = entry.match.add()
    match.field_id = match_id
    match.lpm.value = ip_to_bytes(dst_ip)
    match.lpm.prefix_len = prefix_len
    
    # Action
    action = entry.action.action
    action.action_id = action_id
    
    param1 = action.params.add()
    param1.param_id = dstAddr_param_id
    param1.value = mac_to_bytes(next_hop_mac)
    
    param2 = action.params.add()
    param2.param_id = port_param_id
    param2.value = port.to_bytes(2, byteorder='big') # port is bit<9>, so 2 bytes
    
    try:
        stub.Write(req)
        print(f"Successfully added route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")
    except grpc.RpcError as e:
        print(f"Failed to add route {dst_ip}: {e.details()}")

if __name__ == '__main__':
    channel = grpc.insecure_channel('localhost:50051')
    stub = p4runtime_pb2_grpc.P4RuntimeStub(channel)
    import os
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p4info_path = os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.p4info.txt')
    json_path = os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.json')
    
    p4info = build_p4info(p4info_path)
    
    print("Setting Master Arbitration...")
    def stream_req_iterator():
        req = p4runtime_pb2.StreamMessageRequest()
        req.arbitration.device_id = 1
        req.arbitration.election_id.high = 0
        req.arbitration.election_id.low = 1
        yield req
        import time
        while True:
            time.sleep(1)

    stream = stub.StreamChannel(stream_req_iterator())
    # Wait for response to confirm mastership
    next(stream)
    print("Mastership acknowledged.")
    
    # We also need to SetForwardingPipelineConfig for BMv2 to know the program
    print("Setting Forwarding Pipeline Config...")
    req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
    req.device_id = 1
    req.election_id.low = 1
    req.action = p4runtime_pb2.SetForwardingPipelineConfigRequest.VERIFY_AND_COMMIT
    with open(json_path, "rb") as f:
        req.config.p4_device_config = f.read()
    req.config.p4info.CopyFrom(p4info)
    stub.SetForwardingPipelineConfig(req)
        
    print("Pushing routing rules...")
    insert_route(stub, p4info, 1, "10.0.0.1", 32, "00:00:00:00:00:01", 1)
    insert_route(stub, p4info, 1, "10.0.0.2", 32, "00:00:00:00:00:02", 2)
    print("Done! You can now test Ping in Mininet.")
