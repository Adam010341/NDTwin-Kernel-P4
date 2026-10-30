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
# that goes red voids the run.
#
# Usage:  tests/shell/mutate_p4_one_step.sh          PROXY_PY=/path/to/python tests/shell/...
# Exit:   0 every mutation caught, every control green, every new test seen red;
#         1 otherwise; 2 refused (no interpreter, or the baseline was red); 3 a source changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
EXDIR="$REPO/tools/p4_exercise"
ONE_STEP="$REPO/tools/p4_exercise/one_step.py"
CONVERT="$REPO/tools/p4_exercise/convert.py"
PREFLIGHT="$REPO/tools/p4_exercise/preflight.py"
APP_PACKAGE="$REPO/p4_proxy/mininet/app_package.py"
ROUTE_BINDING="$REPO/p4_proxy/proxy_agent/route_binding.py"
NDT_FILE="$REPO/tools/test_workflow/ndt"
REPO_TEST="$REPO/tests/python/test_one_step_repo.py"
CAPTURE="$REPO/tests/python/fixtures/p4_health/preflight_pft.txt"
SOURCES=("$EXDIR/one_step.py" "$EXDIR/convert.py" "$EXDIR/preflight.py" "$EXDIR/common.py"
         "$APP_PACKAGE" "$ROUTE_BINDING"
         "$EXDIR/tests/test_one_step.py" "$EXDIR/tests/test_convert.py"
         "$EXDIR/tests/test_preflight.py" "$REPO/tests/python/test_one_step_repo.py")
TEST_FILES="tools/p4_exercise/tests/test_one_step tools/p4_exercise/tests/test_convert
tools/p4_exercise/tests/test_preflight tools/p4_exercise/tests/test_thrift_cli
tests/python/test_one_step_repo p4_proxy/tests/test_route_binding"
NEW_TESTS_SPEC="test_one_step:* test_convert:OwnerDefaultTest test_convert:AutoRoleFlagTest test_preflight:TheSuggestionTest test_one_step_repo:*"

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

tree_copy() {   # tree_copy <dir> -- tools/p4_exercise and p4_proxy/{mininet,proxy_agent} copied
    mkdir -p "$1/tools"
    cp -r "$EXDIR" "$1/tools/p4_exercise"
    rm -rf "$1/tools/p4_exercise/__pycache__" "$1/tools/p4_exercise/tests/__pycache__"
    # tests/ is read only (CapturedSuggestionRowsTest reads tests/python/fixtures/p4_health).
    # tests/python is copied (a mutation may touch a capture or test_one_step_repo.py's own
    # pattern); nothing else under tests/ is read.
    mkdir -p "$1/tests"
    cp -r "$REPO/tests/python" "$1/tests/python"
    find "$1/tests/python" -name __pycache__ -prune -exec rm -rf {} +
    ln -s "$REPO/tools/ndt_serve" "$1/tools/ndt_serve"      # read only, by test_one_step_repo.py
    mkdir -p "$1/tools/test_workflow"
    cp "$REPO/tools/test_workflow/ndt" "$1/tools/test_workflow/ndt"      # read by test_one_step_repo.py
    ln -s "$REPO/setting" "$1/setting"                      # read only, by test_route_binding.py
    # p4_proxy: the two directories a mutation may touch are copied, everything else is linked.
    mkdir -p "$1/p4_proxy"
    local e
    for e in "$REPO"/p4_proxy/* "$REPO"/p4_proxy/.[!.]*; do
        [[ -e "$e" ]] || continue
        case "${e##*/}" in
            mininet|proxy_agent) cp -r "$e" "$1/p4_proxy/"
                                 rm -rf "$1/p4_proxy/${e##*/}/__pycache__" ;;
            *) ln -s "$e" "$1/p4_proxy/${e##*/}" ;;
        esac
    done
}

