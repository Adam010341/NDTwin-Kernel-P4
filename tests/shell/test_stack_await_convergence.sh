#!/usr/bin/env bash
#
# `stack.sh await_convergence` -- the wait before the kernel is started, driven OFFLINE.
#
# [Co-developed with claude code -- Adam]
#
# WHAT THIS IS. Between the control plane and the kernel, stack.sh blocks until the control
# plane reports the whole topology, because the kernel pulls topology and destination paths
# exactly once at startup and never retries. The P4 half of that wait counts the proxy's
# installed destination paths -- and on 2026-09-18 a fabric where the proxy INSTALLS NOTHING BY
# DESIGN burned the whole CONVERGE_WAIT (300 s) on every single bring-up:
#
#   * an app package carrying its own P4 program: `lldp_discovery`, `link_watchdog` and
#     `install_initial_routes` are all skipped (proxy_agent/main.py
#     FOREIGN_PIPELINE_FABRIC_SKIPS), because a tutorials p4info declares no
#     controller_packet_metadata and the beacons have no header to ride;
#   * `mode: external`: the proxy opens no arbitration stream at all (EXTERNAL_SKIPS).
#
#   Measured that day: live-p1/02 waited 300 s and then reported `4/12 destination paths, never
#   settled` over a fabric whose twelve ordered pairs all pinged at 0% loss; four driver rounds
#   burned 7.5 minutes each; live-p1/03 printed `destination paths NOT CHECKED` after waiting
#   the full 300 s for a count nobody was working towards.
#
# 🔴 WHAT MUST NOT HAPPEN IS HALF THE SUBJECT. "I did not look" and "I looked and found nothing"
# are the two answers the proxy's `control_plane.skipped` disclosure exists to keep apart, so:
#   * a proxy that says nothing -- no answer, no `control_plane`, `skipped: null` -- must fall
#     through to exactly today's wait. Reading silence as "nothing to wait for" would release
#     the kernel early against a control plane that was still converging, which is the race the
#     whole function replaces;
#   * a proxy that HAS discovered links (skipped without `lldp_discovery`) must still be waited
#     for, byte for byte;
#   * the OVS plane must not be asked at all: it has no /p4/switch_state, and a wait that
#     depended on a P4 endpoint answering would be a new way for an OVS bring-up to hang.
#
# 🔴 THE CONTROL that keeps "it did not wait" from being a sentence this harness always says:
# every skip cell is paired with a cell that asserts the SAME harness does reach the loop and
# does print `waiting for link discovery`, and the poll counter is read positively.
#
# stack.sh returns early when sourced (:1212), so the functions are reached the way
# tests/shell/test_ndt_app_package.sh reaches `ndt`'s: sourced in a subshell, called directly,
# with every reading that would describe this machine answered from a fixture. Nothing here
# reaches root, a port, Mininet or the real lab.
#
# Run:  bash tests/shell/test_stack_await_convergence.sh
# Env:  STACK_UNDER_TEST=<path>  (tests/shell/mutate_stack_await_convergence.sh points it at a copy)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
STACK="${STACK_UNDER_TEST:-$REAL_REPO/tools/test_workflow/stack.sh}"
[[ -r "$STACK" ]] || { echo "  FAILED   no stack.sh at $STACK"; echo "Ran 1 checks, 1 failed"; exit 1; }

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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/stack-await-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.test_run/logs" "$FIX/.test_run/pids"

# A four-host P4 model, so expected_counts -- which is NOT stubbed; it is what makes `want 12`
# a number this fabric implies rather than one this file typed -- has something real to read.
TOPO="$FIX/topo.json"
python3 - "$TOPO" <<'PY'
import json, sys
nodes = [{"device_name": "s%d" % i, "dpid": i, "vertex_type": 0} for i in (1, 2, 3, 4)]
nodes += [{"device_name": "h%d" % i, "dpid": 0, "vertex_type": 1} for i in (1, 2, 3, 4)]
json.dump({"nodes": nodes, "edges": [], "links": []}, open(sys.argv[1], "w"))
PY

