#!/usr/bin/env bash
# Is FixtureProvenance red WITHOUT this ticket? tools/ at trunk 6291db35, real HOME. EXPECTED RED
# (exit 0 when it is red on exactly advanced_tunnel.json). [Co-developed with claude code -- Adam]
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
B="$SP/at-base"; rm -rf "$B"; mkdir -p "$B"
git -C "$WT" archive 6291db35 tools p4_proxy setting | tar -x -C "$B"
echo "~/tutorials/exercises/p4runtime/build/advanced_tunnel.json mtime: $(stat -c %y "$HOME/tutorials/exercises/p4runtime/build/advanced_tunnel.json" 2>&1)"
out=$(env -C "$B/tools/p4_exercise/tests" PYTHONDONTWRITEBYTECODE=1 \
      "$WT/p4_proxy/venv/bin/python" -m unittest -v test_convert.FixtureProvenance 2>&1); r=$?
echo "$out"; echo "unittest rc=$r"
rm -rf "$B"
if (( r != 0 )) && /usr/bin/grep -q "\['p4runtime/build/advanced_tunnel.json'\] != \[\]" <<<"$out"; then
    echo "PROVENANCE-AT-BASE: red at the base on exactly advanced_tunnel.json (pre-existing)"; exit 0
fi
echo "PROVENANCE-AT-BASE: NOT the expected pre-existing red"; exit 1
