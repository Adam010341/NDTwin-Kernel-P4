#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndtwin_lab_ntg_dir.sh: where the P4 bridge finds NTG.
#
# [Co-developed with claude code -- Adam]
#
# Each mutant puts back one piece of the old behaviour in a COPY of ndtwin-lab or ndt, and the
# suite is pointed at the copy (NDTWIN_LAB_UNDER_TEST / NDT_UNDER_TEST). Neither real file is
# written; their byte-identity is asserted at the end anyway.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutant caught; 1 something survived; 2 refused (harness fault); 3 a subject
# changed underneath the gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAB="$REPO/tools/test_workflow/ndtwin-lab"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$REPO/tests/shell/test_ndtwin_lab_ntg_dir.sh"
[[ -r "$LAB" && -r "$NDT" && -r "$TEST" ]] || { echo "refused: ndtwin-lab, ndt or the suite is missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-ntgdir-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_LAB="$(sha256sum "$LAB" | cut -d' ' -f1)"
BASE_NDT="$(sha256sum "$NDT" | cut -d' ' -f1)"

CAUGHT=0; SURVIVORS=0

# shadow_of <label> -- copies of both subjects, with the two tables ndt sources beside it.
shadow_of() {
    local d="$BK/$1"
    mkdir -p "$d"
    cp "$LAB" "$d/ndtwin-lab"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$d/"
    echo "$d"
}

run_suite() {
    NDTWIN_LAB_UNDER_TEST="$1/ndtwin-lab" NDT_UNDER_TEST="$1/ndt" \
        timeout 300 bash "$TEST" 2>&1
}

# Named parameters, so tests/shell/check_gate_anchors.py can read which argument is the file and
# which is the anchor.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d
    d="$(shadow_of "$label")"
    python3 - "$d/${file##*/}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(a) != 1:
    sys.stderr.write("anchor not unique (%d hits): %s\n" % (s.count(a), a[:70]))
    sys.exit(3)
open(p, "w").write(s.replace(a, b, 1))
PY
    [[ $? -eq 0 ]] || { echo "ANCHOR-FAILED"; return 0; }
    echo "$d"
}

report() {   # $1 = label, $2 = shadow dir, $3 = the check that MUST go red
    local out rc
    if [[ "$2" == ANCHOR-FAILED ]]; then
        printf '  SURVIVED %-60s (anchor did not apply -- not a skip)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    out="$(run_suite "$2")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED %-60s (suite stayed green)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    if grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-60s (%s went red)\n' "$1" "$3"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-60s (red, but NOT on the named check)\n' "$1"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS+1))
    fi
}

echo "baseline (the shadow copies, unmutated -- must be green before any mutation):"
base="$(shadow_of base)"
run_suite "$base" | tail -1 | sed 's/^/  /'
run_suite "$base" >/dev/null 2>&1 || { echo "  refused: the shadow baseline is RED"; run_suite "$base" | grep FAILED | head -5; exit 2; }
echo

echo "mutants -- the old behaviour must not come back:"

# The defect itself: the bridge is launched with nothing that carries NTG_DIR.
m=$(mutant m1 "$LAB" \
    '        /usr/bin/env "NTG_DIR=$NTG_DIR" "$NTG_PY" "$BRIDGE"' \
    '        "$NTG_PY" "$BRIDGE"')
report "M1: topo-start no longer hands the bridge NTG_DIR" "$m" \
       "🔴 the program started in the pane sees the configured NTG_DIR"

# The config file has no key for it, so the only way to move NTG is an env var nobody can pass.
m=$(mutant m2 "$LAB" \
    '            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR|NTG_DIR) ;;' \
    '            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR) ;;')
report "M2: the parser no longer accepts an NTG_DIR key" "$m" \
       "🔴 a config with an NTG_DIR line is adopted"

# The env override this whole design refuses, applied to the new key.
m=$(mutant m3 "$LAB" \
    'NTG_DIR=$LAB_DEFAULT_NTG_DIR' \
    'NTG_DIR="${NTG_DIR:-$LAB_DEFAULT_NTG_DIR}"')
report "M3: the caller's environment chooses NTG_DIR" "$m" \
       "🔴 an exported NTG_DIR is replaced by the helper's own value"

# A refusal that does not fire: the pane starts and dies, and ndt up waits 180 s.
m=$(mutant m4 "$LAB" \
    'ntg_dir_usable() { [[ -d "$NTG_DIR" && -f "$NTG_DIR/network_traffic_generator.py" ]]; }' \
    'ntg_dir_usable() { true; }')
report "M4: a path that is not NTG is launched anyway" "$m" \
       "rc is non-zero"

# Half of the check: a directory is enough. $HOME typed for the checkout would pass.
m=$(mutant m5 "$LAB" \
    'ntg_dir_usable() { [[ -d "$NTG_DIR" && -f "$NTG_DIR/network_traffic_generator.py" ]]; }' \
    'ntg_dir_usable() { [[ -d "$NTG_DIR" ]]; }')
report "M5: any directory counts as an NTG checkout" "$m" \
       "a directory without network_traffic_generator.py is refused too"

# A refused config file that leaves its NTG_DIR behind.
m=$(mutant m6 "$LAB" \
    '    NTG_DIR="$LAB_DEFAULT_NTG_DIR"
    LAB_CONF_SOURCE="built-in defaults ($conf was REFUSED)"' \
    '    LAB_CONF_SOURCE="built-in defaults ($conf was REFUSED)"')
report "M6: a refused config does not put NTG_DIR back" "$m" \
       "🔴 a refused config file leaves NTG_DIR at the default"

# Existence is not wiring: the function is right and the verb root reaches does not call it.
m=$(mutant m7 "$LAB" \
    '        session_running topo && die "topo session already running (topo-stop first)"
        p4_topo_start' \
    '        session_running topo && die "topo session already running (topo-stop first)"
        $TMUX new-session -d -s topo -c "$KERNEL_DIR/p4_proxy/mininet" "$NTG_PY" "$BRIDGE"')
report "M7: the verb inlines the old launch again" "$m" \
       "🔴 the topo-start branch hands the bridge NTG_DIR"

# The read-only copy in ndt drifts from the helper: same file, two readings.
m=$(mutant m8 "$NDT" \
    '            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR|NTG_DIR) ;;' \
    '            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR) ;;')
report "M8: ndt's copy of the parser does not know NTG_DIR" "$m" \
       "🔴 ndt reads KERNEL_DIR out of a config that has NTG_DIR in it"

# The default moves: a machine with no config file no longer runs what it ran before.
m=$(mutant m9 "$LAB" \
    'LAB_DEFAULT_NTG_DIR=/home/adam/Network-Traffic-Generator' \
    'LAB_DEFAULT_NTG_DIR=/opt/Network-Traffic-Generator')
report "M9: the built-in default is not the bridge's old value" "$m" \
       "the built-in default is the value the bridge used to carry"

echo
[[ "$(sha256sum "$LAB" | cut -d' ' -f1)" == "$BASE_LAB" ]] || { echo "🔴 baseline CHANGED -- ndtwin-lab was written during the gate"; exit 3; }
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baselines byte-identical: yes (tools/test_workflow/ndtwin-lab, tools/test_workflow/ndt)"
echo "mutation gate: $((CAUGHT+SURVIVORS)) mutations, $CAUGHT caught, $SURVIVORS survived"
[[ $SURVIVORS -eq 0 ]]
