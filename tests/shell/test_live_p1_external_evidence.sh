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
# [Co-developed with claude code -- Adam] 00_identity.txt (live-p1/code_identity.py): the controls on
# C, the treatment on C with B merged (the round-4 review's M-2). Options perturb one fact each.
C, B, T = "c" * 40, "b" * 40, "d" * 40
ident = {"format": 1, "repo": "/r", "recorded_at": T0, "head": o.get("id_head", C), "parents": ["a" * 40],
         "uncommitted": [[" M", "p4_proxy/mininet/host_count_override", "11"]],
         "kernel": ["/r/build/bin/ndtwin_kernel", o.get("id_kernel", "kk")],
         "bmv2_fabric": ["/usr/local/bmv2-fast/bin/simple_switch_grpc", "ff"],
         "bmv2_stock": ["/usr/local/bin/simple_switch", "ss"], "helper": ["/usr/local/sbin/ndtwin-lab", "hh"],
         "venv": {"/r/p4_proxy/venv/bin/python": "distributions 28 sha256 d5fc", "/x/python": "distributions 39 sha256 69c4"}}
if role == "treatment" or o.get("id_role") == "treatment":
    ident.update(head=T, parents=[o.get("id_parent0", C), o.get("id_parent1", B)],
                 merge_changes=["tools/test_workflow/ndt"])
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
if o.get("id") != "none":
    open(os.path.join(run, "00_identity.txt"), "w").write(json.dumps(ident, indent=2) + "\n")
