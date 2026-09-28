#!/usr/bin/env bash
#
# live-p1/external_evidence.py, offline: a control 06 run (no heartbeat on the external arms) against
# a treatment (the heartbeat on them, detect only).
#
# [Co-developed with claude code -- Adam]
#
# 09-27: `ndt up p4 --app` starts the heartbeat on an external control plane too, and before that
# is merged the external arms' OWN evidence is compared, with and without it. This tool is that
# comparison's instrument; what is asserted is that it can tell the answers apart (the external
# judge's F1, F2, F7 and F8, 09-28):
#
#   1. roles: a treatment whose arms did not run the heartbeat (no detect-only start, no running
#      status row, no daemon counters, a session H5 never read running) and a control whose did are
#      REFUSED (rc 3) -- an A/A comparison can only print NO DIFFERENCE; a daemon that counted a
#      forwarded frame is a difference;
#   2. each kind of difference in the exercise's own evidence is named (rc 1), and more counter
#      reads are not one;
#   3. with a second control, a difference inside the two controls' spread is not counted, and one
#      outside it is;
#   4. each arm's invariants on its own numbers: the p4runtime tunnel counters against the pings and
#      iperf datagrams the round sent, the skeleton's zeros, flowcache's IPv4-only packet-ins and
#      cache entries that are packet-ins' flows;
#   5. what cannot be read is UNREADABLE (rc 2), never "same" and never a traceback: a missing log,
#      row or report, a counter block cut short, a packet-in that cannot be parsed, a log that is not
#      UTF-8;
#   6. the runs' code and venv fingerprints are printed.
#
# The fixtures are cut down from the shapes in live-p1/runs/2026-09-27T074635Z_06_thirteen's three
# external rounds -- 00_table.tsv, each round's report and controller log -- written here by a small
# generator; the real raw is not in the repository.
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

# The generator: mk <name> <control|treatment> [key=value ...]. Every run it writes satisfies every
# invariant unless an option says otherwise.
cat > "$FIX/mk.py" <<'MK'
import json, os, sys
fix, name, role = sys.argv[1], sys.argv[2], sys.argv[3]
o = dict(a.split("=", 1) for a in sys.argv[4:])
run, rounds = os.path.join(fix, name), os.path.join(fix, name + "-rounds")
os.makedirs(run); os.makedirs(rounds)
def ip(a): return bytes(int(x) for x in a.split("."))
def frame(src, dst, proto, ethertype=0x0800):
    eth = bytes.fromhex("080000000100") + bytes.fromhex("080000000111") + ethertype.to_bytes(2, "big")
    if ethertype != 0x0800:
        return eth + b"\x00\x01heartbeat"
    iph = bytes([0x45, 0, 0, 84, 0, 0, 0x40, 0, 64, proto, 0, 0]) + ip(src) + ip(dst)
    return eth + iph + b"\x00" * 8
def punt(sw, port, payload):
    return [f"Received PacketIn message of length {len(payload)} bytes from switch {sw}",
            "decodePacketInMetadata: ret=" + repr({"metadata": {"input_port": port, "punt_reason": 1, "opcode": 0},
                                                   "payload": payload})]
arms = [("p4runtime", "skeleton", "p4rt_skel"), ("p4runtime", "solution", "p4rt_sol"),
        ("flowcache", "solution", "fc_sol")]
tbl = ["exercise\twhich\trc\tverdict\treport",
       f"basic\tsolution\t0\tPASS (6/6)\t{rounds}/basic.md",
       "flowcache\tskeleton\t1\tRED ARM (1/1): skeleton does not compile, by design\t" + f"{rounds}/fc_skel.md"]
verdicts = {"p4rt_skel": "0\tPASS (4/4)", "p4rt_sol": o.get("verdict_sol", "0\tPASS (5/5)"), "fc_sol": "0\tPASS (5/5)"}
for ex, which, key in arms:
    if o.get("norow") == key:
        continue
    tbl.append(f"{ex}\t{which}\t{verdicts[key]}\t{rounds}/{key}.md")
