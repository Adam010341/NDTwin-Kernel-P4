#!/usr/bin/env bash
#
# Does any doc page still call a merged fix "being worked on"?
#
# [Co-developed with claude code -- Adam]
#
# ## The defect this file exists to stop (FIXED-ISSUES G-52)
#
# A branch lands and nobody goes back to retract the caveat that was written while it was still
# a branch. The document keeps telling a reader that a tool misbehaves, months after it stopped;
# the reader either works around a defect that is gone, or -- worse -- reads the whole paragraph
# as stale and skips the half that is still true. Three of these were sitting in the old testing
# manual on 2026-09-12, all three naming FIX-NDT-6, which had merged at 05:56 that morning
# (`1656bdba`). That manual has since left this repository. The doc-wide sweep below (cases
# 11-11d) reads every remaining page, but only for Chinese in-progress and unmerged wording.
#
# Nothing catches this. A document is not compiled, and the sentence "the fix is in FIX-NDT-6"
# stays grammatical forever. The only judge that does not decay is the repository itself:
# `git merge-base --is-ancestor <that fix's merge> HEAD`. This file asks git.
#
# ## The two directions
#
# 🔴 DIRECTION ONE IS THE TOOL, AND IT IS WHY CASES 1-4 EXIST. A test that only asks "does the
# document still say 'being fixed' (in Chinese)" is passed perfectly by deleting the word -- a document that claims a fix
# nobody made is worse than one that claims a defect nobody has. So cases 2-4 go and find, in
# `ndt help`'s live output and in `tools/test_workflow/ndt` itself, the sentences the documents
# say the tool prints. Case 1 is the negative half (the three-port sentence is GONE from help)
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
# DIRECTION TWO IS THE DOCUMENT. Case 8 asserts that the user guide quotes the own-fabric
# sentence case 3 found in the tool. The guide deliberately does not type `ndt help`'s computed
# --deep size (it points at `ndt help` instead, and tests/shell/test_manual_rc_table.sh case 15
# keeps a typed copy from coming back), so case 2 has no document-side pair any more.
#
# 🔴 CASE 0 IS THE INSTRUMENT'S OWN CHECK. The sweep asks git a question; if git cannot answer,
# an unanswered question would come back as "no violations" and this file would certify the very
# thing it is for. Case 0 asserts that the lookup resolves for a fix that IS merged, so a broken
# lookup goes red HERE and by name, instead of going quiet over there.
#
# A block may quote what a document USED TO say. The convention is one word: a block carrying
# either of the two Chinese words for "originally" / "once was" (the two skip sites below) is a record of a past wording, not a claim about today, and the sweep skips it.
# It is a suppression, so it is greppable.
#
# CASE 10 IS THE CONTROL: a sentence of the guide this suite does not touch. A suite that is
# all-red cannot tell "sensitive" from "stuck red".
#
# Nothing is built, no lab is touched, nothing is written: this reads the user guide and the
# doc pages, reads `tools/test_workflow/ndt`, runs `ndt help` (which prints text and exits 2)
# and asks git about ancestry.
#
# CASES 11/11b/11c ARE THE SWEEP OVER EVERY doc/**/*.md OUTSIDE doc/audit/. They read a
# markdown BLOCK rather than a line, and they let a block off when it retracts in place -- when it
# names a merge commit that is an ancestor of HEAD next to the Chinese word for "fixed" or "merged". The long comment above those cases
# is the part to read before changing them.
#
# Overridable for the mutation gate, which must never write this worktree's copies (MANUAL names
# the user guide; the variable keeps its old name because the gate passes it):
#   MANUAL=<path>  NDT=<path>  DOCS=<tree>  bash tests/shell/test_manual_no_stale_in_progress.sh
# DOCS is the tree the doc-wide sweep reads pages out of (default: the tree this file is in).
#
# REPO_UNDER_TEST= is the tree git is asked about. It defaults to the tree this file is in, and
# the gate sets it explicitly so that running the TEST from a temp copy does not turn case 0 red
# for a reason that has nothing to do with the mutation being applied.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_UNDER_TEST:-$(cd "$HERE/../.." && pwd)}"
MANUAL="${MANUAL:-$REPO/doc/2026-11-05_user-guide.md}"
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

