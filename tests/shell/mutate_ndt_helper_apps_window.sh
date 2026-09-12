#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_helper_apps_window.sh (3-51, KNOWN-ISSUES G-14).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one piece of what lw16pw measured on 2026-09-07 -- `ndt apps stop sim`
# answering "no pidfile and no live process -- no window, so no rule can be dated", tally all
# zeros, about a sim it had just stopped -- and must turn its NAMED case red. "Something failed"
# is not a verdict: a mutation caught by a case that belongs to different behaviour says nothing
# about the case that was supposed to own it.
#
# 🔴 TWO DIRECTIONS. The mutations marked (widening) are the fixes that look like fixes and are
# not: counting "nobody can ask" as a failure, which makes `ndt status --check` red on every
# machine forever; and writing the pidfile from the lab's rc instead of from a verified pid,
# which is the C26 defect ("ok sim started" for a program that was already gone) moved out of a
# message and into a file.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the suite is
# pointed at them with NDT_UNDER_TEST. tools/test_workflow/ndt is never written -- another
# session may be executing it -- and the sha256 line at the bottom says so.
#
# 🔴 A mutant directory carries ports.sh, sudo_surface.sh and components.env: ndt sources all
# three from beside itself, so a copy without them exits at source time and every case goes red
# for the wrong reason.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG case going red counts as
# SURVIVOR -- never as skipped.
#
# 🔴 Touches no lab: the suite replaces `sudo`, `lab_session` and `app_ps_snapshot`, and
# redirects LAB_CONF into a temp dir, so nothing here reaches ndtwin-lab, reads /etc or needs
# root.
#
# Exit: 0 every mutation caught and the control survived, 1 a mutation survived (or the control
#       went red), 2 refused (baseline red / harness), 3 the file under test changed while the
#       gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
SH_TEST="$HERE/test_ndt_helper_apps_window.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/helper-window-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$SH_TEST" ]] || { echo "🔴 missing $NDT or $SH_TEST" >&2; exit 2; }

SURVIVORS=0
MUTATIONS=0

run_sh() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$SH_TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

