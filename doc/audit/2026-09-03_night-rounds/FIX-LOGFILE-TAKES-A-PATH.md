# Fix: `--logfile` takes a path (FINDINGS #63)

[Co-developed with claude code -- Adam]

分支 `fix/logfile-takes-a-path`，基底 `feb9baef`（trunk 當時的 HEAD）。**沒有 push。**
純離線完成：沒有 `ndt up`、沒有 Mininet／bmv2／OVS、沒有綁 port。
所有建置與閘門都包在 `tools/build_guard/guarded_build.sh` 裡（`JOBS=2 MEM_MAX=5G`，
自己的 lock `/tmp/ndtwin-build-logfile.lock`，不跟主工作樹搶）。

---

## ① 一句話

`--logfile` 不消費下一個 argv——旗標是 boolean、檔名是 `Logger::init` 裡寫死的 `netdt.log`，
所以 `--logfile /我指定的/路徑.log` 看起來成功但那個檔 0 bytes、stderr 一句話都沒有；
現在它吃路徑並真的寫進去，**沒給路徑或下一個 token 是別的選項時直接拒絕（訊息＋rc 2）**，
而照著「同一族全查一遍」查出來的另外兩個同形缺陷（`--loglevel` 缺值靜默忽略、
打錯級別名會**把 log 整個關掉**）一併修掉。

---

## ② 行為變更前後對照

🔴 ＝ 改變對外行為（使用者／腳本看得到的差別）。

| # | 指令 | 修前 | 修後 | |
|---|---|---|---|:-:|
| 1 | `ndtwin_kernel --logfile /p/x.log` | 旗標吃掉、路徑當雜散位置參數丟掉；log 寫到 **cwd 的 `netdt.log`**；`/p/x.log` = 0 bytes；stderr 無話 | log 寫進 `/p/x.log`；**不再產生 `netdt.log`** | 🔴 |
| 2 | `ndtwin_kernel --logfile`（沒給路徑） | 靜默開 `netdt.log` | `--logfile requires a value, and none was given.` ＋選項說明，**rc 2** | 🔴 |
| 3 | `ndtwin_kernel --logfile --no-ai` | `--logfile` 開檔、`--no-ai` 被 `main.cpp` 的 parser 吃掉——**兩個 parser 對同一條命令列有兩種解讀** | `--logfile requires a value, but the next argument is '--no-ai', which is another option.` **rc 2** | 🔴 |
| 4 | `ndtwin_kernel --loglevel`（缺值） | 條件寫成 `(…) && i + 1 < argc`，不成立就掉出 else-if 鏈＝**靜默忽略**，級別留在預設，rc 0 | `--loglevel requires a value, and none was given.` **rc 2** | 🔴 |
| 5 | `ndtwin_kernel --loglevel inf`（打錯） | `spdlog::level::from_str` 是 `SPDLOG_NOEXCEPT`、不認得就回 `off`（`libs/spdlog/common-inl.h`，spdlog 1.15.2）⇒ 原本的 `try/catch` **不可達**，`--loglevel inf` **把 log 整個關掉**，rc 0，一句話都沒有 | `Unknown log level: inf` ＋合法名字列表，**rc 2** | 🔴 |
| 6 | `ndtwin_kernel --loglevel off` | 關掉 log | 關掉 log——**合法請求，不受第 5 列的檢查影響**。`off` 是唯一「正確答案剛好等於所有錯誤答案」的名字，所以檢查的是名字不是回傳值 | — |
| 7 | `ndtwin_kernel --help` | `Logging options are also accepted; see --logfile / --loglevel.`——**而沒有地方可以看**：Logger 自己的 help 分支在這個 binary 裡不可達（`main.cpp` 的 `cli::parse` 先跑，`showHelp` → 印 main 的 usage → `return 0`，`Logger::parse_cli_args` 從沒被呼叫） | 直接印出 `--logfile, -f <path>` 與 `--loglevel, -l <level>` | 🔴 |
| 8 | 沒帶 `--logfile` | console only | **完全不變** | — |
| 9 | 給了路徑但開不起來（目錄不存在／唯讀） | 幾乎碰不到：`netdt.log` 開在 cwd，通常成功 | `cannot open the log file '<path>': <原因>`，**rc 2**——被要求寫檔卻寫不了就不准繼續，否則後面每一句「我有 log」都是關於一個不存在的檔 | 🔴（新路徑） |

