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

# --- which model describes the fabric that is actually running --------------------
#
# [Co-developed with claude code -- Adam] -- KNOWN-ISSUES L-1.
#
# This used to be `p4) echo "$TOPO_P4"`, i.e. whatever components.env defaults to, which is the
# 4-host P4 model. The fabric it runs against is whatever `ndt up` last built. On the night of
# 2026-09-02 that was the 128-host model, so L2/L3 compared a 128-host fabric against a 4-host
# file and reported `host count is 128, topology file says 4` / `edge count is 288, topology
# file says 40` (raw/C39_r5_triage.log:5-9). The suite went red on a healthy system.
#
# That red is not just noise: `doc/audit/2026-08-30_live-full-stack-round/harness/40_r5_p4.sh:336`
# greps this run's output for the literal `BROKEN` and reads it as evidence about **A-8** -- so
# the highest-value fix merged that day could not get a live verdict, and the red it did get
# would have been read as a product failure. An instrument that manufactures the finding it is
# being read for is worse than one that says nothing.
#
# `ndt up` has always derived the model instead of assuming it (ndt:682 passes TOPO_P4 down to
# stack.sh, from topo_for_hosts "$(host_count)"). The two readings differ in ONE way and it
# matters here: ndt derives from `host_count_override`, the file that decides what the next
# fabric will be built with; this derives from the fabric that is running NOW. For a test suite
# the running fabric is the right source -- the override can be edited after bring-up, and the
# whole defect is a model that describes a different network than the one under test.
#
# Three outcomes, and the third is the point:
#   * a fabric is visible and a model matches its host count  -> use that model
#   * no fabric is visible                                    -> the configured default, unchanged
#   * a fabric is visible and NO model matches                -> refuse, loudly (rc 3)
# Falling back to the default in the third case is what produced the bad red; a suite that
# cannot know what it is testing must say so rather than test the wrong thing.
: "${SETTING_DIR:=$KERNEL_DIR/setting}"

# fabric_hosts_in -- count mininet host namespaces on stdin, one process argv per line.
# Split from the `ps` call so the counting is testable without a fabric.
#
# Same reading as ndt's fabric_host_count(). The tag is assembled at run time so the literal
# never appears in this script's own argv -- `mn -c` SIGKILLs a process whose command line
# carries it. Prefix plus an all-digit tail, so `mininet:h12` counts and `mininet:s1` does not.
fabric_hosts_in() {
    local tag="mininet" n=0 line last
    tag="${tag}:h"
    while read -r line; do
        last="${line##* }"
        [[ "$last" == "$tag"* && "${last#$tag}" =~ ^[0-9]+$ ]] && n=$(( n + 1 ))
    done
    echo "$n"
}

fabric_host_count() { fabric_hosts_in < <(ps -eo args= 2>/dev/null); }

# topo_for_hosts <host-count> <mode> -- the model in $SETTING_DIR with that many hosts, within
# the family named after the data plane. Prints nothing when none matches.
#
# The family is part of the query rather than an afterthought: mixing a P4 model into an OVS run
# is the mistake this exists to prevent, and on this tree the two families overlap on host count
# (StaticNetworkTopologyMininet_10Switches.json and StaticNetworkTopologyP4_10Switches_128Hosts.json
# both have 128), so a family-blind search would pick by filename order.
topo_for_hosts() {
    local want="$1" mode="${2:-p4}"
    local pats="StaticNetworkTopologyP4_*.json"
    [[ "$mode" != p4 ]] && pats="StaticNetworkTopologyOVS_*.json StaticNetworkTopologyMininet_*.json"
    python3 - "$SETTING_DIR" "$want" $pats <<'PY' 2>/dev/null
import glob, json, os, sys
d, want, pats = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
for pat in pats:
    for p in sorted(glob.glob(os.path.join(d, pat))):
        try:
            t = json.load(open(p))
        except Exception:
            continue
        if sum(1 for n in t["nodes"] if n.get("vertex_type") == 1) == want:
            print(p); raise SystemExit
PY
}

