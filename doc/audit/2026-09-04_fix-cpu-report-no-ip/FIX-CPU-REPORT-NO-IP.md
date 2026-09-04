# FINDINGS #85：沒有管理 IP 的 switch vertex 會讓整個 kernel SIGSEGV

分支 `fix/cpu-report-no-ip-switch`，base `f138b767`。
[Co-developed with claude code -- Adam]

---

## 1. 一句話結論

**缺陷是真的，`front()` 打在空 vector 上、gdb 有堆疊為證；但「線上可達」不成立。**
finding 猜的那條路（控制平面列出拓樸檔沒有的 dpid ⇒ `updateSwitches` 生出一個沒有 IP 的
switch vertex）在現在的 trunk 上**走不通**——`updateSwitches` 根本不新增 vertex。
另一頭 `loadStaticTopologyFromFile` 從 `2da6954f`（07-30）起就在載入時拒絕 `"ip": []` 的 switch，
main.cpp 收到拒絕就結束。**兩條寫入口都封住了。**

所以 #85 **從「線上崩潰」降級為「潛伏缺陷」**。仍然修，理由在 §4。

---

## 2. 缺陷本體

`fetchCpuReportInternal` 迴圈本體第一句：

```cpp
std::string ip_str = utils::ipToString(vp.ip.front());
```

`VertexProperties::ip` 是 `std::vector<uint32_t>`，**預設是空的**。空 vector 上 `front()` 是
UB；實測是 fault。而它跑在 `statusUpdateWorker` 的執行緒上，**任何一條執行緒吃到未處理的
SIGSEGV，整個行程就結束**——不是那一輪失敗，是 kernel 死掉。

證據（不是我產的，是 stop agent 09-04 凌晨在 gdb 下抓到的）：

```
Thread 4 "test_routing_st" received signal SIGSEGV, Segmentation fault.
0x...b7a08e in DeviceConfigurationAndPowerManager::fetchCpuReportInternal[abi:cxx11]()
    at .../DeviceConfigurationAndPowerManager.cpp:1689
1689	        std::string ip_str = utils::ipToString(vp.ip.front());
#1  ... in DeviceConfigurationAndPowerManager::statusUpdateWorker ()
    at .../DeviceConfigurationAndPowerManager.cpp:2066
```

原正本：`git show audit-raw:doc/audit/2026-09-03_fix-kernel-stop-bounded/raw/logs/gdb_segfault_no_ip.log`
（本次沒有新增 raw log 到那個路徑，見 §8）。
行號 1689 已漂移到 **1786**（未改動的 trunk 上）。

**同一輪還有三個一樣的位置**，全部在 `statusUpdateWorker` 一輪裡：

| 函式 | 未修 trunk 行號 | 何時會 fault |
|---|---|---|
| `fetchPowerReportInternal` | 1543 | **只有 TESTBED**（MININET 用 dpid 算，本來就不碰 IP） |
| `fetchCpuReportInternal` | 1786 | 兩種模式都會 |
| `fetchMemoryReportInternal` | 1068 | 兩種模式都會 |
| `fetchTemperatureReportInternal` | 1884 | 兩種模式都會 |

TESTBED 模式下 **power 排在最前面**（worker 依序呼叫 power → cpu → memory → temperature），
所以真正先炸的是 1543，不是 gdb 抓到的那個。

⚠️ **worker 的節拍**：交辦單寫「this worker ticks at 1 Hz」，**實際是 10 秒一輪**
（`m_stopSignal.waitFor(std::chrono::seconds(10))`，`statusUpdateWorker` 尾端）。1 Hz 的是
`pingWorker`。結論不變（每輪一行 WARN 一樣是洗版），但數字要更正。

---

## 3. 可達性：怎麼查的，查到什麼

問題是「一個 SWITCH vertex 有沒有辦法在生產環境裡帶著空 `ip` 存在」。
把「誰能造出 vertex」和「誰能寫 `ip`」兩件事分開窮舉：

