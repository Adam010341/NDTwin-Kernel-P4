#!/usr/bin/env bash
# Re-record PREREG-B arm identity against the ELF, not the libtool wrapper.
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS EXISTS.  The first pass hashed
#     targets/simple_switch_grpc/simple_switch_grpc
# which autotools leaves as a 6.7 kB *shell script* wrapping .libs/<name>.  Every
# downstream record still looked right: four DISTINCT sha256 values (the wrapper embeds
# its own tree path, so they differ per arm), a size field, a RUNPATH field.  The
# "four distinct hashes" check would have gone GREEN on evidence about shell scripts.
# `nm` on a script returns nothing, so the bidirectional symbol signature would have
# read 0 for every arm and looked like a consistent negative.
#
# The builds are fine.  Only the identity records were wrong.  This re-derives them and
# adds the assertion that would have caught it: the object must BE an ELF.
set -euo pipefail
ROOT="$HOME/bnslab-B"
PIN=f0b7d201570d088a056b7fe660802ca1a8bcb912
MIN_BYTES=1000000          # a real simple_switch_grpc is ~69 MB; a wrapper is ~6.7 kB

echo "=== re-recording identity against the ELF  $(date -Is) ==="
ok=0; bad=0
for arm in A B C D; do
    tree="$ROOT/tree_${arm}"
    [ -d "$tree" ] || { echo "  $arm: no tree (not built yet)"; continue; }

    bin=""
    for cand in "$tree/targets/simple_switch_grpc/.libs/simple_switch_grpc" \
                "$tree/targets/simple_switch/.libs/simple_switch"; do
        [ -f "$cand" ] && { bin="$cand"; break; }
    done
    [ -n "$bin" ] || { echo "  🔴 $arm: no .libs binary found"; bad=$((bad+1)); continue; }

    # ---- the three assertions the first pass lacked ------------------------------------
    ft=$(file -b "$bin")
    case "$ft" in ELF*) : ;; *) echo "  🔴 $arm: not an ELF -- $ft"; bad=$((bad+1)); continue ;; esac
    sz=$(stat -c %s "$bin")
    [ "$sz" -ge "$MIN_BYTES" ] || { echo "  🔴 $arm: $sz bytes < $MIN_BYTES -- looks like a wrapper"; bad=$((bad+1)); continue; }
    nsym=$(nm -C "$bin" 2>/dev/null | wc -l)
    [ "$nsym" -gt 0 ] || { echo "  🔴 $arm: nm returned no symbols -- signature would be vacuous"; bad=$((bad+1)); continue; }

    # keep the build timing from the first pass; it is still valid
    bt=$(awk -F= '/^build_seconds=/{print $2}' "$ROOT/identity_${arm}.meta" 2>/dev/null || echo unknown)
    jb=$(awk -F= '/^jobs=/{print $2}' "$ROOT/identity_${arm}.meta" 2>/dev/null || echo unknown)

    {
      printf 'arm=%s\n' "$arm"
      printf 'pin=%s\n' "$PIN"
      printf 'tree_head=%s\n' "$(git -C "$tree" rev-parse HEAD)"
      printf 'binary=%s\n' "$bin"
      printf 'file_type=%s\n' "$ft"
      printf 'sha256=%s\n' "$(sha256sum "$bin" | cut -d' ' -f1)"
      printf 'size_bytes=%s\n' "$sz"
      printf 'build_seconds=%s\n' "$bt"
      printf 'jobs=%s\n' "$jb"
      printf 'configure_line=%s\n' "$(grep -m1 '\$ \./configure' "$tree/config.log" | sed 's/^ *\$ *//')"
      printf 'runpath=%s\n' "$(readelf -d "$bin" 2>/dev/null | awk '/RUNPATH|RPATH/{print $NF}' | tr -d '[]' | tr '\n' ' ')"
      printf 'sym_total=%s\n' "$nsym"
      printf 'sym_elogger=%s\n' "$(nm -C "$bin" 2>/dev/null | grep -c -i elogger || true)"
      printf 'sym_debug_assert=%s\n' "$(nm -C "$bin" 2>/dev/null | grep -c -i 'assert' || true)"
      printf 'stripped=%s\n' "$(echo "$ft" | grep -o 'not stripped\|stripped' | head -1)"
      printf 'wrapper_sha256=%s\n' "$(sha256sum "${bin%/.libs/*}/$(basename "$bin")" 2>/dev/null | cut -d' ' -f1 || echo n/a)"
    } > "$ROOT/identity_${arm}.meta"
    ldd "$bin" > "$ROOT/ldd_${arm}.txt" 2>&1 || true
    echo "  ✅ $arm  $(printf '%12s' "$sz") bytes  sha=$(sha256sum "$bin" | cut -c1-16)  syms=$nsym  elogger=$(nm -C "$bin" 2>/dev/null | grep -c -i elogger || true)"
    ok=$((ok+1))
done

echo ""
echo "=== distinctness, now over ELF hashes ==="
n=$(grep -h '^sha256=' "$ROOT"/identity_*.meta 2>/dev/null | sort -u | wc -l)
echo "  distinct ELF sha256: $n  (recorded arms: $ok, failed: $bad)"
[ "$ok" -eq 0 ] || {
  echo "  sizes:"; grep -h '^size_bytes=' "$ROOT"/identity_*.meta | sort -u | sed 's/^/    /'
  echo "  🔑 identical SIZES across arms with different configure lines would itself be"
  echo "     suspicious -- -O0 -g and -O3 -DNDEBUG do not produce the same byte count."
}
