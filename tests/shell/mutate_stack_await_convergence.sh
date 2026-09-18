#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_stack_await_convergence.sh -- the offline drive of
# `stack.sh await_convergence` and the proxy's "I sent no LLDP" disclosure.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THREE DIRECTIONS, and this gate needs all three.
#   * FIRES: M1 takes the whole skip away, which is the 2026-09-18 live defect restored -- 300 s
#     burned on every package bring-up, four driver rounds at 7.5 minutes each. M7 makes the
#     skip return a failure; M8 stops quoting the list it acted on, leaving a decision nobody
#     can audit.
#   * WIDENS: M2 fires the skip on ANY non-empty skip list, so a fabric that IS beaconing stops
#     being waited for and the kernel is released against a control plane still converging --
#     the race the whole function exists to remove. M3 reads an unreadable proxy as "nothing to
#     wait for": the same release, on the endpoint's silence. M5 asks the OVS plane about a P4
#     endpoint it does not have.
#   * THE INSTRUMENT: M6 collapses the bounded re-read to a single attempt. Every behavioural
#     cell stays green -- the fall-through is the same -- so what catches it is the positive
#     count of `/p4/switch_state` calls, which is there precisely so "it fell through" cannot be
#     a sentence this harness always says. M4 is its twin one layer down: `skipped: null` read as
#     `[]` turns "startup has not finished" into "nothing was skipped", and the only cells that
#     see it are the rc of the reader and that same counter.
#
# 🔴 A mutation that will not apply, a non-unique anchor, a mutant that does not PARSE, or the
# WRONG check going red counts as SURVIVOR -- never as skipped. A control that goes red makes
# the whole round void.
#
# 🔴 `bash -n` ON EVERY MUTANT before it is run: the suite sources stack.sh with its output
# discarded, so a mutant with a syntax error defines no functions at all and every cell goes red
# -- which looks exactly like a mutation this gate caught.
#
# Bare, not wrapped: nothing here compiles anything. tools/test_workflow/stack.sh is never
# written -- mutants are whole copies in a temp dir, reached through STACK_UNDER_TEST -- and the
# sha256 line at the end says so.
#
# Run:  bash tests/shell/mutate_stack_await_convergence.sh
# Exit: 0 every mutation caught and the controls survived; 1 a mutation survived or a control
#       went red; 2 refused (baseline red, or the harness could not set up); 3 stack.sh changed
#       under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="$REPO/tools/test_workflow/stack.sh"
TEST="$HERE/test_stack_await_convergence.sh"
[[ -r "$STACK" && -r "$TEST" ]] || { echo "refused: stack.sh or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/stack-await-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$STACK" | cut -d' ' -f1)"

