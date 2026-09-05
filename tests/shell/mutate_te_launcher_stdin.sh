#!/usr/bin/env bash
#
# Mutation gate for the W7 section of tests/shell/test_ndt_apps_liveness.sh -- the APP_STDIN
# feed that `ndt apps start te` needs, because Traffic-engineering-App.py:599 calls input()
# at startup and the launcher handed it EOF (measured 2026-09-04, rc 1 within the second).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 Two directions, because "feed it stdin" has three wrong answers that all make te start.
#   * M1 is the defect itself: the feed is not applied, and the app dies as it did.
#   * M2 and M3 are the OTHER TWO WAYS to write the fix -- a `bash -c` wrapper and a pipeline.
#     Both deliver the bytes; both cost `ndt` something it needs afterwards. They are in this
#     gate because the choice of a herestring is a claim, and a claim with no failing
#     alternative is a preference. If M2 or M3 survives, this suite does not know why the
#     herestring was chosen and the next person is free to "simplify" it.
#   * M5 is the over-reaching fix (feed everyone), and it is caught only by the control:
#     nsr and viz get EOF today, an empty herestring is an empty LINE, and an app that reads
#     a line cannot tell you which of those it wanted until it is too late.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the suite is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it right now -- and the sha256 line at the bottom says so. Same
# construction as tests/shell/mutate_apps_stop_kills_the_group.sh, for the same reason.
#
# 🔴 A mutant directory carries ports.sh, sudo_surface.sh and components.env too. ndt sources
# them from beside itself, so a copy without them exits 2 at source time and every case in the
# suite goes red for a reason that has nothing to do with the mutation.
#
# 🔴 No build. This gate is bash only, so it costs no build lock and no memory.
#
# NOT mutated here, on purpose: `>>` -> `>` on the spawn line. That mutation already exists as
# M6 of tests/shell/mutate_apps_stop_kills_the_group.sh, whose anchor (`>>"$log" 2>&1 ) &`)
# still resolves exactly once after this change, because the APP_STDIN branch ends in
# `<<<"$APP_STDIN" ) &` instead. Adding a second copy here would buy nothing and would double
# the slowest part of the suite.
#
# Usage:  bash tests/shell/mutate_te_launcher_stdin.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_apps_liveness.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-testdin-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

report_live() {   # $1 = control name, $2 = mutant dir -- must stay GREEN
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  caught   %-58s (control: stayed green, as it must)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (control went RED -- this gate measures the text, not the behaviour)\n' "$1"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole directory: ndt sources ports.sh and sudo_surface.sh from beside itself, so
# they travel with it, unmutated. The anchor must be unique, so a mutation cannot quietly land
# somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from a function's
# own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is not checking.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself --------------------------------------------------------------------

m=$(mutant m1 "$NDT" \
    '>>"$log" 2>&1 <<<"$APP_STDIN" ) &' \
    '>>"$log" 2>&1 ) &')
report "M1: the feed is not applied (= the state te died in)" "$m" \
       "app_spawn feeds APP_STDIN to the program"

# --- the other two ways to write this fix ---------------------------------------------------

m=$(mutant m2 "$NDT" \
    '        ( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 <<<"$APP_STDIN" ) &' \
    '        ( cd "$dir" && exec setsid nohup bash -c "printf %s \"$APP_STDIN\" | $*" >>"$log" 2>&1 ) &')
report "M2: a bash -c wrapper feeds it (and buries its argv)" "$m" \
       "pid_is_app still matches a fed app"

# The pipeline moved INSIDE the subshell, which is the shape that actually breaks: the subshell
# can no longer exec, so it forks the app and stays alive as its parent, `$!` names the subshell
# -- which wears `ndt`'s own argv -- and the pid this function records is not the program. That
# is the 2026-08-20 failure the design note above app_spawn was written about, arriving by a new
# route. (The OTHER pipeline shape, printf | ( ... ) &, is C4 below: measured equivalent.)
m=$(mutant m3 "$NDT" \
    '        ( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 <<<"$APP_STDIN" ) &' \
    '        ( cd "$dir" && printf %s "$APP_STDIN" | exec setsid nohup "$@" >>"$log" 2>&1 ) &')
report "M3: the feed is piped from inside, so \$! is the subshell" "$m" \
       "a fed app is still its own session leader"

# --- the wrong feed, and the feed given to everyone -----------------------------------------

m=$(mutant m4 "$NDT" \
    "            APP_STDIN=\$'2\\n5\\n' app_spawn te" \
    "            APP_STDIN=\$'1\\n' app_spawn te")
report "M4: te is started in mode 1, whose trigger is then dead" "$m" \
       "the te branch requests mode 2"

m=$(mutant m5 "$NDT" \
    '    if [[ -n "${APP_STDIN:-}" ]]; then' \
    '    if true; then')
report "M5: every app is fed, including the ones that never asked" "$m" \
       "app_spawn without APP_STDIN behaves as before"

# --- controls: rewrites that change nothing must stay green ---------------------------------
# Without these, "5 of 5 caught" would be satisfied by a suite that goes red on any edit at all.

m=$(mutant c1 "$NDT" \
    '    if [[ -n "${APP_STDIN:-}" ]]; then' \
    '    if [[ ! -z "${APP_STDIN:-}" ]]; then')
report_live "C1 (control): -n written as ! -z" "$m"

m=$(mutant c2 "$NDT" \
    '    # lever there is.' \
    '    # lever available to us on this side of the fence.')
report_live "C2 (control): the comment is reworded" "$m"

m=$(mutant c3 "$NDT" \
    '        ( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 <<<"$APP_STDIN" ) &' \
    '        ( cd "$dir" && exec setsid nohup "$@" <<<"$APP_STDIN" >>"$log" 2>&1 ) &')
report_live "C3 (control): the herestring is written before the log" "$m"

# 🔴 C4 is a control on PURPOSE, and it is the honest half of M2/M3. The fix plan predicted that
# `printf ... | ( ... ) &` would cost the app its session; it does not, and this gate says so.
# With job control off -- every script -- bash puts no pipeline in a group of its own, so the
# subshell is not a group leader, setsid(1) execs in place instead of forking, and pgid == sid ==
# pid still holds. `$!` is the last element's pid, which is the program. Measured 2026-09-04: all
# 51 checks green. The herestring is preferred over this on the ground app_spawn's own design
# note gives -- `$!` must name the program, and under a pipeline that is true by a rule about
# pipelines rather than by the exec chain in front of you -- and NOT because this suite can see a
# difference. Anyone who deletes C4 to make the gate read "the pipeline is broken" is inventing
# evidence.
m=$(mutant c4 "$NDT" \
    '        ( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 <<<"$APP_STDIN" ) &' \
    '        printf %s "$APP_STDIN" | ( cd "$dir" && exec setsid nohup "$@" >>"$log" 2>&1 ) &')
report_live "C4 (control): printf | ( ... ) & -- equivalent, not broken" "$m"

echo
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (tools/test_workflow/ndt)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
