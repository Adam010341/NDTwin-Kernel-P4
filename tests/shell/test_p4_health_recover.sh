#!/usr/bin/env bash
#
# tools/p4_health/recover.sh, offline: every command it would run is a stub that logs its argv.
#
# [Co-developed with claude code -- Adam]
#
# Checks the order of the recovery (design 4.5), the refusals (probe alive, not our lab, qdisc
# drift, a failed down), section 12 item 11's re-claim and its limits (somebody else's expired
# claim, a declared or running measurement), the pid identity rule (a recycled pid is left
# alone), and that the knobs come back as bytes. The claim notes are the ones ndt itself writes
# once `ndt up` has started (ndt:1207-1215) or `ndt down` has run (ndt:1245-1277).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SUBJECT="${P4_HEALTH_RECOVER_UNDER_TEST:-$REPO/tools/p4_health/recover.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4h-recover-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CHECKS=0; FAILED=0
check() {  # check <name> <condition...>
    local name="$1"; shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then echo "  ok    $name"; else echo "  FAIL  $name"; FAILED=$((FAILED + 1)); fi
}

UP_NOTE="in use: ndt up p4 6 at 2026-10-03 18:00:00 by p4h-test"

setup() {  # setup <case> -- a fresh run dir, knobs, claim, override, fake /proc and stubs
    local d="$WORK/$1"; mkdir -p "$d/run" "$d/knobs" "$d/test_run" "$d/bin" "$d/proc/555" "$d/proc/666"
    : > "$d/calls"
    printf '  measuring      nothing\n' > "$d/status_measuring"
    printf '  bmv2 switches  0       \n  host/switch    0       \n' > "$d/status_full"
    for s in ndt qdisc sudo kill; do
        cat > "$d/bin/$s" <<STUB
#!/usr/bin/env bash
echo "$s \$*" >> "$d/calls"
if [[ "$s" == ndt && "\${1:-}" == status && "\${2:-}" == --measuring ]]; then cat "$d/status_measuring"
elif [[ "$s" == ndt && "\${1:-}" == status ]]; then cat "$d/status_full"; fi
rc_file="$d/rc.$s.\${1:-}"
[[ -f "\$rc_file" ]] && exit "\$(cat "\$rc_file")"
exit 0
STUB
        chmod +x "$d/bin/$s"
    done
    # the two recorded processes, alive, with the start times and markers the probe recorded
    printf '555 (python3) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777001 0 0\n' > "$d/proc/555/stat"
    printf 'python3\0sniff.py\0--run-id\0run-x\0' > "$d/proc/555/cmdline"
    printf '666 (python3) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777002 0 0\n' > "$d/proc/666/stat"
    printf 'python3\0controller_ext.py\0run-x\0' > "$d/proc/666/cmdline"
    printf '6\n' > "$d/knobs/host_count_override"
    printf '%s\n' "$d/pkgA" > "$d/knobs/app_package_override"
    sleep 0 & local dead=$!; wait "$dead"
    printf 'owner=p4h-test\nexpires=%s\nnote=%s\nexclusive_cpu=no\nmeasuring=\n' "$(( $(date +%s) + 600 ))" \
        "$UP_NOTE" > "$d/test_run/lab.claim"
    python3 - "$d" "$dead" <<'PY'
import base64, json, sys
d, pid = sys.argv[1], int(sys.argv[2])
st = {"pid": pid, "owner": "p4h-test", "run": "run-x", "bring_up": "A", "package": d + "/pkgA",
      "phase": "cells", "netem": ["s2-eth3"],
      "sniffers": [{"pid": 555, "start": 777001, "marker": "run-x"}],
      "controllers": [{"pid": 666, "start": 777002, "marker": "run-x"}],
      "qdisc_before": d + "/run/qdisc.A.before",
      "knob_snapshot": {"host_count_override": base64.b64encode(b"4  # kept as bytes\n").decode(),
                        "telemetry_override": None},
      "knob_paths": {"host_count_override": d + "/knobs/host_count_override",
                     "telemetry_override": d + "/knobs/telemetry_override"},
      "app_package_override": d + "/knobs/app_package_override",
      "claim_file": d + "/test_run/lab.claim", "ndt": d + "/bin/ndt"}
json.dump(st, open(d + "/run/LAB_STATE.json", "w"))
PY
    printf 'x\n' > "$d/knobs/telemetry_override"
    echo "$d"
}

