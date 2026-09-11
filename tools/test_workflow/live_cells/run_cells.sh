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
    # 🔴 A1-b, 2026-09-12. `ndt down` now carries stack.sh's teardown exit status, and one of the
    # three things that makes that non-zero is a component that ended on a FATAL signal --
    # reported out of a `.exit` record on disk and delivered ONCE. So a cell that SIGKILLs a
    # kernel (or a laptop where systemd-oomd did) makes the restore after the NEXT cell red, and
    # the grid would stop and blame the cell that inherited it. The down rc is RECORDED and
    # printed either way; what decides "is the lab restored" is the sweep and the orphan verdict,
    # the two readings that describe the machine as it is NOW rather than how something ended.
    # The port-still-held and could-not-stop-it halves of that rc are not lost by this: `ndt
    # clean` walks the whole port table and is read below.
    local downnote=""
    (( drc != 0 )) && downnote="  🔴 ndt down rc=$drc (recorded; see $rdir/3-down.log)"
    if (( crc != 0 )) || ! grep -q '^VERDICT: CLEAN' "$rdir/6-verdict-postclean.txt"; then
        echo "RESTORE-FAIL after $lab: down rc=$drc clean rc=$crc verdict:" >&2
        grep '^VERDICT:' "$rdir/6-verdict-postclean.txt" | sed 's/^/    /' >&2
        echo "    raw: $rdir" >&2
        return 1
    fi
    printf 'RESTORE ok  after %-40s down=%s clean=%s %s%s\n' "$lab" "$drc" "$crc" \
        "$(grep -m1 '^VERDICT:' "$rdir/6-verdict-postclean.txt")" "$downnote"
    return 0
}

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
