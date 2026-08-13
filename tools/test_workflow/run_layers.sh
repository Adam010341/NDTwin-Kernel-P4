#!/usr/bin/env bash
#
# Top-level driver for the test layers in doc/2026-07-27_testing_workflow.md.
#
# Picks the right set of layers for what you are doing, so the common cases are one
# command instead of six:
#
#   ./run_layers.sh quick              L0 + L1                  (~2 min, no Mininet)
#   ./run_layers.sh api p4             L2 + L3 + log check      (needs a running stack)
#   ./run_layers.sh api p4 --traffic   as above, plus telemetry checks
#   ./run_layers.sh baseline ovs       capture the OVS reference for L4
#   ./run_layers.sh compare            diff the last P4 capture against the OVS baseline
#   ./run_layers.sh full p4            everything available for a P4 run
#
# Each layer prints its own verdict; the summary at the end is what to read. Exit code is
# non-zero if any layer failed, so this can gate CI.
#
# [Co-developed with claude code -- Adam]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=components.env
source "$HERE/components.env"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; B=''; D=''; N=''
fi

mkdir -p "$LOG_DIR" "$BASELINE_DIR"

RESULTS=()   # "name|status"
FAILED=0

banner() { echo; echo "${B}=== $* ===${N}"; }

# layer <label> <command...>
layer() {
    local label="$1"; shift
    banner "$label"
    if "$@"; then
        RESULTS+=("$label|pass")
    else
        RESULTS+=("$label|FAIL")
        FAILED=$((FAILED + 1))
    fi
}

# A layer whose failure should not stop later layers but must be reported.
skip_note() { RESULTS+=("$1|skip"); echo "${Y}skipped: $2${N}"; }

kernel_reachable() {
    curl -sf --max-time 3 "$NDT_URL/ndt/get_graph_data" >/dev/null 2>&1
}

topo_for_mode() {
    case "$1" in
        p4)  echo "$TOPO_P4" ;;
        ovs) echo "$TOPO_OVS" ;;
        *)   echo "" ;;
    esac
}

# --- layer implementations --------------------------------------------------------

run_l0()  { "$HERE/l0_build_check.sh"; }
run_l1()  { "$HERE/l1_unit_tests.sh" "$@"; }

run_l2() {
    local topo="$1"; shift
    "$CONTRACT_DIR/run_contract_test.py" --url "$NDT_URL" --topology "$topo" "$@"
}

run_l3() {
    local topo="$1"; shift
    "$CONTRACT_DIR/l3_component_check.py" --url "$NDT_URL" --topology "$topo" "$@"
}

KERNEL_LOG="$LOG_DIR/kernel.log"
LOG_MARK=0

# Record how long the kernel log is BEFORE the contract tests run. L2's error-path
# checks deliberately provoke ERROR and WARN lines (malformed JSON, unknown dpid,
# non-numeric dpid, unknown endpoint), so checking the whole file afterwards would be
# permanently red for reasons the test itself caused -- which trains you to ignore the
# one mechanism that makes new warnings fail.
LOG_MARKED=0

mark_log() {
    if [[ -f "$KERNEL_LOG" ]]; then
        LOG_MARK=$(wc -l <"$KERNEL_LOG")
        # [Co-developed with claude code -- Adam]
        # The mark only excludes the errors *this* run provokes. Run the contract tests twice
        # against one kernel process and the first run's deliberate errors sit below the second
        # run's mark, so they are reported as unexplained warnings: a wall of red that means
        # nothing. Measured: four runs against one kernel gave "47 problem line(s) across 13
        # distinct message(s)", every one of them a probe the suite fired itself.
        #
        # Detected on a signature no real traffic produces, and only warned about -- the run is
        # still useful for L2/L3, it is just the log layer whose result cannot be trusted.
        if grep -q "there_is_no_such_endpoint" "$KERNEL_LOG" 2>/dev/null; then
            echo "${Y}note: this kernel log already contains a previous contract run's"
            echo "deliberate error probes, so the log check below will report them as if they"
            echo "were new. Restart the kernel for a log result you can trust:"
            echo "  ./stack.sh down && ./stack.sh up ${DP:-ovs}${N}"
        fi
    else
        LOG_MARK=0
    fi
    # Separate flag rather than testing LOG_MARK -gt 0: a mark of 0 is legitimate (the log
    # was empty or absent before the tests ran) and means "check crashes only". Treating 0
    # as unmarked scanned the whole log instead and failed on the errors L2 provokes itself.
    LOG_MARKED=1
}

