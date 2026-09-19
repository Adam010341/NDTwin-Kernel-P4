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

# =============================================================================================
section "4. model_switch_dpids / assert_probe_ok_follows_set -- the proxy's side, same set"
# =============================================================================================
# 🔴 THE UNIVERSE IS PART OF THE CLAIM. The first draft of 03 wrote `for d in (1, 2, 3)`, so the
# SET was computed from the controller's log and the thing it was subtracted from was typed --
# and "s3 is computed, not typed" was only half true. A four-switch package would have had its
# fourth switch silently unchecked, which is the quietest green there is.

mkpkg() {   # mkpkg <dir> <n-switches>
    mkdir -p "$1/ndtwin"
    python3 - "$1/ndtwin/topology.json" "$2" <<'PYP'
import json, sys
ns = int(sys.argv[2])
nodes = [{"device_name": "s%d" % d, "dpid": d, "vertex_type": 0} for d in range(1, ns + 1)]
nodes += [{"device_name": "h%d" % h, "dpid": 0, "vertex_type": 1, "ip": ["10.0.%d.%d" % (h, h)]}
          for h in (1, 2, 3)]
json.dump({"nodes": nodes, "edges": [], "links": []}, open(sys.argv[1], "w"))
PYP
}
PKG3="$FIX/pkg3"; mkpkg "$PKG3" 3
PKG4="$FIX/pkg4"; mkpkg "$PKG4" 4
PKG_BAD="$FIX/pkg-bad"; mkdir -p "$PKG_BAD/ndtwin"; printf 'not json\n' > "$PKG_BAD/ndtwin/topology.json"

# mkss <file> <dpid>:<True|False|null>... -- a switch_state whose subject is probe_ok.
mkss() {
    local f="$1"; shift
    python3 - "$f" "$@" <<'PYS'
import json, sys
d = {"status": "success", "switches": {}}
for spec in sys.argv[2:]:
    dpid, word = spec.split(":")
    d["switches"][dpid] = {"probe_ok": {"True": True, "False": False, "null": None}[word]}
json.dump(d, open(sys.argv[1], "w"))
PYS
}
SS_OK="$FIX/ss_ok.json";     mkss "$SS_OK"   1:True 2:True 3:False
SS_MISS="$FIX/ss_miss.json"; mkss "$SS_MISS" 1:True 2:False 3:False
SS_EXTRA="$FIX/ss_extra.json"; mkss "$SS_EXTRA" 1:True 2:True 3:True
SS_OK4="$FIX/ss_ok4.json";   mkss "$SS_OK4"  1:True 2:True 3:False 4:True

check "  the model's dpids, ascending"                   "1,2,3" "$(one "model_switch_dpids '$PKG3' | paste -sd, -")"
check "🔴 a four-switch package declares four"           "1,2,3,4" "$(one "model_switch_dpids '$PKG4' | paste -sd, -")"
check "🔴 an unreadable model gives NOTHING, not a guess" "" "$(one "model_switch_dpids '$PKG_BAD'")"

OUT="$(drive "assert_probe_ok_follows_set '$SS_OK' '$PKG3' '1,2' 'after skel'")"
check "  the exercise's own shape passes"                "0" "$(rc_of "$OUT")"
has   "  and says which switch got a program"            "switch 1 probe_ok True   (the controller loaded a program onto it)" "$OUT"
has   "  and which never did"                            "switch 3 probe_ok False   (no controller ever loaded a program onto it)" "$OUT"
OUT="$(drive "assert_probe_ok_follows_set '$SS_MISS' '$PKG3' '1,2' 'after skel'")"
check "🔴 a programmed switch that is not answering is red" "1" "$(rc_of "$OUT")"
has   "  naming it and what was wanted"                  "switch 2 got a program from the controller and its probe_ok is 'False', want True" "$OUT"
OUT="$(drive "assert_probe_ok_follows_set '$SS_EXTRA' '$PKG3' '1,2' 'after skel'")"
check "🔴 a switch answering that nobody programmed is red" "1" "$(rc_of "$OUT")"
has   "  naming it too"                                  "switch 3 never got a program and its probe_ok is 'True', want False" "$OUT"

# 🔴 THE CELL THAT SAYS THE UNIVERSE IS NOT THE LITERAL 1,2,3: the same expected set over a
# FOUR-switch package, where s4 is answering and nobody programmed it. A hardcoded universe
# would never look at s4 and this would pass.
OUT="$(drive "assert_probe_ok_follows_set '$SS_OK4' '$PKG4' '1,2' 'after skel'")"
check "🔴 the fourth switch of a four-switch package IS checked" "1" "$(rc_of "$OUT")"
has   "  and it is the one named"                        "switch 4 never got a program" "$OUT"

# The same two controls await_kernel_up_set has.
OUT="$(drive "assert_probe_ok_follows_set '$SS_OK' '$PKG3' '' 'after skel'")"
check "🔴 an EMPTY expected set is refused here too"     "1" "$(rc_of "$OUT")"
has   "  for the same reason"                            "the expected set is EMPTY" "$OUT"
# 🔴 rc 1 ALONE DOES NOT SAY IT REFUSED. With the refusal gone the loop still runs, every switch
# falls into the "nobody programmed this" half, and the two that ARE answering fail it -- rc 1
# for a completely different reason, over a fabric it should never have looked at. The refusal
# is immediate, so the evidence is that no switch was read at all.
hasnt "🔴 and it refuses without reading a single probe" "probe_ok" "$OUT"
OUT="$(drive "assert_probe_ok_follows_set '$SS_OK' '$PKG_BAD' '1,2' 'after skel'")"
check "🔴 an unreadable model is refused, not assumed"   "1" "$(rc_of "$OUT")"
has   "  saying there is no universe to check against"   "no universe to check the probes against" "$OUT"

# =============================================================================================
section "5. TICKET-P3 §2.7 -- the generic cell: link usage follows the iperf path"
# =============================================================================================
# 🔴 THE ONE CHECK IN THIS SUITE THAT IS ABOUT NDTwin RATHER THAN ABOUT AN EXERCISE. Every other
# acceptance here is a claim about one program: source_routing's ttl, the twin's liveness under
# p4runtime's controller. This one says that while a flow crosses the fabric the twin's
# `link_bandwidth_usage_bps` is non-zero exactly on the interfaces that carried it -- whatever
# program the switches are running -- and it is the assertable half of §2.2's "record the link
# bytes BEFORE you ask what the flow was".
#
# 🔴 THE ON-PATH SET IS MEASURED, NOT WRITTEN DOWN. It is the tx_bytes delta on each `sN-ethP`
# across the same window. A path this file typed out would be this file agreeing with itself,
# and would be wrong the first time an exercise's own control plane routed a flow the other way
# round the pod.

