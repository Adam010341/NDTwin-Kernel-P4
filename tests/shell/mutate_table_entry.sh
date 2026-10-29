#!/usr/bin/env bash
#
# Mutation gate for the generic table-entry writer (G5) and what a FOREIGN pipeline changes:
# `P4RuntimeClient.encode_value` / `build_table_entry` / `write_table_entry`,
# `POST /p4/table_entry`, and the startup / readopt branches that apply a package's own entries
# and stop doing the things a tutorials pipeline cannot support.
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
# part. Before the G4 reader merged, this header said that mutating `_pipeline_is_ndtwin`'s BASE
# DIRECTORY would be equivalent, "because under phase-1 app_package.py every package's
# `pipeline_for` returns the fabric-wide pair". A's G4 reader landed, per-switch pipelines are
# real, and `pipeline_for` now returns paths INSIDE the package directory -- so that mutation is
# no longer equivalent, and M-B34 is it: `pipeline_report_for` reading the fabric-wide pair
# instead of the per-switch one. It is killed by the only test that can tell them apart, which
# is the one holding a package whose four switches run two different programs.
#
# The lesson is the gate's, not the change's: an "equivalent mutation" claim is a claim about
# the tree, and it expires when the tree changes. M-B18 caught this class of rot once already
# by SURVIVING after its anchor moved out from under it.
#
# 🔴 THE TERNARY WRITER (Cut A) MOVED THE SUBJECT. `encode_value`, the exception types and every
# shape rule (arity, encoding, value & ~mask, low <= high, the second spelling of don't-care, an
# omitted exact field, lpm host bits, the priority) now live in proxy_agent/match_shape.py, which
# the pre-flight runs as well. So the anchors M-B1, M-B5, M-B16, M-B40 and M-B41 point at that
# file, M-B6 and M-B25 are REVERSED (the claim they guarded -- "a ternary or range match is
# refused with 501" -- is gone; what replaces it is "a ternary or range match is built as what
# the p4info says it is", and the 501 that is left is UNSPECIFIED, guarded by M-J21), and the
# M-S / M-J7 / M-J8 / M-J9 / M-J21 / M-J24 block before the controls is the new shape rules, one
# or two mutations per rule. The table-entry journal's mutations are in mutate_table_journal.sh
# (Cut B and C). M-B7 stays; M-B14 and M-B20, which guarded "nothing claims an entry survives a
# proxy restart", were retired by Cut C, the change that replays the journal (see where they were).
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
# [Co-developed with claude code -- Adam] The shape rules, shared with tools/p4_exercise/preflight.py.
SHAPE="$REPO/p4_proxy/proxy_agent/match_shape.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
# `readopt_switch` grew `install_routes`, which is the seam that keeps this proxy's
# shortest paths out of somebody else's `MyIngress.ipv4_lpm`. One mutation (M-B26) lives there.
TOPOMGR="$REPO/p4_proxy/proxy_agent/topology_manager.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
TEST_ROUTE="$REPO/p4_proxy/tests/test_table_entry_route.py"
TEST_STARTUP="$REPO/p4_proxy/tests/test_startup.py"
TEST_READOPT="$REPO/p4_proxy/tests/test_readopt.py"
TEST_PROXY="$REPO/p4_proxy/tests/test_app_package_proxy.py"
# The suites that meet a pipeline NDTwin did not compile: the exercise tools' compiled fixtures,
# converter and runtime files. They are in their own file because mutate_app_package.sh
# runs its baseline in a tree that holds only p4_proxy/ -- see that file's own header.
TEST_FOREIGN="$REPO/p4_proxy/tests/test_foreign_pipeline.py"
# The live 13/13 found this writer refusing the one-element
# exact value the upstream exercises actually ship. That suite's subject is the REAL
# basic_tunnel runtime file, so it belongs to this gate's baseline.
TEST_EXACT="$REPO/p4_proxy/tests/test_exact_one_element_list.py"
# [Co-developed with claude code -- Adam] The 5-tuple key encoding pins (test_five_tuple_match)
# and the in_port refusal at the three write endpoints (test_in_port_value).
TEST_FIVE="$REPO/p4_proxy/tests/test_five_tuple_match.py"
TEST_INPORT="$REPO/p4_proxy/tests/test_in_port_value.py"
# [Co-developed with claude code -- Adam] The install-time record of an in_port rule (M-B42 turns
# its test red as well: the record is keyed on the mask the writer sends).
TEST_TIMES="$REPO/p4_proxy/tests/test_rule_install_times.py"

