# A-4f — 電源循環會失去 bridge 的 sFlow 紀錄 → 該鏈路遙測永久歸零

派工：fix-design subagent，隔離 worktree
`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-aef4d43052f22d5e3`

---

## 1. Base verification

```
$ git checkout --detach 4cbec52d45bd85e0e972110e35f51693d6ce137f
HEAD is now at 4cbec52d Keep the one line that names the restore failure
$ git log --oneline -1
4cbec52d Keep the one line that names the restore failure          ✅ 完全相符
$ sed -n '335p' doc/KNOWN-ISSUES.md
### A-4f 🔴 電源循環會失去 bridge 的 sFlow 紀錄 → 該鏈路遙測永久歸零   ✅ 完全相符
```

底稿正確，開始讀碼。（以下所有 file:line 都相對於 `4cbec52d`。）

---

## 2. 機制（file:line）

*(填寫中)*

### 2.0 這條是哪個環境的？—— OVS-only，而 P4 早就修好了同一件事

KNOWN-ISSUES 標「平面：OVS」，讀碼證實，而且證據比標籤強：**P4 平面有等價的修法，OVS 沒有。**

| | 遙測管線由誰組態 | 電源循環會不會失去 | power-on 有沒有復原 | 有沒有斷言 |
|---|---|---|---|---|
| **OVS** | `testbed_topo.py:105-141` 的 `ovs-vsctl … set bridge sX sflow=@sflow` | 🔴 **會**（`del-br` 連 bridge 一起刪） | 🔴 **沒有** | 🔴 沒有 |
| **P4** | proxy 的 clone session（`p4_client.py:306` `write_clone_session`） | 會（bmv2 重啟後 PRE 全空） | ✅ 有（`/p4/readopt/{dpid}`） | ✅ 有（`curl --fail-with-body` 檢查 rc） |

`P4PowerStrategy.cpp:104-108` 的註解**逐字寫著這件事**：

> "A restarted bmv2 comes back with no pipeline, no clone session, no table entries …
> Without this step the twin would certify Up a switch that cannot forward one packet."

⇒ **A-4f 的修法不是新發明，是把 P4 那半邊已經做過的事補到 OVS 這半邊。**
差別只有一個、而且很關鍵：P4 掉的是 clone session ⇒ **交換機不能轉發**（大聲）；
OVS 掉的是 sFlow ⇒ **交換機照常轉發、只是量不到**（安靜）。後者才是本條標「靜默」的原因。

### 2.1 組態在哪裡建立（bring-up）

`testbed_topo.py:105-141` `enable_sflow()`：

```python
cmd = (f"ovs-vsctl -- --id=@sflow create sflow agent={agent_iface} "
       f'target=\\"{target}\\" header=128 sampling=256 polling=0 '
       f"-- set bridge {switch} sflow=@sflow")     # :137
os.system(cmd)                                      # :141
```

三個要點：

1. **sFlow 紀錄掛在 bridge 上**（`set bridge sX sflow=@sflow`）。OVSDB 的 `sFlow` 表不是 root
   table ⇒ 沒有 `Bridge` 指著它就被 GC 掉。**bridge 死，紀錄跟著死。**
2. **agent 是那台交換機的管理介面**（`find_ovs_agent_iface`，`:90-100` 回傳與 bridge 同名的
   internal port），而它的 IP 在 `:194` 才被指定：`sw.cmd(f"ifconfig {iface} {switch_ip}/24 up")`，
   `switch_ip = 192.168.123.{11+i}`。**這個 IP 就是 collector 用來認人的 `AgentKey.agentIP`。**
3. 🔴 `os.system(cmd)` **丟掉 rc**（`:141`）。這是
   [[injections-must-assert-their-own-success]] 第八式的形狀：組態失敗長得跟成功一樣。
   `:207` 的 `ovs-vsctl list sflow` 只是印出來給人看，**沒有任何檢查**。
   ⇒ **一座 fabric 可以從一開始就少一台交換機的 sFlow，而沒有任何東西會說。**

### 2.2 電源關閉刪掉它（file:line）

`src/ndt_core/power_management/OVSPowerStrategy.cpp:128-182` `powerOff()`：

```cpp
:157   const auto ports = executeListPorts(swName);       // 只存 port 清單
:166   topoMonitor->setMininetBridgePorts(node, *ports);
:169   run("sudo ifconfig " + port + " down");
:171   run("sudo ovs-vsctl del-br " + swName);            // 🔴 bridge 沒了
```

`del-br` 一次帶走三樣東西，而**只有第一樣被存起來**：

| 隨 bridge 消失的 | 有沒有被存 | 誰在管 |
|---|---|---|
| port 清單 | ✅ `:157-166` | 本條之外，已修 |
| **`sflow` 欄與它指向的 sFlow 紀錄** | 🔴 **沒有** | **本條 A-4f** |
| **與 bridge 同名的 internal port 上的管理 IP**（agent 位址） | 🔴 **沒有** | **本條的第二半，比 sFlow 紀錄本身更容易被漏掉** |
| port 上的 htb/qdisc shaping | 🔴 沒有 | §F F-7a（同族，已登記） |

### 2.3 電源開啟沒有補回來（file:line）

`OVSPowerStrategy.cpp:67-126` `powerOn()` 全部的動作只有四種：

```cpp
:101   run("sudo ovs-vsctl add-br " + swName + " && … other-config:datapath-id=…");
:108   run("sudo ovs-vsctl add-port " + swName + " " + port);
:110   run("sudo ifconfig " + port + " up");
:112   run("sudo ovs-vsctl set-controller " + swName + " tcp:127.0.0.1:6633");
:124   topoMonitor->setVertexUp(node);
```

