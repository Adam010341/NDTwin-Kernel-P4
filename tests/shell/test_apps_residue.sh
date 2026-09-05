#!/usr/bin/env bash
#
# After an app is gone, does anything say what it left ON THE NETWORK?
#
# [Co-developed with claude code -- Adam]
#
# KNOWN-ISSUES G-12, measured 2026-09-05 (R6, 1/1, OVS). An app took `graph_lock`, installed a
# rule on s2 (pri 96, ["OUTPUT:2"]), and was killed by pid. Both survived it, and every
# cleanliness verb went green:
#
#     ndt apps orphans      ok  no untracked app processes        rc 0
#     ndt status --check                                          rc 0
#     POST /ndt/acquire_lock graph_lock -> 423 {"held_by_lease": 4, "retry_after_s": 30}
#     s2 still forwarding on pri 96
#
# Neither verb was broken: they answer a question about PROCESSES. Nothing answered the other
# one. Adam's decision (09-05 grill round 5): `apps stop` and `apps orphans` must LIST the
# rules and locks, and must not delete them.
#
# 🔴 FOUR DIRECTIONS, because "print the residue" has wrong answers that look like fixes:
#   * printing every rule buries the one that matters under the fabric's own baseline (5C);
#   * printing nothing when a reading fails reports a clean network nobody looked at -- the
#     same failure G-12 is about, in a new place (5B, 5E, 5F);
#   * deleting what it finds is a decision on the wire that a reporting verb must not take
#     (5D, and the python suite's test_nothing_in_the_residue_path_deletes_anything);
#   * wiring it to `stop` only would miss the measured case entirely, in which `stop` found
#     nothing to stop because the app was ALREADY dead (5G).
#
# Offline. REPO is redirected into a temp dir; the kernel is a stub, so no port is opened, no
# acquire is POSTed and no flow table is read. The lab was in use the night this was written.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_apps_residue.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }
for sib in ports.sh sudo_surface.sh; do
    [[ -r "$(dirname "$NDT")/$sib" ]] || { echo "ndt needs $sib beside it; not at $(dirname "$NDT")/$sib"; exit 2; }
