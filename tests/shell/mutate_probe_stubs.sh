#!/usr/bin/env bash
#
# Mutation gate for the probe stubs of six suites (tests/shell/lib_probe_stub.sh): each suite's
# own sudo records every call and refuses it, and its closing check fails on a call outside the
# suite's allow-list. A closing check that cannot fail would make the allow-list decoration, so
# each mutation takes ONE entry out of one suite's allow-list -- a call the suite really makes --
# and that suite's closing check must go red. P8 removes a stub altogether: the closing check must
# say the stub is not there, never read an empty call list as clean.
#
# [Co-developed with claude code -- Adam]
#
# A mutant is a copy of the suite BESIDE it (tests/shell/.mutant-<label>-<suite>), so its HERE and
# every path it derives are the suite's own; the copy is removed after its run and on exit. A
# mutation that does not apply (the anchor is not exactly once in the suite) is a SURVIVOR, never a
# skip. The baseline -- every suite green, its closing check ok -- must hold first.
#
# Usage: bash tests/shell/mutate_probe_stubs.sh
# Exit:  0 every mutation caught; 1 a mutation survived; 2 refused (baseline red / harness)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_STOP="$HERE/test_apps_stop_kills_the_group.sh"
APP_ORPHANS="$HERE/test_ndt_app_orphans.sh"
CELL_GATE="$HERE/test_cell_gate_suspect_wiring.sh"
LAB_HANDOFF="$HERE/test_lab_handoff.sh"
HONESTY="$HERE/test_ndt_honesty.sh"
SAMPLE_RATE="$HERE/test_ndt_sample_rate_reads_both_bounds.sh"
CLOSING="🔴 every sudo went to this suite's stub and was an allow-listed read-only probe"
trap 'rm -f "$HERE"/.mutant-*-test_*.sh' EXIT
SURVIVORS=0; MUTATIONS=0

echo "baseline (every suite green, its closing check ok):"
for s in "$APPS_STOP" "$APP_ORPHANS" "$CELL_GATE" "$LAB_HANDOFF" "$HONESTY" "$SAMPLE_RATE"; do
    out="$(timeout 900 bash "$s" < /dev/null 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]] || ! /usr/bin/grep -E '^ *ok ' <<<"$out" | /usr/bin/grep -qF -- "$CLOSING"; then
        echo "  refused: $(basename "$s") is not green with its closing check ok (rc $rc)"; exit 2
    fi
    echo "  ok       $(basename "$s"): $(tail -1 <<<"$out")"
done

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
mutant() {   # $1 = label, $2 = file (the suite), $3 = the anchor, $4 = its replacement -> the copy
    local label="$1" file="$2" old="$3" new="$4"
    local copy="$HERE/.mutant-$label-$(basename "$file")"
    python3 - "$file" "$copy" "$old" "$new" <<'PY'
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src).read()
if s.count(a) != 1:
    print("ANCHOR:%d" % s.count(a)); sys.exit(0)
open(dst, "w").write(s.replace(a, b, 1)); print(dst)
PY
}
report() {   # $1 = mutation name, $2 = the copy (or ANCHOR:n)
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == ANCHOR:* ]]; then
        SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (anchor occurrences: %s)\n' "$1" "${2#ANCHOR:}"; return
    fi
    out="$(timeout 900 bash "$2" < /dev/null 2>&1)"; rc=$?; rm -f "$2"
    if [[ $rc -ne 0 ]] && /usr/bin/grep -E '^ *FAILED ' <<<"$out" | /usr/bin/grep -qF -- "$CLOSING"; then
        printf '  caught   %-66s (the closing check went red: %s)\n' "$1" \
            "$(/usr/bin/grep -A2 -F -- "$CLOSING" <<<"$out" | /usr/bin/grep -oE '(actual: *\[[^]]*\]|outside the allow-list: .*)' | head -1 | cut -c1-80)"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (rc %s; the closing check did not go red)\n' "$1" "$rc"
    fi
}

echo
echo "mutations (one allow-list entry out of one suite):"
m=$(mutant p1 "$APPS_STOP" "probe_stub_install \"\$TMPROOT\" -- 'sudo ndtwin-lab status'" \
    "probe_stub_install \"\$TMPROOT\" --")
report "P1: apps_stop no longer allows 'ndtwin-lab status'" "$m"
m=$(mutant p2 "$APP_ORPHANS" "probe_stub_install \"\$TMPROOT\" -- 'sudo ndtwin-lab status'" \
    "probe_stub_install \"\$TMPROOT\" --")
report "P2: app_orphans no longer allows 'ndtwin-lab status'" "$m"
m=$(mutant p3 "$CELL_GATE" "'sudo ndtwin-lab status' 'sudo ndtwin-lab topo-out *'" \
    "'sudo ndtwin-lab status'")
report "P3: cell_gate no longer allows 'ndtwin-lab topo-out N'" "$m"
m=$(mutant p4 "$LAB_HANDOFF" "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'" \
    "'sudo ndtwin-lab status' 'sudo mnexec -a 1 true' 'tc qdisc show'")
report "P4: lab_handoff no longer allows 'ovs-vsctl list-br'" "$m"
m=$(mutant p5 "$HONESTY" "probe_stub_install \"\$FIX\" -- 'sudo ovs-vsctl list-br'" \
    "probe_stub_install \"\$FIX\" --")
report "P5: honesty no longer allows 'ovs-vsctl list-br'" "$m"
m=$(mutant p6 "$SAMPLE_RATE" "probe_stub_install \"\$TMPROOT\" --ovs-refuse -- 'sudo ovs-vsctl list-br'" \
    "probe_stub_install \"\$TMPROOT\" --ovs-refuse --")
report "P6: sample_rate no longer allows 'ovs-vsctl list-br'" "$m"
m=$(mutant p7 "$LAB_HANDOFF" "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'" \
    "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true'")
report "P7: lab_handoff no longer allows the unprivileged 'tc qdisc show'" "$m"

# P8: the stub never installed -- the shape of the first version's defect in the three suites that
# source ndt first (their HERE became ndt's, the lib was not found): the closing check must say so,
# not read an empty list as clean.
m=$(mutant p8 "$SAMPLE_RATE" "probe_stub_install \"\$TMPROOT\" --ovs-refuse -- 'sudo ovs-vsctl list-br'" \
    ": the stub is not installed")
report "P8: sample_rate's stub is never installed" "$m"

echo
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s)"
(( SURVIVORS == 0 ))
