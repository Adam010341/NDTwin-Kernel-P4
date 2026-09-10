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
# Twenty-one mutations, in four families:
#   M1-M3, M9   the gate goes BLIND: it stops globbing tests/*.cpp, stops knowing the C++
#               spelling, reports findings and still exits 0, or stops following a name from the
#               line that chose it to the line that deletes it.
#   M4, M10-M11 the gate goes LOUD, which is the other way it gets switched off: mkdtemp reported
#               as a hazard, every /tmp word reported whether or not anything writes to it, and a
#               triple-quoted blob of foreign source read as this file's own paths.
#   M12-M21     B12 + D1/D2: one re-spelling of the same fixed temp path per mutation, one scope
#               narrowing, and the C++ one-hop rule the docstring had always promised.
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

# --- family 4: the spellings, and the scope (B12 + D1/D2, 2026-09-11) ----------------------------
# hunt-0911/F-B0-B12-REPORT.md §3.1 put five re-spellings of one fixed temp path through this tool
# and got `0 fixed temp paths`, rc 0, out of every one; F-OFFLINE-1-REPORT.md §1.17 added a scope
# that was three non-recursive globs and a KNOWN LIMIT scan_cpp did not honour. Each mutation below
# puts one of those back, so that "the gate guards the property" is a thing that has been measured
# rather than a thing the docstring says. Half of them are widenings: undoing a spelling test is
# cheap, and turning the gate into "no /tmp in tests" gets it switched off instead.

m12=$(mutant m12 '        if marker not in _MARKER_IS_AN_IDENTIFIER:'$'\x1f''        if True:')
report "M12: a per-process marker is a substring again (mkdtemp_root)" "$m12" \
       "test_a_variable_merely_NAMED_mkdtemp_does_not_make_a_path_safe"

m13=$(mutant m13 'CPP_NAME_WITHOUT_RESERVING = re.compile(r"\b(?:std::)?(?:tmpnam|tempnam)\s*\(")'$'\x1f''CPP_NAME_WITHOUT_RESERVING = re.compile(r"(?!x)x")')
report "M13: tmpnam/tempnam are not temp roots" "$m13" \
       "test_cpp_tmpnam_names_a_file_it_does_not_reserve"

m14=$(mutant m14 '    env = PY_TEMP_ENV.search(code)'$'\x1f''    env = None')
report "M14: Python does not read \$TMPDIR out of the environment" "$m14" \
       "test_python_reads_TMPDIR_out_of_the_environment"

m15=$(mutant m15 '    if PY_BARE_TEMP_ROOT.search(code) and PY_JOINS_A_NAME_ON.search(code):'$'\x1f''    if False:')
report "M15: a name joined onto a bare /tmp is not a root" "$m15" \
       "test_a_name_joined_onto_a_bare_tmp"

m16=$(mutant m16 '_SH_TEMP_ENV_NAMES = r"TMPDIR|TEMPDIR|TEMP|TMP"'$'\x1f''_SH_TEMP_ENV_NAMES = r"TMPDIR"')
report "M16: only \$TMPDIR is the environment's temp dir, not \$TMP" "$m16" \
       "test_shell_TMP_is_the_same_variable_as_TMPDIR"

m17=$(mutant m17 '        if name not in locally_bound:'$'\x1f''        if True:')
report "M17 (widening): a local TMP= no longer shadows the environment" "$m17" \
       "test_a_local_TMP_shadows_the_environments_TMP"

m18=$(mutant m18 '    for here, dirnames, filenames in os.walk(root):'$'\x1f''    for here, dirnames, filenames in list(os.walk(root))[:1]:')
report "M18: the tree walk stops at the top of each suite again" "$m18" \
       "test_a_subdirectory_of_tests_is_walked"

m19=$(mutant m19 '                and (prefix is None or name.startswith(prefix)))'$'\x1f''                and (prefix is None or True))')
report "M19 (widening): every script under tools/ is treated as a test" "$m19" \
       "test_a_driver_under_tools_is_not_a_test_and_stays_out_of_scope"

m20=$(mutant m20 '        bound = CPP_NAME_BOUND_TO_A_PATH.search(stmt)'$'\x1f''        bound = None')
report "M20: a C++ name is not followed from where it was chosen" "$m20" \
       "test_a_cpp_name_bound_to_a_fixed_path_and_created_one_line_later"

m21=$(mutant m21 'CPP_NAME_BOUND_TO_A_PATH = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")'$'\x1f''CPP_NAME_BOUND_TO_A_PATH = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*=")')
report "M21 (widening): a C++ == comparison is read as a binding" "$m21" \
       "test_a_cpp_name_compared_against_is_not_a_binding"

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
