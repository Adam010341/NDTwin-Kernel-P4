#!/usr/bin/env bash
#
# Bring the NDTwin stack up and down in the right order, and wait for it to converge.
#
# Why this exists: the components have a strict dependency order, and starting the next
# one too early produces failures that look like bugs. Step 3 -> 4 in particular MUST
# wait -- a lot of "it looks broken" is really "the topology has not converged yet".
#
#   1. control plane   Ryu (OVS) or the P4 proxy agent (P4)
#   2. data plane      Mininet topology
#   3. kernel          ndtwin_kernel
#   4. readers         Visualizer / NSR / Web-GUI
#   5. traffic         NTG
#   6. apps            Energy-Saving / Traffic-Engineering  (these change the network)
#
# This script covers steps 1-3 plus convergence, because those are the ones that must be
# scripted to be reproducible. Steps 4-6 are launched per test scenario.
#
# Mininet needs root, so `up` re-execs the topology under sudo. Everything else runs as
# the invoking user.
#
# Usage:
#   ./stack.sh up ovs           # Ryu   + OVS Mininet   + kernel
#   ./stack.sh up p4            # proxy + bmv2 Mininet  + kernel
#   ./stack.sh wait             # block until the kernel reports a converged topology
#   ./stack.sh status
#   ./stack.sh down
#   ./stack.sh logs
#
# [Co-developed with claude code -- Adam]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=components.env
source "$HERE/components.env"
# The ports that block a bring-up, with owner and consequence per row. Same table `ndt` reads
# -- the point of it being a file. [Co-developed with claude code -- Adam]
# shellcheck source=ports.sh
source "$HERE/ports.sh"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; D=''; N=''
fi

mkdir -p "$LOG_DIR" "$PID_DIR"
MODE_FILE="$RUN_DIR/mode"

info() { echo "${D}$*${N}"; }

# The mininet: bash tags, one per host/switch shell. A seam so the wedge guard is testable:
# tests override this to simulate a live or absent Mininet.
#
# [Co-developed with claude code -- Adam]
# 🔴 2026-09-11 (FIX-NDT-4 #16, G-inst-2). This was `ps -eo args | awk '$NF ~ /^mininet:/{c++}'`,
# and the problem is where the pattern LIVES, not the arithmetic: it travels as that awk's own
# argv -- and as the argv of the shell that invoked it -- so it is in the process table for the
# duration of the count. Measured 2026-09-11 on this machine: a substring reader of `ps -eo args=`
# counted 4 `mininet:` with that awk running and 3 without. This function's own last-field rule
# happens not to count those lines (awk's last field is `c+0}`), and "happens not to" is not a
# property to build a fabric-liveness check on: twin_audit.py:153 reads the same signal, the
# wedge guard below branches on this number, and `mn -c` SIGKILLs anything whose command line
# carries the tag. The reading is unchanged (LAST argv field, prefix `mininet:`); it is now done
# in this shell, which puts nothing new in the table.
#
# There is no pidfile to read instead: Mininet is started by hand in another terminal (see
# prompt_for_mininet below), so nothing here ever recorded its pids. The process table is the
# only channel there is, and what this removes is the instrument's own footprint in it.
#
# Split in two for the reason run_layers.sh's fabric_hosts_in gives: the counting is then
# testable against a captured `ps` shape, without a fabric. The tag is assembled at run time
# for the `mn -c` reason above.
mininet_procs_in() {
    local tag="mininet" n=0 line last
    tag="${tag}:"
    while read -r line; do
        last="${line##* }"
        [[ "$last" == "$tag"* ]] && n=$(( n + 1 ))
    done
    echo "$n"
}
count_mininet_procs() { mininet_procs_in < <(ps -eo args= 2>/dev/null); }
ok()   { echo "${G}$*${N}"; }
warn() { echo "${Y}$*${N}"; }
err()  { echo "${R}$*${N}" >&2; }

# prompt_for_mininet <script> -- Mininet needs root and drops into an interactive CLI, so it
# cannot be started from here; ask the operator to run it in another terminal.
prompt_for_mininet() {
    local script="$1"
    if [[ ! -f "$script" ]]; then err "  topology script missing: $script"; return 1; fi
    warn "  Mininet is interactive (it drops into a CLI) and needs root."
    warn "  Start it in a separate terminal:"
    echo
    echo "      sudo python3 $script"
    echo
    read -r -p "  Press Enter once Mininet is up (or Ctrl-C to abort)... " _ || true
}

# countdown <seconds> <what> -- a visible wait, so it does not look like a hang.
countdown() {
    local left="${1:-}" what="$2"
    # Must be a plain integer. `sleep` accepts suffixes and decimals ("60s", "0.5") but bash
    # arithmetic does not, and (( left > 0 )) on such a value fails the *condition* rather than
    # the script -- the loop body never runs, "done" prints, and 0 is returned. That silently
    # skips the whole wait and reports success, which is the failure this wait exists to prevent.
    if [[ ! "$left" =~ ^[0-9]+$ ]]; then
        err "  invalid wait value: '${left}' (want a plain integer number of seconds)"
        return 1
    fi
    if (( left == 0 )); then
        info "  $what: skipped (wait set to 0)"
        return 0
    fi
    # No \r animation when redirected: it just clutters a log file. Matches the [[ -t 1 ]]
    # colour detection above.
    if [[ ! -t 1 ]]; then
        info "  $what (${left}s)"
        sleep "$left"
        return 0
    fi
    while (( left > 0 )); do
        printf '\r  %s: %3ds remaining ' "$what" "$left"
        sleep 1
        left=$(( left - 1 ))
    done
    # Pad over the longest transient suffix (": NNNs remaining ") so none of it is left behind.
    printf '\r  %s: done%*s\n' "$what" 20 ''
}

# --- convergence ------------------------------------------------------------------

# expected_counts <mode> <topo>  ->  "<a> <b>" on stdout
# What the control plane must report once discovery has finished, derived from the topology
# file rather than hardcoded. The path goes in as argv, never interpolated into the source.
expected_counts() {
    local mode="$1" topo="$2"
    python3 -c '
import json, sys
mode, path = sys.argv[1], sys.argv[2]
t = json.load(open(path))
switches = {n["dpid"] for n in t["nodes"] if n.get("vertex_type") == 0}
if mode == "ovs":
    # Ryu reports inter-switch links only, one entry per direction. Host links never appear,
    # and neither do the dpid-0 placeholder endpoints hosts carry.
    links = sum(1 for e in t["edges"]
                if e["src_dpid"] in switches and e["dst_dpid"] in switches
                and e["src_dpid"] and e["dst_dpid"])
    print(len(switches), links)
else:
    # [Co-developed with claude code -- Adam]
    # all_destination_paths is a LIST OF PATHS, one per ordered host pair -- not a map keyed by
    # node. This used to expect len(switches) + hosts, which is a different quantity entirely
    # (14 vs 12 on the 10-switch/4-host topology), so the gate could never be satisfied and
    # every P4 start burned the whole timeout before proceeding with a warning.
    hosts = sum(1 for n in t["nodes"] if n.get("vertex_type") == 1)
    print(hosts * (hosts - 1) if hosts > 1 else 0, 0)
' "$mode" "$topo" 2>/dev/null
}

