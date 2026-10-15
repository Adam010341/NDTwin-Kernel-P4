#!/usr/bin/env bash
# runlog.sh <log> <cmd...> : line 1 commit, then cwd/dirty/df/locale/command, then the interpreter THIS command runs
# (its first word when that is a python, else that word's version; a PYTHON in the environment is named too), then
# the output, last line rc=N. $NOTE, when set, is a line after the command (what was changed in the clone).
# Runs in $PWD (the throwaway clone). [Co-developed with claude code -- Adam]
log="$1"; shift
interp_line() {
    local w="$1" r
    if [[ "$w" == env ]]; then shift; while [[ "$1" == *=* ]]; do shift; done; w="$1"; fi
    r="$(realpath "$(command -v "$w" 2>/dev/null || echo "$w")" 2>/dev/null)"
    case "$(basename "$w")" in
        python*) echo "interpreter $w -> $r: $("$w" -c 'import sys; print("Python %s, prefix %s" % (sys.version.split()[0], sys.prefix))' 2>&1 | head -1)";;
        *) echo "interpreter $w -> $r: $("$w" --version 2>&1 | head -1)";;
    esac
    [[ -n "${PYTHON:-}" ]] && echo "PYTHON=$PYTHON -> $(realpath "$PYTHON" 2>/dev/null): $("$PYTHON" -c 'import sys; print("Python %s, prefix %s" % (sys.version.split()[0], sys.prefix))' 2>&1 | head -1)"
    return 0
}
{ echo "commit $(git rev-parse HEAD)"
  echo "cwd $PWD  tracked-dirty=$(git status --porcelain --untracked-files=no | wc -l)  df_free_mb=$(df -m / | awk 'NR==2{print $4}')  mem_avail_mb=$(free -m | awk 'NR==2{print $7}')  LANG=${LANG:-} LC_ALL=${LC_ALL:-}  command: $*"
  [[ -n "${NOTE:-}" ]] && echo "note: $NOTE"
  interp_line "$@"; } > "$log"
PYTHONDONTWRITEBYTECODE=1 "$@" >> "$log" 2>&1
rc=$?
echo "rc=$rc" >> "$log"
exit $rc
