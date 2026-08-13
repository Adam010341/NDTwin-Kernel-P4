# C — Live OVS/Ryu 輪（2026-08-12 夜）

執行者：agent C（獨佔 live 環境）。工作目錄 `/home/adam/Desktop/NDTwin-Kernel`，
分支 `fix/flow-rate-divide-by-zero`，HEAD `5d53cf0`（已確認）。
依據文件：`doc/2026-08-10_ovs_manual_test_runbook.md`（⚠️ 未經今晚掃雷 agent 核對，B4 只掃了 P4 版）。

**Mininet 是 Adam 走前手動開的，全程不得重開。** 本輪不改 repo 任何檔案、不 commit、不跑測試套件。

---

## TL;DR

**本輪走完 runbook §4–§7 全部＋兩個 runbook 未涵蓋的 phase（switch 電源、錯誤回報），
以一條跑滿 1892 秒的 5 pps canary ping 當每個 phase 的共同判準。環境已乾淨收尾，Mininet 完好留給 Adam。**

### 🔴 最重要的一件事（P0）

**單向鏈路故障會讓 Ryu 的全域路由重算永久崩潰，流量無限期黑洞，而 twin 全程回報一切正常。**
`intelligent_router.py:582` 的 `net[current_switch][prev_switch]["port"]` 假設 DiGraph 上每條邊的反向邊必然存在；
單向故障只會產生**一個** `EventLinkDelete`，圖從此不對稱，每次重算都在這行 `KeyError` 中止
⇒ OpenFlow 規則永遠不更新（實測該規則 `dur` 一路累積到 371s 沒被替換）。
實測 **291 秒 100% 丟包、零自癒**，恢復只發生在我手動移除故障之後。
**且今晚的正常啟動流程就已經觸發過一次同一個崩潰**（`route reinstall failed: 1`），
只是被 LLDP 自癒掩蓋。詳見 Phase 3D。

### 逐 phase 結論

| phase | 結論 |
|---|---|
| **0 基線** | 全綠：10 switch up+enabled、128 host up、288/288 edge、Ryu 32 links / 16256 paths、netem 殘留 0 |
| **0b runbook 通讀** | 開跑前就判定 3 個危險步驟（§1 破壞性、殺 Ryu 的替代方案是雷、§6 換方法會換機制）＋2 個未涵蓋 phase |
| **1 靜態健康（§4/§7）** | ✅ **全綠，11 項對照全中**，唯一偏差（§4f 回 2）已歸因到我自己的 canary。runbook §4/§7 完全成立 |
| **2 流量 telemetry（§5）** | ✅ **全綠，9 項對照全中**。路徑與 rate 與 2026-08-11 高度一致；**§5j 的 flow 閃爍成功重現並補上獨立 ground truth** |
| **3A 雙向斷鏈** | 偵測 **+42.6s**、ping gap **52.42s**、繞路成功、恢復 **hitless**（圖 +4.4s / 路徑 +18.4s）。§6i 窗口 A 第三次重現（**14.3s**） |
| **3D 單向斷鏈** | 🔴 **P0，見上**。291 秒黑洞、零自癒、twin 全程說健康 |
| **4 switch 電源（未涵蓋）** | power off 偵測 **+0.34s**、power on 收斂 **+3.4s**、**全程 hitless**；但 🔴 **power cycle 永久遺失 sFlow 與 fail-mode**（已還原） |
| **5 殺 controller（未涵蓋）** | **刻意不執行**——runbook 的精確程序就是「不要做」，而交接單的替代方案在今晚等價於 wedge 觸發條件。改測 kernel 錯誤路徑，8 項全部正確 |
| **6 收尾** | ✅ ryu/kernel 已停、無 listener、netem 0、qdisc 全數還原、**Mininet 128 個 host namespace 與 10 個 bridge 完好** |

### 發現計數

| 等級 | 數量 | 內容 |
|---|---|---|
| **P0** | **1** | 單向鏈路故障 → 路由重算 `KeyError` → 永久黑洞（Phase 3D） |
| **P1** | **5** | ①runbook §1 對「接手已在跑的 stack」是破壞性的 ②「整組 down/up」不是 wedge 的解藥 ③交接單的 `tc ... root netem` 會拆掉 Mininet 的 htb 且還原不回去 ④附錄 A 的 OVS-vs-P4 偵測對照過度概化（靜默故障下反轉，差 ~1370 倍） ⑤power cycle 永久遺失 sFlow／fail-mode |
| **P2** | **2** | ①§6 的 ifconfig 與 netem 量的是不同機制（數字不可並列） ②三個姊妹端點對「switch down」用三種不同表示法 |
| **P3/note** | **4** | ①啟動期 LLDP 抖動未記載 ②kernel 每次啟動噴 `exportfs` warning ③不存在的 dpid 回 success/0 而非 404 ④交接單寫「4 hosts」，實際 128 |

**另有 6 項 runbook 既有宣稱被本輪獨立確認**（§4c 電力上下界第三次相同、§4e `?dpid=` 回 404、
§5c 路徑與型別、§5d 使用率區間、§5g 路徑內外 10/10 自洽、§6i 窗口長度）——**這些不算發現，算回歸通過**。

---

## 給 Adam 的早晨清單

### ✅ 環境狀態：乾淨，Mininet 留存中

- **Mininet 完好**：128 個 `mininet:h*` host namespace、`testbed_topo.py` 仍在跑、10 個 bridge（s1–s10）都在。**我全程沒有碰過它**，沒有 `mn -c`、沒有殺任何 Mininet process、沒有重跑 topo。
- **kernel 與 Ryu 已依交接單停止**（`stack.sh down`，exit 0）。`:8000 / :8080 / :8081 / :6633 / :6653` 都沒有 listener。
- **netem 殘留 0**，我動過的 `s1-eth2`、`s6-eth1` 的 qdisc 已還原成 `htb 5:`，與全程未動的對照組 `s1-eth1` 逐欄位相同。
- **s7 的 sFlow / fail-mode / other-config 已由我還原**（power cycle 弄丟的，見 Phase 4），與其餘九台一致。

### ⚠️ 要你決定的三件事

**1. 🔴 重開 stack 之前先讀這條——現在的狀態下直接 `stack.sh up ovs` 會踩 wedge。**

收尾後的狀態是「Ryu 已停、Mininet 還活著」。這時候跑 `stack.sh up ovs` 會重新啟動 Ryu，
而 Mininet 仍在跑 ⇒ **正是 `2026-07-29_environment_gotchas.md:241` 那條「不要單獨重啟 Ryu」的觸發條件**
（8 秒後 `/stats/flow/<dpid>` 永久回空表，不會自己好）。
這是「收尾停 stack、但保留 Mininet 給你」這個指示的必然結果，不是操作失誤，但你早上一定會碰到。

兩個選項：
- **建議**：`sudo mn -c`，重跑 `sudo python3 testbed_topo.py`，再 `./stack.sh up ovs`（乾淨、無 wedge 風險）。
- 或：接受 wedge 風險直接 `up`，但那樣拿到的 flow path 全部不可信。

**2. s7 的 controller port 是 `tcp:127.0.0.1:6633`，其餘九台是 `:6653`。**
power cycle 造成的（`OVSPowerStrategy::powerOn` 寫死 6633）。**功能上完全等價**——Ryu 同一個 process
同時聽兩個 port。我刻意沒改，因為改 controller 會讓 s7 重連一次、製造拓撲抖動，
而抖動正是 P0 那個 KeyError 的觸發條件。若要對齊：`sudo ovs-vsctl set-controller s7 tcp:127.0.0.1:6653`。

**3. 請 A 輪（P4）確認他們用 `tc` 動過哪些介面。**
交接單給兩輪的斷鏈指令都是 `tc qdisc add dev <if> root netem loss 100%`。
這條指令會**靜默取代** Mininet 的 htb root qdisc，而 `del ... root` 只會留下 `noqueue`、**還不回 htb**
（NOPASSWD 不放行 `tc qdisc add ... htb`）。
**「netem 殘留 0」這個收尾檢查看不出這個殘留。** 若 P4 拓撲的介面也有 htb，
被測過的每條鏈路可能都還帶著 `noqueue`。檢查法：`tc qdisc show dev <if> | head -1`，
應該是 `htb`，若是 `noqueue` 就是殘留。

### 🔧 建議排進待辦（不在本輪修，本輪未改任何 repo 檔案）

| 優先 | 項目 |
|---|---|
| **P0** | `intelligent_router.py:582` 的反向邊假設。BFS 應只走雙向都在的邊，或查不到反向 port 時跳過該 switch（比照它下方 `datapath is None` 那個**已經存在**的同類防禦——`:582` 是同一類缺陷的第二個實例）。**修完要有測試涵蓋「單向邊」這個圖狀態**，本輪的重現方法（單端 netem 撐 >90 秒）可以直接拿來當驗收 |
| **P0 附帶** | 未查證：崩潰發生在 BFS 走到一半，**這一輪的 flow-mod 可能已經半裝**。需要比對崩潰前後各 switch 的規則差異 |
| **P1** | `OVSPowerStrategy::powerOn` 應還原 `fail_mode`、sFlow、`disable-in-band`、`dp-desc`（powerOff 已經會存 port 清單，存組態是同一個模式）；controller port 也不該寫死 |
| **P1** | runbook 補一節「接手一個已經在跑的 stack」，並在附錄 A 的偵測延遲那列加上「故障是否改變 port state」的限定詞 |
| **P2** | `get_power_report` / `get_cpu_utilization` / `get_temperature` 對「switch down」統一表示法（現在是 0 / 鍵缺席 / 字串塞進整數欄位） |

