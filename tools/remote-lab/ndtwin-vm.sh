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
#   ndtwin-vm.sh keep "<why>"     mark this disk as must-not-delete (--clear to lift)
#   ndtwin-vm.sh adopt [pid]      register a RUNNING VM this tool did not start: OWNER +
#                                 CONFIG, work point read out of its own argv. With a
#                                 pid, the DIRECTORY comes from argv too -- use that for
#                                 any VM not laid out by this script. `vms` prints the
#                                 exact command for each one it finds.
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

# 🔴 A stopped VM is indistinguishable from an abandoned one. 2026-08-31: a sibling
# session needed RAM, read `vms` showing "unowned / no qemu / has a disk", and offered
# to destroy the directory -- which held a ruled-preserve toolchain snapshot that had
# cost 38m41s to build. Nothing on screen said otherwise, and nothing was wrong with
# their reasoning; the row simply did not carry the one fact that mattered.
# KEEP is that fact, and it is written here only because destroy/vms/status read it.
# A marker with no reader is not a protection -- it is a note to oneself.
KEEPF="$VM_DIR/KEEP"

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

# 🔴 Both helpers below exist because every other population in this script comes from
# a glob of MY OWN naming convention ($HOME/ndtwin-vm*/). A VM that lives anywhere else
# is not merely unlisted -- it is invisible, and "not listed" reads as "not there".
# 2026-08-31: a sibling ran a VM out of ~/addtools/work.qcow2 and neither `vms` nor
# `adopt` could see it at all. Derive from what is actually running instead.
# qemu_kind <exe-target> <argv0> -> QKIND = "verified" | "unverified" | "no"
#
# 🔴 Identity comes from /proc/<pid>/exe, which the kernel maintains and which a
# process cannot set. This used to substring-match the whole cmdline, so it
# counted (a) the six argv-only stand-ins the gate in this directory launches
# and (b) anything that merely MENTIONS qemu-system -- a grep, an editor, the
# shell of whoever is debugging this function. Same family as `pkill -f`.
#
# ⚠️ It is NOT a straight field swap, and that is the whole design here. exe is
# unreadable for another user's process, and seeing OTHER people's VMs is the
# entire point of `vms` on a shared box -- so switching fields naively would
# trade over-counting impostors for LOSING every VM that is not mine. A pid
# whose exe cannot be read but whose argv[0] says qemu is therefore reported as
# UNVERIFIED: never silently dropped, never silently promoted.
#
# Pure on purpose: both inputs are arguments, so all three outcomes are
# table-testable without starting a process or needing another user's uid.
QKIND=
qemu_kind() {
    local exe="${1% (deleted)}" argv0="${2##*/}"
    if [ -n "$exe" ]; then
        case "${exe##*/}" in
            qemu-system-*|qemu-kvm) QKIND=verified ;;
            *)                      QKIND=no ;;
        esac
        return
    fi
    # Fallback for an exe we may not read. Deliberately argv[0] ONLY, not a
    # substring of the line: `grep qemu-system` has grep as its argv[0].
    case "$argv0" in
        qemu-system-*|qemu-kvm) QKIND=unverified ;;
        *)                      QKIND=no ;;
    esac
}

# One find for every exe link, rather than a readlink per pid. Same reason as
# host_witness.sh in this directory: on a 671-process host the per-pid form cost
# ~2,000 forks and 3.19 s per pass, measured.
qemu_exe_map() {
    local ph tgt
    EXEQ=()
    while read -r ph tgt; do EXEQ["${ph##*/}"]="$tgt"; done \
        < <(find /proc -maxdepth 2 -name exe -printf '%h %l\n' 2>/dev/null)
}

_qemu_scan() {  # <want-kind> -> matching pids, one per line
    local want="$1" d pid a0
    declare -A EXEQ
    qemu_exe_map
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        a0=""; IFS= read -r -d '' a0 2>/dev/null < "$d/cmdline" || true
        qemu_kind "${EXEQ[$pid]-}" "$a0"
        case "$want" in
            any) [ "$QKIND" != no ] && printf '%s\n' "$pid" ;;
            *)   [ "$QKIND" = "$want" ] && printf '%s\n' "$pid" ;;
        esac
    done
    return 0
}