### repo 內部 API

- `LogConfig::enableFile`（`bool`）→ **`LogConfig::filePath`（`std::string`，空＝只有 console）**。
  兩個欄位可以互相矛盾（「檔案 log 開著」卻不帶檔名），一個欄位不行——而那個矛盾正是這個缺陷的材料。
  `enableFile` 在整個 tracked tree 只有 `Logger.cpp`／`Logger.hpp` 用到（已查），沒有其他 caller。
- 新增 `static const char* Logger::cli_usage()`：選項說明**只有一份字串**，`Logger` 的 help 分支與
  `main.cpp` 的 usage 共用。文件與行為不會再各自漂移。

### 完整旗標對帳表

這是第 1 步要求的「不要只修觀察到的那處，同一族全查一遍」的結果。

**`Logger::parse_cli_args`（`src/utils/Logger.cpp`）**

| 旗標 | 文件說吃什麼 | 程式（修前）實際吃什麼 | 一致？ | 修後 |
|---|---|---|:-:|---|
| `--logfile` / `-f` | ① `main.cpp:79`（**使用者唯一看得到的那份**）：「Logging options are also accepted; see --logfile / --loglevel」，而它所在的表格裡 `--mode <…>`、`--topology <path>` 都帶值 ② Logger 自己的 help：「also write logs to netdt.log」（＝不帶值）——**但印不出來** | boolean。`cfg.enableFile = true`，**下一個 argv 完全不消費**；檔名寫死在 `Logger::init` | ❌ | 吃 `<path>`；缺值／值長得像選項 → rc 2 |
| `--loglevel` / `-l` | Logger help：帶一個級別名 | 帶值，**但守衛寫在條件裡**：`(arg == "--loglevel" \|\| arg == "-l") && i + 1 < argc`。缺值 ⇒ 條件不成立 ⇒ 掉出鏈尾 ⇒ **靜默忽略** | ⚠️ | 缺值／值長得像選項 → rc 2 |
| `--loglevel` 的**值** | help 列 7 個名字；碼裡的 catch 說不合法會印 `Unknown log level` 並 `exit(1)` | **catch 不可達**（`from_str` 是 NOEXCEPT，不認得一律回 `off`）⇒ 打錯＝**靜默關閉 log**，rc 0 | ❌ | 檢查名字本身；打錯 → rc 2 |
| `--help` / `-h` | main 的 usage 有列 | 分支存在但**在 `ndtwin_kernel` 中不可達**；而 main 的 usage 正好指向這段印不出來的字 | ❌ | 分支保留（給其他 caller），文字改對且與 main 共用同一份字串 |
| 不認得的參數 | 沒寫 | **靜默忽略**（沒有 else 分支） | ❌ | **未處理，見 §6.1** |

**`cli::parse`（`src/main.cpp`，走同一份 argv 的姊妹 parser；本次只改 usage 字串）**

| 旗標 | 文件 | 實際 | 一致？ |
|---|---|---|:-:|
| `--mode <mininet\|testbed>` | 帶值 | `needsValue`：`i+1>=argc` → stderr ＋ `exit(2)`；值不在白名單 → stderr ＋ `exit(2)` | ✅ |
| `--topology <path>` | 帶 path | `needsValue`：缺值 → `exit(2)`。**沒有檢查值本身是不是另一個旗標** | ✅（⚠️ 見 §6.2） |
| `--ai` / `--no-ai` | boolean | boolean | ✅ |
| `-h` / `--help` | 顯示說明 | 顯示說明並 `return 0` | ✅ |
| 不認得的參數 | 沒寫 | 靜默忽略 | ❌ 見 §6.1 |

> **「消費了值卻沒有 `i + 1 < argc` 保護」的實例：零。**
> 兩個 parser 的每一個帶值旗標都有邊界檢查。問題不在越界，而在**越界之後做什麼**——
> `--mode`／`--topology` 報錯離開，`--loglevel` 靜默忽略，`--logfile` 根本沒去看。

---

## ③ 閘門證據