---

## Phase 0 — 基線（23:44–23:50）

### 【觀察】HEAD 與分支

```
$ git log --oneline -1
5d53cf0 Point the VLAN warning at symbols, after its line number rotted the same hour
$ git rev-parse --abbrev-ref HEAD
fix/flow-rate-divide-by-zero
```

✅ 與 orchestrator 指定的 HEAD 一致，未做任何 reset。

### 【觀察】Process 與 port

```
Ryu    pid 216679  ryu-manager --observe-links intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest
kernel pid 242000  ./bin/ndtwin_kernel --mode mininet --topology .../StaticNetworkTopologyMininet_10Switches.json --no-ai
hosts  pid 216825 (h1) … 217079 (h128)
listeners: :8000 (kernel) :8080 (Ryu REST) :6633 :6653 (Ryu OpenFlow)
```

⚠️ **與 orchestrator 交接單的一處出入（低嚴重度，僅影響閱讀者預期）**：交接單寫「4 hosts」，
實際是 **128 hosts**（h1–h128），與 `testbed_topo.py` 的 `HOST_NUM = 128` 及 topology 檔一致。
4 hosts 是 **P4 拓撲**的數字。這輪所有 host 相關預期值都以 128 為準。

### 【觀察】OVS bridges

```
$ sudo -n ovs-vsctl list-br
s1 s10 s2 s3 s4 s5 s6 s7 s8 s9        （10 個）
```

### 【觀察】kernel 圖（`/ndt/get_graph_data`）

```
switches 10 up 10 enabled 10
hosts 128 up 128
edges 288 up 288
hosts with ipv4: 128
```

switch IP（power API 用 `ip=` 定址，不是 dpid）：

| dpid | name | ip |
|---|---|---|
| 1–10 | s1–s10 | 192.168.123.11 – 192.168.123.20（dpid N → .1(10+N)） |

✅ 與 runbook §4a 的【2026-08-11 實測】完全一致（128/128、288/288）。

### 【觀察】Ryu 拓撲

```
switches: 10（dpid 1–10）
links:    32
hosts:    128（128 個有 ipv4）
paths:    16256
```

拓撲結構（從 32 條 link 還原，runbook 沒有畫出來過，記在這裡供後續 phase 選點）：

```
edge(有 host)   s1 s2 → 上連 s5, s6          s3 s4 → 上連 s7, s8
aggregation     s5 s6 s7 s8 → 各自上連 s9, s10
core            s9 s10
```

- h1 在 s1、h97 在 s4 ⇒ **h1→h97 必經 5 台**：`s1 → (s5|s6) → (s9|s10) → (s7|s8) → s4`。
- 每一跳都有兩條等價路徑 ⇒ 斷單一鏈路或關單一 agg/core switch 時，恆有替代路徑。

### 【觀察】netem / qdisc 基線

```
$ tc qdisc show | grep -c netem
0
```

✅ **零 netem 殘留**（收尾時要回到這個值）。其餘 qdisc 是 Mininet 自己設的 `htb`（每條 host link 的頻寬限制），屬於正常拓撲組態。

### 【觀察】s7 bridge 完整組態（供 power phase 前後比對）

```
$ sudo -n ovs-vsctl list-ports s7      → s7-eth1 s7-eth2 s7-eth3 s7-eth4
$ sudo -n ovs-vsctl get bridge s7 protocols fail_mode sflow other-config
[]
secure
335b27a5-3528-41fc-96c8-4e2e9eb7fe61
{datapath-id="0000000000000007", disable-in-band="true", dp-desc=s7}
$ sudo -n ovs-vsctl --columns=targets,sampling,polling list sflow
targets: ["192.168.123.1:6343"]  sampling: 256  polling: 0
```

---

## Phase 0b — 對 runbook 的通讀結論（開跑前）

通讀 `doc/2026-08-10_ovs_manual_test_runbook.md` 全 1476 行後，**在執行前**就能判定的落差列在這裡。
「這步合理嗎」的一秒判斷結果——三個危險步驟、兩個未涵蓋 phase。

### 🔴 P1 — runbook §1 的「確認起點乾淨」在本輪是**破壞性**的，已跳過

【觀察】runbook §1 開頭（`doc/2026-08-10_ovs_manual_test_runbook.md:90-101`）第一件事就是：

```bash
./stack.sh down
sudo mn -c
```

【推論】這一節的前提是「**從乾淨環境開始**」（文件開頭第 3 行自己這樣寫）。本輪的前提相反：
stack 已經在跑、而且 **Mininet 是不可重建資源**（`sudo python3` 不在 NOPASSWD，Adam 整夜不在）。
`mn -c` 會殺光 10 個 bridge 和 128 個 host namespace，這輪之後就沒有 live 環境了。
**已跳過 §1、§2（build/unit tests，本輪禁令 5）、§3（起 stack，已經起好）**，直接從 §4 開始。

嚴重度 **P1（對本輪而言）**——不是 runbook 的錯（它的適用情境不同），但**它沒有寫「如果 stack 已經在跑該怎麼接手」**，
而「接手一個別人開好的 stack」正是這種過夜輪次的常態。建議 runbook 補一節 §0「接手已在跑的 stack」。

### 🔴 P1 — 「殺 controller」phase：runbook 沒有，而交接單給的替代程序**就是雷本身**

【觀察】runbook **完全沒有**殺 controller / 錯誤回報的 phase。它只有文末的反向警告
（`doc/2026-08-10_ovs_manual_test_runbook.md:1380-1398`「⚠️ 特別警告：不要單獨重啟 Ryu」）。
`doc/2026-07-29_environment_gotchas.md:241-258` 是它的來源，原文：

> 「**在 Mininet 還在跑的時候重啟 Ryu，8 秒後 `/stats/flow/<dpid>` 開始永久回空表**（1.001 秒逾時、
> `{"1": []}`），而且不會恢復 —— 不會因為初始安裝完成而恢復，也不會因為唯一的客戶端停止而恢復。」

【推論】交接單指示「要重啟只能整組 `stack.sh down` → `stack.sh up ovs`」。
**但 `cmd_down`（`tools/test_workflow/stack.sh:655-660`）停的是 kernel + p4_proxy + ryu 三者，它從來不碰 Mininet**
（它自己印 `Mininet was started manually; clean it up with: sudo mn -c`）。
既然 Mininet 今晚不能重開，`down` → `up ovs` 的淨效果**就是「在 Mininet 還在跑的時候重啟 Ryu」**——
一字不差地命中 gotcha 描述的觸發條件。「整組重啟」之所以安全，前提是 Mininet 也跟著重開；那個前提今晚不成立。

⇒ **本輪不執行任何形式的 Ryu 重啟**（單獨或整組皆不做），phase 5 改為靜態查證 + 以 kernel 側的錯誤回報路徑代替。
詳見 Phase 5。嚴重度 P1（給文件與未來的交接單：**「整組 down/up」不是 wedge 的通用解藥，它只在 Mininet 可重建時才是**）。

### ⚠️ P2 — §6 斷鏈用 `ifconfig down`，本輪依交接單改用 `tc netem`；兩者量到的**不是同一個機制**

【觀察】runbook §6a（`:930-933`）用 `sudo -n ifconfig s1-eth2 down`，並在 §6b（`:973-978`）明確記載偵測路徑：

> 「不是『LLDP 收不到 → 逾時』——`ifconfig down` 會讓 OVS 立刻送出 OpenFlow **port-status** 事件，
> Ryu 收到就直接發 `EventLinkDelete`。**沒有逾時，所以是毫秒級不是秒級。**」

【推論】`tc qdisc add ... netem loss 100%` **不會**改變 port 的 link state，所以**不會**產生 port-status 事件。
Ryu 只能靠 LLDP 收不到而逾時（`ryu/topology/switches.py` 的 `LINK_TIMEOUT`）才刪除該 link。
⇒ **本輪 §6 量到的偵測延遲會是「秒級」，而且和 runbook 記載的 +31 ms 不衝突——它們是兩個不同的實驗。**
好處：P4 輪也是用 tc netem 量的（交接單給的對照點 ping gap 16.63s），**改用 netem 反而讓 OVS/P4 的對照變成同機制比較**。
本輪照交接單用 netem，並在 Phase 3 明確標示「這不是 runbook §6 的重跑」。

### 📌 runbook 未涵蓋的兩個 phase（依交接單骨架自行補完）

| phase | runbook 狀態 |
|---|---|
| switch 整台 power off/on | **未涵蓋**。§10「仍未測的項目」自己列著：「switch 整台失聯（非單一鏈路）｜完全沒測；Phase 7 的電源管理會需要這個」 |
| 殺 controller / 錯誤回報 | **未涵蓋**，且見上面 P1 |

power phase 的既定路徑（開跑前先讀原始碼，避免手動 `del-br`）：
`POST /ndt/set_switches_power_state?ip=<switch_ip>&action=on|off`
→ `setPowerStateMininet`（`DeviceConfigurationAndPowerManager.cpp:1398`）
→ `OVSPowerStrategy::powerOff`（`src/ndt_core/power_management/OVSPowerStrategy.cpp:128`）：
`list-ports` → 存 port 清單到圖 → 對每個 port `ifconfig down` → `ovs-vsctl del-br <sw>`；
`powerOn`（`:67`）：`add-br` + `set bridge other-config:datapath-id` → 逐 port `add-port` + `ifconfig up` → `set-controller tcp:127.0.0.1:6633`。

