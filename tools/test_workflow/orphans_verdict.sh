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
# CLEAN  ==  processes=clean  AND  dated-in-window == 0  AND  locks == 0
#            AND the network half answered SOMETHING (see NOT CHECKED below).
#
# 🔴 `not_answerable > 0` and `could not be dated > 0` are a **NOTE, not a FAIL**. That is the
# whole point of this file. They mean "nobody could ask" -- a kernel that was down, a window that
# was lost, a plane (every P4 fabric) with no time axis on its flow stats. They are not evidence
# of residue, and a gate that fails on them is a gate that can never pass on a P4 fabric or on any
# machine where an app once ran and its pidfile is gone. They are printed loudly instead, with the
# tool's own sentence quoted, so a report that says CLEAN cannot be read as "everything was asked".
#
# =================================================================================================
# NOT CHECKED (rc 3) -- SOME of the network half unanswered is a NOTE; ALL of it is not
# =================================================================================================
# 🔴 The NOTE rule above has a floor, and until 2026-09-11 it did not. Measured offline that day
# (F-OFFLINE-1 §1.11, fixture from ndt:5442 + ndt:5561): a report with the kernel UP, a tally
# PRESENT, and all three lock probes answering `NOT CHECKED (http 500)` reads
#
#     network=0/0/0   not_answerable=3   ->  VERDICT: CLEAN   rc 0
#
# because every counter the tally carries is zero -- and they are zero *because nothing was asked
# successfully*, not because the answers came back empty. `ndt` itself answers 5 for that same
# observation (residue_verdict, ndt:5349). Two instruments, one report, 0 against 5.
#
# `0 lock(s) held` after three failed probes is not a measurement of zero. So the CLEAN rule now
# requires one positive answer from the network half, and the verdict when there is none is a new
# token:
#
#     some questions unanswered, at least one answered  ->  CLEAN, with the NOTEs (unchanged)
#     the kernel was up, and NOT ONE came back          ->  NOT CHECKED (rc 3)
#
# 🔴 An answer means the network half got a reply about a lock or about a window, in `ndt`'s own
# words: `lock <t> free`, `lock <t> HELD`, `no flow entry arrived during that window`, or a
# `rule(s) listed:` summary. The three lock probes run on EVERY report regardless of whether any
# app has a datable window (ndt:5533-5548), so a healthy kernel always produces at least one --
# which is why the CONTROL case of tests/shell/test_orphans_verdict.sh (a live OVS4 report whose
# only unanswered question is one app's lost window, three locks free) is still CLEAN. Partial
# blindness is the normal state of this lab and stays a NOTE.
#
# 🔴 Why NOT CHECKED is rc 3 and not 1 or 2. rc 1 means "something IS there" and names a remedy
# that deletes it; nothing was found here, so answering 1 would send an operator hunting a rule
# that may not exist. rc 2 means "this report cannot be read"; this one reads perfectly, and its
# numbers are exactly what it claims -- calling it unparseable would be a lie about the report.
# The remedy differs from both: ask again with a kernel that answers. What matters for every
# caller is that it is NOT 0 and does NOT print the token `CLEAN`.
#
# 🔴 And why the kernel-DOWN case keeps its `CLEAN -- the process half only` (Adam 2026-09-10)
# while this one does not, when neither read a lock. `ndt down` closing :8000 is a state the
# operator created on purpose, as the last step of the round whose restore this gate checks; the
# network half is not merely unanswered, it is gone, and the only honest remedy -- "ask BEFORE the
# down" -- is about the next round, not this report. A kernel that is UP and returns http 500 to
# an acquire probe is a malfunction, the question is still askable this second, and it is the one
# case where "nobody asked" cannot be assumed benign. That asymmetry is deliberate and is pinned
# by two cells of tests/shell/test_orphans_verdict.sh, one on each side of it.
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
#     3  NOT CHECKED (the kernel was UP and the network half was asked, and not one of its
#                  questions came back -- zeros that mean "nobody got an answer", not "nothing is
#                  there". Added 2026-09-11 for F-OFFLINE-1 §1.11; also never a pass)
#
# The report also carries a third field from 2026-09-11: `stack=whole-up|whole-down|HALF|
# not-reported`, read from the `stack:` line `ndt apps orphans` prints. HALF is rc 1 -- see the
# H2 note beside STACK below. `not-reported` is every older `ndt` and changes nothing.

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

