#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_app_package.sh -- the offline drive of
# `ndt up p4 --app <dir>` and the app-package knob's life.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THREE DIRECTIONS, and this gate needs all three.
#   * FIRES: the feature stops doing its job. M1 accepts a package the pre-flight failed; M3
#     and M4 stop clearing the knob, which is how a baseline round silently builds somebody
#     else's exercise; M6 leaves SWITCHES at 10 under a four-switch package; M7 puts the
#     `h1 10.0.0.2` literal back; M8 makes an external package's empty fabric report a routing
#     failure; M10 lets a package and NDT_TOPO name two different models.
#   * WIDENS: M9 makes a rolled-back bring-up delete a knob it never wrote -- every "the knob
#     is gone" cell passes and another session's state is destroyed by a command that failed.
#     M2 removes the exemption a package needs and refuses three-host fabrics.
#   * THE INSTRUMENT: M5 takes away the one `sudo` call a proceeding bring-up makes. Nothing in
#     the refusal half notices -- `sudo=0 stack=0` is what those want -- so what catches it is
#     the positive reading on the proceeding path, which is there precisely so "nothing was
#     touched" cannot be a sentence this harness always says.
#
# 🔴 A mutation that will not apply, a non-unique anchor, a mutant that does not PARSE, or the
# WRONG check going red counts as SURVIVOR -- never as skipped. A control that goes red makes
# the whole round void: a harness that reports red for any edit says nothing when it reports
# red for a mutation.
#
# 🔴 `bash -n` ON EVERY MUTANT, before it is run. `ndt` is sourced by the suite with its output
# discarded, so a mutant with a syntax error defines no functions at all and EVERY cell goes
# red -- which looks exactly like a mutation the suite caught, and would let a badly written
# anchor be scored as evidence. The compile-fail rule the mutation-gate convention already
# carries for the python gates, applied to the one language this gate mutates.
#
# Bare, not wrapped: nothing here compiles anything. tools/test_workflow/ndt is never written
# -- mutants are whole copies in a temp dir, reached through NDT_UNDER_TEST -- and the sha256
# line at the end says so.
#
# Run:  bash tests/shell/mutate_ndt_app_package.sh
# Exit: 0 every mutation caught and the controls survived; 1 a mutation survived or a control
#       went red; 2 refused (baseline red, or the harness could not set up); 3 ndt changed
#       under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_app_package.sh"
[[ -r "$NDT" && -r "$TEST" ]] || { echo "refused: ndt or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-app-pkg-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"

# mutant <name> -- a copy of ndt with A/<name>.old replaced by A/<name>.new. The anchors travel
# as FILES so that a shell word never has to survive two levels of quoting; the applier refuses
# a non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at run time.
#
# 🔴 ndt sources ports.sh and sudo_surface.sh from BESIDE ITSELF, so a copy without them exits
# at source time -- silently, because the suite sources it with output discarded -- and every
# case then goes red for a reason that has nothing to do with the mutation.
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

run_test() { NDT_UNDER_TEST="$1" timeout 600 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$NDT")"; BASE_RC=$?
BASE_RAN="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$BASE_OUT" | tail -1)"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0; CONTROLS=0; CONTROLS_RED=0

check_fires() {   # <label> <name> <the check text that MUST go red>
    local label="$1" name="$2" want="$3" d out rc ran
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-56s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if ! bash -n "$d" 2>/dev/null; then
        printf '  SURVIVED %-56s (the mutant does not PARSE -- a bash -n failure is not a catch)\n' "$label"
        SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    # 🔴 "the named check went red" is not enough by itself: a mutation that made the suite
    # ABORT after that check would look identical. The trailing count is the only evidence the
    # run reached the end, and it must match the baseline or the mutation removed checks
    # instead of failing them.
    ran="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        printf '  SURVIVED %-56s (the run did not finish: "%s" vs baseline "%s")\n' "$label" "$ran" "$BASE_RAN"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite still green)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    if /usr/bin/grep -qF "FAILED   $want" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$label" "$want"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on the named check)\n' "$label"
        /usr/bin/grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVED=$((SURVIVED+1))
    fi
}

