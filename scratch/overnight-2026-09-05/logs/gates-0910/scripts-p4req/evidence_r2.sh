#!/usr/bin/env bash
# Worker REQ, round 2 (judge finding #4 + orchestrator items 1, 2, 4): write to files, whole and
# untrimmed, what round 1's SUMMARY stated as OBSERVED but kept only in a terminal. Read-only
# towards the main checkout and its p4_proxy/venv (PYTHONDONTWRITEBYTECODE=1 for every python run
# here). Every log's line 1 carries the worktree HEAD (full sha) and the venv(s) involved.
# [Co-developed with claude code -- Adam]
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925
MAIN=/home/adam/Desktop/NDTwin-Kernel
MV=$MAIN/p4_proxy/venv
A2=$WT/scratch/venv-aligned2
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
L=$MAIN/scratch/overnight-2026-09-05/logs/gates-0910
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1
H=$(git -C "$WT" rev-parse HEAD); h=${H:0:8}
[[ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]] || { echo "REFUSE: tracked changes"; exit 2; }
out() { local f="$L/$1.p4req-$h.log"; [[ -e "$f" ]] && { echo "REFUSE: $f exists" >&2; exit 3; }; echo "$f"; }
fp() { find "$1" -type f -printf '%P %s %T@\n' | sort | sha256sum | cut -c1-64; }

# 1. main venv fingerprint: before (taken 2026-09-25 ~04:55Z, before this worker first ran it) and now
f=$(out mainvenv_fingerprint)
{ echo "# HEAD $H  venv $MV  (main checkout's p4_proxy/venv, READ-ONLY for this ticket)  $(date -u +%FT%TZ)"
  echo "# method: find <venv> -type f -printf '%P %s %T@\\n' | sort | sha256sum   (path, size, mtime of every file)"
  echo "# BEFORE: file $SP/mainvenv.before.sha, written $(stat -c '%y' "$SP/mainvenv.before.sha") -- before this worker's first use of the venv (first suite log: p4_proxy_suite_mainvenv.p4req-62f76cf5.log, $(sed -n 2p "$L/p4_proxy_suite_mainvenv.p4req-62f76cf5.log" | grep -o '20[0-9-]*T[0-9:]*Z'))"
  echo "BEFORE $(cut -c1-64 "$SP/mainvenv.before.sha")"
  echo "NOW    $(fp "$MV")"
  echo "# files newer than the stamp written at the same moment as BEFORE ($SP/mainvenv.stamp):"
  find "$MV" -newer "$SP/mainvenv.stamp" | sed 's/^/  /'; echo "# (end of list)"
} > "$f"

# 2. main venv: raw pip check / pip freeze / backend
f=$(out mainvenv_pip_check)
{ echo "# HEAD $H  venv $MV  interpreter $(readlink -f "$MV/bin/python")  $(date -u +%FT%TZ)"
  echo "# \$ $MV/bin/python -m pip check"; "$MV/bin/python" -m pip check 2>&1; echo "# rc=$?"
  echo "# \$ $MV/bin/python -m pip freeze"; "$MV/bin/python" -m pip freeze 2>&1
  echo "# \$ protobuf backend"; "$MV/bin/python" -c 'from google.protobuf.internal import api_implementation as a; print(a.Type())'
  echo "# \$ grep Requires-Dist googleapis_common_protos-1.75.0.dist-info/METADATA"
  grep '^Requires-Dist' "$MV"/lib/python3.13/site-packages/googleapis_common_protos-1.75.0.dist-info/METADATA
  echo "# \$ head -20 site-packages/google/rpc/status_pb2.py (1.75.0's gencode, why it imports on 3.20.3)"
  head -20 "$MV"/lib/python3.13/site-packages/google/rpc/status_pb2.py
  echo "# dist-info mtimes (install history):"
  ls -la --time-style=full-iso "$MV"/lib/python3.13/site-packages | grep dist-info | awk '{print $6, $7, $9}' | sort
} > "$f"

