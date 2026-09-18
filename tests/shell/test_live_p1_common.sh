#!/usr/bin/env bash
#
# The three helpers live-p1/03 uses to check that the twin's liveness follows the exercise's own
# pipeline pushes, driven OFFLINE.
#
# [Co-developed with claude code -- Adam]
#
# WHAT THIS IS FOR. `live-p1/03` used to assert `3 switches, 3 up` after `ndt up p4 --app` over
# an external package, and on 2026-09-18 that assertion passed and then failed on two runs of
# the same code. Neither reading was about the fabric: under `mode: external` NDTwin loads no
# pipeline, the liveness probe is a GetForwardingPipelineConfig, a bmv2 with no program answers
# FAILED_PRECONDITION, and the twin's own policy calls such a switch Down. The only writer of
# isUp there is the proxy's `inform_switch_entered` background retry (30 x 10 s, and it does not
# consult read_only), which the kernel's 1 Hz pingWorker undoes a second later -- so `3 up` was
# one read landing in a <= 1 s window, and the same script's `ndt status` a second later read
# `0 up, 3 enabled`. TICKET-P2-F replaced it with the property that IS stable: the switches the
# twin calls up are exactly the switches the exercise's controller loaded a program onto.
#
# 🔴 WHAT MUST NOT HAPPEN IS HALF THE SUBJECT:
#   * the expectation is PARSED OUT OF THE CONTROLLER'S OWN LOG, never written down. A constant
#     would keep passing the day the exercise programs different switches, and would be 03
#     agreeing with itself;
#   * an EMPTY expectation is refused. If the log named no switch, "the twin agrees with the
#     controller" is an equality between two empty sets -- true of a dead fabric, a broken
#     parser and a controller that never started, alike. That is the greenest possible way to
#     check nothing, and it is the control this whole check rests on;
#   * the match is EXACT, not "at least". s3 never gets a program in this exercise, so a twin
#     calling it up is reporting liveness it has no evidence for -- which is the defect being
#     replaced, in a new costume.
#
# `_common.sh` is sourced in a subshell (it defines names and sets variables; nothing runs until
# `start_step`), `curl` is a stub answering a fixture graph, and nothing here reaches root, a
# port, Mininet or the real lab.
#
# Run:  bash tests/shell/test_live_p1_common.sh
# Env:  COMMON_UNDER_TEST=<path>  (tests/shell/mutate_live_p1_common.sh points it at a copy)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
LIVE="$REAL_REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1"
COMMON="${COMMON_UNDER_TEST:-$LIVE/_common.sh}"
[[ -r "$COMMON" ]] || { echo "  FAILED   no _common.sh at $COMMON"; echo "Ran 1 checks, 1 failed"; exit 1; }

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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-common-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM

# mkgraph <file> <up-dpid,...> -- a /ndt/get_graph_data body for three switches and three hosts.
# Every switch is is_enabled, which is what an external fabric really looks like after the
# proxy's inform_switch_entered retry has landed; only is_up varies.
mkgraph() {
    python3 - "$1" "${2:-}" <<'PY'
import json, sys
up = {int(x) for x in sys.argv[2].split(",") if x}
nodes = [{"device_name": "s%d" % d, "dpid": d, "vertex_type": 0,
          "is_up": d in up, "is_enabled": True} for d in (1, 2, 3)]
nodes += [{"device_name": "h%d" % h, "dpid": 0, "vertex_type": 1} for h in (1, 2, 3)]
json.dump({"nodes": nodes, "edges": []}, open(sys.argv[1], "w"))
PY
}
G_NONE="$FIX/g_none.json"; mkgraph "$G_NONE" ""
G_12="$FIX/g_12.json";     mkgraph "$G_12" "1,2"
G_123="$FIX/g_123.json";   mkgraph "$G_123" "1,2,3"
G_3="$FIX/g_3.json";       mkgraph "$G_3" "3"
printf 'not a graph at all\n' > "$FIX/g_junk.json"
# 🔴 A graph the kernel DID answer, that contains no switch at all. Distinct from junk on the
# wire and distinct from "nothing is up": on an external fabric nothing being up is the ordinary
# state, so a kernel that has lost the switches entirely must not read the same as one that is
# simply reporting them all down.
python3 -c '
import json, sys
json.dump({"nodes": [{"device_name": "h1", "dpid": 0, "vertex_type": 1}], "edges": []},
          open(sys.argv[1], "w"))' "$FIX/g_noswitch.json"

