#!/usr/bin/env bash
. /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2/lib.sh
DONE=$K/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-writer-a/r4/driver.done
# --- 0. wait for the other run's driver.done (poll 5 min, give up after 6 h), then require no mutate_ gate process (/proc/*/cmdline)
t0=$(date +%s)
while [ ! -e $DONE ]; do
  echo "[poll] $(date '+%F %T') driver.done absent" >> $OUT/cmds.log
  [ $(( $(date +%s) - t0 )) -ge 21600 ] && { echo "[poll] $(date '+%F %T') gave up after 6 h" >> $OUT/cmds.log; echo GAVEUP >> $OUT/cmds.log; exit 9; }
  sleep 300
done
echo "[poll] $(date '+%F %T') driver.done present" >> $OUT/cmds.log
mg() { for d in /proc/[0-9]*; do [ "${d#/proc/}" = "$$" ] && continue; tr '\0' ' ' < $d/cmdline 2>/dev/null | grep -E '(^| |/)(bash|sh) +([^ ]*/)?mutate_[a-z0-9_]+\.sh' ; done; }
while :; do n=$(mg | wc -l); echo "[mutate_ gate processes at $(date '+%F %T'): $n]" >> $OUT/cmds.log; mg >> $OUT/cmds.log
  [ "$n" -eq 0 ] && break
  [ $(( $(date +%s) - t0 )) -ge 21600 ] && { echo GAVEUP-mutate >> $OUT/cmds.log; exit 9; }; sleep 300; done
mkdir -p $SP $SP/fakehome/_temp $SP/cl $SP/pyc
FH=$SP/fakehome
p4health() { # the four health-check suites, trunk side, in the clone $c; laptop-gate interpreters, P4_HEALTH_UNDER_TEST unset
  for t in test_p4_health_cells.py test_p4_health_collect.py test_p4_health_recover.sh test_p4_health_gate_scripts.sh; do
    waitdisk p4health-$t
    case $t in *.py) it=tests/python/$t; ip=$HOME/miniconda3/envs/ryu-env/bin/python;; *) it=tests/shell/$t; ip=bash;; esac
    echo "[p4health-$t] $(date '+%F %T') \$ (unset P4_HEALTH_UNDER_TEST; cd clone; $ip $it)" >> $OUT/cmds.log
    n=${t%.*}; n=${n#test_p4_health_}
    { echo "commit $(git -C $c rev-parse HEAD)"; ( cd "$c" && unset P4_HEALTH_UNDER_TEST && setsid --wait nice -n 19 $ip $it ); echo "rc=$?"; } > $OUT/p4health-$n-trunk.log 2>&1
    echo "[p4health-$n]   $(tail -1 $OUT/p4health-$n-trunk.log) ($(wc -l < $OUT/p4health-$n-trunk.log) lines)" >> $OUT/cmds.log
  done; }
runlane() { # label side-dir script
  waitdisk $1
  echo "[$1] $(date '+%F %T') $ setsid --wait nice -n 19 ci-r2.sh $2 $3" >> $OUT/cmds.log
  s=$(date +%s.%N)
  { echo "commit $(git -C $2 rev-parse HEAD)"; ( cd "$2" && "${@:4}" setsid --wait nice -n 19 $OUT/ci-r2.sh "$2" "$3" ); echo "rc=$?"; } > $OUT/$1.log 2>&1
  e=$(date +%s.%N); echo "[$1]   $(tail -1 $OUT/$1.log) wall $(echo "$e - $s" | bc)s load=$(cut -d' ' -f1-3 /proc/loadavg) ($(wc -l < $OUT/$1.log) lines)" >> $OUT/cmds.log
}
chk() { # label dir script
  waitdisk $1
  { echo "commit $(git -C $2 rev-parse HEAD)"; ( cd "$2" && setsid --wait nice -n 19 $3 ); echo "rc=$?"; } > $OUT/$1.log 2>&1
  echo "[$1]   $(tail -1 $OUT/$1.log)" >> $OUT/cmds.log
}
side() { # label commit
  lab=$1; sha=$2; c=$SP/cl/$lab
  waitdisk clone-$lab
  x git clone --shared -q $K $c
  x git -C $c checkout -q --detach $sha
  x git -C $c update-ref refs/remotes/origin/trunk $BT
  x ln -s $K/p4_proxy/venv $c/p4_proxy/venv
  { git -C $c rev-parse HEAD; git -C $c rev-parse refs/remotes/origin/trunk; } >> $OUT/verify-revparse.log
  ss -ltnH | awk '{print $4}' | grep -E ':(6633|6653|8000|8080)$' > $OUT/ss-before-$lab.log; echo "rc=0" >> $OUT/ss-before-$lab.log
  runlane p4lane-$lab $c $OUT/p4lane.sh
  runlane klane-$lab $c $OUT/klane.sh
  ss -ltnH | awk '{print $4}' | grep -E ':(6633|6653|8000|8080)$' > $OUT/ss-after-$lab.log; echo "rc=0" >> $OUT/ss-after-$lab.log
  chk anchors-$lab $c $OUT/chk-anchors.sh
  chk tmpdirs-$lab $c $OUT/chk-tmpdirs.sh
  chk bashn-$lab $c $OUT/chk-bashn.sh
  chk pycompile-$lab $c $OUT/chk-pycompile.sh
  chk l1score-$lab $c $OUT/chk-l1score.sh
  if [ $lab = trunk ]; then p4health; fi
  case $lab in pr|trunk) waitdisk builtp4-$lab
     { echo "commit $(git -C $c rev-parse HEAD)"; ( cd "$c" && setsid --wait nice -n 19 env -i PATH=$K/p4_proxy/venv/bin:/usr/bin:/bin HOME=/tmp CI=true $OUT/builtp4.sh ); echo "rc=$?"; } > $OUT/builtp4-$lab.log 2>&1
     echo "[builtp4-$lab] $(tail -1 $OUT/builtp4-$lab.log)" >> $OUT/cmds.log;; esac
  x rm -rf $c
}
BT=$(git -C $K rev-parse --verify '6c1a78c8^{commit}')
B_MAIN=$(git -C $K rev-parse --verify 'main^{commit}'); B_PR=$(git -C $K rev-parse --verify 'refs/heads/pr/p4-health-cut2^{commit}'); B_T=$(git -C $K rev-parse --verify 'refs/heads/trunk-cut2-merge^{commit}')
: > $OUT/verify-revparse.log
side basemain $B_MAIN
side pr $B_PR
side basetrunk $BT
side trunk $B_T
echo ALLSIDES-DONE >> $OUT/cmds.log
