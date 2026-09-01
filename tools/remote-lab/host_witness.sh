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

# vm_kind <pid> <exe-target> -> sets KIND to "vm" | "other" | "unreadable"
#
# 🔑 Three outcomes, not two. "I could not read this process" and "this is not
# a VM" are different facts, and collapsing them is how a permissions failure
# becomes a clean bill of health -- the same shape as a snapshot lister that
# printed a locked disk as "no snapshots". They are reported separately below.
#
# ⚠️ Answers through $KIND rather than stdout. Every caller used to wrap this in
# $(...), which is a fork per pid; on a 671-process host that was ~2,000 forks
# per sample, on a machine whose CPU was under an exclusive measurement claim.
# An instrument that accounts for load must not be a significant source of it.
KIND=
vm_kind() {
    local pid="$1" exe="$2" cmd=""
    # A VM whose binary was replaced under it is still a VM. exe then reads
    # "/usr/bin/qemu-system-x86_64 (deleted)", whose basename is "(deleted)".
    exe="${exe% (deleted)}"
    if [ -n "$exe" ]; then
        case "${exe##*/}" in
            qemu-system-*|qemu-kvm) KIND=vm ;;
            *)                      KIND=other ;;
        esac
        return
    fi
    # ⚠️ NOT "return without answering": the first version did that, so a failed
    # readlink produced the empty string and every caller read it as "not a VM".
    # The self-test caught it on its first run, which is the entire argument for
    # writing the self-test before trusting the script.
    [ -r "$PROCFS/$pid/stat" ] || { KIND=unreadable; return; }
    # 🔴 2026-09-01: this branch used to ask "is tty_nr 0?" and call that a kernel
    # thread. Cross-tabulated against a definitional test on the host it was
    # witnessing: 248 real kernel threads AND 72 userspace processes -- /sbin/init,
    # systemd-resolved, blkmapd, every daemon without a controlling terminal. All
    # 72 were reported as "other", i.e. NOT A VM, when the truth was "I could not
    # read this one". A root-owned qemu started under setsid has no tty either, so
    # this tool's headline failure was reachable through the very branch that was
    # added to prevent it. A kernel thread has an empty cmdline -- that is
    # definitional, where the tty was a heuristic that happened to fit.
    IFS= read -r -d '' cmd < "$PROCFS/$pid/cmdline" 2>/dev/null || true
    [ -z "$cmd" ] && { KIND=other; return; }   # kernel thread, or a zombie: not running
    KIND=unreadable
}

# One find for every exe link on the box, instead of one readlink per pid.
# 671 pids: 3.19 s and ~2,000 forks -> 0.05 s and one. Same symlinks, same
# kernel-maintained field; the only thing that changed is how many processes ask.
read_exe_map() {
    local ph tgt
    EXE=()
    while read -r ph tgt; do EXE["${ph##*/}"]="$tgt"; done \
        < <(find "$PROCFS" -maxdepth 2 -name exe -printf '%h %l\n' 2>/dev/null)
}

