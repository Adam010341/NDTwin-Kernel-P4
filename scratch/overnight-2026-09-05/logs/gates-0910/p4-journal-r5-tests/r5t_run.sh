#!/usr/bin/env bash
# r5t_run.sh <branch head sha> (not named *driver.sh: guard.sh counts those as busy) : the checks of feat/p4-journal-r5-tests, one at a time, in one gate clone, each behind
# merged-trunk-1015/guard.sh (busy -> wait 60 s and retry, up to 6 h; a blocked stop signal -> stop) and exec'd through
# merged-trunk-1015/mexec.sh (refuses unless the exec'ing process has SigBlk & 0x4203 == 0). Each step's verdict is the
# last line of its own log (runlog.sh writes rc=N there), never this script's $?. Kills nothing but the clone dir it made.
# Steps: clone at HEAD; the two journal test files; check_gate_anchors; the bmv2 trial at HEAD (every sequence, m2r
# included); the SAME clone checked out at 7f69609b (before the insert retry) for the m2r red control, then back at HEAD;
# the journal mutation gate; which tests the gate saw red; the p4_proxy lane; the clone removed.
# [Co-developed with claude code -- Adam]
E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-journal-r5-tests
M=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015
CI=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/r5tests
C=$S/gate; D=$E/driver.log
HEAD_SHA="$1"; RED_SHA=7f69609b
PY=p4_proxy/venv/bin/python
export TMPDIR=$S/tmp
mkdir -p "$TMPDIR"
echo "$(date -Is) driver start pid $$ head $HEAD_SHA; SigBlk $(awk '/^SigBlk/{print $2}' /proc/$$/status)" >> "$D"
stop() { echo "$*" > "$E/STOPPED"; echo "$(date -Is) STOPPED: $*" >> "$D"; exit 2; }
wait_ok() {   # $1 = step name
    local name="$1" n=0 g
    while :; do
        bash "$M/guard.sh" "$E/$name.guard.log"; g=$?
        [[ $g -eq 0 ]] && break
        [[ $g -eq 2 ]] && stop "a stop signal is blocked before $name (see $name.guard.log)"
        n=$((n+1)); [[ $n -gt 360 ]] && stop "guard busy for 6 h before $name"
        echo "$(date -Is) [$name] guard busy (try $n): $(grep 'guard: [0-9]' "$E/$name.guard.log" | tail -1 | cut -c1-200)" >> "$D"
        sleep 60
    done
    echo "$(date -Is) [$name] guard ok: $(grep -E 'guard: [0-9]+ matching|SigBlk &' "$E/$name.guard.log" | tail -2 | tr '\n' ' ')" >> "$D"
}
step() {   # step <name> <cap s> <log> <cmd...> : guard, then the command through mexec under timeout, in the clone
    local name="$1" cap="$2" log="$3"; shift 3
    wait_ok "$name"
    echo "$(date -Is) [$name] start (cap ${cap}s)" >> "$D"
    ( cd "$C" && setsid --wait nice -n 19 bash "$M/mexec.sh" "$E/$name.guard.log" timeout -k 60 "$cap" "$@" ) >/dev/null 2>&1
    echo "$(date -Is) [$name] end exit=$? :: last line of $(basename "$log"): $(tail -1 "$log" 2>/dev/null | cut -c1-120) :: $(grep -E 'mutation gate:|cells ok|FAILURES=|^Ran |^OK|^FAILED|ALL CHECKS|tests: [0-9]+, seen red' "$log" 2>/dev/null | tail -2 | cut -c1-200 | tr '\n' ' ')" >> "$D"
}
RL="bash $M/runlog.sh"

# --- the clone ---
wait_ok mkclone
free=$(df -m / | awk 'NR==2{print $4}')
[[ "$free" -ge 2500 ]] || stop "df -m / free $free MB < 2500 before the clone"
rm -rf "$C"
bash "$M/mkclone.sh" "$C" "$HEAD_SHA" "$E/p4build.log" >> "$D" 2>&1 || stop "mkclone failed (see p4build.log)"
[[ "$(git -C "$C" rev-parse HEAD)" == "$HEAD_SHA" ]] || stop "clone HEAD is not $HEAD_SHA"

step two_test_files_whole 1200 "$E/two_test_files_whole.log" $RL "$E/two_test_files_whole.log" bash "$M/unit.sh" tests.test_table_entry_replay tests.test_table_entry_journal
step gate_anchors_clone 1200 "$E/gate_anchors_clone.log" $RL "$E/gate_anchors_clone.log" $PY tests/shell/check_gate_anchors.py HEAD
step trial_head 1800 "$E/trial-r5tests.log" bash "$E/trial_run.sh" "$C" r5tests

# --- the red control: the same clone at the code before the insert retry, then back to HEAD ---
git -C "$C" checkout -q --detach "$RED_SHA" >> "$D" 2>&1 || stop "checkout $RED_SHA failed"
echo "$(date -Is) clone now at $(git -C "$C" rev-parse HEAD) for the red control" >> "$D"
step trial_m2r_red 1800 "$E/trial-r5tests-red.log" env TRIAL_ONLY_M2R=1 bash "$E/trial_run.sh" "$C" r5tests-red
git -C "$C" checkout -q --detach "$HEAD_SHA" >> "$D" 2>&1 || stop "checkout $HEAD_SHA failed"
[[ "$(git -C "$C" rev-parse HEAD)" == "$HEAD_SHA" && "$(git -C "$C" status --porcelain --untracked-files=no | wc -l)" -eq 0 ]] || stop "clone is not clean at $HEAD_SHA after the red control"
echo "$(date -Is) clone back at $(git -C "$C" rev-parse HEAD), tracked-dirty 0" >> "$D"

step mutate_table_journal 5400 "$E/mutate_table_journal.log" $RL "$E/mutate_table_journal.log" bash tests/shell/mutate_table_journal.sh
step journal_tests_seen_red 600 "$E/journal_tests_seen_red.log" $RL "$E/journal_tests_seen_red.log" python3 "$M/seen_red.py" "$C" "$E/mutate_table_journal.log" tests.test_table_entry_replay tests.test_table_entry_journal
step p4lane 2400 "$E/p4lane.log" $RL "$E/p4lane.log" bash "$CI/p4lane.sh" "$C"

rm -rf "$C"
echo "$(date -Is) all done; clone removed: $([[ -e $C ]] && echo NO || echo yes)" >> "$D"
touch "$E/driver.done"
