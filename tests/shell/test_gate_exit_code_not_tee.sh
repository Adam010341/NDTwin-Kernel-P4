#!/usr/bin/env bash
#
# Tests for run_gate(), the helper the E round's gates use to read a gate's exit code.
#
# [Co-developed with claude code -- Adam]
#
# The defect these encode was found on 2026-09-01 while verifying the previous session's handoff.
# gates_e.sh ran its three ratio gates as
#
#     elif <gate> 2>&1 | tee -a "$LOG"; then record ... PASS; else record ... FAIL; abort ...
#
# and nothing in the round sets `pipefail`, so the condition read tee's exit status. tee succeeds
# whenever the write succeeds. All three gates therefore recorded PASS no matter what the gate
# decided, and had done so since 22:03 on 2026-08-31.
#
# The sharpest instance is G6b. It was added that same morning for the sole purpose of making a
# just-fixed code path stop being unread -- a caller shipped to prove a fix works, which would
# have said "works" either way. It had also never actually run: the commit that added it landed
# at 07:50 on 09-01, hours after the last live gate pass.
#
# Case 2 is the load-bearing one and case 3 is its witness: case 3 reproduces the ORIGINAL
# construct against the same failing command and asserts it still reports success, so the fix is
# pinned to a mechanism rather than to a story that fits. Case 5 is the one that stops the defect
# coming back at a call site nobody is looking at.
#
# No fabric, no lab claim: the gate is pointed at t008_poll, the 08-20 cell the live G7 uses.
# [Co-developed with claude code -- Adam] 🔴 CORRECTED 2026-09-27: that cell is NOT in version
# control. Its raw directory ignores itself (raw/.gitignore: `*`) and lives on the audit-raw
# orphan branch, so in every worktree, clone and CI checkout the gate had no data -- UNRUNNABLE,
# rc 2 -- and case 2, which expects rc 2, passed for that wrong reason. The suite now brings a
# MINIMAL SYNTHETIC t008_poll (tests/shell/fixtures/gate_exit_code_not_tee/, README there: the real
# trace's shape, made-up readings, ratio 1.000) and points plot_figures.RAW at a copy of it; and
# case 2 asserts the gate's verdict line as well as its rc, so an UNRUNNABLE can never pass it.
# Case 1b asserts the gate read that fixture (its ratio, 1.0000), not a real trace left on disk.
# [Co-developed with claude code -- Adam] (09-27) case 3 now asserts the gate's OWN rc and verdict
# under the old construct -- it used to be green whatever the gate did (the judge's N2 on d2a9d641) --
# and case 6 holds lib_e.sh's `unset NDT_SAMPLING_RAW_DIR` (NOTE C on 1d5180ce).
#
# 🔴 KNOWN, not fixed here (the opus judge's N7 on d2a9d641): this suite sources round.env, as
# gates_e.sh does, and round.env hardcodes KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel (round.env:13)
# and runs `mkdir -p "$OUT" "$KBIN_STAGE"` (round.env:73). From any worktree or clone it therefore
# touches the MAIN checkout's paths: a no-op where both exist (this laptop, 09-27), a new empty
# directory where they do not, and a suppressed error on a machine with no /home/adam. The fix
# belongs in round.env, which this suite sources because the round does.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_DIR="$HERE/../../doc/audit/2026-08-31_sampling-ceiling-after-merge"
GOODCELL="${RATIO_GOOD_CELL:-t008_poll}"
FIXTURE_DIR="${NOT_TEE_FIXTURE_DIR:-$HERE/fixtures/gate_exit_code_not_tee}"   # the red-first run empties it

PASS=0
FAIL=0

check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

# --- source the SHIPPED helper, never a copy of it -------------------------------------------
# A test that re-implements the branch under test is testing its own copy; this round's own notes
# record that shape three times in two days. run_gate comes from the file gates_e.sh loads.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export ROUND="$ROUND_DIR"
export LOG="$T/test.log"
export DRY_RUN=0
# shellcheck source=/dev/null
. "$ROUND_DIR/round.env" >/dev/null 2>&1 || true
LOG="$T/test.log"          # round.env sets its own LOG; ours is the one under test
# shellcheck source=/dev/null
. "$ROUND_DIR/lib_e.sh"
LOG="$T/test.log"
# [Co-developed with claude code -- Adam] the synthetic cell, copied: the gate reads it, nothing writes here
mkdir -p "$T/raw"; cp "$FIXTURE_DIR"/t008_poll_* "$T/raw/" 2>/dev/null || true
export NDT_SAMPLING_RAW_DIR="$T/raw"