# mkgraph_usage <file> <"<src_dpid>:<port>:<dst_dpid>:<bps>" ...> -- a /ndt/get_graph_data body.
# dst_dpid 0 is the host placeholder, which is how a host-facing edge is spelled.
mkgraph_usage() {
    local f="$1"; shift
    python3 - "$f" "$@" <<'PYU'
import json, sys
nodes = [{"device_name": "s%d" % d, "dpid": d, "vertex_type": 0, "is_up": True}
         for d in (1, 2, 3)]
nodes += [{"device_name": "h%d" % h, "dpid": 0, "vertex_type": 1} for h in (1, 2)]
edges = []
for spec in sys.argv[2:]:
    src, port, dst, bps = spec.split(":")
    edges.append({"src_dpid": int(src), "src_interface": int(port), "dst_dpid": int(dst),
                  "dst_interface": 1, "link_bandwidth_usage_bps": float(bps)})
json.dump({"nodes": nodes, "edges": edges}, open(sys.argv[1], "w"))
PYU
}

# --- 5a. onpath_ifaces: the measurement -------------------------------------------------------
cat > "$FIX/nd.before" <<'ND'
s1-eth1 1000
s1-eth2 1000
s1-eth3 1000
s2-eth1 1000
ND
cat > "$FIX/nd.after" <<'ND'
s1-eth1 2000000
s1-eth2 1000
s1-eth3 11001
s2-eth1 11000
ND
# 🔴 THE CLASS TRAVELS WITH THE NAME (§9 ruling 20①): s1-eth1 moved 1,999,000 B and is the
# PRIMARY; s1-eth3's 10,001 B is over the 10 kB threshold but far under 5% of the primary, so
# it is MINOR -- real bytes the sampler cannot be expected to have caught.
OUT="$(drive "onpath_ifaces '$FIX/nd.before' '$FIX/nd.after' | paste -sd, -")"
check "🔴 only the interfaces that moved bytes are on the path" "s1-eth1 P 1999000,s1-eth3 M 10001" "$(/usr/bin/grep -v '^RC=' <<<"$OUT" | head -1)"
check "  and onpath_primary gives the old one-name shape"  "s1-eth1" \
      "$(drive "onpath_ifaces '$FIX/nd.before' '$FIX/nd.after' > '$FIX/nd.onpath'" >/dev/null; drive "onpath_primary '$FIX/nd.onpath' | paste -sd, -" | /usr/bin/grep -v '^RC=' | head -1)"
# 🔴 THE THRESHOLD IS 10 kB AND NOT "> 0 bytes". LLDP, ARP and the proxy's own probes keep every
# link faintly busy; with a threshold of zero every interface in the fabric is on every path and
# the off-path half of the assertion has nothing left to be about. s2-eth1 grew by EXACTLY 10000
# and is out; s1-eth3 grew by 10001 and is in.
OUT="$(drive "onpath_ifaces '$FIX/nd.before' '$FIX/nd.after' 1 | paste -sd, -")"
check "  a threshold of 1 byte puts the noise on the path too" "s1-eth1 P 1999000,s1-eth3 M 10001,s2-eth1 M 10000" "$(/usr/bin/grep -v '^RC=' <<<"$OUT" | head -1)"

printf 's1-eth1 1000\n' > "$FIX/nd.short"
OUT="$(drive "onpath_ifaces '$FIX/nd.short' '$FIX/nd.after'")"
has   "🔴 an interface in only ONE reading is named, not silently zero" "is in only one of the two readings -- skipped" "$OUT"
hasnt "  and it is not on the path"                      "s1-eth3" "$(/usr/bin/grep -v 'only one of' <<<"$OUT")"

# --- 5b. twin_usage_integral: the twin's side -------------------------------------------------
G_USAGE="$FIX/g_usage.json"
mkgraph_usage "$G_USAGE" 1:1:0:8000 1:3:2:16000 2:3:1:0 3:1:0:0 0:1:1:99999
OUT="$(drive "GRAPH_SEQ='$G_USAGE'; twin_usage_integral '$FIX/int.txt' 1 4; cat '$FIX/int.txt'")"
check "  the integral is rc 0 when the graph answered"   "0" "$(rc_of "$OUT")"
# 1 s at 4 Hz is four samples, each weighted by the nominal 1/4 s: 8000 bps -> 8000 bit.
has   "  a host-facing edge integrates its rate over the window" "s1-eth1 8000.000 host" "$OUT"
has   "  and an inter-switch edge is marked as one"      "s1-eth3 16000.000 switch" "$OUT"
has   "  an edge the twin reports at zero is still listed" "s2-eth3 0.000 switch" "$OUT"
has   "  with the sample count and the measured span"    "# samples=4" "$OUT"
# 🔴 THE host->switch DIRECTION IS DROPPED, and it has to be: its key would be `s0-eth1`, which
# is no interface at all, and /proc/net/dev has nothing to join it to.
hasnt "🔴 the host->switch direction has no sN-ethP to be" "s0-eth" "$OUT"
OUT="$(drive "twin_usage_integral '$FIX/int2.txt' 1 4")"
check "🔴 a graph that never answered is rc 1, not an empty integral" "1" "$(rc_of "$OUT")"
has   "  saying there is no twin reading for the window" "there is no twin reading for this window" "$OUT"

# --- 5c. assert_link_usage_follows_path -------------------------------------------------------
mkint() {   # mkint <file> <"<key> <bits> <kind>" ...>
    local f="$1"; shift
    : > "$f"
    local row; for row in "$@"; do printf '%s\n' "$row" >> "$f"; done
    printf '# samples=4 span=1s\n' >> "$f"
}
# 🔴 `P` because these fixtures ARE the flow: the class column is onpath_ifaces' output
# format now (§9 ruling 20①), and a file without it would exercise a shape nothing produces.
printf 's1-eth1 P 2000000\ns1-eth3 P 2000000\n' > "$FIX/onpath.txt"
mkint "$FIX/i_good.txt" "s1-eth1 8000.000 host" "s1-eth3 16000.000 switch" \
                        "s1-eth2 0.000 switch" "s2-eth1 400.000 host"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath.txt' '$FIX/i_good.txt' 'green'")"
