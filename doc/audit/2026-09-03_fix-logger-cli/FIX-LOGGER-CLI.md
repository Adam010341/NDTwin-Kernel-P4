# FIX-LOGGER-CLI — FINDINGS #69 與 #70

分支 `fix/logger-cli-refuses-unknown`，從 trunk `431d98a5` 開出。
所有 build 與閘門一律走 `tools/build_guard/guarded_build.sh`（trunk 版本）。

[Co-developed with claude code -- Adam]

---

## 0. 先講結論：兩條 finding 在 `431d98a5` 上的狀態不一樣

開工第一件事是**對帳**，不是動手。#69 與 #70 的前半，在我拿到的 trunk 上**已經被
`fix/logfile-takes-a-path` 修掉了**（那支已併進 trunk）。剩下**沒修的是 #70 的後半**。

| finding | 這條在 `431d98a5` 上 | 我做了什麼 |
|---|---|---|
| #69 `--loglevel <打錯>` 靜默關掉 log | **已修**。`Logger::parse_level` 有名字檢查、`exit(2)`；`tests/test_LoggerCliArgs.cpp` 有死亡測試，`mutate_logfile_takes_a_path.sh` 的 M8 守著它 | 沒改 code。**補一條反方向的測試**（見 §4），把「help 文字宣傳了 parser 不接受的等級名」也蓋住 |
| #70 前半 `--help` 分支不可達、usage 指著印不出來的字 | **文字那半已修**：`main.cpp` 的 usage 直接印 `Logger::cli_usage()`，M9 守著它。**但 `Logger::parse_cli_args` 的 `--help` 分支在 kernel 裡仍然不可達**，而且它自己那行 `Usage:` 對 kernel 來說是錯的（少了 `--mode`／`--topology`／`--ai`） | 保留分支（standalone caller 要用），但**把它實際執行起來測**，見 §4 與 §7 的未決事項 |
| #70 後半 兩個 parser 都靜默忽略不認得的旗標 | **沒修** | 這次的主體，見 §2、§3 |

---

## 1. #70 後半在未改動的樹上長什麼樣

binary：`build/bin/ndtwin_kernel`，sha256 前 32 碼 `1e9c306ddf9f1dc18c9b0bea232d87ef`，
由 `431d98a5` 未改動的原始碼經 guard 建出（`configure.log:43`、`build_pristine_kernel.log:5`
都是 `guarded_build: exit 0`）。

🔴 **第一次量的方法是錯的，而且錯得像成功。** 直接打：

```
$ build/bin/ndtwin_kernel --logfle /tmp/ndt-pristine-x.log ; echo $?
stdin is not a TTY, so --mode must be given explicitly.
...usage...
2
```

rc **2**——看起來像「它拒絕了」。它沒有。打錯的旗標被靜默吃掉了，非零狀態是
**另一件事**給的：stdin 是 pipe、`--mode` 沒給。**一個只讀 rc 的閘門，會在有 bug 的樹上通過**，
後面每一條 catch 都會變成沒有意義的。（`/tmp/ndt-pristine-x.log` 也確實沒被建出來，
`file-created=no`。）

換成帶 `--help` 的命令列就沒有這個混淆——`main.cpp` 自己答 `--help` 並在**任何子系統被建構前**
`return 0`，所以 rc 只跟旗標有關，而且不會啟動 kernel：

| 未改動的樹上，實測 | rc | 輸出裡有 `unknown option` |
|---|---|---|
| `--help` | 0 | 0 次 |
| `--help --logfle /tmp/x.log` | **0** | **0 次** |
| `--help -x` | **0** | **0 次** |
| `--help --loglevel=debug` | **0** | **0 次** |
| `--help --mode mininet --topology /tmp/t.json --no-ai --logfile … --loglevel debug` | 0 | 0 次 |

原始紀錄：`pristine_evidence.log`。這就是 finding 的形狀：**收下、什麼都沒做、一句話都沒有**。

---

## 2. 為什麼修法不是「兩個 parser 各自拒絕」

任務書寫的是「consistently in both parsers」。**照字面做會壞掉**，而這正是這條 bug 的重點：