# mutant <name> -- a copy of stack.sh with A/<name>.old replaced by A/<name>.new. The anchors
# travel as FILES so a shell word never has to survive two levels of quoting; the applier refuses
# a non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at run time.
#
# 🔴 stack.sh sources components.env and ports.sh from BESIDE ITSELF, so a copy without them
# exits at source time -- silently, because the suite sources it with output discarded -- and
# every case then goes red for a reason that has nothing to do with the mutation.
mutant() {
    local name="$1" d="$BK/$name"
    mkdir -p "$d"
    cp "$STACK" "$d/stack.sh"
    cp "$REPO/tools/test_workflow/components.env" "$REPO/tools/test_workflow/ports.sh" "$d/"
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

run_test() { STACK_UNDER_TEST="$1" timeout 600 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$STACK")"; BASE_RC=$?
BASE_RAN="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$BASE_OUT" | tail -1)"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0; CONTROLS=0; CONTROLS_RED=0

check_fires() {   # <label> <name> <check text that MUST go red> [<more check texts>...]
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
    # 🔴 "the named check went red" is not enough on its own: a mutation that made the suite
    # ABORT after that check would look identical. The trailing count is the only evidence the
    # run reached the end, and it must match the baseline.
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
        # Every OTHER cell this mutation reddened, so "which test kills which mutation" can be
        # rebuilt from the log rather than from memory.
        /usr/bin/grep '^  FAILED' <<<"$out" | sed 's/^  FAILED   /             also red: /'
        CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on every named check)\n' "$label"
        printf '             still green: %s\n' "${missing[@]}"
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

# --- M1: the skip is gone -- 2026-09-18 restored ---------------------------------------------
# Every package bring-up waits the whole CONVERGE_WAIT for destination paths the proxy has said
# it will never install, and then proceeds with a warning. Measured that day: 300 s per
# bring-up, `4/12 destination paths, never settled` over a fabric pinging 0% loss on all twelve
# ordered pairs, and four driver rounds at 7.5 minutes each.
cat > "$A/m1.old" <<'EOF'
    if [[ "$mode" != "ovs" ]]; then
        local skipped; skipped="$(proxy_skipped_steps)"
EOF
cat > "$A/m1.new" <<'EOF'
    if false; then
        local skipped; skipped="$(proxy_skipped_steps)"
EOF
# 🔴 NOT the rc: this function returns 0 whether it converged, timed out, or skipped -- that is
# deliberate (`ndt up` decides for itself in [3/3]) and it is why "did it wait" has to be read
# off what it DID. The path poll is the observable: a fall-through polls the endpoint, the skip
# never touches it.
check_fires "M1: the proxy's skip list is never read" m1 \
            "🔴 the path count is never polled at all" \
            "🔴 and says the wait did not happen"

# --- M2 (widening): ANY skipped step means do not wait ----------------------------------------
# The proxy skips things for several unrelated reasons -- a switch with no sFlow callback skips
# `sflow_telemetry` while LLDP runs normally. Firing on the list being non-empty releases the
# kernel against a control plane that is still discovering links, which is the race
# await_convergence exists to remove, and no behavioural cell about packages would notice.
cat > "$A/m2.old" <<'EOF'
        if [[ ",$skipped," == *,lldp_discovery,* ]]; then
EOF
cat > "$A/m2.new" <<'EOF'
        if [[ -n "$skipped" ]]; then
EOF
check_fires "M2 (widening): any skipped step at all cancels the wait" m2 \
            "🔴 a skip list without lldp_discovery still waits"

# --- M3 (widening): the endpoint's SILENCE cancels the wait ------------------------------------
# "I did not look" and "I could not ask" are not the same answer. A proxy that has not finished
# starting, or is not answering yet, would release the kernel immediately -- against a fabric
# that is about to start discovering links.
cat > "$A/m3.old" <<'EOF'
        local skipped; skipped="$(proxy_skipped_steps)"
EOF
cat > "$A/m3.new" <<'EOF'
        local skipped; skipped="$(proxy_skipped_steps || echo lldp_discovery)"
EOF
check_fires "M3 (widening): a silent proxy is read as 'nothing to wait for'" m3 \
            "🔴 an answer with no control_plane falls through to today's wait" \
            "🔴 skipped: null (startup unfinished) falls through to today's wait" \
            "🔴 an endpoint that does not answer falls through to today's wait"

# --- M4 (the instrument, one layer down): `skipped: null` read as `[]` -------------------------
# proxy_agent/main.py:455-459 keeps those two apart on purpose: `null` is "startup has not
# finished", `[]` is "every step ran". Collapsing them makes the reader answer "nothing was
# skipped" for a proxy that has not decided yet -- and every behavioural cell stays green,
# because an empty list falls through to the wait either way. What sees it is the rc of the
# reader and the call counter.
cat > "$A/m4.old" <<'EOF'
skipped = cp.get("skipped")
if skipped is None:
    raise SystemExit(1)
EOF
cat > "$A/m4.new" <<'EOF'
skipped = cp.get("skipped") or []
EOF
check_fires "M4: 'the proxy has not said' becomes 'nothing was skipped'" m4 \
            "🔴 while 'the proxy has not said' is rc 1" \
            "  after a BOUNDED re-read, not one try and not forever"

# --- M5 (widening): the OVS plane is asked about a P4 endpoint --------------------------------
# OVS has no /p4/switch_state. Every OVS bring-up would spend the re-read budget on an endpoint
# that is not there -- and if something ever DID answer on :8081 while an OVS fabric was up, the
# wait the OVS plane needs would be skipped on the strength of it.
cat > "$A/m5.old" <<'EOF'
    if [[ "$mode" != "ovs" ]]; then
        local skipped; skipped="$(proxy_skipped_steps)"
EOF
cat > "$A/m5.new" <<'EOF'
    if true; then
        local skipped; skipped="$(proxy_skipped_steps)"
EOF
check_fires "M5 (widening): OVS is asked about the P4 endpoint" m5 \
            "🔴 the P4 endpoint is not consulted on the OVS plane"

# --- M6 (the instrument): the bounded re-read collapses to one try ----------------------------
# 🔴 INVISIBLE TO EVERY BEHAVIOURAL CELL. The fall-through is identical; what changes is that a
# proxy which was one second from answering is recorded as never having answered. It exists to
# prove the call counter reads the machine rather than printing a constant.
cat > "$A/m6.old" <<'EOF'
    for i in 1 2 3 4 5; do
EOF
cat > "$A/m6.new" <<'EOF'
    for i in 1; do
EOF
check_fires "M6: the re-read is a single attempt (the instrument)" m6 \
            "  after a BOUNDED re-read, not one try and not forever"

# --- M7: the skip reports a failure -------------------------------------------------------------
# `up p4` treats a non-zero here as "the stack did not come up" and rolls back. A fabric that is
# working perfectly would be torn down for having been correctly diagnosed.
cat > "$A/m7.old" <<'EOF'
            info "  link discovery: NOT WAITED -- the proxy says it sends no LLDP on this fabric (control_plane.skipped: ${skipped//,/, })"
            return 0
EOF
cat > "$A/m7.new" <<'EOF'
            info "  link discovery: NOT WAITED -- the proxy says it sends no LLDP on this fabric (control_plane.skipped: ${skipped//,/, })"
            return 1
EOF
check_fires "M7: not waiting is reported as a failure" m7 \
            "🔴 it returns success without waiting"

# --- M8: the decision stops quoting what it was made on ----------------------------------------
# The line is the only record that this bring-up skipped a check, and the list is the only
# evidence for why. Without it the log says a wait did not happen and nothing says what the
# proxy actually reported -- a decision an auditor cannot reconstruct.
cat > "$A/m8.old" <<'EOF'
            info "  link discovery: NOT WAITED -- the proxy says it sends no LLDP on this fabric (control_plane.skipped: ${skipped//,/, })"
EOF
cat > "$A/m8.new" <<'EOF'
            info "  link discovery: NOT WAITED -- the proxy says it sends no LLDP on this fabric"
EOF
check_fires "M8: the skip line stops naming the list it read" m8 \
            "  and quoting the list it read"

# --- the controls: two behaviour-preserving rewrites -------------------------------------------
# 🔴 Without these the round says nothing. A harness that reported red for ANY edit would print
# `8 caught, 0 survived` above while catching nothing at all.
cat > "$A/c1.old" <<'EOF'
        if [[ ",$skipped," == *,lldp_discovery,* ]]; then
EOF
cat > "$A/c1.new" <<'EOF'
        if [[ ",${skipped}," == *",lldp_discovery,"* ]]; then
EOF
check_control "C1: the membership test, written the long way" c1

cat > "$A/c2.old" <<'EOF'
    local i out
    for i in 1 2 3 4 5; do
EOF
cat > "$A/c2.new" <<'EOF'
    local i out
    for i in $(seq 1 5); do
EOF
check_control "C2: the re-read bound counted by seq instead of literals" c2

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