**沒有 sflow、沒有管理 IP。** 新的 bridge 是一個沒有 sFlow 紀錄、
internal port 沒有位址的 bridge——`isUp=true`、edges 全 up、controller 接上了、**會轉發封包**，
只是**永遠不再送出任何 sFlow datagram**。

🔑 **就算只補 sFlow 紀錄也不夠**：`agent=s3` 而 `s3` 沒有 IPv4 位址時，
OVS 決定不出 agent 位址，datagram 不是送不出去就是帶著錯的來源位址 ⇒
`AgentKey.agentIP` 對不上 graph 裡的 `srcIp`/`dstIp` ⇒ 樣本進得來也歸不了戶。
**這正是 [[injections-must-assert-their-own-success]] 第九式**（執行了、成功了、打錯地方），
所以斷言必須驗「樣本回來了」，不能只驗「指令 rc=0」。

### 2.4 為什麼讀值「恰好 0」而不是「缺值」

樣本 → 邊 的路徑（三步）：

```
FlowLinkUsageCollector.cpp:1444-1447   m_counterReports[(agentIp, ingressPort)] += frameLength * samplingRate;
FlowLinkUsageCollector.cpp:1967-1997   每秒 drain：讀出累積量、換算 bps、寫回 graph、歸零
TopologyAndFlowMonitor.cpp:1166-1191   leftIn = cap - bps;  usage = cap - leftIn;  util = (1 - leftIn/cap)*100
```

de-sample 之後 `m_counterReports` 那個 key **不會消失**（`purgeIdleFlows` 只清 flow，
沒有任何地方 erase `m_counterReports`），於是每一秒：

```
accumulatedBytes = 0  →  estimatedIn = 0  →  leftIn = linkBandwidth
                      →  linkBandwidthUsage = 0        (TopologyAndFlowMonitor.cpp:1189)
                      →  linkBandwidthUtilization = 0  (TopologyAndFlowMonitor.cpp:1188)
```

**恰好 0，每秒重新寫一次。** 若 kernel 在電源循環後才啟動，那個 key 根本沒被建立過，
邊就停在 `EdgeProperties` 的初值 `linkBandwidthUsage = 0`、`linkBandwidthUtilization = 0`
（`GraphTypes.hpp:372-373`）——**兩條路徑給出位元相同的 0。**

### 2.5 KNOWN-ISSUES 的「⚠️ 機制比預測的窄：進來的邊變暗」——對帳結果：原文正確，機制在這裡

`m_counterReports` 的 key 是 **(取樣交換機的 agent IP, 該交換機的 ingress port)**，
而 `TopologyAndFlowMonitor.cpp:1571-1588` `getAgentKeyFromTheOtherSide()` 用
`props.dstIp.front() == agentIp && props.dstInterface == port` 找邊——**dst 側**。

⇒ 一個 agent 服務的是**以它為終點的那些邊**。失去 sFlow 的交換機讓
**指向它的邊**變暗，出去的邊由對面那台交換機的 agent 供給、不受影響。
**原文的觀測（s3→s8 讀 0）與這個機制一致：暗掉的是 s8 的 ingress。**

### 2.6 第二半的缺陷：「沒有人會注意到」

`src/ndt_core/http/HttpSession.cpp:544-574` `handleGetGraphData()` 對每條邊只吐這些：

```cpp
{"link_bandwidth_usage_bps",         e.linkBandwidthUsage},
{"link_bandwidth_utilization_percent", e.linkBandwidthUtilization},
```

**沒有任何時間戳、沒有樣本計數、沒有「這個 0 是量到的還是沒量到」的欄位。**
`EdgeProperties`（`GraphTypes.hpp:361-388`）整個結構裡沒有 last-update 時間。

⇒ 三種完全不同的世界在 API 上**位元相同**：

| 真實情況 | `link_bandwidth_usage_bps` | 可分辨嗎 |
|---|---|---|
| 鏈路真的閒置 | 0 | — |
| 鏈路承載 103 Mbps，但取樣器沒了 | **0** | 🔴 **不行** |
| kernel 剛啟動、還沒收到任何樣本 | **0** | 🔴 **不行** |

而下游 `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2829-2889`）的
`if (g[e].linkBandwidthUsage != 0 …)` **把 0 的邊整條跳過**——不是算成 0，是**不進分母**。
所以一條變暗的邊不只自己讀 0，還把平均值往「其他還活著的邊」那邊拉。
Energy-App 走的是 A-4b 那條（自己從 graph 算 `group_avg_link_utilization`），
同樣吃到這些 0 ⇒ **循環過的交換機讓自己更容易再被關掉**（原文的結論，機制成立）。

🔑 **關於 polling=0 的誠實但書（這條限制了任何修法能做到多好）**：
`testbed_topo.py:118-120` 明講 `polling=0` 停掉 counter sample，且**這是對的**
（MININET 模式下 kernel 會丟掉 counter sample，`FlowLinkUsageCollector.cpp` 的
`m_mode == utils::MININET` early continue）。
⇒ **一條真的閒置的鏈路，在 sFlow 線路上「什麼都不送」；一條失去取樣器的鏈路也是。
單看那一條鏈路，兩者在物理上不可分辨。** 可分辨的訊號只有一個層級以上：
**同一台 agent 的其他 port 有沒有在送樣本**。修法必須建立在這一點上，不能假裝更多。

---

## 3. 修法設計（兩層，兩層都要）

