import os
import sys

# [Co-developed with claude code -- Adam]
# Resolved from this file, not from the working directory. Both of these used to be relative
# to the repo root -- `sys.path.append('p4_proxy')` and a bare 'p4_proxy/p4_src/...' -- so the
# script only ran if you happened to be standing in the right place, and moving it here would
# have broken it silently.
P4_PROXY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, P4_PROXY)

from proxy_agent.p4_client import P4RuntimeClient

client = P4RuntimeClient(
    1, 'localhost:50051',
    os.path.join(P4_PROXY, 'p4_src', 'build', 'ndtwin_switch.p4info.txt'))
try:
    client.modify_ipv4_route("10.0.0.2", 32, "00:00:00:00:00:02", 1000)
    print("Success")
except Exception as e:
    print("Exception:", e)
