#!/bin/bash
# Prepare the common starting point for the tty/no-tty A/B on install-p4dev-v10.sh.
#
# Why this step exists at all: last night's overnight run returned rc=0 with bmv2 missing,
# and the log named the reason --
#     + '[' -d behavioral-model ']'
#     Found directory /home/tester/behavioral-model.  Assuming ... already installed.
#     p4lang/behavioral-model install: 0 sec
# It skipped the build because the 23:00 partial run had left the directory behind. That is
# PREREG confounder #3 firing exactly as written. So the single most important property of
# the base is NOT "which snapshot" -- it is "no p4 artifacts of any kind are present", and
# that has to be ASSERTED, not assumed. A dirty base does not fail loudly; it produces a
# confident rc=0 and a wrong answer.
#
# p4-guide is cloned and pinned HERE, in the shared base, so both arms compile the identical
# commit. That removes PREREG confounder #4 (upstream moving between arms) completely rather
# than merely recording it.
# [Co-developed with claude code -- Adam]
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_SNAP="${BASE_SNAP:-post-6.6-16h26}"
PIN="${PIN:-a2f9f8c5fd64f37d10ea2ce06f8821893a79a841}"
SSH="ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30 tester@localhost"

say() { echo; echo "=== $* ==="; }

say "1. stop VM and restore '$BASE_SNAP'"
bash "$DIR/vm.sh" stop
bash "$DIR/vm.sh" restore "$BASE_SNAP" || { echo "ABORT: restore failed"; exit 1; }

say "2. boot"
bash "$DIR/vm.sh" start || { echo "ABORT: start failed"; exit 1; }
bash "$DIR/wait_ssh.sh" || { echo "ABORT: no ssh"; exit 1; }

say "3. FRESHNESS ASSERTION -- the base must carry no p4 artifacts"
# Each check writes a state word. We count DIRTY findings rather than trusting any single
# command's exit status, and we look on disk (ls) as well as on PATH (command -v): last
# night proved a PATH-only probe can disagree with the disk in either direction.
# ~/p4-guide is deliberately NOT in this list. The list's purpose is "nothing present can
# make the installer skip a build step or pick up a pre-built artifact". p4-guide is the
# installer's own source tree -- it causes no skip, and step 6 below `rm -rf`s it and
# re-clones at the pin regardless. Excluding it narrows the check to its stated purpose;
# the same pass ADDS the /usr/local build outputs the v10 log showed it probing
# (`objdump: '/usr/local/lib/libprotobuf.a'`), so the check is net stricter, not looser.
dirty=$($SSH 'bash -s' <<'EOF'
n=0
for d in ~/behavioral-model ~/p4c ~/PI ~/tutorials ~/p4setup.bash ~/p4setup.csh ~/.local; do
    if [ -e "$d" ]; then echo "DIRTY: $d exists"; n=$((n+1)); fi
done
for b in /usr/local/bin/p4c-bm2-ss /usr/local/bin/simple_switch /usr/local/bin/simple_switch_grpc \
         /usr/local/bin/p4c /usr/local/lib/libprotobuf.a /usr/local/include/bm; do
    if [ -e "$b" ]; then echo "DIRTY: $b exists"; n=$((n+1)); fi
done
for g in /usr/local/lib/libbm* /usr/local/lib/libsimpleswitch* /usr/local/lib/libpi*; do
    if [ -e "$g" ]; then echo "DIRTY: $g exists"; n=$((n+1)); fi
done
for c in simple_switch_grpc simple_switch p4c-bm2-ss p4c; do
    if command -v "$c" >/dev/null 2>&1; then echo "DIRTY: $c on PATH"; n=$((n+1)); fi
done
echo "DIRTY_COUNT=$n"
EOF
)
echo "$dirty"
count=$(printf '%s\n' "$dirty" | sed -n 's/^DIRTY_COUNT=//p')
if [ "${count:-unknown}" != "0" ]; then
    echo
    echo "ABORT: base '$BASE_SNAP' is not clean (DIRTY_COUNT=${count:-unknown})."
    echo "       Re-run with BASE_SNAP=fresh -- do NOT proceed on a dirty base."
    exit 1
fi
echo "base is clean (DIRTY_COUNT=0)"

say "4. record what the base DOES have (for the write-up)"
$SSH 'bash -s' <<'EOF'
echo "os:      $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "kernel:  $(uname -r)"
echo "cpus:    $(nproc)   mem: $(free -g | awk "NR==2{print \$2}") GiB"
echo "disk:    $(df -h / | awk "NR==2{print \$4}") free"
echo "git:     $(git --version 2>&1 | head -1)"
echo "python3: $(python3 --version 2>&1)"
echo "conda:   $(ls -d ~/miniconda3 2>/dev/null || echo absent)"
EOF

say "5. install tmux (used by the TTY arm; present in BOTH arms so it cannot explain a difference)"
$SSH 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q tmux >/dev/null 2>&1; echo "tmux: $(tmux -V 2>&1)"'

say "6. clone p4-guide and PIN it -- both arms get this identical commit"
$SSH "bash -s" <<EOF
set -u
cd ~ || exit 1
rm -rf ~/p4-guide
git clone -q https://github.com/jafingerhut/p4-guide || { echo "CLONE FAILED"; exit 1; }
git -C ~/p4-guide checkout -q "$PIN" || { echo "CHECKOUT OF PIN FAILED"; exit 1; }
echo "p4-guide HEAD: \$(git -C ~/p4-guide rev-parse HEAD)"
echo "expected PIN : $PIN"
if [ "\$(git -C ~/p4-guide rev-parse HEAD)" = "$PIN" ]; then echo "PIN_OK"; else echo "PIN_MISMATCH"; fi
ls -l ~/p4-guide/bin/install-p4dev-v10.sh
sha256sum ~/p4-guide/bin/install-p4dev-v10.sh
EOF

say "7. stop and snapshot as 'ab-base'"
bash "$DIR/vm.sh" stop || { echo "ABORT: stop failed -- refusing to snapshot a live disk"; exit 1; }
qemu-img snapshot -d ab-base "$DIR/disk.qcow2" 2>/dev/null   # replace any earlier attempt
bash "$DIR/vm.sh" snap ab-base || { echo "ABORT: snapshot failed"; exit 1; }
qemu-img snapshot -l "$DIR/disk.qcow2"

echo
echo "BASE READY. Both arms will start from 'ab-base'."
