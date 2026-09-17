# GAP-ANALYSIS — 用 p4lang/tutorials 的 13 支 exercise 當真實需求，盤點 NDTwin KERNEL/PROXY 還缺什麼

合成自 `GAP-1-exercise-requirements.md`（需求側）與 `GAP-2-ndtwin-p4-capabilities.md`（供給側，兩份由不同
agent 各自讀碼寫成）。本檔做三件事：**對表、勘誤、把真 gap 換成「缺 XXX ⇒ 改法 YYY」**。

[Co-developed with claude code -- Adam]

---

## 0. 怎麼讀這份

- **證據等級**（沿用 `REPORT-PICK-0908.md` §0，不可混用）：【跑過】＝有 raw／逐字；【讀碼推導】＝讀過未執行；
  【只有文件宣稱】＝只讀到文件這樣寫。🔴 **本檔幾乎每一條都是【讀碼推導】**——兩份輸入都宣告「一個封包都沒
  送」。轉引的【跑過】：GAP-2 引的 **2026-08-13 mastership 實測**（`p4_client.py:60-72`）、README 引的
  **09-04 編譯矩陣**（26 支實編、25 支 rc=0）。
  🆕 **2026-09-08 17:24 更新**：**exercise 本身已經跑過了**——Adam 以 root 用 `drive_exercise.py`
  （tutorials 自己的 harness）跑了 `source_routing` 與 `basic` 各 solution／skeleton 兩向，**4/4 綠**
  （5/5、2/2、5/5、4/4，exit 0，報告在 `runs/`）。🔑 **但那是在 tutorials 的 Mininet 上跑的，不是 NDTwin**：
  **在 NDTwin fabric 上仍然 0/13**。⇒ **本檔的五個 gap 與 §5 的發現①一個字都沒被驗證，仍是【讀碼推導】**；
  09-08 那四次改變的只有一件事：**每支 exercise「對的樣子」現在有 raw 可對帳**（原本連對照基準都是推導的）。
- **判定四值**（§2 用）：`真 gap`／`無需求（不是 gap）`／`已足夠`／`【不確定】`。
  **「改法」是提案不是裁決**，每個 gap 都寫了候選與代價，選哪個留給 Adam；**工作量是行數量級的粗估、標【估】**。
- 本檔自己新查證的行號標「**本輪抽查**」（我實際 `sed`／`grep` 讀過那一行），其餘照抄兩份輸入並在 §7 列出來源。
  **沒有執行任何東西**：沒起 fabric、沒編譯、沒跑 Mininet／bmv2／`ndt`、沒 sudo、沒殺行程、沒改任何既有檔。

---

## 1. 一頁報告摘要（給教授）

**方法**：① 需求側——13 支 exercise ×16 個能力維度，逐支讀 `.p4`／`topology.json`／`sX-runtime.json`／
`mycontroller.py`；② 供給側——同 16 維度盤點 NDTwin 做得到／部分／做不到，每格附寫死處 `檔:行`；
③ 對表——剔除「做不到但沒人要」、拆開「需求與供給對不上」的細節，剩下的才是真 gap。

**結論的形狀**：16 維裡有 6 維（custom_headers 資料面、checksum、ttl、registers、qdepth 讀取、parser）問的其實是
「**NDTwin 自己那支 `.p4` 有沒有**」，而每支 exercise 都帶自己的 `.p4` ⇒ **只要「能載入任意 pipeline」成立就自動
滿足，不必補 NDTwin 的 P4 程式**；真 gap 全在 **proxy／kernel 側**：控制面寫入、環境與啟動參數、觀測面。

| # | gap（一句） | 擋住幾支／誰 | 今天寫死在哪 | 提案改法（一句） | 工作量【估】 | 解鎖後 |
|---|---|---|---|---|---|---|
| G2 | 拓樸只認「主機數」選檔、proxy 用四等分公式推主機位置、交換機清單寫死十台；且**逐連結頻寬完全沒被套用** | **13/13**（ecn／mri 另需 0.5 Mbps 瓶頸） | `p4_testbed_topo.py:120-134` | 三處改讀拓樸檔；`Mininet(...)` 加 `link=TCLink` | ~85 行 | 13 支的前提 |
| G4 | 只推得動一份寫死路徑的 pipeline，十台同一份、跑時換不了 | **12/13**（除 basic） | `main.py:185-186` | per-dpid manifest（先收抄本，再加覆寫） | ~150 行 | 12 支的資料面 |
| G5 | 表名／action 名／參數名／key 位寬全寫死在三張自家表上，**且沒有任何 `default_action` 寫入路徑** | **12/13**（link_monitor／mri 沒 default_action ＝零分） | `p4_client.py:846` | 旁路 `POST /p4/table_entry`，exact＋lpm、位寬由 p4info 決定 | ~180 行 | 12 支的控制面 |
| G1 | packet-in metadata id 是**位置相依**的裸常數 1..5 ⇒ 換程式即遙測靜默歸零 | **12 支的遙測**（換 pipeline 就踩到） | `sflow_emitter.py:425-429` | 開機由 p4info 的 `controller_packet_metadata` **按名字**解析 | ~40 行 | 保護上面 12 支 |
| G6 | 觀測面 IPv4-only：`etherType != 0x0800` 整包丟、`FlowKey` 只有 IPv4 五元組 | **6 支「轉得動、分身全盲」** | `FlowLinkUsageCollector.cpp:1266` | 分兩層：先保住外層 IPv4 的既有口徑，再擴 `FlowKey` | ~30 ＋ ~250 行 | 6 支從盲變可觀測 |

