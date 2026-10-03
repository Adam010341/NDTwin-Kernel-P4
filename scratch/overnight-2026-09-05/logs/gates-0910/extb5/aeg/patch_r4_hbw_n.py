#!/usr/bin/env python3
# patch_r4_hbw_n.py <worktree> -- round 4 item 2: N40-N56 (ndt's drop-check wiring) in the
# heartbeat gate.
import os
import sys

p = os.path.join(sys.argv[1], "tests/shell/mutate_p4_heartbeat_w.sh")
s = open(p).read()
anchor = '''nreport "N03d: a failed start on an external plane names the foreign reason" "$m" \\
        "🔴 a failed start on an external plane names external_control_plane"
'''
assert s.count(anchor) == 1
Q = "'\"'\"'"   # a single quote inside a single-quoted bash word


def m(label, old, new, name, check):
    old = old.replace("'", Q)
    new = new.replace("'", Q)
    return (f"m=$(nmutant {label} \"$NDT\" \\\n    '{old}' \\\n    '{new}')\n"
            f"nreport \"{name}\" \"$m\" \\\n        \"{check}\"\n")


gate = '[[ "$2" == external && "${HB_CHECK_RC:-}" != 0 ]]'
new = anchor + '''# [Co-developed with claude code -- Adam] Adam's 09-28 ruling: on an external control plane the
# heartbeat starts only when the drop check proved the program drops its frame. N40 ignores the
# check; N41 takes could-not-tell as proof; N42 never runs it; N43 withholds it everywhere external;
# N44 hides the check's own lines; N45 fails the bring-up over it; N46 parses no reason out of it;
# N47 writes no record; N48 is silent on could-not-tell; N49 takes a check that never ran as
# proof; N50 runs it on every package; N51 withholds it on a foreign fabric that is not external;
# N52/N53 leave a stale record; N54/N55 the status row.
''' + "".join([
    m("n40", f"    if {gate}; then", "    if false; then",
      "N40: the heartbeat starts on an external plane whatever the check said",
      "🔴 and the heartbeat is NOT started"),
    m("n41", f"    if {gate}; then", '    if [[ "$2" == external && "${HB_CHECK_RC:-}" == 1 ]]; then',
      "N41: could-not-tell is taken as proof",
      "🔴 could not tell: NOT started either (unknown is not a drop)"),
    m("n42", '        if [[ "$app_mode" == external && "$app_pipe" == foreign:* ]]; then\n            hb_drop_check_step "$app_dir"',
      '        if false; then\n            hb_drop_check_step "$app_dir"',
      "N42: the check never runs", "🔴 the check ran once, on the package"),
    m("n43", f"    if {gate}; then", '    if [[ "$2" == external ]]; then',
      "N43: the heartbeat is withheld on every external plane, proven or not",
      "🔴 proven dropped: the heartbeat starts"),
    m("n44", "    [[ -n \"$out\" ]] && printf '%s\\n' \"$out\" | sed 's/^/  /'\n    HB_CHECK_RC=\"$rc\"",
      '    HB_CHECK_RC="$rc"',
      "N44: the check's own lines are not printed", "  the check's answer is printed"),
    m("n45", "        printf 'withheld %s %s\\n' \"$(date +%s)\" \"$why\" > \"$(hb_withheld_file)\" 2>/dev/null\n        return 0",
      "        printf 'withheld %s %s\\n' \"$(date +%s)\" \"$why\" > \"$(hb_withheld_file)\" 2>/dev/null\n        exit 1",
      "N45: a withheld heartbeat fails the bring-up", "🔴 NOT dropped: the bring-up still succeeds"),
    m("n46", "(.*: (NOT_DROPPED|UNKNOWN) -- .*)$/\\1/p' | head -1)\"",
      "(.*: (NEVER_DROPPED|UNKNOWN_NEVER) -- .*)$/\\1/p' | head -1)\"",
      "N46: the check's reason is not carried to the warning", "  with the check's own reason"),
    m("n47", "        printf 'withheld %s %s\\n' \"$(date +%s)\" \"$why\" > \"$(hb_withheld_file)\" 2>/dev/null",
      "        :",
      "N47: no record is written for 'ndt status'", "🔴 and the record names it for 'ndt status'"),
    m("n48", '        *) warn "the heartbeat drop check could not tell (rc $rc): the heartbeat will not be started -- unknown is not a drop" ;;',
      "        *) : ;;",
      "N48: could-not-tell is not said", "  saying it could not tell"),
    m("n49", f"    if {gate}; then", '    if [[ "$2" == external && "${HB_CHECK_RC:-0}" != 0 ]]; then',
      "N49: a check that never ran is taken as proof",
      "🔴 a check that never ran is not proof: NOT started"),
    m("n50", '        if [[ "$app_mode" == external && "$app_pipe" == foreign:* ]]; then\n            hb_drop_check_step "$app_dir"',
      '        if true; then\n            hb_drop_check_step "$app_dir"',
      "N50: the check runs on every package", "🔴 a foreign fabric that is not external: no check"),
    m("n50b", '        if [[ "$app_mode" == external && "$app_pipe" == foreign:* ]]; then\n            hb_drop_check_step "$app_dir"',
      '        if true; then\n            hb_drop_check_step "$app_dir"',
      "N50b: (the same, on NDTwin's own pipeline)", "  NDTwin's own pipeline: no check either"),
    m("n51", f"    if {gate}; then", '    if [[ "${HB_CHECK_RC:-}" != 0 ]]; then',
      "N51: a foreign fabric that is not external is held to the check too",
      "  and its heartbeat starts as before"),
    m("n52", "    rm -f \"$(hb_withheld_file)\"\n    heartbeat_wanted \"$1\" \"$2\" || return 0",
      "    heartbeat_wanted \"$1\" \"$2\" || return 0",
      "N52: a later bring-up leaves the last one's record",
      "🔴 a later bring-up that starts it clears the record"),
    m("n53", "    # [Co-developed with claude code -- Adam] The withheld record describes the fabric going away.\n    rm -f \"$(hb_withheld_file)\"",
      "    # [Co-developed with claude code -- Adam] The withheld record describes the fabric going away.\n    :",
      "N53: 'ndt down' leaves the record behind", "🔴 'ndt down' clears it with the fabric"),
    m("n54", '    if [[ -f "$withheld" ]]; then', "    if false; then",
      "N54: 'ndt status' does not say a heartbeat was withheld",
      "🔴 a heartbeat the last bring-up withheld is said, with why"),
    m("n55", '    if [[ -f "$withheld" ]]; then', "    if true; then",
      "N55: 'ndt status' says withheld with no record", "  and not when there is no record"),
])
s = s.replace(anchor, new)
open(p, "w").write(s)
print("ok")
