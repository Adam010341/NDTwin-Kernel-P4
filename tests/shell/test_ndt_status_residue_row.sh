#!/usr/bin/env bash
#
# Does `ndt status --check` say what is left on the NETWORK, and does it go red on it?
#
# [Co-developed with claude code -- Adam]
#
# KNOWN-ISSUES G-12, measured 2026-09-05 (R6, 1/1, OVS). An app took `graph_lock`, installed a
# rule on s2 (pri 96) and was killed by pid. Both survived, and:
#
#     ndt apps orphans      ok  no untracked app processes        rc 0
#     ndt status --check                                          rc 0
#
# `--check` compares the running lab against the last `ndt up` target -- data plane, host
# count, kernel graph, topology sha256. None of those is a flow table, so it was right and
# silent. W16-2, Adam's decision 09-06 (grill §4D round 7, AGAINST the recommendation that
# --check be left alone): it prints a residue row and residue makes it red.
#
# 🔴 FOUR DIRECTIONS, because "make --check see residue" has three wrong answers that look
# like fixes:
#   * always red -- group 2's clean fabric must stay rc 0, or the gate is ignored inside a day;
#   * red on "could not check" -- group 4: on P4 NO rule can ever be dated (W16-3), so folding
#     that into the verdict makes --check permanently red on every healthy P4 fabric, and
#     doc/2026-08-17_testing-manual.md:279 makes rc 0 the P4 acceptance criterion;
#   * silent on "could not check" -- group 4 again, from the other side: it must SAY it did not
#     check, in words, and must never be printed as clean;
#   * scanning on plain `ndt status` too -- group 5: the scan is a flow-table GET plus three
#     acquire POSTs, and plain `status` is read dozens of times an hour.
#
# Offline: REPO is redirected into a temp dir, the kernel is a stub, no port is opened, no
# acquire is POSTed and no flow table is fetched.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_ndt_status_residue_row.sh
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

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-residue-row-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/setting" "$FIX/p4_proxy/mininet"
printf '4\n' > "$FIX/p4_proxy/mininet/host_count_override"

# --- fixtures: a healthy 4-host OVS fabric that --check has every reason to pass -----------
mk_topo() {   # <file> <hosts> <edges>
    python3 - "$FIX/setting/$1" "$2" "$3" <<'PY'
import json, sys
p, h, e = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
nodes = [{"vertex_type": 0, "id": i} for i in range(10)]
nodes += [{"vertex_type": 1, "id": 1000 + i} for i in range(h)]
json.dump({"nodes": nodes, "edges": [{"src": i % 10, "dst": (i + 1) % 10} for i in range(e)]},
          open(p, "w"))
PY
}
mk_topo StaticNetworkTopologyOVS_10Switches_4Hosts.json 4 40
mk_topo StaticNetworkTopologyP4_10Switches_4Hosts.json  4 40
OVS4="setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json"
P4_4="setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"

python3 - "$FIX/graph.json" <<'PY'
import json, sys
sw = [{"vertex_type": 0, "is_up": True, "is_enabled": True, "admin_disabled": False, "id": i}
      for i in range(10)]
sw += [{"vertex_type": 1, "id": 1000 + i} for i in range(4)]
ed = [{"is_up": True, "admin_disabled": False, "src": i % 10, "dst": (i + 1) % 10}
      for i in range(40)]
json.dump({"nodes": sw, "edges": ed}, open(sys.argv[1], "w"))
PY

# The `ndt up` record --check compares against. `record p4` is what makes group 4's P4 cases
# a HEALTHY P4 fabric rather than an OVS record with a bmv2 plane under it: without it the
# dataplane row mismatches and the rc 0 those cases assert would be about the wrong thing.
record() {   # <plane>
    local topo="$OVS4"; [[ "$1" == p4 ]] && topo="$P4_4"
    printf 'plane=%s\nhosts=4\ntopology=%s\ntopology_sha256=%s\nmodel_hosts=4\nmodel_edges=40\nat=%s\nby=fixture\nbuilder=up_%s\n' \
        "$1" "$topo" "$(sha256sum "$FIX/$topo" | cut -d' ' -f1)" "$(date +%s)" "$1" \
        > "$FIX/.test_run/up.target"
}
record ovs

