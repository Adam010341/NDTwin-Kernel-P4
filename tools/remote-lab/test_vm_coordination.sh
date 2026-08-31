#!/usr/bin/env bash
# Mutation gate for the cross-session VM coordination guards.
# [Co-developed with claude code -- Adam]
#
# ===========================================================================
#  THE DESIGN CRITERION FOR THIS FILE -- read before adding a case.
#
#  Enumerate the SURFACE, not the protections that happen to exist.
#
#  On 2026-08-31 this gate was 32/32 green while `stop` and `ssh` -- both of
#  which mutate -- had no guard at all. It could not have caught that: it
#  listed the guards I had written, so it could only ever re-confirm them.
#
#      "every guard fires in both directions"
#  and "every mutating verb has a guard"
#  are DIFFERENT QUESTIONS, and I reported the answer to the first as though
#  it answered the second.
#
#  So G10 asserts over the verbs themselves, from two written-down lists. A
#  new verb fails there until someone decides, in writing, which list it is
#  in. And G10 carries its own control, because a parser that matches nothing
#  would let all of its checks pass vacuously -- a structural test with no
#  control is just the next silent green.
# ===========================================================================
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
MUTATING="create start stop snap restore destroy ssh keep adopt"
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
# 🔴 G10a -- COMPLETENESS. Added 2026-08-31 because everything above it was still the
# wrong shape, one level up. G9 was missed because the gate enumerated the guards I had
# written; G10 replaced that with two lists of verbs -- which I then described in the
# README as "the next verb added will go red here until someone classifies it". It
# would not have. Adding `keep` to the dispatch produced eleven greens and no red,
# because the loops iterate MY LISTS, never the dispatch. The same mistake, promoted:
# a gate can only ever check the population it derives from, so the population has to
# come from the thing under test. Here that means the case labels themselves.
DISPATCH_VERBS=$(awk '/^case "\$\{1:-\}" in/{f=1; next} /^esac/{exit}
                      f && /^[a-z][a-z-]*\)$/ {sub(/\)$/,""); print}' "$VM")
unclassified=""
for v in $DISPATCH_VERBS; do
    case " $MUTATING $READONLY " in *" $v "*) ;; *) unclassified="$unclassified $v" ;; esac
done
if [ -z "$unclassified" ]; then
    printf '  ✅ COMPLETE -- all %s dispatch verbs are classified (%s)\n' \
        "$(printf '%s\n' $DISPATCH_VERBS | wc -l)" "$(echo $DISPATCH_VERBS | tr ' ' ',')"
    pass=$((pass+1))
else
    printf '  🔴 UNCLASSIFIED verb(s) in the dispatch:%s\n' "$unclassified"
    echo  "     Neither list covers them, so G10 said nothing about them at all."
    echo  "     Decide in writing: does it mutate a shared VM, or only read?"
    fail=$((fail+1))
fi
# Control for THIS check: if the label parser found nothing, the completeness result
# above is vacuous in exactly the way it was written to prevent.
if printf '%s\n' $DISPATCH_VERBS | grep -qx destroy && printf '%s\n' $DISPATCH_VERBS | grep -qx vms; then
    echo "  ✅ CONTROL -- the label parser really enumerates the dispatch"; pass=$((pass+1))
else
    echo "  🔴 CONTROL FAILED -- label parser found no verbs; G10a is vacuous"; fail=$((fail+1))
fi


echo
echo "=== G11 destroy must take the registry entry with it (found by mainDev, 08-31) ==="
# `destroy` used to remove IMG/SEED/PIDF/MON and leave OWNER and CONFIG behind, so
# `vms` went on listing a VM that no longer had a disk -- owner, port and all. The
# next reader sees an occupancy and works around a ghost.
mkdir -p "$T/j"
printf 'owner: mainDev\nsince: x\nport:  2245\nnote:  E round\n' > "$T/j/OWNER"
printf 'cpus=12\nmem=8192\ndisk=120G\nport=2245\n' > "$T/j/CONFIG"
: > "$T/j/noble-base.img"          # the deliberately-kept base image
qemu-img create -q -f qcow2 "$T/j/disk.qcow2" 8M 2>/dev/null || : > "$T/j/disk.qcow2"
DOUT=$(printf 'DESTROY\n' | env NDT_OWNER=mainDev VM_DIR="$T/j" SSH_PORT=2245 bash "$VM" destroy 2>&1)

for f in disk.qcow2 OWNER CONFIG; do
    if [ ! -e "$T/j/$f" ]; then
        printf '  ✅ RED-capable -- destroy removed %s\n' "$f"; pass=$((pass+1))
    else
        printf '  🔴 destroy left %s behind -- vms will still show an occupancy\n' "$f"
        fail=$((fail+1))
    fi
done
# GREEN: the base image is kept ON PURPOSE, so a re-create need not re-download.
# Without this case, "delete everything" would pass the three checks above.
if [ -e "$T/j/noble-base.img" ]; then
    echo "  ✅ GREEN-- the base image is still kept (re-create must not re-download)"; pass=$((pass+1))