# observed_counts <mode>  ->  "<a> <b>" on stdout, empty if the control plane cannot be read
observed_counts() {
    local mode="$1"
    if [[ "$mode" == "ovs" ]]; then
        local sw links
        sw="$(curl -s --max-time 3 "$RYU_URL/v1.0/topology/switches" \
              | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)"
        links="$(curl -s --max-time 3 "$RYU_URL/v1.0/topology/links" \
                 | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)"
        [[ -n "$sw" && -n "$links" ]] && echo "$sw $links"
    else
        # [Co-developed with claude code -- Adam]
        # Count the paths inside the envelope. `len()` on the whole response counted the
        # envelope's own keys -- {"status": ..., "all_destination_paths": [...]} -- and so
        # reported a constant 2 no matter how discovery was going.
        local paths
        paths="$(curl -s --max-time 3 "$P4_PROXY_URL/ryu_server/all_destination_paths" \
                 | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(len(d["all_destination_paths"] if isinstance(d, dict) else d))' 2>/dev/null)"
        [[ -n "$paths" ]] && echo "$paths 0"
    fi
}

# paths_installed <mode>  ->  0 when the controller has installed all-destination paths
#
# The milestone the user manual actually names ("you will see the 'all-destination paths
# installed' message"), and a different, much later event than LLDP link discovery:
#
#   intelligent_router.py:282   if is_mininet: hub.sleep(60)
#   intelligent_router.py:284   install_all_pair_paths(...)   <- fills all_destination_paths
#
# That sleep was a hard-coded 60s until 2026-08-21; it is now NDTWIN_RYU_SETTLE_S, default 10.
# Either way it dominates OVS start-up while link discovery finishes in a couple of seconds, so
# gating on the link counts alone releases the kernel early -- by ~58s then, ~8s now. The gap
# shrank but did not close, which is why both conditions below are still required. `all_destination_paths` starts as [] (line 74) and is only
# assigned in install_all_pair_paths (line 510), so a non-empty list is a direct signal that
# needs no log scraping.
#
# P4 mode needs no separate check here: observed_counts already counts the proxy's installed
# destination paths, so that count *is* this milestone. (An earlier version of this comment
# claimed P4 was correct while observed_counts was in fact counting the response envelope's two
# keys -- see the note there. The claim is true now; it was not then.)
paths_installed() {
    local mode="$1"
    [[ "$mode" != "ovs" ]] && return 0
    local n
    n="$(curl -s --max-time 3 "$RYU_URL/ryu_server/all_destination_paths" \
         | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["all_destination_paths"]))' \
         2>/dev/null)"
    [[ -n "$n" && "$n" -gt 0 ]]
}

# await_convergence <mode> <topo> <timeout>
#
# Polls the control plane until it reports the whole topology *and* has installed the
# all-destination paths, rather than sleeping a fixed 60s. The kernel pulls topology and
# destination paths exactly once at startup with no retry, so what matters is not elapsed time
# but that discovery has actually finished.
#
# Both conditions are required because they are different events with very different timings:
# link discovery is LLDP between switches (seconds), while path installation sits behind the
# Ryu app's settle (NDTWIN_RYU_SETTLE_S, default 10s). See paths_installed().
#
# Falls back to sleeping the whole timeout if the endpoint cannot be read at all: proceeding
# immediately on an unreadable control plane would reintroduce the race this replaces.
await_convergence() {
    local mode="$1" topo="$2" timeout="$3"
    local want; want="$(expected_counts "$mode" "$topo")"
    if [[ -z "$want" ]]; then
        warn "  cannot read expected counts from $topo; falling back to a fixed wait"
        countdown "$timeout" "waiting for link discovery to converge"
        return $?
    fi

    local want_a="${want% *}" want_b="${want#* }"
    if [[ "$mode" == "ovs" ]]; then
        info "  waiting for ${want_a} switches, ${want_b} links, and all-destination paths"
        info "  Ryu settles for ${NDTWIN_RYU_SETTLE_S:-10}s before installing paths (NDTWIN_RYU_SETTLE_S)"
    else
        info "  waiting for link discovery: want ${want_a} destination paths"
    fi

    local start; start=$(date +%s)
    local last="" got probed=0 paths=0
    while true; do
        got="$(observed_counts "$mode")"
        [[ -n "$got" ]] && probed=1
        # Only re-probe until it flips: installation does not un-happen, and the endpoint logs
        # a line on every request.
        (( paths == 0 )) && { paths_installed "$mode" && paths=1; }
        if [[ -n "$got" && "$got $paths" != "$last" ]]; then
            local a="${got% *}" b="${got#* }"
            if [[ "$mode" == "ovs" ]]; then
                printf '\r    switches=%s links=%s paths=%s%*s' \
                       "$a" "$b" "$( ((paths)) && echo installed || echo pending )" 10 ''
            else
                printf '\r    paths=%s%*s' "$a" 10 ''
            fi
            last="$got $paths"
        fi
        if [[ "$got" == "$want" ]] && (( paths )); then
            # Matching counts mean discovery finished; give it a moment to stop moving.
            sleep 2
            # Blank the whole line, not just return to column 0: the progress line is longer
            # than the message that replaces it, so its tail would survive as visual garbage
            # ("converged after 2s links=32").
            printf '\r%*s\r' 44 ''
            ok "  converged after $(( $(date +%s) - start ))s"
            return 0
        fi
        if (( $(date +%s) - start >= timeout )); then
            # Blank the whole line, not just return to column 0: the progress line is longer
            # than the message that replaces it, so its tail would survive as visual garbage
            # ("converged after 2s links=32").
            printf '\r%*s\r' 44 ''
            if (( probed == 0 )); then
                warn "  control plane never answered; slept ${timeout}s without confirming"
            else
                warn "  did not converge within ${timeout}s (last: ${last:-none}, want: $want 1)"
                (( paths == 0 )) && warn \
                  "  all-destination paths were never installed; check $LOG_DIR/ryu.log"
                warn "  the kernel pulls once and never retries, so its graph will stay"
                warn "  incomplete -- starting it anyway so the state can be inspected"
            fi
            return 0
        fi
        sleep 2
    done
}

# --- process helpers -------------------------------------------------------------

# The command a running service was started with, recorded beside its pidfile.
#
# [Co-developed with claude code -- Adam]
# Recorded rather than read back from /proc, because /proc shows the process that ended up
# running and every service here is launched through a wrapper that execs away:
#
#     want (argv given to start_bg):  env PYTHONPATH=... bash -c "cd ... && .../python main.py"
#     /proc/<pid>/cmdline:            .../python proxy_agent/main.py
#
# Those never match, so comparing against /proc restarts every service on every `up` while
# reporting it as a changed command -- measured, first run of this check. A sidecar file
# compares like with like: the same string is written at start and read at reuse.
CMD_SUFFIX=".cmd"

recorded_cmd() { cat "$PID_DIR/$1$CMD_SUFFIX" 2>/dev/null; }