# The flow table. `age` dates the app's own pri-96 rule; the rest is the fabric's baseline.
mk_entries() {   # <app-rule-age-seconds>
    python3 - "$FIX/entries.json" "$1" <<'PY'
import json, sys
p, age = sys.argv[1], int(sys.argv[2])
def row(dur, pri, acts):
    return {"actions": acts, "byte_count": 0, "cookie": 0, "duration_sec": dur,
            "duration_nsec": 91000000, "flags": 0, "hard_timeout": 0, "idle_timeout": 0,
            "length": 96, "match": {"in_port": 1}, "packet_count": 0,
            "priority": pri, "table_id": 0}
json.dump([{"dpid": 1, "flows": {"1": [row(9000, 10, ["OUTPUT:1"])]}},
           {"dpid": 2, "flows": {"2": [row(age, 96, ["OUTPUT:2"])]}}], open(p, "w"))
PY
}
mk_entries 9000

# [Co-developed with claude code -- Adam]
# 🔴 RESIDUE-1 (2026-09-12, Adam's ruling 12:3x). The window a dead pid's pidfile opens is now
# CLOSED at the app's own log mtime, so the fixture leaves that log behind -- and windows with
# te rather than energy, because energy is the one app of the five with no log channel on any
# machine (`ndtwin-lab energy-start` is a bare tmux session, no `script -f`). An energy pidfile
# therefore seals to a ZERO-LENGTH window, which is the right answer for it and the wrong
# fixture for a suite about a rule that IS inside a window. Same move group 5L of
# tests/shell/test_apps_residue.sh made on 2026-09-07, for the same reason.
started_ago() { : > "$FIX/.test_run/pids/app_$1.pid"
                touch -d "@$(( $(date +%s) - $2 ))" "$FIX/.test_run/pids/app_$1.pid"
                printf 'the app wrote this\n' > "$FIX/.test_run/logs/app_$1.log"; }
started_ago te 600

# --- the seam ------------------------------------------------------------------------------
# Everything that would describe THIS machine is answered by an FX_ variable; check_up_target,
# the residue scan, residue_verdict and status_residue_row itself all run for real.
STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
MANIFEST="$REPO/manifest.json"
claim_line() { echo none; }
git_lines() { :; }
in_flight() { :; }
foreign_claim() { :; }
sample_rate() { echo 256; }
rate_source() { echo "fixture"; }
bmv2_binary() { echo "fixture-bmv2"; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
bmv2_count() { echo 0; }
mn_count() { echo 14; }
fabric_host_count() { echo 4; }
ovs_bridge_count() { echo 10; }
ovs_daemon_running() { return 0; }
topo_session() { return 0; }
live_dataplane_kind() { echo "${FX_PLANE:-ovs}"; }
# 3-51: where the lab helper starts sim, and therefore where sim'"'"'s log is looked for. Stubbed
# for the same reason as the rest of this seam: the real one resolves the MAIN CHECKOUT, whose
# .test_run/logs/app_sim.log is a real file left by a real run, and group 2'"'"'s "a clean fabric
# is still GREEN" must not depend on what is in another tree. The rule itself is group 1 of
# tests/shell/test_ndt_helper_apps_window.sh.
lab_kernel_dir() { echo "$REPO"; }
port_open() { case "$1" in 8000) [[ "${FX_KERNEL_UP:-1}" == 1 ]] ;; *) return 1 ;; esac; }
http_get_graph() { cat "$REPO/graph.json"; }
http_get_flow_entries() { [[ "${FX_NO_TABLE:-0}" == 1 ]] || cat "$REPO/entries.json"; }
lock_probe() { case "${FX_LOCKS:-free}" in
                 held) [[ "$1" == graph_lock ]] && echo "held 4 30" || echo free ;;
                 blind) echo "unknown :8000 gave no answer" ;;
                 *) echo free ;; esac; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
