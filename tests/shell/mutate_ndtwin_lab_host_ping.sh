#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndtwin_lab_host_ping.sh (`ndtwin-lab host-ping`).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation takes away one decision the root verb makes -- an argument check, the 600 s bound,
# part of the identity of the process it enters, which candidates count, the descriptor that pins
# the network namespace (opened before the check, confirmed after it), the exact argv (the network
# namespace only), the deadline, the empty environment, where the binaries may be and that none is a
# symlink, the tag staying out of every child's argv, nothing found through PATH, the refused-config
# gate, the way in -- and must turn its NAMED check red. A mutation caught by some other check says
# nothing about the check that was supposed to own it.
#
# 🔴 Mutations are applied to a COPY of the helper in a temp dir and the suite is pointed at it with
#    LAB_UNDER_TEST; tools/test_workflow/ndtwin-lab is never written, and its sha256 is compared at
#    the end.
# 🔴 A mutation that will not apply, a non-unique anchor, or the wrong check going red counts as a
#    SURVIVOR. A comment-only edit is the control and must stay green.
# 🔴 Needs no root and runs no nsenter or ping: the suite records the exec (see its header).
#
# Env:  MUTANT_EVIDENCE=<dir>  keeps each mutant as <label>.patch and the suite's output as <label>.log.
# Exit: 0 every mutation caught and the control stayed green, 1 a mutation survived (or the control
#       went red), 2 refused (baseline red / harness), 3 the helper changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LABSRC="$REPO/tools/test_workflow/ndtwin-lab"
SH_TEST="$HERE/test_ndtwin_lab_host_ping.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/host-ping-mutate-XXXXXX")
trap 'rm -rf "${BK:?}"' EXIT
BASE=$(sha256sum "$LABSRC" | cut -d' ' -f1)

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$LABSRC" && -f "$SH_TEST" ]] || { echo "🔴 missing $LABSRC or $SH_TEST" >&2; exit 2; }

SURVIVORS=0
MUTATIONS=0