### 3.1 層 (a)：power-on 復原 sFlow，並且**驗到樣本回來為止**

**形狀：對稱地存＋還原，就像 port 清單那樣；然後讀回來斷言。**

`powerOff` 在 `del-br` **之前**把三樣東西讀進 vertex：sFlow 紀錄的欄位、agent 介面名、
agent 介面上的 IPv4/CIDR。`powerOn` 在 port 都接回來之後，先還原 agent 位址、再重建
sFlow 紀錄、最後**用同一個 seam 讀回來**確認 bridge 的 `sflow` 欄非空。

新增一個 shell seam（與既有的 `executeListPorts` 同形，同一個 mock 點）：

```cpp
// include/ndt_core/power_management/OVSPowerStrategy.hpp
virtual std::optional<SflowBridgeState> executeReadSflowState(const std::string& br);
```

`std::nullopt` ＝ **查詢本身失敗**（跟 `executeListPorts` 完全相同的三態紀律：
不可以把「問不到」壓成「沒有」）。回傳值裡 `configured == false` ＝ **這個 bridge 本來就沒有 sFlow**
（TESTBED、或刻意不取樣的 bridge），此時 `powerOn` **不准無中生有**。

#### 為什麼 `powerOff` 讀不到時**不**拒絕關機（與 `executeListPorts` 的做法不同）

`executeListPorts` 失敗會拒絕關機，理由是「刪掉 bridge 就永久失去唯一的 port 紀錄」——
那是**資料平面**的永久損失。sFlow 讀不到只是**量測**的損失，而且
`sudo -n` 的授權是 **argv-pattern 級的**（[[injections-must-assert-their-own-success]] 第四式）：
`list-ports` 在 sudoers 裡，`get bridge … sflow` / `list sflow` 是**新的 argv 形狀，很可能不在**。
若照抄「讀不到就拒絕」，這個修法會在部署當天**把 power-off 整個弄壞**，
把一個安靜的量測缺陷換成一個大聲的電源管理故障——換錯方向。

⇒ **採用：關機照做，但把「不知道」記成一個一等狀態**，power-on 據此大聲失敗。
（嚴格版列在 §7 給 Adam 裁。）

#### 為什麼 power-on 失敗**仍然**要 `setVertexUp`

沒有 sFlow 的交換機**真的在轉發封包**。標成 down 是往另一個方向說謊，而且 1 Hz 的
liveness 探針一秒內就會把它改回 up（跟 P4 那條一樣）。
⇒ vertex 標 up（真話）＋ `OpResult::failure` 命名遙測損失（大聲）＋
graph 上留下可查詢的事實（持久）。三者缺一不可。
`IPowerStrategy::powerOn` 的介面註解只寫了兩種結果，本修法補上第三種。

#### 🔴 而這會引進 P4 那條記錄在案的陷阱，所以早退守衛必須一起改

`powerOn:73` 的 `if (topoMonitor->getVertexIsUp(node)) return success;` —— 若我標 up 又回失敗，
**重試 power-on 會命中這個早退、回報成功、而完全沒有重試 sFlow 還原**。
這正是 `P4PowerStrategy.cpp:100-114` 花了 15 行記錄的那個形狀。
⇒ 守衛改成問**兩個**問題：機器是不是 up，**而且遙測是不是也在**。
「up 但已知沒有 sFlow」不早退，會重跑還原。

### 3.2 層 (b)：讓「有流量卻沒有樣本」看得見

**判準（三值，外加一個 unknown），建立在 §2.6 那條物理限制上：**

| 狀態 | 條件 | 意義 |
|---|---|---|
| `live` | 這條 (agent, port) 在視窗內有樣本 | 讀值是量到的 |
| `idle` | 這條沒有，但**同一台 agent 的其他 port 有** | agent 活著 ⇒ **0 是一個量測** |
| `silent` | 同一台 agent **任何 port 都沒有**，而交換機 `isUp` | 🔴 **0 不是量測，是缺席** |
| `unknown` | 這台 agent 從未送過樣本 | 分不出「剛開機」與「從沒設定過」 |

**API 同時吐標籤與原始年齡**，不是只吐標籤：

```json
"telemetry_status": "silent",
"last_sample_age_seconds": -1.0,
"agent_last_sample_age_seconds": -1.0
```

理由是這個 codebase 自己的既有原則——`FlowLinkUsageCollector.cpp:2010-2019` 的
rate-divisor gate 逐字寫著：**「a boolean computed in here would be the code grading its own
homework, and a reader could not tell a passing check from a check that never ran」**。
標籤是判決，年齡是證據；只給判決的話，讀的人無法自己重算。（`-1` ＝ 從未。）

**已知的偽陽性，明講**：一台**整台**都閒置的交換機會被標成 `silent`。
這是**悲觀**方向的失效——依 KNOWN-ISSUES 文首的失效方向軸，這遠比目前的**靜默**安全，
而且可以靠年齡欄位當場人工推翻。**不假裝這個修法能分辨那一種情況。**

### 3.3 兩層的關係：層 (b) 就是層 (a) 的「注入斷言」

[[injections-must-assert-their-own-success]] 的要求是**注入要斷言自己成功**，而第九式警告
「執行了、成功了、打錯地方」。層 (a) 的 read-back 只能斷言**結構**（bridge 的 `sflow` 欄非空、
agent 介面有位址）；它**無法**斷言「datagram 真的回來了」，因為那要等一個取樣視窗。
⇒ **層 (b) 是行為斷言**：還原後一個視窗內，那台 agent 若仍 `silent`，
API 自己會說出來。**兩層合起來才構成一個會自己喊錯的修法。**
而層 (b) 也涵蓋層 (a) 管不到的來源：手動重建的 fabric、
`testbed_topo.py:141` 那個丟掉 rc 的 `os.system` 從一開始就漏掉的交換機。

