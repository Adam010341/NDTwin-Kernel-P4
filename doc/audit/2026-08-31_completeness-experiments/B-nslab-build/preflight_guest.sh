#!/usr/bin/env bash
# PREREG-B phase ㊀ — preconditions for the eight-arm ladder, run INSIDE the guest.
# [Co-developed with claude code -- Adam]
#
# This does not measure anything.  It answers the questions that decide whether a
# measurement would mean anything, and it answers them BEFORE the host is quiet enough
# to measure, so that the quiet window is spent measuring rather than discovering.
#
# 🔑 Everything here is read-only or short-lived.  It is registered as the light half of
# the nslab ledger row; the ladder itself waits for H-26 to finish.
set -uo pipefail
ROOT="$HOME/bnslab-B"
echo "=== PREREG-B preflight  $(date -Is) ==="
echo "guest: $(hostname)  nproc=$(nproc)  avail=$(awk '/MemAvailable/{printf "%.1f GiB",$2/1048576}' /proc/meminfo)"
echo "load: $(awk '{print $1,$2,$3}' /proc/loadavg)"
echo ""

echo "--- 1. the four binaries: is each one an ELF, and do the SIZES separate the arms? ---"
printf '  %-4s %-12s %-14s %-10s %-8s %s\n' arm size_bytes sha256_16 build_s elogger configure_tail
for a in A B C D; do
  m="$ROOT/identity_${a}.meta"
  [ -f "$m" ] || { echo "  $a: NO RECORD"; continue; }
  b=$(sed -n 's/^binary=//p' "$m")
  sz=$(sed -n 's/^size_bytes=//p' "$m")
  sh=$(sed -n 's/^sha256=//p' "$m" | cut -c1-16)
  bs=$(sed -n 's/^build_seconds=//p' "$m")
  el=$(sed -n 's/^sym_elogger=//p' "$m")
  ct=$(sed -n 's/^configure_line=//p' "$m" | sed 's/.*python_prefix=[^ ]* *//')
  # re-derive, do not trust the record: a record can outlive the file it describes
  live_sz=$(stat -c %s "$b" 2>/dev/null || echo MISSING)
  live_sh=$(sha256sum "$b" 2>/dev/null | cut -c1-16 || echo MISSING)
  flag=""
  [ "$live_sz" = "$sz" ] || flag="🔴 SIZE DRIFT (live=$live_sz)"
  [ "$live_sh" = "$sh" ] || flag="$flag 🔴 SHA DRIFT (live=$live_sh)"
  printf '  %-4s %-12s %-14s %-10s %-8s %s %s\n' "$a" "$sz" "$sh" "$bs" "$el" "${ct:-(none)}" "$flag"
done
echo ""
echo "  distinct live sha256 across arms: $(for a in A B C D; do b=$(sed -n 's/^binary=//p' "$ROOT/identity_${a}.meta" 2>/dev/null); [ -n "$b" ] && sha256sum "$b" 2>/dev/null; done | cut -d' ' -f1 | sort -u | wc -l)  (want 4)"

echo ""
echo "--- 2. the REGISTERED signature (nm -DC EventLogger), not my invented one ---"
echo "     PREREG-B registers this one because it DISCRIMINATES: stock builds keep the"
echo "     dynamic symbol, --disable-elogger builds do not.  'nm -C | grep -i elogger'"
echo "     reads 56/18/18/18 and cannot separate C or D from B."
for a in A B C D; do
  b=$(sed -n 's/^binary=//p' "$ROOT/identity_${a}.meta" 2>/dev/null)
  [ -n "$b" ] && [ -f "$b" ] || { echo "    $a: binary missing"; continue; }
  printf '    %s  nm -DC EventLogger = %-4s   nm -C elogger = %s\n' \
    "$a" "$(nm -DC "$b" 2>/dev/null | grep -c EventLogger)" "$(nm -C "$b" 2>/dev/null | grep -c -i elogger)"
done

echo ""
echo "--- 3. the tooling the ladder needs ---"
for t in iperf3 mn p4c simple_switch_CLI python3; do
  printf '  %-14s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo '🔴 MISSING')"
done
printf '  %-14s %s\n' "mininet(py)" "$(python3 -c 'import mininet,os;print(os.path.dirname(mininet.__file__))' 2>&1 | tail -1)"

echo ""
echo "--- 4. the P4 program(s) ---"
ls -la "$ROOT/p4/" 2>&1 | sed 's/^/  /'
echo "  ndtwin_switch.json sha256: $(sha256sum "$ROOT/p4/ndtwin_switch.json" 2>/dev/null | cut -c1-16)"
echo "  firewall.p4 present in guest? $(ls "$HOME"/tutorials/exercises/firewall/firewall.p4 2>/dev/null || echo 'NO -- must be copied in for §C')"

echo ""
echo "--- 5. the arm-selection mechanism refuses correctly (force-red, all five ways) ---"
echo "     A gate nobody has seen fail is not a gate.  Each case must EXIT NONZERO."
SAVE=$(mktemp); cp "$ROOT/bmv2_binary_override" "$SAVE" 2>/dev/null || echo "" > "$SAVE"
try() {  # try <label> <file-content-or-DELETE>
  local label="$1" content="$2" rc
  if [ "$content" = "DELETE" ]; then rm -f "$ROOT/bmv2_binary_override"
  else printf '%s\n' "$content" > "$ROOT/bmv2_binary_override"; fi
  timeout 25 python3 - <<PY >/dev/null 2>&1
import sys, runpy
sys.argv = ["bnslab_topo.py"]
sys.path.insert(0, "$ROOT")
import importlib.util
spec = importlib.util.spec_from_file_location("t", "$ROOT/bnslab_topo.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.switch_binary()
PY
  rc=$?
  [ "$rc" -ne 0 ] && printf '    ✅ %-34s refused (rc=%s)\n' "$label" "$rc" \
                  || printf '    🔴 %-34s ACCEPTED -- gate is blind here\n' "$label"
}
try "missing file"            DELETE
try "empty file"              ""
try "comment-only"            "# nothing here"
try "relative path"           "simple_switch_grpc"
try "non-executable"          "/etc/hostname"
try "the libtool WRAPPER"     "$ROOT/tree_D/targets/simple_switch_grpc/simple_switch_grpc"
cp "$SAVE" "$ROOT/bmv2_binary_override"; rm -f "$SAVE"
echo "    (restored: $(sed -n '/^[^#]/p' "$ROOT/bmv2_binary_override" | head -1))"

echo ""
echo "--- 6. force-GREEN: the accept path must actually accept ---"
echo "     smoke-the-accept-path: a gate that refuses everything also passes every"
echo "     refusal test.  The one case that must be ACCEPTED is checked explicitly."
for a in A B C D; do
  b=$(sed -n 's/^binary=//p' "$ROOT/identity_${a}.meta" 2>/dev/null)
  printf '%s\n' "$b" > "$ROOT/bmv2_binary_override"
  if timeout 25 python3 - <<PY >/dev/null 2>&1
import importlib.util
spec = importlib.util.spec_from_file_location("t", "$ROOT/bnslab_topo.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.switch_binary() == "$b"
PY
  then printf '    ✅ arm %s accepted and returned its own path\n' "$a"
  else printf '    🔴 arm %s REJECTED -- the gate would block the round\n' "$a"; fi
done
echo ""
echo "=== preflight done  $(date -Is) ==="