run_sh() { (cd "$1" && LAB_UNDER_TEST="$1/ndtwin-lab" timeout 300 bash "$SH_TEST" 2>&1); }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the check that must fail (a prefix of its name)
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -f "$2/ndtwin-lab" ]]; then
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
    if [[ -f "$2/ndtwin-lab" && "$rc" -eq 0 ]]; then
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
    cp "$LABSRC" "$d/ndtwin-lab"
    if ! python3 - "$d/ndtwin-lab" "$old" "$new" <<'PY' >&2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        rm -f "$d/ndtwin-lab"     # not built: `report` counts it as a survivor
    elif [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        mkdir -p "$MUTANT_EVIDENCE"
        diff -u --label "a/${file#"$REPO"/}" --label "b/${file#"$REPO"/}" "$file" "$d/ndtwin-lab" \
            > "$MUTANT_EVIDENCE/$label.patch"
    fi
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; cp "$LABSRC" "$base/ndtwin-lab"
run_sh "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# --- H1: the arguments -------------------------------------------------------------------------
m=$(mutant h1a "$LABSRC" '    if ! hp_valid_host "$host"; then' '    if false; then')
report "H1a: the host name is not checked" "$m" 'refused (64), nothing entered: h1\;id 10.0.3.3 3000 0.02'

m=$(mutant h1b "$LABSRC" '    if ! hp_valid_ipv4 "$ip"; then' '    if false; then')
report "H1b: the address is not checked" "$m" 'refused (64), nothing entered: h1 -f 3000 0.02'

m=$(mutant h1c "$LABSRC" "    local o='(0|[1-9][0-9]{0,2})'" "    local o='([0-9]{1,3})'")
report "H1c: an octet with a leading zero (octal to ping) is accepted" "$m" 'refused (64), nothing entered: h1 010.0.0.1 3000 0.02'

m=$(mutant h1d "$LABSRC" '    if ! hp_valid_count "$count"; then' '    if false; then')
# Garbage like 3e3 is still refused with the count unchecked, because the duration check's arithmetic
# fails on it and fails closed; a count of 0 is what only the count check refuses.
report "H1d: the count is not checked" "$m" 'refused (64), nothing entered: h1 10.0.3.3 0 0.02'

m=$(mutant h1e "$LABSRC" 'hp_valid_count() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 60000 )); }' \
                          'hp_valid_count() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]]; }')
# Since the 600 s bound (H1i) a count above 60000 is refused whatever this says, so what this one
# still owns is the DIAGNOSIS: the refusal must name the count, not the duration.
report "H1e: the count has no upper bound of its own (the refusal blames the duration)" "$m" '  and the refusal names the count'

m=$(mutant h1f "$LABSRC" '    (( ms >= 10 && ms <= 10000 )) || return 1' '    (( ms >= 1 && ms <= 10000 )) || return 1')
report "H1f: an interval under 0.01 s is accepted" "$m" 'refused (64), nothing entered: h1 10.0.3.3 3000 0.009'

m=$(mutant h1g "$LABSRC" '    if (( $# != 4 )); then
        hp_refuse "usage: ndtwin-lab host-ping' '    if (( $# < 4 )); then
        hp_refuse "usage: ndtwin-lab host-ping')
report "H1g: a fifth argument is accepted" "$m" 'a fifth argument: refused (64), nothing entered'

m=$(mutant h1h "$LABSRC" '    if ! ms="$(hp_interval_ms "$interval")"; then' '    if ! ms="$(hp_interval_ms "${interval%%;*}")"; then')
report "H1h: an interval is checked after trimming what follows ';'" "$m" 'refused (64), nothing entered: h1 10.0.3.3 3000 0.02\;'

m=$(mutant h1i "$LABSRC" 'hp_duration_ok() { (( $1 * $2 <= 600000 )); }' 'hp_duration_ok() { (( $1 * $2 <= 6000000 )); }')
report "H1i: the 600 s bound is ten times too long" "$m" 'refused (64), nothing entered: h1 10.0.3.3 61 10'

m=$(mutant h1j "$LABSRC" 'hp_duration_ok() { (( $1 * $2 <= 600000 )); }' 'hp_duration_ok() { (( $1 * $2 < 600000 )); }')
report "H1j: 600 s itself is refused" "$m" 'control: a 32-character host, 255.255.255.255, 60 x 10 s (600 s, the ceiling) are accepted'

m=$(mutant h1k "$LABSRC" 'hp_duration_ok() { (( $1 * $2 <= 600000 )); }' 'hp_duration_ok() { true; }')
report "H1k: there is no bound on the duration" "$m" 'refused (64), nothing entered: h1 10.0.3.3 60000 10'

# --- H2: the process it enters -----------------------------------------------------------------
m=$(mutant h2a "$LABSRC" '        [[ "$last" == "$tag" ]] || continue' '        [[ "$last" == *"$tag"* ]] || continue')
report "H2a: /proc's last element is matched as a substring" "$m" "ps's joined args end in the tag, /proc's last element is not the tag -> 65"

m=$(mutant h2b "$LABSRC" '        [[ "${args##* }" == "$tag" ]] || continue
        # /proc is the authority, read after the snapshot: an exited pid drops out here.
        last="$(hp_cmdline_last "$pid")" || continue
        [[ "$last" == "$tag" ]] || continue' '        [[ "${args##* }" == *"$tag" ]] || continue
        last="$(hp_cmdline_last "$pid")" || continue
        [[ "$last" == *"$tag" ]] || continue')
report "H2b: the tag is matched as a suffix" "$m" "a last word that only ENDS in the tag ('xmininet:h1') -> 65"

m=$(mutant h2c "$LABSRC" '        last="$(hp_cmdline_last "$pid")" || continue
        [[ "$last" == "$tag" ]] || continue' '        last="$tag"')
report "H2c: /proc is not read (ps decides alone)" "$m" "nominated by ps, gone from /proc (exited) -> 65"

m=$(mutant h2d "$LABSRC" '    for u in "${status[@]}"; do [[ "$u" == "$HP_EXPECT_UID" ]] || bad=1; done' '    :')
report "H2d: the uid check is dropped" "$m" "the same argv owned by another uid -> 66, not entered"

m=$(mutant h2e "$LABSRC" '    (( ${#status[@]} == 4 )) || bad=1
    for u in "${status[@]}"; do [[ "$u" == "$HP_EXPECT_UID" ]] || bad=1; done' \
    '    [[ "${status[0]}" == "$HP_EXPECT_UID" ]] || bad=1')
report "H2e: only the real uid is checked" "$m" "real uid right but effective uid wrong -> 66"

m=$(mutant h2f "$LABSRC" '    if [[ -z "$nsu" || -z "$nsu1" || "$nsu" != "$nsu1" ]]; then' '    if false; then')
report "H2f: the user-namespace check is dropped" "$m" "root, but in another user namespace -> 66"

m=$(mutant h2g "$LABSRC" '    if [[ -z "$nsn" || -z "$nsn1" || "$nsn" == "$nsn1" ]]; then' '    if false; then')
report "H2g: the network-namespace check is dropped" "$m" "root, but in pid 1's network namespace -> 66"

m=$(mutant h2h "$LABSRC" '    if (( ${#ok[@]} > 1 )); then' '    if false; then')
report "H2h: of two candidates that pass, the first is taken" "$m" "two candidates that both pass -> 65, neither entered"

m=$(mutant h2i "$LABSRC" '    if [[ -z "$nsu" || -z "$nsu1" || "$nsu" != "$nsu1" ]]; then' '    if [[ -n "$nsu" && -n "$nsu1" && "$nsu" != "$nsu1" ]]; then')
report "H2i: an unreadable user namespace passes" "$m" "a user namespace that cannot be read -> 66"

m=$(mutant h2j "$LABSRC" '    for u in "${status[@]}"; do [[ "$u" == "$HP_EXPECT_UID" ]] || bad=1; done' \
                          '    for u in "${status[@]:0:2}"; do [[ "$u" == "$HP_EXPECT_UID" ]] || bad=1; done')
report "H2j: only the real and effective uids are checked" "$m" "saved uid wrong, real and effective right -> 66"

m=$(mutant h2k "$LABSRC" '    (( ${#status[@]} == 4 )) || bad=1' '    :')
report "H2k: a Uid line with three fields is accepted" "$m" "a Uid line with three fields instead of four -> 66"

m=$(mutant h2l "$LABSRC" '    if ! { exec 3< "$HP_PROC/$pid/ns/net"; } 2>/dev/null; then' '    { exec 3< "$HP_PROC/$pid/ns/net"; } 2>/dev/null; if false; then')
report "H2l: a network namespace that cannot be opened is not refused at the open" "$m" "a network namespace that exists but cannot be opened -> 66, and it says so"

m=$(mutant h2m "$LABSRC" '        if hp_identity_ok "$cand" "$host"; then ok+=("$cand"); else rejected+=("$cand"); fi' '        ok+=("$cand")')
report "H2m: every process carrying the tag counts, whoever owns it" "$m" "a decoy with the tag owned by another uid does not block the host: the real one is entered"

m=$(mutant h2n "$LABSRC" '(rejected pids ${rejected[*]})"
        return "$HP_RC_IDENTITY"' '(rejected pids ${rejected[*]})"
        return "$HP_RC_NO_HOST"')
report "H2n: when none passes the refusal is 65, not 66" "$m" "only decoys carry the tag -> 66 (not 65), nothing entered"

m=$(mutant h2o "$LABSRC" '(rejected pids ${rejected[*]})"' '(rejected pids)"')
report "H2o: the rejected pids are not named" "$m" "  and the refusal names the rejected pids"

m=$(mutant h2p "$LABSRC" '    for u in "${status[@]}"; do [[ "$u" == "$HP_EXPECT_UID" ]] || bad=1; done' \
                          '    for u in "${status[@]:0:3}"; do [[ "$u" == "$HP_EXPECT_UID" ]] || bad=1; done')
report "H2p: the filesystem uid is not checked (first three only)" "$m" "filesystem uid wrong, the other three right -> 66"

# --- H3: what it execs -------------------------------------------------------------------------
m=$(mutant h3a "$LABSRC" ' -i "$interval" -w "$deadline" "$ip"' ' -i "$interval" "$ip"')
report "H3a: -w is dropped" "$m" "exactly: <nsenter> --net=/proc/self/fd/3 <ping> -n -q -c 3000 -i 0.02 -w 65 10.0.3.3"

m=$(mutant h3b "$LABSRC" 'hp_deadline() { echo $(( ($1 * $2 + 999) / 1000 + 5 )); }' 'hp_deadline() { echo $(( ($1 * $2) / 1000 + 5 )); }')
report "H3b: the deadline is rounded down" "$m" "control: interval 0.3, and the deadline is rounded UP: 7 x 0.3 s = 2.1 s -> -w 8"

m=$(mutant h3c "$LABSRC" 'hp_exec() { exec -c "$@"; }' 'hp_exec() { exec "$@"; }')
report "H3c: the caller's environment is kept" "$m" "nothing of the caller's environment reaches it"

m=$(mutant h3d "$LABSRC" '        [[ "${st%% *}" == "$HP_EXPECT_UID" ]] && (( (8#${st##* } & 8#022) == 0 )) || continue
        st="$("$HP_STAT" -L -c '"'"'%u %a'"'"' "$d" 2>/dev/null)" || continue' '        st="$("$HP_STAT" -L -c '"'"'%u %a'"'"' "$d" 2>/dev/null)" || continue')
report "H3d: the binary's owner and mode are not checked" "$m" "a group-writable binary is not used"

m=$(mutant h3e "$LABSRC" '        st="$("$HP_STAT" -L -c '"'"'%u %a'"'"' "$d" 2>/dev/null)" || continue
        [[ "${st%% *}" == "$HP_EXPECT_UID" ]] && (( (8#${st##* } & 8#022) == 0 )) || continue
        echo "$f"' '        echo "$f"')
report "H3e: the binary's directory is not checked" "$m" "a binary in a world-writable directory is not used"

m=$(mutant h3g "$LABSRC" '        [[ -f "$f" && -x "$f" && ! -L "$f" ]] || continue' '        [[ -f "$f" && -x "$f" ]] || continue')
report "H3g: a symlink is accepted as a binary" "$m" "a symlink to an acceptable binary is not used"

m=$(mutant h3h "$LABSRC" '    HP_READLINK="$(hp_bin readlink)" || return 1' '    HP_READLINK="$(hp_bin readlink)" || :')
report "H3h: a missing readlink is not refused" "$m" "no readlink where it may be -> 67, nothing executed, and the refusal names it"

m=$(mutant h3i "$LABSRC" '    HP_PS="$(hp_bin ps)" || return 1' '    HP_PS="$(hp_bin ps)" || :')
report "H3i: a missing ps is not refused" "$m" "no ps where it may be -> 67, nothing executed, and the refusal names it"

m=$(mutant h3j "$LABSRC" '    HP_STAT="$(hp_bin stat "${HP_STAT_DIRS[@]}")" || return 1' '    HP_STAT="${HP_STAT:-stat}"')
report "H3j: a missing stat is not refused" "$m" "no stat where it may be -> 67, nothing executed, and the refusal names it"

m=$(mutant h3k "$LABSRC" '    for d in "${HP_STAT_DIRS[@]}"; do
        [[ -f "$d/stat" && -x "$d/stat" && ! -L "$d/stat" ]] && { HP_STAT="$d/stat"; break; }
    done
    HP_STAT="$(hp_bin stat "${HP_STAT_DIRS[@]}")" || return 1' '    for d in "${HP_BIN_DIRS[@]}"; do
        [[ -f "$d/stat" && -x "$d/stat" && ! -L "$d/stat" ]] && { HP_STAT="$d/stat"; break; }
    done
    HP_STAT="$(hp_bin stat)" || return 1')
report "H3k: stat may vouch from any directory of the binaries' list" "$m" "a stat in HP_BIN_DIRS but not in the stat directories is not used -> 67, nothing executed"

m=$(mutant h3l "$LABSRC" '    HP_STAT="$(hp_bin stat "${HP_STAT_DIRS[@]}")" || return 1' '    HP_STAT="$(hp_bin stat)" || return 1')
report "H3l: the final stat is searched in the whole list, not the stat directories" "$m" "the stat that vouches is the one from the stat directories, not the first of HP_BIN_DIRS"

m=$(mutant h3m "$LABSRC" 'HP_STAT_DIRS=(/usr/bin /bin)' 'HP_STAT_DIRS=(/usr/bin /bin /usr/local/bin)')
report "H3m: the stat directories are widened" "$m" "the shipped directories stat may come from are /usr/bin and /bin only"

# --- H3/H6: the argv is the network namespace only, through the pinned descriptor ----------------
m=$(mutant h6c "$LABSRC" '    hp_exec "$nsenter" --net=/proc/self/fd/3 "$ping"' '    hp_exec "$nsenter" --net="$HP_PROC/$pid/ns/net" "$ping"')
report "H6c: nsenter is given the pid's path, not the pinned descriptor" "$m" "exactly: <nsenter> --net=/proc/self/fd/3 <ping> -n -q -c 3000 -i 0.02 -w 65 10.0.3.3"

m=$(mutant h6d "$LABSRC" '    hp_exec "$nsenter" --net=/proc/self/fd/3 "$ping"' '    hp_exec "$nsenter" --net=/proc/self/fd/3 --mount="$HP_PROC/$pid/ns/mnt" "$ping"')
report "H6d: the host's mount namespace is joined too" "$m" "the only namespace it joins is the network one, before ping's own path"

m=$(mutant h6e "$LABSRC" '    hp_exec "$nsenter" --net=/proc/self/fd/3 "$ping"' '    hp_exec "${nsenter%nsenter}mnexec" -a "$pid" "$ping"')
report "H6e: mnexec -a <pid> is back" "$m" "the argv has no mnexec at all"

m=$(mutant h6f "$LABSRC" 'hp_exec() { exec -c "$@"; }' 'hp_exec() { exec -c "$@" 3<&-; }')
report "H6f: descriptor 3 is closed before the exec" "$m" "descriptor 3 survived the exec, still naming the host's network namespace"

# --- H6: the namespace is pinned before it is checked ---------------------------------------------
m=$(mutant h6a "$LABSRC" '    if ! { exec 3< "$HP_PROC/$pid/ns/net"; } 2>/dev/null; then
        hp_refuse "refusing pid $pid for Mininet host $host: cannot open its network namespace"; return 1
    fi
    hp_identity_ok "$pid" "$host" || return 1' '    hp_identity_ok "$pid" "$host" || return 1
    if ! { exec 3< "$HP_PROC/$pid/ns/net"; } 2>/dev/null; then
        hp_refuse "refusing pid $pid for Mininet host $host: cannot open its network namespace"; return 1
    fi')
report "H6a: the descriptor is opened after the identity check, not before" "$m" "ns/net re-pointed at another namespace after the check -> 66, nothing executed"

m=$(mutant h6b "$LABSRC" '    if [[ "$held" != "$now" ]]; then' '    if false; then')
report "H6b: descriptor 3 is not compared with what the pid's ns/net names now" "$m" "ns/net re-pointed at another namespace after the check -> 66, nothing executed"

m=$(mutant h6g "$LABSRC" '    if [[ "$held" != "$now" ]]; then' '    if [[ -n "$now" && "$held" != "$now" ]]; then')
report "H6g: a pid whose ns/net is gone passes the comparison" "$m" "ns/net gone after the check (the process exited) -> 66, nothing executed"

m=$(mutant h6h "$LABSRC" '    hp_identity_ok "$pid" "$host" || return 1
    held=' '    held=')
report "H6h: the identity check after the open is deleted (a pid reused before the open is entered)" "$m" "a pid replaced BEFORE the open by a non-root process in a new namespace -> 66, nothing executed"

m=$(mutant h3f "$LABSRC" 'HP_BIN_DIRS=(/usr/bin /usr/sbin /bin /sbin /usr/local/bin /usr/local/sbin)' \
                          'HP_BIN_DIRS=(/usr/local/bin /usr/bin /usr/sbin /bin /sbin /usr/local/sbin)')
report "H3f: /usr/bin is not searched first" "$m" "the shipped search path starts with /usr/bin"

# --- H4: the tag stays out of every child's argv -----------------------------------------------
m=$(mutant h4a "$LABSRC" '    done < <(hp_ps_snapshot)' '    done < <(hp_ps_snapshot | grep -F -- "$tag")')
report "H4a: the snapshot is filtered by a grep that carries the tag" "$m" "🔴 no recorded child argv contains 'mininet:'"

m=$(mutant h4b "$LABSRC" 'hp_ps_snapshot() { "$HP_PS" -eo pid=,args= 2>/dev/null; }' 'hp_ps_snapshot() { ps -eo pid=,args= 2>/dev/null; }')
report "H4b: ps is found through PATH" "$m" "🔴 a ps planted first on PATH is not run"

m=$(mutant h4c "$LABSRC" '    nsn="$("$HP_READLINK" "$HP_PROC/$pid/ns/net" 2>/dev/null)"; nsn1="$("$HP_READLINK" "$HP_PROC/1/ns/net" 2>/dev/null)"' \
                          '    nsn="$(readlink "$HP_PROC/$pid/ns/net" 2>/dev/null)"; nsn1="$(readlink "$HP_PROC/1/ns/net" 2>/dev/null)"')
report "H4c: readlink is found through PATH" "$m" "🔴 a readlink planted first on PATH is not run"

m=$(mutant h4d "$LABSRC" '        st="$("$HP_STAT" -L -c '"'"'%u %a'"'"' "$f" 2>/dev/null)" || continue' '        st="$(stat -L -c '"'"'%u %a'"'"' "$f" 2>/dev/null)" || continue')
report "H4d: stat is found through PATH" "$m" "🔴 a stat planted first on PATH is not run"

# --- H5: how it is reached ---------------------------------------------------------------------
m=$(mutant h5a "$LABSRC" '        status|config)' '        status|config|host-ping)')
report "H5a: host-ping runs under a refused config" "$m" "under a refused config, host-ping fails closed (rc 1)"

m=$(mutant h5b "$LABSRC" '    host-ping) shift; hp_rc=0; host_ping_main "$@" || hp_rc=$?; exit "$hp_rc" ;;' '')
report "H5b: the dispatch line is missing" "$m" "the dispatch hands host-ping everything after the verb"

m=$(mutant h5c "$LABSRC" '|host-ping <host> <ipv4> <count> <interval>|status|config}"' '|status|config}"')
report "H5c: the usage line does not name host-ping" "$m" "the usage line names host-ping and its four arguments"

m=$(mutant h5d "$LABSRC" '    deadline="$(hp_deadline "$count" "$ms")"' '    deadline="$(hp_deadline "$count" "$ms")"; : "$KERNEL_DIR"')
report "H5d: the verb reads a tree user code runs from" "$m" "it names none of the trees user code runs from"

# --- the control -------------------------------------------------------------------------------
m=$(mutant h0 "$LABSRC" '# hp_deadline <count> <interval-ms> -- ping'"'"'s -w: the whole run in seconds, rounded up, plus 5.' \
                         '# hp_deadline <count> <interval-ms> -- ping'"'"'s -w: the whole run in seconds, rounded up, plus 5 (x).')
control "H0: a comment-only edit" "$m"

echo
NOW=$(sha256sum "$LABSRC" | cut -d' ' -f1)
if [[ "$NOW" != "$BASE" ]]; then
    echo "🔴 baseline CHANGED during the gate -- the helper was written"
    echo "   before: $BASE"
    echo "   after:  $NOW"
    exit 3
fi
echo "baseline byte-identical: yes  ndtwin-lab sha256 $BASE"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
