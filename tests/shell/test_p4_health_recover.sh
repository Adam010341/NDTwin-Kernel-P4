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
# once `ndt up` has started (ndt:1211-1219) or `ndt down` has run (ndt:1249-1281).
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

# (r7) The knob exactly as ndt writes it -- a copy of the two printf lines of app_knob_write
# (tools/test_workflow/ndt:1646-1647; the two-line shape is pinned by tests/shell/test_ndt_app_package.sh:334-335):
# a "# written by ..." comment line, THEN the directory. The fixture used to write the directory alone,
# which ndt never does, and recover.sh read the first line of the file.
write_knob() {  # write_knob <file> <package dir>
    { printf '# written by ndt up p4 --app at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf '%s\n' "$2"; } > "$1"
}

setup() {  # setup <case> -- a fresh run dir, knobs, claim, override, fake /proc and stubs
    local d="$WORK/$1"; mkdir -p "$d/run" "$d/bin" "$d/proc/555" "$d/proc/666"
    : > "$d/calls"
    printf '  measuring      nothing\n' > "$d/status_measuring"
    printf '  bmv2 switches  4       \n  host/switch    10      \n' > "$d/status_full"      # a fabric is up (ndt status, cmd_status)
    # (r9) `ndt claim` and `ndt release` are file operations (claim_take, record_round_baseline, release's baseline and
    # foreign-claim checks, .prev), so they run the REAL tools/test_workflow/ndt, from a scratch copy: ndt finds its
    # repo from its own location, so its .test_run and p4_proxy/mininet are the scratch ones ($d/test_run and
    # $d/knobs are links to them). Only what touches processes or interfaces is a stub: ndt down's teardown, ndt
    # status's process rows, qdisc_snapshot.sh, sudo, kill.
    mkdir -p "$d/repo/tools" "$d/repo/p4_proxy/mininet" "$d/repo/.test_run"
    cp -r "$REPO/tools/test_workflow" "$d/repo/tools/"
    git init -q "$d/repo"                    # record_round_baseline reads `git status`; a repo with no commits is enough
    ln -s "$d/repo/p4_proxy/mininet" "$d/knobs"; ln -s "$d/repo/.test_run" "$d/test_run"
    for s in ndt qdisc sudo kill; do
        { printf 'd=%q; s=%s\n' "$d" "$s"; cat <<'STUB'
#!/usr/bin/env bash
# Every behaviour a recovery's outcome depends on follows the real tool; the lines are cited next to it.
echo "$s $*" >> "$d/calls"
host_count() {  # a copy of host_count_in, tools/test_workflow/ndt:1573-1582: the first line that is not blank, not a comment; 4 if none
    local f="$d/knobs/host_count_override" line
    [[ -f "$f" ]] || { echo 4; return; }
    while read -r line; do
        line="${line%%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        echo "$line"; return
    done < "$f"
    echo 4
}
rc_file="$d/rc.$s.${1:-}"
if [[ "$s" == ndt ]]; then
    case "${1:-}" in
    status)
        if [[ "${2:-}" == --measuring ]]; then cat "$d/status_measuring"
        elif [[ -f "$d/down_ran" ]]; then printf '  bmv2 switches  0       \n  host/switch    0       \n'   # nothing left once a down has run
        else cat "$d/status_full"; fi ;;
    claim)
        # injected: a claim that is refused, or one that exits 0 and writes nothing (to see how recover treats it)
        [[ -f "$rc_file" && "$(cat "$rc_file")" != 0 ]] && exit "$(cat "$rc_file")"
        [[ -f "$d/claim_noop" ]] && exit 0
        exec "$d/repo/tools/test_workflow/ndt" "$@" ;;       # the REAL claim_take, record_round_baseline, .prev
    down)
        rm -f "$d/knobs/app_package_override"   # ndt clears the knob as down's last step, even when it exits non-zero (ndt:5251-5264, 5640)
        # claim_note_down (ndt:1249-1281) rewrites the claim's note whatever the exit status: "verified clean" when the
        # teardown had something to tear down, "nothing was up to tear down" when it did not; the claim's owner and
        # expires stay (set_claim_note, ndt:1123-1135), and a note is written only into a live claim of the caller
        drc=0; [[ -f "$rc_file" ]] && drc="$(cat "$rc_file")"
        also=""; [[ "$drc" != 0 && "$drc" != 3 ]] && also="; this teardown still exits $drc, for something other than residue"
        empty=0; grep -q 'bmv2 switches  0 ' "$d/status_full" && grep -q 'host/switch    0 ' "$d/status_full" && empty=1
        [[ -f "$d/down_ran" ]] && empty=1       # a second down finds the lab already down
        if [[ -f "$d/down_unclean" ]]; then     # ndt:1280: what the teardown could not verify is in the note (the file holds the reason)
            sentence="down at 2026-10-03 18:20:00 did NOT verify clean -- $(cat "$d/down_unclean"); claim kept -- read 'running' below, not this note"
        elif [[ "$empty" -eq 1 ]]; then
            sentence="down at 2026-10-03 18:20:00; nothing was up to tear down${also}; claim kept"
        else sentence="down at 2026-10-03 18:20:00; verified clean${also}; claim kept"; fi
        exp_now="$(sed -n 's/^expires=//p' "$d/test_run/lab.claim" 2>/dev/null | head -1)"
        if [[ "$exp_now" -gt "$(date +%s)" ]] 2>/dev/null; then sed -i "s|^note=.*|note=$sentence|" "$d/test_run/lab.claim"; fi
        : > "$d/down_ran"                       # the fabric is gone from here on, whatever the exit status
        # injected: a claim taken by somebody else during the down (the expires may stay the same, the owner changes)
        [[ -f "$d/down_claim_expires" ]] && sed -i "s|^expires=.*|expires=$(cat "$d/down_claim_expires")|" "$d/test_run/lab.claim"
        [[ -f "$d/down_claim_owner" ]] && sed -i "s|^owner=.*|owner=$(cat "$d/down_claim_owner")|" "$d/test_run/lab.claim" ;;
    release)
        # injected: a refusal for a reason this scratch setup cannot produce by itself
        if [[ -f "$rc_file" && "$(cat "$rc_file")" != 0 ]]; then echo "refusing: (a refusal injected for another reason)"; exit "$(cat "$rc_file")"; fi
        exec "$d/repo/tools/test_workflow/ndt" "$@" ;;       # the REAL cmd_release: baseline check, --force, foreign claim, .prev (ndt:866-954)
    esac
