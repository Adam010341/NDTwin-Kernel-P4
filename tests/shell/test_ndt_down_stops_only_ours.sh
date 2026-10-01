#!/usr/bin/env bash
#
# `ndt down`'s [0/3] with BOTH kinds of process on the field: this checkout's orphan and another
# worktree's test fixture. One of them is stopped; the other is listed and left alone.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS FILE EXISTS. C10-8 (FIX-NDT-10, 2026-09-12) taught `ndt` to tell its own processes
# from another checkout's, and it was measured on both halves -- but never on both halves AT
# ONCE through cmd_down. FIX-NDT-10 SUMMARY section 7-10: its `green-2-down-fixed.log` had only
# the foreign process on the field, so it proved "it does not stop theirs" and nothing about
# "it still stops ours". The [0/3] gate is `app_probe` (G-6), and `apps orphans`' cells cannot
# support it: somebody who changed that gate back to `app_running` would leave every orphans
# cell green. This file is the one report with one of each in it.
#
# What went wrong before C10-8, verbatim from the 15:4x restore log of 2026-09-12:
#     !!  sim is running untracked (pid 1166836) -- stopping it by pid
#     XX  could NOT stop sim
# -- one tree's teardown reaching for another tree's running test.
#
# 🔴 OFFLINE, AND IT STAYS OFFLINE. The shape is tests/shell/test_ndt_down_claim_guard.sh's:
# `ndt` is sourced (it returns early when sourced), REPO is a temp dir, $STACK and $LAB are
# fixture scripts, `sudo` is a shell function that only records, and every reading that would
# describe this machine is answered from the fixture. The lab, :8000 and root are never reached.
# What is REAL is everything this file is about: cmd_down's [0/3] loop, app_probe,
# app_claims_pid, proc_checkout, app_stop and the signal it sends.
#
# 🔴 THE FIXTURES HAVE THEIR OWN SESSIONS (setsid) and this script kills them by exact pid when
# it is done, then reads /proc back and says whether they are gone -- printed, not assumed. They
# also carry a TTL so that a SIGKILLed run cannot leave them behind; the TTL is the backstop, the
# kill is the cleanup, and the line this script prints says which one the reader is looking at.
#
# Run:  bash tests/shell/test_ndt_down_stops_only_ours.sh
# Env:  NDT_UNDER_TEST=<path>   (a mutation gate points this at a copy)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -r "$NDT" ]] || { echo "  FAILED   no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }
command -v setsid >/dev/null 2>&1 || {
    echo "  FAILED   this suite needs setsid: a fixture that shares this shell's process group"
    echo "           is one app_kill_group REFUSES to signal, so the run would prove nothing"
    echo "Ran 1 checks, 1 failed"; exit 1; }

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has()   { grep -qF -- "$2" <<<"$3" && { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; } \
          || { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"; }; }
hasnt() { grep -qF -- "$2" <<<"$3" && { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             unexpected: [%s]\n' "$1" "$2"; } \
          || { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }; }
section() { printf '\n%s\n' "$1"; }
alive()  { [[ -d "/proc/$1" ]] && echo yes || echo no; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-down-ours-XXXXXX")"
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/tools/test_workflow" "$FIX/etc"
# The other tree: a directory with a .git in it is a checkout of its own, and a path inside it
# belongs to THAT tree -- which is the rule every wt-* worktree on this machine needs, since they
# all live under the main checkout.
OTHER_TREE="$FIX/scratch/wt-other"
mkdir -p "$OTHER_TREE"
printf 'gitdir: /nowhere\n' > "$OTHER_TREE/.git"
echo '{"switches":[]}' > "$FIX/manifest.json"
printf 'helper\n' > "$FIX/installed-ndtwin-lab"
cat > "$FIX/stack.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STACK_LOG"
echo "stopped kernel"
exit 0
FAKE
chmod +x "$FIX/stack.sh"

# --- the fixtures --------------------------------------------------------------------------
TE_SIG=Traffic-engineering-App.py
OURS_ARGV="python3 /nonexistent/NDT-TEST-FIXTURE-NDT11-OURS/$TE_SIG"
THEIRS_ARGV="python3 /nonexistent/NDT-TEST-FIXTURE-NDT11-THEIRS/$TE_SIG"
FIXTURE_TTL=120
OURS=""; THEIRS=""

# spawn <argv0> <cwd> -- a process wearing that command line, in a session of its own; its pid is
# left in FIXTURE_PID.
# 🔴 setsid, and it is load-bearing twice: app_kill_group REFUSES to signal this shell's own
# group (it would take the test down with it), and a fixture sharing this shell's group would
# make the stop that IS supposed to happen degrade to the per-pid path -- a different code path
# from the one a real app takes.
#
# [Co-developed with claude code -- Adam]
# 🔴 CALLED AS A PLAIN COMMAND, NEVER AS X="$(spawn ...)" (2026-10-01). It used to be, with
# `|| { echo "Ran ..."; exit 1; }` after it: the failure was counted, but the fixture it gave up on
# was in no list the cleanup reads (OURS and THEIRS were still empty), so it outlived the run, and
# the poll gave up after 2 s. Every pid is now registered in SPAWNED_REG before the poll, so the EXIT
# trap reaps it either way; the premise is a check THIS shell counts, on success too, and a failure
# ends the run with its summary. The poll waits up to FIXTURE_ARGV_WAIT seconds: a slow exec on a
# loaded machine is not a defect in `ndt down`. Same shape as the helpers of the six suites
# tests/shell/mutate_fixture_spawn_helpers.sh covers, and that gate covers this one too.
FIXTURE_ARGV_WAIT=30
FIXTURE_PID=""
# Every pid spawn() starts, one per line. A FILE since 2026-10-01, written inside the substitution
# that starts the fixture: a signal sent to this shell while that substitution runs is handled after
# it returns, and the EXIT trap then finds the pid here. An array appended after the assignment
# could miss it. A signal to the whole process group still has a window: test_ndt_app_orphans.sh's
# spawn_fixture says which.
SPAWNED_REG="$FIX/spawned.pids"
: > "$SPAWNED_REG"
spawn() {
    # [Co-developed with claude code -- Adam] In this shell or not at all (2026-10-01): see
    # test_ndt_app_orphans.sh's spawn_fixture. A call from a subshell ends the run, loudly.
    [[ $BASHPID == "$$" ]] || { echo "  FAILED   ${FUNCNAME[0]} called outside this suite's own shell (BASHPID $BASHPID, suite $$): ending the run" >&2; kill -TERM "$$"; exit 1; }
    local want="$1" dir="$2" pid deadline
    local -a argv=()
    FIXTURE_PID=""
    # From a command substitution of its own, as before: the fixture is never a child of this
    # shell, so a stopped one is reaped at once and /proc stops showing it -- the "OURS IS GONE"
    # check below reads /proc. The redirections keep it off that substitution's pipe.
    pid="$( setsid bash -c "cd '$dir' && exec -a '$want' sleep $FIXTURE_TTL" \
            >/dev/null 2>&1 </dev/null & echo "$!" >> "$SPAWNED_REG"; echo "$!" )"
    deadline=$(( SECONDS + FIXTURE_ARGV_WAIT ))
    while :; do
        argv=()
        mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || true
        if [[ "${argv[0]:-}" == "$want" ]]; then
            check "fixture took argv0=$want" "$want" "${argv[0]}"
            FIXTURE_PID="$pid"
            return 0
        fi
        (( SECONDS < deadline )) || break
        sleep 0.1
    done
    check "fixture took argv0=$want" "$want" \
          "${argv[0]:-nothing readable} (pid $pid, after ${FIXTURE_ARGV_WAIT}s)"
    echo
    # The exit is on the summary's own line, like every other early summary in this file:
    # tests/shell/mutate_l1_shell_scoring.sh uses this suite as the one whose summaries other than
    # the last all have their exit <non-zero> on the same line.
    echo "Ran $((PASS+FAIL)) checks, $FAIL failed"; exit 1
}

# 🔴 The cleanup is an ASSERTION, not a trap nobody reads. FIX-NDT-10 SUMMARY section 8-3: that
# round could not tell "the TTL expired" from "I cleaned up", because every log line it had was
# taken BEFORE the kill. This kills by exact pid, re-reads /proc afterwards, and prints both.
# Every pid spawn() started is in SPAWNED_REG, including one it gave up on and the section-2 control.
cleanup() {
    local p
    local -a spawned=()
    [[ -f "${SPAWNED_REG:-}" ]] && mapfile -t spawned < "$SPAWNED_REG"
    for p in "${spawned[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$p/comm" 2>/dev/null)" == sleep ]] && kill -KILL "$p" 2>/dev/null
    done
    sleep 0.3
    for p in "${spawned[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        printf '### FIXTURE %s after kill: /proc/%s exists = %s\n' "$p" "$p" "$(alive "$p")"
    done
    [[ -n "${FIX:-}" && "$FIX" == "${TMPDIR:-/tmp}/ndt-down-ours-"* ]] && rm -rf "$FIX"
    return 0
}
# [Co-developed with claude code -- Adam] A signal ENDS the run (2026-10-01), as in
# test_ndt_app_orphans.sh. The handler used to clean up and return, so on INT or TERM the suite
# went on running with its fixtures reaped and $FIX deleted. The EXIT trap does the cleaning on
# the way out; INT and TERM only exit, 128+signal.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

spawn "$OURS_ARGV" "$FIX"; OURS="$FIXTURE_PID"
spawn "$THEIRS_ARGV" "$OTHER_TREE"; THEIRS="$FIXTURE_PID"

# --- the seam ------------------------------------------------------------------------------
# app_probe, app_claims_pid, proc_checkout, app_stop, app_kill_group and cmd_down itself are
# REAL. app_ps_snapshot is bounded to these two fixtures for the reason
# tests/shell/test_ndt_app_orphans.sh gives: a unit test must never be able to signal a real app
# on the machine it runs on. The identity check still reads the real /proc.
STUBS='
REPO="'"$FIX"'"
HERE="'"$FIX"'/tools/test_workflow"
LAB="'"$FIX"'/installed-ndtwin-lab"
STACK="'"$FIX"'/stack.sh"
MANIFEST="'"$FIX"'/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="'"$FIX"'/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="'"$FIX"'"
APP_NAMES="te"
export STACK_LOG="'"$FIX"'/stack.log"
sudo() { printf "sudo %s\n" "$*" >> "'"$FIX"'/sudo.log"; return 0; }
bmv2_count() { echo 0; }
mn_count() { echo 0; }
fabric_host_count() { echo 0; }
topo_session() { return 1; }
in_flight() { :; }
foreign_claim() { :; }
measuring_declared() { :; }
guard_no_live_ovs() { return 0; }
check_up_target() { UP_TARGET_PROBLEMS=(); return 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
git_lines() { :; }
ovs_bridge_count() { echo 0; }
ovs_daemon_running() { return 1; }
netem_count() { echo 0; }
port_open() { return 1; }
ndt_port_open() { return 1; }
ndt_port_listener_pids() { return 0; }
http_get_graph() { :; }
curl() { return 1; }
wait_reaped() { return 0; }
# The candidate list is a FILE, so each section says what is on the field by writing it --
# no nested quoting, and the stub itself never changes between sections.
app_ps_snapshot() { cat "'"$FIX"'/snapshot" 2>/dev/null; return 0; }
'
drive() {   # drive <shell-code> -> its output plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$STUBS
$1
echo \"RC=\$?\"" 2>&1
}
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

# =============================================================================================
section "0. the premises -- without these the run below discriminates nothing"
# =============================================================================================
check "the two fixtures are different processes"          "no" "$([[ "$OURS" == "$THEIRS" ]] && echo yes || echo no)"
check "ours is alive before the teardown"                 "yes" "$(alive "$OURS")"
check "theirs is alive before the teardown"               "yes" "$(alive "$THEIRS")"
check "🔴 both wear an app's signature (argv alone cannot tell them apart)" "yes yes" \
      "$(drive "printf '%s %s\n' \"\$(pid_is_app $OURS te && echo yes || echo no)\" \"\$(pid_is_app $THEIRS te && echo yes || echo no)\"" | head -1)"
OUT="$(drive "proc_checkout $OURS >/dev/null")"
check "  proc_checkout says ours is ours"                 "0" "$(rc_of "$OUT")"
OUT="$(drive "proc_checkout $THEIRS >/dev/null")"
check "  and theirs belongs to another tree"              "1" "$(rc_of "$OUT")"
# 🔴 Each fixture in a session of its own. Without this app_kill_group refuses to signal at all
# and the "ours was stopped" half below would be measuring the refusal, not the stop.
check "🔴 ours has a process group of its own"            "$OURS" "$(ps -o pgid= -p "$OURS" 2>/dev/null | tr -d ' ')"
check "🔴 theirs has one too"                             "$THEIRS" "$(ps -o pgid= -p "$THEIRS" 2>/dev/null | tr -d ' ')"

# =============================================================================================
section "1. 🔴 one teardown, two processes: ours is stopped, theirs is listed and left alive"
# =============================================================================================
rm -f "$FIX/.test_run/pids"/app_*.pid "$FIX/sudo.log" "$FIX/stack.log"
: > "$FIX/sudo.log"; : > "$FIX/stack.log"
printf '%s %s\n%s %s\n' "$OURS" "$OURS_ARGV" "$THEIRS" "$THEIRS_ARGV" > "$FIX/snapshot"
DOWN="$(NDT_OWNER=ndt11-test drive 'cmd_down')"
DOWN_RC="$(rc_of "$DOWN")"

has   "the apps step ran"                                 "[0/3] apps" "$DOWN"
has   "🔴 ours is named as untracked and stopped by pid"  "te is running untracked (pid $OURS) -- stopping it by pid" "$DOWN"
has   "  and the teardown says it stopped it"             "stopped te" "$DOWN"
check "🔴 OURS IS GONE"                                   "no"  "$(alive "$OURS")"
check "🔴 THEIRS IS STILL ALIVE"                          "yes" "$(alive "$THEIRS")"
has   "🔴 theirs is named in the elsewhere column"        "seen elsewhere (not this checkout): 1 process(es)" "$DOWN"
has   "  with its pid"                                    "$THEIRS" "$DOWN"
has   "  and why it was not counted"                      "nothing ties it to $FIX" "$DOWN"
has   "  and that this teardown will not stop it"         "does not stop them" "$DOWN"
hasnt "🔴 theirs was never called untracked"              "te is running untracked (pid $THEIRS)" "$DOWN"
hasnt "  and the teardown never says it could not stop it" "could NOT stop te" "$DOWN"
# It is still wearing its own command line: what survived is the fixture, not a recycled number.
check "  and theirs is still the process it was"          "yes" \
      "$(drive "pid_is_app $THEIRS te && echo yes || echo no" | head -1)"
# 🔴 The teardown went on to do the rest of its job over the foreign process: a confinement that
# turned [0/3] into an abort would pass every check above.
has   "  the teardown carried on to [1/3]"                "[1/3] kernel + proxy/Ryu" "$DOWN"
has   "  and reached the sweep"                           "[3/3] sweep" "$DOWN"
check "🔴 and a foreign process is not a refusal (rc is not 5)" "no" \
      "$([[ "$DOWN_RC" == 5 ]] && echo yes || echo no)"

# =============================================================================================
section "2. the control -- with ONLY the foreign process on the field, nothing is stopped"
# =============================================================================================
# FIX-NDT-10's green-2 is this case and only this case. Kept as the control: a [0/3] that had
# stopped reaching apps altogether would pass it, which is why section 1 above is the finding.
spawn "$THEIRS_ARGV" "$OTHER_TREE"; THEIRS2="$FIXTURE_PID"
printf '%s %s\n' "$THEIRS2" "$THEIRS_ARGV" > "$FIX/snapshot"
OUT="$(NDT_OWNER=ndt11-test drive 'cmd_down')"
check "🔴 the other tree's process survives a teardown"   "yes" "$(alive "$THEIRS2")"
hasnt "  and nothing claims to have stopped te"           "stopped te" "$OUT"
has   "  it is listed instead"                            "seen elsewhere (not this checkout)" "$OUT"
kill -KILL "$THEIRS2" 2>/dev/null
sleep 0.2
printf '### CONTROL FIXTURE %s after kill: /proc/%s exists = %s\n' "$THEIRS2" "$THEIRS2" "$(alive "$THEIRS2")"

# =============================================================================================
section "3. the other control -- a clean field is not a teardown that stopped something"
# =============================================================================================
: > "$FIX/snapshot"
OUT="$(NDT_OWNER=ndt11-test drive 'cmd_down')"
hasnt "nothing is stopped when nothing is running"        "stopped te" "$OUT"
hasnt "  and no elsewhere column is printed"              "seen elsewhere (not this checkout)" "$OUT"
has   "  the teardown still ran"                          "[1/3] kernel + proxy/Ryu" "$OUT"

printf '\n'
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
