#!/usr/bin/env bash
#
# Build a maximum-performance bmv2 at a SEPARATE prefix (/usr/local/bmv2-fast).
# The existing /usr/local installation is never written to.
#
# [Co-developed with claude code -- Adam]
#
# Why this exists: the installed simple_switch_grpc was built -O0 with all debug logging
# macros and the nanomsg event logger enabled (p4-guide's default; config.log:7 in the source
# tree records the invocation verbatim). Literature puts simple_switch_grpc around ~170 Mbps
# (SIGSIM-PADS '23; this machine's saturation point has never been measured -- step 1 below),
# while upstream's own docs/performance.md prescribes exactly the flags below and reports
# ~917 Mbps with them. Full analysis: doc/audit/2026-08-15_bmv2-source-analysis.md;
# curated findings: doc/2026-08-15_bmv2-performance-report.md.
#
# ⚠️ Read before running (decision points, not folklore):
#   1. Upstream warns this exact flag set "cannot be used to achieve passing results on all
#      p4c tests" (p4-guide/bin/build-behavioral-model.sh:89-92). Re-run our P4 functional
#      tests against the fast binary before trusting any number from it.
#   2. --disable-elogger removes the nanomsg event stream some PTF tooling subscribes to.
#      If that ever matters, keep elogger and drop only the logging macros -- the macros are
#      the expensive half.
#   3. The fast binary must load the fast shared libs, or you silently benchmark a mix:
#         export LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib:${LD_LIBRARY_PATH:-}
#      Do NOT run ldconfig after installing -- that would change which libraries the
#      EXISTING /usr/local/bin/simple_switch_grpc loads.
#   4. Point NDTwin at the fast binary per-run (the topology's switch command), not via a
#      global PATH change, so the two installs stay independently selectable.
#   5. After switching binaries, every previously recorded throughput number (the 170 Mbps
#      ceiling in doc and slides) becomes historical -- label which build produced what.
#
# Not executed by any automation: run it deliberately, once, with the caveats read.

set -euo pipefail

SRC=/home/adam/P4_Source_Code/behavioral-model
PREFIX=/usr/local/bmv2-fast
BUILD=/tmp/bmv2-fast-src
VENV=/home/adam/p4dev-python-venv

# Build inside a local git clone, not out-of-tree against $SRC: autoconf refuses an
# out-of-tree configure while the source dir holds an in-tree configuration ("source
# directory already configured"), and the fix it suggests -- make distclean in $SRC --
# would destroy the original -O0 build's config.log, which is the provenance evidence the
# performance report quotes. A clone reproduces HEAD exactly (the version string embeds the
# commit) and leaves the original tree byte-for-byte untouched. Verified live 2026-08-15:
# the out-of-tree form failed with exactly that error; the clone form built clean.
rm -rf "$BUILD"
git clone --local "$SRC" "$BUILD"
cd "$BUILD" && ./autogen.sh

# One array feeds both ./configure and the manifest below, so the manifest cannot claim
# flags that did not run.
CONFIGURE_ARGS=(
  --prefix="$PREFIX"
  --with-pi
  --with-thrift
  --with-python_prefix="$VENV"
  --disable-logging-macros
  --disable-elogger
  'CXXFLAGS=-O3 -g -DNDEBUG -march=native -fno-semantic-interposition'
  'CFLAGS=-O3 -g -DNDEBUG -march=native'
)

PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
./configure "${CONFIGURE_ARGS[@]}"

# The configure recap must print:
#   Logging macros enabled ........ : no
#   Event logger enabled .......... : no
#   Debugger enabled .............. : no

make -j"$(nproc)"
sudo make install   # NOT install-strip: keep symbols so perf/py-spy profiling still works

# A number is only as good as the binary it names. This install has already been mistaken
# for the -O0 one in an A/B (both runs produced plausible numbers); the manifest makes
# "which build produced this" a file read instead of an archaeology session.
sudo tee "$PREFIX/BUILD-MANIFEST" >/dev/null <<EOF
built:     $(date -u +%Y-%m-%dT%H:%M:%SZ)
source:    $SRC
commit:    $(git -C "$BUILD" rev-parse HEAD)
configure: ${CONFIGURE_ARGS[*]}
EOF

echo
echo "Manifest written:"
cat "$PREFIX/BUILD-MANIFEST"
echo
echo "Installed to $PREFIX. Run with:"
echo "  export LD_LIBRARY_PATH=$PREFIX/lib:\${LD_LIBRARY_PATH:-}"
echo "  $PREFIX/bin/simple_switch_grpc --version"
echo "Then verify library resolution (every bm/services lib must point at $PREFIX/lib):"
echo "  ldd $PREFIX/bin/simple_switch_grpc | grep -E 'bm_grpc|runtimestubs|simpleswitch'"
