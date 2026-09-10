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
#
# 🔴 duration_nsec is NON-zero here, and that is load-bearing since W16-3. On a real switch
# OpenFlow's duration is (sec, nsec) since install, so a rule installed under a second ago has
# sec 0 and nsec != 0; BOTH zero is the signature of the P4 proxy's synthesised rows, which
# carry no clock at all. mk_entries_p4_zero below writes that shape.
mk_entries() {   # <app-rule-age-seconds>
    python3 - "$FIX/entries.json" "$1" <<'PY'
import json, sys
p, age = sys.argv[1], int(sys.argv[2])
def row(dur, pri, dpid, acts):
    return {"actions": acts, "byte_count": 0, "cookie": 0, "duration_sec": dur,
            "duration_nsec": 91000000, "flags": 0, "hard_timeout": 0, "idle_timeout": 0,
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

# W16-3, measured 2026-09-07 (P4 4 hosts, trunk 862c4bf8, logs/w163-*): a route was installed
# on the P4 plane and the endpoint read twice, +12 s and +32 s later. That entry and every
# pre-existing one answered duration_sec 0, duration_nsec 0, while packet_count moved. This is
# that table.
mk_entries_p4_zero() {
    python3 - "$FIX/entries.json" <<'PY'
import json, sys
def row(pri, acts):
    return {"actions": acts, "byte_count": 4212, "cookie": 0, "duration_sec": 0,
            "duration_nsec": 0, "flags": 0, "hard_timeout": 0, "idle_timeout": 0,
            "length": 96, "match": {"in_port": 1}, "packet_count": 42,
            "priority": pri, "table_id": 0}
json.dump([{"dpid": 1, "flows": {"1": [row(10, ["OUTPUT:1"]), row(0, ["CONTROLLER"])]}},
           {"dpid": 2, "flows": {"2": [row(96, ["OUTPUT:2"])]}}], open(sys.argv[1], "w"))
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
# W16-3: which plane the table came from. Stubbed rather than read, because the real
# live_dataplane_kind() shells out to ps and to `sudo -n ovs-vsctl` -- this suite must not
# depend on what is running on the machine it is run from, and must not need a grant.
live_dataplane_kind() { echo "${FX_PLANE:-ovs}"; }
# 3-51: the tree `sudo ndtwin-lab` starts sim in, and therefore where sim'"'"'s log is looked for.
# Stubbed for the same reason live_dataplane_kind is: the real one resolves the MAIN CHECKOUT,
# whose .test_run/logs/app_sim.log is a real file left by a real run, and a suite whose exit
# code depends on that is a suite that reports the machine rather than the code. What the
# resolution rule itself does is tests/shell/test_ndt_helper_apps_window.sh group 1.
lab_kernel_dir() { echo "$REPO"; }
# H2 (2026-09-11): `cmd_apps orphans` now also prints a `stack:` line, and stack_state reads
# two ports and two process counts. Answered from the fixture for the same reason
# live_dataplane_kind is -- the real bmv2_count and mn_count shell out to ps, and a suite whose
# output depends on what is running on this machine is a suite that reports the machine.
bmv2_count() { echo "${FX_BMV2:-0}"; }
mn_count() { echo "${FX_MN:-0}"; }
port_open() { case "$1" in 8081) [[ "${FX_PROXY_UP:-0}" == 1 ]] ;; *) [[ "${FX_KERNEL_UP:-1}" == 1 ]] ;; esac; }
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
has   "  counted, dated and undated apart"               "1 rule(s) listed: 1 dated inside the window," "$OUT"
has   "  and labelled SUSPECTED by time only"            "SUSPECTED by time only" "$OUT"
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

orphans_with() {   # <lock-stub> [extra shell] -> cmd_apps orphans output + RC=
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
apps_orphans() { ok \"no untracked app processes\"; return ${FX_ORC:-0}; }
${2:-}
cmd_apps orphans
echo \"RC=\$?\"" 2>&1
}
ORPH_OUT="$(orphans_with "$LOCK_HELD")"
has   "'apps orphans' prints the residue too"            "network residue" "$ORPH_OUT"
has   "  naming the rule"                                "pri=96" "$ORPH_OUT"
has   "🔴 orphans' own answer about PROCESSES is unchanged" "no untracked app processes" "$ORPH_OUT"

# ==========================================================================================
section "5I. W16-1: the exit code. Adam reversed the recommendation -- residue must be RED"
# 🔴 The recommendation (W16-SUMMARY §7 q1) was to leave orphans' rc meaning "processes", so
# `arm_up.sh` and the other gates kept working. Adam ruled the other way, 09-06 grill §4D round
# 7, and the reason is G-12 itself: the finding IS "every existing check went green over it".
# A residue report whose exit code cannot fail is one more check that goes green.
check "🔴 a held lock and a rule in the window -> rc 4, not 0" "4" "$(rc_of "$ORPH_OUT")"
has   "  and it says what 4 means"                       "RESIDUE: the processes are gone and the network is not clean" "$ORPH_OUT"
has   "🔴 and that 4 is not 1 -- nothing is running to stop" "rc 4 is NOT rc 1" "$ORPH_OUT"

mk_entries 9000                       # no rule in the window; locks free
OUT2="$(orphans_with "$LOCKS_FREE")"
check "🔴 a clean network -> rc 0 (the codes are not always red)" "0" "$(rc_of "$OUT2")"
hasnt "  and nothing claims residue"                     "RESIDUE:" "$OUT2"

OUT2="$(orphans_with "$LOCK_HELD")"
check "🔴 a held lock ALONE is still residue -> rc 4"    "4" "$(rc_of "$OUT2")"

OUT2="$(orphans_with "$LOCK_BLIND")"
check "🔴 a lock that could not be probed -> rc 5, NOT 0" "5" "$(rc_of "$OUT2")"
has   "  and 5 says it is not 'clean'"                   "this is not 'the network is clean'" "$OUT2"

OUT2="$(FX_KERNEL_UP=0 orphans_with "$LOCKS_FREE")"
check "🔴 a kernel that is down -> rc 5, NOT 0"          "5" "$(rc_of "$OUT2")"

# 🔴 The process answer still wins. A live untracked process needs `ndt apps stop`; a leftover
# rule needs a delete by hand. A caller that cannot tell them apart cannot act on either.
OUT2="$(FX_ORC=1 orphans_with "$LOCK_HELD")"
check "🔴 untracked PROCESSES still win the code: rc 1"  "1" "$(rc_of "$OUT2")"
has   "  and the residue is still named beside it"       "the network is not clean either" "$OUT2"
mk_entries 300

section "5J. W16-3: the P4 plane has no time axis, so nothing on it can be dated"
# Measured 2026-09-07: a rule installed on P4 read duration_sec 0 / duration_nsec 0 twelve and
# thirty-two seconds later, alongside every pre-existing entry. Believing that 0 dates the
# whole table to "just installed" -- inside every window, however short.
OUT="$(FX_PLANE=p4 run_residue "$LOCKS_FREE" energy)"
has   "🔴 it says the plane cannot be windowed"          "CANNOT WINDOW" "$OUT"
has   "  naming why"                                     "carry NO install time" "$OUT"
has   "  and what the list below it is"                  "this is the whole flow table, not a residue list" "$OUT"
has   "🔴 the app's own rule is listed"                  "pri=96" "$OUT"
has   "🔴 but with age UNKNOWN, not an age"              "age=UNKNOWN (P4 plane" "$OUT"
hasnt "🔴 and nothing is dated 0 seconds ago"            "installed 0s ago" "$OUT"
has   "  the baseline rules are listed too, since none can be excluded" "pri=65535" "$OUT"
has   "  counted apart from dated ones"                  "0 dated inside the window," "$OUT"

OUT2="$(FX_PLANE=p4 orphans_with "$LOCKS_FREE")"
check "🔴 undatable is rc 5 (NOT CHECKED), never rc 4 (residue)" "5" "$(rc_of "$OUT2")"
has   "  and it says so in words"                        "NOT CHECKED: the residue question could not be answered" "$OUT2"

section "5K. W16-3: duration 0/0 is the synthetic signature, whatever the plane says it is"
# The same table read through a path that did not name the plane. `0` here is not "now": a
# switch that really installed a rule this second reports duration_nsec != 0.
mk_entries_p4_zero
OUT="$(FX_PLANE=unknown run_residue "$LOCKS_FREE" energy)"
has   "🔴 it refuses to window a table with no clock in it" "CANNOT WINDOW" "$OUT"
has   "  naming the field pair"                          "duration_sec=0 AND duration_nsec=0" "$OUT"
has   "🔴 every rule is age=UNKNOWN"                     "age=UNKNOWN (duration_sec=0 AND duration_nsec=0" "$OUT"
hasnt "🔴 and none is dated to right now"                "installed 0s ago" "$OUT"
mk_entries 300
# 🔴 The other direction: a REAL sub-second install (sec 0, nsec set) is still dated. Without
# this case a rule that answered "everything with duration 0 is unknown" would pass 5K.
python3 - "$FIX/entries.json" <<'PY'
import json, sys
json.dump([{"dpid": 5, "flows": {"5": [
    {"actions": ["OUTPUT:9"], "byte_count": 0, "cookie": 0, "duration_sec": 0,
     "duration_nsec": 4000000, "flags": 0, "hard_timeout": 0, "idle_timeout": 0,
     "length": 96, "match": {"in_port": 1}, "packet_count": 0,
     "priority": 96, "table_id": 0}]}}], open(sys.argv[1], "w"))
PY
OUT="$(FX_PLANE=ovs run_residue "$LOCKS_FREE" energy)"
has   "🔴 sec=0 with nsec set is a real just-installed rule, and is DATED" "installed 0s ago" "$OUT"
hasnt "  no rule line says UNKNOWN"                      "age=UNKNOWN (" "$OUT"
has   "  and it is counted as dated"                     "1 rule(s) listed: 1 dated inside the window," "$OUT"
hasnt "  and the plane is not called blind"              "CANNOT WINDOW" "$OUT"
mk_entries 300

section "5L. an app with no window: a LOST record counts against the code, an absent one does not"
# 🔴 Five apps have no pidfile on a machine where nobody started them. Counting that as "could
# not check" would make `ndt apps orphans` answer 5 on every clean machine, and a gate that can
# never pass is a gate nobody reads -- which is how G-12's own green checks stopped being read.
# The log is the discriminator: app_spawn creates it, so a non-empty one is evidence it ran.
#
# 🔴 te and not energy since 3-51 (2026-09-07). This group needs an app whose log question CAN
# be answered, and energy is exactly the app whose cannot be: the lab helper starts it with no
# `script -f` and it has no disk log on any machine. Driving it here asserted that an absent
# file means "never ran" for an app where the file never exists -- true by construction, and
# the same sentence live printed about a sim that had run four minutes earlier. energy's own
# behaviour is group 5M below and tests/shell/test_ndt_helper_apps_window.sh group 7.
no_pidfile te
no_pidfile energy
: > "$FIX/.test_run/logs/app_te.log"
OUT="$(run_residue "$LOCKS_FREE" te)"
has   "an empty log reads as 'never ran here'"           "no sign it ever ran here" "$OUT"
check "  and does not make the verb red"                 "0" "$(rc_of "$(orphans_with "$LOCKS_FREE")")"
echo "something was logged" > "$FIX/.test_run/logs/app_te.log"
OUT="$(run_residue "$LOCKS_FREE" te)"
has   "🔴 a non-empty log means it RAN and the window is lost" "the window is LOST" "$OUT"
check "🔴 and that is rc 5 -- not checked, not clean"    "5" "$(rc_of "$(orphans_with "$LOCKS_FREE")")"
rm -f "$FIX/.test_run/logs/app_te.log"

section "5M. 3-51: an app nobody can ask is not an app that was asked"
# 🔴 energy has no disk log anywhere -- `ndtwin-lab energy-start` is a bare tmux session. Until
# 09-07 the report said "no sign it ever ran here" about it, which is a claim about a channel
# that does not exist. Adam's E-7 rule: "查不了" may be non-red, "沒去查" may not look like
# "查了沒事".
no_pidfile energy
OUT="$(run_residue "$LOCKS_FREE" energy)"
has   "🔴 it says the question cannot be asked"          "CANNOT BE ASKED" "$OUT"
hasnt "🔴 and does not claim it never ran"               "no sign it ever ran here" "$OUT"
check "  and it is not red on its own"                   "0" "$(rc_of "$(orphans_with "$LOCKS_FREE")")"
started_ago energy 600

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

# ==========================================================================================
section "H2. 'apps orphans' says what of the STACK is up -- the reading it never had"
# ==========================================================================================
# Measured live by ROLE-2, 2026-09-11 (ROLE-2-CYCLES-REPORT §4): orphans_verdict.sh printed
# CLEAN three times over a machine whose stack was half up -- 10 bmv2 + 14 mininet with the
# kernel down (cycle-07), 15 mininet + a topo session (cycle-12), and a kernel serving a
# 14-node graph with 0 bmv2 and 0 mininet (cycle-13). Every verdict was correct about what it
# had been given: nothing in this report mentioned the kernel, the fabric or the proxy.
#
# Report only. ndt's 0/1/2/4/5 rc table is the spec (ndt help) and is NOT touched by this
# group -- the rc assertions below are the proof of that.

# cycle-13: a control plane with nothing under it.
OUT="$(FX_KERNEL_UP=1 FX_BMV2=0 FX_MN=0 FX_PROXY_UP=1 orphans_with "$LOCKS_FREE")"
has   "🔴 the stack line is printed"                     "stack: kernel=up dataplane=none" "$OUT"
has   "  with the counts beside the word"                "bmv2=0 mininet=0" "$OUT"
has   "  and the proxy"                                  "proxy=up" "$OUT"
has   "🔴 and the verdict word a reader can parse"       "verdict=HALF" "$OUT"
has   "  with the sentence that says what it means"      "HALF A STACK" "$OUT"
has   "  and the remedy"                                 "take it down:  ndt down" "$OUT"
has   "  and the physical-mode caveat, not guessed at"   "--mode physical" "$OUT"

# cycle-07: a data plane with nothing recording it.
OUT="$(FX_KERNEL_UP=0 FX_BMV2=10 FX_MN=14 orphans_with "$LOCKS_FREE")"
has   "🔴 a fabric with no kernel is HALF too"           "verdict=HALF" "$OUT"
has   "  and the plane is named from the count"          "dataplane=p4" "$OUT"
has   "  with both counts"                               "bmv2=10 mininet=14" "$OUT"
# cycle-12: mininet processes, no bmv2 -- the OVS shape of the same state.
OUT="$(FX_KERNEL_UP=0 FX_BMV2=0 FX_MN=15 orphans_with "$LOCKS_FREE")"
has   "  and an OVS fabric reads as mininet"             "dataplane=mininet bmv2=0 mininet=15" "$OUT"
has   "  still HALF"                                     "verdict=HALF" "$OUT"

# 🔴 THE CONTROLS. "Anything up is a finding" would satisfy every cell above and make every
# mid-round 'apps orphans' a failure -- arm_up.sh asks this verb at the START of a round.
OUT="$(FX_KERNEL_UP=1 FX_BMV2=10 FX_MN=14 orphans_with "$LOCKS_FREE")"
has   "🔴 a healthy P4 fabric is whole-up, not HALF"     "verdict=whole-up" "$OUT"
hasnt "  and no HALF sentence is printed"                "HALF A STACK" "$OUT"
has   "  it says why that is not residue"                "not residue" "$OUT"
OUT="$(FX_KERNEL_UP=1 FX_BMV2=0 FX_MN=14 orphans_with "$LOCKS_FREE")"
has   "  a healthy OVS fabric too"                       "verdict=whole-up" "$OUT"
OUT="$(FX_KERNEL_UP=0 FX_BMV2=0 FX_MN=0 orphans_with "$LOCKS_FREE")"
has   "🔴 and a finished round is whole-down"            "verdict=whole-down" "$OUT"
hasnt "  with no HALF sentence"                          "HALF A STACK" "$OUT"
has   "  and it says what that means"                    "nothing of the stack is up" "$OUT"

# 🔴 The rc table is the spec (ndt help), so the stack word must not move it. Asserted as a
# PAIR over the same residue state: the only difference between the two runs is what the stack
# looks like, so an rc that changed would be the stack line leaking into the exit code. An
# absolute expectation here would have been a test of this suite's entries.json instead.
check "🔴 HALF and whole-up give the same rc (kernel up, locks free)" \
      "$(rc_of "$(FX_KERNEL_UP=1 FX_BMV2=10 FX_MN=14 orphans_with "$LOCKS_FREE")")" \
      "$(rc_of "$(FX_KERNEL_UP=1 FX_BMV2=0  FX_MN=0  orphans_with "$LOCKS_FREE")")"
check "🔴 and with a HELD lock, which is the rc 4 case" \
      "$(rc_of "$(FX_KERNEL_UP=1 FX_BMV2=10 FX_MN=14 orphans_with "$LOCK_HELD")")" \
      "$(rc_of "$(FX_KERNEL_UP=1 FX_BMV2=0  FX_MN=0  orphans_with "$LOCK_HELD")")"
check "🔴 a HALF stack with a held lock is still 4, not a new code" "4" \
      "$(rc_of "$(FX_KERNEL_UP=1 FX_BMV2=0 FX_MN=0 orphans_with "$LOCK_HELD")")"
# And the kernel-down pair, where the residue half answers 5 on its own account.
check "🔴 HALF and whole-down give the same rc (kernel down)" \
      "$(rc_of "$(FX_KERNEL_UP=0 FX_BMV2=10 FX_MN=14 orphans_with "$LOCKS_FREE")")" \
      "$(rc_of "$(FX_KERNEL_UP=0 FX_BMV2=0  FX_MN=0  orphans_with "$LOCKS_FREE")")"

# A count that cannot be read is 0 rather than a word inside an arithmetic test -- ps can fail.
OUT="$(FX_KERNEL_UP=1 orphans_with "$LOCKS_FREE" 'bmv2_count() { echo "cannot tell"; }')"
has   "an unreadable bmv2 count does not break the line" "bmv2=0" "$OUT"

# --- done ---------------------------------------------------------------------------------
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
