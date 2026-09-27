#!/usr/bin/env bash
#
# Mutation gate for the probe stubs of six suites (tests/shell/lib_probe_stub.sh): each suite's
# own sudo records every call and refuses it, and its closing check fails on a call outside the
# suite's allow-list. A closing check that cannot fail would make the allow-list decoration, so
# each mutation takes ONE entry out of one suite's allow-list -- a call the suite really makes --
# and that suite's closing check must go red, ON THAT CALL (the judge's N3 on 356d4e4e, 09-27: a red
# for any other reason is a survivor). P8 removes a stub altogether: the closing check must say the
# stub is not there, never read an empty call list as clean. P9 leaves the stub installed but puts
# ANOTHER sudo in front of it on PATH, P10 another tc, P11 another ovs-vsctl (the judge's N6): the
# closing check must say so ("the <cmd> on PATH is"), never read the calls that stub no longer sees
# as none. T1-T3 are the stubs' own contract: the unprivileged tc answers `qdisc show` and refuses
# everything else, and each stub is the command on PATH and records what it is asked.
#
# [Co-developed with claude code -- Adam]
#
# A mutant is a copy of the suite (or of the lib) BESIDE it (tests/shell/.mutant-<label>-<file>), so
# its HERE and every path it derives are the suite's own; the copy is removed after its run and on
# exit. A mutation that does not apply (the anchor is not exactly once in the file) is a SURVIVOR,
# never a skip. The baseline -- every suite green, its closing check ok -- must hold first, and so
# must the gate's own controls (below).
#
# 🔴 WHAT THIS GATE COVERS, AND WHAT IT DOES NOT (the judge's N8 on 356d4e4e). It holds each suite's
# CLOSING check -- the stub and its allow-list. test_apps_stop_kills_the_group, test_ndt_honesty,
# test_cell_gate_suspect_wiring and test_ndt_sample_rate_reads_both_bounds have mutation gates of
# their own for everything else; test_lab_handoff and test_ndt_app_orphans do NOT (app_orphans is
# only read, statically, by mutate_redirection_order.sh). Their other checks have never been seen
# red by a gate: OPEN, a ticket of its own.
#
# Usage: bash tests/shell/mutate_probe_stubs.sh
# Exit:  0 every mutation caught; 1 a mutation survived; 2 refused (precondition / baseline red /
#        a control that did not come out as it must / harness)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_STOP="$HERE/test_apps_stop_kills_the_group.sh"
APP_ORPHANS="$HERE/test_ndt_app_orphans.sh"
CELL_GATE="$HERE/test_cell_gate_suspect_wiring.sh"
LAB_HANDOFF="$HERE/test_lab_handoff.sh"
HONESTY="$HERE/test_ndt_honesty.sh"
SAMPLE_RATE="$HERE/test_ndt_sample_rate_reads_both_bounds.sh"
LIB="$HERE/lib_probe_stub.sh"
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
trap 'rm -f "$HERE"/.mutant-*-test_*.sh "$HERE"/.mutant-*-lib_probe_stub.sh; rm -rf "$ESC"' EXIT
SURVIVORS=0; MUTATIONS=0

# [Co-developed with claude code -- Adam] 🔴 THIS GATE'S PRECONDITION (the judge's N2 on 356d4e4e,
# 09-27; NOTE c on f9c59a44). Four of the mutations are killed only when ndt makes its
# `sudo ovs-vsctl list-br` probe at all: P4 needs ovs-vsctl on PATH (lab_handoff's `ndt status`
# probes only a program `command -v` finds, sudo_surface.sh ndt_sudo_probe); P5, P6 and P8 need
# ndt's whole OVS path -- ovs-vsctl on PATH and ovs-vswitchd running (ndt ovs_bridge_count) -- and
# P6 and P8, sample_rate's, no bmv2 switch running (a live bmv2 sends it down the p4 branch, with no
# sudo). On a machine without that they would SURVIVE for the machine's reason, so the gate REFUSES
# there instead. It does not pin the path with a fake `ps` on PATH: a refusal fails loud and puts no
# instrument between the suites and the machine that could itself be wrong -- not because a fake ps
# must disturb the other suites (one that rewrote only `ps -eo comm=` did not, 09-27, the judge's
# NOTE b; it could be scoped to the P5/P6/P8 runs, which would let the gate run while a P4 lab is up).
# 🔴 KNOWN LIMITATION: the precondition is read ONCE, here. A bmv2 started, or ovs-vswitchd stopped,
# while the gate runs shows up as P4/P5/P6/P8 SURVIVED -- red, but for the machine's reason.
pre=""
command -v ovs-vsctl >/dev/null 2>&1 || pre="${pre}no ovs-vsctl on PATH (P4, P5, P6, P8); "
_comm="$(ps -eo comm= 2>/dev/null)"
/usr/bin/grep -qx 'ovs-vswitchd' <<<"$_comm" || pre="${pre}no ovs-vswitchd running (P5, P6, P8); "
/usr/bin/grep -qx 'simple_switch_g' <<<"$_comm" && pre="${pre}a bmv2 switch (simple_switch_g) is running (P6, P8); "
if [[ -n "$pre" ]]; then
    echo "refused: P4, P5, P6 and P8 need ndt's OVS path and this machine does not give it: ${pre%; }."
    echo "  (on such a machine they would SURVIVE for the machine's reason, not the suites'; run this gate where"
    echo "   ovs-vswitchd runs, ovs-vsctl is on PATH and no bmv2 fabric is up)"
    exit 2
