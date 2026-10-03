#!/usr/bin/env bash
# redfirst_b.sh <worktree> <keep dir> -- feat/external-detect-only-0927 red first: HEAD's tests against
# the code without B -- the AEG head it merged (B_BASE, default fix/rulings-aeg-0927's f7e2a128).
# Every output KEPT. [Co-developed with claude code -- Adam]
#   P  HEAD's test_heartbeat_fabric.py over the base's main.py (the HB W gate's lay_out): the tests of
#      what B ADDS are red; the guards of what external already did (writes nothing, reroutes
#      nothing) are green there -- they are killed by the gate's X mutants instead
#   N  HEAD's test_ndt_heartbeat.sh with NDT_UNDER_TEST = the base's ndt
#   L  HEAD's 08 self-test with the base's HB_ARMS and without H4's two new verdicts
#   C  HEAD's test_live_p1_common.sh over the base's _common.sh (the fingerprint), and the 03/04 pins
#      asked of the base's 03/04
#   T  HEAD's test_live_p1_thirteen.sh over the base's 06
#   E  HEAD's test_live_p1_external_evidence.sh with no tool at all
set -u
WT="$1"; K="$2"; bad=0; BASE="${B_BASE:-f7e2a128}"; cd "$WT" || exit 2; mkdir -p "$K"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export KEEP="$K/unexpected"; source "$HERE/redfirst_lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/b-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
same_set() {   # same_set <label> <got file> <want...>
    local label="$1" got="$2"; shift 2
    local want; want="$(printf '%s\n' "$@" | sort -u)"
    if [[ "$(sort -u "$got")" == "$want" ]]; then ok "$label: exactly the $# expected"
    else nok "$label: red set differs"; diff <(printf '%s\n' "$want") <(sort -u "$got") | sed 's/^/      /'; fi
}

echo "== P: HEAD's test_heartbeat_fabric.py over the base's main.py"
lo="$(sed -n '/^lay_out() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
P="$T/px"; mkdir -p "$P"
( REPO="$WT"; HELPER="$WT/tools/test_workflow/ndtwin-lab"; eval "$lo"; lay_out "$P" )
PYV="$(readlink -f "$WT/p4_proxy/venv")/bin/python"
hbf() { ( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
          timeout 300 "$PYV" -m unittest -v tests.test_heartbeat_fabric > "$1" 2>&1 ); }
git show "$BASE:p4_proxy/proxy_agent/main.py" > "$P/p4_proxy/proxy_agent/main.py"
hbf "$K/p_base_main.out"
/usr/bin/grep -E '^(Ran |OK|FAILED)' "$K/p_base_main.out" | sed 's/^/    /'
sed -n -E 's/^(FAIL|ERROR): ([^ ]+) .*/\2/p' "$K/p_base_main.out" > "$T/p_red"
same_set "base main.py" "$T/p_red" \
    test_it_declares_its_links_and_starts_the_heartbeat_watchdog \
    test_reroute_is_false_for_the_external_reason_even_when_the_heartbeat_is_usable \
    test_an_unusable_heartbeat_is_declared_and_still_external \
    test_link_watchdog_leaves_the_list_while_the_heartbeat_drives_it \
    test_the_prediction_before_startup_says_declared \
    test_the_startup_log_names_the_skipped_list_switch_state_serves \
    test_the_census_says_which_of_its_arms_ndt_up_starts_the_heartbeat_on \
    test_a_heartbeat_watchdog_that_did_not_start_names_all_six \
    test_the_census_names_the_punt_blind_spot_on_external_control_planes \
    "test_an_external_fabric_serves_no_path_over_its_declared_links" \
    "test_startup_marks_an_external_fabric_on_its_own_pipeline_only" \
    "test_the_declared_links_still_seed_the_graph"