fi
# qdisc_snapshot.sh diff compares `tc qdisc show` of every interface (qdisc_snapshot.sh:24, 37-44): once a down has
# run, the fabric's interfaces are gone and it differs, exit 1
if [[ "$s" == qdisc && "${1:-}" == diff && -f "$d/down_ran" ]]; then echo "QDISC STATE CHANGED since the snapshot" >&2; exit 1; fi
if [[ "$s" == ndt && "${1:-}" == down && -f "$rc_file" && "$(cat "$rc_file")" == 3 && "$empty" != 1 ]]; then exit 0; fi   # ndt:5559-5572: rc 3 only when nothing was up when the down started
[[ -f "$rc_file" ]] && exit "$(cat "$rc_file")"
exit 0
STUB
        } > "$d/bin/$s"
        chmod +x "$d/bin/$s"
    done
    # the two recorded processes, alive, with the start times and markers the probe recorded
    printf '555 (python3) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777001 0 0\n' > "$d/proc/555/stat"
    printf 'python3\0sniff.py\0--run-id\0run-x\0' > "$d/proc/555/cmdline"
    printf '666 (python3) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777002 0 0\n' > "$d/proc/666/stat"
    printf 'python3\0controller_ext.py\0run-x\0' > "$d/proc/666/cmdline"
    sleep 0 & local dead=$!; wait "$dead"
    # The probe's own claim: the REAL `ndt claim`, taken while the knob still has its pre-round value (that is what the
    # round baseline records, ndt:451-464, 853); then `ndt up` moves the knob (the package changed the host count) and
    # rewrites the claim's note (ndt:3504) -- up is process-bound, so those two are written here.
    printf '4  # kept as bytes\n' > "$d/knobs/host_count_override"
    NDT_OWNER=p4h-test "$d/repo/tools/test_workflow/ndt" claim 10 "p4-health run-x A state=$d/run/LAB_STATE.json" > /dev/null 2>&1
    printf '6\n' > "$d/knobs/host_count_override"
    write_knob "$d/knobs/app_package_override" "$d/run/pkgA"      # (r6) the package lives in the run dir
    sed -i "s|^note=.*|note=$UP_NOTE|" "$d/test_run/lab.claim"
    local exp; exp="$(sed -n 's/^expires=//p' "$d/test_run/lab.claim")"
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
fabric_gone() { printf '  bmv2 switches  0       \n  host/switch    0       \n' > "$1/status_full"; }
fabric_up() { printf '  bmv2 switches  4       \n  host/switch    10      \n' > "$1/status_full"; }
to_down_done() {  # to_down_done <dir> [keep] -- what the probe leaves after a successful `ndt down`:
    # phase down-done, the claim's note ndt down wrote, app_package_override REMOVED (ndt:1601-1605).
    # With `keep` the recorded sniffer and controller stay listed (a kill that failed).
    claim_set "$1" note "down at 2026-10-03 18:20:00; verified clean; claim kept"
    rm -f "$1/knobs/app_package_override"; fabric_gone "$1"
    KEEP="${2:-}" python3 -c "import json,os,sys; p=sys.argv[1]; s=json.load(open(p)); s['phase']='down-done'
if not os.environ['KEEP']: s['sniffers']=[]; s['controllers']=[]; s['netem']=[]
json.dump(s,open(p,'w'))" "$1/run/LAB_STATE.json"
}
set_phase() { python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['phase']=sys.argv[2]; json.dump(s,open(p,'w'))" "$1/run/LAB_STATE.json" "$2"; }
claim_get_exp() { sed -n 's/^expires=//p' "$1/test_run/lab.claim" | head -1; }
state_get() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1/run/LAB_STATE.json" "$2"; }
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
check "after its own ndt down the state says down-done" [ "$(state_get "$d" phase)" == "down-done" ]

echo "--- a crash after the probe's own ndt down (phase down-done; review NEW-C)"
# The qdisc stub reports DRIFT here, as the real snapshot would once the fabric's interfaces are
# gone: a recovery that still compared qdiscs would stop at rc 4 and never release.
d="$(setup afterdown)"; claim_set "$d" note "down at 2026-10-03 18:20:00; verified clean; claim kept"; fabric_gone "$d"
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
d="$(setup otherpkg)"; write_knob "$d/knobs/app_package_override" /elsewhere; rc="$(run "$d")"
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
check "an expired foreign claim: the claim stub was never called" no_line "$d" '^ndt claim'
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
ndt release --force
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
check "after its own failed ndt down the state says down-failed" [ "$(state_get "$d" phase)" == "down-failed" ]
check "no release" no_line "$d" '^ndt release'
check "knob untouched" [ "$(cat "$d/knobs/host_count_override")" == "6" ]

echo "--- (r6) the package is this run's own: a package outside the run dir is not evidence"
# A later round of the same owner may hold a live claim on a package at the same path. Nothing in the
# state of an older run can tell them apart -- unless the package must live INSIDE the run's own dir.
d="$(setup pkgoutside)"; mkdir -p "$d/shared"; write_knob "$d/knobs/app_package_override" "$d/shared/pkg"
state_set "$d" package "\"$d/shared/pkg\""; rc="$(run "$d")"
check "a package outside the run dir, every other thing matching (owner, live claim, override, expires): rc 3, no stub called" \
    rc3_nocalls "$rc" "$d"
check "  ... the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup olderrunsamepath)"; mkdir -p "$d/shared"; write_knob "$d/knobs/app_package_override" "$d/shared/pkg"
state_set "$d" package "\"$d/shared/pkg\""; state_set "$d" claim_expires "$(( $(date +%s) + 100 ))"
claim_set "$d" expires "$(( $(date +%s) + 900 ))"        # a LATER round's claim, same owner, same package path
rc="$(run "$d")"
check "an older run dir, the same owner and package path as a later round holding a live claim: rc 3, no tc, no ndt down" \
    rc3_nocalls "$rc" "$d"
check "  ... the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup pkgdotdot)"; write_knob "$d/knobs/app_package_override" "$d/run/../pkgB"
state_set "$d" package "\"$d/run/../pkgB\""; rc="$(run "$d")"
check "a package that climbs out of the run dir with ..: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup pkgsibling)"; write_knob "$d/knobs/app_package_override" "$d/run2/pkg"
state_set "$d" package "\"$d/run2/pkg\""; rc="$(run "$d")"
check "a package in a sibling dir whose name starts with the run dir's: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup pkgsymlink)"; mkdir -p "$d/shared/pkg"; ln -s "$d/shared/pkg" "$d/run/pkgA"; rc="$(run "$d")"
check "a package that is a link out of the run dir: rc 3, no stub called" rc3_nocalls "$rc" "$d"
d="$(setup pkgisrun)"; write_knob "$d/knobs/app_package_override" "$d/run"
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
d="$(setup reclaimretry)"; expire "$d"; echo 1 > "$d/rc.ndt.down"
rc="$(run "$d")"
check "an expired claim of ours is re-taken, then ndt down fails: rc 5" [ "$rc" -eq 5 ]
check "the failed ndt down cleared the knob (as real ndt does) and the state says down-failed" \
    bash -c '[ ! -e "$1/knobs/app_package_override" ] && [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"phase\"])" "$1/run/LAB_STATE.json")" == down-failed ]' _ "$d"
check "after the re-claim the state records the new claim's expires" \
    [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['claim_expires'])" "$d/run/LAB_STATE.json")" == "$(claim_get_exp "$d")" ]
