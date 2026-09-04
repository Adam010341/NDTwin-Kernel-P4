#!/usr/bin/env bash
# Start one p4lang/tutorials exercise on THIS laptop.
#
# Why this exists: the upstream `make run` recipe is
#     sudo PATH=$(PATH) python3 ../../utils/run_exercise.py ...
# and this machine's sudoers sets `secure_path`, so sudo REFUSES the PATH=
# assignment and aborts before python3 ever starts. Naming the interpreter by
# absolute path removes the need to push PATH through sudo at all.
#
# Two things this script must NOT change, because run_exercise.py depends on them:
#   * cwd MUST be the exercise directory. `sw_dict['runtime_json']` ("s1-runtime.json")
#     is opened relative to cwd, and simple_controller resolves that file's own
#     "p4info"/"bmv2_json" fields against workdir=os.getcwd().
#   * the compiled artefacts MUST land at build/<prog>.json and
#     build/<prog>.p4.p4info.txtpb, the exact names sX-runtime.json names.
# So the solution is compiled *to the skeleton's output name* -- same bytes loaded,
# and the exercise's own .p4 source is never edited.
#
# Writes inside ~/tutorials are confined to build/, logs/, pcaps/ -- all three are
# in the tree's .gitignore (verified with `git check-ignore`), so the control tree's
# tracked content stays untouched.
#
# Prints the command and stops. Add --go to actually run it (interactive sudo: Adam only).
# [Co-developed with claude code -- Adam]
set -uo pipefail
T=${T:-/home/adam/tutorials}
PY=${PY:-/home/adam/p4dev-python-venv/bin/python}
SWITCH=${SWITCH:-/usr/local/bin/simple_switch_grpc}   # NOT bmv2-fast; see README §3

ex=${1:-}; which=${2:-solution}; go=${3:-}
[ "$which" = "--go" ] && { go=--go; which=solution; }
if [ -z "$ex" ] || [ ! -d "$T/exercises/$ex" ]; then
  echo "usage: $0 <exercise> [solution|skeleton] [--go]"
  echo "exercises: $(cd "$T/exercises" && ls -d */ | tr -d / | tr '\n' ' ')"
  exit 2
fi
d="$T/exercises/$ex"; mk="$d/Makefile"

topo=$(grep -m1 '^TOPO *=' "$mk" 2>/dev/null | sed 's/.*= *//'); topo=${topo:-topology.json}
prog=$(grep -m1 '^DEFAULT_PROG *=' "$mk" 2>/dev/null | sed 's/.*= *//')
if [ -z "$prog" ]; then prog=$(cd "$d" && ls *.p4 2>/dev/null | head -1); fi
base=${prog%.p4}                       # the output name sX-runtime.json expects

src="$d/$prog"
if [ "$which" = solution ]; then
  s=$(ls "$d"/solution/*.p4 2>/dev/null | head -1)
  if [ -n "$s" ]; then src="$s"; else
    echo "!! $ex has no solution/*.p4 -- using the skeleton instead"; which=skeleton; fi
fi
[ -f "$src" ] || { echo "!! no .p4 found for $ex"; exit 3; }

json="$d/build/$base.json"; p4info="$d/build/$base.p4.p4info.txtpb"
echo "-- compiling ${src#$T/} -> build/$base.json"
mkdir -p "$d/build" "$d/logs" "$d/pcaps"
p4c-bm2-ss --p4v 16 --p4runtime-files "$p4info" -o "$json" "$src" || exit 4

echo
echo "exercise    : $ex   ($which: ${src#$T/})"
echo "topology    : $topo   ($(python3 -c "import json;d=json.load(open('$d/$topo'));print(len(d.get('hosts',{})),'hosts,',len(d.get('switches',{})),'switches')" 2>/dev/null))"
echo "loaded json : build/$base.json   ($(stat -c%s "$json") B, sha256 $(sha256sum "$json"|cut -c1-16))"
echo "switch      : $SWITCH  sha256=$(sha256sum "$SWITCH"|cut -c1-16)  $($SWITCH --version 2>&1|head -1)"
busy=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -cE '[:.]909[0-9]$')
[ "$busy" -gt 0 ] && echo "!! WARNING: $busy listener(s) on 9090-9099 -- s1 will fail to bind its thrift port"

echo; echo "command (cwd MUST be $d):"
echo "  cd $d && \\"
echo "  sudo $PY $T/utils/run_exercise.py -t $topo -j build/$base.json -b $SWITCH"
if [ "$go" = "--go" ]; then
  echo; echo "-- running (interactive sudo) --"
  cd "$d" || exit 5
  exec sudo "$PY" "$T/utils/run_exercise.py" -t "$topo" -j "build/$base.json" -b "$SWITCH"
else
  echo; echo "(not executed. add --go to run it -- needs interactive sudo, so Adam runs this.)"
fi
