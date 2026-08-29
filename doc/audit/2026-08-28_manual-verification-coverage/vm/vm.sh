#!/bin/bash
# Manage the clean Ubuntu 24.04 VM used to test the installation manual.
#
# In a script file rather than typed at a prompt on purpose: the start command contains
# strings ("qemu-system-x86_64", the disk path) that a later `pgrep -f` would match against
# this shell's own argv. A script's argv is just its own path.
# [Co-developed with claude code -- Adam]
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$DIR/vm.pid"
MONITOR="$DIR/monitor.sock"
WATCHDOG="$DIR/watchdog.pid"
WATCHLOG="$DIR/watchdog.log"
MEM="${VM_MEM:-6G}"
CPUS="${VM_CPUS:-4}"
SSH_PORT=2222
# Wall-clock ceiling on a single VM lifetime. Deliberately far longer than any real run
# (a section test is ~15 min, a full v8 install was ~45) so it never interrupts work; its
# job is only to bound a VM nobody is watching any more. See the watchdog below.
MAX_SECONDS="${VM_MAX_SECONDS:-7200}"

vm_pid() { [[ -f "$PIDFILE" ]] && cat "$PIDFILE" 2>/dev/null; }
vm_alive() { local p; p="$(vm_pid)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

case "${1:-}" in
  start)
    if vm_alive; then echo "already running (pid $(vm_pid))"; exit 0; fi

    # --- neighbour check -------------------------------------------------------------
    # This VM is invisible to the lab's bookkeeping: it touches no netns, no OVS instance,
    # no .test_run/, and takes no claim -- but 4 vCPU of p4c/grpc compilation competes for
    # CPU, RAM and I/O with whoever is measuring on this host, and nothing tells them.
    #
    # On 2026-08-28 three runs of this script landed inside another session's 35-minute
    # six-arm mirrored block (base Q M M Q base), covering the four treatment arms almost
    # exactly while leaving both base controls comparatively clean. A mirror design cancels
    # monotonic drift; it does not cancel a middle-heavy load that lines up with the
    # treatment. The rule "check who is running before starting the VM" was already written
    # down at the time and was not followed, so it lives here now instead of in a note.
    # [Co-developed with claude code -- Adam]
    CLAIM="${NDT_REPO:-$HOME/Desktop/NDTwin-Kernel}/.test_run/lab.claim"
    echo "--- neighbours on this host ---"
    echo "loadavg:  $(cut -d' ' -f1-3 /proc/loadavg)   (cores: $(nproc))"
    echo "mem avail: $(free -m | awk 'NR==2{print $7" MiB"}')   swap used: $(free -m | awk 'NR==3{print $3" MiB"}')"
    # Read the claim's own exclusive_cpu field rather than inventing a second rule. `ndt claim`
    # writes it (NDT_EXCLUSIVE_CPU=1) and `ndt status` always prints it, so there is exactly one
    # protocol and one place to change it. Refusing on *any* claim would be stricter than the
    # protocol, which sounds safer and is not: I would pass the override every time and the
    # guard would stop meaning anything.
    if [[ -f "$CLAIM" ]]; then
        echo "LAB CLAIM PRESENT:"; sed 's/^/    /' "$CLAIM"
        excl="$(sed -n 's/^exclusive_cpu=//p' "$CLAIM" | tr -d '[:space:]')"
        case "$excl" in
          yes)
            if [[ "${VM_ACK_EXCLUSIVE_CPU:-}" != "yes" ]]; then
                echo
                echo "REFUSING to start: this claim declares exclusive_cpu=yes."
                echo "A 4-vCPU build competes for CPU, RAM and I/O and appears in none of the"
                echo "claim holder's instruments -- no fabric, no build, no binary touched."
                echo "Ask them first. If they agree, re-run with VM_ACK_EXCLUSIVE_CPU=yes."
                exit 1
            fi
            echo "VM_ACK_EXCLUSIVE_CPU=yes -- claim holder has agreed; proceeding." ;;
          no|"")
            echo "  -> exclusive_cpu is not set: starting is allowed, but TELL THEM. A heavy"
            echo "     build still perturbs anything they are timing, and they cannot see it." ;;
          *)
            echo "  -> exclusive_cpu='$excl' is not a value this script understands; treating as yes."
            [[ "${VM_ACK_EXCLUSIVE_CPU:-}" == "yes" ]] || { echo "REFUSING."; exit 1; } ;;
        esac
    else
        echo "lab claim: none"
    fi
    echo "-------------------------------"

    # --- do not clobber a live VM whose pidfile went missing --------------------------
    # vm_alive above trusts $PIDFILE and nothing else. Lose that file -- a crash, a manual
    # rm, a test that hides it -- and the next `start` walks straight into the two lines
    # below and deletes the MONITOR SOCKET of a VM that is still running. That is not
    # hypothetical: on 2026-08-28 it removed the socket of a *paused* VM, and since a unix
    # socket binds its name at creation, recreating the file does not rebind it. The VM kept
    # listening on an unlinked inode, `cont` could never be delivered, and the only way out
    # was to kill it and redo the run.
    #
    # The qcow2 write lock is the authoritative answer to "is a VM using this image", and
    # unlike a pidfile it cannot drift out of sync with reality.
    # [Co-developed with claude code -- Adam]
    # Distinguish "locked by a live VM" from "unreadable for some other reason" -- an absent
    # or corrupt image fails this command too, and reporting that as a lock would send the
    # next reader hunting for a process that does not exist.
    imgerr="$(qemu-img info "$DIR/disk.qcow2" 2>&1 >/dev/null)"; imgrc=$?
    if [[ $imgrc -ne 0 ]] && ! grep -qi 'lock' <<<"$imgerr"; then
        echo "REFUSING to start: cannot read $DIR/disk.qcow2, and the reason is not a lock:"
        echo "    $imgerr"
        exit 1
    fi
    if [[ $imgrc -ne 0 ]]; then
        echo "REFUSING to start: something still holds a lock on disk.qcow2, so a VM is"
        echo "using this image even though $PIDFILE says otherwise. Find it with:"
        echo "    sudo ss -xlp | grep monitor.sock"
        echo "    for p in /proc/[0-9]*; do ls -l \$p/fd 2>/dev/null | grep -q disk.qcow2 && echo \${p#/proc/}; done"
        echo "Shut that VM down before starting a new one -- continuing would delete its"
        echo "monitor socket and leave it unreachable."
        exit 1
    fi

    # --- dry run: exercise every check above WITHOUT the side effect ------------------
    # Testing the refuse path is safe, because its side effect is "no side effect". Testing
    # the ALLOW path by actually running `start` performs the very thing the guard exists to
    # gate. On 2026-08-28 that is exactly what happened: verifying the allow branch started a
    # VM inside a neighbour's measurement window, and the same run's `rm -f "$MONITOR"` below
    # destroyed a paused VM's control channel. Both were caused by the test, not the guard.
    # VM_DRY_RUN=1 stops here, after all the checks and before anything is created or removed.
    # [Co-developed with claude code -- Adam]
    if [[ "${VM_DRY_RUN:-}" == "1" ]]; then
        echo "DRY RUN: all pre-start checks passed; stopping before touching $PIDFILE,"
        echo "         $MONITOR, or launching qemu. Nothing was created, removed or started."
        exit 0
    fi

    rm -f "$PIDFILE" "$MONITOR"
    qemu-system-x86_64 \
      -enable-kvm -m "$MEM" -smp "$CPUS" \
      -drive file="$DIR/disk.qcow2",if=virtio \
      -drive file="$DIR/seed.img",if=virtio,format=raw \
      -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22 \
      -device virtio-net,netdev=n0 \
      -monitor unix:"$MONITOR",server,nowait \
      -pidfile "$PIDFILE" \
      -display none -daemonize
    sleep 2
    if ! vm_alive; then echo "FAILED to start"; exit 1; fi
    started_pid="$(vm_pid)"
    echo "started (pid $started_pid), ssh on :$SSH_PORT, mem $MEM, $CPUS vcpu"

    # --- the VM carries its own deadline ----------------------------------------------
    # Cleanup that depends on the parent staying alive is not cleanup. On 2026-08-28 a
    # neighbouring session's `trap ... EXIT` failed to fire when its driver was killed by
    # `timeout`, leaving ten CPU burners running -- and `trap EXIT` is blind to SIGKILL,
    # which is precisely the signal `timeout` ends with. So the guard was absent in the one
    # situation that needed it. This script had the same hole in a slower form: qemu is
    # started with -daemonize, so it outlives whatever launched it, and a driver killed
    # mid-run leaves 4 vCPU burning inside a neighbour's window with nobody watching.
    #
    # The fix is theirs: give the child its own deadline instead of inferring one from the
    # parent. `timeout` cannot wrap a -daemonize'd process (it would exit the moment qemu
    # forks), so the deadline is a detached watchdog. setsid, so killing this script's
    # process group does not take it with us -- surviving the parent IS the requirement.
    #
    # It re-reads the pidfile before acting and refuses unless it still names the same pid,
    # so a watchdog left over from an earlier VM can never shut down a later one. It writes
    # what it did to watchdog.log, because "the VM disappeared" has to be distinguishable
    # from "the VM crashed" afterwards.
    # [Co-developed with claude code -- Adam]
    setsid nohup bash -c '
        sleep "$1"
        [[ "$(cat "$2" 2>/dev/null)" == "$4" ]] || exit 0   # a different VM owns it now
        kill -0 "$4" 2>/dev/null || exit 0                  # already gone: nothing to do
        echo "$(date -Is)  deadline of $1s reached; shutting down pid $4" >> "$5"
        if [[ -S "$3" ]] && command -v socat >/dev/null; then
            echo system_powerdown | socat - UNIX-CONNECT:"$3" >/dev/null 2>&1 || true
        fi
        for _ in $(seq 1 60); do kill -0 "$4" 2>/dev/null || break; sleep 1; done
        if kill -0 "$4" 2>/dev/null; then
            echo "$(date -Is)  did not stop gracefully; SIGKILL $4" >> "$5"
            kill -9 "$4" 2>/dev/null || true
        fi
        echo "$(date -Is)  watchdog done" >> "$5"
    ' _ "$MAX_SECONDS" "$PIDFILE" "$MONITOR" "$started_pid" "$WATCHLOG" >/dev/null 2>&1 &
    echo "$!" > "$WATCHDOG"
    echo "watchdog $(cat "$WATCHDOG") will stop this VM after ${MAX_SECONDS}s if nobody else does" ;;

  stop)
    # ACPI shutdown, then VERIFY the process is gone. A "stopped" that leaves the process
    # running is the failure this repo keeps re-finding, so the exit code reflects the
    # process table, not the fact that a request was sent.
    #
    # Retire the watchdog first, and unconditionally -- including on the "not running" path,
    # because that is exactly the case where a stale one is most likely to be sitting there.
    # It is harmless if it survives (it re-checks the pidfile), but a sleeping process whose
    # purpose has passed is the kind of thing that later gets mistaken for a live guard.
    if [[ -f "$WATCHDOG" ]]; then
        wpid="$(cat "$WATCHDOG" 2>/dev/null)"
        if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
            kill "$wpid" 2>/dev/null || true
            echo "retired watchdog $wpid"
        fi
        rm -f "$WATCHDOG"
    fi
    if ! vm_alive; then echo "not running"; rm -f "$PIDFILE"; exit 0; fi
    target="$(vm_pid)"
    if [[ -S "$MONITOR" ]] && command -v socat >/dev/null; then
        echo "system_powerdown" | socat - UNIX-CONNECT:"$MONITOR" >/dev/null 2>&1 || true
    else
        echo "(no monitor socket; sending SIGTERM instead)"
        kill -TERM "$target" 2>/dev/null || true
    fi
    for i in $(seq 1 60); do kill -0 "$target" 2>/dev/null || break; sleep 1; done
    if kill -0 "$target" 2>/dev/null; then
        echo "graceful shutdown did not finish in 60s -- sending SIGTERM to $target"
        kill -TERM "$target" 2>/dev/null || true
        for i in $(seq 1 15); do kill -0 "$target" 2>/dev/null || break; sleep 1; done
    fi
    if kill -0 "$target" 2>/dev/null; then
        echo "STILL RUNNING as pid $target -- not claiming it stopped"; exit 1
    fi
    rm -f "$PIDFILE"; echo "stopped" ;;

  status)
    if vm_alive; then echo "running (pid $(vm_pid))"; else echo "not running"; fi
    qemu-img snapshot -l "$DIR/disk.qcow2" 2>/dev/null ;;

  snap)   # snap <name> -- VM must be OFF
    if vm_alive; then echo "REFUSING: stop the VM first (snapshots of a live disk are inconsistent)"; exit 1; fi
    qemu-img snapshot -c "${2:?usage: vm.sh snap <name>}" "$DIR/disk.qcow2" && echo "snapshot '$2' taken" ;;

  restore)
    if vm_alive; then echo "REFUSING: stop the VM first"; exit 1; fi
    qemu-img snapshot -a "${2:?usage: vm.sh restore <name>}" "$DIR/disk.qcow2" && echo "restored to '$2'" ;;

  *) echo "usage: vm.sh start|stop|status|snap <name>|restore <name>"; exit 2 ;;
esac
