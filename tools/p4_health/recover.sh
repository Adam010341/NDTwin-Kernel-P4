#!/usr/bin/env bash
#
# recover.sh <run dir> -- finish the teardown a crashed health-check round left (design 4.5).
#
# [Co-developed with claude code -- Adam]
#
# Run by a person, after the probe died. Reads <run dir>/LAB_STATE.json, which the probe rewrites
# before every step that changes the machine, and does what its `finally` would have done, in
# the same order -- but only after checking, on evidence that belongs to THIS run alone (its own
# package directory, the expires of its own claim), that the lab is still the probe's:
#
#   0. (r6) the state names what the proof rests on -- owner, run, package, claim_file,
#      app_package_override and claim_expires -- else rc 2 with nothing done;
#   1. the probe's pid must be gone;
#   2. the lab must still be this run's (Cut 1 review, MAJ-5): the claim's owner is the run's
#      owner and the claim is live; app_package_override names this run's package (or is empty
#      once the probe's teardown had reached `ndt down`, which clears it); and the note is one
#      this run or ndt wrote for it -- the probe's own "p4-health <run> <bring-up> ...", ndt up's
#      "in use: ndt up p4 ... by <owner>" (ndt:1207-1215), or ndt down's "down at ..."
#      (ndt:1245-1277). Any mismatch: print it, write NOTHING, stop (rc 3).
#      (r6) Two things make "this run's" a fact about THIS run and not about its owner and a path:
#      the package is inside the run's own directory (every round has its own copy, so the override
#      names this round and no other), and the claim's `expires` is the one the probe read from the
#      claim file right after its `ndt claim` succeeded (a later claim, by anyone, has another).
#      Section 12 item 11: a claim that is EXPIRED while the override still names this run's
#      package is re-taken with the same owner -- but only when that expired claim FILE is the
#      one the probe recorded (same owner, same expires; a file that is gone identifies nothing:
#      rc 3) and `ndt status --measuring` shows no measurement declared or in flight. Somebody
#      else's expired claim is not ours to take. After a re-claim the new expires is written into
#      LAB_STATE.json, so a second run of this script after a failed step still knows the claim.
#      What is still not proven: a claim another session makes for the same owner in the very same
#      second and for the same length has the same expires; and a person who runs `ndt up --app`
#      by hand on this run's package directory looks like the probe.
#   3. stop the recorded sniffers and controllers -- each only while its pid, its start time
#      (/proc/<pid>/stat field 22) and the marker in its command line all still match what the
#      probe recorded; a recycled pid is left alone;
#   (r3, review NEW-C) phase `down-done` -- the probe's `ndt down` already succeeded: `ndt status`
#      must show no bmv2 switch and no host/switch process (else STOP, rc 4); steps 4-5 are skipped
#      (the interfaces they would touch are gone, and a qdisc diff against them always differs);
#      the recovery goes to the knobs and the release.
#      (r4, Cut 1 follow-ups) Step 3 is NOT skipped there: stopping a process needs no fabric, and
#      a kill that failed in the probe's teardown is still recorded for exactly this retry.
#      (r5, Cut 1 follow-ups) The `ndt status` no-fabric check runs BEFORE a re-claim writes
#      anything (a fabric that is up gets no 30-minute claim from us: rc 4). And an absent
#      app_package_override is evidence only in down-done, where the probe's own successful `ndt
#      down` removed it (ndt:1597-1601): there, our own expired claim FILE (owner = ours) is
#      re-taken. In every other phase an absent override may be somebody else's up, down or clean;
#      the fabric is not provably ours and the answer is rc 3 with nothing written.
#   (r5) phase `released` -- the probe finished: only step 3 runs (a recorded process whose kill
#      failed in the probe); no claim, no knob, no netem, no `ndt down`. rc 0, or rc 7 if a kill
#      failed. A released run dir must never drive steps 4-5 against a later round's fabric.
#   4. take netem off the recorded interfaces; the qdisc tree must equal the snapshot taken after
#      `ndt up` -- if it does not, print the difference and stop for a person (rc 4);
#   5. `ndt down` as the same owner (rc 5 if it fails: nothing is released over a fabric still up);
#   6. both knobs back to their snapshot BYTES;
#   7. `ndt release`; if it refuses over a knob, do what it prints (ndt:888-899), never
#      `git checkout --` (rc 6);
#   8. `ndt status`, printed for the person to read: no bmv2, no heartbeat, no claim.
#      (r5) rc 7 at the very end if any kill in step 3 failed: the lab is put right, a process is not.
#
# Exit: 0 done; 2 usage / root / a state file that lacks what the proof rests on; 3 not this run's
# lab, or the probe is alive; 4 a fabric up where
# none should be, or qdisc drift; 5 down or knobs failed; 6 release refused; 7 a recorded process
# could not be stopped.
#
# Seams for tests/shell/test_p4_health_recover.sh: P4H_NDT, P4H_QDISC_SNAPSHOT, P4H_SUDO, P4H_KILL,
# P4H_PROC (default /proc).
# Never pkill/pgrep: every process is stopped by the pid the state file recorded.

