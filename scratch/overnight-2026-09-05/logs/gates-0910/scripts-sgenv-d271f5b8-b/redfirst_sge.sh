#!/usr/bin/env bash
# redfirst_sge.sh <worktree> -- round (b), 09-27: test_build_guard.sh under the gate environment
# (inside the guard, nolab shims first on PATH -- as this script is run), red at 3db3b9a8 and green
# at HEAD. The base version runs as a copy beside the real file (tests/shell/.redfirst-sge-*),
# removed on exit. [Co-developed with claude code -- Adam]
set -u
WT="$1"; bad=0; cd "$WT" || exit 2
C="tests/shell/.redfirst-sge-base-test_build_guard.sh"; T=$(mktemp -d "${TMPDIR:-/tmp}/sge-red-XXXXXX")
trap 'rm -f "$WT/$C"; rm -rf "$T"' EXIT
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
echo "HEAD $(git rev-parse HEAD); base 3db3b9a8"
echo "the guard's variables this run inherits: $(env | /usr/bin/grep -E '^(JOBS|SHIM_JOBS|NDTWIN_GUARD_HELD|LOCK_WAIT)=' | tr '\n' ' ')"
[[ "${SHIM_JOBS:-}" == 1 && "${JOBS:-}" == 1 ]] && ok "this is the gate environment (JOBS=1, SHIM_JOBS=1 inherited)" \
    || nok "not the gate environment -- the red first would prove nothing"
git show 3db3b9a8:tests/shell/test_build_guard.sh > "$C"
bash "$C" < /dev/null > "$T/base.out" 2>&1; rb=$?
bash tests/shell/test_build_guard.sh < /dev/null > "$T/head.out" 2>&1; rh=$?
nb="$(/usr/bin/grep -c '^  FAILED' "$T/base.out")"; nh="$(/usr/bin/grep -c '^  FAILED' "$T/head.out")"
echo "    base: rc $rb, $(tail -1 "$T/base.out")"; echo "    head: rc $rh, $(tail -1 "$T/head.out")"
[[ "$rb" != 0 && "$nb" == 15 ]] && ok "3db3b9a8 under the gate environment: 15 checks red" || nok "3db3b9a8: rc $rb, $nb red"
wrong="$(/usr/bin/grep -A2 '^  FAILED' "$T/base.out" | sed -n 's/^ *actual: *//p' | /usr/bin/grep -vc -- '-j1')"
[[ "$wrong" == 0 ]] && ok "  every one of them read -j1 where the default -j2 was expected (the inherited SHIM_JOBS=1)" \
    || nok "  $wrong red check(s) are not the inherited -j1"
[[ "$rh" == 0 && "$nh" == 0 && "$(tail -1 "$T/head.out")" == "Ran 37 checks, 0 failed" ]] \
    && ok "HEAD under the same environment: Ran 37 checks, 0 failed" || nok "HEAD: rc $rh, $nh red"
[[ "$(/usr/bin/grep -c '^  \(ok\|FAILED\) ' "$T/base.out")" == "$(/usr/bin/grep -c '^  \(ok\|FAILED\) ' "$T/head.out")" ]] \
    && ok "  the same number of checks, none removed" || nok "  the check count changed"
echo "SGE-RED-FIRST: $([[ $bad == 0 ]] && echo 'red under the gate environment at 3db3b9a8, green at HEAD' || echo BROKEN)"
exit $bad
