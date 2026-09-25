#!/usr/bin/env bash
#
# Segment S of TICKET-P4-heartbeat -- the spike: how fast does the veth heartbeat see a cut link,
# and what do the 13 tutorials pipelines do with its frames?
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WRITTEN AND SELF-TESTED OFFLINE; ITS AUTHOR NEVER RAN IT AGAINST A LAB. It needs the NEW
# /usr/local/sbin/ndtwin-lab (the one with `heartbeat`), which is not installed when this is
# written, and it refuses -- rc 2, before any claim -- unless the installed helper is
# byte-identical to this checkout's tools/test_workflow/ndtwin-lab. `--self-test` runs the judge
# (hb_watch.py) and the host sniffer's classifier (hb_sniff.py) against synthetic inputs, one that
# must pass and one that must fail per verdict, and touches nothing else.
#
# PART=detect  (≈ 15 min)  pod-topo `--app basic` (the exercise's own solution pipeline, converted
#   the way 06 converts it). The heartbeat runs; an OUT-OF-BAND `tc netem loss 100%` goes on BOTH
#   ends of the spine cable s1-eth3 <-> s3-eth1 -- the same cable 07's L4 cuts, and NOT through
#   the kernel's inject_link_failure, which knows it cut the link. CYCLES times (default 10):
#     * cut: from the moment tc returned until BOTH directions of that cable are "not heard" by
#       the proxy's own rule (silent > LINK_BEACON_TIMEOUT_S, imported from topology_manager.py);
#     * restore: from the moment tc returned until both directions are heard again;
#     * the other six directions must stay heard throughout (the cut took one cable, not more);
#     * no netem on either end afterwards, and the whole qdisc tree identical to the snapshot.
#   This is REPORT-LEVEL detection: when the proxy COULD call it, reading the report then.
#   Segment W adds at most one watchdog pass (LINK_WATCHDOG_INTERVAL_S) and the kernel's reaction.
#
# PART=census  (≈ 2-3 min per arm)  for each of 06's thirteen exercises (ARMS="solution skeleton"
#   by default; ONLY=a,b to narrow): build the arm exactly as 06 does (census_prepare.py imports
#   drive_exercise.py), `ndt up p4 --app`, start the heartbeat, sniff EVERY host for SNIFF_S
#   seconds (hb_sniff.py via `sudo -n mnexec -a <pid>`: by ethertype AND by payload, so a pipeline
#   that rewrites or wraps the frame is still caught), then read the daemon's own counters
#   (forwarded_to_hosts / forwarded_between_switches / misdelivered).
#   🔴 RULING 4 IS THE STOP CONDITION: a heartbeat frame at ANY host, or the daemon counting one
#   leaving a host-facing port, stops the census right there -- teardown, verdict FAIL naming the
#   exercise, nothing retried, no workaround.
#   p4runtime and flowcache are exercises whose own controller fills the tables; the census does
#   NOT start those controllers, so their pipelines meet the heartbeat with the package's entries
#   only. H5 (segment W) is where 06 runs in full, controllers and all, with the heartbeat on.
#   Single-switch exercises (calc, multicast in 06's packaging) have no switch-to-switch link:
#   `heartbeat start` answers 3 and the row says so -- no frame is sent into them at all.
#   flowcache/skeleton and basic_tunnel/skeleton stop before a fabric exists (their designed red
#   in 06); the row says that too.
#
# Run (from a checkout with p4_proxy/venv, as the operator -- NOT under sudo):
#   NDT_OWNER=<you> PART=all bash doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh
#   NDT_OWNER=<you> PART=detect CYCLES=10 bash .../S_heartbeat_spike.sh
#   NDT_OWNER=<you> PART=census ARMS=solution ONLY=basic,load_balance bash .../S_heartbeat_spike.sh
# Self-test:  bash .../S_heartbeat_spike.sh --self-test
#
# It claims the lab itself (measuring= set for the detection part), snapshots and restores
# p4_proxy/mininet/host_count_override and telemetry_override, stops the heartbeat and removes
# any netem it added BEFORE `ndt down`, and releases last -- live-p1/_common.sh's finish(), with
# the heartbeat and netem steps in front of it.
# Raw goes to spike/runs/<UTC>_S_heartbeat/; the last line is PASS, FAIL <why> or REFUSED.
# Exit: 0 PASS, 1 FAIL (incl. a ruling-4 STOP), 2 refused before anything was started.
set -euo pipefail
SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_P1="$(cd "$SPIKE_DIR/../../2026-09-04_p4-tutorial-exercise-prep/live-p1" && pwd)"
WATCH="$SPIKE_DIR/hb_watch.py"
SNIFF="$SPIKE_DIR/hb_sniff.py"
PREP="$SPIKE_DIR/census_prepare.py"
PY_SELFTEST=/usr/bin/python3