**兩個「測 tutorial 才會暴露」的發現**（機制見 §5）：① **靜默歸零**——遙測鏈路依賴 NDTwin 自己那支 `.p4` 的欄位
順序，換一支程式後每個速率／使用率都是 **0 且沒有任何錯誤訊息**；② **回報成功並清空全表**——tutorials 普遍自帶
`mycontroller.py`，它與 proxy 的十個 client 投**同一個寫死的 election_id (0,1)**，冒名者的
`SetForwardingPipelineConfig` 會被接受、清空每一張表、再回報成功【跑過】。
**誠實聲明**（2026-09-08 更新）：上面五個 gap 與發現①**全部是讀碼推導**，一條都沒有在 NDTwin 上被驗證。
**exercise 本身**已於 **2026-09-08 17:24** 用 tutorials 自己的 harness（`drive_exercise.py`，Adam 以 root）
實跑過 `source_routing`／`basic` 各**兩向**——**4/4 綠**（solution 5/5、skeleton 2/2；solution 5/5、skeleton 4/4），
raw 在 `runs/`。🔴 **在 NDTwin fabric 上仍是 0/13**：那四次證明的是「exercise 該長什麼樣」與「driver 能用」，
**不是** NDTwin 跑得動它們。13 支裡**只有 `basic` 是零改動能跑的**，而「零改動」只在轉發同構這一層成立（見 §4）。

---

## 2. 對表與勘誤

先講**對表最重要的一件事**：GAP-2 的 16 維裡有一群格子問的是「NDTwin 的 `ndtwin_switch.p4` 有沒有這個 feature」，
但 exercise 帶自己的 `.p4`——**只要 G4 成立，那支程式的 register／checksum／TTL／自訂 parser／qdepth 讀取全部
由它自己滿足**，NDTwin 不必補。判定欄照這個原則走。

| 維度 | 需求（GAP-1） | 供給（GAP-2） | 判定 |
|---|---|---|---|
| `pipeline_load` | 13/13；最低標＝**任意一份、每台可不同、可跑時換** | 部分（一份、路徑寫死四處） | **真 gap**＝**G4** |
| `tables` | 12/13；只要 exact＋lpm；**5 支寫 `default_action`** | 部分（三張表名寫死、無 default_action 路徑） | **真 gap**＝**G5** |
| `pre_multicast` | 1 支（multicast），沒它整支零分 | 做不到 | **真 gap**＝**G8** |
| `pre_clone` | 1 支（flowcache），session 57→CPU | 部分（session 250 已可帶參數） | **真 gap（小）**＝**G9a** |
| `counters` | 2 支（flowcache／p4runtime） | 部分（direct 有讀、indirect 無生產讀者） | **真 gap（小）**＝**G7** |
| `meters` | **0 支**（本輪抽查：13 支 solution 全樹無 `meter`） | 做不到 | 🔴 **無需求，不是 gap** |
| `registers` | 2 支（firewall／link_monitor），**只在資料面用、控制面不讀** | 做不到（無 `RegisterEntry` RPC） | 🔴 **無需求，不是 gap**（載入該支 `.p4` 即有狀態） |
| `digest` | **0 支** | 做不到 | 🔴 **無需求，不是 gap** |
| `packet_io` | 1 支（flowcache）＋ **CPU port 是開機參數** | 部分（兩向都通，但 **metadata id 位置相依**） | **真 gap**＝**G1**（通用化）＋**G9b**（cpu-port 510） |
| `custom_headers` | 6 支要非 IPv4／變長 IPv4 | 做不到（parser 只認 0x0800） | **資料面無需求**（exercise 自帶 parser）；**真 gap 在觀測面**＝**G6** |
| `queue_metadata` | 2 支：ecn 讀 `enq_qdepth`、mri 讀 `deq_qdepth` | 做不到（P4 沒讀、bmv2 沒開 `--priority-queues`） | 拆三件，見下 |
| `checksum` | 10 支 update／1 支 verify | 部分（verify 空、只算 IPv4） | **無需求**（exercise 自帶 checksum block） |
| `ttl_or_hop` | 11/13；source_routing 靠它判路徑 | 做得到 | **已足夠**（TTL==0 處置＝**0 支需求**） |
| `topology` | 13/13；四種形狀；11 支要 gw＋靜態 ARP | 部分（schema 夠，周圍三處推導綁死、無整形） | **真 gap**＝**G2** |
| `control_plane_mode` | 3 種模式；2 支自帶外部控制器 | 部分（十個 client 共用 election_id） | **真 gap**＝**G3** |
| `verification` | 13/13；沒有一支只靠 ping 判定 | 部分（只看得到 IPv4／兩張表） | **真 gap**（＝G6＋G7 的下游） |
| `idle_timeout`（額外） | 1 支（flowcache），整支核心 | 做不到（stream 只認 packet／arbitration） | **真 gap**＝**G9c** |

### 2a. 兩份輸入之間的矛盾（我採哪一邊）

| # | GAP-1 說 | GAP-2 說 | 採 | 為什麼 |
|---|---|---|---|---|
| 1 | `registers` 只有 **firewall／link_monitor** 兩支用（§4b:262） | 「吃 register 的（**link_monitor、flowcache、load_balance** 的狀態、**mri** 的部分變體）」（§registers:127-128） | **GAP-1** | **本輪抽查**：`grep -lE '^\s*register<' */solution/*.p4` 只命中 `firewall/solution/firewall.p4` 與 `link_monitor/solution/link_monitor.p4`。flowcache／load_balance／mri 全樹 0 命中。 |
| 2 | qos **完全沒有** meter／priority／queue（§3.12:225-229） | 「tutorials 的 **`qos`**／限速類練習兩層都缺」（§meters:118） | **GAP-1** | **本輪抽查**：13 支 solution 全樹 `meter`／`direct_meter`／`execute_meter` 0 命中；`qos/topology.json` 也無任何 bw 參數。**做 meter 不會有任何一支用到。** |
| 3 | `priority_queues` 這個拓樸鍵 **一支都沒用**（§3.12:227） | 「**qos 的多佇列那半必須改啟動旗標**」（§queue_metadata:184） | **GAP-1** | **本輪抽查**：`grep -rl priority_queues exercises/` ＝ **0 個檔**；該鍵只存在於 `utils/run_exercise.py:91` 與 `p4runtime_switch.py:85-87,124-125` 的支援碼裡。 |
| 4 | `queue_metadata` 要的**只有** `enq_qdepth`（ecn）與 `deq_qdepth`（mri） | 同段把 ecn／qos 綁在一起講、**漏掉 mri** | **GAP-1** | 同上抽查：`enq_qdepth` 只在 `ecn`、`deq_qdepth` 只在 `mri`；qos 兩者皆無。 |

