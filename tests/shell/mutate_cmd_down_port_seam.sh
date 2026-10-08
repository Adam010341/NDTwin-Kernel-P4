#!/usr/bin/env bash
#
# Mutation gate for the cmd_down port seam: the probe guard in test_supervise_exit_status.sh and the
# leftovers-branch test in test_cmd_down_leftovers.sh.
#
# [Co-developed with claude code -- Adam]
#
# What is being protected. test_supervise_exit_status.sh stubs ndt_port_open (the probe stack.sh
# cmd_down really calls) so that a listener on the machine cannot redden its ending checks, and a
# guard in it asserts that cmd_down probed the table's (port, proto) pairs through that stub and hit
# none of the four tripwired helpers. test_cmd_down_leftovers.sh runs the real leftovers branch
# against a listener it owns. Neither had ever been seen red from the stack.sh side, and a guard
# nobody has seen fail is a decoration. Each mutation below breaks ONE thing and names the case that
# must go red; a different case going red, or none, counts as SURVIVED.
#
#   M1  the ndt_port_open stub is gone from the supervise test (the test side of the seam)
#   M2  stack.sh calls port_open at the probe site instead of ndt_port_open (the direction of the
#       original defect). It must be caught with a stray count >= 1; note it ALSO empties the
#       probe record, so it would go red even with the port_open tripwire deleted -- M2b is the
#       mutation that isolates the tripwires
#   M2b a real port_open call is ADDED next to the intact ndt_port_open probe: the probe pairs
#       still match, so only the "N stray" part of the guard can catch it
#   M3  stack.sh drops the proto argument (the TCP-only probe that hid :6343); a bare COUNT of
#       probes stays green on this one -- that is why the guard compares pairs
#   M4  the table expands to nothing (0 probes == 0 expected, green without the want_probes>0 check)
#   M5  the leftovers branch returns 0 instead of failing down
#   M6  the ours/stray verdict is inverted (an owned holder is reported as a stranger)
#   M7  port_owner_verdict's identity test becomes "any registered pid is ours" (stack.sh:779);
#       only the registered-but-not-the-holder variant of test_cmd_down_leftovers.sh sees it
#
# Not covered, and said so: a probe added through another route (ss, /dev/tcp, curl) passes the guard.
#
# 🔴 Mutations go on a COPY of the tree pieces in a temp dir (stack.sh, ports.sh, components.env,
# supervise.sh, the two tests, a symlink to tools/contract_test). Each test is run from its copy, so
# its own REPO resolves to the copy and the mutated stack.sh is the one it sources. Nothing under the
# real tree is written; the sha256 line at the bottom covers stack.sh, ports.sh and the two tests.
#
# 🔴 A mutation that does not apply (python fails, or the copy equals the original) is a HARNESS
# error, exit 2 "did not apply" -- not a SURVIVOR, which would claim the guard is blind when nothing
# was mutated.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness / a
#       mutation did not apply / a tool or the temp dir is missing), 3 a file under test changed
#       while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STK="$REPO/tools/test_workflow/stack.sh"
PRT="$REPO/tools/test_workflow/ports.sh"
SUPT="$HERE/test_supervise_exit_status.sh"
LFT="$HERE/test_cmd_down_leftovers.sh"

refuse() { echo "  REFUSED  $1"; echo "Ran 0 checks, 0 failed (refused)"; exit 2; }
for tool in python3 cmp ss ps mktemp sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || refuse "needs $tool and it is not on PATH"
done
BK=$(mktemp -d "${TMPDIR:-/tmp}/cmd-down-seam-mutate-XXXXXX" 2>/dev/null)
[[ -n "$BK" && -d "$BK" ]] || refuse "mktemp -d failed (TMPDIR unwritable?)"
trap 'rm -rf "$BK"' EXIT

sha_all() { sha256sum "$STK" "$PRT" "$SUPT" "$LFT" | cut -d' ' -f1 | tr '\n' ' '; }
BASE_SHA=$(sha_all)

SURVIVORS=0
MUTATIONS=0

# The tree a mutant runs in: just enough of the repo that both tests find what they source.
build_tree() {   # $1 = dir
    local d="$1" tw="$REPO/tools/test_workflow"
    mkdir -p "$d/tools/test_workflow" "$d/tests/shell"
    cp "$tw/stack.sh" "$tw/ports.sh" "$tw/components.env" "$tw/supervise.sh" "$d/tools/test_workflow/"
    chmod +x "$d/tools/test_workflow/supervise.sh"
    cp "$SUPT" "$LFT" "$d/tests/shell/"
    ln -s "$REPO/tools/contract_test" "$d/tools/contract_test"
}

