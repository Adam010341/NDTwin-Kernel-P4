#!/usr/bin/env bash
# Why does ICMP cross the fabric while TCP does not?  Runs inside the guest.
# [Co-developed with claude code -- Adam]
# Not a measurement. Each step is a separate discriminating question, and the point is to
# find WHICH layer stops it. Every step has its own hard timeout and nothing uses `wait`:
# the first version hung and took the ssh transport with it, losing all output.
# No tcpdump: an AppArmor-shielded tcpdump cannot be killed even by root SIGKILL, and a
# diagnostic that can strand a process is worse than the ambiguity it resolves.
set -uo pipefail
ROOT="$HOME/bnslab-B"
OUT="$ROOT/raw/diag"; mkdir -p "$OUT"
cli() { sudo -n simple_switch_CLI --thrift-port 9090 2>/dev/null; }

printf '%s\n' "$(sed -n 's/^binary=//p' "$ROOT/identity_D.meta")" > "$ROOT/bmv2_binary_override"
rm -f "$ROOT/READY" "$ROOT/STOP"; sudo -n mn -c >/dev/null 2>&1 || true
BNSLAB_NONINTERACTIVE=1 setsid sudo -n -E python3 "$ROOT/bnslab_topo.py" > "$OUT/topo.log" 2>&1 &
for i in $(seq 1 45); do [ -f "$ROOT/READY" ] && break; sleep 2; done
[ -f "$ROOT/READY" ] || { echo "🔴 no READY"; tail -20 "$OUT/topo.log"; exit 1; }
H1=$(sed -n 's/^h1=//p' "$ROOT/READY"); H2=$(sed -n 's/^h2=//p' "$ROOT/READY")
{ echo "table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.0.1/32 => 00:00:00:00:00:01 1"
  echo "table_add MyIngress.ipv4_lpm MyIngress.ipv4_forward 10.0.0.2/32 => 00:00:00:00:00:02 2"; } | cli >/dev/null 2>&1
echo "fabric up: h1=$H1 h2=$H2"

echo ""
echo "=== 1. ICMP h1->h2 (known good) ==="
sudo -n timeout 10 mnexec -a "$H1" ping -c 2 -W 2 10.0.0.2 2>&1 | tail -2 | sed 's/^/  /'

echo ""
echo "=== 2. a plain TCP listener in h2, and is it listening? ==="
sudo -n mnexec -a "$H2" bash -c 'setsid timeout 25 python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind((\"0.0.0.0\",5301)); s.listen(4)
while True:
    c,a=s.accept(); c.sendall(b\"hello\"); c.close()
" >/dev/null 2>&1 &'
sleep 2
sudo -n timeout 8 mnexec -a "$H2" ss -tln 2>&1 | sed 's/^/  /' | head -5

echo ""
echo "=== 3. TCP connect h1 -> 10.0.0.2:5301 ==="
sudo -n timeout 15 mnexec -a "$H1" python3 -c "
import socket, time
s=socket.socket(); s.settimeout(8); t0=time.time()
try:
    s.connect(('10.0.0.2',5301)); d=s.recv(16)
    print('  CONNECTED in %.2fs, got %r' % (time.time()-t0, d))
except Exception as e:
    print('  TCP FAILED after %.2fs: %s' % (time.time()-t0, e))
" 2>&1

echo ""
echo "=== 4. TCP the OTHER way, h2 -> 10.0.0.1 (is it directional?) ==="
sudo -n mnexec -a "$H1" bash -c 'setsid timeout 20 python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind((\"0.0.0.0\",5303)); s.listen(4)
c,a=s.accept(); c.sendall(b\"back\"); c.close()
" >/dev/null 2>&1 &'
sleep 2
sudo -n timeout 15 mnexec -a "$H2" python3 -c "
import socket, time
s=socket.socket(); s.settimeout(8); t0=time.time()
try:
    s.connect(('10.0.0.1',5303)); print('  CONNECTED in %.2fs, got %r' % (time.time()-t0, s.recv(16)))
except Exception as e:
    print('  TCP FAILED after %.2fs: %s' % (time.time()-t0, e))
" 2>&1

echo ""
echo "=== 5. a bare UDP datagram h1->h2 (no handshake: isolates TCP from forwarding) ==="
sudo -n mnexec -a "$H2" bash -c 'setsid timeout 12 python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind((\"0.0.0.0\",5302)); s.settimeout(9)
try:
    d,a=s.recvfrom(64); open(\"/tmp/udp_result\",\"w\").write(\"GOT %r from %s\" % (d,a))
except Exception as e:
    open(\"/tmp/udp_result\",\"w\").write(\"NOTHING: %s\" % e)
" >/dev/null 2>&1 &'
sleep 2
sudo -n timeout 8 mnexec -a "$H1" python3 -c "
import socket
socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(b'ping-udp',('10.0.0.2',5302))
print('  h1 sent one datagram')
" 2>&1
sleep 6
echo "  h2 says: $(sudo -n timeout 5 mnexec -a "$H2" cat /tmp/udp_result 2>/dev/null || echo '(no result file)')"

echo ""
echo "=== 6. offload state (TSO/GSO/checksum) on both host interfaces ==="
for spec in "$H1 h1-eth0" "$H2 h2-eth0"; do
  set -- $spec
  echo "  $2: $(sudo -n timeout 8 mnexec -a "$1" ethtool -k "$2" 2>/dev/null | grep -E '^(tcp-segmentation-offload|generic-segmentation-offload|tx-checksumming|rx-checksumming):' | tr '\n' ' ')"
done

echo ""
echo "=== 7. did the switch see and forward them? (its own port counters) ==="
echo "show_ports" | cli 2>&1 | sed 's/^/  /' | head -8

touch "$ROOT/STOP"; sleep 4; sudo -n mn -c >/dev/null 2>&1 || true
echo ""
echo "=== diag done $(date -Is) ==="