### 2b. 需求與供給對不上、需要拆開的細節

- **`queue_metadata` 拆三件，只有一件是真 gap。** ① **連結整形**：ecn／mri 的 0.5 Mbps 瓶頸是唯一製造佇列的
  手段；tutorials 用 `link = TCLink`（**本輪抽查** `run_exercise.py:258`）並把 `bw` 傳進 `addLink`（`:99-112`），
  NDTwin 的 `Mininet(topo=topo, controller=None, autoSetMacs=True)`（**本輪抽查** `p4_testbed_topo.py:662`）
  **沒有 `link=`、全檔無 `bw=`／`delay=`**（grep 0 命中）⇒ 沒有整形就沒有佇列、qdepth 恆 0、兩支都「假通過」
  ⇒ **真 gap，併入 G2**。② **程式讀 qdepth**：ecn／mri 自己的 `.p4` 自己讀 ⇒ **G4 之後不是 gap**。
  ③ **觀測面看得到 qdepth**：`packet_in_header_t` 六個欄位無佇列深度（`ndtwin_switch.p4:156-164`，**本輪抽查**），
  合成 sFlow 也不帶——但 ecn／mri 的判定在**收端**（`tos`／swtrace 序列）不在 twin ⇒ 對「跑通 exercise」
  **無需求**；對「twin 要能解釋 ecn 為何觸發」是 gap ⇒ 標【選配】。
- 🔑 **`--priority-queues` 不需要。** 13 支沒有一支設它，而 ecn／mri 整支判定就靠 qdepth ⇒ **預設單佇列下 qdepth
  就有值**；該旗標只服務 `standard_metadata.priority`，那欄位 13 支 0 使用。⇒ **GAP-2 §queue_metadata 候選 A 不必
  做**——它會讓 bmv2 天花板那四張工單的數字不可跨比（`KNOWN-ISSUES §F-bmv2`），是白付的代價。⚠️【不確定】
  **bmv2 內部是否真在單佇列下填 `enq/deq_qdepth`，我沒讀 bmv2 原始碼**（這台機器上沒有 behavioral-model 樹）；
  需求層結論不受影響，機制層待驗。
- **`pipeline_load`：候選 A 不夠、B 才夠。** 最低標是「**任意一份、且每台可不同**」
  （`firewall/pod-topo/topology.json:39` 讓 s1 載 `firewall.json`、s2-s4 吃 `Makefile:6` 的 `basic.p4` ⇒ **同一
  網路兩份 p4info 同時在線**），外加 p4runtime／flowcache 要**跑時**推；A（環境變數、四處共讀）只做到「一份、
  全網同一支」⇒ **firewall 直接掛且跑時換不了**。我補 **A'＝把 A 當 B 的第一步**，見 §3-G4。
- **`tables`：候選 B（generic writer ~400 行）過度設計**——GAP-1 §4a:249 明講「**只需要 exact 與 lpm，
  ternary／range／optional 在 13 支裡一次都沒出現**」，而 B 的成本大半來自「把 `ryu_flow_stats` 的 Ryu 形狀
  契約整個拉進來重談」。我補 **A'（中間方案）＝旁路寫入路徑、不動北向 Ryu 那條路**，見 §3-G5。
- 🔴 **GAP-2 的 `tables` 段漏了 `default_action`。** **本輪抽查**：5 支的 `sX-runtime.json` 帶
  `"default_action": true`（basic 7 筆、firewall 4、link_monitor 4、load_balance 3、mri 3），其中 **link_monitor
  的 `MyEgress.swid` 與 mri 的 `MyEgress.swtrace` 是「無 key、只有 default action」的表**
  （`link_monitor.p4:208-214`、`mri.p4:211-217`，宣告都是 `default_action = NoAction()`），參數 **`swid` 每台不同**
  ⇒ **控制面不寫就是零分**。NDTwin proxy 對 `default_action` **只有讀**（`p4_client.py:619`），**沒有任何寫入路徑**
  （**本輪抽查** grep）⇒ 併入 G5。
- **`custom_headers` 的真 gap 在觀測面，而且比 GAP-2 說的更細一層。** 除「非 IPv4 整包丟」
  （`FlowLinkUsageCollector.cpp:1266-1279`）外，**本輪抽查**發現解析器讀 L4 port 用**固定字組位移**
  `data[index+24]`／`[index+25]`（`:1299-1300`），**全檔無任何 `ihl` 項**（grep 0 命中）⇒ **mri 不是「看不見」而是
  「看得見但讀錯」**：外層仍是 IPv4（option 在 IPv4 header 裡、`ihl > 5`），etherType 檢查放行，然後把 MRI option
  的位元組當 L4 port 讀進 `FlowKey`。**比整包丟更糟：會產生看起來合理的錯流。**【讀碼推導】；偏移量的確切後果
  我沒逐行推完 ⇒【不確定】。
- **`p4runtime`／`flowcache` 的控制面不必由 NDTwin 實作**——這兩支**自帶 `mycontroller.py`**（GAP-1 §3.11／§3.6）
  ⇒ NDTwin 要的不是「長出 idle_timeout／packet-in 的控制邏輯」，而是「**退位讓它寫、同時看得見**」，這把 G9 從
  「四件套 ~180 行」降成「G3＋觀測面」。⚠️ 但**位址對不上**：`mycontroller.py:167-176` 寫死
  `127.0.0.1:50051/dev 0`、`:50052/dev 1`，NDTwin 是 `GRPC_PORT_BASE = 30050`、device_id＝dpid（**本輪抽查**
  `grpc_ports.py:39,48,66`）⇒ **s1 在 30051/dev 1，控制器找不到**。兩份輸入都沒列這條 ⇒ 併入 G3。

---

## 3. 逐 gap：缺 XXX ⇒ 改法 YYY

排序＝**解鎖支數 ÷ 工作量**。候選 A／B 轉引 GAP-2，`A'` 是我補的中間方案。工作量一律【估】。

