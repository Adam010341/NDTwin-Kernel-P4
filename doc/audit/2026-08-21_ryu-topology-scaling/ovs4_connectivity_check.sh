#!/usr/bin/env bash
# Does the ovs4 fabric actually forward? intelligent_router.py:32-35 says a 4-host fabric
# running the 128-host route file is 100% loss on every pair. Test it rather than trust it.
# Script file so `ps` cannot match the pattern on our own command line.
H1=$1; H2=$2; H3=$3; H4=$4
for pair in "1 10.0.0.2" "1 10.0.0.3" "1 10.0.0.4"; do
    set -- $pair
    src=$1; dst=$2
    eval "pid=\$H$src"
    out=$(sudo -n mnexec -a "$pid" ping -c 3 -W 2 -i 0.3 "$dst" 2>&1 | tail -2)
    echo "h$src -> $dst"
    echo "$out" | sed 's/^/    /'
done
echo
echo "=== s1 flow rules mentioning a port that may not exist ==="
sudo -n ovs-ofctl dump-flows s1 2>/dev/null | grep -c 'nw_dst' || echo "0"
echo "--- sample of s1 nw_dst rules ---"
sudo -n ovs-ofctl dump-flows s1 2>/dev/null | grep 'nw_dst' | head -4
echo "--- s1 actual ports ---"
sudo -n ovs-ofctl show s1 2>/dev/null | grep -oE '^ [0-9]+\(' | tr -d ' (' | tr '\n' ' '
echo
