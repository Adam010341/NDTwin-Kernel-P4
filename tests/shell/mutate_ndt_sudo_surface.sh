#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_sudo_surface.sh.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of the defect the sudo table replaces, and must turn its
# named case red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Two directions, because one is not enough here. Every "a refusal must not read as a
# measurement" case is ALSO satisfied by an implementation that answers "cannot tell" to
# everything -- and that implementation makes `ndt up p4` impossible to run on any machine.
# The mutations labelled (control) are that implementation in four shapes, and each must turn a
# control case red. A gate with only the first kind would sign off on a tool that refuses every
# bring-up, which is a worse product than the one this change started from.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the test is
# pointed at them with SURFACE_UNDER_TEST / NDT_UNDER_TEST. The files in tools/test_workflow are
# never written -- another session may be executing them right now.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SURFACE="$REPO/tools/test_workflow/sudo_surface.sh"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_sudo_surface.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-sudo-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SURFACE=$(sha256sum "$SURFACE" | cut -d' ' -f1)
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() { SURFACE_UNDER_TEST="$1/sudo_surface.sh" NDT_UNDER_TEST="$1/ndt" timeout 300 bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}

# report_all -- as report, but EVERY named case must go red (a mutation that should show in several
# places, each of which would otherwise never have been seen red).
report_all() {   # $1 = mutation name, $2 = mutant dir, $3... = cases that must all fail
    local name="$1" dir="$2" out rc c missing=""
    shift 2
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$dir"); rc=$?
    for c in "$@"; do grep -qF "FAILED   $c" <<<"$out" || missing="${missing:+$missing; }$c"; done
    if [[ "$rc" -ne 0 && -z "$missing" ]]; then
        printf '  caught   %-58s (%d named cases went red)\n' "$name" "$#"
        printf '             red: %s\n' "$@"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (stayed green: %s)\n' "$name" "${missing:-none named -- rc 0}"
    fi
}

# A mutant is a whole directory: ndt sources sudo_surface.sh from beside itself, so both files
# travel together and a mutation to either is exercised through the real seam. The anchor must
# be unique, so a mutation cannot quietly land somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py
# can read this gate: it learns which argument is the anchor and which is the file from a
# function's own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it
# is not checking (it has happened: two gates written the same night extracted zero anchors and
# nobody would have known).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$SURFACE" "$d/sudo_surface.sh"; cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    # ndt also sources ports.sh from beside itself; ship it, unmutated.
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