- `cli::parse`（`src/main.cpp`）走完整個 argv，**必須容忍** `--logfile`，那是 Logger 的；
- `Logger::parse_cli_args` 走**同一個** argv，**必須容忍** `--mode`，那是 main 的。

所以「我不認得這個旗標」**不是任何一個 parser 有資格講的話**。它只對兩張表的**聯集**成立。
真的讓每個 parser 各自拒絕，結果是 `--mode mininet` 在其中一個變成錯誤、`--logfile x` 在另一個
變成錯誤——比原來的 bug 更糟。

⇒ 判斷做在**一個地方、一次、看得到兩張表**：`Logger::reject_unknown_flags(argc, argv, also_known)`。
`main()` 那邊由 `cli::parse` 開頭呼叫一次，把 `cli::deploymentFlags()` 交進去。

`arity`（0＝開關、1＝吃一個值）存在的理由是**跳過值、不要掃它**：
`--topology -weird-but-a-real-path.json` 不可以被讀成旗標 `-weird-but-a-real-path.json`。

---

## 3. 改了什麼

| 檔案 | 改動 |
|---|---|
| `include/utils/Logger.hpp` | 新增 `struct CliFlag { const char* name; int arity; }`；`Logger::logging_flags()`、`Logger::reject_unknown_flags()` 兩個宣告與它們的理由 |
| `src/utils/Logger.cpp` | `known_option_names()`（拒絕訊息裡那份清單，**從檢查自己讀的兩張表建**，所以不可能宣傳一個它待會要拒絕的旗標）、`Logger::logging_flags()`、`Logger::reject_unknown_flags()` |
| `src/main.cpp` | `cli::deploymentFlags()`；`cli::parse()` 開頭呼叫 `Logger::reject_unknown_flags` |
| `tests/test_LoggerCliArgs.cpp` | 延伸既有檔案（**沒有新開檔**，所以 `tests/CMakeLists.txt` 一行都不用動） |
| `tests/shell/mutate_logger_cli.sh` | 新閘門 |

**前 → 後**（`ndtwin_kernel`，都帶 `--help` 以排除 §1 那個混淆）：

| 命令列 | 前 | 後 |
|---|---|---|
| `--help --logfle /tmp/x.log` | rc 0，無訊息 | rc 2，`unknown option '--logfle'` ＋接受清單 |
| `--help -x` | rc 0，無訊息 | rc 2，`unknown option '-x'` |
| `--help --loglevel=debug` | rc 0，無訊息 | rc 2，`unknown option '--loglevel=debug'` |
| `--help --mode … --topology … --no-ai --logfile … --loglevel debug` | rc 0 | rc 0（**不變**，這是鬆的方向的對照） |

被接受的等級名（`--loglevel`，未改動、由 `fix/logfile-takes-a-path` 定）：
**`trace` `debug` `info` `warn` `err` `critical` `off`**——這是 `cli_usage()` 印的七個。
`spdlog::level::from_str` 另外還吃 `warning` 與 `error`（`libs/spdlog/common.h:270-271` 的
`SPDLOG_LEVEL_NAME_WARNING`／`_ERROR`），`parse_level` 不會擋它們；help 印的是**建議拼法的子集**，
不是全集。這點我沒改（見 §7）。

---

## 4. 測試

紅→綠的紀錄在 §5。新增的案例分兩半，而**第二半才是第一半的意義來源**：
`reject_unknown_flags` 回傳 void、失敗就 `std::exit`，所以「一律拒絕」這個假修法**會通過每一條
拒絕案例**。

**拒絕的那半**
- `AnUnknownOptionIsRefusedRatherThanSilentlyIgnored` — finding 原文
- `TheRefusalNamesTheOptionsThatWouldHaveBeenAccepted` — 訊息要講出什麼會被接受
- `AMistypedShortOptionIsRefusedToo`
- `TheEqualsFormIsRefusedBecauseNeitherParserHonoursIt` — `--loglevel=debug`，兩個 parser 都不吃
- `AFlagTheCallerDidNotDeclareIsUnknownEvenThoughTheKernelOwnsIt` — 聯集是聯集：同一個 `--mode`，
  在 kernel 裡合法、在只有 logging 旗標的 binary 裡不合法