# The wrapper that records how a component ended. See supervise.sh; KNOWN-ISSUES B-5.
# [Co-developed with claude code -- Adam]
SUPERVISE="$HERE/supervise.sh"

# report_exit <name> -- says how a component ended, from the file supervise.sh left behind.
# Silent when there is nothing to report, loud when the ending was an abort: an exit status that
# is only in a file nobody opens is barely more observable than no exit status at all.
#
# [Co-developed with claude code -- Adam]
# Reporting only. It deliberately does NOT change any exit code, because 143 (SIGTERM's default
# action) is what the kernel returns on the *normal* `ndt down` path today -- treating non-zero
# as failure would turn every teardown red tomorrow morning. Whether a crash on shutdown should
# fail the command is a decision for Adam, not a side effect of making it visible.
# fatal_exit_status <wait-status> -- true when it means the process died of a FAULT.
#
# [Co-developed with claude code -- Adam]
# The line between "it was stopped" and "it crashed", drawn once so both report_exit and
# cmd_down use the same one:
#
#   132 SIGILL   134 SIGABRT   135 SIGBUS   136 SIGFPE   137 SIGKILL   139 SIGSEGV
#
# 143 (SIGTERM) is deliberately NOT here: it is what `ndt down` produces on every healthy
# kernel today, because main handles SIGINT only and TERM's default action kills the process.
# Calling it a failure would turn every teardown red for a defect nobody has. 130 (SIGINT) is
# out for the same reason -- it is how an operator stops the kernel by hand.
#
# 137 is in the list on purpose: systemd-oomd on this laptop kills builds and applications
# routinely, a killed process prints nothing about itself, and an OOM-killed kernel would
# otherwise be indistinguishable from a clean stop.
fatal_exit_status() {
    case "$1" in
        132|134|135|136|137|139) return 0 ;;
        *) return 1 ;;
    esac
}

# Set by report_exit, read by cmd_down. Names, not a count, so the message can say which.
STACK_FATAL_ENDINGS=""

report_exit() {
    # Two statements for the reason spelled out at the top of stop_one: a second assignment on a
    # `local` line cannot read the first one.
    local name="$1"
    local f="$PID_DIR/$name.exit"
    [[ -f "$f" ]] || return 0
    local status reason
    status="$(sed -n 's/^status=//p' "$f" 2>/dev/null)"
    reason="$(sed -n 's/^reason=//p' "$f" 2>/dev/null)"
    [[ -n "$status" ]] || return 0
    if fatal_exit_status "$status"; then
        err "  🔴 $name did not stop cleanly: $reason"
        err "     evidence: $f, and the tail of $LOG_DIR/$name.log"
        STACK_FATAL_ENDINGS="${STACK_FATAL_ENDINGS:+$STACK_FATAL_ENDINGS }$name($status)"
        # Delivered once. The durable copy is the appended line in $name.exit.log, which no
        # start and no stop ever rewrites; leaving this file in place would make every later
        # `down` fail again for a crash that has already been reported and acted on.
        rm -f "$f"
    elif [[ "$status" == "0" ]]; then
        info "  $name exit status 0 ($reason)"
    else
        warn "  $name exit status $status ($reason)"
    fi
}

# When a pid started, as an epoch second. Empty if it cannot be determined.
#
# [Co-developed with claude code -- Adam]
# The one property that separates "the process we started" from "a different process that
# happens to hold the same number now": a recycled pid necessarily started AFTER we wrote the
# pidfile. comm and argv cannot do this -- every service here is launched through a wrapper
# that execs away, so what /proc shows never matches what was asked for.
#
# Field 22 of /proc/<pid>/stat is starttime in clock ticks since boot. comm (field 2) may
# contain spaces and parentheses, so everything up to the last ')' is dropped first; the
# remainder starts at field 3, which puts starttime at $20.
proc_start_epoch() {
    local pid="$1" btime hz ticks
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    btime="$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)"
    hz="$(getconf CLK_TCK 2>/dev/null)"; [[ "$hz" =~ ^[0-9]+$ ]] || hz=100
    ticks="$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')"
    [[ -n "$btime" && "$ticks" =~ ^[0-9]+$ ]] || return 1
    echo $(( btime + ticks / hz ))
}

# Extra identity for services whose behaviour is decided by something that is NOT on their
# command line. Set by the caller immediately before start_bg; recorded alongside argv and
# compared with it.
#
# [Co-developed with claude code -- Adam]
# The P4 proxy takes no arguments at all: it reads host_count_override at import and builds its
# host table from that. So `ndt up` then `ndt up 4` produced two proxies whose argv were
# identical while their views of the network were not, and the second run reused a proxy that
# still believed in 128 hosts. Measured: 4-host fabric, 4-host kernel model, proxy serving 3968
# destination paths and the kernel reporting 0 of 10 switches up. Comparing argv cannot see
# this; the fingerprint can.
START_BG_IDENTITY="${START_BG_IDENTITY:-}"

# rotate_log <path> -- move it aside under its own start time, and keep the newest N.
#
# [Co-developed with claude code -- Adam]
# 09-05 night round, O-4. Two generations (.prev, .prev2) is a depth, and a depth is only ever
# right for a fixed number of restarts. The evening this was written, R0's first arm produced
# the kernel.log that five fix tickets (W1/W4/W5/W6/W7) were judged on; nothing copied it, and
# within twenty minutes it was the .prev -- one more `ndt up` from being gone. It was rescued by
# hand at 15:53. Later the same evening the R4 arm wrote 151557 lines / 2.78 MB in eleven
# minutes, so a single rotation would have buried the whole load test.
#
# The second half of that finding is why it kept happening: with no up.target, `ndt status`
# advised "bring the lab up from this checkout first: ndt up <target>" (I-1), and following that
# advice is what rotated the log. The instrument recommended the action that destroyed the
# evidence. I-1 is fixed separately; this makes the destruction bounded rather than immediate.
#
# 🔴 STAMPED, not numbered. `.prev`/`.prev2` renames every generation on every restart, so a
# path written down in a report ("the failure is in kernel.log.prev") means something different
# an hour later. A start-time suffix is stable for the life of the file: cite it once and the
# citation stays true. It also makes the pruning order the era order without consulting mtime,
# which a grep, a copy or an editor can move.
#
# NDT_LOG_KEEP overrides the depth. A run that is about to produce evidence can raise it; a
# machine short of disk can lower it. It cannot be lowered to zero -- the whole point is that
# one generation was never enough.
#
# 🔴 NOTHING ELSE DELETES THESE. `ndt clean` is the teardown ASSERTION (bmv2 count, host/switch
# count, topo session, manifest, ports) and touches no file under .test_run/logs/; `ndt down
# --deep` adds only a port sweep. That was already true before this change and is left true on
# purpose: a teardown command that silently reaped the previous run's evidence would be O-4 with
# a different trigger. Pruning happens HERE, at rotation, where a new generation is being
# created to replace it -- and only ever on the stamped generations this function writes. Any
# pre-existing .prev/.prev2 is left alone rather than swept up, because deleting a file this
# scheme did not create is not this function's decision to make.
rotate_log() {
    local log="$1" keep stamp n=0 old
    keep="${NDT_LOG_KEEP:-5}"
    [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 1 )) || keep=5
    stamp="$(date +%Y%m%d-%H%M%S)"
    # Two starts inside the same second must not overwrite each other's generation.
    while [[ -e "$log.$stamp" ]]; do n=$(( n + 1 )); stamp="$(date +%Y%m%d-%H%M%S)-$n"; done
    mv -f "$log" "$log.$stamp" || return 1
    while IFS= read -r old; do
        [[ -n "$old" ]] && rm -f "$old"
    done < <(ls -1 "$log".[0-9]* 2>/dev/null | LC_ALL=C sort -r | tail -n +$(( keep + 1 )))
    return 0
}

