#!/usr/bin/env bash
#
# Does doc/2026-08-17_testing-manual.md still call a merged fix "being worked on"?
#
# [Co-developed with claude code -- Adam]
#
# ## The defect this file exists to stop (KNOWN-ISSUES G-52)
#
# A branch lands and nobody goes back to retract the caveat that was written while it was still
# a branch. The document keeps telling a reader that a tool misbehaves, months after it stopped;
# the reader either works around a defect that is gone, or -- worse -- reads the whole paragraph
# as stale and skips the half that is still true. Three of these were sitting in §2.1 of the
# manual on 2026-09-12, all three naming FIX-NDT-6, which had merged at 05:56 that morning
# (`1656bdba`). One of them, the `ndt help` note, was already verified wrong by FIX-DOC-3 and was
# left in place because it was out of that ticket's scope.
#
# Nothing catches this. A document is not compiled, and the sentence "the fix is in FIX-NDT-6"
# stays grammatical forever. The only judge that does not decay is the repository itself:
# `git merge-base --is-ancestor <that ticket's merge> HEAD`. This file asks git.
#
# ## The two directions
#
# 🔴 DIRECTION ONE IS THE TOOL, AND IT IS WHY CASES 1-4 EXIST. A test that only asks "does the
# manual still say 在修" is passed perfectly by deleting the word -- a document that claims a fix
# nobody made is worse than one that claims a defect nobody has. So cases 2-4 go and find, in
# `ndt help`'s live output and in `tools/test_workflow/ndt` itself, the sentences the manual now
# says the tool prints. Case 1 is the negative half (the three-port sentence is GONE from help)
# and it is NOT allowed to stand on its own: an empty help text contains no sentence at all, so a
# negative assertion about it is green for the wrong reason. Case 2 is its pair, and M5 in the
# mutation gate takes `ndt help` away from this file to prove the pairing is load-bearing.
#
# 🔴 CASE 4 IS THE SECOND DIRECTION INSIDE DIRECTION ONE. `ndt clean` was made to stop calling
# this checkout's own processes strangers. The fix that would pass a naive test is "never say it
# at all" -- and that sentence is the only warning an operator gets before a :8000 that a P4
# session did not start. The tool's own comment says the stranger half must stay. Case 4 asserts
# it is still there.
#
# DIRECTION TWO IS THE DOCUMENT. Each swept caveat is marked in the manual with
#     <!-- NDT-MERGED-CAVEAT:BEGIN <id> <merge sha> -->  ...  <!-- NDT-MERGED-CAVEAT:END <id> -->
# and cases 5a-5c assert, per caveat: it is marked, it says 已修, the sha it names really is an
# ancestor of HEAD, and it carries no in-progress word. Case 6 is the general sweep -- ANY line
# of the manual that names a ticket and calls it unfixed, when git says that ticket is merged.
# Case 6 is the one that will catch the NEXT one of these, in a part of the document this ticket
# never read.
#
# 🔴 CASE 0 IS THE INSTRUMENT'S OWN CHECK. Case 6 asks git a question; if git cannot answer, an
# unanswered question would come back as "no violations" and this file would certify the very
# thing it is for. Case 0 asserts that the lookup resolves for a ticket that IS merged, so a
# broken lookup goes red HERE and by name, instead of going quiet over there.
#
# A line may quote what the document USED TO say -- FIX-DOC-3 left such a note at §2.8. The
# convention is one word: a line carrying 原本 or 曾經 is a record of a past wording, not a claim
# about today, and case 6 skips it. It is a suppression, so it is greppable, and M4 removes the
# word to show it is not a blanket.
#
# CASE 10 IS THE CONTROL and it is green on the unfixed manual as well as on the fixed one: a
# suite that is all-red before the fix cannot tell "sensitive" from "stuck red".
#
# 🔴 CASE 9 IS WHY A SWEEP IS NOT A DELETION. The three caveats carry a measured record -- 74 `XX`
# lines, two pids, the `--check` row that contradicted them. Retracting the caveat must not take
# the measurement with it: "已修" is a claim about today, the log is what happened. Case 9 asserts
# the record survived the sweep.
#
# Nothing is built, no lab is touched, nothing is written: this reads one markdown file, reads
# `tools/test_workflow/ndt`, runs `ndt help` (which prints text and exits 2) and asks git about
# ancestry.
#
# Overridable for the mutation gate, which must never write this worktree's copies:
#   MANUAL=<path>  NDT=<path>  bash tests/shell/test_manual_no_stale_in_progress.sh
#
# REPO_UNDER_TEST= is the tree git is asked about. It defaults to the tree this file is in, and
# the gate sets it explicitly so that running the TEST from a temp copy does not turn case 0 red
# for a reason that has nothing to do with the mutation being applied.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_UNDER_TEST:-$(cd "$HERE/../.." && pwd)}"
MANUAL="${MANUAL:-$REPO/doc/2026-08-17_testing-manual.md}"
NDT="${NDT:-$REPO/tools/test_workflow/ndt}"

