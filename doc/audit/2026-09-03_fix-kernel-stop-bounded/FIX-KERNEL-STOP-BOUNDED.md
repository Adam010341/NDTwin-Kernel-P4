# FIX-KERNEL-STOP-BOUNDED — FINDINGS #27 與 #76：「說了要停，還沒停」

分支 `fix/kernel-stop-is-bounded`（從 `trunk b57736cd` 長出）。

[Co-developed with claude code -- Adam]

---

## 0. 一句話

兩個 finding 是**同一個機制**：worker 迴圈只在「輪與輪之間」讀停止旗標，而一輪裡面是
一顆一顆 switch 的 `curl`——所以停止請求的答覆時間不是由我們決定的，是由**對面那台不回話的機器**
決定的。修法是讓停止請求可以在**一輪之內**被看見，而且**正在飛的那個 HTTP 呼叫會被殺掉**，
不是被等完。

---

## 1. 缺陷

### 1.1 #27 — openflow worker（量到 81.09 秒的那個）

`DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker` 的迴圈條件是
`while (m_running.load())`。一輪＝`fetchOpenFlowTablesInternal()`，它走過每一台 `isUp` 的
switch，每台跑一次

```
curl -s --max-time 8 -X GET http://{proxy}/stats/flow/{dpid}
```

**這個走訪裡面沒有任何一行讀 `m_running`。** 所以停止請求落在第一台時，要等到最後一台才被答覆。

補好 B-5 的 join 之後實測（FINDINGS row 27）：SIGINT 關機 2.40／2.40／2.53／2.40／3.00／6.40 秒，
而忙碌那一次 **81.09 秒**，其中約 72 秒卡在那個 join 裡。當時 10 台 switch、控制平面不回話：
**剩下 9 台 × 8 秒 ＝ 72 秒**，對到秒。這不是估的，是乘出來剛好等於量到的。

### 1.2 #76 — poll thread（印了 `Exiting` 還活著的那個）

`TopologyAndFlowMonitor` 的 poll 迴圈同一個形狀，一輪三次
（`--connect-timeout 2 --max-time 5`，switches／hosts／links）。

`src/main.cpp` 的 sFlow bind 失敗路徑是：

```cpp
SPDLOG_LOGGER_CRITICAL(..., "cannot start telemetry collection: {}. Exiting -- ...");
topologyAndFlowMonitor->stop();      // ← 卡在 poll thread 正在飛的 curl 裡
return EXIT_FAILURE;
```

**先印 `Exiting`，再呼叫那個會卡住的 stop()。** proxy 卡住時，8 秒後行程還在。
重啟腳本若把「印了 Exiting」當成「已經退了」，就會踩到 #47 那個窗口——
只是這次是從另一頭踩進去的。

### 1.3 兩者為什麼放在一起

它們不是兩個長得像的 bug，是**同一個兩邊都沒有的性質**。把不變量掛在某一個類別的名字底下，
正是 A-2 能比 `tests/test_RequestDeadlines.cpp` 多活兩個星期的原因——那個檔案自己的 scope note
就是這樣寫的。性質是：**stop() 被請求之後，這個行程不應該還在做一件長度由對面決定的事。**

---

## 2. 機制：修法前後

### 2.1 新的原語 `utils::StopSignal`（`include/utils/StopSignal.hpp`，新檔）

有界的停止需要三件事，而且三件必須指向同一個瞬間，否則界不成界：

| # | 需要什麼 | 修法前 | 修法後 |
|---|---|---|---|
| 1 | **輪之內讀得到的旗標** | 只有輪與輪之間的 `while (m_running)` | `stopRequested()`，走訪每台 switch 之前讀 |
| 2 | **睡到一半會醒的睡眠** | 10 秒切成十次 1 秒小睡＋旗標檢查 | `waitFor()`，condition variable，`request()` 叫醒 |
| 3 | **會跟著死的子行程** | ❌ **沒有辦法**——`popen()` 不給 pid | `request()` 對每個登記中的子行程 process group 送 `SIGKILL` |

第 3 點是**唯一不能靠檢查旗標解決的那一半**，也是 #27 的 72 秒與 #76 的 8 秒真正待的地方：
旗標在阻塞中的 `popen()` read 裡面是讀不到的。

### 2.2 `utils::execCommandCancellable(cmd, stop)`

與 `execCommand` **同一個 shell 字串、同一個 `/bin/sh -c`、同一個 wire format**——
所以 `tests/test_RequestDeadlines.cpp` 釘的格式、
`tests/python/test_shell_command_construction.py` 的逐站點分類，兩個都還是原來的意思。

