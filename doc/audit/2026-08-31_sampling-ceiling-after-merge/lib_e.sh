#!/usr/bin/env bash
# =================================================================================================
# lib_e.sh -- shared machinery for the E round (PREREG 2026-08-31_sampling-ceiling-after-merge).
#
# [Co-developed with claude code -- Adam]
#
# WHAT THIS FILE IS FOR.  Everything the E round does to the machine goes through one of the
# functions below, for three reasons that the round's own registration names:
#
#   1. PREREG §4 requires the identity of BOTH binaries per cell -- sha256, ldd, readelf -d
#      RUNPATH, identifying strings.  memory/benchmark-must-name-the-binary-it-measured says
#      naming a commit is not enough: which .so actually loads is decided by RUNPATH, not by the
#      environment.  So identity is captured by one function, called at one place, and it records
#      the RUNNING process's /proc/<pid>/exe as well as the file on disk.
#
#   2. PREREG §2 lists gates, and the D round's lesson (§2.3) is that a gate written in a
#      registration and not called in the script is not a gate.  Every gate here is a function,
#      and gates_e.sh calls each one by name so that a grep of the script can be matched against
#      a grep of the registration.
#
#   3. 🔴 THE ABORT CLAUSES ARE CODE, NOT COMMENTS.  `abort` exits.  Nothing in this round
#      lowers a threshold in response to a reading.
#
# DRY RUN -- AND WHY THE ACCEPT PATH IS THE ONE UNDER TEST.
#   DRY_RUN=1 makes every side-effecting command print instead of running, and makes every probe
#   return a synthetic HEALTHY reading, so the whole control flow -- ladder, arm switching, cell
#   archiving, restore -- executes to completion and leaves a transcript.  This is deliberate and
#   it is the harder direction to test: memory/smoke-the-accept-path-not-just-refusals records
#   that a guard's refusal branch can always be exercised live while the branch it protects
#   cannot, so the protected action is what needs the dry run.
#   DRY_FAIL=<tag> forces exactly one probe unhealthy, so the refusal branch is observable too.
#   A harness whose gate can only ever go one colour is the 08-30 mirrored defect; this one is
#   forced in both directions before it is trusted.
# =================================================================================================
set -u

: "${DRY_RUN:=0}"
: "${DRY_FAIL:=}"
PREREG_FILE="${PREREG_FILE:-$ROUND/PREREG.md}"
: "${_DRY_LIVE_ARM:=1hz}"
: "${_LAST_EXE_READ_VIA:=unset}"
: "${_DRY_EXE_READS:=0}"

# 🔴 A dry run and a real run must never share a transcript.  CLAUDE.md: "跑過" and
# "讀過未執行" are never tabled together -- and a log file that contains both is exactly that,
# with the added hazard that the dry lines are the ones that look tidiest.  The suffix is applied
# here, once, after every caller has set LOG.
[[ "$DRY_RUN" == 1 ]] && LOG="${LOG%.log}.dryrun.log"

HERE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

# 🔴 The registration's stop clauses land here.  This function EXITS; there is no variant that
# warns and carries on, because "carry on and note it" is how a stopped round becomes a finished
# one.  PREREG §2 (any gate fails), §3b E-P4 (ratio dropped => batching bug, not a ceiling move).
abort() {
    say "🔴 ABORT($1): ${*:2}"
    say "🔴 the round stops here.  Do NOT adjust a threshold, an arm or the ladder to get past"
    say "🔴 this: PREREG §2 and §3b(C5) both forbid it.  Fix the gate, or report the finding."
    restore_production || say "🔴 and the production restore ALSO failed -- check before release"
    exit 9
}

# Every command that changes the machine goes through RUN.  In a dry run it is printed with a
# DRYRUN-EXEC prefix, which is the observable output the ticket asks for: a guarded action that
# leaves no trace when skipped is a guard nobody can verify.
RUN() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '[%s] DRYRUN-EXEC %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"
        return 0
    fi
    "$@"
}