**接受的那半（鬆的方向的對照）**
- `EveryFlagTheLoggingParserOwnsSurvivesTheCheck`／`EveryFlagTheCallerDeclaresSurvivesTheCheck`
- `ACommandLineUsingBothParsersFlagsIsAccepted` — 兩張表交錯的真實命令列
- `TheValueOfAValueTakingFlagIsNotScannedAsAnOption`
- `APositionalAndABareDashAreNotOptions`

**表與 parser 不准漂**
- `EveryValueTakingFlagInTheTableIsHonouredByTheParser` — 表裡每個吃值的旗標都真的被
  `parse_cli_args` 用掉。表少一個 → 程式懂的命令列被拒；表多一個 → 收下、沒作用，就是這條 bug 本身。

**#70 前半那個從沒執行過的分支**
- `TheHelpBranchOfTheLoggingParserRunsAndPrintsTheOptionBlock`／`TheShortHelpBranchRunsToo` —
  在 kernel 裡它不可達，但它是 logging-only binary 唯一的 `--help`（例如
  `doc/audit/2026-09-01_esa-power-off-injection/driver.cpp`）。**沒被執行過的分支就是說明與行為漂開的
  地方**，所以這裡把它跑起來。（死亡測試的 matcher 讀的是子行程的 **stderr**，那個分支印在 stdout，
  所以 helper 先把 `std::cout` 的 rdbuf 換成 `std::cerr` 的；分支沒跑就 `exit(3)`，
  跟分支自己的 0 分得開。）

**#69 的反方向**
- `EveryLevelNameTheUsageActuallyPrintsIsAcceptedByTheParser` — 既有的
  `EveryLevelNameTheHelpAdvertisesIsAccepted` 讀的是寫在測試檔裡的清單；這條**從 help 文字本身**
  把名字拆出來，所以「usage 多宣傳了一個 parser 不吃的等級」這個方向才有人看。

🔴 **`src/main.cpp` 沒有被連進測試 binary**（它有自己的 `main()`）。所以 main 那半——
`deploymentFlags()` 的內容、呼叫點在不在——**任何 gtest 都看不到**，只有閘門用真的
`ndtwin_kernel` 打得到。測試檔裡那份 deployment 表是**替身**，檔案裡就是這樣寫的，免得被當成
它給不了的覆蓋率。

---

## 5. 紅 → 綠

### 紅（未改動的樹 ＋ 新測試 ＋ `reject_unknown_flags` 是**空實作**）

新 API 沒辦法在「完全未改動」的樹上編譯——所以紅是這樣取的：**檢查存在、也接上了，但什麼都不決定**
（`RED-FIRST STUB`，原始碼裡有標）。行為上的紅另外由 §1 那支未改動的 binary 提供。

test binary `1b9535ef1b45bb3c38aff3d886ac53db`、kernel `ff4a990746e2a500f4599d6b9f97577b`：

```
[==========] 30 tests from 3 test suites ran. (94 ms total)
[  PASSED  ] 25 tests.
[  FAILED  ] 5 tests, listed below:
[  FAILED  ] LoggerCliArgsDeathTest.AnUnknownOptionIsRefusedRatherThanSilentlyIgnored
[  FAILED  ] LoggerCliArgsDeathTest.TheRefusalNamesTheOptionsThatWouldHaveBeenAccepted
[  FAILED  ] LoggerCliArgsDeathTest.AMistypedShortOptionIsRefusedToo
[  FAILED  ] LoggerCliArgsDeathTest.TheEqualsFormIsRefusedBecauseNeitherParserHonoursIt
[  FAILED  ] LoggerCliArgsDeathTest.AFlagTheCallerDidNotDeclareIsUnknownEvenThoughTheKernelOwnsIt
```

同一顆 stub binary 上的 kernel：

```
$ ndtwin_kernel --help --logfle /tmp/x.log   -> rc=0  'unknown option' x0
$ ndtwin_kernel --help -x                    -> rc=0  'unknown option' x0
$ ndtwin_kernel --help --loglevel=debug      -> rc=0  'unknown option' x0
```