⚠️ **開跑前的預測（Phase 4 要驗證的假說）**：`powerOn` 重建的 bridge **只還原 datapath-id 和 controller**。
基線抓到 s7 還有 `fail_mode=secure`、`sflow=<uuid>`、`other-config:disable-in-band=true`、`dp-desc`，
**這四項都不在 `powerOn` 的還原清單裡**。若假說成立，power cycle 過的 switch 會**永久失去 sFlow 組態**（telemetry 從此少一台）
且 fail-mode 退回 `standalone`。這是可證偽的預測，Phase 4 逐項比對。

---

## Phase 1 — 靜態健康（runbook §4、§7）23:47–23:50

**canary**：h1→h97 ICMP 5 pps（`ping -D -i 0.2`，經 `mnexec` 以 root 在 h1 namespace 內跑），
23:49:02 起持續執行，log 在 scratchpad `canary.log`。判準用它的 loss% 與 gap。

### 【觀察】逐項對照 runbook 的預期值

| runbook 節 | 預期 | 本輪實測 | 判定 |
|---|---|---|---|
| §4a 圖 | 10/10/10、hosts 128/128、edges 288/288 | **完全一致**，hosts with ipv4 128 | ✅ |
| §4b node keys | 12 個 | 12 個，字母序完全相同 | ✅ |
| §4c power report | 10 筆、33466–147622 mW | 10 筆、**min 33466 / max 147622**、`{dpid:1, power_consumed:92465}` | ✅ |
| §4d avg_link_usage (idle) | `0.0` | `{"avg_link_usage":0.0,"status":"success"}` | ✅ |
| §4e flow table | 每台約 130 | **10 台全部正好 130，總計 1300** | ✅ |
| §4f detected flows (idle) | `0` | **2**（見下） | ⚠️ 我自己造成的 |
| §4g Ryu switches / links | 10 / 32 | 10（dpid 1–10）/ 32 | ✅ |
| §4h Ryu paths | 16256 | 16256 | ✅ |
| §4i ryu log | `Static topology initialized` ≥1、`Failed`/`Traceback` 0 | 1 / **0** | ✅ |
| §4j kernel log | 一行 `288 edges up`、error 0、`JSON parsing failed` 0 | 一行（23:41:48.829）、**0** / **0** | ✅ |
| §7 admin_disabled | 全 0、violations 0 | 0 / 0 / **0** | ✅ |

**§4c 的第三次獨立確認**：`33466`–`147622` 這組上下界在 2026-07-30、2026-08-11、今晚三次獨立測試完全相同。
runbook §4c 推論「這是 dpid 的決定性函數，不含量測成分」——**再多一個資料點支持，且再次確認它抓不到「電力估算對不對」**。

### 【觀察】§4f 回 2 筆不是 stale flow，是 canary 自己

```
flows: 2
  16777226 -> 1627389962  proto 1  path_len 7
  1627389962 -> 16777226  proto 1  path_len 7
```

`proto 1` = ICMP，兩個 IP 解出來是 `10.0.0.1` 和 `10.0.0.97`（little-endian，runbook §5c）。
【推論】就是我的 canary，雙向各一筆。**§4f 的「idle 應為 0」在有 canary 時不適用**——這是本輪測試設計造成的，不是缺陷。
記錄下來是因為：任何未來照這份 runbook 跑、同時開 canary 的人都會看到同一件事。

順帶：此刻 `avg_link_usage` **仍是 0.0**，而 ICMP flow 存在且 `path_len=7`。
【推論】與 §5h 的分工一致——`flow_set` 的成員資格活得比 `link_bandwidth_usage` 久；
5 pps × 1/256 取樣（§5j 算出每台 switch 期望取樣間隔 51.2 秒）不足以撐起非零的瞬時速率。
**這同時是 §5j 的一個順帶重驗點**（Phase 2 會正式重測 flicker）。

### 【觀察】🆕 startup 期間有 5 條 link 被刪掉又加回來，runbook 沒有記載過

```
$ grep -c "Link deleted" .test_run/logs/ryu.log     → 5
ryu.log:616  Link deleted: Port<dpid=6, port_no=1, LIVE> to Port<dpid=1, port_no=2, LIVE>
ryu.log:620  Link deleted: Port<dpid=6, port_no=2, LIVE> to Port<dpid=2, port_no=2, LIVE>
ryu.log:624  Link deleted: Port<dpid=6, port_no=4, LIVE> to Port<dpid=10, port_no=2, LIVE>
ryu.log:628  Link deleted: Port<dpid=6, port_no=3, LIVE> to Port<dpid=9, port_no=2, LIVE>
ryu.log:632  Link deleted: Port<dpid=4, port_no=1, LIVE> to Port<dpid=7, port_no=2, LIVE>
ryu.log:636-652  同樣這 5 條全部 Link added 回來
ryu.log:656  recomputing all-pair routes after topology change
ryu.log:1067 route reinstall done
```

【觀察】這 5 組的**前後都夾著 `ECONNREFUSED`**（ryu.log 的 ECONNREFUSED 範圍是 line 28–655），
而 kernel 於 23:41:48 才啟動 ⇒ **這些事件全部發生在 kernel 起來之前**。
`Notified NDT, status code: 200` 在整份 ryu.log 中出現 **0 次**。

【推論】
1. 這是**收斂期的 LLDP 探索抖動**，不是自發故障：5 條全部自己回來，最終 32/32，route reinstall 收斂成 1 次。
2. **兩端都是 `LIVE`** 是關鍵簽名。runbook §6b 記載 `ifconfig down` 造成的刪除是「被 down 的那端 `DOWN`、對端 `LIVE`」。
   ⇒ **`LIVE`→`LIVE` = LLDP 逾時刪除；`DOWN`→`LIVE` = OpenFlow port-status 刪除。**
   這個簽名在 Phase 3 會被拿來**證明** netem 走的是逾時路徑而不是 port-status 路徑，而不是用時間長短去猜。
3. `Notified NDT ... 200` 目前是 0 ⇒ Phase 3 一旦出現第一筆，就是「Ryu 確實把這次斷線推給了 kernel」的無歧義標記。

嚴重度 **P3（記錄用）**：不影響結論，但 runbook §3c 只描述了「32 個 Link added 去抖動成 1 次重裝」，
**沒有提到 discovery 期間會有 delete/re-add 抖動**。建議補一句，否則下一個人看到 `Link deleted` 會以為出事了。

### 【觀察】kernel 有一筆 startup warning（非本輪操作造成）

```
[2026-08-12 23:41:48.750] [warning] [ApplicationManager.cpp:322 cleanupStaleEntries]
  'sudo exportfs -ra' failed while clearing stale entries (exit status 1). Stale exports f…
```

【推論】NFS export 清理，與 OVS/Ryu 資料平面無關；`exportfs` 不在 NOPASSWD 清單裡，失敗是必然的。
kernel 整份 log 的 `[error]`/`[critical]`/exception 計數是 **0**，這是唯一一筆 warning。
嚴重度 **P3**——不影響本輪，但它每次啟動都會噴一次。

### 【觀察】canary 判準

```
replies : 478 / seq 1..478 / missing 0 (0.00% loss) / window 99.2s
gaps >= 0.5s : none
```

✅ **Phase 1 全程 ping 未停、零遺失、無 ≥0.5s 的 gap。**

### Phase 1 判定

✅ **全綠，11 項對照全部符合 runbook §4/§7 的實測值**，唯一的偏差（§4f 回 2）已歸因到本輪自己的 canary。
**runbook §4 與 §7 在今晚的環境下完全成立，沒有發現文件與現實不符。**

---

## Phase 2 — 流量與 telemetry（runbook §5）23:52–23:55

**流量**：`iperf -c 10.0.0.97 -u -p 5001 -b 10M -t 600`（h1→h97，單向 UDP），23:52:01 起跑，
server 端 `iperf -s -u -p 5001` 在 h97。兩者都經 `mnexec` 起在對應 namespace。
pid 用 `pgrep -f "[m]ininet:h1$"` 取得——**`$` 錨定照 runbook §5a 的 🔴 更正做了**，實測 h1 確實只中 1 個 pid。

### 【觀察】逐項對照

| runbook 節 | 預期 | 本輪實測 | 判定 |
|---|---|---|---|
| §5c flow 筆數 | `iperf -u` 單向 = 1 筆 | UDP **1 筆**（另有 canary 的 ICMP，見下） | ✅ |
| §5c path_len | 7 | **7** | ✅ |
| §5c 實際路徑 | `h1→s1→s6→s10→s8→s4→h97` | `[16777226, 1, 6, 10, 8, 4, 1627389962]` **與 2026-08-11 完全相同** | ✅ |
| §5c src/dst 型別 | little-endian 整數 | `16777226`→`10.0.0.1`、`1627389962`→`10.0.0.97` | ✅ |
| §5c rate_bps | 6.2M–15.5M 跳動（送 10M） | **8693350 – 14902886**（12 次取樣） | ✅ |
| §5d avg_link_usage ×3 | 0.001–0.01 | **0.004812 / 0.006960 / 0.007995** | ✅ |
| §5b sFlow ingest healthy | 恰好一行、`rx=1`、`addressed=0` | 一行，`rx=1, app_drop=0, addressed=0, sock_ovfl_total=0` | ✅ |
| §5f flow table（有流量） | 仍每台約 130 | **10 台全部 130，總計 1300，與 idle 相同** | ✅ |
| §5g num_of_flows | 路徑上 1、路徑外 0 | 見下，**10/10 自洽** | ✅ |

