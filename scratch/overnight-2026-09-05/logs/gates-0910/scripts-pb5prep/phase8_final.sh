#!/usr/bin/env bash
# Worker pb5prep, phase 8: the cheap gates again on the final HEAD, and what the branch would
# publish. (a) the procedure's commands at HEAD are byte-identical to those rehearsed at 08483aa5,
# and 08483aa5..HEAD changes comment lines only; (b) check_gate_anchors.py HEAD; (c) the one test
# that reads stack.sh's P4-interpreter message block, tests/shell/test_up_ovs_wedge_guard.sh;
# (d) the branch's added lines scanned for secrets and local paths (p4/lab are public remotes).
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
cd "$WT" || exit 2
f=$(new_log final_gates "procedure identity vs 08483aa5, gate anchors, wedge-guard test, publication scan") || exit 2
rc=0
{
  echo "== (a) procedure commands, 08483aa5 vs HEAD"
  for rev in 08483aa5 HEAD; do git show "$rev:p4_proxy/requirements.txt" | grep -E '^#   \$ ' > "$W/proc.$rev.txt"; done
  python3 "$S/gen_rehearsal.py" <(git show HEAD:p4_proxy/requirements.txt) forward X Y "$W/final.vars" "$W/final_fwd.sh" || rc=1
  if cmp "$W/proc.08483aa5.txt" "$W/proc.HEAD.txt"; then echo "identical: $(wc -l < "$W/proc.HEAD.txt") command lines"; else echo "DIFFER"; rc=1; fi
  echo "non-comment lines changed 08483aa5..HEAD in tracked files:"
  n=$(git diff 08483aa5 HEAD | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-]#' | wc -l); echo "  $n"; [[ $n == 0 ]] || rc=1
  echo "== (b) check_gate_anchors.py HEAD"
  python3 tests/shell/check_gate_anchors.py HEAD 2>&1 | tail -2; [[ ${PIPESTATUS[0]} == 0 ]] || rc=1
  echo "== (c) tests/shell/test_up_ovs_wedge_guard.sh (through the guard)"
  JOBS=1 LOCK_WAIT=10800 "$GUARD" bash tests/shell/test_up_ovs_wedge_guard.sh 2>&1 | tail -3; [[ ${PIPESTATUS[0]} == 0 ]] || rc=1
  echo "== (d) added lines of $TRUNK..HEAD: local paths, key/token shapes"
  git diff "$TRUNK" HEAD | grep -E '^\+[^+]' > "$W/added.txt"
  echo "  added lines: $(wc -l < "$W/added.txt")"
  echo "  naming /home/: $(grep -c '/home/' "$W/added.txt")"; grep -n '/home/' "$W/added.txt" | cut -c1-160
  s=$(grep -ciE 'api[_-]?key|secret|token|passw|BEGIN (RSA|OPENSSH)|ghp_|sk-[A-Za-z0-9]{20}' "$W/added.txt"); echo "  key/token-shaped: $s"
  grep -niE 'api[_-]?key|secret|token|passw|BEGIN (RSA|OPENSSH)|ghp_|sk-[A-Za-z0-9]{20}' "$W/added.txt" | cut -c1-160
  echo "  IPv4-shaped: $(grep -cE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "$W/added.txt")"; grep -nE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "$W/added.txt" | cut -c1-160
} >> "$f" 2>&1
echo "rc=$rc" >> "$f"; cat "$f"
