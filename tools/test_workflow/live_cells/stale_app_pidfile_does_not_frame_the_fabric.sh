#!/usr/bin/env bash
#
# CELL stale_app_pidfile_does_not_frame_the_fabric -- RESIDUE-1. A pidfile nobody removed opened
# an app window with no right edge, and the fabric's OWN forwarding rules were reported as that
# app's residue.
#
# [Co-developed with claude code -- Adam]
#
# Source: hunt-0911/RESIDUE-1-REPORT.md (2026-09-12, read-only investigation) §1 §2 §6.
#   09-11 14:04:25  .test_run/pids/app_viz.pid written; the viz exited on its own at 14:05:43,
#                   so `ndt apps stop` -- the ONLY path that removes a pidfile -- never ran
#   09-12 02:20:23  ROLE-11 `ndt up ovs4`: switches=10 links=32 paths=installed, 8 s
#   09-12 02:20:45  `ndt status --check`: `residue 60 rule(s) inside an app window, 0 lock(s)
#                   HELD` -> `check: 1 problem(s)` -> RC=1   (logs/ROLE-11/05-check-after-up.log)
# The 60 were installed by that bring-up, 17 seconds earlier, on switches that did not exist
# before it. residue_report says so itself: "anything installed in that window is listed,
# whoever installed it". app_started_at dates a dead pidfile by the pidfile's own mtime and
# residue_report then never asks app_window_read, so `wend` stays empty and the window runs to
# `now` -- 12.3 hours wide, wider than the fabric it was measuring.
#
# 🔴 WHAT THIS CELL ASSERTS IS NOT "residue is 0". It is: a window opened by a pidfile whose
# process is dead must not reach forward over a bring-up that happened later. The count is how
# that is read, and the count is taken from `ndt`'s own tally line rather than recomputed here.
#
# 🔴 THE CELL PLANTS ITS OWN STALE PIDFILE, for `te`, and removes it again. Three reasons:
#   1. a cell must survive the cleanup of the 09-11 crime scene. Adam's ruling is 先格後清 --
#      the cell first, then app_viz.pid is removed -- and a cell that only reddens while that
#      one file exists would go green for the wrong reason the day it is deleted.
#   2. the premise becomes measurable: this cell records the pidfile's mtime and the second the
#      bring-up started, so `the window opened before the fabric existed` is a reading and not
#      a story about last night.
#   3. app_viz.pid is not touched, read-only stat aside. Removing it is the orchestrator's,
#      recorded in the ledger.
# A planted pidfile names a pid that is DEAD and that /proc does not know, so app_pidfile_pid's
# `pid_is_app` check refuses it (rc 4) exactly as it refuses the real stale one -- which is the
# point: the second source, the mtime, is the one under test.
#
# 🔴 What would make this cell lie, and is therefore checked before it runs: a `te` that really
# ran in the last ten minutes (its window would legitimately cover the bring-up), and a pidfile
# that is already there (somebody else's -- never overwritten, the cell SKIPs).
#
# This cell brings the fabric up and LEAVES IT UP: run_cells.sh takes it down between cells.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

# The app whose window is staged. `te` and not `viz`: viz's pidfile is the live crime scene and
# this cell may not write it, and te is in APP_NAMES, has no pidfile on this machine, and its
# evidence log has not been written since 2026-09-05.
STALE_APP=te
STALE_PIDFILE=""

# The rule this cell installs to have something datable on the wire. 10.99.99.99 is not a host on
# the 4-host model, and the priority is the lowest there is, so nothing on this fabric can match
# it and nothing it shadows changes. Deleted again at the end of `observe`.
CELL_RULE='{"dpid":1,"priority":1,"match":{"eth_type":2048,"ipv4_dst":"10.99.99.99"},"actions":[{"type":"OUTPUT","port":1}]}'

_stale_unplant() {
    [[ -n "$STALE_PIDFILE" && -f "$STALE_PIDFILE" ]] || return 0
    rm -f "$STALE_PIDFILE"
}

