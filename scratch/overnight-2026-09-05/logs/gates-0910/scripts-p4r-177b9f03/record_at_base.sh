#!/usr/bin/env bash
# The recording wrapper (TICKET-P4-roles section 7 ruling 6, F4). [Co-developed with claude code -- Adam]
#
# What produced BASELINE_NDTWIN_HTTP_BODY, made repeatable: take a `git archive d492a346` tree
# (its p4_proxy/proxy_agent is trunk 6291db35's -- checked below, not asserted), copy the
# recorder from HEAD into it verbatim, run it there, and compare what it prints with the
# constant HEAD pins. Also prints the recorder's sha256 AT HEAD next to the one the original
# recording logged (89e35766...), so the chain recorder -> bytes -> constant is recomputed at
# the head this runs on. Exit 0 only when every link holds.
#
# Round 2 recorded with the same steps typed inline (log
# record_stats_flow_http_body_at_base.p4r-57aae1bf.log); this file is those steps.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
BASE_CAPTURE=d492a346
RECORDED_RECORDER_SHA=89e3576613bedf4920158e68ad019feabf3c317896fc602c4dacf76f96c7a540
bad=0
head_rec=$(git -C "$WT" show HEAD:p4_proxy/tests/record_stats_flow_http_body.py | sha256sum | cut -d' ' -f1)
echo "HEAD                 $(git -C "$WT" rev-parse HEAD)"
echo "recorder at HEAD     $head_rec"
echo "recorder as recorded $RECORDED_RECORDER_SHA"
[[ "$head_rec" == "$RECORDED_RECORDER_SHA" ]] || { echo "  🔴 the recorder changed after the recording"; bad=1; }
d=$(git -C "$WT" diff --stat 6291db35 "$BASE_CAPTURE" -- p4_proxy/proxy_agent p4_proxy/mininet)
echo "production diff 6291db35..$BASE_CAPTURE: [$d] (empty = identical)"
[[ -z "$d" ]] || bad=1
B="$SP/rec-base"; rm -rf "$B"; mkdir -p "$B"
git -C "$WT" archive "$BASE_CAPTURE" p4_proxy setting | tar -x -C "$B"
rm -rf "$B/p4_proxy/p4_src/build" "$B/p4_proxy/venv"
ln -s "$WT/p4_proxy/venv" "$B/p4_proxy/venv"
git -C "$WT" show HEAD:p4_proxy/tests/record_stats_flow_http_body.py \
    > "$B/p4_proxy/tests/record_stats_flow_http_body.py"
out=$(env -C "$B/p4_proxy" PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 TMPDIR="$SP/tmp" \
      venv/bin/python tests/record_stats_flow_http_body.py 2>&1); rc=$?
rm -rf "$B"
printf '%s\n' "$out" | head -4
recorded=$(sed -n 's/^sha256 *//p' <<<"$out")
pinned=$(git -C "$WT" show HEAD:p4_proxy/tests/test_flow_stats_route.py \
         | sed -n 's/^BASELINE_NDTWIN_HTTP_BODY_SHA256 = "\(.*\)"$/\1/p')
echo "recorded now at $BASE_CAPTURE  $recorded"
echo "pinned at HEAD             $pinned"
(( rc == 0 )) && [[ -n "$recorded" && "$recorded" == "$pinned" ]] || { echo "  🔴 recording != pin"; bad=1; }
echo "RECORD-AT-BASE: $([[ $bad == 0 ]] && echo 'recorder unchanged, re-recorded bytes equal the pin' || echo BROKEN)"
exit $bad