dry_note() { [[ "$DRY_RUN" == 1 ]] && printf '[%s] DRYRUN-NOTE %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; return 0; }

# -------------------------------------------------------------------------------------------------
# PRECONDITIONS.  The script refuses to start rather than producing a plausible file.
#
# 🔑 Each check prints WHY it failed, because "preconditions not met" sends the next person to
# read the source instead of fixing the machine.  The order is cheapest-first, so a missing
# NDT_OWNER does not cost a fabric probe.
# -------------------------------------------------------------------------------------------------
preflight() {
    local stage="$1" rc=0        # stage: "gates" | "measure" | "plan"
    say "=== preflight ($stage), DRY_RUN=$DRY_RUN ==="

    # -- 0. disk.  A round that fills / mid-ladder loses every cell after the one that filled it,
    #       and on 08-31 two container builds took this machine to zero bytes free.
    local avail; avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    say "  disk: ${avail}G available on /"
    if (( avail < 3 )); then
        printf 'REFUSE: only %sG free on / (need >=3G).  A ladder that fills the disk\n' "$avail" >&2
        printf '        loses every cell after the one that filled it.\n' >&2
        return 1
    fi

    # -- 1. identity of the caller.  ndt reads NDT_OWNER from the environment, never a flag.
    if [[ -z "${NDT_OWNER:-}" ]]; then
        printf 'REFUSE: NDT_OWNER is unset.  Source round.env first.\n' >&2; return 1
    fi

    # -- 2. the claim.  🔴 memory/lab-claim-handoff-protocol: a claim reading is a point sample,
    #       not a lease, so it is re-read HERE, at the moment of acting, not trusted from earlier.
    #       PREREG §4 additionally requires exclusive_cpu=yes -- this round's discriminator is a
    #       CPU plateau, so a concurrent load is not noise, it is a treatment.
    local claim="$KERNEL_DIR/.test_run/lab.claim" owner="" excl=""
    # A dry run must not depend on live lab state: otherwise the accept path becomes untestable
    # exactly when somebody else holds the lab, which is most of the time.  DRY_FAIL=claim is how
    # the refusal branch is reached instead.
    if [[ "$DRY_RUN" == 1 && "$DRY_FAIL" != claim ]]; then
        dry_note "synthesising claim owner=$NDT_OWNER exclusive_cpu=yes (real claim: ${_real_owner:=$(sed -n 's/^owner=//p' "$claim" 2>/dev/null || echo none)})"
        owner="$NDT_OWNER"; excl="yes"
    else
        owner="$(sed -n 's/^owner=//p' "$claim" 2>/dev/null || true)"
        excl="$(sed -n 's/^exclusive_cpu=//p' "$claim" 2>/dev/null || true)"
    fi
    [[ "$DRY_FAIL" == claim ]] && owner="somebody-else"
    if [[ "$owner" != "$NDT_OWNER" ]]; then
        printf 'REFUSE: lab.claim owner=%s but NDT_OWNER=%s.\n' "${owner:-<none>}" "$NDT_OWNER" >&2
        printf '        Claim the lab first:  NDT_EXCLUSIVE_CPU=1 ndt claim 720 %s\n' "'E round'" >&2
        printf '        (and the claim is the only source of truth -- this reading is a point\n' >&2
        printf '         sample, so it is taken again by every stage of the run.)\n' >&2
        return 1
    fi
    if [[ "$excl" != yes ]]; then
        printf 'REFUSE: lab.claim has exclusive_cpu=%s.  PREREG §4 requires exclusive CPU:\n' "${excl:-<unset>}" >&2
        printf '        this round reads a CPU plateau, so a sibling build is a treatment, not noise.\n' >&2
        printf '        Re-claim with NDT_EXCLUSIVE_CPU=1 set.\n' >&2
        return 1
    fi
    say "  claim: owner=$owner exclusive_cpu=$excl"


    # 🔴 The evidence-basis field in the registration is a GATE, not a note.  Verification belongs
    # on an executable precondition, not in a revision record -- the same rule as "acceptance goes
    # on the state, not on the rc".  A round whose clauses are registered but not demonstrably
    # exercised must not start.
    local ebasis
    # 🔴 LINE-ANCHORED.  An unanchored grep -m1 takes the first hit anywhere in the file, so the
    # gate's correctness would depend on document ordering -- and this round pastes verbatim force
    # output (which contains the literal string EVIDENCE-BASIS: INCOMPLETE) into the upper half.
    # The pasted lines begin with "[ok]" or whitespace+"[", so anchoring excludes them structurally.
    ebasis=$(grep -m1 -oE '^[[:space:]]*EVIDENCE-BASIS: [A-Z]*' "$PREREG_FILE" 2>/dev/null | awk '{print $2}')
    # No DRY_FAIL special case here on purpose: the matrix points PREREG_FILE at a FIXTURE
    # whose content really says INCOMPLETE, so what gets tested is the reader against real
    # content rather than a branch that only exists for the test.  Breaks the circularity too --
    # the master registration is never read during its own force.
    if [[ "$ebasis" != "COMPLETE" ]]; then
        printf 'REFUSE: the registration reports EVIDENCE-BASIS: %s\n' "${ebasis:-<absent>}" >&2
        printf '        Registered clauses exist but are not all demonstrably exercised.  Fix the\n' >&2
        printf '        coverage, re-run the forces, and update the field WITH its verbatim output.\n' >&2
        printf '        %s\n' "$PREREG_FILE" >&2
        return 1
    fi

    [[ "$stage" == plan ]] && { say "  (plan only -- fabric checks skipped)"; return 0; }

    # -- 3. the staged binaries.  The recompute axis has no runtime switch; if the pre-window
    #       build did not happen there is no 1 kHz arm and the 2x2 is a 1x2.  Better to say so now
    #       than to run 40 cells of a design that cannot answer Q2.
    local b
    for b in "$KBIN_1KHZ" "$KBIN_1HZ"; do
        if [[ "$DRY_RUN" == 1 && "$DRY_FAIL" != staged && ! -s "$b" ]]; then
            dry_note "staged arm $b absent; synthesising present so the accept path runs"
            continue
        fi
        if [[ "$DRY_FAIL" == staged || ! -s "$b" ]]; then
            printf 'REFUSE: staged kernel binary missing: %s\n' "$b" >&2
            printf '        Run build_1khz_binary.sh BEFORE the window opens -- PREREG §4 and the\n' >&2
            printf '        fabric queue both forbid building inside it, and there is no env var\n' >&2
            printf '        that switches kFlowPathRecomputeInterval at run time.\n' >&2
            return 1
        fi
    done
    say "  staged binaries: present"

    # -- 4. the fabric.  This is the check the ticket cares about: without it the script would
    #       happily write a full ladder of NO-DATA cells and they would look like a result.
    if ! fabric_is_up; then
        printf 'REFUSE: no live P4 fabric (expected 10 bmv2 switches and :8000 answering).\n' >&2
        printf '        This script measures; it does not bring the lab up.  Start it first:\n' >&2
        printf '          NDT_OWNER=%s ndt up p4 128\n' "$NDT_OWNER" >&2
        printf '        A ladder run without a fabric produces NO-DATA cells that are shaped\n' >&2
        printf '        exactly like a saturated ceiling.\n' >&2
        return 1
    fi
    say "  fabric: up"

    # -- 5. nothing else measuring.  `ndt` computes `measuring` live from process names; a
    #       foreign iperf3 would both contaminate this round and be destroyed by measure.sh's
    #       own cleanup (see foreign_iperf3_guard).
    foreign_iperf3_guard || return 1
    return 0
}

fabric_is_up() {
    if [[ "$DRY_RUN" == 1 ]]; then
        [[ "$DRY_FAIL" == fabric ]] && { dry_note "forcing fabric_is_up FALSE"; return 1; }
        dry_note "synthesising fabric_is_up TRUE (bmv2: 10, :8000 answering)"; return 0
    fi
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || return 1
    curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" || return 1
    return 0
}

# 🔴 measure.sh -- which this round reuses UNCHANGED so that its cells stay comparable with the
# D round's -- clears stale servers with `pkill -f iperf3`, and its own comment records that
# mininet hosts share the root PID namespace, "which is why a plain pkill reaches them at all".
# That is a project-wide prohibited verb (CLAUDE.md; memory/destructive-shell-traps, seven
# self-kills to date) and it would reach a sibling session's iperf3.
#
# This round does not edit measure.sh -- editing it would fork the instrument the §6 comparison
# depends on -- so instead it refuses to hand control to measure.sh while any iperf3 exists that
# this round did not start.  Enumeration is by exact `comm`, never by `pgrep -f`: a -f pattern
# match always matches the searching command line itself.
foreign_iperf3_guard() {
    local pids
    if [[ "$DRY_RUN" == 1 ]]; then
        if [[ "$DRY_FAIL" == iperf3 ]]; then
            printf 'REFUSE: iperf3 already running (pids: 424242) and this round did not start it.\n' >&2
            return 1
        fi
        dry_note "synthesising: no foreign iperf3"; return 0
    fi
    pids=$(ps -eo pid=,comm= | awk '$2=="iperf3"{printf "%s ", $1}')
    if [[ -n "${pids// /}" ]]; then
        printf 'REFUSE: iperf3 already running (pids: %s) and this round did not start it.\n' "$pids" >&2
        printf '        measure.sh clears stale servers with `pkill -f iperf3` at the ROOT pid\n' >&2
        printf '        namespace, so continuing would destroy a sibling session process.  Stop\n' >&2
        printf '        it by PID yourself, then re-run.  Never `pkill -f`.\n' >&2
        return 1
    fi
    return 0
}

# -------------------------------------------------------------------------------------------------
# BINARY IDENTITY (PREREG §4 / §C3).
#
# Four things, because three of them are individually insufficient and the round has been bitten
# by each: sha256 of the file names the bytes; `ldd` names the libraries resolved NOW; `readelf -d`
# names the RUNPATH that decided that resolution (an environment variable does not); and the
# running process's /proc/<pid>/exe names what is actually executing, which is the only one of the
# four that a recompile 9 seconds before exec cannot invalidate.
#
# `commit=` is written as UNKNOWN unless the caller supplies one.  🔴 That is a measurement, not a
# placeholder -- the same discipline as .test_run/binaries/*.provenance.  mtime is deliberately
# NOT recorded as evidence: on this machine a binary is on record as being 26 s OLDER than the
# commit that describes it.
# -------------------------------------------------------------------------------------------------
record_identity() {   # $1 = tag (goes in the filename), $2 = commit-or-UNKNOWN
    local tag="$1" commit="${2:-UNKNOWN}" f="$OUT/identity_$1.txt"
    {
        printf '# binary identity for %s\n' "$tag"
        printf 'when=%s\n' "$(date -Is)"
        printf 'commit=%s\n' "$commit"
        printf 'dirty_worktree=%s\n' "$(git -C "$KERNEL_DIR" status --porcelain | wc -l) file(s) modified"
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
        local b
        for b in "$KBIN" /usr/local/bmv2-fast/bin/simple_switch_grpc; do
            [[ -e "$b" ]] || { printf '\n[%s] ABSENT\n' "$b"; continue; }
            printf '\n[%s]\n' "$b"
            printf 'sha256=%s\n' "$(sha256sum "$b" | cut -d' ' -f1)"
            printf 'size=%s\n'   "$(stat -c%s "$b")"
            printf -- '--- ldd ---\n';        ldd "$b" 2>&1
            printf -- '--- readelf -d ---\n'; readelf -d "$b" 2>&1 | grep -E 'RUNPATH|RPATH|NEEDED|SONAME'
        done
        # Identifying strings / symbols.  Signatures, not circumstances: each names a commit whose
        # presence or absence is a fact about these bytes.  The 1 Hz symbol is what separates this
        # round's two kernel arms and it is asserted per cell, not assumed from the filename.
        printf '\n--- symbol signatures (kernel) ---\n'
        # 🔴 NOT A DISCRIMINATOR FOR THIS ROUND'S TWO ARMS -- recorded only.  The label is on the
        # OUTPUT LINE, not just in the registration, because the next reader will not scroll back
        # to §4 to find out that this column cannot decide anything.
        printf 'contains_2f57ba5_kFlowPathRecomputeInterval=%s  [NON-DISCRIMINATING: both arms are\n' \
               "$(nm -C "$KBIN" 2>/dev/null | grep -c kFlowPathRecomputeInterval)"
        printf '  built from one tree and differ only in the constant VALUE, so this count is equal\n'
        printf '  on both.  Arm identity comes from sha256 vs .provenance; the VALUE is proven by\n'
        printf '  the gtest at build time and by recompute_rate.py at run time.]\n'
        printf 'contains_91e7743_setProgrammedPredicate=%s\n' \
               "$(nm -C "$KBIN" 2>/dev/null | grep -c setProgrammedPredicate)"
        printf '\n--- proxy ---\n'
        printf 'main_py_sha256=%s\n'     "$(sha256sum "$KERNEL_DIR/p4_proxy/proxy_agent/main.py" | cut -d' ' -f1)"
        printf 'emitter_py_sha256=%s\n'  "$(sha256sum "$KERNEL_DIR/p4_proxy/proxy_agent/sflow_emitter.py" | cut -d' ' -f1)"
        printf 'python=%s\n'             "$($PY_PROXY -V 2>&1)"
        # 🔴 PREREG §4: truncate=128 is asserted per cell, not assumed.  Both the source constant
        # and the compiled artefact, because bmv2 runs the artefact.
        printf '\n--- p4 constants ---\n'
        grep -E '^const bit<(16|32)> SAMPLE_(RATE|TRUNC_BYTES)' "$P4SRC" 2>/dev/null
        printf 'compiled_json_sha256=%s\n' \
               "$(sha256sum "$P4BUILD/ndtwin_switch.json" 2>/dev/null | cut -d' ' -f1)"
    } >"$f" 2>&1
    say "  identity -> $f"
}

# The bracket (PREREG-F5 §4 F4, applied here too because it is strictly more provenance and costs
# one read).  A claim protects the fabric; it does not protect the file on disk.  Taking the
# RUNNING process's exe hash at the start and end of a cell is the only check that catches a
# rebuild landing between two arms.
running_kernel_sha() {
    if [[ "$DRY_RUN" == 1 ]]; then
        # 🔴 exedriftmid: the FIRST read is arm-correct (so assert_running_arm passes and the
        # bracket is actually REACHED), and every read after it drifts (so open != close).
        # Without it the bracket had ZERO force coverage in two independent ways: exedrift sets
        # both ends to the SAME wrong value, so the comparison only ever compared equal values;
        # and assert_running_arm runs first and aborts, so the bracket was never even reached.
        # Third instance of the fixture trap -- the first two only tested nothing, this one was
        # never executed.
        case "$DRY_FAIL" in
            # Named for WHAT IT TESTS, not for what it injects: both of these are
            # absorbed by assert_running_arm and never reach the bracket.  A row that
            # misstates what it covers is another "looks verified" artefact -- the
            # table is a product people read.
            exeunreadable_absorbed) echo "UNREADABLE"; return 0 ;;
            # Only the CLOSING read is unreadable, so the earlier identity check passes and the
            # BRACKET's own shape test is what fires.  Found by building the force matrix: with
            # `exeunreadable` alone, E aborted at ABORT(§4 running-arm) -- absorbed again -- so
            # E's bracket-unreadable branch had no force reaching it while F-5's did.
            exeunreadablemid)
                [[ "${_DRY_PHASE:-}" == close ]] && { echo "UNREADABLE"; return 0; }
                ;;
            exedrift_absorbed) echo "$(printf 'd%063d' 1)"; return 0 ;;
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
        # A synthetic value that PASSES the 64-hex shape test, so the accept path is really
        # exercised rather than skipped by a sentinel that would fail the shape test anyway.
        # 🔑 It FOLLOWS whichever arm swap_kernel last installed.  The first version returned a
        # constant, which silently made the accept path unreachable for the other arm -- a dry-run
        # fixture that can only ever produce one verdict is the same defect this file is about,
        # one level up.
        case "${_DRY_LIVE_ARM:-1hz}" in
            1khz) printf 'b%063d\n' 0 ;;
            *)    printf 'a%063d\n' 0 ;;
        esac
        return 0
    fi
    local pid h
    pid=$(ps -eo pid=,comm= | awk '$2=="ndtwin_kernel"{print $1; exit}')
    [[ -n "${pid:-}" ]] || { echo "NO-KERNEL-PROCESS"; return 0; }
    # 🔑 Try unprivileged FIRST, fall back to sudo, and RECORD WHICH PATH WAS USED.
    # Adopted from the reviewer line's arm_binary_assert.sh: a check that silently escalates
    # hides the difference between "read it" and "was allowed to read it" -- and if the process
    # runs as root, the unprivileged read returns empty, which without the fallback would look
    # like "unreadable" and abort a perfectly good cell.
    h=$(sha256sum "/proc/$pid/exe" 2>/dev/null | cut -d' ' -f1); _LAST_EXE_READ_VIA=direct
    if [[ -z "$h" ]]; then
        h=$(sudo -n sha256sum "/proc/$pid/exe" 2>/dev/null | cut -d' ' -f1); _LAST_EXE_READ_VIA=sudo
    fi
    [[ -n "$h" ]] || { _LAST_EXE_READ_VIA=none; echo "UNREADABLE"; return 0; }
    echo "$h"
}

