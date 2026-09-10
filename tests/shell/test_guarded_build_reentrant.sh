#!/usr/bin/env bash
#
# Tests for the RE-ENTRANCY of tools/build_guard/guarded_build.sh.
#
# WHY THIS FILE EXISTS
# `guarded_build.sh` takes $LOCK with `flock`. Many gate scripts in tests/shell call the guard
# themselves, once per build. Wrap such a gate in an outer guard and the two layers fight over
# the same flock: the inner one waits out the whole `LOCK_WAIT` and exits 2, which the gate
# reads as "the mutant does not compile". Measured twice -- 3 hours on 2026-09-04
# (tests/shell/README.md §3) and 9 minutes on 2026-09-10
# (scratch/.../fix/R4-CPPGATES-1-SUMMARY.md §4.0, where every mutation came back INVALID).
# The guard now recognises a lock this process tree already holds and nests without a second
# flock and without a second cgroup scope.
#
# 🔴 TWO-SIDED, and the second side is the one that costs something. "Nest without locking" is
# trivially satisfied by a guard that never locks at all, or by one that stops locking the
# moment it sees any nesting. Cases (b), (d) and (e) exist for that: an independent caller must
# still queue, and a DIFFERENT lock must still be taken even from inside an outer guard.
#
# MUTATION GATE: yes -- tests/shell/mutate_build_guard.sh, which runs this file (and
# test_build_guard.sh) against a mutated COPY of tools/build_guard. M11/M12/M13 there are the
# re-entrancy mutations: M11 removes the check, M12 widens it to "any nesting at all", M13
# keeps the check but opens a second scope anyway. All three must be seen red.
#
# 🔴 NO DEFAULT LOCK. Every case here uses a lock under this run's own mktemp dir. Using
# /tmp/ndtwin-build.lock would (a) make these results depend on whoever is compiling right now
# and (b) block them for LOCK_WAIT while they did it. No case builds anything, no case invokes
# a compiler, and no case creates a real systemd scope: the cgroup case runs against a FAKE
# systemd-run that logs its argv and execs the payload, so there is no scope to collect.
#
# Nesting is expressed as generated one-line scripts rather than `bash -c` inside `bash -c`.
# Three levels of shell quoting is a place for the test to be wrong in a way that looks like
# the defect, and the A-B-A case needs three levels.
#
# Usage: tests/shell/test_guarded_build_reentrant.sh
#        GUARD_UNDER_TEST=<dir> tests/shell/test_guarded_build_reentrant.sh   (the gate's way)
# Exit:  0 all checks pass, 1 some check failed, 2 refused (no guard to test).
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Canonicalised, because case (h) compares against the shim dir the guard itself computed
# (`cd … && pwd`); a `../..` in the expected value would fail a correct guard.
GUARD="$(cd "${GUARD_UNDER_TEST:-$HERE/../../tools/build_guard}" 2>/dev/null && pwd)" \
    || { echo "no guard dir at ${GUARD_UNDER_TEST:-$HERE/../../tools/build_guard}"; exit 2; }
SHIM="$GUARD/shims"
GB="$GUARD/guarded_build.sh"
[[ -x "$GB" ]] || { echo "no guarded_build.sh at $GB"; exit 2; }

# 🔴 The ambient environment must not decide the answer. If this file is itself run from inside
# a guard (the gate may be), NDTWIN_GUARD_HELD arrives already set, and a case that means to be
# the outermost layer would be testing something else.
unset NDTWIN_GUARD_HELD

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LA="$TMP/lock-a"; LB="$TMP/lock-b"

# nest <name> <line>  -- an executable one-liner, so the payload of a guard can itself be a guard.
nest() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TMP/$1"; chmod +x "$TMP/$1"; }
nest inner_true  "exec \"$GB\" true"
nest inner_false "exec \"$GB\" false"
nest inner_other "exec env LOCK=\"$LB\" LOCK_WAIT=1 \"$GB\" true"
nest aba_inner   "exec env LOCK=\"$LA\" \"$GB\" true"
nest aba_mid     "exec env LOCK=\"$LB\" \"$GB\" \"$TMP/aba_inner\""
nest inner_jobs  "exec env JOBS=5 \"$GB\" bash -c 'printf %s \"\$SHIM_JOBS\"'"
nest inner_path  "exec \"$GB\" bash -c 'printf %s \"\${PATH%%:*}\"'"

