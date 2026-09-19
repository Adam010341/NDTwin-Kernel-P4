#!/usr/bin/env bash
# Driver for the three-group telemetry round: six fabric generations, twelve ladder arms,
# twenty-seven sampling-error windows and three controls, in the order PREREG.md registered.
#
# THE ORDER IS THE DESIGN, not a convenience (PREREG 4.1):
#
#   G1 none         f64_a  f1024_a    + the sampling-error block, + the three controls
#   G2 cooperative  f64_a  f1024_a    + the sampling-error block
#   G3 link         f64_a  f1024_a    + the sampling-error block
#   G4 link         f1024_b f64_b
#   G5 cooperative  f1024_b f64_b
#   G6 none         f1024_b f64_b
#
# Group AND frame order are both mirrored, so each (group, frame) cell has one early and one late
# arm and each group has one early and one late fabric generation: a linear drift in machine state
# cannot line up with a group. Changing the group means rebuilding the fabric -- `--telemetry` is
# decided at bring-up -- so the two frame sizes share a generation. That is a cost trade, not a
# control, and PREREG 4.1 says so in the same words.
#
# Inside a generation the sampling-error block runs FIRST, before the ladders: the ladders drive
# the fabric into saturation and leave queues and flow-table state behind, and the error metric
# wants a clean low-load fabric.
#
# 🔴 WHAT THIS SCRIPT REFUSES TO START ON, and why each one is a refusal rather than a warning:
#   * p4_proxy/mininet/telemetry_override exists    -- a leftover would silently decide the group
#                                                      of every arm, and the arm would agree with
#                                                      itself when it checked
#   * p4_proxy/mininet/app_package_override exists  -- decides which fabric `ndt up p4` builds
#   * /tmp/ndtwin_link_telemetry.json exists        -- names a pid a teardown will signal, and
#                                                      makes `link_emitter.alive` answer about
#                                                      somebody else's emitter
#   * the lab is claimed by someone else, or declares a measurement
#
# 🔴 AND WHAT IT PUTS BACK, on every path including every abort (the order is live-p1/_common.sh's
# finish(), and it is not the obvious one):
#   1. `ndt down`;
#   2. telemetry_override REMOVED -- absent is `auto`, which is what a checkout should be left at;
#   3. host_count_override restored to the BYTES this round found (not the number: the file may
#      be commented, and rewriting it into a bare number is not a restore);
#   4. the claim released LAST, because `ndt release` refuses while the knob is still moved.
#
# Usage:
#   NDT_OWNER="..." ./drive_e.sh [--only G1..G6|C1|C2|C3] [--dry-run]
#
# Exit: 0 every arm produced a reading; 1 something was invalid or failed (the table at the end
#       names it); 2 refused before anything was started.
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${NDT_REPO:-$(cd "$HERE/../../.." && pwd)}"
NDT="$REPO/tools/test_workflow/ndt"
TELEMETRY_KNOB="$REPO/p4_proxy/mininet/telemetry_override"
APP_KNOB="$REPO/p4_proxy/mininet/app_package_override"
HOST_KNOB="$REPO/p4_proxy/mininet/host_count_override"
LT_MANIFEST="${LT_MANIFEST:-/tmp/ndtwin_link_telemetry.json}"

ONLY=""; DRY=0
while (( $# )); do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '1,52p' "$0"; exit 0 ;;
        *) echo "🔴 unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -n "$ONLY" ]]; then
    case "$ONLY" in
        G1|G2|G3|G4|G5|G6|C1|C2|C3) ;;
        *) echo "🔴 --only takes G1..G6 or C1|C2|C3, got '$ONLY'" >&2; exit 2 ;;
    esac
fi

HOSTS="${HOSTS:-4}"
SETTLE_S="${SETTLE_S:-20}"          # between arms, as 08-28's drive_p2.sh used
FABRIC_SETTLE_S="${FABRIC_SETTLE_S:-60}"
CLAIM_MINUTES="${CLAIM_MINUTES:-600}"
SE_RATES_PASS1="${SE_RATES_PASS1:-2 20 100}"
SE_RATES_PASS2="${SE_RATES_PASS2:-100 20 2}"
SE_RATES_PASS3="${SE_RATES_PASS3:-2 20 100}"
CTRL_RATES="${CTRL_RATES:-1 2 3 5 8 12}"    # C3's throwaway ladder: short, the gate is the point
CTRL_BURNERS="${CTRL_BURNERS:-4}"
WINDOW_GAP_S="${WINDOW_GAP_S:-3}"   # between sampling-error windows; 0 in the offline test
MEASURING_NOTE="P3-E three-group telemetry round (pps ceiling / sampling error / CPU)"
CLAIM_NOTE="P3-E three-group telemetry round"
: "${NDT_OWNER:=p3-E}"
export NDT_OWNER

