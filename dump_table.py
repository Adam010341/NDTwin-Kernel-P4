import sys
import grpc
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc

channel = grpc.insecure_channel('localhost:50051')
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
