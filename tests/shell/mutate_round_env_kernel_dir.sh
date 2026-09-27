#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_round_env_kernel_dir.sh -- does that suite notice a round.env
# that names some OTHER checkout than the one it sits in?
#
# [Co-developed with claude code -- Adam]
#
# The defect (N7): both round.env files hard-coded KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel, so
# every suite and gate that sources them from a worktree read the main checkout. M1 and M7 put
# that line back; the others are the near misses a fix is likely to make instead -- the caller's
# cwd, one directory short, an override that is silently ignored, one exported path or one mkdir
# still pointing at a fixed tree.
#
# 🔴 Guards its own baseline: every mutation goes into a COPY in a temp dir and the suite is
# pointed at the copies through E_ROUND_ENV_UNDER_TEST / F5_ROUND_ENV_UNDER_TEST. The round.env
# files in this checkout are never written; their sha256 is compared before and after. Anchors
# are counted in the REAL files, so a reworded line reports a missing anchor here and in
# tests/shell/check_gate_anchors.py.
#
# Run:  bash tests/shell/mutate_round_env_kernel_dir.sh
# Exit: 0 every mutation caught and the controls stayed green; 1 a mutation survived or a control
#       went red; 2 refused (baseline red, or an anchor did not occur exactly once); 3 a round.env
#       in the checkout changed during the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

E_ENV=doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env
F_ENV=doc/audit/2026-08-31_f5-fine-grid-round/round.env
TEST=tests/shell/test_round_env_kernel_dir.sh

BK="$(mktemp -d "${TMPDIR:-/tmp}/round-env-kdir-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$E_ENV" "$F_ENV" | sha256sum | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
CONTROLS_RED=0

# fresh <tag> -- unmutated copies of both files; echoes the directory holding e.env and f.env
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

run_suite() {   # run_suite <dir> -- the suite against the copies in <dir>
    E_ROUND_ENV_UNDER_TEST="$1/e.env" F5_ROUND_ENV_UNDER_TEST="$1/f.env" timeout 300 bash "$TEST" 2>&1
}

# report <label> <dir> <check that must go red>... -- red on EVERY named check, or it survived
report() {
    local label="$1" dir="$2"; shift 2
    local out rc want missing=()
    MUTATIONS=$((MUTATIONS + 1))
    out="$(run_suite "$dir")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-60s (suite still green)\n' "$label"; return
    fi
    for want in "$@"; do
        grep -qF "  FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-60s (%d named check(s) went red)\n' "$label" "$#"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-60s (red, but NOT on every named check)\n' "$label"
        printf '             still green: %s\n' "${missing[@]}"
    fi
}

control() {   # control <label> <dir> -- behaviour-preserving; the suite must stay GREEN
    local label="$1" dir="$2" out rc
    out="$(run_suite "$dir")"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  control  %-60s (stayed green, as it must)\n' "$label"
    else
        CONTROLS_RED=$((CONTROLS_RED + 1))
        printf '  🔴 CONTROL %-58s (went RED -- this suite reddens for any edit)\n' "$label"
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

# --- the E round -------------------------------------------------------------------------------
d="$(fresh m1)"
apply_exact "$E_ENV" \
  'export KERNEL_DIR="${KERNEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:?round.env must be sourced by bash}")/../../.." && pwd)}"' \
  'export KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel' "$d/e.env"
report "M1: E names the main checkout again (the defect)" "$d" \
       "🔴 E: KERNEL_DIR is the tree the file sits in" \
       "🔴 E: a second checkout gets its own KERNEL_DIR"

d="$(fresh m2)"
apply_exact "$E_ENV" \
  '$(cd "$(dirname "${BASH_SOURCE[0]:?round.env must be sourced by bash}")/../../.." && pwd)' \
  '$(pwd)' "$d/e.env"
report "M2: E derives from the caller's working directory" "$d" \
       "🔴 E: KERNEL_DIR is the tree the file sits in" \
       "🔴 E: sourced from inside ANOTHER checkout, it still names its own"

d="$(fresh m3)"
apply_exact "$E_ENV" \
  'must be sourced by bash}")/../../.." && pwd)}"' \
  'must be sourced by bash}")/../.." && pwd)}"' "$d/e.env"
report "M3: E stops one directory short of the checkout" "$d" \
       "🔴 E: KERNEL_DIR is the tree the file sits in"

d="$(fresh m4)"
apply_exact "$E_ENV" \
  '"${KERNEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:?round.env must be sourced by bash}")/../../.." && pwd)}"' \
  '"$(cd "$(dirname "${BASH_SOURCE[0]:?round.env must be sourced by bash}")/../../.." && pwd)"' "$d/e.env"
report "M4: E ignores an exported KERNEL_DIR" "$d" \
       "E: an exported KERNEL_DIR is honoured" \
       "  E: and ROUND follows it"

d="$(fresh m5)"
apply_exact "$E_ENV" \
  'export PRIOR="$KERNEL_DIR/doc/audit/2026-08-20_sampling-rate-and-cpu"' \
  'export PRIOR="/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu"' "$d/e.env"
report "M5: one exported E path still names a fixed tree" "$d" \
       "🔴 E: every path it exports is inside that tree"

d="$(fresh m6)"
apply_exact "$E_ENV" \
  'mkdir -p "$OUT" "$KBIN_STAGE"' \
  'mkdir -p "$OUT" "/home/adam/Desktop/NDTwin-Kernel/.test_run/binaries/e-round"' "$d/e.env"
report "M6: E creates one directory in a fixed tree" "$d" \
       "🔴 E: every directory it creates is inside that tree"

# --- the F-5 round -----------------------------------------------------------------------------
d="$(fresh m7)"
apply_exact "$F_ENV" \
  'export KERNEL_DIR="${KERNEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:?round.env must be sourced by bash}")/../../.." && pwd)}"' \
  'export KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel' "$d/f.env"
report "M7: F5 names the main checkout again (the defect)" "$d" \
       "🔴 F5: KERNEL_DIR is the tree the file sits in" \
       "🔴 F5: a second checkout gets its own KERNEL_DIR"

d="$(fresh m8)"
apply_exact "$F_ENV" \
  'must be sourced by bash}")/../../.." && pwd)}"' \
  'must be sourced by bash}")/../../../.." && pwd)}"' "$d/f.env"
report "M8: F5 climbs one directory past the checkout" "$d" \
       "🔴 F5: KERNEL_DIR is the tree the file sits in"

# --- the control -------------------------------------------------------------------------------
# Rewording the comment on the line under test must change nothing. Without it, every line above
# could be measuring "the file is not byte-identical" instead of "the behaviour is different".
d="$(fresh c1)"
apply_exact "$E_ENV" \
  '# the checkout this file is in; an exported KERNEL_DIR overrides' \
  '# the checkout this file lives in (an exported KERNEL_DIR still wins)' "$d/e.env"
control "C1 (control): the comment on E's KERNEL_DIR line is reworded" "$d"

echo
if [[ "$(sha256sum "$E_ENV" "$F_ENV" | sha256sum | cut -d' ' -f1)" != "$BASE_SHA" ]]; then
    echo "🔴 a round.env in this checkout CHANGED during the gate"
    exit 3
fi
echo "baseline byte-identical: yes"
if [[ "$SURVIVORS" -eq 0 && "$CONTROLS_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; control green"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROLS_RED control(s) red"
exit 1
