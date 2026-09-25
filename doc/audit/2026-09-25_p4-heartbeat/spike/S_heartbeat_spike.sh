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
# (hb_watch.py), the host sniffer (hb_sniff.py), and this script's own teardown, tc pre-check and
# sniffer watch against stubs -- one input that must pass and one that must fail per verdict --
# and touches nothing else.
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
#   The tc runs through `sudo -n mnexec -a 1 tc` by default (FAULTS_TC overrides it); the route is
#   proven BEFORE the claim by running a harmless `tc qdisc show dev lo` through it, and a refusal
#   is rc 2.
#
# PART=census  (≈ 2-3 min per arm)  for each of 06's thirteen exercises (ARMS="solution skeleton"
#   by default; ONLY=a,b to narrow): build the arm exactly as 06 does (census_prepare.py imports
#   drive_exercise.py), `ndt up p4 --app`, start the heartbeat, sniff EVERY host for up to SNIFF_S
#   seconds (hb_sniff.py via `sudo -n mnexec -a <pid>`: by ethertype AND by payload, so a pipeline
#   that rewrites or wraps the frame is still caught), then read the daemon's own counters
#   (forwarded_to_hosts / forwarded_between_switches / misdelivered).
#   🔴 RULING 4 IS THE STOP CONDITION: a heartbeat frame at ANY host, or the daemon counting one
#   leaving a host-facing port, stops the census right there -- teardown, verdict FAIL naming the
#   exercise, nothing retried, no workaround. The first sniffer that sees one exits at once; the
#   watch loop then stops the heartbeat and tells every other sniffer to stop (a stop file) --
#   not at the end of the window (judge #11, round 2).
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

# faults.sh FIRST: its `say` is then replaced by _common.sh's, the only name the two share.
# From faults.sh this uses netem_attach_point / netem_delete_point / show_qdisc / run_tc /
# revert_link_loss -- the htb-safe netem the fault catalogue already uses, not a second copy.
# Sourced before --self-test too, because the self-test drives this script's teardown through
# _common.sh's own finish().
#
# 🔴 THE tc ROUTE IS mnexec BY DEFAULT (judge R2-1, round 3). faults.sh's own default is `sudo -n tc`,
# whose grant this repo documents three different ways and which `sudo -n -l` cannot settle on this
# machine (tools/test_workflow/sudo_surface.sh:37-49: a password-requiring ALL rule makes `-l` say
# yes to everything). `sudo -n mnexec -a 1 tc` runs tc as uid 0 in pid 1's network namespace -- the
# root netns, where the switch veths are -- under the mnexec grant `require_root` already checks and
# ping_loss already uses with arbitrary arguments; faults.sh names it as its own escape. Set before
# faults.sh is sourced, so faults.sh's `${FAULTS_TC:-sudo -n tc}` keeps it; an explicit FAULTS_TC in
# the environment still wins.
FAULTS_TC_FROM_ENV="${FAULTS_TC:+yes}"
: "${FAULTS_TC:=sudo -n mnexec -a 1 tc}"
# shellcheck source=/dev/null
source "$LIVE_P1/../../../../tools/test_workflow/faults.sh"
# shellcheck source=/dev/null
source "$LIVE_P1/_common.sh"
set -euo pipefail

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
STEP="S_heartbeat"
HB_STARTED=0
INJECTED_IFACES=()
#: Whether THIS run believes a fabric of its own is up. Set when `ndt up` is attempted, cleared
#: when this run's own `ndt down` answers 0 or 3. Read by spike_ndt at teardown.
FABRIC_UP=0
#: The real ndt. spike_finish points $NDT at spike_ndt for finish(); everything else uses this.
REAL_NDT="$NDT"
WATCH_HIT=""

# --- the proxy's constants, imported, never copied ----------------------------------------------
consts() {
    env -u NDTWIN_P4_BEACON_S "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1])
from proxy_agent import topology_manager as t
print(t.LLDP_BEACON_INTERVAL_S, t.LINK_BEACON_TIMEOUT_S, t.LINK_WATCHDOG_INTERVAL_S)' "$REPO/p4_proxy"
}