### 3.4 被否決的替代方案

| 方案 | 否決理由 |
|---|---|
| 把 `testbed_topo.py` 的 sFlow 參數硬編進 kernel，power-on 時重放 | 組態出現在第二個地方、保證漂移；且 agent 介面與 IP 是**每台不同**的 |
| **改 `testbed_topo.py` 的 `enable_sflow` 去驗 rc** | 🔴 **改到的不是跑的那份**——記憶 [[injections-must-assert-their-own-success]] 第六式：`ndtwin-lab` 起 OVS 拓樸跑的是 `~/Network-Traffic-Generator/testbed_topo.py`，repo 這份**內容不同且不會被執行**。仍**必須回報**（§6），但不能當成修法 |
| `powerOff` 讀不到 sFlow 就拒絕關機 | 見 §3.1：sudoers 是 argv-pattern 級的，很可能把 power-off 弄壞 |
| power-on 失敗就不標 vertex up | 說謊：交換機真的在轉發；而且探針一秒內覆蓋掉 |
| 只加 `telemetry_status`，不加年齡欄位 | 「code grading its own homework」，見 §3.2 |
| 只加年齡欄位，不加狀態 | 每個 consumer 各自訂閾值 ⇒ 七個 repo 七套判準 |
| 在 `EdgeProperties` 上再存一份 `lastSampleAt` | 重複狀態：collector 已經知道，`handleGetGraphData` 手上就有 collector |
| 用 counter sample（`polling`）來偵測沉默 | `testbed_topo.py:118-120` 明講 MININET 下 kernel 丟掉 counter sample，開了只是多送 datagram |

### 3.5 受影響的呼叫端

- `DeviceConfigurationAndPowerManager.cpp:1474`（唯一的 `powerOn` 呼叫端）——
  `result.ok == false` 會讓 `setPowerStateMininet` 回 false 並 WARN。**行為改變**：
  以前 sFlow 掉了也回 true。⚠️ 但實務上 Energy-App **丟掉這個回傳值**
  （`2026-09-01_esa-power-off-injection/FINDINGS.md:171,174`）⇒ **持久的訊號是 graph 欄位，不是狀態碼。**
- `HttpSession.cpp:544-574` `handleGetGraphData`——每條邊多三個欄位。
  `/ndt/get_graph_data` 是**七個工具/app 共用的跨 repo 契約**（`spec.py:383`）。
  **只加不改**：既有欄位一個位元組都沒動 ⇒ 舊 consumer 不受影響。
- `tools/contract_test/spec.py` 的 `GRAPH_EDGE`——三個欄位放進 `optional=`，
  這樣**還沒帶此修的 kernel 也照樣通過結構檢查**，新的不變式再分開判。

---

## 4. Patch

分支 `fix/a-4f-sflow-lost-on-power-cycle`，從 `4cbec52d` 長出來。**沒有 push。**

```
$ git log --oneline -1
f0fb29e8 Restore the sFlow record a power cycle deletes, and say when a link goes quiet

$ git show --stat HEAD
 include/common_types/GraphTypes.hpp                |  71 +++++
 include/ndt_core/collection/FlowLinkUsageCollector.hpp |  55 ++++
 include/ndt_core/collection/TopologyAndFlowMonitor.hpp |   7 +
 include/ndt_core/power_management/IPowerStrategy.hpp   |  15 +
 include/ndt_core/power_management/OVSPowerStrategy.hpp |  58 ++++
 src/ndt_core/collection/FlowLinkUsageCollector.cpp |  79 ++++-
 src/ndt_core/collection/TopologyAndFlowMonitor.cpp |  18 ++
 src/ndt_core/http/HttpSession.cpp                  |  25 ++
 src/ndt_core/power_management/OVSPowerStrategy.cpp | 338 ++++++++++++++++++++-
 tests/python/test_contract_spec.py                 | 147 ++++++++-
 tests/test_OvsPowerStrategy.cpp                    | 321 +++++++++++++++++++
 tools/contract_test/spec.py                        |  95 +++++-
 12 files changed, 1218 insertions(+), 11 deletions(-)
```

**🔴 C++ 全部 NOT COMPILED**（量測窗開著，派工單禁止 build）。做過的靜態檢查只有：
逐檔括號／小括號平衡（12 檔全平衡）、seam 覆蓋比對、include 鏈確認。
**這不等於會編過。**

### 4.1 寫測試時發現的一個我自己引進的缺陷（重要，因為讀碼讀不出來）

第一版把早退守衛從「up 就返回」改成「up 且不欠 sFlow 才返回」，然後**直接往下走完整的開機流程**。
寫 `ARetriedPowerOnReAttemptsTheSflowRestore` 時才看出來：
**重試時 bridge 已經存在，`add-br` 會 exit 1** ⇒ `allOk=false` ⇒ **在 500 就返回，永遠走不到還原那段。**
＝ 我為了避開 P4 那個「重試碰到早退」的陷阱，換成了「重試碰到 add-br 撞牆」，
**而兩者的外觀一樣：重試沒有修好任何東西。**

修法：`alreadyUp` 時只跑 `finishTelemetryRestore`，不重跑開機。
🔑 **這個缺陷是被測試設計逼出來的，不是被讀碼看出來的**——
[[live-runs-find-what-tests-cannot]] 的鏡像面：**寫測試也會找到讀碼找不到的。**

---

