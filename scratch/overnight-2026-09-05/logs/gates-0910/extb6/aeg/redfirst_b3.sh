#!/usr/bin/env bash
# redfirst_b3.sh <worktree> <keep dir> -- round 3 (the external judge on 14921f98: M2, M3, S1, S3, m1-m3),
# red first: HEAD's new cells against the code without them (B3_BASE, default 14921f98). Every output
# KEPT. [Co-developed with claude code -- Adam]
#   A  08 self-test in the HB W gate's ltree: over the base's _common.sh (M3's rc and the TERM before
#      arm_traps); over the base's sampler and without v_restore_strict (M2's sampler, F9's red)
#   B  test_live_p1_common over the base's _common.sh (section 19, M3); the 03/04 consumer pins over
#      a 03/04 without the line
#   C  test_heartbeat_fabric over the base's main.py (S1)
#   D  test_ndt_app_package over the base's ndt (S3)
#   E  test_live_p1_external_evidence over the base's external_evidence.py (M2, m1)
#   F  the evidence gate's own coverage report: HEAD's gate without one mutation (E56 until round 4, E66 since
#      round 5) must fail on the check no other mutation turns red, with nothing survived (the report alone)
set -u
WT="$1"; K="$2"; bad=0; BASE="${B3_BASE:-14921f98}"; cd "$WT" || exit 2; mkdir -p "$K"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export KEEP="$K/unexpected"; source "$HERE/redfirst_lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/b3-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
same_set() {   # same_set <label> <got file> <want...>
    local label="$1" got="$2"; shift 2
    local want; want="$(printf '%s\n' "$@" | sort -u)"
    if [[ "$(sort -u "$got")" == "$want" ]]; then ok "$label: exactly the $# expected red"
    else nok "$label: red set differs"; diff <(printf '%s\n' "$want") <(sort -u "$got") | sed 's/^/      /'; fi
}

echo "== A: 08's new cells"
src="$(sed -n '/^ltree() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
run08() {   # run08 <08 copy> <_common copy> <out>
    ( REPO="$WT"; LIVE_DIR_REL="$LIVE"; LIVE08="$WT/$LIVE/08_heartbeat.sh"; eval "$src"
      rm -rf "$T/lt"; ltree "$T/lt"; cp "$1" "$T/lt/$LIVE/08_heartbeat.sh"; cp "$2" "$T/lt/$LIVE/_common.sh"
      cd "$T/lt" && TMPDIR="$T/lt/tmp" PYTHONDONTWRITEBYTECODE=1 timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$3" 2>&1 )
}
reds08() { /usr/bin/grep -E '^ *🔴 ' "$1" | sed -E 's/^ *🔴 +//' | sed -E "s/ {2,}.*//; s/: (header )?'.*//; s/ +\$//"; }
git show "$BASE:$LIVE/_common.sh" > "$T/_common_base.sh"
git show "$BASE:$LIVE/08_heartbeat.sh" > "$T/08_base.sh"
run08 "$LIVE/08_heartbeat.sh" "$T/_common_base.sh" "$K/a_08_common_base.out"; reds08 "$K/a_08_common_base.out" > "$T/r"
same_set "08 over the base's _common.sh (M3)" "$T/r" \
    "TERM mid-H1 with nothing failed before it ended" "a TERM'd run exited 0, not 143" "TERM before arm_traps ended"
/usr/bin/grep -m1 -F "TERM before arm_traps ended" "$K/a_08_common_base.out" | cut -c1-160 | sed 's/^/    base behaviour: /'
python3 - "$LIVE/08_heartbeat.sh" "$T/08_base.sh" "$T/08_m2.sh" <<'PY'
import sys
head, base, out = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
def between(s, a, b):
    i = s.index(a); j = s.index(b, i)
    return s[i:j]
# the base's sampler (header and program), and no v_restore_strict
h = between(head, "SAMPLER_HEADER=", "\nSAMPLER\n)\"")
b = between(base, "SAMPLER_HEADER=", "\nSAMPLER\n)\"")
assert h != b
head = head.replace(h, b)
i = head.index("def v_restore_strict("); j = head.index("\ndef ", i + 1)
head = head[:i] + head[j + 1:]
open(out, "w").write(head)
PY
run08 "$T/08_m2.sh" "$LIVE/_common.sh" "$K/a_08_m2.out"; reds08 "$K/a_08_m2.out" > "$T/r"
same_set "08 with the base's sampler and no v_restore_strict (M2, F9)" "$T/r" \
    "H4 restore 19.9 s is within the strict 20 s" "H5 sampler rows" "🔴 H5 sampler controllers column" \
    "🔴 H5 sampler ctrl_logs column"
echo "    (round 6, M-3: the sampler records the controller logs' sizes -- red over the base's sampler, which has no such column)"
echo "    (round 5, M-3: the sampler records the exercise controllers alive -- red over the base's sampler, which has no such column)"
echo "    (the up-told BAD and table_generation-only cells are green over the base: its v_links and v_no_writes already"
echo "     answer them; L73b and L77 turn them red. The restore's BAD cell is green over a missing verdict; L76 turns it red)"
run08 "$LIVE/08_heartbeat.sh" "$LIVE/_common.sh" "$K/a_08_head.out"
[[ "$(tail -1 "$K/a_08_head.out")" == "SELF-TEST PASS" ]] && ok "  HEAD's own 08 and _common.sh in the same tree: SELF-TEST PASS" || nok "  HEAD's 08 is not green"

echo "== B: test_live_p1_common over the base's _common.sh (M3), and the 03/04 consumer pins"
mkdir -p "$T/cb"; cp "$T/_common_base.sh" "$T/cb/_common.sh"; cp "$LIVE/venv_fingerprint.sh" "$T/cb/"
COMMON_UNDER_TEST="$T/cb/_common.sh" timeout 1500 bash tests/shell/test_live_p1_common.sh > "$K/b_common_base.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/b_common_base.out" > "$T/r"
same_set "base _common.sh" "$T/r" "🔴 TERM mid-step: the last verdict line is a FAIL" "🔴 and the step exits 143" \
    "🔴 INT mid-step: FAIL" "🔴 and the step exits 130"
W5="['clone_session', 'install_initial_routes', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']"
for step in 03_app_p4runtime 04_diag_p4runtime; do
    sed '/^    \[\[ "\$V" == OK\* \]\] || fail "\${V#BAD }"$/d' "$LIVE/$step.sh" > "$T/$step.noconsumer.sh"
    got="$(/usr/bin/grep -A1 -F "V=\"\$(heartbeat_skips_verdict \"\$SS0\" \"$W5\")\"" "$T/$step.noconsumer.sh" | sed -n 2p)"
    [[ "$got" != '    [[ "$V" == OK* ]] || fail "${V#BAD }"' ]] && ok "  $step without its consumer line: the pin reads '${got:0:50}' (RED)" || nok "  $step pin green without the consumer"
