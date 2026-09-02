#!/bin/bash
# =================================================================================================
# 00_preflight.sh -- refuse to start the T-4 round unless PREREG §4's four preconditions hold,
# the machine is free of the previous round's artefacts, and the binary under test is named.
#
# WRITTEN, NOT RUN. `bash -n` only.
#
# This script VERIFIES preconditions. It does not create them: it never claims the lab, never
# starts a fabric, never sudos. PREREG §4 assigns those to the executor. A preflight that fixes
# what it is checking cannot report that the check was needed.
#
# H-CORRESPONDENCE
#   H-17  liveness only via lib.sh `alive()` (/proc). No `kill -0` anywhere.
#   H-18  every log/state string is read through the PATTERN REGISTRY, self-tested at start.
#   H-19  `ndt status` and the kernel probe are separate observations; a kernel answering 404 is
#         reported as "answering", never as "down".
#   H-20  THIS IS THE SCRIPT THAT OWNS H-20. It records a signature for every artefact a
#         previous run could have left, and later scripts call require_absent_or_fresh against
#         the baseline written here. If /tmp/ndtwin_p4_switches.json exists and cannot be
#         removed, this script ABORTS rather than assuming the next run will overwrite it.
#   H-21  `set -o pipefail` via lib.sh; every gate takes a pre-computed value.
#   H-22  nothing is spawned here.
#   H-23  see H-18.
#   H-24  PYTHONUNBUFFERED=1 exported by lib.sh.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harness_begin 00_preflight

STATUS_TXT="$(ndt_status pre)"
info "ndt status captured at $STATUS_TXT"

# -------------------------------------------------------------------------------------------------
say "PREREG §4.1 + §4.2 -- the lab claim"
# `ndt status` prints:   claim   yours ...  |  none  |  EXPIRED ...  |  <someone else>
CLAIM_LINE="$(grep -E '^  claim ' "$STATUS_TXT" | head -1 | sed 's/^  claim *//' || true)"
info "claim line: ${CLAIM_LINE:-<absent>}"
info "NDT_OWNER: ${NDT_OWNER:-<unset>}   (the name the claim line above is rendered relative to)"
# The verdict is computed by lib.sh's claim_verdict, not by a case here, so that the five
# outcomes -- in particular OWNER-UNSET, which this script used to report as FOREIGN -- are
# testable without a lab. See lib.sh claim_verdict.
case "$(claim_verdict "$CLAIM_LINE")" in
    YOURS)   ok "the lab is claimed by this session (PREREG §4.2)" ;;
    UNCLAIMED) bad "the lab is NOT claimed. PREREG §4.2 requires a claim naming this round before any measurement. Run: NDT_OWNER=<you> ndt claim 240 'T-4 full-stack round'" ;;
    EXPIRED) bad "the lab claim has EXPIRED ($CLAIM_LINE) -- re-claim before measuring" ;;
    FOREIGN) bad "the lab is claimed by someone else: $CLAIM_LINE (this session is NDT_OWNER=${NDT_OWNER:-}). PREREG §4.1 requires 開機手冊 to have released it." ;;
    OWNER-UNSET) bad "THIS HARNESS CANNOT TELL WHOSE CLAIM THAT IS: NDT_OWNER is unset, so 'ndt status' renders every claim -- including this round's own -- as a stranger's name ($CLAIM_LINE). This is the instrument, not the lab. Re-run with the name the claim was made under: export NDT_OWNER=${CLAIM_LINE%% *} (and keep it exported for every later script)." ;;
esac

# §4.2 also requires exclusive_cpu=yes. `ndt status` prints the DECLARED value next to the
# measured load1, and goes red itself when the declaration is not holding.
EXCL_LINE="$(grep -E '^  exclusive cpu ' "$STATUS_TXT" | head -1 || true)"
info "exclusive cpu: ${EXCL_LINE:-<absent, i.e. no live claim>}"
case "$EXCL_LINE" in
    *"yes (load1"*)      ok "exclusive_cpu=yes and ndt judges it to be holding" ;;
    *"it is NOT holding"*) bad "exclusive_cpu was declared but load1 says it is not holding -- something unbookkept is on the cores ($EXCL_LINE)" ;;
    *"no ("*)            bad "the claim does not set exclusive_cpu=yes; PREREG §4.2 requires it" ;;
    *)                   bad "no exclusive-cpu line in ndt status -- there is no live claim to read it from" ;;
esac

