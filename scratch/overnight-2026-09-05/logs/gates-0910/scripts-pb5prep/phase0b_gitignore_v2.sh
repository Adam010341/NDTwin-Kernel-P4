#!/usr/bin/env bash
# Worker pb5prep, phase 0b: .gitignore red/green, v2. v1 (in phase0_prep.sh) chose
# p4_proxy/venv.protobuf3-*/bin/python as the parked venv's sample path, and that one is already
# ignored at trunk by the generic `bin/` rule (.gitignore:10) -- so v1 printed rc=1 against its own
# wrong expectation, while the rest of the parked venv (pyvenv.cfg, lib/...) was NOT ignored. v2
# samples paths no other rule covers. v1's log is kept as it was written.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
f=$(new_log gitignore_venv_parking_redgreen_v2 "git check-ignore on the parked-venv paths: .gitignore of $TRUNK (RED expected) vs HEAD (GREEN); v2 sample paths") || exit 2
tmp=$(mktemp -d "$W/gi.XXXXXX"); rc=0
paths=(p4_proxy/venv.protobuf3-20260926/pyvenv.cfg
       p4_proxy/venv.protobuf3-20260926/lib/python3.13/site-packages/google/protobuf/__init__.py
       p4_proxy/venv.protobuf3-20260926.freeze
       p4_proxy/venv.protobuf3-20260926.fingerprint
       p4_proxy/venv.failed-20260926120000/pyvenv.cfg)
{
  git -C "$tmp" init -q
  declare -A n
  for rev in "$TRUNK" "$FULL"; do
      git -C "$WT" show "$rev:.gitignore" > "$tmp/.gitignore"
      echo "== .gitignore @ $rev"; n[$rev]=0
      for p in "${paths[@]}"; do
          if m=$(git -C "$tmp" check-ignore -v --no-index "$p"); then echo "  IGNORED      $p   ($m)"; n[$rev]=$((n[$rev]+1))
          else echo "  NOT IGNORED  $p"; fi
      done
  done
  t=$(git -C "$WT" ls-files 'p4_proxy/venv.*' | wc -l)
  echo "RESULT trunk: ${n[$TRUNK]} of ${#paths[@]} ignored (want 0 = RED); HEAD: ${n[$FULL]} of ${#paths[@]} (want ${#paths[@]} = GREEN); tracked files matching p4_proxy/venv.*: $t (want 0)"
  [[ ${n[$TRUNK]} == 0 && ${n[$FULL]} == "${#paths[@]}" && $t == 0 ]] || rc=1
} >> "$f" 2>&1
rm -rf "$tmp"; echo "rc=$rc" >> "$f"; cat "$f"