run_tests() {   # run_tests <tree> -> every FAIL/ERROR test name, one per line, then RC=<n>
    local t rc=0 out
    for t in $TEST_FILES; do
        out="$(cd "$1/p4_proxy" && PYTHONPATH=. timeout 600 "$PY" "$1/$t.py" -v 2>&1)" || rc=1
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
NEW_TESTS="$(cd "$BK/base/p4_proxy" && PYTHONPATH="$BK/base/tools/p4_exercise/tests:$BK/base/tests/python" "$PY" - $NEW_TESTS_SPEC <<'PY'
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

apply() {   # apply <tree> <file> <old> <new>  -> "ok" | "ANCHOR:<n>" | "COMPILE"
    "$PY" - "$1/${2#"$REPO/"}" "$3" "$4" <<'PY'
import io, py_compile, sys
target, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(target, encoding="utf-8").read()
c = s.count(old)
if c != 1:
    print("ANCHOR:%d" % c); sys.exit(0)
io.open(target, "w", encoding="utf-8").write(s.replace(old, new, 1))
if not target.endswith(".py"):
    print("ok"); sys.exit(0)
try:
    py_compile.compile(target, doraise=True, cfile=target + ".gatecheck")
except py_compile.PyCompileError:
    print("COMPILE"); sys.exit(0)
print("ok")
PY
}

mut() {   # mut <name> <file> <old> <new> <test that must go red>...
    local name="$1" file="$2" old="$3" new="$4"; shift 4
    local d="$BK/$name" res out want missing=()
    tree_copy "$d"
    res="$(apply "$d" "$file" "$old" "$new")"
    if [[ "$res" != ok ]]; then
        printf '  SURVIVED %-62s (%s)\n' "$name" "$res"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_tests "$d")"
    if grep -q '^__NO_RUN__' <<<"$out"; then
        printf '  SURVIVED %-62s (a test file did not run)\n' "$name"; SURVIVED=$((SURVIVED+1)); return
    fi
    grep -v '^RC=' <<<"$out" >> "$BK/seen"
    for want in "$@"; do grep -qxF "$want" <<<"$out" || missing+=("$want"); done
    if (( $# > 0 && ${#missing[@]} == 0 )); then
        printf '  caught   %-62s red: %s\n' "$name" "$*"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-62s still green: %s\n' "$name" "${missing[*]:-<no test named>}"; SURVIVED=$((SURVIVED+1))
    fi
    grep -v '^RC=' <<<"$out" | sort -u | sed 's/^/             also red: /'
    rm -rf "$d"
}

control() {   # control <name> <file> <old> <new> -- the suite must stay GREEN
    local name="$1" file="$2" old="$3" new="$4"
    local d="$BK/$name" res out
    tree_copy "$d"
    res="$(apply "$d" "$file" "$old" "$new")"
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
mut T1_several_take_the_first "$ONE_STEP" \
    '    if len(found) == 1:
        return found[0], "the only one"' \
    '    if found:
        return found[0], "the only one"' \
    test_several_and_no_topo_are_refused_listed_and_the_flag_named
mut T2_top_level_ignored "$ONE_STEP" \
    '        out.append("topology.json")' \
    '        pass' \
    test_a_top_level_topology_is_a_candidate_too
mut T3_build_dirs_count "$ONE_STEP" \
    'NOT_TOPOLOGY_DIRS = ("build", "logs", "pcaps", "ndtwin")' \
    'NOT_TOPOLOGY_DIRS = ()' \
    test_build_logs_pcaps_and_a_package_model_are_not_candidates
mut T4_flag_ignored "$ONE_STEP" \
    '    if given:
        return _package_path(given, TOPOLOGY_FLAG), f"{TOPOLOGY_FLAG}"' \
    '    if False:
        return _package_path(given, TOPOLOGY_FLAG), f"{TOPOLOGY_FLAG}"' \
    test_the_flag_picks_one_over_the_makefile
mut T5_neither_unsaid "$ONE_STEP" \
    '    if not found:
        raise convert.ConversionError(
            f"{exercise_dir} is neither' \
    '    if False:
        raise convert.ConversionError(
            f"{exercise_dir} is neither' \
    test_a_directory_with_no_topology_is_neither
mut T6_package_taken_as_exercise "$ONE_STEP" \
    '    if os.path.isfile(os.path.join(exercise_dir, "package.json")):' \
    '    if False:' \
    test_a_package_directory_is_refused_as_an_exercise
mut T7_the_only_one_unsaid "$ONE_STEP" \
    '        return found[0], "the only one"' \
    '        return found[0], "found"' \
    test_the_only_topology_is_used

# --- one_step.py: the program ---------------------------------------------------------------
mut P1_default_prog_ignored "$ONE_STEP" \
    '    default = makefile_var(exercise_dir, "DEFAULT_PROG")' \
    '    default = None' \
    test_the_makefiles_default_prog_is_the_program
mut P2_several_take_the_first "$ONE_STEP" \
    '    if len(found) == 1:
        return found[0], "the only .p4 at the top"' \
    '    if found:
        return found[0], "the only .p4 at the top"' \
    test_several_programs_and_no_default_prog_are_refused_naming_the_flag
mut P3_the_one_refused "$ONE_STEP" \
    '    if len(found) == 1:
        return found[0], "the only .p4 at the top"' \
    '    if len(found) == 99:
        return found[0], "the only .p4 at the top"' \
    test_the_one_program_at_the_top
mut P4_flag_ignored "$ONE_STEP" \
    '    if given:
        return _package_path(given, "--p4"), "--p4"' \
    '    if False:
        return _package_path(given, "--p4"), "--p4"' \
    test_the_flag_picks_the_program
mut P5_no_program_unnamed "$ONE_STEP" \
    '            f"{exercise_dir} has no .p4 program at its top. Name it with --p4, for example  "' \
    '            f"{exercise_dir} has no .p4 program at its top. Add one, for example  "' \
    test_no_program_at_the_top_is_refused_naming_the_flag
mut P6_missing_default_prog_unchecked "$ONE_STEP" \
    '        if not os.path.isfile(os.path.join(exercise_dir, default)):' \
    '        if False:' \
    test_a_default_prog_that_is_not_there_is_refused

# --- one_step.py: where it goes, and a re-run -------------------------------------------------
mut L1_inside_the_exercise "$ONE_STEP" \
    '    return os.path.join(os.path.abspath(run_dir), "packages", "generated",' \
    '    return os.path.join(real, "packages", "generated",' \
    test_it_goes_under_the_run_directory test_the_exercise_is_never_written
mut L2_not_keyed_by_path "$ONE_STEP" \
    '    digest = hashlib.sha256(real.encode("utf-8")).hexdigest()[:8]' \
    '    digest = "00000000"' \
    test_two_exercises_with_one_name_get_two_packages
mut R1_never_unchanged "$ONE_STEP" \
    '        if os.path.isdir(dest) and _tree(dest) == _tree(staging):' \
    '        if False:' \
    test_the_same_result_keeps_the_old_package_untouched test_but_it_is_reused_when_nothing_changed
mut R2_in_use_replaced "$ONE_STEP" \
    '        elif os.path.isdir(dest) and _same_dir(dest, in_use):' \
    '        elif False:' \
    test_a_package_a_fabric_still_runs_is_not_replaced
mut R3_copied_over "$ONE_STEP" \
    '            shutil.rmtree(old, ignore_errors=True)
            state = "replaced"' \
    '            shutil.copytree(os.path.join(old, "pkg"), dest, dirs_exist_ok=True)
            shutil.rmtree(old, ignore_errors=True)
            state = "replaced"' \
    test_a_different_result_replaces_it_whole
mut R4_staging_left "$ONE_STEP" \
    '        if os.path.isdir(staging):
            shutil.rmtree(staging, ignore_errors=True)' \
    '        if False:
            shutil.rmtree(staging, ignore_errors=True)' \
    test_and_nothing_is_written

# --- one_step.py: which role ------------------------------------------------------------------
mut O1_explicit_does_not_win "$ONE_STEP" \
    '            auto_role=(role is None and not no_roles), owner=owner, auto_report=auto,' \
    '            auto_role=not no_roles, owner=owner, auto_report=auto,' \
    test_an_explicit_role_wins_over_the_auto_filled_one
mut O2_no_roles_ignored "$ONE_STEP" \
    '            auto_role=(role is None and not no_roles), owner=owner, auto_report=auto,' \
    '            auto_role=(role is None), owner=owner, auto_report=auto,' \
    test_no_roles_declares_none

# --- one_step.py: the command line ------------------------------------------------------------
mut C1_usage_combination_accepted "$ONE_STEP" \
    '    if args.no_roles and (args.role_ipv4_route is not None or args.table_owner is not None):' \
    '    if False:' \
    test_usage_errors_are_2
mut C2_refusal_is_0 "$ONE_STEP" \
    '        print(f"REFUSED: {exc}")
        return RC_REFUSED' \
    '        print(f"REFUSED: {exc}")
        return RC_OK' \
    test_a_refusal_is_5_and_emits_nothing
mut C3_no_path_emitted "$ONE_STEP" \
    '            fh.write(result["dest"] + "\n")' \
    '            fh.write("\n")' \
    test_a_ready_package_is_0_and_its_path_is_emitted

# --- convert.py: --auto-role, --owner, the owner default --------------------------------------
mut A1_several_take_the_first "$CONVERT" \
    '        if len(found["candidates"]) == 1:' \
    '        if found["candidates"]:' \
    test_several_candidates_no_roles_a_warning_naming_each
mut A2_owner_ndtwin_not_refused "$CONVERT" \
    '    if owner == "ndtwin" and found["role"] is None:' \
    '    if False:' \
    test_table_owner_ndtwin_with_no_single_candidate_is_refused
mut A3_no_warning "$CONVERT" \
    '        lines.append(f"  WARNING       : {NO_PATHS_WARNING}")' \
    '        pass' \
    test_zero_candidates_no_roles_and_a_warning
mut A4_external_not_special "$CONVERT" \
    '    if external:' \
    '    if False:' \
    test_an_external_control_plane_gets_none_and_says_why
mut A5_owner_flag_ignored "$CONVERT" \
    '                                owner or DEFAULT_ROLE_OWNER)' \
    '                                DEFAULT_ROLE_OWNER)' \
    test_owner_ndtwin_uses_the_detected_table_and_takes_its_entries_out test_with_owner_ndtwin_it_takes_the_owned_entries_out
mut A6_role_that_does_not_resolve "$CONVERT" \
    '            found["role"] = dict(found["candidates"][0], owner=owner)' \
    '            found["role"] = dict(found["candidates"][0], owner=owner, table="MyIngress.nope")' \
    test_the_auto_filled_role_passes_pre_flights_route_binding_check
mut A7_auto_role_writes_nothing "$CONVERT" \
    '        role_ipv4_route = found["role"]' \
    '        pass' \
    test_it_fills_the_one_candidate_with_owner_package test_one_candidate_is_filled_with_owner_package
mut A8_choice_unsaid "$CONVERT" \
    '        return ["  route role    : auto-filled from the p4info -- its one (table, action) "' \
    '        return ["  route role    : chosen -- its one (table, action) "' \
    test_the_choice_is_printed
mut A9_auto_role_by_default "$CONVERT" \
    '    ap.add_argument("--auto-role", action="store_true",' \
    '    ap.add_argument("--auto-role", action="store_false",' \
    test_without_it_there_are_no_roles
mut A10_both_role_sources_taken "$CONVERT" \
    '    if auto_role and role_ipv4_route is not None:' \
    '    if False:' \
    test_with_an_explicit_role_it_is_refused
mut A11_owner_with_nothing_accepted "$CONVERT" \
    '        if args.table_owner is not None and args.role_ipv4_route is None and not args.auto_role:' \
    '        if False:' \
    test_an_owner_with_no_role_is_refused
mut D1_default_owner_ndtwin "$CONVERT" \
    'DEFAULT_ROLE_OWNER = "package"' \
    'DEFAULT_ROLE_OWNER = "ndtwin"' \
    test_a_role_without_owner_is_owner_package test_owner_package_keeps_the_authors_entries
mut D2_owner_conflict_accepted "$CONVERT" \
    '    if owner is not None and values.get("owner", owner) != owner:' \
    '    if False:' \
    test_an_owner_written_twice_differently_is_refused
mut D3_any_owner_flag_refused "$CONVERT" \
    '    if owner is not None and values.get("owner", owner) != owner:' \
    '    if owner is not None:' \
    test_the_same_owner_twice_is_fine test_the_owner_flag_fills_it
mut D4_format_two "$CONVERT" \
    '        "format": common.PACKAGE_FORMAT,' \
    '        "format": 2,' \
    test_the_package_format_is_still_one
mut D5_unbuilt_unsaid "$CONVERT" \
    '                    f"is not at {abs_path}. Build the exercise first (`make build` in "' \
    '                    f"is not at {abs_path}. Build the exercise first (`make` in "' \
    test_an_unbuilt_exercise_is_refused_with_make_build

# --- preflight.py: the heuristic --------------------------------------------------------------
mut H1_first_candidate_only "$PREFLIGHT" \
    '        out.append(role)
    return out' \
    '        out.append(role)
        break
    return out' \
    test_every_candidate_is_returned_and_the_suggestion_is_the_first
# Two defences, mutated together: the intersection across switches AND the resolve on every
# switch each refuse a candidate one switch lacks, so either alone is masked by the other.
mut H2_any_switch_will_do "$PREFLIGHT" \
    '        shared = found if shared is None else shared & found
    out = []
    for table, field, action, mac, port in sorted(shared or ()):
        role = {"owner": "ndtwin", "table": table, "match_field": field, "action": action,
                "params": {"dst_mac": mac, "port": port}}
        try:
            for dpid, p4info in p4infos.items():' \
    '        shared = found if shared is None else shared | found
    out = []
    for table, field, action, mac, port in sorted(shared or ()):
        role = {"owner": "ndtwin", "table": table, "match_field": field, "action": action,
                "params": {"dst_mac": mac, "port": port}}
        try:
            for dpid, p4info in list(p4infos.items())[:1]:' \
    test_a_candidate_must_fit_every_switch


# --- the TOPO default, paths, staging, the stripped count, the flags ---------------------
# [Co-developed with claude code -- Adam]
mut N1_topo_ignored "$ONE_STEP" \
    '    make_topo = makefile_var(exercise_dir, "TOPO")' \
    '    make_topo = None' \
    test_the_makefiles_topo_is_the_default
mut N2_missing_topo_unchecked "$ONE_STEP" \
    '        if not os.path.isfile(os.path.join(exercise_dir, make_topo)):' \
    '        if False:' \
    test_a_topo_that_is_not_there_is_refused
mut N3_symlink_kept "$ONE_STEP" \
    '    exercise_dir = os.path.realpath(exercise_dir)' \
    '    exercise_dir = os.path.abspath(exercise_dir)' \
    test_a_symlinked_path_is_the_same_exercise
mut N4_lost_manifest_converted "$ONE_STEP" \
    '    if os.path.isfile(os.path.join(exercise_dir, PACKAGE_MODEL)):' \
    '    if False:' \
    test_a_package_that_lost_its_manifest_is_refused_not_converted
mut N5_stale_staging_kept "$ONE_STEP" \
    '        shutil.rmtree(stale, ignore_errors=True)' \
    '        pass' \
    test_staging_a_killed_run_left_behind_is_removed
mut N6_every_staging_removed "$ONE_STEP" \
    '    for stale in glob.glob(os.path.join(stage_root, glob.escape(os.path.basename(dest)) + ".*-*")):' \
    '    for stale in glob.glob(os.path.join(stage_root, "*")):' \
    test_staging_a_killed_run_left_behind_is_removed
mut N7_staging_under_packages "$ONE_STEP" \
    '    return os.path.join(os.path.abspath(run_dir), "packages-staging")' \
    '    return os.path.join(os.path.abspath(run_dir), "packages", "staging")' \
    test_staging_is_outside_packages test_ndt_serve_will_not_take_a_staging_directory
mut N8_stripped_unsaid "$ONE_STEP" \
    '    if route is not None and route["owner"] == "ndtwin":' \
    '    if False:' \
    test_owner_ndtwin_says_how_many_entries_it_stripped
mut N9_stripped_said_for_package "$ONE_STEP" \
    '    if route is not None and route["owner"] == "ndtwin":' \
    '    if route is not None:' \
    test_owner_package_strips_nothing_and_says_nothing
mut N10_count_not_collected "$ONE_STEP" \
    '            removed=removed, mode=mode)' \
    '            removed={}, mode=mode)' \
    test_owner_ndtwin_says_how_many_entries_it_stripped
mut N11_several_not_offered_as_flags "$ONE_STEP" \
    '        if len(candidates) > 1:' \
    '        if False:' \
    test_several_candidates_are_printed_as_the_ndt_flag_that_picks_each
mut N13_bad_role_is_a_refusal "$ONE_STEP" \
    '            print(f"usage: {exc}", file=sys.stderr)
            return RC_USAGE' \
    '            print(f"usage: {exc}", file=sys.stderr)' \
    test_usage_errors_are_2
mut N15_in_use_dropped "$ONE_STEP" \
    '                         no_roles=args.no_roles, in_use=args.in_use, mode=args.mode)' \
    '                         no_roles=args.no_roles, in_use=None, mode=args.mode)' \
    test_the_in_use_flag_reaches_the_replace_guard test_every_flag_is_forwarded_to_prepare
mut N16_topology_dropped "$ONE_STEP" \
    '        result = prepare(args.exercise_dir, args.run_dir, topology=args.topology, p4=args.p4,' \
    '        result = prepare(args.exercise_dir, args.run_dir, topology=None, p4=args.p4,' \
    test_every_flag_is_forwarded_to_prepare
mut N17_p4_dropped "$ONE_STEP" \
    '        result = prepare(args.exercise_dir, args.run_dir, topology=args.topology, p4=args.p4,' \
    '        result = prepare(args.exercise_dir, args.run_dir, topology=args.topology, p4=None,' \
    test_every_flag_is_forwarded_to_prepare
mut N18_role_dropped "$ONE_STEP" \
    '                         role_text=args.role_ipv4_route, owner=args.table_owner,' \
    '                         role_text=None, owner=args.table_owner,' \
    test_every_flag_is_forwarded_to_prepare
mut N19_table_owner_dropped "$ONE_STEP" \
    '                         role_text=args.role_ipv4_route, owner=args.table_owner,' \
    '                         role_text=args.role_ipv4_route, owner=None,' \
    test_every_flag_is_forwarded_to_prepare
mut N20_no_roles_dropped "$ONE_STEP" \
    '                         no_roles=args.no_roles, in_use=args.in_use, mode=args.mode)' \
    '                         no_roles=False, in_use=args.in_use, mode=args.mode)' \
    test_every_flag_is_forwarded_to_prepare

# --- pre-flight's suggestion, and a role that names no owner -----------------------------
mut S1_suggestion_owner_ndtwin "$PREFLIGHT" \
    '    block = {"ipv4_route": dict(suggestion, owner="package")}' \
    '    block = {"ipv4_route": suggestion}' \
    test_the_suggestion_offers_owner_package \
    test_every_captured_suggestion_row_is_what_preflight_prints_now \
    test_a_foreign_route_shaped_table_without_roles_gets_one_pasteable_line
mut S2_suggestion_on_external "$PREFLIGHT" \
    '        if mode == "external" or not report.suggest_roles:' \
    '        if not report.suggest_roles:' \
    test_none_is_offered_on_an_external_control_plane
mut S3_suggestion_not_switchable "$PREFLIGHT" \
    '        if mode == "external" or not report.suggest_roles:' \
    '        if mode == "external":' \
    test_it_can_be_switched_off
mut S4_cli_switch_ignored "$PREFLIGHT" \
    '                 suggest_roles=not args.no_role_suggestion)' \
    '                 suggest_roles=True)' \
    test_the_command_line_switch_reaches_it
mut S5_loader_default_ndtwin "$APP_PACKAGE" \
    'ROLE_DEFAULT_OWNER = "package"' \
    'ROLE_DEFAULT_OWNER = "ndtwin"' \
    test_the_loader_gives_it_owner_package test_the_loader_and_the_resolver_agree_on_the_shape
mut S6_loader_owner_required "$APP_PACKAGE" \
    '    route = dict(route, owner=route.get("owner", ROLE_DEFAULT_OWNER))' \
    '    pass' \
    test_the_loader_gives_it_owner_package test_a_package_whose_role_names_no_owner_passes_pre_flight
mut S7_resolver_default_ndtwin "$ROUTE_BINDING" \
    'DEFAULT_OWNER = OWNER_PACKAGE' \
    'DEFAULT_OWNER = OWNER_NDTWIN' \
    test_the_resolver_gives_it_owner_package test_the_loader_and_the_resolver_agree_on_the_shape
mut S8_resolver_owner_required "$ROUTE_BINDING" \
    '    role = dict(role, owner=role.get("owner", DEFAULT_OWNER))' \
    '    pass' \
    test_the_resolver_gives_it_owner_package

# --- the control plane --------------------------------------------------------------------------
mut O3_mode_not_passed_to_convert "$ONE_STEP" \
    '            removed=removed, mode=mode)' \
    '            removed=removed, mode="auto")' \
    test_mode_ndtwin_overrides_the_mycontroller
mut O4_mode_flag_dropped "$ONE_STEP" \
    '                         no_roles=args.no_roles, in_use=args.in_use, mode=args.mode)' \
    '                         no_roles=args.no_roles, in_use=args.in_use, mode="auto")' \
    test_every_flag_is_forwarded_to_prepare
mut O5_why_external_unsaid "$ONE_STEP" \
    '    elif package["control_plane"]["mode"] == "external":' \
    '    elif False:' \
    test_auto_with_a_mycontroller_is_external_and_says_how_to_change_it
mut O6_any_mode_word_taken "$ONE_STEP" \
    '    ap.add_argument("--mode", default="auto", choices=("auto", "ndtwin", "external"),' \
    '    ap.add_argument("--mode", default="auto",' \
    test_a_mode_that_is_not_one_of_the_three_is_a_usage_error

# --- refusals that name their way out ----------------------------------------------------------
mut A12_several_named_in_prose "$CONVERT" \
    '        if len(found["candidates"]) > 1:' \
    '        if False:' \
    test_table_owner_ndtwin_with_several_names_each_as_a_flag_line
mut A13_several_joined_on_one_line "$CONVERT" \
    '                + "\n".join(f"    --role-ipv4-route owner=ndtwin,{role_flag_text(c)}"' \
    '                + "; ".join(f"    --role-ipv4-route owner=ndtwin,{role_flag_text(c)}"' \
    test_table_owner_ndtwin_with_several_names_each_as_a_flag_line
mut A15_external_offers_no_mode "$CONVERT" \
    '                "so NDTwin can own none. Drop --table-owner, or pass --mode ndtwin so NDTwin "' \
    '                "so NDTwin can own none. Drop --table-owner, or so NDTwin "' \
    test_table_owner_ndtwin_on_an_external_plane_says_so
mut A14_external_pointed_at_a_role "$CONVERT" \
    '        if external is True:' \
    '        if False:' \
    test_table_owner_ndtwin_on_an_external_plane_says_so

# --- moving a conversion into place ----------------------------------------------------------
mut R5_two_filesystems_taken "$ONE_STEP" \
    '    if not _same_filesystem(stage_root, os.path.dirname(dest)):' \
    '    if False:' \
    test_staging_on_another_filesystem_is_refused_before_converting
mut R6_a_failed_move_is_a_traceback "$ONE_STEP" \
    '    except OSError as exc:
        # Only EXDEV' \
    '    except ImportError as exc:
        # Only EXDEV' \
    test_a_failed_move_is_a_refusal_and_the_old_package_stays
mut R7_the_old_package_is_lost "$ONE_STEP" \
    '                    os.rename(os.path.join(old, "pkg"), dest)     # the old package goes back' \
    '                    pass' \
    test_a_failed_move_is_a_refusal_and_the_old_package_stays
mut R8_every_failure_blamed_on_filesystems "$ONE_STEP" \
    '               if exc.errno == errno.EXDEV else "")' \
    '               if True else "")' \
    test_a_failed_move_names_its_own_errno
mut R9_empty_directory_left "$ONE_STEP" \
    '                os.rmdir(old)                                  # the empty directory made for it' \
    '                pass' \
    test_a_failed_first_move_leaves_no_empty_directory
mut R10_failed_restore_is_a_traceback "$ONE_STEP" \
    '                except OSError as back:' \
    '                except ImportError as back:' \
    test_a_failed_restore_says_where_the_old_package_was_left

# --- every path the package carries stays inside it, as written ------------------------------------
mut T8_no_bound "$CONVERT" \
    '    if not norm or os.path.isabs(norm) or norm == os.pardir or norm.startswith(os.pardir + os.sep):' \
    '    if not norm:' \
    test_a_path_that_leaves_and_reenters_the_exercise_is_refused \
    test_a_runtime_file_naming_a_path_that_leaves_the_exercise_is_refused \
    test_a_topology_naming_a_runtime_file_that_leaves_the_exercise_is_refused \
    test_a_topo_outside_the_exercise_is_refused test_a_program_outside_the_exercise_is_refused
mut T9_dotdot_inside_a_path_taken "$CONVERT" \
    '    if not norm or os.path.isabs(norm) or norm == os.pardir or norm.startswith(os.pardir + os.sep):' \
    '    if not norm or os.path.isabs(norm) or norm == os.pardir:' \
    test_a_path_that_leaves_and_reenters_the_exercise_is_refused \
    test_a_runtime_file_naming_a_path_that_leaves_the_exercise_is_refused
mut T10_written_paths_unchecked "$CONVERT" \
    '    for _abs_src, rel in copies:
        package_relative(rel, "a file the package carries")' \
    '    for _abs_src, rel in []:
        package_relative(rel, "a file the package carries")' \
    test_a_runtime_file_naming_a_path_that_leaves_the_exercise_is_refused \
    test_a_topology_naming_a_runtime_file_that_leaves_the_exercise_is_refused
mut T11_topology_flag_unchecked "$ONE_STEP" \
    '        return _package_path(given, TOPOLOGY_FLAG), f"{TOPOLOGY_FLAG}"' \
    '        return given, f"{TOPOLOGY_FLAG}"' \
    test_a_topology_flag_outside_the_exercise_is_refused
mut T12_topo_unchecked "$ONE_STEP" \
    '        _package_path(make_topo, ' \
    '        (lambda *a: None)(make_topo, ' \
    test_a_topo_outside_the_exercise_is_refused
mut T13_convert_takes_any_topology "$CONVERT" \
    '    package_relative(topology_rel, "the topology")' \
    '    pass' \
    test_a_topology_or_program_outside_is_refused_by_name
mut P7_p4_flag_unchecked "$ONE_STEP" \
    '        return _package_path(given, "--p4"), "--p4"' \
    '        return given, "--p4"' \
    test_a_program_outside_the_exercise_is_refused
mut P8_default_prog_unchecked "$ONE_STEP" \
    '        _package_path(default, ' \
    '        (lambda *a: None)(default, ' \
    test_a_program_outside_the_exercise_is_refused
mut P9_convert_takes_any_program "$CONVERT" \
    '        package_relative(p4_rel, "the program (--p4)")' \
    '        pass' \
    test_a_topology_or_program_outside_is_refused_by_name
mut N21_computed_topo_called_unset "$ONE_STEP" \
    '           if computed else "its Makefile sets no TOPO")' \
    '           if False else "its Makefile sets no TOPO")' \
    test_a_computed_topo_is_said_to_be_unread_not_unset
mut N22_resolved_line_break_taken "$ONE_STEP" \
    '    if "\n" in real or "\r" in real:' \
    '    if False:' \
    test_usage_errors_are_2
mut D6_make_clean_advised_again "$CONVERT" \
    '            f"the stale one, or delete build/ and run `make build`")' \
    '            f"the stale one (or `make clean && make`)")' \
    test_both_spellings_present_is_refused_naming_both \
    test_no_printed_string_in_tools_p4_exercise_advises_make

mut C4_ndt_help_advises_make_again "$NDT_FILE" \
    'exercise is refused with the make build' \
    'exercise is refused with the (make) build' \
    test_no_line_of_ndt_but_its_comments_advises_make
mut C5_the_pattern_misses_make_and "$REPO_TEST" \
    '                         r"|\bmake\s*&&")' \
    '                         r"|\bmake\s*&&XX")' \
    test_the_pattern_tells_the_command_from_the_verb
mut C6_a_capture_says_nothing_of_its_edit "$CAPTURE" \
    '; every other row is as captured.' \
    '.' \
    test_every_capture_says_its_suggestion_row_was_edited_by_hand

# --- controls ---------------------------------------------------------------------------------
control K1_comment_in_one_step "$ONE_STEP" \
    'def _same_dir(a, b):' \
    '# (a comment the suite must not notice)
def _same_dir(a, b):'
control K2_comment_in_convert "$CONVERT" \
    'def _describe_candidate(role):' \
    'def _describe_candidate(role):
    # (a comment the suite must not notice)'

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