**這不是** FIX-CLOEXEC.md §7 列為「刻意不做」的那個 popen→execArgv 轉換。
差別只有一個：這個行程現在**握有子行程的 pid**，因此殺得掉它。

與 `popen()` 的三個刻意差異：

1. **自己的 process group**（fork 兩邊都 `setpgid`，無競態的寫法）。`request()` 送給整個 group，
   所以萬一 `/bin/sh` 是 fork 而不是 exec 它的 curl，curl 也一起走。
   代價：終端機的 Ctrl-C 不再經由 tty 送到這些子行程——**改由誰殺，不是改成沒人殺**：
   SIGINT 到 main，main 呼叫 stop()，stop() 明確殺它們。而且這個方向更安全，因為它不再依賴
   有沒有控制終端（`ndt up` 是用 setsid 跑的）。
2. **子行程裡 `close_range(3, ...)`**——`execArgv` 本來就做，`popen` 從來沒做。#47 已經修在
   socket，所以這是縱深防禦而不是修法；但把兩個最熱的 spawn 站點走過這裡，是**讓那個洞變小**。
3. **`SIGKILL` 不是 `SIGTERM`**：一個被放棄的 curl 沒有東西要收尾，而它若自己處理 SIGTERM，
   等於把一個無界的步驟放回一個存在目的就是移除無界步驟的函式裡。

### 2.3 逐處改動

| 檔案 | 改了什麼 |
|---|---|
| `include/utils/StopSignal.hpp` | **新檔**。`StopSignal`、`WorkerScope`、`ChildProcessRegistration`、`reportIfWorkersOutlastTheBound()`、`execCommandCancellable()` |
| `…/DeviceConfigurationAndPowerManager.hpp` | `m_stopSignal`、`m_stopReportBound`、`setStopReportBound()`、`FlowTableFetch::abandoned` |
| `…/DeviceConfigurationAndPowerManager.cpp` | `start()` reset；`stop()` request＋報告；走訪迴圈加停止檢查；flow-stats curl 改可取消；三個 worker 各加 `WorkerScope`＋`waitFor` |
| `…/TopologyAndFlowMonitor.hpp` | 同上兩個成員與 setter |
| `…/TopologyAndFlowMonitor.cpp` | `start()` reset；`stop()` request＋報告；三個 endpoint 之間加檢查；topology curl 改可取消；`runLoop` 與 `flushEdgeFlowLoop` 各加 scope＋`waitFor` |
| `src/main.cpp` | #76 的措辭：`Exiting` → `Shutting down`，並在 **stop() 之後**才印「exiting now」 |

`FlowTableFetch::abandoned` 值得單獨說：被中斷的那一輪**不可以被套用**。
`tables` 只裝了停止前問到的那幾台，而 `applyFetchedTables` 是**整份覆蓋**——
套用一個被放棄的輪次，會把走訪還沒走到的每一台 switch 從快取裡刪掉。
`carryForwardUnreadTables` 也救不了它們：它們不在 `unread` 裡，因為**它們根本沒被問**。

---

## 3. 界，以及它從哪裡來

**提出的界：stop 請求之後 3 秒內完成，不論控制平面是卡住、拒絕還是很慢。**

它從三個地方來，不是挑一個好看的數字：

1. **必須打敗的兩個 deadline**：每台 switch 8 秒（#27）、每個 topology endpoint 5 秒（#76）。
2. **修法後每個 worker 的停止延遲**＝「殺掉正在飛的子行程」＝一個 syscall，不是一個 deadline。
   睡眠不再貢獻（`waitFor` 立刻醒），走訪不再貢獻（下一台之前就 break）。
3. **既有的地板**：`main.cpp` 依序停五個子系統，而 finding 自己記的閒置關機成本本來就是
   **2.40–3.00 秒**——那與這兩個缺陷無關。所以界訂在 3 秒是「不比現在差」，
   不是「我們讓它變成 3 秒」。

超過界時會怎樣：`reportIfWorkersOutlastTheBound()` 印**一行**（不是每個 worker 一行、
也不是每秒一行），帶著子系統名、還沒回來的 worker 名字、以及**經過的秒數**。
它**不 detach、不放棄、不殺 worker thread**——呼叫端照樣 join。
detach 一個還在碰物件成員的 thread 是 use-after-free，而**一個用崩潰來回傳的「有界停止」不是有界停止**；
這一行買到的是「剩下的等待被解釋了」，而不是看起來像當掉。

---

## 4. 紅 → 綠

測試檔 `tests/test_KernelStopIsBounded.cpp`，六個 case。

### 4.1 紅（trunk 的行為）

`ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound`，**親眼看到的紅**：