# -------------------------------------------------------------------------------------------------
# 🔴 IS THE PROCESS THAT IS RUNNING THE ARM THIS CELL CLAIMS TO BE?
#
# This is the check the reviewer line found missing from PREREG-B, transplanted here because E has
# the same exposure: BL/M and P/MP differ by BINARY, and every identity field the registration asks
# for (sha256, ldd, readelf -d, strings) can be recorded off the COMPILED ARTEFACT and still be
# perfectly correct while the fabric runs something else.  Only /proc/<pid>/exe can refute that.
#
# On this machine the kernel is exec'd as `./bin/ndtwin_kernel` (stack.sh:766) -- a RELATIVE path,
# so the bare-name/PATH variant that bit the bmv2 launcher cannot occur for the kernel.  The
# remaining ways to run the wrong arm are: the cp did not land; a previous cell's process outlived
# `stack.sh down`; or something rebuilt build/bin between the swap and the exec.  All three are
# refuted by comparing the RUNNING exe's hash to the STAGED arm's hash.
#
# 🔑 TWO WAYS THIS CHECK COULD PASS WITHOUT CHECKING, BOTH CLOSED HERE:
#   1. the sentinel: `running_kernel_sha` returns NO-KERNEL-PROCESS / UNREADABLE on failure, and
#      two sentinels COMPARE EQUAL -- so an open/close bracket built on it passes vacuously.
#      The shape test (64 lowercase hex) is what turns "could not read" into a refusal.
#   2. the silent skip: a caller that never reaches the comparison looks exactly like one that
#      made it.  So the verdict is EMITTED as `IDENTITY verdict=MATCH|MISMATCH|UNREADABLE`, and
#      the force test greps for MATCH specifically rather than for exit status 0.
# -------------------------------------------------------------------------------------------------
check_running_arm() {   # $1 = staged binary path.  Prints a verdict line; 0=MATCH, 1=MISMATCH, 2=UNREADABLE
    local staged="$1" want got
    want=$(sed -n 's/^sha256=//p' "$staged.provenance" 2>/dev/null | head -1)
    # In a dry run the arms have not been built, so the STAGED side is synthesised to match what
    # running_kernel_sha synthesises -- 1hz agrees, 1khz deliberately does not, which is what makes
    # the force-red reachable without a fabric.
    if [[ "$DRY_RUN" == 1 && -z "$want" ]]; then
        case "$staged" in
            *1khz) want=$(printf 'b%063d' 0) ;;
            *)     want=$(printf 'a%063d' 0) ;;
        esac
    fi
    got=$(running_kernel_sha)
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
        echo "IDENTITY verdict=UNREADABLE reason=no-staged-sha256 staged=$staged"; return 2
    fi
    if [[ ! "$got" =~ ^[0-9a-f]{64}$ ]]; then
        echo "IDENTITY verdict=UNREADABLE reason=running-exe-unreadable got=$got"; return 2
    fi
    if [[ "$want" != "$got" ]]; then
        echo "IDENTITY verdict=MISMATCH want=$want got=$got"; return 1
    fi
    echo "IDENTITY verdict=MATCH want=$want got=$got read_via=${_LAST_EXE_READ_VIA}"; return 0
}

