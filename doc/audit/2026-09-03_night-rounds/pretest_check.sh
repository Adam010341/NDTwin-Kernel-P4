#!/usr/bin/env bash
# Read-only pre-test environment check for the 09-04 full-machine test. No sudo beyond the
# NOPASSWD tc-qdisc-show shape; no process is signalled; nothing is written outside the scratchpad.
R=/home/adam/Desktop/NDTwin-Kernel
echo "### pretest check $(date '+%F %T')"
echo "## git: trunk=$(git -C $R rev-parse --short trunk) main-checkout HEAD=$(git -C $R rev-parse --short HEAD) ($(git -C $R rev-parse --abbrev-ref HEAD)); dirty=$(git -C $R status --porcelain | wc -l)"
B=$R/build/bin/ndtwin_kernel; [[ -x $B ]] && echo "## kernel binary: sha=$(sha256sum $B | cut -c1-8) mtime=$(stat -c %y $B | cut -c1-16) size=$(stat -c %s $B)" || echo "## kernel binary: MISSING"
echo "## helper: installed=$(sha256sum /usr/local/sbin/ndtwin-lab | cut -c1-8) repo=$(sha256sum $R/tools/test_workflow/ndtwin-lab | cut -c1-8)"
echo "## processes by name (ps -C):"; ps -C ndtwin_kernel,simple_switch_grpc,simple_switch,ovs-vswitchd,ovsdb-server,ryu-manager,osken-manager,mininet,mnexec,p4_proxy,python3 -o pid,user,etime,comm,args --no-headers 2>/dev/null | grep -v -E 'pretest_check|claude' | cut -c1-140 | head -20
echo "## listeners (ss -ltn) on lab ports:"; ss -ltnp 2>/dev/null | awk 'NR==1 || /:(8000|8080|8081|6633|6653|9090|50051|50052|6343|9559|8443) /' | cut -c1-150
echo "## lab-shaped interfaces:"; ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(s[0-9]+-eth[0-9]+|h[0-9]+-eth[0-9]+|s[0-9]+|br-|ovs-)' | tr '\n' ' '; echo
for d in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^s[0-9]+-eth[0-9]+$' | head -40); do q=$(sudo -n tc qdisc show dev "$d" 2>/dev/null | grep -c -E 'netem|htb'); [[ "$q" -gt 0 ]] && echo "   netem/htb residue on $d"; done
echo "## .test_run state (main + worktrees):"; for w in $R $R/wt-*; do [[ -d $w/.test_run ]] || continue; echo "   $w: $(ls $w/.test_run 2>/dev/null | tr '\n' ' ')"; [[ -f $w/.test_run/lab.claim ]] && echo "      claim: $(cat $w/.test_run/lab.claim | tr '\n' ' ' | cut -c1-120)"; done
echo "## ndt status:"; NDT_OWNER=auditor $R/tools/test_workflow/ndt status 2>&1 | sed -n '1,8p'
echo "## build guard: lock holder=$(fuser /tmp/ndtwin-build.lock 2>/dev/null | tr -s ' ' ); scopes: $(systemctl --user list-units 'ndtwin-build-*' --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
echo "## memory: $(free -m | awk '/Mem:/{print "used="$3"M avail="$7"M"} /Swap:/{print "swap="$3"M"}' | tr '\n' ' '); pressure: $(grep some /proc/pressure/memory | cut -d' ' -f2,3)"
echo "## disk: $(df -h / /tmp 2>/dev/null | awk 'NR>1{print $6"="$4" free"}' | tr '\n' ' ')"
echo "## oomd kills since 13:00: $(journalctl --user -u systemd-oomd --since '13:00' --no-pager 2>/dev/null | grep -c -i kill) (user) $(journalctl -k --since '13:00' --no-pager 2>/dev/null | grep -c -i -E 'oom-kill|Killed process')"
echo "## audit-raw tip=$(git -C $R rev-parse --short audit-raw) integrate=$(git -C $R rev-parse --short integrate/2026-09-03-auditor-merge)"