# judge <verdict line> <what> -- OK is a note, anything else a fail (07_roles_basic.sh's shape).
judge() {
    case "$1" in
        OK*) note "$2: ${1#OK }" ;;
        *)   fail "$2: ${1#BAD }" ;;
    esac
}

#: Every function this script takes from the two files it sources. The self-test asks for each by
#: name, because a missing one (07's `judge` is not in _common.sh) is found only on a lab otherwise.
BORROWED="netem_attach_point netem_delete_point show_qdisc run_tc revert_link_loss say note bad fail
die require_root require_free_lab snapshot_knob snapshot_telemetry_knob take_claim finish model_hosts"

if [[ "${1:-}" == "--self-test" ]]; then
    rc=0
    /usr/bin/python3 -I "$WATCH" --self-test || rc=1
    echo "hb_sniff --self-test"
    /usr/bin/python3 -I "$SNIFF" --self-test || rc=1
    bash -n "${BASH_SOURCE[0]}" || { echo "  🔴 this script does not parse"; rc=1; }
    missing="$( set +eu
                source "$LIVE_P1/../../../../tools/test_workflow/faults.sh" >/dev/null 2>&1
                source "$LIVE_P1/_common.sh" >/dev/null 2>&1
                for f in $BORROWED; do declare -F "$f" >/dev/null || printf '%s ' "$f"; done )"
    if [[ -z "$missing" ]]; then echo "  ok    every borrowed function exists ($(wc -w <<<"$BORROWED"))"
    else echo "  🔴    borrowed functions missing: $missing"; rc=1; fi
    "$PY_SELFTEST" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$PREP" \
        && echo "  ok    census_prepare.py parses" || { echo "  🔴    census_prepare.py does not parse"; rc=1; }
    # The sniffer and the daemon must agree on the frame: encode one with the daemon's OWN code
    # (the helper's embedded program) and ask the sniffer about it, as sent and re-wrapped.
    st_tmp="$(mktemp -d "${TMPDIR:-/tmp}/hb-spike-selftest-XXXXXX")"
    ( set +eu; source "$LIVE_P1/../../../../tools/test_workflow/ndtwin-lab" >/dev/null 2>&1; hb_program ) \
        > "$st_tmp/daemon.py" 2>/dev/null
    agree="$("$PY_SELFTEST" -I - "$st_tmp/daemon.py" "$SNIFF" <<'PYAGREE' 2>&1
import importlib.util, sys
sys.dont_write_bytecode = True
def load(name, path):
    s = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m); return m
d, sn = load("d", sys.argv[1]), load("sn", sys.argv[2])
P = d.Port("s1", 1, 3, "s1-eth3"); Q = d.Port("s3", 3, 1, "s3-eth1")
sess = bytes(range(8))
f = d.encode(d.Direction(0, P, Q), sess, 7, b"\x02\x00\x00\x00\x00\x01")
wrapped = f[:12] + b"\x12\x12" + b"\x08\x00\x00\x02" + f[14:]
print(sn.classify(f, sess), sn.classify(wrapped, sess), sn.classify(wrapped, bytes(8)),
      sn.ETHERTYPE == d.ETHERTYPE and sn.MAGIC == d.MAGIC)
PYAGREE
)"
    rm -rf "$st_tmp"
    if [[ "$agree" == "(True, 'ethertype') (True, 'payload') (False, '') True" ]]; then
        echo "  ok    the sniffer recognises the daemon's own frames, sent and re-wrapped"
    else
        echo "  🔴    the sniffer and the daemon disagree about the frame: $agree"; rc=1
    fi
    (( rc == 0 )) && echo "SPIKE SELF-TEST PASS" || echo "SPIKE SELF-TEST FAIL"
    exit "$rc"
fi

# faults.sh FIRST: its `say` is then replaced by _common.sh's, the only name the two share.
# From faults.sh this uses netem_attach_point / netem_delete_point / show_qdisc / run_tc /
# revert_link_loss -- the htb-safe netem the fault catalogue already uses, not a second copy.
# shellcheck source=/dev/null
source "$LIVE_P1/../../../../tools/test_workflow/faults.sh"
# shellcheck source=/dev/null
source "$LIVE_P1/_common.sh"
set -euo pipefail