# start_bg <name> <logfile> <command...>
start_bg() {
    local name="$1" log="$2"; shift 2
    if is_running "$name"; then
        # [Co-developed with claude code -- Adam]
        # Reuse only what was started with the SAME command. is_running answers "a pid is
        # registered under this name and it is alive" -- not "it is the thing you are asking
        # for". It checks no mode, no topology, not even that the process is the right program.
        #
        # So switching data planes silently kept the previous plane's kernel: `ndt up ovs` then
        # `ndt up` left a kernel serving the P4 fabric with `--topology ...Mininet_10Switches`
        # and pointing at a Ryu that had already been stopped. Nothing downstream could catch
        # it either -- the OVS and P4 128-host models both declare 10 switches, 128 hosts and
        # 288 edges, so "model matches fabric" was satisfied by the wrong model.
        #
        # Comparing argv is enough to separate every case that matters here, because the
        # topology path and the mode are both on the command line.
        local want have
        want="$(printf '%s\n' "$@"; [[ -n "$START_BG_IDENTITY" ]] && printf '%s\n' "$START_BG_IDENTITY")"
        have="$(recorded_cmd "$name")"
        if [[ -n "$have" && "$have" == "$want" ]]; then
            info "  $name already running (pid $(cat "$PID_DIR/$name.pid"), same command)"
            return 0
        fi
        if [[ -z "$have" ]]; then
            warn "  $name is running (pid $(cat "$PID_DIR/$name.pid")) but was started before this"
            warn "    check existed, so what it is serving cannot be verified; restarting it."
        else
            warn "  $name is running (pid $(cat "$PID_DIR/$name.pid")) with a DIFFERENT command;"
            warn "    restarting it, because reusing it would serve the previous run's topology."
            warn "    was:  $(printf '%s' "$have" | tr '\n' ' ')"
            warn "    want: $(printf '%s' "$want" | tr '\n' ' ')"
        fi
        stop_one "$name"
    fi
    # History, one file per era: '>' alone erased the previous era's log at every restart,
    # which is how the whole P4-era kernel.log vanished during the 2026-08-15 overnight audit
    # (the OVS restart truncated it; the era had to be reconstructed from the proxy's side).
    # Rotating keeps each file single-era and the disk bounded. [Co-developed with claude code -- Adam]
    #
    # Depth was 2 (.prev/.prev2), chosen for "restart, it recurred, restart again" -- the
    # sequence KNOWN-ISSUES A-5 names and A-2's workaround produces. That is the right shape
    # for a debugging loop and the wrong one for a night of experiments: on 2026-09-05 seven
    # `ndt up`s ran in this checkout inside three hours, and the log five fix tickets were
    # judged on survived only because someone copied it by hand (O-4). See rotate_log.
    if [[ -s "$log" ]]; then
        rotate_log "$log"
    fi
    # [Co-developed with claude code -- Adam]
    # KNOWN-ISSUES B-5. Launched through supervise.sh so that HOW the component ended is written
    # down. Nothing here waited for these processes and nothing recorded their exit status, so a
    # component that aborted and a component that stopped cleanly left the same evidence: a pid
    # that is no longer there. The kernel had been dying of SIGABRT on every Ctrl-C shutdown, and
    # no log in this repository could have distinguished that from a clean stop.
    #
    # The recorded pid is still the supervisor -- it is the process-group leader, which is what
    # stop_one signals with `kill -TERM -$pid` and what port_owner_verdict compares pgids against,
    # so both keep working unchanged. The pid of the process actually doing the work is written
    # separately, to $name.child.pid.
    #
    # A missing supervisor is a warning, not a refusal: losing the exit status is worse than
    # nothing recorded it before, but it is much better than a stack that will not come up. The
    # warning names exactly what is lost.
    rm -f "$PID_DIR/$name.exit" "$PID_DIR/$name.child.pid"
    if [[ -x "$SUPERVISE" ]]; then
        setsid "$SUPERVISE" "$PID_DIR/$name" "$@" >"$log" 2>&1 &
    else
        warn "  $SUPERVISE is missing or not executable; starting $name unsupervised."
        warn "    Its exit status will NOT be recorded, so an abort on shutdown will look"
        warn "    exactly like a clean stop."
        setsid "$@" >"$log" 2>&1 &
    fi
    echo $! >"$PID_DIR/$name.pid"
    { printf '%s\n' "$@"; [[ -n "$START_BG_IDENTITY" ]] && printf '%s\n' "$START_BG_IDENTITY"; } \
        >"$PID_DIR/$name$CMD_SUFFIX"
    info "  started $name (pid $!) -> $log"
}

