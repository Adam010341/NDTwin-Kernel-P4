#!/usr/bin/env bash
#
# Mutation gate for the probe stubs of six suites (tests/shell/lib_probe_stub.sh): each suite's
# own sudo records every call and refuses it, and its closing check fails on a call outside the
# suite's allow-list. A closing check that cannot fail would make the allow-list decoration, so
# each mutation takes ONE entry out of one suite's allow-list -- a call the suite really makes --
# and that suite's closing check must go red. P8 removes a stub altogether: the closing check must
# say the stub is not there, never read an empty call list as clean. P9 leaves the stub installed
# but puts ANOTHER sudo in front of it on PATH: the closing check must say so ("the sudo on PATH
# is"), never read the calls that stub no longer sees as none. T1 is the stubs' own contract: the
# unprivileged tc answers `qdisc show` and refuses everything else.
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
# [Co-developed with claude code -- Adam] 🔴 THIS GATE'S OWN sudo, FIRST ON PATH FOR EVERY RUN (09-27).
# A mutant can take a suite's stub away (P8), and then the suite's probes go to whatever sudo is
# next on PATH -- on 09-27 that was the driver's nolab shim, and its tripwire counted them. Here they
# land in this gate's own recorder, which refuses them (rc 1), and P8's kill REQUIRES them there: a
# stub that is gone must show up as calls that escaped it, not as silence.
ESC="$(mktemp -d "${TMPDIR:-/tmp}/probe-stub-gate-XXXXXX")"
cat > "$ESC/sudo" <<EOF
#!/bin/bash
printf 'sudo %s\n' "\$*" >> '$ESC/escaped'
echo "sudo: a password is required" >&2
exit 1
EOF
chmod +x "$ESC/sudo"; : > "$ESC/escaped"
export PATH="$ESC:$PATH"
trap 'rm -f "$HERE"/.mutant-*-test_*.sh; rm -rf "$ESC"' EXIT
SURVIVORS=0; MUTATIONS=0

# [Co-developed with claude code -- Adam] 🔴 THIS GATE'S PRECONDITION (the judge's N2 on 356d4e4e,
# 09-27). P5, P6 and P8 are killed only when ndt makes its `sudo ovs-vsctl list-br` probe at all,
# and it makes it only on its OVS path: ovs-vsctl on PATH and ovs-vswitchd running (ndt
# ovs_bridge_count), and -- for sample_rate -- no bmv2 switch running (a live bmv2 sends it down the
# p4 branch, with no sudo). On a machine without that, those three would SURVIVE for the machine's
# reason. This gate REFUSES there instead of pinning the path with a fake ps: a fake `ps` on PATH
# would also be what apps_stop and app_orphans read for their own process checks.
pre=""
command -v ovs-vsctl >/dev/null 2>&1 || pre="${pre}no ovs-vsctl on PATH; "
_comm="$(ps -eo comm= 2>/dev/null)"
/usr/bin/grep -qx 'ovs-vswitchd' <<<"$_comm" || pre="${pre}no ovs-vswitchd running; "
/usr/bin/grep -qx 'simple_switch_g' <<<"$_comm" && pre="${pre}a bmv2 switch (simple_switch_g) is running; "
if [[ -n "$pre" ]]; then
    echo "refused: P5, P6 and P8 need ndt's OVS path and this machine does not give it: ${pre%; }."
    echo "  (on such a machine they would SURVIVE for the machine's reason, not the suites'; run this gate where"
    echo "   ovs-vswitchd runs, ovs-vsctl is on PATH and no bmv2 fabric is up)"
    exit 2
fi
echo "precondition: ovs-vsctl on PATH, ovs-vswitchd running, no bmv2 switch -- ndt takes its OVS path"

