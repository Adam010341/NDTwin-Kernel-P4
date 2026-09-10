#!/usr/bin/env bash
#
# orphans_verdict.sh -- read the REPORT `ndt apps orphans` prints, not its exit code.
#
# [Co-developed with claude code -- Adam]
#
# =================================================================================================
# WHY THIS EXISTS
# =================================================================================================
# `ndt apps orphans` has a documented, disjoint exit-code table (`ndt help`):
#
#     0  no untracked processes AND nothing on the network
#     1  untracked app PROCESSES are running
#     2  a liveness channel was blind
#     4  processes are clean, but the NETWORK carries residue (a rule, or a held lock)
#     5  processes are clean, and the residue COULD NOT BE CHECKED
#
# and it says of itself: "Every gate that reads this rc has to be updated". It has been right to
# say so. The same fabric, in the same state, has changed code twice inside one merge window --
# measured live on `integrate-0910`, 2026-09-10 (`scratch/.../fix/R4-LIVE-SUMMARY.md` §4-A7, §4-A9):
#
#   * clean OVS4 fabric:   rc 0  ->  rc 5.  The tally gained `1 question(s) not answerable`,
#     from an app whose log is non-empty but whose pidfile is gone -- "the window is LOST".
#     Nothing was on the network; nothing was running. The fabric was clean and the gate said no.
#   * P4 4 with a sim up:  rc 5  ->  rc 2.  `/proc/<pid>/fd` of a root process could not be read,
#     so a liveness channel was blind and 2 outranks 5.
#
# Both moves are the tool becoming MORE honest, and both break every caller that spells its gate
# `orphans && ok || fail`. Adam's ruling, 2026-09-10: **read the tally line, do not read the rc.**
# `ndt`'s own rc table and the tests that pin it (tests/shell/test_ndt_app_orphans.sh,
# tests/shell/test_apps_residue.sh) are the spec and are NOT changed. What changes is the reader.
#
# =================================================================================================
# THE THREE FIELDS, AND WHAT MAKES A FABRIC "CLEAN"
# =================================================================================================
#     processes=<clean|running|unknown>
#     network=<dated rule(s) in a window>/<lock(s) held>/<rule(s) that could not be dated>
#     not_answerable=<n>
#
# CLEAN  ==  processes=clean  AND  dated-in-window == 0  AND  locks == 0.
#
# 🔴 `not_answerable > 0` and `could not be dated > 0` are a **NOTE, not a FAIL**. That is the
# whole point of this file. They mean "nobody could ask" -- a kernel that was down, a window that
# was lost, a plane (every P4 fabric) with no time axis on its flow stats. They are not evidence
# of residue, and a gate that fails on them is a gate that can never pass on a P4 fabric or on any
# machine where an app once ran and its pidfile is gone. They are printed loudly instead, with the
# tool's own sentence quoted, so a report that says CLEAN cannot be read as "everything was asked".
#
# 🔴 `processes=unknown` IS a FAIL, and deliberately so: it is `ndt`'s rc 2, "a channel could not
# look", and Adam's E-7 ruling is that a check which could not look must not look like a check that
# looked and found nothing. The verdict line says which of the two it was, because the remedies
# differ.
#
# 🔴 A report with no tally line at all is UNUSABLE (rc 2), never CLEAN. Half a report read as a
# pass is the failure mode this file exists to remove, not one to reintroduce.
#
# =================================================================================================
# KERNEL-DOWN MODE -- the one case where a missing tally is not an unreadable report
# =================================================================================================
# `ndt down` closes :8000. residue_report's first act is to ask :8000 for the flow table, and when
# the port is closed it says so and returns BEFORE printing a tally (ndt:5415):
#
#     !!  the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked.
#     !!  this is not 'the lab is clean'. it is 'nobody asked'. (KNOWN-ISSUES G-12)
#
# So every report taken after `ndt down` -- which is where a round's restore check is taken -- had
# no tally, and this reader answered UNUSABLE on a machine that six other instruments had just
# called clean. Measured on the merge tree, 2026-09-10 23:59:
# `scratch/overnight-2026-09-05/logs/lv-p4128-94-orphans.log`, written up in R5-P4-128 §5 and
# raised as §7-2: "as an end-of-round restore gate this helper is structurally always UNUSABLE".
# Adam took option (b) of that item: give the reader a legal kernel-down exit.
#
# 🔴 What makes it legal is that `ndt` SAID SO. The rule is not "a missing tally is fine after a
# down"; it is "a missing tally is readable only when the report names the reason":
#
#     no tally + a kernel-down sentence from `ndt`  ->  network=n/a, verdict from the process half
#     no tally + nothing saying why                 ->  UNUSABLE, exactly as before
#
# The second line is the whole safety of the first. A report cut off mid-run, a report from an
# older `ndt` whose `orphans` had no network half at all (every `*-94-orphans.log` before 09-10 is
# one line long), a report whose residue half died -- none of those explain themselves, and none of
# them may pass. tests/shell/test_orphans_verdict.sh pins both lines, with the kernel-down fixture
# copied verbatim from that live log and the negative control taken verbatim from
# `logs/lv-a7-94-orphans.log`.
#
# 🔴 The missing half is named, never counted as zero: the fields print `network=n/a` and
# `not_answerable=n/a` rather than `0/0/0` and `0`, and `NOTE: network half not checkable: kernel
# down` is printed above the verdict with `ndt`'s own two sentences quoted under it. E-7 forbids a
# check that could not look from looking like a check that looked; what it does not forbid is
# reporting the half that DID look. The process half does not read :8000 -- it reads pidfiles,
# /proc and argv -- so after a down it is still a real answer, and it is the answer the verdict
# comes from. A running orphan after `ndt down` is NOT CLEAN, kernel or no kernel.
#
# 🔴 A tally, if one is present, always wins: the kernel-down branch is only reachable when there
# is no tally to read. A report carrying both (no `ndt` path produces one today) is read from its
# tally, so this can never become a way to skip numbers that were printed.
#
# The exit code `ndt` itself returned may be passed in as the second argument. It is ECHOED for the
# record and never consulted. Two runs of this helper over the same report text must agree whatever
# rc is handed to them -- tests/shell/test_orphans_verdict.sh pins exactly that.
#
# =================================================================================================
# USAGE
# =================================================================================================
#     ndt apps orphans > orphans.log 2>&1; rc=$?          # 2>&1 matters: err() writes to stderr
#     bash tools/test_workflow/orphans_verdict.sh orphans.log "$rc"
#
#     if bash tools/test_workflow/orphans_verdict.sh orphans.log "$rc"; then
#         echo "RESTORE-OK"
#     else
#         echo "RESTORE-FAIL"
#     fi
#
# Invoked with `bash`, not `./`: this file ships mode 644, the same as its neighbours `ports.sh`
# and `ndtwin-lab`, and a caller that relies on the execute bit breaks on a fresh clone.
#
# `-` reads the report from stdin. Exit codes of THIS script:
#     0  CLEAN     (possibly with NOTEs -- read them, they are in the output. After an `ndt down`
#                  this means "the process half is clean and the network half was not checkable")
#     1  NOT CLEAN (an untracked process, a blind process channel, a dated rule, or a held lock)
#     2  UNUSABLE  (no report, or a report this cannot parse and that does not say why -- never to
#                  be read as a pass)