is_running() {
    local pidfile="$PID_DIR/$1.pid"
    [[ -f "$pidfile" ]] || return 1
    local pid; pid="$(cat "$pidfile")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_one() {
    # [Co-developed with claude code -- Adam]
    # Two statements, not one. `local name="$1" pidfile="$PID_DIR/$name.pid"` expands BOTH
    # right-hand sides before the local builtin runs, so `$name` there is whatever `name` held in
    # the CALLER, never the argument on this line. It has always worked only by coincidence: both
    # call sites happen to have a `name` in scope holding the same value (cmd_down's loop
    # variable, start_bg's local), so the wrong reading and the right one agreed. Called from
    # anywhere else it either dies under `set -u` -- which is how this was found, from a test --
    # or, with some other `name` in scope, quietly stops a DIFFERENT component while reporting
    # the one it was asked for.
    local name="$1"
    local pidfile="$PID_DIR/$name.pid"
    [[ -f "$pidfile" ]] || return 0

    # Refuse to follow a symlink: with a predictable path an attacker could point the
    # pidfile at something else entirely.
    if [[ -L "$pidfile" ]]; then
        err "  $pidfile is a symlink; refusing to read it"
        return 1
    fi

    local pid; pid="$(cat "$pidfile")"

    # Validate before interpolating into kill. Two real hazards:
    #   * a pidfile containing "1" makes `kill -TERM -1` -- which signals EVERY process the
    #     user is allowed to signal, i.e. their whole session, not just init
    #   * anything non-numeric gets interpolated into the command as-is
    # Require a plain integer of at least 2, since 0 and 1 both have special meanings for
    # kill and no legitimate child of this script can have them.
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -lt 2 ]]; then
        err "  $pidfile does not contain a usable pid (${pid:-empty}); not killing anything"
        rm -f "$pidfile" "$PID_DIR/$name$CMD_SUFFIX"
        return 1
    fi

    # [Co-developed with claude code -- Adam]
    # Prove the pid is still ours before signalling it. Measured 2026-08-21: an unrelated pid
    # written into kernel.pid was killed -- and it is `kill -TERM -$pid`, the whole process
    # GROUP -- after which this reported "stopped kernel", the teardown assertion went five for
    # five, and the exit code was 0. Three wrong answers, all silent.
    #
    # A stale pidfile is not hypothetical: one survives every abnormal exit, and one survived a
    # reboot on this machine while `ndt clean` called the result clean.
    local pf_mtime p_start
    pf_mtime="$(stat -c %Y "$pidfile" 2>/dev/null)"
    p_start="$(proc_start_epoch "$pid")"
    if [[ -n "$pf_mtime" && -n "$p_start" ]] && (( p_start > pf_mtime + 2 )); then
        err "  refusing to stop $name: pid $pid started $(( p_start - pf_mtime ))s AFTER"
        err "    $pidfile was written, so it is a different process that reuses the number."
        err "    Leaving it alone and keeping the pidfile. It is now $(cat "/proc/$pid/comm" 2>/dev/null || echo '?')."
        err "    If the stack really is gone, delete the stale pidfile: rm $pidfile"
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        # Negative pid targets the whole process group (setsid above), so children die too.
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            warn "  $name did not exit on TERM; sending KILL"
            kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        else
            info "  stopped $name"
        fi
    fi
    # [Co-developed with claude code -- Adam]
    # KNOWN-ISSUES B-5. Read after the process is gone, never before: supervise.sh writes the
    # file and then exits, so by the time the kill loop above sees the pid disappear the answer
    # is already on disk. A component that had died on its own before `down` ran is reported here
    # too -- that is the point, since nothing else would ever have said so.
    report_exit "$name"
    # .child.pid names a pid that is now dead. Removed with the pidfile so that nobody signals a
    # recycled number out of a file this script left behind. .exit is evidence and is kept; the
    # next start_bg clears it.
    rm -f "$pidfile" "$PID_DIR/$name$CMD_SUFFIX" "$PID_DIR/$name.child.pid"
}

port_open() {
    # bash /dev/tcp avoids depending on nc/ss being installed.
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0
    return 1
}

# port_listener_pids <port> -- pids listening on it, one per line. Empty when unknowable.
# [Co-developed with claude code -- Adam]
port_listener_pids() {
    command -v ss >/dev/null 2>&1 || return 0
    ss -ltnpH "( sport = $1 )" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# port_listener_description <port> -- "name (pid N)" for the log, or a plain statement when the
# owner is not visible to this user. [Co-developed with claude code -- Adam]
port_listener_description() {
    local pids; pids="$(port_listener_pids "$1")"
    if [[ -z "$pids" ]]; then
        echo "a process this user cannot see (probably root-owned)"
        return
    fi
    local out=""
    for pid in $pids; do
        local comm; comm="$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"
        out="${out:+$out, }$comm (pid $pid)"
    done
    echo "$out"
}

# port_owner_verdict <port> <component> -> ours | stray | unknown
#
# [Co-developed with claude code -- Adam]
# `ours` means the listening socket belongs to the process this script started, or to one of its
# descendants: start_bg uses setsid, so the recorded pid is the process-group leader and every child
# shares that pgid -- which is the same assumption stop_one already makes when it signals `-$pid`.
port_owner_verdict() {
    local port="$1" component="$2"
    local pidfile="$PID_DIR/$component.pid"
    if [[ ! -f "$pidfile" ]]; then echo unknown; return; fi
    local ours; ours="$(cat "$pidfile" 2>/dev/null)"
    [[ -n "$ours" ]] || { echo unknown; return; }

    local listeners; listeners="$(port_listener_pids "$port")"
    if [[ -z "$listeners" ]]; then
        echo unknown
        return
    fi

    for pid in $listeners; do
        if [[ "$pid" == "$ours" ]]; then
            echo ours
            return
        fi
        local pgid; pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
        if [[ -n "$pgid" && "$pgid" == "$ours" ]]; then
            echo ours
            return
        fi
    done
    echo stray
}

# wait_for_port <port> <label> [timeout] [component]
#
# [Co-developed with claude code -- Adam]
# The optional 4th argument is the component we just started. Pass it, and a port that opens
# because *something else* is already listening no longer counts as success.
#
# That distinction is not theoretical. A stray kernel left running on :8000 outside this
# script's pid tracking made `up p4` report "waiting for kernel API on :8000  up" while the
# kernel it had actually started was already dead of `bind: Address already in use`. The whole
# run then measured the stray process: `stack.sh wait` reported 288 edges and 128 hosts, which
# are the OVS topology's numbers, during what was supposed to be a P4 session. Everything
# downstream of that -- the graph, the flow tables, any baseline captured -- was about the wrong
# network, and nothing said so.
wait_for_port() {
    local port="$1" label="$2" timeout="${3:-30}" component="${4:-}"
    printf '  waiting for %s on :%s ' "$label" "$port"
    for _ in $(seq 1 $((timeout * 2))); do
        if [[ -n "$component" ]] && ! is_running "$component"; then
            echo " ${R}died${N}"
            err "  $component exited while starting; :$port may be held by something else"
            err "  check $LOG_DIR/$component.log, then:  ss -ltnp | grep :$port"
            return 1
        fi
        if port_open "$port"; then
            # The port is open, but is it ours?
            #
            # [Co-developed with claude code -- Adam]
            # This used to re-test `! is_running "$component"` -- textually the same condition as the
            # check at the top of this loop, a few instructions earlier. It could therefore only fire
            # if the process died in between, and the stray-listener case it was written for sailed
            # straight through: a leftover kernel holding :8000 was reported as "up" while the kernel
            # this script started was already dead of `bind: Address already in use`. Found by
            # review; the guard had never worked.
            #
            # Asking who owns the socket is the only way to answer the question the comment claims to
            # answer.
            if [[ -n "$component" ]]; then
                case "$(port_owner_verdict "$port" "$component")" in
                    ours)
                        ;;
                    stray)
                        echo " ${R}not ours${N}"
                        err "  :$port is held by $(port_listener_description "$port"), not by the" \
                            "$component this script started"
                        err "  stop it first:  ss -ltnp | grep :$port"
                        return 1
                        ;;
                    unknown)
                        # Cannot see the owner -- no `ss`, or the socket belongs to another user
                        # (the manual instructions start the kernel with `sudo -E`). Fall back to the
                        # weaker check rather than inventing a failure, but say so, because a silent
                        # fallback here is how the original guard went unnoticed.
                        warn "  cannot tell who owns :$port; proceeding on '$component is alive'"
                        if ! is_running "$component"; then
                            echo " ${R}died${N}"
                            return 1
                        fi
                        ;;
                esac
            fi
            echo " ${G}up${N}"
            return 0
        fi
        printf '.'
        sleep 0.5
    done
    echo " ${R}timeout${N}"
    return 1
}