qemu_pids()            { _qemu_scan any ; }         # verified + unverified
qemu_pids_unverified() { _qemu_scan unverified ; }  # argv says qemu, exe unreadable

qemu_disk() {  # qemu_disk <pid> -> its WRITABLE disk path (skips the read-only seed)
    # 🔴 The first version matched /^file=/ -- i.e. only the argument order THIS script
    # happens to emit. A sibling's VM used `-drive id=d0,file=...,if=none,...` and was
    # invisible to both `vms` and `adopt`: same defect as a gate that enumerates its own
    # author's list, one layer down in the parser. -drive keys are comma-separated and
    # ORDER-INDEPENDENT, so parse them that way.
    # ⚠️ A path containing a literal comma is not handled; qemu escapes those by doubling
    # them, and no lab path here has one. Named so the next reader knows it was considered.
    tr '\0' '\n' 2>/dev/null < "/proc/$1/cmdline" | awk '
        /^-hd[a-d]$/ { want=1; next }
        want         { print; exit }
        /(^|,)(file|filename)=/ {
            n=split($0, part, ","); ro=0; f=""
            for (i=1; i<=n; i++) {
                if (part[i] ~ /^(readonly|read-only)=(on|true)$/) ro=1
                if (f=="" && part[i] ~ /^(file|filename)=/) {
                    f=part[i]; sub(/^(file|filename)=/, "", f)
                }
            }
            if (f != "" && !ro) { print f; exit }
        }'
}

addr_is_loopback() {  # addr_is_loopback <addr> -- rc=0 if nothing off-box can reach it
    # 🔴 The first version compared against the two literals this script writes,
    # "127.0.0.1" and "::1". Deployed, it immediately flagged systemd-resolved's
    # 127.0.0.53%lo and 127.0.0.54 as exposed. The whole of 127.0.0.0/8 is loopback.
    # A marker that fires on ordinary system state is one people learn to scroll past,
    # which costs exactly the cases it was added for.
    # ⚠️ And the unit test had ENCODED the bug: to avoid opening a real exposed port the
    # fixture bound 127.0.0.2 and asserted it was flagged -- a fixture chosen for safety
    # turned a wrong classification into a requirement. Classification is a pure function
    # of a string, so it is table-tested below instead of via sockets.
    case "${1%\%*}" in                       # drop any %iface scope suffix
        127.*|::1|'[::1]'|localhost) return 0 ;;
        *) return 1 ;;
    esac
}

listener_level() {  # listener_level <addr:port> <vm-ports…> -> one of three words
    # Kept a pure function of strings so it can be table-tested without opening a
    # socket. Testing an exposure detector must not create an exposure, and the only
    # fixture that reaches the interesting branch is a genuinely exposed port.
    local ap="$1"; shift
    local port="${ap##*:}" addr="${ap%:*}"
    addr_is_loopback "$addr" && { printf 'loopback'; return; }
    # 🔑 Two levels, not one. A lab VM forwarding off-box is what this tool is about;
    # the host's own sshd on 0.0.0.0:22 is expected and always there. Marking both the
    # same way is how a marker stops being read -- and then it is absent exactly when
    # it matters.
    case " $* " in *" $port "*) printf 'vm-exposed'; return ;; esac
    printf 'host-service'
}

