#!/usr/bin/env python3
"""offline int-v1: does the converted package's s1 load, take every entry, and do what int-v1 does?

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python offline_int_v1.py <bmv2 simple_switch_grpc> <simple_switch_CLI> \
        <worktree> <package dir> <app dir> <out dir>

One throwaway simple_switch_grpc at a time (tools/p4_health/throwaway.py: no root, argv[0]
ndt-hc-*, ports outside the lab's checked free right before the launch, the device id confirmed by
switch_info, stopped by its own pid), pcap mode with `--use-files`, so frames go in on a port and
come out of a pcap with no namespace and no sudo.

The pipeline goes in the way a bring-up puts it in -- the proxy's own P4RuntimeClient, a
SetForwardingPipelineConfig of the package's build/int.json + build/int.p4.p4info.txt -- and the
package's entries the way `main.apply_package_entries` writes them (main.py:622-670): one
`write_table_entry` per entry under `entry_source(ENTRY_SOURCE_BOOT)`, one refusal not stopping
the rest. The route binding is None, which is what `main.route_binding_for` returns for a foreign
pipeline whose package declares no roles (main.py:301-320).

Four arms, the same four frames into each:

  A  translated   the converted package's s1 runtime file (the app's ipv4_lpm entries plus the
                  two entries translated from runtime_cmds/s1.sh), all through P4Runtime.
  B  thrift       the APP's own linear-topo/s1-runtime.json through P4Runtime, then the app's two
                  CLI lines, read out of runtime_cmds/s1.sh by a regex of this file's own (not
                  thrift_cli), through simple_switch_CLI on the throwaway's thrift port -- i.e.
                  what `make run` + runtime_cmd.sh do to s1, on the same pipeline.
  D  thrift, priority probe  the app's runtime file, then three CLI lines: set_source, Y (a /16
                  pair, CLI priority 2, hop_metadata_len 2) and X (the app's /24 pair, CLI
                  priority 1, hop_metadata_len 1), inserted Y first. A frame both match carries
                  the winner's hop_metadata_len in its INT header -- the CLI's priority
                  direction, read off the wire rather than assumed.
  E  translated, priority probe  the same three lines through thrift_cli and P4Runtime.

Verdicts (each printed with its evidence):
  P1  the pipeline push is accepted (A, B, D, E)
  P2  every package entry is accepted and read back with the same match, action and params
  P3  B's thrift-installed tb_int_source / tb_set_source read back over P4Runtime with the same
      match, action and params as A's translated ones (priorities printed side by side)
  P4  A's frames out == B's frames out, byte for byte, on every port
  P5  A's f1 out == the INT frame int-v1's source computes (int_source.p4:21-53), built here
      from the input bytes; f2-f4 come out with no INT header
  P6  D's f1 carries hop_metadata_len 1 (CLI priority 1 beat 2: the lower number wins), and
      E's frames out == D's, byte for byte
"""
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import time

BMV2, CLI, WT, PKG, APP, OUT = (os.path.abspath(a) for a in sys.argv[1:7])
sys.path.insert(0, os.path.join(WT, "p4_proxy"))
sys.path.insert(0, os.path.join(WT, "tools"))

from p4_exercise import thrift_cli  # noqa: E402
from p4_health import frames as F  # noqa: E402
from p4_health import throwaway as TW  # noqa: E402
from p4_health.collect.config import default_p4dev_python  # noqa: E402
from proxy_agent import p4_client as p4_client_module  # noqa: E402
from proxy_agent.p4_client import P4RuntimeClient  # noqa: E402

JSON = os.path.join(PKG, "build", "int.json")
INFO = os.path.join(PKG, "build", "int.p4.p4info.txt")
CPU = 255
ELECTION = (0, 65535)          # the package's control_plane.election_id
TAG = "fast" if "bmv2-fast" in BMV2 else "stock"
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "offline_%s.log" % TAG), "w")


