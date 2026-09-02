#!/bin/bash
B=http://localhost:8000
c(){ echo "### $1"; shift; curl -sS -m 15 -w '\n[HTTP %{http_code}]\n' "$@"; echo "-----"; }
echo "############## LOCK API: the doc says all of these are 400 since 2026-08-30 ##############"
c "acquire, NO type field"        -X POST -H 'Content-Type: application/json' -d '{"ttl":30}' $B/ndt/acquire_lock
c "acquire, EMPTY body"           -X POST -H 'Content-Type: application/json' -d '{}' $B/ndt/acquire_lock
c "acquire, type is a NUMBER"     -X POST -H 'Content-Type: application/json' -d '{"type":123,"ttl":30}' $B/ndt/acquire_lock
c "acquire, type is UNKNOWN string" -X POST -H 'Content-Type: application/json' -d '{"type":"banana_lock","ttl":30}' $B/ndt/acquire_lock
c "renew, NO body at all"         -X POST -H 'Content-Type: application/json' $B/ndt/renew_lock
c "release, NO type field"        -X POST -H 'Content-Type: application/json' -d '{}' $B/ndt/release_lock
echo "--- clean up whatever I just took ---"
curl -sS -X POST -H 'Content-Type: application/json' -d '{"type":"routing_lock"}' $B/ndt/release_lock; echo
echo
echo "############## D12/D13: are CPU and MEMORY the same numbers? sample twice ##############"
for n in 1 2; do
  echo "sample $n:"
  echo -n "  cpu: "; curl -sS $B/ndt/get_cpu_utilization
  echo; echo -n "  mem: "; curl -sS $B/ndt/get_memory_utilization; echo
  sleep 3
done
echo
echo "############## D15/D20 EFFECT: did the rename actually land? ##############"
echo "-- doc says modify_device_name updates 'the NDTwin topology and StaticNetworkTopology.json' --"
echo -n "graph_data mentions HstA? : "; curl -sS $B/ndt/get_graph_data | grep -o '"device_name":"HstA"' | head -1; echo
echo -n "nickname of dpid 1 now    : "; curl -sS "$B/ndt/get_nickname?dpid=1"; echo
echo "-- did the on-disk topology JSON change? --"
cd ~/Desktop/NDTwin-Kernel
git status --short setting/ 
grep -c 'HstA\|Sinica-Switch-01' setting/StaticNetworkTopologyMininet_10Switches.json
echo "-- and the static-topology endpoint? --"
curl -sS $B/ndt/get_static_topology_json | grep -c 'HstA'
echo
echo "############## D16 EFFECT: app_register should create /srv/nfs/sim/<app_id> ##############"
ls -la /srv/nfs/sim/ 2>&1 | head -5
echo "-- register a second app: does app_id increment? --"
curl -sS -X POST -H 'Content-Type: application/json' -d '{"app_name":"MySecondApp","simulation_completed_url":"http://127.0.0.1:9000/simulation_completed"}' $B/ndt/app_register; echo
date +%H:%M:%S
