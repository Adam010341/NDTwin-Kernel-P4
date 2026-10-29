#!/usr/bin/env bash
#
# Mutation gate for the exercise half of `ndt up p4 --app <exercise dir>`: tools/p4_exercise/
# one_step.py, convert.py's --auto-role / --owner / owner default, and preflight.py's
# route_role_candidates -- against tools/p4_exercise/tests/test_one_step.py and the two new classes
# of test_convert.py. `ndt`'s half is tests/shell/mutate_ndt_app_package.sh (M77..M86).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 EVERY NEW TEST HAS TO HAVE BEEN SEEN RED. Each mutation names the tests that must go red,
# and the gate records every test each mutation reddened. At the end every test in NEW_TESTS
# (enumerated by the unittest loader from the unmutated copy, not typed out) that no mutation
# reddened FAILS THE GATE by name.
#
# 🔴 THE MUTANT IS A COPY. tools/p4_exercise/ is copied under a temp dir laid out like the repo,
# with p4_proxy/ linked (read only: bytecode writing is off), and nothing in the checkout is
# written -- every source is re-hashed at the end. A mutation whose anchor does not occur exactly
# once, a mutant that does not compile, or the WRONG test going red counts as SURVIVED. A control
# that goes red voids the round.
#
# Usage:  tests/shell/mutate_p4_one_step.sh          PROXY_PY=/path/to/python tests/shell/...
# Exit:   0 every mutation caught, every control green, every new test seen red;
#         1 otherwise; 2 refused (no interpreter, or the baseline was red); 3 a source changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
EXDIR="$REPO/tools/p4_exercise"
SOURCES=("$EXDIR/one_step.py" "$EXDIR/convert.py" "$EXDIR/preflight.py" "$EXDIR/common.py"
         "$EXDIR/tests/test_one_step.py" "$EXDIR/tests/test_convert.py")
TEST_FILES="test_one_step test_convert"
NEW_TESTS_SPEC="test_one_step:* test_convert:OwnerDefaultTest test_convert:AutoRoleFlagTest"

# The interpreter: a worktree has no venv of its own, so the main worktree is consulted.
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'from p4.config.v1 import p4info_pb2' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || { echo "refused: no interpreter with the P4Runtime protobufs (set PROXY_PY)"; exit 2; }
export PYTHONDONTWRITEBYTECODE=1

BK="$(mktemp -d "${TMPDIR:-/tmp}/p4-one-step-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
sums() { sha256sum "${SOURCES[@]}"; }
BEFORE="$(sums)"

tree_copy() {   # tree_copy <dir> -- a repo-shaped copy: tools/p4_exercise copied, p4_proxy linked
    mkdir -p "$1/tools"
    cp -r "$EXDIR" "$1/tools/p4_exercise"
    rm -rf "$1/tools/p4_exercise/__pycache__" "$1/tools/p4_exercise/tests/__pycache__"
    ln -s "$REPO/p4_proxy" "$1/p4_proxy"
}

run_tests() {   # run_tests <tree> -> every FAIL/ERROR test name, one per line, then RC=<n>
    local t rc=0 out
    for t in $TEST_FILES; do
        out="$(cd "$1/p4_proxy" && PYTHONPATH=. timeout 600 "$PY" "$1/tools/p4_exercise/tests/$t.py" -v 2>&1)" || rc=1
        printf '%s\n' "$out" | sed -nE 's/^(FAIL|ERROR): (test_[A-Za-z0-9_]+) .*/\2/p'
        grep -qE '^Ran [0-9]+ test' <<<"$out" || echo "__NO_RUN__$t"
    done
    echo "RC=$rc"
}

tree_copy "$BK/base"
echo "interpreter: $PY"
echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_tests "$BK/base")"
if [[ "$(tail -1 <<<"$BASE_OUT")" != "RC=0" ]]; then
    echo "refused: baseline is not green -- mutations would prove nothing"
    sed 's/^/  /' <<<"$BASE_OUT"; exit 2
fi
echo "  green"