# spike_ndt <ndt args...> -- what finish() runs as "$NDT".
#
# 🔴 JUDGE #1, ROUND 2. finish() takes the fabric down once more, and this run has usually done
# that already (after the detection part, after every census arm). `ndt down` then answers rc 3,
# "nothing was up -- this command measured nothing" (Adam, 09-12), and finish() reads any non-zero
# as a failed teardown: a clean run ended `FAIL ... 'ndt down' exited 3`. A 3 from `down` is
# passed as 0 ONLY when this run's own bookkeeping says its fabric is already down; every other
# rc, and a 3 while the spike believes something is up, goes through untouched -- a real surprise
# still fails the run. Every other subcommand (release) is the real ndt, unchanged.
spike_ndt() {
    local rc
    "$REAL_NDT" "$@" && rc=0 || rc=$?
    if [[ "${1:-}" == down ]] && (( rc == 3 && FABRIC_UP == 0 )); then
        echo "spike: 'ndt down' answered 3 (nothing was up) -- expected: this run had already taken its own fabric down"
        return 0
    fi
    return "$rc"
}

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
    NDT=spike_ndt
    ( exit "$rc" )
    finish
}

# precheck_tc <report> -- 0 when the tc route this run uses actually RUNS, without a password.
#
# 🔴 BY RUNNING, NOT BY ASKING (judge R2-1, round 3). Round 2 asked `sudo -n -l`, which on this
# machine answers 0 for anything (tools/test_workflow/sudo_surface.sh:37-49) -- no discriminating
# power. What discriminates is sudo_surface.sh's own rule: run a harmless command of the same shape
# and read the rc; the message only explains. `tc qdisc show dev lo` reads, touches nothing, and
# cannot fail for a missing device, so a non-zero rc is the route refusing. Done BEFORE the claim:
# finding out at the first cut would spend a claim, a fabric and a heartbeat on nothing.
# For the default mnexec route one successful run proves the grant covers the cut too (mnexec's
# grant does not restrict its arguments -- INFERRED from ping_loss's use; not read from sudoers).
# For a plain `sudo -n tc` override it proves only `show`; the report says so.
precheck_tc() {
    local out="$1" ok=0 err
    {
        echo "FAULTS_TC=$FAULTS_TC"
        if err="$(run_tc qdisc show dev lo 2>&1 >/dev/null)"; then
            echo "ran       $FAULTS_TC qdisc show dev lo  (rc 0)"
        else
            echo "REFUSED   $FAULTS_TC qdisc show dev lo  (${err:-no message})"
            ok=1
        fi
        if [[ "$FAULTS_TC" != "sudo -n mnexec -a 1 tc" ]]; then
            echo "note      '$FAULTS_TC' is not the default route: 'show' running proves only 'show';"
            echo "          whether 'add ... netem' is granted too is found at the first cut"
        fi
    } > "$out"
    return "$ok"
}

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

# nd_up <package> <out> / nd_down <out> -- the real ndt, and FABRIC_UP kept honest.
nd_up() {
    local rc
    FABRIC_UP=1
    set +e; "$REAL_NDT" up p4 --app "$1" > "$2" 2>&1; rc=$?; set -e
    return "$rc"
}
nd_down() {
    local rc
    set +e; "$REAL_NDT" down > "$1" 2>&1; rc=$?; set -e
    (( rc == 0 || rc == 3 )) && FABRIC_UP=0
    return "$rc"
}

sp_hb_start() {   # sp_hb_start <out> -- the helper's rc
    local rc
    set +e
    sudo -n "$LAB_HELPER" heartbeat start > "$1" 2>&1
    rc=$?
    set -e
    (( rc == 0 )) && HB_STARTED=1
    return "$rc"
}
sp_hb_stop() {
    sudo -n "$LAB_HELPER" heartbeat stop > "$1" 2>&1 || true
    HB_STARTED=0
}

# child_running <pid> -- a live, unreaped, non-zombie process.
child_running() {
    local st
    st="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" || st=""
    [[ -n "$st" && "$st" != Z && "$st" != X ]]
}

# watch_hit <dir> <stop-file> -- read first-hit once; on a hit: the stop file (every sniffer checks
# it twice a second), the report snapshot, and the heartbeat stopped. rc 0 on a hit.
watch_hit() {
    WATCH_HIT="$(/usr/bin/python3 -I "$WATCH" first-hit "$1" 2>/dev/null)" || WATCH_HIT=""
    [[ -n "$WATCH_HIT" ]] || return 1
    : > "$2"
    cp "$HB_REPORT" "$1/30_report.json" 2>/dev/null || true
    sp_hb_stop "$1/31_hb_stop.txt"
    return 0
}

