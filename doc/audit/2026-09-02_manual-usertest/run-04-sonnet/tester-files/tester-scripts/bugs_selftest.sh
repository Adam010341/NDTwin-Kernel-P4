#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

## BUG-2: `testbed_topo.py`'s own built-in connectivity self-test reports 100% packet loss on pairs that work fine moments later, and its final banner ignores the failure entirely
- **Feature:** Terminal 2 (Mininet topology), `testbed_topo.py`'s internal self-test that runs
  automatically between "Adding links" and the `mininet>` prompt -- not something I invoked,
  it runs unattended as part of bringing the topology up.
- **Manual page/section:** User Manual > NDTwin Kernel > Operate an Emulated (Software)
  Network > Native-Linux Execution Environment > "Terminal 2: Mininet Topology". The manual
  documents waiting for the *Ryu* controller to print "all-destination paths installed" and
  gives an OVS-flow-count recipe to confirm that independently -- it says nothing about this
  script running its own ping self-test before the CLI appears, so this behaviour and its
  banner are both undocumented.
- **Exact steps (verbatim), run twice independently:**
  ```
  # Terminal 1
  conda activate ryu-env
  export NDTWIN_RYU_TOPO_FILE=~/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json
  ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link
  # Terminal 2, after Ryu is up
  cd ~/Desktop/NDTwin-Kernel && sudo python3 testbed_topo.py
  ```
- **Expected:** nothing in the manual predicts a failure here; by extension, a script that
  performs its own connectivity check and then prints "Final Configuration Active" /
  "Host internet: OK | sFlow reachability: OK | Switch identification: OK" is implicitly
  claiming the network it just verified is up, matching the spirit of the manual's own emphasis
  on checking real effects rather than trusting a success message.
- **Observed (verbatim, trimmed), run 1 (16:00-16:09):** the script printed 128 `Pinging from
  hN to 10.0.0.M...` announcements, then 128 `Result from ... :` blocks -- **all 128 of them
  `1 packets transmitted, 0 received, 100% packet loss`** (`grep -c "100% packet loss"` = 128,
  `grep -c "0% packet loss"` = 0, out of 128 `Result from` lines total). This was at a point
  where `sudo ovs-ofctl dump-flows sN | grep -c actions=` already read **130 on all ten
  switches** -- the manual's own documented "converged" figure -- so the flow tables were not
  empty when the self-test ran.
  Run 2 (16:11-16:13, fresh Ryu + fresh topology, see note on methodology below): identical
  result, 128/128 pings in the self-test at **100% packet loss**, again with flow tables
  already at 130/switch beforehand (checked directly with `ovs-ofctl dump-flows` seconds before
  the self-test's results appeared). Both runs ended with the same banner regardless:
  ```
  --- Final Configuration Active ---
  Host internet: OK | sFlow reachability: OK | Switch identification: OK
  ```
  Immediately after reaching the `mininet>` prompt in run 2, I typed the *exact* failing pair
  from the self-test by hand:
  ```
  mininet> h1 ping -c 3 10.0.0.65
  PING 10.0.0.65 (10.0.0.65) 56(84) bytes of data.
  64 bytes from 10.0.0.65: icmp_seq=1 ttl=64 time=0.696 ms
  64 bytes from 10.0.0.65: icmp_seq=2 ttl=64 time=0.058 ms
  64 bytes from 10.0.0.65: icmp_seq=3 ttl=64 time=0.045 ms
  --- 10.0.0.65 ping statistics ---
  3 packets transmitted, 3 received, 0% packet loss, time 2033ms
  ```
  0% packet loss, seconds after the self-test logged that same destination as 100% loss. A
  same-switch pair (`h1 ping -c 3 h2`) also passed cleanly (0% loss). So the fabric the
  self-test was reporting as unreachable was, in fact, fully reachable by the time (and almost
  certainly already was reachable when) the self-test ran.
- **Reproduced on a second try?** Yes -- the 128/128 self-test failure reproduced identically
  across two independent full stack restarts (fresh `ryu-manager`, fresh `testbed_topo.py`).
  The "actually works when tested by hand" half was checked once in run 2, on both a near pair
  and the exact far pair the self-test flagged; I did not feel a need to re-run that half a
  third time since both pairs it was asked to explain (near and far) passed cleanly.
- **My methodology note, not a bug:** run 1's Mininet CLI later crashed
  (`OSError: [Errno 5] Input/output error` inside `cmd.cmdloop()` -> `input()`) a few seconds
  after reaching `mininet>`, tearing the whole fabric down. I do not believe this is an NDTwin
  defect: I had launched Terminal 2 as `sudo python3 testbed_topo.py 2>&1 | tee ~/logs/...log`
  to capture a log, and run 2 (identical otherwise, launched *without* the `| tee`, logged via
  `tmux capture-pane` instead as my own instructions actually specify) reached and stayed at
  `mininet>` without incident. Recorded here only so the CLI crash is not mistaken for part of
  this bug -- BUG-2 is specifically about the self-test's false-failure report and its banner,
  both of which reproduced independently of the tee/no-tee difference.
- **Severity (my guess):** Medium. The actual data plane is fine on the evidence above, so this
  is not "the network is broken" -- it is "the project's own built-in health check cannot be
  trusted, and its summary line asserts health regardless of what the check underneath it just
  found." That is precisely the failure mode this test run was briefed to watch for (a
  success-looking message that is not evidence of anything), and it is bad specifically because
  a reader who *does* look at the pings (rather than only the final "OK" line) would reasonably
  conclude the network is broken and go looking for a problem that, on this machine, does not
  exist -- likely costing exactly the kind of debugging time the manual's other install-time
  warnings are otherwise careful to save.
EOF
echo APPENDED
wc -l ~/BUGS.md
