#!/usr/bin/env bash
# Segment W: an existing mutation gate run on the BASE 580767a8 (git archive of p4_proxy, tools,
# tests, setting; the untracked venv and p4_src/build linked in) -- to tell a red that is the
# gate's own (its baseline copies proxy_agent without the topology model, so it needs
# NDTWIN_P4_TOPO_FILE -- the _withmodel runs) from one this branch caused. Prints the gate's
# output; exits with the gate's rc. [Co-developed with claude code -- Adam]
set -u
WT="$1"; GATE="$2"; BASE=580767a8
T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-gatebase-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "base $(git -C "$WT" rev-parse $BASE); $GATE diff base..HEAD: [$(git -C "$WT" diff --stat $BASE HEAD -- "$GATE")]"
git -C "$WT" archive $BASE p4_proxy tools tests setting | tar -x -C "$T"
ln -s "$WT/p4_proxy/venv" "$T/p4_proxy/venv"
rm -rf "$T/p4_proxy/p4_src/build"; ln -s "$WT/p4_proxy/p4_src/build" "$T/p4_proxy/p4_src/build"
cd "$T" && bash "$GATE"
