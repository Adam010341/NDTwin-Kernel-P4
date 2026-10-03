# CI clang+TSan (fix/ci-clang-tsan-0927) — intake

- **02:1x** Delivered a956fd78: 3 commits on f186ce98, 4 files, +87/−11.
  - Diff read hunk by hunk; secret scan 0/3.
  - Test merge onto fed37cff is 59ebd725, with no conflicts. trunk has no C++/CMake change since f186ce98.
- **02:27** My rerun (`rerun-cicxx.frozen.sh`) started: formatTime mutation gate, base fed37cff vs test merge, TZ unset / Asia/Taipei / UTC.
- **02:5x** Judge verdict MERGE (`judge-CICXX-a956fd78.md`); notes N1–N15, none blocking.
  - I asked for a small 4th commit: N6 (nullptr test, red on base), N5 (a tzset comment), N15 (tags), plus the 3-zone run.
  - Also SUMMARY corrections (§0, §2.1, §3 RAN/INFERRED labels, §4, §5, N10, N13, N14).
- **CI prediction to write before the PR:** clang green (observed only with libstdc++ 13), TSan green, ASan inferred. The GCC job stays red with the same FAILED list.
- **02:55** My rerun finished (`rerun-cicxx.log`):
  - base fed37cff is red under TZ unset, Asia/Taipei and UTC (tm_year 123, tm_yday 318);
  - the test merge is green under all three; the full file under UTC gives 13/13.
- **03:0x** 4th commit 70c54045 (comments only: no non-comment line changed; secret scan 0/3). Judge N6 withdrawn: no int64 ms makes localtime_r fail.
- **03:0x** Merged into trunk as 18c83aba (`git merge --no-ff` in the main checkout; the 4 files were clean there, index empty). Pushed with `push-18c83aba.log`.
- **PR:** d411e852 on main f9be5842, the same 4 files. Its tree equals trunk's, filtered. Prediction: `ci-prediction-pr9.txt`.
- **03:3x** PR #9 CI: clang, TSan and ASan PASS; GCC L1 FAILED list IDENTICAL 29/29 on both runs (`ci-compare-pr9.txt`). Squash-merged as bad4cc7a. Invariant holds, and main is public at bad4cc7a (unauthenticated).
