#!/usr/bin/env bash
#
# Rebuild-and-compare gate for the ndt serve page (tools/ndt_serve/web -> tools/ndt_serve/static).
#
# [Co-developed with claude code -- Adam]
#
# CI has no Node, so tests/python/test_ndt_serve_web.py can only check that static/BUILD.json names
# the committed sources and built files with their sha256. It cannot tell a bundle that the sources
# BUILD into from one edited by hand with the manifest recomputed. This gate can: it copies web/
# (without node_modules/ and dist/) to a scratch directory, runs `npm ci --ignore-scripts` and
# `npm run build` there into a scratch static directory, and compares every file byte by byte with
# the committed static/ -- BUILD.json included, so the toolchain and every source hash must agree too.
#
# Each npm step takes the build guard's lock on its own (tools/build_guard/guarded_build.sh,
# JOBS=1); a laptop that oomd has taken down twice does not get a second build beside this one.
# Node comes from NODE_BIN (default ~/.local/node/bin) and must be the version BUILD.json names.
#
#   tests/shell/rebuild_ndt_serve_web.sh
#   NDT_SERVE_STATIC_UNDER_TEST=/tmp/x/static tests/shell/rebuild_ndt_serve_web.sh   # another bundle
#
# The first lines say which commit and tree the run is about; the last line is the exit code.
#
# Exit: 0 the committed bundle is what the sources build into, 1 it is not (or they do not build),
#       2 refused: wrong node/npm, less than 2 GB free, npm ci failed, harness error.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WEB="$REPO/tools/ndt_serve/web"
STATIC="${NDT_SERVE_STATIC_UNDER_TEST:-$REPO/tools/ndt_serve/static}"
GUARD="$REPO/tools/build_guard/guarded_build.sh"
NODE_BIN="${NODE_BIN:-$HOME/.local/node/bin}"
MIN_FREE_KB=$((2 * 1024 * 1024))
export PATH="$NODE_BIN:$PATH"
T=""
trap 'rc=$?; [[ -n "$T" ]] && rm -rf "$T"; echo "rc=$rc"' EXIT
# "?" when git cannot say (not a work tree, say): never a 0 that reads as a clean tree
git_head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null) || git_head="?"
if git_status=$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null); then
    git_dirty=$(grep -c . <<<"$git_status")
else
    git_dirty="?"
fi
echo "head $git_head"
echo "porcelain $git_dirty tracked file(s) differ from HEAD"
echo "date $(date -Is)"
echo "static $STATIC"

refuse() { echo "REFUSED: $*"; exit 2; }

guarded() {   # $1 = dir to run in, $2... = command; one guard lock per call
    local d="$1"; shift
    (cd "$d" && JOBS=1 LOCK_WAIT="${LOCK_WAIT:-10800}" "$GUARD" env PATH="$PATH" "$@")
}

free_enough() {
    local kb
    kb=$(df -Pk "${TMPDIR:-/tmp}" / | awk 'NR > 1 {print $4}' | sort -n | head -1)
    (( kb >= MIN_FREE_KB )) || refuse "$((kb / 1024)) MB free, the gate wants 2048 MB"
}

[[ -f "$STATIC/BUILD.json" ]] || refuse "no $STATIC/BUILD.json"
command -v node >/dev/null && command -v npm >/dev/null || refuse "no node/npm in $NODE_BIN or on PATH"
read -r want_node want_npm < <(python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))["toolchain"]
print(t["node"], t["npm"])' "$STATIC/BUILD.json") || refuse "BUILD.json has no toolchain"
have_node=$(node --version); have_npm=$(npm --version)
[[ "$have_node" == "$want_node" ]] || refuse "node $have_node here, the bundle was built with $want_node"
[[ "$have_npm" == "$want_npm" ]] || refuse "npm $have_npm here, the bundle was built with $want_npm"
free_enough

T=$(mktemp -d "${TMPDIR:-/tmp}/ndt-serve-rebuild-XXXXXX")
tar -C "$REPO/tools/ndt_serve" --exclude=web/node_modules --exclude=web/dist -cf - web | tar -C "$T" -xf - \
    || refuse "could not copy web/"
mkdir "$T/static"
echo "rebuilding $WEB in $T (node $have_node, npm $have_npm)"

guarded "$T/web" npm ci --ignore-scripts --no-audit --no-fund > "$T/ci.log" 2>&1 \
    || { tail -20 "$T/ci.log"; refuse "npm ci failed"; }
free_enough
if ! guarded "$T/web" env NDT_SERVE_STATIC_OUT="$T/static" npm run build > "$T/build.log" 2>&1; then
    tail -30 "$T/build.log"
    echo "FAIL: the sources do not build"
    exit 1
fi

bad=0
built=$(cd "$T/static" && ls -A | LC_ALL=C sort)
committed=$(cd "$STATIC" && ls -A | LC_ALL=C sort)
if [[ "$built" != "$committed" ]]; then
    echo "FAIL: the build writes other files than are committed"
    diff <(echo "$committed") <(echo "$built") | sed 's/^/  /'
    bad=1
fi
for f in $built; do
    [[ -f "$STATIC/$f" ]] || continue
    if cmp -s "$T/static/$f" "$STATIC/$f"; then
        printf '  same     %-12s %s\n' "$f" "$(sha256sum < "$STATIC/$f" | cut -c1-16)"
    else
        printf '  DIFFERS  %-12s committed %s, rebuilt %s\n' "$f" \
            "$(sha256sum < "$STATIC/$f" | cut -c1-16)" "$(sha256sum < "$T/static/$f" | cut -c1-16)"
        bad=1
    fi
done
if (( bad )); then
    echo "FAIL: the committed bundle is not what these sources build into"
    exit 1
fi
echo "OK: the committed bundle is byte for byte what these sources build into"
