#!/usr/bin/env bash
#
# live-p1/external_evidence.py, offline: the external arms' OWN evidence out of two 06 runs.
#
# [Co-developed with claude code -- Adam]
#
# 09-27: `ndt up p4 --app` starts the heartbeat on an external control plane too, detect only, and
# before that is merged a live 06 WITH it is compared against 06 without it (074635Z). This tool is
# that comparison's instrument, so what is asserted is that it can tell the answers apart:
#
#   * two runs whose controllers logged the same things compare equal (exit 0) -- also when one of
#     them read its counters more often, which is how long the arm ran and not evidence;
#   * a tunnel counter that ended elsewhere, a rule not installed, a cache entry more, a packet-in
#     more, a verdict that changed, a gRPC error more: each is a DIFF by name (exit 1);
#   * a packet-in whose frame carries the heartbeat's ethertype 0x88B5 is a DIFF AND is named as
#     the frame reaching the exercise's own controller;
#   * an arm whose round directory has no controller log is UNREADABLE (exit 2), never "same";
#   * each run's venv fingerprint is printed when it has one, and "not recorded" when it has not.
#
# The fixtures are cut down from the shapes in live-p1/runs/2026-09-27T074635Z_06_thirteen's three
# external rounds (their controller logs), written here -- the real raw is not in the repository.
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

# mkrun <name> -- a 06 run directory whose three external rounds carry the baseline's evidence.
mkrun() {
    local run="$FIX/$1" rounds="$FIX/$1-rounds"
    mkdir -p "$run" "$rounds/p4rt_skel" "$rounds/p4rt_sol" "$rounds/fc_sol"
    printf 'exercise\twhich\trc\tverdict\treport\n' > "$run/00_table.tsv"
    printf 'basic\tsolution\t0\tPASS (6/6)\t%s\n' "$rounds/basic.md" >> "$run/00_table.tsv"
    printf 'p4runtime\tskeleton\t0\tPASS (4/4)\t%s\n' "$rounds/p4rt_skel.md" >> "$run/00_table.tsv"
    printf 'p4runtime\tsolution\t0\tPASS (5/5)\t%s\n' "$rounds/p4rt_sol.md" >> "$run/00_table.tsv"
    printf 'flowcache\tskeleton\t1\tRED ARM (1/1): skeleton does not compile, by design\t%s\n' "$rounds/fc_skel.md" >> "$run/00_table.tsv"
    printf 'flowcache\tsolution\t0\tPASS (5/5)\t%s\n' "$rounds/fc_sol.md" >> "$run/00_table.tsv"
    counters() {   # counters <in100> <eg100> <in200> <eg200>
        printf '\n----- Reading tunnel counters -----\n'
        printf 's1 MyIngress.ingressTunnelCounter 100: %s\n' "$1"
        printf 's2 MyIngress.egressTunnelCounter 100: %s\n' "$2"
        printf 's2 MyIngress.ingressTunnelCounter 200: %s\n' "$3"
        printf 's1 MyIngress.egressTunnelCounter 200: %s\n' "$4"
    }
    {
        echo "Installed P4 Program using SetForwardingPipelineConfig on s1"
        echo "Installed P4 Program using SetForwardingPipelineConfig on s2"
        echo "Installed ingress tunnel rule on s1"
        echo "Installed egress tunnel rule on s2"
        counters "0 packets (0 bytes)" "0 packets (0 bytes)" "0 packets (0 bytes)" "0 packets (0 bytes)"
        counters "5 packets (490 bytes)" "0 packets (0 bytes)" "0 packets (0 bytes)" "0 packets (0 bytes)"
    } > "$rounds/p4rt_skel/driver-controller-p4runtime.log"
    {
        echo "Installed P4 Program using SetForwardingPipelineConfig on s1"
        echo "Installed P4 Program using SetForwardingPipelineConfig on s2"
        echo "Installed ingress tunnel rule on s1"
        echo "Installed transit tunnel rule on s1"
        echo "Installed egress tunnel rule on s2"
        counters "0 packets (0 bytes)" "0 packets (0 bytes)" "0 packets (0 bytes)" "0 packets (0 bytes)"
        counters "3505 packets (4347490 bytes)" "3505 packets (4361510 bytes)" "7 packets (830 bytes)" "7 packets (858 bytes)"
    } > "$rounds/p4rt_sol/driver-controller-p4runtime.log"
    {
        echo "Installed P4 Program using SetForwardingPipelineConfig on s1"
        echo "Received PacketIn message of length 98 bytes from switch s1"
        echo "decodePacketInMetadata: ret={'metadata': {'input_port': 1, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\\x08\\x00\\x00\\x00\\x01\\x00\\x08\\x00\\x00\\x00\\x01\\x11\\x08\\x00E\\x00\\x00T'}"
        echo "For switch s1 flow (SA=10.0.1.1, DA=10.0.2.2, proto=1) added table entry to send packets to port 2 with new DSCP 5"
        echo "s1 MyIngress.ingressPktOutCounter 2: 1 packets (104 bytes)"
        echo "gRPC error occurred: <_InactiveRpcError of RPC that terminated with:"
    } > "$rounds/fc_sol/driver-controller-flowcache.log"
}
ev() { "$EVIDENCE_PY" "$TOOL" "$@" 2>&1; echo "RC=$?"; }
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
line_of() { /usr/bin/grep -F -- "$2" <<<"$1" | head -1 | sed 's/^ *//'; }