assert_running_arm() {   # abort-wrapping caller
    local out rc
    out=$(check_running_arm "$1"); rc=$?
    say "    $out"
    (( rc == 0 )) && return 0
    abort "§4 running-arm" "the RUNNING kernel is not the arm this cell claims.
        $out
        Every identity field this round records can be taken off the compiled artefact and be
        correct while the fabric runs something else; this is the only check that refutes it.
        A cell measured on the wrong arm is a clean, reproducible, completely wrong result."
}

# bmv2's identity, which NEITHER prereg asks for and which decides this round's sampling.
# The launcher is chosen by p4_proxy/mininet/bmv2_binary_override (one directive line, absolute
# path).  Since 2026-08-22 a missing directive is a REFUSAL rather than a fallback -- so the
# bare-name PATH trap is closed on this machine -- but WHICH path the file names is still a free
# variable that changes the number, and nothing in this round recorded it until now.
record_bmv2_identity() {
    local f="$OUT/identity_bmv2_$1.txt" ovr="$KERNEL_DIR/p4_proxy/mininet/bmv2_binary_override"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would record the bmv2 override directive and the sha256 of each RUNNING simple_switch_grpc from /proc"
        return 0
    fi
    {
        printf 'when=%s\n' "$(date -Is)"
        printf 'override_directive=%s\n' "$(grep -vE '^[[:space:]]*(#|$)' "$ovr" 2>/dev/null | head -1)"
        printf 'override_file_sha256=%s\n' "$(sha256sum "$ovr" 2>/dev/null | cut -d' ' -f1)"
        # 🔴 What the switches ARE running, not what the file says they should.  The 08-22 stock
        # control ladder already established this technique ("each arm verifying from /proc which
        # binary the live switches actually run"); it simply was never carried into this round.
        local pid
        for pid in $(ps -eo pid=,comm= | awk '$2=="simple_switch_"{print $1}'); do
            printf 'running pid=%s exe=%s sha256=%s\n' "$pid" \
                "$(sudo -n readlink -f /proc/$pid/exe 2>/dev/null)" \
                "$(sudo -n sha256sum /proc/$pid/exe 2>/dev/null | cut -d' ' -f1)"
        done
    } >"$f" 2>&1
    # One distinct binary across all ten switches, or the arm is a mixture.
    local n; n=$(grep -c '^running pid=' "$f")
    local d; d=$(grep '^running pid=' "$f" | grep -oE 'sha256=[0-9a-f]{64}' | sort -u | wc -l)
    say "    bmv2: $n running switch(es), $d distinct binary/binaries -> $f"
    if (( n > 0 && d != 1 )); then
        abort "§4 bmv2" "the ten switches are not all running the same binary ($d distinct).
        A ceiling measured across a mixture is not a ceiling of either binary."
    fi
}

# -------------------------------------------------------------------------------------------------
# FABRIC LIFECYCLE.  Structure is gate_e.sh's, deliberately -- same teardown, same bringup, same
# poll bounds -- so that a cell of this round differs from a cell of the 08-25 round only in the
# things the registration says differ.
# -------------------------------------------------------------------------------------------------
free_8081() {
    # stack.sh down will not kill a proxy it did not start, which is right and which is what
    # stalled wall_f's first attempt.  Clearing the port is the caller's job.  By PID from ss,
    # never `pkill -f`: this file's own command line contains the pattern.
    local pid
    [[ "$DRY_RUN" == 1 ]] && { dry_note "would clear :8081 if held"; return 0; }
    pid=$(ss -ltnp 2>/dev/null | grep ":8081" | grep -oE "pid=[0-9]+" | cut -d= -f2 | head -1)
    [[ -n "${pid:-}" ]] || return 0
    say "    clearing :8081 held by pid $pid"
    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do ss -ltnp 2>/dev/null | grep -q ":8081" || return 0; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true; sleep 2
    ss -ltnp 2>/dev/null | grep -q ":8081" && { say "    FATAL: :8081 still held"; return 1; }
    return 0
}

