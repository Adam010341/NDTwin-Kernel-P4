#!/usr/bin/env bash
# Paired A/B: two kernels one constant apart, measured at zero sampling and at 1/1024.
#
# [Co-developed with claude code -- Adam]
#
# THE QUESTION (Adam, 2026-09-02): not "how much did it save" but "why is that step triggered
# by whether samples exist at all". Baseline + one low rate is enough to separate those.
#
# WHY THIS IS A CONTROLLED EXPERIMENT AND 09-01 WAS NOT
# The 09-01 round compared two binaries twelve days apart, so its 46-point difference is "the
# difference between two rounds", not "the effect of this change". These two arms are the same
# tree, same commit, same compiler, same flags, differing in one constant's value -- built
# 2026-08-31 by the E round and, per their SUPPLEMENTARY-provenance.md §9, never run.
#
# ORDER IS PRE-REGISTERED (PREREG.md §4). The arm is the innermost loop so the two arms sit
# adjacent in time and share whatever the machine is doing; three pairs start with 1hz and three
# start with 1khz, so an order effect cannot masquerade as the arm effect.
#
# BOTH CONDITIONS ARE VERIFIED BEFORE MEASURING, NOT AFTER. A "1/1024" cell that silently
# sampled nothing reads as a small number and gets subtracted from the other arm as if it were
# real -- the same failure as a mislabelled zero, except it shrinks the gap and therefore looks
# conservative rather than broken.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
HERE="$REPO/doc/audit/2026-09-02_recompute-paired-ab"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
KBIN="$REPO/build/bin/ndtwin_kernel"
ARMDIR="$REPO/.test_run/binaries/e-round"
PROD_BACKUP="$ARMDIR/ndtwin_kernel.production-backup"
PROD_SHA=e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94
LOG="$HERE/run_ab.log"
DUR="${DUR:-300}"

A_BIN="$ARMDIR/ndtwin_kernel.recompute-1hz"
A_SHA=fcb0d9d40d5814a80b37127d01a04068f92aa45a54e74372bebec75ec343b956
A_RATIO='ratioILl1ELl1EE'
B_BIN="$ARMDIR/ndtwin_kernel.recompute-1khz"
B_SHA=4dc9193de97a2cfed2307fb3ef50fa9d8ee7b62879bfb277e92ed3626b74bba6
B_RATIO='ratioILl1ELl1000000EE'

SAMPLING_ON='random(meta.sample_rand, (bit<16>)0, SAMPLE_RATE - 1);'
SAMPLING_OFF='random(meta.sample_rand, (bit<16>)1, SAMPLE_RATE - 1);'

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# 🔴 ONE INSTANCE ONLY. On 2026-09-02 two instances of this script ran at once (PREREG 3c): the
# second tore down the fabric the first had just built, deployed the other arm over the one in
# place, and both wrote the same raw files. That is not repairable after the fact. flock on a
# file in the round directory; a second launcher refuses before touching anything, and it
# refuses BEFORE the traps are armed so it cannot run restore_all against the live instance.
exec 9>"$HERE/.run_ab.lock"
if ! flock -n 9; then
    echo "REFUSE: another run_ab.sh holds $HERE/.run_ab.lock -- two instances would race" >&2
    exit 75
fi

