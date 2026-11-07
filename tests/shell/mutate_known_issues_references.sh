#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_known_issues_references.py.
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
#                                     decided. M4 is the mutation for that direction, and the
#                                     only case that catches it is the control case
#                                     `test_a_correct_reference_is_not_a_violation`.
#
# So every mutation below is a KILL: it must turn its NAMED case red. C1 at the end is the
# opposite -- a comment-only edit, which must leave every case green. A gate with no surviving
# control cannot tell "the suite is sensitive" from "the suite is stuck red".
#
# M13-M14 are the bare-code half (2026-09-11, E1): `<the document> <CODE>` with no line number
# is the preferred citation form, and until that night nothing checked that the code existed.
#
# M20-M27 close the gaps in M15-M19: a missing second document must be an
# error (M20), the fast path must read a file that names only the second document (M21), a code in
# both documents must fail the repository test (M22, a data mutation in the style of M1), a circled
# digit belongs to its code's citation (M23), and a script with no suffix is read only when it
# starts with a shebang (M24 reads none, M25 reads all), a build directory is never walked (M26) and
# a named pipe is never opened (M27).
#
# M15-M19 are the two-document half: doc/KNOWN-ISSUES.md lists only open defects and
# the codes of the others live in doc/FIXED-ISSUES.md, so a bare-code citation has to name a code
# that the document it names defines. M15 is the open document being cited for a fixed code, M16
# the fixed document not being read at all, M17 a code living in both files, M18-M19 a parser that
# has gone blind on one of the two documents (the floors).
#
# M1 is applied to the DATA, not the scanner: a copy of the tree gets a fixture document whose
# citation by heading is then turned back into a stale line-number citation, and the repository
# case has to notice. M2-M9 are applied to the scanner. The two are different failures and this
# gate is the only place that separates them.
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

# --- M1: the DATA. A citation goes back to the stale line-number form --------------------
# The tree copy gets one fixture document that cites an entry by its heading, which is a
# correct citation. The copy must be green with it; then the heading is replaced by a line
# number that lands nowhere near that entry, which is the whole defect in one line.
# [Co-developed with claude code -- Adam]
T1="$BK/tree.m1"
snapshot_tree "$T1"
# `git ls-files --cached` copies what the INDEX knows about. A file that exists only in the
# working tree is absent from the copy, and the repository case would then be scanning a tree
# that is missing the very files this gate is about -- green for a reason nobody asked for.
if [[ ! -f "$T1/tests/python/test_known_issues_references.py" ]]; then
    echo "🔴 the tree copy is missing the file under test -- commit or 'git add -N' first" >&2
    exit 2
fi
STALE="doc/$KI:1679"   # M1 fixture below: a citation by heading, no line number (accepted); M1 makes it a stale line number
M1_FIX="$T1/doc/m1-citation-fixture.md"
printf '%s\n' '# M1 fixture' '' \
    'The rebuild recipe of the kernel in production is tracked in KNOWN-ISSUES "Rebuild recipe of the kernel that production runs".' \
    > "$M1_FIX"
if ! run_against "$TEST" "$T1" >/dev/null 2>&1; then
    echo "🔴 the tree copy is RED with the M1 fixture before any mutation -- M1 would prove nothing" >&2
    run_against "$TEST" "$T1" | grep -E '^(FAIL|ERROR): ' | sed 's/^/    /' >&2
    exit 2
fi
if ! apply_exact "$M1_FIX" \
        'KNOWN-ISSUES "Rebuild recipe of the kernel that production runs"'$'\x1f'"\`$STALE\`"; then
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

# --- M10-M12: the SPELLING of the citation (2026-09-11) ------------------------------------
# A check on 2026-09-11 put four re-spellings of one citation through
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
report "M12 (widening): a row label with the Chinese line marker is read as a line number" "$m" "$REPO" \
       "test_a_row_label_is_not_a_line_number"

# --- M13-M14: the BARE-CODE half (2026-09-11) ----------------------------------------------
# A check on 2026-09-11 ran this scanner's own parser over four codes the repo
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

# --- M15-M19: the TWO-DOCUMENT half --------------------------------------------
# The open document lost its fixed entries, so 450 old citations now need the other file's name.
# Each check below is a way for that to go quiet: a fixed code cited against the open file reads
# as fine (M15), the fixed file's own citations are never read (M16), a code is defined in both
# files and the citation has two places to land (M17), or the parser reads no codes out of
# one of the documents and every floor-less check stays green over nothing (M18, M19).