teardown() {
    RUN "$KERNEL_DIR/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
    free_8081 || abort "teardown" ":8081 could not be freed; the next bringup would measure a stale proxy"
    RUN $LAB topo-stop >>"$LOG" 2>&1 || true
    # setsid: `ndtwin-lab cleanup` runs `mn -c`, which kills broadly enough to take out the shell
    # that called it.  It has killed a driver mid-run before.
    RUN setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
    RUN sleep 3
}

bringup() {   # $1 = NDTWIN_SFLOW_BATCH value for this cell
    local batch="$1" i
    RUN $LAB topo-start >>"$LOG" 2>&1
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would poll ndtwin-lab status for 'bmv2: 10' (<=200 s)"
    else
        for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
        $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "    fabric short of 10"; return 1; }
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
        # Not backgrounded in a dry run: a backgrounded print races the transcript it belongs to,
        # and an unordered transcript is not a verifiable one.
        RUN env NDTWIN_SFLOW_BATCH="$batch" TOPO_P4="$TOPO" \
            nohup "$KERNEL_DIR/tools/test_workflow/stack.sh" up p4
        dry_note "would poll :8000/ndt/get_graph_data for readiness (<=200 s)"
        return 0
    fi
    env NDTWIN_SFLOW_BATCH="$batch" TOPO_P4="$TOPO" \
        nohup "$KERNEL_DIR/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do
        sleep 5
        curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0
    done
    say "    kernel API never came up"; return 1
}

# 🔴 The batching value has to be shown to have REACHED the emitter, not merely to have been
# exported.  memory: an env var whose reader does not exist is this repo's most-repeated bug
# shape, and NDTWIN_CLONE_DISABLE shipped a committed setter, committed docs and zero readers.
# GET /sflow/stats answers with the value the emitter is actually holding, and 503s (never zeros)
# if the emitter was not injected.
assert_batch_took() {   # $1 = expected batch size
    local want="$1" got
    if [[ "$DRY_RUN" == 1 ]]; then dry_note "would GET :8081/sflow/stats and assert batch_size=$want"; return 0; fi
    got=$(curl -sf --max-time 10 http://localhost:8081/sflow/stats \
          | "$PY_PROXY" -c 'import json,sys; print(json.load(sys.stdin).get("batch_size"))' 2>/dev/null)
    if [[ "$got" != "$want" ]]; then
        abort "§2 batch-wiring" "GET /sflow/stats reports batch_size=${got:-<no answer>}, expected $want.
        The value did not reach the emitter, so an arm labelled 'batching on' would be
        measuring 'batching off' under a different name."
    fi
    say "    batch_size confirmed at the emitter: $got"
}

# PREREG §4: truncate=128 is the production setting and must hold in ALL cells.  Asserted against
# the COMPILED artefact, because that is what bmv2 loads -- and bmv2 loads it at exec and never
# reloads, which is why every rate change is followed by a full fabric restart.
assert_truncate_128() {
    if [[ "$DRY_RUN" == 1 ]]; then dry_note "would assert SAMPLE_TRUNC_BYTES=128 in source and compiled JSON"; return 0; fi
    grep -q '^const bit<32> SAMPLE_TRUNC_BYTES = 128;' "$P4SRC" \
        || abort "§4 truncate" "SAMPLE_TRUNC_BYTES is not 128 in $P4SRC"
    grep -q '"op" *: *"truncate"' "$P4BUILD/ndtwin_switch.json" \
        || abort "§4 truncate" "the truncate op is absent from the compiled JSON that bmv2 will load"
}

compile_at() {   # $1 = SAMPLE_RATE.  truncate is pinned at 128 for every cell (PREREG §4).
    local rate="$1"
    RUN sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $rate;/" "$P4SRC"
    RUN sed -i -E "s/^const bit<32> SAMPLE_TRUNC_BYTES = [0-9]+;/const bit<32> SAMPLE_TRUNC_BYTES = 128;/" "$P4SRC"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would assert the seds landed, then p4c-bm2-ss, then assert truncate in the JSON"
        return 0
    fi
    # Assert the injection landed -- in the SOURCE first, because a sed that silently matched
    # nothing is reported by sed as success.
    grep -q "SAMPLE_RATE = $rate;" "$P4SRC" || abort "compile" "the SAMPLE_RATE sed matched nothing"
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 \
        || abort "compile" "p4c-bm2-ss failed at rate 1/$rate"
    assert_truncate_128
}

# -------------------------------------------------------------------------------------------------
# KERNEL ARM SWITCHING.
#
# 🔴 There is no flag.  kFlowPathRecomputeInterval is `constexpr` in
# include/ndt_core/collection/FlowLinkUsageCollector.hpp:51, its single use site is
# src/ndt_core/collection/FlowLinkUsageCollector.cpp:2969, and the only getenv anywhere in the
# kernel's collection tree is NDTWIN_TOPO_FILE.  Switching this axis means switching the file
# stack.sh execs, because stack.sh:766 hardcodes $KERNEL_DIR/build/bin/ndtwin_kernel.
#
# The production binary is backed up on first use and restored by restore_production.
#
# 🔴 THE SWAP IS VERIFIED BY sha256 AGAINST THE STAGED FILE'S RECORDED HASH, NOT BY SYMBOL.
# The .test_run/binaries provenance files separate M's binary from Q's with
# `nm -C | grep -c kFlowPathRecomputeInterval` (5 hits vs 0), and that worked there because
# ab2d7ed1 predates the CONSTANT'S EXISTENCE.  It does NOT work for this round's two arms: both
# are built from the same tree and differ only in the constant's VALUE, so the symbol is present
# in both and the count would read 5 == 5 -- a discriminator with no discriminating power, which
# is worse than none because it looks like a check.
# What proves the value is the build step, where a gtest that asserts `== seconds(1)` is run
# against each binary and required to come out opposite ways; see build_1khz_binary.sh.  Here the
# binary is bound to that build by its hash.
# -------------------------------------------------------------------------------------------------
swap_kernel() {   # $1 = 1khz | 1hz
    local which="$1" src
    case "$which" in
        1khz) src="$KBIN_1KHZ" ;;   # microseconds(1000): 2f57ba5 reverted at the value
        1hz)  src="$KBIN_1HZ"  ;;   # seconds(1): the frozen tip
        *) abort "swap_kernel" "unknown arm '$which'" ;;
    esac
    if [[ ! -f "$KBIN_BACKUP" ]]; then
        RUN mkdir -p "$(dirname "$KBIN_BACKUP")"
        RUN cp -p "$KBIN" "$KBIN_BACKUP"
        say "    production kernel backed up -> $KBIN_BACKUP"
    fi
    RUN cp -f "$src" "$KBIN"
    _DRY_LIVE_ARM="$which"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would verify sha256($KBIN) == the sha256 recorded in $src.provenance,"
        dry_note "  and that the two staged arms' hashes differ from each other"
        return 0
    fi
    local want got other
    want=$(sed -n 's/^sha256=//p' "$src.provenance" 2>/dev/null | head -1)
    got=$(sha256sum "$KBIN" | cut -d' ' -f1)
    [[ -n "$want" ]] || abort "swap_kernel" "$src has no .provenance recording its sha256.
        An unidentified binary cannot be an arm -- benchmark-must-name-the-binary-it-measured."
    [[ "$want" == "$got" ]] || abort "swap_kernel" "arm '$which': staged sha256 $want != in-place $got"
    # Negative control on the identification itself: if the two arms hash the same, the build did
    # not pick up the one-line change and both 'arms' are one arm under two names.
    other=$([[ "$which" == 1khz ]] && sha256sum "$KBIN_1HZ" | cut -d' ' -f1 \
                                   || sha256sum "$KBIN_1KHZ" | cut -d' ' -f1)
    [[ "$got" != "$other" ]] || abort "swap_kernel" "the two staged arms are byte-identical.
        The recompute axis is not being varied at all; every Q2 reading would be a duplicate."
    say "    kernel arm=$which sha256=$got (verified against $src.provenance)"
}

