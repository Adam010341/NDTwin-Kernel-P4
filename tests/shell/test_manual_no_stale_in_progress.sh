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
# ancestor of HEAD, and it carries no in-progress word. Cases 6 and 6b are the general sweep --
# ANY line of the manual that names a ticket and calls it unfixed, or names a branch and calls it
# unmerged, when git says otherwise. They are the ones that will catch the NEXT one of these, in a
# part of the document this ticket never read.
#
# 🔴 CASE 6b EXISTS BECAUSE CASE 6 MISSED ONE WHILE THIS TICKET WAS BEING WRITTEN. §2.6 said
# `fix/e21-link-endpoints-in-contract` was 未併入 trunk and that seventeen contract checks
# "describe the branch, not trunk"; the branch merged on 2026-09-10 (`bb9301a0`). The line names
# no FIX-<X>-<n>, so the ticket-shaped scan walked straight past it. A gate whose stated job is
# "catch the next one" and cannot see a whole spelling of it is worse than no gate.
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
# CASES 11/11b/11c ARE THE SAME SWEEP OVER EVERY doc/**/*.md OUTSIDE doc/audit/ (FIX-DOC-4 §7-6).
# They read a markdown BLOCK rather than a line, and they let a block off when it retracts in
# place -- when it names a merge commit that is an ancestor of HEAD next to 已修/已併. The long
# comment above those cases is the part to read before changing them.
#
# Overridable for the mutation gate, which must never write this worktree's copies:
#   MANUAL=<path>  NDT=<path>  DOCS=<tree>  bash tests/shell/test_manual_no_stale_in_progress.sh
# DOCS is the tree the doc-wide sweep reads pages out of (default: the tree this file is in).
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
# The same question asked of a branch the document names outright. A caveat does not have to
# name a ticket to go stale: §2.6 said `fix/e21-link-endpoints-in-contract` was 未併入 trunk, and
# that branch merged on 2026-09-10 (`bb9301a0`). Case 6 could not see it -- no FIX-<X>-<n> on the
# line -- which is how the second half of this scan came to exist.
branch_merge() {   # branch_merge fix/e21-... -> the merge sha reachable from HEAD, or ""
    git -C "$REPO" log --merges --format='%H %s' HEAD 2>/dev/null \
        | grep -F -- " Merge $1:" | head -1 | cut -d' ' -f1
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
# The branch-side vocabulary. Kept separate from IN_PROGRESS because the caveat regions are about
# a TOOL being unfixed, while these are about a CHANGE not having landed; folding them together
# would make case 5's actual column say IN-PROGRESS about a sentence that is not in a caveat.
UNMERGED='未併入|尚未併|還沒併|只在分支上|仍在分支上'

# --- cases 5a-5c: one cell per swept caveat -------------------------------------------------------
# marked / says 已修 / the sha it names is an ancestor of HEAD / no in-progress word left.
caveat_case() {   # caveat_case <letter> <id>
    local id="$2" region sha marked fixed anc clean words nb ne
    # 🔴 BOTH markers, counted. Without the END count, deleting the END marker of the LAST caveat
    # makes caveat_region run to the end of the file, and every assertion below passes against a
    # region that is most of the document. M9 of the mutation gate SURVIVED exactly that way, and
    # this is the repair: an unterminated region is not a region.
    nb=$(grep -c "NDT-MERGED-CAVEAT:BEGIN $id " "$MANUAL")
    ne=$(grep -c "NDT-MERGED-CAVEAT:END $id" "$MANUAL")
    region="$(caveat_region "$id")"
    sha="$(caveat_sha "$id")"
    if [[ "$nb" != 1 || "$ne" != 1 ]]; then
        check "case 5$1 caveat '$id' is retracted and says what merged it" \
              "marked/已修/merged/no-in-progress" "markers $nb BEGIN + $ne END (want 1+1)/-/-/-"
        return
    fi
    if [[ -z "$region" || -z "$sha" ]]; then
        check "case 5$1 caveat '$id' is retracted and says what merged it" \
              "marked/已修/merged/no-in-progress" "absent/-/-/-"
        return
    fi
    marked=marked
    # 已修 for a tool that was fixed; 已併入 for a change that merely had not landed. Both are
    # the same statement -- "the thing this caveat warns about is over" -- and a caveat that says
    # neither has not been retracted, it has only been edited.
    grep -qE '已修|已併入' <<<"$region" && fixed=已修 || fixed='NO-已修'
    [[ "$(is_ancestor "$sha")" == yes ]] && anc=merged || anc="NOT-AN-ANCESTOR($sha)"
    words="$(grep -oE "$IN_PROGRESS" <<<"$region" | sort -u | tr '\n' ',' | sed 's/,$//')"
    [[ -z "$words" ]] && clean=no-in-progress || clean="IN-PROGRESS($words)"
    check "case 5$1 caveat '$id' is retracted and says what merged it" \
          "marked/已修/merged/no-in-progress" "$marked/$fixed/$anc/$clean"
}
caveat_case a clean-calls-your-fabric-residue
caveat_case b help-deep-names-three-ports
caveat_case c clean-advises-deep-on-your-own
caveat_case d e21-contract-branch-only

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

# --- case 6b: the same question, asked of a branch the document names outright -------------------
# "still only on a branch" is the same claim as "still being fixed", and it decays the same way.
BVIOLATIONS=0
while IFS= read -r line; do
    n="${line%%:*}"
    text="${line#*:}"
    grep -qE '原本|曾經' <<<"$text" && continue
    for b in $(grep -oE 'fix/[a-z0-9][a-z0-9._-]*' <<<"$text" | sed 's/[.]$//' | sort -u); do
        m="$(branch_merge "$b")"
        [[ -z "$m" ]] && continue
        BVIOLATIONS=$((BVIOLATIONS + 1))
        echo "             $(basename "$MANUAL"):$n  calls $b unmerged, but $m is reachable from HEAD"
    done
done < <(grep -nE "$UNMERGED" "$MANUAL" | grep -E 'fix/[a-z0-9]')
check "case 6b no line calls a branch unmerged when its merge is already in the tree" \
      0 "$BVIOLATIONS"

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

# --- cases 11 / 11b / 11c: the same two questions, asked of every doc page -------------------------------
#
# 🔴 WHY THIS IS NOT JUST "cases 6/6b WITH MORE FILES". G-52's shape is not specific to the
# testing manual, and FIX-DOC-4 §7-6 said so and left it. Running 6/6b's exact rule over the
# other 37 pages produces four hits, and only ONE of them is stale: the other three are entries
# that name a merged ticket precisely BECAUSE they are recording what it did or did not do.
# A sweep that calls those three violations teaches the next reader to silence the gate.
#
# So the doc-wide half asks for one more thing before it calls a line stale: the markdown BLOCK
# the line sits in must not already disclose the merge. "Disclose" is checkable, not a word
# list -- the block has to name a hex sha that resolves in THIS repository to a MERGE commit
# that is an ancestor of HEAD, next to 已修 or 已併. That is the same bargain the manual's
# NDT-MERGED-CAVEAT markers strike (retract in place, name what merged it), written as a rule
# that works in a file which has no markers.
#
# 🔴 THE UNIT IS A BLOCK, NOT A LINE, AND THAT IS LOAD-BEARING. Prose here wraps at ~100 chars,
# so the sentence "§2.8 原本把這一條寫成「FIX-NDT-6 在修」的現行缺陷。現在改成已修 ... `1656bdba`"
# is three lines: the qualifier is on the first, the ticket on the second, the sha on the third.
# Line-scoped reading sees the middle line alone and calls a retraction a stale caveat.
#
# 🔴 WHAT THIS STILL CANNOT DO (FIX-DOC-4 §7-5, now with an instance). ticket_merge is a PREFIX
# match on the branch name, and FIX-NDT-3's branch is `fix/ndt-claim-semantics-0911` -- no ticket
# number in it at all. `fix/ndt-3-` therefore matches `fix/ndt-3-51-helper-apps-window`, a
# different ticket, and the sweep reports THAT sha. The verdict on G-34's line was right and the
# evidence printed next to it was wrong. The violation line below prints the branch it matched
# for exactly this reason: a human reading the failure can see the mismatch. A lookup that
# demanded `fix/<slug>-<4 digits>` would have gone silent on that line instead, which is worse.
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
            echo "             $f:$n  calls $t unfixed; $m ($(merge_branch "$m")) is reachable from HEAD,"
            echo "                    and this block names no merge of its own"
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

# --- case 11c: the sweep's own check -----------------------------------------------------------------
# Cases 11/11b count violations, so an empty file list is indistinguishable from a clean tree.
# This asserts the list exists, every page in it can actually be read out of DOCS, and the two
# pages that carry this repository's caveats are in it. M13 empties the list to show it fires.
PMISS=0
for f in "${PAGES[@]}"; do [[ -r "$DOCS/$f" ]] || PMISS=$((PMISS + 1)); done
check "case 11c the sweep has a page list, all of it readable, with the manual and KNOWN-ISSUES in it" \
      "many/0-unreadable/manual/known-issues" \
      "$( [[ "${#PAGES[@]}" -ge 20 ]] && echo many || echo "only ${#PAGES[@]}" )/$PMISS-unreadable/$(printf '%s\n' "${PAGES[@]}" | grep -qx 'doc/2026-08-17_testing-manual.md' && echo manual || echo NO-manual)/$(printf '%s\n' "${PAGES[@]}" | grep -qx 'doc/KNOWN-ISSUES.md' && echo known-issues || echo NO-known-issues)"

# --- case 10 (CONTROL): a sentence this ticket does not touch -------------------------------------------
check "case 10 CONTROL: §2.1 still says the machine's 4 veth are not residue" \
      1 "$(grep -c -F -- '這台機器上永遠有 4 條 veth，它們不是殘留。' "$MANUAL")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
