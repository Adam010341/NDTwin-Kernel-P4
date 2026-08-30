#!/bin/bash
# =================================================================================================
# guest_nsr_journey.sh -- follow the Network State Recorder documentation end to end, as a reader
# would, inside the clean-room VM.
#
# TWO PAGES, ONE JOURNEY. The auditor's dispatch names "the UM NSR page, 6 bash blocks". Reading
# it first showed that is not a journey: the User Manual page opens at
# `./start_network_state_recorder.sh` with no clone, no cd and no link to an install page. The
# install steps do exist -- Installation Manual / NDTwin Tool / Network State Recoder.md, 3 more
# blocks -- so the reader's real path is nine blocks across two pages, and the missing link
# between them is itself a finding. (I nearly reported "no install steps exist"; checking whether
# they existed elsewhere before claiming absence is what stopped that.)
#
# STRUCTURE: two passes, and the order matters.
#   PASS 1 -- LITERAL: every command exactly as printed, in the printed order, from the directory
#             a reader would plausibly be in. Failures here are findings about the documents.
#   PASS 2 -- RECOVERED: the same goal with the documented defects worked around (venv, cd).
#             This separates "the documentation is wrong" from "the software does not work".
#             Without pass 2 a broken doc and broken software look identical.
#
# Not `set -e`: pass 1 is expected to fail in places and every failure must be recorded, not
# abort the run.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
set -uo pipefail

OUT="${OUT:-$HOME/nsr-results}"
mkdir -p "$OUT"
RESULTS="$OUT/verdicts.tsv"; : > "$RESULTS"
LOG="$OUT/run.log"
NDT_URL="${NDT_URL:-http://localhost:8000}"

