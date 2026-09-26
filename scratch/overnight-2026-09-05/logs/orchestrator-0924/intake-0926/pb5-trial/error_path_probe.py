"""Ad-hoc live probe of P4RuntimeClient's error paths, run once per interpreter (main venv, venv-cand).

[Co-developed with claude code -- Adam]

NOT a repo test. Run only on a fabric the pb5 trial claimed, with the proxy stopped (same
precondition as tests/test_p4_client.py LiveSwitchTest), right after LiveSwitchTest put
10.0.0.1/32 and 10.0.0.2/32 on switch 1. Touches switch 1 only. Prints one line per step so the
two interpreters' outputs can be diffed.

  1. arbitration over StreamChannel (start(push_config=False): no pipeline push)
  2. probe(): GetForwardingPipelineConfig COOKIE_ONLY
  3. duplicate INSERT of 10.0.0.1/32 -> the RpcError branch -> MODIFY (the "Modified route" path)
  4. DELETE of an absent route 10.9.9.9/32 -> the RpcError branch of delete
  5. read_table_entries(): Read RPC, a server stream of entities decoded with the p4info
  6. read_egress_counter(1): a counter Read
  7. a raw Write naming table id 0xdeadbeef -> how a genuine error surfaces (code name, details)
"""
import os
import sys
import time

REPO = "/home/adam/Desktop/NDTwin-Kernel"
sys.path.insert(0, os.path.join(REPO, "p4_proxy"))
sys.path.insert(0, os.path.join(REPO, "p4_proxy", "mininet"))

import grpc  # noqa: E402
from google.protobuf import __version__ as pbv  # noqa: E402
from google.protobuf.internal import api_implementation  # noqa: E402
from p4.v1 import p4runtime_pb2  # noqa: E402
from proxy_agent.p4_client import P4RuntimeClient  # noqa: E402
from grpc_ports import grpc_port  # noqa: E402

B = os.path.join(REPO, "p4_proxy", "p4_src", "build")
print("interp", sys.prefix, "protobuf", pbv, "backend", api_implementation.Type(), "grpc", grpc.__version__)
print("env PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION present:",
      "PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION" in os.environ)

c = P4RuntimeClient(device_id=1, grpc_addr="localhost:%d" % grpc_port(1),
                    p4info_path=os.path.join(B, "ndtwin_switch.p4info.txt"),
                    json_path=os.path.join(B, "ndtwin_switch.json"))
c.start(push_config=False)
time.sleep(1.0)
try:
    print("1 stream_alive", c.stream_alive)
    print("2 probe", c.probe())
    print("3 dup insert ->", c.insert_ipv4_route("10.0.0.1", 32, "00:00:00:00:00:01", 1))
    print("4 delete absent ->", c.delete_ipv4_route("10.9.9.9", 32))
    ents = c.read_table_entries()
    rows = sorted((e["table"], str(e["match"]), e["action"]["name"] if e.get("action") else None,
                   e["is_default"]) for e in ents)
    print("5 read_table_entries n=%d" % len(ents))
    for r in rows:
        print("   ", r)
    try:
        print("6 read_egress_counter(1) ->", c.read_egress_counter(1))
    except Exception as e:  # noqa: BLE001
        print("6 read_egress_counter(1) raised", type(e).__name__, e)
    req = p4runtime_pb2.WriteRequest()
    req.device_id = 1
    c._bid(req)
    u = req.updates.add()
    u.type = p4runtime_pb2.Update.INSERT
    u.entity.table_entry.table_id = 0xDEADBEEF
    try:
        c.stub.Write(req, timeout=5)
        print("7 bogus write: ACCEPTED (unexpected)")
    except grpc.RpcError as e:
        print("7 bogus write -> RpcError code=%s details=%r" % (e.code().name, e.details()))
finally:
    c.stop()
print("done")
