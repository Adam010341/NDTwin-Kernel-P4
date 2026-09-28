#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_round_env_kernel_dir.sh -- does that suite notice a round.env
# that names some OTHER checkout than the one it sits in, or a consumer suite that lets it?
#
# [Co-developed with claude code -- Adam]
#
# The defect (N7): both round.env files hard-coded KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel, so
# every suite and gate that sources them from a worktree read the main checkout. M1 and M7 put that
# line back; the rest are the near misses a fix is likely to make instead, in BOTH files -- the
# caller's cwd or $0 instead of the file's own path, one directory short or long, an override that
# is silently ignored, one exported path or one mkdir still pointing at a fixed tree, CDPATH left
# in play, and each of the three guards removed (not bash; no file behind BASH_SOURCE; a
# derivation that is no checkout, e.g. /). M22 and M24 make the no-file guard and the checkout
# guard exit an interactive shell again, M23 lets a relative KERNEL_DIR through. M19-M21 break the two consumer suites instead: an
# inherited KERNEL_DIR no longer dropped, and a missing interpreter read as a green skip again.
#
# 🔴 Guards its own baseline: round.env mutations go into COPIES in a temp dir, pointed at through
# E_ROUND_ENV_UNDER_TEST / F5_ROUND_ENV_UNDER_TEST. A consumer suite finds round.env relative to
# its own location, so its mutated copy is written beside it by mktemp as
# tests/shell/.mutant-<m>-XXXXXX-<name>.sh (only the files this run created are removed on exit)
# and pointed at through GATE_EXIT_SUITE_UNDER_TEST / CELL_WIRING_SUITE_UNDER_TEST.
# No tracked file is written; the sha256 of every file under mutation is compared before and after.
# Anchors are counted in the REAL files, so a reworded line reports a missing anchor here and in
# tests/shell/check_gate_anchors.py.
#
# Run:  bash tests/shell/mutate_round_env_kernel_dir.sh
# Exit: 0 every mutation caught and the controls stayed green; 1 a mutation survived or a control
#       went red; 2 refused (baseline red, or an anchor did not occur exactly once); 3 a file in the
#       checkout changed during the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

E_ENV=doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env
F_ENV=doc/audit/2026-08-31_f5-fine-grid-round/round.env
NOT_TEE=tests/shell/test_gate_exit_code_not_tee.sh
WIRING=tests/shell/test_cell_gate_suspect_wiring.sh
TEST=tests/shell/test_round_env_kernel_dir.sh

BK="$(mktemp -d "${TMPDIR:-/tmp}/round-env-kdir-mutate-XXXXXX")"
CREATED=()
trap 'rm -rf "$BK"; if (( ${#CREATED[@]} )); then rm -f -- "${CREATED[@]}"; fi' EXIT
# mutant_copy <tag> <suite basename> -- MUT = a fresh, uniquely named file beside the real suite
mutant_copy() { MUT="$(mktemp --suffix="-$2" "$HERE/.mutant-$1-XXXXXX")" || exit 2; CREATED+=("$MUT"); }
BASE_SHA="$(sha256sum "$E_ENV" "$F_ENV" "$NOT_TEE" "$WIRING" | sha256sum | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
CONTROLS_RED=0

# fresh <tag> -- unmutated copies of both round.env files; echoes the directory holding them
fresh() {
    local d="$BK/$1"
    rm -rf "$d"; mkdir -p "$d"
    cp "$E_ENV" "$d/e.env"; cp "$F_ENV" "$d/f.env"
    echo "$d"
}

# apply_exact <repo-relative file> <old> <new> <destination file> -- assert the anchor occurs
# exactly once in the REAL file, then write the replacement to the destination. Never writes the
# real file. A substitution that matched nothing would score an unmutated copy as "caught".
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

# run_suite <dir> [NAME=value...] -- the suite against the round.env copies in <dir>
run_suite() {
    local dir="$1"; shift
    env E_ROUND_ENV_UNDER_TEST="$dir/e.env" F5_ROUND_ENV_UNDER_TEST="$dir/f.env" "$@" \
        timeout 1200 bash "$TEST" 2>&1
}

