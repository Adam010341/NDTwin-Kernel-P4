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

m=$(mutant m3 "$NDT" \
    '    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        et="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '\'' '\'')"
        [[ "$et" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$best" ]] || (( et > best )); then best="$et"; fi
    done < <(app_scan_pids "$name")
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
report "M8: the stop reports after it has deleted the window" "$m" \
       "🔴 and the residue report has a window for it"

m=$(mutant m9 "$NDT" \
    '        started="${RESIDUE_WINDOW[$a]:-}"' \
    '        started=""')
report "M9: the captured window is never read" "$m" \
       "🔴 and the residue report has a window for it"

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

# --- the control -------------------------------------------------------------------------------
# A comment-only edit must NOT turn the suite red. If it does, this gate is measuring "the file
# changed" rather than "the behaviour changed" and every catch above is uninterpretable.
m=$(mutant m16 "$NDT" \
    '# app_evidence_log <name> -- the file that answers "did this app ever run HERE", or rc 1 when' \
    '# app_evidence_log <name> -- the file that answers "did this app ever run HERE" (x), or rc 1 when')
control "M16: a comment-only edit" "$m"

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
