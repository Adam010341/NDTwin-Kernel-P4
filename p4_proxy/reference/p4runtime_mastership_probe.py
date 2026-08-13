#!/usr/bin/env python3
"""
Mastership probe: what bmv2 really does with SetForwardingPipelineConfig.

[Co-developed with claude code -- Adam]

This script settled the "bmv2 accepts a pipeline push from a non-primary client"
question by running the three cases apart from each other. Result: bmv2 is
spec-conforming in all three, and the destructive readopt we saw on 2026-08-13 was
caused by *our* client reusing the primary's election id. The write-up is
doc/2026-08-13_p4runtime-mastership-spec-check.md.

It is kept because the question will come back the moment anyone reads the old
audit reports, and because the three scenarios are the cheapest way to re-derive
the answer against a future bmv2.

Deliberately a third-party client: it shares no request-building code with
proxy_agent/p4_client.py, only raw grpc plus the stock p4.v1 protobufs. That is
the whole point -- a repro written on top of the suspect client proves nothing.

Why not p4lang/tutorials' p4runtime_lib: its MasterArbitrationUpdate() blocks
forever here. bmv2 terminates a duplicate-election-id stream (P4Runtime spec:
"shall terminate the stream by returning an INVALID_ARGUMENT error") and that
library waits for a reply that never arrives. This client drives its own stream
loop, so a killed stream is an observation instead of a hang.

The three scenarios
-------------------
  1  genuine non-primary : A(0,2) is primary, B(0,1) is a backup. B pushes.
                           -> PERMISSION_DENIED. bmv2 DOES check mastership.
  2  duplicate election  : O(0,1) is primary, D(0,1) duplicates it. D pushes.
                           -> accepted, and it WIPES the tables. D's Write is
                              accepted too, so there is no "Write is checked but
                              the push is not" asymmetry.
  3  ordering            : scenario 2, then close O's stream, then D writes.
                           -> PERMISSION_DENIED. This is the readopt log: the
                              push is accepted while the real primary is alive,
                              and the route writes are refused only because
                              topology_manager closes it in between
                              (old.stop() at :831 runs before
                              install_initial_routes() at :836).

Why scenario 2 is not a bmv2 bug: the spec identifies the client of a unary RPC
by the (device_id, role, election_id) carried *in the request message* -- "A
server must use all three of these values from a WriteRequest message to identify
which client is making the WriteRequest, not only the election_id" -- not by the
connection it arrived on. A client presenting the primary's 3-tuple is the
primary as far as the server can tell. p4_client.py hardcodes election_id (0,1)
for every client it builds, so readopt's "fresh" client presents the incumbent's
credentials exactly.

⚠️ DESTRUCTIVE. Scenarios 2 and 3 push VERIFY_AND_COMMIT, which clears every
table on the target device. Point it at scratch switches, never at a fabric whose
state you care about. Each scenario uses its own device so they cannot alias.

Usage (needs the proxy venv -- the system python3 has no grpc):
    p4_proxy/venv/bin/python p4_proxy/reference/p4runtime_mastership_probe.py --scenario all
    ... --scenario 1 --device-id 1 --addr 127.0.0.1:50051
"""

import argparse
import queue
import socket
import sys
import threading
import time

import grpc
from google.protobuf import text_format
from p4.config.v1 import p4info_pb2
from p4.v1 import p4runtime_pb2, p4runtime_pb2_grpc

BUILD = "/home/adam/Desktop/NDTwin-Kernel/p4_proxy/p4_src/build"
P4INFO_PATH = f"{BUILD}/ndtwin_switch.p4info.txt"
JSON_PATH = f"{BUILD}/ndtwin_switch.json"

# google.rpc.Code names. The arbitration status is a google.rpc.Status, whose
# numeric code has no generated enum here, and a bare integer in a transcript is
# unreadable a week later.
RPC_CODE = {0: "OK", 3: "INVALID_ARGUMENT", 5: "NOT_FOUND", 6: "ALREADY_EXISTS",
            7: "PERMISSION_DENIED", 9: "FAILED_PRECONDITION", 10: "ABORTED"}


def load_p4info(path=P4INFO_PATH):
    p4info = p4info_pb2.P4Info()
    with open(path) as f:
        text_format.Merge(f.read(), p4info)
    return p4info