check "  usage on the path and nothing off it is green"  "0" "$(rc_of "$OUT")"
has   "  and it says so"                                 "green: link usage follows the iperf path" "$OUT"

mkint "$FIX/i_zero.txt" "s1-eth1 8000.000 host" "s1-eth3 0.000 switch" "s1-eth2 0.000 switch"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath.txt' '$FIX/i_zero.txt' 'zero'")"
check "🔴 an interface that carried the flow and reads 0 is red" "1" "$(rc_of "$OUT")"
has   "  naming it"                                      "s1-eth3 carried the flow (2000000 B, primary) and the twin integrated 0.000 bit" "$OUT"

mkint "$FIX/i_missing.txt" "s1-eth1 8000.000 host"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath.txt' '$FIX/i_missing.txt' 'gap'")"
check "🔴 an on-path interface with NO twin edge is red"  "1" "$(rc_of "$OUT")"
has   "  and says the link is not modelled"              "the twin has NO edge for it" "$OUT"

# --- 5c-bis. the off-path FLOOR (TICKET-P3 §9 ruling 9, R4) --------------------------------
# 🔴 "EXACTLY 0" OFF THE PATH WOULD GO RED ON A CORRECT FABRIC, AT RANDOM. After the kernel
# banks a sample's frame length BEFORE it asks what the flow was (§2.2), ARP and LLDP count
# toward link usage; the proxy beacons LLDP along every switch-switch link and the pipeline
# samples 1/256, so ONE beacon drawn in an eight-second window is banked as 256 x its frame
# length -- tens of kilobits on an edge that carried nothing. The bound is therefore a floor:
# max(5 kbit, 2% of the SMALLEST on-path integral). Absolute so a quiet window still has a
# bound; relative so it cannot be a fixed number an 8 s 2 Mbit/s flow dwarfs.
# 🔴 THE FLOOR IS NOW AT LEAST ONE SAMPLE (§9 ruling 26①): 256 x 1500 x 8 = 3,072,000 bit.
# Below that there is nothing the sampler could have reported, so a bound under it bounds noise
# that cannot exist. For a realistic 8-second flow this term DOMINATES the 2% one -- the 2%
# only takes over above 153.6 Mbit on-path -- and saying so is better than pretending the
# relative term still decides these cases.
check "  the floor is one sample even for a small on-path integral" "3072000.000" \
      "$(one "link_usage_floor '$FIX/onpath.txt' '$FIX/i_good.txt'")"
mkint "$FIX/i_big.txt" "s1-eth1 16000000.000 host" "s1-eth3 16000000.000 switch"
printf 's1-eth1 P 16000000\ns1-eth3 P 16000000\n' > "$FIX/onpath2.txt"
check "  and a 16 Mbit flow does not raise it: 2% is 320 kbit, under one sample" "3072000.000" \
      "$(one "link_usage_floor '$FIX/onpath2.txt' '$FIX/i_big.txt'")"
# 🔴 THE 2% TERM IS STILL THERE AND STILL TAKES OVER when the flow is big enough for it to mean
# something -- 2% of 400 Mbit is 8 Mbit, well above one sample.
mkint "$FIX/i_huge.txt" "s1-eth1 400000000.000 host" "s1-eth3 400000000.000 switch"
check "🔴 above 153.6 Mbit the 2% term decides again"     "8000000.000" \
      "$(one "link_usage_floor '$FIX/onpath2.txt' '$FIX/i_huge.txt'")"

# A sampled LLDP beacon on an off-path inter-switch link: ~500 bit frame x 256 = ~128 kbit,
# under 2% of a 16 Mbit on-path integral and over the absolute 5 kbit.
mkint "$FIX/i_beacon.txt" "s1-eth1 16000000.000 host" "s1-eth3 16000000.000 switch" \
                          "s1-eth2 128000.000 switch"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath2.txt' '$FIX/i_beacon.txt' 'beacon'")"
check "🔴 one sampled LLDP beacon off the path is NOT a failure" "0" "$(rc_of "$OUT")"
has   "  and the floor it was judged against is in the raw" "off-path floor 3072000.000 bit" "$OUT"
has   "  with the edge's own integral beside it"         "off-path s1-eth2  128000.000 bit" "$OUT"

# ... and an edge carrying real traffic off the path still is one.
# 🔴 ABOVE ONE SAMPLE, so it is a real reading and not something the sampler could not have
# produced: 4 Mbit is more than 3.07 Mbit.
mkint "$FIX/i_leak.txt" "s1-eth1 16000000.000 host" "s1-eth3 16000000.000 switch" \
                        "s1-eth2 4000000.000 switch"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath2.txt' '$FIX/i_leak.txt' 'leak'")"
check "🔴 an inter-switch link off the path carrying the FLOW is red" "1" "$(rc_of "$OUT")"
has   "  naming it, the bits and the floor"              "s1-eth2 is an inter-switch link that did NOT carry the flow and the twin integrated 4000000.000 bit on it, at or over the 3072000.000 bit floor" "$OUT"

# 🔴 THE FLOOR IS TAKEN FROM THE SMALLEST ON-PATH INTEGRAL, AND THE TWO ENDS DIFFER IN
# PRACTICE. The on-path edges of one window are not equal: the host-facing edge carries the
# flow once and an inter-switch edge on a longer path carries it again, so `min` and `max` are
# a factor of several apart -- and `min` is the conservative end, the one that still catches an
# off-path link with real traffic on it.
# 🔴 SCALED SO THE 2% TERM IS THE ONE UNDER TEST: 2% of 400 Mbit is 8 Mbit, above one
# sample, and the off-path edge at 10 Mbit is above that.
mkint "$FIX/i_spread.txt" "s1-eth1 400000000.000 host" "s1-eth3 6400000000.000 switch" \
                          "s1-eth2 10000000.000 switch"
check "  the floor follows the SMALLEST on-path integral"  "8000000.000" \
      "$(one "link_usage_floor '$FIX/onpath2.txt' '$FIX/i_spread.txt'")"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath2.txt' '$FIX/i_spread.txt' 'spread'")"