set -uo pipefail
RUN="${1:-}"
[[ -n "$RUN" && -f "$RUN/LAB_STATE.json" ]] || { echo "usage: $0 <run dir containing LAB_STATE.json>" >&2; exit 2; }
[[ "$(id -u)" -ne 0 ]] || { echo "refusing to run as root" >&2; exit 2; }
STATE="$RUN/LAB_STATE.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

field() {  # field <key> -- one value out of the state file (lists space-joined)
    python3 - "$STATE" "$1" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
if isinstance(v, list):
    print(" ".join(str(x) for x in v))
elif isinstance(v, dict):
    print(json.dumps(v))
elif v is not None:
    print(v)
PY
}

PID="$(field pid)"; OWNER="$(field owner)"; RUNID="$(field run)"; BRINGUP="$(field bring_up)"
PKG="$(field package)"; NETEM="$(field netem)"; QBEFORE="$(field qdisc_before)"; PHASE="$(field phase)"
PID_START="$(field pid_start)"
CLAIM_FILE="$(field claim_file)"; OVERRIDE="$(field app_package_override)"; CLAIM_EXPIRES="$(field claim_expires)"
NDT="${P4H_NDT:-$(field ndt)}"; NDT="${NDT:-$REPO/tools/test_workflow/ndt}"
QDISC="${P4H_QDISC_SNAPSHOT:-$REPO/tools/test_workflow/qdisc_snapshot.sh}"
SUDO="${P4H_SUDO:-sudo}"; KILL="${P4H_KILL:-kill}"; PROC="${P4H_PROC:-/proc}"
echo "recover: run $RUNID bring-up $BRINGUP phase $PHASE owner $OWNER"

# 0. (r6) a state file that leaves out what the proof rests on proves nothing: with an empty package
#    and an absent override "$ov" == "$PKG" would hold in every phase. A person looks at it (rc 2).
for kv in \
    "owner:$OWNER" \
    "run:$RUNID" \
    "package:$PKG" \
    "claim_file:$CLAIM_FILE" \
    "app_package_override:$OVERRIDE"; do
    if [[ -z "${kv#*:}" ]]; then
        echo "STOP: $STATE has no ${kv%%:*} -- nothing is proved without it; a person looks. Nothing done."; exit 2
    fi
done
# claim_expires: absent, empty, null, 0 or text all fail this one test
[[ "$CLAIM_EXPIRES" =~ ^[1-9][0-9]*$ ]] || {
    echo "STOP: $STATE has claim_expires '$CLAIM_EXPIRES', not a time -- the probe did not record its claim. Nothing done."; exit 2; }