# -------------------------------------------------------------------------------------------------
say "PREREG §4.4 -- nothing else is measuring, and nothing invisible is loading the machine"
MEAS_LINE="$(grep -E '^  measuring ' "$STATUS_TXT" | head -1 | sed 's/^  measuring *//' || true)"
info "measuring: ${MEAS_LINE:-<absent>}"
if [[ "$MEAS_LINE" == "nothing" ]]; then
    ok "ndt status reports measuring=nothing (the sanctioned source; do NOT re-derive this with pgrep)"
else
    bad "a measurement is in flight: $MEAS_LINE"
fi
if grep -qE '^  orphaned ' "$STATUS_TXT"; then
    bad "ndt status reports ORPHANED measurement processes with no fabric -- 'ndt clean' reaps them; they are leftovers, and waiting for them never ends"
fi

# The three invisible load sources this project has actually been bitten by, in order of when
# they were found. None of them appears in `measuring`.
#   1. a QEMU VM (the installation-manual replay) -- 4 vCPU of apt/cmake/ninja
#   2. the act of recording the experiment (git/commit/agy: measured 207% of a core)
#   3. this claude session itself (~29.4% of one core when idle)
NCPU="$(nproc 2>/dev/null || echo 1)"
LOAD1="$(cut -d' ' -f1 /proc/loadavg)"
info "load1=$LOAD1 over $NCPU cores"
QEMU_N="$(ps -eo comm= 2>/dev/null | grep -cE '^(qemu-system|qemu-kvm)' || true)"
if [[ "${QEMU_N:-0}" == "0" ]]; then
    ok "no qemu process is running (the installation-manual VM is down)"
else
    bad "$QEMU_N qemu process(es) are running. PREREG §4.1: that VM is invisible to 'measuring' and its load lands on the same cores."
fi
info "REMINDER, not a gate: the session running this harness is itself a covariate (~0.3 core idle). Record it in the write-up; do not try to subtract it."

# -------------------------------------------------------------------------------------------------
say "PREREG §4.3 -- name the binaries this round measures"
# memory: benchmark-must-name-the-binary-it-measured -- name the commit AND say which kind of
# identifier it is. mtime does not even give a lower bound; the binary on PATH is not
# necessarily the binary the fabric runs.
{
    printf 'recorded %s\n' "$(_ts)"
    printf 'kernel source commit (git rev-parse HEAD, i.e. a SOURCE identifier, not a build id): %s\n' \
           "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
    printf 'kernel worktree dirty: %s\n' \
           "$( [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]] && echo YES || echo no )"
    printf 'kernel binary path: %s\n' "$REPO/build/bin/ndtwin_kernel"
    printf 'kernel binary sha256: %s\n' \
           "$(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -d' ' -f1 || echo ABSENT)"
    printf 'bmv2 binary ndt reports: %s\n' "$(grep -E '^  bmv2 ' "$STATUS_TXT" | head -1 || echo UNKNOWN)"
    printf 'bmv2 binary actually running: %s\n' \
           "$(ps -eo args= 2>/dev/null | grep -o '/[^ ]*simple_switch_grpc' | sort -u | head -1 || echo none)"
    printf 'PREREG names kernel-under-test: faffdbe (compare the line above; if they differ, say so in the write-up rather than editing the PREREG)\n'
} > "$OUT/binary-provenance.txt"
info "provenance written to $OUT/binary-provenance.txt"
cat "$OUT/binary-provenance.txt" | sed 's/^/      /'

HEAD_NOW="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo UNKNOWN)"
if [[ "$HEAD_NOW" == faffdbe* ]]; then
    ok "kernel source is the commit PREREG registered (faffdbe)"
else
    skip "kernel source is $HEAD_NOW, PREREG registered faffdbe -- NOT a failure, but the write-up must say which was measured and must not quote PREREG's commit"
fi

# -------------------------------------------------------------------------------------------------
say "H-20 -- artefacts a previous run could have left, signed BEFORE anything starts"
# Everything here is read later as if it described this run. Each gets a signature now; the
# scripts that consume them call require_absent_or_fresh against this baseline.
BASELINE="$OUT/artifact-baseline.txt"
: > "$BASELINE"
for f in \
    "$P4_MANIFEST" \
    "$LOG_DIR/kernel.log" \
    "$LOG_DIR/p4_proxy.log" \
    "$LOG_DIR/ryu.log" \
    "$LOG_DIR/app_nsr.log" \
    "$LOG_DIR/app_viz.log" \
    "$LOG_DIR/app_te.log" \
; do
    printf '%s\t%s\n' "$f" "$(artifact_signature "$f")" >> "$BASELINE"