class RawStream:
    """One hand-driven StreamChannel: bid an election id, then hold the stream open.

    Holding it open is what makes the scenarios mean anything -- mastership lasts
    exactly as long as the stream, so a client that opens and closes a stream is
    not a primary afterwards. stop() is therefore an experimental step, not
    cleanup (scenario 3 uses it as the independent variable).
    """

    def __init__(self, stub, device_id, election_high, election_low):
        self.stub = stub
        self.device_id = device_id
        self.eh = election_high
        self.el = election_low
        self._out = queue.Queue()
        self._running = True
        self.last_arb = None
        self._arb_seen = threading.Event()
        self.stream_err = None

    def _iterator(self):
        req = p4runtime_pb2.StreamMessageRequest()
        req.arbitration.device_id = self.device_id
        req.arbitration.election_id.high = self.eh
        req.arbitration.election_id.low = self.el
        yield req
        while self._running:
            try:
                msg = self._out.get(timeout=0.5)
                if msg is None:
                    return
                yield msg
            except queue.Empty:
                continue

    def start(self):
        self._resp = self.stub.StreamChannel(self._iterator())
        self._thread = threading.Thread(target=self._recv, daemon=True)
        self._thread.start()

    def _recv(self):
        try:
            for resp in self._resp:
                if resp.HasField("arbitration"):
                    self.last_arb = resp.arbitration
                    self._arb_seen.set()
        except grpc.RpcError as e:
            # A terminated stream is a result here, not an error: it is how bmv2
            # answers a duplicate election id.
            self.stream_err = e
            self._arb_seen.set()

    def wait_arbitration(self, timeout=5.0):
        self._arb_seen.wait(timeout)
        return self.last_arb

    @property
    def alive(self):
        return self.stream_err is None and self._thread.is_alive()

    def describe(self):
        if self.last_arb is not None:
            code = self.last_arb.status.code
            out = (f"arbitration code={code} ({RPC_CODE.get(code, '?')}) "
                   f"message={self.last_arb.status.message!r}")
        else:
            out = "arbitration (no reply)"
        if self.stream_err is not None:
            out += (f" | STREAM TERMINATED {self.stream_err.code().name}: "
                    f"{self.stream_err.details()!r}")
        else:
            out += f" | stream {'alive' if self.alive else 'closed'}"
        return out

    def stop(self):
        self._running = False
        self._out.put(None)
        if self._thread.is_alive():
            self._thread.join(timeout=3.0)


def channel(addr):
    # Same option the proxy uses; a shared subchannel pool would let one scenario's
    # reconnect backoff leak into the next.
    return grpc.insecure_channel(addr, options=[("grpc.use_local_subchannel_pool", 1)])


def set_pipeline(stub, device_id, p4info, device_config, election_low):
    req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
    req.device_id = device_id
    req.election_id.high = 0
    req.election_id.low = election_low
    req.action = p4runtime_pb2.SetForwardingPipelineConfigRequest.VERIFY_AND_COMMIT
    req.config.p4info.CopyFrom(p4info)
    req.config.p4_device_config = device_config
    return stub.SetForwardingPipelineConfig(req, timeout=10)


def write_route(stub, device_id, p4info, election_low, dst_ip):
    tables = {t.preamble.name: t for t in p4info.tables}
    actions = {a.preamble.name: a for a in p4info.actions}
    table = tables["MyIngress.ipv4_lpm"]
    action = actions["MyIngress.ipv4_forward"]

    req = p4runtime_pb2.WriteRequest()
    req.device_id = device_id
    req.election_id.high = 0
    req.election_id.low = election_low
    update = req.updates.add()
    update.type = p4runtime_pb2.Update.INSERT
    entry = update.entity.table_entry
    entry.table_id = table.preamble.id
    match = entry.match.add()
    match.field_id = next(m.id for m in table.match_fields if m.name == "hdr.ipv4.dstAddr")
    match.lpm.value = socket.inet_aton(dst_ip)
    match.lpm.prefix_len = 32
    act = entry.action.action
    act.action_id = action.preamble.id
    p_dst = act.params.add()
    p_dst.param_id = next(p.id for p in action.params if p.name == "dstAddr")
    p_dst.value = bytes.fromhex("000000000009")
    p_port = act.params.add()
    p_port.param_id = next(p.id for p in action.params if p.name == "port")
    p_port.value = (2).to_bytes(2, "big")
    return stub.Write(req, timeout=10)


def rpc(fn):
    """Runs an RPC and renders the outcome as a short string, never raising."""
    try:
        fn()
        return "OK"
    except grpc.RpcError as e:
        return f"{e.code().name}: {e.details() or '(no details)'}"


