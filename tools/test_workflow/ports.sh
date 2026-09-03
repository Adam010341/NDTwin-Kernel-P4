#!/usr/bin/env bash
#
# ports.sh -- the ports that block a bring-up, declared once, in a form that is READ.
#
# [Co-developed with claude code -- Adam]
#
# Why this file exists
#
# `cmd_clean` and `deep_sweep` both looped over `8000 8080 8081`. That set is the ports that
# are easy to name, not the ports that block the next bring-up. Everything else was known --
# and written down, in four separate comments, none of which is executed:
#
#   ndt:635                 "orphans outlive `mn -c` and hold :3005x, which makes the next
#                            fabric fail to bind"
#   ovs_4host_topo.py:31    a no-port RemoteController tries 6653 -> 6633 -> falls back to
#                            6653, which "silently masks a controller that is not there"
#   stack.sh:782-798        the same probe order, plus "simple_switch_grpc listens on
#                            0.0.0.0:30051-30060"
#   ndtwin-lab:141,152      "Ryu must already be listening on 6653"
#
# A comment is not a check. The cost was measured on 2026-09-02: a kernel nobody had started
# held UDP :6343, a legitimate Terminal 3 died with `bind() to sFlow port 6343 failed`, and
# every one of `ndt down`'s assertions came back green -- because :6343 was in none of them,
# and because `port_open` speaks only TCP.
#
# So the knowledge moves here, next to the code that acts on it, with the consequence attached
# to each row. A row that is wrong is now falsifiable by a test; a comment never was.
#
# Sourced by tools/test_workflow/ndt and tools/test_workflow/stack.sh. Defines functions and
# data only -- no side effects, so sourcing it is safe from a test.

# --- the table ---------------------------------------------------------------------
#
#   spec|proto|plane|owner|consequence
#
# spec    a port, or an inclusive `lo-hi` range.
# proto   tcp or udp. It is a column and not an assumption because :6343 is UDP, and the
#         TCP-only probe every caller had is exactly how it stayed invisible.
# plane   which bring-up the row blocks: p4, ovs, both, or apps. `both` and `apps` rows are
#         always residue; the plane column is what lets a preflight ask about its own plane.
# owner   who is supposed to hold it. Named so a residue line can say "bmv2 pid 12345
#         holding :30051" instead of a count.
# consequence  what happens if something ELSE holds it. This is the column the four comments
#         had and the four checks did not. It is printed, not just stored.
#
# Ranges are per-device: the gRPC port for device N is GRPC_PORT_BASE + N and the Thrift port
# is THRIFT_PORT_BASE + N, both from p4_proxy/mininet/grpc_ports.py -- the ten-switch fabric
# therefore occupies 30051-30060 and 9091-9100. Keep the two files in step; grpc_ports.py is
# the source of the base, this is the source of what a leftover on it costs.
NDT_PORT_TABLE="$(cat <<'TABLE'
8000|tcp|both|the kernel's northbound API (ndtwin_kernel)|the next 'up' measures the stray kernel while the one it started is dead of EADDRINUSE -- a P4 session reported the OVS topology's 288 edges and 128 hosts this way
8080|tcp|ovs|Ryu's REST API (ryu-manager)|the kernel pulls topology and paths from the PREVIOUS round's controller
8081|tcp|p4|the P4 proxy agent (uvicorn)|the next 'up' measures the previous round's proxy; the one it started never opened the port
6653|tcp|ovs|Ryu's OpenFlow listener (ryu-manager)|a surviving Ryu silently adopts the next round's switches: RemoteController probes 6653 then 6633 and falls back to 6653, so "no controller" and "the wrong controller" look identical
6633|tcp|ovs|Ryu's legacy OpenFlow listener (ryu-manager with no --ofp-tcp-listen-port opens BOTH)|same as :6653 -- the probe order reaches this one too, so leaving it out means the check can be walked around
6343|udp|both|the kernel's sFlow collector (FlowLinkUsageCollector, SFLOW_PORT)|the next kernel's bind() fails with `bind() to sFlow port 6343 failed`, and every flow rate and link utilisation then reads zero -- indistinguishable from an idle network
30051-30060|tcp|p4|bmv2 simple_switch_grpc, one port per device (grpc_ports.py GRPC_PORT_BASE + N)|an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
9091-9100|tcp|p4|bmv2 Thrift, one port per device (grpc_ports.py THRIFT_PORT_BASE + N)|the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
9000|tcp|apps|Simulation-Platform-Manager (ndt apps sim; the kernel posts to http://127.0.0.1:9000/submit)|a stray holder makes the sim liveness check pass while the app is not there -- the 09-02 round used ':9000 has a listener' as its criterion for that app
TABLE
)"

