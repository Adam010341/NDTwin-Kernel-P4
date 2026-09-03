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

（本節數字在測完後填入。）

---

## 5. 變異閘

（本節數字在跑完後填入。）

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

### 6.4 AFTER

（等 fix 建置完成後填入。建置鎖今晚由三支別的 agent 的變異閘門排滿。）

---

## 7. 合併

（`git merge-tree --write-tree trunk fix/kernel-stop-is-bounded` 的結果填入。）

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

---

## 9. 給 Adam 的問題

1. **3 秒這個界，要不要寫進對外文件？** 現在它只寫在這份文件和測試的 `kStopBound` 裡。
   如果 `ndt down`／重啟腳本要依賴它，它就得是一個有人維護的承諾，而不是一個常數。
2. **`Exiting` 的措辭改了（→ `Shutting down`，並在 stop() 之後才印 `exiting now`）。**
   這是**對外可見的字串變更**。有沒有腳本／同事的工具在 grep `Exiting`？我查不到 repo 外的使用者。
3. **8.1 的六個 worker，要不要現在派一支分支去收 collector 那四條？**
   那是把**行程**層級的界真正壓下去的最後一段；我沒做是因為那個檔案現在有兩支別的分支在動。
4. **TESTBED 的 snmp／ssh 是這批裡唯一真正「無界」的**（沒有 `-t`、沒有 `-r`）。
   要不要在沒有 testbed 的情況下先補上超時參數（純參數、不改結構），還是等能實測再動？
