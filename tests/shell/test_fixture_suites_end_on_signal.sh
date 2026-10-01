#!/usr/bin/env bash
#
# A signal ENDS each of the seven fixture-spawning suites: sent TERM (and INT) mid-run, a suite must
# stop at once with the shell's 128+signal status, its fixtures gone and its temp tree removed.
#
# [Co-developed with claude code -- Adam]
#
# WHAT WENT WRONG (2026-10-01). Six of these suites armed `trap <cleanup> EXIT INT TERM` with a
# cleanup that returns. On INT or TERM the handler reaped the fixtures, deleted the temp tree and
# RETURNED, and the suite went on running without them: test_ndt_down_stops_only_ours.sh spawned
# into the deleted directory and waited out its poll, the others ran their checks against a tree
# that was no longer there. test_ndt_app_orphans.sh was converted first (2026-09-28): EXIT does
# the cleaning, INT and TERM only `exit 130` / `exit 143`. This test holds all seven to that.
#
# HOW. Each suite is started in the background with a token in its environment that every
# process it starts inherits, so "a process of this run" is read from /proc/<pid>/environ, not
# from a name: a busy machine, or another checkout running the same suite, cannot be mistaken for
# it. The suite leads a session of its own (setsid). The signal is sent once the suite has printed
# an `ok       fixture took argv0=` line AND a live process carrying the token is listed in the
# suite's own fixture register -- a fixture, not just any process of the run (a poll's sleep, a
# `bash -c`), so there is something its cleanup must reap. That register also names the suite's
# temp tree: three suites honour TMPDIR, which is pointed at a directory of this test's own; the
# other four write under /tmp, and their tree is the new one whose register lists such a pid.
# TERM goes to the suite's own pid, INT to its whole process group, the way a terminal's Ctrl-C
# arrives (bash runs an INT trap once the foreground child it is waiting for has died of INT too).
# Then:
#   * it ends within SIGNAL_END_WITHIN seconds (default 20), with 143 for TERM and 130 for INT;
#   * no process carrying the token is left once it has ended;
#   * its temp tree is gone.
# Under INT the "no process left" check can only fail for a fixture outside the suite's process
# group (a setsid one): a fixture inside it dies of the same INT, reaped or not.
# INT goes through `env --default-signal=INT`: a background job of a non-interactive shell starts
# with INT ignored, and bash cannot trap a signal that was ignored when it started.
#
# Run:  bash tests/shell/test_fixture_suites_end_on_signal.sh [label...]
#   labels: orphans liveness sweep window topo_pid ovs_claim down (default: all seven)
#   SIGNAL_END_WITHIN=20  SIGNAL_FIRST_FIXTURE_WAIT=30  SIGNAL_HARD_LIMIT=30  SIGNAL_TOTAL_LIMIT=150
#   (seconds). Green, the fourteen runs take 23-24 s in all on the development machine.
# THE BOUND. The limits keep a HUNG suite a red line rather than a killed CI job. ci.yml's
#   build-and-test has timeout-minutes 30, and on PR #22 that job took 22 min 11 s and 21 min 30 s
#   (GitHub Actions jobs 110274499246 and 110274514834: 07:56:17Z-08:18:28Z and
#   07:56:19Z-08:17:49Z), so about 7.8 min are left. One run is at most FIRST_WAIT + HARD_LIMIT +
#   about 5 s of /proc scans = 65 s, and no run starts after TOTAL_LIMIT, so this whole test ends
#   within 150 + 65 = 215 s (3.6 min) -- 22 min 11 s + 3.6 min = 25.8 min, inside the 30. Without
#   the total limit it would be 14 x 65 = 910 s.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_LABELS=(orphans liveness sweep window topo_pid ovs_claim down)
END_WITHIN="${SIGNAL_END_WITHIN:-20}"
FIRST_WAIT="${SIGNAL_FIRST_FIXTURE_WAIT:-30}"
HARD_LIMIT="${SIGNAL_HARD_LIMIT:-30}"
TOTAL_LIMIT="${SIGNAL_TOTAL_LIMIT:-150}"

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"; PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

