#!/usr/bin/env bash
#
# CELL help_drops_deleted_claims -- F12 and B10. `ndt help` stops saying two things the code
# had already stopped being able to support.
#
# [Co-developed with claude code -- Adam]
#
# Source: F-OFFLINE-1 §1.12 and §1.24, run for real 2026-09-11 00:5x.
#   F12  help said `no 'ndt up' has run in THIS checkout. 3 is never "checked and matched"`,
#        while check_up_target's own comment three thousand lines away says that sentence is a
#        statement about HISTORY and is false after every ordinary up->down. One file, two
#        opposite claims.
#   B10  help carried a blanket guarantee that the 4-host-model-against-a-128-host-fabric
#        mistake `cannot be made by forgetting an environment variable`. Scope, not falsity:
#        09-05 made that pair by SETTING NDT_TOPO, which help itself teaches.
# Fix: 3259d296 (both), merged in 954ab467.
#
# 🔴 Two directions. Deleting the sentence is not the property -- a help text that says nothing
# about either subject would pass a "the old words are gone" check and leave the reader with no
# statement at all. So the replacement is asserted as well: the tense F2 corrected, and the
# scoped form of B10 that still names 09-05's counter-example.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NDT_ROOT="${NDT_ROOT:-$REPO_ROOT}"
source "$HERE/_cell_lib.sh"

cell_observe() {
    local d="$1"
    cell_write_ids "$d"
    # `ndt help` reads no state and writes none. It is the one ndt verb that is safe to run
    # while somebody else holds the lab, which is why this cell needs no fabric.
    bash "$NDT_ROOT/tools/test_workflow/ndt" help > "$d/help.txt" 2>&1
    printf '%s\n' "$?" > "$d/help.rc"
}

cell_judge() {
    local d="$1"
    a_have  help_output_present                   "$d/help.txt"
    # 2, not 0, and pinned rather than ignored: there is no `help` case in ndt's dispatch --
    # `help` falls through to `*)`, which prints the usage and exits 2. Asserted so that a day
    # when this text stops being reachable is a red cell rather than an empty raw file.
    a_eq    help_rc_is_2                    "2"   "$(cat "$d/help.rc" 2>/dev/null)"
    # 🔴 F12, THE KEY ASSERTION. The sentence the code deleted and the help kept.
    a_hasnt help_drops_this_checkout_claim        'has run in THIS checkout. 3 is never'      "$d/help.txt"
    # ... and the tense that replaced it, so "say nothing" is not a way to pass.
    a_has   help_scopes_the_residue_rc            'rc 1 ONLY while there is a'                "$d/help.txt"
    # 🔴 B10. The blanket guarantee is gone. The needle is the HALF-LINE the old text wrapped
    # on -- pre-fix the sentence read `... mistake cannot be made by forgetting an` / `environment
    # variable.` across two lines, and grep -F is per line, so the whole sentence as a needle
    # matched nothing and this assertion passed on the very fixture it exists to fail.
    a_hasnt help_drops_blanket_env_guarantee      'mistake cannot be made by forgetting an' "$d/help.txt"
    # ... and replaced by the scoped claim, which keeps 09-05's counter-example in the text.
    a_has   help_keeps_the_scoped_knob_claim      'It does NOT make the 4-host-model-against-a-128-host-fabric' "$d/help.txt"
}

cell_main help_drops_deleted_claims ndt none "$@"
