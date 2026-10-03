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
if [[ "$s" == ndt && "\${1:-}" == claim && -f "$d/claim_new_expires" ]]; then
    printf 'owner=p4h-test\nexpires=%s\nnote=p4-health run-x A recover\nexclusive_cpu=no\nmeasuring=\n' "\$(cat "$d/claim_new_expires")" > "$d/test_run/lab.claim"
fi
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
    printf '%s\n' "$d/run/pkgA" > "$d/knobs/app_package_override"      # (r6) the package lives in the run dir
    sleep 0 & local dead=$!; wait "$dead"
    local exp=$(( $(date +%s) + 600 ))
    printf 'owner=p4h-test\nexpires=%s\nnote=%s\nexclusive_cpu=no\nmeasuring=\n' "$exp" \
        "$UP_NOTE" > "$d/test_run/lab.claim"
    python3 - "$d" "$dead" "$exp" <<'PY'
import base64, json, sys
d, pid, exp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
st = {"pid": pid, "owner": "p4h-test", "run": "run-x", "bring_up": "A", "package": d + "/run/pkgA",
      "claim_expires": exp,        # (r6) what the probe read from the claim file right after `ndt claim`
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
past() { echo $(( $(date +%s) - 60 )); }
state_set() {  # state_set <dir> <key> <json value> -- one field of LAB_STATE.json
    python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s[sys.argv[2]]=json.loads(sys.argv[3]); json.dump(s,open(p,'w'))" \
        "$1/run/LAB_STATE.json" "$2" "$3"; }
state_del() { python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s.pop(sys.argv[2],None); json.dump(s,open(p,'w'))" "$1/run/LAB_STATE.json" "$2"; }
# expire <dir> -- the probe's own claim ran out: the file AND the state's record of it say the same past time
expire() { local t; t="$(past)"; claim_set "$1" expires "$t"; state_set "$1" claim_expires "$t"; }
to_down_done() {  # to_down_done <dir> [keep] -- what the probe leaves after a successful `ndt down`:
    # phase down-done, the claim's note ndt down wrote, app_package_override REMOVED (ndt:1597-1601).
    # With `keep` the recorded sniffer and controller stay listed (a kill that failed).
    claim_set "$1" note "down at 2026-10-03 18:20:00; verified clean; claim kept"
    rm -f "$1/knobs/app_package_override"
    KEEP="${2:-}" python3 -c "import json,os,sys; p=sys.argv[1]; s=json.load(open(p)); s['phase']='down-done'
if not os.environ['KEEP']: s['sniffers']=[]; s['controllers']=[]; s['netem']=[]
json.dump(s,open(p,'w'))" "$1/run/LAB_STATE.json"
}
set_phase() { python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['phase']=sys.argv[2]; json.dump(s,open(p,'w'))" "$1/run/LAB_STATE.json" "$2"; }
no_line_out() { ! grep -q "$2" "$1/out"; }
rc4_noclaim() { [ "$1" -eq 4 ] && ! grep -q "^ndt claim" "$2/calls"; }
nocalls() { [ ! -s "$1/calls" ]; }
rc3_nocalls() { [ "$1" -eq 3 ] && nocalls "$2"; }                         # rc 3 and no stub called
rc_calls() { [ "$1" -eq "$2" ] && [[ "$(cat "$3/calls")" == "$4" ]]; }    # rc and the exact stub calls
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
d="$(setup expired)"; expire "$d"; rc="$(run "$d")"
check "rc 0" [ "$rc" -eq 0 ]
check "asked ndt whether anything is measuring, then re-claimed as the same owner's run" \
    [ "$(head -2 "$d/calls")" == "ndt status --measuring
ndt claim 30 p4-health run-x A recover state=$d/run/LAB_STATE.json" ]
check "and then the whole recovery" [ "$(tail -1 "$d/calls")" == "ndt status" ]

echo "--- ... but never somebody else's expired claim, and never over a measurement"
d="$(setup expiredforeign)"; expire "$d"; claim_set "$d" owner somebody-else
rc="$(run "$d")"
check "an expired foreign claim: rc 3, no re-claim" [ "$rc" -eq 3 ]
check "  ... nothing run" nocalls "$d"
d="$(setup expireddeclared)"; expire "$d"; claim_set "$d" measuring "nsr reader, do not tear down"
rc="$(run "$d")"
check "an expired claim that declares a measurement: rc 3" [ "$rc" -eq 3 ]
check "  ... no claim, no down" no_line "$d" '^ndt claim\|^ndt down'
d="$(setup expiredstatusfails)"; expire "$d"; echo 2 > "$d/rc.ndt.status"
rc="$(run "$d")"
check "an expired claim and ndt status --measuring not answering: rc 3 (fails closed)" [ "$rc" -eq 3 ]
check "  ... no claim, no down" no_line "$d" '^ndt claim\|^ndt down'
d="$(setup expiredbusy)"; expire "$d"
printf '  measuring      iperf3 -c 10.0.6.6 -t 200\n' > "$d/status_measuring"
rc="$(run "$d")"
check "an expired claim with a measurement in flight: rc 3" [ "$rc" -eq 3 ]
check "  ... no claim, no down" no_line "$d" '^ndt claim\|^ndt down'

echo "--- (r4, Cut 1 follow-ups) down-done: our own claim expired while ndt down ran"
# ndt down removes app_package_override, so "the override names this package" can never hold here;
# the claim is still this owner's, nothing is measuring, and the recovery must finish.
d="$(setup downdoneexpired)"; to_down_done "$d"; expire "$d"; rc="$(run "$d")"
check "down-done, own claim expired, override absent: rc 0" [ "$rc" -eq 0 ]
check "  ... checked no fabric first, asked what measures, re-claimed, restored the knobs, released" \
    [ "$(cat "$d/calls")" == "ndt status
ndt status --measuring
ndt claim 30 p4-health run-x A recover state=$d/run/LAB_STATE.json
ndt release
ndt status" ]
check "  ... the host knob is its snapshot's bytes" [ "$(cat "$d/knobs/host_count_override")" == "4  # kept as bytes" ]
d="$(setup downdoneexpiredforeign)"; to_down_done "$d"; expire "$d"; claim_set "$d" owner somebody-else
rc="$(run "$d")"
check "down-done, an expired claim of somebody else: rc 3, nothing run" [ "$rc" -eq 3 ]
check "  ... and nothing run" nocalls "$d"
d="$(setup downdoneexpireddeclared)"; to_down_done "$d"; expire "$d"; claim_set "$d" measuring "nsr reader, do not tear down"
rc="$(run "$d")"
check "down-done, an expired claim that declares a measurement: rc 3" [ "$rc" -eq 3 ]
check "  ... no claim, no release" no_line "$d" '^ndt claim\|^ndt release'
echo "--- (r4) down-done: stopping a process needs no fabric"
d="$(setup downdonekept)"; to_down_done "$d" keep; rc="$(run "$d")"
check "down-done with a kept sniffer and controller: rc 0" [ "$rc" -eq 0 ]
check "down-done with a kept sniffer and controller: ndt status, both signalled, release -- no qdisc, no netem, no down" \
    [ "$(cat "$d/calls")" == "ndt status
sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666
ndt release
ndt status" ]
d="$(setup downdonekeptfabric)"; to_down_done "$d" keep
printf '  bmv2 switches  4       \n  host/switch    10      \n' > "$d/status_full"
rc="$(run "$d")"
check "down-done with a fabric still up: rc 4, nothing signalled either" [ "$rc" -eq 4 ]
check "  ... no kill, no release" no_line "$d" 'kill\|^ndt release'

echo "--- (r4) an answer that says nothing about measuring is busy, not idle"
d="$(setup expirednorows)"; expire "$d"; : > "$d/status_measuring"
rc="$(run "$d")"
check "an expired claim and an empty ndt status --measuring answer: rc 3 (fails closed)" [ "$rc" -eq 3 ]
check "  ... no claim, no down" no_line "$d" '^ndt claim\|^ndt down'
d="$(setup expiredorphaned)"; expire "$d"
printf '  orphaned       iperf3 -c 10.0.6.6 -t 200\n                 no fabric is running, so these are leftovers, not a measurement\n' > "$d/status_measuring"
rc="$(run "$d")"
check "an expired claim and only an orphaned row (leftovers, no fabric): rc 0, re-claimed" [ "$rc" -eq 0 ]
check "  ... the claim was taken" [ "$(sed -n 2p "$d/calls")" == "ndt claim 30 p4-health run-x A recover state=$d/run/LAB_STATE.json" ]

echo "--- (r5) an absent override is evidence only in down-done: anywhere else it may be somebody else's down"
for ph in teardown claim-lost down-failed; do
    d="$(setup "absent$ph")"; expire "$d"; rm -f "$d/knobs/app_package_override"; set_phase "$d" "$ph"
    rc="$(run "$d")"
    check "$ph, own claim expired, override absent: rc 3, no stub called" rc3_nocalls "$rc" "$d"
done
d="$(setup downdonenoclaim)"; to_down_done "$d"; rm -f "$d/test_run/lab.claim"; rc="$(run "$d")"
check "down-done, no lab.claim: rc 3, nothing written" rc3_nocalls "$rc" "$d"
# the claim file is there, expired and the recorded one (r6: so the identity check passes), but it names no owner
d="$(setup downdonenoowner)"; to_down_done "$d"; expire "$d"; sed -i '/^owner=/d' "$d/test_run/lab.claim"; rc="$(run "$d")"
check "down-done, an expired claim file that is the recorded one but names no owner: rc 3, nothing written" rc3_nocalls "$rc" "$d"
d="$(setup downdonefabricup)"; to_down_done "$d"; expire "$d"
printf '  bmv2 switches  4       \n  host/switch    10      \n' > "$d/status_full"
rc="$(run "$d")"
check "down-done, own claim expired, fabric up: rc 4 and the claim stub never called" \
    rc4_noclaim "$rc" "$d"
check "  ... nothing released, no down" no_line "$d" '^ndt release\|^ndt down'
check "  ... knob untouched" [ "$(cat "$d/knobs/host_count_override")" == "6" ]

echo "--- (r5) phase released: only the identity-checked kills, never a claim, a knob, netem or ndt down"
d="$(setup releasedlive)"; set_phase "$d" released; rm -f "$d/test_run/lab.claim" "$d/knobs/app_package_override"; rc="$(run "$d")"
check "released with recorded live processes: rc 0, only the two kills" \
    rc_calls "$rc" 0 "$d" "sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666"
check "  ... the knob is untouched" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup releasednothing)"; to_down_done "$d"; set_phase "$d" released; rm -f "$d/test_run/lab.claim"; rc="$(run "$d")"
check "released with nothing recorded: rc 0 and no stub called" rc_calls "$rc" 0 "$d" ""
d="$(setup releasedlater)"; set_phase "$d" released      # the same owner holds a LIVE claim on a later round's fabric
rc="$(run "$d")"
check "released while the same owner holds a later round's live claim: rc 0, only the kills" \
    rc_calls "$rc" 0 "$d" "sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666"
check "  ... no ndt down, no claim, no release, no qdisc, no netem" no_line "$d" '^ndt\|^qdisc\|tc qdisc'
d="$(setup releasedkillfails)"; set_phase "$d" released; rm -f "$d/test_run/lab.claim"; echo 1 > "$d/rc.sudo.-n"; rc="$(run "$d")"
check "released with a kill that fails: rc 7, only the kills" \
    rc_calls "$rc" 7 "$d" "sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666"

echo "--- (r5) a kill that failed is never a quiet \"done\""
d="$(setup killfails)"; echo 1 > "$d/rc.kill.-TERM"; rc="$(run "$d")"
check "a controller kill fails in a live recovery: the recovery finishes, then rc 7" [ "$rc" -eq 7 ] 
check "  ... it did finish: down, release, status" [ "$(tail -3 "$d/calls")" == "ndt down
ndt release
ndt status" ]
check "  ... and it did not say done" no_line_out "$d" 'recover: done'

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

echo "--- (r6) the package is this run's own: a package outside the run dir is not evidence"
# A later round of the same owner may hold a live claim on a package at the same path. Nothing in the
# state of an older run can tell them apart -- unless the package must live INSIDE the run's own dir.
d="$(setup pkgoutside)"; mkdir -p "$d/shared"; printf '%s\n' "$d/shared/pkg" > "$d/knobs/app_package_override"
state_set "$d" package "\"$d/shared/pkg\""; rc="$(run "$d")"
check "a package outside the run dir, every other thing matching (owner, live claim, override, expires): rc 3, no stub called" \
    rc3_nocalls "$rc" "$d"
check "  ... the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup olderrunsamepath)"; mkdir -p "$d/shared"; printf '%s\n' "$d/shared/pkg" > "$d/knobs/app_package_override"
state_set "$d" package "\"$d/shared/pkg\""; state_set "$d" claim_expires "$(( $(date +%s) + 100 ))"
claim_set "$d" expires "$(( $(date +%s) + 900 ))"        # a LATER round's claim, same owner, same package path
rc="$(run "$d")"
check "an older run dir, the same owner and package path as a later round holding a live claim: rc 3, no tc, no ndt down" \
    rc3_nocalls "$rc" "$d"
check "  ... the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup pkgdotdot)"; printf '%s\n' "$d/run/../pkgB" > "$d/knobs/app_package_override"
state_set "$d" package "\"$d/run/../pkgB\""; rc="$(run "$d")"
check "a package that climbs out of the run dir with ..: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup pkgsibling)"; printf '%s\n' "$d/run2/pkg" > "$d/knobs/app_package_override"
state_set "$d" package "\"$d/run2/pkg\""; rc="$(run "$d")"
check "a package in a sibling dir whose name starts with the run dir's: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup pkgsymlink)"; mkdir -p "$d/shared/pkg"; ln -s "$d/shared/pkg" "$d/run/pkgA"; rc="$(run "$d")"
check "a package that is a link out of the run dir: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup pkgisrun)"; printf '%s\n' "$d/run" > "$d/knobs/app_package_override"
state_set "$d" package "\"$d/run\""; rc="$(run "$d")"
check "the package is the run dir itself: rc 3, no stub called" rc3_nocalls "$rc" "$d"

echo "--- (r6) the claim is the one the probe made: its expires, recorded right after \`ndt claim\`"
d="$(setup livemismatch)"; claim_set "$d" expires "$(( $(date +%s) + 900 ))"; rc="$(run "$d")"
check "a live claim of our owner with another expires than the probe recorded: rc 3, no stub called" rc3_nocalls "$rc" "$d"
check "  ... the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup downdonelater)"; to_down_done "$d"; claim_set "$d" expires "$(( $(date +%s) + 900 ))"; rc="$(run "$d")"
check "an older down-done run dir under a later same-owner round's live claim: rc 3, no stub called" rc3_nocalls "$rc" "$d"
check "  ... that round's claim was not released, the knob not written" \
    bash -c '! grep -q "^ndt release" "$1/calls" && [ "$(cat "$1/knobs/host_count_override")" == "6" ]' _ "$d"
d="$(setup expiredothers)"; claim_set "$d" expires "$(past)"; rc="$(run "$d")"
check "an expired claim of our owner that is not the one the probe recorded: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup downdoneexpiredothers)"; to_down_done "$d"; claim_set "$d" expires "$(past)"; rc="$(run "$d")"
check "down-done, an expired claim of our owner that is not the recorded one: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup claimgone)"; rm -f "$d/test_run/lab.claim"; rc="$(run "$d")"
check "no claim file at all, override still ours, phase cells: rc 3 (nothing to identify), no stub called" rc3_nocalls "$rc" "$d"
d="$(setup reclaimretry)"; expire "$d"; echo "$(( $(date +%s) + 1800 ))" > "$d/claim_new_expires"; echo 1 > "$d/rc.ndt.down"
rc="$(run "$d")"
check "an expired claim of ours is re-taken, then ndt down fails: rc 5" [ "$rc" -eq 5 ]
check "after the re-claim the state records the new claim's expires" \
    [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['claim_expires'])" "$d/run/LAB_STATE.json")" == "$(cat "$d/claim_new_expires")" ]
rm -f "$d/rc.ndt.down" "$d/claim_new_expires"; : > "$d/calls"; rc="$(run "$d")"
check "  ... and the retry under that live claim finishes: rc 0" [ "$rc" -eq 0 ]
check "  ... it went on to ndt down and the release" bash -c 'grep -q "^ndt down" "$1/calls" && grep -q "^ndt release" "$1/calls"' _ "$d"

echo "--- (r6) a state file that leaves out what the recovery trusts stops at rc 2"
for f in owner run package claim_file app_package_override claim_expires; do
    d="$(setup "miss$f")"; state_del "$d" "$f"; rc="$(run "$d")"
    check "LAB_STATE.json without $f: rc 2, no stub called" rc_calls "$rc" 2 "$d" ""
    d="$(setup "empty$f")"; state_set "$d" "$f" '""'; rc="$(run "$d")"
    check "LAB_STATE.json with an empty $f: rc 2, no stub called" rc_calls "$rc" 2 "$d" ""
done
d="$(setup expirestext)"; state_set "$d" claim_expires '"soon"'; rc="$(run "$d")"
check "LAB_STATE.json with a claim_expires that is not a number: rc 2, no stub called" rc_calls "$rc" 2 "$d" ""
d="$(setup expireszero)"; state_set "$d" claim_expires 0; rc="$(run "$d")"
check "LAB_STATE.json with a claim_expires of 0: rc 2, no stub called" rc_calls "$rc" 2 "$d" ""
d="$(setup releasednoowner)"; set_phase "$d" released; state_del "$d" owner; rc="$(run "$d")"
check "a released run whose owner is missing: rc 2 and not even the kills" rc_calls "$rc" 2 "$d" ""
d="$(setup nullexpires)"; state_set "$d" claim_expires null; rc="$(run "$d")"
check "LAB_STATE.json whose claim_expires is null (the probe died between ndt claim and writing it): rc 2" rc_calls "$rc" 2 "$d" ""

echo
echo "Ran $CHECKS checks, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
