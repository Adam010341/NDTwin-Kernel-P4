#!/usr/bin/env bash
# lldp_detection.sh [reps] -- time link-down -> Ryu notices, at both OVS fabric sizes.
#
# [Co-developed with claude code -- Adam]
#
# ## The hypothesis
#
# 46.6 s of the 51.75 s OVS/128 failover is unattributed. Ryu's link discovery
# (ryu/topology/switches.py) deletes a link only after LINK_LLDP_DROP=5 consecutive
# unanswered sends, and its send loop is serialised: `hub.sleep(LLDP_SEND_GUARD)` = 0.05 s
# between ports, over EVERY port including host-facing ones. So one sweep costs
# ports x 0.05 s, and the interval between two sends to the SAME port scales with the port
# count -- which scales with the host count.
#
#   4 hosts   32 inter-switch + 4 host   =  36 ports -> 1.8 s/sweep -> 6 sweeps ~ 10.8 s
#   128 hosts 32 inter-switch + 128 host = 160 ports -> 8.0 s/sweep -> 6 sweeps ~ 48.0 s
#
# Adding the 5 s link_loop granularity, the 3 s debounce and the walk gives 16.3 s and
# 55.7 s against measured 15.70 s and 51.75 s, and a ratio of 3.28x against a measured
# 3.30x. That is a good fit, and a good fit is exactly what this script exists to distrust:
# arithmetic that matches is not the mechanism. This measures the detection term directly
# and separately, so the fit can be confirmed or killed rather than admired.
#
# ## What is measured
#
# t0  netem applied to s1's on-path egress -- the same interface, resolved the same way, as
#     measure_failover.sh, so the number composes with that round's 51.75 s.
# t1  "topology changed" appears in the Ryu log  -> DETECTION
# t2  "route reinstall done" appears            -> detection + debounce + walk
#
# The Ryu log carries no timestamps of its own, so lines are stamped as they arrive.
#
# ## Prediction, written down before running
#
#   4 hosts:    detection ~10.8 s   (ports ~36)
#   128 hosts:  detection ~48.0 s   (ports ~160)
#   ratio:      ~4.4x, and detection should be ~92% of the 128-host outage
#
# If detection comes back flat across the two sizes, the hypothesis is dead and the time is
# somewhere else.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-maindev-0821}"
REPO=/home/adam/Desktop/NDTwin-Kernel
LOG="$REPO/.test_run/logs/ryu.log"
OUT="$REPO/doc/audit/2026-08-21_ryu-topology-scaling/lldp_detection.txt"
REPS="${1:-3}"

# The destination has to put an INTER-SWITCH hop on the path, and which address does that
# depends on the layout. Hosts fill s1..s4 in contiguous blocks, so at 4 hosts h4 is on s4 but
# at 128 hosts 10.0.0.4 is on s1 -- the same switch as h1. The first run of this script used
# 10.0.0.4 for both and the 128-host cell injected into s1-eth6, the ACCESS LINK to h4: no link
# exists there to delete, no alternative path exists to a directly-attached host, and it read
# "NO DETECTION within 180 s" twice. That is a broken probe, not a slow controller.
#
# 10.0.0.33 is the first host on s2 and is what the 2026-08-19 round pinged, so the 128-host
# cell now injects into the same link that round did.
dst_for() { [[ "$1" == 4 ]] && echo 10.0.0.4 || echo 10.0.0.33; }

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "# LLDP link-failure detection time, by fabric size"
say "# date:   $(date -Is)"
say "# commit: $(cd "$REPO" && git rev-parse --short HEAD)"
say "# reps:   $REPS per size"
say "# t0=netem applied  t1=\"topology changed\"  t2=\"route reinstall done\""
say ""

port_count() {
    curl -sf --max-time 5 http://localhost:8080/v1.0/topology/switches \
      | python3 -c 'import json,sys; print(sum(len(s.get("ports",[])) for s in json.load(sys.stdin)))' \
      2>/dev/null || echo "?"
}