sample() {
    local pid vms="" nvm=0 nunread=0 d
    declare -A EXE
    read_exe_map
    for d in "$PROCFS"/[0-9]*; do
        pid=${d##*/}
        vm_kind "$pid" "${EXE[$pid]-}"
        case "$KIND" in
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
    declare -A EXE
    t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
    local PROCFS="$t"
    # A real qemu: exe points at the binary. The target need not exist -- readlink
    # reports the link, which is exactly the property argv cannot forge.
    mkdir -p "$t/101"; ln -s /usr/bin/qemu-system-x86_64 "$t/101/exe"
    # 🔑 THE CASE THAT MATTERS: a process pretending to be qemu in its argv only.
    # This is not hypothetical -- test_vm_coordination.sh launches six of them.
    mkdir -p "$t/102"; ln -s /usr/bin/bash "$t/102/exe"
    printf 'qemu-system-x86_64\0-smp\0007\0' > "$t/102/cmdline"
    # Unreadable exe, nothing else readable either: must NOT be counted "not a VM".
    mkdir -p "$t/103"
    mkdir -p "$t/104"; ln -s /usr/bin/qemu-kvm "$t/104/exe"
    # 🔴 105 and 106 are the pair the old tty_nr rule could not tell apart: both
    # have tty_nr 0, and it called both "other". 105 is a userspace daemon whose
    # exe I cannot read -- on the real host there were 72 of these -- and the
    # honest answer for it is "unreadable", because a root-owned qemu looks
    # exactly like this. 106 is a genuine kernel thread. The discriminator is
    # cmdline, which is empty for kernel threads by definition.
    mkdir -p "$t/105"
    printf '105 (somedaemon) S 1 105 105 0 -1 4194560 0 0\n' > "$t/105/stat"
    printf '/usr/sbin/somedaemon\0--flag\0'                   > "$t/105/cmdline"
    mkdir -p "$t/106"
    printf '106 (kworker/0:1) I 2 0 0 0 -1 69238880 0 0\n'    > "$t/106/stat"
    : > "$t/106/cmdline"
    # A running VM whose binary was replaced on disk. Also exercises a target
    # containing a space, which the one-pass exe map has to carry intact.
    # ⚠️ qemu-kvm, NOT qemu-system-x86_64: the trailing wildcard in the
    # "qemu-system-*" pattern swallows " (deleted)" all by itself, so with that
    # binary this fixture stays green whether or not the suffix is stripped. It
    # was written that way first, and the mutation gate is what said so.
    mkdir -p "$t/107"; ln -s '/usr/bin/qemu-kvm (deleted)' "$t/107/exe"

    read_exe_map
    check() {
        vm_kind "$1" "${EXE[$1]-}"
        if [ "$KIND" = "$2" ]; then printf '  ✅ pid %s -> %s\n' "$1" "$KIND"
        else printf '  🔴 pid %s -> %s (want %s)\n' "$1" "$KIND" "$2"; rc=1; fi
    }
    echo "=== classification (no processes are started by this test) ==="
    check 101 vm
    check 102 other        # argv says qemu, exe says bash -- exe wins
    check 103 unreadable
    check 104 vm
    check 105 unreadable   # daemon with no tty: "I cannot read it", not "not a VM"
    check 106 other        # kernel thread: empty cmdline, genuinely not a VM
    check 107 vm           # "(deleted)" suffix stripped; space survived the map

    echo "=== the one-pass exe map carries targets verbatim ==="
    if [ "${EXE[107]-}" = '/usr/bin/qemu-kvm (deleted)' ]; then
        echo "  ✅ target with a space read intact"
    else
        echo "  🔴 exe map mangled a target: '${EXE[107]-}'"; rc=1
    fi

    echo "=== the sample line names its host and separates the three counts ==="
    got=$(sample)
    printf '  %s\n' "$got"
    case "$got" in
        *"host=$(hostname)"*) echo "  ✅ host field present and correct" ;;
        *) echo "  🔴 no host field -- the defect this file exists to prevent"; rc=1 ;;
    esac
    case "$got" in
        *'vms=3'*) echo "  ✅ counted exactly the three real VMs" ;;
        *) echo "  🔴 VM count wrong -- the argv impostor was probably counted"; rc=1 ;;
    esac
    case "$got" in
        *'unreadable=2'*) echo "  ✅ both unreadable processes reported, not absorbed" ;;
        *) echo "  🔴 unreadable collapsed into 'not a VM'"; rc=1 ;;
    esac

    arg_test "$t" || rc=1
    return $rc
}

# The reported bug lived entirely in argument handling, which the classification
# self-test never touched. These re-invoke $0, so a mutation to the option
# parsing is visible here -- but every case either exits immediately or samples
# a 7-entry fake procfs, so nothing heavy starts.
arg_test() {
    local t="$1" rc=0 out r n
    echo "=== arguments: refuse, never adopt ==="
    argcase() {  # <want-rc> <want-substring> <args...>
        local wrc="$1" want="$2"; shift 2
        # ⚠️ timeout, because the defect under test IS an infinite loop: a mutant
        # that removes the interval check makes this invocation spin forever, and
        # a test suite that hangs on its own subject reports nothing at all.
        out=$(timeout 15 "$0" "$@" 2>&1); r=$?
        if [ "$r" = "$wrc" ] && printf '%s' "$out" | grep -qF -- "$want"; then
            printf '  ✅ [%s] -> rc=%s, %s\n' "$*" "$r" "$want"
        else
            printf '  🔴 [%s] -> rc=%s (want %s), missing %s\n' "$*" "$r" "$wrc" "$want"; rc=1
        fi
    }
    argcase 0 'usage:'                    --help
    argcase 2 "unknown option"            --nope
    argcase 2 "interval must be a number" abc
    argcase 2 "must be greater than 0"    0
    argcase 2 "count must be"             1 x
    argcase 2 "at most 2 arguments"       1 2 3

    # 🔑 The accept path. Five refusals are also passed by a script that refuses
    # everything, so the run that is supposed to work has to be run.
    echo "=== a bounded run: exactly the samples asked for, and a terminating line ==="
    out=$(PROCFS="$t" timeout 15 "$0" 0.1 2 2>&1); r=$?
    n=$(printf '%s\n' "$out" | grep -c '^2[0-9][0-9][0-9]-')
    if [ "$r" = 0 ] && [ "$n" = 2 ]; then
        echo "  ✅ asked for 2 samples, got 2 (a busy loop would give many more)"
    else
        echo "  🔴 rc=$r, sample lines=$n -- wanted rc=0 and exactly 2"; rc=1
    fi
    case "$(printf '%s\n' "$out" | tail -1)" in
        '# end '*reason=complete*) echo "  ✅ the log ends with '# end … reason=complete'" ;;
        *) echo "  🔴 no terminating line: a truncated log is indistinguishable from a whole one"
           rc=1 ;;
    esac
    return $rc
}

