#!/bin/bash
# Host-side driver for the sections 1-5 clean-room replay.
#
# Runs guest_sections_1_5.sh inside a VM restored to the `fresh` snapshot -- the ONLY snapshot
# whose sections 1-5 have not already been performed against the pre-b41b9e4 text. Every later
# snapshot (after-deps, ovs-complete, ab-base, v8-installed) has the old sequence baked in, so
# testing on one of those would silently answer a different question.
#
# The two snippet files are pushed from ~/NDTwin-Website/assets/snippet/, NOT from the kernel
# repo. That is deliberate and is the point: section 2.6 tells the reader to paste the website
# copy, every previous harness read the repo copy, and the two differ by 1360 lines. A harness
# that clones is on the wrong side of the split -- see SNIPPET-CANONICAL.md.
#
# This script does NOT override vm.sh's exclusive_cpu guard. If the lab is claimed, it stops
# here, which is the correct outcome: a 4-vCPU build is invisible to the claim holder's
# instruments and lines its load up with whatever they are timing.
# [Co-developed with claude code -- Adam]
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/ab-results/sections1-5"
WEB="${WEB:-$HOME/NDTwin-Website}"
SSH="ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30 tester@localhost"
SCP="scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
mkdir -p "$OUT"
say() { echo; echo "=== $* ==="; }

# --- the snippets must exist before anything is started ------------------------------------
for f in intelligent_router.py testbed_topo.py; do
    [ -r "$WEB/assets/snippet/$f" ] || { echo "ABORT: missing $WEB/assets/snippet/$f"; exit 1; }
done
say "snippets that will be pushed (the copies a READER pastes, not the repo's)"
wc -l "$WEB/assets/snippet/intelligent_router.py" "$WEB/assets/snippet/testbed_topo.py"

# --- vm.sh performs the claim check; do not duplicate or weaken it --------------------------
say "restore the fresh snapshot"
bash "$DIR/vm.sh" stop
bash "$DIR/vm.sh" restore fresh || { echo "ABORT: restore failed"; exit 1; }
bash "$DIR/vm.sh" start        || { echo "ABORT: start refused or failed (check the lab claim)"; exit 1; }
bash "$DIR/wait_ssh.sh"        || { echo "ABORT: no ssh"; exit 1; }

# --- prove it really is the fresh snapshot, not a later one ---------------------------------
# Cheap, and it is the assumption the whole run rests on. A wrong snapshot would produce a
# green run that answered nothing, and would look identical to a good one.
say "confirm this is FRESH: none of the things sections 2-5 install may be present yet"
$SSH 'for c in conda ryu-manager mn ovs-vsctl cmake ninja; do
        printf "  %-12s " "$c"
        command -v "$c" >/dev/null 2>&1 && echo "PRESENT -- NOT a fresh snapshot" || echo "absent (correct)"
      done
      printf "  %-12s " "~/Desktop/NDTwin-Kernel"
      [ -d ~/Desktop/NDTwin-Kernel ] && echo "PRESENT -- NOT fresh" || echo "absent (correct)"' \
    | tee "$OUT/snapshot-check.txt"
if grep -q 'NOT a fresh snapshot\|NOT fresh' "$OUT/snapshot-check.txt"; then
    echo "ABORT: the VM is not on the fresh snapshot; the run would answer a different question."
    exit 1
fi

say "push the guest script and the website snippets"
$SSH 'mkdir -p ~/snippets'
$SCP "$DIR/guest_sections_1_5.sh"                  tester@localhost:~/guest_sections_1_5.sh
$SCP "$WEB/assets/snippet/intelligent_router.py"   tester@localhost:~/snippets/
$SCP "$WEB/assets/snippet/testbed_topo.py"         tester@localhost:~/snippets/

say "run sections 1-5 (one shell, cwd inherited) -- this is the long part"
# No `ssh -t`: a pty would give the guest script a terminal it would not otherwise have, and
# section 2.5's ryu-manager behaves differently with one. A reader has a terminal, but what is
# under test here is the command sequence, and a pty would also make SIGINT handling differ.
$SSH 'bash ~/guest_sections_1_5.sh' 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}

say "collect"
for f in s1-5.log pingall.log ryu25.log; do
    $SCP "tester@localhost:~/$f" "$OUT/" 2>/dev/null || echo "  (no $f)"
done

say "summary"
grep -E '^\s+\^\^ NON-ZERO|^--- \[|^############|^steps run:' "$OUT/run.log" \
    | grep -B1 'NON-ZERO' | sed 's/^/  /' || echo "  no non-zero exits"
echo
tail -5 "$OUT/run.log"
echo
echo "ssh rc=$rc   full log: $OUT/run.log"