# tmutant -- a mutated copy of the SUITE ITSELF, for the checks that hold the suite's own fakes
# (the parameters are named for check_gate_anchors.py, as in mutant() above). It runs against the
# unmutated sudo_surface.sh and ndt.
tmutant() {   # $1 = label, $2 = file to mutate (the suite), $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/t-$label"; mkdir -p "$d"
    cp "$file" "$d/$(basename "$file")"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d/$(basename "$file")"
}
report_test() {   # $1 = mutation name, $2 = the suite's mutated copy, $3 = case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(SURFACE_UNDER_TEST="$base/sudo_surface.sh" NDT_UNDER_TEST="$base/ndt" timeout 300 bash "$2" 2>&1); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
    fi
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$SURFACE" "$base/sudo_surface.sh"; cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself: a refusal arriving as a value -------------------------------------------

m=$(mutant m1 "$NDT" \
    '    out="$(ndt_sudo_capture ovs-vsctl list-br)" || return 2' \
    '    out="$(sudo -n ovs-vsctl list-br 2>/dev/null)" || true')
report "M1: ovs_bridge_count discards sudo's exit status again" "$m" \
       "refused: ovs_bridge_count returns 2 and prints no number"

m=$(mutant m2 "$SURFACE" \
    '    return "$rc"' \
    '    return 0')
report "M2: ndt_sudo_capture throws sudo's exit status away" "$m" \
       "refused: ovs_bridge_count returns 2 and prints no number"

m=$(mutant m3 "$NDT" \
    '    if (( brc != 0 )); then' \
    '    if false; then')
report "M3: the guard reads 'could not tell' as 'nothing there'" "$m" \
       "refused: the guard stops the bring-up, rc 5"

m=$(mutant m4 "$NDT" \
    '            NDT_DATAPLANE_WHY="sudo refused mnexec"' \
    '            return 1')
report "M4: a refusal is reported as 'does not forward' again" "$m" \
       "refused: dataplane_ok returns 2 (not tested), and says why"

m=$(mutant m5 "$SURFACE" \
    '        *"a password is required"*)                       return 0 ;;' \
    '        *"NEVER-MATCHES-THIS"*)                           return 0 ;;')
report "M5: the classifier stops recognising sudo's measured wording" "$m" \
       "refused: dataplane_ok returns 2 (not tested), and says why"

m=$(mutant m6 "$SURFACE" \
    '    NDT_SUDO_STDERR="$(cat "$errfile" 2>/dev/null)"' \
    '    NDT_SUDO_STDERR=""')
report "M6: the exit status is kept but the message is dropped" "$m" \
       "refused: dataplane_ok returns 2 (not tested), and says why"

# --- the table: the part that stops the NEXT sudo call from repeating this -----------------------

m=$(mutant m7 "$SURFACE" \
    'mnexec|mnexec -a 1 true' \
    'NOPE-mnexec|mnexec -a 1 true')
report "M7: the mnexec row leaves the table (a call with no row again)" "$m" \
       "every privileged command ndt names has a row (nothing new can go unlisted)"

m=$(mutant m8 "$SURFACE" \
    'ALL=(root) NOPASSWD: %s' \
    'needs root for %s')
report "M8: explain() names the problem but not the line that fixes it" "$m" \
       "explain() prints the sudoers line that fixes it"

# --- the wiring: the callers must READ the table, not keep a copy ---------------------------------

# 🔴 REPOINTED 2026-09-12: the failure branch of this call now puts the P4
# host knob back before returning, so the one-line form this anchored on is gone. Same mutation
# -- up_p4 stops asking the guard -- against the line that is there now. check_gate_anchors.py
# reported MISSING:1 for it, which is what that checker is for: this gate would otherwise have
# said SURVIVED, and an applier that cannot apply is a hole and never a skip.
# [Co-developed with claude code -- Adam] Repointed again: the guard is now asked above the
# writes (up.target, the knobs, the claim note), on the line that refuses with "were not touched".
# [Co-developed with claude code -- Adam] Repointed 2026-11-06: that line now carries the guard's rc out.
m=$(mutant m9 "$NDT" \
    '    (( reuse )) || guard_no_live_ovs || { local grc=$?; err "up.target, the knobs and the claim note were not touched."; return "$grc"; }' \
    '        :')
report "M9: up_p4 stops asking the guard" "$m" \
       "up_p4 asks guard_no_live_ovs"

m=$(mutant m10 "$NDT" \
    '    local sudo_report; sudo_report="$(ndt_sudo_report)"; local src=$?' \
    '    local sudo_report=""; local src=0')
report "M10: cmd_status --check stops reading the sudo table" "$m" \
       "cmd_status --check reads ndt_sudo_report"

# --- the words: what ndt_sudo_probe does with a "sudo:" line it does not know ----------------------
# [Co-developed with claude code -- Adam] (2026-09-27) each part of the
# rule taken out once; each must turn the case that holds that part red, by name.
m=$(mutant s1 "$SURFACE" \
    '    ndt_sudo_unread && return 2' \
    '    : ndt_sudo_unread')
report "S1: an unknown sudo: line falls through to 'granted' again" "$m" \
       "probe: an unknown sudo: line (PAM) is 2, could not tell -- not granted"
m=$(mutant s2 "$SURFACE" \
    '        [[ "$line" == "sudo:"* ]] || continue' \
    '        [[ -n "$line" ]] || continue')
report "S2 (control): any stderr line counts, so the program's own failure is 'could not tell'" "$m" \
       "control, probe: rc!=0 with no sudo: line (ovsdb down, ovs-vsctl's own words) is 0, granted"
m=$(mutant s3 "$SURFACE" \
    '        *"you must have a tty"*)' \
    '        *"NEVER-MATCHES-tty"*)')
report "S3: requiretty's wording is not a known refusal" "$m" \
       "probe: requiretty ('sorry, you must have a tty to run sudo') is 1, refused"
m=$(mutant s4 "$SURFACE" \
    'NDT_SUDO_WARNINGS=("unable to resolve host" "setrlimit(RLIMIT_CORE)")' \
    'NDT_SUDO_WARNINGS=("setrlimit(RLIMIT_CORE)")')
report "S4 (control): 'unable to resolve host' dropped from the warning list" "$m" \
       "control, probe: warning 'unable to resolve host' + ovsdb down is 0, granted"
m=$(mutant s5 "$SURFACE" \
    'NDT_SUDO_WARNINGS=("unable to resolve host" "setrlimit(RLIMIT_CORE)")' \
    'NDT_SUDO_WARNINGS=("unable to resolve host")')
report "S5 (control): 'setrlimit(RLIMIT_CORE)' dropped from the warning list" "$m" \
       "control, probe: warning 'setrlimit(RLIMIT_CORE)' + ovsdb down is 0, granted"
m=$(mutant s6 "$SURFACE" \
    '        (( warn )) && continue' \
    '        (( warn )) && return 1')
report "S6: a warning hides every sudo: line after it, a refusal included" "$m" \
       "probe: a warning AND an unknown sudo: refusal together is 2 -- the list hides only itself"
m=$(mutant s7 "$SURFACE" \
    '               if [[ -n "$NDT_SUDO_UNREAD" ]]; then' \
    '               if false; then')
report "S7: the report says 'no sudo, or not installed' when sudo said something else" "$m" \
       "report: an unknown sudo: line is rc 2, 'could NOT be tested', and quotes what sudo said"

# The checks none of the mutations above reach: each has to be seen red once, by name.
m=$(mutant s8 "$SURFACE" \
    '    local key="$1" probe bin
    NDT_SUDO_UNREAD=""' \
    '    local key="$1" probe bin')
report "S8: the probe keeps the last row's unread line past its early returns" "$m" \
       "report, two rows: an unknown sudo: line, then a program that is not installed -- each row its own reason"
m=$(mutant s9 "$SURFACE" \
    '    ndt_sudo_refused && return 1
    ndt_sudo_unread && return 2' \
    '    ndt_sudo_unread && return 2
    ndt_sudo_refused && return 1')
report_all "S9: an unread sudo: line is asked for before a known refusal" "$m" \
       "probe: a refusal ndt_sudo_refused knows ('a password is required') is 1, refused" \
       "probe: a warning AND a known refusal is 1, refused" \
       "control, report: a known refusal is still rc 1, REFUSED"
m=$(mutant s10 "$SURFACE" \
    '    ndt_sudo_capture $probe >/dev/null && return 0' \
    '    ndt_sudo_capture $probe >/dev/null && return 2')
report "S10 (control): a probe that succeeds is 'could not tell'" "$m" \
       "control, probe: the grant is live and the probe succeeds -- 0"
m=$(mutant s11 "$SURFACE" \
    '    local line w warn' \
    '    local line w warn
    [[ -z "$NDT_SUDO_STDERR" ]] && { NDT_SUDO_UNREAD=""; return 0; }')
report "S11: a refusal that prints nothing is 'could not tell' too" "$m" \
       "control, probe: a refusal that prints nothing is read as granted -- the rule's known limit"
m=$(mutant s12 "$SURFACE" \
    'NDT_SUDO_WARNINGS=("unable to resolve host" "setrlimit(RLIMIT_CORE)")' \
    'NDT_SUDO_WARNINGS=("unable to" "setrlimit(RLIMIT_CORE)")')
report "S12: a warning entry widened into a pattern ('unable to')" "$m" \
       "probe: a fatal 'sudo: unable to execute ...' is 2 -- a warning entry is matched whole, from 'sudo: '"
m=$(mutant s13 "$SURFACE" \
    '            [[ "$line" == "sudo: $w"* ]] && { warn=1; break; }' \
    '            [[ "$line" == *"$w"* ]] && { warn=1; break; }')
report "S13: a warning entry is matched anywhere in the line, not right after 'sudo: '" "$m" \
       "probe: a fatal sudo: line with a warning entry further on is 2 -- entries match only right after 'sudo: '"
m=$(mutant s14 "$SURFACE" \
    '        [[ "$line" == "sudo:"* ]] || continue' \
    '        [[ "$line" == "sudo"* ]] || continue')
report "S14 (control): any line that starts 'sudo' is sudo's own, sudo-rs's included" "$m" \
       "control, probe: a refusal worded without a 'sudo:' prefix (sudo-rs) is read as granted -- the rule's known limit"
m=$(mutant s15 "$SURFACE" \
    '            [[ "$line" == "sudo: $w"* ]] && { warn=1; break; }' \
    '            [[ "$line" == *": $w"* ]] && { warn=1; break; }')
report "S15: a warning entry is matched after any ': ' in the line" "$m" \
       "probe: a fatal sudo: line naming a command before a warning entry is 2 -- not matched after any ': '"
m=$(mutant s16 "$SURFACE" \
    '        (( warn )) && continue' \
    '        (( warn )) && { NDT_SUDO_UNREAD="$line"; return 0; }')
report "S16 (control): a listed warning is itself read as a line ndt cannot read" "$m" \
       "control, probe: a listed warning followed by a silent refusal is read as granted -- the rule's known limit"
t=$(tmutant t1 "$TEST" \
    '[[ -n "${FAKE_SUDO_WARN:-}" ]] && printf '"'"'%s\n'"'"' "$FAKE_SUDO_WARN" >&2' \
    ': the fake no longer prints its warning')
report_test "T1: the suite's fake sudo stops printing the warning it is given" "$t" \
       "injection took effect: the fake prints the warning, then the refusal it is given"

# --- 🔴 the other direction: refuse-everything, in four shapes -------------------------------------
# Each of these would satisfy every check that M1-M10 above are killed on. They are caught only by the controls, and
# without them this gate would sign off on an `ndt` that can never bring a fabric up at all.

m=$(mutant n1 "$NDT" \
    '    out="$(ndt_sudo_capture ovs-vsctl list-br)" || return 2' \
    '    out="$(ndt_sudo_capture ovs-vsctl list-br)"; return 2')
report "N1 (control): ovs_bridge_count always says 'cannot tell'" "$m" \
       "control, permitted: ovs_bridge_count returns 0 and the real count"

m=$(mutant n2 "$NDT" \
    '    (( srv == 0 )) || return 0' \
    '    (( srv == 0 )) && return 1
    return 0')
report "N2 (control): the guard refuses whenever a topo session exists" "$m" \
       "control, permitted and no bridges: the guard PASSES and the bring-up proceeds"

m=$(mutant n3 "$NDT" \
    '    ovs_daemon_running                   || { echo 0; return 0; }' \
    '    :')
report "N3 (control): no unprivileged early-out, so a P4-only machine cannot start" "$m" \
       "control, no ovs-vswitchd: a definite 0, answered without sudo"

m=$(mutant n4 "$NDT" \
    '    sudo -n mnexec -a "$pid" ping -c 2 -W 2 -q "$2" >/dev/null 2>&1 || return 1' \
    '    return 2')
report "N4 (control): dataplane_ok never tests, so a real outage is never seen" "$m" \
       "control, permitted and the ping really fails: 'not forwarding' is still said"

# --- [Co-developed with claude code -- Adam] a failed `ndtwin-lab status` call is "cannot tell" ------------------
# The session look in guard_no_live_ovs used to be `topo_session || return 0`: rc 2 (the status call itself
# failed) fell through as "no session" and the bring-up went on over a fabric it could not check.

m=$(mutant l1 "$NDT" \
    '    if (( srv == 2 )); then' \
    '    if false; then')
report "L1: the guard reads a failed status call as 'no session' again" "$m" \
       "status call failed: the guard stops the bring-up, rc 5"

m=$(mutant l2 "$NDT" \
    '    out="$(TERM="${TERM:-dumb}" sudo -n "$LAB" status 2>/dev/null)" || return 2' \
    '    out="$(TERM="${TERM:-dumb}" sudo -n "$LAB" status 2>/dev/null)" || return 1')
report "L2: lab_session answers 1 ('no session') for a failed status call" "$m" \
       "real lab_session: a refused status call is rc 2, not 'no session'"

m=$(mutant l3 "$NDT" \
    '        ndt_sudo_explain lab | while IFS= read -r l; do err "$l"; done' \
    '        :')
report "L3: the stop does not print the sudoers line that fixes it" "$m" \
       "status call failed: and prints the line that fixes it"

m=$(mutant l4 "$SURFACE" \
    'so `ndt up p4` stops before it touches the fabric (rc 5), ' \
    'so `ndt status` reports an empty lab, ')
report "L4: the lab row goes back to claiming an empty lab" "$m" \
       "the lab row says what ndt does now: stops before the fabric"

m=$(mutant l5 "$SURFACE" \
    'still calls topo-stop and cleanup (the missing grant refuses those too, so it says they did not run)' \
    'skips the orderly stop')
report "L5: the lab row goes back to claiming a skipped stop" "$m" \
       "the lab row no longer claims a skipped stop"

m=$(mutant l6 "$NDT" \
    '    if (( srv == 2 )); then' \
    '    if (( srv != 0 )); then')
report "L6 (control): the guard stops whenever there is no session too" "$m" \
       "control, real lab_session: and the guard PASSES"

m=$(mutant l7 "$NDT" \
    '    if (( srv == 2 )); then' \
    '    if true; then')
report "L7 (control): the guard stops for every session look" "$m" \
       "control, real lab_session: no bridges under it, the guard PASSES"

# --- [Co-developed with claude code -- Adam] the row's sentence about `ndt down`, the hint's third case, the fake sudo ---
m=$(mutant l8 "$SURFACE" \
    'still calls topo-stop and cleanup (the missing grant refuses those too, so it says they did not run)' \
    'still runs its stop and sweep')
report "L8: the lab row says ndt down still runs its stop and sweep again" "$m" \
       "the lab row says down's stop and sweep are refused too"

m=$(mutant l9 "$NDT" \
    '    case $p in' \
    '    case $(( p == 2 ? 1 : p )) in')
report "L9: the hint answers 'the reason is sudo' when the probe could not tell" "$m" \
       "status call failed, probe cannot read sudo: the hint quotes what sudo said"

m=$(mutant l10 "$NDT" \
    '(no sudo, or $(ndt_sudo_field lab 3) is not installed)' \
    '(no sudo, or the helper is not installed)')
report "L10: the hint for a missing helper does not name its path" "$m" \
       "status call failed, helper not installed: the hint says so and names the path"

m=$(mutant l11 "$NDT" \
    '        0) err "   the grant is permitted but the call did not answer; try:  sudo -n $LAB $verb" ;;' \
    '        0) : ;;')
report "L11 (control): the hint says nothing when the grant is permitted" "$m" \
       "control, probe says granted: the hint says the grant is permitted"

# --- [Co-developed with claude code -- Adam] 2026-11-06: "cannot tell" is rc 5, a live OVS fabric rc 1 ---
m=$(mutant l12 "$NDT" \
    '        lab_status_failed_hint
        return 5
    fi
    (( srv == 0 )) || return 0' \
    '        lab_status_failed_hint
        return 1
    fi
    (( srv == 0 )) || return 0')
report "L12: a failed status call is rc 1 again (measured, and dirty)" "$m" \
       "status call failed: the guard stops the bring-up, rc 5"

m=$(mutant l13 "$NDT" \
    '            ndt_sudo_explain ovs-vsctl | while IFS= read -r l; do err "$l"; done
        fi
        return 5' \
    '            ndt_sudo_explain ovs-vsctl | while IFS= read -r l; do err "$l"; done
        fi
        return 1')
report "L13: a refused ovs-vsctl look is rc 1 again" "$m" \
       "refused: the guard stops the bring-up, rc 5"

m=$(mutant l14 "$NDT" \
    '        err "'"'"'ndt up'"'"' would tear it down to build a bmv2 fabric in its place."
        err "take it down first:  ndt down"
        return 1' \
    '        err "'"'"'ndt up'"'"' would tear it down to build a bmv2 fabric in its place."
        err "take it down first:  ndt down"
        return 5')
report "L14 (control): a live OVS fabric the guard saw becomes 5" "$m" \
       "control: a live OVS fabric it saw is rc 1, not 5"

# [Co-developed with claude code -- Adam] the rows' exit codes and the kept record, 2026-11-06 second pass
m=$(mutant l15 "$SURFACE" \
    'stops before it touches the fabric (rc 5), `ndt status` prints' \
    'stops before it touches the fabric, `ndt status` prints')
report "L15: the lab row drops up's rc 5" "$m" \
       "the lab row gives up's refusal rc 5"

m=$(mutant l16 "$SURFACE" \
    'running under the topo session" (rc 5) before it touches the fabric' \
    'running under the topo session" (rc 1) before it touches the fabric')
report "L16: the ovs-vsctl row says rc 1 again" "$m" \
       "the ovs-vsctl row gives up's refusal rc 5"

m=$(mutant l17 "$SURFACE" \
    ', ends non-zero and keeps the '"'"'ndt up'"'"' record' \
    ' and ends non-zero')
report "L17: the lab row does not say down keeps the record" "$m" \
       "the lab row says down keeps the record"

t=$(tmutant t2 "$TEST" \
    'if [[ "$base" == ndtwin-lab && "$(dirname "$1")" != "$(dirname "$0")" ]]; then' \
    'if false; then')
report_test "T2: the suite's fake sudo runs any ndtwin-lab it is given" "$t" \
       "injection took effect: the fake sudo refuses an ndtwin-lab outside the fixture"

echo
[[ "$(sha256sum "$SURFACE" | cut -d' ' -f1)" == "$BASE_SURFACE" ]] || { echo "🔴 baseline CHANGED -- sudo_surface.sh was written during the gate"; exit 3; }
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (sudo_surface.sh and ndt)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