done

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
has()   { grep -qF -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2'"; }
hasnt() { grep -qF -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in the output" || t_ok "$1"; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-residue-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs"

# The flow table, in the shape /ndt/get_switch_openflow_table_entries returns (API doc §5).
# G-12's own rule on s2, plus the baseline `ndt up` installs and which must not drown it.
mk_entries() {   # <app-rule-age-seconds>
    python3 - "$FIX/entries.json" "$1" <<'PY'
import json, sys
p, age = sys.argv[1], int(sys.argv[2])
def row(dur, pri, dpid, acts):
    return {"actions": acts, "byte_count": 0, "cookie": 0, "duration_sec": dur,
            "duration_nsec": 0, "flags": 0, "hard_timeout": 0, "idle_timeout": 0,
            "length": 96, "match": {"in_port": 1}, "packet_count": 0,
            "priority": pri, "table_id": 0}
data = [
    {"dpid": 1, "flows": {"1": [row(9000, 10, 1, ["OUTPUT:1"]),
                                row(9000, 0, 1, ["CONTROLLER"]),
                                row(9000, 65535, 1, ["OUTPUT:2"])]}},
    {"dpid": 2, "flows": {"2": [row(age, 96, 2, ["OUTPUT:2"]),
                                row(9000, 10, 2, ["OUTPUT:1"])]}},
]
json.dump(data, open(p, "w"))
PY
}
mk_entries 300

# app_started_at reads the pidfile's mtime when the process is gone -- which is G-12's case.
started_ago() { # <app> <seconds ago>
    : > "$FIX/.test_run/pids/app_$1.pid"
    touch -d "@$(( $(date +%s) - $2 ))" "$FIX/.test_run/pids/app_$1.pid"
}
no_pidfile() { rm -f "$FIX/.test_run/pids/app_$1.pid"; }

# --- the seam ------------------------------------------------------------------------------
# The kernel is replaced at the two functions that talk to it, so nothing is fetched and no
# acquire is POSTed. residue_report, app_started_at, residue_rule_lines and the window
# comparison itself all run for real. FX_LOCK decides what the lock probe answers.
STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
port_open() { [[ "${FX_KERNEL_UP:-1}" == 1 ]]; }
http_get_flow_entries() { [[ "${FX_NO_TABLE:-0}" == 1 ]] || cat "$REPO/entries.json"; }
'
LOCKS_FREE='lock_probe() { echo free; }'
LOCK_HELD='lock_probe() { case "$1" in graph_lock) echo "held 4 30" ;; *) echo free ;; esac; }'
LOCK_BLIND='lock_probe() { echo "unknown :8000 gave no answer"; }'

run_residue() {   # <lock-stub> <apps...>
    local lockstub="$1"; shift
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$lockstub
residue_report $*
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# ==========================================================================================
section "5A. G-12: the lock the dead app is still holding is named, with its lease"
started_ago energy 600
OUT="$(run_residue "$LOCK_HELD" energy)"
has   "🔴 the held lock is reported"                     "lock  graph_lock HELD" "$OUT"
has   "  with the lease the kernel answered 423 with"    "held_by_lease=4" "$OUT"
has   "  and the TTL that will free it"                  "frees itself in 30s" "$OUT"
has   "  the locks that are free are said to be free"    "lock  routing_lock free" "$OUT"
has   "🔴 and the lease is not presented as an owner"    "the lease id is not an owner" "$OUT"
check "reporting residue does not fail the command"      "0" "$(rc_of "$OUT")"

section "5B. 🔴 a lock that could not be probed is NOT CHECKED -- never 'free'"
OUT="$(run_residue "$LOCK_BLIND" energy)"
has   "it says the lock was not checked"                 "lock  routing_lock NOT CHECKED" "$OUT"
hasnt "🔴 and does not report it as free"                "routing_lock free" "$OUT"

section "5C. G-12's rule is listed, and the baseline it would drown in is not"
OUT="$(run_residue "$LOCKS_FREE" energy)"
has   "🔴 the rule installed during the app's window"    "rule  dpid=2" "$OUT"
has   "  named by priority"                              "pri=96" "$OUT"
has   "  and by what it does"                            '"OUTPUT:2"' "$OUT"
has   "  with its age"                                   "installed 5m00s ago" "$OUT"
has   "  counted, and labelled SUSPECTED"                "1 SUSPECTED rule(s) -- by time only" "$OUT"
hasnt "🔴 the pri-65535 baseline rule is not listed"     "pri=65535" "$OUT"
hasnt "🔴 nor the pri-0 one"                             "pri=0 " "$OUT"
has   "  and the report says why it can only suspect"    "cookie is 0 everywhere" "$OUT"

mk_entries 9000
OUT="$(run_residue "$LOCKS_FREE" energy)"
has   "🔴 a window with nothing new in it says so plainly" "no flow entry arrived during that window" "$OUT"
hasnt "  and claims no rule"                             "SUSPECTED rule(s)" "$OUT"
mk_entries 300

section "5D. 🔴 nothing is deleted, and the report says so and how to do it by hand"
OUT="$(run_residue "$LOCK_HELD" energy)"
has   "it says the residue was not deleted"              "NOT deleted, and nothing here deletes them" "$OUT"
has   "  the lock heals on its own"                      "a lock heals" "$OUT"
has   "🔴 the rule does not -- no TTL, no owner"         "no TTL, no owner, no cleanup path" "$OUT"
has   "  and the command to remove one is handed over"   "delete_flow_entry" "$OUT"

section "5E. 🔴 an app with no window is said to have none -- not reported clean"
no_pidfile energy
OUT="$(run_residue "$LOCKS_FREE" energy)"
has   "it says there is no window"                       "no window, so no rule can be dated" "$OUT"
has   "🔴 and refuses to read that as 'left nothing'"    "NOT 'this app left nothing'" "$OUT"
hasnt "  no rule is attributed to it"                    "rule  dpid=2" "$OUT"
started_ago energy 600

section "5F. 🔴 a kernel that is down means NOT CHECKED, never 'the lab is clean'"
OUT="$(FX_KERNEL_UP=0 run_residue "$LOCKS_FREE" energy)"
has   "it says rules and locks cannot be checked"        "rules and locks CANNOT be checked" "$OUT"
has   "🔴 and says what that does not mean"              "this is not 'the lab is clean'" "$OUT"
OUT="$(FX_NO_TABLE=1 run_residue "$LOCKS_FREE" energy)"
has   "an empty flow table is 'NOT checked', not 'none'" "rules NOT checked (not 'none found')" "$OUT"

section "5G. 🔴 the wiring -- and the branch the finding was actually measured in"
# In G-12 the app was killed by pid BEFORE `ndt apps stop` ran, so stop found nothing to stop
# and returned its truthful no-op. A residue report wired only to the "something was stopped"
# branch would have printed nothing in the one case it exists for.
started_ago energy 600
STOP_OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$LOCK_HELD
app_stop() { info \"nothing to stop\"; return 2; }
cmd_apps stop energy
echo \"RC=\$?\"" 2>&1)"
check "'apps stop' on an already-dead app is still a no-op" "2" "$(rc_of "$STOP_OUT")"
has   "🔴 and the residue is printed anyway"             "network residue" "$STOP_OUT"
has   "  naming the lock it left"                        "graph_lock HELD" "$STOP_OUT"
has   "  and the rule it left"                           "pri=96" "$STOP_OUT"

ORPH_OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$LOCK_HELD
apps_orphans() { ok \"no untracked app processes\"; return 0; }
cmd_apps orphans
echo \"RC=\$?\"" 2>&1)"
has   "'apps orphans' prints the residue too"            "network residue" "$ORPH_OUT"
has   "  naming the rule"                                "pri=96" "$ORPH_OUT"
has   "🔴 orphans' own answer about PROCESSES is unchanged" "no untracked app processes" "$ORPH_OUT"
check "🔴 and so is its exit code -- callers read it as processes" "0" "$(rc_of "$ORPH_OUT")"

section "5H. lock_probe itself: what the kernel answered, and what it did not"
# 🔴 Groups 5A-5G stub lock_probe out, so nothing above this line looks at how a 423 is read.
# The mutation gate found that gap: a lock_probe that answered "free" to every 423 survived
# every case in this file. This drives the real function with a stubbed curl.
lock_says() {   # <http-code> <body>
    bash -c "source '$NDT' >/dev/null 2>&1
curl() { printf '%s\n%s' '$2' '$1'; }
lock_probe graph_lock" 2>&1
}
check "🔴 a 423 is a HELD lock, with the lease it named"  "held 4 30" \
      "$(lock_says 423 '{"detail":"lock is held","error":"Lock acquisition failed","held_by_lease":4,"retry_after_s":30}')"
check "  a 200 is a free lock"                            "free" \
      "$(lock_says 200 '{"status":"locked","type":"graph_lock","lease":41}')"
check "🔴 any other code is NOT CHECKED, never free"      "unknown http 500" \
      "$(lock_says 500 '{"error":"Internal server error"}')"
check "🔴 a 423 whose body cannot be read still says HELD" "held ? ?" \
      "$(lock_says 423 'not json at all')"
check "🔴 no answer at all is not a free lock"            "unknown :8000 gave no answer" \
      "$(bash -c "source '$NDT' >/dev/null 2>&1
curl() { :; }
lock_probe graph_lock" 2>&1)"

# --- done ---------------------------------------------------------------------------------
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