def pipeline_state(stub, device_id):
    req = p4runtime_pb2.GetForwardingPipelineConfigRequest()
    req.device_id = device_id
    req.response_type = p4runtime_pb2.GetForwardingPipelineConfigRequest.COOKIE_ONLY
    try:
        stub.GetForwardingPipelineConfig(req, timeout=5)
        return "pipeline present"
    except grpc.RpcError as e:
        return f"{e.code().name}: {e.details() or '(no details)'}"


def count_entries(stub, device_id):
    req = p4runtime_pb2.ReadRequest()
    req.device_id = device_id
    req.entities.add().table_entry.table_id = 0     # 0 = every table
    n = 0
    try:
        for resp in stub.Read(req, timeout=5):
            for ent in resp.entities:
                if ent.HasField("table_entry") and not ent.table_entry.is_default_action:
                    n += 1
    except grpc.RpcError as e:
        return f"(read failed {e.code().name})"
    return n


def scenario_1(addr, device_id, p4info, cfg):
    """Genuine non-primary. Expect PERMISSION_DENIED -- bmv2 does check."""
    print(f"\n{'=' * 78}\nSCENARIO 1  genuine non-primary  ({addr} device {device_id})")
    print(f"{'=' * 78}")
    ch_a, ch_b = channel(addr), channel(addr)
    stub_a = p4runtime_pb2_grpc.P4RuntimeStub(ch_a)
    stub_b = p4runtime_pb2_grpc.P4RuntimeStub(ch_b)

    print(f"[0] pipeline before : {pipeline_state(stub_a, device_id)}")
    A = RawStream(stub_a, device_id, 0, 2)
    A.start(); A.wait_arbitration()
    print(f"[1] A election (0,2): {A.describe()}")
    if A.last_arb is None or A.last_arb.status.code != 0:
        print("    ABORT: A is not primary; another controller may hold this device.")
        A.stop(); return None

    B = RawStream(stub_b, device_id, 0, 1)
    B.start(); B.wait_arbitration()
    print(f"[2] B election (0,1): {B.describe()}")
    # Only a confirmed backup makes the next line meaningful. Without this check a
    # B that quietly became primary would look like "bmv2 accepted a non-primary".
    if not ((B.last_arb is not None and B.last_arb.status.code != 0) and A.alive):
        print("    ABORT: B is not a confirmed backup.")
        A.stop(); B.stop(); return None
    print("    -> A primary, B non-primary, both streams open. Proceeding.")

    push = rpc(lambda: set_pipeline(stub_b, device_id, p4info, cfg, 1))
    print(f"[3] B pipeline push : {push}")
    print(f"[4] pipeline after  : {pipeline_state(stub_a, device_id)}")
    write = rpc(lambda: write_route(stub_b, device_id, p4info, 1, "10.5.5.5"))
    print(f"[5] B route write   : {write}")
    A.stop(); B.stop()

    ok = push.startswith("PERMISSION_DENIED") and write.startswith("PERMISSION_DENIED")
    print(f"\n  => {'as expected: bmv2 denies a genuine non-primary on BOTH RPCs'
                    if ok else 'UNEXPECTED -- read the lines above'}")
    return ok


def scenario_2(addr, device_id, p4info, cfg):
    """Duplicate election id. Expect both RPCs accepted, and a wiped table."""
    print(f"\n{'=' * 78}\nSCENARIO 2  duplicate election id  ({addr} device {device_id})")
    print(f"{'=' * 78}")
    ch_o, ch_d = channel(addr), channel(addr)
    stub_o = p4runtime_pb2_grpc.P4RuntimeStub(ch_o)
    stub_d = p4runtime_pb2_grpc.P4RuntimeStub(ch_d)

    O = RawStream(stub_o, device_id, 0, 1)
    O.start(); O.wait_arbitration()
    print(f"[1] O election (0,1): {O.describe()}")
    if O.last_arb is None or O.last_arb.status.code != 0:
        print("    ABORT: O is not primary."); O.stop(); return None
    print(f"[2] O pipeline push : {rpc(lambda: set_pipeline(stub_o, device_id, p4info, cfg, 1))}")
    print(f"[3] O route write   : {rpc(lambda: write_route(stub_o, device_id, p4info, 1, '10.7.7.7'))}")
    print(f"[4] entries now     : {count_entries(stub_o, device_id)}  (expect 1)")

    D = RawStream(stub_d, device_id, 0, 1)
    D.start(); D.wait_arbitration()
    print(f"[5] D election (0,1): {D.describe()}")
    print("    (this is readopt's state against a healthy switch: mastership NOT confirmed)")

    push = rpc(lambda: set_pipeline(stub_d, device_id, p4info, cfg, 1))
    print(f"[6] D pipeline push : {push}")
    entries = count_entries(stub_o, device_id)
    print(f"[7] entries now     : {entries}  (0 = the push wiped O's table)")
    write = rpc(lambda: write_route(stub_d, device_id, p4info, 1, "10.8.8.8"))
    print(f"[8] D route write   : {write}")
    O.stop(); D.stop()

    both = push == "OK" and write == "OK"
    print(f"\n  => {'both RPCs accepted: the election id, not the connection, is the credential'
                    if both else 'UNEXPECTED -- read the lines above'}")
    return both