RUN_ROOT="$HERE/raw"
STAMP="$(date -u '+%Y-%m-%dT%H%M%SZ')"
RUN="$RUN_ROOT/${STAMP}_${ONLY:-full}"

CLAIMED=0
HOST_KNOB_COPY=""
FAILURES=()
RESULTS=()

say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
bad()  { printf '   !! %s\n' "$*" >&2; }
die()  { bad "$*"; exit 2; }

# --- the plan, printed the same way whether or not it is executed --------------------------
# generations: <id>|<group>|<pass>|<frame order>|<sampling-error block?>
GENERATIONS=(
    "G1|none|a|64 1024|yes"
    "G2|cooperative|a|64 1024|yes"
    "G3|link|a|64 1024|yes"
    "G4|link|b|1024 64|no"
    "G5|cooperative|b|1024 64|no"
    "G6|none|b|1024 64|no"
)

print_plan() {
    printf 'owner               %s\n' "$NDT_OWNER"
    printf 'repo                %s\n' "$REPO"
    printf 'raw                 %s\n' "$RUN"
    printf 'hosts               %s   (ndt up p4 %s --telemetry <group>)\n' "$HOSTS" "$HOSTS"
    printf 'selection           %s\n' "${ONLY:-everything: C1 C2 C3 then G1..G6}"
    printf 'settle              %ss after bring-up, %ss between arms\n\n' "$FABRIC_SETTLE_S" "$SETTLE_S"
    printf 'controls (run once, inside G1, BEFORE any measurement arm -- PREREG 4.3):\n'
    printf '  C1  generator ceiling at 64 B frames    h1 -> h1 loopback, not through bmv2, 3 reps\n'
    printf '      requirement: >= 5x the highest 64 B pps this round measures through bmv2\n'
    printf '  C2  generator ceiling at 1024 B frames  same, -l 982, 3 reps\n'
    printf '  C3  the external gate has a positive control: two throwaway ladders (%s kpps),\n' "$CTRL_RATES"
    printf '      one clean and one with %s CPU burners from rung 4. external must step up, and\n' "$CTRL_BURNERS"
    printf '      the gate must reject the burner arm. If it does not fire, the round does not start.\n\n'
    printf 'generations:\n'
    local row id group pass frames block
    for row in "${GENERATIONS[@]}"; do
        IFS='|' read -r id group pass frames block <<<"$row"
        printf '  %-3s %-12s pass %s   arms: ' "$id" "$group" "$pass"
        local f
        for f in $frames; do printf '%s_f%s_%s  ' "$group" "$f" "$pass"; done
        if [[ "$block" == yes ]]; then
            printf '\n      + sampling-error block: 3 passes over the rates, middle one reversed\n'
            printf '        %s | %s | %s  Mbit/s, %ss each\n' \
                "$SE_RATES_PASS1" "$SE_RATES_PASS2" "$SE_RATES_PASS3" "${DUR_S:-8}"
        else
            printf '\n'
        fi
    done
    printf '\nteardown on EVERY path (including abort):\n'
    printf '  ndt down  ->  rm %s (absent = auto)  ->  restore %s bytes  ->  ndt release\n' \
        "$TELEMETRY_KNOB" "$HOST_KNOB"
}

if (( DRY )); then
    printf '### DRY RUN -- drive_e.sh   (nothing is started, no fabric is built, nothing is written)\n\n'
    print_plan
    printf '\nthe exact commands, per generation:\n'
    printf '  NDT_OWNER=%s %s claim %s "P3-E three-group telemetry round"\n' "$NDT_OWNER" "$NDT" "$CLAIM_MINUTES"
    printf '  NDT_OWNER=%s %s up p4 %s --telemetry <group>\n' "$NDT_OWNER" "$NDT" "$HOSTS"
    printf '  NDT_OWNER=%s %s/sample_error.sh --group <group> --rate <R> --window p<pass> --out <run>/<gen>/se_<group>_<R>M_p<pass>\n' "$NDT_OWNER" "$HERE"
    printf '  NDT_OWNER=%s %s/run_group_arm.sh --group <group> --frame <F> --arm <group>_f<F>_<pass> --out <run>/<gen>/<arm>\n' "$NDT_OWNER" "$HERE"
    printf '  NDT_OWNER=%s %s down\n' "$NDT_OWNER" "$NDT"
    printf '  rm -f %s ; restore %s ; NDT_OWNER=%s %s release\n' "$TELEMETRY_KNOB" "$HOST_KNOB" "$NDT_OWNER" "$NDT"
    printf '\nand then, offline:\n'
    printf '  %s/analyse.py --raw <run> --out <run>/summary.json\n' "$HERE"
    printf '  %s/plot.py --summary <run>/summary.json --out %s\n' "$HERE" "$HERE"
    printf '\nrefusals checked before anything starts:\n'
    for f in "$TELEMETRY_KNOB" "$APP_KNOB" "$LT_MANIFEST"; do
        printf '  %-70s %s\n' "$f" "$([[ -e "$f" ]] && echo 'PRESENT -- would refuse' || echo 'absent, good')"
    done
    printf '  lab.claim owner/measuring, and root reachable without a prompt\n'
    exit 0
