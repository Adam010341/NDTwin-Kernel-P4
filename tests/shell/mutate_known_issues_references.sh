#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_known_issues_references.py (R3-KIREF, DECISIONS 09-07 21:0x #3).
#
# [Co-developed with claude code -- Adam]
#
# What is being protected. Citations of doc/KNOWN-ISSUES.md must name an entry CODE, and a
# citation that also carries a line number has to land inside that entry. On 1a284f75 all 62
# line-number citations in the repo were stale -- four of them were already wrong on the day
# they were written -- because the document is appended to and inserted into constantly and
# every insertion shifts every line below it.
#
# Two things can go wrong with a scanner like this, and only one of them is loud:
#
#   * it stops seeing violations   -- the gate reads clean and the citations rot anyway;
#   * it starts inventing them     -- and then the only way to keep the tree green is to delete
#                                     line numbers that were correct, which is not what was
#                                     ruled. M4 is the mutation for that direction, and the
#                                     only case that catches it is the control case
#                                     `test_a_correct_reference_is_not_a_violation`.
#
# So every mutation below is a KILL: it must turn its NAMED case red. C1 at the end is the
# opposite -- a comment-only edit, which must leave every case green. A gate with no surviving
# control cannot tell "the suite is sensitive" from "the suite is stuck red".
#
# M13-M14 are the bare-code half (2026-09-11, E1): `<the document> <CODE>` with no line number
# is the form the ruling asks for, and until that night nothing checked that the code existed.
#
# M1 is applied to the DATA, not the scanner: a copy of the tree gets its stale citation back
# (`FINDINGS.md` cited a line that is inside B-12 while talking about the `commit=UNKNOWN` gap
# in the bmv2 provenance) and the repository case has to notice. M2-M9 are applied to the
# scanner. The two are different failures and this gate is the only place that separates them.
#
# 🔴 Guards its own baseline. Every mutation is applied to a COPY of the test file in a temp
# dir, and the tree M1 mutates is a COPY made with `git ls-files | tar`. Neither
# tests/python/test_known_issues_references.py nor any file in the worktree is ever written --
# this worktree is shared and another session may be reading it right now. Byte identity of the
# test file is asserted at the end regardless.
#
# 🔴 The gate contains no literal citation of its own. tests/ is inside the tree the scanner
# reads, so a literal here would be a finding this gate produces about itself; the two it needs
# are built from "$KI" at the point of use.
#
# Nothing is built, nothing is killed, no lab is touched, nothing leaves the machine: the thing
# under test reads files and counts lines.
#
# Exit: 0  every mutation caught by the case it names, the control survived, baseline intact
#       1  a mutation SURVIVED, or the control went red
#       2  the baseline was already red, or a mutation could not be applied
#       3  the file under test changed while the gate ran
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TEST="$REPO/tests/python/test_known_issues_references.py"
PY="${PY:-/usr/bin/python3}"
KI="KNOWN-ISSUES.md"
export PYTHONDONTWRITEBYTECODE=1

