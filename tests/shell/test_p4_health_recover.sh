#!/usr/bin/env bash
#
# tools/p4_health/recover.sh, offline: every command it would run is a stub that logs its argv.
#
# [Co-developed with claude code -- Adam]
#
# Checks the order of the recovery (DESIGN 4.5), the refusals (probe alive, not our lab, qdisc
# drift, a failed down), section 12 item 11's re-claim, and that the knobs come back as bytes.
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

setup() {  # setup <case> -- a fresh run dir, knobs, claim, override and stubs
    local d="$WORK/$1"; mkdir -p "$d/run" "$d/knobs" "$d/test_run" "$d/bin"
    : > "$d/calls"
    for s in ndt qdisc sudo kill; do
        cat > "$d/bin/$s" <<STUB
#!/usr/bin/env bash
echo "$s \$*" >> "$d/calls"
rc_file="$d/rc.$s.\${1:-}"
[[ -f "\$rc_file" ]] && exit "\$(cat "\$rc_file")"
exit 0
STUB
        chmod +x "$d/bin/$s"
    done
    printf '6\n' > "$d/knobs/host_count_override"
    printf '%s\n' "$d/pkgA" > "$d/knobs/app_package_override"
    sleep 0 & local dead=$!; wait "$dead"
    printf 'owner=p4h-test\nexpires=%s\nnote=p4-health run-x A state=%s\n' "$(( $(date +%s) + 600 ))" \
        "$d/run/LAB_STATE.json" > "$d/test_run/lab.claim"
    python3 - "$d" "$dead" <<'PY'
import base64, json, sys
d, pid = sys.argv[1], int(sys.argv[2])
st = {"pid": pid, "owner": "p4h-test", "run": "run-x", "bring_up": "A", "package": d + "/pkgA",
      "phase": "cells", "netem": ["s2-eth3"], "sniffers": [555], "controllers": [666],
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
        bash "$SUBJECT" "$d/run" > "$d/out" 2>&1
    echo $?
}

echo "subject: $SUBJECT"
echo "--- the whole recovery, in order"
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

echo "--- not our lab"
d="$(setup foreign)"; sed -i 's/^owner=.*/owner=somebody-else/' "$d/test_run/lab.claim"; rc="$(run "$d")"
check "rc 3" [ "$rc" -eq 3 ]
check "nothing was run" [ ! -s "$d/calls" ]
check "the knob was not written" [ "$(cat "$d/knobs/host_count_override")" == "6" ]
d="$(setup otherpkg)"; printf '/elsewhere\n' > "$d/knobs/app_package_override"; rc="$(run "$d")"
check "another package in the override: rc 3, nothing run" [ "$rc" -eq 3 -a ! -s "$d/calls" ]

echo "--- the probe is still alive"
d="$(setup alive)"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['pid']=int(sys.argv[2]); json.dump(s,open(p,'w'))" \
    "$d/run/LAB_STATE.json" "$$"
rc="$(run "$d")"
check "rc 3 and nothing run" [ "$rc" -eq 3 -a ! -s "$d/calls" ]

echo "--- section 12 item 11: an expired claim, the override still ours"
d="$(setup expired)"; sed -i "s/^expires=.*/expires=$(( $(date +%s) - 60 ))/" "$d/test_run/lab.claim"; rc="$(run "$d")"
check "rc 0" [ "$rc" -eq 0 ]
check "re-claimed first, as the same owner's run" [ "$(head -1 "$d/calls")" == "ndt claim 30 p4-health run-x A recover state=$d/run/LAB_STATE.json" ]
check "and then the whole recovery" [ "$(tail -1 "$d/calls")" == "ndt status" ]

echo "--- the qdisc tree drifted"
d="$(setup drift)"; echo 1 > "$d/rc.qdisc.diff"; rc="$(run "$d")"
check "rc 4" [ "$rc" -eq 4 ]
check "no ndt down after the drift" bash -c "! grep -q '^ndt down' '$d/calls'"

echo "--- ndt down failed"
d="$(setup downfail)"; echo 1 > "$d/rc.ndt.down"; rc="$(run "$d")"
check "rc 5" [ "$rc" -eq 5 ]
check "no release" bash -c "! grep -q '^ndt release' '$d/calls'"
check "knob untouched" [ "$(cat "$d/knobs/host_count_override")" == "6" ]

echo
echo "Ran $CHECKS checks, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
