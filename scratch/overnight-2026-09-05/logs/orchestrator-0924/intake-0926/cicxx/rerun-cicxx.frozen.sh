#!/usr/bin/env bash
# rerun-cicxx.frozen.sh -- orchestrator rerun of the formatTime mutation gate on the TEST MERGE
# 59ebd725 (trunk fed37cff + fix/ci-clang-tsan-0927 a956fd78) vs trunk fed37cff, trees from
# `git archive` (no working tree involved). The test file is the test merge's in both variants, so
# only the product code differs. One guard call per cell. TSan / clang are left to the PR's CI run.
# [Co-developed with claude code -- Adam]
set -uo pipefail
REPO=/home/adam/Desktop/NDTwin-Kernel
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
W=$SP/rerun-cicxx; G=$SP/gtest/googletest-03597a01ee50ed33e9dfd640b249b4be3799d395/googletest
GUARD=$REPO/tools/build_guard/guarded_build.sh
export JOBS=1 LOCK_WAIT=10800
rm -rf "$W"; mkdir -p "$W/base" "$W/head"
git -C "$REPO" archive fed37cff include libs tests/test_IpToString.cpp | tar -x -C "$W/base"
git -C "$REPO" archive 59ebd725 include libs tests/test_IpToString.cpp | tar -x -C "$W/head"
cp "$W/head/tests/test_IpToString.cpp" "$W/test_IpToString.cpp"
echo "start $(date -Is)  df=$(df -h / | awk 'NR==2{print $4}')"; g++ --version | head -1
sha256sum "$W/test_IpToString.cpp" "$W/base/include/utils/Utils.hpp" "$W/head/include/utils/Utils.hpp"
FLAGS="-std=c++23 -g -O0 -Wall -Wextra -Wpedantic -Wno-unused-parameter -Wunused -Werror -pthread -DSPDLOG_ACTIVE_LEVEL=SPDLOG_LEVEL_TRACE"
"$GUARD" bash -c "g++ -std=c++23 -O0 -pthread -I$G/include -I$G -c $G/src/gtest-all.cc -o $W/gtest-all.o && g++ -std=c++23 -O0 -pthread -I$G/include -I$G -c $G/src/gtest_main.cc -o $W/gtest_main.o"; echo "gtest objs rc=$?"
for v in base head; do
  "$GUARD" bash -c "g++ $FLAGS -I$W/$v/include -I$W/$v/libs -I$G/include -c $W/test_IpToString.cpp -o $W/t-$v.o && g++ -pthread $W/t-$v.o $W/gtest-all.o $W/gtest_main.o -lssl -lcrypto -o $W/t-$v"; echo "variant $v build rc=$?"
  echo "===== $v TZ unset ====="; env -u TZ "$W/t-$v" --gtest_filter='FormatTimeTest.*'; echo "variant $v TZ-unset rc=$?"
  echo "===== $v TZ=Asia/Taipei ====="; TZ=Asia/Taipei "$W/t-$v" --gtest_filter='FormatTimeTest.*'; echo "variant $v TZ=Asia/Taipei rc=$?"
  echo "===== $v TZ=UTC full file ====="; TZ=UTC "$W/t-$v"; echo "variant $v TZ=UTC all rc=$?"
done
echo "end $(date -Is)"
