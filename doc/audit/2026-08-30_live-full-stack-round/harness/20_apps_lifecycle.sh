#!/bin/bash
# =================================================================================================
# 20_apps_lifecycle.sh -- start and stop the FOUR non-destructive consumer apps (sim, nsr, viz,
# te), and time R-3's convergence: from `ndt up` to each app actually serving.
#
# 🔴 `energy` IS DELIBERATELY NOT IN THIS SCRIPT. It powers switches off for real. It lives in
#    25_apps_energy.sh, runs last, and has its own restore step (90_restore.sh).
#
# WRITTEN, NOT RUN. `bash -n` only.
#
# 🔴 TWO PREREG PREMISES THIS SCRIPT CONTRADICTS -- READ BEFORE INTERPRETING ANY NUMBER
#
#  (1) "Consumers poll on a 15 s cadence" (PREREG §3 R-2). Measured from the apps' own source
#      on 2026-08-30, no app uses 15 s:
#        energy 60 s   Energy-Saving-App/include/app/settings.hpp:8 (CHECKING_INTERVAL_IN_SECOND)
#                      + a 1 s inner poll during power-on waits (energy_saving_app.cpp:141-179)
#        sim    none   Simulation-Platform-Manager is EVENT-DRIVEN: it serves :9000 and POSTs
#                      /ndt/simulation_completed only when a simulation finishes. It has no loop.
#        nsr    5 s    Network-State-Recorder/setting/recorder_setting.yaml:5 (code default 1 s
#                      at network_state_recorder.py:25, overridden at :285)
#        viz    1 s    NetworkTopologyApp.java:424 scheduleAtFixedRate(..., 0, 1, SECONDS)
#        te     1 s    Traffic-engineering-App.py:41 get_graph_data_interval = 1
#      Three of the five poll FASTER than R-2's 1 Hz path recompute. R-2's registered
#      expectation of "no observable difference" rests on the 15 s figure, so its premise does
#      not hold. This is recorded, not silently corrected: amending a pre-registration is the
#      auditor's call, not the harness's, and "the threshold blocked me so I moved it" is the
#      worst possible reason to change one.
#
#  (2) "convergence time from `ndt up` to all five apps serving. 08-18 reference: 69 s (OVS) /
#      2 s (P4)" (PREREG §3 R-3). Those two numbers come from the 08-18 documents' own headers
#      -- "Converged after 69s" / "Converged in 2s" -- where they describe the STACK coming up
#      (fabric + control plane + kernel), measured before the apps were started. They are not
#      app-convergence times. Comparing an all-five-apps-serving number to them would put two
#      different populations on the two sides of one comparison.
#      This script therefore records TWO separate quantities and never subtracts one from the
#      other:  T_stack = ndt up -> "up. ready"   and   T_app[i] = ndt up -> app i first serves.
#      Only T_stack is comparable to 69 s / 2 s.
#
# H-CORRESPONDENCE
#   H-17  every liveness test is lib.sh `alive()` (/proc). No `kill -0`. The apps started here
#         run as the invoking user, but the topology under them is root-owned, and a harness
#         that uses the safe form only where it remembers to is the harness that failed on 08-30.
#   H-18  every log string is a registered pattern, self-tested against a sample taken from the
#         emitting source before anything is measured.
#   H-19  "app is serving" is asserted from a POSITIVE artefact (a file it wrote, a port it
#         holds), never from the absence of an error. An app that logs nothing is not an app
#         that is working.
#   H-20  each app log's pre-run signature is compared against 00_preflight.sh's baseline before
#         it is read, so a previous run's log cannot supply this run's evidence. `ndt`'s
#         app_spawn renames a non-empty log to .prev (ndt:1542), which helps but is not relied on.
#   H-21  pipefail from lib.sh; every gate takes a pre-computed value.
#   H-22  🔑 THE DEFECT THAT PRODUCED THE RETRACTED T2-1. Nothing here is backgrounded with
#         `( ... ) &` and then addressed by `$!`. `spawn_exec` execs through every layer so the
#         pid is the program's, and then PROVES it by matching /proc/<pid>/cmdline. Shutdown
#         uses that recorded pid. `pkill -f` and `pgrep -f` appear nowhere.
#   H-23  see H-18; the reversed-grep case is covered by the registry's must-match samples.
#   H-24  PYTHONUNBUFFERED=1 from lib.sh, and `wait_for_line` polls rather than reading once.
#         The 08-30 run read a 706-line proxy log with no HTTP lines in it and concluded the
#         server had served nothing.
#
# ADDITIONAL, FOUND WHILE WRITING THIS
#   * `te` cannot start headless. Traffic-engineering-App.py:617 calls ask_mode(), which calls
#     input() at :599 and :605 with no EOFError guard (only enter_listener() at :591 catches it).
#     With stdin not a terminal, input() raises EOFError and main() dies before a single poll.
#     `ndt apps te` uses nohup with stdout redirected and stdin inherited (ndt:1543), so from a
#     script it dies. This script starts te under a pty via `script`, feeds it "1", and records
#     BOTH outcomes -- the headless failure is itself worth reporting.
#     This is the same shape as T-3's pty point: a program tested without a terminal is not the
#     program the reader runs.
#   * `viz` is a JavaFX GUI and ndt:1570 refuses to start it with no DISPLAY. On a headless
#     executor R-3 is a FOUR-app convergence, and must be written up as such.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harness_begin 20_apps_lifecycle