```
[ RUN      ] KernelStopIsBoundedTest.ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound
curl: (28) Operation timed out after 5002 milliseconds with 0 bytes received   ← switches
curl: (28) Operation timed out after 5002 milliseconds with 0 bytes received   ← hosts
curl: (28) Operation timed out after 5002 milliseconds with 0 bytes received   ← links
test_KernelStopIsBounded.cpp:396: Failure
Expected: (elapsed) < (kStopBound), actual: 15010119827ns vs 3s
stop() took 15.010119827 s while the poll was inside `curl --connect-timeout 2 --max-time 5`.
[  FAILED  ] KernelStopIsBoundedTest.ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound (15032 ms)
```

三個 endpoint 各自 5002 ms 逾時，一個一個排隊，加起來 15.010 秒——
**與 §6.3 的 live 15.00 秒是同一個數字**，一個在單元測試裡、一個在真 kernel 上。

儀器對照組 `TheInstrumentReallyWedgesACurl` 同一輪是綠的（1014 ms、body 空、curl exit 28），
所以上面那個紅不是「假控制平面壞了」。

🏁 **09-04 補收到了**（把 `DeviceConfigurationAndPowerManager.cpp` 單獨還原成修法前那一版
`535f8f4b^`、其餘不動，＝ trunk 的走訪對上本支的測試）：

```
Expected: (elapsed) < (kStopBound), actual: 32018696072ns vs 3s
stop() took 32.018696071999997 s with 4 switches against a control plane that accepts and never answers.
[  FAILED  ] KernelStopIsBoundedTest.AFlowTablePollCaughtMidRoundStopsWithinTheBound (32039 ms)
```

**32.019 秒 ＝ 4 台 × 8 秒**，對到小數點。跑完該檔還原為 byte-identical。

以下是當時的紀錄：**`AFlowTablePollCaughtMidRoundStopsWithinTheBound` 的紅當晚沒有以 gtest 形式收到**，
原因與程式無關：整晚建置鎖被另外三支 agent 的變異閘門佔滿（一次 2 步的增量建置排了 80 分鐘），
而我把僅有的一次建置機會用在修法上。
**它的紅是 live 收的**：§6.3 的 **79.77 秒**，真 kernel、真 SIGINT、10 台 switch、
假控制平面記到整整 10 次 `/stats/flow/` 被卡住。那比一個單元測試更接近 row 27 量的東西。
（另有一個 gdb 直接觀察：trunk 上主執行緒卡在 `futex_do_wait`（join）而
`sh -c curl -s --max-time 8 …/stats/flow/…` 子行程一個接一個地跑。）

### 4.2 綠（修法後，同一顆 binary sha256 `98981de3…5281bd`）

```
[       OK ] KernelStopIsBoundedTest.TheInstrumentReallyWedgesACurl (1009 ms)
[       OK ] KernelStopIsBoundedTest.AFlowTablePollCaughtMidRoundStopsWithinTheBound (21 ms)
[       OK ] KernelStopIsBoundedTest.ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound (21 ms)
[       OK ] KernelStopIsBoundedTest.AStopThatExceedsItsBoundSaysWhatItIsWaitingOn (21 ms)
[       OK ] KernelStopIsBoundedTest.TheMonitorsStopReportNamesItsOwnWorkers (21 ms)
[       OK ] KernelStopIsBoundedTest.StoppingTwiceAndStoppingWhatNeverRanAreBothImmediate (1 ms)
[  PASSED  ] 6 tests.
```

**15,032 ms → 21 ms**，約 700 倍。儀器對照組仍然是 1009 ms（假控制平面照樣卡住，
只是現在沒有人在等它）。

### 4.3 全套

| 套件 | 結果 |
|---|---|
| gtest binary 全跑 | **957/957 PASSED**（trunk 的 951 ＋ 本支 6，數字對得上） |
| `ctest --output-on-failure` | **957/957，0 failed**，13.28 s |
| `tests/python`（29 模組） | **29/29** |
| `p4_proxy/tests`（25 模組） | **25/25** |

🔴 `tests/python` 中途**紅過一次**，而且是它該做的事：見 §8.4。

---

## 5. 變異閘

`tests/shell/mutate_kernel_stop_is_bounded.sh`，形狀照 `mutate_poll_does_not_resurrect.sh`：
15 個錨點先斷言唯一、`cp -p` 快照＋EXIT trap 還原＋`touch`、跑完驗 byte-identical
與 test binary sha 不變、不編譯的變異算存活、hang 既不算紅也不算抓到。
它也**重跑既有的關機閘門**（`PowerManagerShutdownDeathTest.*`），因為第二個方向只有它抓得到。

