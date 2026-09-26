#!/usr/bin/env bash
# Mark every embedded program of 08, 07, _common.sh and the spike scripts IN PLACE, run the
# self-tests that could execute them with COV_DIR set, report, and put the files back from git
# (refusing to start on a tree with changes to them). [Co-developed with claude code -- Adam]
set -u
WT="$1"; OUT="$2"; TOOL="$3"
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
SPIKE=doc/audit/2026-09-25_p4-heartbeat/spike
FILES=("$LIVE/08_heartbeat.sh" "$LIVE/07_roles_basic.sh" "$LIVE/_common.sh" "$SPIKE/S_heartbeat_spike.sh" "$SPIKE/oldcode_selftest.sh")
cd "$WT" || exit 2
[[ -z "$(git status --porcelain -- "${FILES[@]}")" ]] || { echo "REFUSE: the files have changes"; exit 2; }
echo "HEAD $(git rev-parse HEAD)"
rm -rf "$OUT"; mkdir -p "$OUT/cov"
trap 'git checkout -q -- "${FILES[@]}"; [[ -z "$(git status --porcelain -- "${FILES[@]}")" ]] && echo "files restored from git" || echo "!! FILES NOT RESTORED"' EXIT
python3 "$TOOL" mark "${FILES[@]}" > "$OUT/map.json" || exit 2
for f in "${FILES[@]}"; do bash -n "$f" || { echo "an instrumented file does not parse: $f"; exit 2; }; done
export COV_DIR="$OUT/cov"
run() { local name="$1"; shift; timeout 1800 "$@" > "$OUT/$name.out" 2>&1; echo "  $name rc $? -- $(tail -1 "$OUT/$name.out" | cut -c1-100)"; }
run 08_selftest bash "$LIVE/08_heartbeat.sh" --self-test
run 07_selftest bash "$LIVE/07_roles_basic.sh" --self-test
run live_p1_common bash tests/shell/test_live_p1_common.sh
run live_p1_thirteen bash tests/shell/test_live_p1_thirteen.sh
run spike_selftest bash "$SPIKE/S_heartbeat_spike.sh" --self-test
python3 "$TOOL" report "$OUT/map.json" "$OUT/cov"