下面每一段都是**我在這個 worktree 裡自己跑出來的輸出**，不是轉述、不是讀碼推論。

### 3.1 單元測試：`tests/test_LoggerCliArgs.cpp`（19 cases）

```
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-logfile/build/_deps/googletest-src/googletest/src/gtest_main.cc
Note: Google Test filter = LoggerCliArgs*:LoggerFileSink*:LoggerUsageText*
[==========] Running 19 tests from 5 test suites.
[----------] Global test environment set-up.
[----------] 5 tests from LoggerCliArgsDeathTest
[ RUN      ] LoggerCliArgsDeathTest.AMistypedLevelIsRefusedRatherThanSilentlyDisablingLogging
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-logfile/build/_deps/googletest-src/googletest/src/gtest_main.cc
[       OK ] LoggerCliArgsDeathTest.AMistypedLevelIsRefusedRatherThanSilentlyDisablingLogging (8 ms)
[ RUN      ] LoggerCliArgsDeathTest.LogfileWithNoPathIsRefusedRatherThanDefaulted
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-logfile/build/_deps/googletest-src/googletest/src/gtest_main.cc
[       OK ] LoggerCliArgsDeathTest.LogfileWithNoPathIsRefusedRatherThanDefaulted (9 ms)
[ RUN      ] LoggerCliArgsDeathTest.LogfileFollowedByAnotherOptionIsRefused
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-logfile/build/_deps/googletest-src/googletest/src/gtest_main.cc
[       OK ] LoggerCliArgsDeathTest.LogfileFollowedByAnotherOptionIsRefused (8 ms)
[ RUN      ] LoggerCliArgsDeathTest.LoglevelWithNoValueIsRefusedRatherThanIgnored
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-logfile/build/_deps/googletest-src/googletest/src/gtest_main.cc
[       OK ] LoggerCliArgsDeathTest.LoglevelWithNoValueIsRefusedRatherThanIgnored (8 ms)
[ RUN      ] LoggerCliArgsDeathTest.LoglevelFollowedByAnotherOptionIsRefused
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-logfile/build/_deps/googletest-src/googletest/src/gtest_main.cc
[       OK ] LoggerCliArgsDeathTest.LoglevelFollowedByAnotherOptionIsRefused (8 ms)
[----------] 5 tests from LoggerCliArgsDeathTest (43 ms total)

[----------] 1 test from LoggerFileSinkDeathTest
[ RUN      ] LoggerFileSinkDeathTest.ALogFileThatCannotBeOpenedEndsTheRun
Running main() from /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-logfile/build/_deps/googletest-src/googletest/src/gtest_main.cc
[       OK ] LoggerFileSinkDeathTest.ALogFileThatCannotBeOpenedEndsTheRun (59 ms)
[----------] 1 test from LoggerFileSinkDeathTest (59 ms total)

[----------] 8 tests from LoggerCliArgsTest
[ RUN      ] LoggerCliArgsTest.LogfileConsumesThePathThatFollowsIt
[       OK ] LoggerCliArgsTest.LogfileConsumesThePathThatFollowsIt (0 ms)
[ RUN      ] LoggerCliArgsTest.TheShortFormConsumesAPathToo
[       OK ] LoggerCliArgsTest.TheShortFormConsumesAPathToo (0 ms)
[ RUN      ] LoggerCliArgsTest.TheOptionAfterTheLogfilePathIsStillParsed
[       OK ] LoggerCliArgsTest.TheOptionAfterTheLogfilePathIsStillParsed (0 ms)
[ RUN      ] LoggerCliArgsTest.LoglevelStillTakesItsValue
[       OK ] LoggerCliArgsTest.LoglevelStillTakesItsValue (0 ms)
[ RUN      ] LoggerCliArgsTest.WithoutTheFlagNoFileIsRequestedAtAll
[       OK ] LoggerCliArgsTest.WithoutTheFlagNoFileIsRequestedAtAll (0 ms)
[ RUN      ] LoggerCliArgsTest.ATopologyPathIsNotMistakenForALogPath
[       OK ] LoggerCliArgsTest.ATopologyPathIsNotMistakenForALogPath (0 ms)
[ RUN      ] LoggerCliArgsTest.EveryLevelNameTheHelpAdvertisesIsAccepted
[       OK ] LoggerCliArgsTest.EveryLevelNameTheHelpAdvertisesIsAccepted (0 ms)
[ RUN      ] LoggerCliArgsTest.AskingForOffIsARequestAndNotATypo
[       OK ] LoggerCliArgsTest.AskingForOffIsARequestAndNotATypo (0 ms)
[----------] 8 tests from LoggerCliArgsTest (0 ms total)

[----------] 2 tests from LoggerFileSinkTest
[ RUN      ] LoggerFileSinkTest.InitWritesToThePathTheConfigNamesAndToNoOther
[2026-09-03 14:06:32.432] [info] [test_LoggerCliArgs.cpp:367 TestBody] MARKER-ndtwin-logfile-takes-a-path
[       OK ] LoggerFileSinkTest.InitWritesToThePathTheConfigNamesAndToNoOther (0 ms)
[ RUN      ] LoggerFileSinkTest.AnEmptyPathOpensNoFile
[2026-09-03 14:06:32.433] [info] [test_LoggerCliArgs.cpp:387 TestBody] MARKER-no-file-was-requested
[       OK ] LoggerFileSinkTest.AnEmptyPathOpensNoFile (0 ms)
[----------] 2 tests from LoggerFileSinkTest (0 ms total)

[----------] 3 tests from LoggerUsageTextTest
[ RUN      ] LoggerUsageTextTest.TheUsageShowsLogfileTakingAPath
[       OK ] LoggerUsageTextTest.TheUsageShowsLogfileTakingAPath (0 ms)
[ RUN      ] LoggerUsageTextTest.TheUsageNoLongerPromisesAHardCodedFilename
[       OK ] LoggerUsageTextTest.TheUsageNoLongerPromisesAHardCodedFilename (0 ms)
[ RUN      ] LoggerUsageTextTest.TheUsageShowsLoglevelTakingAValue
[       OK ] LoggerUsageTextTest.TheUsageShowsLoglevelTakingAValue (0 ms)
[----------] 3 tests from LoggerUsageTextTest (0 ms total)

[----------] Global test environment tear-down
[==========] 19 tests from 5 test suites ran. (103 ms total)
[  PASSED  ] 19 tests.
```

