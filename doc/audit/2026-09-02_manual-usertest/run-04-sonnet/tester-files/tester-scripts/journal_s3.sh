#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Section 3: System Dependencies Installation   started 15:45   ended 15:49   friction: 0
what I did: `conda deactivate` first (manual's own red warning to leave ryu-env before this
section). Step 3.1: build-essential, cmake, g++, make, git, ninja-build, xterm, curl,
wireshark, iperf3 with DEBIAN_FRONTEND=noninteractive -- no debconf hang (the manual's own
warning about the iperf3 daemon-autostart dialog was correctly avoided by following its
instruction). Step 3.2: libboost-all-dev (pulled in a large Fortran/MPI/coarray dependency
chain -- openmpi, gfortran, libcoarrays -- this is apt resolving Boost's optional MPI
components, not anything NDTwin-specific, but it made this the single biggest download of the
whole section), libfmt-dev, libspdlog-dev, libssh-dev, nlohmann-json3-dev, python3-venv,
mininet, openvswitch-switch. Step 3.3 verification block matched the manual's expected output
on every line: `systemctl is-active openvswitch-switch` -> active, `ovs-vsctl show` -> version
line only (no bridges yet, as the manual says is correct pre-Section-5), `sudo mn --test
pingall` -> "*** Results: 0% dropped (2/2 received)".
verdict: 0 smooth.
EOF
echo APPENDED
