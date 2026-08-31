#!/usr/bin/env bash
# ndtwin-vm.sh -- one NDTwin lab VM on a lab machine, with no host root at all.
# [Co-developed with claude code -- Adam]
#
#   ndtwin-vm.sh create           fetch cloud image, build seed, make the disk
#   ndtwin-vm.sh start            boot it (daemonised, survives ssh disconnect)
#   ndtwin-vm.sh stop             graceful shutdown, wait for the process to go
#   ndtwin-vm.sh status           pid / port / disk / snapshots / guest reachability
#   ndtwin-vm.sh ssh [cmd...]     run a command in the guest (or open a shell)
#   ndtwin-vm.sh snap <name>      stop if needed, snapshot, restore prior run state
#   ndtwin-vm.sh restore <name>   roll back to a snapshot
#   ndtwin-vm.sh snaps            list snapshots
#   ndtwin-vm.sh vms              EVERY lab VM on this host: dir / owner / port / pid
#   ndtwin-vm.sh destroy          delete the disk (asks for the magic word)
#
# 🔑 NDT_OWNER is REQUIRED for anything that mutates a VM (same rule as every ndt
# command). One VM per session: VM_DIR and SSH_PORT are both env vars and both
# MUST differ between sessions -- see the coordination block below for why.
#
# Why plain qemu and not libvirt: one less root daemon on a shared lab box.
# Why user-mode (SLIRP) networking: the guest gets outbound NAT and NO layer-2
# presence on 10.10.10.0/24, without needing root to make a tap device.
#
# 🔑 Acceptance is read off STATE (pid alive, ssh answers, snapshot listed), never
# off an exit code -- qemu -daemonize returns 0 long before the guest is usable.
set -uo pipefail

VM_DIR="${VM_DIR:-$HOME/ndtwin-vm}"
IMG="$VM_DIR/disk.qcow2"
SEED="$VM_DIR/seed.iso"
PIDF="$VM_DIR/qemu.pid"
LOG="$VM_DIR/qemu.log"
MON="$VM_DIR/monitor.sock"
BASE="$VM_DIR/noble-base.img"
CLOUD_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

OWNERF="$VM_DIR/OWNER"
CFG="$VM_DIR/CONFIG"

# 🔴 The working point must live WITH the VM, not in whichever shell happens to start
# it. 2026-08-31, first hand: a stop → snap → start cycle that did not re-pass
# VM_CPUS/VM_MEM brought a 16 vCPU / 16 GiB lab back up as 12 / 8192 -- the built-in
# defaults. Nothing failed, nothing warned, the guest booted perfectly. Every number
# measured after that point would have come from a different machine than the ones
# before it, with no artifact anywhere recording the change.
# ⇒ env var (explicit intent) > CONFIG (what this VM has been running as) > built-in.
cfg_get() { [ -f "$CFG" ] && awk -F= -v k="$1" '$1==k{print $2; exit}' "$CFG" || true; }

if   [ -n "${VM_CPUS:-}${VM_MEM:-}" ]; then WP_SRC="env（顯式指定）"
elif [ -f "$CFG" ];                   then WP_SRC="CONFIG（這顆 VM 上次跑的工作點）"
else                                       WP_SRC="built-in default"; fi

VM_USER="${VM_USER:-ndt}"
VM_CPUS="${VM_CPUS:-$(cfg_get cpus)}"; VM_CPUS="${VM_CPUS:-12}"
VM_MEM="${VM_MEM:-$(cfg_get mem)}";    VM_MEM="${VM_MEM:-8192}"
VM_DISK="${VM_DISK:-$(cfg_get disk)}"; VM_DISK="${VM_DISK:-120G}"
SSH_PORT="${SSH_PORT:-$(cfg_get port)}"; SSH_PORT="${SSH_PORT:-2222}"

cfg_write() {
    mkdir -p "$VM_DIR"
    printf 'cpus=%s\nmem=%s\ndisk=%s\nport=%s\n' \
        "$VM_CPUS" "$VM_MEM" "$VM_DISK" "$SSH_PORT" > "$CFG"
}