🔴 **兩條新的 `--help` 分支案例（`TheHelpBranchOfTheLoggingParserRuns…`／`TheShortHelpBranchRunsToo`）
在紅的那一輪就是綠的，這裡要講明白。** 它們釘的是**既有**的分支（#70 前半那個「從沒被執行過」的
分支），不是這次新寫的行為 ⇒ 它們**不是**紅先行的案例。它們的紅由閘門 M8 提供，那裡是真的看過紅的。

### 綠

test binary `58491009a879a32239f7d32f69d9d97b`、kernel `fd0b45cfa2dd9ab3fd0a6152abf6e286`：

```
[==========] 33 tests from 5 test suites ran. (303 ms total)
[  PASSED  ] 33 tests.
```

kernel：

```
$ ndtwin_kernel --help --logfle /tmp/x.log                              -> rc=2
$ ndtwin_kernel --help -x                                               -> rc=2
$ ndtwin_kernel --help --loglevel=debug                                 -> rc=2
$ ndtwin_kernel --help --mode mininet --topology … --no-ai --logfile … --loglevel debug -> rc=0

$ ndtwin_kernel --help --logfle /tmp/x.log
unknown option '--logfle'
Accepted options: --ai, --help, --logfile, --loglevel, --mode, --no-ai, --topology, -f, -h, -l
Run with --help for the full usage.
```

### 整顆 binary（最後一版原始碼，兩支閘門跑完並還原之後）

```
[==========] 938 tests from 121 test suites ran.
[  PASSED  ] 938 tests.

100% tests passed, 0 tests failed out of 938        (ctest)
```

---

## 6. 突變閘門 `tests/shell/mutate_logger_cli.sh`

`tools/build_guard/guarded_build.sh ./tests/shell/mutate_logger_cli.sh` →
**9 mutations, 0 survived；3 widenings, 0 wrongly caught**，`guarded_build: exit 0`。

| # | 突變 | 由誰抓到 |
|---|---|---|
| M1 | union 檢查什麼都不決定（**就是出貨時的樣子**） | `AnUnknownOptionIsRefused…`、`AMistypedShortOptionIsRefusedToo`、KERNEL `unknown-long-flag-refused` |
| M2 | 檢查寫好了、測好了，**main 從來沒呼叫** | KERNEL `unknown-long-flag-refused`＋`unknown-short-flag-refused` |
| M3 | main 的表掉了 `--topology` | KERNEL `all-known-flags-accepted` |
| M4 | Logger 的表掉了 `--logfile` | `ACommandLineUsingBothParsersFlagsIsAccepted` |
| M5 | 旗標的**值**被當成旗標掃 | `TheValueOfAValueTakingFlagIsNotScannedAsAnOption` |
| M6 | 拒絕訊息不再講可接受清單 | `TheRefusalNamesTheOptionsThatWouldHaveBeenAccepted`＋KERNEL `refusal-names-both-tables` |
| M7 | **講了、然後照樣放行**（最像樣的假修法） | `AnUnknownOptionIsRefused…`＋KERNEL `unknown-long-flag-refused` |
| M8 | logging parser 的 `--help` 印完不 exit | `TheHelpBranchOfTheLoggingParserRuns…`＋`TheShortHelpBranchRunsToo` |
| M9 | usage 宣傳一個 parser 不吃的等級名 | `EveryLevelNameTheUsageActuallyPrintsIsAcceptedByTheParser` |
| **W1** | 只改一行註解 | **必須存活** ✅ |
| **W2** | `--log-file` 第三種拼法，**表與 parser 都加** | **必須存活** ✅ |
| **W3** | 裸 `--` 不再算未知旗標 | **必須存活** ✅ |

### 🔴 第一輪閘門抓到兩件事，而兩件都是**我這邊**的錯

1. **M1 HUNG（>300s），不是 catch。** 檢查被停掉之後 `arity` 是 −1，而前進寫的是裸的
   `i += arity`——它抵消掉 `++i`，行程原地轉。**改的是 `src/utils/Logger.cpp` 不是突變**：
   現在是 `i += std::max(arity, 0)`。一個「只因為三行前那個分支才會非負」的迴圈索引，離永不終止只有
   一次編輯；而 hang **既不是紅也不是能推理的存活**，是閘門唯一沒辦法給分的結果。
