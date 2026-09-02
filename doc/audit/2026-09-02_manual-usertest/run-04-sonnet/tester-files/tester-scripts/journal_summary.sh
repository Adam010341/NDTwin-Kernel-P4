#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## SUMMARY

**Installed and running?** Yes. NDTwin Kernel built clean from source (Sections 1-5 of the
Installation Manual, Native-Linux path), and both the OVS/Ryu path and the optional P4/BMv2
path (Section 6) were brought up end-to-end more than once, with traffic flowing and detected
by the kernel's own API each time. Evidence: `~/Desktop/NDTwin-Kernel/build/bin/ndtwin_kernel`
built 2026-09-02 15:53 (OVS) and still working through the P4 walkthrough that ended 18:21;
kernel log line `topology from the control plane: 10 switches, 128 hosts, 288 edges up` on
both the OVS fabric (twice) and the P4/BMv2 fabric; `curl :8000/ndt/get_detected_flow_data`
returning real flow records with real switch paths on both fabrics, cross-checked against
independently-run iperf3 transfers.

**Per-section timings** (from JOURNAL.md's own `started`/`ended` timestamps, all VM-local
`date` output):
- Section 1 (System Requirements): 15:39-15:39, friction 0
- Section 2 (Python/Ryu): 15:39-15:45, friction 0
- Section 3 (System Dependencies): 15:45-15:49, friction 0
- Section 4 (Clone + Compile Kernel): 15:51-15:57, friction 2 (friction was my own tooling, not the build)
- Section 5 (Topology Script): 15:58-15:58, friction 0
- Kernel User Manual, OVS path (short way + 3-terminal): 15:59-~16:23, friction 3
- Network State Recorder: 16:04-16:31, friction 2
- Web GUI: 16:26-16:32, friction 3
- Network Traffic Generator: 16:04-16:37, friction 1
- Simulation Platform Manager + Energy-Saving-App: 16:38-16:44, friction 1
- Network Traffic Visualizer: 16:46-16:47, friction 0
- Section 6 (P4/BMv2 Installation, dominated by the ~2h13m toolchain build): 16:02-18:12, friction 2
- Kernel User Manual, P4/BMv2 path: 18:17-18:21, friction 1
- Total elapsed, first VM command to last: 15:37 -> 18:25, about **6h48m of wall-clock**, of
  which roughly 2h13m was the unattended P4 toolchain build running in the background while
  other sections were tested, and two further stretches were my own tooling stalling rather
  than any wait the project itself required (recorded in JOURNAL.md as the two "Tooling note"
  entries, 15:51-15:57 and centered on 16:52-17:00 respectively -- both were me incorrectly
  assuming a detached VM-side process would page me, not anything NDTwin did).

**What was skipped and why:**
- Step 6.7 (optional bmv2-fast `-O3` performance rebuild of BMv2): explicitly
  optional-on-top-of-optional per the manual's own framing; not needed for any checklist item.
- NTG/NSR "hardware/worker-node" modes, Operate a Physical (Hardware) Network: no physical
  testbed available in this run.
- WebGUI's GUI feature pages, TrafficVisualizer's GUI features, NTG's tab-completion: this
  test's own ground rules (no browser automation; this VM has no real display or interactive
  TTY) -- marked NOT-TRIED rather than guessed at.
- Full Simulation Platform end-to-end (kernel submits a task, simulator runs): would need
  WebGUI (blocked by BUG-5) or another documented trigger path I did not have.

**Moment I felt most lost:** discovering the orphaned `ndtwin_kernel` process (BUG-3) blocking
my own Terminal-3 launch with a sFlow-port bind failure. `ndt down` had reported the machine
fully clean minutes earlier, and I could not initially tell whether the leftover process was
something I had caused, a race in `ndt up ovs`'s own internal retry logic, or something else
entirely -- it took `ps`/`ss` cross-checks and re-reading the one file the manual named
(`ndtwin-lab`) to get confident enough to write it up rather than guess.
EOF
wc -l ~/JOURNAL.md
