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
# [Co-developed with claude code -- Adam] (09-28) And every check of the suite must go red under at
# least one mutation: the gate keeps each mutant's whole run and names, by position (names repeat),
# any check no mutation turned red -- a check never seen red is not evidence.
# external_evidence.py is never written: mutants are copies, reached through EVIDENCE_UNDER_TEST,
# and its sha256 is compared at the end. [Co-developed with claude code -- Adam] Since round 5 it
# imports live-p1/code_identity.py from its own directory: every mutant directory gets a copy of it,
# and the I mutants mutate that copy instead (the tool beside it unchanged).
#
# Run:  bash tests/shell/mutate_live_p1_external_evidence.sh
# Exit: 0 every mutation caught and every check seen red; 1 one survived, or a check no mutation
#       turned red; 2 refused (baseline red); 3 the tool changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOOL="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_evidence.py"
IDENT="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/code_identity.py"
# [Co-developed with claude code -- Adam] (round 6) the frozen survey and its manifest sit beside the tool too
SURVEY="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_survey.py"
MANIFEST="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_survey_34.tsv"
TEST="$HERE/test_live_p1_external_evidence.sh"
[[ -r "$TOOL" && -r "$TEST" && -r "$IDENT" ]] || { echo "refused: the tool, code_identity.py or the suite is missing"; exit 2; }
ID_SUM="$(sha256sum "$IDENT" | cut -d' ' -f1)"
SV_SUM="$(sha256sum "$SURVEY" "$MANIFEST" | cut -d' ' -f1 | paste -sd,)"
BK="$(mktemp -d "${TMPDIR:-/tmp}/live-p1-evidence-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"

