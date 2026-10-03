#!/usr/bin/env bash
# redfirst_aeg5.sh <worktree> <keep dir> -- the fixes of the AEG judge's round on ebe17f7c, red first:
# HEAD's tests against ebe17f7c's code (AEG_BASE to change it). Every output KEPT. [Co-developed with claude code -- Adam]
#   F1  HEAD's 08 with the base's w_finish swapped back in, in an ltree: the early-exit cell red, alone
#   F2  HEAD's test_heartbeat_fabric.py against the base's main.py: the startup-log test red, alone
#   N1  HEAD's test_live_p1_common.sh with COMMON_UNDER_TEST = the base's _common.sh: section 18's
#       verdict cells red; its two source pins on 02, asked of the base's 02
#   N4  the gate driver's proxy_unit: red on a tree with the base's main.py, red on a file whose every
#       test skipped
set -u
WT="$1"; K="$2"; bad=0; BASE="${AEG_BASE:-ebe17f7c}"; cd "$WT" || exit 2; mkdir -p "$K"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export KEEP="$K/unexpected"; source "$HERE/redfirst_lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/aeg5-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
reds() { /usr/bin/grep -E '^ *🔴 ' "$1" | sed -E 's/^ *🔴 +//' | cut -c1-120; }

echo "== F1: HEAD's 08 self-test with the base's w_finish"
git show "$BASE:$LIVE/08_heartbeat.sh" > "$T/08_base.sh"
python3 - "$LIVE/08_heartbeat.sh" "$T/08_base.sh" "$T/08_hybrid.sh" <<'PY'
import re, sys
head, base, out = (open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3])
def block(s, start):
    i = s.index(start); m = re.compile(r"^}\n", re.M).search(s, i + len(start))
    return s[i:m.end()]