# =============================================================================================
section "1. 🔴 the same evidence compares equal -- and more counter reads are not a difference"
# =============================================================================================
mkrun base; mkrun same
OUT="$(ev compare "$FIX/base" "$FIX/same")"
check "🔴 identical logs: rc 0"                             "0" "$(rc_of "$OUT")"
has   "  and says so"                                      "NO DIFFERENCE in the external arms' own evidence" "$OUT"
check "  every compared key of every arm said same"         "24" "$(/usr/bin/grep -c '^   same  ' <<<"$OUT")"
mkrun longer
printf '\n----- Reading tunnel counters -----\ns1 MyIngress.ingressTunnelCounter 100: 3505 packets (4347490 bytes)\ns2 MyIngress.egressTunnelCounter 100: 3505 packets (4361510 bytes)\ns2 MyIngress.ingressTunnelCounter 200: 7 packets (830 bytes)\ns1 MyIngress.egressTunnelCounter 200: 7 packets (858 bytes)\n' \
    >> "$FIX/longer-rounds/p4rt_sol/driver-controller-p4runtime.log"
OUT="$(ev compare "$FIX/base" "$FIX/longer")"
check "🔴 one read more, same last values: rc 0"           "0" "$(rc_of "$OUT")"
has   "  the read count is printed, as not compared"       "counter_reads         3 (baseline 2; not compared" "$OUT"

# =============================================================================================
section "2. 🔴 each kind of difference in the exercise's own evidence is named"
# =============================================================================================
mkrun counter
sed -i 's/^s2 MyIngress.egressTunnelCounter 100: 3505 packets (4361510 bytes)$/s2 MyIngress.egressTunnelCounter 100: 3504 packets (4360264 bytes)/' \
    "$FIX/counter-rounds/p4rt_sol/driver-controller-p4runtime.log"
OUT="$(ev compare "$FIX/base" "$FIX/counter")"
check "🔴 a tunnel counter that ended elsewhere: rc 1"      "1" "$(rc_of "$OUT")"
has   "  named as counters_final"                          "DIFF  counters_final" "$OUT"
has   "  with the baseline beside it"                      "s2 MyIngress.egressTunnelCounter 100 = 3505 packets (4361510 bytes)" "$OUT"

mkrun rule
sed -i '/^Installed transit tunnel rule on s1$/d' "$FIX/rule-rounds/p4rt_sol/driver-controller-p4runtime.log"
OUT="$(ev compare "$FIX/base" "$FIX/rule")"
check "🔴 a rule the controller did not install: rc 1"      "1" "$(rc_of "$OUT")"
has   "  named as rules_installed"                         "DIFF  rules_installed" "$OUT"

mkrun entry
echo "For switch s2 flow (SA=10.0.1.1, DA=10.0.2.2, proto=1) added table entry to send packets to port 1 with new DSCP 5" \
    >> "$FIX/entry-rounds/fc_sol/driver-controller-flowcache.log"
OUT="$(ev compare "$FIX/base" "$FIX/entry")"
check "🔴 a cache entry more: rc 1"                         "1" "$(rc_of "$OUT")"
has   "  named as cache_entries"                           "DIFF  cache_entries" "$OUT"

mkrun punt
{
    echo "Received PacketIn message of length 98 bytes from switch s2"
    echo "decodePacketInMetadata: ret={'metadata': {'input_port': 2, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\\x08\\x00\\x00\\x00\\x02\\x00\\x08\\x00\\x00\\x00\\x02\\x22\\x08\\x00E\\x00\\x00T'}"
} >> "$FIX/punt-rounds/fc_sol/driver-controller-flowcache.log"
OUT="$(ev compare "$FIX/base" "$FIX/punt")"
check "🔴 a packet-in more (an IPv4 one): rc 1"             "1" "$(rc_of "$OUT")"
has   "  named as packet_ins"                              "DIFF  packet_ins" "$OUT"
hasnt "  and NOT as the heartbeat's"                       "carried the heartbeat's ethertype" "$OUT"

