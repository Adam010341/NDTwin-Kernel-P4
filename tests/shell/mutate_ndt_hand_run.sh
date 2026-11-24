#!/usr/bin/env bash
#
# Mutation gate for the "program run by hand from examples/" channel of `ndt apps orphans`,
# `ndt down` and `ndt up` -- cells HR1-HR7 and C1-C5 (what `ndt status` says about it) of
# tests/shell/test_ndt_app_orphans.sh, and HR5 of tests/shell/test_orphans_verdict.sh.
#
# [Co-developed with claude code -- Adam]
#
# What the channel is for: a user starts `python examples/p4_energy_saving/energy_saving_sdk.py`
# by hand, and `ndt apps orphans`, `ndt down` and the orphans verdict all said CLEAN over it while
# it went on changing the next fabric. Each mutation below removes or breaks one thing the channel
# does; each must turn the NAMED check red, and a mutation that does not is a survivor.
#
#   M1  the scan is not run                          -> HR1; and HR5 in test_orphans_verdict.sh
#   M2  found is not incremented                     -> HR1 (the report is printed, rc stays 0)
#   M3  argv[0] need not be python                   -> HR2 (tail -f on the same file)
#   M4  a relative script is not resolved by cwd     -> HR1b (bare filename, run from examples/)
#   M5  the .test_run/pids/*.pid exclusion is gone   -> HR4
#   M6  proc_checkout is not asked                   -> HR3 (another checkout's copy)
#   M7  another checkout's copy is not filed         -> HR3 (the elsewhere column)
#   M8  a file need not exist under examples/        -> HR2c
#   M9  the script need not end in .py               -> HR2d
#   M10 a process nobody could attribute is dropped  -> HR7
#   M11 `ndt down` does not name it                  -> HR6 down
#   M12 `ndt down` stops it                          -> HR6 down (still running afterwards)
#   M13 `ndt down` changes its exit status           -> HR6 down (same rc with and without)
#   M14 `ndt up` does not call the scan              -> HR6 up (the up) arm calls it before the plan)
#   M15 a script inside this checkout is not trusted -> HR1c (relative path, started from outside)
#   M16 `ndt status` does not run the scan          -> C1 (no hand-run row)
#   M17 `ndt status` prints no hand-run row         -> C1
#   M18 the hand-run row goes to stderr             -> C1 (the page is read from stdout)
#   M19 the apps row is not changed                 -> C1 (it still reads `none running`)
#   M20 a hand-run program is a `--check` problem   -> C2 (rc and problem lines differ)
#   M21 `ndt status` loses another tree's copy      -> C4 (no elsewhere row)
#   M22 the clean page differs by a byte            -> C3 (the apps row is not exactly `none running`)
#   M23 a tracked app is hidden behind `none started`   -> C1b (the apps row is not exactly the app)
#   M24 an untracked app is hidden behind `none started` -> C1c (the apps row says none was started by ndt)
#
# and two rewordings that change no behaviour and must stay green (W1, W2): a gate that went red
# for any edit to this code would prove nothing when it went red for a mutation.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as a
# survivor, never as skipped. tools/test_workflow/ndt is never written: mutants are whole copies in
# a temp dir, reached through NDT_UNDER_TEST, and the sha256 line at the end says so.
#
# Nothing here compiles anything; the suites start a few python3 sleepers of their own and kill them
# by exact pid. Run it through the shared gate queue, or bare.
#
# Run:  bash tests/shell/mutate_ndt_hand_run.sh
# Exit: 0 every mutation caught and every reword stayed green; 1 a survivor or a reword went red;
#       2 refused (baseline red, or the harness could not set up); 3 ndt changed under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_app_orphans.sh"
TEST_V="$HERE/test_orphans_verdict.sh"
[[ -r "$NDT" && -r "$TEST" && -r "$TEST_V" ]] || { echo "refused: ndt or a test is missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-hand-run-mutate-XXXXXX")"
trap '[[ -n "${BK:-}" && "$BK" == */ndt-hand-run-mutate-* ]] && rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"