# --- instrument restoration ---------------------------------------------------------------
# Leaving either of these behind is silent and expensive: a kernel binary that is not the
# production one, or a fabric compiled with sampling disabled, would change what every later
# round on this machine measures without saying so.
restore_all() {
    local rc=$?
    say "--- restoring instruments (rc=$rc) ---"

    # 🔴 THE STACK MUST GO DOWN FIRST, and the dry run is why this line exists.
    # cp onto a file that a live process is executing fails with ETXTBSY ("Text file busy"),
    # so the first version of this function left an ARM BINARY sitting in the production path
    # and the kernel still running from it. The sha check below caught it -- which is the whole
    # argument for verifying a restore instead of assuming one -- but the machine was left
    # wrong. The last cell of a round does not tear down after measuring, and neither does an
    # abort, so both exits reach here with the stack up.
    "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
    sleep 2

    if grep -qF "$SAMPLING_OFF" "$P4SRC"; then
        swap_p4 "$SAMPLING_OFF" "$SAMPLING_ON" && say "  p4 predicate restored"
    fi
    set_sample_rate 256 && say "  SAMPLE_RATE restored to 256"
    # Restoring the .p4 source is not enough: the fabric loads the COMPILED artefact
    # (p4_proxy/mininet/p4_testbed_topo.py:357 reads p4_src/build/ndtwin_switch.json), so a
    # stale json would silently zero the telemetry of every later round on this machine while
    # the source read as correct.
    if p4_compile; then
        say "  p4 recompiled from the restored source"
    else
        say "  🔴 FATAL: p4c failed on the restored source -- the fabric would load a stale json"
    fi

    if [ -f "$PROD_BACKUP" ]; then
        local got
        if ! cp "$PROD_BACKUP" "$KBIN" 2>>"$LOG"; then
            say "  🔴 FATAL: cp of the production kernel FAILED (is something still running it?)"
        fi
        got=$(sha256sum "$KBIN" | cut -d' ' -f1)
        if [ "$got" = "$PROD_SHA" ]; then
            say "  production kernel restored, sha256 verified"
        else
            say "  🔴 FATAL: restored kernel sha $got != $PROD_SHA -- DO NOT RUN THE STACK"
        fi
    else
        say "  🔴 FATAL: production backup missing at $PROD_BACKUP"
    fi
    say "  predicate now: $(grep -oE 'random\(meta.sample_rand[^;]*;' "$P4SRC" | head -1)"
    say "  SAMPLE_RATE  : $(grep -oE 'SAMPLE_RATE = [0-9]+;' "$P4SRC" | head -1)"
    say "  kernel now   : $(sha256sum "$KBIN" | cut -d' ' -f1)"
    say "  fabric is left DOWN; 'ndt up' brings it back on the production binary."
}
# 🔴 A TRAPPED SIGNAL DOES NOT END THE SCRIPT. bash runs the handler and then resumes where it
# was. The first version trapped INT/TERM straight onto restore_all, so the SIGTERM sent to stop
# the round at a pair boundary restored the instruments -- and then carried on into the next
# cell: it tore down the fabric a resumed instance had just built, copied its arm over the one
# the other instance had deployed, and both wrote the same raw files. Two cells were voided
# (PREREG 3c). The handler restores, disarms the EXIT trap so the restore does not run twice,
# and exits.
on_signal() {
    say "--- signal received: restoring instruments, then EXITING (not continuing) ---"
    restore_all
    trap - EXIT
    exit 143
}
trap on_signal INT TERM
trap restore_all EXIT

swap_p4() {
    python3 - "$P4SRC" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(old) == 1, f"expected exactly one occurrence of {old!r}, found {s.count(old)}"
open(p, "w").write(s.replace(old, new))
PY
}

set_sample_rate() {
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC"
}

p4_compile() {
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1
}

teardown() {
    "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
    $LAB topo-stop >>"$LOG" 2>&1 || true
    setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
    sleep 3
}

bringup() {
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do
        sleep 5
        $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break
    done
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "FATAL: fabric short of 10 switches"; return 1; }
    env TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do
        sleep 5
        curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0
    done
    say "FATAL: kernel API never came up"; return 1
}

# The identity assay is the template instantiation of sleep_for, read out of the binary that is
# actually in place -- not the source, not mtime, not the arm's own provenance file.
#   std::ratio<1,1>       = seconds      = 1 Hz
#   std::ratio<1,1000000> = microseconds = 1 kHz
kernel_ratio() {
    local sym
    sym=$(nm "$KBIN" | awk '/calFlowPathByQueried/ {print $NF}' | head -1)
    objdump -d --disassemble="$sym" "$KBIN" 2>/dev/null \
        | grep -oE 'sleep_forIlSt5ratioILl1ELl[0-9]+EE' | sort -u
}

# Deploy one arm and refuse to continue unless the binary in place is provably that arm.
deploy() {
    local name="$1" src="$2" want_sha="$3" want_ratio="$4" got_sha got_ratio
    cp "$src" "$KBIN"
    got_sha=$(sha256sum "$KBIN" | cut -d' ' -f1)
    [ "$got_sha" = "$want_sha" ] || { say "FATAL: deployed $name sha $got_sha != $want_sha"; return 1; }
    got_ratio=$(kernel_ratio)
    case "$got_ratio" in
        *"$want_ratio"*) say "  deployed $name  sha ok  recompute=$got_ratio" ;;
        *) say "FATAL: deployed $name reads $got_ratio, expected *$want_ratio*"; return 1 ;;
    esac
}

# A cell already on disk and complete is not measured again. The round was stopped once at a
# pair boundary (PREREG 3b) and resumes in the pre-registered order; the judge of "complete" is
# the same is_complete() the analyser uses, so a cell the analysis would reject is re-measured
# rather than trusted because its files exist.
cell_complete() {
    python3 - "$1" <<'PY'
import importlib.util, sys
old = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu/analyse_matrix.py"
spec = importlib.util.spec_from_file_location("am", old)
am = importlib.util.module_from_spec(spec); spec.loader.exec_module(am)
am.BASE = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-02_recompute-paired-ab/raw"
sys.exit(0 if am.is_complete(sys.argv[1]) else 1)
PY
}

