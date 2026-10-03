#!/usr/bin/env bash
# redfirst_b4.sh <worktree> <keep dir> -- round 4 (Adam's 09-28 ruling: no guessed destination paths on
# an external control plane; the heartbeat there only after the drop check), red first: HEAD's new
# cells against the code without them (B4_BASE, default 35b19663 -- round 3's head merged with trunk
# 08f67b7a, before round 4's commits). Every output KEPT. [Co-developed with claude code -- Adam]
#   A  test_heartbeat_fabric over the base's main.py, topology_manager.py and api_routes.py
#   B  test_ndt_app_package over the base's ndt (the status row)
#   C  test_ndt_heartbeat over the base's ndt (the drop check's wiring)
#   D  test_heartbeat_drop_check.py with no tool: it must fail, not pass (the tool is new; each of its
#      cells is seen red by mutate_heartbeat_drop_check.sh)
set -u
WT="$1"; K="$2"; bad=0; BASE="${B4_BASE:-35b19663}"; cd "$WT" || exit 2; mkdir -p "$K"
T=$(mktemp -d "${TMPDIR:-/tmp}/b4-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
same_set() {   # same_set <label> <got file> <want...>
    local label="$1" got="$2"; shift 2
    local want; want="$(printf '%s\n' "$@" | sort -u)"
    if [[ "$(sort -u "$got")" == "$want" ]]; then ok "$label: exactly the $# expected red"
    else nok "$label: red set differs"; diff <(printf '%s\n' "$want") <(sort -u "$got") | sed 's/^/      /'; fi
}

echo "== A: test_heartbeat_fabric over the base's proxy (item 1, and item 2's census text)"
lo="$(sed -n '/^lay_out() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
P="$T/px"; mkdir -p "$P"
( REPO="$WT"; HELPER="$WT/tools/test_workflow/ndtwin-lab"; eval "$lo"; lay_out "$P" )
PYV="$(readlink -f "$WT/p4_proxy/venv")/bin/python"
for f in main.py topology_manager.py api_routes.py; do
    git show "$BASE:p4_proxy/proxy_agent/$f" > "$P/p4_proxy/proxy_agent/$f"
done
( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
    timeout 300 "$PYV" -m unittest -v tests.test_heartbeat_fabric > "$K/a_base_proxy.out" 2>&1 )
sed -n -E 's/^(FAIL|ERROR): ([^ ]+) .*/\2/p' "$K/a_base_proxy.out" > "$T/r"
same_set "base proxy" "$T/r" \
    test_startup_marks_an_external_fabric_on_its_own_pipeline_only \
    test_an_external_fabric_serves_no_path_over_its_declared_links \
    test_a_cut_on_an_external_fabric_pushes_no_path \
    test_the_census_says_which_of_its_arms_ndt_up_starts_the_heartbeat_on \
    test_the_census_names_the_punt_blind_spot_on_external_control_planes
echo "    (green over the base, and why: 'the declared links still seed the graph' guards what the base did"
echo "     (X1 kills it); 'the same graph without the flag does have a path' is the control (X14 kills it))"
for f in main.py topology_manager.py api_routes.py; do cp "$WT/p4_proxy/proxy_agent/$f" "$P/p4_proxy/proxy_agent/$f"; done
( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
    timeout 300 "$PYV" -m unittest tests.test_heartbeat_fabric > "$K/a_head_proxy.out" 2>&1 )
/usr/bin/grep -q '^OK' "$K/a_head_proxy.out" && ok "  HEAD's proxy in the same tree: OK" || nok "  HEAD's proxy is not green"

echo "== B: test_ndt_app_package over the base's ndt (item 1's status row)"
mkdir -p "$T/ndt/tools/test_workflow"
git show "$BASE:tools/test_workflow/ndt" > "$T/ndt/tools/test_workflow/ndt"
for f in tools/test_workflow/*; do [[ -f "$f" && "$(basename "$f")" != ndt ]] && cp "$f" "$T/ndt/tools/test_workflow/"; done
NDT_UNDER_TEST="$T/ndt/tools/test_workflow/ndt" timeout 1500 bash tests/shell/test_ndt_app_package.sh > "$K/b_base_ndt.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/b_base_ndt.out" > "$T/r"
same_set "base ndt, the status row" "$T/r" "🔴 an external plane on its own pipeline expects no path" \
    "  and does not call its count the twin's guess" \
    "🔴 a nonzero count on an external plane is flagged" "🔴 and is a --check problem" \
    "  so --check exits 1 on it" "  zero paths on an external plane: the designed answer"
echo "    (round 5, the nit: a path count on an external plane is flagged; zero is quiet -- red over every base before round 5, whose status row has neither)"

echo "== C: test_ndt_heartbeat over the base's ndt (item 2's wiring)"
NDT_UNDER_TEST="$T/ndt/tools/test_workflow/ndt" timeout 1500 bash tests/shell/test_ndt_heartbeat.sh > "$K/c_base_ndt.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/c_base_ndt.out" > "$T/r"
same_set "base ndt, the drop check" "$T/r" \
    "🔴 the check ran once, on the package" "🔴 before anything touched the machine" \
    "  the check's answer is said, in one line" "  and the whole of it is kept, in the log the line names" "  and this one's says what this check said" \
    "🔴 a second bring-up keeps its own log: the first one's is still there" "  in another file" \
    "🔴 and the heartbeat is NOT started" "🔴 saying so" "  with the check's own reason" \
    "🔴 and the record names it for 'ndt status'" \
    "🔴 could not tell: NOT started either (unknown is not a drop)" "  saying it could not tell" "  and why" \
    "🔴 a check that never ran is not proof: NOT started" "  saying so" \
    "🔴 a later bring-up that starts it clears the record" "🔴 'ndt down' clears it with the fabric" \
    "🔴 a heartbeat the last bring-up withheld is said, with why"
echo "    (round 5, S-5: one drop-check log per bring-up -- 'the whole of it is kept' is now '... in the log the line names', and three cells pin a second bring-up's own log; red over every base before round 5)"
echo "    (green over the base, each a guard of what the base already did, killed by the gate's N mutant:"
echo "     'proven dropped: the heartbeat starts' N43, 'nothing is recorded as withheld' N43, 'NOT dropped: the"
echo "     bring-up still succeeds' N45, 'the proxy and kernel were still started' N45, the not-external and"
echo "     NDTwin-pipeline cells N50/N50b/N51, 'and not when there is no record' N55)"

echo "== D: test_heartbeat_drop_check.py with no tool"
CHECK_UNDER_TEST="$T/no_such_tool.py" timeout 300 python3 tests/shell/test_heartbeat_drop_check.py > "$K/d_no_tool.out" 2>&1; drc=$?
(( drc != 0 )) && ok "  without the tool the suite fails (rc $drc): $(tail -1 "$K/d_no_tool.out" | cut -c1-100)" \
               || nok "  the suite passed without the tool"
echo "    (the tool is new: each of its cells is seen red one by one by mutate_heartbeat_drop_check.sh)"

echo "REDFIRST-B4: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"
exit $bad