done
sed 's/^/      /' "$BASELINE"
ok "artefact baseline written to $BASELINE"

# The manifest is the one that has already caused a false pass. It is created by root, so a
# plain rm fails, and the check that reads it cannot tell whose run wrote it.
if [[ -e "$P4_MANIFEST" ]]; then
    OWNER="$(stat -c %U "$P4_MANIFEST" 2>/dev/null || echo '?')"
    bad "$P4_MANIFEST already exists (owner: $OWNER, sig: $(artifact_signature "$P4_MANIFEST")). H-20: if the fabric fails, the manifest check will read THIS file and pass. Remove it before starting -- it is probably root-owned, so: sudo rm -f $P4_MANIFEST"
else
    ok "$P4_MANIFEST is absent -- no previous manifest can be mistaken for this run's"
fi

# -------------------------------------------------------------------------------------------------
say "the machine is quiet: no fabric, no kernel, no apps"
BMV2_N="$(ps -eo comm= 2>/dev/null | grep -cx 'simple_switch_g' || true)"
info "bmv2 processes: ${BMV2_N:-0}   (comm is truncated to 15 chars; 'simple_switch_g' is the whole name the kernel reports)"
gate "no bmv2 switches are already running" "$( [[ "${BMV2_N:-0}" == "0" ]] && echo 0 || echo 1 )" "${BMV2_N:-0}"

# port_holder is three-valued as of 2026-08-30 (FINDING-02 Defect B). The middle branch is new
# and it is the one that matters here: a root-owned listener used to read as ":$p is free", which
# is the strongest possible false PASS for a preflight whose entire job is to establish that the
# machine is quiet. A port we cannot see the owner of is NOT free.
# [Co-developed with claude code -- Adam]
for p in 8000 8080 8081 9000; do
    H="$(port_holder "$p")"
    if [[ -z "$H" ]]; then
        ok ":$p is free (no LISTEN line -- decided on the line's presence, which is visible whoever owns it)"
    elif [[ "$H" == "$PORT_HOLDER_HIDDEN" ]]; then
        bad ":$p HAS a listener whose owner is not visible to this uid (root-owned). The machine is NOT quiet. Before 2026-08-30 this printed ':$p is free'. Identify it with:  sudo ss -lptnH 'sport = :$p'"
    else
        bad ":$p is held by pid $H ($(proc_cmdline "$H" | cut -c1-70)) -- P-1: a second instance on a taken port still runs its startup and writes to the data plane before it discovers the port is gone"
    fi
done

APPS_LINE="$(grep -E '^  apps ' "$STATUS_TXT" | head -1 | sed 's/^  apps *//' || true)"
gate "no consumer app is already running" "$( [[ "$APPS_LINE" == "none running" ]] && echo 0 || echo 1 )" "${APPS_LINE:-?}"

# -------------------------------------------------------------------------------------------------
say "the five apps exist where components.env says they do"
# The seven sibling repos are at $WORKSPACE_ROOT, discovered by probing upward for
# Energy-Saving-App (components.env:19-28). Measured 2026-08-30: they are under /home/adam,
# NOT under /home/adam/Desktop next to the kernel.
# shellcheck source=/dev/null
. "$REPO/tools/test_workflow/components.env"
info "WORKSPACE_ROOT=$WORKSPACE_ROOT"
for pair in \
    "energy:$ENERGY_APP_DIR" \
    "sim:$SIM_MGR_DIR" \
    "nsr:$NSR_DIR/network_state_recorder.py" \
    "viz:$VISUALIZER_DIR/network_traffic_visualizer.sh" \
    "te:$TE_APP_DIR/Traffic-engineering-App.py" \
; do
    n="${pair%%:*}"; p="${pair#*:}"
    gate "$n present at $p" "$( [[ -e "$p" ]] && echo 0 || echo 1 )" "$p"
done

# Two known reasons an app cannot start headless. Both are recorded now so that a later failure
# is read as "we already knew this" rather than as a finding about the kernel.
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    skip "viz cannot start: it is a JavaFX GUI and there is no DISPLAY/WAYLAND_DISPLAY (ndt:1570 refuses it). R-3's five-app convergence is therefore four-app unless the executor runs on a desktop session."
else
    ok "a display is present, so viz can start"
fi
skip "te calls input() twice in ask_mode() (Traffic-engineering-App.py:595-612) with no EOFError guard; started headless it will raise EOFError and die. 20_apps_lifecycle.sh gives it a pty. Recorded here so the crash is not mistaken for a kernel fault."

summary
exit 0
