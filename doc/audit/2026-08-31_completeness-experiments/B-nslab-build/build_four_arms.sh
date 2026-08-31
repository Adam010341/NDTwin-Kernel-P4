#!/usr/bin/env bash
# PREREG-B v1.0 §2 — build the four arms from behavioral-model f0b7d201.
# Builds are not measurements, so they may run concurrently; each arm gets its
# own tree and prefix so nothing can leak between them.
# Records, per arm: sha256 of the binary, ldd, RUNPATH (readelf -d), the
# expansion of -march=native, and the two symbol markers the prereg's
# bidirectional signature needs.
# [Co-developed with claude code -- Adam]
set -uo pipefail
ROOT="${1:-$HOME/b-round}"
SRC="$ROOT/bmv2-src"; OUT="$ROOT/builds"; PIN=f0b7d201
mkdir -p "$OUT"

if [ ! -d "$SRC/.git" ]; then
  git clone -q https://github.com/p4lang/behavioral-model.git "$SRC" || exit 3
fi
cd "$SRC" && git fetch -q --all 2>/dev/null
git checkout -q "$PIN" 2>/dev/null || { echo "ABORT: cannot check out $PIN"; exit 3; }
FULL=$(git rev-parse HEAD); echo "pinned_tree: $FULL" | tee "$OUT/tree.txt"

VENV="$HOME/p4dev-python-venv"
declare -A CFG=(
  [A_stock]="--with-pi --with-thrift --with-python_prefix=$VENV CXXFLAGS=-O0 -g"
  [B_default]=""
  [C_documented]="-O3 --disable-logging-macros --disable-elogger"
  [D_fullfast]="-O3 --disable-logging-macros --disable-elogger EXTRA"
)

build_arm () {
  local name="$1"
  local tree="$ROOT/tree_$name"
  local log="$OUT/${name}.buildlog"
  rm -rf "$tree"; cp -a "$SRC" "$tree" || return 4
  cd "$tree" || return 4
  ./autogen.sh >"$log" 2>&1
  case "$name" in
    A_stock)      ./configure --with-pi --with-thrift --with-python_prefix="$VENV" 'CXXFLAGS=-O0 -g' --prefix="$OUT/$name" >>"$log" 2>&1 ;;
    B_default)    ./configure --prefix="$OUT/$name" >>"$log" 2>&1 ;;
    C_documented) ./configure --disable-logging-macros --disable-elogger 'CXXFLAGS=-O3' --prefix="$OUT/$name" >>"$log" 2>&1 ;;
    D_fullfast)   ./configure --disable-logging-macros --disable-elogger \
                    'CXXFLAGS=-O3 -DNDEBUG -march=native -fno-semantic-interposition' \
                    --prefix="$OUT/$name" >>"$log" 2>&1 ;;
  esac
  [ $? -eq 0 ] || { echo "$name CONFIGURE-FAIL" >>"$OUT/status.txt"; return 5; }
  make -j4 >>"$log" 2>&1 || { echo "$name MAKE-FAIL" >>"$OUT/status.txt"; return 6; }
  make install >>"$log" 2>&1
  local BIN="$tree/targets/simple_switch/simple_switch"
  [ -x "$BIN" ] || BIN=$(find "$tree/targets" -name simple_switch -type f -perm -u+x | head -1)
  {
    echo "arm: $name"; echo "tree_sha: $FULL"
    echo "configure: ${CFG[$name]}"
    echo "binary: $BIN"
    echo "sha256: $(sha256sum "$BIN" | cut -d' ' -f1)"
    echo "--- ldd ---";        ldd "$BIN" 2>&1 | head -25
    echo "--- RUNPATH ---";    readelf -d "$BIN" 2>/dev/null | grep -E "RUNPATH|RPATH" || echo "(none)"
    echo "--- symbol markers (bidirectional signature) ---"
    echo "logging_macro_syms: $(nm -C "$BIN" 2>/dev/null | grep -ci 'Logger\|ELOGGER\|elogger')"
    echo "assert_syms:        $(nm -C "$BIN" 2>/dev/null | grep -c '__assert_fail')"
    echo "--- build id ---";   file "$BIN" 2>&1 | tr ',' '\n' | grep -i "BuildID\|not stripped\|stripped"
  } > "$OUT/${name}.identity.txt" 2>&1
  echo "$name OK $(sha256sum "$BIN" | cut -c1-16)" >>"$OUT/status.txt"
}

echo "--- march=native expansion on this VM ---" > "$OUT/march_native.txt"
gcc -march=native -Q --help=target 2>/dev/null | grep -E "^\s+-m(arch|tune)=" >> "$OUT/march_native.txt"
gcc --version | head -1 >> "$OUT/march_native.txt"

: > "$OUT/status.txt"
for a in A_stock B_default C_documented D_fullfast; do
  ( build_arm "$a" ) &
done
wait
echo "=== ALL DONE $(date -u +%FT%TZ) ==="; cat "$OUT/status.txt"
