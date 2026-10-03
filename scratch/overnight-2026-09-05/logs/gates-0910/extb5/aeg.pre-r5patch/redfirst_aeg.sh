#!/usr/bin/env bash
# redfirst_aeg.sh <worktree> <keep dir> -- fix/rulings-aeg-0927 red first: HEAD's tests against the code
# without the rulings -- the trunk this branch merged last (7746832e; AEG_BASE to change it). Every output KEPT under <keep dir>. [Co-developed with claude code -- Adam]
#   A  HEAD's 08 with the base's v_strict, cut_cycle and strict_conclude swapped back in, in an
#      ltree (the HB W gate's own): the ruling's cells red, the control green
#   E  HEAD's test_heartbeat_fabric.py against the base's main.py; HEAD's 07 with the base's two
#      SKIPPED_* constants
#   G  HEAD's test_live_p1_common.sh with COMMON_UNDER_TEST = the base's _common.sh (and A's section
#      15 with it); HEAD's test_live_p1_thirteen.sh with THIRTEEN_UNDER_TEST = the base's 06 -- a run
#      with no NDT_OWNER used to go on, as `live-p1`
set -u
WT="$1"; K="$2"; bad=0; BASE="${AEG_BASE:-7746832e}"; cd "$WT" || exit 2; mkdir -p "$K"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export KEEP="$K/unexpected"; source "$HERE/redfirst_lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/aeg-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
echo "HEAD $(git rev-parse HEAD); base $(git rev-parse $BASE)"
reds() { /usr/bin/grep -E '^ *🔴 ' "$1" | sed -E 's/^ *🔴 +//' | cut -c1-120; }

echo "== A: HEAD's 08 self-test over the base's strict-bound code"
git show "$BASE:$LIVE/08_heartbeat.sh" > "$T/08_base.sh"
python3 - "$LIVE/08_heartbeat.sh" "$T/08_base.sh" "$T/08_hybrid.sh" <<'PY'
import re, sys
head, base, out = (open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3])
def block(s, start, end_re):
    i = s.index(start); m = re.compile(end_re, re.M).search(s, i + len(start))
    return s[i:m.start()]
for start, end_re in (("cut_cycle() {\n", r"^}\n"), ("strict_conclude() {\n", r"^}\n"),
                      ("def v_strict(row, bound):\n", r"^def ")):
    h, b = block(head, start, end_re), block(base, start, end_re)
    assert head.count(h) == 1 and h != b, start
    head = head.replace(h, b)
