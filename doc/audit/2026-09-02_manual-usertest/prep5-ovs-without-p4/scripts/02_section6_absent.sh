#!/bin/bash
# A-8 step 1: establish that Installation Manual Section 6 (P4/BMv2) was never done on this guest.
# Also record the kernel commit and the docs snapshot the guest actually has.
# [Co-developed with claude code -- Adam]
echo "=== A-8 / SECTION 6 ABSENCE EVIDENCE  $(date -u +%FT%TZ) ==="
echo "host=$(hostname) user=$(id -un) kernel=$(uname -r)"
echo "os=$(. /etc/os-release; echo "$PRETTY_NAME")"
echo

echo "########## 1. P4 / BMv2 BINARIES ON PATH ##########"
for b in simple_switch simple_switch_grpc simple_switch_CLI p4c p4c-bm2-ss bm_CLI \
         protoc grpc_cpp_plugin mn ovs-vsctl ovs-ofctl ryu-manager iperf3; do
  p=$(command -v "$b" 2>/dev/null)
  if [ -n "$p" ]; then echo "PRESENT  $b -> $p"; else echo "ABSENT   $b"; fi
done
echo
echo "--- explicit which(1) for the four the ledger names ---"
which simple_switch_grpc p4c-bm2-ss simple_switch p4c 2>&1; echo "WHICH_EXIT=$?"
echo
echo "--- any simple_switch* / p4c* anywhere in the usual prefixes ---"
ls -l /usr/local/bin/simple_switch* /usr/local/bin/p4c* /usr/bin/simple_switch* /usr/bin/p4c* 2>&1
echo
echo "--- ldconfig: bmv2 / PI / p4runtime shared libs ---"
ldconfig -p 2>/dev/null | grep -Ei 'bmv2|simpleswitch|libpi|p4runtime|libbm' || echo "(no bmv2/PI/p4runtime libs in ldconfig cache)"
echo
echo "--- dpkg: any p4 / bmv2 / protobuf / grpc packages ---"
dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' | grep -Ei '^(p4|bmv2|libbm|protobuf|libprotobuf|grpc|libgrpc)' || echo "(no p4/bmv2/protobuf/grpc dpkg packages)"
echo

echo "########## 2. SECTION 6 SOURCE TREES ##########"
for d in ~/p4-guide ~/behavioral-model ~/p4c ~/PI ~/grpc ~/protobuf ~/p4runtime ~/p4setup.bash; do
  e=$(eval echo "$d")
  if [ -e "$e" ]; then echo "PRESENT  $e"; ls -ld "$e"; else echo "ABSENT   $e"; fi
done
echo
echo "--- full listing of \$HOME (top level) ---"
ls -la ~/
echo
echo "--- any p4dev-python-venv anywhere under \$HOME ---"
find ~ -maxdepth 4 -name 'p4dev-python-venv' -o -maxdepth 4 -name 'p4setup.bash' 2>/dev/null | sed 's/^/FOUND: /' || true
echo "(end find)"
echo

echo "########## 3. p4_proxy venv + COMPILED PIPELINE ##########"
R=~/Desktop/NDTwin-Kernel
for f in "$R/p4_proxy/venv" "$R/p4_proxy/venv/bin/python" \
         "$R/p4_proxy/p4_src/build/ndtwin_switch.json" "$R/p4_proxy/p4_src/build"; do
  if [ -e "$f" ]; then echo "PRESENT  $f"; ls -ld "$f"; else echo "ABSENT   $f"; fi
done
echo
echo "--- p4_proxy tree as it actually is ---"
ls -la "$R/p4_proxy" 2>&1 | head -30
echo
echo "--- p4_src tree ---"
find "$R/p4_proxy/p4_src" -maxdepth 2 2>/dev/null | head -40 || echo "(no p4_src)"
echo

echo "########## 4. KERNEL COMMIT THE GUEST ACTUALLY HAS ##########"
git -C "$R" rev-parse HEAD 2>&1
git -C "$R" log -1 --format='%H%n%h%n%ad%n%s' --date=iso 2>&1
echo "--- remotes ---"
git -C "$R" remote -v 2>&1
echo "--- status (porcelain, first 20) ---"
git -C "$R" status --porcelain 2>&1 | head -20
echo "--- built kernel binary present? ---"
ls -l "$R/build/ndtwin_kernel" 2>&1
echo "--- CMake dependency lines (what the kernel actually requires) ---"
grep -nEi 'find_package|pkg_check_modules' "$R/CMakeLists.txt" 2>&1 | head -30
echo "--- any protobuf/grpc/PI mention in the kernel CMakeLists ---"
grep -nEi 'protobuf|grpc|\bPI\b|p4runtime|bmv2' "$R/CMakeLists.txt" 2>&1 || echo "(zero protobuf/grpc/PI/p4runtime/bmv2 mentions in CMakeLists.txt)"
echo

echo "########## 5. DOCS SNAPSHOT IN ~/ndtwin-docs ##########"
if [ -d ~/ndtwin-docs ]; then
  echo "PRESENT ~/ndtwin-docs"
  git -C ~/ndtwin-docs rev-parse HEAD 2>&1
  git -C ~/ndtwin-docs log -1 --format='%H %h %ad %s' --date=iso 2>&1
  echo "md count: $(find ~/ndtwin-docs -name '*.md' | wc -l)"
  find ~/ndtwin-docs -name '*.md' | sort | head -60
else
  echo "ABSENT ~/ndtwin-docs"
  echo "--- looking for any docs copy elsewhere ---"
  find ~ -maxdepth 3 -type d \( -name '*docs*' -o -name '*website*' -o -name '*ndtwin*' \) 2>/dev/null | head -20
fi
echo

echo "########## 6. WHAT §1-§5 DID LEAVE ##########"
echo "--- ovs ---"; ovs-vsctl --version 2>&1 | head -2; sudo -n ovs-vsctl show 2>&1 | head -20
echo "--- mininet ---"; dpkg -l mininet 2>/dev/null | tail -2; python3 -c 'import mininet,sys; print("mininet import OK", mininet.__file__)' 2>&1
echo "--- ryu ---"; command -v ryu-manager; python3 -c 'import ryu; print("ryu", ryu.version.version if hasattr(ryu,"version") else "?")' 2>&1 | head -3
echo "--- conda / ntg-env (prediction 2) ---"
ls -ld ~/miniconda3 2>&1
ls -ld ~/miniconda3/envs/ntg-env 2>&1
ls -l ~/miniconda3/envs/ntg-env/bin/python 2>&1
echo "--- ndt CLI ---"; ls -l /usr/local/sbin/ndtwin-lab /usr/local/bin/ndt 2>&1; command -v ndt
echo
echo "SECTION6_EVIDENCE_EXIT=0"
