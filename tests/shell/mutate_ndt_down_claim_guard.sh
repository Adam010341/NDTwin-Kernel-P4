#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_down_claim_guard.sh -- the offline drive of `ndt down`'s
# refusal over somebody else's live claim (12-4).
#
# [Co-developed with claude code -- Adam]
#
# FIX-NDT-10 SUMMARY §7-6: that suite's only red was a hand edit somebody made once
# (`if false`, 14 of 30 red, quoted in the FIX document) and then undid. A red nobody repeats is
# a red that exists in a log; this file is what repeats it, every night, from the repo.
#
# 🔴 THE TWO DIRECTIONS, and this gate needs both.
#   * FIRES: the guard stops working. M1 turns it off, M5 turns off the measuring= half, M4 and
#     M6 keep the refusal but break what it SAYS -- the sentence an operator reads, and the retry
#     line ROLE-4 T2 measured pasting a parenthesised description into a command line.
#   * WIDENS: M7 refuses everything. Every refusal cell above passes and the lab becomes
#     impossible to tear down; only the expired-claim control catches it.
#   * THE INSTRUMENT: M2 and M3 take away one of the two things a proceeding teardown touches,
#     one each. Nothing in the refusal half notices -- `sudo=0 stack=0` is what it wants -- so
#     what catches them is the positive reading on the control path (`sudo=2 stack=1`), which is
#     there precisely so that "nothing was touched" cannot be a sentence the harness always says.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as
# SURVIVOR -- never as skipped. A control that goes red makes the whole round void: a harness
# that reports red for any edit says nothing when it reports red for a mutation.
#
# Bare, not wrapped: nothing here compiles anything. tools/test_workflow/ndt is never written --
# mutants are whole copies in a temp dir, reached through NDT_UNDER_TEST -- and the sha256 line
# at the end says so.
#
# Run:  bash tests/shell/mutate_ndt_down_claim_guard.sh
# Exit: 0 every mutation caught and the control survived; 1 a mutation survived or a control went
#       red; 2 refused (baseline red, or the harness could not set up); 3 ndt changed under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_down_claim_guard.sh"
[[ -r "$NDT" && -r "$TEST" ]] || { echo "refused: ndt or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-claim-guard-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"

# mutant <name> -- a copy of ndt with A/<name>.old replaced by A/<name>.new. The anchors travel
# as FILES so that a shell word never has to survive two levels of quoting; the applier refuses a
# non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at run time.
#
# 🔴 ndt sources ports.sh and sudo_surface.sh from BESIDE ITSELF, so a copy without them exits at
# source time -- silently, because the suite sources it with output discarded -- and every case
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
        printf '  SURVIVED %-56s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    # 🔴 "the named check went red" is not enough by itself: a mutation that made the suite ABORT
    # after that check would look identical. The trailing count is the only evidence the run
    # reached the end, and it must match the baseline or the mutation removed checks instead of
    # failing them. (Shape taken from tests/shell/mutate_redirection_order.sh.)
    ran="$(grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        printf '  SURVIVED %-56s (the run did not finish: "%s" vs baseline "%s")\n' "$label" "$ran" "$BASE_RAN"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite still green)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    if grep -qF "FAILED   $want" <<<"$out"; then
        printf '  caught   %-56s (%s went red)\n' "$label" "$want"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on the named check)\n' "$label"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
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
    out="$(run_test "$d")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  control  %-56s (stayed green, as it must)\n' "$label"
    else
        printf '  🔴 CONTROL %-53s (went RED -- this harness reddens for any edit)\n' "$label"
        grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        CONTROLS_RED=$((CONTROLS_RED+1))
    fi
}

# --- M1: the guard itself ---------------------------------------------------------------------
# The hand edit FIX-NDT-10 made once, made permanent. Its red is the one that matters: the
# intruder's teardown really runs, and `touched()` reads sudo=2 stack=1.
cat > "$A/m1.old" <<'EOF'
    if [[ -n "$held" && "$force" != "--force" ]]; then
EOF
cat > "$A/m1.new" <<'EOF'
    if false; then
EOF
check_fires "M1: the foreign-claim guard never fires" m1 "🔴 NOTHING on the machine was reached"