# -------------------------------------------------------------------------------------------------
# #11 -- RESTORE THE PRODUCTION CONFIGURATION, AND BE LOUD IF IT DID NOT LAND.
#
# All six D-round drivers had this (gate_d:103, ladder_ext:121, wall_f:142, run_c:68, h_probe:142,
# ctl_c:71) and NEITHER new registration inherited it.  It is not a precaution: run_c.sh:46 records
# it happening -- "earlier arm of gate_d.sh set it to 16384 and only its own restore put it back"
# -- which is why run_c added an independent truncate==128 assertion.
#
# 🔴 WHY IT MATTERS MORE HERE THAN IT DID IN D.  This round mutates the P4 source AND swaps the
# kernel binary, F-5 swaps binaries between arms, and the fabric queue has the two rounds adjacent.
# A failed restore therefore contaminates the SIBLING ROUND, which cannot see it -- it inherits a
# fabric whose numbers are merely a little odd.
#
# 🔴 AND THE PROTECTION FAILS AT THE MOMENT IT IS NEEDED.  Restore runs last, when the operator
# has stopped watching; "restore failed" printed into a scrolled-past log is not loud.  So this
# does three things instead of printing: it ASSERTS each element landed, it drops a marker file
# that a release must trip over, and it returns non-zero.
# -------------------------------------------------------------------------------------------------
assert_restore_landed() {
    local fail=0 f="$OUT/RESTORE-FAILED"
    # Each element is checked against the artefact that will actually be READ next time, not
    # against the command that was issued.
    if [[ "$DRY_RUN" == 1 ]]; then
        if [[ "$DRY_FAIL" == restore ]]; then
            dry_note "forcing restore verification to FAIL"
            fail=1
        else
            dry_note "would assert: SAMPLE_RATE=256 and SAMPLE_TRUNC_BYTES=128 in source AND in the"
            dry_note "  compiled JSON; kernel sha256 == the production backup's; no RESTORE-FAILED marker"
        fi
    else
        grep -q '^const bit<16> SAMPLE_RATE = 256;' "$P4SRC" || { say "🔴 restore: SAMPLE_RATE is not 256"; fail=1; }
        grep -q '^const bit<32> SAMPLE_TRUNC_BYTES = 128;' "$P4SRC" || { say "🔴 restore: truncate is not 128"; fail=1; }
        grep -q '"op" *: *"truncate"' "$P4BUILD/ndtwin_switch.json" 2>/dev/null \
            || { say "🔴 restore: the compiled JSON has no truncate op"; fail=1; }
        if [[ -f "$KBIN_BACKUP" ]]; then
            local a b; a=$(sha256sum "$KBIN_BACKUP" | cut -d' ' -f1); b=$(sha256sum "$KBIN" | cut -d' ' -f1)
            [[ "$a" == "$b" ]] || { say "🔴 restore: kernel is $b, production backup is $a"; fail=1; }
        fi
    fi

    if (( fail )); then
        # Loud means three channels, because a line in a log is not loud when nobody is watching:
        #   (1) the transcript, (2) stderr, (3) a marker file the next actor must trip over.
        say "🔴🔴🔴 PRODUCTION RESTORE FAILED -- DO NOT RELEASE THE LAB 🔴🔴🔴"
        say "🔴 The next round in the queue would inherit this fabric and could not tell."
        printf '%s\n' "RESTORE-FAILED $(date -Is) -- do not release the lab; see $LOG" >&2
        [[ "$DRY_RUN" == 1 ]] || { mkdir -p "$OUT"; printf 'RESTORE-FAILED %s\n' "$(date -Is)" >"$f"; }
        return 1
    fi
    say "    restore verified: P4 constants, compiled artefact and kernel binary all back at production"
    [[ "$DRY_RUN" == 1 ]] || rm -f "$f"
    return 0
}

restore_production() {
    say "--- restoring production config (1/256, truncate 128, batch unset, production kernel) ---"
    if [[ -f "$KBIN_BACKUP" ]]; then
        RUN cp -f "$KBIN_BACKUP" "$KBIN"
        say "    kernel restored: $(RUN sha256sum "$KBIN" 2>/dev/null | cut -d' ' -f1)"
    fi
    teardown
    compile_at 256 || { assert_restore_landed; return 1; }
    assert_restore_landed || return 1
    return 0
}

# -------------------------------------------------------------------------------------------------
# #14 -- AN INVARIANT ACROSS A RESTART.
# run_e8:67 compared edge count before and after a proxy restart and shouted "telemetry
# multiplication trap may have fired" (memory: proxy-restart-warm-fabric-multiplies-telemetry).
# This round rebuilds the fabric EVERY CELL and registered no before/after check at all.
# The topology is identical by construction across cells, so a changed edge count means the
# rebuild did not reproduce the fabric -- and every ceiling reading is per-fabric.
# -------------------------------------------------------------------------------------------------
edge_count() {
    if [[ "$DRY_RUN" == 1 ]]; then
        # 🔑 Only drift once a baseline exists: a forced value on the FIRST read just becomes the
        # baseline and nothing ever differs -- the force would silently test nothing.  Drift
        # mid-run is also the real shape of this failure.
        [[ "$DRY_FAIL" == edgecount && -n "$EDGE_BASELINE" ]] && { echo 999; return 0; }
        echo 288; return 0
    fi
    curl -s -m 10 "http://localhost:8000/ndt/get_graph_data" \
      | "$PY_PROXY" -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(-1); raise SystemExit
for k in ("edges","links"):
    v=d.get(k) if isinstance(d,dict) else None
    if isinstance(v,list): print(len(v)); raise SystemExit
print(-1)' 2>/dev/null || echo -1
}