check_control() {   # <label> <name> -- a behaviour-preserving edit; the suite must stay GREEN
    local label="$1" name="$2" d out rc
    CONTROLS=$((CONTROLS+1))
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  🔴 CONTROL %-53s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    if ! bash -n "$d" 2>/dev/null; then
        printf '  🔴 CONTROL %-53s (the control does not PARSE -- it is not behaviour-preserving)\n' "$label"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  control  %-56s (stayed green, as it must)\n' "$label"
    else
        printf '  🔴 CONTROL %-53s (went RED -- this harness reddens for any edit)\n' "$label"
        /usr/bin/grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        CONTROLS_RED=$((CONTROLS_RED+1))
    fi
}

# --- M1: a package the pre-flight failed is built anyway ----------------------------------
# The whole point of running somebody else's package through preflight.py is that a red row
# means nothing is built. This is that guard turned off, and its cost is the knob: the file
# that points the next proxy at a package now points it at one that does not parse.
cat > "$A/m1.old" <<'EOF'
        if ! app_preflight "$app_dir"; then
EOF
cat > "$A/m1.new" <<'EOF'
        if app_preflight "$app_dir"; false; then
EOF
check_fires "M1: a FAILED pre-flight is built anyway" m1 "🔴 the knob was NOT written"

# --- M2 (widening): the layout rule a package replaces is applied to it -------------------
# host_count_buildable is a statement about ntg_bmv2_topo.py's four-way splitter. Applied to a
# package, it refuses exercises/p4runtime -- three hosts on three switches -- for violating a
# layout rule that fabric does not use. Every four-host cell in the suite stays green.
cat > "$A/m2.old" <<'EOF'
    [[ "$layout" == package ]] || host_count_buildable "$n" || return 1
EOF
cat > "$A/m2.new" <<'EOF'
    host_count_buildable "$n" || return 1
EOF
check_fires "M2 (widening): the splitter rule is applied to packages" m2 \
            "🔴 a three-host package is built, not refused"

# --- M3: `ndt up` without --app stops clearing the knob -----------------------------------
# The quiet half of the feature. A knob left over from an earlier `--app` run is read by the
# proxy and by p4_testbed_topo.py, so `ndt up p4 4` would build the exercise fabric under a
# banner that says baseline -- and every topology view would read correct.
cat > "$A/m3.old" <<'EOF'
        app_knob_clear "this 'ndt up' asked for the baseline fabric" || return 1
EOF
cat > "$A/m3.new" <<'EOF'
        :
EOF
check_fires "M3: a baseline 'ndt up p4' keeps somebody's package" m3 \
            "🔴 'ndt up p4 4' with no --app clears it"

# --- M4: the teardown side stops clearing it ------------------------------------------------
# 🔴 THIS MUTATION FOUND A REAL DEFECT AND THE FIX IS IN `ndt`, NOT HERE. The first draft
# cleared the knob in BOTH cmd_down (before the teardown) and cmd_clean (`verify clean`, its
# last step). M4 deleted cmd_down's call and the whole suite stayed green -- cmd_clean was
# doing the same job, and there is no path between the teardown starting and that call that
# returns early. Two guards over one fact, where deleting either is invisible: P1-A's M19 in
# startup(), the same week. cmd_down's call is gone; this mutation now points at the one that
# remains, and it takes BOTH verbs' cells down with it, which is the evidence that one call is
# what serves both.
cat > "$A/m4.old" <<'EOF'
    app_knob_clear "this checkout is being put back" || rc=1
EOF
cat > "$A/m4.new" <<'EOF'
    :
EOF
check_fires "M4: the teardown side leaves the knob behind" m4 "🔴 'ndt down' clears it"

