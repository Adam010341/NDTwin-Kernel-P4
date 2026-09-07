#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_check_test_tmpdirs.py (decision E-17).
#
# [Co-developed with claude code -- Adam]
#
# The tool under test decides whether anyone ever hears about the seventh fixture that names its
# temp path from a constant. It reports by SAYING NOTHING when a tree is clean, which is also what
# it says when it is blind -- three separate parser bugs found while writing it made whole real
# files scan green -- so its own tests have to be shown red before a clean run means anything.
#
# Eleven mutations, in three families:
#   M1-M3, M9   the gate goes BLIND: it stops globbing tests/*.cpp, stops knowing the C++
#               spelling, reports findings and still exits 0, or stops following a name from the
#               line that chose it to the line that deletes it.
#   M4, M10-M11 the gate goes LOUD, which is the other way it gets switched off: mkdtemp reported
#               as a hazard, every /tmp word reported whether or not anything writes to it, and a
#               triple-quoted blob of foreign source read as this file's own paths.
#   M5-M8       the three parser bugs, pinned: a `<<<` herestring read as a heredoc, `"$( ... )"`
#               read as an unterminated string, an unreadable file reported as a clean one, and
#               C++ comments read as code.
#
# A mutation that makes the WRONG test go red is a SURVIVOR, not a kill: the case it targets was
# never put to the test. So is one that makes the tool crash before the named case runs.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY in a temp dir and the tests are
# pointed at the copy with CHECK_TMPDIRS_UNDER_TEST. tests/shell/check_test_tmpdirs.py itself is
# never written -- this worktree is shared and another session may be running it right now. Byte
# identity is asserted at the end regardless.
#
# Nothing is built, nothing is killed, no lab is touched: the tool is read-only, every tree it
# reads here is synthetic and in a temp directory, and the one real-tree case only reads files.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHECKER="$HERE/check_test_tmpdirs.py"
TEST="$REPO/tests/python/test_check_test_tmpdirs.py"
PY="${PY:-/usr/bin/python3}"
BK=$(mktemp -d "${TMPDIR:-/tmp}/check-tmpdirs-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "$CHECKER" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
run_against() { CHECK_TMPDIRS_UNDER_TEST="$1" "$PY" "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutated copy, $3 = test that must fail
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "^\(FAIL\|ERROR\): $3 " <<<"$out"; then
        printf '  caught   %-60s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-60s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR): |^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /'
    fi
}

mutant() {   # $1 = name, $2 = anchor \x1f replacement; prints the path to the mutated copy
    local out="$BK/check.$1.py"; cp "$CHECKER" "$out"
    "$PY" - "$out" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p).read()
assert s.count(old) == 1, "anchor is not unique (%d matches): %r" % (s.count(old), old[:70])
open(p, "w").write(s.replace(old, new))
PY
    echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "$CHECKER" | tail -1
if ! run_against "$CHECKER" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    run_against "$CHECKER" | grep -E '^(FAIL|ERROR): ' | sed 's/^/    /'
    exit 2
fi
echo

# --- family 1: the gate goes blind ---------------------------------------------------------------

m1=$(mutant m1 '    ("tests", "*.cpp", scan_cpp),
'$'\x1f''')
report "M1: tests/*.cpp is no longer one of the suites" "$m1" \
       "test_the_cpp_suite_is_scanned_by_the_tree_walk"

m2=$(mutant m2 'CPP_TEMP_ROOT = re.compile(r"(?:\btemp_directory_path\s*\(\s*\))|(?:/(?:var/)?tmp/)")'$'\x1f''CPP_TEMP_ROOT = re.compile(r"/(?:var/)?tmp/")')
report "M2: only /tmp/ is a temp root, not temp_directory_path()" "$m2" \
       "test_a_constant_joined_onto_temp_directory_path"

m3=$(mutant m3 '    return 1 if findings else 0'$'\x1f''    return 0')
report "M3: findings are printed and the run still exits 0" "$m3" \
       "test_a_tree_with_a_fixed_path_exits_1_and_names_it"

m9=$(mutant m9 '            for name in _SH_VAR_USE.findall(bare):'$'\x1f''            for name in []:')
report "M9: a shell name is not followed from where it was chosen" "$m9" \
       "test_shell_constant_reached_through_a_name"

# --- family 2: the gate goes loud ----------------------------------------------------------------
# A false alarm costs the same as a miss here: the first person who has to explain why mkdtemp is
# "a hazard" turns the gate off, and then the real one goes unreported too.

m4=$(mutant m4 '    "mkdtemp",            # mkdtemp(3), tempfile.mkdtemp -- the kernel picks the name
'$'\x1f''')
report "M4 (widening): mkdtemp no longer makes a path safe" "$m4" \
       "test_mkdtemp_under_a_fixed_parent_cannot_collide"

m10=$(mutant m10 '        if head in SH_MATERIALISERS:'$'\x1f''        if True:')
report "M10 (widening): every argument of every command is a write" "$m10" \
       "test_shell_words_that_are_data"

m11=$(mutant m11 '            if tok_text.lstrip("rbufRBUF")[:3] in ('"'"'"""'"'"', "'"'"''"'"''"'"'"):'$'\x1f''            if False:')
report "M11 (widening): a triple-quoted blob is read as this file's own paths" "$m11" \
       "test_a_triple_quoted_blob_is_data"

# --- family 3: the three parser bugs, pinned -----------------------------------------------------
# Each of these was a live bug in this file at some point today, and each made whole REAL files
# scan green. They are here because "it is clean" and "I could not read it" printed the same way.

m5=$(mutant m5 '            if two == "<<":'$'\x1f''            if two == "<<" and line[j:j + 3] != "<<<":')
report "M5: the <<< guard is back, so a herestring reads as a heredoc" "$m5" \
       "test_a_herestring_is_not_a_heredoc"

m6=$(mutant m6 '                if quote == '"'"'"'"'"' and line[j:j + 2] == "$(":'$'\x1f''                if False:')
report "M6: quoting does not restart inside \"\$( ... )\"" "$m6" \
       "test_quoting_restarts_inside_a_command_substitution"

m7=$(mutant m7 '    if quote and unreadable is None:'$'\x1f''    if False:')
report "M7: a file left mid-string is reported as clean" "$m7" \
       "test_an_unterminated_quote_is_not_a_clean_file"

m8=$(mutant m8 '    code, unreadable = strip_cpp_comments(text)'$'\x1f''    code, unreadable = text, None')
report "M8 (widening): C++ comments are read as code" "$m8" \
       "test_a_defect_quoted_in_a_c_comment"

echo
if [[ "$(sha256sum "$CHECKER" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes (check_test_tmpdirs.py was never written)"
else
    echo "🔴 baseline CHANGED -- check_test_tmpdirs.py was written during the gate"
    exit 3
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
