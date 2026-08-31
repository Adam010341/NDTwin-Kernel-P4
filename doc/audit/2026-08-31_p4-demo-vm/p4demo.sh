#!/bin/bash
# Boot the P4 demo image that is being prepared for distribution.
#
# Separate from vm.sh on purpose. vm.sh drives disk.qcow2 -- the clean-room instrument whose
# snapshot chain every manual-verification result is anchored to. This one drives a *product*:
# a standalone, flattened copy that will leave this machine as an .ova. Mixing them would make
# "which image produced this result" a question, and that question has cost this project a
# round before.
#
# Two deliberate differences from vm.sh, both because this image is the thing readers get:
#   1. NO seed.img. The .ova ships one disk. If the guest cannot boot and log in without the
#      cloud-init seed, the shipped VM is broken, and attaching the seed here would hide it.
#   2. -cpu host. vm.sh leaves qemu's default (qemu64), which lacks x86-64-v2, so every
#      numpy-shaped runtime fails inside it -- a property of the instrument, not the software
#      (see doc/audit/2026-08-28_manual-verification-coverage/). A reader on VMware gets their
#      real CPU, so verifying this image on qemu64 would test a machine nobody will run.
#      This is a new script on a new image, so no earlier result changes ruler.
#
# In a script file, not typed at a prompt: the qemu command line contains strings a later
# `ps | grep` would match against the invoking shell's own argv.
# [Co-developed with claude code -- Adam]
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
IMG="${P4DEMO_IMG:-$DIR/ndtwin-p4-demo-work.qcow2}"
PIDFILE="$DIR/p4demo.pid"
MONITOR="$DIR/p4demo-monitor.sock"
WATCHDOG="$DIR/p4demo-watchdog.pid"
WATCHLOG="$DIR/p4demo-watchdog.log"
MEM="${P4DEMO_MEM:-6G}"
CPUS="${P4DEMO_CPUS:-4}"
SSH_PORT="${P4DEMO_SSH_PORT:-2223}"   # not 2222: vm.sh's VM must be able to coexist
MAX_SECONDS="${P4DEMO_MAX_SECONDS:-14400}"

