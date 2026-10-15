#!/usr/bin/env bash
# runlog.sh <log> <cmd...> : line 1 commit, then cwd/dirty/df/locale/command, the interpreter, the p4c version and the
# sha256 of both P4 build outputs in this clone, then the output, last line rc=N. Runs in $PWD (the clone).
# [Co-developed with claude code -- Adam]
log="$1"; shift
{ echo "commit $(git rev-parse HEAD)"
  echo "cwd $PWD  tracked-dirty=$(git status --porcelain --untracked-files=no | wc -l)  df_free_mb=$(df -m / | awk 'NR==2{print $4}')  LANG=${LANG:-} LC_ALL=${LC_ALL:-}  command: $*"
  echo "interpreter $(realpath p4_proxy/venv/bin/python 2>/dev/null): $(p4_proxy/venv/bin/python --version 2>&1 | head -1)"
  echo "command's own program $(realpath "$(command -v "$1")" 2>/dev/null || echo "$1"): $("$1" --version 2>&1 | head -1)"
  echo "p4c $(command -v p4c-bm2-ss): $(p4c-bm2-ss --version 2>&1 | tr '\n' ' ')"
  echo "p4 build: $(sha256sum p4_proxy/p4_src/build/ndtwin_switch.json | cut -c1-64) ndtwin_switch.json  $(sha256sum p4_proxy/p4_src/build/ndtwin_switch.p4info.txt | cut -c1-64) ndtwin_switch.p4info.txt"; } > "$log"
PYTHONDONTWRITEBYTECODE=1 "$@" >> "$log" 2>&1
rc=$?
echo "rc=$rc" >> "$log"
exit $rc