### G1 — packet-in metadata id 位置相依（12 支的遙測；~40 行；ratio 最高）
**現況**：`PKTIN_META_REASON..SAMPLING_RATE = 1..5` 是裸常數（`sflow_emitter.py:425-429`，註解自陳 "They are
positional, so reordering the header's fields renumbers them"）；packet-out 的 `metadata_id = 1 / 2` 是裸字面
（`p4_client.py:217,222`）。**本輪抽查兩處逐字確認。**
**最低標**（GAP-1 §1:33）：packet_io 要能跟著 exercise 自己的 `@controller_header` 走。
**候選 A**：開機由 p4info 的 `controller_packet_metadata` **按名字**解析 id 存進 client，~40 行，動
`p4_client.py`＋`sflow_emitter.py`；**欄位語意不變 ⇒ 不動遙測口徑**；`tests/test_sflow_emitter.py:423-445`
已在用 regex 讀那個區段，改成正式解析可沿用。**候選 B**：維持常數＋開機自檢，對不上就拒絕啟動，~20 行——
保守，但**不解決換程式**。**建議 A**：它是 G4 的**必要伴隨**——G4 解鎖「載入任意 pipeline」的那一刻，B 只會把
靜默歸零換成拒絕啟動，A 才讓遙測跟著新程式走。風險低，且是**改動最小、後果最大**的一處。

### G2 — 拓樸三處推導 ＋ 逐連結整形（13/13；~85 行）
**現況／寫死處**：① 選檔只看主機數（`p4_testbed_topo.py:120-134`；`NDTWIN_P4_TOPO_FILE` 仍被 host 數核對
`:99-118`）⇒ **同樣 4 host 的三角形會撞上現有 10 交換機檔**；② proxy 主機表用四等分公式
`dpid = 1+(i-1)//(N//4)`、`port = 3+(i-1)%(N//4)`（`main.py:113-120`，**本輪抽查**）不讀拓樸檔；③ 交換機清單
寫死 `tuple(range(1,11))`（`main.py:154`，註解自陳 'Phase 3 work'）；④ **`Mininet()` 沒有 `link=TCLink`、全檔無
`bw=`／`delay=`**（`p4_testbed_topo.py:662`，**本輪抽查**，grep 0 命中）⇒ `link_bandwidth_bps` 完全沒被套用。
**最低標**（GAP-1 §4a:247）：四種拓樸形狀、11 支要 default gw＋靜態 ARP、host 介面一律 `eth0`（測試腳本寫死
這名字）；ecn／mri 另需**逐連結 0.5 Mbps**。
**候選 A**：主機表改讀 `topo_from_json.host_links()`，~25 行，消掉抄本 ②。**候選 B**：交換機清單一起由拓樸檔
推導，~60 行，動 `startup()` 回傳契約與 `test_startup.py`。**我補 C（必要）**：`Mininet(..., link=TCLink)` ＋
把 `link_bandwidth_bps` 轉成 `bw`(Mbps) 傳進 `addLink`，~15 行。
**建議 A＋B＋C，但 C 走獨立進入點**：13 支都要拓樸，A/B 不做就每支手改；C 不做 ecn／mri 是假通過（qdepth
恆 0）。⚠️ C **會改變所有既有量測的排隊行為**（與 `--priority-queues` 同性質的可比性風險）⇒ 只在 exercise
fabric 上開，**不要動 NDTwin 主線 fabric**。

### G3 — election_id 共用（2 支；~15 行）
**現況**：十個 client 全投寫死的 `(0,1)`（`p4_client.py:234-235`，**本輪抽查**）。`p4_client.py:60-72`
記錄 **2026-08-13 實測**【跑過】：P4Runtime 用訊息裡的三元組（不是連線）辨識送出者 ⇒ 冒名者 stream 被殺，
但它的 `SetForwardingPipelineConfig` **被接受、清空每一張表、回報成功**。
**最低標**：flowcache／p4runtime 自帶 `mycontroller.py`，必須能與 proxy 共存。
**候選 A**：election_id 提成參數、NDTwin 用高值，~15 行，不動遙測；`p4_proxy/reference/p4runtime_mastership_probe.py`
有現成驗證腳本。**候選 B**：加「唯讀模式」讓 proxy 不搶 mastership，~50 行——但 `install_initial_routes`、clone
session、readopt 全依賴寫入權，要一併裁決該模式下關掉哪些功能。**我補（必要）**：一併對齊位址——
`mycontroller.py:167-176` 寫死 `50051/dev 0`，NDTwin 是 `30050+dpid`／`dev=dpid`（`grpc_ports.py:48`、
`main.py:182-186`），~10 行。**建議 A ＋ 位址對齊**：15 行換兩支能跑，而它擋住的失敗模式是**回報成功並清空
全表**——示範現場踩到會直接毀掉整場。B 留給「NDTwin 只觀測不控制」那個場景（§6 第三階段）。

### G4 — pipeline_load 的任意性（12/13；~150 行）
**現況**：`set_forwarding_pipeline_config()` 用 `VERIFY_AND_COMMIT` 推（`p4_client.py:318-327`），但 artefact
路徑寫死在 `main.py:185-186`（**本輪抽查**），Mininet 端另有三份抄本（`p4_testbed_topo.py:360,624`、
`ntg_bmv2_topo.py:66`）；**bmv2 在 exec 時載入 json 且不重載** ⇒ 換 pipeline ＝重建 fabric（`ndt:720-724` 的
`stale_pipeline` 就是為此存在）。**最低標**（GAP-1 §4c:286）：**任意 p4info + json、每台可不同、可跑時換**。
**候選 A**：`NDTWIN_P4_PIPELINE_DIR` 環境變數、四處共讀，~40 行 ⇒ **不夠**（見 §2b：firewall 一支就否決）。
**候選 B**：per-dpid pipeline（manifest 帶 json 路徑），~150 行，動 `build_p4_client` 簽章與 readopt；
**遙測與契約測試全部假設十台同一份 p4info** ⇒ 主要風險。**我補 A'（實作順序）**：把 A 當 B 的第一步——
commit 1 把四處寫死路徑（含 `ndt` 的 `sample_rate()`／`stale_pipeline`）收成一個 helper，~40 行、可獨立驗；
commit 2 讓 helper 接 per-dpid 覆寫，~110 行。**建議 B、走 A' 的兩步**：讓「消抄本」這個獨立價值先落地，
第二步失敗也不留半套。⚠️ 依賴：**沒有 G1 先做，G4 一成功遙測就全滅**（§5-①）。