# mkss <file> <control-plane spec> -- a /p4/switch_state answer.
#   NOCP   no control_plane object    NULL   skipped: null (startup has not finished)
#   ""     skipped: []                a,b,c  skipped: [a, b, c]
mkss() {
    python3 - "$1" "$2" <<'PY'
import json, sys
f, cp = sys.argv[1], sys.argv[2]
d = {"status": "success", "switches": {}}
if cp != "NOCP":
    d["control_plane"] = {"mode": "ndtwin",
                          "skipped": None if cp == "NULL" else ([] if cp == "" else cp.split(","))}
json.dump(d, open(f, "w"))
PY
}
# And a THREE-switch one, so the external cell below is shaped like live-p1/03 -- the script
# that regressed -- rather than like a copy of the four-switch one.
TOPO3="$FIX/topo3.json"
python3 - "$TOPO3" <<'PY3'
import json, sys
nodes = [{"device_name": "s%d" % i, "dpid": i, "vertex_type": 0} for i in (1, 2, 3)]
nodes += [{"device_name": "h%d" % i, "dpid": 0, "vertex_type": 1} for i in (1, 2, 3)]
json.dump({"nodes": nodes, "edges": [], "links": []}, open(sys.argv[1], "w"))
PY3

SKIPS3=install_initial_routes,link_watchdog,lldp_discovery
SS_FOREIGN="$FIX/ss_foreign.json"; mkss "$SS_FOREIGN" "$SKIPS3"
SS_EXTERNAL="$FIX/ss_external.json"
mkss "$SS_EXTERNAL" "clone_session,install_initial_routes,link_watchdog,lldp_discovery,pipeline,sflow_telemetry"
SS_BASELINE="$FIX/ss_baseline.json"; mkss "$SS_BASELINE" ""
SS_NOCP="$FIX/ss_nocp.json";         mkss "$SS_NOCP" NOCP
SS_NULL="$FIX/ss_null.json";         mkss "$SS_NULL" NULL

