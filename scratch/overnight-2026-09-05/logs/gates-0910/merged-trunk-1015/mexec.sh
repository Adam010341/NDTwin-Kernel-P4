#!/usr/bin/env bash
# mexec.sh <guard log> <cmd...> : the exec wrapper of every step. Writes /proc/self/status's SigBlk and SigIgn lines (this very
# process, the one that goes on to exec <cmd>, and a child grep that inherits the same mask) into <guard log>, refuses
# (rc 98) unless SigBlk & 0x4203 == 0, then execs <cmd>. [Co-developed with claude code -- Adam]
glog="$1"; shift
{ echo "$(date -Is) mexec pid $$ (the process that execs: $*)" | cut -c1-300
  grep -E '^Sig(Blk|Ign)' /proc/$$/status | sed 's/^/mexec: process /'
  grep -E '^Sig(Blk|Ign)' /proc/self/status | sed 's/^/mexec: child grep /'; } >> "$glog"
grep SigBlk /proc/$$/status > "$glog.sb.tmp"; blk=$(awk '{print $2}' "$glog.sb.tmp"); rm -f "$glog.sb.tmp"
if [[ $(( 0x$blk & 0x4203 )) -ne 0 ]]; then echo "mexec: REFUSED: SigBlk $blk & 0x4203 != 0" >> "$glog"; exit 98; fi
echo "mexec: SigBlk $blk & 0x4203 == 0, exec" >> "$glog"
exec "$@"