### G5 — tables 通用寫入 ＋ default_action（12/13；~180 行）
**現況**：id 按名字向 p4info 查（`p4_client.py:459-481`）——**這一半是對的、重編會跟上**；寫死的是**名字**：
`MyIngress.flow_5tuple`（`:729`）、`MyIngress.ipv4_lpm`（`:846`）、action `MyIngress.ipv4_forward` 與參數
`dstAddr`/`port`（`:761-767,856-866`）；key 位寬另有手寫表 `_FIVE_TUPLE_KEY_BYTES`（`:697-704`）——**與 p4info
的 `bitwidth` 是兩份真相**。北向 match 只有 `FIVE_TUPLE_FIELD_MAP` 十二個拼法（`topology_manager.py:193-207`）、
action 只認 `OUTPUT`。**`default_action` 完全沒有寫入路徑**（只有 `p4_client.py:619` 的讀）。**本輪抽查全部確認。**
**最低標**（GAP-1 §1:26、§4a:249）：依表名寫 entry；**match kind 只要 exact＋lpm**；參數依 p4info 型寬；**`default_action` 可改（含帶參數、每台不同）**。
**候選 A**：三個表名提成 class 常數＋位寬讀 p4info，~60 行 ⇒ **不夠**（還是自家三張表）。**候選 B**：p4info
驅動的 generic writer，~400 行 ⇒ **過度設計**（ternary/range 0 需求，且會把 `ryu_flow_stats` 的 Ryu 契約整個
拉進來重談）。**我補 A'（建議）**：**一條旁路寫入路徑** `POST /p4/table_entry`，body ＝
`{dpid, table, match:{field: value 或 [value, prefix_len]}, action, params:{}, is_default:bool}`；**只支援
exact＋lpm**；表名／欄位名／action 名一律向 p4info 查（重用 `_get_table_id` 那組）；**位寬一律讀 p4info 的
`bitwidth`，刪掉 `_FIVE_TUPLE_KEY_BYTES` 這份第二真相**；`is_default` 走 `is_default_action`。~180 行，動
`p4_client.py`＋`api_routes.py`，**不動北向 `/stats/flowentry/*`、不動 `ryu_flow_stats.py`、不動
`test_P4FlowStatsToClassifier.cpp`**。⚠️ 風險：新路徑繞過 `rule_journal`（`topology_manager.py:949-976` 只認
install/delete 的 flow 語意）⇒ **重啟後 exercise 灌的規則靜默消失**——本 repo 最常見的缺陷形狀，要先裁決。

### G6 — 非 IPv4／變長 IPv4 的觀測盲區（6 支；~30 ＋ ~250 行）
**現況**：三層都 IPv4-only——① 解析器 `etherType != 0x0800` 整包跳過（`FlowLinkUsageCollector.cpp:1266-1279`）；
② `FlowKey` 只有 IPv4 五元組＋ICMP type/code（`SFlowType.hpp:31-47`）；③ `FIELD_TO_RYU` 只認 IPv4 欄位＋
`dl_dst`（`ryu_flow_stats.py:40-48`）。**外加（本輪抽查新發現）**：L4 port 讀固定字組位移
`data[index+24]`／`[index+25]`（`:1299-1300`），**全檔無任何 `ihl` 項**（grep 0 命中）⇒ **mri 會被讀錯而不是
被丟掉**（見 §2b）。**受影響 6 支**：basic_tunnel(0x1212)／calc(0x1234)／source_routing(0x1234)／
link_monitor(0x812)＝**看不見**；mri(IPv4 option)＝**看錯**；flowcache(controller header)＝CPU 通道另計。
**候選 A**：只讓自訂標頭「不打斷」既有 IPv4 遙測，0～30 行，**新欄位仍不可見**。**候選 B**：擴 `FlowKey` 與
C++ 解析器，~250 行，碰核心＋契約測試（`test_GoldenFixture.cpp`、`test_SFlowEmitterRoundtrip.cpp`）**且會動到
已發表的量測口徑**。**我補 A'（建議先做）**：兩件小事、都不動口徑——① 解析器讀 `ihl` 決定 L4 偏移（~15 行，
**這是修錯誤不是擴功能**）；② 非 IPv4 樣本**計數但不解析**（今天是靜默 `continue`）⇒ 至少「分身知道自己看
不見多少」。合計 ~30 行。B 留到有人真的要拿 twin 觀測 tunnel 欄位再談。

### G7 — counters 北向暴露（2 支；~50 行）
**現況**：direct_counter 有讀（`p4_client.py:554-561`——**缺 `counter_data.SetInParent()` 會全回 0 且不報錯**）；
indirect `egress_port_counter` 的 `read_egress_counter()` **docstring 自陳「There are no production callers
today」**（`:651-652`）。`entry_to_ryu` 對 `is_default` 與「沒有可對映 match」的條目回 `None`
（`ryu_flow_stats.py:148-154`，**本輪抽查**）⇒ **那些 entry 的 counter 永遠不會出現在北向**——而
link_monitor／mri 的 default-only 表正是這一類。**最低標**：flowcache「counter 要增加」、p4runtime
「每 2 s 遞增」（GAP-1 §2c）。**候選 A**：`GET /p4/counter/{name}`，重用三態契約，~50 行，不動遙測。
**候選 B**：併進 `/stats/flow/{dpid}` ⇒ 改變 kernel `Classifier` 讀到的 body 形狀，碰契約測試。
**建議 A**：需求方是 exercise 的驗證腳本、不是 kernel；走旁路不必動契約，與 G5 的 A' 同一種取捨。