# The new tests, by the loader, from the unmutated copy.
NEW_TESTS="$(cd "$BK/base/p4_proxy" && PYTHONPATH="$BK/base/tools/p4_exercise/tests" "$PY" - $NEW_TESTS_SPEC <<'PY'
import sys, unittest, importlib
names = set()
for spec in sys.argv[1:]:
    mod, cls = spec.split(":")
    m = importlib.import_module(mod)
    suite = unittest.defaultTestLoader.loadTestsFromModule(m)
    def walk(s):
        for t in s:
            if isinstance(t, unittest.TestSuite):
                walk(t)
            elif cls == "*" or type(t).__name__ == cls:
                names.add(t._testMethodName)
    walk(suite)
print("\n".join(sorted(names)))
PY
)"
[[ -n "$NEW_TESTS" ]] || { echo "refused: the loader found no new tests"; exit 2; }
echo "new tests to be seen red: $(wc -l <<<"$NEW_TESTS")"
echo

CAUGHT=0; SURVIVED=0; CONTROLS_RED=0
: > "$BK/seen"

apply() {   # apply <tree> <file-rel> <spec file>  -> "ok" | "ANCHOR:<n>" | "COMPILE"
    "$PY" - "$1/tools/p4_exercise/$2" "$3" <<'PY'
import io, py_compile, sys
target, spec = sys.argv[1], sys.argv[2]
old, new = io.open(spec, encoding="utf-8").read().split("\n@@@@\n")
new = new[:-1] if new.endswith("\n") else new     # the heredoc's own last newline
s = io.open(target, encoding="utf-8").read()
c = s.count(old)
if c != 1:
    print("ANCHOR:%d" % c); sys.exit(0)
io.open(target, "w", encoding="utf-8").write(s.replace(old, new, 1))
try:
    py_compile.compile(target, doraise=True, cfile=target + ".gatecheck")
except py_compile.PyCompileError:
    print("COMPILE"); sys.exit(0)
print("ok")
PY
}

mut() {   # mut <name> <file under tools/p4_exercise> <test that must go red>... ; old @@@@ new on stdin
    local name="$1" rel="$2"; shift 2
    local d="$BK/$name" spec="$BK/$name.spec" res out want missing=()
    cat > "$spec"
    tree_copy "$d"
    res="$(apply "$d" "$rel" "$spec")"
    if [[ "$res" != ok ]]; then
        printf '  SURVIVED %-62s (%s)\n' "$name" "$res"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_tests "$d")"
    if grep -q '^__NO_RUN__' <<<"$out"; then
        printf '  SURVIVED %-62s (a test file did not run)\n' "$name"; SURVIVED=$((SURVIVED+1)); return
    fi
    grep -v '^RC=' <<<"$out" >> "$BK/seen"
    for want in "$@"; do grep -qxF "$want" <<<"$out" || missing+=("$want"); done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-62s red: %s\n' "$name" "$*"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-62s still green: %s\n' "$name" "${missing[*]}"; SURVIVED=$((SURVIVED+1))
    fi
    grep -v '^RC=' <<<"$out" | sort -u | sed 's/^/             also red: /'
    rm -rf "$d"
}

control() {   # control <name> <file> ; old @@@@ new on stdin -- the suite must stay GREEN
    local name="$1" rel="$2" d="$BK/$1" spec="$BK/$1.spec" res out
    cat > "$spec"
    tree_copy "$d"
    res="$(apply "$d" "$rel" "$spec")"
    out="$(run_tests "$d")"
    if [[ "$res" == ok && "$(tail -1 <<<"$out")" == "RC=0" ]]; then
        printf '  control  %-62s (stayed green, as it must)\n' "$name"
    else
        printf '  🔴 CONTROL %-60s (%s; %s)\n' "$name" "$res" "$(tail -1 <<<"$out")"
        CONTROLS_RED=$((CONTROLS_RED+1))
    fi
    rm -rf "$d"
}

# --- one_step.py: the topology --------------------------------------------------------------
mut T1_several_take_the_first one_step.py test_several_are_refused_listed_and_the_flag_named <<'EOF'
    if len(found) == 1:
        return found[0], "the only one"
@@@@
    if found:
        return found[0], "the only one"
EOF
mut T2_top_level_ignored one_step.py test_a_top_level_topology_is_a_candidate_too <<'EOF'
        out.append("topology.json")
