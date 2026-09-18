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
# those files right now -- and all four sources plus the six test files are re-hashed at the
# end. `setting/` is linked rather than copied: the topology models are the fabric's, several
# megabytes, and nothing here mutates them.
#
# 🔴 A NOTE THAT WAS TRUE AND IS NOT ANY MORE, kept because the correction is the interesting
# part. Before ticket A merged, this header said that mutating `_pipeline_is_ndtwin`'s BASE
# DIRECTORY would be equivalent, "because under phase-1 app_package.py every package's
# `pipeline_for` returns the fabric-wide pair". A's G4 reader landed, per-switch pipelines are
# real, and `pipeline_for` now returns paths INSIDE the package directory -- so that mutation is
# no longer equivalent, and M-B34 is it: `pipeline_report_for` reading the fabric-wide pair
# instead of the per-switch one. It is killed by the only test that can tell them apart, which
# is the one holding a package whose four switches run two different programs.
#
# The lesson is the gate's, not the ticket's: an "equivalent mutation" claim is a claim about
# the tree, and it expires when the tree changes. M-B18 caught this class of rot once already
# in round 2 -- see the SUMMARY -- by SURVIVING after its anchor moved out from under it.
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
# Round 2: `readopt_switch` grew `install_routes`, which is the seam that keeps this proxy's
# shortest paths out of somebody else's `MyIngress.ipv4_lpm`. One mutation (M-B26) lives there.
TOPOMGR="$REPO/p4_proxy/proxy_agent/topology_manager.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
TEST_ROUTE="$REPO/p4_proxy/tests/test_table_entry_route.py"
TEST_STARTUP="$REPO/p4_proxy/tests/test_startup.py"
TEST_READOPT="$REPO/p4_proxy/tests/test_readopt.py"
TEST_PROXY="$REPO/p4_proxy/tests/test_app_package_proxy.py"
# The suites that meet a pipeline NDTwin did not compile: A's compiled fixtures, A's
# converter, A's runtime files. They are in their own file because mutate_app_package.sh
# runs its baseline in a tree that holds only p4_proxy/ -- see that file's own header.
TEST_FOREIGN="$REPO/p4_proxy/tests/test_foreign_pipeline.py"

MODULES="tests.test_p4_client_writes tests.test_table_entry_route tests.test_startup \
tests.test_readopt tests.test_app_package_proxy tests.test_foreign_pipeline"

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
# [Co-developed with claude code -- Adam]
# Round 2: the suites now reach two things outside p4_proxy, and both are INPUTS, never subjects.
#   tools/    -- ticket A's compiled exercise fixtures (the only foreign p4info this repo has)
#                and `convert.py`, which test_startup runs to build a real package.
#   p4_proxy/ -- NOT the mutant. `tools/p4_exercise/common.py` derives the model reader's path
#                from its own __file__ with abspath (not realpath), so through the link above it
#                looks for `$BK/p4_proxy/mininet`; without this it finds nothing and every test
#                that builds a package errors. The converter is not under mutation here, so
#                giving it the real reader is correct as well as necessary -- the mutants
#                themselves resolve everything from their own __file__ and never touch this path.
ln -s "$REPO/tools" "$BK/tools"
ln -s "$REPO/p4_proxy" "$BK/p4_proxy"

BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_TOPOMGR=$(sha256sum "$TOPOMGR" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TEST_ROUTE=$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)
BASE_TEST_STARTUP=$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)
BASE_TEST_READOPT=$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)
BASE_TEST_PROXY=$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)
BASE_TEST_FOREIGN=$(sha256sum "$TEST_FOREIGN" | cut -d' ' -f1)

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
        # 🔴 EVERY test that reddened, not only the one this mutation is named for.
        # [Co-developed with claude code -- Adam]
        # A gate that records one name per mutation cannot answer the question an auditor
        # actually asks -- "which of these tests has ever been seen to fail?" -- for any test
        # that is not somebody's named killer. M-B24 reddens
        # test_the_default_action_row_every_runtime_file_carries_is_a_modify as well as its own
        # named case, and round 2's log said nothing about it, so that test read as unproven
        # when it was not. Printed, not counted: the verdict is still the named one.
        /usr/bin/grep -E '^(FAIL|ERROR): ' <<<"$out" \
            | sed -E 's/^(FAIL|ERROR): [^(]*\(([^)]*)\).*/             also red: \2/' \
            | sort -u
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

