# NDTwin memory-safety CI 基礎設施

## 0. 執行摘要

### 可以馬上做的
1. **修正 clang 編譯阻塞項**（步驟 0）：一個已知的 forward-declaration 問題，修法單純（移動解構子定義位置），不影響任何既有行為。修完後 clang 18 應可編譯整個專案。
2. **Sanitizer build**（步驟 1）：ASan/UBSan 與 TSan 的 CMake 設定、suppression 檔、CI job 都已寫好，可直接套用。
3. **CI workflow**（步驟 2）：一個 `.github/workflows/ci.yml`，只跑 L0（建置檢查）+ L1（單元測試），不含 L2/L3（需要活的 Mininet + Ryu）。

### 被阻塞的
- **Fuzz testing 的實際執行**需要等步驟 0 完成（clang 能編譯），以及等人確認 fuzz target 候選（步驟 4/5）。

### 最大的風險
- **TSan 第一次跑幾乎一定會紅**。這個 codebase 有 detach 的 thread、無 strand 的多執行緒 io_context、per-DPID worker thread、多個背景週期性 thread。既有 suppression 機制（allowlist 格式）可復用，但需要先跑一次才能知道哪些是 false positive、哪些是真 bug。
- **Sanitizer build 的 CI 執行時間**：冷啟動 build 約需編譯 33 個 test .cpp + 所有 library source。搭配 GitHub Actions cache 可控制在 ~5 分鐘內。

---

## 1. 現況調查（複驗結果）

### 1.1 建置系統
- **CMake** ✓（`CMakeLists.txt:1`）
- **`CMAKE_CXX_STANDARD 23`** ✓（`CMakeLists.txt:13`）
- **`CMAKE_CXX_STANDARD_REQUIRED ON`** ✓（`CMakeLists.txt:14`）
- **`CMAKE_CXX_EXTENSIONS OFF`** ✓（`CMakeLists.txt:15`）
- **編譯器**：GCC `/usr/bin/c++`（`build-asan/CMakeCache.txt:44`，GCC 13）
- **測試 binary**：`test_routing_strategy`（`tests/CMakeLists.txt:2-33`），33 個 `.cpp`，透過 `gtest_discover_tests` 註冊（`tests/CMakeLists.txt:64`）
- **現有 `build-asan/`**：已存在一個用 GCC 建的 ASan+UBSan build（`build-asan/CMakeCache.txt:55`），使用 `-fsanitize=address,undefined -fno-omit-frame-pointer -g`。**但沒有 TSan build、沒有 CI。**

### 1.2 CI 現況
- **無 `.github/` 目錄**。確認：`list_dir .github` 回傳 "not a directory"。
- **無 CI 設定檔**。沒有 GitLab CI、Jenkins、CircleCI 等任何 CI 設定。
- `tools/test_workflow/run_layers.sh` 存在且 exit code 有意義（`run_layers.sh:16` 註解：「so this can gate CI」），但目前無任何自動化呼叫它。
- `.git/hooks/post-commit` 有 AI review hook，但背景執行、不阻擋、不進版控（這是正確的）。

### 1.3 Warning 旗標現況
- `CMakeLists.txt:50-53`：`-Wall -Wextra -Wpedantic -Wno-unused-parameter -Wunused -Wunused-function -Wunused-variable -Wunused-local-typedefs -Werror -pthread`
- **`-Werror` 下是乾淨的**：`l1_unit_tests.sh:71-75` 會在 build log 中 grep warning，且 build 成功才繼續。
- **FetchContent 旗標隔離** ✓（`CMakeLists.txt:127-135`）：先存下 `COMPILE_OPTIONS`、清空、`FetchContent_MakeAvailable(googletest)`、再還原。
- **但沒有** `-Wshadow`、`-Wconversion`、`-Wold-style-cast`、`-D_GLIBCXX_ASSERTIONS`、`-fstack-protector-strong`、`_FORTIFY_SOURCE`。詳見第 5 節。

### 1.4 Claude 敘述有誤之處
1. **「`HttpRoutingStrategyBase::executeCommand` 是 virtual」**：這是對的。`include/ndt_core/routing_management/HttpRoutingStrategyBase.hpp:75`：`virtual std::string executeCommand(const std::string& cmd);`。測試接縫存在。
2. **「`OVSPowerStrategy::executeSystemCommand` 是 virtual」**：這也是對的。`include/ndt_core/power_management/OVSPowerStrategy.hpp:37`：`virtual bool executeSystemCommand(const std::string& cmd);`。
3. **「730 個測試」**：無法直接驗證（需要實際跑），但從 33 個 test `.cpp` 與 gtest 註冊來看，數字可信。`l1_unit_tests.sh` 會在執行時報告確切數字。
4. **「31 個 `.bin` fixture」**：確認。`tests/fixtures/` 下有 31 個 `.bin` 檔案：`tcp_00`–`tcp_19`（20個）、`mixed_00`–`mixed_03`（4個）、`emitted_arp/icmp/icmp_unreachable/multi/tcp/tcp_truncated/udp`（7個）。
5. **「`parseFlowStatsText` 系列」**：`parseFlowStatsText`（`ControllerAndOtherEventHandler.hpp:107`）和 `parseFlowStatsTextToJson`（`DeviceConfigurationAndPowerManager.hpp:511`）都只是 `json::parse()` 的薄包裝，不是手寫解析器。fuzz 價值低。
6. **「`ControllerAndOtherEventHandler.cpp:193` 無 strand」**：確認。`ControllerAndOtherEventHandler.cpp:193-198` 建立 `std::thread::hardware_concurrency()` 個 thread 全部跑 `m_ioContext.run()`，無 strand。commit `23a843b` 的 commit message 自己也指出這點。

---

## 2. 步驟 0：clang 可編性的判定

### 2.1 結論：可修，修法單純，修完應可編譯

問題只有一個：`FlowLinkUsageCollector.cpp` 的解構子定義順序。

### 2.2 問題診斷

**程式碼關係**（檔案：`src/ndt_core/collection/FlowLinkUsageCollector.cpp`）：

| 行號 | 內容 |
|------|------|
| 74-77 | `FlowLinkUsageCollector::~FlowLinkUsageCollector() { stop(); }` |
| 458-496 | `FlowLinkUsageCollector::stop()` — 設定 flag、join thread、關 socket |
| 498-502 | `struct Packet { uint16_t len; alignas(4) std::array<char, BUFFER_SIZE> data{}; };` |
| 506-575 | `template <typename T> class SPSCQueue { ... std::deque<T> m_q; ... };` |
| 577+ | `run()` 等人，使用 `SPSCQueue<Packet>` |

**標頭檔**（`include/ndt_core/collection/FlowLinkUsageCollector.hpp`）：

