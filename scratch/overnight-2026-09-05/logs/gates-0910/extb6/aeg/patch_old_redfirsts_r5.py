# patch_old_redfirsts_r5.py -- round 5's cells in the expected sets of redfirst_b..b4 (HEAD's suites now carry
# them; over every older base they are red, or their old names are gone). Each change prints its reason in the
# script it patches. [Co-developed with claude code -- Adam]
import sys
A = sys.argv[1]
def patch(name, pairs):
    p = f"{A}/{name}"; s = open(p).read()
    for a, b in pairs:
        assert s.count(a) == 1, (name, a[:70], s.count(a))
        s = s.replace(a, b)
    open(p, "w").write(s)
NDT_LOG_OLD = '"  and the whole of it is kept"'
NDT_LOG_NEW = ('"  and the whole of it is kept, in the log the line names" "  and this one\'s says what this check said" \\\n'
               '    "🔴 a second bring-up keeps its own log: the first one\'s is still there" "  in another file"')
NDT_LOG_WHY = ('echo "    (round 5, S-5: one drop-check log per bring-up -- \'the whole of it is kept\' is now \'... in the log the line'
               ' names\', and three cells pin a second bring-up\'s own log; red over every base before round 5)"\n')
APP_NEW = ('"🔴 a nonzero count on an external plane is flagged" "🔴 and is a --check problem" \\\n'
           '    "  so --check exits 1 on it" "  zero paths on an external plane: the designed answer"')
APP_WHY = ('echo "    (round 5, the nit: a path count on an external plane is flagged; zero is quiet -- red over every base'
           ' before round 5, whose status row has neither)"\n')
# redfirst_b (base f7e2a128)
patch("redfirst_b.sh", [
    (NDT_LOG_OLD + " \\", NDT_LOG_NEW + " \\"),
    ('''same_set "base 06" "$T/t_red" \\
    "🔴 the raw records the venv fingerprint of both interpreters" "  the driver's interpreter among them" \\
    "  with protobuf's version and implementation"
''', '''same_set "base 06" "$T/t_red" \\
    "🔴 the raw records the venv fingerprint of both interpreters" "  the driver's interpreter among them" \\
    "  with protobuf's version and implementation" "🔴 the raw records the code identity"
echo "    (round 5, M-2: 06 records 00_identity.txt -- red over every base before round 5; and that was the venv cells' base)"
'''),
])
# redfirst_b2 (base 17e40e29)
patch("redfirst_b2.sh", [
    (NDT_LOG_OLD + " \\", NDT_LOG_NEW + " \\"),
    ('"  said as the invariant, kept by every control" "  said as cut short" \\',
     '"  noted as the invariant, descriptive" "  said as cut short" \\'),
])
# redfirst_b3 (base 14921f98)
patch("redfirst_b3.sh", [
    ('''same_set "08 with the base's sampler and no v_restore_strict (M2, F9)" "$T/r" \\
    "H4 restore 19.9 s is within the strict 20 s" "H5 sampler rows"
''', '''same_set "08 with the base's sampler and no v_restore_strict (M2, F9)" "$T/r" \\
    "H4 restore 19.9 s is within the strict 20 s" "H5 sampler rows" "🔴 H5 sampler controllers column"
echo "    (round 5, M-3: the sampler records the exercise controllers alive -- red over the base's sampler, which has no such column)"
'''),
    ('''    "🔴 its own pid with a start it never had is DEAD, not alive"
''', '''    "🔴 its own pid with a start it never had is DEAD, not alive" \\
    ''' + APP_NEW + '''
''' + APP_WHY),
    ('''         "🔴 broken in the second control only: shown, not counted" \\
         "🔴 a last counter block that had not settled: rc 2" "🔴 an IPv4 packet-in shorter than its header: rc 2" \\
         "🔴 samples from a sampler before 09-28: rc 2" "🔴 samples without 06's end beside them: rc 2" \\
         "🔴 a treatment also given as a control: refused as such"; do''', '''         "  said as not settled" "  said as a sampler from before round 5" \\
         "🔴 a treatment also given as a control: refused as such"; do'''),
    ('''echo "    ('tunnel counters outside the controls': rc 1' is green over the base: its within() already ranged the"
echo "     counters with --control2; E45 turns it red)"''', '''echo "    (round 5: every compare in HEAD's suite names --b-sha, which this base does not take -- it answers usage, rc 2."
echo "     So the cells that only read an rc 2 are green over it by accident: 'a last counter block that had not settled',"
echo "     'an IPv4 packet-in shorter than its header', 'samples from a sampler before 09-28', 'samples without 06's end"
echo "     beside them'. The first and third are asked through their reason cells instead; the other two have none, and"
echo "     their red is the evidence gate's coverage report. 'broken in the second control only' is gone: round 5 made"
echo "     that invariant descriptive, and a decisive one broken in a control is UNDECIDED.)"'''),
    ('''i = s.index("mutate '    return 0 if not diffs else 1'")''', '''i = s.index("mutate '    return 1 if diffs else 2 if undecided else 0'")'''),
    ('''cp tests/shell/test_live_p1_external_evidence.sh "$G/tests/shell/"; cp "$LIVE/external_evidence.py" "$G/$LIVE/"''',
     '''cp tests/shell/test_live_p1_external_evidence.sh "$G/tests/shell/"; cp "$LIVE/external_evidence.py" "$LIVE/code_identity.py" "$G/$LIVE/"'''),
])
# redfirst_b4 (base 35b19663)
patch("redfirst_b4.sh", [
    ('''same_set "base ndt, the status row" "$T/r" "🔴 an external plane on its own pipeline expects no path" \\
    "  and does not call its count the twin's guess"
''', '''same_set "base ndt, the status row" "$T/r" "🔴 an external plane on its own pipeline expects no path" \\
    "  and does not call its count the twin's guess" \\
    ''' + APP_NEW + '''
''' + APP_WHY),
    (NDT_LOG_OLD + " \\", NDT_LOG_NEW + " \\"),
])
for n in ("redfirst_b.sh", "redfirst_b2.sh", "redfirst_b4.sh"):
    p = f"{A}/{n}"; s = open(p).read()
    # the reason, once, right after the ndt set that carries the new log cells
    i = s.index('"  in another file"'); j = s.index("\n", i)
    while s[j + 1:].startswith("    "):
        j = s.index("\n", j + 1)
    s = s[:j + 1] + NDT_LOG_WHY + s[j + 1:]
    open(p, "w").write(s)
print("patched")