# --- ask the kernel, rather than deriving behind its back --------------------------------
#
# [Co-developed with claude code -- Adam] -- KNOWN-ISSUES G-15, DECISIONS.md grill §4E E-2.
#
# Everything above derives the model from the fabric. That is a better guess than the configured
# default was, and it is still a guess: it reads the number of host namespaces and looks for a
# model of that size. `setting/` holds more than one model with the same ten dpids and the same
# 10 switch / 4 host / 40 edge cardinality, so a fabric built from model A validated against
# model B is green **by construction** -- every per-node identity check passes because the
# numbers agree. The suite could not know what it was testing (fix/R2-PY-SUMMARY.md §7-3).
#
# The kernel knows. It opened one file, and since E-2 it reports which, together with the sha256
# of the bytes it read. So: ask first, derive only when it does not answer.
#
# 🔴 The digest is the point, not the path. A model edited after the kernel loaded it is the
# accident this exists to catch, and the path is identical on both sides of that edit.

# kernel_graph_json -- the raw /ndt/get_graph_data body, or nothing. Its own function so the
# tests can substitute a canned body: tests/shell/test_run_layers_asks_kernel.sh overrides it,
# and tests/shell/test_run_layers_topology_from_fabric.sh stubs it out entirely, which is what
# keeps the derivation suite independent of whether anything is listening on :8000.
kernel_graph_json() {
    curl -sf --max-time 3 "$NDT_URL/ndt/get_graph_data" 2>/dev/null
}

# kernel_loaded_model -- reads the body on stdin, prints "<path><TAB><sha256>" when the kernel
# named a file, and nothing otherwise. The body arrives on stdin rather than in an argument or
# an environment variable because a 128-host graph is comfortably larger than one exec argument
# may be (MAX_ARG_STRLEN, 128 KiB), and that limit fails as E2BIG on the big fabrics -- which is
# exactly where a mismatched model matters most.
kernel_loaded_model() {
    python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(body, dict):
    raise SystemExit(0)
path = body.get("topology_file")
sha = body.get("topology_sha256")
if not isinstance(path, str) or not path:
    raise SystemExit(0)
print(path + "\t" + (sha if isinstance(sha, str) else ""))
' 2>/dev/null
}

# kernel_model_is_confirmed <path> <sha the kernel reported> <sha of that file now>
#   rc 0  this run may test against <path>
#   rc 1  it may not, and the reason is on stderr
#
# Its own function so the refusal reads as one question -- "may I use the file the kernel
# named?" -- and so the caller's exit code is decided in one place.
kernel_model_is_confirmed() {
    local path="$1" sha="$2" local_sha="$3"

    if [[ -z "$local_sha" ]]; then
        echo "${R}the kernel loaded $path, and this host cannot read that file.${N}" >&2
        echo "nothing here can confirm which network the twin is describing, and deriving a" >&2
        echo "model instead would test the fabric against a file the kernel is not serving." >&2
        echo "name one explicitly if that is really what you want:" >&2
        echo "  NDT_TOPO=/path/to/model $0 ..." >&2
        return 1
    fi

    if [[ -n "$sha" && "$sha" != "$local_sha" ]]; then
        echo "${R}$path has been edited since the kernel loaded it.${N}" >&2
        echo "  kernel loaded: $sha" >&2
        echo "  on disk now:   $local_sha" >&2
        echo "the twin is serving the OLD contents and the layers below would read the NEW ones," >&2
        echo "so every difference between them would be reported as a product defect." >&2
        echo "restart the kernel on the current file, or put the file back." >&2
        return 1
    fi

    return 0
}