# watch_sniffers <dir> <stop-file> <cap-seconds> <pid>... -- WATCH_HIT is the first host that saw
# a heartbeat frame, or empty; on the first hit everything stops now, not at the end of the window.
# Called directly, never in $( ): sp_hb_stop's HB_STARTED=0 has to reach this shell.
watch_sniffers() {
    local dir="$1" stopf="$2" cap="$3" p running end
    shift 3
    end=$(( $(date +%s) + cap ))
    WATCH_HIT=""
    while :; do
        watch_hit "$dir" "$stopf" && return 0
        running=0
        for p in "$@"; do child_running "$p" && running=1; done
        # R2-2, round 3: every sniffer has exited -- and the last one may have written its hit
        # AFTER the read above. Read once more before calling the window clean.
        if (( ! running )); then watch_hit "$dir" "$stopf"; return 0; fi
        if (( $(date +%s) >= end )); then : > "$stopf"; watch_hit "$dir" "$stopf"; return 0; fi
        sleep 0.2
    done
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
    local prep pkg t0a t0 t1 down up v i up_rc hs d
    prep="$(prepare basic solution)"
    [[ "$prep" == OK* ]] || { fail "detect: could not build basic/solution: $prep"; return; }
    pkg="${prep#OK }"
    say "ndt up p4 --app $pkg"
    nd_up "$pkg" "$RUN/10_up_basic.txt" && up_rc=0 || up_rc=$?
    note "rc=$up_rc"; tail -4 "$RUN/10_up_basic.txt" | sed 's/^/     /'
    (( up_rc == 0 )) || { fail "detect: 'ndt up p4 --app' exited $up_rc"; return; }
    say "heartbeat start"
    sp_hb_start "$RUN/11_hb_start.txt" && hs=0 || hs=$?
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
    sp_hb_stop "$RUN/25_hb_stop.txt"
    nd_down "$RUN/26_down.txt" && d=0 || d=$?
    (( d == 0 )) || fail "'ndt down' after the detection part exited $d"
}

