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
#   1. the probe's pid must be gone;
#   0. (r6; r7: after 1) the state names what the proof rests on -- owner, run, package, claim_file,
#      app_package_override and claim_expires -- else rc 2 with nothing done. A claim that carries this
#      run's own note "p4-health <run> <bring-up> state=<this file>" but no recorded expires is the one the
#      probe took and never recorded: the release command is printed;
#   2. the lab must still be this run's (Cut 1 review, MAJ-5): the claim's owner is the run's
#      owner and the claim is live; app_package_override names this run's package (or is empty
#      once the probe's teardown had reached `ndt down`, which clears it); and the note is one
#      this run or ndt wrote for it -- the probe's own "p4-health <run> <bring-up> ...", ndt up's
#      "in use: ndt up p4 ... by <owner>" (ndt:1207-1215), or ndt down's "down at ..."
#      (ndt:1245-1277). Any mismatch: print it, write NOTHING, stop (rc 3).
#      (r7) The override is read as ndt reads it: the first line that is neither blank nor a `#`
#      comment (real ndt writes a comment line and then the path, ndt:1642-1643). When it is ABSENT
#      (ndt down, and a baseline ndt up, clear it) the note must be this run's own or ndt down's, never
#      an "in use: ndt up ..." (an ndt up of the same owner writes exactly that); and if
#      <claim file>.overrides records an `ndt up --force` past a claim with OUR expires (ndt:1058,
#      1071), the claim is not ours to act under, whichever branch it would take.
#      (r6) Two things make "this run's" a fact about THIS run and not about its owner and a path:
#      the package is inside the run's own directory (every round has its own copy, so the override
#      names this round and no other), and the claim's `expires` is the one the probe read from the
#      claim file right after its `ndt claim` succeeded (a later claim, by anyone, has another).
#      Section 12 item 11: a claim that is EXPIRED while the override still names this run's
#      package -- or, in down-done alone, is absent -- is re-taken with the same owner, but only when
#      that expired claim FILE is the one the probe recorded (the owner is ours or the file names none,
#      and the expires is the recorded one; a file that is gone identifies nothing: rc 3, with what
#      <claim file>.prev says) and `ndt status --measuring` shows no measurement declared or in
#      flight. Somebody else's expired claim is not ours to take. After a re-claim the new expires is
#      written into LAB_STATE.json, so a second run after a failed step still knows the claim.
#      After its own `ndt down` this script records phase down-done (or down-failed) as the probe does:
#      ndt clears the knob either way, so the next run could not tell otherwise.
#      Before the knobs are put back and the claim released, the claim file is read once more: still our
#      owner, still the recorded expires, else rc 3 (`ndt down` takes minutes).
#      What is still not proven: a claim another session makes for the same owner that ends in the same
#      second (start + 60*minutes, ndt:824) has the same expires; a person who runs `ndt up --app` by
#      hand on this run's package directory looks like the probe; a run killed between its own
#      `ndt down` and the phase write leaves phase up or cells with the knob gone (rc 3 on the next run);
#      and the probe's own `ndt down`, killed between removing the knob (cmd_clean, ndt:5605) and writing its
#      note (ndt:5538), leaves the knob gone and the note still "in use: ndt up ...": the note rule refuses
#      it (rc 3), which fails safe.
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
#      for an EXPIRED claim the answer is rc 3 with nothing written. (r7) For a LIVE claim with the
#      recorded expires an absent override is accepted in teardown, down-failed and claim-lost (a failed
#      `ndt down` clears it too), on this run's own note or ndt down's -- not on an ndt up's.
#   (r5) phase `released` -- the probe finished: only step 3 runs (a recorded process whose kill
#      failed in the probe); no claim, no knob, no netem, no `ndt down`. rc 0, or rc 7 if a kill
#      failed. A released run dir must never drive steps 4-5 against a later round's fabric.
#   4. take netem off the recorded interfaces; the qdisc tree must equal the snapshot taken after
#      `ndt up` -- if it does not, print the difference and stop for a person (rc 4);
#      (r8) Not when the knob is absent and `ndt status` shows no switch and no host/switch process: a
#      `ndt down` already ran (its interfaces are gone, the qdisc diff would always differ). That records
#      phase down-done and goes on to the re-check, the knobs and the release; with a fabric up, steps 4-5 run;
#   5. `ndt down` as the same owner (rc 5 if it fails: nothing is released over a fabric still up). (r8)
#      Its rc 3 -- it measured nothing, the lab was already down (ndt:5524-5537) -- counts as done;
#   6. both knobs back to their snapshot BYTES;
#   7. `ndt release`. (r8) `ndt claim` records the round baseline (the host knob's value then, ndt:447-460) and
#      `ndt release` refuses while the knob differs (ndt:890-903): this script's own re-claim recorded the
#      ROUND's value, so after step 6 the refusal is certain, and the value it tells you to write back would
#      undo the restore. When the claim held is this script's own re-claim (recover_claim_expires in the state is
#      its expires) and every knob is its snapshot, the release is `--force`, with a line saying why; otherwise
#      it is plain. rc 6 if refused: the knobs were restored, do NOT write a printed value back, a person reads
#      ndt status (never `git checkout --`);
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