**(a) 生產碼裡的 `boost::add_vertex` 只有一處**：`TopologyAndFlowMonitor.cpp:680`，靜態拓樸載入。
（其餘 20 幾處全在 `tests/`。）

**(b) 生產碼裡寫 `vp.ip` 只有三處**：
`TopologyAndFlowMonitor.cpp:621`（載入）、`DeviceConfigurationAndPowerManager.cpp:1960`
（`fetchSmartPlugInfoFromFile`，讀同一份檔、**只讀不建 vertex**，而且它自己就有 `ip.empty()` 檢查）、
`GraphTypes.hpp:478` 的 `from_json(VertexProperties&)`——**這一支在 `src/` 底下沒有呼叫者**
（`grep get<VertexProperties>` 在 src/include 零命中）。

**(c) `updateSwitches` 不新增 vertex。** 這是 finding 猜錯的地方。實碼（`TopologyAndFlowMonitor.cpp:1424-1429`）：

```cpp
else
{
    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "Switch ({}) not found in static network topology file",
                       switchDpidStr);
}
```

它只寫 `isUp`／`isEnabled` 到**已存在**的 vertex；不認得的 dpid 就一行 WARN。
`updateHosts`／`updateLinks` 同理（host 那條也不建 switch）。

**(d) 載入端已經拒絕了。** `TopologyAndFlowMonitor.cpp:664`：

```cpp
if (vp.vertexType == VertexType::SWITCH && vp.ip.empty())
{
    throw std::runtime_error("switch dpid ... has an empty \"ip\" array; ...");
}
```

`git log -L` 指到 **`2da6954f`（2026-07-30，"Reject a switch with no management address at load,
not with undefined behaviour later"）**，是別的 session 為 F-61/62 做的。
`loadStaticTopology()` 接住這個 throw、印 CRITICAL、回 false，main.cpp 就退出。

⇒ **裁定：現在的 trunk 上不可達。** finding 的 reachability 欄要改寫成
「`updateSwitches` 不建 vertex；載入端自 `2da6954f` 起拒絕空 ip」。

**這條裁定本身被寫成測試**（`UpdateSwitchesInventsNoVertexForADpidTheTopologyDoesNotDeclare`）：
餵一份 Ryu `/v1.0/topology/switches` 形狀的回覆、裡面有一個拓樸沒有的 dpid，斷言
**vertex 數不變**、而且那行 WARN 有出現。哪一天這條紅了，#85 就**重新變成線上遠端崩潰**，
而擋在前面的只剩我這支修的空檢查。

---

## 4. 既然不可達，為什麼還是修

三個理由，按份量排：

1. **守恆的那個 `if` 在別的子系統、別的檔案，而且只有五週大。** 「每台 switch 至少一個位址」
   這個不變式現在由 `TopologyAndFlowMonitor` 一行 `if` 撐著；`DeviceConfigurationAndPowerManager`
   對它有依賴、卻沒有任何一句話說出這個依賴。改壞它的代價不是一個爛讀數，是**行程**。
2. **`from_json(VertexProperties&)` 沒有這個檢查**，今天沒有呼叫者不等於明天沒有。
3. **檔案裡早就寫下這個坑、而且明講不處理**：`fetchTemperatureReportInternal` 上方 F-1b 的註解說
   *"A switch carrying no IP would still fault one branch later, in all three functions. That is a
   separate question ... and is deliberately not answered here."* 這支就是來回答那個問題的。

---

## 5. 修法

新增四個 helper（宣告與理由都寫在 header）：

| 名稱 | 作用 |
|---|---|
| `managementIpOf(vp)` | 空就回 `nullopt`，**不回 `"0.0.0.0"`**（假位址是這個檔已經被燒過兩次的失敗模式） |
| `reportKeyForSwitchWithoutIp(dpid)` | 回 `"dpid:<十進位>"` |
| `noteSwitchMissingManagementIp` / `noteSwitchHasManagementIp` | 邊緣觸發記憶（`std::set<uint64_t>`） |
| `managementIpForReport(vp)` | 上面三個的組合，四份報表實際呼叫的那一支 |

