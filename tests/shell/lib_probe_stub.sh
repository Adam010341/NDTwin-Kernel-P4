# lib_probe_stub.sh -- sourced, never run: a suite's OWN sudo, answering every call the same way on
# every machine -- recorded, and REFUSED with rc 1 in sudo's own words -- so no sudo ANSWER a suite
# gets depends on this machine's grants or lab, and no call it makes can reach root. What it does
# NOT fix is the suite's PATH through ndt: see "WHAT THE STUB FIXES" below.
#
# [Co-developed with claude code -- Adam]
#
# WHY (2026-09-27, the orchestrator's round (a)). Six suites send read-only lab probes through the
# real `sudo -n` -- `ndtwin-lab status`, `topo-out`, `ovs-vsctl list-br`, `mnexec -a 1 true`. On a
# machine with the grants and a live lab those are answered, and the suite then runs on a path
# neither CI nor any gate has run: under a sudo that answered as a live OVS lab would,
# test_ndt_sample_rate_reads_both_bounds went red on four checks. Refusing (never a fabricated
# "no lab" answer with rc 0) fixes every sudo answer a suite gets.
#
# 🔴 WHAT THE STUB FIXES, AND WHAT IT DOES NOT (the opus judge's B1 on 356d4e4e, 09-27).
#   - It fixes the ANSWERS to sudo: always `sudo: a password is required`, rc 1.
#   - It does not fix the PATH a suite takes through ndt. That still varies with the machine:
#     `ps` (ovs_daemon_running, bmv2_count), `command -v` (ovs-vsctl, mnexec, the helper), the lab
#     ports, curl :8000 and the p4 switch manifest decide which probes are made at all.
#     test_ndt_sample_rate_reads_both_bounds takes ndt's p4 branch with a live bmv2 (0 sudo calls),
#     the unknown branch with ovs-vswitchd running (4 calls), and the none branch in CI (0 calls).
#     The gates on this laptop run the unknown branch; the other two are read from ndt, not run.
#   - The WORDING is not neutral either. ndt_sudo_probe decides granted / refused BY it
#     (sudo_surface.sh:179-182 -- ndt_sudo_refused knows five wordings). A DEVIATION from the
#     orchestrator's ruling ("answering like today's R pass"), which the orchestrator RATIFIED on
#     09-27: the R pass's shim said `sudo: refused by the nolab shim (a lab command)`, which is not
#     one of the five, so ndt read every probe as GRANTED -- an artifact of the gate. This stub says
#     what a real sudo without NOPASSWD says, and ndt reads it as refused. test_lab_handoff's
#     `ndt status` shows the three branches (its "sudo grants" line; the verdict is unchanged only
#     because that suite reads the `lab` section and nothing else):
#         where                           sudo -n answers                        ndt reads
#         gates before this stub (R pass) "refused by the nolab shim", rc 1      granted
#         this stub                       "a password is required", rc 1         refused (+ how to grant)
#         CI (ubuntu-24.04: no mnexec,    not asked -- `command -v` of the       could not be tested
#             no ndtwin-lab, no OVS)      probe's program fails first
#     The first two rows are run (the stub fix round's red first, 09-27); the CI row is read from
#     .github/workflows/ci.yml and sudo_surface.sh:176-177, not run.
#
#   probe_stub_install <dir> [--tc-empty] [--ovs-refuse] -- <allowed call>...
#       puts <dir>/probe-stub first on PATH (the suite's own temp dir: its trap removes it). An
#       allowed call is written as it is RECORDED: `sudo <command basename> <args>` with sudo's -n
#       dropped (`sudo ndtwin-lab status`, `sudo ovs-vsctl list-br`), a shell glob allowed
#       (`sudo ndtwin-lab topo-out *`); `tc <args>` / `ovs-vsctl <args>` for the unprivileged stubs.
#       --tc-empty    an unprivileged `tc` that records every call; `tc qdisc show` alone prints
#                     nothing (rc 0) -- no netem qdisc anywhere, which is the part of the answer the
#                     suites read (CI's own `tc qdisc show` lists its default qdiscs, and no netem);
#                     every other argv is REFUSED (rc 1), never a fabricated success (the judge's N5)
#       --ovs-refuse  an unprivileged `ovs-vsctl` that records and refuses (rc 1)
#   probe_stub_outside  -> one line per recorded call that no allowed call matches, plus one if the
#                          stub is not installed or not the sudo on PATH; nothing at all only when
#                          the stub took every call and every call was allowed
#   probe_stub_calls    -> every recorded call, normalised, counted
probe_stub_install() {
    local dir="$1" tc=0 ovs=0 d
    shift
    while [[ "${1:-}" == --* ]]; do
        case "$1" in --tc-empty) tc=1 ;; --ovs-refuse) ovs=1 ;; --) shift; break ;; esac
        shift
    done
    d="$dir/probe-stub"; mkdir -p "$d"
    PROBE_STUB_DIR="$d"
    PROBE_STUB_LOG="$d/calls"; : > "$PROBE_STUB_LOG"
    PROBE_STUB_ALLOW=("$@")
    # sudo's own refusal, word for word (sudo 1.9.15p5 with no NOPASSWD rule). ndt DECIDES by it,
    # not only words its messages: ndt_sudo_probe reads it as "refused" (sudo_surface.sh:179-182,
    # ndt_sudo_refused). See "WHAT THE STUB FIXES" above -- a ratified deviation from the R pass.
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
[[ "\$*" == "qdisc show" ]] && exit 0
echo "tc: refused by this suite's stub (only 'qdisc show' is answered)" >&2
exit 1
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
    # 🔴 never vacuous: a stub that was never installed, or is not the sudo on PATH, is itself a
    # line here -- "no call outside the allow-list" must not be true of a suite whose sudo went
    # somewhere else (found 09-27: a suite that sourced ndt first lost its HERE, the lib was not
    # found, and the closing check read an empty list as clean)
    if [[ -z "${PROBE_STUB_LOG:-}" || ! -f "$PROBE_STUB_LOG" ]]; then
        echo "NO STUB: probe_stub_install never ran"; return
    fi
    [[ "$(type -P sudo)" == "$PROBE_STUB_DIR/sudo" ]] || echo "the sudo on PATH is $(type -P sudo), not this suite's stub"
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