## 5. 測試證據

### 5.1 Python：紅 → 綠 → 變異閘（全部實跑，rc 未經 pipe）

直譯器：系統 `python3`（`tests/python/` 依約只准標準庫；`p4_proxy/venv` 不適用於這個目錄）。

**RED**（加了測試、還沒動 `spec.py`）：
```
$ python3 -m unittest tests.python.test_contract_spec.SilentTelemetryTest -v > red1.txt 2>&1; echo "RC=$?"
RC=1
Ran 13 tests   FAILED (failures=1, errors=10)
```
10 個 error＝`spec.inv_no_silent_telemetry` 不存在；1 個 fail＝schema 還沒拒絕未定義的狀態字串。
（另外 2 個一開始就綠——`Obj` 預設非 strict，所以「多送欄位」本來就過。**照實記，不當成通過的證據。**）

**GREEN**（`spec.py` 改完）：
```
$ python3 -m unittest tests.python.test_contract_spec.SilentTelemetryTest -v; echo RC=$?
Ran 13 tests   OK        RC=0
$ python3 -m unittest tests.python.test_contract_spec; echo RC=$?
Ran 105 tests  OK        RC=0        ← 全檔無回歸
```

**變異閘**（字面字串替換＋斷言 anchor 恰好出現一次，[[injections-must-assert-their-own-success]] 第十一式）：

| 變異 | rc | 判定 |
|---|---|---|
| M1 停用「沒有欄位」那支 | 1 | RED（殺掉） |
| M2 讓 `silent` 永遠比不中 | 1 | RED（殺掉） |
| M3 停用「零條邊」那支 | 1 | RED（殺掉） |
| M4 整個不變式回 `[]` | 1 | RED（殺掉） |
| 還原後 | 0 | `Ran 105 tests OK` |

🔴 **M3 第一次跑活下來了**，這是本輪最有價值的一件事：
原本的測試只斷言「有回傳東西」，而空邊清單也會落進「沒有欄位」那支 ⇒
**兩個不同的情況回同一種訊息，刪掉其中一支測不出來。**
兩者對操作者的意義完全不同（拓樸沒載入 vs kernel 版本太舊），
指錯方向會把人送去找一個不存在的欄位。修法＝斷言**訊息內容**而不只是存在性，M3 隨即被殺。

**其餘 Python 測試**（`tests/python/` 全部 16 檔）：15 綠。
`test_sflow_stats_endpoint.py` rc=1，原因是系統 python3 沒有 `fastapi`（`ModuleNotFoundError`）——
**該檔我一個位元組都沒動，是既有的環境限制，不是本輪造成的回歸。**

### 5.2 C++：🔴 UNVERIFIED —— 從沒看過紅

`tests/test_OvsPowerStrategy.cpp` 新增 **11 個 TEST**，涵蓋：
del-br 之前讀（順序斷言）、讀不到記成 unknown 而非 absent、本來就沒有的不補、
還原 agent 位址＋sFlow 紀錄、`add-br` 早於 `create sflow`、
read-back 說沒接上就失敗、**接上了但 agent 沒位址也失敗**（第九式）、
read-back 讀不到也算失敗、unknown 時不無中生有、**重試會重跑還原且不重跑 add-br**、
已 up 且不欠時零指令。

**這 11 個沒有跑過，一次也沒有。** 依 CLAUDE.md「測試沒看過紅就不算交付」，
**這一半不算交付**，要等能 build 的 session 接手。已做的替代檢查（弱得多）：

- ✅ **seam 覆蓋**：`FakeOvs` 與 `RendezvousOvs` **都**覆寫了新的 `executeReadSflowState`。
  這一條不是形式——本檔頭自己記著 `add-br` 曾經繞過 fake、**真的對開發者的機器跑了
  `sudo ovs-vsctl`**，新開一個 shell seam 而不覆寫就是把那個洞原樣裝回去。
- ✅ 12 個檔的括號平衡。
- ❌ 沒有型別檢查、沒有連結、沒有執行。

---

## 6. 沒驗到的部分 ＋ 人要接手做什麼

### 6.1 會電源循環交換機的 round 腳本（它們繼承這個缺陷）

全 `doc/audit/` 掃過（`action=off`／`action=on`／`power_cycle`／`del-br`，含 `.sh` `.py` `.cpp`）。
**只有四個位置**，逐一分類：

| # | 檔案 | 做什麼 | 跑過沒 | 遙測欄可信度 |
|---|---|---|---|---|
| 1 | `doc/audit/2026-08-30_live-full-stack-round/harness/25_apps_energy.sh` | 啟動 Energy-App，讓它 POST `action=off` | ✅ 跑過兩次（P4 arm 08-30 15:30 關了 s9/s7/s5；**OVS arm 08-30 15:53 關了 0 台**） | ⚠️ **既有資料沒被污染**（OVS 那臂 0 台）。但**下一次 OVS arm 會被污染** |
| 2 | `doc/audit/2026-08-30_live-full-stack-round/harness/90_restore.sh` | `power-on` 模式逐台 POST `action=on` | ✅ 同一輪 | 🔴 **這支是最危險的**——見下 |
| 3 | `doc/audit/2026-08-28_chaos-harness/harness/actions.py` `_c01_apply`/`_c01_verify`/`_c01_undo` | off→on 循環，在 `--allow-poweroff` 後面 | 🔴 **從沒活跑過**（`05_first-live-run.md:341`「fixed, **never run**」） | 前瞻性繼承：**第一次跑就會踩到** |
| 4 | `doc/audit/2026-08-28_chaos-harness/harness/invariants.py:78-90` `inv01_powercycle_latency` | 看起來會循環，**其實不會** | — | ✅ **無影響**：它送 **GET** 且帶 `dpid=`，兩者都不成立（`actions.py:92-101` 自己記著：路由只收 POST、handler 讀 `ip`）⇒ 請求從沒到過電源碼 |