run_test() { EVIDENCE_UNDER_TEST="$1" timeout 300 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$TOOL")"; BASE_RC=$?
printf '%s\n' "$BASE_OUT" > "$BK/base.out"
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
    cp "$IDENT" "$d/code_identity.py"; cp "$SURVEY" "$MANIFEST" "$d/"
    if ! python3 -m py_compile "$d/external_evidence.py" 2>/dev/null; then
        printf '  SURVIVED %-62s (the mutant does not compile)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d/external_evidence.py")"
    printf '%s\n' "$out" > "$d/suite.out"
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
# label, E48 a control's heartbeat block; E50-E60 (09-28) one for each check no mutation had turned
# red, the rc-0 controls included (E56, E57).
mutate '            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")' \
    '            "heartbeat_packet_ins", "non_ipv4_packet_ins", "grpc_errors")
COMPARED = tuple(k for k in COMPARED if k != "counters_final")' \
    "E1: the counters' last values are not compared" \
    "  named as a DIFF in counters_final" "  noted as counters_final"
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
    "  noted as counters_final"
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
    "  named as a DIFF in packet_ins" "  noted as packet_ins"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins", "cache_entries",' \
    'COMPARED = ("rc", "verdict", "rules_installed", "counters_final", "packet_ins",' \
    "E11: the cache entries are not compared" \
    "  and a note on cache_entries (descriptive)"
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
    "  noted as verdict"
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
mutate '                where = "inside" if within(key, b[arm][key], cvals) else "OUTSIDE"' \
    '                where = "OUTSIDE"' \
    "E23: the controls' spread is ignored" \
    "  noted as inside the spread" "  noted as inside the counters' spread"
mutate '        return min(cs) <= t <= max(cs)' \
    '        return True' \
    "E24: any count is inside the spread" \
    "  noted as OUTSIDE the spread"
mutate '            s1_in is not None and base <= s1_in <= base + extra,' \
    '            True,' \
    "E25: s1 ingress 100 is not checked against the pings and datagrams" \
    "  noted as the invariant, descriptive"
mutate '            elif not all(i[name][0] for i in ic):' \
    '            elif False:' \
    "E26: an invariant a control breaks too is counted" \
    "🔴 a decisive invariant broken in a control too: UNDECIDED, rc 2"
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
    "🔴 a decisive invariant broken in a control too: UNDECIDED, rc 2"
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
    "🔴 a session sampled running, then stopped before the controller: rc 3" "  said as stopped before the controller's last write"
mutate '    if before == last:
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
    "  said as a sampler from before round 6"
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
    "  noted as OUTSIDE the counters' spread"
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

# [Co-developed with claude code -- Adam] (09-28) One mutation for each check that no mutation above
# turned red. Two of those checks are held by more than one guard, so the mutation takes all of the
# check's guards at once: a heartbeat frame at the controller is caught by the packet-in count, two
# more compared keys AND the IPv4 invariant (E51 hides both of its log lines from the reader), a
# changed verdict by both rc and verdict (E52).
mutate '        raise Unreadable(f"a packet-in whose frame cannot be parsed ({type(exc).__name__}: {exc}): "' \
    '        return -1, b""
        raise Unreadable(f"a packet-in whose frame cannot be parsed ({type(exc).__name__}: {exc}): "' \
    "E50: an unparseable packet-in is read as a non-IPv4 one" \
    "🔴 a packet-in that cannot be parsed: rc 2"
mutate '    lines = read_text(log_path).splitlines()' \
    '    lines = read_text(log_path).splitlines()
    lines = [x for i, x in enumerate(lines) if "\\x88\\xb5" not in x
             and not (i + 1 < len(lines) and "\\x88\\xb5" in lines[i + 1])]' \
    "E51: the reader never sees a heartbeat frame's packet-in (both its lines dropped)" \
    "🔴 a heartbeat frame at the exercise's controller: rc 1"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final",' \
    'COMPARED = ("rules_installed", "counters_final",' \
    "E52: an arm's rc and verdict are not compared" \
    "  noted as verdict" "  and as rc"
mutate '    if os.path.realpath(treatment) in dirs:' \
    '    if False:' \
    "E53: the treatment may also be a control" \
    "🔴 a treatment also given as a control: refused as such"
mutate '    print(f"  code  {' \
    '    (f"  code  {' \
    "E54: which code each run was is not printed" \
    "🔴 the control's code is printed" "🔴 and the treatment's"
mutate '        return ["not recorded (no 00_venv.txt)"]' \
    '        return []' \
    "E55: a run without 00_venv.txt says nothing about it" \
    "🔴 and the control's absence is said"
mutate '    return 1 if diffs else 2 if undecided else 0' \
    '    return 1' \
    "E56: every compare is a difference (the rc-0 controls)" \
    "🔴 controls vs treatment, the same evidence, H5's samples: rc 0" "  identity is not evidence: still rc 0"
mutate '    return 0


def identities(control, controls2, treatment, b_sha):' \
    '    return 2


def identities(control, controls2, treatment, b_sha):' \
    "E57: show refuses (the rc-0 control)" \
    "  show: rc 0" "  the same numbers read twice are settled: show rc 0"
mutate '        print(f"   hb      session {se[' \
    '        (f"   hb      session {se[' \
    "E58: the session each arm was judged on is not printed" \
    "  naming each arm's session and how long it ran"
mutate '          f"own evidence ({1 + len(cs2)} controls)"' \
    '          f"own evidence ({len(cs2)} controls)"' \
    "E59: the conclusion miscounts the controls" \
    "  and says so" "  said with its count of controls"
mutate '        return float(read_text(path).split()[0])' \
    '        return float(read_text(path).split()[0]) if os.path.exists(path) else float("inf")' \
    "E60: samples without 06's end run the last arm to no end" \
    "🔴 samples without 06's end beside them: rc 2"
# --- [Co-developed with claude code -- Adam] round 5: heard during the controller's lifetime (M-3),
# counters that are not numbers, the code identity (M-2) ---------------------------------------
mutate '    heard = heard_evidence(name, ev, sess, stretch, samples)' \
    '    heard = {"log": "-", "push_offset": 0, "from": 0, "to": 0, "undecided": None, "grew": {}}' \
    "E61: whether the session heard anything in the controller's window is not asked" \
    "🔴 a direction heard only before the push (+1 per 5 s, 1-s reads): rc 3" \
    "🔴 a direction heard only after the controller's last write: rc 3" \
    "🔴 a controller window of 5 s (under two periods): UNDECIDED, rc 2, not refused" \
    "🔴 a session first running after the push: rc 3" "🔴 a sampler that never saw the controller's log: rc 2" \
    "🔴 a log the sampler never saw reach its push: rc 2" "🔴 a controller log with no push and no entry: rc 2" \
    "🔴 every direction heard in the controller's window, said per direction"
mutate '    deaf = sorted(d for d in first if last[d] - first[d] < 1)' \
    '    deaf = []' \
    "E62: a direction that heard nothing is let through" \
    "🔴 a direction heard only before the push (+1 per 5 s, 1-s reads): rc 3" "  naming the direction and the window" \
    "  and which one" "🔴 a direction heard only after the controller's last write: rc 3" "  said as not heard in the window"
# --- [Co-developed with claude code -- Adam] round 6: the controller's own window (push to last write)
mutate '    if t1 - t0 < MIN_WINDOW_S:' \
    '    if t1 - t0 <= MIN_WINDOW_S:' \
    "E63: a window of exactly two periods is UNDECIDED" \
    "🔴 a window of exactly two periods is decided: rc 0" "  heard +2 in it"
mutate 'MIN_WINDOW_S = 2 * PERIOD_S' \
    'MIN_WINDOW_S = 0' \
    "E64: no window is too short" \
    "🔴 a controller window of 5 s (under two periods): UNDECIDED, rc 2, not refused" "  said as too short, with its length" \
    "  the rest of the comparison still printed"
mutate '    before = [s for s in stretch if s["wall"] <= t0]' \
    '    before = stretch[:1]' \
    "E65: heard counted from the session's start, not the push" \
    "🔴 a direction heard only before the push (+1 per 5 s, 1-s reads): rc 3" "🔴 a session first running after the push: rc 3" \
    "  said as the window not watched from its start"
mutate '    upto = [s for s in stretch if s["wall"] <= t1]' \
    '    upto = stretch' \
    "E81: heard counted to the session's end, not the controller's last write" \
    "🔴 a direction heard only after the controller's last write: rc 3"
mutate '        if PUSH.match(line):
            push = pos' \
    '        if PUSH.match(line):
            push = pos if push is None else push' \
    "E82: the window opens at the first push, not the last" \
    "🔴 the window opens at the LAST push (s2's at 70 s), not the first"
mutate '    return push if push is not None else entry' \
    '    return push' \
    "E83: a log with no push line has no window" \
    "🔴 no push line: the window opens at the first rule installed"
mutate '    if push is None and entry is None:' \
    '    if False:' \
    "E84: a log with neither push nor entry is not said as such" \
    "🔴 a controller log with no push and no entry: rc 2" "  said as a window with no start"
mutate '    if not seen:
        raise Unreadable' \
    '    if False:
        raise Unreadable' \
    "E85: a log the sampler never saw is not said as such" \
    "🔴 a sampler that never saw the controller's log: rc 2" "  said as such"
mutate '    if opened is None:' \
    '    if False:' \
    "E86: a log never seen at its push is not said as such" \
    "🔴 a log the sampler never saw reach its push: rc 2" "  said as no window start"
mutate '    if not before:' \
    '    if False:' \
    "E87: a session not running at the push is a traceback" \
    "🔴 a session first running after the push: rc 3" "  said as the window not watched from its start"
mutate '        if hd["undecided"]:
            undecided += 1' \
    '        if hd["undecided"]:
            pass' \
    "E88: a too-short window is not counted UNDECIDED" \
    "🔴 a controller window of 5 s (under two periods): UNDECIDED, rc 2, not refused" "  the rest of the comparison still printed"
mutate '            if key and size.isdigit():' \
    '            if False:' \
    "E89: the ctrl_logs column is not read" \
    "🔴 controls vs treatment, the same evidence, H5's samples: rc 0" \
    "🔴 every direction heard in the controller's window, said per direction"
mutate '    want = SAMPLER_COLUMNS' \
    '    want = SAMPLER_COLUMNS[:12]' \
    "E90: round 5's sampler file (no ctrl_logs) is taken" \
    "🔴 samples from round 5's sampler (no ctrl_logs): rc 2"
# --- the same program and compiler in every run; the identity before and after each run
mutate '    programs_same([("control", a)] + [(f"control2 #{i + 1}", c) for i, c in enumerate(cs2)]
                  + [("treatment", b)])' \
    '    pass' \
    "E91: the compiler and program are not compared across runs" \
    "🔴 a treatment compiled by another p4c: rc 3" "  said as not the same compiler and program" \
    "🔴 a control whose flowcache JSON differs: rc 3" "  naming the JSON" "🔴 a report with no p4c or JSON sha: rc 2" \
    "  said as such"