BK=$(mktemp -d /tmp/kiref-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "$TEST" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
CONTROLS=0
CONTROLS_RED=0

run_against() {   # $1 = test file to run, $2 = tree it scans
    KIREF_REPO_UNDER_TEST="$2" "$PY" "$1" -v 2>&1
}

report() {   # $1 = label, $2 = mutated test file, $3 = tree, $4 = case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2" "$3"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "^FAIL: $4 " <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$1" "$4"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-56s (%s stayed green -- that case proves nothing)\n' "$1" "$4"
        grep -E '^(FAIL|ERROR): |^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /'
    fi
}

control() {   # $1 = label, $2 = mutated test file, $3 = tree
    local out rc
    CONTROLS=$((CONTROLS + 1))
    out=$(run_against "$2" "$3"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED %-56s (control, as required)\n' "$1"
    else
        CONTROLS_RED=$((CONTROLS_RED + 1))
        printf '  🔴 CONTROL WENT RED %-45s\n' "$1" >&2
        grep -E '^(FAIL|ERROR): ' <<<"$out" | sed 's/^/             /' >&2
    fi
}

apply_exact() {   # $1 = file to edit in place, $2 = anchor \x1f replacement
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

mutant() {   # $1 = name, $2 = anchor \x1f replacement; prints the mutated copy of the test
    local out="$BK/test.$1.py"; cp "$TEST" "$out"
    apply_exact "$out" "$2" || { echo "$BK/UNAPPLIED"; return; }
    echo "$out"
}

# A copy of the tree the scanner walks, taken from the WORKING TREE (not from a rev): the point
# of M1 is what this branch's files say now. Tracked paths only, so build trees, scratch and the
# p4_proxy/venv symlink into the other checkout cannot come along.
snapshot_tree() {   # $1 = destination
    mkdir -p "$1"
    (cd "$REPO" && git ls-files -z --cached -- doc tests tools src include p4_proxy '*.md' \
        | tar --null -T - -cf -) | tar -xf - -C "$1"
}

echo "baseline (must be green before any mutation):"
run_against "$TEST" "$REPO" | tail -1
if ! run_against "$TEST" "$REPO" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    run_against "$TEST" "$REPO" | grep -E '^(FAIL|ERROR): ' | sed 's/^/    /'
    exit 2
fi
echo

# --- M1: the DATA. One citation goes back to the stale form it had on 1a284f75 -------------
# `doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md` cited a line number that has pointed
# into B-12 since B-12 was inserted, while the sentence around it is about the kernel binary's
# `commit=UNKNOWN` gap. Putting it back is the whole defect in one line.
T1="$BK/tree.m1"
snapshot_tree "$T1"
# `git ls-files --cached` copies what the INDEX knows about. A file that exists only in the
# working tree is absent from the copy, and the repository case would then be scanning a tree
# that is missing the very files this gate is about -- green for a reason nobody asked for.
if [[ ! -f "$T1/tests/python/test_known_issues_references.py" ]]; then
    echo "🔴 the tree copy is missing the file under test -- commit or 'git add -N' first" >&2
    exit 2
fi
STALE="doc/$KI:1679"
if ! apply_exact "$T1/doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md" \
        'KNOWN-ISSUES〈生產線在跑的那顆 kernel 的重建配方〉'$'\x1f'"\`$STALE\`"; then
    echo "  🔴 M1 could not be applied -- the citation it puts back is not where it was" >&2
    SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1))
else
    report "M1: a stale line-number citation comes back (data)" "$TEST" "$T1" \
           "test_every_line_number_citation_names_the_entry_it_lands_in"
fi

# --- M2-M9: the SCANNER --------------------------------------------------------------------

m=$(mutant m2 '    ".md", ".py", ".sh", ".cpp", ".hpp", ".cc", ".c", ".h", ".txt", ".tsv", ".csv",'$'\x1f''    ".md", ".py", ".sh", ".hpp", ".cc", ".c", ".h", ".txt", ".tsv", ".csv",')
report "M2: .cpp is not scanned" "$m" "$REPO" "test_a_cpp_comment_is_scanned"

m=$(mutant m3 '    out = []
    lines = text.splitlines()'$'\x1f''    return []
    out = []
    lines = text.splitlines()')
report "M3: violations are found and never reported (rc 0)" "$m" "$REPO" \
       "test_a_line_in_another_entry_is_reported"

m=$(mutant m4 '                if not any(s <= want <= e for s, e in spans[code]):'$'\x1f''                if True:')
report "M4 (widening): a correct citation is reported too" "$m" "$REPO" \
       "test_a_correct_reference_is_not_a_violation"

# 2026-09-11: the same mutation, repointed. B12 split the one-line CITATION_RE into _KI_DOC plus
# a separator alternation, so this anchor moved -- the mutation is unchanged: `.md` becomes
# mandatory and the 20 sites that write it without the suffix go unread.
m=$(mutant m5 '_KI_DOC = r"KNOWN[-_]ISSUES(?:\.md)?"'$'\x1f''_KI_DOC = r"KNOWN[-_]ISSUES\.md"')
report "M5: the .md-less spelling is a bypass again" "$m" "$REPO" \
       "test_the_md_less_spelling_is_read_too"

m=$(mutant m6 'VERBATIM_SUFFIXES = frozenset((".log", ".diff", ".patch"))'$'\x1f''VERBATIM_SUFFIXES = frozenset()')
report "M6: verbatim records are corrected like source" "$m" "$REPO" \
       "test_a_log_is_a_verbatim_record_and_is_not_read"

m=$(mutant m7 '        code = row_code(line)
        if code:'$'\x1f''        code = row_code(line)
        if False:')
report "M7: a table row stops being an entry" "$m" "$REPO" "test_a_table_row_is_an_entry_too"

m=$(mutant m8 '    for top in SCAN_DIRS:'$'\x1f''    for top in ():')
report "M8: the walk visits nothing and the scan is green" "$m" "$REPO" \
       "test_the_scan_actually_read_the_repository"

m=$(mutant m9 '    start, end = paragraph_bounds(lines, idx)'$'\x1f''    start, end = 0, len(lines) - 1')
report "M9: a code anywhere in the file counts as claimed" "$m" "$REPO" \
       "test_a_code_in_a_different_paragraph_does_not_count"

# --- M10-M12: the SPELLING of the citation (B12, 2026-09-11) -------------------------------
# hunt-0911/F-B0-B12-REPORT.md §3.1 rows (5)b..(5)e put four re-spellings of one citation through
# the old regex and got `violations=0` out of every one. Two of these put a spelling test back;
# the third is the widening direction, which costs the same as a miss here -- a scanner that
# reads a ROW label as a line number reports a citation that is correct, and the only way to get
# the tree green again is to delete something true.

# 2026-09-11: repointed, mutation unchanged. The fast path moved into mentions_the_document()
# when the bare-code half needed the same filter -- two scanners spelling one filter separately
# is two filters. It now covers both halves.
m=$(mutant m10 '    return "KNOWN" in text'$'\x1f''    return "KNOWN-ISSUES" in text')
report "M10: the fast path tests for one spelling of the name" "$m" "$REPO" \
       "test_a_citation_with_no_code_is_reported_in_every_spelling_too"

m=$(mutant m11 'CITATION_RE = re.compile(_KI_DOC + r"(?:" + _KI_LINE_SEP + r")(\d+)"'$'\x1f''CITATION_RE = re.compile(_KI_DOC + r"(?:" + r" ?: ?" + r")(\d+)"')
report "M11: one colon, one space each side, and nothing else" "$m" "$REPO" \
       "test_each_spelling_of_a_wrong_line_is_reported"

m=$(mutant m12 '    r"|[ \t]*第?[ \t]*(?=\d+(?:[ \t]*(?:" + _KI_JOIN + r")[ \t]*\d+)*[ \t]*行)"'$'\x1f''    r"|[ \t]*[第行][ \t]*"')
report "M12 (widening): a 行 row label is read as a line number" "$m" "$REPO" \
       "test_a_row_label_is_not_a_line_number"

# --- M13-M14: the BARE-CODE half (E1, 2026-09-11) ------------------------------------------
# hunt-0911/F-OFFLINE-1-REPORT.md §1.1 ran this scanner's own parser over four codes the repo
# cites as `<the document> <CODE>` -- T-11, L-3, L-5, I-3 -- and got None out of every one while
# all 30 cases were green. M13 is the miss direction. M14 is the widening one and costs more:
# a code anywhere on the line would make another document's code this document's, so a correct
# citation would be reported and the only way back to green is to delete something true.

m=$(mutant m13 '            cm = CODE_RE.search(window)'$'\x1f''            cm = None')
report "M13: a bare code is never even found" "$m" "$REPO" \
       "test_a_bare_code_with_no_entry_is_reported"

m=$(mutant m14 '            window = line[m.end():m.end() + BARE_CODE_WINDOW]'$'\x1f''            window = line[m.end():]')
report "M14 (widening): any code on the line is claimed" "$m" "$REPO" \
       "test_a_code_beyond_the_window_is_not_claimed_by_this_document"

# --- C1: the control -----------------------------------------------------------------------
# A comment-only edit. If this goes red the suite is pinned to the shape of its own source and
# every "caught" above is worth less than it looks.
echo
m=$(mutant c1 '#: The document every citation this file reads is a citation OF.'$'\x1f''#: The document every citation this file reads is a citation of (reworded).')
control "C1 (control): a comment is reworded" "$m" "$REPO"

echo
if [[ "$(sha256sum "$TEST" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes  tests/python/test_known_issues_references.py"
else
    echo "🔴 baseline CHANGED -- the file under test was written during the gate"
    exit 3
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS controls=$CONTROLS red=$CONTROLS_RED"
if [[ "$SURVIVORS" -eq 0 && "$CONTROLS_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; $CONTROLS control(s), 0 went red"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROLS control(s), $CONTROLS_RED went red"
exit 1
