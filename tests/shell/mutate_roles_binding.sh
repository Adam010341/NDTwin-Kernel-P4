#!/usr/bin/env bash
#
# Mutation gate for TICKET-P4-roles (phase 4, first cut): the roles manifest, the route binding,
# the declared links, the external link-state entry, the flow-stats read-back and the
# capabilities disclosure -- the proxy half (p4_proxy/) and the package-tool half
# (tools/p4_exercise/) in ONE gate, because several of these behaviours are a single function
# with two callers (route_binding.resolve runs in pre-flight and in the proxy) and a gate that
# split them would test each caller against a copy of the other.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 EVERY NEW TEST HAS TO HAVE BEEN SEEN RED (TICKET-P4-roles section 0-6). Each mutation names
# the one test that must go red, and the gate also records EVERY test each mutation reddened.
# At the end the tests this ticket added (NEW_CLASSES below, enumerated by the unittest loader
# from the unmutated copy, not typed out) are compared against everything that ever went red,
# and a test that no mutation reddened FAILS THE GATE by name. A test nobody has seen fail is a
# decoration; this is the list that would otherwise have to be trusted.
#
# 🔴 M-R1 MUST BE KILLED ONLY BY THE RENAMED FIXTURE (section 3.3). tutorials' basic spells
# NDTwin's five names character for character, so a binding that ignores the roles and falls
# back to the literals is indistinguishable from a correct one on basic. The gate therefore
# checks more than "its killer went red": every test that went red under M-R1 must carry
# "renamed" in its id -- the tests that run on fixtures/renamed_route are named for it -- and a
# single red test that does not would mean a basic-only test could tell the two apart, which
# would make the renamed fixture a formality.
#
# 🔴 THE MUTANT IS A COPY. p4_proxy/{proxy_agent,tests,mininet,p4_src} and
# tools/p4_exercise/ are copied under a temp dir laid out like the repo, and both suites run
# there; nothing in the checkout is written (every source is re-hashed at the end). `setting/`
# is linked. The tools suite runs with HOME pointed at an empty directory: its
# FixtureProvenance test compares the fixtures with ~/tutorials, which is a working copy other
# sessions rebuild (on 2026-09-24 ~/tutorials/exercises/p4runtime/build/advanced_tunnel.json was
# recompiled with absolute paths and that test went red at the base), and a gate whose baseline
# depends on somebody else's build tree reports on that tree, not on this ticket. The test then
# skips, loudly, as it is written to.
#
# ROUND 2 (TICKET-P4-roles section 7 ruling 5) added: the mutations for items 1-8; the
# 07_roles_basic.sh --self-test mutations (item 6), run on a copy of the script, each named for
# the self-test case that must go red; and a check that NEW_CLASSES -- a typed list -- names
# every TestCase class that exists now and did not exist at the ticket's base 6291db35, so a
# class this ticket added cannot be left out of the "every new test seen red" check by omission.
#
# Usage:  tests/shell/mutate_roles_binding.sh
#         PROXY_PY=/path/to/python tests/shell/mutate_roles_binding.sh
# Exit:   0 every mutation caught, every control green, every new test seen red;
#         1 otherwise; 2 refused (no interpreter, or the baseline was red); 3 a source changed
#         underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BINDING="$REPO/p4_proxy/proxy_agent/route_binding.py"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
TOPOMGR="$REPO/p4_proxy/proxy_agent/topology_manager.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
STATS="$REPO/p4_proxy/proxy_agent/ryu_flow_stats.py"
PKG="$REPO/p4_proxy/mininet/app_package.py"
CONVERT="$REPO/tools/p4_exercise/convert.py"
PREFLIGHT="$REPO/tools/p4_exercise/preflight.py"
COMMON="$REPO/tools/p4_exercise/common.py"
LIVE_DIR_REL="doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1"
LIVE07="$REPO/$LIVE_DIR_REL/07_roles_basic.sh"
FLOWROUTE_TEST="$REPO/p4_proxy/tests/test_flow_stats_route.py"
SOURCES=("$BINDING" "$CLIENT" "$MAIN" "$TOPOMGR" "$ROUTES" "$STATS" "$PKG" "$CONVERT"
         "$PREFLIGHT" "$COMMON")
# One per line: check_gate_anchors.py reads a continuation line that starts with a path and has
# four words as a mutation call.
SOURCES+=("$LIVE07")
SOURCES+=("$REPO/$LIVE_DIR_REL/_common.sh")
#: The ticket's base: NEW_CLASSES must name every TestCase class added since.
TICKET_BASE=6291db35

MODULES="tests.test_route_binding tests.test_declared_links tests.test_link_state_entry \
tests.test_p4_client_writes tests.test_ryu_flow_stats tests.test_flow_stats_route \
tests.test_switch_state tests.test_app_package tests.test_readopt tests.test_startup"

#: The test classes this ticket added: every test in them must be seen red by some mutation.
#: <module>:<Class>, or <module>:* for a module that is wholly this ticket's.
NEW_CLASSES="tests.test_route_binding:* tests.test_declared_links:* \
tests.test_link_state_entry:* \
tests.test_p4_client_writes:TheNdtwinPipelinesWritesAreByteIdenticalToTheBaseTest \
tests.test_p4_client_writes:ARenamedBindingIsWhatGoesOnTheWireTest \
tests.test_p4_client_writes:NoBindingNoWriteTest \
tests.test_ryu_flow_stats:TheNdtwinPipelinesFlowStatsAreByteIdenticalToTheBaseTest \
tests.test_ryu_flow_stats:ARenamedBindingIsReadBackThroughItsOwnNamesTest \
tests.test_ryu_flow_stats:OnAForeignPipelineAnUnknownActionIsLeftOutAndCountedTest \
tests.test_flow_stats_route:AForeignSwitchIsRenderedThroughItsBindingTest \
tests.test_switch_state:CapabilitiesShapeTest tests.test_switch_state:CapabilitiesFromStartupTest \
tests.test_switch_state:CapabilitiesOnTheEndpointTest tests.test_switch_state:TheUnrenderedCountTest \
tests.test_switch_state:TheDeclaredLinksReportOnTheEndpointTest \
tests.test_flow_stats_route:TheNdtwinClientsHttpBodyIsByteIdenticalToTheBaseTest \
tests.test_readopt:ReadoptOnAFabricThatSkipsItsRoutesTest tests.test_readopt:OnlyTheAttachedHostsTest \
tests.test_app_package:APackageWithoutRolesLoadsByteIdenticallyTest \
tests.test_app_package:RolesShapeTest \
tests.test_readopt:ReadoptOnAFabricWhoseRouteTablesNdtwinOwnsTest \
test_convert:WithoutTheRoleFlagTheOutputIsByteIdenticalTest test_convert:TheRoleFlagTest \
test_convert:ConvertingWithTheRoleFlagTest test_preflight:BasicWithRolesTest \
test_preflight:RenamedRolesTest test_preflight:TheSuggestionTest \
test_preflight:NoSuggestionWhereNothingFitsTest test_preflight:NoSuggestionOnNdtwinsOwnPipelineTest \
test_preflight:ReverseControlsTest test_preflight:FirewallWithRolesTest"

# The interpreter: a worktree has no venv of its own, so the main worktree is consulted, asked of
# git rather than spelled as somebody's home directory. Override with PROXY_PY= .
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc; from p4.config.v1 import p4info_pb2' \
        >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no interpreter with fastapi/networkx/grpc/p4runtime. Set PROXY_PY=." >&2
    exit 2
}
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-roles-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
ln -s "$REPO/setting" "$BK/setting"
RED_LOG="$BK/ever_red.txt"
: > "$RED_LOG"

declare -A BASE_SHA
for f in "${SOURCES[@]}"; do BASE_SHA["$f"]=$(sha256sum "$f" | cut -d' ' -f1); done

SURVIVORS=0
MUTATIONS=0

lay_out() {   # $1 = a directory to become a repo-shaped copy
    local d="$1"
    mkdir -p "$d/p4_proxy/p4_src" "$d/tools" "$d/home" "$d/tmp"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" \
          "$d/p4_proxy/"
    # The two .p4 sources as well as the compiled build: tools/p4_exercise/tests/
    # test_telemetry_include.py reads ndtwin_switch.p4 and compiles ndtwin_telemetry.p4.
    cp "$REPO/p4_proxy/p4_src/"*.p4 "$d/p4_proxy/p4_src/"
    cp -r "$REPO/p4_proxy/p4_src/build" "$d/p4_proxy/p4_src/" 2>/dev/null
    cp -r "$REPO/tools/p4_exercise" "$d/tools/"
    ln -s "$REPO/setting" "$d/setting"
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
}

# Both suites, one combined transcript. PYTHONDONTWRITEBYTECODE so a mutant can never be run
# from a .pyc of its unmutated self (same-size mutants written in one second is exactly the trap
# mutate_ryu_rest_topology_bounded.sh documents). rc is 124 if either run timed out.
run_against() {
    local d="$1" rc1 rc2
    ( cd "$d/p4_proxy" && HOME="$d/home" TMPDIR="$d/tmp" PYTHONPATH="$d/p4_proxy" \
        PYTHONDONTWRITEBYTECODE=1 timeout 300 "$PY" -m unittest $MODULES -v 2>&1 )
    rc1=$?
    ( cd "$d" && HOME="$d/home" TMPDIR="$d/tmp" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests -v 2>&1 )
    rc2=$?
    if [[ $rc1 -eq 124 || $rc2 -eq 124 ]]; then return 124; fi
    [[ $rc1 -eq 0 && $rc2 -eq 0 ]]
}