LAB_HELPER=/usr/local/sbin/ndtwin-lab
HB_REPORT=/run/ndtwin-lab/heartbeat.json
PART="${PART:-all}"
CYCLES="${CYCLES:-10}"
ARMS="${ARMS:-solution skeleton}"
ALL_EXERCISES="basic source_routing calc multicast basic_tunnel load_balance qos link_monitor firewall ecn mri p4runtime flowcache"
EXERCISES="${ONLY:-$ALL_EXERCISES}"; EXERCISES="${EXERCISES//,/ }"
: "${CLAIM_MINUTES:=180}"
#: The cable, both ends, and its two directions in hb_watch's notation.
CUT_A=s1-eth3; CUT_B=s3-eth1
CUT_DIRS="1:3>3:1,3:1>1:3"
QDISC_TOOL="$REPO/tools/test_workflow/qdisc_snapshot.sh"
case "$PART" in detect|census|all) ;; *) echo "PART must be detect, census or all" >&2; exit 2 ;; esac
[[ "$CYCLES" =~ ^[1-9][0-9]*$ ]] || { echo "CYCLES must be a positive integer" >&2; exit 2; }

# --- the proxy's constants, imported, never copied ----------------------------------------------
consts() {
    env -u NDTWIN_P4_BEACON_S "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1])
from proxy_agent import topology_manager as t
print(t.LLDP_BEACON_INTERVAL_S, t.LINK_BEACON_TIMEOUT_S, t.LINK_WATCHDOG_INTERVAL_S)' "$REPO/p4_proxy"
}

# --- start: our own run dir, _common's refusals, then ours ----------------------------------------
STEP="S_heartbeat"
RUN="$SPIKE_DIR/runs/$(date -u '+%Y-%m-%dT%H%M%SZ')_$STEP"
mkdir -p "$RUN" || { echo "could not create $RUN" >&2; exit 2; }
HB_STARTED=0
INJECTED_IFACES=()

