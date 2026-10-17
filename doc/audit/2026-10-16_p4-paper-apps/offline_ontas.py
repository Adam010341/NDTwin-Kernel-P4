#!/usr/bin/env python3
"""offline ONTAS: does the converted package's s1 load, take every entry, and anonymise as p4anony.p4 says?

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python -I offline_ontas.py <bmv2 simple_switch_grpc> <simple_switch_CLI> \
        <worktree> <package dir> <pcap> <out dir>

The app is Princeton-Cabernet/p4-projects @e5c7cca1, ONTAS/bmv2_p4_16 (Apache-2.0), DOWNLOADED and
untrusted: nothing of it is executed here. Its p4anony.p4 was compiled with this machine's
p4c-bm2-ss into the package; its s1-runtime.json is read as the package's entries; its
smallFlows.pcap is read as DATA (frames.read_pcap, a struct parser) and the frames are written into
the throwaway's input pcap. Run with -I and from this file's own directory, the package and pcap
paths as arguments.

One throwaway simple_switch_grpc (tools/p4_health/throwaway.py, as offline_int_v1.py), pipeline and
entries through the proxy's own P4RuntimeClient the way main.apply_package_entries writes them,
route binding None (a foreign pipeline with no roles). Frames into port 1 (and one into port 2);
every frame out is compared with ontas_model.py, a hand model of p4anony.p4, byte for byte.

Verdicts:
  O1  the pipeline push is accepted
  O2  every package entry is accepted, and the all-tables Read returns exactly what was written
      (table, match, action, params, priority; against P4RuntimeClient.build_table_entry)
  O3  each crafted frame leaves on the port the model says, as the bytes the model says:
        g1 UDP 72.14.213.5 -> 72.14.213.77 (both addresses anonymised, both MAC ids hashed)
        g2 UDP 10.1.2.3 -> 10.4.5.6 (outside 72.14.213.0/24: addresses kept, MAC ids hashed)
        g3 broadcast destination MAC (destination id kept)
        g4 multicast destination 01:00:5e:00:00:fb (destination id kept)
        g5 ARP reply 72.14.213.9 -> 72.14.213.10 (hardware ids and protocol addresses rewritten)
        g6 802.1Q-tagged IPv4 72.14.213.5 -> 10.9.9.9 (the source anonymised inside the tag)
        g7 TCP 72.14.213.200:80 -> 72.14.213.1:1234 (ports and TCP checksum untouched)
        g8 the g1 frame in on port 2 (forward_tb has no port-2 entry: nothing leaves)
  O4  the first REPLAY_N frames of smallFlows.pcap that carry every header the parser extracts,
      into port 1: as many out of port 2, each equal to the model -- and at least one of them
      had an address in 72.14.213.0/24 (else the replay would not test the anonymiser)
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import time

BMV2, CLI, WT, PKG, PCAP, OUT = (os.path.abspath(a) for a in sys.argv[1:7])
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(WT, "p4_proxy"))
sys.path.insert(0, os.path.join(WT, "tools"))

import ontas_model as M  # noqa: E402
from p4_health import frames as F  # noqa: E402
from p4_health import throwaway as TW  # noqa: E402
from p4_health.collect.config import default_p4dev_python  # noqa: E402
from proxy_agent import p4_client as p4_client_module  # noqa: E402
from proxy_agent.p4_client import P4RuntimeClient  # noqa: E402

JSON = os.path.join(PKG, "build", "p4anony.json")
INFO = os.path.join(PKG, "build", "p4anony.p4.p4info.txt")
CPU = 255
ELECTION = (0, 65535)
REPLAY_N = 60
TAG = "fast" if "bmv2-fast" in BMV2 else "stock"
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "ontas_%s.log" % TAG), "w")


def w(msg=""):
    print(msg, flush=True)
    LOG.write(msg + "\n")
    LOG.flush()


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def intify(obj):
    if isinstance(obj, bytes):
        return int.from_bytes(obj, "big")
    if isinstance(obj, dict):
        return {k: intify(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [intify(v) for v in obj]
    return obj


def key(entry):
    return json.dumps({k: intify(entry[k]) for k in ("table", "priority", "is_default", "match",
                                                      "action")}, sort_keys=True)


# --- crafted frames ------------------------------------------------------------------------------

SRC_MAC, DST_MAC = "aa:bb:cc:12:34:56", "00:11:22:ab:cd:ef"


def ipv4_udp(src_ip, dst_ip, dst_mac=DST_MAC, sport=5000, dport=6000, cell="x"):
    return F.udp_marker(SRC_MAC, dst_mac, src_ip, dst_ip, dport, sport=sport, run_id="ontas",
                        cell=cell)


def ipv4_tcp(src_ip, dst_ip, sport, dport):
    body = F.payload("ontas", "g7", 7)
    tcp = struct.pack("!HHIIBBHHH", sport, dport, 1000, 0, 5 << 4, 0x18, 512, 0xBEEF, 0) + body
    ip = F.ipv4_header(src_ip, dst_ip, F.PROTO_TCP, len(tcp))
    return F.ethernet(DST_MAC, SRC_MAC, F.ETH_IPV4, ip + tcp).ljust(60, b"\0")


def arp_reply(spa, tpa):
    body = struct.pack("!HHBBH", 1, 0x0800, 6, 4, 2) + F.mac_bytes(SRC_MAC) + F.ip_bytes(spa) \
        + F.mac_bytes(DST_MAC) + F.ip_bytes(tpa)
    return F.ethernet(DST_MAC, SRC_MAC, 0x0806, body).ljust(60, b"\0")


def vlan_ipv4(src_ip, dst_ip):
    inner = ipv4_udp(src_ip, dst_ip, cell="g6")[14:]
    return (F.mac_bytes(DST_MAC) + F.mac_bytes(SRC_MAC) + struct.pack("!HHH", 0x8100, 7, 0x0800)
            + inner)


CRAFTED = [
    ("g1", 1, ipv4_udp("72.14.213.5", "72.14.213.77", cell="g1")),
    ("g2", 1, ipv4_udp("10.1.2.3", "10.4.5.6", cell="g2")),
    ("g3", 1, ipv4_udp("72.14.213.5", "10.4.5.6", dst_mac="ff:ff:ff:ff:ff:ff", cell="g3")),
    ("g4", 1, ipv4_udp("72.14.213.5", "10.4.5.6", dst_mac="01:00:5e:00:00:fb", cell="g4")),
    ("g5", 1, arp_reply("72.14.213.9", "72.14.213.10")),
    ("g6", 1, vlan_ipv4("72.14.213.5", "10.9.9.9")),
    ("g7", 1, ipv4_tcp("72.14.213.200", "72.14.213.1", 80, 1234)),
    ("g8", 2, ipv4_udp("72.14.213.5", "72.14.213.77", cell="g8")),
]


def replay_slice():
    """(frames, skipped) -- the first REPLAY_N frames of the pcap the program parses whole."""
    frames = F.read_pcap(PCAP)
    if frames is None:
        raise SystemExit("%s is not a pcap this reader can read" % PCAP)
    take, skipped = [], 0
    for frame in frames:
        if len(frame) < M.needed_length(frame) or len(frame) > 1514:
            skipped += 1
            continue
        take.append(frame)
        if len(take) == REPLAY_N:
            break
    return take, skipped


def run(entries, inputs, label):
    work = os.path.join(OUT, TAG, label)
    os.makedirs(work, exist_ok=True)
    # The CLI is used for one thing: throwaway.start's switch_info, which confirms the switch on
    # the port is the one just started. No table is written through it.
    sw = TW.Throwaway(JSON, inputs, CPU, [default_p4dev_python(), CLI], wait_s=12, bmv2=BMV2,
                      workdir=work, argv0="ndt-hc-paperapps-bmv2", grpc=True)
    res = {"written": [], "refused": []}
    w("\n=== %s (%s) ===" % (label, TAG))
    sw.start()
    try:
        w("bmv2 up: pid %d grpc 127.0.0.1:%d device_id %d" % (sw.proc.pid, sw.grpc_port,
                                                             TW.DEVICE_ID))
        client = P4RuntimeClient(device_id=TW.DEVICE_ID, grpc_addr="127.0.0.1:%d" % sw.grpc_port,
                                 p4info_path=INFO, json_path=JSON, election_id=ELECTION)
        client.bind_routes(None)
        client.start(push_config=False)
        time.sleep(1.0)
        try:
            client.set_forwarding_pipeline_config()
            res["pipeline"] = "accepted"
        except Exception as exc:  # noqa: BLE001
            res["pipeline"] = "REFUSED: %s: %s" % (type(exc).__name__, exc)
        w("O1 pipeline push: %s" % res["pipeline"])
        for i, spec in enumerate(entries):
            try:
                with p4_client_module.entry_source(p4_client_module.ENTRY_SOURCE_BOOT):
                    client.write_table_entry(spec, spec.get("op", "insert"))
                res["written"].append(i)
            except Exception as exc:  # noqa: BLE001
                res["refused"].append({"index": i, "table": spec.get("table"),
                                       "error": "%s: %s" % (type(exc).__name__, exc)})
        w("entries: %d written, %d refused %s" % (len(res["written"]), len(res["refused"]),
                                                  res["refused"]))
        expected = []
        for spec in entries:
            if spec.get("default_action"):
                continue
            entry, _k = client.build_table_entry(spec)
            a = entry.action.action
            expected.append(key({
                "table": client._table_name(entry.table_id), "priority": entry.priority,
                "is_default": False, "match": client._match_as_dict(entry.table_id, entry.match),
                "action": {"name": client._action_name(a.action_id),
                           "params": {client._action_param_name(a.action_id, p.param_id): p.value
                                      for p in a.params}}}))
        res["expected"] = sorted(expected)
        try:
            res["read"] = sorted(key(e) for e in client.read_table_entries())
            res["read_error"] = None
        except Exception as exc:  # noqa: BLE001
            res["read"], res["read_error"] = [], "%s: %s" % (type(exc).__name__, exc)
        installed = time.monotonic() - sw.started_at
        res["installed_before_s"] = installed
        w("entries in %.1f s (the switch reads its input at %d s)" % (installed, sw.wait_s))
        sw.wait_processed(settle_s=4.0)
        res["outputs"] = {p: f for p, f in sw.outputs().items()}
        client.stop()
    finally:
        w("stopped pid %d rc=%s" % (sw.proc.pid, sw.stop()))
    return res


def main():
    w("offline ONTAS -- %s" % time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    ver = subprocess.run([BMV2, "--version"], capture_output=True, text=True)
    w("bmv2   : %s sha256 %s  --version: %s" % (BMV2, sha(BMV2), (ver.stdout or ver.stderr).strip()))
    head = subprocess.run(["git", "-C", WT, "rev-parse", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", WT, "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True)
    w("commit : %s" % head.stdout.strip())
    w("tree   : %d tracked file(s) modified" % len(dirty.stdout.splitlines()))
    w("package: %s  p4anony.json %s  p4info %s" % (PKG, sha(JSON)[:16], sha(INFO)[:16]))
    w("pcap   : %s sha256 %s" % (PCAP, sha(PCAP)[:16]))
    with open(os.path.join(PKG, "package.json")) as fh:
        rel = json.load(fh)["switches"]["1"]["entries"]
    with open(os.path.join(PKG, rel)) as fh:
        entries = json.load(fh)["table_entries"]

    replay, skipped = replay_slice()
    w("replay slice: %d frame(s), %d skipped as shorter than the parser's headers or > 1514"
      % (len(replay), skipped))
    inputs = {1: [f for _n, p, f in CRAFTED if p == 1], 2: [f for _n, p, f in CRAFTED if p == 2]}
    a = run(entries, inputs, "crafted")
    b = run(entries, {1: replay, 2: []}, "replay")

    verdicts = []

    def verdict(name, ok, evidence):
        verdicts.append((name, ok))
        w("%s %s -- %s" % ("PASS" if ok else "FAIL", name, evidence))

    w("\n=== verdicts (%s) ===" % TAG)
    verdict("O1 pipeline push accepted (both arms)",
            a["pipeline"] == b["pipeline"] == "accepted", (a["pipeline"], b["pipeline"]))
    verdict("O2 every package entry accepted", not a["refused"] and len(a["written"]) ==
            len(entries), "%d/%d" % (len(a["written"]), len(entries)))
    verdict("O2 the all-tables Read returns exactly the entries written",
            a["read_error"] is None and a["read"] == a["expected"] and a["expected"],
            "%d read, %d expected%s" % (len(a["read"]), len(a["expected"]),
                                        "" if a["read"] == a["expected"] else
                                        "; read %s | expected %s" % (a["read"], a["expected"])))
    out = {p: list(f or []) for p, f in a["outputs"].items()}
    for name, port, frame in CRAFTED:
        eport, want = M.apply(frame, port)
        if eport is None:
            n_out = sum(1 for _n, q, f in CRAFTED if M.apply(f, q)[0] == 2)
            verdict("O3 %s (in on port %d) leaves on no port" % (name, port),
                    len(out.get(1, [])) == 0 and len(out.get(2, [])) == n_out,
                    "port 1 holds %d frame(s), port 2 %d (want 0 and %d)"
                    % (len(out.get(1, [])), len(out.get(2, [])), n_out))
            continue
        got = want in out.get(eport, [])
        verdict("O3 %s leaves port %d as the model computes it, byte for byte" % (name, eport),
                got, "want %s | port %d got %s" % (want.hex(), eport,
                                                   [f.hex() for f in out.get(eport, [])][:8]))
    rout = list(b["outputs"].get(2) or [])
    model = [M.apply(f, 1)[1] for f in replay]
    same = sum(1 for x, y in zip(rout, model) if x == y)
    anonymised = sum(1 for f, m in zip(replay, model) if f[26:34] != m[26:34] or
                     (f[12:14] == b"\x08\x06" and f[28:32] != m[28:32]))
    first_bad = next((i for i, (x, y) in enumerate(zip(rout, model)) if x != y), None)
    verdict("O4 replay: %d frames in, %d out of port 2, %d equal to the model, %d with an "
            "address the model anonymised" % (len(replay), len(rout), same, anonymised),
            len(rout) == len(replay) == same and anonymised > 0,
            "first difference at frame %s%s" % (first_bad, "" if first_bad is None else
                                                ": got %s | model %s" % (
                                                    rout[first_bad].hex(), model[first_bad].hex())))
    failed = [n for n, ok in verdicts if not ok]
    w("\n%s: %d verdict(s), %d failed%s" % (TAG, len(verdicts), len(failed),
                                             (": " + "; ".join(failed)) if failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
