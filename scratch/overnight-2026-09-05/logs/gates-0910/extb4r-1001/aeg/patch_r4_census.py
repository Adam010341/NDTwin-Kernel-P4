#!/usr/bin/env python3
# patch_r4_census.py <worktree> -- round 4 item 2: the census text, its test and its mutants.
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


OLD_TAIL = '''               "skeletons do not build. Segment S's census started the heartbeat by hand (the "
               "helper, not ndt) on all 20. Since 2026-09-27 `ndt up p4 --app` is EXPECTED to "
               "start it on all 20 too -- on the 3 external control planes among them (p4runtime "
               "skeleton and solution, flowcache solution) detect only -- which is inferred from "
               "ndt's rule and not yet measured under ndt (live-p1/08 PART=h5 checks it per arm). "
               "On an external control plane a frame the program punts to ITS OWN controller is "
               "seen neither by this proxy (it has no stream there) nor by the daemon (it counts "
               "frames leaving switch ports). The P4 SOURCE of these 3 programs drops it "
               "(flowcache drops every non-IPv4 frame at ingress; advanced_tunnel applies no table "
               "to it, so egress_spec stays 0 -- that no port 0 exists is inferred from bmv2); "
               "segment S's census ran them with no controller, so no pipeline was loaded, and "
               "live-p1/08 PART=h5 is the first measurement with these programs loaded. No other "
               "external program has been looked at.",'''
NEW_TAIL = '''               "skeletons do not build. Segment S's census started the heartbeat by hand (the "
               "helper, not ndt) on all 20. Since 2026-09-27 `ndt up p4 --app` is EXPECTED to "
               "start it on all 20 too -- on the 3 external control planes among them (p4runtime "
               "skeleton and solution, flowcache solution) detect only, and since 2026-09-28 only "
               "after ndt's offline drop check proves the program drops the frame -- which is "
               "inferred from ndt's rule and not yet measured under ndt (live-p1/08 PART=h5 checks "
               "it per arm). On an external control plane a frame the program punts to ITS OWN "
               "controller is seen neither by this proxy (it has no stream there) nor by the "
               "daemon (it counts frames leaving switch ports); the drop check "
               "(tools/test_workflow/heartbeat_drop_check.py) is what keeps the heartbeat off a "
               "program that does that. The P4 SOURCE of these 3 programs drops it (flowcache "
               "drops every non-IPv4 frame at ingress; advanced_tunnel applies no table to it, so "
               "egress_spec stays 0 -- that no port 0 exists is inferred from bmv2), and the drop "
               "check agrees on a throwaway bmv2 with each program loaded and no controller "
               "(flowcache drops it at ingress; advanced_tunnel sends it to port 0, which no "
               "switch of the fabric has). Segment S's census ran them with no controller, so no "
               "pipeline was loaded, and live-p1/08 PART=h5 is the first measurement with these "
               "programs loaded and their controllers running. Any other external program is "
               "checked the same way before the heartbeat starts on it; what its controller "
               "installs later is not covered.",'''
patch("p4_proxy/proxy_agent/main.py", [
    (OLD_TAIL, NEW_TAIL),
    ('''    # (round 2): the 3 external arms were NOT measured with their programs loaded -- segment S never
    # started their controllers -- so what is served is a reading of the P4 source, and says so.
}''', '''    # (round 2): the 3 external arms were NOT measured with their programs loaded -- segment S never
    # started their controllers -- so what is served is a reading of the P4 source, and says so.
    # Adam's 09-28 ruling: on an external control plane the heartbeat starts only after the offline
    # drop check proves the program drops the frame; its answer on the 3 programs is served too.
}'''),
])

patch("p4_proxy/tests/test_heartbeat_fabric.py", [
    ('''        self.assertIn("EXPECTED to start it on all 20 too", text)
        self.assertIn("not yet measured under ndt", text)''', '''        self.assertIn("EXPECTED to start it on all 20 too", text)
        self.assertIn("not yet measured under ndt", text)
        # [Co-developed with claude code -- Adam] Adam's 09-28 ruling: on an external control plane
        # only after the offline drop check proves the program drops the frame.
        self.assertIn("only after ndt's offline drop check proves the program drops the frame", text)'''),
    ('''        self.assertIn("No other external program has been looked at", text)''',
     '''        self.assertIn("Any other external program is checked the same way before the heartbeat "
                      "starts on it; what its controller installs later is not covered", text)
        self.assertIn("the drop check agrees on a throwaway bmv2", text)'''),
])

Q = "'\"'\"'"
old_m28 = OLD_TAIL.replace("'", Q)
new_m28 = NEW_TAIL.replace("'", Q)
patch("tests/shell/mutate_p4_heartbeat_w.sh", [
    (old_m28.split("\n", 1)[0].replace('               "skeletons do not build. ', '               "skeletons do not build. ')
     + "\n" + old_m28.split("\n", 1)[1],
     new_m28.split("\n", 1)[0] + "\n" + new_m28.split("\n", 1)[1]),
    ('''m=$(mutant m28b "$MAIN" \\
    '               "external program has been looked at.",' \\
    '               "external program has been assumed safe.",')
report "M28b: the census stops saying no other external program was looked at" "$m" \\''',
     '''m=$(mutant m28b "$MAIN" \\
    '               "installs later is not covered.",' \\
    '               "installs later is covered too.",')
report "M28b: the census stops saying what the drop check does not cover" "$m" \\'''),
])
print("ok")
