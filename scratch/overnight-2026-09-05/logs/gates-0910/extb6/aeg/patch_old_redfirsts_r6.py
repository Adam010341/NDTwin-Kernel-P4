# patch_old_redfirsts_r6.py -- round 6's cells in the expected sets of redfirst_b, b3 and b5 (HEAD's suites now
# carry them; over every older base they are red, or their old names are gone). Each change prints its reason in
# the script it patches. [Co-developed with claude code -- Adam]
import sys
A = sys.argv[1]
def patch(name, pairs):
    p = f"{A}/{name}"; s = open(p).read()
    for a, b in pairs:
        assert s.count(a) == 1, (name, a[:70], s.count(a))
        s = s.replace(a, b)
    open(p, "w").write(s)
ID_NEW = '"🔴 the raw records the code identity as 06 starts" "🔴 and again as it ends, after the last round wrote its table row"'
ID_WHY = ('echo "    (round 6, M-2: 06 records its identity as it starts and as it ends -- the one round-5 cell is now two,'
          ' red over every base before round 6)"\n')
patch("redfirst_b.sh", [
    ('''    "  with protobuf's version and implementation" "🔴 the raw records the code identity"
''', '''    "  with protobuf's version and implementation" ''' + ID_NEW + "\n" + ID_WHY),
])
patch("redfirst_b5.sh", [
    ('''same_set "base 06" "$T/r" "🔴 the raw records the code identity"
''', '''same_set "base 06" "$T/r" ''' + ID_NEW + "\n" + ID_WHY),
    ('''for want in "🔴 a direction not heard while the controller ran: rc 3" "🔴 no --b-sha: rc 3" \\''',
     '''for want in "🔴 every direction heard in the controller's window, said per direction" "🔴 no --b-sha: rc 3" \\'''),
    ('''echo "REDFIRST-B5:''', '''echo "    (round 6, M-3: the heard cells are now about the controller's own window; the one named here is a"
echo "     has-check, red over this base, which answers usage to every compare)"
echo "REDFIRST-B5:'''),
])
patch("redfirst_b3.sh", [
    ('''    "H4 restore 19.9 s is within the strict 20 s" "H5 sampler rows" "🔴 H5 sampler controllers column"
''', '''    "H4 restore 19.9 s is within the strict 20 s" "H5 sampler rows" "🔴 H5 sampler controllers column" \\
    "🔴 H5 sampler ctrl_logs column"
echo "    (round 6, M-3: the sampler records the controller logs' sizes -- red over the base's sampler, which has no such column)"
'''),
    ('''         "  said as not settled" "  said as a sampler from before round 5" \\''',
     '''         "  said as not settled" "  said as a sampler from before round 6" \\'''),
    ('''keep = "\\n".join(blk for blk in calls.split("\\nmutate") if blk.startswith("_id() {")).strip()
out = head + s[i:j] + ("\\nmutate" + keep if keep else "") + s[end:]
assert out.count("\\nmutate '") + out.count("\\nmutate_id '") == 1, out.count("\\nmutate '")''',
     '''# (round 6: and the mutate_sv function, the survey's)
keep = "\\n".join("mutate" + blk for blk in calls.split("\\nmutate") if blk.startswith(("_id() {", "_sv() {"))).strip()
out = head + s[i:j] + ("\\n" + keep if keep else "") + s[end:]
assert out.count("\\nmutate '") + out.count("\\nmutate_id '") + out.count("\\nmutate_sv '") == 1, out.count("\\nmutate '")'''),
    ('''cp tests/shell/test_live_p1_external_evidence.sh "$G/tests/shell/"; cp "$LIVE/external_evidence.py" "$LIVE/code_identity.py" "$G/$LIVE/"''',
     '''cp tests/shell/test_live_p1_external_evidence.sh "$G/tests/shell/"; cp "$LIVE/external_evidence.py" "$LIVE/code_identity.py" "$G/$LIVE/"
cp "$LIVE/external_survey.py" "$LIVE/external_survey_34.tsv" "$G/$LIVE/"   # round 6: the survey beside the tool'''),
])
print("patched redfirst_b, b3, b5")
