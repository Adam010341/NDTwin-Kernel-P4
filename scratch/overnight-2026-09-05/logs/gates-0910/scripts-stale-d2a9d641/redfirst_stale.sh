#!/usr/bin/env bash
# redfirst_stale.sh <worktree> <keep dir> -- fix/stale-suites-0927, red first for (b1), (b2) and (b3), every
# suite output KEPT under <keep dir>. [Co-developed with claude code -- Adam]
#   b1  test_start_bg_log_rotation: at 8746c1bc red (the six .prev/.prev2 expectations), HEAD green;
#       and the history claim observed, not inferred: the OLD suite against stack.sh at 74c811df^
#       (green) and at 74c811df (red)
#   b2  test_gate_exit_code_not_tee, in this worktree, which has no raw t008_poll: at 8746c1bc red
#       (cases 1, 4) with case 2 green for the wrong reason (the gate said UNRUNNABLE); HEAD green;
#       HEAD with its fixture dir EMPTY -- case 2 now red; and the fixture's verdict beside the
#       real trace's (read from audit-raw into a temp dir, never into the tree)
#   b3  test_l1_shell_scoring: at 8746c1bc red (group C, 12 suites), HEAD green; 8746c1bc's own
#       mutation gate PASSES in an 8746c1bc tree over that red baseline (every KILLED vacuous) and
#       HEAD's gate REFUSES there (rc 2); then old / new / new-without-rule-(2) group C side by
#       side on one corpus and the gate's four corpus mutants (M1-M4): which of them each tells
#       apart from the unmutated corpus
set -u
WT="$1"; K="$2"; bad=0; cd "$WT" || exit 2
mkdir -p "$K"; T=$(mktemp -d "${TMPDIR:-/tmp}/stale-red-XXXXXX"); COPIES=()
trap 'rm -f "${COPIES[@]}"; rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
red_names() { /usr/bin/grep -E '^ *FAILED ' "$1" | sed -E 's/^ *FAILED +//' | paste -sd';' -; }
echo "HEAD $(git rev-parse HEAD); base 8746c1bc"