fi

# --- refusals, before anything is touched ---------------------------------------------------
[[ -x "$NDT" ]] || die "no ndt at $NDT"
[[ -x "$HERE/run_group_arm.sh" ]] || die "no run_group_arm.sh beside this script"
[[ -x "$HERE/sample_error.sh" ]]  || die "no sample_error.sh beside this script"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo -n true 2>/dev/null \
        || { sudo -n -l /usr/local/sbin/ndtwin-lab >/dev/null 2>&1 \
             && sudo -n -l /usr/bin/mnexec >/dev/null 2>&1; } \
        || die "this needs root without a prompt: the sudoers grants ndtwin-lab and mnexec"
fi

# 🔴 Three files that would each silently decide what this round measured. A leftover
# telemetry_override is the worst of them, because every arm's own group check would read it
# back and agree.
for f in "$TELEMETRY_KNOB" "$APP_KNOB" "$LT_MANIFEST"; do
    [[ -e "$f" ]] && die "refusing: $f exists. It is a leftover from a previous round and it
       decides what this one would measure. Nothing was started. Remove it deliberately
       (and for the manifest, check no emitter is still running) and run this again."
done

CLAIM_FILE="$REPO/.test_run/lab.claim"
if [[ -f "$CLAIM_FILE" ]]; then
    c_owner="$(sed -n 's/^owner=//p' "$CLAIM_FILE" | head -1)"
    c_expires="$(sed -n 's/^expires=//p' "$CLAIM_FILE" | head -1)"
    c_measuring="$(sed -n 's/^measuring=//p' "$CLAIM_FILE" | head -1)"
    now="$(date +%s)"
    if [[ "$c_expires" =~ ^[0-9]+$ ]] && (( c_expires > now )); then
        [[ "$c_owner" == "$NDT_OWNER" ]] \
            || die "refusing: the lab is claimed by '$c_owner' until $(date -d "@$c_expires" '+%H:%M:%S')"
        [[ -z "$c_measuring" ]] \
            || die "refusing: the live claim declares measuring=$c_measuring"
    fi
fi

mkdir -p "$RUN" || die "cannot create $RUN"
printf '### P3-E three-group telemetry round  %s\n' "$(date -u '+%F %T UTC')" | tee "$RUN/driver.log"
print_plan | tee -a "$RUN/driver.log"

# --- teardown, on every path -----------------------------------------------------------------
snapshot_host_knob() {
    HOST_KNOB_COPY="$RUN/00_host_count_override.entry"
    if [[ -e "$HOST_KNOB" ]]; then
        cp -p "$HOST_KNOB" "$HOST_KNOB_COPY"
        note "host_count_override snapshot taken"
    else
        HOST_KNOB_COPY="(absent)"
        note "host_count_override does not exist; it will be removed again at the end"
    fi
}
restore_host_knob() {
    [[ -n "$HOST_KNOB_COPY" ]] || return 0
    if [[ "$HOST_KNOB_COPY" == "(absent)" ]]; then rm -f "$HOST_KNOB"; return 0; fi
    cmp -s "$HOST_KNOB_COPY" "$HOST_KNOB" 2>/dev/null && return 0
    cp -p "$HOST_KNOB_COPY" "$HOST_KNOB" || { bad "could NOT put host_count_override back"; return 1; }
    note "host_count_override put back to the bytes this round found"
}

