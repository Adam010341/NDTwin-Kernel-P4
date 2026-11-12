#!/usr/bin/env bash
# [Co-developed with claude code -- Adam]
#
# Put the googletest source tree that CMakeLists.txt pins on disk, for CI.
#
# CMakeLists.txt fetches googletest with FetchContent, which retries connect, DNS and timeout
# errors but not an HTTP error. A single HTTP 503 from github.com therefore fails the configure
# step. CI instead runs this script before
# configuring: it reads the pinned archive URL from CMakeLists.txt (the only place the pin
# lives), downloads it with retries unless the tree is already in place (for example restored
# from the workflow cache), and prints the directory. Configure then passes
#   -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=<that directory>
# and FetchContent downloads nothing. A local build does not need this script; on a machine
# without network access, run it where there is one and point the configure step at its output
# the same way (README.md, "Build").
#
# Usage:
#   fetch_googletest.sh [--cmakelists FILE] --print-commit
#   fetch_googletest.sh [--cmakelists FILE] --dry-run  CACHE_ROOT
#   fetch_googletest.sh [--cmakelists FILE]            CACHE_ROOT
#
#   --print-commit  print the pinned commit (the cache key) and exit; no download
#   --dry-run       print the directory that would be used and whether it is already there; no download
#   CACHE_ROOT      directory that holds googletest-<commit>/ ; created if missing
#
# Output: stdout is exactly the googletest source directory (one line); everything else, including
# unzip's output, goes to stderr.
# Exit status: 0 on success; 2 for a usage error; 3 if CMakeLists.txt is missing or does not
# contain exactly one pinned googletest archive URL; 4 if the download or unpack fails or the tree
# is not googletest; 1 for any other failure (the script runs under set -e).

set -euo pipefail

cmakelists=""
mode="fetch"
root=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cmakelists) [ $# -ge 2 ] || { echo "fetch_googletest: --cmakelists needs a file" >&2; exit 2; }
                  cmakelists="$2"; shift 2 ;;
    --print-commit) mode="print-commit"; shift ;;
    --dry-run) mode="dry-run"; shift ;;
    -h|--help) awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
    -*) echo "fetch_googletest: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$root" ] || { echo "fetch_googletest: more than one CACHE_ROOT" >&2; exit 2; }
       root="$1"; shift ;;
  esac
done

if [ -z "$cmakelists" ]; then
  cmakelists="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/CMakeLists.txt"
fi
if [ ! -f "$cmakelists" ]; then
  echo "fetch_googletest: $cmakelists not found" >&2
  exit 3
fi
if [ "$mode" != "print-commit" ] && [ -z "$root" ]; then
  echo "fetch_googletest: CACHE_ROOT is required" >&2
  exit 2
fi

# Exactly one pinned archive URL: https://github.com/google/googletest/archive/<40 hex>.zip
pin_re='https://github\.com/google/googletest/archive/[0-9a-f]{40}\.zip'
urls="$(grep -Eo "$pin_re" "$cmakelists" || true)"
count=0
[ -n "$urls" ] && count="$(printf '%s\n' "$urls" | wc -l)"
if [ "$count" -ne 1 ]; then
  echo "fetch_googletest: expected exactly one googletest archive URL of the form" >&2
  echo "  https://github.com/google/googletest/archive/<40-hex-commit>.zip" >&2
  echo "in $cmakelists, found $count" >&2
  exit 3
fi
url="$urls"
commit="${url##*/}"
commit="${commit%.zip}"

if [ "$mode" = "print-commit" ]; then
  echo "$commit"
  exit 0
fi

dir="$root/googletest-$commit"

if [ -f "$dir/CMakeLists.txt" ]; then
  echo "fetch_googletest: $dir already there, not downloading" >&2
  echo "$dir"
  exit 0
fi

if [ "$mode" = "dry-run" ]; then
  echo "fetch_googletest: would download $url into $dir" >&2
  echo "$dir"
  exit 0
fi

mkdir -p "$root"
work="$(mktemp -d "$root/.fetch.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "fetch_googletest: downloading $url" >&2
if ! curl -fsSL --retry 6 --retry-all-errors --retry-max-time 600 --retry-delay 15 \
       --connect-timeout 20 --max-time 120 -o "$work/gt.zip" "$url"; then
  echo "fetch_googletest: download failed after retries" >&2
  exit 4
fi

if command -v unzip >/dev/null 2>&1; then
  unzip -q "$work/gt.zip" -d "$work/x" >&2 || { echo "fetch_googletest: unzip failed" >&2; exit 4; }
else
  python3 -m zipfile -e "$work/gt.zip" "$work/x" >&2 || { echo "fetch_googletest: unpack failed" >&2; exit 4; }
fi

if [ ! -f "$work/x/googletest-$commit/CMakeLists.txt" ]; then
  echo "fetch_googletest: archive has no googletest-$commit/CMakeLists.txt at its top" >&2
  exit 4
fi

rm -rf "$dir"
mv "$work/x/googletest-$commit" "$dir"
echo "fetch_googletest: unpacked into $dir" >&2
echo "$dir"
