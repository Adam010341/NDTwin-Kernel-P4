#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndtwin_lab_no_bytecode.sh and
# p4_proxy/tests/test_bridge_writes_no_bytecode.py: root-run Python must not write bytecode.
#
# [Co-developed with claude code -- Adam]
#
# Each mutant takes one switch out of a COPY of ndtwin-lab or of the bridge, and the matching
# suite is pointed at the copy (NDTWIN_LAB_UNDER_TEST / NDTWIN_BRIDGE_UNDER_TEST). Neither real
# file is written; their byte-identity is asserted at the end anyway.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as
# SURVIVOR -- never as skipped.
#
# PYTHON: the interpreter for the bridge suite (default: this checkout's proxy venv if there is one,
# else python3).
#
# Exit: 0 every mutant caught; 1 something survived; 2 refused (harness fault); 3 a subject
# changed underneath the gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAB="$REPO/tools/test_workflow/ndtwin-lab"
BRIDGE_PY="$REPO/p4_proxy/mininet/ntg_bmv2_topo.py"
LINK_TELEMETRY_PY="$REPO/p4_proxy/mininet/link_telemetry.py"
SHELL_TEST="$REPO/tests/shell/test_ndtwin_lab_no_bytecode.sh"
PY_TEST="$REPO/p4_proxy/tests/test_bridge_writes_no_bytecode.py"
[[ -r "$LAB" && -r "$BRIDGE_PY" && -r "$SHELL_TEST" && -r "$PY_TEST" ]] || { echo "refused: a subject or a suite is missing"; exit 2; }
PYTHON="${PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
    PYTHON=python3
    [[ -x "$REPO/p4_proxy/venv/bin/python" ]] && PYTHON="$REPO/p4_proxy/venv/bin/python"
fi

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-nobytecode-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_LAB="$(sha256sum "$LAB" | cut -d' ' -f1)"
BASE_BRIDGE="$(sha256sum "$BRIDGE_PY" | cut -d' ' -f1)"
BASE_LT="$(sha256sum "$LINK_TELEMETRY_PY" | cut -d' ' -f1)"

CAUGHT=0; SURVIVORS=0

shadow_of() {
    local d="$BK/$1"
    mkdir -p "$d"
    cp "$LAB" "$d/ndtwin-lab"
    cp "$BRIDGE_PY" "$d/ntg_bmv2_topo.py"
    # The other files the bridge imports, flat beside the bridge copy: the Python suite takes
    # them from here (NDTWIN_MININET_UNDER_TEST), so a mutant of one of them reaches the probe.
    local f
    for f in p4_testbed_topo topo_log ntg_config topo_from_json grpc_ports app_package link_telemetry psample_sflow_emitter; do
        cp "$REPO/p4_proxy/mininet/$f.py" "$d/$f.py"
    done
    echo "$d"
}

# The two suites, one output stream; the shell suite reads the shadow helper, the Python one the
# shadow bridge. PYTHONDONTWRITEBYTECODE is removed from the Python run's environment (the suite
# builds its probe's environment itself, this is for the test process only).
run_suite() {
    NDTWIN_LAB_UNDER_TEST="$1/ndtwin-lab" timeout 300 bash "$SHELL_TEST" 2>&1
    ( cd "$REPO/p4_proxy" && env -u PYTHONDONTWRITEBYTECODE PYTHONPATH=. \
        NDTWIN_BRIDGE_UNDER_TEST="$1/ntg_bmv2_topo.py" NDTWIN_MININET_UNDER_TEST="$1" timeout 300 "$PYTHON" "$PY_TEST" 2>&1 )
}

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

# $3 is what MUST go red: a shell check's label ("FAILED   <label>") or a unittest name
# ("FAIL: <name> ").
report() {
    local out rc
    if [[ "$2" == ANCHOR-FAILED ]]; then
        printf '  SURVIVED %-62s (anchor did not apply -- not a skip)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    out="$(run_suite "$2")"
    if grep -qF -e "FAILED   $3" -e "FAIL: $3 " -e "ERROR: $3 " <<<"$out"; then
        printf '  caught   %-62s (%s went red)\n' "$1" "$3"; CAUGHT=$((CAUGHT+1))
    elif grep -qE '^(  FAILED   |FAIL: |ERROR: |FAILED \()' <<<"$out"; then
        printf '  SURVIVED %-62s (red, but NOT on the named check)\n' "$1"
        grep -E '^(  FAILED   |FAIL: |ERROR: )' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS+1))
    else
        printf '  SURVIVED %-62s (suites stayed green)\n' "$1"
        SURVIVORS=$((SURVIVORS+1))
    fi
}

