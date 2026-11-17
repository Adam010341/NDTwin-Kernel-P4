#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_ping.sh (`ndt ping`).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation takes away one decision `ndt ping` makes -- a bound on its arguments, a name resolved
# only from the recorded model, a guard that refuses before anything starts, the rule that a loss
# figure comes only from ping's own summary, the exit-code order, the background start, the bounded
# wait, where the files go, the way in -- and must turn its NAMED check red. A mutation caught by some
# other check says nothing about the check that was supposed to own it.
#
# 🔴 Mutations are applied to COPIES in a temp dir and the suite is pointed at them with
#    NDT_UNDER_TEST; tools/test_workflow/ndt is never written, and its sha256 is compared at the end.
#    The suite copies the ndt under test into a scratch tree of its own, with the three files beside
#    it, so each mutant dir carries those too.
# 🔴 A mutation that will not apply, a non-unique anchor, or the wrong check going red counts as a
#    SURVIVOR. A comment-only edit is the control and must stay green.
# 🔴 Touches no lab: the suite's sudo is a fake (see its header).
#
# Env:  MUTANT_EVIDENCE=<dir>  keeps each mutant as <label>.patch and the suite's output as <label>.log.
# Exit: 0 every mutation caught and the control stayed green, 1 a mutation survived (or the control
#       went red), 2 refused (baseline red / harness), 3 ndt changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
README="$REPO/examples/p4_energy_saving/README.md"
GUIDE="$REPO/doc/2026-11-05_user-guide.md"
SH_TEST="$HERE/test_ndt_ping.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-ping-mutate-XXXXXX")
trap 'rm -rf "${BK:?}"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$SH_TEST" ]] || { echo "🔴 missing $NDT or $SH_TEST" >&2; exit 2; }

SURVIVORS=0
MUTATIONS=0

run_sh() { (cd "$1" && NDT_UNDER_TEST="$1/tools/test_workflow/ndt" timeout 300 bash "$SH_TEST" 2>&1); }