h, b = block(head, "w_finish() {\n"), block(base, "w_finish() {\n")
assert head.count(h) == 1 and h != b
open(out, "w").write(head.replace(h, b))
PY
src="$(sed -n '/^ltree() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
run08() {   # run08 <08 copy> <out>
    ( REPO="$WT"; LIVE_DIR_REL="$LIVE"; LIVE08="$WT/$LIVE/08_heartbeat.sh"; eval "$src"
      rm -rf "$T/lt"; ltree "$T/lt"; cp "$1" "$T/lt/$LIVE/08_heartbeat.sh"
      cd "$T/lt" && TMPDIR="$T/lt/tmp" PYTHONDONTWRITEBYTECODE=1 timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$2" 2>&1 )
}
run08 "$T/08_hybrid.sh" "$K/f1_08_hybrid.out"
reds "$K/f1_08_hybrid.out" | sed 's/^/    red: /'
exactly_red "08, HEAD's cells over the base's w_finish" "$K/f1_08_hybrid.out" \
    "  H1's last lines after an early exit following an OVER cycle were"
/usr/bin/grep -m1 -F "H1's last lines after an early exit following an OVER cycle were" "$K/f1_08_hybrid.out" | cut -c1-220 | sed 's/^/    base behaviour: /'
run08 "$LIVE/08_heartbeat.sh" "$K/f1_08_head.out"
[[ "$(tail -1 "$K/f1_08_head.out")" == "SELF-TEST PASS" ]] && ok "  HEAD's own 08 in the same tree: SELF-TEST PASS" || nok "  HEAD's own 08 is not green"

echo "== F2: HEAD's test_heartbeat_fabric.py over the base's main.py"
lo="$(sed -n '/^lay_out() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
P="$T/px"; mkdir -p "$P"
( REPO="$WT"; HELPER="$WT/tools/test_workflow/ndtwin-lab"; eval "$lo"; lay_out "$P" )
PYV="$(readlink -f "$WT/p4_proxy/venv")/bin/python"
hbf() { ( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
          timeout 300 "$PYV" -m unittest -v tests.test_heartbeat_fabric > "$1" 2>&1 ); }
git show "$BASE:p4_proxy/proxy_agent/main.py" > "$P/p4_proxy/proxy_agent/main.py"
hbf "$K/f2_base_main.out"
/usr/bin/grep -E '^(Ran |OK|FAILED)|^(FAIL|ERROR):' "$K/f2_base_main.out" | sed 's/^/    /'
[[ "$(/usr/bin/grep -cE '^(FAIL|ERROR):' "$K/f2_base_main.out")" == 1 ]] \
    && /usr/bin/grep -qE '^FAIL: test_the_startup_log_names_the_same_skipped_list_switch_state_serves ' "$K/f2_base_main.out" \
    && ok "  base main.py: exactly the startup-log test is RED" || nok "  base main.py: not exactly the startup-log test red"
cp "$WT/p4_proxy/proxy_agent/main.py" "$P/p4_proxy/proxy_agent/main.py"
hbf "$K/f2_head_main.out"
/usr/bin/grep -qE '^OK' "$K/f2_head_main.out" && ok "  the same tree with HEAD's main.py: $(/usr/bin/grep -E '^Ran ' "$K/f2_head_main.out")" \
    || nok "  the same tree with HEAD's main.py is not green"
/usr/bin/grep -A3 "^FAIL: test_the_startup_log" "$K/f2_base_main.out" | tail -1 | cut -c1-200 | sed 's/^/    base behaviour: /'
/usr/bin/grep -m1 -E "AssertionError" "$K/f2_base_main.out" | cut -c1-200 | sed 's/^/    base behaviour: /'

echo "== N1: HEAD's test_live_p1_common.sh with the base's _common.sh"
git show "$BASE:$LIVE/_common.sh" > "$T/_common_base.sh"
COMMON_UNDER_TEST="$T/_common_base.sh" timeout 900 bash tests/shell/test_live_p1_common.sh > "$K/n1_common_base.out" 2>&1
sed -n '/^18\./,/^14\./p' "$K/n1_common_base.out" | sed 's/^/    /' | head -24
for c in "🔴 running, the two names: OK" "🔴 not_started is a failure, not the other list" \
         "  and it names the proxy's own heartbeat.error" "🔴 no heartbeat block is a failure too" \
         "🔴 running with link_watchdog still named: BAD"; do
    /usr/bin/grep -qF "FAILED   $c" "$K/n1_common_base.out" && ok "  base _common.sh: '$c' RED" || nok "  base _common.sh: '$c' not red"
done
n_red="$(/usr/bin/grep -c '^  FAILED' "$K/n1_common_base.out")"
[[ "$n_red" == 5 ]] && ok "  exactly those 5 red over the base's _common.sh" || nok "  $n_red red over the base's _common.sh (want 5)"
git show "$BASE:$LIVE/02_app_basic.sh" > "$T/02_base.sh"
a="$(/usr/bin/grep -c '^    V="$(heartbeat_skips_verdict "$SS" "$FABRIC_SKIPS_HB")"$' "$T/02_base.sh")"
b="$(/usr/bin/grep -c 'HB_WD" == running' "$T/02_base.sh")"
[[ "$a" == 0 ]] && ok "  the base's 02 does not ask the verdict (pin 1 would read 0, want 1: RED)" || nok "  base 02 pin 1 = $a"
[[ "$b" != 0 ]] && ok "  the base's 02 picks its list from heartbeat.watchdog (pin 2 would read $b, want 0: RED)" || nok "  base 02 pin 2 = $b"
COMMON_UNDER_TEST="$WT/$LIVE/_common.sh" timeout 900 bash tests/shell/test_live_p1_common.sh > "$K/n1_common_head.out" 2>&1
[[ "$(tail -1 "$K/n1_common_head.out")" == *", 0 failed" ]] && ok "  HEAD's _common.sh: $(tail -1 "$K/n1_common_head.out")" || nok "  HEAD's _common.sh: $(tail -1 "$K/n1_common_head.out")"

echo "== N4: the gate driver's proxy_unit can go red"
F="$T/full"; mkdir -p "$F"
git archive HEAD p4_proxy tools setting tests | tar -x -C "$F"
ln -s "$(readlink -f "$WT/p4_proxy/venv")" "$F/p4_proxy/venv"
ln -s "$(readlink -f "$WT/p4_proxy/p4_src/build")" "$F/p4_proxy/p4_src/build"
git show "$BASE:p4_proxy/proxy_agent/main.py" > "$F/p4_proxy/proxy_agent/main.py"
bash "$HERE/proxy_unit.sh" "$F" > "$K/n4_unit_base_main.out" 2>&1; rc=$?
/usr/bin/grep -E '^  FAILED' "$K/n4_unit_base_main.out" | sed 's/^/    /'
tail -1 "$K/n4_unit_base_main.out" | sed 's/^/    /' 
[[ $rc == 1 && "$(/usr/bin/grep -c '^  FAILED' "$K/n4_unit_base_main.out")" == 1 ]] \
    && /usr/bin/grep -qE '^  FAILED   tests/test_heartbeat_fabric.py' "$K/n4_unit_base_main.out" \
    && ok "  HEAD's tree with the base's main.py: rc 1, exactly test_heartbeat_fabric.py FAILED" || nok "  with the base's main.py: rc $rc"
S="$T/skipall"; mkdir -p "$S/p4_proxy/tests"; ln -s "$(readlink -f "$WT/p4_proxy/venv")" "$S/p4_proxy/venv"
cat > "$S/p4_proxy/tests/test_all_skipped.py" <<'PY'
import unittest
@unittest.skip("a dependency this interpreter does not have")
class T(unittest.TestCase):
    def test_a(self): pass
    def test_b(self): pass
if __name__ == "__main__":
    unittest.main()
PY
bash "$HERE/proxy_unit.sh" "$S" > "$K/n4_unit_all_skipped.out" 2>&1; rc=$?
cat "$K/n4_unit_all_skipped.out" | sed 's/^/    /'
[[ $rc == 1 ]] && /usr/bin/grep -qF "every one of its 2 test(s) SKIPPED" "$K/n4_unit_all_skipped.out" \
    && ok "  a file whose every test skipped: rc 1, named" || nok "  all-skipped: rc $rc"

echo "REDFIRST-AEG5: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"
exit $bad
