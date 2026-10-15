#!/usr/bin/env bash
# runlog.sh <log> <cmd...> : line 1 commit, then cwd/dirty/df/locale/command, the interpreter, then the output, last line rc=N.
# Runs in $PWD (the throwaway clone). [Co-developed with claude code -- Adam]
log="$1"; shift
{ echo "commit $(git rev-parse HEAD)"
  echo "cwd $PWD  tracked-dirty=$(git status --porcelain --untracked-files=no | wc -l)  df_free_mb=$(df -m / | awk 'NR==2{print $4}')  mem_avail_mb=$(free -m | awk 'NR==2{print $7}')  LANG=${LANG:-} LC_ALL=${LC_ALL:-}  command: $*"
  echo "interpreter $(realpath p4_proxy/venv/bin/python 2>/dev/null): $(p4_proxy/venv/bin/python --version 2>&1 | head -1)"; } > "$log"
PYTHONDONTWRITEBYTECODE=1 "$@" >> "$log" 2>&1
rc=$?
echo "rc=$rc" >> "$log"
exit $rc
