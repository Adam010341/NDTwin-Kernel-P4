#!/usr/bin/env bash
# step.sh <name> <dir> <cmd...> : guard, then the command in <dir>; the guard lines go to $E/<name>.guard.log. Exit code is the command's.
E=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r5
name="$1"; dir="$2"; shift 2
bash $E/guard.sh $E/$name.guard.log || { echo "$name: guard refused (see $E/$name.guard.log)"; exit 97; }
cd "$dir" && "$@"