done

echo "== C: test_heartbeat_fabric over the base's main.py (S1)"
lo="$(sed -n '/^lay_out() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
P="$T/px"; mkdir -p "$P"
( REPO="$WT"; HELPER="$WT/tools/test_workflow/ndtwin-lab"; eval "$lo"; lay_out "$P" )
PYV="$(readlink -f "$WT/p4_proxy/venv")/bin/python"
git show "$BASE:p4_proxy/proxy_agent/main.py" > "$P/p4_proxy/proxy_agent/main.py"
( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
    timeout 300 "$PYV" -m unittest -v tests.test_heartbeat_fabric > "$K/c_base_main.out" 2>&1 )
sed -n -E 's/^(FAIL|ERROR): ([^ ]+) .*/\2/p' "$K/c_base_main.out" > "$T/r"
same_set "base main.py" "$T/r" test_the_census_names_the_punt_blind_spot_on_external_control_planes \
    "test_an_external_fabric_serves_no_path_over_its_declared_links" \
    "test_startup_marks_an_external_fabric_on_its_own_pipeline_only" \
    "test_the_census_says_which_of_its_arms_ndt_up_starts_the_heartbeat_on"
echo "    (added at round 4, 09-28: the destination-path cells of test_heartbeat_fabric and its census cell's drop-check sentence -- red over every older base for that reason)"