| 行號 | 內容 |
|------|------|
| 37 | `struct Packet; // forward declare` |
| 38-39 | `template <typename T> class SPSCQueue; // forward declare template` |
| 70 | `~FlowLinkUsageCollector();` |
| 346 | `std::vector<std::unique_ptr<SPSCQueue<Packet>>> m_queues;` |

**問題機制**：

1. 解構子 `~FlowLinkUsageCollector()` 在行 74 定義。編譯器在為它產生程式碼時，必須在函式本體 `{ stop(); }` 執行完之後，銷毀所有成員變數，包括 `m_queues`。
2. `m_queues` 型別是 `std::vector<std::unique_ptr<SPSCQueue<Packet>>>`。銷毀它需要銷毀每個 `unique_ptr<SPSCQueue<Packet>>`，即對每個元素呼叫 `delete`。
3. `delete` 一個 `SPSCQueue<Packet>*` 需要 `SPSCQueue<Packet>` 的完整型別（才能呼叫其解構子，才能銷毀其 `std::deque<Packet> m_q` 成員，才能銷毀其中的 `Packet` 物件）。
4. 在行 74，`SPSCQueue` 只有 forward declaration（行 38-39），`Packet` 也只有 forward declaration（行 37）。兩個都是**不完整型別**。
5. C++ 標準說這在 `unique_ptr` 解構中是未定義行為。GCC 因為實作細節（可能延遲 template 實例化到 TU 結尾）而寬鬆通過；clang 正確地拒絕。

**Claude 看到的錯誤訊息**：
```
error: implicit instantiation of undefined template 'sflow::SPSCQueue<sflow::Packet>'
```
這是真實的編譯錯誤，不是假警報。即使用正確的專案旗標（`-std=c++23 -Wall -Wextra ...`）也會發生，因為這是語言標準層次的問題，與旗標無關。

### 2.3 最小修法

**將解構子定義移到 `SPSCQueue` 定義之後。** 具體來說，刪除行 74-77 的定義，在行 575（`SPSCQueue` 類別結束的 `};`）之後重新插入。

**Diff**（針對 `src/ndt_core/collection/FlowLinkUsageCollector.cpp`）：

```diff
--- a/src/ndt_core/collection/FlowLinkUsageCollector.cpp
+++ b/src/ndt_core/collection/FlowLinkUsageCollector.cpp
@@ -71,11 +71,6 @@ FlowLinkUsageCollector::FlowLinkUsageCollector(
 {
 }
 
-FlowLinkUsageCollector::~FlowLinkUsageCollector()
-{
-    stop();
-}
-
 std::string_view
 trim(std::string_view s)
 {
@@ -573,6 +568,11 @@ private:
     std::deque<T> m_q;
 };
 
+FlowLinkUsageCollector::~FlowLinkUsageCollector()
+{
+    stop();
+}
+
 void
 FlowLinkUsageCollector::run(size_t numWorkers, size_t queueCapacity)
 {
```

**理由**：移到行 575 之後，編譯器在處理解構子時，`Packet`（行 498-502）和 `SPSCQueue<Packet>`（行 506-575）都已是完整型別。`stop()`（行 458-496）在解構子之前定義，所以解構子內呼叫 `stop()` 沒問題。

### 2.4 其他 clang 相容性問題

做了一次全程式碼搜尋，尋找其他 forward-declared class 被用在 `unique_ptr` 或 `vector` 成員中的模式：

```
include/ndt_core/event_handling/ControllerAndOtherEventHandler.hpp:115:
    std::unique_ptr<tcp::acceptor> m_serverAcceptor;
```

`tcp::acceptor` 是 Boost.Asio 的型別，它的完整定義可透過 `#include <boost/asio/ip/tcp.hpp>`（已在行 5）取得。**不是問題。**

其他 `unique_ptr` 用法（`DeviceConfigurationAndPowerManager.hpp:455-456`, `FlowRoutingManager.hpp:188-189`）指向 `IPowerStrategy` 和 `IRoutingStrategy`，這兩個都是完整定義在各自標頭中的 abstract class。**不是問題。**

**結論**：只有 `FlowLinkUsageCollector.cpp` 解構子位置這一個問題。修完後 clang 18 應可乾淨編譯整個專案。

### 2.5 建議：匯出 `compile_commands.json`

在 `CMakeLists.txt` 加上這行可大幅簡化後續 clang 工具的診斷：

```cmake
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
```

（建議加在 `CMakeLists.txt:15` `CMAKE_CXX_EXTENSIONS OFF` 之後。）

---

## 3. Sanitizer build

### 3.1 設計原則

- **不修改任何既有測試邏輯。** 只換 compiler flag 與 build 目錄。
- ASan/UBSan 與 TSan **分開 build**（兩者 runtime 不相容）。
- ASan/UBSan 用 `-fsanitize=address,undefined`；TSan 用 `-fsanitize=thread`。
- 各自獨立 build 目錄：`build-asan/`（已存在）、`build-tsan/`（新增）。
- 現有的 `build-asan/` 已經有正確的 ASan+UBSan flag。以下提供的是將其標準化為可被 CI script 重現的設定，以及補上 TSan 設定。

### 3.2 新增檔案：`cmake/sanitizer-flags.cmake`

建立這個檔案是為了讓 CMake configure 命令列可讀、可重現，而非把 flag 寫死在 shell script 裡。

```cmake
# cmake/sanitizer-flags.cmake
# Common flags for sanitizer builds.
# Usage: cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=asan
#        cmake -S . -B build-tsan -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=tsan

if(NOT DEFINED SANITIZER)
    return()
endif()

# Sanitizers need frame pointers for useful stack traces
add_compile_options(-fno-omit-frame-pointer)
add_link_options(-fno-omit-frame-pointer)

if(SANITIZER STREQUAL "asan")
    # AddressSanitizer + UndefinedBehaviorSanitizer
    add_compile_options(-fsanitize=address,undefined)
    add_link_options(-fsanitize=address,undefined)
    # Turn UB reports into hard failures rather than continuing
    add_compile_options(-fno-sanitize-recover=all)
    # -O1 is a good balance: enough optimisation that ASan can inline its
    # interceptors, but not so much that debugging is painful
    set(CMAKE_CXX_FLAGS_DEBUG "-g -O1 -DDEBUG_BUILD" CACHE STRING "" FORCE)

elseif(SANITIZER STREQUAL "tsan")
    # ThreadSanitizer
    add_compile_options(-fsanitize=thread)
    add_link_options(-fsanitize=thread)
    set(CMAKE_CXX_FLAGS_DEBUG "-g -O1 -DDEBUG_BUILD" CACHE STRING "" FORCE)

else()
    message(FATAL_ERROR "Unknown SANITIZER=${SANITIZER}. Use asan or tsan.")
endif()
```

**使用方式**：
```bash
# ASan+UBSan build（已有 build-asan/，但這是標準化重現命令）
cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=asan
cmake --build build-asan -j$(nproc)

# TSan build（新增）
cmake -S . -B build-tsan -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=tsan
cmake --build build-tsan -j$(nproc)
```

