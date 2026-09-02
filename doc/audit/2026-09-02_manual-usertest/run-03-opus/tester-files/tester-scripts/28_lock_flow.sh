#!/bin/bash
B=http://localhost:8000
rel(){ curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"type":"routing_lock"}' $B/ndt/acquire_lock 2>/dev/null
       curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"type":"routing_lock"}' $B/ndt/release_lock 2>/dev/null; }
t(){ echo "### $1"; echo "    sent: $2"; curl -sS -m 15 -w '\n    [HTTP %{http_code}]\n' -X POST -H 'Content-Type: application/json' -d "$2" $B$3; rel; }
echo "############## lock tests, each from a released state ##############"
rel
t "acquire, no type"            '{"ttl":30}'                 /ndt/acquire_lock
t "acquire, empty body"         '{}'                          /ndt/acquire_lock
t "acquire, type=number"        '{"type":123,"ttl":30}'       /ndt/acquire_lock
t "acquire, type=unknown str"   '{"type":"banana_lock"}'      /ndt/acquire_lock
t "release, no type"            '{}'                          /ndt/release_lock
t "renew, no type"              '{"ttl":30}'                  /ndt/renew_lock
echo "-- and the documented-correct form, for contrast --"
t "acquire, type=power_lock"    '{"type":"power_lock","ttl":30}' /ndt/acquire_lock
curl -sS -X POST -H 'Content-Type: application/json' -d '{"type":"power_lock"}' $B/ndt/release_lock; echo
echo
echo "############## FLOW ENTRY install/modify/delete, with the EFFECT checked on the switch ##############"
echo "-- BEFORE: s1 rules matching 10.0.0.99 --"
sudo ovs-ofctl dump-flows s1 | grep -c 'nw_dst=10.0.0.99'
echo "-- (a) manual's own example values (its dpid does not exist on my fabric) --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":106225808380928,"priority":99,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.3"},"actions":[{"type":"OUTPUT","port":24}]}' \
  $B/ndt/install_flow_entry
echo "-- (b) my own values: dpid 1 (s1), a destination that has no rule yet --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":1,"priority":99,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.99"},"actions":[{"type":"OUTPUT","port":2}]}' \
  $B/ndt/install_flow_entry
sleep 3
echo "-- AFTER install: the actual rule on s1 --"
sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.99'
echo "-- (c) modify it to output:5 --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":1,"priority":99,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.99"},"actions":[{"type":"OUTPUT","port":5}]}' \
  $B/ndt/modify_flow_entry
sleep 3
echo "-- AFTER modify --"
sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.99'
echo "-- (d) delete it --"
curl -sS -w '\n[HTTP %{http_code}]\n' -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.99"}}' \
  $B/ndt/delete_flow_entry
sleep 3
echo "-- AFTER delete: count of matching rules (expect 0) --"
sudo ovs-ofctl dump-flows s1 | grep -c 'nw_dst=10.0.0.99'
echo "-- did the manual's non-existent dpid actually create anything anywhere? --"
for i in $(seq 1 10); do sudo ovs-ofctl dump-flows s$i | grep -c 'nw_dst=10.0.0.3,\|priority=99'; done | tr '\n' ' '; echo
date +%H:%M:%S
