#!/usr/bin/env bash
#
# Mutation gate for p4_proxy/tests/test_table_entry_owner.py: the generic table-entry writer
# refuses the tables NDTwin owns (409 `owned_by_ndtwin`).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS GATE EXISTS. The defect it guards is silent at the switch: an API write with an
# EMPTY match into `MyIngress.flow_5tuple` is a catch-all that matches every packet, and the
# switch accepts it and answers OK. Nothing downstream raises. The check that refuses it is four
# small decisions -- is this a baseline switch, is this the package's bound route table, is the
# binding's owner ndtwin, is this the boot default -- and every one of them can be wrong in a way
# that leaves most of the suite green: a check that is simply not called, an owner test turned
# round, an exception that has grown to cover an API write, a baseline branch that no longer
# fires. Each mutation below puts one of those back and must turn its named case red.
#
# 🔴 Two directions, as mutate_rule_journal_is_wired.sh has them. A refusal that is too WEAK lets
# the catch-all through (M1-M4, M7, M12). A refusal that is too WIDE refuses the author's own
# table, which is also a defect and which a "must refuse" test never sees (M5, M6, M8, M9,
# M10, M11). The mutations are labelled by which way they go.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY of p4_proxy under a temp dir and
# the tests are run there. Nothing under p4_proxy/ is written -- another session may be executing
# those files right now -- and the sources and the test files are re-hashed at the end. A
# comment-only edit is applied first as a negative control: it must NOT turn anything red, or the
# gate is reporting on something other than behaviour.
#
# Usage:  tests/shell/mutate_table_entry_owner.sh
#         PROXY_PY=/path/to/python tests/shell/mutate_table_entry_owner.sh
# Exit:   0 every mutation caught and the control held, 1 a mutation survived or the control
#         failed, 2 refused (no interpreter, or the baseline was red), 3 a source changed
#         underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
TEST_OWNER="$REPO/p4_proxy/tests/test_table_entry_owner.py"
# The two suites whose doubles bind a user-table switch explicitly. They are in the baseline so a
# mutation that made the check refuse a user write is seen by their success-path tests as well.
TEST_ROUTE="$REPO/p4_proxy/tests/test_table_entry_route.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
# test_foreign_pipeline holds the one test that puts NDTwin's own compiled p4info (flow_5tuple) in a
# baseline client and expects the owner refusal; test_exact_one_element_list is the foreign-pipeline
# double that binds None. Both need p4_src/build and tools/, linked or copied below.
TEST_FOREIGN="$REPO/p4_proxy/tests/test_foreign_pipeline.py"
TEST_EXACT="$REPO/p4_proxy/tests/test_exact_one_element_list.py"
# The end-to-end suite: a package the converter wrote with an owner-ndtwin route role, driven
# through main.build_p4_client, startup and readopt_switch.
TEST_PACKAGE="$REPO/p4_proxy/tests/test_table_entry_owner_package.py"
MODULES="tests.test_table_entry_owner tests.test_table_entry_route tests.test_p4_client_writes \
tests.test_foreign_pipeline tests.test_exact_one_element_list tests.test_table_entry_owner_package"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up. Override with
# PROXY_PY= .
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no interpreter with fastapi/networkx/grpc. Set PROXY_PY=<path>." >&2
    echo "        A gate that cannot run its tests has not checked anything, so it does not" >&2
    echo "        get to exit 0." >&2
    exit 2
}
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-owner-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
# `proxy_agent.main`, which the test imports, loads a topology model at import time from
# `<repo root>/setting`, and a mutant tree under $BK has no such directory. An input, never a
# subject, so linked rather than copied.
ln -s "$REPO/setting" "$BK/setting"
# The foreign-pipeline suites read ticket A's compiled fixtures under tools/ and run its converter,
# which derives the model reader's path from its own __file__ (see mutate_table_entry.sh for why
# p4_proxy/ is linked too). Inputs, never subjects.
ln -s "$REPO/tools" "$BK/tools"
ln -s "$REPO/p4_proxy" "$BK/p4_proxy"
[[ -d "$REPO/p4_proxy/p4_src/build" ]] || echo "note: p4_proxy/p4_src/build is absent, so the real-p4info test skips and M16 cannot be caught"
BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_TEST_OWNER=$(sha256sum "$TEST_OWNER" | cut -d' ' -f1)
BASE_TEST_ROUTE=$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TEST_FOREIGN=$(sha256sum "$TEST_FOREIGN" | cut -d' ' -f1)
BASE_TEST_EXACT=$(sha256sum "$TEST_EXACT" | cut -d' ' -f1)
BASE_TEST_PACKAGE=$(sha256sum "$TEST_PACKAGE" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

# PYTHONDONTWRITEBYTECODE so a mutant cannot be run from a .pyc of its unmutated self.
run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest $MODULES -v 2>&1 )
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -e "$2/.applied" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  NOT APPLIED %-62s (the anchor is missing, so nothing was mutated)\n' "$1"
        return
    fi
    out=$(run_against "$2"); rc=$?
    # A suite that did not finish is not a verdict in either direction.
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  HUNG     %-66s (the suite never finished -- never a catch)\n' "$1"
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-66s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