usage() {
    cat <<'EOF'
usage: host_witness.sh [interval_sec] [count]   # count 0 = run until killed
       host_witness.sh --self-test              # pure, spawns nothing
       host_witness.sh --help

  interval_sec   number > 0, default 5
  count          non-negative integer, default 0

A log that does not end with a "# end" line was truncated. Do not read the
density of a truncated log as evidence of coverage.
EOF
}
die_arg() { printf 'host_witness: %s\n' "$1" >&2; usage >&2; exit 2; }

case "${1:-}" in
    --self-test) self_test; exit $? ;;
    --help|-h)   usage; exit 0 ;;
    -*)          die_arg "unknown option '$1'" ;;
esac
[ "$#" -le 2 ] || die_arg "expected at most 2 arguments, got $#"

INTERVAL="${1:-5}"
COUNT="${2:-0}"

# ===========================================================================
# 🔴 AN ARGUMENT THAT IS NOT A NUMBER MUST BE REFUSED, NOT ADOPTED.
#
#  2026-09-01, first outside deployment: `--help` was not a recognised option,
#  so it fell through and became the interval. `sleep --help` prints usage and
#  returns immediately -- the witness became a busy loop, sampling as fast as
#  the kernel would answer.
#
#  🔑 The direction is the whole lesson. Sampling density is exactly the
#  quantity a reader uses to argue "continuous accounting" -- the round that
#  hit this documents coverage as "200 samples, no gap > 8 s". So this failure
#  does not make the witness look broken. IT MAKES IT LOOK THOROUGH. A reader
#  checking for gaps cannot catch it, because the error runs the other way.
#
#  The header did print `interval=--helps`. It described the wrong value
#  faithfully and carried on.
#
#      Self-describing output is not a gate. Only refusing is a gate.
#
#  Reported by the 8/29 poster-reviewer line, within an hour of first use,
#  from a real run -- see new-tools-are-the-first-thing-under-test.
# ===========================================================================
case "$INTERVAL" in
    ''|*[!0-9.]*|*.*.*) die_arg "interval must be a number, got '$INTERVAL'" ;;
esac
awk -v v="$INTERVAL" 'BEGIN{exit !(v+0 > 0)}' \
    || die_arg "interval must be greater than 0, got '$INTERVAL'"
case "$COUNT" in
    ''|*[!0-9]*) die_arg "count must be a non-negative integer, got '$COUNT'" ;;
esac

# Backstop for everything the argument check cannot see: sleep failing for any
# other reason, or returning 0 without time having passed. Only bites at
# interval >= 2 s -- below that there is no room to tell a spin from a sample.
MIN_GAP=$(awk -v v="$INTERVAL" 'BEGIN{g=int(v)-1; print (g>0?g:0)}')

SAMPLES=0
END_REASON=killed
# 🔑 A witness that dies mid-window must say so IN THE LOG. The same round that
# found the busy loop also lost a witness after 5 lines (its parent shell was
# reaped) and had to detect it by reading the file twice, six seconds apart.
# With this line, the check is "does the file end with # end" -- and a log
# killed by SIGKILL, which can write nothing, is exactly the one that lacks it.
finish() {
    printf '# end  host=%s  at=%s  samples=%s  interval=%ss  reason=%s\n' \
        "$(hostname)" "$(date -Is)" "$SAMPLES" "$INTERVAL" "$END_REASON"
}
trap finish EXIT
trap 'END_REASON=signal; exit 143' HUP INT TERM

# The header repeats the host, so a file that gets truncated, tailed or pasted
# into a report still carries it. One line of redundancy against the failure
# this whole file is about.
printf '# host_witness  host=%s  started=%s  interval=%ss  count=%s  procfs=%s\n' \
    "$(hostname)" "$(date -Is)" "$INTERVAL" "$COUNT" "$PROCFS"
last=0
while :; do
    now=$(date +%s)
    if [ "$MIN_GAP" -gt 0 ] && [ "$last" != 0 ] && [ "$((now - last))" -lt "$MIN_GAP" ]; then
        END_REASON="cadence-collapsed(gap=$((now - last))s, wanted >=${MIN_GAP}s)"
        exit 4
    fi
    last=$now
    sample
    SAMPLES=$((SAMPLES+1))
    [ "$COUNT" != 0 ] && [ "$SAMPLES" -ge "$COUNT" ] && { END_REASON=complete; break; }
    sleep "$INTERVAL" || { END_REASON="sleep-failed(rc=$?)"; exit 3; }
done
