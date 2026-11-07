#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_manual_no_stale_in_progress.sh.
#
# [Co-developed with claude code -- Adam]
#
# What is being protected. A document that calls a merged fix "being worked on" (FIXED-ISSUES
# G-52) stays grammatical forever, and nothing in this repository notices it. The test this gate
# protects asks git instead -- is the merge that fixes it an ancestor of HEAD -- over every doc
# page, and checks that the tool still prints the sentences the user guide relies on. These
# mutations put a stale sentence back, or take an authority away, one at a time, and name the
# case that has to notice.
#
# 🔴 M5 IS THE ONE WORTH READING. It takes `ndt help` away from the TEST. The test's case 1 is
# a NEGATIVE assertion -- help no longer names three ports -- and an empty help text satisfies
# it perfectly, which is the whole trap: an authority that says nothing agrees with every
# document. If case 2 were not standing next to case 1, the tool-side half of that file would be
# a decoration. M5 is how that is shown rather than claimed.
#
# 🔴 M7 IS THE SECOND DIRECTION. The fix that passes a naive "stop calling my processes
# strangers" test is "never say it at all", and that sentence is the only warning before a :8000
# nobody here started. M7 deletes it from a copy of `ndt`; case 4 has to go red.
#
# M17 takes the own-fabric sentence out of a copy of the user guide; case 8 has to go red.
# M18 and C2 show that the sweep's past-wording suppression is the word, not a blanket.
#
# C1 at the end is the opposite: an HTML-comment reword in the guide, which must leave every case
# green. A gate with no surviving control cannot tell "the suite is sensitive" from "stuck red".
#
# 🔴 ONE MUTATION, ONE ANCHOR. Two mutations sharing an anchor string make
# check_gate_anchors.py's ok(N) count anchor CELLS rather than mutations, and the difference is
# printed nowhere (FIXED-ISSUES G-56). Every anchor below is distinct.
#
# 🔴 NOTHING IN THE WORKTREE IS WRITTEN. The guide, `ndt`, the test and KNOWN-ISSUES are copied
# into a temp dir and the copies are mutated; the test takes MANUAL= (the guide), NDT= and DOCS=,
# and is itself run from a copy for M5, so this gate is safe to run while another session is
# editing this shared tree. Byte identity of the originals is asserted at the end anyway.
#
# Nothing is built, no lab is touched: the test reads markdown files, reads `ndt`, runs `ndt
# help` (which prints text and exits 2) and asks git about ancestry.
#
# Exit: 0  every mutation caught by the case it names, the control survived, originals intact
#       1  a mutation SURVIVED, or the control went red, or an original changed
#       2  the baseline was already red, or a mutation could not be applied
#
# Usage:  bash tests/shell/mutate_manual_no_stale_in_progress.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MANUAL="$REPO/doc/2026-11-05_user-guide.md"
TEST="$REPO/tests/shell/test_manual_no_stale_in_progress.sh"
NDT="$REPO/tools/test_workflow/ndt"
KI="$REPO/doc/KNOWN-ISSUES.md"
PY="${PY:-/usr/bin/python3}"

BK=$(mktemp -d /tmp/manual-stale-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
MANUAL_SHA=$(sha256sum "$MANUAL" | cut -d' ' -f1)
TEST_SHA=$(sha256sum "$TEST" | cut -d' ' -f1)
NDT_SHA=$(sha256sum "$NDT" | cut -d' ' -f1)
KI_SHA=$(sha256sum "$KI" | cut -d' ' -f1)

# The tree cases 11/11b/11c read their pages out of. Built once, never written to: every doc
# mutation below copies this and edits the copy, so the sweep can be pointed at a mutant without
# anything under $REPO/doc changing. doc/audit/ is not copied -- the sweep does not read it.
PGS="$BK/pages.pristine"
for f in $(git -C "$REPO" ls-files -- 'doc/*.md' 'doc/**/*.md' | grep -v '^doc/audit/'); do
    mkdir -p "$PGS/$(dirname "$f")"
    cp "$REPO/$f" "$PGS/$f"
done

MUTATIONS=0
SURVIVORS=0
UNAPPLIED=0
CONTROLS=0
CONTROLS_RED=0

apply_exact() {   # apply_exact <file to edit in place> <anchor \x1f replacement>
    "$PY" - "$1" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p, encoding="utf-8").read()
n = s.count(old)
assert n == 1, "anchor is not unique (%d matches): %r" % (n, old[:70])
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
}