# spike_finish -- the heartbeat and any netem this run added go FIRST, then _common's finish()
# (ndt down, knobs back, release, verdict), with the exit status it would have seen.
spike_finish() {
    local rc=$?
    set +e
    trap - EXIT INT TERM
    if (( ${#INJECTED_IFACES[@]} > 0 )); then
        note "removing the netem this run added: ${INJECTED_IFACES[*]}"
        revert_link_loss || fail "could NOT remove the netem on ${INJECTED_IFACES[*]} -- remove it by hand before anything else runs"
    fi
    if (( HB_STARTED )); then
        sudo -n "$LAB_HELPER" heartbeat stop 2>&1 | sed 's/^/   /'
    fi
    ( exit "$rc" )
    finish
}
trap spike_finish EXIT INT TERM
printf '== %s\n   repo: %s\n   raw : %s\n   owner: %s\n   part: %s\n' "$STEP" "$REPO" "$RUN" "$NDT_OWNER" "$PART"
[[ -x "$NDT" ]] || die "no ndt at $NDT"
[[ -x "$PY" ]]  || die "no proxy venv interpreter at $PY -- run this from a checkout that has p4_proxy/venv"
[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "refusing: run this as the operator, not under sudo (the lab's grants are what it needs)"
require_root

# 🔴 THE INSTALLED HELPER MUST BE THIS CHECKOUT'S, byte for byte. The old one has no `heartbeat`
# and would answer every call below with a usage line; a different new one would be a spike of a
# program nobody reviewed.
inst="$(sha256sum "$LAB_HELPER" 2>/dev/null | cut -d' ' -f1)"
repo_sha="$(sha256sum "$REPO/tools/test_workflow/ndtwin-lab" | cut -d' ' -f1)"
{ echo "installed $LAB_HELPER sha256 ${inst:-absent}"; echo "checkout  tools/test_workflow/ndtwin-lab sha256 $repo_sha"; } > "$RUN/00_helper_sha.txt"
[[ -n "$inst" && "$inst" == "$repo_sha" ]] || die "refusing: $LAB_HELPER (${inst:0:12}) is not this checkout's tools/test_workflow/ndtwin-lab (${repo_sha:0:12}).
       install it first:  sudo install -o root -g root -m 755 $REPO/tools/test_workflow/ndtwin-lab $LAB_HELPER"
grep -q '^    heartbeat) shift; hb_rc=0; heartbeat_main' "$LAB_HELPER" || die "refusing: $LAB_HELPER has no heartbeat verb"
# No heartbeat may be running already -- somebody else's would be measured as ours.
set +e; sudo -n "$LAB_HELPER" heartbeat status > "$RUN/00_heartbeat_status_before.txt" 2>&1; st=$?; set -e
(( st == 3 )) || die "refusing: 'ndtwin-lab heartbeat status' answered $st, not 3 (not running) -- see 00_heartbeat_status_before.txt"

read -r BEACON_S TIMEOUT_S WATCHDOG_S < <(consts) || die "cannot import the proxy's constants with $PY"
note "proxy constants (imported): LLDP_BEACON_INTERVAL_S=$BEACON_S LINK_BEACON_TIMEOUT_S=$TIMEOUT_S LINK_WATCHDOG_INTERVAL_S=$WATCHDOG_S"
: "${SNIFF_S:=$(( ${BEACON_S%.*} * 3 + 5 ))}"
{
    echo "repo HEAD  $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "helper     $repo_sha  (installed: $inst)"
    for f in "$WATCH" "$SNIFF" "$PREP" "${BASH_SOURCE[0]}"; do echo "spike      $(sha256sum "$f" | cut -c1-16)  ${f#$REPO/}"; done
    echo "constants  beacon=$BEACON_S timeout=$TIMEOUT_S watchdog=$WATCHDOG_S sniff=$SNIFF_S cycles=$CYCLES"
} | tee "$RUN/01_binaries.txt" | sed 's/^/   /'

require_free_lab
snapshot_knob
snapshot_telemetry_knob

# --- helpers ---------------------------------------------------------------------------------------
now() { /usr/bin/python3 -I "$WATCH" now; }

# prepare <exercise> <arm> -- "OK <pkg>" | "NOT-BUILT ..." | "ERROR ..."; the log beside it.
prepare() {
    local pkg="$PKG_ROOT/hbspike-$1-$2" out
    set +e
    out="$("$PY" "$PREP" "$1" "$2" "$pkg" 2>&1)"
    set -e
    printf '%s\n' "$out" > "$RUN/prep_$1_$2.txt"
    printf '%s\n' "$out" | tail -1 | sed 's/^PREP //'
}

hb_start() {   # hb_start <out> -- the helper's rc
    local rc
    set +e
    sudo -n "$LAB_HELPER" heartbeat start > "$1" 2>&1
    rc=$?
    set -e
    (( rc == 0 )) && HB_STARTED=1
    return "$rc"
}
hb_stop() {
    sudo -n "$LAB_HELPER" heartbeat stop > "$1" 2>&1 || true
    HB_STARTED=0
}

# cut / restore -- faults.sh's htb-safe attach point; INJECTED_IFACES is what spike_finish reverts.
cut_link() {
    local dev where
    for dev in "$CUT_A" "$CUT_B"; do
        where="$(netem_attach_point "$dev")" || true
        [[ "$where" != unsafe ]] || { fail "no safe netem attach point on $dev (netem already there, or the tree is unreadable)"; return 1; }
        # shellcheck disable=SC2086
        run_tc qdisc add dev "$dev" $where netem loss 100% || { fail "tc refused to add netem on $dev ($where)"; return 1; }
        INJECTED_IFACES+=("$dev")
    done
}
restore_link() { revert_link_loss; }
no_netem_on_cut() {
    local dev n=0
    for dev in "$CUT_A" "$CUT_B"; do show_qdisc "$dev" | grep -q netem && n=$((n+1)); done
    (( n == 0 ))
}

# --- PART detect -----------------------------------------------------------------------------------
detect() {
    say "detection: prepare basic/solution (pod-topo), the way 06 builds it"
    local prep pkg t0a t0 t1 down up v i
    prep="$(prepare basic solution)"
    [[ "$prep" == OK* ]] || { fail "detect: could not build basic/solution: $prep"; return; }
    pkg="${prep#OK }"
    say "ndt up p4 --app $pkg"
    set +e; "$NDT" up p4 --app "$pkg" > "$RUN/10_up_basic.txt" 2>&1; local up_rc=$?; set -e
    note "rc=$up_rc"; tail -4 "$RUN/10_up_basic.txt" | sed 's/^/     /'
    (( up_rc == 0 )) || { fail "detect: 'ndt up p4 --app' exited $up_rc"; return; }
    say "heartbeat start"
    local hs; hb_start "$RUN/11_hb_start.txt" && hs=0 || hs=$?
    sed 's/^/   /' "$RUN/11_hb_start.txt"
    (( hs == 0 )) || { fail "detect: heartbeat start answered $hs"; return; }
    t0="$(now)"
    v="$(/usr/bin/python3 -I "$WATCH" wait-heard "$HB_REPORT" "$CUT_DIRS" "$t0" "$(( ${BEACON_S%.*} * 3 ))")"
    sleep 1
    cp "$HB_REPORT" "$RUN/12_report_first.json" 2>/dev/null || true
    v="$(/usr/bin/python3 -I "$WATCH" all-heard "$HB_REPORT" "$(python3 -c "print($t0 - 1)")")"
    judge "$v" "every direction heard once the heartbeat is up"
    [[ "$v" == OK* ]] || return
    "$QDISC_TOOL" save "$RUN/13_qdisc.before" > /dev/null
    printf 'cycle\tdown_s\tup_s\tcut_tc_s\tcollateral\tnetem_left\n' > "$RUN/20_cycles.tsv"
    for (( i = 1; i <= CYCLES; i++ )); do
        say "cycle $i/$CYCLES"
        # healthy first: both directions heard within the last period + 1 s
        v="$(/usr/bin/python3 -I "$WATCH" wait-heard "$HB_REPORT" "$CUT_DIRS" "$(python3 -c "print($(now) - ${BEACON_S} - 1)")" "$(( ${BEACON_S%.*} * 3 ))")"
        [[ "$v" != TIMEOUT ]] || { fail "cycle $i: the cable was not heard before the cut"; break; }
        t0a="$(now)"
        cut_link || break
        t0="$(now)"
        down="$(/usr/bin/python3 -I "$WATCH" wait-down "$HB_REPORT" "$CUT_DIRS" "$t0" "$TIMEOUT_S" "$(python3 -c "print($TIMEOUT_S + 2 * $BEACON_S + 10)")")"
        local coll; coll="$(/usr/bin/python3 -I "$WATCH" others-up "$HB_REPORT" "$CUT_DIRS" "$TIMEOUT_S")"
        cp "$HB_REPORT" "$RUN/21_report_cut_$i.json" 2>/dev/null || true
        restore_link || { fail "cycle $i: could not remove the netem"; break; }
        t1="$(now)"
        up="$(/usr/bin/python3 -I "$WATCH" wait-heard "$HB_REPORT" "$CUT_DIRS" "$t1" "$(python3 -c "print(2 * $BEACON_S + 10)")")"
        local left=no; no_netem_on_cut || left=yes
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$down" "$up" "$(python3 -c "print(f'{$t0 - $t0a:.3f}')")" "$coll" "$left" >> "$RUN/20_cycles.tsv"
        note "down after ${down}s, heard again after ${up}s, others: $coll, netem left: $left"
        [[ "$coll" == OK* ]] || fail "cycle $i: $coll"
        [[ "$left" == no ]] || { fail "cycle $i: netem is still on the cable after the restore"; break; }
    done
    /usr/bin/python3 -I "$WATCH" summary "$RUN/20_cycles.tsv" "$TIMEOUT_S" "$BEACON_S" | tee "$RUN/22_summary.txt" | sed 's/^/   /'
    judge "$(tail -1 "$RUN/22_summary.txt")" "detection (report level, the proxy's rule)"
    if "$QDISC_TOOL" diff "$RUN/13_qdisc.before" > "$RUN/23_qdisc.diff" 2>&1; then
        note "qdisc tree identical to the snapshot"
    else
        fail "the qdisc tree differs from before the cycles -- see 23_qdisc.diff"
    fi
    cp "$HB_REPORT" "$RUN/24_report_last.json" 2>/dev/null || true
    hb_stop "$RUN/25_hb_stop.txt"
    set +e; "$NDT" down > "$RUN/26_down.txt" 2>&1; local d=$?; set -e
    (( d == 0 )) || fail "'ndt down' after the detection part exited $d"
}

# --- PART census -----------------------------------------------------------------------------------
census() {
    local ex which prep pkg row rc hs session h pid v
    printf 'exercise\tarm\tbuilt\theartbeat\tverdict\n' > "$RUN/40_census.tsv"
    for ex in $EXERCISES; do
      for which in $ARMS; do
        say "census $ex/$which"
        local dir="$RUN/census_${ex}_${which}"; mkdir -p "$dir"
        prep="$(prepare "$ex" "$which")"
        if [[ "$prep" != OK* ]]; then
            printf '%s\t%s\t%s\t-\t-\n' "$ex" "$which" "$prep" >> "$RUN/40_census.tsv"
            note "not built: $prep"
            [[ "$prep" == NOT-BUILT* ]] || fail "census $ex/$which could not be prepared: $prep"
            continue
        fi
        pkg="${prep#OK }"
        set +e; "$NDT" up p4 --app "$pkg" > "$dir/10_up.txt" 2>&1; rc=$?; set -e
        if (( rc != 0 )); then
            printf '%s\t%s\tup rc=%s\t-\t-\n' "$ex" "$which" "$rc" >> "$RUN/40_census.tsv"
            fail "census $ex/$which: 'ndt up p4 --app' exited $rc"
            "$NDT" down > "$dir/90_down.txt" 2>&1 || true
            continue
        fi
        hb_start "$dir/11_hb_start.txt" && hs=0 || hs=$?
        if (( hs == 3 )); then
            printf '%s\t%s\tyes\tno link (rc 3)\tno frame sent\n' "$ex" "$which" >> "$RUN/40_census.tsv"
            note "no switch-to-switch link: no heartbeat frame enters this fabric"
            "$NDT" down > "$dir/90_down.txt" 2>&1 || fail "census $ex/$which: 'ndt down' failed"
            continue
        elif (( hs != 0 )); then
            printf '%s\t%s\tyes\tstart rc=%s\t-\n' "$ex" "$which" "$hs" >> "$RUN/40_census.tsv"
            fail "census $ex/$which: heartbeat start answered $hs"
            "$NDT" down > "$dir/90_down.txt" 2>&1 || true
            continue
        fi
        session="$(/usr/bin/python3 -I "$WATCH" session "$HB_REPORT")"
        # every host, at once, for SNIFF_S
        local -a pids=()
        while read -r h _ip; do
            pid="$( set +e; source "$NDT" >/dev/null 2>&1; host_pid "$h" )" || pid=""
            if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
                printf '{"host": "%s", "error": "no namespace"}\n' "$h" > "$dir/sniff_$h.json"; continue
            fi
            ( sudo -n mnexec -a "$pid" /usr/bin/timeout "$(( SNIFF_S + 10 ))" /usr/bin/python3 -I "$SNIFF" "$h" "$SNIFF_S" "$session" \
                > "$dir/sniff_$h.json" 2> "$dir/sniff_$h.err" \
              || printf '{"host": "%s", "error": "sniffer exited %s"}\n' "$h" "$?" > "$dir/sniff_$h.json" ) &
            pids+=("$!")
        done < <(model_hosts "$pkg")
        for pid in "${pids[@]}"; do wait "$pid" || true; done
        cp "$HB_REPORT" "$dir/30_report.json" 2>/dev/null || true
        v="$(/usr/bin/python3 -I "$WATCH" census-verdict "$dir" "$dir/30_report.json")"
        hb_stop "$dir/31_hb_stop.txt"
        set +e; "$NDT" down > "$dir/90_down.txt" 2>&1; rc=$?; set -e
        (( rc == 0 )) || fail "census $ex/$which: 'ndt down' exited $rc"
        printf '%s\t%s\tyes\trunning\t%s\n' "$ex" "$which" "$v" >> "$RUN/40_census.tsv"
        note "$v"
        case "$v" in
            OK*)   ;;
            STOP*) fail "RULING 4 STOP at $ex/$which: $v"; return ;;
            *)     fail "census $ex/$which: $v" ;;
        esac
      done
    done
}

# --- the run -----------------------------------------------------------------------------------------
if [[ "$PART" == detect || "$PART" == all ]]; then
    export NDT_MEASURING="heartbeat spike S: detection latency, out-of-band netem on $CUT_A/$CUT_B"
fi
take_claim "heartbeat spike S ($PART): pod-topo basic, netem on $CUT_A/$CUT_B; 13-exercise census"
[[ "$PART" == detect || "$PART" == all ]] && detect
if [[ "$PART" == census || "$PART" == all ]] && (( VERDICT_RC == 0 || ${CENSUS_EVEN_IF_RED:-0} )); then
    census
    column -t -s $'\t' "$RUN/40_census.tsv" | sed 's/^/   /'
fi
say "done -- teardown follows"