### 3.2 變異閘：`tests/shell/mutate_logfile_takes_a_path.sh`

`9 mutations, 0 survived` ＋ `3 widenings, 0 wrongly caught`。
每一條變異都指名**哪一盞燈必須紅**（「有東西紅了」不是檢查，「哪一個紅了」才是）；
三條 widening 是**必須不被抓到**的行為保持改動——沒有它們，上面九個 ✅ 只證明「檔案被改過」。

```
guarded_build: jobs=2 mem_max=5G lock=/tmp/ndtwin-build-logfile.lock
guarded_build: $ ./tests/shell/mutate_logfile_takes_a_path.sh
=== anchor uniqueness (exact substring count must be 1) ===
  ok     logfile-consumes     src/utils/Logger.cpp         x1
  ok     sink-uses-path       src/utils/Logger.cpp         x1
  ok     index-advance        src/utils/Logger.cpp         x1
  ok     missing-refused      src/utils/Logger.cpp         x1
  ok     flag-shaped-guard    src/utils/Logger.cpp         x1
  ok     sink-guard           src/utils/Logger.cpp         x1
  ok     usage-first-line     src/utils/Logger.cpp         x1
  ok     level-typo-guard     src/utils/Logger.cpp         x1
  ok     flag-spelling        src/utils/Logger.cpp         x1
  ok     usage-comment        src/utils/Logger.cpp         x1
  ok     main-prints-usage    src/main.cpp                 x1
  ok     main-unrelated       src/main.cpp                 x1
  ok     config-field         include/utils/Logger.hpp     x1

=== baseline (unmutated working tree) must build, be green, and print a correct --help ===
  ok       baseline green (19 cases in LoggerCliArgs*:LoggerFileSink*:LoggerUsageText*)
  ok       ndtwin_kernel --help names --logfile <path> and --loglevel <level>
  ok       test_routing_strategy sha256 921e7e4fb44e3d3d

=== M1. the flag is a boolean again: the path is not consumed, netdt.log is hard-coded ===
  expect red: LoggerCliArgsTest.LogfileConsumesThePathThatFollowsIt LoggerCliArgsTest.TheShortFormConsumesAPathToo
  ✅ caught  red: LoggerCliArgsTest.LogfileConsumesThePathThatFollowsIt LoggerCliArgsTest.TheShortFormConsumesAPathToo

=== M2. the sink ignores the config and reopens the hard-coded netdt.log ===
  expect red: LoggerFileSinkTest.InitWritesToThePathTheConfigNamesAndToNoOther
  ✅ caught  red: LoggerFileSinkTest.InitWritesToThePathTheConfigNamesAndToNoOther

=== M3. consuming the path eats the next option too ===
  expect red: LoggerCliArgsTest.TheOptionAfterTheLogfilePathIsStillParsed
  ✅ caught  red: LoggerCliArgsTest.TheOptionAfterTheLogfilePathIsStillParsed

=== M4. a missing value is silently accepted instead of refused ===
  expect red: LoggerCliArgsDeathTest.LogfileWithNoPathIsRefusedRatherThanDefaulted LoggerCliArgsDeathTest.LoglevelWithNoValueIsRefusedRatherThanIgnored
  ✅ caught  red: LoggerCliArgsDeathTest.LogfileWithNoPathIsRefusedRatherThanDefaulted LoggerCliArgsDeathTest.LoglevelWithNoValueIsRefusedRatherThanIgnored

=== M5. a following option is taken as the value ===
  expect red: LoggerCliArgsDeathTest.LogfileFollowedByAnotherOptionIsRefused LoggerCliArgsDeathTest.LoglevelFollowedByAnotherOptionIsRefused
  ✅ caught  red: LoggerCliArgsDeathTest.LogfileFollowedByAnotherOptionIsRefused LoggerCliArgsDeathTest.LoglevelFollowedByAnotherOptionIsRefused

=== M6. the usage text goes back to promising a hard-coded netdt.log ===
  expect red: LoggerUsageTextTest.TheUsageShowsLogfileTakingAPath LoggerUsageTextTest.TheUsageNoLongerPromisesAHardCodedFilename
  ✅ caught  red: LoggerUsageTextTest.TheUsageShowsLogfileTakingAPath LoggerUsageTextTest.TheUsageNoLongerPromisesAHardCodedFilename

=== M7. a default log file is opened when none was requested ===
  expect red: LoggerFileSinkTest.AnEmptyPathOpensNoFile
  ✅ caught  red: LoggerFileSinkTest.AnEmptyPathOpensNoFile

=== M8. a mistyped log level silently disables logging instead of being refused ===
  expect red: LoggerCliArgsDeathTest.AMistypedLevelIsRefusedRatherThanSilentlyDisablingLogging
  ✅ caught  red: LoggerCliArgsDeathTest.AMistypedLevelIsRefusedRatherThanSilentlyDisablingLogging

=== M9. the kernel's --help stops printing the logging options ===
  expect red: HELP
  ✅ caught  the reachable --help is wrong: --help does not show --logfile taking a path

=== W1. a comment, nothing else (MUST stay green) ===
  ✅ survived -- behaviour unchanged, so the catches above are about behaviour

=== W2. --log-file accepted as a third spelling (MUST stay green) ===
  ✅ survived -- behaviour unchanged, so the catches above are about behaviour

=== W3. an unrelated line of main.cpp's usage is reworded (MUST stay green) ===
  ✅ survived -- behaviour unchanged, so the catches above are about behaviour

=== restore ===
  all 3 files byte-identical to the pre-run snapshot
  rebuilt from the restored tree
  suite green again after restore
  no mutant log file left in the working tree
  test binary: 921e7e4fb44e3d3d (was 921e7e4fb44e3d3d)

=== verdict ===
  9 mutations, 0 survived
  3 widenings, 0 wrongly caught
  FINDINGS #63 gate: every mutation was caught by the test it names, and every
  behaviour-preserving change was left alone.
guarded_build: exit 0
```