# mutant <name> -- a copy of ndt with A/<name>.old replaced by A/<name>.new. The anchors travel as
# FILES so that a shell word never has to survive two levels of quoting; the applier refuses a
# non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at run time.
#
# 🔴 ndt sources ports.sh and sudo_surface.sh from BESIDE ITSELF, so a copy without them exits at
# source time -- silently, because the suites source it with output discarded -- and every case
# then goes red for a reason that has nothing to do with the mutation.
mutant() {
    local name="$1" d="$BK/$name"
    mkdir -p "$d"
    cp "$NDT" "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$d/"
    [[ -r "$REPO/tools/test_workflow/components.env" ]] &&
        cp "$REPO/tools/test_workflow/components.env" "$d/"
    python3 - "$d/ndt" "$A/$name.old" "$A/$name.new" <<'PY'
import sys, io
target, oldf, newf = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(target, encoding='utf-8').read()
o = io.open(oldf, encoding='utf-8').read()
n = io.open(newf, encoding='utf-8').read()
c = s.count(o)
if c != 1:
    print("ANCHOR:%d" % c); sys.exit(0)
io.open(target, 'w', encoding='utf-8').write(s.replace(o, n, 1))
print(target)
PY
}

run_test() { NDT_UNDER_TEST="$1" timeout 300 bash "$TEST" 2>&1; }
run_verdict() { NDT_UNDER_TEST="$1" timeout 300 bash "$TEST_V" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$NDT")"; BASE_RC=$?
BASE_RAN="$(grep -oE 'Ran [0-9]+ checks' <<<"$BASE_OUT" | tail -1)"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
BASE_V_OUT="$(run_verdict "$NDT")"; BASE_V_RC=$?
tail -1 <<<"$BASE_V_OUT" | sed 's/^/  /'
[[ $BASE_V_RC -eq 0 ]] || { echo "refused: the verdict suite is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0; CONTROLS=0; CONTROLS_RED=0

check_fires() {   # <label> <name> <the check text that MUST go red> [also: <the HR5 check text that MUST go red in test_orphans_verdict.sh>]
    local label="$1" name="$2" want="$3" want_v="${4:-}" d out rc ran vout vrc
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-56s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if ! bash -n "$d" 2>/dev/null; then
        printf '  SURVIVED %-56s (mutant does not parse -- proves nothing)\n' "$label"
        SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    # 🔴 "the named check went red" is not enough by itself: a mutation that made the suite ABORT
    # after that check would look identical. The trailing count is the only evidence the run
    # reached the end, and it must match the baseline or the mutation removed checks instead of
    # failing them.
    ran="$(grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        printf '  SURVIVED %-56s (the run did not finish: "%s" vs baseline "%s")\n' "$label" "$ran" "$BASE_RAN"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite still green)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    if ! grep -qF "FAILED   $want" <<<"$out"; then
        printf '  SURVIVED %-56s (red, but NOT on the named check)\n' "$label"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ -n "$want_v" ]]; then
        vout="$(run_verdict "$d")"; vrc=$?
        if [[ $vrc -eq 0 ]] || ! grep -qF "FAILED   $want_v" <<<"$vout" || ! grep -qE '^[0-9]+ passed, [0-9]+ failed' <<<"$vout"; then
            printf '  SURVIVED %-56s (test_orphans_verdict.sh: "%s" did not go red)\n' "$label" "$want_v"
            SURVIVED=$((SURVIVED+1)); return
        fi
        printf '  caught   %-56s (%s; and HR5 "%s" went red)\n' "$label" "$want" "$want_v"
    else
        printf '  caught   %-56s (%s went red)\n' "$label" "$want"
    fi
    CAUGHT=$((CAUGHT+1))
}

check_control() {   # <label> <name> -- a behaviour-preserving edit; both suites must stay GREEN
    local label="$1" name="$2" d out rc vout vrc
    CONTROLS=$((CONTROLS+1))
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  🔴 CONTROL %-53s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    vout="$(run_verdict "$d")"; vrc=$?
    if [[ $rc -eq 0 && $vrc -eq 0 ]]; then
        printf '  control  %-56s (stayed green, as it must)\n' "$label"
    else
        printf '  🔴 CONTROL %-53s (went RED -- this harness reddens for any edit)\n' "$label"
        grep 'FAILED' <<<"$out$vout" | head -3 | sed 's/^/             /'
        CONTROLS_RED=$((CONTROLS_RED+1))
    fi
}