ctl_pid = {"p4rt_skel": 7001, "p4rt_sol": 7002, "fc_sol": 7003}
for i, (ex, which, key) in enumerate(order):
    if key in ("basic", "fc_skel"):
        continue
    d = paths[key][:-3]; os.makedirs(d)
    md = [f"# report {ex}/{which}", "", "### 3. N3  ndt up p4 --app", "```"]
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
    if o.get("noctlpid") != key:
        md += ["## 8. 完整 transcript", "", "### stdout", "```",
               f"   controller pid {ctl_pid[key]} (handed to the generic cell; stopped after it)", "```", ""]
    if o.get("report_is_dir") == key:
        os.makedirs(paths[key])
    else:
        open(paths[key], "w").write("\n".join(md) + "\n")
    log = ["Installed P4 Program using SetForwardingPipelineConfig on s1",
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
# 2 s through 06 (arms 300 s apart from T0; 06 ends at T0+1500), each external arm's session running
# fresh from 30 s to 200 s into its arm, stopped by SIGTERM after; 50_t06_end.txt beside it.
cat > "$FIX/ms.py" <<'MS'
import os, sys
fix, name = sys.argv[1], sys.argv[2]
o = dict(a.split("=", 1) for a in sys.argv[3:])
T0 = 1790000000
d = os.path.join(fix, name); os.makedirs(d)
arms = {2: "0a0a", 3: "0b0b", 4: "0c0c"}
head = "wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\twritten_wall\tstop_reason\tmisdelivered\tforeign_frames\theard\tcontrollers"
if o.get("old_header") == "1":
    head = "wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches"
if o.get("old_header") == "2":
    head = "\t".join(head.split("\t")[:10])
# [Co-developed with claude code -- Adam] heard per direction (2 of them, one more per read) and the
# arm's controller pid (7001..7003, as mk's reports say) alive 40-160 s into its arm.
ctl_pid = {"0a0a": 7001, "0b0b": 7002, "0c0c": 7003}
def heard(sess, k, target):
    a, b = k - 30, k - 30
    if target and o.get("deaf") == "1" and k >= 40:
        b = 10
    if target and o.get("heard_bad") == "1" and k == 100:
        return "1:2>2:2=x"
    return f"1:2>2:2={a},2:2>1:2={b}"
def ctls(sess, k, target):
    if sess is None or not 40 <= k <= 160 or (target and o.get("noctl") == "1"):
        return "-"
    return str(ctl_pid[sess])
def tail(sess, k, target, running):
    return "\t" + (heard(sess, k, target) if running else "-") + "\t" + ctls(sess, k, target)
rows = [head]
for t in range(T0, T0 + 1500, 2):
    i, k = divmod(t - T0, 300)
    sess = arms.get(i)
    target = o.get("arm") == sess
    if sess is None or k < 30:
        rows.append(f"{t}\tabsent\t-\t-\t0\t0\t-\t\t0\t0" + tail(sess, k, target, False)); continue
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
        rows.append(f"{t}\trunning\t{sess}\t4242\t{hosts}\t{between}\t{written}\t\t{mis}\t0" + tail(sess, k, target, True))
        if target and o.get("second") == "1" and k == 120:
            rows.append(f"{t}.5\trunning\t0d0d\t4343\t0\t0\t{t}\t\t0\t0\t1:2>2:2=1\t-")
    else:
        rows.append(f"{t}\tstopped\t{sess}\t-\t0\t0\t{T0 + 300 * i + stop_k}\tSIGTERM\t0\t0" + tail(sess, k, target, False))
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
ms h5_once arm=0b0b stop_at=40
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
# while the exercise's controller ran -- else the treatment arm is about nothing.
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
has   "🔴 every direction heard while the controller ran, said per direction" "heard   all 2 direction(s) while the controller (pid 7002) ran, 1790000940-1790001060: 1:2>2:2 +120, 2:2>1:2 +120" "$OUT"
ms h5_deaf arm=0b0b deaf=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_deaf/50_samples.tsv")"
check "🔴 a direction not heard while the controller ran: rc 3" "3" "$(rc_of "$OUT")"
has   "  naming the direction and the controller"          "did not hear 1 of 2 direction(s) while the controller (pid 7002) ran" "$OUT"
has   "  and which one"                                    "2:2>1:2 stayed 10" "$OUT"
ms h5_noctl arm=0c0c noctl=1
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_noctl/50_samples.tsv")"
check "🔴 a controller the sampler never saw alive: rc 3"  "3" "$(rc_of "$OUT")"
has   "  said as no lifetime"                              "the sampler saw the controller (pid 7003) alive in 0 sample(s)" "$OUT"
mk t_noctl treatment noctlpid=p4rt_skel
OUT="$(ev compare "$FIX/c1" "$FIX/t_noctl" --control2 "$FIX/c2" --samples "$S")"
check "🔴 a round report that names no controller pid: rc 3" "3" "$(rc_of "$OUT")"
has   "  said as no controller pid in the report"         "names no single \`controller pid N\`" "$OUT"
# [Co-developed with claude code -- Adam] The round-4 review's M-2: the same code apart from B.
OUT="$(NO_BSHA=1 ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
check "🔴 no --b-sha: rc 3"                                 "3" "$(rc_of "$OUT")"
has   "  said as a missing --b-sha"                        "REFUSED no --b-sha" "$OUT"
has   "  the identities are said when they match"          "identity: the controls ran cccccccccccc with 1 uncommitted tracked file(s); the treatment ran dddddddddddd = that + B bbbbbbbbbbbb" "$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$S")"
mk c_noid control id=none
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_noid" --samples "$S")"
check "🔴 a control with no identity: rc 3"                 "3" "$(rc_of "$OUT")"
has   "  said as no identity"                              "no 00_identity.txt -- which code it ran is not known" "$OUT"
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
hasnt "  and not as a DIFF"                                "DIFF    packet_ins" "$OUT"
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
has   "  said as such"                                     "a sampler from before round 5" "$OUT"
# [Co-developed with claude code -- Adam] round 5: the sampler's heard and controllers columns.
ms h5_r4 old_header=2
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c2" --samples "$FIX/h5_r4/50_samples.tsv")"
check "🔴 samples from round 4's sampler (no heard, no controllers): rc 2" "2" "$(rc_of "$OUT")"
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

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