set -uo pipefail

usage() {
    echo "usage: orphans_verdict.sh <report-file>|- [ndt-rc]" >&2
    echo "       the report is the FULL output of 'ndt apps orphans', stdout AND stderr" >&2
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }

SRC="$1"
NDT_RC="${2-}"

if [[ "$SRC" == "-" ]]; then
    REPORT="$(cat)"
elif [[ -r "$SRC" ]]; then
    REPORT="$(cat -- "$SRC")"
else
    echo "VERDICT: UNUSABLE -- cannot read the report at '$SRC'"
    exit 2
fi

# `ndt` colours its own output unless NO_COLOR is set, and a caller that captured a report with
# colours on still deserves an answer. Strip SGR sequences before matching anything.
REPORT="$(printf '%s\n' "$REPORT" | sed 's/\x1b\[[0-9;]*m//g')"

if [[ -z "${REPORT//[[:space:]]/}" ]]; then
    echo "VERDICT: UNUSABLE -- the report is empty"
    exit 2
fi

# --- the process half ---------------------------------------------------------------------------
# Order matters. The blind sentence CONTAINS the clean sentence's words ("no untracked app
# processes found, but a channel was blind"), so "clean" is only reached after both other shapes
# have been ruled out.
PROCESSES=""
if grep -qF -- ' app(s) are running with nothing tracking them' <<<"$REPORT" \
   || grep -qF -- 'pidfile-lost-but-alive' <<<"$REPORT"; then
    PROCESSES=running
