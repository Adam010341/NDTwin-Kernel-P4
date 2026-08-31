#!/usr/bin/env bash
# vm-install-stack.sh -- build the NDTwin toolchain INSIDE the lab VM.
# [Co-developed with claude code -- Adam]
#
#   bash vm-install-stack.sh deps    manual Step 3.1 + 3.2 apt lists   (~5-10 min)
#   bash vm-install-stack.sh p4      p4-guide install-p4dev-v8.sh      (~2 h, CPU saturating)
#   bash vm-install-stack.sh all     both, in order
#
# Runs as `ndt` inside the guest, which has NOPASSWD root. Blast radius is the VM;
# snapshot `fresh` on the host rolls the whole thing back.
#
# Acceptance is read off ARTIFACTS, never off exit codes -- p4-guide is the script
# that taught us that lesson: on a half-installed tree it skips the build and
# returns 0. See install-manual-clean-room-test in memory.
set -uo pipefail

LOG_DIR="$HOME"                 # NOT /tmp -- tmpfiles.d wipes /tmp on boot
STAMP=$(date +%Y%m%d-%H%M%S)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

phase_deps() {
    local L="$LOG_DIR/install-deps.log"
    exec > >(tee -a "$L") 2>&1
    log "=== deps phase  host=$(hostname)  $(. /etc/os-release; echo "$PRETTY_NAME") ==="

    # Manual Step 3.1. wireshark omitted on purpose: GUI analyser, never invoked here.
    local P31=(build-essential cmake g++ make git ninja-build xterm curl iperf3)
    # Manual Step 3.2.
    local P32=(libboost-all-dev libfmt-dev libspdlog-dev libssh-dev nlohmann-json3-dev
               python3-venv mininet openvswitch-switch)

    log "apt update"
    sudo apt-get update -qq || log "WARN: apt update rc=$? (acceptance is dpkg state)"
    log "apt install ${#P31[@]} + ${#P32[@]} packages"
    # DEBIAN_FRONTEND is REQUIRED: iperf3 opens a debconf dialog after the download
    # and -y does not answer debconf. Without it, dpkg deadlocks holding the lock.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${P31[@]}" "${P32[@]}"
    log "apt-get rc=$? (not the criterion)"

    local miss=0
    echo "--- ACCEPTANCE: dpkg state ---"
    for p in "${P31[@]}" "${P32[@]}"; do
        st=$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || echo not-installed)
        [ "$st" = installed ] && printf '  OK       %s\n' "$p" \
            || { printf '  MISSING  %s (%s)\n' "$p" "$st"; miss=$((miss+1)); }
    done
    echo "--- ACCEPTANCE: the two the manual says to check by state ---"
    printf '  ovs daemon: %s\n' "$(systemctl is-active openvswitch-switch 2>&1)"
    printf '  python3 -m venv usable: '
    python3 -m venv --help >/dev/null 2>&1 && echo yes || { echo NO; miss=$((miss+1)); }
    [ "$miss" -eq 0 ] && log "DEPS: PASS" || { log "DEPS: FAIL ($miss missing)"; return 1; }
}

phase_p4() {
    local L="$LOG_DIR/install-p4.log"
    exec > >(tee -a "$L") 2>&1
    log "=== p4 phase  started $STAMP ==="

    # Idempotence trap, learned the hard way: if a previous run left these dirs, the
    # installer SKIPS the build and exits 0 -- a half install that reports success.
    for d in behavioral-model p4c PI grpc; do
        if [ -e "$HOME/$d" ]; then
            log "🔴 REFUSING TO START: $HOME/$d already exists."
            log "   p4-guide would skip that component and still exit 0."
            log "   Roll the VM back to snapshot 'fresh' on the host, then re-run."
            return 1
        fi
    done

    [ -d "$HOME/p4-guide" ] || git clone -q https://github.com/jafingerhut/p4-guide.git "$HOME/p4-guide"
    log "p4-guide $(git -C "$HOME/p4-guide" log -1 --format='%h %ci')"

    # Deliberately UNPINNED, both for p4-guide and behavioral-model: that is what a
    # reader of the manual gets today, and a preflight (patch --dry-run, with v10 as
    # a control) confirmed v8's patches still apply against the current HEAD.
    log "launching install-p4dev-v8.sh (memory-aware -j is the script's own)"
    cd "$HOME" || return 1
    ./p4-guide/bin/install-p4dev-v8.sh
    log "installer rc=$? (NOT the criterion)"

    echo "--- ACCEPTANCE: the artifacts, not the exit code ---"
    local miss=0
    for b in simple_switch_grpc p4c-bm2-ss p4c; do
        p=$(command -v "$b" 2>/dev/null) \
            && printf '  OK       %-20s %s\n' "$b" "$p" \
            || { printf '  MISSING  %s\n' "$b"; miss=$((miss+1)); }
    done
    command -v simple_switch_grpc >/dev/null && \
        printf '  version: %s\n' "$(simple_switch_grpc --version 2>&1 | head -1)"
    command -v p4c-bm2-ss >/dev/null && \
        printf '  version: %s\n' "$(p4c-bm2-ss --version 2>&1 | head -1)"

    # Purpose, not mechanism: "the binary exists" is weaker than "it compiles a program".
    echo "--- ACCEPTANCE: p4c-bm2-ss actually compiles a minimal v1model program ---"
    cat > /tmp/min.p4 <<'P4'
#include <v1model.p4>
struct H {} struct M {}
parser P(packet_in b, out H h, inout M m, inout standard_metadata_t s){ state start { transition accept; } }
control VC(inout H h, inout M m){ apply{} }
control I(inout H h, inout M m, inout standard_metadata_t s){ apply{} }
control E(inout H h, inout M m, inout standard_metadata_t s){ apply{} }
control CC(inout H h, inout M m){ apply{} }
control D(packet_out b, in H h){ apply{} }
V1Switch(P(), VC(), I(), E(), CC(), D()) main;
P4
    if p4c-bm2-ss --std p4-16 -o /tmp/min.json /tmp/min.p4 2>/tmp/min.err; then
        printf '  OK       compiled to %s bytes of BMv2 JSON\n' "$(stat -c%s /tmp/min.json)"
    else
        printf '  FAILED   %s\n' "$(head -3 /tmp/min.err)"; miss=$((miss+1))
    fi

    [ "$miss" -eq 0 ] && log "P4: PASS" || { log "P4: FAIL ($miss)"; return 1; }
}

case "${1:-}" in
    deps) phase_deps ;;
    p4)   phase_p4 ;;
    all)  phase_deps && phase_p4 ;;
    *)    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