echo "    (added at round 4, 09-28: the destination-path cells of test_heartbeat_fabric (and, over f7e2a128, its seeding cell) -- red over every older base for that reason)"
# (the census punt test: added in the 09-28 round, and red over f7e2a128 as over 17e40e29)
# (the did-not-start one is red at the base because there is no heartbeat block on an external fabric to
# read `not_started` from -- B is what makes one)
for t in test_the_route_writer_is_left_skipping_so_a_cut_rewrites_nothing test_no_client_is_asked_to_write_anything \
         test_even_with_every_table_bound_to_ndtwin_it_does_not_reroute \
         test_the_cut_is_told_to_the_kernel_and_no_route_is_rewritten test_an_external_fabric_on_ndtwins_own_pipeline_does_not_start_it; do
    /usr/bin/grep -qE "^$t .* ok$" "$K/p_base_main.out" && ok "  guard green at the base (external already did not do it): $t" \
        || nok "  guard not green at the base: $t"
done
cp "$WT/p4_proxy/proxy_agent/main.py" "$P/p4_proxy/proxy_agent/main.py"
hbf "$K/p_head_main.out"
/usr/bin/grep -qE '^OK' "$K/p_head_main.out" && ok "  the same tree with HEAD's main.py: $(/usr/bin/grep -E '^Ran ' "$K/p_head_main.out")" \
    || nok "  the same tree with HEAD's main.py is not green"

echo "== N: HEAD's test_ndt_heartbeat.sh over the base's ndt"
mkdir -p "$T/ndt/tools/test_workflow"
git show "$BASE:tools/test_workflow/ndt" > "$T/ndt/tools/test_workflow/ndt"
for f in tools/test_workflow/*; do [[ -f "$f" && "$(basename "$f")" != ndt ]] && cp "$f" "$T/ndt/tools/test_workflow/"; done
NDT_UNDER_TEST="$T/ndt/tools/test_workflow/ndt" timeout 900 bash tests/shell/test_ndt_heartbeat.sh > "$K/n_base_ndt.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/n_base_ndt.out" > "$T/n_red"
same_set "base ndt" "$T/n_red" \
    "🔴 exactly one 'heartbeat start' on an external plane" "🔴 after topo-start, before the proxy, as anywhere" \
    "🔴 and ndt says it detects only" \
    "🔴 a failed start on an external plane names external_control_plane" \
    "🔴 a heartbeat the last bring-up withheld is said, with why" \
    "🔴 a later bring-up that starts it clears the record" \
    "🔴 and the record names it for 'ndt status'" \
    "  and the whole of it is kept" \
    "  and why" \
    "🔴 before anything touched the machine" \
    "🔴 'ndt down' clears it with the fabric" \
    "🔴 proven dropped: the heartbeat starts" \
    "  saying it could not tell" \
    "  saying so" \
    "🔴 saying so" \
    "🔴 the check ran once, on the package" \
    "  the check's answer is said, in one line" \
    "  with the check's own reason"
echo "    (added at round 4, 09-28: test_ndt_heartbeat's drop-check cells (section 2c and the withheld row) -- red over every older base for that reason)"
# ("and not the reason a foreign fabric serves" is green over f7e2a128: that ndt never starts the
#  heartbeat on an external plane, so it never reaches the failure branch; redfirst_b2 shows it red
#  over 17e40e29, which did)
NDT_UNDER_TEST="$WT/tools/test_workflow/ndt" timeout 900 bash tests/shell/test_ndt_heartbeat.sh > "$K/n_head_ndt.out" 2>&1 \
    && ok "  HEAD's ndt: $(tail -1 "$K/n_head_ndt.out")" || nok "  HEAD's ndt: $(tail -1 "$K/n_head_ndt.out")"

echo "== L: HEAD's 08 self-test with the base's HB_ARMS and without H4's new verdicts"
python3 - "$LIVE/08_heartbeat.sh" "$T/08_hybrid.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
new_arms = ('ecn/solution mri/skeleton mri/solution p4runtime/skeleton p4runtime/solution flowcache/solution"')
assert s.count(new_arms) == 1
s = s.replace(new_arms, 'ecn/solution mri/skeleton mri/solution"')
for fn in ("def v_links(", "def v_model_has("):
    i = s.index(fn); j = s.index("\ndef ", i + 1)
    s = s[:i] + s[j + 1:]
open(sys.argv[2], "w").write(s)
PY
src="$(sed -n '/^ltree() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
( REPO="$WT"; LIVE_DIR_REL="$LIVE"; LIVE08="$WT/$LIVE/08_heartbeat.sh"; eval "$src"
  ltree "$T/lt"; cp "$T/08_hybrid.sh" "$T/lt/$LIVE/08_heartbeat.sh"
  cd "$T/lt" && TMPDIR="$T/lt/tmp" PYTHONDONTWRITEBYTECODE=1 timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$K/l_08_hybrid.out" 2>&1 )
/usr/bin/grep -E '^ *🔴 ' "$K/l_08_hybrid.out" | sed -E 's/^ *🔴 +//' | sed -E "s/ {2,}.*//; s/: '.*//; s/ +\$//" > "$T/l_red"
sed 's/^/    red: /' "$T/l_red" | cut -c1-140
same_set "08 over the base's HB_ARMS and verdicts" "$T/l_red" \
    "H4 the proxy holds the cut down" "H4 restored: both up again" "H4 the cut is a cable the package declares" \
    "H4 the cut is down and the kernel accepted it" "H4 restored and the kernel accepted it" \
    "H5 heartbeat on exactly the expected arms" "HB_ARMS names 17 arms, not 20" \
    "HB_ARMS does not name p4runtime/skeleton, p4runtime/solution and flowcache/solution"

