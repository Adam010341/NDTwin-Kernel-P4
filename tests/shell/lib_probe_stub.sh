# lib_probe_stub.sh -- sourced, never run: a suite's OWN sudo, answering every call the way CI and
# every gate answer it today -- recorded, and REFUSED with rc 1 -- so the suite's result no longer
# depends on whether this machine has a live lab, and no call it makes can reach root.
#
# [Co-developed with claude code -- Adam]
#
# WHY (2026-09-27, the orchestrator's round (a)). Six suites send read-only lab probes through the
# real `sudo -n` -- `ndtwin-lab status`, `topo-out`, `ovs-vsctl list-br`, `mnexec -a 1 true`. On a
# machine with the grants and a live lab those are answered, and the suite then runs on a path
# neither CI nor any gate has run: under a sudo that answered as a live OVS lab would,
# test_ndt_sample_rate_reads_both_bounds went red on four checks. Refusing (never a fabricated
# "no lab" answer with rc 0) keeps every suite on the one path CI and the gates run.
#
#   probe_stub_install <dir> [--tc-empty] [--ovs-refuse] -- <allowed call>...
#       puts <dir>/probe-stub first on PATH (the suite's own temp dir: its trap removes it). An
#       allowed call is written as it is RECORDED: `sudo <command basename> <args>` with sudo's -n
#       dropped (`sudo ndtwin-lab status`, `sudo ovs-vsctl list-br`), a shell glob allowed
#       (`sudo ndtwin-lab topo-out *`); `tc <args>` / `ovs-vsctl <args>` for the unprivileged stubs.
#       --tc-empty    an unprivileged `tc` that records and prints nothing (rc 0): no qdisc, as on a
#                     machine with no lab -- CI's answer, not this machine's
#       --ovs-refuse  an unprivileged `ovs-vsctl` that records and refuses (rc 1)
#   probe_stub_outside  -> one line per recorded call that no allowed call matches; nothing at all
#                          when every call was allowed
#   probe_stub_calls    -> every recorded call, normalised, counted
probe_stub_install() {
    local dir="$1" tc=0 ovs=0 d
    shift
    while [[ "${1:-}" == --* ]]; do
        case "$1" in --tc-empty) tc=1 ;; --ovs-refuse) ovs=1 ;; --) shift; break ;; esac
        shift
    done
    d="$dir/probe-stub"; mkdir -p "$d"
    PROBE_STUB_LOG="$d/calls"; : > "$PROBE_STUB_LOG"
    PROBE_STUB_ALLOW=("$@")
    # sudo's own refusal, word for word (sudo 1.9.15p5 with no NOPASSWD rule): ndt words its
    # messages by it (sudo_surface.sh ndt_sudo_refused -- wording only, never a verdict).
    cat > "$d/sudo" <<EOF
#!/bin/bash
printf 'sudo %s\\n' "\$*" >> '$PROBE_STUB_LOG'
echo "sudo: a password is required" >&2
exit 1
EOF
    if (( tc )); then
        cat > "$d/tc" <<EOF
#!/bin/bash
printf 'tc %s\\n' "\$*" >> '$PROBE_STUB_LOG'
exit 0
EOF
    fi
    if (( ovs )); then
        cat > "$d/ovs-vsctl" <<EOF
#!/bin/bash
printf 'ovs-vsctl %s\\n' "\$*" >> '$PROBE_STUB_LOG'
echo "ovs-vsctl: refused by this suite's stub" >&2
exit 1
EOF
    fi
    chmod +x "$d"/*
    export PATH="$d:$PATH"
}
_probe_stub_norm() {   # a recorded line -> `sudo <basename> <args>` (sudo's -n dropped) or as is
    local l="$1" w
    if [[ "$l" == "sudo "* ]]; then
        l="${l#sudo }"; [[ "$l" == "-n "* ]] && l="${l#-n }"
        w="${l%% *}"; [[ "$l" == *" "* ]] && l="${w##*/} ${l#* }" || l="${w##*/}"
        l="sudo $l"
    fi
    printf '%s' "$l"
}
probe_stub_outside() {
    local line n a hit
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n="$(_probe_stub_norm "$line")"; hit=0
        for a in "${PROBE_STUB_ALLOW[@]}"; do
            # shellcheck disable=SC2053  # the allowed call IS a glob
            [[ "$n" == $a ]] && { hit=1; break; }
        done
        (( hit )) || printf '%s\n' "$n"
    done < "$PROBE_STUB_LOG"
}
probe_stub_calls() {
    local line
    while IFS= read -r line; do _probe_stub_norm "$line"; echo; done < "$PROBE_STUB_LOG" | sort | uniq -c | sed 's/^ *//' | paste -sd';' -
}
