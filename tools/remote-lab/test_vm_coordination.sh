#!/usr/bin/env bash
# Mutation gate for the cross-session VM coordination guards.
# [Co-developed with claude code -- Adam]
#
# Every guard is exercised in BOTH directions. A guard that has only ever been seen
# to pass is not a guard -- and the mirror image is just as bad: 2026-08-31 shipped a
# readiness gate that could never go green. So each case below asserts a specific
# message, not merely an exit code, because several distinct failures share rc=1.
#
# Runs entirely on throwaway directories on this laptop. Touches no lab machine.
set -uo pipefail

# Resolve BOTH tools relative to this script, never by absolute path. A harness that
# names an absolute path tests whichever copy lives there -- which, once this file is
# in the repo and also in ~/.local, is not the copy the reader just checked out.
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
VM="$HERE/ndtwin-vm.sh"
RLAB="$HERE/rlab"
[ -x "$VM" ] && [ -x "$RLAB" ] || { echo "🔴 missing tools next to $0"; exit 2; }
echo "testing: $VM"
echo "         $RLAB"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

# expect <label> <want-rc> <want-substring> -- then the command on stdin
expect() {
    local label="$1" want_rc="$2" want="$3"; shift 3
    local out rc
    out=$("$@" 2>&1 </dev/null); rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want"; then
        printf '  ✅ %s\n' "$label"; pass=$((pass+1))
    else
        printf '  🔴 %s\n     want rc=%s containing %s\n     got  rc=%s: %s\n' \
            "$label" "$want_rc" "'$want'" "$rc" "$(printf '%s' "$out" | head -3 | tr '\n' '|')"
        fail=$((fail+1))
    fi
}

echo "=== G1  claim_guard: no NDT_OWNER ==="
mkdir -p "$T/a"
expect "RED  -- unset owner is refused"     1 "NDT_OWNER is not set" \
    env -u NDT_OWNER VM_DIR="$T/a" bash "$VM" destroy
expect "GREEN-- owner set, dir unclaimed"   1 "Type DESTROY" \
    env NDT_OWNER=mainDev VM_DIR="$T/a" bash "$VM" destroy

echo "=== G2  claim_guard: foreign claim ==="
mkdir -p "$T/b"
printf 'owner: bmv2paper\nsince: 2026-08-31T14:00:00+08:00\nport:  2222\nnote:  lab\n' > "$T/b/OWNER"
expect "RED  -- another session's VM is refused" 3 "belongs to another session" \
    env NDT_OWNER=mainDev VM_DIR="$T/b" bash "$VM" destroy
expect "RED  -- and it names the real owner"     3 "owner: bmv2paper" \
    env NDT_OWNER=mainDev VM_DIR="$T/b" bash "$VM" destroy
expect "GREEN-- the actual owner gets through"   1 "Type DESTROY" \
    env NDT_OWNER=bmv2paper VM_DIR="$T/b" bash "$VM" destroy

echo "=== G3  the override is not silent ==="
expect "GREEN-- NDTVM_FORCE=1 proceeds"          1 "recording the override" \
    env NDT_OWNER=mainDev NDTVM_FORCE=1 VM_DIR="$T/b" bash "$VM" destroy
if grep -q '^FORCED: mainDev took this from bmv2paper' "$T/b/OWNER"; then
    echo "  ✅ RED-for-the-next-reader -- the override wrote itself into OWNER"; pass=$((pass+1))
else
    echo "  🔴 override left no trace in OWNER"; fail=$((fail+1))
fi

echo "=== G4  port_guard ==="
mkdir -p "$T/c"; : > "$T/c/disk.qcow2"
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",34567)); s.listen(1); time.sleep(60)' &
HOLDER=$!
for _ in $(seq 1 20); do ss -tlnH 'sport = :34567' | grep -q . && break; sleep 0.2; done
expect "RED  -- a busy port is refused"      4 "is already listening" \
    env NDT_OWNER=mainDev VM_DIR="$T/c" SSH_PORT=34567 bash "$VM" start
expect "GREEN-- a free port gets past the guard" 1 "booting" \
    env NDT_OWNER=mainDev VM_DIR="$T/c" SSH_PORT=34568 bash "$VM" start
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "=== G5  generic snapshot tags (how the collision stayed invisible) ==="
mkdir -p "$T/d"; : > "$T/d/disk.qcow2"
expect "RED  -- 'fresh' is refused"          1 "too generic" \
    env NDT_OWNER=mainDev VM_DIR="$T/d" bash "$VM" snap fresh
expect "GREEN-- a purpose+date tag is allowed" 1 "snapshot failed" \
    env NDT_OWNER=mainDev VM_DIR="$T/d" bash "$VM" snap p4-toolchain-0831

echo "=== G8  the working point survives a restart (2026-08-31 silent downgrade) ==="
mkdir -p "$T/e"; : > "$T/e/disk.qcow2"; printf 'x' > "$T/e/disk.qcow2"
expect "RED  -- existing VM, no CONFIG, warns before booting" 1 "工作點來自 built-in default" \
    env NDT_OWNER=mainDev VM_DIR="$T/e" SSH_PORT=34570 bash "$VM" start