### G8 — PRE multicast（1 支；~80 行）
**現況**：**沒有任何 multicast group 寫入路徑**；p4info 無 PRE multicast 實體；`ndtwin_switch.p4` 無
`mcast_grp` 賦值（**本輪抽查** grep 0 命中）。`p4_client.py:355,369` 的 multicast 是 docstring 在描述 bmv2 拿
mgid `0x8000+session` 當 clone session **後端**的實作細節，**不是我們程式化的東西**。
**最低標**：`grp 1 = {port 1,2,3}`；沒有它 `mcast_grp = 1` 就是丟掉、`pingall` 全掛。⚠️ GAP-1 §3.10 另指出
陷阱：`solution/s1-runtime.json` 的 group 是 **{1,2,3,4}**（Step 2 作業答案），與預設載入的
`sig-topo/s1-runtime.json` 的 {1,2,3} 不同——**拿錯會讓「h4 不通」這個判定失效**。
**候選 A**：加 `write_multicast_group()`（形狀與 `write_clone_session()` 對稱：
`packet_replication_engine_entry.multicast_group_entry`）＋`POST /p4/multicast_group`，~80 行，不動遙測。
**候選 B**：接上 OpenFlow group 語意（`P4RoutingStrategy.cpp:19-21` 現為明確 `refuse()`），~300 行以上，
且 pipeline 要長出 ActionSelector——Phase 4 未竟工作。**建議 A**：需求只有 1 支且只要「建 group」；
而 `refuse()` 的措辭是 F-13 的裁決結果（`P4RoutingStrategy.cpp:11-23`，**本輪抽查**），動它要重談。

### G9 — flowcache 的四件套（1 支；~180 行，**但多半不必做**）
**拆四件**：a) 第二個 clone session（57→CPU）——`write_clone_session(session_id, egress_port)` 本來就是參數
（`p4_client.py:338`，**本輪抽查**），只要暴露呼叫點，~20 行，**不動既有 250**；b) **CPU port 510 是開機參數**
——NDTwin 寫死 `--cpu-port 255` 三份抄本（`ndtwin_switch.p4:45`、`p4_client.py:32`、`p4_testbed_topo.py` 的
args，**本輪抽查**），~10 行參數化；c) 通用 packet-in／packet-out ＝ **G1**；d) `idle_timeout`——entry 帶
`idle_timeout_ns` ＋ `_stream_receiver` 要認 `IdleTimeoutNotification`（今天只認 `packet` 與 `arbitration`，
`p4_client.py:158-174`），~60 行。
🔑 **但 flowcache 與 p4runtime 都自帶 `mycontroller.py`**（GAP-1 §3.6／§3.11）⇒ **NDTwin 不必當那個控制器。**
**建議：只做 a＋b（~30 行），c 由 G1 涵蓋，d 不做**——靠 **G3** 讓 exercise 自己的控制器寫、NDTwin 觀測。
要 NDTwin 自己長出 idle-timeout 控制邏輯才需要 d，**這批 exercise 沒有任何一支逼我們做**。

---

## 4. 逐支 exercise 的可行性路線

「資料面今天能跑」＝不改 NDTwin 任何一行、在 NDTwin fabric 上能不能轉發；「twin 觀測得到」＝ kernel/proxy 的
觀測面看不看得見它的流。

| exercise | 資料面今天能跑 | twin 觀測得到 | 擋住的 gap | 解掉後怎麼驗（引 GAP-1 §2c） |
|---|---|---|---|---|
| **basic** | ✅ **零改動可跑**（見下兩個 ⚠️） | ✅（IPv4，既有口徑） | （G2 拓樸／G4 若要載它自己的 json） | `pingall` loss 0%；PTF 另走 veth 不經 Mininet（**09-08 tutorials harness 實跑 PASS**：pod-topo，solution `loss = 0.0%`／`ping -c3` 3/3／h2 ttl `[63]`，skeleton `loss = 100.0%`／0/3／收 0 個——**在 tutorials 上，不是 NDTwin**） |
| qos | ❌（要它自己的 diffserv 邏輯） | ✅ | G4 | h2 看 `tos` 由 `0x1` 變 `0xb9`(UDP)／`0xb1`(TCP) |
| ecn | ❌ | ✅（外層 IPv4） | G4、**G2-C 整形** | h1 1 pps ＋ h11 `iperf -u` 灌爆 → h2 看 `tos` `0x1`→`0x3` |
| mri | ❌ | ⚠️ **看得見但讀錯**（`ihl>5`） | G4、G2-C、**G6-A'** | h2 `receive.py` 要看到 swtrace 序列（swid＋qdepth） |
| firewall | ❌（**s1 與 s2-s4 不同程式**） | ✅ | **G4（per-switch 是硬需求）**、G5 | `iperf h1 h2` 通、`h1 h3` 通、**`h3 h1` 要被擋** |
| basic_tunnel | ❌（0x1212） | ❌ **全盲** | G4、G5、**G6** | `send.py --dst_id 2` 要到 **h2 不是 h3**（`show2()` 有 tunnel 層） |
| source_routing | ❌（0x1234＋stack） | ❌ **全盲** | G4、**G6**（G5 不需要：**0 筆 entry**） | h2 收到 2 個、`ttl` ＝ **{59, 62}**、無 SourceRoute 層（**09-08 tutorials harness 實跑 PASS**：solution 收 2 個／`[59, 62]`／0 個 SourceRoute 層／etherType 顯示 `IPv4`，skeleton 收 0 個＋`s1.log` 91 行 drop——**在 tutorials 上，不是 NDTwin**） |
| calc | ❌（0x1234＋`lookahead`） | ❌ **全盲** | G4、**G6**（G5 不需要：entry 寫死在 P4 裡） | `h1 python3 calc.py` REPL：`1+1` 要回 `2` |
| link_monitor | ❌（0x812＋兩個 stack） | ❌ **全盲** | G4、**G5（default-only 表＋每台 swid）**、G6 | 印出的 Mbps 要與 `iperf h1 h4` 對得上（**唯一量化對帳**） |
| load_balance | ❌（ECMP 兩張表＋egress 表） | ✅（外層 IPv4） | G4、G5 | h2/h3 各跑 `receive.py`，**兩邊都要收到**（分佈型斷言） |
| multicast | ❌（無 PRE 就零分） | ⚠️（ARP 是廣播） | G4、**G8** | `pingall`：h1/h2/h3 互通、**h4 不通**（部分連通） |
| p4runtime | ❌（跑時推 pipeline） | ✅ | G4、**G3（含位址對齊）**、G7 | `h1 ping h2` 起初無回應、跑 `mycontroller.py` 後有；counter 每 2 s 遞增 |
| flowcache | ❌（packet-in/out＋clone＋idle） | ❌（CPU 通道） | G4、**G3**、G9a/b、G7 | 控制器起來前無回應、起來後有；counter 要增加 |

