#!/usr/bin/env bash
# host_witness.sh -- continuous accounting of what is running on ONE host, for the
# duration of a measurement window. Writes one line every N seconds.
# [Co-developed with claude code -- Adam]
#
#   host_witness.sh [interval_sec] [count]      # count 0 = until killed
#   host_witness.sh --self-test                 # pure, spawns nothing
#
# ===========================================================================
#  WHY THIS EXISTS, AND WHY EVERY LINE CARRIES A HOSTNAME
#
#  2026-09-01: an auditor read a witness log of this shape
#
#      23:57:39 load=0.58 qemu=1 pids=52578
#
#  concluded that a VM had been running on the laptop where the repo lives,
#  and was about to retract two columns of a measurement round and mark four
#  cells contaminated. pid 52578 was on a DIFFERENT machine -- another
#  session's VM, on the lab box, still running hours later.
#
#  The log was not wrong. It simply never said which host it described. The
#  only thing pointing at a machine was the DIRECTORY the file sat in, and a
#  directory name is a hint, not a field -- but the next reader will use it
#  as one, because there is nothing else to use.
#
#      A record of "what is on the machine" must say which machine.
#
#  Same rule as naming the binary a benchmark measured. An identifier that
#  the reader has to infer is an identifier that will eventually be inferred
#  wrongly, and the cost lands on whoever trusts it most.
# ===========================================================================
#
# 🔴 AND: a VM is identified by /proc/<pid>/exe, never by argv.
#
#  The mutation gate in this directory launches stand-ins whose argv[0] is
#  literally "qemu-system-x86_64" -- six of them. Anything counting VMs by
#  pattern-matching a command line counts those as virtual machines. The
#  mirror image of the same defect is a round runner elsewhere that clears
#  the field with `pkill -f iperf3`: one over-counts, the other over-kills,
#  and both because a string appeared in an argument vector.
#
#  exe is a kernel-maintained symlink to the actual binary. It cannot be set
#  by the process.
set -uo pipefail

PROCFS="${PROCFS:-/proc}"     # overridable so the self-test needs no processes

# vm_kind <pid> -> "vm" | "other" | "unreadable"
#
# 🔑 Three outcomes, not two. "I could not read this process" and "this is not
# a VM" are different facts, and collapsing them is how a permissions failure
# becomes a clean bill of health -- the same shape as a snapshot lister that
# printed a locked disk as "no snapshots". They are reported separately below.
vm_kind() {
    local exe
    # ⚠️ NOT `|| return`: the first version did that, so a failed readlink returned
    # with no output at all -- "cannot read" printed as the empty string and every
    # caller read it as "not a VM". The self-test caught it on its first run, which
    # is the entire argument for writing the self-test before trusting the script.
    exe=$(readlink "$PROCFS/$1/exe" 2>/dev/null || true)
    if [ -z "$exe" ]; then
        # No permission, or a kernel thread (which has no exe at all).
        [ -r "$PROCFS/$1/stat" ] || { printf 'unreadable'; return; }
        if grep -qE '^[0-9]+ \(.*\) [A-Z] [0-9]+ [0-9]+ [0-9]+ 0 ' "$PROCFS/$1/stat" 2>/dev/null; then
            printf 'other'; return          # kernel thread: no tty, no exe, benign
        fi
        printf 'unreadable'; return
    fi
    case "${exe##*/}" in
        qemu-system-*|qemu-kvm) printf 'vm' ;;
        *)                      printf 'other' ;;
    esac
}

sample() {
    local pid vms="" nvm=0 nunread=0 k
    for d in "$PROCFS"/[0-9]*; do
        pid=${d##*/}
        k=$(vm_kind "$pid")
        case "$k" in
            vm)         nvm=$((nvm+1)); vms="$vms${vms:+,}$pid" ;;
            unreadable) nunread=$((nunread+1)) ;;
        esac
    done
    printf '%s host=%s load=%s vms=%s pids=%s unreadable=%s\n' \
        "$(date -Is)" "$(hostname)" \
        "$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo '?')" \
        "$nvm" "${vms:--}" "$nunread"
}

self_test() {
    local t rc=0 got
    t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
    # A real qemu: exe points at the binary. The target need not exist -- readlink
    # reports the link, which is exactly the property argv cannot forge.
    mkdir -p "$t/101"; ln -s /usr/bin/qemu-system-x86_64 "$t/101/exe"
    # 🔑 THE CASE THAT MATTERS: a process pretending to be qemu in its argv only.
    # This is not hypothetical -- test_vm_coordination.sh launches six of them.
    mkdir -p "$t/102"; ln -s /usr/bin/bash "$t/102/exe"
    printf 'qemu-system-x86_64\0-smp\0007\0' > "$t/102/cmdline"
    # Unreadable exe (another user's process): must NOT be silently counted as "not a VM".
    mkdir -p "$t/103"
    mkdir -p "$t/104"; ln -s /usr/bin/qemu-kvm "$t/104/exe"

    check() {
        got=$(PROCFS="$t" vm_kind "$1")
        if [ "$got" = "$2" ]; then printf '  ✅ pid %s -> %s\n' "$1" "$got"
        else printf '  🔴 pid %s -> %s (want %s)\n' "$1" "$got" "$2"; rc=1; fi
    }
    echo "=== classification (no processes are started by this test) ==="
    check 101 vm
    check 102 other        # argv says qemu, exe says bash -- exe wins
    check 103 unreadable
    check 104 vm

    echo "=== the sample line names its host and separates the three counts ==="
    got=$(PROCFS="$t" sample)
    printf '  %s\n' "$got"
    case "$got" in
        *"host=$(hostname)"*) echo "  ✅ host field present and correct" ;;
        *) echo "  🔴 no host field -- the defect this file exists to prevent"; rc=1 ;;
    esac
    case "$got" in
        *'vms=2'*) echo "  ✅ counted exactly the two real VMs" ;;
        *) echo "  🔴 VM count wrong -- the argv impostor was probably counted"; rc=1 ;;
    esac
    case "$got" in
        *'unreadable=1'*) echo "  ✅ the unreadable process is reported, not absorbed" ;;
        *) echo "  🔴 unreadable collapsed into 'not a VM'"; rc=1 ;;
    esac
    return $rc
}

case "${1:-}" in
    --self-test) self_test; exit $? ;;
esac

INTERVAL="${1:-5}"
COUNT="${2:-0}"
# The header repeats the host, so a file that gets truncated, tailed or pasted
# into a report still carries it. One line of redundancy against the failure
# this whole file is about.
printf '# host_witness  host=%s  started=%s  interval=%ss  procfs=%s\n' \
    "$(hostname)" "$(date -Is)" "$INTERVAL" "$PROCFS"
i=0
while :; do
    sample
    i=$((i+1))
    [ "$COUNT" != 0 ] && [ "$i" -ge "$COUNT" ] && break
    sleep "$INTERVAL"
done