**8 個變異（方向一：把缺陷放回去）**

| # | 變異 | 期望紅 |
|---|---|---|
| M1 | flow-table 的 curl 換回不可取消的 `execCommand` | flow-table case |
| M2 | topology 的 curl 換回 `execCommand` | topology case |
| M3 | `request()` 不再殺子行程 | 兩個 case |
| M4 | `waitFor` 忽略旗標、睡好睡滿 | flow-table case（經 `statusUpdateWorker` 的 10 秒） |
| M5 | 電源管理的 `stop()` 不再 `request()` | flow-table case |
| M6 | monitor 的 `stop()` 不再 `request()` | topology case |
| M7 | 超界報告什麼都不說 | 兩個報告 case |
| M8 | **刪掉 openflow 的 join**（方向二） | **B-5 的兩個死亡測試** |

M8 是這支閘門真正的重點：**刪掉 join 會讓 `stop()` 在微秒內回來、讓上面每一個計時斷言變綠**，
同時把 KNOWN-ISSUES B-5 放回去（destroy 一個 joinable thread ＝ `std::terminate`、SIGABRT、134）。
沒有 M8 的閘門等於對「把 join 刪掉」開綠燈。

**5 個放寬控制組（必須全綠）**：W1 註解、W2 報告換句話（測試只斷言 worker 名與子系統名，
不斷言句子）、W3 停止檢查改成等價寫法、**W4／W5 兩個「這套測試守不住」的冗餘檢查**（見 §8.3）。

### 5.1 09-04 補跑：8/0，但第一次跑出 2 個誤捕，而錯的是這套測試

第一次在合併樹 `63792cc9` 跑完：**8 變異 0 存活**（每一條缺陷路線都守住了），
但 **5 放寬 2 誤捕**——W4（走訪迴圈開頭的停止檢查拿掉）與 W5（三個 endpoint 之間的檢查拿掉）
都讓 `AStopThatExceedsItsBoundSaysWhatItIsWaitingOn` 變紅。

**原因是那個 case 自己有競態，不是那兩個檢查是行為。** 同一顆 binary、同一份原始碼，
**只改 CPU affinity**：

| 條件 | 結果 |
|---|---|
| 14 顆核心 | **15/15 綠** |
| `taskset -c 3`（釘在一顆） | **0/15 綠** |

而失敗那幾次擷取到的 log 是

```
stop: cancelled 1 in-flight control-plane request(s)
Collector Stops
```

——**那是 `stop()` 做對了**：它取消了正在飛的請求，三條 worker 隨即結束，
報告因此正確地沒有印，因為**已經沒有東西在等了**。錯的是斷言，不是 kernel。

競態本身：`stop()` 依序做 `m_running=false` → `request()`（殺掉 curl **並且** `notify_all()`
叫醒每個睡眠中的 worker）→ 然後才 `waitForWorkers(0ms)` **取樣一次**。
那一瞬間還有沒有 worker 登記著，是主執行緒與三條 worker 的賽跑；14 核時主執行緒穩贏，
單核時穩輸，而放寬動到 worker 離開迴圈路徑上的幾個指令，就足以把它推過去。

修法在測試這一側：報告改成在它真正住的地方被測——**測試自己持有的 `StopSignal`，
以及測試自己撐著不放的 `WorkerScope`**。落單的 worker 因此是 fixture 的事實，
而不是排程器的結果。用當初打爛舊寫法的條件驗證：**釘在一顆核心，15/15 綠**。
三個 case 取代兩個，第三個是**零鑑別力守衛**（無條件印的報告會滿足前兩個，
卻對操作者謊稱健康的關機卡住了）。

**補跑結果（`JOBS=1`，guard 下）：8 變異 0 存活、5 放寬 0 誤捕、`guarded_build: exit 0`。**
baseline 10 個 case 全綠且沒有任何 skip；還原後三個檔 byte-identical；
test binary sha 回到基準 `8d45ef8f308cc3e9`。

🔴 **這樣放棄了什麼**：現在沒有任何測試釘住
`DeviceConfigurationAndPowerManager::stop()` **仍然呼叫**那個報告。那個呼叫點靠 review 守，
不靠這套測試——**一個三次裡守住兩次的測試什麼都沒守住，而且對另外那一次說了假話。**

### 5.2 第一次跑的紀錄

