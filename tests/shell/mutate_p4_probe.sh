#!/usr/bin/env bash
#
# Mutation gate for what the proxy says about a bmv2 that has been pushed no pipeline: the ProbeTest case in
# p4_proxy/tests/test_p4_client_writes.py and ASwitchWithNoPipelineIsNotAliveTest in
# p4_proxy/tests/test_switch_state.py.
#
# [Co-developed with claude code -- Adam]
#
# Measured on stock and bmv2-fast simple_switch_grpc (run-stock.out / run-fast.out, phase A, under
# doc/audit/2026-10-04_p4-cookie-probe/): a bmv2 with no pipeline answers the
# COOKIE_ONLY probe with FAILED_PRECONDITION. P4RuntimeClient.probe() turns that into ok False, so
# switch_liveness() (which GET /p4/switch_state serves) shows probe_ok false and
# connected_switch_dpids() leaves the switch out; reroutable_down_endpoints() grants no amnesty on
# the `probe_ok is True` clause. Before these tests a probe that read FAILED_PRECONDITION as ok
# survived the whole p4_proxy suite (1734 ran, 0 red).
#
# What would follow if a no-pipeline switch read as alive is that it is listed as connected and the
# kernel's p4LivenessFor answers Up. The amnesty case pins its one clause and nothing more: in the
# deployed configuration both directions of every link are seeded and a restarted bmv2 behind the
# old client sends no beacons, so every link of it is reroutable whatever probe_ok says.
#
# M1 is that mutant. M2-M5 break the other links of the same chain (the list, the amnesty clause,
# the payload, the poller's record), each alone while the probe itself stays right. C1 is a
# comment-only edit of the probe and every test must stay green on it; a mutation whose anchor is
# missing is a SURVIVOR, the control included, and the control case (a switch that answers) must
# stay green under every mutation.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY of p4_proxy under a temp dir and
# the tests are run there. Nothing under p4_proxy/ is written -- another session may be executing
# those files right now -- and the four files are re-hashed at the end. A mutation whose anchor is
# not exactly once in its file is a SURVIVOR, not a skip.
#
# Usage:  tests/shell/mutate_p4_probe.sh          PROXY_PY=<python> overrides the interpreter
# Exit:   0 every mutation caught and the control green; 1 a survivor; 2 refused; 3 baseline moved.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
TOPO="$REPO/p4_proxy/proxy_agent/topology_manager.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
TEST_STATE="$REPO/p4_proxy/tests/test_switch_state.py"
# The two classes only, not the modules: the rest of test_switch_state drives the poller through
# real threads and costs seconds a run, which this gate pays once per mutation.
MODULES="tests.test_p4_client_writes.ProbeTest tests.test_switch_state.ASwitchWithNoPipelineIsNotAliveTest"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives in
# the main checkout), so the main worktree is asked of git before giving up. Override: PROXY_PY= .
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
echo "HEAD: $(git -C "$REPO" rev-parse HEAD 2>/dev/null)"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-probe-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
# proxy_agent.main loads the fabric model at import from <three levels above mininet/>/setting, so
# each copy (BK/<label>/mininet) looks for BK/setting. Without it every copy dies on import and the
# baseline reads red -- which is what mutate_p4_rule_install_time.sh does from a temp dir.
cp -r "$REPO/setting" "$BK/setting"
BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_TOPO=$(sha256sum "$TOPO" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TEST_STATE=$(sha256sum "$TEST_STATE" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0
CONTROL_CASE="test_control_a_switch_that_answers_is_listed_and_does_get_the_amnesty"

# PYTHONDONTWRITEBYTECODE so a mutant cannot be run from a .pyc of its unmutated self.
run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest $MODULES -v 2>&1 )
}