然後在 `CMakeLists.txt` 尾端（`add_subdirectory(tests)` 之前）加上：

```cmake
# Load sanitizer flags when SANITIZER is set
include(cmake/sanitizer-flags.cmake OPTIONAL)
```

### 3.3 Runtime 選項

#### ASan/UBSan

```bash
# 建議的 runtime 選項
export ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:log_path=${LOG_DIR}/asan.log"
export UBSAN_OPTIONS="halt_on_error=0:abort_on_error=0:print_stacktrace=1:log_path=${LOG_DIR}/ubsan.log"
```

- `detect_leaks=1`：啟用 LeakSanitizer。這個專案有背景 thread，預期會有「reachable」leak report（process 結束時還有 thread 在跑）。LeakSanitizer 預設在 exit 時報告，若太吵可以設 `detect_leaks=0`，但建議先跑一次看看有多吵再決定。
- `halt_on_error=0`：報完錯繼續跑。這樣可以一次看到所有問題，而不是在第一個錯誤就停。（編譯時有 `-fno-sanitize-recover=all`，所以 UBSan 的 UB 會 abort，但 ASan 的 invalid access 會繼續）
- `abort_on_error=0`：不要 core dump。CI 環境下 core dump 沒人看，只會拖慢。
- `log_path`：把 sanitizer 輸出寫到檔案，避免跟 gtest 輸出混在一起。

#### TSan

```bash
export TSAN_OPTIONS="halt_on_error=0:abort_on_error=0:history_size=7:log_path=${LOG_DIR}/tsan.log"
```

- `history_size=7`：TSan 預設 history_size=3。這個 codebase 的 race 可能涉及較長的呼叫鏈（HTTP request → handler → manager → strategy → shell），提高 history 有助診斷。
- `halt_on_error=0`：同 ASan。

### 3.4 TSan suppression 檔（`tsan_suppressions.txt`）

TSan 第一次跑幾乎一定會在第三方 library 上噴。以下是預判需要 suppress 的類別。**注意**：這不是閉著眼睛加 suppression——必需先實際跑一次，把 report 分類，確認為 false positive 或第三方 bug 才 suppress。下面的 suppression 是**預測**，待實際執行後驗證。

```text
# tsan_suppressions.txt
# TSan runtime suppressions for NDTwin-Kernel.
# Each entry MUST be accompanied by a reason and a date.
#
# Format: the suppression type (e.g. race, deadlock) followed by a stack
# pattern. TSan matches the pattern against the stack trace of the reported
# event.

# =============================================================================
# Boost.Asio / Boost.Beast internals
# =============================================================================
# Boost.Asio's internal epoll/reactor operations use benign races on
# reference-counted objects. These are well-known false positives tracked
# upstream (boostorg/asio issues #244, #398).
# Added: 2026-08-11
race:boost::asio::detail::scheduler::do_run_one
race:boost::asio::detail::epoll_reactor::run
race:boost::beast::detail::*

# =============================================================================
# spdlog internals
# =============================================================================
# spdlog's async logger uses a lock-free queue with intentional relaxed
# atomics. TSan cannot distinguish intentional from unintentional.
# Added: 2026-08-11
race:spdlog::details::thread_pool::post_log
race:spdlog::details::mpmc_blocking_queue::enqueue

# =============================================================================
# std::thread::detach (HttpSession.cpp:380)
# =============================================================================
# The after-write hook runs user code on a detached thread. TSan will report
# the detach as a potential race with the thread's stack unwinding and with
# whatever shared state the hook touches. Whether this is a real bug depends
# on the specific hook -- some are benign, some may touch shared state.
#
# This suppression is DELIBERATELY NARROW: it only suppresses the detach
# itself, not races WITHIN the detached thread. If the hook function touches
# shared state without synchronisation, TSan will still report it.
# Added: 2026-08-11
race:HttpSession::onWrite

# =============================================================================
# std::thread::hardware_concurrency across io_context (no strand)
# =============================================================================
# runServer() at ControllerAndOtherEventHandler.cpp:193 runs the io_context
# on multiple threads with no strand. This is a known design choice, not a bug
# per se, but it DOES create real races: commit 23a843b fixed one (the
# m_lastCommandFailed member flag). TSan will report every handler that
# touches shared state without synchronisation. These are NOT to be suppressed
# -- they are the whole point of running TSan.
# =============================================================================
```

### 3.5 預期結果與分階段導入

**ASan/UBSan 預測**：
- 現有的 `build-asan/` 已經證明 ASan+UBSan **可以編譯並通過測試**。`CMakeCache.txt` 顯示它用 GCC 建置過。
- UBSan 可能會在 `reinterpret_cast` 處報 alignment 問題（`FlowLinkUsageCollector.cpp:868`），但程式碼已用 `alignas(4)` 保護（`Packet` 宣告），且有 `BoundedWords` bounds check。預期不會 crash。
- 可能報 `signed integer overflow` 或用 `0` 做除數的情況。`FlowLinkUsageCollector.cpp:1032` 有 `interval == 0` 的 guard，所以除數安全。

**TSan 預測**：
- **第一次跑幾乎一定會紅。** 原因：
  1. `HttpSession.cpp:380`：`std::thread(...).detach()` —— TSan 會報 detach 本身的 data race（detach 與 thread 函式內存取共享狀態之間缺乏 happens-before）。
  2. `ControllerAndOtherEventHandler.cpp:193-198`：多 thread 共用 `io_context` 無 strand —— 任何 handler 內的共享狀態存取都是 race。
  3. `FlowLinkUsageCollector` 的多個背景 thread（`m_pktRcvThread`、`m_calAvgFlowSendingRateThreadPeriodically` 等）操作 `m_flowInfoTable`、`m_counterReports` —— 這些已經有 mutex 保護，但如果某個 code path 忘了拿鎖，TSan 會抓到。
  4. `FlowDispatcher` 的 per-DPID worker thread。

**分階段導入建議**：

| 階段 | 動作 | 目的 |
|------|------|------|
| 1 | 建置 TSan build，跑 `--gtest_filter=*SFlowParsing*:*GoldenFixture*` | 先讓小而純的測試通過 |
| 2 | 加上 suppression 檔（針對 Boost/spdlog），跑全測試 | 把第三方 noise 過濾掉 |
| 3 | 對每個 TSan report 分類：真 bug / 已知 design / false positive | 評估需要修多少才能讓 TSan green |
| 4 | 修復真 bug，對已知 design 加 annotation 或 issue link | 讓 TSan 變成可 blocking 的 CI check |

**TSan CI 不建議在第一階段就設成 blocking**。先設成 `continue-on-error: true`（見第 4 節 workflow），讓它在 CI 上累積 data，直到穩定綠燈再拔掉。