🔴 **第一次未能由我執行完畢。** 建置鎖整夜由其他 agent 的四支變異閘門佔用
（單次 2 步增量建置排隊 80 分鐘；本閘門排入後到交班時仍未取得鎖）。
閘門腳本已 `bash -n` 通過、15 個錨點在本支修法後的樹上**逐一驗證為唯一**，
但**「幾抓幾存活」這個數字我沒有量到，因此不報**。
交接：`tools/build_guard/guarded_build.sh ./tests/shell/mutate_kernel_stop_is_bounded.sh`，
log 在 session scratchpad `logs/gate.log`。

---

## 6. Live 數字（沒有用 lab）

沒有 `ndt up`、沒有 claim、沒有 Mininet／bmv2／OVS、沒有 sudo。全部在 loopback 上：
一個 python 假控制平面（`live/fake_control_plane.py`）＋真的 `ndtwin_kernel`。
今晚有三支 agent 在排 lab，這條路徑完全不碰它。

### 6.1 為什麼假控制平面要「接受然後不回話」

FIX-CLOEXEC.md §2.3 已經量過：**`:8081` 沒人聽的時候，每個 poll 的 curl 0 ms 就失敗**，
兩個缺陷都不重現——**「拒絕」是快的**。要花掉整個 `--max-time` 的，是一個完成三向交握
之後就不再說話的對端。所以假控制平面 accept、讀完 request、然後**永遠不寫一個 byte**。

### 6.2 為什麼 #27 的假控制平面必須先回答一部分

`loadStaticTopologyFromFile` 把每個 vertex 都設成 `isUp = false`，而
`isPollableForFlowTable` 要 `isUp`。**一個什麼都不回答的 proxy 會讓每台 switch 都是 down，
flow-table worker 就什麼都不 poll，#27 不重現。** row 27 量到的是一個 switch 本來就 up
的 fabric 上控制平面停止回答。所以 s27 這一臂：
`/v1.0/topology/switches` **回答 10 台**（把它們抬成 up）、`/stats/flow/*` **卡住**——
拓樸面健康、flow-stats 面卡住，正是 row 27 描述的條件。

### 6.3 BEFORE（trunk `b57736cd`，sha256 `50ad6e35…0b0f468`）

| 情境 | 量的是什麼 | N | 每次（秒） | 平均 |
|---|---|---|---|---|
| **s27**（#27） | SIGINT → 行程消失，10 台 switch、flow-stats 卡住 | 5 | 79.756／79.759／79.773／79.799／79.741 | **79.77** |
| **s76**（#76） | `Exiting` 那行 → 行程消失，bind 失敗＋全部卡住 | 5 | 15.006／14.983／15.000／15.009／14.984 | **15.00** |

**兩個都對得上算術，而不是「差不多」：**

- s27：假控制平面記到**整整 10 次** `/stats/flow/` 被卡住（每 rep 都是 10），
  10 × 8 秒 `--max-time` = 80 秒，量到 79.77 秒。
  FINDINGS row 27 在真 fabric 上量到的是 **81.09 秒**——**同一個數字**。
- s76：3 個 endpoint × 5 秒 `--max-time` = 15 秒，量到 15.00 秒（五次的全距只有 26 ms）。
  🔴 **row 76 記的「8 秒後行程仍在」是一個下界，不是總長**：那是一次點取樣。
  實際上這條路徑要 **15 秒**，接近兩倍。

s76 的 `exit_code` 是 1（`EXIT_FAILURE`，kernel 自己決定退出）；
s27 的是 0（SIGINT 走完整關機路徑），兩者都不是被殺的——**慢，但不是壞**。

### 6.4 AFTER（本支 `27e33c9f`，sha256 `1ea6f22a…5ee095c`）

兩顆 binary 只差修法那幾個 commit，兩者 sha256 都記在 `live/*/kernel.sha256`。

| 情境 | BEFORE | AFTER | 倍數 |
|---|---|---|---|
| **s76**（#76） | 15.006／14.983／15.000／15.009／14.984 → **15.00 s** | 0.0070／0.0068／0.0061／0.0070／0.0056 → **0.0065 s** | **≈2,300×** |
| **s27**（#27） | 79.756／79.759／79.773／79.799／79.741 → **79.77 s** | 4.710／4.706／4.691／4.702／4.687 → **4.699 s** | **17×** |

s27 的 `flow_reqs` 欄從 **10 → 1**：假控制平面現在每次只被問一個 `/stats/flow/`，
之後那一輪就被放棄了。**走訪真的在第一台之後就停了。**

#76 的訊息也照設計換了（rep1 實際 log）：

```
02:44:24.017 [critical] main.cpp:459 cannot start telemetry collection: … Shutting down -- …
02:44:24.017 [info]     TopologyAndFlowMonitor.cpp:339 stop: cancelled 1 in-flight topology request(s)
02:44:24.018 [critical] main.cpp:464 telemetry collection could not start; exiting now.
```