else
    echo "  🔴 destroy deleted the base image too"; fail=$((fail+1))
fi
# The old message named ONLY the base image. It was true, and that is precisely why
# it misled: disclosing one leftover reads as the complete list of leftovers.
if printf '%s' "$DOUT" | grep -q 'What is still in' && printf '%s' "$DOUT" | grep -q 'noble-base.img'; then
    echo "  ✅ GREEN-- destroy enumerates what actually remains, not one example"; pass=$((pass+1))
else
    echo "  🔴 destroy's closing message does not list the real residue"; fail=$((fail+1))
fi

echo
echo "=== G12 vms must not report a disk-less directory as an occupancy ==="
# 🔑 `vms` enumerates $HOME/ndtwin-vm*/ -- NOT $VM_DIR. The first version of this
# case set VM_DIR and asserted on the output, so its fixture was never scanned at
# all: it went red for the wrong reason. Point HOME at the sandbox instead.
mkdir -p "$T/home/ndtwin-vm-ghost"
printf 'owner: mainDev\nsince: x\nport:  2245\nnote:  destroyed\n' > "$T/home/ndtwin-vm-ghost/OWNER"
: > "$T/home/ndtwin-vm-ghost/noble-base.img"
VOUT=$(env HOME="$T/home" bash "$VM" vms 2>&1)
if printf '%s' "$VOUT" | grep -q 'no disk'; then
    echo "  ✅ RED-capable -- a leftover directory is labelled, not listed as a VM"; pass=$((pass+1))
else
    echo "  🔴 a disk-less directory still reads as a VM in vms"; fail=$((fail+1))
fi
# GREEN: a real VM directory must STILL show its owner -- the new branch must not
# swallow live entries on its way to hiding dead ones.
mkdir -p "$T/home/ndtwin-vm-live"
printf 'owner: bmv2paper\nsince: x\nport:  2299\nnote:  B round\n' > "$T/home/ndtwin-vm-live/OWNER"
: > "$T/home/ndtwin-vm-live/disk.qcow2"
VOUT2=$(env HOME="$T/home" bash "$VM" vms 2>&1)
if printf '%s' "$VOUT2" | grep -q 'bmv2paper'; then
    echo "  ✅ GREEN-- a directory that HAS a disk still shows its owner"; pass=$((pass+1))
else
    echo "  🔴 the disk-less branch is swallowing real VMs too"; fail=$((fail+1))
fi

echo
echo "=== G13 a KEEP mark must reach every place someone decides to delete from ==="
# 🔑 The whole point of the mark is its READERS. A KEEP file that only `keep` itself
# prints back would be the shape this repo keeps stepping on: one writer, zero
# readers, and a protection that reads as present because the writer looks tidy.
# So each case below is a READER, and the mark is written by hand -- not by the verb --
# so that a broken writer cannot make the reader tests pass.
mkdir -p "$T/home/ndtwin-vm-keeper"
: > "$T/home/ndtwin-vm-keeper/disk.qcow2"
printf 'kept-by: remote-machine-test\nkept-at: x\nreason: ID4 p4-toolchain-v8, 38m41s to build, ruled preserve\n' \
    > "$T/home/ndtwin-vm-keeper/KEEP"

# READER 1 -- vms, the survey people clean up from.
KOUT=$(env HOME="$T/home" bash "$VM" vms 2>&1)
if printf '%s' "$KOUT" | grep -q 'KEEP' && printf '%s' "$KOUT" | grep -q '38m41s'; then
    echo "  ✅ RED-capable -- vms surfaces the keep mark AND its reason"; pass=$((pass+1))
else
    echo "  🔴 vms shows a kept VM exactly like an abandoned one"; fail=$((fail+1))
fi

# READER 2 -- destroy, the last screen before the loss.
mkdir -p "$T/k"
qemu-img create -q -f qcow2 "$T/k/disk.qcow2" 8M 2>/dev/null || : > "$T/k/disk.qcow2"
cp "$T/home/ndtwin-vm-keeper/KEEP" "$T/k/KEEP"
KD=$(printf 'DESTROY\n' | env NDT_OWNER=tester VM_DIR="$T/k" SSH_PORT=2299 bash "$VM" destroy 2>&1)
if printf '%s' "$KD" | grep -q '38m41s'; then
    echo "  ✅ RED-capable -- destroy prints the reason before asking"; pass=$((pass+1))
else
    echo "  🔴 destroy never shows the keep reason"; fail=$((fail+1))
fi
# ...and the plain word must NOT get through. This is the case that matters: the
# reflex you built typing DESTROY is exactly what a mark you did not read must stop.
if [ -e "$T/k/disk.qcow2" ]; then
    echo "  ✅ RED-capable -- bare DESTROY did not delete a kept disk"; pass=$((pass+1))
else
    echo "  🔴 a kept disk was destroyed by the ordinary confirmation word"; fail=$((fail+1))