say() { printf '%s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

vm_pid() { [ -f "$PIDF" ] && head -1 "$PIDF" 2>/dev/null || true; }

vm_running() {
    local p; p=$(vm_pid)
    [ -n "$p" ] || return 1
    # Read /proc directly: kill -0 cannot tell "gone" from "not yours", and a stale
    # pidfile whose number got recycled would answer yes to the wrong question.
    [ -r "/proc/$p/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$p/cmdline" | grep -q "$IMG"
}

guest_ready() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=4 -p "$SSH_PORT" "$VM_USER@127.0.0.1" true 2>/dev/null
}

# ------------------------------------------------------------------ coordination
# Several Claude sessions share ONE unix account on the lab host, so the filesystem
# is the only medium they can coordinate through. This block is that medium.
#
# 🔴 Written after the accident it prevents (2026-08-31): two sessions ran inside the
# SAME disk.qcow2, discovered only because snapshots appeared that nobody present had
# taken. Mechanism, and it is entirely mundane: VM_DIR and SSH_PORT have independent
# defaults, so a session that sets neither silently lands on top of another one.
#
# Three design choices, each paid for:
#
#  1. The claim lives IN the VM directory, not in a central index. A central index can
#     disagree with what is on disk; a file beside the disk cannot. `vms` enumerates by
#     globbing directories, so a VM that never claimed still SHOWS UP as unowned rather
#     than being invisible.
#  2. Ownership and occupancy are separate readings -- the lab-claim lesson, restated:
#     OWNER says whose it is, the pid says whether anything is running. Never infer one
#     from the other.
#  3. No env-var override for a foreign claim beyond one that LOGS ITSELF into the very
#     file it overrode. A bypass nobody can see is not a guard.
#
# 🔑 Sharing the HOST is fine (28 cores hold several VMs, and the Mininet netns / OVS
# datapath conflicts that force one-lab-at-a-time are per-KERNEL). Sharing a VM is not:
# a qcow2 snapshot is global mutable state on that disk with no notion of an owner, so
# one `restore` silently replaces everybody's work.

me() { printf '%s' "${NDT_OWNER:-unset}"; }

owner_of() {  # owner_of <vmdir> -> the claimant, or "unowned"
    local f="$1/OWNER"
    [ -f "$f" ] && awk '/^owner:/{print $2; exit}' "$f" || printf 'unowned'
}

port_of() { local f="$1/OWNER"; [ -f "$f" ] && awk '/^port:/{print $2; exit}' "$f" || printf '?'; }

# Is the pid in <vmdir>'s pidfile actually THAT dir's qemu? Same /proc test as
# vm_running, generalised: a recycled pid must not be able to answer yes.
dir_pid() {
    local d="$1" p
    p=$(head -1 "$d/qemu.pid" 2>/dev/null) || return 1
    [ -n "$p" ] && [ -r "/proc/$p/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$p/cmdline" | grep -q "$d/disk.qcow2" || return 1
    printf '%s' "$p"
}

claim_guard() {  # claim_guard <verb> -- call before anything that mutates this VM
    local who cur
    who=$(me)
    # Fails CLOSED. Writing "unset" into the registry and calling it coordination
    # would be a gate that can never go red.
    [ "$who" = unset ] && die "NDT_OWNER is not set -- refusing to touch $VM_DIR.
   Every VM on a shared host must name the session that owns it:
       NDT_OWNER=<session> $0 $1
   (same rule as every ndt command; see CLAUDE.md)"

    if [ -f "$OWNERF" ]; then
        cur=$(owner_of "$VM_DIR")
        if [ "$cur" != "$who" ]; then
            say "🔴 REFUSED -- $VM_DIR belongs to another session:"
            sed 's/^/     /' "$OWNERF"
            say ""
            say "   Do NOT share a VM. Snapshots on that disk have no owner, so a"
            say "   restore replaces everyone's state with no warning (08-31, first hand)."
            say ""
            say "   Take your own instead:"
            say "       NDT_OWNER=$who VM_DIR=\$HOME/ndtwin-vm-$who SSH_PORT=<free> $0 create"
            say "   See what is already taken:   $0 vms"
            say ""
            say "   If you KNOW it is abandoned:  NDTVM_FORCE=1 (the override writes itself"
            say "   into the OWNER file, so the next reader sees that it happened)"
            [ "${NDTVM_FORCE:-0}" = 1 ] || exit 3
            say "   ⚠️  NDTVM_FORCE=1 -- proceeding and recording the override."
            printf 'FORCED: %s took this from %s at %s (verb: %s)\n' \
                "$who" "$cur" "$(date -Is)" "$1" >> "$OWNERF"
        fi
    fi
}

claim_write() {  # record the claim; called once the VM dir really exists
    mkdir -p "$VM_DIR"
    if [ ! -f "$OWNERF" ]; then
        printf 'owner: %s\nsince: %s\nport:  %s\nnote:  %s\n' \
            "$(me)" "$(date -Is)" "$SSH_PORT" "${VM_NOTE:-（未填 -- 用 VM_NOTE= 說明用途）}" \
            > "$OWNERF"
    else
        # Ownership unchanged, but the port can move between runs and a stale port in
        # the registry is worse than none: it is what the next session will avoid.
        local tmp; tmp=$(mktemp)
        awk -v p="$SSH_PORT" '/^port:/{print "port:  " p; next} {print}' "$OWNERF" > "$tmp" \
            && mv "$tmp" "$OWNERF"
    fi
}

snaps_list() {
    # 🔴 The single most expensive line this script has had. The old version was
    #     qemu-img snapshot -l "$IMG" 2>/dev/null || say "(no disk or no snapshots)"
    # and `qemu-img snapshot -l` FAILS while qemu holds the image lock. So a running
    # VM printed "no snapshots" -- and on 2026-08-31 another session read that, believed
    # the disk was bare, and created a second snapshot tagged `fresh`. qemu-img allows
    # duplicate tags silently, so there are now two different `fresh` on that disk.
    #
    # Two fixes, and the second matters more than the first:
    #   -U (force-share) actually reads the list while the VM runs.
    #   "could not read" and "there are none" are printed as DIFFERENT things. Collapsing
    #   them is what turned a lock into a false fact -- see memory/failures-that-report-
    #   success: the report was not an error, it was a confident wrong answer.
    local out rc
    [ -f "$IMG" ] || { say "  🔴 no disk at $IMG"; return 1; }
    out=$(qemu-img snapshot -l -U "$IMG" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        say "  🔴 COULD NOT READ the snapshot list -- this is NOT the same as 'there are none'."
        printf '%s\n' "$out" | sed 's/^/     /'
        say "     Do not create a snapshot on the assumption that the disk is empty."
        return 1
    fi
    if [ "$(printf '%s\n' "$out" | sed '1d' | grep -c .)" -eq 0 ]; then
        say "  (none -- read successfully, the disk really has no snapshots)"
    else
        printf '%s\n' "$out" | sed 's/^/  /'
        # Duplicate tags are legal and silent; say so at the moment of reading.
        printf '%s\n' "$out" | sed '1d' | awk '{print $2}' | sort | uniq -d | while read -r d; do
            [ -n "$d" ] && say "  🔴 DUPLICATE TAG '$d' -- restore is ambiguous and qemu-img will not warn."
        done
    fi
}

port_guard() {
    # The actual collision mechanism, not a hypothetical: change VM_DIR and forget
    # SSH_PORT and you get your own disk on somebody else's forwarded port -- qemu
    # then either fails to bind, or `$0 ssh` quietly reaches THEIR guest.
    ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q . || return 0
    say "🔴 REFUSED -- 127.0.0.1:$SSH_PORT is already listening."
    say "   Whoever holds it:"
    for d in "$HOME"/ndtwin-vm*/; do
        [ -d "$d" ] && [ "$(port_of "${d%/}")" = "$SSH_PORT" ] \
            && say "     $d  owner=$(owner_of "${d%/}")"
    done
    say "   Pick a free one:  SSH_PORT=$((SSH_PORT + 1)) ... ($0 vms shows what is taken)"
    exit 4
}

case "${1:-}" in

create)
    claim_guard create
    mkdir -p "$VM_DIR" || die "cannot make $VM_DIR"
    claim_write
    cfg_write
    command -v qemu-img >/dev/null || die "qemu-img missing -- run ndtwin-virt-root.sh first"
    command -v cloud-localds >/dev/null || die "cloud-localds missing -- run ndtwin-virt-root.sh first"
    [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm not accessible -- are you in group kvm? (needs a NEW login)"

    # TWO keys go in, and both are load-bearing:
    #   1. whatever is in ~/.ssh/authorized_keys -- the operator's laptop key, so a
    #      human reaches the guest with:  ssh -J <thishost> -p 2222 ndt@127.0.0.1
    #   2. a key belonging to THIS host -- without it nothing running ON the host can
    #      ssh into its own guest.
    # 🔴 The first version injected only (1), which made guest_ready() a gate that
    # could never go green: the host has no private key for the operator's laptop key,
    # so the readiness probe would have failed for 900s on a perfectly healthy VM.
    [ -f "$HOME/.ssh/id_ed25519" ] || ssh-keygen -t ed25519 -N '' -q -f "$HOME/.ssh/id_ed25519"
    KEYS=$( { grep -h '^ssh-' "$HOME/.ssh/authorized_keys" 2>/dev/null
              cat "$HOME/.ssh/id_ed25519.pub"; } | sort -u )
    [ -n "$KEYS" ] || die "no public keys to inject"
    printf 'injecting %d key(s):\n' "$(printf '%s\n' "$KEYS" | wc -l)"
    printf '%s\n' "$KEYS" | awk '{printf "  %s ...%s\n", $1, substr($2,length($2)-11)}'

    if [ ! -f "$BASE" ]; then
        say "--- fetching Ubuntu 24.04 cloud image (~600 MB) ---"
        curl -fL --progress-bar -o "$BASE.part" "$CLOUD_URL" || die "download failed"
        mv "$BASE.part" "$BASE"
    else
        say "--- base image already present, reusing ---"
    fi
    say "base: $(ls -lh "$BASE" | awk '{print $5}')  $BASE"

    say "--- building cloud-init seed ---"
    cat > "$VM_DIR/user-data" <<EOF
#cloud-config
hostname: ndtwin-lab-vm
users:
  - name: $VM_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
$(printf '%s\n' "$KEYS" | sed 's/^/      - /')
ssh_pwauth: false
package_update: false
runcmd:
  # DELIBERATE DEVIATION, recorded so it is never mistaken for a test result:
  # the install manual uses ~/Desktop 13 times but never creates it (finding M-1).
  # We create it here so the build can proceed. This means this VM does NOT
  # re-test M-1 -- it works around it.
  - [ mkdir, -p, "/home/$VM_USER/Desktop" ]
  - [ chown, "$VM_USER:$VM_USER", "/home/$VM_USER/Desktop" ]
  - [ sh, -c, "echo 'ndtwin-lab VM ready' > /home/$VM_USER/CLOUD_INIT_DONE" ]
EOF
    printf 'instance-id: ndtwin-lab-vm\nlocal-hostname: ndtwin-lab-vm\n' > "$VM_DIR/meta-data"
    cloud-localds "$SEED" "$VM_DIR/user-data" "$VM_DIR/meta-data" || die "cloud-localds failed"

    say "--- creating $VM_DISK overlay-free copy of the base image ---"
    # A full copy, not a backing file: snapshots and rollbacks stay self-contained,
    # and a corrupted base cannot silently poison an existing lab.
    cp --reflink=auto "$BASE" "$IMG" || die "copy failed"
    qemu-img resize "$IMG" "$VM_DISK" || die "resize failed"

    say
    say "=== ACCEPTANCE ==="
    printf '  disk:  %s\n' "$(qemu-img info "$IMG" | awk -F': ' '/virtual size/{print $2}')"
    printf '  seed:  %s\n' "$([ -f "$SEED" ] && echo present || echo MISSING)"
    printf '  keys:  %s injected (operator laptop + this host)\n' "$(printf '%s\n' "$KEYS" | wc -l)"
    say "  next: $0 start"
    ;;

start)
    [ -f "$IMG" ] || die "no disk -- run: $0 create"
    claim_guard start
    if vm_running; then say "already running (pid $(vm_pid))"; exit 0; fi
    # Order matters: the vm_running check above must come first, or restarting your
    # OWN stopped VM would trip port_guard on a port you are about to reuse.
    port_guard
    claim_write
    # 🔴 Loud, because the failure it guards against is silent: an existing lab that
    # comes back up on built-in defaults is a DIFFERENT machine, and nothing else in
    # the system will ever say so.
    if [ "$WP_SRC" = "built-in default" ] && [ -s "$IMG" ]; then
        say "⚠️  這顆 VM 已經存在，但工作點來自 built-in default（${VM_CPUS} vCPU / ${VM_MEM} MiB）。"
        say "    上一次是多少沒有紀錄（沒有 $CFG）⇒ 它可能正被無聲地縮小或放大。"
        say "    要固定就顯式指定一次：VM_CPUS=… VM_MEM=… $0 start（之後會記住）"
    fi
    cfg_write
    rm -f "$PIDF" "$MON"
    mkdir -p "$VM_DIR"
    say "--- booting: ${VM_CPUS} vCPU, ${VM_MEM}MiB, ssh on 127.0.0.1:${SSH_PORT} ---"
    say "    工作點來源: $WP_SRC   （記在 $CFG）"
    # setsid so the VM outlives this ssh session; -daemonize so we get the shell back.
    setsid qemu-system-x86_64 \
        -name ndtwin-lab-vm \
        -machine q35,accel=kvm -cpu host \
        -smp "$VM_CPUS" -m "$VM_MEM" \
        -drive "file=$IMG,if=virtio,format=qcow2" \
        -drive "file=$SEED,if=virtio,format=raw,readonly=on" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=n0 \
        -display none -serial "file:$LOG" \
        -monitor "unix:$MON,server,nowait" \
        -pidfile "$PIDF" -daemonize \
        || die "qemu failed to launch (see above)"

    say "--- waiting for the guest to answer ssh (state, not exit code) ---"
    for i in $(seq 1 90); do
        if guest_ready; then
            say "  guest reachable after ${i}0s"
            say "=== ACCEPTANCE ==="
            printf '  qemu pid: %s\n' "$(vm_pid)"
            ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -p "$SSH_PORT" "$VM_USER@127.0.0.1" \
                'echo "  guest: $(. /etc/os-release; echo $PRETTY_NAME) kernel $(uname -r)"
                 echo "  cpus:  $(nproc)   mem: $(free -g | awk "/^Mem:/{print \$2}")Gi"
                 echo "  disk:  $(df -h / | awk "NR==2{print \$4}") free"
                 echo "  cloud-init marker: $([ -f ~/CLOUD_INIT_DONE ] && echo present || echo MISSING)"'
            exit 0
        fi
        sleep 10
    done
    say "🔴 guest did not answer ssh within 900s."
    say "   qemu alive: $(vm_running && echo yes || echo NO)"
    say "   serial log tail:"; tail -20 "$LOG" 2>/dev/null | sed 's/^/     /'
    exit 1
    ;;

stop)
    if ! vm_running; then say "not running"; rm -f "$PIDF"; exit 0; fi
    p=$(vm_pid)
    say "--- graceful shutdown (pid $p) ---"
    guest_ready && ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" "$VM_USER@127.0.0.1" 'sudo systemctl poweroff' 2>/dev/null
    for i in $(seq 1 60); do vm_running || { say "  stopped after ${i}s"; rm -f "$PIDF"; exit 0; }; sleep 1; done
    say "  still up after 60s; sending SIGTERM to qemu (guest state may be dirty)"
    kill -TERM "$p" 2>/dev/null
    for i in $(seq 1 20); do vm_running || { say "  stopped"; rm -f "$PIDF"; exit 0; }; sleep 1; done
    say "🔴 qemu pid $p will not die -- do NOT snapshot; investigate."
    exit 1
    ;;

status)
    say "=== ndtwin-vm status  $(date -Is) ==="
    printf '  owner:  %s   port %s\n' "$(owner_of "$VM_DIR")" "$SSH_PORT"
    # Printed here so a silent downgrade is visible without anyone thinking to look:
    # the recorded working point is what the next `start` will actually use.
    printf '  work point: %s vCPU / %s MiB   (source: %s)\n' "$VM_CPUS" "$VM_MEM" "$WP_SRC"
    [ -f "$CFG" ] || printf '  🔴 no %s -- the next start falls back to built-in defaults\n' "$CFG"
    if vm_running; then
        p=$(vm_pid)
        printf '  qemu:   RUNNING pid %s, up %s\n' "$p" "$(ps -o etime= -p "$p" | tr -d ' ')"
        printf '  guest:  %s\n' "$(guest_ready && echo 'ssh answering' || echo 'NOT answering ssh')"
    else
        printf '  qemu:   not running\n'
    fi
    [ -f "$IMG" ] && printf '  disk:   %s on disk, %s virtual\n' \
        "$(du -h "$IMG" | cut -f1)" "$(qemu-img info "$IMG" | awk -F': ' '/virtual size/{print $2}')" \
        || printf '  disk:   ABSENT\n'
    printf '  host free: %s\n' "$(df -h "$VM_DIR" | awk 'NR==2{print $4}')"
    say "  snapshots:"
    snaps_list
    # `status` is a report, not a verdict: it exits 0 even when what it reports is bad,
    # so the badness has to be read off the text. Inheriting snaps_list's rc here would
    # make an absent disk look like the command itself had failed.
    exit 0
    ;;

