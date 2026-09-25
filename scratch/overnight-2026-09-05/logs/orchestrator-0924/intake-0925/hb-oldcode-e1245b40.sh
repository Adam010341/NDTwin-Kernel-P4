#!/usr/bin/env bash
# oldcode.sh -- the spike's --self-test (this head's) against a COPY of the spike with the two round-4
# set -e fixes put back to their old form. Passes (rc 0) only if exactly the two checks written for
# them go red, and nothing else does.
# [Co-developed with claude code -- Adam]
set -uo pipefail
D=doc/audit/2026-09-25_p4-heartbeat/spike
M="$D/.S_heartbeat_spike.oldcode-$$.sh"
trap 'rm -f "$M"' EXIT
python3 - "$D/S_heartbeat_spike.sh" "$M" <<'PY'
import sys
s = open(sys.argv[1]).read()
reps = [('    [[ "$v" == OK* ]] || return 0\n', '    [[ "$v" == OK* ]] || return\n', 1),
        ('watch_hit "$dir" "$stopf" || true; return 0; fi', 'watch_hit "$dir" "$stopf"; return 0; fi', 2)]
for a, b, n in reps:
    assert s.count(a) == n, (a, s.count(a))
    s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
echo "### the copy differs from this head's spike exactly by:"
diff "$D/S_heartbeat_spike.sh" "$M"
echo "### its --self-test (SELFTEST_PROBE_SUDO unset):"
out="$(env -u SELFTEST_PROBE_SUDO bash "$M" --self-test 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -E '🔴|SELF-TEST (PASS|FAIL)'
reds="$(printf '%s\n' "$out" | grep -c '🔴')"
want1="$(printf '%s\n' "$out" | grep -c '🔴      a clean window under set -e: rc 1')"
want2="$(printf '%s\n' "$out" | grep -c '🔴    a detection part that fails its first check ended the run under set -e: rc 1')"
echo "self-test rc=$rc, red lines $reds (clean window: $want1, detect: $want2)"
[[ "$rc" != 0 && "$reds" == 2 && "$want1" == 1 && "$want2" == 1 ]] && { echo "OLD CODE IS RED IN EXACTLY THE TWO CHECKS"; exit 0; }
echo "UNEXPECTED"; exit 1
