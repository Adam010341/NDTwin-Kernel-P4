import sys
p = sys.argv[1]; s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)
rep('''#   E  test_live_p1_external_evidence over the base's external_evidence.py (M2, m1)
set -u''', '''#   E  test_live_p1_external_evidence over the base's external_evidence.py (M2, m1)
#   F  the evidence gate's own coverage report: HEAD's gate without E56 must fail on the two rc-0
#      checks no other mutation turns red, with nothing survived (the report alone makes it red)
set -u''')
rep('''         "🔴 samples from a sampler before 09-28: rc 2" "🔴 samples without 06's end beside them: rc 2"; do''',
    '''         "🔴 samples from a sampler before 09-28: rc 2" "🔴 samples without 06's end beside them: rc 2" \\
         "🔴 a treatment also given as a control: refused as such"; do''')
rep('''echo "    cells green over the base tool (guards of what it already did; the evidence gate's E mutants kill each):"''',
    '''echo "    cells green over the base tool (guards of what it already did; the evidence gate's coverage report"
echo "    shows every check of the suite red under some mutation -- F checks that report can fail):"''')
rep('''echo "REDFIRST-B3: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"''',
'''echo "== F: the evidence gate's coverage report, red on its own"
G="$T/gate_noE56"; mkdir -p "$G/tests/shell" "$G/$LIVE"
python3 - tests/shell/mutate_live_p1_external_evidence.sh "$G/tests/shell/mutate_live_p1_external_evidence.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
i = s.index("mutate '    return 0 if not diffs else 1'")
j = s.index("\\nmutate ", i + 1)
assert "E56:" in s[i:j] and s.count("E56:") == 1
open(sys.argv[2], "w").write(s[:i] + s[j + 1:])
PY
cp tests/shell/test_live_p1_external_evidence.sh "$G/tests/shell/"; cp "$LIVE/external_evidence.py" "$G/$LIVE/"
( cd "$G" && timeout 1500 bash tests/shell/mutate_live_p1_external_evidence.sh ) > "$K/f_gate_noE56.out" 2>&1; frc=$?
/usr/bin/grep -E "^mutation gate|^every check seen red|NEVER RED" "$K/f_gate_noE56.out" | sed 's/^/    /'
nev="$(/usr/bin/grep -c 'NEVER RED' "$K/f_gate_noE56.out")"
if [[ $frc == 1 ]] && /usr/bin/grep -q '^mutation gate: 60 mutations, 0 survived$' "$K/f_gate_noE56.out" && [[ $nev == 2 ]] \\
   && /usr/bin/grep -qF "NEVER RED under any mutation: #1 🔴 controls vs treatment, the same evidence, H5's samples: rc 0" "$K/f_gate_noE56.out" \\
   && /usr/bin/grep -qF "identity is not evidence: still rc 0" <(/usr/bin/grep 'NEVER RED' "$K/f_gate_noE56.out"); then
    ok "the gate without E56: rc 1 with 0 survived, on exactly the two rc-0 checks E56 alone turns red (RED)"
else nok "the gate without E56: rc $frc, $nev never-red line(s)"; fi

echo "REDFIRST-B3: $([[ $bad == 0 ]] && echo ALL-AS-EXPECTED || echo UNEXPECTED)"''')
open(p, "w").write(s)
