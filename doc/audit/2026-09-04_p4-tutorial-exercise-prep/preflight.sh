#!/usr/bin/env bash
# Pre-flight for a p4lang/tutorials exercise run on THIS laptop.
# Read-only: no sudo that changes state, no process is killed, ~/tutorials is not written to.
# [Co-developed with claude code -- Adam]
set -uo pipefail
T=${T:-/home/adam/tutorials}
VENV=${VENV:-/home/adam/p4dev-python-venv/bin/python}
ok=0; bad=0
say() { printf '%-2s %-42s %s\n' "$1" "$2" "$3"; [ "$1" = "!!" ] && bad=$((bad+1)) || ok=$((ok+1)); }

echo "== toolchain identity (sha256 -- version strings do NOT distinguish these) =="
for b in /usr/local/bin/p4c-bm2-ss /usr/local/bin/simple_switch_grpc \
         /usr/local/bmv2-fast/bin/simple_switch_grpc /usr/bin/mn; do
  if [ -e "$b" ]; then
    printf '   %-46s %s  %s\n' "$b" "$(sha256sum "$b" | cut -c1-16)" "$("$b" --version 2>&1 | grep -im1 -e version -e '^[0-9]' || echo '?')"
  else
    printf '   %-46s (absent)\n' "$b"
  fi
done

echo; echo "== interpreter =="
[ -x "$VENV" ] && say "OK" "p4dev venv interpreter" "$VENV ($($VENV --version 2>&1))" \
               || say "!!" "p4dev venv interpreter" "MISSING at $VENV"
"$VENV" - <<'PY' 2>/dev/null
import sys; sys.path.insert(0, "/home/adam/tutorials/utils")
mods = ["p4runtime_lib.simple_controller","mininet.net","p4_mininet","p4runtime_switch","scapy.all"]
bad = [m for m in mods if not __import__("importlib").util.find_spec(m.split(".")[0])]
print("   venv imports:", "all OK" if not bad else "MISSING " + ",".join(bad))
PY
for p in "$(command -v python3)" /usr/bin/python3; do
  r=$("$p" -c "import mininet,grpc,scapy" 2>&1 | tail -1)
  [ -z "$r" ] && say "OK" "$p" "has mininet+grpc+scapy" \
              || say "!!" "$p" "NOT usable for the harness ($r)"
done

echo; echo "== sudo =="
# NOTE: 'set -o pipefail' makes `sudo ... | grep -q` return sudo's rc, not grep's,
# so the match MUST be tested on a captured string, never as the pipeline's status.
sudo_msg=$(sudo -n PATH=/zzz /usr/bin/mnexec /usr/bin/true 2>&1)
case "$sudo_msg" in
  *"not allowed to set"*)
    say "!!" "sudo PATH= assignment" "REFUSED (secure_path) -> 'make run' aborts; use run_exercise.sh" ;;
  *)
    say "OK" "sudo PATH= assignment" "accepted -- upstream 'make run' can work as written" ;;
esac

echo; echo "== ports the tutorials harness wants =="
for p in 9090 9091 9092 9093 50051 50052 50053 50054; do
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"; then
    say "!!" "port $p" "IN USE -- $(ss -tlnpH 2>/dev/null | grep -m1 ":$p " | sed 's/.*users:(//;s/).*//')"
  fi
done
[ $bad -eq 0 ] && echo "   (all clear)"

echo; echo "== control tree cleanliness =="
n=$(cd "$T" && git status --porcelain 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && say "OK" "$T working tree" "clean at $(cd "$T" && git rev-parse --short HEAD)" \
               || say "!!" "$T working tree" "$n dirty/untracked entr(y|ies) -- see 'git -C $T status'"

echo; echo "== NDTwin lab (must be free; nothing here claims it) =="
NDT_OWNER=${NDT_OWNER:-p4-tutorial-prep} timeout 25 ndt status 2>/dev/null | sed -n '/^lab/,/^$/p' | sed 's/^/   /'

echo; echo "checks passed=$ok  needs attention=$bad"