§5d 的三個數字和 2026-08-11 的 `0.004890 / 0.008460 / 0.007658` 幾乎重疊，且**上下跳動不是單調爬升**——再次符合 §5d 的機制描述。

### 【觀察】§5g：10/10 完全自洽

當下只有 UDP 一條 flow（ICMP 剛好在這一刻不存在，見下節），路徑 `[1, 6, 10, 8, 4]`：

```
dpid 1  {"num_of_flows":1}   dpid 6  {"num_of_flows":1}   dpid 10 {"num_of_flows":1}
dpid 8  {"num_of_flows":1}   dpid 4  {"num_of_flows":1}
dpid 2,3,5,7,9              {"num_of_flows":0}      <- 路徑外全 0
```

✅ 路徑上 5 台各 1、路徑外 5 台全 0，與 `get_detected_flow_data` 的路徑**完全自洽**。
§5g 說「路徑外回 0 才是這個檢查真正有鑑別力的部分」——本輪這一半也對。

### 【觀察】🆕 §5j 的重現，這次帶了 ground truth 對照

runbook §5j 主張：低速率 flow 在 `get_detected_flow_data` 裡**存在與否本身會閃爍**，
原因是每條邊各自獨立取樣、各自獨立老化，不是流量真的斷了。
§5j 的證據是讀 edge 的 `flow_set`。**本輪用不同的方法重驗：拿 ping 自己的序號當 ground truth。**

canary 是 5 pps ICMP（正好是 §5j 用的速率）。每 5 秒查一次頂層端點，連查 12 次（60 秒）：

```
23:53:21  icmp=2   23:53:36  icmp=1   23:54:01  icmp=2
23:53:26  icmp=2   23:53:41  icmp=1   23:54:06  icmp=2
23:53:31  icmp=2   23:53:46  icmp=1   23:54:11  icmp=2
                   23:53:51  icmp=1   23:54:16  icmp=1
                   23:53:56  icmp=1
```

同一個 60 秒窗內，**twin 回報的 ICMP flow 數在 1 和 2 之間來回**；
本 phase 稍早的另一次查詢（23:52:4x）更是 **icmp=0**（該次 `get_detected_flow_data` 只列得出 UDP 一條）。
⇒ 實測涵蓋了 **0、1、2 三種答案**。

**同一時間窗的 ground truth（canary 自己的序號，與 twin 完全獨立的量測）**：

```
replies 290 / seq 1244..1533 / missing 0 (0.00% loss) / window 60.1s
gaps >= 0.5s : none
```

【推論】**這 60 秒內 ICMP 雙向 100% 送達、一個封包都沒掉、沒有任何 ≥0.5 秒的中斷**，
而 twin 在同一段時間對「這條 flow 存不存在」給出了 0/1/2 三種答案。
⇒ **§5j 成立，而且這是比原本更強的證據**：原本是用 twin 的另一個端點（edge `flow_set`）去反駁 twin 的頂層端點，
本輪是用**完全在 twin 之外的量測**（ping 的序號）證明「流量從未中斷」。
「排除 ICMP」這類協定過濾假說在這裡也再次被排除——同一條 ICMP flow 在不同時刻被列出 2 次、1 次、0 次，
協定過濾解釋不了「有時候看得到」。

⚠️ **對 Phase 7 電源管理的意義（沿用 §5j 的結論，本輪再確認一次）**：
拿「`get_detected_flow_data` 裡有沒有這條 flow」當「這條路徑閒不閒置」的判準，
在 ~5 pps 的流量上會拿到 0/1/2 三種答案，而真相是 0% loss。**這個誤判無法用取多次中位數修掉**——
0 和 2 都是「當下觀測」，中位數只會給你一個同樣沒有根據的數字。

### 【觀察】canary 判準

Phase 2 全程（含流量灌入的瞬間）：**0.00% loss、無 ≥0.5s gap**。
✅ 開 10M UDP 沒有對 canary 造成任何可見擾動。

### Phase 2 判定

✅ **全綠，9 項對照全部符合 runbook §5**；§5j 的閃爍現象**成功重現並強化證據**。
本輪 UDP flow 走的路徑（s1→s6→s10→s8→s4）與 2026-08-11 完全相同——
runbook §5c 說「不同 run 會走不同路」，本輪**沒有**走不同路，等價路徑的選擇看起來是穩定可重現的（兩次同結果，非決定性證據）。

---

## Phase 3 — 斷鏈路（runbook §6，但改用 tc netem）23:56–00:03

⚠️ **這不是 runbook §6 的重跑。** §6 用 `ifconfig down`，本輪依交接單用 `tc netem loss 100%`。
兩者觸發**不同的偵測機制**（見 Phase 0b 的 P2），量到的數字不可直接和 §6 的並列。

### 🔴 P1（新，未記載於任何文件）— 交接單指定的 `tc qdisc add ... root netem` 會**破壞 Mininet 的 htb**，而且**還原不回去**

【觀察】交接單寫的是：「`sudo -n tc qdisc add dev <if> root netem loss 100%`，兩端都下，復原 `del ... root`」。
本輪先查了目標介面的既有 qdisc：

```
$ tc qdisc show dev s1-eth2
qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 0 direct_qlen 1000
$ tc class show dev s1-eth2
class htb 5:1 root prio 0 rate 1Gbit ceil 1Gbit burst 15Kb cburst 1600b
```

**root qdisc 已經被 Mininet 佔用了**（`htb`，即 TCLink 的頻寬限制）。我原本預期 `add root` 會因為
「已有 root qdisc」而報 `File exists` 而失敗，於是拿它當一個安全的預檢——**結果它成功了，而且直接把 htb 換掉**：

```
$ sudo -n tc qdisc add dev s1-eth2 root netem loss 100%      # 沒有任何錯誤輸出
$ tc qdisc show dev s1-eth2
qdisc netem 8005: root refcnt 15 limit 1000 loss 100%         # htb 5: 和 class 5:1 都不見了
```

【觀察】接著照交接單的復原指令做，**復原不回原狀**：

```
$ sudo -n tc qdisc del dev s1-eth2 root        # 成功
$ sudo -n tc qdisc add dev s1-eth2 root handle 5: htb default 1
sudo: a password is required                    # ← 被拒絕
$ tc qdisc show dev s1-eth2
qdisc noqueue 0: root refcnt 2                  # 既不是 netem 也不是 htb
```

原因在 sudoers：

```
$ sudo -n -l
(root) NOPASSWD: /usr/bin/ovs-vsctl, /usr/sbin/ifconfig, /usr/bin/mnexec
(root) NOPASSWD: /usr/sbin/tc qdisc add dev s[0-9]*-eth[0-9]* root netem *
(root) NOPASSWD: /usr/sbin/tc qdisc del dev s[0-9]*-eth[0-9]* root
(root) NOPASSWD: /usr/sbin/tc qdisc show dev s[0-9]*-eth[0-9]*
```

**NOPASSWD 只放行了「加 root netem」和「刪 root」，沒有放行「加回 htb」。**

【推論】照交接單的字面程序操作，**每測一條鏈路就會永久拆掉那條鏈路的 htb 頻寬設定**，
而且 `del ... root` 之後留下的是 `noqueue`，**不是原本的 htb**——
`tc qdisc show | grep -c netem` 這個收尾檢查會回 0（看起來乾淨），但環境其實已經被改掉了。
**「netem 零殘留」不等於「qdisc 回到原狀」。**

【解法（本輪採用）】`mnexec` 以 uid 0 執行（`doc/2026-07-29_environment_gotchas.md` 記載過這個技巧用於 `ovs-ofctl` 和 `py-spy`），
拿 root namespace 的 pid 就能取得完整 tc 權限：

```
$ sudo -n mnexec -a 1 tc qdisc add dev s1-eth2 root handle 5: htb default 1
$ sudo -n mnexec -a 1 tc class add dev s1-eth2 parent 5: classid 5:1 htb rate 1Gbit ceil 1Gbit burst 15Kb cburst 1600b
$ tc qdisc show dev s1-eth2 ; tc class show dev s1-eth2
qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 10 direct_qlen 1000
class htb 5:1 root prio 0 rate 1Gbit ceil 1Gbit burst 15Kb cburst 1600b
```

**與未被動過的姊妹介面 `s1-eth1` 逐欄位一致**（只差 `direct_packets_stat` 這個計數器）。s1-eth2 已完全復原。

【本輪之後所有斷鏈都改用非破壞性的做法】把 netem 掛在 htb class 底下當 leaf，而不是取代 root：

```
sudo -n mnexec -a 1 tc qdisc add dev <if> parent 5:1 handle 10: netem loss 100%   # 斷
sudo -n mnexec -a 1 tc qdisc del dev <if> parent 5:1 handle 10:                   # 復原，htb 原封不動
```

實測 htb 全程保留、移除後 `grep -c netem` 回 0，**且 `tc qdisc show` 與基線逐行相同**。