open(os.path.join(run, "00_table.tsv"), "w").write("\n".join(tbl) + "\n")
hb = role == "treatment"
for ex, which, key in arms:
    d = os.path.join(rounds, key); os.makedirs(d)
    md = [f"# report {ex}/{which}", "", "### 3. N3  ndt up p4 --app", "```"]
    if o.get("hb_up", "1" if hb else "0") == "1":
        md.append("  ok  heartbeat running on the inter-switch veths, detect only: a cut link is told to the twin")
    md += ["```", "", "### 5. N5  ndt status", "```", f"  code           {o.get('code', '5dc7fc9a')}  +95 file(s) with uncommitted changes"]
    row = o.get("hb_row", "running" if hb else "stopped")
    if row == "running":
        md.append(f"  heartbeat      running (pid 4242, session {o.get('session', '0102abcd')}) -- 6 direction(s), report 1.0 s old")
    elif row == "stopped":
        md.append("  heartbeat      stopped (stopped by SIGTERM), 13 s ago")
    md.append("```")
    if hb and o.get("no_side") != "1":
        md += ["```json", '      "foreign_frames": 0,', '      "forwarded_between_switches": 0,',
               f'      "forwarded_to_hosts": {o.get("side_hosts", "0")},', '      "misdelivered": 0', "```"]
    md += ["", "### 7. P1  h1 ping h2 with the controller running", "```", "$ ping -c 5 -W 2 10.0.2.2", "```",
           "```", "5 packets transmitted, 5 received, 0% packet loss, time 4005ms", "```", ""]
    if o.get("report_is_dir") == key:
        os.makedirs(os.path.join(rounds, key + ".md"))
    else:
        open(os.path.join(rounds, key + ".md"), "w").write("\n".join(md) + "\n")
    log = [f"Installed P4 Program using SetForwardingPipelineConfig on s1",
           f"Installed P4 Program using SetForwardingPipelineConfig on s2"]
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
        if o.get("punt_garbage") == "1":
            log += ["Received PacketIn message of length 60 bytes from switch s3",
                    "decodePacketInMetadata: ret={'metadata': {'input_port': 2}, 'payload': <truncated>}"]
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
    open(os.path.join(d, name_log), "wb").write(data)
if o.get("venv"):
    open(os.path.join(run, "00_venv.txt"), "w").write(
        "== interpreter /x/venv/bin/python\nresolves_to /usr/bin/python3.13\npython 3.13.1 prefix /x/venv\n"
        "protobuf 5.29.6 api_implementation upb\ngrpcio 1.82.1\ndistributions 28 sha256 d5fc\n\n")
MK
mk() { "$EVIDENCE_PY" "$FIX/mk.py" "$FIX" "$@" || echo "fixture $1 not built"; }
ev() { "$EVIDENCE_PY" "$TOOL" "$@" 2>&1; echo "RC=$?"; }
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

