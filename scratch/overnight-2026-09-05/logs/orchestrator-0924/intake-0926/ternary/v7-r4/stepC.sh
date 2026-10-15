#!/usr/bin/env bash
. /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/ternary/v7-r4/lib.sh
R6=$K/scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/r6/disk_watchdog.log
H=f703d0ff19a563a9031e8870a79cd66a82d39961
# --- 0. wait for the r6 gate and for step A
while :; do
  n=$(grep -c "END shard" $R6); p=$(ps -eo pid,args | grep -E "^ *[0-9]+ (timeout [0-9]+ )?(env MUT_SHARD=[^ ]+ )?bash (tests/shell/)?mutate_p4_health" | wc -l)  # real gate processes only; other sessions' shell wrappers that merely quote the file name do not count
  echo "$(date '+%F %T') END shard lines=$n  mutate_p4_health procs=$p  stepA_done=$(grep -c STEPA-DONE $OUT/cmds.log)" >> $OUT/r6-poll.log
  if [ "$n" -ge 5 ] && [ "$p" -eq 0 ] && grep -q STEPA-DONE $OUT/cmds.log; then break; fi
  sleep 300
done
echo "rc=0" >> $OUT/r6-poll.log
mkdir -p $SP $SP/fakehome/_temp $SP/cl
FH=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/fakehome
mkdir -p $FH/_temp
# --- 1. owner mutation gate on H, throwaway tree
waitdisk mutate-owner
x git clone --shared -q $K $SP/cl/mut
x git -C $SP/cl/mut checkout -q --detach $H
x ln -s $K/p4_proxy/venv $SP/cl/mut/p4_proxy/venv
x ln -s $K/p4_proxy/p4_src/build $SP/cl/mut/p4_proxy/p4_src/build
{ echo "commit $(git -C $SP/cl/mut rev-parse HEAD)"; echo "date $(date)"; ( cd $SP/cl/mut && setsid --wait nice -n 19 env -i PATH=$K/p4_proxy/venv/bin:/usr/bin:/bin HOME=$FH LANG=C.UTF-8 CI=true bash tests/shell/mutate_table_entry_owner.sh ); echo "rc=$?"; } > $OUT/mutate-owner.log 2>&1
echo "[mutate-owner] $(tail -1 $OUT/mutate-owner.log)" >> $OUT/cmds.log
x rm -rf $SP/cl/mut
# --- 2./3. lanes
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
  x git -C $c update-ref refs/remotes/origin/trunk d811f871f37d3a22caac214dc837f7223be5cbdb
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
  case $lab in pr|trunk) waitdisk builtp4-$lab
     { echo "commit $(git -C $c rev-parse HEAD)"; ( cd "$c" && setsid --wait nice -n 19 env -i PATH=$K/p4_proxy/venv/bin:/usr/bin:/bin HOME=/tmp CI=true $OUT/builtp4.sh ); echo "rc=$?"; } > $OUT/builtp4-$lab.log 2>&1
     echo "[builtp4-$lab] $(tail -1 $OUT/builtp4-$lab.log)" >> $OUT/cmds.log;; esac
  x rm -rf $c
}
: > $OUT/verify-revparse.log
side basemain 37e6c79b2c6865e22baa01859a9771f86f7dc7ef
side pr 3b3c84eca358afae5c1fa505a5468c91c48b6df8
side basetrunk d811f871f37d3a22caac214dc837f7223be5cbdb
side trunk 6c1a78c8fa80e687889ecb6a401300f2d432808f
echo ALLDONE >> $OUT/cmds.log
