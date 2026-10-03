#!/usr/bin/env bash
#
# recover.sh <run dir> -- finish the teardown a crashed health-check round left (DESIGN 4.5).
#
# [Co-developed with claude code -- Adam]
#
# Run by a person, after the probe died. Reads <run dir>/LAB_STATE.json, which the probe rewrites
# before every step that changes the machine, and does what its `finally` would have done, in
# the same order -- but only after proving the lab is still the probe's:
#
#   1. the probe's pid must be gone;
#   2. the claim must be this run's (owner and note), and app_package_override must name this
#      run's package. Any mismatch: print it, write NOTHING, stop (rc 3). Section 12 item 11: a
#      claim that has EXPIRED while the override still names this run's package is re-taken with
#      the same owner, and recovery continues under it;
#   3. stop the recorded sniffers and controllers, by pid;
#   4. take netem off the recorded interfaces; the qdisc tree must equal the snapshot taken after
#      `ndt up` -- if it does not, print the difference and stop for a person (rc 4);
#   5. `ndt down` as the same owner (rc 5 if it fails: nothing is released over a fabric still up);
#   6. both knobs back to their snapshot BYTES;
#   7. `ndt release`; if it refuses over a knob, do what it prints (ndt:888-899), never
#      `git checkout --` (rc 6);
#   8. `ndt status`, printed for the person to read: no bmv2, no heartbeat, no claim.
#
# Seams for tests/shell/test_p4_health_recover.sh: P4H_NDT, P4H_QDISC_SNAPSHOT, P4H_SUDO, P4H_KILL.
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
PKG="$(field package)"; NETEM="$(field netem)"; SNIFFERS="$(field sniffers)"
CONTROLLERS="$(field controllers)"; QBEFORE="$(field qdisc_before)"; PHASE="$(field phase)"
CLAIM_FILE="$(field claim_file)"; OVERRIDE="$(field app_package_override)"
NDT="${P4H_NDT:-$(field ndt)}"; NDT="${NDT:-$REPO/tools/test_workflow/ndt}"
QDISC="${P4H_QDISC_SNAPSHOT:-$REPO/tools/test_workflow/qdisc_snapshot.sh}"
SUDO="${P4H_SUDO:-sudo}"; KILL="${P4H_KILL:-kill}"
echo "recover: run $RUNID bring-up $BRINGUP phase $PHASE owner $OWNER"

# 1. the probe is gone
if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "STOP: the probe (pid $PID) is still running -- stop it first (kill -TERM $PID)."; exit 3
fi

# 2. the lab is still ours
claim_get() { [[ -f "$CLAIM_FILE" ]] && sed -n "s/^$1=//p" "$CLAIM_FILE" | head -1; }
c_owner="$(claim_get owner)"; c_note="$(claim_get note)"; c_exp="$(claim_get expires)"
now="$(date +%s)"
ov=""; [[ -f "$OVERRIDE" ]] && ov="$(head -1 "$OVERRIDE")"
ours_override=0
if [[ "$ov" == "$PKG" ]]; then ours_override=1
elif [[ -z "$ov" && "$PHASE" =~ ^(teardown|down-failed|released)$ ]]; then ours_override=1
fi
if [[ "$c_owner" == "$OWNER" && "$c_note" == *"p4-health $RUNID $BRINGUP"* && "${c_exp:-0}" -gt "$now" \
      && "$ours_override" -eq 1 ]]; then
    echo "  the claim and the override are this run's"
elif [[ ( -z "$c_owner" || "${c_exp:-0}" -le "$now" ) && "$ov" == "$PKG" ]]; then
    echo "  the claim is gone or expired and the override still names this run's package: re-claiming as $OWNER"
    if ! NDT_OWNER="$OWNER" "$NDT" claim 30 "p4-health $RUNID $BRINGUP recover state=$STATE"; then
        echo "STOP: the re-claim was refused; nothing written."; exit 3
    fi
else
    echo "STOP: the lab does not look like this run's -- nothing written."
    echo "  claim owner '$c_owner' (want '$OWNER'), note '$c_note', expires '${c_exp:-}' (now $now)"
    echo "  app_package_override '$ov' (want '$PKG')"
    exit 3
fi

# 3. sniffers (root, in a host namespace) and controllers (the user's), by pid
for p in $SNIFFERS; do "$SUDO" -n mnexec -a 1 kill -TERM "$p" || echo "  sniffer $p: already gone?"; done
for p in $CONTROLLERS; do "$KILL" -TERM "$p" || echo "  controller $p: already gone?"; done

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
