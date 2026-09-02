#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## P4 toolchain build: both required binaries confirmed installed and working   18:11
what I did: `which p4c-bm2-ss` -> `/usr/local/bin/p4c-bm2-ss`, `p4c-bm2-ss --version` ->
`Version 1.2.5.17 (SHA: d46d824202 BUILD: Release)`; `which simple_switch_grpc` ->
`/usr/local/bin/simple_switch_grpc`, `--version` -> `1.15.6-1c8c9a4f`. Both answer for real,
not just "found on disk". Total elapsed for `install-p4dev-v8.sh` to build and install grpc,
PI, behavioral-model and p4c (the four components that matter for these two binaries): from
16:02:57 to ~18:11, about 2h08m on this VM's 4 vCPUs -- close to the manual's own "about two
hours on 4 vCPUs" reference figure. The script itself is still running in its tmux session
`p4` (now installing packages for the next component, mininet, going by the apt output in the
log -- tk8.6-blt2.5, libxss1, etc.), and per the manual's own guidance ("the check that
decides whether it worked is not its exit status but whether the two binaries exist
afterwards... check whether you need the full redo first") I am proceeding directly to Step
6.2 rather than waiting for the whole script (mininet/ptf/p4runtime-shell/tutorials) to finish
-- none of those remaining components are things NDTwin itself needs, and the manual's own
Section 3.2 already installed the apt-packaged Mininet this project actually uses.
EOF
echo APPENDED