# _dead_pid -- a pid number /proc does not know. Counting DOWN from pid_max, because the numbers
# near the top are the last the kernel will hand out and so the least likely to be recycled into
# a stranger between the plant and the read.
_dead_pid() {
    local max p
    max="$(cat /proc/sys/kernel/pid_max 2>/dev/null)"
    [[ "$max" =~ ^[0-9]+$ ]] || max=32768
    for (( p = max - 1; p > max - 200; p-- )); do
        (( p > 1 )) || break
        [[ -d "/proc/$p" ]] || { echo "$p"; return 0; }
    done
    return 1
}

cell_observe() {
    local d="$1" pid logf logmt plantmt now t0 t1 entries i
    cell_write_ids "$d"
    STALE_PIDFILE="$NDT_ROOT/.test_run/pids/app_$STALE_APP.pid"
    trap _stale_unplant EXIT
    now="$(date +%s)"

    if [[ -e "$STALE_PIDFILE" ]]; then
        cell_skip "$d" "$STALE_PIDFILE already exists -- it is somebody else's and this cell never overwrites a pidfile"
        return 0
    fi
    logf="$NDT_ROOT/.test_run/logs/app_$STALE_APP.log"
    logmt=""
    if [[ -e "$logf" ]]; then
        logmt="$(stat -c %Y "$logf" 2>/dev/null)"
        if [[ "$logmt" =~ ^[0-9]+$ ]] && (( logmt > now - 600 )); then
            cell_skip "$d" "$logf was written $(( now - logmt ))s ago -- $STALE_APP may really have run just now, and a live window that covers the bring-up is not the defect this cell is about"
            return 0
        fi
    fi
    if ! pid="$(_dead_pid)"; then
        cell_skip "$d" "could not find a pid number /proc does not know -- no dead pid to name"
        return 0
    fi

    # The plant. mtime BEFORE the app's own log, so that a right edge taken from either the log
    # or the pidfile lands before the bring-up; and the recorded numbers are what the judge
    # reads, so the premise is a measurement.
    printf '%s\n' "$pid" > "$STALE_PIDFILE"
    if [[ "$logmt" =~ ^[0-9]+$ ]]; then plantmt=$(( logmt - 60 )); else plantmt=$(( now - 3600 )); fi
    touch -d "@$plantmt" "$STALE_PIDFILE"
    { printf 'app=%s\n' "$STALE_APP"
      printf 'pidfile=%s\n' "$STALE_PIDFILE"
      printf 'pid=%s\n' "$pid"
      printf 'pid_alive=%s\n' "$([[ -d "/proc/$pid" ]] && echo yes || echo no)"
      printf 'pidfile_mtime=%s\n' "$(stat -c %Y "$STALE_PIDFILE" 2>/dev/null)"
      printf 'applog=%s\n' "$logf"
      printf 'applog_mtime=%s\n' "${logmt:-none}"
    } > "$d/plant.txt"
    # The 09-11 crime scene, read-only and never written: stat only, so a reader of this raw can
    # see whether the original stale pidfile was still there when the cell ran.
    { printf 'viz_pidfile=%s\n' "$NDT_ROOT/.test_run/pids/app_viz.pid"
      printf 'viz_pidfile_mtime=%s\n' "$(stat -c %Y "$NDT_ROOT/.test_run/pids/app_viz.pid" 2>/dev/null || echo absent)"
    } > "$d/viz_scene.txt"

    t0="$(date +%s)"; printf '%s\n' "$t0" > "$d/up.start"
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 420 bash "$NDT_ROOT/tools/test_workflow/ndt" up ovs 4 > "$d/up.log" 2>&1
    printf '%s\n' "$?" > "$d/up.rc"
    t1="$(date +%s)"; printf '%s\n' "$t1" > "$d/up.end"

    # 🔴 THE CELL PUTS A DATED RULE ON THE WIRE ITSELF, and measured 2026-09-12 15:00 is why.
    # The first live run of this cell read the kernel's flow table straight after a converged
    # `ndt up ovs 4` -- `paths=installed`, `h1 -> 10.0.0.2 forwards`, sFlow sampling -- and got
    # `[]`. Every assertion below then passed for the wrong reason: a window that frames nothing
    # is what an EMPTY TABLE gives you too, whatever the window's right edge is. RESIDUE-1's 60
    # were read 22 s after ROLE-11's bring-up and are not reproducible on demand.
    # So the premise is manufactured: one rule, installed through the northbound API, matching an
    # address no host on this fabric has, and deleted again below. Its install time is now, which
    # is inside the stale window and outside every honestly-closed one -- which is the whole of
    # what this cell is about.
    printf '%s' "$(curl -sf --max-time 10 \
        http://localhost:8000/ndt/get_switch_openflow_table_entries 2>/dev/null)" \
        > "$d/flow_entries.before.json"
    # Ryu's own answer beside the kernel's, so an empty table can be told from a kernel that
    # will not report one. Unprivileged: :8080 is Ryu's REST, no sudo and no ovs-ofctl.
    curl -sf --max-time 10 http://localhost:8080/stats/flow/1 > "$d/ryu_flow_1.json" 2>/dev/null || true
    curl -s -o "$d/install.body" -w '%{http_code}\n' \
        -X POST http://localhost:8000/ndt/install_flow_entry -d "$CELL_RULE" \
        > "$d/install.code" 2>> "$d/curl.err"
    for i in $(seq 1 12); do
        entries="$(curl -sf --max-time 10 \
            http://localhost:8000/ndt/get_switch_openflow_table_entries 2>/dev/null)"
        printf '%s' "$entries" > "$d/flow_entries.json"
        printf '%s\n' "$(grep -o '"priority"' <<<"$entries" | grep -c .)" > "$d/flow_entries.count"
        printf 'sample %s at %s: %s entrie(s)\n' "$i" "$(date +%s)" \
            "$(cat "$d/flow_entries.count")" >> "$d/flow_poll.log"
        [[ "$(cat "$d/flow_entries.count")" != 0 ]] && break
        sleep 5
    done

    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 180 bash "$NDT_ROOT/tools/test_workflow/ndt" apps orphans > "$d/orphans.txt" 2>&1
    printf '%s\n' "$?" > "$d/orphans.rc"
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 180 bash "$NDT_ROOT/tools/test_workflow/ndt" status --check > "$d/check.log" 2>&1
    printf '%s\n' "$?" > "$d/check.rc"

    # Take the rule back off the wire. The fabric is destroyed by run_cells.sh's restore a minute
    # later, so a failed delete costs nothing that survives -- but a cell that left it to the
    # teardown would be leaving its own mess for the next reader of `apps orphans` to find.
    curl -s -o "$d/delete.body" -w '%{http_code}\n' \
        -X POST http://localhost:8000/ndt/delete_flow_entry -d "$CELL_RULE" \
        > "$d/delete.code" 2>> "$d/curl.err"
    printf '%s' "$(curl -sf --max-time 10 \
        http://localhost:8000/ndt/get_switch_openflow_table_entries 2>/dev/null)" \
        > "$d/flow_entries.after.json"
    printf '%s\n' "$(grep -o '"priority"' < "$d/flow_entries.after.json" | grep -c .)" \
        > "$d/flow_entries.after.count"

    _stale_unplant
    printf 'removed=%s\nstill_there=%s\n' "$STALE_PIDFILE" \
        "$([[ -e "$STALE_PIDFILE" ]] && echo yes || echo no)" > "$d/plant.cleanup"
}