vm_pid() { [[ -f "$PIDFILE" ]] && cat "$PIDFILE" 2>/dev/null; }
vm_alive() { local p; p="$(vm_pid)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

case "${1:-}" in
  start)
    if vm_alive; then echo "already running (pid $(vm_pid))"; exit 0; fi

    # The qcow2 write lock is the authoritative "is a VM using this image", unlike a pidfile
    # which drifts. Distinguish a lock from an unreadable image: an absent or corrupt file
    # fails this command too, and calling that a lock sends the reader hunting for a process
    # that does not exist.
    imgerr="$(qemu-img info "$IMG" 2>&1 >/dev/null)"; imgrc=$?
    if [[ $imgrc -ne 0 ]] && ! grep -qi 'lock' <<<"$imgerr"; then
        echo "REFUSING: cannot read $IMG, and not because of a lock:"; echo "    $imgerr"; exit 1
    fi
    if [[ $imgrc -ne 0 ]]; then
        echo "REFUSING: something holds a lock on $IMG -- a VM is using it. Find it with:"
        echo "    for p in /proc/[0-9]*; do ls -l \$p/fd 2>/dev/null | grep -q \$(basename $IMG) && echo \${p#/proc/}; done"
        exit 1
    fi

    echo "--- host ---"
    echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)   cores: $(nproc)"
    CLAIM="${NDT_REPO:-$HOME/Desktop/NDTwin-Kernel}/.test_run/lab.claim"
    if [[ -f "$CLAIM" ]]; then echo "LAB CLAIM PRESENT:"; sed 's/^/    /' "$CLAIM"; else echo "lab claim: none"; fi
    echo "image:   $IMG"
    echo "------------"

    if [[ "${P4DEMO_DRY_RUN:-}" == "1" ]]; then
        echo "DRY RUN: checks passed; nothing created, removed or started."; exit 0
    fi

    rm -f "$PIDFILE" "$MONITOR"
    qemu-system-x86_64 \
      -enable-kvm -cpu host -m "$MEM" -smp "$CPUS" \
      -drive file="$IMG",if=virtio,discard=unmap,detect-zeroes=unmap \
      -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22 \
      -device virtio-net,netdev=n0 \
      -monitor unix:"$MONITOR",server,nowait \
      -pidfile "$PIDFILE" \
      -display none -daemonize
    sleep 2
    if ! vm_alive; then echo "FAILED to start"; exit 1; fi
    started_pid="$(vm_pid)"
    echo "started (pid $started_pid), ssh on :$SSH_PORT, mem $MEM, $CPUS vcpu, -cpu host, NO seed disk"

    # The VM carries its own deadline: -daemonize means it outlives whatever launched it, so
    # a driver killed mid-run would otherwise leave 4 vCPU burning with nobody watching.
    # setsid, because surviving the parent is the requirement. It re-reads the pidfile and
    # refuses unless it still names the same pid, so a stale watchdog cannot shut down a
    # later VM.
    setsid nohup bash -c '
        sleep "$1"
        [[ "$(cat "$2" 2>/dev/null)" == "$4" ]] || exit 0
        kill -0 "$4" 2>/dev/null || exit 0
        echo "$(date -Is)  deadline of $1s reached; shutting down pid $4" >> "$5"
        if [[ -S "$3" ]] && command -v socat >/dev/null; then
            echo system_powerdown | socat - UNIX-CONNECT:"$3" >/dev/null 2>&1 || true
        fi
        for _ in $(seq 1 60); do kill -0 "$4" 2>/dev/null || break; sleep 1; done
        kill -0 "$4" 2>/dev/null && { echo "$(date -Is)  SIGKILL $4" >> "$5"; kill -9 "$4" 2>/dev/null; }
        echo "$(date -Is)  watchdog done" >> "$5"
    ' _ "$MAX_SECONDS" "$PIDFILE" "$MONITOR" "$started_pid" "$WATCHLOG" >/dev/null 2>&1 &
    echo "$!" > "$WATCHDOG"
    echo "watchdog $(cat "$WATCHDOG") stops it after ${MAX_SECONDS}s if nobody else does" ;;

  stop)
    # ACPI shutdown, then verify against the process table. A "stopped" that leaves the
    # process running is the failure this repo keeps re-finding, so the exit code reflects
    # what is true, not that a request was sent. A clean ACPI shutdown also matters more here
    # than in vm.sh: this image is about to be packaged, and an unclean filesystem ships.
    if [[ -f "$WATCHDOG" ]]; then
        wpid="$(cat "$WATCHDOG" 2>/dev/null)"
        [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null && { kill "$wpid" 2>/dev/null; echo "retired watchdog $wpid"; }
        rm -f "$WATCHDOG"
    fi
    if ! vm_alive; then echo "not running"; rm -f "$PIDFILE"; exit 0; fi
    target="$(vm_pid)"
    if [[ -S "$MONITOR" ]] && command -v socat >/dev/null; then
        echo "system_powerdown" | socat - UNIX-CONNECT:"$MONITOR" >/dev/null 2>&1 || true
    else
        echo "(no monitor socket; SIGTERM instead)"; kill -TERM "$target" 2>/dev/null || true
    fi
    for i in $(seq 1 90); do kill -0 "$target" 2>/dev/null || break; sleep 1; done
    if kill -0 "$target" 2>/dev/null; then
        echo "STILL RUNNING as pid $target -- not claiming it stopped"; exit 1
    fi
    rm -f "$PIDFILE"; echo "stopped cleanly" ;;

  status)
    if vm_alive; then echo "running (pid $(vm_pid)) ssh :$SSH_PORT"; else echo "not running"; fi
    qemu-img info -U "$IMG" 2>/dev/null | head -4 ;;

  *) echo "usage: p4demo.sh start|stop|status"; exit 2 ;;
esac