ssh)
    shift
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" "$VM_USER@127.0.0.1" "$@"
    ;;

snap)
    name="${2:?usage: $0 snap <name>}"
    claim_guard snap
    # 🔑 Generic tags are how the 08-31 collision stayed invisible: qemu-img ALLOWS
    # duplicate tags, so two sessions both calling theirs `fresh` leaves `restore fresh`
    # ambiguous with no error anywhere. Name what it is and when.
    case "$name" in
        fresh|base|clean|test|tmp|snap|backup)
            die "snapshot name '$name' is too generic -- duplicate tags are legal and silent.
   Use purpose+date, e.g. p4-toolchain-$(date +%m%d) or pre-<experiment>-$(date +%m%d)." ;;
    esac
    was_running=0; vm_running && was_running=1
    [ "$was_running" = 1 ] && { say "--- stopping for a consistent snapshot ---"; "$0" stop || die "stop failed"; }
    # Read the list BEFORE writing: on 2026-08-31 a session snapshotted onto a disk it
    # believed was empty because the list had failed to read. Refusing here is cheap;
    # an ambiguous duplicate tag is permanent.
    say "--- existing snapshots (checked before adding, not after) ---"
    snaps_list || die "cannot read the existing snapshots -- refusing to add one blind"
    qemu-img snapshot -l -U "$IMG" | awk -v n="$name" '$2==n{f=1} END{exit !f}' \
        && die "'$name' already exists on this disk -- pick another tag (duplicates are legal and silent)"
    qemu-img snapshot -c "$name" "$IMG" || die "snapshot failed"
    say "=== ACCEPTANCE: snapshot must appear in the list ==="
    snaps_list
    qemu-img snapshot -l -U "$IMG" | awk -v n="$name" '$2==n{f=1} END{exit !f}' \
        || die "snapshot '$name' is NOT in the list -- treat as not taken"
    # if/fi, not `&& { }`: as the last statement of the branch, a false test made the
    # whole verb exit 1 after a snapshot that had actually succeeded. Harmless-looking,
    # but it makes `snap && <next step>` silently never run the next step.
    if [ "$was_running" = 1 ]; then say "--- restarting ---"; "$0" start; fi
    ;;