[[ -r "$MANUAL" ]] || { echo "FAILED   the user guide is not readable: $MANUAL"; exit 2; }
[[ -r "$NDT"    ]] || { echo "FAILED   ndt is not readable: $NDT"; exit 2; }

# --- the tool ---------------------------------------------------------------------------------
# `ndt help` exits 2 by design (section 4.1 of the user guide), so its status is not read here.
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
# The same question asked of a branch a page names outright. A caveat does not have to name a
# work item to go stale: the old testing manual said `fix/e21-link-endpoints-in-contract` was "not yet merged" (in Chinese)
# into trunk after that branch merged on 2026-09-10 (`bb9301a0`), and a scan for FIX-<X>-<n> could not
# see it -- which is how the branch half of the sweep (case 11b) came to exist.
branch_merge() {   # branch_merge fix/e21-... -> the merge sha reachable from HEAD, or ""
    git -C "$REPO" log --merges --format='%H %s' HEAD 2>/dev/null \
        | grep -F -- " Merge $1:" | head -1 | cut -d' ' -f1
}

# --- case 0: the instrument can ask the question ------------------------------------------------
# Without this, a git that cannot answer makes the sweep (case 11) green by silence.
check "case 0  git resolves a merged ticket (FIX-NDT-6 -> a merge reachable from HEAD)" \
      "yes" "$( [[ -n "$(ticket_merge FIX-NDT-6)" ]] && echo yes || echo "no (lookup returned nothing)" )"

# --- cases 1-4: the tool really is what the documents say it is ----------------------------------
check "case 1  'ndt help' no longer names only three ports for --deep" \
      0 "$(grep -c -F -- ':8000/:8080/:8081' <<<"$HELP")"
check "case 2  'ndt help' prints --deep's size out of ports.sh's table" \
      1 "$(grep -c -F -- '9 rule(s), 27 port(s)' <<<"$HELP")"
check "case 3  'ndt' tells an operator its own fabric is its own" \
      1 "$(grep -c -F -- 'the fabric this stack started is still up' <<<"$NDT_SRC")"
check "case 4  'ndt' still has the stranger sentence (the fix was not 'never say it')" \
      1 "$(grep -c -F -- 'err "   this stack did not start it' <<<"$NDT_SRC")"
# The two vocabularies the sweep looks for. Kept apart because the first is about a TOOL being
# unfixed, while the second is about a CHANGE not having landed.
IN_PROGRESS='在修|待修|尚未修|還沒修|未修|未改|落地之前'
UNMERGED='未併入|尚未併|還沒併|只在分支上|仍在分支上'

# --- case 8: the user guide quotes the tool it relies on ----------------------------------------------
# Case 3 found this sentence in the tool; the guide's teardown section tells the reader to expect
# it. Zero is the failure: the guide would describe a tool that says nothing about its own fabric.
n8=$(grep -c -F -- 'the fabric this stack started is still up' "$MANUAL")
check "case 8  the user guide quotes clean's own-fabric sentence" \
      "yes" "$( [[ "$n8" -ge 1 ]] && echo yes || echo "no ($n8)" )"

# --- cases 11 / 11b / 11c: two questions, asked of every doc page ---------------------------------------
#
# 🔴 WHY THIS IS NOT A LINE SCAN. G-52's shape is not specific to one document. A line rule
# (a FIX code next to an in-progress word, merge reachable) run over the 37 other pages of the time
# produced four hits, and only ONE
# recording what it did or did not do. A sweep that calls those three violations teaches the next
# reader to silence the gate.
#
# So the doc-wide half asks for one more thing before it calls a line stale: the markdown BLOCK
# the line sits in must not already disclose the merge. "Disclose" is checkable, not a word
# list -- the block has to name a hex sha that resolves in THIS repository to a MERGE commit
# that is an ancestor of HEAD, next to the Chinese word for "fixed" or "merged". That is the same bargain the old manual's
# NDT-MERGED-CAVEAT markers strike (retract in place, name what merged it), written as a rule
# that works in a file which has no markers.
#
# 🔴 THE UNIT IS A BLOCK, NOT A LINE, AND THAT IS LOAD-BEARING. Prose here wraps at ~100 chars,
# so a sentence such as "§2.8 used to describe this as a current defect, 'FIX-NDT-6 is being fixed'; it now says fixed ... `1656bdba`" (the old manual wrote it in Chinese)
# is three lines: the qualifier is on the first, the ticket on the second, the sha on the third.
# Line-scoped reading sees the middle line alone and calls a retraction a stale caveat.
#
# 🔴 WHAT THIS STILL CANNOT DO (now with an instance). ticket_merge is a PREFIX match on the branch
# name, and a branch can be named `fix/<topic>-<date>` -- no work-item number in it at all.
# `fix/<area>-3-` therefore matches `fix/<area>-3-51-<topic>`, a different work item, and the
# sweep reports THAT sha. The verdict on G-34's line was right and the evidence printed next to it
# was wrong. The violation line below prints the branch it matched for exactly this reason: a human
# reading the failure can see the mismatch. A lookup that demanded `fix/<slug>-<4 digits>` would
# have gone silent on that line instead, which is worse.
#
# DOCS= is the tree the pages are READ from; git is still asked about REPO_UNDER_TEST. The
# mutation gate points DOCS at a mutated copy so this worktree is never written.
DOCS="${DOCS:-$REPO}"
mapfile -t PAGES < <(git -C "$REPO" ls-files -- 'doc/*.md' 'doc/**/*.md' 2>/dev/null \
                     | grep -v '^doc/audit/' | sort -u)