mutate '        if len({(p, j) for _l, p, j in seen}) != 1:' \
    '        if len({j for _l, p, j in seen}) != 1:' \
    "E92: another p4c is the same compiler" \
    "🔴 a treatment compiled by another p4c: rc 3"
mutate '        if len({(p, j) for _l, p, j in seen}) != 1:' \
    '        if len({p for _l, p, j in seen}) != 1:' \
    "E93: another compiled JSON is the same program" \
    "🔴 a control whose flowcache JSON differs: rc 3" "  naming the JSON"
mutate '            if not ev["p4c_sha"] or not ev["json_shas"]:' \
    '            if False:' \
    "E94: a report with no shas is refused, not unreadable" \
    "🔴 a report with no p4c or JSON sha: rc 2"
mutate '        why = code_identity.unchanged_reasons(pair[0], pair[1], os.path.basename(run))' \
    '        why = []' \
    "E95: the code may change while a run runs" \
    "  said as the code changing during the run" \
    "🔴 a treatment whose HEAD moved while it ran: rc 3" "  said as its HEAD before and after"
mutate '            counts[name] = int(v) if v.isdigit() else None' \
    '            counts[name] = int(v) if v.isdigit() else 0' \
    "E66: a counter the report did not carry reads as 0" \
    "🔴 a running sample whose daemon counter is not a number: rc 2, not a zero" "  naming the counter"