tree() {   # <dir> -- ndt and the three files it sources or reads from beside itself, and the docs
    mkdir -p "$1/tools/test_workflow" "$1/doc" "$1/examples/p4_energy_saving"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
       "$REPO/tools/test_workflow/components.env" "$REPO/tools/test_workflow/ndtwin-lab" "$1/tools/test_workflow/"
    cp "$REPO/doc/2026-11-05_user-guide.md" "$REPO/doc/2026-10-31_p4-app-guide.md" "$1/doc/"
    cp "$REPO/examples/p4_energy_saving/README.md" "$1/examples/p4_energy_saving/"
    chmod +x "$1/tools/test_workflow/ndt"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the check that must fail (a prefix of its name)
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -f "$2/tools/test_workflow/ndt" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (the mutant was not built)\n' "$1"; return
    fi
    out=$(run_sh "$2"); rc=$?
    if [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        { printf '%s\nthe check that must fail: %s\n\n' "$1" "$3"; printf '%s\n' "$out"; echo "exit code: $rc"; } \
            > "$MUTANT_EVIDENCE/$(basename "$2").log"
    fi
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that check proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

control() {   # $1 = name, $2 = mutant dir -- must NOT turn the suite red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ -f "$2/tools/test_workflow/ndt" && "$rc" -eq 0 ]]; then
        printf '  survived %-58s (control, as required)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 CONTROL WENT RED %-47s\n' "$1"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    tree "$d"
    local target="$d/${file#"$REPO"/}"
    if ! python3 - "$target" "$old" "$new" <<'PY' >&2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        rm -f "$d/tools/test_workflow/ndt"     # not built: `report` counts it as a survivor
    elif [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        mkdir -p "$MUTANT_EVIDENCE"
        diff -u --label "a/${file#"$REPO"/}" --label "b/${file#"$REPO"/}" "$file" "$target" \
            > "$MUTANT_EVIDENCE/$label.patch"
    fi
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; tree "$base"
run_sh "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- P1: arguments -----------------------------------------------------------------------------
m=$(mutant p1a "$NDT" '    if (( PING_FOR_S < 1 || PING_FOR_S > 600 )); then' '    if (( PING_FOR_S < 1 || PING_FOR_S > 6000 )); then')
report "P1a: --for has no 600 s ceiling" "$m" "'ndt ping h1:h3 --for 601s' -> 2"

m=$(mutant p1b "$NDT" 'NDT_PING_MAX_STREAMS=32' 'NDT_PING_MAX_STREAMS=64')
report "P1b: more than 32 streams are accepted" "$m" "33 streams -> 2"

m=$(mutant p1c "$NDT" '        if [[ -z "$word" || "$word" == ,* || "$word" == *, || "$word" == *,,* ]]; then' '        if [[ -z "$word" ]]; then')
report "P1c: an empty pair after a comma is dropped silently" "$m" "'ndt ping h1:h3,' -> 2"

# The count is clamped so that count x interval stays within the helper's 600 s.
m=$(mutant p1d "$NDT" '    (( PING_COUNT * PING_INTERVAL_MS <= 600000 )) || PING_COUNT=$(( 600000 / PING_INTERVAL_MS ))' '    :')
report "P1d: the count is not clamped to 600 s (rounding gives 86 pings at 7 s)" "$m" "--for 600 --interval 7 -> 85 pings, never more than 600 s of them"

m=$(mutant p1e "$NDT" '    (( PING_COUNT * PING_INTERVAL_MS <= 600000 )) || PING_COUNT=$(( 600000 / PING_INTERVAL_MS ))' '    (( PING_COUNT * PING_INTERVAL_MS <= 600000 )) || PING_COUNT=$(( 600000 / PING_INTERVAL_MS + 1 ))')
report "P1e: the clamp rounds up and still passes 600 s" "$m" "--for 10m --interval 0.9 -> 666 pings, never more than 600 s of them"

m=$(mutant p1f "$NDT" '    (( PING_COUNT * PING_INTERVAL_MS <= 600000 )) || PING_COUNT=$(( 600000 / PING_INTERVAL_MS ))' '    (( PING_COUNT * PING_INTERVAL_MS <= 601000 )) || PING_COUNT=$(( 601000 / PING_INTERVAL_MS ))')
report "P1f: the clamp's bound drifts from the helper's (601 s)" "$m" "every count ndt computes for --for 595-600 (96 combinations) is accepted by the helper's own checks"

# --- P2: names ---------------------------------------------------------------------------------
m=$(mutant p2a "$NDT" '        elif (( rc == 1 )); then
            err "no '"'"'ndt up'"'"' record in this checkout, so ${PING_DST[$i]} has no address here: give the address (${PING_SRC[$i]}:10.0.3.3)"
            return 2' '        elif (( rc == 1 )); then
            PING_IP+=("10.0.0.${PING_DST[$i]#h}")')
report "P2a: with no record a name is guessed (h3 -> 10.0.0.3)" "$m" "🔴 no record: a name is refused (2)"

m=$(mutant p2b "$NDT" '            if [[ -z "$ip" ]]; then
                err "${PING_DST[$i]} is not a host of' '            if false; then
                err "${PING_DST[$i]} is not a host of')
report "P2b: an unknown destination name is not refused" "$m" "an unknown destination name -> 2, named, nothing started"

# --- P3: guards --------------------------------------------------------------------------------
m=$(mutant p3a "$NDT" '    guard_ping_lab_free || return 5' '    :')
report "P3a: the guard is not called" "$m" "somebody else's claim -> 5, no sudo call at all, no run dir"

m=$(mutant p3b "$NDT" '    PING_BUSY="$(in_flight)"' '    PING_BUSY=""')
report "P3b: a measurement in flight is ignored" "$m" "a measurement in flight -> 5, no sudo call, no run dir"

m=$(mutant p3c "$NDT" '    if tif="$(teardown_in_flight)"; then
        teardown_in_flight_refusal "start pings"' '    if [[ "$PING_FORCE" != 1 ]] && tif="$(teardown_in_flight)"; then
        teardown_in_flight_refusal "start pings"')
report "P3c: --force goes past an 'ndt down' in flight" "$m" "an 'ndt down' in flight -> 5 even with --force"

m=$(mutant p3d "$NDT" '    lab_session topo
    case $? in
        0) ;;' '    lab_session topo
    case $? in
        0|2) ;;')
report "P3d: an unreadable topo session is taken as running" "$m" "the topo session cannot be read (status refused) -> 5"

m=$(mutant p3e "$NDT" '        1) err "no topology is running (no topo session): nothing was started"' '        9) err "no topology is running (no topo session): nothing was started"')
report "P3e: no topo session is not refused" "$m" "no topo session -> 3, no host-ping call, no run dir"

m=$(mutant p3f "$NDT" '        if ! claim_override_record "ndt ping $PING_WORDS" "$PING_HELD" "$PING_BUSY"; then' '        if false; then')
report "P3f: --force is not recorded" "$m" "--force over the claim: starts, and writes ONE overrides line"

m=$(mutant p3g "$NDT" '    [[ "$PING_FORCE" == 1 ]] && return 0
    if [[ -n "$PING_HELD" ]]; then' '    [[ "$PING_FORCE" == 1 ]] && { claim_override_record "ndt ping $PING_WORDS" "$PING_HELD" "$PING_BUSY"; return 0; }
    if [[ -n "$PING_HELD" ]]; then')
report "P3g: the override is written before the topology is known" "$m" "--force with no topology: 3, and no override is recorded"

# --- P4: the report ----------------------------------------------------------------------------
m=$(mutant p4a "$NDT" '    if [[ -f "$base.rc" ]]; then
        rc="$(head -n 1 "$base.rc" 2>/dev/null)"' '    if [[ -f "$base.rc" ]]; then
        PS_STATE=clean; PS_TEXT="0 sent  0 received  0% packet loss"; return 0
        rc="$(head -n 1 "$base.rc" 2>/dev/null)"')
report "P4a: a stream without a summary is reported as 0% loss" "$m" "🔴 (c) sudo refused (rc 1, no summary) -> NOT MEASURED, rc 4"

m=$(mutant p4b "$NDT" '        if ndt_sudo_refused; then
            PS_TEXT="NOT MEASURED -- sudo refused $LAB host-ping"; PS_SUDO=1' '        if [[ "$rc" == 1 ]]; then
            PS_STATE=lost; PS_TEXT="100% packet loss (exit 1)"
        elif ndt_sudo_refused; then
            PS_TEXT="NOT MEASURED -- sudo refused $LAB host-ping"; PS_SUDO=1')
report "P4b: exit 1 without a summary is read as total loss" "$m" "🔴 (c) sudo refused (rc 1, no summary) -> NOT MEASURED, rc 4"

m=$(mutant p4c "$NDT" '    (( unmeasured )) && return 4' '    (( unmeasured )) && return 0')
report "P4c: not measured exits 0" "$m" "🔴 (c) sudo refused (rc 1, no summary) -> NOT MEASURED, rc 4"

m=$(mutant p4d "$NDT" '    (( lost )) && return 1
    (( unmeasured )) && return 4' '    (( unmeasured )) && return 4
    (( lost )) && return 1')
report "P4d: 4 outranks 1" "$m" "🔴 (j) a loss and a sudo refusal -> rc 1 (1 outranks 4)"

m=$(mutant p4e "$NDT" '    if ping_stream_alive "$base" || { [[ ! -f "$base.pid" ]] && (( now <= ends )); }; then' '    if :; then')
report "P4e: a stream whose process is gone is called running" "$m" "(e) no .rc, its process gone, past its end -> killed"

m=$(mutant p4f "$NDT" '        elif [[ "$NDT_SUDO_STDERR" == *"ndtwin-lab: usage:"* && "$NDT_SUDO_STDERR" != *host-ping* ]]; then' '        elif false; then')
report "P4f: an older helper is not recognised" "$m" "(f) an older helper's usage line -> 'no host-ping verb'"

m=$(mutant p4g "$NDT" '        (( sent < planned )) && PS_TEXT="$PS_TEXT  (ended early: $sent of $planned sent)"' '')
report "P4g: a stream that ended early is not flagged" "$m" "(h) fewer sent than planned is flagged"

m=$(mutant p4h "$NDT" '        if (( sent == 0 )); then' '        if false; then')
report "P4h: a summary with nothing sent is read as one" "$m" "(h2) a summary with 0 transmitted -> NOT MEASURED"

m=$(mutant p4i "$NDT" '        if [[ "$pct" =~ [1-9] ]]; then PS_STATE=lost; else PS_STATE=clean; fi' '        if [[ "$pct" =~ [0-9] ]]; then PS_STATE=lost; else PS_STATE=clean; fi')
report "P4i: 0% is read as a loss" "$m" "(a) 0% lost -> rc 0"

m=$(mutant p4j "$NDT" '        [[ "$cur" == "$up_at" ]] || warn "the fabric was taken down or rebuilt during this run; the loss includes that"' '        :')
report "P4j: a rebuilt fabric is not said" "$m" "a fabric rebuilt during the run is said"

m=$(mutant p4k "$NDT" '        elif [[ "$rc" =~ ^6[4-7]$ ]] && first="$(grep '"'"'^ndtwin-lab host-ping: '"'"' <<<"$NDT_SUDO_STDERR" | tail -n 1)" && [[ -n "$first" ]]; then' '        elif false; then')
report "P4k: the helper's own refusal is not quoted" "$m" "(g) the helper's own refusal is passed through"

m=$(mutant p4p "$NDT" '        elif [[ "$rc" =~ ^6[4-7]$ ]] && first="$(grep' '        elif first="$(grep')
report "P4p: the helper's refusal line is used whatever the exit code (a decoy's line wins)" "$m" "(o) a rejected decoy, then ping unreachable (exit 2) -> the reason is ping's, not the decoy's"

m=$(mutant p4q "$NDT" '<<<"$NDT_SUDO_STDERR" | tail -n 1)" && [[ -n "$first" ]]; then' '<<<"$NDT_SUDO_STDERR" | head -n 1)" && [[ -n "$first" ]]; then')
report "P4q: the FIRST helper line is the reason, not the last" "$m" "(p) the helper refuses (66) after naming a decoy -> the reason is its LAST line"

m=$(mutant p4r "$NDT" 'first="$(grep -v '"'"'^ndtwin-lab host-ping: '"'"' <<<"$NDT_SUDO_STDERR" | grep -m 1 .)"' 'first="$(grep -m 1 . <<<"$NDT_SUDO_STDERR")"')
report "P4r: the fallback reason may be a decoy's helper line" "$m" "(o) a rejected decoy, then ping unreachable (exit 2) -> the reason is ping's, not the decoy's"

m=$(mutant p4l "$NDT" '            PS_TEXT="NOT MEASURED -- ping'"'"'s summary has no loss figure: $line"' '            PS_STATE=clean; PS_TEXT="$sent sent  $recv received  0% packet loss"')
report "P4l: a summary without a loss figure is given one (0%)" "$m" "(k) a summary 'N transmitted, M received' with no '% packet loss' -> NOT MEASURED, rc 4"

m=$(mutant p4m "$NDT" '            PS_TEXT="NOT MEASURED -- no summary (exit ${rc:-?}): ${first:-no message}"' '            PS_STATE=lost; PS_TEXT="100% packet loss (exit ${rc:-?})"')
report "P4m: an exit with no summary at all is given a loss figure (100%)" "$m" "(l) exit 2 with only 'ping: connect: Network is unreachable' on stderr -> NOT MEASURED, rc 4"

m=$(mutant p4n "$NDT" '      if (( ! found )); then' '      if false; then')
report "P4n: a stream with no plan file is skipped silently" "$m" "(m) a stream the run started, with its plan file missing"

m=$(mutant p4o "$NDT" '    if [[ ! "$streams" =~ ^[1-9][0-9]*$ ]]; then' '    if false; then')
report "P4o: a run file with no stream count reports nothing, and is green" "$m" "(n) a run file without streams= -> NOT MEASURED, rc 4, no stream line, not green"

# --- P5: the call ------------------------------------------------------------------------------
m=$(mutant p5a "$NDT" 'LC_ALL=C LANGUAGE=C sudo -n "$LAB" host-ping "$1" "$2" "$3" "$4"' 'LC_ALL=C LANGUAGE=C sudo -n mnexec -a 1 /usr/bin/ping -q -c "$3" -i "$4" "$2"')
report "P5a: a direct mnexec call instead of the helper verb" "$m" "exactly one helper verb, with exactly four arguments"

# --- P6: start and wait ------------------------------------------------------------------------
m=$(mutant p6a "$NDT" '        if LAB="$LAB" setsid -f bash -c' '        if LAB="$LAB" setsid -w bash -c')
report "P6a: start waits for each stream" "$m" "start returns while a 3 s stream runs"

m=$(mutant p6b "$NDT" '        (( $(date +%s) > ends + NDT_PING_GRACE )) && break' '        :')
report "P6b: wait has no deadline" "$m" "--wait on a stream that never ends: gives up"

# --- P7: files ---------------------------------------------------------------------------------
m=$(mutant p7a "$NDT" 'ping_root() { echo "$REPO/.test_run/ping"; }' 'ping_root() { echo "$REPO/ping-runs"; }')
report "P7a: the runs are written outside .test_run/" "$m" "nothing written outside .test_run/ping/"

# --- the way in --------------------------------------------------------------------------------
m=$(mutant p8a "$NDT" '    ping)    shift; cmd_ping "$@" ;;' '')
report "P8a: the dispatch line is missing" "$m" "through the executable: bare 'ndt ping' -> 2 with its usage"

m=$(mutant p8b "$NDT" "                mininet> prompt: it works under NTG's prompt too. sudo: only the
                helper (its status and host-ping verbs; user guide 3.2's grant)." "                mininet> prompt: it works under NTG's prompt too. sudo: only
                'ndtwin-lab host-ping' (the helper grant of user guide 3.2).")
report "P8b: the help text says sudo covers host-ping alone" "$m" "'ndt help' says what sudo covers: the helper, its status and host-ping verbs"

m=$(mutant p8c "$NDT" "                files: .test_run/ping/<UTC stamp>.<pid>/  ('ndt down' leaves them)" "                files: .test_run/ping/<stamp>/  ('ndt down' does not touch them)")
report "P8c: the help text names the run directory as a bare <stamp>" "$m" "'ndt help' names the run directory as <UTC stamp>.<pid>, as ndt makes it"

# --- D1: the docs ------------------------------------------------------------------------------
m=$(mutant d1a "$README" \
    '   ndt ping h1:h3,h1:h4,h3:h1,h4:h1 --for 60s --interval 0.02' \
    '   ndt ping h1:h3,h1:h4,h3:h1,h4:h1 --for 60s --intreval 0.02')
report "D1a: a doc line with a misspelt flag" "$m" "  parses: ndt ping h1:h3,h1:h4,h3:h1,h4:h1 --for 60s --intreval 0.02"

m=$(mutant d1b "$GUIDE" '`.test_run/ping/<UTC stamp>.<pid>/`, files of yours.' '`.test_run/ping/<stamp>/`, files of yours.')
report "D1b: the guide names the run directory as a bare <stamp>" "$m" "the user guide names the run directory as <UTC stamp>.<pid>, not a bare <stamp>"

# --- the control -------------------------------------------------------------------------------
m=$(mutant p0 "$NDT" '# ping_last_dir -- the last run'"'"'s directory, or rc 1.' '# ping_last_dir -- the last run'"'"'s directory, or rc 1 (x).')
control "P0: a comment-only edit" "$m"

echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  ndt sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