echo "== C: HEAD's test_live_p1_common.sh over the base's _common.sh; the 03/04 pins over the base's 03/04"
mkdir -p "$T/cb"; git show "$BASE:$LIVE/_common.sh" > "$T/cb/_common.sh"
cp "$LIVE/venv_fingerprint.sh" "$T/cb/"
COMMON_UNDER_TEST="$T/cb/_common.sh" timeout 1200 bash tests/shell/test_live_p1_common.sh > "$K/c_base_common.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/c_base_common.out" > "$T/c_red"
same_set "base _common.sh" "$T/c_red" \
    "🔴 the raw has 00_venv.txt" "  one block per interpreter (proxy and controllers)" \
    "🔴 naming protobuf and its implementation" "  and the installed set's sha" \
    "🔴 a missing interpreter is written down as such" "🔴 and disclosed above the last line" \
    "🔴 a top-level list: exactly one line" "  a BAD one, naming the cause" \
    "🔴 TERM mid-step: the last verdict line is a FAIL" "🔴 and the step exits 143" \
    "🔴 INT mid-step: FAIL" "🔴 and the step exits 130"
echo "    (round 3, 09-28: section 19's four cells -- INT/TERM fail the step with 130/143 -- are red over every base"
echo "     before fdae10a9; redfirst_b3 sees them red against 14921f98 too)"
W5="['clone_session', 'install_initial_routes', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']"
for step in 03_app_p4runtime 04_diag_p4runtime; do
    n="$(git show "$BASE:$LIVE/$step.sh" | /usr/bin/grep -cF "V=\"\$(heartbeat_skips_verdict \"\$SS0\" \"$W5\")\"")"
    [[ "$n" == 0 ]] && ok "  the base's $step does not ask the verdict (its pin would read 0, want 1: RED)" || nok "  base $step pin = $n"
done

echo "== T: HEAD's test_live_p1_thirteen.sh over the base's 06"
mkdir -p "$T/tb"; git show "$BASE:$LIVE/06_thirteen.sh" > "$T/tb/06_thirteen.sh"; cp "$LIVE/venv_fingerprint.sh" "$T/tb/"
THIRTEEN_UNDER_TEST="$T/tb/06_thirteen.sh" timeout 900 bash tests/shell/test_live_p1_thirteen.sh > "$K/t_base_06.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/t_base_06.out" > "$T/t_red"
same_set "base 06" "$T/t_red" \
    "🔴 the raw records the venv fingerprint of both interpreters" "  the driver's interpreter among them" \
    "  with protobuf's version and implementation"

echo "== E: HEAD's test_live_p1_external_evidence.sh with no tool"
EVIDENCE_UNDER_TEST="$T/no_such_tool.py" timeout 300 bash tests/shell/test_live_p1_external_evidence.sh > "$K/e_no_tool.out" 2>&1
last="$(tail -1 "$K/e_no_tool.out")"
n_ok="$(/usr/bin/grep -c '^  ok ' "$K/e_no_tool.out")"
echo "    $last; $n_ok ok"
/usr/bin/grep '^  ok ' "$K/e_no_tool.out" | sed 's/^/    green without a tool: /'

echo "REDFIRST-B: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"
exit $bad