open(out, "w").write(head)
PY
src="$(sed -n '/^ltree() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
( REPO="$WT"; LIVE_DIR_REL="$LIVE"; LIVE08="$WT/$LIVE/08_heartbeat.sh"; eval "$src"
  ltree "$T/lt"; cp "$T/08_hybrid.sh" "$T/lt/$LIVE/08_heartbeat.sh"
  cd "$T/lt" && TMPDIR="$T/lt/tmp" PYTHONDONTWRITEBYTECODE=1 timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$K/a_08_hybrid.out" 2>&1 )
reds "$K/a_08_hybrid.out" | sed 's/^/    red: /'
exactly_red "08, HEAD's cells over the base's strict code" "$K/a_08_hybrid.out" \
    "H1's last line with an OVER cycle was" "cut_cycle gave" \
    "  H1's last line after an earlier failure was" "  H1's last line with a STOP after an OVER cycle was"
/usr/bin/grep -qF "the control: a cycle within 20 s ends PASS with nothing disclosed" "$K/a_08_hybrid.out" \
    && ok "  the control (a cycle within 20 s) stays green over the base's code" || nok "  the control is not green"
/usr/bin/grep -m1 -F "H1's last line with an OVER cycle was" "$K/a_08_hybrid.out" | cut -c1-200 | sed 's/^/    base behaviour: /'

echo "== E: the proxy's list, and 07's"
# the HB W gate's own lay_out (a repo-shaped copy of HEAD, `setting/` linked), with the base's main.py
# put in its place -- the first cut of this used a bare archive with no setting/ and main.py could
# not even import (it loads the fabric model at import time)
lo="$(sed -n '/^lay_out() {/,/^}/p' tests/shell/mutate_p4_heartbeat_w.sh)"
P="$T/px"; mkdir -p "$P"
( REPO="$WT"; HELPER="$WT/tools/test_workflow/ndtwin-lab"; eval "$lo"; lay_out "$P" )
git show "$BASE:p4_proxy/proxy_agent/main.py" > "$P/p4_proxy/proxy_agent/main.py"
( cd "$P/p4_proxy" && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
    timeout 300 "$(readlink -f "$WT/p4_proxy/venv")/bin/python" -m unittest -v tests.test_heartbeat_fabric > "$K/e_proxy_base_main.out" 2>&1 )
/usr/bin/grep -E '^(Ran |OK|FAILED)' "$K/e_proxy_base_main.out" | sed 's/^/    /'
( cd "$P/p4_proxy" && cp "$WT/p4_proxy/proxy_agent/main.py" proxy_agent/main.py && PYTHONDONTWRITEBYTECODE=1 HOME="$P/home" TMPDIR="$P/tmp" PYTHONPATH="$P/p4_proxy" \
    timeout 300 "$(readlink -f "$WT/p4_proxy/venv")/bin/python" -m unittest -v tests.test_heartbeat_fabric > "$K/e_proxy_head_main.out" 2>&1 )
/usr/bin/grep -qE '^OK' "$K/e_proxy_head_main.out" && ok "  the same tree with HEAD's main.py: $(/usr/bin/grep -E '^Ran ' "$K/e_proxy_head_main.out")" \
    || nok "  the same tree with HEAD's main.py is not green"
/usr/bin/grep -E '^(FAIL|ERROR):' "$K/e_proxy_base_main.out" | sed 's/^/    /'
for t in test_the_lldp_beacons_stay_off_and_named_skipped_but_the_watchdog_runs test_an_unbound_fabric_reports_its_watchdog_running_too; do
    /usr/bin/grep -qE "^FAIL: $t " "$K/e_proxy_base_main.out" && ok "  base main.py: $t is RED" || nok "  base main.py: $t not red"
done
/usr/bin/grep -qE "^(FAIL|ERROR): test_a_heartbeat_watchdog_that_did_not_start" "$K/e_proxy_base_main.out" \
    && nok "  the did-not-start guard went red at the base" \
    || ok "  test_a_heartbeat_watchdog_that_did_not_start... is green at the base (it guards the other half, E2)"
[[ "$(/usr/bin/grep -cE '^(FAIL|ERROR):' "$K/e_proxy_base_main.out")" == 2 ]] && ok "  exactly those two red" || nok "  other reds at the base"
python3 - "$LIVE/07_roles_basic.sh" "$T/07_e.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
for a, b in (("SKIPPED_OWNED=\"['lldp_discovery']\"", "SKIPPED_OWNED=\"['link_watchdog', 'lldp_discovery']\""),
             ("SKIPPED_UNBOUND=\"['install_initial_routes', 'lldp_discovery']\"",
              "SKIPPED_UNBOUND=\"['install_initial_routes', 'link_watchdog', 'lldp_discovery']\"")):
    assert s.count(a) == 1; s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
d7="$T/t7"; mkdir -p "$d7/$LIVE" "$d7/p4_proxy" "$d7/tmp"; cp "$LIVE/_common.sh" "$d7/$LIVE/"; cp "$T/07_e.sh" "$d7/$LIVE/07_roles_basic.sh"
ln -s "$(readlink -f "$WT/p4_proxy/venv")" "$d7/p4_proxy/venv"
( cd "$d7" && TMPDIR="$d7/tmp" timeout 300 bash "$LIVE/07_roles_basic.sh" --self-test > "$K/e_07_base_lists.out" 2>&1 )
reds "$K/e_07_base_lists.out" | sed 's/^/    red: /'
for c in "L6 skipped with every table owned" "L6 link_watchdog still named skipped while the heartbeat drives it" "L6/L1 on switch_state (unbound)"; do
    reds "$K/e_07_base_lists.out" | /usr/bin/grep -qF -- "$c" && ok "  07 with the base's lists: '$c' is RED" || nok "  07 with the base's lists: '$c' not red"
done

echo "== G (and A's disclose): the base's _common.sh and 06 under HEAD's suites"
git show "$BASE:$LIVE/_common.sh" > "$T/_common_base.sh"
COMMON_UNDER_TEST="$T/_common_base.sh" timeout 600 bash tests/shell/test_live_p1_common.sh < /dev/null > "$K/g_common_base.out" 2>&1; rc=$?
echo "    test_live_p1_common over the base's _common.sh: rc $rc, $(tail -1 "$K/g_common_base.out")"
/usr/bin/grep -E '^  FAILED' "$K/g_common_base.out" | sed 's/^  FAILED */    red: /'
sec() { awk -v s="$2" 'index($0, s) == 1 {on = 1; next} on && /^[0-9]+\. / {on = 0} on' "$1"; }
s15="$(sec "$K/g_common_base.out" "15. ")"; s16="$(sec "$K/g_common_base.out" "16. ")"
others="$(/usr/bin/grep -E '^  FAILED' "$K/g_common_base.out" | /usr/bin/grep -vF -f <( { /usr/bin/grep -E '^  FAILED' <<<"$s15"; /usr/bin/grep -E '^  FAILED' <<<"$s16"; } ) )"
[[ $rc != 0 && -z "$others" ]] && ok "  red only in sections 15 (disclose) and 16 (no default owner)" || nok "  red elsewhere too: $others"
for c in "🔴 no NDT_OWNER: start_step refuses with rc 2" "🔴 it did not go on as a default owner" "🔴 and made no run directory" "🔴 sourcing the file does not invent an owner"; do
    /usr/bin/grep -qF "  FAILED   $c" <<<"$s16" && ok "  base: '$c' RED" || nok "  base: '$c' not red"
done
/usr/bin/grep -qF "  FAILED   🔴 and the line right above it is the disclosure, verbatim" <<<"$s15" && ok "  base: the disclosure cell RED (no disclose)" || nok "  base: disclosure cell not red"
T16="$T/g16"; mkdir -p "$T16/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T16/bin/ndt"; chmod +x "$T16/bin/ndt"
cat > "$T16/step.sh" <<STEPSH
set -euo pipefail
source "$T/_common_base.sh"
LIVE_DIR="$T16"; NDT="$T16/bin/ndt"; PY=/usr/bin/python3; CLAIMED=0
require_root() { :; }; require_free_lab() { :; }; snapshot_knob() { :; }; snapshot_telemetry_knob() { :; }
restore_knob() { :; }; restore_telemetry_knob() { :; }
start_step 16_owner
echo "STARTED as owner [\$NDT_OWNER]"
exit 0
STEPSH
o="$(env -u NDT_OWNER timeout 60 bash "$T16/step.sh" 2>&1; echo "rc=$?")"
echo "$o" > "$K/g_start_step_base.out"
/usr/bin/grep -E "owner:|STARTED|^(PASS|FAIL|REFUSED)|rc=" <<<"$o" | sed 's/^/    base, no NDT_OWNER: /'
[[ "$o" == *"STARTED as owner [live-p1]"* ]] && ok "  at $BASE a run with no NDT_OWNER went on, as 'live-p1'" || nok "  at $BASE: no 'live-p1' start"
git show "$BASE:$LIVE/06_thirteen.sh" > "$T/06_base.sh"
THIRTEEN_UNDER_TEST="$T/06_base.sh" timeout 600 bash tests/shell/test_live_p1_thirteen.sh < /dev/null > "$K/g_thirteen_base.out" 2>&1; rc=$?
echo "    test_live_p1_thirteen over the base's 06: rc $rc, $(tail -1 "$K/g_thirteen_base.out")"
/usr/bin/grep -E '^  FAILED' "$K/g_thirteen_base.out" | sed 's/^  FAILED */    red: /'
[[ "$(/usr/bin/grep -cE '^  FAILED' "$K/g_thirteen_base.out")" -ge 1 ]] && /usr/bin/grep -qF "  FAILED   🔴 no NDT_OWNER is rc 2" "$K/g_thirteen_base.out" \
    && ok "  base 06: the no-owner cells RED" || nok "  base 06: not red"
echo "AEG-RED-FIRST: $([[ $bad == 0 ]] && echo "A, E and G red at $BASE's code, green at HEAD" || echo BROKEN)"
exit $bad