mutate '        if bad or s["heard"] is None:' \
    '        if bad:' \
    "E67: a heard column that is not counts is let through" \
    "🔴 a running sample whose heard column is not counts: rc 2" "  said as a heard column that is not counts"
mutate '    want = SAMPLER_COLUMNS' \
    '    want = SAMPLER_COLUMNS[:10]' \
    "E68: round 4's sampler file is taken" \
    "🔴 samples from round 4's sampler (no heard, no controllers): rc 2"
mutate '    cid, tid = identities(control, controls2, treatment, b_sha)' \
    '    cid, tid = {"head": "?" * 12}, {"head": "?" * 12}' \
    "E69: which code the runs ran is not asked" \
    "🔴 no --b-sha: rc 3" "🔴 a control with no identity: rc 3" "🔴 controls on two different HEADs: rc 3" \
    "🔴 a treatment merged onto another trunk: rc 3" "  the identities are said when they match"
mutate '        if why:
            raise Refused(f"the controls did not run the same code: {'"'"'; '"'"'.join(why)}")' \
    '        if False:
            raise Refused(f"the controls did not run the same code: {'"'"'; '"'"'.join(why)}")' \
    "E70: controls on different code are one spread" \
    "🔴 controls on two different HEADs: rc 3" "  said as the controls' code differing"
mutate '    if not b_sha:
        raise Refused("no --b-sha:' \
    '    if False:
        raise Refused("no --b-sha:' \
    "E71: no B named is let through to the identity check" \
    "  said as a missing --b-sha"
mutate '                raise Refused(f"{run}: no {name} -- which code it ran is not known "' \
    '                continue; (f"{run}: no {name} -- which code it ran is not known "' \
    "E72: a run with no identity is skipped" \
    "🔴 a control with no identity: rc 3" "  said as no identity" "🔴 a control with no identity after it ran: rc 3" \
    "  said as no after-identity"

# the pre-registered split (S-9): decisive keys and invariants held exactly, descriptive ones noted
mutate '    ("p4runtime", "solution"): {"rc", "verdict", "counters_final"},' \
    '    ("p4runtime", "solution"): {"rc", "verdict"},' \
    "E73: p4runtime/solution's varying counters are decisive" \
    "🔴 p4runtime/solution's counters ending elsewhere, invariants kept: noted, rc 0"
mutate '    ("flowcache", "solution"): {"rc", "verdict", "packet_ins", "cache_entries", "grpc_errors"},' \
    '    ("flowcache", "solution"): {"rc", "verdict", "cache_entries", "grpc_errors"},' \
    "E74: flowcache's varying packet-in count is decisive" \
    "🔴 a flowcache packet-in more (an IPv4 one; that count varied before): noted, rc 0" \
    "  and not decided either way (descriptive)"
mutate '    ("p4runtime", "solution"): {"rc", "verdict", "counters_final"},' \
    '    ("p4runtime", "solution"): {"rc", "verdict", "counters_final", "rules_installed"},' \
    "E75: the rules installed are only described" \
    "🔴 a rule the controller did not install: rc 1"
mutate '            if any(v != cvals[0] for v in cvals):' \
    '            if False:' \
    "E76: controls that disagree on a decisive key decide it anyway" \
    "🔴 controls that disagree on a decisive key (rules installed): UNDECIDED, rc 2" "  said as such"
mutate '    return 1 if diffs else 2 if undecided else 0' \
    '    return 1 if diffs else 0' \
    "E77: UNDECIDED exits 0" \
    "🔴 controls that disagree on a decisive key (rules installed): UNDECIDED, rc 2" \
    "🔴 a decisive invariant broken in a control too: UNDECIDED, rc 2"
mutate '    ("p4runtime", "solution"): {"s1 ingress 100 = pings + iperf datagrams",' \
    '    ("p4runtime", "solution"): {"s1 ingress 100 = never",' \
    "E78: the traffic sum that broke before is decisive" \
    "🔴 s1 ingress 100 = pings + the server's 3499, one under pings + Sent (as 6 of 12 earlier rounds): noted, rc 0"
mutate '          + (f"; {undecided} UNDECIDED: the controls disagree on a decisive check, or a controller'"'"'s "
             f"window was too short to show the heartbeat heard" if undecided else ""))' \
    '          + "")' \
    "E79: the conclusion does not say UNDECIDED" \
    "  and in the conclusion"