control() {   # $1 = name, $2 = mutant dir -- must NOT turn the suite red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  survived %-58s (control, as required)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 CONTROL WENT RED %-47s\n' "$1"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_sh "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- E-8 point 1: the pidfile the helper never writes ------------------------------------------

# The defect itself. `sudo ndtwin-lab sim-start` starts the program as root in tmux and nothing
# records the pid, so app_started_at has nothing to read for the rest of the app's life.
m=$(mutant m1 "$NDT" \
    '            echo "${APP_LIVE_PIDS[0]}" >"$pid_dir/app_$name.pid"' \
    '            :')
report "M1: the helper apps get no pidfile (the measured defect)" "$m" \
       "🔴 the pidfile now exists"

# (widening) The pidfile is written from the REQUEST rather than from a verified pid -- before
# app_wait_started has looked. That is C26 ("ok sim started" for a program already gone) moved
# out of a message and into a file that everything downstream believes.
m=$(mutant m2 "$NDT" \
    '            app_wait_started "$name" || return 1' \
    '            echo "${APP_LIVE_PIDS[0]:-0}" >"$pid_dir/app_$name.pid"
            app_wait_started "$name" || return 1')
report "M2 (widening): the pidfile records the request, not the program" "$m" \
       "🔴 and writes NO pidfile"

# --- E-8 point 2: a running app with no pidfile has no window ----------------------------------

# 🔴 2026-09-12 (FIX-NDT-10, C10-8): the anchor below moved with the code. app_started_at used
# to read the machine-wide scan directly; it now goes through app_scan_here, which drops the pids
# that belong to ANOTHER checkout on this machine before they can date a window. The mutation is
# the same one -- delete the scan half and leave app_started_at reading the pidfile alone.
m=$(mutant m3 "$NDT" \
    '    app_scan_here "$name"
    for pid in ${APP_SCAN_HERE[@]+"${APP_SCAN_HERE[@]}"}; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        et="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '\'' '\'')"
        [[ "$et" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$best" ]] || (( et > best )); then best="$et"; fi
    done
    [[ -n "$best" ]] && { echo "$(( $(date +%s) - best ))"; return 0; }' \
    '    :')
report "M3: app_started_at asks the pidfile and nothing else" "$m" \
       "🔴 a live process with no pidfile still has a window"

# The window opens at whichever pid `ps` happened to list first. sim matches twice on a logging
# run and a child is younger than its parent, so this reports "no flow entry arrived during that
# window" -- a clean answer, from looking at the wrong hour.
m=$(mutant m4 "$NDT" \
    '        if [[ -z "$best" ]] || (( et > best )); then best="$et"; fi' \
    '        best="$et"; break')
report "M4: the window opens at the youngest process, not the oldest" "$m" \
       "🔴 with two live pids the window opens at the OLDER one"

# --- E-8 point 3: which log answers "did it ever run HERE" -------------------------------------

# The measured shape: the discriminator reads OUR tree while root wrote the log in the helper's,
# so in a worktree it always says "no sign it ever ran here".
m=$(mutant m5 "$NDT" \
    '        sim)    printf '\''%s/.test_run/logs/app_sim.log'\'' "$(lab_kernel_dir)" ;;' \
    '        sim)    app_logfile sim ;;')
report "M5: sim's log is looked for in this checkout" "$m" \
       "🔴 sim's log is the helper's, not ours"

# (widening) energy is given a log path it has never had, so the absent file is read as evidence
# and "no sign it ever ran here" is printed about a channel that does not exist.
m=$(mutant m6 "$NDT" \
    '        energy) return 1 ;;' \
    '        energy) app_logfile energy ;;')
report "M6 (widening): energy is given a log it does not have" "$m" \
       "🔴 it says the question cannot be asked"

# --- E-8 point 4: the sentence that was printed about a running app ----------------------------

m=$(mutant m7 "$NDT" \
    '            if (( ${#live[@]} > 0 )); then
                warn "  $a: running as pid(s) ${live[*]} but no pidfile, and its start time"' \
    '            if false; then
                warn "  $a: running as pid(s) ${live[*]} but no pidfile, and its start time"')
report "M7: 'no live process' is printed without looking for one" "$m" \
       "🔴 it does NOT say 'no pidfile and no live process' about a running app"

# --- the window a stop destroys before it reports on it ----------------------------------------

m=$(mutant m8 "$NDT" \
    '                awin="$(app_started_at "$a")" && [[ -n "$awin" ]] && RESIDUE_WINDOW["$a"]="$awin"' \
    '                :')
# 🔴 RE-ANCHORED 2026-09-11 (FIX-NDT-4, F3). The case this used to name is now ALSO answered by
# the window F3 writes to disk, so both these mutations went green over it -- the gate saying, in
# its own way, that the two mechanisms had merged. The case they name now is the one only the
# pre-loop capture can answer: a stop that found nothing running discards the pidfile and writes
# no record, because a record is what a VERIFIED stop leaves. See section 9B of the suite.
report "M8: the stop reports after it has deleted the window" "$m" \
       "🔴 and the residue report still has a window for it"

m=$(mutant m9 "$NDT" \
    '        started="${RESIDUE_WINDOW[$a]:-}"' \
    '        started=""')
report "M9: the captured window is never read" "$m" \
       "🔴 and the residue report still has a window for it"

# ...and the other direction: a window with a start and no end, kept forever. Every later
# `--check` windows from a sim that stopped yesterday to now and calls the fabric's own baseline
# residue -- a verb that is red forever is read as often as one that is green forever.
# 2026-09-07 (lw351 follow-up): re-anchored to the one line that does the work. The `(was: ...)`
# line below it changed in the same commit, and an anchor that spans a neighbour breaks whenever
# the neighbour is edited -- which is how mutate_g6_apps_liveness.sh lost this same case.
m=$(mutant m10 "$NDT" \
    '            rm -f "$(app_pidfile "$name")"' \
    '            :')
report "M10 (widening): a verified stop leaves the window open forever" "$m" \
       "🔴 and the pidfile is gone afterwards, so the window closes"

# --- E-7: "could not ask" is not red, and is not invisible either ------------------------------

# (widening) energy has no log channel on ANY machine, so folding it into the verdict makes
# `ndt status --check` red on every lab forever, for a fact about the helper nobody can act on.
m=$(mutant m11 "$NDT" \
    '    (( RESIDUE_UNDATABLE > 0 || RESIDUE_BLIND > 0 )) && return 5' \
    '    (( RESIDUE_UNDATABLE > 0 || RESIDUE_BLIND > 0 || RESIDUE_UNKNOWABLE > 0 )) && return 5')
report "M11 (widening): 'nobody can ask' is counted as a failure" "$m" \
       "🔴 and it is NOT red (nobody can act on it) -- rc 0"

# The opposite: not red AND not printed, so the row reads "none ... (asked, not assumed)" on a
# lab where two of the five apps were never asked anything.
m=$(mutant m12 "$NDT" \
    '    if (( RESIDUE_UNKNOWABLE > 0 )); then
        printf '\''  %-14s %s\n'\'' "" "${Y}$RESIDUE_UNKNOWABLE app(s) could not be asked whether they ran here: $RESIDUE_UNKNOWABLE_APPS${N}"' \
    '    if false; then
        printf '\''  %-14s %s\n'\'' "" "${Y}$RESIDUE_UNKNOWABLE app(s) could not be asked whether they ran here: $RESIDUE_UNKNOWABLE_APPS${N}"')
report "M12: --check goes back to 'asked, not assumed' over it" "$m" \
       "🔴 the --check row says an app could not be asked"

# --- the copied rule: a config `ndt` trusts and the helper does not -----------------------------

m=$(mutant m13 "$NDT" \
    '    lab_conf_path_trusted "$(dirname "$conf")" || return 1
    # A symlink is refused rather than followed: stat would describe the LINK, so checking it
    # says nothing about what would be read.
    [[ -L "$conf" ]] && return 1
    [[ -f "$conf" ]] || return 1
    lab_conf_path_trusted "$conf" || return 1' \
    '    [[ -e "$conf" ]] || return 1')
report "M13: any readable config file is trusted" "$m" \
       "🔴 a config this user owns is REFUSED (it is not root's)"

# The helper refuses a file with an unknown key OUTRIGHT and keeps its defaults. A parser that
# skips the line adopts a KERNEL_DIR that is not in force on the other side of the sudoers rule.
m=$(mutant m14 "$NDT" \
    '        case "$key" in
            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR) ;;
            *) return 1 ;;
        esac' \
    '        case "$key" in
            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR) ;;
            *) continue ;;
        esac')
report "M14: an unknown key is skipped instead of refusing the file" "$m" \
       "🔴 an unknown key sets NOTHING (the helper refuses the whole file)"

# The copy drifts from the original -- the one failure a copied rule is guaranteed to have
# eventually, and the only thing that can see it happen.
m=$(mutant m15 "$NDT" \
    'LAB_DEFAULT_KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel' \
    'LAB_DEFAULT_KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel-worktree')
report "M15: ndt's default drifts from the helper's" "$m" \
       "🔴 ndt's default KERNEL_DIR is the helper's default"

# --- lw351: three verbs, one app, one answer ---------------------------------------------------

# The measured defect. app_survivors answers "which processes do these channels find"; without
# the subtraction that becomes "which processes is nobody tracking", and `apps orphans` reported
# the contents of the pidfile -- verified alive by app_probe in the same run -- as an orphan.
m=$(mutant m17 "$NDT" \
    '        unnamed=()
        for s in ${APP_SURVIVORS[@]+"${APP_SURVIVORS[@]}"}; do
            spid="${s%% *}"; known=0
            for lp in ${APP_LIVE_PIDS[@]+"${APP_LIVE_PIDS[@]}"}; do
                [[ "$lp" == "$spid" ]] && { known=1; break; }
            done
            (( known == 0 )) && unnamed+=("$s")
        done' \
    '        unnamed=( ${APP_SURVIVORS[@]+"${APP_SURVIVORS[@]}"} )')
report "M17: orphans reports pids the probe already accounted for" "$m" \
       "🔴 a tracked, running sim is NOT an orphan -- rc 0"

# (widening) The other direction, and it is FINDING #48 itself: subtract everything and the verb
# goes green over the 09-02 viz JVMs -- processes no channel names, which is what it exists for.
m=$(mutant m18 "$NDT" \
    '            (( known == 0 )) && unnamed+=("$s")' \
    '            :')
report "M18 (widening): orphans reports nothing at all" "$m" \
       "🔴 control: untracked children still exit 1"

# `(was: ...)` is a claim about the state BEFORE the stop, and app_wait_stopped overwrites
# APP_STATE with the state after it. Live, that printed "was: not-running" about a sim whose own
# log shows it taking SIGINT a second later.
m=$(mutant m19 "$NDT" \
    '            ok "$name stopped (was: $was)" ;;' \
    '            ok "$name stopped (was: $APP_STATE)" ;;')
report "M19: the stop reports the state it produced, not the one it found" "$m" \
       "🔴 it says what the app WAS: running"

# --- 3-51c: read, truncate, and look inside are three permissions -------------------------------
#
# Each of these puts back one half of "the tool asked whether it could READ the log and answered
# whether it could TRUNCATE it", or one half of "the fd channel found nothing" standing in for
# "the fd channel was not allowed to look".

# The measured shape: `apps trim` on a root-owned log wrote the tail, had its truncate refused,
# and printed a failure that named neither the owner nor the one command that fixes it.
m=$(mutant m20 "$NDT" \
    '        if ! why="$(app_log_blocked_reason "$log")"; then' \
    '        if false; then')
report "M20: trim finds out it cannot truncate by trying it" "$m" \
       "🔴 trim names the owner and the remedy"

# (widening) The opposite, and it is the one that would make `ndt apps trim` useless: refuse
# every log, including the ordinary ones this user writes and owns. A guard that never lets the
# work happen is not a safer version of the work.
m=$(mutant m21 "$NDT" \
    '    if [[ ! -w "$p" ]]; then' \
    '    if true; then')
report "M21 (widening): trim refuses a log it can truncate" "$m" \
       "🔴 control: a log this user CAN truncate is still trimmed -- rc 0"

# (widening) Every permission problem blamed on root, so the remedy printed is `sudo` for a file
# whose owner is sitting at the keyboard. "Could not write it" and "somebody else owns it" are
# two facts and only the second one calls for the operator.
m=$(mutant m22 "$NDT" \
    '        if [[ "$u" == 0 ]]; then' \
    '        if true; then')
report "M22 (widening): every unwritable log is called root's" "$m" \
       "🔴 but it is NOT blamed on root"

# `apps status` goes back to printing a size and a verb, with nothing saying the verb cannot run.
m=$(mutant m23 "$NDT" \
    '            if [[ ! -w "$log" ]] && [[ "$(app_log_owner "$log")" == 0 ]]; then' \
    '            if false; then')
report "M23: the status row stops saying whose log it is" "$m" \
       "🔴 apps status says the log is root's"

# The third channel's blindness is dropped on the floor, which is exactly the state it was in:
# `find` returns nothing for a root process's fd directory and nothing is what it returns when
# no process holds the log.
m=$(mutant m24 "$NDT" \
    '    out="$(app_fd_blindness)" &&
        APP_SURVIVOR_BLIND="${APP_SURVIVOR_BLIND:+$APP_SURVIVOR_BLIND; }$out"' \
    '    :')
report "M24: an fd channel that could not look reports as one that found nothing" "$m" \
       "🔴 app_survivors keeps it as blindness, not as an empty channel"

# (widening) ...and the other direction: call every process unreadable. A verb that reports
# blindness about processes it can see perfectly well is a verb whose blindness line stops
# being read, which is how the real one would be missed.
m=$(mutant m25 "$NDT" \
    'app_fd_readable() { [[ -r "/proc/$1/fd" ]]; }' \
    'app_fd_readable() { false; }')
report "M25 (widening): the fd channel calls every process unreadable" "$m" \
       "🔴 control: no blindness is invented for a process we can look inside"

# The blindness is kept when the verb found nothing and dropped when it found something -- i.e.
# it disappears exactly when there is a number on the screen for a reader to take as a count.
m=$(mutant m26 "$NDT" \
    '    [[ -n "$blind" ]] &&
        warn "and a channel was blind, so this is a floor and not a count: $blind"' \
    '    :')
report "M26: orphans drops the blindness once it has found something" "$m" \
       "🔴 and prints the blindness instead of dropping it once it found something"

# --- F3: the window a stop leaves on disk, and its right edge ----------------------------------
#
# Each of these puts back one half of "the stop could date the app it had just stopped, and
# nothing after it could" (FIX-NDT-2 SUMMARY §7-2), or one half of the fix's own hazard: a
# recorded window with no end attributes every rule installed since to an app that has stopped.

m=$(mutant m28 "$NDT" \
    '            app_window_record "$name" "$wstart" || true' \
    '            :')
report "M28: the stop deletes the pidfile and records no window" "$m" \
       "🔴 the stop left a window record on disk"

m=$(mutant m29 "$NDT" \
    '        if [[ -z "$started" ]] && wrec="$(app_window_read "$a")"; then' \
    '        if false; then')
report "M29: the recorded window is never read back" "$m" \
       "🔴 a later process still has a window for sim"

# (widening) The record is read and its END is thrown away, so every later --check windows from
# an app that stopped yesterday to now and calls the fabric's own baseline residue. That is M10
# with a file behind it -- a verb that is red forever is read as often as one that is green
# forever.
m=$(mutant m30 "$NDT" \
    '                if now - dur > stop:' \
    '                if False:')
report "M30 (widening): the closed window has no right edge" "$m" \
       "🔴 a rule installed AFTER it closed is NOT this app's"

# ...and the same widening one layer up, in the shell: the bound is computed and not passed.
m=$(mutant m31 "$NDT" \
    '            started="${wrec%% *}"; wend="${wrec##* }"' \
    '            started="${wrec%% *}"; wend=""')
report "M31 (widening): the window end never leaves the reader" "$m" \
       "🔴 and reports it as closed, not open to now"

# Nobody clears it, so a running app has a closed window from its own previous life sitting
# beside it -- two answers to "when did this app run", which is the shape 3-51 is about.
m=$(mutant m32 "$NDT" \
    '    rm -f "$(app_windowfile "$name")"' \
    '    :')
report "M32: a start does not supersede the last stop's window" "$m" \
       "🔴 and it cleared the window its last stop left"

# --- RESIDUE-1: the right edge of the window a dead pidfile opens (Adam, 2026-09-12 12:3x) -----
#
# The measured defect: `app_viz.pid` was written 2026-09-11 14:04:25, viz exited by itself at
# 14:05:43, nothing removed the pidfile, and twelve hours later `ndt status --check` over a
# brand-new OVS fabric reported that fabric's own 60 forwarding rules as residue, rc 1.

# The defect itself: the seal is never asked, so the window runs to now again.
m=$(mutant m33 "$NDT" \
    '        if [[ -n "$started" ]] && wseal="$(app_window_seal "$a")"; then' \
    '        if false; then')
report "M33: a dead pidfile's window runs to now again (the measured defect)" "$m" \
       "🔴 the window has a right edge"

# (widening) The seal fires for a LIVE process too, so an app installing rules this second is
# reported as having had nothing arrive. Sealing everything passes every case M33 owns.
m=$(mutant m34 "$NDT" \
    '    if pid="$(app_pidfile_pid "$name" 2>/dev/null)" && [[ -n "$pid" ]]; then return 1; fi' \
    '    if false; then return 1; fi')
report "M34 (widening): a running app's window is sealed too" "$m" \
       "🔴 control: a LIVE pid still windows to now"

# (widening) Every dead app is sealed to a ZERO-length window -- the edge is taken from the
# pidfile even when the log can date it. "Attribute nothing, ever" also passes M33.
m=$(mutant m35 "$NDT" \
    '            echo "$lm pid gone; app log mtime"' \
    '            echo "$et pid gone; app log mtime"')
report "M35 (widening): the edge is the pidfile's mtime, never the log's" "$m" \
       "🔴 control: a rule installed INSIDE the closed window is still listed"

# The line says the window is closed and the rule filter is still given an open one: the report
# reads right and the number under it is the old one. A verdict and its evidence, disagreeing.
m=$(mutant m36 "$NDT" \
    '            wend="${wseal%% *}"; wwhy="${wseal#* }"' \
    '            wend=""; wwhy="${wseal#* }"')
report "M36: the sealed edge is printed but never applied" "$m" \
       "🔴 a rule installed after the app exited is not framed by it"

# An app with no log at all gets no seal, so energy -- the one app the lab helper gives no log
# channel -- goes back to windowing the whole table.
m=$(mutant m37 "$NDT" \
    '    echo "$et pid gone; nothing later than the pidfile to date the end -- zero-length window"' \
    '    return 1')
report "M37: no log -> no seal, so the window is open again" "$m" \
       "🔴 no log -> the window has no extent, and the report says so"

# (widening) The end is taken from a log OLDER than the pidfile, so the window is negative: it
# excludes every rule there is, which looks exactly like a clean answer.
m=$(mutant m38 "$NDT" \
    '        if [[ "$lm" =~ ^[0-9]+$ ]] && (( lm >= et )); then' \
    '        if [[ "$lm" =~ ^[0-9]+$ ]]; then')
report "M38 (widening): an end before the start is accepted" "$m" \
       "🔴 a log older than the pidfile does not invert the window"

# --- the control -------------------------------------------------------------------------------
# A comment-only edit must NOT turn the suite red. If it does, this gate is measuring "the file
# changed" rather than "the behaviour changed" and every catch above is uninterpretable.
m=$(mutant m16 "$NDT" \
    '# app_evidence_log <name> -- the file that answers "did this app ever run HERE", or rc 1 when' \
    '# app_evidence_log <name> -- the file that answers "did this app ever run HERE" (x), or rc 1 when')
control "M16: a comment-only edit" "$m"

# The same control inside the 3-51c block, because that is where the newest cases are: a case
# that goes red for a reworded comment is reading the file rather than the tool.
m=$(mutant m27 "$NDT" \
    '# app_log_blocked_reason <path> -- rc 0 and nothing when this process could truncate that log;' \
    '# app_log_blocked_reason <path> (x) -- rc 0 and nothing when this process could truncate that log;')
control "M27: a comment-only edit in the 3-51c block" "$m"

echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