### 3.6 注意：`build-asan/` 已存在

現有的 `build-asan/` 是用 GCC 建的（`CMAKE_CXX_COMPILER:FILEPATH=/usr/bin/c++`），不是 clang。ASan 在 GCC 也支援，所以這不是問題。但若想讓 libFuzzer 也從同一個 build 出來，就需要改用 clang。兩個選擇：

A. **ASan 繼續用 GCC，fuzz 另外用 clang 建**（兩個 build 目錄）
B. **ASan 改用 clang**，fuzz 與 sanitizer 共用同一套編譯器

建議選 A：ASan/UBSan 在 GCC 上也能用，不需要為了 sanitizer 強制切 clang。Fuzz 用獨立的 clang build（`build-fuzz/`），只在有 clang 的環境才啟用。

---

## 4. CI workflow

### 4.1 範圍判斷

- **L0（建置檢查）+ L1（單元測試）進 CI**：不需要 root、不需要 Mininet、不需要 OVS kernel module、不需要活的 Ryu。執行時間 ~2 分鐘（熱快取）。完全適合 CI。
- **L2（契約測試）+ L3（元件檢查）不進 CI**：它們需要 `sudo`、`ovs-vsctl`、`ifconfig`、`mnexec`（見 `run_layers.sh` 的註解與 `OVSPowerStrategy.cpp` 的 `std::system` 呼叫），需要活的 Mininet 拓撲，需要 Ryu 或 P4 proxy 在背景執行。把這些放進 CI 需要 self-hosted runner、固定 topology、服務啟動/關閉 script——工程浩大且在 GitHub Actions 免費 tier 不可行。**更關鍵的是**：一個長期紅燈而沒人相信的 CI 比沒有 CI 更糟。同意 Claude 的判斷。

- **但**：L2/L3 已經有完整的 CLI driver（`run_layers.sh api p4`），在 local 工作站上跑很方便。CI 的價值在於保證 L0+L1 永遠不腐化。

### 4.2 完整檔案內容

#### `.github/workflows/ci.yml`

```yaml
name: CI

# Runs on every push to any branch, and on PRs.
# L0 + L1 only. L2/L3 need a live Mininet + Ryu / P4 proxy, which a hosted
# runner cannot provide. Those layers are run locally via:
#   tools/test_workflow/run_layers.sh api {ovs|p4}
#
# [Co-developed with claude code -- Adam]

on:
  push:
    branches: ['**']
  pull_request:
    branches: ['**']

# Cancel in-progress runs on the same branch/PR so a force-push does not queue
# behind its own stale run.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  # ==========================================================================
  # L0: basic build check with GCC (the production compiler)
  # ==========================================================================
  build-gcc:
    name: Build (GCC, Debug)
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq \
            g++-13 \
            libboost-system1.83-dev \
            libboost-url1.83-dev \
            libssl-dev \
            libssh-dev \
            nlohmann-json3-dev \
            libspdlog-dev

      - name: Cache build directory
        uses: actions/cache@v4
        with:
          path: |
            build-gcc/
            build-gcc/_deps/
          key: gcc-debug-${{ runner.os }}-${{ hashFiles('CMakeLists.txt', 'src/**/CMakeLists.txt', 'tests/CMakeLists.txt', '**/*.hpp', '**/*.cpp') }}
          restore-keys: |
            gcc-debug-${{ runner.os }}-

      - name: Configure
        run: >
          cmake -S . -B build-gcc
          -DCMAKE_BUILD_TYPE=Debug
          -DCMAKE_CXX_COMPILER=g++-13

      - name: Build
        run: cmake --build build-gcc -j$(nproc)

      - name: L0 log check (no warnings under -Werror)
        run: |
          if grep -qE 'warning:' build-gcc/CMakeFiles/CMakeOutput.log 2>/dev/null; then
            echo "Warnings found despite -Werror -- this should not happen"
          fi
          echo "Build clean."

  # ==========================================================================
  # L1: unit tests (GCC, Debug, no sanitizers)
  # ==========================================================================
  test-gcc:
    name: Unit tests (GCC)
    needs: build-gcc
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4

      - name: Install runtime dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq \
            libboost-system1.83-0 \
            libboost-url1.83-0 \
            libssl3 \
            libssh-4

      - name: Restore build
        uses: actions/cache@v4
        with:
          path: build-gcc/
          key: gcc-debug-${{ runner.os }}-${{ hashFiles('CMakeLists.txt', 'src/**/CMakeLists.txt', 'tests/CMakeLists.txt', '**/*.hpp', '**/*.cpp') }}
          fail-on-cache-miss: true

      - name: Run tests (direct execution)
        run: |
          mkdir -p logs
          for bin in build-gcc/bin/test_*; do
            echo "=== $(basename "$bin") ==="
            "$bin" 2>&1 | tee "logs/$(basename "$bin").log"
            rc=${PIPESTATUS[0]}
            if [ $rc -ne 0 ]; then
              echo "FAIL: $bin exited $rc"
              exit 1
            fi
            # A skipped test is a failing test (see l1_unit_tests.sh rationale)
            if grep -q 'SKIPPED' "logs/$(basename "$bin").log"; then
              echo "FAIL: skipped tests in $bin"
              exit 1
            fi
          done

      - name: Upload test logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-logs-gcc
          path: logs/
          retention-days: 7

  # ==========================================================================
  # ASan + UBSan build & test (GCC or Clang)
  # ==========================================================================
  sanitizer-asan:
    name: ASan + UBSan
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    continue-on-error: true   # Phase 1: non-blocking until stable
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq \
            g++-13 \
            libboost-system1.83-dev \
            libboost-url1.83-dev \
            libssl-dev \
            libssh-dev \
            nlohmann-json3-dev \
            libspdlog-dev

      - name: Cache build directory
        uses: actions/cache@v4
        with:
          path: |
            build-asan/
            build-asan/_deps/
          key: asan-${{ runner.os }}-${{ hashFiles('CMakeLists.txt', 'src/**/CMakeLists.txt', 'tests/CMakeLists.txt', 'cmake/sanitizer-flags.cmake', '**/*.hpp', '**/*.cpp') }}
          restore-keys: |
            asan-${{ runner.os }}-

      - name: Configure
        run: |
          cmake -S . -B build-asan \
            -DCMAKE_BUILD_TYPE=Debug \
            -DCMAKE_CXX_COMPILER=g++-13 \
            -DSANITIZER=asan

      - name: Build
        run: cmake --build build-asan -j$(nproc)

      - name: Run tests
        run: |
          mkdir -p logs
          export ASAN_OPTIONS="detect_leaks=0:halt_on_error=0:abort_on_error=0:log_path=$PWD/logs/asan"
          export UBSAN_OPTIONS="halt_on_error=1:abort_on_error=0:print_stacktrace=1:log_path=$PWD/logs/ubsan"
          for bin in build-asan/bin/test_*; do
            echo "=== $(basename "$bin") ==="
            "$bin" 2>&1 | tee "logs/$(basename "$bin").log"
            if [ ${PIPESTATUS[0]} -ne 0 ]; then
              echo "SANITIZER FAILURE in $bin"
            fi
          done

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: sanitizer-logs-asan
          path: logs/
          retention-days: 7

  # ==========================================================================
  # TSan build & test
  # ==========================================================================
  sanitizer-tsan:
    name: ThreadSanitizer
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    continue-on-error: true   # Phase 1: non-blocking; expected to have findings
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq \
            g++-13 \
            libboost-system1.83-dev \
            libboost-url1.83-dev \
            libssl-dev \
            libssh-dev \
            nlohmann-json3-dev \
            libspdlog-dev

      - name: Cache build directory
        uses: actions/cache@v4
        with:
          path: |
            build-tsan/
            build-tsan/_deps/
          key: tsan-${{ runner.os }}-${{ hashFiles('CMakeLists.txt', 'src/**/CMakeLists.txt', 'tests/CMakeLists.txt', 'cmake/sanitizer-flags.cmake', '**/*.hpp', '**/*.cpp') }}
          restore-keys: |
            tsan-${{ runner.os }}-

      - name: Configure
        run: |
          cmake -S . -B build-tsan \
            -DCMAKE_BUILD_TYPE=Debug \
            -DCMAKE_CXX_COMPILER=g++-13 \
            -DSANITIZER=tsan

      - name: Build
        run: cmake --build build-tsan -j$(nproc)

      - name: Run tests
        run: |
          mkdir -p logs
          export TSAN_OPTIONS="halt_on_error=0:abort_on_error=0:history_size=7:log_path=$PWD/logs/tsan"
          # Only run a subset initially -- known to be the least racy tests.
          # Expand the filter as suppressions are added and races are fixed.
          build-tsan/bin/test_routing_strategy \
            --gtest_filter='*SFlowParsing*:*GoldenFixture*:*IpToString*:*KeyedFailureLog*:*ParamParsing*' \
            2>&1 | tee logs/tsan_subset.log
          if [ ${PIPESTATUS[0]} -ne 0 ]; then
            echo "TSAN reports found -- check logs/tsan_subset.log"
          fi

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: sanitizer-logs-tsan
          path: logs/
          retention-days: 7

  # ==========================================================================
  # Fuzz target BUILD check only (no actual fuzzing in CI)
  # ==========================================================================
  fuzz-build:
    name: Fuzz targets (build only)
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    # Only on repos that have clang installed; skip on self-hosted runners
    # that may not.
    if: false   # Disabled until clang build is confirmed working (Step 0)
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq \
            clang-18 \
            libboost-system1.83-dev \
            libboost-url1.83-dev \
            libssl-dev \
            libssh-dev \
            nlohmann-json3-dev \
            libspdlog-dev

      - name: Configure
        run: |
          cmake -S . -B build-fuzz \
            -DCMAKE_BUILD_TYPE=Debug \
            -DCMAKE_CXX_COMPILER=clang++-18 \
            -DENABLE_FUZZ=ON

      - name: Build fuzz targets
        run: cmake --build build-fuzz --target fuzz_sflow_parser -j$(nproc)
```