# Controller logs, verbatim in shape from live-p1/runs/2026-09-18T132821Z_03_app_p4runtime/
# 37_skeleton_controller.log.
cat > "$FIX/log_s1s2.txt" <<'LOG'
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed ingress tunnel rule on s1
TODO Install transit tunnel rule
LOG
cat > "$FIX/log_none.txt" <<'LOG'
[adapter] running          /home/adam/tutorials/exercises/p4runtime/mycontroller.py
Traceback (most recent call last):
  grpc._channel._InactiveRpcError: failed to connect
LOG
cat > "$FIX/log_s10.txt" <<'LOG'
Installed P4 Program using SetForwardingPipelineConfig on s10
Installed P4 Program using SetForwardingPipelineConfig on s2
LOG

# --- the seam -------------------------------------------------------------------------------
# 🔴 THE GRAPH IS A SEQUENCE, not a constant: one file per curl, the last repeating. That is the
# only way to tell "waited until it became right" from "read once and got lucky", which is the
# distinction this whole ticket is about. The counter is a file because every curl in these
# helpers runs inside a command substitution.
STUBS='
KERNEL_URL="http://localhost:8000"
PY="'"$REAL_REPO"'/p4_proxy/venv/bin/python"
curl() {
    printf "%s\n" "$*" >> "'"$FIX"'/curl.log"
    local i seq
    i="$(cat "'"$FIX"'/g.n" 2>/dev/null)"; i="${i:-0}"
    echo "$(( i + 1 ))" > "'"$FIX"'/g.n"
    read -r -a seq <<< "${GRAPH_SEQ:-}"
    [[ ${#seq[@]} -eq 0 ]] && return 1
    cat "${seq[i]:-${seq[$(( ${#seq[@]} - 1 ))]}}"
}
sleep() { printf "sleep %s\n" "$*" >> "'"$FIX"'/sleep.log"; }
'
drive() {   # drive <shell code> -> its output plus a trailing RC=<n>
    : > "$FIX/curl.log"; : > "$FIX/sleep.log"; rm -f "$FIX/g.n"
    bash -c "source '$COMMON' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
one()   { drive "$1" | /usr/bin/grep -v '^RC=' | head -1; }
reads() {
    local n; n="$(/usr/bin/grep -c 'get_graph_data' "$FIX/curl.log" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# =============================================================================================
section "1. controller_program_set -- the expectation comes out of the controller's own log"
# =============================================================================================
check "  the two switches this exercise programs"        "1,2" "$(one "controller_program_set '$FIX/log_s1s2.txt'")"
check "🔴 a controller that programmed nothing gives an EMPTY set" "" "$(one "controller_program_set '$FIX/log_none.txt'")"
check "🔴 s10 is dpid 10, not dpid 1"                    "2,10" "$(one "controller_program_set '$FIX/log_s10.txt'")"
check "  a log that is not there is empty, not an error" "" "$(one "controller_program_set '$FIX/no-such.log'")"

# =============================================================================================
section "2. kernel_up_set -- which switches the twin says are up, right now"
# =============================================================================================
check "  two of three up"                                "1,2" "$(one "GRAPH_SEQ='$G_12'; kernel_up_set")"
check "  all three up"                                   "1,2,3" "$(one "GRAPH_SEQ='$G_123'; kernel_up_set")"
check "🔴 none up is an EMPTY answer, not a missing one"  "" "$(one "GRAPH_SEQ='$G_NONE'; kernel_up_set")"
OUT="$(drive "GRAPH_SEQ='$G_NONE'; kernel_up_set")"
check "  and it is rc 0 -- 'nothing is up' is a reading" "0" "$(rc_of "$OUT")"
OUT="$(drive "GRAPH_SEQ='$FIX/g_junk.json'; kernel_up_set")"
check "🔴 an unreadable graph is rc 1, NOT an empty set"  "1" "$(rc_of "$OUT")"
OUT="$(drive "kernel_up_set")"
check "  and so is an endpoint that does not answer"     "1" "$(rc_of "$OUT")"
OUT="$(drive "GRAPH_SEQ='$FIX/g_noswitch.json'; kernel_up_set")"
check "🔴 a graph with no switches in it is rc 1 too"    "1" "$(rc_of "$OUT")"

# =============================================================================================
section "3. await_kernel_up_set -- it waits, and it matches EXACTLY"
# =============================================================================================
# (a) it waits rather than sampling: nothing, nothing, then the two the controller programmed.
OUT="$(drive "GRAPH_SEQ='$G_NONE $G_NONE $G_12'; await_kernel_up_set '1,2' 20 '$FIX/out.txt'")"
check "🔴 it waits until the up set becomes the expected one" "0" "$(rc_of "$OUT")"
# Three polls plus one more: the raw capture re-reads the graph to write the per-switch rows.
check "  which took three polls, not one"                "4" "$(reads)"
has   "  and it says how long it took"                   "reached after:                      2s" "$(cat "$FIX/out.txt")"
has   "  the file names the expectation and its source"  "expected (from the controller log): 1,2" "$(cat "$FIX/out.txt")"
has   "  and the per-switch rows behind the verdict"     "dpid is_up is_enabled" "$(cat "$FIX/out.txt")"

# (b) 🔴 EXACT, not "at least". The switch the controller never touched has to be down.
OUT="$(drive "GRAPH_SEQ='$G_123'; await_kernel_up_set '1,2' 3 '$FIX/out.txt'")"
check "🔴 a THIRD switch reported up is not a match"     "1" "$(rc_of "$OUT")"
has   "  and the failure says what it saw"               "never became '1,2'" "$OUT"
has   "  with the last reading in it"                    "(last: 1,2,3)" "$OUT"
has   "  the file keeps both sides"                      "kernel up set (last read):          1,2,3" "$(cat "$FIX/out.txt")"

# (c) the timeout path, when nothing ever comes up
OUT="$(drive "GRAPH_SEQ='$G_NONE'; await_kernel_up_set '1,2' 3 '$FIX/out.txt'")"
check "🔴 a set that never arrives is a failure"         "1" "$(rc_of "$OUT")"
has   "  naming what it gave up after"                   "gave up after:                      3s" "$(cat "$FIX/out.txt")"
check "  after polling for the whole timeout (+1 for the capture)" "4" "$(reads)"

# (d) the wrong switches entirely
OUT="$(drive "GRAPH_SEQ='$G_3'; await_kernel_up_set '1,2' 2 '$FIX/out.txt'")"
check "  s3 up while 1,2 were expected is not a match"   "1" "$(rc_of "$OUT")"

# (e) 🔴 THE CONTROL, and the reason this section is worth anything: an empty expectation is
# refused OUTRIGHT and immediately. Two empty sets comparing equal is what a dead fabric, a
# broken parser and a controller that never started all look like.
OUT="$(drive "GRAPH_SEQ='$G_NONE'; await_kernel_up_set '' 20 '$FIX/out.txt'")"
check "🔴 an EMPTY expected set is refused, not satisfied" "1" "$(rc_of "$OUT")"
has   "  saying why an empty-to-empty match proves nothing" "the expected set is EMPTY" "$OUT"
check "🔴 and it refuses WITHOUT reading the graph at all" "0" "$(reads)"
has   "  the file records the refusal too"               "REFUSED: empty expected set" "$(cat "$FIX/out.txt")"

# (f) the happy path of the exercise as it really is: the log says 1,2 and the twin gets there.
OUT="$(drive "GRAPH_SEQ='$G_NONE $G_12'
await_kernel_up_set \"\$(controller_program_set '$FIX/log_s1s2.txt')\" 20 '$FIX/out.txt'")"
check "🔴 end to end: log -> expectation -> twin agrees" "0" "$(rc_of "$OUT")"
has   "  and the expectation really came from the log"   "expected (from the controller log): 1,2" "$(cat "$FIX/out.txt")"
# ... and the same wiring over a log that programmed nothing must NOT pass.
OUT="$(drive "GRAPH_SEQ='$G_NONE'
await_kernel_up_set \"\$(controller_program_set '$FIX/log_none.txt')\" 20 '$FIX/out.txt'")"
check "🔴 a controller that programmed nothing fails the step" "1" "$(rc_of "$OUT")"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