cell() {                     # cell <cond> <arm> <rep>
    local cond="$1" arm="$2" rep="$3" label
    # LABEL_PFX is set by the dry run so its cells can never be mistaken for real ones by a
    # glob, by the analyser, or by a reader of raw/.
    label="${LABEL_PFX:-}ab_${cond}_${arm}_r${rep}_nopoll"
    if cell_complete "$label"; then
        say "  ---- $label: already complete on disk, skipping ----"
        return 0
    fi
    say "  ---- $label ----"
    teardown
    case "$arm" in
        1hz)  deploy 1hz  "$A_BIN" "$A_SHA" "$A_RATIO" || exit 1 ;;
        1khz) deploy 1khz "$B_BIN" "$B_SHA" "$B_RATIO" || exit 1 ;;
    esac
    bringup || exit 1
    local mode; [ "$cond" = zero ] && mode=zero || mode=sampled
    say "    verifying condition ($mode) before measuring"
    if ! python3 "$HERE/verify_cond.py" "$mode" 30 >>"$LOG" 2>&1; then
        say "    ✗ condition did NOT hold -- refusing to measure, aborting the round"
        say "      (a cell measured now would be mislabelled, and its arm's pair would be poisoned)"
        exit 1
    fi
    say "    ✓ condition holds"
    # 🔴 Identity is re-read from the RUNNING PROCESS at the last moment before measuring, not
    # only from the file at deploy time. In the 09-02 race the file in build/bin was overwritten
    # and the fabric restarted BETWEEN this cell's deploy and its measurement, so the deploy-time
    # check had passed and the cell measured the other arm. /proc/<pid>/exe is what executes.
    local want_sha now_sha kpid
    [ "$arm" = 1hz ] && want_sha="$A_SHA" || want_sha="$B_SHA"
    kpid=$(ps -eo pid=,comm= | awk '$2=="ndtwin_kernel"{print $1; exit}')
    [ -n "$kpid" ] || { say "FATAL: no running ndtwin_kernel to identify before measuring"; exit 1; }
    # Unprivileged first, sudo as the fallback, and say which one answered (lib_e.sh's
    # running_kernel_sha, adopted). stack.sh starts the kernel as this user, so the direct read
    # is the one that normally works; `sudo -n sha256sum` is NOT in this machine's NOPASSWD list
    # and always fails -- the first version tried only that and refused every cell.
    local via=direct
    now_sha=$(sha256sum "/proc/$kpid/exe" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$now_sha" ]; then
        now_sha=$(sudo -n sha256sum "/proc/$kpid/exe" 2>/dev/null | cut -d' ' -f1); via=sudo
    fi
    # Shape first: an unreadable exe must refuse, not compare (two unreadables compare equal).
    [[ "$now_sha" =~ ^[0-9a-f]{64}$ ]] || { say "FATAL: running kernel exe UNREADABLE (pid $kpid, tried direct and sudo); unreadable is not the arm"; exit 1; }
    [ "$now_sha" = "$want_sha" ] || { say "FATAL: running kernel is $now_sha, this cell claims $arm ($want_sha) -- refusing to measure"; exit 1; }
    say "    running kernel pid=$kpid exe sha256 matches $arm (read via $via)"
    if ! POLL=off "$HERE/measure.sh" "$label" "$DUR" 200 >>"$LOG" 2>&1; then
        say "FATAL: measure.sh failed for $label (see log). A cell that did not measure is not 'done'."
        exit 1
    fi
    say "    $label done"
}

pair() {                     # pair <cond> <first-arm> <second-arm> <rep>
    local cond="$1" first="$2" second="$3" rep="$4"
    say "=== rep $rep / $cond / order: $first then $second ==="
    if [ "$cond" = zero ]; then
        grep -qF "$SAMPLING_OFF" "$P4SRC" || swap_p4 "$SAMPLING_ON" "$SAMPLING_OFF"
        set_sample_rate 256 || { say "FATAL: sed did not take"; exit 1; }
    else
        grep -qF "$SAMPLING_ON" "$P4SRC" || swap_p4 "$SAMPLING_OFF" "$SAMPLING_ON"
        set_sample_rate 1024 || { say "FATAL: sed did not take"; exit 1; }
    fi
    say "  p4: $(grep -oE 'random\(meta.sample_rand[^;]*;' "$P4SRC" | head -1)  $(grep -oE 'SAMPLE_RATE = [0-9]+;' "$P4SRC" | head -1)"
    p4_compile || { say "FATAL: p4c failed"; exit 1; }
    cell "$cond" "$first" "$rep"
    cell "$cond" "$second" "$rep"
}