# claim_get <field> -- one field of the claim file, the first occurrence, as the file has it
claim_get() { [[ -f "$CLAIM_FILE" ]] && sed -n "s/^$1=//p" "$CLAIM_FILE" | head -1; }
# state_set <key> <value> -- one field of LAB_STATE.json, written atomically; digits stay a number (r6, r7)
state_set() {
    python3 - "$STATE" "$1" "$2" <<'PY'
import json, os, sys
st = json.load(open(sys.argv[1]))
st[sys.argv[2]] = int(sys.argv[3]) if sys.argv[3].isdigit() else sys.argv[3]
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(st, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, sys.argv[1])
PY
}

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

# knobs_match_snapshot -- every knob in LAB_STATE.json is now exactly its snapshot (r8)
knobs_match_snapshot() {
    python3 - "$STATE" <<'PY'
import base64, json, os, sys
st = json.load(open(sys.argv[1]))
for name, b64 in (st.get("knob_snapshot") or {}).items():
    path = (st.get("knob_paths") or {})[name]
    if b64 is None:
        if os.path.exists(path):
            sys.exit(1)
    else:
        try:
            with open(path, "rb") as fh:
                if fh.read() != base64.b64decode(b64):
                    sys.exit(1)
        except OSError:
            sys.exit(1)
PY
}

# 0. (r6; r7: after the probe-alive check, so a probe still running is told so) a state file that leaves
#    out what the proof rests on proves nothing: with an empty package and an absent override
#    "$ov" == "$PKG" would hold in every phase. A person looks at it (rc 2).
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
if ! [[ "$CLAIM_EXPIRES" =~ ^[1-9][0-9]*$ ]]; then
    echo "STOP: $STATE has claim_expires '$CLAIM_EXPIRES', not a time -- the probe did not record its claim. Nothing done."
    # (r7) Until `ndt up` rewrites it, the probe's claim note "p4-health <run> <bring-up> state=<this file>"
    # is unique to this run: a claim with that note and our owner is the one the probe took and never recorded.
    if [[ "$(claim_get owner)" == "$OWNER" && "$(claim_get note)" == "p4-health $RUNID $BRINGUP state=$STATE" ]]; then
        echo "  The claim in $CLAIM_FILE is this run's: its note names this state file."
        # (r8) "nothing was brought up" is only known when nobody forced an ndt up past that claim
        # (a forced up leaves the note as it found it, ndt:1131; the override record names the claim's expires).
        if [[ -f "$CLAIM_FILE.overrides" ]] && awk -F'\t' -v e="claim_expires=$(claim_get expires)" \
                '{ for (i = 1; i <= NF; i++) if ($i == e) f = 1 } END { exit !f }' "$CLAIM_FILE.overrides"; then
            echo "  WARNING: $CLAIM_FILE.overrides records an ndt up --force past this claim: a fabric may be up under it."
            echo "  Look at ndt status before releasing:  NDT_OWNER=$OWNER $NDT release"
        else
            echo "  Nothing was brought up under it (no forced up is on record for it)."
            echo "  Release it with:  NDT_OWNER=$OWNER $NDT release"
        fi
    fi
    exit 2
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
c_owner="$(claim_get owner)"; c_note="$(claim_get note)"; c_exp="$(claim_get expires)"
c_meas="$(claim_get measuring)"
[[ "$c_exp" =~ ^[0-9]+$ ]] || c_exp=0
now="$(date +%s)"
# (r6) the claim in the file is the one the probe recorded right after `ndt claim` -- not a later one
claim_same=0; [[ "$c_exp" -gt 0 && "$c_exp" -eq "$CLAIM_EXPIRES" ]] && claim_same=1
# (r7) ndt records every `up --force` that went past a claim, with that claim's expires, in <claim>.overrides
# (ndt:1058, 1071; tab-separated key=value). One with OUR expires means somebody else brought a fabric up
# over this run's claim: whatever is up now is not provably ours.
claim_overridden=0
if [[ -f "$CLAIM_FILE.overrides" ]] && awk -F'\t' -v e="claim_expires=$CLAIM_EXPIRES" \
        '{ for (i = 1; i <= NF; i++) if ($i == e) f = 1 } END { exit !f }' "$CLAIM_FILE.overrides"; then
    claim_overridden=1; claim_same=0
