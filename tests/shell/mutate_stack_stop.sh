#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_stack_stop.sh -- `stack.sh stop <name>...`.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation takes one property of the verb away and must turn its NAMED case red:
#   S1  stops every component whatever it was given (the verb is `down` under another name)
#   S2  a name that is not a component is skipped, so the valid ones beside it are stopped
#   S3  no sweep: the stale registry of a component that was not named is left
#   S4  stop_one's refusal (a symlinked pidfile, a recycled number) is swallowed: rc 0
#   S5  the port table is read, as `down` reads it
#   S6  a component that ended on a fatal signal is reported and the command still succeeds
#   S7  no name at all is a success
#   S8  the dispatch runs `down`
# N1 is the widening: the verb prints "stopped" and signals nothing. W1/W2 change no behaviour and the
# suite must stay green.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is pointed at
# them with STACK_UNDER_TEST. tools/test_workflow/stack.sh is never written, and the sha256 line at
# the bottom says so.
#
# 🔴 A mutant directory carries components.env, ports.sh and supervise.sh too: stack.sh sources the
# first two from beside itself, so a copy without them dies at source time and every case goes red for
# the wrong reason.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation behaved as declared, 1 one did not, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="$REPO/tools/test_workflow/stack.sh"
TEST="$HERE/test_stack_stop.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/stack-stop-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_STACK=$(sha256sum "$STACK" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { STACK_UNDER_TEST="$1/stack.sh" timeout 600 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        if [[ -f "$2/.unapplied" ]]; then
            printf '  SURVIVED %-58s (anchor could not be applied)\n' "$1"
            sed 's/^/             /' "$2/.apply.err"
        else
            printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        fi
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

report_green() {   # $1 = mutation name, $2 = mutant dir, $3 = why it changes nothing
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-58s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        if [[ -f "$2/.unapplied" ]]; then
            printf '  RED      %-58s (anchor could not be applied, so this red is about nothing)\n' "$1"
            sed 's/^/             /' "$2/.apply.err"
        else
            printf '  RED      %-58s (behaviour is unchanged, so this is the suite reading text)\n' "$1"
        fi
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$STACK" "$d/stack.sh"; chmod +x "$d/stack.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/supervise.sh" "$d/supervise.sh"
    if ! python3 - "$d/$(basename "$file")" "$old" "$new" > "$d/.apply.err" 2>&1 <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        printf 'ANCHOR-NOT-APPLIED %s\n' "$label" > "$d/.unapplied"
    fi
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$STACK" "$base/stack.sh"; chmod +x "$base/stack.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/supervise.sh" "$base/supervise.sh"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# S1: the loop over the names becomes the loop `down` runs. Every case that asks "the others keep
# running" goes red; the ones that only ask whether the named one stopped stay green.
m=$(mutant s1 "$STACK" \
    '    for name in "$@"; do stop_one "$name" || rc=1; done' \
    '    for name in kernel p4_proxy ryu; do stop_one "$name" || rc=1; done')
report "S1: stop stops every component, whatever it was given" "$m" \
       "🔴 the kernel is still running"

# S2: the validation does not refuse. The valid name beside the bad one is stopped, and the exit
# status is whatever the stops gave.
m=$(mutant s2 "$STACK" \
    '               return 2 ;;
        esac' \
    '               continue ;;
        esac')
report "S2: an unknown name is noted and the rest is stopped anyway" "$m" \
       "🔴 and the valid one was not stopped either"

# S3: the sweep of the endings stop_one cannot reach is gone.
m=$(mutant s3 "$STACK" \
    '    sweep_orphan_exits
    if [[ -n "$STACK_FATAL_ENDINGS" ]]; then
        err "  a component' \
    '    if [[ -n "$STACK_FATAL_ENDINGS" ]]; then
        err "  a component')
report "S3: the stale registry of a component that was not named stays" "$m" \
       "🔴 a dead component that was not named has its stale registry cleared, and it says so"

# S4: stop_one's refusal is swallowed.
m=$(mutant s4 "$STACK" \
    '    for name in "$@"; do stop_one "$name" || rc=1; done' \
    '    for name in "$@"; do stop_one "$name"; done')
report "S4: a refusal by stop_one (a symlinked pidfile) is rc 0" "$m" \
       "🔴 a symlinked pidfile is refused: rc 1"

# S5: the verb reads a port, as `down` does for every row of the table.
m=$(mutant s5 "$STACK" \
    '    sweep_orphan_exits
    if [[ -n "$STACK_FATAL_ENDINGS" ]]; then
        err "  a component' \
    '    ndt_port_open 8081 tcp
    sweep_orphan_exits
    if [[ -n "$STACK_FATAL_ENDINGS" ]]; then
        err "  a component')
report "S5: stop reads the port table" "$m" \
       "🔴 no port was read"

# S6: a fatal ending is reported and the command still succeeds.
m=$(mutant s6 "$STACK" \
    '        err "  a component the command stopped crashed or had to be killed rather than stopping: $STACK_FATAL_ENDINGS"
        rc=1' \
    '        err "  a component the command stopped crashed or had to be killed rather than stopping: $STACK_FATAL_ENDINGS"')
report "S6: a component that crashed on its way out does not fail the command" "$m" \
       "🔴 and fails the command"

# S7: no name is a success.
m=$(mutant s7 "$STACK" \
    '        err "usage: stack.sh stop <name>...   (kernel, p4_proxy, ryu)"
        return 2' \
    '        err "usage: stack.sh stop <name>...   (kernel, p4_proxy, ryu)"
        return 0')
report "S7: stop with no name exits 0" "$m" \
       "no name at all: rc 2"

# S8: the dispatch runs `down`.
m=$(mutant s8 "$STACK" \
    '    stop)   shift; cmd_stop "$@" ;;' \
    '    stop)   shift; cmd_down ;;')
report "S8: the stop command is wired to down" "$m" \
       "🔴 the kernel is still running"

# N1 (widening): the verb says it stopped the component and signals nothing. Every message the
# suite could read at a glance is still there.
m=$(mutant n1 "$STACK" \
    '    for name in "$@"; do stop_one "$name" || rc=1; done' \
    '    for name in "$@"; do info "  stopped $name"; done')
report "N1 (widening): stop prints 'stopped' and stops nothing" "$m" \
       "🔴 the proxy process is gone"

# W1 (behaviour-preserving): the usage line is reworded.
m=$(mutant w1 "$STACK" \
    '        err "usage: stack.sh stop <name>...   (kernel, p4_proxy, ryu)"' \
    '        err "usage: stack.sh stop <name> [<name>...]   (kernel, p4_proxy or ryu)"')
report_green "W1 (behaviour-preserving): the usage line reworded" "$m" \
       "the suite asserts the word usage, not the sentence"

# W2 (behaviour-preserving): the empty-argument test in the other syntax.
m=$(mutant w2 "$STACK" \
    '    if (( $# == 0 )); then' \
    '    if [[ $# -eq 0 ]]; then')
report_green "W2 (behaviour-preserving): the argument count tested with [[ ]]" "$m" \
       "the same condition spelled differently"

echo
NOW_STACK=$(sha256sum "$STACK" | cut -d' ' -f1)
if [[ "$NOW_STACK" != "$BASE_STACK" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/stack.sh was written"
    echo "   before: $BASE_STACK"
    echo "   after:  $NOW_STACK"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/stack.sh  sha256 $BASE_STACK"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