LABELS=("$@")
(( ${#LABELS[@]} )) || LABELS=("${ALL_LABELS[@]}")
for l in "${LABELS[@]}"; do
    [[ " ${ALL_LABELS[*]} " == *" $l "* ]] || { echo "no suite labelled '$l' (${ALL_LABELS[*]})"; exit 2; }
done

# suite_info <label> -> SFILE, SPREFIX (its temp tree's mktemp prefix), SPRIVATE (1: it honours
# TMPDIR), SREG (its fixture register, one pid per line, relative to that tree)
suite_info() {
    case "$1" in
        orphans)   SFILE="$HERE/test_ndt_app_orphans.sh";           SPREFIX=ndt-app-orphans-;     SPRIVATE=0; SREG=fixtures ;;
        liveness)  SFILE="$HERE/test_ndt_apps_liveness.sh";         SPREFIX=ndt-apps-liveness-;   SPRIVATE=0; SREG=fixtures ;;
        sweep)     SFILE="$HERE/test_ndtwin_lab_sweep.sh";          SPREFIX=ndtwin-lab-sweep-;    SPRIVATE=0; SREG=fixtures ;;
        topo_pid)  SFILE="$HERE/test_faults_topo_pid.sh";           SPREFIX=faults-topo-pid-;     SPRIVATE=0; SREG=fixtures ;;
        window)    SFILE="$HERE/test_ndt_helper_apps_window.sh";    SPREFIX=ndt-helper-window-;   SPRIVATE=1; SREG=fixtures ;;
        ovs_claim) SFILE="$HERE/test_ndt_ovs_claim.sh";             SPREFIX=ndt-ovs-claim-;       SPRIVATE=1; SREG=fixture.pids ;;
        down)      SFILE="$HERE/test_ndt_down_stops_only_ours.sh";  SPREFIX=ndt-down-ours-;       SPRIVATE=1; SREG=spawned.pids ;;
    esac
}

