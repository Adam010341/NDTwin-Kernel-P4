# Q-N1 suite TERM trap (fix/suite-term-trap-0928) — intake
- **11:2x Delivered** 85befc7d: 1 commit on fed37cff, 5 files, +47/−7. Diff read. Secret scan 0/3.
  - Clean onto trunk f253ed08 (which also edited lib_probe_stub.sh; no textual overlap).
  - trap4 ALL-AS-EXPECTED per the worker (the earlier 78 failures were the missing venv symlink).
- **Judge launched.** Rerun `rerun-qn1.frozen.sh` on test merge b23874ca.

## 14:1x — rerun2 on the test merge onto trunk 85bec430 (6893a9ba)
- The b23874ca rerun (12:29) was all green, but trunk moved to 85bec430 with C++ (third cut), so the reuse rule does not hold.
  File-disjoint (Q-N1 touches 5 tests/shell files only) and merge-tree clean, but rerun anyway: same frozen script, new sha, anchors from 85bec430.
- pid/pgid 3150234; summary `rerun2-qn1-summary.txt`.
- 15:5x merged on trunk as 3368412d (tree = tested c90c2cfd + the GAP-2b doc only); rerun3 corpus cells green; trunk public on both repos.
- 16:2x PR #16 (head 1e1c26ee, on be01cc7a without KJL) all four jobs green on both runs, prediction met; squash-merged as 9a74408b;
  ndtwin-lab main fast-forwarded to 9a74408b; both mains verified unauthenticated.
