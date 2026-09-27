#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_live_p1_external_evidence.sh -- live-p1/external_evidence.py,
# the instrument the external detect-only change is compared with before it is merged.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation takes away one thing the comparison must do and names the check(s) that must go
# red for it: compare the counters' LAST values (E1, E5), leave the read count out (E2), know the
# heartbeat's ethertype (E3) and say it in words (E6), refuse what it cannot read (E4, E9), compare
# the installed rules (E8), print the fingerprints (E7). A mutation that will not apply, whose
# anchor is not unique, that does not compile, or whose named check stays green is a SURVIVOR.
# external_evidence.py is never written: mutants are copies, reached through EVIDENCE_UNDER_TEST,
# and its sha256 is compared at the end.
#
# Run:  bash tests/shell/mutate_live_p1_external_evidence.sh
# Exit: 0 every mutation caught; 1 one survived; 2 refused (baseline red); 3 the tool changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOOL="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_evidence.py"
TEST="$HERE/test_live_p1_external_evidence.sh"
[[ -r "$TOOL" && -r "$TEST" ]] || { echo "refused: the tool or its suite is missing"; exit 2; }
BK="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-evidence-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"

run_test() { EVIDENCE_UNDER_TEST="$1" timeout 300 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$TOOL")"; BASE_RC=$?
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0
mutate() {   # mutate <label> <old> <new> <check that must go red>...
    local label="$1" old="$2" new="$3" d want out missing=()
    shift 3
    d="$BK/$(printf '%s' "$label" | cut -d: -f1)"; mkdir -p "$d"
    if ! python3 - "$TOOL" "$d/external_evidence.py" "$old" "$new" <<'PY'
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src).read()
if a == b or s.count(a) != 1:
    print(f"ANCHOR:{s.count(a)}"); sys.exit(1)
open(dst, "w").write(s.replace(a, b))
PY
    then
        printf '  SURVIVED %-62s (anchor not unique or identity)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    if ! python3 -m py_compile "$d/external_evidence.py" 2>/dev/null; then
        printf '  SURVIVED %-62s (the mutant does not compile)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d/external_evidence.py")"
    for want in "$@"; do
        /usr/bin/grep -qF -- "  FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-62s (%s)\n' "$label" "$(tail -1 <<<"$out")"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-62s still green: %s\n' "$label" "${missing[0]}"; SURVIVED=$((SURVIVED+1))
    fi
}

mutate "E1: the counters' last values are not compared" \
    '            "heartbeat_packet_ins", "grpc_errors")' \
    '            "heartbeat_packet_ins", "grpc_errors")
COMPARED = tuple(k for k in COMPARED if k != "counters_final")' \
    "🔴 a tunnel counter that ended elsewhere: rc 1"
mutate "E2: how often the counters were read is compared" \
    '            "heartbeat_packet_ins", "grpc_errors")' \
    '            "heartbeat_packet_ins", "grpc_errors", "counter_reads")' \
    "🔴 one read more, same last values: rc 0"
mutate "E3: the heartbeat's ethertype is IPv4's" \
    'HEARTBEAT_ETHERTYPE = 0x88B5' \
    'HEARTBEAT_ETHERTYPE = 0x0800' \
    "🔴 named as heartbeat_packet_ins" "  and NOT as the heartbeat's"
mutate "E4: a round with no controller log reads as an empty one" \
    '    if len(logs) != 1:
        raise Unreadable' \
    '    if len(logs) != 1:
        return "/dev/null"
        raise Unreadable' \
    "🔴 an arm with no controller log: rc 2" "  and does not print a conclusion either way"
mutate "E5: the FIRST counter read is compared, not the last" \
    '        "counters_final": blocks[-1] if blocks else {},' \
    '        "counters_final": blocks[0] if blocks else {},' \
    "🔴 a tunnel counter that ended elsewhere: rc 1"
mutate "E6: a heartbeat frame at the controller is not said in words" \
    '        if b[arm]["heartbeat_packet_ins"]:' \
    '        if False:' \
    "🔴 and said in words"
mutate "E7: the venv fingerprint is not printed" \
    '        elif line.startswith(("protobuf ", "distributions ", "NOT RECORDED")):' \
    '        elif False:' \
    "🔴 the new run's protobuf is printed"
mutate "E8: the installed rules are not compared" \
    'COMPARED = ("rc", "verdict", "rules_installed", "counters_final",' \
    'COMPARED = ("rc", "verdict", "counters_final",' \
    "🔴 a rule the controller did not install: rc 1"
mutate "E9: an arm missing from the table is skipped" \
    '        if row is None:
            raise Unreadable' \
    '        if row is None:
            continue
            raise Unreadable' \
    "🔴 a run without the flowcache/solution row: rc 2"

echo
NOW_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 external_evidence.py CHANGED during the gate"; exit 3
fi
echo "source byte-identical: yes  external_evidence.py  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived"
(( SURVIVED == 0 ))