mutate '            elif name in DESCRIPTIVE_INVARIANTS.get(arm, ()):' \
    '            elif name in DESCRIPTIVE_INVARIANTS.get(arm, ()) or True:' \
    "E80: every invariant is only described" \
    "🔴 the 200 tunnel's sum broken (it never broke before): rc 1" "  said as INV BAD"

# [Co-developed with claude code -- Adam] (10-02) E96-E106: settled() -- each condition of its rule, on
# the 12 frozen real rounds and on cells that break one condition each.
R3504="2026-09-19T151037Z 2026-09-24T162954Z 2026-09-24T192012Z 2026-09-26T061642Z 2026-09-26T062438Z 2026-09-26T155814Z"
real_settled() { local r; for r in $R3504; do printf '%s\n' "🔴 real $r: the last block settled, show rc 0"; done; }
mapfile -t SETTLED_3504 < <(real_settled)
mutate '    if before == last:' \
    '    if False:' \
    "E96: a last block read twice is not settled" \
    "  the same numbers read twice are settled: show rc 0" "  no server report, the last block read twice: settled, show rc 0"
mutate '        if total is None or ip["no_ack"]:' \
    '        if total is None:' \
    "E97: a server report is an ack, 'did not receive ack' or not" \
    "🔴 a server report but 'did not receive ack', in range: rc 2" "  said as no ack"
mutate '        total = ip["server_total"]' \
    '        total = ip["server_total"] if ip["server_total"] is not None else ip["sent"] - 1' \
    "E98: no server report reads as Sent - 1 datagrams acked" \
    "🔴 no server report (and no warning), in range: rc 2" "  said as no server report"
mutate '        elif s1 is None or s2e != s1:' \
    '        elif s1 is None:' \
    "E99: s2 egress 100 need not be s1 ingress 100" \
    "🔴 s2 egress 100 not s1 ingress 100 in the last block, s1 in range: rc 2" "  naming the two counters" \
    "  named as s2 egress 100 not s1 ingress 100"
mutate '            if low <= s1 <= high:' \
    '            if low < s1 <= high:' \
    "E100: the low bound itself is not settled" \
    "${SETTLED_3504[@]}"
mutate '            if low <= s1 <= high:' \
    '            if s1 <= high:' \
    "E101: no low bound" \
    "🔴 a last counter block that had not settled: rc 2" "  naming the low bound"
mutate '            high = low + IPERF_FIN_RETRIES' \
    '            high = low' \
    "E102: no FIN retries allowed when acked" \
    "🔴 real 2026-09-27T081205Z: the last block settled, show rc 0" \
    "🔴 s1 ingress 100 at pings + the server's + 10 FIN retries: settled, show rc 0"
mutate '            if low <= s1 <= high:' \
    '            if low <= s1:' \
    "E103: no high bound" \
    "🔴 s1 ingress 100 over pings + the server's + 10 FIN retries: rc 2" "  naming the high bound"