# --- M1: the scan is not run ----------------------------------------------------------------------
cat > "$A/m1.old" <<'EOF'
    hand_run_scan
    for e in ${HAND_RUN[@]+"${HAND_RUN[@]}"}; do
        found=$(( found + 1 ))
EOF
cat > "$A/m1.new" <<'EOF'
    HAND_RUN=()
    for e in ${HAND_RUN[@]+"${HAND_RUN[@]}"}; do
        found=$(( found + 1 ))
EOF
check_fires "M1: apps_orphans never scans for hand-run programs" m1 \
            "HR1 a hand-run example -> rc 1" "  🔴 the verdict is rc 1"

# --- M2: counted nowhere: the report is printed and the exit code and tally stay clean ------------
cat > "$A/m2.old" <<'EOF'
        found=$(( found + 1 ))
        pid="${e%% *}"
        err "hand-run: pid $pid  ${e#* }"
EOF
cat > "$A/m2.new" <<'EOF'
        pid="${e%% *}"
        err "hand-run: pid $pid  ${e#* }"
EOF
check_fires "M2: a hand-run program is named but not counted" m2 "HR1 a hand-run example -> rc 1"

# --- M3: any argv[0] ----------------------------------------------------------------------------------
cat > "$A/m3.old" <<'EOF'
        [[ "$base" == python* ]] || continue
EOF
cat > "$A/m3.new" <<'EOF'
        [[ -n "$base" ]] || continue
EOF
check_fires "M3: argv[0] need not be a python" m3 "HR2 argv[0] is not python (tail -f the same file) -> rc 0"

# --- M4: the cwd is not used to place a relative script ------------------------------------------
cat > "$A/m4.old" <<'EOF'
                p="${cwd:-.}/$el"
EOF
cat > "$A/m4.new" <<'EOF'
                p="./$el"
EOF
check_fires "M4: a relative script is not resolved against the cwd" m4 \
            "HR1b run from inside examples/ by bare filename -> rc 1"

# --- M5: the stack's own pids are candidates too ----------------------------------------------------
cat > "$A/m5.old" <<'EOF'
        [[ "$stackpids" == *" $pid "* ]] && continue
EOF
cat > "$A/m5.new" <<'EOF'
        :
EOF
check_fires "M5: a pid in .test_run/pids/*.pid is a candidate" m5 \
            "HR4 a pid named in .test_run/pids/*.pid -> rc 0"

# --- M6: attribution is never asked: everything that looks right is ours ---------------------------
cat > "$A/m6.old" <<'EOF'
            proc_checkout "$pid"; rc=$?
EOF
cat > "$A/m6.new" <<'EOF'
            rc=0
EOF
check_fires "M6: proc_checkout is not asked about a candidate" m6 "HR3 another checkout's copy -> rc 0"

# --- M7: another checkout's copy is dropped, not listed --------------------------------------------
cat > "$A/m7.old" <<'EOF'
            1) app_elsewhere_add "$pid" hand-run "$PROC_CHECKOUT_WHY" ;;
EOF
cat > "$A/m7.new" <<'EOF'
            1) : ;;
EOF
check_fires "M7: another checkout's copy is not filed as elsewhere" m7 "  listed under seen elsewhere"

# --- M8: a path that is not a file under examples/ still counts -----------------------------------
cat > "$A/m8.old" <<'EOF'
            [[ "$tail" != *..* && -f "$REPO/examples/$tail" ]] && break
EOF
cat > "$A/m8.new" <<'EOF'
            [[ "$tail" != *..* && -n "$tail" ]] && break
EOF
check_fires "M8: the file need not exist under examples/" m8 "HR2c examples/nonesuch.py, not a file there -> rc 0"

# --- M9: any argument under examples/ is a script ------------------------------------------------------
cat > "$A/m9.old" <<'EOF'
            [[ "$el" == *.py ]] || continue
EOF
cat > "$A/m9.new" <<'EOF'
            :
EOF
check_fires "M9: the argument need not end in .py" m9 "HR2d a data file under examples/ beside a script outside it -> rc 0"