run() {  # run <dir> -- recover.sh with every seam pointed at the stubs; echoes rc
    local d="$1"
    P4H_NDT="$d/bin/ndt" P4H_QDISC_SNAPSHOT="$d/bin/qdisc" P4H_SUDO="$d/bin/sudo" P4H_KILL="$d/bin/kill" \
        P4H_PROC="$d/proc" bash "$SUBJECT" "$d/run" > "$d/out" 2>&1
    echo $?
}
claim_set() { sed -i "s|^$2=.*|$2=$3|" "$1/test_run/lab.claim"; }
nocalls() { [ ! -s "$1/calls" ]; }
no_line() { ! grep -q "$2" "$1/calls"; }

echo "subject: $SUBJECT"
echo "--- the whole recovery, in order, under the note ndt up wrote"
d="$(setup happy)"; rc="$(run "$d")"
want="sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666
sudo -n tc qdisc del dev s2-eth3 root
qdisc diff $d/run/qdisc.A.before
ndt down
ndt release
ndt status"
check "rc 0" [ "$rc" -eq 0 ]
check "stop sniffer, stop controller, netem off, qdisc diff, down, release, status" [ "$(cat "$d/calls")" == "$want" ]
check "the host knob is its snapshot's bytes" [ "$(cat "$d/knobs/host_count_override")" == "4  # kept as bytes" ]
check "the telemetry knob that was absent is absent again" [ ! -e "$d/knobs/telemetry_override" ]