echo "baseline (the shadow copies, unmutated -- must be green before any mutation):"
base="$(shadow_of base)"
base_out="$(run_suite "$base")"
echo "$base_out" | grep -E '^(Ran |OK|FAILED \()' | sed 's/^/  /'
if grep -qE '^(  FAILED   |FAIL: |ERROR: |FAILED \()' <<<"$base_out"; then
    echo "  refused: the shadow baseline is RED"; exit 2
fi
echo

echo "mutants -- bytecode must not come back:"

# ---- the helper: one per launch --------------------------------------------------------------
m=$(mutant h1 "$LAB" \
    '/usr/bin/env "NTG_DIR=$NTG_DIR" PYTHONDONTWRITEBYTECODE=1 "$NTG_PY" "$BRIDGE"' \
    '/usr/bin/env "NTG_DIR=$NTG_DIR" "$NTG_PY" "$BRIDGE"')
report "H1: topo-start no longer sets it on the bridge" "$m" \
       "🔴 the bridge's interpreter is started with PYTHONDONTWRITEBYTECODE=1"

m=$(mutant h2 "$LAB" \
    '"$KERNEL_DIR" /usr/bin/env PYTHONDONTWRITEBYTECODE=1 "$NTG_PY" "$script"' \
    '"$KERNEL_DIR" "$NTG_PY" "$script"')
report "H2: ovs-topo-start no longer sets it" "$m" \
       "🔴 the OVS topology's interpreter is started with PYTHONDONTWRITEBYTECODE=1"

m=$(mutant h3 "$LAB" \
    '            /usr/bin/env PYTHONDONTWRITEBYTECODE=1 "$NTG_PY" "$KERNEL_DIR/tools/test_workflow/ovs_4host_topo.py"' \
    '            "$NTG_PY" "$KERNEL_DIR/tools/test_workflow/ovs_4host_topo.py"')
report "H3: ovs-topo-4host no longer sets it" "$m" \
       "🔴 the ovs-topo-4host branch starts the topology with PYTHONDONTWRITEBYTECODE=1"

# Present but empty: Python reads an empty PYTHONDONTWRITEBYTECODE as not set.
m=$(mutant h4 "$LAB" \
    '/usr/bin/env "NTG_DIR=$NTG_DIR" PYTHONDONTWRITEBYTECODE=1 "$NTG_PY" "$BRIDGE"' \
    '/usr/bin/env "NTG_DIR=$NTG_DIR" PYTHONDONTWRITEBYTECODE= "$NTG_PY" "$BRIDGE"')
report "H4: the bridge's variable is present but empty" "$m" \
       "🔴 the bridge's interpreter is started with PYTHONDONTWRITEBYTECODE=1"