fi

# GREEN 1 -- the longer phrase must actually work, or the mark is a one-way door and
# people will route around it. A guard nobody can lift on purpose gets lifted by rm.
KD2=$(printf 'DESTROY k\n' | env NDT_OWNER=tester VM_DIR="$T/k" SSH_PORT=2299 bash "$VM" destroy 2>&1)
if [ ! -e "$T/k/disk.qcow2" ] && [ ! -e "$T/k/KEEP" ]; then
    echo "  ✅ GREEN-- the deliberate phrase destroys, and the mark dies with the disk"
    pass=$((pass+1))
else
    echo "  🔴 the documented way past the mark does not work: $KD2"; fail=$((fail+1))
fi

# GREEN 2 -- an UNMARKED VM must still take the ordinary word. Otherwise this whole
# section would pass by making destroy refuse everything.
mkdir -p "$T/nk"
qemu-img create -q -f qcow2 "$T/nk/disk.qcow2" 8M 2>/dev/null || : > "$T/nk/disk.qcow2"
printf 'DESTROY\n' | env NDT_OWNER=tester VM_DIR="$T/nk" SSH_PORT=2298 bash "$VM" destroy >/dev/null 2>&1
if [ ! -e "$T/nk/disk.qcow2" ]; then
    echo "  ✅ GREEN-- an unmarked VM still destroys with the plain word"; pass=$((pass+1))
else
    echo "  🔴 destroy now refuses unmarked VMs too -- the mark is doing nothing"; fail=$((fail+1))
fi

# GREEN 3 -- destroy names the snapshots that die. "every snapshot in it" is an
# abstraction, and the 08-31 near-miss happened with exactly that abstraction on screen.
mkdir -p "$T/sn"
if qemu-img create -q -f qcow2 "$T/sn/disk.qcow2" 8M 2>/dev/null \
   && qemu-img snapshot -c p4-toolchain-v8 "$T/sn/disk.qcow2" 2>/dev/null; then
    SD=$(printf 'no\n' | env NDT_OWNER=tester VM_DIR="$T/sn" SSH_PORT=2297 bash "$VM" destroy 2>&1)
    if printf '%s' "$SD" | grep -q 'p4-toolchain-v8'; then
        echo "  ✅ GREEN-- destroy names the snapshots by tag, not as a category"; pass=$((pass+1))
    else
        echo "  🔴 destroy still describes the loss abstractly"; fail=$((fail+1))
    fi
    if [ -e "$T/sn/disk.qcow2" ]; then
        echo "  ✅ CONTROL -- and answering anything else aborted, so that was a dry run"
        pass=$((pass+1))
    else
        echo "  🔴 CONTROL FAILED -- 'no' still destroyed the disk"; fail=$((fail+1))
    fi
else
    echo "  ⚠️  SKIPPED (qemu-img cannot make snapshots here) -- 2 checks not run"
fi

echo
echo "=== G14 adopt must DERIVE the work point from argv, never accept it as input ==="
# The point of adopt is that its record cannot disagree with the process it describes.
# So the fixture is a real process with a real /proc/<pid>/cmdline, and the numbers in
# it are ones nobody passes to adopt. If adopt ever grew a --cpus flag, these cases
# would still pass while the guarantee was gone -- so the last case asserts the
# opposite direction too: values that were NEVER typed still land in CONFIG.
mkdir -p "$T/a"
qemu-img create -q -f qcow2 "$T/a/disk.qcow2" 8M 2>/dev/null || : > "$T/a/disk.qcow2"
# A stand-in with a genuine argv. vm_running greps /proc for $IMG, so the disk path
# has to be in there -- which is exactly the shape of the thing it stands in for.
# 🔑 `sleep 30; :` not `sleep 30`: bash execs a lone simple command, and the exec
# REPLACES argv -- the stand-in would have run as plain `sleep 30` with every flag
# below gone, and G14 would have failed for a reason that has nothing to do with adopt.
bash -c 'sleep 30; :' dummy -smp 11 -m 5555 \
    -drive "file=$T/a/disk.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2296-:22 &
FAKE=$!
printf '%s\n' "$FAKE" > "$T/a/qemu.pid"
sleep 0.3

AOUT=$(env NDT_OWNER=tester VM_DIR="$T/a" SSH_PORT=9999 bash "$VM" adopt 2>&1)
if grep -q '^cpus=11$' "$T/a/CONFIG" 2>/dev/null && grep -q '^mem=5555$' "$T/a/CONFIG" 2>/dev/null; then
    echo "  ✅ RED-capable -- CONFIG carries the argv values (11/5555), not the defaults"
    pass=$((pass+1))
else
    echo "  🔴 adopt did not derive the work point from argv: $AOUT"; fail=$((fail+1))
fi
# 🔑 SSH_PORT=9999 was passed on the command line and 2296 is what the process really
# forwards. The recorded port must be the process's, or the registry sends the next
# session to avoid a port nothing is on.
if grep -q '^port=2296$' "$T/a/CONFIG" 2>/dev/null; then
    echo "  ✅ RED-capable -- the port came from argv, beating the env var that was passed"
    pass=$((pass+1))