mk c1 control; mk t1 treatment
# =============================================================================================
section "1. 🔴 roles: a treatment without the heartbeat, or a control with it, is REFUSED (rc 3)"
# =============================================================================================
OUT="$(ev compare "$FIX/c1" "$FIX/t1")"
check "🔴 control vs treatment, the same evidence: rc 0"   "0" "$(rc_of "$OUT")"
has   "  and says so"                                      "NO DIFFERENCE in the external arms' own evidence" "$OUT"
has   "  naming that one control cannot rule out noise"   "one control only: a DIFF below may be run-to-run noise" "$OUT"
has   "  the treatment's daemon counters are shown, all 0" "daemon  foreign_frames = 0; forwarded_between_switches = 0; forwarded_to_hosts = 0; misdelivered = 0" "$OUT"
check "  every compared key of every arm said same"         "27" "$(/usr/bin/grep -c '^   same    ' <<<"$OUT")"
mk c2 control
OUT="$(ev compare "$FIX/c1" "$FIX/c2")"
check "🔴 A/A (a control as the treatment): rc 3"           "3" "$(rc_of "$OUT")"
has   "  naming the missing detect-only start"             "treatment p4runtime/skeleton: \`ndt up\` did not say it started the heartbeat detect-only" "$OUT"
hasnt "  and no conclusion"                                "DIFFERENCE" "$OUT"
mk t_stopped treatment hb_row=stopped
OUT="$(ev compare "$FIX/c1" "$FIX/t_stopped")"
check "🔴 a treatment whose status row is not running: rc 3" "3" "$(rc_of "$OUT")"
has   "  naming the row it saw"                            "no \`heartbeat running (pid, session)\` row" "$OUT"
mk t_noup treatment hb_up=0
OUT="$(ev compare "$FIX/c1" "$FIX/t_noup")"
check "🔴 a treatment with no detect-only start line: rc 3" "3" "$(rc_of "$OUT")"
mk c_hb control hb_row=running
OUT="$(ev compare "$FIX/c_hb" "$FIX/t1")"
check "🔴 a control whose heartbeat was running: rc 3"      "3" "$(rc_of "$OUT")"
has   "  said as not a control"                            "that is not a control" "$OUT"
mk t_noside treatment no_side=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_noside")"
check "🔴 a treatment with no daemon counters: rc 3"        "3" "$(rc_of "$OUT")"
mk t_leak treatment side_hosts=2
OUT="$(ev compare "$FIX/c1" "$FIX/t_leak")"
check "🔴 a daemon that counted a frame to a host: rc 1"    "1" "$(rc_of "$OUT")"
has   "  said as ruling 4"                                 "!! DAEMON the heartbeat daemon counted frames it must not: {'forwarded_to_hosts': 2}" "$OUT"
printf 'wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\n1\trunning\t0102abcd\t4242\t0\t0\n2\tstopped\t0102abcd\t-\t0\t0\n' > "$FIX/samples_ok.tsv"
printf 'wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\n1\trunning\tffffeeee\t4242\t0\t0\n' > "$FIX/samples_other.tsv"
printf 'wall\tstatus\tsession\tpid\tforwarded_to_hosts\tforwarded_between_switches\n1\trunning\t0102abcd\t4242\t0\t3\n' > "$FIX/samples_fwd.tsv"
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --samples "$FIX/samples_ok.tsv")"
check "  with H5's samples naming the session running: rc 0" "0" "$(rc_of "$OUT")"
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --samples "$FIX/samples_other.tsv")"
check "🔴 a session H5 never read running: rc 3"           "3" "$(rc_of "$OUT")"
has   "  naming it"                                        "session 0102abcd was never sampled running" "$OUT"
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --samples "$FIX/samples_fwd.tsv")"
check "🔴 a sampled session that forwarded between switches: rc 3" "3" "$(rc_of "$OUT")"