fi
echo "precondition: ovs-vsctl on PATH, ovs-vswitchd running, no bmv2 switch -- ndt takes its OVS path"

# --- one run, and the two rules that read it --------------------------------------------------
# [Co-developed with claude code -- Adam] (09-27, the judge's N4 on 356d4e4e) the baseline's rule and a
# mutant's rule are functions of ONE run's output, rc and escaped-call count, so the controls below
# can hold each rule to a run whose answer is known.
run_one() {   # run_one <file> -> RUN_OUT, RUN_RC, RUN_ESC
    : > "$ESC/escaped"
    RUN_OUT="$(timeout 900 bash "$1" < /dev/null 2>&1)"; RUN_RC=$?
    RUN_ESC="$(wc -l < "$ESC/escaped")"
}
baseline_rule() {   # baseline_rule <name> -> "ok ..." or "refused: ..."
    if (( RUN_ESC > 0 )); then
        echo "refused: $1 sent $RUN_ESC sudo call(s) past its own stub"; return
    fi
    if [[ $RUN_RC -ne 0 ]] || ! /usr/bin/grep -E '^ *ok ' <<<"$RUN_OUT" | /usr/bin/grep -qF -- "$CLOSING"; then
        echo "refused: $1 is not green with its closing check ok (rc $RUN_RC)"; return
    fi
    echo "ok       $1: $(tail -1 <<<"$RUN_OUT")"
}
mutant_rule() {   # mutant_rule <"escapes" or ""> <text the closing check's red must show> -> "caught ..." or "SURVIVED ..."
    local why
    # a stub that is there takes every call (0 escaped); a stub that is gone must leak (>0)
    if [[ "$1" == escapes ]] && (( RUN_ESC == 0 )); then
        echo "SURVIVED (no call reached this gate's sudo -- the escape it tests went nowhere)"; return
    fi
    if [[ "$1" != escapes ]] && (( RUN_ESC > 0 )); then
        echo "SURVIVED ($RUN_ESC call(s) escaped a stub that should have taken them)"; return
    fi
    why="$(/usr/bin/grep -A2 -F -- "$CLOSING" <<<"$RUN_OUT" | /usr/bin/grep -oE '(actual: *.*|outside the allow-list: .*)' | head -1)"
    if [[ $RUN_RC -ne 0 ]] && /usr/bin/grep -E '^ *FAILED ' <<<"$RUN_OUT" | /usr/bin/grep -qF -- "$CLOSING"; then
        if [[ -n "$2" && "$why" != *"$2"* ]]; then
            echo "SURVIVED (the closing check went red, but not on \"$2\": ${why:0:100})"
        else
            echo "caught   ($RUN_ESC escaped; the closing check went red: ${why:0:100})"
        fi
    else
        echo "SURVIVED (rc $RUN_RC; the closing check did not go red)"
    fi
}

echo "baseline (every suite green, its closing check ok):"
for s in "$APPS_STOP" "$APP_ORPHANS" "$CELL_GATE" "$LAB_HANDOFF" "$HONESTY" "$SAMPLE_RATE"; do
    run_one "$s"; r="$(baseline_rule "$(basename "$s")")"
    echo "  $r"
    [[ "$r" == refused:* ]] && exit 2