cell_judge() {
    local d="$1"
    local app shape listed frames pmt ustart n line nxt nprob crc untr apps_row
    app="$(rawfield "$d" plant.txt app)"; app="${app:-te}"
    line="$(grep -m1 -E "^  $app +window " "$d/orphans.txt" 2>/dev/null)"
    nxt="$(grep -A1 -m1 -E "^  $app +window " "$d/orphans.txt" 2>/dev/null | tail -1)"
    # 🔴 THE APP'S OWN BLOCK, not the whole report. residue_report prints one block per app and a
    # tally that SUMS them, and on this machine a second app can have a window that is legitimately
    # open -- a sim running with no pidfile is dated by app_started_at's third source and really
    # does run to now. A judge that read the tally would call that a regression of this fix.
    # 🔴 The block ENDS at the next app's window line or at the blank line before the closing
    # section -- not at "the next line that starts with two spaces and a letter". Every rule line
    # inside the block is `  XX        rule  dpid=...` (err() prefixes `  XX  `), which starts
    # exactly that way, so the first draft of this awk closed the block on the first rule it was
    # supposed to count and reported 0 over a block with 61 rules in it. Measured live
    # 2026-09-12 15:04, on the run this cell's own old/ fixture came out of.
    listed="$(awk -v a="$app" '
        $0 ~ "^  " a " +window "                                     { inblock = 1; next }
        inblock && ($0 ~ /^  [a-z]+ +window / || $0 ~ /^[[:space:]]*$/) { inblock = 0 }
        inblock && ($0 ~ /rule\(s\) listed:/ || $0 ~ /rule  dpid=/)  { n++ }
        END { print n + 0 }' "$d/orphans.txt" 2>/dev/null)"
    a_have  stale_plant_recorded                      "$d/plant.txt"
    a_have  stale_orphans_report_present              "$d/orphans.txt"
    a_have  stale_check_present                       "$d/check.log"

    # --- the premises. None of these is the finding; all of them have to hold for the finding
    # to mean anything, and each is a reading this cell took rather than a claim about last night.
    pmt="$(rawfield "$d" plant.txt pidfile_mtime)"
    ustart="$(cat "$d/up.start" 2>/dev/null)"
    if [[ "$pmt" =~ ^[0-9]+$ && "$ustart" =~ ^[0-9]+$ ]] && (( pmt < ustart )); then
        _a_ok  stale_premise_pidfile_predates_bringup \
               "pidfile mtime $pmt is $(( ustart - pmt ))s before the bring-up at $ustart"
    else
        _a_bad stale_premise_pidfile_predates_bringup \
               "pidfile mtime [${pmt:-<none>}] against bring-up start [${ustart:-<none>}]: the window does not open before the fabric exists, so nothing here discriminates"
    fi
    a_eq    stale_premise_pid_was_dead      "no"   "$(rawfield "$d" plant.txt pid_alive)"
    a_eq    stale_premise_up_rc_is_0        "0"    "$(cat "$d/up.rc" 2>/dev/null)"
    a_eq    stale_premise_rule_was_accepted "200"  "$(cat "$d/install.code" 2>/dev/null)"
    n="$(cat "$d/flow_entries.count" 2>/dev/null)"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
        _a_ok  stale_premise_flow_table_not_empty "$n rule(s) on the wire for a window to frame"
    else
        _a_bad stale_premise_flow_table_not_empty \
               "flow table entry count [${n:-<not recorded>}]: with no rule on the wire 'no rule in that window' is true of every tool, including one that stopped looking"
    fi
    if [[ -n "$line" ]]; then
        _a_ok  stale_premise_the_app_got_a_window "${line# }"
    else
        _a_bad stale_premise_the_app_got_a_window \
               "residue_report printed no window line for the planted app -- the pidfile dated nothing, so the right edge is not what this run is measuring"
    fi

    # --- 🔴 THE KEY ASSERTIONS.
    # (1) the shape of the window itself. `-> now (` is the open branch and `window closed` the
    #     closed one; both are residue_report's own words for which branch it took.
    case "$line" in
        *"-> now ("*)      shape=open ;;
        *"window closed"*) shape=closed ;;
        "")                shape=no-window ;;
        *)                 shape=unrecognised ;;
    esac
    a_eq    stale_window_has_a_right_edge   "closed"  "$shape"
    # (2) what that window framed. The line after the window line is residue_report's answer:
    #     `no flow entry arrived during that window`, or the first `rule` of a list.
    case "$nxt" in
        *"no flow entry arrived during that window"*) frames=none ;;
        *"rule "*)                                    frames=rules ;;
        *)                                            frames="unrecognised" ;;
    esac
    a_eq    stale_window_frames_no_rule     "none"    "$frames"
    # (3) and nothing anywhere in that app's block was listed against it -- the `rule` lines and
    #     the `N rule(s) listed:` summary, counted inside the block and not over the report.
    a_eq    stale_app_block_lists_no_rule   "0"       "$listed"
    # (4) what the operator sees. `listed by:` is printed on the residue row's RED branch only,
    #     so its absence is bound to a path and not to a wording (CELLS-1 §7-1).
    a_hasnt stale_check_does_not_list_them  "listed by:  ndt apps orphans"   "$d/check.log"
    # (5) 🔴 THE PROBLEM LIST, NOT `--check`'s EXIT CODE. The rc is one number for every problem
    #     the report found, and on 2026-09-12 15:04 this cell's own raw came back
    #     `check: 2 problem(s)` -- one of them the rules-in-a-window row this cell is about, the
    #     other an untracked `sim` belonging to ANOTHER WORKTREE's test fixture. An assertion on
    #     the rc cannot tell those apart, so it would go red on a fixed tree whenever somebody
    #     else's suite happened to be running, and green on a broken one never. Counted instead:
    #     how many of the `  - ` problem lines are about rules inside a window. The pattern holds
    #     across FIX-NDT-9's rename -- `app residue: N rule(s) installed inside an app's window`
    #     and `rules-in-window: N rule(s) ...` both carry `rule(s)` and `window`.
    nprob="$(awk '/^check: /{p=1; next} p && /^  - /{print}' "$d/check.log" 2>/dev/null \
             | grep -cE 'rule\(s\).*window')"
    crc="$(cat "$d/check.rc" 2>/dev/null)"
    if [[ "$nprob" == 0 ]]; then
        _a_ok  stale_check_raises_no_rules_in_window_problem \
               "no '  - ' problem line is about rules in an app window (check rc was ${crc:-<not recorded>}, which this cell does NOT judge -- see the comment)"
    else
        _a_bad stale_check_raises_no_rules_in_window_problem \
               "$nprob problem line(s) about rules in an app window (check rc ${crc:-<not recorded>}): $(awk '/^check: /{p=1; next} p && /^  - /{print}' "$d/check.log" 2>/dev/null | grep -E 'rule\(s\).*window' | head -1 | sed 's/^ *- //')"
    fi

    # 🔴 THE PREMISE THE `--check` ASSERTIONS ABOVE REST ON, and it is a premise and not a
    # control: an app that is REALLY RUNNING has a window that is legitimately open to now, and
    # its window really does contain rules installed a minute ago. On this machine that is not
    # hypothetical -- a sim with no pidfile, dated by app_started_at's third source, was running
    # during this cell's own first capture.
    #
    # 🔴 IT READS THE UNTRACKED ROW, and the first draft did not. It asserted `a_has ... 'none
    # running'`, which matches the `apps` row -- and the `apps` row is about apps this checkout
    # TRACKS. In the raw this cell's old/ fixture came out of, that row said `apps  none running`
    # and the row under it said `untracked  sim(1166836) -- running`: the premise passed with a
    # foreign app process on the machine, which is the whole thing it exists to exclude. Measured
    # 2026-09-12 15:04:47, old/check.log lines 36-37.
    # tests/fixtures/live_cells/<this cell>/control-untracked/ is the negative control, and
    # tests/shell/mutate_live_cells.sh requires this id to be in ITS failing set.
    apps_row="$(grep -m1 -E '^  apps +' "$d/check.log" 2>/dev/null)"
    untr="$(grep -m1 -E '^  untracked +.*-- running' "$d/check.log" 2>/dev/null)"
    if [[ -z "$untr" && "$apps_row" == *"none running"* ]]; then
        _a_ok  stale_premise_no_app_was_running \
               "no tracked app and no untracked app process: ${apps_row# }"
    else
        _a_bad stale_premise_no_app_was_running \
               "an app process was running while this was measured, so a legitimately-open window could be on the machine and the rows above are not this cell's to read -- apps row [${apps_row:-<absent>}] untracked row [${untr:-<none>}]"
    fi

    # --- controls: the directions a wrong fix would take. They pass on old/ by design.
    a_has   stale_control_fabric_was_really_up   "10 up, 10 enabled"   "$d/check.log"
    a_eq    stale_control_plant_was_removed      "no"  "$(rawfield "$d" plant.cleanup still_there)"
}

cell_main stale_app_pidfile_does_not_frame_the_fabric ndt ovs4 "$@"
