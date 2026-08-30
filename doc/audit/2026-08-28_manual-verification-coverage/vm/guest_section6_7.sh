#!/bin/bash
# =================================================================================================
# guest_section6_7.sh -- run Installation Manual Step 6.7 verbatim inside the VM, and check the
# four notes it attaches.
#
# Page: "NDTwin Installation Manual / NDTwin Kernel / Operate an Emulated (Software) Network /
#        Native-Linux Excution Environment.md", Step 6.7 "(Optional) Build BMv2 for realistic
#        throughput".
#
# THE POINT: the commands below are COPIED FROM THE MANUAL, not written to work. Where the
# manual is wrong this script must fail in the way a reader would fail. Anything I add for
# instrumentation is marked HARNESS and kept out of the copied blocks.
#
# WHY A SCRIPT AND NOT A TRANSCRIPT (memory: put-measurement-commands-in-script-files):
# the build is hours long and unattended, so "what was actually run" has to survive without me.
#
# NOT `set -e`. A failing step is the finding; aborting on the first one would hide the rest.
# Every phase records its own verdict and the script always reaches the summary.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
set -uo pipefail

OUT="${OUT:-$HOME/s6.7-results}"
mkdir -p "$OUT"
RESULTS="$OUT/verdicts.tsv"
: > "$RESULTS"
LOG="$OUT/run.log"

