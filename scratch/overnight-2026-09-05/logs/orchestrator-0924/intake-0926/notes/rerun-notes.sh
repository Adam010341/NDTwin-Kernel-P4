#!/usr/bin/env bash
# Orchestrator rerun on the test merge bdcf64b8 (trunk b005bf50 + fix/followup-notes-0927 16069d1a,
# tree 4feceb1a): the suites and gates the branch changed, plus three red arms of my own --
#   R3-N3: trunk's 07 self-test vs the merge's, each in its own session; what is left in it after exit.
#   R3-N4: trunk's 07 with l6_plain's default 30 -> 40: its self-test (expected PASS, it cannot see it).
#   NOTE-2: trunk's reentrant suite vs the merge's, with NO_CGROUP=1 / TIMEOUT=1 inherited.
# Through the guard, sudo/curl tripwire outermost on PATH; knobs hashed. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/notes; GUARD=$W/tools/build_guard/guarded_build.sh
P=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
M=bdcf64b8fc48851f87b5390081432e13ee962a76; B=b005bf50
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset L1_POLL_S SELFTEST_L1_POLL_S SELFTEST_PROBE_SUDO JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP
knobs() { for k in host_count_override app_package_override telemetry_override; do
    f=$R/p4_proxy/mininet/$k; [[ -e $f ]] && echo "$k $(sha256sum < $f | cut -c1-16) $(stat -c %Y $f)" || echo "$k absent"; done; }
knobs > "$O/knobs-before.txt"
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-notes; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.bdcf64b8.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(SELF-TEST|mutation gate|Ran [0-9]+|.*[0-9]+ passed|.*cells ok|SESSION|08.s mutant tree)' $log | tail -2 | tr '\n' ' ')"; }

# helper for R3-N3: run a 07 copy's self-test in a session of its own; count what is left in it
cat > "$TMPDIR/sess07.sh" <<'EOF'
#!/usr/bin/env bash
f=$1; d=$(mktemp -d)
setsid -w bash -c 'echo $$ > "$1/sid"; exec bash "$2" --self-test' _ "$d" "$f" > "$d/out" 2>&1; rc=$?
sid=$(< "$d/sid"); left() { ps -eo sid=,pid=,args= | awk -v s="$sid" '$1==s' ; }
echo "self-test rc=$rc last: $(tail -1 "$d/out")"
echo "SESSION $sid left at exit: $(left | wc -l)"; left | sed 's/^/  /'
sleep 30; echo "SESSION $sid left 30 s later: $(left | wc -l)"; left | sed 's/^/  /'
EOF
chmod +x "$TMPDIR/sess07.sh"

# --- red arms (trunk's files as copies beside the merge's; removed after) ---
git -C "$W" show $B:$P/07_roles_basic.sh > "$W/$P/.redfirst-notes-07.sh"
run R3N3_TRUNK_07_session bash "$TMPDIR/sess07.sh" "$P/.redfirst-notes-07.sh"
run R3N3_MERGE_07_session bash "$TMPDIR/sess07.sh" "$P/07_roles_basic.sh"
sed -i 's|"L6: no switch_state on the control fabric" "${1:-30}"|"L6: no switch_state on the control fabric" "${1:-40}"|' "$W/$P/.redfirst-notes-07.sh"
echo "R3N4 trunk copy mutated lines: $(grep -c 'control fabric" "${1:-40}"' "$W/$P/.redfirst-notes-07.sh")"
run R3N4_TRUNK_07_plain40 bash "$P/.redfirst-notes-07.sh" --self-test
rm -f "$W/$P/.redfirst-notes-07.sh"
git -C "$W" show $B:tests/shell/test_guarded_build_reentrant.sh > "$W/tests/shell/.redfirst-notes-reentrant.sh"
run NOTE2_TRUNK_reentrant_nocg env NO_CGROUP=1 bash tests/shell/.redfirst-notes-reentrant.sh
run NOTE2_TRUNK_reentrant_to1  env TIMEOUT=1 bash tests/shell/.redfirst-notes-reentrant.sh
rm -f "$W/tests/shell/.redfirst-notes-reentrant.sh"
run NOTE2_MERGE_reentrant_nocg env NO_CGROUP=1 bash tests/shell/test_guarded_build_reentrant.sh
run NOTE2_MERGE_reentrant_to1  env TIMEOUT=1 bash tests/shell/test_guarded_build_reentrant.sh

# --- the merge's own suites and gates ---
run live07_selftest bash $P/07_roles_basic.sh --self-test
run live08_selftest bash $P/08_heartbeat.sh --self-test
run test_build_guard bash tests/shell/test_build_guard.sh
run test_guarded_build_reentrant bash tests/shell/test_guarded_build_reentrant.sh
run test_l1_shell_scoring bash tests/shell/test_l1_shell_scoring.sh
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
run mutate_build_guard bash tests/shell/mutate_build_guard.sh
run mutate_roles_binding bash tests/shell/mutate_roles_binding.sh
run mutate_p4_heartbeat_w bash tests/shell/mutate_p4_heartbeat_w.sh
knobs > "$O/knobs-after.txt"
cmp -s "$O/knobs-before.txt" "$O/knobs-after.txt" && echo "main checkout's lab-state knobs unchanged" || { echo "🔴 KNOBS CHANGED"; diff "$O/knobs-before.txt" "$O/knobs-after.txt"; }
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
ls "$W"/tests/shell/.redfirst-* "$W"/tests/shell/.mutant-* "$W/$P"/.redfirst-* 2>/dev/null && echo "LEFTOVER copies" || echo "no leftover copies"
echo RERUN-NOTES-DONE
