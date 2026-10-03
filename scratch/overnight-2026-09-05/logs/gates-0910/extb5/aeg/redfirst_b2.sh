#!/usr/bin/env bash
# redfirst_b2.sh <worktree> <keep dir> -- the round after the judges on 17e40e29 (external) and f7e2a128
# (AEG), red first: HEAD's new cells against the code without them (B2_BASE, default 17e40e29).
# Every output KEPT. [Co-developed with claude code -- Adam]
#   A  08 self-test in the HB W gate's ltree, one hybrid per fix: INT/TERM back on w_finish (N-1),
#      the base's v_strict (N-4), the base's v_links without v_no_writes (F4)
#   B  test_live_p1_common over the base's _common.sh (N-5); 02's consumer pin over a 02 without it
#   C  test_heartbeat_fabric over the base's main.py (F3/F6 census cells)
#   D  test_ndt_heartbeat over the base's ndt (F5's failure-reason cell)
#   E  test_live_p1_external_evidence over the base's external_evidence.py (F1/F2/F7)
set -u
WT="$1"; K="$2"; bad=0; BASE="${B2_BASE:-17e40e29}"; cd "$WT" || exit 2; mkdir -p "$K"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export KEEP="$K/unexpected"; source "$HERE/redfirst_lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/b2-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
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