# shellcheck source=/dev/null
. "$REPO/tools/test_workflow/components.env"

FABRIC="${1:-p4}"     # p4 | ovs   -- which stack is up; affects nothing here but the record
BASELINE="$OUT/artifact-baseline.txt"
[[ -f "$BASELINE" ]] || die "no artefact baseline at $BASELINE -- run 00_preflight.sh first. Without it, H-20 is unguarded and a previous run's logs can supply this run's evidence."

T0_FILE="$OUT/t0_ndt_up_epoch"
[[ -f "$T0_FILE" ]] || die "no $T0_FILE. The executor must record the epoch second at which 'ndt up' was invoked: date +%s > $T0_FILE"
T0="$(cat "$T0_FILE")"
info "T0 (ndt up invoked) = $T0 ($(date -u -d "@$T0" +%Y-%m-%dT%H:%M:%SZ))"

sig_of() { grep -P "^\Q$1\E\t" "$BASELINE" 2>/dev/null | head -1 | cut -f2 || true; }

# -------------------------------------------------------------------------------------------------
say "T_stack -- the only quantity comparable to 08-18's 69 s / 2 s"
if [[ -f "$OUT/ndt_up.log" ]]; then
    READY_N="$(count_matches ndt_up_ready "$OUT/ndt_up.log")"
    if [[ "$READY_N" != "0" && "$READY_N" != "-1" ]]; then
        T_READY="$(stat -c %Y "$OUT/ndt_up.log")"
        info "T_stack ~= $(( T_READY - T0 )) s  (mtime of ndt_up.log at its last write minus T0)"
        info "This is a CEILING, not the instant of readiness: the log keeps being written after"
        info "the ready line. For a tight number the executor should timestamp by hand:"
        info "  date +%s > $OUT/t_stack_ready_epoch   immediately after 'up. ready' appears."
        [[ -f "$OUT/t_stack_ready_epoch" ]] && info "hand-recorded T_stack = $(( $(cat "$OUT/t_stack_ready_epoch") - T0 )) s"
        ok "stack reached ready; T_stack recorded"
    else
        bad "ndt_up.log has no ready line -- the stack did not converge, which is R-3's registered break condition"
    fi
else
    skip "no $OUT/ndt_up.log; T_stack not measurable in this run (the executor brought the stack up outside the harness)"
fi

# -------------------------------------------------------------------------------------------------
# Per-app "first serves" evidence. Each is a POSITIVE artefact (H-19).
#
#   sim  :9000 is held by the simulation_platform_manager we started. It is event-driven, so
#        "serving" means listening, NOT polling. Waiting for it to poll would wait forever --
#        the same trap as `ndt status`'s orphaned-iperf3 note.
#   nsr  a new file under $NSR_DIR/recorded_info/ , or its log naming the kernel.
#   viz  its log; plus the JavaFX window it cannot open without a display.
#   te   its log; TE writes a dated .json in its own directory once running.
# -------------------------------------------------------------------------------------------------

first_serve_epoch() {
    # first_serve_epoch <glob-dir> <since-epoch> -- newest file in dir strictly newer than T0
    local dir="$1" since="$2" newest
    [[ -d "$dir" ]] || { printf '%s' "-1"; return 0; }
    newest="$(find "$dir" -maxdepth 1 -type f -newermt "@$since" -printf '%T@\n' 2>/dev/null \
              | sort -n | head -1 || true)"
    [[ -n "$newest" ]] && printf '%.0f' "$newest" || printf '%s' "-1"
}

declare -A T_APP

# --- sim ------------------------------------------------------------------------------------------
say "app: sim (Simulation-Platform-Manager)"
info "started through ndtwin-lab's NOPASSWD verb, in a tmux session (ndt:1565)"
set +e
"$NDT_BIN" apps sim > "$OUT/app_sim_start.log" 2>&1
set -e
sed 's/^/      /' "$OUT/app_sim_start.log" || true
SIM_WAIT=0
for i in $(seq 1 60); do
    [[ -n "$(port_holder 9000)" ]] && { SIM_WAIT=$i; break; }
    sleep 1
