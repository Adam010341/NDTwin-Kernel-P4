# BEFORE arm captured by the auditor (2026-09-03 21:4x)

Your session was killed by API 529 three times while this fabric was up; I captured what the BEFORE arm needs and tore the fabric down so the lab is not left running unattended.

- processes.txt        : ps at capture time -- the topo process is /home/adam/Network-Traffic-Generator/testbed_topo.py (the NTG copy), started via the MAIN checkout's ndtwin-lab (supervise.sh under /home/adam/Desktop/NDTwin-Kernel/.test_run/pids)
- topo-sha.txt         : sha256 of NTG's copy (ead4d84a...) vs this repo's testbed_topo.py (efbc4f88...) -- they differ, as finding #77 says
- (no banner capture)  : the NTG topo's stdout lives only in the root-owned tmux pane (`tmux -L ndtwinlab`, socket /tmp/tmux-0); `sudo tmux` is NOT in the passwordless sudo list, so it cannot be read from user space -- do not try. For the AFTER arm, make your banner evidence come from a file: ndtwin-lab's own log if it writes one, or run this repo's testbed_topo.py the way ndtwin-lab will with its stdout redirected. The BEFORE arm's control-plane side is in /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/ryu.log (21:36-21:46 window).
- ndt-status.txt       : NDT_OWNER=ovstopo ndt status while up (topo session present, :8000 kernel open, host/switch 139)
- ndt-down.txt         : teardown from the main checkout, all five verify-clean assertions ok
- ndt-release.txt      : release from the main checkout; the main-checkout claim copy was removed by me
- lab.claim.copy       : the claim as it stood

Your worktree's own .test_run/lab.claim is untouched -- run `ndt release` there yourself. Continue with the AFTER arm on your branch; claim again (both files) before `ndt up ovs`. Note that `ndt down` kills process groups broadly: run it under `setsid` with output to a file, or your own shell may die with it (mine did, exit 144).
