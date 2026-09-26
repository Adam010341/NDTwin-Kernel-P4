#!/usr/bin/env bash
# Mark every embedded program of 08, 07, _common.sh and the spike scripts IN PLACE, run the
# self-tests that could execute them with COV_DIR set, report, and put the files back from git
# (refusing to start on a tree with changes to them). [Co-developed with claude code -- Adam]
# Round 2b: the programs are embedded_sweep2's (logical lines), 07 runs with the real 08 captures,
# and oldcode_selftest.sh --list runs the tool whose whole body is the one program at its line 67
# (that is the TOOL running, not a self-test of it -- reported on its own row).
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
COV_ROOT="$OUT/cov"
anyfail=0
run() { local name="$1" rc; shift; mkdir -p "$COV_ROOT/$name"
         COV_DIR="$COV_ROOT/$name" timeout 1800 "$@" > "$OUT/$name.out" 2>&1; rc=$?
         (( rc == 0 )) || anyfail=1; echo "  $name rc $rc -- $(tail -1 "$OUT/$name.out" | cut -c1-100)"; }
run 08_selftest bash "$LIVE/08_heartbeat.sh" --self-test
run 07_selftest env SELFTEST_HB_RUN="${SELFTEST_HB_RUN:-}" SELFTEST_HB_PKGS="${SELFTEST_HB_PKGS:-}" bash "$LIVE/07_roles_basic.sh" --self-test
# 🔴 test_live_p1_common's 5e cells 'to-h2' and 'default' use the host names a real fabric has
# (h1..h3) and stub neither sudo nor iperf: with a lab fabric up, host_pid finds its hosts and the
# cell starts a REAL 2 Mbit/s iperf in them (this worker's 01:55:08 +0800 run did, into a live 06
# arm). So: not run while any mininet host exists, and the caller's PATH carries a sudo that refuses.
lab_hosts() { ps -eo args= 2>/dev/null | /usr/bin/grep -cE '(^| )mininet:[A-Za-z0-9_-]+$'; }
if [[ "$(lab_hosts)" != 0 ]]; then
    echo "  live_p1_common NOT RUN -- $(lab_hosts) mininet host(s) exist: a lab fabric is up"; anyfail=1
elif [[ "$(PATH="$PATH" bash -c 'type -P sudo')" != */nolab/sudo ]]; then
    echo "  live_p1_common NOT RUN -- the refusing sudo shim is not first on PATH"; anyfail=1
else
    run live_p1_common bash tests/shell/test_live_p1_common.sh
    echo "  (mininet hosts after it: $(lab_hosts))"
fi
run live_p1_thirteen bash tests/shell/test_live_p1_thirteen.sh
run spike_selftest bash "$SPIKE/S_heartbeat_spike.sh" --self-test
python3 "$TOOL" report "$OUT/map.json" "$OUT/cov"
# the tool itself (not a self-test), into its own marker directory so it cannot count as one
COV_ROOT="$OUT/cov-tool"
run oldcode_list_the_tool_itself bash "$SPIKE/oldcode_selftest.sh" --list
echo "MARKERS LEFT BY oldcode_selftest.sh --list: $(ls "$OUT/cov-tool/oldcode_list_the_tool_itself" | tr '\n' ' ')"
echo "COVER-RUN: $([[ $anyfail == 0 ]] && echo "every run under the markers exited 0" || echo "a run under the markers FAILED")"
exit $anyfail