if grep -q '^cpus=12' "$T/e/CONFIG" 2>/dev/null; then
    echo "  ✅ and it recorded what it actually used"; pass=$((pass+1))
else
    echo "  🔴 CONFIG not written by start"; fail=$((fail+1))
fi
printf 'cpus=16\nmem=16384\ndisk=120G\nport=34570\n' > "$T/e/CONFIG"
expect "GREEN-- CONFIG is honoured with no env vars"  1 "16 vCPU, 16384MiB" \
    env NDT_OWNER=mainDev VM_DIR="$T/e" SSH_PORT=34570 bash "$VM" start
expect "GREEN-- and the warning is gone"              1 "CONFIG（這顆 VM 上次跑的工作點）" \
    env NDT_OWNER=mainDev VM_DIR="$T/e" SSH_PORT=34570 bash "$VM" start
expect "GREEN-- an explicit env var still overrides"  1 "8 vCPU, 4096MiB" \
    env NDT_OWNER=mainDev VM_DIR="$T/e" SSH_PORT=34570 VM_CPUS=8 VM_MEM=4096 bash "$VM" start
expect "RED  -- status names an unrecorded work point" 0 "next start falls back" \
    env NDT_OWNER=mainDev VM_DIR="$T/a" bash "$VM" status

echo "=== G9  'cannot read' must never be printed as 'there are none' ==="
# This is the defect that caused the duplicate `fresh` tag on 2026-08-31: the list
# failed under the qemu image lock and the script reported an empty disk.
# The fixture must produce a REAL open failure. A text file does not: qemu-img probes
# it as raw, and raw has zero snapshots -- which reads as a successful empty list. That
# is the same false-negative shape the guard exists to catch, so the first version of
# this test would have passed against the OLD broken code.
mkdir -p "$T/f"; qemu-img create -q -f qcow2 "$T/f/disk.qcow2" 16M; chmod 000 "$T/f/disk.qcow2"
expect "RED  -- unreadable list says so"      1 "COULD NOT READ" \
    env NDT_OWNER=mainDev VM_DIR="$T/f" bash "$VM" snaps
expect "RED  -- and snap refuses to add blind" 1 "refusing to add one blind" \
    env NDT_OWNER=mainDev VM_DIR="$T/f" bash "$VM" snap p4-toolchain-0831
expect "RED  -- and restore refuses too"       1 "refusing to restore blind" \
    env NDT_OWNER=mainDev VM_DIR="$T/f" bash "$VM" restore p4-toolchain-0831

mkdir -p "$T/g"; qemu-img create -q -f qcow2 "$T/g/disk.qcow2" 16M
expect "GREEN-- a genuinely empty disk says THAT instead" 0 "read successfully" \
    env NDT_OWNER=mainDev VM_DIR="$T/g" bash "$VM" snaps
qemu-img snapshot -c dup-tag "$T/g/disk.qcow2"
qemu-img snapshot -c dup-tag "$T/g/disk.qcow2"
expect "RED  -- duplicate tags are called out at read time" 0 "DUPLICATE TAG 'dup-tag'" \
    env NDT_OWNER=mainDev VM_DIR="$T/g" bash "$VM" snaps
expect "RED  -- restore refuses an ambiguous tag" 1 "matches 2 snapshots" \
    env NDT_OWNER=mainDev VM_DIR="$T/g" bash "$VM" restore dup-tag
expect "RED  -- snap refuses to create a third one" 1 "already exists on this disk" \
    env NDT_OWNER=mainDev VM_DIR="$T/g" bash "$VM" snap dup-tag
expect "GREEN-- a fresh unique tag is accepted"  0 "ACCEPTANCE" \
    env NDT_OWNER=mainDev VM_DIR="$T/g" bash "$VM" snap p4-toolchain-0831

echo "=== G6  vms is readable without owning anything ==="
expect "GREEN-- no NDT_OWNER needed to look"  0 "OWNER" \
    env -u NDT_OWNER HOME="$T" bash "$VM" vms

echo "=== G7  rlab suspension refuses before dialling ==="
expect "RED  -- nslab refused"                4 "PAUSED (not suspended)" \
    env bash "$RLAB" status nslab
expect "RED  -- and it says who, when and the unpause condition" 4 "the rules land" \
    env bash "$RLAB" status nslab
expect "RED  -- server8 refused too"          4 "遠端機器先不要用" \
    env bash "$RLAB" status server8
expect "RED  -- no stale redirect offered"    4 "another machine: NONE" \
    env bash "$RLAB" status server8
# GREEN direction for the suspension table itself: a machine NOT in it must fall
# through to the normal unknown-machine path, proving suspended() is not a blanket deny.
expect "GREEN-- an unlisted machine is not swallowed" 2 "unknown machine" \
    env bash "$RLAB" status laptop

printf '\n=== %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" = 0 ]
