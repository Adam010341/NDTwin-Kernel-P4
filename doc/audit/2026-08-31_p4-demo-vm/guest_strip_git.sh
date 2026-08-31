#!/bin/bash
# Remove the git metadata from the demo image, because the .ova was about to ship the
# EuroP4 poster submission package.
#
# WHY .git AND NOT A HISTORY REWRITE
#   The image's repo carried 77 objects matching the submission package -- including
#   abstract.tex, refs.bib and NOTES.md -- reachable from origin/fix/flow-rate-divide-by-zero
#   at c745f216 (2026-08-30). None of it was checked out, so `ls`, `find`, `grep -r` and
#   `git status` all reported clean; only `git rev-list --objects --all` saw it. Deleting
#   .git outright is the version whose acceptance criterion is trivially checkable
#   ("no .git exists") rather than one that requires trusting a filter's completeness.
#
# WHY THE PROVENANCE FILE
#   Deleting .git deletes the answer to "which commit is this?", and this project's rule is
#   that a shipped artefact must name what it contains. So the commit ids are written to a
#   plain file before the metadata goes.
#
# WHY fstrim
#   `rm` unlinks; it does not overwrite. qemu-img convert copies allocated blocks, so a
#   deleted-but-not-discarded packfile would be copied into the shipped .ova and remain
#   recoverable with a forensic tool. fstrim tells qemu to discard those blocks so the
#   conversion reads them as zeros. This is checked afterwards from the host by searching
#   the rebuilt image for a byte signature taken from the packfile before deletion -- the
#   deletion is not trusted, it is tested.
#
# [Co-developed with claude code -- Adam]
set -u

R=/home/tester/Desktop/NDTwin-Kernel
PROV=/home/tester/Desktop/NDTwin-Kernel/PROVENANCE.txt

echo "=== 1. record what is about to be deleted ==="
{
  echo "NDTwin P4/BMv2 demo VM -- source provenance"
  echo "Git metadata was removed from this image before distribution. The commit ids below"
  echo "identify what the working tree contains."
  echo
  for r in "$R" /home/tester/Network-Traffic-Generator /home/tester/Network-State-Recorder; do
    [ -d "$r/.git" ] || continue
    echo "repo: $r"
    echo "  remote: $(git -C "$r" remote get-url origin 2>/dev/null)"
    echo "  branch: $(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "  commit: $(git -C "$r" rev-parse HEAD 2>/dev/null)"
    echo "  date:   $(git -C "$r" log -1 --format=%ci 2>/dev/null)"
    echo
  done
} | sudo tee "$PROV" >/dev/null
sudo chown tester:tester "$PROV"
cat "$PROV"

echo "=== 2. delete every .git on the disk ==="
for g in $(sudo find / -xdev -name '.git' -maxdepth 6 2>/dev/null); do
  echo "  removing $g"
  sudo rm -rf "$g"
done

echo "=== 3. verify by state, not by rc ==="
left=$(sudo find / -xdev -name '.git' 2>/dev/null | wc -l)
echo "  .git directories remaining: $left"
[ "$left" -eq 0 ] || { echo "  ABORT: .git still present"; exit 1; }

echo "=== 4. the same keyword scan that found 77 objects ==="
KEYS='europ4|EuroP4|poster-abstract|poster-review|poster-package'
echo "  control (must be non-empty or the scan proves nothing):"
sudo find / -xdev -iname '*NDTwin-Kernel*' -maxdepth 4 2>/dev/null | head -2 | sed 's/^/    /'
echo "  paths matching submission keywords: $(sudo find / -xdev 2>/dev/null | grep -icE "$KEYS")"
echo "  files whose CONTENT matches:        $(sudo grep -rilE "$KEYS" /home /root /tmp /var/tmp 2>/dev/null | wc -l)"

echo "=== 5. discard the freed blocks so they are not copied into the .ova ==="
sudo fstrim -av 2>&1

echo "=== 6. disk usage after ==="
df -h / | tail -1
sync
echo "=== STRIP_DONE ==="