m=$(mutant b25 "$CLIENT" \
    'BUILDABLE_MATCH_TYPES = ("EXACT", "LPM")' \
    'BUILDABLE_MATCH_TYPES = ("EXACT", "LPM", "RANGE")')
report "M-B25: a RANGE match is built instead of refused -- [lo, hi] becomes a prefix length" "$m" \
       "test_a_range_field_is_unsupported_and_says_RANGE"

m=$(mutant b21 "$CLIENT" \
    '    def _table_by_name(self, name):
        for table in self.p4info.tables:
            if name in (table.preamble.name, table.preamble.alias):' \
    '    def _table_by_name(self, name):
        for table in self.p4info.tables:
            if name == table.preamble.name:')
report "M-B21: an alias is no longer a table name, so a tutorials-shaped entry is a 404" "$m" \
       "test_the_names_may_be_aliases_because_the_tutorials_helper_accepts_both"

m=$(mutant b24 "$CLIENT" \
    '        if entry.is_default_action and op == "insert":
            op, substituted = "modify", True' \
    '        if False:
            op, substituted = "modify", True')
report "M-B24: a default action is INSERTed, which every target refuses" "$m" \
       "test_a_default_action_insert_is_sent_as_a_modify_and_says_so"

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

# TICKET-P3 2.6 gave POST /p4/multicast_group the same not-journaled warning, so the old
# one-line anchor matched twice. Extended upwards to `priority_honoured`, which only the
# table-entry response has.
m=$(mutant b20 "$ROUTES" \
    '            "priority_honoured": written["priority_honoured"],
            "journaled": False, "note": TABLE_ENTRY_NOT_JOURNALED}' \
    '            "priority_honoured": written["priority_honoured"],
            "journaled": True, "note": TABLE_ENTRY_NOT_JOURNALED}')
report "M-B20: the response claims the entry survives a restart, next to a note saying it does not" "$m" \
       "test_every_success_says_the_entry_is_not_journaled_and_what_that_costs"

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
    '    return package.pipeline_is_ndtwin(dpid, base_dir)' \
    '    return True')
report "M-B18: every switch is called an NDTwin switch, so no branch below ever fires" "$m" \
       "test_a_package_naming_its_own_artefacts_does_not"

m=$(mutant b8 "$MAIN" \
    '        if i in foreign and i not in broken and not read_only:' \
    '        if i not in broken and not read_only:')
report "M-B8: the exercise's entries are applied to NDTwin's own pipeline as well" "$m" \
       "test_under_ndtwins_own_pipeline_the_entries_stay_recorded_and_unapplied"

# 🔴 M-B9 IS RETIRED, AND THE REASON IS THE INTERESTING PART (TICKET-P3 section 9 ruling 4).
# It mutated `if i in foreign:` in the telemetry loop to `if False:` and was killed by
# `test_a_foreign_pipeline_gets_no_clone_session_and_no_sflow_registration`. TICKET-P3 put a
# telemetry-source check a few lines below it, and under `auto` a foreign pipeline resolves to
# `link` -- so with the foreign branch deleted that check skipped the same switch and the
# mutation changed nothing observable. It SURVIVED in P3-C round 1 for exactly that reason, and
# the fix was not to delete the guard: section 9 ruling 4 then made the branch conditional
# (`and source != TELEMETRY_COOPERATIVE`), because a foreign program that includes
# ndtwin_telemetry.p4 CAN clone to the CPU port and must get a session.
#
# So the claim worth mutating moved. It is no longer "a foreign switch is skipped" -- that is
# now true only sometimes, and the sometimes is the point. M-B9b below is the claim that
# replaced it, in the other direction: the branch must NOT swallow the switch that can carry
# the header. The negative direction is still covered, by the refusal
# (`test_a_foreign_pipeline_that_cannot_carry_the_header_still_gets_nothing`) and by
# M-C3/M-C22 in tests/shell/mutate_telemetry_by_name.sh.
m=$(mutant b9b "$MAIN" \
    '        if i in foreign and source != TELEMETRY_COOPERATIVE:' \
    '        if i in foreign:  # MUTANT: round 1, before section 9 ruling 4')
report "M-B9b: a foreign program that includes the header is left without a clone session" "$m" \
       "test_a_foreign_program_that_included_the_header_gets_the_cooperative_path"

m=$(mutant b10 "$MAIN" \
    '        skipped.extend(FOREIGN_PIPELINE_FABRIC_SKIPS)' \
    '        skipped.extend([SKIP_LLDP])')
