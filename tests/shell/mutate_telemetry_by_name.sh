#!/usr/bin/env bash
#
# Mutation gate for TICKET-P3 2.1 and 2.6, the proxy half: the packet_in metadata ids resolved BY
# NAME (G1), the telemetry source (none / cooperative / link / auto), the PRE entries a package
# declares (G8, G9a), the counter route (G7), and the disclosure on GET /p4/switch_state.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS GATE EXISTS AT ALL. Every defect in the code it covers is SILENT, and every one of
# them produces a twin full of zeroes -- which is also what an idle fabric produces, what a
# broken fabric produces, and what a fabric nobody sent traffic through produces.
#
#   * ids read positionally from a program that declares them in another order: a sample decodes
#     into a perfectly valid SampledPacket with ingress_port and egress_port exchanged, and the
#     kernel credits every byte to the reverse edge. Nothing raises, both values are real ports;
#   * a clone session programmed on a switch whose samples come from the LINK emitter: the same
#     packet is counted twice into one edge's byte total and every rate reads exactly double.
#     That is the 2026-08-16 clone-stacking shape, which took a veth reconciliation harness to
#     catch the last time;
#   * `cooperative` accepted for a pipeline with no controller header: the fabric comes up, the
#     PRE accepts the clone session (it is a target object, so bmv2 takes it against any
#     program), the agent registers, and zero samples arrive for the whole run;
#   * a multicast replica written without its `instance`: two replicas to one port collapse into
#     one inside the PRE, so a four-port group becomes a one-port group and three hosts stop
#     receiving, with no error anywhere;
#   * a PRE entry the switch refused counted as applied: `pre_entries.failed == 0` becomes a
#     sentence about nothing;
#   * `link_emitter.alive` hardcoded true: a manifest left behind by a bring-up that died says
#     the emitter is running just as confidently as one written a second ago.
#
# So each of them gets a mutation, and each mutation names the single test that must go red.
#
# 🔴 THE MUTANT IS A COPY, the same arrangement tests/shell/mutate_table_entry.sh uses and for
# its reason: nothing under p4_proxy/ is written, because another session may be executing those
# files right now. Every source and every test file is re-hashed at the end.
#
# The convert.py / preflight.py half of TICKET-P3 (the exercise's own cpu_port, the telemetry
# word, the PRE replica checks) is NOT here: it is appended to
# tests/shell/mutate_p4_exercise_tools.sh, which already owns those two files and runs their
# suite from the root that suite needs. Splitting on the file that is mutated rather than on the
# ticket keeps each gate's baseline check meaningful.
#
# Usage:  tests/shell/mutate_telemetry_by_name.sh
#         PROXY_PY=/path/to/python tests/shell/mutate_telemetry_by_name.sh
# Assumes: nothing about the cwd.
# Exit:    0 every mutation caught, 1 a mutation survived, 2 refused (no interpreter, or the
#          baseline was red), 3 a source file changed underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
EMITTER="$REPO/p4_proxy/proxy_agent/sflow_emitter.py"
TEST_BYNAME="$REPO/p4_proxy/tests/test_packet_in_by_name.py"
TEST_COUNTER="$REPO/p4_proxy/tests/test_counter_route.py"
TEST_MCAST="$REPO/p4_proxy/tests/test_multicast_group.py"
TEST_STARTUP="$REPO/p4_proxy/tests/test_startup.py"
TEST_STATE="$REPO/p4_proxy/tests/test_switch_state.py"
TEST_EMITTER="$REPO/p4_proxy/tests/test_sflow_emitter.py"
TEST_CLONE="$REPO/p4_proxy/tests/test_clone_session.py"

MODULES="tests.test_packet_in_by_name tests.test_counter_route tests.test_multicast_group \
tests.test_startup tests.test_switch_state tests.test_sflow_emitter tests.test_clone_session"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up -- asked of git
# rather than spelled as somebody's home directory. Override with PROXY_PY= .
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

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-telemetry-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
# Every mutant lives at $BK/<label>, so that directory IS the mutant's `p4_proxy` root and the
# repo root its tests derive is $BK. Four things are linked in as INPUTS, never subjects:
#   setting/   the topology models the emitter reads agent IPs out of (several MB, read-only)
#   tools/     ticket A's compiled exercise fixtures -- the only foreign p4info this repo has
#   tests/     the REAL sFlow capture fixtures (tests/fixtures/emitted_*.bin). test_sflow_emitter
#              resolves them from its own __file__ up three levels, so without this every
#              byte-comparison case ERRORs and the baseline is red for a reason that has nothing
#              to do with any mutation.
#   p4_proxy/  NOT the mutant: tools/p4_exercise/common.py derives the model reader's path from
#              its own __file__ with abspath, so through the tools link it looks for
#              $BK/p4_proxy/mininet. The mutants resolve everything from their own __file__.
ln -s "$REPO/setting" "$BK/setting"
ln -s "$REPO/tools" "$BK/tools"
ln -s "$REPO/tests" "$BK/tests"
ln -s "$REPO/p4_proxy" "$BK/p4_proxy"

BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_EMITTER=$(sha256sum "$EMITTER" | cut -d' ' -f1)
BASE_TEST_BYNAME=$(sha256sum "$TEST_BYNAME" | cut -d' ' -f1)
BASE_TEST_COUNTER=$(sha256sum "$TEST_COUNTER" | cut -d' ' -f1)
BASE_TEST_MCAST=$(sha256sum "$TEST_MCAST" | cut -d' ' -f1)
BASE_TEST_STARTUP=$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)
BASE_TEST_STATE=$(sha256sum "$TEST_STATE" | cut -d' ' -f1)
BASE_TEST_EMITTER=$(sha256sum "$TEST_EMITTER" | cut -d' ' -f1)
BASE_TEST_CLONE=$(sha256sum "$TEST_CLONE" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

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
    # returns 124, and unittest prints its `FAIL: <name>` section at the END -- so a mutant that
    # hangs the run produces no named failure and would be scored a survivor of nothing.
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 HUNG   %-74s (the suite never finished -- never a catch)\n' "$1"
        return
    fi
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-74s (%s went red)\n' "$1" "$3"
        # EVERY test that reddened, not only the one this mutation is named for: a gate that
        # records one name per mutation cannot answer "which of these tests has ever been seen
        # to fail" for any test that is not somebody's named killer.
        /usr/bin/grep -E '^(FAIL|ERROR): ' <<<"$out" \
            | sed -E 's/^(FAIL|ERROR): [^(]*\(([^)]*)\).*/             also red: \2/' \
            | sort -u
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-74s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

control() {  # $1 = label, $2 = mutant dir, $3 = what must stay green
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-74s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 RED   %-74s -- these suites are change detectors, not a specification\n' "$1"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -4 | sed 's/^/             /'
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

# --- G1: the ids come from the p4info, by name ------------------------------------------------

m=$(mutant c1 "$EMITTER" \
    '    found = _controller_metadata_by_name(p4info, PACKET_IN_HEADER)
    missing = [name for name in PACKET_IN_FIELDS if name not in found]' \
    '    found = {"reason": 1, "ingress_port": 2, "egress_port": 3, "frame_length": 4,
             "sampling_rate": 5}   # MUTANT: the constants, whatever program is loaded
    missing = [name for name in PACKET_IN_FIELDS if name not in found]')
report "M-C1: the ids are the constants again, so another program's samples decode swapped" "$m" \
       "test_a_reordered_header_gives_reordered_ids"

m=$(mutant c2 "$EMITTER" \
    '    if missing:
        raise TelemetryHeaderMissing(missing, sorted(found))' \
    '    if False:
        raise TelemetryHeaderMissing(missing, sorted(found))')
report "M-C2: a pipeline with no controller header resolves to something instead of raising" "$m" \
       "test_a_pipeline_with_no_controller_header_names_all_five"

m=$(mutant c11 "$EMITTER" \
    '        return {m.name: int(m.id) for m in entry.metadata}' \
    '        return {m.name: i + 1 for i, m in enumerate(entry.metadata)}')
report "M-C11: the id is the field POSITION rather than the number the compiler assigned" "$m" \
       "test_the_id_is_the_compilers_number_and_not_the_fields_position"

m=$(mutant c12 "$CLIENT" \
    '        egress_id = ids.get("egress_port")' \
    '        egress_id = 1  # MUTANT: the beacon always claims id 1')
report "M-C12: an LLDP beacon puts its egress port in whatever field is numbered 1" "$m" \
       "test_a_reordered_packet_out_header_is_followed"

# --- the telemetry source: the two paths must never both run ----------------------------------

m=$(mutant c3 "$MAIN" \
    '        if source != TELEMETRY_COOPERATIVE:' \
    '        if False:  # MUTANT: every switch gets the cooperative path')
report "M-C3: a clone session goes in under link telemetry, and every rate reads double" "$m" \
       "test_link_on_ndtwins_pipeline_programs_no_clone_and_registers_nothing"

m=$(mutant c4 "$MAIN" \
    '    for i, client in clients.items():
        source = telemetry_sources[i]
        if read_only:' \
    '    for i, client in clients.items():
        source = telemetry_sources[i]
        sflow.register_switch(i, agent_ips.get(i) or "0.0.0.0")  # MUTANT: register regardless
        if read_only:')
report "M-C4: a switch that samples nothing is registered with the emitter anyway" "$m" \
       "test_none_on_ndtwins_pipeline_samples_nothing_at_all"

m=$(mutant c5 "$MAIN" \
    '        if source == TELEMETRY_COOPERATIVE and getattr(client, "packet_in_ids", None) is None:' \
    '        if False:  # MUTANT: ask a program with no controller header to clone to the CPU')
report "M-C5: cooperative on a pipeline that cannot carry it is accepted, and reports zero" "$m" \
       "test_cooperative_on_a_foreign_pipeline_refuses_to_start"

m=$(mutant c13 "$MAIN" \
    '    knob = read_telemetry_knob(knob_path)
    if knob and knob != TELEMETRY_AUTO:
        return knob' \
    '    knob = read_telemetry_knob(knob_path)
    if False:
        return knob')
report "M-C13: the knob is read and ignored, so --telemetry changes nothing" "$m" \
       "test_the_knob_beats_the_package"

m=$(mutant c14 "$MAIN" \
    '            if line not in TELEMETRY_WORDS:
                raise TelemetryConfigError(' \
    '            if False:
                raise TelemetryConfigError(')
report "M-C14: a mistyped telemetry word is accepted and silently changes the conditions" "$m" \
       "test_a_word_outside_the_domain_is_refused_rather_than_defaulted"

# --- G7: the counter route ---------------------------------------------------------------------

m=$(mutant c6 "$ROUTES" \
    '    except CounterNotFound as err:
        raise HTTPException(
            status_code=404,' \
    '    except CounterNotFound as err:
        return {"dpid": dpid, "counter": name, "index": index, "bytes": 0, "packets": 0}
    except ZeroDivisionError:
        raise HTTPException(
            status_code=404,')
report "M-C6: a counter this pipeline does not have reads as a measurement of zero" "$m" \
       "test_a_counter_this_pipeline_does_not_have_is_404"

m=$(mutant c15 "$ROUTES" \
    '    if reading is None:
        raise HTTPException(
            status_code=503,' \
    '    if reading is None:
        reading = (0, 0)
    if False:
        raise HTTPException(
            status_code=503,')
report "M-C15: a failed read answers 200 with zeroes, which is the instrument's own finding" "$m" \
       "test_a_failed_read_is_503_rather_than_a_zero"

# --- G8 / G9a: the PRE ---------------------------------------------------------------------------

m=$(mutant c7 "$CLIENT" \
    '            for port, instance in wanted:
                replica = group.replicas.add()
                replica.egress_port = port
                replica.instance = instance' \
    '            for port, _instance in wanted:
                replica = group.replicas.add()
                replica.egress_port = port')
report "M-C7: a replica goes out with no instance, so two of them collapse into one" "$m" \
       "test_instance_defaults_to_one_rather_than_zero"

m=$(mutant c16 "$CLIENT" \
    '        duplicates = sorted({pair for pair in wanted if wanted.count(pair) > 1})' \
    '        duplicates = []  # MUTANT: the PRE will sort it out')
report "M-C16: a group declaring one replica twice is accepted and is quietly smaller" "$m" \
       "test_the_same_port_and_instance_twice_is_refused_and_names_the_pair"

m=$(mutant c8 "$MAIN" \
    '        if ok:
            out["multicast"]["applied"] += 1
        else:
            out["multicast"]["failed"] += 1' \
    '        if True:
            out["multicast"]["applied"] += 1
        else:
            out["multicast"]["failed"] += 1')
report "M-C8: a group the switch refused is counted as applied, so failed==0 says nothing" "$m" \
       "test_a_refused_group_is_counted_as_failed_not_applied"

m=$(mutant c17 "$MAIN" \
    '        pre = _blank_pre_counts()
        if i not in broken and not read_only:' \
    '        pre = _blank_pre_counts()
        if False:')
report "M-C17: a package's multicast group is never programmed, so its hosts never receive" "$m" \
       "test_a_declared_group_is_programmed_on_ndtwins_own_pipeline_too"

# 🔴 TWO EQUIVALENT MUTATIONS THIS REPLACED, both of which SURVIVED and both correctly.
# (a) `[dict(r) for r in (replicas or [])] or [{"egress_port": egress_port}]` drops the explicit
#     `"instance": 1`, and `spec.get("instance", 1)` below puts it straight back;
# (b) changing that `.get`'s default to 0 changes nothing either, because the only caller that
#     omits `instance` is a package's own replica list and the default path spells it out.
# The one observable difference is the value written on the default path, so that is where the
# mutation has to be made. The lesson is the gate's: "this line looks important" is not the
# same claim as "changing this line changes what goes on the wire".
m=$(mutant c18 "$CLIENT" \
    '        wanted = ([{"egress_port": egress_port, "instance": 1}] if replicas is None' \
    '        wanted = ([{"egress_port": egress_port, "instance": 0}] if replicas is None')
report "M-C18: the baseline clone session's replica changes instance, so a warm PRE stacks" "$m" \
       "test_no_replicas_argument_writes_one_replica_to_the_cpu_port"

# --- the disclosure -------------------------------------------------------------------------------

m=$(mutant c10 "$MAIN" \
    '    alive = False
    if isinstance(pid, int) and pid > 0:
        alive = os.path.exists(f"/proc/{pid}")' \
    '    alive = True  # MUTANT: the manifest exists, so the emitter must be running')
report "M-C10: a dead link emitter is reported alive, and link telemetry samples into nothing" "$m" \
       "test_a_dead_pid_reads_dead"

m=$(mutant c19 "$ROUTES" \
    '    if telemetry_report is not None:
        per_switch = telemetry_report()' \
    '    if False:
        per_switch = telemetry_report()')
report "M-C19: switch_state stops saying where each switch's samples come from" "$m" \
       "test_each_switch_carries_its_own_telemetry_object"

m=$(mutant c20 "$MAIN" \
    '        source = _telemetry_source(package, dpid)
        telemetry_sources[dpid] = source' \
    '        source = TELEMETRY_COOPERATIVE   # MUTANT: one answer for the whole fabric
        telemetry_sources[dpid] = source')
report "M-C20: every switch is reported cooperative whatever it was configured for" "$m" \
       "test_link_on_ndtwins_pipeline_programs_no_clone_and_registers_nothing"

# --- negative controls ------------------------------------------------------------------------

m=$(mutant n1 "$EMITTER" \
    '#: The name of the controller header the samples ride' \
    '# MUTANT: a comment, and nothing else.
#: The name of the controller header the samples ride')
control "N1 (control): a comment-only edit beside the by-name lookup" "$m" \
        "the whole suite stays green"

m=$(mutant n2 "$MAIN" \
    '    telemetry_sources = {}' \
    '    telemetry_sources = dict()')
control "N2 (control): the same empty dict written the long way" "$m" \
        "the whole suite stays green"

echo
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$EMITTER" | cut -d' ' -f1)" == "$BASE_EMITTER" ]] || { echo "🔴 baseline CHANGED -- sflow_emitter.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_BYNAME" | cut -d' ' -f1)" == "$BASE_TEST_BYNAME" ]] || { echo "🔴 baseline CHANGED -- test_packet_in_by_name.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_COUNTER" | cut -d' ' -f1)" == "$BASE_TEST_COUNTER" ]] || { echo "🔴 baseline CHANGED -- test_counter_route.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_MCAST" | cut -d' ' -f1)" == "$BASE_TEST_MCAST" ]] || { echo "🔴 baseline CHANGED -- test_multicast_group.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)" == "$BASE_TEST_STARTUP" ]] || { echo "🔴 baseline CHANGED -- test_startup.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STATE" | cut -d' ' -f1)" == "$BASE_TEST_STATE" ]] || { echo "🔴 baseline CHANGED -- test_switch_state.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_EMITTER" | cut -d' ' -f1)" == "$BASE_TEST_EMITTER" ]] || { echo "🔴 baseline CHANGED -- test_sflow_emitter.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_CLONE" | cut -d' ' -f1)" == "$BASE_TEST_CLONE" ]] || { echo "🔴 baseline CHANGED -- test_clone_session.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (4 sources, 7 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
