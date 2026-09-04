#!/usr/bin/env bash
# Start one p4lang/tutorials exercise on THIS laptop.
#
# Why this exists: the upstream `make run` recipe is
#     sudo PATH=$(PATH) python3 ../../utils/run_exercise.py ...
# and this machine's sudoers has `secure_path`, so sudo REFUSES the PATH= assignment
# and aborts before python3 ever starts. Naming the interpreter by absolute path
# removes the need to pass PATH through sudo at all.
#
# Prints the command and stops. Add --go to actually run it (interactive sudo: Adam only).
# Nothing is ever written inside ~/tutorials.
# [Co-developed with claude code -- Adam]
set -uo pipefail
T=${T:-/home/adam/tutorials}
PY=${PY:-/home/adam/p4dev-python-venv/bin/python}
KIT=${P4KIT:-$HOME/.cache/p4-tutorial-kit}
SWITCH=${SWITCH:-/usr/local/bin/simple_switch_grpc}   # NOT bmv2-fast; see README

ex=${1:-}; which=${2:-solution}; go=${3:-}
[ "$which" = "--go" ] && { go=--go; which=solution; }
if [ -z "$ex" ] || [ ! -d "$T/exercises/$ex" ]; then
  echo "usage: $0 <exercise> [solution|skeleton] [--go]"
  echo "exercises: $(cd "$T/exercises" && ls -d */ | tr -d / | tr '\n' ' ')"
  exit 2
fi
d="$T/exercises/$ex"
mk="$d/Makefile"

topo=$(grep -m1 '^TOPO *=' "$mk" 2>/dev/null | sed 's/.*= *//')
topo=${topo:-topology.json}
prog=$(grep -m1 '^DEFAULT_PROG *=' "$mk" 2>/dev/null | sed 's/.*= *//')
if [ "$which" = solution ]; then
  src=$(ls "$d"/solution/*.p4 2>/dev/null | head -1)
  [ -n "$src" ] || { echo "!! $ex has no solution/*.p4 -- falling back to skeleton"; which=skeleton; }
fi
if [ "$which" != solution ]; then
  src="$d/${prog:-}"
  [ -f "$src" ] || src=$(ls "$d"/*.p4 2>/dev/null | head -1)
fi
[ -f "$src" ] || { echo "!! no .p4 found for $ex"; exit 3; }

tag=${src#$d/}; tag=$(echo "$tag" | tr '/' '_'); tag=${tag%.p4}
json="$KIT/build/$ex/$tag.json"
if [ ! -f "$json" ]; then
  echo "-- compiling $src -> $json"
  mkdir -p "$(dirname "$json")"
  p4c-bm2-ss --p4v 16 --p4runtime-files "${json%.json}.p4info.txtpb" -o "$json" "$src" || exit 4
fi

echo "exercise    : $ex   ($which: ${src#$T/})"
echo "topology    : $topo   ($(python3 -c "import json;d=json.load(open('$d/$topo'));print(len(d.get('hosts',{})),'hosts,',len(d.get('switches',{})),'switches')" 2>/dev/null))"
echo "program json: $json"
echo "switch      : $SWITCH  sha256=$(sha256sum "$SWITCH" | cut -c1-16)"
busy=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -cE '[:.]909[0-9]$')
[ "$busy" -gt 0 ] && echo "!! WARNING: $busy listener(s) already on 9090-9099 -- the first bmv2 switch will fail to bind its thrift port"

cmd=(sudo "$PY" "$T/utils/run_exercise.py" -t "$d/$topo" -j "$json" -b "$SWITCH"
     -l "$KIT/logs/$ex" -p "$KIT/pcaps/$ex")
echo; echo "command:"; printf '  %q' "${cmd[@]}"; echo
if [ "$go" = "--go" ]; then
  mkdir -p "$KIT/logs/$ex" "$KIT/pcaps/$ex"
  echo; echo "-- running (interactive sudo) --"; exec "${cmd[@]}"
else
  echo; echo "(not executed. add --go to run it -- needs interactive sudo, so Adam runs this.)"
fi