**basic 那一列的細節**（全部 **本輪抽查**）：**零改動可跑的依據**＝表名／action 名／參數名／match kind 逐字
相同——`basic/pod-topo/s1-runtime.json` 的 `MyIngress.ipv4_lpm` 與 `MyIngress.ipv4_forward{dstAddr, port}`，
對上 `ndtwin_switch.p4:349-364` 與 `p4_client.py:846-866`。但有三個 ⚠️：
- **pod-topo 仍要走 G2 的三處推導**（選檔只看主機數：4 host 會撞上現有 10 交換機檔；proxy 四等分公式；
  交換機清單寫死十台）。**「零改動」指的是 P4 與表寫入，不含拓樸。**
- **default action 不同 ⇒ Step 1 的失敗形狀不同**：NDTwin 的 `ipv4_lpm` 是 `default_action = send_to_cpu()`
  （`ndtwin_switch.p4:362`）且帶 `ipv4_lpm_counter`，basic 是 `drop()`（`basic.p4:112`，runtime json 也明寫）
  ⇒ **骨架（無 entry）在 NDTwin 上不是 drop 而是 punt 到 CPU port 255**：`pingall` 仍 100% loss（CPU 不回覆），
  **判定不變**，但 proxy 會收到一堆 packet-in、遙測那側會有雜訊。
- **若改載 basic 自己的 pipeline（G4 之後），NDTwin 的 clone 取樣遙測就不存在**
  （`clone_preserving_field_list(…, SAMPLE_SESSION, …)` 是 `ndtwin_switch.p4:411` 獨有）⇒ **「跑得動、
  分身全盲」，與 G6 同形。「零改動」不可讀成「twin 也能觀測」。**

---

## 5. 兩個「測 tutorial 才會暴露」的發現

### 發現① — 位置相依的 metadata id ⇒ 換一支 P4 程式，遙測靜默歸零
**現象**：載入任何非 `ndtwin_switch.p4` 的程式之後，NDTwin 報出來的每一個速率與鏈路使用率都是 **0、而且沒有
任何錯誤訊息**——不是報錯，是報零。
**機制**：遙測鏈路是 `clone_preserving_field_list(I2E, 250)` → egress 認 `instance_type==1` 補 `packet_in`
標頭 → PI 轉 typed metadata → `sample_from_packet_in` **依 id** 讀 → 合成 sFlow → UDP 6343
（`ndtwin_switch.p4:405-448`、`sflow_emitter.py:446-482`）。而 id 是**位置相依**的裸常數 1..5
（`sflow_emitter.py:425-429`，註解自陳）＋ packet-out 的 `1/2`（`p4_client.py:217,222`）。換一支程式，只要
`packet_in` 標頭的欄位順序或數量不同，`sampling_rate` 就讀成 0，而**`sampling_rate == 0` 的樣本被靜默丟棄**
（`sflow_emitter.py:468-470`）。
**為什麼 tutorial 會踩到**：13 支沒有一支的 controller header 長得跟我們一樣，flowcache 的
`@controller_header` 更是它自己的設計。**這條路以前沒人走過，因為十台一直載同一份 p4info。**
**證據等級**：【讀碼推導】🟠（三處行號本輪抽查逐字確認；**沒有實際換過程式驗證歸零**）。
**建議修法**：開機時由 p4info 的 `controller_packet_metadata` **按名字**解析 id（G1 候選 A，~40 行【估】）。

### 發現② — election_id 共用 ⇒ 外部控制器清空全表並回報成功
**現象**：同時掛一個外部 P4Runtime 控制器，它的 `SetForwardingPipelineConfig` 會**被接受、清空每一張表、然後
回報成功**；NDTwin 這一側只看到 stream 斷掉。
**機制**：十個 client 全投寫死的 `election_id (0,1)`（`p4_client.py:234-235`）。P4Runtime 用**訊息裡的三元組**
（不是連線）辨識送出者 ⇒ 冒名者的 stream 被當重複殺掉，但它的 unary RPC 照樣生效（`p4_client.py:60-72`）。
**bmv2 全程符合規格**——對照組：第三方 client 送出的、真正非 primary 的推送會被 `PERMISSION_DENIED` 拒絕。
**為什麼 tutorial 會踩到**：tutorials **普遍自帶控制器**——`p4runtime` 與 `flowcache` 整支的教學重點就是跑
`mycontroller.py`，其餘支還可能用 `simple_switch_CLI`；那與 proxy 是同一個 election_id 的競爭者。**外加**：
`mycontroller.py:167-176` 寫死 `127.0.0.1:50051/dev 0`，NDTwin 是 `GRPC_PORT_BASE=30050`／`device_id=dpid`
（`grpc_ports.py:48`、`main.py:182-186`，本輪抽查）⇒ **連位址都對不上**，兩份輸入都沒列這條。
**證據等級**：**【跑過】🟢 2026-08-13 三情境實測**（`doc/2026-08-13_p4runtime-mastership-spec-check.md`，
`p4_proxy/reference/p4runtime_mastership_probe.py` 可重跑）；位址不符那半是【讀碼推導】🟠。
**建議修法**：election_id 提成參數、NDTwin 用高值（G3 候選 A，~15 行【估】）＋ exercise fabric 的
gRPC base／device_id 對齊 tutorials 的預期。

---

## 6. 建議的實作順序

