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
# F7, F8) and again for its second round (M2, m1, m3): E1-E15 the comparison of the exercise's own
# evidence, E16-E19 and E32-E40 the roles and the samples, E21-E22 and E41-E43 and E46-E47 what is
# unreadable, E23-E24 and E45 the controls' spread, E25-E31 the invariants and the daemon, E44 N4's
# label, E48 a control's heartbeat block.
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
    "🔴 an arm with no controller log: rc 2"
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
mutate '        et = int.from_bytes(payload[12:14], "big")' \
    '        et = int.from_bytes(payload[14:16], "big")' \
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
mutate '            if trace:
                raise Refused' \
    '            if False:
                raise Refused' \
    "E18: a control may carry the heartbeat" \
    "🔴 a control with a running row: rc 3"
mutate '        if not t["hb_started"]:
            raise Refused(f"treatment {name}: `ndt up` did not say it started the heartbeat detect-only")
        if not t["hb_running"]:' \
    '        if False:
            raise Refused(f"treatment {name}: `ndt up` did not say it started the heartbeat detect-only")
        if False:' \
    "E18b: a treatment need show no heartbeat at all" \
    "🔴 A/A (a control as the treatment): rc 3"
mutate '    if not mine:' \
    '    if False:' \
    "E19: a session need not have been sampled running" \
    "🔴 a session never sampled running: rc 3"
mutate '    counts = {k: max(s["counts"][k] for s in win if s["session"] == sess) for k in DAEMON}' \
    '    counts = {k: max(s["counts"][k] for s in win if s["session"] == sess) for k in DAEMON if k != "forwarded_between_switches"}' \
    "E20: a sampled session may forward between switches" \
    "🔴 a session that forwarded between switches: rc 1"
mutate '        if short:
            raise Unreadable' \
    '        if False:
            raise Unreadable' \
    "E21: a counter block cut short is read as a reading" \
    "🔴 a counter block cut short: rc 2"
mutate '    except (OSError, UnicodeDecodeError) as exc:
        raise Unreadable(f"{path}: {type(exc).__name__}: {exc}") from exc


def table_rows' \
    '    except OSError as exc:
        raise Unreadable(f"{path}: {type(exc).__name__}: {exc}") from exc


def table_rows' \
    "E22: a log that is not UTF-8 is a traceback" \
    "🔴 a controller log that is not UTF-8: rc 2"
mutate '            if within(key, b[arm][key], cvals):' \
    '            if False:' \
    "E23: the controls' spread is ignored" \
    "🔴 a packet-in count between the controls': rc 0"
mutate '        return min(cs) <= t <= max(cs)' \
    '        return True' \
    "E24: any count is inside the spread" \
    "🔴 a packet-in count outside the controls': rc 1"
mutate '            s1_in is not None and base <= s1_in <= base + extra,' \
    '            True,' \
    "E25: s1 ingress 100 is not checked against the pings and datagrams" \
    "  said as the invariant, kept by every control"
mutate '            elif not all(i[name][0] for i in ic):' \
    '            elif False:' \
    "E26: an invariant a control breaks too is counted" \
    "  and with the counters inside the spread: rc 0"
mutate '        stray = [f for f in ev["_entry_flows"] if f not in ev["_flows"]]' \
    '        stray = []' \
    "E27: a cache entry need not be a packet-in's flow" \
    "🔴 a cache entry that is no packet-in's flow: INV BAD"
mutate '        moved = {k: v for k, v in se["counts"].items() if v}' \
    '        moved = {}' \
    "E28: a daemon that forwarded a frame is not a difference" \
    "🔴 a session whose daemon counted a frame to a host: rc 1"
mutate '            elif not all(i[name][0] for i in ic):' \
    '            elif not ic[0][name][0]:' \
    "E29: an invariant only the second control breaks is counted" \
    "🔴 broken in the second control only: shown, not counted"
mutate '        out["every other tunnel counter 0"] = (bool(others) and all(v == 0 for v in others.values()),' \
    '        out["every other tunnel counter 0"] = (True,' \
    "E30: the skeleton's other counters are not checked" \
    "🔴 a skeleton counter that should be 0: INV BAD"
mutate '        extra = IPERF_FIN_RETRIES if ip["no_ack"] else 0' \
    '        extra = 0' \
    "E31: FIN retries after a lost ack are not allowed for" \
    "  up to 10 FIN retries when the client got no ack"
mutate '    sessions = check_roles([("control", a)] + [(f"control2 #{i + 1}", c) for i, c in enumerate(cs2)],' \
    '    sessions = check_roles([("control", a)],' \
    "E32: a second control may have run the heartbeat" \
    "🔴 a second control with only a heartbeat block: rc 3"
