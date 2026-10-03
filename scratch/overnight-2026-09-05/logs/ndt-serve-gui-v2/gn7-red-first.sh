#!/usr/bin/env bash
# G-N7 red first at a committed head: the fork case, token assertion first, against
#   (old) serve.py as of fed37cff (url_command checked the listener only), and
#   (g48) today's serve.py with the peer check switched off;
# and (now) today's serve.py, which must be green. Prints its own provenance and each rc.
# usage: gn7-red-first.sh <worktree>     [Co-developed with claude code -- Adam]
set -uo pipefail
WT="$1"; PY=/usr/bin/python3.12; OLD=fed37cff5d70209235f6f4458ed7294b4ef542b4
T=UrlCommand.test_url_sends_the_token_only_over_a_connection_the_pid_accepted
cd "$WT" || exit 2
echo "date $(date -Is)"; echo "dir $WT"
echo "head $(git rev-parse HEAD 2>/dev/null || echo '?')"
st=$(git status --porcelain --untracked-files=no 2>/dev/null) && echo "porcelain $(grep -c . <<<"$st")" || echo "porcelain ?"
echo "python $PY $($PY -c 'import sys; print(sys.version.split()[0])')"
echo "test file $(git log -1 --format=%h -- tests/python/test_ndt_serve_gui.py) (committed), sha256 $(sha256sum tests/python/test_ndt_serve_gui.py | cut -c1-16)"
S=$(mktemp -d "${TMPDIR:-/tmp}/gn7-XXXXXX"); trap 'rm -rf "$S"' EXIT
for d in old g48; do
    mkdir -p "$S/$d/tools/ndt_serve"; cp tools/ndt_serve/*.py tools/ndt_serve/README.md "$S/$d/tools/ndt_serve/"
    cp -r tools/ndt_serve/static "$S/$d/tools/ndt_serve/"
done
git show "$OLD:tools/ndt_serve/serve.py" > "$S/old/tools/ndt_serve/serve.py"
$PY - "$S/g48/tools/ndt_serve/serve.py" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
a = "    if not peer_owned_by(pid, port, sock.getsockname()[1]):"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, "    if False:"))
PYEOF
for d in old g48 now; do
    [[ $d == now ]] && dir="$WT/tools/ndt_serve" || dir="$S/$d/tools/ndt_serve"
    echo; echo "== $d: serve.py sha256 $(sha256sum "$dir/serve.py" | cut -c1-16)$([[ $d == old ]] && echo " (git show $OLD:tools/ndt_serve/serve.py)")"
    NDT_SERVE_UNDER_TEST="$dir" $PY tests/python/test_ndt_serve_gui.py "$T" > "$S/out" 2>&1; rc=$?
    grep -E '^(FAIL|ERROR|OK|FAILED|Ran)|AssertionError' "$S/out"
    echo "rc=$rc"
done