# =============================================================================================
section "2. 🔴 each kind of difference in the exercise's own evidence is named (rc 1)"
# =============================================================================================
mk t_reads treatment reads_extra=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_reads")"
check "🔴 one counter read more, same last values: rc 0"   "0" "$(rc_of "$OUT")"
has   "  the read count is printed, as not compared"       "counter_reads         3 (control 2; not compared" "$OUT"
mk t_200 treatment counters_p4rt_sol=3505,3505,8,8
OUT="$(ev compare "$FIX/c1" "$FIX/t_200")"
check "🔴 a tunnel counter that ended elsewhere, invariants kept: rc 1" "1" "$(rc_of "$OUT")"
has   "  named as counters_final"                          "DIFF    counters_final" "$OUT"
has   "  with the control beside it"                       "control: s1 MyIngress.egressTunnelCounter 200 = 7 packets" "$OUT"
mk t_rule treatment drop_rule=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_rule")"
check "🔴 a rule the controller did not install: rc 1"      "1" "$(rc_of "$OUT")"
has   "  named as rules_installed"                         "DIFF    rules_installed" "$OUT"
mk t_punt treatment punts_extra=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_punt")"
check "🔴 a packet-in more (an IPv4 one): rc 1"             "1" "$(rc_of "$OUT")"
has   "  named as packet_ins"                              "DIFF    packet_ins" "$OUT"
hasnt "  and NOT as the heartbeat's"                       "carried the heartbeat's ethertype" "$OUT"
mk t_hb treatment punt_hb=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_hb")"
check "🔴 a heartbeat frame at the exercise's controller: rc 1" "1" "$(rc_of "$OUT")"
has   "🔴 named as heartbeat_packet_ins"                    "DIFF    heartbeat_packet_ins  1" "$OUT"
has   "🔴 and as a non-IPv4 packet-in"                      "DIFF    non_ipv4_packet_ins   1" "$OUT"
has   "🔴 and said in words"                                "1 packet-in(s) carried the heartbeat's ethertype 0x88B5: the frame reached the exercise's own controller" "$OUT"
mk t_verdict treatment "verdict_sol=1	FAIL (4/5)"
OUT="$(ev compare "$FIX/c1" "$FIX/t_verdict")"
check "🔴 an arm whose verdict changed: rc 1"               "1" "$(rc_of "$OUT")"
has   "  named as verdict"                                 "DIFF    verdict" "$OUT"
has   "  and as rc"                                        "DIFF    rc" "$OUT"
mk t_grpc treatment grpc=p4rt_skel
OUT="$(ev compare "$FIX/c1" "$FIX/t_grpc")"
check "🔴 a gRPC error more: rc 1"                          "1" "$(rc_of "$OUT")"
has   "  named as grpc_errors"                             "DIFF    grpc_errors" "$OUT"

# =============================================================================================
section "3. 🔴 with a second control, a difference inside the two controls' spread is not counted"
# =============================================================================================
mk c1b control punts_extra=1
mk t_spread treatment punts_extra=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_spread" --control2 "$FIX/c1b")"
check "🔴 a packet-in count between the controls': rc 0"    "0" "$(rc_of "$OUT")"
has   "  said as spread"                                   "spread  packet_ins" "$OUT"
hasnt "  and not as a DIFF"                                "DIFF    packet_ins" "$OUT"
hasnt "  and no one-control warning"                       "one control only" "$OUT"
mk t_out treatment punts_extra=3
OUT="$(ev compare "$FIX/c1" "$FIX/t_out" --control2 "$FIX/c1b")"
check "🔴 a packet-in count outside the controls': rc 1"    "1" "$(rc_of "$OUT")"
has   "  named as a DIFF"                                  "DIFF    packet_ins" "$OUT"
mk c_hb2 control hb_row=running
OUT="$(ev compare "$FIX/c1" "$FIX/t1" --control2 "$FIX/c_hb2")"
check "🔴 a second control with the heartbeat running: rc 3" "3" "$(rc_of "$OUT")"

