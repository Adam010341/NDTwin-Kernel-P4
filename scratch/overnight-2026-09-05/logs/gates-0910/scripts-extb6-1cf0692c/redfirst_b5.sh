#!/usr/bin/env bash
# redfirst_b5.sh <worktree> <keep dir> -- round 5 (the round-4 review's M-1..M-4, S-1..S-9 on faf6eb41),
# red first: HEAD's new cells against round 4's code (B5_BASE, default faf6eb41). Every output KEPT.
# [Co-developed with claude code -- Adam]
#   A  test_heartbeat_drop_check.py over the base's heartbeat_drop_check.py (S-4, S-6, M-4's argv cells)
#   B  test_ndt_heartbeat over the base's ndt (S-5: one drop-check log per bring-up)
#   C  test_ndt_app_package over the base's ndt (the nit: a path count on an external plane)
#   D  test_heartbeat_fabric over the base's main.py (S-2, S-3: the census text)
#   E  test_live_p1_thirteen over the base's 06 (M-2: 06 records its code identity)
#   F  test_l1_shell_scoring over the base's l1_unit_tests.sh (S-8)
#   G  test_live_p1_external_evidence over the base's external_evidence.py (M-2, M-3, S-9: the base
#      takes no --b-sha, so nearly every cell is red -- degenerate; each cell's own red is the
#      evidence gate's coverage report)
#   (08's new self-test cases -- M-1's prelude refusal and C1 shape, M-3's sampler columns, M-2's
#    identity gate -- are seen red by mutate_p4_heartbeat_w's L79-L85, each on its named case.)
set -u
WT="$1"; K="$2"; bad=0; BASE="${B5_BASE:-faf6eb41}"; cd "$WT" || exit 2; mkdir -p "$K"
T=$(mktemp -d "${TMPDIR:-/tmp}/b5-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
same_set() {   # same_set <label> <got file> <want...>
    local label="$1" got="$2"; shift 2
    local want; want="$(printf '%s\n' "$@" | sort -u)"
    if [[ "$(sort -u "$got")" == "$want" ]]; then ok "$label: exactly the $(wc -l <<<"$want") expected red"
    else nok "$label: red set differs"; diff <(printf '%s\n' "$want") <(sort -u "$got") | sed 's/^/      /'; fi
}
reds() { sed -n 's/^  FAILED   //p' "$1" | sed 's/[[:space:]]*$//'; }

echo "== A: test_heartbeat_drop_check.py over the base's tool"
mkdir -p "$T/a/tools/test_workflow"; ln -s "$WT/p4_proxy" "$T/a/p4_proxy"
git show "$BASE:tools/test_workflow/heartbeat_drop_check.py" > "$T/a/tools/test_workflow/heartbeat_drop_check.py"
CHECK_UNDER_TEST="$T/a/tools/test_workflow/heartbeat_drop_check.py" timeout 900 python3 tests/shell/test_heartbeat_drop_check.py > "$K/a_base_tool.out" 2>&1
reds "$K/a_base_tool.out" > "$T/r"
same_set "base tool" "$T/r" '🔴 a crash of the check is rc 2' \
    '🔴 a fabric binary that answers no version: rc 2' \
    '🔴 a fabric on another bmv2 version: rc 2' \
    '🔴 and a launch as root is refused' \
    '  and it is one short line (06 keeps 6000 characters of `ndt up`)' \
    '🔴 and its heartbeat is NOT started' \
    '🔴 and its switch is gone' \
    '  and so is its directory' \
    '🔴 a package whose switches the model gives no port: rc 3' \
    '🔴 a program with no data port to inject on: not dropped-by-default' \
    "🔴 a --version run's comm is ndt-hbdrop-bmv2 too (bmv2_count counts comm)" \
    '🔴 end to end: a package whose program floods it -- NOT dropped, said' \
    "🔴 end to end: the converted p4runtime package's one-line answer" \
    "🔴 its comm is not a switch's either" \
    '🔴 its own modules missing: rc 2' \
    "🔴 main() SIGTERM'd mid-check: rc 143" \
    '  naming both versions' \
    '  no throwaway switch is left there either' \
    '🔴 no throwaway switch is left when the fabric starts' \
    '🔴 run as root (euid 0): rc 2' \
    '  saying it crashed' \
    '  saying it refuses' \
    '  saying nothing was asked' \
    '  saying there is no frame to inject' \
    '  saying the two are not the same switch' \
    '  saying what it could not load' \
    "🔴 the fabric's binary is p4_testbed_topo's override when nothing overrides it" \
    '🔴 the heartbeat is asked to start, once' \
    '  the record names what it did' \
    '  (the switch was found running before the signal)' \
    "  the whole answer is in the bring-up's own log, named on the line"
echo "    (red over the base for want of what round 5 added -- the version check, fabric_binary, rc 2 on a crash, the"
echo "     root refusal, comm through a link, no-port refusal; the SIGTERM and end-to-end cells are NOT RUN there, as"
echo "     the base has no fabric_binary for section 7 to vet -- degenerate, so their own reds are the gate's D41, NE1-NE3,"
echo "     D1, D27. Green over the base, and why: the recorder's argv cells, settled()'s cells, the tripwire-conditions"
echo "     and every-launch cells guard what the base already did right; each is red under a D mutant (the gate's"
echo "     coverage report, every non-control check seen red)"
timeout 900 python3 tests/shell/test_heartbeat_drop_check.py > "$K/a_head_tool.out" 2>&1 \
    && ok "  HEAD's tool: $(tail -1 "$K/a_head_tool.out")" || nok "  HEAD's tool is not green: $(tail -1 "$K/a_head_tool.out")"

mkdir -p "$T/ndt/tools/test_workflow"
git show "$BASE:tools/test_workflow/ndt" > "$T/ndt/tools/test_workflow/ndt"
for f in tools/test_workflow/*; do [[ -f "$f" && "$(basename "$f")" != ndt ]] && cp "$f" "$T/ndt/tools/test_workflow/"; done
echo "== B: test_ndt_heartbeat over the base's ndt"
NDT_UNDER_TEST="$T/ndt/tools/test_workflow/ndt" timeout 1500 bash tests/shell/test_ndt_heartbeat.sh > "$K/b_base_ndt.out" 2>&1
reds "$K/b_base_ndt.out" > "$T/r"
same_set "base ndt, the drop check's log" "$T/r" '  and the whole of it is kept, in the log the line names' \
    "  and this one's says what this check said" \
    "🔴 a second bring-up keeps its own log: the first one's is still there" \
    '  in another file' \
    "  the check's answer is said, in one line"

echo "== C: test_ndt_app_package over the base's ndt"
NDT_UNDER_TEST="$T/ndt/tools/test_workflow/ndt" timeout 1500 bash tests/shell/test_ndt_app_package.sh > "$K/c_base_ndt.out" 2>&1
reds "$K/c_base_ndt.out" > "$T/r"
same_set "base ndt, the external path count" "$T/r" '🔴 and is a --check problem' \
    '🔴 a nonzero count on an external plane is flagged' \
    '  so --check exits 1 on it'

echo "== D: test_heartbeat_fabric over the base's main.py"
lo="$(sed -n '/^lay_out() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
P="$T/px"; mkdir -p "$P"
( REPO="$WT"; HELPER="$WT/tools/test_workflow/ndtwin-lab"; eval "$lo"; lay_out "$P" )
PYV="$(readlink -f "$WT/p4_proxy/venv")/bin/python"
git show "$BASE:p4_proxy/proxy_agent/main.py" > "$P/p4_proxy/proxy_agent/main.py"
( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
    timeout 300 "$PYV" -m unittest -v tests.test_heartbeat_fabric > "$K/d_base_proxy.out" 2>&1 )
sed -n -E 's/^(FAIL|ERROR): ([^ ]+) .*/\2/p' "$K/d_base_proxy.out" > "$T/r"
same_set "base proxy, the census" "$T/r" test_the_census_names_the_punt_blind_spot_on_external_control_planes

echo "== E: test_live_p1_thirteen over the base's 06"
mkdir -p "$T/e"
git show "$BASE:doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/06_thirteen.sh" > "$T/e/06_thirteen.sh"
cp doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/venv_fingerprint.sh doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/code_identity.py "$T/e/"
THIRTEEN_UNDER_TEST="$T/e/06_thirteen.sh" timeout 900 bash tests/shell/test_live_p1_thirteen.sh > "$K/e_base_06.out" 2>&1
reds "$K/e_base_06.out" > "$T/r"
same_set "base 06" "$T/r" "🔴 the raw records the code identity as 06 starts" "🔴 and again as it ends, after the last round wrote its table row"
echo "    (round 6, M-2: 06 records its identity as it starts and as it ends -- the one round-5 cell is now two, red over every base before round 6)"

echo "== F: test_l1_shell_scoring over the base's l1_unit_tests.sh"
mkdir -p "$T/f/tools/test_workflow" "$T/f/tests/shell/fixtures"
git show "$BASE:tools/test_workflow/l1_unit_tests.sh" > "$T/f/tools/test_workflow/l1_unit_tests.sh"
cp tools/test_workflow/components.env "$T/f/tools/test_workflow/"
cp tests/shell/test_*.sh tests/shell/test_*.py "$T/f/tests/shell/"; cp -r tests/shell/fixtures/l1_shell_scoring "$T/f/tests/shell/fixtures/"
timeout 600 bash "$T/f/tests/shell/test_l1_shell_scoring.sh" > "$K/f_base_l1.out" 2>&1
reds "$K/f_base_l1.out" > "$T/r"
same_set "base l1" "$T/r" 'D18 the lane probes the needs it can excuse (ryu, py-plot, bmv2-stock)' \
    "D19 the dispatch hands the lane's own excuse and the hosted flag to the verdict" \
    'D22 every NDTWIN_L1_NEEDS in tests/shell and tests/python is one the lane probes' \
    'D27 🔴 the lane collects tests/shell/test_*.py' \
    'D28 🔴 and scores them as shell suites (their summary and SKIP: lines), run by python3' \
    'X0 the scoring dispatch was located, so X1-X4 are not asking about an empty string' \
    "X3 the Python arm still counts with unittest's '^Ran N' (the __main__-guard catch)"

echo "== G: test_live_p1_external_evidence over the base's tool"
git show "$BASE:doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_evidence.py" > "$T/external_evidence.py"
EVIDENCE_UNDER_TEST="$T/external_evidence.py" timeout 600 bash tests/shell/test_live_p1_external_evidence.sh > "$K/g_base_ev.out" 2>&1
n="$(reds "$K/g_base_ev.out" | wc -l)"; tot="$(sed -n 's/^Ran \([0-9]*\) checks.*/\1/p' "$K/g_base_ev.out")"
(( n > 0 )) && ok "  the base tool fails $n of ${tot:-?} cells (degenerate: no --b-sha; the evidence gate's coverage report is each cell's red)" \
            || nok "  the base tool passed HEAD's suite"
for want in "🔴 every direction heard in the controller's window, said per direction" "🔴 no --b-sha: rc 3" \
            "🔴 a treatment merged onto another trunk: rc 3" "  and in the conclusion"; do
    reds "$K/g_base_ev.out" | /usr/bin/grep -qxF -- "$want" && ok "  red: $want" || nok "  green on the base: $want"
done

echo "    (round 6, M-3: the heard cells are now about the controller's own window; the one named here is a"
echo "     has-check, red over this base, which answers usage to every compare)"
echo "REDFIRST-B5: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"
exit $bad