mutate '    if not samples_path:
        raise Refused' \
    '    if False:
        raise Refused' \
    "E33: no --samples is accepted" \
    "🔴 no --samples: rc 3"
mutate '    if not controls2:
        raise Refused' \
    '    if False:
        raise Refused' \
    "E34: one control is accepted" \
    "🔴 no --control2: rc 3"
mutate '    if len(set(dirs)) != len(dirs):' \
    '    if False:' \
    "E35: a control given twice is accepted" \
    "🔴 --control2 that is the control itself: rc 3"
mutate '    if others:
        raise Refused' \
    '    if False:
        raise Refused' \
    "E36: another session in the arm window is accepted" \
    "🔴 a second session inside the arm window: rc 3"
mutate '        if b["wall"] - a["wall"] > MAX_GAP_S:' \
    '        if False:' \
    "E37: a stretch without samples is accepted" \
    "🔴 a stretch of the session with no sample: rc 3"
mutate '        if s["written"] is None or s["wall"] - s["written"] > STALE_S or s["stop_reason"]:' \
    '        if False:' \
    "E38: a stale 'running' is accepted" \
    "🔴 a stale 'running' left by a killed daemon: rc 3"
mutate '    if stop is not None and any(s["session"] == sess and s["status"] == "running" for s in win[stop:]):' \
    '    if False:' \
    "E39: a stop and a restart is accepted" \
    "🔴 a session that stopped and ran again: rc 3"
mutate '    if ev["_last_write"] > stopped_at:' \
    '    if False:' \
    "E40: a session that stopped before the controller's last write is accepted" \
    "🔴 a session sampled running, then stopped before the controller: rc 3"
mutate '    if before == last or (exp[0] == exp[1] and s1 == exp[0]):
        return' \
    '    if True:
        return' \
    "E41: an unsettled last counter block is read as final" \
    "🔴 a last counter block that had not settled: rc 2"
mutate '        if et == IPV4_ETHERTYPE and len(payload) < 34:' \
    '        if False:' \
    "E42: an IPv4 payload shorter than its header is parsed" \
    "🔴 an IPv4 packet-in shorter than its header: rc 2"
mutate '    if head[:len(want)] != want:' \
    '    if False:' \
    "E43: a sampler file from before 09-28 is not named" \
    "  said as such"
mutate '"(before the exercise'"'"'s pipeline was loaded: not evidence about the program)")' \
    '"")' \
    "E44: N4's counters are not labelled" \
    "🔴 N4's counters are labelled as before the pipeline"
mutate '    if key == "counters_final":
        keys = set(t).union(*(set(c) for c in cs))' \
    '    if key == "counters_final":
        return True
        keys = set(t).union(*(set(c) for c in cs))' \
    "E45: any tunnel counter is inside the spread" \
    "🔴 tunnel counters outside the controls': rc 1"
mutate '    print(__doc__.split("Usage:")[1].split("Exit:")[0].rstrip(), file=sys.stderr)
    return 2' \
    '    print(__doc__.split("Usage:")[1].split("Exit:")[0].rstrip(), file=sys.stderr)
    return 0' \
    "E46: a wrong command line exits 0" \
    "🔴 a compare with one run: usage, rc 2"
mutate '    except (OSError, UnicodeDecodeError) as exc:
        raise Unreadable(f"{path}: {type(exc).__name__}: {exc}") from exc


def table_rows' \
    '    except (FileNotFoundError, UnicodeDecodeError) as exc:
        raise Unreadable(f"{path}: {type(exc).__name__}: {exc}") from exc


def table_rows' \
    "E47: a report that is a directory is a traceback" \
    "🔴 and no traceback from it"
mutate '                                      ("a heartbeat block on switch_state", ev["hb_block"]),' \
    '                                      ("a heartbeat block on switch_state", False),' \
    "E48: a control's heartbeat block is not a trace" \
    "🔴 a second control with only a heartbeat block: rc 3" "  naming both traces"
mutate '    except Unreadable as exc:
        print(f"UNREADABLE {exc}")' \
    '    except Unreadable as exc:
        print("NO DIFFERENCE")
        print(f"UNREADABLE {exc}")' \
    "E49: an unreadable run still prints a conclusion" \
    "  and does not print a conclusion either way"

echo
NOW_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 external_evidence.py CHANGED during the gate"; exit 3
fi
echo "source byte-identical: yes  external_evidence.py  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived"
(( SURVIVED == 0 ))