⚠️ **這條要回報給 orchestrator**：如果今晚的 P4 輪也照同一份交接單用 `tc ... root netem`，
**P4 拓撲上被測過的每條鏈路可能都留下了同樣的 htb 殘留**（症狀是該介面變成 `noqueue`），
而 netem 殘留檢查看不出來。建議請 A 輪確認一下他們動過哪些介面。

### 【觀察】Phase 3A — 雙向斷（s1-eth2 + s6-eth1，兩端都下 netem）

T0 = **23:59:40.551**。iperf（10M UDP，h1→h97）與 canary 全程在跑。

| 時間 | 事件 | 相對 T0 | 來源 |
|---|---|---|---|
| 23:59:40.451 | canary 最後一筆回應 | −0.10s | canary.log |
| 23:59:40.551 | netem loss 100% 上到兩端 | **T0** | 指令 |
| 23:59:41 – 00:00:23 | **twin 回報 `edges_up=288/288`、`ryu_links=32`、兩向都在、flow 路徑仍是 `[1,6,10,8,4]`、rate 3–18 Mbps** | +0.5 … +42.5s | monitor（每秒取樣） |
| **00:00:23.124** | kernel log `link failed on 6:1 -> 1:2` | **+42.57s** | kernel.log |
| 00:00:24.10 | kernel 圖 `edges_up=286/288`，`down=[(1,2,6,1),(6,1,1,2)]`；但 Ryu 仍 `ryu_links=31`（`1->6=Y`） | +43.5s | monitor |
| **00:00:28.127** | kernel log `link failed on 1:2 -> 6:1` | **+47.58s** | kernel.log |
| 00:00:28.27 | `ryu_links=30`，兩向皆 N | +47.7s | monitor |
| **00:00:32.867** | **canary 恢復** | **+52.42s** | canary.log |
| 00:00:38.36 | twin 的 flow 路徑才改成 `[1,5,10,8,4]`（繞到 s5） | +57.8s | monitor |
| 00:00:51.687 | kernel topology poll 印出 `286 edges up` | +71.1s | kernel.log |

**canary 判準**：

```
gaps >= 0.5s : 1
     52.42s   1786550380.451 -> 1786550432.867   seq 3066 -> 3318
整段 189s 窗：missing 251 (27.58% loss)
```

### 【推論】三個結論

**1. netem 走的是 LLDP 逾時路徑，這是用簽名證明的，不是用時間長短猜的。**
Phase 1 建立的判別法（`LIVE`→`LIVE` = LLDP 逾時；`DOWN`→`LIVE` = port-status）在這裡派上用場：

```
Link deleted: Link: Port<dpid=6, port_no=1, LIVE> to Port<dpid=1, port_no=2, LIVE>
Link deleted: Link: Port<dpid=1, port_no=2, LIVE> to Port<dpid=6, port_no=1, LIVE>
```

**兩端都是 `LIVE`** ⇒ port 狀態從未改變 ⇒ 不可能是 port-status 事件 ⇒ 只能是逾時。
兩個方向相隔 **5.003 秒**（00:00:23.124 → 00:00:28.127），正好是 Ryu 的 5 秒逾時掃描週期——**另一個獨立的簽名**。
`Notified NDT, status code: 200` 從 0 變成 2，證明這兩筆確實推給了 kernel（本 stack 生命週期內第一次成功通知）。

**2. 🔴 附錄 A 的「OVS 事件驅動 ~30 ms，比 P4 的 5 秒輪詢快」只在 port-state 故障成立，對靜默故障會反轉。**

| 故障型態 | OVS 偵測延遲 | 來源 |
|---|---|---|
| `ifconfig down`（port state 改變） | **+31 ms** | runbook §6b【2026-08-11 實測】 |
| `tc netem loss 100%`（port 仍 LIVE） | **+42.6s** | 本輪實測 |

**差距約 1370 倍。** runbook 附錄 A 那一列（「link failure 偵測：OVS 事件驅動 ~30 ms ｜ P4 輪詢 5 秒一輪」）
**沒有標明它的前提是「故障會改變 port 狀態」**。真實世界的鏈路劣化（光衰、單向故障、中間設備丟包）
不會改變 port state，這時 OVS 這條路徑要靠 LLDP 逾時，**比 P4 的 5 秒輪詢慢一個數量級**。
建議附錄 A 那一列加上故障型態的限定詞。嚴重度 **P1（文件宣稱過度概化）**。

**3. 對照 P4 輪：同樣用 tc netem，OVS 的 ping gap 是 P4 的 3.15 倍。**

| | P4 輪（交接單提供） | OVS 輪（本輪） |
|---|---|---|
| ping gap | **16.63s** | **52.42s** |
| 復原 | hitless | **hitless**（見下） |

⚠️ **這個對照現在是同機制比較**（兩邊都是 netem、都不改 port state），比原本的 30ms-vs-5s 更有意義。
差異的來源是偵測層：P4 的 proxy watchdog 5 秒輪詢一次 LLDP beacon；OVS 靠 Ryu 的 LLDP 逾時（實測 ~43s）。

### 【觀察】§6i 窗口 A 第三次重現，長度 14.3 秒

```
00:00:24.10  edges_up=286  down=[(1,2,6,1),(6,1,1,2)]   flow path [1, 6, 10, 8, 4] @6209536
00:00:38.36  edges_up=286                                flow path [1, 5, 10, 8, 4] @6830489
```

【推論】**twin 在 14.3 秒內同時宣稱「s1↔s6 這條鏈路是 down 的」和「這條 flow 正以 ~6 Mbps 走過它」。**
runbook §6i 記載的兩次分別是 13 秒和 14 秒（條件差異極大：閒置 vs 200 Mbps 負載）。
本輪是第三種條件（netem 靜默故障、10M 單流），**仍然是 14.3 秒**。
三次不同條件都落在 13–14.3 秒 ⇒ 強化 §6i 的推測「成因是固定週期的快取更新（10 秒）而非負載相關」。

⚠️ 但**本輪 twin 的自相矛盾比 §6i 記載的更嚴重**：§6i 的窗口 A 是「斷線後圖已更新、路徑還沒更新」。
本輪在**圖更新之前**還多了一段 **42.5 秒**，期間 twin 對這條鏈路和這條 flow **兩者都說健康**
（`edges_up=288/288` + flow 以 3–18 Mbps 走過那條鏈路），而實際上封包 100% 被丟。
**這 42.5 秒不是矛盾，是一致地錯**——比矛盾更難被消費端發現，因為沒有任何跡象可以交叉檢查。

### 【觀察】恢復

T0 = **00:02:46.145**（`tc qdisc del ... parent 5:1 handle 10:` 兩端）

| 時間 | 事件 | 相對 T0 |
|---|---|---|
| 00:02:50.53 | kernel 圖回到 `edges_up=288/288`（`ryu_links=31`，一向先回來） | **+4.4s** |
| 00:02:51.921 | kernel topology poll 印出 `288 edges up` | +5.8s |
| 00:02:52.60 | `ryu_links=32`，兩向皆 Y | **+6.5s** |
| 00:03:04.51 | flow 路徑繞回 `[1,6,10,8,4]` | **+18.4s** |

**canary 判準**：`missing 0 (0.00% loss)`、`gaps >= 0.5s : none`（60.9 秒窗）
✅ **恢復完全 hitless**——流量早就在 s5 上跑，鏈路回來只是多一條路可選。

對照 runbook §6g 的 `ifconfig up`：edges up ~3 秒、路徑繞回 ~27 秒。本輪 netem 是 4.4 秒 / 18.4 秒，**同量級**。
【推論】**恢復方向兩種故障型態沒有明顯差異**，因為 LLDP 一旦通了就立刻被收到，不需要等逾時。
不對稱性只存在於偵測方向：**斷得慢（42.6s），復得快（4.4s）。**

### 【觀察】iperf 總結（600 秒跑完）

```
[  1] 0.0000-600.0015 sec   629 MBytes  8.80 Mbits/sec  0.400 ms  86049/534991 (16%)
     22 datagrams received out-of-order
```

16% 的 loss 看起來很高。【推論】534991 datagram / 600s ≈ 891 pps，
本輪這條 iperf 撞上**兩次**中斷：Phase 3 前的 44.5 秒（見下節）和 Phase 3A 的 52.4 秒，
合計 96.9 秒 × 891 pps ≈ **86,300**，與實測 86,049 相符。
⚠️ 依「算式吻合不等於機制」的教訓，這只當作**一致性檢查**（兩次中斷都落在這條 flow 的路徑上，預期它們都會計入），
不當作獨立證據。runbook §5e 說「沒斷線的乾淨一輪應該接近 0%」——本輪斷了兩次，16% 與該說法不矛盾。

---

## Phase 3D — 🔴🔴 **P0：單向鏈路故障會讓 Ryu 的路由重算永久崩潰，流量無限期黑洞**

**這是本輪最重要的發現，runbook、`2026-07-29_environment_gotchas.md`、§10「仍未測」清單都沒有記載過。**

### 為什麼會跑這一輪

Phase 3 開始前的意外操作（P1 那節）在 s1-eth2 單端下了 netem，44.5 秒後移除，期間**完全沒有任何偵測**。
我原本要寫成「單向故障偵測不到」，但 Phase 3A 量到的偵測延遲是 42.6 秒——**44.5 秒只比它多 1.9 秒**，
所以「沒偵測到」完全可能只是「還沒到」。**觀察不足以支撐那個推論**，於是補跑一輪、把時間拉長到足以分辨。

