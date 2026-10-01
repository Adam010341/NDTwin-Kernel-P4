#!/usr/bin/env bash
#
# Mutation gate for "one clock per residue report": tests/shell/test_apps_residue.sh groups 5K
# and 5N, against tools/test_workflow/ndt's residue_report and app_started_at.
#
# [Co-developed with claude code -- Adam]
#
# residue_report dates every rule as `now - duration_sec` and every live app as `now - etimes`,
# both against the SAME `now`, read after the flow table, with every app dated right after it.
# Each product mutation below puts back one way of breaking that, and must turn the 5N case
# written for it red:
#   M3  app_started_at's pidfile source reads the clock again   (the CI failure itself)
#   M4  app_started_at's scan source reads the clock again
#   M5  the report reads `now` before the table instead of after it
#   M6  the report stops handing its `now` to app_started_at
#   M9  apps are dated after the lock probes instead of right after `now`
# 5N makes each race CERTAIN rather than likely (a `ps` that waits for the next second before the
# dating's etimes query, a switch that answers from the rule's install instant, lock probes that
# take 1.2 s each), and asserts that the race was set up. The test mutations take that set-up
# away and must turn the PREMISE checks red -- a premise that cannot fail is a regression test
# that can pass without its race:
#   M7  the dating's `ps` no longer waits for a boundary   -> the three live premises
#   M8  the switch no longer straddles one                 -> the dead-app premise
#   M10 the lock probes no longer take their time          -> the early-window premise
#   M2  5K's argv wait is back to the one second it had    -> 5K's argv premise (under `late`)
# `late` is a harness, not a mutation: the fixture execs 1.5 s after it forks, longer than the old
# one-second wait and far shorter than the 30 s the suite allows. It must leave the suite green on
# its own, or everything under it would look caught.
#
# Guards its own baseline: every edit is made to COPIES in a temp dir (ndt and its siblings, and
# the suite), the files under test are never written, and the sha256 lines at the bottom say so.
# A mutation that will not apply, or a named case that stays green, counts as SURVIVED -- never
# as skipped.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline or harness red),
#       3 a file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
SH_TEST="$HERE/test_apps_residue.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/apps-residue-clock-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SH=$(sha256sum "$SH_TEST" | cut -d' ' -f1)
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_sh() { NDT_UNDER_TEST="$1/ndt" timeout 900 bash "$1/$(basename "$SH_TEST")" 2>&1; }
reds()   { grep -E '^  FAILED ' <<<"$1" | sed 's/^  FAILED *//' | paste -sd'|'; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the case(s) that must fail, '|'-separated
    local out rc c miss=""
    local -a want=()
    MUTATIONS=$((MUTATIONS+1))
    if [[ -z "$2" || ! -d "$2" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-50s (the mutation did not apply -- nothing was tested)\n' "$1"
        return
    fi
    out=$(run_sh "$2"); rc=$?
    IFS='|' read -r -a want <<<"$3"
    for c in "${want[@]}"; do grep -qF "FAILED   $c" <<<"$out" || miss="${miss:+$miss | }$c"; done
    if [[ "$rc" -ne 0 && -z "$miss" ]]; then
        printf '  caught   %-50s (%d named case(s) went red)\n' "$1" "${#want[@]}"
        printf '           all red: %s\n' "$(reds "$out")"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-50s (stayed green: %s)\n' "$1" "${miss:-rc 0}"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate. `base` (optional) is a mutant dir to build on, which is how a mutation is stacked
# on a harness or on another edit: the anchor must then be unique in that dir's copy as well.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement, [$5 = base]
    local label="$1" file="$2" old="$3" new="$4" base="${5:-}"
    local d="$BK/$label" src f
    mkdir -p "$d"
    for f in ndt ports.sh sudo_surface.sh components.env; do
        src="$REPO/tools/test_workflow/$f"; [[ -n "$base" ]] && src="$base/$f"
        cp "$src" "$d/$f" || return 1
    done
    chmod +x "$d/ndt"
    src="$SH_TEST"; [[ -n "$base" ]] && src="$base/$(basename "$SH_TEST")"
    cp "$src" "$d/$(basename "$SH_TEST")" || return 1
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY' || return 1
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
for f in ndt ports.sh sudo_surface.sh components.env; do cp "$REPO/tools/test_workflow/$f" "$base/$f"; done
cp "$SH_TEST" "$base/"
out=$(run_sh "$base"); rc=$?
echo "  $(grep -E '^Ran ' <<<"$out" | tail -1)"
[[ "$rc" -eq 0 ]] || { echo "  shell baseline is RED -- mutations prove nothing"; exit 2; }

late=$(mutant late "$SH_TEST" \
    'LIVE_TE_ARGV="/nonexistent/NDT-TEST-FIXTURE/Traffic-engineering-App.py"
( exec -a "$LIVE_TE_ARGV" sleep 120 ) >/dev/null 2>&1 </dev/null &' \
    'LIVE_TE_ARGV="/nonexistent/NDT-TEST-FIXTURE/Traffic-engineering-App.py"
( sleep 1.5; exec -a "$LIVE_TE_ARGV" sleep 120 ) >/dev/null 2>&1 </dev/null &')
if [[ -z "$late" ]]; then echo "  harness late did not apply -- refused"; exit 2; fi
out=$(run_sh "$late"); rc=$?
echo "  harness late on the unmutated suite: $(grep -E '^Ran ' <<<"$out" | tail -1)"
[[ "$rc" -eq 0 ]] || { echo "  harness late turns the suite red by itself -- refused"; exit 2; }
echo

# --- the product: one clock per report -----------------------------------------------------------
m=$(mutant m3 "$NDT" \
    '        if [[ "$et" =~ ^[0-9]+$ ]]; then echo "$(( ${now:-$(date +%s)} - et ))"; return 0; fi' \
    '        if [[ "$et" =~ ^[0-9]+$ ]]; then echo "$(( $(date +%s) - et ))"; return 0; fi')
report "M3: the pidfile source reads the clock again" "$m" \
       "🔴 young app: its rule is DATED, 0s old, across a boundary between now and the dating|  young app: its window starts at the report's now, not a second after it|🔴 2s-old app: the rule from its first second is DATED, 2s old, across the boundary|  2s-old app: its window opens where it started, two seconds back"

m=$(mutant m4 "$NDT" \
    '    [[ -n "$best" ]] && { echo "$(( ${now:-$(date +%s)} - best ))"; return 0; }' \
    '    [[ -n "$best" ]] && { echo "$(( $(date +%s) - best ))"; return 0; }')
report "M4: the scan source reads the clock again" "$m" \
       "🔴 an app found by the scan, no pidfile: its young rule is DATED, 0s old"

m5a=$(mutant m5a "$NDT" \
    '    plane="$(live_dataplane_kind)"
    entries="$(http_get_flow_entries)"' \
    '    now="$(date +%s)"
    plane="$(live_dataplane_kind)"
    entries="$(http_get_flow_entries)"')
m=""; [[ -n "$m5a" ]] && m=$(mutant m5 "$NDT" \
    '    now="$(date +%s)"
    # 🔴 AND EVERY APP IS DATED HERE' \
    '    # 🔴 AND EVERY APP IS DATED HERE' "$m5a")
report "M5: now is read before the flow table" "$m" \
       "🔴 dead app: a rule from its pidfile's own second is DATED across a straddling fetch"

m=$(mutant m6 "$NDT" \
    '        dated[$a]="$(app_started_at "$a" "$now")" || dated[$a]=""' \
    '        dated[$a]="$(app_started_at "$a")" || dated[$a]=""')
report "M6: the report stops handing its now to the dating" "$m" \
       "🔴 young app: its rule is DATED, 0s old, across a boundary between now and the dating|🔴 2s-old app: the rule from its first second is DATED, 2s old, across the boundary|🔴 an app found by the scan, no pidfile: its young rule is DATED, 0s old"

m=$(mutant m9 "$NDT" \
    '        [[ -n "$started" ]] || started="${dated[$a]:-}"' \
    '        [[ -n "$started" ]] || started="$(app_started_at "$a" "$now")" || started=""')
report "M9: apps are dated after the lock probes" "$m" \
       "🔴 early window: a rule from 2s before the app started is NOT in its window|  early window: the window's age is the app's, not the app's plus the probes'"

# --- the suite's own premises --------------------------------------------------------------------
m=$(mutant m7 "$SH_TEST" \
    '                for _w in {1..400}; do s1=${EPOCHREALTIME%.*}; (( s1 > s0 )) && break; sleep 0.005; done' \
    '                :')
report "M7: the dating's ps no longer waits for a boundary" "$m" \
       "🔴 premise (young): one second boundary between the report's now and the dating, app < 1s old|🔴 premise (old): one second boundary between the report's now and the dating, app 2s old|🔴 premise (scan): one second boundary between the report's now and the dating, app < 1s old"

m=$(mutant m8 "$SH_TEST" \
    '    while int(time.time()) == s0:
        time.sleep(0.005)
    time.sleep(0.05)' \
    '    pass')
report "M8: the switch no longer straddles a boundary" "$m" \
       "🔴 premise (dead): the flow-table fetch straddled a second boundary"

m=$(mutant m10 "$SH_TEST" \
    '        sleep 1.2
        echo x >> "$REPO/.test_run/probes_slept"' \
    '        :')
report "M10: the lock probes no longer take their time" "$m" \
       "🔴 premise (early): the three lock probes each took 1.2s"

m=$(mutant m2 "$SH_TEST" \
    'for _i in {1..300}; do                  # up to 30 s for the exec to land' \
    'for _i in 1 2 3 4 5 6 7 8 9 10; do' "$late")
report "M2: 5K's argv wait back to one second (under late)" "$m" \
       "🔴 premise: /proc shows the live fixture's argv, so ndt can recognise the pid"

echo
[[ "$(sha256sum "$SH_TEST" | cut -d' ' -f1)" == "$BASE_SH" && "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] \
    || { echo "a file under test CHANGED while the gate ran -- result void"; exit 3; }
echo "suite untouched (sha256 ${BASE_SH:0:16}...), ndt untouched (sha256 ${BASE_NDT:0:16}...)"
printf '%d mutation(s), %d survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]] || exit 1
exit 0
