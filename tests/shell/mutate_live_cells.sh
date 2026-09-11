#!/usr/bin/env bash
#
# Mutation gate for tools/test_workflow/live_cells/ -- the regression grid's judges.
#
# [Co-developed with claude code -- Adam]
#
# A live cell is `observe` (drives the lab, writes raw) plus `judge` (a pure function of that raw
# directory). The judge is the part that can be wrong quietly: it is what says PASS, it runs on
# every night round, and nothing else in this project reads it. So this gate asks the two
# questions the grid's value rests on.
#
# (a) DOES EACH JUDGE STILL TELL THE TWO APART?
#     `judge tests/fixtures/live_cells/<cell>/old/` must FAIL and `judge .../new/` must PASS.
#     🔴 And FAIL is not enough: the gate compares the SET OF FAILING ASSERT IDS against the
#     fixture's own `old/EXPECTED-FAILS`, which is a reviewed, committed file. A judge that goes
#     red for a different reason than it used to is not the judge that was delivered, and a plain
#     "rc is 1" check cannot see the difference.
#
# (b) IS EACH JUDGE'S KEY ASSERTION LOAD-BEARING?
#     Two mutation shapes per assertion, applied to COPIES of the cell scripts in a temp dir:
#       delete  the assertion line becomes `:`            -- the id vanishes from the output
#       widen   the assertion line becomes `_a_ok <id>`   -- the id stays and never fails again
#     Either changes the failing set, so (a) must break. 🔴 The WIDENING one is the reason the
#     set comparison exists: a widened assertion keeps the cell red overall, keeps its id in the
#     report, and has no discriminating power at all -- which is exactly the shape of instrument
#     this project keeps re-discovering (02-recurring-mistakes: 揭露≠下修, 零鑑別力).
#     Only assertions each fixture's PROVENANCE.md names as CARRYING THE FINDING are mutated. An
#     assertion that fails on a fixture merely because the role kept no such file is a fixture
#     gap, and mutating it would be this gate grading a gap.
#
# (c) DOES THE PRE-FIX TOOL REALLY FAIL THE CELL?
#     For an `ndt`-tag cell that needs no lab, `observe` is re-run with NDT_ROOT pointed at a
#     temp tree carrying `git show <fix>^:tools/test_workflow/ndt`, and the judge must FAIL on
#     what comes out. That is the cell's red obtained from the tool rather than from a stored
#     file. Cells whose `observe` drives the lab are listed as NOT ATTEMPTED with the reason,
#     because the pre-fix `ndt` would build or hang a real fabric.
#
# 🔴 GUARDS ITS OWN SUBJECT. Mutations are applied to copies under a temp dir and the copies are
# executed there; nothing in tools/test_workflow/live_cells/ is written, and the sha256 lines at
# the bottom say so. No build, no lab, no network, no sudo -- this gate reads fixtures only.
#
# Run:  bash tests/shell/mutate_live_cells.sh
# Exit: 0 every mutation caught and every fixture check passed
#       1 a mutation survived, or a fixture check failed
#       2 refused (a baseline check is red before any mutation, or the harness cannot run)
#       3 a cell script changed while the gate ran
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CELLDIR="$REPO/tools/test_workflow/live_cells"
FIXROOT="$REPO/tests/fixtures/live_cells"
BK="$(mktemp -d "${TMPDIR:-/tmp}/live-cells-mutate-$$-XXXXXX")"
trap 'rm -rf "$BK"' EXIT

[[ -d "$CELLDIR" ]] || { echo "no live_cells directory at $CELLDIR"; exit 2; }
BASE_SHA="$(cat "$CELLDIR"/*.sh | sha256sum | cut -d' ' -f1)"

MUTATIONS=0; SURVIVORS=0; CHECKS=0; CHECKFAIL=0; PENDING=0

