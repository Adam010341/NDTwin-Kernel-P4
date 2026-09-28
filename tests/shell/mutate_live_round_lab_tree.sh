#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_live_round_lab_tree.sh -- does that suite notice a live E /
# F-5 preflight that no longer refuses a tree the lab is not running?
#
# [Co-developed with claude code -- Adam]
#
# M1/M2 remove the call from each preflight (the state before N7 B1). M3-M10 and M16-M19 are the
# ways the check itself can be quietly wrong: comparing paths without resolving symlinks (on either
# side, or with readlink -f, which resolves a path that does not exist), asking the lab in a dry
# run, taking a failed config query for an answer or failing open on it, taking a config that
# names no tree for agreement, inverting the comparison, reading a KERNEL_DIR: line out of the
# refused-conf preamble, and accepting an unset or relative KERNEL_DIR. M11-M15 are the entry
# points: run_f5.sh arming its restore trap before the tree check (arm, q3, restore) and gates_e.sh
# writing its first log line before preflight (main, baseline).
#
# 🔴 Guards its own baseline: mutations go into COPIES in a temp dir and the suite is pointed at
# them through LIB_E_UNDER_TEST / RUN_F5_UNDER_TEST / GATES_E_UNDER_TEST. lib_e.sh, run_f5.sh and
# gates_e.sh in this checkout are never written; their sha256 is compared before and after.
# Anchors are counted in the REAL files. No real sudo is run: the suite's own stub answers the
# only query.
#
# Run:  bash tests/shell/mutate_live_round_lab_tree.sh
# Exit: 0 every mutation caught and the controls stayed green; 1 a mutation survived or a control
#       went red; 2 refused (baseline red, or an anchor did not occur exactly once); 3 a file in the
#       checkout changed during the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LIB=doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh
F5=doc/audit/2026-08-31_f5-fine-grid-round/run_f5.sh
GATES=doc/audit/2026-08-31_sampling-ceiling-after-merge/gates_e.sh
TEST=tests/shell/test_live_round_lab_tree.sh

BK="$(mktemp -d "${TMPDIR:-/tmp}/live-round-lab-tree-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$LIB" "$F5" "$GATES" | sha256sum | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
CONTROLS_RED=0

fresh() {   # fresh <tag> -- unmutated copies of the three files; echoes their directory
    local d="$BK/$1"
    rm -rf "$d"; mkdir -p "$d"
    cp "$LIB" "$d/lib_e.sh"; cp "$F5" "$d/run_f5.sh"; cp "$GATES" "$d/gates_e.sh"
    echo "$d"
}

# apply_exact <repo-relative file> <old> <new> <destination file> -- the anchor must occur exactly
# once in the REAL file; the replacement is written to the destination only.
apply_exact() {
    local file="$1" from="$2" to="$3" dst="$4" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: anchor appears $n time(s) in $file, expected 1"
        echo "     anchor: $from"
        exit 2
    fi
    FROM="$from" TO="$to" perl -0777 -pe 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' \
        "$file" > "$dst"
}

run_suite() {   # run_suite <dir>
    LIB_E_UNDER_TEST="$1/lib_e.sh" RUN_F5_UNDER_TEST="$1/run_f5.sh" GATES_E_UNDER_TEST="$1/gates_e.sh" \
        timeout 300 bash "$TEST" 2>&1
}

report() {   # report <label> <dir> <check that must go red>...
    local label="$1" dir="$2"; shift 2
    local out rc want missing=()
    MUTATIONS=$((MUTATIONS + 1))
    out="$(run_suite "$dir")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-62s (suite still green)\n' "$label"; return
    fi
    for want in "$@"; do
        grep -qF "  FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-62s (%d named check(s) went red)\n' "$label" "$#"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-62s (red, but NOT on every named check)\n' "$label"
        printf '             still green: %s\n' "${missing[@]}"
    fi
}