else
    echo "  🔴 adopt recorded a port that the process is not actually using"; fail=$((fail+1))
fi
if [ -f "$T/a/OWNER" ] && grep -q 'owner: tester' "$T/a/OWNER"; then
    echo "  ✅ RED-capable -- adopt also wrote the OWNER entry that was missing"; pass=$((pass+1))
else
    echo "  🔴 adopt left the VM unowned"; fail=$((fail+1))
fi
# GREEN: a drifted CONFIG is a FINDING, not something to overwrite quietly. This is
# the case that turns adopt into an instrument instead of a repair.
printf 'cpus=12\nmem=8192\ndisk=x\nport=2296\n' > "$T/a/CONFIG"
DOUT2=$(env NDT_OWNER=tester VM_DIR="$T/a" SSH_PORT=2296 bash "$VM" adopt 2>&1)
if printf '%s' "$DOUT2" | grep -q 'DISAGREES' && printf '%s' "$DOUT2" | grep -q '12 vCPU / 8192'; then
    echo "  ✅ GREEN-- a stale CONFIG is reported, with both numbers, before being fixed"
    pass=$((pass+1))
else
    echo "  🔴 adopt silently overwrote a CONFIG that disagreed with reality"; fail=$((fail+1))
fi
# GREEN: adopt must refuse when nothing is running. There is no argv to read, so the
# only thing it could do is accept a number from a human -- which is the failure mode.
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
NOUT=$(env NDT_OWNER=tester VM_DIR="$T/a" SSH_PORT=2296 bash "$VM" adopt 2>&1)
if printf '%s' "$NOUT" | grep -q 'RUNNING'; then
    echo "  ✅ GREEN-- adopt refuses a stopped VM rather than inventing a work point"
    pass=$((pass+1))
else
    echo "  🔴 adopt produced a record with no process to derive it from"; fail=$((fail+1))
fi
# CONTROL: prove the fixture really was readable as a process, or every case above
# could have passed on some path that never touched /proc at all.
if printf '%s' "$AOUT" | grep -q "adopted pid $FAKE"; then
    echo "  ✅ CONTROL -- adopt really read that pid's argv"; pass=$((pass+1))
else
    echo "  🔴 CONTROL FAILED -- adopt never named the pid; G14 may be vacuous"; fail=$((fail+1))
fi

echo
echo "=== G15 the population must come from /proc, not from my own naming convention ==="
# Found within the hour by the session `adopt` was written for: their VM lived in
# ~/addtools/work.qcow2, so `vms` (which globs $HOME/ndtwin-vm*/) could not see it and
# `adopt` (which only knew $VM_DIR/disk.qcow2) refused it. Same shape as G10a one layer
# out: a survey that enumerates the author's convention only rediscovers the author's
# convention. So the fixture here deliberately sits OUTSIDE that convention.
# 🔑 The stand-in must not assume this machine has no other qemu -- it may. Every
# assertion below therefore names its own fixture rather than counting processes.
mkdir -p "$T/home/addtools"
qemu-img create -q -f qcow2 "$T/home/addtools/work.qcow2" 8M 2>/dev/null || : > "$T/home/addtools/work.qcow2"
# 🔑 The read-only seed is deliberately FIRST. The first version of this fixture had the
# writable disk first, so a picker that simply grabbed the earliest `file=` passed the
# control -- the control's own comment said "only by luck of argument order", and then
# the fixture supplied exactly that luck. Mutating the readonly filter away survived.
bash -c 'sleep 30; :' qemu-system-x86_64 -smp 7 -m 3333 \
    -drive "file=$T/home/addtools/seed.iso,if=virtio,format=raw,readonly=on" \
    -drive "file=$T/home/addtools/work.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2295-:22 &
OUTS=$!
# 🔑 And a second stand-in INSIDE the naming convention, because the green case below
# needs a RUNNING process the glob already covers. The first version asserted against a
# directory fixture with no process at all, so the /proc pass could never have reported
# it either way: removing the de-duplication filter survived, silently.
# 🔴 A third stand-in in the form that ACTUALLY broke it in the field: `file=` is not
# the first key. The parser matched /^file=/ -- the shape this very script emits -- so a
# sibling's `-drive id=d0,file=...,if=none,...` was invisible to both vms and adopt while
# every test here stayed green. The fixture must carry forms this script never produces.
mkdir -p "$T/home/othertool"
qemu-img create -q -f qcow2 "$T/home/othertool/work.qcow2" 8M 2>/dev/null \
    || : > "$T/home/othertool/work.qcow2"
bash -c 'sleep 30; :' qemu-system-x86_64 -m 6144 -smp 4 \
    -drive "id=d0,file=$T/home/othertool/work.qcow2,if=none,format=qcow2,discard=unmap" \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2293-:22 &