control() {   # $1 = name, $2 = mutant dir: an edit that changes no behaviour must stay green
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -e "$2/.applied" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  NOT APPLIED %-62s (the anchor is missing, so the control proves nothing)\n' "$1"
        return
    fi
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  held     %-66s (comment-only edit, suite still green)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  BROKEN   %-66s (a comment-only edit turned the suite red)\n' "$1"
        grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from a function's
# own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is not checking.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    mkdir -p "$d/p4_src"
    cp -r "$REPO/p4_proxy/p4_src/build" "$d/p4_src/" 2>/dev/null
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    # The python above asserts its anchor, but this shell has no `set -e`: without this marker a
    # missing anchor leaves an UNMUTATED copy, and a control would print "held" for an edit that
    # never happened. report() and control() both refuse a copy that lacks it.
    [[ $? -eq 0 ]] && touch "$d/.applied"
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
mkdir -p "$base/p4_src"; cp -r "$REPO/p4_proxy/p4_src/build" "$base/p4_src/" 2>/dev/null
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the negative control ----------------------------------------------------------------------

m=$(mutant c1 "$CLIENT" \
    '        before anything is built: a table that cannot be resolved here is left for' \
    '        before anything is built: a table that cannot be resolved here is left to')
control "C1 (control): a docstring comma moves" "$m"

# --- too weak: the catch-all goes through ------------------------------------------------------

m=$(mutant m1 "$CLIENT" \
    '        self._refuse_owned_table(spec, op, source)' \
    '        pass')
report "M1: write_table_entry no longer asks whether the table is owned" "$m" \
       "test_an_empty_match_into_flow_5tuple_is_refused_and_nothing_is_written"

m=$(mutant m2 "$CLIENT" \
    '        return (binding.owner == route_binding_module.OWNER_NDTWIN' \
    '        return (binding.owner != route_binding_module.OWNER_NDTWIN')
report "M2: the owner test is inverted (a package binding)" "$m" \
       "test_an_api_match_entry_into_the_owned_route_table_is_refused"

m=$(mutant m3 "$CLIENT" \
    '        if (source == ENTRY_SOURCE_BOOT
                and binding.source == route_binding_module.SOURCE_PACKAGE' \
    '        if (True
                and binding.source == route_binding_module.SOURCE_PACKAGE')
report "M3: the default-action exception is widened to API writes" "$m" \
       "test_an_api_default_action_change_on_the_owned_route_table_is_refused"

m=$(mutant m4 "$CLIENT" \
    '        if binding.source == route_binding_module.SOURCE_BASELINE:
            return True' \
    '        if False:
            return True')
report "M4: a baseline-bound switch no longer owns every table" "$m" \
       "test_an_empty_match_into_flow_5tuple_is_refused_and_nothing_is_written"

m=$(mutant m5 "$CLIENT" \
    '        if (source == ENTRY_SOURCE_BOOT
                and binding.source == route_binding_module.SOURCE_PACKAGE' \
    '        if (source in (ENTRY_SOURCE_BOOT, ENTRY_SOURCE_REPLAY)
                and binding.source == route_binding_module.SOURCE_PACKAGE')
report "M5: a replayed default is treated as a boot one" "$m" \
       "test_a_replayed_default_is_refused_like_an_api_one"

m=$(mutant m6 "$CLIENT" \
    '                and binding.source == route_binding_module.SOURCE_PACKAGE
' \
    '')
report "M6: the exception also covers the default of a baseline table" "$m" \
       "test_a_baseline_default_is_refused_inside_the_boot_block_too"

m=$(mutant m7 "$CLIENT" \
    '                and spec.get("default_action") is True
' \
    '')
report "M7: the exception admits a non-default entry that has no match" "$m" \
       "test_a_boot_entry_with_no_match_that_is_not_a_default_is_refused"

m=$(mutant m7b "$CLIENT" \
    '                and not spec.get("match")
' \
    '')
report "M7b: the exception admits a default that also names a match" "$m" \
       "test_a_boot_default_that_also_names_a_match_is_refused"

m=$(mutant m8 "$CLIENT" \
    '                and op in ("insert", "modify")):' \
    '                and True):')
report "M8: the exception also covers a boot delete" "$m" \
       "test_a_boot_delete_of_the_default_is_refused"

m=$(mutant m9 "$CLIENT" \
    '        _entry_source.reset(token)' \
    '        pass')
report "M9: the boot marking is never taken back after the block" "$m" \
       "test_the_boot_exception_does_not_outlive_the_boot_block"

# --- too wide: the author's own tables are refused ---------------------------------------------

m=$(mutant m10 "$CLIENT" \
    '                and binding.table in (table.preamble.name, table.preamble.alias))' \
    '                and True)')
report "M10: every table of a package switch is owned, not just the bound one" "$m" \
       "test_a_write_into_the_packages_own_user_table_is_still_accepted"

m=$(mutant m11 "$CLIENT" \
    '        binding = self.route_binding
        if binding is None:
            return False
        if binding.source == route_binding_module.SOURCE_BASELINE:' \
    '        binding = self.route_binding
        if binding is None:
            return True
        if binding.source == route_binding_module.SOURCE_BASELINE:')
report "M11: a foreign switch with no roles owns every table" "$m" \
       "test_a_foreign_switch_with_no_roles_owns_nothing"

m=$(mutant m12 "$MAIN" \
    '            with p4_client_module.entry_source(p4_client_module.ENTRY_SOURCE_BOOT):' \
    '            if True:')
report "M12: package boot entries are no longer marked as boot writes" "$m" \
       "test_the_boot_default_of_the_owned_route_table_still_installs"

# --- the answer the caller reads ---------------------------------------------------------------

m=$(mutant m13 "$ROUTES" \
    '"error": "owned by NDTwin", "outcome": "owned_by_ndtwin",' \
    '"error": "owned by NDTwin", "outcome": "refused",')
report "M13: the 409 body no longer says owned_by_ndtwin" "$m" \
       "test_the_headline_post_is_409_owned_by_ndtwin_and_writes_nothing"

m=$(mutant m14 "$ROUTES" \
    '                    "remedy": err.remedy,' \
    '                    "pad": "x" * 300,
                    "remedy": err.remedy,')
report "M14: the remedy is pushed past the first 200 bytes of the body" "$m" \
       "test_the_remedy_and_where_it_ends_are_inside_the_first_200_bytes_of_the_body"

m=$(mutant m15 "$CLIENT" \
    '        self._refuse_write(f"a table entry {op}")
        source =' \
    '        source =')
report "M15: an external control plane is no longer refused first" "$m" \
       "test_an_external_control_plane_is_still_told_that_first"

m=$(mutant m16 "$CLIENT" \
    '        self._refuse_owned_table(spec, op, source)' \
    '        pass')
report "M16: the check is dropped (NDTwin's own flow_5tuple p4info, a baseline client)" "$m" \
       "test_a_ternary_table_in_a_real_compiled_p4info_is_owned_and_its_builder_says_unsupported"

m=$(mutant m17 "$CLIENT" \
    '        if not self.table_owned_by_ndtwin(table):' \
    '        _b = self.route_binding
        if not (_b is not None and (_b.source == route_binding_module.SOURCE_BASELINE
                or (_b.owner == route_binding_module.OWNER_NDTWIN and _b.table == spec["table"]))):')
report "M17: the owner test compares the spelling in the request, not the resolved table" "$m" \
       "test_the_alias_of_the_owned_route_table_is_refused"

m=$(mutant m18 "$CLIENT" \
    '        source = _entry_source.get() if source is None else source' \
    '        source = _entry_source.get()')
report "M18: an explicit source argument is ignored" "$m" \
       "test_an_explicit_boot_source_installs_the_default"

m=$(mutant m19 "$CLIENT" \
    '        if source not in ENTRY_SOURCES:
            raise ValueError(
                f"entry source must be one of {list(ENTRY_SOURCES)}, got {source!r}")
        self._refuse_owned_table(spec, op, source)' \
    '        self._refuse_owned_table(spec, op, source)')
report "M19: an unknown source is no longer a ValueError" "$m" \
       "test_an_unknown_source_is_a_valueerror_and_writes_nothing"

m=$(mutant m20 "$CLIENT" \
    '    try:
        yield
    finally:
        _entry_source.reset(token)' \
    '    yield
    _entry_source.reset(token)')
report "M20: the boot marking is reset outside a finally" "$m" \
       "test_the_boot_exception_does_not_survive_a_refused_boot_entry"

m=$(mutant m21 "$CLIENT" \
    '_entry_source = contextvars.ContextVar("p4_table_entry_source", default=ENTRY_SOURCE_API)' \
    'class _GlobalSource:
    value = ENTRY_SOURCE_API

    def get(self):
        return self.value

    def set(self, value):
        old, self.value = self.value, value
        return old

    def reset(self, token):
        self.value = token


_entry_source = _GlobalSource()')
report "M21: the boot marking is one process-wide value, not per thread" "$m" \
       "test_an_api_write_is_refused_while_a_boot_write_is_blocked_on_the_wire"

m=$(mutant m22 "$CLIENT" \
    '        if binding.source == route_binding_module.SOURCE_BASELINE:
            why =' \
    '        if True:
            why =')
report "M22: the 409 remedy is NDTwin-pipeline text even for a package role" "$m" \
       "test_on_a_package_pipeline_the_409_names_the_role_and_points_at_another_table"

m=$(mutant m23 "$CLIENT" \
    '        shown = (sorted(match_types) if match_types
                 else "(default action)" if entry.is_default_action else "(no match fields)")' \
    '        shown = sorted(match_types) or "(default action)"')
report "M23: an empty match is labelled (default action) again" "$m" \
       "test_an_empty_match_entry_that_is_not_a_default_is_not_labelled_default"

m=$(mutant m24 "$MAIN" \
    '            with p4_client_module.entry_source(p4_client_module.ENTRY_SOURCE_BOOT):' \
    '            if True:')
report "M24: startup and readopt no longer mark the package entries as boot" "$m" \
       "test_startup_applies_the_packages_default_and_fails_nothing"

echo
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_OWNER" | cut -d' ' -f1)" == "$BASE_TEST_OWNER" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_owner.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)" == "$BASE_TEST_ROUTE" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_route.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_FOREIGN" | cut -d' ' -f1)" == "$BASE_TEST_FOREIGN" ]] || { echo "🔴 baseline CHANGED -- test_foreign_pipeline.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_EXACT" | cut -d' ' -f1)" == "$BASE_TEST_EXACT" ]] || { echo "🔴 baseline CHANGED -- test_exact_one_element_list.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PACKAGE" | cut -d' ' -f1)" == "$BASE_TEST_PACKAGE" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_owner_package.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (p4_client.py, main.py, api_routes.py, the six test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
