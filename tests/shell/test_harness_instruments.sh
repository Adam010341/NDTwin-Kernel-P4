#!/usr/bin/env bash
#
# Regression tests for the T-4 harness's own instruments.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS EXISTS. The T-4 full-stack round's first live run produced five findings, four of
# which were defects in the instrument rather than in NDTwin. Three of them are here:
#
#   FINDING-02 Defect A  three of the four rows in the R-3 convergence table were `T0 + i`,
#                        where `i` is WHICH ITERATION OF A WAIT LOOP MATCHED and T0 is when
#                        `ndt up` was invoked. viz printed +5 s against a true ~+229 s.
#   FINDING-02 Defect B  `port_holder` returned the empty string for a root-owned listener,
#                        which every caller read as "nothing is listening". sim is started as
#                        root, so sim's liveness check could not succeed by construction.
#   FINDING-05           a watch window registered as 240 s ran 474 s, and was reported as
#                        "in 240s", because the loop counted iterations and the per-sample
#                        query cost was not counted.
#
# All three were fixed on 2026-08-30 (T-9/T-10) and NONE of them left a permanent test behind:
# the acceptance ran in a throwaway worktree against extracted-logic fixtures. This file is that
# missing half. Everything below runs against the SHIPPED harness files -- lib.sh is sourced,
# not reimplemented -- because this repo has already paid for a round of patches applied to a
# copy of the file that was never the one being executed.
#
# NOTHING HERE TOUCHES THE LAB. No `ndt`, no `ndtwin-lab`, no Mininet, no sudo, no real `ss`,
# no network. `ss` is shimmed on PATH, the clock is passed in as an argument, and every artefact
# lands in a mktemp directory that is removed on exit.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="$HERE/../../doc/audit/2026-08-30_live-full-stack-round"
LIB="$ROUND/harness/lib.sh"
LIFECYCLE="$ROUND/harness/20_apps_lifecycle.sh"
ENERGY="$ROUND/harness/25_apps_energy.sh"

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

for f in "$LIB" "$LIFECYCLE" "$ENERGY"; do
    [[ -f "$f" ]] || { echo "SKIP: $f not found"; exit 0; }
done

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/out"

# -------------------------------------------------------------------------------------------------
# The `ss` shim.
#
# It replays REAL `ss -lptnH` output shapes, and the distinction between the two non-free ones is
# the whole point of group 1: run unprivileged against a socket owned by another user, `ss` still
# prints the LISTEN line but OMITS the users:(("...",pid=N,...)) field, because resolving a socket
# inode to a pid means reading /proc/<pid>/fd/ and this uid may not. So the line is present and the
# pid is not, and the old two-valued port_holder collapsed that into "free".
#
# Driven by $SS_MODE so a test can choose which of the three the shim answers with.
# -------------------------------------------------------------------------------------------------
cat > "$SANDBOX/bin/ss" <<'SHIM'
#!/usr/bin/env bash
case "${SS_MODE:-free}" in
    free) exit 0 ;;
    mine)   printf 'LISTEN 0      4096         0.0.0.0:9000      0.0.0.0:*    users:(("kernel",pid=284117,fd=7))\n' ;;
    hidden) printf 'LISTEN 0      4096         0.0.0.0:9000      0.0.0.0:*   \n' ;;
esac
SHIM
chmod +x "$SANDBOX/bin/ss"
export PATH="$SANDBOX/bin:$PATH"
# EXPORTED, and that is not a detail. `ss` is a separate process; a plain `SS_MODE=hidden`
# assignment would stay in this shell and the shim would answer `free` to every case, so the two
# rows that matter would have gone green against a shim that never produced their input. Caught by
# running the suite, not by reading it -- the same way FINDING-02 was found.
export SS_MODE=free

# Point every lib.sh artefact at the sandbox before sourcing it, so the shared round directory is
# never written to. KERNEL_DIR is the name lib.sh itself honours for "the tree under test".
export KERNEL_DIR="$SANDBOX"
export OUT="$SANDBOX/out"
export RUN_TAG="test-harness-instruments"

# lib.sh sets `set -Eeuo pipefail`. That is what the harness runs under, so the tests run under it
# too -- but it means an assertion has to capture rc without a pipe, which is what run_rc does.
# shellcheck source=/dev/null
source "$LIB"

run_rc() {  # run_rc <cmd...> -- echo the rc, never let it abort the suite
    local rc=0
    "$@" > "$SANDBOX/last.out" 2>&1 || rc=$?
    printf '%s' "$rc"
}
last_out() { cat "$SANDBOX/last.out"; }

echo
echo "=== group 1: port_holder is three-valued (FINDING-02 Defect B) ==="

export SS_MODE=free   ; check "no LISTEN line          -> '' (FREE)"                "" "$(port_holder 9000)"
export SS_MODE=mine   ; check "LISTEN line with pid=   -> the pid"            "284117" "$(port_holder 9000)"
# THE LOAD-BEARING CASE. Before the fix this returned '' and read as "nothing there".
export SS_MODE=hidden ; check "LISTEN line, no pid=    -> the sentinel" \
                       "LISTENER-OWNER-HIDDEN" "$(port_holder 9000)"