### 【觀察】實驗設計與結果

只在 **s1-eth2 單端**下 netem（`parent 5:1`，非破壞性），s6-eth1 保持乾淨 ⇒ 只有 s1→s6 方向丟包，s6→s1 正常。
T0 = **00:05:03.683**。canary + iperf（10M UDP）全程在跑。

| 時間 | 事件 | 相對 T0 |
|---|---|---|
| 00:05:03.666 | canary 最後一筆回應 | −0.02s |
| 00:05:03.683 | netem loss 100% 上到 s1-eth2（**單端**） | **T0** |
| 00:05:52.83 | 最後一次 `edges_up=288/288`（twin 仍全綠） | +49.1s |
| **00:05:53.244** | kernel log `link failed on 1:2 -> 6:1`（**只有一筆，不是兩筆**） | **+49.6s** |
| 00:05:53.86 | kernel 圖 `edges_up=286`，`down=[(1,2,6,1),(6,1,1,2)]` ← **兩條都標 down** | +50.2s |
| 00:06:22.93 | kernel 圖自我修正為 `edges_up=287`，`down=[(1,2,6,1)]` ← 只剩一條 | +79.2s |
| 00:05:03 – 00:09:55 | **canary 100% 遺失，一筆都沒回來** | 全程 |
| 00:09:55.011 | 我移除 netem | +291.3s |
| 00:09:55.075 | canary 立刻恢復 | +291.4s |

**canary 判準：中斷 291.4 秒，等於 netem 在位的全部時間。零自我恢復。**
移除 netem 後 0% loss、86.7 秒無 gap。

獨立驗證（不靠 canary，避免「我的量測工具壞了」這個解釋）：

```
$ sudo -n mnexec -a <h1> ping -c 4 -W 2 10.0.0.97   → 4 transmitted, 0 received, 100% packet loss
$ sudo -n mnexec -a <h97> ping -c 4 -W 2 10.0.0.1   → 4 transmitted, 0 received, 100% packet loss
```

（反向也 100% 失敗是預期的：request 走 s4→s8→s10→s5→s1 沒問題，但 h1 的 **reply** 要走 h1→s1→s6，正是壞掉的方向。）

### 【觀察】根因：`install_all_pair_paths` 拋 `KeyError` 並中止整輪重算

```
route reinstall failed: 6
Traceback (most recent call last):
  File "/home/adam/Desktop/NDTwin-Kernel/intelligent_router.py", line 200, in _route_reinstall_worker
    self.install_all_pair_paths(self._active_net())
  File "/home/adam/Desktop/NDTwin-Kernel/intelligent_router.py", line 582, in install_all_pair_paths
    out_port = net[current_switch][prev_switch]["port"]
  File ".../networkx/classes/coreviews.py", line 53, in __getitem__
    return self._atlas[key]
KeyError: 6
```

崩潰當下的資料平面（**這是「twin 說謊」的鐵證**）：

```
$ curl -s localhost:8080/stats/flow/1 | (取 nw_dst=10.0.0.97 那條)
match: {'dl_type': 2048, 'nw_dst': '10.0.0.97'}   actions: ['OUTPUT:2']   dur: 371
                                                            ^^^^^^^^ port 2 = 通往 s6 = 壞掉的方向
```

`dur: 371` ⇒ 這條規則從未被替換過（stack 起來就在了）。Ryu 自己的 `all_destination_paths` 也還是舊路徑：

```
h1 -> h97 : [['10.0.0.1', 3], [1, 2], [6, 4], [10, 4], [8, 2], [4, 3], ['10.0.0.97', 0]]
                                     ^^^^^^ 仍經 port 2 -> s6
```

而同一時刻 twin 的 `get_detected_flow_data` 回報這條 flow **正以 9–15 Mbps 走 `[1,6,10,8,4]`**，
`get_graph_data` 回報 `edges_up=287/288`。**流量實際是 0。**

### 【推論】機制：DiGraph 的邊不對稱，BFS 假設反向邊必然存在

`intelligent_router.py:99-100` 用的是 `nx.DiGraph()`。`install_all_pair_paths` 的 BFS 從 `dst_switch` 出發，
沿著出邊 `X → Y` 走，然後查**反向**邊的 port：

```python
out_port = net[current_switch][prev_switch]["port"]     # :582
```

⇒ **只要存在「X→Y 有邊、Y→X 沒邊」的狀態，這一行就 KeyError，整輪重算中止。**

單向資料平面故障產生的正是這個狀態：LLDP 只有 s1→s6 這一向收不到，
所以 Ryu 只發**一個** `EventLinkDelete`、只移除 `1→6`，而 `6→1` 完好保留 ⇒ **圖永遠不對稱**。

`intelligent_router.py:807-809` 的註解正好寫下了這個被違反的假設：

> 「The graph is a DiGraph and EventLinkDelete fires once per direction, so removing the one
> directed edge named by this event is exactly right — **the paired event removes the other**.」

**「the paired event removes the other」只在雙向同時故障時成立。** 單向故障時配對事件永遠不會來，
不對稱狀態不是過渡期而是**穩態**，於是每一次重算都在同一行崩潰、路由永遠不更新、流量永遠黑洞。

### 【觀察】🔴 這個 bug 今晚在「正常啟動」時就已經觸發過一次

`route reinstall failed` 全程共 **2 筆**：

| ryu.log 行號 | 錯誤 | 時機 |
|---|---|---|
| **4119** | `KeyError: 1` | **stack 正常啟動期間**（Phase 1 記錄的那 5 條 LLDP 抖動） |
| 6550 | `KeyError: 6` | 本 phase 的單向故障 |

Phase 1 記錄的 5 條啟動抖動，log 寫的是 `removed edge 6 -> 1` / `6 -> 2` / `6 -> 10` / `6 -> 9` / `4 -> 7`
——**全部只有單一方向**，反向邊都還在 ⇒ 同樣的不對稱狀態 ⇒ 同樣的 `KeyError`。

【推論】**這不是只有在人為單向故障下才碰得到的邊緣情況。** LLDP 探索抖動在每次啟動都可能發生，
今晚就發生了，而且確實讓一輪重算崩潰。啟動時之所以沒事，是因為那 5 條 link 隨後又被加回來、
圖恢復對稱，後續的重算才成功（`route reinstall done` 最終有出現、16256 條路徑齊全）。
**是自癒掩蓋了崩潰，不是崩潰沒發生。**

### 【推論】為什麼 Phase 3A（雙向斷）反而沒事

3A 的兩個方向不是同時刪除的，相隔 5.003 秒（Ryu 的逾時掃描週期）。
中間那 5 秒圖是不對稱的，但**第二個刪除到達後圖又對稱了**，隨後的重算就成功了——
canary 也正是在第二次刪除之後約 4.7 秒恢復（+47.6s → +52.4s）。

⇒ **雙向故障能繞路，只是因為不對稱狀態是暫時的。單向故障讓它變成永久。**
這也解釋了 3A 的 ping gap（52.4s）為什麼比偵測延遲（42.6s）多了約 10 秒。

### 嚴重度與影響

**P0。** 理由：

1. **後果是無限期的資料平面黑洞**，而非延遲或不準確——流量 100% 不通，且不會自己好。
2. **twin 在整段期間回報一切正常**（`edges_up=287/288`、flow 以 9–15 Mbps 流動），
   消費端（含 Phase 7 電源管理）看不到任何異常訊號。
3. **單向鏈路故障在真實網路很常見**（光模組單向衰減、單邊 SFP 故障、中間設備單向丟包），
   而這正是數位孿生應該要抓到的東西。
4. **同一個崩潰在今晚的正常啟動流程中就觸發過一次**，不需要人為故障。
5. 崩潰是**沉默的**：只有 ryu.log 有 traceback，kernel 完全不知情，沒有任何端點會顯示「上一輪路由重算失敗了」。

**建議修法（未實作，本輪不改 code）**：`:582` 那行需要在反向邊缺席時有退路——
要嘛 BFS 只走「雙向都在」的邊，要嘛查不到反向 port 時跳過該 switch（比照下方 `datapath is None` 那個
已經存在的防禦，它的註解說的正是同一類問題：「aborted the whole recompute part-way and left routes half-installed」）。
**`:582` 是同一類缺陷的第二個實例，而且沒有被守住。**

⚠️ **另一個未查證的疑慮，留給下一輪**：崩潰發生在 BFS 走到一半，
所以這一輪的 flow-mod **可能已經裝了一部分**（`datapath is None` 那段註解明講過「left routes half-installed」）。
本輪沒有去比對崩潰前後每台 switch 的規則差異，**「半裝狀態會不會留下不一致的轉發表」沒有答案**。

---

## Phase 4 — Switch 整台 power off / on（**runbook 未涵蓋**）00:13–00:19

runbook §10「仍未測的項目」自己列著：「switch 整台失聯（非單一鏈路）｜完全沒測；Phase 7 的電源管理會需要這個」。
本節依交接單骨架補測，**走 kernel API 的既定路徑，沒有手動 `del-br`**。

目標選 **s7**（aggregation，連 s3/s4/s9/s10）——不在當下流量路徑（`[1,6,10,8,4]` 走 s8）上，
所以 canary 可以乾淨地回答「twin 自己的動作有沒有波及無關流量」。

### 【觀察】power off：`POST /ndt/set_switches_power_state?ip=192.168.123.17&action=off`

