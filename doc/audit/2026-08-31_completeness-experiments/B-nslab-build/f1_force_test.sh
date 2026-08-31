#!/usr/bin/env bash
# F1 force test — prove the binary-identity gate actually aborts.
# Two reds, because they fail for different reasons and only the second is F1 itself:
#   RED-A  same running switch, wrong "expected" path      -> the check's comparison works
#   RED-B  override rewritten so the fabric launches the OTHER binary, arm still
#          expects its own  -> F1's real failure mode, end to end
# GREEN   expected == running, and the pass must carry a full hash as evidence.
# [Co-developed with claude code -- Adam]
set -uo pipefail
ASSERT="$(dirname "$0")/arm_binary_assert.sh"
FAST=/usr/local/bmv2-fast/bin/simple_switch_grpc
STOCK=/usr/local/bin/simple_switch_grpc
OUT="${1:-/tmp/f1out}"; mkdir -p "$OUT"

# comm is capped at 15 chars, so `pgrep -x simple_switch_grpc` matches nothing while ten
# switches run (ndt:44 records the same trap). `pgrep -f` is banned here: it matches the
# shell that invoked it. Read /proc directly and compare the resolved exe, which is the
# same fact the assertion itself checks.
switch_pid () {
  local p
  for p in /proc/[0-9]*; do
    [ -r "$p/comm" ] || continue
    [ "$(cat "$p/comm" 2>/dev/null)" = "simple_switch_g" ] || continue
    echo "${p#/proc/}"; return 0
  done
  return 1
}

run () { # label expected expect_rc
  local pid; pid=$(switch_pid)
  echo "--- $1 (pid=$pid, expected=$2) ---"
  local o; o=$(bash "$ASSERT" "$2" "$pid" 2>&1); local rc=$?
  echo "$o" | sed 's/^/    /'
  if [ "$rc" -eq "$3" ]; then echo "    ✅ rc=$rc as required"; else echo "    🔴 rc=$rc but required $3"; fi
  { echo "=== $1 ==="; echo "pid=$pid expected=$2 rc=$rc (required $3)"; echo "$o"; echo; } >> "$OUT/f1_force.log"
}

: > "$OUT/f1_force.log"
echo "running switch: $(readlink -f /proc/$(switch_pid)/exe 2>/dev/null)" | tee -a "$OUT/f1_force.log"
run "GREEN  expected == running"      "$FAST"  0
run "RED-A  wrong expected path"      "$STOCK" 10