# --- the seam -------------------------------------------------------------------------------
# Only the machine is replaced. `await_convergence`, `proxy_skipped_steps`, `expected_counts`
# and `observed_counts` are all REAL -- they are the subject. The `curl` stub answers both
# endpoints off the same switch (the URL), and records every call in a file, because each call
# happens inside a command substitution and a shell variable would not survive it.
# 🔴 THE P4 SWITCH LIST IS A SEQUENCE, NOT A CONSTANT. `SWITCH_SEQ` is one count per call, the
# last value repeating -- so "0 0 4" is a proxy that lists nothing for two polls and then all
# four, which is the only way to assert that the wait does not return early. The counter lives
# in a FILE because every curl runs inside a command substitution and a shell variable would not
# survive it. The two `/v1.0/topology/switches` endpoints are told apart by PORT: :8081 is the
# P4 proxy's (the new wait) and :8080 is Ryu's (the OVS branch), and a stub that answered both
# from one variable would have let an OVS cell pass on a P4 answer.
STUBS='
KERNEL_DIR="'"$FIX"'"
p4_switch_list() {
    local i seq n
    i="$(cat "'"$FIX"'/p4sw.n" 2>/dev/null)"; i="${i:-0}"
    echo "$(( i + 1 ))" > "'"$FIX"'/p4sw.n"
    read -r -a seq <<< "${SWITCH_SEQ:-0}"
    n="${seq[i]:-${seq[$(( ${#seq[@]} - 1 ))]}}"
    python3 -c "import json,sys; print(json.dumps([{\"dpid\": \"%016x\" % (k + 1)} for k in range(int(sys.argv[1]))]))" "$n"
}
curl() {
    printf "%s\n" "$*" >> "'"$FIX"'/curl.log"
    case "$*" in
        */p4/switch_state) [[ -r "${SS_FILE:-}" ]] && cat "$SS_FILE" ;;
        */ryu_server/all_destination_paths)
            printf "{\"status\":\"success\",\"all_destination_paths\":%s}" "${PATHS_JSON:-[]}" ;;
        *:8081/v1.0/topology/switches) p4_switch_list ;;
        */v1.0/topology/switches) printf "%s" "${OVS_SWITCHES:-[]}" ;;
        */v1.0/topology/links)    printf "%s" "${OVS_LINKS:-[]}" ;;
    esac
}
sleep() { printf "sleep %s\n" "$*" >> "'"$FIX"'/sleep.log"; command sleep 0.2; }
countdown() { echo "COUNTDOWN $1 -- $2"; }
'
drive() {   # drive <shell code> -> its output plus a trailing RC=<n>
    : > "$FIX/curl.log"; : > "$FIX/sleep.log"; rm -f "$FIX/p4sw.n"
    KERNEL_DIR="$FIX" bash -c "source '$STACK' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
ss_calls() {
    local n; n="$(/usr/bin/grep -c '/p4/switch_state' "$FIX/curl.log" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
paths_calls() {
    local n; n="$(/usr/bin/grep -c 'all_destination_paths' "$FIX/curl.log" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
p4_switch_calls() {
    local n; n="$(/usr/bin/grep -c ':8081/v1.0/topology/switches' "$FIX/curl.log" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# =============================================================================================
section "1. 🔴 a proxy that says it sent no LLDP is not waited for"
# =============================================================================================
OUT="$(drive "SS_FILE='$SS_FOREIGN'; SWITCH_SEQ='4'; await_convergence p4 '$TOPO' 2")"
check "🔴 it returns success without waiting"            "0" "$(rc_of "$OUT")"
has   "🔴 and says the wait did not happen"              "link discovery: NOT WAITED" "$OUT"
has   "  giving the proxy's own reason"                  "the proxy says it sends no LLDP on this fabric" "$OUT"
has   "  and quoting the list it read"                   "control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery" "$OUT"
hasnt "🔴 it does NOT announce a wait it is not doing"   "waiting for link discovery" "$OUT"
hasnt "  and does not fall back to a fixed sleep"        "COUNTDOWN" "$OUT"
check "🔴 the path count is never polled at all"         "0" "$(paths_calls)"
check "  and the proxy was asked exactly once"           "1" "$(ss_calls)"
# 🔴 What this section does NOT say any more: that the function returns without
# waiting for anything. It skips the DISCOVERY wait; section 1B is the half that
# stayed, and the live regression that put it there.

# external is the same shape one layer up: the proxy opens no arbitration stream, so
# lldp_discovery is in EXTERNAL_SKIPS too. live-p1/03 waited the full 300 s for this.
OUT="$(drive "SS_FILE='$SS_EXTERNAL'; SWITCH_SEQ='4'; await_convergence p4 '$TOPO' 2")"
check "🔴 an external control plane is not waited for either" "0" "$(rc_of "$OUT")"
has   "  and says so the same way"                       "link discovery: NOT WAITED" "$OUT"
check "  with no path poll"                              "0" "$(paths_calls)"

# =============================================================================================
section "1B. 🔴 the skip is about DISCOVERY only -- the switch list is still waited for"
# =============================================================================================
# 🔴 THE LIVE REGRESSION THIS SECTION EXISTS FOR. 2026-09-18 21:28, the first live round with
# the NOT WAITED skip in it: `live-p1/03` (mode external) came back
# `XX kernel: 3 switches, 0 up (want 3/3)` -- against `ok kernel: 3 switches, 3 up` from the
# same script four hours earlier. Two different things had been riding on the 300 s discovery
# wait and only one of them was about discovery:
#   * `GET /v1.0/topology/switches` serves connected_switch_dpids() only;
#   * the kernel's updateSwitches sets isUp for exactly the dpids that reply lists and never
#     clears it for one it does not (FINDINGS #46) -- a one-way ratchet;
#   * the kernel pulls once at startup and `ndt`'s verify runs once, right after.
# So the skip started the kernel before the proxy had listed a single switch, and the twin
# believed a healthy fabric was powered off. 02/02b did not show it because on a package
# pipeline the proxy connects the switches synchronously in startup (it pushes their pipeline
# and their entries) -- they were listed before stack.sh ever asked.

# (a) it returns once every switch the model declares is listed
OUT="$(drive "SS_FILE='$SS_FOREIGN'; SWITCH_SEQ='4'; await_convergence p4 '$TOPO' 2")"
check "🔴 it waits for the switch list, then returns 0"  "0" "$(rc_of "$OUT")"
has   "  saying what it is waiting for"                  "waiting for the proxy to list 4 switches" "$OUT"
has   "  and why the kernel cares"                       "it is what the kernel reads isUp from" "$OUT"
has   "🔴 and reports how many were listed"              "4 switches listed after" "$OUT"
check "🔴 the switch list IS polled on this path"        "1" "$([[ "$(p4_switch_calls)" -ge 1 ]] && echo 1 || echo 0)"
check "🔴 and the destination paths still are NOT"       "0" "$(paths_calls)"
hasnt "  no timeout warning on the happy path"           "did not converge" "$OUT"

# (b) 🔴 THE CELL THAT SAYS IT DID NOT RETURN EARLY, and the reason SWITCH_SEQ is a sequence: a
# proxy that lists nothing for two polls and then all four. An implementation that returned on
# the first answer would have reported a converged fabric with nothing on it.
OUT="$(drive "SS_FILE='$SS_FOREIGN'; SWITCH_SEQ='0 0 4'; await_convergence p4 '$TOPO' 30")"
check "🔴 it does not return while fewer than four are listed" "0" "$(rc_of "$OUT")"
has   "  and ends on the full count, not on the first answer" "4 switches listed after" "$OUT"
check "🔴 which took more than one poll"                 "3" "$(p4_switch_calls)"
hasnt "  it never calls a partial list a full one"       "0 switches listed" "$OUT"

# (c) the timeout path, in the words the old loop's timeout already used -- so `ndt`'s [3/3]
# reports the shortfall the way it already does instead of this script inventing a verdict.
OUT="$(drive "SS_FILE='$SS_FOREIGN'; SWITCH_SEQ='0'; await_convergence p4 '$TOPO' 2")"
check "🔴 a list that never fills still returns 0"       "0" "$(rc_of "$OUT")"
has   "  in the shape the old loop's timeout already had" "did not converge within 2s" "$OUT"
has   "  naming what was seen and what was wanted"       "last: switches=0, want: 4" "$OUT"
has   "  and what starting anyway costs"                 "the kernel pulls once and never retries" "$OUT"
check "  destination paths are not polled even then"     "0" "$(paths_calls)"

# (e) BOTH fixtures take this path. The external one is live-p1/03 -- three switches, and the
# script that actually regressed; the package one is 02/02b, which did not.
OUT="$(drive "SS_FILE='$SS_EXTERNAL'; SWITCH_SEQ='0 3'; await_convergence p4 '$TOPO3' 30")"
check "🔴 an external control plane waits for its switches too" "0" "$(rc_of "$OUT")"
has   "  the skip line is still printed first"           "link discovery: NOT WAITED" "$OUT"
has   "  and the count comes off ITS model, not the other one" "3 switches listed after" "$OUT"
check "  after more than one poll"                       "2" "$(p4_switch_calls)"

# A model this script cannot count is not a fabric to release the kernel against.
OUT="$(drive "SS_FILE='$SS_FOREIGN'; SWITCH_SEQ='4'; await_convergence p4 '$FIX/no-such-model.json' 7")"
has   "🔴 an uncountable model falls back to the fixed wait" "COUNTDOWN 7" "$OUT"
has   "  and says which question it could not answer"    "cannot count the switches" "$OUT"
check "  and still does not poll the destination paths"  "0" "$(paths_calls)"

# =============================================================================================
section "2. 🔴 THE CONTROL -- a proxy that IS discovering links is waited for, unchanged"
# =============================================================================================
# Without this the section above is a sentence this harness would print for any implementation,
# including one that had simply deleted the wait.
OUT="$(drive "SS_FILE='$SS_BASELINE'; PATHS_JSON='$(python3 -c 'print([0]*12)')'
await_convergence p4 '$TOPO' 30")"
check "🔴 a baseline fabric still converges the old way" "0" "$(rc_of "$OUT")"
has   "🔴 and announces the wait, with the model's number" "waiting for link discovery: want 12 destination paths" "$OUT"
has   "  reporting when it converged"                    "converged after" "$OUT"
hasnt "  and never claims the wait was skipped"          "NOT WAITED" "$OUT"
check "🔴 the path count IS polled here"                 "1" "$([[ "$(paths_calls)" -ge 1 ]] && echo 1 || echo 0)"

# skipped that does not name lldp_discovery: the proxy skipped something else and IS beaconing.
# Reading "some steps were skipped" as "do not wait" would skip the wait on a fabric that needs
# it, which is the widening this cell exists to catch.
SS_OTHER="$FIX/ss_other.json"; mkss "$SS_OTHER" "sflow_telemetry"
OUT="$(drive "SS_FILE='$SS_OTHER'; PATHS_JSON='[]'; await_convergence p4 '$TOPO' 2")"
has   "🔴 a skip list without lldp_discovery still waits" "waiting for link discovery: want 12 destination paths" "$OUT"
hasnt "  and does not claim the proxy said it"           "NOT WAITED" "$OUT"

# =============================================================================================
section "3. 🔴 silence is not consent -- three ways the proxy can say nothing"
# =============================================================================================
# 🔴 `skipped: null` is the endpoint's own word for "startup has not finished yet"
# (proxy_agent/main.py:455-459 keeps it deliberately apart from `[]`). Reading it as an empty
# list would turn "nobody has started" into "nothing was skipped".
for name in NOCP NULL NONE; do
    case "$name" in
        NOCP) f="$SS_NOCP"; label="an answer with no control_plane" ;;
        NULL) f="$SS_NULL"; label="skipped: null (startup unfinished)" ;;
        NONE) f="$FIX/no-such-file";  label="an endpoint that does not answer" ;;
    esac
    OUT="$(drive "SS_FILE='$f'; PATHS_JSON='[]'; await_convergence p4 '$TOPO' 2")"
    has   "🔴 $label falls through to today's wait" "waiting for link discovery: want 12 destination paths" "$OUT"
    hasnt "  and never says the proxy told it not to"    "NOT WAITED" "$OUT"
    check "  after a BOUNDED re-read, not one try and not forever" "5" "$(ss_calls)"
done

# =============================================================================================
section "4. 🔴 the OVS plane is never asked about a P4 endpoint"
# =============================================================================================
# OVS has no /p4/switch_state. A wait that depended on it answering would be a new way for an
# OVS bring-up to stall for five seconds on every start, on an endpoint that is not there.
OUT="$(drive "SS_FILE='$SS_FOREIGN'; OVS_SWITCHES='$(python3 -c 'print([0]*4)')'; OVS_LINKS='[]'
await_convergence ovs '$TOPO' 2")"
check "🔴 the P4 endpoint is not consulted on the OVS plane" "0" "$(ss_calls)"
has   "  and the OVS wait is the one that runs"          "waiting for 4 switches, 0 links, and all-destination paths" "$OUT"
hasnt "  with no P4 skip line"                           "NOT WAITED" "$OUT"

# =============================================================================================
section "5. 🔴 proxy_skipped_steps on its own"
# =============================================================================================
sk() { drive "SS_FILE='$1'; proxy_skipped_steps; echo" | /usr/bin/grep -v '^RC=' | head -1; }
check "  the list comes back comma-joined and sorted"    "install_initial_routes,link_watchdog,lldp_discovery" "$(sk "$SS_FOREIGN")"
check "  an empty skip list is an empty answer"          "" "$(sk "$SS_BASELINE")"
OUT="$(drive "SS_FILE='$SS_BASELINE'; proxy_skipped_steps")"
check "🔴 and 'nothing was skipped' is rc 0, not rc 1"   "0" "$(rc_of "$OUT")"
OUT="$(drive "SS_FILE='$SS_NULL'; proxy_skipped_steps")"
check "🔴 while 'the proxy has not said' is rc 1"        "1" "$(rc_of "$OUT")"
OUT="$(drive "SS_FILE='$SS_NOCP'; proxy_skipped_steps")"
check "  and so is an answer with no control_plane"      "1" "$(rc_of "$OUT")"

sw() { drive "$1" | /usr/bin/grep -v '^RC=' | head -1; }
check "  model_switch_count reads vertex_type 0 nodes"   "4" "$(sw "model_switch_count '$TOPO'")"
check "  and the three-switch model gives three"         "3" "$(sw "model_switch_count '$TOPO3'")"
check "🔴 an unreadable model gives NOTHING, not zero"   "" "$(sw "model_switch_count '$FIX/no-such-model.json'")"
check "  observed_switch_count counts the proxy's list"  "2" "$(sw "SWITCH_SEQ='2'; observed_switch_count")"
check "  an empty list is a count of zero"               "0" "$(sw "SWITCH_SEQ='0'; observed_switch_count")"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
