#!/usr/bin/env bash
#
# Mutation gate for the ONE thing tools/test_workflow/stack.sh contributes to TICKET-P3 §2.1:
# the start_bg fingerprint that tells two proxies apart.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS IS ITS OWN GATE FILE AND NOT A CASE IN mutate_ndt_app_package.sh. It was one,
# for an afternoon. tests/shell/check_gate_anchors.py resolves ONE applier per gate file --
# `next((n for n, b in funcs.items() if ".old" in b and ".new" in b), None)` -- and counts
# every `<name>.old` heredoc in that applier's subject, so a second subject inside one gate
# is an anchor counted in the wrong file: `MISSING:2` against tools/test_workflow/ndt for a
# string that was never supposed to be in it. Splitting the subject out is the fix that does
# not require teaching that tool a second applier, which is not this ticket's file to change
# (TICKET-P3 §0-7: check_gate_anchors.py is D's only for the §6.6 HEAD-literal item).
#
# 🔴 WHAT THE FINGERPRINT IS FOR. The proxy reads three files at import and none of them is on
# its command line: host_count_override, app_package_override and now telemetry_override.
# `ndt up p4 --telemetry cooperative` followed by `ndt up p4 --telemetry link` produces two
# proxies with identical argv -- one writing clone sessions and registering switches for sFlow,
# one deliberately doing neither -- and start_bg would REUSE the first. That is the measured
# 128-vs-4 reuse failure (stack.sh:1052-1078's own note) with a third file behind it, and the
# fingerprint is the only thing that can see it.
#
# The suite is tests/shell/test_ndt_app_package.sh, whose section 18 EVALUATES the production
# assignment -- lifted out of stack.sh by its own text, run with KERNEL_DIR pointed at the
# fixture -- reached through STACK_UNDER_TEST, the seam of the same shape NDT_UNDER_TEST is.
#
# 🔴 A mutation that will not apply, a non-unique anchor, a mutant that does not PARSE, or the
# WRONG check going red counts as SURVIVOR -- never as skipped. A control that goes red makes
# the whole round void.
#
# Run:  bash tests/shell/mutate_stack_telemetry_identity.sh
# Exit: 0 every mutation caught and the controls survived; 1 a mutation survived or a control
#       went red; 2 refused (baseline red); 3 stack.sh changed under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="$REPO/tools/test_workflow/stack.sh"
TEST="$HERE/test_ndt_app_package.sh"
[[ -r "$STACK" && -r "$TEST" ]] || { echo "refused: stack.sh or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/stack-telemetry-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$STACK" | cut -d' ' -f1)"

# mutant <name> -- a copy of stack.sh with A/<name>.old replaced by A/<name>.new. The anchors
# travel as FILES so a shell word never has to survive two levels of quoting; the applier
# refuses a non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at
# run time.
mutant() {
    local name="$1" d="$BK/$name"
    mkdir -p "$d"
    cp "$STACK" "$d/stack.sh"
    python3 - "$d/stack.sh" "$A/$name.old" "$A/$name.new" <<'PY'
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

run_test() { STACK_UNDER_TEST="$1" timeout 900 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$STACK")"; BASE_RC=$?
BASE_RAN="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$BASE_OUT" | tail -1)"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0; CONTROLS=0; CONTROLS_RED=0

check_fires() {   # <label> <name> <check text that MUST go red> [<more>...]
    local label="$1" name="$2"; shift 2
    local wants=("$@") want missing=() d out rc ran
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
    ran="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        printf '  SURVIVED %-56s (the run did not finish: "%s" vs baseline "%s")\n' "$label" "$ran" "$BASE_RAN"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite still green)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    for want in "${wants[@]}"; do
        /usr/bin/grep -qF "FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-56s (%d named check(s) went red)\n' "$label" "${#wants[@]}"
        printf '             red: %s\n' "${wants[@]}"
        /usr/bin/grep '^  FAILED' <<<"$out" | sed 's/^  FAILED   /             also red: /'
        CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on every named check)\n' "$label"
        printf '             still green: %s\n' "${missing[@]}"
        SURVIVED=$((SURVIVED+1))
    fi
}

check_control() {   # <label> <name> -- behaviour-preserving; the suite must stay GREEN
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

# --- M1 (TICKET-P3 M-D4): the fingerprint drops the telemetry source -----------------------------
cat > "$A/m1.old" <<'EOF'
            "$KERNEL_DIR/p4_proxy/mininet/app_package_override" 2>/dev/null) telemetry=$(sed -n \
            '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]].*//; p; q' \
            "$KERNEL_DIR/p4_proxy/mininet/telemetry_override" 2>/dev/null) topo=$topo" \
EOF
cat > "$A/m1.new" <<'EOF'
            "$KERNEL_DIR/p4_proxy/mininet/app_package_override" 2>/dev/null) topo=$topo" \
EOF
check_fires "M1: the start_bg fingerprint drops the telemetry source" m1 \
            "🔴 the start_bg fingerprint carries the telemetry source"

# --- M2: the fingerprint reads the knob without stripping comments -------------------------------
# 🔴 THE SAME FILE SHAPE EVERY OTHER READER HONOURS. `ndt` writes a comment line naming who wrote
# it and when; a reader that took the first line would fingerprint the TIMESTAMP, so every
# bring-up would look like a different proxy and start_bg would never reuse one -- the opposite
# failure, and the one that is invisible because restarting always "works".
cat > "$A/m2.old" <<'EOF'
'/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]].*//; p; q' \
            "$KERNEL_DIR/p4_proxy/mininet/telemetry_override" 2>/dev/null) topo=$topo" \
EOF
cat > "$A/m2.new" <<'EOF'
'p; q' \
            "$KERNEL_DIR/p4_proxy/mininet/telemetry_override" 2>/dev/null) topo=$topo" \
EOF
check_fires "M2: the fingerprint reads the knob's comment line" m2 \
            "🔴 the start_bg fingerprint carries the telemetry source"

# --- the control ---------------------------------------------------------------------------------
# 🔴 Without it the two lines above say nothing: a suite that reddened for ANY edit to stack.sh
# would print the same table while catching neither.
cat > "$A/c1.old" <<'EOF'
        START_BG_IDENTITY="hosts=$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
EOF
cat > "$A/c1.new" <<'EOF'
        # the three files the proxy reads at import, none of them on its command line
        START_BG_IDENTITY="hosts=$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
EOF
check_control "C1: a comment above the fingerprint" c1

echo
NOW_SUM="$(sha256sum "$STACK" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/stack.sh was written"
    echo "   before: $BASE_SUM"
    echo "   after:  $NOW_SUM"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/stack.sh  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived; $CONTROLS control(s), $CONTROLS_RED went red"
(( SURVIVED == 0 && CONTROLS_RED == 0 ))
