#!/usr/bin/env bash
# manifest_backfill.sh -- write a BUILD-MANIFEST beside the fast bmv2 that is already installed.
#
# [Co-developed with claude code -- Adam]
#
# 38e0c44 made build_bmv2_fast.sh sign its own work, but only for builds run after it. The fast
# binary in /usr/local/bmv2-fast was installed 2026-08-15 and its build tree (/tmp/bmv2-fast-src)
# is gone, so the installed artifact -- the one every -O3 number in this project came from -- has
# no record beside it. This backfills that record from doc/audit/bmv2-binary-provenance.md, which
# established each field by observation rather than inference.
#
# ## Why this is a separate script and not a flag on the build script
#
# It writes a manifest for a build it did not perform. That is a different and more dangerous act
# than recording a build as it happens, and it gets two guards the build path does not need:
#
#   1. **It refuses to describe a binary it cannot identify.** The expected sha256 is pinned
#      below. Both installations answer `--version` with the same string (1.15.3-f0b7d201), so
#      --version cannot tell them apart -- writing "fast, -O3" onto whatever happens to sit at
#      that path is exactly how the -O0 binary got mistaken for this one in an A/B where both
#      numbers looked plausible. If the hash does not match, this exits non-zero and writes
#      nothing.
#   2. **The file says it was reconstructed.** A backfilled manifest that is byte-identical in
#      shape to a build-time one is a forged provenance record: a later reader would take
#      "built: 2026-08-15" as something observed at build time. Every reconstructed field is
#      marked, and the fields that genuinely cannot be recovered are listed as unrecoverable
#      rather than guessed.
#
# Idempotent in the way that matters: re-running overwrites with identical content EXCEPT the
# `reconstructed:` stamp, which records when the reconstruction was performed and therefore
# changes every run. The build's own fields are fixed. An earlier version of this comment
# claimed byte-identical output, which its own `date -u` line contradicted.
#
# ## Installation (Adam runs these two lines; this script must not try to)
#
#   sudo install -o root -g root -m 755 tools/test_workflow/manifest_backfill.sh \
#        /usr/local/sbin/ndtwin-manifest-backfill
#   sudo visudo -f /etc/sudoers.d/ndtwin-lab   # add:
#        adam ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-manifest-backfill
#
# The narrow-sudoers shape follows ndtwin-lab's existing pattern: one absolute path, no
# arguments, root-owned and not writable by the invoking user -- so the NOPASSWD entry cannot be
# turned into arbitrary root by editing the script it points at.
set -uo pipefail

PREFIX=/usr/local/bmv2-fast
BIN="$PREFIX/bin/simple_switch_grpc"
MANIFEST="$PREFIX/BUILD-MANIFEST"

# From doc/audit/bmv2-binary-provenance.md, established by sha256sum on 2026-08-21.
EXPECT_SHA=3ff54b5c1901c9d3ffd80ac05dc3dc7d0e696e3df73174c1616fb87ac9aedb4a
EXPECT_SIZE=92147960
STOCK_SHA=327fa7d17221739747a15c6ced580b452b5c8981f29ba6a6998c1361d73cdef4

die() { printf 'manifest_backfill: %s\n' "$*" >&2; exit 1; }

[[ -x "$BIN" ]] || die "no executable at $BIN -- is the fast build installed?"

actual_sha="$(sha256sum "$BIN" | cut -d' ' -f1)"
actual_size="$(stat -c %s "$BIN")"

if [[ "$actual_sha" != "$EXPECT_SHA" ]]; then
    if [[ "$actual_sha" == "$STOCK_SHA" ]]; then
        die "the binary at $BIN is the STOCK -O0 build (sha256 matches the stock row of
  doc/audit/bmv2-binary-provenance.md). Refusing to label it as the fast build."
    fi
    die "the binary at $BIN is not the one the provenance record describes.
  expected sha256: $EXPECT_SHA
  actual   sha256: $actual_sha
  It was probably rebuilt in place. Do not backfill: run build_bmv2_fast.sh, which writes a
  real manifest at build time, and correct bmv2-binary-provenance.md with the new hash."
fi

# --version is not an identifier (both builds answer identically) but it is the one field that
# can still be read from the artifact itself, and it carries the source SHA.
version="$("$BIN" --version 2>&1 | head -1)"
[[ -n "$version" ]] || version="(unreadable)"

tee "$MANIFEST" >/dev/null <<EOF
# RECONSTRUCTED MANIFEST -- not written at build time.
#
# The build tree for this binary (/tmp/bmv2-fast-src) no longer exists. Every field below was
# recovered after the fact by tools/test_workflow/manifest_backfill.sh from
# doc/audit/bmv2-binary-provenance.md, and the binary was verified by sha256 before this file
# was written. Builds made after 38e0c44 write their own manifest at install time and do not
# carry this header.
#
# reconstructed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# verified:      sha256 $EXPECT_SHA matches the installed binary

built:     2026-08-15T07:11:36Z          # mtime of the installed binary, +0800 15:11:36
source:    /tmp/bmv2-fast-src            # gone; was a --local clone of behavioral-model
commit:    f0b7d201                      # embedded in --version, tree still at this HEAD
configure: --prefix=$PREFIX --with-pi --with-thrift --with-python_prefix=/home/adam/p4dev-python-venv --disable-logging-macros --disable-elogger CXXFLAGS=-O3 -g -DNDEBUG -march=native -fno-semantic-interposition CFLAGS=-O3 -g -DNDEBUG -march=native

version:   $version
sha256:    $actual_sha
size:      $actual_size
buildid:   1748b7ebaef9fd0181eba223e36220d9001709c3

# Recovered from tools/test_workflow/build_bmv2_fast.sh, the recipe that produced this install.
# NOT recoverable, and deliberately not guessed:
#   * the configure recap (the no/no/no confirmation that logging macros, elogger and debugger
#     were actually disabled) -- read from the recipe's intent, never captured from the run
#   * the exact toolchain version
#   * byte-reproducibility: -march=native bakes in this machine's ISA, so a rebuild from
#     f0b7d201 is functionally equivalent, not identical. Treat the installed binary as the
#     artifact of record.
EOF

printf 'manifest_backfill: wrote %s\n' "$MANIFEST"
cat "$MANIFEST"