「宣告要退」到「真的退」之間 **1 ms**，而且 `Exiting` 這個字不再出現在 stop() 之前。

### 6.5 🔴 4.7 秒不是 3 秒——界要改口徑，不是改數字

s27 的 AFTER 是 **4.70 秒**，**超過我在 §3 提的 3 秒**。這件事必須講清楚，
而它剛好落在 §8.1 已經預告的地方。rep1 的關機時間軸：

```
02:44:44.476  main.cpp        Shutdown requested. Cleaning up…
02:44:44.476  TopologyAndFlowMonitor  Exiting … updating        ← 我修的 monitor：0 ms
02:44:44.476  FlowLinkUsageCollector  Collector Stops           ← collector 的 stop() 開始
02:44:49.083  DeviceConfigurationAndPowerManager  cancelled 2 in-flight requests  ← 4.607 秒之後
02:44:49.084  main.cpp        All subsystems stopped. Exiting.  ← 電源管理：1 ms
```

**4.607 秒整段都在 `FlowLinkUsageCollector::stop()` 裡面**——就是 §8.1 表格裡那四條
我明講沒有修的 thread（沒切片的 1–2 秒 sleep，加上 `--max-time 10` 的 curl）。
我修的那兩個子系統是 **0 ms 與 1 ms**。

所以界要分兩層講，而不是含糊成一個數字：

| 界 | 值 | 證據 |
|---|---|---|
| **我修的每個子系統**（monitor、power manager） | **≤ 3 秒，實測 21 ms（gtest）／0–1 ms（live）** | ✅ 達成 |
| **整個行程**（`main.cpp` 依序停五個子系統） | **4.70 秒**，其中 4.61 秒在沒修的 collector | ❌ 未達 3 秒 |

**我不把 3 秒改寫成 5 秒來讓它看起來達標。** 工單要的是「stop() 有界」，
而這支分支交付的是**它負責的那兩個 stop() 有界**，並且把剩下那 4.61 秒
**指到單一一個具名的子系統**——那是下一支分支一行一行照抄同一個原語就能收掉的。
在那之前，對外能承諾的行程層級數字是 **5 秒**，不是 3 秒。

---

## 7. 合併

### 7.1 對 trunk

```
git merge-tree --write-tree trunk fix/kernel-stop-is-bounded
→ rc=0   tree 095c1f37f30a3ecd15188c07d2ad8a227b790212
```

**乾淨。**

### 7.2 對 `fix/is-up-split-admin-state-reachable`（`76b8313e`，今晚同時在寫）

```
git merge-tree --write-tree fix/is-up-split-admin-state-reachable fix/kernel-stop-is-bounded
→ rc=1
CONFLICT (content): Merge conflict in tests/CMakeLists.txt
```

**只有一個衝突檔，而且是那個已知的 add/add**：兩支各自往同一份清單尾巴加自己的測試檔。
MERGE-LOG 的第 13、23、27 列各記過一次同樣的東西，處置也一樣——**兩塊都留**。

值得記的是**沒有衝突的那些**：

```
Auto-merging include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp
Auto-merging src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
```

兩支**都改了**電源管理的 header 與 cpp（is-up 那支在那個 .cpp 裡 +159 行），而它自動合起來了。
`src/main.cpp` 兩支也都動、也自動合起來。is-up 那支**完全沒碰** `TopologyAndFlowMonitor.cpp`——
它動的是 `HttpSession.cpp`／`P4PowerStrategy`／`Logger`。

工單要求「hunk 小而局部」的理由在這裡兌現了：把原語放進**一個新檔**
（`include/utils/StopSignal.hpp`）而不是塞進 `Utils.hpp`，讓這支分支在兩個共用檔案裡
只留下幾個各自獨立的小 hunk，所以三方合併不需要人來讀。

🔴 **但這是「今晚這一刻」的結果**：is-up 那支還在寫。合併前要重跑。

---

## 8. 沒有做的事

### 8.1 同一個形狀、**沒有**修的 worker

派出去的普查在 `src/` 底下找到 **11 個** 符合這個形狀的 worker
（`while (m_running)` ＋ 迴圈內有阻塞呼叫 ＋ 旗標只在輪與輪之間讀）。
修了其中 **5 個**——就是被我修的那兩個 `stop()` 會 join 的那五條 thread，
因為那五條才是我的測試量得到的：