#### 🔴 為什麼 #2 最危險

`90_restore.sh` 的驗收條件是**節點與邊的計數**（`:203-211`：`N_UP`／`N_SW`／`N_ED` 回到基準就 `ok`）。
**A-4f 之下這些計數全部會回來**——bridge 重建了、port 接回去了、controller 連上了、
邊全部 up。**唯一沒回來的東西，剛好是這支腳本不看的那個。**

而且它**已經知道有東西回不來**（`:224` 對 F-7a／htb 印 `bad` 並要求改用 rebuild），
**但 sFlow 不在那段文字裡**。⇒ 一個讀那行警告的人會認為「已知的殘留只有 shaping」。
`README.md:81` 更把 `power-on` 寫成 **OVS 上的「便宜路線」**。

⇒ **建議（不是我能裁的）**：在 `90_restore.sh` 的 `:224` 那段 OVS 警告裡，
把 sFlow 與 F-7a 並列，並加一條真的檢查——
`sudo ovs-vsctl list sflow | grep -c '^_uuid'` 的循環前後比對。
**一行、不需要 kernel 改動、對舊 build 也有效。**（本輪沒做：改別人的 round 腳本不在派工範圍。）

#### 對帳：`ndt down && ndt up` 不受影響

完整重建會重跑 `testbed_topo.py`，sFlow 從頭設一次 ⇒ **rebuild 路線是乾淨的**。
被污染的只有「電源循環但不重建」。`2026-08-31_f5-fine-grid-round`、
`2026-08-31_sampling-ceiling-after-merge`、`2026-09-02_recompute-paired-ab` 掃過，**都不電源循環**。
（`cpu_gate.py` 出現在初掃結果裡，是因為它引用「power-on 那一輪」的教訓，不是因為它會關機。）

### 6.2 🔴 必須先查、否則這個修法會安靜地半殘

```bash
sudo -l | grep -i ovs-vsctl
```

`sudo -n` 的授權是 **argv-pattern 級的**（記憶第四式，被咬過一次）。
若 allowlist 只收 `list-ports`／`add-br`／`del-br` 這些既有形狀，
新的 `get bridge <br> sflow` 與 `get sflow <uuid> …` **會被拒**，
於是 `powerOff` 把每一台都記成 `unknown`，`powerOn` 每一次都回 502。
⇒ **修法會退化成「大聲回報損失」而不是「復原損失」**，而它仍然是進步（現在是安靜地損失），
**但那不是我宣稱的東西。這一條在活跑前查，不要在活跑後解釋。**

### 6.3 人要跑的活體測試（含對照組）

**前置**：claim lab；`ndt down && ndt up ovs4`（或 10 台 OVS 拓樸）；
**不要**用前一輪 power-on 過的 fabric 當起點（F-7a＋本條都會殘留）。

| 步驟 | 動作 | 斷言 |
|---|---|---|
| 0 | `sudo ovs-vsctl list sflow \| grep -c '^_uuid'` | 記下 `N0`（＝交換機數）。**這是本次量測的分母，先確認它非零**（第八式：先讓斷言對已知為真的情況成功一次） |
| 1 | 起流量：跨 fabric 的一對 host，經過 sX 的 ingress | `get_graph_data` 中**進入 sX 的邊** `link_bandwidth_usage_bps > 0` |
| 2 | **臂 A（處理）**：POST `set_switches_power_state?ip=<sX>&action=off`，等 5 s，再 `action=on` | — |
| 3 | 循環後 60 s | `list sflow` 計數；進入 sX 的邊的 usage；`telemetry_status` |
| 4 | **對照 1（陰性，同時窗）**：一台**沒被循環**、載著相當流量的 sY | 它的邊必須**保持非零**。若它也掉了，掉的不是 sFlow 而是流量或量測工具 |
| 5 | **對照 2（鑑別力）**：把 sY 的流量停掉，不動它的 sFlow | 必須讀 **`idle`**，不可以是 `silent`。**這一條證明新欄位真的在分辨，而不是對所有 0 都喊 silent** |
| 6 | **對照 3（歸因）**：不循環電源，直接 `sudo ovs-vsctl remove bridge sZ sflow <uuid>`；**先斷言 `list sflow` 少一筆** | sZ 的入邊必須讀 `silent`。證明偵測的是「沒有取樣器」這個條件，**不是「發生過電源循環」這個事件** |

**修法前的預測**（今天就可以先跑，當基準）：步驟 3 → `list sflow` 是 `N0-1`、
進入 sX 的邊讀**恰好 0**、沒有 `telemetry_status` 欄位。
**修法後的預測**：`list sflow` 回到 `N0`、邊在一個取樣視窗內回到非零、`telemetry_status = live`。

🔴 **步驟 6 的「先斷言注入生效」不可省**。`remove bridge … sflow` 打錯 uuid 會 rc=0 而什麼都沒做，
而下游「讀到 silent」與「本來就 silent」長得一模一樣。

### 6.4 本輪沒有做、也不該由我做的

