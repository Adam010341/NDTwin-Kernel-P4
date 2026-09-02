#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Section 6: P4 / BMv2 Data Plane (Installation)   started 16:02   ended 18:12   friction: 2
what I did: Step 6.0 confirmed `p4_proxy/p4_src/ndtwin_switch.p4` exists (already true since
Section 4.1 cloned the P4-public repo). Step 6.1: checked `python3 --version` was 3.12.x (not
ryu-env's 3.8) before starting, cloned `p4-guide`, launched
`./p4-guide/bin/install-p4dev-v8.sh` inside a detached tmux session exactly as the manual's own
"run it detached" box shows. This is the long step the manual warns about -- total time from
launch to both required binaries answering `--version` was **about 2h08m** on this VM's 4
vCPUs, close to the manual's own "about two hours on 4 vCPUs" figure. Versions:
`simple_switch_grpc 1.15.6-1c8c9a4f`, `p4c-bm2-ss 1.2.5.17 (SHA: d46d824202)` -- both an exact
match for the manual's own worked example for 2026-09-02, a satisfying confirmation the
manual's dated claims are not decorative. Followed the manual's own advice to judge readiness
by the two binaries rather than the script's exit status, and moved on to Step 6.2 while the
script's remaining components (mininet, ptf, p4runtime-shell, tutorials) kept running in the
background -- none of those are things NDTwin itself needs.
Steps 6.2-6.6 all went smoothly: `p4c-bm2-ss` compiled `ndtwin_switch.p4` cleanly (two benign
warnings only: an unused constant, a deprecated output-format notice); the proxy's Python 3.12
venv built and every pinned requirement (`protobuf==3.20.3` included) installed without
conflict; `AppConfig.hpp` already had the correct proxy port and mixed-dataplane flag from the
original Section 4.2 build, so no edit/rebuild was needed; `host_count_override` set to 128;
and `bmv2_binary_override` -- which shipped pointed at the not-yet-built `bmv2-fast` path, with
an unusually detailed comment already in the file explaining a specific prior finding about
why (a debug build's throughput ceiling masking a downstream app's traffic-sensitivity) -- was
switched to the stock `/usr/local/bin/simple_switch_grpc` per the manual's own instruction for
readers who skip Step 6.7, which I did (optional-of-optional, cut for time). Confirmed the
selected path is a real, executable binary before moving on.
Skipped Step 6.7 (the `-O3` "bmv2-fast" performance rebuild) entirely -- the manual itself
frames it as optional on top of an already-optional section, and building BMv2 a second time
from a fresh clone was not worth the extra time against the 90-minute floor this run owes the
use-and-break phase.
verdict: 2 needed a workaround -- none from the manual's own steps (every one of 6.0-6.6
matched exactly), the friction was entirely mine: the two "second stop" incidents recorded
earlier in this journal happened during this section's long wait, not because of anything the
build did.
EOF
echo APPENDED
