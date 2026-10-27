#!/usr/bin/env bash
#
# Two build guards from DIFFERENT checkouts, one inside the other, must not exec each other's
# PATH shims forever.
#
# WHY THIS FILE EXISTS
# tools/build_guard/shims/_resolve.sh finds the "real" tool by taking ITS OWN shim directory out
# of PATH and asking again. Put a second checkout's guard inside the first and PATH reads
#     <clone>/shims : <main>/shims : ...
# The clone's cmake strips the clone's dir and finds <main>/shims/cmake; <main>'s cmake strips
# <main>'s dir and finds <clone>/shims/cmake; neither is its own file, so the self-check passes
# both times, and they exec each other without end. It cost a 58-minute hung baseline build on
# 2026-10-25 (`cmake --version` hangs inside 10 s).
# The fix is that a shim never resolves to ANY build-guard shim: every PATH entry that is a shims
# directory is skipped, identified by a marker file the guard ships in it -- not by its path,
# because the other checkout's path is exactly what a shim cannot know.
#
# No build is run, no compiler is invoked. The "real" tool is a fake cmake that prints its argv
# (plus, where a real cmake is installed, `cmake --version` itself, which is the reported hang).
#
# 🔴 EVERY invocation that could loop is wrapped in `timeout`: a regression must come back as
# rc 124 and a FAILED line, not as a test that never ends. The loop is a chain of exec, so there
# is no fork bomb, only a process that spins until something kills it.
#
# 🔴 NO REAL LOCK, NO REAL SCOPE. Each nested guard is run with NO_CGROUP=1 (no systemd-run) and a
# LOCK under this run's own mktemp dir -- never /tmp/ndtwin-build.lock. The two guards use two
# DIFFERENT locks on purpose: two checkouts do not share a lock unless LOCK says so, and a shared
# one would be the re-entrant case, which test_guarded_build_reentrant.sh covers.
#
# MUTATION GATE: this file is red on the resolver before the fix (every nested case times out).
#
# Usage: tests/shell/test_build_guard_nested_checkouts.sh
#        GUARD_UNDER_TEST=<dir> tests/shell/test_build_guard_nested_checkouts.sh
# Exit:  0 all checks pass, 1 some check failed, 2 refused (no guard to test).
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

# Same list the other build_guard suites clear: the caller's guard settings must not decide the answer.
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "${GUARD_UNDER_TEST:-$HERE/../../tools/build_guard}" 2>/dev/null && pwd)" \
    || { echo "no guard dir at ${GUARD_UNDER_TEST:-$HERE/../../tools/build_guard}"; exit 2; }