# A mutated copy of the manual; prints its path, or an empty string if the anchor missed.
manual_mutant() {   # manual_mutant <tag> <anchor \x1f replacement>
    local out="$BK/manual.$1.md"; cp "$MANUAL" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$out"
}

# An UNMUTATED copy of the manual, for the mutations applied to the test or to `ndt` instead.
# It is a copy and not "$MANUAL" itself because check_gate_anchors.py reads a declared repo path
# followed by a quoted literal as "anchor in that file", and the case name passed alongside it
# would be reported as a missing anchor in the manual.
manual_copy() {
    local out="$BK/manual.pristine.md"; cp "$MANUAL" "$out"; echo "$out"
}

# A mutated copy of the test itself, run against a pristine copy of the manual.
test_mutant() {   # test_mutant <tag> <anchor \x1f replacement>
    local out="$BK/test.$1.sh"; cp "$TEST" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$out"
}

# A mutated copy of `ndt` that still RUNS. `ndt` sources ports.sh and sudo_surface.sh out of its
# own directory, so a bare copy in a temp dir dies on line 64 and prints nothing at all -- and a
# mutant that breaks the whole tool turns every help assertion red at once, which says nothing
# about the one sentence it removed. The copy therefore sits in a MIRROR of tools/test_workflow/
# whose other entries are symlinks to the originals, so the only difference between this `ndt`
# and the repo's is the anchor below. (Measured 2026-09-12: `ndt help` out of the mirror is
# byte-identical to the repo's except its trailing `repo:` line, which nothing here reads.)
ndt_mutant() {   # ndt_mutant <tag> <anchor \x1f replacement>
    local dir="$BK/$1/tools/test_workflow" out f
    mkdir -p "$dir"
    for f in "$(dirname "$NDT")"/*; do ln -sfn "$f" "$dir/$(basename "$f")"; done
    out="$dir/ndt"; rm -f "$out"; cp "$NDT" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$out"
}

# An UNMUTATED mirror of `ndt`, for every mutation that is applied to the manual or to the test.
# Same reason as manual_copy: with "$NDT" -- a declared repo path -- passed to report(), the case
# name right after it is read as an anchor inside `ndt`, and the cell scores 0 (want 1). Every
# entry here is a symlink, `ndt` included, so the tool under test is byte-for-byte the repo's.
ndt_copy() {
    local dir="$BK/pristine/tools/test_workflow" f
    mkdir -p "$dir"
    for f in "$(dirname "$NDT")"/*; do ln -sfn "$f" "$dir/$(basename "$f")"; done
    echo "$dir/ndt"
}

# A copy of the page tree with doc/KNOWN-ISSUES.md mutated. Same shape as manual_mutant: the
# body names "$KI" so check_gate_anchors.py counts these anchors in KNOWN-ISSUES.md.
ki_mutant() {   # ki_mutant <tag> <anchor \x1f replacement>
    local dir="$BK/pages.$1" out
    rm -rf "$dir"; cp -r "$PGS" "$dir"
    out="$dir/doc/KNOWN-ISSUES.md"; cp "$KI" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$dir"
}

run_quad() {   # run_quad <test file> <manual file> <ndt file> <page tree>
    # REPO_UNDER_TEST pins the tree git is asked about: the M5 mutant runs from $BK, and without
    # this its case 0 would go red because /tmp is not a repository, muddying the one case M5 is
    # about.
    MANUAL="$2" NDT="$3" DOCS="$4" REPO_UNDER_TEST="$REPO" bash "$1" 2>&1
}
run_triple() {   # run_triple <test file> <manual file> <ndt file> -- pristine pages
    run_quad "$1" "$2" "$3" "$PGS"
}

report() {   # report <label> <test file> <manual file> <ndt file> <case that must go red>
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
        printf '  DID-NOT-APPLY %-54s (anchor missed; nothing was tested)\n' "$1"
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    out=$(run_triple "$2" "$3" "$4"); rc=$?
    if ! grep -qE '^  (ok|FAILED) ' <<<"$out"; then
        printf '  TEST-DID-NOT-RUN %-51s (mutant broke the file; harness error)\n' "$1"
        sed -n '1,4p' <<<"$out" | sed 's/^/                /'
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $5" <<<"$out"; then
        printf '  caught        %-54s (%s went red)\n' "$1" "$5"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED      %-54s (%s stayed green -- that case proves nothing)\n' "$1" "$5"
        grep -E '^  (ok|FAILED) ' <<<"$out" | sed 's/^/                /'
    fi
}

# A mutation applied to `ndt` has to be shown to be SURGICAL: a mutant that cannot run turns the
# whole tool-side half red and would "catch" everything. This reporter names one case that has to
# go red and one witness that has to stay green.
report_isolated() {   # report_isolated <label> <test> <manual> <ndt> <case that goes red> <witness that stays green>
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
        printf '  DID-NOT-APPLY %-54s (anchor missed; nothing was tested)\n' "$1"
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    out=$(run_triple "$2" "$3" "$4"); rc=$?
    if ! grep -qE '^  (ok|FAILED) ' <<<"$out"; then
        printf '  TEST-DID-NOT-RUN %-51s (mutant broke the file; harness error)\n' "$1"
        sed -n '1,4p' <<<"$out" | sed 's/^/                /'
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $5" <<<"$out" && grep -q "ok       $6" <<<"$out"; then
        printf '  caught        %-54s (%s went red; the witness stayed green)\n' "$1" "$5"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED      %-54s (the named case stayed green, or the mutant was not surgical)\n' "$1"
        grep -E '^  (ok|FAILED) ' <<<"$out" | sed 's/^/                /'
    fi
}

# Same judgement as report(), for a mutation applied to the PAGE TREE the doc-wide sweep reads.
# The manual, `ndt` and the test are all pristine copies, so the only thing that changed is one
# sentence in one page -- which is what cases 11/11b/11c are about.
report_pages() {   # report_pages <label> <test> <manual> <ndt> <page tree> <case that must go red>
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ -z "$2" || -z "$3" || -z "$4" || -z "$5" ]]; then
        printf '  DID-NOT-APPLY %-54s (anchor missed; nothing was tested)\n' "$1"
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    out=$(run_quad "$2" "$3" "$4" "$5"); rc=$?
    if ! grep -qE '^  (ok|FAILED) ' <<<"$out"; then
        printf '  TEST-DID-NOT-RUN %-51s (mutant broke the file; harness error)\n' "$1"
        sed -n '1,4p' <<<"$out" | sed 's/^/                /'
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $6" <<<"$out"; then
        printf '  caught        %-54s (%s went red)\n' "$1" "$6"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED      %-54s (%s stayed green -- that case proves nothing)\n' "$1" "$6"
        grep -E '^  (ok|FAILED) ' <<<"$out" | sed 's/^/                /'
    fi
}

control() {   # control <label> <test file> <manual file> <ndt file> [page tree]
    local out rc
    CONTROLS=$((CONTROLS + 1))
    out=$(run_quad "$2" "$3" "$4" "${5:-$PGS}"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED      %-54s (control, as required)\n' "$1"
    else
        CONTROLS_RED=$((CONTROLS_RED + 1))
        printf '  🔴 CONTROL WENT RED %-47s\n' "$1" >&2
        grep -E '^  FAILED ' <<<"$out" | sed 's/^/                /' >&2
    fi
}

echo "baseline (unmutated) must be green:"
if run_triple "$TEST" "$MANUAL" "$NDT" | tail -1 | grep -q ' 0 failed'; then
    echo "  ok            baseline green"
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run_triple "$TEST" "$MANUAL" "$NDT" | sed 's/^/    /'
    exit 2
fi
echo
echo "mutations:"

# Short name on purpose. check_gate_anchors.py reads "a declared path followed by a quoted word"
# as "that word is an anchor in that file", and a longer variable name here is read as an anchor
# it cannot resolve -- the gate then scores UNPARSED, which is NOT a pass.
P=$(manual_copy)
D=$(ndt_copy)

# --- M5: the TEST loses its authority ------------------------------------------------------------
# 🔴 The direction that matters. Case 1 is a negative assertion about `ndt help`; with no help
# text at all it is green, and only case 2 stands between this file and a certificate that means
# nothing.
T=$(test_mutant m5 'HELP="$(bash "$NDT" help 2>&1)"'$'\x1f''HELP=""')
report "M5: the test stops reading 'ndt help'" "$T" "$P" "$D" "case 2  'ndt help' prints --deep's size out of ports.sh's table"

# --- M7: the tool is 'fixed' by never warning about a stranger again --------------------------------
N=$(ndt_mutant m7 'err "   this stack did not start it; to kill it too:  ndt down --deep"'$'\x1f''err "   nothing on this machine is worth mentioning"')
report_isolated "M7: 'ndt' stops warning about a stranger at all" "$TEST" "$P" "$N" \
                "case 4  'ndt' still has the stranger sentence (the fix was not 'never say it')" \
                "case 2  'ndt help' prints --deep's size out of ports.sh's table"

# --- M17: the user guide stops quoting the own-fabric sentence ------------------------------------
M=$(manual_mutant m17 'registered under `the fabric this stack started is still up`;'$'\x1f''registered under a heading of their own;')
report "M17: the guide drops clean's own-fabric sentence" "$TEST" "$M" "$D" "case 8  the user guide quotes clean's own-fabric sentence"

# --- M10-M15: the doc-wide sweep (cases 11 / 11b / 11c) ------------------------------------------------
# 🔴 THESE SIX ARE ABOUT ONE BARGAIN. Cases 11/11b let a block off when it retracts IN PLACE --
# names a merge commit that is an ancestor of HEAD, next to the words for "fixed" or "merged". That escape is the only
# thing standing between the sweep and false positives on pages that retract a stale caveat, so
# every clause of it is taken away once: the word (M10, M11), the sha's merge-ness (M12), the
# sha's existence (M13), and the block that carries it (M14). M15 is the sweep's own silence.
#
# 🔴 THE FIXTURES ARE SYNTHETIC SINCE THE KNOWN-ISSUES REWRITE. These mutations used to be anchored
# on four real retraction notes in the old KNOWN-ISSUES.md. That file now lists only open defects
# and holds no such note, but the sweep and its escape clause are unchanged, so each mutation now
# writes its own retraction block into the page tree's copy of that file (a paragraph of its own,
# before a heading that exists) and takes one clause of it away. C3 and C4 are the same blocks
# with every clause in place: the sweep must stay green on them, or the mutations below would
# only prove that any block at all turns case 11 red. The shas are looked up in this repository
# when the gate runs, so no commit id is typed here.
FIX6_MERGE=$(git -C "$REPO" log --merges --format='%H %s' HEAD | grep -F -- ' Merge fix/ndt-6-' | head -1 | cut -d' ' -f1)
W8_BRANCH='fix/w8-declared-link-failure-sticky'
W8_MERGE=$(git -C "$REPO" log --merges --format='%H %s' HEAD | grep -F -- " Merge $W8_BRANCH:" | head -1 | cut -d' ' -f1)
NONMERGE=$(git -C "$REPO" rev-list --no-merges -1 HEAD)
# The sweep (case 11/11b) looks for these four Chinese words; they are written as UTF-8 bytes here
# so that the fixtures below stay readable in English.
W_INPROG=$'\xe5\x9c\xa8\xe4\xbf\xae'          # "being worked on"
W_FIXED=$'\xe5\xb7\xb2\xe4\xbf\xae'           # "fixed"
W_MERGED=$'\xe5\xb7\xb2\xe4\xbd\xb5'          # "merged"
W_UNMERGED=$'\xe6\x9c\xaa\xe4\xbd\xb5\xe5\x85\xa5'  # "not merged in"
W_WAS=$'\xe5\x8e\x9f\xe6\x9c\xac'              # "originally": marks a block as past wording
if [[ -z "$FIX6_MERGE" || -z "$W8_MERGE" || -z "$NONMERGE" ]]; then
    echo "  REFUSE: this checkout has no merge for the fixtures (ticket '$FIX6_MERGE', branch '$W8_MERGE')"
    exit 2
fi

# --- C3 / C4 (controls): the same blocks with every clause of the escape in place ----------------------
# They run first so a red here says the fixtures are wrong before any mutation is blamed.
G=$(ki_mutant c3 '### F-9 '$'\x1f'"This block says FIX-NDT-6 ${W_INPROG} (sweep fixture), ${W_FIXED}, merge \`${FIX6_MERGE}\`."$'\n\n''### F-9 ')
control "C3 (control): a ticket caveat that names its merge in place" "$TEST" "$P" "$D" "$G"
G=$(ki_mutant c4 '### F-17 '$'\x1f'"\`${W8_BRANCH}\` ${W_UNMERGED} trunk (sweep fixture),"$'\n'"${W_MERGED}, merge \`${W8_MERGE}\`."$'\n\n''### F-17 ')
control "C4 (control): a branch caveat whose merge sits on the next line" "$TEST" "$P" "$D" "$G"

# --- M10: a block says a merge landed and then does not say so ----------------------------------------
G=$(ki_mutant m10 '### G-62 '$'\x1f'"This block says FIX-NDT-6 ${W_INPROG} (sweep fixture), merge \`${FIX6_MERGE}\`."$'\n\n''### G-62 ')
report_pages "M10: a doc block drops the word that says the ticket landed" "$TEST" "$P" "$D" "$G" \
             "case 11  no doc page calls a ticket unfixed without naming the merge that landed it"

# --- M11: the same, on the branch half ---------------------------------------------------------------------
G=$(ki_mutant m11 '### G-59 '$'\x1f'"\`${W8_BRANCH}\` ${W_UNMERGED} trunk (sweep fixture), merge \`${W8_MERGE}\`."$'\n\n''### G-59 ')
report_pages "M11: a doc block drops the word that says the branch landed" "$TEST" "$P" "$D" "$G" \
             "case 11b no doc page calls a branch unmerged without naming the merge that landed it"

# --- M12: the disclosed sha is real, reachable -- and is not a landing ----------------------------------
# 🔴 A commit on the branch is not the branch arriving. If a single-parent commit counted, "fixed
# in <sha>" could name the very commit that is still only on the branch and the sweep would agree
# with it. The replacement sha has to be BOTH reachable and not a merge, or this mutation proves
# nothing: NONMERGE above is the newest non-merge commit of HEAD, so it has one parent and is an
# ancestor of HEAD by construction.
G=$(ki_mutant m12 '### G-39 '$'\x1f'"This block says FIX-NDT-6 ${W_INPROG} (sweep fixture), ${W_FIXED}, merge \`${NONMERGE}\`."$'\n\n''### G-39 ')
report_pages "M12: the disclosed sha is an ancestor but not a merge" "$TEST" "$P" "$D" "$G" \
             "case 11  no doc page calls a ticket unfixed without naming the merge that landed it"

# --- M13: the disclosed sha does not resolve at all -------------------------------------------------------
G=$(ki_mutant m13 '### G-36 '$'\x1f'"This block says FIX-NDT-6 ${W_INPROG} (sweep fixture), ${W_FIXED}, merge \`0123456789ab\`."$'\n\n''### G-36 ')
report_pages "M13: the disclosed sha is not in this repository" "$TEST" "$P" "$D" "$G" \
             "case 11  no doc page calls a ticket unfixed without naming the merge that landed it"

# --- M14: the sweep reads a line where it should read a block -----------------------------------------------
# 🔴 THE ONE THAT IS EASY TO GET WRONG. Prose wraps: a note can say it is not merged on one line and name
# the merge on the next. A line-scoped reader sees the first half of a sentence and calls a
# retraction a stale caveat -- which is how a sweep teaches people to switch it off. The page
# tree is C4's block (branch caveat on one line, retraction on the next), and the mutation is the
# test's block reader becoming a line reader.
T=$(test_mutant m14 'for (i = s; i <= e; i++) print a[i]'$'\x1f''print a[L]')
G=$(ki_mutant m14p '### B-9 '$'\x1f'"\`${W8_BRANCH}\` ${W_UNMERGED} trunk (sweep fixture),"$'\n'"${W_MERGED}, merge \`${W8_MERGE}\`."$'\n\n''### B-9 ')
report_pages "M14: the sweep reads one line instead of the block" "$T" "$P" "$D" "$G" \
             "case 11b no doc page calls a branch unmerged without naming the merge that landed it"

# --- M15: the sweep stops having anything to sweep -------------------------------------------------------
# Cases 11/11b count violations, so no pages is indistinguishable from no violations. This is the
# failure 11c exists for, and it is the failure a doc-wide sweep drifts into on its own -- a moved
# directory, a renamed pathspec -- without anybody editing a document.
T=$(test_mutant m15 'mapfile -t PAGES < <(git -C "$REPO" ls-files'$'\x1f''mapfile -t PAGES < <(true "$REPO" ls-files')
report_pages "M15: the sweep's page list comes back empty" "$T" "$P" "$D" "$PGS" \
             "case 11c the sweep has a page list, all of it readable, with the user guide and KNOWN-ISSUES in it"

# --- M16: the failure line goes back to printing empty parentheses --------------------------------------
# 🔴 NOT A HYPOTHETICAL MUTATION -- IT IS THE FIRST RUN OF THIS SWEEP. `merge_branch`'s sed wanted
# a space before `Merge`, and a merge subject starts at column 1, so every violation line read
# `… 4e969110… () is reachable from HEAD`. The one thing that tells a reader the prefix lookup
# matched a DIFFERENT ticket was blank, on the only two lines that would ever have shown it, and
# the run still looked like a correct finding because those lines were red for their own reason.
# The decision to leave the lookup alone is exactly as good as this cell.
T=$(test_mutant m16 '^.*Merge \(fix\/[^: ]*\)'$'\x1f''.* Merge \(fix\/[^: ]*\)')
report_pages "M16: the failure line stops naming the branch it matched" "$T" "$P" "$D" "$PGS" \
             "case 11d a violation line names the branch the lookup matched, not just the sha"

# --- M18 / C2: the past-wording suppression is the word, not a blanket ----------------------------------
# [Co-developed with claude code -- Adam]
# A block carrying one of the two past-wording words is skipped as a record of what a page used to say. The page list
# comes from git, so the fixture is a synthetic paragraph inside the page tree's KNOWN-ISSUES copy,
# placed before a heading so it is a block of its own: it names a merged fix as being worked on and no merge.
# C2 keeps the word and must stay green; M18 is the same sentence without it, and case 11 must see it.
G=$(ki_mutant m18 '### G-33 '$'\x1f'"This block says FIX-NDT-6 ${W_INPROG} (sweep fixture)."$'\n\n''### G-33 ')
report_pages "M18: a stale block without the past-wording word" "$TEST" "$P" "$D" "$G" \
             "case 11  no doc page calls a ticket unfixed without naming the merge that landed it"
echo
G=$(ki_mutant c2 '### A-13 '$'\x1f'"${W_WAS} this block said FIX-NDT-6 ${W_INPROG} (sweep fixture)."$'\n\n''### A-13 ')
if [[ -z "$G" ]]; then
    echo "  DID-NOT-APPLY C2 (control): the heading it writes before is not there" >&2
    UNAPPLIED=$((UNAPPLIED + 1))
else
    control "C2 (control): the same block, marked as past wording" "$TEST" "$P" "$D" "$G"
fi

# --- M19-M24 / C5: the English half of the sweep (cases 11e / 11g) --------------------------------------
# [Co-developed with claude code -- Adam]
# The Chinese word lists cannot see "fixed on a branch, not on trunk" written in English, which is
# how FIXED-ISSUES G-52 happened. Case 11g runs the English sweep over a fixture tree (four stale
# phrasings on one page, two phrasings split across lines on another, ordinary sentences on a
# third); M19 takes a phrase out of the pattern, M20 makes the sweep read nothing, M21 adds an
# alternative that matches every character, M23 drops case-insensitivity and M24 makes one phrase
# need single spaces, so its wrapped form is missed: all five must turn that case red. M22 is the document side: a stale English
# sentence in a page of the tree must turn case 11e red. C5 is the same fact reworded the way the
# repository's own G-52 row describes it, and must stay green.
T11G="case 11g the English sweep finds four phrasings, two split across lines, and nothing on an ordinary page"
T=$(test_mutant m19 "not[\\s>]+on[\\s>]+.?trunk.?|has"$'\x1f'"this-phrase-matches-nothing|has")
report "M19: the English pattern loses its second phrase" "$T" "$P" "$D" "$T11G"
T=$(test_mutant m20 'grep -z -o -i -P "$ENGLISH_STALE" "$tree/$pg" | sed -z '"'"'s/[[:space:]>]\+/ /g'"'"' | tr '"'"'\0'"'"' '"'"'\n'"'"' | sed "s|^|$pg: |"'$'\x1f''true "$tree/$pg"')
report "M20: the English sweep reads no page" "$T" "$P" "$D" "$T11G"
T=$(test_mutant m21 "+merged|not[\\s>]+yet[\\s>]+merged'"$'\x1f'"+merged|.'")
report "M21: the English pattern gains an alternative that matches everything" "$T" "$P" "$D" "$T11G"
T=$(test_mutant m23 'grep -z -o -i -P "$ENGLISH_STALE"'$'\x1f''grep -z -o -P "$ENGLISH_STALE"')
report "M23: the English sweep becomes case-sensitive" "$T" "$P" "$D" "$T11G"
T=$(test_mutant m24 "ENGLISH_STALE='on[\\s>]+a[\\s>]+branch|"$'\x1f'"ENGLISH_STALE='on a branch|")
report "M24: a phrase split across two lines is no longer found" "$T" "$P" "$D" "$T11G"
G=$(ki_mutant m22 '### B-17 '$'\x1f'"This fix is still only on a branch (sweep fixture)."$'\n\n''### B-17 ')
report_pages "M22: a doc page says a fix is only on a branch" "$TEST" "$P" "$D" "$G" \
             "case 11e no doc page says a fix is on a branch, not on trunk, or not yet merged"
echo
G=$(ki_mutant c5 '### B-21 '$'\x1f'"This fix was described as unmerged after it had merged (sweep fixture)."$'\n\n''### B-21 ')
if [[ -z "$G" ]]; then
    echo "  DID-NOT-APPLY C5 (control): the heading it writes before is not there" >&2
    UNAPPLIED=$((UNAPPLIED + 1))
else
    control "C5 (control): the same fact, described instead of quoted" "$TEST" "$P" "$D" "$G"
fi

# --- C1 (control): an HTML comment in the guide is reworded; nothing about the contract changes ------
echo
M=$(manual_mutant c1 'Keep exactly one table of these codes in this guide.'$'\x1f''Keep only one table of these codes in this guide.')
if [[ -z "$M" ]]; then
    echo "  DID-NOT-APPLY C1 (control): the comment it rewords is not there" >&2
    UNAPPLIED=$((UNAPPLIED + 1))
else
    control "C1 (control): an HTML comment in the guide is reworded" "$TEST" "$M" "$D"
fi

echo
ok=0
if [[ "$(sha256sum "$MANUAL" | cut -d' ' -f1)" == "$MANUAL_SHA" ]]; then
    echo "baseline byte-identical: yes  doc/2026-11-05_user-guide.md"
else
    echo "🔴 THE USER GUIDE CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
if [[ "$(sha256sum "$TEST" | cut -d' ' -f1)" == "$TEST_SHA" ]]; then
    echo "baseline byte-identical: yes  tests/shell/test_manual_no_stale_in_progress.sh"
else
    echo "🔴 THE TEST CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
if [[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$NDT_SHA" ]]; then
    echo "baseline byte-identical: yes  tools/test_workflow/ndt"
else
    echo "🔴 ndt CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
if [[ "$(sha256sum "$KI" | cut -d' ' -f1)" == "$KI_SHA" ]]; then
    echo "baseline byte-identical: yes  doc/KNOWN-ISSUES.md"
else
    echo "🔴 KNOWN-ISSUES CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS unapplied=$UNAPPLIED controls=$CONTROLS red=$CONTROLS_RED"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROLS control(s), $CONTROLS_RED went red"
[[ "$SURVIVORS" -eq 0 && "$UNAPPLIED" -eq 0 && "$CONTROLS_RED" -eq 0 && "$ok" -eq 0 ]]