# The markdown block a line belongs to: from the item it starts (list bullet, heading, table
# row, fence) or from the line after the last blank one, down to just before the next of either.
# A `>` blockquote prefix is stripped before deciding, so a quoted note is one block, not one
# block per line.
doc_block() {   # doc_block <file> <line number>
    awk -v L="$2" '
        function bare(s) { sub(/^[ \t]*/, "", s); sub(/^(> ?)+/, "", s); sub(/^[ \t]*/, "", s); return s }
        function blank(s) { return bare(s) == "" }
        function starts(s,  b) { b = bare(s); return b ~ /^([-*+][ \t]|[0-9]+\.[ \t]|#+[ \t]|\||```)/ }
        { a[NR] = $0 }
        END {
            s = L; while (s > 1) { if (starts(a[s])) break; if (blank(a[s-1])) break; s-- }
            e = L; while (e < NR) { if (blank(a[e+1]) || starts(a[e+1])) break; e++ }
            for (i = s; i <= e; i++) print a[i]
        }' "$1"
}

# "This block retracts in place": it says the thing is over AND names the merge that ended it.
# Three conditions on the sha, because two of them are cheap to fake: it has to resolve here, it
# has to be a MERGE commit (>=2 parents -- a topic-branch commit is not a landing), and it has
# to be an ancestor of HEAD. Prints the sha it accepted so the log says why a line was skipped.
block_discloses() {   # block_discloses <block text> -> <sha> | ""
    local blk="$1" tok
    grep -qE '已修|已併' <<<"$blk" || return 0
    for tok in $(grep -oE '[0-9a-f]{7,40}' <<<"$blk" | sort -u); do
        git -C "$REPO" rev-parse --verify --quiet "$tok^{commit}" >/dev/null 2>&1 || continue
        [[ "$(git -C "$REPO" cat-file -p "$tok^{commit}" | grep -c '^parent ')" -ge 2 ]] || continue
        git -C "$REPO" merge-base --is-ancestor "$tok" HEAD >/dev/null 2>&1 || continue
        echo "$tok"; return 0
    done
}
merge_branch() {   # merge_branch <merge sha> -> the branch its subject names
    git -C "$REPO" log -1 --format=%s "$1" 2>/dev/null | sed -n 's/^.*Merge \(fix\/[^: ]*\).*/\1/p'
}
# The line case 11 prints for a violation. A function, not an inline echo, because case 11d runs
# it: the branch name in the parentheses is the ONLY thing that shows a reader the prefix lookup
# matched a DIFFERENT ticket, and there is nothing else in the output to catch it with.
viol_ticket() {   # viol_ticket <page> <line no> <ticket> <merge sha>
    echo "             $1:$2  calls $3 unfixed; $4 ($(merge_branch "$4")) is reachable from HEAD,"
    echo "                    and this block names no merge of its own"
}

PVIOL=0; PVIOLB=0; PSKIP_REC=0; PSKIP_DISC=0
for f in "${PAGES[@]}"; do
    [[ -r "$DOCS/$f" ]] || continue
    while IFS= read -r line; do
        n="${line%%:*}"; text="${line#*:}"
        blk="$(doc_block "$DOCS/$f" "$n")"
        if grep -qE '原本|曾經' <<<"$blk"; then PSKIP_REC=$((PSKIP_REC + 1)); continue; fi
        d="$(block_discloses "$blk")"
        for t in $(grep -oE 'FIX-[A-Z]+-[0-9]+' <<<"$text" | sort -u); do
            m="$(ticket_merge "$t")"
            [[ -z "$m" ]] && continue
            if [[ -n "$d" ]]; then PSKIP_DISC=$((PSKIP_DISC + 1)); continue; fi
            PVIOL=$((PVIOL + 1))
            viol_ticket "$f" "$n" "$t" "$m"
        done
    done < <(grep -nE "$IN_PROGRESS" "$DOCS/$f" | grep -E 'FIX-[A-Z]+-[0-9]+')

    while IFS= read -r line; do
        n="${line%%:*}"; text="${line#*:}"
        blk="$(doc_block "$DOCS/$f" "$n")"
        if grep -qE '原本|曾經' <<<"$blk"; then PSKIP_REC=$((PSKIP_REC + 1)); continue; fi
        d="$(block_discloses "$blk")"
        for b in $(grep -oE 'fix/[a-z0-9][a-z0-9._-]*' <<<"$text" | sed 's/[.]$//' | sort -u); do
            m="$(branch_merge "$b")"
            [[ -z "$m" ]] && continue
            if [[ -n "$d" ]]; then PSKIP_DISC=$((PSKIP_DISC + 1)); continue; fi
            PVIOLB=$((PVIOLB + 1))
            echo "             $f:$n  calls $b unmerged; $m is reachable from HEAD,"
            echo "                    and this block names no merge of its own"
        done
    done < <(grep -nE "$UNMERGED" "$DOCS/$f" | grep -E 'fix/[a-z0-9]')
done
echo "             (sweep: ${#PAGES[@]} page(s); skipped $PSKIP_REC as a record of past wording, $PSKIP_DISC as retracted in place)"
check "case 11  no doc page calls a ticket unfixed without naming the merge that landed it" \
      0 "$PVIOL"
check "case 11b no doc page calls a branch unmerged without naming the merge that landed it" \
      0 "$PVIOLB"

# --- case 11d: the failure line names the branch, and not only the sha --------------------------------
# 🔴 THE SECOND INSTRUMENT CELL, AND THE ONE THAT WAS MISSING UNTIL IT WAS NEEDED. The decision on
# the prefix lookup is "leave it alone, because the failure line prints the branch it matched and a
# reader can see the mismatch". That decision rests entirely on those parentheses being filled in --
# and the FIRST run of this sweep printed `()` on both hits, because the sed wanted a space before
# `Merge` and a merge subject begins at column 1. Nobody noticed: the only lines that could have
# shown it were already red for their own reason, which is exactly how an instrument's own defect
# hides inside the finding it is reporting.
#
# It runs the real printer -- the same function the sweep calls -- on a merge this repository has,
# so it cannot pass by describing what the printer ought to do. M16 puts the old sed back.
d11="$(viol_ticket doc/EXAMPLE.md 1 FIX-NDT-6 "$(ticket_merge FIX-NDT-6)")"
check "case 11d a violation line names the branch the lookup matched, not just the sha" \
      "yes" "$( grep -qE '\(fix/[a-z0-9][a-z0-9._-]*\)' <<<"$d11" \
                && echo yes || echo "no -- $(head -1 <<<"$d11" | sed 's/^ *//')" )"

# --- cases 11e / 11g: the English half of the sweep ---------------------------------------------------
# [Co-developed with claude code -- Adam]
# The Chinese word lists above see the G-52 shape only in pages written in Chinese. The same defect
# in English -- "fixed on a branch, not on trunk", "has not been merged" -- is what the API reference
# said for weeks after the fix had merged (FIXED-ISSUES G-52). A page that must say that a change
# is not yet in `main` says "not in main"; these four phrases are the wording that goes stale.
# Case-insensitive, over the same page list (doc/**/*.md outside doc/audit/, from git). No page
# is allowed to match: a page that needs to quote one of them describes it instead ("described as
# unmerged"), so there is no allow-list to grow.
# Prose here wraps at about 100 columns and a quoted note carries a `>` at the start of each line,
# so a phrase can be split between two lines; the separators between its words therefore accept
# any run of white space and `>`, and the page is read as one record (grep -z).
ENGLISH_STALE='on[\s>]+a[\s>]+branch|not[\s>]+on[\s>]+.?trunk.?|has[\s>]+not[\s>]+been[\s>]+merged|not[\s>]+yet[\s>]+merged'
english_sweep() {   # english_sweep <tree> <page>... -> "page: <phrase as written>" for every stale phrase
    local tree="$1" pg; shift
    for pg in "$@"; do
        [[ -r "$tree/$pg" ]] || continue
        grep -z -o -i -P "$ENGLISH_STALE" "$tree/$pg" | sed -z 's/[[:space:]>]\+/ /g' | tr '\0' '\n' | sed "s|^|$pg: |"
    done
}
EHITS="$(english_sweep "$DOCS" "${PAGES[@]}")"
EVIOL=0
if [[ -n "$EHITS" ]]; then
    EVIOL="$(grep -c . <<<"$EHITS")"
    while IFS= read -r hit; do
        echo "             ${hit%%: *}  says a change is still on a branch or unmerged: \"${hit#*: }\""
    done <<<"$EHITS"
fi
check "case 11e no doc page says a fix is on a branch, not on trunk, or not yet merged" \
      0 "$EVIOL"
# The sweep's own control, run through the same function on a fixture tree: one page with four
# phrasings (one in capitals) that must all be found, one page with two phrasings split across lines
# (one inside a `>` quote) that must be found too, and one page with ordinary sentences about a merge
# that must not be. A pattern gone blind or case-sensitive, one that cannot read a wrapped phrase,
# a pattern widened to everything, or a sweep that reads nothing is red here and nowhere else.
EFIX="$(mktemp -d /tmp/english-sweep-XXXXXX)"
mkdir -p "$EFIX/doc"
printf '%s\n' 'It lives ON A BRANCH.' 'It is not on `trunk`.' 'That change has not been merged.' \
       'It is not yet merged.' > "$EFIX/doc/stale.md"
printf '%s\n' 'The branch was merged on 2026-09-10.' 'The fix is in main.' > "$EFIX/doc/ordinary.md"
printf '%s\n' 'The fix is still' '> on a' '> branch, and that change has not' 'been merged yet.' > "$EFIX/doc/wrapped.md"
check "case 11g the English sweep finds four phrasings, two split across lines, and nothing on an ordinary page" \
      "4/2/0" "$(english_sweep "$EFIX" doc/stale.md | grep -c .)/$(english_sweep "$EFIX" doc/wrapped.md | grep -c .)/$(english_sweep "$EFIX" doc/ordinary.md | grep -c .)"
rm -rf "$EFIX"

# --- case 11c: the sweep's own check -----------------------------------------------------------------
# Cases 11/11b count violations, so an empty file list is indistinguishable from a clean tree.
# This asserts the list exists, every page in it can actually be read out of DOCS, and the user
# guide and KNOWN-ISSUES (the page that carries this repository's caveats) are in it. M15 of the
# mutation gate empties the list to show it fires. The floor is low on purpose: doc/ held 9 pages
# outside doc/audit/ on 2026-11-05, and a new page must not be able to break this case.
PMISS=0
for f in "${PAGES[@]}"; do [[ -r "$DOCS/$f" ]] || PMISS=$((PMISS + 1)); done
check "case 11c the sweep has a page list, all of it readable, with the user guide and KNOWN-ISSUES in it" \
      "many/0-unreadable/user-guide/known-issues" \
      "$( [[ "${#PAGES[@]}" -ge 5 ]] && echo many || echo "only ${#PAGES[@]}" )/$PMISS-unreadable/$(printf '%s\n' "${PAGES[@]}" | grep -qx 'doc/2026-11-05_user-guide.md' && echo user-guide || echo NO-user-guide)/$(printf '%s\n' "${PAGES[@]}" | grep -qx 'doc/KNOWN-ISSUES.md' && echo known-issues || echo NO-known-issues)"

# --- case 10 (CONTROL): a sentence this suite does not touch -------------------------------------
check "case 10 CONTROL: the user guide still says ndt clean stops nothing" \
      1 "$(grep -c -F -- '`ndt clean` stops nothing and deletes no logs' "$MANUAL")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