red_ids() {   # the ids of every FAIL/ERROR in a transcript, one per line
    sed -n -E 's/^(FAIL|ERROR): [^ ]+ \(([^)]*)\).*/\2/p' | sort -u
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test that must go red, [$4 = only]
    local out rc reds
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 HUNG   %-66s (a suite never finished -- never a catch)\n' "$1"
        rm -rf "$2"; return
    fi
    reds=$(red_ids <<<"$out")
    printf '%s\n' "$reds" >> "$RED_LOG"
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-66s (%s went red)\n' "$1" "$3"
        if [[ "${4:-}" == "renamed-only" ]]; then
            local stray
            stray=$(/usr/bin/grep -iv 'renamed' <<<"$reds" | /usr/bin/grep -v '^$')
            if [[ -n "$stray" ]]; then
                SURVIVORS=$((SURVIVORS+1))
                printf '  🔴 NOT RENAMED-ONLY: these went red too, and none uses renamed_route:\n'
                sed 's/^/             /' <<<"$stray"
            else
                printf '             renamed-only: every one of the %s red test(s) is a renamed_route test\n' \
                    "$(/usr/bin/grep -c . <<<"$reds")"
            fi
        fi
        sed 's/^/             also red: /' <<<"$reds" | /usr/bin/grep -v "also red: .*$3" \
            | /usr/bin/grep -v 'also red: $'
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
    rm -rf "$2"
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate (it learns
# which argument is the anchor and which the file from this `local` line). The anchor must occur
# exactly once, so a mutation cannot quietly land somewhere other than where it says.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    lay_out "$d"
    python3 - "$d/${file#"$REPO/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; lay_out "$base"
if ! base_out=$(run_against "$base"); then
    /usr/bin/grep -E '^(Ran |OK|FAILED|FAIL:|ERROR:)' <<<"$base_out" | head -20
    echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"
    exit 2
fi
/usr/bin/grep -E '^(Ran |OK)' <<<"$base_out" | sed 's/^/  /'

# The new tests, enumerated from the unmutated copy by the loader itself.
NEW_IDS="$BK/new_ids.txt"
( cd "$base/p4_proxy" && PYTHONPATH="$base/p4_proxy:$base/tools/p4_exercise/tests" \
    HOME="$base/home" TMPDIR="$base/tmp" PYTHONDONTWRITEBYTECODE=1 \
    "$PY" - $NEW_CLASSES > "$NEW_IDS.raw" <<'PY'
import importlib, sys, unittest
sys.path.insert(0, ".")
loader = unittest.TestLoader()
for spec in sys.argv[1:]:
    module_name, cls = spec.split(":")
    module = importlib.import_module(module_name)
    classes = ([getattr(module, n) for n in dir(module)
                if isinstance(getattr(module, n), type)
                and issubclass(getattr(module, n), unittest.TestCase)
                and getattr(module, n).__module__ == module.__name__]
               if cls == "*" else [getattr(module, cls)])
    for c in classes:
        for name in loader.getTestCaseNames(c):
            print(f"ID {module_name}.{c.__name__}.{name}")
PY
) || { echo "REFUSE: could not enumerate the new tests"; exit 2; }
# Only the id lines: importing a module under test prints (main.py announces its package),
# and a print line counted as a test would be a "test" no mutation can ever redden.
sed -n 's/^ID //p' "$NEW_IDS.raw" > "$NEW_IDS"
echo "  new tests to be seen red: $(wc -l < "$NEW_IDS")"
# 🔴 NEW_CLASSES IS TYPED; THIS IS WHAT KEEPS IT HONEST (round 2, the judge's finding 9). Every
# TestCase class in the modules this gate runs that is not in the base's version of its file must
# be in NEW_CLASSES -- read by `git show <base>:<file>`, not remembered.
missing=$("$PY" - "$REPO" "$TICKET_BASE" "$NEW_CLASSES" <<'PY'
import ast, glob, os, subprocess, sys
repo, base, listed = sys.argv[1], sys.argv[2], sys.argv[3].split()
wild = {s.split(":")[0] for s in listed if s.endswith(":*")}
named = {tuple(s.split(":")) for s in listed if not s.endswith(":*")}
def classes(src):
    """Top-level classes that define a test method of their own."""
    return {n.name for n in ast.parse(src).body if isinstance(n, ast.ClassDef)
            and any(isinstance(f, ast.FunctionDef) and f.name.startswith("test")
                    for f in n.body)}
files = ([("tests." + os.path.basename(p)[:-3], os.path.relpath(p, repo))
          for p in sorted(glob.glob(f"{repo}/p4_proxy/tests/test_*.py"))]
         + [(os.path.basename(p)[:-3], os.path.relpath(p, repo))
            for p in sorted(glob.glob(f"{repo}/tools/p4_exercise/tests/test_*.py"))])
for module, rel in files:
    now = classes(open(f"{repo}/{rel}").read())
    shown = subprocess.run(["git", "-C", repo, "show", f"{base}:{rel}"], capture_output=True,
                           text=True)
    then = classes(shown.stdout) if shown.returncode == 0 else set()
    for cls in sorted(now - then):
        if module not in wild and (module, cls) not in named:
            print(f"{module}:{cls}")
PY
) || { echo "REFUSE: could not compare the test classes with $TICKET_BASE"; exit 2; }
if [[ -n "$missing" ]]; then
    echo "  🔴 NEW_CLASSES omits class(es) added since $TICKET_BASE -- their tests would never be"
    echo "     required to go red:"
    sed 's/^/       /' <<<"$missing"
    SURVIVORS=$((SURVIVORS+1))
else
    echo "  NEW_CLASSES names every TestCase class added since $TICKET_BASE"
fi
rm -rf "$base"
echo

# --- the ticket's fifteen (section 3.3) ----------------------------------------------------------

m=$(mutant r1 "$BINDING" \
    '    return RouteBinding(table=table.preamble.name, match_field=field.name,
                        action=action.preamble.name, dst_mac_param=dst_mac.name,
                        port_param=port.name, owner=owner, source=SOURCE_PACKAGE,' \
    '    return RouteBinding(table=BASELINE.table, match_field=BASELINE.match_field,
                        action=BASELINE.action, dst_mac_param=BASELINE.dst_mac_param,
                        port_param=BASELINE.port_param, owner=owner, source=SOURCE_PACKAGE,')
report "M-R1: the binding ignores the roles and falls back to the literals" "$m" \
       "test_the_renamed_role_resolves_to_the_renamed_names" renamed-only

m=$(mutant r2 "$CLIENT" \
    '        if binding is None:
            raise RouteWriteUnsupported(route_binding_module.REASON_UNBOUND, self.device_id, what)' \
    '        if binding is None:
            return route_binding_module.BASELINE')
report "M-R2: an unbound foreign switch is written with the literals, not refused 501" "$m" \
       "test_unbound_on_basics_own_names_is_still_refused"

m=$(mutant r3 "$CLIENT" \
    '        if binding.owner != route_binding_module.OWNER_NDTWIN:' \
    '        if False:')
report "M-R3: a table the package owns is written anyway" "$m" \
       "test_a_package_owned_table_is_read_by_ndtwin_and_never_written"

m=$(mutant r4 "$PREFLIGHT" \
    '    if owned:
        report.bad("owned table has no package entries",' \
    '    if False:
        report.bad("owned table has no package entries",')
report "M-R4: pre-flight lets the package keep match entries in a table NDTwin owns" "$m" \
       "test_the_owned_tables_match_entries_fail_and_each_one_is_named"

m=$(mutant r5 "$BINDING" \
    '        elif int(dst_mac.bitwidth) != DST_MAC_BITWIDTH:' \
    '        elif False:')
report "M-R5: the MAC parameter's width is not checked (pre-flight passes a 9-bit MAC)" "$m" \
       "test_a_dst_mac_that_is_not_48_bits_fails_here_before_the_proxy_refuses"

m=$(mutant r5b "$PREFLIGHT" \
    '            binding = route_binding.resolve(role.as_manifest(), p4info,
                                            max_port=_roles_max_port(model, dpid),' \
    '            binding = route_binding.resolve(role.as_manifest(), p4info,
                                            max_port=None,')
report "M-R5b: pre-flight does not size the port against the topology" "$m" \
       "test_a_port_too_narrow_for_the_topology_fails_here"

m=$(mutant r6 "$MAIN" \
    '        seeded, seed_error = _seed_declared_links(topo, package)' \
    '        seeded, seed_error = 0, None')
report "M-R6: a foreign fabric's declared links are never seeded" "$m" \
       "test_a_foreign_fabric_seeds_its_declared_links"

m=$(mutant r6b "$TOPOMGR" \
    '            self.add_link(src, dst, src_port, dst_port)
            with self._liveness_lock:' \
    '            with self._liveness_lock:')
report "M-R6b: seeding records the links but never enters them into net" "$m" \
       "test_all_eight_directions_are_served_to_the_kernels_topology_poll"

m=$(mutant r7 "$TOPOMGR" \
    '            self.add_link(src, dst, src_port, dst_port)
            with self._liveness_lock:' \
    '            self.add_link(src, dst, src_port, dst_port)
            self._notify_link((src, src_port, dst, dst_port), False)
            with self._liveness_lock:')
report "M-R7: seeding sends link_recovery_detected to the kernel" "$m" \
       "test_the_kernel_is_told_nothing_by_a_declaration"

m=$(mutant r8 "$MAIN" \
    '        routes_owned = routes_owned_by_ndtwin(clients, foreign)' \
    '        routes_owned = False')
report "M-R8: every table owned by ndtwin and the routes are still skipped" "$m" \
       "test_every_foreign_switch_owned_by_ndtwin_brings_the_routes_back"

m=$(mutant r9 "$MAIN" \
    '        if binding is None or binding.owner != route_binding.OWNER_NDTWIN:
            return False' \
    '        if False:
            return False')
report "M-R9: one unbound switch and the routes are installed anyway" "$m" \
       "test_one_unbound_switch_keeps_the_routes_skipped_for_the_whole_fabric"

m=$(mutant r10 "$MAIN" \
    '        read_only = True
        # 🔴 TICKET-P4-roles 2.3-1/2' \
    '        read_only = False
        # 🔴 TICKET-P4-roles 2.3-1/2')
report "M-R10: a foreign fabric starts LLDP and the watchdog" "$m" \
       "test_lldp_and_the_watchdog_stay_off_on_a_foreign_fabric_even_when_every_table_is_owned"

# Round 2 (section 7 ruling 5, item 3): the killer is the renamed fixture's OWN rows. Round 1's
# killer used a tag row keyed `hdr.ipv4.protocol`, a shape the fixture never produces. On the
# fixture's real rows an unknown action cannot be rendered as a drop at all -- proto_tags matches
# `hdr.ip4.proto`, which no vocabulary translates -- so what this mutation (the base's foreign
# path: everything through entry_to_ryu, nothing counted) takes away there is the COUNT; M-R11b
# below takes away the omission alone, on a row whose match does translate.
m=$(mutant r11 "$STATS" \
    '        counts = foreign and not entry.get("is_default")' \
    '        counts = False')
report "M-R11: a foreign switch is rendered as the base did -- unknown rows as drops, none counted" "$m" \
       "test_the_renamed_fixtures_own_rows_list_its_four_routes_and_count_its_tag_row"

m=$(mutant r11b "$STATS" \
    '        if counts and not recognises_action(entry.get("action"), forwarding_actions):' \
    '        if False:')
report "M-R11b: an unknown action whose match translates is listed as a drop again" "$m" \
       "test_an_unknown_action_on_an_unbound_foreign_switch_is_not_listed_either"

m=$(mutant r12 "$MAIN" \
    '        "reroute": bool(fabric.get("lldp") and fabric.get("watchdog")),' \
    '        "reroute": True,')
report "M-R12: a foreign fabric says reroute: true" "$m" \
       "test_a_foreign_switch_whose_roles_ndtwin_owns"

m=$(mutant r13 "$BINDING" \
    '    action="MyIngress.ipv4_forward",' \
    '    action="MyIngress.ipv4_fwd",')
report "M-R13: one of BASELINE's five names is changed" "$m" \
       "test_the_baseline_binding_is_ndtwin_switchs_own_five_names"

m=$(mutant r14 "$TOPOMGR" \
    '        if not watchdog:
            print(f"[TopologyManager] external link report' \
    '        if not watchdog:
            self.install_initial_routes()
            print(f"[TopologyManager] external link report')
report "M-R14: an external report reroutes on a fabric with no watchdog" "$m" \
       "test_a_down_report_changes_no_route_and_tells_the_kernel_nothing"

m=$(mutant r15 "$CONVERT" \
    '        "bmv2": {"cpu_port": package_cpu_port(switches)},' \
    '        "bmv2": {"cpu_port": package_cpu_port(switches)},
        "roles": {},')
report "M-R15: convert without the flag writes a different package.json" "$m" \
       "test_every_file_of_every_conversion_is_the_one_the_base_wrote"

# --- every other new test, each seen red by a named mutation (section 0-6) ----------------------
#
# Beyond the ticket's fifteen: one mutation per behaviour a new test pins, so that no new test is
# a decoration. Grouped by file. Each is the plausible wrong version of that behaviour, not a
# syntax break.

# route_binding.resolve -- every rule of 2.1-4, one mutation each

m=$(mutant rb_table "$BINDING" \
    '        raise RouteBindingError(
            f"{where}.table: {role['"'"'table'"'"']!r} is not a table of this pipeline "' \
    '        return BASELINE
        raise RouteBindingError(
            f"{where}.table: {role['"'"'table'"'"']!r} is not a table of this pipeline "')
report "RB1: a table the pipeline lacks falls back to NDTwin's (the guess the contract forbids)" "$m" \
       "test_a_table_the_pipeline_does_not_have"

m=$(mutant rb_field "$BINDING" \
    '    if field is None:
        problems.append(' \
    '    if field is None and False:
        problems.append(')
report "RB2: a match field the table lacks is not reported" "$m" \
       "test_a_match_field_the_table_does_not_have"

m=$(mutant rb_lpm "$BINDING" \
    '        if kind != ROUTE_MATCH_TYPE:' \
    '        if False:')
report "RB3: a match type other than LPM is accepted" "$m" "test_a_match_that_is_not_lpm"

m=$(mutant rb_width32 "$BINDING" \
    '        if int(field.bitwidth) != ROUTE_MATCH_BITWIDTH:' \
    '        if False:')
report "RB4: a match that is not 32 bits is accepted" "$m" "test_a_match_that_is_not_32_bits"

m=$(mutant rb_action "$BINDING" \
    '        problems.append(f"{where}.action: {role['"'"'action'"'"']!r} is not an action of this pipeline")' \
    '        pass')
report "RB5: an action the pipeline lacks is not reported" "$m" \
       "test_an_action_the_pipeline_does_not_have"

m=$(mutant rb_refs "$BINDING" \
    '        if action.preamble.id not in refs:' \
    '        if False:')
report "RB6: an action the table does not list is accepted" "$m" \
       "test_an_action_the_table_does_not_list"

m=$(mutant rb_mac "$BINDING" \
    '        if dst_mac is None:
            problems.append(' \
    '        if False:
            problems.append(')
report "RB7: a missing dst_mac parameter is not reported" "$m" \
       "test_a_dst_mac_parameter_the_action_does_not_take"

m=$(mutant rb_port "$BINDING" \
    '        if port is None:
            problems.append(' \
    '        if False:
            problems.append(')
report "RB8: a missing port parameter is not reported" "$m" \
       "test_a_port_parameter_the_action_does_not_take"

m=$(mutant rb_narrow "$BINDING" \
    '        elif max_port is not None and bits_for_port(max_port) > int(port.bitwidth):' \
    '        elif False:')
report "RB9: a port too narrow for the topology is accepted" "$m" \
       "test_a_port_too_narrow_for_the_topologys_largest_port"

m=$(mutant rb_third "$BINDING" \
    '        if extra:' \
    '        if False:')
report "RB10: an action with a third parameter is accepted (it would be written as zero)" "$m" \
       "test_an_action_with_a_third_parameter"

m=$(mutant rb_owner "$BINDING" \
    '    if owner not in OWNERS:' \
    '    if False:')
report "RB11: resolve accepts an owner outside the two words" "$m" \
       "test_an_owner_outside_the_two_words"

m=$(mutant rb_first "$BINDING" \
    '        raise RouteBindingError("; ".join(problems))' \
    '        raise RouteBindingError(problems[0])')
report "RB12: only the first problem is reported" "$m" \
       "test_every_problem_is_reported_not_just_the_first"

m=$(mutant rb_source "$BINDING" \
    '                        port_param=port.name, owner=owner, source=SOURCE_PACKAGE,' \
    '                        port_param=port.name, owner=owner, source=SOURCE_BASELINE,')
report "RB13: a resolved binding claims to be the baseline" "$m" \
       "test_a_resolved_binding_says_where_it_came_from_and_who_owns_it"

m=$(mutant rb_ownerlost "$BINDING" \
    '                        port_param=port.name, owner=owner, source=SOURCE_PACKAGE,' \
    '                        port_param=port.name, owner=OWNER_NDTWIN, source=SOURCE_PACKAGE,')
report "RB14: owner package is resolved as owner ndtwin" "$m" \
       "test_an_owner_package_role_is_bound_but_owned_by_the_package"

m=$(mutant rb_width "$BINDING" \
    '                        port_bitwidth=int(port.bitwidth))' \
    '                        port_bitwidth=9)')
report "RB15: the port width is NDTwin's bit<9>, not the p4info's" "$m" \
       "test_the_renamed_port_width_comes_from_the_p4info"

m=$(mutant rb_basewidth "$BINDING" \
    '    port_bitwidth=9,
)' \
    '    port_bitwidth=16,
)')
report "RB16: BASELINE's port width is not bit<9>" "$m" \
       "test_the_baseline_is_ndtwin_owned_from_the_baseline_and_two_bytes_of_port"

# p4_client -- the class default, the literals, the order of the refusals, the 5-tuple

m=$(mutant pc_default "$CLIENT" \
    '    route_binding = route_binding_module.BASELINE

    def __init__(' \
    '    route_binding = None

    def __init__(')
report "PC1: a client nobody bound is unbound, so every pre-roles double stops writing" "$m" \
       "test_every_client_that_was_never_bound_writes_through_the_baseline"

m=$(mutant pc_literal "$CLIENT" \
    '        entry.table_id = self._get_table_id(binding.table)' \
    '        entry.table_id = self._get_table_id("MyIngress.ipv4_lpm")')
report "PC2: a route write spells the table again instead of reading the binding" "$m" \
       "test_no_route_write_spells_any_of_the_five_names"

m=$(mutant pc_iv4const "$CLIENT" \
    '    IPV4_LPM_TABLE = "MyIngress.ipv4_lpm"' \
    '    IPV4_LPM_TABLE = "ipv4_lpm"')
report "PC3: the disclosed exception stops being the baseline's own table name" "$m" \
       "test_the_one_disclosed_exception_is_the_baselines_own_table_name"

m=$(mutant pc_order "$CLIENT" \
    '        self._refuse_write("an ipv4_lpm route insert")
        binding = self._writable_route_binding("an ipv4_lpm route insert")' \
    '        binding = self._writable_route_binding("an ipv4_lpm route insert")
        self._refuse_write("an ipv4_lpm route insert")')
report "PC4: the binding is consulted before the external control plane's refusal" "$m" \
       "test_an_external_control_plane_refuses_before_the_binding_is_consulted"

m=$(mutant pc_5tuple "$CLIENT" \
    '        if binding is None or binding.source != route_binding_module.SOURCE_BASELINE:
            raise RouteWriteUnsupported(route_binding_module.REASON_NO_FIVE_TUPLE_ROLE,' \
    '        if False:
            raise RouteWriteUnsupported(route_binding_module.REASON_NO_FIVE_TUPLE_ROLE,')
report "PC5: a 5-tuple rule goes to a foreign switch" "$m" \
       "test_a_five_tuple_rule_on_any_foreign_binding_is_refused"

# main -- the factory, the startup loop, capabilities, the unrendered count, readopt

m=$(mutant mn_unbound "$MAIN" \
    '    if role is None:
        return None
    return route_binding.resolve(' \
    '    if role is None:
        return route_binding.BASELINE
    return route_binding.resolve(')
report "MN1: the factory binds a foreign switch without roles to NDTwin's names" "$m" \
       "test_a_foreign_pipeline_without_roles_is_unbound"

m=$(mutant mn_ndtwin "$MAIN" \
    '    if _pipeline_is_ndtwin(package, dpid, base_dir):
        return route_binding.BASELINE' \
    '    if _pipeline_is_ndtwin(package, dpid, base_dir):
        return None')
report "MN2: NDTwin's own pipeline is left unbound" "$m" \
       "test_ndtwins_own_pipeline_is_bound_to_the_baseline"

m=$(mutant mn_cache "$MAIN" \
    '    client.bind_routes(route_binding_for(package, dpid, client.p4info, base_dir))' \
    '    client.bind_routes(build_p4_client.__dict__.setdefault(
        dpid, route_binding_for(package, dpid, client.p4info, base_dir)))')
report "MN3: a switch's first binding is remembered, so readopt never re-resolves" "$m" \
       "test_a_second_build_of_the_same_switch_is_resolved_again_not_remembered"

m=$(mutant mn_readoptfactory "$MAIN" \
    'api_routes.inject_readopt(build_p4_client, sflow.handle_sample, readopt_switch)' \
    'api_routes.inject_readopt(P4RuntimeClient, sflow.handle_sample, readopt_switch)')
report "MN4: readopt builds its client with a factory that binds nothing" "$m" \
       "test_readopt_builds_its_client_through_the_same_factory"

m=$(mutant mn_swallow "$MAIN" \
    '            print(f"[Proxy Agent] REFUSING to start: {e}")
            raise' \
    '            print(f"[Proxy Agent] REFUSING to start: {e}")
            continue')
report "MN5: a role that does not fit becomes one missing switch instead of a refusal" "$m" \
       "test_the_startup_loop_does_not_swallow_the_refusal_as_a_down_switch"

m=$(mutant mn_lldpflag "$MAIN" \
    '            print("[Proxy Agent] Started LLDP Discovery...")
            _fabric["lldp"] = True' \
    '            print("[Proxy Agent] Started LLDP Discovery...")
            _fabric["lldp"] = False')
report "MN6: an all-NDTwin fabric reports it cannot reroute" "$m" \
       "test_an_all_ndtwin_fabric_reroutes"

m=$(mutant mn_fivetuple "$MAIN" \
    '        "five_tuple": bool(ndtwin and not external' \
    '        "five_tuple": bool(False and not external')
report "MN7: NDTwin's own pipeline reports no 5-tuple" "$m" \
       "test_an_ndtwin_switch_on_an_ndtwin_fabric_can_do_everything"

m=$(mutant mn_ownerword "$MAIN" \
    '        "ipv4_route": owner_word,' \
    '        "ipv4_route": "ndtwin" if owner_word != "unbound" else owner_word,')
report "MN8: a package-owned table is reported as ndtwin's" "$m" "test_a_package_owned_table"

m=$(mutant mn_inject "$MAIN" \
    'api_routes.inject_roles_reports(capabilities_report, flow_stats_report)' \
    'api_routes.inject_roles_reports(capabilities_report, None)')
report "MN9: the proxy never wires the flow-stats count to the endpoint" "$m" \
       "test_the_proxy_wires_both_reporters_at_import"

m=$(mutant mn_count "$MAIN" \
    '        if seen is not None:
            count = seen[0]' \
    '        if seen is not None:
            count = 0')
report "MN10: the count a foreign render left is reported as zero" "$m" \
       "test_a_foreign_switchs_count_is_its_last_renders"

m=$(mutant mn_nullcount "$MAIN" \
    '        else:
            count = None
        out[str(dpid)] = {"unrendered_entries": count}' \
    '        else:
            count = 0
        out[str(dpid)] = {"unrendered_entries": count}')
report "MN11: a switch nobody rendered reports zero left out" "$m" \
       "test_before_any_render_it_is_null_not_zero"

m=$(mutant mn_ndtwincount "$MAIN" \
    '            # as the empty list), so after its first table read nothing has been left out.
            count = 0' \
    '            # as the empty list), so after its first table read nothing has been left out.
            count = None')
report "MN12: NDTwin's own pipeline never says it left nothing out" "$m" \
       "test_ndtwins_own_pipeline_leaves_nothing_out_once_its_table_was_read"

m=$(mutant mn_readoptroutes "$MAIN" \
    '    if (_fabric_installs_routes() and binding is not None
            and binding.owner == route_binding.OWNER_NDTWIN):
        routes, attempted = topology.install_initial_routes(only_dpid=dpid)' \
    '    if False:
        routes, attempted = topology.install_initial_routes(only_dpid=dpid)')
report "MN13: a power-cycled owned switch comes back with its route table empty" "$m" \
       "test_the_routes_go_back_into_the_bound_table"

m=$(mutant mn_readoptcaps "$MAIN" \
    '        _capabilities[str(dpid)] = capabilities_for(owner, source, ndtwin, package.read_only,
                                                    _fabric)' \
    '        pass')
report "MN14: readopt leaves the old client's capabilities in place" "$m" \
       "test_its_capabilities_follow_the_new_clients_binding"

m=$(mutant mn_seedall "$MAIN" \
    '    elif read_only:
        # `external`: nothing discovers links and nothing seeds them -- unchanged by this cut.' \
    '    elif read_only:
        _seed_declared_links(topo, package)
        # `external`: nothing discovers links and nothing seeds them -- unchanged by this cut.')
report "MN15: an external fabric seeds declared links too" "$m" \
       "test_an_external_fabric_seeds_nothing_this_cut_leaves_it_as_it_was"

m=$(mutant mn_seedndtwin "$MAIN" \
    '    if routes_owned:
        route_counts = _install_owned_routes(topo)' \
    '    if routes_owned:
        route_counts = _install_owned_routes(topo)
    if not foreign:
        _seed_declared_links(topo, package)')
report "MN16: an all-NDTwin fabric seeds declared links beside LLDP" "$m" \
       "test_an_all_ndtwin_fabric_seeds_nothing_and_runs_lldp_as_before"

# topology_manager -- seeding, the declared-link report, the external entry

m=$(mutant tm_untyped "$TOPOMGR" \
    '            if not (self.net.nodes.get(src, {}).get("type") == "switch"' \
    '            if False and not (self.net.nodes.get(src, {}).get("type") == "switch"')
report "TM1: a cable to a switch that never connected is entered (an untyped node in net)" "$m" \
       "test_a_link_to_a_switch_that_never_connected_is_not_entered"

m=$(mutant tm_twice "$TOPOMGR" \
    '                    if direction not in self._declared_links:' \
    '                    if True:')
report "TM2: seeding twice counts every direction twice" "$m" \
       "test_seeding_twice_enters_each_direction_once"

m=$(mutant tm_evidence "$TOPOMGR" \
    '                        self._declared_links.add(direction)' \
    '                        self._declared_links.add(direction)
                        self._link_beacons.setdefault(direction, {
                            "at": self._clock(), "down": False, "acked": True, "seen": True})')
report "TM3: a declared link is entered as beacon evidence the watchdog then times out" "$m" \
       "test_the_beacon_evidence_the_watchdog_reads_is_untouched"

m=$(mutant tm_downfalse "$TOPOMGR" \
    '                    "source": "declared",
                    "last_beacon_age_s": None,
                    "down": None,' \
    '                    "source": "declared",
                    "last_beacon_age_s": None,
                    "down": False,')
report "TM4: a declared link claims it was checked and found up" "$m" \
       "test_every_declared_link_says_it_is_declared_and_that_nobody_checks_it"

m=$(mutant tm_reportkey "$TOPOMGR" \
    '            "external_link_reports": self.external_link_report(),' \
    '')
report "TM5: switch_state stops serving the external-report count" "$m" \
       "test_before_any_report_the_count_is_zero_and_present"

m=$(mutant tm_recorded "$TOPOMGR" \
    '                self._external_reports["recorded_only"] += 1' \
    '                pass')
report "TM6: a recorded-only report is not counted" "$m" \
       "test_it_is_counted_where_switch_state_serves_it"

m=$(mutant tm_always "$TOPOMGR" \
    '            watchdog = self._link_watchdog_running' \
    '            watchdog = True')
report "TM7: a foreign fabric's report is written as beacon evidence anyway" "$m" \
       "test_no_beacon_evidence_is_written_so_nothing_can_act_on_it_later"

m=$(mutant tm_notimeout "$TOPOMGR" \
    '                entry["at"] = now if up else now - self._link_timeout(entry) - 1.0' \
    '                entry["at"] = now')
report "TM8: a down report on a watched fabric is heard as a beacon, not a silence" "$m" \
       "test_a_down_report_is_reported_to_the_kernel_and_rerouted_on_the_next_pass"

m=$(mutant tm_routed "$TOPOMGR" \
    '                self._external_reports["routed_through_watchdog"] += 1' \
    '                pass')
report "TM9: a report routed through the watchdog is not counted" "$m" \
       "test_it_is_counted_as_routed_through_the_watchdog"

m=$(mutant tm_wired "$ROUTES" \
    '@router.post("/p4/readopt/{dpid}")' \
    '@router.post("/p4/external_link_state")
def external_link_state(body: dict):
    return topology.report_external_link_state(**body)


@router.post("/p4/readopt/{dpid}")')
report "TM10: an HTTP route wires the entry this cut must leave unwired" "$m" \
       "test_no_proxy_route_reaches_it"

# api_routes and ryu_flow_stats -- the endpoint keys, the render path, the vocabulary

m=$(mutant ar_uninjected "$ROUTES" \
    '    if capabilities_report is not None:
        caps = capabilities_report()' \
    '    if True:
        caps = capabilities_report() if capabilities_report is not None else {}')
report "AR1: an uninjected capabilities reporter still adds a key full of nulls" "$m" \
       "test_an_uninjected_reporter_adds_no_key"

m=$(mutant ar_flowkey "$ROUTES" \
    '            entry["flow_stats"] = rendered.get(str(dpid), {"unrendered_entries": None})' \
    '            pass')
report "AR2: switch_state never carries flow_stats" "$m" \
       "test_each_switch_carries_its_capabilities_and_its_flow_stats"

m=$(mutant ar_allforeign "$ROUTES" \
    '        if binding is None or binding.source != route_binding.SOURCE_BASELINE:
            body, unrendered = ryu_flow_stats.render_flow_stats_counted(' \
    '        if True:
            body, unrendered = ryu_flow_stats.render_flow_stats_counted(')
report "AR3: NDTwin's own pipeline is sent down the foreign render path" "$m" \
       "test_a_client_on_ndtwins_pipeline_takes_the_unchanged_path"

m=$(mutant ar_early "$ROUTES" \
    '            body, unrendered = ryu_flow_stats.render_flow_stats_counted(' \
    '            client.last_flow_render = (0, time.monotonic())
            body, unrendered = ryu_flow_stats.render_flow_stats_counted(')
report "AR4: a render is recorded before the read that may fail" "$m" \
       "test_a_failed_read_records_no_render"

m=$(mutant fs_vocab "$STATS" \
    '    if binding is None or binding.source == route_binding.SOURCE_BASELINE:
        return FIELD_TO_RYU, FORWARDING_ACTIONS' \
    '    if True:
        return FIELD_TO_RYU, FORWARDING_ACTIONS')
report "FS1: the renderer ignores a package binding's names" "$m" \
       "test_the_renamed_route_renders_as_its_destination_and_output_port"

m=$(mutant fs_drop "$STATS" \
    '    return name.rsplit(".", 1)[-1] in DROP_ACTION_NAMES' \
    '    return False')
report "FS2: a known drop on a foreign switch is left out as unknown" "$m" \
       "test_a_known_drop_is_still_a_drop_and_is_not_counted"

m=$(mutant fs_count "$STATS" \
    '        elif counts:
            # A known action on a match this module cannot translate: not listed, so counted.
            unrendered += 1' \
    '        elif False:
            unrendered += 1')
report "FS3: a foreign row with no usable match is left out and not counted (round 1's rule)" "$m" \
       "test_a_row_with_no_usable_match_is_counted_whatever_its_action"

m=$(mutant fs_countdefault "$STATS" \
    '        counts = foreign and not entry.get("is_default")' \
    '        counts = foreign')
report "FS3b: a default row is counted as left out" "$m" \
       "test_a_default_row_is_never_counted"

m=$(mutant fs_countndtwin "$STATS" \
    '        counts = foreign and not entry.get("is_default")' \
    '        counts = not entry.get("is_default")')
report "FS3c: NDTwin's own pipeline starts leaving rows out and counting them" "$m" \
       "test_ndtwins_own_pipeline_leaves_nothing_out"

m=$(mutant fs_literal "$STATS" \
    '    route_binding.BASELINE.action: route_binding.BASELINE.port_param,' \
    '    "MyIngress.ipv4_forward": "port",')
report "FS4: the renderer spells the route action again" "$m" \
       "test_no_module_spells_the_four_route_names_outside_baseline_and_the_named_exceptions"

m=$(mutant fs_nobase "$STATS" \
    '    route_binding.BASELINE.action: route_binding.BASELINE.port_param,' \
    '')
report "FS5: the renderer loses NDTwin's own route action" "$m" \
       "test_the_renderer_takes_the_route_action_from_the_baseline"

# app_package -- the loader's shape checks

m=$(mutant ap_required "$PKG" \
    '    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise AppPackageError(f"{where}: '"'"'roles'"'"' must be an object' \
    '    if raw is None:
        raise AppPackageError(f"{where}: '"'"'roles'"'"' is required")
    if not isinstance(raw, dict):
        raise AppPackageError(f"{where}: '"'"'roles'"'"' must be an object')
report "AP1: roles becomes required, so every package written before it stops loading" "$m" \
       "test_every_case_was_captured"

m=$(mutant ap_empty "$PKG" \
    '    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise AppPackageError(f"{where}: '"'"'roles'"'"' must be an object' \
    '    if raw is None:
        return Roles()
    if not isinstance(raw, dict):
        raise AppPackageError(f"{where}: '"'"'roles'"'"' must be an object')
report "AP2: a package without roles gets an empty Roles, not None" "$m" \
       "test_a_package_without_roles_has_none_not_an_empty_object"

m=$(mutant ap_object "$PKG" \
    '    if not isinstance(raw, dict):
        raise AppPackageError(f"{where}: '"'"'roles'"'"' must be an object' \
    '    if False:
        raise AppPackageError(f"{where}: '"'"'roles'"'"' must be an object')
report "AP3: roles that is not an object is not refused" "$m" \
       "test_roles_that_is_not_an_object_is_refused"

m=$(mutant ap_unknown "$PKG" \
    '    unknown = sorted(set(raw) - set(ROLE_NAMES))' \
    '    unknown = []')
report "AP4: a role this cut does not know is silently ignored" "$m" \
       "test_a_role_this_cut_does_not_know_is_refused_by_name"

m=$(mutant ap_keys "$PKG" \
    '    missing = [k for k in ROLE_KEYS if k not in route]
    extra = sorted(set(route) - set(ROLE_KEYS))
    if missing or extra:' \
    '    missing = [k for k in ROLE_KEYS if k not in route]
    extra = sorted(set(route) - set(ROLE_KEYS))
    if False:')
report "AP5: a missing or extra key in ipv4_route is not refused" "$m" \
       "test_a_missing_key_is_refused_by_name"

m=$(mutant ap_extra "$PKG" \
    '    extra = sorted(set(route) - set(ROLE_KEYS))' \
    '    extra = []')
report "AP6: an extra key in ipv4_route is accepted" "$m" "test_an_extra_key_is_refused_by_name"

m=$(mutant ap_params "$PKG" \
    '    missing = [k for k in ROLE_PARAM_KEYS if k not in params]
    extra = sorted(set(params) - set(ROLE_PARAM_KEYS))
    if missing or extra:' \
    '    missing = [k for k in ROLE_PARAM_KEYS if k not in params]
    extra = sorted(set(params) - set(ROLE_PARAM_KEYS))
    if False:')
report "AP7: a missing or extra parameter is not refused" "$m" \
       "test_a_missing_or_extra_parameter_is_refused_by_name"

m=$(mutant ap_emptyname "$PKG" \
    '        if not isinstance(value, str) or not value:
            spelled = key if key in ROLE_KEYS else f"params.{key}"' \
    '        if not isinstance(value, str):
            spelled = key if key in ROLE_KEYS else f"params.{key}"')
report "AP8: an empty name is accepted" "$m" "test_an_empty_name_is_refused_rather_than_guessed"

m=$(mutant ap_owner "$PKG" \
    '    if values["owner"] not in ROLE_OWNERS:' \
    '    if False:')
report "AP9: the loader accepts an owner outside the two words" "$m" \
       "test_an_owner_outside_the_two_words_is_refused"

m=$(mutant ap_owners "$PKG" \
    'ROLE_OWNERS = ("ndtwin", "package")' \
    'ROLE_OWNERS = ("ndtwin",)')
report "AP10: owner package stops being a legal word (and the two copies disagree)" "$m" \
       "test_both_owners_are_accepted"

m=$(mutant ap_swap "$PKG" \
    '    return Roles(ipv4_route=RouteRole(**values))' \
    '    return Roles(ipv4_route=RouteRole(**dict(values, dst_mac=values["port"],
                                                 port=values["dst_mac"])))')
report "AP11: the loader carries the two parameter names swapped" "$m" \
       "test_a_declared_route_role_is_carried_name_for_name"

# convert -- the flag and what it does to the package

m=$(mutant cv_missing "$CONVERT" \
    '    missing = [k for k in ROLE_FLAG_KEYS if k not in values]' \
    '    missing = []')
report "CV1: a missing name in the flag is not refused" "$m" \
       "test_a_missing_name_is_refused_and_named"

m=$(mutant cv_twice "$CONVERT" \
    '        if key in values:' \
    '        if False:')
report "CV2: a name given twice is taken" "$m" \
       "test_an_unknown_duplicated_or_empty_key_is_refused"

m=$(mutant cv_swap "$CONVERT" \
    '            "params": {"dst_mac": values["dst_mac"], "port": values["port"]}}' \
    '            "params": {"dst_mac": values["port"], "port": values["dst_mac"]}}')
report "CV3: the flag writes the two parameter names swapped" "$m" \
       "test_the_six_names_become_the_roles_object_package_json_carries"

m=$(mutant cv_external "$CONVERT" \
    '    if package["control_plane"]["mode"] == "external":' \
    '    if False:')
report "CV4: a role is written into an external package" "$m" \
       "test_a_role_on_an_external_control_plane_is_refused"

m=$(mutant cv_noprogram "$CONVERT" \
    '    if not own_program:' \
    '    if False:')
report "CV5: a role is written into a package where it applies to no switch" "$m" \
       "test_a_role_on_a_package_whose_every_switch_runs_ndtwins_pipeline_is_refused"

m=$(mutant cv_alltables "$CONVERT" \
    '            if (isinstance(entry, dict) and entry.get("table") in names' \
    '            if (isinstance(entry, dict)')
report "CV6: owner ndtwin empties every table, not only the owned one" "$m" \
       "test_every_other_table_keeps_its_entries"

m=$(mutant cv_count "$CONVERT" \
    '        removed[str(dpid)] = gone' \
    '        removed[str(dpid)] = 0')
report "CV7: the entries taken out are not counted" "$m" \
       "test_owner_ndtwin_takes_the_owned_tables_match_entries_out_and_counts_them"

m=$(mutant cv_package "$CONVERT" \
    '    if role["owner"] != "ndtwin":' \
    '    if False:')
report "CV8: owner package still takes the author's entries out" "$m" \
       "test_owner_package_keeps_the_authors_entries_byte_for_byte"

m=$(mutant cv_noroles "$CONVERT" \
    '    package["roles"] = {"ipv4_route": role}' \
    '    pass')
report "CV9: the flag's roles never reach package.json" "$m" \
       "test_the_package_carries_the_roles_block"

m=$(mutant cv_copies "$CONVERT" \
    '    copies = [(src, rel) for src, rel in copies if rel not in rewrites]' \
    '    copies = [(src, rel) for src, rel in copies if rel not in rewrites
              and not rel.startswith("build/")]')
report "CV10: with the flag, files it had no reason to touch go missing" "$m" \
       "test_everything_but_the_runtime_files_and_package_json_is_as_without_the_flag"

m=$(mutant cv_cli "$CONVERT" \
    '            print(f"  owned table   : {sum(removed.values())} match entr"' \
    '            print(f"  owned table   : {0} match entr"')
report "CV11: the convert report does not say how many entries it took out" "$m" \
       "test_the_command_line_reports_the_count"

# pre-flight -- the rows, the suggestion, the reverse controls

m=$(mutant pf_badpass "$PREFLIGHT" \
    '        report.ok("owned table has no package entries",' \
    '        report.bad("owned table has no package entries",')
report "PF1: an owned table with no package entries is reported as a failure" "$m" \
       "test_a_converted_owned_package_passes_every_check"

m=$(mutant pf_shape "$PREFLIGHT" \
    '        report.bad("roles", str(exc))' \
    '        report.note("roles", str(exc))')
report "PF2: a roles shape the loader refuses passes pre-flight" "$m" \
       "test_a_shape_the_loader_refuses_is_refused_here_with_the_loaders_sentence"

m=$(mutant pf_suggestdeclared "$PREFLIGHT" \
    '    if raw is None:
        if not p4infos:' \
    '    if True:
        if not p4infos:')
report "PF3: a package that declared its roles is still given a suggestion (and not checked)" "$m" \
       "test_no_suggestion_is_printed_for_a_package_that_declared_its_roles"

m=$(mutant pf_count "$PREFLIGHT" \
    '    own = [k for k, v in own if (v or {}).get("pipeline")]' \
    '    own = [k for k, v in own if (v or {}).get("pipeline")][:1]')
report "PF4: one switch's binding stands for the whole fabric" "$m" \
       "test_one_block_resolves_on_both_programs"

m=$(mutant pf_default "$PREFLIGHT" \
    '    if defaults:
        report.note("owned table default action",' \
    '    if False:
        report.note("owned table default action",')
report "PF5: the kept default action is not disclosed" "$m" \
       "test_the_kept_default_action_is_disclosed_not_refused"

m=$(mutant pf_message "$PREFLIGHT" \
    '            problems.append(str(exc))' \
    '            problems.append("roles.ipv4_route does not fit")')
report "PF6: pre-flight rewords the proxy's refusal instead of printing it" "$m" \
       "test_the_message_is_the_one_the_proxy_raises"

m=$(mutant pf_detail "$PREFLIGHT" \
    '                  f"{len(bound)} switch(es): {first.table} {first.match_field} -> "' \
    '                  f"{len(bound)} switch(es): {first.table} -> "')
report "PF7: the binding row stops naming the match field it bound" "$m" \
       "test_the_binding_row_names_what_every_switch_resolved_to"

m=$(mutant pf_fatal "$PREFLIGHT" \
    '            report.note("roles suggestion",' \
    '            report.bad("roles suggestion",')
report "PF8: the suggestion is a failure" "$m" "test_the_suggestion_is_not_a_failure"

m=$(mutant pf_entriesp4info "$PREFLIGHT" \
    '    _check_roles(report, package_dir, package, model, pipeline_p4info, referenced)' \
    '    _check_roles(report, package_dir, package, model, used_p4info or pipeline_p4info,
                 referenced)')
report "PF9: the heuristic reads the entries' p4info, so NDTwin's own pipeline gets a suggestion" "$m" \
       "test_an_all_null_package_gets_no_suggestion"

m=$(mutant pf_guess "$PREFLIGHT" \
    '        return role
    return None' \
    '        return role
    return {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm",
            "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward",
            "params": {"dst_mac": "dstAddr", "port": "port"}}')
report "PF10: when nothing fits, the heuristic suggests NDTwin's own names" "$m" \
       "test_calc_has_no_route_table_so_nothing_is_suggested"

# PF11 and PF12 are two different claims. PF11: when NOTHING resolved there is no owned table
# to vouch for (calc). PF12: when SOME switches resolved, the owned-table rows are about those
# only. Gate run c21deca3 had one mutation for both, the loop's, and calc cannot see the loop --
# nothing resolves there, so the guard returns before it; that mutation SURVIVED, correctly.
m=$(mutant pf_noguard "$PREFLIGHT" \
    '    if not bound:
        # Nothing resolved' \
    '    if False:
        # Nothing resolved')
report "PF11: with nothing resolved, pre-flight vouches for an owned table the program lacks" "$m" \
       "test_no_owned_table_row_is_claimed_for_a_table_the_program_does_not_have"

m=$(mutant pf_ownedall "$PREFLIGHT" \
    '    for dpid, _binding in bound:
        path = referenced.get(f"switches[{dpid}].entries")' \
    '    for dpid in own:
        path = referenced.get(f"switches[{dpid}].entries")')
report "PF12: the owned-table rows also judge a switch whose binding did not resolve" "$m" \
       "test_the_owned_table_rows_speak_only_of_the_switches_whose_binding_resolved"

m=$(mutant mn_predict "$MAIN" \
    '    if ndtwin:
        return _binding_words(route_binding.BASELINE)' \
    '    if False:
        return _binding_words(route_binding.BASELINE)')
report "MN17: the prediction applies a package's roles to an NDTwin-pipeline switch" "$m" \
       "test_roles_do_not_apply_to_an_ndtwin_switch_beside_a_foreign_one"

# --- round 2 (TICKET-P4-roles section 7 ruling 5) -------------------------------------------------

# item 1 -- readopt obeys the fabric's route skip
m=$(mutant tm_attachedoff "$TOPOMGR" \
    '                if self.routes_to_attached_hosts_only and next_node != dst:' \
    '                if False and next_node != dst:')
report "R2-1a: on a fabric that skips its routes, a route through another switch is written" "$m" \
       "test_restricted_each_switch_routes_only_to_its_own_hosts_and_counts_only_those"

m=$(mutant tm_attacheddefault "$TOPOMGR" \
    '        self.routes_to_attached_hosts_only = False' \
    '        self.routes_to_attached_hosts_only = True')
report "R2-1b: every fabric's route writer starts restricted" "$m" \
       "test_the_default_is_every_host_as_before"

m=$(mutant mn_scopenever "$MAIN" \
    '    topo.routes_to_attached_hosts_only = SKIP_ROUTES in skipped' \
    '    topo.routes_to_attached_hosts_only = False')
report "R2-1c: startup never tells the route writer that the fabric skips its routes" "$m" \
       "test_a_fabric_that_skips_its_routes_tells_the_route_writer"

m=$(mutant mn_scopealways "$MAIN" \
    '    topo.routes_to_attached_hosts_only = SKIP_ROUTES in skipped' \
    '    topo.routes_to_attached_hosts_only = True')
report "R2-1d: startup restricts the route writer on a fabric whose routes NDTwin owns" "$m" \
       "test_a_fabric_whose_routes_ndtwin_owns_does_not_restrict_the_writer"

m=$(mutant mn_scopenote "$MAIN" \
    '    if (ndtwin and result.get("status") == "success"
            and getattr(topology, "routes_to_attached_hosts_only", False)):' \
    '    if False:')
report "R2-1e: a restricted refill is reported as if it were the whole one" "$m" \
       "test_it_says_the_refill_stopped_at_the_attached_hosts_and_why"

m=$(mutant mn_scopenoteall "$MAIN" \
    '            and getattr(topology, "routes_to_attached_hosts_only", False)):' \
    '            and True):')
report "R2-1f: every NDTwin readopt claims its refill was restricted" "$m" \
       "test_on_a_fabric_that_installs_routes_the_same_readopt_refills_every_host"

m=$(mutant mn_refillnow "$MAIN" \
    '    if (_fabric_installs_routes() and binding is not None
            and binding.owner == route_binding.OWNER_NDTWIN):' \
    '    if (binding is not None
            and binding.owner == route_binding.OWNER_NDTWIN):')
report "R2-1g: a foreign readopt refills on a fabric that skipped its routes at startup" "$m" \
       "test_a_fabric_that_skipped_its_routes_at_startup_is_not_refilled_now"

m=$(mutant mn_refillnull "$MAIN" \
    '    return skipped is not None and SKIP_ROUTES not in skipped' \
    '    return SKIP_ROUTES not in (skipped or ())')
report "R2-1h: before startup has decided, a foreign readopt refills" "$m" \
       "test_before_startup_has_run_a_foreign_switch_is_not_refilled"

m=$(mutant mn_refillowner "$MAIN" \
    '    if (_fabric_installs_routes() and binding is not None
            and binding.owner == route_binding.OWNER_NDTWIN):' \
    '    if (_fabric_installs_routes() and binding is not None):')
report "R2-1i: a package-owned switch is refilled with NDTwin's routes" "$m" \
       "test_a_package_owned_switch_is_not_refilled_on_a_fabric_that_installs_routes"

# Round 1's killer for this test was M-R9, inside routes_owned_by_ndtwin -- which readopt no
# longer calls (item 1: the predicate is startup's recorded decision plus THIS switch's binding).
m=$(mutant mn_refillunbound "$MAIN" \
    '    if (_fabric_installs_routes() and binding is not None
            and binding.owner == route_binding.OWNER_NDTWIN):' \
    '    if (_fabric_installs_routes()
            and getattr(binding, "owner", route_binding.OWNER_NDTWIN)
            == route_binding.OWNER_NDTWIN):')
report "R2-1j: a switch that came back unbound counts as owned and is refilled" "$m" \
       "test_a_switch_that_came_back_unbound_is_not_refilled"

# item 2 -- the literal gate over four names
m=$(mutant fs_fieldliteral "$STATS" \
    '    route_binding.BASELINE.match_field: "nw_dst",' \
    '    "hdr.ipv4.dstAddr": "nw_dst",')
report "R2-2a: the renderer spells the route match field again" "$m" \
       "test_no_module_spells_the_four_route_names_outside_baseline_and_the_named_exceptions"

m=$(mutant fs_fieldgone "$STATS" \
    '    route_binding.BASELINE.match_field: "nw_dst",' \
    '')
report "R2-2b: the renderer loses NDTwin's own route match field" "$m" \
       "test_the_renderer_reads_the_route_match_field_back_as_nw_dst"

m=$(mutant tm_stale "$TOPOMGR" \
    '    if p4_key in ("hdr.ipv4.srcAddr", "hdr.ipv4.dstAddr")' \
    '    if p4_key in ("hdr.ipv4.srcAddr", FIVE_TUPLE_FIELD_MAP["nw_dst"])')
report "R2-2c: a named exception stops matching anything and stays on the list" "$m" \
       "test_no_module_spells_the_four_route_names_outside_baseline_and_the_named_exceptions"

# item 4 -- NDTwin's /stats/flow in HTTP-body bytes. R2-4a is invisible to round 1's
# sort_keys fixture (TheNdtwinPipelinesFlowStatsAreByteIdenticalToTheBaseTest stays green): that
# is the point of the byte comparison.
m=$(mutant fs_keyorder "$STATS" \
    '        "idle_timeout": 0,
        "hard_timeout": 0,' \
    '        "hard_timeout": 0,
        "idle_timeout": 0,')
report "R2-4a: two keys of every flow swap places in the body the kernel parses" "$m" \
       "test_the_body_is_the_one_the_base_answered_byte_for_byte"

m=$(mutant http_drift "$FLOWROUTE_TEST" \
    'BASELINE_NDTWIN_HTTP_BODY_SHA256 = "aca1a88af0d889a8a7cc84468ee775cbccfb34ed1f3b8d3c1d3d4373f87a8659"' \
    'BASELINE_NDTWIN_HTTP_BODY_SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"')
report "R2-4b: the pinned bytes and the recording they claim to be part ways" "$m" \
       "test_the_constant_is_the_recording"

# item 5 -- a 5-tuple delete / modify on a foreign switch
m=$(mutant pc_5del "$CLIENT" \
    '        self._writable_five_tuple_binding("a 5-tuple rule delete")' \
    '        None')
report "R2-5a: a 5-tuple delete reaches a foreign switch" "$m" \
       "test_a_five_tuple_delete_on_a_foreign_switch_answers_501"

m=$(mutant pc_5mod "$CLIENT" \
    '        binding = self._writable_five_tuple_binding("a 5-tuple rule modify")' \
    '        binding = self.route_binding')
report "R2-5b: a 5-tuple modify reaches a foreign switch" "$m" \
       "test_a_five_tuple_modify_on_a_foreign_switch_answers_501"

# item 8 -- link_discovery is the mode; the seed's outcome is its own fabric-level key
m=$(mutant mn_seedcount "$MAIN" \
    '        _fabric.update(lldp=False, watchdog=False, declared_links=True,' \
    '        _fabric.update(lldp=False, watchdog=False, declared_links=seeded > 0,')
report "R2-8a: link_discovery follows the seed count again" "$m" \
       "test_a_foreign_fabric_that_declares_no_link_still_says_declared"

m=$(mutant mn_nonewhen "$MAIN" \
    '    if external:
        discovery = "none"' \
    '    if not fabric.get("lldp") and not fabric.get("declared_links"):
        discovery = "none"')
report "R2-8b: \"none\" means \"nothing started\" again, not \"external\"" "$m" \
       "test_none_is_for_an_external_control_plane_only"

m=$(mutant mn_seederror "$MAIN" \
    '        return 0, f"{type(e).__name__}: {e}"' \
    '        return 0, None')
report "R2-8c: a seed that raised is reported as one that entered nothing" "$m" \
       "test_a_seed_that_raises_says_declared_and_names_the_error"

m=$(mutant mn_seednoreport "$MAIN" \
    '    return dict(seed)' \
    '    return None')
report "R2-8d: the seed's outcome is never reported" "$m" \
       "test_a_seed_that_worked_reports_its_count_and_no_error"

m=$(mutant mn_seedexternal "$MAIN" \
    '        _fabric.update(lldp=False, watchdog=False, declared_links=False)
' \
    '        _fabric.update(lldp=False, watchdog=False, declared_links=True,
                       declared_links_seed={"directions": 0, "error": None})
')
report "R2-8e: an external fabric reports a declaration it never made" "$m" \
       "test_a_fabric_that_declares_nothing_reports_null"

m=$(mutant ar_seedkey "$ROUTES" \
    '    if declared_links_report is not None:
        state["declared_links"] = declared_links_report()' \
    '    if False:
        state["declared_links"] = declared_links_report()')
report "R2-8f: switch_state never carries the seed's outcome" "$m" \
       "test_the_seed_outcome_is_a_top_level_key_not_a_per_switch_one"

m=$(mutant ar_seednull "$ROUTES" \
    '    if declared_links_report is not None:
        state["declared_links"] = declared_links_report()' \
    '    if declared_links_report is not None and declared_links_report() is not None:
        state["declared_links"] = declared_links_report()')
report "R2-8g: a fabric that declares nothing serves no key instead of null" "$m" \
       "test_a_fabric_that_declares_nothing_serves_null_rather_than_no_key"

m=$(mutant ar_seedalways "$ROUTES" \
    '    if declared_links_report is not None:
        state["declared_links"] = declared_links_report()' \
    '    if True:
        state["declared_links"] = (declared_links_report() if declared_links_report
                                   else None)')
report "R2-8h: an uninjected reporter still adds the key" "$m" \
       "test_an_uninjected_seed_reporter_adds_no_key"

m=$(mutant mn_seedunwired "$MAIN" \
    'api_routes.inject_declared_links_report(declared_links_report)' \
    '# (the seed reporter is not wired)')
report "R2-8i: the proxy never wires the seed reporter" "$m" \
       "test_the_proxy_wires_the_reporter_at_import"

# --- item 6: 07_roles_basic.sh --self-test, mutated ------------------------------------------------
#
# The live script is not run here (it needs a lab); its --self-test is. Each mutation weakens ONE
# verdict function of a copy, and must turn SELF-TEST PASS into SELF-TEST FAIL through the named
# case. The copy has no runs/ directory, so the comparison against the real 062604Z_02 capture is
# skipped in the copy ("not compared (NOT a pass)") -- every case named below is synthetic.

l7_mutant() {   # $1 = label, $2 = the anchor, $3 = its replacement
    local label="$1" old="$2" new="$3"
    local d="$BK/$label"; mkdir -p "$d/$LIVE_DIR_REL" "$d/p4_proxy" "$d/tmp"
    cp "$REPO/$LIVE_DIR_REL/_common.sh" "$REPO/$LIVE_DIR_REL/07_roles_basic.sh" "$d/$LIVE_DIR_REL/"
    ln -s "$(dirname "$(dirname "$PY")")" "$d/p4_proxy/venv"
    python3 - "$d/$LIVE_DIR_REL/07_roles_basic.sh" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert a != b, "identity mutation: %s" % a[:70]
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

l7_report() {   # $1 = mutation name, $2 = mutant dir, $3 = the self-test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(cd "$2" && TMPDIR="$2/tmp" timeout 120 bash "$LIVE_DIR_REL/07_roles_basic.sh" \
              --self-test 2>&1); rc=$?
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qF "🔴    $3 " <<<"$out" \
            && /usr/bin/grep -q '^SELF-TEST FAIL' <<<"$out"; then
        printf '  caught   %-66s (self-test case "%s" went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (self-test case "%s" stayed green)\n' "$1" "$3"
        /usr/bin/grep -E '🔴|SELF-TEST' <<<"$out" | head -4 | sed 's/^/             /'
    fi
    rm -rf "$2"
}

l7_base="$BK/l7_base"; mkdir -p "$l7_base/$LIVE_DIR_REL" "$l7_base/p4_proxy" "$l7_base/tmp"
cp "$REPO/$LIVE_DIR_REL/_common.sh" "$LIVE07" "$l7_base/$LIVE_DIR_REL/"
ln -s "$(dirname "$(dirname "$PY")")" "$l7_base/p4_proxy/venv"
if (cd "$l7_base" && TMPDIR="$l7_base/tmp" bash "$LIVE_DIR_REL/07_roles_basic.sh" --self-test \
        2>&1 | tail -1 | /usr/bin/grep -q '^SELF-TEST PASS'); then
    echo "  07 self-test baseline: SELF-TEST PASS"
else
    echo "  07 self-test baseline is RED -- its mutations would prove nothing"; exit 2
fi
rm -rf "$l7_base"

m=$(l7_mutant l7_edges 'if have.get(d) != (True, True)]' 'if have.get(d) is None]')
l7_report "L7-1: edges_all_up accepts a direction that is present but down" "$m" \
          "L1 one direction down"

m=$(l7_mutant l7_enabled 'if have.get(d) != (True, True)]' \
    'if (have.get(d) or (None, None))[1] is not True]')
l7_report "L7-2: edges_all_up stops asking whether the kernel ENABLED the edge" "$m" \
          "L1 up but not enabled"

m=$(l7_mutant l7_cutdown 'if [[ "$a" == *" False" && "$b" == *" False" ]]; then' \
    'if [[ "$a" == *" False" || "$b" == *" False" ]]; then')
l7_report "L7-3: cut_is_down accepts one direction down" "$m" "L4 only one direction down"

m=$(l7_mutant l7_cutup 'if [[ "$a" == "True True" && "$b" == "True True" ]]; then' \
    'if [[ "$a" == "True True" || "$b" == "True True" ]]; then')
l7_report "L7-4: cut_is_up accepts one direction back up" "$m" "L4 only one direction back up"

m=$(l7_mutant l7_caps '       if s.get("capabilities") != want}' \
    '       if s.get("capabilities") is None}')
l7_report "L7-5: caps_are only checks that capabilities exist" "$m" \
          "L6 one switch says reroute:true"

m=$(l7_mutant l7_skipped 'if [[ "$got" == "$2" ]]; then echo "OK control_plane.skipped is $got"' \
    'if [[ -n "$got" ]]; then echo "OK control_plane.skipped is $got"')
l7_report "L7-6: skipped_is accepts any skipped list" "$m" "L6 routes still skipped"

m=$(l7_mutant l7_declared 'if len(declared) == n and len(links) == n:' \
    'if len(declared) == len(links):')
l7_report "L7-7: declared_links_marked stops counting the links" "$m" "L1 no link entries"

m=$(l7_mutant l7_flowhas 'if any(r.get("actions") == [f"OUTPUT:{port}"] for r in rows):' \
    'if rows:')
l7_report "L7-8: flow_has accepts the destination on any port" "$m" \
          "L2 read back on the wrong port"

m=$(l7_mutant l7_flowlacks 'print(f"BAD /stats/flow/{dpid} still has {dst}: {rows}" if rows' \
    'print(f"BAD /stats/flow/{dpid} still has {dst}: {rows}" if False')
l7_report "L7-9: flow_lacks never fails" "$m" "L2 delete left it"

m=$(l7_mutant l7_dispclean 'ok = (d.get("complete") is True and c.get("dispatch_failed") == 0
      and c.get("dispatched_ok") == d.get("enqueued") and so.get("rejected_by_switch", 0) == 0)' \
    'ok = (d.get("complete") is True)')
l7_report "L7-10: dispatch_clean only asks whether the request completed" "$m" \
          "L2 dispatch failed"

m=$(l7_mutant l7_501code 'if code == "501" and detail.get("outcome")' \
    'if code in ("500", "501") and detail.get("outcome")')
l7_report "L7-11: refused_501 accepts a 500" "$m" "L5 a 500 is not the 501"

m=$(l7_mutant l7_501reason ' and detail.get("reason") == "unbound":' ':')
l7_report "L7-12: refused_501 stops checking the reason" "$m" "L5 a 501 for another reason"

m=$(l7_mutant l7_501outcome ' and detail.get("outcome") == "unsupported_on_p4"' '')
l7_report "L7-13: refused_501 stops checking the outcome" "$m" \
          "L5 a 501 that is not unsupported_on_p4"

m=$(l7_mutant l7_dispfailed 'if failed >= 1 and hits:' 'if hits:')
l7_report "L7-14: dispatch_refused_unbound stops asking whether the write failed" "$m" \
          "L5 a clean dispatch is not the refusal"

m=$(l7_mutant l7_dispunbound ' and "unbound" in str(f.get("message"))]' ']')
l7_report "L7-15: dispatch_refused_unbound accepts a refusal for any reason" "$m" \
          "L5 a refusal for another reason"

m=$(l7_mutant l7_rows '    if not os.path.exists(after) or a != b:' \
    '    if not os.path.exists(after):')
l7_report "L7-16: rows_unchanged ignores the row diff" "$m" "L5 a row changed"

m=$(l7_mutant l7_netem 'for f in "$@"; do' 'for f in "$1"; do')
l7_report "L7-17: no_netem looks at one end only" "$m" "L4 netem left on one end"

# --- negative controls: edits no suite specifies, which must stay GREEN -------------------------

control() {  # $1 = label, $2 = mutant dir
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-66s (the whole suite stays green)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 RED   %-66s -- these suites are change detectors, not a specification\n' "$1"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -4 | sed 's/^/             /'
    fi
    rm -rf "$2"
}

m=$(mutant c1 "$BINDING" \
    '#: Where a binding came from.' \
    '# MUTANT: a comment, and nothing else.
#: Where a binding came from.')
control "C1 (control): a comment-only edit in route_binding.py" "$m"

m=$(mutant c2 "$PREFLIGHT" \
    '    raw = package.get("roles")
    route_binding = common.import_route_binding()' \
    '    raw = package.get("roles")
    # MUTANT: a comment, and nothing else.
    route_binding = common.import_route_binding()')
control "C2 (control): a comment-only edit inside pre-flight's roles check" "$m"

# --- every new test, seen red ----------------------------------------------------------------------

echo
never=$(sort -u "$RED_LOG" | comm -23 <(sort -u "$NEW_IDS") -)
total=$(wc -l < "$NEW_IDS")
if [[ -n "$never" ]]; then
    SURVIVORS=$((SURVIVORS+1))
    echo "🔴 NEVER SEEN RED: $(/usr/bin/grep -c . <<<"$never") of $total new test(s) -- no mutation reddened them:"
    sed 's/^/     /' <<<"$never"
else
    echo "every new test seen red: $total of $total"
fi

echo
for f in "${SOURCES[@]}"; do
    [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "${BASE_SHA[$f]}" ]] \
        || { echo "🔴 baseline CHANGED -- ${f#"$REPO/"} was written during the gate"; exit 3; }
done
echo "baseline byte-identical: yes (${#SOURCES[@]} sources)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