# ndt_port_rows [plane] -- table rows, optionally only those blocking one plane.
# `both` rows come back for every plane; no argument returns everything.
ndt_port_rows() {
    local want="${1:-}"
    local spec proto plane rest
    while IFS='|' read -r spec proto plane rest; do
        [[ -z "$spec" ]] && continue
        if [[ -n "$want" && "$want" != all ]]; then
            [[ "$plane" == "$want" || "$plane" == both ]] || continue
        fi
        printf '%s|%s|%s|%s\n' "$spec" "$proto" "$plane" "$rest"
    done <<<"$NDT_PORT_TABLE"
}

# ndt_port_expand <spec> -- one port per line; `lo-hi` becomes every port in the range.
ndt_port_expand() {
    local spec="$1"
    if [[ "$spec" == *-* ]]; then
        local lo="${spec%%-*}" hi="${spec##*-}" p
        for (( p = lo; p <= hi; p++ )); do echo "$p"; done
    else
        echo "$spec"
    fi
}

# ndt_port_open <port> [proto] -- 0 open, 1 closed, 2 cannot tell.
#
# 2 is a real answer and callers must not fold it into "closed". UDP has no connect handshake
# to borrow, so the only probe is `ss`; where `ss` is missing the honest report is "blind",
# which is the same distinction read_ephemeral_range() already makes in grpc_ports.py.
ndt_port_open() {
    local port="$1" proto="${2:-tcp}"
    if [[ "$proto" == udp ]]; then
        command -v ss >/dev/null 2>&1 || return 2
        ss -lunH "( sport = :$port )" 2>/dev/null | grep -q . && return 0
        return 1
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && exec 3>&- && return 0
    return 1
}

# ndt_port_listener_pids <port> [proto] -- pids holding it, one per line. Empty when the
# socket belongs to another user (root-owned listeners are invisible to us) or `ss` is absent.
ndt_port_listener_pids() {
    local port="$1" proto="${2:-tcp}" flag=-ltnpH
    command -v ss >/dev/null 2>&1 || return 0
    [[ "$proto" == udp ]] && flag=-lunpH
    ss "$flag" "( sport = :$port )" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# ndt_port_holder <port> [proto] -- "comm pid N" for the residue line, or a plain statement
# when the owner cannot be seen. Never empty: a residue report with a blank subject is the
# count it is replacing.
ndt_port_holder() {
    local port="$1" proto="${2:-tcp}"
    local pids; pids="$(ndt_port_listener_pids "$port" "$proto")"
    [[ -z "$pids" ]] && { echo "a process this user cannot see (probably root-owned)"; return; }
    local out="" pid comm
    for pid in $pids; do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"
        out="${out:+$out, }$comm pid $pid"
    done
    echo "$out"
}

# ndt_port_residue [plane] -- one line per HELD port, naming the holder and the consequence:
#
#   residue: bmv2 pid 12345 holding :30051 (tcp)
#            -> owner: bmv2 simple_switch_grpc, one port per device ...
#            -> if something else holds it: an orphan holding one makes the next fabric ...
#
# Prints nothing when everything is free. Returns 0 when clean, 1 when anything is held, 2
# when a row could not be probed at all -- so a caller can tell "clean" from "did not look".
ndt_port_residue() {
    local plane="${1:-all}" spec proto rowplane owner consequence port rc=0 blind=0
    while IFS='|' read -r spec proto rowplane owner consequence; do
        [[ -z "$spec" ]] && continue
        for port in $(ndt_port_expand "$spec"); do
            ndt_port_open "$port" "$proto"
            case $? in
                0) ;;
                2) blind=1
                   printf 'residue: :%s (%s) could NOT be probed on this machine (no ss) -- not a pass\n' \
                          "$port" "$proto"
                   printf '         -> owner: %s\n' "$owner"
                   continue ;;
                *) continue ;;
            esac
            rc=1
            printf 'residue: %s holding :%s (%s)\n' "$(ndt_port_holder "$port" "$proto")" "$port" "$proto"
            printf '         -> owner: %s\n' "$owner"
            printf '         -> if something else holds it: %s\n' "$consequence"
        done
    done < <(ndt_port_rows "$plane")
    (( rc == 1 )) && return 1
    (( blind == 1 )) && return 2
    return 0
}

# ndt_port_label -- the ports this plane covers, for a one-line "all closed" summary. The old
# message hard-coded "ports 8000/8080/8081 closed", which is the same defect in prose.
ndt_port_label() {
    local plane="${1:-all}" spec rest out=""
    while IFS='|' read -r spec rest; do
        [[ -z "$spec" ]] && continue
        out="${out:+$out/}$spec"
    done < <(ndt_port_rows "$plane")
    echo "$out"
}