done

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
mutant() {   # $1 = label, $2 = file (the suite, or the lib), $3 = the anchor, $4 = its replacement -> the copy
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
             # $4 = text the closing check's red must show: WHY it went red -- the call taken off the allow-list
    local r
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == ANCHOR:* ]]; then
        SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (anchor occurrences: %s)\n' "$1" "${2#ANCHOR:}"; return
    fi
    run_one "$2"; rm -f "$2"
    r="$(mutant_rule "${3:-}" "${4:-}")"
    [[ "$r" == SURVIVED* ]] && SURVIVORS=$((SURVIVORS+1))
    printf '  %s %-66s %s\n' "${r%% (*}" "$1" "(${r#* (}"
}

# --- the gate's own controls: each rule above must fire on a run built to trip it ----------------
# [Co-developed with claude code -- Adam] 🔴 (09-27, the judge's N4 and NOTE e) three branches of this
# gate had never been seen to fire: the baseline's refusal of a suite that leaks, a P-mutant that
# leaks being a SURVIVOR, and "red, but not on the call taken out". Each is tripped here, on a copy
# built to trip it, every run -- and a control that does not come out as it must stops the gate
# (rc 2): a rule that cannot fire makes every verdict after it decoration.
echo
echo "controls (each must come out as stated, or nothing below means anything):"
control() {   # control <name> <the glob its answer must match> <what it answered>
    # shellcheck disable=SC2053  # $2 IS a glob
    if [[ "$3" == $2 ]]; then printf '  ok       %s -> %s\n' "$1" "${3:0:110}"
    else printf '  refused: control "%s" answered "%s", not "%s"\n' "$1" "${3:0:110}" "$2"; exit 2; fi
}
m=$(mutant c1 "$SAMPLE_RATE" "probe_stub_install \"\$TMPROOT\" --ovs-refuse -- 'sudo ovs-vsctl list-br'" \
    ": the stub is not installed")
[[ "$m" == ANCHOR:* ]] && { echo "  refused: control C1/C2's anchor is not exactly once in sample_rate ($m)"; exit 2; }
run_one "$m"; rm -f "$m"
control "C1: a suite whose calls escape its stub is refused as a baseline" \
        'refused: sample_rate sent * sudo call(s) past its own stub' "$(baseline_rule sample_rate)"
control "C2: ... and as a P-mutant (no \"escapes\" expected) it is a SURVIVOR" \
        'SURVIVED (* call(s) escaped a stub that should have taken them)' "$(mutant_rule "" "sudo ovs-vsctl list-br")"
m=$(mutant c3 "$LAB_HANDOFF" "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'" \
    "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true'")
[[ "$m" == ANCHOR:* ]] && { echo "  refused: control C3's anchor is not exactly once in lab_handoff ($m)"; exit 2; }
run_one "$m"; rm -f "$m"
control "C3: 'tc qdisc show' taken out, judged as if 'sudo ovs-vsctl list-br' were: red, but not on it" \
        'SURVIVED (the closing check went red, but not on "sudo ovs-vsctl list-br"*' \
        "$(mutant_rule "" "sudo ovs-vsctl list-br")"

echo
echo "mutations (one allow-list entry out of one suite; the red must name it):"
m=$(mutant p1 "$APPS_STOP" "probe_stub_install \"\$TMPROOT\" -- 'sudo ndtwin-lab status'" \
    "probe_stub_install \"\$TMPROOT\" --")
report "P1: apps_stop no longer allows 'ndtwin-lab status'" "$m" "" "sudo ndtwin-lab status"
m=$(mutant p2 "$APP_ORPHANS" "probe_stub_install \"\$TMPROOT\" -- 'sudo ndtwin-lab status'" \
    "probe_stub_install \"\$TMPROOT\" --")
report "P2: app_orphans no longer allows 'ndtwin-lab status'" "$m" "" "sudo ndtwin-lab status"
m=$(mutant p3 "$CELL_GATE" "'sudo ndtwin-lab status' 'sudo ndtwin-lab topo-out *'" \
    "'sudo ndtwin-lab status'")
report "P3: cell_gate no longer allows 'ndtwin-lab topo-out N'" "$m" "" "sudo ndtwin-lab topo-out"
m=$(mutant p4 "$LAB_HANDOFF" "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'" \
    "'sudo ndtwin-lab status' 'sudo mnexec -a 1 true' 'tc qdisc show'")
report "P4: lab_handoff no longer allows 'ovs-vsctl list-br'" "$m" "" "sudo ovs-vsctl list-br"
m=$(mutant p5 "$HONESTY" "probe_stub_install \"\$FIX\" -- 'sudo ovs-vsctl list-br'" \
    "probe_stub_install \"\$FIX\" --")