# --- case 6: an inherited NDT_SAMPLING_RAW_DIR never reaches the round's gates -----------------
# [Co-developed with claude code -- Adam] (the opus judge's NOTE C on 1d5180ce, 09-27) round.env unsets
# it, but gates_e.sh, run_e.sh and build_1khz_binary.sh skip round.env when ROUND is already set --
# so lib_e.sh, which each of them sources unconditionally, must drop it as well. Asked in a child
# shell with ROUND set and the variable exported: the operator's own sequence. It sits above the
# PY_PLOT skip so that it runs wherever this suite runs.
case6="$(env NDT_SAMPLING_RAW_DIR=/inherited/raw ROUND="$ROUND_DIR" LOG_BASE="$T/case6.log" \
         bash -c '. "$1/lib_e.sh" >/dev/null 2>&1; printf "%s" "${NDT_SAMPLING_RAW_DIR-unset}"' _ "$ROUND_DIR")"
check "case 6  lib_e.sh drops an inherited NDT_SAMPLING_RAW_DIR (what skips round.env still sources it)" \
      unset "$case6"

if ! declare -F run_gate >/dev/null; then
    echo "FAILED   lib_e.sh does not define run_gate -- the helper under test is gone"
    exit 1
fi
if [[ ! -x "${PY_PLOT:-}" && ! -f "${PY_PLOT:-}" ]]; then
    echo "SKIP: PY_PLOT (${PY_PLOT:-unset}) is not present; the gate cannot be invoked"
    exit 0
fi