echo "baseline (every suite green, its closing check ok):"
for s in "$APPS_STOP" "$APP_ORPHANS" "$CELL_GATE" "$LAB_HANDOFF" "$HONESTY" "$SAMPLE_RATE"; do
    : > "$ESC/escaped"
    out="$(timeout 900 bash "$s" < /dev/null 2>&1)"; rc=$?
    if [[ -s "$ESC/escaped" ]]; then
        echo "  refused: $(basename "$s") sent $(wc -l < "$ESC/escaped") sudo call(s) past its own stub"; exit 2
    fi
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
report() {   # $1 = mutation name, $2 = the copy (or ANCHOR:n), $3 = "escapes" when the stub is meant to be gone,
             # $4 = text the closing check's red must show (optional: WHY it went red)
    local out rc esc why
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == ANCHOR:* ]]; then
        SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (anchor occurrences: %s)\n' "$1" "${2#ANCHOR:}"; return
    fi
    : > "$ESC/escaped"
    out="$(timeout 900 bash "$2" < /dev/null 2>&1)"; rc=$?; rm -f "$2"
    esc="$(wc -l < "$ESC/escaped")"
    # a stub that is there takes every call (0 escaped); a stub that is gone must leak (>0)
    if [[ "${3:-}" == escapes ]] && (( esc == 0 )); then
        SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (no call reached this gate'"'"'s sudo -- the escape it tests went nowhere)\n' "$1"; return
    fi
    if [[ "${3:-}" != escapes ]] && (( esc > 0 )); then
        SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (%s call(s) escaped a stub that should have taken them)\n' "$1" "$esc"; return
    fi
    why="$(/usr/bin/grep -A2 -F -- "$CLOSING" <<<"$out" | /usr/bin/grep -oE '(actual: *.*|outside the allow-list: .*)' | head -1)"
    if [[ $rc -ne 0 && -n "${4:-}" && "$why" != *"$4"* ]] && /usr/bin/grep -E '^ *FAILED ' <<<"$out" | /usr/bin/grep -qF -- "$CLOSING"; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (the closing check went red, but not on "%s": %s)\n' "$1" "$4" "${why:0:100}"
    elif [[ $rc -ne 0 ]] && /usr/bin/grep -E '^ *FAILED ' <<<"$out" | /usr/bin/grep -qF -- "$CLOSING"; then
        printf '  caught   %-66s (%s escaped; the closing check went red: %s)\n' "$1" "$esc" "${why:0:100}"
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
report "P8: sample_rate's stub is never installed (its calls escape to this gate's sudo)" "$m" escapes

# [Co-developed with claude code -- Adam] P9 (the judge's B2 on 356d4e4e, 09-27): the stub installed,
# then ANOTHER sudo put in front of it on PATH -- the case in which the calls are not recorded and
# the allow-list check would read nothing as clean. Only lib_probe_stub.sh's "the sudo on PATH is"
# line can see it; P1-P8 all pass without that line.
m=$(mutant p9 "$CELL_GATE" "probe_stub_install \"\$T\" -- 'sudo ndtwin-lab status' 'sudo ndtwin-lab topo-out *'" \
    "probe_stub_install \"\$T\" -- 'sudo ndtwin-lab status' 'sudo ndtwin-lab topo-out *'
P9D=\"\$(mktemp -d \"\$T/p9-XXXXXX\")\"; printf '#!/bin/bash\\necho \"sudo: a password is required\" >&2\\nexit 1\\n' > \"\$P9D/sudo\"
chmod +x \"\$P9D/sudo\"; export PATH=\"\$P9D:\$PATH\"")
report "P9: cell_gate's stub is shadowed by another sudo on PATH" "$m" "" "the sudo on PATH is"

# [Co-developed with claude code -- Adam] T1 (the judge's N5): the stubs' own contract, on the lib
# given -- the unprivileged tc answers `qdisc show` (rc 0, nothing) and REFUSES every other argv,
# recording it; sudo and ovs-vsctl refuse. The lib as it is must meet it; a copy whose tc answers
# rc 0 to anything must not.
stub_contract() {   # stub_contract <lib file> -> one line per way its stubs break the contract
    ( source "$1"; d="$(mktemp -d "${TMPDIR:-/tmp}/probe-stub-contract-XXXXXX")"
      probe_stub_install "$d" --tc-empty --ovs-refuse -- 'tc qdisc show'
      o="$(tc qdisc show 2>&1)"; r=$?; [[ $r == 0 && -z "$o" ]] || echo "tc qdisc show: rc $r, '$o' (want rc 0 and nothing)"
      tc qdisc add dev ndt-no-such-dev root netem delay 1ms >/dev/null 2>&1 && echo "tc qdisc add ...: rc 0 (want a refusal)"
      tc qdisc del dev ndt-no-such-dev root >/dev/null 2>&1 && echo "tc qdisc del ...: rc 0 (want a refusal)"
      probe_stub_calls | /usr/bin/grep -qF "tc qdisc add dev ndt-no-such-dev root netem delay 1ms" || echo "a refused tc call was not recorded"
      sudo -n true 2>"$d/e"; r=$?; [[ $r == 1 && "$(cat "$d/e")" == "sudo: a password is required" ]] || echo "sudo: rc $r, '$(cat "$d/e")'"
      ovs-vsctl list-br >/dev/null 2>&1 && echo "ovs-vsctl: rc 0 (want a refusal)"
      rm -rf "$d" )
}
echo
echo "the stubs' contract:"
c0="$(stub_contract "$HERE/lib_probe_stub.sh")"
if [[ -n "$c0" ]]; then echo "  refused: lib_probe_stub.sh does not meet its own contract: $(paste -sd';' <<<"$c0")"; exit 2; fi
echo "  ok       lib_probe_stub.sh: tc answers qdisc show and refuses the rest; sudo and ovs-vsctl refuse"
MUTATIONS=$((MUTATIONS+1))
t1="$(mktemp "${TMPDIR:-/tmp}/probe-stub-t1-XXXXXX")"
python3 - "$HERE/lib_probe_stub.sh" "$t1" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = """[[ "\\$*" == "qdisc show" ]] && exit 0\n"""
if s.count(a) != 1:
    print("ANCHOR:%d" % s.count(a)); sys.exit(0)
open(sys.argv[2], "w").write(s.replace(a, "exit 0\n"))
PY
c1="$(stub_contract "$t1")"; rm -f "$t1"
if [[ "$c1" == *"tc qdisc add ...: rc 0 (want a refusal)"* ]]; then
    printf '  caught   %-66s (%s)\n' "T1: the tc stub answers rc 0 to every argv" "$(paste -sd';' <<<"$c1" | cut -c1-100)"
else
    SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (%s)\n' "T1: the tc stub answers rc 0 to every argv" "${c1:-the contract held}"
fi

echo
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s)"
(( SURVIVORS == 0 ))