MODULES="tests.test_p4_client_writes tests.test_table_entry_route tests.test_startup \
tests.test_readopt tests.test_app_package_proxy tests.test_foreign_pipeline \
tests.test_exact_one_element_list tests.test_five_tuple_match tests.test_in_port_value tests.test_rule_install_times"

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
# The suites reach two things outside p4_proxy, and both are INPUTS, never subjects.
#   tools/    -- the compiled exercise fixtures (the only foreign p4info this repo has)
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
BASE_SHAPE=$(sha256sum "$SHAPE" | cut -d' ' -f1)
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_TOPOMGR=$(sha256sum "$TOPOMGR" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TEST_ROUTE=$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)
BASE_TEST_STARTUP=$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)
BASE_TEST_READOPT=$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)
BASE_TEST_PROXY=$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)
BASE_TEST_FOREIGN=$(sha256sum "$TEST_FOREIGN" | cut -d' ' -f1)
BASE_TEST_EXACT=$(sha256sum "$TEST_EXACT" | cut -d' ' -f1)
BASE_TEST_FIVE=$(sha256sum "$TEST_FIVE" | cut -d' ' -f1)
BASE_TEST_INPORT=$(sha256sum "$TEST_INPORT" | cut -d' ' -f1)
BASE_TEST_TIMES=$(sha256sum "$TEST_TIMES" | cut -d' ' -f1)

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
        printf '  🔴 HUNG   %-72s (the suite never finished -- never a catch) [%s]\n' "$1" "$(date +%T)"
        return
    fi
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-72s (%s went red) [%s]\n' "$1" "$3" "$(date +%T)"
        # 🔴 EVERY test that reddened, not only the one this mutation is named for.
        # [Co-developed with claude code -- Adam]
        # A gate that records one name per mutation cannot answer the question a maintainer
        # actually asks -- "which of these tests has ever been seen to fail?" -- for any test
        # that is not somebody's named killer. M-B24 reddens
        # test_the_default_action_row_every_runtime_file_carries_is_a_modify as well as its own
        # named case, and an earlier run's log said nothing about it, so that test read as unproven
        # when it was not. Printed, not counted: the verdict is still the named one.
        /usr/bin/grep -E '^(FAIL|ERROR): ' <<<"$out" \
            | sed -E 's/^(FAIL|ERROR): [^(]*\(([^)]*)\).*/             also red: \2/' \
            | sort -u
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-72s (%s stayed green -- that case proves nothing) [%s]\n' "$1" "$3" "$(date +%T)"
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

m=$(mutant b1 "$SHAPE" \
    '    if not table_has_priority_column(kinds):
        if value:' \
    '    if not table_has_priority_column(kinds):
        if False:')
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
    '                m.lpm.prefix_len = wire[2]' \
    '                m.lpm.prefix_len = 32')
report "M-B3: every lpm entry is a /32, so a subnet route blackholes all but one address" "$m" \
       "test_the_prefix_length_is_not_pinned_to_the_field_width"

m=$(mutant b4 "$CLIENT" \
    '        entry.is_default_action = default_action' \
    '        entry.is_default_action = False')
report "M-B4: a default action is written as an ordinary entry with no key" "$m" \
       "test_a_default_action_is_marked_as_one_and_carries_no_match"

