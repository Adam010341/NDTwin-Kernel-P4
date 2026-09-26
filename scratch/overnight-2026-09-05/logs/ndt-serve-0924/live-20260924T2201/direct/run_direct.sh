#!/usr/bin/env bash
# The control: the same sequence as the API run, straight to ~/.local/bin/ndt.
# [Co-developed with claude code -- Adam]
# Every call: setsid -w (ndt up/down have killed their caller -- memory ndt-one-command-lab-lifecycle),
# stdin /dev/null (the same as the server's runner, so `apps` never offers its picker), NDT_OWNER set.
set -u
OUT="$1"; cd "$OUT" || exit 2
NDT="$HOME/.local/bin/ndt"
n=0
step() {   # name, ndt args...
    local name="$1"; shift; n=$((n+1))
    local f; f=$(printf '%02d-%s' "$n" "$name")
    local t0; t0=$(date +%s.%N)
    setsid -w env NDT_OWNER=ndt-serve-0924 "$NDT" "$@" > "$f.stdout" 2> "$f.stderr" < /dev/null
    local rc=$?
    printf '%s\trc=%s\t%.1fs\tndt %s\n' "$f" "$rc" "$(echo "$(date +%s.%N) - $t0" | bc)" "$*" | tee -a summary.tsv
    return 0
}
step status-before status
step claim claim 30 "ndt-serve-0924 control run: the same sequence straight to ndt"
step up up 4
step status-after-up status
step apps-before apps status
step nsr-start apps nsr
sleep 5
step apps-while-nsr apps status
step nsr-stop apps stop nsr
step down down
step release release
step status-after status
