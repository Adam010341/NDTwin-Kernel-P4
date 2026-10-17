#!/usr/bin/env bash
# shardwrap.sh <k> : exec wrapper of one health-gate shard (run in the clone). Writes the signal mask of this process (the one that
# execs the gate) and of a child grep into the shard log (stdout), the PYTHON* environment, refuses (rc 98) unless
# SigBlk & 0x4203 == 0 (SIGHUP, SIGINT, SIGUSR1, SIGTERM unblocked), then execs the gate for shard k of 4.
# [Co-developed with claude code -- Adam]
k="$1"
echo "shardwrap: pid $$ at $(date -Is), shard $k/4, cwd $PWD"
grep -E '^Sig(Blk|Ign)' /proc/self/status | sed 's/^/shardwrap: child grep, /'
grep -E '^Sig(Blk|Ign)' /proc/$$/status | sed 's/^/shardwrap: the exec-ing process, /'
echo "shardwrap: env PYTHON*: $(env | grep ^PYTHON | tr '\n' ' ')"
echo "shardwrap: PYTHON is ${PYTHON:-unset}"
grep SigBlk /proc/self/status > "$PWD/../tmp/shardwrap.sb.$k"; blk=$(awk '{print $2}' "$PWD/../tmp/shardwrap.sb.$k"); rm -f "$PWD/../tmp/shardwrap.sb.$k"
if [[ $(( 0x$blk & 0x4203 )) -ne 0 ]]; then echo "shardwrap: REFUSED: SigBlk $blk & 0x4203 != 0"; exit 98; fi
echo "shardwrap: SigBlk $blk & 0x4203 == 0; exec env MUT_SHARD=$k/4 bash tests/shell/mutate_p4_health.sh"
exec env MUT_SHARD=$k/4 bash tests/shell/mutate_p4_health.sh