OTHR=$!
mkdir -p "$T/home/ndtwin-vm-inside"
qemu-img create -q -f qcow2 "$T/home/ndtwin-vm-inside/disk.qcow2" 8M 2>/dev/null \
    || : > "$T/home/ndtwin-vm-inside/disk.qcow2"
bash -c 'sleep 30; :' qemu-system-x86_64 -smp 2 -m 1111 \
    -drive "file=$T/home/ndtwin-vm-inside/disk.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2294-:22 &
INS=$!
sleep 0.3

VOUT3=$(env HOME="$T/home" bash "$VM" vms 2>&1)
if printf '%s' "$VOUT3" | grep -q 'addtools/work.qcow2'; then
    echo "  ✅ RED-capable -- vms surfaces a running VM that is outside the glob"; pass=$((pass+1))
else
    echo "  🔴 a VM outside \$HOME/ndtwin-vm*/ is invisible to vms"; fail=$((fail+1))
fi
# It is not enough to list it: the reader has to be told it is unregistered, and handed
# the command. "Listed but indistinguishable from a registered one" is how the whole
# problem started.
# 🔑 Scoped to OUR fixture's own lines. This machine really does have another qemu
# (Claude's own VM bundle), so a bare grep over the whole section can be satisfied --
# or broken -- by a process that has nothing to do with this test. The comment above
# said not to assume an empty machine; the first version of these two assertions then
# assumed exactly that, and the green one failed for a reason that was never the code.
MINE3=$(printf '%s' "$VOUT3" | grep -A2 'addtools/work.qcow2')
if printf '%s' "$MINE3" | grep -q 'no CONFIG' && printf '%s' "$MINE3" | grep -q "adopt $OUTS"; then
    echo "  ✅ RED-capable -- and it says the work point is unrecorded, with the fix command"
    pass=$((pass+1))
else
    echo "  🔴 vms lists it without saying it is unregistered or how to register it"; fail=$((fail+1))
fi
# 🔑 GREEN, and it must NOT be "no other qemu exists" -- this machine may well have one.
# Assert instead that the RUNNING fixture inside the convention stays out of the
# unlisted section, while the one outside it is in there. Both halves are needed:
# without the first the filter can be deleted, without the second the whole pass can be.
UNLISTED=$(printf '%s' "$VOUT3" | sed -n '/cannot see/,/ports actually/p')
if ! printf '%s' "$UNLISTED" | grep -q 'ndtwin-vm-inside' \
   && printf '%s' "$UNLISTED" | grep -q 'addtools'; then
    echo "  ✅ GREEN-- a RUNNING VM inside the convention is not double-reported"; pass=$((pass+1))
else
    echo "  🔴 the /proc pass mis-partitions: inside-glob VMs must not appear, outside ones must"
    fail=$((fail+1))
fi

# 🔴 A qemu whose disk this parser cannot read must be REPORTED, not skipped. The loop
# used to do `[ -n "$qd" ] || continue`, so an unparseable one vanished -- and then the
# "(none -- every running qemu is already listed above)" line asserted that nothing was
# missing. A gap in the parser became a completeness claim, which is the exact shape
# this whole section exists to prevent, sitting one line downstream of the fix for it.
# (Those lines came from the reviewer session; this case is the test they did not have.)
bash -c 'sleep 30; :' qemu-system-x86_64 -m 512 -smp 1 \
    -cdrom "$T/home/nodisk.iso" -netdev user,id=n0 &
NODK=$!
# Wait for the stand-in to be visible in /proc rather than sleeping a guessed interval.
# A fixed sleep made this section fail once out of six runs, and an intermittently red
# gate is worse than no gate: it teaches people to re-run until it goes green.
for _ in $(seq 1 40); do [ -r "/proc/$NODK/cmdline" ] && break; sleep 0.1; done
VOUT5=$(env HOME="$T/home" bash "$VM" vms 2>&1)
if printf '%s' "$VOUT5" | grep -q "pid $NODK" && printf '%s' "$VOUT5" | grep -q 'not parseable'; then
    echo "  ✅ RED-capable -- an unparseable qemu is reported with its argv, not skipped"
    pass=$((pass+1))
else
    echo "  🔴 a qemu the parser cannot read disappears from the survey"; fail=$((fail+1))
fi
# Reporting the gap must also SUPPRESS the all-clear line -- otherwise it states the
# gap and claims completeness in the same breath.
# 🔑 Asserted structurally, not from output. On this laptop something is essentially
# always outside the glob (Claude's own VM), so `unlisted` is set regardless and an
# output-based check here could never go red: decoration, not a check. It was also the
# one case that raced. Assert on the branch itself instead.
UNPARSE_BLOCK=$(awk '/if \[ -z "\$qd" \]; then/{f=1} f{print} f&&/^ *fi$/{exit}' "$VM")
if printf '%s' "$UNPARSE_BLOCK" | grep -q 'unlisted=1'; then
    echo "  ✅ RED-capable -- the unparseable branch sets unlisted, withholding the all-clear"
    pass=$((pass+1))
