import sys
sys.path.append('p4_proxy')
from proxy_agent.p4_client import P4RuntimeClient
import grpc

client = P4RuntimeClient(1, 'localhost:50051', 'p4_proxy/p4_src/build/ndtwin_switch.p4info.txt')
try:
    client.modify_ipv4_route("10.0.0.2", 32, "00:00:00:00:00:02", 1000)
    print("Success")
except Exception as e:
    print("Exception:", e)
