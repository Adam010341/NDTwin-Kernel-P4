#!/usr/bin/env bash
#
# Mutation gate for finding #78 -- check_gate_anchors.py decided which argument of a gate names a
# FILE with `"/" in v`, so a mutation gate whose target sits at the repo ROOT had every one of its
# anchors attributed to the only slash-bearing string it declared.
#
# [Co-developed with claude code -- Adam]
#
# Measured 2026-09-03 on tests/shell/mutate_testbed_banner.sh, the first gate in this repo whose
# target is a root file: `MISSING:23` against a gate whose 23 anchors are all present and all
# unique. 🔴 That is the one answer this tool is built to make impossible. NO-ANCHORS and UNPARSED
# are loud and useless; MISSING:23 is quiet and WRONG, and a reader of that cell goes looking for
# 23 drifted anchors that never drifted.
#
# It drives one suite:
#
#   tests/python/test_check_gate_anchors.py   classes ATargetAtTheRepoRootIsAFile (the eight
#                                             shapes) and NotEveryStringIsAFile (the other
#                                             direction). The rest of that file is the L-3 gate,
#                                             tests/shell/mutate_check_gate_anchors.sh.
#
# 🔴 Three directions, not one:
#
#   (defect)     the `"/" in v` test, put back one call site at a time. There are SEVEN places
#                the tool asks "file, or the text to search for", and each is reached by a
#                different gate shape -- so each is put back on its own, and the case that must go
#                red is the one for that shape. Putting back one and watching a DIFFERENT case go
#                red would be this gate signing off on the wrong evidence: R6 was written pointing
#                at the obvious gate and survived there, because a second rule reaches the same
#                call line. It is named at the one gate that rule cannot reach.
#   (loosening)  the honest weakening the tool already has: an anchor whose file it could not pin
#                down is counted across the UNION of every path the gate declares. That union
#                finds the right count often enough to hide a broken route, which is why six of
#                the cases assert the anchor was PINNED to `epsilon.py` rather than merely
#                counted correctly.
#   (control)    "every argument is a file". It satisfies every case in the first group -- every
#                root target resolves, because everything resolves -- and turns the checker into
#                something that counts anchors in whatever string it was handed. R1 and R3 are
#                that direction, and both must turn a case labelled control red.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY in a temp dir and the suite is
# pointed at the copy with CHECKER_UNDER_TEST. tests/shell/check_gate_anchors.py itself is never
# written -- this worktree is shared and another session may be running it right now. Byte
# identity is asserted at the end regardless.
#
# Nothing is built, nothing is killed, no lab is touched: the tool is read-only and every gate it
# reads here is a synthetic one in a temp git repo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHECKER="$HERE/check_gate_anchors.py"
TEST="$REPO/tests/python/test_check_gate_anchors.py"
PY="${PY:-/usr/bin/python3}"
command -v "$PY" >/dev/null || { echo "no python3 -- set PY"; exit 2; }
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-anchors-root-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "$CHECKER" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
run_against() { CHECKER_UNDER_TEST="$1" timeout 300 "$PY" "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutated copy, $3 = the test method that must fail
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "^FAIL: $3 " <<<"$out"; then
        printf '  caught   %-62s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-62s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR): |^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /'
    fi
}

# An ERROR is NOT a kill: a mutation that makes the tool crash before the named case can run
# proves nothing about that case, which is why report() greps for FAIL specifically.
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

# --- 🔴 the control direction: every argument is a file ------------------------------------------
# Both of these make every root target in this gate resolve. They are what "fixing" this finding
# looks like if nobody writes the other direction down.

