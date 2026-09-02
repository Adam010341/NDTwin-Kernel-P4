#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

## BUG-3: an `ndtwin_kernel` process I never started was already running, invisible to `ndt down`'s "verify clean", and blocked my own Terminal-3 launch
- **Feature:** Terminal 3 (NDTwin Kernel) startup; also `ndt down`'s "verify clean" claim.
- **Manual page/section:** User Manual > Native-Linux Execution Environment > "Terminal 3:
  NDTwin Kernel", and the "Short way" page's `ndt down` description ("take it all down and
  prove the machine is clean").
- **Exact steps:** after BUG-1 (`ndt up ovs` failed, 16:00-16:05) and a clean `bash -l -c "ndt
  down"` (16:05:54, reported `ok bmv2 switches: 0`, `ok host/switch processes: 0`, `ok no topo
  session`, `ok no switch manifest`, `ok ports 8000/8080/8081 closed`), I started the manual
  3-terminal procedure fresh: Terminal 1 (`ryu-manager ...`, 16:07:21 and again 16:11:37 after
  an `mn -c`), Terminal 2 (`sudo python3 testbed_topo.py`, 16:08:19 then 16:11:51). At 16:15:08
  I ran my own **first-ever** Terminal 3 in this session:
  ```
  cd ~/Desktop/NDTwin-Kernel/build
  sudo bin/ndtwin_kernel --mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info
  ```
- **Expected (quoted):** the manual gives no indication anything but my own three terminals,
  started by me, would be running the kernel.
- **Observed (verbatim, trimmed):** my own kernel refused to start:
  ```
  [error] [FlowLinkUsageCollector.cpp:690] bind() to sFlow port 6343 failed: Address already
  in use. Another NDTwin kernel is almost certainly still running and holding it; without
  telemetry this twin would report every flow rate as zero, so it will not start.
  [critical] [main.cpp:406] cannot start telemetry collection: Failed to bind UDP socket. Exiting
  ```
  (the kernel's own error message is honest and specific here -- credit where due.) I went
  looking for what actually held the port:
  ```
  $ sudo ss -ulnp | grep 6343
  UNCONN 0 0 0.0.0.0:6343 0.0.0.0:* users:(("ndtwin_kernel",pid=59174,fd=3))
  $ ps -o pid,lstart,cmd -p 59174
    PID                  STARTED CMD
   59174 Wed Sep  2 16:08:38 2026 ./bin/ndtwin_kernel --mode mininet --topology
   /home/ndt/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json --no-ai
  ```
  `bash -l -c "ndt status"` at that point described this process's world as a normal, healthy,
  converged run -- `:8000 kernel open`, `switches 10 up, 10 enabled`, `links 288 total, 0
  down`, `kernel graph 10 switches (10 up, 10 enabled), 128 hosts, 288 edges` -- with **nothing
  in the output distinguishing "a run you started" from "a run nobody currently owns."**
  `lab > claim` still correctly read `none`, so the *ownership* bookkeeping and the *process*
  bookkeeping disagree with each other.
  I cannot pin down with certainty which of my own actions produced PID 59174 -- I never
  typed a command to start a kernel before 16:15:08 -- but the timing narrows it to one of two
  candidates, both concerning in their own way: **(a)** a detached child of the *failed*
  `ndt up ovs` run (16:00:09-16:05:17) that kept polling for a fabric on its own after the
  parent script had already reported failure and exited, and fired once my manual Terminal
  1+2 produced a real one around 16:08; or **(b)** `testbed_topo.py` (Terminal 2) itself
  starting a kernel as a side effect once its own setup finishes -- 59174's start time
  (16:08:38) sits right at the point my *first* `testbed_topo.py` run (16:08:19, the one that
  later crashed per my methodology note under BUG-2) would have been finishing its self-test
  and reaching "Final Configuration Active." I have deliberately not opened either script to
  settle this, per this test's own ground rules -- recording both candidates rather than
  guessing.
  Killing the one PID I had confirmed (`sudo kill -TERM 59174`, not a pattern-matched kill)
  ended it in under 3 seconds and released both `:6343` and `:8000` cleanly; my own Terminal 3
  then started normally.
- **Reproduced on a second try?** Not deliberately re-run a third time from scratch (that would
  mean redoing the ~15-minute BUG-1/BUG-2 sequence that originally produced it, for a process
  whose exact trigger I already can't isolate without the source-reading this test avoids) --
  but the process's *existence* was independently confirmed by two different tools agreeing
  with each other (`ss -ulnp` and `ps`), and its *effect* (blocking a legitimate Terminal 3)
  reproduced exactly once and was directly observed, not inferred.
- **Severity (my guess):** Medium-high. However it started, the practical failure mode is bad:
  `ndt down` reported a fully clean machine while a kernel process it did not know about kept
  running for at least 9 minutes (16:08:38 until I killed it at 16:18:44), `ndt status`
  described that process's state as an ordinary healthy run with no ownership attached, and the
  first symptom a user gets is an unrelated-looking bind failure on a port (`6343`, sFlow) that
  neither `ndt down`'s three checked ports (`8000`/`8080`/`8081`) nor its process-count check
  cover. A user who trusts "clean" after `ndt down` and then starts their own Terminal 3 by
  hand, as the manual instructs, hits exactly what I hit.
EOF
echo APPENDED
wc -l ~/BUGS.md