def w(msg=""):
    print(msg, flush=True)
    LOG.write(msg + "\n")
    LOG.flush()


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def hexify(obj):
    if isinstance(obj, bytes):
        return obj.hex()
    if isinstance(obj, dict):
        return {k: hexify(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [hexify(v) for v in obj]
    return obj


# --- frames ------------------------------------------------------------------------------------

H1_MAC, H2_MAC = "08:00:00:00:01:11", "08:00:00:00:02:22"


def icmp_echo(src_mac, dst_mac, src_ip, dst_ip, ident=0x1234, seq=1):
    """An ICMP echo request, as `ping` sends one (built here; frames.py has no ICMP)."""
    data = b"int-v1 offline ping".ljust(32, b".")
    head = struct.pack("!BBHHH", 8, 0, 0, ident, seq)
    csum = F.checksum16(head + data)
    icmp = struct.pack("!BBHHH", 8, 0, csum, ident, seq) + data
    ip = F.ipv4_header(src_ip, dst_ip, 1, len(icmp))
    return F.ethernet(dst_mac, src_mac, F.ETH_IPV4, ip + icmp)


FRAMES = {
    # send.py's frame: Ether(dst=08:00:00:00:02:22)/IP(dst=10.0.2.2)/UDP(8001, 8002)
    "f1": (1, F.udp_marker(H1_MAC, H2_MAC, "10.0.1.1", "10.0.2.2", 8002, sport=8001,
                           run_id="intv1", cell="f1")),
    # not from 10.0.1.0/24: the app's source entry does not match
    "f2": (1, F.udp_marker(H1_MAC, H2_MAC, "10.0.9.9", "10.0.2.2", 8002, sport=8001,
                           run_id="intv1", cell="f2")),
    # in on port 2: not an INT source port
    "f3": (2, F.udp_marker(H2_MAC, H1_MAC, "10.0.2.2", "10.0.1.1", 8002, sport=8001,
                           run_id="intv1", cell="f3")),
    # to 10.0.3.3: forwarded (s1 sends it to port 2) but not in the app's 10.0.2.0/24
    "f4": (1, F.udp_marker(H1_MAC, H2_MAC, "10.0.1.1", "10.0.3.3", 8002, sport=8001,
                           run_id="intv1", cell="f4")),
    # h1 pings h2. The source entry's two L4 keys are don't-care, so an ICMP echo matches too,
    # and with no UDP/TCP header valid the deparser puts the INT shim straight after IPv4
    # (parser.p4:96-116) -- read as: int-v1's own fabric breaks ping between h1 and h2.
    "f5": (1, icmp_echo(H1_MAC, H2_MAC, "10.0.1.1", "10.0.2.2")),
}


def inputs():
    out = {}
    for _name, (port, frame) in sorted(FRAMES.items()):
        out.setdefault(port, []).append(frame)
    return out


def expected_int_frame(frame, dst_mac, hop_ml, rhc, mask0003, mask0407):
    """int_source.p4:21-53 + fwd.p4 ipv4_forward, applied to `frame` by hand.

    Ethernet dst <- the route's dst_addr (src unchanged); ttl - 1; DSCP <- 0x17; ipv4.len += 12
    and the header checksum recomputed (int.p4 MyComputeChecksum); udp.length_ += 12, the UDP
    checksum untouched; after the UDP header, the 4-byte shim (int_type 1, len 3, dscp = the
    ORIGINAL dscp) and the 8-byte INT header (hop_metadata_len, remaining_hop_cnt, the two
    instruction masks, everything else 0); then the rest of the frame as it came in.
    """
    eth, ip, rest = frame[:14], bytearray(frame[14:34]), frame[34:]
    udp, payload = bytearray(rest[:8]), rest[8:]
    orig_dscp = ip[1] >> 2
    ip[1] = (0x17 << 2) | (ip[1] & 0x3)
    ip[2:4] = struct.pack("!H", struct.unpack("!H", bytes(ip[2:4]))[0] + 12)
    ip[8] -= 1
    ip[10:12] = b"\0\0"
    ip[10:12] = struct.pack("!H", F.checksum16(bytes(ip)))
    udp[4:6] = struct.pack("!H", struct.unpack("!H", bytes(udp[4:6]))[0] + 12)
    shim = bytes([1, 0, 3, (orig_dscp << 2) & 0xFC])
    header = bytes([0, 0, hop_ml & 0x1F, rhc, ((mask0003 & 0xF) << 4) | (mask0407 & 0xF),
                    0, 0, 0])
    return F.mac_bytes(dst_mac) + eth[6:] + bytes(ip) + bytes(udp) + shim + header + payload


def expected_int_after_ip(frame, dst_mac, hop_ml, rhc, mask0003, mask0407):
    """The same INT source, on a frame with no TCP/UDP header: shim + INT header right after
    IPv4, ipv4.len += 12, nothing after it rewritten."""
    eth, ip, rest = frame[:14], bytearray(frame[14:34]), frame[34:]
    orig_dscp = ip[1] >> 2
    ip[1] = (0x17 << 2) | (ip[1] & 0x3)
    ip[2:4] = struct.pack("!H", struct.unpack("!H", bytes(ip[2:4]))[0] + 12)
    ip[8] -= 1
    ip[10:12] = b"\0\0"
    ip[10:12] = struct.pack("!H", F.checksum16(bytes(ip)))
    shim = bytes([1, 0, 3, (orig_dscp << 2) & 0xFC])
    header = bytes([0, 0, hop_ml & 0x1F, rhc, ((mask0003 & 0xF) << 4) | (mask0407 & 0xF),
                    0, 0, 0])
    return F.mac_bytes(dst_mac) + eth[6:] + bytes(ip) + shim + header + rest


def expected_plain_frame(frame, dst_mac):
    eth, ip, rest = frame[:14], bytearray(frame[14:34]), frame[34:]
    ip[8] -= 1
    ip[10:12] = b"\0\0"
    ip[10:12] = struct.pack("!H", F.checksum16(bytes(ip)))
    return F.mac_bytes(dst_mac) + eth[6:] + bytes(ip) + rest


def int_fields(frame):
    """(dscp, hop_metadata_len) of an IPv4/UDP frame, hop_ml None when there is no INT (or the
    frame is not UDP, where the shim sits elsewhere)."""
    dscp = frame[15] >> 2
    if dscp != 0x17 or len(frame) < 54 or frame[23] != 17:
        return dscp, None
    return dscp, frame[34 + 8 + 4 + 2] & 0x1F


# --- one arm -----------------------------------------------------------------------------------

def app_runtime_entries():
    with open(os.path.join(APP, "linear-topo", "s1-runtime.json")) as fh:
        return json.load(fh)["table_entries"]


def package_runtime_entries():
    with open(os.path.join(PKG, "package.json")) as fh:
        rel = json.load(fh)["switches"]["1"]["entries"]
    with open(os.path.join(PKG, rel)) as fh:
        return json.load(fh)["table_entries"]


def app_cli_lines():
    """The app's CLI commands, by a regex of this file's own -- not thrift_cli's extractor."""
    with open(os.path.join(APP, "runtime_cmds", "s1.sh")) as fh:
        return re.findall(r'<<<\s*"([^"]*)"', fh.read())


PROBE_Y = ("table_add tb_int_source int_source_dscp 10.0.0.0&&&0xFFFF0000 10.0.0.0&&&0xFFFF0000 "
           "0&&&0 0&&&0 => 2 4 0xF 0xF 2")
PROBE_X = ("table_add tb_int_source int_source_dscp 10.0.1.0&&&0xFFFFFF00 10.0.2.0&&&0xFFFFFF00 "
           "0&&&0 0&&&0 => 1 4 0xF 0xF 1")


def run_arm(label, p4rt_entries, cli_lines):
    work = os.path.join(OUT, TAG, label)
    os.makedirs(work, exist_ok=True)
    cli_argv = [default_p4dev_python(), CLI]
    sw = TW.Throwaway(JSON, inputs(), CPU, cli_argv, wait_s=10, bmv2=BMV2, workdir=work,
                      argv0="ndt-hc-paperapps-bmv2", grpc=True)
    res = {"arm": label, "written": [], "refused": [], "cli": None}
    w("\n=== arm %s (%s) ===" % (label, TAG))
    sw.start()
    try:
        w("bmv2 up: pid %d grpc 127.0.0.1:%d thrift %d device_id %d" %
          (sw.proc.pid, sw.grpc_port, sw.thrift_port, TW.DEVICE_ID))
        w("argv: %s" % " ".join(sw.argv))
        client = P4RuntimeClient(device_id=TW.DEVICE_ID, grpc_addr="127.0.0.1:%d" % sw.grpc_port,
                                 p4info_path=INFO, json_path=JSON, election_id=ELECTION)
        client.bind_routes(None)
        client.start(push_config=False)
        time.sleep(1.0)
        try:
            client.set_forwarding_pipeline_config()
            res["pipeline"] = "accepted"
        except Exception as exc:  # noqa: BLE001 -- recorded, the verdict reads it
            res["pipeline"] = "REFUSED: %s: %s" % (type(exc).__name__, exc)
        w("P1 pipeline push: %s" % res["pipeline"])
        for i, spec in enumerate(p4rt_entries):
            try:
                with p4_client_module.entry_source(p4_client_module.ENTRY_SOURCE_BOOT):
                    client.write_table_entry(spec, spec.get("op", "insert"))
                res["written"].append(i)
            except Exception as exc:  # noqa: BLE001 -- one entry must not cost the others
                res["refused"].append({"index": i, "table": spec.get("table"),
                                       "error": "%s: %s" % (type(exc).__name__, exc)})
        w("P4Runtime entries: %d written, %d refused" % (len(res["written"]),
                                                         len(res["refused"])))
        for r in res["refused"]:
            w("   REFUSED %s" % r)
        if cli_lines:
            out = sw.install(cli_lines)
            res["cli"] = {"lines": cli_lines, "out": out}
            w("thrift CLI: %d line(s) installed" % len(cli_lines))
            for line in out.splitlines():
                if "handle" in line.lower() or "error" in line.lower():
                    w("   cli: %s" % line.strip())
        res["read"] = hexify(client.read_table_entries())
        w("read back: %d entr(ies)" % len(res["read"]))
        sw.wait_processed(settle_s=3.0)
        res["outputs"] = {str(p): [f.hex() for f in (frames or [])] if frames is not None
                          else None for p, frames in sw.outputs().items()}
        res["alive"] = sw.alive()
        client.stop()
    finally:
        rc = sw.stop()
        res["stopped_rc"] = rc
        w("stopped pid %d rc=%s" % (sw.proc.pid, rc))
    return res


def readback_key(entry):
    return (entry["table"], json.dumps(entry["match"], sort_keys=True),
            json.dumps(entry["action"], sort_keys=True), entry["is_default"])


def main():
    w("offline int-v1 -- %s" % time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    ver = subprocess.run([BMV2, "--version"], capture_output=True, text=True)
    w("bmv2   : %s sha256 %s  --version: %s" % (BMV2, sha(BMV2), (ver.stdout or ver.stderr).strip()))
    w("CLI    : %s sha256 %s" % (CLI, sha(CLI)))
    head = subprocess.run(["git", "-C", WT, "rev-parse", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", WT, "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True)
    w("tree   : %s HEAD %s, %d tracked file(s) modified%s" % (
        WT, head.stdout.strip(), len(dirty.stdout.splitlines()),
        (": " + ", ".join(l[3:] for l in dirty.stdout.splitlines())) if dirty.stdout else ""))
    w("package: %s  int.json %s  p4info %s" % (PKG, sha(JSON)[:16], sha(INFO)[:16]))
    w("app    : %s" % APP)

    pkg_entries = package_runtime_entries()
    app_entries = app_runtime_entries()
    cli = app_cli_lines()
    w("app CLI lines (regex): %s" % cli)
    schema = thrift_cli.schema_from_p4info_path(INFO)
    probe_cli = [cli[0], PROBE_Y, PROBE_X]
    probe_translated, probe_notes = thrift_cli.translate(list(enumerate(probe_cli, 1)), schema)
    w("probe translation notes: %s" % probe_notes)

    arms = {
        "A": run_arm("A_translated", pkg_entries, []),
        "B": run_arm("B_thrift", app_entries, cli),
        "D": run_arm("D_thrift_probe", app_entries, probe_cli),
        "E": run_arm("E_translated_probe", app_entries + probe_translated, []),
    }
    with open(os.path.join(OUT, "offline_%s.json" % TAG), "w") as fh:
        json.dump(arms, fh, indent=1, sort_keys=True)

    verdicts = []

    def verdict(name, ok, evidence):
        verdicts.append((name, ok))
        w("%s %s -- %s" % ("PASS" if ok else "FAIL", name, evidence))

    w("\n=== verdicts (%s) ===" % TAG)
    verdict("P1 pipeline push accepted on every arm",
            all(a["pipeline"] == "accepted" for a in arms.values()),
            {k: a["pipeline"] for k, a in arms.items()})
    a = arms["A"]
    verdict("P2 every package entry accepted (A)",
            not a["refused"] and len(a["written"]) == len(pkg_entries),
            "%d/%d written, refused %s" % (len(a["written"]), len(pkg_entries), a["refused"]))
    non_default = [e for e in a["read"] if not e["is_default"]]
    want_non_default = [e for e in pkg_entries if not e.get("default_action")]
    verdict("P2 every non-default package entry read back (A)",
            len(non_default) == len(want_non_default),
            "%d read, %d written" % (len(non_default), len(want_non_default)))
    for t in ("MyIngress.process_int_source.tb_int_source",
              "MyIngress.process_int_source_sink.tb_set_source"):
        ra = sorted(readback_key(e) for e in a["read"] if e["table"] == t and not e["is_default"])
        rb = sorted(readback_key(e) for e in arms["B"]["read"]
                    if e["table"] == t and not e["is_default"])
        pa = [e["priority"] for e in a["read"] if e["table"] == t and not e["is_default"]]
        pb = [e["priority"] for e in arms["B"]["read"] if e["table"] == t and not e["is_default"]]
        verdict("P3 %s: translated == thrift-installed (match, action, params)" % t,
                bool(ra) and ra == rb,
                "A %s | B %s | priority A %s B %s" % (ra, rb, pa, pb))
    verdict("P4 A frames out == B frames out on every port",
            a["outputs"] == arms["B"]["outputs"],
            "A %s | B %s" % ({p: len(v or []) for p, v in a["outputs"].items()},
                             {p: len(v or []) for p, v in arms["B"]["outputs"].items()}))
    out2 = [bytes.fromhex(x) for x in a["outputs"].get("2") or []]
    out1 = [bytes.fromhex(x) for x in a["outputs"].get("1") or []]
    want_f1 = expected_int_frame(FRAMES["f1"][1], "08:00:00:00:02:00", 8, 4, 0xF, 0xF)
    verdict("P5 f1 out of port 2 is int-v1's INT frame, byte for byte",
            want_f1 in out2, "want %s | port 2 got %s" % (want_f1.hex(), [f.hex() for f in out2]))
    want_f2 = expected_plain_frame(FRAMES["f2"][1], "08:00:00:00:02:00")
    want_f4 = expected_plain_frame(FRAMES["f4"][1], "08:00:00:00:03:00")
    want_f3 = expected_plain_frame(FRAMES["f3"][1], "08:00:00:00:01:11")
    verdict("P5 f2 and f4 (not the app's flow) leave port 2 with no INT",
            want_f2 in out2 and want_f4 in out2 and len(out2) == 4,
            "port 2: %s" % [int_fields(f) for f in out2])
    want_f5 = expected_int_after_ip(FRAMES["f5"][1], "08:00:00:00:02:00", 8, 4, 0xF, 0xF)
    verdict("P5 f5 (h1 pings h2) gets the INT shim straight after IPv4, byte for byte",
            want_f5 in out2, "want %s" % want_f5.hex())
    verdict("P5 f3 (in on port 2, not a source port) leaves port 1 with no INT",
            out1 == [want_f3], "port 1: %s" % [int_fields(f) for f in out1])
    d2 = [bytes.fromhex(x) for x in arms["D"]["outputs"].get("2") or []]
    d_f1 = [int_fields(f) for f in d2 if f[23] == 17
            and f[26:34] == F.ip_bytes("10.0.1.1") + F.ip_bytes("10.0.2.2")]
    verdict("P6 CLI priority 1 beat CLI priority 2 (D f1 hop_metadata_len == 1)",
            d_f1 == [(0x17, 1)], "D f1 (dscp, hop_ml): %s; all D port 2: %s" %
            (d_f1, [int_fields(f) for f in d2]))
    verdict("P6 E frames out == D frames out on every port",
            arms["E"]["outputs"] == arms["D"]["outputs"],
            "E port 2: %s" % [int_fields(bytes.fromhex(x))
                              for x in arms["E"]["outputs"].get("2") or []])
    dp = [(e["priority"], e["action"]["params"].get("hop_metadata_len"))
          for e in arms["D"]["read"]
          if e["table"] == "MyIngress.process_int_source.tb_int_source" and not e["is_default"]]
    ep = [(e["priority"], e["action"]["params"].get("hop_metadata_len"))
          for e in arms["E"]["read"]
          if e["table"] == "MyIngress.process_int_source.tb_int_source" and not e["is_default"]]
    w("INFO P4Runtime priority read back, (priority, hop_metadata_len): D thrift %s | E "
      "translated %s" % (sorted(dp), sorted(ep)))
    failed = [n for n, ok in verdicts if not ok]
    w("\n%s: %d verdict(s), %d failed%s" % (TAG, len(verdicts), len(failed),
                                             (": " + "; ".join(failed)) if failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
