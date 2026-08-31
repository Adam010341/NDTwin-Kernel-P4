#!/usr/bin/env bash
# =================================================================================================
# run_f5.sh -- the F-5 fine-grid round's arm driver.
#              PREREG 2026-08-31_f5-fine-grid-round §2-§5.
#
# [Co-developed with claude code -- Adam]
#
#     . doc/audit/2026-08-31_f5-fine-grid-round/round.env
#     ./run_f5.sh plan                     # what would run; touches nothing
#     ./run_f5.sh selftest                 # the detector's three force tests, no fabric needed
#     ARM=q1-p4-post  ./run_f5.sh arm      # Q1: does the fix hold under load
#     ARM=q2-p4-pre   ./run_f5.sh arm      # Q2: how common was the old world
#     ARM=q3-p4-pre   ./run_f5.sh q3       # Q3: deliberate-trigger upper bound
#     DRY_RUN=1 ./run_f5.sh arm            # every branch, no side effects, full transcript
#
# WHAT THIS FILE REFUSES TO DO
#   * It will not run without a live fabric, an exclusive claim in this session's name, and the
#     arm's binary confirmed BY SYMBOL against the running process.
#   * It will not run Q3 after a post-T-11 phantom has been seen (§3 R1: stop Q3, CONTINUE Q2).
#   * It will not write the word "zero phantoms".  The only legal wording is the upper bound, and
#     the sampler prints it rather than leaving it to whoever writes the report.
# =================================================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${ROUND:-}" ]] || . "$HERE/round.env"
: "${DRY_RUN:=0}"
: "${DRY_FAIL:=}"
: "${_DRY_EXE_READS:=0}"
# 🔴 A dry run and a real run never share a transcript (CLAUDE.md: "跑過" and "讀過未執行" are
# never tabled together), and the dry lines are the ones that look tidiest.
[[ "$DRY_RUN" == 1 ]] && LOG="${LOG%.log}.dryrun.log"

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
RUN() { if [[ "$DRY_RUN" == 1 ]]; then printf '[%s] DRYRUN-EXEC %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; return 0; fi; "$@"; }
dry_note() { [[ "$DRY_RUN" == 1 ]] && printf '[%s] DRYRUN-NOTE %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; return 0; }
abort() { say "🔴 ABORT($1): ${*:2}"; say "🔴 §3 C5: nothing is added, widened or re-run to get past this."; exit 9; }

# -------------------------------------------------------------------------------------------------
# 🔴 BRACKETED IDENTITY (§4 F4).  A claim protects the fabric; it does NOT protect the binary on
# disk -- on 08-30 a rebuild landed 9 seconds before an exec.  So the arm records the sha256 of the
# RUNNING process's /proc/<pid>/exe at its start AND at its end, and a mismatch voids the arm.
# `ndt status`'s code column is an auxiliary signal only; the file on disk is not the evidence.
# -------------------------------------------------------------------------------------------------
running_kernel_sha() {
    # 🔴 The synthetic value PASSES the 64-hex shape test on purpose, so the dry run exercises the
    # comparison rather than skipping it.  DRY_FAIL=exeunreadable / exedrift force the two failure
    # shapes.  (A sentinel like "NO-KERNEL-PROCESS" compares EQUAL to itself, so a bracket built on
    # sentinels closes vacuously -- the hole the reviewer line found in PREREG-B's family.)
    if [[ "$DRY_RUN" == 1 ]]; then
        # 🔴 exedriftmid -- see lib_e.sh for the reasoning.  Mirrored here deliberately: the
        # last time a fixture guard was fixed in one file and not the other, the unmirrored copy
        # silently tested nothing for hours.
        case "$DRY_FAIL" in
            exeunreadable) echo "UNREADABLE"; return 0 ;;
            exedrift)      printf 'd%063d\n' 1; return 0 ;;
            exedriftmid)
                # 🔴 Drift ONLY on the closing read, marked explicitly by the caller.
                # The first attempt counted reads instead, and silently did not fire: E makes
                # three reads per cell (identity check, open, close) and F-5 makes two, so any
                # count is coupled to call sites and breaks when one is added.  A phase marker is
                # what the fixture actually means -- "the binary changed between open and close".
                [[ "${_DRY_PHASE:-}" == close ]] && { printf 'd%063d
' 2; return 0; }
                ;;
        esac
        printf 'a%063d\n' 0; return 0
    fi
    local pid; pid=$(ps -eo pid=,comm= | awk '$2=="ndtwin_kernel"{print $1; exit}')
    [[ -n "${pid:-}" ]] || { echo "NO-KERNEL-PROCESS"; return 0; }
    sudo -n sha256sum "/proc/$pid/exe" 2>/dev/null | cut -d' ' -f1 || echo UNREADABLE
}

