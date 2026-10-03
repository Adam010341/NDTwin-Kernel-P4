#!/usr/bin/env bash
#
# recover.sh <run dir> -- finish the teardown a crashed health-check round left (design 4.5).
#
# [Co-developed with claude code -- Adam]
#
# Run by a person, after the probe died. Reads <run dir>/LAB_STATE.json, which the probe rewrites
# before every step that changes the machine, and does what its `finally` would have done, in
# the same order -- but only after proving the lab is still the probe's:
#
#   1. the probe's pid must be gone;
#   2. the lab must still be this run's (Cut 1 review, MAJ-5): the claim's owner is the run's
#      owner and the claim is live; app_package_override names this run's package (or is empty
#      once the probe's teardown had reached `ndt down`, which clears it); and the note is one
#      this run or ndt wrote for it -- the probe's own "p4-health <run> <bring-up> ...", ndt up's
#      "in use: ndt up p4 ... by <owner>" (ndt:1207-1215), or ndt down's "down at ..."
#      (ndt:1245-1277). Any mismatch: print it, write NOTHING, stop (rc 3).
#      Section 12 item 11: a claim that is GONE or EXPIRED while the override still names this
#      run's package is re-taken with the same owner -- but only when the expired claim's owner
#      was this run's (or there is no claim file at all) and `ndt status --measuring` shows no
#      measurement declared or in flight. Somebody else's expired claim is not ours to take.
#   3. stop the recorded sniffers and controllers -- each only while its pid, its start time
#      (/proc/<pid>/stat field 22) and the marker in its command line all still match what the
#      probe recorded; a recycled pid is left alone;
#   4. take netem off the recorded interfaces; the qdisc tree must equal the snapshot taken after
#      `ndt up` -- if it does not, print the difference and stop for a person (rc 4);
#   5. `ndt down` as the same owner (rc 5 if it fails: nothing is released over a fabric still up);
#   6. both knobs back to their snapshot BYTES;
#   7. `ndt release`; if it refuses over a knob, do what it prints (ndt:888-899), never
#      `git checkout --` (rc 6);
#   8. `ndt status`, printed for the person to read: no bmv2, no heartbeat, no claim.
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
CLAIM_FILE="$(field claim_file)"; OVERRIDE="$(field app_package_override)"
NDT="${P4H_NDT:-$(field ndt)}"; NDT="${NDT:-$REPO/tools/test_workflow/ndt}"
QDISC="${P4H_QDISC_SNAPSHOT:-$REPO/tools/test_workflow/qdisc_snapshot.sh}"
SUDO="${P4H_SUDO:-sudo}"; KILL="${P4H_KILL:-kill}"; PROC="${P4H_PROC:-/proc}"
echo "recover: run $RUNID bring-up $BRINGUP phase $PHASE owner $OWNER"

# 1. the probe is gone
if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "STOP: the probe (pid $PID) is still running -- stop it first (kill -TERM $PID)."; exit 3
fi

# 2. the lab is still ours
claim_get() { [[ -f "$CLAIM_FILE" ]] && sed -n "s/^$1=//p" "$CLAIM_FILE" | head -1; }
c_owner="$(claim_get owner)"; c_note="$(claim_get note)"; c_exp="$(claim_get expires)"
c_meas="$(claim_get measuring)"
[[ "$c_exp" =~ ^[0-9]+$ ]] || c_exp=0
now="$(date +%s)"
ov=""; [[ -f "$OVERRIDE" ]] && ov="$(head -1 "$OVERRIDE")"
override_ours=0
if [[ "$ov" == "$PKG" ]]; then override_ours=1
elif [[ -z "$ov" && "$PHASE" =~ ^(teardown|down-failed|claim-lost|released)$ ]]; then override_ours=1
fi
note_ours=0
case "$c_note" in
    "p4-health $RUNID $BRINGUP "*)               note_ours=1 ;;
    "in use: ndt up p4 "*" by $OWNER")          note_ours=1 ;;
    "down at "*)                                note_ours=1 ;;
esac
measuring_now() {  # a declaration or a measurement in flight, per ndt's own rows; empty if none
    NDT_OWNER="$OWNER" "$NDT" status --measuring 2>/dev/null \
        | awk '$1 == "declared" || ($1 == "measuring" && $2 != "nothing") { print; exit }'
}
if [[ "$c_owner" == "$OWNER" && "$c_exp" -gt "$now" && "$override_ours" -eq 1 && "$note_ours" -eq 1 ]]; then
    echo "  the claim, its note and the override are this run's"
elif [[ ( -z "$c_owner" || "$c_owner" == "$OWNER" ) && "$c_exp" -le "$now" && "$ov" == "$PKG" ]]; then
    busy="$(measuring_now)"
    if [[ -n "$c_meas" || -n "$busy" ]]; then
        echo "STOP: the claim is gone or expired, but a measurement is declared or running:"
        echo "  ${c_meas:+claim measuring=$c_meas }$busy"
        echo "  nothing written."
        exit 3
    fi
    echo "  the claim is gone or expired, it was this run's owner's, the override still names this"
    echo "  run's package and nothing is measuring: re-claiming as $OWNER"
    if ! NDT_OWNER="$OWNER" "$NDT" claim 30 "p4-health $RUNID $BRINGUP recover state=$STATE"; then
        echo "STOP: the re-claim was refused; nothing written."; exit 3
    fi
else
    echo "STOP: the lab does not look like this run's -- nothing written."
    echo "  claim owner '$c_owner' (want '$OWNER'), note '$c_note', expires '$c_exp' (now $now)"
    echo "  app_package_override '$ov' (want '$PKG')"
    exit 3
fi

# 3. sniffers (root, in a host namespace) and controllers (the user's): pid + start + marker
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
while read -r p st mk; do
    [[ -n "$p" ]] || continue
    if still_ours "$p" "$st" "$mk"; then "$SUDO" -n mnexec -a 1 kill -TERM "$p" || echo "  sniffer $p: kill failed"
    else echo "  sniffer $p: gone or no longer the process the probe started -- left alone"; fi
done < <(procs sniffers)
while read -r p st mk; do
    [[ -n "$p" ]] || continue
    if still_ours "$p" "$st" "$mk"; then "$KILL" -TERM "$p" || echo "  controller $p: kill failed"
    else echo "  controller $p: gone or no longer the process the probe started -- left alone"; fi
done < <(procs controllers)

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
echo "recover: done -- read the status above: no bmv2, no heartbeat, no claim."