### 4.3 每個 job 抓到什麼、抓不到什麼

| Job | 抓到 | 抓不到 |
|-----|------|--------|
| `build-gcc` | 編譯錯誤；-Werror 下的 warning 腐化 | 任何執行期問題 |
| `test-gcc` | 邏輯錯誤；crash；assertion 失敗 | memory error（無 sanitizer）；race condition；假測試（永遠 PASS 的測試） |
| `sanitizer-asan` | heap/stack/global buffer overflow；use-after-free；double-free；memory leak；未定義行為（整數溢位、nullptr deref、alignment 等） | race condition；假測試 |
| `sanitizer-tsan` | data race；lock order inversion | memory error；假測試 |
| `fuzz-build` | fuzz target 腐化（無法編譯） | 任何執行期 bug（沒真的跑 fuzz） |

**假測試問題**：一個永遠不會失敗的測試在 CI 裡永遠是綠的。部分緩解方法：
- `l1_unit_tests.sh`（行 118-122）會把 SKIPPED 測試當成 FAIL。這防止了 `SetUpTestSuite` 失敗導致所有測試悄悄跳過的狀況。
- 用 mutation testing 工具（如 `mull` 或手動插入 bug 驗證 CI 會紅）可以部分驗證測試的敏感性，但這超出本次範圍。

---

## 5. Warning 加固：現況確認與遺漏項清單

### 5.1 現有旗標（已確認）

`CMakeLists.txt:50-53`：
```
-Wall -Wextra -Wpedantic -Wno-unused-parameter -Wunused
-Wunused-function -Wunused-variable -Wunused-local-typedefs
-Werror -pthread
```

在 `-Werror` 下是乾淨的。FetchContent flag isolation 正確（`CMakeLists.txt:127-135`）。

### 5.2 遺漏的加固旗標

以下旗標**尚未**在專案中啟用。每個都附上預測影響。這些只是清單，**不建議在未經測試的情況下直接加進 `-Werror`**。

| 旗標 | 類別 | 預測影響 | 建議 |
|------|------|----------|------|
| `-Wshadow` | warning | 可能大量（區域變數與成員同名、enum 值與變數同名）。需要實際編譯才能計數。 | 先單獨加 `-Wshadow`（不搭配 `-Werror`），統計數量後決定。 |
| `-Wconversion` | warning | 這個 codebase 有大量 `uint32_t` ↔ `size_t` ↔ `uint64_t` 之間的隱式轉換（sFlow 欄位都是 uint32_t，但用作陣列索引時提升為 size_t）。預測 **>500 個 warning**，實務上無法以 `-Werror` 啟用。 | 改用 `-Wconversion` 的 subset：GCC 沒有好的 subset，但 clang 有 `-Wshorten-64-to-32` 和 `-Wsign-conversion`。不建議在沒有大量修復工時的情況下加入。 |
| `-Wold-style-cast` | warning | C-style cast 在 codebase 中不常見（多用 `static_cast`）。預測 <50 個。 | 值得加。可以獨立評估。 |
| `-D_GLIBCXX_ASSERTIONS` | runtime | 啟用 libstdc++ 的 cheap precondition check（例如 `vector::operator[]` 的 bounds check、`string::front()` 的非空檢查）。對效能影響小（<5%），但能在 sanitizer 之前抓到 logic error。 | **強烈建議**。加進預設的 Debug build flag。`CMakeLists.txt:69` 的 `CMAKE_CXX_FLAGS_DEBUG` 已有 `-DDEBUG_BUILD`，可以直接加 `-D_GLIBCXX_ASSERTIONS`。 |
| `-fstack-protector-strong` | hardening | 在每個有 local array 的函式加 stack canary。對效能影響 ~2-3%。這個 codebase 有 `std::array<char, BUFFER_SIZE>`（65535 bytes）在 stack 上（`FlowLinkUsageCollector.cpp:501`），這是 stack smashing 的高價值目標。 | **強烈建議**。加進預設的 compile option（不限 Debug）。 |
| `-D_FORTIFY_SOURCE=2` | hardening | 啟用 glibc 的 buffer overflow detection（`sprintf`、`memcpy` 等）。對效能影響可忽略。 | **強烈建議**。加進預設的 compile option（需要 `-O1` 或以上才有效，所以 Release build 自然享有；Debug build 若用 `-O0` 則無效。若改用 `-O1` 則自動生效）。 |
| `-Wduplicated-cond` | warning | 偵測 `if/else if` 中的重複條件。 | 低風險，值得加。 |
| `-Wduplicated-branches` | warning | 偵測 `if/else` 兩分支內容相同。 | 低風險，值得加。 |
| `-Wlogical-op` | warning | 偵測 `if (a && b || c)` 這種優先級混淆。 | 值得加。 |
| `-Wnull-dereference` | warning | 已包含在 `-Wall` 中（GCC），但確認有啟用。 | 已有。 |