- **`testbed_topo.py:141` 的 `os.system` 丟掉 rc**（§2.1 第 3 點）——**沒有修**。
  理由是記憶第六式：`ndtwin-lab` 起 OVS 拓樸跑的是
  `~/Network-Traffic-Generator/testbed_topo.py`，**repo 這份內容不同且不會被執行**。
  改它會產生一條完整的、每一步都是真的、但**打在旁邊那份上**的證據鏈。
  ⇒ **要修必須先確認改的是跑的那份**，那要碰 lab，本輪禁止。**登記給下一輪。**
- **§F 的 qdisc/htb 遺失（F-7a）** —— 同一個 `del-br`、同一個存還原窗口、同一支
  `powerOff`。本輪只做 sFlow。**兩件事分兩次做，等於讀兩次 bridge**，見 §7 Q3。
- 沒有跑任何 C++ 測試、沒有 build、沒有碰 fabric、沒有 claim、沒有 push。

---

## 7. 給 Adam 的裁決（選項＋後果）

**Q1｜`powerOff` 讀不到 sFlow 組態時要不要拒絕關機？**
- **A（本輪採用）**：照關，記成 `unknown`，`powerOn` 回 502 並在 log 大聲說。
  後果：sudoers 沒放行時**修法退化成回報而非復原**（§6.2），但 power-off 一定能用。
- B：比照 `executeListPorts` 拒絕關機。
  後果：遙測絕不會無聲損失；但 sudoers 少一條 argv 形狀就**把 Energy-App 的關機路徑整條弄壞**。
- C：先把 §6.2 那條 `sudo -l` 查清楚再裁。**我建議先做 C，再在 A/B 之間選。**

**Q2｜`silent` 的判定視窗預設 5 秒，而整台閒置的交換機會被誤判成 `silent`。**
- **A（本輪採用）**：接受這個偽陽性，寫進註解，並同時吐出原始年齡讓人當場推翻。
  後果：安靜的示範網路上會出現看起來嚇人的 `silent`。
- B：交換機的 `flowSet` 全空時抑制 `silent`。
  後果：**真的失去取樣器的交換機 flowSet 也會空** ⇒ 抑制掉的正好是要抓的那個。**我不建議。**
- C：視窗改成可設定（環境變數／設定檔）。後果：多一個沒人會調的旋鈕。

**Q3｜要不要把 F-7a（qdisc）併進同一個存／還原機制？**
- A：併。後果：一次讀 bridge、一次還原、一個 read-back；**diff 變大**，而 F-7a 沒被派工。
- **B（本輪採用）**：不併。後果：下一輪要再開一次同一個窗口、再寫一次同型的碼，
  且中間這段時間 `90_restore.sh` 的警告仍然只講對一半。

**Q4｜`telemetry_status` 是 `/ndt/` 上的新欄位，七個 consumer 共用這個契約。**
- **A（本輪採用）**：只加不改，舊 consumer 零改動；contract spec 放進 `optional=`。
- B：另開端點。後果：多一次往返，而且 graph 與狀態可能取自不同時刻。

**Q5｜power-on 復原了交換機但沒復原遙測，HTTP 該回什麼？**
- **A（本輪採用）**：502＋vertex 標 up。後果：**與 `IPowerStrategy` 原本的介面註解相牴觸**
  （我改了註解、明講第三種結果）。且 Energy-App **丟掉回傳值**，所以狀態碼實際上沒人看，
  **真正的訊號是 graph 欄位**。
- B：回 200，只寫 log。後果：更像「成功」，而這條缺陷的本質就是太像成功。

---

## 附：口徑對帳

| 宣稱 | 證據等級 |
|---|---|
| sFlow 掛 bridge、`del-br` 帶走它 | **讀碼**（`OVSPowerStrategy.cpp:171`＋`testbed_topo.py:137`）＋ OVSDB root-table 語意 |
| `powerOn` 不重建 sFlow | **讀碼**，`OVSPowerStrategy.cpp:97-112` 全部四種指令列完 |
| 管理 IP 也隨 bridge 消失 | **讀碼**（`testbed_topo.py:194` 設在 internal port 上；`list-ports` 不含同名 internal port）。⚠️ **沒有活體驗證** |
| 暗掉的是「進來的邊」 | **讀碼**（`getAgentKeyFromTheOtherSide` 比對 `dstIp`/`dstInterface`），與 KNOWN-ISSUES 的實測一致 |
| 讀值恰好 0、與閒置不可分辨 | **讀碼**（drain→`updateLinkInfoLeftLinkBandwidth`→`EdgeProperties` 初值）＋ KNOWN-ISSUES 的 round 6 實測 |
| P4 平面已有等價修法 | **讀碼**（`P4PowerStrategy.cpp:104-121`、`api_routes.py:298-329`、`p4_client.py:239`） |
| Python 不變式紅→綠→四個變異全殺 | **實跑**，rc 未經 pipe |
| C++ 修法正確 | 🔴 **無證據**：NOT COMPILED、NOT RUN |

---

## 附二：一則疑似送錯的協調訊息（沒有照做）

工作進行中收到一則協調者訊息，開頭是「**Addendum to your A-9 assignment**」，
要我處理 `KNOWN-ISSUES.md:505` 的 **B-2 case ②**（LockManager），
並把結果寫進**同一個 scratchpad 底下的 `A-9.md`**。

**我沒有照做**，理由兩條：

1. 我的派工是 **A-4f**，從頭到尾沒有 A-9；那則訊息稱它為「你的 A-9 派工」，
   指的是一份我沒收到過的派工單。
2. `A-9.md` 是**另一個 agent 的 findings 檔**。往裡面寫等於覆蓋同儕正在寫的東西，
   而 LockManager 與本條沒有任何共用檔案。

⇒ 照原派工把 A-4f 做完，並在回報裡向上呈報這件事。**若 B-2 ② 確實要我做，需要一份新的派工單。**

