#!/usr/bin/env bash
# (c) the probe's kernel request, as ndt's http_get_graph makes it: N timed GETs alone, then N pairs
# fired together (does one slow the other?). [Co-developed with claude code -- Adam]
N="${1:-7}"; U=http://localhost:8000/ndt/get_graph_data
echo "# $(date -Is) alone: http_code bytes time_total rc"
for i in $(seq "$N"); do
    curl -sf --max-time 5 -o /dev/null -w '%{http_code} %{size_download}B %{time_total}s' "$U"; echo " rc=$?"
    sleep 1
done
echo "# $(date -Is) pairs: two GETs started together, each one's time_total"
for i in $(seq "$N"); do
    t=$( { curl -sf --max-time 5 -o /dev/null -w '%{time_total}\n' "$U" & curl -sf --max-time 5 -o /dev/null -w '%{time_total}\n' "$U"; wait; } | tr '\n' ' ')
    echo "pair $i: $t"
    sleep 1
done
