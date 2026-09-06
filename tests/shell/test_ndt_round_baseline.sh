#!/usr/bin/env bash
#
# Does `ndt status` notice that the P4 host knob has not been put back?
#
# [Co-developed with claude code -- Adam]
#
# 09-05 R7 finding I-3 (rounds/03-R7-reconciler.md), decided 09-07 (grill §4D round 10).
# `p4_proxy/mininet/host_count_override` was working tree 4 / HEAD 128 that night -- the
# LAB-RULES red line, because restoring it means WRITING 4, and `git checkout --` gives 128.
# R4 wrote 128 into it for a 128-host round, and BOTH restoration instruments went blind at
# once, because both derived their answer from git dirtiness:
#
#     git status --porcelain | wc -l          22  ->  21     (the machine LEFT its baseline
#                                                             and the number went DOWN)
#     ndt status:
#       code  68c1dde4  +22 file(s) with uncommitted changes
#                       1 of them can change behaviour:
#                       p4_proxy/mininet/host_count_override      <- this block DISAPPEARED
#
# The value was still printed in the configuration section. What vanished was the WARNING, at
# the moment the knob held the value that changes the most behaviour. Two guards, one flawed
# signal: not redundant, blind together. (MEMORY: "the clean version is the one you have to go
# back and check".)
#
# 🔴 THREE DIRECTIONS, because "warn about the knob" has wrong answers that look like fixes:
#   * warn whenever the value is not 4 -- group 3 is the 128-host round that is SUPPOSED to be
#     running at 128, and it must be able to say "this is what this round started with";
#   * warn only when git calls the file dirty -- group 1 is the finding itself, and the file is
#     CLEAN there;
#   * count the dirty files instead of naming them -- group 5: the count moves the wrong way,
#     and no count can express "this path left the set".
#
# Offline: a throwaway git repository in a temp dir. No lab, no kernel, no sudo, no network.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_ndt_round_baseline.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; exit 2; }
for sib in ports.sh sudo_surface.sh; do
    [[ -r "$(dirname "$NDT")/$sib" ]] || { echo "ndt needs $sib beside it; not at $(dirname "$NDT")/$sib"; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "this suite needs git"; exit 2; }

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
has()   { grep -qF -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2'"; }
hasnt() { grep -qF -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in the output" || t_ok "$1"; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-round-base-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# --- the 09-05 machine, in miniature ------------------------------------------------------
# HEAD carries 128 (that is what is committed on trunk), the working tree carries 4 (that is
# what the night was actually running). Reproducing that pairing is the whole point: it is the
# state in which "restore" and "match HEAD" are OPPOSITE instructions.
git -C "$FIX" init -q 2>/dev/null || { echo "git init failed"; exit 2; }
git -C "$FIX" config user.email fixture@example.invalid
git -C "$FIX" config user.name  fixture
mkdir -p "$FIX/p4_proxy/mininet" "$FIX/.test_run" "$FIX/src"
KNOB="$FIX/p4_proxy/mininet/host_count_override"
printf '128\n' > "$KNOB"
printf 'baseline\n' > "$FIX/src/Thing.cpp"
printf 'readme\n'   > "$FIX/README.md"
# As the real repo does (.gitignore:21). It matters here: the round baseline lives under
# .test_run/, and an untracked baseline file would add a line to `git status --porcelain` --
# the very count these cases are about.
printf '.test_run/\n' > "$FIX/.gitignore"
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" commit -qm "fixture: HEAD carries 128, as trunk does" >/dev/null 2>&1

knob()  { printf '%s\n' "$1" > "$KNOB"; }
dirty_count() { git -C "$FIX" status --porcelain | wc -l | tr -d ' '; }
no_baseline() { rm -f "$FIX/.test_run/round.baseline"; }

STUBS='
REPO="'"$FIX"'"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
'
drive() {   # drive <shell-code> -> output + RC=
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# ==========================================================================================
section "1. 🔴 the finding: the knob at 128 with git calling the file CLEAN"
# The night's baseline is 4, so the round baseline says 4. R4 writes 128 for a 128-host round
# and stops there. git now agrees with HEAD, so nothing git-shaped can see it.
knob 4
BEFORE="$(dirty_count)"
OUT="$(drive 'record_round_baseline')"
knob 128
AFTER="$(dirty_count)"
check "🔴 the porcelain count moved the WRONG way (22->21 on 09-05)" "yes" \
      "$( (( AFTER < BEFORE )) && echo yes || echo no)"
check "  and git itself calls the knob clean"          "" \
      "$(git -C "$FIX" status --porcelain -- p4_proxy/mininet/host_count_override)"

OUT="$(drive 'git_lines')"
has   "🔴 the alarm fires anyway"                       "NOT RESTORED" "$OUT"
has   "  naming the value it should be"                 "this round started at 4" "$OUT"
has   "  and the value it is"                           "knob baseline  128" "$OUT"
has   "🔴 and saying the thing that made this invisible" "git calls this file CLEAN (it matches HEAD) -- that is NOT 'restored'" "$OUT"
has   "  it hands over the restore command"             "echo 4 > p4_proxy/mininet/host_count_override" "$OUT"
has   "🔴 and warns against the one that gives 128"     "NOT 'git checkout --'" "$OUT"

section "2. 🔴 a clean tree does not stop the check"
# The old git_lines returned early on a clean tree. That is exactly the state the knob's most
# dangerous value produces, so the early return WAS the bug.
git -C "$FIX" stash -q -u >/dev/null 2>&1 || true
git -C "$FIX" checkout -q -- . 2>/dev/null
knob 128
check "the tree really is clean now"                    "0" "$(dirty_count)"
OUT="$(drive 'git_lines')"
has   "the code row still says clean tree"              "(clean tree)" "$OUT"
has   "🔴 and the knob is still checked"                "NOT RESTORED" "$OUT"

section "3. 🔴 the other direction: a 128-host round that is MEANT to be at 128"
# Without this the change is satisfied by "always warn when != 4", and a warning that is on
# during every legitimate P4-128 round is a warning nobody reads.
knob 128
OUT="$(drive 'record_round_baseline; knob_row')"
has   "it says the value matches what the round started with" "128 == the value this round started with" "$OUT"
hasnt "  and does not shout"                            "NOT RESTORED" "$OUT"

section "4. no baseline: the unconditional fallback Adam named"
no_baseline
knob 128
OUT="$(drive 'knob_row')"
has   "🔴 128 with no baseline is still printed"        "128 != 4, and no round baseline exists" "$OUT"
has   "  saying what it decides"                        "builds 128 hosts" "$OUT"
knob 4
OUT="$(drive 'knob_row')"
has   "  and 4 with no baseline is quiet but explicit"  "4 (the default; no round baseline recorded" "$OUT"
hasnt "  nothing red about it"                          "NOT RESTORED" "$OUT"

section "5. 🔴 the restoration check compares the SET, not the count"
no_baseline
knob 4                                   # the night's real working-tree value: dirty vs HEAD
printf 'edited\n' > "$FIX/src/Thing.cpp"
OUT="$(drive 'record_round_baseline')"
has   "the baseline records the paths, sorted"          "recorded this round's starting point" "$OUT"
BASE_FILE="$FIX/.test_run/round.baseline"
has   "  the knob's value is in it"                     "host_count=4" "$(cat "$BASE_FILE")"
has   "  and both dirty paths"                          "dirty=p4_proxy/mininet/host_count_override" "$(cat "$BASE_FILE")"
has   "  including the other one"                       "dirty=src/Thing.cpp" "$(cat "$BASE_FILE")"

BEFORE="$(dirty_count)"
knob 128                                  # leaves the dirty set by MATCHING HEAD
AFTER="$(dirty_count)"
check "🔴 the count says the tree got cleaner"          "yes" "$( (( AFTER < BEFORE )) && echo yes || echo no)"
OUT="$(drive 'tree_vs_round_row')"
has   "🔴 the set difference names the path that LEFT"  "- p4_proxy/mininet/host_count_override" "$OUT"
has   "  and says what leaving the set means"           "now matches HEAD -- which is not the same as restored" "$OUT"
has   "  counted in both directions"                    "1 file(s) LEFT the uncommitted set" "$OUT"

printf 'new\n' > "$FIX/src/Added.cpp"
OUT="$(drive 'tree_vs_round_row')"
has   "🔴 a path that JOINED the set is named too"      "+ src/Added.cpp" "$OUT"
rm -f "$FIX/src/Added.cpp"

section "6. 🔴 no baseline is said, not assumed"
no_baseline
OUT="$(drive 'tree_vs_round_row')"
has   "it says there is nothing to compare against"     "nothing here can say what this round changed" "$OUT"
hasnt "  and never reports a match"                     "same set of uncommitted files" "$OUT"

section "7. the wiring: 'ndt claim' is what records a round"
no_baseline
knob 4
OUT="$(bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
NDT_OWNER=fixture-owner
cmd_claim 5 'a round'
echo \"RC=\$?\"" 2>&1)"
check "claim succeeds"                                  "0" "$(rc_of "$OUT")"
check "🔴 and it wrote the baseline"                    "yes" \
      "$( [[ -f "$BASE_FILE" ]] && echo yes || echo no)"
has   "  with the owner in it"                          "by=fixture-owner" "$(cat "$BASE_FILE" 2>/dev/null)"
has   "  and the knob's value at that moment"           "host_count=4" "$(cat "$BASE_FILE" 2>/dev/null)"

# 🔴 git_lines has to CALL both rows, or the whole file is a set of functions nobody runs.
OUT="$(drive 'git_lines')"
has   "git_lines runs the knob check"                   "knob baseline" "$OUT"
has   "  and the set comparison"                        "tree vs round" "$OUT"

# --- done ---------------------------------------------------------------------------------
# 🔴 `echo`, not printf: tests/shell/test_l1_shell_scoring.sh group C reads the LAST
# `echo "..."` out of every suite's SOURCE and requires it to render a count the scorer in
# tools/ can read. A summary printed with printf is invisible to it.
echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