env --default-signal=INT true 2>/dev/null \
    || { echo "  FAILED   env --default-signal is not available (GNU coreutils >= 8.31)"; echo "Ran 1 checks, 1 failed"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-signal-ends-run-XXXXXX")"
TOKENS=()
# token_pids <token> -- every live process whose environment carries this run's token.
token_pids() {
    local f
    for f in $(grep -alsF -- "NDT_SIGNAL_TEST_TOKEN=$1" /proc/[0-9]*/environ 2>/dev/null); do
        f="${f#/proc/}"; echo "${f%/environ}"
    done
}
# reap_token <token> -- kill, by pid, whatever still carries it (each pid re-read first).
reap_token() {
    local p
    for p in $(token_pids "$1"); do
        grep -qasF -- "NDT_SIGNAL_TEST_TOKEN=$1" "/proc/$p/environ" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    done
    return 0
}
cleanup() {
    local t
    for t in "${TOKENS[@]}"; do reap_token "$t"; done
    [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# state_of <pid> -- R/S/D/Z/... from /proc, or "gone".
state_of() { local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || { echo gone; return; }; s="${s##*) }"; echo "${s%% *}"; }
ended() { local s; s="$(state_of "$1")"; [[ "$s" == Z || "$s" == gone ]]; }
now_ms() { local t="${EPOCHREALTIME/,/.}"; echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 )); }

# one <label> <SIG> <expected rc>
one() {
    local label="$1" sig="$2" want="$3" tok tmpd out spid t0 t1 rc i tree="" d p f0="$FAIL" deadline
    local -a before=() fixtures=() left=() live=()
    suite_info "$label"
    tok="$label-$sig-$$-$RANDOM$RANDOM"; TOKENS+=("$tok")
    tmpd="$WORK/tmp-$label-$sig"; out="$WORK/out-$label-$sig.log"
    mkdir -p "$tmpd"
    (( SPRIVATE )) || { shopt -s nullglob; before=(/tmp/"$SPREFIX"*); shopt -u nullglob; }
    echo "$label, $sig"
    TMPDIR="$tmpd" NDT_SIGNAL_TEST_TOKEN="$tok" \
        setsid env --default-signal=INT bash "$SFILE" </dev/null >"$out" 2>&1 &
    spid=$!
    # Wait until a fixture premise has been printed AND a live process of this run is in the suite's
    # own fixture register; the register it is in is the suite's temp tree. A suite may stop its
    # first fixture again within a second (test_ndt_ovs_claim.sh does) and run on with only a poll's
    # sleep or a `bash -c` of its own alive: a signal sent then gives the leftover checks nothing to
    # find, so that moment does not count.
    deadline=$(( SECONDS + FIRST_WAIT ))
    while (( SECONDS < deadline )); do
        ended "$spid" && break
        if grep -qE '^ *ok +fixture took argv0=' "$out" 2>/dev/null; then
            mapfile -t live < <(token_pids "$tok" | grep -vx -- "$spid")
            for d in "$( (( SPRIVATE )) && echo "$tmpd" || echo /tmp)/$SPREFIX"*; do
                [[ -f "$d/$SREG" ]] || continue
                (( SPRIVATE )) || [[ " ${before[*]} " != *" $d "* ]] || continue
                mapfile -t fixtures < <(printf '%s\n' "${live[@]}" | grep -xF -f "$d/$SREG" | grep -x '[0-9][0-9]*')
                (( ${#fixtures[@]} )) && { tree="$d"; break; }
            done
            [[ -n "$tree" ]] && break
        fi
        sleep 0.1
    done
    if ended "$spid" || [[ -z "$tree" ]]; then
        check "$label $sig: within ${FIRST_WAIT}s, a pid in its own fixture register is alive, the suite still running" yes \
              "no ($(state_of "$spid"); ${#live[@]} other process(es) of the run alive; last line: $(tail -1 "$out" | cut -c1-80))"
        kill -KILL "$spid" 2>/dev/null; wait "$spid" 2>/dev/null; reap_token "$tok"
        [[ -n "$tree" && -d "$tree" ]] && rm -rf "$tree"
        return
    fi
    check "$label $sig: the pid signalled is the shell running the suite" yes \
          "$([[ "$(tr '\0' ' ' < "/proc/$spid/cmdline" 2>/dev/null)" == *"$SFILE"* ]] && echo yes || echo no)"
    check "$label $sig: and it leads its own process group" "$spid" "$(ps -o pgid= -p "$spid" 2>/dev/null | tr -d ' ')"
    echo "  note     signalled with fixture pid(s) ${fixtures[*]} alive, listed in $tree/$SREG"
    t0="$(now_ms)"
    if [[ "$sig" == INT ]]; then kill -s INT -- "-$spid"; else kill -s "$sig" "$spid"; fi
    deadline=$(( SECONDS + HARD_LIMIT ))
    while (( SECONDS < deadline )); do ended "$spid" && break; sleep 0.1; done
    t1="$(now_ms)"
    if ! ended "$spid"; then
        echo "             still running ${HARD_LIMIT}s after the signal: killed (SIGNAL_HARD_LIMIT)"
        kill -KILL "$spid" 2>/dev/null
    fi
    wait "$spid"; rc=$?
    check "$label $sig: the run ends with $want" "$want" "$rc"
    check "$label $sig: within ${END_WITHIN}s of the signal" yes \
          "$( (( t1 - t0 <= END_WITHIN * 1000 )) && echo yes || echo "no ($(( (t1 - t0) / 1000 ))s)")"
    # A fixture killed on the way out can take a moment to leave /proc.
    for (( i = 0; i < 30; i++ )); do mapfile -t left < <(token_pids "$tok"); (( ${#left[@]} )) || break; sleep 0.1; done
    check "$label $sig: no process of this run is left" "" "${left[*]}"
    check "$label $sig: its temp tree is gone" no "$([[ -n "$tree" && -e "$tree" ]] && echo "yes ($tree)" || echo no)"
    if (( FAIL > f0 )); then
        echo "             the suite's last lines:"; tail -3 "$out" | cut -c1-120 | sed 's/^/               /'
    fi
    # Nothing of a red run outlives this test: its processes by pid, its tree by its exact path.
    reap_token "$tok"
    [[ -n "$tree" && -d "$tree" && "${tree##*/}" == "$SPREFIX"* ]] && rm -rf "$tree"
}

for l in "${LABELS[@]}"; do
    for sig in TERM INT; do
        if (( SECONDS >= TOTAL_LIMIT )); then
            check "$l $sig: run, before SIGNAL_TOTAL_LIMIT (${TOTAL_LIMIT}s) was used up" yes "no (${SECONDS}s used)"
            continue
        fi
        if [[ "$sig" == TERM ]]; then one "$l" TERM 143; else one "$l" INT 130; fi
    done
done

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
