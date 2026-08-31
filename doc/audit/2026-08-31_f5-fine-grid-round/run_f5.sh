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
    [[ "$DRY_RUN" == 1 ]] && { echo "DRYRUN-synthetic-running-sha"; return 0; }
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
preflight() {
    local avail owner excl claim="$KERNEL_DIR/.test_run/lab.claim"
    avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    say "=== preflight arm=$ARM fabric=$FABRIC DRY_RUN=$DRY_RUN disk=${avail}G ==="
    (( avail >= 3 )) || { printf 'REFUSE: only %sG free on / (need >=3G).\n' "$avail" >&2; return 1; }
    [[ -n "${NDT_OWNER:-}" ]] || { printf 'REFUSE: NDT_OWNER unset.  Source round.env first.\n' >&2; return 1; }

    if [[ "$DRY_RUN" == 1 && ! -f "$claim" ]]; then
        dry_note "no lab.claim; synthesising owner=$NDT_OWNER exclusive_cpu=yes"
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

    sha_close=$(running_kernel_sha)
    say "=== arm $ARM: bracket CLOSE, running exe sha256=$sha_close ==="
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
    say "=== Q3 adversarial: $Q3_ROUNDS bursts x $Q3_BURST installs, gap ${Q3_GAP_MS}ms (【TBD-3】) ==="
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
    (( rc == 0 )) && say "=== detector force tests PASS ===" || say "🔴 detector force tests FAILED"
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

case "${1:-plan}" in
    plan)     plan ;;
    selftest) selftest ;;
    arm)      arm ;;
    q3)       q3 ;;
    *) printf 'usage: %s {plan|selftest|arm|q3}\n' "$0" >&2; exit 2 ;;
esac
