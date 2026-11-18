#!/usr/bin/env bash
#
# `ndt python [args]`: python3 with this checkout's SDK (sdk/python) first on its path.
#
# [Co-developed with claude code -- Adam]
#
# The command replaces a virtual environment and an install, so what it must get right is which
# `ndtwin` an app imports: this checkout's, whatever else is on PYTHONPATH (Y1, Y2). The rest is that
# it stays an interpreter -- python's exit code, arguments and stdin pass through (Y3) -- that it
# refuses a Python older than the SDK supports before running anything (Y4), and that it asks the lab
# for nothing (Y5).
#
# Runs the real `ndt` as an executable (the dispatch line is part of what is tested). No lab, no
# sudo: a fake `sudo` first on PATH records any call, and Y5 asserts there was none.
#
# Run:  bash tests/shell/test_ndt_python.sh
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points it at a mutated copy; that copy's tree must
#                                carry sdk/python/ndtwin, since the SDK found is the one beside ndt)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
[[ -x "$NDT" ]] || { echo "no executable ndt at $NDT"; exit 2; }
NDT_TREE="$(cd "$(dirname "$(readlink -f "$NDT")")/../.." && pwd)"
[[ -f "$NDT_TREE/sdk/python/ndtwin/__init__.py" ]] || {
    echo "the tree of $NDT has no sdk/python/ndtwin -- nothing to find"; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 2; }

PASS=0; FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: %s\n             actual:   %s\n' "$1" "$2" "$3"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/ndt-python-XXXXXX")"
trap 'rm -rf "$T"' EXIT
FAKES="$T/bin"; mkdir -p "$FAKES"
CALLS="$T/sudo.calls"; : > "$CALLS"
# A sudo that runs nothing and writes down that it was asked.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\necho "sudo: a password is required" >&2\nexit 1\n' "$CALLS" > "$FAKES/sudo"
chmod +x "$FAKES/sudo"
export PATH="$FAKES:$PATH"
want="$NDT_TREE/sdk/python/ndtwin/__init__.py"

echo "Y1 the SDK found is this checkout's"
got="$(cd "$T" && env -u PYTHONPATH "$NDT" python -c 'import ndtwin; print(ndtwin.__file__)' 2>&1)"
check "from another directory: ndtwin is sdk/python of the tree ndt is in" "$want" "$got"
got="$(cd "$NDT_TREE" && env -u PYTHONPATH "$NDT" python -c 'import ndtwin; print(ndtwin.__file__)' 2>&1)"
check "from the checkout root: the same file" "$want" "$got"

echo "Y2 an ndtwin elsewhere on PYTHONPATH does not win"
mkdir -p "$T/decoy/ndtwin"
echo 'DECOY = True' > "$T/decoy/ndtwin/__init__.py"
got="$(cd "$T" && PYTHONPATH="$T/decoy" "$NDT" python -c 'import ndtwin; print(ndtwin.__file__)' 2>&1)"
check "a decoy package already on PYTHONPATH -> still this checkout's" "$want" "$got"
got="$(cd "$T" && PYTHONPATH="$T/decoy" "$NDT" python -c 'import sys; print(sys.path.index("'"$T"'/decoy") > sys.path.index("'"$NDT_TREE"'/sdk/python"))' 2>&1)"
check "and the caller's own entry is kept, after the SDK" "True" "$got"

echo "Y3 an interpreter: exit code, arguments and stdin are python's"
(cd "$T" && "$NDT" python -c 'raise SystemExit(7)' >/dev/null 2>&1); rc=$?
check "SystemExit(7) -> 7" "7" "$rc"
got="$(cd "$T" && "$NDT" python -c 'import sys; print(len(sys.argv), sys.argv[1])' 'two words' 2>&1)"
check "an argument with a space arrives whole" "2 two words" "$got"
got="$(cd "$T" && printf 'from stdin\n' | "$NDT" python -c 'import sys; print(sys.stdin.read().strip())' 2>&1)"
check "stdin reaches the script" "from stdin" "$got"
printf 'import sys\nprint("script", sys.argv[1:])\n' > "$T/app.py"
got="$(cd / && "$NDT" python "$T/app.py" --dry-run 2>&1)"
check "a script file and its options" "script ['--dry-run']" "$got"

echo "Y4 a python3 older than the SDK's floor is refused, and nothing runs"
# The floor is the SDK's own: requires-python in the pyproject.toml of the sdk the ndt under test uses,
# not a number written here, so a change to the floor that ndt does not follow is caught.
FMAJ=""; FMIN=""
read -r FMAJ FMIN <<<"$(sed -n 's/^requires-python *= *">=\([0-9][0-9]*\)\.\([0-9][0-9]*\)".*/\1 \2/p' "$NDT_TREE/sdk/python/pyproject.toml" 2>/dev/null)"
check "requires-python (>=MAJOR.MINOR) was read from sdk/python/pyproject.toml" "yes" "$([[ -n "$FMAJ" && -n "$FMIN" ]] && echo yes || echo no)"
: "${FMAJ:=3}" "${FMIN:=10}"
BELOW="$FMAJ.$((FMIN - 1))"; FLOOR="$FMAJ.$FMIN"
OLD="$T/old"; mkdir -p "$OLD"
# Answers the version probe as one minor below the floor and writes down anything else it is asked to run.
printf '#!/usr/bin/env bash\nif [[ "$1" == -c && "$2" == *version_info* ]]; then echo "%s %s"; exit 0; fi\necho RAN >> %q\n' "$FMAJ" "$((FMIN - 1))" "$T/old.ran" > "$OLD/python3"
chmod +x "$OLD/python3"
out="$(cd "$T" && PATH="$OLD:$PATH" "$NDT" python "$T/app.py" 2>&1)"; rc=$?
check "a Python one minor below requires-python -> rc 5" "5" "$rc"
check "the script was not run" "no" "$([[ -s "$T/old.ran" ]] && echo yes || echo no)"
check "the refusal names the version and the floor" "yes" \
    "$([[ "$out" == *"Python $BELOW"*"$FLOOR or newer"* ]] && echo yes || echo no)"
# The control: the same fake answering the floor itself runs the script -- a check that refused
# everything would pass the three lines above.
printf '#!/usr/bin/env bash\nif [[ "$1" == -c && "$2" == *version_info* ]]; then echo "%s %s"; exit 0; fi\necho RAN >> %q\n' "$FMAJ" "$FMIN" "$T/new.ran" > "$OLD/python3"
(cd "$T" && PATH="$OLD:$PATH" "$NDT" python "$T/app.py" >/dev/null 2>&1); rc=$?
check "control: requires-python's own version is accepted and the script runs (rc 0)" "0 yes" "$rc $([[ -s "$T/new.ran" ]] && echo yes || echo no)"

echo "Y5 no sudo call"
check "the fake sudo was never called" "" "$(cat "$CALLS")"

echo "Y6 the usage text names the command"
out="$("$NDT" help 2>&1)"
check "'ndt help' lists 'python [args]'" "yes" "$([[ "$out" == *"python [args]"* ]] && echo yes || echo no)"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
