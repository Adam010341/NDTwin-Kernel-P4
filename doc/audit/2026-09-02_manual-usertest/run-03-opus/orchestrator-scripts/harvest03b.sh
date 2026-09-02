# run-03 harvest pass 2: the tester's driver scripts live in /tmp, not ~.
# Also: ndtwin-lab (the script at the centre of the G-6/G-7/G-8 lead), bash_history,
# install-details/, and diffs of the two files the tester edited in the kernel repo.
# [Co-developed with claude code -- Adam]
set -u; cd ~
rm -rf ~/harvest2 && mkdir -p ~/harvest2/tester-scripts ~/harvest2/evidence
# tester driver scripts (exclude my own orch-*.sh)
for f in /tmp/*.sh; do
  b=$(basename "$f"); case "$b" in orch-*) continue;; esac
  cp -p "$f" ~/harvest2/tester-scripts/ 2>/dev/null
done
ls ~/harvest2/tester-scripts | wc -l
cp -p ~/.bash_history ~/harvest2/evidence/bash_history.txt 2>/dev/null
cp -p /usr/local/sbin/ndtwin-lab ~/harvest2/evidence/ndtwin-lab.sh 2>/dev/null || sudo -n cp /usr/local/sbin/ndtwin-lab ~/harvest2/evidence/ndtwin-lab.sh 2>/dev/null
cp -p ~/p4setup.bash ~/p4setup.csh ~/harvest2/evidence/ 2>/dev/null
cp -rp ~/install-details ~/harvest2/evidence/ 2>/dev/null
{
  echo "=== git diff: NDTwin-Kernel (tester's edits) ==="
  git -C ~/Desktop/NDTwin-Kernel diff 2>&1 | head -200
  echo; echo "=== git diff --stat: Energy-Saving-App ==="
  git -C ~/Energy-Saving-App diff --stat 2>&1 | head -20
  git -C ~/Energy-Saving-App diff 2>&1 | head -40
  echo; echo "=== git diff --stat: Simulation-Platform-Manager ==="
  git -C ~/Simulation-Platform-Manager diff --stat 2>&1 | head -20
  git -C ~/Simulation-Platform-Manager diff 2>&1 | head -40
} > ~/harvest2/evidence/tester-edits.diff 2>&1
{
  echo "=== NTG config now vs ~/logs/NTG.yaml.orig ==="
  find ~/Network-Traffic-Generator -maxdepth 2 -name '*.yaml' -o -maxdepth 2 -name '*.yml' 2>/dev/null | head -10
  for y in ~/Network-Traffic-Generator/NTG.yaml ~/Network-Traffic-Generator/config/NTG.yaml; do
    [ -f "$y" ] && { echo "--- CURRENT $y:"; cat "$y"; }
  done
  echo "--- ORIG (~/logs/NTG.yaml.orig):"; cat ~/logs/NTG.yaml.orig 2>&1
  echo; echo "=== ntg-env / ntg-env2 interpreters ==="
  for py in ~/ntg-env/bin/python ~/ntg-env2/bin/python ~/nsr-env/bin/python; do
    [ -x "$py" ] && echo "$py -> $($py -c 'import sys;print(sys.version.split()[0])' 2>&1) | mininet: $($py -c 'import mininet;print(mininet.__file__)' 2>&1 | tail -1)"
  done
  echo; echo "=== NTG entrypoint / requirements ==="
  ls ~/Network-Traffic-Generator 2>&1
  echo "--- requirements:"; cat ~/Network-Traffic-Generator/requirements.txt 2>&1 | head -20
  echo; echo "=== does NTG import mininet? ==="
  grep -rn "import mininet\|from mininet" ~/Network-Traffic-Generator --include=*.py 2>/dev/null | head -10
  echo; echo "=== ndtwin-lab: ovs-topo-start section ==="
  sudo -n sed -n '1,200p' /usr/local/sbin/ndtwin-lab 2>&1
} > ~/harvest2/evidence/ntg-and-lab-probe.txt 2>&1
tar czf /tmp/run03-guest2.tgz -C ~ harvest2 2>&1 | head -5
ls -l /tmp/run03-guest2.tgz; echo "files: $(tar tzf /tmp/run03-guest2.tgz | wc -l)"