mutate '            low = pings + (total if ip["target"] == "10.0.2.2" else 0)' \
    '            low = pings + (ip["sent"] if ip["target"] == "10.0.2.2" else 0)' \
    "E104: the client's Sent, not the server's total" \
    "${SETTLED_3504[@]}" \
    "🔴 s1 ingress 100 = pings + the server's 3499, one under pings + Sent (as 6 of 12 earlier rounds): noted, rc 0"
mutate '            total = int(t.group(2)) if t else None' \
    '            total = int(t.group(1)) if t else None' \
    "E105: the server's lost count read as its total" \
    "${SETTLED_3504[@]}" "🔴 real 2026-09-27T081205Z: the last block settled, show rc 0"
mutate '        if s1 == pings:' \
    '        if True:' \
    "E106: the skeleton's last block is settled whatever it counts" \
    "🔴 the skeleton's s1 ingress 100 not the pings, read once: rc 2"

# mutate_id <old> <new> <label> <check>... -- the same, on the copy of code_identity.py beside the
# (unchanged) tool.
mutate_id() {
    local old="$1" new="$2" label="$3" d want out missing=()
    shift 3
    d="$BK/$(printf '%s' "$label" | cut -d: -f1)"; mkdir -p "$d"
    # (the mutated file first: tests/shell/check_gate_anchors.py takes the first path a function
    # names as the file its anchors are in)
    if ! python3 - "$IDENT" "$d/code_identity.py" "$old" "$new" <<'PY'
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
    cp "$TOOL" "$d/external_evidence.py"; cp "$SURVEY" "$MANIFEST" "$d/"
    if ! python3 -m py_compile "$d/code_identity.py" 2>/dev/null; then
        printf '  SURVIVED %-62s (the mutant does not compile)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d/external_evidence.py")"
    printf '%s\n' "$out" > "$d/suite.out"
    for want in "$@"; do
        /usr/bin/grep -qF -- "  FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-62s (%s)\n' "$label" "$(tail -1 <<<"$out")"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-62s still green: %s\n' "$label" "${missing[0]}"; SURVIVED=$((SURVIVED+1))
    fi
}
mutate_id '        if parents[0] != c.get("head"):' \
    '        if False:' \
    "I1: T's first parent is not compared with the controls' HEAD" \
    "🔴 a treatment merged onto another trunk: rc 3" "  said as trunk moved"
mutate_id '        if not re.fullmatch(r"[0-9a-f]{7,40}", b_sha or "") or not parents[1].startswith(b_sha):' \
    '        if False:' \
    "I2: T's second parent is not compared with B" \
    "🔴 a treatment that merged another commit than B: rc 3" "  said as another B"
mutate_id '    if len(parents) != 2:' \
    '    if False:' \
    "I3: a commit that is not a merge passes as one" \
    "🔴 a treatment that is a commit on the controls' HEAD, not a merge: rc 3" "  said as not a merge"
mutate_id '    if c.get("head") == t.get("head"):' \
    '    if False:' \
    "I4: T on the controls' very HEAD is not said as B not merged" \
    "  said as B not merged"
mutate_id 'SAME = ("uncommitted", "kernel", "bmv2_fabric", "bmv2_libs", "bmv2_stock", "helper", "venv",' \
    'SAME = ("kernel", "bmv2_fabric", "bmv2_libs", "bmv2_stock", "helper", "venv",' \
    "I5: other uncommitted files are the same code" \
    "🔴 a treatment with another uncommitted file: rc 3" "  said as other uncommitted files"
mutate_id 'SAME = ("uncommitted", "kernel", "bmv2_fabric", "bmv2_libs", "bmv2_stock", "helper", "venv",' \
    'SAME = ("uncommitted", "bmv2_fabric", "bmv2_libs", "bmv2_stock", "helper", "venv",' \
    "I6: another kernel binary is the same code" \
    "🔴 a treatment on another kernel binary: rc 3" "  said as another kernel"
mutate_id '    if touched:' \
    '    if False:' \
    "I7: an uncommitted file B also changes is let through" \
    "🔴 an uncommitted file that B's merge changes too: rc 3" "  said as a file B changes"
mutate_id '    if changed_by_b is None and len(parents) == 2:' \
    '    if False:' \
    "I8: an identity that does not say what its merge changed is let through" \
    "🔴 a treatment whose identity does not say what its merge changed: rc 3" "  said as unknown merge changes"