四個站點的行為：

- **不能丟掉那台 switch。** 丟掉正是 2026-08-18 修過的缺陷：body 裡少一台，Web-GUI 的
  `data[ip] || 0` 會畫成 **0%**——讀起來像「閒置」而不是「讀不到」，那正是 Energy-Saving App
  在找的狀態。`test_SimulatedDeviceMetrics.cpp:118` 已經把這件事釘住了
  （"every switch must still have a key"）。
- **三份用 IP 當 key 的報表**（cpu／memory／temperature）：entry 保留，key 用
  `dpid:<n>`，值是 `kHealthMetricUnavailable`（`-1`）。
  前綴的用意是**不可能被誤讀成點分四段、也不可能撞到真的 key**。
  `-1` 不是我發明的：`doc/2026-01-02_ndt_api.md` §12/§13 已經寫著
  "A value of -1 means SNMP query failed or data is unavailable"。
- **power 報表本來就以 dpid 為 key**，所以不需要替代 key，只有值是 unavailable（`-1`）。
  **而且守衛留在 TESTBED 分支裡面**：MININET 的數字是 `syntheticPowerMilliwattsFor(dpid)`，
  header 註解自己就寫著這條路徑不可以呼叫 `ip.front()`——沒有位址的 switch 在這裡有一個
  完全真實的答案，不可以順手拿掉。**這一點有專門的測試守著**（見 §7 的 M9）。
- **WARN 一個 episode 一行**，點名 dpid。抄 `FailureRun` 與 `m_resurrectionDeclined` 的邊緣觸發：
  worker 每輪重讀整張圖，沒有邊緣觸發就是「拓樸錯多久、就每 10 秒一行」——那正是把 3596 行
  sudo 錯誤塞進一次執行、把其他東西全埋掉的形狀。dpid 由**該輪最先跑到的那份報表**認領，
  所以一個 episode 是一行、不是四行；那台 switch 下次帶著位址出現時 episode 結束、WARN 重新上膛。

另外把 `fetchPowerReportInternal` 從 private 移到 protected 的測試接縫（和它三個手足並排），
否則測試沒辦法驅動「完整一輪」。

---

## 6. 沒有動、但一樣沒有守衛的位置

交辦單要求列出來而不是順手改。**同一個檔案裡**：

| 位置（本分支行號） | 函式 | 誰呼叫 | 備註 |
|---|---|---|---|
| `DeviceConfigurationAndPowerManager.cpp:383` | `queryMininet` | `getSwitchesPowerState` ← `HttpSession.cpp:848`（`GET /ndt/get_switches_power_state`） | 對**每個** SWITCH vertex 做 `ip.front()` |
| 同上 `:2154` | `getSingleSwitchPowerReport` | `IntentTranslator.cpp:475` | |
| 同上 `:2183` | `getSingleSwitchCpuReport` | `IntentTranslator.cpp:464` | 迴圈裡對每個 SWITCH vertex 做 `ip.front()` 再比字串 |

`:2077`（`fetchSmartPlugInfoFromFile`）**已經有** `if (vp.ip.empty()) continue;`，不列入。

**別的檔案**（更沒有動，連讀都只是掃過）：

| 位置 | 函式 |
|---|---|
| `TopologyAndFlowMonitor.cpp:3377` | `findSwitchByIp` |
| `TopologyAndFlowMonitor.cpp:3391` | `findSwitchByIpNoLock` |
| `TopologyAndFlowMonitor.cpp:3613` | `initializeMappingsFromGraph` |
| `TopologyAndFlowMonitor.cpp:1634` | `updateHosts`（`ip[0]`，對象是 host） |
| `IntentTranslator.cpp:212 / 657 / 665 / 702 / 738` | `getSwitchIpByName`／`performTask` |
| `LLMAgent.cpp:243` | `getCurrentTopology` |

