#!/usr/bin/env bash
# redfirst_stale.sh <worktree> <keep dir> -- fix/stale-suites-0927, red first for (b1) and (b2), every
# suite output KEPT under <keep dir>. [Co-developed with claude code -- Adam]
#   b1  test_start_bg_log_rotation: at 8746c1bc red (the six .prev/.prev2 expectations), HEAD green;
#       and the history claim observed, not inferred: the OLD suite against stack.sh at 74c811df^
#       (green) and at 74c811df (red)
#   b2  test_gate_exit_code_not_tee, in this worktree, which has no raw t008_poll: at 8746c1bc red
#       (cases 1, 4) with case 2 green for the wrong reason (the gate said UNRUNNABLE); HEAD green;
#       HEAD with its fixture dir EMPTY -- case 2 now red; and the fixture's verdict beside the
#       real trace's (read from audit-raw into a temp dir, never into the tree)
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
rm -f "${COPIES[@]}"
echo "STALE-RED-FIRST: $([[ $bad == 0 ]] && echo 'b1 and b2 red at 8746c1bc, green at HEAD' || echo BROKEN)"
exit $bad
