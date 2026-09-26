#!/usr/bin/env bash
# Segment W: what mutate_roles_binding.sh's "1 survived" is, read from this round's log of it.
# Passes only if (1) every mutant was caught, (2) the first cut's new tests were all seen red,
# (3) the sources were restored, and (4) the one survivor is its NEW_CLASSES scan (pinned to the
# first cut's base 6291db35) listing EXACTLY the test classes this branch added since 580767a8 --
# computed here from git with the gate's own AST rule, not remembered. [Co-developed with claude
# code -- Adam]
set -u
WT="$1"; LOG="$2"; bad=0
echo "HEAD $(git -C "$WT" rev-parse HEAD)   log $LOG"
[[ -s "$LOG" ]] || { echo "no log"; exit 2; }
summary=$(/usr/bin/grep -E '^mutation gate: [0-9]+ mutations, [0-9]+ survived' "$LOG" | tail -1)
n=$(sed -E 's/^mutation gate: ([0-9]+) mutations.*/\1/' <<<"$summary")
s=$(sed -E 's/.* ([0-9]+) survived.*/\1/' <<<"$summary")
c=$(/usr/bin/grep -c '^  caught ' "$LOG")
echo "gate summary: $summary; caught lines: $c"
[[ "$s" == 1 ]] || { echo "  BAD survivors $s (this check explains exactly one)"; bad=1; }
[[ -n "$n" && "$c" == "$n" ]] && echo "  ok    every one of the $n mutants caught" || { echo "  BAD   caught $c of $n"; bad=1; }
/usr/bin/grep -qE '^every new test seen red: ([0-9]+) of \1$' "$LOG" \
    && echo "  ok    $(/usr/bin/grep -E '^every new test seen red' "$LOG")" || { echo "  BAD   not every first-cut test seen red"; bad=1; }
/usr/bin/grep -q '^baseline byte-identical: yes' "$LOG" \
    && echo "  ok    $(/usr/bin/grep '^baseline byte-identical' "$LOG")" || { echo "  BAD   sources not restored"; bad=1; }
listed=$(sed -n '/NEW_CLASSES omits class(es) added since 6291db35/,/^$/p' "$LOG" | sed -n 's/^ *\(tests\.[^ ]*\|test_[^ ]*\)$/\1/p' | sort)
added=$(cd "$WT" && python3 - <<'PY'
import ast, glob, os, subprocess
def classes(src):
    return {n.name for n in ast.parse(src).body if isinstance(n, ast.ClassDef)
            and any(isinstance(f, ast.FunctionDef) and f.name.startswith("test") for f in n.body)}
out = []
for d, pref in (("p4_proxy/tests", "tests."), ("tools/p4_exercise/tests", "")):
    names = subprocess.run(["git", "ls-tree", "--name-only", "HEAD", d + "/"], capture_output=True,
                           text=True, check=True).stdout.split()
    for rel in sorted(r for r in names if os.path.basename(r).startswith("test_") and r.endswith(".py")):
        now = classes(subprocess.run(["git", "show", f"HEAD:{rel}"], capture_output=True, text=True).stdout)
        r = subprocess.run(["git", "show", f"580767a8:{rel}"], capture_output=True, text=True)
        then = classes(r.stdout) if r.returncode == 0 else set()
        out += [f"{pref}{os.path.basename(rel)[:-3]}:{c}" for c in sorted(now - then)]
print("\n".join(sorted(out)))
PY
)
echo "  the gate's omitted list: $(wc -l <<<"$listed") class(es); this branch added since 580767a8: $(wc -l <<<"$added")"
if [[ -n "$listed" && "$listed" == "$added" ]]; then
    echo "  ok    identical: the survivor is the first cut's class scan counting this segment's classes"
else
    echo "  BAD   they differ:"; diff <(printf '%s\n' "$listed") <(printf '%s\n' "$added") | sed 's/^/        /'; bad=1
fi
echo "ROLES-BINDING-SURVIVOR: $([[ $bad == 0 ]] && echo 'the one survivor is the class scan, and only this segment'"'"'s classes' || echo UNEXPLAINED)"
exit $bad