report "P5: honesty no longer allows 'ovs-vsctl list-br'" "$m" "" "sudo ovs-vsctl list-br"
m=$(mutant p6 "$SAMPLE_RATE" "probe_stub_install \"\$TMPROOT\" --ovs-refuse -- 'sudo ovs-vsctl list-br'" \
    "probe_stub_install \"\$TMPROOT\" --ovs-refuse --")
report "P6: sample_rate no longer allows 'ovs-vsctl list-br'" "$m" "" "sudo ovs-vsctl list-br"
m=$(mutant p7 "$LAB_HANDOFF" "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'" \
    "'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true'")
report "P7: lab_handoff no longer allows the unprivileged 'tc qdisc show'" "$m" "" "tc qdisc show"

# P8: the stub never installed -- the shape of the first version's defect in the three suites that
# source ndt first (their HERE became ndt's, the lib was not found): the closing check must say so,
# not read an empty list as clean.
m=$(mutant p8 "$SAMPLE_RATE" "probe_stub_install \"\$TMPROOT\" --ovs-refuse -- 'sudo ovs-vsctl list-br'" \
    ": the stub is not installed")
report "P8: sample_rate's stub is never installed (its calls escape to this gate's sudo)" "$m" escapes "NO STUB"

# [Co-developed with claude code -- Adam] P9 (the judge's B2 on 356d4e4e, 09-27): the stub installed,
# then ANOTHER sudo put in front of it on PATH -- the case in which the calls are not recorded and
# the allow-list check would read nothing as clean. Only lib_probe_stub.sh's "the sudo on PATH is"
# line can see it; P1-P8 all pass without that line.
m=$(mutant p9 "$CELL_GATE" "probe_stub_install \"\$T\" -- 'sudo ndtwin-lab status' 'sudo ndtwin-lab topo-out *'" \
    "probe_stub_install \"\$T\" -- 'sudo ndtwin-lab status' 'sudo ndtwin-lab topo-out *'
P9D=\"\$(mktemp -d \"\$T/p9-XXXXXX\")\"; printf '#!/bin/bash\\necho \"sudo: a password is required\" >&2\\nexit 1\\n' > \"\$P9D/sudo\"
chmod +x \"\$P9D/sudo\"; export PATH=\"\$P9D:\$PATH\"")
report "P9: cell_gate's stub is shadowed by another sudo on PATH" "$m" "" "the sudo on PATH is"

# [Co-developed with claude code -- Adam] P10, P11 (the judge's N6 on 356d4e4e, 09-27): the same for the
# unprivileged stubs. The shadow answers exactly as the stub does -- tc `qdisc show` with nothing,
# ovs-vsctl a refusal -- so every other check of the suite stays green and only the closing check can
# see that its calls went unrecorded.
m=$(mutant p10 "$LAB_HANDOFF" "probe_stub_install \"\$SANDBOX\" --tc-empty -- 'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'" \
    "probe_stub_install \"\$SANDBOX\" --tc-empty -- 'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'
P10D=\"\$(mktemp -d \"\$SANDBOX/p10-XXXXXX\")\"; printf '#!/bin/bash\\n[[ \"\$*\" == \"qdisc show\" ]] && exit 0\\nexit 1\\n' > \"\$P10D/tc\"
chmod +x \"\$P10D/tc\"; export PATH=\"\$P10D:\$PATH\"")
report "P10: lab_handoff's tc stub is shadowed by another tc on PATH" "$m" "" "the tc on PATH is"
m=$(mutant p11 "$SAMPLE_RATE" "probe_stub_install \"\$TMPROOT\" --ovs-refuse -- 'sudo ovs-vsctl list-br'" \
    "probe_stub_install \"\$TMPROOT\" --ovs-refuse -- 'sudo ovs-vsctl list-br'
P11D=\"\$(mktemp -d \"\$TMPROOT/p11-XXXXXX\")\"; printf '#!/bin/bash\\necho \"ovs-vsctl: refused\" >&2\\nexit 1\\n' > \"\$P11D/ovs-vsctl\"
chmod +x \"\$P11D/ovs-vsctl\"; export PATH=\"\$P11D:\$PATH\"")
report "P11: sample_rate's ovs-vsctl stub is shadowed by another ovs-vsctl on PATH" "$m" "" "the ovs-vsctl on PATH is"