check "🔴 and 10 Mbit off the path is red against it"      "1" "$(rc_of "$OUT")"
has   "  naming the floor the smallest on-path edge set"  "at or over the 8000000.000 bit floor" "$OUT"

# 🔴 THE FLOOR IS NOT A BLANK CHEQUE: in a quiet window it is the absolute 5 kbit, so an
# off-path edge with real traffic on it is still red there.
# 🔴 THE "QUIET WINDOW" ABSOLUTE FLOOR IS NOW ONE SAMPLE, so an off-path edge has to carry
# more than one sample's worth to be red at all.
mkint "$FIX/i_offpath.txt" "s1-eth1 8000.000 host" "s1-eth3 16000.000 switch" \
                           "s1-eth2 4000000.000 switch"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath.txt' '$FIX/i_offpath.txt' 'quiet'")"
check "🔴 and in a quiet window the floor is one sample"   "1" "$(rc_of "$OUT")"
has   "  naming that floor"                              "at or over the 3072000.000 bit floor" "$OUT"
mkint "$FIX/i_under.txt" "s1-eth1 8000.000 host" "s1-eth3 16000.000 switch" \
                         "s1-eth2 12.000 switch"
check "  12 bit of stray on an off-path link is under it" "0" \
      "$(rc_of "$(drive "assert_link_usage_follows_path '$FIX/onpath.txt' '$FIX/i_under.txt' 'stray'")")"

# host-facing edges are held to the same floor -- a host's link is never quiet.
mkint "$FIX/i_arp.txt" "s1-eth1 8000.000 host" "s1-eth3 16000.000 switch" \
                       "s2-eth1 4999.000 host"
check "  a host-facing edge under the floor is fine"     "0" \
      "$(rc_of "$(drive "assert_link_usage_follows_path '$FIX/onpath.txt' '$FIX/i_arp.txt' 'arp'")")"
# 🔴 ONE SAMPLE IS THE UNIT NOW: a host-facing edge is red only above 3,072,000 bit, because
# below that the sampler could not have produced a reading at all.
mkint "$FIX/i_arplot.txt" "s1-eth1 8000.000 host" "s1-eth3 16000.000 switch" \
                          "s2-eth1 3072001.000 host"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath.txt' '$FIX/i_arplot.txt' 'arp2'")"
check "🔴 and one over it is red"                         "1" "$(rc_of "$OUT")"
has   "  naming the floor it passed"                     "at or over the 3072000.000 bit floor" "$OUT"

# 🔴 THE CONTROL. With nothing measured as on-path the first clause is vacuous and the second is
# "every edge is zero" -- which a fabric that moved no packet at all satisfies perfectly, and
# that fabric is what a broken iperf, a missing sudo grant and a dead switch all look like.
: > "$FIX/onpath_empty.txt"
OUT="$(drive "assert_link_usage_follows_path '$FIX/onpath_empty.txt' '$FIX/i_good.txt' 'empty'")"
check "🔴 an EMPTY on-path set is refused, not satisfied" "1" "$(rc_of "$OUT")"
has   "  saying why"                                     "the on-path interface set is EMPTY" "$OUT"
# 🔴 rc 1 ALONE DOES NOT SAY IT REFUSED. With the refusal gone the loops still run, every edge
# falls into the off-path half, and the host-facing one is over the ARP allowance -- rc 1 for a
# completely different reason, over a window this helper should never have judged. The evidence
# that it refused is that no edge was named at all.
hasnt "🔴 and it refuses WITHOUT judging a single edge"   "s1-eth1" "$OUT"

# --- 5d. assert_link_usage_absent: the positive control ---------------------------------------
# 🔴 WITHOUT THIS THE CELL ABOVE HAS NO DISCRIMINATING POWER. A twin that reported a constant
# non-zero on every edge would pass "usage follows the path" on every run, for ever.
mkint "$FIX/i_silent.txt" "s1-eth1 0.000 host" "s1-eth3 0.000 switch"
OUT="$(drive "assert_link_usage_absent '$FIX/onpath.txt' '$FIX/i_silent.txt' 'none-group'")"
check "  telemetry off: the twin reports nothing on the path" "0" "$(rc_of "$OUT")"
has   "  and says what that proves"                      "with telemetry off the twin reports nothing on the path" "$OUT"
OUT="$(drive "assert_link_usage_absent '$FIX/onpath.txt' '$FIX/i_good.txt' 'none-group'")"
check "🔴 telemetry off and the twin still reporting is RED" "1" "$(rc_of "$OUT")"
has   "  because the cell above would then prove nothing" "the cell above has no discriminating power" "$OUT"
OUT="$(drive "assert_link_usage_absent '$FIX/onpath_empty.txt' '$FIX/i_silent.txt' 'none-group'")"
check "🔴 and an EMPTY on-path set is refused here too"   "1" "$(rc_of "$OUT")"
has   "  for the same reason"                            "the on-path interface set is EMPTY" "$OUT"

# --- 5e. link_usage_round: the two refusals it can decide offline -----------------------------
# The measurement itself needs a fabric and is the orchestrator's to run. What CAN be decided
# here is the pair of refusals, and both are the same rule: an answer about permissions or about
# the package is never rendered as a reading about link usage.
mkdir -p "$FIX/pkg1host/ndtwin"
python3 -c '
import json, sys
json.dump({"nodes": [{"device_name": "h1", "dpid": 0, "vertex_type": 1, "ip": ["10.0.1.1"]}],
           "edges": [], "links": []}, open(sys.argv[1], "w"))' "$FIX/pkg1host/ndtwin/topology.json"
OUT="$(drive "link_usage_round '$FIX/pkg1host' 'one-host' '$FIX/lur1'")"
check "🔴 a model with one host cannot carry a flow"      "1" "$(rc_of "$OUT")"
has   "  and says so instead of measuring nothing"       "does not name two hosts to run a flow between" "$OUT"
# 🔴 HOST NAMES NO FABRIC CAN HAVE, AND THAT IS THE POINT (found during the live-fix round).
# This cell used `$PKG3`, whose hosts are h1..h3 -- the names a REAL fabric uses. It passed only
# while no lab was up: with the orchestrator's live run in progress, `host_pid h1` returns a
# genuine namespace pid, the refusal never fires, and the cell went red for a reason that has
# nothing to do with the code under test. A test whose result depends on whether somebody else
# has a fabric up is not testing what it says.
mkdir -p "$FIX/pkg-nons/ndtwin"
python3 -c '
import json, sys
json.dump({"nodes": [{"device_name": "zz1", "dpid": 0, "vertex_type": 1, "ip": ["10.9.9.1"]},
                     {"device_name": "zz3", "dpid": 0, "vertex_type": 1, "ip": ["10.9.9.3"]}],
           "edges": [], "links": []}, open(sys.argv[1], "w"))' "$FIX/pkg-nons/ndtwin/topology.json"