2. **W2 被誤抓。** `EveryValueTakingFlagInTheTableIsHonouredByTheParser` 本來帶一張
   name→value 對照表，遇到不認得的表項就 `ADD_FAILURE`。那看起來像嚴謹，實際是**把案例釘在表的內容上**
   ⇒ 加一個合法的第三拼法就變紅。改成**單一探針值 `"debug"`**（它同時是合法等級名與可用路徑），
   案例就只認行為不認內容。
   順帶：**原本的 W2 本身也是錯的**——它只加到表、沒加到 parser，那不是等價改寫，那正是
   「檢查收下、parser 不理」的缺陷本身。現在 W2 兩邊都加。

### 相鄰閘門沒有被我弄壞

`tools/build_guard/guarded_build.sh ./tests/shell/mutate_logfile_takes_a_path.sh` →
**9 mutations, 0 survived；3 widenings, 0 wrongly caught**，`guarded_build: exit 0`。

---

## 7. 沒做的事

1. **`Logger::parse_cli_args` 的 `--help` 分支在 kernel 裡仍然不可達。** 我沒有刪它，也沒有讓
   `main` 掉進去。理由：它是 logging-only binary 唯一的 `--help`，刪掉是功能倒退；而讓 kernel
   掉進去會印出一行對 kernel 而言是錯的 `Usage:`（少了 `--mode`／`--topology`／`--ai`）。
   現況是：kernel 的 `--help` 由 `main.cpp` 答、文字含 `Logger::cli_usage()`（M9 守）；Logger 的
   分支由 §4 兩條死亡測試執行（M8 守）。**要不要留這個分支，是留給 auditor 的裁決。**
2. **等級名沒有統一成一份清單。** `cli_usage()` 印七個，`parse_level` 實際吃九個
   （多 `warning`、`error`）。把兩者接到同一個 `accepted_level_names()` 會改到
   `mutate_logfile_takes_a_path.sh` 的 `usage-first-line` 錨點所在那一行 ⇒ **那支閘門會判錨點漂移、
   直接 exit 2**。任務書要我保持它綠，所以我停手。這是**已知的不一致，不是已修**。
3. **多餘的 positional 不擋。** `ndtwin_kernel somefile` 仍然被容忍（測試有把這條容忍釘住）。
   這條 finding 講的是旗標；擋 positional 是另一個決定。
4. **`--mode=mininet` 這種等號形式現在是錯誤，不是被支援。** 我沒有讓 parser 開始吃等號形式，
   只是不再默默丟掉它。
5. **沒動 public build path。** #69 在 `origin/main` 上的狀態我**沒有查證**（那要打未認證 HTTPS
   去看公開 repo，不在這次的授權範圍內）。trunk 修好 ≠ 使用者拿得到。

---

## 8. Guard 紀錄

每一次 cmake／ninja 都走 trunk 版的 `tools/build_guard/guarded_build.sh`
（`jobs=2 mem_high=3G mem_max=4G lock=/tmp/ndtwin-build.lock`）。**唯一的真話是
`guarded_build: exit N` 那一行**，wrapper 的 rc 一律不採信（log 裡有寫）。

| 日誌 | 行 | 內容 |
|---|---|---|
| `configure.log` | 43 | `guarded_build: exit 0` |
| `build_pristine_tests.log` | 104 | `guarded_build: exit 0` |
| `build_pristine_kernel.log` | 5 | `guarded_build: exit 0` |
| `build_red.log` | 92 | `guarded_build: exit 0` |
| `build_green.log` | 8 | `guarded_build: exit 0` |
| `gate_logger_cli.log` | 82 | `guarded_build: exit 0` |
| `gate_logfile_regression.log` | 81 | `guarded_build: exit 0` |

日誌留在本 session 的 scratchpad `logs/`（不進版控）。

**開跑前一律先看 `free -m`，低於 7000 MB 就等。** 這台機器上當時另一個 agent 的
`mutate_cloexec_listening_sockets.sh` 正在跑，記憶體被壓在 3.6–6.5 GB ⇒ 綠的那次 build
等了 **51 次檢查（約 25 分鐘）** 才開工（`build_green.log:1`）。等待是照做的，不是繞過的。