# [Co-developed with claude code -- Adam] T1-T3 (the judge's N5 on 356d4e4e and NOTE d on f9c59a44,
# 09-27): the stubs' own contract, on the lib given. Each stub must be the command on PATH and record
# what it is asked; the unprivileged tc answers `qdisc show` (rc 0, nothing) and REFUSES every other
# argv; sudo and ovs-vsctl refuse. A command that is not the stub is not exercised at all -- the
# contract never hands a real tc or ovs-vsctl a changing argv. Before NOTE d the sudo and ovs-vsctl
# halves could not fail in this gate: this gate's own sudo answers in the stub's words, and an
# unprivileged ovs-vsctl refuses `list-br` too, so a stub that recorded nothing, or was never
# written, met the contract. T2 and T3 are exactly those.
stub_contract() {   # stub_contract <lib file> -> one line per way its stubs break the contract
    ( source "$1"; d="$(mktemp -d "${TMPDIR:-/tmp}/probe-stub-contract-XXXXXX")"
      probe_stub_install "$d" --tc-empty --ovs-refuse -- 'tc qdisc show'
      for c in sudo tc ovs-vsctl; do
          [[ "$(type -P "$c")" == "$d/probe-stub/$c" ]] || echo "$c on PATH is $(type -P "$c"), not the stub"
      done
      if [[ "$(type -P tc)" == "$d/probe-stub/tc" ]]; then
          o="$(tc qdisc show 2>&1)"; r=$?; [[ $r == 0 && -z "$o" ]] || echo "tc qdisc show: rc $r, '$o' (want rc 0 and nothing)"
          tc qdisc add dev ndt-no-such-dev root netem delay 1ms >/dev/null 2>&1 && echo "tc qdisc add ...: rc 0 (want a refusal)"
          tc qdisc del dev ndt-no-such-dev root >/dev/null 2>&1 && echo "tc qdisc del ...: rc 0 (want a refusal)"
          probe_stub_calls | /usr/bin/grep -qF "tc qdisc add dev ndt-no-such-dev root netem delay 1ms" || echo "a refused tc call was not recorded"
      fi
      if [[ "$(type -P sudo)" == "$d/probe-stub/sudo" ]]; then
          sudo -n true 2>"$d/e"; r=$?; [[ $r == 1 && "$(cat "$d/e")" == "sudo: a password is required" ]] || echo "sudo: rc $r, '$(cat "$d/e")'"
          probe_stub_calls | /usr/bin/grep -qE '(^|;)1 sudo true(;|$)' || echo "sudo -n true was not recorded by the stub"
      fi
      if [[ "$(type -P ovs-vsctl)" == "$d/probe-stub/ovs-vsctl" ]]; then
          ovs-vsctl list-br >/dev/null 2>&1 && echo "ovs-vsctl: rc 0 (want a refusal)"
          probe_stub_calls | /usr/bin/grep -qE '(^|;)1 ovs-vsctl list-br(;|$)' || echo "ovs-vsctl list-br was not recorded by the stub"
      fi
      rm -rf "$d" )
}
echo
echo "the stubs' contract:"
c0="$(stub_contract "$LIB")"
if [[ -n "$c0" ]]; then echo "  refused: lib_probe_stub.sh does not meet its own contract: $(paste -sd';' <<<"$c0")"; exit 2; fi
echo "  ok       lib_probe_stub.sh: each stub is on PATH and records; tc answers qdisc show and refuses the rest; sudo and ovs-vsctl refuse"
contract_report() {   # $1 = mutation name, $2 = the lib copy (or ANCHOR:n), $3 = the breach the contract must name
    local c
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == ANCHOR:* ]]; then
        SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (anchor occurrences: %s)\n' "$1" "${2#ANCHOR:}"; return
    fi
    c="$(stub_contract "$2")"; rm -f "$2"
    if [[ "$c" == *"$3"* ]]; then
        printf '  caught   %-66s (%s)\n' "$1" "$(paste -sd';' <<<"$c" | cut -c1-100)"
    else
        SURVIVORS=$((SURVIVORS+1)); printf '  SURVIVED %-66s (%s)\n' "$1" "${c:-the contract held}"
    fi
}
m=$(mutant t1 "$LIB" '[[ "\$*" == "qdisc show" ]] && exit 0' 'exit 0')
contract_report "T1: the tc stub answers rc 0 to every argv" "$m" "tc qdisc add ...: rc 0 (want a refusal)"
m=$(mutant t2 "$LIB" "printf 'sudo %s" ": printf 'sudo %s")
contract_report "T2: the sudo stub refuses but records nothing" "$m" "sudo -n true was not recorded by the stub"
m=$(mutant t3 "$LIB" "    if (( ovs )); then" "    if false; then")
contract_report "T3: --ovs-refuse writes no ovs-vsctl stub" "$m" "ovs-vsctl on PATH is"

echo
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s)"
(( SURVIVORS == 0 ))