# topo_from_kernel -- the model the KERNEL says it loaded. Path on stdout, notes on stderr.
#   rc 0  the kernel named a file, and the bytes on disk still hash to what it loaded
#   rc 1  the kernel did not say -- unreachable, or built before E-2. The caller derives, and
#         must say that it is deriving
#   rc 3  the kernel named a file this run cannot confirm it is still serving -- refuse
#
# 🔴 A kernel built before E-2 (baseline 28b8b13) serves none of the three keys. Missing means
# "the kernel did not say", never "there is nothing to check": the caller falls back to the
# derivation and prints that it is guessing. Aborting instead would take every pre-E-2 kernel
# out of the harness, which is the widening this gate's M6 exists to catch.
topo_from_kernel() {
    local said path sha local_sha
    said="$(kernel_graph_json | kernel_loaded_model)"
    if [[ -z "$said" ]]; then
        echo "${Y}topology: the kernel did not say which model it loaded (unreachable, or built" >&2
        echo "before E-2), so the model below is DERIVED from the running fabric -- guessing.${N}" >&2
        return 1
    fi

    path="${said%%$'\t'*}"
    sha="${said#*$'\t'}"
    local_sha="$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1)"

    kernel_model_is_confirmed "$path" "$sha" "$local_sha" || return 3

    if [[ -z "$sha" ]]; then
        # A path with no digest beside it. Still better than deriving -- it is the file the
        # kernel named -- but the one question the digest answers is now unanswerable, and a
        # reader must not have to infer that from the absence of a line.
        echo "${Y}topology: the kernel named $path but reported no topology_sha256, so this run" >&2
        echo "cannot tell whether that file has been edited since it was loaded.${N}" >&2
    else
        echo "${D}topology: ${path#$KERNEL_DIR/} (the kernel says so; sha256 matches)${N}" >&2
    fi
    echo "$path"
    return 0
}

# topo_for_mode <mode> -- the model to test against. Path on stdout, notes on stderr.
#   rc 0  a model was chosen
#   rc 2  not a data plane this script knows (usage error)
#   rc 3  a fabric is running and no model in $SETTING_DIR describes it, or the kernel's own
#         model cannot be confirmed -- refuse
topo_for_mode() {
    local mode="$1" configured live derived from_kernel krc
    case "$mode" in
        p4)  configured="$TOPO_P4" ;;
        ovs) configured="$TOPO_OVS" ;;
        *)   return 2 ;;
    esac

    # NDT_TOPO short-circuits the whole thing, the same escape hatch and the same name ndt uses,
    # for a model that does not follow the naming.
    if [[ -n "${NDT_TOPO:-}" ]]; then
        echo "${D}topology: $NDT_TOPO (NDT_TOPO override)${N}" >&2
        echo "$NDT_TOPO"
        return 0
    fi

    # [Co-developed with claude code -- Adam] -- E-2. The kernel first; the derivation below is
    # the fallback for a kernel that cannot answer, not the primary answer.
    from_kernel="$(topo_from_kernel)"; krc=$?
    if [[ "$krc" -eq 0 ]]; then
        echo "$from_kernel"
        return 0
    fi
    [[ "$krc" -eq 3 ]] && return 3

    live="$(fabric_host_count)"
    if [[ "${live:-0}" -le 0 ]]; then
        # Nothing to derive from. Not an error here: `api`/`baseline` check kernel_reachable
        # separately, and `full` deliberately runs the offline layers with no fabric at all.
        echo "$configured"
        return 0
    fi

    derived="$(topo_for_hosts "$live" "$mode")"
    if [[ -z "$derived" ]]; then
        echo "${R}the running fabric has $live host(s) and no $mode model in $SETTING_DIR" >&2
        echo "describes a network that size.${N}" >&2
        echo "testing against ${configured#$KERNEL_DIR/} anyway would compare the twin to a" >&2
        echo "different network and report the difference as a product defect -- which is how" >&2
        echo "a BROKEN line ended up being read as evidence about A-8 (KNOWN-ISSUES L-1)." >&2
        echo "derive one first, or name it explicitly:" >&2
        echo "  python3 tools/test_workflow/derive_p4_topology_json.py \\" >&2
        echo "      setting/StaticNetworkTopologyMininet_10Switches.json \\" >&2
        echo "      setting/StaticNetworkTopologyP4_10Switches_${live}Hosts.json" >&2
        echo "  NDT_TOPO=/path/to/model $0 ..." >&2
        return 3
    fi

    if [[ "$derived" != "$configured" ]]; then
        echo "${Y}topology: the running fabric has $live host(s), so this run uses" >&2
        echo "${derived#$KERNEL_DIR/} rather than the configured ${configured#$KERNEL_DIR/}.${N}" >&2
    else
        echo "${D}topology: ${derived#$KERNEL_DIR/} ($live host(s), matches the running fabric)${N}" >&2
    fi
    echo "$derived"
    return 0
}