restore)
    name="${2:?usage: $0 restore <name>}"
    claim_guard restore
    # Duplicate tags are legal, and `qemu-img snapshot -a` picks one of them without
    # saying which. Refuse rather than roll back to an ambiguous point.
    # -U and fail-closed: the old form swallowed a read failure into n=0, which then
    # passed the check. A guard whose read can fail silently is not a guard.
    lst=$(qemu-img snapshot -l -U "$IMG" 2>&1) \
        || die "cannot read the snapshot list -- refusing to restore blind:
$lst"
    n=$(printf '%s\n' "$lst" | awk -v t="$name" '$2==t{c++} END{print c+0}')
    [ "$n" -eq 0 ] && die "'$name' is not on this disk. Available: $0 snaps"
    [ "$n" -gt 1 ] && die "'$name' matches $n snapshots on this disk -- ambiguous, refusing.
   Someone else's tag collided with yours. List them: $0 snaps"
    vm_running && { say "--- stopping first ---"; "$0" stop || die "stop failed"; }
    qemu-img snapshot -a "$name" "$IMG" || die "restore failed"
    say "restored to '$name'. Snapshots now:"
    qemu-img snapshot -l "$IMG" | sed 's/^/  /'
    ;;

snaps)
    snaps_list
    ;;

vms)
    # The cross-session view. Read-only and needs no NDT_OWNER on purpose: finding out
    # what is taken must never be gated on having already claimed something.
    say "=== lab VMs on $(hostname)  $(date -Is) ==="
    printf '  %-24s %-12s %-6s %-9s %s\n' DIR OWNER PORT QEMU 'WORK POINT'
    found=0
    for d in "$HOME"/ndtwin-vm*/; do
        [ -d "$d" ] || continue
        found=1; d="${d%/}"
        if p=$(dir_pid "$d"); then q="pid $p"; else q="-"; fi
        if [ -f "$d/CONFIG" ]; then
            wp=$(awk -F= '/^cpus=/{c=$2} /^mem=/{m=$2} END{print c" vCPU/"m" MiB"}' "$d/CONFIG")
        else
            wp="🔴 unrecorded (next start = defaults)"
        fi
        printf '  %-24s %-12s %-6s %-9s %s\n' \
            "$(basename "$d")" "$(owner_of "$d")" "$(port_of "$d")" "$q" "$wp"
    done
    [ "$found" = 1 ] || say "  (none)"
    say ""
    say "  ports actually listening on 127.0.0.1 (the ground truth, not the registry):"
    ss -tlnH 2>/dev/null | awk '{print "    " $4}' | grep '^ *127.0.0.1:' | sort -u \
        || say "    (ss unavailable)"
    say ""
    say "  host budget -- RAM is what limits parallel VMs, not cores:"
    printf '    cores %s   mem %s   swap %s   %s free on %s\n' \
        "$(nproc)" \
        "$(free -g | awk '/^Mem:/{print $2"Gi total, "$7"Gi available"}')" \
        "$(free -g | awk '/^Swap:/{print $2"Gi"}')" \
        "$(df -h "$HOME" | awk 'NR==2{print $4}')" "$(df -h "$HOME" | awk 'NR==2{print $6}')"
    say "  🔑 Claimed is not the same reading as running, and neither is the same as busy."
    ;;

destroy)
    claim_guard destroy
    say "This deletes $IMG and every snapshot in it."
    printf 'Type DESTROY to confirm: '; read -r ans
    [ "$ans" = DESTROY ] || { say "aborted"; exit 1; }
    vm_running && "$0" stop
    rm -f "$IMG" "$SEED" "$PIDF" "$MON"
    say "gone. Base image kept at $BASE (delete by hand if you mean it)."
    ;;

*)
    sed -n '5,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
