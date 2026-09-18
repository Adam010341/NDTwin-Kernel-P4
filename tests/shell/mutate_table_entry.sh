#!/usr/bin/env bash
#
# Mutation gate for the generic table-entry writer (G5) and what a FOREIGN pipeline changes:
# `P4RuntimeClient.encode_value` / `build_table_entry` / `write_table_entry`,
# `POST /p4/table_entry`, and the startup / readopt branches that apply a package's own entries
# and stop doing the things a tutorials pipeline cannot support. TICKET-P2 section 4.5.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS GATE IS NOT OPTIONAL HERE. Almost every defect this code can have is SILENT at the
# switch. An lpm prefix pinned to /32 forwards one address and blackholes the subnet; a
# truncated action parameter forwards to a port nobody named; a clone session programmed into a
# pipeline that never clones succeeds and then reports zero samples for the rest of the run; an
# unknown table name that resolves to some other table writes a real rule into the wrong place
# and answers 200. Not one of those raises, and the suites that cover them are exactly the kind
# that stay green whatever the code does -- so each of them gets a mutation, and each mutation
# names the single test that must go red.
#
# 🔴 THE MUTANT IS A COPY. Every mutation is applied to a copy of p4_proxy under a temp dir and
# the tests run there. Nothing under p4_proxy/ is written -- another session may be executing
# those files right now -- and all three sources plus the five test files are re-hashed at the
# end. `setting/` is linked rather than copied: the topology models are the fabric's, several
# megabytes, and nothing here mutates them.
#
# 🔴 ONE MUTATION IS DELIBERATELY NOT HERE, because it is EQUIVALENT in this tree:
#
#   * "apply the package's entries under NDTwin's own pipeline TOO" written as a change to
#     `_pipeline_is_ndtwin`'s BASE DIRECTORY (say, resolving against the package dir instead of
#     the proxy root). Under phase-1 `app_package.py` every package's `pipeline_for` returns the
#     fabric-wide pair, so both spellings answer the same paths and the predicate is unchanged.
#     M-B18 mutates the predicate's RESULT instead, which a package declaring its own artefacts
#     can tell apart -- and that package is a fixture, not a file on disk.
#
# Usage:  tests/shell/mutate_table_entry.sh
#         PROXY_PY=/path/to/python tests/shell/mutate_table_entry.sh
# Assumes: nothing about the cwd.
# Exit:    0 every mutation caught, 1 a mutation survived, 2 refused (no interpreter, or the
#          baseline was red), 3 a source file changed underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
TEST_ROUTE="$REPO/p4_proxy/tests/test_table_entry_route.py"
TEST_STARTUP="$REPO/p4_proxy/tests/test_startup.py"
TEST_READOPT="$REPO/p4_proxy/tests/test_readopt.py"
TEST_PROXY="$REPO/p4_proxy/tests/test_app_package_proxy.py"

MODULES="tests.test_p4_client_writes tests.test_table_entry_route tests.test_startup \
tests.test_readopt tests.test_app_package_proxy"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up -- asked of git
# rather than spelled as somebody's home directory, which would make this gate runnable on one
# machine. Override with PROXY_PY= .
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

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-tableentry-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
# Every mutant lives at $BK/<label>, so each one's `p4_proxy` root is that directory and the
# repo root the tests derive from it is $BK. The models and the compiled p4info are read, never
# written, so they are linked in once rather than copied per mutation.
ln -s "$REPO/setting" "$BK/setting"

BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TEST_ROUTE=$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)
BASE_TEST_STARTUP=$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)
BASE_TEST_READOPT=$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)
BASE_TEST_PROXY=$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

# The tests import proxy_agent the way the proxy is launched, so the mutant needs the package,
# the tests beside it, and mininet/ (app_package, topo_from_json and grpc_ports all live there).
# PYTHONDONTWRITEBYTECODE so a mutant cannot be run from a .pyc of its unmutated self -- a .pyc
# is revalidated against (mtime-in-SECONDS, size), and two same-size mutants written in one
# second are exactly the trap mutate_ryu_rest_topology_bounded.sh documents.
run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest $MODULES -v 2>&1 )
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    # 🔴 A SUITE THAT DID NOT FINISH IS NOT A VERDICT, in either direction. `timeout 300`
    # returns 124, and unittest prints its `FAIL: <name>` section at the END -- so a mutant
    # that hangs the run produces no named failure and would be scored a survivor of nothing.
    # Named, and it fails the gate. (mutate_app_package.sh carries the same branch, and the
    # 2026-09-18 incident that put it there.)
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 HUNG   %-72s (the suite never finished -- never a catch)\n' "$1"
        return
    fi
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-72s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-72s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole copy of p4_proxy's importable tree plus the compiled artefacts: the client,
# the proxy and the route are one chain, and a mutation to any of them has to be exercised
# through the real import rather than through a stub of the other two. The anchor must be
# unique, so a mutation cannot quietly land somewhere other than where it says.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from a function's
# own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is not checking
# (finding #28).
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
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
mkdir -p "$base/p4_src"; cp -r "$REPO/p4_proxy/p4_src/build" "$base/p4_src/" 2>/dev/null
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | /usr/bin/grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- what goes on the wire: the value encoder and the entry builder --------------------------

