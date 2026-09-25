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
# root netns, where the switch veths are -- under the mnexec grant `require_root` already checks.
# ping_loss runs mnexec with arbitrary arguments (a fact, _common.sh:572-576); that the GRANT therefore
# does not restrict its arguments is (INFERRED) -- sudoers was not read, and `tc qdisc add ... netem`
# is first run at the first cut. faults.sh names this route as its own escape. Set before
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

# wait_session <report> <tries> <pid> -- the session (hex) of daemon <pid> out of its report, polled
# every 0.25 s for up to <tries> reads; rc 1, printing nothing, if there is none by then (judge
# R3-4, round 4: the report is written right after the pidfile `start` waits for, so it can lag by
# an instant, and a bare read under `set -e` would end the run on that instant).
# 🔴 ONLY A REPORT THAT SAYS `running` AND NAMES <pid> (judge R4-1, round-4 verdict): in that same
# instant the file can still hold the previous arm's final "stopped" report, and a daemon killed
# before its clean exit leaves a "running" one with its own pid -- either session is not this arm's.
# <pid> is the one `heartbeat start` answered with (hb_watch.py started-pid).
wait_session() {
    local i s
    for (( i = 0; i < $2; i++ )); do
        s="$(/usr/bin/python3 -I "$WATCH" session "$1" "$3" 2>/dev/null)" || s=""
        [[ -n "$s" ]] && { echo "$s"; return 0; }
        sleep 0.25
    done
    return 1
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
        # 🔴 `|| true`, BOTH TIMES (judge R3-1, round 4): watch_hit answers 1 on no hit, which is
        # the normal clean window; bare, under the run's `set -e`, that 1 ended the whole spike.
        if (( ! running )); then watch_hit "$dir" "$stopf" || true; return 0; fi
        if (( $(date +%s) >= end )); then : > "$stopf"; watch_hit "$dir" "$stopf" || true; return 0; fi
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
    # `return 0`, not a bare `return` (round-4 audit): detect is the last command of the run's
    # `&& detect`, so the status of the failed test would end the run under set -e.
    [[ "$v" == OK* ]] || return 0
    "$QDISC_TOOL" save "$RUN/13_qdisc.before" > /dev/null
    printf 'cycle\tdown_s\tup_s\tcut_tc_s\tcollateral\tnetem_left\n' > "$RUN/20_cycles.tsv"
    for (( i = 1; i <= CYCLES; i++ )); do
        say "cycle $i/$CYCLES"
        # healthy first: both directions heard within the last period + 1 s
        v="$(/usr/bin/python3 -I "$WATCH" wait-heard "$HB_REPORT" "$CUT_DIRS" "$(python3 -c "print($(now) - ${BEACON_S} - 1)")" "$(( ${BEACON_S%.*} * 3 ))")"
        [[ "$v" != TIMEOUT ]] || { fail "cycle $i: the cable was not heard before the cut"; break; }
        t0a="$(now)"
        # 🔴 A CUT REFUSED ON ITS SECOND END (judge R4-2, round-4 verdict) has already put netem on the
        # first. It comes off HERE, while the veth exists: left to the EXIT trap, the revert runs
        # after `nd_down` removed the veth, answers "cannot locate", and adds a misleading failure.
        cut_link || { restore_link || fail "cycle $i: could not remove the netem a half-done cut left on $CUT_A"; break; }
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
    local ex which prep pkg rc hs hb_pid session h pid v dir stopf
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
        # The daemon THIS start started (judge R4-1): its pid from start's own answer, and the
        # session only from a running report of that pid. "already running" names no pid here.
        hb_pid="$(/usr/bin/python3 -I "$WATCH" started-pid "$dir/11_hb_start.txt" 2>/dev/null)" || hb_pid=""
        session=""
        if [[ -n "$hb_pid" ]]; then
            session="$(wait_session "$HB_REPORT" 20 "$hb_pid")" || session=""
        fi
        if [[ -z "$session" ]]; then
            printf '%s\t%s\tyes\tno session in 5 s\t-\n' "$ex" "$which" >> "$RUN/40_census.tsv"
            if [[ -n "$hb_pid" ]]; then
                fail "census $ex/$which: the heartbeat started (pid $hb_pid) but no running report of that pid carries a session after 5 s"
            else
                fail "census $ex/$which: 'heartbeat start' answered 0 without saying it started a daemon -- see 11_hb_start.txt"
            fi
            sp_hb_stop "$dir/31_hb_stop.txt"
            nd_down "$dir/90_down.txt" || true
            continue
        fi
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

# show_census <tsv> -- the census table on the terminal. A DISPLAY: the raw is the tsv, so this never
# decides the run (judge R4-3, round-4 verdict: under pipefail, a machine without `column` --
# bsdextrautils -- turned a finished census into "exited 127 before its own verdict"). Without
# `column`, the rows as they are.
show_census() {
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' "$1" | sed 's/^/   /' || true
    else
        sed 's/^/   /' "$1" || true
    fi
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
    # pid 1's namespaces; that the mnexec grant covers it whatever its arguments is (INFERRED).
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
    # THE REAL sudo PROBE IS OPT-IN (Adam's ruling on judge R3-2, round 4): no --self-test -- a gate,
    # another machine -- fires a sudo unless asked to with SELFTEST_PROBE_SUDO=1. The run itself
    # does not depend on it: precheck_tc runs the route for real before the claim. When asked:
    # one harmless command (`true` in pid 1's namespaces), absolute paths so no function or PATH
    # shim can stand in for it, bounded by `timeout 15`; its rc is printed as evidence and a
    # refusal is a red line, never a pass.
    if [[ "${SELFTEST_PROBE_SUDO:-}" == 1 ]]; then
        local probe_out probe_rc
        probe_out="$(/usr/bin/timeout 15 /usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true 2>&1)" && probe_rc=0 || probe_rc=$?
        echo "  --    evidence: '/usr/bin/timeout 15 /usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true' -> rc $probe_rc${probe_out:+ ($probe_out)}"
        (( probe_rc == 0 )) \
            && ok "the mnexec grant is usable without a password (probe: mnexec -a 1 true, rc 0)" \
            || red "the mnexec grant is NOT usable without a password here (rc $probe_rc): the spike's default tc route would be refused -- grant mnexec, or pass FAULTS_TC"
    else
        echo "  --    the real sudo probe was NOT run (opt-in: SELFTEST_PROBE_SUDO=1) -- neither ok nor red; precheck_tc proves the route at run time, before the claim"
    fi
    local pl cl
    pl="$(grep -n '^    precheck_tc "\$RUN/00_tc_grant.txt"' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
    cl="$(grep -n '^take_claim ' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
    [[ -n "$pl" && -n "$cl" ]] && (( pl < cl )) \
        && ok "  the pre-check runs before the claim (source read: line $pl < $cl)" \
        || red "  the pre-check is not before the claim (precheck line '${pl:-none}', take_claim line '${cl:-none}')"

    # 🔴 JUDGE #11 (round 2), R2-2 (round 3), R3-1 (round 4) -- the sniffer watch, and every scenario
    # of it run in a FRESH `bash -euo pipefail` process. This whole self-test runs inside
    # `self_test && exit 0 || exit 1`, where bash ignores errexit in everything it calls -- so a
    # bare call that returns 1 on a normal path passed here and would abort the real census arm
    # (round 3 did exactly that: a clean window ended the whole spike). The driver carries the
    # functions' own text (`declare -f`), so what runs is this file's code, under the run's options.
    {
        echo 'set -euo pipefail'
        declare -f watch_sniffers watch_hit child_running
        printf 'WATCH=%q\nHB_REPORT=%q\n' "$WATCH" "$st_tmp/no-report.json"
        cat <<'DRIVER'
sp_hb_stop() { echo stopped > "$1"; HB_STARTED=0; }
d="$1"; shift
if [[ "${RACE:-}" == 1 ]]; then
    # The last sniffer writes its hit and exits BETWEEN the loop's first-hit read and its liveness
    # check: child_running itself writes the hit and answers "exited".
    child_running() { printf '{"host": "hZ", "frames_hb": 1}' > "$d/sniff_hZ.json"; return 1; }
fi
HB_STARTED=1; WATCH_HIT=""
watch_sniffers "$d" "$d/stop" 30 "$@"
printf '%s %s\n' "${WATCH_HIT:-none}" "$HB_STARTED" > "$d/result"
DRIVER
    } > "$st_tmp/watch_driver.sh"
    # (1) two stand-in sniffers: one reports a heartbeat frame after 0.3 s; the other would run 20 s
    # unless told to stop.
    d="$(mktemp -d "$st_tmp/watch-XXXXXX")"
    "$PY_SELFTEST" -I -c 'import json,sys,time
time.sleep(0.3); open(sys.argv[1] + "/sniff_hA.json", "w").write(json.dumps({"host": "hA", "frames_hb": 1}))' "$d" &
    local pa=$!
    "$PY_SELFTEST" -I -c 'import json,os,sys,time
end = time.monotonic() + 20
while time.monotonic() < end and not os.path.exists(sys.argv[1] + "/stop"): time.sleep(0.1)
open(sys.argv[1] + "/sniff_hB.json", "w").write(json.dumps({"host": "hB", "frames_hb": 0}))' "$d" &
    local pb=$! t0 t1 wrc
    t0="$(date +%s)"
    bash "$st_tmp/watch_driver.sh" "$d" "$pa" "$pb" > "$d/driver.out" 2>&1 && wrc=0 || wrc=$?
    t1="$(date +%s)"
    wait "$pb" 2>/dev/null; wait "$pa" 2>/dev/null
    [[ "$wrc" == 0 && "$(cat "$d/result" 2>/dev/null)" == "hA 0" && -e "$d/stop" && "$(cat "$d/31_hb_stop.txt" 2>/dev/null)" == stopped ]] \
        && (( t1 - t0 < 6 )) \
        && ok "the first host to see a heartbeat frame stops the heartbeat and every sniffer at once ($(( t1 - t0 )) s, not 20; set -e process)" \
        || red "the first hit did not stop everything: rc $wrc, result '$(cat "$d/result" 2>/dev/null)', $(( t1 - t0 )) s, stop file $( [[ -e "$d/stop" ]] && echo yes || echo no)"
    # (2) the clean arm -- the one every §H.6 prediction expects, and the one round 3 broke.
    d="$(mktemp -d "$st_tmp/watch-XXXXXX")"
    "$PY_SELFTEST" -I -c 'import json,sys
open(sys.argv[1] + "/sniff_hA.json", "w").write(json.dumps({"host": "hA", "frames_hb": 0}))' "$d" &
    pa=$!
    wait "$pa" 2>/dev/null
    bash "$st_tmp/watch_driver.sh" "$d" "$pa" > "$d/driver.out" 2>&1 && wrc=0 || wrc=$?
    [[ "$wrc" == 0 && "$(cat "$d/result" 2>/dev/null)" == "none 1" && ! -e "$d/31_hb_stop.txt" ]] \
        && ok "  a clean window under set -e: no hit, the census goes on, the heartbeat is left for the arm's own stop" \
        || red "  a clean window under set -e: rc $wrc, result '$(cat "$d/result" 2>/dev/null || echo 'none written -- the process died')'"
    # (3) the last sniffer's race (R2-2), under set -e as well.
    d="$(mktemp -d "$st_tmp/watch-XXXXXX")"
    RACE=1 bash "$st_tmp/watch_driver.sh" "$d" 99999 > "$d/driver.out" 2>&1 && wrc=0 || wrc=$?
    [[ "$wrc" == 0 && "$(cat "$d/result" 2>/dev/null)" == "hZ 0" && -e "$d/stop" && "$(cat "$d/31_hb_stop.txt" 2>/dev/null)" == stopped ]] \
        && ok "  a hit written as the last sniffer exits is still caught, and the heartbeat stopped (set -e process)" \
        || red "  the last sniffer's hit under set -e: rc $wrc, result '$(cat "$d/result" 2>/dev/null)'"

    # Found by the round-4 audit of bare calls (judge R3-1 asked for it): the run calls
    # `[[ $PART ... ]] && detect`, and detect is the LAST command of that list, so a non-zero return
    # from it ends the run under set -e -- skipping the census even with CENSUS_EVEN_IF_RED=1.
    # detect records its failures with `fail`; it must itself return 0. Driven with stubs in a fresh
    # `bash -euo pipefail` process: the heartbeat comes up but not every direction is heard.
    #
    # Round 5 (judge R4-2, R4-5 of the round-4 verdict): the same driver now carries everything
    # detect touches PAST its first check -- cut_link, restore_link, no_netem_on_cut and faults.sh's
    # own netem functions (run_tc, show_qdisc, netem_attach_point, netem_delete_point,
    # revert_link_loss, err), run against a fake tc that keeps each veth's qdisc in a state
    # directory -- and spike_finish as the EXIT trap, installed the way the run installs it. Only
    # the lab is stubbed: prepare, nd_up, nd_down (which removes the veths, as `ndt down` does), the
    # heartbeat, the clock, sudo and _common's finish.
    cat > "$st_tmp/fake_watch.py" <<'PYFAKE'
import os, sys
cmd = sys.argv[1]
if os.environ.get("FAKE_WATCH") == "healthy":
    if cmd == "summary":
        with open(sys.argv[2]) as fh:
            rows = [l for l in fh if l.strip() and not l.startswith("cycle")]
        print("OK every cut and every restore detected" if rows else "BAD not every cycle was detected")
    else:
        print({"wait-heard": "1.000", "wait-down": "12.345", "all-heard": "OK 8/8 directions heard"}.get(cmd, "OK"))
else:
    print({"wait-heard": "TIMEOUT", "all-heard": "BAD 0/8 directions heard"}.get(cmd, "OK"))
PYFAKE
    {
        printf '#!%s\n' "$BASH"
        cat <<'FAKETC'
# tc against a state directory: up.<dev> = the veth exists, netem.<dev> = netem at its root,
# refuse.<dev> = `qdisc add` on it is refused. Every call but `show` is logged, in order.
s="$FAKE_TC_STATE"; dev=""
for (( i = 1; i < $#; i++ )); do [[ "${!i}" == dev ]] && { j=$(( i + 1 )); dev="${!j}"; }; done
[[ "$2" == show ]] || echo "tc $*" >> "$s/calls"
[[ -e "$s/up.$dev" ]] || { echo "Cannot find device \"$dev\"" >&2; exit 1; }
case "$2" in
    show) if [[ -e "$s/netem.$dev" ]]; then echo "qdisc netem 8001: root refcnt 2 limit 1000 loss 100%"
          else echo "qdisc noqueue 0: root refcnt 2"; fi ;;
    add)  [[ ! -e "$s/refuse.$dev" ]] || { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
          : > "$s/netem.$dev" ;;
    del)  rm -f "$s/netem.$dev" ;;
esac
FAKETC
    } > "$st_tmp/fake_tc"
    printf '#!%s\necho "qdisc_tool $1" >> "$FAKE_TC_STATE/calls"\n' "$BASH" > "$st_tmp/fake_qdisc_tool"
    chmod +x "$st_tmp/fake_tc" "$st_tmp/fake_qdisc_tool"
    {
        echo 'set -euo pipefail'
        declare -f detect judge note fail bad say err cut_link restore_link no_netem_on_cut \
            run_tc show_qdisc netem_attach_point netem_delete_point revert_link_loss spike_finish
        declare -p R N
        printf 'WATCH=%q\nHB_REPORT=%q\nFAULTS_TC=%q\nLAB_HELPER=%q\n' \
            "$st_tmp/fake_watch.py" "$st_tmp/no-report.json" "$st_tmp/fake_tc" "$st_tmp/no-helper"
        printf 'CUT_A=%q\nCUT_B=%q\nCUT_DIRS=%q\n' "$CUT_A" "$CUT_B" "$CUT_DIRS"
        # R4-5: every global detect reads past its first check is defined here -- QDISC_TOOL too.
        printf 'QDISC_TOOL=%q\n' "$st_tmp/fake_qdisc_tool"
        cat <<'DRIVER'
sudo() { echo "sudo $*" >> "$FAKE_TC_STATE/calls"; }
out="$1"; RUN="$2"; export FAKE_TC_STATE="$3"
mkdir -p "$RUN"
VERDICT_RC=0; VERDICT_WHY=""; BEACON_S=5; TIMEOUT_S=15; CYCLES=1; HB_STARTED=0; INJECTED_IFACES=()
prepare() { echo "OK /nonexistent/pkg"; }
nd_up() { : > "$2"; return 0; }
sp_hb_start() { : > "$1"; HB_STARTED=1; return 0; }
sp_hb_stop() { HB_STARTED=0; }
nd_down() { echo "ndt down" >> "$FAKE_TC_STATE/calls"; rm -f "$FAKE_TC_STATE"/up.*; return 0; }
now() { echo 100.0; }
finish() { echo "finish VERDICT_RC=$VERDICT_RC WHY=$VERDICT_WHY" > "$out.finish"; }
trap spike_finish EXIT INT TERM
[[ "all" == detect || "all" == all ]] && detect
echo "survived VERDICT_RC=$VERDICT_RC" > "$out"
DRIVER
    } > "$st_tmp/detect_driver.sh"
    # st_detect <name> <FAKE_WATCH mode> <device whose `tc qdisc add` is refused, or ""> -- one run
    # of the driver; its files are $st_tmp/detect_<name>.{result,result.finish,out,run/} and
    # $st_tmp/detect_<name>.tc/calls. Sets wrc.
    st_detect() {
        local s="$st_tmp/detect_$1.tc"
        mkdir -p "$s"; : > "$s/calls"; : > "$s/up.$CUT_A"; : > "$s/up.$CUT_B"
        [[ -z "$3" ]] || : > "$s/refuse.$3"
        FAKE_WATCH="$2" bash "$st_tmp/detect_driver.sh" "$st_tmp/detect_$1.result" "$st_tmp/detect_$1.run" "$s" \
            > "$st_tmp/detect_$1.out" 2>&1 && wrc=0 || wrc=$?
    }
    st_died() { grep -m1 -E 'unbound variable|command not found|syntax error' "$1" 2>/dev/null | tr '\n' ' '; }
    st_detect first "" ""
    # 🔴 THE DRIVER MUST GET AS FAR AS THE CHECK IT IS ABOUT. Its first version died of `set -u` on a
    # variable the stub environment lacked (CUT_DIRS) -- red, but for its own reason, not detect's
    # (5c882c9f's red log). So the fake hb_watch must have been asked for `all-heard`, and the
    # verdict must be the one that check records.
    [[ "$wrc" == 0 && "$(cat "$st_tmp/detect_first.result" 2>/dev/null)" == "survived VERDICT_RC=1" ]] \
        && grep -q 'every direction heard once the heartbeat is up: 0/8 directions heard' "$st_tmp/detect_first.out" \
        && ok "a detection part that fails its first check records FAIL and returns -- the run goes on (set -e process)" \
        || red "a detection part that fails its first check ended the run under set -e: rc $wrc, '$(cat "$st_tmp/detect_first.result" 2>/dev/null || echo 'nothing written')'; driver said: $(tail -2 "$st_tmp/detect_first.out" | tr '\n' ' ')"
    # R4-5 -- a cycle that goes as designed. The round-4 driver had no QDISC_TOOL: any scenario that
    # got past the first check died of the driver's own `set -u` there, as 5c882c9f's did on CUT_DIRS.
    local want
    st_detect healthy healthy ""
    want="$(printf '%s\n' "qdisc_tool save" "tc qdisc add dev $CUT_A root netem loss 100%" \
        "tc qdisc add dev $CUT_B root netem loss 100%" "tc qdisc del dev $CUT_A root" \
        "tc qdisc del dev $CUT_B root" "qdisc_tool diff" "ndt down")"
    [[ "$wrc" == 0 && "$(cat "$st_tmp/detect_healthy.result" 2>/dev/null)" == "survived VERDICT_RC=0" \
       && "$(cat "$st_tmp/detect_healthy.result.finish" 2>/dev/null)" == "finish VERDICT_RC=0 WHY=" \
       && "$(cat "$st_tmp/detect_healthy.tc/calls")" == "$want" \
       && "$(sed -n 2p "$st_tmp/detect_healthy.run/20_cycles.tsv" 2>/dev/null)" == $'1\t12.345\t1.000\t0.000\tOK\tno' ]] \
        && ok "a detection cycle that goes as designed: both ends cut, both restored, its row written, the run goes on (set -e process, fake tc)" \
        || red "a detection cycle that goes as designed: rc $wrc, '$(cat "$st_tmp/detect_healthy.result" 2>/dev/null || echo 'nothing written')', calls: $(paste -sd';' "$st_tmp/detect_healthy.tc/calls"); $(st_died "$st_tmp/detect_healthy.out")"
    # R4-2 -- the cut is refused on its SECOND end. The first end's netem has to come off while its
    # veth still exists; left to the EXIT trap, it runs after `ndt down` removed the veth, answers
    # "cannot locate", and adds a second, misleading failure.
    st_detect halfcut healthy "$CUT_B"
    want="$(printf '%s\n' "qdisc_tool save" "tc qdisc add dev $CUT_A root netem loss 100%" \
        "tc qdisc add dev $CUT_B root netem loss 100%" "tc qdisc del dev $CUT_A root" \
        "qdisc_tool diff" "ndt down")"
    [[ "$wrc" == 0 && "$(cat "$st_tmp/detect_halfcut.result" 2>/dev/null)" == "survived VERDICT_RC=1" \
       && "$(cat "$st_tmp/detect_halfcut.result.finish" 2>/dev/null)" == "finish VERDICT_RC=1 WHY=tc refused to add netem on $CUT_B (root)" \
       && "$(cat "$st_tmp/detect_halfcut.tc/calls")" == "$want" ]] \
       && ! grep -qE 'cannot locate|could NOT remove' "$st_tmp/detect_halfcut.out" \
        && ok "  a half-done cut (the second end refused): the first end's netem comes off before 'ndt down'; no 'cannot locate' at teardown" \
        || red "  a half-done cut: rc $wrc, '$(cat "$st_tmp/detect_halfcut.result.finish" 2>/dev/null || echo 'finish never ran')', calls: $(paste -sd';' "$st_tmp/detect_halfcut.tc/calls")$(grep -q 'cannot locate' "$st_tmp/detect_halfcut.out" && echo '; teardown said: cannot locate the netem (its veth was gone)'); $(st_died "$st_tmp/detect_halfcut.out")"

    # R3-4, round 4 -- the census reads the new daemon's session from its report, which may not be
    # written the instant `start` returns. Bounded wait, and no abort under set -e either way.
    # R4-1 (round-4 verdict) -- and only from a report that says `running` and names the pid `start`
    # answered with: `start` can return while the file still holds the previous arm's final report.
    {
        echo 'set -euo pipefail'
        declare -f wait_session
        printf 'WATCH=%q\n' "$WATCH"
        cat <<'DRIVER'
s="$(wait_session "$1" 4 "$3")" || s="NONE"
echo "$s" > "$2"
DRIVER
    } > "$st_tmp/session_driver.sh"
    st_session() {   # st_session <report json, or "" for no report> <the pid start named> -> "rc N: <session|NONE>"
        local f src
        f="$(mktemp "$st_tmp/report-XXXXXX")"
        if [[ -n "$1" ]]; then printf '%s' "$1" > "$f.json"; fi
        bash "$st_tmp/session_driver.sh" "$f.json" "$f.got" "$2" >/dev/null 2>&1 && src=0 || src=$?
        printf 'rc %s: %s' "$src" "$(cat "$f.got" 2>/dev/null)"
    }
    r="$(st_session '{"status": "running", "pid": 4242, "session": "0102030405060708"}' 4242)"
    [[ "$r" == "rc 0: 0102030405060708" ]] \
        && ok "the census reads the daemon's session from its report (set -e process)" \
        || red "reading the session from the running daemon's report: $r"
    r="$(st_session "" 4242)"
    [[ "$r" == "rc 0: NONE" ]] \
        && ok "  no report yet: a bounded wait, then 'no session' for the caller to handle -- not an abort" \
        || red "  no report: $r"
    r="$(st_session '{"status": "stopped", "pid": 1111, "session": "a1a1a1a1a1a1a1a1"}' 4242)"
    [[ "$r" == "rc 0: NONE" ]] \
        && ok "  the previous arm's final report ('stopped', its own pid) is not taken for the new daemon's session" \
        || red "  the previous arm's final 'stopped' report was taken for the new session: $r"
    r="$(st_session '{"status": "stopped", "pid": 4242, "session": "b2b2b2b2b2b2b2b2"}' 4242)"
    [[ "$r" == "rc 0: NONE" ]] \
        && ok "  nor a 'stopped' report of the very pid start named (a daemon that has already exited)" \
        || red "  a 'stopped' report of the pid start named was taken for a session: $r"
    r="$(st_session '{"status": "running", "pid": 1111, "session": "c3c3c3c3c3c3c3c3"}' 4242)"
    [[ "$r" == "rc 0: NONE" ]] \
        && ok "  nor a 'running' report of another pid (a daemon killed before it could write 'stopped')" \
        || red "  a 'running' report of another pid was taken for the new session: $r"
    # The pid is the one in the helper's own answer: the template is read out of the helper this
    # checkout installs, filled in, and handed to what the census calls.
    local tpl
    tpl="$(sed -n 's/^ *echo "\(heartbeat started (pid \$pid;[^"]*\)"$/\1/p' "$REPO/tools/test_workflow/ndtwin-lab" | head -1)"
    printf '%s\n' "${tpl//\$pid/4242}" > "$st_tmp/start_answer.txt"
    r="$(/usr/bin/python3 -I "$WATCH" started-pid "$st_tmp/start_answer.txt" 2>&1 | tail -1)"
    [[ -n "$tpl" && "$r" == 4242 ]] \
        && ok "  the pid is read from the helper's own 'heartbeat started (pid N; ...)' answer (template taken from the helper)" \
        || red "  the pid in the helper's start answer is not what the census reads: template '${tpl:-not found in the helper}', read '$r'"
    # R4-1 at the census's own call site: one arm, driven with stubs in a fresh `bash -euo pipefail`
    # process -- census, wait_session and the sniffer watch are this file's code (`declare -f`),
    # hb_watch.py is the real one; the lab (prepare, ndt, the heartbeat helper, the model's hosts,
    # host_pid, sudo/mnexec) is stubbed, and the stub sniffer records the session it was given.
    printf 'host_pid() { echo 4321; }\n' > "$st_tmp/fake_ndt"
    {
        echo 'set -euo pipefail'
        declare -f census wait_session watch_sniffers watch_hit child_running note fail bad say
        printf 'WATCH=%q\nSNIFF=%q\nREAL_NDT=%q\n' "$WATCH" "$SNIFF" "$st_tmp/fake_ndt"
        cat <<'DRIVER'
sudo() {
    if [[ "${2:-}" == mnexec ]]; then echo "sniff ${10:-} ${12:-}" >> "$CALLS"; else echo "sudo $*" >> "$CALLS"; fi
    printf '{"host": "%s", "frames_hb": 0}\n' "${10:-}"
}
out="$1"; RUN="$2"; HB_REPORT="$3"; START_ANSWER="$4"; CALLS="$2/calls"
mkdir -p "$RUN"; : > "$CALLS"
VERDICT_RC=0; VERDICT_WHY=""; HB_STARTED=0; WATCH_HIT=""; EXERCISES=basic; ARMS=solution; SNIFF_S=1
prepare() { echo "OK /nonexistent/pkg"; }
nd_up() { : > "$2"; return 0; }
sp_hb_start() { printf '%s\n' "$START_ANSWER" > "$1"; HB_STARTED=1; return 0; }
sp_hb_stop() { echo "hb stop" >> "$CALLS"; HB_STARTED=0; }
nd_down() { echo "ndt down" >> "$CALLS"; return 0; }
model_hosts() { echo "h1 10.0.0.1"; }
census
echo "survived VERDICT_RC=$VERDICT_RC WHY=$VERDICT_WHY" > "$out"
DRIVER
    } > "$st_tmp/census_arm_driver.sh"
    st_arm() {   # st_arm <name> <report json> <start answer> -> "<driver's last word> | calls: a;b | row: <tsv row>"
        local d="$st_tmp/arm_$1"
        mkdir -p "$d"; printf '%s' "$2" > "$d/report.json"
        bash "$st_tmp/census_arm_driver.sh" "$d/result" "$d/run" "$d/report.json" "$3" > "$d/out" 2>&1 || true
        printf '%s | calls: %s | row: %s' "$(cat "$d/result" 2>/dev/null || echo "died: $(st_died "$d/out")")" \
            "$(paste -sd';' "$d/run/calls" 2>/dev/null)" "$(sed -n 2p "$d/run/40_census.tsv" 2>/dev/null | tr '\t' '|')"
    }
    local started="heartbeat started (pid 4242; report: /run/ndtwin-lab/heartbeat.json, log: x)"
    r="$(st_arm new '{"status": "running", "pid": 4242, "session": "0102030405060708"}' "$started")"
    [[ "$r" == "survived VERDICT_RC=0 WHY= | calls: sniff h1 0102030405060708;hb stop;ndt down | row: basic|solution|yes|running|OK "* ]] \
        && ok "  a census arm: the pid start named ties the session, and the sniffers get that one (census driven with stubs, set -e process)" \
        || red "  a census arm with the new daemon's report: $r"
    r="$(st_arm stale '{"status": "stopped", "pid": 1111, "session": "a1a1a1a1a1a1a1a1"}' "$started")"
    [[ "$r" == "survived VERDICT_RC=1 WHY=census basic/solution: the heartbeat started (pid 4242) but no running report of that pid carries a session after 5 s | calls: hb stop;ndt down | row: basic|solution|yes|no session in 5 s|-" ]] \
        && ok "  an arm whose report is still the previous arm's 'stopped' one: a FAIL row, no sniffer given that session" \
        || red "  an arm whose report is still the previous arm's 'stopped' one: $r"
    r="$(st_arm already '{"status": "running", "pid": 4242, "session": "d4d4d4d4d4d4d4d4"}' \
        "heartbeat already running (pid 4242) -- not starting a second one")"
    [[ "$r" == "survived VERDICT_RC=1 WHY=census basic/solution: 'heartbeat start' answered 0 without saying it started a daemon -- see 11_hb_start.txt | calls: hb stop;ndt down | row: basic|solution|yes|no session in 5 s|-" ]] \
        && ok "  an arm whose start answered 'already running' (it started nothing): a FAIL row, nobody else's session sniffed" \
        || red "  an arm whose start answered 'already running': $r"

    # R4-3 (round-4 verdict) -- the census table is a display; the raw is 40_census.tsv. The run
    # block's own display step (read out of this file, whatever it is) runs in a fresh
    # `bash -euo pipefail` process on a PATH with no `column` (bsdextrautils): it must print the rows
    # and let the run go on to its verdict. And where `column` is there, it is still used.
    local step
    step="$(awk '/^# --- the run/ {run = 1} run && /^    census$/ {grab = 1; next} grab && /^fi$/ {exit} grab' "${BASH_SOURCE[0]}")"
    mkdir -p "$st_tmp/census_run" "$st_tmp/bin_nocolumn" "$st_tmp/bin_column"
    printf 'exercise\tarm\tbuilt\theartbeat\tverdict\nbasic\tsolution\tyes\trunning\tOK no host saw a heartbeat frame\n' \
        > "$st_tmp/census_run/40_census.tsv"
    {
        echo 'set -euo pipefail'
        if declare -F show_census >/dev/null; then declare -f show_census; fi
        printf 'RUN=%q\n' "$st_tmp/census_run"
        printf '%s\n' "$step"
        echo 'echo survived > "$1"'
    } > "$st_tmp/census_driver.sh"
    ln -s "$(command -v sed)" "$st_tmp/bin_nocolumn/sed"
    ln -s "$(command -v sed)" "$st_tmp/bin_column/sed"
    { printf '#!%s\n' "$BASH"; echo 'echo column-ran; while IFS= read -r l; do printf "%s\n" "$l"; done < "${!#}"'; } \
        > "$st_tmp/bin_column/column"
    chmod +x "$st_tmp/bin_column/column"
    PATH="$st_tmp/bin_nocolumn" "$BASH" "$st_tmp/census_driver.sh" "$st_tmp/census_nocolumn.result" \
        > "$st_tmp/census_nocolumn.out" 2>&1 && wrc=0 || wrc=$?
    [[ -n "$step" && "$wrc" == 0 && "$(cat "$st_tmp/census_nocolumn.result" 2>/dev/null)" == survived ]] \
        && grep -q '^   basic' "$st_tmp/census_nocolumn.out" \
        && ok "the census table on a machine without 'column': the rows are printed and the run goes on to its verdict (set -e process)" \
        || red "the census table without 'column' ended the run: rc $wrc, step '${step:-not found in the run block}'; it said: $(head -2 "$st_tmp/census_nocolumn.out" | tr '\n' ' ')"
    PATH="$st_tmp/bin_column" "$BASH" "$st_tmp/census_driver.sh" "$st_tmp/census_column.result" \
        > "$st_tmp/census_column.out" 2>&1 && wrc=0 || wrc=$?
    [[ "$wrc" == 0 && "$(cat "$st_tmp/census_column.result" 2>/dev/null)" == survived ]] \
        && grep -q '^   column-ran' "$st_tmp/census_column.out" && grep -q '^   basic' "$st_tmp/census_column.out" \
        && ok "  and where 'column' is installed it still lays the table out" \
        || red "  the census table with 'column' installed: rc $wrc; it said: $(head -2 "$st_tmp/census_column.out" | tr '\n' ' ')"
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
    show_census "$RUN/40_census.tsv"
fi
say "done -- teardown follows"