else
    echo "  🔴 it can report a gap and still print 'every running qemu is already listed'"
    fail=$((fail+1))
fi
if [ -n "$UNPARSE_BLOCK" ]; then
    echo "  ✅ CONTROL -- that block parser found the branch (else the check above is vacuous)"
    pass=$((pass+1))
else
    echo "  🔴 CONTROL FAILED -- no unparseable branch found; previous check is vacuous"
    fail=$((fail+1))
fi
kill "$NODK" 2>/dev/null; wait "$NODK" 2>/dev/null

# 🔑 The form this script never emits must be found too -- that is the whole point of
# the third stand-in. Without this case the parser can go back to matching only its
# author's own output and every other case here stays green.
if printf '%s' "$VOUT3" | grep -q 'othertool/work.qcow2'; then
    echo "  ✅ RED-capable -- a -drive with file= NOT first is still parsed"; pass=$((pass+1))
else
    echo "  🔴 the disk parser only understands the argument order this script emits"
    fail=$((fail+1))
fi
AO=$(env NDT_OWNER=tester VM_DIR="$T/nowhere" SSH_PORT=1 bash "$VM" adopt "$OTHR" 2>&1)
if grep -q '^cpus=4$' "$T/home/othertool/CONFIG" 2>/dev/null \
   && grep -q '^mem=6144$' "$T/home/othertool/CONFIG" 2>/dev/null; then
    echo "  ✅ RED-capable -- adopt reaches that VM too"; pass=$((pass+1))
else
    echo "  🔴 adopt cannot register a VM laid out by another tool: $AO"; fail=$((fail+1))
fi

# adopt <pid>: the DIRECTORY has to come from argv too, not just the work point.
AP=$(env NDT_OWNER=tester VM_DIR="$T/nowhere" SSH_PORT=1 bash "$VM" adopt "$OUTS" 2>&1)
if grep -q '^cpus=7$' "$T/home/addtools/CONFIG" 2>/dev/null \
   && grep -q '^mem=3333$' "$T/home/addtools/CONFIG" 2>/dev/null; then
    echo "  ✅ RED-capable -- adopt <pid> wrote into the directory it derived from argv"
    pass=$((pass+1))
else
    echo "  🔴 adopt <pid> did not reach the real directory: $AP"; fail=$((fail+1))
fi
# 🔴 The guard must protect the DERIVED directory. Guarding whatever VM_DIR the caller
# happened to be pointed at, then writing somewhere else, is worse than no guard.
printf 'owner: someone-else\nsince: x\nport:  2295\nnote:  theirs\n' > "$T/home/addtools/OWNER"
GP=$(env NDT_OWNER=tester VM_DIR="$T/nowhere" SSH_PORT=1 bash "$VM" adopt "$OUTS" 2>&1); grc=$?
if [ "$grc" = 3 ] && printf '%s' "$GP" | grep -q 'REFUSED'; then
    echo "  ✅ RED-capable -- adopt <pid> guards the DERIVED dir, not the caller's VM_DIR"
    pass=$((pass+1))
else
    echo "  🔴 adopt <pid> wrote into another session's directory (rc=$grc)"; fail=$((fail+1))
fi
# GREEN: a pid that is not a qemu must be refused by name, not silently adopted.
NQ=$(env NDT_OWNER=tester bash "$VM" adopt $$ 2>&1)
if printf '%s' "$NQ" | grep -q 'not a qemu-system process'; then
    echo "  ✅ GREEN-- a non-qemu pid is refused, and the message shows its argv"; pass=$((pass+1))
else
    echo "  🔴 adopt accepted a pid that is not a qemu"; fail=$((fail+1))
fi
# GREEN: and once it IS registered, the warning must go away. Without this the whole
# branch can be made unconditional -- `[ -f X ] || true && printf` still passes every
# red case above, because none of them ever asks when the warning should be silent.
VOUT4=$(env HOME="$T/home" bash "$VM" vms 2>&1)
UNL4=$(printf '%s' "$VOUT4" | sed -n '/cannot see/,/ports actually/p')
MINE4=$(printf '%s' "$UNL4" | grep -A2 'addtools/work.qcow2')
if [ -n "$MINE4" ] && ! printf '%s' "$MINE4" | grep -q 'no CONFIG'; then
    echo "  ✅ GREEN-- once adopted, it is still listed but no longer flagged unregistered"
    pass=$((pass+1))
else
    echo "  🔴 the unregistered warning does not depend on being unregistered"; fail=$((fail+1))
fi
# CONTROL: prove the writable-disk picker skipped the read-only seed drive. Without
# this, a picker that grabbed the FIRST file= would look identical on the cases above
# only by luck of argument order.
if printf '%s' "$AP" | grep -q 'work.qcow2' && ! printf '%s' "$AP" | grep -q 'seed.iso'; then
    echo "  ✅ CONTROL -- it picked the writable drive, not the read-only seed"; pass=$((pass+1))