ts()  { date -Is; }
say() { echo; echo "=== $* ==="; }
verdict() { printf '%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" >> "$RESULTS"; printf '  %-10s %-4s %s\n' "$1" "$2" "$3"; }
# run_literal <id> <cwd> <command...> -- runs a documented command verbatim and records its rc
run_literal() {
    local id="$1" cwd="$2"; shift 2
    echo "--- [$id] cwd=$cwd :: $*" >> "$LOG"
    ( cd "$cwd" 2>/dev/null || { echo "cwd missing"; exit 127; }; eval "$@" ) >> "$LOG" 2>&1
    return $?
}

echo "guest_nsr_journey.sh starting $(ts)  ($(lsb_release -ds 2>/dev/null || echo unknown OS))" | tee -a "$LOG"

# =================================================================================================
say "PASS 1 -- LITERAL: Installation Manual / NDTwin Tool / Network State Recoder.md"
# =================================================================================================
HOME_START="$HOME"

# --- install block 1 --------------------------------------------------------------------------
# pip install nornir loguru orjson requests
run_literal I1 "$HOME_START" 'pip install nornir loguru orjson requests'
rc=$?
if [[ $rc -eq 0 ]]; then
    verdict INST-1 PASS "the page's 'pip install' worked as printed"
else
    if grep -q "externally-managed-environment" "$LOG"; then
        verdict INST-1 FAIL "pip install refused: externally-managed-environment (PEP 668). The page's Requirements section names no virtualenv, and the Kernel manual mandates Ubuntu 24.04, where this is the default. The first command a reader types does not work."
    else
        verdict INST-1 FAIL "pip install exited rc=$rc -- see $LOG"
    fi
fi

# --- install block 2 --------------------------------------------------------------------------
# git clone https://github.com/ndtwin-lab/Network-State-Recorder.git
run_literal I2 "$HOME_START" 'git clone https://github.com/ndtwin-lab/Network-State-Recorder.git'
rc=$?
if [[ $rc -eq 0 && -d "$HOME_START/Network-State-Recorder" ]]; then
    verdict INST-2 PASS "clone succeeded into $HOME_START/Network-State-Recorder"
else
    verdict INST-2 FAIL "clone failed rc=$rc (private repo? no network? already present?) -- see $LOG"
fi

# --- install block 3 --------------------------------------------------------------------------
# chmod +x start_network_state_recorder.sh stop_network_state_recorder.sh
# 🔑 Run from where the reader is standing after block 2: the page never says `cd`.
run_literal I3 "$HOME_START" 'chmod +x start_network_state_recorder.sh stop_network_state_recorder.sh'
rc=$?
if [[ $rc -eq 0 ]]; then
    verdict INST-3 PASS "chmod worked from the directory the page leaves the reader in"
else
    verdict INST-3 FAIL "chmod failed rc=$rc from \$HOME. The page prints clone then chmod with no 'cd Network-State-Recorder' between them, so the scripts are one directory below where the reader is standing. Same shape as M-1: a missing cd whose failure is quiet."
fi

# =================================================================================================
say "PASS 1 -- LITERAL: User Manual / NDTwin Tools / Network State Recoder.md"
# =================================================================================================
# The UM page's first command is ./start_network_state_recorder.sh with no cd and no clone. A
# reader arriving here from the site menu -- not from the install page -- is in $HOME.
run_literal U1 "$HOME_START" './start_network_state_recorder.sh'
rc=$?
if [[ $rc -eq 0 ]]; then
    verdict UM-1 PASS "start script ran from \$HOME"
else
    verdict UM-1 FAIL "'./start_network_state_recorder.sh' failed rc=$rc from \$HOME. The UM page states no working directory anywhere on it, and does not link to the install page that creates the checkout."
fi

# =================================================================================================
say "PASS 2 -- RECOVERED: same goal, documented defects worked around"
# =================================================================================================
NSR="$HOME_START/Network-State-Recorder"
if [[ ! -d "$NSR" ]]; then
    verdict REC-0 FAIL "no checkout at $NSR -- pass 2 cannot run"
else
    # Work around INST-1 the way Ubuntu 24.04 expects: a venv.
    python3 -m venv "$OUT/venv" >> "$LOG" 2>&1
    "$OUT/venv/bin/pip" install -q nornir loguru orjson requests >> "$LOG" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
        verdict REC-1 PASS "the four dependencies install cleanly into a venv -- so INST-1 is a documentation defect, not a broken dependency set"
    else
        verdict REC-1 FAIL "dependencies do NOT install even in a venv (rc=$rc) -- this is a real dependency problem, not just a missing venv instruction"
    fi

    chmod +x "$NSR/start_network_state_recorder.sh" "$NSR/stop_network_state_recorder.sh" 2>/dev/null
    verdict REC-2 "N/A" "chmod applied from inside the checkout (the 'cd' the page omits)"

    # The page's own API Dependency section: NSR needs these two endpoints.
    for ep in get_detected_flow_data get_graph_data; do
        code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$NDT_URL/ndt/$ep" 2>/dev/null)
        if [[ "$code" == "200" ]]; then
            verdict "API-$ep" PASS "/ndt/$ep answers 200, as the page's API Dependency table requires"
        else
            verdict "API-$ep" FAIL "/ndt/$ep -> http=$code. NSR cannot record without it; if no kernel is running this is a precondition the page states but the reader has no way to check from this page."
        fi
    done

    # Start it the documented way, from the right directory, with the venv on PATH.
    ( cd "$NSR" && PATH="$OUT/venv/bin:$PATH" setsid ./start_network_state_recorder.sh ) >> "$LOG" 2>&1
    sleep 12

    # Status check -- the page's block 3, verbatim. It uses `pgrep -f`, which this project has
    # banned for killing; here it is only reading, but the self-match hazard is the finding.
    PIDS="$(pgrep -f network_state_recorder.py || true)"
    SELF="$(pgrep -f network_state_recorder.py | while read -r p; do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'pgrep\|guest_nsr' && echo "$p"; done)"
    if [[ -n "$PIDS" ]]; then
        verdict REC-3 PASS "NSR is running; 'pgrep -f network_state_recorder.py' returns: $(echo "$PIDS" | tr '\n' ' ')"
    else
        verdict REC-3 FAIL "NSR did not start, or pgrep cannot see it"
    fi
    if [[ -n "$SELF" ]]; then
        verdict PGREP-SELF FAIL "the page's status command matched processes that are NOT NSR (pids: $SELF). Its stop command is 'sudo kill -15 \$(pgrep -f network_state_recorder.py)', so a false match there is a kill of the wrong process."
    else
        verdict PGREP-SELF "N/A" "no self-match observed in this invocation. NOTE: pgrep -f matches command lines, so a shell whose own argv carries the pattern (bash -c '...', an editor, a grep) does match. Absence here is one sample, not a proof."
    fi

    # Does it actually record? That is what the tool is for.
    sleep 20
    N_REC=$(find "$NSR/recorded_info" -newermt '-2 minutes' -type f 2>/dev/null | wc -l)
    if [[ "$N_REC" -gt 0 ]]; then
        verdict REC-4 PASS "$N_REC file(s) written into recorded_info/ within 2 minutes -- NSR does the thing the page says it does"
    else
        verdict REC-4 FAIL "nothing new in recorded_info/. Either the kernel is not serving, or NSR is running without recording."
    fi

    # Log file the page tells you to tail. NOT `tail -f` -- that never returns.
    TODAY_LOG="$NSR/logs/NSR_$(date +%Y-%m-%d).log"
    if [[ -f "$TODAY_LOG" ]]; then
        verdict REC-5 PASS "$TODAY_LOG exists, matching the page's 'tail -f logs/NSR_\$(date +%F).log'"
    else
        verdict REC-5 FAIL "no $TODAY_LOG. The page's tail command embeds today's date, so it also breaks for a run started before midnight."
    fi

    # Stop it the documented way (option 1, the script -- not the pgrep kill).
    ( cd "$NSR" && ./stop_network_state_recorder.sh ) >> "$LOG" 2>&1
    sleep 5
    if pgrep -f network_state_recorder.py >/dev/null 2>&1; then
        verdict REC-6 FAIL "stop script returned but NSR is still running -- a stop that reports success while the process survives"
    else
        verdict REC-6 PASS "stop script stopped it, verified against the process table rather than its exit code"
    fi

    # The two scripts' documented side effect on the config.
    CFG="$NSR/setting/recorder_setting.yaml"
    [[ -f "$CFG" ]] && verdict REC-7 "N/A" "display_on_console after stop: $(grep -m1 display_on_console "$CFG" 2>/dev/null | tr -d ' ') (the UM page says start sets it false and stop sets it true)"
fi

# =================================================================================================
say "SUMMARY"
awk -F'\t' '{printf "  %-12s %-4s %s\n", $2, $3, $4}' "$RESULTS"
echo
echo "  PASS=$(awk -F'\t' '$3=="PASS"' "$RESULTS" | wc -l)  FAIL=$(awk -F'\t' '$3=="FAIL"' "$RESULTS" | wc -l)  N/A=$(awk -F'\t' '$3=="N/A"' "$RESULTS" | wc -l)"
echo "  verdicts: $RESULTS    log: $LOG"
echo "guest_nsr_journey.sh done $(ts)"
