#!/usr/bin/env bash
#
# ndtwin-lab -- the root-side lab operations an agent may perform unattended.
#
# [Co-developed with claude code -- Adam]
#
# Install (both commands need sudo, run once):
#   sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
#   echo 'adam ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-lab' | sudo tee /etc/sudoers.d/ndtwin-lab
#
# Security shape, stated plainly: after install, anything running as adam can perform
# exactly the operations below as root -- start/stop the bmv2+NTG topology, type into the
# NTG CLI, read its screen, and start/stop the two app binaries. That is the whole surface:
# the script is root-owned (a non-root write cannot change what sudo runs), takes fixed
# subcommands only, and send-keys uses literal mode, so text lands in NTG's stdin rather
# than in any root shell. This replaces handing out NOPASSWD on adam-writable scripts,
# which would have been root-for-anyone-who-can-write-a-file.
#
# Everything runs inside root tmux sessions on a dedicated socket (-L ndtwinlab), so an
# operator can also `sudo tmux -L ndtwinlab attach -t topo` and watch or type by hand.

set -euo pipefail

TMUX="tmux -L ndtwinlab"
KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel
NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python
BRIDGE=$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py
ENERGY_DIR=/home/adam/Energy-Saving-App
SIM_DIR=/home/adam/Simulation-Platform-Manager

die() { echo "ndtwin-lab: $*" >&2; exit 1; }

session_running() { $TMUX has-session -t "$1" 2>/dev/null; }

case "${1:-}" in
    topo-start)
        session_running topo && die "topo session already running (topo-stop first)"
        $TMUX new-session -d -s topo -c "$KERNEL_DIR/p4_proxy/mininet" \
            "$NTG_PY" "$BRIDGE"
        echo "topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)"
        ;;
    topo-cmd)
        shift; [ $# -ge 1 ] || die "usage: topo-cmd <text to type into the NTG prompt>"
        session_running topo || die "no topo session"
        # -l = literal: the text is keystrokes for NTG's stdin, never key names or shell.
        $TMUX send-keys -t topo -l -- "$*"
        $TMUX send-keys -t topo Enter
        ;;
    topo-out)
        session_running topo || die "no topo session"
        $TMUX capture-pane -t topo -p -S "-${2:-60}"
        ;;
    topo-stop)
        session_running topo || { echo "no topo session"; exit 0; }
        # Ctrl-C first so the bridge's teardown (net.stop + manifest reap) gets to run;
        # kill the session only if it lingers.
        $TMUX send-keys -t topo C-c || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            session_running topo || break
            sleep 1
        done
        session_running topo && $TMUX kill-session -t topo
        echo "topo stopped"
        ;;
    cleanup)
        # The orphan sweep the topology's own start also performs, callable on demand --
        # plus the stray topology pythons that outlive their terminals (seen live 2026-08-15:
        # a bridge survived its closed terminal and needed a manual root kill). Everything a
        # dead round can leave behind goes here, so no human is needed to reset the lab.
        pkill -f ntg_bmv2_topo.py 2>/dev/null || true
        pkill -f p4_testbed_topo.py 2>/dev/null || true
        pkill -f "Network-Traffic-Generator/testbed_topo.py" 2>/dev/null || true
        mn -c >/dev/null 2>&1 || true
        pkill -f simple_switch_grpc 2>/dev/null || true
        rm -f /tmp/ndtwin_p4_switches.json
        echo "cleanup done"
        ;;
    ovs-topo-start)
        # NTG's own OVS topology (128 hosts, RemoteController -> Ryu). Ryu must already be
        # listening on 6653 -- the agent starts it unprivileged before calling this.
        session_running topo && die "topo session already running (topo-stop first)"
        $TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator \
            "$NTG_PY" /home/adam/Network-Traffic-Generator/testbed_topo.py
        echo "OVS topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)"
        ;;
    ovs-topo-4host)
        # OVS on the P4 test bed's own 10-switch/4-host layout, so a P4-vs-OVS comparison
        # varies the data plane and nothing else. Every such comparison before 2026-08-17 also
        # changed the topology (4 hosts / 40 edges vs 128 hosts / 288 edges) and the link
        # shaping, so none of them could attribute a difference to the data plane.
        # Ryu must already be listening on 6653 -- the agent starts it unprivileged first.
        session_running topo && die "topo session already running (topo-stop first)"
        $TMUX new-session -d -s topo -c "$KERNEL_DIR" \
            "$NTG_PY" "$KERNEL_DIR/tools/test_workflow/ovs_4host_topo.py"
        echo "OVS 4-host topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)"
        ;;
    energy-start)
        session_running energy && die "energy session already running"
        $TMUX new-session -d -s energy -c "$ENERGY_DIR" ./energy_saving_app
        echo "energy_saving_app started"
        ;;
    energy-stop)
        session_running energy || { echo "no energy session"; exit 0; }
        $TMUX send-keys -t energy C-c || true; sleep 2
        session_running energy && $TMUX kill-session -t energy
        echo "energy stopped"
        ;;
    energy-out)
        session_running energy || die "no energy session"
        $TMUX capture-pane -t energy -p -S "-${2:-60}"
        ;;
    sim-start)
        session_running sim && die "sim session already running"
        $TMUX new-session -d -s sim -c "$SIM_DIR" ./simulation_platform_manager
        echo "simulation_platform_manager started"
        ;;
    sim-stop)
        session_running sim || { echo "no sim session"; exit 0; }
        $TMUX send-keys -t sim C-c || true; sleep 2
        session_running sim && $TMUX kill-session -t sim
        echo "sim stopped"
        ;;
    sim-out)
        session_running sim || die "no sim session"
        $TMUX capture-pane -t sim -p -S "-${2:-60}"
        ;;
    status)
        $TMUX list-sessions 2>/dev/null || echo "no lab sessions"
        printf 'bmv2: %s  mininet: %s\n' \
            "$(pgrep -c -f simple_switch_grpc || true)" \
            "$(ps -eo args | awk '$NF ~ /^mininet:/{c++} END{print c+0}')"
        ;;
    *)
        die "usage: ndtwin-lab {topo-start|ovs-topo-start|ovs-topo-4host|topo-cmd <text>|topo-out [n]|topo-stop|cleanup|energy-start|energy-stop|energy-out [n]|sim-start|sim-stop|sim-out [n]|status}"
        ;;
esac