mkrun heartbeat
{
    echo "Received PacketIn message of length 60 bytes from switch s3"
    echo "decodePacketInMetadata: ret={'metadata': {'input_port': 2, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\\xff\\xff\\xff\\xff\\xff\\xff\\x02\\x00\\x00\\x00\\x00\\x01\\x88\\xb5\\x00\\x01'}"
} >> "$FIX/heartbeat-rounds/fc_sol/driver-controller-flowcache.log"
OUT="$(ev compare "$FIX/base" "$FIX/heartbeat")"
check "🔴 a heartbeat frame at the exercise's controller: rc 1" "1" "$(rc_of "$OUT")"
has   "🔴 named as heartbeat_packet_ins"                    "DIFF  heartbeat_packet_ins  1" "$OUT"
has   "🔴 and said in words"                                "1 packet-in(s) carried the heartbeat's ethertype 0x88B5: the frame reached the exercise's own controller" "$OUT"

mkrun verdict
sed -i 's/^p4runtime\tsolution\t0\tPASS (5\/5)/p4runtime\tsolution\t1\tFAIL (4\/5)/' "$FIX/verdict/00_table.tsv"
OUT="$(ev compare "$FIX/base" "$FIX/verdict")"
check "🔴 an arm whose verdict changed: rc 1"               "1" "$(rc_of "$OUT")"
has   "  named as verdict"                                 "DIFF  verdict" "$OUT"
has   "  and as rc"                                        "DIFF  rc" "$OUT"

mkrun grpc
echo "gRPC error occurred: <_InactiveRpcError of RPC that terminated with:" >> "$FIX/grpc-rounds/p4rt_skel/driver-controller-p4runtime.log"
OUT="$(ev compare "$FIX/base" "$FIX/grpc")"
check "🔴 a gRPC error more: rc 1"                          "1" "$(rc_of "$OUT")"
has   "  named as grpc_errors"                             "DIFF  grpc_errors" "$OUT"

# =============================================================================================
section "3. 🔴 evidence that cannot be read is UNREADABLE, never 'same'"
# =============================================================================================
mkrun nolog
rm "$FIX/nolog-rounds/fc_sol/driver-controller-flowcache.log"
OUT="$(ev compare "$FIX/base" "$FIX/nolog")"
check "🔴 an arm with no controller log: rc 2"              "2" "$(rc_of "$OUT")"
has   "  and says which"                                   "UNREADABLE" "$OUT"
hasnt "  and does not print a conclusion either way"       "DIFFERENCE" "$OUT"
mkrun norow
sed -i '/^flowcache\tsolution/d' "$FIX/norow/00_table.tsv"
OUT="$(ev compare "$FIX/base" "$FIX/norow")"
check "🔴 a run without the flowcache/solution row: rc 2"   "2" "$(rc_of "$OUT")"
has   "  naming the arm"                                   "no flowcache/solution row" "$OUT"

# =============================================================================================
section "4. each run's venv fingerprint is printed, or said to be missing"
# =============================================================================================
mkrun fp
printf '== interpreter /x/venv/bin/python\nresolves_to /usr/bin/python3.13\npython 3.13.1 prefix /x/venv\nprotobuf 5.29.6 api_implementation upb\ngrpcio 1.82.1\ndistributions 28 sha256 d5fc\n\n' > "$FIX/fp/00_venv.txt"
OUT="$(ev compare "$FIX/base" "$FIX/fp")"
has   "🔴 the new run's protobuf is printed"                 "/x/venv/bin/python: protobuf 5.29.6 api_implementation upb" "$OUT"
has   "  with the installed set's sha"                     "/x/venv/bin/python: distributions 28 sha256 d5fc" "$OUT"
has   "🔴 and the baseline's absence is said"                "venv  not recorded (no 00_venv.txt)" "$OUT"
check "  a fingerprint is not evidence: still rc 0"         "0" "$(rc_of "$OUT")"
OUT="$(ev show "$FIX/fp")"
check "  show: rc 0"                                       "0" "$(rc_of "$OUT")"
has   "  and lists the flowcache packet-ins"               "packet_ins            1" "$OUT"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
