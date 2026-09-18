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

finish() {
    local rc=$?
    trap - EXIT INT TERM
    say "teardown"
    if (( CLAIMED )); then
        "$NDT" down > "$RUN/90_down.txt" 2>&1
        note "ndt down rc=$? -> 90_down.txt"
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
        "$NDT" release 2>&1 | sed 's/^/   /' || bad "'ndt release' did not take -- run it by hand"
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
NDT_MEASURING="P3-E three-group telemetry round (pps ceiling / sampling error / CPU)" \
    "$NDT" claim "$CLAIM_MINUTES" "P3-E three-group telemetry round" 2>&1 | sed 's/^/   /' \
    || die "'ndt claim' would not take. Nothing was started."
CLAIMED=1

# --- the pieces --------------------------------------------------------------------------
fabric_up() {   # fabric_up <group> <gen id>
    local group="$1" gen="$2"
    say "$gen: ndt up p4 $HOSTS --telemetry $group"
    if ! "$NDT" up p4 "$HOSTS" --telemetry "$group" > "$RUN/$gen/10_up.txt" 2>&1; then
        tail -20 "$RUN/$gen/10_up.txt" | sed 's/^/     /'
        FAILURES+=("$gen: 'ndt up p4 $HOSTS --telemetry $group' failed -- see $gen/10_up.txt")
        return 1
    fi
    tail -3 "$RUN/$gen/10_up.txt" | sed 's/^/     /'
    note "settling ${FABRIC_SETTLE_S}s"
    sleep "$FABRIC_SETTLE_S"
    "$NDT" verify_p4 > "$RUN/$gen/11_verify.txt" 2>&1
    note "ndt verify_p4 rc=$? -> $gen/11_verify.txt"
    return 0
}

fabric_down() {   # fabric_down <gen id>
    local gen="$1"
    "$NDT" down > "$RUN/$gen/99_down.txt" 2>&1
    note "$gen: ndt down rc=$?"
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
            sleep 3
        done
    done
}

# --- C1 / C2: the generator's own ceiling, per frame size (PREREG 4.3) ----------------------
# 🔴 NOT INHERITED from 08-28's 770.7 kpps, and not shared between the two frame sizes: 1b
# section 3 made that rule explicit after 2's control was proposed for a 1400 B round. Small
# packets are bound by per-packet cost and large ones by bandwidth, so one says nothing about
# the other -- and neither says anything about this machine three weeks later.
sender_control() {   # sender_control <C1|C2> <frame>
    local id="$1" frame="$2" payload=$((frame - 42)) out="$RUN/controls/$id"
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