OUT="$(drive "link_usage_round '$FIX/pkg-nons' 'no-ns' '$FIX/lur2'")"
check "🔴 a host with no namespace is rc 2, a refusal"    "2" "$(rc_of "$OUT")"
has   "  named as the permission answer it is"           "never a reading about link usage" "$OUT"

# 🔴 THE DESTINATION IS A PARAMETER, AND TWO EXERCISES NEED IT. "The model's last host" is a
# property of the MODEL, and for exercises/multicast and exercises/p4runtime it is a host the
# exercise deliberately cannot reach -- sig-topo replicates ports 1,2,3 and p4runtime's
# controller wires h1<->h2 and never touches s3. Measuring to those produces an EMPTY on-path
# set, which this cell refuses: correctly, and about the wrong thing.
OUT="$(drive "link_usage_round '$PKG3' 'to-h2' '$FIX/lur3' follows h2")"
has   "  a named destination is the one the flow runs to" "h1 -> h2 (10.0.2.2)" "$OUT"
OUT="$(drive "link_usage_round '$PKG3' 'default' '$FIX/lur4'")"
has   "  and with none named it is the model's LAST host" "h1 -> h3 (10.0.3.3)" "$OUT"
OUT="$(drive "link_usage_round '$PKG3' 'to-h9' '$FIX/lur5' follows h9")"
check "🔴 a destination the model does not declare is refused" "1" "$(rc_of "$OUT")"
has   "  rather than silently falling back to another host" "declares no host 'h9'" "$OUT"

# =============================================================================================
section "9. 🔴 no live-p1 script reintroduces the \`set -u\` \`local\` hazard"
# =============================================================================================
# Under `set -u`, bash 5.2 declares EVERY name in a `local` list before assigning any of them,
# so `local a="$1" b="${a}.log"` expands an unset `a` and the function dies on its own first
# line. `05_link_usage_generic.sh` and `06_thirteen.sh` both had it and NEITHER HAD EVER BEEN
# RUN, so nothing in the repo said a word (found in round 2, via 06's new test).
#
# 🔴 WHY THIS IS A SCANNER AND NOT A RUN OF 05. `group()` is reachable only after p4c, two
# convert.py runs, two pre-flights and a lab claim; a stub deep enough to reach it would be a
# stub of the whole step, and would pin the stub rather than the script. What actually
# regresses here is the SHAPE, in any of these files, including ones written later -- so that
# is what is checked, with a positive control below so the check cannot pass by finding nothing.
# 🔴 `python3`, NOT `$PY`. The first version used `$PY`, which is not set in this file's scope
# -- so the scan errored, printed NOTHING, and the "no script has the hazard" check went GREEN
# on empty output. The positive control below is the only reason that was caught, which is the
# entire argument for having one.
# 🔴 THE SCANNER MUST FAIL WHEN THE SCANNER FAILS (TICKET-P3 §9 ruling 12d). The first version
# printed nothing when `python3` itself could not run -- and "prints nothing" is exactly what
# "no script has the hazard" looks like, so the check went GREEN on a scan that never happened.
# (That is not hypothetical: it shipped that way for one iteration, with `$PY` unset, and only
# the positive control caught it.) A tool that cannot run has not answered; this returns
# non-zero and says so on stderr, and `hazard_check` below turns that into a FAILED cell.
hazard_scan() {   # hazard_scan <file>... -- prints "<file>:<line> <name> reads $<earlier>"
    local out err rc
    err="$(mktemp "${TMPDIR:-/tmp}/hazard-err-XXXXXX")"
    out="$(hazard_scan_raw "$@" 2>"$err")"; rc=$?
    if (( rc != 0 )) || [[ -s "$err" ]]; then
        printf 'SCANNER-FAILED rc=%s %s\n' "$rc" "$(tr '\n' ' ' < "$err")"
        rm -f "$err"
        return 3
    fi
    rm -f "$err"
    printf '%s' "$out"
    [[ -z "$out" ]] || printf '\n'
    return 0
}

hazard_scan_raw() {
    python3 - "$@" <<'PYH'
import re, sys
for path in sys.argv[1:]:
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        continue
    for n, line in enumerate(lines, 1):
        m = re.match(r"\s*local\s+(.*)$", line)
        if not m:
            continue
        seen = []
        for chunk in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)=(\"(?:[^\"\\]|\\.)*\"|\S*)",
                                 m.group(1)):
            name, val = chunk.group(1), chunk.group(2)
            for prev in seen:
                if re.search(r"\$\{?%s\b" % re.escape(prev), val):
                    print("%s:%d %s reads $%s" % (path, n, name, prev))
            seen.append(name)
PYH
}

OUT="$(hazard_scan "$LIVE"/*.sh)"; SCAN_RC=$?
check "  the scanner itself ran"                         "0" "$SCAN_RC"
check "🔴 no live-p1 script has a cross-referencing \`local\`" "" "$(printf '%s' "$OUT")"
[[ -n "$OUT" ]] && printf '%s\n' "$OUT" | sed 's/^/             /'

# 🔴 THE POSITIVE CONTROL. Without it "found nothing" and "cannot find anything" read the same.
mkdir -p "$FIX/bin"
cat > "$FIX/hazard.sh" <<'HZ'
f() {
    local ex="$1" which="$2" log="$RUN/${ex}_${which}.log" rc
    echo "$log$rc"
}
HZ
OUT="$(hazard_scan "$FIX/hazard.sh")"
has   "  and the scanner finds one that IS there"        "log reads \$ex" "$OUT"
has   "  naming both of the names it read"               "log reads \$which" "$OUT"

# ... and the shape that is FINE must not be flagged: separate statements are the fix.
cat > "$FIX/ok.sh" <<'OK'
f() {
    local ex="$1" which="$2"
    local log rc
    log="$RUN/${ex}_${which}.log"
    echo "$log$rc"
}
OK
check "🔴 and the FIXED shape is not flagged"            "" "$(hazard_scan "$FIX/ok.sh")"