done
SIM_PID="$(port_holder 9000)"
if [[ -n "$SIM_PID" ]]; then
    T_APP[sim]=$(( T0 + SIM_WAIT ))
    ok "sim is serving :9000 after ~${SIM_WAIT}s (pid $SIM_PID: $(proc_cmdline "$SIM_PID" | cut -c1-70))"
    info "sim has NO polling loop; 'serving' here means listening. Do not wait for it to appear in the kernel log -- it only POSTs /ndt/simulation_completed when a simulation finishes."
else
    bad "sim never opened :9000 within 60s (see $OUT/app_sim_start.log)"
fi

# --- nsr ------------------------------------------------------------------------------------------
say "app: nsr (Network-State-Recorder)"
NSR_LOG="$LOG_DIR/app_nsr.log"
NSR_BASE="$(sig_of "$NSR_LOG")"
info "pre-run signature of $NSR_LOG: ${NSR_BASE:-<not in baseline>}"
set +e
"$NDT_BIN" apps nsr > "$OUT/app_nsr_start.log" 2>&1
set -e
sed 's/^/      /' "$OUT/app_nsr_start.log" || true
# H-20: the log must have been rewritten by THIS run before anything is read from it.
require_absent_or_fresh "$NSR_LOG" "${NSR_BASE:-ABSENT}"
NSR_T="$(first_serve_epoch "$NSR_DIR/recorded_info" "$T0")"
if [[ "$NSR_T" != "-1" ]]; then
    T_APP[nsr]="$NSR_T"
    ok "nsr wrote a new file under $NSR_DIR/recorded_info at +$(( NSR_T - T0 ))s -- a positive artefact, not the absence of an error"
else
    # Give it its configured cadence plus margin before calling it a failure. 5 s per
    # recorder_setting.yaml:5, so 60 s is twelve cycles.
    for i in $(seq 1 60); do
        NSR_T="$(first_serve_epoch "$NSR_DIR/recorded_info" "$T0")"
        [[ "$NSR_T" != "-1" ]] && break
        sleep 1
    done
    if [[ "$NSR_T" != "-1" ]]; then
        T_APP[nsr]="$NSR_T"; ok "nsr wrote its first record at +$(( NSR_T - T0 ))s"
    else
        bad "nsr produced no record in $NSR_DIR/recorded_info within 60s (12 cycles at its configured 5 s). Tail of its log:"
        tail -10 "$NSR_LOG" 2>/dev/null | sed 's/^/        /' || true
    fi
fi

# --- viz ------------------------------------------------------------------------------------------
say "app: viz (Network-Traffic-Visualizer)"
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    skip "viz NOT STARTED: no DISPLAY/WAYLAND_DISPLAY, and ndt:1570 refuses it. R-3 for this run is a FOUR-app convergence and the write-up must say so rather than reporting five."
else
    VIZ_LOG="$LOG_DIR/app_viz.log"
    VIZ_BASE="$(sig_of "$VIZ_LOG")"
    set +e
    "$NDT_BIN" apps viz > "$OUT/app_viz_start.log" 2>&1
    set -e
    sed 's/^/      /' "$OUT/app_viz_start.log" || true
    info "first run builds with maven and is slow (ndt:1575) -- allowing 300 s"
    VIZ_T=-1
    for i in $(seq 1 300); do
        if [[ -s "$VIZ_LOG" ]] && grep -qiE 'topolog|graph|node|edge' "$VIZ_LOG"; then VIZ_T=$(( T0 + i )); break; fi
        sleep 1
    done
    if (( VIZ_T > 0 )); then
        require_absent_or_fresh "$VIZ_LOG" "${VIZ_BASE:-ABSENT}"
        T_APP[viz]="$VIZ_T"; ok "viz produced topology output at ~+$(( VIZ_T - T0 ))s"
    else
        bad "viz produced nothing recognisable in 300s (see $VIZ_LOG)"
    fi
    info "⚠️ CALIBRATION DEBT: the viz pattern above ('topolog|graph|node|edge') was NOT taken from viz's emitted output -- viz has never been run in this project's audits and there is no sample log to copy from. It is the one un-calibrated pattern in this harness. After the first run, copy a real line out of $VIZ_LOG into lib.sh's PATTERN REGISTRY and replace this grep. Until then, treat a viz PASS as weak evidence and a viz FAIL as uninformative."
fi

# --- te -------------------------------------------------------------------------------------------
say "app: te (Traffic-Engineering-App)"
TE_LOG="$LOG_DIR/app_te.log"
TE_BASE="$(sig_of "$TE_LOG")"