# --- PART census -----------------------------------------------------------------------------------
census() {
    local ex which prep pkg rc hs session h pid v dir stopf
    printf 'exercise\tarm\tbuilt\theartbeat\tverdict\n' > "$RUN/40_census.tsv"
    for ex in $EXERCISES; do
      for which in $ARMS; do
        say "census $ex/$which"
        dir="$RUN/census_${ex}_${which}"; mkdir -p "$dir"
        prep="$(prepare "$ex" "$which")"
        if [[ "$prep" != OK* ]]; then
            printf '%s\t%s\t%s\t-\t-\n' "$ex" "$which" "$prep" >> "$RUN/40_census.tsv"
            note "not built: $prep"
            [[ "$prep" == NOT-BUILT* ]] || fail "census $ex/$which could not be prepared: $prep"
            continue
        fi
        pkg="${prep#OK }"
        nd_up "$pkg" "$dir/10_up.txt" && rc=0 || rc=$?
        if (( rc != 0 )); then
            printf '%s\t%s\tup rc=%s\t-\t-\n' "$ex" "$which" "$rc" >> "$RUN/40_census.tsv"
            fail "census $ex/$which: 'ndt up p4 --app' exited $rc"
            nd_down "$dir/90_down.txt" || true
            continue
        fi
        sp_hb_start "$dir/11_hb_start.txt" && hs=0 || hs=$?
        if (( hs == 3 )); then
            printf '%s\t%s\tyes\tno link (rc 3)\tno frame sent\n' "$ex" "$which" >> "$RUN/40_census.tsv"
            note "no switch-to-switch link: no heartbeat frame enters this fabric"
            nd_down "$dir/90_down.txt" || fail "census $ex/$which: 'ndt down' failed"
            continue
        elif (( hs != 0 )); then
            printf '%s\t%s\tyes\tstart rc=%s\t-\n' "$ex" "$which" "$hs" >> "$RUN/40_census.tsv"
            fail "census $ex/$which: heartbeat start answered $hs"
            nd_down "$dir/90_down.txt" || true
            continue
        fi
        session="$(/usr/bin/python3 -I "$WATCH" session "$HB_REPORT")"
        stopf="$dir/stop"; rm -f "$stopf"
        # every host, at once, for up to SNIFF_S; each sniffer exits on its first heartbeat frame
        local -a pids=()
        while read -r h _ip; do
            pid="$( set +e; source "$REAL_NDT" >/dev/null 2>&1; host_pid "$h" )" || pid=""
            if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
                printf '{"host": "%s", "error": "no namespace"}\n' "$h" > "$dir/sniff_$h.json"; continue
            fi
            ( sudo -n mnexec -a "$pid" /usr/bin/timeout "$(( SNIFF_S + 10 ))" /usr/bin/python3 -I "$SNIFF" "$h" "$SNIFF_S" "$session" "$stopf" \
                > "$dir/sniff_$h.json" 2> "$dir/sniff_$h.err" \
              || printf '{"host": "%s", "error": "sniffer exited %s"}\n' "$h" "$?" > "$dir/sniff_$h.json" ) &
            pids+=("$!")
        done < <(model_hosts "$pkg")
        watch_sniffers "$dir" "$stopf" "$(( SNIFF_S + 15 ))" "${pids[@]}"
        [[ -z "$WATCH_HIT" ]] || note "a heartbeat frame reached $WATCH_HIT -- heartbeat stopped at once, every sniffer told to stop"
        for pid in "${pids[@]}"; do wait "$pid" || true; done
        [[ -s "$dir/30_report.json" ]] || cp "$HB_REPORT" "$dir/30_report.json" 2>/dev/null || true
        v="$(/usr/bin/python3 -I "$WATCH" census-verdict "$dir" "$dir/30_report.json")"
        (( HB_STARTED )) && sp_hb_stop "$dir/31_hb_stop.txt"
        nd_down "$dir/90_down.txt" && rc=0 || rc=$?
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

# --- --self-test -------------------------------------------------------------------------------------
self_test() {
    local rc=0 st_tmp agree missing r d
    /usr/bin/python3 -I "$WATCH" --self-test || rc=1
    echo "hb_sniff --self-test"
    /usr/bin/python3 -I "$SNIFF" --self-test || rc=1
    echo "S_heartbeat_spike --self-test"
    ok()  { echo "  ok    $1"; }
    red() { echo "  🔴    $1"; rc=1; }
    bash -n "${BASH_SOURCE[0]}" || red "this script does not parse"
    missing="$(for f in $BORROWED; do declare -F "$f" >/dev/null || printf '%s ' "$f"; done)"
    [[ -z "$missing" ]] && ok "every borrowed function exists ($(wc -w <<<"$BORROWED"))" \
                        || red "borrowed functions missing: $missing"
    "$PY_SELFTEST" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$PREP" \
        && ok "census_prepare.py parses" || red "census_prepare.py does not parse"

    # The sniffer and the daemon must agree on the frame: encode one with the daemon's OWN code
    # (the helper's embedded program) and ask the sniffer about it, as sent and re-wrapped.
    st_tmp="$(mktemp -d "${TMPDIR:-/tmp}/hb-spike-selftest-XXXXXX")"
    ( set +eu; source "$REPO/tools/test_workflow/ndtwin-lab" >/dev/null 2>&1; hb_program ) \
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
    [[ "$agree" == "(True, 'ethertype') (True, 'payload') (False, '') True" ]] \
        && ok "the sniffer recognises the daemon's own frames, sent and re-wrapped" \
        || red "the sniffer and the daemon disagree about the frame: $agree"

    # 🔴 JUDGE #1, ROUND 2 -- the teardown, walked for real: spike_finish -> _common.sh's finish()
    # with a stub ndt whose `down` answers a chosen rc and whose claim/release answer 0.
    st_finish() {   # st_finish <FABRIC_UP> <down rc> -> "<last line>|<ndt calls>"
        local d out
        d="$(mktemp -d "$st_tmp/finish-XXXXXX")"
        printf '#!/usr/bin/env bash\necho "$1" >> "%s/calls"\ncase "$1" in down) exit %s ;; *) exit 0 ;; esac\n' \
            "$d" "$2" > "$d/ndt"
        chmod +x "$d/ndt"
        out="$( RUN="$d/run"; mkdir -p "$RUN"; CLAIMED=1; VERDICT_RC=0; VERDICT_WHY=""; FABRIC_UP="$1"
                HB_STARTED=0; INJECTED_IFACES=(); NDT="$d/ndt"; REAL_NDT="$d/ndt"; APP_KNOB="$d/none"
                KNOB_ENTRY_COPY=""; TEL_ENTRY_COPY=""; CTRL_PID=""
                ( exit 0 ); spike_finish 2>&1 )"
        printf '%s|%s' "$(tail -1 <<<"$out")" "$(paste -sd, "$d/calls" 2>/dev/null)"
    }
    r="$(st_finish 0 3)"
    [[ "$r" == "PASS S_heartbeat|down,release" ]] \
        && ok "a run whose fabric is already down: finish's 'ndt down' rc 3 does not fail it (PASS, down and release both ran)" \
        || red "a run whose fabric is already down ended: $r"
    r="$(st_finish 1 3)"
    [[ "$r" == "FAIL S_heartbeat -- 'ndt down' exited 3"*"|down,release" ]] \
        && ok "  but a 3 while this run believes its fabric is up still fails it" \
        || red "  a 3 while the fabric should be up did not fail the run: $r"
    r="$(st_finish 1 0)"
    [[ "$r" == "PASS S_heartbeat|down,release" ]] \
        && ok "  and a clean down of a fabric that is up passes (the control)" \
        || red "  a clean down of an up fabric ended: $r"

    # 🔴 R2-1, ROUND 3 -- the tc route is proven by RUNNING something, never by asking sudo.
    # tools/test_workflow/sudo_surface.sh:37-49 measured on this machine that `sudo -n -l <cmd>`
    # answers 0 for anything (a password-requiring ALL rule rides beside the NOPASSWD ones), so the
    # round-2 pre-check built on it had no discriminating power. The default route is mnexec in
    # pid 1's namespaces, which the mnexec grant covers whatever its arguments.
    if [[ "${FAULTS_TC_FROM_ENV:-}" == yes ]]; then
        red "FAULTS_TC came from the environment ('$FAULTS_TC'); run the self-test without it so the DEFAULT is what is checked"
    elif [[ "$FAULTS_TC" == "sudo -n mnexec -a 1 tc" ]]; then
        ok "the spike's default tc route is 'sudo -n mnexec -a 1 tc' (plain 'sudo -n tc' only as an override)"
    else
        red "the spike's default tc route is '$FAULTS_TC', not 'sudo -n mnexec -a 1 tc'"
    fi
    : > "$st_tmp/sudo_calls"
    r="$( sudo() { echo "$*" >> "$st_tmp/sudo_calls"; [[ "$*" == "-n mnexec -a 1 tc qdisc show dev lo" ]]; }
          FAULTS_TC="sudo -n mnexec -a 1 tc"; precheck_tc "$st_tmp/grant1.txt"; echo "$?" )"
    [[ "$r" == 0 && "$(cat "$st_tmp/sudo_calls")" == "-n mnexec -a 1 tc qdisc show dev lo" ]] \
        && ok "the pre-check RUNS a harmless tc through the route (sudo stubbed: one call, 'qdisc show dev lo')" \
        || red "the pre-check did not run tc through the route: rc '$r', sudo was called as: $(paste -sd';' "$st_tmp/sudo_calls")"
    r="$( sudo() { return 1; }; FAULTS_TC="sudo -n mnexec -a 1 tc"; precheck_tc "$st_tmp/grant2.txt"; echo "$?" )"
    [[ "$r" == 1 ]] && grep -q '^REFUSED ' "$st_tmp/grant2.txt" \
        && ok "  a route sudo refuses: the pre-check refuses and says so" \
        || red "  a refused route: the pre-check answered '$r'"
    : > "$st_tmp/sudo_calls"
    r="$( sudo() { echo "$*" >> "$st_tmp/sudo_calls"; return 0; }; FAULTS_TC="sudo -n tc"
          precheck_tc "$st_tmp/grant3.txt"; echo "$?" )"
    [[ "$r" == 0 ]] && ! grep -qE '(^| )-l( |$)' "$st_tmp/sudo_calls" && [[ -s "$st_tmp/sudo_calls" ]] \
        && ok "  the plain 'sudo -n tc' override is also asked by running tc, never by 'sudo -l'" \
        || red "  the 'sudo -n tc' override was asked as: $(paste -sd';' "$st_tmp/sudo_calls") (rc '$r')"
    r="$( FAULTS_TC="false"; precheck_tc "$st_tmp/grant4.txt"; echo "$?" )"
    [[ "$r" == 1 ]] && ok "  a FAULTS_TC that cannot run tc is refused" \
                    || red "  a failing FAULTS_TC answered '$r'"
    # THE ONE REAL sudo CALL of this self-test, harmless (`true` in pid 1's namespaces), made with
    # absolute paths so no function or PATH shim can stand in for it. Its rc is the evidence that
    # the default route's grant exists on the machine the self-test ran on; a refusal is reported
    # as a red line, never passed.
    local probe_out probe_rc
    probe_out="$(/usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true 2>&1)" && probe_rc=0 || probe_rc=$?
    echo "  --    evidence: '/usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true' -> rc $probe_rc${probe_out:+ ($probe_out)}"
    (( probe_rc == 0 )) \
        && ok "the mnexec grant the default route needs is there, without a password (one real call, rc 0)" \
        || red "the mnexec grant is NOT usable without a password here (rc $probe_rc): the spike's default tc route would be refused -- grant mnexec, or pass FAULTS_TC"
    local pl cl
    pl="$(grep -n '^    precheck_tc "\$RUN/00_tc_grant.txt"' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
    cl="$(grep -n '^take_claim ' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
    [[ -n "$pl" && -n "$cl" ]] && (( pl < cl )) \
        && ok "  the pre-check runs before the claim (source read: line $pl < $cl)" \
        || red "  the pre-check is not before the claim (precheck line '${pl:-none}', take_claim line '${cl:-none}')"

    # 🔴 JUDGE #11, ROUND 2 -- the first hit stops everything, not the end of the window. Two stand-in
    # sniffers: one reports a heartbeat frame after 0.3 s; the other would run 20 s unless told to stop.
    d="$(mktemp -d "$st_tmp/watch-XXXXXX")"
    "$PY_SELFTEST" -I -c 'import json,sys,time