### 3.3 live：真正的 binary（純離線）

`ndtwin_kernel` 在沒有 `--mode` 且 stdin 不是 TTY 時，會在 `Logger::init` 之後、
**任何子系統建立之前**以 rc 2 結束（`main.cpp` 的 `requireFlag`）——
所以下面每一輪都只跑到 logger 就停，沒有任何 socket、沒有 Mininet／bmv2／OVS。

```
$ sha256sum build/bin/ndtwin_kernel
beebed6f4ecc8bb77d73974e265fb3a731c74a470c0c5573cc97bb16c9a95419  build/bin/ndtwin_kernel

### A. --logfile <path>: the path is honoured, end to end
$ ndtwin_kernel --logfile $EV/i-named-this.log  < /dev/null
rc=2
-- the file I named --
-rw-rw-r-- 1 adam adam 113 Sep  3 14:06 ./i-named-this.log
[2026-09-03 14:06:32.494] [info] [main.cpp:304 main] Logger Loads Successfully! level
-- netdt.log in the cwd? --
ls: cannot access 'netdt.log': No such file or directory
-- stderr (the rc 2 is the unrelated, pre-existing 'no --mode on a non-TTY') --
stdin is not a TTY, so --mode must be given explicitly.


### B. --logfile with no path: refused, non-zero
rc=2
--logfile requires a value, and none was given.

  --logfile, -f <path>       also write every log line to <path>. The path is
                             REQUIRED: a run asked to log to a file it cannot name
                             is refused, never silently sent to a default file.
  --loglevel, -l <level>     trace, debug, info, warn, err, critical, off

### C. --logfile followed by another option: refused, and says which
rc=2
--logfile requires a value, but the next argument is '--no-ai', which is another option.

### D. --loglevel inf (a typo): refused instead of silently turning logging off
rc=2
Unknown log level: inf
Valid levels: trace, debug, info, warn, err, critical, off

### E. --loglevel with no value: refused instead of silently ignored
rc=2
--loglevel requires a value, and none was given.

### F. --loglevel off: still a legal request, NOT a typo -- and it really takes effect
rc=2  (the same unrelated 'no --mode' exit; nothing was said about the level)
the startup log line is absent  <-- off was applied

### G. no --logfile at all: unchanged, console only, and no netdt.log anywhere
rc=2
the same startup log line at info is present  <-- console logging still works
-- files created by the whole run --
i-named-this.log
```