# =============================================================================================
section "4. 🔴 invariants on each arm's own numbers"
# =============================================================================================
mk t_lost treatment counters_p4rt_sol=3504,3504,7,7
OUT="$(ev compare "$FIX/c1" "$FIX/t_lost")"
check "🔴 s1 ingress 100 one short of pings + datagrams: rc 1" "1" "$(rc_of "$OUT")"
has   "  said as the invariant, kept by the control"       "INV BAD s1 ingress 100 = pings + iperf datagrams: s1 ingress 100 = 3504; pings h1->h2 5 + datagrams to 10.0.2.2 3500 = 3505 (the control keeps it)" "$OUT"
mk t_eg treatment counters_p4rt_sol=3505,3504,7,7
OUT="$(ev compare "$FIX/c1" "$FIX/t_eg")"
has   "🔴 s2 egress 100 not s1 ingress 100: INV BAD"        "INV BAD s2 egress 100 = s1 ingress 100: 3504 vs 3505" "$OUT"
mk c_eg control counters_p4rt_sol=3505,3504,7,7
OUT="$(ev compare "$FIX/c_eg" "$FIX/t_eg")"
has   "  broken in the control too: shown, not counted"    "inv --  s2 egress 100 = s1 ingress 100: broken in the control too" "$OUT"
check "  and with nothing else different: rc 0"           "0" "$(rc_of "$OUT")"
mk t_skel treatment counters_p4rt_skel=5,1,0,0
OUT="$(ev compare "$FIX/c1" "$FIX/t_skel")"
has   "🔴 a skeleton counter that should be 0: INV BAD"     "INV BAD every other tunnel counter 0" "$OUT"
mk c_ack control no_ack=1 counters_p4rt_sol=3508,3508,7,7
OUT="$(ev show "$FIX/c_ack")"
has   "  up to 10 FIN retries when the client got no ack"  "inv ok  s1 ingress 100 = pings + iperf datagrams: s1 ingress 100 = 3508; pings h1->h2 5 + datagrams to 10.0.2.2 3500 + up to 10 FIN retries = 3505" "$OUT"
mk t_stray treatment stray_entry=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_stray")"
has   "🔴 a cache entry that is no packet-in's flow: INV BAD" "INV BAD every cache entry is an IPv4 packet-in's flow: not a packet-in's flow: [('10.0.1.1', '10.0.3.3', 17)]" "$OUT"
has   "  and a DIFF in cache_entries"                      "DIFF    cache_entries" "$OUT"

# =============================================================================================
section "5. 🔴 evidence that cannot be read is UNREADABLE (rc 2), never 'same', never a traceback"
# =============================================================================================
mk t_nolog treatment nolog=fc_sol
OUT="$(ev compare "$FIX/c1" "$FIX/t_nolog")"
check "🔴 an arm with no controller log: rc 2"              "2" "$(rc_of "$OUT")"
has   "  and says which"                                   "UNREADABLE" "$OUT"
hasnt "  and does not print a conclusion either way"       "DIFFERENCE" "$OUT"
mk t_norow treatment norow=fc_sol
OUT="$(ev compare "$FIX/c1" "$FIX/t_norow")"
check "🔴 a run without the flowcache/solution row: rc 2"   "2" "$(rc_of "$OUT")"
has   "  naming the arm"                                   "no flowcache/solution row" "$OUT"
mk t_trunc treatment truncate=p4rt_sol
OUT="$(ev compare "$FIX/c1" "$FIX/t_trunc")"
check "🔴 a counter block cut short: rc 2"                  "2" "$(rc_of "$OUT")"
has   "  said as cut short"                                "has 1 of 4 counters -- cut short" "$OUT"
mk t_garbage treatment punt_garbage=1
OUT="$(ev compare "$FIX/c1" "$FIX/t_garbage")"
check "🔴 a packet-in that cannot be parsed: rc 2"          "2" "$(rc_of "$OUT")"
has   "  said as such"                                     "a packet-in whose frame cannot be parsed" "$OUT"
mk t_bytes treatment nonutf8=p4rt_skel
OUT="$(ev compare "$FIX/c1" "$FIX/t_bytes")"
check "🔴 a controller log that is not UTF-8: rc 2"         "2" "$(rc_of "$OUT")"
hasnt "  and no traceback"                                 "Traceback" "$OUT"
mk t_dir treatment report_is_dir=p4rt_sol
OUT="$(ev compare "$FIX/c1" "$FIX/t_dir")"
check "🔴 a report that cannot be read: rc 2"               "2" "$(rc_of "$OUT")"
hasnt "  and no traceback"                                 "Traceback" "$OUT"
OUT="$(ev compare "$FIX/c1")"
check "  a compare with one run: usage, rc 2"             "2" "$(rc_of "$OUT")"

# =============================================================================================
section "6. which code and which venv each run was"
# =============================================================================================
mk t_fp treatment venv=1 code=f7e2a128
OUT="$(ev compare "$FIX/c1" "$FIX/t_fp")"
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