| 階段 | 做什麼 | 工作量【估】 | 解鎖 | 驗證方式（哪支用 `drive_exercise.py` 跑通） |
|---|---|---|---|---|
| **一** | **G1**（metadata id 按名字）＋ **G3**（election_id ＋ 位址）＋ **G2-A/B**（拓樸三處改讀檔） | ~140 行 | 1 支真跑通、2 支可共存 | `basic --which solution/skeleton` **雙向**跑通（紅綠都看過）（**兩向預期輸出 09-08 已在 tutorials harness 上驗過**：solution 5/5、skeleton 4/4，`runs/`；**要驗的是同樣兩向在 NDTwin 上成立**）；`p4runtime` 的 `mycontroller.py` 能與 proxy 共存而不清表（用 `p4runtime_mastership_probe.py` 當斷言） |
| **二** | **G4**（per-dpid pipeline，A' 兩步）＋ **G5**（`POST /p4/table_entry`，含 default_action） | ~330 行 | **+9 支**（qos／ecn／mri／firewall／basic_tunnel／source_routing／calc／link_monitor／load_balance 的資料面與控制面） | `source_routing`（0 筆 entry、只驗資料面）→ `firewall`（**per-switch 兩份 p4info 同時在線**）→ `link_monitor`（default-only 表＋每台 swid） |
| **三** | **G2-C**（TCLink 整形，獨立進入點）＋ **G6-A'**（`ihl` 修正＋不可見樣本計數）＋ **G7**（`/p4/counter`）＋ **G8**（PRE multicast）＋ **G9a/b** | ~205 行 | **+3 支**（ecn／mri 的判定成立、multicast、flowcache 的 clone/cpu-port） | `ecn`（tos `0x1`→`0x3`）、`mri`（swtrace 序列）、`multicast`（h1/h2/h3 通而 **h4 不通**）、`flowcache`（控制器起來前後） |

🏁 **第二階段之後，tutorial 就可以當 NDTwin 的回歸測試。** 那時「載入任意 pipeline ＋ 依 p4info 寫任意表 ＋
遙測不會因換程式歸零」三件都成立，`drive_exercise.py` 的 exit code（0 全過／1 有一條沒過／2 pre-flight 擋掉）
就是可自動化的閘門，而 **skeleton／solution 兩個方向都有預期輸出**（`DRIVER.md` §3）⇒ **看得到紅，符合
mutation gate 的「沒看過紅不算交付」**。第三階段之前 ecn／mri 會「綠得很可疑」（qdepth 恆 0），**不可放進閘門**。

---

## 7. 附

### 7a. 來源行號索引
- **需求側** `GAP-1`：§1:25-43（維度定義）、§2a:50-64、§2b:68-82、§2c:86-100、§3.6:150-165（flowcache）、
  §3.10:195-205（multicast）、§3.11:207-218（p4runtime）、§3.12:220-229（qos 無 priority queue）、§4a:244-251、
  §4b:255-265、§4c:267-289。**供給側** `GAP-2`：§1:20-39（能力矩陣）、§2 各維度 45-259、§3:263-291（六條架構
  觀察）；本檔**改判**的是 §meters:114-123、§registers:125-134、§queue_metadata:178-188。
- **本輪抽查（我實際讀過那一行）**：`p4_client.py:31-32,60-72,217,222,234-235,338,619,697-704,729,846-866`、
  `sflow_emitter.py:425-429,468-470`、`main.py:113-120,154,182-186`、`ryu_flow_stats.py:40-48,148-154`、
  `topology_manager.py:193-207,332-343`、`mininet/p4_testbed_topo.py:86-134,256-280,655-685`、
  `mininet/grpc_ports.py:39,48,66`、`p4_src/ndtwin_switch.p4:45,48,156-164,224-231,292-315,340-381,405-447`、
  `src/ndt_core/collection/FlowLinkUsageCollector.cpp:1260-1315`、`include/common_types/SFlowType.hpp:31-47`、
  `P4RoutingStrategy.cpp:11-33`。
- **tutorials 樹（根 `/home/adam/tutorials`）**：`utils/run_exercise.py:85-115,258`、
  `utils/p4runtime_switch.py:80-125`、`basic/solution/basic.p4:102-113`、`basic/pod-topo/s1-runtime.json:1-30`、
  `link_monitor/solution/link_monitor.p4:208-214`、`mri/solution/mri.p4:211-217`、
  `load_balance/solution/load_balance.p4:123-132`；全樹 grep：`register<`／`meter`／`enq_qdepth`／
  `deq_qdepth`／`priority_queues`／`"default_action": true`。

### 7b. 我沒讀完的（誠實列出）
- 🔴 **沒有執行任何東西**：沒起 fabric、沒編譯、沒跑 Mininet／bmv2／`ndt`、沒 sudo、沒殺行程、沒改任何既有檔；
  本檔唯一寫入的是它自己。
- 🔴 **bmv2 原始碼一行都沒讀**（這台機器上沒有 `behavioral-model` 樹）⇒「`enq/deq_qdepth` 在單佇列下就有值」
  是從 tutorials 的用法反推的，**機制層【不確定】**。**`FlowLinkUsageCollector.cpp` 只讀了 1260-1315**：
  `ihl` 全檔 grep 0 命中是確定的，但**偏移量錯位的確切後果我沒逐字推完** ⇒【不確定】。
- **`api_routes.py`／`ndt verify_p4`／契約測試我沒讀**，§3 各候選對「會不會動遙測／契約測試」的判斷轉引自
  GAP-2，屬**【只有文件宣稱】**這一級。13 支的 `README.md` 一份都沒讀（需求全部轉引 GAP-1）。
- **兩份輸入我讀完了全文，但它們各自沒讀完的部分我也沒補**：GAP-1 沒讀 13 支骨架 `.p4`、兩支 PTF 的斷言、
  `convert.py`；GAP-2 沒讀 `topology_manager.py` 的 unroute/readopt/watchdog、`ryu_topology.py:191-454`、
  `p4_testbed_topo.py:500-600`、`ndt` 的絕大部分、`p4_proxy/tests/` 的主體。
