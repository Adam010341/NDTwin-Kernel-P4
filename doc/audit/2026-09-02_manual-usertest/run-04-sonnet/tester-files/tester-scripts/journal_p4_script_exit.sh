#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## P4 toolchain: install-p4dev-v8.sh reached SCRIPT_EXIT=0   18:16
what I did: the full `install-p4dev-v8.sh` run (grpc, PI, behavioral-model, p4c, mininet, ptf,
p4runtime-shell, tutorials) finished on its own, `grep -c SCRIPT_EXIT ~/log.txt` -> 1,
`SCRIPT_EXIT=0`. Total wall time 16:02:57 -> ~18:16, about **2h13m** on this VM's 4 vCPUs --
consistent with the manual's own "about two hours on 4 vCPUs" reference. Per the manual's own
framing, exit 0 says the script ended, not that it succeeded -- the acceptance check is the two
binaries, which I had already confirmed answering `--version` about 5 minutes earlier and had
already used to finish Installation Section 6.2-6.6 while this tail end (mininet/ptf/etc, none
of which NDTwin itself needs) kept running in the background.
EOF
echo APPENDED