---

## 8. 追加交付：C++ 變異閘腳本（協調者要求）

`tests/shell/mutate_a4f_sflow_power_cycle.sh`，commit `e9993f9f`。**沒有 push。**

### 8.1 為了讓閘門有意義而必須先做的重構

`telemetryStatusFor` 原本把「取兩個時間戳」與「四選一的判定」綁在一起。
判定那半才是本功能全部的主張，而它被綁在需要 collector＋monitor＋deviceManager＋classifier
＋真實時間流逝才能到達的位置 ⇒ **實務上不會有測試碰到它**，
「`telemetry_status` 永遠回 live」那個變異會**毫無對手地存活**。

⇒ 抽出純靜態 `classifyTelemetry(now, portAt, agentAt, window)`，
`test_SFlowParsing.cpp` 新增 8 個 `TelemetrySilenceTest`。
其中**承重的是這一對**：
`AnAgentStillReportingElsewhereMakesThisLinksZeroAMeasurement`（idle）
與 `AnAgentReportingNowhereMakesThisLinksZeroAnAbsence`（silent）——
**該 port 的沉默完全相同，判定相反**，差別只在 agent。
分不出這一對就是沒有實作這個功能。

### 8.2 五個變異＋一個對照

| # | 變異 | 必須變紅的測試 |
|---|---|---|
| 1 | `powerOff` 不存 sFlow 紀錄（照樣讀，讀完丟掉） | `PowerOffReadsTheSflowRecordBeforeItDeletesTheBridge`、`PowerOffRecordsAnUnreadableSflowAsUnknownRatherThanAsAbsent` |
| 2 | `powerOn` 重放但不 read-back（每條指令照跑、照回 0） | `PowerOnReportsFailureWhenTheSflowRecordDoesNotComeBack` |
| 3 | read-back 接受沒有位址的 agent 介面 | `PowerOnReportsFailureWhenTheAgentInterfaceHasNoAddress` |
| 4 | 重試又掉進 `add-br`（§4.1 我自己那個回歸） | `ARetriedPowerOnReAttemptsTheSflowRestore` |
| 5 | `telemetry_status` 永遠 `live` | `AnAgentReportingNowhereMakesThisLinksZeroAnAbsence`、`AnAgentThatHasNeverReportedIsUnknownRatherThanSilent` |
| 對照 | 只改一行註解 | **必須維持全綠**；變紅 ⇒ 上面每一個 caught 都不算數 |

### 8.3 三件跑了才發現的事（讀碼都讀不出來）

1. 🔴 **`apply` 的離開狀態沒有被消費。** 它在頂層被呼叫、沒有 `set -e`，
   於是 python 以 3 離開之後**照樣往下跑**，`report` 去 build 並評分**未被變異的 binary**——
   當然全綠。**而檔頭那時已經寫著「Both abort the run rather than being skipped」。**
   ＝ 一個會說謊的註解配一個不存在的保護。
2. 🔴 **第一個陰性對照的注入沒有落地。** 我把複製的那行前面加了 `// `，
   **縮排就變了**，於是那份副本**不包含**被搜尋的字面 ⇒ 錨點仍然唯一 ⇒ 跑出 rc=0。
   是注入後的 `count == 2` 斷言抓到的。
3. 🔴 **第二次瞄錯錨點。** 我拿 M3 去做對照，但 M3 的錨點是**多行區塊**，
   只複製它的第一行 ⇒ 真正的錨點還是唯一。**注入執行了、成功了、改的是檢查器不讀的地方**
   ＝ [[injections-must-assert-their-own-success]] **第九式**，我在寫防第九式的腳本時犯第九式。

⇒ 改用單行錨點（M1）重跑，**rc=1、印出 SURVIVED 行、其餘四個錨點仍照跑、檔案位元還原**。

### 8.4 協調者後續兩點要求的對帳

| 要求 | 修改前 | 現在 |
|---|---|---|
| (1) restore 後 mtime 必須新於變異物件；最後重建一次 | ✅ 本來就用裸 `cp`（非 `cp -p`／`-a`）且最後有重建 | 加了明確的 `touch` 與「不要改成 `cp -p`」的理由註解。**實測**：restore 後的 mtime 比替身物件新 0.187 s ⇒ ninja 會重建 |
| (2) 編不過／錨點失配都算 SURVIVOR，不是警告 | 🔴 **不合規**：編不過進 `BROKEN` 另一欄；錨點失配直接 `exit 3` 中止全部 | 兩者都計入 `SURVIVORS`（附原因），錨點失配**不再中止**，其餘變異照跑。理由：批次執行時中止會丟掉後面所有結果，而「沒跑到」與「跑了沒抓到」對報告而言是同一件事 |

（(2) 的 `exit 3` 已從契約移除；現在只有 0／1／2。）

### 8.5 已實跑 vs 仍未跑

**已實跑**（rc 未經 pipe）：
- `bash -n` rc=0
- `ANCHOR_CHECK=1` 走完全部：**6 個錨點各 1 次**（`grep -c` 亦逐一確認為 1），檔案位元還原
- 陰性對照：故意讓錨點出現 2 次 ⇒ rc=1＋SURVIVED 行＋還原（**斷言看過紅**）
- mtime 對照：restore 後來源比替身物件新 ⇒ ninja 會重建

🔴 **仍未跑**：`ninja`、gtest binary、五個變異是否真的能編、11+8 個 C++ 測試是否真的變紅。
**閘門本身也還沒被閘過。** 這些全部要等編譯窗。
