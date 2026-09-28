#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_p4_capabilities_wired.sh.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation below puts back one way the pingWorker -> pollP4SwitchState -> fetchP4SwitchState
# wiring can come apart, and must turn its named check red. W1 is the one that matters: the old
# direct-fetch block restored in pingWorker, which compiles, keeps bmv2 liveness working and stops
# every node from carrying `capabilities` (doc/2026-01-02_ndt_api.md section 3).
#
#   W1  the old direct-fetch block is back in pingWorker                (red: check 2)
#   W2  a second caller of fetchP4SwitchState elsewhere in the class    (red: check 1)
#   W3  the call to pollP4SwitchState() survives only as a comment      (red: check 2)
#   W4  the liveness verdicts are fed a fresh fetch, not the answer     (red: check 3)
#   C1  control: a comment in pingWorker that names both functions      (must stay green)
#
# W3 and C1 are why the check strips comments: a grep for "pollP4SwitchState()" is satisfied by
# the comment in W3, and a grep for "fetchP4SwitchState(" is tripped by the comment in C1.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY of src/ and include/ under a temp
# dir, and the check is pointed there with P4CAPS_WIRING_ROOT. Nothing in the tree is written --
# another session may be building it -- and the mutated file is re-hashed at the end.
#
# Usage:  bash tests/shell/mutate_p4_capabilities_wired.sh
# Exit:   0 every mutation caught and the control green, 1 otherwise, 2 refused (red baseline).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DCPM="$REPO/src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp"
TEST="$REPO/tests/shell/test_p4_capabilities_wired.sh"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-p4caps-wired-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_DCPM=$(sha256sum "$DCPM" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0
CONTROL_RED=0

run_against() {   # $1 = a tree root
    P4CAPS_WIRING_ROOT="$1" bash "$TEST" 2>&1
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can tell the anchor from the file.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/src" "$REPO/include" "$d/"
    python3 - "$d/${file#"$REPO/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

report() {   # $1 = label, $2 = mutant dir, $3 = the check that must go red ("-" = control)
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$3" == "-" ]]; then
        if [[ "$rc" -eq 0 ]]; then
            printf '  control  %-66s (stayed green)\n' "$1"
        else
            CONTROL_RED=$((CONTROL_RED+1))
            printf '  🔴 CONTROL WENT RED %-56s\n' "$1"
            sed 's/^/             /' <<<"$out"
        fi
        return
    fi
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$rc" -ne 0 ]] && grep -qF "  FAILED   $3" <<<"$out"; then
        printf '  caught   %-66s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (%s stayed green)\n' "$1" "$3"
        sed 's/^/             /' <<<"$out"
    fi
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; cp -r "$REPO/src" "$REPO/include" "$base/"
run_against "$base" | tail -1 | sed 's/^/  /'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first"; exit 2; }
echo

C1="fetchP4SwitchState is called from exactly one place, inside pollP4SwitchState"
C2="pingWorker takes its bmv2 evidence from pollP4SwitchState()"
C3="the liveness verdicts read the answer pollP4SwitchState() returned"

m=$(mutant w1 "$DCPM" \
    '        const std::optional<json> p4SwitchState = pollP4SwitchState();' \
    '        std::optional<json> p4SwitchState;
        if (m_mode == utils::DeploymentMode::MININET && dataPlaneIsBmv2())
        {
            p4SwitchState = fetchP4SwitchState();
        }')
report "W1: the old direct-fetch block is back in pingWorker" "$m" "$C2"

m=$(mutant w2 "$DCPM" \
    '    m_dataPlaneKindDetermined.store(true);' \
    '    m_dataPlaneKindDetermined.store(true);
    (void)fetchP4SwitchState();')
report "W2: a second caller of fetchP4SwitchState in the class" "$m" "$C1"

m=$(mutant w3 "$DCPM" \
    '        const std::optional<json> p4SwitchState = pollP4SwitchState();' \
    '        const std::optional<json> p4SwitchState = std::nullopt; // = pollP4SwitchState();')
report "W3: the call to pollP4SwitchState() survives only in a comment" "$m" "$C2"

m=$(mutant w4 "$DCPM" \
    '                        switch (p4VerdictFor(swName, graph[v].dpid, p4SwitchState))' \
    '                        switch (p4VerdictFor(swName, graph[v].dpid, fetchP4SwitchState()))')
report "W4: the liveness verdicts are fed a fresh fetch, not the answer" "$m" "$C3"

m=$(mutant c1 "$DCPM" \
    '        const std::optional<json> p4SwitchState = pollP4SwitchState();' \
    '        // Not fetchP4SwitchState() here: pollP4SwitchState() both records and returns it.
        const std::optional<json> p4SwitchState = pollP4SwitchState();')
report "C1 (control): a comment in pingWorker naming both functions" "$m" "-"

echo
if [[ "$(sha256sum "$DCPM" | cut -d' ' -f1)" != "$BASE_DCPM" ]]; then
    echo "🔴 $DCPM changed during the gate"
    exit 1
fi
echo "  $(basename "$DCPM") byte-identical: yes"
if [[ "$SURVIVORS" -eq 0 && "$CONTROL_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; control green"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROL_RED control(s) red"
exit 1