time.sleep(0.3); open(sys.argv[1] + "/sniff_hA.json", "w").write(json.dumps({"host": "hA", "frames_hb": 1}))' "$d" &
    local pa=$!
    "$PY_SELFTEST" -I -c 'import json,os,sys,time
end = time.monotonic() + 20
while time.monotonic() < end and not os.path.exists(sys.argv[1] + "/stop"): time.sleep(0.1)
open(sys.argv[1] + "/sniff_hB.json", "w").write(json.dumps({"host": "hB", "frames_hb": 0}))' "$d" &
    local pb=$! t0 t1
    t0="$(date +%s)"
    ( sp_hb_stop() { echo stopped > "$1"; HB_STARTED=0; }
      HB_STARTED=1; watch_sniffers "$d" "$d/stop" 30 "$pa" "$pb"
      printf '%s %s\n' "$WATCH_HIT" "$HB_STARTED" > "$d/result" )
    t1="$(date +%s)"
    wait "$pb" 2>/dev/null; wait "$pa" 2>/dev/null
    [[ "$(cat "$d/result" 2>/dev/null)" == "hA 0" && -e "$d/stop" && "$(cat "$d/31_hb_stop.txt" 2>/dev/null)" == stopped ]] \
        && (( t1 - t0 < 6 )) \
        && ok "the first host to see a heartbeat frame stops the heartbeat and every sniffer at once ($(( t1 - t0 )) s, not 20)" \
        || red "the first hit did not stop everything: result '$(cat "$d/result" 2>/dev/null)', $(( t1 - t0 )) s, stop file $( [[ -e "$d/stop" ]] && echo yes || echo no)"
    d="$(mktemp -d "$st_tmp/watch-XXXXXX")"
    "$PY_SELFTEST" -I -c 'import json,sys