# The on-path egress of s1 toward DST, read from the flow table -- a previous reroute moves
# the path, and a hard-coded interface would inject into a link nothing is using, which looks
# exactly like instant recovery.
resolve_iface() {
    local dst="$1" port
    port=$(sudo -n mnexec -a 1 ovs-ofctl dump-flows s1 2>/dev/null \
           | grep -oP "nw_dst=${dst//./\\.} actions=output:\K[0-9]+" | head -1)
    [[ -z "$port" ]] && return 1
    # Assert the port is a switch-to-switch link before injecting into it. An access link has no
    # Link object, so no EventLinkDelete can ever fire and the run silently measures nothing.
    # Ryu's own link list is the authority -- it is what would have to notice.
    #
    # Compared as INTEGERS. The REST API renders port_no as a zero-padded HEX string
    # (port 10 -> "0000000a") while ovs-ofctl prints decimal, so string comparison silently
    # disagrees for every port above 9 -- and the first version of this guard let s1-eth6
    # through while claiming to have checked it.
    # SRCPORT goes on python3, not on curl. `VAR=x cmd1 | cmd2` exports VAR to cmd1 only, so
    # the first version set it on the fetch and the checker died with KeyError -- and because
    # the failure path and the "not an inter-switch link" path shared an exit code, a crashed
    # guard was indistinguishable from a guard that had run and said no.
    curl -sf --max-time 5 http://localhost:8080/v1.0/topology/links \
      | SRCPORT="$port" python3 -c "
import json,os,sys
want=int(os.environ['SRCPORT'])
ls=json.load(sys.stdin)
ok=[l for l in ls if int(l['src']['dpid'],16)==1 and int(l['src']['port_no'],16)==want]
sys.stderr.write('    s1 inter-switch src ports seen by ryu: '
                 + ','.join(sorted({str(int(l['src']['port_no'],16))
                                    for l in ls if int(l['src']['dpid'],16)==1})) + '\n')
sys.exit(0 if ok else 3)" || return 2
    echo "s1-eth${port}"
}