m=$(mutant m15 '            if code in known:
                continue
            if code in fixed:'$'\x1f''            if code in known or code in fixed:
                continue
            if code in fixed:')
report "M15: a fixed code cited against the open document passes" "$m" "$REPO" \
       "test_a_fixed_code_cited_against_the_open_document_is_reported"

m=$(mutant m16 '        for line_no, raw, code in bare_code_citations(text, FIXED_DOC_NAME_RE):'$'\x1f''        for line_no, raw, code in ():')
report "M16: citations of the fixed document are never read" "$m" "$REPO" \
       "test_an_open_code_cited_against_the_fixed_document_is_reported"

m=$(mutant m17 '    return read_defined_codes(root, KI_REL) & read_defined_codes(root, FIXED_REL)'$'\x1f''    return set()')
report "M17: a code defined in both documents is not noticed" "$m" "$REPO" \
       "test_a_code_defined_in_both_documents_is_reported"

m=$(mutant m18 '    m2 = CELL_IS_CODE_RE.fullmatch(cell)'$'\x1f''    m2 = None')
report "M18: the table parser reads no code out of the fixed document" "$m" "$REPO" \
       "test_the_real_fixed_document_parses_into_entries"

m=$(mutant m19 '    heading_spans(H3_RE)
'$'\x1f''    pass
')
report "M19: the heading parser reads no code out of the open document" "$m" "$REPO" \
       "test_the_real_document_parses_into_entries"

# --- M20-M27: more checks on the two-document half -------------------------------------
m=$(mutant m20 '        raise IOError("%s is not in %s -- nothing to check citations against" % (rel, root))'$'\x1f''        return set()')
report "M20: a missing fixed document reads as a clean scan" "$m" "$REPO" \
       "test_a_missing_fixed_document_is_an_error_not_a_clean_scan"

m=$(mutant m21 '    return "KNOWN" in text or "FIXED" in text'$'\x1f''    return "KNOWN" in text')
report "M21: the fast path skips a file that names only the fixed document" "$m" "$REPO" \
       "test_an_open_code_cited_against_the_fixed_document_is_reported"

# M22 is applied to the DATA, like M1: a copy of the tree gets one code defined in both documents.
# The repository test must go red on it, and only a tree that is green first proves that it is the
# duplicate and not something else that did it.
T22="$BK/tree.m22"
snapshot_tree "$T22"
if ! run_against "$TEST" "$T22" >/dev/null 2>&1; then
    echo "🔴 the tree copy is RED before the M22 mutation -- M22 would prove nothing" >&2
    run_against "$TEST" "$T22" | grep -E '^(FAIL|ERROR): ' | sed 's/^/    /' >&2
    SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1))
else
    printf '%s\n' '| B-9 | a row that repeats an open code | fixed | nowhere |' >> "$T22/doc/FIXED-ISSUES.md"
    report "M22 (data): a code defined in both documents" "$TEST" "$T22" \
           "test_no_code_is_defined_in_both_documents"
fi

m=$(mutant m23 'CODE_RE = re.compile(r"\b([A-Z]-\d+[a-z]?)[\u2460-\u2473]?(?!\w)")'$'\x1f''CODE_RE = re.compile(r"\b([A-Z]-\d+[a-z]?)\b")')
report "M23: a circled digit hides the code it belongs to" "$m" "$REPO" \
       "test_a_circled_digit_suffix_is_part_of_the_citation"

m=$(mutant m24 '    if os.path.splitext(path)[1]:'$'\x1f''    if True:')
report "M24: a script with no suffix is never read" "$m" "$REPO" \
       "test_a_suffixless_script_with_a_shebang_is_read"

m=$(mutant m25 '            return fh.read(2) == b"#!"'$'\x1f''            return True')
report "M25 (widening): every file with no suffix is read" "$m" "$REPO" \
       "test_a_suffixless_file_without_a_shebang_is_not_read"

m=$(mutant m26 'SKIP_DIR_PREFIXES = ("build",)'$'\x1f''SKIP_DIR_PREFIXES = ()')
report "M26: a build tree is walked" "$m" "$REPO" \
       "test_a_suffixless_script_in_a_build_tree_is_not_read"

m=$(mutant m27 '    if os.path.islink(path) or not os.path.isfile(path):
        return False'$'\x1f''    if False:
        return False')
report "M27: a named pipe is opened" "$m" "$REPO" \
       "test_a_named_pipe_without_a_suffix_does_not_hang_the_walk"

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