# --- M5: the instrument ---------------------------------------------------------------------
# 🔴 INVISIBLE TO EVERY REFUSAL CELL. It takes away the one `sudo -n $LAB topo-start` a
# proceeding bring-up makes, and a refusal wants `sudo=0`. It exists to prove touched() reads
# the machine rather than printing a constant -- which is what would make every
# `sudo=0 stack=0` cell pass over a guard somebody had deleted.
cat > "$A/m5.old" <<'EOF'
        tsout="$(sudo -n "$LAB" topo-start 2>&1)"; tsrc=$?
EOF
cat > "$A/m5.new" <<'EOF'
        tsout=""; tsrc=0
EOF
check_fires "M5: the bring-up stops calling sudo (the instrument)" m5 \
            "🔴 and the machine WAS reached -- the instrument can read non-zero"

# --- M6: SWITCHES stays at the literal 10 under a package ---------------------------------
# Every topology in setting/ has ten switches, which is why 10 could be a constant.
# exercises/basic's pod-topo has four: with this line gone, `[1/3]` waits 180 s for six
# switches that are never coming and then calls the fabric dead.
cat > "$A/m6.old" <<'EOF'
        SWITCHES="$app_sw"
EOF
cat > "$A/m6.new" <<'EOF'
        :
EOF
check_fires "M6: the switch count stays at the literal 10" m6 \
            "  the switch count came from the model too"

# --- M7: the `h1 10.0.0.2` literal, put back ----------------------------------------------
# It is true of the two baseline models and of nothing else. Under exercises/basic it names an
# address no host in that fabric holds, and the ping fails for that reason under a message
# claiming the fabric is up but not forwarding -- a specific claim about routing, manufactured
# from a wrong destination. Exactly the shape verify_dataplane's own header warns about.
cat > "$A/m7.old" <<'EOF'
        verify_dataplane "$src" "$dst" \
EOF
cat > "$A/m7.new" <<'EOF'
        verify_dataplane h1 10.0.0.2 \
EOF
check_fires "M7: the hardcoded ping pair comes back" m7 \
            "ndtwin mode pings the pair the model names"

# --- M8: an external control plane's empty fabric is reported as a fault -------------------
# `mode: external` means the proxy installs no routes: 0 destination paths and no forwarding
# are the DESIGN, not readings. Reporting them as failures makes every p4runtime bring-up end
# `up, but not verified`, and the operator's next move is to debug a fabric that is correct.
cat > "$A/m8.old" <<'EOF'
    if [[ "$mode" == external ]]; then
        warn "proxy: destination paths NOT CHECKED -- this package declares an external control"
EOF
cat > "$A/m8.new" <<'EOF'
    if false; then
        warn "proxy: destination paths NOT CHECKED -- this package declares an external control"
EOF
check_fires "M8: external mode is judged by NDTwin's own routes" m8 \
            "🔴 and NAMES the path count as not checked"

# --- M9 (widening): a rollback deletes a knob it never wrote -------------------------------
# Every "the knob is gone" cell passes, and a bring-up that failed has destroyed a file that
# belongs to whatever is still running. APP_KNOB_WRITTEN is the whole difference, and only the
# control cell for it can see this.
cat > "$A/m9.old" <<'EOF'
    if [[ -n "$APP_KNOB_WRITTEN" ]]; then
        app_knob_clear "this bring-up was rolled back" || rc=1
    fi
EOF
cat > "$A/m9.new" <<'EOF'
    app_knob_clear "this bring-up was rolled back" || rc=1
EOF
check_fires "M9 (widening): rollback clears any knob it finds" m9 \
            "🔴 but NOT one this run did not write"

# --- M10: a package and NDT_TOPO may name two different models -----------------------------
# One of them builds the fabric, the other is handed to the kernel, and every topology view
# reads correct either way. That is the 2026-08-21 defect; this is the check for it removed.
cat > "$A/m10.old" <<'EOF'
            if [[ "$(readlink -f "$cur" 2>/dev/null)" != "$(readlink -f "$app_model" 2>/dev/null)" ]]; then