@@@@
        pass
EOF
mut T3_build_dirs_count one_step.py test_build_logs_pcaps_and_a_package_model_are_not_candidates <<'EOF'
NOT_TOPOLOGY_DIRS = ("build", "logs", "pcaps", "ndtwin")
@@@@
NOT_TOPOLOGY_DIRS = ()
EOF
mut T4_flag_ignored one_step.py test_the_flag_picks_one <<'EOF'
    if given:
        return given, f"{TOPOLOGY_FLAG}"
@@@@
    if False:
        return given, f"{TOPOLOGY_FLAG}"
EOF
mut T5_neither_unsaid one_step.py test_a_directory_with_no_topology_is_neither <<'EOF'
    if not found:
        raise convert.ConversionError(
            f"{exercise_dir} is neither
@@@@
    if False:
        raise convert.ConversionError(
            f"{exercise_dir} is neither
EOF
mut T6_package_taken_as_exercise one_step.py test_a_package_directory_is_refused_as_an_exercise <<'EOF'
    if os.path.isfile(os.path.join(exercise_dir, "package.json")):
@@@@
    if False:
EOF
mut T7_the_only_one_unsaid one_step.py test_the_only_topology_is_used <<'EOF'
        return found[0], "the only one"
@@@@
        return found[0], "found"
EOF

# --- one_step.py: the program ---------------------------------------------------------------
mut P1_default_prog_ignored one_step.py test_the_makefiles_default_prog_is_the_program <<'EOF'
    default = makefile_var(exercise_dir, "DEFAULT_PROG")
@@@@
    default = None
EOF
mut P2_several_take_the_first one_step.py test_several_programs_and_no_default_prog_are_refused_naming_the_flag <<'EOF'
    if len(found) == 1:
        return found[0], "the only .p4 at the top"
@@@@
    if found:
        return found[0], "the only .p4 at the top"
EOF
mut P3_the_one_refused one_step.py test_the_one_program_at_the_top <<'EOF'
    if len(found) == 1:
        return found[0], "the only .p4 at the top"
@@@@
    if len(found) == 99:
        return found[0], "the only .p4 at the top"
EOF
mut P4_flag_ignored one_step.py test_the_flag_picks_the_program <<'EOF'
    if given:
        return given, "--p4"
@@@@
    if False:
        return given, "--p4"
EOF
mut P5_no_program_unnamed one_step.py test_no_program_at_the_top_is_refused_naming_the_flag <<'EOF'
            f"{exercise_dir} has no .p4 program at its top. Name it with --p4, for example  "
@@@@
            f"{exercise_dir} has no .p4 program at its top. Add one, for example  "
EOF
mut P6_missing_default_prog_unchecked one_step.py test_a_default_prog_that_is_not_there_is_refused <<'EOF'
        if not os.path.isfile(os.path.join(exercise_dir, default)):
@@@@
        if False:
EOF

# --- one_step.py: where it goes, and a re-run -------------------------------------------------
mut L1_inside_the_exercise one_step.py test_it_goes_under_the_run_directory test_the_exercise_is_never_written <<'EOF'
    return os.path.join(os.path.abspath(run_dir), "packages", "generated",
@@@@
    return os.path.join(real, "packages", "generated",
EOF
mut L2_not_keyed_by_path one_step.py test_two_exercises_with_one_name_get_two_packages <<'EOF'
    digest = hashlib.sha256(real.encode("utf-8")).hexdigest()[:8]
@@@@
    digest = "00000000"
EOF
mut R1_never_unchanged one_step.py test_the_same_result_keeps_the_old_package_untouched test_but_it_is_reused_when_nothing_changed <<'EOF'
        if os.path.isdir(dest) and _tree(dest) == _tree(staging):
@@@@
        if False:
EOF
mut R2_in_use_replaced one_step.py test_a_package_a_fabric_still_runs_is_not_replaced <<'EOF'
        elif os.path.isdir(dest) and _same_dir(dest, in_use):
@@@@
        elif False:
EOF
mut R3_copied_over one_step.py test_a_different_result_replaces_it_whole <<'EOF'
            old = tempfile.mkdtemp(prefix=os.path.basename(dest) + ".old-", dir=parent)
            os.rename(dest, os.path.join(old, "pkg"))
            os.rename(staging, dest)
            shutil.rmtree(old, ignore_errors=True)
@@@@
            shutil.copytree(staging, dest, dirs_exist_ok=True)
EOF
mut R4_staging_left one_step.py test_and_nothing_is_written <<'EOF'
        if os.path.isdir(staging):
            shutil.rmtree(staging, ignore_errors=True)
@@@@
        if False:
            shutil.rmtree(staging, ignore_errors=True)
EOF

# --- one_step.py: which role ------------------------------------------------------------------
mut O1_explicit_does_not_win one_step.py test_an_explicit_role_wins_over_the_auto_filled_one <<'EOF'
            auto_role=(role is None and not no_roles), owner=owner, auto_report=auto)
@@@@
            auto_role=not no_roles, owner=owner, auto_report=auto)
EOF
mut O2_no_roles_ignored one_step.py test_no_roles_declares_none <<'EOF'
            auto_role=(role is None and not no_roles), owner=owner, auto_report=auto)
@@@@
            auto_role=(role is None), owner=owner, auto_report=auto)
