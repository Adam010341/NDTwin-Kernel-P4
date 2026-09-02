set -u; cd ~
{ echo "captured: $(date -u +%FT%TZ)"; for d in ~/Desktop/NDTwin-Kernel ~/p4-guide ~/Desktop/Network-Traffic-Generator ~/Desktop/Network-State-Recorder ~/Desktop/Network-Traffic-Visualizer ~/Desktop/Web-GUI ~/Energy-Saving-App ~/Simulation-Platform-Manager; do [ -d "$d" ] && echo "$d HEAD=$(git -C $d rev-parse --short=12 HEAD 2>/dev/null) dirty=$(git -C $d status --porcelain 2>/dev/null | wc -l)" || echo "$d ABSENT"; done
  echo "--- kernel repo dirty files:"; git -C ~/Desktop/NDTwin-Kernel status --porcelain 2>/dev/null | head -20
  echo "--- docs snapshot:"; cat ~/ndtwin-docs/DOCS-SNAPSHOT.txt 2>/dev/null | head -3
  echo "--- binaries:"; ls -l --time-style=+%H:%M ~/Desktop/NDTwin-Kernel/bin/ 2>/dev/null | head; which p4c simple_switch simple_switch_grpc 2>&1
  echo "--- conda envs:"; ls ~/miniconda3/envs 2>/dev/null
  echo "--- home listing:"; ls -la --time-style=+%H:%M ~ | head -40
  echo "--- .test_run:"; ls -la --time-style=+%H:%M ~/Desktop/NDTwin-Kernel/.test_run/logs ~/Desktop/NDTwin-Kernel/.test_run/pids 2>/dev/null
  echo "--- p4dev log head/tail:"; head -5 ~/logs/p4dev_v8.log | cut -c1-120; echo ...; tail -3 ~/logs/p4dev_v8.log | cut -c1-120; wc -c < ~/logs/p4dev_v8.log
} > ~/GUEST-STATE.txt 2>&1
tar czf /tmp/run02-guest.tgz GUEST-STATE.txt JOURNAL.md BUGS.md CHECKLIST.md SUMMARY_FINDINGS.md *.sh p4_install.pid $(ls logs/*.log | grep -v p4dev_v8) Desktop/NDTwin-Kernel/.test_run/logs 2>&1 | head -5
ls -l /tmp/run02-guest.tgz