run_test() {   # $1 = tree, $2 = test file name
    env -u STACK_UNDER_TEST -u SUPERVISE_UNDER_TEST timeout 600 bash "$1/tests/shell/$2" 2>&1
}

# $1 = mutation name, $2 = mutant tree, $3 = test file, $4 = case that must fail,
# $5 = optional ERE the output must also match (the guard's own "N stray" text)
report() {
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_test "$2" "$3"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $4" <<<"$out" && { [[ -z "${5:-}" ]] || grep -qE "$5" <<<"$out"; }; then
        printf '  caught   %-62s (%s went red)\n' "$1" "$4"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (%s stayed green, or the expected text was missing -- that case proves nothing)\n' "$1" "$4"
        grep -E '^  FAILED|^Ran |actual:' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; build_tree "$d" || return 2
    local target="$d/${file#"$REPO"/}"
    python3 - "$target" "$old" "$new" <<'PY' || return 2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    # An edit that left the copy byte-identical to the original did not apply.
    cmp -s "$file" "$target" && return 2
    echo "$d"
}
harness_fail() {
    echo "harness: mutation $1 did not apply (anchor drifted or the edit was a no-op); nothing was judged"
    exit 2
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; build_tree "$base"
for t in test_supervise_exit_status.sh test_cmd_down_leftovers.sh; do
    out=$(run_test "$base" "$t"); rc=$?
    printf '  %-34s %s\n' "$t" "$(tail -1 <<<"$out")"
    if [[ $rc -ne 0 ]]; then
        echo "  baseline is RED for $t -- fix that first, mutations prove nothing on a red baseline"
        exit 2
    fi
done
echo

GUARD="cmd_down probes every (port, proto) of the table only through the stubbed ndt_port_open"
STRAYTXT='actual: +[0-9]+ probes, [1-9][0-9]* stray'

m=$(mutant m1 "$SUPT" \
    'ndt_port_open() { echo "$1 ${2:-tcp}" >>"$PROBE_CALLS"; return 1; }' \
    ':') || harness_fail m1
report "M1: the ndt_port_open stub is removed from the test" "$m" test_supervise_exit_status.sh "$GUARD"

m=$(mutant m2 "$STK" \
    'ndt_port_open "$port" "$proto" || continue' \
    'port_open "$port" || continue') || harness_fail m2
report "M2: stack.sh probes with port_open instead of ndt_port_open" "$m" test_supervise_exit_status.sh "$GUARD" "$STRAYTXT"

m=$(mutant m2b "$STK" \
    'ndt_port_open "$port" "$proto" || continue' \
    'port_open "$port" >/dev/null; ndt_port_open "$port" "$proto" || continue') || harness_fail m2b
report "M2b: stack.sh ADDS a port_open call next to the real probe" "$m" test_supervise_exit_status.sh "$GUARD" "$STRAYTXT"

m=$(mutant m3 "$STK" \
    'ndt_port_open "$port" "$proto" || continue' \
    'ndt_port_open "$port" || continue') || harness_fail m3
report "M3: stack.sh drops the proto argument" "$m" test_supervise_exit_status.sh "$GUARD"

m=$(mutant m4 "$PRT" \
    'done <<<"$NDT_PORT_TABLE"' \
    'done <<<""') || harness_fail m4
report "M4: the table expands to nothing" "$m" test_supervise_exit_status.sh \
       "the table expands to at least one probe"

m=$(mutant m5 "$STK" \
    'if (( leftovers > 0 )); then' \
    'if (( leftovers > 0 )); then return 0') || harness_fail m5
report "M5: the leftovers branch returns 0" "$m" test_cmd_down_leftovers.sh \
       "stray: a still-listening port fails down"

m=$(mutant m6 "$STK" \
    '*ours*)' \
    '*stray*)') || harness_fail m6
report "M6: the ours/stray verdict is inverted" "$m" test_cmd_down_leftovers.sh \
       "ours: it says a process this script started holds it, by pid"

m=$(mutant m7 "$STK" \
    'if [[ "$pid" == "$ours" ]]; then' \
    'if [[ -n "$ours" ]]; then') || harness_fail m7
report "M7: any registered pid is called ours (identity test gone)" "$m" test_cmd_down_leftovers.sh \
       "not-holder: it names the real holder and says this script did not start it"

echo
NOW_SHA=$(sha_all)
if [[ "$NOW_SHA" != "$BASE_SHA" ]]; then
    echo "🔴 a file under test CHANGED during the gate"
    echo "   before: $BASE_SHA"
    echo "   after:  $NOW_SHA"
    exit 3
fi
echo "files under test byte-identical: yes  sha256 $BASE_SHA"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