# A fake systemd-run: log the call, then exec whatever followed `--`. This is how "did the
# nested layer open a SECOND scope" is observed without creating one real scope.
FAKE="$TMP/fake"; mkdir -p "$FAKE"
cat > "$FAKE/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$SCOPE_LOG"
while [[ $# -gt 0 ]]; do [[ "$1" == "--" ]] && { shift; break; }; shift; done
exec "$@"
EOF
chmod +x "$FAKE/systemd-run"

checks=0; failed=0
section() { printf '\n%s\n' "$1"; }
t_eq() {   # $1 label, $2 expected, $3 actual
    checks=$((checks+1))
    if [[ "$2" == "$3" ]]; then printf '  ok       %s\n' "$1"
    else failed=$((failed+1)); printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"; fi
}
t_true() { checks=$((checks+1)); if [[ "$2" == 1 ]]; then printf '  ok       %s\n' "$1"; else failed=$((failed+1)); printf '  FAILED   %s\n' "$1"; fi; }

section "(a) the nested call must not wait for a lock this tree already holds"
# 🔴 LOCK_WAIT=3, and the case asserts rc 0 AND under 3s. Without the elapsed assertion a
# guard that waited 2.9s and then succeeded anyway would look identical to one that never
# waited, and the waiting is the whole defect.
start=$(date +%s)
NO_CGROUP=1 LOCK="$LA" LOCK_WAIT=3 "$GB" "$TMP/inner_true" >/dev/null 2>"$TMP/a.err"
rc=$?
elapsed=$(( $(date +%s) - start ))
t_eq "nested same-lock guard exits 0"                          "0" "$rc"
t_true "and it took ${elapsed}s, not the whole LOCK_WAIT=3"    "$([[ $elapsed -lt 3 ]] && echo 1 || echo 0)"
t_true "and it never printed 'giving up'"                      "$([[ "$(grep -c 'giving up' "$TMP/a.err")" == 0 ]] && echo 1 || echo 0)"
t_true "and the log says the nesting happened, not nothing"    "$([[ "$(grep -c 'already held' "$TMP/a.err")" -ge 1 ]] && echo 1 || echo 0)"

section "(b) two INDEPENDENT outer guards on one lock are still mutually exclusive"
NO_CGROUP=1 LOCK="$LB" "$GB" bash -c 'sleep 4' >/dev/null 2>&1 &
holder=$!
sleep 1
start=$(date +%s)
NO_CGROUP=1 LOCK="$LB" LOCK_WAIT=30 "$GB" true >/dev/null 2>&1
rc=$?
waited=$(( $(date +%s) - start ))
wait $holder 2>/dev/null
t_eq "the second one still gets in, eventually"                "0" "$rc"
t_true "🔴 and it WAITED (${waited}s, needs >=2)"              "$([[ $waited -ge 2 ]] && echo 1 || echo 0)"

section "(c) the nested command's exit code is the answer"
NO_CGROUP=1 LOCK="$LA" LOCK_WAIT=3 "$GB" "$TMP/inner_false" >/dev/null 2>&1
t_eq "a nested guard around \`false\` is rc 1, not rc 0 and not rc 2" "1" "$?"

section "🔴 (d) nesting does NOT switch locking off -- a DIFFERENT lock is still contended"
NO_CGROUP=1 LOCK="$LB" "$GB" bash -c 'sleep 5' >/dev/null 2>&1 &
holder=$!
sleep 1
NO_CGROUP=1 LOCK="$LA" LOCK_WAIT=30 "$GB" "$TMP/inner_other" >/dev/null 2>&1
rc=$?
wait $holder 2>/dev/null
t_eq "an inner guard on a lock SOMEONE ELSE holds still gives up (rc 2)" "2" "$rc"

section "🔴 (e) the outer lock is still remembered after an inner one is taken (A-B-A)"
# Held locks are a LIST, not the most recent one. With a single-valued NDTWIN_GUARD_HELD this
# case is the 09-04 deadlock again: level 3 asks for lock A, which level 1 still holds, and the
# variable by then says B.
start=$(date +%s)
NO_CGROUP=1 LOCK="$LA" LOCK_WAIT=3 "$GB" "$TMP/aba_mid" >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
t_eq "A(outer) -> B -> A(inner) exits 0"                       "0" "$rc"
t_true "and did not wait out LOCK_WAIT (${elapsed}s, needs <3)" "$([[ $elapsed -lt 3 ]] && echo 1 || echo 0)"

section "(f) a lock path that would corrupt the held-lock list is refused, not accepted"
NO_CGROUP=1 LOCK="$TMP/has:colon" "$GB" true >/dev/null 2>&1
t_eq "LOCK containing ':' is rc 2"                             "2" "$?"

section "(g) the nested call re-uses the outer cgroup scope instead of opening a second one"
export SCOPE_LOG="$TMP/scopes.log"; : > "$SCOPE_LOG"
PATH="$FAKE:$PATH" LOCK="$LA" LOCK_WAIT=3 "$GB" "$TMP/inner_true" >/dev/null 2>&1
rc=$?
t_eq "the nested pair exits 0 with the cgroup guard on"        "0" "$rc"
t_eq "🔴 systemd-run was called ONCE, by the outer layer"      "1" "$(wc -l < "$SCOPE_LOG" | tr -d ' ')"
unset SCOPE_LOG

section "(h) the nested call still gets the shims and its own JOBS"
out="$(NO_CGROUP=1 LOCK="$LA" LOCK_WAIT=3 JOBS=3 "$GB" "$TMP/inner_jobs" 2>/dev/null)"
t_eq "the inner layer's own JOBS reaches the shims"            "5" "$out"
out="$(NO_CGROUP=1 LOCK="$LA" LOCK_WAIT=3 "$GB" "$TMP/inner_path" 2>/dev/null)"
t_eq "and the shim dir is still the first thing on PATH"       "$SHIM" "$out"

printf '\nRan %d checks, %d failed\n' "$checks" "$failed"
[[ $failed -eq 0 ]]
