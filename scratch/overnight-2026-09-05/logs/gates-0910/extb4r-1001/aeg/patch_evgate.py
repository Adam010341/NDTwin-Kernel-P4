#!/usr/bin/env python3
# patch_evgate.py <mutate_live_p1_external_evidence.sh> -- round 3b: E50-E60 and the coverage report.
import sys

p = sys.argv[1]
s = open(p).read()


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:80]
    s = s.replace(old, new)


rep('''# red for it -- the list is at the mutations below. A mutation that will not apply, whose
# anchor is not unique, that does not compile, or whose named check stays green is a SURVIVOR.''',
    '''# red for it -- the list is at the mutations below. A mutation that will not apply, whose
# anchor is not unique, that does not compile, or whose named check stays green is a SURVIVOR.
# [Co-developed with claude code -- Adam] (09-28) And every check of the suite must go red under at
# least one mutation: the gate keeps each mutant's whole run and names, by position (names repeat),
# any check no mutation turned red -- a check never seen red is not evidence.''')
rep('''# Exit: 0 every mutation caught; 1 one survived; 2 refused (baseline red); 3 the tool changed.''',
    '''# Exit: 0 every mutation caught and every check seen red; 1 one survived, or a check no mutation
#       turned red; 2 refused (baseline red); 3 the tool changed.''')
rep('''BASE_OUT="$(run_test "$TOOL")"; BASE_RC=$?
''', '''BASE_OUT="$(run_test "$TOOL")"; BASE_RC=$?
printf '%s\\n' "$BASE_OUT" > "$BK/base.out"
''')
rep('''    out="$(run_test "$d/external_evidence.py")"
''', '''    out="$(run_test "$d/external_evidence.py")"
    printf '%s\\n' "$out" > "$d/suite.out"
''')
rep('''# label, E48 a control's heartbeat block.''',
    '''# label, E48 a control's heartbeat block; E50-E60 (09-28) one for each check no mutation had turned
# red, the rc-0 controls included (E56, E57).''')

NEW = r'''
# [Co-developed with claude code -- Adam] (09-28) One mutation for each check that no mutation above
# turned red. Two of those checks are held by more than one guard, so the mutation takes all of the
# check's guards at once: a heartbeat frame is caught by two compared keys AND the IPv4 invariant
# (E51 drops the frame where it is read), a changed verdict by both rc and verdict (E52).
mutate '        raise Unreadable(f"a packet-in whose frame cannot be parsed ({type(exc).__name__}: {exc}): "' \
    '        return -1, b""
        raise Unreadable(f"a packet-in whose frame cannot be parsed ({type(exc).__name__}: {exc}): "' \
    "E50: an unparseable packet-in is read as a non-IPv4 one" \
    "🔴 a packet-in that cannot be parsed: rc 2"
mutate '            kinds.append(et)' \
    '            if et == HEARTBEAT_ETHERTYPE:
                continue
            kinds.append(et)' \
    "E51: the heartbeat's packet-ins are dropped before they are counted" \
    "🔴 a heartbeat frame at the exercise's controller: rc 1"
mutate 'COMPARED = ("rc", "verdict", "rules_installed", "counters_final",' \
    'COMPARED = ("rules_installed", "counters_final",' \
    "E52: an arm's rc and verdict are not compared" \
    "🔴 an arm whose verdict changed: rc 1"
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
mutate '    return 0 if not diffs else 1' \
    '    return 1' \
    "E56: every compare is a difference (the rc-0 controls)" \
    "🔴 controls vs treatment, the same evidence, H5's samples: rc 0" "  identity is not evidence: still rc 0"
mutate '    return 0


def compare(control, treatment, controls2, samples_path):' \
    '    return 2


def compare(control, treatment, controls2, samples_path):' \
    "E57: show refuses (the rc-0 control)" \
    "  show: rc 0" "  the same numbers read twice are settled: show rc 0"
mutate '        print(f"   hb      session {se[' \
    '        (f"   hb      session {se[' \
    "E58: the session each arm was judged on is not printed" \
    "  naming each arm's session and how long it ran"
mutate '          f"own evidence ({1 + len(cs2)} controls)")' \
    '          f"own evidence ({len(cs2)} controls)")' \
    "E59: the conclusion miscounts the controls" \
    "  and says so" "  said with its count of controls"
mutate '        return float(read_text(path).split()[0])' \
    '        return float(read_text(path).split()[0]) if os.path.exists(path) else float("inf")' \
    "E60: samples without 06's end run the last arm to no end" \
    "🔴 samples without 06's end beside them: rc 2"
'''
anchor = '''
echo
NOW_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"'''
rep(anchor, NEW + anchor)

rep('''echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived"
(( SURVIVED == 0 ))''',
    '''echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived"
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
(( SURVIVED == 0 )) && ! /usr/bin/grep -q 'NEVER RED' <<<"$COV"''')
open(p, "w").write(s)
print("patched")