# 🔴 One variable per cell file, and each is passed to `mutant` WHOLE.
# tests/shell/check_gate_anchors.py resolves a scalar assignment and a bare "$VAR", but a
# mixed word like "$CELLDIR/x.sh" is not a path it can follow -- it falls back to the
# function's default file, which is the DIRECTORY, and every anchor is then counted in a path
# instead of in a file. First draft did that and the checker said MISSING:20 over 20 anchors
# that all resolve. Measured 2026-09-11 13:4x.
CELL_OBPNC="$CELLDIR/orphans_blind_probes_not_checked.sh"
CELL_HDDC="$CELLDIR/help_drops_deleted_claims.sh"
CELL_DRPIC="$CELLDIR/default_round_plane_is_classified.sh"
CELL_UTNARM="$CELLDIR/up_target_names_a_readable_model.sh"
CELL_URAMOAN="$CELLDIR/up_refuses_a_model_of_another_network.sh"
CELL_URWADIIF="$CELLDIR/up_refuses_while_a_down_is_in_flight.sh"
CELL_HSINC="$CELLDIR/half_stack_is_not_clean.sh"
CELL_RRFN="$CELLDIR/recovery_refuses_foreign_netem.sh"
CELL_LFCBEON="$CELLDIR/link_failure_cuts_both_ends_or_neither.sh"


# --- (a) the fixture check, which is also the oracle every mutation is measured against --------
# fails_of <celldir> <cell> <rawdir> -> the failing assert ids, one per line, sorted
fails_of() {
    NDT_ROOT="$REPO" bash "$1/$2.sh" judge "$3" 2>&1 \
        | sed -n 's/^ASSERT FAIL \([A-Za-z0-9_]*\).*/\1/p' | LC_ALL=C sort
}

# check_cell <celldir> <cell> -> 0 the cell's fixtures still discriminate, 1 they do not.
# Prints nothing unless $VERBOSE_CHECK is set, so a mutation round stays one line per mutant.
check_cell() {
    # 🔴 `fix` is assigned on ITS OWN LINE, and it has to be. `local cd_="$1" cell="$2"
    # fix="$FIXROOT/$cell"` looks right and is not: every word of a builtin's command line is
    # expanded BEFORE the builtin runs, so `$cell` there is whatever the CALLER's scope had --
    # which, after the baseline loop below, is the last cell alphabetically. The first draft of
    # this gate did exactly that, scored all 18 mutations against ONE cell's fixture, and
    # reported `18 caught, 0 survived`. The two controls caught it. Measured 2026-09-11 13:2x.
    local cd_="$1" cell="$2" want got rc
    local fix="$FIXROOT/$cell"
    [[ -d "$fix/old" ]] || { [[ -n "${VERBOSE_CHECK:-}" ]] && echo "    no old/ fixture"; return 1; }
    [[ -r "$fix/old/EXPECTED-FAILS" ]] || { [[ -n "${VERBOSE_CHECK:-}" ]] && echo "    no EXPECTED-FAILS"; return 1; }
    NDT_ROOT="$REPO" bash "$cd_/$cell.sh" judge "$fix/old" >/dev/null 2>&1; rc=$?
    if [[ "$rc" -ne 1 ]]; then
        [[ -n "${VERBOSE_CHECK:-}" ]] && echo "    judge old/ returned $rc, want 1 (FAIL)"
        return 1
    fi
    want="$(LC_ALL=C sort "$fix/old/EXPECTED-FAILS")"
    got="$(fails_of "$cd_" "$cell" "$fix/old")"
    if [[ "$want" != "$got" ]]; then
        if [[ -n "${VERBOSE_CHECK:-}" ]]; then
            echo "    the failing set is not the reviewed one:"
            diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/      /'
        fi
        return 1
    fi
    if [[ -d "$fix/new" ]]; then
        NDT_ROOT="$REPO" bash "$cd_/$cell.sh" judge "$fix/new" >/dev/null 2>&1 || {
            [[ -n "${VERBOSE_CHECK:-}" ]] && echo "    judge new/ is RED"
            return 1; }
    fi
    return 0
}