control() {   # control <label> <dir> -- behaviour-preserving; the suite must stay GREEN
    local label="$1" dir="$2" out rc
    out="$(run_suite "$dir")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  control  %-62s (stayed green, as it must)\n' "$label"
    else
        CONTROLS_RED=$((CONTROLS_RED + 1))
        printf '  🔴 CONTROL %-60s (went RED -- this suite reddens for any edit)\n' "$label"
        grep '^  FAILED' <<<"$out" | head -3 | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base="$(fresh base)"
run_suite "$base" | tail -1 | sed 's/^/  /'
if ! run_suite "$base" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

d="$(fresh m1)"
apply_exact "$LIB" \
  '    local stage="$1" rc=0; lab_tree_check || return 2   # the tree first, before any write (N7); stage: gates|measure|cell|plan' \
  '    local stage="$1" rc=0        # stage: "gates" | "measure" | "cell" | "plan"' "$d/lib_e.sh"
report "M1: E preflight no longer asks which tree (the defect)" "$d" \
       "🔴 E: a live preflight from another tree is refused with rc 2" \
       "🔴 E: and it refused before writing anything (no preflight log)"

d="$(fresh m2)"
apply_exact "$F5" \
  '    local avail owner excl claim; lab_tree_check || return 2; claim="$KERNEL_DIR/.test_run/lab.claim"   # the tree first (N7)' \
  '    local avail owner excl claim; claim="$KERNEL_DIR/.test_run/lab.claim"' "$d/run_f5.sh"
report "M2: F5 preflight no longer asks which tree (the defect)" "$d" \
       "🔴 F5: a live preflight from another tree is refused with rc 2" \
       "🔴 F5: and it refused before writing anything (no preflight log)"

d="$(fresh m3)"
apply_exact "$LIB" \
  '    mine="$(CDPATH= cd -P -- "$KERNEL_DIR" 2>/dev/null && pwd -P)"' \
  '    mine="$KERNEL_DIR"' "$d/lib_e.sh"
report "M3: E compares paths without resolving symlinks" "$d" \
       "🔴 E: the lab's tree reached through a symlink passes too"

d="$(fresh m4)"
apply_exact "$F5" \
  '[[ "${DRY_RUN:-0}" == 1 ]] && return 0' \
  ': "dry runs ask too"' "$d/run_f5.sh"
report "M4: F5 asks the lab in a dry run" "$d" \
       "  F5: and does not call sudo at all"

d="$(fresh m5)"
apply_exact "$LIB" \
  'if ! cfg="$($lab_cmd config 2>&1)"; then' \
  'cfg="$($lab_cmd config 2>&1)"; if false; then' "$d/lib_e.sh"
report "M5: E takes a failed config query for an answer" "$d" \
       "  E: and says it could not ask"

d="$(fresh m6)"
apply_exact "$F5" \
  '    if [[ -n "$mine" && -n "$theirs" && "$mine" == "$theirs" ]]; then' \
  '    if [[ -z "$lab" || "$mine" == "$theirs" ]]; then' "$d/run_f5.sh"
report "M6: F5 takes a config that names no tree for agreement" "$d" \
       "🔴 F5: a config that names no KERNEL_DIR is a refusal (rc 2)"

d="$(fresh m7)"
apply_exact "$LIB" \
  '    if [[ -n "$mine" && -n "$theirs" && "$mine" == "$theirs" ]]; then' \
  '    if [[ -n "$mine" && -n "$theirs" && "$mine" != "$theirs" ]]; then' "$d/lib_e.sh"
report "M7: E inverts the comparison" "$d" \
       "🔴 E: a live preflight from another tree is refused with rc 2" \
       "E: the lab's own tree passes the check"

d="$(fresh m8)"
apply_exact "$F5" \
  '    mine="$(CDPATH= cd -P -- "$KERNEL_DIR" 2>/dev/null && pwd -P)"' \
  '    mine="$KERNEL_DIR"' "$d/run_f5.sh"
report "M8: F5 compares paths without resolving symlinks" "$d" \
       "🔴 F5: the lab's tree reached through a symlink passes too"

d="$(fresh m9)"
apply_exact "$LIB" \
  $'"$cfg" >&2\n        return 2' \
  $'"$cfg" >&2\n        return 0' "$d/lib_e.sh"
report "M9: E fails open when the config query fails" "$d" \
       "🔴 E: a lab that cannot be asked is a refusal (rc 2)"

d="$(fresh m10)"
apply_exact "$F5" \
  '    theirs="$( [[ -n "$lab" ]] && CDPATH= cd -P -- "$lab" 2>/dev/null && pwd -P)"' \
  '    theirs="$lab"' "$d/run_f5.sh"
report "M10: F5 resolves symlinks on its own side only" "$d" \
       "🔴 F5: and so does a lab config that names this tree through a symlink"

d="$(fresh m11)"
apply_exact "$F5" \
  '    arm)      lab_tree_check || exit 2; trap f5_exit_restore_check EXIT; arm ;;' \
  '    arm)      trap f5_exit_restore_check EXIT; arm ;;' "$d/run_f5.sh"
report "M11: run_f5.sh arm arms its restore trap before the tree check" "$d" \
       "🔴 run_f5.sh arm: no file created or changed in the tree" \
       "🔴 run_f5.sh arm: no restore alarm (nothing was armed)"

d="$(fresh m12)"
apply_exact "$F5" \
  '    q3)       lab_tree_check || exit 2; trap f5_exit_restore_check EXIT; q3 ;;' \
  '    q3)       trap f5_exit_restore_check EXIT; q3 ;;' "$d/run_f5.sh"
report "M12: run_f5.sh q3 arms its restore trap before the tree check" "$d" \
       "🔴 run_f5.sh q3: refused with rc 2" \
       "🔴 run_f5.sh q3: no file created or changed in the tree"

d="$(fresh m13)"
apply_exact "$F5" \
  '    restore)  lab_tree_check || exit 2; trap f5_exit_restore_check EXIT; preflight && assert_kernel_restored ;;' \
  '    restore)  trap f5_exit_restore_check EXIT; preflight && assert_kernel_restored ;;' "$d/run_f5.sh"
report "M13: run_f5.sh restore arms its restore trap before the tree check" "$d" \
       "🔴 run_f5.sh restore: no file created or changed in the tree" \
       "🔴 run_f5.sh restore: no restore alarm (nothing was armed)"

d="$(fresh m14)"
apply_exact "$GATES" \
  $'    preflight gates || { printf \'preflight refused -- nothing below ran\\n\' >&2; exit 2; }   # before any log line (N7)\n    say "=== gates_e start (PREREG-E §2), DRY_RUN=$DRY_RUN ==="' \
  $'    say "=== gates_e start (PREREG-E §2), DRY_RUN=$DRY_RUN ==="\n    preflight gates || { printf \'preflight refused -- nothing below ran\\n\' >&2; exit 2; }' \
  "$d/gates_e.sh"
report "M14: gates_e.sh logs its start line before preflight" "$d" \
       "🔴 gates_e.sh: no file created or changed in the tree"

d="$(fresh m15)"
apply_exact "$GATES" \
  $'    preflight plan || exit 2       # [Co-developed with claude code -- Adam] before the first log line (N7)\n    say "=== gates_e baseline (fabric must be DOWN) ==="' \
  $'    say "=== gates_e baseline (fabric must be DOWN) ==="\n    preflight plan || exit 2' \
  "$d/gates_e.sh"
report "M15: gates_e.sh baseline logs before preflight" "$d" \
       "🔴 gates_e.sh baseline: no file created or changed in the tree"

d="$(fresh m16)"
apply_exact "$LIB" \
  '    if [[ "${KERNEL_DIR:-}" != /* ]]; then' \
  '    if false; then' "$d/lib_e.sh"
report "M16: E takes an unset or relative KERNEL_DIR to the lab" "$d" \
       "🔴 E: a relative KERNEL_DIR is refused even from inside the lab's tree (rc 2)" \
       "  E: and does not ask the lab"

d="$(fresh m17)"
apply_exact "$F5" \
  '    if [[ "${KERNEL_DIR:-}" != /* ]]; then' \
  '    if false; then' "$d/run_f5.sh"
report "M17: F5 takes an unset or relative KERNEL_DIR to the lab" "$d" \
       "🔴 F5: a relative KERNEL_DIR is refused even from inside the lab's tree (rc 2)" \
       "  N-9 run_f5.sh arm: and says KERNEL_DIR is not set"

d="$(fresh m18)"
apply_exact "$LIB" \
  "    lab=\"\$(sed -n 's/^KERNEL_DIR:[[:space:]]*//p' <<<\"\$cfg\" | head -1)\"" \
  "    lab=\"\$(sed -n 's/.*KERNEL_DIR:[[:space:]]*//p' <<<\"\$cfg\" | head -1)\"" "$d/lib_e.sh"
report "M18: E reads a KERNEL_DIR: line out of the refused-conf preamble" "$d" \
       "🔴 E: nor does one naming THIS tree while the lab runs another (rc 2)"

d="$(fresh m19)"
apply_exact "$F5" \
  $'    mine="$(CDPATH= cd -P -- "$KERNEL_DIR" 2>/dev/null && pwd -P)"\n    theirs="$( [[ -n "$lab" ]] && CDPATH= cd -P -- "$lab" 2>/dev/null && pwd -P)"' \
  $'    mine="$(readlink -f -- "$KERNEL_DIR")"\n    theirs="$( [[ -n "$lab" ]] && readlink -f -- "$lab")"' "$d/run_f5.sh"
report "M19: F5 resolves with readlink -f (a missing path resolves too)" "$d" \
       "  F5: the same missing path on both sides is no agreement (rc 2)"

# --- controls: behaviour-preserving rewrites -----------------------------------------------------
d="$(fresh c1)"
apply_exact "$LIB" \
  '    local lab_cmd="${LAB:-sudo -n /usr/local/sbin/ndtwin-lab}" cfg lab mine theirs' \
  '    local lab_cmd="${LAB:-sudo -n /usr/local/sbin/ndtwin-lab}" theirs mine lab cfg' "$d/lib_e.sh"
control "C1 (control): E declares its locals in another order" "$d"

d="$(fresh c2)"
apply_exact "$F5" \
  'preflight calls this ahead of its own first log line' \
  'preflight calls this before its own first log line' "$d/run_f5.sh"
control "C2 (control): a comment in F5's copy is reworded" "$d"

d="$(fresh c3)"
apply_exact "$LIB" \
  $'    mine="$(CDPATH= cd -P -- "$KERNEL_DIR" 2>/dev/null && pwd -P)"\n    theirs="$( [[ -n "$lab" ]] && CDPATH= cd -P -- "$lab" 2>/dev/null && pwd -P)"' \
  $'    mine="$(readlink -e -- "$KERNEL_DIR")"\n    theirs="$( [[ -n "$lab" ]] && readlink -e -- "$lab")"' "$d/lib_e.sh"
control "C3 (control): E resolves with readlink -e (existing paths only, like cd -P)" "$d"

d="$(fresh c4)"
apply_exact "$GATES" \
  '   # before any log line (N7)' \
  '   # ahead of any log line (N7)' "$d/gates_e.sh"
control "C4 (control): a comment in gates_e.sh is reworded" "$d"

echo
if [[ "$(sha256sum "$LIB" "$F5" "$GATES" | sha256sum | cut -d' ' -f1)" != "$BASE_SHA" ]]; then
    echo "🔴 lib_e.sh, run_f5.sh or gates_e.sh in this checkout CHANGED during the gate"
    exit 3
fi
echo "baseline byte-identical: yes"
if [[ "$SURVIVORS" -eq 0 && "$CONTROLS_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; controls green"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROLS_RED control(s) red"
exit 1