# --- M2 / M3: one number each, from the pair the instrument reads ------------------------------
# 🔴 These two are invisible to every refusal cell -- they take away part of what a PROCEEDING
# teardown does, and a refusal wants that to be nothing. They exist to prove `touched()` is
# reading the machine rather than printing a constant, which is what would make all the
# `sudo=0 stack=0` cells pass over a deleted guard.
cat > "$A/m2.old" <<'EOF'
    local out src ports_deferred=""
    out="$(NO_COLOR=1 bash "$STACK" down 2>&1)"; src=$?
EOF
cat > "$A/m2.new" <<'EOF'
    local out src ports_deferred=""
    out=""; src=0
EOF
check_fires "M2: stack.sh is never invoked (the stack= number)" m2 \
            "🔴 and the machine WAS reached -- the instrument can read non-zero"

cat > "$A/m3.old" <<'EOF'
    say "[2/3] topology session"
    sudo -n "$LAB" topo-stop 2>&1 | sed 's/^/      /'
EOF
cat > "$A/m3.new" <<'EOF'
    say "[2/3] topology session"
    :
EOF
check_fires "M3: [2/3] stops calling sudo (the sudo= number)" m3 \
            "🔴 and the machine WAS reached -- the instrument can read non-zero"

# --- M4: the refusal keeps refusing but stops saying what it is --------------------------------
# One word. An operator who reads "declining" instead of "refusing" is not the loss; a gate that
# keys on the rc alone would sign off on a message that no longer names the claim.
cat > "$A/m4.old" <<'EOF'
        err "refusing to tear down: the lab is claimed by $held"
EOF
cat > "$A/m4.new" <<'EOF'
        err "declining to tear down: the lab is claimed by $held"
EOF
check_fires "M4: the refusal sentence loses one word" m4 "  and it says it is refusing"

# --- M5: the other guard, the one a claim DECLARES ---------------------------------------------
# T2d, 2026-09-11 01:57:27: the owner's own `ndt down` tore out a fabric whose claim said
# `measuring=ROLE-4 reader nsr, do not tear down`, printed clean, and exited 0.
cat > "$A/m5.old" <<'EOF'
    if [[ -n "$declared" && "$force" != "--force" ]]; then
EOF
cat > "$A/m5.new" <<'EOF'
    if false; then
EOF
check_fires "M5: a DECLARED measurement stops guarding" m5 "🔴 our OWN claim that DECLARES a measurement is refused"

# --- M6: ROLE-4 T2's retry line, put back the way it was ---------------------------------------
# `$held` is a DESCRIPTION -- `other-session (until 02:36:24, reader running)`. Pasted, bash reads
# `(until ...)` as a subshell and the command dies on a syntax error.
cat > "$A/m6.old" <<'EOF'
        err "$(printf '    NDT_OWNER=%q ndt down' "$holder")"
EOF
cat > "$A/m6.new" <<'EOF'
        err "    NDT_OWNER=$held ndt down"
EOF
check_fires "M6: the retry line carries the description again" m6 \
            "  🔴 and not the parenthesised description"

# --- M7 (widening): refuse everything ----------------------------------------------------------
# Passes every refusal cell in the file and makes the lab impossible to tear down. The
# expired-claim control is the only thing between this and a green round.
cat > "$A/m7.old" <<'EOF'
    if [[ -n "$held" && "$force" != "--force" ]]; then
EOF
cat > "$A/m7.new" <<'EOF'
    if [[ -e "$CLAIM" && "$force" != "--force" ]]; then
EOF
check_fires "M7 (widening): any claim file at all is a refusal" m7 "an EXPIRED claim is not a refusal"

# --- the control: a behaviour-preserving rewrite ------------------------------------------------
# 🔴 Without this the round says nothing. A harness that reports red for ANY edit would report
# `7 caught, 0 survived` above while catching nothing at all, and this is the edit that tells the
# two apart: same branch, same warning, same text, written the long way.
cat > "$A/c1.old" <<'EOF'
    [[ -n "$declared" ]] && warn "--force: tearing down over a declared measurement -- $declared"
EOF
cat > "$A/c1.new" <<'EOF'
    if [[ -n "$declared" ]]; then
        warn "--force: tearing down over a declared measurement -- $declared"
    fi
EOF
check_control "C1: the --force warning, written the long way" c1

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
