#!/usr/bin/env bash
#
# run_cells.sh -- the regression grid. Runs the cells in this directory, one at a time, restoring
# the lab between them, and prints one summary line whose FAIL count is the number the night
# round reports.
#
# [Co-developed with claude code -- Adam]
#
#   run_cells.sh                                 every cell
#   run_cells.sh --tag ndt                       only the cells whose subject is `ndt`
#   run_cells.sh --cell half_stack_is_not_clean  one cell
#   run_cells.sh --requires none                 only the cells that need no lab at all
#   run_cells.sh --list                          what would run, and nothing else
#
#   --tag ndt|kernel|proxy      the subject a cell is about; a merge that touched `ndt` runs
#                               `--tag ndt` and nothing else.
#   --cell <name>               repeatable.
#   --requires none|idle|ovs4|p4-4
#                               a FILTER on what a cell needs, not a promise about what is there:
#                                 none  nothing -- safe while another session holds the lab
#                                 idle  the lab must be down; the cell runs an `ndt` verb
#                                 ovs4  the cell brings up the OVS 4-host fabric itself
#                                 p4-4  the cell brings up the P4 4-host fabric itself
#   --raw-root <dir>            default $NDT_ROOT/.test_run/live_cells
#   --no-restore                skip the between-cell restore. For debugging one cell; NEVER for
#                               a round, and it says so on the summary line.
#
# NDT_ROOT names the checkout whose `ndt` is driven (default: this repo). The cells are the
# instrument; the tree under test is whichever one NDT_ROOT points at, so a night round can run
# this grid out of a worktree against the main checkout's `ndt` -- which is the only `ndt` the
# lab helper acts for.
#
# 🔴 RESTORE BETWEEN CELLS, and in this order, because the order is load-bearing:
#     orphans_verdict.sh   BEFORE the down -- the network half cannot be asked once :8000 is shut
#     ndt down
#     ndt clean
#     orphans_verdict.sh   AFTER -- the process half, with its kernel-down sentence
# A restore that fails stops the grid. Carrying on would attribute the next cell's red to the
# next cell, and the state it inherited is not its own.
#
# Exit: 0 every cell PASS or SKIP, 1 some cell FAILED, 2 the harness could not run (no cells
#       matched, a restore failed, NDT_ROOT has no ndt).
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
NDT="$NDT_ROOT/tools/test_workflow/ndt"
VERDICT="$NDT_ROOT/tools/test_workflow/orphans_verdict.sh"
export NDT_OWNER="${NDT_OWNER:-overnight-0905}"

WANT_TAG=""; WANT_REQ=""; LIST=0; RESTORE=1
declare -a WANT_CELLS=()
RAW_ROOT="$NDT_ROOT/.test_run/live_cells"
while (( $# )); do
    case "$1" in
        --tag)        WANT_TAG="${2:-}"; shift 2 ;;
        --cell)       WANT_CELLS+=("${2:-}"); shift 2 ;;
        --requires)   WANT_REQ="${2:-}"; shift 2 ;;
        --raw-root)   RAW_ROOT="${2:-}"; shift 2 ;;
        --list)       LIST=1; shift ;;
        --no-restore) RESTORE=0; shift ;;
        -h|--help)    sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "run_cells.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -r "$NDT" ]] || { echo "run_cells.sh: no ndt at $NDT (NDT_ROOT=$NDT_ROOT)" >&2; exit 2; }