# 🔴 `ndt down` REFUSES (rc 5) WHILE THE CLAIM DECLARES A MEASUREMENT, and this driver is what
# declares one. The first real run proved it: raw/2026-09-19T062206Z_full/90_down.txt is the
# refusal, not a teardown -- "refusing to tear down: this claim DECLARES a measurement in
# progress ... when that run is over: ndt claim <mins> to redeclare, or ndt down --force". So
# the round that was supposed to leave the lab clean left the fabric up.
#
# The fix is NOT --force. --force also skips the in_flight process check, which is the reading
# that can still tell the truth about whether something is running; a script that forces past a
# guard on every path has removed the guard. The declaration is THIS driver's own statement, and
# the driver is the one thing that knows when its arms are finished -- so it RETRACTS the
# statement the way ndt itself suggests (re-claim without NDT_MEASURING), and then runs an
# ordinary `ndt down` that still refuses if a real process is in flight.
#
# If the down still refuses after the retraction, that refusal is about something else and is
# reported as a failure with the command to run by hand. It is never overridden here.
declare_measuring() {   # declare_measuring on|off
    local want="$1"
    local rc=0
    if [[ "$want" == on ]]; then
        NDT_MEASURING="$MEASURING_NOTE" "$NDT" claim "$CLAIM_MINUTES" "$CLAIM_NOTE" >/dev/null 2>&1
        rc=$?
    else
        # no NDT_MEASURING in this command's environment => the claim is rewritten with the
        # field empty, which is the retraction.
        "$NDT" claim "$CLAIM_MINUTES" "$CLAIM_NOTE (arms finished)" >/dev/null 2>&1
        rc=$?
    fi
    (( rc == 0 )) || bad "could not set measuring=$want on the claim (ndt claim rc=$rc)"
    return "$rc"
}

teardown_fabric() {   # teardown_fabric <log path> <label>
    local log="$1"
    local label="$2"
    local rc=0
    declare_measuring off || true
    "$NDT" down > "$log" 2>&1
    rc=$?
    note "$label: ndt down rc=$rc"
    if (( rc == 5 )); then
        bad "$label: 'ndt down' still REFUSED after the measuring declaration was retracted."
        bad "  That refusal is about something else -- read $log. It is not overridden here."
        bad "  If you have checked that nothing is running:  NDT_OWNER=$NDT_OWNER $NDT down --force"
        FAILURES+=("$label: 'ndt down' refused (rc 5) -- see $log; the fabric may still be up")
    fi
    return "$rc"
}