# 3. the p4_src/build copy
f=$(out build_copy_hashes)
{ echo "# HEAD $H  venv n/a  $(date -u +%FT%TZ)"
  echo "# the worktree has no p4_src/build (gitignored); round 1 COPIED the main checkout's, cp -p"
  sha256sum "$MAIN"/p4_proxy/p4_src/build/* "$WT"/p4_proxy/p4_src/build/*
  ls -l --time-style=full-iso "$MAIN"/p4_proxy/p4_src/build/ "$WT"/p4_proxy/p4_src/build/
  echo "# cmp:"; for x in ndtwin_switch.json ndtwin_switch.p4info.txt; do
      cmp "$MAIN/p4_proxy/p4_src/build/$x" "$WT/p4_proxy/p4_src/build/$x" && echo "  $x identical"; done
} > "$f"

# 4. PyPI: which versions exist (raw)
f=$(out pip_index_versions)
{ echo "# HEAD $H  venv $A2 (its pip, a query only)  $(date -u +%FT%TZ)"
  for p in p4runtime protobuf googleapis-common-protos grpcio grpcio-tools starlette fastapi; do
      echo "# \$ pip index versions $p"; "$A2/bin/python" -m pip index versions "$p" 2>&1; echo "# rc=$?"; done
} > "$f"

# 5. googleapis-common-protos: what pip resolves with the pin REMOVED, and the declared protobuf
#    range of the releases around it (dry runs; nothing installed)
f=$(out googleapis_resolution)
grep -v '^googleapis-common-protos==' "$WT/p4_proxy/requirements.txt" > "$SP/req.nogapi.txt"
{ echo "# HEAD $H  venv $A2 (dry runs, --ignore-installed; nothing installed)  $(date -u +%FT%TZ)"
  echo "# requirements = HEAD's p4_proxy/requirements.txt minus its googleapis-common-protos line:"
  diff "$WT/p4_proxy/requirements.txt" "$SP/req.nogapi.txt" | sed 's/^/#   /'
  echo "# \$ pip install --dry-run --ignore-installed --report - -r req.nogapi.txt   (resolved set)"
  (cd "$SP" && "$A2/bin/python" -m pip install --dry-run --ignore-installed --quiet --report "$SP/nogapi.json" -r "$SP/req.nogapi.txt" 2>&1; echo "# rc=$?")
  "$A2/bin/python" -c "
import json; r=json.load(open('$SP/nogapi.json'))
for i in r['install']: print('  resolved', i['metadata']['name'], i['metadata']['version'])"
  for v in 1.73.0 1.73.1 1.74.0 1.75.0 1.75.4; do
      (cd "$SP" && "$A2/bin/python" -m pip install --dry-run --ignore-installed --no-deps --quiet \
          --report "$SP/gapi-$v.json" "googleapis-common-protos==$v" 2>&1)
      "$A2/bin/python" -c "
import json; r=json.load(open('$SP/gapi-$v.json')); m=r['install'][0]['metadata']
print('  declared', m['name'], m['version'], [d for d in m.get('requires_dist', []) if d.startswith('protobuf')])"
  done
} > "$f"

# 6. round 1's per-test diffs, whole (round 1 printed them to a terminal; one trimmed copy kept)
f=$(out verdict_diffs_round1)
{ echo "# HEAD $H (this round); the TSVs diffed are round 1's, at the shas their names carry  $(date -u +%FT%TZ)"
  for pair in "55cebe6c main aligned" "55cebe6c main pb5_pyimpl" "55cebe6c main pb5_upb" \
              "55cebe6c main pb5_regen" "7cc50b42 main cand"; do
      set -- $pair
      for suite in p4_proxy_suite p4_exercise_suite; do
          a="$L/${suite}_verdicts_$2.p4req-$1.tsv"; b="$L/${suite}_verdicts_$3.p4req-$1.tsv"
          echo "== $suite @$1: $2 vs $3"
          for t in "$a" "$b"; do [[ -s "$t" ]] || echo "   NO VERDICT FILE: $(basename "$t") (the suite did not load)"; done
          if [[ -s "$a" && -s "$b" ]]; then
              echo "# \$ diff $(basename "$a") $(basename "$b")"; d=$(diff "$a" "$b"); printf '%s\n' "$d"
              echo "# diff lines (<,>): $(printf '%s' "$d" | grep -c '^[<>]');  ids: $(wc -l < "$a") vs $(wc -l < "$b")"
          fi
      done
  done
} > "$f"

# 7. freeze diff main vs aligned2, whole
f=$(out freeze_main_vs_aligned2)
{ echo "# HEAD $H  A venv $MV  B venv $A2  $(date -u +%FT%TZ)"
  "$MV/bin/python" -m pip freeze > "$SP/fz.main.r2"; "$A2/bin/python" -m pip freeze > "$SP/fz.a2.r2"
  echo "# \$ diff <(main pip freeze) <(aligned2 pip freeze)"; diff "$SP/fz.main.r2" "$SP/fz.a2.r2"; echo "# rc=$?"
} > "$f"

# 8. check_pins: three files against the main venv's freeze, and HEAD's file against aligned2
for spec in "62f76cf5 $MV main" "55cebe6c $MV main" "$h $MV main" "$h $A2 aligned2"; do
    set -- $spec
    git -C "$WT" show "$1:p4_proxy/requirements.txt" > "$SP/req.$1.txt"
    "$2/bin/python" -m pip freeze > "$SP/fz.$3.pins"
    f=$(out "check_pins_file-$1_vs_$3")
    { echo "# HEAD $H  venv $2  file = $(git -C "$WT" rev-parse "$1"):p4_proxy/requirements.txt  $(date -u +%FT%TZ)"
      echo "# \$ python3 check_pins_vs_venv.py <file> <pip freeze of $2> --allow googleapis-common-protos"
      python3 "$HERE/check_pins_vs_venv.py" "$SP/req.$1.txt" "$SP/fz.$3.pins" --allow googleapis-common-protos; echo "# rc=$?"
    } > "$f" 2>&1
done

# 9. import coverage: old, round-1 and HEAD files (must be RED, RED, GREEN) + two negative controls
grep -v '^requests==' "$SP/req.$h.txt" > "$SP/req.$h.minus-requests.txt"
grep -v '^starlette==' "$SP/req.$h.txt" > "$SP/req.$h.minus-starlette.txt"
for spec in "62f76cf5 req.62f76cf5.txt" "55cebe6c req.55cebe6c.txt" "$h req.$h.txt" \
            "$h-minus-requests req.$h.minus-requests.txt" "$h-minus-starlette req.$h.minus-starlette.txt"; do
    set -- $spec
    f=$(out "check_imports_file-$1")
    { echo "# HEAD $H  venv $MV (the tested environment: its distributions map imports to packages)  $(date -u +%FT%TZ)"
      echo "# file: $2 ($( [[ $1 == *minus* ]] && echo "HEAD's file with one line removed -- a negative control" || echo "git show ${1}:p4_proxy/requirements.txt"))"
      echo "# \$ $MV/bin/python check_imports_vs_requirements.py $WT <file>"
      (cd "$SP" && "$MV/bin/python" "$HERE/check_imports_vs_requirements.py" "$WT" "$SP/$2"); echo "# rc=$?"
    } > "$f" 2>&1
done

# 10. the scripts: round 1's SHA256SUMS still verifies (v2 copies), then this round's sums
f=$(out scripts_sha256)
{ echo "# HEAD $H  venv n/a  $(date -u +%FT%TZ)"
  echo "# \$ (cd scripts-p4req) sha256sum -c SHA256SUMS   (written at the end of round 1)"
  (cd "$HERE" && sha256sum -c SHA256SUMS 2>&1); echo "# rc=$?"
  echo "# the round-1 (v2) texts of the two scripts changed in round 2 are kept as *.v2.*:"
  (cd "$HERE" && for x in run_suites compare_verbose; do
      printf '  %s.v2.sh %s ; SHA256SUMS says %s\n' "$x" "$(sha256sum $x.v2.sh | cut -c1-64)" "$(grep " $x.sh\$" SHA256SUMS | cut -c1-64)"; done)
  (cd "$HERE" && sha256sum *.sh *.py > SHA256SUMS.r2 && echo "# SHA256SUMS.r2 written:" && cat SHA256SUMS.r2)
} > "$f"
echo "evidence_r2 $h: done"; ls -1 "$L"/*.p4req-$h.log | wc -l