PASS=0
FAIL=0
check() {   # check <what> <expected> <actual>
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

[[ -r "$MANUAL" ]] || { echo "FAILED   the manual is not readable: $MANUAL"; exit 2; }
[[ -r "$NDT"    ]] || { echo "FAILED   ndt is not readable: $NDT"; exit 2; }

# --- the tool ---------------------------------------------------------------------------------
# `ndt help` exits 2 by design (§2.0 of the manual), so its status is not read here.
HELP="$(bash "$NDT" help 2>&1)"
NDT_SRC="$(cat "$NDT")"

# --- git, the only judge of "is this ticket still a branch" -------------------------------------
# A ticket FIX-NDT-6 is branch fix/ndt-6-<date>, and its merge commit says so in its subject.
# Asking `git log --merges HEAD` means anything found is reachable from HEAD by construction.
ticket_merge() {   # ticket_merge FIX-NDT-6 -> the merge sha reachable from HEAD, or ""
    local br
    br="fix/$(tr 'A-Z' 'a-z' <<<"${1#FIX-}")-"
    git -C "$REPO" log --merges --format='%H %s' HEAD 2>/dev/null \
        | grep -F -- " Merge $br" | head -1 | cut -d' ' -f1
}
is_ancestor() {   # is_ancestor <sha> -> yes | no
    git -C "$REPO" merge-base --is-ancestor "$1" HEAD >/dev/null 2>&1 && echo yes || echo no
}

# --- case 0: the instrument can ask the question ------------------------------------------------
# Without this, a git that cannot answer makes case 6 green by silence.
check "case 0  git resolves a merged ticket (FIX-NDT-6 -> a merge reachable from HEAD)" \
      "yes" "$( [[ -n "$(ticket_merge FIX-NDT-6)" ]] && echo yes || echo "no (lookup returned nothing)" )"

# --- cases 1-4: the tool really is what the manual now says it is --------------------------------
check "case 1  'ndt help' no longer names only three ports for --deep" \
      0 "$(grep -c -F -- ':8000/:8080/:8081' <<<"$HELP")"
check "case 2  'ndt help' prints --deep's size out of ports.sh's table" \
      1 "$(grep -c -F -- '9 rule(s), 27 port(s)' <<<"$HELP")"
check "case 3  'ndt' tells an operator its own fabric is its own" \
      1 "$(grep -c -F -- 'the fabric this stack started is still up' <<<"$NDT_SRC")"
check "case 4  'ndt' still has the stranger sentence (the fix was not 'never say it')" \
      1 "$(grep -c -F -- 'err "   this stack did not start it' <<<"$NDT_SRC")"

# --- the manual's marked caveats -----------------------------------------------------------------
caveat_sha() {   # caveat_sha <id> -> the sha its BEGIN marker names, or ""
    sed -n "s/.*NDT-MERGED-CAVEAT:BEGIN $1 \([0-9a-f]\{7,\}\).*/\1/p" "$MANUAL" | head -1
}
caveat_region() {   # caveat_region <id> -- the lines strictly between its BEGIN and its END
    awk -v b="NDT-MERGED-CAVEAT:BEGIN $1 " -v e="NDT-MERGED-CAVEAT:END $1" '
        index($0, e) { on=0 }
        on           { print }
        index($0, b) { on=1 }' "$MANUAL"
}
IN_PROGRESS='在修|待修|尚未修|還沒修|未修|未改|落地之前'

# --- cases 5a-5c: one cell per swept caveat -------------------------------------------------------
# marked / says 已修 / the sha it names is an ancestor of HEAD / no in-progress word left.
caveat_case() {   # caveat_case <letter> <id>
    local id="$2" region sha marked fixed anc clean words
    region="$(caveat_region "$id")"
    sha="$(caveat_sha "$id")"
    if [[ -z "$region" || -z "$sha" ]]; then
        check "case 5$1 caveat '$id' is retracted and says what merged it" \
              "marked/已修/merged/no-in-progress" "absent/-/-/-"
        return
    fi
    marked=marked
    grep -q '已修' <<<"$region" && fixed=已修 || fixed='NO-已修'
    [[ "$(is_ancestor "$sha")" == yes ]] && anc=merged || anc="NOT-AN-ANCESTOR($sha)"
    words="$(grep -oE "$IN_PROGRESS" <<<"$region" | sort -u | tr '\n' ',' | sed 's/,$//')"
    [[ -z "$words" ]] && clean=no-in-progress || clean="IN-PROGRESS($words)"
    check "case 5$1 caveat '$id' is retracted and says what merged it" \
          "marked/已修/merged/no-in-progress" "$marked/$fixed/$anc/$clean"
}
caveat_case a clean-calls-your-fabric-residue
caveat_case b help-deep-names-three-ports
caveat_case c clean-advises-deep-on-your-own

# --- case 6: the general sweep --------------------------------------------------------------------
# Any line that names a ticket AND calls it unfixed, where git says that ticket is already merged.
# A line recording a past wording says so with 原本 or 曾經 and is skipped; M4 removes that word.
VIOLATIONS=0
while IFS= read -r line; do
    n="${line%%:*}"
    text="${line#*:}"
    grep -qE '原本|曾經' <<<"$text" && continue
    for t in $(grep -oE 'FIX-[A-Z]+-[0-9]+' <<<"$text" | sort -u); do
        m="$(ticket_merge "$t")"
        [[ -z "$m" ]] && continue
        VIOLATIONS=$((VIOLATIONS + 1))
        echo "             $(basename "$MANUAL"):$n  calls $t unfixed, but $m is reachable from HEAD"
    done
done < <(grep -nE "$IN_PROGRESS" "$MANUAL" | grep -E 'FIX-[A-Z]+-[0-9]+')
check "case 6  no line calls a ticket unfixed when its merge is already in the tree" \
      0 "$VIOLATIONS"

# --- cases 7-8: the manual quotes the tool it now relies on ------------------------------------------
# Retracting a caveat means describing what the tool does now. A retraction that quotes nothing is
# an assertion; these two are the sentences cases 2 and 3 found in the tool.
# A count, not an exact number: quoting the same tool sentence in two places is legitimate here
# (the summary caveat and the fold-out both need it), and an exact count would go red on an edit
# that is not a drift. Zero is the failure this pair is about.
n7=$(grep -c -F -- '9 rule(s), 27 port(s)' "$MANUAL")
n8=$(grep -c -F -- 'the fabric this stack started is still up' "$MANUAL")
check "case 7  the manual quotes help's computed --deep size" \
      "yes" "$( [[ "$n7" -ge 1 ]] && echo yes || echo "no ($n7)" )"
check "case 8  the manual quotes clean's own-fabric sentence" \
      "yes" "$( [[ "$n8" -ge 1 ]] && echo yes || echo "no ($n8)" )"

# --- case 9: the sweep retracted the caveat, not the measurement --------------------------------------
REC="$(caveat_region clean-advises-deep-on-your-own)"
check "case 9  the measured record inside the third caveat survived the sweep" \
      "1/1/1" \
      "$(grep -c -F -- '74 行 `XX`' <<<"$REC")/$(grep -c -F -- 'XX  residue: ndtwin_kernel pid 2511227 holding :8000 (tcp)' <<<"$REC")/$(grep -c -F -- 'kernel.child.pid=2511227 alive' <<<"$REC")"

# --- case 10 (CONTROL): a sentence this ticket does not touch -------------------------------------------
check "case 10 CONTROL: §2.1 still says the machine's 4 veth are not residue" \
      1 "$(grep -c -F -- '這台機器上永遠有 4 條 veth，它們不是殘留。' "$MANUAL")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
