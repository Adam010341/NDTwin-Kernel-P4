#!/usr/bin/env bash
# repro_404.sh -- P1-3: does get_path_switch_count's OVS 404 ever come back?
#
# [Co-developed with claude code -- Adam]
#
# Status going in: on 2026-08-21 the OVS L2 run reported
#     FAIL [404]  get_path_switch_count   -- HTTP status 404, expected 200
# On 2026-08-22, at the fixed settle default and on a fabric gated healthy before capture, the
# same endpoint passed and so did the whole 39-check contract run. That was recorded as "did not
# reproduce, n=1" rather than "fixed", for a specific reason: two variables changed at once
# (the settle default, and dropping --traffic), and --traffic cannot explain an HTTP 404 from
# the kernel. A 404 here means getSwitchCount returned nullopt -- the (src,dst) pair was absent
# from m_switchCountMap -- which is a property of the path snapshot, not of check strictness.
#
# The suspected cause is the known non-monotonic all_destination_paths fetch: the count has been
# seen dropping from 16256 back to 13184, so a snapshot taken in a trough is missing pairs. That
# is intermittent BY CONSTRUCTION, which makes a single passing run exactly the evidence that
# cannot tell "fixed" from "did not happen to hit it".
#
# So this samples instead of concluding. Per boot: ask the endpoint repeatedly over several
# minutes, and alongside each answer record how many destination paths the control plane is
# reporting right then. If a 404 appears, the path count at that moment is the discriminator --
# a 404 in a trough supports the snapshot theory, a 404 at full count refutes it.
#
# The pair asked about is taken from the kernel's own graph, not from a topology file: the
# contract harness derives it from the declared model, and getting that wrong is how the
# 2026-08-24 five-tuple run aimed a rule at a management address no packet carries.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-24_path-switch-count-404"
OUT="$DIR/repro_404.txt"
RAWDIR="$DIR/raw"
KERNEL=http://localhost:8000
RYU=http://localhost:8080
BOOTS="${BOOTS:-3}"
SAMPLES="${SAMPLES:-12}"
GAP="${GAP:-15}"

mkdir -p "$DIR/raw"
# --- keep the previous run's evidence -------------------------------------------------------
# Re-running a driver used to destroy the round it was re-running: the output table was
# truncated on entry, and same-named per-cell raws were overwritten in place, so a second
# invocation left no trace of the first. That cost real evidence twice -- this study's own first
# round never reached disk, and a correction block in 2026-08-22_loaded-fp-study/REPORT.md ended
# up citing a raw file a later run had replaced with the OPPOSITE result: a successful boot
# standing as the evidence for a failure.
#
# The pattern is the one that worked by hand in the loaded-fp study
# (raw/run1_AB_ok_C_failed.txt): before writing anything, move what is there aside under a
# sequence number. Nothing is overwritten; runs accumulate.
# [Co-developed with claude code -- Adam]
archive_previous() {
    local n=1
    [[ -s "$OUT" ]] || return 0
    while [[ -e "${OUT%.txt}.run${n}.txt" ]]; do n=$(( n + 1 )); done
    mv "$OUT" "${OUT%.txt}.run${n}.txt"
    if [[ -d "$RAWDIR" ]] && [[ -n "$(ls -A "$RAWDIR" 2>/dev/null)" ]]; then
        mkdir -p "$RAWDIR/run${n}"
        find "$RAWDIR" -maxdepth 1 -type f -exec mv -t "$RAWDIR/run${n}" {} +
    fi
    printf 'archived previous run to %s\n' "$(basename "${OUT%.txt}.run${n}.txt")"
}

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
archive_previous
: > "$OUT"
trap 'ndt down >/dev/null 2>&1' EXIT

if [[ -n "${NDTWIN_RYU_SETTLE_S:-}" ]]; then
    say "ABORT: NDTWIN_RYU_SETTLE_S='${NDTWIN_RYU_SETTLE_S}' -- this must run at the default."
    exit 2
fi

