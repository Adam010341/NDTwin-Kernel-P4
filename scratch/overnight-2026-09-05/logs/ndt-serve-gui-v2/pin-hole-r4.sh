#!/usr/bin/env bash
# The round-3 pin's hole, shown: the same five bypass mutants of status_measuring_rows that the r4
# gate adds (L14, L14b, L15, L16, L16b), run against the r3 test (51f61eea) and against the r4 test
# of this worktree. The r3 test should stay green on each; the r4 one should go red.
# usage: pin-hole-r4.sh <worktree> <scratch dir>     [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; S="$2"; cd "$WT" || exit 2
echo "date $(date -Is)"; echo "head $(git rev-parse HEAD)"; echo "porcelain $(git status --porcelain --untracked-files=no | grep -c .)"
git show 51f61eea:tests/shell/test_ndt_status_measuring.sh > "$S/old_test.sh"
echo "r3 test: git show 51f61eea:tests/shell/test_ndt_status_measuring.sh (sha256 $(sha256sum < "$S/old_test.sh" | cut -c1-16))"
echo "r4 test: tests/shell/test_ndt_status_measuring.sh (sha256 $(sha256sum < tests/shell/test_ndt_status_measuring.sh | cut -c1-16))"
A='status_measuring_rows() {
    # Declared beside observed'
declare -A INS=(
  [L14]='    port_open 8000 >/dev/null'
  [L14b]='    (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null'
  [L15]='    python3 -c '"'"'import urllib.request
try: urllib.request.urlopen("http://127.0.0.1:8000/ndt/get_graph_data", timeout=2)
except Exception: pass'"'"' >/dev/null 2>&1'
  [L16]='    /usr/bin/ovs-vsctl list-br >/dev/null 2>&1'
  [L16b]='    /usr/bin/curl -s --max-time 1 http://127.0.0.1:8000/ndt/get_graph_data >/dev/null 2>&1')
for m in L14 L14b L15 L16 L16b; do
    d="$S/$m"; mkdir -p "$d"
    cp tools/test_workflow/ndt tools/test_workflow/ports.sh tools/test_workflow/sudo_surface.sh tools/test_workflow/components.env "$d/"
    python3 - "$d/ndt" "$A" "${INS[$m]}" <<'PY'
import sys
p, a, ins = sys.argv[1:4]
s = open(p).read(); assert s.count(a) == 1
first, rest = a.split("\n", 1)
open(p, "w").write(s.replace(a, first + "\n" + ins + "\n" + rest))
PY
    o=$(NDT_UNDER_TEST="$d/ndt" bash "$S/old_test.sh" 2>&1); orc=$?
    n=$(NDT_UNDER_TEST="$d/ndt" bash tests/shell/test_ndt_status_measuring.sh 2>&1); nrc=$?
    echo "$m: r3 test rc=$orc ($(tail -1 <<<"$o")); r4 test rc=$nrc ($(tail -1 <<<"$n")): $(grep -E '^  FAILED   🔴' <<<"$n" | sed 's/^  FAILED   //' | tr '\n' ';')"
done