| 修了 | thread | 所屬 stop() |
|---|---|---|
| ✅ | `openflowTablesUpdateWorker`（#27 本體） | 電源管理 |
| ✅ | `statusUpdateWorker`（只改睡眠，見下） | 電源管理 |
| ✅ | `pingWorker`（睡眠＋兩個阻塞呼叫都改可取消） | 電源管理 |
| ✅ | `runLoop`／topology poll（#76 本體） | topology monitor |
| ✅ | `flushEdgeFlowLoop`（只改睡眠） | topology monitor |

**沒有修的六個**，以及為什麼：

| worker | 檔案 | 最壞一輪 | 為什麼沒修 |
|---|---|---|---|
| `statusUpdateWorker` 的**四個 fetch** | `DeviceConfigurationAndPowerManager.cpp:2057` | 🔴 **無界**：`snmpget`／`snmpwalk` 沒有 `-t`／`-r`，`SSHHelper` 只有 `-oConnectTimeout=10`（連上之後卡住就沒有界） | 只有 TESTBED 會走（MININET 的 power 是合成值，已查證），而**我沒有 testbed**。改了會是沒看過紅的交付 |
| `pingSwitch`（TESTBED 分支） | 同上 `:382` | N × 約 18 秒（3 次嘗試 × `ping -W 5` ＋ 1 秒間隔） | 同上：TESTBED-only，測不到 |
| `refreshDestinationPathsPeriodically` | `FlowLinkUsageCollector.cpp:538` | 10 秒（`--max-time 10`） | 屬於 collector 的 `stop()`，**不是我在量的那兩個**。它已經是這批裡最守規矩的一個（curl 之前有重讀旗標） |
| `testCalAvgFlowSendingRatesRandomly`／`purgeIdleFlows`／`calAvgFlowSendingRatesPeriodically`／`calFlowPathByQueried` | `FlowLinkUsageCollector.cpp` | 各約 1–2 秒（都是**沒切片**的 sleep，沒有子行程） | 同上：collector 的 `stop()`。沒有外部呼叫，所以它們是秒級地板而不是分鐘級 |
| `HistoricalDataManager::run` | `HistoricalDataManager.cpp:196` | 約 1 秒＋快照寫檔 | 睡眠已經切片；沒有子行程。且 MININET 根本不啟動它 |

**這是一份清單，不是一份藉口**：collector 的四條 thread 是 `main.cpp` 關機序列的第二站，
它們的秒級地板會直接加進行程層級的關機時間。要把**行程**的界壓到 3 秒以下的最後一段，
就是把同一個原語接到 `FlowLinkUsageCollector::stop()`——那是一支獨立的分支，
因為那個檔案現在有兩支別的分支在動。

### 8.2 其他刻意沒做的

- **沒有把 `popen`／`std::system` 全面換成 `execArgv`。** FIX-CLOEXEC.md §7 把這件事列為
  「刻意不做」，理由今天仍然成立（九個站點的行為變更）。`execCommandCancellable` **不是**那個轉換：
  它還是 `/bin/sh -c`、還是同一個字串，只是這個行程握得到 pid。
- **沒有動 `--max-time` 的數值。** 8 秒與 5 秒是 `test_RequestDeadlines.cpp` 釘住的 wire format，
  而且它們是「控制平面很慢」的界，不是「關機」的界。這支分支改的是後者。
- **沒有註冊 SIGTERM handler。** FINDINGS row 27 自己把順序寫死了：**先把輪詢變成有界的，再註冊 handler**。
  第一步做完了；第二步是下一支分支的事，而且它現在**才有意義**——
  在此之前註冊 handler 等於把「一定立刻死」換成「等 10 秒然後照樣被 SIGKILL」。
- **`main.cpp` 的五個子系統仍然是序列停止。** 兩段式（先對五個都 `requestStop()`、再逐一 join）
  會把行程層級的界從「五個之和」變成「五個之最大」。那要在五個類別上各加一個方法，
  比這支分支該碰的範圍大。
- **`ControllerAndOtherEventHandler.cpp:284` 有一行過期的註解**（說「只有 `while(m_running)` 迴圈
  離開才會印」，而那個迴圈已經不存在了）。普查順手發現的，**沒有動**——不是這支的題目。
- **`SimulationRequestManager.cpp:296` 與 `HttpSession.cpp:398` 各有一條 detach 的 thread，沒有人 join。**
  它們可以活過 `stop()` 並在關機開始後碰物件。**沒有動**，另案。

### 8.3 這支分支的閘門**不**保護的東西

`pollControlPlaneTopology` 裡三個 endpoint 之間的停止檢查，**變異閘抓不到**——
因為 `execCommandCancellable` 在 fork 之前就問過 `stopRequested()`，
所以拿掉那三個檢查之後、停止請求之後剩下的兩個 endpoint 各只花一個 syscall，那一輪還是在界內結束。
我把它放在**放寬控制組 W4**，而不是假裝它是一個 catch。它是對「未來有人改動 executor」的縱深防禦，
不是這套測試守得住的行為。