# [Co-developed with claude code -- Adam] round 6: the tree, ~/tutorials, the fabric's libraries, the
# code paths compared, and the run's identity before against after
mutate_id '    if len(parents) == 2 and t.get("tree") != t.get("merge_tree"):' \
    '    if False:' \
    "I9: an amended merge is C plus B" \
    "🔴 a treatment whose tree is not the two parents' merge: rc 3" "  said as an amended or hand-resolved merge" \
    "🔴 an amended merge is refused"
mutate_id '            r = subprocess.run(["git", "-C", repo, "merge-tree", "--write-tree", *ident["parents"]],' \
    '            r = subprocess.run(["git", "-C", repo, "merge-tree", "--write-tree", ident["parents"][0], ident["parents"][0]],' \
    "I10: the merge's tree is checked against the wrong merge" \
    "🔴 a clean merge: its tree is what merging its parents gives"
mutate_id '        "tutorials")' \
    '        )' \
    "I11: another ~/tutorials is the same code" \
    "🔴 a treatment on another ~/tutorials: rc 3" "  said as tutorials" "🔴 a changed exercise file in ~/tutorials does" \
    "🔴 an untracked file in an exercise (git's porcelain does not show it) changes it too"
mutate_id 'SAME = ("uncommitted", "kernel", "bmv2_fabric", "bmv2_libs", "bmv2_stock", "helper", "venv",' \
    'SAME = ("uncommitted", "kernel", "bmv2_fabric", "bmv2_stock", "helper", "venv",' \
    "I12: other bmv2 libraries are the same code" \
    "🔴 a treatment on other bmv2 shared libraries: rc 3" "  said as bmv2_libs" "🔴 a rebuilt bmv2 shared library changes the identity"
mutate_id 'TUTORIALS_SKIP_DIRS = {"build", "logs", "pcaps", "__pycache__"}' \
    'TUTORIALS_SKIP_DIRS = {"logs", "pcaps", "__pycache__"}' \
    "I13: a round's build/ output changes the identity" \
    "🔴 a round rewriting build/ under an exercise does not change the identity"
mutate_id '    out["trees"] = {part: tree_digest(os.path.join(path, part)) for part in TUTORIALS_PARTS}' \
    '    out["trees"] = {}' \
    "I14: the exercises' files are not digested" \
    "🔴 an untracked file in an exercise (git's porcelain does not show it) changes it too" "  in that exercise's tree digest"
mutate_id '        out["head"] = git(path, "rev-parse", "HEAD").strip()' \
    '        out["head"] = "?"' \
    "I15: the tutorials' HEAD is not recorded" \
    "  the tutorials' HEAD is recorded"
mutate_id '        if ".so" in f and os.path.isfile(p) and not os.path.islink(p):' \
    '        if ".so" in f and os.path.isfile(p):' \
    "I16: a library's symlinks are digested as libraries" \
    "  the fabric's libraries: the one shared object, its symlink not counted"
mutate_id '            h.update(f"{f}\0{sha256_of(p)}\n".encode())' \
    '            h.update(f"{f}\n".encode())' \
    "I17: a library is known by its name only" \
    "🔴 a rebuilt bmv2 shared library changes the identity"
mutate_id 'NOT_CODE = (re.compile(r"^doc/.*\.md$"), re.compile(r"^doc/audit/.*\.tsv$"))' \
    'NOT_CODE = ()' \
    "I18: docs and audit tables are compared as code" \
    "🔴 uncommitted: a code file and an audit .json are recorded, a doc .md and an audit .tsv are not"
mutate_id 'NOT_CODE = (re.compile(r"^doc/.*\.md$"), re.compile(r"^doc/audit/.*\.tsv$"))' \
    'NOT_CODE = (re.compile(r"^doc/"),)' \
    "I19: everything under doc/ is left out" \
    "🔴 uncommitted: a code file and an audit .json are recorded, a doc .md and an audit .tsv are not"
mutate_id '    for key in ("head", "parents", "tree"):' \
    '    for key in ():' \
    "I20: a HEAD that moved during a run goes unnoticed" \
    "🔴 a treatment whose HEAD moved while it ran: rc 3" "  said as its HEAD before and after"

