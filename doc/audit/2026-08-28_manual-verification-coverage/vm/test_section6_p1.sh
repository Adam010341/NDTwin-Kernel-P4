#!/bin/bash
# Host-side driver for the section 6.0-6.1 clean-room replay.
#
# Restores `post-s5-run2` -- the snapshot taken immediately after run 2 finished sections 1-5
# by following the page. Section 6 is written for a reader who has just done that, and 6.1's
# central warning is about the working directory inherited from step 4.2, so starting anywhere
# else would answer a different question.
#
# Like test_sections_1_5.sh this does NOT override vm.sh's exclusive_cpu guard.
#
# VM_MAX_SECONDS is raised because 6.1 alone is one to two hours and the default watchdog is
# two. A watchdog that fires mid-install would look exactly like an install that hung.
# [Co-developed with claude code -- Adam]
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/ab-results/section6"
SNAP="${SNAP:-post-s5-run2}"
export VM_MAX_SECONDS="${VM_MAX_SECONDS:-21600}"   # 6h
SSH="ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30 tester@localhost"
SCP="scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
mkdir -p "$OUT"
say() { echo; echo "=== $* ==="; }

say "restore $SNAP"
bash "$DIR/vm.sh" stop
bash "$DIR/vm.sh" restore "$SNAP" || { echo "ABORT: restore failed"; exit 1; }
bash "$DIR/vm.sh" start        || { echo "ABORT: start refused or failed (check the lab claim)"; exit 1; }
bash "$DIR/wait_ssh.sh"        || { echo "ABORT: no ssh"; exit 1; }

# --- prove this really is the post-sections-1-5 machine ------------------------------------
# The mirror of test_sections_1_5.sh's freshness check. There, everything had to be ABSENT.
# Here the same things must be PRESENT, because section 6 is written for a reader who has
# finished 1-5. A fresh snapshot would produce a run that fails for the wrong reason.
say "confirm this is POST-SECTIONS-1-5, not fresh and not a later P4 snapshot"
$SSH 'for c in conda mn ovs-vsctl cmake ninja; do
        printf "  %-14s " "$c"
        command -v "$c" >/dev/null 2>&1 && echo "present (correct)" || echo "ABSENT -- not the 1-5 machine"
      done
      printf "  %-14s " "kernel binary"
      [ -x ~/Desktop/NDTwin-Kernel/build/bin/ndtwin_kernel ] && echo "present (correct)" || echo "ABSENT -- 4.2 did not run here"
      printf "  %-14s " "p4c-bm2-ss"
      command -v p4c-bm2-ss >/dev/null 2>&1 && echo "PRESENT -- 6.1 already done, wrong snapshot" || echo "absent (correct)"' \
    | tee "$OUT/snapshot-check-p1.txt"
if grep -q 'ABSENT -- \|PRESENT -- ' "$OUT/snapshot-check-p1.txt"; then
    echo "ABORT: wrong starting snapshot; the run would answer a different question."
    exit 1
fi

say "push the guest script"
$SCP "$DIR/guest_section6_p1.sh" tester@localhost:~/guest_section6_p1.sh

say "run 6.0-6.1 -- the page says this is one to two hours"
$SSH 'bash ~/guest_section6_p1.sh' 2>&1 | tee "$OUT/run-p1.log"
rc=${PIPESTATUS[0]}

say "collect"
$SCP "tester@localhost:~/s6p1.log" "$OUT/" 2>/dev/null || echo "  (no s6p1.log)"

say "summary"
grep -E '^--- \[|NON-ZERO|^steps run:' "$OUT/run-p1.log" | grep -B1 'NON-ZERO' | sed 's/^/  /' \
    || echo "  no non-zero exits"
echo
tail -8 "$OUT/run-p1.log"
echo
echo "ssh rc=$rc   full log: $OUT/run-p1.log"
