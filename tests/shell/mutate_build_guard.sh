#!/usr/bin/env bash
#
# Mutation gate for tools/build_guard.
#
# Shape copied from tests/shell/mutate_ports_that_block_restart.sh: a mutant is a whole COPY of
# the guard directory (the shims source _resolve.sh from beside themselves, so the files travel
# together), the real tree is never written to, and the baseline is asserted byte-identical at
# the end anyway.
#
# 🔴 TWO-SIDED. A guard that capped everything would satisfy a one-sided gate -- and it would
# also make `cmake -S . -B build` and a deliberately serial `make install` behave differently
# from what their authors wrote. So mutations 8 and 9 are WIDENINGS: code that caps MORE. A
# gate with only 1..7 would pass both of them.
#
# M11..M14 are the 2026-09-11 re-entrancy (see tools/build_guard/guarded_build.sh, and
# tests/shell/test_guarded_build_reentrant.sh, which this gate runs alongside test_build_guard.sh
# because that is where re-entrancy is observed). M12 is the widening on THAT side: a guard that
# stopped locking the moment it saw any nesting would pass a one-sided "nesting must not
# deadlock" gate while letting an inner build on a DIFFERENT lock run beside someone else's.
#
# 🔴 A mutation that will not apply, a non-unique anchor, a compile/syntax error, or the WRONG
# check going red all count as SURVIVOR -- never as skipped. On a shared tree the tempting
# reading of "it did not run" is "it passed".
#
# Usage: tests/shell/mutate_build_guard.sh
# Exit:  0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only).
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GUARD="$REPO/tools/build_guard"
TEST="$REPO/tests/shell/test_build_guard.sh"
REENT="$REPO/tests/shell/test_guarded_build_reentrant.sh"
[[ -d "$GUARD" && -x "$TEST" && -x "$REENT" ]] || { echo "refused: guard or test missing"; exit 2; }

BK="$(mktemp -d)"; trap 'rm -rf "$BK"' EXIT
BASE_SUM="$(cd "$GUARD" && find . -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"

# mutant <name> <relative file>   -- anchors come from A/<name>.old and A/<name>.new
#
# 🔴 old/new travel as FILES, never as shell words. The first version of this gate built them
# with printf and lost: `[[` had been backslash-escaped for a grep that was -F (fixed string,
# so the backslashes were literal), and one anchor ended in a newline, which grep -F reads as
# TWO patterns -- the second empty, matching every line. Six mutations came back "anchor
# occurrences: 0" and the gate counted all six as SURVIVOR. That accounting was right; the
# harness was wrong. Files have no quoting.
A="$BK/anchors"; mkdir -p "$A"
mutant() {
    local name="$1" rel="$2"
    local d="$BK/$name"; rm -rf "$d"; cp -r "$GUARD" "$d"
    python3 - "$d/$rel" "$A/$name.old" "$A/$name.new" <<'PY'
import sys, io
target, oldf, newf = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(target, encoding='utf-8').read()
o = io.open(oldf, encoding='utf-8').read()
n = io.open(newf, encoding='utf-8').read()
c = s.count(o)
if c != 1:
    print("ANCHOR:%d" % c)
    sys.exit(0)
io.open(target, 'w', encoding='utf-8').write(s.replace(o, n, 1))
print(target.rsplit('/', 2)[0])
PY
}

# Both suites, against ONE guard copy. Either one red is red, and a timeout in either one is a
# timeout -- the caller distinguishes 124 from 1, because "unbounded" is not "failed".
run_against() {
    local g="$1" o1 o2 r1 r2
    o1="$(GUARD_UNDER_TEST="$g" timeout 300 bash "$TEST" 2>&1)";  r1=$?
    o2="$(GUARD_UNDER_TEST="$g" timeout 300 bash "$REENT" 2>&1)"; r2=$?
    printf '%s\n%s\n' "$o1" "$o2"
    [[ $r1 -eq 124 || $r2 -eq 124 ]] && return 124
    [[ $r1 -eq 0 && $r2 -eq 0 ]] && return 0
    return 1
}

echo "baseline (both suites must be green before any mutation):"
base_out="$(run_against "$GUARD")"; base_rc=$?
echo "$base_out" | grep -E '^Ran [0-9]+ checks' | sed 's/^/  /'
if [[ $base_rc -ne 0 ]]; then echo "refused: baseline is not green"; exit 2; fi
echo