# mutate_sv <old> <new> <label> <check>... -- the same, on the copy of external_survey.py beside the
# (unchanged) tool. [Co-developed with claude code -- Adam]
mutate_sv() {
    local old="$1" new="$2" label="$3" d want out missing=()
    shift 3
    d="$BK/$(printf '%s' "$label" | cut -d: -f1)"; mkdir -p "$d"
    # (the mutated file first: tests/shell/check_gate_anchors.py takes the first path a function
    # names as the file its anchors are in)
    if ! python3 - "$SURVEY" "$d/external_survey.py" "$old" "$new" <<'PY'
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
    cp "$TOOL" "$d/external_evidence.py"; cp "$IDENT" "$MANIFEST" "$d/"
    if ! python3 -m py_compile "$d/external_survey.py" 2>/dev/null; then
        printf '  SURVIVED %-62s (the mutant does not compile)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d/external_evidence.py")"
    printf '%s\n' "$out" > "$d/suite.out"
    for want in "$@"; do
        /usr/bin/grep -qF -- "  FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-62s (%s)\n' "$label" "$(tail -1 <<<"$out")"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-62s still green: %s\n' "$label" "${missing[0]}"; SURVIVED=$((SURVIVED+1))
    fi
}
mutate_sv '            if got != r[kind + "_sha256"]:' \
    '            if False:' \
    "S1: a round whose bytes changed is surveyed anyway" \
    "🔴 a round whose controller log changed since it was frozen: rc 3" "  said as not what the manifest froze"
mutate_sv '            except OSError as exc:
                refused.append' \
    '            except OSError as exc:
                continue
                refused.append' \
    "S2: a frozen round that is gone is skipped" \
    "🔴 a frozen round that is gone: rc 3"
mutate_sv '        if trace:
            refused.append' \
    '        if False:
            refused.append' \
    "S3: a round with the heartbeat is surveyed as a control" \
    "🔴 a round that had the heartbeat: rc 3" "  said as not a round without it"
mutate_sv '    if not lines or lines[0].split("\t") != COLUMNS:' \
    '    if not lines:' \
    "S4: any first line is a manifest's header" \
    "  a manifest that is not one: rc 2"
mutate_sv '    print(f"{len(rows)} rounds, every report and controller log as frozen, none with the heartbeat")' \
    '    print(f"{len(rows)} rounds")' \
    "S5: the survey does not say what it checked" \
    "  said as such"
mutate_sv '            cnt = collections.Counter(value(e[k]) for e in evs)' \
    '            cnt = collections.Counter(value(e[k]) for e in evs[:0])' \
    "S6: the counts are of nothing" \
    "  with each field's count of values"
mutate_sv '    return 0


def main(argv):' \
    '    return 1


def main(argv):' \
    "S7: a survey that found everything as frozen exits 1" \
    "🔴 the frozen rounds as frozen, none with the heartbeat: rc 0"

echo
NOW_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 external_evidence.py CHANGED during the gate"; exit 3
fi
if [[ "$(sha256sum "$IDENT" | cut -d' ' -f1)" != "$ID_SUM" ]]; then
    echo "🔴 code_identity.py CHANGED during the gate"; exit 3
fi
if [[ "$(sha256sum "$SURVEY" "$MANIFEST" | cut -d' ' -f1 | paste -sd,)" != "$SV_SUM" ]]; then
    echo "🔴 external_survey.py or its manifest CHANGED during the gate"; exit 3
fi
echo "source byte-identical: yes  external_evidence.py  sha256 $BASE_SUM; code_identity.py sha256 $ID_SUM; survey and manifest $SV_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived"
# [Co-developed with claude code -- Adam] (09-28) every check, by position, red under some mutation
COV="$(python3 - "$BK" <<'COVERAGE'
import glob, re, sys
rx = re.compile(r"^  (ok|FAILED) +(.*)$")
def checks(path):
    lines = open(path, errors="replace").read().splitlines()
    return [(m.group(1), m.group(2).rstrip()) for m in map(rx.match, lines) if m]
base = checks(sys.argv[1] + "/base.out")
runs = [checks(p) for p in glob.glob(sys.argv[1] + "/*/suite.out")]
never = [f"#{i + 1} {name}" for i, (_, name) in enumerate(base)
         if not any(len(r) == len(base) and r[i] == ("FAILED", name) for r in runs)]
print(f"every check seen red: {len(base) - len(never)}/{len(base)} (over {len(runs)} mutant runs)")
for n in never:
    print(f"  NEVER RED under any mutation: {n}")
COVERAGE
)"
echo "$COV"
(( SURVIVED == 0 )) && ! /usr/bin/grep -q 'NEVER RED' <<<"$COV"