def scenario_3(addr, device_id, p4info, cfg):
    """The readopt ordering. The primary's stream closes between the two RPCs."""
    print(f"\n{'=' * 78}\nSCENARIO 3  readopt ordering  ({addr} device {device_id})")
    print(f"{'=' * 78}")
    ch_o, ch_d = channel(addr), channel(addr)
    stub_o = p4runtime_pb2_grpc.P4RuntimeStub(ch_o)
    stub_d = p4runtime_pb2_grpc.P4RuntimeStub(ch_d)

    O = RawStream(stub_o, device_id, 0, 1)
    O.start(); O.wait_arbitration()
    print(f"[1] O (incumbent)   : {O.describe()}")
    if O.last_arb is None or O.last_arb.status.code != 0:
        print("    ABORT: O is not primary."); O.stop(); return None
    print(f"[2] O pipeline push : {rpc(lambda: set_pipeline(stub_o, device_id, p4info, cfg, 1))}")
    print(f"[3] O route write   : {rpc(lambda: write_route(stub_o, device_id, p4info, 1, '10.7.7.7'))}")

    D = RawStream(stub_d, device_id, 0, 1)
    D.start(); D.wait_arbitration()
    print(f"[4] D (readopt's)   : {D.describe()}")

    push = rpc(lambda: set_pipeline(stub_d, device_id, p4info, cfg, 1))
    print(f"[5] D push, O alive : {push}          <- topology_manager.py:809")
    O.stop()
    time.sleep(1.0)     # let bmv2 register the close before the next RPC
    print(f"[6] O.stop()        : O stream {'alive' if O.alive else 'closed'}"
          f"   <- topology_manager.py:831")
    write = rpc(lambda: write_route(stub_d, device_id, p4info, 1, "10.6.6.6"))
    print(f"[7] D write, O gone : {write}   <- topology_manager.py:836")
    D.stop()

    confirmed = push == "OK" and write.startswith("PERMISSION_DENIED")
    print(f"\n  => {'confirmed: the refusal follows the primary leaving, not the RPC kind'
                    if confirmed else 'NOT confirmed -- the readopt log needs another explanation'}")
    return confirmed


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--scenario", choices=["1", "2", "3", "all"], default="all")
    ap.add_argument("--addr", default=None,
                    help="override the gRPC address (default: 127.0.0.1:5005<device_id>)")
    ap.add_argument("--device-id", type=int, default=None,
                    help="override the device (default: 1, 2, 3 per scenario)")
    args = ap.parse_args()

    p4info = load_p4info()
    with open(JSON_PATH, "rb") as f:
        cfg = f.read()

    # A device each, so a wipe in one scenario cannot be mistaken for a result in
    # the next. bmv2's gRPC port convention here is 50050 + device_id.
    plan = {"1": (scenario_1, 1), "2": (scenario_2, 2), "3": (scenario_3, 3)}
    wanted = ["1", "2", "3"] if args.scenario == "all" else [args.scenario]

    results = {}
    for key in wanted:
        fn, default_dev = plan[key]
        dev = args.device_id if args.device_id is not None else default_dev
        addr = args.addr or f"127.0.0.1:{50050 + dev}"
        results[key] = fn(addr, dev, p4info, cfg)

    print(f"\n{'=' * 78}\nSUMMARY")
    labels = {"1": "genuine non-primary denied (spec-conforming)",
              "2": "duplicate election id accepted on both RPCs",
              "3": "refusal follows the primary's departure"}
    for key in wanted:
        got = results[key]
        mark = "yes" if got else ("no" if got is False else "inconclusive")
        print(f"  scenario {key}: {mark:13s} {labels[key]}")
    print("=" * 78)
    return 0 if all(results.get(k) for k in wanted) else 1


if __name__ == "__main__":
    sys.exit(main())
