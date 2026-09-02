# run-03 (opus) harvest: capture volatile tmux panes first, then guest state, then tar.
# Read-only apart from writing ~/pane_*.txt, ~/GUEST-STATE.txt, /tmp/run03-guest.tgz.
# [Co-developed with claude code -- Adam]
set -u; cd ~
for S in KERNEL MN NTG P4 RYU; do
  tmux capture-pane -t "$S" -p -S -3000 > ~/pane_$S.txt 2>>~/pane_capture_errors.txt \
    || echo "CAPTURE FAILED: $S" >> ~/pane_capture_errors.txt
done
{
  echo "captured: $(date -u +%FT%TZ)  (local $(date +%F' '%T' '%Z))"
  echo "--- uptime / mem:"; uptime; free -m | head -2
  echo "--- tmux ls:"; tmux ls 2>&1
  echo "--- tmux pane sizes:"; ls -l --time-style=+%H:%M:%S ~/pane_*.txt 2>&1
  echo "--- tmux -L ndtwinlab (root):"; sudo -n tmux -L ndtwinlab ls 2>&1 | head -5
  echo "--- listeners (ss -tlnpH):"; ss -tlnpH 2>&1
  echo "--- ls -la ~/logs:"; ls -la --time-style=+%m-%d_%H:%M:%S ~/logs 2>&1
  echo "--- df -h /:"; df -h / 2>&1
  echo "--- home listing:"; ls -la --time-style=+%m-%d_%H:%M:%S ~ 2>&1
  echo "--- /tmp listing (tester scripts):"; ls -la --time-style=+%m-%d_%H:%M:%S /tmp 2>&1 | head -60
  echo "--- repos:"
  for d in ~/Desktop/NDTwin-Kernel ~/p4-guide ~/p4c ~/behavioral-model ~/ndtwin-docs \
           ~/Desktop/Network-Traffic-Generator ~/Desktop/Network-State-Recorder \
           ~/Desktop/Network-Traffic-Visualizer ~/Desktop/Web-GUI \
           ~/Energy-Saving-App ~/Simulation-Platform-Manager; do
    if [ -d "$d" ]; then
      echo "== $d"
      git -C "$d" log --oneline -3 2>&1 | sed 's/^/   /'
      echo "   status --porcelain:"; git -C "$d" status --porcelain 2>&1 | head -20 | sed 's/^/     /'
    else echo "== $d ABSENT"; fi
  done
  echo "--- docs snapshot:"; cat ~/ndtwin-docs/DOCS-SNAPSHOT.txt 2>&1 | head -6
  echo "--- .test_run:"; ls -la --time-style=+%m-%d_%H:%M:%S ~/Desktop/NDTwin-Kernel/.test_run/pids ~/Desktop/NDTwin-Kernel/.test_run/logs 2>&1
  echo "--- .test_run/pids contents:"
  for f in ~/Desktop/NDTwin-Kernel/.test_run/pids/*; do
    [ -f "$f" ] || continue; echo "  == $f"; cat "$f" 2>&1 | sed 's/^/     /'
  done
  echo "--- pid liveness for recorded pids:"
  for f in ~/Desktop/NDTwin-Kernel/.test_run/pids/*.pid ~/*.pid; do
    [ -f "$f" ] || continue; p=$(tr -dc '0-9' < "$f")
    [ -n "$p" ] || continue
    if [ -d "/proc/$p" ]; then
      echo "  $f pid=$p ALIVE start=$(stat -c %y /proc/$p | cut -c1-19) cmd=$(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-110)"
    else echo "  $f pid=$p GONE"; fi
  done
  echo "--- binaries:"; ls -l --time-style=+%m-%d_%H:%M ~/Desktop/NDTwin-Kernel/bin/ 2>&1 | head -20
  command -v p4c simple_switch simple_switch_grpc ndtwin-lab 2>&1
  ls -l /usr/local/sbin/ndtwin-lab /usr/local/bin/ndtwin-lab 2>&1
  echo "--- P4 tmux pane tail (build finished?):"; tail -25 ~/pane_P4.txt 2>&1
  echo "--- NTG tmux pane tail:"; tail -25 ~/pane_NTG.txt 2>&1
  echo "--- conda envs:"; ls ~/miniconda3/envs 2>&1
  echo "--- python interpreters:"; for py in /usr/bin/python3 ~/miniconda3/envs/*/bin/python ~/p4dev-python-venv/bin/python; do
    [ -x "$py" ] && echo "  $py -> $($py -c 'import sys;print(sys.version.split()[0])' 2>&1) mininet=$($py -c 'import mininet;print(mininet.__file__)' 2>&1 | tail -1)"; done
} > ~/GUEST-STATE.txt 2>&1
cd ~
tar czf /tmp/run03-guest.tgz \
  GUEST-STATE.txt pane_*.txt $(ls *.md 2>/dev/null) $(ls *.txt 2>/dev/null | grep -v '^pane_\|^GUEST-STATE') \
  $(ls *.sh *.yaml *.yml *.orig *.pid 2>/dev/null) logs \
  Desktop/NDTwin-Kernel/.test_run 2>&1 | head -10
ls -l /tmp/run03-guest.tgz
echo "=== TAR CONTENTS ==="; tar tzf /tmp/run03-guest.tgz | head -100
echo "=== count: $(tar tzf /tmp/run03-guest.tgz | wc -l)"
