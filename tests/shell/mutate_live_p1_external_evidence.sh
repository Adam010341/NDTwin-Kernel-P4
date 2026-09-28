#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_live_p1_external_evidence.sh -- live-p1/external_evidence.py,
# the instrument the external detect-only change is compared with before it is merged.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation takes away one thing the comparison must do and names the check(s) that must go
# red for it -- the list is at the mutations below. A mutation that will not apply, whose
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
mutate() {   # mutate <old> <new> <label> <check that must go red>...
    # (the anchor first: tests/shell/check_gate_anchors.py reads a mutate()'s first argument as
    # its anchor, in the file the function body names)
    local old="$1" new="$2" label="$3" d want out missing=()
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

# [Co-developed with claude code -- Adam] Rewritten 09-28 with the tool (the external judge's F1, F2,
# F7 and F8): E1-E15 the comparison of the exercise's own evidence (F8 added E10-E15: every COMPARED
# key and the ethertype parse), E16-E20 the roles (F1), E21-E22 what is unreadable (F2, F7),
# E23-E24 the spread of two controls (F2), E25-E31 the invariants and the daemon (F2, section 5 of
# the judge), E32 a second control with the heartbeat.
mutate '            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")' \
    '            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")
COMPARED = tuple(k for k in COMPARED if k != "counters_final")' \
    "E1: the counters' last values are not compared" \
    "🔴 a tunnel counter that ended elsewhere, invariants kept: rc 1"
mutate '            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")' \
    '            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors", "counter_reads")' \
    "E2: how often the counters were read is compared" \
    "🔴 one counter read more, same last values: rc 0"
mutate 'HEARTBEAT_ETHERTYPE = 0x88B5' \
    'HEARTBEAT_ETHERTYPE = 0x0800' \
    "E3: the heartbeat's ethertype is IPv4's" \
    "🔴 named as heartbeat_packet_ins" "  and NOT as the heartbeat's"
mutate '    if len(logs) != 1:
        raise Unreadable' \
    '    if len(logs) != 1:
        return "/dev/null"
        raise Unreadable' \
    "E4: a round with no controller log reads as an empty one" \
    "🔴 an arm with no controller log: rc 2" "  and does not print a conclusion either way"
mutate '        "counters_final": blocks[-1] if blocks else {},' \
    '        "counters_final": blocks[0] if blocks else {},' \
    "E5: the FIRST counter read is compared, not the last" \
    "🔴 a tunnel counter that ended elsewhere, invariants kept: rc 1"
mutate '        if b[arm]["heartbeat_packet_ins"]:' \
    '        if False:' \
    "E6: a heartbeat frame at the controller is not said in words" \
    "🔴 and said in words"
mutate '        elif line.startswith(("protobuf ", "distributions ", "NOT RECORDED")):' \
    '        elif False:' \
    "E7: the venv fingerprint is not printed" \
    "🔴 the treatment's protobuf is printed"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final",' \
    'COMPARED = ("rc", "verdict", "counters_final",' \
    "E8: the installed rules are not compared" \
    "🔴 a rule the controller did not install: rc 1"
mutate '        if row is None:
            raise Unreadable' \
    '        if row is None:
            continue
            raise Unreadable' \
    "E9: an arm missing from the table is skipped" \
    "🔴 a run without the flowcache/solution row: rc 2"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins", "cache_entries",' \
    'COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "cache_entries",' \
    "E10: the packet-in count is not compared" \
    "🔴 a packet-in more (an IPv4 one): rc 1"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins", "cache_entries",' \
    'COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins",' \
    "E11: the cache entries are not compared" \
    "  and a DIFF in cache_entries"
mutate '            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")' \
    '            "heartbeat_packet_ins", "non_ipv4_packet_ins")' \
    "E12: the gRPC errors are not compared" \
    "🔴 a gRPC error more: rc 1"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final",' \
    'COMPARED = ("verdict", "rules_installed", "counters_final",' \
    "E13: the rc is not compared" \
    "  and as rc"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final",' \
    'COMPARED = ("rc", "rules_installed", "counters_final",' \
    "E14: the verdict is not compared" \
    "  named as verdict"
mutate '    return int.from_bytes(payload[12:14], "big"), payload' \
    '    return int.from_bytes(payload[14:16], "big"), payload' \
    "E15: the ethertype is read two bytes late" \
    "🔴 named as heartbeat_packet_ins"
mutate '        if not t["hb_started"]:' \
    '        if False:' \
    "E16: a treatment need not have started the heartbeat" \
    "🔴 a treatment with no detect-only start line: rc 3"
mutate '        if not t["hb_running"]:' \
    '        if False:' \
    "E17: a treatment need not have a running status row" \
    "🔴 a treatment whose status row is not running: rc 3"
mutate '        if control[arm]["hb_running"]:' \
    '        if False:' \
    "E18: a control may have run the heartbeat" \
    "🔴 a control whose heartbeat was running: rc 3"
mutate '            if not any(s["status"] == "running" for s in mine):' \
    '            if False:' \
    "E19: a session need not have been sampled running" \
    "🔴 a session H5 never read running: rc 3"
mutate '            leaked = [s for s in mine if s["hosts"] not in ("0", "") or s["between"] not in ("0", "")]' \
    '            leaked = [s for s in mine if s["hosts"] not in ("0", "")]' \
    "E20: a sampled session may forward between switches" \
    "🔴 a sampled session that forwarded between switches: rc 3"
mutate '        if short:
            raise Unreadable' \
    '        if False:
            raise Unreadable' \
    "E21: a counter block cut short is read as a reading" \
    "🔴 a counter block cut short: rc 2"
mutate '    except (OSError, UnicodeDecodeError) as exc:' \
    '    except OSError as exc:' \
    "E22: a log that is not UTF-8 is a traceback" \
    "🔴 a controller log that is not UTF-8: rc 2"
mutate '            if c2 is not None and within(key, b[arm][key], a[arm][key], c2[arm][key]):' \
    '            if False:' \
    "E23: the second control's spread is ignored" \
    "🔴 a packet-in count between the controls': rc 0"
mutate '        return min(c1, c2) <= t <= max(c1, c2)' \
    '        return True' \
    "E24: any count is inside the spread" \
    "🔴 a packet-in count outside the controls': rc 1"
mutate '            s1_in is not None and base <= s1_in <= base + extra,' \
    '            True,' \
    "E25: s1 ingress 100 is not checked against the pings and datagrams" \
    "  said as the invariant, kept by the control"
mutate '            elif not ia[name][0]:' \
    '            elif False:' \
    "E26: an invariant the control breaks too is counted" \
    "  and with nothing else different: rc 0"
mutate '        stray = [f for f in ev["_entry_flows"] if f not in ev["_flows"]]' \
    '        stray = []' \
    "E27: a cache entry need not be a packet-in's flow" \
    "🔴 a cache entry that is no packet-in's flow: INV BAD"
mutate '        moved = {k: v for k, v in b[arm]["side_effects"].items() if v}' \
    '        moved = {}' \
    "E28: a daemon that forwarded a frame is not a difference" \
    "🔴 a daemon that counted a frame to a host: rc 1"
mutate '        if not t["side_effects"]:' \
    '        if False:' \
    "E29: a treatment need not show the daemon's counters" \
    "🔴 a treatment with no daemon counters: rc 3"
mutate '        out["every other tunnel counter 0"] = (bool(others) and all(v == 0 for v in others.values()),' \
    '        out["every other tunnel counter 0"] = (True,' \
    "E30: the skeleton's other counters are not checked" \
    "🔴 a skeleton counter that should be 0: INV BAD"
mutate '        extra = IPERF_FIN_RETRIES if ip["no_ack"] else 0' \
    '        extra = 0' \
    "E31: FIN retries after a lost ack are not allowed for" \
    "  up to 10 FIN retries when the client got no ack"
mutate '            if c2[arm]["hb_running"]:' \
    '            if False:' \
    "E32: a second control may have run the heartbeat" \
    "🔴 a second control with the heartbeat running: rc 3"

echo
NOW_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 external_evidence.py CHANGED during the gate"; exit 3
fi
echo "source byte-identical: yes  external_evidence.py  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived"
(( SURVIVED == 0 ))
