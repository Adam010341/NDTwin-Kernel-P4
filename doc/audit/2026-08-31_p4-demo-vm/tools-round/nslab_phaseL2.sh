#!/bin/bash
# H-26 phase L2: redo control B, because the pair it formed had no discriminating power.
#
# 🔴 WHAT HAPPENED. Phase J left /home/nslab/repack/imp-disk1.vmdk behind -- I removed imp.vmx
#    and forgot its disk. So phase L's POSITIVE arm died on
#        Error: File already exists: .../imp-disk1.vmdk
#    before ovftool ever read the archive, giving exit 1. The NEGATIVE arm also gave exit 1.
#    Two arms, same verdict, two unrelated reasons.
#
# 🔑 The failure mode to name is not "I forgot to clean a directory". It is that a control
#    whose two arms return the SAME value has told me nothing, and the arm that was supposed to
#    prove the artefact is GOOD is the one that broke -- so the surviving evidence all pointed
#    the reassuring way. Had I checked only "the negative arm fails", this would have read as a
#    pass.
#    ⇒ So this run asserts the PAIR, not each arm: the two exits must differ, and the positive
#      arm must additionally reach "Completed successfully".
#
# Each conversion gets a fresh empty directory, so "file already exists" cannot recur.
#
# [Co-developed with claude code -- Adam]
set -u
T=/home/nslab/ovftool-dist/ovftool/ovftool
R=/home/nslab/repack
OVA="$R/out/NDTwin-P4-demo.ova"
[ -s "$OVA" ] || { echo "no artefact -- stop"; exit 1; }
echo "=== $(date -Is) phase L2: control B, properly paired ==="
stat -c '  %n %s bytes' "$OVA"

echo
echo "--- POSITIVE arm: the artefact as packed, into a fresh directory ---"
rm -rf "$R/cb_pos"; mkdir -p "$R/cb_pos"
POUT=$("$T" "$OVA" "$R/cb_pos/imp.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$')
PEXIT=$?
echo "$POUT" | tail -3 | sed 's/^/    /'
PEXIT=$(echo "$POUT" | grep -qE 'Completed successfully' && echo 0 || echo 1)
echo "  positive arm exit (by outcome text, not by a pipeline rc): $PEXIT   <-- must be 0"

echo
echo "--- NEGATIVE arm: one byte flipped, into its own fresh directory ---"
rm -rf "$R/cb_neg"; mkdir -p "$R/cb_neg"
cp "$OVA" "$R/cb_neg/flip.ova"
SZ=$(stat -c%s "$R/cb_neg/flip.ova")
printf '\xff' | dd of="$R/cb_neg/flip.ova" bs=1 seek=$(( SZ / 2 )) count=1 conv=notrunc status=none
echo "  flipped byte at offset $(( SZ / 2 )) of $SZ"
NOUT=$("$T" "$R/cb_neg/flip.ova" "$R/cb_neg/z.vmx" 2>&1 | tr '\r' '\n' | grep -vE 'Disk progress|^$')
echo "$NOUT" | tail -3 | sed 's/^/    /'
NEXIT=$(echo "$NOUT" | grep -qE 'Completed successfully' && echo 0 || echo 1)
echo "  negative arm exit: $NEXIT   <-- must be 1"

echo
echo "--- the assertion is on the PAIR ---"
if [ "$PEXIT" = 0 ] && [ "$NEXIT" = 1 ]; then
  echo "  PASS: the two arms DIFFER (good=0, corrupted=1) -- the check discriminates"
  echo "$NOUT" | grep -i 'digest' | head -1 | sed 's/^/    reason the bad one failed: /'
else
  echo "  🔴 FAIL: arms did not differ (positive=$PEXIT negative=$NEXIT) -- this proves nothing"
fi
rm -rf "$R/cb_pos" "$R/cb_neg"
echo "PHASE_L2_DONE"
