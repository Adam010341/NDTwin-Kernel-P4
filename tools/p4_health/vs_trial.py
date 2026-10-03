#!/usr/bin/env python3
"""Does a P4Runtime ValueSetEntry write kill a simple_switch_grpc? Asked of a throwaway switch.

[Co-developed with claude code -- Adam]

VS1 (Q3(b)) would have controller B write a ValueSetEntry on a fabric switch in Cut 2. The thrift
route (`pvs_add`) aborts the stock bmv2 (parser.cpp:535, seen in Cut 1), so before anything
writes one on the fabric this asks the same question of a throwaway `simple_switch_grpc`, under
throwaway.py's rules: pcap mode, no root, argv[0] `ndt-hc-vstrial-bmv2`, Thrift 29500-29599, gRPC
29650-29699 (never the lab's 30051+), stopped by pid.

    p4_proxy/venv/bin/python tools/p4_health/vs_trial.py <build dir> <out.json> [bmv2 ...]

For each bmv2 binary given (default: the stock /usr/local/bin/simple_switch_grpc and the one
p4_proxy/mininet/bmv2_binary_override names): push hc_main's pipeline, write ONE member into
HcParser.vs_ports, read the value set back over P4Runtime, and record whether the process is
still alive afterwards and what its last log lines say.
"""
import json
import os
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from p4_health import throwaway as TW  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CPU = 510
VALUE = 40055


def fabric_binary():
    path = os.path.join(REPO, "p4_proxy", "mininet", "bmv2_binary_override")
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    return None


def batch_errors(exc):
    """The per-update p4.v1.Error list a Write's UNKNOWN status carries in its trailing metadata."""
    from google.rpc import status_pb2
    from p4.v1 import p4runtime_pb2
    out = []
    for key, value in (exc.trailing_metadata() or ()):
        if key != "grpc-status-details-bin":
            continue
        st = status_pb2.Status()
        st.ParseFromString(value)
        for detail in st.details:
            err = p4runtime_pb2.Error()
            if detail.Unpack(err):
                out.append({"canonical_code": err.canonical_code, "message": err.message,
                            "space": err.space, "code": err.code})
    return out


def trial(build, bmv2, cli_argv, workroot):
    import grpc
    from google.protobuf import text_format
    from p4.config.v1 import p4info_pb2
    from p4.v1 import p4runtime_pb2, p4runtime_pb2_grpc

    info_path = os.path.join(build, "hc_main.p4.p4info.txtpb")
    p4info = p4info_pb2.P4Info()
    with open(info_path) as fh:
        text_format.Merge(fh.read(), p4info)
    vs = [v for v in p4info.value_sets if v.preamble.name == "HcParser.vs_ports"][0]
    work = os.path.join(workroot, os.path.basename(os.path.dirname(os.path.dirname(bmv2))) or "sw")
    os.makedirs(work, exist_ok=True)
    sw = TW.Throwaway(os.path.join(build, "hc_main.json"), {1: [], 2: []}, CPU, cli_argv, wait_s=2,
                      bmv2=bmv2, workdir=work, argv0="ndt-hc-vstrial-bmv2", grpc=True)
    out = {"bmv2": bmv2, "argv0": sw.argv0}
    sw.start()
    out.update({"thrift_port": sw.thrift_port, "grpc_port": sw.grpc_port, "device_id": TW.DEVICE_ID})
    try:
        if not TW.outside_lab_ports(sw.grpc_port):
            raise TW.ThrowawayError("gRPC port %d is a lab port" % sw.grpc_port)
        chan = grpc.insecure_channel("127.0.0.1:%d" % sw.grpc_port)
        stub = p4runtime_pb2_grpc.P4RuntimeStub(chan)
        eid = p4runtime_pb2.Uint128(high=0, low=1)

        def reqs():
            r = p4runtime_pb2.StreamMessageRequest()
            r.arbitration.device_id = TW.DEVICE_ID
            r.arbitration.election_id.CopyFrom(eid)
            yield r
            time.sleep(8)
        stream = stub.StreamChannel(reqs())
        first = next(stream)
        out["arbitration"] = text_format.MessageToString(first.arbitration, as_one_line=True)
        cfg = p4runtime_pb2.SetForwardingPipelineConfigRequest(
            device_id=TW.DEVICE_ID, election_id=eid,
            action=p4runtime_pb2.SetForwardingPipelineConfigRequest.VERIFY_AND_COMMIT)
        cfg.config.p4info.CopyFrom(p4info)
        with open(os.path.join(build, "hc_main.json"), "rb") as fh:
            cfg.config.p4_device_config = fh.read()
        stub.SetForwardingPipelineConfig(cfg, timeout=20)
        out["pipeline"] = "OK"
        w = p4runtime_pb2.WriteRequest(device_id=TW.DEVICE_ID, election_id=eid)
        u = w.updates.add()
        u.type = p4runtime_pb2.Update.INSERT
        e = u.entity.value_set_entry
        e.value_set_id = vs.preamble.id
        m = e.members.add().match.add()
        m.field_id = vs.match[0].id
        m.exact.value = VALUE.to_bytes(2, "big")
        try:
            stub.Write(w, timeout=20)
            out["write"] = "OK"
        except grpc.RpcError as exc:
            out["write"] = "%s: %s" % (exc.code().name, (exc.details() or "")[:300])
            out["write_errors"] = batch_errors(exc)
        time.sleep(1.0)
        out["pvs_get_after_write"] = sw.cli(["pvs_get HcParser.vs_ports"]).splitlines()[-3:] if sw.alive() else None
        out["alive_after_write"] = sw.alive()
        if sw.alive():
            rd = p4runtime_pb2.ReadRequest(device_id=TW.DEVICE_ID)
            rd.entities.add().value_set_entry.value_set_id = vs.preamble.id
            try:
                got = [text_format.MessageToString(ent, as_one_line=True)
                       for resp in stub.Read(rd, timeout=20) for ent in resp.entities]
                out["read_back"] = got
            except grpc.RpcError as exc:
                out["read_back"] = "%s: %s" % (exc.code().name, (exc.details() or "")[:300])
            out["alive_after_read"] = sw.alive()
        chan.close()
    finally:
        out["exit_status"] = sw.stop()
        with open(os.path.join(work, "stdout.txt"), errors="replace") as fh:
            out["stdout_tail"] = fh.read().splitlines()[-4:]
    return out


def main(argv):
    build, dest = argv[0], argv[1]
    bins = argv[2:] or ["/usr/local/bin/simple_switch_grpc", fabric_binary()]
    from p4_health.collect.config import default_p4dev_python
    cli = [default_p4dev_python(), "/usr/local/bin/simple_switch_CLI"]
    workroot = os.path.join(os.path.dirname(os.path.abspath(dest)), "vs_trial_work")
    results = []
    for b in bins:
        try:
            results.append(trial(build, b, cli, workroot))
        except Exception as exc:  # noqa: BLE001 -- recorded, the next binary still runs
            results.append({"bmv2": b, "error": "%s: %s" % (type(exc).__name__, exc)})
    with open(dest, "w") as fh:
        json.dump(results, fh, indent=2)
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
