#!/usr/bin/env python3
# patch_old_redfirsts_r4.py <aeg dir> <dry dir> -- extend redfirst_b/b2/b3's expected sets with the cells
# round 4 (and trunk 08f67b7a, merged into it) added to the suites they run: those are red over every older
# base for a reason that is not the older round's. Each extension is printed by the script, with its reason.
import os
import re
import sys

aeg, dry = sys.argv[1], sys.argv[2]


def extras(out, section_header):
    text = open(os.path.join(dry, out)).read()
    sec = text.split(section_header, 1)[1]
    sec = sec.split("\n==", 1)[0]
    return [ln[len("      > "):] for ln in sec.splitlines() if ln.startswith("      > ")]


def q(name):
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'


NOTE = 'echo "    (added at round 4, 09-28: {what} -- red over every older base for that reason)"\n'


def patch_list(script, anchor, names, what):
    """anchor = the last line of the same_set call, without its newline."""
    p = os.path.join(aeg, script)
    s = open(p).read()
    assert s.count(anchor + "\n") == 1, (script, anchor[:60])
    add = " \\\n    " + " \\\n    ".join(q(n) for n in names)
    s = s.replace(anchor + "\n", anchor + add + "\n" + NOTE.format(what=what), 1)
    open(p, "w").write(s)


P_WHAT = "the destination-path cells of test_heartbeat_fabric (and, over f7e2a128, its seeding cell)"
N_WHAT = "test_ndt_heartbeat's drop-check cells (section 2c and the withheld row)"
patch_list("redfirst_b.sh", "    test_the_census_names_the_punt_blind_spot_on_external_control_planes",
           extras("rf4b-dry.out", "== P:"), P_WHAT)
patch_list("redfirst_b.sh", '    "🔴 a failed start on an external plane names external_control_plane"',
           extras("rf4b-dry.out", "== N:"), N_WHAT)
patch_list("redfirst_b2.sh", "    test_the_census_names_the_punt_blind_spot_on_external_control_planes",
           extras("rf4b2-dry.out", "== C:"), P_WHAT)
patch_list("redfirst_b2.sh", '    "  and not the reason a foreign fabric serves"',
           extras("rf4b2-dry.out", "== D:"), N_WHAT)
patch_list("redfirst_b3.sh",
           'same_set "base main.py" "$T/r" test_the_census_names_the_punt_blind_spot_on_external_control_planes',
           extras("rf4b3-dry.out", "== C:"), P_WHAT + " and its census cell's drop-check sentence")
patch_list("redfirst_b3.sh", 'same_set "base ndt" "$T/r" "🔴 a package fabric is told the count is not a reading"',
           extras("rf4b3-dry.out", "== D:"),
           "the external no-path status cell; and trunk 08f67b7a's emitter-liveness cell, red over any ndt "
           "before that merge")
print("ok")