fi
# (r7) The first line that is not blank and not a comment, as ndt's own reader takes it (app_knob_dir,
# ndt:1606-1615; the proxy's read_knob skips `#` lines too). Real ndt writes TWO lines: a
# "# written by ndt up p4 --app at ..." comment, then the directory (ndt:1642-1643).
ov=""
if [[ -f "$OVERRIDE" ]]; then
    while read -r knob_line; do
        knob_line="${knob_line%%$'\r'}"      # (read already trims the blanks around a line, as in the reader of ndt itself)
        [[ -z "$knob_line" || "$knob_line" == \#* ]] && continue
        ov="$knob_line"; break
    done < "$OVERRIDE"
fi
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
# (r7) With the knob absent, "in use: ndt up p4 ..." is what a baseline `ndt up` of the same owner writes
# after it cleared the knob (ndt:3454, 3486); a forced up by anybody leaves the note as it found it. So
# an absent knob is backed only by this run's own note or ndt down's -- never by an ndt up's.
if [[ -z "$ov" && "$c_note" == "in use: ndt up p4 "* ]]; then note_ours=0; fi
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
    if [[ "$new_exp" =~ ^[1-9][0-9]*$ ]] && state_set claim_expires "$new_exp" && state_set recover_claim_expires "$new_exp"
    then echo "  recorded the new claim's expires ($new_exp) in $STATE"
    else echo "  WARNING: could not record the new claim's expires; a second run of this script will stop at rc 3"
    fi
    [[ "$new_exp" =~ ^[1-9][0-9]*$ ]] && CLAIM_EXPIRES="$new_exp"
else
    echo "STOP: the lab does not look like this run's -- nothing written."
    if [[ ! -f "$CLAIM_FILE" ]]; then
        echo "  the claim file is gone ($CLAIM_FILE)."
        if [[ -f "$CLAIM_FILE.prev" ]]; then
            p_exp="$(sed -n 's/^expires=//p' "$CLAIM_FILE.prev" | head -1)"
            echo "  the released claim is kept as $CLAIM_FILE.prev: owner '$(sed -n 's/^owner=//p' "$CLAIM_FILE.prev" | head -1)', expires '$p_exp'."
            [[ "$p_exp" == "$CLAIM_EXPIRES" ]] && echo "  That is the claim this run recorded: somebody released it. The fabric may still be up; the knob bytes to put back are in $STATE."
        else
            echo "  there is no $CLAIM_FILE.prev either: nothing says whose claim it was."
        fi
    fi
    [[ "$claim_overridden" -eq 1 ]] && echo "  $CLAIM_FILE.overrides records an ndt up --force past this run's claim (expires $CLAIM_EXPIRES)."
    echo "  claim owner '$c_owner' (want '$OWNER'), note '$c_note', expires '$c_exp' (now $now; the probe recorded $CLAIM_EXPIRES)"
    echo "  app_package_override '$ov' (want '$PKG')"
    exit 3
fi

stop_recorded

# (r8, N1) With the knob absent outside down-done, a `ndt down` may already have run -- the probe's, a person's,
# or a failed one of this script's own (ndt clears the knob as down's last step, ndt:5605, and an `ndt down` that
# exits 1 after tearing everything down is documented, ndt:5312-5318). Its interfaces are gone then, so
# qdisc_snapshot.sh diff (it diffs `tc qdisc show` of every interface, qdisc_snapshot.sh:24,37-44) always differs
# and would stop at "the fabric is still up". Ask ndt status first, as down_done_fabric_check does: no switches
# and no host/switch process -> the down is done (record it); anything else -> steps 4-5 as before.
SKIP_DOWN=0
if [[ "$PHASE" == down-done ]]; then SKIP_DOWN=1
elif [[ -z "$ov" ]]; then
    st_out="$(NDT_OWNER="$OWNER" "$NDT" status 2>/dev/null)"
    n_bmv2="$(printf '%s\n' "$st_out" | awk '$1 == "bmv2" && $2 == "switches" { print $3; exit }')"
    n_mn="$(printf '%s\n' "$st_out" | awk '$1 == "host/switch" { print $2; exit }')"
    if [[ "$n_bmv2" == 0 && "$n_mn" == 0 ]]; then
        echo "  the override is gone and ndt status shows no fabric: a down already ran; steps 4-5 skipped (their interfaces are gone)"
        state_set phase down-done
        SKIP_DOWN=1
    fi
fi
if [[ "$SKIP_DOWN" -eq 0 ]]; then
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
NDT_OWNER="$OWNER" "$NDT" down; down_rc=$?
# (r8) rc 3 is "this command measured nothing" -- the lab was already down (ndt:5524-5537): the down is done.
if [[ "$down_rc" -eq 3 ]]; then echo "  ndt down exited 3: nothing was up to tear down -- done"; down_rc=0; fi
if [[ "$down_rc" -ne 0 ]]; then
    # (r7) real ndt clears the knob as down's last step even when it exits non-zero (ndt:5233-5246, 5605),
    # so a retry no longer finds the knob: the phase says what the knob can no longer say, as LabRound's does.
    state_set phase down-failed
    echo "STOP: ndt down failed; NOT releasing over a fabric that may still be up."; exit 5
fi
state_set phase down-done
fi   # steps 4-5

# (r7) The claim again, before anything is written back or released: `ndt down` took minutes, and a claim of
# the same owner taken meanwhile must not be released here. (The release follows the knob restore with no
# ndt call between, so one look covers both.)
if [[ "$(claim_get owner)" != "$OWNER" || "$(claim_get expires)" != "$CLAIM_EXPIRES" ]]; then
    echo "STOP: the claim is no longer the one this run recorded (owner '$(claim_get owner)', expires '$(claim_get expires)',"
    echo "      recorded $CLAIM_EXPIRES): knobs and release left to a person. Nothing more written."; exit 3
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
# (r8, N2) `ndt claim` records the round baseline: the host knob's value at that moment (ndt:447-460, 849), and
# `ndt release` refuses while the knob differs from it (ndt:890-903). This script's own re-claim ran while the
# round's values were still in the knobs, so its baseline is the round's value, and step 6 has just put the
# pre-round value back: the refusal would be certain, and the fix it prints (write the baseline value back)
# would undo the restore. So when the claim held is this script's own re-claim (its expires is the one this
# script wrote into the state as recover_claim_expires -- also on a later run, after a step failed), and every
# knob now is its snapshot, release with --force and say why. In every other case the release is plain.
rel_force=()
recover_exp="$(field recover_claim_expires)"
if [[ -n "$recover_exp" && "$recover_exp" == "$(claim_get expires)" ]] && knobs_match_snapshot; then
    echo "  releasing with --force: the claim held is this script's own re-claim, whose round baseline was recorded while"
    echo "  the round's values were still in the knobs; they are back at the pre-round snapshot, which that baseline would refuse."
    rel_force=(--force)
fi
if ! out="$(NDT_OWNER="$OWNER" "$NDT" release ${rel_force[@]+"${rel_force[@]}"} 2>&1)"; then
    echo "$out"
    echo "STOP: ndt release refused (above). The knobs were put back to their pre-round snapshot in step 6: do NOT write"
    echo "      a value ndt prints back into them -- that would undo the restore. The lab is still claimed and may need"
    echo "      a person: read ndt status (never 'git checkout --')."; exit 6
fi
echo "$out"

# 8. what the lab looks like now
NDT_OWNER="$OWNER" "$NDT" status || true
if [[ "$KILL_FAILED" -gt 0 ]]; then
    echo "recover: the lab is put right, but $KILL_FAILED recorded process(es) could not be stopped (kill failed above): rc 7"
    exit 7
fi
echo "recover: done -- read the status above: no bmv2, no heartbeat, no claim."