finish() {
    local rc=$?
    trap - EXIT INT TERM
    say "teardown"
    if (( CLAIMED )); then
        teardown_fabric "$RUN/90_down.txt" "final"
        tail -3 "$RUN/90_down.txt" | sed 's/^/     /'
    fi
    # `ndt down` deliberately does not touch telemetry_override (TICKET-P3 2.1), so this does.
    # Absent IS `auto`: removing it is what leaves the checkout where it should be, and writing
    # the word `auto` into it would leave a file that says the same thing louder.
    if [[ -e "$TELEMETRY_KNOB" ]]; then
        rm -f "$TELEMETRY_KNOB" && note "telemetry_override removed (absent = auto)" \
            || bad "could NOT remove $TELEMETRY_KNOB -- the next 'ndt up p4' reads it"
    fi
    [[ -e "$APP_KNOB" ]] && bad "app_package_override SURVIVED the teardown -- the next 'ndt up p4' reads it"
    restore_host_knob || true
    if (( CLAIMED )); then
        # 🔴 THE ROUND BASELINE HAS TO BE RE-RECORDED FROM THE RESTORED KNOB, OR THE RELEASE
        # REFUSES. Every `ndt claim` runs record_round_baseline, which snapshots the knob AS IT
        # IS AT THAT MOMENT (ndt:844 -> :442-455). This driver re-claims once per generation to
        # declare and retract `measuring=`, and those claims happen AFTER `ndt up p4 4` has
        # rewritten the knob to 4 -- so the round's recorded starting point silently becomes 4.
        # cmd_release then compares that baseline against the knob it finds (ndt:885-894) and,
        # when this checkout's entry value is not 4, refuses with rc 1 and KEEPS THE CLAIM.
        #
        # It is dormant only because the entry value here is also 4. One `git checkout --
        # p4_proxy/mininet/host_count_override` in the main checkout lights it, and then the
        # round ends with the lab still claimed. (Ruling 22(2), introduced by last round's fix.)
        #
        # One more claim, after the restore, makes the baseline agree with the bytes that are
        # actually on disk -- which is what the release is entitled to compare against.
        declare_measuring off || true
        local release_log="$RUN/95_release.txt"
        "$NDT" release > "$release_log" 2>&1
        local release_rc=$?
        sed 's/^/   /' "$release_log"
        # 🔴 AND THE rc IS READ. This was `"$NDT" release 2>&1 | sed ... || bad ...`, where the
        # `||` tests SED's status and can never see the release refuse: the round printed the
        # refusal, called itself a PASS, and left the claim on the lab.
        if (( release_rc != 0 )); then
            bad "'ndt release' refused (rc $release_rc) -- THE LAB IS STILL CLAIMED. Read $release_log."
            FAILURES+=("final: 'ndt release' refused (rc $release_rc) -- the lab is still claimed; see 95_release.txt")
        fi
    fi
    printf '\n'
    if (( ${#RESULTS[@]} )); then
        printf '%-28s %-12s %-10s %s\n' arm group clean_kpps verdict
        printf '%s\n' "${RESULTS[@]}"
    fi
    printf 'raw: %s\n' "$RUN"
    if (( ${#FAILURES[@]} )); then
        printf 'FAIL P3-E -- %d problem(s):\n' "${#FAILURES[@]}"
        printf '  %s\n' "${FAILURES[@]}"
        exit 1
    fi
    (( rc == 0 )) || { printf 'FAIL P3-E -- the driver exited %d before its own verdict\n' "$rc"; exit 1; }
    printf 'PASS P3-E -- every selected arm produced a reading. Now: analyse.py, then plot.py.\n'
    exit 0
}

snapshot_host_knob
trap finish EXIT INT TERM

say "claiming the lab"
NDT_MEASURING="$MEASURING_NOTE" \
    "$NDT" claim "$CLAIM_MINUTES" "$CLAIM_NOTE" 2>&1 | sed 's/^/   /' \
    || die "'ndt claim' would not take. Nothing was started."
CLAIMED=1

# --- the pieces --------------------------------------------------------------------------
fabric_up() {   # fabric_up <group> <gen id>
    local group="$1"
    local gen="$2"
    declare_measuring on || true
    say "$gen: ndt up p4 $HOSTS --telemetry $group"
    if ! "$NDT" up p4 "$HOSTS" --telemetry "$group" > "$RUN/$gen/10_up.txt" 2>&1; then
        tail -20 "$RUN/$gen/10_up.txt" | sed 's/^/     /'
        FAILURES+=("$gen: 'ndt up p4 $HOSTS --telemetry $group' failed -- see $gen/10_up.txt")
        return 1
    fi
    tail -3 "$RUN/$gen/10_up.txt" | sed 's/^/     /'
    note "settling ${FABRIC_SETTLE_S}s"
    sleep "$FABRIC_SETTLE_S"
    verify_generation "$group" "$gen"
}

# 🔴 `ndt verify_p4` IS NOT A SUBCOMMAND. It was never one: `ndt`'s dispatch is up/down/status/
# check/clean/apps/ntg/claim/release, and an unknown word prints the usage text and exits 2. The
# round's first generation recorded that usage text as its verification (ruling 21(1)), and rc 2
# went unread because the call was not tested -- a check that cannot fail is not a check.
#
# What replaces it is TWO readings, and they are deliberately not given the same authority:
#
#   HARD GATE -- `ndt up`'s own [3/3] block, parsed out of 10_up.txt. It is the only thing on
#     this machine that asserts the telemetry source PER SWITCH at bring-up ("telemetry: none --
#     0 cooperative, 0 link, 10 none; the proxy agrees switch by switch"), and the group is what
#     every number in this round is indexed by. Its exact wording is not guessed: it is copied
#     from the generation that really ran, raw/2026-09-19T062206Z_full/G1/10_up.txt lines 26-29.
#
#   RECORDED, NOT GATING -- `ndt status --check`, which IS the standalone re-check that exists
#     (it compares the live lab against .test_run/up.target: plane, host count, kernel graph,
#     model sha256; rc 0 match, 1 mismatch, 3 nothing compared). Its rc and its whole report go
#     into 11_verify.txt and into the log, and rc 3 is written down as "nothing was compared",
#     never as a pass -- but it does not fail the generation, because I have never seen its
#     output against a `--telemetry` fabric and turning an unverified expectation into a hard
#     gate is the exact mistake that produced ruling 21(1) in the first place.
#
# The group is proved again per arm and per window from /p4/switch_state (PREREG 2), so this is
# the generation-level belt to that pair of braces, not the only reading of it.
verify_generation() {   # verify_generation <group> <gen id>
    local group="$1"
    local gen="$2"
    local up_log="$RUN/$gen/10_up.txt"
    local out="$RUN/$gen/11_verify.txt"
    local rc=0
    local line=""

    {
        echo "### generation $gen -- the [3/3] block ndt up printed (hard gate)"
        /usr/bin/grep -nE "^[[:space:]]*(ok|XX)[[:space:]]+(kernel|telemetry|data plane|model)" \
            "$up_log" 2>/dev/null || echo "(no [3/3] lines found in $up_log)"
    } > "$out"

    line="$(/usr/bin/grep -oE "ok[[:space:]]+telemetry: [a-z]+ --.*" "$up_log" 2>/dev/null | head -1)"
    if [[ -z "$line" ]]; then
        FAILURES+=("$gen: 'ndt up' printed no 'ok telemetry:' line -- the group was never asserted at bring-up")
        rc=1
    elif [[ "$line" != *"telemetry: $group --"* ]]; then
        FAILURES+=("$gen: bring-up asserted a telemetry source that is not '$group': $line")
        rc=1
    elif [[ "$line" != *"the proxy agrees switch by switch"* ]]; then
        FAILURES+=("$gen: bring-up did not say the proxy agrees switch by switch: $line")
        rc=1
    else
        note "$gen: $line"
    fi
    /usr/bin/grep -qE "^[[:space:]]*ok[[:space:]]+data plane: .* forwards" "$up_log" 2>/dev/null \
        || { FAILURES+=("$gen: bring-up did not report the data plane forwarding"); rc=1; }

    # the standalone re-check that really exists -- recorded, never silently believed
    {
        echo
        echo "### ndt status --check   (rc 0 all compared fields match; 1 a mismatch; 3 NOTHING was compared)"
    } >> "$out"
    "$NDT" status --check >> "$out" 2>&1
    local check_rc=$?
    case "$check_rc" in
        0) note "$gen: ndt status --check rc=0 (the live lab matches .test_run/up.target)" ;;
        1)
            # 🔴 rc 1 IS A VERDICT, AND IT IS ndt's, NOT A GUESS OF MINE. Its own words are
            # "compared against the last 'ndt up': dataplane, fabric hosts, kernel graph,
            # topology file" and, when any of those differ, "check: N problem(s)" with the list
            # (ndt:6468-6475). The problems it can name include a dead data plane, a host count
            # that is not the one the round asked for, a kernel graph that no longer matches, a
            # changed model sha256, a DEAD link-telemetry emitter and a stale pipeline -- every
            # one of which makes this generation's numbers something other than what their group
            # label says. Ruling 22(1): that cannot sit in the same run as `PASS P3-E`.
            #
            # It does NOT skip the generation. The arms still run and still write their raw,
            # because a cell that was measured under a named problem is evidence about that
            # problem; what is forbidden is the round calling itself a pass over it. So it goes
            # into FAILURES (which decides the verdict) and the return value is untouched.
            bad "$gen: ndt status --check rc=1 -- ndt compared the live lab against .test_run/up.target and found a problem"
            /usr/bin/grep -E "^[[:space:]]*- " "$out" | tail -8 | sed 's/^/       /' >&2
            FAILURES+=("$gen: 'ndt status --check' rc=1 -- see $gen/11_verify.txt; the arms of this generation ran under it")
            ;;
        3) note "$gen: ⚠️  ndt status --check rc=3 -- NOTHING was compared (no up.target baseline). Not a pass, not a failure." ;;
        *) note "$gen: ⚠️  ndt status --check rc=$check_rc -- read $gen/11_verify.txt; recorded, not gating." ;;
    esac
    echo "status_check_rc=$check_rc" >> "$out"
    return "$rc"
}

fabric_down() {   # fabric_down <gen id>
    local gen="$1"
    # Between generations the arms really are finished -- the last one returned and the driver
    # slept -- so retracting the declaration here is true, and it is re-declared at the next
    # generation's bring-up.
    teardown_fabric "$RUN/$gen/99_down.txt" "$gen"
    rm -f "$TELEMETRY_KNOB"
    sleep "$SETTLE_S"
}

ladder_arm() {   # ladder_arm <group> <frame> <arm label> <gen id> [extra env assignments...]
    local group="$1" frame="$2" arm="$3" gen="$4"
    say "$gen: ladder arm $arm  (group $group, frame ${frame}B)"
    "$HERE/run_group_arm.sh" --group "$group" --frame "$frame" --arm "$arm" \
        --out "$RUN/$gen/$arm" 2>&1 | tee "$RUN/$gen/${arm}.log"
    local rc="${PIPESTATUS[0]}"
    local clean invalid
    clean="$(sed -n 's/^highest_clean_kpps=//p' "$RUN/$gen/$arm/arm.meta" 2>/dev/null | head -1)"
    invalid="$(sed -n 's/^invalid=//p' "$RUN/$gen/$arm/arm.meta" 2>/dev/null | head -1)"
    RESULTS+=("$(printf '%-28s %-12s %-10s %s' "$arm" "$group" "${clean:-none}" \
        "$( [[ "${invalid:-no}" == no ]] && echo ok || echo "INVALID: $invalid" )")")
    (( rc == 0 )) || FAILURES+=("$gen/$arm: ${invalid:-run_group_arm.sh exited $rc}")
    sleep "$SETTLE_S"
}

sampling_block() {   # sampling_block <group> <gen id>
    local group="$1" gen="$2" pass=0 rate n
    say "$gen: sampling-error block (group $group) -- 3 passes, the middle one reversed"
    for rates in "$SE_RATES_PASS1" "$SE_RATES_PASS2" "$SE_RATES_PASS3"; do
        pass=$((pass + 1))
        for rate in $rates; do
            n="p${pass}"
            "$HERE/sample_error.sh" --group "$group" --rate "$rate" --window "$n" \
                --out "$RUN/$gen/se_${group}_${rate}M_${n}" 2>&1 \
                | tee -a "$RUN/$gen/sampling_error.log"
            local rc="${PIPESTATUS[0]}"
            (( rc == 0 )) || FAILURES+=("$gen: sampling-error window ${group} ${rate}M ${n} is invalid")
            sleep "$WINDOW_GAP_S"
        done
    done
}

# --- C1 / C2: the generator's own ceiling, per frame size (PREREG 4.3) ----------------------
# 🔴 NOT INHERITED from 08-28's 770.7 kpps, and not shared between the two frame sizes: 1b
# section 3 made that rule explicit after 2's control was proposed for a 1400 B round. Small
# packets are bound by per-packet cost and large ones by bandwidth, so one says nothing about
# the other -- and neither says anything about this machine three weeks later.
sender_control() {   # sender_control <C1|C2> <frame>
    # 🔴 ONE NAME PER `local`, AND NOTHING ON THAT LINE READS ANOTHER OF THEM. This line used to
    # be `local id="$1" frame="$2" payload=$((frame - 42)) out="$RUN/controls/$id"`, and under
    # `set -u` that is `frame: unbound variable`: bash expands every right-hand side on a `local`
    # line BEFORE it assigns any of them, so `frame` is still unset when `$((frame - 42))` reads
    # it. It killed the round's first generation (ruling 21(2)), and it is the same shape D found
    # in live-p1/05 and 06 (ruling 9 / 12d). The dry-run could not see it because the dry-run
    # never enters a generation -- which is why test_drive_e_offline.sh now does.
    local id="$1"
    local frame="$2"
    local payload
    local out
    payload=$((frame - 42))
    out="$RUN/controls/$id"
    mkdir -p "$out"
    say "$id: generator ceiling at ${frame}B frames (h1 -> h1 loopback, not through bmv2)"
    local src_pid rep best=0
    src_pid="$(ps -eo pid,args | awk '$NF=="mininet:h1"{print $1; exit}')"
    [[ -n "$src_pid" ]] || { FAILURES+=("$id: no h1 namespace"); return 1; }
    for rep in 1 2 3; do
        local port=$((5801 + rep))
        sudo -n mnexec -a "$src_pid" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
        sleep 1
        sudo -n mnexec -a "$src_pid" iperf3 -c 10.0.0.1 -p "$port" -u -b 0 -t 8 -l "$payload" \
            --json > "$out/rep${rep}.json" 2>&1
        local pps
        pps="$(python3 - "$out/rep${rep}.json" <<'PY'
import json, sys
try:
    sent = json.load(open(sys.argv[1]))["end"]["sum_sent"]
    print("%.1f" % (sent["packets"] / sent["seconds"]))
except Exception:
    print("-1")
PY
)"
        note "  rep $rep: $pps pps"
        echo "$pps" >> "$out/pps.txt"
        awk -v a="$pps" -v b="$best" 'BEGIN{exit !(a > b)}' && best="$pps"
    done
    {
        echo "control=$id"
        echo "frame_bytes=$frame"
        echo "payload_bytes=$payload"
        echo "reps_pps=$(tr '\n' ' ' < "$out/pps.txt")"
        echo "ceiling_pps=$best"
        echo "requirement=>= 5x the highest ${frame}B pps this round measures through bmv2 (PREREG 4.3)"
        echo "verdict=computed by analyse.py once the ${frame}B cells exist"
    } > "$out/control.meta"
    note "  ceiling ${best} pps -- the 5x requirement is checked by analyse.py against the measured cells"
}

# --- C3: the external gate's positive control (PREREG 4.3, 6.3) -----------------------------
# 🔴 A GATE THAT HAS NEVER BEEN SEEN TO FIRE HAS NOT BEEN DELIVERED. 08-28 replaced a gate that
# fired on the treatment with one that had a positive control, and required the control BEFORE
# the round. Two short throwaway ladders, identical except for the burners, so the step in
# `external` is attributable to them and to nothing else.
gate_control() {
    local out="$RUN/controls/C3"
    mkdir -p "$out"
    say "C3: the external gate's positive control -- two throwaway ladders, one with burners"
    RATES_KPPS="$CTRL_RATES" BURNERS=0 \
        "$HERE/run_group_arm.sh" --group none --frame 1024 --arm c3a_noburn \
        --out "$out/c3a_noburn" > "$out/c3a.log" 2>&1
    RATES_KPPS="$CTRL_RATES" BURNERS="$CTRL_BURNERS" \
        "$HERE/run_group_arm.sh" --group none --frame 1024 --arm c3b_burn \
        --out "$out/c3b_burn" > "$out/c3b.log" 2>&1
    local clean burn
    clean="$(sed -n 's/^external=//p' "$out/c3a_noburn/arm.meta" 2>/dev/null | head -1)"
    burn="$(sed -n 's/^external=//p' "$out/c3b_burn/arm.meta" 2>/dev/null | head -1)"
    {
        echo "control=C3"
        echo "burners=$CTRL_BURNERS"
        echo "ladder=$CTRL_RATES"
        echo "external_without_burners=${clean:-none}"
        echo "external_with_burners=${burn:-none}"
        echo "threshold=+0.15 absolute (PREREG 6.2)"
    } > "$out/control.meta"
    if [[ -z "$clean" || -z "$burn" ]]; then
        FAILURES+=("C3: the gate's positive control produced no external figure -- the gate is UNVALIDATED and PREREG 6.3 says the round does not start")
        echo "verdict=NO READING -- gate unvalidated" >> "$out/control.meta"
        return 1
    fi
    if awk -v a="$burn" -v b="$clean" 'BEGIN{exit !(a - b > 0.15)}'; then
        note "  external $clean -> $burn with $CTRL_BURNERS burners: the gate fires (+$(awk -v a="$burn" -v b="$clean" 'BEGIN{printf "%.4f", a-b}'))"
        echo "verdict=FIRES" >> "$out/control.meta"
        return 0
    fi
    FAILURES+=("C3: external moved only $clean -> $burn with $CTRL_BURNERS burners; the gate did NOT fire, so it is UNVALIDATED and PREREG 6.3 says the round does not start")
    echo "verdict=DID NOT FIRE -- gate unvalidated" >> "$out/control.meta"
    return 1
}

# --- the run ----------------------------------------------------------------------------------
run_generation() {   # run_generation <row>
    local id group pass frames block
    IFS='|' read -r id group pass frames block <<<"$1"
    mkdir -p "$RUN/$id"
    fabric_up "$group" "$id" || { fabric_down "$id"; return 1; }
    if [[ "$id" == "G1" && -z "$ONLY" ]]; then
        sender_control C1 64
        sender_control C2 1024
        if ! gate_control; then
            bad "the external gate's positive control did not fire -- PREREG 6.3: the round does not start"
            fabric_down "$id"
            return 1
        fi
    fi
    [[ "$block" == yes ]] && sampling_block "$group" "$id"
    local frame
    for frame in $frames; do
        ladder_arm "$group" "$frame" "${group}_f${frame}_${pass}" "$id"
    done
    fabric_down "$id"
}

if [[ -n "$ONLY" ]]; then
    case "$ONLY" in
        G*)
            for row in "${GENERATIONS[@]}"; do
                [[ "${row%%|*}" == "$ONLY" ]] && run_generation "$row"
            done ;;
        C1|C2|C3)
            mkdir -p "$RUN/controls"
            fabric_up none controls || { fabric_down controls; }
            case "$ONLY" in
                C1) sender_control C1 64 ;;
                C2) sender_control C2 1024 ;;
                C3) gate_control || true ;;
            esac
            fabric_down controls ;;
    esac
else
    for row in "${GENERATIONS[@]}"; do
        run_generation "$row" || bad "${row%%|*} did not complete; continuing with the next generation"
    done
fi

say "arms complete"
note "next, offline:  $HERE/analyse.py --raw $RUN --out $RUN/summary.json"
note "then:           $HERE/plot.py --summary $RUN/summary.json --out $HERE"
exit 0