elif grep -qF -- 'no untracked app processes found, but a channel was blind' <<<"$REPORT"; then
    PROCESSES=unknown
elif grep -qF -- 'no untracked app processes' <<<"$REPORT"; then
    PROCESSES=clean
fi

if [[ -z "$PROCESSES" ]]; then
    echo "VERDICT: UNUSABLE -- no process half in the report (did the caller capture stderr? 'ndt'"
    echo "         writes its findings with err(), which goes to fd 2)"
    exit 2
fi

# --- the network half: the tally line, which is the exit code's own source ------------------------
# ndt:5561 prints it precisely so a reader can check the verdict against what it just saw rather
# than against ndt's source. That is what this reads.
TALLY="$(sed -n 's/.*tally: \([0-9][0-9]*\) dated rule(s) in a window, \([0-9][0-9]*\) lock(s) held, \([0-9][0-9]*\) rule(s) that could not be dated, \([0-9][0-9]*\) question(s) not answerable.*/\1 \2 \3 \4/p' <<<"$REPORT" | tail -1)"

# --- kernel-down mode: a missing tally that the report itself explains ----------------------------
# Only consulted when there is no tally, so a printed number is never skipped in favour of a
# sentence. Both matches are `ndt` saying, in its own words, that :8000 was closed and therefore
# no rule and no lock was read: residue_report (ndt:5415) is the one that produces this report
# shape, status_residue_row (ndt:5368) is the same statement from `ndt status --check`.
KERNEL_DOWN=0
if [[ -z "$TALLY" ]] \
   && { grep -qF -- 'the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked' <<<"$REPORT" \
        || grep -qF -- "NOT CHECKED -- :8000 is closed, so no rule and no lock was read" <<<"$REPORT"; }; then
    KERNEL_DOWN=1
fi

if [[ -z "$TALLY" ]] && (( KERNEL_DOWN == 0 )); then
    echo "processes=$PROCESSES"
    echo "VERDICT: UNUSABLE -- no 'tally:' line in the report, and nothing in it says why. This is"
    echo "         NOT 'the network is clean': the residue report did not run, or did not finish."
    echo "         (A report that DOES name the reason -- ':8000 closed' after 'ndt down' -- is read"
    echo "         instead: network=n/a and the verdict comes from the process half.)"
    echo "         Do not pass on it."
    exit 2
fi

if (( KERNEL_DOWN )); then
    # Zeroed so the verdict arithmetic below has numbers to read. They are NOT printed as fields:
    # the network half was not measured, and a measurement of zero is a different claim.
    N_RULES=0; N_LOCKS=0; N_UNDATED=0; N_UNANSWERABLE=0
else
    read -r N_RULES N_LOCKS N_UNDATED N_UNANSWERABLE <<<"$TALLY"
fi

echo "processes=$PROCESSES"
if (( KERNEL_DOWN )); then
    echo "network=n/a"
    echo "not_answerable=n/a"
else
    echo "network=$N_RULES/$N_LOCKS/$N_UNDATED"
    echo "not_answerable=$N_UNANSWERABLE"
