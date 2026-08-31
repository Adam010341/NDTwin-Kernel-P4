#!/usr/bin/env bash
# =================================================================================================
# run_e.sh -- the E round's ladder: 2x2 (batching x recompute period) plus the BL-true control.
#             PREREG 2026-08-31_sampling-ceiling-after-merge §3.
#
# [Co-developed with claude code -- Adam]
#
#     . doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env
#     ./run_e.sh plan              # cell list + wall-clock estimate; touches nothing
#     ./run_e.sh gates             # hand off to gates_e.sh (§2 must be green first)
#     ./run_e.sh ladder            # the 2x2, low rate -> high rate
#     ./run_e.sh bltrue            # the fifth control cell, wall-side three rungs only
#     DRY_RUN=1 ./run_e.sh ladder  # every branch, no side effects, full transcript
#
# WHAT IS FROZEN HERE AND WHY IT IS HERE RATHER THAN IN A SHELL.
#   The ladder, the arms, the interleave and the reps are read from round.env, which is committed.
#   memory/put-measurement-commands-in-script-files: a bracket protects a pattern, not a command,
#   and a value typed at a prompt has no provenance.  Every number this round used is recoverable
#   from the commit that ran it.
#
# THE LADDER-TOP DISCIPLINE (§3 E1) IS THE PART THAT IS EASY TO GET BACKWARDS.
#   * The top rung's availability is judged on MP -- the production-side cell, expected highest --
#     never on BL.  Dropping the top rung because BL died there would cut exactly where the
#     effect is.  So there is NO stop condition in this loop that removes a rung.
#   * A cell that reads healthy at the top rung is recorded as RIGHT-CENSORED (">=1/1"), never as
#     "the ceiling is 1/1".  Two censored cells compared to each other are INDISTINGUISHABLE.
#   * No rung is ever added after freezing (§3 (c), C5).  `plan` prints the full list up front so
#     that "we should have gone higher" is a finding, not an edit.
#
# ORDER.  Low sampling rate first (1/1024 -> 1/1).  Sampling gets heavier as the ladder climbs, so
# when it breaks every completed cell is still valid; the reverse order risks the lot.  Within a
# rung the arms are interleaved BL,M,P,MP and repeated REPS times, so drift across the rung is
# shared by all four arms instead of being confounded with one of them.
# =================================================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${ROUND:-}" ]] || . "$HERE/round.env"
LOG="$ROUND/run_e.log"
# shellcheck source=lib_e.sh
. "$HERE/lib_e.sh"

RESULTS="$OUT/cells.tsv"
CENSOR_RUNG=1          # the top of the frozen ladder: healthy here means ">=1/1", not "= 1/1"

# arm -> (kernel recompute arm, sflow batch value).  This is the 2x2, written once.
arm_kernel() { case "$1" in bl|m) echo 1khz ;; p|mp) echo 1hz ;; *) echo "?" ;; esac; }
arm_batch()  { case "$1" in bl|p) echo "$BATCH_OFF" ;; m|mp) echo "$BATCH_ON" ;; *) echo "?" ;; esac; }
cell_name()  { printf 'e_%s_%04d_%d' "$1" "$2" "$3"; }   # e_bl_0016_2 -- zero padded, mutually
                                                          # exclusive prefixes (the `m1*` lesson)

# -------------------------------------------------------------------------------------------------
plan() {
    local rate arm rep n=0
    say "=== E round plan (frozen at v0.2; nothing below is chosen at run time) ==="
    say "ladder     1/{$(echo "$LADDER" | tr ' ' ',')}"
    say "arms       $ARM_ORDER   (bl=off/1kHz  m=on/1kHz  p=off/1Hz  mp=on/1Hz)"
    say "reps       $REPS, interleaved within each rung"
    say "duration   ${DUR}s per cell at ${RATE_MBIT} Mbit/s offered"
    say "batch      off=$BATCH_OFF  on=$BATCH_ON"
    say ""
    for rate in $LADDER; do for rep in $(seq 1 "$REPS"); do for arm in $ARM_ORDER; do
        n=$((n+1)); printf '  %3d  %s  kernel=%-5s batch=%s\n' \
            "$n" "$(cell_name "$arm" "$rate" "$rep")" "$(arm_kernel "$arm")" "$(arm_batch "$arm")"
    done; done; done
    local nb=0
    for rate in $BLTRUE_RUNGS; do for rep in $(seq 1 "$REPS"); do
        nb=$((nb+1)); printf '  B%02d  %s  (control, §3a)\n' "$nb" "$(cell_name blt "$rate" "$rep")"
    done; done
    # Wall clock.  From wall_f.out, a cell with a full teardown+bringup cost ~45 s of overhead on
    # this fabric; the estimate is stated so that the schedule is a decision and not a surprise.
    local total=$(( (n + nb) * (DUR + 45) ))
    say ""
    say "cells      $n ladder + $nb control = $((n + nb))"
    say "estimate   ~$(( total / 3600 ))h $(( (total % 3600) / 60 ))m of EXCLUSIVE fabric,"
    say "           at DUR=${DUR}s + ~45s bring-up per cell.  🔴 This does not fit beside the"
    say "           9/03 preparation window; PREREG §4 forbids overlapping it.  Adam schedules."
    say "           DUR=120 (gate_e/wall_f's value) would make it ~$(( (n+nb)*165/3600 ))h -- see TBD-DRAFT.md D5."
}