# 3. sniffers (root, in a host namespace) and controllers (the user's): pid + start + marker.
#    Also in down-done and released (r4, r5): a kill needs no fabric, and a failed one was kept for
#    this retry. A kill that fails is counted, and the run does not end in "done" (r5, rc 7).
KILL_FAILED=0
procs() {  # procs <key> -- "pid start marker" per recorded process
    python3 - "$STATE" "$1" <<'PY'
import json, sys
for e in json.load(open(sys.argv[1])).get(sys.argv[2]) or []:
    if isinstance(e, dict):
        print(e.get("pid"), e.get("start"), e.get("marker"))
PY
}
still_ours() {  # still_ours <pid> <start> <marker>
    local stat cmd start
    stat="$(cat "$PROC/$1/stat" 2>/dev/null)" || return 1
    start="$(printf '%s' "${stat##*) }" | awk '{print $20}')"
    cmd="$(tr '\0' ' ' < "$PROC/$1/cmdline" 2>/dev/null)"
    [[ "$start" == "$2" && "$cmd" == *"$3"* ]]
}
stop_recorded() {
    local p st mk
    while read -r p st mk; do
        [[ -n "$p" ]] || continue
        if still_ours "$p" "$st" "$mk"; then
            "$SUDO" -n mnexec -a 1 kill -TERM "$p" || { echo "  sniffer $p: kill failed"; KILL_FAILED=$((KILL_FAILED + 1)); }
        else echo "  sniffer $p: gone or no longer the process the probe started -- left alone"; fi
    done < <(procs sniffers)
    while read -r p st mk; do
        [[ -n "$p" ]] || continue
        if still_ours "$p" "$st" "$mk"; then
            "$KILL" -TERM "$p" || { echo "  controller $p: kill failed"; KILL_FAILED=$((KILL_FAILED + 1)); }
        else echo "  controller $p: gone or no longer the process the probe started -- left alone"; fi
    done < <(procs controllers)
}

# 1. the probe is gone -- its pid alive WITH the start time it recorded is the probe still
#    running; the same pid with another start time is a recycled pid (review MINOR 6)
proc_start() { local stat; stat="$(cat "$PROC/$1/stat" 2>/dev/null)" || return 1; printf '%s' "${stat##*) }" | awk '{print $20}'; }
if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    now_start="$(proc_start "$PID")"
    if [[ -z "$PID_START" || -z "$now_start" || "$now_start" == "$PID_START" ]]; then
        echo "STOP: the probe (pid $PID) is still running -- stop it first (kill -TERM $PID)."; exit 3
    fi
    echo "  pid $PID is alive but started at $now_start, not $PID_START: a recycled pid, not the probe"
fi

# 1b. (r5) a released run: the probe finished its teardown. Only the identity-checked kills of what it
#     recorded and could not stop; nothing else is this run's to touch any more.
if [[ "$PHASE" == released ]]; then
    echo "  phase released: stopping only what the probe recorded and could not stop; no claim, no knob, no ndt down"
    stop_recorded
    if [[ "$KILL_FAILED" -gt 0 ]]; then
        echo "STOP: $KILL_FAILED recorded process(es) could not be stopped (above); a person stops them."; exit 7
    fi
    echo "recover: nothing else to do for a released run."; exit 0
fi

# 1c. (r6) the package is this run's own copy, inside the run's directory. A package at a path another
#     round can also use proves only that somebody ran `ndt up --app` with that path.
run_abs="$(readlink -m "$RUN")"; pkg_abs="$(readlink -m "$PKG")"
if [[ "$pkg_abs" != "$run_abs"/* ]]; then
    echo "STOP: the package '$PKG' is not inside the run dir '$RUN': this state was not written by a probe"
    echo "      that gives every round its own package, so the override cannot tell this run from another. Nothing written."
    exit 3
fi

# 2. the lab is still ours
claim_get() { [[ -f "$CLAIM_FILE" ]] && sed -n "s/^$1=//p" "$CLAIM_FILE" | head -1; }
c_owner="$(claim_get owner)"; c_note="$(claim_get note)"; c_exp="$(claim_get expires)"
c_meas="$(claim_get measuring)"
[[ "$c_exp" =~ ^[0-9]+$ ]] || c_exp=0
now="$(date +%s)"
# (r6) the claim in the file is the one the probe recorded right after `ndt claim` -- not a later one
claim_same=0; [[ "$c_exp" -gt 0 && "$c_exp" -eq "$CLAIM_EXPIRES" ]] && claim_same=1
ov=""; [[ -f "$OVERRIDE" ]] && ov="$(head -1 "$OVERRIDE")"
override_ours=0
if [[ "$ov" == "$PKG" ]]; then override_ours=1
elif [[ -z "$ov" && "$PHASE" =~ ^(teardown|down-failed|down-done|claim-lost)$ ]]; then override_ours=1
fi
note_ours=0
case "$c_note" in
    "p4-health $RUNID $BRINGUP "*)               note_ours=1 ;;
    "in use: ndt up p4 "*" by $OWNER")          note_ours=1 ;;
    "down at "*)                                note_ours=1 ;;
esac
measuring_now() {  # a declaration or a measurement in flight, per ndt's own rows; empty if none.
    # Fails CLOSED (review MINOR 6): an `ndt status --measuring` that does not answer is busy.
    # (r4) So is one that answers with neither a `measuring` nor an `orphaned` row: ndt always
    # prints one of the two (ndt:6803-6815), so their absence is an answer we do not understand.
    local out
    if ! out="$(NDT_OWNER="$OWNER" "$NDT" status --measuring 2>/dev/null)"; then
        echo "ndt status --measuring did not answer"; return
    fi
    if ! printf '%s\n' "$out" | awk '$1 == "measuring" || $1 == "orphaned" { found = 1 } END { exit !found }'; then
        echo "ndt status --measuring printed neither a measuring nor an orphaned row"; return
    fi
    printf '%s\n' "$out" | awk '$1 == "declared" || ($1 == "measuring" && $2 != "nothing") { print; exit }'
}
down_done_fabric_check() {  # (r3, review NEW-C; r5: called BEFORE any write) the fabric was torn down already; prove it
    [[ "$PHASE" == down-done ]] || return 0
    local st_out n_bmv2 n_mn
    st_out="$(NDT_OWNER="$OWNER" "$NDT" status 2>/dev/null)"
    n_bmv2="$(printf '%s\n' "$st_out" | awk '$1 == "bmv2" && $2 == "switches" { print $3; exit }')"
    n_mn="$(printf '%s\n' "$st_out" | awk '$1 == "host/switch" { print $2; exit }')"
    if [[ "$n_bmv2" != 0 || "$n_mn" != 0 ]]; then
        echo "STOP: phase is down-done but ndt status shows bmv2 switches '${n_bmv2:-?}', host/switch"
        echo "      '${n_mn:-?}' -- a fabric is up. A person decides; nothing written."
        exit 4
    fi
    echo "  the probe's ndt down had completed and ndt status shows no fabric: knobs and release only"
}
if [[ "$c_owner" == "$OWNER" && "$c_exp" -gt "$now" && "$claim_same" -eq 1 && "$override_ours" -eq 1 && "$note_ours" -eq 1 ]]; then
    echo "  the claim, its note and the override are this run's"
    down_done_fabric_check
elif [[ ( -z "$c_owner" || "$c_owner" == "$OWNER" ) && "$c_exp" -le "$now" && "$claim_same" -eq 1 \
        && ( "$ov" == "$PKG" || ( -z "$ov" && "$PHASE" == down-done && "$c_owner" == "$OWNER" ) ) ]]; then
    # (r5) an expired claim is re-taken only on evidence the fabric is still ours: the override
    # still names our package, or -- in down-done alone, where our own `ndt down` removed it --
    # the expired claim file is OUR owner's. The fabric check comes first: it writes nothing.
    down_done_fabric_check
    busy="$(measuring_now)"
    if [[ -n "$c_meas" || -n "$busy" ]]; then
        echo "STOP: the claim is expired, but a measurement is declared or running:"
        echo "  ${c_meas:+claim measuring=$c_meas }$busy"
        echo "  nothing written."
        exit 3
    fi
    echo "  the claim is expired, it is the one the probe recorded, the override still names this run's"
    echo "  package (or, in down-done, ndt down cleared it and the claim file is ours) and nothing is"
    echo "  measuring: re-claiming as $OWNER"
    if ! NDT_OWNER="$OWNER" "$NDT" claim 30 "p4-health $RUNID $BRINGUP recover state=$STATE"; then
        echo "STOP: the re-claim was refused; nothing written."; exit 3
    fi
    # (r6) the claim is a new one now: record its expires, or a second run after a failed step would
    # stop at rc 3 on a claim that is ours. Read the way the script reads every claim field.
    new_exp="$(claim_get expires)"
    if [[ "$new_exp" =~ ^[1-9][0-9]*$ ]] && python3 - "$STATE" "$new_exp" <<'PY'
import json, os, sys
st = json.load(open(sys.argv[1]))
st["claim_expires"] = int(sys.argv[2])
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(st, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, sys.argv[1])
PY
    then echo "  recorded the new claim's expires ($new_exp) in $STATE"
    else echo "  WARNING: could not record the new claim's expires; a second run of this script will stop at rc 3"
    fi
else
    echo "STOP: the lab does not look like this run's -- nothing written."
    echo "  claim owner '$c_owner' (want '$OWNER'), note '$c_note', expires '$c_exp' (now $now; the probe recorded $CLAIM_EXPIRES)"
    echo "  app_package_override '$ov' (want '$PKG')"
    exit 3
fi

stop_recorded

if [[ "$PHASE" != down-done ]]; then
# 4. netem off, and the qdisc tree must be what it was right after `ndt up`
for i in $NETEM; do "$SUDO" -n tc qdisc del dev "$i" root || echo "  $i: no netem to remove?"; done
if [[ -n "$QBEFORE" ]]; then
    if ! "$QDISC" diff "$QBEFORE"; then
        echo "STOP: the qdisc tree differs from the snapshot after up (above). A person decides; nothing"
        echo "      further was done -- the fabric is still up and the claim still held."
        exit 4
    fi
fi

# 5. down, as the same owner
if ! NDT_OWNER="$OWNER" "$NDT" down; then
    echo "STOP: ndt down failed; NOT releasing over a fabric that may still be up."; exit 5
fi
fi   # not down-done

# 6. the knobs, as bytes
python3 - "$STATE" <<'PY' || { echo "STOP: could not put the knobs back"; exit 5; }
import base64, json, os, sys
st = json.load(open(sys.argv[1]))
for name, b64 in sorted((st.get("knob_snapshot") or {}).items()):
    path = (st.get("knob_paths") or {})[name]
    if b64 is None:
        if os.path.exists(path):
            os.remove(path)
        print("  %s: absent again" % name)
    else:
        with open(path, "wb") as fh:
            fh.write(base64.b64decode(b64))
        print("  %s: restored" % name)
PY

# 7. release
if ! out="$(NDT_OWNER="$OWNER" "$NDT" release 2>&1)"; then
    echo "$out"
    echo "STOP: ndt release refused; do what it printed above (never 'git checkout --')."; exit 6
fi
echo "$out"

# 8. what the lab looks like now
NDT_OWNER="$OWNER" "$NDT" status || true
if [[ "$KILL_FAILED" -gt 0 ]]; then
    echo "recover: the lab is put right, but $KILL_FAILED recorded process(es) could not be stopped (kill failed above): rc 7"
    exit 7
fi
echo "recover: done -- read the status above: no bmv2, no heartbeat, no claim."