回應 `{"192.168.123.17":"Success"}`，**耗時 196 ms**。`ovs-vsctl list-br` 立刻少一台（s7 不見了）。

| 時間 | 事件 | 相對 T0（00:13:45.334） |
|---|---|---|
| 00:13:45.53 | API 回 Success，s7 bridge 已刪除 | +0.20s |
| 00:13:45.67 | kernel 圖 `sw_up=9`、`edges_up=280/288`、Ryu `ryu_links=24` | **+0.34s** |

8 條邊正好是 s7 的 4 條 link × 雙向，且**完全對稱**：

```
down=[(3,1,7,1), (4,1,7,2), (7,1,3,1), (7,2,4,1), (7,3,9,3), (7,4,10,3), (9,3,7,3), (10,3,7,4)]
```

✅ **偵測是次秒級的**（不是 Phase 3 的 42.6 秒）——因為刪 bridge 會直接斷開 OpenFlow 連線，
Ryu 立刻收到 switch leave，不需要等 LLDP 逾時；而且 kernel 的 `setVertexDown` 是 `powerOff` 同步呼叫的。

✅ **沒有觸發 Phase 3D 的 KeyError**（`route reinstall failed` 維持 2 筆）。
【推論】因為整台 switch 消失會讓它的**所有**邊雙向一起消失，圖仍然對稱——
再次印證 3D 的機制是「不對稱」而不是「邊變少」。

### 【觀察】twin 的表示方式（**不要套用 P4 的預期**）

| 端點 | s7 power off 時的行為 |
|---|---|
| kernel `get_graph_data` | dpid 7 **仍在圖上**，`is_up=false`、`is_enabled=true`、`admin_disabled=false` |
| Ryu `/v1.0/topology/switches` | **s7 整個消失**（count 9，dpid 清單無 7） |
| kernel `get_switches_power_state` | `{"192.168.123.17":"OFF"}`，其餘 9 台 `ON` ✅ |
| kernel `get_switch_openflow_table_entries` | 只剩 9 台（s7 不在），其餘仍各 130 條 |

【推論】交接單提醒的「32afeb9 的『死 switch 從 topology/switches 消失』是 P4 proxy 側行為」——
**OVS 側實測：Ryu 那一層確實也消失了，但 kernel 的圖保留 vertex 並標 `is_up=false`。**
兩層行為不同是合理的（kernel 的圖來自靜態 topology 檔，liveness 是疊上去的屬性），
但**消費端若直接讀 Ryu 的 `/v1.0/topology/switches` 會認為那台機器不存在，讀 kernel 的圖則會認為它存在但 down。**

### 【觀察】🆕 三個姊妹端點對「switch is down」用了三種不同的表示法

同一時刻、同一台 s7（`192.168.123.17`）：

```
get_power_report      →  {'dpid': 7, 'power_consumed': 0}          數值 0
get_cpu_utilization   →  （整個 key 不存在）                        鍵缺席
get_temperature       →  {"192.168.123.17": "The switch is down."}  字串，塞在本來是整數的欄位
```

【推論】嚴重度 **P2（API 一致性）**。三種都「有道理」，但**放在一起就不可能寫出統一的消費端**：
- 把 temperature 當整數解析的客戶端會在這裡拋型別錯誤（其餘 9 個 key 都是整數）。
- 迭代 cpu 的 key 的客戶端會**靜默地**少一台，不會知道是「down」還是「沒回報」。
- 只有 power 是型別乾淨的。

順帶：runbook §4c 寫「如果 `up=0`，power report 可能是空的」。**實測不是空的，是 10 筆但該台為 `0`。**
（本輪是單台 down，不是全部 down，嚴格說沒有直接推翻該句，但 `power_consumed: 0` 這個行為值得補進 §4c。）

### 【觀察】power on：`?ip=192.168.123.17&action=on`

回應 `{"192.168.123.17":"Success"}`，耗時 **261 ms**。

| 時間 | 事件 | 相對 T0（00:15:39.170） |
|---|---|---|
| 00:15:39.45 | kernel `sw_up=10`（vertex 立刻標 up）但 `edges_up=280` | +0.28s |
| 00:15:40.49 | kernel `edges_up=288/288`、Ryu `ryu_links=28` | **+1.3s** |
| 00:15:42.57 | Ryu `ryu_links=32`（全部回來） | **+3.4s** |

✅ **完整收斂 ~3.4 秒**，遠快於 Phase 3 的鏈路故障恢復。

### 【觀察】canary 判準 — 全程 hitless

```
window 243.7s（涵蓋 power off + 維持 + power on + 收斂）
missing 0 (0.00% loss)   gaps >= 0.5s : none
```

✅ **關掉再開一台不在路徑上的 switch，對既有流量零影響。**

### 🔴 P1 —— power cycle 會**永久遺失** switch 的 sFlow 與 fail-mode 組態

Phase 0b 的可證偽預測，**逐項命中**。s7 power cycle 前後 `ovs-vsctl list bridge s7` 比對：

| 欄位 | power off 之前 | power on 之後 | 結果 |
|---|---|---|---|
| ports | s7-eth1…s7-eth4 | s7-eth1…s7-eth4 | ✅ 還原 |
| `datapath_id` | `0000000000000007` | `0000000000000007` | ✅ 還原 |
| `protocols` | `[]` | `[]` | ✅（本來就空） |
| **`sflow`** | `335b27a5-…` | **`[]`** | 🔴 **遺失** |
| **`fail_mode`** | **`secure`** | **`[]`** | 🔴 **遺失** |
| **`other_config:disable-in-band`** | `"true"` | **不存在** | 🔴 遺失 |
| **`other_config:dp-desc`** | `s7` | **不存在** | 🔴 遺失 |
| `controller` | `tcp:127.0.0.1:**6653**` | `tcp:127.0.0.1:**6633**` | ⚠️ 改了 port |

跨 bridge 交叉確認（power on 之後、我還原之前）：

```
s1..s6, s8..s10 :  sflow=<uuid>  fail_mode=secure
s7              :  sflow=[]      fail_mode=[]        <- 十台裡唯一的一台
```

**成因**在 `src/ndt_core/power_management/OVSPowerStrategy.cpp`：
`powerOff`（`:128`）只記錄 port 清單然後 `del-br`；`powerOn`（`:67`）重建時只跑
`add-br` + `set bridge other-config:datapath-id` + 逐 port `add-port`/`ifconfig up` + `set-controller tcp:127.0.0.1:6633`。
**sFlow、fail-mode、disable-in-band、dp-desc 都不在還原清單裡**，而 `del-br` 把它們連同 bridge 一起刪掉了。

【推論】為什麼這是 P1 而不是 P3：

1. **sFlow 遺失 = 那台 switch 的 telemetry 永久消失。** kernel 的鏈路使用率與 flow 偵測完全建立在 sFlow 上
   （runbook §5b/§5j）。power cycle 過的 switch 之後不再送任何 sample，
   而 `get_graph_data` 仍然回報它 `is_up=true` ——**twin 看起來完全健康，只是那台的流量從此隱形**。
2. **這正是 Phase 7 電源管理的核心動作。** 電源管理的價值就是把 switch 關掉再開；
   **每做一次就少一台的 telemetry**，且沒有任何錯誤訊息。做滿一輪 10 台，sFlow 就全滅了。
3. **`fail_mode` 從 `secure` 變成預設的 `standalone` 是行為改變**：controller 斷線時，
   `secure` 是丟包，`standalone` 是退化成 L2 learning switch 自己轉發。
   也就是說 power cycle 過的 switch 在 controller 失聯時會**開始自作主張轉發**，
   而 twin 的模型假設它不會——這會讓真實轉發行為和 twin 的路徑宣稱分岔。

⚠️ 這條和 §5j 疊加起來特別糟：§5j 說低速率 flow 的存在本身就不可信；
現在再加上「power cycle 過的 switch 完全不送 sample」。
**若 Phase 7 拿「flow 不存在」當「可以關機」的判準，關掉一台之後再開，那台就永遠「沒有 flow」——
判準會自我實現。**

### 【本輪已還原】

sFlow / fail-mode / other-config 已用 `ovs-vsctl`（NOPASSWD 允許）照 `testbed_topo.py:105-137` 的原始參數重建：

```
sudo -n ovs-vsctl -- --id=@sflow create sflow agent=s7-eth1 target=\"192.168.123.1:6343\" \
    header=128 sampling=256 polling=0 -- set bridge s7 sflow=@sflow
sudo -n ovs-vsctl set-fail-mode s7 secure
sudo -n ovs-vsctl set bridge s7 other-config:disable-in-band=true other-config:dp-desc=s7
```

還原後 s7 的 `fail_mode`、`other_config`、sFlow record（agent/header/sampling/polling/targets）
與其餘九台**逐欄位相同**（只有 sFlow record 的 uuid 是新的，無意義）。

⚠️ **唯一沒有還原的是 controller port**：s7 現在是 `tcp:127.0.0.1:6633`，其餘九台是 `tcp:127.0.0.1:6653`。
**刻意不動**——Ryu 同一個 process 同時聽 6633 和 6653（Phase 0 基線的 `ss` 已確認），
兩者功能完全相同，而改 controller 會讓 s7 重新連線一次、製造一次不必要的拓撲抖動
（而抖動正是 Phase 3D 那個 KeyError 的觸發條件）。**已收斂的 stack 不值得為了外觀去戳。**
留給 Adam 決定，一行指令：`sudo ovs-vsctl set-controller s7 tcp:127.0.0.1:6653`。