EDGE_BASELINE=""
assert_topology_invariant() {   # $1 = cell label
    local n; n=$(edge_count)
    if [[ "$n" == "-1" || -z "$n" ]]; then
        abort "#14 invariant" "$1: could not read the edge count.  Unreadable is not equal --
        an invariant that cannot be evaluated must refuse, not pass."
    fi
    if [[ -z "$EDGE_BASELINE" ]]; then
        EDGE_BASELINE="$n"; say "    topology invariant: edges=$n (baseline for this run)"; return 0
    fi
    if [[ "$n" != "$EDGE_BASELINE" ]]; then
        abort "#14 invariant" "$1: edge count changed across the rebuild ($EDGE_BASELINE -> $n).
        The fabric was not reproduced, so this cell is not comparable to the earlier ones -- and
        the telemetry-multiplication trap has this exact signature."
    fi
    say "    topology invariant: edges=$n (matches baseline)"
}

# -------------------------------------------------------------------------------------------------
# #3 -- boot_id.  One line, recorded by ladder_ext:83 and by neither new registration.  It is the
# only thing that can answer "were these two cells the same boot", which every /proc counter
# baseline and every thread-id offset silently depends on.
# -------------------------------------------------------------------------------------------------
BOOT_BASELINE=""
assert_same_boot() {   # $1 = cell label
    local b
    if [[ "$DRY_RUN" == 1 ]]; then
        # Same reasoning as edge_count: drift only after the baseline exists.
        [[ "$DRY_FAIL" == bootid && -n "$BOOT_BASELINE" ]] \
            && b="00000000-dead-dead-dead-000000000000" || b="dry-run-synthetic-boot-id"
    else
        b=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    fi
    [[ -n "$b" ]] || abort "#3 boot_id" "$1: boot_id unreadable; unreadable is not equal"
    if [[ -z "$BOOT_BASELINE" ]]; then
        BOOT_BASELINE="$b"
        say "    boot_id=$b uptime=$( [[ "$DRY_RUN" == 1 ]] && echo synthetic || cut -d' ' -f1 /proc/uptime)s (baseline)"
        return 0
    fi
    [[ "$b" == "$BOOT_BASELINE" ]] || abort "#3 boot_id" "$1: the machine REBOOTED mid-round
        ($BOOT_BASELINE -> $b).  Cells either side of a reboot share no /proc baseline and no
        thread-id offsets; they are not one run."
    say "    boot_id unchanged"
}

# -------------------------------------------------------------------------------------------------
# PER-CELL CPU: a fabric-free baseline in the teardown gap, and a gate reading during the cell.
#
# Adam ruled 2026-08-31 that the desktop STAYS UP during the window.  That is a working point, not
# a defect -- but it means the gate's floor is ~0.5 cores of EXCESS over a ~0.84-core baseline, and
# the baseline itself swings ~0.19 cores over seconds.  Two things claw some discrimination back
# at no cost, and both are RECORDED rather than gated:
#
#   1. a fabric-free baseline PER CELL, taken in the gap teardown already creates;
#   2. claude-desktop / claude / gnome-shell CPU as NAMED covariates per cell.  They are our own
#      processes, so the cost is attributable rather than guessed -- without this, "did that cell
#      get worse because someone was using the desktop?" has no answer, and it will be asked.
#
# 🔴 THE TRAP, NAMED SO NOBODY "FIXES" IT BACK.  The per-cell baseline must NOT become the gate's
# baseline.  The gate judges excess over the ROUND-OPEN reference, which is what makes a drifting
# desktop show up as excess.  Re-baselining per cell would make each cell's drift the new normal,
# excess would stay near zero, and the gate would go green forever -- it would ABSORB exactly the
# drift it exists to catch.  So: reference = fixed, round-open, fabric-down.  Per-cell = covariate.
# -------------------------------------------------------------------------------------------------
# 🔴 C (reviewer, 08-31): the baseline's SOURCE is operator behaviour, so a single reading is a
# point sample of a moving quantity -- the real detection floor is not 0.5 cores, it is 0.5 plus
# that variation.  So the round-open reference is taken >=3 times and its RANGE recorded, and if
# the range approaches the threshold that fact is itself a result to disclose.
baseline_range_check() {   # $1 = baseline file written by --record-baseline (one JSON per line)
    "$PY_PROXY" - "$1" "$CPU_GATE_FOREIGN_CORES" <<'PYEOF'
import json, sys
vals = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        try: vals.append(json.loads(line)["baseline_cores"])
        except Exception: pass
thr = float(sys.argv[2])
if len(vals) < 3:
    print(f"BASELINE verdict=UNRUNNABLE only {len(vals)} reading(s); >=3 required"); raise SystemExit(2)
rng = max(vals) - min(vals)
print(f"BASELINE n={len(vals)} min={min(vals)} max={max(vals)} range={rng:.3f} threshold={thr}")
if rng >= thr:
    print("  🔴 THE BASELINE'S OWN RANGE MEETS OR EXCEEDS THE THRESHOLD.")
    print("     The gate cannot separate foreign load from baseline drift at this working point.")
    print("     PREREG §0-ter: this must be DISCLOSED in the result, not absorbed.")
    raise SystemExit(1)
if rng >= thr / 2:
    print(f"  ⚠️  range is {rng/thr:.0%} of the threshold -- disclose it alongside any 'no interference' claim.")
PYEOF
}

cell_baseline() {   # $1 = cell.  Call AFTER teardown, BEFORE bringup: the fabric must be down.
    local f="$OUT/cell_cpu/${1}_baseline.json"
    RUN mkdir -p "$OUT/cell_cpu"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would take a ${CELL_BASELINE_WINDOW}s FABRIC-FREE baseline into $f"
        dry_note "  (covariate only; the gate keeps judging against the round-open reference)"
        return 0
    fi
    "$PY_PROXY" "$HERE_LIB/cpu_gate.py" --label "baseline_$1" --record-baseline \
        --baseline-file "$f" --window "$CELL_BASELINE_WINDOW" >>"$LOG" 2>&1 || true
    local b ref
    b=$("$PY_PROXY" -c "import json;print(json.load(open('$f'))['baseline_cores'])" 2>/dev/null)
    ref=$("$PY_PROXY" -c "import json;print(json.load(open('$CPU_BASELINE_FILE'))['baseline_cores'])" 2>/dev/null)
    say "    cell baseline: ${b:-?} cores (round-open reference ${ref:-?}) -- covariate, not the gate's baseline"
}

