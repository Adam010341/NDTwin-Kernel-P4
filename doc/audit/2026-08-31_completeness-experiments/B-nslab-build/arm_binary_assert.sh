#!/usr/bin/env bash
# PREREG-B — assert that the switch actually running is the arm's binary.
#
# F1: four builds installed to four prefixes is not four arms running four
# binaries. Recording the sha256 of what we compiled cannot detect that; only
# the sha256 of /proc/<pid>/exe can. This script is that check.
#
# It is written to fail loudly rather than to pass quietly, because the failure
# it guards against is itself silent. Every way of not-knowing -- no pid, an
# unreadable exe link, a missing expected file, an empty hash -- exits non-zero
# with a distinct code, so "it did not run" can never look like "it passed".
#
#   arm_binary_assert.sh <expected-binary> <pid>
#   arm_binary_assert.sh --selftest        # forces every failure mode
# [Co-developed with claude code -- Adam]
set -uo pipefail

RC_MISMATCH=10 RC_NOPID=11 RC_NOEXE=12 RC_NOEXPECT=13 RC_EMPTYHASH=14

assert_arm_binary () {
  local expected="$1" pid="$2"
  [ -n "$pid" ] || { echo "ABORT[$RC_NOPID]: no pid given"; return $RC_NOPID; }
  [ -e "/proc/$pid" ] || { echo "ABORT[$RC_NOPID]: pid $pid not present"; return $RC_NOPID; }
  [ -r "$expected" ] || { echo "ABORT[$RC_NOEXPECT]: expected binary unreadable: $expected"; return $RC_NOEXPECT; }

  local running
  running=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
  if [ -z "$running" ] || [ ! -r "$running" ]; then
    echo "ABORT[$RC_NOEXE]: cannot read /proc/$pid/exe (permission, or process gone)"
    return $RC_NOEXE
  fi

  local h_run h_exp
  h_run=$(sha256sum "$running"  2>/dev/null | cut -d' ' -f1)
  h_exp=$(sha256sum "$expected" 2>/dev/null | cut -d' ' -f1)
  # an empty hash must never compare equal to another empty hash
  if [ -z "$h_run" ] || [ -z "$h_exp" ]; then
    echo "ABORT[$RC_EMPTYHASH]: a hash came back empty (run='$h_run' exp='$h_exp')"
    return $RC_EMPTYHASH
  fi
  if [ "$h_run" != "$h_exp" ]; then
    echo "ABORT[$RC_MISMATCH]: running binary is NOT this arm's build"
    echo "  running : $running"
    echo "            $h_run"
    echo "  expected: $expected"
    echo "            $h_exp"
    return $RC_MISMATCH
  fi
  echo "OK: running binary matches this arm's build"
  echo "  path: $running"
  echo "  sha : $h_run"
  return 0
}

selftest () {
  local t; t=$(mktemp -d); local fails=0
  cp /bin/sleep "$t/binA"; cp /bin/cat "$t/binB"   # two genuinely different binaries
  "$t/binA" 600 & local pid=$!; sleep 0.3

  check () { # name expected_rc actual_rc
    if [ "$2" -eq "$3" ]; then echo "  PASS  $1 (rc=$3)"; else echo "  🔴FAIL $1 expected rc=$2 got $3"; fails=$((fails+1)); fi
  }
  echo "--- forced RED cases (each must abort with its own code) ---"
  assert_arm_binary "$t/binB" "$pid"      >/dev/null 2>&1; check "wrong binary running"      $RC_MISMATCH  $?
  assert_arm_binary "$t/binA" ""          >/dev/null 2>&1; check "empty pid"                 $RC_NOPID     $?
  assert_arm_binary "$t/binA" 999999      >/dev/null 2>&1; check "pid not present"           $RC_NOPID     $?
  assert_arm_binary "$t/missing" "$pid"   >/dev/null 2>&1; check "expected file missing"     $RC_NOEXPECT  $?
  assert_arm_binary "$t/binA" 1           >/dev/null 2>&1; check "exe unreadable (pid 1)"    $RC_NOEXE     $?
  echo "--- forced GREEN case (must pass, and for the right reason) ---"
  local out; out=$(assert_arm_binary "$t/binA" "$pid" 2>&1); local rc=$?
  check "correct binary running" 0 $rc
  if grep -q "matches this arm's build" <<<"$out" && grep -q "sha : [0-9a-f]\{64\}" <<<"$out"; then
    echo "  PASS  green carries a full 64-hex hash (not an empty compare)"
  else
    echo "  🔴FAIL green passed without evidence"; fails=$((fails+1))
  fi
  kill "$pid" 2>/dev/null; rm -rf "$t"
  echo "--- selftest: $fails failure(s) ---"
  return $fails
}

case "${1:-}" in
  --selftest) selftest ;;
  *) assert_arm_binary "${1:-}" "${2:-}" ;;
esac