# 🔴 THE CONTROL THE JUDGE ASKED FOR (§9 ruling 12d): break the INTERPRETER, not the input.
# With no `python3` reachable the scan cannot happen -- and the cell above, which asserts an
# EMPTY result, would be satisfied by that silence. This is the difference between "I looked
# and found nothing" and "I could not look".
# 🔴 THE PATH MUST STILL HAVE coreutils (TICKET-P3 §9 ruling 14g). `PATH=/nonexistent` killed
# `mktemp` inside hazard_scan before python3 was ever reached -- so that cell proved the
# function fails when the SHELL loses its tools, which is not the thing under test. This PATH
# has everything the function itself uses and nothing called `python3`, so the only thing that
# can fail is the interpreter, and the rc it reports must be 127 (command not found).
mkdir -p "$FIX/nopy"
for t in mktemp tr rm cat sed grep; do
    src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$FIX/nopy/$t"
done
OUT="$(PATH="$FIX/nopy" hazard_scan "$FIX/hazard.sh" 2>&1)"; SCAN_RC=$?
check "🔴 no python3 on PATH is NOT a clean scan"         "3" "$SCAN_RC"
has   "  and it says so out loud"                        "SCANNER-FAILED" "$OUT"
has   "🔴 naming the rc that says 'command not found'"    "rc=127" "$OUT"
# ... and the control for THIS control: the same PATH still runs the function's own tools, so a
# red here would mean the fixture broke the shell rather than the interpreter.
# (`/bin/bash` by absolute path: the trimmed PATH deliberately has no `bash` either, and this
# control is about the tools the FUNCTION uses, not about how this line finds a shell.)
check "  (the trimmed PATH still has the tools hazard_scan itself uses)" "0" \
      "$(PATH="$FIX/nopy" /bin/bash -c 'mktemp -u >/dev/null && tr -d "" </dev/null' >/dev/null 2>&1; echo $?)"
# (an empty needle matches everything, so "it did not print an empty result" is asserted by
# the rc-3 and SCANNER-FAILED cells above, not by a `hasnt ""` that can never fail)

# ... and the same for an interpreter that exists but fails.
cat > "$FIX/bin/python3" <<'BOGUS'
#!/bin/sh
echo "ImportError: something the scanner needs is missing" >&2
exit 1
BOGUS
chmod +x "$FIX/bin/python3"
OUT="$(PATH="$FIX/bin:$PATH" hazard_scan "$FIX/hazard.sh" 2>&1)"; SCAN_RC=$?
check "🔴 an interpreter that fails is not a clean scan either" "3" "$SCAN_RC"
has   "  naming what it said"                            "ImportError" "$OUT"

# 🔴 THE NEGATIVE CONTROL FOR THE CONTROL: a working interpreter must NOT trip the guard, or
# every run of this suite would refuse and the two cells above would be vacuous.
OUT="$(hazard_scan "$FIX/ok.sh")"; SCAN_RC=$?
check "  a working interpreter is not reported as failed" "0" "$SCAN_RC"
hasnt "  and prints no SCANNER-FAILED"                   "SCANNER-FAILED" "$OUT"

# =============================================================================================
section "10. 🔴 a teardown step that fails must not kill the teardown"
# =============================================================================================
# TICKET-P3 §9 ruling 19②, found by the first live run. `_common.sh` runs under
# `set -euo pipefail` and `finish()` is the EXIT trap, so a non-zero `ndt down` ENDED THE TRAP
# half way: live 02's log stops at `== teardown` and live 03's at "stopping the exercise
# controller" -- no `ndt down rc=` line, no `ndt release`, and no verdict line at all, while the
# README promises the last line is PASS or FAIL. A teardown is the one place where every step
# must run BECAUSE an earlier one failed, and `-e` inverts exactly that; it took the release
# with it, leaving the lab claimed by a finished run.
FIX10="$(mktemp -d "${TMPDIR:-/tmp}/common-finish-XXXXXX")"
mkdir -p "$FIX10/bin" "$FIX10/run"
cat > "$FIX10/bin/ndt" <<'STUBNDT'
#!/usr/bin/env bash
echo "$*" >> "$NDTLOG"
case "${1:-}" in
    down)    echo "stub: down says something was wrong"; exit 1 ;;
    release) echo "stub: released"; exit 0 ;;
    claim)   exit 0 ;;
    *)       exit 0 ;;
esac
STUBNDT
chmod +x "$FIX10/bin/ndt"

# The smallest driver that exercises the real `finish`: source the file under test, claim, and
# let the EXIT trap run with a `down` that fails.
# 🔴 `set -euo pipefail`, THE LINE EVERY REAL STEP SCRIPT HAS (02_app_basic.sh:43, and the
# others). `_common.sh` does NOT set it -- the steps do -- so a driver here that used
# `set -uo pipefail` would never have `-e` on, and the whole scenario would be vacuous: the
# mutation that removes `set +e` from finish() would change nothing and the cells below would
# pass for a defect that is still there. (That is exactly what happened on the first attempt;
# the gate's M29 caught it.)
cat > "$FIX10/step.sh" <<STEPSH
set -euo pipefail
export NDTLOG="$FIX10/ndt.log"
source "$COMMON"
NDT="$FIX10/bin/ndt"
RUN="$FIX10/run"; STEP=10_finish; CLAIMED=1; CTRL_PID=""
VERDICT_RC=0; VERDICT_WHY=""
trap finish EXIT INT TERM
exit 0
STEPSH
: > "$FIX10/ndt.log"
OUT10="$(timeout 120 bash "$FIX10/step.sh" 2>&1)"; RC10=$?

check "🔴 a failing 'ndt down' still produces a verdict"  "1" "$RC10"
has   "  the 'ndt down rc=' line is printed"             "ndt down rc=1" "$OUT10"
has   "🔴 its rc is folded into the verdict"             "'ndt down' exited 1" "$OUT10"
has   "  the raw path is printed"                        "raw: " "$OUT10"
check "🔴 and the LAST line is the verdict, as the README promises" "1" \
      "$(printf '%s\n' "$OUT10" | tail -1 | /usr/bin/grep -cE '^(PASS|FAIL) ')"
has   "🔴 'ndt release' still ran -- the lab is not left claimed" "release" "$(cat "$FIX10/ndt.log")"