EOF

# --- one_step.py: the command line ------------------------------------------------------------
mut C1_usage_combination_accepted one_step.py test_usage_errors_are_2 <<'EOF'
    if args.no_roles and (args.role_ipv4_route is not None or args.owner is not None):
@@@@
    if False:
EOF
mut C2_refusal_is_0 one_step.py test_a_refusal_is_5_and_emits_nothing <<'EOF'
        print(f"REFUSED: {exc}")
        return RC_REFUSED
@@@@
        print(f"REFUSED: {exc}")
        return RC_OK
EOF
mut C3_no_path_emitted one_step.py test_a_ready_package_is_0_and_its_path_is_emitted <<'EOF'
            fh.write(result["dest"] + "\n")
@@@@
            fh.write("\n")
EOF

# --- convert.py: --auto-role, --owner, the owner default --------------------------------------
mut A1_several_take_the_first convert.py test_several_candidates_no_roles_a_warning_naming_each <<'EOF'
        if len(found["candidates"]) == 1:
@@@@
        if found["candidates"]:
EOF
mut A2_owner_ndtwin_not_refused convert.py test_owner_ndtwin_with_no_single_candidate_is_refused <<'EOF'
    if owner == "ndtwin" and found["role"] is None:
@@@@
    if False:
EOF
mut A3_no_warning convert.py test_zero_candidates_no_roles_and_a_warning <<'EOF'
        lines.append(f"  WARNING       : {NO_PATHS_WARNING}")
@@@@
        pass
EOF
mut A4_external_not_special convert.py test_an_external_control_plane_gets_none_and_says_why <<'EOF'
    if external:
@@@@
    if False:
EOF
mut A5_owner_flag_ignored convert.py test_owner_ndtwin_uses_the_detected_table_and_takes_its_entries_out test_with_owner_ndtwin_it_takes_the_owned_entries_out <<'EOF'
                                owner or DEFAULT_ROLE_OWNER)
@@@@
                                DEFAULT_ROLE_OWNER)
EOF
mut A6_role_that_does_not_resolve convert.py test_the_auto_filled_role_passes_pre_flights_route_binding_check <<'EOF'
            found["role"] = dict(found["candidates"][0], owner=owner)
@@@@
            found["role"] = dict(found["candidates"][0], owner=owner, table="MyIngress.nope")
EOF
mut A7_auto_role_writes_nothing convert.py test_it_fills_the_one_candidate_with_owner_package test_one_candidate_is_filled_with_owner_package <<'EOF'
        role_ipv4_route = found["role"]
@@@@
        pass