caught=0; survived=0
check() {   # $1 label, $2 name, $3 relative file, $4 the check text that MUST go red
    local label="$1" name="$2" rel="$3" want="$4"
    local d; d="$(mutant "$name" "$rel")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-58s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        survived=$((survived+1)); return
    fi
    local out; out="$(run_against "$BK/$name")"; local rc=$?
    if [[ $rc -eq 124 ]]; then
        printf '  SURVIVED %-58s (the suite TIMED OUT -- unbounded, not red)\n' "$label"
        survived=$((survived+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-58s (suite still green)\n' "$label"
        survived=$((survived+1)); return
    fi
    if echo "$out" | grep -qF "FAILED   $want"; then
        printf '  caught   %-58s (%s went red)\n' "$label" "$want"
        caught=$((caught+1))
    else
        printf '  SURVIVED %-58s (suite went red, but NOT on the named check)\n' "$label"
        echo "$out" | grep 'FAILED' | head -3 | sed 's/^/             /'
        survived=$((survived+1))
    fi
}

# ---- fires: the cap must actually happen -------------------------------------------------
cat > "$A/m1.old" <<'EOF'
        -j*|--parallel=*) ;;                       # value is glued on
EOF
cat > "$A/m1.new" <<'EOF'
        -j*|--parallel=*) args+=("$a") ;;          # value is glued on
EOF
check "M1: cmake ignores a glued -j14" m1 shims/cmake "-j14 glued becomes -j2"

cat > "$A/m2.old" <<'EOF'
        -j|--parallel)   skip=1 ;;                 # value is the NEXT argv
EOF
cat > "$A/m2.new" <<'EOF'
        -j|--parallel)   args+=("$a") ;;           # value is the NEXT argv
EOF
check "M2: cmake stops eating the separate -j value" m2 shims/cmake "-j 14 as a separate argv"

cat > "$A/m3.old" <<'EOF'
if [[ $is_build == 1 ]]; then
EOF
cat > "$A/m3.new" <<'EOF'
if false; then
EOF
check "M3: cmake --build gets no -j when the caller passed none" m3 shims/cmake "no -j at all still gets one"

cat > "$A/m4.old" <<'EOF'
exec "$real" -j"$(guard_jobs)" "${args[@]}"
EOF
cat > "$A/m4.new" <<'EOF'
exec "$real" "${args[@]}"
EOF
check "M4: bare ninja is left at its own default (nproc+2)" m4 shims/ninja "bare ninja gets a cap"

cat > "$A/m5.old" <<'EOF'
if [[ $asked_parallel == 1 ]]; then
EOF
cat > "$A/m5.new" <<'EOF'
if false; then
EOF
check "M5: make stops capping an explicit -j" m5 shims/make "-j14 becomes -j2"

cat > "$A/m6.old" <<'EOF'
    [[ "$j" =~ ^[1-9][0-9]*$ ]] || j=2
EOF
cat > "$A/m6.new" <<'EOF'
    :
EOF
check "M6: SHIM_JOBS trusted as given (0 becomes 'unlimited')" m6 shims/_resolve.sh "🔴 SHIM_JOBS=0 falls back to 2"

cat > "$A/m7.old" <<'EOF'
        canon="$(cd "$part" 2>/dev/null && pwd -P)" || canon="$part"
EOF
cat > "$A/m7.new" <<'EOF'
        canon="$(cd "$part" 2>/dev/null && pwd)" || canon="$part"
EOF
check "M7: the resolver goes back to a LOGICAL pwd" m7 shims/_resolve.sh "shim dir reached by a symlink too"