**走訪迴圈開頭那個停止檢查也一樣**（W5）。原本我寫了一個「把它拿掉＝把缺陷放回去」的 M1，
**在跑閘門之前先用手追了一次，發現它會存活**：走訪裡還有第二個檢查（curl 之後），
而且就算兩個都拿掉，`execCommandCancellable` 在 fork 之前就問旗標，剩下每台只花一個 syscall。
⇒ **旗標檢查不是界的來源，取消才是。** 那個 M1 在跑之前就被刪掉了，改列為 W5。
它們真正的用途是設 `FlowTableFetch::abandoned`（不讓被中斷的一輪覆蓋快取），
而**那個性質這套測試沒有量**。

### 8.4 中途紅過的那個 python 測試（它是對的）

`tests/python/test_shell_command_construction.py` 在修法後**紅了**，四個站點同時
「classified 1, found 0」。原因不是分類錯，是 **`SHELL_CALL` 那個正規式
`\butils::execCommand\s*\(` 對不上 `utils::execCommandCancellable(`**——
`execCommand` 後面接的是 `C` 不是 `(`。

⇒ 那四個站點不是「改名」，是**整個從清單裡消失了**。
一個仍然走 `/bin/sh -c` 的站點，因為被改名就退出了「有人在分類它」的名單——
**這正是這個檔案存在要防的事，而它從沒人寫下來的那個方向來。**

處置：正規式加一個可選的 `(?:Cancellable)?`，讓站點**不可能靠改名離開清單**；
四個 key 更新，而 provenance 依照這個檔案自己在 09-03 記下的教訓
**重新推導、不是照著新行文字改**（同一個 std::string、同一個 `/bin/sh -c`、
`StopSignal` 那個參數不進命令列 ⇒ 分類不變，而且每一條都寫明為什麼）。
commit `27e33c9f`。

---

## 9. 給 Adam 的問題

1. 🔴 **界要用哪一層對外講？** 我修的兩個子系統各自 ≤ 3 秒（實測 21 ms），
   但**整個行程量到 4.70 秒**，其中 4.61 秒在我沒修的 `FlowLinkUsageCollector::stop()`（§6.5）。
   選項：(a) 對外只承諾 5 秒，等 collector 那支收完再改 3 秒；
   (b) 現在就派 collector 那支，兩支一起併，然後承諾 3 秒；
   (c) 兩層都寫進文件（子系統 3 秒／行程 5 秒）。**我建議 (b)**——
   那支是照抄同一個原語，而 4.61 秒是目前唯一擋在 3 秒前面的東西。
2. **`Exiting` 的措辭改了（→ `Shutting down`，並在 stop() 之後才印 `exiting now`）。**
   這是**對外可見的字串變更**。有沒有腳本／同事的工具在 grep `Exiting`？我查不到 repo 外的使用者。
3. **8.1 的六個 worker，要不要現在派一支分支去收 collector 那四條？**
   那是把**行程**層級的界真正壓下去的最後一段；我沒做是因為那個檔案現在有兩支別的分支在動。
4. **TESTBED 的 snmp／ssh 是這批裡唯一真正「無界」的**（沒有 `-t`、沒有 `-r`）。
   要不要在沒有 testbed 的情況下先補上超時參數（純參數、不改結構），還是等能實測再動？
5. 🔴 **順手挖到一個與本題無關的 kernel 崩潰，我沒有修**：
   `fetchCpuReportInternal` 對每個 SWITCH vertex 做 `vp.ip.front()`，
   **沒有檢查 `ip` 是否為空**（`DeviceConfigurationAndPowerManager.cpp:1689`）。
   gdb 實測：一個沒有 IP 的 switch vertex ⇒ 10 秒內 SIGSEGV 整個 kernel 死掉
   （raw `logs/gdb_segfault_no_ip.log`）。
   **要緊的是它可能不只是測試夾具的問題**：`updateSwitches` 會為靜態拓樸不認識的 dpid
   新增 switch vertex，而那個 vertex 是從控制平面的 `/v1.0/topology/switches` 來的——
   **那份回覆裡沒有 IP**。若真是如此，這是一個「控制平面列出一個拓樸檔沒有的 dpid ⇒ kernel 當場死」的
   線上崩潰。我已開一張獨立的 task（含 gdb stack 與查證順序），**沒有在這支裡動它**。
6. **磁碟**：交班時 `/` 只剩 **4.1 GB**（floor 是 4 GB）。變異閘門要重跑，先看一眼。