say "# P1-3: is the get_path_switch_count 404 reproducible at the fixed default?"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# plan:   $BOOTS boots x $SAMPLES samples every ${GAP}s, path count recorded per sample"
say ""

total404=0; total200=0; totalother=0

for b in $(seq 1 "$BOOTS"); do
    say "## boot $b"
    ndt down > /dev/null 2>&1
    sleep 3
    t0=$(date +%s)
    if ! timeout 900 ndt up ovs > "$DIR/raw/boot${b}_up.out" 2>&1; then
        say "  UP FAILED -- see raw/boot${b}_up.out"
        tail -6 "$DIR/raw/boot${b}_up.out" | sed 's/^/    /' | tee -a "$OUT"
        continue
    fi
    say "  boot: $(( $(date +%s) - t0 ))s"

    # The pair to ask about, read from the kernel's own graph.
    read -r SRC DST <<< "$(curl -sf --max-time 10 "$KERNEL/ndt/get_graph_data" 2>/dev/null | python3 -c "
import json,socket,struct,sys
# dst_ip is a LIST of little-endian uint32, not a string. The first version treated it as a
# string and built a set of lists -- unhashable, TypeError, swallowed by the bare except, and
# printed as 'no host IPs in the kernel graph' against a graph ndt had just called complete
# (128 hosts, 288 edges). A check that degrades to 'found nothing' reads as a fabric state.
# The graph also carries management addresses (192.168.123.x); only 10.0.0.x is the data plane.
# [Co-developed with claude code -- Adam]
try: g=json.load(sys.stdin)
except Exception: print(' '); raise SystemExit
ips=set()
for e in g.get('edges',[]):
    for v in (e.get('dst_ip') or []):
        try: ips.add(socket.inet_ntoa(struct.pack('<I', int(v))))
        except Exception: pass
ips=sorted(i for i in ips if i.startswith('10.'))
print(f'{ips[0]} {ips[-1]}' if len(ips)>1 else ' ')" 2>/dev/null)"
    if [[ -z "${SRC// }" || -z "${DST// }" ]]; then
        say "  no host IPs in the kernel graph -- cannot form a path query; skipping this boot"
        continue
    fi
    say "  asking about $SRC -> $DST"
    say ""
    say "     sample   http   paths_known   note"

    for s in $(seq 1 "$SAMPLES"); do
        code=$(curl -s -o "$DIR/raw/b${b}_s${s}.json" -w '%{http_code}' --max-time 10 \
               "$KERNEL/ndt/get_path_switch_count?src_ip=$SRC&dst_ip=$DST" 2>/dev/null || echo "000")
        paths=$(curl -sf --max-time 10 "$RYU/ryu_server/all_destination_paths" 2>/dev/null \
                | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('?'); raise SystemExit
print(len(d) if isinstance(d,(list,dict)) else '?')" 2>/dev/null || echo "?")
        note=""
        case "$code" in
            200) total200=$((total200+1)) ;;
            404) total404=$((total404+1)); note="<-- THE 404 REPRODUCED" ;;
            *)   totalother=$((totalother+1)); note="<-- unexpected status" ;;
        esac
        printf '     %6s   %4s   %11s   %s\n' "$s" "$code" "$paths" "$note" | tee -a "$OUT"
        sleep "$GAP"
    done
    say ""
done

ndt down > /dev/null 2>&1
say "=================================================================="
say "## tally over $BOOTS boot(s)"
say "  200: $total200    404: $total404    other: $totalother"
say ""
if (( total404 == 0 )); then
    say "  The 404 did not reproduce in $(( total200 + totalother )) samples at the default."
    say "  That is evidence of ABSENCE ONLY to the extent of this sample count -- the suspected"
    say "  cause is an intermittent path-snapshot trough, so a clean run bounds the rate rather"
    say "  than proving the defect gone. Quote the sample count with the verdict."
else
    say "  REPRODUCED. Compare paths_known on the 404 rows against the 200 rows: a 404 in a"
    say "  trough supports the non-monotonic-snapshot theory; a 404 at full count refutes it and"
    say "  the cause is elsewhere."
fi
say ""
say "done -> $OUT"