# M8 is COMPOSITE and its expected observation is a HANG, not a red check.
#
# The self-resolution refusal is unreachable while the stripper is correct -- by construction,
# `found` is never inside the shim dir. Mutating it alone therefore changes nothing, and a gate
# that demanded a red for it would be demanding a lie. What the refusal actually buys is a
# BOUND on the stripper's own failure: M7 shows the stripper can regress (a logical pwd), and
# with the refusal in place that regression is a red check in ten seconds. Take the refusal
# away as well and the same regression becomes one process exec'ing itself forever -- which
# every caller reads as "still building".
#
# M8. The first two versions of this gate got M8 wrong twice, and both errors are worth the
# lines. First it demanded a red for removing the refusal alone -- but the refusal was then
# unreachable by construction (stripping the shim DIRECTORY meant `found` could never be inside
# it), so the demand was for a lie. Then it demanded a HANG from a composite mutation -- but
# every self-resolution case in the suite bounds itself with `timeout 10`, so the runaway came
# back as an ordinary red and the composite proved nothing M7 had not already proved.
#
# The fix was not to the gate. It was to make the refusal REACHABLE: resolve the symlink of the
# candidate before comparing, so that a $SOMEWHERE/cmake pointing at $SHIM/cmake is caught.
# That case is now a test, and M8 is an ordinary catchable mutation against it.
cat > "$A/m8.old" <<'EOF'
    [[ "$found_dir" == "$canon_shim" ]] && return 0
EOF
cat > "$A/m8.new" <<'EOF'
    :
EOF
check "M8: a tool that points back at the shim is accepted" m8 shims/_resolve.sh "a real tool that points back at the shim is refused"

# ---- spares: a guard that capped EVERYTHING would pass the eight above --------------------
cat > "$A/m9.old" <<'EOF'
exec "$real" "${args[@]}"
EOF
cat > "$A/m9.new" <<'EOF'
exec "$real" "${args[@]}" -j"$(guard_jobs)"
EOF
check "M9 (widening): cmake caps a configure too" m9 shims/cmake "cmake -S . -B build is untouched"

cat > "$A/m10.old" <<'EOF'
if [[ $asked_parallel == 1 ]]; then
EOF
cat > "$A/m10.new" <<'EOF'
if true; then
EOF
check "M10 (widening): make forces -j onto a deliberately serial build" m10 shims/make "🔴 a serial make is left serial"

# ---- re-entrancy (2026-09-11) ------------------------------------------------------------
cat > "$A/m11.old" <<'EOF'
[[ ":$HELD:" == *":$LOCK:"* ]] && reentrant=1
EOF
cat > "$A/m11.new" <<'EOF'
:
EOF
check "M11: the guard forgets it already holds the lock" m11 guarded_build.sh "nested same-lock guard exits 0"

# 🔴 M12 is the WIDENING, and it is the one that would have been missed. Removing the
# re-entrancy check (M11) makes the nested case deadlock again and every nesting test goes red.
# Widening it to "any nesting at all" makes every one of those tests PASS -- while an inner
# build on a lock somebody else holds runs straight past guard 2, which is the parallel build
# the lock exists to prevent. Only case (d) of the re-entrancy suite says a word.
cat > "$A/m12.old" <<'EOF'
[[ ":$HELD:" == *":$LOCK:"* ]] && reentrant=1
EOF
cat > "$A/m12.new" <<'EOF'
[[ -n "$HELD" ]] && reentrant=1
EOF
check "M12 (widening): ANY nesting counts as holding the lock" m12 guarded_build.sh "an inner guard on a lock SOMEONE ELSE holds still gives up (rc 2)"

# M13 keeps the re-entrancy decision and only takes away half of what it buys: a second cgroup
# scope per nesting level. The log line is left in place on purpose, so the case that reads the
# log stays green and the only red is the one that counts scopes.
cat > "$A/m13.old" <<'EOF'
    "${cmd[@]}"
    rc=$?
    echo "guarded_build: exit $rc" >&2
EOF
cat > "$A/m13.new" <<'EOF'
    run_it
    rc=$?
    echo "guarded_build: exit $rc" >&2
EOF
check "M13: the nested layer opens a second scope anyway" m13 guarded_build.sh "🔴 systemd-run was called ONCE, by the outer layer"

cat > "$A/m14.old" <<'EOF'
[[ "$LOCK" != *:* ]] || { echo "guarded_build: LOCK must not contain ':', got '$LOCK'" >&2; exit 2; }
EOF
cat > "$A/m14.new" <<'EOF'
:
EOF
check "M14: a ':' in the lock path splits the held list silently" m14 guarded_build.sh "LOCK containing ':' is rc 2"

echo
NOW_SUM="$(cd "$GUARD" && find . -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 baseline CHANGED -- tools/build_guard was written during the gate"; exit 3
fi
echo "baseline byte-identical: yes (whole tools/build_guard tree)"
echo "mutation gate: $((caught+survived)) mutations, $survived survived"
[[ $survived -eq 0 ]]