else
    echo "  🔴 CONTROL FAILED -- the disk picker does not distinguish the seed"; fail=$((fail+1))
fi
kill "$OUTS" "$INS" "$OTHR" 2>/dev/null; wait "$OUTS" "$INS" "$OTHR" 2>/dev/null


echo
echo "=== G16 the host address in hostfwd is a security property, not a format quirk ==="
# 開機手冊 found this: qemu's `hostfwd=tcp:[hostaddr]:port-` has an OPTIONAL host address,
# and omitting it binds EVERY interface. They had written `hostfwd=tcp::PORT-` on every
# VM that evening, so their forwards were on 0.0.0.0, into a guest with a password login,
# on the lab network. My parser matched the literal `127.0.0.1:` this script writes -- so
# it did not get that wrong, it could not see it at all.
# 🔑 A parser that only understands its own output cannot warn about the input it does
#   not understand, and that is exactly the input worth warning about. Every stand-in
#   below is therefore in a form this script never emits.
mkdir -p "$T/home/ndtwin-vm-exposed"
qemu-img create -q -f qcow2 "$T/home/ndtwin-vm-exposed/disk.qcow2" 8M 2>/dev/null \
    || : > "$T/home/ndtwin-vm-exposed/disk.qcow2"
bash -c 'sleep 30; :' qemu-system-x86_64 -smp 2 -m 2048 \
    -drive "file=$T/home/ndtwin-vm-exposed/disk.qcow2,if=virtio,format=qcow2" \
    -netdev user,id=n0,hostfwd=tcp::2291-:22 &
EXPO=$!
printf '%s\n' "$EXPO" > "$T/home/ndtwin-vm-exposed/qemu.pid"
# No hostfwd at all -- the case that used to be filled in from the built-in default.
mkdir -p "$T/w"
qemu-img create -q -f qcow2 "$T/w/disk.qcow2" 8M 2>/dev/null || : > "$T/w/disk.qcow2"
bash -c 'sleep 30; :' qemu-system-x86_64 -smp 3 -m 777 -drive "file=$T/w/disk.qcow2,if=virtio" &
NOFW=$!
for _ in $(seq 1 40); do [ -r "/proc/$EXPO/cmdline" ] && [ -r "/proc/$NOFW/cmdline" ] && break; sleep 0.1; done

EOUT=$(env NDT_OWNER=tester VM_DIR="$T/nope" SSH_PORT=9999 bash "$VM" adopt "$EXPO" 2>&1)
if grep -q '^port=2291$' "$T/home/ndtwin-vm-exposed/CONFIG" 2>/dev/null; then
    echo "  ✅ RED-capable -- a hostfwd with the address omitted is still parsed"; pass=$((pass+1))
else
    echo "  🔴 the parser only reads the 127.0.0.1 form this script writes"; fail=$((fail+1))
fi
if printf '%s' "$EOUT" | grep -q 'NOT loopback'; then
    echo "  ✅ RED-capable -- adopt says the forward is exposed, and names the address"
    pass=$((pass+1))
else
    echo "  🔴 an off-box-reachable guest login is registered without comment"; fail=$((fail+1))
fi
XOUT=$(env HOME="$T/home" bash "$VM" vms 2>&1)
if printf '%s' "$XOUT" | grep -q 'NOT loopback'; then
    echo "  ✅ RED-capable -- vms flags it too, even inside the naming convention"; pass=$((pass+1))
else
    echo "  🔴 vms shows an exposed forward as an ordinary VM"; fail=$((fail+1))
fi

# 🔴 A port that could not be read must stay visibly unread -- in BOTH files. Filling it
# from the default put an invented 2222 under a banner reading "read out of its argv",
# where the three true fields vouched for it.
NOUT2=$(env NDT_OWNER=tester VM_DIR="$T/nope2" SSH_PORT=2222 bash "$VM" adopt "$NOFW" 2>&1)
if grep -q '^port=unknown$' "$T/w/CONFIG" 2>/dev/null; then
    echo "  ✅ RED-capable -- CONFIG records the unreadable port as unknown, not 2222"
    pass=$((pass+1))
else
    echo "  🔴 CONFIG invented a port: $(grep '^port=' "$T/w/CONFIG" 2>/dev/null)"; fail=$((fail+1))
fi
if grep -q '^port:  unknown$' "$T/w/OWNER" 2>/dev/null; then
    echo "  ✅ RED-capable -- and OWNER too (fixing one file would just move the lie)"
    pass=$((pass+1))
else
    echo "  🔴 OWNER still carries the default port: $(grep '^port:' "$T/w/OWNER" 2>/dev/null)"
    fail=$((fail+1))
fi
# GREEN: a genuine loopback forward must NOT be flagged, or the warning means nothing.
if ! printf '%s' "$NOUT2" | grep -q 'NOT loopback' \
   && printf '%s' "$NOUT2" | grep -q 'EXCEPT port'; then
    echo "  ✅ GREEN-- no false exposure warning, and the real gap is the one reported"
    pass=$((pass+1))