fi
[[ -n "$NDT_RC" ]] && echo "ndt_rc=$NDT_RC (recorded, NOT used for the verdict)"

if (( KERNEL_DOWN )); then
    echo "NOTE: network half not checkable: kernel down"
    echo "      :8000 was closed when this report was taken (an 'ndt down' has run), so NO rule and"
    echo "      NO lock was read. The verdict below comes from the process half ALONE -- it reads"
    echo "      pidfiles, /proc and argv, not the kernel, so it is still an answer. Ask 'orphans'"
    echo "      BEFORE the down if you need the network half of a round answered."
fi

# --- the NOTEs: the things that are honest about not knowing, and are not failures ---------------
if (( N_UNANSWERABLE > 0 )); then
    echo "NOTE: $N_UNANSWERABLE question(s) not answerable -- 'nobody asked', NOT 'the network is"
    echo "      clean'. A NOTE and not a FAIL (Adam 2026-09-10)."
fi
if (( N_UNDATED > 0 )); then
    echo "NOTE: $N_UNDATED rule(s) could not be dated -- a rule this tool could not place, not a"
    echo "      finding. On a P4 fabric this is EVERY rule (W16-3). A NOTE and not a FAIL."
fi
# Printed by residue_report on its own line, deliberately outside the tally: apps that have no
# channel at all to be asked on (energy has no disk log, ever). Carried through for the same
# reason ndt prints it -- so CLEAN cannot be read as "everything was asked".
grep -F -- 'could not be asked whether they ran here at all' <<<"$REPORT" \
    | sed 's/^[[:space:]]*/NOTE: /'
# The tool's own sentences for WHY something could not be answered. Quoted rather than summarised:
# a reader copying this into a round log should be copying ndt's words, not mine.
grep -E -- 'CANNOT BE ASKED|CANNOT READ|CANNOT WINDOW|window is LOST|NOT CHECKED|the kernel is not up|was not valid JSON|gave no flow table' <<<"$REPORT" \
    | sed 's/^[[:space:]]*/NOTE-WHY: /'

# --- the verdict --------------------------------------------------------------------------------
REASONS=()
case "$PROCESSES" in
    running) REASONS+=("untracked app processes are running -- 'ndt apps stop <name>'") ;;
    unknown) REASONS+=("a liveness channel was blind, so the process half was NOT answered (E-7: a check that could not look must not look like a clean check)") ;;
esac
(( N_RULES > 0 )) && REASONS+=("$N_RULES dated rule(s) in a window -- remove by hand, nothing here deletes them")
(( N_LOCKS > 0 )) && REASONS+=("$N_LOCKS lock(s) held -- a lock frees itself at its TTL")

if (( ${#REASONS[@]} == 0 )); then
    # 🔴 The kernel-down verdict is QUALIFIED on its own line rather than left as a bare
    # `VERDICT: CLEAN`, because the NOTE above is not guaranteed to reach the reader: the
    # print-only call sites are told to show `orphans_verdict.sh <log> <rc> | tail -1`, and
    # `tail -1` is THIS line. "CLEAN" with no qualifier, for a network half nobody read, is the
    # exact shape E-7 forbids. The token `CLEAN` is unchanged, so both the rc and a
    # `grep -F 'VERDICT: CLEAN'` gate (.claude/skills/overnight-hunt/SKILL.md:199) still match.
    if (( KERNEL_DOWN )); then
        echo "VERDICT: CLEAN -- the process half only; the network half was NOT checked (kernel down)"
    else
        echo "VERDICT: CLEAN"
    fi
    exit 0
fi

# Joined by hand and not with `IFS`: `${arr[*]}` joins on the FIRST CHARACTER of IFS only, so
# IFS='; ' would silently produce "a;b" and lose the space this line is formatted around.
JOINED=""
for r in "${REASONS[@]}"; do JOINED="${JOINED:+$JOINED; }$r"; done
printf 'VERDICT: NOT CLEAN -- %s\n' "$JOINED"
exit 1