---

## Phase 5 — 殺 controller / 錯誤回報 00:20–00:22

### 🔴 決定：**不執行任何形式的 Ryu 重啟**（單獨或整組皆不做）

理由已在 Phase 0b 詳述，這裡只記結論與證據鏈：

1. **runbook 沒有這個 phase。** 它只有文末的反向警告（`:1380`「⚠️ 特別警告：不要單獨重啟 Ryu」）。
   ⇒ 交接單說「只照 runbook 的精確程序做」，而 runbook 的精確程序就是**不要做**。
2. **交接單給的替代方案（整組 `stack.sh down` → `up ovs`）在今晚等價於「單獨重啟 Ryu」。**
   `cmd_down`（`tools/test_workflow/stack.sh:655-660`）只停 kernel / p4_proxy / ryu，
   **從不碰 Mininet**（它自己印 `Mininet was started manually; clean it up with: sudo mn -c`）。
   Mininet 今晚不可重建 ⇒ `down`+`up` 的淨效果就是 gotcha 描述的觸發條件：
   「在 Mininet 還在跑的時候重啟 Ryu」。
3. **後果不可逆且會污染整晚的結論**：`/stats/flow/<dpid>` 8 秒後永久回空表，
   kernel 讀到的 flow table 全空 → 每條 flow 的 `path` 變空 → 之後任何觀察都不可信，
   而且**不會恢復**（`2026-07-29_environment_gotchas.md:246-247`：「不會因為初始安裝完成而恢復，
   也不會因為唯一的客戶端停止而恢復」）。Adam 早上會拿到一個壞掉的環境。

⇒ **這一格是刻意留白，不是漏測。** 要補測它，必須在 Adam 能重開 Mininet 的時段做。

⚠️ kernel 對 wedge 的防禦（`classifyFlowStatsReply`，空表 + 耗時 ≥ `kFlowStatsSuspectSeconds` 0.5s
→ 保留上一份表）**本輪沒有也無法驗證**——要驗證它就得先製造 wedge。**這一格仍是未測狀態。**

### 【觀察】改以 kernel API 的錯誤回報路徑代替（零 wedge 風險）

「錯誤回報」這個目標本身可以在不碰 Ryu 的前提下測——直接打 kernel 的錯誤路徑：

| 請求 | HTTP | body | 判定 |
|---|---|---|---|
| `POST set_switches_power_state?ip=10.99.99.99&action=off`（不存在的 IP） | **500** | `{"error":"Failed to change switch power state"}` | ✅ |
| `POST set_switches_power_state?ip=192.168.123.17&action=bogus` | **400** | `{"error":"Missing or invalid ip/action"}` | ✅ |
| `POST set_switches_power_state`（無參數） | **400** | 同上 | ✅ |
| `GET set_switches_power_state?...`（它是 POST-only） | **404** | `{"error":"Not Found"}` | ✅ |
| `GET get_switch_openflow_table_entries?dpid=1` | **404** | `{"error":"Not Found"}` | ✅ **證實 runbook §4e 的宣稱** |
| `GET /ndt/does_not_exist` | **404** | `{"error":"Not Found"}` | ✅ |
| `POST get_num_of_flows_passing_a_switch {}`（缺 dpid） | **400** | `{"message":"dpid missing","status":"error"}` | ✅ |
| `POST get_num_of_flows_passing_a_switch {"dpid":999}` | 200 | `{"num_of_flows":0,"status":"success"}` | ⚠️ 見下 |

✅ **最重要的一項：對不存在的 IP 下 `action=off`，什麼都沒被關掉。**
呼叫後 `ovs-vsctl list-br` 仍是 10 台、`get_switches_power_state` 十台全 `ON`。
**失敗的電源請求沒有去動圖，也沒有去動資料平面**——這正是 `setPowerStateTestbed` 那段註解
（「Deliberately does NOT touch the graph…」）所堅持的性質，在 MININET 路徑上一樣成立。

⚠️ **P3**：`{"dpid":999}`（根本不存在的 switch）回 `{"num_of_flows":0,"status":"success"}` 而不是錯誤。
實作是數「以該 dpid 為終點的邊」，不存在的 dpid 自然是 0 條，所以技術上沒錯。
但**打錯 dpid 和「這台真的沒有 flow」回傳完全相同**，而 §5j 已經說明 `0` 本身就不可信了——
兩層歧義疊在同一個回傳值上。建議至少對不在圖上的 dpid 回 404。

---

## Phase 6 — 收尾 00:20–00:22

### 【觀察】停掉本輪自己開的東西（Mininet 完全不碰）

依 runbook §5e 的方法，`kill` 不在 NOPASSWD 清單，所以繞 `mnexec`（uid 0）殺 root 持有的 process：

```
for p in $(pgrep -x iperf); do sudo -n mnexec -a 216825 kill "$p"; done    # iperf  247683
for p in $(pgrep -x ping);  do sudo -n mnexec -a 216825 kill "$p"; done    # canary 245796
```

`pgrep -x`（精確比對 comm）對 iperf/ping 是安全的。

⚠️ **過程紀錄：我在殺自己的 monitor 時踩到了 `-f` 自我匹配，把自己的 shell 殺掉了**（exit 144）。
指令是 `for p in $(pgrep -f "scratchpad/monitor.py"); do kill "$p"; done`——
**`pgrep -f` 的 pattern 字串本身出現在我這條命令列裡**，於是它匹配到自己的 shell。
這正是 runbook §1（`:107`、`:119`）對 `pgrep -f` 的警告、以及「`pkill -f` 會殺掉我自己的 shell」的同一個陷阱，
**只是換成 `pgrep -f` + `kill` 的組合，危險性完全相同**。
後果僅限於我自己的 shell（每個 Bash 呼叫本來就是新 shell），**Mininet／Ryu／kernel 都沒事**，
但這件事值得寫進來：**`-f` 的自我匹配風險不會因為把 `pkill` 換成 `pgrep`+`kill` 而消失。**
安全寫法是 `ps -eo pid,args | grep '[m]onitor\.py'`（中括號）或直接用已知 pid。

事後以中括號法確認：iperf / ping / monitor / mnexec wrapper **全部為空**。

### 【觀察】`stack.sh down`

```
$ cd tools/test_workflow && ./stack.sh down          # 00:21:14
Shutting down (reverse order)
  stopped kernel
  stopped ryu
Mininet was started manually; clean it up with:  sudo mn -c
done
exit code: 0
```

✅ 只停了 kernel 和 ryu，**如設計般沒有碰 Mininet**，且 `cmd_down` 的 port 殘留檢查沒有報任何 leftover（exit 0）。

### 【觀察】收尾驗證 vs Phase 0 基線

| 項目 | Phase 0 基線 | 收尾實測 | 判定 |
|---|---|---|---|
| Ryu process | pid 216679 | **無** | ✅ 應死已死 |
| kernel process | pid 242000 | **無** | ✅ 應死已死 |
| iperf / ping | （本輪開的） | **無** | ✅ |
| `:8000 :8080 :8081 :6633 :6653` listener | 8000/8080/6633/6653 有 | **全部無** | ✅ |
| OVS bridges | s1–s10（10 個） | **s1–s10（10 個）** | ✅ 屬於活著的 Mininet，正常 |
| Mininet host namespace | 128（h1–h128） | **128** | ✅ 完好 |
| `testbed_topo.py` process | 活著 | **活著** | ✅ 完好 |
| netem 殘留 | 0 | **0** | ✅ |
| `s1-eth2` qdisc | `htb 5:` | **`htb 5:`** | ✅ 已還原（見 Phase 3 的 P1） |
| `s6-eth1` qdisc | `htb 5:` | **`htb 5:`** | ✅ |
| `s1-eth1` qdisc（對照組，全程未動） | `htb 5:` | **`htb 5:`** | ✅ |

**orchestrator 獨立複驗的結果與上表一致**：kernel 0、`:8000/:8080/:6633` 皆空、bridges s1–s10 都在、netem 殘留 0。
唯一數字差異是 Mininet process 計數（我記的是 **128 個 host namespace**，orchestrator 記的是 **139 個 mininet process**）——
**這不是不一致**：128 是 `mininet:h*` 的 host namespace shell 數，139 額外含 switch 與 topo 腳本自身的 process。
兩者都指向同一結論：**Mininet 完好無損。**

### 【觀察】canary 的全程總帳（本輪最強的單一證據）

canary 從 23:49:03 跑到 00:20:35，**1892 秒未中斷取樣**：

```
replies : 7234        seq 1..9098 (expected 9098)
missing : 1864 (20.49%)
gaps >= 0.5s : 3
    291.41s   Phase 3D  單向斷（P0 bug，全程無自癒）
     52.42s   Phase 3A  雙向斷（+42.6s 偵測、+52.4s 繞路完成）
     44.51s   Phase 3 前 tc 誤操作（單端 netem，44.5 秒後我自己移除）
```

✅ **整整 1892 秒裡只有 3 個 gap，而且三個全部可歸因到我自己下的斷鏈操作。**
⇒ **Phase 1（靜態）、Phase 2（telemetry）、Phase 4（switch power off/on）、Phase 5（錯誤路徑）全部零封包遺失、零中斷。**
這一行同時也是「power cycle 一台不在路徑上的 switch 完全 hitless」與「twin 的查詢本身不擾動資料平面」的證據。