http_get() {
    # --fail so a 4xx/5xx is not mistaken for success.
    curl -sf --max-time 5 "$1" 2>/dev/null
}

# --- convergence -----------------------------------------------------------------

# The important one. Polls get_graph_data until every switch in the topology file is both
# up and enabled, so downstream tests never run against a half-learned graph.
cmd_wait() {
    local timeout="${1:-90}"
    local topo
    topo="$(awk '{print $2}' "$MODE_FILE" 2>/dev/null)"
    [[ -z "$topo" ]] && topo="$TOPO_OVS"

    local expected
    # The path is passed as argv, not interpolated into the source: a topology path
    # containing a quote would otherwise break the script or inject Python.
    expected="$(python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))
print(sum(1 for n in t["nodes"] if n.get("vertex_type") == 0))' "$topo" 2>/dev/null)"
    [[ -z "$expected" ]] && { err "cannot read topology: $topo"; return 2; }

    echo "waiting for topology convergence (expect $expected switches up+enabled, timeout ${timeout}s)"
    local start; start=$(date +%s)
    local last=""
    while true; do
        local body; body="$(http_get "$NDT_URL/ndt/get_graph_data")"
        if [[ -n "$body" ]]; then
            local state
            state="$(printf '%s' "$body" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('unparseable'); raise SystemExit
sw=[n for n in d.get('nodes',[]) if n.get('vertex_type')==0]
up=sum(1 for n in sw if n.get('is_up'))
en=sum(1 for n in sw if n.get('is_enabled'))
print(f'{len(sw)} {up} {en} {len(d.get(\"edges\",[]))}')" 2>/dev/null)"
            if [[ "$state" != "$last" ]]; then
                read -r total up en edges <<<"$state" 2>/dev/null || true
                info "  switches=$total up=$up enabled=$en edges=$edges"
                last="$state"
            fi
            read -r total up en _edges <<<"$state" 2>/dev/null || true
            if [[ "${total:-0}" == "$expected" && "${up:-0}" == "$expected" \
                  && "${en:-0}" == "$expected" ]]; then
                ok "converged after $(( $(date +%s) - start ))s"
                return 0
            fi
        fi
        if (( $(date +%s) - start > timeout )); then
            err "did not converge within ${timeout}s (last: ${last:-no response})"
            warn "in P4 mode this is expected until Phase 6: nothing calls"
            warn "/ndt/inform_switch_entered, so is_enabled stays false."
            return 1
        fi
        sleep 2
    done
}

# --- up ---------------------------------------------------------------------------

