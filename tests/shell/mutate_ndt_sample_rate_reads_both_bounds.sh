#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_sample_rate_reads_both_bounds.sh.
#
# [Co-developed with claude code -- Adam]
#
# M1 restores the original defect (read only the upper bound). M2 makes rate_label print
# "1/<x>" for everything, i.e. "1/DISABLED:lo=1" -- the fraction a reader skims past. M3 makes
# source_ahead_of_build blind, the way stale_pipeline() already is. Each must turn its named
# case red; a mutation nobody catches means that case proves nothing.
#
# 🔴 Guards its own baseline: the mutations are applied to a COPY of ndt in a temp dir and the
# test is pointed at the copy with NDT_UNDER_TEST. tools/test_workflow/ndt itself is never
# written -- another session may be executing it right now.
#
# 🔴 The copy's directory carries ports.sh, sudo_surface.sh and components.env: ndt sources them
# from beside itself and exits 2 without them, so a mutant would run no checks at all and be
# recorded as a survivor. See mutant() below -- that is exactly what happened here until
# 2026-09-07, and all three mutations were false survivors for it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_sample_rate_reads_both_bounds.sh"
BK=$(mktemp -d /tmp/ndt-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
run_against() { NDT_UNDER_TEST="$1" bash "$TEST" 2>&1; }
report() {   # $1 = mutation name, $2 = mutated copy, $3 = case that must fail
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}
mutant() {   # $1 = name, $2 = python replacing text in the copy; prints the path
    local out="$BK/ndt.$1"; cp "$NDT" "$out"
    # 🔴 ndt sources three files from beside itself -- ports.sh and sudo_surface.sh at the top
    # level, components.env inside a function -- and a missing sudo_surface.sh makes it
    # `exit 2` on the spot. Without these three the test suite could not source the mutant at
    # all: it ran ZERO checks, so the named case "did not go red", so report() below wrote
    # SURVIVED. All three mutations of this gate had been survivors on every rev anybody looked
    # at (ee0b399e, b09d330d, 19a05ddb, trunk 1a284f75) for that reason and no other -- the
    # code under test was fine and this gate had no discriminating power at all.
    # mutate_ndt_round_baseline.sh's mutant() already copies them; so does this one now.
    # [Co-developed with claude code -- Adam]
    cp "$REPO/tools/test_workflow/ports.sh"        "$BK/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$BK/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env"  "$BK/components.env"
    python3 - "$out" "$2" <<'PY'
import sys; p, spec = sys.argv[1], sys.argv[2]; a, b = spec.split("\x1f")
s = open(p).read(); assert s.count(a) == 1, "anchor not unique: " + a[:60]; open(p, "w").write(s.replace(a, b))
PY
    chmod +x "$out"; echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "$NDT" | tail -1
[[ $(run_against "$NDT" >/dev/null 2>&1; echo $?) -eq 0 ]] || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }

m1=$(mutant m1 'return "DISABLED:lo=%d" % lo if lo else hi + 1'$'\x1f''return hi + 1')
report "M1: read only the upper bound (the original defect)" "$m1" "lo=1 hi=255 is reported DISABLED, not 1/256"

m2=$(mutant m2 '        DISABLED:lo=*) echo "SAMPLING DISABLED'$'\x1f''        NEVER-MATCHES) echo "SAMPLING DISABLED')
report "M2: rate_label prints 1/<anything> (1/DISABLED:lo=1)" "$m2" "rate_label: 1/256 for a rate, DISABLED text (not 1/DISABLED) for a dead pipeline"

m3=$(mutant m3 '    [[ "$src" -nt "$built" ]]'$'\x1f''    return 1')
report "M3: source_ahead_of_build is blind (always false)" "$m3" "source newer than build -> ahead (restored .p4, never recompiled)"

echo
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_SHA" ]] && echo "baseline byte-identical: yes" || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
if [[ "$SURVIVORS" -eq 0 ]]; then echo "mutation gate: 3 mutations, 0 survived"; exit 0; else echo "mutation gate: $SURVIVORS survived"; exit 1; fi
