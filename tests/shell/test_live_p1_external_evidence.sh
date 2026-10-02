#!/usr/bin/env bash
#
# live-p1/external_evidence.py, offline: controls (06 runs without the heartbeat on the external
# arms) against a treatment (H5's 06 with it, detect only) and H5's samples of the daemon's report.
#
# [Co-developed with claude code -- Adam]
#
# 09-27: `ndt up p4 --app` starts the heartbeat on an external control plane too, and before that
# is merged the external arms' OWN evidence is compared, with and without it. This tool is that
# comparison's instrument; what is asserted is that it can tell the answers apart (the external
# judge's F1, F2, F7, F8 of 09-28 and its M2, m1, m3 of the second round):
#
#   1. roles: no --samples, no --control2, a control given twice, a treatment arm whose session the
#      samples do not show running through the arm (never, stale, a gap, a restart, stopped before
#      the controller's last write, another session in the window) and a control with ANY trace of
#      the heartbeat are REFUSED (rc 3); a daemon that counted a frame is a difference;
#   2. each kind of difference in the exercise's own evidence is named (rc 1), and more counter
#      reads are not one;
#   3. a difference inside the controls' spread is not counted, and one outside it is -- counts and
#      tunnel counters alike;
#   4. each arm's invariants on its own numbers, counted only when every control keeps them;
#   5. what cannot be read is UNREADABLE (rc 2), never "same" and never a traceback: a missing log,
#      row or report, a counter block cut short or not settled, a packet-in that cannot be parsed
#      (a short IPv4 one included), a log that is not UTF-8, a sampler file from before 09-28 or
#      without 06's end beside it;
#   6. the runs' code and venv fingerprints are printed; N4's counters are labelled for what they are.
#
# The fixtures are cut down from the shapes in live-p1/runs/2026-09-27T074635Z_06_thirteen's three
# external rounds -- 00_table.tsv, each round's report and controller log -- and from live-p1/08's
# sampler, written here by two small generators; the real raw is not in the repository.
#
# Run:  bash tests/shell/test_live_p1_external_evidence.sh
# Env:  EVIDENCE_UNDER_TEST=<path to a copy of external_evidence.py>
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${EVIDENCE_UNDER_TEST:-$HERE/../../doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_evidence.py}"
EVIDENCE_PY="${EVIDENCE_PY:-/usr/bin/python3}"

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has()   { /usr/bin/grep -qF -- "$2" <<<"$3" && { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; } \
          || { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"; }; }
hasnt() { /usr/bin/grep -qF -- "$2" <<<"$3" && { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             unexpected: [%s]\n' "$1" "$2"; } \
          || { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-evidence-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM

# mk <name> <control|treatment> [key=value ...] -- a 06 run. Arms start 300 s apart from T0 (the table
# order: basic, flowcache/skeleton, p4runtime/skeleton, p4runtime/solution, flowcache/solution), each
# controller log last written 150 s into its arm. Every run satisfies every invariant, and its last
# counter block is settled, unless an option says otherwise.
cat > "$FIX/mk.py" <<'MK'
import json, os, sys, time
fix, name, role = sys.argv[1], sys.argv[2], sys.argv[3]
o = dict(a.split("=", 1) for a in sys.argv[4:])
T0 = 1790000000
run, rounds = os.path.join(fix, name), os.path.join(fix, name + "-rounds")
os.makedirs(run); os.makedirs(rounds)
def stamp(i): return time.strftime("%Y-%m-%dT%H%M%SZ", time.gmtime(T0 + 300 * i))
def ip(a): return bytes(int(x) for x in a.split("."))
def frame(src, dst, proto, ethertype=0x0800, short=False):
    eth = bytes.fromhex("080000000100") + bytes.fromhex("080000000111") + ethertype.to_bytes(2, "big")
    if ethertype != 0x0800:
        return eth + b"\x00\x01heartbeat"
    if short:
        return eth + b"E\x00\x00T\x00\x00"
    iph = bytes([0x45, 0, 0, 84, 0, 0, 0x40, 0, 64, proto, 0, 0]) + ip(src) + ip(dst)
    return eth + iph + b"\x00" * 8
def punt(sw, port, payload):
    return [f"Received PacketIn message of length {len(payload)} bytes from switch {sw}",
            "decodePacketInMetadata: ret=" + repr({"metadata": {"input_port": port, "punt_reason": 1, "opcode": 0},
                                                   "payload": payload})]
order = [("basic", "solution", "basic"), ("flowcache", "skeleton", "fc_skel"),
         ("p4runtime", "skeleton", "p4rt_skel"), ("p4runtime", "solution", "p4rt_sol"),
         ("flowcache", "solution", "fc_sol")]
verdicts = {"basic": "0\tPASS (6/6)", "fc_skel": "1\tRED ARM (1/1): skeleton does not compile, by design",
            "p4rt_skel": "0\tPASS (4/4)", "p4rt_sol": o.get("verdict_sol", "0\tPASS (5/5)"), "fc_sol": "0\tPASS (5/5)"}
tbl = ["exercise\twhich\trc\tverdict\treport"]
paths = {}
for i, (ex, which, key) in enumerate(order):
    paths[key] = os.path.join(rounds, f"{stamp(i)}_{ex}_{which}_ndtwin.md")
    if o.get("norow") != key:
        tbl.append(f"{ex}\t{which}\t{verdicts[key]}\t{paths[key]}")
open(os.path.join(run, "00_table.tsv"), "w").write("\n".join(tbl) + "\n")
hb = role == "treatment"
# [Co-developed with claude code -- Adam] 00_identity.before.txt and .after.txt (live-p1/code_identity.py,
# format 2): the controls on C, the treatment on C with B merged (the round-4 review's M-2), its tree
# the one merging its parents gives. Options perturb one fact each.
C, B, T = "c" * 40, "b" * 40, "d" * 40
ident = {"format": 2, "repo": "/r", "recorded_at": T0, "head": o.get("id_head", C), "parents": ["a" * 40],
         "tree": "e" * 40, "bmv2_libs": "/usr/local/bmv2-fast/lib: 9 shared objects sha256 " + o.get("id_libs", "11"),
         "tutorials": {"path": "/h/tutorials", "head": o.get("id_tut", "7" * 40), "uncommitted": [],
                       "trees": {"exercises/p4runtime": "12 file(s) sha256 aa", "exercises/flowcache": "9 file(s) sha256 bb",
                                 "utils": "20 file(s) sha256 cc"}},
         "uncommitted": [[" M", "p4_proxy/mininet/host_count_override", "11"]],
         "kernel": ["/r/build/bin/ndtwin_kernel", o.get("id_kernel", "kk")],
         "bmv2_fabric": ["/usr/local/bmv2-fast/bin/simple_switch_grpc", "ff"],
         "bmv2_stock": ["/usr/local/bin/simple_switch", "ss"], "helper": ["/usr/local/sbin/ndtwin-lab", "hh"],
         "venv": {"/r/p4_proxy/venv/bin/python": "distributions 28 sha256 d5fc", "/x/python": "distributions 39 sha256 69c4"}}
if role == "treatment" or o.get("id_role") == "treatment":
    ident.update(head=T, parents=[o.get("id_parent0", C), o.get("id_parent1", B)], tree="f" * 40,
                 merge_tree=o.get("id_merge_tree", "f" * 40), merge_changes=["tools/test_workflow/ndt"])
    if o.get("id_nomerge") == "1":
        ident.update(head=C, parents=["a" * 40]); ident.pop("merge_changes")
    if o.get("id_single") == "1":
        ident.update(parents=[C]); ident.pop("merge_changes")
    if o.get("id_nochanges") == "1":
        ident.pop("merge_changes")
    if o.get("id_touch") == "1":
        ident["merge_changes"].append("p4_proxy/mininet/host_count_override")
if o.get("id_uncommitted") == "1":
    ident["uncommitted"].append([" M", "README.md", "22"])
after = json.loads(json.dumps(ident))
if o.get("id_drift") == "kernel":        # the kernel rebuilt while the run ran
    after["kernel"] = [after["kernel"][0], "k9"]
if o.get("id_drift") == "head":          # a commit landed in the checkout while the run ran
    after["head"] = "9" * 40
if o.get("id") != "none":
    open(os.path.join(run, "00_identity.before.txt"), "w").write(json.dumps(ident, indent=2) + "\n")
    if o.get("id_after") != "none":
        open(os.path.join(run, "00_identity.after.txt"), "w").write(json.dumps(after, indent=2) + "\n")
ctl_pid = {"p4rt_skel": 7001, "p4rt_sol": 7002, "fc_sol": 7003}
for i, (ex, which, key) in enumerate(order):
    if key in ("basic", "fc_skel"):
        continue
    d = paths[key][:-3]; os.makedirs(d)
    md = [f"# report {ex}/{which}", ""]
    # [Co-developed with claude code -- Adam] (round 6) drive_exercise's toolchain row and compiled
    # program table, as in the real reports
    if o.get("noshas") != key:
        prog = "advanced_tunnel" if ex == "p4runtime" else "flowcache"
        js = o.get("json_" + key, {"p4rt_skel": "ef1adeee9e769f26", "p4rt_sol": "ef1adeee9e769f26", "fc_sol": "6156e996ba5c3ec4"}[key])
        md += ["| 執行檔 | sha256[:16] | --version |", "|---|---|---|",
               f"| `/usr/local/bin/p4c-bm2-ss` | `{o.get('p4c', '226f3f66df515c9e')}` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |", "",
               "| 產物 | bytes | sha256[:16] |", "|---|---|---|",
               f"| `/h/tutorials/exercises/{ex}/build/{prog}.json` | 27957 | `{js}` |",
               f"| `/h/tutorials/exercises/{ex}/build/{prog}.p4.p4info.txtpb` | 2285 | `4d986039017abeef` |", ""]
    md += ["### 3. N3  ndt up p4 --app", "```"]
    if o.get("hb_up", "1" if hb else "0") == "1":
        md.append("  ok  heartbeat running on the inter-switch veths, detect only: a cut link is told to the twin")
    md += ["```", "", "### 4. N4  GET /p4/switch_state", "```json"]
    if o.get("hb_block", "1" if hb else "0") == "1":
        md += ['  "heartbeat": {', '    "side_effects": {', '      "foreign_frames": 0,',
               '      "forwarded_between_switches": 0,', '      "forwarded_to_hosts": 0,', '      "misdelivered": 0', "    }", "  },"]
    else:
        md.append('  "heartbeat": null,')
    md += ["```", "", "### 5. N5  ndt status", "```", f"  code           {o.get('code', '5dc7fc9a')}  +95 file(s) with uncommitted changes"]
    row = o.get("hb_row", "running" if hb else "stopped")
    if row == "running":
        md.append(f"  heartbeat      running (pid 4242, session {o.get('session', {'p4rt_skel': '0a0a', 'p4rt_sol': '0b0b', 'fc_sol': '0c0c'}[key])}) -- 6 direction(s), report 1.0 s old")
    elif row == "stopped":
        md.append("  heartbeat      stopped (stopped by SIGTERM), 13 s ago")
    elif row == "stale":
        md.append("  heartbeat      STALE -- the report says running but was written 90 s ago (daemon gone or hung)")
    md.append("```")
    md += ["", "### 7. P1  h1 ping h2 with the controller running", "```", "$ ping -c 5 -W 2 10.0.2.2", "```",
           "```", "5 packets transmitted, 5 received, 0% packet loss, time 4005ms", "```", ""]
    if True:
        md += ["## 8. 完整 transcript", "", "### stdout", "```",
               f"   controller pid {ctl_pid[key]} (handed to the generic cell; stopped after it)", "```", ""]
    if o.get("report_is_dir") == key:
        os.makedirs(paths[key])
    else:
        open(paths[key], "w").write("\n".join(md) + "\n")
    # [Co-developed with claude code -- Adam] (round 6) the adapter's header first, as in the real logs:
    # the sampler's ctrl_logs sizes are read against where the pipeline push ends
    log = ["[adapter] tutorials utils : /h/tutorials/utils", "[adapter] grpc base       : 30050 (device id = dpid)",
           "Installed P4 Program using SetForwardingPipelineConfig on s1",
           "Installed P4 Program using SetForwardingPipelineConfig on s2"]
    if key.startswith("p4rt"):
        log += ["Installed ingress tunnel rule on s1", "Installed egress tunnel rule on s2"]
        if key == "p4rt_sol" and o.get("drop_rule") != "1":
            log.append("Installed transit tunnel rule on s1")
        final = [int(x) for x in o.get("counters_" + key, "5,0,0,0" if key == "p4rt_skel" else "3505,3505,7,7").split(",")]
        def block(v):
            return ["", "----- Reading tunnel counters -----",
                    f"s1 MyIngress.ingressTunnelCounter 100: {v[0]} packets ({v[0] * 1240} bytes)",
                    f"s2 MyIngress.egressTunnelCounter 100: {v[1]} packets ({v[1] * 1244} bytes)",
                    f"s2 MyIngress.ingressTunnelCounter 200: {v[2]} packets ({v[2] * 118} bytes)",
                    f"s1 MyIngress.egressTunnelCounter 200: {v[3]} packets ({v[3] * 122} bytes)"]
        log += block([0, 0, 0, 0])
        for _ in range(int(o.get("reads_extra", "0"))):
            log += block(final)
        log += block(final)
        if o.get("truncate") == key:
            log += ["", "----- Reading tunnel counters -----", f"s1 MyIngress.ingressTunnelCounter 100: {final[0]} packets (1 bytes)"]
        if o.get("grpc") == key:
            log.append("gRPC error occurred: <_InactiveRpcError of RPC that terminated with:")
        if o.get("punt_p4rt") == key:
            log += punt("s1", 1, frame("10.0.1.1", "10.0.2.2", 1))
        if key == "p4rt_sol":
            os.makedirs(os.path.join(d, "link_usage"))
            it = ["[  1] local 10.0.1.1 port 52102 connected with 10.0.2.2 port 5001", "[  1] Sent 3500 datagrams"]
            if o.get("no_ack") == "1":
                it.append("[  5] WARNING: did not receive ack of last datagram after 10 tries.")
            open(os.path.join(d, "link_usage", "iperf_client.txt"), "w").write("\n".join(it) + "\n")
        name_log = "driver-controller-p4runtime.log"
    else:
        log.append("Installed P4 Program using SetForwardingPipelineConfig on s3")
        log += punt("s1", 1, frame("10.0.1.1", "10.0.2.2", 1))
        log.append("For switch s1 flow (SA=10.0.1.1, DA=10.0.2.2, proto=1) added table entry to send packets to port 2 with new DSCP 5")
        for _ in range(int(o.get("punts_extra", "0"))):
            log += punt("s2", 2, frame("10.0.1.1", "10.0.2.2", 1))
        if o.get("punt_hb") == "1":
            log += punt("s3", 2, frame("0.0.0.0", "0.0.0.0", 0, 0x88B5))
        if o.get("punt_arp") == "1":
            log += punt("s3", 2, frame("0.0.0.0", "0.0.0.0", 0, 0x0806))
        if o.get("punt_garbage") == "1":
            log += ["Received PacketIn message of length 60 bytes from switch s3",
                    "decodePacketInMetadata: ret={'metadata': {'input_port': 2}, 'payload': <truncated>}"]
        if o.get("punt_short") == "1":
            log += punt("s3", 2, frame("10.0.1.1", "10.0.2.2", 1, short=True))
        if o.get("stray_entry") == "1":
            log.append("For switch s3 flow (SA=10.0.1.1, DA=10.0.3.3, proto=17) added table entry to send packets to port 3 with new DSCP 5")
        log.append("s1 MyIngress.ingressPktOutCounter 2: 1 packets (104 bytes)")
        if o.get("grpc", "fc_sol") == "fc_sol":
            log.append("gRPC error occurred: <_InactiveRpcError of RPC that terminated with:")
        name_log = "driver-controller-flowcache.log"
    if o.get("nolog") == key:
        continue
    if o.get("nopush") == key:        # no pipeline push line: the window opens at the first entry
        log = [x for x in log if "SetForwardingPipelineConfig" not in x]
    if o.get("bare") == key:          # neither a push nor a rule nor a cache entry
        log = [x for x in log if not x.startswith(("Installed ", "For switch "))]
    data = ("\n".join(log) + "\n").encode()
    if o.get("nonutf8") == key:
        data += b"\xff\xfe not utf-8\n"
    lp = os.path.join(d, name_log)
    open(lp, "wb").write(data)
    last = T0 + 300 * i + int(o.get("ctl_last_" + key, o.get("ctl_last", "150")))
    os.utime(lp, (last, last))
if o.get("venv"):
    open(os.path.join(run, "00_venv.txt"), "w").write(
        "== interpreter /x/venv/bin/python\nresolves_to /usr/bin/python3.13\npython 3.13.1 prefix /x/venv\n"
        "protobuf 5.29.6 api_implementation upb\ngrpcio 1.82.1\ndistributions 28 sha256 d5fc\n\n")
MK
# ms <name> [key=value ...] -- H5's samples for a treatment made by mk (sessions 0a0a, 0b0b, 0c0c): a read every
# second through 06 (arms 300 s apart from T0; 06 ends at T0+1500), each external arm's session running
# fresh from 30 s to 200 s into its arm, stopped by SIGTERM after; 50_t06_end.txt beside it.
# [Co-developed with claude code -- Adam] (round 6) at the daemon's real cadence: each direction's heard
# grows by one every 5 s (one round), and the sampler reads every second. The ctrl_logs column carries
# the sizes of the treatment's own controller logs (mk's run, run=, default t1): the adapter's header
# from 5 s before the push, the whole log from push_at (default 45 s) into the arm; each log is last
# written at 150 s (mk's ctl_last), so the controller's window is 45-150 s.
cat > "$FIX/ms.py" <<'MS'
import glob, os, sys
fix, name = sys.argv[1], sys.argv[2]
o = dict(a.split("=", 1) for a in sys.argv[3:])
T0 = 1790000000
d = os.path.join(fix, name); os.makedirs(d)
arms = {2: "0a0a", 3: "0b0b", 4: "0c0c"}
which = {2: "p4runtime_skeleton", 3: "p4runtime_solution", 4: "flowcache_solution"}
head = "wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\twritten_wall\tstop_reason\tmisdelivered\tforeign_frames\theard\tcontrollers\tctrl_logs"
if o.get("old_header") == "1":
    head = "wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches"
if o.get("old_header") == "2":
    head = "\t".join(head.split("\t")[:10])
if o.get("old_header") == "3":
    head = "\t".join(head.split("\t")[:12])
# each external arm's controller log: its key as the sampler names it, and the sizes it passes through
logs = {}
for i, w in which.items():
    found = glob.glob(os.path.join(fix, o.get("run", "t1") + "-rounds", f"*_{w}_ndtwin", "driver-controller-*.log"))
    if len(found) != 1:
        sys.exit(f"ms: {len(found)} controller log(s) for {w} in {o.get('run', 't1')}")
    data = open(found[0], "rb").read()
    lines = data.splitlines(keepends=True)
    header = sum(len(x) for x in lines if x.startswith(b"[adapter]"))
    first = next((sum(len(x) for x in lines[:n + 1]) for n, x in enumerate(lines) if b"SetForwardingPipelineConfig" in x), header)
    key = os.path.basename(os.path.dirname(found[0])) + "/" + os.path.basename(found[0])
    logs[i] = (key, header, first, len(data))
def ctrl_logs(t):
    out = []
    for i in sorted(logs):
        key, header, first, full = logs[i]
        k = t - T0 - 300 * i
        target = o.get("arm") == arms[i]
        push = int(o["push_at"]) if target and "push_at" in o else 45
        mid = int(o["mid_at"]) if target and "mid_at" in o else None
        if k < min(push, mid if mid is not None else push) - 5:
            continue
        size = header
        if mid is not None and k >= mid:
            size = first
        if k >= push:
            size = full
        if target and o.get("short_sizes") == "1":
            size = header
        out.append(f"{key}:{size}")
    if o.get("nolog_sizes") == "1":
        return "-"
    return ",".join(out) or "-"
# heard per direction (2 of them, +1 per 5 s round from 30 s into the arm) and the arm's controller pid
# (7001..7003) alive 40-160 s into its arm -- the pids are context now, not the window
ctl_pid = {"0a0a": 7001, "0b0b": 7002, "0c0c": 7003}
def heard(sess, k, target):
    a = b = (k - 30) // 5
    if target and "deaf_from" in o:            # the second direction heard nothing from deaf_from on
        b = (min(k, int(o["deaf_from"])) - 30) // 5
    if target and "late_from" in o:            # ... and nothing until late_from
        b = 0 if k < int(o["late_from"]) else (k - int(o["late_from"])) // 5 + 1
    if target and o.get("heard_bad") == "1" and k == 100:
        return "1:2>2:2=x"
    return f"1:2>2:2={a},2:2>1:2={b}"
def ctls(sess, k, target):
    if sess is None or not 40 <= k <= 160:
        return "-"
    return str(ctl_pid[sess])
def tail(t, sess, k, target, running):
    return "\t" + (heard(sess, k, target) if running else "-") + "\t" + ctls(sess, k, target) + "\t" + ctrl_logs(t)
rows = [head]
for t in range(T0, T0 + 1500):
    i, k = divmod(t - T0, 300)
    sess = arms.get(i)
    target = o.get("arm") == sess
    start_k = int(o["start_at"]) if target and "start_at" in o else 30
    if sess is None or k < start_k:
        rows.append(f"{t}\tabsent\t-\t-\t0\t0\t-\t\t0\t0" + tail(t, sess, k, target, False)); continue
    stop_k = int(o["stop_at"]) if target and "stop_at" in o else 200
    if target and "gap" in o and int(o["gap"]) <= k < int(o["gap"]) + 30:
        continue
    if k < stop_k or (target and o.get("restart") == "1" and k >= stop_k + 20):
        written = t - 1
        if target and "stale_from" in o and k >= int(o["stale_from"]):
            written = T0 + 300 * i + int(o["stale_from"])
        hosts = o.get("hosts", "0") if target and k == 100 else "0"
        between = o.get("between", "0") if target and k == 100 else "0"
        mis = "None" if target and o.get("counts_none") == "1" and k == 100 else "0"
        rows.append(f"{t}\trunning\t{sess}\t4242\t{hosts}\t{between}\t{written}\t\t{mis}\t0" + tail(t, sess, k, target, True))
        if target and o.get("second") == "1" and k == 120:
            rows.append(f"{t}.5\trunning\t0d0d\t4343\t0\t0\t{t}\t\t0\t0\t1:2>2:2=1\t-\t-")
    else:
        rows.append(f"{t}\tstopped\t{sess}\t-\t0\t0\t{T0 + 300 * i + stop_k}\tSIGTERM\t0\t0" + tail(t, sess, k, target, False))
open(os.path.join(d, "50_samples.tsv"), "w").write("\n".join(rows) + "\n")
if o.get("no_end") != "1":
    open(os.path.join(d, "50_t06_end.txt"), "w").write(f"{T0 + 1500}\n")
MS
mk() { "$EVIDENCE_PY" "$FIX/mk.py" "$FIX" "$@" || echo "fixture $1 not built"; }
ms() { "$EVIDENCE_PY" "$FIX/ms.py" "$FIX" "$@" || echo "samples $1 not built"; }
# [Co-developed with claude code -- Adam] every compare names the B commit (M-2) unless NO_BSHA=1.
BSHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ev() {
    if [[ "${1:-}" == compare && -z "${NO_BSHA:-}" ]]; then set -- "$@" --b-sha "$BSHA"; fi
    "$EVIDENCE_PY" "$TOOL" "$@" 2>&1; echo "RC=$?"
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
S="$FIX/h5/50_samples.tsv"

mk c1 control; mk c2 control; mk t1 treatment; ms h5
# =============================================================================================
section "1. 🔴 roles: only a treatment the samples show running, against controls with no trace of it"
# =============================================================================================
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
check "🔴 controls vs treatment, the same evidence, H5's samples: rc 0" "0" "$(rc_of "$OUT")"
has   "  and says so"                                      "NO DIFFERENCE in the external arms' own evidence (2 controls)" "$OUT"
has   "  naming each arm's session and how long it ran"   "hb      session 0b0b running from 1790000930 to 1790001100" "$OUT"
has   "  with the daemon's own counters, all 0"           "daemon  foreign_frames = 0; forwarded_between_switches = 0; forwarded_to_hosts = 0; misdelivered = 0 (the session's own counters, sampled, all 0)" "$OUT"
check "  every compared key of every arm said same"         "27" "$(/usr/bin/grep -c '^   same    ' <<<"$OUT")"
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2")"
check "🔴 no --samples: rc 3"                               "3" "$(rc_of "$OUT")"
has   "  said as such"                                     "REFUSED no --samples" "$OUT"
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --samples "$S")"
check "🔴 no --control2: rc 3"                              "3" "$(rc_of "$OUT")"
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c1" --samples "$S")"
check "🔴 --control2 that is the control itself: rc 3"      "3" "$(rc_of "$OUT")"
has   "  said as no spread"                                "a control compared with itself has no spread" "$OUT"
# [Co-developed with claude code -- Adam] (09-28) the treatment also passed as a control: refused
# by name. Its rc alone cannot tell this guard from check_roles (a treatment has the heartbeat's
# traces, so as a control it is refused anyway) -- the message is the check.
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --control2 "$FIX/t1" --samples "$S")"
has   "🔴 a treatment also given as a control: refused as such" "REFUSED the treatment is one of the controls" "$OUT"
mk c3 control
# [Co-developed with claude code -- Adam] (round 5) the "treatment" here carries a treatment's code
# identity, so it is the ROLE check that refuses it, not the identity check.
mk c2t control id_role=treatment
OUT="$(ev compare "$FIX/c1" "$FIX/c2t" --control2 "$FIX/c3" --samples "$S")"
check "🔴 A/A (a control as the treatment): rc 3"           "3" "$(rc_of "$OUT")"
has   "  refused for what it is, not for its identity"     "did not say it started the heartbeat detect-only" "$OUT"
mk t_noup treatment hb_up=0
OUT="$(ev compare "$FIX/c1" "$FIX/t_noup" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment with no detect-only start line: rc 3" "3" "$(rc_of "$OUT")"
mk t_stopped treatment hb_row=stopped
OUT="$(ev compare "$FIX/c1" "$FIX/t_stopped" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment whose status row is not running: rc 3" "3" "$(rc_of "$OUT")"
mk c_row control hb_row=running
OUT="$(ev compare "$FIX/c_row" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a control with a running row: rc 3"               "3" "$(rc_of "$OUT")"
has   "  said as not a control"                            "that is not a control" "$OUT"
mk c_trace control hb_up=1 hb_block=1 hb_row=stale
OUT="$(ev compare "$FIX/c_trace" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a control with the detect-only line and a heartbeat block, N5 STALE: rc 3" "3" "$(rc_of "$OUT")"
has   "  naming both traces"                               "the detect-only start line, a heartbeat block on switch_state" "$OUT"
mk c_block control hb_block=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_block" --samples "$S")"
check "🔴 a second control with only a heartbeat block: rc 3" "3" "$(rc_of "$OUT")"
# [Co-developed with claude code -- Adam] (round 5) stopped at 120 s: after the controller's window had
# opened (45 s) and before its last write at 150 s -- this cell is that check's alone
ms h5_once arm=0b0b stop_at=120
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_once/50_samples.tsv")"
check "🔴 a session sampled running, then stopped before the controller: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as stopped before the controller's last write" "before the exercise's controller last wrote its log" "$OUT"
ms h5_stale arm=0b0b stale_from=60
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_stale/50_samples.tsv")"
check "🔴 a stale 'running' left by a killed daemon: rc 3"  "3" "$(rc_of "$OUT")"
has   "  said as STALE"                                    "STALE: a daemon that died leaves 'running' behind" "$OUT"
ms h5_second arm=0c0c second=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_second/50_samples.tsv")"
check "🔴 a second session inside the arm window: rc 3"     "3" "$(rc_of "$OUT")"
has   "  naming it"                                        "another heartbeat session ran inside the arm window: ['0d0d']" "$OUT"
ms h5_gap arm=0a0a gap=80
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_gap/50_samples.tsv")"
check "🔴 a stretch of the session with no sample: rc 3"    "3" "$(rc_of "$OUT")"
has   "  said as not watched throughout"                   "was not watched throughout" "$OUT"
ms h5_restart arm=0b0b stop_at=160 restart=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_restart/50_samples.tsv")"
check "🔴 a session that stopped and ran again: rc 3"       "3" "$(rc_of "$OUT")"
has   "  said as such"                                     "stopped at 1790001060 and ran again" "$OUT"
ms h5_never arm=0c0c stop_at=0
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_never/50_samples.tsv")"
check "🔴 a session never sampled running: rc 3"            "3" "$(rc_of "$OUT")"
ms h5_hosts arm=0b0b hosts=2
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_hosts/50_samples.tsv")"
check "🔴 a session whose daemon counted a frame to a host: rc 1" "1" "$(rc_of "$OUT")"
has   "  said as ruling 4"                                 "!! DAEMON the heartbeat daemon counted, for this arm's session: {'forwarded_to_hosts': 2} -- ruling 4" "$OUT"
ms h5_between arm=0c0c between=3
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_between/50_samples.tsv")"
check "🔴 a session that forwarded between switches: rc 1"  "1" "$(rc_of "$OUT")"
OUT="$(ev show "$FIX/t1")"
has   "🔴 N4's counters are labelled as before the pipeline" "(before the exercise's pipeline was loaded: not evidence about the program)" "$OUT"
# [Co-developed with claude code -- Adam] The round-4 review's M-3: frames HEARD on every direction
# inside the exercise's controller's own window -- else the treatment arm is about nothing. Round 6: the
# window runs from the sample that saw the log reach its last pipeline push to the log's last write.
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
has   "🔴 every direction heard in the controller's window, said per direction" "heard   all 2 direction(s) in the controller's window (2026-09-21T142820Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log from its push to its last write), 1790000945-1790001050: 1:2>2:2 +21, 2:2>1:2 +21" "$OUT"
ms h5_deaf arm=0b0b deaf_from=46
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_deaf/50_samples.tsv")"
check "🔴 a direction heard only before the push (+1 per 5 s, 1-s reads): rc 3" "3" "$(rc_of "$OUT")"
has   "  naming the direction and the window"              "did not hear 1 of 2 direction(s) in the controller's window, 1790000945-1790001050" "$OUT"
has   "  and which one"                                    "2:2>1:2 stayed 3" "$OUT"
ms h5_late arm=0c0c late_from=151
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_late/50_samples.tsv")"
check "🔴 a direction heard only after the controller's last write: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as not heard in the window"                  "2:2>1:2 stayed 0" "$OUT"
ms h5_short arm=0a0a push_at=145
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_short/50_samples.tsv")"
check "🔴 a controller window of 5 s (under two periods): UNDECIDED, rc 2, not refused" "2" "$(rc_of "$OUT")"
has   "  said as too short, with its length"               "UNDECIDED heard     the controller's window, push seen at 1790000745 to its last write at 1790000750, is 5.0 s -- under two heartbeat periods (10 s)" "$OUT"
has   "  the rest of the comparison still printed"         "NO DIFFERENCE in the external arms' own evidence (2 controls); 1 UNDECIDED" "$OUT"
ms h5_ten arm=0a0a push_at=140
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_ten/50_samples.tsv")"
check "🔴 a window of exactly two periods is decided: rc 0" "0" "$(rc_of "$OUT")"
has   "  heard +2 in it"                                   "1790000740-1790000750: 1:2>2:2 +2, 2:2>1:2 +2" "$OUT"
ms h5_mid arm=0b0b mid_at=45 push_at=70
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_mid/50_samples.tsv")"
has   "🔴 the window opens at the LAST push (s2's at 70 s), not the first" "1790000970-1790001050: 1:2>2:2 +16, 2:2>1:2 +16" "$OUT"
ms h5_late_start arm=0b0b start_at=50
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_late_start/50_samples.tsv")"
check "🔴 a session first running after the push: rc 3"    "3" "$(rc_of "$OUT")"
has   "  said as the window not watched from its start"    "after the controller pushed its pipeline (1790000945) -- the window was not watched from its start" "$OUT"
mk t_nopush treatment nopush=p4rt_sol
ms h5_nopush run=t_nopush
OUT="$(ev compare "$FIX/c1" "$FIX/t_nopush" --control2 "$FIX/c2" --samples "$FIX/h5_nopush/50_samples.tsv")"
has   "🔴 no push line: the window opens at the first rule installed" "1790000945-1790001050: 1:2>2:2 +21" "$OUT"
# [Co-developed with claude code -- Adam] The round-4 review's M-2: the same code apart from B.
OUT="$(NO_BSHA=1 ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
check "🔴 no --b-sha: rc 3"                                 "3" "$(rc_of "$OUT")"
has   "  said as a missing --b-sha"                        "REFUSED no --b-sha" "$OUT"
has   "  the identities are said when they match"          "identity: the controls ran cccccccccccc with 1 uncommitted tracked file(s); the treatment ran dddddddddddd = that + B bbbbbbbbbbbb" "$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
mk c_noid control id=none
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_noid" --samples "$S")"
check "🔴 a control with no identity: rc 3"                 "3" "$(rc_of "$OUT")"
has   "  said as no identity"                              "no 00_identity.before.txt -- which code it ran is not known" "$OUT"
# [Co-developed with claude code -- Adam] (round 6) taken before AND after each run, and equal
mk c_noafter control id_after=none
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_noafter" --samples "$S")"
check "🔴 a control with no identity after it ran: rc 3"   "3" "$(rc_of "$OUT")"
has   "  said as no after-identity"                        "no 00_identity.after.txt" "$OUT"
mk c_drift control id_drift=kernel
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_drift" --samples "$S")"
check "🔴 a control whose kernel was rebuilt while it ran: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as the code changing during the run"         "the code changed while a run ran: kernel: c_drift before" "$OUT"
mk t_drift treatment id_drift=head
OUT="$(ev compare "$FIX/c1" "$FIX/t_drift" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment whose HEAD moved while it ran: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as its HEAD before and after"                "t_drift: head" "$OUT"
mk t_amend treatment id_merge_tree=0123456789012345678901234567890123456789
OUT="$(ev compare "$FIX/c1" "$FIX/t_amend" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment whose tree is not the two parents' merge: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as an amended or hand-resolved merge"        "an amended or hand-resolved merge" "$OUT"
mk t_tut treatment id_tut=8888888888888888888888888888888888888888
OUT="$(ev compare "$FIX/c1" "$FIX/t_tut" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment on another ~/tutorials: rc 3"        "3" "$(rc_of "$OUT")"
has   "  said as tutorials"                                "tutorials: controls" "$OUT"
mk t_libs treatment id_libs=22
OUT="$(ev compare "$FIX/c1" "$FIX/t_libs" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment on other bmv2 shared libraries: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as bmv2_libs"                                "bmv2_libs: controls" "$OUT"
# [Co-developed with claude code -- Adam] (round 6) the same compiler and compiled program in every run
mk t_p4c treatment p4c=0000000000000001
OUT="$(ev compare "$FIX/c1" "$FIX/t_p4c" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment compiled by another p4c: rc 3"       "3" "$(rc_of "$OUT")"
has   "  said as not the same compiler and program"        "p4runtime/skeleton: not the same compiler and program in every run" "$OUT"
mk c_json control json_fc_sol=0000000000000002
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_json" --samples "$S")"
check "🔴 a control whose flowcache JSON differs: rc 3"    "3" "$(rc_of "$OUT")"
has   "  naming the JSON"                                  "json ['flowcache.json 0000000000000002']" "$OUT"
mk t_noshas treatment noshas=p4rt_sol
OUT="$(ev compare "$FIX/c1" "$FIX/t_noshas" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a report with no p4c or JSON sha: rc 2"          "2" "$(rc_of "$OUT")"
has   "  said as such"                                     "names no p4c sha256 or no compiled JSON sha256" "$OUT"
mk c_head control id_head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_head" --samples "$S")"
check "🔴 controls on two different HEADs: rc 3"           "3" "$(rc_of "$OUT")"
has   "  said as the controls' code differing"            "the controls did not run the same code: HEAD" "$OUT"
mk t_moved treatment id_parent0=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
OUT="$(ev compare "$FIX/c1" "$FIX/t_moved" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment merged onto another trunk: rc 3"     "3" "$(rc_of "$OUT")"
has   "  said as trunk moved"                              "is not the controls' HEAD cccccccccccccccccccccccccccccccccccccccc: trunk moved between C and T" "$OUT"
mk t_otherb treatment id_parent1=9999999999999999999999999999999999999999
OUT="$(ev compare "$FIX/c1" "$FIX/t_otherb" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment that merged another commit than B: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as another B"                                "is not the B commit under test" "$OUT"
mk t_nomerge treatment id_nomerge=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_nomerge" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment that is not a merge: rc 3"           "3" "$(rc_of "$OUT")"
has   "  said as B not merged"                             "is the controls' HEAD: B was not merged" "$OUT"
mk t_dirty treatment id_uncommitted=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_dirty" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment with another uncommitted file: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as other uncommitted files"                  "uncommitted: controls" "$OUT"
mk t_kernel treatment id_kernel=k2
OUT="$(ev compare "$FIX/c1" "$FIX/t_kernel" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment on another kernel binary: rc 3"      "3" "$(rc_of "$OUT")"
has   "  said as another kernel"                           "kernel: controls" "$OUT"
mk t_single treatment id_single=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_single" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment that is a commit on the controls' HEAD, not a merge: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as not a merge"                              "has 1 parent(s), not a merge of two" "$OUT"
mk t_nochg treatment id_nochanges=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_nochg" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a treatment whose identity does not say what its merge changed: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as unknown merge changes"                    "does not say which files its merge changed" "$OUT"
mk t_touch treatment id_touch=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_touch" --control2 "$FIX/c2" --samples "$S")"
check "🔴 an uncommitted file that B's merge changes too: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as a file B changes"                         "uncommitted file(s) B also changes: ['p4_proxy/mininet/host_count_override']" "$OUT"

# =============================================================================================
section "2. 🔴 each kind of DECISIVE difference is named (rc 1); a descriptive one is noted, not counted"
# =============================================================================================
cmp() { ev compare "$FIX/c1" "$FIX/$1" --control2 "$FIX/c2" --samples "$S"; }
mk t_reads treatment reads_extra=1
OUT="$(cmp t_reads)"
check "🔴 one counter read more, same last values: rc 0"   "0" "$(rc_of "$OUT")"
has   "  the read count is printed, as not compared"       "counter_reads         3 (control 2; not compared" "$OUT"
# [Co-developed with claude code -- Adam] Round 5 (S-9, pre-registered): p4runtime/solution's final
# counters varied across earlier rounds -- described, not counted; the skeleton's never did.
mk t_200 treatment counters_p4rt_sol=3505,3505,8,8
OUT="$(cmp t_200)"
check "🔴 p4runtime/solution's counters ending elsewhere, invariants kept: noted, rc 0" "0" "$(rc_of "$OUT")"
has   "  noted as counters_final"                          "note    counters_final" "$OUT"
has   "  with the control beside it"                       "control: s1 MyIngress.egressTunnelCounter 200 = 7 packets" "$OUT"
has   "  said as outside the spread, not counted"          "OUTSIDE the controls' spread -- descriptive, not counted (pre-registered)" "$OUT"
mk t_skel_c treatment counters_p4rt_skel=5,0,1,0
OUT="$(cmp t_skel_c)"
check "🔴 the skeleton's counters, which never varied, ending elsewhere: rc 1" "1" "$(rc_of "$OUT")"
has   "  named as a DIFF in counters_final"                "DIFF    counters_final" "$OUT"
mk t_rule treatment drop_rule=1
OUT="$(cmp t_rule)"
check "🔴 a rule the controller did not install: rc 1"      "1" "$(rc_of "$OUT")"
has   "  named as rules_installed"                         "DIFF    rules_installed" "$OUT"
mk t_punt treatment punts_extra=1
OUT="$(cmp t_punt)"
check "🔴 a flowcache packet-in more (an IPv4 one; that count varied before): noted, rc 0" "0" "$(rc_of "$OUT")"
has   "  noted as packet_ins"                              "note    packet_ins" "$OUT"
hasnt "  and NOT as the heartbeat's"                       "carried the heartbeat's ethertype" "$OUT"
mk t_punt4 treatment punt_p4rt=p4rt_sol
OUT="$(cmp t_punt4)"
check "🔴 a packet-in on p4runtime, where there never was one: rc 1" "1" "$(rc_of "$OUT")"
has   "  named as a DIFF in packet_ins"                    "DIFF    packet_ins" "$OUT"
mk t_hb treatment punt_hb=1
OUT="$(cmp t_hb)"
check "🔴 a heartbeat frame at the exercise's controller: rc 1" "1" "$(rc_of "$OUT")"
has   "🔴 named as heartbeat_packet_ins"                    "DIFF    heartbeat_packet_ins  1" "$OUT"
has   "🔴 and as a non-IPv4 packet-in"                      "DIFF    non_ipv4_packet_ins   1" "$OUT"
has   "🔴 and said in words"                                "1 packet-in(s) carried the heartbeat's ethertype 0x88B5: the frame reached the exercise's own controller" "$OUT"
mk t_verdict treatment "verdict_sol=1	FAIL (4/5)"
OUT="$(cmp t_verdict)"
check "🔴 an arm whose verdict changed (verdicts were flaky before): noted, rc 0" "0" "$(rc_of "$OUT")"
has   "  noted as verdict"                                 "note    verdict" "$OUT"
has   "  and as rc"                                        "note    rc" "$OUT"
mk t_grpc treatment grpc=p4rt_skel
OUT="$(cmp t_grpc)"
check "🔴 a gRPC error more: rc 1"                          "1" "$(rc_of "$OUT")"
has   "  named as grpc_errors"                             "DIFF    grpc_errors" "$OUT"

# =============================================================================================
section "3. 🔴 descriptive: noted inside or OUTSIDE the controls' spread; decisive: controls that disagree are UNDECIDED"
# =============================================================================================
mk c2p control punts_extra=1
mk t_spread treatment punts_extra=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_spread" --control2 "$FIX/c2p" --samples "$S")"
check "🔴 a packet-in count between the controls': rc 0"    "0" "$(rc_of "$OUT")"
has   "  noted as inside the spread"                       "inside the controls' spread -- descriptive, not counted" "$OUT"
hasnt "  and not decided either way (descriptive)"          "UNDECIDED packet_ins" "$OUT"
mk t_out treatment punts_extra=3
OUT="$(ev compare "$FIX/c1" "$FIX/t_out" --control2 "$FIX/c2p" --samples "$S")"
check "🔴 a packet-in count outside the controls': noted, still rc 0" "0" "$(rc_of "$OUT")"
has   "  noted as OUTSIDE the spread"                      "OUTSIDE the controls' spread -- descriptive, not counted" "$OUT"
mk c3p control punts_extra=3
OUT="$(ev compare "$FIX/c1" "$FIX/t_out" --control2 "$FIX/c2p" --control2 "$FIX/c3p" --samples "$S")"
check "🔴 a third control that widens the spread: rc 0"     "0" "$(rc_of "$OUT")"
has   "  said with its count of controls"                  "(3 controls)" "$OUT"
has   "  and the treatment now inside it"                  "inside the controls' spread -- descriptive, not counted" "$OUT"
mk c2c control counters_p4rt_sol=3505,3505,9,9
mk t_c8 treatment counters_p4rt_sol=3505,3505,8,8
OUT="$(ev compare "$FIX/c1" "$FIX/t_c8" --control2 "$FIX/c2c" --samples "$S")"
check "🔴 tunnel counters between the controls': rc 0"      "0" "$(rc_of "$OUT")"
has   "  noted as inside the counters' spread"             "inside the controls' spread -- descriptive, not counted (pre-registered); control: s1" "$OUT"
mk t_c10 treatment counters_p4rt_sol=3505,3505,10,10
OUT="$(ev compare "$FIX/c1" "$FIX/t_c10" --control2 "$FIX/c2c" --samples "$S")"
check "🔴 tunnel counters outside the controls': noted, rc 0" "0" "$(rc_of "$OUT")"
has   "  noted as OUTSIDE the counters' spread"            "OUTSIDE the controls' spread -- descriptive, not counted (pre-registered); control: s1" "$OUT"
mk c2r control drop_rule=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2r" --samples "$S")"
check "🔴 controls that disagree on a decisive key (rules installed): UNDECIDED, rc 2" "2" "$(rc_of "$OUT")"
has   "  said as such"                                     "UNDECIDED rules_installed" "$OUT"
has   "  and in the conclusion"                            "1 UNDECIDED: the controls disagree on a decisive check" "$OUT"

# =============================================================================================
section "4. 🔴 invariants on each arm's own numbers, counted only when every control keeps them"
# =============================================================================================
# [Co-developed with claude code -- Adam] Round 5 (S-9): p4runtime/solution's two traffic sums broke
# in earlier no-heartbeat rounds (s1 ingress 100 = pings + datagrams held in 1 of 12) -- described;
# the 200 tunnel's sum and the skeleton's and flowcache's never broke -- decisive.
mk t_lost treatment counters_p4rt_sol=3504,3504,7,7 reads_extra=1
OUT="$(cmp t_lost)"
check "🔴 s1 ingress 100 one short of pings + datagrams (as 6 of 12 earlier rounds): noted, rc 0" "0" "$(rc_of "$OUT")"
has   "  noted as the invariant, descriptive"              "inv ..  s1 ingress 100 = pings + iperf datagrams: s1 ingress 100 = 3504; pings h1->h2 5 + datagrams to 10.0.2.2 3500 = 3505 (descriptive, not counted: pre-registered)" "$OUT"
mk t_eg treatment counters_p4rt_sol=3505,3504,7,7
OUT="$(cmp t_eg)"
has   "🔴 s2 egress 100 not s1 ingress 100: noted"          "inv ..  s2 egress 100 = s1 ingress 100: 3504 vs 3505" "$OUT"
mk t_200b treatment counters_p4rt_sol=3505,3505,7,8 reads_extra=1
OUT="$(cmp t_200b)"
check "🔴 the 200 tunnel's sum broken (it never broke before): rc 1" "1" "$(rc_of "$OUT")"
has   "  said as INV BAD"                                  "INV BAD s1 egress 200 = s2 ingress 200: 8 vs 7 (every control keeps it)" "$OUT"
mk c_arp control punt_arp=1
mk t_arp treatment punt_arp=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_arp" --control2 "$FIX/c_arp" --samples "$S")"
check "🔴 a decisive invariant broken in a control too: UNDECIDED, rc 2" "2" "$(rc_of "$OUT")"
has   "  said as a decisive invariant that is not one"     "UNDECIDED inv every packet-in is IPv4: broken in a control too" "$OUT"
mk t_skel treatment counters_p4rt_skel=5,1,0,0
OUT="$(cmp t_skel)"
has   "🔴 a skeleton counter that should be 0: INV BAD"     "INV BAD every other tunnel counter 0" "$OUT"
mk c_ack control no_ack=1 counters_p4rt_sol=3508,3508,7,7 reads_extra=1
OUT="$(ev show "$FIX/c_ack")"
has   "  up to 10 FIN retries when the client got no ack"  "inv ok  s1 ingress 100 = pings + iperf datagrams: s1 ingress 100 = 3508; pings h1->h2 5 + datagrams to 10.0.2.2 3500 + up to 10 FIN retries = 3505" "$OUT"
mk t_stray treatment stray_entry=1
OUT="$(cmp t_stray)"
has   "🔴 a cache entry that is no packet-in's flow: INV BAD" "INV BAD every cache entry is an IPv4 packet-in's flow: not a packet-in's flow: [('10.0.1.1', '10.0.3.3', 17)]" "$OUT"
has   "  and a note on cache_entries (descriptive)"        "note    cache_entries" "$OUT"

# =============================================================================================
section "5. 🔴 evidence that cannot be read is UNREADABLE (rc 2), never 'same', never a traceback"
# =============================================================================================
mk t_nolog treatment nolog=fc_sol
OUT="$(cmp t_nolog)"
check "🔴 an arm with no controller log: rc 2"              "2" "$(rc_of "$OUT")"
has   "  and says which"                                   "UNREADABLE" "$OUT"
hasnt "  and does not print a conclusion either way"       "DIFFERENCE" "$OUT"
mk t_norow treatment norow=fc_sol
OUT="$(cmp t_norow)"
check "🔴 a run without the flowcache/solution row: rc 2"   "2" "$(rc_of "$OUT")"
has   "  naming the arm"                                   "no flowcache/solution row" "$OUT"
mk t_trunc treatment truncate=p4rt_sol
OUT="$(cmp t_trunc)"
check "🔴 a counter block cut short: rc 2"                  "2" "$(rc_of "$OUT")"
has   "  said as cut short"                                "has 1 of 4 counters -- cut short" "$OUT"
mk t_unset treatment counters_p4rt_sol=3000,3000,5,5
OUT="$(cmp t_unset)"
check "🔴 a last counter block that had not settled: rc 2"  "2" "$(rc_of "$OUT")"
has   "  said as not settled"                              "the last counter block had not settled" "$OUT"
mk t_eq treatment counters_p4rt_sol=3000,3000,5,5 reads_extra=1
OUT="$(ev show "$FIX/t_eq")"
check "  the same numbers read twice are settled: show rc 0" "0" "$(rc_of "$OUT")"
mk t_garbage treatment punt_garbage=1
OUT="$(cmp t_garbage)"
check "🔴 a packet-in that cannot be parsed: rc 2"          "2" "$(rc_of "$OUT")"
has   "  said as such"                                     "a packet-in whose frame cannot be parsed" "$OUT"
mk t_short treatment punt_short=1
OUT="$(cmp t_short)"
check "🔴 an IPv4 packet-in shorter than its header: rc 2"  "2" "$(rc_of "$OUT")"
hasnt "  and no traceback"                                 "Traceback" "$OUT"
mk t_bytes treatment nonutf8=p4rt_skel
OUT="$(cmp t_bytes)"
check "🔴 a controller log that is not UTF-8: rc 2"         "2" "$(rc_of "$OUT")"
hasnt "  and no traceback"                                 "Traceback" "$OUT"
mk t_dir treatment report_is_dir=p4rt_sol
OUT="$(cmp t_dir)"
check "🔴 a report that cannot be read: rc 2"               "2" "$(rc_of "$OUT")"
hasnt "🔴 and no traceback from it"                         "Traceback" "$OUT"
ms h5_old old_header=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_old/50_samples.tsv")"
check "🔴 samples from a sampler before 09-28: rc 2"        "2" "$(rc_of "$OUT")"
has   "  said as a sampler from before round 6"            "a sampler from before round 6" "$OUT"
# [Co-developed with claude code -- Adam] round 5: the sampler's heard and controllers columns.
ms h5_r4 old_header=2
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_r4/50_samples.tsv")"
check "🔴 samples from round 4's sampler (no heard, no controllers): rc 2" "2" "$(rc_of "$OUT")"
# [Co-developed with claude code -- Adam] round 6: and its ctrl_logs column; logs it never saw grow
ms h5_r5 old_header=3
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_r5/50_samples.tsv")"
check "🔴 samples from round 5's sampler (no ctrl_logs): rc 2" "2" "$(rc_of "$OUT")"
ms h5_nosizes nolog_sizes=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_nosizes/50_samples.tsv")"
check "🔴 a sampler that never saw the controller's log: rc 2" "2" "$(rc_of "$OUT")"
has   "  said as such"                                     "the sampler never saw 2026-09-21T142320Z_p4runtime_skeleton_ndtwin/driver-controller-p4runtime.log" "$OUT"
ms h5_header arm=0c0c short_sizes=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_header/50_samples.tsv")"
check "🔴 a log the sampler never saw reach its push: rc 2" "2" "$(rc_of "$OUT")"
has   "  said as no window start"                          "never at the push's end" "$OUT"
mk t_bare treatment bare=p4rt_skel
ms h5_bare run=t_bare
OUT="$(ev compare "$FIX/c1" "$FIX/t_bare" --control2 "$FIX/c2" --samples "$FIX/h5_bare/50_samples.tsv")"
check "🔴 a controller log with no push and no entry: rc 2" "2" "$(rc_of "$OUT")"
has   "  said as a window with no start"                   "no pipeline push and no rule or cache entry" "$OUT"
ms h5_none arm=0b0b counts_none=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_none/50_samples.tsv")"
check "🔴 a running sample whose daemon counter is not a number: rc 2, not a zero" "2" "$(rc_of "$OUT")"
has   "  naming the counter"                               "counters misdelivered are not numbers" "$OUT"
ms h5_hbad arm=0c0c heard_bad=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_hbad/50_samples.tsv")"
check "🔴 a running sample whose heard column is not counts: rc 2" "2" "$(rc_of "$OUT")"
has   "  said as a heard column that is not counts"       "heard column is not numbers" "$OUT"
ms h5_noend no_end=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_noend/50_samples.tsv")"
check "🔴 samples without 06's end beside them: rc 2"       "2" "$(rc_of "$OUT")"
OUT="$(ev compare "$FIX/c1")"
check "🔴 a compare with one run: usage, rc 2"              "2" "$(rc_of "$OUT")"

# =============================================================================================
section "6. which code and which venv each run was"
# =============================================================================================
mk t_fp treatment venv=1 code=f7e2a128
OUT="$(cmp t_fp)"
has   "🔴 the control's code is printed"                    "code  5dc7fc9a +95 file(s) with uncommitted changes" "$OUT"
has   "🔴 and the treatment's"                              "code  f7e2a128 +95 file(s) with uncommitted changes" "$OUT"
has   "🔴 the treatment's protobuf is printed"              "/x/venv/bin/python: protobuf 5.29.6 api_implementation upb" "$OUT"
has   "  with the installed set's sha"                     "/x/venv/bin/python: distributions 28 sha256 d5fc" "$OUT"
has   "🔴 and the control's absence is said"                "venv  not recorded (no 00_venv.txt)" "$OUT"
check "  identity is not evidence: still rc 0"            "0" "$(rc_of "$OUT")"
OUT="$(ev show "$FIX/t_fp")"
check "  show: rc 0"                                       "0" "$(rc_of "$OUT")"
has   "  and lists the flowcache packet-ins"               "packet_ins            1" "$OUT"

# =============================================================================================
section "7. 🔴 code_identity.py record, on real repositories (round 6)"
# =============================================================================================
# [Co-developed with claude code -- Adam] What record writes, not what a fixture says it wrote: the
# code paths it compares (docs and audit tables left out), ~/tutorials, the fabric's libraries, and a
# merge's tree against what merging its parents gives. The copy beside the tool is the one run.
IDPY="$(dirname "$TOOL")/code_identity.py"
gi=(-c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=trunk)
G="$FIX/idrepo"; TUT="$FIX/tutorials"
mkdir -p "$G/doc/audit" "$G/p4_proxy/mininet" "$FIX/bmv2/bin" "$FIX/bmv2/lib" \
         "$TUT/exercises/p4runtime/build" "$TUT/exercises/flowcache" "$TUT/utils"
printf 'a\n' > "$G/a.py"; printf 'n\n' > "$G/doc/notes.md"; printf 't\n' > "$G/doc/audit/agents.tsv"
printf 'j\n' > "$G/doc/audit/raw.json"; printf '%s\n' "$FIX/bmv2/bin/simple_switch_grpc" > "$G/p4_proxy/mininet/bmv2_binary_override"
printf 'bin\n' > "$FIX/bmv2/bin/simple_switch_grpc"; printf 'so1\n' > "$FIX/bmv2/lib/libbm.so.0.0.0"
ln -s libbm.so.0.0.0 "$FIX/bmv2/lib/libbm.so"
printf 'c\n' > "$TUT/exercises/p4runtime/mycontroller.py"; printf 'f\n' > "$TUT/exercises/flowcache/flowcache.p4"
printf 'u\n' > "$TUT/utils/run.py"; printf 'build/\n' > "$TUT/.gitignore"
{ git "${gi[@]}" init -q "$G" && git -C "$G" add -A && git "${gi[@]}" -C "$G" commit -q -m c \
  && git "${gi[@]}" init -q "$TUT" && git -C "$TUT" add -A && git "${gi[@]}" -C "$TUT" commit -q -m t; } \
    || echo "  (the identity repositories could not be built)"
rec() { TUTORIALS_DIR="$TUT" CTRL_PY=/nonexistent "$EVIDENCE_PY" "$IDPY" record "$G" "$FIX/$1.json" > /dev/null 2>&1 || echo "record $1 failed"; }
jq_() { "$EVIDENCE_PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FIX/$1.json" "$2" 2>&1 | tail -1; }
why() { "$EVIDENCE_PY" -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import code_identity as c
a, b = (json.load(open(p)) for p in sys.argv[2:4]); print(sorted({r.split(":")[1].split()[0] if r.startswith("r ") else r.split(":")[0] for r in c.unchanged_reasons(a, b, "r")}))' \
        "$(dirname "$IDPY")" "$FIX/$1.json" "$FIX/$2.json" 2>&1 | tail -1; }
rec id0
printf 'a2\n' > "$G/a.py"; printf 'n2\n' > "$G/doc/notes.md"; printf 't2\n' > "$G/doc/audit/agents.tsv"; printf 'j2\n' > "$G/doc/audit/raw.json"
rec id1
check "🔴 uncommitted: a code file and an audit .json are recorded, a doc .md and an audit .tsv are not" \
      "['a.py', 'doc/audit/raw.json']" "$(jq_ id1 '[p for _s, p, _h in d["uncommitted"]]')"
git -C "$G" checkout -q -- a.py doc
check "  the tutorials' HEAD is recorded"                 "yes" "$(jq_ id0 '"yes" if d["tutorials"]["head"] == "'"$(git -C "$TUT" rev-parse HEAD)"'" else d["tutorials"]')"
printf 'rebuilt\n' > "$TUT/exercises/p4runtime/build/advanced_tunnel.json"
rec id2
check "🔴 a round rewriting build/ under an exercise does not change the identity" "[]" "$(why id0 id2)"
printf 'c2\n' > "$TUT/exercises/p4runtime/mycontroller.py"
rec id3
check "🔴 a changed exercise file in ~/tutorials does"   "['tutorials']" "$(why id0 id3)"
check "  in that exercise's tree digest"                 "changed" "$(a="$(jq_ id0 'd["tutorials"]["trees"]["exercises/p4runtime"]')"; b="$(jq_ id3 'd["tutorials"]["trees"]["exercises/p4runtime"]')"; [[ -n "$a" && "$a" != "$b" ]] && echo changed || echo "same: $a")"
git -C "$TUT" checkout -q -- exercises
printf 'mine\n' > "$TUT/exercises/flowcache/new_helper.py"
rec id3u
check "🔴 an untracked file in an exercise (git's porcelain does not show it) changes it too" "['tutorials']" "$(why id0 id3u)"
rm -f "$TUT/exercises/flowcache/new_helper.py"
check "  the fabric's libraries: the one shared object, its symlink not counted" "yes" "$(jq_ id0 '"yes" if ": 1 shared objects sha256 " in d["bmv2_libs"] else d["bmv2_libs"]')"
printf 'so2\n' > "$FIX/bmv2/lib/libbm.so.0.0.0"
rec id4
check "🔴 a rebuilt bmv2 shared library changes the identity" "['bmv2_libs']" "$(why id0 id4)"
# a merge: C on trunk, B on a branch, T = B merged onto C -- then the same merge amended by hand
bsha="$(git -C "$G" checkout -q -b b && printf 'b\n' > "$G/b.py" && git -C "$G" add b.py && git "${gi[@]}" -C "$G" commit -q -m b \
        && git -C "$G" rev-parse HEAD && git -C "$G" checkout -q trunk)"
rec idc
git "${gi[@]}" -C "$G" merge -q --no-ff --no-edit b > /dev/null 2>&1
rec idt
vf() { "$EVIDENCE_PY" "$IDPY" verify "$FIX/idc.json" "$FIX/$1.json" "$bsha" 2>&1; }
has   "🔴 a clean merge: its tree is what merging its parents gives" "SAME CODE APART FROM B" "$(vf idt)"
printf 'hand\n' > "$G/hand.py"; git -C "$G" add hand.py; git "${gi[@]}" -C "$G" commit -q --amend --no-edit
rec ida
has   "🔴 an amended merge is refused"                     "an amended or hand-resolved merge" "$(vf ida)"

# =============================================================================================
section "8. 🔴 the 34 rounds the split rests on, frozen (external_survey.py, S-9)"
# =============================================================================================
# [Co-developed with claude code -- Adam] Round 6: the survey reads only the rounds its manifest names, by
# sha256, and none of them may carry the heartbeat. Fixture: c1's two solution rounds in a prep dir of
# their own, and t1's p4runtime/solution round (it has the heartbeat).
SV="$(dirname "$TOOL")/external_survey.py"
P="$FIX/prep"; mkdir -p "$P/runs"; cp -r "$FIX/c1-rounds/." "$P/runs/"
mkdir -p "$P/hb"; cp -r "$FIX/t1-rounds/." "$P/hb/"
manifest() {   # manifest <out> <dir under P> <stamp_ex_which>... -- the manifest of those rounds, as frozen now
    local out="$1" sub="$2"; shift 2
    "$EVIDENCE_PY" - "$P" "$out" "$sub" "$@" <<'PY'
import glob, hashlib, os, sys
p, out, sub, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
sha = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest()
rows = ["arm\treport\treport_sha256\tlog\tlog_sha256"]
for n in names:
    md = os.path.join(p, sub, n + ".md")
    log = glob.glob(os.path.join(p, sub, n, "driver-controller-*.log"))[0]
    arm = "/".join(n.split("_")[1:3])
    rows.append("\t".join([arm, os.path.relpath(md, p), sha(md), os.path.relpath(log, p), sha(log)]))
open(out, "w").write("\n".join(rows) + "\n")
PY
}
sv() { "$EVIDENCE_PY" "$SV" "$P" "$1" 2>&1; echo "RC=$?"; }
SOL=2026-09-21T142820Z_p4runtime_solution_ndtwin; FC=2026-09-21T143320Z_flowcache_solution_ndtwin
manifest "$FIX/m_ok.tsv" runs "$SOL" "$FC"
OUT="$(sv "$FIX/m_ok.tsv")"
check "🔴 the frozen rounds as frozen, none with the heartbeat: rc 0" "0" "$(rc_of "$OUT")"
has   "  said as such"                                     "2 rounds, every report and controller log as frozen, none with the heartbeat" "$OUT"
has   "  with each field's count of values"                "rules_installed        1 distinct" "$OUT"
printf 'one more line\n' >> "$P/runs/$FC/driver-controller-flowcache.log"
OUT="$(sv "$FIX/m_ok.tsv")"
check "🔴 a round whose controller log changed since it was frozen: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as not what the manifest froze"              "the manifest froze" "$OUT"
manifest "$FIX/m_ok.tsv" runs "$SOL" "$FC"
mv "$P/runs/$SOL.md" "$P/runs/$SOL.md.gone"
OUT="$(sv "$FIX/m_ok.tsv")"
check "🔴 a frozen round that is gone: rc 3"               "3" "$(rc_of "$OUT")"
mv "$P/runs/$SOL.md.gone" "$P/runs/$SOL.md"
manifest "$FIX/m_hb.tsv" hb "$SOL"
OUT="$(sv "$FIX/m_hb.tsv")"
check "🔴 a round that had the heartbeat: rc 3"            "3" "$(rc_of "$OUT")"
has   "  said as not a round without it"                   "not a round without the heartbeat" "$OUT"
printf 'arm\treport\n' > "$FIX/m_bad.tsv"
OUT="$(sv "$FIX/m_bad.tsv")"
check "  a manifest that is not one: rc 2"                 "2" "$(rc_of "$OUT")"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