[[ -d "$GUARD/shims" && -x "$GUARD/guarded_build.sh" ]] || { echo "no guard at $GUARD"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Two "checkouts": the guard's files copied into two unrelated directories, under names that
# share nothing with the real tree. A shim that knew only its own path cannot tell them apart
# from a real tool directory.
A="$TMP/checkout-a/tools/build_guard"; B="$TMP/other-clone/vendor/guard"; C="$TMP/third/bg"
for d in "$A" "$B" "$C"; do mkdir -p "$d"; cp -r "$GUARD/." "$d/"; done

# The one real tool every case should end up at.
REAL="$TMP/real"; mkdir -p "$REAL"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "REAL-cmake $*"\n' > "$REAL/cmake"; chmod +x "$REAL/cmake"

# A PATH tail that has the basics the shims call (dirname, readlink, env, bash, timeout) and
# nothing else, so "no real binary" really means none.
ONLY="$TMP/only"; mkdir -p "$ONLY"
for u in dirname readlink env bash timeout cat flock; do
    p="$(command -v "$u" 2>/dev/null)" && ln -sf "$p" "$ONLY/$u"
done

checks=0; failed=0
section() { printf '\n%s\n' "$1"; }
t_eq() {   # $1 label, $2 expected, $3 actual
    checks=$((checks+1))
    if [[ "$2" == "$3" ]]; then printf '  ok       %s\n' "$1"
    else failed=$((failed+1)); printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"; fi
}
t_true() { checks=$((checks+1)); if [[ "$2" == 1 ]]; then printf '  ok       %s\n' "$1"; else failed=$((failed+1)); printf '  FAILED   %s\n' "$1"; fi; }

# run_bounded <PATH> <cmd...> -- sets OUT, RC, SECS. 5 s is generous for a shim and short for a loop.
run_bounded() {
    local p="$1"; shift
    local t0=$SECONDS
    OUT="$(PATH="$p" timeout -k 1 5 "$@" 2>"$TMP/stderr")"; RC=$?
    ERR="$(cat "$TMP/stderr")"; SECS=$(( SECONDS - t0 ))
}

section "🔴 two shim dirs from different checkouts, both orders: the real tool is reached, in bounded time"
for order in "$A/shims:$B/shims" "$B/shims:$A/shims"; do
    tag="${order%%:*}"; tag="${tag#$TMP/}"
    run_bounded "$order:$REAL:$ONLY" cmake --version
    t_eq   "[$tag first] cmake --version exits 0 (124 would be the loop)" "0" "$RC"
    t_eq   "and it is the real tool that answered"                  "REAL-cmake --version" "$OUT"
    t_true "and it answered in ${SECS}s, under 5"                    "$([[ $SECS -lt 5 ]] && echo 1 || echo 0)"
done

section "a third checkout, and shim dirs spread out with real directories between them"
run_bounded "$A/shims:$ONLY:$B/shims:$C/shims:$REAL" cmake --build d -j14
t_eq "A, (no cmake), B, C, then the real tool: capped, once" "REAL-cmake --build d -j2" "$OUT"
run_bounded "$C/shims:$A/shims:$B/shims:$REAL:$ONLY" cmake --version
t_eq "C, A, B in a row" "REAL-cmake --version" "$OUT"

section "a shims dir is recognised by what is in it, not by what it is called"
# Copy under a name that is not 'shims' and, unlike the above, put a symlink to it first.
ODD="$TMP/odd-name-for-the-shims"; cp -r "$B/shims" "$ODD"; ln -s "$ODD" "$TMP/odd-link"
run_bounded "$A/shims:$TMP/odd-link:$REAL:$ONLY" cmake --version
t_eq "a renamed shims dir behind a symlink is skipped too" "REAL-cmake --version" "$OUT"
# A clone from before the marker existed has no marker file, only _resolve.sh, and its shim strips
# nothing but ITS OWN directory. This stand-in behaves exactly so: with the clone's dir removed it
# finds the next cmake and execs it with PATH unchanged -- which, if ours does not skip it, is our
# shim again, and so on without end.
OLDC="$TMP/old-clone-shims"; mkdir -p "$OLDC"; : > "$OLDC/_resolve.sh"
cat > "$OLDC/cmake" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd -P)"; new=""; IFS=:
for p in $PATH; do [[ "$(cd "$p" 2>/dev/null && pwd -P)" == "$d" ]] || new="${new:+$new:}$p"; done
next="$(PATH="$new" command -v cmake)" && exec "$next" "$@"
STUB
chmod +x "$OLDC/cmake"
run_bounded "$A/shims:$OLDC:$REAL:$ONLY" cmake --version
t_eq "an older clone's shims dir (no marker file, only _resolve.sh) is skipped too" "REAL-cmake --version" "$OUT"

section "a plain-looking directory whose cmake is a link INTO another checkout's shims is refused, not run"
# Stripping shims dirs from PATH does not catch a pointer into one. The target here is a stand-in
# shim that announces itself, so "the shim handed control to it" is visible, not inferred from rc.
STAND="$TMP/standin/shims"; mkdir -p "$STAND"; : > "$STAND/.ndtwin-build-guard-shims"
printf '#!/usr/bin/env bash\necho STANDIN-SHIM-RAN\n' > "$STAND/cmake"; chmod +x "$STAND/cmake"
PTR="$TMP/pointer-dir"; mkdir -p "$PTR"; ln -s "$STAND/cmake" "$PTR/cmake"
run_bounded "$A/shims:$PTR:$REAL:$ONLY" cmake --version
t_true "the shim did not exec the other checkout's shim through the link" "$([[ "$OUT" != *STANDIN-SHIM-RAN* ]] && echo 1 || echo 0)"
t_eq   "and it refused with rc 127" "127" "$RC"