else
    echo "  🔴 the exposure warning does not discriminate"; fail=$((fail+1))
fi
# The listening list had the same defect and no test: it used to grep
# '^ *127.0.0.1:', so a socket bound anywhere else was filtered out of the section
# titled "the ground truth". The one binding worth seeing was the one it could not show.
#
# 🔴 The FIRST version of this test encoded a bug. To avoid opening a genuinely exposed
# port it bound 127.0.0.2 and asserted that it was flagged "not loopback" -- so a fixture
# chosen for safety turned a wrong classification into a requirement. Deployed, the tool
# then flagged systemd-resolved's 127.0.0.53%lo and 127.0.0.54: all of 127.0.0.0/8 is
# loopback. A marker that fires on ordinary system state is one people learn to skip.
# ⇒ Classification is a pure function of a string. Table-test it -- no sockets, no
#   exposure, and every case the socket approach could not reach.
CLASSIFY_OK=1
for a in 127.0.0.1 127.0.0.2 127.0.0.53%lo 127.0.0.54 ::1 '[::1]' '::1%lo' '[::1]%lo' localhost; do
    (source_fn() { :; }; . /dev/stdin <<< "$(sed -n '/^addr_is_loopback()/,/^}$/p' "$VM")"
     addr_is_loopback "$a") || { echo "     🔴 $a classified as exposed"; CLASSIFY_OK=0; }
done
for a in 0.0.0.0 '[::]' 10.10.10.1 172.25.197.100 192.168.1.5 '' ; do
    (. /dev/stdin <<< "$(sed -n '/^addr_is_loopback()/,/^}$/p' "$VM")"
     addr_is_loopback "$a") && { echo "     🔴 $a classified as loopback"; CLASSIFY_OK=0; }
done
if [ "$CLASSIFY_OK" = 1 ]; then
    echo "  ✅ RED-capable -- 127.0.0.0/8 and ::1 are loopback; 0.0.0.0 and LAN are not"
    pass=$((pass+1))
else
    echo "  🔴 the loopback classifier is wrong on at least one address above"; fail=$((fail+1))
fi

# Integration: a real socket off 127.0.0.1 must still be LISTED (the old grep dropped
# it) -- and, being inside 127/8, must NOT be flagged.
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.2",34571)); s.listen(1); time.sleep(20)' &
ODDB=$!
for _ in $(seq 1 30); do ss -tlnH 'sport = :34571' | grep -q . && break; sleep 0.2; done
LOUT=$(env HOME="$T/home" bash "$VM" vms 2>&1)
if printf '%s' "$LOUT" | grep -q '127.0.0.2:34571'; then
    echo "  ✅ RED-capable -- a socket off 127.0.0.1 still appears in the listening list"
    pass=$((pass+1))
else
    echo "  🔴 the 'ground truth' list filters out every address but its own"; fail=$((fail+1))
fi
if ! printf '%s' "$LOUT" | grep '127.0.0.2:34571' | grep -q 'not loopback'; then
    echo "  ✅ GREEN-- and 127/8 is not mislabelled as exposed"; pass=$((pass+1))
else
    echo "  🔴 127.0.0.2 flagged as exposed -- the marker fires on ordinary system state"
    fail=$((fail+1))
fi
# 🔑 The two levels, table-tested for the same reason: the only fixture that reaches
# the interesting branch is a genuinely exposed port, and this test refuses to open one.
lvl() { (. /dev/stdin <<< "$(sed -n '/^addr_is_loopback()/,/^}$/p;/^listener_level()/,/^}$/p' "$VM")"
        listener_level "$1" 2291 2223); }
LVL_OK=1
[ "$(lvl 0.0.0.0:2291)"   = vm-exposed   ] || { echo "     🔴 VM forward off-box not vm-exposed"; LVL_OK=0; }
[ "$(lvl 0.0.0.0:22)"     = host-service ] || { echo "     🔴 host sshd flagged as a VM"; LVL_OK=0; }
[ "$(lvl 127.0.0.1:2223)" = loopback     ] || { echo "     🔴 loopback VM port not loopback"; LVL_OK=0; }
[ "$(lvl '[::]:22')"      = host-service ] || { echo "     🔴 IPv6 wildcard misclassified"; LVL_OK=0; }
[ "$(lvl 127.0.0.53%lo:53)" = loopback   ] || { echo "     🔴 resolved's stub flagged"; LVL_OK=0; }
if [ "$LVL_OK" = 1 ]; then
    echo "  ✅ RED-capable -- a VM's off-box forward and the host's own sshd are distinguished"
    pass=$((pass+1))
else
    echo "  🔴 the two levels do not discriminate"; fail=$((fail+1))
fi
kill "$ODDB" 2>/dev/null; wait "$ODDB" 2>/dev/null
kill "$EXPO" "$NOFW" 2>/dev/null; wait "$EXPO" "$NOFW" 2>/dev/null

printf '\n=== %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" = 0 ]