cmd_up() {
    local mode="${1:-}"
    local force="${2:-}"
    case "$mode" in
        ovs|p4) ;;
        *) err "usage: $0 up {ovs|p4} [--force]"; return 2 ;;
    esac

    # [Co-developed with claude code -- Adam]
    # Starting Ryu while a Mininet is already alive is the known /stats/flow wedge trigger:
    # the switches reconnect to the new Ryu and its flow-stats replies come back empty
    # forever (1.011 s, the ofctl DEFAULT_TIMEOUT) -- root cause unproven, no recovery short
    # of recreating the network. doc/2026-08-10_ovs_manual_test_runbook.md's own rule is "never restart
    # Ryu alone"; the 2026-08-13 overnight round nearly walked into it via this exact
    # command. The check reads the mininet: process tags, the same signal mnexec targets.
    if [[ "$mode" == "ovs" && "$force" != "--force" ]]; then
        local mn_procs
        mn_procs="$(count_mininet_procs)"
        if [[ "$mn_procs" -gt 0 ]]; then
            err "refusing 'up ovs': a Mininet is already running ($mn_procs mininet: processes)."
            err "Starting Ryu under a live Mininet triggers the /stats/flow wedge (empty replies"
            err "forever; no recovery). Exit the Mininet CLI first, then re-run this; start"
            err "Mininet when [2/3] prompts for it. To accept the risk: $0 up ovs --force"
            return 1
        fi
    fi

    local topo script
    if [[ "$mode" == "p4" ]]; then
        topo="$TOPO_P4"; script="$P4_TOPO_SCRIPT"
    else
        topo="$TOPO_OVS"; script="$OVS_TOPO_SCRIPT"
    fi
    echo "Bringing up the $mode stack"
    echo "  topology: $topo"
    echo

    # The two modes start in *opposite* orders, because the direction of the southbound
    # connection is reversed:
    #
    #   OVS: Ryu is the server. Switches dial out to it, so Ryu has to be listening *before*
    #        Mininet starts -- that ordering is the whole requirement, not the port number.
    #        The topology passes RemoteController with no port, so Mininet probes 6653 then
    #        6633 and connects to whichever answers (mininet/node.py:1551-1565
    #        RemoteController.checkListening). ryu-manager with no --ofp-tcp-listen-port
    #        opens *both* 6653 and 6633 (the second for backward compatibility), so the
    #        no-flag invocation below lands on 6653.
    #
    #        If Ryu is not listening yet, checkListening falls through to a 6653 default
    #        (node.py:1564) and the switches dial a dead port -- and no log on either side
    #        ever names the port. That silent failure is why wait_for_port below is not
    #        optional.
    #
    #        Verified live 2026-08-21, 128-host NTG testbed_topo.py, three arms: no flag ->
    #        switches on 6653, 10/10 connected; --ofp-tcp-listen-port 6633 -> switches on
    #        6633, 10/10 connected; the website's verbatim command (with singular
    #        --observe-link) -> 6633, 10 switches / 32 links, paths installed. An earlier
    #        version of this comment claimed the 6633 flag "breaks it silently". It does not.
    #   P4:  bmv2 is the server -- simple_switch_grpc listens on 0.0.0.0:30051-30060 -- and the
    #        proxy is a gRPC *client* connecting to each one. So Mininet has to be up first, or
    #        the proxy's first real RPC gets ECONNREFUSED and uvicorn exits before opening :8081.
    #
    # Every port number named above is also a row in ports.sh, with its owner and what a
    # foreign holder costs, and cmd_down/cmd_clean/deep_sweep/preflight read those rows. This
    # comment is kept for the ORDERING argument and the 2026-08-21 three-arm measurement, which
    # no table can hold; it is no longer the only place the numbers exist. If you change a port
    # here, change the row -- a comment that describes moved behaviour sends the next reader
    # looking for something that is not there.
    #
    # Treating both as "control plane first" is what used to break P4 mode.
    if [[ "$mode" == "ovs" ]]; then
        echo "[1/3] control plane (Ryu)"
        if [[ ! -x "$RYU_MANAGER" ]]; then
            err "  ryu-manager not found: $RYU_MANAGER"; return 1
        fi
        # Fail here rather than at wait_for_port. A missing app file makes ryu-manager exit, and
        # the symptom -- :8080 never opening -- reads like a slow controller rather than like a
        # file that is not there. [Co-developed with claude code -- Adam]
        if [[ ! -f "$RYU_TOPOLOGY_APP" ]]; then
            err "  bounded topology app not found: $RYU_TOPOLOGY_APP"
            err "  (it is version-controlled at tools/ryu_apps/rest_topology_bounded.py)"; return 1
        fi
        # intelligent_router.py only serves /ryu_server/all_destination_paths. Every other Ryu
        # REST endpoint the kernel depends on comes from a stock app, and loading neither of
        # these is a silent 404 that surfaces as garbage rather than as an error:
        #
        #   rest_topology -> /v1.0/topology/{switches,hosts,links}
        #     The kernel's *pull* path for switch state. --observe-links alone only loads
        #     ryu.topology.switches, which fires the events the custom app pushes from.
        #     Without the REST app, updateSwitches() feeds the 404's HTML to json::parse,
        #     catches the throw and returns -- so the graph stays down and disabled.
        #
        #     🔴 This is $RYU_TOPOLOGY_APP -- OUR copy (tools/ryu_apps/rest_topology_bounded.py),
        #     not the stock `ryu.app.rest_topology` module, and the stock one must NOT be added
        #     back alongside it: both register the same /v1.0/topology/* routes. KNOWN-ISSUES A-2
        #     -- upstream these three handlers block forever in send_request -> reply_q.get(), so
        #     a wedged ryu.topology.switches accepts the kernel's connection and never answers.
        #     The copy bounds each at 3 s and returns 503 with an empty body. See
        #     tools/ryu_apps/README.md for why both of those numbers are what they are.
        #
        #   ofctl_rest -> GET /stats/flow/<dpid>, POST /stats/flowentry/{add,modify,delete,
        #                 delete_strict}
        #     Every flow install/modify/delete and all flow-table polling. Without it the
        #     kernel logs "JSON parsing failed ... last read: '<'" once per poll per switch
        #     (it is parsing a 404 HTML page), get_switch_openflow_table_entries returns
        #     nothing usable, the Classifier stays empty so every flow's path is [], and
        #     install_flow_entry fails with "Ryu controller returned HTTP 404".
        start_bg ryu "$LOG_DIR/ryu.log" \
            bash -c "cd '$KERNEL_DIR' && '$RYU_MANAGER' --observe-links '$RYU_APP' '$RYU_TOPOLOGY_APP' ryu.app.ofctl_rest"
        wait_for_port 8080 "Ryu REST" 40 ryu || {
            err "  Ryu did not open :8080; see $LOG_DIR/ryu.log"; return 1; }

        echo "[2/3] data plane (Mininet, needs sudo)"
        prompt_for_mininet "$script" || return 1
    else
        echo "[1/3] data plane (bmv2 Mininet, needs sudo)"
        warn "  bmv2 must be listening before the proxy starts: the proxy is a gRPC client,"
        warn "  and it exits if it cannot reach the switches."
        prompt_for_mininet "$script" || return 1

        echo "[2/3] control plane (P4 proxy agent)"
        if [[ ! -x "$P4_PROXY_PY" ]]; then
            err "  P4 proxy interpreter not found: $P4_PROXY_PY"
            err "  create it: python3 -m venv p4_proxy/venv && p4_proxy/venv/bin/pip install -r p4_proxy/requirements.txt"
            return 1
        fi
        # The agent must run with p4_proxy as cwd; it resolves p4info/json relative to it.
        # The proxy's host table comes from this file, not from its argv -- see START_BG_IDENTITY.
        START_BG_IDENTITY="hosts=$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            "$KERNEL_DIR/p4_proxy/mininet/host_count_override" 2>/dev/null | head -1)" \
        start_bg p4_proxy "$LOG_DIR/p4_proxy.log" \
            env PYTHONPATH="$KERNEL_DIR/p4_proxy" \
            bash -c "cd '$KERNEL_DIR/p4_proxy' && '$P4_PROXY_PY' proxy_agent/main.py"
        wait_for_port 8081 "P4 proxy agent" 30 p4_proxy || {
            err "  proxy did not open :8081; see $LOG_DIR/p4_proxy.log"
            err "  if the log shows ECONNREFUSED to :3005x, bmv2 is not running -- start it first"
            return 1; }
    fi

    # The kernel must come last, and not immediately: TopologyAndFlowMonitor::run() pulls
    # /v1.0/topology/* and the destination paths exactly once and then exits, so whatever the
    # controller knows at that moment is all the kernel ever learns. The user manual requires
    # at least 60s after Mininet for LLDP discovery to converge first.
    # https://ndtwin.org/docs/ndtwin-user-manual/ndtwin-kernel/operate-an-emulated-software-network/native-linux-excution-environment/
    await_convergence "$mode" "$topo" "$CONVERGE_WAIT" || return 1

    # -- 3. kernel --
    echo "[3/3] kernel"
    if [[ ! -x "$KERNEL_DIR/build/bin/ndtwin_kernel" ]]; then
        err "  kernel binary missing; run tools/test_workflow/l1_unit_tests.sh first"
        return 1
    fi
    # Both dataplanes run under mode=mininet; the topology file is what selects OVS vs bmv2.
    #
    # [Co-developed with claude code -- Adam]
    # `exec` matters: without it this bash stays alive as the kernel's parent, and every number
    # and every exit status anyone recorded for "the kernel" belonged to that shell instead. With
    # it the shell becomes the kernel, so $name.child.pid is the kernel's own pid, /proc/<pid>/comm
    # reads ndtwin_kernel, and the status supervise.sh records is the kernel's own.
    #
    # This changes the recorded command string, so the first `up` after this change restarts a
    # kernel that is already running -- start_bg's own rule, and the reason it is worth naming
    # here rather than being discovered as a surprise.
    start_bg kernel "$LOG_DIR/kernel.log" \
        bash -c "cd '$KERNEL_DIR/build' && exec ./bin/ndtwin_kernel --mode mininet --topology '$topo' --no-ai"
    wait_for_port 8000 "kernel API" 40 kernel || {
        err "  kernel did not open :8000; see $LOG_DIR/kernel.log"; return 1; }

    # Recorded only now that the stack is actually up. Written up-front, a failed start left
    # the mode claiming e.g. p4 while an OVS stack was still running, so 'wait' checked
    # convergence against the wrong topology.
    echo "$mode $topo" >"$MODE_FILE"

    echo
    ok "stack up. next: $0 wait"
}

# --- status / down / logs ---------------------------------------------------------

cmd_status() {
    local mode; mode="$(cat "$MODE_FILE" 2>/dev/null || echo 'unknown')"
    echo "mode: $mode"
    echo
    printf '  %-14s %-10s %s\n' COMPONENT PROCESS ENDPOINT
    for name in ryu p4_proxy kernel; do
        local proc="-"
        is_running "$name" && proc="running"
        printf '  %-14s %-10s' "$name" "$proc"
        case "$name" in
            ryu)      port_open 8080 && echo " :8080 open" || echo " :8080 closed" ;;
            p4_proxy) port_open 8081 && echo " :8081 open" || echo " :8081 closed" ;;
            kernel)   port_open 8000 && echo " :8000 open" || echo " :8000 closed" ;;
        esac
    done
    echo
    if port_open 8000; then
        local body; body="$(http_get "$NDT_URL/ndt/get_graph_data")"
        if [[ -n "$body" ]]; then
            printf '%s' "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sw=[n for n in d.get('nodes',[]) if n.get('vertex_type')==0]
