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
# it. The suite leads a session of its own (setsid). When it has printed its first
# `ok       fixture took argv0=` line -- a fixture exists -- the signal is sent: TERM to the
# suite's own pid, INT to its whole process group, the way a terminal's Ctrl-C arrives (bash
# runs an INT trap once the foreground child it is waiting for has died of INT too). Then:
#   * it ends within SIGNAL_END_WITHIN seconds (default 20), with 143 for TERM and 130 for INT;
#   * no process carrying the token is left once it has ended;
#   * its temp tree is gone. Three suites honour TMPDIR, which is pointed at a directory of this
#     test's own; the other four write under /tmp, and their tree is the new one whose fixture
#     register lists a pid that carries the token.
# INT goes through `env --default-signal=INT`: a background job of a non-interactive shell starts
# with INT ignored, and bash cannot trap a signal that was ignored when it started.
#
# Run:  bash tests/shell/test_fixture_suites_end_on_signal.sh [label...]
#   labels: orphans liveness sweep window topo_pid ovs_claim down (default: all seven)
#   SIGNAL_END_WITHIN=20  SIGNAL_FIRST_FIXTURE_WAIT=180  SIGNAL_HARD_LIMIT=600   (seconds)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_LABELS=(orphans liveness sweep window topo_pid ovs_claim down)
END_WITHIN="${SIGNAL_END_WITHIN:-20}"
FIRST_WAIT="${SIGNAL_FIRST_FIXTURE_WAIT:-180}"
HARD_LIMIT="${SIGNAL_HARD_LIMIT:-600}"

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
# TMPDIR), SREG (its fixture register, relative to that tree; empty if it keeps none)
suite_info() {
    case "$1" in
        orphans)   SFILE="$HERE/test_ndt_app_orphans.sh";           SPREFIX=ndt-app-orphans-;     SPRIVATE=0; SREG=fixtures ;;
        liveness)  SFILE="$HERE/test_ndt_apps_liveness.sh";         SPREFIX=ndt-apps-liveness-;   SPRIVATE=0; SREG=fixtures ;;
        sweep)     SFILE="$HERE/test_ndtwin_lab_sweep.sh";          SPREFIX=ndtwin-lab-sweep-;    SPRIVATE=0; SREG=fixtures ;;
        topo_pid)  SFILE="$HERE/test_faults_topo_pid.sh";           SPREFIX=faults-topo-pid-;     SPRIVATE=0; SREG=fixtures ;;
        window)    SFILE="$HERE/test_ndt_helper_apps_window.sh";    SPREFIX=ndt-helper-window-;   SPRIVATE=1; SREG="" ;;
        ovs_claim) SFILE="$HERE/test_ndt_ovs_claim.sh";             SPREFIX=ndt-ovs-claim-;       SPRIVATE=1; SREG="" ;;
        down)      SFILE="$HERE/test_ndt_down_stops_only_ours.sh";  SPREFIX=ndt-down-ours-;       SPRIVATE=1; SREG="" ;;
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
    local label="$1" sig="$2" want="$3" tok tmpd out spid t0 t1 rc i tree="" d p f0="$FAIL"
    local -a before=() fixtures=() left=()
    suite_info "$label"
    tok="$label-$sig-$$-$RANDOM$RANDOM"; TOKENS+=("$tok")
    tmpd="$WORK/tmp-$label-$sig"; out="$WORK/out-$label-$sig.log"
    mkdir -p "$tmpd"
    (( SPRIVATE )) || { shopt -s nullglob; before=(/tmp/"$SPREFIX"*); shopt -u nullglob; }
    echo "$label, $sig"
    TMPDIR="$tmpd" NDT_SIGNAL_TEST_TOKEN="$tok" \
        setsid env --default-signal=INT bash "$SFILE" </dev/null >"$out" 2>&1 &
    spid=$!
    # Wait for the first fixture premise: from here on the run is mid-way, with a fixture to lose.
    for (( i = 0; i < FIRST_WAIT * 10; i++ )); do
        grep -qE '^ *ok +fixture took argv0=' "$out" 2>/dev/null && break
        ended "$spid" && break
        sleep 0.1
    done
    if ended "$spid" || ! grep -qE '^ *ok +fixture took argv0=' "$out"; then
        check "$label $sig: the suite reaches its first fixture, still running" yes \
              "no ($(state_of "$spid"); last line: $(tail -1 "$out" | cut -c1-100))"
        kill -KILL "$spid" 2>/dev/null; wait "$spid" 2>/dev/null; reap_token "$tok"
        return
    fi
    mapfile -t fixtures < <(token_pids "$tok" | grep -vx -- "$spid")
    check "$label $sig: the pid signalled is the shell running the suite" yes \
          "$([[ "$(tr '\0' ' ' < "/proc/$spid/cmdline" 2>/dev/null)" == *"$SFILE"* ]] && echo yes || echo no)"
    check "$label $sig: and it leads its own process group" "$spid" "$(ps -o pgid= -p "$spid" 2>/dev/null | tr -d ' ')"
    check "$label $sig: a process of this run besides the suite is alive when it is signalled" yes \
          "$( (( ${#fixtures[@]} > 0 )) && echo yes || echo "no (${#fixtures[@]})")"
    # Its temp tree, by construction (TMPDIR) or by the register that names one of its pids.
    if (( SPRIVATE )); then
        for d in "$tmpd/$SPREFIX"*; do [[ -d "$d" ]] && tree="$d"; done
    else
        for d in /tmp/"$SPREFIX"*; do
            [[ -d "$d" && " ${before[*]} " != *" $d "* && -f "$d/$SREG" ]] || continue
            for p in "${fixtures[@]}"; do grep -qx -- "$p" "$d/$SREG" 2>/dev/null && { tree="$d"; break; }; done
        done
    fi
    check "$label $sig: its temp tree is found while it runs" yes "$([[ -n "$tree" ]] && echo yes || echo no)"
    t0="$(now_ms)"
    if [[ "$sig" == INT ]]; then kill -s INT -- "-$spid"; else kill -s "$sig" "$spid"; fi
    for (( i = 0; i < HARD_LIMIT * 10; i++ )); do ended "$spid" && break; sleep 0.1; done
    t1="$(now_ms)"
    ended "$spid" || kill -KILL "$spid" 2>/dev/null
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
    one "$l" TERM 143
    one "$l" INT 130
done

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