section "🔴 the same through two real nested guarded_build.sh calls (the reported case)"
# Outer guard from checkout A, inner guard from the other clone. Each has its OWN lock under
# $TMP and no cgroup, so nothing real is locked and no scope is opened.
t0=$SECONDS
OUT="$(PATH="$REAL:$ONLY" NO_CGROUP=1 LOCK="$TMP/lock-a" timeout -k 1 8 \
        "$A/guarded_build.sh" env NO_CGROUP=1 LOCK="$TMP/lock-b" \
        "$B/guarded_build.sh" cmake --version 2>/dev/null)"; RC=$?
SECS=$(( SECONDS - t0 ))
t_eq   "nested guards: cmake --version rc"            "0" "$RC"
t_eq   "nested guards: the real tool answered"        "REAL-cmake --version" "$OUT"
t_true "nested guards: and in ${SECS}s, under 8"      "$([[ $SECS -lt 8 ]] && echo 1 || echo 0)"

# If a real cmake is installed, the exact command from the report must print ITS version.
# Found by walking PATH ourselves: when this file runs under a guard, `command -v cmake` is a shim.
real_cmake=""
OLD_IFS="$IFS"; IFS=:; set -f
for d in $PATH; do
    [[ -n "$d" && -x "$d/cmake" && ! -e "$d/_resolve.sh" ]] && { real_cmake="$d/cmake"; break; }
done
set +f; IFS="$OLD_IFS"
if [[ -n "$real_cmake" ]]; then
    want="$("$real_cmake" --version 2>/dev/null | head -1)"
    OUT="$(NO_CGROUP=1 LOCK="$TMP/lock-a" timeout -k 1 8 \
            "$A/guarded_build.sh" env NO_CGROUP=1 LOCK="$TMP/lock-b" \
            "$B/guarded_build.sh" cmake --version 2>/dev/null | head -1)"
    t_eq "with the system PATH: the installed cmake's own version line" "$want" "$OUT"
else
    echo "  (no cmake installed -- the report's exact command is not repeated against a real one)"
fi

section "🔴 no real binary anywhere: a loud failure, never a loop and never a silent 0"
for order in "$A/shims:$B/shims" "$B/shims:$A/shims" "$A/shims"; do
    tag="${order%%:*}"; tag="${tag#$TMP/}"
    run_bounded "$order:$ONLY" cmake --version
    t_eq   "[$tag first] rc is 127" "127" "$RC"
    t_true "and it did not time out (rc 124 would be the loop)" "$([[ $RC != 124 ]] && echo 1 || echo 0)"
    t_true "and stderr names the missing tool"                  "$([[ "$ERR" == *"no real cmake"* ]] && echo 1 || echo 0)"
    t_eq   "and nothing was printed on stdout"                  "" "$OUT"
done
for tool in ninja make; do
    run_bounded "$A/shims:$B/shims:$ONLY" "$tool" --version
    t_eq "$tool: two shim dirs, no real one -> rc 127" "127" "$RC"
    t_true "$tool: and stderr says which tool is missing" "$([[ "$ERR" == *"no real $tool"* ]] && echo 1 || echo 0)"
done

section "and with a real cmake behind them nothing about a plain run changes"
run_bounded "$A/shims:$REAL:$ONLY" cmake -S . -B build
t_eq "a configure is untouched" "REAL-cmake -S . -B build" "$OUT"
run_bounded "$A/shims:$REAL:$ONLY" cmake --build d -j14
t_eq "a build is still capped"  "REAL-cmake --build d -j2" "$OUT"

printf '\nRan %d checks, %d failed\n' "$checks" "$failed"
[[ $failed -eq 0 ]]
