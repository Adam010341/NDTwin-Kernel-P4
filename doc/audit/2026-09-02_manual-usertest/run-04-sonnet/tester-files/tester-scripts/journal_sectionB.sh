#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## User Manual: Kernel usage, OVS path (the short way + the 3-terminal way)   started 15:59   ended ~16:23   friction: 3
what I did: installed the `ndt` launcher exactly per the manual (symlink, root-owned
`ndtwin-lab`, sudoers NOPASSWD entry) -- all three steps WORKED. Tried `ndt up ovs` first,
since it is literally the first code block on the page and a curious reader tries the
shortcut before the reference procedure. It reproduced the manual's own pre-documented "G-7"
known limitation exactly: phase 1/4 (Ryu) came up, phase 2/4 (OVS fabric) never started a real
topology (confirmed nothing running underneath it -- no topology process, no root tmux
session, zero OVS bridges), and it gave up after 5m08s with "XX fabric has 0 hosts, expected
128". Read (did not edit) `/usr/local/sbin/ndtwin-lab` to confirm the hardcoded `/home/adam/...`
paths the manual's box names are real -- they are. `ndt down` afterward correctly reported a
clean machine. Full detail in BUGS.md BUG-1.
Fell back to the documented 3-terminal procedure, as the manual itself instructs for this
known case. This is where the run got interesting: Terminal 2 (`testbed_topo.py`) runs its own
built-in all-pairs ping self-test before showing the CLI prompt, and on *two independent full
restarts* that self-test reported 100% packet loss on all 128 pairs it tried -- while
`ovs-ofctl dump-flows` already showed the documented "converged" figure (130 rules/switch) at
the time. Manually re-pinging the *exact same* failing pair (`h1 -> 10.0.0.65`) seconds later
at the `mininet>` prompt got 0% loss, and so did a same-switch pair. So the fabric itself was
fine both times; the script's own health check was not, and its final banner
("Host internet: OK | sFlow reachability: OK | Switch identification: OK") did not reflect
that at all. Full detail in BUGS.md BUG-2. Separately, my first attempt at Terminal 2 (piped
through `tee` for logging, my own choice, not the manual's) had its Mininet CLI crash with an
I/O error a few seconds after reaching the prompt; a second attempt without the pipe (logged
via `tmux capture-pane` instead, as my own instructions actually specify) did not crash, so I
am treating that crash as my own tooling mistake and not a project defect -- noted in BUGS.md
under BUG-2 so it isn't confused with the actual finding.
Terminal 3 (kernel) then refused to start the *first* time I tried it, with a very legible
error: `bind() to sFlow port 6343 failed: Address already in use. Another NDTwin kernel is
almost certainly still running and holding it.` It was right -- a kernel process I never
started (PID 59174, running since 16:08:38) was already up, already looked completely healthy
under `ndt status` (10 switches, 128 hosts, 288 edges, no owner claimed), and neither that
status output nor the earlier `ndt down` had said anything about it, because `ndt down` only
checks ports 8000/8080/8081, not 6343. I could not pin down for certain whether it came from
the failed `ndt up ovs` run polling on in the background after reporting failure, or from
`testbed_topo.py` itself starting a kernel as a side effect -- both are plausible from the
timing and I deliberately did not open either script's source to settle it. Killed it by its
exact PID (not a pattern match) and moved on. Full detail in BUGS.md BUG-3.
With that out of the way, my *own*, properly-started Terminal 3 came up cleanly and
immediately reported "topology from the control plane: 10 switches, 128 hosts, 288 edges up".
Ran the manual's traffic-validation recipe against it: `h1 iperf3 -s &` / `h2 iperf3 -c h1 -t
300 &` in the Mininet CLI, then `curl :8000/ndt/get_detected_flow_data` while it ran --
**exactly 2 records**, one per direction, and the integers decoded to `10.0.0.1`/`10.0.0.2`
(h1/h2) via the manual's own one-liner -- matching the manual's own worked example down to the
literal integer values it uses (`16777226`/`33554442`). iperf3 itself sustained ~955-956
Mbit/s, close to the declared 1000Mbit `TCLink` cap. Stopped the flows (`pkill iperf3` on each
host, not `-f`) and re-queried after ~20s idle: `[]`, matching the documented 15s
`FLOW_IDLE_TIMEOUT`.
Also tried the kernel with **no flags**: got the exact 3-question interactive prompt the
manual quotes, answered 1/1/2 by hand, and it started identically to the flagged form.
Safe shutdown, first full cycle: Ctrl-C on the kernel released `:8000` (process gone, `ss`
confirms) but I did not see the "terminate called without an active exception" line the manual
quotes in what I captured -- noted as a partial match rather than chasing it further, since the
signal path here is `tmux send-keys C-c` into a `sudo ... | tee` pipeline rather than a human's
raw keypress, which is a difference in my own method, not necessarily the project's behaviour.
`exit` in the Mininet CLI worked cleanly (no crash this time -- consistent with the tee theory
above). `sudo mn -c` killed Ryu's tmux session exactly as the manual warns it will -- confirmed
by tmux session listing before/after.
Restarted the **entire stack a second time** from a genuinely clean state (this is restart
attempt #3 counting the `ndt up ovs` false start) -- see the next journal entry for its result.
surprised by: the self-test false-failure (BUG-2) and the invisible leftover kernel (BUG-3) --
both are the "prints success/looks fine but did not do what it claims" pattern this run was
specifically briefed to catch, and neither would have been visible from exit codes alone.
verdict: 3 blocked, worked around: `ndt up ovs` itself is broken on this machine (manual's own
known issue, worked around by using the documented 3-terminal fallback, which works); getting
a truthful read on Terminal 2/3 required not trusting either script's own summary line and
checking the effect directly, exactly as this test was briefed to do.
EOF
echo APPENDED
