#!/usr/bin/env python3
# patch_r4_ndt_check.py <worktree> -- round 4 item 2: the drop check in ndt.
import os
import sys

p = os.path.join(sys.argv[1], "tools/test_workflow/ndt")
s = open(p).read()


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:80]
    s = s.replace(old, new)


# 1. the check's functions, after the heartbeat's paths
rep('''HB_PIDFILE=/run/ndtwin-lab/heartbeat.pid
HB_REPORT=/run/ndtwin-lab/heartbeat.json
''', '''HB_PIDFILE=/run/ndtwin-lab/heartbeat.pid
HB_REPORT=/run/ndtwin-lab/heartbeat.json

# --- the heartbeat drop check (Adam, 09-28): default-safe on an external control plane ----------
#
# [Co-developed with claude code -- Adam]
# On an external control plane the heartbeat's frames enter the EXERCISE'S program, and a program
# that punts, floods or digests an unknown ethertype hands them to its own controller or hosts --
# where neither the proxy (no stream there) nor the daemon (it counts frames leaving switch
# ports) can see it. So there the heartbeat starts ONLY when tools/test_workflow/
# heartbeat_drop_check.py proves, offline, that every program the package's switches run drops
# the frame with no controller and no entries. Not proven -- not dropped, or could not tell --
# means not started, said here and in `ndt status`. Run in the package pre-flight, before
# anything on the machine is touched: the check's throwaway switch is not the lab's (its own
# directory, a Thrift port outside the lab's, argv[0] `ndt-hbdrop-bmv2`, stopped by its pid).
# A foreign fabric that is NOT external keeps the heartbeat as before (segment W, ruling 4).
HB_CHECK_RC=""
HB_CHECK_WHY=""
hb_withheld_file() { echo "${NDT_HB_WITHHELD:-$REPO/.test_run/heartbeat.withheld}"; }

# hb_drop_check_run <package dir> -- the check itself: its lines, its rc (0 dropped, 1 not, 2 could
# not tell, 3 nothing to check). A function so the offline suites can stand in for it.
hb_drop_check_run() {
    python3 "$REPO/tools/test_workflow/heartbeat_drop_check.py" "$1"
}

# hb_drop_check_step <package dir> -- run it, print it, and remember the answer for
# heartbeat_up_step. Always rc 0: a program that does not drop the frame costs the fabric its
# detection, not its bring-up.
hb_drop_check_step() {
    local out rc
    say "heartbeat drop check (external control plane)"
    out="$(hb_drop_check_run "$1" 2>&1)"; rc=$?
    [[ -n "$out" ]] && printf '%s\\n' "$out" | sed 's/^/  /'
    HB_CHECK_RC="$rc"
    HB_CHECK_WHY="$(printf '%s\\n' "$out" | sed -n -E 's/^heartbeat drop check \\([a-z]+\\): (.*: (NOT_DROPPED|UNKNOWN) -- .*)$/\\1/p' | head -1)"
    [[ -z "$HB_CHECK_WHY" ]] && HB_CHECK_WHY="$(printf '%s\\n' "$out" | sed -n 's/^heartbeat drop check: //p' | head -1)"
    case "$rc" in
        0) ok "every program on this fabric drops the heartbeat's frame (default actions): it may run here" ;;
        1) warn "a program on this fabric does NOT drop the heartbeat's frame: the heartbeat will not be started" ;;
        *) warn "the heartbeat drop check could not tell (rc $rc): the heartbeat will not be started -- unknown is not a drop" ;;
    esac
    [[ -z "$HB_CHECK_WHY" && "$rc" != 0 ]] && HB_CHECK_WHY="the drop check answered rc $rc"
    return 0
}
''')

# 2. heartbeat_up_step: the external gate and its record
rep('''heartbeat_up_step() {
    heartbeat_wanted "$1" "$2" || return 0
    local out rc
''', '''heartbeat_up_step() {
    # [Co-developed with claude code -- Adam] A record of the LAST bring-up's decision, so it goes
    # before anything is decided for this one.
    rm -f "$(hb_withheld_file)"
    heartbeat_wanted "$1" "$2" || return 0
    local out rc
    # [Co-developed with claude code -- Adam] (Adam, 09-28) Default-safe on an external control
    # plane: started only when the drop check proved every program drops the frame. "" -- the
    # check never ran -- is not proof either.
    if [[ "$2" == external && "${HB_CHECK_RC:-}" != 0 ]]; then
        local why="${HB_CHECK_WHY:-the drop check did not run}"
        warn "heartbeat NOT started on this external control plane: its program is not proven to drop the heartbeat's frame"
        warn "  ($why)"
        warn "  a cut link on this fabric is not detected; the proxy reports reroute.reason external_control_plane."
        mkdir -p "$(dirname "$(hb_withheld_file)")" 2>/dev/null
        printf 'withheld %s %s\\n' "$(date +%s)" "$why" > "$(hb_withheld_file)" 2>/dev/null
        return 0
    fi
''')

# 3. the package pre-flight runs it
rep('''        app_pipe="$(app_pipeline_kind "$app_dir")"
    elif [[ -n "${1:-}" ]]; then''', '''        app_pipe="$(app_pipeline_kind "$app_dir")"
        # [Co-developed with claude code -- Adam] (Adam, 09-28) The heartbeat drop check, here --
        # before the machine is touched -- and only where heartbeat_up_step will ask for it.
        HB_CHECK_RC=""; HB_CHECK_WHY=""
        if [[ "$app_mode" == external && "$app_pipe" == foreign:* ]]; then
            hb_drop_check_step "$app_dir"
            echo
        fi
    elif [[ -n "${1:-}" ]]; then''')

# 4. ndt status says it
rep('''    printf '  %-14s %s\\n' "heartbeat" "$line"
}
''', '''    printf '  %-14s %s\\n' "heartbeat" "$line"
    # [Co-developed with claude code -- Adam] (Adam, 09-28) The last bring-up's decision when it
    # withheld the heartbeat on an external control plane: the report above can be an older run's.
    local withheld; withheld="$(hb_withheld_file)"
    if [[ -f "$withheld" ]]; then
        local at why
        read -r _ at why < "$withheld"
        printf '  %-14s %s\\n' "" "NOT started by the last 'ndt up' ($(( $(date +%s) - ${at:-0} )) s ago): its program is not proven to drop the heartbeat's frame -- $why"
    fi
}
''')

# 5. `ndt down` clears the record with the fabric
rep('''    heartbeat_stop_step "before the topology it watches is taken down" || {
        down_rc=1
        not_verified "the heartbeat daemon (its stop failed; sudo ndtwin-lab heartbeat status says whether it runs)"
    }
''', '''    heartbeat_stop_step "before the topology it watches is taken down" || {
        down_rc=1
        not_verified "the heartbeat daemon (its stop failed; sudo ndtwin-lab heartbeat status says whether it runs)"
    }
    # [Co-developed with claude code -- Adam] The withheld record describes the fabric going away.
    rm -f "$(hb_withheld_file)"
''')
open(p, "w").write(s)
print("ok")