🔴 其中 **`findSwitchByIp` / `findSwitchByIpNoLock` 最值得單獨開一張**：
載入端那段註解自己就點名它——它在**搜尋時對每一個** switch vertex 做 `ip.front()`，
所以一台 `"ip": []` 的 switch 不是只弄壞自己，是**弄壞整張圖的 IP 查詢**。
它們不在 status worker 的路徑上，所以照交辦單留在這裡不動。

---

## 7. 紅 → 綠、與變異閘門

見同目錄的 `RED-GREEN.md`（逐字輸出）。摘要：

- 新測試檔 `tests/test_CpuReportNoIpSwitch.cpp`，註冊在 `tests/CMakeLists.txt`
  `test_routing_strategy` 來源清單的**最後**。
- 崩潰用 **death test**（`EXPECT_EXIT(..., ExitedWithCode(0), "")`）包起來。理由寫在測試檔頭：
  in-process 直接呼叫在舊碼上也會紅，但是**用整個 binary 陪葬的方式紅**——沒有 `[  FAILED  ]`
  這一行，後面每一個 suite 都不會跑。fork 一個子行程把 fault 關起來，才會變成一行具名的紅。
  （`test_SimulatedDeviceMetrics.cpp:245` 當時明講不寫 death test，是因為那個時間窗不能編譯；
  這支可以編譯、也編過了。）
- 閘門 `tests/shell/mutate_cpu_report_no_ip.sh`：**9 個變異 + 3 個對照**。
  結構抄 `mutate_f1_mininet_health_metrics.sh`（同兩個檔的鄰居）。
  `python3 tests/shell/check_gate_anchors.py HEAD --gates mutate_cpu_report_no_ip.sh` ⇒ `ok(12)`。

交辦單點名的四個變異都在：M1／M2（把崩潰放回去）、M3（WARN 每輪都印）、
M6／M7（報 0 不報哨兵）、M4（安靜跳過、不 WARN）；另加 M5（entry 被丟掉）、
M8（episode 永不結束）、**M9（過度守衛：把守衛提到模式分支之上，MININET 的合成功率就沒了）**。
M9 是這裡唯一一個「看起來比較整齊」的變異，也是最重要的一個：suite 若在它面前綠了，
釘住的就只是「不會崩」而不是「能報的照報」。

### 🔴 09-04 11:54：M2 SURVIVED，抓到的是**我的測試**的洞

閘門第一次跑到 M2（TESTBED power 路徑把解參考放回去）就把它判成 **SURVIVED**，而且判得對。

原因：M2 指名的必死測試 `AStatusRound...DoesNotKillTheProcess` 是
`buildManager(utils::MININET)`，而 **MININET 的 power 報表根本不讀位址**
（`syntheticPowerMilliwattsFor(dpid)` 只吃 dpid）⇒ 那個 death test 永遠碰不到 M2 改的那一行。
fault 於是落在 `TestbedPowerReportsTheSentinelForAnAddresslessSwitch`——一個**行程內**的呼叫——
binary 當場死掉、一行 `[  FAILED  ]` 都沒有。閘門自己的規則把這種情形印成 SURVIVED
而不是 caught（那條規則就是為了不讓 crash 被讀成乾淨的紅），於是它抓到了。

**修法**：加第二個 death test

```
NoIpSwitchTest.ATestbedStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess
```

在 TESTBED 下跑同一輪四份報表，**宣告在所有行程內 TESTBED 測試之前**（gtest 依宣告順序跑）。
閘門的 M2 已改指這一支。