# Existence is not wiring: the function is right and the verb root reaches does not call it.
m=$(mutant h5 "$LAB" \
    '        session_running topo && die "topo session already running (topo-stop first)"
        p4_topo_start' \
    '        session_running topo && die "topo session already running (topo-stop first)"
        $TMUX new-session -d -s topo -c "$KERNEL_DIR/p4_proxy/mininet" /usr/bin/env "NTG_DIR=$NTG_DIR" "$NTG_PY" "$BRIDGE"')
report "H5: the topo-start verb inlines a launch without it" "$m" \
       "🔴 the topo-start branch starts the bridge with PYTHONDONTWRITEBYTECODE=1"

m=$(mutant h6 "$LAB" \
    '        ovs_topo_start' \
    '        $TMUX new-session -d -s topo -c "$KERNEL_DIR" "$NTG_PY" "$KERNEL_DIR/testbed_topo.py"')
report "H6: the ovs-topo-start verb inlines a launch without it" "$m" \
       "🔴 the ovs-topo-start branch starts the topology with PYTHONDONTWRITEBYTECODE=1"

# A fourth launch nobody wrote a case for.
m=$(mutant h7 "$LAB" \
    '        echo "OVS 4-host topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)"' \
    '        echo "OVS 4-host topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)"
        $TMUX new-session -d -s extra -c "$KERNEL_DIR" "$NTG_PY" "$KERNEL_DIR/extra.py"')
report "H7: a new interpreter launch without it" "$m" \
       'the helper starts $NTG_PY from 3 places'

# The reason the heartbeat is exempt is -I; take it away and the exemption is gone.
m=$(mutant h8 "$LAB" \
    'hb_run() { "$HB_PYTHON" -I "$HB_PROGRAM" "$1"; }' \
    'hb_run() { "$HB_PYTHON" "$HB_PROGRAM" "$1"; }')
report "H8: a heartbeat launch loses -I" "$m" \
       "  and every one of them is isolated (-I)"

# ---- the bridge: the flag, the variable, the value -------------------------------------------
m=$(mutant b1 "$BRIDGE_PY" \
    'sys.dont_write_bytecode = True
' \
    '')
report "B1: the bridge no longer sets sys.dont_write_bytecode" "$m" \
       "test_importing_the_kernel_modules_and_ntg_writes_no_bytecode_in_either_tree"

m=$(mutant b2 "$BRIDGE_PY" \
    'os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
' \
    '')
report "B2: the bridge no longer sets the variable for its children" "$m" \
       "test_a_python_the_bridge_starts_writes_no_bytecode_either"

m=$(mutant b3 "$BRIDGE_PY" \
    'os.environ["PYTHONDONTWRITEBYTECODE"] = "1"' \
    'os.environ["PYTHONDONTWRITEBYTECODE"] = ""')
report "B3: the bridge sets the variable to the empty string" "$m" \
       "test_a_python_the_bridge_starts_writes_no_bytecode_either"

m=$(mutant b4 "$BRIDGE_PY" \
    'sys.dont_write_bytecode = True' \
    'sys.dont_write_bytecode = False')
report "B4: the bridge sets the flag the wrong way" "$m" \
       "test_importing_the_kernel_modules_and_ntg_writes_no_bytecode_in_either_tree"

# A child that loses the variable on the way: the bridge's own environment still holds "1", so only
# what the emitter wrote can show it.
m=$(mutant b5 "$LINK_TELEMETRY_PY" \
    '        return popen(argv, stdout=handle, stderr=handle)' \
    '        return popen(argv, stdout=handle, stderr=handle, env={"PATH": os.environ.get("PATH", "")})')
report "B5: the emitter's Popen gets an env= without the variable" "$m" \
       "test_a_python_the_bridge_starts_writes_no_bytecode_either"

# The two lines are there but too late: a kernel module is imported above them.
m=$(mutant b6 "$BRIDGE_PY" \
    'import time
' \
    'import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p4_testbed_topo as _early  # noqa: E402
')
report "B6: the two lines sit below an import of p4_testbed_topo" "$m" \
       "test_importing_the_kernel_modules_and_ntg_writes_no_bytecode_in_either_tree"

echo
[[ "$(sha256sum "$LAB" | cut -d' ' -f1)" == "$BASE_LAB" ]] || { echo "🔴 baseline CHANGED -- ndtwin-lab was written during the gate"; exit 3; }
[[ "$(sha256sum "$BRIDGE_PY" | cut -d' ' -f1)" == "$BASE_BRIDGE" ]] || { echo "🔴 baseline CHANGED -- ntg_bmv2_topo.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$LINK_TELEMETRY_PY" | cut -d' ' -f1)" == "$BASE_LT" ]] || { echo "🔴 baseline CHANGED -- link_telemetry.py was written during the gate"; exit 3; }
echo "baselines byte-identical: yes (tools/test_workflow/ndtwin-lab, p4_proxy/mininet/ntg_bmv2_topo.py, p4_proxy/mininet/link_telemetry.py)"
echo "mutation gate: $((CAUGHT+SURVIVORS)) mutations, $CAUGHT caught, $SURVIVORS survived"
[[ $SURVIVORS -eq 0 ]]