# Which side of T-11 is actually executing.  91e7743 introduced `setProgrammedPredicate`, so its
# presence is a fact about the bytes rather than a claim about a filename -- the archived binaries
# in .test_run/binaries all record commit=UNKNOWN and are identified only this way.
assert_arm_binary() {
    local want side pid exe hits
    case "$ARM" in *-post) want=post ;; *-pre) want=pre ;; *) abort "arm" "ARM='$ARM' names neither -pre nor -post" ;; esac
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would read the running kernel's /proc/<pid>/exe and require setProgrammedPredicate to be $( [[ $want == post ]] && echo PRESENT || echo ABSENT)"
        return 0
    fi
    pid=$(ps -eo pid=,comm= | awk '$2=="ndtwin_kernel"{print $1; exit}')
    [[ -n "${pid:-}" ]] || abort "§4" "no running ndtwin_kernel to identify"
    exe=$(sudo -n readlink -f "/proc/$pid/exe")
    hits=$(sudo -n nm -C "$exe" 2>/dev/null | grep -c setProgrammedPredicate || true)
    side=$([[ "${hits:-0}" -gt 0 ]] && echo post || echo pre)
    say "    running kernel: pid=$pid exe=$exe setProgrammedPredicate_hits=${hits:-0} => $side-T-11"
    [[ "$side" == "$want" ]] || abort "§4" "ARM='$ARM' wants the $want-T-11 binary but the RUNNING
        process is $side-T-11.  Q1 measured on a pre-T-11 binary would report the defect as a
        regression of a fix that is not in the binary; Q2 measured on a post-T-11 one would
        report the old world as already fixed.  Swap the binary and restart the fabric."
}

# -------------------------------------------------------------------------------------------------
# #3 / #11 / #14, inherited from the D round (see
# ../2026-08-31_completeness-experiments/CROSS-ROUND-REGRESSION.md).  None was registered here
# before 2026-08-31; all three were executed by the D round's own scripts.
# -------------------------------------------------------------------------------------------------
BOOT_BASELINE=""
assert_same_boot() {   # #3 -- ladder_ext:83
    local b
    if [[ "$DRY_RUN" == 1 ]]; then
        # 🔴 Drift only ONCE A BASELINE EXISTS.  A forced value on the first read just becomes
        # the baseline and nothing ever differs -- the force would silently test nothing.  This is
        # the same fixture trap that step 5b of the inheritance checklist documents; it was fixed
        # in lib_e.sh on 2026-08-31 and NOT mirrored here, which step 5b then caught.
        [[ "$DRY_FAIL" == bootid && -n "$BOOT_BASELINE" ]] \
            && b="00000000-dead-dead-dead-000000000000" || b="dry-run-synthetic-boot-id"
    else
        b=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    fi
    [[ -n "$b" ]] || abort "#3" "boot_id unreadable; unreadable is not equal"
    if [[ -z "$BOOT_BASELINE" ]]; then
        BOOT_BASELINE="$b"; say "    boot_id=$b (baseline)"; return 0
    fi
    [[ "$b" == "$BOOT_BASELINE" ]] || abort "#3" "the machine REBOOTED mid-arm ($BOOT_BASELINE -> $b).
        Installs either side of a reboot share no /proc baseline; they are not one arm."
    say "    boot_id unchanged"
}