# 🔴 A RELEASE THAT DID NOT TAKE MUST FAIL THE ROUND (the shape E's judge found today). `bad`
# only prints: the verdict stayed whatever it was, so a round whose release failed could end
# PASS -- and the next person to want the lab finds it held by a step that reported success.
cat > "$FIX10/bin/ndt" <<'STUBREL'
#!/usr/bin/env bash
echo "$*" >> "$NDTLOG"
case "${1:-}" in
    release) echo "stub: release did NOT take"; exit 1 ;;
    *)       exit 0 ;;
esac
STUBREL
chmod +x "$FIX10/bin/ndt"
: > "$FIX10/ndt.log"
OUT10="$(timeout 120 bash "$FIX10/step.sh" 2>&1)"; RC10=$?
check "🔴 a failing 'ndt release' fails the round"        "1" "$RC10"
check "🔴 and the LAST line is FAIL, not PASS"            "1" \
      "$(printf '%s\n' "$OUT10" | tail -1 | /usr/bin/grep -c '^FAIL ')"
has   "  saying the lab is still claimed"                "THE LAB IS STILL CLAIMED" "$OUT10"

# 🔴 THE CONTROL: with a `down` that succeeds the verdict is PASS and nothing above is a fluke.
cat > "$FIX10/bin/ndt" <<'STUBOK'
#!/usr/bin/env bash
echo "$*" >> "$NDTLOG"
exit 0
STUBOK
chmod +x "$FIX10/bin/ndt"
: > "$FIX10/ndt.log"
OUT10="$(timeout 120 bash "$FIX10/step.sh" 2>&1)"; RC10=$?
check "  a clean teardown still passes"                  "0" "$RC10"
check "  and its last line is PASS"                      "1" \
      "$(printf '%s\n' "$OUT10" | tail -1 | /usr/bin/grep -c '^PASS ')"
rm -rf "$FIX10"

# =============================================================================================
section "11. 🔴 qos/solution's real numbers: a side branch the sampler cannot see"
# =============================================================================================
# TICKET-P3 §9 ruling 20①, from the first live run. These are the ACTUAL tx deltas of
# runs/2026-09-19T053856Z_qos_solution_ndtwin/link_usage/netdev.{before,after} and the actual
# twin integrals from its twin_integral.txt -- not numbers chosen to make a point:
#
#   s1-eth3  2,162,160 B   twin 22,443,167 bit    <- the flow
#   s2-eth1  2,162,160 B   twin 14,704,115.5 bit  <- the flow
#   s1-eth4     15,120 B   twin 0                 <- TEN datagrams down a side branch
#   s3-eth1     15,120 B   twin 0                 <- the same ten, other end
#   s1-eth2        340 B / s2-eth3 170 / s3-eth2 170 / the rest 0
#
# 10 kB made all four "on-path" and demanded a non-zero integral on each. At 1 sample in 256
# the EXPECTED samples for ten packets is 15120/(1500*256) = 0.04 -- so the twin integrating
# zero on the 15 kB pair was CORRECT, and the cell went red on a twin that was right.
cat > "$FIX/qos.before" <<'NB'
s1-eth1 1000
s1-eth2 1000
s1-eth3 1000
s1-eth4 1000
s2-eth1 1000
s2-eth2 1000
s2-eth3 1000
s2-eth4 1000
s3-eth1 1000
s3-eth2 1000
s3-eth3 1000
NB
cat > "$FIX/qos.after" <<'NA'
s1-eth1 1000
s1-eth2 1340
s1-eth3 2163160
s1-eth4 16120
s2-eth1 2163160
s2-eth2 1000
s2-eth3 1170
s2-eth4 1000
s3-eth1 16120
s3-eth2 1170
s3-eth3 1000
NA
mkint "$FIX/qos.int" "s1-eth1 0.000 host" "s1-eth2 0.000 host" "s1-eth3 22443167.000 switch" \
                     "s1-eth4 0.000 switch" "s2-eth1 14704115.500 host" "s2-eth2 0.000 host" \
                     "s2-eth3 0.000 switch" "s2-eth4 0.000 switch" "s3-eth1 0.000 host" \
                     "s3-eth2 0.000 switch" "s3-eth3 0.000 switch"

OUT="$(drive "onpath_ifaces '$FIX/qos.before' '$FIX/qos.after' > '$FIX/qos.onpath'")"
ONP="$(cat "$FIX/qos.onpath")"
has   "🔴 s1-eth3 is PRIMARY"                            "s1-eth3 P 2162160" "$ONP"
has   "🔴 s2-eth1 is PRIMARY"                            "s2-eth1 P 2162160" "$ONP"
has   "🔴 s1-eth4 is MINOR, not primary"                 "s1-eth4 M 15120" "$ONP"
has   "🔴 s3-eth1 is MINOR, not primary"                 "s3-eth1 M 15120" "$ONP"
hasnt "  and the 340 B interface is not listed at all"   "s1-eth2" "$ONP"
hasnt "  nor the 170 B ones"                             "s2-eth3" "$ONP"

OUT="$(drive "assert_link_usage_follows_path '$FIX/qos.onpath' '$FIX/qos.int' 'qos'")"
check "🔴 the real qos/solution reading PASSES"           "0" "$(rc_of "$OUT")"
has   "  the two primaries are asserted and named"       "on-path  s1-eth3" "$OUT"
has   "🔴 the minor rows are printed, not asserted"      "minor    s1-eth4" "$OUT"
has   "🔴 with the expected sample count beside them"    "expected samples = 15120 / (1500 x 256) = 0.039" "$OUT"
has   "  and said to be NOT asserted"                    "NOT asserted" "$OUT"

# 🔴 THE PRIMARY HALF STILL HAS TEETH: a primary interface the twin never saw is still red.
mkint "$FIX/qos.int0" "s1-eth3 0.000 switch" "s2-eth1 14704115.500 host" "s1-eth4 0.000 switch" \
                      "s3-eth1 0.000 host"
OUT="$(drive "assert_link_usage_follows_path '$FIX/qos.onpath' '$FIX/qos.int0' 'qos0'")"
check "🔴 a PRIMARY interface with a zero integral is still red" "1" "$(rc_of "$OUT")"
has   "  naming it as primary, with its byte count"      "s1-eth3 carried the flow (2162160 B, primary)" "$OUT"