EOF
mut A8_choice_unsaid convert.py test_the_choice_is_printed <<'EOF'
        return ["  route role    : auto-filled from the p4info -- the one table shaped like a "
@@@@
        return ["  route role    : chosen -- the one table shaped like a "
EOF
mut A9_auto_role_by_default convert.py test_without_it_there_are_no_roles <<'EOF'
    ap.add_argument("--auto-role", action="store_true",
@@@@
    ap.add_argument("--auto-role", action="store_false",
EOF
mut A10_both_role_sources_taken convert.py test_with_an_explicit_role_it_is_refused <<'EOF'
    if auto_role and role_ipv4_route is not None:
@@@@
    if False:
EOF
mut A11_owner_with_nothing_accepted convert.py test_an_owner_with_no_role_is_refused <<'EOF'
        if args.owner is not None and args.role_ipv4_route is None and not args.auto_role:
@@@@
        if False:
EOF
mut D1_default_owner_ndtwin convert.py test_a_role_without_owner_is_owner_package test_owner_package_keeps_the_authors_entries <<'EOF'
DEFAULT_ROLE_OWNER = "package"
@@@@
DEFAULT_ROLE_OWNER = "ndtwin"
EOF
mut D2_owner_conflict_accepted convert.py test_an_owner_written_twice_differently_is_refused <<'EOF'
    if owner is not None and values.get("owner", owner) != owner:
@@@@
    if False:
EOF
mut D3_any_owner_flag_refused convert.py test_the_same_owner_twice_is_fine test_the_owner_flag_fills_it <<'EOF'
    if owner is not None and values.get("owner", owner) != owner:
@@@@
    if owner is not None:
EOF
mut D4_format_two convert.py test_the_package_format_is_still_one <<'EOF'
        "format": common.PACKAGE_FORMAT,
@@@@
        "format": 2,
EOF
mut D5_unbuilt_unsaid convert.py test_an_unbuilt_exercise_is_refused_with_the_make_command <<'EOF'
                    f"is not at {abs_path}. Build the exercise first (`make` in "
@@@@
                    f"is not at {abs_path}. (in "
EOF

# --- preflight.py: the heuristic --------------------------------------------------------------
mut H1_first_candidate_only preflight.py test_every_candidate_is_returned_and_the_suggestion_is_the_first <<'EOF'
        out.append(role)
    return out
@@@@
        out.append(role)
        break
    return out
EOF
# Two defences, mutated together: the intersection across switches AND the resolve on every
# switch each refuse a candidate one switch lacks, so either alone is masked by the other.
mut H2_any_switch_will_do preflight.py test_a_candidate_must_fit_every_switch <<'EOF'
        shared = found if shared is None else shared & found
    out = []
    for table, field, action, mac, port in sorted(shared or ()):
        role = {"owner": "ndtwin", "table": table, "match_field": field, "action": action,
                "params": {"dst_mac": mac, "port": port}}
        try:
            for dpid, p4info in p4infos.items():
@@@@
        shared = found if shared is None else shared | found
    out = []
    for table, field, action, mac, port in sorted(shared or ()):
        role = {"owner": "ndtwin", "table": table, "match_field": field, "action": action,
                "params": {"dst_mac": mac, "port": port}}
        try:
            for dpid, p4info in list(p4infos.items())[:1]:
EOF

# --- controls ---------------------------------------------------------------------------------
control K1_comment_in_one_step one_step.py <<'EOF'
def _same_dir(a, b):
@@@@
# (a comment the suite must not notice)
def _same_dir(a, b):
EOF
control K2_long_way_in_convert convert.py <<'EOF'
    lines = [f"  route role    : none -- {found['why']}"]
@@@@
    why = found["why"]
    lines = [f"  route role    : none -- {why}"]
EOF

# --- every new test seen red ------------------------------------------------------------------
echo
NEVER="$(comm -23 <(sort -u <<<"$NEW_TESTS") <(sort -u "$BK/seen"))"
if [[ -n "$NEVER" ]]; then
    echo "🔴 new tests that NO mutation reddened:"
    sed 's/^/     /' <<<"$NEVER"
else
    echo "every new test was seen red: $(wc -l <<<"$NEW_TESTS") of $(wc -l <<<"$NEW_TESTS")"
fi

AFTER="$(sums)"
if [[ "$AFTER" != "$BEFORE" ]]; then
    echo "🔴 a source CHANGED during the gate"; exit 3
fi
echo "sources byte-identical: yes"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived; $CONTROLS_RED control(s) went red"
(( SURVIVED == 0 && CONTROLS_RED == 0 )) && [[ -z "$NEVER" ]]