# --- M10: "could not tell" is read as "not ours" ------------------------------------------------------
cat > "$A/m10.old" <<'EOF'
            *) HAND_RUN+=("$pid ${hargv[*]:0:12}")
EOF
cat > "$A/m10.new" <<'EOF'
            *) :
EOF
check_fires "M10: a process nobody could attribute is dropped" m10 "HR7 cwd and fds unreadable -> rc 1"

# --- M11: `ndt down` does not name it ----------------------------------------------------------------------
cat > "$A/m11.old" <<'EOF'
        hand_run_warn down
EOF
cat > "$A/m11.new" <<'EOF'
        :
EOF
check_fires "M11: ndt down does not name a hand-run program" m11 "  it names the hand-run program, not stopped"

# --- M12: `ndt down` stops it --------------------------------------------------------------------------------
cat > "$A/m12.old" <<'EOF'
    local mode="$1" e pid
    for e in ${HAND_RUN[@]+"${HAND_RUN[@]}"}; do
        pid="${e%% *}"
EOF
cat > "$A/m12.new" <<'EOF'
    local mode="$1" e pid
    for e in ${HAND_RUN[@]+"${HAND_RUN[@]}"}; do
        pid="${e%% *}"
        [[ "$mode" == down ]] && kill -KILL "$pid" 2>/dev/null
EOF
check_fires "M12: ndt down stops the hand-run program" m12 "  🔴 the program is still running after the teardown"

# --- M13: `ndt down` ends differently when one is running ----------------------------------------------
cat > "$A/m13.old" <<'EOF'
        started=1
        hand_run_warn down
EOF
cat > "$A/m13.new" <<'EOF'
        started=1
        hand_run_warn down
        down_rc=1
EOF
check_fires "M13: ndt down's exit status changes over a hand-run program" m13 \
            "  🔴 and the exit status is the same with and without it"

# --- M14: `ndt up` never calls the scan --------------------------------------------------------------------
cat > "$A/m14.old" <<'EOF'
        hand_run_scan; hand_run_warn up
EOF
cat > "$A/m14.new" <<'EOF'
        :
EOF
check_fires "M14: the up) arm does not call the scan" m14 "  🔴 the up) arm of ndt calls it before the plan runs"

# --- M15: a script that resolves into this checkout is not taken as ours, so a relative path run
# --- from outside the checkout falls to proc_checkout, which cannot see it
cat > "$A/m15.old" <<'EOF'
        if [[ -n "$rp" ]] && path_under_this_checkout "$rp"; then
EOF
cat > "$A/m15.new" <<'EOF'
        if false; then
EOF
check_fires "M15: a script inside this checkout is not taken as ours" m15 \
            "HR1c relative path from outside the checkout -> rc 1"

