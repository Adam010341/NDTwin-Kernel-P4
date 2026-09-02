#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_harness_instruments.sh.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen red is not a test. Each mutation below reintroduces ONE of the
# defects the T-9/T-10 round fixed -- verbatim, in the construct the original used -- and this
# script asserts that the suite goes red for it. A mutation that leaves the suite green names a
# check that is decorative, and is reported as `SURVIVED`.
#
# The mutations are applied to a COPY of the harness in a mktemp sandbox laid out with the same
# relative shape, because the suite resolves its targets as $HERE/../../doc/audit/... . The files
# in the worktree are never written to, and nothing here goes near the lab.
#
# Run:  bash tests/shell/mutate_harness_instruments.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
HARNESS_REL="doc/audit/2026-08-30_live-full-stack-round/harness"
SUITE_REL="tests/shell/test_harness_instruments.sh"

KILLED=0
SURVIVED=0

# build_sandbox -- a fresh copy of exactly the files the suite reads. Echoes the sandbox root.
build_sandbox() {
    local sb; sb="$(mktemp -d)"
    mkdir -p "$sb/$HARNESS_REL" "$sb/tests/shell"
    cp "$REPO_ROOT/$HARNESS_REL/lib.sh" \
       "$REPO_ROOT/$HARNESS_REL/20_apps_lifecycle.sh" \
       "$REPO_ROOT/$HARNESS_REL/25_apps_energy.sh" "$sb/$HARNESS_REL/"
    cp "$REPO_ROOT/$SUITE_REL" "$sb/tests/shell/"
    printf '%s' "$sb"
}

# mutate <name> <file-relative-to-harness> <python-mutation-expression>
#
# The mutation is a python snippet given the file text as `s` and expected to rebind `s`. It MUST
# change the text: a no-op mutation would report KILLED or SURVIVED about nothing, which is the
# failure mode this repo calls "the instrument looking like its own finding".
mutate() {
    local name="$1" rel="$2" expr="$3"
    local sb; sb="$(build_sandbox)"
    local target="$sb/$HARNESS_REL/$rel"
    [[ "$rel" == "SUITE" ]] && target="$sb/$SUITE_REL"

    if ! python3 - "$target" "$expr" <<'PY'
import sys
path, expr = sys.argv[1], sys.argv[2]
s = open(path).read()
before = s
ns = {"s": s}
exec(expr, ns)
s = ns["s"]
if s == before:
    sys.stderr.write("MUTATION DID NOT CHANGE THE FILE\n")
    sys.exit(2)
open(path, "w").write(s)
PY
    then
        echo "  ERROR    $name -- the mutation did not apply; the construct it targets has moved"
        SURVIVED=$((SURVIVED + 1))
        rm -rf "$sb"
        return
    fi

    local rc=0
    bash "$sb/$SUITE_REL" > "$sb/out.log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "  KILLED   $name   (suite rc=$rc, $(grep -c '^  FAILED' "$sb/out.log") check(s) red)"
        KILLED=$((KILLED + 1))
    else
        echo "  SURVIVED $name   -- the suite stayed GREEN with this defect present"
        SURVIVED=$((SURVIVED + 1))
    fi
    rm -rf "$sb"
}

echo
echo "=== mutations: FINDING-02 Defect B, port_holder collapses back to two values ==="

mutate "port_holder returns '' for a hidden owner (the 08-30 defect, verbatim)" lib.sh '
s = s.replace("printf \x27%s\x27 \"$PORT_HOLDER_HIDDEN\"", "printf \x27\x27")
'

mutate "the sentinel becomes numeric, so a forgetful caller fails silently" lib.sh '
s = s.replace("PORT_HOLDER_HIDDEN=\x27LISTENER-OWNER-HIDDEN\x27", "PORT_HOLDER_HIDDEN=\x270\x27")
'

mutate "assert_port_is scores the hidden state as a pass instead of N/A" lib.sh '
s = s.replace("        skip \"$label: :$port HAS a listener", "        ok \"$label: :$port HAS a listener")
'

echo
echo "=== mutations: FINDING-05, the window compares nothing again ==="

mutate "the span gate is removed from the phase (back to info-only)" 25_apps_energy.sh '
s = s.replace("assert_window_span energy_watch", "info energy_watch_span_was")
'

mutate "OVERRUN downgraded from a verdict to a printed line" lib.sh '
s = s.replace("            bad \"$label window OVERRUN", "            info \"$label window OVERRUN")
'

mutate "UNDERRUN given a tolerance, so a shortened window passes" lib.sh '
s = s.replace("if   (( delta < 0 ));    then verdict=UNDERRUN", "if   (( delta < -60 ));  then verdict=UNDERRUN")
'

mutate "the span artefact is written only when the verdict is OK" lib.sh '
s = s.replace("    } > \"$OUT/${label}_span.tsv\"",
              "    } > \"$OUT/${label}_span.tsv\"\n    [[ \"$verdict\" == OK ]] || rm -f \"$OUT/${label}_span.tsv\"")
'

mutate "the registered value is dropped from the artefact" lib.sh '
s = s.replace("\"$label\" \"$registered\" \"$actual\"", "\"$label\" \"-\" \"$actual\"")
'

echo
echo "=== mutations: FINDING-02 Defect A / FINDING-05, the defect SHAPES come back ==="

mutate "viz uses a loop counter as a clock again (T0 + i)" 20_apps_lifecycle.sh '
s = s.replace("then VIZ_T=\"$(date +%s)\"; break; fi", "then VIZ_T=$(( T0 + i )); break; fi")
'

mutate "the watch loop counts iterations again instead of seconds" 25_apps_energy.sh '
s = s.replace("while :; do", "for i in $(seq 0 $(( WATCH_S / 10 ))); do", 1)
'

mutate "mark_start stops reading the clock, so the own column collapses into sequencing" 20_apps_lifecycle.sh '
s = s.replace("mark_start() { T_START[$1]=\"$(date +%s)\"; }", "mark_start() { T_START[$1]=\"$T0\"; }")
'

mutate "the degraded banner loses its gate and lights unconditionally" 25_apps_energy.sh '
s = s.replace("if (( POWERED_OFF > 0 )); then\n    info ", "if true; then\n    info ")
'

echo
echo "===== $((KILLED + SURVIVED)) mutation(s): $KILLED killed, $SURVIVED survived ====="
[[ "$SURVIVED" -eq 0 ]]
