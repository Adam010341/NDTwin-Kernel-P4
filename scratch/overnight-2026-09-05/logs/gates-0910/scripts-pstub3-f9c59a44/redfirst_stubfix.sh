#!/usr/bin/env bash
# redfirst_stubfix.sh <worktree> <keep dir> -- fix/probe-suites-stub-0927's fix round (the opus judge's
# B1, B2, N2, N5, N10 on 356d4e4e), red first where there is behaviour, every output KEPT under
# <keep dir>. [Co-developed with claude code -- Adam]
#   B1   the "sudo grants" branch test_lab_handoff's `ndt status` takes, OBSERVED under the stub's
#        wording and under the R pass's -- the first two rows of the table the lib now carries
#   B2   P9 in a sandbox of HEAD whose lib_probe_stub.sh lost its "the sudo on PATH is" line: P9 must
#        SURVIVE there (and nothing else)
#   N2   a ps that does not list ovs-vswitchd: 356d4e4e's gate lets P5, P6, P8 SURVIVE; HEAD's refuses
#        before any mutation
#   N5   the stubs' contract (HEAD's gate's stub_contract) on 356d4e4e's lib: its tc answers rc 0 to
#        a changing argv; HEAD's lib holds
#   N10  each of the six suites with no lib beside it: at 356d4e4e its last line is the FAILED line
#        and the L1 lane's scorer reads 0 checks; at HEAD `Ran 1 checks, 1 failed`, read as 1 / 1
set -u
WT="$1"; K="$2"; bad=0; BASE=356d4e4e; cd "$WT" || exit 2; mkdir -p "$K"
T=$(mktemp -d "${TMPDIR:-/tmp}/stubfix-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
sandbox() {   # sandbox <rev> <dir> -- the whole tree at <rev>, with the worktree's venv / build links
    mkdir -p "$2"; git archive "$1" | tar -x -C "$2"
    ln -s "$(readlink -f "$WT/p4_proxy/venv")" "$2/p4_proxy/venv"
    ln -s "$(readlink -f "$WT/p4_proxy/p4_src/build")" "$2/p4_proxy/p4_src/build"
}

echo "== B1: the sudo grants line test_lab_handoff's ndt status prints, per wording"
LS="$T/labsb"; mkdir -p "$LS/tools/test_workflow" "$LS/.test_run"
for f in ndt ports.sh sudo_surface.sh components.env; do cp "tools/test_workflow/$f" "$LS/tools/test_workflow/"; done
for w in "sudo: a password is required" "sudo: refused by the nolab shim (a lab command)"; do
    ( source tests/shell/lib_probe_stub.sh
      probe_stub_install "$LS" --tc-empty -- 'sudo ndtwin-lab status' 'sudo ovs-vsctl list-br' 'sudo mnexec -a 1 true' 'tc qdisc show'
      printf '#!/bin/bash\nprintf "sudo %%s\\n" "$*" >> %q\necho %q >&2\nexit 1\n' "$PROBE_STUB_LOG" "$w" > "$PROBE_STUB_DIR/sudo"
      bash "$LS/tools/test_workflow/ndt" status > "$T/status.out" 2>&1
      echo "    wording '$w':"
      /usr/bin/grep -E 'sudo grants|^ *sudo: ' "$T/status.out" | sed 's/\x1b\[[0-9;]*m//g; s/^ */      /'
      echo "      (sudo calls the stub recorded: $(probe_stub_calls))" )
    cp "$T/status.out" "$K/b1_ndt_status_$(tr -c 'A-Za-z0-9' '_' <<<"$w").out"
done
g1="$(/usr/bin/grep -h 'sudo grants' "$K"/b1_ndt_status_sudo__a_password*.out | sed 's/\x1b\[[0-9;]*m//g')"
g2="$(/usr/bin/grep -h 'sudo grants' "$K"/b1_ndt_status_sudo__refused*.out | sed 's/\x1b\[[0-9;]*m//g')"
[[ "$g1" == *refused* ]] && ok "the stub's wording: ndt reads the grants as REFUSED" || nok "the stub's wording: '$g1'"
[[ "$g2" == *granted* ]] && ok "the R pass's wording: ndt reads them as GRANTED -- the gate's artifact" || nok "the R pass's wording: '$g2'"

echo "== N10: a suite with no lib beside it"
NDTWIN_L1_LIB_ONLY=1 source tools/test_workflow/l1_unit_tests.sh >/dev/null 2>&1
declare -F shell_summary >/dev/null || { nok "the lane's shell_summary did not load"; }
for rev in "$BASE" HEAD; do
    d="$T/nolib-$rev"; mkdir -p "$d"; git archive "$rev" tests/shell tools/test_workflow | tar -x -C "$d"; rm -f "$d/tests/shell/lib_probe_stub.sh"
    for s in test_apps_stop_kills_the_group test_ndt_app_orphans test_cell_gate_suspect_wiring test_lab_handoff test_ndt_honesty test_ndt_sample_rate_reads_both_bounds; do
        ( cd "$d" && timeout 120 bash "tests/shell/$s.sh" < /dev/null > "$d/$s.out" 2>&1 ); rc=$?
        cp "$d/$s.out" "$K/n10_${rev}_$s.out"
        sc="$(shell_summary "$d/$s.out")"; last="$(tail -1 "$d/$s.out")"
        echo "    $rev $s: rc $rc, last '$last', the lane reads ran/failed $sc"
        if [[ "$rev" == "$BASE" ]]; then
            [[ "$sc" == "0 0" && "$last" == *"FAILED   no tests/shell/lib_probe_stub.sh"* ]] || nok "  $BASE $s: not the summary-less exit"
        else
            [[ $rc == 1 && "$sc" == "1 1" && "$last" == "Ran 1 checks, 1 failed" ]] && ok "  HEAD $s: 'Ran 1 checks, 1 failed', read as 1 ran, 1 failed" \
                || nok "  HEAD $s: rc $rc, '$last', $sc"
        fi
    done
done

echo "== N5: the stubs' contract on 356d4e4e's lib and on HEAD's"
fn="$(sed -n '/^stub_contract() {/,/^}/p' tests/shell/mutate_probe_stubs.sh)"
git show "$BASE:tests/shell/lib_probe_stub.sh" > "$T/lib_base.sh"
cb="$( eval "$fn"; stub_contract "$T/lib_base.sh" )"; ch="$( eval "$fn"; stub_contract tests/shell/lib_probe_stub.sh )"
echo "    $BASE: $(paste -sd';' <<<"$cb")"; echo "    HEAD: ${ch:-(the contract holds)}"
[[ "$cb" == *"tc qdisc add ...: rc 0 (want a refusal)"* ]] && ok "at $BASE the tc stub answers rc 0 to a changing argv (a fabricated success)" || nok "at $BASE: '$cb'"
[[ -z "$ch" ]] && ok "at HEAD the contract holds" || nok "at HEAD: $ch"

echo "== B2: P9 against a lib without its 'the sudo on PATH is' line"
S9="$T/sb9"; sandbox HEAD "$S9"
python3 - "$S9/tests/shell/lib_probe_stub.sh" <<'PY' || nok "the line to delete moved"
import sys
p = sys.argv[1]; s = open(p).read()
a = '    [[ "$(type -P sudo)" == "$PROBE_STUB_DIR/sudo" ]] || echo "the sudo on PATH is $(type -P sudo), not this suite\'s stub"\n'
assert s.count(a) == 1
open(p, "w").write(s.replace(a, ""))
PY
( cd "$S9" && bash tests/shell/mutate_probe_stubs.sh < /dev/null > "$K/b2_gate_without_the_line.out" 2>&1 ); r9=$?
/usr/bin/grep -E '^  (caught|SURVIVED) ' "$K/b2_gate_without_the_line.out" | cut -c1-150 | sed 's/^/    /'
echo "    rc $r9, $(tail -1 "$K/b2_gate_without_the_line.out")"
[[ $r9 == 1 && "$(/usr/bin/grep -c '^  SURVIVED ' "$K/b2_gate_without_the_line.out")" == 1 ]] \
    && /usr/bin/grep -q '^  SURVIVED P9: ' "$K/b2_gate_without_the_line.out" \
    && ok "without that line P9 SURVIVES, and only P9 -- the line is what kills it" || nok "P9 red first: rc $r9"

echo "== N2: a machine where ps lists no ovs-vswitchd"
FP="$T/fakeps"; mkdir -p "$FP"; realps="$(type -P ps)"
printf '#!/bin/bash\nif [[ "$*" == "-eo comm=" ]]; then %q -eo comm= | /usr/bin/grep -vx ovs-vswitchd; exit 0; fi\nexec %q "$@"\n' "$realps" "$realps" > "$FP/ps"; chmod +x "$FP/ps"
S2="$T/sb2"; sandbox "$BASE" "$S2"
( cd "$S2" && PATH="$FP:$PATH" bash tests/shell/mutate_probe_stubs.sh < /dev/null > "$K/n2_gate_base_no_ovs.out" 2>&1 ); rb=$?
/usr/bin/grep -E '^  (caught|SURVIVED|refused) ' "$K/n2_gate_base_no_ovs.out" | cut -c1-150 | sed 's/^/    /'
sv="$(/usr/bin/grep -oE '^  SURVIVED P[0-9]' "$K/n2_gate_base_no_ovs.out" | awk '{print $2}' | paste -sd' ' -)"
[[ $rb == 1 && "$sv" == "P5 P6 P8" ]] && ok "at $BASE, no ovs-vswitchd: P5, P6 and P8 SURVIVE for the machine's reason, and the gate says nothing of why" \
    || nok "at $BASE, no ovs-vswitchd: rc $rb, survived: $sv"
( PATH="$FP:$PATH" bash tests/shell/mutate_probe_stubs.sh < /dev/null > "$K/n2_gate_head_no_ovs.out" 2>&1 ); rh=$?
sed 's/^/    /' "$K/n2_gate_head_no_ovs.out" | head -4
[[ $rh == 2 && "$(head -1 "$K/n2_gate_head_no_ovs.out")" == "refused: P5, P6 and P8 need ndt's OVS path"*"no ovs-vswitchd running"* ]] \
    && ! /usr/bin/grep -qE '^  (caught|SURVIVED|ok) ' "$K/n2_gate_head_no_ovs.out" \
    && ok "at HEAD the gate refuses (rc 2) before any suite or mutation runs, and names what is missing" || nok "at HEAD: rc $rh"
/usr/bin/ls "$WT"/tests/shell/.mutant-* 2>/dev/null && nok "mutant copies left in the worktree"
echo "STUBFIX-RED-FIRST: $([[ $bad == 0 ]] && echo "B1 observed; B2, N2, N5, N10 red at $BASE (or in the mutated sandbox), green at HEAD" || echo BROKEN)"
exit $bad
