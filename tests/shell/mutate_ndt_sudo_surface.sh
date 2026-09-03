#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_sudo_surface.sh.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of the defect the sudo table replaces, and must turn its
# named case red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Two directions, because one is not enough here. Every "a refusal must not read as a
# measurement" case is ALSO satisfied by an implementation that answers "cannot tell" to
# everything -- and that implementation makes `ndt up p4` impossible to run on any machine.
# The mutations labelled (control) are that implementation in four shapes, and each must turn a
# control case red. A gate with only the first kind would sign off on a tool that refuses every
# bring-up, which is a worse product than the one this change started from.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with SURFACE_UNDER_TEST / NDT_UNDER_TEST. The files in tools/test_workflow are
# never written -- another session may be executing them right now.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SURFACE="$REPO/tools/test_workflow/sudo_surface.sh"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_sudo_surface.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-sudo-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SURFACE=$(sha256sum "$SURFACE" | cut -d' ' -f1)
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { SURFACE_UNDER_TEST="$1/sudo_surface.sh" NDT_UNDER_TEST="$1/ndt" timeout 300 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole directory: ndt sources sudo_surface.sh from beside itself, so both files
# travel together and a mutation to either is exercised through the real seam. The anchor must
# be unique, so a mutation cannot quietly land somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py
# can read this gate: it learns which argument is the anchor and which is the file from a
# function's own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it
# is not checking (finding #28 -- two gates written the same night extracted zero anchors and
# nobody would have known).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$SURFACE" "$d/sudo_surface.sh"; cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    # ndt also sources ports.sh from beside itself (fix/ports-that-block-restart); ship it, unmutated.
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$SURFACE" "$base/sudo_surface.sh"; cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself: a refusal arriving as a value -------------------------------------------

m=$(mutant m1 "$NDT" \
    '    out="$(ndt_sudo_capture ovs-vsctl list-br)" || return 2' \
    '    out="$(sudo -n ovs-vsctl list-br 2>/dev/null)" || true')
report "M1: ovs_bridge_count discards sudo's exit status again" "$m" \
       "refused: ovs_bridge_count returns 2 and prints no number"

m=$(mutant m2 "$SURFACE" \
    '    return "$rc"' \
    '    return 0')
report "M2: ndt_sudo_capture throws sudo's exit status away" "$m" \
       "refused: ovs_bridge_count returns 2 and prints no number"

m=$(mutant m3 "$NDT" \
    '    if (( brc != 0 )); then' \
    '    if false; then')
report "M3: the guard reads 'could not tell' as 'nothing there'" "$m" \
       "refused: the guard stops the bring-up"

m=$(mutant m4 "$NDT" \
    '            NDT_DATAPLANE_WHY="sudo refused mnexec"' \
    '            return 1')
report "M4: a refusal is reported as 'does not forward' again" "$m" \
       "refused: dataplane_ok returns 2 (not tested), and says why"

m=$(mutant m5 "$SURFACE" \
    '        *"a password is required"*)                       return 0 ;;' \
    '        *"NEVER-MATCHES-THIS"*)                           return 0 ;;')
report "M5: the classifier stops recognising sudo's measured wording" "$m" \
       "refused: dataplane_ok returns 2 (not tested), and says why"

m=$(mutant m6 "$SURFACE" \
    '    NDT_SUDO_STDERR="$(cat "$errfile" 2>/dev/null)"' \
    '    NDT_SUDO_STDERR=""')
report "M6: the exit status is kept but the message is dropped" "$m" \
       "refused: dataplane_ok returns 2 (not tested), and says why"

# --- the table: the part that stops the NEXT sudo call from repeating this -----------------------

m=$(mutant m7 "$SURFACE" \
    'mnexec|mnexec -a 1 true' \
    'NOPE-mnexec|mnexec -a 1 true')
report "M7: the mnexec row leaves the table (a call with no row again)" "$m" \
       "every privileged command ndt names has a row (nothing new can go unlisted)"

m=$(mutant m8 "$SURFACE" \
    'ALL=(root) NOPASSWD: %s' \
    'needs root for %s')
report "M8: explain() names the problem but not the line that fixes it" "$m" \
       "explain() prints the sudoers line that fixes it"

# --- the wiring: the callers must READ the table, not keep a copy ---------------------------------

m=$(mutant m9 "$NDT" \
    '        guard_no_live_ovs || return 1' \
    '        :')
report "M9: up_p4 stops asking the guard" "$m" \
       "up_p4 asks guard_no_live_ovs"

m=$(mutant m10 "$NDT" \
    '    local sudo_report; sudo_report="$(ndt_sudo_report)"; local src=$?' \
    '    local sudo_report=""; local src=0')
report "M10: cmd_status --check stops reading the sudo table" "$m" \
       "cmd_status --check reads ndt_sudo_report"

# --- 🔴 the other direction: refuse-everything, in four shapes -------------------------------------
# Every one of these passes all ten mutations above. They are caught only by the controls, and
# without them this gate would sign off on an `ndt` that can never bring a fabric up at all.

m=$(mutant n1 "$NDT" \
    '    out="$(ndt_sudo_capture ovs-vsctl list-br)" || return 2' \
    '    out="$(ndt_sudo_capture ovs-vsctl list-br)"; return 2')
report "N1 (control): ovs_bridge_count always says 'cannot tell'" "$m" \
       "control, permitted: ovs_bridge_count returns 0 and the real count"

m=$(mutant n2 "$NDT" \
    '    topo_session || return 0' \
    '    topo_session && return 1
    return 0')
report "N2 (control): the guard refuses whenever a topo session exists" "$m" \
       "control, permitted and no bridges: the guard PASSES and the bring-up proceeds"

m=$(mutant n3 "$NDT" \
    '    ovs_daemon_running                   || { echo 0; return 0; }' \
    '    :')
report "N3 (control): no unprivileged early-out, so a P4-only machine cannot start" "$m" \
       "control, no ovs-vswitchd: a definite 0, answered without sudo"

m=$(mutant n4 "$NDT" \
    '    sudo -n mnexec -a "$pid" ping -c 2 -W 2 -q "$2" >/dev/null 2>&1 || return 1' \
    '    return 2')
report "N4 (control): dataplane_ok never tests, so a real outage is never seen" "$m" \
       "control, permitted and the ping really fails: 'not forwarding' is still said"

echo
[[ "$(sha256sum "$SURFACE" | cut -d' ' -f1)" == "$BASE_SURFACE" ]] || { echo "🔴 baseline CHANGED -- sudo_surface.sh was written during the gate"; exit 3; }
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (sudo_surface.sh and ndt)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