report "M-B10: LLDP, the watchdog and the routes are switched off, two without being named" "$m" \
       "test_a_foreign_pipeline_names_every_fabric_wide_step_it_switched_off"

# Round 2: section 9 ruling 4 moved the expression this anchored on into `switch_skips_for`,
# which is now the ONE definition of the per-switch list (predicted before startup, re-recorded
# by startup with the decision it actually made). The mutation is unchanged in meaning: a
# foreign switch that really did skip both says it skipped nothing.
m=$(mutant b28 "$MAIN" \
    '    if ndtwin:
        return []
    if package.read_only:' \
    '    if True:
        return []
    if package.read_only:')
report "M-B28: a foreign switch says it skipped nothing, so its dead telemetry looks like a fault" "$m" \
       "test_a_foreign_switch_names_the_two_steps_it_does_not_get"

m=$(mutant b11 "$MAIN" \
    '            out["failed"] += 1' \
    '            out["applied"] += 1')
report "M-B11: an entry the switch refused is counted as applied" "$m" \
       "test_one_refused_entry_does_not_cost_the_others"

# TICKET-P3 2.1 put the telemetry note inside this branch, so the anchor is the condition
# alone now -- still one site, and `if True:` still returns before the entries go back on.
m=$(mutant b12 "$MAIN" \
    '    if ndtwin or result.get("status") != "success":' \
    '    if True:')
report "M-B12: readopt leaves the switch empty -- the push erased the package's entries" "$m" \
       "test_the_packages_entries_go_back_on_after_the_push_that_erased_them"

m=$(mutant b22 "$MAIN" \
    '        if i in foreign and i not in broken and not read_only:' \
    '        if i in foreign and not read_only:')
report "M-B22: entries are written to a switch whose pipeline push failed" "$m" \
       "test_a_switch_whose_pipeline_push_failed_gets_no_entries"

m=$(mutant b23 "$MAIN" \
    '                                     sample_callback if cooperative else None,' \
    '                                     sample_callback,')
report "M-B23: readopt hands a foreign switch the sFlow callback, so a clone session goes in" "$m" \
       "test_a_foreign_pipeline_gets_no_clone_session"

# Round 2: section 9 ruling 4 merged readopt's two "no clone session was programmed" paths into
# one guarded block (the foreign-with-header case now KEEPS its session), so the two lines this
# anchored on are no longer adjacent. Same mutation: report the session `readopt_switch` claims
# rather than the one this switch was given.
m=$(mutant b27 "$MAIN" \
    '    if result.get("status") == "success" and not cooperative:' \
    '    if False:')
report "M-B27: readopt reports a clone session on a switch that was given none" "$m" \
       "test_it_does_not_claim_a_clone_session_it_never_programmed"

# --- the route refill the package's pipeline must not receive (round 2, objection 1) ---------

m=$(mutant b26 "$TOPOMGR" \
    '            if install_routes:
                routes, attempted = self.install_initial_routes(only_dpid=dpid)' \
    '            if True:
                routes, attempted = self.install_initial_routes(only_dpid=dpid)')
report "M-B26: the refill runs anyway, putting NDTwin's routes in the exercise's own table" "$m" \
       "test_install_routes_false_attempts_not_one_write"

m=$(mutant b29 "$TOPOMGR" \
    '        if attempted == 0 and install_routes:' \
    '        if attempted == 0:')
report "M-B29: a fabric with no watchdog is promised the watchdog will install its routes" "$m" \
       "test_install_routes_false_does_not_claim_the_watchdog_will_fix_it"

m=$(mutant b30 "$TOPOMGR" \
    '    def readopt_switch(self, dpid, client_factory, sample_callback=None, settle_s=1.0,
                       install_routes=True):' \
    '    def readopt_switch(self, dpid, client_factory, sample_callback=None, settle_s=1.0,
                       install_routes=False):')
report "M-B30: the default flips, so the whole P4 plane silently stops refilling its routes" "$m" \
       "test_the_default_is_the_behaviour_every_caller_had_before_the_parameter"

m=$(mutant b31 "$MAIN" \
    '    result["routes"] = "skipped"' \
    '    pass')
report "M-B31: a deliberate zero is reported as a bare zero, which reads as a refusal" "$m" \
       "test_it_says_the_routes_were_skipped_rather_than_reporting_a_bare_zero"

m=$(mutant b32 "$MAIN" \
    '    result = topology.readopt_switch(dpid, client_factory,
                                     sample_callback if cooperative else None,
                                     install_routes=ndtwin)' \
    '    try:
        result = topology.readopt_switch(dpid, client_factory,
                                         sample_callback if cooperative else None,
                                         install_routes=ndtwin)
    except Exception as exc:  # noqa: BLE001
        return {"status": "failed", "step": "routes", "dpid": dpid, "error": str(exc)}')
report "M-B32: round 1's swallow comes back, so a real fault is dressed as a route failure" "$m" \
       "test_an_exception_from_readopt_is_not_swallowed"

m=$(mutant b33 "$MAIN" \
    '            return hashlib.sha256(fh.read()).hexdigest()[:16]' \
    '            return hashlib.sha256(fh.read()).hexdigest()[:8]')
report "M-B33: the program identifier is half as wide as every reader of it expects" "$m" \
       "test_a_real_file_gets_sixteen_lowercase_hex_characters"

m=$(mutant b34 "$MAIN" \
    '    p4info_path, _json_path = package.pipeline_for(dpid, base_dir)
    ndtwin = _pipeline_is_ndtwin(package, dpid, base_dir)' \
    '    p4info_path, _json_path = app_package.baseline().pipeline_for(dpid, base_dir)
    ndtwin = _pipeline_is_ndtwin(package, dpid, base_dir)')
report "M-B34: every switch is reported running NDTwin's artefacts, whatever it was given" "$m" \
       "test_the_fingerprint_is_a_digest_because_the_file_is_really_there"

m=$(mutant b36 "$MAIN" \
    '    except OSError:
        return None' \
    '    except OSError:
        return ""')
report "M-B36: an unreadable p4info gets an identifier, so two of them are the same program" "$m" \
       "test_a_missing_file_is_none_rather_than_an_invented_identifier"

m=$(mutant b38 "$MAIN" \
    '            return hashlib.sha256(fh.read()).hexdigest()[:16]' \
    '            fh.read()
            return hashlib.sha256(b"").hexdigest()[:16]')
report "M-B38: the fingerprint ignores the file, so every program has the same one" "$m" \
       "test_two_different_programs_do_not_share_a_fingerprint"

m=$(mutant b39 "$MAIN" \
    '        election_id=package.election_id,' \
    '        election_id=app_package.BASELINE_ELECTION_ID,')
report "M-B39: the factory drops the package's bid, so every write goes out as the old (0, 1)" "$m" \
       "test_the_client_the_factory_built_took_its_identity_from_the_package"

m=$(mutant b37 "$MAIN" \
    'FOREIGN_PIPELINE_FABRIC_SKIPS = (SKIP_LLDP, SKIP_WATCHDOG, SKIP_ROUTES)' \
    'FOREIGN_PIPELINE_FABRIC_SKIPS = (SKIP_CLONE, SKIP_LLDP, SKIP_WATCHDOG, SKIP_ROUTES)')
report "M-B37: the two scopes overlap again, so a per-switch skip is told about the fabric" "$m" \
       "test_the_two_scopes_do_not_overlap"

m=$(mutant b35 "$CLIENT" \
    '        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        self._bid(req)
        update = req.updates.add()
        update.type = TABLE_ENTRY_OPS[op]' \
    '        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        update = req.updates.add()
        update.type = TABLE_ENTRY_OPS[op]')
report "M-B35: a table entry carries no election id, so the switch answers PERMISSION_DENIED" "$m" \
       "test_an_insert_is_an_insert_addressed_to_this_device_with_this_election_id"

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
    '    op = data.get("op", "insert")
    spec = {key: data.get(key) for key in' \
    '    op = data.get("op") if "op" in data else "insert"
    spec = {key: data.get(key) for key in')
control "N3 (control): the same default written the long way" "$m" "the whole suite stays green"

echo
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPOMGR" | cut -d' ' -f1)" == "$BASE_TOPOMGR" ]] || { echo "🔴 baseline CHANGED -- topology_manager.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)" == "$BASE_TEST_ROUTE" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_route.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)" == "$BASE_TEST_STARTUP" ]] || { echo "🔴 baseline CHANGED -- test_startup.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)" == "$BASE_TEST_READOPT" ]] || { echo "🔴 baseline CHANGED -- test_readopt.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)" == "$BASE_TEST_PROXY" ]] || { echo "🔴 baseline CHANGED -- test_app_package_proxy.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_FOREIGN" | cut -d' ' -f1)" == "$BASE_TEST_FOREIGN" ]] || { echo "🔴 baseline CHANGED -- test_foreign_pipeline.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (4 sources, 6 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
