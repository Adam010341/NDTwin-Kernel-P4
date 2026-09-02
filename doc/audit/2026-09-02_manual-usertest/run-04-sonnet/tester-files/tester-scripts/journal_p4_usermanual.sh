#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## User Manual: P4/BMv2 data-plane walkthrough   started 18:17   ended 18:21   friction: 1
what I did: with Section 6 installed for real (both binaries confirmed working, pipeline
compiled, proxy venv built, `host_count_override`=128, `bmv2_binary_override` pointed at the
stock build), first tried the shortcut `ndt up` (bare, P4 is its default) out of the same
curiosity that tried `ndt up ovs` earlier. Reproduced the identical G-7 root cause: "XX fabric
did not come up: 0/10 switches, manifest missing" after 3m06s -- faster to give up than the
OVS path's 5m08s, and with a better message (names a diagnostic command,
`sudo -n /usr/local/sbin/ndtwin-lab topo-out 40`, which itself just says "no topo session").
`ndt down` afterward reported clean. Full detail in BUGS.md's addendum to BUG-1.
Fell back to the documented 3-terminal procedure, in the **reverse** order the manual
specifically calls out (Mininet/BMv2 first, since BMv2 listens and the proxy dials in, unlike
OVS where Ryu listens and switches dial in). Terminal 1
(`sudo python3 p4_proxy/mininet/p4_testbed_topo.py`): all 10 BMv2 switches came up and were
verified listening on gRPC 50051-50060 in under a minute, with a real `/tmp/ndtwin_p4_switches.json`
manifest (10 entries, real PIDs, each `argv` naming the exact `ndtwin_switch.json` pipeline
compiled in Installation Step 6.2). Terminal 2 (the proxy agent, in its own venv, `PYTHONPATH`
set to `p4_proxy`): came up on :8081; its first 10 attempts to tell the kernel about switches
entering all failed with `Connection refused` (kernel not started yet) -- its own log names
this as expected and retries in the background, then went on to LLDP discovery, link
discovery and proactive route install without getting stuck. `curl
:8081/ryu_server/all_destination_paths` reached exactly **16256** (128x127, the manual's own
documented figure) in under 30s and stayed stable across two more samples 5s apart. Terminal 3
(kernel, `--topology ...StaticNetworkTopologyP4_10Switches_128Hosts.json`): immediately logged
`Data plane: bmv2 (10 switch(es))`, correctly switched to polling the proxy's :8081 instead of
Ryu, and converged to exactly **10 switches, 128 hosts, 288 edges** -- the manual's own
documented figure, matched exactly.
Traffic validation (`h1 iperf3 -s &` / `h2 iperf3 -c h1 -t 300 &` in the Mininet CLI, then
`curl :8000/ndt/get_detected_flow_data`): exactly 2 records, same h1/h2 integer-IP encoding as
the OVS test, each with a real switch-level `path`. Measured throughput on the *stock* (debug)
`simple_switch_grpc` I deliberately kept (skipped the optional Step 6.7 fast rebuild): roughly
34-37 Mbit/s one direction -- squarely inside the manual's own documented debug-build ceiling
("about 40 Mbps of delivered UDP... adding parallel streams did not help"), a nice real
confirmation of a claim I did not have to take on faith.
Safe shutdown, in reverse order (kernel, then proxy, then Mininet): the kernel's Ctrl-C output
this time *did* show "terminate called without an active exception" (captured via plain `>`
file redirection rather than the `tee` pipe used earlier for the OVS test) -- this resolves
the open question from checklist item B14 in favour of "the manual is right, my earlier
capture method was the variable." The proxy released :8081 immediately. Mininet's own `exit`
had already killed all 10 `simple_switch_grpc` processes on its own -- `ps -eo args= | grep -c
"[s]imple_switch_grpc"` (the exact non-truncating form the manual insists on, not `pgrep -c`)
read **0** even before `mn -c` ran. `ndt status` independently confirmed a fully clean machine
afterward.
Skipped Step 6.7 / checklist item C17 (the `-O3` bmv2-fast performance build) -- explicitly
optional-on-top-of-optional per the manual's own framing, and not needed to exercise any
checklist item above.
surprised by: nothing broke. Every documented number in this section (16256 paths, 10
switches/288 edges, 2 flow records, the debug-build throughput ceiling) matched exactly on the
first real attempt, once the two known-and-already-documented G-7 shortcuts were worked around
by falling back to the 3-terminal procedure the manual itself recommends for exactly this case.
verdict: 1 confusing but worked -- the `ndt up` shortcut failing was expected (same as OVS),
and the manual's own reverse-order instruction for P4 was the one thing worth double-checking
against the actual startup logs, which it matched.
EOF
echo APPENDED