echo "--- a crash after the probe's own ndt down (phase down-done; review NEW-C)"
# The qdisc stub reports DRIFT here, as the real snapshot would once the fabric's interfaces are
# gone: a recovery that still compared qdiscs would stop at rc 4 and never release.
d="$(setup afterdown)"; claim_set "$d" note "down at 2026-10-03 18:20:00; verified clean; claim kept"
: > "$d/knobs/app_package_override"; echo 1 > "$d/rc.qdisc.diff"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['phase']='down-done'; s['sniffers']=[]; s['controllers']=[]; s['netem']=[]; json.dump(s,open(p,'w'))" "$d/run/LAB_STATE.json"
rc="$(run "$d")"
check "down-done: rc 0" [ "$rc" -eq 0 ]
check "down-done: asked ndt status, then released -- no qdisc, no netem, no second down" \
    [ "$(cat "$d/calls")" == "ndt status
ndt release
ndt status" ]
check "down-done: the host knob is its snapshot's bytes" [ "$(cat "$d/knobs/host_count_override")" == "4  # kept as bytes" ]
d="$(setup afterdownup)"; claim_set "$d" note "down at 2026-10-03 18:20:00; verified clean; claim kept"
: > "$d/knobs/app_package_override"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['phase']='down-done'; json.dump(s,open(p,'w'))" "$d/run/LAB_STATE.json"
printf '  bmv2 switches  4       \n  host/switch    10      \n' > "$d/status_full"
rc="$(run "$d")"
check "down-done but ndt status shows a fabric: rc 4" [ "$rc" -eq 4 ]
check "  ... no release, no knob write" no_line "$d" '^ndt release'
check "  ... knob untouched" [ "$(cat "$d/knobs/host_count_override")" == "6" ]

echo "--- not our lab"
d="$(setup foreign)"; claim_set "$d" owner somebody-else; rc="$(run "$d")"
check "a live foreign claim: rc 3" [ "$rc" -eq 3 ]
check "nothing was run" nocalls "$d"
check "the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup otherpkg)"; printf '/elsewhere\n' > "$d/knobs/app_package_override"; rc="$(run "$d")"
check "another package in the override: rc 3, nothing run" [ "$rc" -eq 3 ]
check "  ... and nothing run" nocalls "$d"
d="$(setup othernote)"; claim_set "$d" note "in use: ndt up p4 6 at 2026-10-03 18:00:00 by somebody-else"; rc="$(run "$d")"
check "an up note written for another owner: rc 3, nothing run" [ "$rc" -eq 3 ]
check "  ... and nothing run" nocalls "$d"

echo "--- the probe is still alive"
d="$(setup alive)"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['pid']=int(sys.argv[2]); json.dump(s,open(p,'w'))" \
    "$d/run/LAB_STATE.json" "$$"
rc="$(run "$d")"
check "rc 3 and nothing run" [ "$rc" -eq 3 ]
check "  ... and nothing run" nocalls "$d"

d="$(setup alivesame)"
mkdir -p "$d/proc/$$"; printf '%s (bash) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242 0 0\n' "$$" > "$d/proc/$$/stat"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['pid']=int(sys.argv[2]); s['pid_start']=4242; json.dump(s,open(p,'w'))" \
    "$d/run/LAB_STATE.json" "$$"
rc="$(run "$d")"
check "the probe's pid alive with its own start time: rc 3" [ "$rc" -eq 3 ]
check "  ... and nothing run" nocalls "$d"

echo "--- the probe's pid alive but recycled (another start time) is not the probe"
d="$(setup recycledprobe)"
mkdir -p "$d/proc/$$"; printf '%s (bash) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 5 0 0\n' "$$" > "$d/proc/$$/stat"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['pid']=int(sys.argv[2]); s['pid_start']=999; json.dump(s,open(p,'w'))" \
    "$d/run/LAB_STATE.json" "$$"
rc="$(run "$d")"
check "rc 0: a live pid with another start time is a recycled pid" [ "$rc" -eq 0 ]

echo "--- section 12 item 11: an expired claim of ours, the override still ours"
d="$(setup expired)"; claim_set "$d" expires "$(( $(date +%s) - 60 ))"; rc="$(run "$d")"
check "rc 0" [ "$rc" -eq 0 ]
check "asked ndt whether anything is measuring, then re-claimed as the same owner's run" \
    [ "$(head -2 "$d/calls")" == "ndt status --measuring
ndt claim 30 p4-health run-x A recover state=$d/run/LAB_STATE.json" ]
check "and then the whole recovery" [ "$(tail -1 "$d/calls")" == "ndt status" ]

echo "--- ... but never somebody else's expired claim, and never over a measurement"
d="$(setup expiredforeign)"; claim_set "$d" expires "$(( $(date +%s) - 60 ))"; claim_set "$d" owner somebody-else
rc="$(run "$d")"
check "an expired foreign claim: rc 3, no re-claim" [ "$rc" -eq 3 ]
check "  ... nothing run" nocalls "$d"
d="$(setup expireddeclared)"; claim_set "$d" expires "$(( $(date +%s) - 60 ))"; claim_set "$d" measuring "nsr reader, do not tear down"
rc="$(run "$d")"
check "an expired claim that declares a measurement: rc 3" [ "$rc" -eq 3 ]
check "  ... no claim, no down" no_line "$d" '^ndt claim\|^ndt down'
d="$(setup expiredstatusfails)"; claim_set "$d" expires "$(( $(date +%s) - 60 ))"; echo 2 > "$d/rc.ndt.status"
rc="$(run "$d")"
check "an expired claim and ndt status --measuring not answering: rc 3 (fails closed)" [ "$rc" -eq 3 ]
check "  ... no claim, no down" no_line "$d" '^ndt claim\|^ndt down'
d="$(setup expiredbusy)"; claim_set "$d" expires "$(( $(date +%s) - 60 ))"
printf '  measuring      iperf3 -c 10.0.6.6 -t 200\n' > "$d/status_measuring"
rc="$(run "$d")"
check "an expired claim with a measurement in flight: rc 3" [ "$rc" -eq 3 ]
check "  ... no claim, no down" no_line "$d" '^ndt claim\|^ndt down'

echo "--- a recycled pid is left alone"
d="$(setup recycled)"
printf '555 (bash) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 999999 0 0\n' > "$d/proc/555/stat"
rm -rf "$d/proc/666"
rc="$(run "$d")"
check "rc 0" [ "$rc" -eq 0 ]
check "no signal to the recycled sniffer pid or the vanished controller" no_line "$d" 'kill'
check "  ... and the rest of the recovery ran" [ "$(tail -1 "$d/calls")" == "ndt status" ]

echo "--- the qdisc tree drifted"
d="$(setup drift)"; echo 1 > "$d/rc.qdisc.diff"; rc="$(run "$d")"
check "rc 4" [ "$rc" -eq 4 ]
check "no ndt down after the drift" no_line "$d" '^ndt down'

echo "--- ndt down failed"
d="$(setup downfail)"; echo 1 > "$d/rc.ndt.down"; rc="$(run "$d")"
check "rc 5" [ "$rc" -eq 5 ]
check "no release" no_line "$d" '^ndt release'
check "knob untouched" [ "$(cat "$d/knobs/host_count_override")" == "6" ]

echo
echo "Ran $CHECKS checks, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