m=$(mutant r1 '    if "/" in v:
        return True                             # unchanged: a directory part is a path'$'\x1f''    if True:
        return True                             # unchanged: a directory part is a path')
report "R1 (control): every string is a file, anchors included" "$m" \
       "test_anchor_text_is_never_promoted_to_a_file"

m=$(mutant r3 '    return _BARE_FILENAME.fullmatch(v) is not None and bool(exists(v))'$'\x1f''    return bool(exists(v))')
report "R3 (control): anything the tree answers to is a file, whatever its shape" "$m" \
       "test_anchor_text_is_never_promoted_to_a_file"

# --- the predicate's own contract ----------------------------------------------------------------

m=$(mutant r2 '    return _BARE_FILENAME.fullmatch(v) is not None and bool(exists(v))'$'\x1f''    return _BARE_FILENAME.fullmatch(v) is not None')
# A name that LOOKS like a file is not a file. Without the tree's answer, a target no rev holds
# gets pinned and the run reports a counted verdict (NOFILE, exit 1) instead of admitting it could
# not work out which file was meant (exit 2, NOT CHECKED) -- the L-3 failure, one layer down.
report "R2: a filename-shaped word is a file without asking the tree" "$m" \
       "test_a_root_target_that_is_not_in_the_tree_is_not_checked"

m=$(mutant r4 '    if exists is None:
        return False                            # no rev to ask -- do not guess'$'\x1f''    if exists is None:
        return True                             # no rev to ask -- do not guess')
report "R4: with no rev to ask, guess yes" "$m" \
       "test_a_bare_name_is_a_path_only_when_the_tree_holds_one"

m=$(mutant r5 '    if "/" in v:
        return True                             # unchanged: a directory part is a path'$'\x1f''    if False:
        return True                             # unchanged: a directory part is a path')
# The other half of the contract: the slash rule NEVER asked the tree and still must not, or every
# gate in the repo changes its verdict on a rev that happens to have moved a file.
report "R5: a path with a directory part now needs the tree's permission too" "$m" \
       "test_a_path_with_a_directory_part_still_needs_no_permission"

# --- the seven call sites, one at a time ---------------------------------------------------------

m=$(mutant r6 '        return v if (v is not w and is_repo_path(v, exists)) else None'$'\x1f''        return v if (v is not w and "/" in v) else None')
# 🔴 Named at the SHORT-anchor gate, not at the obvious one. The obvious gate's call line is
# reached by the generic rule as well, which pins the same anchor to the same file and leaves this
# mutation invisible -- measured, it survived there. The generic rule ignores anchors under eight
# characters, so a short one has the applier's own named roles as its only route.
report "R6: the positional file lookup is slash-only again" "$m" \
       "test_a_short_anchors_root_target_is_pinned_by_the_appliers_named_roles"

m=$(mutant r7 '        if v and "$" not in v and is_repo_path(v, exists) and (exists is None or exists(v)):'$'\x1f''        if v and "$" not in v and "/" in v and (exists is None or exists(v)):')
report "R7: a file baked into the applier body is slash-only again" "$m" \
       "test_a_baked_in_root_targets_anchor_is_pinned_to_the_root_file"

m=$(mutant r8 '            if val is w or not is_repo_path(val, exists):'$'\x1f''            if val is w or "/" not in val:')
report "R8: the generic <file> <anchor> rule is slash-only again" "$m" \
       "test_a_generic_appliers_root_target_is_pinned_to_the_root_file"

m=$(mutant r9 '                if val is not w and is_repo_path(val, exists):
                    files.append(val)
                elif q != "'"'"'" and is_repo_path(val, exists) and not val.startswith("s/"):'$'\x1f''                if val is not w and "/" in val:
                    files.append(val)
                elif q != "'"'"'" and "/" in val and not val.startswith("s/"):')
report "R9: an interpreter operand is slash-only again" "$m" \
       "test_a_heredoc_appliers_root_target_is_pinned_to_the_root_file"

m=$(mutant r10 '                    if v is not x and is_repo_path(v, exists):'$'\x1f''                    if v is not x and "/" in v:')
report "R10: a file beside an inline python body is slash-only again" "$m" \
       "test_an_inline_python_appliers_root_target_is_pinned_to_the_root_file"

m=$(mutant r11 '        if is_repo_path(v, exists) and re.search(r"\.[A-Za-z0-9]+$", v):'$'\x1f''        if "/" in v and re.search(r"\.[A-Za-z0-9]+$", v):')
# The union an unpinned anchor falls back to: with the root target left out of it, the union is
# every file the gate declares EXCEPT the one it mutates.
report "R11: the declared-path union drops repo-root files" "$m" \
       "test_a_root_target_is_in_the_union_an_unpinned_anchor_falls_back_to"

m=$(mutant r12 '                and not any(deref(w, q, env) is not w
                            and is_repo_path(deref(w, q, env), exists)
                            for w, q in cmd[1:])'$'\x1f''                and not any(deref(w, q, env) is not w
                            and "/" in deref(w, q, env)
                            for w, q in cmd[1:])')
# Not a wrong count this time: a `mutate` call that names a root target is mistaken for the shape
# whose file lives in the function body, and with no file there either the whole gate is refused.
report "R12: a mutate call naming a root target is read as naming no file" "$m" \
       "test_a_bare_mutate_call_with_a_root_target_is_read_not_refused"

# --- 🔴 the control for the eight ok cases -------------------------------------------------------
# Every case above except this one is satisfied by a checker that answers ok to everything. This
# mutation IS that checker, on the root-file path, and the drift case is the only thing standing
# between "the root target resolves" and "the root target is never actually counted".

m=$(mutant r13 '        return body.count(anchor)'$'\x1f''        return 1')
report "R13 (control): every anchor is present, so nothing ever drifts" "$m" \
       "test_a_root_targets_drift_is_still_caught"

echo
if [[ "$(sha256sum "$CHECKER" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes (check_gate_anchors.py $BASE_SHA)"
else
    echo "🔴 baseline CHANGED -- check_gate_anchors.py was written during the gate"
    exit 3
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