ts()  { date -Is; }
say() { echo; echo "=== $* ==="; }
# verdict <id> <PASS|FAIL|N/A> <text>
verdict() { printf '%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" >> "$RESULTS"; printf '  %-6s %-4s %s\n' "$1" "$2" "$3"; }

echo "guest_section6_7.sh starting $(ts)" | tee -a "$LOG"
echo "host: $(hostname)  cores: $(nproc)  mem: $(free -m | awk 'NR==2{print $2}') MiB  free /: $(df -h / | awk 'NR==2{print $4}')" | tee -a "$LOG"

# -------------------------------------------------------------------------------------------------
say "PRE -- the manual's own evidence for 'this is a debug build'"
# The manual tells the reader to look for CXXFLAGS=-O0 -g in the existing tree's config.log.
# That instruction is checkable before anything is built, so it is checked first.
if [[ -f "$HOME/behavioral-model/config.log" ]]; then
    if grep -q -- "CXXFLAGS=-O0 -g" "$HOME/behavioral-model/config.log"; then
        verdict PRE-1 PASS "config.log contains 'CXXFLAGS=-O0 -g' exactly as the manual says to look for"
    else
        verdict PRE-1 FAIL "config.log exists but has no 'CXXFLAGS=-O0 -g'; the manual's stated evidence is not there"
    fi
else
    verdict PRE-1 FAIL "no ~/behavioral-model/config.log -- the manual assumes install-p4dev built one"
fi

# HARNESS: record what the debug binary is, so the comparison later has a named baseline
# (memory: benchmark-must-name-the-binary-it-measured).
DEBUG_BIN="$(command -v simple_switch_grpc || true)"
DEBUG_SHA=""
if [[ -n "$DEBUG_BIN" ]]; then
    DEBUG_SHA="$(sha256sum "$DEBUG_BIN" | cut -d' ' -f1)"
    verdict PRE-2 PASS "debug binary on PATH: $DEBUG_BIN  sha256=${DEBUG_SHA:0:16}  size=$(stat -c %s "$DEBUG_BIN")"
else
    verdict PRE-2 FAIL "no simple_switch_grpc on PATH before the build"
fi

# The manual says to build to a SEPARATE prefix "so the debug install stays available".
# Record the precondition so a later 'it is still available' claim means something.
verdict PRE-3 "N/A" "before build: /usr/local/bmv2-fast $( [[ -d /usr/local/bmv2-fast ]] && echo EXISTS || echo absent ); ~/bmv2-fast-src $( [[ -d $HOME/bmv2-fast-src ]] && echo EXISTS || echo absent )"

# sudo is needed by 'sudo make install'. Fail now rather than after two hours of compiling.
if sudo -n true 2>/dev/null; then
    verdict PRE-4 PASS "passwordless sudo available (needed by the manual's 'sudo make install')"
else
    verdict PRE-4 FAIL "no passwordless sudo -- 'sudo make install' will block forever unattended. STOPPING."
    echo "STOPPED: see $RESULTS"; exit 1
fi

# -------------------------------------------------------------------------------------------------
say "BUILD -- the manual's block, verbatim"
# ------------------------ COPIED FROM THE MANUAL, DO NOT EDIT ------------------------
# A FRESH clone -- not the ~/behavioral-model that install-p4dev-v8.sh already built in.
# See note 1 below for why that matters.
build_block() {
cd ~
git clone https://github.com/p4lang/behavioral-model.git bmv2-fast-src
cd bmv2-fast-src
./autogen.sh

./configure --prefix=/usr/local/bmv2-fast --with-pi --with-thrift \
    --disable-logging-macros --disable-elogger \
    'CXXFLAGS=-O3 -g -DNDEBUG -march=native -fno-semantic-interposition'
make -j"$(nproc)"
sudo make install        # do NOT run ldconfig afterwards
}
# --------------------------- END COPIED BLOCK ---------------------------

T0=$(date +%s)
build_block >> "$LOG" 2>&1
BUILD_RC=$?
T1=$(date +%s)
BUILD_MIN=$(( (T1 - T0) / 60 ))

if [[ $BUILD_RC -eq 0 ]]; then
    verdict BUILD PASS "the manual's block ran to completion, rc=0, ${BUILD_MIN} min on $(nproc) cores"
else
    verdict BUILD FAIL "the manual's block exited rc=$BUILD_RC after ${BUILD_MIN} min -- see $LOG"
fi
# The manual gives no duration at all. Recording it is the point: a reader deciding whether to
# take this optional step needs to know it is hours, not minutes.
verdict BUILD-TIME "N/A" "wall clock ${BUILD_MIN} min (${nproc_note:-$(nproc)} cores, 6 GB VM). The manual states no duration."

# -------------------------------------------------------------------------------------------------
say "POST -- did it produce what the manual promises"
FAST_BIN=/usr/local/bmv2-fast/bin/simple_switch_grpc
if [[ -x "$FAST_BIN" ]]; then
    verdict POST-1 PASS "$FAST_BIN exists  sha256=$(sha256sum "$FAST_BIN" | cut -c1-16)  size=$(stat -c %s "$FAST_BIN")"
else
    verdict POST-1 FAIL "$FAST_BIN was not produced"
fi

# "so the debug install stays available" -- the manual's stated reason for a separate prefix.
# Compared against the sha PRE-2 recorded BEFORE the build. An earlier draft of this compared
# sha256sum "$DEBUG_BIN" with sha256sum "$DEBUG_BIN" -- a thing against itself, which cannot
# fail. Same family as the gates FINDING-04 is about; caught by re-reading, not by running.
if [[ -z "$DEBUG_SHA" ]]; then
    verdict POST-2 "N/A" "no pre-build sha recorded, so 'unchanged' has nothing to compare against"
elif [[ ! -x "$DEBUG_BIN" ]]; then
    verdict POST-2 FAIL "the debug binary is gone -- the separate prefix did not protect it"
elif [[ "$(sha256sum "$DEBUG_BIN" | cut -d' ' -f1)" == "$DEBUG_SHA" ]]; then
    verdict POST-2 PASS "debug install byte-identical to before the build (${DEBUG_SHA:0:16}), as the manual promises"
else
    verdict POST-2 FAIL "the debug binary CHANGED during the build: was ${DEBUG_SHA:0:16}, now $(sha256sum "$DEBUG_BIN" | cut -c1-16)"
fi

# Note 4: --disable-elogger removes the nanomsg event stream. Observable without running anything.
if [[ -x "$FAST_BIN" ]]; then
    if ldd "$FAST_BIN" 2>/dev/null | grep -qi nanomsg; then
        verdict NOTE-4 FAIL "fast binary still links nanomsg -- the manual says --disable-elogger removes that stream"
    else
        verdict NOTE-4 PASS "fast binary does not link nanomsg, consistent with --disable-elogger"
    fi
    ldd "$FAST_BIN" > "$OUT/ldd_fast.txt" 2>&1
    ldd "$DEBUG_BIN" > "$OUT/ldd_debug.txt" 2>&1
fi

# -------------------------------------------------------------------------------------------------
say "NOTE 2 -- the library-mixing trap, tested the way the manual says to test it"
# The manual: "always launch the fast binary with LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib ...
# Verify through /proc/<pid>/maps that no library resolves to the old prefix."
#
# So: launch it BOTH ways and read /proc/<pid>/maps. The wrong way is the control -- if it does
# not show old-prefix libraries, the trap the manual warns about does not exist as described and
# that is itself a finding.
# 🔑 The manual's stated verification method cannot be used here, and that is itself a finding:
# /proc/<pid>/maps needs a RUNNING switch, and a switch only runs once a fabric hands it a
# compiled pipeline and interfaces. So a reader following Step 6.7 in order cannot check the
# trap at the point the manual raises it -- only much later, after Section 6's fabric is up.
#
# `ldd` answers the same question without a process: it runs the real dynamic loader's
# resolution. It is used as the primary instrument here, with the maps route deferred.
ldd_check() {   # ldd_check <label> <ld_library_path-or-empty>
    local label="$1" ldp="$2" out old
    out="$OUT/ldd_$label.txt"
    if [[ -n "$ldp" ]]; then LD_LIBRARY_PATH="$ldp" ldd "$FAST_BIN" > "$out" 2>&1
    else                     ldd "$FAST_BIN" > "$out" 2>&1
    fi
    # Count resolutions that land anywhere OTHER than the fast prefix, restricted to bmv2's own
    # libraries -- system libs legitimately come from /usr/lib.
    old="$(grep -E 'lib(bm|simple_switch|bmpi|runtimestubs)[^ ]* => ' "$out" | grep -vc '/usr/local/bmv2-fast/' || true)"
    verdict "NOTE-2-$label" "N/A" "$old bmv2 library resolution(s) outside /usr/local/bmv2-fast (see $out)"
}
if [[ -x "$FAST_BIN" ]]; then
    ldd_check with-ldpath /usr/local/bmv2-fast/lib
    ldd_check without-ldpath ""
    echo "  ^ read both rows together. The manual's claim is that WITHOUT the path you get the" | tee -a "$LOG"
    echo "    OLD libraries; so with-ldpath should be 0 and without-ldpath should be non-zero." | tee -a "$LOG"
    echo "    If BOTH are 0 the trap does not exist as described on this system -- report that," | tee -a "$LOG"
    echo "    do not report 'note 2 verified'." | tee -a "$LOG"
    verdict NOTE-2-METHOD "N/A" "the manual says to verify via /proc/<pid>/maps; that needs a running switch, i.e. a fabric, which Step 6.7 does not have. Deferred to the fabric re-test (note 3)."
fi

# -------------------------------------------------------------------------------------------------
say "NOTE 1 -- NOT TESTED, and why"
# The manual: build from a fresh clone, because an in-tree configuration makes autoconf refuse an
# out-of-tree configure, and `make distclean` would destroy the config.log documenting the
# existing build.
#
# Testing this means deliberately running configure inside ~/behavioral-model, which is the one
# artefact PRE-1 depends on and which took over an hour to produce. The manual's advice is
# conservative and costs nothing to follow; verifying it costs the baseline.
verdict NOTE-1 "N/A" "not tested: reproducing it requires damaging ~/behavioral-model, the tree PRE-1 reads. Recorded as untested, not as verified."

# -------------------------------------------------------------------------------------------------
say "FINAL STEP -- the manual's last instruction"
# "Once built, put the absolute path back into p4_proxy/mininet/bmv2_binary_override as the
# single directive line."
# Located rather than assumed: the manual's §4.1 clone lands in ~/Desktop/NDTwin-Kernel on this
# guest, not ~/NDTwin-Kernel. An earlier draft hard-coded the latter, which would have reported
# FAIL for the wrong reason -- the H-19 shape, a failure that is really a wrong address.
OVR="$(find "$HOME" -maxdepth 5 -name bmv2_binary_override -type f 2>/dev/null | head -1)"
if [[ -n "$OVR" && -f "$OVR" ]]; then
    cp "$OVR" "$OUT/bmv2_binary_override.before"
    echo "$FAST_BIN" > "$OVR"
    verdict FINAL PASS "wrote '$FAST_BIN' into $OVR (previous contents saved to $OUT/bmv2_binary_override.before)"
else
    verdict FINAL FAIL "no bmv2_binary_override found under \$HOME -- the manual's final instruction has no target on this guest"
fi

# -------------------------------------------------------------------------------------------------
say "SUMMARY"
awk -F'\t' '{printf "  %-14s %-4s %s\n", $2, $3, $4}' "$RESULTS"
echo
echo "  PASS=$(awk -F'\t' '$3=="PASS"' "$RESULTS" | wc -l)  FAIL=$(awk -F'\t' '$3=="FAIL"' "$RESULTS" | wc -l)  N/A=$(awk -F'\t' '$3=="N/A"' "$RESULTS" | wc -l)"
echo "  verdicts: $RESULTS"
echo "  full log: $LOG"
echo "guest_section6_7.sh done $(ts)"
