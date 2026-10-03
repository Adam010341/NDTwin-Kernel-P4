#!/usr/bin/env python3
# patch_r4_hbw_x.py <worktree> -- round 4 item 1: X11-X14 in the heartbeat gate.
import os
import sys

p = os.path.join(sys.argv[1], "tests/shell/mutate_p4_heartbeat_w.sh")
s = open(p).read()
anchor = '''report "X10: link_watchdog stays named skipped on an external fabric the heartbeat watches" "$m" \\
       "test_link_watchdog_leaves_the_list_while_the_heartbeat_drives_it"
'''
assert s.count(anchor) == 1
new = anchor + '''# [Co-developed with claude code -- Adam] Adam's 09-28 ruling: an external control plane on its
# own pipeline reports NO destination path. X11 never marks the fabric (the guess comes back
# through startup); X12 the pull ignores the mark; X13 the push ignores it; X14 the pull
# withholds the paths of every fabric (what the control cell is for).
m=$(mutant x11 "$MAIN" \\
    '        topo.destination_paths_unknown = True' \\
    '        pass')
report "X11: startup leaves an external fabric's paths to the shortest-path guess" "$m" \\
       "test_startup_marks_an_external_fabric_on_its_own_pipeline_only"
m=$(mutant x11b "$MAIN" \\
    '        topo.destination_paths_unknown = True' \\
    '        pass')
report "X11b: (the same, seen as the paths the pull serves)" "$m" \\
       "test_an_external_fabric_serves_no_path_over_its_declared_links"
m=$(mutant x12 "$ROUTES" \\
    '    if getattr(topology, "destination_paths_unknown", False):' \\
    '    if False:')
report "X12: the pull renders the guess on an external fabric" "$m" \\
       "test_an_external_fabric_serves_no_path_over_its_declared_links"
m=$(mutant x13 "$TOPOMGR" \\
    '        if self.destination_paths_unknown:' \\
    '        if False:')
report "X13: a cut on an external fabric pushes the guess" "$m" \\
       "test_a_cut_on_an_external_fabric_pushes_no_path"
m=$(mutant x14 "$ROUTES" \\
    '    if getattr(topology, "destination_paths_unknown", False):' \\
    '    if True:')
report "X14: the pull withholds the paths of every fabric" "$m" \\
       "test_the_same_graph_without_the_flag_does_have_a_path_to_withhold"
'''
s = s.replace(anchor, new)
open(p, "w").write(s)
print("ok")