# --- the stack half: a reading this file used to have no access to ------------------------------
# 🔴 H2, measured live by ROLE-2 on 2026-09-11 (ROLE-2-CYCLES-REPORT §4). This reader printed
# CLEAN three times over a machine whose stack was half up:
#
#   cycle-07  10 bmv2 + 14 mininet processes + a live proxy, kernel down   -> CLEAN
#   cycle-12  10 OVS bridges + 15 mininet processes + a topo session       -> CLEAN
#   cycle-13  a kernel serving a 14-node graph on :8000 with 0 bmv2, 0 mininet, no topo
#             session                                                      -> CLEAN
#
# and every one of those verdicts was correct about what it had been given. `ndt apps orphans`
# answered about APP processes and about the NETWORK; nothing in its report mentioned the
# kernel, the fabric or the proxy, so this file could not have known. It is not knowable from
# this side either -- so `ndt apps orphans` now prints a `stack:` line (stack_state), and this
# reads its verdict word the way it reads the tally's numbers.
#
# 🔴 HALF is the two halves DISAGREEING -- a control plane with no data plane, or a data plane
# with no control plane -- and NOT "something is up". `apps orphans` is asked before a teardown
# as well as after it, on a healthy fabric, where whole-up is the right answer and stays CLEAN.
#
# 🔴 A report with NO stack line is UNKNOWN and changes nothing. Every older `ndt`, and every
# fixture written before 2026-09-11, is in that state, so this cannot turn an old report into a
# failure -- the same rule the kernel-down mode follows: a half nobody reported is named, never
# inferred.
STACK="$(sed -n 's/.*stack: .*verdict=\([A-Za-z-]*\).*/\1/p' <<<"$REPORT" | tail -1)"

# --- did the network half answer ANYTHING? -------------------------------------------------------
# 🔴 F-OFFLINE-1 §1.11. The tally cannot answer this on its own: `0 lock(s) held` is the same
# number whether three probes said `free` or three said `NOT CHECKED (http 500)`, and only the
# first of those is a measurement. So the positive answers are read from the report text, in
# `ndt`'s own words, and matched as whole shapes rather than as bare words:
#
#   ndt:5545  info "  lock  $t free"                          a lock WAS read, and it is free
#   ndt:5543  err  "  lock  $t HELD -- held_by_lease=..."      a lock WAS read, and it is held
#   ndt:5632  ok   "      no flow entry arrived during window" the flow table WAS read for a window
#   ndt:5634  err  "      $n rule(s) listed: ..."              likewise, and it had entries
#
# `lock <t> free` is anchored at end-of-line on purpose: `NOT CHECKED (${lock#unknown })`
# (ndt:5550) carries the probe's own error text, and an unanchored ` free` would match a kernel
# that returned, say, `500 no free lease slot` -- the exact failure this discriminator exists to
# catch. Anchoring is safe because `info` appends nothing after "$*" (ndt:100) and the SGR strip
# above has already removed the colour reset.
NETWORK_ANSWERED=0
if grep -qE -- 'lock[[:space:]]+[A-Za-z_]+ free[[:space:]]*$' <<<"$REPORT" \
   || grep -qF -- 'HELD -- held_by_lease=' <<<"$REPORT" \
   || grep -qF -- 'no flow entry arrived during that window' <<<"$REPORT" \
   || grep -qF -- 'rule(s) listed:' <<<"$REPORT"; then
    NETWORK_ANSWERED=1
fi

echo "processes=$PROCESSES"
if (( KERNEL_DOWN )); then
    echo "network=n/a"
    echo "not_answerable=n/a"
