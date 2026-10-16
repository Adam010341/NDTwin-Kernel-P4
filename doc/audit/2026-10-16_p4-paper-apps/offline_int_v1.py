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

Arms, the same six frames into each:

  A   translated  the converted package's s1 runtime file (the app's three ipv4_lpm routes and
                  its default action, plus the two entries translated from runtime_cmds/s1.sh),
                  all through P4Runtime.
  B   thrift      the APP's own linear-topo/s1-runtime.json through P4Runtime, then the app's two
                  CLI lines, read out of runtime_cmds/s1.sh by a regex of this file's own (not
                  thrift_cli), through simple_switch_CLI on the throwaway's thrift port -- i.e.
                  what `make run` + runtime_cmd.sh do to s1, on the same pipeline.
  D   thrift, priority probe   the app's runtime file, then set_source, Y and X through the CLI,
                  Y FIRST. Y: the /16 pair, CLI priority 2, hop_metadata_len 2, masks f/f.
                  X: the app's /24 pair, CLI priority 1, hop_metadata_len 1, masks 0x3/0xC (so a
                  swap of the two mask parameters shows on the wire).
  D2  as D, X FIRST. If the later insert won instead of the lower number, D2's winner differs.
  E / E2  D / D2's three lines through thrift_cli and P4Runtime, in the same order.

Verdicts (each printed with its evidence):
  P1  the pipeline push is accepted on every arm
  P2  A: every package entry accepted, and the all-tables Read returns exactly the entries
      written -- table, match, action, params and priority compared, as the switch encodes them,
      against what the proxy's writer built (P4RuntimeClient.build_table_entry)
  P3  bmv2's own view (the CLI's table_dump) of tb_set_source and tb_int_source is the same in A
      and B, Priority lines included: the translated entry is held with the CLI's own priority
  P4  A's frames out == B's frames out, byte for byte, on every port
  P5  A's f1 out == the INT frame int-v1's source computes (int_source.p4:21-53), built here from
      the input bytes; f2-f4 come out with no INT; f5 (ICMP echo request h1->h2) and f6 (ICMP
      echo reply h1->h2) get the shim straight after IPv4, byte for byte
  P6  D's and D2's f1 == X's INT frame byte for byte (hop 1, masks 3/C): CLI priority 1 beat 2
      whichever was inserted first; E's / E2's frames out == D's / D2's
  P7  E's / E2's table_dump == D's / D2's, Priority lines included
  READ SCOPE (recorded, not a verdict): on every arm, six Reads -- all tables, ipv4_lpm alone
  (never written by the CLI) and tb_int_source alone, each with and without counter_data.
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