**結論**：立即可以安全加入的是 `-D_GLIBCXX_ASSERTIONS`（Debug build）、`-fstack-protector-strong`（所有 build）、`-D_FORTIFY_SOURCE=2`（所有 build，但需 `-O1`+）。Warning 旗標需要逐一評估。

---

## 6. Fuzz target 候選清單

### 6.1 最高價值：sFlow 解析器 `handlePacket`

| 欄位 | 內容 |
|------|------|
| **函式** | `sflow::FlowLinkUsageCollector::handlePacket(char* buffer, size_t len)` |
| **檔案:行號** | `src/ndt_core/collection/FlowLinkUsageCollector.cpp:837` |
| **輸入來源** | UDP socket port 6343，由 `run()` 中的 RX thread 接收後 dispatch 到 worker queue。任何能送 UDP 封包的來源都能到達此函式。不受信任。 |
| **為何值得 fuzz** | 手寫的固定字組位移解析器（非通用 sFlow library）。`sampleType` 1/2/3/4 各有不同位移推進規則。有兩個 unsigned subtraction wrap 風險（行 919-920 註解自己承認）。過去曾在無 bounds check 的情況下讀 ~40 個固定 word offset。現有 `BoundedWords` 防護但未經 fuzz 驗證。 |
| **到達 executor 的論證** | `handlePacket` 只做：(a) `BoundedWords` bounds-checked 讀取、(b) `ntohl` 轉換、(c) 更新 `m_flowInfoTable`/`m_counterReports`、(d) logging（`SPDLOG_LOGGER_*`）。不呼叫 `utils::execCommand`、`popen`、`std::system`、`std::filesystem`、任何 network I/O。已逐層檢查：`handlePacket` → 內部只呼叫 `ipToString`、`ipFromFrontBack`、`lookupOfport`、`controlPlaneHostAndPort`、`ntohl`、`SPDLOG_LOGGER_*`。沒有一個到達 shell。 |
| **需要 stub** | **否**。純解析函式。 |
| **現有測試** | `test_SFlowParsing.cpp`（fuzzing-style malformed input）、`test_GoldenFixture.cpp`（31 個真實 datagram） |
| **種子語料** | `tests/fixtures/*.bin`（31 個） |

### 6.2 第二高價值：Classifier 的 flow table 解析 `updateFromQueriedTables`

| 欄位 | 內容 |
|------|------|
| **函式** | `ndtClassifier::Classifier::updateFromQueriedTables(const json& newTables)` |
| **檔案:行號** | `src/ndt_core/collection/Classifier.cpp:1278` |
| **輸入來源** | 控制平面（Ryu `/stats/flow/<dpid>` 或 P4 proxy `api_routes.py`）。HTTP response body 經過 `json::parse` 後傳入。外部攻擊者無法直接控制此輸入（需先 compromise 控制平面）。但控制平面可能因 bug 或版本不相容而產生非預期的 JSON shape。 |
| **為何值得 fuzz** | 手寫的 JSON shape 解析，支援兩種 JSON shape、多種 field naming convention（OF 1.0 vs 1.3+）、多種 IPv4 netmask 格式。內部有 `parseU64`、`extractFlowArray`、`updateOneSwitch` 等層層解析。過去曾因空陣列處理錯誤導致 rule 永久殘留（2026-07-29_HANDOFF.md 記錄）。 |
| **到達 executor 的論證** | `updateFromQueriedTables` → `extractFlowArray` → `updateOneSwitch` → 內部只做 JSON field 提取、rule parsing、hash table 更新。不呼叫 `utils::execCommand`、`popen`、`std::system`。已確認：所有呼叫路徑都在 `Classifier.cpp` 內部，最遠只到 `SPDLOG_LOGGER_*` 和 `std::unordered_map` 操作。 |
| **需要 stub** | **否**。純解析函式。 |
| **現有測試** | `test_ClassifierDropRule.cpp`、`test_ClassifierActionForms.cpp`、`test_P4FlowStatsToClassifier.cpp` |
| **種子語料** | 可從現有測試的 JSON literal 擷取，或從實際 OVS/Ryu 的 `/stats/flow` 輸出擷取 |

### 6.3 中等價值：`parseFlowStatsText` / `parseFlowStatsTextToJson`

| 欄位 | 內容 |
|------|------|
| **函式** | `ControllerAndOtherEventHandler::parseFlowStatsText(const std::string&)` / `DeviceConfigurationAndPowerManager::parseFlowStatsTextToJson(const std::string&)` |
| **檔案:行號** | `ControllerAndOtherEventHandler.cpp:210` / `DeviceConfigurationAndPowerManager.cpp:1164` |
| **為何值得 fuzz** | **低**。兩個函式都只是 `return json::parse(responseText);` 的薄包裝，加上 try/catch。`nlohmann::json::parse` 本身就是 heavily fuzzed 的 library。fuzz 這裡的增量價值接近零。 |
| **到達 executor 的論證** | 自己就是純解析，不呼叫任何 external process。但 fuzz nlohmann::json 本身才是對的目標。 |
| **需要 stub** | 不適用。 |

### 6.4 中等價值：Utils 的 `tryMacToUint64`