# The sentinel must be distinguishable from a pid by a caller that forgot to handle it: a
# non-numeric string makes such a caller fail visibly instead of quietly meaning something else.
export SS_MODE=hidden
check "the sentinel is not numeric" "not-numeric" \
      "$( [[ "$(port_holder 9000)" =~ ^[0-9]+$ ]] && echo numeric || echo not-numeric )"

echo
echo "=== group 2: 'is anything listening' is decided by the LISTEN line, not by the pid ==="

export SS_MODE=free   ; check "port_is_bound  free   -> false" "1" "$(run_rc port_is_bound 9000)"
export SS_MODE=mine   ; check "port_is_bound  mine   -> true"  "0" "$(run_rc port_is_bound 9000)"
# This is the check sim's wait loop asks. It could not succeed before the fix.
export SS_MODE=hidden ; check "port_is_bound  hidden -> true"  "0" "$(run_rc port_is_bound 9000)"

echo
echo "=== group 3: assert_port_is keeps UNREADABLE separate from none (sentinel family) ==="

reset_counts() { CHECKS=0; FAILS=0; }
# `$(assert_port_is ...)` would run it in a SUBSHELL, and lib.sh's FAILS counter would be
# incremented in that subshell and discarded -- so "does not increment FAILS" would pass no matter
# what the function did. run_rc redirects instead, which keeps the mutation in this shell where the
# assertion can see it. The first draft used the subshell form and the vacuous check went green.
verdict_of() { last_out | grep -oE 'PASS|FAIL|N/A' | head -1; }

export SS_MODE=hidden; reset_counts
run_rc assert_port_is sim 9000 12345 > /dev/null
check "hidden -> N/A (UNTESTABLE), not PASS and not FAIL" "N/A" "$(verdict_of)"
check "hidden -> the message says the owner is not visible" "yes" \
      "$(last_out | grep -qi 'not visible' && echo yes || echo no)"
check "hidden -> does NOT increment FAILS" "0" "$FAILS"

export SS_MODE=free; reset_counts
run_rc assert_port_is sim 9000 12345 > /dev/null
check "free   -> FAIL 'nothing is listening'" "FAIL" "$(verdict_of)"
check "free   -> DOES increment FAILS"        "1"    "$FAILS"

export SS_MODE=mine; reset_counts
run_rc assert_port_is sim 9000 284117 > /dev/null
check "mine, pid matches -> PASS" "PASS" "$(verdict_of)"

export SS_MODE=mine; reset_counts
run_rc assert_port_is sim 9000 999999 > /dev/null
check "mine, pid differs  -> FAIL (P-1 orphan)" "FAIL" "$(verdict_of)"

echo
echo "=== group 4: the registered window is COMPARED to the executed one (FINDING-05) ==="
#
# The defect this group exists for is not that the 08-30 window was wrong -- it is that nothing
# in the run compared 240 to 474. The two numbers were printed with info(), which does not count
# a check, does not count a failure and writes no verdict, so the run proceeded. A self-measurement
# that can only print cannot hold a loop honest.

reset_counts
# NOT `$(run_rc ...)`. Wrapping it in a command substitution puts the call in a subshell and the
# FAILS increment dies with it, so "it is counted as a failure" would read 0 whatever the function
# did -- a check that cannot go red. The first draft did exactly that and this line caught it.
run_rc assert_window_span energy_watch 240 474 > /dev/null
check "08-30's real numbers go RED"        "FAIL" "$(verdict_of)"
check "and the line names all three"       "yes" \
      "$(last_out | grep -q 'registered=240' && \
         last_out | grep -q 'actual=474'     && \
         last_out | grep -q 'overrun=234'    && echo yes || echo no)"
check "and it is counted as a failure"     "1" "$FAILS"

reset_counts
run_rc assert_window_span energy_watch 240 249 > /dev/null
check "a structural overrun (one sleep) passes" "PASS" \
      "$(last_out | grep -oE 'PASS|FAIL|N/A' | head -1)"
check "and counts no failure"                   "0" "$FAILS"

# The dangerous direction. A deadline-driven loop CANNOT end before its deadline, so any shortfall
# at all means the loop has stopped being deadline-driven -- and then "nothing happened" is a
# statement about our patience, which is precisely what the registered window exists to rule out.
reset_counts
run_rc assert_window_span energy_watch 240 200 > /dev/null
check "an UNDERRUN goes RED even by 40 s" "FAIL" "$(last_out | grep -oE 'PASS|FAIL|N/A' | head -1)"
check "and says which direction"          "yes" \
      "$(last_out | grep -qi 'UNDERRUN' && echo yes || echo no)"

reset_counts
run_rc assert_window_span energy_watch 240 239 > /dev/null
check "an UNDERRUN of 1 s still goes RED" "FAIL" "$(last_out | grep -oE 'PASS|FAIL|N/A' | head -1)"

# A tolerance a caller can widen deliberately, but not by accident.
reset_counts
run_rc assert_window_span energy_watch 240 474 300 > /dev/null
check "an explicitly widened tolerance passes" "PASS" \
      "$(last_out | grep -oE 'PASS|FAIL|N/A' | head -1)"