# report <name> <mutant dir> <test case that must go red> [more test cases that must go red]
report() {
    local name="$1" dir="$2"; shift 2
    local out rc t missed=""
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -d "$dir/proxy_agent" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (the anchor is missing or not unique: nothing was mutated)\n' "$name"
        return
    fi
    out=$(run_against "$dir"); rc=$?
    for t in "$@"; do
        grep -qE "^(FAIL|ERROR): $t " <<<"$out" || missed="$missed $t"
    done
    # The control case (a switch that answers) must stay green under every mutation, or a mutant
    # that breaks every switch alike would also redden the cases above and look caught.
    grep -qE "^$CONTROL_CASE .*ok$" <<<"$out" || missed="$missed $CONTROL_CASE(went red or did not run)"
    if [[ "$rc" -ne 0 && -z "$missed" ]]; then
        printf '  caught   %-70s (%d case(s) went red)\n' "$name" "$#"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (rc=%s, stayed green:%s)\n' "$name" "$rc" "${missed:- none -- red for the wrong reason}"
        grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# The negative control: a mutation that changes no behaviour must leave every case green.
report_green() {
    local name="$1" dir="$2"
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -d "$dir/proxy_agent" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  RED      %-70s (the anchor is missing or not unique: nothing was mutated)\n' "$name"
        return
    fi
    out=$(run_against "$dir"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-70s (as it must be)\n' "$name"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  RED      %-70s (a comment-only edit broke a test: the tests pin source text)\n' "$name"
        grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole copy of p4_proxy's importable tree. The parameters are NAMED so
# tests/shell/check_gate_anchors.py can read this gate (it learns the anchor and the file from this
# function's own `local ... file="$2" old="$3"` line).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    [[ $? -eq 0 ]] || rm -rf "$d"    # no mutated copy: report / report_green count that as a survivor
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the mutant the suite used to let through -------------------------------------------------

m=$(mutant m1 "$CLIENT" \
    '            return {"ok": False, "detail": f"{code}: {details}"}' \
    '            if code == "FAILED_PRECONDITION":
                return {"ok": True, "detail": f"{code}: {details}"}
            return {"ok": False, "detail": f"{code}: {details}"}')
report "M1: probe() reads FAILED_PRECONDITION (no pipeline) as ok" "$m" \
       "test_a_switch_with_no_pipeline_is_not_ok_and_the_detail_says_why" \
       "test_liveness_reports_probe_ok_false_with_the_status_name" \
       "test_it_is_left_out_of_the_connected_switches" \
       "test_it_gets_no_amnesty_from_the_stalled_switch_rule"

# --- the other links of the chain: each alone gives an empty switch a healthy one's treatment ---

m=$(mutant m2 "$TOPO" \
    '                    if (self._last_probe.get(dpid) or {}).get("ok") is not False]' \
    '                    if True]')
report "M2: connected_switch_dpids lists a switch whose probe failed" "$m" \
       "test_it_is_left_out_of_the_connected_switches"

m=$(mutant m3 "$TOPO" \
    '            if links and all(link in down_links for link in links) and probe_ok.get(dpid) is True:' \
    '            if links and all(link in down_links for link in links) and probe_ok.get(dpid) is not None:')
report "M3: the stalled-switch amnesty goes to any switch that was probed, answered or not" "$m" \
       "test_it_gets_no_amnesty_from_the_stalled_switch_rule"

m=$(mutant m4 "$TOPO" \
    '                    "probe_ok": None if probe is None else probe["ok"],' \
    '                    "probe_ok": None if probe is None else True,')
report "M4: switch_liveness serves probe_ok true for every probed switch" "$m" \
       "test_liveness_reports_probe_ok_false_with_the_status_name"

m=$(mutant m5 "$TOPO" \
    '                            "ok": bool(result.get("ok")),' \
    '                            "ok": True,')
report "M5: the poller records every probe as ok" "$m" \
       "test_liveness_reports_probe_ok_false_with_the_status_name" \
       "test_it_is_left_out_of_the_connected_switches" \
       "test_it_gets_no_amnesty_from_the_stalled_switch_rule"

# --- the negative control ---------------------------------------------------------------------

m=$(mutant c1 "$CLIENT" \
    '            code = e.code().name if e.code() is not None else "UNKNOWN"' \
    '            # a comment, nothing else
            code = e.code().name if e.code() is not None else "UNKNOWN"')
report_green "C1 (control): a comment inside the probe's error branch" "$m"

echo
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPO" | cut -d' ' -f1)" == "$BASE_TOPO" ]] || { echo "🔴 baseline CHANGED -- topology_manager.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STATE" | cut -d' ' -f1)" == "$BASE_TEST_STATE" ]] || { echo "🔴 baseline CHANGED -- test_switch_state.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (2 sources, 2 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
