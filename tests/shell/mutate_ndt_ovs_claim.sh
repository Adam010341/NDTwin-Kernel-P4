#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_ovs_claim.sh -- `ndt up`'s one claim guard on both
# planes, the recorded --force, and the stale-pidfile rule (TICKET-ndt-ovs-claim, Adam 09-25).
#
# [Co-developed with claude code -- Adam]
#
# The three mutants the ticket names are M1, M2 and M3:
#   M1  drop OVS's claim check           -- the 09-24 defect itself, put back
#   M2  the override flag is not recorded -- --force still works, and leaves no trace
#   M3  staleness judged only by file existence -- the 09-14 app_viz.pid shape, put back
# and the rest are the ways each of those three could be half-undone: the P4 plane losing the
# shared call (M6), the guard losing its second half (M7), the override being ignored (M8) or
# honoured from the environment (M19), the guard moved below the first write (M12), the record
# forgetting whose claim (M11), an unrecordable override building anyway (M10), staleness losing
# the group (M4) or the argv (M5), the sweep never called (M14) or removing live files too (M13),
# the subject counting stale entries again (M15), the window not written before the file goes
# (M16), the status row defined and never called (M17), the flag not parsed (M18), and the help
# no longer naming it (M20).
#
# 🔴 THE TWO DIRECTIONS. M9 and M13 WIDEN -- they refuse / remove too much, pass every refusal
# and removal cell, and are caught only by the controls in sections 3 and 9.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as
# SURVIVOR -- never as skipped. A control that goes red voids the round: a harness that reports
# red for any edit says nothing when it reports red for a mutation.
#
# Bare, not wrapped: nothing here compiles anything. tools/test_workflow/ndt is never written --
# mutants are whole copies in a temp dir, reached through NDT_UNDER_TEST -- and the sha256 line at
# the end says so.
#
# Run:  bash tests/shell/mutate_ndt_ovs_claim.sh
# Exit: 0 every mutation caught and every control green; 1 a mutation survived or a control went
#       red; 2 refused (baseline red, or the harness could not set up); 3 ndt changed under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_ovs_claim.sh"
[[ -r "$NDT" && -r "$TEST" ]] || { echo "refused: ndt or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-ovs-claim-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"

# mutant <name> -- a copy of ndt with A/<name>.old replaced by A/<name>.new, and, when the mutant
# moves something, A/<name>.b.old by A/<name>.b.new as well. Anchors travel as FILES so no shell
# word has to survive two levels of quoting; every anchor must occur exactly once.
#
# 🔴 ndt sources ports.sh and sudo_surface.sh from BESIDE ITSELF, so a copy without them exits at
# source time -- silently, because the suite sources it with output discarded.
mutant() {
    local name="$1" d="$BK/$name"
    mkdir -p "$d"
    cp "$NDT" "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$d/"
    [[ -r "$REPO/tools/test_workflow/components.env" ]] &&
        cp "$REPO/tools/test_workflow/components.env" "$d/"
    python3 - "$d/ndt" "$A/$name.old" "$A/$name.new" "$A/$name.b.old" "$A/$name.b.new" <<'PY'
import sys, io, os
target = sys.argv[1]
pairs = [(sys.argv[2], sys.argv[3])]
if os.path.exists(sys.argv[4]):
    pairs.append((sys.argv[4], sys.argv[5]))
s = io.open(target, encoding='utf-8').read()
for oldf, newf in pairs:
    o = io.open(oldf, encoding='utf-8').read()
    n = io.open(newf, encoding='utf-8').read()
    c = s.count(o)
    if c != 1:
        print("ANCHOR:%d" % c); sys.exit(0)
    s = s.replace(o, n, 1)
io.open(target, 'w', encoding='utf-8').write(s)
print(target)
PY
}

run_test() { NDT_UNDER_TEST="$1" timeout 600 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$NDT")"; BASE_RC=$?
BASE_RAN="$(grep -oE 'Ran [0-9]+ checks' <<<"$BASE_OUT" | tail -1)"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0; CONTROLS=0; CONTROLS_RED=0

check_fires() {   # <label> <name> <the check text that MUST go red>
    local label="$1" name="$2" want="$3" d out rc ran
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-60s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    # 🔴 The trailing count is the only evidence the run reached the end; a mutant that made the
    # suite abort after the named check would otherwise look identical to one that failed it.
    ran="$(grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        printf '  SURVIVED %-60s (the run did not finish: "%s" vs baseline "%s")\n' "$label" "$ran" "$BASE_RAN"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-60s (suite still green)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    if grep -qF "FAILED   $want" <<<"$out"; then
        printf '  caught   %-60s (%s went red; %s red in all)\n' "$label" "$want" "$(grep -c 'FAILED' <<<"$out")"
        CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-60s (red, but NOT on the named check)\n' "$label"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVED=$((SURVIVED+1))
    fi
}

check_control() {   # <label> <name> -- a behaviour-preserving edit; the suite must stay GREEN
    local label="$1" name="$2" d out rc
    CONTROLS=$((CONTROLS+1))
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  🔴 CONTROL %-57s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  control  %-60s (stayed green, as it must)\n' "$label"
    else
        printf '  🔴 CONTROL %-57s (went RED -- this harness reddens for any edit)\n' "$label"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        CONTROLS_RED=$((CONTROLS_RED+1))
    fi
}

# =============================================================================================
# The three the ticket names
# =============================================================================================

# --- M1: drop OVS's claim check -- the 09-24 defect, put back ---------------------------------
cat > "$A/m1.old" <<'EOF'
    guard_up_lab_free "ovs $ovs_hosts" || return $?
EOF
cat > "$A/m1.new" <<'EOF'
    :
EOF
check_fires "M1: up_ovs no longer calls the claim guard" m1 \
            "🔴 a foreign claim refuses the OVS bring-up with 5"

# --- M2: the override is not recorded -- --force still works and leaves no trace --------------
cat > "$A/m2.old" <<'EOF'
claim_override_record() {
    local cmd="$1" held="$2" busy="$3" f="$CLAIM.overrides" over=none exp=- note="" meas="" run="" n line
EOF
cat > "$A/m2.new" <<'EOF'
claim_override_record() {
    local cmd="$1" held="$2" busy="$3" f="$CLAIM.overrides" over=none exp=- note="" meas="" run="" n line
    return 0
EOF
check_fires "M2: --force builds and nothing is written down" m2 \
            "🔴 exactly one override is recorded"

# --- M3: staleness judged only by the file existing -- the 09-14 app_viz.pid shape ------------
cat > "$A/m3.old" <<'EOF'
    PF_STATE=unjudged; PF_PID=""; PF_GROUP=""; PF_WHY=""
    base="${f##*/}"
EOF
cat > "$A/m3.new" <<'EOF'
    PF_STATE=unjudged; PF_PID=""; PF_GROUP=""; PF_WHY=""
    [[ -e "$f" ]] && { PF_STATE=live; return 0; }
    base="${f##*/}"
EOF
check_fires "M3: a pidfile that exists is never stale" m3 \
            "🔴 an already-down lab with a stale pidfile is rc 3, not 0"

# =============================================================================================
# The guard, and the override
# =============================================================================================

# --- M6: P4 stops going through the shared guard ----------------------------------------------
cat > "$A/m6.old" <<'EOF'
    guard_up_lab_free "$up_what" || return $?
EOF
cat > "$A/m6.new" <<'EOF'
    :
EOF
check_fires "M6: up_p4 no longer calls the claim guard" m6 \
            "🔴 a foreign claim still refuses the P4 bring-up with 5"

# --- M7: the guard loses its second half, the measurement in flight ---------------------------
cat > "$A/m7.old" <<'EOF'
    held="$(foreign_claim)"
    busy="$(in_flight)"
EOF
cat > "$A/m7.new" <<'EOF'
    held="$(foreign_claim)"
    busy=""
EOF
check_fires "M7: a measurement in flight no longer refuses" m7 \
            "🔴 a measurement in flight refuses the OVS bring-up"

# --- M8: --force is ignored ----------------------------------------------------------------------
cat > "$A/m8.old" <<'EOF'
    if [[ "${NDT_UP_FORCE:-}" != 1 ]]; then
EOF
cat > "$A/m8.new" <<'EOF'
    if true; then
EOF
check_fires "M8: --force no longer opens the guard" m8 "--force is not refused"

# --- M9 (widening): our OWN claim refuses too ----------------------------------------------------
cat > "$A/m9.old" <<'EOF'
    held="$(foreign_claim)"
    busy="$(in_flight)"
EOF
cat > "$A/m9.new" <<'EOF'
    held="$(claim_field owner)"
    busy="$(in_flight)"
EOF
check_fires "M9 (widening): any live claim file refuses, ours included" m9 \
            "our own live claim is not a refusal"

# --- M10: an override that could not be recorded builds anyway ---------------------------------
cat > "$A/m10.old" <<'EOF'
    if ! claim_override_record "$retry --force" "$held" "$busy"; then
EOF
cat > "$A/m10.new" <<'EOF'
    if ! claim_override_record "$retry --force" "$held" "$busy" && false; then
EOF
check_fires "M10: an unrecordable --force builds anyway" m10 \
            "🔴 --force whose record cannot be written is refused"

# --- M11: the record forgets whose claim it went past ------------------------------------------
cat > "$A/m11.old" <<'EOF'
        "$(ovr_flat "${over:-<no owner field>}")" "$(ovr_flat "${exp:--}")" "$(ovr_flat "$note")" \
EOF
cat > "$A/m11.new" <<'EOF'
        "none" "$(ovr_flat "${exp:--}")" "$(ovr_flat "$note")" \
EOF
check_fires "M11: the record does not say whose claim" m11 "  🔴 whose claim was overridden"

# --- M12: the OVS guard moved below the first writes -- a refusal that has half-built -----------
# Moved, not removed: it still refuses, still says so, still returns 5 and still cleans its own
# fifo. What it no longer does is refuse BEFORE up.target is written and the app knob cleared.
cat > "$A/m12.old" <<'EOF'
    guard_up_lab_free "ovs $ovs_hosts" || return $?
EOF
cat > "$A/m12.new" <<'EOF'
EOF
cat > "$A/m12.b.old" <<'EOF'
    claim_note_up "ovs $ovs_hosts"
EOF
cat > "$A/m12.b.new" <<'EOF'
    claim_note_up "ovs $ovs_hosts"
    guard_up_lab_free "ovs $ovs_hosts" || { rm -f "$fifo" "$out"; return 5; }
EOF
check_fires "M12: the OVS guard runs after up.target and the knob" m12 \
            "🔴 NOTHING was reached: no sudo, no stack.sh, no target, no temp, knob kept"

# --- M18: the flag is not parsed -------------------------------------------------------------------
cat > "$A/m18.old" <<'EOF'
        if (( ! want && ! twant )) && [[ "$a" == --force ]]; then NDT_UP_FORCE=1; continue; fi
EOF
cat > "$A/m18.new" <<'EOF'
EOF
check_fires "M18: 'ndt up ... --force' is not parsed" m18 \
            "--force is taken off argv and sets the flag"

# --- M19: an exported NDT_UP_FORCE forces -------------------------------------------------------
cat > "$A/m19.old" <<'EOF'
NDT_UP_FORCE=""
NDT_UP_WORDS=""
up_take_app_flag() {
EOF
cat > "$A/m19.new" <<'EOF'
NDT_UP_WORDS=""
up_take_app_flag() {
EOF
check_fires "M19: NDT_UP_FORCE from the environment opens the guard" m19 \
            "🔴 an exported NDT_UP_FORCE=1 does not open the guard"

# --- M20: the help stops naming the override --------------------------------------------------
cat > "$A/m20.old" <<'EOF'
                  ndt up <any of the above> --force
EOF
cat > "$A/m20.new" <<'EOF'
                  ndt up <any of the above>
EOF
check_fires "M20: 'ndt help' no longer names --force for up" m20 "the up block names the override"

# =============================================================================================
# The stale-pidfile rule
# =============================================================================================

# --- M4: the process group is not asked -- pid only ---------------------------------------------
cat > "$A/m4.old" <<'EOF'
    if [[ "$g" =~ ^[0-9]+$ ]] && (( g > 1 )); then
        PF_GROUP="$g"
EOF
cat > "$A/m4.new" <<'EOF'
    if false; then
        PF_GROUP="$g"
EOF
check_fires "M4: a dead pid is stale even while its group runs" m4 \
            "🔴 pid gone but its process group alive: NOT stale"

# --- M5: the number, not the process -- an app's argv is not asked -----------------------------
cat > "$A/m5.old" <<'EOF'
        if pid_is_app "$pid" "$name"; then PF_STATE=live; return 0; fi
EOF
cat > "$A/m5.new" <<'EOF'
        if pid_alive "$pid"; then PF_STATE=live; return 0; fi
EOF
check_fires "M5: a recycled pid passes for the app" m5 \
            "🔴 a pid alive as somebody else is STALE (pid + argv, not the number)"

# --- M13 (widening): the sweep removes every pidfile, live ones too ------------------------------
cat > "$A/m13.old" <<'EOF'
        [[ "$PF_STATE" == stale ]] || continue
        (( said == 0 )) && { say "stale registry entries"; said=1; }
EOF
cat > "$A/m13.new" <<'EOF'
        (( said == 0 )) && { say "stale registry entries"; said=1; }
EOF
check_fires "M13 (widening): 'down' removes live pidfiles too" m13 "🔴 a LIVE pidfile is kept"

# --- M14: 'down' never calls the sweep -----------------------------------------------------------
cat > "$A/m14.old" <<'EOF'
    registry_clear_stale || {
EOF
cat > "$A/m14.new" <<'EOF'
    true || {
EOF
check_fires "M14: 'down' leaves the stale pidfile where it is" m14 "🔴 the stale pidfile is GONE"

# --- M15: the subject counts stale entries again (the pre-09-25 registry) -----------------------
cat > "$A/m15.old" <<'EOF'
        [[ "$PF_STATE" == stale ]] && continue
        printf '%s\n' "${f#$REPO/}"
EOF
cat > "$A/m15.new" <<'EOF'
        printf '%s\n' "${f#$REPO/}"
EOF
check_fires "M15: a stale entry is a subject again" m15 \
            "🔴 an already-down lab with a stale pidfile is rc 3, not 0"

# --- M16: the file goes and the window does not get written ---------------------------------------
cat > "$A/m16.old" <<'EOF'
            app_window_record "$name" "$start" "$end" \
EOF
cat > "$A/m16.new" <<'EOF'
            false \
EOF
check_fires "M16: the app's window is lost with its pidfile" m16 \
            "🔴 the app's window was written down before the file went"

# --- M17: the status row is defined and nothing calls it ----------------------------------------
cat > "$A/m17.old" <<'EOF'
    # [Co-developed with claude code -- Adam] Adam, 2026-09-25: a stale app pidfile is marked.
    app_pidfile_stale_row
EOF
cat > "$A/m17.new" <<'EOF'
    :
EOF
check_fires "M17: 'ndt status' never prints the stale-app row" m17 \
            "🔴 and 'ndt status' itself prints that row (existence is not wiring)"

# =============================================================================================
# The controls
# =============================================================================================
cat > "$A/c1.old" <<'EOF'
    [[ -n "$held" ]] && warn "--force: building over the claim of $held"
EOF
cat > "$A/c1.new" <<'EOF'
    if [[ -n "$held" ]]; then
        warn "--force: building over the claim of $held"
    fi
EOF
check_control "C1: the --force warning, written the long way" c1

cat > "$A/c2.old" <<'EOF'
        PF_WHY="$PF_WHY; process group $g empty"
EOF
cat > "$A/c2.new" <<'EOF'
        printf -v PF_WHY '%s; process group %s empty' "$PF_WHY" "$g"
EOF
check_control "C2: the stale reason, built with printf -v" c2

echo
NOW_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_SUM"
    echo "   after:  $NOW_SUM"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived; $CONTROLS control(s), $CONTROLS_RED went red"
(( SURVIVED == 0 && CONTROLS_RED == 0 ))