app_probe() { APP_STATE=not-running; }
lab_version_verdict() { echo "same fixture-sha fixture-sha"; }
'
run_status() {   # [--check] -> the whole report plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
cmd_status ${1:-}
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# ==========================================================================================
section "1. G-12: a rule left inside an app's window makes --check RED"
mk_entries 300
OUT="$(run_status --check)"
has   "🔴 --check prints a residue row"                  "residue" "$OUT"
has   "  naming what it found"                           "1 rule(s) inside an app window" "$OUT"
has   "  and where the detail is"                        "ndt apps orphans" "$OUT"
has   "🔴 it is listed as a problem"                     "- the network carries app residue" "$OUT"
check "🔴 and --check exits 1 (it exited 0 over this on 09-05)" "1" "$(rc_of "$OUT")"
hasnt "  and does not also say ok"                       "check: ok" "$OUT"

section "2. 🔴 the other direction: a clean fabric is still GREEN"
# Without this the whole change is satisfied by a --check that is always red, and a gate that
# is always red is a gate nobody reads -- which is how G-12's own green checks stopped being
# read from the other end.
mk_entries 9000
OUT="$(run_status --check)"
has   "it says the network was asked and is clean"       "residue        none" "$OUT"
has   "  and that it asked rather than assumed"          "asked, not assumed" "$OUT"
check "🔴 rc 0"                                          "0" "$(rc_of "$OUT")"
has   "  check: ok"                                      "check: ok" "$OUT"

section "3. a held lock is residue too, with no rule anywhere"
OUT="$(FX_LOCKS=held run_status --check)"
has   "the lock is counted"                              "1 lock(s) HELD" "$OUT"
check "🔴 and --check is red on it"                      "1" "$(rc_of "$OUT")"

section "4. 🔴 'could not check' is said in words -- and is NOT the verdict"
# W16-3, measured 2026-09-07: on the P4 plane every flow entry reports duration 0/0, so no
# rule can be dated, ever. That is a permanent property of the proxy, not a state of the lab.
record p4
OUT="$(FX_PLANE=p4 run_status --check)"
has   "it says NOT CHECKED"                              "residue        NOT CHECKED" "$OUT"
has   "🔴 and says what that does not mean"              "this is not 'the network is clean'" "$OUT"
has   "  naming P4 as the reason it is permanent"        "on P4 that is permanent" "$OUT"
has   "🔴 and says the locks WERE checked"               "the locks WERE checked" "$OUT"
check "🔴 but a healthy P4 fabric still passes: rc 0"    "0" "$(rc_of "$OUT")"
hasnt "  and it is not listed as a problem"              "- the network carries app residue" "$OUT"

# ...and a held lock on P4 IS still residue: locks are kernel state, not flow stats.
OUT="$(FX_PLANE=p4 FX_LOCKS=held run_status --check)"
check "🔴 a held lock on P4 is still rc 1"               "1" "$(rc_of "$OUT")"
record ovs

OUT="$(FX_KERNEL_UP=0 run_status --check)"
has   "a kernel that is down says NOT CHECKED"           "NOT CHECKED -- :8000 is closed" "$OUT"
has   "🔴 and not 'clean'"                               "this is not 'the network is clean'" "$OUT"

OUT="$(FX_NO_TABLE=1 run_status --check)"
has   "an unreadable flow table says NOT CHECKED"        "residue        NOT CHECKED" "$OUT"
hasnt "🔴 and never 'none'"                              "residue        none" "$OUT"

section "5. 🔴 plain 'ndt status' does not pay for the scan"
mk_entries 300
OUT="$(run_status)"
hasnt "no residue row without --check"                   "residue" "$OUT"
check "  and plain status still exits 0"                 "0" "$(rc_of "$OUT")"
# 🔴 The seam that proves it is the SCAN that is skipped and not merely the printing. The
# marker is a FILE, not a message: status_residue_row runs residue_report with its output
# redirected to /dev/null, so anything the stub writes to stdout or stderr is swallowed and a
# case built on that would pass whether or not the fetch happened.
fetch_marker() {   # <status args...> -> "yes"/"no", did anything read the flow table?
    rm -f "$FIX/fetched.marker"
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
http_get_flow_entries() { : > \"\$REPO/fetched.marker\"; cat \"\$REPO/entries.json\"; }
cmd_status ${1:-}" >/dev/null 2>&1
    [[ -e "$FIX/fetched.marker" ]] && echo yes || echo no
}
check "🔴 and the flow table is not fetched at all"      "no"  "$(fetch_marker)"
check "  while --check does fetch it (the marker works)" "yes" "$(fetch_marker --check)"

# --- done ---------------------------------------------------------------------------------
# 🔴 `echo`, not printf: tests/shell/test_l1_shell_scoring.sh group C reads the LAST
# `echo "..."` out of every suite's SOURCE and requires it to render a count the scorer in
# tools/ can read. A summary printed with printf is invisible to it.
echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