rm -f "$d/rc.ndt.down"; : > "$d/calls"; rc="$(run "$d")"
check "  ... and the retry under that live claim finishes: rc 0" [ "$rc" -eq 0 ]
check "  ... ndt status showed no fabric: it skipped tc and the qdisc diff, ran ndt down (idempotent) and released (--force: the re-claim's baseline)" \
    [ "$(cat "$d/calls")" == "sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666
ndt status
ndt down
ndt release --force
ndt status" ]

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

echo "--- (r7) the knob as ndt writes it: a comment line, THEN the directory"
d="$(setup knobreal)"
check "the fixture's knob has ndt's two lines" [ "$(grep -c . "$d/knobs/app_package_override")" -eq 2 ]
rc="$(run "$d")"
check "the knob in ndt's two-line format: the recovery reads the path, not the comment: rc 0" [ "$rc" -eq 0 ]
check "  ... and it ran the whole recovery (tc, down, release)" bash -c 'grep -q "tc qdisc del" "$1/calls" && grep -q "^ndt down" "$1/calls" && grep -q "^ndt release" "$1/calls"' _ "$d"
d="$(setup knobblank)"; printf '# a comment\n\n   # an indented comment\n   %s\r\n' "$d/run/pkgA" > "$d/knobs/app_package_override"; rc="$(run "$d")"
check "a knob with blank lines, an indented comment and a CR-LF path (ndt's reader skips them): rc 0" [ "$rc" -eq 0 ]
d="$(setup knobcommentonly)"; printf '# written by ndt up p4 --app at 2026-10-03T18:00:00Z\n' > "$d/knobs/app_package_override"; rc="$(run "$d")"
check "a knob with a comment and no directive line is no override: rc 3, no stub called" rc3_nocalls "$rc" "$d"

echo "--- (r7) an absent override outside down-done is evidence only for this run's own notes, never for an up"
for ph in teardown down-failed claim-lost; do
    d="$(setup "noov$ph")"; rm -f "$d/knobs/app_package_override"; set_phase "$d" "$ph"; rc="$(run "$d")"
    check "$ph, knob absent, our live claim with the note of somebody's ndt up: rc 3, no stub called" rc3_nocalls "$rc" "$d"
    d="$(setup "noovown$ph")"; rm -f "$d/knobs/app_package_override"; set_phase "$d" "$ph"
    claim_set "$d" note "p4-health run-x A recover state=$d/run/LAB_STATE.json"; rc="$(run "$d")"
    check "$ph, knob absent, our live claim with this run's own note: rc 0 (tc, down, release)" \
        bash -c '[ "$2" -eq 0 ] && grep -q "tc qdisc del" "$1/calls" && grep -q "^ndt down" "$1/calls" && grep -q "^ndt release" "$1/calls"' _ "$d" "$rc"
done
d="$(setup noovdownat)"; rm -f "$d/knobs/app_package_override"; set_phase "$d" down-failed
claim_set "$d" note "down at 2026-10-03 18:20:00; verified clean; claim kept"; rc="$(run "$d")"
check "down-failed, knob absent, our live claim with ndt down's note: rc 0" [ "$rc" -eq 0 ]
d="$(setup noovupdd)"; to_down_done "$d"; claim_set "$d" note "$UP_NOTE"; rc="$(run "$d")"
check "down-done, knob absent, our live claim with an ndt up note: rc 3, no stub called" rc3_nocalls "$rc" "$d"

echo "--- (r7) somebody forced an ndt up past this run's claim: .test_run/lab.claim.overrides names its expires"
ovr_line() {  # ovr_line <expires> -- one line as ndt:1075 writes it (tab-separated key=value)
    printf 'at=2026-10-03T18:10:00+0800\tby=p4h-test\tuser=adam\tpid=4242\tcommand=up p4 4 --force\tover=p4h-test\tclaim_expires=%s\tclaim_note=%s\tmeasuring=\trunning=\n' "$1" "p4-health run-x A state=x"
}
d="$(setup overridden)"; ovr_line "$(state_get "$d" claim_expires)" > "$d/test_run/lab.claim.overrides"; rc="$(run "$d")"
check "a forced up past this run's live claim is on record: rc 3, no stub called" rc3_nocalls "$rc" "$d"
check "  ... the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup overriddenother)"; ovr_line "$(( $(state_get "$d" claim_expires) + 7 ))" > "$d/test_run/lab.claim.overrides"; rc="$(run "$d")"
check "a forced up past ANOTHER claim is on record: no effect, rc 0" [ "$rc" -eq 0 ]
d="$(setup overriddenexpired)"; expire "$d"; ovr_line "$(state_get "$d" claim_expires)" > "$d/test_run/lab.claim.overrides"; rc="$(run "$d")"
check "a forced up past this run's claim, which has since expired: rc 3, no stub called" rc3_nocalls "$rc" "$d"

echo "--- (r7) the claim is looked at again after the down, before the knobs and the release"
d="$(setup claimtakenindown)"; echo "$(( $(date +%s) + 900 ))" > "$d/down_claim_expires"; rc="$(run "$d")"
check "a claim of the same owner taken while ndt down ran: rc 3" [ "$rc" -eq 3 ]
check "  ... the knob was not written and nothing was released" \
    bash -c '[ "$(cat "$1/knobs/host_count_override")" == "6" ] && ! grep -q "^ndt release" "$1/calls"' _ "$d"

echo "--- (r7) the messages say what the state is"
d="$(setup gonewithprev)"
NDT_OWNER=p4h-test "$d/repo/tools/test_workflow/ndt" release --force > /dev/null 2>&1      # somebody releases it: the REAL release keeps .prev
rc="$(run "$d")"
check "a claim file that is gone, its released copy kept as .prev: rc 3 and the output says which claim it was" \
    bash -c '[ "$2" -eq 3 ] && grep -q "claim file is gone" "$1/out" && grep -q "kept as .*lab.claim.prev" "$1/out" && grep -q "the claim this run recorded" "$1/out"' _ "$d" "$rc"
d="$(setup gonenoprev)"; rm -f "$d/test_run/lab.claim"; rc="$(run "$d")"
check "a claim file that is gone and no .prev: rc 3 and the output says so" \
    bash -c '[ "$2" -eq 3 ] && grep -q "claim file is gone" "$1/out" && grep -q "no .*lab.claim.prev" "$1/out"' _ "$d" "$rc"
d="$(setup unrecorded)"; state_set "$d" claim_expires null; state_set "$d" phase '"claiming"'
claim_set "$d" note "p4-health run-x A state=$d/run/LAB_STATE.json"; rc="$(run "$d")"
check "no claim_expires and the claim's note names this run: rc 2 and the output prints the release command" \
    bash -c '[ "$2" -eq 2 ] && grep -q "NDT_OWNER=p4h-test $1/bin/ndt release" "$1/out"' _ "$d" "$rc"
d="$(setup unrecordedother)"; state_set "$d" claim_expires null; rc="$(run "$d")"
check "no claim_expires and a claim that is not this run's: rc 2 and no release command" \
    bash -c '[ "$2" -eq 2 ] && ! grep -q "ndt release" "$1/out"' _ "$d" "$rc"
d="$(setup aliveunrecorded)"; state_set "$d" claim_expires null; state_set "$d" pid "$$"; rc="$(run "$d")"
check "the probe is still running with no claim_expires recorded yet: rc 3 (still running), not rc 2" rc3_nocalls "$rc" "$d"

echo "--- (r8) a down that already ran leaves no interfaces: the retry asks ndt status, not the qdisc diff"
# The stubs follow ndt: after a down the fabric is gone (status shows 0) and `qdisc diff` exits 1 (qdisc_snapshot.sh:37-44);
# ndt down can exit 1 after tearing everything down (ndt:5330-5336) and exits 3 on an empty lab (ndt:5559-5572).
d="$(setup oneshotred)"; echo 1 > "$d/rc.ndt.down"; rc="$(run "$d")"
check "ndt down exits 1 after tearing everything down: rc 5, down-failed" [ "$rc" -eq 5 ] 
rm -f "$d/rc.ndt.down"; : > "$d/calls"; rc="$(run "$d")"
check "  ... the retry finds no fabric and finishes: rc 0" [ "$rc" -eq 0 ]
check "  ... it asked ndt status, skipped tc and the qdisc diff, ran ndt down (exit 0 now), then released" \
    [ "$(cat "$d/calls")" == "sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666
ndt status
ndt down
ndt release
ndt status" ]
check "  ... and it recorded down-done" [ "$(state_get "$d" phase)" == "down-done" ]
check "  ... the host knob is its snapshot's bytes" [ "$(cat "$d/knobs/host_count_override")" == "4  # kept as bytes" ]
d="$(setup probedownfailed)"; rm -f "$d/knobs/app_package_override"; : > "$d/down_ran"; set_phase "$d" down-failed
claim_set "$d" note "down at 2026-10-03 18:20:00; verified clean; this teardown still exits 1, for something other than residue; claim kept"; rc="$(run "$d")"
check "the probe's own down-failed after a down that left the lab verified clean: ndt down is run again (exit 0), then the knobs and the release: rc 0" \
    rc_calls "$rc" 0 "$d" "sudo -n mnexec -a 1 kill -TERM 555
kill -TERM 666
ndt status
ndt down
ndt release
ndt status"
d="$(setup downrc3)"; fabric_gone "$d"; echo 3 > "$d/rc.ndt.down"; rc="$(run "$d")"
check "ndt down exits 3 (measured nothing, the lab was down): the down is done, rc 0" [ "$rc" -eq 0 ]
check "  ... it went on to the release" bash -c 'grep -q "^ndt down" "$1/calls" && grep -q "^ndt release" "$1/calls"' _ "$d"
d="$(setup stillup)"; rm -f "$d/knobs/app_package_override"; set_phase "$d" teardown; echo 1 > "$d/rc.qdisc.diff"
claim_set "$d" note "p4-health run-x A recover state=x"; rc="$(run "$d")"
check "knob absent but ndt status shows a fabric: steps 4-5 as before (qdisc drift stops at rc 4)" [ "$rc" -eq 4 ]
check "  ... no ndt down, no release" no_line "$d" '^ndt down\|^ndt release'

echo "--- (r8) recover.sh's own re-claim records the round's host count as the baseline: its release is --force"
d="$(setup expiredpkgchangedhosts)"; expire "$d"; rc="$(run "$d")"
check "an expired claim, the package changed the host count: rc 0 and the host knob at its pre-round value" \
    bash -c '[ "$2" -eq 0 ] && [ "$(cat "$1/knobs/host_count_override")" == "4  # kept as bytes" ]' _ "$d" "$rc"
check "  ... released with --force and the output says why" \
    bash -c 'grep -q "^ndt release --force" "$1/calls" && grep -q "releasing with --force" "$1/out"' _ "$d"
check "  ... the state records the claim recover.sh took" \
    [ "$(state_get "$d" recover_claim_expires)" == "$(state_get "$d" claim_expires)" ]
d="$(setup releaserefused)"; echo 1 > "$d/rc.ndt.release"; rc="$(run "$d")"
check "a release refused for another reason: rc 6 and the output says what was restored, not to write the baseline back" \
    bash -c '[ "$2" -eq 6 ] && grep -q "do NOT write" "$1/out" && ! grep -q "do what it printed" "$1/out" && grep -q "pre-round snapshot" "$1/out"' _ "$d" "$rc"
check "  ... the host knob stays at its restored value" [ "$(cat "$d/knobs/host_count_override")" == "4  # kept as bytes" ]
check "  ... and a plain release was tried (the claim is the probe's own)" no_line "$d" '^ndt release --force'
d="$(setup reclaimrefused)"; expire "$d"; echo 1 > "$d/rc.ndt.release"; rc="$(run "$d")"
check "recover's own re-claim and a release refused for another reason: rc 6 with the same message" \
    bash -c '[ "$2" -eq 6 ] && grep -q "do NOT write" "$1/out"' _ "$d" "$rc"

echo "--- (r8) the unrecorded-claim hint says nothing was brought up only when no forced up is on record for that claim"
d="$(setup unrecordedforced)"; state_set "$d" claim_expires null; state_set "$d" phase '"claiming"'
claim_set "$d" note "p4-health run-x A state=$d/run/LAB_STATE.json"
ovr_line "$(claim_get_exp "$d")" > "$d/test_run/lab.claim.overrides"; rc="$(run "$d")"
check "a forced up on record over the unrecorded claim: rc 2, the output warns and does not say nothing was brought up" \
    bash -c '[ "$2" -eq 2 ] && grep -q "WARNING.*ndt up --force" "$1/out" && ! grep -q "Nothing was brought up" "$1/out"' _ "$d" "$rc"
d="$(setup unrecordedclean)"; state_set "$d" claim_expires null; state_set "$d" phase '"claiming"'
claim_set "$d" note "p4-health run-x A state=$d/run/LAB_STATE.json"; rc="$(run "$d")"
check "no forced up on record over it: rc 2 and the output says nothing was brought up under it" \
    bash -c '[ "$2" -eq 2 ] && grep -q "Nothing was brought up under it" "$1/out"' _ "$d" "$rc"

echo "--- (r9) a down that already ran is run AGAIN: the two status rows are not all ndt down has to tear down"
d="$(setup downfailedagain)"; rm -f "$d/knobs/app_package_override"; : > "$d/down_ran"; set_phase "$d" down-failed
claim_set "$d" note "down at 2026-10-03 18:20:00 did NOT verify clean -- the residue check found a live process; claim kept -- read 'running' below, not this note"
echo 1 > "$d/rc.ndt.down"; echo "the residue check found a live process" > "$d/down_unclean"; rc="$(run "$d")"
check "down-failed, knob absent, status 0/0, the probe's did-NOT-verify-clean note, the retry's ndt down exits 1: rc 5" [ "$rc" -eq 5 ]
check "  ... the phase is down-failed and nothing was released" \
    bash -c '[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"phase\"])" "$1/run/LAB_STATE.json")" == down-failed ] && ! grep -q "^ndt release" "$1/calls" && grep -q "^ndt down" "$1/calls"' _ "$d"
check "  ... no tc and no qdisc diff (their interfaces are gone), and the knob was not written" \
    bash -c '! grep -q "tc qdisc del\|^qdisc diff" "$1/calls" && [ "$(cat "$1/knobs/host_count_override")" == "6" ]' _ "$d"

echo "--- (r9) a status that does not answer is not an empty lab"
d="$(setup statusempty)"; rm -f "$d/knobs/app_package_override"; set_phase "$d" teardown; : > "$d/status_full"; echo 1 > "$d/rc.qdisc.diff"
claim_set "$d" note "p4-health run-x A recover state=x"; rc="$(run "$d")"
check "knob absent and ndt status printed nothing: steps 4-5 as before (qdisc drift: rc 4), no release" \
    bash -c '[ "$2" -eq 4 ] && grep -q "^qdisc diff" "$1/calls" && ! grep -q "^ndt release" "$1/calls"' _ "$d" "$rc"
d="$(setup statushalf)"; rm -f "$d/knobs/app_package_override"; set_phase "$d" teardown; printf '  bmv2 switches  0       \n' > "$d/status_full"; echo 1 > "$d/rc.qdisc.diff"
claim_set "$d" note "p4-health run-x A recover state=x"; rc="$(run "$d")"
check "knob absent and ndt status printed no host/switch row: steps 4-5 as before (rc 4)" [ "$rc" -eq 4 ]
d="$(setup downdonestatusempty)"; to_down_done "$d"; : > "$d/status_full"; rc="$(run "$d")"
check "down-done and ndt status printed nothing: rc 4, nothing released (the fabric is not shown to be gone)" \
    bash -c '[ "$2" -eq 4 ] && ! grep -q "^ndt release" "$1/calls"' _ "$d" "$rc"

echo "--- (r9) only a claim that is live now is taken for this script's own re-claim"
d="$(setup claimnoop)"; expire "$d"; : > "$d/claim_noop"; rc="$(run "$d")"
check "an expired claim, ndt claim exits 0 and writes nothing: the probe's old expires is not adopted, plain release, rc 0" \
    bash -c '[ "$2" -eq 0 ] && ! grep -q "release --force" "$1/calls" && [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(\"recover_claim_expires\"))" "$1/run/LAB_STATE.json")" == None ]' _ "$d" "$rc"
d="$(setup ownertakenindown)"; echo somebody-else > "$d/down_claim_owner"; rc="$(run "$d")"
check "another owner takes the claim during ndt down (the expires stays): rc 3, nothing released, the knob not written" \
    bash -c '[ "$2" -eq 3 ] && ! grep -q "^ndt release" "$1/calls" && [ "$(cat "$1/knobs/host_count_override")" == "6" ]' _ "$d" "$rc"

echo
echo "Ran $CHECKS checks, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