def intify(obj):
    """bytes -> int everywhere: the switch may return a value in fewer bytes than the writer
    sent (P4Runtime's canonical form), and the same number must compare equal."""
    if isinstance(obj, bytes):
        return int.from_bytes(obj, "big")
    if isinstance(obj, dict):
        return {k: intify(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [intify(v) for v in obj]
    return obj


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


def icmp_echo(src_mac, dst_mac, src_ip, dst_ip, ident=0x1234, seq=1, kind=8):
    """An ICMP echo request (kind 8) or reply (kind 0), as `ping` and the kernel send them."""
    data = b"int-v1 offline ping".ljust(32, b".")
    head = struct.pack("!BBHHH", kind, 0, 0, ident, seq)
    csum = F.checksum16(head + data)
    icmp = struct.pack("!BBHHH", kind, 0, csum, ident, seq) + data
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
    # (parser.p4:96-116).
    "f5": (1, icmp_echo(H1_MAC, H2_MAC, "10.0.1.1", "10.0.2.2")),
    # h1 ANSWERS a ping from h2: the reply crosses s1's port 1 towards 10.0.2.2 too, so the
    # ping h2 -> h1 is broken on its way back (live A3's h2->h1 cell).
    "f6": (1, icmp_echo(H1_MAC, H2_MAC, "10.0.1.1", "10.0.2.2", ident=0x4321, seq=7, kind=0)),
}


def inputs():
    out = {}
    for _name, (port, frame) in sorted(FRAMES.items()):
        out.setdefault(port, []).append(frame)
    return out


def _int_ip(ip):
    """The IPv4 header int_source_dscp leaves: DSCP 0x17, len + 12, ttl - 1, checksum redone."""
    ip = bytearray(ip)
    ip[1] = (0x17 << 2) | (ip[1] & 0x3)
    ip[2:4] = struct.pack("!H", struct.unpack("!H", bytes(ip[2:4]))[0] + 12)
    ip[8] -= 1
    ip[10:12] = b"\0\0"
    ip[10:12] = struct.pack("!H", F.checksum16(bytes(ip)))
    return bytes(ip)


def _int_bytes(orig_dscp, hop_ml, rhc, mask0003, mask0407):
    """The 4-byte shim (int_type 1, len 3, the ORIGINAL dscp) and the 8-byte INT header."""
    shim = bytes([1, 0, 3, (orig_dscp << 2) & 0xFC])
    header = bytes([0, 0, hop_ml & 0x1F, rhc, ((mask0003 & 0xF) << 4) | (mask0407 & 0xF),
                    0, 0, 0])
    return shim + header


def expected_int_frame(frame, dst_mac, hop_ml, rhc, mask0003, mask0407):
    """int_source.p4:21-53 + fwd.p4 ipv4_forward on a UDP frame, by hand: Ethernet dst <- the
    route's dst_addr (src unchanged); the IPv4 header as _int_ip; udp.length_ += 12 with the UDP
    checksum untouched; shim + INT header after the UDP header; then the rest as it came in."""
    eth, ip, rest = frame[:14], frame[14:34], frame[34:]
    udp, payload = bytearray(rest[:8]), rest[8:]
    udp[4:6] = struct.pack("!H", struct.unpack("!H", bytes(udp[4:6]))[0] + 12)
    return (F.mac_bytes(dst_mac) + eth[6:] + _int_ip(ip) + bytes(udp)
            + _int_bytes(ip[1] >> 2, hop_ml, rhc, mask0003, mask0407) + payload)


def expected_int_after_ip(frame, dst_mac, hop_ml, rhc, mask0003, mask0407):
    """The same source on a frame with no TCP/UDP header: shim + INT header right after IPv4."""
    eth, ip, rest = frame[:14], frame[14:34], frame[34:]
    return (F.mac_bytes(dst_mac) + eth[6:] + _int_ip(ip)
            + _int_bytes(ip[1] >> 2, hop_ml, rhc, mask0003, mask0407) + rest)


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


LPM = "MyIngress.FwdIngress.ipv4_lpm"
SET_SOURCE = "MyIngress.process_int_source_sink.tb_set_source"
INT_SOURCE = "MyIngress.process_int_source.tb_int_source"
INT_TABLES = (SET_SOURCE, INT_SOURCE)


def dump_entries(text):
    """The entry blocks of one `table_dump`, without the CLI's banner and prompt lines."""
    keep = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(("*", "Dumping entry", "Match key", "Priority", "Action entry",
                            "Default entry")) or "EXACT" in line or "TERNARY" in line:
            keep.append(line)
    return keep


PROBE_Y = ("table_add tb_int_source int_source_dscp 10.0.0.0&&&0xFFFF0000 10.0.0.0&&&0xFFFF0000 "
           "0&&&0 0&&&0 => 2 4 0xF 0xF 2")
PROBE_X = ("table_add tb_int_source int_source_dscp 10.0.1.0&&&0xFFFFFF00 10.0.2.0&&&0xFFFFFF00 "
           "0&&&0 0&&&0 => 1 4 0x3 0xC 1")


def scoped_reads(client):
    """Six Reads, each (ok, entries or error). Built here, not through read_table_entries, which
    always asks for every table and for counters (the proxy's flow-stats read)."""
    from p4.v1 import p4runtime_pb2

    out = {}
    for label, table in (("all", None), ("ipv4_lpm", LPM), ("tb_int_source", INT_SOURCE)):
        for counters in (True, False):
            req = p4runtime_pb2.ReadRequest()
            req.device_id = client.device_id
            te = req.entities.add().table_entry
            te.table_id = 0 if table is None else client._get_table_id(table)
            if counters:
                te.counter_data.SetInParent()
            key = "%s%s" % (label, "+counters" if counters else "")
            try:
                n = sum(len(r.entities) for r in client.stub.Read(req, timeout=5))
                out[key] = "ok: %d entit%s" % (n, "y" if n == 1 else "ies")
            except Exception as exc:  # noqa: BLE001 -- the error IS the reading
                details = getattr(exc, "details", None)
                code = getattr(exc, "code", None)
                out[key] = "FAILED: %s %s" % (code() if callable(code) else "",
                                              details() if callable(details) else exc)
    return out


def expected_readback(client, specs):
    """What the switch should hold for `specs`, in read_table_entries' shape, from the writer."""
    out = []
    for spec in specs:
        if spec.get("default_action"):
            continue
        entry, _kinds = client.build_table_entry(spec)
        a = entry.action.action
        out.append(readback_key({
            "table": client._table_name(entry.table_id), "priority": entry.priority,
            "is_default": False, "match": client._match_as_dict(entry.table_id, entry.match),
            "action": {"name": client._action_name(a.action_id),
                       "params": {client._action_param_name(a.action_id, p.param_id): p.value
                                  for p in a.params}}}))
    return sorted(out)


def readback_key(entry):
    return json.dumps({k: intify(entry[k]) for k in ("table", "priority", "is_default", "match",
                                                      "action")}, sort_keys=True)


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
        res["expected"] = expected_readback(client, p4rt_entries)
        if cli_lines:
            out = sw.install(cli_lines)
            res["cli"] = {"lines": cli_lines, "out": out}
            w("thrift CLI: %d line(s) installed" % len(cli_lines))
        # 🔴 After a CLI write, a P4Runtime Read can fail on bmv2 (round 1: INTERNAL "Table state
        # out-of-sync with target"). Recorded, never assumed; the scope is measured here.
        try:
            res["read"] = client.read_table_entries()
            res["read_keys"] = sorted(readback_key(e) for e in res["read"])
            res["read_error"] = None
            w("P4Runtime read back (all tables, counters): %d entr(ies)" % len(res["read"]))
        except Exception as exc:  # noqa: BLE001 -- the error IS the reading
            res["read"], res["read_keys"] = [], []
            res["read_error"] = "%s: %s" % (type(exc).__name__, getattr(
                exc, "details", lambda: str(exc))())
            w("P4Runtime read back FAILED: %s" % res["read_error"])
        res["read"] = hexify(res["read"])
        res["scope"] = scoped_reads(client)
        for k in sorted(res["scope"]):
            w("   read scope %-22s %s" % (k, res["scope"][k]))
        res["dump"] = {t: sw.cli(["table_dump %s" % t]) for t in INT_TABLES + (LPM,)}
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


def main():
    w("offline int-v1 -- %s" % time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    ver = subprocess.run([BMV2, "--version"], capture_output=True, text=True)
    w("bmv2   : %s sha256 %s  --version: %s" % (BMV2, sha(BMV2), (ver.stdout or ver.stderr).strip()))
    w("CLI    : %s sha256 %s" % (CLI, sha(CLI)))
    head = subprocess.run(["git", "-C", WT, "rev-parse", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", WT, "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True)
    w("commit : %s" % head.stdout.strip())
    w("tree   : %s, %d tracked file(s) modified%s" % (
        WT, len(dirty.stdout.splitlines()),
        (": " + ", ".join(l[3:] for l in dirty.stdout.splitlines())) if dirty.stdout else ""))
    w("package: %s  int.json %s  p4info %s" % (PKG, sha(JSON)[:16], sha(INFO)[:16]))
    w("app    : %s" % APP)

    pkg_entries = package_runtime_entries()
    app_entries = app_runtime_entries()
    cli = app_cli_lines()
    w("app CLI lines (regex): %s" % cli)
    schema = thrift_cli.schema_from_p4info_path(INFO)
    d_lines = [cli[0], PROBE_Y, PROBE_X]
    d2_lines = [cli[0], PROBE_X, PROBE_Y]
    e_entries, e_notes = thrift_cli.translate(list(enumerate(d_lines, 1)), schema)
    e2_entries, _n = thrift_cli.translate(list(enumerate(d2_lines, 1)), schema)
    w("probe translation notes: %s" % e_notes)

    arms = {
        "A": run_arm("A_translated", pkg_entries, []),
        "B": run_arm("B_thrift", app_entries, cli),
        "D": run_arm("D_thrift_probe_Y_first", app_entries, d_lines),
        "D2": run_arm("D2_thrift_probe_X_first", app_entries, d2_lines),
        "E": run_arm("E_translated_probe_Y_first", app_entries + e_entries, []),
        "E2": run_arm("E2_translated_probe_X_first", app_entries + e2_entries, []),
    }
    with open(os.path.join(OUT, "offline_%s.json" % TAG), "w") as fh:
        json.dump(arms, fh, indent=1, sort_keys=True)

    verdicts = []

    def verdict(name, ok, evidence):
        verdicts.append((name, ok))
        w("%s %s -- %s" % ("PASS" if ok else "FAIL", name, evidence))

    def frames(arm, port):
        return [bytes.fromhex(x) for x in arms[arm]["outputs"].get(str(port)) or []]

    w("\n=== verdicts (%s) ===" % TAG)
    verdict("P1 pipeline push accepted on every arm",
            all(a["pipeline"] == "accepted" for a in arms.values()),
            {k: a["pipeline"] for k, a in arms.items()})
    a = arms["A"]
    verdict("P2 every package entry accepted (A)",
            not a["refused"] and len(a["written"]) == len(pkg_entries),
            "%d/%d written, refused %s" % (len(a["written"]), len(pkg_entries), a["refused"]))
    verdict("P2 the all-tables Read returns exactly the entries written (A): table, match, "
            "action, params, priority",
            a["read_error"] is None and a["read_keys"] == a["expected"] and a["expected"],
            "%d read, %d expected%s" % (len(a["read_keys"]), len(a["expected"]),
                                        "" if a["read_keys"] == a["expected"] else
                                        "; read %s | expected %s" % (a["read_keys"],
                                                                     a["expected"])))
    for t in INT_TABLES:
        da, db = dump_entries(a["dump"][t]), dump_entries(arms["B"]["dump"][t])
        verdict("P3 %s: bmv2 holds the same entry translated or CLI-written, Priority "
                "included (table_dump)" % t, bool(da) and da == db, "A %s | B %s" % (da, db))
    verdict("P4 A frames out == B frames out on every port",
            a["outputs"] == arms["B"]["outputs"],
            "A %s | B %s" % ({p: len(v or []) for p, v in a["outputs"].items()},
                             {p: len(v or []) for p, v in arms["B"]["outputs"].items()}))
    out1, out2 = frames("A", 1), frames("A", 2)
    want = {
        "f1": expected_int_frame(FRAMES["f1"][1], "08:00:00:00:02:00", 8, 4, 0xF, 0xF),
        "f2": expected_plain_frame(FRAMES["f2"][1], "08:00:00:00:02:00"),
        "f4": expected_plain_frame(FRAMES["f4"][1], "08:00:00:00:03:00"),
        "f5": expected_int_after_ip(FRAMES["f5"][1], "08:00:00:00:02:00", 8, 4, 0xF, 0xF),
        "f6": expected_int_after_ip(FRAMES["f6"][1], "08:00:00:00:02:00", 8, 4, 0xF, 0xF),
    }
    verdict("P5 f1 out of port 2 is int-v1's INT frame, byte for byte", want["f1"] in out2,
            "want %s | port 2 got %s" % (want["f1"].hex(), [f.hex() for f in out2]))
    verdict("P5 f2 and f4 (not the app's flow) leave port 2 with no INT",
            want["f2"] in out2 and want["f4"] in out2 and len(out2) == 5,
            "port 2 (dscp, hop_ml): %s" % [int_fields(f) for f in out2])
    verdict("P5 f5 (echo request h1->h2) gets the shim straight after IPv4, byte for byte",
            want["f5"] in out2, "want %s" % want["f5"].hex())
    verdict("P5 f6 (echo reply h1->h2) gets the shim straight after IPv4, byte for byte",
            want["f6"] in out2, "want %s" % want["f6"].hex())
    verdict("P5 f3 (in on port 2, not a source port) leaves port 1 with no INT",
            out1 == [expected_plain_frame(FRAMES["f3"][1], "08:00:00:00:01:11")],
            "port 1: %s" % [int_fields(f) for f in out1])
    want_x = expected_int_frame(FRAMES["f1"][1], "08:00:00:00:02:00", 1, 4, 0x3, 0xC)
    for arm in ("D", "D2"):
        got = [f for f in frames(arm, 2) if f[23] == 17
               and f[26:34] == F.ip_bytes("10.0.1.1") + F.ip_bytes("10.0.2.2")]
        verdict("P6 %s: f1 carries X's INT header, byte for byte (CLI priority 1 beat 2, %s "
                "inserted first)" % (arm, "Y" if arm == "D" else "X"),
                got == [want_x], "got %s | want %s" % ([g.hex() for g in got], want_x.hex()))
    for d, e in (("D", "E"), ("D2", "E2")):
        verdict("P6 %s frames out == %s frames out on every port" % (e, d),
                arms[e]["outputs"] == arms[d]["outputs"],
                "%s port 2: %s" % (e, [int_fields(f) for f in frames(e, 2)]))
        dd = dump_entries(arms[d]["dump"][INT_SOURCE])
        de = dump_entries(arms[e]["dump"][INT_SOURCE])
        verdict("P7 %s table_dump of tb_int_source == %s's, Priority included" % (e, d),
                bool(dd) and dd == de,
                "%s %s | %s %s" % (d, [l for l in dd if l.startswith("Priority")],
                                   e, [l for l in de if l.startswith("Priority")]))
    w("\nREAD SCOPE (%s): which P4Runtime Reads work after what" % TAG)
    for k, arm in arms.items():
        w("  %-3s CLI lines %d | %s" % (k, len((arm.get("cli") or {}).get("lines") or []),
                                        " | ".join("%s %s" % (s, arm["scope"][s])
                                                   for s in sorted(arm["scope"]))))
    failed = [n for n, ok in verdicts if not ok]
    w("\n%s: %d verdict(s), %d failed%s" % (TAG, len(verdicts), len(failed),
                                             (": " + "; ".join(failed)) if failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