# STEP 1 -- the documented way, exactly as a reader/executor would do it. Expected to fail.
# This is not a formality: "the sanctioned command does not work headless" is a finding, and it
# can only be observed by running the sanctioned command.
info "step 1: 'ndt apps te' as documented (expected to die on EOFError -- see header)"
set +e
"$NDT_BIN" apps te > "$OUT/app_te_start_documented.log" 2>&1 < /dev/null
set -e
sed 's/^/      /' "$OUT/app_te_start_documented.log" || true
TE_EOF="$(count_matches te_eof_crash "$TE_LOG")"
if [[ "$TE_EOF" != "0" && "$TE_EOF" != "-1" ]]; then
    bad "te died on EOFError when started the documented way (ask_mode() -> input() at Traffic-engineering-App.py:599, no guard). The documented start path cannot work without a terminal. This is a finding for R-4, not a harness fault."
else
    ok "te survived the documented headless start (contradicts the source read at Traffic-engineering-App.py:595-612 -- re-read it before writing this up)"
fi

# STEP 2 -- give it a pty so the round still has a TE consumer.
# `script` allocates a pty; TE then sees a terminal, prints its menu, and takes "1" for mode 1
# (Enter-triggered), which is the default and the least invasive: mode 2 would run TE
# periodically and install flow rules on its own schedule.
TE_PID=""
if [[ ! -f "$PID_DIR/app_te.pid" ]] || ! alive "$(cat "$PID_DIR/app_te.pid" 2>/dev/null || echo 0)"; then
    info "step 2: restarting te under a pty (the T-3 pty point: a program tested without a terminal is not the program a reader runs)"
    mkdir -p "$LOG_DIR"
    # H-22: `script` is exec'd as the single child, so $! is its pid; we then verify the cmdline.
    # NOT `TE_PID="$(spawn_exec …)"`. That captured spawn_exec's PASS line along with the pid,
    # left TE_PID a blob that was non-empty (so this looked like success) but not a live pid (so
    # the wait loop below broke on its first iteration), and swallowed spawn_exec's own ok/bad
    # lines and their CHECKS/FAILS increments into the subshell. See lib.sh spawn_exec.
    spawn_exec te_pty "$TE_APP_DIR" "$LOG_DIR/app_te.log" \
        script -qfc "printf '1\n' | $TE_PY Traffic-engineering-App.py" /dev/null || SPAWN_PID=""
    TE_PID="$SPAWN_PID"
fi
if [[ -n "$TE_PID" ]]; then
    TE_T=-1
    for i in $(seq 1 90); do
        if [[ -s "$TE_LOG" ]] && grep -qiE 'Select TE mode|graph|flow' "$TE_LOG"; then TE_T=$(( T0 + i )); break; fi
        alive "$TE_PID" || break
        sleep 1
    done
    if (( TE_T > 0 )); then
        require_absent_or_fresh "$TE_LOG" "${TE_BASE:-ABSENT}"
        T_APP[te]="$TE_T"; ok "te is running under a pty and producing output at ~+$(( TE_T - T0 ))s (pid $TE_PID)"
        info "te is in MODE 1: it runs run_te() only on Enter. It polls get_graph_data every 1 s (Traffic-engineering-App.py:41) but installs NO flow rules unless triggered. That is deliberate -- mode 2 would mutate the fabric on its own schedule and confound every other measurement in this round."
    else
        bad "te under a pty produced no output in 90s (see $TE_LOG)"
    fi
else
    bad "te could not be started even under a pty"
fi

# -------------------------------------------------------------------------------------------------
say "R-3 -- convergence table"
{
    printf 'T0 (ndt up invoked)\t%s\n' "$T0"
    for a in sim nsr viz te; do
        if [[ -n "${T_APP[$a]:-}" ]]; then
            printf '%s\tfirst served at\t%s\t(+%s s)\n' "$a" "${T_APP[$a]}" "$(( ${T_APP[$a]} - T0 ))"
        else
            printf '%s\tDID NOT SERVE\t-\t-\n' "$a"
        fi
    done
    printf 'energy\tnot started by this script (destructive; see 25_apps_energy.sh)\t-\t-\n'
} > "$OUT/r3_convergence.tsv"
sed 's/^/      /' "$OUT/r3_convergence.tsv"
SERVED=0; for a in sim nsr viz te; do [[ -n "${T_APP[$a]:-}" ]] && SERVED=$((SERVED+1)); done
info "apps serving: $SERVED of 4 (excluding energy)"
# PREREG §3 R-3: "Break condition is failure to converge, not a different number."
if (( SERVED == 4 )); then
    ok "R-3: every app this script starts converged. The elapsed seconds are recorded but are NOT the verdict, and must not be compared to 08-18's 69 s / 2 s (different population -- see header)."
else
    bad "R-3 BREAK CONDITION MET: $SERVED of 4 apps converged. Name which, and why, from the logs above."
fi

summary
info "next: 30_r2_r3_sample.py (sampling), then 40_r5_p4.sh. Run 25_apps_energy.sh LAST."
exit 0
