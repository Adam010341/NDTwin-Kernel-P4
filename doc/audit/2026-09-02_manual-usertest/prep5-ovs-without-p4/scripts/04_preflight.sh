#!/bin/bash
# A-8 step 2 pre-flight: the manual's own Pre-flight Checks + whether the manual's literal
# Terminal-1 line ("conda activate ryu-env") works in a shell on this machine.
# [Co-developed with claude code -- Adam]
R=~/Desktop/NDTwin-Kernel
echo "=== A-8 PRE-FLIGHT  $(date -u +%FT%TZ) ==="
echo
echo "### Manual Pre-flight Check 1: NDTwin-Kernel in ~/Desktop ###"
ls -d "$R" && echo "PF1=PASS" || echo "PF1=FAIL"
echo
echo "### Manual Pre-flight Check 2: ndtwin_kernel exists in build/bin/ ###"
ls -l "$R/build/bin/ndtwin_kernel" && echo "PF2=PASS" || echo "PF2=FAIL"
sha256sum "$R/build/bin/ndtwin_kernel"
file "$R/build/bin/ndtwin_kernel" 2>/dev/null
echo "--- does the built binary link anything P4/gRPC/protobuf? (the whole question, in one command) ---"
ldd "$R/build/bin/ndtwin_kernel" 2>&1 | sed 's/^/  /'
echo "--- grep that ldd output for p4/bmv2/grpc/protobuf ---"
ldd "$R/build/bin/ndtwin_kernel" 2>/dev/null | grep -Ei 'grpc|protobuf|bm2|bmv2|p4|libpi' || echo "NONE: the kernel binary links no gRPC/protobuf/P4/BMv2 library"
echo
echo "### Manual Pre-flight Check 3: testbed_topo.py exists ###"
ls -l "$R/testbed_topo.py" && echo "PF3=PASS" || echo "PF3=FAIL"
echo
echo "### topology model file the manual passes ###"
ls -l "$R/setting/StaticNetworkTopologyMininet_10Switches.json"
echo
echo "### tmux ###"
command -v tmux && tmux -V || echo "tmux ABSENT"
tmux ls 2>&1 || true
echo
echo "### the manual's literal Terminal 1 line: does 'conda activate ryu-env' work? ###"
echo "--- is conda on PATH in a NON-interactive shell? ---"
command -v conda || echo "conda NOT on PATH (non-interactive)"
echo "--- is conda initialised in ~/.bashrc? ---"
grep -n 'conda initialize\|conda.sh\|miniconda3/bin' ~/.bashrc ~/.profile 2>/dev/null || echo "NO conda-init block in ~/.bashrc or ~/.profile"
echo "bashrc bytes: $(wc -c < ~/.bashrc)  (stock Ubuntu 24.04 = 3771)"
echo "--- try it exactly as the manual writes it, in an interactive login shell ---"
bash -lic 'conda activate ryu-env && echo "CONDA_ACTIVATE=OK env=$CONDA_DEFAULT_ENV py=$(command -v python)" && command -v ryu-manager' 2>&1 | tail -8
echo "MANUAL_CONDA_LINE_EXIT=$?"
echo "--- fallback that does work, for the record ---"
bash -c 'source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && echo "FALLBACK=OK env=$CONDA_DEFAULT_ENV" && ryu-manager --version && python --version' 2>&1 | tail -6
echo
echo "### ports that must be free before we start ###"
for p in 6633 6653 8000 8080 6343; do
  echo -n "port $p: "; ss -tlnH "sport = :$p" 2>/dev/null | head -1 || true
  ss -tlnH "sport = :$p" 2>/dev/null | grep -q . && echo " OCCUPIED" || echo "free"
done
echo "--- udp 6343 ---"; ss -ulnH 'sport = :6343' 2>/dev/null | head -2; echo "(end)"
echo
echo "### any leftover mininet/ovs state ###"
sudo -n ovs-vsctl show 2>&1 | head -20
ps -eo comm= | sort -u | grep -Ei 'ryu|mininet|ndtwin|ovs-vsw' || echo "(no ryu/mininet/ndtwin processes by comm)"
echo
echo "PREFLIGHT_EXIT=0"
