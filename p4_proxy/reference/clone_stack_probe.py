#!/usr/bin/env python3
"""
Clone-session stacking probe: does a pipeline re-commit orphan the PRE group?

[Co-developed with claude code -- Adam]

Third-party repro for the 2026-08-16 reconciliation finding (proxy restart x warm
fabric = telemetry xN): shares no request-building code with proxy_agent/p4_client.py --
raw grpc plus the stock p4.v1 protobufs only, the same discipline (and stream machinery)
as p4runtime_mastership_probe.py. A repro written on top of the suspect client proves
nothing; this one exists so the claim can go upstream.

The claim under test (the PRE-RUN hypothesis, phrased against bmv2/PI internals):
  SetForwardingPipelineConfig(VERIFY_AND_COMMIT) empties the P4Runtime server's
  clone-session bookkeeping, but the multicast group backing the session
  (mgid 0x8000+session) survives in the target PRE. The next INSERT of the same
  session then succeeds -- no duplicate status -- and APPENDS another replica to the
  surviving group. A DELETE issued after the commit is answered NOT_FOUND and never
  reaches the orphaned group, so the stacking is unreachable from the clone-session API.

What the run actually recorded (2026-08-16; full output in
doc/audit/2026-08-16_clone-stacking-raw-repro.md). The stacking half held; two details
of the paragraph above did NOT, and both were written into the fix:
  - the post-commit DELETE answers UNKNOWN with EMPTY DETAILS, not NOT_FOUND. The
    NOT_FOUND was an inference from a caller that never logged a code -- fourth instance
    of bmv2's UNKNOWN-for-everything vocabulary. The effective claim (that DELETE cannot
    reach the orphan from the emptied-bookkeeping state) is unaffected.
  - "unreachable from the clone-session API" is too broad: phase e shows a DELETE issued
    while the bookkeeping still HOLDS the session destroys the whole backing group,
    accumulated replicas included. That is exactly what the settle pair in
    p4_client.write_clone_session (79e4f69) exploits to heal.
Upstream status: material is upstream-grade but NOT filed -- archived by Adam's ruling
of 2026-08-17. Keep this file as the reproduction of record.

Phases -- run one per invocation; each arbitrates (0,1) afresh, which is valid because
every earlier client is gone by then (all-controllers-offline rebid, measured during C8):

  a  gen-1 boot     : push pipeline, INSERT session 250 -> expect OK; PRE should show 1 node
  b  control        : NO push, duplicate INSERT           -> expect UNKNOWN, PRE unchanged
                      (isolates the trigger: a restart alone does not stack -- the commit does)
  c  gen-2 restart  : push pipeline, INSERT               -> expect OK again; PRE 2 nodes
  d  gen-3 restart  : push pipeline, DELETE, INSERT       -> DELETE expect a failure
                      (predicted NOT_FOUND, measured UNKNOWN ''), INSERT OK; PRE 3 nodes
                      (the DELETE-first ceiling, live round shape)
  e  diagnostic     : NO push, DELETE                     -> status + what PRE does with the
                      group; answers whether the API can reach the orphans at all

The PRE ground truth is read between phases by the harness (thrift mirroring_get/mc_dump),
not here: this file stays a pure P4Runtime client so the observation channel is
independent of the actor.

Usage:
    p4_proxy/venv/bin/python p4_proxy/reference/clone_stack_probe.py --phase a [--device-id 1] [--addr ...]
"""

import argparse
import queue
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

SESSION_ID = 250
CPU_PORT = 255

RPC_CODE = {0: "OK", 3: "INVALID_ARGUMENT", 5: "NOT_FOUND", 6: "ALREADY_EXISTS",
            7: "PERMISSION_DENIED", 9: "FAILED_PRECONDITION", 10: "ABORTED"}


class RawStream:
    """As p4runtime_mastership_probe.RawStream: bid an election id, hold the stream open."""

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
            self.stream_err = e
            self._arb_seen.set()

    def wait_arbitration(self, timeout=5.0):
        self._arb_seen.wait(timeout)
        return self.last_arb

    def stop(self):
        self._running = False
        self._out.put(None)
        if self._thread.is_alive():
            self._thread.join(timeout=3.0)


def clone_session_write(stub, device_id, update_type):
    req = p4runtime_pb2.WriteRequest()
    req.device_id = device_id
    req.election_id.low = 1
    update = req.updates.add()
    update.type = update_type
    session = update.entity.packet_replication_engine_entry.clone_session_entry
    session.session_id = SESSION_ID
    session.class_of_service = 0
    session.packet_length_bytes = 0
    replica = session.replicas.add()
    replica.egress_port = CPU_PORT
    replica.instance = 1
    return stub.Write(req, timeout=5)


def attempt(label, fn):
    try:
        fn()
        print(f"  {label}: OK")
        return "OK"
    except grpc.RpcError as e:
        print(f"  {label}: {e.code().name} details={e.details()!r}")
        return e.code().name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", required=True, choices=list("abcde"))
    ap.add_argument("--device-id", type=int, default=1)
    ap.add_argument("--addr", default="127.0.0.1:50051")
    args = ap.parse_args()

    with open(P4INFO_PATH) as f:
        p4info = p4info_pb2.P4Info()
        text_format.Merge(f.read(), p4info)
    with open(JSON_PATH, "rb") as f:
        device_config = f.read()

    chan = grpc.insecure_channel(args.addr,
                                 options=[("grpc.use_local_subchannel_pool", 1)])
    stub = p4runtime_pb2_grpc.P4RuntimeStub(chan)

    stream = RawStream(stub, args.device_id, 0, 1)
    stream.start()
    arb = stream.wait_arbitration()
    code = arb.status.code if arb is not None else None
    print(f"phase {args.phase}: arbitration code={code} ({RPC_CODE.get(code, '?')})")
    if code != 0:
        print("  not primary; aborting phase")
        stream.stop()
        sys.exit(2)
    time.sleep(0.3)  # mastership settle, as the proxy allows

    def push():
        req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
        req.device_id = args.device_id
        req.election_id.low = 1
        req.action = p4runtime_pb2.SetForwardingPipelineConfigRequest.VERIFY_AND_COMMIT
        req.config.p4info.CopyFrom(p4info)
        req.config.p4_device_config = device_config
        stub.SetForwardingPipelineConfig(req, timeout=10)

    if args.phase == "a":
        attempt("push pipeline (gen-1)", push)
        attempt("INSERT clone session", lambda: clone_session_write(
            stub, args.device_id, p4runtime_pb2.Update.INSERT))
    elif args.phase == "b":
        attempt("duplicate INSERT, no push (control)", lambda: clone_session_write(
            stub, args.device_id, p4runtime_pb2.Update.INSERT))
    elif args.phase == "c":
        attempt("push pipeline (gen-2)", push)
        attempt("INSERT clone session", lambda: clone_session_write(
            stub, args.device_id, p4runtime_pb2.Update.INSERT))
    elif args.phase == "d":
        attempt("push pipeline (gen-3)", push)
        attempt("DELETE clone session", lambda: clone_session_write(
            stub, args.device_id, p4runtime_pb2.Update.DELETE))
        attempt("INSERT clone session", lambda: clone_session_write(
            stub, args.device_id, p4runtime_pb2.Update.INSERT))
    elif args.phase == "e":
        attempt("DELETE clone session, no push (diagnostic)", lambda: clone_session_write(
            stub, args.device_id, p4runtime_pb2.Update.DELETE))

    stream.stop()
    chan.close()


if __name__ == "__main__":
    main()