# =============================================================================================
section "12. 🔴 ecn's bottleneck: a window too short for the sampler to see the flow"
# =============================================================================================
# TICKET-P3 §9 ruling 26①, from the final live pass. ecn shapes s1-s2 to 500,000 bit/s, so an
# 8 s 2 Mbit/s iperf delivers ~691 kB -- the REAL numbers from
# runs/2026-09-19T085702Z_ecn_solution_ndtwin/link_usage are s1-eth3 690,928 B (twin 875,000
# bit: one sample got through) and s2-eth1 691,131 B with twin 0. At 1 sample in 256 the
# expected count per primary link is ~1.8 and P(zero) is ~16%: three runs in four read
# s2-eth1 = 0 and went red on a fabric that forwarded every byte.
mkdir -p "$FIX/ecnpkg/ndtwin"
python3 -c '
import json, sys
json.dump({"links": [{"a": ["h1", 0], "b": ["s1", 1], "bandwidth_bps": 1000000000.0},
                     {"a": ["s1", 3], "b": ["s2", 3], "bandwidth_bps": 500000.0},
                     {"a": ["s2", 1], "b": ["h2", 0], "bandwidth_bps": 1000000000.0}]},
          open(sys.argv[1], "w"))' "$FIX/ecnpkg/package.json"

read -r ECN_T ECN_BPS ECN_AT8 < <(drive "link_usage_window '$FIX/ecnpkg'" | /usr/bin/grep -v '^RC=')
check "🔴 the slowest declared link is the 500 kbit/s bottleneck" "500000" "$ECN_BPS"
# (1.30 = bandwidth x time / (rate x MTU x 8). The ruling quotes ~1.8, which is the same
# quantity computed from the bytes ecn actually delivered -- 691,131 B -- rather than from the
# shaped rate; both are under two samples, which is the point.)
check "🔴 at the old 8 s window only ~1.3 samples were expected" "1.30" "$ECN_AT8"
check "🔴 so the window grows to 62 s"                    "62" "$ECN_T"

# 🔴 THE CONTROL: an unshaped package keeps the 8 s window -- the rule must not slow every
# round down to 61 s for a bottleneck that is not there.
mkdir -p "$FIX/fastpkg"
python3 -c '
import json, sys
json.dump({"links": [{"a": ["s1", 3], "b": ["s2", 3], "bandwidth_bps": 1000000000.0}]},
          open(sys.argv[1], "w"))' "$FIX/fastpkg/package.json"
read -r F_T F_BPS F_AT8 < <(drive "link_usage_window '$FIX/fastpkg'" | /usr/bin/grep -v '^RC=')
check "  a 1 Gbit/s path keeps the 8 s window"            "8" "$F_T"

# 🔴 ONE SAMPLED FRAME IS THE SMALLEST THING THE SAMPLER CAN REPORT, so the off-path floor
# cannot be below it: a single 170-byte packet is 256 x 170 x 8 = 348 kbit, thirty-five times
# the old 10 kbit floor, and the cell would have gone red on it.
mkint "$FIX/ecn.int" "s1-eth3 875000.000 switch" "s2-eth1 0.000 host" "s1-eth1 348002.000 host"
printf 's1-eth3 P 690928\ns2-eth1 P 691131\n' > "$FIX/ecn.onpath"
FLOOR="$(one "link_usage_floor '$FIX/ecn.onpath' '$FIX/ecn.int'")"
check "🔴 the floor is at least ONE sample's worth of bits" "3072000.000" "$FLOOR"
OUT="$(drive "assert_link_usage_follows_path '$FIX/ecn.onpath' '$FIX/ecn.int' 'ecn'")"
has   "  and the raw says how that number was reached"   "ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit" "$OUT"
has   "🔴 one sampled frame off the path is NOT a failure" "off-path s1-eth1  348002.000 bit" "$OUT"

# ... and a PRIMARY link the twin never saw is still red -- the window is what changes, not
# the assertion.
check "🔴 s2-eth1 with a zero integral is still red"      "1" "$(rc_of "$OUT")"
has   "  naming it as primary"                           "s2-eth1 carried the flow (691131 B, primary)" "$OUT"

# =============================================================================================
section "13. 🔴 p4runtime/flowcache: 273 B everywhere means the flow never moved"
# =============================================================================================
# §9 ruling 26②. Both arms read EXACTLY 273 B on every interface: the fabric dropped every
# 1470-byte datagram (advanced_tunnel's 4-byte header pushes 1470+28+4 past the 1500 MTU)
# while the driver's 64-byte pings passed.
cat > "$FIX/flat.before" <<'NB'
s1-eth1 1000
s1-eth2 1000
s1-eth3 1000
s2-eth1 1000
NB
cat > "$FIX/flat.after" <<'NA'
s1-eth1 1273
s1-eth2 1273
s1-eth3 1273
s2-eth1 1273
NA
drive "onpath_ifaces '$FIX/flat.before' '$FIX/flat.after' > '$FIX/flat.onpath'" >/dev/null
check "  273 B on every interface is nobody on the path"  "" "$(cat "$FIX/flat.onpath")"
mkint "$FIX/flat.int" "s1-eth1 0.000 host" "s1-eth3 0.000 switch"
OUT="$(drive "assert_link_usage_follows_path '$FIX/flat.onpath' '$FIX/flat.int' 'flat'")"
check "🔴 the cell refuses rather than measuring nothing" "1" "$(rc_of "$OUT")"
has   "  saying nothing carried the flow"                "nothing measurably carried the flow" "$OUT"
has   "🔴 and NAMING the datagram size it chose"         "iperf -l 1200" "$OUT"

# 🔴 A DEAD CONTROLLER IS 'NOT RUN', NEVER 'PASS'. flowcache's first packet needs the
# controller's packet-in; measuring without it measures the controller's absence.
OUT="$(drive "CTRL_PID=999999; link_usage_round '$PKG3' 'noctrl' '$FIX/lur3'")"
has   "🔴 a dead exercise controller makes G1 NOT RUN"   "G1 NOT RUN" "$OUT"
has   "  naming the pid it checked"                      "pid 999999" "$OUT"
has   "  and the summary line says NOT-RUN"              "rc=NOT-RUN" "$OUT"
hasnt "🔴 and it never reports the flow as measured"     "LINK_USAGE noctrl expect=follows primary=s" "$OUT"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
