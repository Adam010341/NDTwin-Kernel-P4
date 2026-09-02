#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## P4 toolchain build: milestone check while still running   17:43
what I did: with the overall `install-p4dev-v8.sh` script still running (started 16:02:57,
now past 90 minutes), checked whether the two binaries NDTwin actually needs were usable yet,
per the manual's own advice ("the two binaries NDTwin uses are built before the components
that fail late"). `simple_switch_grpc` is already installed and answers
`--version` -> `1.15.6-1c8c9a4f`. `p4c-bm2-ss` is not yet installed to `/usr/local/bin`, but
the freshly-linked binary in the build tree already answers
(`~/p4c/build/backends/bmv2/p4c-bm2-ss --version` -> `Version 1.2.5.17 (SHA: d46d824202 BUILD:
Release)`).
Both version strings are an exact match for the manual's own worked example for **this
specific date** -- the Installation Manual's Section 6.1 box says, verbatim: "1.15.6-1c8c9a4f
with p4c-bm2-ss 1.2.5.17 on 2026-09-02 ... The 2026-09-02 toolchain compiled this project's
ndtwin_switch.p4 cleanly, so a newer p4c is not by itself a problem." That is precisely what
I am seeing, on the day the manual names. A concrete, satisfying cross-check that the manual's
own "measured on" claims are not decorative -- they reproduce.
EOF
echo APPENDED
