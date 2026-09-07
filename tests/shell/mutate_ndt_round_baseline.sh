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
# N12-N17 cover the two things decided on 09-07 (grill §4E round 3): NOT RESTORED is a --check
# problem so the rc goes red (E-9, measured printing red at rc 0 on the 04:36 live arm), and
# `ndt release` retires .test_run/round.baseline to .prev (E-11).
#
# N18-N25 cover the correction Adam made that evening (18:1x, R3-NDT §7-1/§7-2): `ndt up p4 4`
# writes the knob through, so E-9 made the standard P4 round red from its own second command
# to its last. E-9b records what ndt wrote (up_wrote=) and demotes that one value to a warning;
# E-11b moves the deadline to `ndt release`, which refuses while the knob is not back.
#
# 🔴 TWO DIRECTIONS. The mutations marked (widening) stay GREEN where the suite requires RED:
# one warns whenever the value is not 4, which is on through every legitimate 128-host round;
# one reports no baseline as a match; one makes the no-baseline value a --check problem, which
# is red on every 128-host round nobody claimed; one retires the round baseline on a release
# that held no claim; one excuses a hand edit because a note exists at all; one reads a missing
# note as "ndt wrote it"; one refuses every release, so --force stops meaning anything; one
# lets the value `ndt up` wrote be released without a word. All of them look like a working
# alarm, and the four E-9b/E-11b ones look like the FIX.
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

# --- E-9: NOT RESTORED is a --check problem, so the rc goes red ---------------------------------
#
# The state these four restore is the 04:36 live arm (rounds/08-round2.md:146): the row printed
# `8 -- this round started at 128: NOT RESTORED` in red and `ndt status --check` returned 0.
# A report whose exit code never moves is one more green light, which is the thing W16-2 was
# decided against. [Co-developed with claude code -- Adam]

# 🔴 E-9 itself: the row prints and raises nothing.
m=$(mutant n12 "$NDT" \
    '        STATUS_KNOB_PROBLEMS+=("the P4 host knob is NOT RESTORED: $rel is $now, this round started at $base -- write $base back ('\''echo $base > $rel'\''), not '\''git checkout --'\'', which gives you HEAD. (I-3)")' \
    '        :')
report "N12: NOT RESTORED prints red and raises nothing" "$m" \
       "🔴 and it is listed as a problem"

# The other half of the same wire: the row fills the list and cmd_status never reads it. Two
# places, because a mutation that only deleted one of them would leave the other looking like
# the whole mechanism.
m=$(mutant n13 "$NDT" \
    '    (( ${#STATUS_KNOB_PROBLEMS[@]} > 0 )) && problems+=("${STATUS_KNOB_PROBLEMS[@]}")' \
    '    :')
report "N13: cmd_status stops merging the knob problems" "$m" \
       "🔴 --check exits 1 (it exited 0 over this at 04:36)"

