import os
import sys
import grpc
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc

# [Co-developed with claude code -- Adam]
# The port comes from the fabric's own module, not from a literal here. It was
# 'localhost:50051' until F-15 moved the block off the kernel's ephemeral range; a hardcoded
# number in a hand-run probe fails as "connection refused" against a perfectly healthy
# fabric, which reads as "the switch is down" rather than "this script is out of date".
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mininet"))
from grpc_ports import grpc_port  # noqa: E402

channel = grpc.insecure_channel(f'localhost:{grpc_port(1)}')
stub = p4runtime_pb2_grpc.P4RuntimeStub(channel)

req = p4runtime_pb2.ReadRequest()
req.device_id = 1
entity = req.entities.add()
entity.table_entry.table_id = 0 # All tables

resp = stub.Read(req)
for rep in resp:
    for entity in rep.entities:
        if entity.HasField('table_entry'):
            print(entity.table_entry)