# report <label> <dir> <env-or-"-"> <check that must go red>... -- red on EVERY named check
report() {
    local label="$1" dir="$2" envset="$3"; shift 3
    local out rc want missing=() extra=()
    [[ "$envset" == - ]] || read -r -a extra <<<"$envset"
    MUTATIONS=$((MUTATIONS + 1))
    out="$(run_suite "$dir" "${extra[@]}")"; rc=$?
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

control() {   # control <label> <dir> <env-or-"-"> -- behaviour-preserving; must stay GREEN
    local label="$1" dir="$2" envset="$3" out rc extra=()
    [[ "$envset" == - ]] || read -r -a extra <<<"$envset"
    out="$(run_suite "$dir" "${extra[@]}")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  control  %-62s (stayed green, as it must)\n' "$label"
    else
        CONTROLS_RED=$((CONTROLS_RED + 1))
        printf '  🔴 CONTROL %-60s (went RED -- this suite reddens for any edit)\n' "$label"
        grep '^  FAILED' <<<"$out" | head -3 | sed 's/^/             /'
    fi
}

RO=ROUND_ENV_CONSUMERS=0     # round.env-only mutants: the consumer suites read the REAL round.env

echo "baseline (must be green before any mutation, consumers included):"
base="$(fresh base)"
run_suite "$base" | tail -1 | sed 's/^/  /'
if ! run_suite "$base" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

# --- the E round -------------------------------------------------------------------------------
d="$(fresh m1)"
apply_exact "$E_ENV" \
  '_kd="${KERNEL_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)}"' \
  '_kd="${KERNEL_DIR:-/home/adam/Desktop/NDTwin-Kernel}"' "$d/e.env"
report "M1: E names the main checkout again (the defect)" "$d" "$RO" \
       "🔴 E: KERNEL_DIR is the tree the file sits in" \
       "🔴 E: a second checkout gets its own KERNEL_DIR"

d="$(fresh m2)"
apply_exact "$E_ENV" \
  '$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)' \
  '$(pwd)' "$d/e.env"
report "M2: E derives from the caller's working directory" "$d" "$RO" \
       "🔴 E: KERNEL_DIR is the tree the file sits in" \
       "🔴 E: sourced from inside ANOTHER checkout, it still names its own"

d="$(fresh m3)"
apply_exact "$E_ENV" \
  '")/../../.." >/dev/null && pwd)}"' \
  '")/../.." >/dev/null && pwd)}"' "$d/e.env"
report "M3: E stops one directory short of the checkout" "$d" "$RO" \
       "🔴 E: KERNEL_DIR is the tree the file sits in"

d="$(fresh m4)"
apply_exact "$E_ENV" \
  '_kd="${KERNEL_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)}"' \
  '_kd="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)"' "$d/e.env"
report "M4: E ignores an exported KERNEL_DIR" "$d" "$RO" \
       "E: an exported KERNEL_DIR is honoured" \
       "  E: and ROUND follows it"

d="$(fresh m5)"
apply_exact "$E_ENV" \
  'export PRIOR="$KERNEL_DIR/doc/audit/2026-08-20_sampling-rate-and-cpu"' \
  'export PRIOR="/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu"' "$d/e.env"
report "M5: one exported E path still names a fixed tree" "$d" "$RO" \
       "🔴 E: every absolute path it exports is inside that tree"

d="$(fresh m6)"
apply_exact "$E_ENV" \
  'mkdir -p "$OUT" "$KBIN_STAGE"' \
  'mkdir -p "$OUT" "/home/adam/Desktop/NDTwin-Kernel/.test_run/binaries/e-round"' "$d/e.env"
report "M6: E creates one directory in a fixed tree" "$d" "$RO" \
       "🔴 E: every write it asks for is inside that tree"

d="$(fresh m13)"
apply_exact "$E_ENV" '[ -n "${BASH_VERSION:-}" ] ||' 'true ||' "$d/e.env"
report "M13: E drops the bash guard" "$d" "$RO" \
       "🔴 E: dash is told to use bash"

d="$(fresh m14)"
apply_exact "$E_ENV" '[[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] ||' 'true ||' "$d/e.env"
report "M14: E drops the no-file-behind-BASH_SOURCE guard" "$d" "$RO" \
       "🔴 E: sourced as text (empty BASH_SOURCE) it refuses"

d="$(fresh m15)"
apply_exact "$E_ENV" '[[ "$_kd" == /?* && -d "$_kd/doc/audit" ]] ||' 'true ||' "$d/e.env"
report "M15: E drops the is-it-a-checkout check" "$d" "$RO" \
       "🔴 E: a copy outside any checkout refuses" \
       "🔴 E: an exported KERNEL_DIR that is no checkout is refused"

d="$(fresh m16)"
apply_exact "$E_ENV" \
  '"$(dirname -- "${BASH_SOURCE[0]}")/../../.."' \
  '"$(dirname -- "$0")/../../.."' "$d/e.env"
report "M16: E derives from \$0 instead of its own path" "$d" "$RO" \
       "🔴 E: sourced from inside ANOTHER checkout, it still names its own"

d="$(fresh m18)"
apply_exact "$E_ENV" 'CDPATH= cd -- "$(dirname' 'cd -- "$(dirname' "$d/e.env"
report "M18: E lets CDPATH steer the relative form" "$d" "$RO" \
       "🔴 E: the documented relative form ignores CDPATH"

d="$(fresh m22)"
apply_exact "$E_ENV" \
  'names no file)" >&2; return 1 2>/dev/null || { [[ $- == *i* ]] && kill -INT $$; exit 1; }; }' \
  'names no file)" >&2; return 1 2>/dev/null || exit 1; }' "$d/e.env"
report "M22: E's no-file guard exits an interactive shell again" "$d" "$RO" \
       "🔴 E: and the interactive shell survives (its next command runs)"

d="$(fresh m24)"
apply_exact "$E_ENV" \
  'with doc/audit)" >&2; unset _kd; return 1 2>/dev/null || { [[ $- == *i* ]] && kill -INT $$; exit 1; }; }' \
  'with doc/audit)" >&2; unset _kd; return 1 2>/dev/null || exit 1; }' "$d/e.env"
report "M24: E's checkout guard exits an interactive shell again (a paste)" "$d" "$RO" \
       "🔴 E: pasted line by line into an interactive bash, the shell survives every refusal"

# --- the F-5 round -----------------------------------------------------------------------------
d="$(fresh m7)"
apply_exact "$F_ENV" \
  '_kd="${KERNEL_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)}"' \
  '_kd="${KERNEL_DIR:-/home/adam/Desktop/NDTwin-Kernel}"' "$d/f.env"
report "M7: F5 names the main checkout again (the defect)" "$d" "$RO" \
       "🔴 F5: KERNEL_DIR is the tree the file sits in" \
       "🔴 F5: a second checkout gets its own KERNEL_DIR"

d="$(fresh m8)"
apply_exact "$F_ENV" \
  '")/../../.." >/dev/null && pwd)}"' \
  '")/../../../.." >/dev/null && pwd)}"' "$d/f.env"
report "M8: F5 climbs one directory past the checkout" "$d" "$RO" \
       "🔴 F5: KERNEL_DIR is the tree the file sits in"

d="$(fresh m9)"
apply_exact "$F_ENV" \
  '$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)' \
  '$(pwd)' "$d/f.env"
report "M9: F5 derives from the caller's working directory" "$d" "$RO" \
       "🔴 F5: sourced from inside ANOTHER checkout, it still names its own"

d="$(fresh m10)"
apply_exact "$F_ENV" \
  '_kd="${KERNEL_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)}"' \
  '_kd="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." >/dev/null && pwd)"' "$d/f.env"
report "M10: F5 ignores an exported KERNEL_DIR" "$d" "$RO" \
       "F5: an exported KERNEL_DIR is honoured"

d="$(fresh m11)"
apply_exact "$F_ENV" \
  'export TRH="$KERNEL_DIR/doc/audit/2026-08-30_live-traffic-round/harness"' \
  'export TRH="/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-30_live-traffic-round/harness"' "$d/f.env"
report "M11: one exported F5 path still names a fixed tree" "$d" "$RO" \
       "🔴 F5: every absolute path it exports is inside that tree"

d="$(fresh m12)"
apply_exact "$F_ENV" \
  'mkdir -p "$OUT"' \
  'mkdir -p "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-31_f5-fine-grid-round/raw/$ARM"' "$d/f.env"
report "M12: F5 creates its directory in a fixed tree" "$d" "$RO" \
       "🔴 F5: every write it asks for is inside that tree"

d="$(fresh m17)"
apply_exact "$F_ENV" '[ -n "${BASH_VERSION:-}" ] ||' 'true ||' "$d/f.env"
report "M17: F5 drops the bash guard" "$d" "$RO" \
       "🔴 F5: dash is told to use bash"

d="$(fresh m23)"
apply_exact "$F_ENV" '[[ "$_kd" == /?* && -d "$_kd/doc/audit" ]] ||' '[[ "$_kd" != / && -d "$_kd/doc/audit" ]] ||' "$d/f.env"
report "M23: F5 takes a relative KERNEL_DIR again" "$d" "$RO" \
       "🔴 F5: a relative exported KERNEL_DIR is refused, even from inside a checkout"

# --- the consumer suites -----------------------------------------------------------------------
d="$(fresh m19)"; mutant_copy m19 test_gate_exit_code_not_tee.sh
apply_exact "$NOT_TEE" $'unset KERNEL_DIR\n' $'\n' "$MUT"
report "M19: test_gate_exit_code_not_tee keeps an inherited KERNEL_DIR" "$d" \
       "GATE_EXIT_SUITE_UNDER_TEST=$MUT" \
       "🔴 test_gate_exit_code_not_tee: under an inherited KERNEL_DIR it still tests this checkout"

d="$(fresh m20)"; mutant_copy m20 test_cell_gate_suspect_wiring.sh
apply_exact "$WIRING" $'unset KERNEL_DIR\n' $'\n' "$MUT"
report "M20: test_cell_gate_suspect_wiring keeps an inherited KERNEL_DIR" "$d" \
       "CELL_WIRING_SUITE_UNDER_TEST=$MUT" \
       "🔴 test_cell_gate_suspect_wiring: under an inherited KERNEL_DIR it still tests this checkout"

d="$(fresh m21)"; mutant_copy m21 test_cell_gate_suspect_wiring.sh
apply_exact "$WIRING" \
  '    echo "  $PASS passed, $((FAIL + 1)) failed"
    exit 1' \
  '    echo "  $PASS passed, $((FAIL + 1)) failed"
    exit 0' "$MUT"
report "M21: test_cell_gate_suspect_wiring skips green without an interpreter" "$d" \
       "CELL_WIRING_SUITE_UNDER_TEST=$MUT" \
       "🔴 test_cell_gate_suspect_wiring: a missing interpreter is a failure, not a green skip (rc)"

# --- controls: behaviour-preserving rewrites -----------------------------------------------------
d="$(fresh c1)"
apply_exact "$E_ENV" \
  'so source it by its real path.' \
  'so source it through its real path.' "$d/e.env"
control "C1 (control): a comment in E's header is reworded" "$d" "$RO"

d="$(fresh c2)"
apply_exact "$E_ENV" 'CDPATH= cd -- "$(dirname' 'CDPATH= cd -P -- "$(dirname' "$d/e.env"
control "C2 (control): E resolves with cd -P (no symlinks in the temp trees)" "$d" "$RO"

d="$(fresh c3)"; mutant_copy c3 test_gate_exit_code_not_tee.sh
apply_exact "$NOT_TEE" \
  'a KERNEL_DIR inherited from a shell that once sourced' \
  'a KERNEL_DIR inherited from a shell that had sourced' "$MUT"
control "C3 (control): a comment in the not_tee consumer is reworded" "$d" \
        "GATE_EXIT_SUITE_UNDER_TEST=$MUT"

echo
if [[ "$(sha256sum "$E_ENV" "$F_ENV" "$NOT_TEE" "$WIRING" | sha256sum | cut -d' ' -f1)" != "$BASE_SHA" ]]; then
    echo "🔴 a file under mutation CHANGED in this checkout during the gate"
    exit 3
fi
echo "baseline byte-identical: yes"
if [[ "$SURVIVORS" -eq 0 && "$CONTROLS_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; controls green"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROLS_RED control(s) red"
exit 1