m=$(mutant b5 "$SHAPE" \
    '    if value >= (1 << bitwidth):
        raise TableEntryInvalid(' \
    '    if False:
        raise TableEntryInvalid(')
report "M-B5: a value wider than its field is truncated rather than refused" "$m" \
       "test_a_value_wider_than_its_field_is_refused_rather_than_truncated"

# 🔴 M-B6 IS REVERSED (the ternary writer). It used to delete the 501 guard and be killed by
# "a ternary match is 501"; that test is gone because the claim is. The mutation that keeps the
# name now makes a ternary match go onto the wire as the wrong KIND of match -- an exact one --
# and is killed by the test that reads the kind back off the built entry.
m=$(mutant b6 "$SHAPE" \
    '        return ("TERNARY", value, mask)' \
    '        return ("EXACT", value)')
report "M-B6: a ternary match is built as an exact one, so a masked rule matches one address" "$m" \
       "test_a_ternary_field_is_built_with_its_value_and_mask"

# Both directions. The upstream exercises write an exact value
# as a one-element list (`"hdr.myTunnel.dst_id": [1]`) and the reference controller unwraps it
# (~/tutorials/utils/p4runtime_lib/convert.py:71-75). This writer refused it, and three of
# basic_tunnel/solution's six entries were missing on every switch in both live passes -- while
# `tools/p4_exercise/preflight.py` passed the same package. M-B40 is the refusal coming back;
# M-B41 is the over-correction, which is worse than the refusal was: `[value, prefix_len]` is
# the LPM shape, and taken on an EXACT field it installs a rule matching ONE address where the
# author wrote one matching a subnet -- forwarding, blackholing the rest, erroring nowhere.
m=$(mutant b40 "$SHAPE" \
    '        if isinstance(raw, (list, tuple)):
            if len(raw) != 1:
                raise TableEntryInvalid(
                    f"{where} is an EXACT match' \
    '        if isinstance(raw, (list, tuple)):
            if True:  # MUTANT: stricter than the reference implementation again
                raise TableEntryInvalid(
                    f"{where} is an EXACT match')
report "M-B40: the exercises' own one-element exact value is refused again" "$m" \
       "test_all_six_of_basic_tunnels_entries_go_on"

m=$(mutant b41 "$SHAPE" \
    '            if len(raw) != 1:
                raise TableEntryInvalid(
                    f"{where} is an EXACT match' \
    '            if len(raw) > 2:
                raise TableEntryInvalid(
                    f"{where} is an EXACT match')
report "M-B41: an lpm-shaped pair is taken on an EXACT field, so a subnet rule matches one host" "$m" \
       "test_a_two_element_pair_on_an_exact_field_is_still_refused"

# The 5-tuple writer's ternary mask. flow_5tuple's in_port key is bit<9>: a mask of 0xffff is two
# whole bytes and nine bits too wide, bmv2 answers UNKNOWN ("does not fit within 9 bits"), and
# every rule that names in_port is refused while the same rule without it installs. The recording
# stub takes any bytes, so only a test that computes the expected mask from the p4info fixture's
# bitwidth can tell. M-B42 puts the byte-wise mask back; M-B43 stops refusing a value of 512 and up.
# [Co-developed with claude code -- Adam]
m=$(mutant b42 "$CLIENT" \
    '        return raw, ((1 << bits) - 1).to_bytes(width, byteorder="big")' \
    '        return raw, b"\xff" * width')
report "M-B42: the 5-tuple mask is every bit of the field's bytes, so a bit<9> in_port gets 0xffff" "$m" \
       "test_in_port_is_masked_with_nine_ones_not_sixteen"

m=$(mutant b43 "$CLIENT" \
    '        if int.from_bytes(raw, "big") >> bits:' \
    '        if False:')
report "M-B43: a 5-tuple value wider than its field goes to the switch to be refused" "$m" \
       "test_an_in_port_wider_than_nine_bits_is_refused_before_the_wire"

# [Co-developed with claude code -- Adam]
# M-B44: the mask of a key whose width IS a whole number of bytes. M-B42 only moves bit<9>; a
# table entry that is off by one bit on protocol (7, not 8) leaves the byte-wise mutant green.
m=$(mutant b44 "$CLIENT" \
    '"hdr.ipv4.protocol": 8,' \
    '"hdr.ipv4.protocol": 7,')
report "M-B44: the 5-tuple protocol key is seven bits wide, so its mask is 0x7f" "$m" \
       "test_every_key_is_masked_with_exactly_its_own_bits"

# [Co-developed with claude code -- Adam]
# M-B45 / M-B46: the in_port refusal at the endpoints. The writer refuses 512 and up with an
# OverflowError raised while the request is built, which no handler catches -- a 500 -- unless
# check_match_values has run the encoder first. M-B45 skips that check; M-B46 lets the encoder's
# OverflowError through it.
m=$(mutant b45 "$TOPOMGR" \
    '_check_in_port_value(field, match_dict[field], action)' \
    'pass')
report "M-B45: an in_port that does not fit nine bits is not checked before the writer" "$m" \
       "test_every_write_verb_answers_400_for_an_in_port_that_does_not_fit_nine_bits"

m=$(mutant b46 "$TOPOMGR" \
    '    except (ValueError, OverflowError, TypeError, OSError):
        raise MalformedMatchValueError(
            field, value, action,' \
    '    except (ValueError, TypeError, OSError):
        raise MalformedMatchValueError(
            field, value, action,')
report "M-B46: the in_port check lets the encoder's OverflowError out, so 512 is a 500" "$m" \
       "test_the_switch_is_not_written_for_any_of_them"

m=$(mutant b16 "$SHAPE" \
    '                return bytes.fromhex("".join(groups))' \
    '                return bytes.fromhex("".join(reversed(groups)))')
report "M-B16: a MAC goes onto the wire byte-reversed, and bmv2 takes it" "$m" \
       "test_a_mac_string_is_six_raw_bytes_in_the_order_it_was_written"

# 🔴 M-B25 IS REVERSED. It widened the tuple to let a RANGE through and was killed by "a range
# field is unsupported". The tuple is the whole list of what the writer builds now, and the
# mutation that matters is the old one coming back: RANGE and OPTIONAL and TERNARY dropped from
# it, so the writer answers 501 for a match type it has a branch for.
m=$(mutant b25 "$SHAPE" \
    'BUILDABLE_MATCH_TYPES = ("EXACT", "LPM", "TERNARY", "RANGE", "OPTIONAL")' \
    'BUILDABLE_MATCH_TYPES = ("EXACT", "LPM")')
report "M-B25: the writer is back to exact and lpm, so a range match is a 501 again" "$m" \
       "test_a_range_field_is_built_with_its_low_and_high"

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
       "test_every_switch_reports_what_was_written_and_whether_it_is_journaled"

# M-B14 and M-B20 are retired here (Cut C): the journal is replayed, so a recorded entry DOES survive a
# restart and `journaled: true` is the truth this gate's suites cannot tell apart from the mutants. What
# they guarded -- no claim for a record that was lost -- is M-B14b and M-B20b in mutate_table_journal.sh,
# killed there by a journal that cannot be written. [Co-developed with claude code -- Adam]

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

# 🔴 M-B9 IS RETIRED, AND THE REASON IS THE INTERESTING PART.
# It mutated `if i in foreign:` in the telemetry loop to `if False:` and was killed by
# `test_a_foreign_pipeline_gets_no_clone_session_and_no_sflow_registration`. A later change put a
# telemetry-source check a few lines below it, and under `auto` a foreign pipeline resolves to
# `link` -- so with the foreign branch deleted that check skipped the same switch and the
# mutation changed nothing observable. It SURVIVED in an earlier run for exactly that reason, and
# the fix was not to delete the guard: a further change then made the branch conditional
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
    '        if i in foreign:  # MUTANT: the first version, before the header rule')
report "M-B9b: a foreign program that includes the header is left without a clone session" "$m" \
       "test_a_foreign_program_that_included_the_header_gets_the_cooperative_path"

m=$(mutant b10 "$MAIN" \
    '        skipped.extend(FOREIGN_PIPELINE_FABRIC_SKIPS)' \
    '        skipped.extend([SKIP_LLDP])')
report "M-B10: LLDP, the watchdog and the routes are switched off, two without being named" "$m" \
       "test_a_foreign_pipeline_names_every_fabric_wide_step_it_switched_off"

# A later change moved the expression this anchored on into `switch_skips_for`,
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

# The telemetry note sits inside this branch, so the anchor is the condition
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

# A later change merged readopt's two "no clone session was programmed" paths into
# one guarded block (the foreign-with-header case now KEEPS its session), so the two lines this
# anchored on are no longer adjacent. Same mutation: report the session `readopt_switch` claims
# rather than the one this switch was given.
m=$(mutant b27 "$MAIN" \
    '    if result.get("status") == "success" and not cooperative:' \
    '    if False:')
report "M-B27: readopt reports a clone session on a switch that was given none" "$m" \
       "test_it_does_not_claim_a_clone_session_it_never_programmed"

# --- the route refill the package's pipeline must not receive ---------

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

# --- the ternary writer's shape rules (Cut A), one mutation per rule --------------------------
#
# [Co-developed with claude code -- Adam]
# Every rule in proxy_agent/match_shape.py repeats a refusal bmv2 makes itself, which is exactly
# why it is easy to lose: take the check away and the request still gets refused, one hop later,
# as a 502 UNKNOWN, and nothing in a happy-path suite notices. Each mutation below deletes or
# bends ONE rule and names the single test that has to notice. M-J7, M-J8, M-J9, M-J21 and
# M-J24 carry the numbers DESIGN.md 6.3 gave them (a letter after a number is that mutation's
# variant); the rest are M-S<rule>, "S" for shape, so they cannot be mistaken for the journal's
# M-J1..M-J6 and M-J10..M-J29, which belong to a later cut.
#
# V7 (the owner check) is not here: it has its own gate, tests/shell/mutate_table_entry_owner.sh.

# V1: arity, one per type that has a shape of its own.
m=$(mutant j1a "$SHAPE" \
    '        if not isinstance(raw, (list, tuple)) or len(raw) != 2:
            raise TableEntryInvalid(
                f"{where} is a TERNARY match' \
    '        if False:
            raise TableEntryInvalid(
                f"{where} is a TERNARY match')
report "M-S1a: a ternary field is not held to [value, mask], so a bare value reaches the encoder" "$m" \
       "test_a_ternary_field_wants_exactly_value_and_mask"

m=$(mutant j1b "$SHAPE" \
    '        if not isinstance(raw, (list, tuple)) or len(raw) != 2:
            raise TableEntryInvalid(
                f"{where} is a RANGE match' \
    '        if False:
            raise TableEntryInvalid(
                f"{where} is a RANGE match')
report "M-S1b: a range field is not held to [low, high]" "$m" \
       "test_a_range_field_wants_exactly_low_and_high"

m=$(mutant j1c "$SHAPE" \
    '        if len(raw) != 1:
            raise TableEntryInvalid(
                f"{where} is an OPTIONAL match' \
    '        if False:
            raise TableEntryInvalid(
                f"{where} is an OPTIONAL match')
report "M-S1c: an optional field given two elements takes the first and drops the second" "$m" \
       "test_an_optional_field_given_two_elements_is_refused"

# V2: the three new types encode through the field's own width.
m=$(mutant j2a "$SHAPE" \
    '        mask = _encode_in_field(where, raw[1], bitwidth)' \
    '        mask = _encode_in_field(where, raw[1] & 0xff if isinstance(raw[1], int) else raw[1], bitwidth)')
report "M-S2a: a ternary mask too wide for its field (0x1ff) is truncated to 0xff and accepted" "$m" \
       "test_a_ternary_value_or_mask_that_does_not_fit_is_refused"

m=$(mutant j2e "$SHAPE" \
    '        value = _encode_in_field(where, raw[0], bitwidth)' \
    '        value = _encode_in_field(where, raw[0] & 0xff if isinstance(raw[0], int) else raw[0], bitwidth)')
report "M-S2e: a ternary value too wide for its field is truncated instead of refused" "$m" \
       "test_a_ternary_value_or_mask_that_does_not_fit_is_refused"

m=$(mutant j2f "$SHAPE" \
    '        low = _encode_in_field(where, raw[0], bitwidth)' \
    '        low = _encode_in_field(where, raw[0] & 0xffff if isinstance(raw[0], int) else raw[0], bitwidth)')
report "M-S2f: a range low bound too wide for its field is truncated instead of refused" "$m" \
       "test_a_range_bound_that_does_not_fit_is_refused"

m=$(mutant j2b "$SHAPE" \
    '        high = _encode_in_field(where, raw[1], bitwidth)' \
    '        high = _encode_in_field(where, raw[1] & 0xffff if isinstance(raw[1], int) else raw[1], bitwidth)')
report "M-S2b: a range bound too wide for its field is truncated instead of refused" "$m" \
       "test_a_range_bound_that_does_not_fit_is_refused"

m=$(mutant j2c "$SHAPE" \
    '    return ("OPTIONAL", _encode_in_field(where, raw, bitwidth))' \
    '    return ("OPTIONAL", _encode_in_field(where, raw & 0xffff if isinstance(raw, int) else raw, bitwidth))')
report "M-S2c: an optional value too wide for its field is truncated instead of refused" "$m" \
       "test_an_optional_value_that_does_not_fit_is_refused"

m=$(mutant j2d "$SHAPE" \
    '    if _as_int(raw) >= (1 << int(bitwidth)):
        raise TableEntryInvalid(
            f"{where}: {value!r} does not fit' \
    '    if False:
        raise TableEntryInvalid(
            f"{where}: {value!r} does not fit')
report "M-S2d: bytes with a bit above the field width are taken because their LENGTH fits" "$m" \
       "test_a_mask_with_a_bit_above_the_field_width_is_refused"

# V3 (M-J7)
m=$(mutant j7 "$SHAPE" \
    '        if _as_int(value) & ~_as_int(mask):' \
    '        if False:')
report "M-J7: a ternary value with a bit outside its mask goes on the wire" "$m" \
       "test_a_ternary_value_with_a_bit_outside_its_mask_is_refused"

m=$(mutant j7b "$SHAPE" \
    '        if _as_int(value) & ~_as_int(mask):' \
    '        if _as_int(mask) & ~_as_int(value):')
report "M-J7b: the containment test is the wrong way round, so a legal partial mask is refused" "$m" \
       "test_a_value_inside_its_mask_is_accepted_and_not_rewritten"

# V4
m=$(mutant j4 "$SHAPE" \
    '        if _as_int(low) > _as_int(high):' \
    '        if False:')
report "M-S4a: a range with low above high goes on the wire" "$m" \
       "test_a_range_with_low_above_high_is_refused"

m=$(mutant j4b "$SHAPE" \
    '        if _as_int(low) > _as_int(high):' \
    '        if _as_int(low) >= _as_int(high):')
report "M-S4b: a one-value range [7, 7] is refused as if it were inverted" "$m" \
       "test_a_single_point_range_and_an_ordinary_range_are_accepted"

# V5: each spelling of don't-care has its own mutation.
m=$(mutant j5a "$SHAPE" \
    '        if _as_int(mask) == 0:' \
    '        if False:')
report "M-S5a: a zero ternary mask is built, a second spelling of the field being omitted" "$m" \
       "test_a_ternary_mask_of_zero_is_refused_saying_to_omit_the_field"

m=$(mutant j5b "$SHAPE" \
    '        if _as_int(low) == 0 and _as_int(high) == (1 << int(bitwidth)) - 1:' \
    '        if False:')
report "M-S5b: the whole range is built, a second spelling of the field being omitted" "$m" \
       "test_the_whole_range_is_refused_saying_to_omit_the_field"

m=$(mutant j5b2 "$SHAPE" \
    '        if _as_int(low) == 0 and _as_int(high) == (1 << int(bitwidth)) - 1:' \
    '        if _as_int(low) == 0 and _as_int(high) >= (1 << int(bitwidth)) - 2:')
report "M-S5b2: a range one short of the whole is refused as if it were the whole" "$m" \
       "test_a_range_one_short_of_the_whole_is_accepted"

m=$(mutant j5c "$SHAPE" \
    '    if prefix_len == 0:' \
    '    if False:')
report "M-S5c: an lpm /0 is built, a second spelling of the field being omitted" "$m" \
       "test_an_lpm_prefix_of_zero_is_refused_saying_to_omit_the_field"

# V6: the priority.
m=$(mutant j6a "$SHAPE" \
    '    if not 1 <= value <= PRIORITY_MAX:' \
    '    if value > PRIORITY_MAX:')
report "M-S6a: a table with a priority column takes an entry with none, as priority 0" "$m" \
       "test_an_empty_match_with_no_priority_is_refused_on_a_table_that_has_a_priority_column"

m=$(mutant j6b "$SHAPE" \
    '    if not 1 <= value <= PRIORITY_MAX:' \
    '    if not 1 <= value:')
report "M-S6b: a priority above int32 is passed to the protobuf, which raises a ValueError (a 500)" "$m" \
       "test_the_largest_int32_priority_is_accepted_and_one_past_it_is_not"

m=$(mutant j8 "$SHAPE" \
    '    if is_default:
        if value:' \
    '    if False:
        if value:')
report "M-J8: a default entry may carry a priority, which the switch then refuses" "$m" \
       "test_a_default_entry_with_a_priority_is_refused"

m=$(mutant j8b "$CLIENT" \
    'spec.get("priority"), is_default=default_action)' \
    'spec.get("priority"), is_default=False)')
report "M-J8b: the builder never tells the priority rule that the entry is a default" "$m" \
       "test_a_default_entry_with_a_priority_is_refused"

m=$(mutant j6c "$SHAPE" \
    'PRIORITY_MATCH_TYPES = ("TERNARY", "RANGE", "OPTIONAL")' \
    'PRIORITY_MATCH_TYPES = ("TERNARY", "RANGE")')
report "M-S6c: an OPTIONAL field is not counted as giving a table a priority column" "$m" \
       "test_a_table_has_a_priority_column_iff_it_has_a_ternary_range_or_optional_field"

# DESIGN 10-1: table_honours_priority goes back to "any field the writer cannot build". With the
# tuple grown to five, that is nothing, so every table answers False.
m=$(mutant j6d "$CLIENT" \
    '        return match_shape.table_has_priority_column(
            self._match_type_name(f) for f in table.match_fields)' \
    '        return any(self._match_type_name(f) not in BUILDABLE_MATCH_TYPES
                   for f in table.match_fields)')
report "M-S6d: table_honours_priority is back to its old definition and answers False for every table" "$m" \
       "test_a_table_has_a_priority_column_iff_it_has_a_ternary_range_or_optional_field"

m=$(mutant j6e "$CLIENT" \
    '        if priority:
            entry.priority = priority' \
    '        if False:
            entry.priority = priority')
report "M-S6e: the validated priority is never put on the entry" "$m" \
       "test_a_ternary_field_is_built_with_its_value_and_mask"

m=$(mutant j6f "$CLIENT" \
    '            "priority": entry.priority,' \
    '            "priority": 0,')
report "M-S6f: write_table_entry reports priority 0 whatever went on the wire" "$m" \
       "test_a_ternary_entry_goes_on_the_wire_with_its_mask_and_its_priority"

m=$(mutant j6g "$ROUTES" \
    '            "priority": written["priority"],' \
    '            "priority": 0,')
report "M-S6g: the 200 body reports priority 0 whatever went on the wire" "$m" \
       "test_a_ternary_entry_is_accepted_and_the_response_says_which_priority_went_out"

# V8
m=$(mutant j9a "$SHAPE" \
    '        if missing:
            raise TableEntryInvalid(
                f"{table_name}: {missing} is an EXACT field' \
    '        if False:
            raise TableEntryInvalid(
                f"{table_name}: {missing} is an EXACT field')
report "M-S8a: an exact field left out of an entry goes on the wire" "$m" \
       "test_an_exact_field_left_out_is_refused"

m=$(mutant j9b "$SHAPE" \
    '    if not is_default:
        missing = ' \
    '    if True:
        missing = ')
report "M-S8b: a default entry is held to the exact-field rule, though it names no field at all" "$m" \
       "test_a_default_entry_names_no_exact_field_and_that_is_fine"

# V9
m=$(mutant j9c "$SHAPE" \
    '    if host_bits > 0 and _as_int(value_bytes) & ((1 << host_bits) - 1):' \
    '    if False:')
report "M-S9: an lpm value with host bits goes on the wire" "$m" \
       "test_an_lpm_value_with_host_bits_is_refused_on_insert_and_on_delete"

# [Co-developed with claude code -- Adam] Tests that no mutation above reddened: the lpm field
# that may be left out, the lpm host route, and the type of the priority.
m=$(mutant j8c "$SHAPE" \
    '                   if kind == "EXACT" and name not in shaped]' \
    '                   if kind in ("EXACT", "LPM") and name not in shaped]')
report "M-S8c: an lpm field left out of an entry is refused like an exact one" "$m" \
       "test_leaving_the_lpm_field_out_is_the_way_to_say_any_address"

m=$(mutant j5d "$SHAPE" \
    '    if prefix_len == 0:' \
    '    if prefix_len in (0, int(bitwidth)):')
report "M-S5d: an lpm host route (/32) is refused as if it were a catch-all" "$m" \
       "test_a_network_address_and_a_host_route_are_both_accepted"

m=$(mutant j6h "$SHAPE" \
    '    if priority is not None and (isinstance(priority, bool) or not isinstance(priority, int)):' \
    '    if False:')
report "M-S6h: a priority that is not an integer reaches the comparison (a TypeError, a 500)" "$m" \
       "test_a_priority_that_is_not_an_integer_is_refused"

# The read side (M-J9 is the design's: an optional match is not read back).
m=$(mutant j10 "$CLIENT" \
    '            elif m.HasField("optional"):' \
    '            elif False:')
report "M-J9: an optional match is dropped on the way back, so its entry reads as a catch-all" "$m" \
       "test_an_optional_match_is_read_back_as_optional"

m=$(mutant j10b "$CLIENT" \
    '            elif m.HasField("ternary"):' \
    '            elif False:')
report "M-J9b: a ternary match is dropped on the way back" "$m" \
       "test_the_shape_of_a_built_entry_is_the_shape_that_is_read_back"

m=$(mutant j10c "$CLIENT" \
    '            elif m.HasField("range"):' \
    '            elif False:')
report "M-J9c: a range match is dropped on the way back" "$m" \
       "test_a_range_match_is_read_back_with_its_bounds"

m=$(mutant j10d "$CLIENT" \
    '        return self._match_as_dict(entry.table_id, entry.match)' \
    '        return {k: v for k, v in self._match_as_dict(entry.table_id, entry.match).items()
                if v["type"] in ("exact", "lpm")}')
report "M-J9d: the write side records only exact and lpm fields, so a ternary rule is unfindable" "$m" \
       "test_the_shape_of_a_built_entry_is_the_shape_that_is_read_back"

# The 501 that is left (M-J21).
m=$(mutant j21 "$SHAPE" \
    '    if kind not in BUILDABLE_MATCH_TYPES:' \
    '    if False:')
report "M-J21: a field of an unbuildable match type is shaped as an optional one" "$m" \
       "test_a_match_type_no_writer_can_build_is_unsupported_and_says_which_it_is"

# E1 (M-J24): the switch's own reason in the 502.
m=$(mutant j24 "$ROUTES" \
    '        p4rt = _p4rt_error(err)' \
    '        p4rt = None')
report "M-J24: the 502 does not unpack the per-update error, so NOT_FOUND reads as UNKNOWN" "$m" \
       "test_the_502_carries_the_switchs_own_reason_from_the_per_update_error"

m=$(mutant j24b "$ROUTES" \
    '                if not detail.Unpack(error) or error.canonical_code == 0:' \
    '                if not detail.Unpack(error):')
report "M-J24b: an OK entry in the batch is reported as the switch's refusal" "$m" \
       "test_the_first_update_that_was_not_ok_is_the_one_reported"

m=$(mutant j24c "$ROUTES" \
    '    except Exception:  # noqa: BLE001 -- see above
        return None' \
    '    except KeyError:
        return None')
report "M-J24c: a malformed trailer turns the 502 into a 500" "$m" \
       "test_a_502_with_no_trailer_or_a_broken_one_is_still_a_502_without_the_extra_key"

# --- negative controls -----------------------------------------------------------------------
#
# A gate that reddens on anything is not a gate. These are edits that change no behaviour these
# suites specify, and each must leave the suite GREEN -- which `report` would score as a
# SURVIVOR, so they are run separately and the survivor count is not touched.

control() {  # $1 = label, $2 = mutant dir, $3 = what must stay green
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-72s (%s) [%s]\n' "$1" "$3" "$(date +%T)"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 RED   %-72s -- these suites are change detectors, not a specification [%s]\n' "$1" "$(date +%T)"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -4 | sed 's/^/             /'
    fi
}

m=$(mutant n1 "$CLIENT" \
    '#: `op` as a caller spells it -> the P4Runtime Update type.' \
    '# MUTANT: a comment, and nothing else.
#: `op` as a caller spells it -> the P4Runtime Update type.')
control "N1 (control): a comment-only edit beside the writer" "$m" "the whole suite stays green"

m=$(mutant n4 "$SHAPE" \
    '    if kind not in BUILDABLE_MATCH_TYPES:' \
    '    # MUTANT: a comment, and nothing else.
    if kind not in BUILDABLE_MATCH_TYPES:')
control "N4 (control): a comment-only edit beside the 501 guard in match_shape" "$m" \
        "the whole suite stays green"

m=$(mutant n5 "$ROUTES" \
    '        p4rt = _p4rt_error(err)' \
    '        # MUTANT: a comment, and nothing else.
        p4rt = _p4rt_error(err)')
control "N5 (control): a comment-only edit beside the 502 body" "$m" "the whole suite stays green"

m=$(mutant n2 "$MAIN" \
    '    entry_errors = {}
    for i, client in clients.items():' \
    '    entry_errors = {}
    # MUTANT: a comment, and nothing else.
    for i, client in clients.items():')
control "N2 (control): a comment-only edit inside the entry-applying loop" "$m" \
        "the whole suite stays green"

m=$(mutant n3 "$ROUTES" \
    '    op = str(data.get("op", "insert") or "insert").strip().lower()
    spec = {key: data.get(key) for key in' \
    '    op = str((data.get("op") if "op" in data else "insert") or "insert").strip().lower()
    spec = {key: data.get(key) for key in')
control "N3 (control): the same default written the long way" "$m" "the whole suite stays green"

echo
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$SHAPE" | cut -d' ' -f1)" == "$BASE_SHAPE" ]] || { echo "🔴 baseline CHANGED -- match_shape.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPOMGR" | cut -d' ' -f1)" == "$BASE_TOPOMGR" ]] || { echo "🔴 baseline CHANGED -- topology_manager.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)" == "$BASE_TEST_ROUTE" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_route.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)" == "$BASE_TEST_STARTUP" ]] || { echo "🔴 baseline CHANGED -- test_startup.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)" == "$BASE_TEST_READOPT" ]] || { echo "🔴 baseline CHANGED -- test_readopt.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)" == "$BASE_TEST_PROXY" ]] || { echo "🔴 baseline CHANGED -- test_app_package_proxy.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_FOREIGN" | cut -d' ' -f1)" == "$BASE_TEST_FOREIGN" ]] || { echo "🔴 baseline CHANGED -- test_foreign_pipeline.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_EXACT" | cut -d' ' -f1)" == "$BASE_TEST_EXACT" ]] || { echo "🔴 baseline CHANGED -- test_exact_one_element_list.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_FIVE" | cut -d' ' -f1)" == "$BASE_TEST_FIVE" ]] || { echo "🔴 baseline CHANGED -- test_five_tuple_match.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_INPORT" | cut -d' ' -f1)" == "$BASE_TEST_INPORT" ]] || { echo "🔴 baseline CHANGED -- test_in_port_value.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_TIMES" | cut -d' ' -f1)" == "$BASE_TEST_TIMES" ]] || { echo "🔴 baseline CHANGED -- test_rule_install_times.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (5 sources, 10 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