else
    echo "network=$N_RULES/$N_LOCKS/$N_UNDATED"
    echo "not_answerable=$N_UNANSWERABLE"
fi
if [[ -n "$STACK" ]]; then
    echo "stack=$STACK"
else
    # Named, not counted as clean: an `ndt apps orphans` from before 2026-09-11 answered nothing
    # about the stack, and "no answer" must not read as "nothing was up". (E-7)
    echo "stack=not-reported"
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
# 🔴 H2. A stack the report itself calls HALF is a finding, and the remedy is `ndt down` --
# different from every other reason here, which is why it says so rather than being folded in.
[[ "$STACK" == HALF ]] && REASONS+=("the stack is HALF up -- one of the kernel and the data plane is there and the other is not; 'ndt apps orphans' does not answer about the stack and said CLEAN over exactly this on 09-11 (H2). remedy: 'ndt down'")
(( N_RULES > 0 )) && REASONS+=("$N_RULES dated rule(s) in a window -- remove by hand, nothing here deletes them")
(( N_LOCKS > 0 )) && REASONS+=("$N_LOCKS lock(s) held -- a lock frees itself at its TTL")

if (( ${#REASONS[@]} == 0 )); then
    # 🔴 The kernel-down verdict is QUALIFIED on its own line rather than left as a bare
    # `VERDICT: CLEAN`, because the NOTE above is not guaranteed to reach the reader: the
    # print-only call sites are told to show `orphans_verdict.sh <log> <rc> | tail -1`, and
    # `tail -1` is THIS line. "CLEAN" with no qualifier, for a network half nobody read, is the
    # exact shape E-7 forbids. The token `CLEAN` is unchanged, so both the rc and a
    # `grep -F 'VERDICT: CLEAN'` gate (.claude/skills/overnight-hunt/SKILL.md:199) still match.
    # That is Adam's 2026-09-10 ruling and it is NOT changed by the NOT CHECKED branch below.
    if (( KERNEL_DOWN )); then
        echo "VERDICT: CLEAN -- the process half only; the network half was NOT checked (kernel down)"
        exit 0
    fi
    # 🔴 F-OFFLINE-1 §1.11. Kernel UP, tally present, and not one of the network half's questions
    # came back. The three zeros in `network=0/0/0` are then not findings-of-nothing; they are the
    # initial values of counters nothing ever incremented, and the token `CLEAN` over them is the
    # one thing this file exists to prevent. `grep -F 'VERDICT: CLEAN'` gates DO NOT match this
    # line, deliberately -- that is the whole fix.
    if (( N_UNANSWERABLE > 0 && NETWORK_ANSWERED == 0 )); then
        echo "VERDICT: NOT CHECKED -- the process half is clean, and the network half answered"
        echo "         NOTHING: all $N_UNANSWERABLE of its question(s) came back unanswerable and not one"
        echo "         lock or window was read, with the kernel UP (there is a tally, so :8000 was"
        echo "         open). network=0/0/0 here is 'nobody got an answer', NOT 'nothing is there'."
        echo "         Not CLEAN and not NOT CLEAN: nothing was found because nothing could be"
        echo "         asked. Fix what is answering the probes (the NOTE-WHY lines above say what"
        echo "         it was -- http 500 on the lock endpoint means the kernel is up but sick) and"
        echo "         ask again; 'ndt apps orphans' is re-runnable and costs nothing."
        exit 3
    fi
    echo "VERDICT: CLEAN"
    exit 0
fi

# Joined by hand and not with `IFS`: `${arr[*]}` joins on the FIRST CHARACTER of IFS only, so
# IFS='; ' would silently produce "a;b" and lose the space this line is formatted around.
JOINED=""
for r in "${REASONS[@]}"; do JOINED="${JOINED:+$JOINED; }$r"; done
printf 'VERDICT: NOT CLEAN -- %s\n' "$JOINED"
exit 1