hostfwd_of() {  # hostfwd_of <pid> -> "<bind-addr> <port>", rc=1 if it has no hostfwd
    # 🔴 The first version matched `hostfwd=tcp:127\.0\.0\.1:` -- the literal string THIS
    # script writes. In qemu the host address is OPTIONAL, and omitting it binds ALL
    # interfaces. 2026-08-31: a sibling wrote `hostfwd=tcp::2296-:22` on every VM of the
    # evening, so their forwards were on 0.0.0.0, reaching a guest with a password login,
    # on the lab network. My parser did not get that wrong -- it could not see it at all.
    # ⇒ A parser that only understands its own output cannot warn you about the input it
    #   does not understand, and that is exactly the input most worth warning about.
    tr '\0' '\n' 2>/dev/null < "/proc/$1/cmdline" | awk '
        match($0, /hostfwd=tcp:[^,]*/) {
            s = substr($0, RSTART + 12, RLENGTH - 12)   # strip "hostfwd=tcp:"
            sub(/-.*$/, "", s)                          # drop the guest side
            if (match(s, /^\[[^]]*\]:/)) {              # [::1]:2222  -- bracketed IPv6
                a = substr(s, 2, RLENGTH - 3); p = substr(s, RLENGTH + 1)
            } else if (match(s, /:/)) {                 # 127.0.0.1:2222  or  :2296
                a = substr(s, 1, RSTART - 1); p = substr(s, RSTART + 1)
            } else { a = ""; p = s }                    # no colon at all: port only
            if (p ~ /^[0-9]+$/) { print (a == "" ? "0.0.0.0" : a), p; exit }
        }' | sed -n 1p | grep . || return 1
}

keep_reason() {  # keep_reason <vmdir> -> the one-line reason; rc=1 if not marked keep
    local f="$1/KEEP" r
    [ -f "$f" ] || return 1
    r=$(sed -n 's/^reason:[[:space:]]*//p' "$f" | sed -n '1p')
    # Fall back to the first non-empty line so a hand-written KEEP still gets read.
    # The SUMMARY is what appears in a row; `destroy` prints the whole file, because
    # the place where a truncated reason could cost something is the delete prompt.
    [ -n "$r" ] || r=$(sed -n '/./{p;q;}' "$f")
    printf '%s' "$r"
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
    # 🔴 This guard was MISSING until 2026-08-31 and nothing noticed, because the
    # mutation gate enumerated the guards I had written rather than the verbs that
    # mutate. 32/32 green meant "every guard fires both ways", never "every mutating
    # verb has a guard" -- and I reported the first as if it answered the second.
    # Powering off another session's VM mid-run is precisely the R7 downgrade shape:
    # they `start` it again without their working point and the lab comes back
    # smaller, silently. See the structural test in test_vm_coordination.sh.
    claim_guard stop
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
    if [ -f "$KEEPF" ]; then
        say "  🔒 marked KEEP:"
        sed 's/^/       /' "$KEEPF"
    fi
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
    # Also missing. `ssh <cmd>` runs arbitrary commands in the guest, so it is a
    # mutating verb wearing a read-only name -- two sessions sharing one VM through
    # it is exactly what R6 forbids.
    #
    # 🔑 Note what this guard does NOT do: claim_guard refuses, claim_write records,
    # and only create/start call the latter. So requiring NDT_OWNER here still lets
    # you look inside an UNOWNED VM without taking it -- which the 08-31 inventory
    # of the pending-retirement VM needed, and which §5b of the rules requires stay
    # possible. Guarding and claiming are separate powers; do not fuse them.
    claim_guard ssh
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

adopt)
    # 🔴 Coordination hangs entirely off `create` and `start` -- they are what call
    # claim_write and what record the working point. So ANY legitimate route that does
    # not pass through them loses OWNER and CONFIG together, silently.
    # 2026-08-31, first hand: a session needed a VM built from an exported snapshot.
    # `create` only knows how to download a clean cloud image, so they assembled the
    # qemu invocation themselves -- correctly -- and their measurement round ran with
    # its working point recorded nowhere but the process's own argv. That is not a
    # discipline failure. It is a missing path, and the registry gap was its shadow.
    # 🔴 `adopt` with no pid only ever looked at $VM_DIR/disk.qcow2 -- so the VMs most in
    # need of adopting, the ones this tool did not lay out, were exactly the ones it
    # could not see. Found by the sibling it was written for, on their own VM, within
    # the hour. The applicability domain was narrower than the description.
    # ⇒ `adopt <pid>` derives the DIRECTORY from argv too, not just the work point.
    if [ -n "${2:-}" ]; then
        p="$2"
        [ -r "/proc/$p/cmdline" ] || die "no readable /proc/$p/cmdline -- is $p a running process of yours?"
        case "$(tr '\0' ' ' < "/proc/$p/cmdline")" in
            *qemu-system*) ;;
            *) die "pid $p is not a qemu-system process. Its argv starts:
     $(tr '\0' ' ' < "/proc/$p/cmdline" | cut -c1-160)" ;;
        esac
        d=$(qemu_disk "$p")
        [ -n "$d" ] || die "found no writable '-drive file=' in pid $p's argv -- refusing to guess a directory"
        # Re-point EVERY path before the guard runs: guarding the directory the caller
        # happens to be pointed at, then writing into a different one, is worse than
        # no guard at all.
        IMG="$d"; VM_DIR=$(dirname "$d")
        OWNERF="$VM_DIR/OWNER"; CFG="$VM_DIR/CONFIG"; KEEPF="$VM_DIR/KEEP"
        claim_guard adopt
        say "adopting by pid: $p"
        say "  disk      $IMG      (read out of argv)"
        say "  directory $VM_DIR   (derived from the disk, not assumed)"
    else
        claim_guard adopt
        vm_running || die "adopt records what a RUNNING VM is actually using.
   Nothing matching $IMG is running (checked /proc, not a pidfile).
   If the VM is not laid out by this tool, name it:   $0 adopt <pid>
   Running qemu processes right now:
