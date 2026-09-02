#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

## BUG-6: `ndt apps energy` / `ndt apps sim` print "ok ... started" for apps that are already dead
- **Feature:** `ndt apps [names]` -- "start readers/apps: energy sim nsr viz te"
- **Manual page/section:** User Manual > NDTwin Kernel > Native-Linux Execution Environment >
  "The rest of the interface" table: `ndt apps [names] start readers/apps ... No arguments on
  a terminal gives an interactive picker`.
- **Exact steps (verbatim), tried twice under different conditions:**
  ```
  bash -l -c "ndt apps energy"     # attempt 1: no Ryu/Mininet/Kernel running at all
  bash -l -c "ndt apps sim"        # same conditions
  # ... later, with a converged Ryu+Mininet+Kernel OVS fabric fully up (confirmed via
  # ovs-ofctl flow counts and the kernel's own "topology from the control plane" line) ...
  bash -l -c "ndt apps energy"     # attempt 2: dependencies actually satisfied this time
  ```
- **Expected:** "ok ... started" should mean the app is running (that is what "started" means
  anywhere else in this tool's own output -- compare `ndt up`'s per-phase `ok` lines, which
  only appear once a check actually passed).
- **Observed (verbatim):**
  ```
  $ ndt apps energy
    ok  energy started (tmux: energy)
  $ tmux list-sessions | grep energy
  (nothing)
  $ ndt apps sim
    ok  sim started (tmux: sim)
  $ tmux list-sessions | grep sim
  (nothing)
  ```
  Both tmux sessions were already gone by the time I checked -- including on an immediate,
  zero-delay recheck right after the "ok" line printed. `ndt status`'s own `apps` field agreed
  afterward (`apps  none running`), so the tool's own status view is not fooled -- only the
  `ndt apps` command's own success message is. No log file was created anywhere I could find
  (`.test_run/logs/app_energy.log` and `app_sim.log` both do not exist), unlike NSR's own
  failure earlier in this run, which logged a specific, useful error. Repeated the `energy`
  case a second time with a real, converged OVS fabric and kernel already running (the
  dependency I initially assumed was missing) -- identical result: "ok ... started", tmux
  session already gone. This matches what a standalone `sudo ./energy_saving_app` showed
  directly (see the Simulation Platform Manager section of this file): it needs an NFS
  subdirectory that only gets created by a prior successful kernel registration, so it likely
  crashes near-instantly here too -- but that root cause is beside the point of this bug, which
  is that `ndt apps` never checks whether the process it just launched is still alive before
  reporting success.
- **Reproduced on a second try?** Yes, deliberately, under two different starting conditions
  (no stack running; full converged stack running) -- both times "ok" and both times the
  session was already gone.
- **Severity (my guess):** Medium-high. This is the exact failure shape this whole test run
  was briefed to catch: a command that reports success and is not itself evidence anything
  happened. It is worse than BUG-3's silent leftover process in one respect -- there the tool
  under-reported (said nothing about a process that *was* there); here it over-reports (says
  something started that already was not there), which is the more dangerous direction to be
  wrong in for anyone scripting against `ndt apps`'s exit code or message.
EOF
echo APPENDED
wc -l ~/BUGS.md