`ndtwin_kernel --help` 現在印的內容：

```
Usage: ./build/bin/ndtwin_kernel [options]

Deployment options (prompted interactively if omitted and stdin is a TTY):
  --mode <mininet|testbed>   deployment environment
  --topology <path>          topology JSON to load. Defaults to the mode's
                             configured file; for mininet, pick a P4 topology
                             here to run against bmv2
  --ai / --no-ai             enable or disable the Intent Translator
                             (--ai needs an OpenAI token)
  -h, --help                 show this message

Logging options:
  --logfile, -f <path>       also write every log line to <path>. The path is
                             REQUIRED: a run asked to log to a file it cannot name
                             is refused, never silently sent to a default file.
  --loglevel, -l <level>     trace, debug, info, warn, err, critical, off

Examples:
  ./build/bin/ndtwin_kernel --mode mininet --no-ai
  ./build/bin/ndtwin_kernel --mode mininet --no-ai \
      --topology ../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json
```

---

## ④ 合併順序與衝突

| 對象 | 檔案重疊 | 判斷 |
|---|---|---|
| `fix/topology-load-fails-before-listen` | `src/main.cpp` | **不會衝突（已核對）**。它相對於共同祖先 `128bfc6b` 只在 `main()` 內第 325 行附近新增 23 行；我只改 `cli::printUsage`（第 64–85 行）裡的一句。兩個 hunk 相距 240 行 |
| `fix/b5-kernel-shutdown`、`fix/d15-dataplane-kind-race`、`fix/telemetry-health-visible` | `tests/CMakeLists.txt` | 三個都在同一份 source 清單裡加行、加在清單尾端；我加在 `test_LoggerEnvironment.cpp` 之後。位置不同，一般不衝突；真衝突時**兩邊的行都留下**即可，順序無意義 |
| `worktree-agent-a0170b1609e75e0a1` 等 5 個 `worktree-agent-*` | `src/utils/Logger.cpp` | 全部是同一個過時改動：`set_pattern` 的 `%e` → `%F`（基底 `28b8b133`）。那一行在 `Logger::init` 尾端，離我改的 sink 區塊 16 行以上，三路合併乾淨。看起來是自動建立的 worktree 分支，未必會併 |

