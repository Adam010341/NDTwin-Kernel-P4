#!/usr/bin/env bash
# s0_frozen_run.sh <log> <rundir> : S0 with a Frozen, WITHOUT bytecode suppression, in the gate clone ($PWD). Deliberately NOT through
# runlog.sh (runlog sets PYTHONDONTWRITEBYTECODE=1 for its child). The header lines are written here. [Co-developed with claude code -- Adam]
log="$1"; RUN="$2"; E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015
PYV=p4_proxy/venv/bin/python
stamp=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/c5aa4598-fe0a-45c1-9b2a-32bbb7b0496a/scratchpad/mg/tmp/s0frozen.stamp; : > "$stamp"
rm -rf "$RUN"
{ echo "commit $(git rev-parse HEAD)"
  echo "cwd $PWD  tracked-dirty=$(git status --porcelain --untracked-files=no | wc -l)  df_free_mb=$(df -m / | awk 'NR==2{print $4}')  mem_avail_mb=$(free -m | awk 'NR==2{print $7}')  LANG=${LANG:-} LC_ALL=${LC_ALL:-}  command: env -u PYTHONDONTWRITEBYTECODE $PYV $E/s0_with_frozen.py $PWD $RUN"
  echo "note: NOT run through runlog.sh (it sets PYTHONDONTWRITEBYTECODE=1); this process's own environment had PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE:-unset}, removed for the command by env -u"
  echo "interpreter $PYV -> $(realpath $PYV): $($PYV -c 'import sys; print("Python %s, prefix %s" % (sys.version.split()[0], sys.prefix))' 2>&1 | head -1)"
  echo "== env -u PYTHONDONTWRITEBYTECODE env | grep ^PYTHON  (the command's environment)"
  env -u PYTHONDONTWRITEBYTECODE env | grep ^PYTHON || echo "(no PYTHON* variable)"
  echo "== python sys.dont_write_bytecode in that environment: $(env -u PYTHONDONTWRITEBYTECODE $PYV -c 'import sys; print(sys.dont_write_bytecode)')"
  echo "== clone __pycache__ dirs before: $(find . -name __pycache__ -not -path './p4_proxy/venv/*' | wc -l)"
  echo "== output"; } > "$log"
env -u PYTHONDONTWRITEBYTECODE $PYV "$E/s0_with_frozen.py" "$PWD" "$RUN" >> "$log" 2>&1
rc=$?
{ echo "== find $RUN/exercise -name __pycache__ -o -name '*.pyc'  (empty = none)"; find "$RUN/exercise" \( -name __pycache__ -o -name '*.pyc' \) 2>&1
  echo "== end of find; files in the copy: $(find "$RUN/exercise" -type f 2>/dev/null | wc -l), dirs: $(find "$RUN/exercise" -type d 2>/dev/null | wc -l)"
  echo "== find $RUN/exercise (full listing)"; find "$RUN/exercise" 2>&1 | sort
  echo "== bytecode written elsewhere by this run: __pycache__ dirs in the clone now: $(find . -name __pycache__ -not -path './p4_proxy/venv/*' | wc -l)"
  find . -name __pycache__ -not -path './p4_proxy/venv/*' | sort | head -40
  echo "== .pyc under the shared venv (via the clone's symlink) newer than the start of this run: $(find p4_proxy/venv/ -name '*.pyc' -newer "$stamp" 2>/dev/null | wc -l)"
  echo "== git status --porcelain --untracked-files=no: $(git status --porcelain --untracked-files=no | wc -l) line(s)"; } >> "$log"
echo "rc=$rc" >> "$log"
exit $rc