GATE=(env PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$ROUND_DIR/ratio_gate.py")

# --- case 1: the accept path.  A green cell asked to be green passes. --------------------------
run_gate "${GATE[@]}" --check "$GOODCELL" --expect green >/dev/null 2>&1
check "case 1  --expect green on a green cell -> caller sees success" 0 "$?"
# [Co-developed with claude code -- Adam] N2 (the opus judge on d2a9d641, 09-27): the gate read THIS
# fixture -- not whatever raw/ the tree has on disk. The real t008_poll is GREEN too (ratio 0.9656),
# so with a broken override every case here passed on a checkout that still has the real trace;
# only the fixture's ratio, exactly 1.0000, tells the two apart.
out1b="$("${GATE[@]}" --check "$GOODCELL" --expect green 2>&1)"
check "case 1b the gate read the synthetic fixture (ratio 1.0000), not a raw/ on disk" \
      "GATE ratio cell=$GOODCELL ratio=1.0000" \
      "$(/usr/bin/grep -m1 -oE '^GATE ratio cell=[^ ]+ ratio=[0-9.]+' <<<"$out1b")"

# --- case 2: THE DEFECT.  A green cell asked to be RED must reach the caller as a failure. -----
# Before the fix this returned 0, and gates_e.sh recorded PASS.
# [Co-developed with claude code -- Adam] 🔴 the rc AND the verdict (2026-09-27): rc 2 is also what an
# UNRUNNABLE gate (no data) returns, so the rc alone passed this case with no cell at all.
out2="$(run_gate "${GATE[@]}" --check "$GOODCELL" --expect red 2>&1)"; rc2=$?
check "case 2  --expect red on a green cell -> caller sees failure" \
      "2 | GATE ratio FORCE-TEST FAILED: expected RED, got GREEN." \
      "$rc2 | $(/usr/bin/grep -m1 -E '^GATE ratio (FORCE-TEST|cell=.*verdict=UNRUNNABLE)' <<<"$out2")"

# --- case 3: the witness.  The original construct, same command, still reports success. --------
# This is not a hypothetical: it is what shipped, and it is why case 2 could not have caught it.
#
# 🔴 `set +o pipefail` is load-bearing, and the first draft of this test got it wrong.  This file
# opens with `set -uo pipefail`, house style for tests here -- under which the old construct
# behaves CORRECTLY and case 3 reports failure, i.e. the harness would have testified that the
# shipped code was fine.  gates_e.sh sets only `set -u` (line 35).  The defect lives entirely in
# that difference, so the reproduction has to run under the shell options the round actually used.
# A harness whose options differ from production's is the same family as a harness that cd's
# somewhere production never goes: both hide a whole class of defect while looking green.
#
# [Co-developed with claude code -- Adam] 🔴 AND THE GATE'S OWN ANSWER (2026-09-27, the opus judge's N2 on
# d2a9d641). "reported-success" alone is what tee says whatever the gate did: an UNRUNNABLE gate (no
# data, rc 2) and a gate that PASSED (rc 0) both read reported-success, so case 3 was green with no
# cell at all and would stay green on a gate that no longer fails. It witnesses "that same failure"
# only if the gate, inside the pipeline, really failed and for the reason case 2 names.
set +o pipefail
: > "$LOG"
if "${GATE[@]}" --check "$GOODCELL" --expect red 2>&1 | tee -a "$LOG" >/dev/null; then
    old_gate_rc=${PIPESTATUS[0]}; old_verdict=reported-success
else
    old_gate_rc=${PIPESTATUS[0]}; old_verdict=reported-failure
fi
set -o pipefail
check "case 3  the pre-fix pipeline hid that same failure (no pipefail, as gates_e.sh runs)" \
      "reported-success | gate rc 2 | GATE ratio FORCE-TEST FAILED: expected RED, got GREEN." \
      "$old_verdict | gate rc $old_gate_rc | $(/usr/bin/grep -m1 -E '^GATE ratio (FORCE-TEST|cell=.*verdict=UNRUNNABLE)' "$LOG")"

# --- case 3b: and gates_e.sh really does still lack pipefail, which is what makes 3 relevant ----
check "case 3b gates_e.sh sets no pipefail, so run_gate is the only thing standing there" 0 \
      "$(grep -cE '^\s*set .*pipefail' "$ROUND_DIR/gates_e.sh")"

# --- case 4: the tee's actual job still happens.  A silent gate is its own defect. -------------
: >"$LOG"
run_gate "${GATE[@]}" --check "$GOODCELL" --expect green >/dev/null 2>&1
check "case 4  gate output still reaches the log" 1 \
      "$(grep -c 'GATE ratio force-test OK' "$LOG")"

# --- case 5: no call site anywhere still pipes a gate straight into an if/elif condition -------
# Case 2 only protects the three sites that exist today. This protects the next one.
#
# 🔴 Line continuations must be joined first, and the first draft of this check did not join them.
# The mutation gate caught it: reverting the G6b call site left the test green, because two of the
# three sites that shipped the defect were written as
#
#     elif <gate> \
#             --args 2>&1 | tee -a "$LOG"; then
#
# and a line-based grep sees `elif` on one line and `| tee ...; then` on the next, matching
# neither. A guard that cannot see the exact shape the defect actually took is decorative --
# and this one would have reported all clear against the code as it shipped.
count_leaks() {
    local f n total=0
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        n=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' "$f" |
            grep -cE '^[[:space:]]*(el)?if .*\|[[:space:]]*tee .*; then')
        total=$((total + n))
    done
    printf '%s\n' "$total"
}
check "case 5  no gate is wired straight into a condition through tee" 0 \
      "$(count_leaks "$ROUND_DIR/gates_e.sh" "$ROUND_DIR/run_e.sh")"

# --- case 5b: the joiner itself works, checked against a fixture, not against the file ---------
# Case 5 passing could mean "no leaks" or "the joiner is broken". A guard that cannot tell those
# apart reads as all-clear in both.
cat >"$T/fixture.sh" <<'FIXTURE'
    elif some_gate \
            --arg 2>&1 | tee -a "$LOG"; then
FIXTURE
check "case 5b the continuation joiner sees a leak written across two lines" 1 \
      "$(count_leaks "$T/fixture.sh")"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