# [Co-developed with claude code -- Adam]
# True when a running kernel actually has this log file open. Without this check the log layer
# happily validated a file no live process was writing: an operator following the user manual starts
# the kernel by hand, so its output goes to their terminal and $LOG_DIR/kernel.log keeps whatever
# the last stack.sh run left there. Measured once: the check reported on a 37-minute-old log from a
# *P4* session while the running kernel was OVS -- a verdict about the wrong process in the wrong
# mode, and nothing said so. A missing file was already handled; a stale one was not.
#
# Three states, not two, and for the same reason ovsLivenessFor has three: **"cannot tell" must not
# be reported as "no".**
#
#   0  a running kernel has this file open
#   1  a running kernel does not have it open -- the log is stale
#   2  cannot tell, because /proc/<pid>/fd is unreadable by this user
#
# State 2 is the documented startup. `/proc/PID/fd` is mode 0500 owned by the process's uid, and the
# manual teaches `sudo -E bin/ndtwin_kernel` (see doc/2026-07-29_HANDOFF.md 5, which also warns that a normal
# `pkill` cannot kill it). Against a root-owned kernel the glob matched nothing, this returned 1, and
# the log layer hard-failed with "is not being written by any running kernel" -- while the kernel was
# writing it live. A guard that fails on the recommended workflow gets worked around, which is how the
# last generation of allowlist noise got where it did.
kernel_owns_log() {
    local target pid pids unreadable=0
    target="$(readlink -f "$KERNEL_LOG" 2>/dev/null)" || return 1
    pids="$(pgrep -x ndtwin_kernel 2>/dev/null)"
    [[ -z "$pids" ]] && return 1   # no kernel at all: definitely stale, not "cannot tell"

    for pid in $pids; do
        if readlink -f /proc/"$pid"/fd/* 2>/dev/null | grep -qxF "$target"; then
            return 0
        fi
        # Distinguish "looked and it is not there" from "was not allowed to look".
        [[ -r /proc/"$pid"/fd ]] || unreadable=1
    done
    [[ "$unreadable" -eq 1 ]] && return 2
    return 1
}

# Weaker evidence for the "cannot tell" case: is the file being written right now?
# Not used as the primary signal -- a busy kernel writes constantly, but so does a log rotated by
# something else -- only to avoid a false FAIL when the strong signal is unavailable.
# [Co-developed with claude code -- Adam]
log_written_recently() {
    local age
    age="$(( $(date +%s) - $(stat -c %Y "$KERNEL_LOG" 2>/dev/null || echo 0) ))"
    [[ "$age" -ge 0 && "$age" -le "${LOG_FRESH_SECONDS:-120}" ]]
}

run_logcheck() {
    if [[ ! -f "$KERNEL_LOG" ]]; then
        # Not silently passing: a missing log means this layer checked nothing, and the
        # documented workflow starts Mininet by hand, so this is easy to hit by accident.
        echo "${R}no kernel log at $KERNEL_LOG${N}"
        echo "this layer verified nothing. Either start the stack with stack.sh, or point"
        echo "the checker at your log directly:"
        echo "  $CONTRACT_DIR/check_logs.py /path/to/kernel.log"
        return 1
    fi
    kernel_owns_log
    case $? in
        0) ;;   # a live kernel has it open
        2)
            # Cannot inspect the kernel's fds -- it is running as another user, which is what the
            # manual's `sudo -E` produces. Fall back to file freshness and say so, rather than
            # asserting the log is stale when it may be being written live.
            # [Co-developed with claude code -- Adam]
            if log_written_recently; then
                echo "${Y}cannot verify the log's owner: the kernel is running as another user"
                echo "(/proc/<pid>/fd is unreadable), which is what 'sudo -E bin/ndtwin_kernel' does."
                echo "Proceeding on file freshness instead -- last written"
                echo "$(stat -c %y "$KERNEL_LOG" 2>/dev/null).${N}"
            else
                echo "${R}$KERNEL_LOG has not been written in ${LOG_FRESH_SECONDS:-120}s${N}"
                echo "last written: $(stat -c %y "$KERNEL_LOG" 2>/dev/null || echo unknown)"
                echo "a kernel is running but its fds cannot be inspected, and this file looks"
                echo "stale, so this layer would be checking nothing. Point the checker at the log"
                echo "your kernel is actually writing:"
                echo "  $CONTRACT_DIR/check_logs.py /path/to/your/kernel.log"
                return 1
            fi
            ;;
        *)
            echo "${R}$KERNEL_LOG is not being written by any running kernel${N}"
            echo "last written: $(stat -c %y "$KERNEL_LOG" 2>/dev/null || echo unknown)"
            echo "this layer would report on a stale file, so it is checking nothing. Either start the"
            echo "kernel with stack.sh, or point the checker at the log your kernel is writing:"
            echo "  $CONTRACT_DIR/check_logs.py /path/to/your/kernel.log"
            return 1
            ;;
    esac

    if [[ "$LOG_MARKED" -eq 1 ]]; then
        echo "${D}checking lines 1-$LOG_MARK (before the L2 error-path checks);"
        echo "crashes are still scanned across the whole file${N}"
        "$CONTRACT_DIR/check_logs.py" "$KERNEL_LOG" --to-line "$LOG_MARK"
    else
        "$CONTRACT_DIR/check_logs.py" "$KERNEL_LOG"
    fi
}

run_capture() {
    local topo="$1" outdir="$2"; shift 2
    rm -rf "$outdir"; mkdir -p "$outdir"
    "$CONTRACT_DIR/run_contract_test.py" --url "$NDT_URL" --topology "$topo" \
        --save-json "$outdir" "$@"
    # The capture is what matters here; contract failures are reported by the L2 layer,
    # so a non-zero exit from the run itself must not lose the saved responses.
    local n; n=$(find "$outdir" -name '*.json' | wc -l)
    echo
    if [[ "$n" -gt 0 ]]; then
        echo "${G}captured $n response(s) to $outdir${N}"
        return 0
    fi
    echo "${R}captured nothing to $outdir${N}"
    return 1
}

run_compare() {
    local base="$BASELINE_DIR/ovs" cand="$BASELINE_DIR/p4"
    if [[ ! -d "$base" ]]; then
        echo "${R}no OVS baseline at $base${N}"
        echo "capture it first:  $0 baseline ovs"
        return 1
    fi
    if [[ ! -d "$cand" ]]; then
        echo "${R}no P4 capture at $cand${N}"
        echo "capture it first:  $0 baseline p4"
        return 1
    fi
    "$CONTRACT_DIR/compare_baseline.py" "$base" "$cand"
}

# --- summary ----------------------------------------------------------------------

summary() {
    echo
    echo "${B}======================================================================${N}"
    echo "${B}Summary${N}"
    local entry name status
    for entry in "${RESULTS[@]}"; do
        name="${entry%%|*}"; status="${entry##*|}"
        case "$status" in
            pass) printf '  %s%-6s%s %s\n' "$G" PASS "$N" "$name" ;;
            FAIL) printf '  %s%-6s%s %s\n' "$R" FAIL "$N" "$name" ;;
            skip) printf '  %s%-6s%s %s\n' "$Y" SKIP "$N" "$name" ;;
        esac
    done
    echo
    echo "  logs: $LOG_DIR"
    if [[ $FAILED -gt 0 ]]; then
        echo "${R}$FAILED layer(s) failed${N}"
        return 1
    fi
    echo "${G}all layers passed${N}"
    return 0
}

# --- modes ------------------------------------------------------------------------

MODE="${1:-}"
shift || true

case "$MODE" in
    quick)
        layer "L0 build check" run_l0
        layer "L1 unit tests" run_l1 --no-build
        ;;

    api)
        DP="${1:-}"; shift || true
        TOPO="$(topo_for_mode "$DP")"
        [[ -z "$TOPO" ]] && { echo "usage: $0 api {ovs|p4} [--traffic] [--mutations]"; exit 2; }
        EXTRA=()
        for a in "$@"; do
            case "$a" in
                --traffic)   EXTRA+=(--with-traffic) ;;
                --mutations) EXTRA+=(--allow-mutations) ;;
                *) echo "unknown option: $a"; exit 2 ;;
            esac
        done
        if ! kernel_reachable; then
            echo "${R}kernel not reachable at $NDT_URL${N}"
            echo "start it first:  $HERE/stack.sh up $DP && $HERE/stack.sh wait"
            exit 1
        fi
        mark_log
        layer "L2 API contract ($DP)" run_l2 "$TOPO" "${EXTRA[@]}"
        layer "L3 component contract ($DP)" run_l3 "$TOPO" "${EXTRA[@]}"
        layer "log allowlist check" run_logcheck
        ;;

    baseline)
        DP="${1:-}"; shift || true
        TOPO="$(topo_for_mode "$DP")"
        [[ -z "$TOPO" ]] && { echo "usage: $0 baseline {ovs|p4} [--traffic]"; exit 2; }
        EXTRA=()
        for a in "$@"; do
            case "$a" in
                --traffic) EXTRA+=(--with-traffic) ;;
                *) echo "unknown option: $a"; exit 2 ;;
            esac
        done
        if ! kernel_reachable; then
            echo "${R}kernel not reachable at $NDT_URL${N}"; exit 1
        fi
        layer "capture $DP responses" run_capture "$TOPO" "$BASELINE_DIR/$DP" "${EXTRA[@]}"
        echo
        echo "${D}captures live in $BASELINE_DIR; compare with:  $0 compare${N}"
        ;;

    compare)
        layer "L4 OVS/P4 differential" run_compare
        ;;

    full)
        DP="${1:-}"; shift || true
        TOPO="$(topo_for_mode "$DP")"
        [[ -z "$TOPO" ]] && { echo "usage: $0 full {ovs|p4} [--traffic] [--mutations]"; exit 2; }
        EXTRA=()
        for a in "$@"; do
            case "$a" in
                --traffic)   EXTRA+=(--with-traffic) ;;
                --mutations) EXTRA+=(--allow-mutations) ;;
                *) echo "unknown option: $a"; exit 2 ;;
            esac
        done
        layer "L0 build check" run_l0
        layer "L1 unit tests" run_l1 --no-build
        if kernel_reachable; then
            mark_log
            layer "L2 API contract ($DP)" run_l2 "$TOPO" "${EXTRA[@]}"
            layer "L3 component contract ($DP)" run_l3 "$TOPO" "${EXTRA[@]}"
            layer "log allowlist check" run_logcheck
            layer "capture $DP responses" run_capture "$TOPO" "$BASELINE_DIR/$DP" "${EXTRA[@]}"
            if [[ -d "$BASELINE_DIR/ovs" && -d "$BASELINE_DIR/p4" ]]; then
                layer "L4 OVS/P4 differential" run_compare
            else
                skip_note "L4 OVS/P4 differential" \
                    "needs captures for both planes ($0 baseline ovs, $0 baseline p4)"
            fi
        else
            skip_note "L2 API contract" "kernel not reachable at $NDT_URL"
            skip_note "L3 component contract" "kernel not reachable at $NDT_URL"
            skip_note "log allowlist check" "kernel not reachable at $NDT_URL"
        fi
        ;;

    selftest)
        # Everything that needs neither a kernel nor Mininet -- safe anywhere.
        layer "contract self-test" "$CONTRACT_DIR/run_contract_test.py" --self-test
        layer "component dependency map" "$CONTRACT_DIR/l3_component_check.py" --map
        ;;

    *)
        cat <<EOF
usage: $0 <mode> [args]

  quick               L0 build check + L1 unit tests          (no Mininet needed)
  selftest            offline checks: schema self-test, dependency map
  api {ovs|p4}        L2 + L3 + log check against a running stack
                        --traffic     also require flows/paths/rates
                        --mutations   also exercise write endpoints
  baseline {ovs|p4}   capture responses for L4 comparison
  compare             diff the P4 capture against the OVS baseline
  full {ovs|p4}       everything available, skipping what cannot run

typical P4 session:
  $HERE/stack.sh up p4 && $HERE/stack.sh wait
  $0 api p4 --traffic
  $HERE/stack.sh down

establishing the L4 baseline (once, on a healthy OVS run):
  $HERE/stack.sh up ovs && $HERE/stack.sh wait
  $0 baseline ovs --traffic

run artefacts: $RUN_DIR
EOF
        exit 2 ;;
esac

summary
