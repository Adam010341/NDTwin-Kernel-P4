#!/bin/bash
# ============================================================================================
# Installation Manual section 6.0 and 6.1, replayed as a literal reader in ONE terminal.
#
# Starts from the `post-s5-run2` snapshot -- i.e. a machine that has just finished sections
# 1-5 by following the page. That is the state a reader arriving at section 6 is actually in,
# which is the whole point: 6.1's headline warning is about the working directory you inherit
# from step 4.2.
#
# SAME DESIGN CONSTRAINT AS guest_sections_1_5.sh
#   One bash process, cwd carried from step to step, no cd or absolute path the page does not
#   print, cwd logged on both sides of every step. `set -e` deliberately not used.
#
# WHY 6.1 IS SPLIT INTO ITS OWN SCRIPT
#   It takes one to two hours. Steps 6.2-6.7 are minutes. Running them as one script would
#   mean any mistake in the short tail costs another two-hour install to retry.
#
# THE TRAP 6.1 DOCUMENTS, AND HOW THIS SCRIPT AVOIDS ARMING IT
#   The page warns that install-p4dev-v8.sh creates grpc/, PI/, behavioral-model/ and p4c/ in
#   *whatever directory you launch it from*, and that a reader still sitting in
#   ~/Desktop/NDTwin-Kernel/build from 4.2 will scatter a 12 GB toolchain there. This script
#   runs the page's `cd ~` exactly as printed and LOGS the cwd, so if the chain is broken the
#   log says so rather than the toolchain silently landing in the wrong place.
#
# VERIFICATION IS BY USE, NOT BY PRESENCE
#   The page is explicit that a script "declaring support is not evidence that it installs",
#   and that a re-run skips already-present components and exits 0 with a half-built
#   toolchain. So the acceptance check below compiles a real v1model program with p4c-bm2-ss
#   and asserts the output JSON is non-empty -- presence on PATH is not accepted as success.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/s6p1.log
exec > >(tee -a "$LOG") 2>&1
step_n=0
fail_n=0

banner() { echo; echo "############ $* ############"; }
say() {
    local desc="$1"; shift
    step_n=$((step_n+1))
    echo; echo "--- [$step_n] $desc"
    echo "    cwd-before: $PWD"
    echo "    \$ $*"
    "$@"
    local rc=$?
    echo "    rc=$rc   cwd-after: $PWD"
    [ $rc -ne 0 ] && { fail_n=$((fail_n+1)); echo "    ^^ NON-ZERO"; }
    return $rc
}
sayc() {
    local desc="$1"; shift
    step_n=$((step_n+1))
    echo; echo "--- [$step_n] $desc"
    echo "    cwd-before: $PWD"
    echo "    \$ $*"
    eval "$@"
    local rc=$?
    echo "    rc=$rc   cwd-after: $PWD"
    [ $rc -ne 0 ] && { fail_n=$((fail_n+1)); echo "    ^^ NON-ZERO"; }
    return $rc
}

echo "=== section 6.0-6.1 replay, started $(date -Is) ==="
echo "shell pid $$ -- cwd is inherited across every step below"
echo "starting cwd: $PWD"
echo "disk before:"; df -h / | tail -1

# --------------------------------------------------------------------------------------------
banner "SECTION 6.0 -- Check you cloned the right repository"
echo "The page puts this first precisely so a wrong clone is found in one second rather than"
echo "after a two-hour build. Both commands exactly as printed."
say  "6.0 cd to the project root" cd "$HOME/Desktop/NDTwin-Kernel"
sayc "6.0 the P4 source must be present" "ls p4_proxy/p4_src/ndtwin_switch.p4"

# --------------------------------------------------------------------------------------------
banner "SECTION 6.1 -- Install BMv2 and p4c  (the page says one to two hours)"
echo "Note the cwd logged on the next step. The page's warning is that this script builds into"
echo "whatever directory it is launched from, and a reader coming out of 4.2 may still be in"
echo "~/Desktop/NDTwin-Kernel/build. 4.2.4 is supposed to have prevented that."
say  "6.1 cd ~ (the page says this is not decoration)" cd "$HOME"
sayc "6.1 clone p4-guide" "git clone https://github.com/jafingerhut/p4-guide"

echo
echo "    >>> cwd immediately before launching the installer: $PWD"
echo "    >>> everything grpc/ PI/ behavioral-model/ p4c/ will be created HERE"
echo

sayc "6.1 run install-p4dev-v8.sh (the pinned script the page names)" \
     "./p4-guide/bin/install-p4dev-v8.sh"

echo
echo "    >>> what the installer actually created in $PWD:"
ls -d ~/grpc ~/PI ~/behavioral-model ~/p4c ~/p4setup.bash 2>&1 | sed 's/^/      /'
echo "    >>> and, to catch the trap the page warns about, anything that landed in build/:"
ls -d ~/Desktop/NDTwin-Kernel/build/grpc ~/Desktop/NDTwin-Kernel/build/p4c 2>/dev/null \
    | sed 's/^/      WRONG PLACE: /' || echo "      (nothing in build/ -- correct)"

# --------------------------------------------------------------------------------------------
banner "6.1 ACCEPTANCE -- judge the two binaries by USING them, not by presence"
echo "The page is explicit that a re-run skips already-built components, prints a normal"
echo "summary and exits 0. So exit status is not the criterion; these checks are."

sayc "are the two tools even on PATH?" \
     "source ~/p4setup.bash 2>/dev/null; command -v simple_switch_grpc; command -v p4c-bm2-ss"
sayc "simple_switch_grpc --version (page recorded 1.15.5-fdd3b893)" \
     "source ~/p4setup.bash 2>/dev/null; simple_switch_grpc --version"
sayc "p4c-bm2-ss --version (page recorded 1.2.5.16)" \
     "source ~/p4setup.bash 2>/dev/null; p4c-bm2-ss --version"

echo
echo "--- USE TEST: compile a minimal v1model program, as the page says was done"
cat > /tmp/minimal.p4 <<'P4EOF'
#include <v1model.p4>
header h_t { bit<8> f; }
struct H { h_t h; }
struct M { }
parser P(packet_in p, out H h, inout M m, inout standard_metadata_t s) {
    state start { transition accept; } }
control VC(inout H h, inout M m) { apply { } }
control I(inout H h, inout M m, inout standard_metadata_t s) { apply { } }
control E(inout H h, inout M m, inout standard_metadata_t s) { apply { } }
control CC(inout H h, inout M m) { apply { } }
control D(packet_out p, in H h) { apply { } }
V1Switch(P(), VC(), I(), E(), CC(), D()) main;
P4EOF
sayc "compile it to BMv2 JSON" \
     "source ~/p4setup.bash 2>/dev/null; p4c-bm2-ss --arch v1model -o /tmp/minimal.json /tmp/minimal.p4"
sayc "the output must exist AND be non-empty (presence is not success)" \
     "test -s /tmp/minimal.json && wc -c /tmp/minimal.json && head -c 120 /tmp/minimal.json"

# --------------------------------------------------------------------------------------------
banner "RESULT (6.0-6.1)"
echo "steps run: $step_n    non-zero exits: $fail_n"
echo "disk after:"; df -h / | tail -1
echo "toolchain size:"; du -sh ~/grpc ~/PI ~/behavioral-model ~/p4c 2>/dev/null | sed 's/^/  /'
echo "finished $(date -Is)"