open(sys.argv[1] + "/sniff_hA.json", "w").write(json.dumps({"host": "hA", "frames_hb": 0}))' "$d" &
    pa=$!
    ( sp_hb_stop() { echo stopped > "$1"; }
      watch_sniffers "$d" "$d/stop" 30 "$pa"; printf '%s\n' "${WATCH_HIT:-none}" > "$d/result" )
    wait "$pa" 2>/dev/null
    [[ "$(cat "$d/result")" == none && ! -e "$d/31_hb_stop.txt" ]] \
        && ok "  no host sees one: no hit, and the heartbeat is left for the arm's own stop (the control)" \
        || red "  a clean window was reported as a hit: $(cat "$d/result")"
    # R2-2, ROUND 3: the last sniffer writes its hit and exits BETWEEN the loop's first-hit read
    # and its liveness check. Stood in for deterministically: child_running itself writes the hit
    # and answers "exited", so only a re-read after "all exited" can see it.
    d="$(mktemp -d "$st_tmp/watch-XXXXXX")"
    ( sp_hb_stop() { echo stopped > "$1"; HB_STARTED=0; }
      child_running() { printf '{"host": "hZ", "frames_hb": 1}' > "$d/sniff_hZ.json"; return 1; }
      HB_STARTED=1; watch_sniffers "$d" "$d/stop" 30 99999
      printf '%s %s\n' "${WATCH_HIT:-none}" "$HB_STARTED" > "$d/result" )
    [[ "$(cat "$d/result")" == "hZ 0" && -e "$d/stop" && "$(cat "$d/31_hb_stop.txt" 2>/dev/null)" == stopped ]] \
        && ok "  a hit written as the last sniffer exits is still caught, and the heartbeat stopped" \
        || red "  a hit written as the last sniffer exits was missed: '$(cat "$d/result")'"
    rm -rf "$st_tmp"
    (( rc == 0 )) && echo "SPIKE SELF-TEST PASS" || echo "SPIKE SELF-TEST FAIL"
    return "$rc"
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test && exit 0 || exit 1
fi

