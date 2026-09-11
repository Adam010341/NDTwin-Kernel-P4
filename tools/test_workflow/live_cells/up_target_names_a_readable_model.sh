#!/usr/bin/env bash
#
# CELL up_target_names_a_readable_model -- the H4 REGRESSION. `ndt up` handed the kernel a
# --topology path with a newline inside it, on both planes, and no plane could start a kernel.
#
# [Co-developed with claude code -- Adam]
#
# Source: ROLE-6 2026-09-11 02:48-03:00, live on both planes, plus its own offline replay.
# H4's fix (76b5d434) replaced `topo="$(topo_for_hosts ...)"` with a tab-packed reading that
# carries path, rc and refusal out of one subshell. A command substitution strips only TRAILING
# newlines, and here the tab and the rc follow the path -- so `topo` came out as "<path>\n":
# every `[[ -f "$topo" ]]` false, `topology_sha256=unavailable` and an empty `model_hosts=`
# written into up.target, and the kernel started with a --topology it could not open.
#   `ndt up p4 4`   rc 1 after 318 s, `rollback INCOMPLETE`      (logs/ROLE-6/51a-up-p4-A.log)
#   `ndt up ovs 4`  stuck past 120 s, killed by ROLE-6's own tool timeout, no rc
#   kernel.log      `Cannot open topology file` / `No port has been opened`
# Fix: ce2ae2f9, cherry-picked to trunk as 5e7a91c8.
#
# 🔴 Judged through the RECORD, not by re-splitting the string. up.target is where the resolved
# path lands, it is written by the one function every plane passes through, and its
# topology_sha256 is a reading OF THE FILE -- 64 hex when the path names a file, the literal
# `unavailable` when it does not. A cell that repeated ndt's own unpacking expression would only
# prove the expression agrees with itself. (Same reasoning as section 11 of
# tests/shell/test_ndt_up_down_robust.sh, which is this finding's offline half.)
#
# This cell brings the fabric up and LEAVES IT UP: run_cells.sh takes it down between cells, so
# a teardown here would hide a failure of that teardown behind a success of this cell.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

cell_observe() {
    local d="$1" t0 t1
    cell_write_ids "$d"
    t0=$(date +%s)
    NDT_OWNER="${NDT_OWNER:-overnight-0905}" \
        timeout 420 bash "$NDT_ROOT/tools/test_workflow/ndt" up ovs 4 > "$d/up.log" 2>&1
    printf '%s\n' "$?" > "$d/up.rc"
    t1=$(date +%s); printf '%s\n' "$((t1-t0))" > "$d/up.secs"
    # The record, and the exit record beside it. Copied rather than referenced: the judge may
    # read nothing outside the raw directory.
    cp "$NDT_ROOT/.test_run/up.target" "$d/up.target" 2>/dev/null || true
    cp "$NDT_ROOT/.test_run/pids/kernel.exit" "$d/kernel.exit" 2>/dev/null || true
}

cell_judge() {
    local d="$1"
    a_have  h4nl_up_log_present                        "$d/up.log"
    # 🔴 THE KEY ASSERTION on the live half: with the newline in the path the bring-up could not
    # finish at all. rc 0 is the finding stated in one number.
    a_eq    h4nl_up_rc_is_0                     "0"    "$(cat "$d/up.rc" 2>/dev/null)"
    # ndt's own sentence when topo_model_counts could not read the file it was handed.
    a_hasnt h4nl_model_counts_were_readable            "cannot read expected counts from"  "$d/up.log"
    a_hasnt h4nl_no_incomplete_rollback                "rollback INCOMPLETE"               "$d/up.log"
    a_hasnt h4nl_kernel_did_not_die_starting           "kernel exited while starting"      "$d/up.log"
    # The record. Absent on the pre-fix evidence only because ROLE-6 did not keep it -- see this
    # cell's fixture PROVENANCE.md, which says which assertions carry the finding there.
    a_have  h4nl_target_record_written                 "$d/up.target"
    a_re    h4nl_topology_sha_is_a_reading  '^topology_sha256=[0-9a-f]{64}$'   "$d/up.target"
    a_re    h4nl_model_hosts_were_counted   '^model_hosts=[0-9]+$'             "$d/up.target"
    a_re    h4nl_topology_path_is_one_line  '^topology=[^[:space:]]+\.json$'   "$d/up.target"
}

cell_main up_target_names_a_readable_model ndt ovs4 "$@"