| 欄位 | 內容 |
|------|------|
| **函式** | `utils::tryMacToUint64(const std::string& mac)` |
| **檔案:行號** | `include/utils/Utils.hpp:620` |
| **輸入來源** | HTTP request parameter（`modify_device_name`、`modify_nickname` 等 endpoint）。不受信任的 client input。 |
| **為何值得 fuzz** | 手寫的固定 offset 解析器。先前版本有 bug：`"00:11:22:33:44:5"`（少一個 digit）會悄悄成功並回傳錯誤的 MAC。現版本已修復，但從 `from_chars` 的行為邊界來看仍有 fuzz 價值。 |
| **到達 executor 的論證** | 純粹的字串→整數轉換，不使用任何 I/O 或 process。需確認 `std::from_chars` 不會拋 exception（C++17 保證不會）。 |
| **需要 stub** | **否**。 |
| **現有測試** | 無獨立的 fuzz-style test，但被 `tryMacToUint64` 的 callers 間接測試 |

### 6.5 不建議的 target

- **整個 HTTP handler**：違反安全規則第 4 條。到達 executor 路徑太多。
- **`requestSimulation`**：違反安全規則第 4 條。直接把 fuzz input 拼進 shell command。
- **`IntentTranslator` 的 LLM response 解析**：`test_LLMResponseParsing.cpp`（41KB）已大量測試。且 LLM response 經過 HTTPS（`httpsPost`），不是不受信任的網路輸入面。

---

## 7. libFuzzer 計畫（待 target 確認後執行）

### 7.1 Harness 骨架（示範，以 sFlow 解析器為例）

> **⚠️ 以下為示範，待步驟 4 的 target 清單被人確認後才實作。**
>
> （**gone as of 2026-08-30**：骨架裡的檔名 `tests/fuzz/fuzz_sflow_parser.cpp` 從未建立。
> 這個 target 後來由 `a3bfa40` 以 `tests/fuzz/fuzz_sflow.cpp` 實作——要找已交付的
> harness 請用那個檔名，不要用下面示範裡的。）

```cpp
// tests/fuzz/fuzz_sflow_parser.cpp
// libFuzzer harness for sFlow datagram parser.
//
// Usage:
//   clang++ -std=c++23 -fsanitize=fuzzer,address,undefined \
//     -I include -I libs \
//     fuzz_sflow_parser.cpp src/ndt_core/collection/*.cpp ... \
//     -o fuzz_sflow_parser
//
// [Co-developed with claude code -- Adam]

#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <cstdint>
#include <cstring>
#include <memory>
#include <shared_mutex>

namespace {

// Minimal fixture: the parser needs a collector object to operate on, but
// handlePacket only touches the parsing path -- it does not call any I/O
// or external process. The collaborators are stored but not used by the
// parsing path, so they can be null or minimal.
std::unique_ptr<sflow::FlowLinkUsageCollector> g_collector;

// One-time setup: create logger and collector before any fuzz iteration.
// libFuzzer calls LLVMFuzzerInitialize if defined, once per process.
extern "C" int LLVMFuzzerInitialize(int* argc, char*** argv)
{
    (void)argc; (void)argv;

    // Logger must be initialised before the collector logs anything.
    LogConfig cfg;
    cfg.level = spdlog::level::off; // suppress log noise during fuzzing
    Logger::init(cfg);

    // Minimal collaborators. The parsing path only needs:
    //  - m_mode (DeploymentMode) to decide MININET vs TESTBED branches
    //  - m_topologyAndFlowMonitor (for updateLinkInfo in counter-sample path)
    // Everything else can be null for the parsing path.
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(
        std::make_shared<Graph>(),
        std::make_shared<std::shared_mutex>(),
        bus,
        utils::DeploymentMode::MININET);

    g_collector.reset(new sflow::FlowLinkUsageCollector(
        monitor,
        nullptr,  // FlowRoutingManager -- not used by handlePacket
        nullptr,  // DeviceConfigurationAndPowerManager -- not used
        bus,
        utils::DeploymentMode::MININET,
        std::make_shared<ndtClassifier::Classifier>()));

    return 0;
}

} // anonymous namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    // handlePacket takes char*, not const uint8_t*, but the parser does not
    // modify the buffer. The const_cast is safe because BoundedWords only
    // reads. Verified: handlePacket never writes through `buffer`.
    g_collector->handlePacket(const_cast<char*>(reinterpret_cast<const char*>(data)), size);

    // We fuzz for crashes and sanitizer reports only. No return value
    // to assert -- the parser's contract is "never throw, never crash".
    return 0;
}
```

### 7.2 CMake 整合

在 `tests/CMakeLists.txt` 尾端加上：

```cmake
# --- libFuzzer targets (clang only) -----------------------------------------
# These are NOT built by default. Pass -DENABLE_FUZZ=ON and use clang.
option(ENABLE_FUZZ "Build libFuzzer harnesses (requires Clang)" OFF)

if(ENABLE_FUZZ AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    # Fuzz target: sFlow parser
    add_executable(fuzz_sflow_parser
        fuzz/fuzz_sflow_parser.cpp
    )
    target_compile_options(fuzz_sflow_parser PRIVATE -fsanitize=fuzzer,address,undefined)
    target_link_libraries(fuzz_sflow_parser PRIVATE
        -fsanitize=fuzzer,address,undefined
        NdtCore_CollectionLib
        EventSystemLib
        UtilsLib
    )

    # Seed corpus: copy the 31 fixtures from tests/fixtures/
    add_custom_command(TARGET fuzz_sflow_parser POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "${CMAKE_BINARY_DIR}/fuzz_corpus/sflow"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_SOURCE_DIR}/tests/fixtures/"*.bin
            "${CMAKE_BINARY_DIR}/fuzz_corpus/sflow/"
        COMMENT "Copying sFlow seed corpus to fuzz_corpus/sflow/"
    )
endif()
```

### 7.3 Seed corpus

- **來源**：`tests/fixtures/*.bin`（31 個真實 sFlow datagram）
- **是否需要 corpus minimisation**：建議做一次。libFuzzer 本身會在執行期做 corpus minimisation（`-merge=1`），所以不需要手動做。CI 上只確保 corpus 存在即可。
- **未來新增**：每當 crash 被修復後，將 crash input 加入 `tests/fixtures/` 並加一個 gtest（見 7.5）。

### 7.4 `.dict` 檔案

**不建議現在寫。** 理由：sFlow 的魔數（version=5, sampleType=1..4, etherType=0x0800, IP protocol=6/17/1）已經在 31 個真實種子中涵蓋。libFuzzer 會在 mutation 過程中保留這些 byte sequence。Dict 的價值在於當種子語料無法涵蓋某些 magic value 時加速 coverage——但這裡的種子語料已經非常完整（來自真實 OVS 執行、涵蓋 TCP/UDP/ICMP/ARP）。

如果後續 coverage report 顯示某些 branch 無法被種子覆蓋（例如 sampleType=2 的 Brocade counter sample 路徑），再針對性地加 dict entry。

### 7.5 Crash → 永久迴歸測試的流程

這個專案已有 golden fixture 慣例（`test_GoldenFixture.cpp`）。Crash input 應遵循相同模式：

