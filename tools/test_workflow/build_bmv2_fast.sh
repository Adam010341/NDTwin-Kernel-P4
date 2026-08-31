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

# $SRC used to be a bare constant. It is now overridable, because the tree it named
# (/home/adam/P4_Source_Code, 3.5 GB) is scheduled for deletion and the documented way to
# rebuild after that is to clone f0b7d201 somewhere else and point SRC at it. The default is
# unchanged, so nothing about an existing invocation moves.
SRC="${SRC:-/home/adam/P4_Source_Code/behavioral-model}"
PREFIX=/usr/local/bmv2-fast
BUILD=/tmp/bmv2-fast-src
VENV=/home/adam/p4dev-python-venv

# The commit both installed simple_switch_grpc binaries were built from; see
# doc/audit/bmv2-binary-provenance.md. Overridable, but only on purpose and by name.
EXPECT_COMMIT="${BMV2_EXPECT_COMMIT:-f0b7d201570d088a056b7fe660802ca1a8bcb912}"
RESIDUE_DOC="doc/audit/2026-08-31_p4-source-tree-residue/README.md"

# ---------------------------------------------------------------------------------------
# Two gates, before anything is built, cloned or installed.
#
# Gate 1 exists because this script's whole job is to produce a binary whose identity is
# known, and $SRC is where that identity comes from. If the tree is gone, the honest outcome
# is a stop, not a recovery: cloning a replacement here would silently take upstream's
# current HEAD, and the build would succeed, install over $PREFIX, and write a manifest --
# every step green -- while producing a binary from different source than every number this
# project has published. "Thought it was rebuilding the same binary, wasn't" is the exact
# shape being refused. The fix is one `git clone` + one `git checkout` by a human who reads
# what commit they are pinning; that human is told below where to find it.
#
# Gate 2 is the one that actually catches it. Gate 1 alone passes happily for a fresh clone
# at the wrong commit, which is the likelier accident once the original tree is gone.
# ---------------------------------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    cat >&2 <<EOF

======================================================================================
REFUSING TO BUILD: the behavioral-model source tree is not there.

  SRC = $SRC   <-- no .git in it (missing, or not a git checkout)

This tree was /home/adam/P4_Source_Code/behavioral-model and it has been deleted, or you
pointed SRC somewhere that is not a checkout.

NOT cloning a replacement, deliberately. A fresh clone lands on upstream HEAD, not on
$EXPECT_COMMIT, and this script would then build, install to $PREFIX and
write a BUILD-MANIFEST -- all of it succeeding -- from source that is not what every
published number was measured against.

How to rebuild, verbatim:

  git clone https://github.com/p4lang/behavioral-model /some/path/behavioral-model
  git -C /some/path/behavioral-model checkout $EXPECT_COMMIT
  SRC=/some/path/behavioral-model bash tools/test_workflow/build_bmv2_fast.sh

What was saved out of the deleted tree, and what it was evidence for:
  $RESIDUE_DOC          (section 5.3)
  doc/audit/bmv2-binary-provenance.md                     (which binary produced which number)

The result is functionally equivalent, NOT byte-identical: -march=native bakes in this
machine's ISA. Treat the already-installed binary as the artifact of record.
======================================================================================

EOF
    exit 2
fi

SRC_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
if [ "$SRC_COMMIT" != "$EXPECT_COMMIT" ]; then
    cat >&2 <<EOF

======================================================================================
REFUSING TO BUILD: \$SRC is a checkout, but not of the commit this project measured.

  SRC      = $SRC
  HEAD     = $SRC_COMMIT
  expected = $EXPECT_COMMIT

Building anyway would install a binary to $PREFIX whose BUILD-MANIFEST
names a commit nobody's published number belongs to. Both installed simple_switch_grpc
builds came from the expected commit -- see doc/audit/bmv2-binary-provenance.md.

  git -C $SRC checkout $EXPECT_COMMIT

If you genuinely mean to build a different commit, say so out loud:

  BMV2_EXPECT_COMMIT=$SRC_COMMIT SRC=$SRC bash tools/test_workflow/build_bmv2_fast.sh

...and then label every number that comes out of it with that commit, not with
$EXPECT_COMMIT.
======================================================================================

EOF
    exit 3
fi

echo "source tree OK: $SRC @ $SRC_COMMIT"

# Build inside a local git clone, not out-of-tree against $SRC: autoconf refuses an
# out-of-tree configure while the source dir holds an in-tree configuration ("source
# directory already configured"), and the fix it suggests -- make distclean in $SRC --
# would destroy the original -O0 build's config.log, which is the provenance evidence the
# performance report quotes. A clone reproduces HEAD exactly (the version string embeds the
# commit) and leaves the original tree byte-for-byte untouched. Verified live 2026-08-15:
# the out-of-tree form failed with exactly that error; the clone form built clean.
#
# CORRECTION 2026-08-31, to the sentence above: "byte-for-byte untouched" is false for the
# ignored half of $SRC. 100 files there carry mtime 2026-08-15 14:58 -- configure, aclocal.m4,
# every Makefile.in, ltmain.sh, the autom4te.cache/s, and an untracked
# targets/simple_switch_grpc/config.h.in -- i.e. an ./autogen.sh was run in the original tree
# minutes before the fast build. The *clone* was still unaffected (git clone --local copies
# committed state, and every file touched is .gitignore'd), so the source claim stands and the
# fast binary's identity is not in question. What is wrong is the scope of the word "untouched".
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