TOPO_BASELINE=""
assert_topology_invariant() {   # #14 -- run_e8:67
    local n
    if [[ "$DRY_RUN" == 1 ]]; then
        # Same reasoning as assert_same_boot: drift only after the baseline exists.
        [[ "$DRY_FAIL" == edgecount && -n "$TOPO_BASELINE" ]] && n=999 || n=12
    else
        n=$(curl -s -m 10 "$NDT_URL/ndt/get_graph_data" | "$PY_PROXY" -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
for k in ("edges","links"):
    v=d.get(k) if isinstance(d,dict) else None
    if isinstance(v,list): print(len(v)); raise SystemExit
print(-1)' 2>/dev/null || echo -1)
    fi
    [[ "$n" != "-1" && -n "$n" ]] || abort "#14" "edge count unreadable.  An invariant that cannot
        be evaluated must refuse, not pass."
    if [[ -z "$TOPO_BASELINE" ]]; then TOPO_BASELINE="$n"; say "    topology: edges=$n (baseline)"; return 0; fi
    [[ "$n" == "$TOPO_BASELINE" ]] || abort "#14" "edge count changed across the swap ($TOPO_BASELINE -> $n).
        The fabric was not reproduced, so the two arms are not comparable."
    say "    topology: edges=$n (matches baseline)"
}

# #11 -- the production kernel must be back before the lab is released.  This round SWAPS kernel
# binaries between arms; a failed restore leaves the next round in the queue (E) running F-5's
# pre-T-11 binary, and E cannot tell.  Loud means three channels, not a line in a log.
assert_kernel_restored() {
    local fail=0 f="$ROUND/raw/RESTORE-FAILED"
    if [[ "$DRY_RUN" == 1 ]]; then
        [[ "$DRY_FAIL" == restore ]] && { dry_note "forcing restore verification to FAIL"; fail=1; } \
            || dry_note "would assert the running kernel is post-T-11 (production) again"
    else
        local pid exe hits
        pid=$(ps -eo pid=,comm= | awk '$2=="ndtwin_kernel"{print $1; exit}')
        if [[ -z "${pid:-}" ]]; then
            say "🔴 restore: no kernel running -- cannot confirm the production binary is back"; fail=1
        else
            exe=$(sudo -n readlink -f "/proc/$pid/exe")
            hits=$(sudo -n nm -C "$exe" 2>/dev/null | grep -c setProgrammedPredicate || true)
            (( ${hits:-0} > 0 )) || { say "🔴 restore: the running kernel is still PRE-T-11"; fail=1; }
        fi
    fi
    if (( fail )); then
        say "🔴🔴🔴 KERNEL RESTORE FAILED -- DO NOT RELEASE THE LAB 🔴🔴🔴"
        say "🔴 E is next in the queue and would run F-5's binary without being able to tell."
        printf 'RESTORE-FAILED %s -- do not release the lab\n' "$(date -Is)" >&2
        [[ "$DRY_RUN" == 1 ]] || { mkdir -p "$ROUND/raw"; printf 'RESTORE-FAILED %s\n' "$(date -Is)" >"$f"; }
        return 1
    fi
    say "    restore verified: the production (post-T-11) kernel is running"
    [[ "$DRY_RUN" == 1 ]] || rm -f "$f"
    return 0
}

# -------------------------------------------------------------------------------------------------
# Clauses inherited from the D round after the per-clause walk (CROSS-ROUND-REGRESSION.md).
# Every one of these was executed by a D-round script and registered by neither new round until
# 2026-08-31.  Numbers are that document's.
# -------------------------------------------------------------------------------------------------

# #2 -- bmv2's identity.  APPLIES to the P4 arm and was missing: this round's southbound reader is
# "what the switch has", and the switch IS bmv2.  A different bmv2 build has different programming
# latency, which is the very quantity Q1/Q2 time.
record_bmv2_identity() {   # $1 = arm
    [[ "$FABRIC" == p4 ]] || { say "    bmv2 identity: n/a on the OVS arm"; return 0; }
    local f="$OUT/identity_bmv2_$1.txt" ovr="$KERNEL_DIR/p4_proxy/mininet/bmv2_binary_override"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would record the bmv2 override directive and each RUNNING simple_switch_grpc's sha256"
        return 0
    fi
    { printf 'when=%s\n' "$(date -Is)"
      printf 'override_directive=%s\n' "$(grep -vE '^[[:space:]]*(#|$)' "$ovr" 2>/dev/null | head -1)"
      printf 'override_file_sha256=%s\n' "$(sha256sum "$ovr" 2>/dev/null | cut -d' ' -f1)"
      local pid
      for pid in $(ps -eo pid=,comm= | awk '$2=="simple_switch_"{print $1}'); do
          printf 'running pid=%s exe=%s sha256=%s\n' "$pid" \
              "$(sudo -n readlink -f /proc/$pid/exe 2>/dev/null)" \
              "$(sudo -n sha256sum /proc/$pid/exe 2>/dev/null | cut -d' ' -f1)"
      done; } >"$f" 2>&1
    local n d
    n=$(grep -c '^running pid=' "$f"); d=$(grep '^running pid=' "$f" | grep -oE 'sha256=[0-9a-f]{64}' | sort -u | wc -l)
    say "    bmv2: $n switch(es), $d distinct binary/binaries -> $f"
    (( n == 0 || d == 1 )) || abort "#2" "the switches are not all running one binary ($d distinct).
        A visibility window measured across a mixture is not a window of either binary."
}

# #5 -- fabric completeness.  APPLIES: §3's load is a background mesh plus churn, and a fabric
# short of switches yields a smaller mesh, i.e. Q1's "under load" condition is not met while the
# run still produces perfectly well-formed readings.
assert_fabric_complete() {
    if [[ "$DRY_RUN" == 1 ]]; then
        [[ "$DRY_FAIL" == fabricshort ]] && abort "#5" "fabric short of its full switch count (forced)"
        dry_note "would assert the fabric is complete before trusting 'under load'"
        return 0
    fi
    if [[ "$FABRIC" == p4 ]]; then
        $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" \
            || abort "#5" "fabric is short of 10 bmv2 switches; the mesh would be smaller than §3 registers"
    else
        local n; n=$(curl -s -m 10 "$SOUTHBOUND_URL/stats/switches" 2>/dev/null | grep -o '[0-9]\+' | wc -l)
        (( n > 0 )) || abort "#5" "Ryu reports no switches; 'under load' cannot be asserted"
    fi
    say "    fabric complete"
}

# #7 / #15 -- assert the sampling CONSTANTS, against the compiled artefact as well as the source.
# 🔴 #8 rides here: the constants are the thing a NEIGHBOURING round mutates.  E seds the P4
# source and swaps binaries, E and F-5 are adjacent in the fabric queue, and run_c.sh:46 records
# this exact contamination happening once already (gate_d left truncate at 16384).  So this is not
# only "did I set it", it is "did the previous round put it back".
assert_sampling_config() {
    [[ "$FABRIC" == p4 ]] || { say "    sampling config: n/a on the OVS arm (not a P4 pipeline)"; return 0; }
    local src="$KERNEL_DIR/p4_proxy/p4_src/ndtwin_switch.p4"
    local json="$KERNEL_DIR/p4_proxy/p4_src/build/ndtwin_switch.json"
    if [[ "$DRY_RUN" == 1 ]]; then
        [[ "$DRY_FAIL" == config ]] && abort "#7/#8" "sampling config not at production values (forced)"
        dry_note "would assert SAMPLE_RATE=$EXPECT_SAMPLE_RATE and SAMPLE_TRUNC_BYTES=128 in the"
        dry_note "  source AND the compiled JSON -- also catches a neighbouring round's failed restore"
        return 0
    fi
    grep -q "^const bit<16> SAMPLE_RATE = ${EXPECT_SAMPLE_RATE};" "$src" \
        || abort "#7/#8" "SAMPLE_RATE is not $EXPECT_SAMPLE_RATE in $src.
        Both arms must share one sampling configuration, or a difference in the visibility window
        gets attributed to T-11 when it came from sampling.  If E ran before this round, check
        whether its production restore landed."
    grep -q '^const bit<32> SAMPLE_TRUNC_BYTES = 128;' "$src" \
        || abort "#7/#8" "SAMPLE_TRUNC_BYTES is not 128 in $src (see above about the previous round)"
    grep -q '"op" *: *"truncate"' "$json" 2>/dev/null \
        || abort "#7/#8" "the truncate op is absent from the compiled JSON -- bmv2 runs the artefact,
        so asserting only the source would assert the wrong file"
    say "    sampling config: SAMPLE_RATE=$EXPECT_SAMPLE_RATE truncate=128, source and compiled JSON agree"
}

# #12 -- archive kernel.log.  APPLIES, and for a STRONGER reason than the D round's: D needed it to
# resolve thread-ids against a CPU trace; here it carries the dispatcher's own record of what it
# actually programmed, which is direct evidence for R1 (a phantom is cached-but-not-programmed).
# 🔑 Unit adapted: D archived per CELL, this round's unit is an ARM of 60 installs, so it is taken
# at arm open and close rather than 60 times over one growing file.
# 🔴 The closing copy is only the whole arm if the file was neither rotated nor truncated in
# between -- and the failure direction is towards CLEAN: a rotation loses the EARLY segment, i.e.
# the early phantom evidence, so R1 would read as tidier than it was.
#
# No rotation mechanism was found (the logger uses a basic_file_sink with truncate=false and there
# is no rotating sink in src/utils/Logger.cpp; kernel.log itself is stack.sh's stdout capture).
# 🔑 That is "not found", not "asserted not to have happened", and the assertion costs one stat.
# Failure marks the arm's log evidence INCOMPLETE and does NOT abort: §4 grades this as evidence,
# not as a precondition, and aborting an arm over its evidence channel would discard the
# measurement to protect its annotation.
KLOG_OPEN_INODE=""; KLOG_OPEN_SIZE=""
archive_kernel_log() {   # $1 = arm, $2 = open|close
    local klog="$KERNEL_DIR/.test_run/logs/kernel.log" ino sz
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would copy kernel.log -> $OUT/${1}_kernel_$2.log and record its inode+size"
        if [[ "$2" == open ]]; then KLOG_OPEN_INODE=111; KLOG_OPEN_SIZE=100
            say "    kernel.log (open) archived; inode=111 size=100"
        elif [[ "$DRY_FAIL" == logrotate ]]; then
            say "    🔴 kernel.log ROTATED or TRUNCATED during the arm (inode 111 -> 222, size 100 -> 5)"
            say "    🔴 the arm's log evidence is INCOMPLETE: a rotation loses the EARLY segment,"
            say "    🔴 so R1 would read cleaner than it was.  Marked, not aborted (§4: evidence)."
            RUN touch "$OUT/${1}_LOG-EVIDENCE-INCOMPLETE"
        else say "    kernel.log (close) archived; inode unchanged, size grew"; fi
        return 0
    fi
    cp -f "$klog" "$OUT/${1}_kernel_$2.log" 2>/dev/null \
        || { say "    WARNING: no kernel.log to archive at $2 -- R1 loses its dispatcher-side evidence"
             touch "$OUT/${1}_LOG-EVIDENCE-INCOMPLETE"; return 0; }
    ino=$(stat -c%i "$klog" 2>/dev/null); sz=$(stat -c%s "$klog" 2>/dev/null)
    if [[ "$2" == open ]]; then
        KLOG_OPEN_INODE="$ino"; KLOG_OPEN_SIZE="$sz"
        say "    kernel.log (open) archived; inode=$ino size=$sz"
        return 0
    fi
    say "    kernel.log (close) archived; inode=$ino size=$sz (open: $KLOG_OPEN_INODE/$KLOG_OPEN_SIZE)"
    if [[ "$ino" != "$KLOG_OPEN_INODE" ]] || (( ${sz:-0} < ${KLOG_OPEN_SIZE:-0} )); then
        say "    🔴 kernel.log ROTATED or TRUNCATED during the arm."
        say "    🔴 The arm's log evidence is INCOMPLETE -- and what a rotation loses is the EARLY"
        say "    🔴 segment, so R1 would read CLEANER than it was.  Marked, not aborted (§4)."
        touch "$OUT/${1}_LOG-EVIDENCE-INCOMPLETE"
    fi
}

# -------------------------------------------------------------------------------------------------
preflight() {
    local avail owner excl claim="$KERNEL_DIR/.test_run/lab.claim"
    avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    say "=== preflight arm=$ARM fabric=$FABRIC DRY_RUN=$DRY_RUN disk=${avail}G ==="
    (( avail >= 3 )) || { printf 'REFUSE: only %sG free on / (need >=3G).\n' "$avail" >&2; return 1; }
    [[ -n "${NDT_OWNER:-}" ]] || { printf 'REFUSE: NDT_OWNER unset.  Source round.env first.\n' >&2; return 1; }

    # A dry run must not depend on live lab state (see lib_e.sh preflight for the reasoning).
    if [[ "$DRY_RUN" == 1 && "$DRY_FAIL" != claim ]]; then
        dry_note "synthesising claim owner=$NDT_OWNER exclusive_cpu=yes"
        owner="$NDT_OWNER"; excl=yes
    else
        owner=$(sed -n 's/^owner=//p' "$claim" 2>/dev/null || true)
        excl=$(sed -n 's/^exclusive_cpu=//p' "$claim" 2>/dev/null || true)
    fi
    [[ "$DRY_FAIL" == claim ]] && owner=somebody-else
    if [[ "$owner" != "$NDT_OWNER" ]]; then
        printf 'REFUSE: lab.claim owner=%s but NDT_OWNER=%s.\n' "${owner:-<none>}" "$NDT_OWNER" >&2
        printf '        NDT_EXCLUSIVE_CPU=1 ndt claim 240 %s\n' "'F-5 fine grid'" >&2
        printf '        §4 puts the exclusivity clause in the claim NOTE as a registered term,\n' >&2
        printf '        not a memo -- and this reading is a point sample, so it is taken again\n' >&2
        printf '        by every stage.\n' >&2
        return 1
    fi
    [[ "$excl" == yes ]] || { printf 'REFUSE: claim has exclusive_cpu=%s; §4 requires it.\n' "${excl:-unset}" >&2; return 1; }
    say "  claim: owner=$owner exclusive_cpu=$excl"

    # The fabric.  🔴 Without this the sampler would run 60 installs against nothing, every
    # control would fail, and a transcript of 60 CONTROL-FAILED lines is one careless summary away
    # from being read as 60 clean installs.
    if [[ "$DRY_RUN" == 1 && "$DRY_FAIL" != fabric ]]; then
        dry_note "synthesising fabric up and both readers answering"
    else
        if [[ "$DRY_FAIL" == fabric ]] || ! curl -s -o /dev/null -m 3 "$NDT_URL/ndt/get_graph_data"; then
            printf 'REFUSE: the kernel API at %s does not answer.\n' "$NDT_URL" >&2
            printf '        This script measures; it does not bring the lab up.  Start it first:\n' >&2
            printf '          NDT_OWNER=%s ndt up %s 4\n' "$NDT_OWNER" "$FABRIC" >&2
            return 1
        fi
        if ! curl -s -o /dev/null -m 5 "$SOUTHBOUND_URL/stats/flow/$DPID"; then
            printf 'REFUSE: the southbound reader at %s/stats/flow/%s does not answer.\n' "$SOUTHBOUND_URL" "$DPID" >&2
            printf '        §2 requires BOTH instruments at every grid point.  With one reader the\n' >&2
            printf '        round cannot separate "visible" from "programmed" at all, which is the\n' >&2
            printf '        entire question.\n' >&2
            return 1
        fi
    fi
    say "  fabric: kernel API and southbound both answering"
    return 0
}

# -------------------------------------------------------------------------------------------------
freeze_sequence() {
    # 🔴 The sequence is written to raw BEFORE the first install and read back from there, so what
    # ran is an artefact rather than a claim about what the generator would produce.
    local f="$OUT/dst_sequence.txt"
    RUN mkdir -p "$OUT"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would write the frozen $N_INSTALLS-address sequence to $f and sha256 it"
        "$HERE/f5_dst_sequence.py" -n "$N_INSTALLS" --print > "$f" 2>/dev/null || true
    else
        "$HERE/f5_dst_sequence.py" -n "$N_INSTALLS" --print > "$f" || abort "TBD-1" "the dst sequence would not generate"
    fi
    say "  dst sequence -> $f  sha256=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)  n=$(wc -l <"$f" 2>/dev/null)"
}

traffic_start() {
    # §3: background mesh plus a never-before-used pair every ~30 s.  traffic_mesh.sh is the
    # successor the TR round wrote precisely because the original traffic.sh ran ONE hardcoded
    # pair and, in its first version, silently ran zero traffic while a 600 s sampler recorded an
    # idle fabric.  It selects its pair set from what is on the fabric, not from a flag.
    local secs="$1"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: $TRH/traffic_mesh.sh start $secs \${MESH_MBPS:-20}   (mesh + ${CHURN_EVERY_S}s churn)"
        dry_note "would then run: $TRH/traffic_mesh.sh ledger pre   (counter snapshot, so offered rate comes from the datapath)"
        return 0
    fi
    [[ -x "$TRH/traffic_mesh.sh" ]] || abort "§3" "traffic_mesh.sh not found at $TRH"
    "$TRH/traffic_mesh.sh" start "$secs" "${MESH_MBPS:-20}" >>"$LOG" 2>&1 || abort "§3" "traffic would not start"
    "$TRH/traffic_mesh.sh" ledger pre >>"$LOG" 2>&1 || true
    sleep 10
}
traffic_stop() {
    if [[ "$DRY_RUN" == 1 ]]; then dry_note "would run: $TRH/traffic_mesh.sh ledger post; then stop (TERM by recorded pid)"; return 0; fi
    "$TRH/traffic_mesh.sh" ledger post >>"$LOG" 2>&1 || true
    "$TRH/traffic_mesh.sh" stop >>"$LOG" 2>&1 || true
}

# -------------------------------------------------------------------------------------------------
# One arm: Q1 or Q2.  Same procedure, different binary -- that is the whole design.
# -------------------------------------------------------------------------------------------------
arm() {
    preflight || exit 2
    assert_arm_binary
    local sha_open sha_close; sha_open=$(running_kernel_sha)
    say "=== arm $ARM: bracket OPEN, running exe sha256=$sha_open ==="
    assert_same_boot                 # #3
    assert_topology_invariant        # #14
    assert_fabric_complete           # #5
    assert_sampling_config           # #7 / #8 -- also catches a neighbour's failed restore
    record_bmv2_identity "$ARM"      # #2
    archive_kernel_log "$ARM" open   # #12
    freeze_sequence

    # Binary identity for the record (§4): the four fields, because three of them are each
    # individually insufficient and RUNPATH -- not the environment -- decides which .so loads.
    if [[ "$DRY_RUN" != 1 ]]; then
        { printf 'arm=%s\nwhen=%s\nrunning_exe_sha256=%s\n' "$ARM" "$(date -Is)" "$sha_open"
          printf 'commit_tip=%s\ndirty=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)" \
                 "$(git -C "$KERNEL_DIR" status --porcelain | wc -l)"
          printf -- '--- ldd ---\n';        ldd "$KBIN" 2>&1
          printf -- '--- readelf -d ---\n'; readelf -d "$KBIN" 2>&1 | grep -E 'RUNPATH|RPATH|NEEDED'
        } >"$OUT/identity_$ARM.txt"
    else
        dry_note "would write $OUT/identity_$ARM.txt (sha256 + ldd + readelf -d RUNPATH + symbols)"
    fi

    local secs=$(( N_INSTALLS * 20 + 120 ))
    traffic_start "$secs"

    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: $PY_PROXY $HERE/f5_sampler.py --arm $ARM --dst-file $OUT/dst_sequence.txt"
        dry_note "  --ndt $NDT_URL --southbound $SOUTHBOUND_URL --dpid $DPID --skew-limit-ms $SKEW_LIMIT_MS --out $OUT"
        dry_note "  (60 installs x 10 grid points x 2 instruments, alternating call order)"
    else
        TRH="$TRH" "$PY_PROXY" "$HERE/f5_sampler.py" --arm "$ARM" \
            --dst-file "$OUT/dst_sequence.txt" --ndt "$NDT_URL" \
            --southbound "$SOUTHBOUND_URL" --dpid "$DPID" \
            --skew-limit-ms "$SKEW_LIMIT_MS" --grid "$GRID" --out "$OUT" 2>&1 | tee -a "$LOG"
    fi
    traffic_stop

    _DRY_PHASE=close; sha_close=$(running_kernel_sha); _DRY_PHASE=
    say "=== arm $ARM: bracket CLOSE, running exe sha256=$sha_close ==="
    if [[ ! "$sha_open" =~ ^[0-9a-f]{64}$ ]] || [[ ! "$sha_close" =~ ^[0-9a-f]{64}$ ]]; then
        abort "§4 F4" "the bracket could not be READ (open=$sha_open close=$sha_close).
        Two unreadable ends compare EQUAL, so this must refuse rather than pass -- an unreadable
        bracket is the shape of a check that never ran, not of one that succeeded."
    fi
    if [[ "$sha_open" != "$sha_close" ]]; then
        abort "§4 F4" "the running kernel changed during arm $ARM ($sha_open -> $sha_close).
        The arm is VOID and must be re-run.  This is not a warning: the claim protects the
        fabric, not the binary, and a mid-arm swap makes every install in it unattributable."
    fi

    # -- R1, as code (§3-judgement).  Any phantom on a post-T-11 arm is a regression FINDING.
    #    🔴 The stop is SCOPED: Q3 stops, Q2 CONTINUES.  Q2 is Adam's material for re-ruling F-5
    #    and is logically independent of whether the fix regressed.  A blanket stop would destroy
    #    the deliverable in order to report the finding.
    if [[ "$ARM" == *-post ]] && [[ "$DRY_RUN" != 1 ]]; then
        local hits; hits=$(grep -c '"verdict": "HIT"' "$OUT/f5_installs_$ARM.jsonl" 2>/dev/null || echo 0)
        if [[ "${hits:-0}" -gt 0 ]]; then
            printf 'R1-TRIGGERED\n' > "$ROUND/raw/R1-TRIGGERED"
            say "🔴 R1: $hits phantom(s) on a POST-T-11 binary.  The fix has regressed to a FINDING."
            say "🔴 §3 R1 stop scope: Q3 is CANCELLED (a deliberate-trigger upper bound is"
            say "🔴 meaningless while the fix is known broken).  Q2 CONTINUES -- it is the"
            say "🔴 material for Adam's re-ruling and does not depend on Q1's answer."
            say "🔴 The round stops on this evidence; do not re-run the arm hoping for zero."
        fi
    fi
    assert_same_boot                 # #3, closing the bracket
    assert_topology_invariant        # #14, across the arm
    archive_kernel_log "$ARM" close  # #12
    say "=== arm $ARM complete -> $OUT ==="
}

# -------------------------------------------------------------------------------------------------
# Q3 (§1 Q3, cadence = 【TBD-3】).  Interleaved install/list, hammered, pre-T-11 only.
# Reports an UPPER BOUND per hundred interleaved operations and never extrapolates a natural rate:
# "the accidental case understates the deliberate case" cuts both ways, and the deliberate number
# says nothing about how often it happens by itself.
# -------------------------------------------------------------------------------------------------
q3() {
    if [[ -f "$ROUND/raw/R1-TRIGGERED" ]]; then
        say "🔴 REFUSING Q3: R1 fired on a post-T-11 arm (see $ROUND/raw/R1-TRIGGERED)."
        say "   §3 R1 cancels Q3 when the fix is known broken.  Q2 is unaffected and may proceed."
        exit 3
    fi
    [[ "$ARM" == *-pre ]] || abort "§1 Q3" "Q3 runs on the PRE-T-11 binary only; ARM='$ARM'"
    preflight || exit 2
    assert_arm_binary
    freeze_sequence
    # 🔴 The address budget, as code.  A repeated dst makes the second install a MODIFY, and a
    # modify produces no cached row at all -- so an over-budget Q3 would read as "fewer phantoms"
    # for a reason with nothing to do with T-11.  Raising the budget means registering a second
    # address range, which is an amendment and only available before data.
    local ops=$(( Q3_ROUNDS * Q3_BURST ))
    if (( ops > N_INSTALLS )); then
        abort "§3 / TBD-3" "Q3 would drive $ops operations against a frozen budget of $N_INSTALLS
        addresses.  The overflow would repeat destinations, turning those installs into modifies,
        which produce no cached row -- the arm would read as 'fewer phantoms' for a reason that
        has nothing to do with T-11.  Register a second address range first, before any data."
    fi
    say "=== Q3 adversarial: $Q3_ROUNDS bursts x $Q3_BURST installs = $ops ops (budget $N_INSTALLS) ==="
    say "🔴 【TBD-3】 is a DRAFT.  These three numbers are not frozen by PREREG v0.2; running Q3"
    say "🔴 before they are ruled would be choosing the cadence after seeing the fabric."
    if [[ -z "${Q3_CADENCE_RULED:-}" ]]; then
        say "   Set Q3_CADENCE_RULED=1 once the reviewer has ruled TBD-3, then re-run."
        exit 3
    fi
    traffic_start $(( Q3_ROUNDS * Q3_BURST * 2 + 60 ))
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would drive $((Q3_ROUNDS * Q3_BURST)) install/list pairs at ${Q3_GAP_MS}ms spacing"
        dry_note "and report hits per hundred interleaved operations -- an UPPER BOUND, never a rate"
    else
        TRH="$TRH" Q3_BURST="$Q3_BURST" Q3_GAP_MS="$Q3_GAP_MS" Q3_ROUNDS="$Q3_ROUNDS" \
            "$PY_PROXY" "$HERE/f5_sampler.py" --arm "$ARM-q3" \
            --dst-file "$OUT/dst_sequence.txt" --ndt "$NDT_URL" \
            --southbound "$SOUTHBOUND_URL" --dpid "$DPID" \
            --skew-limit-ms "$SKEW_LIMIT_MS" --grid "0 0.05 0.1 0.25 0.5" --out "$OUT" 2>&1 | tee -a "$LOG"
    fi
    traffic_stop
}

selftest() {
    # The detector's force tests.  No fabric, no claim -- deliberately runnable outside the
    # window, because a detector first exercised inside a scarce window is a detector whose own
    # bugs are paid for in scarce time.  memory/new-tools-are-the-first-thing-under-test.
    local rc=0 s
    say "=== f5 detector force tests (no fabric required) ==="
    for s in phantom clean blind; do
        say "--- scenario $s ---"
        TRH="$TRH" python3 "$HERE/f5_sampler.py" --dry-scenario "$s" --arm "selftest-$s" \
            --out "${SELFTEST_OUT:-$ROUND/raw/selftest}" --dst 10.0.0.180 --dst 10.0.0.187 \
            2>&1 | tail -6 | tee -a "$LOG" || rc=1
    done
    # The three inherited clauses, each forced RED -- and #11 forced GREEN too, because a check
    # that is always red is not a check either.  "Restore failure must be loud" is itself a claim
    # that can be vacuously true: if nobody has seen it shout, it is an empty pass.
    say "--- inherited clauses #3 / #11 / #14, forced ---"
    local o
    o=$( ( DRY_RUN=1 DRY_FAIL=restore assert_kernel_restored ) 2>&1 || true)
    [[ "$o" == *"DO NOT RELEASE THE LAB"* ]] && say "  #11 force-red  PASS" || { say "  #11 force-red  FAIL"; rc=1; }
    o=$( ( DRY_RUN=1 DRY_FAIL= assert_kernel_restored ) 2>&1 || true)
    [[ "$o" == *"restore verified"* ]] && say "  #11 force-green PASS" || { say "  #11 force-green FAIL"; rc=1; }
    o=$( ( DRY_RUN=1 BOOT_BASELINE=dry-run-synthetic-boot-id DRY_FAIL=bootid assert_same_boot ) 2>&1 || true)
    [[ "$o" == *"REBOOTED mid-arm"* ]] && say "  #3  force-red  PASS" || { say "  #3  force-red  FAIL"; rc=1; }
    o=$( ( DRY_RUN=1 TOPO_BASELINE=12 DRY_FAIL=edgecount assert_topology_invariant ) 2>&1 || true)
    [[ "$o" == *"edge count changed"* ]] && say "  #14 force-red  PASS" || { say "  #14 force-red  FAIL"; rc=1; }
    (( rc == 0 )) && say "=== detector + inherited-clause force tests PASS ===" || say "🔴 force tests FAILED"
    return $rc
}

plan() {
    say "=== F-5 plan ==="
    say "arm            $ARM   fabric=$FABRIC   dpid=$DPID"
    say "endpoints      kernel=$NDT_URL   southbound=$SOUTHBOUND_URL/stats/flow/$DPID"
    say "installs       $N_INSTALLS  (single-arm 95% upper bound on zero hits = $(awk -v n="$N_INSTALLS" 'BEGIN{printf "%.1f", 300/n}')%)"
    say "grid           $GRID  s since the POST returned"
    say "skew limit     ${SKEW_LIMIT_MS}ms; over it a point is INDETERMINATE and KEPT, never dropped"
    say "estimate       ~$(( N_INSTALLS * 15 / 60 )) min of sampling per arm, plus bring-up"
    say ""
    say "🔴 the independent unit is one INSTALL, not one grid point.  Ten points on one install"
    say "🔴 are repeated observations of one event; pooling runs along the install axis only."
    say "🔴 cross-arm pooling is legal ONLY if both arms are zero (n=120 => <=2.5%), and must"
    say "🔴 state that it crosses two different fabrics."
}

# Same reasoning as run_e.sh: `plan`, `selftest` and `restore` execute for real and need no
# fabric, so they are not dry runs -- but none of them is a measurement, and their transcripts
# must not share a file with one.
case "${1:-plan}" in
    plan|selftest|restore) LOG="${LOG%.log}.$1.log" ;;
esac

case "${1:-plan}" in
    plan)     plan ;;
    selftest) selftest ;;
    restore)  preflight && assert_kernel_restored ;;
    arm)      arm ;;
    q3)       q3 ;;
    *) printf 'usage: %s {plan|selftest|arm|q3|restore}\n' "$0" >&2; exit 2 ;;
esac