for size in ${SIZES:-4 128}; do
    say "=== ${size} hosts ==="
    ndt down > /tmp/lldp_down_$size.out 2>&1 || { say "  DOWN FAILED"; exit 1; }
    sleep 2
    if ! timeout 600 ndt up ovs "$size" > /tmp/lldp_up_$size.out 2>&1; then
        say "  UP FAILED -- see /tmp/lldp_up_$size.out"
        tail -4 /tmp/lldp_up_$size.out | sed 's/^/    /' | tee -a "$OUT"
        continue
    fi

    # Identify the fabric independently of what ndt reported: 10 switches means 32
    # inter-switch ports, so host ports = veth count - 32.
    ifaces=$(ls /sys/class/net | grep -c '^s[0-9]*-eth')
    say "  fabric: $((ifaces - 32)) hosts, ${ifaces} switch ports (veth count)"
    say "  ryu sees $(port_count) ports"
    say ""

    dst=$(dst_for "$size")
    say "  pinging $dst (must be off-switch so the path crosses an inter-switch link)"
    for rep in $(seq 1 "$REPS"); do
        flowline=$(sudo -n mnexec -a 1 ovs-ofctl dump-flows s1 2>/dev/null \
                   | grep -F "nw_dst=$dst" | head -1 | sed 's/^ *//')
        iface=$(resolve_iface "$dst" 2>/tmp/lldp_guard.err); rc=$?
        say "  rep $rep  s1 rule toward $dst: ${flowline:-<none>}"
        [[ -s /tmp/lldp_guard.err ]] && cat /tmp/lldp_guard.err | tee -a "$OUT"
        if (( rc == 2 )); then
            say "  rep $rep: that port is NOT an inter-switch link -- refusing to inject"
            continue
        elif (( rc != 0 )); then
            say "  rep $rep: could not resolve on-path iface toward $dst, skipping"
            continue
        fi

        # Match measure_failover.sh: netem goes under the htb class where the topology shapes.
        if sudo -n tc qdisc show dev "$iface" 2>/dev/null | head -1 | grep -q htb; then
            cls=$(sudo -n mnexec -a 1 tc class show dev "$iface" 2>/dev/null \
                  | grep -oP 'class htb \K[0-9]+:[0-9]+' | head -1)
            add=(sudo -n tc qdisc add dev "$iface" parent "$cls" netem loss 100%)
            del=(sudo -n tc qdisc del dev "$iface" parent "$cls")
        else
            add=(sudo -n tc qdisc add dev "$iface" root netem loss 100%)
            del=(sudo -n tc qdisc del dev "$iface" root)
        fi

        stamped=$(mktemp -t lldp_tail.XXXXXX)
        stdbuf -oL tail -F -n 0 "$LOG" 2>/dev/null \
          | stdbuf -oL grep --line-buffered -E "topology changed|route reinstall done" \
          | while IFS= read -r line; do printf '%s %s\n' "$(date +%s.%N)" "$line"; done \
          > "$stamped" &
        tailpid=$!
        sleep 0.5

        # Wait for the control plane to go quiet before injecting. Without this the first run
        # read detection=13.57 s but "detect+debounce+walk"=0.95 s -- shorter than the thing it
        # contains -- because a route reinstall left over from the fabric coming up finished
        # just after t0 and the grep took the first match it saw. A stale line landing a moment
        # EARLIER would have been much worse: it would have read as a fast detection and looked
        # entirely plausible.
        # Counted, not truncated: `tail` holds the file open at its own offset, so emptying it
        # underneath would leave a sparse file padded with NULs rather than a clean slate.
        quiet_since=$(date +%s); last_n=$(wc -l < "$stamped")
        while (( $(date +%s) - quiet_since < 12 )); do
            n=$(wc -l < "$stamped")
            if (( n != last_n )); then last_n=$n; quiet_since=$(date +%s); fi
            sleep 1
        done

        t0=$(date +%s.%N)
        "${add[@]}" 2>/dev/null
        # An injection that silently no-ops produces a beautiful "instant recovery"; assert it.
        if ! sudo -n tc qdisc show dev "$iface" 2>/dev/null | grep -q netem; then
            say "  rep $rep: NETEM NOT PRESENT after add -- discarding"
            kill "$tailpid" 2>/dev/null; rm -f "$stamped"; continue
        fi

        # Belt and braces on top of the quiet window: take only stamps strictly after t0, so a
        # line that slipped in between the last truncation and the injection cannot be read as
        # an instant detection.
        after_t0() { awk -v t0="$t0" -v pat="$1" '$0 ~ pat && $1 > t0 {print $1; exit}' "$stamped"; }

        deadline=$(( $(date +%s) + 180 ))
        t1=""; t2=""
        while (( $(date +%s) < deadline )); do
            [[ -z "$t1" ]] && t1=$(after_t0 "topology changed")
            [[ -z "$t2" ]] && t2=$(after_t0 "route reinstall done")
            [[ -n "$t1" && -n "$t2" ]] && break
            sleep 0.2
        done

        kill "$tailpid" 2>/dev/null
        pkill -P "$tailpid" 2>/dev/null
        "${del[@]}" 2>/dev/null

        if [[ -z "$t1" ]]; then
            say "  rep $rep  iface=$iface  NO DETECTION within 180 s"
        else
            det=$(python3 -c "print(f'{$t1-$t0:.2f}')")
            tot=$([[ -n "$t2" ]] && python3 -c "print(f'{$t2-$t0:.2f}')" || echo "n/a")
            say "  rep $rep  iface=$iface  detection=${det}s  detect+debounce+walk=${tot}s"
        fi
        rm -f "$stamped"
        # Let the restored link be rediscovered and the routes settle before the next rep.
        sleep $(( size == 4 ? 20 : 45 ))
    done
    say ""
done

ndt down >/dev/null 2>&1
say "done -> $OUT"