m=$(mutant b1 "$CLIENT" \
    '            if priority and not self.table_honours_priority(table):' \
    '            if False:')
report "M-B1: a priority no table column can honour is accepted instead of refused" "$m" \
       "test_a_priority_on_a_table_with_no_priority_column_is_refused"

m=$(mutant b2 "$CLIENT" \
    '    def _table_by_name(self, name):
        for table in self.p4info.tables:
            if name in (table.preamble.name, table.preamble.alias):
                return table' \
    '    def _table_by_name(self, name):
        for table in self.p4info.tables:
            if True:
                return table')
report "M-B2: an unknown table name resolves to some other table and the Write goes out" "$m" \
       "test_an_unknown_table_reaches_no_switch"

m=$(mutant b3 "$CLIENT" \
    '                m.lpm.prefix_len = prefix_len' \
    '                m.lpm.prefix_len = 32')
report "M-B3: every lpm entry is a /32, so a subnet route blackholes all but one address" "$m" \
       "test_the_prefix_length_is_not_pinned_to_the_field_width"

m=$(mutant b4 "$CLIENT" \
    '        entry.is_default_action = default_action' \
    '        entry.is_default_action = False')
report "M-B4: a default action is written as an ordinary entry with no key" "$m" \
       "test_a_default_action_is_marked_as_one_and_carries_no_match"

m=$(mutant b5 "$CLIENT" \
    '    if value >= (1 << bitwidth):
        raise TableEntryInvalid(' \
    '    if False:
        raise TableEntryInvalid(')
report "M-B5: a value wider than its field is truncated rather than refused" "$m" \
       "test_a_value_wider_than_its_field_is_refused_rather_than_truncated"

m=$(mutant b6 "$CLIENT" \
    '            if kind not in BUILDABLE_MATCH_TYPES:' \
    '            if False:')
report "M-B6: a ternary match is built as something else instead of answering 501" "$m" \
       "test_a_ternary_match_is_501_and_names_the_match_type"

m=$(mutant b16 "$CLIENT" \
    '                return bytes.fromhex("".join(groups))' \
    '                return bytes.fromhex("".join(reversed(groups)))')
report "M-B16: a MAC goes onto the wire byte-reversed, and bmv2 takes it" "$m" \
       "test_a_mac_string_is_six_raw_bytes_in_the_order_it_was_written"

m=$(mutant b19 "$CLIENT" \
    '        self.stub.Write(req, timeout=RPC_TIMEOUT_S)

        table_name = self._table_name(entry.table_id)' \
    '        try:
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
        except grpc.RpcError:
            update.type = TABLE_ENTRY_OPS["modify"]
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)

        table_name = self._table_name(entry.table_id)')
report "M-B19: the silent MODIFY fallback comes back, so an overwrite reports an insert" "$m" \
       "test_a_grpc_refusal_is_raised_and_not_retried_as_a_modify"

# --- the endpoint -----------------------------------------------------------------------------

m=$(mutant b13 "$CLIENT" \
    '        self._refuse_write(f"a table entry {op}")' \
    '        pass')
report "M-B13: an external control plane's fabric takes the write and answers 200" "$m" \
       "test_an_external_control_plane_is_409"

m=$(mutant b7 "$ROUTES" \
    '    if table_entries_report is not None:
        written = table_entries_report()' \
    '    if False:
        written = table_entries_report()')
report "M-B7: switch_state stops saying what was written to each switch" "$m" \
       "test_every_switch_reports_what_was_written_and_that_none_of_it_is_journaled"

m=$(mutant b14 "$MAIN" \
    '                     "journaled": False}' \
    '                     "journaled": True}')
report "M-B14: switch_state claims these entries survive a proxy restart" "$m" \
       "test_the_count_reaches_the_endpoint_report_not_just_the_response"

m=$(mutant b15 "$ROUTES" \
    '    if note_api_table_entry_write is not None:
        note_api_table_entry_write(raw_dpid)' \
    '    if False:
        note_api_table_entry_write(raw_dpid)')
report "M-B15: a rule POSTed by hand is never counted, so nothing says it will vanish" "$m" \
       "test_an_accepted_write_is_counted_where_switch_state_can_report_it"

m=$(mutant b17 "$ROUTES" \
    '    if pipelines_report is not None:
        pipelines = pipelines_report()' \
    '    if False:
        pipelines = pipelines_report()')
report "M-B17: switch_state stops saying which program each switch is running" "$m" \
       "test_every_switch_says_which_pipeline_it_is_running_and_names_it"

# --- startup under a foreign pipeline ---------------------------------------------------------

m=$(mutant b18 "$MAIN" \
    '    return (package.pipeline_for(dpid, base_dir)
            == app_package.baseline().pipeline_for(dpid, base_dir))' \
    '    return True')
report "M-B18: every switch is called an NDTwin switch, so no branch below ever fires" "$m" \
       "test_a_package_naming_its_own_artefacts_does_not"

m=$(mutant b8 "$MAIN" \
    '        if i in foreign and i not in broken and not read_only:' \
    '        if i not in broken and not read_only:')
report "M-B8: the exercise's entries are applied to NDTwin's own pipeline as well" "$m" \
       "test_under_ndtwins_own_pipeline_the_entries_stay_recorded_and_unapplied"

m=$(mutant b9 "$MAIN" \
    '        if i in foreign:
            # [Co-developed with claude code -- Adam]
            # 🔴 The PRE write would SUCCEED.' \
    '        if False:
            # [Co-developed with claude code -- Adam]
            # 🔴 The PRE write would SUCCEED.')
report "M-B9: a clone session is programmed into a pipeline that never clones" "$m" \
       "test_a_foreign_pipeline_gets_no_clone_session_and_no_sflow_registration"

m=$(mutant b10 "$MAIN" \
    '        skipped.extend([SKIP_CLONE, SKIP_TELEMETRY, SKIP_LLDP, SKIP_WATCHDOG, SKIP_ROUTES])' \
    '        skipped.extend([SKIP_CLONE, SKIP_TELEMETRY])')
report "M-B10: LLDP, the watchdog and the routes are switched off without being named" "$m" \
       "test_a_foreign_pipeline_names_every_fabric_wide_step_it_switched_off"

m=$(mutant b11 "$MAIN" \
    '            out["failed"] += 1' \
    '            out["applied"] += 1')
report "M-B11: an entry the switch refused is counted as applied" "$m" \
       "test_one_refused_entry_does_not_cost_the_others"

m=$(mutant b12 "$MAIN" \
    '    if ndtwin or result.get("status") != "success":
        return result' \
    '    if True:
        return result')
report "M-B12: readopt leaves the switch empty -- the push erased the package's entries" "$m" \
       "test_the_packages_entries_go_back_on_after_the_push_that_erased_them"

# --- negative controls -----------------------------------------------------------------------
#
# A gate that reddens on anything is not a gate. These are edits that change no behaviour these
# suites specify, and each must leave the suite GREEN -- which `report` would score as a
# SURVIVOR, so they are run separately and the survivor count is not touched.

control() {  # $1 = label, $2 = mutant dir, $3 = what must stay green
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-72s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 RED   %-72s -- these suites are change detectors, not a specification\n' "$1"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -4 | sed 's/^/             /'
    fi
}

m=$(mutant n1 "$CLIENT" \
    '#: Match types this writer can put on the wire.' \
    '# MUTANT: a comment, and nothing else.
#: Match types this writer can put on the wire.')
control "N1 (control): a comment-only edit beside the writer" "$m" "the whole suite stays green"

m=$(mutant n2 "$MAIN" \
    '    entry_errors = {}
    for i, client in clients.items():' \
    '    entry_errors = {}
    # MUTANT: a comment, and nothing else.
    for i, client in clients.items():')
control "N2 (control): a comment-only edit inside the entry-applying loop" "$m" \
        "the whole suite stays green"

m=$(mutant n3 "$ROUTES" \
    '    op = data.get("op", "insert")' \
    '    op = data.get("op") if "op" in data else "insert"')
control "N3 (control): the same default written the long way" "$m" "the whole suite stays green"

echo
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)" == "$BASE_TEST_ROUTE" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_route.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)" == "$BASE_TEST_STARTUP" ]] || { echo "🔴 baseline CHANGED -- test_startup.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)" == "$BASE_TEST_READOPT" ]] || { echo "🔴 baseline CHANGED -- test_readopt.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)" == "$BASE_TEST_PROXY" ]] || { echo "🔴 baseline CHANGED -- test_app_package_proxy.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (3 sources, 5 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