⚠️ **這一支只做過 `-fsyntax-only`，沒看過紅。** 依 `03-test-discipline` 的規矩，
**在 merged-tree 閘門跑出它的紅之前，它不算交付**。M3–M9／C1–C3 的判定同樣來自那一輪
（本輪 M3 起卡在 build lock，auditor 12:58 停掉，EXIT trap 已復原兩個原始檔）。

**我也順手修好了別人的閘門**：`mutate_f1_mininet_health_metrics.sh` 的 M8 anchor
指著 `fetchTemperatureReportInternal` 裡那句 `std::string ip_str = utils::ipToString(vp.ip.front());`，
被我這支改掉了 ⇒ anchor 會失效（= SURVIVOR）。已重新指到新文字、判定不變（expected survivor），
並在註解裡更正**理由**：那個變異現在不再是 UB，而是「這個 suite 沒有斷言到的副作用」。
沒有刪掉它——因為變異不再危險就把它拿掉，正是閘門悄悄變鬆的方式。

---

## 8. 沒做的事

- **live**：沒有跑。這支修的是 kernel 內部的空 vector 檢查，沒有任何一段需要 fabric；
  而且要重現得先造出一個生產環境造不出來的圖（§3）。Lab 沒有 claim、`NDT_OWNER=noip` 沒有用到。
- **raw log 上 audit-raw**：見 §9 問題 3。
- **API 文件沒有動**。`get_power_report`（§6）**沒有記載任何哨兵值**；我在那裡用了 `-1`，
  理由是它的三個手足端點都用 `-1`、而 `0` 在這個端點已經是「關機」的意思。
  這是**文件與實作之間新開的一個口子**，要不要補進 `doc/2026-01-02_ndt_api.md` 見問題 2。

---

## 9. 給 Adam 的問題

1. 🔴 **`"dpid:<n>"` 這個 key 形狀可以嗎？** 這是**對外可見**的變更：
   `get_cpu_utilization` / `get_memory_utilization` / `get_temperature` 的 body 一直是
   「IP 字串 → 數字」，我在裡面放進了一個不是 IP 的 key。
   三個選項：**(a) 照現在（保留 entry、`dpid:<n>` 當 key、值 -1）**——我建議這個，因為
   「丟掉一台 switch」是這個檔案已經被燒過的失敗模式，而 `dpid:` 前綴不可能被誤讀成位址；
   (b) 直接省略那台 switch，只留 WARN——body 的 key 定義域不變，但 Web-GUI 會少一列，
   等於重演 08-18；(c) 用十進位 dpid 當 key、不加前綴——列出來比較好看，但一個 `3`
   放在一堆 `10.0.0.x` 中間會被當成壞掉的位址。
   **後果**：選 (a) 要通知 Web-GUI 那邊「key 不保證是 IP」。
2. **`get_power_report` 的 `power_consumed: -1` 要不要寫進 API 文件？**
   目前文件沒有替這個端點記載哨兵。我沒有改文件（那是共用檔、今晚有別人在動）。
   建議：補一行，措辭沿用 §12/§13 的 "-1 means ... data is unavailable"。
3. **raw 要放哪一個 audit-raw 路徑？** 交辦單指定
   `doc/audit/2026-09-04_fix-cpu-report-no-ip/raw/`；我這支的原始證據其實是
   **stop agent 09-03 那份 gdb log**（已經在 audit-raw 裡了），加上我自己的
   build／gtest／閘門輸出。要不要把後者也推上去，還是只留分支裡的 `RED-GREEN.md`？
4. **#85 的 coverage 欄要怎麼寫？** 我建議寫「**缺陷成立、線上不可達**（`updateSwitches`
   不建 vertex；載入端自 `2da6954f` 起拒絕空 ip）；已修並加測試守住可達性本身」。
5. **`findSwitchByIp` / `findSwitchByIpNoLock` 要不要另開一張？**（§6 的 🔴）
   它們一台壞 switch 會弄壞整張圖的 IP 查詢，比我修的這四個影響面更大，但不在
   status worker 路徑上，所以我照交辦單沒有碰。