# --- M16: `ndt status` does not run the scan --------------------------------------------------
cat > "$A/m16.old" <<'EOF'
    hand_run_scan
    if [[ -z "$appson" ]] && [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
cat > "$A/m16.new" <<'EOF'
    HAND_RUN=()
    if [[ -z "$appson" ]] && [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
check_fires "M16: ndt status never scans for hand-run programs" m16 \
            "C1 a live hand-run program -> a hand-run row names its pid"

# --- M17: the row is not printed ------------------------------------------------------------
cat > "$A/m17.old" <<'EOF'
        printf '  %-14s %s\n' "hand-run" "${Y}pid $hrp  $hrargv${N}"
EOF
cat > "$A/m17.new" <<'EOF'
        :
EOF
check_fires "M17: ndt status prints no hand-run row" m17 \
            "C1 a live hand-run program -> a hand-run row names its pid"

# --- M18: the row is printed to stderr --------------------------------------------------
cat > "$A/m18.old" <<'EOF'
        printf '  %-14s %s\n' "hand-run" "${Y}pid $hrp  $hrargv${N}"
EOF
cat > "$A/m18.new" <<'EOF'
        printf '  %-14s %s\n' "hand-run" "${Y}pid $hrp  $hrargv${N}" >&2
EOF
check_fires "M18: the hand-run row goes to stderr" m18 \
            "C1 a live hand-run program -> a hand-run row names its pid"

# --- M19: the apps row still says `none running` ----------------------------------------
cat > "$A/m19.old" <<'EOF'
    if [[ -z "$appson" ]] && [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
cat > "$A/m19.new" <<'EOF'
    if false; then
EOF
check_fires "M19: the apps row is not changed over a hand-run program" m19 \
            "  the apps row is not a bare 'none running'"

# --- M20: a hand-run program is a --check problem ----------------------------------------
cat > "$A/m20.old" <<'EOF'
        printf '  %-14s %s\n' "" "started by hand from this checkout's examples/, tracked by nothing; ndt does not stop it (kill $hrp)$hrnote"
EOF
cat > "$A/m20.new" <<'EOF'
        printf '  %-14s %s\n' "" "started by hand from this checkout's examples/, tracked by nothing; ndt does not stop it (kill $hrp)$hrnote"
        problems+=("a program started by hand is running: pid $hrp")
EOF
check_fires "M20: a hand-run program is a --check problem" m20 \
            "  🔴 --check ends with the same rc with and without it"

# --- M21: another tree's copy is lost from the elsewhere row ------------------------------
cat > "$A/m21.old" <<'EOF'
    hand_run_scan
    if [[ -z "$appson" ]] && [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
cat > "$A/m21.new" <<'EOF'
    hand_run_scan
    app_elsewhere_reset
    if [[ -z "$appson" ]] && [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
check_fires "M21: ndt status drops another checkout's copy" m21 \
            "C4 another checkout's copy -> an elsewhere row naming it"

# --- M22: the clean page differs by a byte --------------------------------------------------
cat > "$A/m22.old" <<'EOF'
        printf '  %-14s %s\n' "apps" "${appson:-none running}"
EOF
cat > "$A/m22.new" <<'EOF'
        printf '  %-14s %s\n' "apps" "${appson:-none running} "
EOF
check_fires "M22: the page with no hand-run program differs by a byte" m22 \
            "  the apps row is exactly that, with no byte after it"

# --- M23: an app ndt started and tracks is hidden behind "none started by ndt" ---------------------
cat > "$A/m23.old" <<'EOF'
    if [[ -z "$appson" ]] && [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
cat > "$A/m23.new" <<'EOF'
    if [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
check_fires "M23: the apps row hides an app ndt started and tracks" m23 \
            "C1b an app ndt started AND a hand-run one: the apps row is exactly the app"

# --- M24: an app ndt started, pidfile gone, is hidden behind "none started by ndt" -------------------
cat > "$A/m24.old" <<'EOF'
    if [[ -z "$appson" ]] && [[ -z "$orphans" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
cat > "$A/m24.new" <<'EOF'
    if [[ -z "$appson" ]] && (( ${#HAND_RUN[@]} > 0 )); then
EOF
check_fires "M24: the apps row hides an app ndt started with no pidfile" m24 \
            "C1c an app ndt started with no pidfile AND a hand-run one: the apps row does not say none was started by ndt"

# --- W1, W2: rewordings that change no behaviour ---------------------------------------------------------
cat > "$A/w1.old" <<'EOF'
        err "    started from this checkout and tracked by nothing; ndt does not stop it, and it acts on"
EOF
cat > "$A/w1.new" <<'EOF'
        err "    run from this checkout and tracked by nothing; ndt does not stop it, and it acts upon"
EOF
check_control "W1: the second line of the orphan report is reworded" w1

cat > "$A/w2.old" <<'EOF'
        pid="${e%% *}"
        if [[ "$mode" == up ]]; then
EOF
cat > "$A/w2.new" <<'EOF'
        pid="${e%% *}"
        if [[ "$mode" != down ]]; then
EOF
check_control "W2: hand_run_warn tests 'not down' instead of 'up'" w2

echo
if [[ "$(sha256sum "$NDT" | cut -d' ' -f1)" != "$BASE_SUM" ]]; then
    echo "🔴 ndt CHANGED under this run: $NDT"; exit 3
fi
echo "tools/test_workflow/ndt unchanged: sha256 $BASE_SUM"
echo
printf '%d mutations caught, %d survived; %d controls, %d went red\n' "$CAUGHT" "$SURVIVED" "$CONTROLS" "$CONTROLS_RED"
(( SURVIVED == 0 && CONTROLS_RED == 0 )) || exit 1
exit 0