echo "== b1 test_start_bg_log_rotation"
b="tests/shell/.redfirst-stale-base-test_start_bg_log_rotation.sh"; git show 8746c1bc:tests/shell/test_start_bg_log_rotation.sh > "$b"; COPIES+=("$WT/$b")
bash "$b" < /dev/null > "$K/b1_base.out" 2>&1; rb=$?
bash tests/shell/test_start_bg_log_rotation.sh < /dev/null > "$K/b1_head.out" 2>&1; rh=$?
echo "    base: rc $rb, $(tail -1 "$K/b1_base.out")   red: $(red_names "$K/b1_base.out" | cut -c1-160)"
echo "    head: rc $rh, $(tail -1 "$K/b1_head.out")"
[[ $rb != 0 && "$(/usr/bin/grep -cE '^ *FAILED ' "$K/b1_base.out")" == 6 ]] && ok "8746c1bc: red, the six .prev/.prev2 expectations" || nok "8746c1bc: rc $rb"
[[ $rh == 0 && "$(tail -1 "$K/b1_head.out")" == "Ran 5 checks, all passed" ]] && ok "HEAD: Ran 5 checks, all passed" || nok "HEAD: rc $rh"
for rev in 74c811df^ 74c811df; do
    d="$T/hist-${rev//^/p}"; mkdir -p "$d"
    git archive "$rev" tools/test_workflow | tar -x -C "$d"
    mkdir -p "$d/tests/shell"; git show 8e7e3b00:tests/shell/test_start_bg_log_rotation.sh > "$d/tests/shell/t.sh"
    ( cd "$d" && bash tests/shell/t.sh < /dev/null > "$K/b1_hist_${rev//^/p}.out" 2>&1 ); r=$?
    echo "    the 08-31 suite (8e7e3b00) against stack.sh at $rev: rc $r, $(tail -1 "$K/b1_hist_${rev//^/p}.out")"
    if [[ "$rev" == *^ ]]; then [[ $r == 0 ]] && ok "  green before O-4" || nok "  not green before O-4"
    else [[ $r != 0 ]] && ok "  red from O-4 on (observed, not inferred)" || nok "  not red at 74c811df"; fi
done

echo "== b2 test_gate_exit_code_not_tee"
[[ ! -e doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_twin.jsonl ]] && ok "this worktree has no raw t008_poll_twin.jsonl" \
    || nok "this worktree HAS the raw file -- the red first would prove nothing"
b="tests/shell/.redfirst-stale-base-test_gate_exit_code_not_tee.sh"; git show 8746c1bc:tests/shell/test_gate_exit_code_not_tee.sh > "$b"; COPIES+=("$WT/$b")
bash "$b" < /dev/null > "$K/b2_base.out" 2>&1; rb=$?
echo "    base: rc $rb, $(tail -1 "$K/b2_base.out")   red: $(red_names "$K/b2_base.out" | cut -c1-160)"
[[ $rb != 0 ]] && /usr/bin/grep -qE '^ *FAILED +case 1' "$K/b2_base.out" && /usr/bin/grep -qE '^ *FAILED +case 4' "$K/b2_base.out" \
    && ok "8746c1bc: red on cases 1 and 4" || nok "8746c1bc: not red as expected"
/usr/bin/grep -qE '^ *ok +case 2 ' "$K/b2_base.out" && ok "  and case 2 GREEN there -- with no data at all" || nok "  case 2 was not green at base"
( set +u; . doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env >/dev/null 2>&1
  env -u NDT_SAMPLING_RAW_DIR PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" doc/audit/2026-08-31_sampling-ceiling-after-merge/ratio_gate.py \
      --check t008_poll --expect red > "$K/b2_base_case2_gate.out" 2>&1; echo "rc=$?" >> "$K/b2_base_case2_gate.out" )
echo "    what case 2's gate said at base (the suite threw it away): $(/usr/bin/grep -E '^GATE|^rc=' "$K/b2_base_case2_gate.out" | paste -sd' ' -)"
/usr/bin/grep -q 'verdict=UNRUNNABLE' "$K/b2_base_case2_gate.out" && /usr/bin/grep -q '^rc=2$' "$K/b2_base_case2_gate.out" \
    && ok "  -- UNRUNNABLE, rc 2: case 2's rc was right for the wrong reason" || nok "  the base gate did not say UNRUNNABLE rc 2"
bash tests/shell/test_gate_exit_code_not_tee.sh < /dev/null > "$K/b2_head.out" 2>&1; rh=$?
echo "    head: rc $rh, $(tail -1 "$K/b2_head.out")"
[[ $rh == 0 && "$(/usr/bin/grep -cE '^ *FAILED ' "$K/b2_head.out")" == 0 ]] && ok "HEAD: green, in a worktree with no raw file" || nok "HEAD: rc $rh"
mkdir -p "$T/empty"
NOT_TEE_FIXTURE_DIR="$T/empty" bash tests/shell/test_gate_exit_code_not_tee.sh < /dev/null > "$K/b2_head_nofixture.out" 2>&1; rn=$?
echo "    head, fixture dir empty: rc $rn   red: $(red_names "$K/b2_head_nofixture.out" | cut -c1-200)"
/usr/bin/grep -A2 -E '^ *FAILED +case 2 ' "$K/b2_head_nofixture.out" | /usr/bin/grep -q 'UNRUNNABLE' \
    && ok "HEAD with no fixture and no raw: case 2 is RED, and says the gate was UNRUNNABLE" || nok "HEAD with no data: case 2 not red on UNRUNNABLE"
mkdir -p "$T/real"
for f in t008_poll_twin.jsonl t008_poll_client.json; do
    git show "audit-raw:doc/audit/2026-08-20_sampling-rate-and-cpu/raw/$f" > "$T/real/$f"
done
echo "    the real trace, read from audit-raw into a temp dir: sha256 $(sha256sum "$T/real/t008_poll_twin.jsonl" | cut -c1-16)…"
gate() { ( set +u; . doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env >/dev/null 2>&1
           NDT_SAMPLING_RAW_DIR="$1" PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" doc/audit/2026-08-31_sampling-ceiling-after-merge/ratio_gate.py \
               --check t008_poll --expect green 2>&1; echo "rc=$?" ); }
gate "$T/real" > "$K/b2_verdict_real.out"; gate tests/shell/fixtures/gate_exit_code_not_tee > "$K/b2_verdict_fixture.out"
for w in real fixture; do echo "    $w:"; sed 's/^/      /' "$K/b2_verdict_$w.out"; done
vr="$(/usr/bin/grep -oE 'verdict=[A-Z]+' "$K/b2_verdict_real.out")"; vf="$(/usr/bin/grep -oE 'verdict=[A-Z]+' "$K/b2_verdict_fixture.out")"
mr="$(/usr/bin/grep -oE 'mark=[A-Z+-]+' "$K/b2_verdict_real.out" | head -1)"; mf="$(/usr/bin/grep -oE 'mark=[A-Z+-]+' "$K/b2_verdict_fixture.out" | head -1)"
[[ -n "$vr" && "$vr" == "$vf" && "$mr" == "$mf" ]] && ok "the fixture takes the real trace's path: $vr, $mr in both, through the ratio (not UNRUNNABLE)" \
    || nok "the fixture's verdict ($vf, $mf) is not the real trace's ($vr, $mr)"
echo "== b3 test_l1_shell_scoring group C, and mutate_l1_shell_scoring's baseline"
b="tests/shell/.redfirst-stale-base-test_l1_shell_scoring.sh"; git show 8746c1bc:tests/shell/test_l1_shell_scoring.sh > "$b"; COPIES+=("$WT/$b")
bash "$b" < /dev/null > "$K/b3_base.out" 2>&1; rb=$?
bash tests/shell/test_l1_shell_scoring.sh < /dev/null > "$K/b3_head.out" 2>&1; rh=$?
echo "    base: rc $rb, $(tail -1 "$K/b3_base.out")   head: rc $rh, $(tail -1 "$K/b3_head.out")"
[[ $rb != 0 && "$(/usr/bin/grep -cE '^ *FAILED +C ' "$K/b3_base.out")" == 12 ]] && ok "8746c1bc: group C red on 12 suites" || nok "8746c1bc: rc $rb, $(/usr/bin/grep -cE '^ *FAILED +C ' "$K/b3_base.out") C reds"
[[ $rh == 0 && "$(/usr/bin/grep -cE '^ *ok +C ' "$K/b3_head.out")" -ge 60 ]] && ok "HEAD: green, $(/usr/bin/grep -cE '^ *ok +C ' "$K/b3_head.out") group C checks ok" || nok "HEAD: rc $rh"
# the gate at 8746c1bc, in a tree of that commit: its "kills" were vacuous; HEAD's gate refuses there
d="$T/l1base"; mkdir -p "$d"; git archive 8746c1bc tools/test_workflow tests/shell | tar -x -C "$d"
( cd "$d" && bash tests/shell/mutate_l1_shell_scoring.sh < /dev/null > "$K/b3_gate_old_at_base.out" 2>&1 ); r1=$?
cp tests/shell/mutate_l1_shell_scoring.sh "$d/tests/shell/.head-mutate_l1_shell_scoring.sh"
( cd "$d" && bash tests/shell/.head-mutate_l1_shell_scoring.sh < /dev/null > "$K/b3_gate_new_at_base.out" 2>&1 ); r2=$?
echo "    8746c1bc's gate on 8746c1bc: rc $r1, $(tail -1 "$K/b3_gate_old_at_base.out") -- with the suite already red: $(/usr/bin/grep -c '^  KILLED' "$K/b3_gate_old_at_base.out") KILLED"
[[ $r1 == 0 ]] && ok "  the old gate PASSED on a red baseline (every kill vacuous)" || nok "  the old gate did not pass (rc $r1)"
echo "    HEAD's gate on 8746c1bc: rc $r2, $(/usr/bin/grep -m1 'refused' "$K/b3_gate_new_at_base.out")"
[[ $r2 == 2 ]] && /usr/bin/grep -q 'refused: the suite is RED with no mutation' "$K/b3_gate_new_at_base.out" \
    && ok "  HEAD's gate refuses there (rc 2): a red baseline" || nok "  HEAD's gate did not refuse (rc $r2)"
echo "== b3 group C, old (8746c1bc) vs new vs new-without-rule-(2), on one corpus and its four mutants"
# a sandbox of HEAD's corpus; the three suites sit beside it under dot-names (outside the test_*.sh
# glob, so none of them reads the others). Only the TARGET suite's group C line is read.
sb="$T/l1disc"
mk_sb() {
    rm -rf "$sb"; mkdir -p "$sb/tools/test_workflow" "$sb/tests/shell"
    cp tools/test_workflow/l1_unit_tests.sh tools/test_workflow/components.env "$sb/tools/test_workflow/"
    cp tests/shell/test_*.sh "$sb/tests/shell/"
    git show 8746c1bc:tests/shell/test_l1_shell_scoring.sh > "$sb/tests/shell/.old-l1.sh"
    cp tests/shell/test_l1_shell_scoring.sh "$sb/tests/shell/.new-l1.sh"
    python3 - "$sb/tests/shell/.new-l1.sh" "$sb/tests/shell/.norule2-l1.sh" <<'PYN' || nok "rule (2) did not come out"
import sys
s = open(sys.argv[1]).read()
a = '''bare="$(awk -v n="$last" 'NR > n && /^[[:space:]]*exit[[:space:]]+[1-9]/ {print NR; exit}' "$suite")"'''
assert s.count(a) == 1
open(sys.argv[2], "w").write(s.replace(a, 'bare=""'))
PYN
}
cmut() {   # cmut <M0..M4>: apply that corpus mutant (the gate's own four, and M0 = none) to the sandbox
    python3 - "$sb/tests/shell" "$1" <<'PYM'
import sys
d, m = sys.argv[1], sys.argv[2]
F, P = d + "/test_faults.sh", d + "/test_stack_log_rotation.sh"
def sub(p, pairs):
    s = open(p).read(); b = s
    for a, c in pairs:
        s = s.replace(a, c)
    assert s != b, m
    open(p, "w").write(s)
g = ('echo "Ran $((PASS + FAIL)) checks, all passed"', 'echo "everything is fine"')
f = ('echo "Ran $((PASS + FAIL)) checks, $FAIL failed"', 'echo "something failed"')
pf = "printf '\\nRan %d checks, %d failed\\n'"
if m == "M1": sub(F, [g])
if m == "M2": sub(F, [g, f])
if m == "M3": sub(P, [(pf, "printf '\\nDone: %d, %d\\n'")])
if m == "M4": sub(P, [(pf + ' "$((PASS+FAIL))" "$FAIL"\n[[ "$FAIL" -eq 0 ]] || exit 1\n',
                       'if [[ "$FAIL" -ne 0 ]]; then\n    ' + pf + ' "$((PASS+FAIL))" "$FAIL"\n    exit 1\nfi\n')])
PYM
}
cline() {  # cline <suite file> <target> -> ok | FAILED (the target's group C line)
    ( cd "$sb" && bash "tests/shell/$1" < /dev/null 2>&1 ) > "$K/b3_disc_${1#.}_$3.out"
    /usr/bin/grep -m1 -oE "^  (ok|FAILED) +C  ${2//./\\.}('s| )" "$K/b3_disc_${1#.}_$3.out" | awk '{print $1}'
}
declare -A R
for m in M0 M1 M2 M3 M4; do
    mk_sb; [[ $m == M0 ]] || cmut "$m" || nok "$m did not apply"
    case $m in M0) tg=(test_faults.sh test_stack_log_rotation.sh) ;; M1|M2) tg=(test_faults.sh) ;; *) tg=(test_stack_log_rotation.sh) ;; esac
    for t in "${tg[@]}"; do for v in old new norule2; do
        R[$m,$t,$v]="$(cline ".$v-l1.sh" "$t" "$m-${t%.sh}")"
    done; echo "    $m  $t:  old ${R[$m,$t,old]:-?}   new ${R[$m,$t,new]:-?}   new-without-rule-(2) ${R[$m,$t,norule2]:-?}"; done
done
disc() { [[ "${R[M0,$2,$1]}" == ok && "${R[$3,$2,$1]}" == FAILED ]] && echo yes || echo no; }   # disc <suite> <target> <mutant>
row() { echo "$(disc "$1" test_faults.sh M1)$(disc "$1" test_faults.sh M2)$(disc "$1" test_stack_log_rotation.sh M3)$(disc "$1" test_stack_log_rotation.sh M4)"; }
echo "    discriminates (green before, red after) M1 M2 M3 M4:  old $(row old)   new $(row new)   new-without-rule-(2) $(row norule2)"
[[ "$(row new)" == yesyesyesyes ]] && ok "the new group C discriminates all four" || nok "the new group C: $(row new)"
[[ "$(row old)" == yesyesnono ]] && ok "the old one discriminates M1 M2 only (red on the printf suite before any mutation)" || nok "the old one: $(row old)"
[[ "$(row norule2)" == noyesyesno ]] && ok "without rule (2) the new one misses M1 and M4: the bare-exit rule is what catches them" || nok "without rule (2): $(row norule2)"
rm -f "${COPIES[@]}"
echo "STALE-RED-FIRST: $([[ $bad == 0 ]] && echo 'b1, b2 and b3 red at 8746c1bc, green at HEAD' || echo BROKEN)"
exit $bad