# The gate reading DURING the cell.  §4 pins the round to exclusive CPU because the readout is a
# CPU plateau, but v0.2 registered no PER-CELL check -- only the §2 force tests.  A cell
# contaminated in the middle of a seven-hour ladder would otherwise be invisible.
CELL_GATE_PID=""; CELL_GATE_OUT=""
cell_cpu_gate_start() {   # $1 = cell
    CELL_GATE_OUT="$OUT/cell_cpu/${1}_gate.jsonl"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run cpu_gate alongside the cell -> $CELL_GATE_OUT"
        CELL_GATE_PID=""; return 0
    fi
    RUN mkdir -p "$OUT/cell_cpu"
    "$PY_PROXY" "$HERE_LIB/cpu_gate.py" --label "cell_$1" \
        --window "$(( DUR > 60 ? DUR - 30 : 30 ))" --threshold "$CPU_GATE_FOREIGN_CORES" \
        --baseline-file "$CPU_BASELINE_FILE" --out "$CELL_GATE_OUT" >>"$LOG" 2>&1 &
    CELL_GATE_PID=$!
}
cell_cpu_gate_finish() {   # $1 = cell
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would collect the cell's gate verdict; RED or UNREADABLE aborts the round"
        return 0
    fi
    [[ -n "${CELL_GATE_PID:-}" ]] && wait "$CELL_GATE_PID" 2>/dev/null
    local v cov
    v=$("$PY_PROXY" -c "
import json
try: r=json.loads(open('$CELL_GATE_OUT').read().strip().split(chr(10))[-1])
except Exception: print('UNREADABLE'); raise SystemExit
print('%s excess=%s' % (r['verdict'], r['excess_cores']))" 2>/dev/null)
    cov=$("$PY_PROXY" -c "
import json
try:
    r=json.loads(open('$CELL_GATE_OUT').read().strip().split(chr(10))[-1])
    print(' '.join('%s=%s'%(k,x) for k,x in r.get('covariates',{}).items()))
except Exception: print('')" 2>/dev/null)
    say "    cell CPU gate: ${v:-UNREADABLE}"
    say "    covariates:    ${cov:-<none>}"
    case "${v:-UNREADABLE}" in
        RED*) abort "§4 exclusive-CPU" "$1: foreign load exceeded the registered threshold DURING
        this cell.  The readout is a CPU plateau, so this cell measured a different machine from
        the others.  Attribution is in $CELL_GATE_OUT." ;;
        UNREADABLE*) abort "§4 exclusive-CPU" "$1: the cell's CPU gate produced no readable
        verdict.  Unreadable is not green." ;;
    esac
}

# -------------------------------------------------------------------------------------------------
# §4-bis -- IS THE RECOMPUTE LOOP ACTUALLY EXECUTING?  (blocking review finding, 2026-08-31)
#
# The round could prove the two binaries DIFFER (a gtest on the constant, red on one arm and green
# on the other).  Nothing proved the loop that READS that constant is ever entered on a live
# fabric.  A unit test proves a constant's value; it says nothing about whether its loop runs.
# Third instance of one family: the batching flag, PREREG-B's F1, and this.
#
# Counted, never inferred from CPU%: 1 Hz and "not running" both round to zero CPU, so a CPU-based
# check has no power between exactly the two states this exists to separate.
# -------------------------------------------------------------------------------------------------
assert_recompute_running() {   # $1 = cell, $2 = arm (1hz|1khz)
    local out="$OUT/recompute/${1}.jsonl"
    RUN mkdir -p "$OUT/recompute"
    if [[ "$DRY_RUN" == 1 ]]; then
        if [[ "$DRY_FAIL" == recompute ]]; then
            say "    RECOMPUTE $1 passes_per_s=0.000 verdict=NOT-RUNNING (forced)"
            abort "§4-bis" "$1: the path-recompute loop is NOT executing.
        A null on Q2 from this arm would mean 'the path never ran', not 'the period change bought
        nothing' -- opposite next actions, so the cell cannot be allowed to stand."
        fi
        dry_note "would count voluntary_ctxt_switches of the calFlowPathByQueried thread for"
        dry_note "  ${RECOMPUTE_WINDOW}s and require arm=$2 to be in band (1hz: 0.2-20/s, 1khz: >=100/s)"
        return 0
    fi
    local o rc
    o=$("$PY_PROXY" "$HERE_LIB/recompute_rate.py" --arm "$2" --label "$1" \
        --window "$RECOMPUTE_WINDOW" --klog "$KERNEL_DIR/.test_run/logs/kernel.log" \
        --out "$out" 2>&1); rc=$?
    say "    $(head -1 <<<"$o")"
    (( rc == 0 )) || abort "§4-bis" "$1 (arm $2): the recompute loop is not running as this arm requires.
$o
        A null on Q2 built on this cell would be unreadable: 'no effect' and 'never executed' are
        different findings with opposite next actions."
}

# The frozen cross-arm rule, applied once the ladder has both arms at a rung.
compare_recompute_arms() {   # $1 = 1khz jsonl, $2 = 1hz jsonl
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would apply the frozen cross-arm rule: khz/hz >= 10 else Q2 UNINTERPRETABLE"
        return 0
    fi
    local o rc; o=$("$PY_PROXY" "$HERE_LIB/recompute_rate.py" --compare "$1" "$2" 2>&1); rc=$?
    say "$o"
    (( rc == 0 )) || abort "§4-bis" "the two arms' recompute rates are not distinguishable.
        The treatment was not delivered, so Q2 is UNINTERPRETABLE -- NOT null.  Reporting
        'changing the period had no effect' from here would be reporting a treatment that
        never happened."
}

# -------------------------------------------------------------------------------------------------
# CELL ARCHIVING.
#
# measure.sh hardcodes its output directory (the 08-20 round's raw/) and cell_verdict.py reads
# that same directory through `from plot_figures import RAW`.  Neither is edited -- see round.env.
# So a cell is measured there and COPIED here, with a sha256 on both sides, because a copy whose
# fidelity is not checked is a second artefact that merely resembles the first.
# 🔴 raw/ is git-ignored on working branches and belongs on the audit-raw orphan branch; the
# pre-commit hook enforces it, and an uninstalled hook enforces nothing.
# -------------------------------------------------------------------------------------------------
archive_cell() {   # $1 = cell label
    local cell="$1" s suffix
    RUN mkdir -p "$OUT/cells"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would copy ${cell}_{cpu,twin}.jsonl ${cell}_client.json ${cell}_kernel.log from"
        dry_note "  $PRIOR_RAW -> $OUT/cells, and record sha256 on both sides in $OUT/cells/MANIFEST"
        return 0
    fi
    for suffix in cpu.jsonl twin.jsonl client.json server.log; do
        s="$PRIOR_RAW/${cell}_${suffix}"
        [[ -f "$s" ]] || continue
        cp -p "$s" "$OUT/cells/" && \
          printf '%s  %s  (src %s)\n' "$(sha256sum "$s" | cut -d' ' -f1)" \
                 "${cell}_${suffix}" "$s" >>"$OUT/cells/MANIFEST"
    done
    # The thread-id table and the CPU trace must come from the same boot or the identification is
    # a guess; the 08-20 round archived no kernel.log and can never resolve its tid offsets.
    cp -f "$KERNEL_DIR/.test_run/logs/kernel.log" "$OUT/cells/${cell}_kernel.log" 2>/dev/null \
        || say "    WARNING: no kernel.log to keep for $cell"
}