echo
echo "=== group 5: the span reaches the artefacts, whatever the verdict ==="
#
# Before the fix only WATCH_ACTUAL was written to disk. WATCH_S never reached any file, so nobody
# reading raw/ afterwards could tell whether the window had been honoured. The overrun had never
# been computed at all.

rm -f "$OUT/energy_watch_span.tsv"
reset_counts
run_rc assert_window_span energy_watch 240 474 > /dev/null
SPAN_TSV="$OUT/energy_watch_span.tsv"
check "a RED verdict still writes the span file" "yes" \
      "$( [[ -s "$SPAN_TSV" ]] && echo yes || echo no )"
check "the file carries registered, actual and overrun" "240 474 234" \
      "$(awk -F'\t' 'NR==2 {print $2, $3, $4}' "$SPAN_TSV")"
check "the file carries the verdict"             "OVERRUN" \
      "$(awk -F'\t' 'NR==2 {print $5}' "$SPAN_TSV")"

rm -f "$SPAN_TSV"
reset_counts
run_rc assert_window_span energy_watch 240 245 > /dev/null
check "a GREEN verdict writes it too"            "OK" \
      "$(awk -F'\t' 'NR==2 {print $5}' "$SPAN_TSV")"

echo
echo "=== group 6: source guards -- the two defect SHAPES stay out (FINDING-02 A, FINDING-05) ==="
#
# HONEST LABEL: these are source-shape guards, not behavioural tests. They are here because the
# behavioural alternative is to extract the loop into a fixture and drive the fixture -- which
# tests the copy, and this repo has already lost a whole comparison round to a patch applied to a
# copy that was never the file being executed. A shape guard runs against the shipped file.
#
# Each one encodes the exact construct that produced a published wrong number.

check "20_apps_lifecycle.sh has no 'T0 + <loop var>' clock" "clean" \
      "$(grep -nE '=[[:space:]]*\$\(\([[:space:]]*T0[[:space:]]*\+' "$LIFECYCLE" \
         | grep -v '^[0-9]*:#' | head -1 | { read -r l; [[ -z "$l" ]] && echo clean || echo "$l"; })"

check "every app served-epoch comes from a real clock" "yes" \
      "$(grep -qE '(VIZ_T|TE_T|SIM_BIND_EPOCH)="\$\(date \+%s\)"' "$LIFECYCLE" && echo yes || echo no)"

# mark_start must read a REAL CLOCK, not be merely present. Seeding T_START from T0 would leave
# every name in place -- `mark_start()`, `T_START[`, the `own` column -- while making `own` and
# `since_T0` the same number again, which is the defect wearing the fix's clothes.
check "mark_start records a real clock, not T0" "yes" \
      "$(grep -qE 'mark_start\(\) \{ T_START\[\$1\]="\$\(date \+%s\)"; \}' "$LIFECYCLE" && echo yes || echo no)"

check "the convergence table header carries both since_T0 and own" "yes" \
      "$(grep -E "^[[:space:]]*printf '#app" "$LIFECYCLE" | grep -q 'since_T0' && \
         grep -E "^[[:space:]]*printf '#app" "$LIFECYCLE" | grep -q 'own' && echo yes || echo no)"

check "25_apps_energy.sh's watch loop is deadline-driven, not iteration-counted" "clean" \
      "$(grep -nE 'for i in \$\(seq [0-9]+ \$\(\([[:space:]]*WATCH_S' "$ENERGY" \
         | head -1 | { read -r l; [[ -z "$l" ]] && echo clean || echo "$l"; })"

# A CALL, not a mention. The first draft grepped for the bare name and stayed green when the call
# was replaced by an info() line, because the explanatory comment two lines above still contained
# the word. The mutation gate caught it; review did not.
check "and it asserts its own span rather than only printing it" "yes" \
      "$(grep -qE '^[[:space:]]*assert_window_span[[:space:]]+[A-Za-z_]' "$ENERGY" && echo yes || echo no)"

# FINDING-05's other half: the degraded banner used to print unconditionally, next to this same
# script's own "switches powered off by the app: 0", and pointed the operator at the restore route
# FINDING-04 shows tears a healthy fabric down. Two survivable defects composing into one that is
# not: following it on an undegraded fabric destroys a healthy fabric to fix nothing.
#
# The gate must be the line IMMEDIATELY ABOVE the banner. "some POWERED_OFF test appears earlier in
# the file" is not the same claim -- the script has another one at the INJECTION ASSERTED block,
# so a banner re-opened with `if true; then` would still satisfy the looser form.
check "the degraded banner's own gate is POWERED_OFF" "yes" \
      "$(awk '/THE FABRIC IS NOW DEGRADED/ && prev ~ /^if \(\( POWERED_OFF > 0 \)\); then$/ { hit=1 }
              { prev=$0 } END { exit !hit }' "$ENERGY" && echo yes || echo no)"

echo
echo "===== $((PASS + FAIL)) check(s): $PASS ok, $FAIL FAILED ====="
[[ "$FAIL" -eq 0 ]]
