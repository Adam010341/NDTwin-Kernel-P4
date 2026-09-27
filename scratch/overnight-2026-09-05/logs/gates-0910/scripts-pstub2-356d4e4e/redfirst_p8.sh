#!/usr/bin/env bash
# redfirst_p8.sh <worktree> <keep dir> -- (a)'s P8 hermetic assertion seen red: a copy of HEAD's
# mutate_probe_stubs.sh whose own recording sudo still refuses every call but records them NOWHERE
# (>> /dev/null) -- the escape reaches nothing. P8 must then NOT be caught ("no call reached this
# gate's sudo") and the gate must fail; P1-P7 and the baseline are unaffected. Nothing leaves the
# recorder either way, so the outer tripwire stays 0. [Co-developed with claude code -- Adam]
set -u
WT="$1"; K="$2"; bad=0; cd "$WT" || exit 2; mkdir -p "$K"
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
echo "HEAD $(git rev-parse HEAD)"
c="tests/shell/.redfirst-p8-mutate_probe_stubs.sh"; trap 'rm -f "$WT/$c"' EXIT
python3 - tests/shell/mutate_probe_stubs.sh "$c" <<'PY' || { echo "REFUSE: the recorder line moved"; exit 2; }
import sys
s = open(sys.argv[1]).read()
a = """printf 'sudo %s\\n' "\\$*" >> '$ESC/escaped'"""
assert s.count(a) == 1, s.count(a)
open(sys.argv[2], "w").write(s.replace(a, """printf 'sudo %s\\n' "\\$*" >> /dev/null"""))
PY
diff tests/shell/mutate_probe_stubs.sh "$c" | sed 's/^/    diff: /'
bash "$c" < /dev/null > "$K/p8_escape_to_nowhere.out" 2>&1; rc=$?
echo "    the gate with its recorder writing nowhere: rc $rc, $(tail -1 "$K/p8_escape_to_nowhere.out")"
/usr/bin/grep -E '^  (caught|SURVIVED) +P[0-9]' "$K/p8_escape_to_nowhere.out" | sed 's/^/    /' | cut -c1-170
[[ $rc != 0 ]] && ok "the gate fails" || nok "the gate passed with P8's escape going nowhere"
/usr/bin/grep -qE "^  SURVIVED P8: .*no call reached this gate's sudo" "$K/p8_escape_to_nowhere.out" \
    && ok "P8 is not caught: no call reached this gate's sudo" || nok "P8 was not reported as an escape to nowhere"
[[ "$(/usr/bin/grep -cE '^  caught +P[1-7]:' "$K/p8_escape_to_nowhere.out")" == 7 ]] && ok "P1-P7 still caught" || nok "P1-P7 changed"
echo "P8-RED-FIRST: $([[ $bad == 0 ]] && echo 'an escape that reaches nothing is not a kill' || echo BROKEN)"
exit $bad
