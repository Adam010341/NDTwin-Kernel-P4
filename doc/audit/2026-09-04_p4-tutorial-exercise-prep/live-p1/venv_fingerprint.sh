#!/usr/bin/env bash
#
# venv_fingerprint.sh <out> <python>... -- what each interpreter a live run uses actually carries.
#
# [Co-developed with claude code -- Adam]
#
# 09-27: the proxy's venv moved to protobuf 5 (upb) that day, and a live raw that does not say which
# stack it ran on cannot be compared with one from before the move. So every live-p1 raw records,
# per interpreter: the path and what it resolves to, the Python version, protobuf's version and
# api_implementation, grpcio's version, and every installed distribution as `name==version`
# (sorted), with the sha256 of that list -- two raws on the same stack have the same sha.
#
# Read with importlib.metadata inside each interpreter: nothing is installed, pip is not run, and
# nothing is fetched. An interpreter that is missing or cannot answer is written down as such and
# the rc is 1; the caller decides what that means for its run (live-p1 discloses it, it does not
# fail a run over it).
#
# Exit: 0 every interpreter answered, 1 some did not, 2 usage.
set -uo pipefail
[[ $# -ge 2 ]] || { echo "usage: venv_fingerprint.sh <out> <python>..." >&2; exit 2; }
out="$1"; shift
rc=0
: > "$out" || exit 2
for py in "$@"; do
    {
        printf '== interpreter %s\n' "$py"
        if [[ ! -x "$py" ]]; then
            printf 'NOT RECORDED: not an executable file\n\n'
            rc=1
            continue
        fi
        printf 'resolves_to %s\n' "$(readlink -f "$py")"
        if ! "$py" - <<'FP' 2>&1; then
import hashlib, importlib.metadata as md, platform, sys

def version_of(name):
    try:
        return md.version(name)
    except md.PackageNotFoundError:
        return "not installed"

try:
    from google.protobuf.internal import api_implementation
    impl = api_implementation.Type()
except Exception as exc:  # noqa: BLE001 -- a record: say what happened
    impl = f"unreadable ({type(exc).__name__}: {exc})"
dists = sorted({f"{d.metadata['Name']}=={d.version}" for d in md.distributions()
                if d.metadata["Name"]}, key=str.lower)
print(f"python {platform.python_version()} prefix {sys.prefix}")
print(f"protobuf {version_of('protobuf')} api_implementation {impl}")
print(f"grpcio {version_of('grpcio')}")
print(f"distributions {len(dists)} sha256 {hashlib.sha256(chr(10).join(dists).encode()).hexdigest()}")
for line in dists:
    print(f"  {line}")
FP
            printf 'NOT RECORDED: the interpreter did not answer\n'
            rc=1
        fi
        printf '\n'
    } >> "$out"
done
exit "$rc"