# --- the mutant builder ------------------------------------------------------------------------
# A mutant is a whole COPY of the live_cells directory: a cell sources _cell_lib.sh from beside
# itself, so the library travels with it, unmutated.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate out of this function's own `local label="$1" file="$2" old="$3" new="$4"` line.
# A gate that tool cannot read is a gate it is not checking (finding #28).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"
    rm -rf "$d"; mkdir -p "$d"
    cp "$CELLDIR"/*.sh "$d/"
    chmod +x "$d"/*.sh
    # 🔴 AN ANCHOR THAT WILL NOT APPLY IS A SURVIVOR, AND IT SAYS SO. The mutant directory is
    # returned either way -- an unmutated copy discriminates, so `report` scores it SURVIVED,
    # which is the honest verdict (tests/shell/README.md §1: `SURVIVED (anchor could not be
    # applied)` is what a hole in the tests looks like). What was missing until 2026-09-11 13:4x
    # was the REASON: narrowing two needles in the cells left these two anchors stale, the gate
    # said `2 survived` with no explanation, and "the assertion is not load-bearing" is a very
    # different diagnosis from "the gate can no longer find the line".
    if ! python3 - "$d/$(basename "$file")" "$old" "$new" > "$d/.apply.err" 2>&1 <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        printf 'ANCHOR-NOT-APPLIED %s\n' "$label" > "$d/.unapplied"
    fi
    echo "$d"
}

report() {   # $1 = label, $2 = mutant dir, $3 = the cell whose fixture check must break
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if check_cell "$2" "$3"; then
        SURVIVORS=$((SURVIVORS+1))
        if [[ -f "$2/.unapplied" ]]; then
            printf '  SURVIVED %-62s (anchor could not be applied -- the gate cannot find that line any more)\n' "$1"
            sed 's/^/           /' "$2/.apply.err"
        else
            printf '  SURVIVED %-62s (%s still discriminates -- that assertion is not load-bearing)\n' "$1" "$3"
            VERBOSE_CHECK=1 check_cell "$2" "$3" | sed 's/^/           /'
        fi
    else
        printf '  caught   %-62s (%s stopped telling old/ from new/)\n' "$1" "$3"
    fi
}

# 🔴 The control, and it is the other half of the gate. `N/N caught` from a harness that reports
# red for ANY edit says nothing at all (tests/shell/README.md, "Before you call a new gate
# wired", item 3). A control mutation is behaviour-preserving and must SURVIVE; one that is
# caught means the oracle above is answering about the edit rather than about the property.
CONTROLS=0; CONTROL_BAD=0
control() {   # $1 = label, $2 = mutant dir, $3 = the cell whose fixture check must NOT break
    CONTROLS=$((CONTROLS+1))
    if check_cell "$2" "$3"; then
        printf '  control  %-62s (%s still discriminates -- as it must)\n' "$1" "$3"
    else
        CONTROL_BAD=$((CONTROL_BAD+1))
        printf '  🔴 CONTROL CAUGHT %-53s (%s broke on a behaviour-preserving edit)\n' "$1" "$3"
        VERBOSE_CHECK=1 check_cell "$2" "$3" | sed 's/^/           /'
    fi
}

# =================================================================================================
echo "(a) baseline: every cell's fixtures must discriminate BEFORE any mutation"
# =================================================================================================
declare -a ALLCELLS=()
for f in "$CELLDIR"/*.sh; do
    b="$(basename "$f" .sh)"
    [[ "$b" == run_cells || "$b" == _cell_lib ]] && continue
    ALLCELLS+=("$b")
done
(( ${#ALLCELLS[@]} )) || { echo "  no cells found"; exit 2; }

for cell in "${ALLCELLS[@]}"; do
    CHECKS=$((CHECKS+1))
    if VERBOSE_CHECK=1 check_cell "$CELLDIR" "$cell" > "$BK/chk.$cell" 2>&1; then
        if [[ -d "$FIXROOT/$cell/new" ]]; then
            printf '  ok       %-52s old/ FAIL == EXPECTED-FAILS, new/ PASS\n' "$cell"
        else
            PENDING=$((PENDING+1))
            printf '  PENDING  %-52s old/ FAIL == EXPECTED-FAILS; no new/ yet (the first fixed run has not been captured)\n' "$cell"
        fi
    else
        CHECKFAIL=$((CHECKFAIL+1))
        printf '  FAILED   %-52s\n' "$cell"
        sed 's/^/           /' "$BK/chk.$cell"
    fi
done
echo
if (( CHECKFAIL > 0 )); then
    echo "  🔴 $CHECKFAIL cell(s) cannot tell their own fixtures apart. Mutations prove nothing"
    echo "     against a red baseline -- fix that first."
    exit 2
fi

# =================================================================================================
echo "(b) mutations: is the key assertion the thing that catches the old evidence?"
# =================================================================================================
# One DELETE and one WIDEN per cell, on an assertion its fixture's PROVENANCE.md names as
# carrying the finding. The widening form is the one that stays red and stops discriminating.

# --- orphans_blind_probes_not_checked ---
m=$(mutant m1 "$CELL_OBPNC" \
    '    a_eq    f5_verdict_rc_is_3           "3"  "$(cat "$d/verdict.rc" 2>/dev/null)"' \
    '    :')
report "M1  (delete) F5: the rc 3 that replaced 0 is not read" "$m" orphans_blind_probes_not_checked
m=$(mutant m2 "$CELL_OBPNC" \
    '    a_hasnt f5_does_not_say_clean             "VERDICT: CLEAN"             "$d/verdict.txt"' \
    '    _a_ok   f5_does_not_say_clean "(widening: the token every restore gate greps is not checked)"')
report "M2  (widen)  F5: the CLEAN token is reported but never tested" "$m" orphans_blind_probes_not_checked

# --- help_drops_deleted_claims ---
m=$(mutant m3 "$CELL_HDDC" \
    "    a_hasnt help_drops_this_checkout_claim        'has run in THIS checkout. 3 is never'      \"\$d/help.txt\"" \
    '    :')
report "M4  (delete) F12: the deleted sentence is not looked for" "$m" help_drops_deleted_claims
m=$(mutant m4 "$CELL_HDDC" \
    "    a_has   help_keeps_the_scoped_knob_claim      'It does NOT make the 4-host-model-against-a-128-host-fabric' \"\$d/help.txt\"" \
    '    _a_ok   help_keeps_the_scoped_knob_claim "(widening: deleting the sentence would pass)"')
report "M5  (widen)  B10: 'say nothing' becomes a passing answer" "$m" help_drops_deleted_claims

# --- default_round_plane_is_classified ---
m=$(mutant m5 "$CELL_DRPIC" \
    "    a_has  f10_mininet_model_reads_as_ovs   'mininet128: out=ovs rc=0'   \"\$d/planes.txt\"" \
    '    :')
report "M6  (delete) F10: the default round's own model is not read" "$m" default_round_plane_is_classified
m=$(mutant m6 "$CELL_DRPIC" \
    "    a_has  f10_mininet_model_reads_as_ovs   'mininet128: out=ovs rc=0'   \"\$d/planes.txt\"" \
    '    _a_ok  f10_mininet_model_reads_as_ovs "(widening: the id is still reported and never fails)"')
report "M7  (widen)  F10: the reading is reported but never tested" "$m" default_round_plane_is_classified
# 🔴 NOT MUTATED HERE, and said out loud: f10_ovs_model_still_reads_as_ovs, f10_p4_is_not_swallowed
# and f10_physical_is_still_unknown are that cell's three CONTROLS -- they pass on old/ by design,
# so removing one changes no failing set and no fixture in this directory would redden it. The
# wrong fix they exist to catch (classify every model as ovs) is a mutation of `ndt`, not of the
# judge, and it is covered by test_ndt_honesty.sh 1G, which carries both directions. The same is
# true of every "control" assertion named in a fixture's PROVENANCE.md; CELLS.md §what these cells
# do NOT cover lists them in one place.

# --- up_target_names_a_readable_model ---
m=$(mutant m7 "$CELL_UTNARM" \
    '    a_hasnt h4nl_model_counts_were_readable            "cannot read expected counts from"  "$d/up.log"' \
    '    :')
report "M8  (delete) H4-regression: ndt's own 'cannot read' sentence" "$m" up_target_names_a_readable_model
m=$(mutant m8 "$CELL_UTNARM" \
    '    a_eq    h4nl_up_rc_is_0                     "0"    "$(cat "$d/up.rc" 2>/dev/null)"' \
    '    _a_ok   h4nl_up_rc_is_0 "(widening: any rc is accepted)"')
report "M9  (widen)  H4-regression: a bring-up that cannot finish passes" "$m" up_target_names_a_readable_model

# --- up_refuses_a_model_of_another_network ---
m=$(mutant m9 "$CELL_URAMOAN" \
    "    a_has   h4_refusal_names_both_counts          '128 declared by'             \"\$d/up.log\"" \
    '    :')
report "M10 (delete) H4: the two host counts stop being compared" "$m" up_refuses_a_model_of_another_network
m=$(mutant m9b "$CELL_URAMOAN" \
    "    a_has   h4_refusal_names_two_networks \\
            'refusing to build: NDT_TOPO names a model of a different network'  \"\$d/up.log\"" \
    '    _a_ok   h4_refusal_names_two_networks "(widening: any refusal counts, whatever it says)"')
report "M10b (widen) H4: any refusal counts, whatever refused it" "$m" up_refuses_a_model_of_another_network
m=$(mutant m10 "$CELL_URAMOAN" \
    '    a_hasnt h4_nothing_was_built                  '"'"'[1/3] bmv2 fabric'"'"'           "$d/up.log"' \
    '    _a_ok   h4_nothing_was_built "(widening: a refusal that built ten switches first passes)"')
report "M11 (widen)  H4: building the fabric first becomes acceptable" "$m" up_refuses_a_model_of_another_network

# --- up_refuses_while_a_down_is_in_flight ---
m=$(mutant m11 "$CELL_URWADIIF" \
    '    a_hasnt h3_did_not_reuse_the_fabric             '"'"'ok  already up:'"'"'               "$d/up.log"' \
    '    :')
report "M12 (delete) H3: 'reusing' the fabric being destroyed" "$m" up_refuses_while_a_down_is_in_flight
m=$(mutant m12 "$CELL_URWADIIF" \
    "    a_has   h3_refusal_quotes_the_marker            '.test_run/down.inflight'       \"\$d/up.log\"" \
    '    _a_ok   h3_refusal_quotes_the_marker "(widening: the marker need not be named)"')
report "M13 (widen)  H3: the marker stops having to be named" "$m" up_refuses_while_a_down_is_in_flight

# --- half_stack_is_not_clean ---
m=$(mutant m13 "$CELL_HSINC" \
    "    a_hasnt h2_half_stack_is_not_clean    'VERDICT: CLEAN'            \"\$d/half.verdict.txt\"" \
    '    :')
report "M14 (delete) H2: the CLEAN token on a half stack" "$m" half_stack_is_not_clean
m=$(mutant m14 "$CELL_HSINC" \
    "    a_has   h2_half_stack_names_the_half  'the stack is HALF up'      \"\$d/half.verdict.txt\"" \
    '    _a_ok   h2_half_stack_names_the_half "(widening: a verdict that names no half passes)"')
report "M15 (widen)  H2: which half is up stops being said" "$m" half_stack_is_not_clean

# --- recovery_refuses_foreign_netem ---
m=$(mutant m15 "$CELL_RRFN" \
    '    a_has   a1r_foreign_netem_survived       '"'"'netem'"'"'                      "$d/tc_after.txt"' \
    '    :')
report "M16 (delete) A1: the WIRE reading, which the 200 could not satisfy" "$m" recovery_refuses_foreign_netem
m=$(mutant m16 "$CELL_RRFN" \
    '    a_eq    a1r_http_is_409           "409"  "$(cat "$d/recovery.code" 2>/dev/null)"' \
    '    _a_ok   a1r_http_is_409 "(widening: 200 is accepted again)"')
report "M17 (widen)  A1: 200 becomes an acceptable answer" "$m" recovery_refuses_foreign_netem

# --- link_failure_cuts_both_ends_or_neither ---
m=$(mutant m17 "$CELL_LFCBEON" \
    "    a_hasnt a1f_far_end_was_not_cut           'netem'   \"\$d/tc_after_far.txt\"" \
    '    :')
report "M18 (delete) A1: the far end's qdisc is not read" "$m" link_failure_cuts_both_ends_or_neither
m=$(mutant m18 "$CELL_LFCBEON" \
    "    a_hasnt a1f_does_not_claim_injected       '\"status\":\"link failure injected\"'       \"\$d/failure.body\"" \
    '    _a_ok   a1f_does_not_claim_injected "(widening: the status line may claim a cut that did not happen)"')
report "M19 (widen)  A1: 'link failure injected' over nothing attached" "$m" link_failure_cuts_both_ends_or_neither

echo
# --- controls: behaviour-preserving edits that must NOT be caught ------------------------------
m=$(mutant c1 "$CELL_OBPNC" \
    '    # 🔴 THE KEY ASSERTION. rc 3 is the whole finding: 0 was the answer that made three failed' \
    '    # A COMMENT THIS CONTROL REWROTE. Nothing about the judge changed, so nothing may.')
control "C1 a comment is rewritten" "$m" orphans_blind_probes_not_checked
# C2 reorders two assertions. fails_of sorts the ids, so a judge that reports the same set in a
# different order is the same judge -- and a gate that called this a catch would be scoring the
# diff, not the property.
m=$(mutant c2 "$CELL_DRPIC" \
    "    a_has  f10_ovs_model_still_reads_as_ovs 'ovs4:       out=ovs rc=0'   \"\$d/planes.txt\"
    # ... and the direction a blanket answer would swallow.
    a_has  f10_p4_is_not_swallowed          'p44:        out=p4 rc=0'    \"\$d/planes.txt\"" \
    "    a_has  f10_p4_is_not_swallowed          'p44:        out=p4 rc=0'    \"\$d/planes.txt\"
    a_has  f10_ovs_model_still_reads_as_ovs 'ovs4:       out=ovs rc=0'   \"\$d/planes.txt\"")
control "C2 two assertions swap places" "$m" default_round_plane_is_classified

echo
# =================================================================================================
echo "(c) the pre-fix tool: does it really fail the cell it is the red of?"
# =================================================================================================
# Only the cells whose `observe` touches no lab. A pre-fix `ndt` driving a real bring-up would
# build or hang a fabric, so those are named below as NOT ATTEMPTED rather than skipped quietly.
pre_tree() {   # <rev> -> a temp NDT_ROOT carrying that rev's ndt and the files it sources
    # `d` on its own line, for the reason check_cell's header gives at length. Here it happened
    # to be harmless -- the caller's own `rev` holds the same value it passes -- and a latent
    # version of a bug this gate has already been bitten by is not worth keeping.
    local rev="$1" sib
    local d="$BK/tree-${rev//[^A-Za-z0-9]/_}"
    mkdir -p "$d/tools/test_workflow"
    git -C "$REPO" show "$rev:tools/test_workflow/ndt" > "$d/tools/test_workflow/ndt" 2>/dev/null || return 1
    chmod +x "$d/tools/test_workflow/ndt"
    for sib in ports.sh sudo_surface.sh components.env orphans_verdict.sh; do
        git -C "$REPO" show "$rev:tools/test_workflow/$sib" > "$d/tools/test_workflow/$sib" 2>/dev/null \
            || cp "$REPO/tools/test_workflow/$sib" "$d/tools/test_workflow/$sib"
    done
    echo "$d"
}

c_case() {   # <cell> <pre-fix rev>
    local cell="$1" rev="$2" tree raw rc
    CHECKS=$((CHECKS+1))
    if ! tree="$(pre_tree "$rev")"; then
        CHECKFAIL=$((CHECKFAIL+1)); printf '  FAILED   %-52s cannot read %s from git\n' "$cell" "$rev"; return
    fi
    raw="$BK/c-$cell"; rm -rf "$raw"; mkdir -p "$raw"
    NDT_ROOT="$tree" bash "$CELLDIR/$cell.sh" observe "$raw" >/dev/null 2>&1
    NDT_ROOT="$REPO" bash "$CELLDIR/$cell.sh" judge "$raw" >/dev/null 2>&1; rc=$?
    if [[ "$rc" -eq 1 ]]; then
        printf '  ok       %-52s the %s tool fails this judge\n' "$cell" "${rev%\^}^"
    else
        CHECKFAIL=$((CHECKFAIL+1))
        printf '  FAILED   %-52s judge returned %s against the pre-fix tool -- want 1\n' "$cell" "$rc"
        NDT_ROOT="$REPO" bash "$CELLDIR/$cell.sh" judge "$raw" 2>&1 | sed 's/^/           /'
    fi
}

c_case orphans_blind_probes_not_checked  ded00d06^
c_case help_drops_deleted_claims         3259d296^
c_case default_round_plane_is_classified ca9af4f1^
cat <<'NOTE'
  NOT ATTEMPTED, and each with its reason -- these cells' `observe` drives the lab:
    up_target_names_a_readable_model       the pre-fix ndt's `ndt up` takes ~318 s and ends in
                                           `rollback INCOMPLETE` (ROLE-6). Paying that price
                                           nightly is worse than reading the captured log.
    up_refuses_a_model_of_another_network  the pre-fix ndt BUILDS the 4-host fabric and then
                                           hangs in [2/3] until a 300 s timeout (ROLE-2 c07).
    up_refuses_while_a_down_is_in_flight   needs a live teardown to overlap; the pre-fix ndt
                                           reuses the fabric being destroyed, which is the
                                           defect, on a shared lab.
    half_stack_is_not_clean                needs a live half stack.
    recovery_refuses_foreign_netem         the pre-fix KERNEL is the subject, not `ndt`; it
                                           would have to be rebuilt from 0b928fe6^ and pointed
                                           at a live fabric. Not a shell question.
    link_failure_cuts_both_ends_or_neither same, and its pre-fix form really cuts a link end.
NOTE

echo
echo "--- the subject was not written ---"
printf 'live_cells/*.sh sha256 (all files, concatenated): %s\n' "$BASE_SHA"
NOW_SHA="$(cat "$CELLDIR"/*.sh | sha256sum | cut -d' ' -f1)"
printf 'the same, after the round:                        %s\n' "$NOW_SHA"
if [[ "$BASE_SHA" != "$NOW_SHA" ]]; then
    echo "🔴 a cell script CHANGED while this gate ran -- every verdict above is void"
    exit 3
fi

echo
printf '%s mutations, %s survived;  %s controls, %s wrongly caught;  %s fixture checks, %s failed, %s pending (a cell with no new/ fixture)\n' \
    "$MUTATIONS" "$SURVIVORS" "$CONTROLS" "$CONTROL_BAD" "$CHECKS" "$CHECKFAIL" "$PENDING"
# (the trailing label is a definition of `pending`, not a claim: it reads `0 pending` once every
#  cell has a new/ fixture, and saying "no new/ yet" there would be false)
(( SURVIVORS == 0 && CHECKFAIL == 0 && CONTROL_BAD == 0 ))
