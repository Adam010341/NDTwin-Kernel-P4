# run-04 (sonnet) harvest: tmux panes (if any), guest state, then tar.
# Read-only on the project apart from writing ~/pane_*.txt, ~/GUEST-STATE.txt, /tmp/run04-guest.tgz.
# [Co-developed with claude code -- Adam]
set -u; cd ~
: > ~/pane_capture_errors.txt
if tmux ls >/dev/null 2>&1; then
  for S in $(tmux ls -F '#{session_name}' 2>/dev/null); do
    tmux capture-pane -t "$S" -p -S -3000 > ~/pane_$S.txt 2>>~/pane_capture_errors.txt \
      || echo "CAPTURE FAILED: $S" >> ~/pane_capture_errors.txt
  done
else
  echo "NO TMUX SERVER AT HARVEST TIME: $(tmux ls 2>&1)" >> ~/pane_capture_errors.txt
fi
sudo -n tmux -L ndtwinlab ls >/dev/null 2>&1 && \
  for S in $(sudo -n tmux -L ndtwinlab ls -F '#{session_name}' 2>/dev/null); do
    sudo -n tmux -L ndtwinlab capture-pane -t "$S" -p -S -3000 > ~/pane_root_$S.txt 2>>~/pane_capture_errors.txt
  done
{
  echo "captured: $(date -u +%FT%TZ)  (local $(date +%F' '%T' '%Z))"
  echo "--- uptime / mem:"; uptime; free -m | head -2
  echo "--- tmux ls (user):"; tmux ls 2>&1
  echo "--- tmux -L ndtwinlab (root):"; sudo -n tmux -L ndtwinlab ls 2>&1 | head -5
  echo "--- pane capture errors:"; cat ~/pane_capture_errors.txt 2>&1
  echo "--- tmux pane sizes:"; ls -l --time-style=+%H:%M:%S ~/pane_*.txt 2>&1
  echo "--- listeners (ss -tlnpH):"; ss -tlnpH 2>&1
  echo "--- udp listeners (ss -ulnpH):"; ss -ulnpH 2>&1
  echo "--- sflow port 6343 specifically:"; ss -ulnpH 'sport = :6343' 2>&1; ss -tlnpH 'sport = :6343' 2>&1
  echo "--- ls -la ~/logs:"; ls -la --time-style=+%m-%d_%H:%M:%S ~/logs 2>&1
  echo "--- df -h /:"; df -h / 2>&1
  echo "--- home listing:"; ls -la --time-style=+%m-%d_%H:%M:%S ~ 2>&1
  echo "--- /tmp listing:"; ls -la --time-style=+%m-%d_%H:%M:%S /tmp 2>&1 | head -80
  echo "--- repos:"
  for d in ~/Desktop/NDTwin-Kernel ~/p4-guide ~/p4c ~/behavioral-model ~/ndtwin-docs ~/mininet \
           ~/Network-Traffic-Generator ~/Network-State-Recorder ~/Network-Traffic-Visualizer \
           ~/Web-GUI ~/Energy-Saving-App ~/Simulation-Platform-Manager ~/PI ~/ptf ~/p4runtime-shell ~/tutorials; do
    if [ -d "$d" ]; then
      echo "== $d"
      git -C "$d" log --oneline -3 2>&1 | sed 's/^/   /'
      echo "   status --porcelain:"; git -C "$d" status --porcelain 2>&1 | head -25 | sed 's/^/     /'
    else echo "== $d ABSENT"; fi
  done
  echo "--- docs snapshot:"; cat ~/ndtwin-docs/DOCS-SNAPSHOT.txt 2>&1 | head -8
  echo "--- docs HEAD:"; git -C ~/ndtwin-docs log --oneline -3 2>&1
  echo "--- .test_run:"; ls -laR --time-style=+%m-%d_%H:%M:%S ~/Desktop/NDTwin-Kernel/.test_run 2>&1 | head -60
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
  echo "--- BUG-3 orphan pid 59174 now:"; [ -d /proc/59174 ] && echo ALIVE || echo GONE
  echo "--- any ndtwin_kernel / ryu / simple_switch alive (via /proc scan, no pgrep):"
  for p in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < $p/cmdline 2>/dev/null); case "$c" in
      *ndtwin_kernel*|*ryu-manager*|*simple_switch*|*mn\ *|*ovs-vswitchd*) echo "  ${p#/proc/}: $(echo "$c" | cut -c1-120)";;
    esac; done
  echo "--- binaries:"; ls -l --time-style=+%m-%d_%H:%M ~/Desktop/NDTwin-Kernel/bin/ 2>&1 | head -20
  command -v p4c simple_switch simple_switch_grpc ndtwin-lab ndt 2>&1
  ls -l /usr/local/sbin/ndtwin-lab /usr/local/bin/ndtwin-lab ~/.local/bin/ndt 2>&1
  echo "--- .local birth/stat:"; stat ~/.local ~/.local/bin 2>&1 | head -30
  echo "--- .profile PATH stanza:"; grep -n -A3 -B3 'local/bin' ~/.profile 2>&1
  echo "--- p4 versions (manual's Step 6.2 acceptance):"
  bash -l -c 'source ~/p4setup.bash 2>/dev/null; simple_switch_grpc --version 2>&1 | head -2; p4c-bm2-ss --version 2>&1 | head -2; mn --version 2>&1 | head -2' 2>&1
  echo "--- conda envs:"; ls ~/miniconda3/envs 2>&1
  echo "--- venvs:"; ls -d ~/ntg-env ~/nsr-env ~/p4dev-python-venv 2>&1
  echo "--- python interpreters:"; for py in /usr/bin/python3 ~/miniconda3/envs/*/bin/python ~/p4dev-python-venv/bin/python ~/ntg-env/bin/python ~/nsr-env/bin/python; do
    [ -x "$py" ] && echo "  $py -> $($py -c 'import sys;print(sys.version.split()[0])' 2>&1) mininet=$($py -c 'import mininet;print(mininet.__file__)' 2>&1 | tail -1)"; done
  echo "--- bash_history:"; cat ~/.bash_history 2>&1
  echo "--- SUMMARY present in JOURNAL?:"; grep -c '^## SUMMARY' ~/JOURNAL.md 2>&1
  echo "--- wc -l of the three source files:"; wc -l ~/JOURNAL.md ~/CHECKLIST.md ~/BUGS.md ~/JOURNAL.md.bak-dedup 2>&1
  echo "--- sizes NOT tarred:"; du -sh ~/install-details 2>&1; ls ~/install-details 2>&1 | head; ls ~/install-details 2>/dev/null | wc -l
} > ~/GUEST-STATE.txt 2>&1
cd ~
tar czf /tmp/run04-guest.tgz \
  GUEST-STATE.txt \
  $(ls pane_*.txt 2>/dev/null) \
  $(ls *.md 2>/dev/null) \
  $(ls *.bak-dedup 2>/dev/null) \
  $(ls *.sh *.json *.py *.yaml *.yml *.orig *.pid *.bash *.csh 2>/dev/null) \
  log.txt logs \
  .bash_history \
  Desktop/NDTwin-Kernel/.test_run 2>&1 | head -10
ls -l /tmp/run04-guest.tgz
echo "=== TAR COUNT: $(tar tzf /tmp/run04-guest.tgz | wc -l)"
echo "=== TAR CONTENTS ==="; tar tzf /tmp/run04-guest.tgz
echo "=== sha256 ==="; sha256sum /tmp/run04-guest.tgz