print('  graph: %d switches (%d up, %d enabled), %d hosts, %d edges' % (
    len(sw), sum(1 for n in sw if n.get('is_up')),
    sum(1 for n in sw if n.get('is_enabled')),
    sum(1 for n in d.get('nodes',[]) if n.get('vertex_type')==1),
    len(d.get('edges',[]))))" 2>/dev/null || echo "  graph: unparseable response"
        else
            echo "  graph: no response from get_graph_data"
        fi
    fi
}

cmd_down() {
    echo "Shutting down (reverse order)"
    # Kernel first so it stops polling a controller that is going away.
    for name in kernel p4_proxy ryu; do stop_one "$name"; done
    warn "Mininet was started manually; clean it up with:  sudo mn -c"
    rm -f "$MODE_FILE"

    # [Co-developed with claude code -- Adam]
    # stop_one only knows what this script started. A process launched by hand -- during
    # debugging, say -- survives `down` and then poisons the next `up`, because wait_for_port sees
    # an open port and reports success while the kernel it actually started is dead of
    # `bind: Address already in use`. That happened: a whole P4 session measured a stray OVS
    # kernel and reported 288 edges and 128 hosts, and nothing said so. wait_for_port now catches
    # it, but saying it here means the operator learns at teardown rather than mid-run.
    # The message used to assert "not something this script started" without checking. :8000 and
    # :8080 are two of the most commonly occupied ports on a developer machine, so an unrelated
    # listener made every `down` exit non-zero while claiming something it had not established.
    # port_owner_verdict answers it properly, using the same `ss -ltnp` the advice below names.
    #
    # The set of ports is now ports.sh's table, not three literals here. The literals were the
    # ports that are easy to name; the table is the ports that block the next bring-up, and it
    # carries the consequence of each, which is what turns a leftover into an actionable line.
    local leftovers=0 spec proto rowplane rowowner consequence port
    while IFS='|' read -r spec proto rowplane rowowner consequence; do
      [[ -z "$spec" ]] && continue
      for port in $(ndt_port_expand "$spec"); do
        ndt_port_open "$port" "$proto" || continue
        (( leftovers++ ))
        local owner; owner="$(ndt_port_holder "$port" "$proto")"
        # port_owner_verdict reads TCP listeners only, so a UDP row can never come back
        # `ours`. That is correct rather than convenient: :6343's holder is not in $PID_DIR
        # either, and claiming ownership we cannot establish is the shape this file's own
        # comment at cmd_down already warns about.
        err "  -> $consequence"
        case "$(port_owner_verdict "$port" kernel)$(port_owner_verdict "$port" p4_proxy)$(port_owner_verdict "$port" ryu)" in
            *ours*)
                # A component this script started is still holding the port: teardown really failed.
                err "  :$port is still held by a process this script started ($owner) -- stop_one did"
                err "    not manage to stop it"
                ;;
            *)
                err "  :$port is still listening, held by $owner"
                err "    This script did not start it. The next 'up' would find the port open and"
                err "    measure the wrong process, so this is reported rather than ignored."
                ;;
        esac
      done
    done < <(ndt_port_rows all)
    # [Co-developed with claude code -- Adam]
    # KNOWN-ISSUES B-5. A component that ended on a fatal signal fails this command and is named
    # in the failure. Until now a crash on shutdown was not merely unreported -- it was
    # unreportable, because nothing recorded an exit status at all, and `down` said "done".
    #
    # Scanned as well as accumulated: report_exit fires from stop_one, which returns early when
    # there is no pidfile, so a component that crashed and whose pidfile someone removed would
    # otherwise be missed by the very check that exists for it.
    local name f status
    for f in "$PID_DIR"/*.exit; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .exit)"
        status="$(sed -n 's/^status=//p' "$f" 2>/dev/null)"
        [[ -n "$status" ]] || continue
        if fatal_exit_status "$status"; then
            err "  🔴 $name is recorded as having died of a fatal signal (status $status)"
            err "     evidence: $f, and $PID_DIR/$name.exit.log"
            STACK_FATAL_ENDINGS="${STACK_FATAL_ENDINGS:+$STACK_FATAL_ENDINGS }$name($status)"
            rm -f "$f"
        fi
    done

    if (( leftovers > 0 )); then
        # [Co-developed with claude code -- Adam]
        # 🔴 2026-09-11 (FIX-NDT-4 #16, G-9's other half). The third line here used to be
        # `pgrep -ax ndtwin_kernel`, and advice printed at an operator spreads further than a
        # lookup in code: it gets pasted into shells, runbooks and other scripts by people who
        # never read this file, and `-a` prints a command line that the next reader greps. What
        # the operator actually needs is the pid HOLDING THE PORT, which the line above already
        # gives, and this registry, which says which of them this stack started.
        err "  find and stop it, or the next 'up' will report on it:"
        err "    ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh"
        err "    cat $PID_DIR/*.pid   # what this stack started; check each against /proc/<pid>"
        return 1
    fi

    if [[ -n "$STACK_FATAL_ENDINGS" ]]; then
        err "  teardown itself worked, but something crashed rather than stopped:"
        err "    $STACK_FATAL_ENDINGS"
        err "  Reported once -- the durable record is $PID_DIR/<component>.exit.log."
        return 1
    fi

    ok "done"
}

cmd_logs() {
    echo "logs in $LOG_DIR:"
    ls -1t "$LOG_DIR" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    echo
    echo "check the kernel log against the allowlist:"
    echo "  $CONTRACT_DIR/check_logs.py $LOG_DIR/kernel.log"
}

# Sourced rather than run: define the functions and stop, so they can be driven from a test.
#
# [Co-developed with claude code -- Adam]
# Added because wait_for_port's stray-listener guard shipped broken -- the "is it ours?" branch was
# textually the same condition as the liveness check a few lines above it, so it was unreachable and
# the leftover-kernel case it exists for reported success. A false PASS in this script is worse than
# a bug in the kernel, because everything downstream is then measuring the wrong network. That is
# only testable if the real function can be called.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

case "${1:-}" in
    up)     shift; cmd_up "$@" ;;
    wait)   shift; cmd_wait "$@" ;;
    status) cmd_status ;;
    down)   cmd_down ;;
    logs)   cmd_logs ;;
    *)
        cat <<EOF
usage: $0 <command>

  up {ovs|p4}   bring the stack up in the order that mode requires, then the kernel
                  ovs: Ryu -> Mininet -> wait -> kernel   (switches dial out to Ryu)
                  p4:  Mininet -> proxy -> wait -> kernel  (proxy dials out to bmv2)
  wait [secs]   block until every switch is up AND enabled (default 90s)
  status        show process/port/graph state
  down          stop kernel, proxy/Ryu (Mininet needs 'sudo mn -c')
  logs          list logs and show the log-check command

run artefacts: $RUN_DIR
EOF
        exit 2 ;;
esac