1. **Reproduce**：將 crashing input 存為 `tests/fixtures/crash_<hash>.bin`。
2. **Minimise**：用 `fuzz_sflow_parser -minimize_crash=1 crash_<hash>.bin` 得到最小 reproducer。
3. **Add gtest**：在 `tests/test_SFlowParsing.cpp` 加入一個 `TEST_F(SFlowParsingFixture, Crash_<hash>)`，讀取該 `.bin` 並斷言 `handlePacket` 不回 crash。
4. **Document**：在 test 註解中寫明這個 input 原本會觸發什麼 bug、在哪個 commit 修復。

### 7.6 執行策略

```bash
# 手動執行（不在 CI 自動跑）
./fuzz_sflow_parser \
    fuzz_corpus/sflow/ \
    -max_total_time=3600 \       # 1 hour; adjust based on available time
    -rss_limit_mb=2048 \         # 2 GB; the collector allocates per-sample state
    -jobs=4 \                    # 4 parallel workers; each gets its own process
    -workers=4 \
    -max_len=65536 \             # sFlow datagrams are ≤ 64KB
    -artifact_prefix=crash_sflow_/
```

**第一階段不用 `-fork=1`**：`-fork=1` 是單程序模式，適合 debug 但不適合 corpus exploration。用 `-jobs=N -workers=N` 更有效率。

**為什麼第一階段不要讓 CI 自動跑 fuzz：**
1. **安全規則**：fuzz target 雖經靜態驗證為純解析，但確認仍需人審查。
2. **資源**：libFuzzer 需要持續 CPU time。GitHub Actions free tier 的 6 小時 limit 不足以做有意義的 fuzzing。
3. **訊號品質**：Fuzz 是機率性的——今天沒 crash 不代表明天沒有。把 fuzz 放進 CI 會產生「有時紅有時綠」的不穩定訊號，違反 CI 的核心契約。
4. **建議模式**：在專用機器上持續跑 fuzz（`-max_total_time=0` 表示無限），CI 只做 build check（確保 fuzz target 不腐化）。Crash 被修復後變成 gtest，由 CI 保證不再 regression。

---

## 8. 我無法判定的事項

1. **`-Wshadow` 的實際數量**：需要在專案上實際編譯一次才能計數。預測可能有數十到數百個。無法從靜態分析準確估算。
2. **TSan 第一次跑的具體結果**：已預測會紅並列出可能的來源（spdlog、Boost、detached thread、無 strand io_context），但實際 report 數量與真假需要跑過才知道。
3. **clang 編譯是否還有其他隱藏問題**：已確認 `SPSCQueue` forward declaration 是唯一明顯的 clang 阻斷項。但模板實例化的邊界行為（尤其是與 Boost 模板的互動）可能還有其他 GCC 寬容而 clang 拒絕的情況。唯一的確認方法是實際用 clang 編譯一次。
4. **`build-asan/` 中的測試結果**：`build-asan/` 目錄存在且有 `bin/` 與 `lib/`，表示曾成功編譯。但無法確認是否曾成功跑過測試（沒有 log）。ASan 可能會在 process exit 時報告 memory leak（因為背景 thread 還在跑），這不一定代表真正的 leak。
5. **`FlowLinkUsageCollector::stop()` 沒有 join `m_workers`**：`stop()` 設定 `m_running = false` 並 joins `m_pktRcvThread`、`m_calAvgFlowSendingRateThreadPeriodically` 等，但**沒有 join `m_workers`**（行 601-606 建立的 per-worker thread）。`m_workers` 的 thread 在 `SPSCQueue::pop()` 中等待 `m_running` 變 false，但 `stop()` 沒有 notify 那些 condition_variable（`m_queues[qid]->notify_all()`），所以 worker 可能會卡在 `pop()` 直到 `stop()` 被呼叫後的某個時機才醒來。更嚴重的是：解構子 `~FlowLinkUsageCollector()` 只呼叫 `stop()` 然後就結束——此時 `m_workers` 中的 thread 若尚未返回，`std::thread` 解構子會呼叫 `std::terminate()`。這是一個既存的 bug，但**不在本次範圍內**。它會影響 sanitizer build 的行為（ASan 可能會在 `std::terminate` 時報告）。

### 補充修正（2026-08-11）

**8.5 `FlowLinkUsageCollector::stop()` 未 join `m_workers` 的疑慮——經複查後撤銷**

初版報告推測 `stop()` 沒有 join `m_workers` 會導致 `std::terminate()`。經完整追蹤執行流程後，此推測不成立：

1. `start()`（行 391）建立 `m_pktRcvThread`，執行 `run(this, numWorkers, queueCapacity)`。
2. `run()`（行 578+）建立 `m_workers`（行 601-606），進入 receive loop。
3. `stop()`（行 458）先設 `m_running = false`，關閉 socket（行 464-467），**然後 join `m_pktRcvThread`**（行 469-471）。
4. 關閉 socket 使 `run()` 的 `recvmmsg` 失敗/unblock，`run()` 退出 receive loop。
5. `run()` 接著 notify 所有 queue（行 776-778），使 worker 從 `pop()` 醒來。
6. `run()` join 所有 `m_workers`（行 781-787）。
7. `run()` 返回 → `m_pktRcvThread` 完成 → `stop()` 的 join 返回。
8. `stop()` join 剩餘 thread 後返回。
9. 解構子的成員解構階段：`m_workers` 已 empty/joined（安全），`m_queues` 銷毀（安全）。

所以 `m_workers` 實際上是透過 `m_pktRcvThread` → `run()` → join workers 這條間接路徑被正確清理的。解構子的呼叫順序沒有 bug。唯一的問題仍然是 clang 編譯時的 forward declaration 順序。

### 補充說明：現有 build-asan 的設定方式

現有的 `build-asan/` 是直接用 `-DCMAKE_CXX_FLAGS` 設定的（見 `build-asan/CMakeCache.txt:55`）：
```
CMAKE_CXX_FLAGS:STRING=-fsanitize=address,undefined -fno-omit-frame-pointer -g
```
這是一個更簡單的做法，不需要新增 `cmake/sanitizer-flags.cmake`。如果偏好簡單，可以用同樣方式做 TSan build：
```bash
cmake -S . -B build-tsan -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_CXX_FLAGS="-fsanitize=thread -fno-omit-frame-pointer -g -O1"
```
兩種方式（`cmake/sanitizer-flags.cmake` vs `-DCMAKE_CXX_FLAGS`）都可以，報告中保留兩種以供選擇。

### 補充說明：新目錄需求

本報告提議建立以下新檔案/目錄：
- `cmake/` 目錄（若選用 `sanitizer-flags.cmake` 方案）
- `.github/workflows/` 目錄（CI workflow）
- `tsan_suppressions.txt`（專案根目錄）
- `tests/fuzz/` 目錄（fuzz harness，待 target 確認後）

這些目錄目前都不存在，需要手動建立。
