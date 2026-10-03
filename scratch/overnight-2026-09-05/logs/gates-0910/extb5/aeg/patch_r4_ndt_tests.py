#!/usr/bin/env python3
# patch_r4_ndt_tests.py <worktree> -- round 4 item 2: ndt's suites for the drop check.
import os
import sys

wt = sys.argv[1]


def patch(rel, pairs):
    p = os.path.join(wt, rel)
    s = open(p).read()
    for old, new in pairs:
        assert s.count(old) == 1, (rel, old[:80])
        s = s.replace(old, new)
    open(p, "w").write(s)


STUB = r'''hb_drop_check_run() {
    printf "hbcheck %s\n" "$1" >> "$EVENTS"
    case "${HB_CHECK_STUB_RC:-0}" in
        0) echo "heartbeat drop check (checked): advanced_tunnel.json (stub): DROPPED -- every injected frame was dropped" ;;
        1) echo "heartbeat drop check (checked): advanced_tunnel.json (stub): NOT_DROPPED -- port 2: PUNTED to the CPU port 255" ;;
        *) echo "heartbeat drop check (checked): advanced_tunnel.json (stub): UNKNOWN -- the switch exited before the check finished" ;;
    esac
    return "${HB_CHECK_STUB_RC:-0}"
}
'''

patch("tests/shell/test_ndt_heartbeat.sh", [
    ('''stale_pipeline() { return 1; }
preflight() { return 0; }
''', '''stale_pipeline() { return 1; }
preflight() { return 0; }
# [Co-developed with claude code -- Adam] (Adam, 09-28) The drop check stands in here: it is driven
# for real by tests/shell/test_heartbeat_drop_check.py. On the event log, so ORDER can be asserted.
''' + STUB.replace('"', '"').replace("'", "'\"'\"'")),
    ('''          "$FIX/.test_run/up.target" "$FIX/.test_run/host_count_override.pre-up"
    : > "$EVENTS"''', '''          "$FIX/.test_run/up.target" "$FIX/.test_run/host_count_override.pre-up" \\
          "$FIX/.test_run/heartbeat.withheld"
    : > "$EVENTS"'''),
    ('''# =============================================================================================
section "3. 🔴 a heartbeat that does not start does not fail the bring-up"''', '''# =============================================================================================
section "2c. 🔴 external: started ONLY when the drop check proves its program drops the frame (09-28)"
# =============================================================================================
# [Co-developed with claude code -- Adam] Adam's ruling: default-safe on an external control plane.
# The check runs in the package pre-flight (before the machine is touched), and the heartbeat
# starts only on its rc 0 -- not dropped and could-not-tell both withhold it, and say why.
withheld() { cat "$FIX/.test_run/heartbeat.withheld" 2>/dev/null || echo "<no record>"; }
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_EXTERNAL"); up_p4")"
check "🔴 the check ran once, on the package"                    "1" "$(count_of "hbcheck $PKG_EXTERNAL")"
check "🔴 before anything touched the machine"                   "yes" "$(before 'hbcheck ' 'topo-start')"
check "🔴 proven dropped: the heartbeat starts"                  "1" "$(count_of 'ndtwin-lab heartbeat start')"
has   "  the check's answer is printed"                          "DROPPED -- every injected frame was dropped" "$OUT"
check "  and nothing is recorded as withheld"                    "<no record>" "$(withheld)"

reset_fix
OUT="$(drive "export HB_CHECK_STUB_RC=1; NDT_APP_DIR=$(q "$PKG_EXTERNAL"); up_p4")"
check "🔴 NOT dropped: the bring-up still succeeds"              "0" "$(rc_of "$OUT")"
check "🔴 and the heartbeat is NOT started"                      "0" "$(count_of 'ndtwin-lab heartbeat start')"
has   "🔴 saying so"                                             "heartbeat NOT started on this external control plane" "$OUT"
has   "  with the check's own reason"                            "PUNTED to the CPU port 255" "$OUT"
check "  the proxy and kernel were still started"                "1" "$(count_of 'stack up p4')"
has   "🔴 and the record names it for 'ndt status'"              "PUNTED to the CPU port 255" "$(withheld)"

reset_fix
OUT="$(drive "export HB_CHECK_STUB_RC=2; NDT_APP_DIR=$(q "$PKG_EXTERNAL"); up_p4")"
check "🔴 could not tell: NOT started either (unknown is not a drop)" "0" "$(count_of 'ndtwin-lab heartbeat start')"
has   "  saying it could not tell"                               "could not tell (rc 2)" "$OUT"
has   "  and why"                                                "the switch exited before the check finished" "$(withheld)"

reset_fix
OUT="$(drive "heartbeat_up_step foreign:1 external")"
check "🔴 a check that never ran is not proof: NOT started"      "0" "$(count_of 'ndtwin-lab heartbeat start')"
has   "  saying so"                                              "the drop check did not run" "$OUT"

reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "🔴 a foreign fabric that is not external: no check"       "0" "$(count_of 'hbcheck ')"
check "  and its heartbeat starts as before"                     "1" "$(count_of 'ndtwin-lab heartbeat start')"
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_NDTWIN"); up_p4")"
check "  NDTwin's own pipeline: no check either"                 "0" "$(count_of 'hbcheck ')"

# The record is the last bring-up's: a later bring-up that starts it clears it, and so does down.
reset_fix
printf 'withheld 1 an older reason\\n' > "$FIX/.test_run/heartbeat.withheld"
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_EXTERNAL"); up_p4")"
check "🔴 a later bring-up that starts it clears the record"     "<no record>" "$(withheld)"
printf 'withheld 1 an older reason\\n' > "$FIX/.test_run/heartbeat.withheld"
OUT="$(NDT_OWNER=t drive 'cmd_down')"
check "🔴 'ndt down' clears it with the fabric"                   "<no record>" "$(withheld)"

# =============================================================================================
section "3. 🔴 a heartbeat that does not start does not fail the bring-up"'''),
    ('''printf '{not json' > "$HB_JSON"
has   "  an unreadable report says so"                           "unreadable" "$(row)"''', '''printf '{not json' > "$HB_JSON"
has   "  an unreadable report says so"                           "unreadable" "$(row)"
# [Co-developed with claude code -- Adam] (Adam, 09-28) A withheld heartbeat is said under the row:
# the report above it can be an older run's.
printf 'withheld %s port 2: PUNTED to the CPU port 255\\n' "$(date +%s)" > "$FIX/.test_run/heartbeat.withheld"
has   "🔴 a heartbeat the last bring-up withheld is said, with why" "NOT started by the last 'ndt up'" "$(row)"
has   "  and why"                                                "PUNTED to the CPU port 255" "$(row)"
rm -f "$FIX/.test_run/heartbeat.withheld"
hasnt "  and not when there is no record"                        "NOT started by the last" "$(row)"'''),
])

patch("tests/shell/test_ndt_app_package.sh", [
    ('''stale_pipeline() { return 1; }
preflight() { return 0; }
''', '''stale_pipeline() { return 1; }
preflight() { return 0; }
hb_drop_check_run() { echo "heartbeat drop check (stub): DROPPED"; return 0; }
'''),
])
print("ok")