echo "== A: 08's new cells, one hybrid per fix"
src="$(sed -n '/^ltree() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
run08() {   # run08 <08 copy> <out>
    ( REPO="$WT"; LIVE_DIR_REL="$LIVE"; LIVE08="$WT/$LIVE/08_heartbeat.sh"; eval "$src"
      rm -rf "$T/lt"; ltree "$T/lt"; cp "$1" "$T/lt/$LIVE/08_heartbeat.sh"
      cd "$T/lt" && TMPDIR="$T/lt/tmp" PYTHONDONTWRITEBYTECODE=1 timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$2" 2>&1 )
}
reds08() { /usr/bin/grep -E '^ *🔴 ' "$1" | sed -E 's/^ *🔴 +//' | sed -E "s/ {2,}.*//; s/: '.*//; s/ +\$//"; }
git show "$BASE:$LIVE/08_heartbeat.sh" > "$T/08_base.sh"
python3 - "$LIVE/08_heartbeat.sh" "$T/08_base.sh" "$T" <<'PY'
import re, sys
head, base, t = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
def fn(s, start):
    i = s.index(start); j = s.index("\ndef ", i + 1)
    return s[i:j + 1]
# N-1: INT/TERM back on w_finish
# (round 3: the handler is _common.sh's `interrupted` now, w_interrupted is gone)
a = head.replace("arm_traps() { trap w_finish EXIT; trap 'interrupted SIGINT 130' INT; trap 'interrupted SIGTERM 143' TERM; }",
                 "arm_traps() { trap w_finish EXIT INT TERM; }")
assert a != head; open(f"{t}/08_n1.sh", "w").write(a)
# N-4: the base's v_strict
b = head.replace(fn(head, "def v_strict("), fn(base, "def v_strict("))
assert b != head; open(f"{t}/08_n4.sh", "w").write(b)
# F4: the base's v_links, and no v_no_writes
c = head.replace(fn(head, "def v_links("), fn(base, "def v_links("))
c = c.replace(fn(c, "def v_no_writes("), "")
assert c != head; open(f"{t}/08_f4.sh", "w").write(c)
PY
run08 "$T/08_n1.sh" "$K/a_08_n1.out"; reds08 "$K/a_08_n1.out" > "$T/r"
same_set "08, INT/TERM on w_finish (N-1)" "$T/r" "TERM mid-H1 with nothing failed before it ended" \
    "a TERM'd run exited 0, not 143"
echo "    (round 3: the rc cell is new -- M3 carries 143 through finish; red here because w_finish exits the verdict's 0)"
/usr/bin/grep -m1 -F "TERM mid-H1 with nothing failed" "$K/a_08_n1.out" | cut -c1-200 | sed 's/^/    base behaviour: /'
run08 "$T/08_n4.sh" "$K/a_08_n4.out"; reds08 "$K/a_08_n4.out" > "$T/r"
same_set "08, the base's v_strict (N-4)" "$T/r" "strict 36 s is past the 35 s ceiling: a FAIL"
run08 "$T/08_f4.sh" "$K/a_08_f4.out"; reds08 "$K/a_08_f4.out" > "$T/r"
same_set "08, the base's v_links and no v_no_writes (F4)" "$T/r" \
    "H4 the cut is down and the kernel accepted it" "H4 nothing written across the cut" \
    "H4 up at the proxy, not accepted by the kernel"
echo "    (round 3: 'H4 up at the proxy, not accepted by the kernel' is new (m3) and red here -- the base's v_links"
echo "     answers OK for an up with reported_to_kernel False; L73b turns it red against HEAD's)"
echo "    (the base's v_links answers BAD for a want it does not know, so the two BAD cells and the up-told OK cell"
echo "     are green there; L73, L74 and L75 are what turn each of them red)"
run08 "$LIVE/08_heartbeat.sh" "$K/a_08_head.out"
[[ "$(tail -1 "$K/a_08_head.out")" == "SELF-TEST PASS" ]] && ok "  HEAD's own 08 in the same tree: SELF-TEST PASS" || nok "  HEAD's own 08 is not green"
echo "    (the H3 cut-short, all-within and clean-run cells guard what the base already does -- F1 of the AEG round is in it; L69, L70 and L72 kill them)"

echo "== B: test_live_p1_common over the base's _common.sh (N-5), and 02's consumer pin"
mkdir -p "$T/cb"; git show "$BASE:$LIVE/_common.sh" > "$T/cb/_common.sh"; cp "$LIVE/venv_fingerprint.sh" "$T/cb/"
COMMON_UNDER_TEST="$T/cb/_common.sh" timeout 1200 bash tests/shell/test_live_p1_common.sh > "$K/b_common_base.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/b_common_base.out" > "$T/r"
same_set "base _common.sh" "$T/r" "🔴 a top-level list: exactly one line" "  a BAD one, naming the cause" \
    "🔴 TERM mid-step: the last verdict line is a FAIL" "🔴 and the step exits 143" \
    "🔴 INT mid-step: FAIL" "🔴 and the step exits 130"
echo "    (round 3: section 19's four cells are red over every base before fdae10a9)"
sed '/^    \[\[ "\$V" == OK\* \]\] || fail "\${V#BAD }"$/d' "$LIVE/02_app_basic.sh" > "$T/02_noconsumer.sh"
got="$(/usr/bin/grep -A1 '^    V="$(heartbeat_skips_verdict "$SS" "$FABRIC_SKIPS_HB")"$' "$T/02_noconsumer.sh" | sed -n 2p)"
[[ "$got" != '    [[ "$V" == OK* ]] || fail "${V#BAD }"' ]] && ok "  02 without its consumer line: the pin reads '${got:0:60}', not the consumer (RED)" || nok "  the pin still green without the consumer"

echo "== C: test_heartbeat_fabric over the base's main.py (F3/F6)"
lo="$(sed -n '/^lay_out() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
P="$T/px"; mkdir -p "$P"
( REPO="$WT"; HELPER="$WT/tools/test_workflow/ndtwin-lab"; eval "$lo"; lay_out "$P" )
PYV="$(readlink -f "$WT/p4_proxy/venv")/bin/python"
git show "$BASE:p4_proxy/proxy_agent/main.py" > "$P/p4_proxy/proxy_agent/main.py"
( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
    timeout 300 "$PYV" -m unittest -v tests.test_heartbeat_fabric > "$K/c_base_main.out" 2>&1 )
sed -n -E 's/^(FAIL|ERROR): ([^ ]+) .*/\2/p' "$K/c_base_main.out" > "$T/r"
same_set "base main.py" "$T/r" test_the_census_says_which_of_its_arms_ndt_up_starts_the_heartbeat_on \
    test_the_census_names_the_punt_blind_spot_on_external_control_planes \
    "test_an_external_fabric_serves_no_path_over_its_declared_links" \
    "test_startup_marks_an_external_fabric_on_its_own_pipeline_only"
echo "    (added at round 4, 09-28: the destination-path cells of test_heartbeat_fabric -- red over every older base for that reason)"

echo "== D: test_ndt_heartbeat over the base's ndt (F5)"
mkdir -p "$T/ndt/tools/test_workflow"
git show "$BASE:tools/test_workflow/ndt" > "$T/ndt/tools/test_workflow/ndt"
for f in tools/test_workflow/*; do [[ -f "$f" && "$(basename "$f")" != ndt ]] && cp "$f" "$T/ndt/tools/test_workflow/"; done
NDT_UNDER_TEST="$T/ndt/tools/test_workflow/ndt" timeout 900 bash tests/shell/test_ndt_heartbeat.sh > "$K/d_base_ndt.out" 2>&1
sed -n 's/^  FAILED   //p' "$K/d_base_ndt.out" > "$T/r"
same_set "base ndt" "$T/r" "🔴 a failed start on an external plane names external_control_plane" \
    "  and not the reason a foreign fabric serves" \
    "🔴 a check that never ran is not proof: NOT started" \
    "🔴 a heartbeat the last bring-up withheld is said, with why" \
    "🔴 a later bring-up that starts it clears the record" \
    "🔴 and the heartbeat is NOT started" \
    "🔴 and the record names it for 'ndt status'" \
    "  and the whole of it is kept, in the log the line names" "  and this one's says what this check said" \
    "🔴 a second bring-up keeps its own log: the first one's is still there" "  in another file" \
    "  and why" \
    "🔴 before anything touched the machine" \
    "🔴 could not tell: NOT started either (unknown is not a drop)" \
    "🔴 'ndt down' clears it with the fabric" \
    "  saying it could not tell" \
    "  saying so" \
    "🔴 saying so" \
    "🔴 the check ran once, on the package" \
    "  the check's answer is said, in one line" \
    "  with the check's own reason"
echo "    (round 5, S-5: one drop-check log per bring-up -- 'the whole of it is kept' is now '... in the log the line names', and three cells pin a second bring-up's own log; red over every base before round 5)"
echo "    (added at round 4, 09-28: test_ndt_heartbeat's drop-check cells (section 2c and the withheld row) -- red over every older base for that reason)"

echo "== E: test_live_p1_external_evidence over the base's tool (F1/F2/F7)"
git show "$BASE:$LIVE/external_evidence.py" > "$T/ee_base.py"
EVIDENCE_UNDER_TEST="$T/ee_base.py" timeout 300 bash tests/shell/test_live_p1_external_evidence.sh > "$K/e_base_tool.out" 2>&1
echo "    $(tail -1 "$K/e_base_tool.out")"
# Round 3 (09-28) rewrote the suite (M2): the round-2 cells are checked under the names they have now. Every
# `compare` in it passes --samples and a second --control2, which this base's argparse rejects with rc 2 -- so
# a cell that only wants rc 2 is green over this base by that accident. For those the cell checked is the one
# that names the cause (its `has`), matched on the text it wants.
for c in "🔴 A/A (a control as the treatment): rc 3" "🔴 a treatment with no detect-only start line: rc 3" \
         "🔴 a second control with only a heartbeat block: rc 3" "  naming both traces" \
         "🔴 a packet-in count between the controls': rc 0" \
         "  noted as the invariant, descriptive" "  said as cut short" \
         "🔴 a session whose daemon counted a frame to a host: rc 1" "  said as ruling 4"; do
    /usr/bin/grep -qF "FAILED   $c" "$K/e_base_tool.out" && ok "  base tool: '$c' RED" || nok "  base tool: '$c' not red"
done
/usr/bin/grep -qF "no match for: [a packet-in whose frame cannot be parsed]" "$K/e_base_tool.out" \
    && ok "  base tool: the unparseable packet-in's 'said as such' RED" || nok "  base tool: the unparseable packet-in's cause not red"
echo "    (renamed in round 3: 'a control whose heartbeat was running' is now the two control-refusal cells above;"
echo "     'kept by the control' is 'kept by every control'; 'a daemon that counted' is 'a session whose daemon counted'."
echo "     'a controller log that is not UTF-8: rc 2' has no cause cell and is green over this base by the argparse"
echo "     accident; it was seen red in extb2's redfirst_b2 log against this same base, with the round-2 suite)"
echo "    cells green over the base tool (guards of what it already did; the evidence gate kills each):"
/usr/bin/grep '^  ok ' "$K/e_base_tool.out" | sed 's/^/      /' | head -40

echo "REDFIRST-B2: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"
exit $bad