# --- which cells --------------------------------------------------------------------------------
# A cell's tag and requirement come out of the cell itself (`<cell> meta`), never out of a table
# here: a table is a second place for the answer to be wrong, and it would go stale silently.
declare -a CELLS=()
for f in "$HERE"/*.sh; do
    b="$(basename "$f")"
    [[ "$b" == run_cells.sh || "$b" == _cell_lib.sh ]] && continue
    if ! meta="$(bash "$f" meta 2>&1)"; then
        echo "run_cells.sh: $b meta failed -- a cell that cannot be read is not a cell that passed" >&2
        echo "$meta" | sed 's/^/    /' >&2
        exit 2
    fi
    name="$(sed -n 's/^name=//p' <<<"$meta")"
    tag="$(sed -n 's/^tag=//p' <<<"$meta")"
    req="$(sed -n 's/^requires=//p' <<<"$meta")"
    [[ "$name" == "${b%.sh}" ]] || {
        echo "run_cells.sh: $b calls itself '$name' -- the file name and the cell name must agree" >&2
        exit 2; }
    [[ -n "$WANT_TAG" && "$tag" != "$WANT_TAG" ]] && continue
    [[ -n "$WANT_REQ" && "$req" != "$WANT_REQ" ]] && continue
    if (( ${#WANT_CELLS[@]} )); then
        hit=0; for w in "${WANT_CELLS[@]}"; do [[ "$w" == "$name" ]] && hit=1; done
        (( hit )) || continue
    fi
    CELLS+=("$name|$tag|$req")
done

if (( ${#CELLS[@]} == 0 )); then
    echo "run_cells.sh: no cell matched (tag=${WANT_TAG:-any} requires=${WANT_REQ:-any} cell=${WANT_CELLS[*]:-any})" >&2
    exit 2
fi

if (( LIST )); then
    printf '%-46s %-8s %s\n' NAME TAG REQUIRES
    for c in "${CELLS[@]}"; do
        IFS='|' read -r n t r <<<"$c"; printf '%-46s %-8s %s\n' "$n" "$t" "$r"
    done
    exit 0
fi

DAY="$(date +%Y-%m-%d)"
OUT="$RAW_ROOT/$DAY"
mkdir -p "$OUT" || { echo "run_cells.sh: cannot create $OUT" >&2; exit 2; }

# --- the restore ---------------------------------------------------------------------------------
restore() {   # <label> -> 0 clean, 1 not
    # 🔴 `rdir` on its own line. `local lab="$1" rdir="$OUT/_restore-$lab"` is wrong for a reason
    # worth keeping: every word of a builtin's command line is expanded BEFORE the builtin runs,
    # so `$lab` there is the CALLER's -- which under `set -u` is an unbound-variable abort in the
    # middle of a restore, i.e. the lab left as the cell left it. Found 2026-09-11 by driving this
    # runner against a recording fake `ndt`; the same shape had just been caught in
    # tests/shell/mutate_live_cells.sh by its controls.
    local lab="$1" orc vrc
    local rdir="$OUT/_restore-$lab"
    mkdir -p "$rdir"
    # BEFORE the down: the network half is only answerable while :8000 is open.
    timeout 180 bash "$NDT" apps orphans > "$rdir/1-orphans-predown.txt" 2>&1; orc=$?
    bash "$VERDICT" "$rdir/1-orphans-predown.txt" "$orc" > "$rdir/2-verdict-predown.txt" 2>&1
    printf 'orphans_rc=%s verdict_rc=%s\n' "$orc" "$?" >> "$rdir/2-verdict-predown.txt"
    timeout 420 bash "$NDT" down > "$rdir/3-down.log" 2>&1
    local drc=$?; printf '%s\n' "$drc" > "$rdir/3-down.rc"
    timeout 180 bash "$NDT" clean > "$rdir/4-clean.log" 2>&1
    local crc=$?; printf '%s\n' "$crc" > "$rdir/4-clean.rc"
    timeout 180 bash "$NDT" apps orphans > "$rdir/5-orphans-postclean.txt" 2>&1; orc=$?
    bash "$VERDICT" "$rdir/5-orphans-postclean.txt" "$orc" > "$rdir/6-verdict-postclean.txt" 2>&1
    vrc=$?
    printf 'orphans_rc=%s verdict_rc=%s\n' "$orc" "$vrc" >> "$rdir/6-verdict-postclean.txt"
    # 🔴 The verdict is read from the LINE, not from the rc of `ndt apps orphans` (which is 2 on
    # this machine whenever an app ran as root) and not from grep CLEAN alone -- `NOT CLEAN` and
    # `NOT CHECKED` both contain neither. ded00d06's rc 3 is a refusal too.
    #
    # 🔴 2026-09-12, FIX-NDT-8 (Adam, form 1 Q1). BACK TO A HARD JUDGEMENT, on a vocabulary that
    # can now carry one. Between 09-12 01:09 and today this block RECORDED `ndt down`'s rc and
    # judged the machine by the sweep and the orphan verdict alone, because that rc had three
    # sources and one of them -- a component that died of a fatal signal, reported once out of a
    # .exit record -- can be LAST round's ending, which would have stopped the grid and blamed
    # the cell that inherited it. `ndt down` and `ndt clean` now answer with one vocabulary:
    #
    #     0  measured, and clean          -> restored
    #     3  measured NOTHING             -> restored. An already-down lab and an assertion with
    #                                       no subject are the ordinary state between cells
    #     1  measured, and DIRTY          -> RESTORE-FAIL. A port still held, something that
    #                                       would not stop, or a component that ended on a fatal
    #                                       signal -- and that last one still stops the grid,
    #                                       which is the point: the next cell must not inherit it
    #     5  a guard REFUSED              -> RESTORE-FAIL, and the block says WHO blocked it.
    #                                       Nothing was torn down at all, so the lab is whatever
    #                                       the cell left it as
    #
    # The orphan verdict and `ndt clean` are still both read: three readings, all three hard.
    local blocked=0 why=""
    case "$drc" in
        0|3) ;;
        5)   why="'ndt down' was REFUSED (rc 5) -- nothing was torn down"; blocked=1 ;;
        *)   why="'ndt down' exited $drc -- it measured something dirty" ;;
    esac
    case "$crc" in
        0|3) ;;
        5)   why="${why:+$why; }'ndt clean' was REFUSED (rc 5)"; blocked=1 ;;
        *)   why="${why:+$why; }'ndt clean' exited $crc -- the machine is not clean" ;;
    esac
    grep -q '^VERDICT: CLEAN' "$rdir/6-verdict-postclean.txt" \
        || why="${why:+$why; }the orphan verdict is not CLEAN"
    if [[ -n "$why" ]]; then
        echo "RESTORE-FAIL after $lab: $why" >&2
        echo "    down rc=$drc  clean rc=$crc" >&2
        if (( blocked )); then
            # 🔴 WHO blocked it. A refusal names the pid and what it is protecting, and that is
            # the one thing a stopped grid needs in its own log -- the raw directory survives,
            # but the reason a night round stopped should not require opening it.
            echo "    who blocked it:" >&2
            grep -hE "refusing to |pid [0-9]+, started |is claimed by |measuring=" \
                "$rdir/3-down.log" "$rdir/4-clean.log" 2>/dev/null | sed 's/^/      /' >&2
        fi
        grep '^VERDICT:' "$rdir/6-verdict-postclean.txt" | sed 's/^/    /' >&2
        echo "    raw: $rdir" >&2
        return 1
    fi
    local note=""
    [[ "$drc" == 3 || "$crc" == 3 ]] && note="  (3 = measured nothing: the lab was already down)"
    printf 'RESTORE ok  after %-40s down=%s clean=%s %s%s\n' "$lab" "$drc" "$crc" \
        "$(grep -m1 '^VERDICT:' "$rdir/6-verdict-postclean.txt")" "$note"
    return 0
}

# [Co-developed with claude code -- Adam]
# A SOURCE SEAM, the same one tools/test_workflow/ndt has and for the same reason: sourced with
# RUN_CELLS_LIB_ONLY=1 this file defines restore() and stops, so tests/shell/mutate_live_cells.sh
# can drive the restore DECISION against a recording fake `ndt` instead of against a lab. Without
# it the only way to exercise this function is a night round, and the rules above -- which rc
# means restored -- would be the one part of the grid nothing tests. `return` outside a function
# is legal only in a sourced file, which is exactly when this line is reached with the variable
# set; executed normally it is never reached with it set.
[[ -n "${RUN_CELLS_LIB_ONLY:-}" ]] && return 0

# --- the round -----------------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0; TOTAL=0
declare -a LINES=()
printf 'run_cells.sh  NDT_ROOT=%s  ndt=%s  raw=%s\n' \
    "$NDT_ROOT" "$(git -C "$NDT_ROOT" hash-object "$NDT" 2>/dev/null || echo unknown)" "$OUT"
printf 'started %s   cells=%s   restore=%s\n\n' "$(date -Iseconds)" "${#CELLS[@]}" \
    "$( ((RESTORE)) && echo between-cells || echo DISABLED )"

for c in "${CELLS[@]}"; do
    IFS='|' read -r name tag req <<<"$c"
    TOTAL=$((TOTAL+1))
    d="$OUT/$name"; rm -rf "$d"; mkdir -p "$d"
    printf '=== %s  (tag=%s requires=%s)\n' "$name" "$tag" "$req"
    NDT_ROOT="$NDT_ROOT" bash "$HERE/$name.sh" observe "$d" > "$d/observe.stdout" 2>&1
    orc=$?
    printf '%s\n' "$orc" > "$d/observe.rc"
    (( orc != 0 )) && sed 's/^/    observe| /' "$d/observe.stdout"
    out="$(NDT_ROOT="$NDT_ROOT" bash "$HERE/$name.sh" judge "$d" 2>&1)"; jrc=$?
    printf '%s\n' "$out" | sed 's/^/  /'
    printf '%s\n' "$out" > "$d/judge.txt"
    line="$(grep -m1 '^CELL: ' <<<"$out")"
    LINES+=("${line:-CELL: FAIL $name tag=$tag kernel=unknown ndt=unknown at=unknown (no verdict line)}")
    case "$jrc" in
        0) PASS=$((PASS+1)) ;;
        3) SKIP=$((SKIP+1)) ;;
        *) FAIL=$((FAIL+1)) ;;
    esac
    if (( RESTORE )) && [[ "$req" != none ]]; then
        restore "$name" || { echo "run_cells.sh: stopping -- the lab is not restored" >&2; exit 2; }
    fi
    echo
done

echo "--- verdicts ---"
printf '%s\n' "${LINES[@]}"
printf 'CELLS: %s/%s pass, %s FAIL, %s SKIP%s\n' \
    "$PASS" "$TOTAL" "$FAIL" "$SKIP" "$( ((RESTORE)) || echo '  (restore DISABLED -- not a round)' )"
(( FAIL == 0 ))