# --- the run -----------------------------------------------------------------------------------------
case "$PART" in detect|census|all) ;; *) echo "PART must be detect, census or all" >&2; exit 2 ;; esac
[[ "$CYCLES" =~ ^[1-9][0-9]*$ ]] || { echo "CYCLES must be a positive integer" >&2; exit 2; }
RUN="$SPIKE_DIR/runs/$(date -u '+%Y-%m-%dT%H%M%SZ')_$STEP"
mkdir -p "$RUN" || { echo "could not create $RUN" >&2; exit 2; }
trap spike_finish EXIT INT TERM
printf '== %s\n   repo: %s\n   raw : %s\n   owner: %s\n   part: %s\n' "$STEP" "$REPO" "$RUN" "$NDT_OWNER" "$PART"
[[ -x "$NDT" ]] || die "no ndt at $NDT"
[[ -x "$PY" ]]  || die "no proxy venv interpreter at $PY -- run this from a checkout that has p4_proxy/venv"
[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "refusing: run this as the operator, not under sudo (the lab's grants are what it needs)"
require_root

# 🔴 THE INSTALLED HELPER MUST BE THIS CHECKOUT'S, byte for byte. The old one has no `heartbeat`
# and would answer every call below with a usage line; a different new one would be a spike of a
# program nobody reviewed.
inst="$(sha256sum "$LAB_HELPER" 2>/dev/null | cut -d' ' -f1)" || inst=""
repo_sha="$(sha256sum "$REPO/tools/test_workflow/ndtwin-lab" | cut -d' ' -f1)"
{ echo "installed $LAB_HELPER sha256 ${inst:-absent}"; echo "checkout  tools/test_workflow/ndtwin-lab sha256 $repo_sha"; } > "$RUN/00_helper_sha.txt"
[[ -n "$inst" && "$inst" == "$repo_sha" ]] || die "refusing: $LAB_HELPER (${inst:0:12}) is not this checkout's tools/test_workflow/ndtwin-lab (${repo_sha:0:12}).
       install it first:  sudo install -o root -g root -m 755 $REPO/tools/test_workflow/ndtwin-lab $LAB_HELPER"
grep -q '^    heartbeat) shift; hb_rc=0; heartbeat_main' "$LAB_HELPER" || die "refusing: $LAB_HELPER has no heartbeat verb"
# No heartbeat may be running already -- somebody else's would be measured as ours.
set +e; sudo -n "$LAB_HELPER" heartbeat status > "$RUN/00_heartbeat_status_before.txt" 2>&1; st=$?; set -e
(( st == 3 )) || die "refusing: 'ndtwin-lab heartbeat status' answered $st, not 3 (not running) -- see 00_heartbeat_status_before.txt"
# The tc the detection part runs, asked before anything is claimed or built.
if [[ "$PART" != census ]]; then
    precheck_tc "$RUN/00_tc_grant.txt" || die "refusing: '$FAULTS_TC qdisc show dev lo' did not run without a password -- see 00_tc_grant.txt.
       The default route is 'sudo -n mnexec -a 1 tc' (mnexec as uid 0 in pid 1's namespaces, the
       root netns where the switch veths are). Grant mnexec, or set FAULTS_TC to a route that runs."
fi

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
