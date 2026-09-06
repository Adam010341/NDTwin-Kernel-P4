#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_round_baseline.sh (09-05 R7 finding I-3).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of I-3 -- the P4 host knob at 128 with git calling the file
# clean, `git status --porcelain | wc -l` moving 22 -> 21 as the machine LEFT its baseline, and
# `ndt status`'s "can change behaviour" block disappearing at that exact moment -- or one of the
# wrong answers "warn about the knob" invites, and must turn its NAMED case red.
#
# 🔴 TWO DIRECTIONS. The mutations marked (widening) stay GREEN where the suite requires RED:
# one warns whenever the value is not 4, which is on through every legitimate 128-host round;
# one reports no baseline as a match. Both look like a working alarm.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the suite is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it -- and the sha256 line at the bottom says so.
#
# 🔴 A mutant directory carries ports.sh, sudo_surface.sh and components.env: ndt sources them
# from beside itself and exits 2 without them, so every case would go red for the wrong reason.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 the file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
SH_TEST="$HERE/test_ndt_round_baseline.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/round-base-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_sh() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$SH_TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_sh "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- the finding: the alarm derived from git dirtiness ----------------------------------------

# 🔴 I-3 itself. The knob's most dangerous value is the one that EQUALS HEAD, so an alarm keyed
# on git dirtiness is silent exactly there.
m=$(mutant n1 "$NDT" \
    '        if [[ "$now" == "$base" ]]; then' \
    '        if git -C "$REPO" diff --quiet -- "$rel" 2>/dev/null; then')
report "N1: the alarm goes back to asking git" "$m" \
       "🔴 the alarm fires anyway"

# The early return that WAS the bug: a clean tree is the state the dangerous value produces.
m=$(mutant n2 "$NDT" \
    '        echo "  (clean tree)"' \
    '        echo "  (clean tree)"; return')
report "N2: git_lines returns early on a clean tree" "$m" \
       "🔴 and the knob is still checked"

# (widening) Warn whenever the value is not 4. On through every legitimate 128-host round, so
# nobody reads it -- and it satisfies every "the alarm fires" case above.
m=$(mutant n3 "$NDT" \
    '    base="$(round_baseline_field host_count)"' \
    '    base=""')
report "N3 (widening): the round baseline is never consulted" "$m" \
       "it says the value matches what the round started with"

# The row stops naming the thing that made I-3 invisible.
m=$(mutant n4 "$NDT" \
    '        gitstate="git calls this file CLEAN (it matches HEAD) -- that is NOT '\''restored'\''"' \
    '        gitstate="clean"')
report "N4: the row stops saying git calls the file clean" "$m" \
       "🔴 and saying the thing that made this invisible"

# 🔴 LAB-RULES hard rule 5, in red: restoring this knob is WRITING the value. `git checkout --`
# gives HEAD, which is 128 -- the wrong direction, from the instrument that is supposed to help.
m=$(mutant n5 "$NDT" \
    "        printf '  %-14s %s\\n' \"\" \"  echo \$base > \$rel      # NOT 'git checkout --', which gives you HEAD\"" \
    "        printf '  %-14s %s\\n' \"\" \"  git checkout -- \$rel\"")
report "N5: the restore advice becomes the one that gives 128" "$m" \
       "  it hands over the restore command"

# ...and the warning against it, separately: the advice can be right while the trap it exists
# to name is dropped, and the trap is the part LAB-RULES prints in red.
m=$(mutant n5b "$NDT" \
    "', which gives you HEAD\"" \
    "\"")
report "N5b: the 'not git checkout --' warning is dropped" "$m" \
       "🔴 and warns against the one that gives 128"

# --- the restoration check: the set, not the count --------------------------------------------

# 🔴 The direction a count cannot express. On 09-05 the count went 22 -> 21 as the knob LEFT the
# dirty set, and every "<= baseline is clean" rule passed.
m=$(mutant n6 "$NDT" \
    '    removed="$(comm -23 "$basefile" "$nowfile")"' \
    '    removed=""')
report "N6: a path that LEFT the uncommitted set is not named" "$m" \
       "🔴 the set difference names the path that LEFT"

m=$(mutant n7 "$NDT" \
    '    added="$(comm -13 "$basefile" "$nowfile")"' \
    '    added=""')
report "N7: a path that JOINED the set is not named" "$m" \
       "🔴 a path that JOINED the set is named too"

# The baseline records the count and not the paths, so there is no set to difference.
m=$(mutant n8 "$NDT" \
    "        git -C \"\$REPO\" status --porcelain 2>/dev/null | cut -c4- | sort | sed 's/^/dirty=/'" \
    '        :')
report "N8: the baseline stores no file list" "$m" \
       "  and both dirty paths"

# (widening) No baseline reported as a match -- "could not check" printed as "checked and fine",
# which is the conflation this repository keeps finding.
m=$(mutant n9 "$NDT" \
    '        printf '\''  %-14s %s\n'\'' "tree vs round" "no baseline in ${f#$REPO/} -- nothing here can say what this round changed ('\''ndt claim'\'' records one)"' \
    '        printf '\''  %-14s %s\n'\'' "tree vs round" "same set of uncommitted files as when the round started"')
report "N9 (widening): no baseline is reported as a match" "$m" \
       "it says there is nothing to compare against"

# --- the wiring -------------------------------------------------------------------------------

m=$(mutant n10 "$NDT" \
    '    knob_row
    tree_vs_round_row' \
    '    tree_vs_round_row')
report "N10: git_lines stops running the knob check" "$m" \
       "git_lines runs the knob check"

m=$(mutant n11 "$NDT" \
    '    record_round_baseline || warn "could not record the round baseline; '\''ndt status'\'' will say so"' \
    '    :')
report "N11: 'ndt claim' stops recording the round" "$m" \
       "🔴 and it wrote the baseline"

echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