# ============================== preflight ==================================================
say "================ paired A/B, DUR=${DUR}s, 12 cells ================"
say "PREREG: $HERE/PREREG.md"

for f in "$A_BIN" "$B_BIN" "$PROD_BACKUP"; do
    [ -f "$f" ] || { say "FATAL: missing $f"; exit 1; }
done
say "arm shas as found on disk:"
say "  1hz : $(sha256sum "$A_BIN" | cut -d' ' -f1)"
say "  1khz: $(sha256sum "$B_BIN" | cut -d' ' -f1)"
say "  prod: $(sha256sum "$PROD_BACKUP" | cut -d' ' -f1)"
[ "$(sha256sum "$A_BIN" | cut -d' ' -f1)" = "$A_SHA" ] || { say "FATAL: 1hz arm sha mismatch"; exit 1; }
[ "$(sha256sum "$B_BIN" | cut -d' ' -f1)" = "$B_SHA" ] || { say "FATAL: 1khz arm sha mismatch"; exit 1; }
[ "$(sha256sum "$PROD_BACKUP" | cut -d' ' -f1)" = "$PROD_SHA" ] || { say "FATAL: production backup sha mismatch -- refusing to overwrite the live kernel without a verified restore"; exit 1; }

# The discriminator has to print two different answers across the pair, or "read 1 Hz" and
# "the grep is broken" are the same observation.
say "discriminator, read out of each arm (must differ):"
for pair_spec in "1hz:$A_BIN" "1khz:$B_BIN"; do
    n="${pair_spec%%:*}"; b="${pair_spec#*:}"
    s=$(nm "$b" | awk '/calFlowPathByQueried/ {print $NF}' | head -1)
    r=$(objdump -d --disassemble="$s" "$b" 2>/dev/null | grep -oE 'sleep_forIlSt5ratioILl1ELl[0-9]+EE' | sort -u)
    say "  $n -> $r"
done

say "p4 at start: $(grep -oE 'random\(meta.sample_rand[^;]*;' "$P4SRC" | head -1)  $(grep -oE 'SAMPLE_RATE = [0-9]+;' "$P4SRC" | head -1)"
say "shared instruments (unmodified, identified by sha):"
for f in "$REPO/doc/audit/2026-09-01_cpu-matrix-1hz/netdev_only.py" \
         "$REPO/doc/audit/2026-09-01_cpu-matrix-1hz/slim_client_json.sh" \
         "$REPO/tools/test_workflow/cpu_probe.py"; do
    say "  $(sha256sum "$f" | cut -c1-16)  $(basename "$f")"
done

# ============================== the round ==================================================
# DRY_RUN walks the whole control flow once -- p4 swap, compile, teardown, arm deploy, bringup,
# both condition verifiers, measure, label -- on short cells. The 09-01 round found its wiring
# error two minutes into a 100-minute launch and had to restart; this is that check, paid for up
# front. Its cells are prefixed so they cannot be read as data.
if [ "${DRY_RUN:-0}" = "1" ]; then
    say "################  DRY RUN -- cells are prefixed 'dry_' and are not data  ################"
    LABEL_PFX=dry_
    pair zero  1hz  1khz 0
    # The fabric is still up and NOT sampling here, which is the only cheap chance to see the
    # sampled-mode assertion go red. Together with the two runs recorded in REPORT.md (sampled
    # green and zero red, both against a sampling fabric) that closes the verifier's truth
    # table: each mode has been seen to pass and to fail.
    say "  negative control: verify_cond.py sampled against a NON-sampling fabric must fail"
    if python3 "$HERE/verify_cond.py" sampled 25 >>"$LOG" 2>&1; then
        say "  🔴 FATAL: sampled-mode verifier PASSED on a fabric with sampling disabled."
        say "     It cannot distinguish the two conditions, so nothing it gates is trustworthy."
        exit 1
    fi
    # Not "rc=$?" -- that would read the `if`, not python, and print 0 for a refusal.
    say "  ✓ sampled-mode verifier correctly refused"
    pair s1024 1khz 1hz  0
    say "################  DRY RUN complete  ################"
    exit 0
fi

# Pre-registered order, PREREG.md §4. Three pairs lead with 1hz, three with 1khz.
pair zero  1hz  1khz 1
pair s1024 1khz 1hz  1
pair zero  1khz 1hz  2
pair s1024 1hz  1khz 2
pair zero  1hz  1khz 3
pair s1024 1khz 1hz  3

say "================ all 12 cells done ================"