echo "== D: test_ndt_app_package over the base's ndt (S3)"
mkdir -p "$T/ndt/tools/test_workflow"
git show "$BASE:tools/test_workflow/ndt" > "$T/ndt/tools/test_workflow/ndt"
for f in tools/test_workflow/*; do [[ -f "$f" && "$(basename "$f")" != ndt ]] && cp "$f" "$T/ndt/tools/test_workflow/"; done
NDT_UNDER_TEST="$T/ndt/tools/test_workflow/ndt" timeout 1500 bash tests/shell/test_ndt_app_package.sh > "$K/d_base_ndt.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/d_base_ndt.out" > "$T/r"
same_set "base ndt" "$T/r" "🔴 a package fabric is told the count is not a reading" \
    "🔴 an external plane on its own pipeline expects no path" \
    "🔴 its own pid with a start it never had is DEAD, not alive" \
    "🔴 a nonzero count on an external plane is flagged" "🔴 and is a --check problem" \
    "  so --check exits 1 on it" "  zero paths on an external plane: the designed answer"
echo "    (round 5, the nit: a path count on an external plane is flagged; zero is quiet -- red over every base before round 5, whose status row has neither)"
echo "    (added at round 4, 09-28: the external no-path status cell; and trunk 08f67b7a's emitter-liveness cell, red over any ndt before that merge -- red over every older base for that reason)"

echo "== E: test_live_p1_external_evidence over the base's tool (M2, m1)"
git show "$BASE:$LIVE/external_evidence.py" > "$T/ee_base.py"
EVIDENCE_UNDER_TEST="$T/ee_base.py" timeout 600 bash tests/shell/test_live_p1_external_evidence.sh > "$K/e_base_tool.out" 2>&1
echo "    $(tail -1 "$K/e_base_tool.out")"
for c in "🔴 no --samples: rc 3" "🔴 no --control2: rc 3" "🔴 --control2 that is the control itself: rc 3" \
         "🔴 a control with the detect-only line and a heartbeat block, N5 STALE: rc 3" \
         "🔴 a second control with only a heartbeat block: rc 3" \
         "🔴 a session sampled running, then stopped before the controller: rc 3" \
         "🔴 a stale 'running' left by a killed daemon: rc 3" "🔴 a second session inside the arm window: rc 3" \
         "🔴 a stretch of the session with no sample: rc 3" "🔴 a session that stopped and ran again: rc 3" \
         "🔴 a session whose daemon counted a frame to a host: rc 1" "🔴 a session that forwarded between switches: rc 1" \
         "🔴 N4's counters are labelled as before the pipeline" \
         "  said as not settled" "  said as a sampler from before round 6" \
         "🔴 a treatment also given as a control: refused as such"; do
    /usr/bin/grep -qF "FAILED   $c" "$K/e_base_tool.out" && ok "  base tool: '$c' RED" || nok "  base tool: '$c' not red"
done
echo "    (round 5: every compare in HEAD's suite names --b-sha, which this base does not take -- it answers usage, rc 2."
echo "     So the cells that only read an rc 2 are green over it by accident: 'a last counter block that had not settled',"
echo "     'an IPv4 packet-in shorter than its header', 'samples from a sampler before 09-28', 'samples without 06's end"
echo "     beside them'. The first and third are asked through their reason cells instead; the other two have none, and"
echo "     their red is the evidence gate's coverage report. 'broken in the second control only' is gone: round 5 made"
echo "     that invariant descriptive, and a decisive one broken in a control is UNDECIDED.)"
echo "    cells green over the base tool (guards of what it already did; the evidence gate's coverage report"
echo "    shows every check of the suite red under some mutation -- F checks that report can fail):"
/usr/bin/grep '^  ok ' "$K/e_base_tool.out" | sed 's/^/      /'

echo "== F: the evidence gate's coverage report, red on its own"
G="$T/gate_noE56"; mkdir -p "$G/tests/shell" "$G/$LIVE"
python3 - tests/shell/mutate_live_p1_external_evidence.sh "$G/tests/shell/mutate_live_p1_external_evidence.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
# [Co-developed with claude code -- Adam] round 5: no single mutation is any more the only one to reach some
# check (E56, then E66, were tried: 151/151 stayed red without either -- E65 and E69 refuse every arm and turn
# most cells red). So the gate keeps ONE mutation, E1: it is caught, nothing survives, and the coverage report
# alone must turn the gate red (rc 1) on the checks no mutation reached.
i = s.index("mutate '            \"heartbeat_packet_ins\", \"non_ipv4_packet_ins\", \"grpc_errors\")'")
j = s.index("\nmutate ", i + 1)
assert "E1:" in s[i:j]
end = s.index("\necho\nNOW_SUM=")
head = s[:s.index("# [Co-developed with claude code -- Adam] Rewritten 09-28 with the tool")]
# the mutate_id function definition sits among the calls; keep every function body, drop every other call
calls = s[j + 1:end]
# (round 6: and the mutate_sv function, the survey's)
keep = "\n".join("mutate" + blk for blk in calls.split("\nmutate") if blk.startswith(("_id() {", "_sv() {"))).strip()
out = head + s[i:j] + ("\n" + keep if keep else "") + s[end:]
assert out.count("\nmutate '") + out.count("\nmutate_id '") + out.count("\nmutate_sv '") == 1, out.count("\nmutate '")
open(sys.argv[2], "w").write(out)
PY
cp tests/shell/test_live_p1_external_evidence.sh "$G/tests/shell/"; cp "$LIVE/external_evidence.py" "$LIVE/code_identity.py" "$G/$LIVE/"
cp "$LIVE/external_survey.py" "$LIVE/external_survey_34.tsv" "$G/$LIVE/"   # round 6: the survey beside the tool
( cd "$G" && timeout 1500 bash tests/shell/mutate_live_p1_external_evidence.sh ) > "$K/f_gate_noE56.out" 2>&1; frc=$?
/usr/bin/grep -E "^mutation gate|^every check seen red|NEVER RED" "$K/f_gate_noE56.out" | sed 's/^/    /'
nev="$(/usr/bin/grep -c 'NEVER RED' "$K/f_gate_noE56.out")"
if [[ $frc == 1 ]] && /usr/bin/grep -q "^mutation gate: 1 mutations, 0 survived\$" "$K/f_gate_noE56.out" && (( nev >= 1 )); then
    ok "the gate with E1 alone: rc 1 with 0 survived, on its $nev never-red line(s) -- the coverage report alone (RED)"
else nok "the gate with E1 alone: rc $frc, $nev never-red line(s)"; fi

echo "REDFIRST-B3: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"
exit $bad