# -------------------------------------------------------------------------------------------------
# One cell.  Everything that could differ between two cells is recorded per cell, not per run.
# -------------------------------------------------------------------------------------------------
run_cell() {   # $1 = arm, $2 = rate, $3 = rep
    local arm="$1" rate="$2" rep="$3"
    local cell; cell=$(cell_name "$arm" "$rate" "$rep")
    local kern batch; kern=$(arm_kernel "$arm"); batch=$(arm_batch "$arm")

    if [[ -f "$RESULTS" ]] && grep -q "^$cell	" "$RESULTS"; then
        say "--- $cell: already recorded, skipping (resume) ---"; return 0
    fi
    say "--- $cell  arm=$arm rate=1/$rate rep=$rep kernel=$kern batch=$batch ---"

    # 🔴 The claim is re-read at the moment of acting.  A reading taken at the top of a 10-hour
    # run is a point sample of a lease that may have expired eight hours ago.
    preflight measure >/dev/null || abort "§4" "preconditions no longer hold at cell $cell"

    teardown
    swap_kernel "$kern"
    bringup "$batch" || abort "bringup" "$cell: the fabric would not come up"
    assert_batch_took "$batch"
    assert_truncate_128

    # Bracket identity (F-5 §4 F4's discipline, applied here): the running process's exe at the
    # start and at the end.  A claim protects the fabric, not the file on disk -- on 08-30 a
    # rebuild landed 9 seconds before an exec.
    local sha_open sha_close; sha_open=$(running_kernel_sha)
    say "    running kernel exe sha256 (open)  $sha_open"

    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: POLL=on $PRIOR/measure.sh $cell $DUR $RATE_MBIT"
        dry_note "would then read the verdict from cell_verdict.py and append it to $RESULTS"
    else
        foreign_iperf3_guard || abort "$cell" "a foreign iperf3 appeared; measure.sh would destroy it"
        POLL=on "$PRIOR/measure.sh" "$cell" "$DUR" "$RATE_MBIT" >>"$LOG" 2>&1
    fi

    sha_close=$(running_kernel_sha)
    say "    running kernel exe sha256 (close) $sha_close"
    if [[ "$sha_open" != "$sha_close" ]]; then
        abort "identity" "$cell: the running kernel changed mid-cell ($sha_open -> $sha_close).
        The cell is void.  Per F-5 §4 F4's rule, a bracket that does not close discards the arm."
    fi

    local v
    if [[ "$DRY_RUN" == 1 ]]; then
        v="cell=$cell  mark=OK  ratio=0.99  lam=1000  distinct=50  (synthetic)"
    else
        v=$(PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$ROUND25/cell_verdict.py" "$cell" 2>&1 | tail -1)
    fi
    say "    VERDICT $v"

    # Right-censoring at the top rung -- recorded per cell so the analysis cannot forget it.
    local censor="-"
    [[ "$rate" == "$CENSOR_RUNG" && "$v" != *SATURATED* && "$v" != *NO-DATA* ]] && censor=">=1/1"
    [[ "$censor" != "-" ]] && say "    RIGHT-CENSORED: healthy at the top of the frozen ladder."
    [[ "$censor" != "-" ]] && say "                    Record as '>=1/1'.  Two censored cells are"
    [[ "$censor" != "-" ]] && say "                    INDISTINGUISHABLE, never equal (§3 E1b)."

    RUN mkdir -p "$OUT"
    if [[ "$DRY_RUN" != 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$cell" "$arm" "$rate" "$rep" "$kern" "$batch" "$censor" "$sha_open" "$v" >>"$RESULTS"
    fi
    archive_cell "$cell"

    # -- E-P4, as code (§3b).  Merge must not change `ratio`.  The comparison is against this
    #    rung's batching-OFF partner at the same rep, and it reuses cell_verdict's own frozen
    #    0.95 rather than inventing a second threshold: if the off cell is ratio-healthy and the
    #    on cell is not, `ratio` moved with batching.
    #    🔴 That is a batching BUG -- most likely `_pending` unflushed at the end -- and NOT a
    #    ceiling movement.  The round stops and reports the bug; it does not read it as an effect.
    if [[ "$arm" == m || "$arm" == mp ]] && [[ "$DRY_RUN" != 1 ]]; then
        local partner pv
        partner=$(cell_name "$( [[ $arm == m ]] && echo bl || echo p )" "$rate" "$rep")
        pv=$(grep -m1 "^$partner	" "$RESULTS" 2>/dev/null || true)
        if [[ -n "$pv" && "$pv" != *SATURATED* && "$v" == *SATURATED* ]]; then
            abort "§3b E-P4" "$cell is ratio-saturated while its batching-off partner $partner is not.
        Merge changed \`ratio\`.  PREREG §3b: this is a batching implementation bug (most likely
        \`_pending\` not flushed at the end), NOT evidence that the ceiling moved, and it must not
        be reported as one."
        fi
    fi
}

# -------------------------------------------------------------------------------------------------
ladder() {
    local rate arm rep
    preflight measure || exit 2
    record_identity "ladder-open" "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
    say "=== run_e ladder start; ladder='$LADDER' arms='$ARM_ORDER' reps=$REPS DUR=${DUR}s ==="
    say "🔴 no rung, rep or arm is added from here on (C5).  If the ladder proves too short, that"
    say "🔴 is a finding to register for the NEXT round, not an edit to this one."
    for rate in $LADDER; do
        say "===== rung 1/$rate ====="
        teardown
        compile_at "$rate"
        for rep in $(seq 1 "$REPS"); do
            for arm in $ARM_ORDER; do run_cell "$arm" "$rate" "$rep"; done
        done
    done
    restore_production || say "🔴 production restore FAILED -- check before releasing the lab"
    say "=== ladder complete -> $RESULTS ==="
}

# -------------------------------------------------------------------------------------------------
# The fifth control cell, PREREG §3a.
#
# 🔴 REGISTERED AS `a3bb761^`, AND `a3bb761^` DOES NOT RUN.  Checked before the window, which is
# the whole point of checking before the window:
#     a3bb761^ p4_proxy/proxy_agent/main.py:80   SFlowEmitter(batch_size=int(os.environ...))
#     a3bb761^ p4_proxy/proxy_agent/sflow_emitter.py:257  def __init__(self, collector, ...,
#                                                          started_at=None)      <- no batch_size
# The wiring commit (9487643, 08-26) is an ancestor of a3bb761^, while the implementation was
# only rescued into version control by a3bb761 itself ("written by 8/25 mainDev and never
# committed" -- its own message).  So that tree raises TypeError at proxy start.
#
# PREREG §3a(c) already registers what happens then: "equivalence disproved, OR a3bb761^ cannot be
# built => rewrite the claim scope".  This script therefore REFUSES to invent a substitute tree on
# its own -- picking a different parent is an amendment, and an amendment is the reviewer's, not
# the runner's.  See TBD-DRAFT.md D2.  Set BLTRUE_TREE explicitly once that is ruled.
# -------------------------------------------------------------------------------------------------
bltrue() {
    local rate rep
    if [[ -z "${BLTRUE_TREE:-}" ]]; then
        say "🔴 BL-true is NOT runnable as registered."
        say "   §3a(a) names a3bb761^ as the pre-batching tree.  It is not one: its main.py passes"
        say "   batch_size= to an SFlowEmitter whose __init__ does not accept it, so the proxy"
        say "   raises TypeError at import time.  Verified from git, before any data was touched."
        say "   §3a(c) is therefore in force: BL is recorded as 'the batching code at batch_size=1',"
        say "   NEVER as 'old behaviour' or 'pre-batching', and R-E1's language becomes"
        say "   'switching the batching parameter', not 'with and without batching'."
        say "   To run a substitute control, the reviewer must rule the tree first and pass it as"
        say "   BLTRUE_TREE=<path>.  This script will not choose one."
        return 3
    fi
    preflight measure || exit 2
    # Assert the substitute really is pre-batching, in the artefact that will run.  An unasserted
    # control is a cell that looks like a control.
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would assert: $BLTRUE_TREE/sflow_emitter.py has no batching branch, and"
        dry_note "  its sha256 differs from production's"
    else
        grep -q 'self.batch_size' "$BLTRUE_TREE/sflow_emitter.py" 2>/dev/null \
            && abort "§3a" "BLTRUE_TREE still contains the batching implementation; it is not a control"
        [[ "$(sha256sum "$BLTRUE_TREE/sflow_emitter.py" | cut -d' ' -f1)" \
           != "$(sha256sum "$KERNEL_DIR/p4_proxy/proxy_agent/sflow_emitter.py" | cut -d' ' -f1)" ]] \
            || abort "§3a" "BLTRUE_TREE's emitter is byte-identical to production's; nothing is controlled"
    fi
    say "=== BL-true control: rungs $BLTRUE_RUNGS only (§3a: the wall side is where equivalence matters) ==="
    for rate in $BLTRUE_RUNGS; do
        teardown; compile_at "$rate"
        for rep in $(seq 1 "$REPS"); do run_cell blt "$rate" "$rep"; done
    done
    restore_production || say "🔴 production restore FAILED"
}

case "${1:-plan}" in
    plan)   preflight plan >/dev/null || true; plan ;;
    gates)  exec "$HERE/gates_e.sh" ;;
    ladder) ladder ;;
    bltrue) bltrue ;;
    *) printf 'usage: %s {plan|gates|ladder|bltrue}\n' "$0" >&2; exit 2 ;;
esac
