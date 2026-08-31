#!/bin/bash
# H-26 phase H part 1: take out what must not ship, and report what is left, before the reboot.
#
# THE .git DIRECTORIES GO. A clone carries every blob the repository ever held, and an image is
# a filesystem -- shipping them ships history nobody has looked at. That is not hypothetical
# here: an earlier NDTwin artefact went out with 77 objects from a submission package inside a
# .git that four separate checks called clean.
# PROVENANCE.txt was written in phase G, while they still existed, so deleting them costs the
# recipient nothing they cannot read off a file on the Desktop.
#
# WHAT IS *NOT* DELETED, and why it is stated rather than silently kept:
#   ~/.m2  -- the Maven cache. Keeping it is what lets the recipient rebuild the Visualizer with
#             no network. It is third-party jars from Maven Central, i.e. exactly what they
#             would fetch themselves. Its size is printed below rather than left to be found.
#   target/original-*.jar -- 233 KB, and it is the artefact that made phase F look broken. It
#             stays so the README's story can be checked against the tree.
#
# apt caches DO go: they are pure download residue, nobody rebuilds from them.
#
# [Co-developed with claude code -- Adam]
LOG=/home/tester/phaseH1.out
exec > >(tee -a "$LOG") 2>&1
D=/home/tester/Desktop
echo "=== phase H part 1 started $(date -Is) ==="

echo
echo "############ what the four .git directories weigh, and what leaves with them ############"
TOT=0
for r in Energy-Saving-App Simulation-Platform-Manager Traffic-Engineering-App Network-Traffic-Visualizer; do
  p="$D/$r/.git"
  if [ -d "$p" ]; then
    k=$(du -sk "$p" | cut -f1); TOT=$((TOT+k))
    printf '  %-32s %8s KB   %s objects\n' "$r" "$k" "$(git -C "$D/$r" count-objects -v 2>/dev/null | sed -n 's/^count: //p')"
  fi
done
echo "  total: $TOT KB"
echo "  PROVENANCE.txt records the commits, and it exists: $([ -s "$D/PROVENANCE.txt" ] && echo yes || echo 'NO -- STOP')"

echo
echo "############ delete, then assert the deletion (a missing thing is loud, a renamed one is not) ############"
for r in Energy-Saving-App Simulation-Platform-Manager Traffic-Engineering-App Network-Traffic-Visualizer; do
  rm -rf "$D/$r/.git"
done
LEFT=$(find "$D" -maxdepth 2 -name .git 2>/dev/null | wc -l)
echo "  .git directories under Desktop now: $LEFT (expect 0)"
GITFILES=$(find "$D" -name '*.git*' -o -name 'ORIG_HEAD' 2>/dev/null | wc -l)
echo "  any remaining git-ish names: $GITFILES"
echo "  and the trees still work as trees: $(ls "$D/Network-Traffic-Visualizer/target"/*.jar 2>/dev/null | wc -l) jar(s) still present"

echo
echo "############ apt residue ############"
sudo -n apt-get clean
sudo -n rm -rf /var/lib/apt/lists/* /var/log/journal/* 2>/dev/null
sudo -n journalctl --rotate --vacuum-time=1s >/dev/null 2>&1
echo "  /var/cache/apt: $(du -sh /var/cache/apt 2>/dev/null | cut -f1)"

echo
echo "############ what is left, largest first -- kept deliberately, so it is named ############"
du -sh "$D"/* 2>/dev/null | sort -rh | head -8 | sed 's/^/  /'
echo "  ~/.m2 (Maven cache, KEPT so the Visualizer can be rebuilt offline): $(du -sh /home/tester/.m2 2>/dev/null | cut -f1)"
df -h / | awk 'NR==2{print "  disk: "$3" used, "$4" free"}'

echo
echo "############ units must still be installed-but-disabled going into the reboot ############"
for u in ndtwin-esa ndtwin-spm ndtwin-reqmgr; do
  printf '  %-18s %s\n' "$u" "$(systemctl is-enabled "$u" 2>&1)"
done
echo "PHASE_H1_DONE"
