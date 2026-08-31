#!/usr/bin/env bash
# A-6 banner + B-2c proxy curls.
# Recipe source: doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md section 6
# ("Live verification recipes, for when a fabric is up"). Commands copied verbatim.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
P=.test_run/logs/p4_proxy.log

echo "##### A-6: the startup banner must not claim a ruined round #####"
echo "--- recipe command, verbatim ---"
echo 'grep -n "did not acknowledge\|acknowledged all\|stay partly disabled" .test_run/logs/p4_proxy.log'
grep -n "did not acknowledge\|acknowledged all\|stay partly disabled" $P
echo "(grep rc=$?)"
echo
echo "--- counted per alternative (expect: one of the first two present, third ZERO) ---"
for pat in "acknowledged all" "did not acknowledge" "stay partly disabled"; do
    printf '%-24s %s hit(s)\n' "$pat" "$(grep -c "$pat" $P 2>/dev/null || echo 0)"
done

echo
echo "##### B-2c: CIDR ipv4_dst must be 400, not 500 #####"
echo "--- status code ---"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.5/32"},"actions":[{"type":"OUTPUT","port":1}]}'
echo "--- body (must contain nw_dst and 10.0.0.5/32; must NOT contain a bare 10.0.0.5) ---"
BODY=$(curl -s -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.5/32"},"actions":[{"type":"OUTPUT","port":1}]}' | head -c 400)
echo "$BODY"
echo
echo "  contains 'nw_dst'      : $(grep -c 'nw_dst' <<<"$BODY")"
echo "  contains '10.0.0.5/32' : $(grep -c '10\.0\.0\.5/32' <<<"$BODY")"
# The substituted value is the address with the prefix stripped. It must never be quoted.
# Strip every occurrence of the full caller string first, then look for a leftover bare address.
echo "  bare '10.0.0.5' left after removing all '10.0.0.5/32' occurrences (must be 0):"
echo "    $(sed 's|10\.0\.0\.5/32||g' <<<"$BODY" | grep -c '10\.0\.0\.5')"

echo
echo "##### B-2c ACCEPT PATH -- a guard that refuses everything passes every refusal test #####"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.4"},"actions":[{"type":"OUTPUT","port":1}]}'
echo "(must still be 200)"

echo
echo "##### B-2c-b: the REGISTERED NON-FIX -- must STILL be 500 until ruled on #####"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8081/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"nw_dst":"10.0.0.4","tp_dst":"not-a-port"},"actions":[{"type":"OUTPUT","port":1}]}'
echo "(recording only -- not to be fixed in this pass)"
echo "##### DONE #####"