**順序**：本分支與上面任何一個都沒有相依，先併後併都可以。

🔴 **併入任何改動 `src/utils/Logger.cpp` 的分支之後，先跑
`tests/shell/check_gate_anchors.py` 再相信這個閘。** 這個閘有 13 個 anchor，
其中 8 個在 `Logger.cpp` 裡；anchor 漂掉的時候測試仍然是綠的，只有那支工具會說話。

---

## ⑤ 回退方式

1. **整支退掉**：`git revert <sha>`。沒有資料遷移、沒有持久狀態。唯一要注意的是
   `LogConfig::filePath` 會變回 `enableFile`——本次之前沒有任何 caller 用到 `filePath`，
   所以 revert 乾淨。
2. **只退「拒絕」那半、保留吃路徑**：把 `require_value` 的兩個 `std::exit(2)` 改成
   `return std::string();`。**不建議**——那正是 M4 在測的東西，會讓「打錯」與「沒打」重新
   變成同一件事，而且閘門會立刻紅。
3. **只退 `--loglevel` 的值檢查**：拿掉 `parse_level` 的 `if (level == … && name != "off")`。
   同樣會被 M8 抓到。

`tests/CMakeLists.txt` 裡新增的那一行必須跟 `tests/test_LoggerCliArgs.cpp` 一起退，
否則 configure 會找不到檔案。

---

## ⑥ 未處理

1. 🔴 **不認得的旗標，兩個 parser 都靜默忽略。** 修完之後 `--logfle /tmp/x.log`（少一個 `i`）
   **仍然**是「接受了、什麼都沒做、沒有訊息」——跟 #63 一模一樣的形狀，只是換成打錯**旗標名**
   而不是打錯值。沒修的理由：`cli::parse` 刻意忽略 Logger 的旗標、`Logger::parse_cli_args`
   刻意忽略 main 的旗標，要做統一的 unknown-flag 檢查得讓兩邊都知道對方的旗標集合，
   那是另一個改動＋另一組測試。**這是本輪最大的遺留缺口。**
2. **`cli::parse` 的 `needsValue` 不擋「值長得像旗標」。** `--topology --logfile /x.log` 會把
   `--logfile` 當拓撲檔名。它不是「接受了卻沒效果」（開檔會失敗、會吵），所以不在本次的缺陷族裡；
   但同族的守衛目前只有 Logger 這邊有。三行可以補齊。
3. **Logger 自己的 `--help` 分支在 `ndtwin_kernel` 裡仍然不可達。** 文字已改對、而且與 main
   印的是同一份 `cli_usage()`（所以不會再各說各話），但那個分支本身沒有 caller 會走到，
   **也沒有測試覆蓋它的 `std::exit(0)` 路徑**。要嘛刪掉（改變 `parse_cli_args` 對其他 binary
   的契約），要嘛讓 main 委派給它。
4. **`Logger::init` 用 `std::exit` 而不是丟例外。** 與檔案裡既有的 `parse_level` 一致，也讓死亡
   測試能斷言 rc；但它是 library 函式，對日後想在同一行程裡重試的 caller 不友善。
5. **`parse_level` 的 rc 從 1 變成 2。** 舊的 `exit(1)` 是**不可達**的碼，嚴格說沒有既有行為被改；
   但如果有人照著讀碼寫了「rc 1 ＝ 級別打錯」的期待，那個期待現在不成立。
6. **沒有跑完整套 `test_routing_strategy`。** 我跑的是
   `LoggerCliArgs*:LoggerFileSink*:LoggerUsageText*` 這 19 個 case，加上閘門自己的 baseline。
   `include/utils/Logger.hpp` 被 83 個 TU 引用、`LogConfig` 的欄位換掉了——雖然全部重建過而且
   連結成功，**全套綠燈這件事我沒有驗過。**
7. **沒有跑 live 的完整堆疊。** `stack.sh` 從來沒傳過 `--logfile`（已查，`stack.sh:908` 只有
   `--mode/--topology/--no-ai`），理論上不受影響，但**「stack 起得來」我沒有驗。**
