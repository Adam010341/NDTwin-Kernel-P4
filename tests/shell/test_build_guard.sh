#!/usr/bin/env bash
#
# Tests for tools/build_guard -- the PATH shims and guarded_build.sh that keep a build from
# taking the machine (and the user's own application) down with it.
#
# No build is run and no compiler is invoked. Every case puts a FAKE cmake/ninja/make on PATH
# that prints its own argv, then reads what the shim forwarded to it. That is the whole
# behaviour under test: "what -j does the real tool actually receive".
#
# 🔴 The case that matters most is DoesNotResolveToItself. If guard_real_tool ever fails to
# take the shim's own directory out of PATH, `command -v cmake` returns the shim, the shim
# execs the shim, and the result is a fork bomb -- on the machine this guard exists to protect.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GUARD_UNDER_TEST:-$HERE/../../tools/build_guard}"
SHIM="$GUARD/shims"
[[ -d "$SHIM" ]] || { echo "no shim dir at $SHIM"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/fake"; mkdir -p "$FAKE"
for t in cmake ninja make; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "FAKE-%s $*"\n' "$t" > "$FAKE/$t"
    chmod +x "$FAKE/$t"
done

checks=0; failed=0
section() { printf '\n%s\n' "$1"; }
t_eq() {   # $1 label, $2 expected, $3 actual
    checks=$((checks+1))
    if [[ "$2" == "$3" ]]; then printf '  ok       %s\n' "$1"
    else failed=$((failed+1)); printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"; fi
}
t_true() { checks=$((checks+1)); if [[ "$2" == 1 ]]; then printf '  ok       %s\n' "$1"; else failed=$((failed+1)); printf '  FAILED   %s\n' "$1"; fi; }

# Run a shim with the fakes ahead of the real tools, and print what the fake received.
#
# 🔴 The system PATH stays on the end ON PURPOSE. The first version of this file used
# PATH="$SHIM:$FAKE" and every case came back empty -- not because a shim was wrong, but
# because the shims call `dirname` and the cases call `timeout`, and neither is a builtin.
# A minimal PATH breaks the instrument, and an instrument that fails looks exactly like the
# defect it is looking for.
shimmed() { PATH="$SHIM:$FAKE:$PATH" "$@" 2>/dev/null; }

section "the cmake shim caps --build, whatever spelling the caller used"
t_eq "-j14 glued becomes -j2"            "FAKE-cmake --build d -j2" "$(shimmed cmake --build d -j14)"
t_eq "-j 14 as a separate argv"          "FAKE-cmake --build d -j2" "$(shimmed cmake --build d -j 14)"
t_eq "--parallel 14"                     "FAKE-cmake --build d -j2" "$(shimmed cmake --build d --parallel 14)"
t_eq "--parallel=14"                     "FAKE-cmake --build d -j2" "$(shimmed cmake --build d --parallel=14)"
t_eq "no -j at all still gets one"       "FAKE-cmake --build d -j2" "$(shimmed cmake --build d)"
t_eq "the target survives the rewrite"   "FAKE-cmake --build d --target t_x -j2" "$(shimmed cmake --build d --target t_x -j14)"

section "🔴 and it must NOT fire on a configure -- capping that would break nothing but is a lie"
t_eq "cmake -S . -B build is untouched"  "FAKE-cmake -S . -B build" "$(shimmed cmake -S . -B build)"
t_eq "cmake --version is untouched"      "FAKE-cmake --version"     "$(shimmed cmake --version)"
t_eq "no -j is added to a configure"     "1" "$([[ "$(shimmed cmake -S . -B b)" != *-j* ]] && echo 1 || echo 0)"

section "the ninja shim -- an UNDECORATED ninja is the dangerous one (its default is nproc+2)"
t_eq "bare ninja gets a cap"             "FAKE-ninja -j2 -C build" "$(shimmed ninja -C build)"
t_eq "-j14 becomes -j2"                  "FAKE-ninja -j2 tgt"      "$(shimmed ninja -j14 tgt)"
t_eq "-j 14 separate argv"               "FAKE-ninja -j2 tgt"      "$(shimmed ninja -j 14 tgt)"

section "the make shim -- make is serial by default, so it caps only what asked for parallelism"
t_eq "-j14 becomes -j2"                  "FAKE-make -j2 all"       "$(shimmed make -j14 all)"
t_eq "-j 14 separate argv"               "FAKE-make -j2 all"       "$(shimmed make -j 14 all)"
t_eq "--jobs=14"                         "FAKE-make -j2 all"       "$(shimmed make --jobs=14 all)"
t_eq "🔴 a serial make is left serial"   "FAKE-make install"       "$(shimmed make install)"

section "SHIM_JOBS: the values that must NOT become 'unlimited'"
t_eq "SHIM_JOBS=3 is honoured"           "FAKE-ninja -j3 x" "$(SHIM_JOBS=3 shimmed ninja x)"
t_eq "🔴 SHIM_JOBS=0 falls back to 2"    "FAKE-ninja -j2 x" "$(SHIM_JOBS=0 shimmed ninja x)"
t_eq "SHIM_JOBS=oops falls back to 2"    "FAKE-ninja -j2 x" "$(SHIM_JOBS=oops shimmed ninja x)"
t_eq "SHIM_JOBS=-4 falls back to 2"      "FAKE-ninja -j2 x" "$(SHIM_JOBS=-4 shimmed ninja x)"
t_eq "SHIM_JOBS empty falls back to 2"   "FAKE-ninja -j2 x" "$(SHIM_JOBS= shimmed ninja x)"

section "🔴 DoesNotResolveToItself -- the failure mode is a fork bomb, not a wrong answer"
t_eq "shim dir listed twice"             "FAKE-cmake --build d -j2" \
     "$(PATH="$SHIM:$SHIM:$FAKE:$PATH" timeout 10 cmake --build d 2>/dev/null)"
REL="$TMP/rel"; ln -s "$SHIM" "$REL"
t_eq "shim dir reached by a symlink too"  "FAKE-cmake --build d -j2" \
     "$(PATH="$SHIM:$REL:$FAKE:$PATH" timeout 10 cmake --build d 2>/dev/null)"
ONLYSHIM="$TMP/onlyshim"; mkdir -p "$ONLYSHIM"
for u in dirname timeout env bash; do ln -sf "$(command -v $u)" "$ONLYSHIM/$u" 2>/dev/null || true; done
out="$(PATH="$SHIM:$ONLYSHIM" timeout 10 cmake --build d 2>&1)"; rc=$?
t_eq "no real tool anywhere -> rc 127, not a loop" "127" "$rc"
t_true "and it says which tool it could not find" "$([[ "$out" == *"no real cmake"* ]] && echo 1 || echo 0)"

# 🔴 A tool that is a SYMLINK back into the shim dir. Stripping the shim directory out of
# PATH does not catch this -- the link lives somewhere else. Without the target check the
# shim execs itself here, forever, and only the caller's own timeout ends it.
POINTER="$TMP/pointer"; mkdir -p "$POINTER"; ln -sf "$SHIM/cmake" "$POINTER/cmake"
out="$(PATH="$SHIM:$POINTER:$PATH" timeout 10 cmake --build d 2>&1)"; rc=$?
t_eq "a real tool that points back at the shim is refused" "127" "$rc"
t_true "and it did not spin until the timeout"  "$([[ $rc != 124 ]] && echo 1 || echo 0)"

# The shim dir alone on PATH: whatever resolution does, the answer must not be the shim.
out="$(PATH="$SHIM:$ONLYSHIM" timeout 10 ninja 2>&1)"; rc=$?
t_eq "a shim that can only find itself refuses, in bounded time" "127" "$rc"
t_true "and does not spin (timeout would have been 124)" "$([[ $rc != 124 ]] && echo 1 || echo 0)"

section "guarded_build.sh"
GB="$GUARD/guarded_build.sh"
out="$(PATH="$FAKE:$PATH" NO_CGROUP=1 LOCK="$TMP/l1" "$GB" cmake --build d 2>/dev/null)"
t_eq "it puts the shims on PATH for the wrapped command" "FAKE-cmake --build d -j2" "$out"
out="$(PATH="$FAKE:$PATH" NO_CGROUP=1 LOCK="$TMP/l1" JOBS=3 "$GB" cmake --build d 2>/dev/null)"
t_eq "JOBS reaches the shims"                            "FAKE-cmake --build d -j3" "$out"
NO_CGROUP=1 LOCK="$TMP/l1" "$GB" bash -c 'exit 42' >/dev/null 2>&1
t_eq "🔴 the wrapped command's exit code comes back"     "42" "$?"
NO_CGROUP=1 LOCK="$TMP/l1" JOBS=zero "$GB" true >/dev/null 2>&1
t_eq "a bad JOBS is refused, not defaulted"              "2" "$?"
"$GB" >/dev/null 2>&1
t_eq "no command at all is refused"                      "2" "$?"

# flock: hold the lock in one process, prove a second one waits rather than running alongside.
NO_CGROUP=1 LOCK="$TMP/l2" "$GB" bash -c 'sleep 4' >/dev/null 2>&1 &
holder=$!
sleep 1
start=$(date +%s)
NO_CGROUP=1 LOCK="$TMP/l2" LOCK_WAIT=30 "$GB" true >/dev/null 2>&1
waited=$(( $(date +%s) - start ))
wait $holder 2>/dev/null
t_true "🔴 a second build waits for the first (waited ${waited}s, needs >=2)" "$([[ $waited -ge 2 ]] && echo 1 || echo 0)"
start=$(date +%s)
NO_CGROUP=1 LOCK="$TMP/l2" "$GB" true >/dev/null 2>&1
t_true "and it does not wait once the lock is free"      "$([[ $(( $(date +%s) - start )) -lt 2 ]] && echo 1 || echo 0)"
NO_CGROUP=1 LOCK="$TMP/l3" "$GB" bash -c 'sleep 5' >/dev/null 2>&1 &
holder=$!
sleep 1
NO_CGROUP=1 LOCK="$TMP/l3" LOCK_WAIT=1 "$GB" true >/dev/null 2>&1
t_eq "LOCK_WAIT exceeded is rc 2, not a silent parallel build" "2" "$?"
wait $holder 2>/dev/null

printf '\nRan %d checks, %d failed\n' "$checks" "$failed"
[[ $failed -eq 0 ]]
