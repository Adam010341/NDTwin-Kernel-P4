set -u
echo "=== clock ==="; date -u +%FT%TZ; uptime -p
echo "=== files ==="; wc -l ~/JOURNAL.md ~/BUGS.md ~/CHECKLIST.md; md5sum ~/JOURNAL.md ~/BUGS.md ~/CHECKLIST.md | cut -c1-16,33-
echo "--- journal sections (all) ---"; grep -n "^## " ~/JOURNAL.md
echo "--- BUG ids ---"; grep -n "^#* *BUG-0[0-9][0-9]\|^\*\*BUG-0[0-9][0-9]" ~/BUGS.md | cut -c1-120
echo "--- checklist outcomes ---"; grep -o "WORKS-BUT\|WORKS\|BROKEN\|NOT-TRIED\|SKIPPED" ~/CHECKLIST.md | sort | uniq -c
echo "=== install state ==="; ls ~/Desktop/NDTwin-Kernel/build/bin/ 2>&1 | head -5; for b in mn ovs-vsctl simple_switch_grpc p4c-bm2-ss ryu-manager docker java; do printf '%s=%s ' "$b" "$(command -v $b || echo MISSING)"; done; echo
simple_switch_grpc --version 2>&1; p4c-bm2-ss --version 2>&1 | head -2
echo "--- p4 venv ---"; cat ~/p4dev-python-venv/pyvenv.cfg 2>&1 | head -3; echo "trees in HOME: $(ls -d ~/p4c ~/behavioral-model ~/PI ~/mininet ~/ptf 2>/dev/null | wc -l)  trees in repo: $(ls -d ~/Desktop/NDTwin-Kernel/p4c ~/Desktop/NDTwin-Kernel/behavioral-model 2>/dev/null | wc -l)"
grep -n "Total time\|requires a different Python" ~/logs/step6.1_p4toolchain.log 2>/dev/null | tail -3
echo "--- repo ---"; cd ~/Desktop/NDTwin-Kernel && echo "HEAD=$(git rev-parse --short HEAD) remote=$(git remote get-url origin)"; git status --porcelain | head -25; echo "porcelain_lines=$(git status --porcelain | wc -l)"; git diff --stat | tail -6
echo "=== BUG-003 ndtwin-lab ==="; ls -la /usr/local/bin/ndt /usr/local/sbin/ndtwin-lab /usr/local/bin/ndtwin-lab 2>&1; find . -name "ndtwin-lab*" -not -path "./.git/*" 2>/dev/null | head -3; grep -n "ndtwin-lab" tools/ndt 2>/dev/null | head -5 || true; ls tools 2>/dev/null | head -12
echo "=== BUG-009 Dockerfile ==="; f=$(find . -name Dockerfile -not -path "./.git/*" | head -3); echo "$f"; for d in $f; do grep -n "pnpm" "$d" | head -4; done; git diff -- $f | grep "^[-+]" | grep -v "^+++\|^---" | head -6
echo "=== running now ==="; k=0; r=0; s=0; j=0; for p in /proc/[0-9]*; do e=$(readlink "$p/exe" 2>/dev/null) || continue; case "$e" in *ndtwin_kernel*) k=$((k+1)); echo "kernel pid=${p#/proc/} :: $(tr '\0' ' ' < $p/cmdline | cut -c1-120)";; *simple_switch_grpc*) s=$((s+1));; *java*) j=$((j+1)); echo "java pid=${p#/proc/} :: $(tr '\0' ' ' < $p/cmdline | cut -c1-100)";; esac; case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *ryu-manager*) r=$((r+1));; esac; done; echo "kernel=$k ryu=$r simple_switch_grpc=$s java=$j"
docker ps --format "{{.Names}} {{.Status}} {{.Ports}}" 2>&1 | head -6
echo "listeners: $(ss -tlnH | awk '{print $4}' | sort -u | tr '\n' ' ')"
echo "=== ESA / s9 claim (live) ==="; curl -s -m 8 http://localhost:8000/ndt/get_graph_data > /tmp/g.json; echo "bytes=$(stat -c %s /tmp/g.json 2>/dev/null)"; python3 - <<'PY'
import json
try:
    d=json.load(open('/tmp/g.json'))
except Exception as e:
    print("parse fail:", e); raise SystemExit
out=[]
def walk(x):
    if isinstance(x,dict):
        if 'is_up' in x: out.append((x.get('name') or x.get('id') or x.get('ip'), x.get('ip'), x['is_up']))
        for v in x.values(): walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d)
print("nodes with is_up:", len(out))
for n in sorted(out, key=lambda t: str(t[0])): print("  ", n)
PY
echo "=== BUG-011 cpu util (live) ==="; curl -s -m 8 "http://localhost:8000/ndt/get_cpu_utilization" | head -c 300; echo
echo "=== BUG-010 evidence ==="; grep -ln "shutdown\|Shutting down\|exiting" ~/logs/kernel_*.log 2>/dev/null; grep -n -i "shutdown complete\|shutting down\|exit" ~/logs/kernel_session2.log 2>/dev/null | tail -4
echo "=== ESA log ==="; ls ~/logs | grep -i "esa\|energy\|sim" ; grep -rn "set_switches_power_state" ~/logs/*.log 2>/dev/null | tail -3 | cut -c1-200