# select_topo <mode> <usage line> -- set $TOPO, or exit. Called at top level so `exit` works;
# topo_for_mode itself runs in a $( ) and cannot end the script.
select_topo() {
    local mode="$1" usage="$2" rc
    TOPO="$(topo_for_mode "$mode")"; rc=$?
    case "$rc" in
        0) ;;
        2) echo "usage: $usage"; exit 2 ;;
        *) exit 1 ;;
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

    # [Co-developed with claude code -- Adam] -- KNOWN-ISSUES A-8.
    # Which switches the Energy-Saving-App has powered down. Passed straight through so the
    # log check can tell "the proxy cannot read a switch we turned off" (correct) from "the
    # control plane has stopped reading its switches" (the 2026-08-07 defect). Those two
    # produce the same log line, so with no declaration the checker reports
    # TOOL-PRECONDITION-FAILED (exit 3) rather than guessing -- which layer() still counts
    # as a failed layer, but the run says why instead of naming a fault that is not there.
    #   NDT_POWERED_OFF=5,7,9   ./run_layers.sh ...
    #   NDT_POWERED_OFF=none    ./run_layers.sh ...   # assert nothing is off
    local powered_off_args=()
    if [[ -n "${NDT_POWERED_OFF:-}" ]]; then
        powered_off_args=(--powered-off "$NDT_POWERED_OFF")
    fi

    if [[ "$LOG_MARKED" -eq 1 ]]; then
        echo "${D}checking lines 1-$LOG_MARK (before the L2 error-path checks);"
        echo "crashes are still scanned across the whole file${N}"
        "$CONTRACT_DIR/check_logs.py" "$KERNEL_LOG" --to-line "$LOG_MARK" \
            ${powered_off_args[@]+"${powered_off_args[@]}"}
    else
        "$CONTRACT_DIR/check_logs.py" "$KERNEL_LOG" ${powered_off_args[@]+"${powered_off_args[@]}"}
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

# [Co-developed with claude code -- Adam]
# tests/shell/test_run_layers_topology_from_fabric.sh sources this file with
# NDTWIN_RUN_LAYERS_LIB_ONLY=1 to drive the topology selection on fixtures -- no kernel, no
# fabric, no lab claim. Same seam and same name-shape as l1_unit_tests.sh's NDTWIN_L1_LIB_ONLY.
# A selector reachable only by running a whole live round is a selector nobody watches go red,
# which is how L-1 survived for as long as the 128-host model has existed.
[[ -n "${NDTWIN_RUN_LAYERS_LIB_ONLY:-}" ]] && return 0

MODE="${1:-}"
shift || true

case "$MODE" in
    quick)
        layer "L0 build check" run_l0
        layer "L1 unit tests" run_l1 --no-build
        ;;

    api)
        DP="${1:-}"; shift || true
        select_topo "$DP" "$0 api {ovs|p4} [--traffic] [--mutations]"
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
        select_topo "$DP" "$0 baseline {ovs|p4} [--traffic]"
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
        select_topo "$DP" "$0 full {ovs|p4} [--traffic] [--mutations]"
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