8. **使用者手冊沒改。** repo 內只有 `main.cpp` 與 Logger 的 help 描述過這個旗標，兩處都改了；
   使用者手冊在另一個 repo（`/docs/ndtwin-user-manual/…`），本輪沒碰。
9. **沒有 push。** 依指示。

---

## ⑦ 對帳舊紀錄

- **`round5-topology-repro/FINDINGS.md` 的 F1（CONFIRMED, LOW-MED）與 `SUMMARY.md` 第 1 列**
  講的正是本條。它們的兩個 raw 數字（`build/netdt.log` = 74 942 bytes、指定的檔 = 0 bytes）
  **沒有被推翻**——本分支是讓它不會再發生。F1 給的兩個繞法（「改抓 stdout」「`cd` 到你要
  `netdt.log` 的地方再帶裸旗標」）之後都不需要了，第二個甚至**不再可行**：裸旗標會被拒絕。
- **`FINDINGS-COVERAGE.md` 第 155 列（#63，⭕ UNASSIGNED）** 與 `MORNING-BRIEF.md` 點名
  「今天真的派得出去」的三件事之一。**我沒有改那兩份帳**（共用工作樹的檔案、而且 auditor 在管），
  狀態請由 auditor 更新。
- **`doc/KNOWN-ISSUES.md` A-5** 的機制段寫「`--logfile`／`netdt.log` stack.sh 從來沒傳過，
  是死路徑」——**仍然成立**，本分支沒有讓 `stack.sh` 開始用它。
- 🆕 **原本沒有人記過的一條**：`--loglevel` 的值檢查不可達（§2 第 5 列）。
  它不在 FINDINGS 的任何一列裡，是照第 1 步「同族全查一遍」查出來的，而且**比 #63 更糟**：
  #63 是「log 跑到別的檔」，這一條是「log 根本不存在」，兩者都不出聲。

---

## ⑧ 寫這個閘門的時候，被閘門自己抓到的三件事

repo 的慣例是把這些寫下來——「由寫閘門發現、不是由讀碼發現」的缺陷才是閘門存在的理由。

1. **M7 的第一版是不能用的，而閘門說了。** 只把守衛拿掉（`if (!cfg.filePath.empty())` → `if (true)`）
   會讓 `init` 去開 `""`，那會丟例外、被 catch 成 `std::exit(2)`，**而且是在 global test
   environment 裡發生的**——binary 在第一個 `[ RUN ]` 之前就死了，沒有任何測試能被指名為紅，
   於是一條**確實套用了**的變異會被報成 survivor。改成「供給一個預設檔名」才既是真實的錯誤修法、
   又留得住可以回答問題的儀器。順便，`run_tests` 學會了這個形狀：
   **一個結束了整個行程的測試不會印 `[  FAILED  ]`**，把它讀成「沒有東西紅」是錯的。
2. **`restore()` 每輪 `touch` 全部三個檔，包括那個 header。** ninja 因此在每一條變異之後重編
   **83 個 TU**——一輪從 ~40 秒變成 5 分 46 秒，整個閘門會慢到沒人跑。改成「只還原、也只 touch
   真的被改過的那個檔」之後，一輪 10 秒。**`cp -p` 要 touch 是對的；touch 沒被改過的檔是錯的。**
3. **`EXPECT_EXIT` 是巨集，`Argv a{"x", "--logfile"}` 的逗號會直接交給前處理器**
   （`macro "EXPECT_EXIT" passed 6 arguments, but takes just 3`）。括號裡的逗號安全，
   大括號裡的不安全。死亡測試因此改成呼叫一個只吃一個字串參數的 helper。

另外一件不是閘門抓到、但花掉時間的事：**第一次跑測試時整個 binary 在 global test environment
裡丟 `std::bad_alloc`**，看起來像我的碼有 bug。真正的原因是我**在背景建置還在跑的時候改了
`include/utils/Logger.hpp`**——`LogConfig` 從 8 bytes 變成 40 bytes，同一個 binary 裡混進了
兩種佈局的 object，而 `ninja -n` 說「no work to do」。
`touch include/utils/Logger.hpp` 強制重建 83 個 TU 之後全綠。
**一個看起來像缺陷的失敗，來源是儀器。**