EOF
cat > "$A/m10.new" <<'EOF'
            if false; then
EOF
check_fires "M10: NDT_TOPO may disagree with the package" m10 \
            "🔴 NDT_TOPO naming another model is refused"

# --- M11: `status --check` stops going red on a knob whose package is gone -----------------
# The row still prints. Only the problem list -- the thing `--check` exits on, and the thing an
# end-of-round script reads -- goes quiet, which is the "red text with a green exit code" shape
# Adam ruled against when E-9 was decided.
cat > "$A/m11.old" <<'EOF'
        STATUS_APP_PROBLEMS+=("the app package knob ($rel) names $state, which does not exist -- the next 'ndt up p4' cannot start its proxy")
EOF
cat > "$A/m11.new" <<'EOF'
        :
EOF
check_fires "M11: a missing package directory is no longer a problem" m11 \
            "  and --check has a problem to exit 1 on"

# --- M12: the OVS plane stops clearing the knob ----------------------------------------------
# The quiet half of M3, on the plane where a stale knob is least likely to be noticed: nothing
# on an OVS fabric reads it, so it survives the whole round and decides the NEXT `ndt up p4`.
# up_ovs's own rollback cannot cover for this -- APP_KNOB_WRITTEN is empty on this plane.
cat > "$A/m12.old" <<'EOF'
    app_knob_clear "this 'ndt up ovs' does not use one" || { rm -f "$fifo" "$out"; return 1; }
EOF
cat > "$A/m12.new" <<'EOF'
    :
EOF
check_fires "M12: 'ndt up ovs 4' keeps somebody's package" m12 \
            "🔴 'ndt up ovs 4' clears it as well"

# --- M13: --app with an empty value falls through to the baseline -----------------------------
# `--app=` and `--app ""` both leave NDT_APP_DIR empty. Read as "no package", the command builds
# the BASELINE fabric and CLEARS the knob -- under an argv that says --app. A flag given with no
# value is a typo, not a request for the default.
cat > "$A/m13.old" <<'EOF'
    if (( seen )) && [[ -z "$NDT_APP_DIR" ]]; then
EOF
cat > "$A/m13.new" <<'EOF'
    if false; then
EOF
check_fires "M13: an empty --app value silently means baseline" m13 \
            "🔴 --app= with an empty value is a usage error"

# --- M14: a proxy that will not start says nothing about why ----------------------------------
# P1-A §4-11 makes proxy_agent/main.py raise AT IMPORT when a package will not load, and
# stack.sh can then only report `proxy did not open :8081`, which under a package is true of
# every possible cause. This puts the silence back.
cat > "$A/m14.old" <<'EOF'
        proxy_log_tail 10
EOF
cat > "$A/m14.new" <<'EOF'
        :
EOF
check_fires "M14: the proxy's own last words are not printed" m14 \
            "🔴 the PROXY's own last words are printed"

# --- the controls: two behaviour-preserving rewrites -----------------------------------------
# 🔴 Without these the round says nothing. A harness that reported red for ANY edit would print
# `11 caught, 0 survived` above while catching nothing at all, and these are the edits that tell
# the two apart: same branch, same message, same file, written the long way.
cat > "$A/c1.old" <<'EOF'
    [[ "$state" == absent ]] && return 0
EOF
cat > "$A/c1.new" <<'EOF'
    if [[ "$state" == absent ]]; then
        return 0
    fi
EOF
check_control "C1: app_knob_clear's early return, written the long way" c1

cat > "$A/c2.old" <<'EOF'
            --app=*) NDT_APP_DIR="${a#--app=}"; seen=1 ;;
EOF
cat > "$A/c2.new" <<'EOF'
            --app=*) NDT_APP_DIR="${a:6}"; seen=1 ;;
EOF
check_control "C2: --app=<dir> stripped by offset instead of prefix" c2

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