# (widening) The no-baseline value is a problem too. Adam ruled on ONE sentence; this branch
# cannot tell a forgotten restore from a deliberate 128-host round that never claimed, so
# folding it in turns --check red on every such round -- and it satisfies every case above.
m=$(mutant n14 "$NDT" \
    "    printf '  %-14s %s\\n' \"\" \"the next 'ndt up p4' builds \$now hosts. (I-3)\"" \
    "    printf '  %-14s %s\\n' \"\" \"the next 'ndt up p4' builds \$now hosts. (I-3)\"
    STATUS_KNOB_PROBLEMS+=(\"the P4 host knob is NOT RESTORED: \$rel is \$now and no baseline exists\")")
report "N14 (widening): the no-baseline value is a problem too" "$m" \
       "🔴 but it is not a problem"

# --- E-11: `ndt release` retires the round baseline ---------------------------------------------

# 🔴 E-11 itself: R2-NDT left the file behind on purpose and nothing removed it, so a round that
# ended kept being compared against -- `status` would say NOT RESTORED about somebody else's
# chosen value.
m=$(mutant n15 "$NDT" \
    '    if [[ -f "$rb" ]]; then' \
    '    if false; then')
report "N15: 'ndt release' leaves the round baseline behind" "$m" \
       "🔴 the round baseline is gone"

# The NAME, separately. `.prev` is the lab.handoff precedent and it is what the testing manual
# and the round-closing checklist tell a human to go and read; a rename to anything else is
# indistinguishable from a delete for everyone who was told where to look.
m=$(mutant n16 "$NDT" \
    '        mv -f "$rb" "$rb.prev" 2>/dev/null \' \
    '        mv -f "$rb" "$rb.old" 2>/dev/null \')
report "N16: the baseline is retired under a different name" "$m" \
       "🔴 and kept as .prev, not deleted"

# (widening) The early return retires it too. Releasing a claim you never held is a no-op and
# says nothing about whose round is running -- retiring there ends somebody else's round from
# a command that reported doing nothing.
m=$(mutant n17 "$NDT" \
    '    if [[ ! -f "$CLAIM" ]]; then ok "no claim to release"; return 0; fi' \
    '    if [[ ! -f "$CLAIM" ]]; then local rb0; rb0="$(round_baseline_file)"; [[ -f "$rb0" ]] && mv -f "$rb0" "$rb0.prev"; ok "no claim to release"; return 0; fi')
report "N17 (widening): 'no claim to release' retires it anyway" "$m" \
       "🔴 and leaves the baseline where it is"

# --- E-9b: what `ndt up p4` wrote is a warning, a hand edit is still a problem ------------------
#
# The state these four are about is the standard P4 round, which E-9 turned red end to end:
# `ndt claim` records host_count=128, `ndt up p4 4` writes 4 through set_host_count, and from
# that second command onward every `--check` said NOT RESTORED and exited 1 -- on every P4 arm
# arm_up.sh:45 runs. Adam's decision 09-07 18:1x (R3-NDT §7-1). [Co-developed with claude code -- Adam]

# 🔴 E-9b itself: the write happens and nothing records that ndt was the one who did it, so the
# middle answer can never be reached and every P4 round is back to being red throughout.
m=$(mutant n18 "$NDT" \
    '    note_up_wrote_host_count "$n"' \
    '    :')
report "N18: 'ndt up p4' leaves no note that it wrote the knob" "$m" \
       "🔴 the baseline records that ndt wrote it"

# The other half of the same wire: the note is written and the row ignores it -- exactly the
# behaviour of ee0b399e, which is the thing being corrected.
m=$(mutant n19 "$NDT" \
    "            printf '  %-14s %s\\n' \"\" \"'ndt release' refuses while these differ; 'ndt release --force' releases anyway\"" \
    "            printf '  %-14s %s\\n' \"\" \"'ndt release' refuses while these differ; 'ndt release --force' releases anyway\"
            STATUS_KNOB_PROBLEMS+=(\"the P4 host knob is NOT RESTORED: \$rel is \$now, this round started at \$base\")")
report "N19: the value 'ndt up' wrote is a --check problem again" "$m" \
       "🔴 --check is green (rc 1 for the whole round before E-9b)"

# (widening) Any value at all gets the warning once a note exists. That excuses the 04:36 case
# -- somebody's `echo 8 >` after an `ndt up p4 4` -- which is the case E-9 was decided on, and
# it satisfies every "not a problem" assertion above.
m=$(mutant n20 "$NDT" \
    '        if [[ -n "$upw" && "$now" == "$upw" ]]; then' \
    '        if [[ -n "$upw" ]]; then')
report "N20 (widening): a hand edit is excused too" "$m" \
       "🔴 and still a problem"

# (widening) A baseline with NO note is treated as though ndt wrote whatever is there. That is
# the pre-E-9 world with extra steps: every forgotten restore in a round that never ran
# `ndt up p4` goes quiet, and groups 8-11 -- the finding itself -- stop proving anything.
m=$(mutant n21 "$NDT" \
    '        if [[ -n "$upw" && "$now" == "$upw" ]]; then' \
    '        if [[ -z "$upw" || "$now" == "$upw" ]]; then')
report "N21 (widening): no note is read as 'ndt wrote it'" "$m" \
       "🔴 no note means NOT RESTORED, exactly as before"

# --- E-11b: `ndt release` refuses while the knob is not back ------------------------------------
#
# E-9b took the deadline off every status call, so it has to bite somewhere. One line below the
# check, the baseline becomes .prev and the question stops being answerable at all.

# 🔴 E-11b itself: release stops asking, and the round ends with the knob wherever it was left.
m=$(mutant n22 "$NDT" \
    '    if [[ -n "$knob_base" ]]; then' \
    '    if false; then')
report "N22: 'ndt release' does not look at the knob" "$m" \
       "🔴 release refuses"

# The escape hatch, separately. A refusal with no override strands a round that ended with the
# knob deliberately elsewhere, and the answer to that is a flag you sign, not a check nobody
# can pass -- the same `--force` the foreign-claim refusal above already takes.
m=$(mutant n23 "$NDT" \
    '            if [[ "${1:-}" != "--force" ]]; then' \
    '            if true; then')
report "N23: '--force' does not release either" "$m" \
       "🔴 --force releases anyway"

# (widening) Refuse whenever a baseline exists. Every release now needs --force, so --force
# stops meaning anything -- and it satisfies every "release refuses" assertion above.
m=$(mutant n24 "$NDT" \
    '        if [[ "$knob_now" != "$knob_base" ]]; then' \
    '        if true; then')
report "N24 (widening): release refuses even with the knob back" "$m" \
       "release succeeds"

# (widening) The up_wrote note excuses the value at release time too. That is the one place it
# must NOT: "ndt wrote it" is why the value is acceptable DURING the round, and precisely why
# it is not acceptable at the end -- the next round's `ndt up p4` reads this file and nothing
# else does. With this in, a P4 round can end at 4 with a baseline of 128 and never say so.
m=$(mutant n25 "$NDT" \
    '        if [[ "$knob_now" != "$knob_base" ]]; then' \
    '        if [[ "$knob_now" != "$knob_base" && "$knob_now" != "$(round_baseline_field up_wrote)" ]]; then')
report "N25 (widening): what 'ndt up' wrote is released without a word" "$m" \
       "🔴 but release still refuses"

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
