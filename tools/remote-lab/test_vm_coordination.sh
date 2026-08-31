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
# readlink -f, not dirname $0: this file is symlinked from ~/.local, and $0's directory
# would then be the symlink's home -- where the tools are not. Resolve to the real file
# so the harness always tests the copy it actually lives beside.
HERE=$(dirname -- "$(readlink -f -- "$0")")
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

echo "=== G7  the suspension table: refuses the suspended, lets the unpaused past ==="
# Asked through `rlab suspended`, which answers WITHOUT dialling. Finding out by trying
# is exactly what a stop order forbids -- and a table observable only through its own
# refusals cannot be tested in the direction that matters: that it lets the right
# things past. 2026-08-31 exercised both directions for real: nslab was paused in the
# afternoon and unpaused the same evening once its usage rules landed.
expect "RED  -- a suspended machine is refused"  4 "遠端機器先不要用" \
    env bash "$RLAB" suspended server8
expect "RED  -- and it names who and when"       4 "學姐 via Adam" \
    env bash "$RLAB" suspended server8
expect "GREEN-- an UNPAUSED machine is let past" 0 "not suspended" \
    env bash "$RLAB" suspended nslab
expect "GREEN-- and it still points at the rules" 0 "register BEFORE you act" \
    env bash "$RLAB" suspended nslab
expect "GREEN-- an unlisted machine is not swallowed" 2 "unknown machine" \
    env bash "$RLAB" suspended laptop
# The guard that actually matters sits in rssh, so every verb inherits it -- prove it
# there too, not only in the verb built to report it.
expect "RED  -- rssh refuses before any packet leaves" 4 "Nothing was sent" \
    env bash "$RLAB" status server8

echo
echo "=== G9  the two verbs the gate itself missed (stop, ssh) ==="
# 🔴 Found 2026-08-31 while reading this script for an unrelated reason: `stop` and
# `ssh` mutate and had NO claim_guard, and this gate was 32/32 green anyway. The gate
# enumerated the guards that existed, so it could only ever confirm them -- it had no
# way to notice a verb that had been left out. That is a coverage hole shaped exactly
# like the finding: a check that cannot fail for the reason you care about.
mkdir -p "$T/h"
printf 'owner: bmv2paper\nsince: 2026-08-31T14:00:00+08:00\nport:  2222\nnote:  B round\n' > "$T/h/OWNER"

expect "RED  -- stop refuses another session's VM"     3 "belongs to another session" \
    env NDT_OWNER=mainDev VM_DIR="$T/h" bash "$VM" stop
expect "RED  -- stop refuses when NDT_OWNER is unset"  1 "NDT_OWNER is not set" \
    env -u NDT_OWNER VM_DIR="$T/h" bash "$VM" stop
expect "GREEN-- stop proceeds on your own VM"          0 "not running" \
    env NDT_OWNER=bmv2paper VM_DIR="$T/h" bash "$VM" stop
expect "RED  -- ssh refuses another session's VM"      3 "belongs to another session" \
    env NDT_OWNER=mainDev VM_DIR="$T/h" bash "$VM" ssh true
expect "RED  -- ssh refuses when NDT_OWNER is unset"   1 "NDT_OWNER is not set" \
    env -u NDT_OWNER VM_DIR="$T/h" bash "$VM" ssh true

# 🔑 The green direction that matters most for ssh is NOT "it connects" -- it is that
# guarding it did not quietly turn it into a claim. §5b of the rules requires that an
# UNOWNED VM pending retirement can still be inspected without anyone taking it, and
# the 08-31 .git inventory depended on exactly that. claim_guard refuses; claim_write
# records; only create/start call the latter. Prove the separation, do not trust it.
mkdir -p "$T/i"
env NDT_OWNER=mainDev VM_DIR="$T/i" SSH_PORT=34599 bash "$VM" ssh true >/dev/null 2>&1
if [ ! -f "$T/i/OWNER" ]; then
    echo "  ✅ GREEN-- ssh on an UNOWNED VM did not claim it (no OWNER written)"; pass=$((pass+1))
else
    echo "  🔴 ssh created an OWNER file -- inspecting a VM now takes it, which §5b forbids"
    fail=$((fail+1))
fi

echo
echo "=== G10 structural: every mutating verb is guarded (the test that would have caught G9) ==="
# Counting guards can only ever re-confirm the guards you remembered to write. This
# asserts over the VERBS instead, so the next verb added to the dispatch fails here
# until someone decides, in writing, which list it belongs to.
MUTATING="create start stop snap restore destroy ssh"
READONLY="status snaps vms"
verb_block() {  # print the case-arm body for verb $1
    awk -v v="$1" '$0 ~ "^"v"\\)$" {f=1; next} f && /^[[:space:]]*;;/ {exit} f' "$VM"
}
for v in $MUTATING; do
    if verb_block "$v" | grep -q 'claim_guard'; then
        printf '  ✅ RED-capable -- %s calls claim_guard\n' "$v"; pass=$((pass+1))
    else
        printf '  🔴 %s mutates but has NO claim_guard\n' "$v"; fail=$((fail+1))
    fi
done
# The green direction of the structural test: read-only verbs must STAY unguarded.
# `vms` especially -- asking who holds what must not require already holding something,
# or the first session willing to yield is the one locked out.
for v in $READONLY; do
    if verb_block "$v" | grep -q 'claim_guard'; then
        printf '  🔴 %s is read-only but demands ownership\n' "$v"; fail=$((fail+1))
    else
        printf '  ✅ GREEN-- %s stays readable without owning anything\n' "$v"; pass=$((pass+1))
    fi
done
# And the control for the parser itself: if verb_block returned nothing for every verb,
# every check above would pass vacuously. Prove it can actually see a known guard.
if verb_block destroy | grep -q 'claim_guard destroy'; then
    echo "  ✅ CONTROL -- the block parser really reads the dispatch"; pass=$((pass+1))
else
    echo "  🔴 CONTROL FAILED -- verb_block found nothing; every G10 result above is vacuous"
    fail=$((fail+1))
fi


printf '\n=== %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" = 0 ]