$(for q in $(qemu_pids); do printf '     pid %-7s %s\n' "$q" "$(qemu_disk "$q")"; done)
   For a VM that is stopped there is no argv to read -- write $CFG yourself."
        p=$(vm_pid)
    fi
    argv=$(tr '\0' '\n' < "/proc/$p/cmdline")
    # 🔑 Everything below is DERIVED FROM argv, never from what the operator types.
    # A registry entry that can disagree with the process it describes is worse than
    # no entry at all, because the next reader has no reason to doubt it.
    acpu=$(printf '%s\n' "$argv" | awk '/^-smp$/{getline; print; exit}')
    amem=$(printf '%s\n' "$argv" | awk '/^-m$/{getline; print; exit}')
    afwd=$(hostfwd_of "$p") || afwd=""
    abind=${afwd% *}; aport=${afwd#* }
    [ -n "$afwd" ] || { abind=""; aport=""; }
    [ -n "$acpu" ] && [ -n "$amem" ] \
        || die "could not read -smp / -m out of pid $p's argv -- refusing to guess.
   What it actually says:
$(printf '%s\n' "$argv" | sed 's/^/     /')"
    # 🔴 If argv has no hostfwd, DO NOT fall back to $SSH_PORT. The old code did, and the
    # default 2222 was then written into CONFIG under a banner reading "Read out of its
    # argv, not typed in" -- three true fields and one invented one. A sibling caught it.
    # Three-true-one-false is harder to catch than four-missing, because the true fields
    # vouch for the false one. A gap must stay visibly a gap.
    # ⚠️ And SSH_PORT must be neutralised, not left at its default: claim_write stamps
    # it into OWNER, which is where `vms` reads the port from. Fixing only CONFIG would
    # have moved the invented 2222 into the other file and left it there, still labelled
    # as this VM's port. One made-up value, two places to write it.
    if [ -n "$aport" ]; then SSH_PORT="$aport"; else SSH_PORT="unknown"; fi
    if [ -f "$CFG" ]; then
        old_c=$(cfg_get cpus); old_m=$(cfg_get mem)
        if [ "$old_c" != "$acpu" ] || [ "$old_m" != "$amem" ]; then
            say "🔴 $CFG DISAGREES with the running process -- argv wins, and the old"
            say "   values are printed because a record that drifted is itself a finding:"
            say "     recorded: $old_c vCPU / $old_m MiB"
            say "     actual:   $acpu vCPU / $amem MiB"
        fi
    fi
    claim_write
    adisk=$(qemu-img info -U "$IMG" 2>/dev/null | awk -F': ' '/virtual size/{print $2; exit}')
    printf 'cpus=%s\nmem=%s\ndisk=%s\nport=%s\n' \
        "$acpu" "$amem" "${adisk:-unknown}" "${aport:-unknown}" > "$CFG"
    say "adopted pid $p. Read out of its argv, not typed in:"
    sed 's/^/     /' "$CFG"
    if [ -z "$aport" ]; then
        say "  🔴 EXCEPT port: this argv has no hostfwd I can read, so it is recorded as"
        say "     'unknown' rather than filled in from a default. A default written under"
        say "     an 'out of its argv' banner is worse than a gap -- the true fields vouch"
        say "     for it. Set it by hand if you know it. The argv line was:"
        printf '%s\n' "$argv" | grep -i 'netdev\|hostfwd' | sed 's/^/       /' \
            || say "       (no -netdev at all)"
    elif ! addr_is_loopback "$abind"; then
        say "  🔴 THIS VM'S SSH FORWARD IS ON $abind:$aport -- NOT loopback."
        say "     qemu binds every interface when hostfwd's host address is omitted"
        say "     (\`hostfwd=tcp::$aport-\`). On a lab network that exposes the guest login."
        say "     Fix at the source: \`hostfwd=tcp:127.0.0.1:$aport-:22\`, then restart it."
    fi
    say ""
    sed 's/^/     /' "$OWNERF"
    say ""
    say "  🔑 The next start reuses this working point instead of the built-in defaults."
    say "  Do not take my word for it -- the same source is two lines away:"
    say "      tr '\\0' '\\n' < /proc/$p/cmdline | grep -A1 -E '^-smp\$|^-m\$'"
    ;;

keep)
    # Writing a marker is a state change on a shared disk, so it takes a guard like
    # every other mutating verb -- see the MUTATING table in test_vm_coordination.sh,
    # which will go red for the next verb somebody adds without deciding this.
    claim_guard keep
    if [ "${2:-}" = --clear ]; then
        [ -f "$KEEPF" ] || { say "not marked keep -- nothing to clear"; exit 0; }
        say "clearing the keep mark. For the record, it said:"
        sed 's/^/     /' "$KEEPF"
        rm -f "$KEEPF"
        say "cleared -- $VM_DIR now deletes with the ordinary confirmation."
        exit 0
    fi
    reason="${2:?usage: $0 keep \"<why this disk must outlive its VM>\"   |   $0 keep --clear}"
    [ -d "$VM_DIR" ] || die "$VM_DIR does not exist -- nothing to mark"
    {
        printf 'kept-by: %s\n' "$(me)"
        printf 'kept-at: %s\n' "$(date -Is)"
        printf 'reason: %s\n' "$reason"
    } > "$KEEPF"
    say "marked keep:"
    sed 's/^/     /' "$KEEPF"
    say ""
    # Naming the readers is the point of the verb. A mark whose readers you cannot
    # name is a note to yourself, and it will not be there when it matters.
    say "   Read by:  $0 vms  (the survey people clean up from)"
    say "             $0 status"
    say "             $0 destroy  (prints this, and then wants a longer phrase)"
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
        # A directory with no disk is not a VM. Say so instead of printing a row
        # that looks like an occupancy -- post-destroy leftovers used to read as one.
        if [ ! -f "$d/disk.qcow2" ]; then
            printf '  %-24s %-12s %-6s %-9s %s\n' \
                "$(basename "$d")" "-" "-" "$q" "no disk -- leftover files only, not a VM"
            continue
        fi
        if [ -f "$d/CONFIG" ]; then
            wp=$(awk -F= '/^cpus=/{c=$2} /^mem=/{m=$2} END{print c" vCPU/"m" MiB"}' "$d/CONFIG")
        else
            wp="🔴 unrecorded (next start = defaults)"
        fi
        printf '  %-24s %-12s %-6s %-9s %s\n' \
            "$(basename "$d")" "$(owner_of "$d")" "$(port_of "$d")" "$q" "$wp"
        # 🔴 This row is where the 08-31 near-miss happened: "unowned / no qemu / has a
        # disk" is exactly how an abandoned leftover looks AND exactly how a preserved
        # artifact looks. If someone wrote down a reason to keep it, it has to surface
        # HERE -- this is the survey people read before deciding what to clean up.
        if r=$(keep_reason "$d"); then
            printf '  %-24s 🔒 KEEP -- %s\n' "" "$r"
        fi
    done
    [ "$found" = 1 ] || say "  (none)"
    # 🔴 Everything above came from a glob of ONE naming convention, so it can only ever
    # rediscover the directories I already expected. That is the same shape as a gate
    # that enumerates its author's own list (see the G10a note in the test file): the
    # population has to come from the thing under test, which here means the processes.
    say ""
    say "  running qemu the glob above cannot see (population taken from /proc, not from a name):"
    unlisted=0
    UNVERIFIED=$(qemu_pids_unverified | tr '\n' ' ')
    for q in $(qemu_pids); do
        qd=$(qemu_disk "$q")
        # 🔴 An unparseable disk must NOT be a silent skip. The line below used to be
        # `[ -n "$qd" ] || continue`, which meant any qemu whose -drive form the parser
        # did not understand vanished -- and then the "(none)" line below asserted that
        # every running qemu was accounted for. A parser gap became a completeness claim.
        # Report the pid with its argv instead: unparseable is a finding, not an absence.
        if [ -z "$qd" ]; then
            unlisted=1
            printf '    pid %-7s %-12s 🔴 disk argv not parseable -- argv: %s\n' \
                "$q" "?" "$(tr '\0' ' ' 2>/dev/null < "/proc/$q/cmdline" | cut -c1-200)"
            continue
        fi
        case "$qd" in "$HOME"/ndtwin-vm*/*) continue ;; esac
        unlisted=1
        qdir=$(dirname "$qd")
        printf '    pid %-7s %-12s %s\n' "$q" "$(owner_of "$qdir")" "$qd"
        # 🔑 An identity I could not check must say so where it is USED, not only
        # where it was decided. exe is unreadable for another user's process, so
        # this line is argv-derived and a process can set argv.
        case " $UNVERIFIED " in *" $q "*)
            printf '    %-20s ⚠️  UNVERIFIED -- /proc/%s/exe unreadable (another user?); identity is argv, which a process can set\n' "" "$q" ;;
        esac
        if r=$(keep_reason "$qdir"); then printf '    %-20s 🔒 KEEP -- %s\n' "" "$r"; fi
        [ -f "$qdir/CONFIG" ] || printf '    %-20s 🔴 no CONFIG -- work point recorded nowhere but this argv: %s\n' \
            "" "$(tr '\0' '\n' 2>/dev/null < "/proc/$q/cmdline" | awk '/^-smp$/{getline;c=$0} /^-m$/{getline;m=$0} END{print c" vCPU / "m" MiB"}')"
        if fw=$(hostfwd_of "$q"); then
            addr_is_loopback "${fw% *}" \
                || printf '    %-20s 🔴 ssh forward on %s -- NOT loopback, the guest login is reachable off-box\n' "" "$fw"
        fi
        printf '    %-20s ⇒ register it without restarting:  NDT_OWNER=<you> %s adopt %s\n' "" "$0" "$q"
    done
    # Same check for the VMs the glob DID cover -- an exposed forward is not less
    # exposed for living in a directory I recognise.
    for d in "$HOME"/ndtwin-vm*/; do
        [ -d "$d" ] && p2=$(dir_pid "${d%/}") || continue
        fw=$(hostfwd_of "$p2") || continue
        if ! addr_is_loopback "${fw% *}"; then
            unlisted=1
            printf '    pid %-7s %-12s 🔴 ssh forward on %s -- NOT loopback\n' \
                "$p2" "$(owner_of "${d%/}")" "$fw"
        fi
    done
    [ "$unlisted" = 1 ] || say "    (none -- every running qemu is already listed above)"
    say ""
    # 🔴 This used to `grep '^ *127.0.0.1:'` -- the address MY OWN start command binds.
    # So a forward on 0.0.0.0 was not merely unflagged here, it was filtered out of the
    # "ground truth" list entirely. The one binding that needed showing was the one
    # binding this could not show. Print them all; mark the ones that are not loopback.
    say "  ports actually listening (the ground truth, not the registry):"
    # Two levels on purpose. 🔴 is reserved for a port a lab VM is forwarding, which is
    # what this tool is about; the host's own sshd on 0.0.0.0:22 is expected and gets a
    # plain note. Flagging both the same way is how a marker stops being read.
    vmports=$(for q in $(qemu_pids); do f=$(hostfwd_of "$q") && printf '%s\n' "${f#* }"; done)
    ss -tlnH 2>/dev/null | awk '{print $4}' | sort -u | while read -r a; do
        case "$(listener_level "$a" $vmports)" in
            loopback)     printf '    %s\n' "$a" ;;
            vm-exposed)   printf '    %s   🔴 a lab VM is forwarding this OFF-BOX\n' "$a" ;;
            host-service) printf '    %s   (not loopback -- host service, not a lab VM)\n' "$a" ;;
        esac
    done
    ss -tlnH >/dev/null 2>&1 || say "    (ss unavailable)"
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
    # 🔴 "every snapshot in it" is an abstraction, and abstractions do not stop anyone.
    # Name them. The 08-31 near-miss had exactly one line on screen -- the word
    # "snapshots" -- while what was about to die was a 38m41s toolchain build.
    if [ -f "$IMG" ]; then
        snaplist=$(qemu-img snapshot -l -U "$IMG" 2>/dev/null | sed '1,2d;/^$/d')
        say "This deletes $IMG -- permanently."
        if [ -n "$snaplist" ]; then
            say "   These snapshots die with it:"
            printf '%s\n' "$snaplist" | sed 's/^/     /'
        else
            say "   (the disk carries no snapshots)"
        fi
    else
        say "This deletes $IMG -- which does not currently exist."
    fi
    # The keep mark, and the reason someone wrote down, belong in front of the prompt.
    word=DESTROY
    if [ -f "$KEEPF" ]; then
        say ""
        say "🔒 THIS VM IS MARKED KEEP. Someone recorded a reason not to delete it:"
        sed 's/^/     /' "$KEEPF"
        say ""
        say "   If that reason is stale, clear it deliberately first:"
        say "       NDT_OWNER=$(me) VM_DIR=$VM_DIR $0 keep --clear"
        say "   The confirmation phrase below is longer on purpose, so the reflex you"
        say "   built typing DESTROY cannot carry you past a mark you have not read."
        word="DESTROY $(basename "$VM_DIR")"
    fi
    printf 'Type %s to confirm: ' "$word"; read -r ans
    [ "$ans" = "$word" ] || { say "aborted"; exit 1; }
    vm_running && "$0" stop
    # 🔴 Until 2026-08-31 this removed only IMG/SEED/PIDF/MON, so OWNER and CONFIG
    # survived a destroy and `vms` kept listing a VM that no longer had a disk --
    # a ghost claim, complete with a port number, for the next reader to work around.
    # The registry entry has to die with the thing it describes.
    rm -f "$IMG" "$SEED" "$PIDF" "$MON" "$OWNERF" "$CFG" "$KEEPF" \
          "$VM_DIR/user-data" "$VM_DIR/meta-data"
    # And the old closing line named ONLY the base image. It was true, which is
    # exactly why it misled: a report that discloses one leftover reads as the
    # complete list of leftovers. Enumerate whatever is actually still there.
    say "gone. What is still in $VM_DIR:"
    if [ -d "$VM_DIR" ] && [ -n "$(ls -A "$VM_DIR" 2>/dev/null)" ]; then
        ls -1sh "$VM_DIR" | sed '1d;s/^/     /'
        say "   (kept so a re-create need not re-download; delete the directory if you mean it)"
    else
        say "     (nothing -- the directory is empty)"
    fi
    ;;

*)
    sed -n '5,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
