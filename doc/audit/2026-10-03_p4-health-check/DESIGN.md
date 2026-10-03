# P4 健檢組合（health-check combo）設計稿 — r6

[Co-developed with claude code -- Adam]

- **依據**：Adam 2026-10-01 form 1 第 2 題【轉述 `scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/RULINGS-1001.md:12-14`】。
- **版本**：
  - r6 是最後幾處精確修正：Q6、Q7 與 CP4；r5 原文在 `DESIGN-r5.md`；
  - r5 只改 §9 的 Q5、Q6、Q7 與它們依賴的格（判官對 r4 的限定範圍複審）；r4 原文在 `DESIGN-r4.md`；
  - r4 是限定範圍的一輪：只修決策表依賴的項目與判官 r3 的四個設計 MAJOR（`judge-DESIGN-r3-e0dcfc73.md`）；可以等 Cut 1 的 MINOR 列在 §12；r3 原文在 `DESIGN-r3.md`；
  - r3 回應 `judge-DESIGN-r2-70d68522.md`（FIX FIRST）；
  - r1 原文在 `DESIGN-r1.md`，r2 原文在 `DESIGN-r2.md`；
  - 逐條處理見 §11。
- **r3 的原則**：能刪或收窄一格、能把限制講清楚，就不加機制。
  - 所以 r3 **拿掉了 N 空白對照**，也拿掉了只靠封包行為下紅燈的格。
  - 程式行為改成「程式自檢」：自檢失敗判 `PROBE-BROKEN`，永遠不判 RED（§2.1）。
- **性質**：純設計。沒起 fabric、沒跑 `ndt`、沒 build、沒 commit。
  - r1、r2 用過的唯讀指令列在 `DESIGN-r2.md` 開頭。
  - r3 加用：`grep -c -a` 掃 fabric 那顆 bmv2 執行檔的字串（不執行它）、`sed`、`ls`。
- **引用**：程式碼一律引 trunk **`995bdfd0`** 的 `檔:行`，都是本系列親自讀過的；被引用的檔 `git status` 都乾淨，唯一例外見 §7.4。
- **證據等級**：
  - 【讀碼】本輪讀過的碼；
  - 【GAP-2b 跑過】GAP-2b 引的 live raw，我沒有重讀；
  - 【轉述】出自報告或記憶，沒驗；
  - 【推論】沒有任何東西證實。

---

## 0. 一段話講完

- **程式**：
  - 一份 `hc_main.p4`，編兩次：照原樣一份，加 `-DHC_ALT` 再一份，多一張表，parser 改以 port 當 key。
  - ingress 的**第一個敘述**是：遇到 0x88B5 就 `mark_to_drop` 接著 `exit`。
  - 另外 `-DHC_MUTANT_*` 只用來做 live 看過紅。
- **包裝**：一份 tutorials 形狀的 exercise 目錄，走現成的 `convert.py` → `preflight.py` → `ndt up p4 --app`。
- **探測器**：`tools/p4_health/` 底下的 Python driver，用 `setsid` 起動。
  - 先跑不用 lab 的靜態段 S0。
  - 再起三次 fabric，依序是 A（ndtwin）、B（external，探測器自己的控制器）、C（roles）。
  - 每次都是 claim → up → 格子 → 停 sniffer／控制器 → 拿掉 netem → down → 還原 knob → release。
- **判格**：
  - NDTwin 那一半一律對照**交換機上的狀態**（thrift 唯讀），或對照 NDTwin 自己的觀測面（link usage、流表、側表），不看封包有沒有被程式正確處理。
  - 封包行為只用在兩個地方：當觀測格的刺激，以及「程式自檢」。
- **紅要有歸因**（§2.1）：
  - `bmv2`：B 的控制器直接對 bmv2 做同一件事，必須成功；
  - `wire`：收端證明線上真相，只有 CH 類用；
  - `structural`：NDTwin 自己宣告「沒有」，加上 bmv2 做得到的證據。
  - 歸因不成立就判 `UNATTRIBUTED`，不計數。
- **輸出**：紅綠表、`health.json`、`00_table.tsv`。
- **時間**：lab 約 19–22 分鐘【推論】，與 §4.4 一致。

---

## 1. 今天的碼長什麼樣（設計用得到的事實）

### 1.1 程式怎麼進 NDTwin

- **package**：一個目錄，有 `package.json` 和 `ndtwin/topology.json`（`ndt:1682`、`app_package.py:964-987`）。
  - `control_plane.mode` 只能是 `ndtwin` 或 `external`（`app_package.py:93-95,1006-1009`）。
  - `bmv2.cpu_port` 一個 package 只有一個值（`:1028-1030`；`convert.py:232-262`）。
  - 其他欄位：`links[]` 整形（`:1032-1034,527-603`）、`telemetry.source`（`:1038-1049`）、`roles`（`:1053`）。
- **`convert.py`**：
  - 不編譯，只抄 `build/` 底下的 artefact（`convert.py:29-33,361-371`）。
  - `--mode {auto,ndtwin,external}` 在 `convert.py:818-819`。
- **`preflight.py`**：
  - 不需要 root（`preflight.py:1-18`）。
  - 會自己編譯一次（`:1211`），**不加 nice**，而且 `ndt up` 每次都會再跑它（`ndt:2064-2077`）。
  - 只讀 runtime JSON（`:1124-1130`）。
  - entry **指名的欄位**是 ternary／range／optional 就 FAIL（`:33-34,60,218-234`）。
  - entries 的 p4info 必須就是該台的 pipeline（`:881-908`）。
  - FAIL 時 `ndt` 回 rc 5（`ndt:3272-3282`）。
- **`ndt up p4 --app`**（`ndt:3227`）：
  - 不另收主機數（`:3256-3259`），主機數由 model 決定（`:3285-3291`）；
  - 會改寫 `host_count_override`，也會寫 `app_package_override`（`:10933-10936`）；
  - 後者由 `ndt down` 清（`:1597-1601`）。
- **工具鏈**：
  - p4c-bm2-ss 1.2.5.15，sha256[:16] `226f3f66df515c9e`；
  - `simple_switch_CLI` 在 `/usr/local/bin`；
  - bmv2-fast 有 thrift（`build_bmv2_fast.sh:154`），port 9091–9100（`p4_testbed_topo.py:214,350,357`）；
  - fabric 那顆 bmv2（`/usr/local/bmv2-fast/bin/simple_switch_grpc`，由 `bmv2_binary_override` 指定）的字串裡有 `priority-queues` 一處：`grep -c -a`，沒有執行它。

### 1.2 proxy 北向

| 端點 | 位置 | 語意 |
|---|---|---|
| `GET /p4/switch_state` | `api_routes.py:697-829` | `pipeline`（p4info sha）`:758-761`；`table_entries`，其中 `journaled` 恆為 false，`:762-767`；`pre_entries` `:788-793`；`capabilities` `:807-810`；頂層的 `control_plane`、`heartbeat` |
| `POST /p4/readopt/{dpid}` | `:656-692` | power-cycle 之後重新寫回 package 的 table 與 PRE（`main.py:1690-1697`） |
| `POST /p4/table_entry` | `:841-957` | 200；400／404／409／**501（ternary、range、optional）**這幾種都什麼都沒寫；502 是交換機拒絕 |
| `GET /p4/counter/{name}` | `:963-1029` | 200／404／503（503 明言不是 0）；external 下也能讀 |
| `POST /p4/multicast_group` | `:1035-1130` | 200／400／404／409／502 |

- **沒有 route 的**：meter、register、digest、packet-in、packet-out、clone session。clone session 只在開機（`main.py:1011-1075`）與 readopt 時寫。
- **開機套 package**：只對外來 pipeline、而且不是 external 的交換機（`main.py:2012-2016`），**每次 proxy 啟動都重套**。
- **clone id**：外來 pipeline 用 package 給的 id（`main.py:1057-1062`）；NDTwin 自己的 pipeline 固定 250（`p4_client.py:29-36`）；id 相同時 proxy 自己的那個贏（`main.py:2031-2036`）。
- **writer**：只建 EXACT／LPM（`p4_client.py:133,1204-1208`）。
- **don't-care**：ternary 的 don't-care key 是「不放進 entry」（`p4_client.py:1655-1662`）。
- **counter**：只掃 `p4info.counters`（`:1598`）。
- **stream**：只處理 packet 與 arbitration（`:526-551`）。
- **packet-in**：只在 telemetry 與 LLDP 之間分流（`:553-586`）。
- **`capabilities` 五鍵**（`main.py:1160-1184`）：
  - `ipv4_route` 是綁定的 owner；**只有 owner 是 `ndtwin`，kernel 才寫那張表、fabric 才會改路**（`route_binding.py:51-56,312-319`、`main.py:1236-1249`）。
  - 改路還要心跳 `usable`（`main.py:1290-1304`）。
  - owner 是 `ndtwin` 時，package 自己給那張表的 entries 會被 pre-flight 拒絕（`route_binding.py:51-53`）。

### 1.3 kernel

- **`P4Capabilities`**：把 proxy 的物件原樣抄到 `get_graph_data`，最多落後一輪 1 Hz（`P4Capabilities.hpp:4-19,41-44`、`.cpp:67-75`、`HttpSession.cpp:1417-1430`）。⇒ 健檢讀 `switch_state`，不讀它。
- **meter**：在 P4 上回 501 `unsupported_on_p4`（`HttpSession.cpp:279-281,416-427,2019-2024`、`P4RoutingStrategy.cpp:10-33`）。
- **側表**：
  - 上限 1024，IPv6 會一直產生新 key（`FlowLinkUsageCollector.hpp:740-747`、`.cpp:1060-1090`）；
  - 經 `non_ipv4_flows` 供應（`.cpp:1134-1161`）；
  - L2 那一列帶 `src_mac`、`dst_mac`、`ethertype`，還有 `samples`（`SFlowType.hpp:587-589`、`.cpp:1139-1141`）。
- **frame 身份**：`identifyFrame`（`SFlowType.hpp:267`、`.cpp:1510`），剝一層 VLAN（`SFlowType.hpp:305-311`）。
- **link telemetry**：
  - 取樣 1/256、截 128 B（`link_telemetry.py:69,75`）；
  - **每個埠都有 ingress 取樣**（`:312,329-338`）⇒ 從主機送出的幀，在程式處理之前就被取樣了。

### 1.4 心跳

- `ndt` 在每個外來 pipeline 上都起心跳（`ndt:3008-3013`）。
- 在 external 上，要 `heartbeat_drop_check.py` 證明程式會丟 0x88B5 才起（`ndt:2959-2971,3022-3033,3330-3335`）；沒起就寫 `.test_run/heartbeat.withheld`（`:2974,3025-3032`）。
- **drop check 只檢查「沒有 entries 時的 default action」**（`heartbeat_drop_check.py:36-41`），用的是拋棄式 stock simple_switch、pcap 模式、不需要 root（`:14-22`）。
- 心跳幀會進 package 的程式（`main.py:1403-1407`）；送到主機就觸發停止條件（`link_heartbeat.py:100`、`main.py:1429-1430`）。
- proxy 在任何外來 fabric 上都起 watchdog（`main.py:2326-2332`）。所以判準是 `heartbeat.state=="usable"`（`main.py:1418-1419`），不是「不為 null」。

### 1.5 可抄的東西與 sudo

- **`drive_exercise.py`**：
  - 生命週期在 `:2776-3047`；
  - teardown 先停控制器、再 `ndt down`（`:3018-3027`）；
  - 再來是 knob 與 release（`:2685-2726`）；
  - mnexec 在 `:1006-1045`；
  - `NDT` 寫死在 `:92`；
  - **沒有訊號處理、沒有 lab 狀態檔、沒有 netem 帳**。
- **`06_thirteen.sh`**：不 claim（`:20-24`）；沒有 owner 就拒（`:43-48`）；euid 0 也拒（`:63-71`）；有 `DRIVER_UNDER_TEST` seam（`:34-38`）。
- **`code_identity.py:1-40`**：記錄 HEAD、未提交的程式碼、kernel、bmv2 與 lib、stock simple_switch、`ndtwin-lab`、兩個 venv。
- **sudo**：
  - 手冊只教 `ndtwin-lab`；tc 與 mnexec 的授權都不在手冊裡（`sudo_surface.sh:9-19`）。
  - 這台機器的 mnexec 授權很寬：`faults.sh:60,68` 用 `sudo -n mnexec -a 1 kill`。
  - tc 的 grant 包含 `qdisc del dev s*-eth* root`（`faults.sh:54-56`）。而 `del root` 會靜默毀掉 TCLink 的 htb，所以一定要配 `qdisc_snapshot.sh` 做前後比對（`faults.sh:15-20`、`tools/test_workflow/qdisc_snapshot.sh:1-15`）。

### 1.6 和舊文件對不上的地方

1. **external 心跳**：GAP-2b 說是 null【GAP-2b 跑過】；碼裡有 watchdog，daemon 要過 drop check（§1.4）。「碼比較新」是推論。
2. **clone 寫死 250**：`PAPER-APPS-CANDIDATES.md:63` 的說法，對外來 pipeline 已經過時（§1.2）。
3. **int-v1**：
   - INT 在 L4 之後【轉述 `RULINGS-1001.md:59-64`】。
   - ternary entry 是 thrift `table_add`（`/home/adam/paper-apps/int-v1/runtime_cmds/s1.sh:21`）。
   - 還需要 `s1.sh:7` 的 `tb_set_source`：`int.p4:42-43` 只在 source 旗標成立時才套 `tb_int_source`。
   - `tb_int_source` 的 default 是 `nop`（`include/int_source.p4:67-83`）。
   - 腳本打的 thrift port 是 9090（`s1.sh:2-4`），NDTwin fabric 是 9091 起（`p4_testbed_topo.py:350`）。
   - varbit 在 `include/parser.p4:70`。
4. **ONTAS 的 VLAN**：native 已經會剝（`SFlowType.hpp:305-311`）。
5. **行號漂移**：GAP-2b 的 `api_routes.py:958` → `:963`；記憶的 `:871,924` → `:876`、`:925-930`。

---

## 2. 功能清單：16 維 → 探測格

### 2.1 判定規則

**判定詞彙**：

| 判定 | 意思 |
|---|---|
| GREEN | NDTwin 的觀測與獨立 oracle 一致 |
| PARTIAL(a\|b\|c\|d) | 理由同 GAP-2b §0.3 |
| RED | NDTwin 明確答「沒有」或「錯」，**而且**該格寫明的歸因成立 |
| UNATTRIBUTED | 看起來紅，但歸因不成立；不計數 |
| NOT RUN | 刺激沒發生，或 oracle 讀不到；永遠不算綠 |
| READ-ONLY | 只在論文 app 模式出現，只比讀數 |
| PROBE-BROKEN | 已知答案的對照，或程式自檢不符。該格與依賴它的格都判這個；整輪 rc 1，表標「不可發佈」 |

**判定順序（r3：解決判官的優先序問題）**，逐格依序走，先命中先決定：

1. **NDTwin 的「做不到」答案**：openapi 沒有這個 route、404「不在 pipeline」、501、恆定欄位。命中就直接是 RED 候選（再看歸因），**不需要也不讀 oracle**。
   - 只適用於「對這一格而言表示 NDTwin 做不到」的答案。**預期中的拒絕不算**：CP2 的 409、K1-neg 與 T3-neg 的 404 都是該格的及格條件，留到第 5 步判。
2. **依賴的 gate 格與程式自檢**（規則 D，見下）：
   - 依賴的 gate 格不是 GREEN → 本格 NOT RUN，理由寫明「gate <id> <判定>」；
   - gate 格都 GREEN、但依賴的自檢不成立 → PROBE-BROKEN。
3. **刺激**：以 sender **自己回報**的送出數為準；0 → NOT RUN。static 格跳過這一步。
4. **oracle 讀不到** → NOT RUN。
5. **比較** → GREEN、PARTIAL 或 RED。

> **r2 (Cut 1 review)** 新增三步，詳見 §14.1：
> - **0. NDTwin 的答案讀不到**（proxy／kernel 沒回 2xx JSON）→ NOT RUN。沒有 NDTwin 那一半的格（P1、P4、Q2、CS1、TTL1）不走這步。
> - **0b. 該格的對照**（K1 的 K1-neg、T3 的 T3-neg）不是 GREEN → 沒觀測到就 NOT RUN，答錯就 PROBE-BROKEN。對照要的是端點自己的 404 `{"error": "not in this pipeline"}`；FastAPI 的路由不存在 404 不算。
> - **4b. 該格需要的讀數缺了**（答案或 oracle 裡沒有那個鍵）→ NOT RUN。缺鍵是沒讀到，不是相符。

> **r4 (Cut 1 follow-ups)**：判定順序本身沒動，但兩條讀數規則寫明了（細節見 §14.7）：
> - **計時讀數的編碼要先驗**（TP2／TP4／CP4／IT1 在比較之前）：值必須是 `never`，或 0 ≤ s ≤ 自己的 `watched_s` 的數字；`watched_s` 本身必須是 ≥ 0 的數字。負數、不是正本拼法的 `Never`／`NEVER`、比自己的 `watched_s` 大的數字、布林，一律 **PROBE-BROKEN**（觀測器的錯，不是 NDTwin 的，也不是綠）。
> - **觀測器的契約**：觀測器「讀了、那裡什麼都沒有」要寫成 `False` 或 `0`（或空 list），**不能寫成 `None`、也不能省略那個鍵**。`None`／缺鍵是「沒讀到」，步驟 4b 會把它變成 NOT RUN；一個把「讀了沒有」編成 `None` 的觀測器，會把壞掉的 emitter 該得的 RED 變成 NOT RUN。Cut 2–4 的觀測器照這條寫。

**程式自檢**（不進 rollup；失敗就 PROBE-BROKEN，不判 RED）：

| 自檢 | 內容 |
|---|---|
| SC-fwd | marker pingall 30/30，而且 thrift `table_dump` 證明 T1 的 entries 都在 |
| SC-count | `c_in` 的 thrift 差＝sent |
| SC-reg | marker 寫了 register 之後，thrift `register_read` ≠ 0 |
| SC-qstamp | 收到至少一個帶 0x8000 旗標的包 |
| SC-ttl | 收端的 ttl＝64−跳數；跳數取自 TP1 讀到的 fabric 算出的路徑 |

- **為什麼不判 RED**：這些行為是我們的程式加上 bmv2 的事。NDTwin 會影響它們的那幾條路，各自由一個 **gate 格**守著：
  - 載錯程式 → PL1；
  - 寫錯 entries → T1；
  - 接錯線 → TP1；
  - host offload → CS1。
- **規則 D（r4）**：
  - gate 格本身照常判，它的 RED 會進表，也會進 rollup；
  - gate 格不是 GREEN 時，依賴它的自檢與格一律判 NOT RUN 並寫明原因，**整輪仍可發佈**；
  - 只有在所有相關 gate 格都 GREEN、自檢仍不成立時，才判 PROBE-BROKEN。
  - 依賴關係：SC-fwd → PL1、T1、TP1；SC-count、SC-reg、SC-qstamp → SC-fwd；SC-ttl → SC-fwd、TP1。
- **剩下的風險**：某個不在任何 gate 格裡的 NDTwin 故障，仍會表現成 PROBE-BROKEN。這是保守的方向——不會因此出現假紅，也不會出現假綠。

**同窗負讀（r4，取代 N 的作用）**：

- 每一個「thrift 讀到相符」的 GREEN，都要配一個同一個窗內的「thrift 讀到不在」。
- **凡是「寫入之後相符」的格，負讀一律是「寫入之前不在」**（r5 補齊：T3、T4–T7、M2、C2、MT1–MT3、R3）。
- 這樣，thrift 讀取層要是把錯誤或空回覆當成相符，負讀就會不通過，判 PROBE-BROKEN。
- 逐格的負讀寫在 §2.3。

**格的種類**：`active`（要送刺激）或 `static`（只讀）。

**歸因**：

- `bmv2`：B 的控制器做同一件事，用 thrift 讀到它生效。
- `wire`：收端證明線上真相，只用在 CH4。
- `structural`：NDTwin 自己的宣告，例如沒有 route、501、`journaled` 恆為 false、argv 沒有該旗標。
  - 如果該功能也是 bmv2 的功能，還要加 `bmv2` 或 static 證據（例如 Q2 用 binary 字串）。
  - T8 的 journal 純屬 NDTwin，所以 `structural` 一種就夠。

**marker**：

- 每個 active 刺激都用 sender 主機的 MAC、該格專屬的 UDP dport（40001–40099），payload 開頭是 `b"NDTHC"`＋run id＋格 id＋序號。
- 非 IP 的幀用該格專屬的 ethertype（§2.3）。
- counter、register、meter、digest、punt **只作用在各自的 dport 上**；sniff 只數 magic 與格 id 都對的幀。
- 每個 sniff 窗都另送一顆「活著」marker，必須收到。

**心跳**：

- ingress 的第一個敘述：`if (hdr.ethernet.etherType == 0x88B5) { mark_to_drop(standard_metadata); exit; }`。parser 對 0x88B5 直接 accept。
  - 理由：v1model 裡 parser reject 不會丟包；排在後面的 action 又可能把 `egress_spec` 改回去【轉述判官 r2，與 v1model 語意一致；推論】。
- S0 對三個 package 跑 drop check，rc 必須 0；對 FWD 變體必須 rc 1；任何其他結果 → PROBE-BROKEN。
- **drop check 的覆蓋限制**：它只證明 default action 會丟（§1.4）。A、C 的 runtime entries 由「ingress 第一句就 exit」這個構造保證碰不到它，但 drop check **證明不了**這一點。
  - 剩下的偵測只有每次 bring-up 結束前查 `frames_reached_hosts`（必須是 false 或 null）。那是事後偵測：真的有幀送到主機的時候，停止條件已經觸發過了。

**route 存在與否**：讀 `/openapi.json`。【推論】FastAPI 預設會提供它（`main.py:38` 沒關），Cut 1 用 TestClient 驗。

**`scope`**：`core` ＝ 13 支 exercise 用到的構造；`ext` ＝ 其餘。

**oracle**：一律不經 NDTwin。

- `thrift`：唯讀 `table_dump`、`show_tables`、`counter_read`、`register_read`、`meter_get_rates`、`mc_dump`、`mirroring_get`、`show_ports`。
- `ps`：bmv2 行程的 argv。
- `fabric`：veth 對端，加上每台 host namespace 裡的 IP 與 MAC，加上 `show_ports`。
- `netdev`：`/proc/net/dev`。
- `tc`：`tc qdisc show`。
- `sniff`：scapy，在 host namespace 裡跑。

### 2.2 拓樸（三次 bring-up 共用一份 model）

```
   h1 h2 h3                h4
    \ | /                  |
     s1 ── p4 ─── p2 ──── s2 ── p3 ─── p2 ── s4 ── h6
      └─ p5 ─(0.5 Mbit/s)─ p2 ── s3 ── p3 ─── p3 ┘
                                 |
                                 h5
```

- s1 跑 hc_alt，s2–s4 跑 hc_main。
- 整形：s1:p5↔s3:p2 0.5 Mbit/s。
- PRE：multicast group 1、2；clone session 7，在 s2 上鏡射到 p1。
- `telemetry.source` 明寫 `link`。
- 三個 package 各有各的 runtime 檔：
  - A：lpm 與 exact，加上 PRE；
  - B：external，不帶 entries；
  - C：roles owner `ndtwin`，**不帶** `ipv4_lpm` 的 entries（`route_binding.py:51-53`）。

### 2.3 格子表

| 維度 | 格 | scope／種類 | GREEN（NDTwin 那一半） | RED（歸因） | oracle |
|---|---|---|---|---|---|
| `pipeline_load` | PL1 | core／static | `switch_state` 的 `pipeline` sha：s1＝hc_alt、s2–s4＝hc_main（S0 的 artefact sha）；**而且** thrift `show_tables` 只有 s1 列得出 hc_alt 多的那張表 | 錯台（`structural`） | thrift |
| | PL2 | core／active | B：`skipped` 含 `pipeline_push`（`main.py:337`）；控制器的仲裁回覆說它是 primary（proxy 沒有搶 mastership），而且它的 SetForwardingPipelineConfig 回 OK。**不用 thrift `show_tables`**：bmv2 開機時 argv 上就帶著 package 的 JSON（`p4_testbed_topo.py:217-218`），表的集合分不出有沒有人推過 | proxy 推了，或控制器不是 primary | 控制器 log |
| `tables` | T1 | core／active | 每台 `recorded==applied`、`failed==0`；thrift `table_dump` 逐筆相符。負讀：每台的 dump 裡，**只宣告給別台**的那一筆 host 路由必須不在 | failed>0 或 dump 不符（`structural`） | thrift |
| | T2 只有 default | core／static | package 在 s2 給的 runtime default 是 `stamp(0x2A)`，**與編譯時的 `default_action`（`stamp(0)`）不同**。applied；thrift 在 s2 顯示 `stamp(0x2A)`。負讀：沒給 runtime default 的 s3 顯示編譯時的 `stamp(0)` | 不符 | thrift |
| | T3 runtime exact | core／active | 負讀：寫入前 thrift dump 沒有這一筆。然後 `POST` 寫 `port_exact` 回 200，thrift dump 有這一筆。T3-neg：寫一張不存在的表，**回 404 就算及格** | 非 200 | thrift |
| | T4 ternary | ext／active | 負讀：寫入前 dump 沒有這一筆。然後 200，thrift dump 有這一筆、遮罩與 priority 都對 | **今天**：501（`api_routes.py:925-930`）（`structural`＋`bmv2`） | thrift；B |
| | T5 range | ext／active | 同 T4 | 今天 501 | 同上 |
| | T6 optional | ext／active | 同 T4 | 今天 501 | 同上 |
| | T7 priority | ext／active | 負讀：寫入前兩筆都不在。然後兩筆重疊的 entry，thrift 顯示的 priority 次序對 | T4 紅時判 NOT RUN | 同上 |
| | T8 journal | ext／static | 一筆 POST 寫進去的 entry 帶 `journaled==true`；重啟後持久那一半**延後** | **今天**：恆為 false（`api_routes.py:765-767,837-838,957`）（`structural`） | — |
| | PF-T | ext／static | 開機 entry 指名 ternary 欄位，pre-flight 通過 | **今天**：FAIL「G5 not done」（`preflight.py:218-234`）（`structural`＋同 T4 的 `bmv2`） | 不需要 lab |
| `pre_multicast` | M1 | core／static | `pre_entries.multicast.applied==recorded`；s1 的 `mc_dump` 顯示 group 1＝{p1, p2}。負讀：s2–s4 的 `mc_dump` 沒有 group 1 | 不符 | thrift |
| | M2 | core／active | 負讀：寫入前 `mc_dump` 沒有 group 2。然後 `POST` group 2 回 200，`mc_dump` 有它 | 不符 | thrift |
| `pre_clone` | C1 | core／static | `pre_entries.clone.applied==1`；s2 上 `mirroring_get 7` 讀出 mgid（預期是 0x8000+7，`p4_client.py:780-786`），再 `mc_dump` 那個 group，結果是 {p1}。負讀：s1、s3、s4 上沒有 session 7【今天是 GAP-2b 的 (c)：GAP-2b:91】 | 不符 | thrift |
| | C2 runtime | ext／static | openapi 有 clone 端點；負讀：寫入前 `mirroring_get 9` 沒有 session 9。寫入之後看得到它，它的 mgid `mc_dump` 出來是宣告的埠 | **今天**：沒有 route（`structural`＋`bmv2`） | B |
| `counters` | K1 | core／active（依賴 SC-count） | `GET /p4/counter/c_in` 的差＝thrift 的差。對照 K1-neg：不存在的名字必須 404 | 404／503，或兩者不等（`structural`；thrift 就是證據） | thrift |
| | K2 direct | ext／active | 前提：刺激之後 thrift 讀到的 direct counter ＞0，而且＝sent，否則 NOT RUN。然後 NDTwin 讀到的值＝thrift | 預測 404（`p4_client.py:1598`，推論）（`bmv2`） | B |
| | K3 external | core／active | B：200 且＝thrift（`api_routes.py:987-990`） | 不符 | thrift |
| `meters` | MT1 | core／active | 負讀：寫入前 `meter_get_rates` 不是要寫的那組速率。然後 `/ndt/install_meter_entry` 回 200，`meter_get_rates` 顯示寫進去的速率 | **今天**：501 `unsupported_on_p4`（`structural`＋`bmv2`） | thrift；B |
| | MT2 | core／static | openapi 有 meter 端點；寫入前 thrift 不是那組速率，寫入之後是 | **今天**：沒有 route（同上） | 同上 |
| | MT3 direct | ext／static | 同 MT2，對象是 direct meter | 今天同上 | 同上 |
| `registers` | R2 讀 | core／active（依賴 SC-reg） | openapi 有讀端點，讀到的值＝`register_read` | **今天**：沒有 route【GAP-2b 跑過：GAP-2b:94】（`structural`＋thrift） | thrift |
| | R3 寫 | core／static | 負讀：寫入前 `register_read` 不是要寫的那個值。寫入之後是 | **今天**：沒有 route（`structural`＋`bmv2`；bmv2 PI 不支援的話判 UNATTRIBUTED） | B |
| `digest` | D1 | core／active | NDTwin 有出口，內容＝marker 的欄位 | **今天**：stream 收到就丟（`p4_client.py:544-545`）（`structural`＋`bmv2`） | B 收到 DigestList |
| `packet_io` | P1 | core／static | `ps` 看到 bmv2 的 argv 有 `--cpu-port 510`（用 `--thrift-port 909N` 找到行程） | 沒有 | ps |
| | P2 packet-in | core／active | NDTwin 有出口交給 app | **今天**：只在 telemetry／LLDP 之間分流（`structural`＋`bmv2`） | B 收到 |
| | P3 packet-out | core／active | NDTwin 有端點，封包從指定埠出去 | **今天**：沒有 route（同上） | B 送、sniff 收 |
| | P4 external | core／active | B：控制器收到 dport 40050 的 packet-in | PARTIAL(b) | 控制器 log |
| `custom_headers` | CH1 tunnel 0x1212 | core／active | G1：on-path 集合非空、主路徑積分 >0、非路徑 <1 樣本（`_common.sh:911,1065-1140`）；**而且**流表有 sender 的內層 5-tuple | PARTIAL(a)：只在側表，`ethertype==0x1212`、`src_mac`／`dst_mac`＝這一對 host，且 `samples` 在窗內增加；RED：連這一列都沒有 | netdev＋sender argv |
| | CH2 stack 0x1234 | core／active | 同 CH1 | 今天 PARTIAL(a) | 同上 |
| | CH3 IPv4 option | core／active | 流表 port 正確 | 預測綠（`SFlowType.hpp:343-369`；模型跑過【轉述 parser-autoderive `REPORT.md:233`】） | sender argv |
| | CH4 shim 夾在 IPv4 與 UDP 之間 | ext／active | 流表 port＝真 port，或者揭露「無法解」、不進流表 | **今天預測**：讀錯【轉述 `RULINGS-1001.md:59-64`】（`wire`：收端剝掉 shim 之後的真 port） | sniff |
| | CH5 VLAN | core／active | 流表 5-tuple 正確 | 預測綠 | sender argv |
| | CH6 shim 在 L4 之後 | ext／active | 流表 5-tuple 正確 | 預測綠 | sender argv |
| | CH7 非 IP 單頭 | core／active | G1，加上側表一列：`ethertype==0x1236`（與 CH2 的 0x1234 分開）、MAC 對＝這一對 host、`samples` 在窗內增加 | 缺任何一半 | netdev |
| | CH8 port-keyed parser | ext／active | 經 s1 的 tunnel 流量身份正確 | 今天 PARTIAL(a) | sender argv |
| `queue_metadata` | Q1 | core／active（依賴 SC-qstamp）；**排在 A 的最後** | 前提：`tc qdisc show dev s1-eth5` 與 `s3-eth2` 都有 0.5 Mbit/s，否則 RED。送 `id=0`、2 Mbit/s、10 s；GREEN：至少一包的 qdepth（低 15 位）>0 | 有整形、有戳、但 qdepth 恆為 0 → UNATTRIBUTED。跑完查 `heartbeat.missing_directions` 並揭露 | tc＋sniff |
| | Q2 priority | ext／static | `ps` 看到 bmv2 的 argv 有 `--priority-queues` | **今天**：沒有（`p4_proxy/mininet/` 0 處命中）（`structural`＋binary 字串，§1.1） | ps |
| `checksum` | CS1 | core／static | 每台 host 的 `ethtool -k` 顯示 tx-checksumming off（`p4_testbed_topo.py:474-491`） | on | mnexec ethtool |
| `ttl_or_hop` | TTL1 | core／active（依賴 SC-ttl） | 這維沒有 NDTwin 的那一半（GAP-2b:39），只要 marker 送到收端就是 GREEN | 不會 RED；ttl 不對就是 SC-ttl → PROBE-BROKEN | sniff |
| `topology` | TP1 | core／static | `get_graph_data` 的交換機、主機（IP、MAC）、邊、埠，與 fabric oracle 逐項相等 | 任何一項不一致 | fabric |
| | TP2 | core／active；**排在 Q1 之前** | 前提：`state=="usable"` 而且 `missing_directions` 是空的，否則 NOT RUN。對 s2–s4 下 netem 之後 ≤20 s，邊變成 `is_up=false`；拿掉之後恢復 | 超過 20 s | netem＋qdisc 快照 |
| | TP4 external | core／active | B：前提是 drop check rc 0、沒有 withheld 檔、`usable`，否則 NOT RUN；判準同 TP2 | 超過 20 s；GAP-2b 判紅，碼預測綠（推論） | 同上 |
| `control_plane_mode` | CP1 | — | ＝T1 | — | — |
| | CP2 | core／active | B：`POST` 回 409——**這是及格的答案，不是 RED 候選**；同一份 thrift dump 沒有那一筆，但**有**控制器自己的那一筆 | 回 200 或真的寫進去 | thrift |
| | CP4 roles | core／active | C：前提是 `heartbeat.state=="usable"`，否則 NOT RUN。`switch_state` 的 `ipv4_route=="ndtwin"`、`binding_source=="package"`、`reroute==true`；thrift dump 有 kernel 寫的路由；負讀：剪線前 s1 往 h6 的 entry **不指** p5；netem 剪 s2–s4 之後，期限內同一筆改指 p5 | 不符 | thrift |
| `verification` | V1 | core／active | G1，IPv4 iperf | RED／NOT RUN | netdev |
| | V2 | core／active | 拿 CH1、CH2 的流量：位元組＝netdev，身份在流表 | 今天 PARTIAL(a) | netdev |

**對照與看過紅**：

- 對照：K1-neg、T3-neg（404 就算及格），加上各格的同窗負讀。
- **telemetry `none` 那一次**（合併了 r2 的 V3 與 L4）：用 A 的 package 加 `--telemetry none` 起一次，只跑 V1、CH1、CH7。
  - `assert_link_usage_absent`（`_common.sh:1140-1145`）必須成立：on-path 集合非空、主路徑積分恰為 0。
  - V1、CH1、CH7 必須是 RED。
  - 不符 → PROBE-BROKEN。

**r3 拿掉的格**（理由見 §11）：

- C3：NDTwin 的那一半和 C1 相同。
- CH9：NDTwin 的那一半和 CH6 相同；varbit 照樣編進 hc_main，所以 p4c／bmv2 會吃到它，但不成格。
- CS2、CS3、R1、CP3、PL1 的打戳：純屬程式語意。
- r2 的 N：整次 bring-up 拿掉。

**計數**：

- core 34 格（不含 CP1，因為它就是 T1）；
- ext 13 格；
- 對照 2；
- 程式自檢 5；
- telemetry-none 一次。
- 依 bring-up 分：A 40 格（含 static；另有 2 個對照、5 個自檢；PF-T 在 S0 跑）；B 5 格（PL2、K3、P4、TP4、CP2），外加 11 項歸因；C 1 格（CP4）。合計 40＋1＋5＋1＝47＝34＋13。

**刺激量**：身份格每格送 ≥5000 幀（取樣率 1/256，`link_telemetry.py:69`）；一個樣本都沒抽到 → NOT RUN。

### 2.4 一支程式或一次 bring-up 放不下的東西

| 衝突 | 依據 | 處置 |
|---|---|---|
| mode 一個 package 一個值 | `app_package.py:1006-1009` | B 另開一次 |
| cpu_port 一個 package 一個值 | `app_package.py:1028` | 三次都用 510 |
| 開機帶 ternary 欄位 ⇒ rc 5 | `preflight.py:218-234`、`ndt:3272-3282` | runtime 用 POST 試；開機那一半做成 PF-T（另一份 package 變體，只跑 pre-flight） |
| roles owner `ndtwin` ⇒ package 自己的 lpm entries 被拒 | `route_binding.py:51-53` | C 另開一次 |
| clone 底下是 mgid 0x8000+session | `p4_client.py:780-786` | group 1、2；session 7 |
| 心跳幀會進每支外來程式 | `main.py:1403-1407` | ingress 第一句就丟 |
| Q1 灌 s1–s3 會影響心跳 | 判官 r2 | TP2 排在前、Q1 排在最後 |
| port-keyed parser 只能放一台 | 【轉述 REPORT.md:35-37】 | 只放 s1 |
| header union、value_set、recirculate／resubmit、action profile／selector、idle timeout、hash／random | 不在 16 維裡 | 第一版不放（Q3） |

---

## 3. 測試程式

- **一份原始檔**：`hc_main.p4`，加 `-DHC_ALT` 多一份。
  - 不選「每維一支」：16 次 bring-up。
  - 不選「一次全包」：mode、roles、開機 ternary 互相衝突（§2.4）。
- **構造**：
  - parser：ethernet → {0x88B5 直接 accept, vlan, 0x1212, 0x1234 stack, 0x1236, ipv4（options）→ {udp → varbit 尾段, tcp, shim}}；
  - 表：lpm、exact、ternary、range、optional、direct counter、default-only、`q_stamp`；
  - 外部物件：counter、meter、direct_meter、register、digest；
  - 複製：clone I2E、mcast_grp；
  - controller header：packet_in／packet_out；
  - 其他：IPv4 checksum update、enq_qdepth、TTL。
- **live 變體**：`-DHC_MUTANT_NO_COUNT -DHC_MUTANT_NO_TTL -DHC_MUTANT_NO_QSTAMP` 合在同一份 artefact。另有 `-DHC_MUTANT_FWD_88B5`，只給 S0 用。
- **架構**：v1model on bmv2。
- **編譯**：`nice -n 19 p4c-bm2-ss --p4v 16 [-D…] --p4runtime-files … -o … src/hc_main.p4`，形狀同 `preflight.py:1211`，一次一支，記錄每份 artefact 的 sha。
  - ⚠️ `ndt up` 自己的 pre-flight 每次 bring-up 會**不加 nice** 再編一次（§1.1）。這裡只揭露，不改 `ndt`；【推論】每次多 5–10 s。
- 【推論】這些構造能不能一起編過，是 Cut 1 的第一個斷言；編不過就拆成兩份。
- **包裝**：
  - 出貨 `tools/p4_health/exercise/`：`topology.json`、A／B／C 的 runtime 檔、`src/`。
  - 每輪：編譯到 run 目錄的 `build/` → `convert.py` 產三個 package（B 加 `--mode external`，C 加 `--role-ipv4-route owner=ndtwin,…`）→ `preflight.py`。
  - 這是 T06 跑過的路【GAP-2b 跑過：GAP-2b:88-89】。

---

## 4. 探測器

### 4.1 放哪、怎麼組（Q1 建議 (a)）

`tools/p4_health/` 底下：

| 檔 | 內容 |
|---|---|
| `probe.py` | 主程式 |
| `cells/*.py` | 判定用的純函式 |
| `collect/*.py` | 讀取層：proxy、kernel、thrift、ps、tc、fabric、sniff |
| `lab_round.py` | 生命週期 |
| `controller_ext.py` | B 用的控制器 |
| `recover.sh` | 當機後收拾 |
| `expected_today.tsv` | 預註冊的預測 |
| `exercise/` | 程式與拓樸 |

- **所有子行程都經過同一個注入的 `Runner`**：sudo、mnexec、tc、ndt、`simple_switch_CLI`、ps、ip、ethtool。
- proxy／kernel 的 URL 與 knob 路徑都從同一個 `Config` 物件拿。

### 4.2 一輪怎麼跑

```
run.sh = setsid nice -n 10 python probe.py … > runs/<run>/probe.log 2>&1
S0（不用 lab，約 2 分鐘）
   compile（3 份＋mutant）-> 清點 -> convert ×3 -> preflight ×3 ＋ PF-T 變體（必須 FAIL）
   -> drop check：三個 package 必須 rc 0，FWD 變體必須 rc 1，其他任何結果 -> PROBE-BROKEN
   -> 讀 `ndt status --measuring` 與 claim 檔：有人在量 -> rc 2，什麼都不動
每次 bring-up X（A、B、C；外加 telemetry-none 那一次）：
   寫 LAB_STATE.json {pid, owner, bring_up, phase:"pre-claim", knob_snapshot, netem:[], qdisc_before}
   snapshot 兩個 knob（這一次的 bytes）
   ndt claim 45 "p4-health <run> <X> state=<LAB_STATE.json>"   拿不到 -> 整輪 INCOMPLETE（不用 --force）
   **r6**：claim 成功後立刻從 claim 檔讀 `expires`，寫進 `LAB_STATE.claim_expires`（讀不到、或 owner 不是自己 → phase `claim-unverified`，不往下 up）
   ndt up p4 --app <pkg>（**r6**：<pkg> 是這一輪自己的副本，放在這一輪的 run 目錄裡）-> 讀 switch_state、openapi、fabric、`qdisc_snapshot.sh save`
   逐格（順序：static -> active，TP2 在 Q1 之前，Q1 最後）
   結束前查 frames_reached_hosts
   finally（例外、SIGTERM、SIGINT、SIGHUP）：
      停 sniffer、停 B 控制器 -> 拿掉 netem -> qdisc 快照比對 -> ndt down
      -> 還原兩個 knob（app_package_override 不碰）-> ndt release
```

- **B 的控制器**：
  - 寫成 tutorials 的 `mycontroller.py` 形狀，經 `tools/p4_exercise/run_external_controller.py` 改寫連線（`run_external_controller.py:1-30`；`ndt:4116-4122` 就指向它）。
  - 負責推 pipeline、寫 lpm，並提供 11 項歸因：
    1. ternary
    2. range
    3. optional
    4. priority
    5. MeterEntry
    6. DirectMeterEntry
    7. DigestEntry 加收 DigestList
    8. CloneSessionEntry
    9. RegisterEntry 寫
    10. DirectCounterEntry 讀
    11. packet-in 與 packet-out
  - 每一項都用 thrift 或收端確認生效。
  - 【推論】`p4runtime_lib` 涵蓋其中一部分，其餘用 `p4runtime_pb2` 直接組。
- **刺激**：
  - 經 `sudo -n mnexec -a <pid>`，pid 用末欄規則（`drive_exercise.py:1024-1038`）；
  - scapy 在 `/home/adam/p4dev-python-venv/bin/python`（`06_thirteen.sh:39`）；
  - 不用 tcpdump【轉述：記憶 index 05】。
- **netem**：
  - 用 `faults.sh` 那套 tc，s2–s4 這兩個介面沒有整形；
  - 下之前寫進 `LAB_STATE.netem`；
  - 前後用 `qdisc_snapshot.sh` 比對，必須相同（`faults.sh:15-20`）。
- 不用 `pkill -f`、`pgrep -f`；行程一律用 pid 停。

### 4.3 輸出

- **終端機表**：`維度 | 格 | scope | 判定 | 歸因 | 預期 | Δ | 理由`，下面是兩組 rollup（§5.1）。
- **`runs/<UTC>_p4_health/health.json`**：

```json
{"run": "...", "probe_version": "<tools/p4_health tree sha>",
 "lab_surface": {"probe": "...", "ndt": "...", "ndtwin_lab": "...", "bmv2": "...", "bmv2_libs": "...",
                 "stock_simple_switch": "...", "p4c": "226f3f66df515c9e", "faults_sh": "...", "qdisc_snapshot_sh": "..."},
 "system_under_test": "<code_identity.py record path>",
 "s0": {}, "bringups": [{"id": "A", "up_rc": 0, "down_rc": 0, "release_rc": 0, "knobs_restored": true,
                         "heartbeat_state": "usable", "frames_reached_hosts": false, "seconds": 0}],
 "self_checks": {"SC-fwd": "ok"},
 "cells": [{"id": "T4", "verdict": "RED", "attribution": {"kind": ["structural", "bmv2"], "ok": true},
            "observed": {"http": 501}, "expected_today": "RED", "delta": "same", "evidence": ["A/T4.json"]}],
 "rollup": {"core": {}, "full": {}}, "verdict": "COMPLETE|PROBE-BROKEN|INCOMPLETE"}
```

- 另有 `00_table.tsv`；整個 `runs/` 進 audit-raw。

### 4.4 時間【推論，依 T06 的時間戳：GAP-2b 跑過】

| 段 | 估計 |
|---|---|
| S0 | 約 2 分鐘，不佔 lab |
| A | 10–12 分鐘：身份格每格約 10 s，加 G1 窗、TP2 ≤20 s、Q1 10 s |
| B | 4–5 分鐘 |
| C | 約 3 分鐘 |
| telemetry-none | 約 2 分鐘 |
| **合計** | **約 19–22 分鐘** |

- 看過紅那一次（§5.2-④）另外約 3 分鐘。
- `--only <cells>` 只重跑指定的格，並帶上它們依賴的自檢與 B 的歸因。

### 4.5 當掉也收得乾淨

- `setsid` 起動；每次 bring-up 包在 try/finally；SIGTERM、SIGINT、SIGHUP 轉成例外，走 finally（順序見 §4.2）。
- 每個會改機器的步驟**之前**先寫 `LAB_STATE.json`，含探測器的 pid；claim note 帶這個檔的路徑。
- **`recover.sh <run>`**（人執行；照順序）：
  1. 讀 `LAB_STATE.json`，確認 pid 已經不在。
  2. **先確認現場還是探測器的**：`ndt status` 的 claim owner 與 note 都對得上這個 run，`app_package_override` 指的是這個 run 的 package。任何一項不符就印出來、什麼都不寫，停。
     - **r2 (Cut 1 review)**：`ndt up` 一開始改機器就會把 note 改成「in use: ndt up p4 … by <owner>」（`ndt:1207-1215`），`ndt down` 也會改（`ndt:1245-1277`），所以只認探測器自己的 note 會讓每次當機都 rc 3。改成：claim owner＝這個 run 的 owner 且沒過期；`app_package_override`＝這個 run 的 package（teardown 已走到 `ndt down` 之後可以是空的）；note 是三種之一：探測器自己的、ndt up 為這個 owner 寫的、ndt down 寫的。
     - **r2**：§12 第 11 項的重新 claim 只在兩個條件下做：過期 claim 的 owner 是空的或是這個 run 的；而且 `ndt status --measuring` 與 claim 的 `measuring=` 都沒有量測。別人過期的 claim 不接手。
     - **r4 (Cut 1 follow-ups)**：
       - ~~這個重新 claim 在 phase `down-done` 也要成立……要用 recover.sh 自己算出的 `override_ours`（……在 teardown 之後的 phase 為空）~~ **r5 (Cut 1 follow-ups)** 收窄：`app_package_override` 不見了，只有 phase 是 `down-done` 才算證據（探測器自己成功的 `ndt down` 刪掉它，`ndt:1597-1601`）。重新 claim 只在 override 等於這個 run 的 package，或「override 為空，而且 phase 是 `down-done`，而且過期的 claim 檔還在、owner 是自己」時做。其他 phase（teardown、down-failed、claim-lost）override 不見了，可能是別人的 up／down／clean 刪的，現場不能證明還是自己的 → rc 3，什麼都不寫（和 r3 一樣）。
       - ~~phase `released` 不重新 claim~~ **r5 (Cut 1 follow-ups)**：phase `released` 只做第 3 步（認得出身分的 kill，停掉探測器記下、停不掉的行程）：不 claim、不動 knob／netem、不 `ndt down`；全部停掉（或本來就沒有）rc 0，有 kill 失敗 rc 7。一個已經 release 的 run 目錄不能再拿去對後來一輪的 fabric 跑第 4–5 步。
       - **r5 (Cut 1 follow-ups)**：`down-done` 的「`ndt status` 確認沒有 fabric」改在任何 claim 分支**寫入之前**做（唯讀）：fabric 還在 → rc 4，`ndt claim` 不會被呼叫。
       - **r5 (Cut 1 follow-ups)**：第 3 步有 kill 失敗時，不論 phase，整個流程做完之後以 rc 7 結束，不再印「done」、不再 rc 0。
       - `ndt status --measuring` 的輸出必須有 `measuring` 或 `orphaned` 其中一列（`ndt:6803-6815` 一定會印其中一列）；兩列都沒有就當忙碌，不放行（和讀不到時一樣，往關的方向失敗）。
     - **r6 (Cut 1 follow-ups r6)**：「現場是這個 run 的」過去只靠 owner 加 package 路徑，這兩樣在兩輪之間都可以相同：先前某個 run 目錄的 `recover.sh`，會在後來同 owner、同 package 路徑那一輪的 live claim 之下通過、對那一輪的介面下 `tc qdisc del`、符合快照時再 `ndt down`。改成兩件事一起成立：
       - **package 是這一輪自己的**：每一輪把 S0 建好的 package 複製進**這一輪的 run 目錄**（`<run>/pkg…`），`ndt up p4 --app` 用那一份；`LabRound` 拒絕 run 目錄以外的 `package_dir`（`..`、符號連結、名字開頭相同的鄰居、run 目錄本身都算外面），在動任何東西之前就丟 `PackageOutsideRunDir`。`recover.sh` 同樣要求 `package`（`readlink -m` 之後）在 run 目錄裡面，否則 rc 3、什麼都不寫。這讓 `app_package_override` ＝ 這個 package 成為只屬於這一輪的事實。
       - **claim 是探測器自己那一個**：探測器在 `ndt claim` 成功後立刻把 claim 檔的 `expires` 記進 `LAB_STATE.claim_expires`。live claim 分支要求 claim 檔的 `expires` ＝ 記下的；過期 claim 分支要求過期的 claim **檔**的 `expires` ＝ 記下的（檔不見了就沒有東西可以對，rc 3）。任何一個不符：rc 3、什麼都不寫。`recover.sh` 自己重新 claim 成功之後，把新的 `expires` 寫回 `LAB_STATE.json`，否則失敗後第二次執行會在自己的 claim 上 rc 3。
       - 還沒證明的：同一個 owner 的另一個 claim，只要結束的那一秒相同（開始時間＋60×分鐘，`ndt:824`）就有相同的 `expires`；人手動對這一輪的 package 目錄下 `ndt up --app`，看起來就像探測器；`recover.sh` 在自己的 `ndt down` 之後、寫 phase 之前被殺，下一次會是舊 phase 加上已清掉的 knob（rc 3）。
     - **r7 (Cut 1 follow-ups r7)**：
       - **knob 的讀法**：真的 `ndt` 把 `app_package_override` 寫成兩行——`# written by ndt up p4 --app at …` 註解，再是路徑（`ndt:1642-1643`）。`recover.sh` 原本讀第一行，所以對真的 knob 每個「knob 還在」的當機狀態都 rc 3，而測試的 fixture 寫的是一行（ndt 從不這樣寫）所以一直綠。現在讀第一個不是空白、不是 `#` 的行（同 `app_knob_dir`，`ndt:1606-1615`）；fixture 改成 ndt 的兩行格式。
       - **recover 自己的 `ndt down` 之後記 phase**：成功寫 `down-done`，失敗寫 `down-failed`（和 `LabRound` 一樣）。真的 `ndt down` 不論結果都會清掉 knob（`ndt:5233-5246, 5605`），沒有 phase，重跑時 knob 不在、phase 還是 cells，會對自己的 live claim rc 3。
       - **live claim 加上 knob 不在**：只認這一輪自己的 note 或 `ndt down` 的 "down at …"，不認 "in use: ndt up …"（同 owner 的 baseline `ndt up` 清掉 knob 並寫下這個 note，`ndt:3454, 3486`）。`<claim>.overrides` 裡有一行 `claim_expires=` 等於記下的值（`ndt up --force` 越過了這一輪的 claim，`ndt:1058, 1071`），不論哪個分支都不行動。
       - **`ndt down` 之後、還原 knob 與 release 之前**再讀一次 claim：owner 與記下的 `expires` 都要還在，否則 rc 3。
       - **訊息**：claim 檔不見時印出 `lab.claim.prev` 的 owner 與 `expires`（`ndt:920`），並說那是不是這一輪記下的 claim；沒記到 `claim_expires` 但 claim 的 note 是這一輪獨有的 "p4-health <run> <bring-up> state=…" 時，印出 `ndt release` 的指令。
       - 探測器還活著的檢查在欄位檢查之前，所以 `claiming` 階段還在跑的探測器得到 rc 3「還在跑」，不是 rc 2。
       - `LabRound` 把 package 路徑解析一次（跟隨連結），檢查、LAB_STATE 與 `ndt up --app` 都用同一條；`expires` 用 `^[1-9][0-9]*$` 判斷，不再用 `isdigit`。
     - **r8 (Cut 1 follow-ups r8)**：測試的 stub 一律照 `ndt` 與 `qdisc_snapshot.sh` 真的行為寫，每一處行為旁邊註明出處（`ndt:447-460, 849, 890-903, 920, 1245-1277, 5233-5246, 5312-5318, 5524-5537`、`qdisc_snapshot.sh:24, 37-44`）。照著寫之後，r7 的兩個舊洞才現形：
       - **N1：`ndt down` 跑過之後沒有介面了，qdisc diff 一定不同**。knob 不在、phase 不是 `down-done` 時，`recover.sh` 先問 `ndt status`：沒有 bmv2、沒有 host/switch → 這個 down 已經做完，記 `down-done`，跳過第 4–5 步，接著重讀 claim、還原 knob、release；還有 fabric → 第 4–5 步照舊。`ndt down` 的 rc 3（沒有東西可以拆，`ndt:5524-5537`）算做完。這是 `ndt down` 在 component 被 SIGKILL 之後「拆乾淨卻回 1」那個一次性的紅（`ndt:5312-5318`）之後，重試能走完的條件。
       - **N2：`recover.sh` 自己重新 claim 之後，release 會被自己的 baseline 擋住**。`ndt claim` 把當下的 host knob 值記成 round baseline（`ndt:447-460, 849`），`ndt release` 在 knob 不等於 baseline 時拒絕（`ndt:890-903`）；重新 claim 時 knob 裡還是這一輪的值，第 6 步還原成輪前的值之後 release 必被拒，而 ndt 印出的補救（把 baseline 的值寫回去）會把還原蓋掉。現在 `recover.sh` 把重新 claim 的 `expires` 同時記在 `recover_claim_expires`；release 時若手上的 claim 就是那一個，而且每個 knob 都等於 snapshot，就用 `ndt release --force` 並印一行原因；其他情形照舊用普通 release。rc 6 的訊息不再叫人照 ndt 印的去寫 baseline 值，改成說明 knob 已還原到輪前的快照、不要把印出的值寫回去、lab 可能需要人看。
       - **提示**：沒記到 `claim_expires` 時，只有在 `<claim>.overrides` 沒有針對那個 claim 的行時，才說「沒有東西被帶起來」；有就改成警告。
       - **殘餘風險補上**：探測器自己的 `ndt down` 若在清掉 knob（`ndt:5605`）與寫 note（`ndt:5538`）之間被殺，knob 不在、note 還是 "in use: ndt up …"，note 規則會拒絕（rc 3），安全。「在 `ndt down` 之後、寫 phase 之前被殺」只在 phase 是 up 或 cells 時才是下一次 rc 3；teardown、down-failed、claim-lost 現在由 N1 的 `ndt status` 處理。
     - **r6**：`recover.sh` 一開始（在 pid 檢查之前）要求 `owner`、`run`、`package`、`claim_file`、`app_package_override`、`claim_expires` 都在而且不是空的（`claim_expires` 是正整數），否則 rc 2、什麼都不做。package 為空、override 不見時，`"$ov" == "$PKG"` 在每個 phase 都成立。探測器若在 `ndt claim` 與寫入 `claim_expires` 之間死掉，`claim_expires` 是 null，也是 rc 2，由人看過再處理。
  3'. **r2 (Cut 1 review)**：sniffer 與控制器記錄成 pid＋start time（`/proc/<pid>/stat` 第 22 欄）＋cmdline marker（run id），三者都對得上才送訊號；停掉之後從 `LAB_STATE.json` 移除，之後不會被殺第二次。`lab_round` 的 teardown 在每個會動共用狀態的步驟（netem、`ndt down`、knob、release）之前重讀 claim：不再是自己的、或已過期，就停在那裡，剩下的交給 `recover.sh`。netem 加失敗的介面會移出清單。
  3. 停掉列出的 sniffer 與控制器 pid。
     - **r4 (Cut 1 follow-ups)**：phase 是 `down-done` 時**也做這一步**。停行程不需要 fabric；lab_round 在 kill 失敗時把那筆留在 `LAB_STATE.json` 就是留給這一次重試的，過了 `ndt down` 之後不能再跳過它。
  4. 對列出的介面拿掉 netem，再拿 `qdisc_snapshot.sh` 和 `qdisc_before` 比對，必須相同；不同就印出差異、停下來給人看。
  5. `NDT_OWNER=<同一個 owner> ndt down`。
  6. 兩個 knob 寫回 snapshot 的 bytes。
  7. `ndt release`；如果因為 knob 拒絕，照它印出的那一行做（`ndt:888-899`），不用 `git checkout --`。
  8. `ndt status` 確認：沒有 bmv2、沒有心跳、沒有 claim。

---

## 5. 紅燈先行與防假綠

### 5.1 預測與 rollup

- **rollup 只算**：GREEN、PARTIAL、歸因成立的 RED。
  - 一個維度裡沒有可算的格 → **未判**。
  - 全綠＝做得到；全紅＝做不到；其餘＝部分。
- **預測會紅**：
  - meters：MT1–MT3；
  - digest：D1；
  - registers：R2、R3；
  - packet_io：P2、P3；
  - custom_headers：CH4（推論），CH1、CH2、CH8 是 PARTIAL(a)；
  - verification：V2 是 PARTIAL(a)；
  - tables：T4–T8、PF-T；
  - counters：K2；
  - pre_clone：C2；
  - queue_metadata：Q2。
- **第一次跑、預測綠**：C1、K1、TP4。
  - registers 這一維在 r3 只剩 R2、R3，所以從 GAP-2b 的「部分」變成**做不到**。
  - 這是 r3 拿掉 R1（資料面狀態本來就是 bmv2 的事）的直接結果，和 GAP-2b 的定義一致：NDTwin 的那一半是讀寫（GAP-2b:33）。

| rollup | 做得到 | 部分 | 做不到 | 未判 | 說明 |
|---|---|---|---|---|---|
| core | 最可能 10；範圍 6–10 | 最可能 3 | 最可能 3；範圍 3–5 | 0–1 | 一定做得到的有 6 維：pipeline_load、tables、pre_multicast、checksum、ttl_or_hop、control_plane_mode。pre_clone、counters、queue_metadata、topology 這 4 維看 C1、K1、Q1、TP4。C1 或 K1 紅 ⇒ 那一維做不到；Q1 若 UNATTRIBUTED ⇒ queue_metadata 未判 |
| full | 最可能 6 | 最可能 7 | 最可能 3；Q1 UNATTRIBUTED 時 4 | 0 | Q1 若 UNATTRIBUTED ⇒ queue_metadata 只剩 Q2，做不到變 4；C1、K1 若紅，還會再加 |

- 兩組都是 16 維的分配，加起來是 16。
- **r2 (Cut 1 review)**：Q2(a) 不變，core 與 full 都是 16 維。Q3(b) 的六個類別另成**第三組 rollup `q3b`**（6 維），和另外兩組並列回報，不併進 full。預測：can 2（recirculate、hash_random）、partial 1（header_union）、cannot 2（action_profile、idle_timeout）、未判 1（value_set：VS1 預測 UNATTRIBUTED）。

- **預註冊**：`expected_today.tsv` 在第一次 live 之前 commit。
  - 每個修正的 PR 指名它翻轉的格，附 `health.json`，並在同一個 PR 改預期檔。

### 5.2 防假綠

**① 判定函式加上 fixture**（`tools/p4_health/tests/test_cells.py`）

- 每個 active 格都要有：綠、紅、sent=0 → NOT RUN、oracle 讀不到 → NOT RUN、歸因失敗 → UNATTRIBUTED、自檢失敗 → PROBE-BROKEN。
- **static 格（T2、M1、C1、PL1、T1 的 dump 那一半、P1、Q2、CS1、TP1）也要有**：oracle 讀不到 → NOT RUN；thrift 回錯誤或空回覆 → 不准 GREEN（負讀必須不通過）。
- **規則 D 的 fixture**：PL1 紅 ⇒ SC-fwd 與依賴的格判 NOT RUN、寫明 `gate PL1 RED`，整輪 COMPLETE；所有 gate 綠而 SC-fwd 失敗 ⇒ PROBE-BROKEN。
- **預期拒絕的 fixture**：CP2 的 409、K1-neg 與 T3-neg 的 404 ⇒ 及格，不准變成 RED 候選。
- **判定順序的 fixture**：404 加上 oracle 讀不到，必須是 RED 候選，不是 NOT RUN。
- 判官點名的 fixture：
  - Q1：送 `id=1`、沒有戳 → 不准 GREEN；
  - CH7：側表只有 CH2 的 0x1234 列，或只有 ARP、IPv6、0x88B5 → 不准 GREEN；
  - K1：thrift＝N 而 NDTwin＝N+1 → RED。

**② 讀取層的測試要封死**（`tests/test_collect.py`）

- 只注入一個 `Runner` 與一個 `Config`。測試用的 `Runner` 只記錄 argv、回罐頭輸出。
- `Config` 指向 tmp 路徑與 in-process 的假 proxy／kernel：FastAPI TestClient，不開 socket。
- 測試時 `PATH` 最前面放一個目錄，裡面的 `sudo`、`tc`、`ndt`、`mnexec`、`simple_switch_CLI` 都是**一碰就失敗**的腳本：exit 99，並寫一個 tripwire 檔。
- `socket.create_connection` 被包起來，連 127.0.0.1 的 8000、8081、30051–30060、9091–9100 一律拒絕並記錄。
- 每個測試結束都斷言兩件事：tripwire 不存在、沒有任何 lab 埠被嘗試過。
- 斷言內容：
  - sent 取自 sender 的 stdout；
  - oracle 欄的值來自 thrift 的罐頭，不是 proxy 的；
  - finally 依序呼叫停 sniffer → 拿掉 netem → down → 還原 → release，而且不碰 `app_package_override`。

**③ copy 式 mutation gate**：`tests/shell/mutate_p4_health.sh`，規矩同 `mutate_drive_exercise.sh:16-30`。

| M | 突變 | 必須轉紅的測試 |
|---|---|---|
| M1 | 2xx 就算 GREEN | K1 的 N+1 fixture |
| M2 | route 不存在當成物件不在 | R2 的 openapi fixture |
| M3 | sent 改成「想送幾個」 | test_collect |
| M4 | oracle 改讀 proxy | test_collect |
| M5 | 503 當 0 | K1 的 503 fixture |
| M6 | NOT RUN 算綠 | rollup fixture |
| M7 | rollup 改成 best-of | rollup fixture |
| M8 | 側表只看 ethertype | CH7 的 CH2 列 fixture |
| M9 | 忽略 `journaled` | T8 fixture |
| M10 | 心跳期限改成無限 | TP2 fixture |
| M11 | 判定順序反過來（oracle 先查） | 順序 fixture |
| M12 | 預期從本輪結果產生 | 預期檔讀取測試 |
| M13 | 歸因失敗仍判 RED | UNATTRIBUTED fixture |
| M14 | knob 不還原 | test_collect |
| M15 | 心跳只查非 null | TP4 fixture |
| M16 | Q1 不要求旗標 | Q1 fixture |
| M17 | finally 跳過 netem 或 sniffer | test_collect |
| M18 | 自檢失敗判成 RED | 自檢 fixture |

- 另有負對照（只改註解必須維持綠）與 anchor check 模式。

**④ live 看過紅**（每個探測器版本一次；必須得到的判定寫死）

| Cut | 變體 | 必須得到 |
|---|---|---|
| 1 | S0 的 FWD_88B5 | FWD 必須 rc 1，三個真 package 必須 rc 0；其他任何結果 → PROBE-BROKEN |
| 2 | A 用 mutant artefact，`--only K1,TTL1`（gate 格都綠） | K1、TTL1 都是 PROBE-BROKEN，原因分別是 SC-count、SC-ttl |
| 3 | A 用 mutant artefact，`--only Q1` | Q1 是 PROBE-BROKEN（SC-qstamp）；Q1 是 Cut 3 的格 |
| 3 | telemetry-none 那一次 | V1、CH1、CH7 都是 RED，`assert_link_usage_absent` 成立；這三格都是 Cut 3 的格 |

---

## 6. 論文 app 模式

- **怎麼交**：`run.sh --p4 <file> [--app-dir <tutorials 形狀的目錄>] [--expect <file>]`。
- **不用 lab 的那半**：
  - 編譯，清點 match kind、counter／meter（direct 與 indirect）、register、digest、controller header、clone／mcast、varbit、union、value_set；
  - parser 形狀用 `p4pi.py` 判；
  - 和最近一次同 lab_surface 的 full 健檢 join，得到【讀碼】級的預測，不和跑過的格同欄。
- **用 lab 的那半**：
  - PL1 的 sha、T1、M1、C1、TP1、TP2、P1；
  - counter：NDTwin 讀數＝thrift 讀數，判 READ-ONLY；
  - V1；
  - 有附 `send.py` 的話，跑 CH 類。
- **探不到的**：
  - 程式語意（除非給 `--expect`）；
  - thrift 控制面；
  - P4_14、PSA、PNA、Tofino；
  - 只靠 thrift 腳本裝的 entries。目前沒有轉換工具，見 Q7。
- **不丟 0x88B5 的程式**：drop check rc 1。
  - 在 ndtwin mode 下，心跳照樣會起（`ndt:3008-3013`），幀可能送到主機。⇒ 探測器只允許以 external 跑這種程式。
  - **external 下 NDTwin 什麼都不寫**，所以那支 app 自己的 runtime JSON 也沒人裝。要嘛 B 重放它，要嘛那一半判 NOT RUN。這件事要明講。
- **int-v1 的實況**：見 §1.6-3 與 Q7。

---

## 7. 範圍與風險

### 7.1 刻意不做的

- 效能與規模、OVS、`ndtwin_switch.p4` 自己的功能。
- 修任何缺口；改 proxy、kernel、`ndt`。
- 經 thrift 寫入。
- 把結果餵回 `capabilities` 或 GUI。
- 判 app 對不對。

### 7.2 lab 時間與地點

- 一輪約 19–22 分鐘，看過紅另外約 3 分鐘（推論）。
- `ndt` 與 lab helper 只在主 checkout 動手（`ndt:1407-1409,11215-11218`）。
  - 【推論】從 worktree 呼叫主 checkout 的 `ndt` 也行。
  - 為了讓 identity 單純，建議併進 trunk 之後在主 checkout 跑。

### 7.3 sudo 面

- **`ndt` 經 `ndtwin-lab`**：手冊有教。
- **mnexec 跑 python、ethtool、ip**：
  - 手冊沒教，`sudo_surface.sh:13` 只列了 ping；
  - drive_exercise 的用法 T06 跑過【GAP-2b 跑過】；
  - 授權很寬（`faults.sh:60,68`）。
  - ⇒ 正因為寬，§5.2-② 才要封死。
- **tc**：
  - 手冊沒教（`sudo_surface.sh:15-19`）；
  - `faults.sh:54-56` 記的 grant 是用 `sudo -n -l` 看到的，而 sudo_surface 說那個方法不可信。
  - ⇒ Cut 3 的第一件事是逐字讀 sudoers。
- **T8 的重啟**：延後。
- **探測器**拒絕 euid 0。

### 7.4 共用狀態

- 只動兩個 knob：`host_count_override`、`telemetry_override`。每次 bring-up 各自 snapshot、各自還原。
- `app_package_override` 不碰。
- 🔴 **未提交的觀測**：工作樹的 `host_count_override` 是 `4`（committed 版是 `128`）。每次 bring-up 會改成 6，release 前寫回 4。

### 7.5 和進行中工作的互動

| 進行中 | 會碰到的檔（讀碼推估） | 健檢的關係 |
|---|---|---|
| ternary／range＋journal | `p4_client.py:133,1200-1208`、`api_routes.py:925-930,765-767`、`preflight.py:60,218-234`、`main.py:618-665`、`rule_journal.py` | T4–T8、PF-T 是它的驗收格；T8 的持久性要那一刀提供重啟路徑 |
| 自動產生 parser hints | pre-flight 的產生器、`SFlowType.hpp:267`、`FlowLinkUsageCollector.cpp:1510`、`switch_state` 的新揭露鍵 | CH1、CH2、CH4、CH8、V2 是它的驗收格；揭露鍵不在＝維持現判 |
| external detect-only | 碼在 trunk（`main.py:1396-1401`、`ndt:3008-3044`） | TP4 跟著它的形狀走 |
| B live 重跑 | trunk 凍結、佔用 lab【轉述 `RULINGS-1001.md:126-133`】 | 健檢的 live 排在它之後 |

- 健檢新增的檔：`tools/p4_health/**`、`tests/shell/mutate_p4_health.sh`。
- 接進 L1 要協調共用的 `l1_unit_tests.sh`。

### 7.6 風險

- **編不過**：拆成兩份。
- **連帶**（規則 D）：gate 格（PL1、T1、TP1、CS1）不是 GREEN 時，依賴的格判 NOT RUN 並寫明原因；只有 gate 格都綠、自檢仍失敗才判 PROBE-BROKEN。T7 依賴 T4，T4 紅時 T7 是 NOT RUN。
- **B 控制器有 bug**：產生 UNATTRIBUTED，不會產生綠。
- **tc 未驗**：沒有 tc，TP2、TP4、CP4 都判 NOT RUN。
- **時間是推論**。

---

## 8. 交付計畫（照 Q1(a)）

| Cut | 內容 | 證明什麼 | 規模（推估） | lab |
|---|---|---|---|---|
| 0 | 本稿加上 `expected_today.tsv` | 契約先寫定 | 文件 | 不用 |
| 1 | 程式；S0；`cells/` 與 fixture；`collect/` 加上 `Runner`／`Config` 與封死的測試；`lab_round.py`（只做離線測試）；`recover.sh`；M1–M18 | 編得過；PF-T 紅；drop check 三個 rc 0、FWD rc 1；gate 0 survivor、負對照綠；test_collect 沒碰到任何 lab 埠 | P4 約 400 行、Python 約 1,200 行、測試約 800 行 | 不用 |
| 2 | A 的 core 格與 T4–T8、K2、C2、MT3；**最小 B**（11 項歸因）；看過紅的 K1、TTL1 那一次 | 第一張帶歸因的紅綠表；C1、K1 第一次跑 | 約 1,200 行 | 要授權；約 17 分鐘＋3 分鐘 |
| 3 | CH1–CH8、Q1、Q2、TP2、V1、V2、telemetry-none；看過紅的 Q1 與 telemetry-none；tc sudo 的驗證 | 自訂標頭、佇列、斷線偵測 | 約 500 行 | 加約 10 分鐘 |
| 4 | B 的 PL2、K3、P4、TP4、CP2；C 的 CP4 | external 與 roles 兩種模式 | 約 400 行 | 加約 7 分鐘 |
| 5 | 論文 app 模式；int-v1 照 Q7 的選擇 | 「論文 app X 會卡在哪」 | 約 300 行（Q7(b) 再加轉換工具） | 每支約 3 分鐘 |

---

## 9. 要 Adam 決定的

**Q1 探測器放哪、生命週期怎麼來**

- **建議：** (a)。
- **後果：** repo 裡會有第二份 lab 生命週期，由健檢自己的 gate 守著；「工具搬出 doc/audit」那件事的排序照舊由你決定，不受影響。

| 選項 | 好處 | 代價 |
|---|---|---|
| **(a) `tools/p4_health/` 自己寫 `lab_round.py`（§8 照這個寫）** | 不依賴任何搬家；§4.5 的當機收拾、netem 帳、注入的 `Runner` 都在自己的碼裡，有自己的 gate | 和 `drive_exercise.py` 是兩份生命週期，日後可能漂移；之後合併是待辦 |
| (b) 等 `drive_exercise.py` 搬到 tools/ 之後共用它的生命週期 | 一份生命週期 | 等於替你排定搬家的時間；§4.5（訊號處理、`LAB_STATE.json`、netem 帳）得嫁接到別人的工具上、過它的 gate；它的 `NDT` 寫死在 `drive_exercise.py:92`，要先改成可注入；Cut 1 的 `lab_round` 測試與 M14、M17 都要改寫成針對它，所以 Cut 1 也會受影響 |
| (c) `ndt health p4` 子命令 | 入口統一 | 每一刀都要過 ndt 的重閘門，和其他 ndt 工作搶熱檔 |
| (d) `live-p1/09_health_check.sh` | 最快 | `.sh`／`.py` 會進 PR，等於加深 doc/audit 的搬家債；長得像一次性腳本 |

**Q2 紅綠表回答哪個問題**

- **建議：** (a)。
- **後果：** 兩組數字，各有做得到／部分／做不到／未判四欄，每組加起來都是 16 維；core 可以和 GAP-2b 對帳。

| 選項 | 好處 | 代價 |
|---|---|---|
| **(a) core 與 full 兩組 rollup，只算 GREEN、PARTIAL、歸因成立的 RED** | 對得上 GAP-2b，也回答教授；沒有歸因的紅不灌水 | 兩組數字要解釋（§5.1）。core 做得到 6–10（最可能 10）、做不到 3–5、未判 0–1；full 做不到至少 3，Q1 若 UNATTRIBUTED 就是 4 |
| (b) 只有 full | 一組數字 | 看起來像退步；和 GAP-2b 失去對照 |
| (c) 只有 core | 和 GAP-2b 同口徑 | 論文 app 會撞到的 ext 構造不上表 |

**Q3 「所有 P4 功能」的邊界**

- **建議：** (a)。
- **後果：** varbit 只確認 p4c 與 bmv2 吃得下（編進 hc_main），不成格——它在 NDTwin 那一半和 CH6 相同；六類構造不上表。

| 選項 | 好處 | 代價 |
|---|---|---|
| **(a) 16 維加上維內的 ext 構造** | 16 個鍵不變 | action profile／selector、idle timeout、value_set、recirculate／resubmit、hash／random、header union 不上表；varbit 沒有自己的格 |
| (b) (a) 再加「16 維之外」那六類，加 varbit | 最接近「每個功能」 | 多約 10 格、lab 多約 4 分鐘；沒有 GAP-1 的需求依據，紅了也不知道該不該修 |
| (c) 嚴格 16 維 core | 最小 | 沒回答教授 |

**Q4 第一刀多大**（互斥）

- **建議：** (a)。
- **後果：** 第一張 live 表就有 meters、digest、ternary 這些帶歸因的紅；Cut 2 約 1,200 行，B 的控制器要先寫好。

| 選項 | 好處 | 代價 |
|---|---|---|
| **(a) Cut 1（不用 lab）→ Cut 2＝A＋最小 B（經 `run_external_controller.py`）** | 第一次 live 的紅燈最完整 | Cut 2 大 |
| (b) Cut 1 → Cut 2＝只有 A，B 留到 Cut 4 | Cut 2 小 | Cut 2 的紅**只有 T8 與 R2**：T8 是 structural，R2 是 structural 加上 thrift 讀數。Q2、CH4 是 Cut 3 的格，所以不在其中。需要 `bmv2` 歸因的 meters、digest、T4–T7、PF-T、C2、K2、R3、P2–P3 都是 UNATTRIBUTED，要等到 Cut 4 |
| (c) 先做最小 live 切片：MT1、D1、R2、T4、K1 加上只歸因這五格的 B，再補 Cut 1 | 最早看到紅 | 框架要做兩次；切片沒有完整的 gate |

**Q5 要不要 N 空白對照**（互斥）

- **建議：** (a)。
- **後果：** 少一次 bring-up（每輪省約 3–4 分鐘）。r2 用 N 買到的保護，改由同窗負讀（§2.1、§2.3）、static 格也有的「oracle 讀不到」fixture、規則 D 與 mutation gate 提供。

| 選項 | 好處 | 代價 |
|---|---|---|
| **(a) 不要 N；每個 thrift 相符的 GREEN 都配一個同窗負讀** | 不多一次 bring-up、不多一支程式 | 見下方三點 |
| (b) 要 N：**照 r3 重寫一張新的 N 表**（r2 的 §2.5 在 r3 下做不出來） | 多一層「構造整個不在」的 live 對照 | 見下方三點 |

**(a) 的負讀**：

- 寫入之後相符的格，一律要求寫入之前不在：T3、T4–T7、M2、C2、MT1–MT3、R3。
- 其餘的格：
  - M1：在 s2–s4 不在；
  - C1：在 s1、s3、s4 不在；
  - T1：每台 dump 裡只宣告給別台的那一筆不在；
  - T2：拿沒給 runtime default 的 s3 比；
  - PL1：hc_alt 多的那張表在 s2–s4 不在；
  - CP2：要有控制器的那一筆。
- 前提：K2 要非零；PL2 不靠 `show_tables`。

**(a) 的代價**：

- r5 補完上面這些之後，**已知還開著的只剩 K3**：它在沒刺激時會 0＝0 變綠，Cut 1 改成依賴 SC-count（§12 第 7 項）。
- 其中 T4–T7、C2、MT1–MT3、R3 今天都是紅的。它們的負讀要等到修好、轉綠的那一天才會真正派上用場，所以建議不變，只是代價寫得更準。
- 沒有「整支程式抽掉構造」那一種對照。M1、C1 依定義只量 NDTwin 寫的 PRE，和程式無關；其餘取決於程式的綠（K1、K2、R2、Q1）由自檢加 gate 格守著。

**(b) 的代價**：

- 要新寫一支 hc_null 與它的 runtime 檔；要定 N 模式下自檢的語意（r3 規則下，hc_null 上的自檢失敗會變成 PROBE-BROKEN）。
- M1、C1 在 N 上依定義是綠，要重訂預期；r2 表裡的 R1、CP3、CS2、CS3 都已經不存在。這張表要再審一次，每輪多 3–4 分鐘。
- 而 (a) 唯一還開著的 K3，修法是改依賴 SC-count，不靠 N。⇒ 目前沒有任何已知的路徑非 N 不可。

**Q6 live 的授權方式**（互斥）

- **建議：** (a)。
- **後果：** 只改了 proxy（`sflow_emitter.py` 除外）、kernel、它們的測試，或 doc 底下的 `.md`／`.tsv` 的話，可以自己重跑驗證；閘門指紋涵蓋的其他任何東西和第一次授權那一輪不同，都要重新問你。

**(a) 改成反向的閘門（r5）**：

- 不再列「動 lab 的那一面」——列表永遠可能漏。改成只列**允許和第一次授權那一輪不同的東西**，其餘全部要相同。
- **允許不同的**（受測的修正）：
  - `p4_proxy/proxy_agent/**`，**但 `sflow_emitter.py` 除外**，它放在必須相同那一邊：
    - 每個健檢 package 都宣告 `telemetry.source: link`；
    - root 的 topology 在 bring-up 時起 link-telemetry emitter（`p4_proxy/mininet/p4_testbed_topo.py:1201-1211`），用的是 root 的直譯器（`link_telemetry.py:818-821`）；
    - 那支 emitter 再依路徑 import `proxy_agent/sflow_emitter.py`（`psample_sflow_emitter.py:56-65`）；
    - `sflow_emitter.py` 只 import 標準函式庫（`sflow_emitter.py:63-71`、`psample_sflow_emitter.py:59-60`）。
    - **搜尋範圍**：`p4_proxy/mininet/*.py` 裡每一行非標準函式庫的 import 與每一處 `sys.path` 修改，加上 `ndtwin-lab` 裡所有 `$KERNEL_DIR/src`、`$KERNEL_DIR/build`、`$KERNEL_DIR/p4_proxy/proxy_agent` 的參照。結果：root 路徑上碰到 `proxy_agent/` 的只有這一個檔，碰到 `src/` 的一個都沒有（kernel 由 `stack.sh` 以一般使用者身分起動，`stack.sh:19`）。
  - kernel 的原始碼與建置：`src/**`、`include/**`、`libs/**`、`cmake/**`、`CMakeLists.txt`、`build/**`（含 `build/bin/ndtwin_kernel`）；
  - `tests/**`：修正必附測試（CLAUDE.md 的 mutation gate）；
  - `doc/**/*.md`、`doc/audit/**/*.tsv`：別的 session 整天在改，而且這兩種是不執行的文字格式，沿用 `live-p1/code_identity.py:25` 的同一個切法。
- **其餘一律必須相同**，以 sha 或 digest 計：
  - repo 其餘每一個 tracked 檔，加上未提交的修改；
  - 輸出目錄（`.test_run/`、run 目錄、`scratch/`）以外的 untracked 檔，名字與內容都要相同；
  - NTG repo `/home/adam/Network-Traffic-Generator` 的 HEAD、tree，以及 `.git/` 以外**每一個檔**的 digest——untracked 與 ignored 的檔都算，例如 `NTG.yaml`（`ntg_bmv2_topo.py:100`）。helper 以 root 跑的 `ntg_bmv2_topo.py` 會 import 這個 repo（`p4_proxy/mininet/ntg_bmv2_topo.py:57-58,95,111`）；
  - `ntg-env`（helper 用它的 python 當 root 直譯器，`ndtwin-lab:99,312,1665-1666`；nornir 也從這裡來，`ntg_bmv2_topo.py:127`）、`p4_proxy/venv`、`/home/adam/p4dev-python-venv`（scapy 經 `sudo mnexec` 以 root 跑）。三個都照 `venv_fingerprint.sh` 的方法取 digest；
  - 系統 Mininet（`/usr/lib/python3/dist-packages/mininet` 與 `/usr/local/lib/python3/dist-packages`，`ntg_bmv2_topo.py:51-52`）與 `/usr/bin/mnexec`；
  - `/usr/local/sbin/ndtwin-lab`，以及 `/etc/ndtwin-lab.conf` 的內容或「不存在」——它能改掉 KERNEL_DIR 與 NTG_PY（`ndtwin-lab:233-241`）；
  - 二進位：fabric bmv2 加上它的 lib、stock simple_switch、p4c；以及以 root 執行的 OS 工具 `tmux`、`tc`、`ip`、`ethtool`、`sudo`——用 `command -v` 找到路徑後一行 digest。

| 選項 | 好處 | 代價 |
|---|---|---|
| **(a) 第一次 live（含看過紅）逐次授權；之後只有「允許不同」那幾類有差的重跑給常設授權，每次照 claim 規則登記** | 「修 proxy 或 kernel 就轉綠」不用等你。**在閘門指紋涵蓋的範圍內**——repo、NTG repo、三個 env、helper 與它的設定、上面列名的二進位——沒列進「允許不同」的一律要相同；root 路徑上的 repo 碼（含 `sflow_emitter.py`）不會沒審過就混進來 | 常設授權的重跑**會**對 lab 執行改過的 proxy 與 kernel，那正是要驗的修正。proxy 主程式與 kernel 不以 root 執行（`stack.sh:19`），但 proxy 會對交換機寫入；proxy_agent 裡唯一會被 root 執行的 `sflow_emitter.py` 已移到必須相同那一邊。**閘門沒涵蓋的**：上面沒列名的 OS 檔案與套件；root 路徑底下被 gitignore 的 `__pycache__`（Python 只在原始碼的 mtime 或大小變了才重編，所以一份和舊 metadata 相符的 pyc 抓不到【推論】）。`tests/**` 與 doc 的文字檔放行，是基於「探測器、`ndt`、helper 都不執行它們」這個**推論**，依據是 grep：`ndt`／`stack.sh` 裡沒有 `$REPO/doc` 的參照。共用工作樹裡任何其他檔一被別人改，常設授權就失效，要重新問你；這會比 r4 的列表版更常發生 |
| (b) 每次都逐次授權 | 最保守 | 每個修正都要等一次回覆 |
| (c) 跟其他 live 工作綁在一起授權 | 少問一次 | 時間窗互相牽動 |

**Q7 論文 app 先試哪支、怎麼試**（四個選項是互斥的計畫）

- **建議：** (a)。
- **後果：** int-v1 今天只得到一個靜態的紅：pre-flight 的 entries 檢查拒絕兩個 ternary 欄位。【推論】ternary 那一刀修好之後，同一份 package 可以直接轉 live，成為 PF-T 的 live 版，會插 INT，CH6 量得到真幀——前提是未來的 ternary writer 接受這份手寫的編碼。

**int-v1 的事實**：

- 要兩筆 entry：
  - `s1.sh:7` 的 `tb_set_source`，以 ingress port 1 做 exact（`include/int_source.p4:116`）；
  - `s1.sh:21` 的 `tb_int_source`。它的 key 有 `hdr.ipv4.src_addr`、`hdr.ipv4.dst_addr` 兩個 ternary（`include/int_source.p4:68-70`），加上兩個也是 ternary 的 L4 port 欄位（`:71-72`）；port 的遮罩是 `0x0000`，thrift priority 是 0。
- 換成 P4Runtime 的寫法：
  - don't-care 欄位**不放進 entry**（`p4_client.py:1655-1662`），所以 entry 裡只剩兩個 IP 欄位；
  - priority 必須 >0，而且大小意義和 thrift 相反【P4Runtime 規格，本 repo 沒驗】。
- 三份 runtime JSON 都寫 `"p4info": "build/int.p4.p4info.txt"`（`linear-topo/s1-runtime.json:3`），而 convert 要的是 `.p4.p4info.txtpb`（`convert.py:361-370`）。
- **convert 只把最上層的 `.p4` 抄進 package**（`convert.py:504-508`）。而 `int.p4` 會 `#include` `include/` 底下五個檔（`int.p4:5-9`）。
  - pre-flight 預設會從 package 裡的 `source.p4` 編譯（`preflight.py:1190-1216`）；
  - `ndt up` 跑的就是這個會編譯的 pre-flight（`ndt:2064-2077`）。
  - ⇒ 沒有 `include/`，編譯那一列也會 FAIL。
- runtime JSON 裡只有每台 4 筆 `ipv4_lpm`（lpm）。
- 預設會丟 0x88B5【轉述判官 r3：`include/fwd.p4:66`】。
- `--translate-thrift` 這個工具目前不存在。

**(a) 的做法**（在 run 目錄裡做，不改 `/home/adam/paper-apps`）：

先把 int-v1 抄一份到 run 目錄，以下都在那份副本上做。順序照 convert 的要求：convert 要求 artefact 已經編好（`convert.py:422-429`），也要求 entries 指的 p4info 已經存在（`convert.py:605-610`）。

1. 用 `p4c-bm2-ss --p4v 16 --p4runtime-files build/int.p4.p4info.txtpb -o build/int.json int.p4` 編譯，名字照 `.txtpb` 的慣例。
2. 三份 runtime JSON 的 p4info 路徑都改成 `build/int.p4.p4info.txtpb`。
3. 在 s1 那份手寫上面兩筆 entry。
4. 跑 convert。
5. 把 int-v1 的 `include/` **整個抄進 package**，放在 `int.p4` 旁邊。
   - 選這個、不選 `--no-compile`，理由是：live 那條路上 `ndt up` 一定會跑會編譯的 pre-flight。現在就讓編譯那一列過，同一份 package 修好 ternary 之後才轉得了 live。用 `--no-compile` 的話，那一列只是暫時被遮住。
6. 跑 pre-flight（會編譯）。

**預期的輸出**：

- `p4c-bm2-ss` 那一列 PASS【推論：p4c 1.2.5.15 能不能編 int-v1 還沒驗過】；
- **只有「entries match p4info」那一列 FAIL，而且是「2 problem(s)」**：s1 那筆 `tb_int_source` 的 `hdr.ipv4.src_addr` 與 `hdr.ipv4.dst_addr`，各是一個「is a TERNARY match -- G5 not done」（`preflight.py:218-234,1136-1142`）。
- 任何別的列 FAIL，或 problem 的數目不是 2，都照實回報成路徑或格式錯，不算 ternary 的紅。

| 選項 | 好處 | 代價 |
|---|---|---|
| **(a) 照上面六步：編譯、改三份 p4info 路徑、在 s1 手寫兩筆 entry、convert、抄 `include/`、跑會編譯的 pre-flight** | 不用新工具、不用 lab；今天就有一個真論文 app 的紅，而且紅在對的那一列 | 只涵蓋 int-v1；手寫的 priority 與 don't-care 要人工核對；live 要等 ternary 那一刀 |
| (b) 先做通用的 `--translate-thrift`：把 `table_add` 轉成 runtime JSON 的 entry，含 don't-care 省略與 priority 反轉，也負責抄 `#include` 的檔；再用它產出 (a) 那份 package | 之後其他 thrift 形狀的 app 也能用 | 多一個要定規格、要 gate 的工具；int-v1 的第一個結果要等它做完 |
| (c) 做 (a)，**再加**一次 external 的 live：另用 `--mode external` convert 一份 package，由 B 控制器重放 int-v1 的 runtime JSON 加這兩筆。<br>external 的 package 不帶任何 runtime entries（`convert.py:495-497`；`preflight.py:1088-1093`）；convert 在 external 模式下要求 exercise 裡有 `mycontroller.py`（`convert.py:516-521`），所以副本裡要放一個替身，就是 B 的控制器。<br>package 一樣要帶 `include/`，因為 `ndt up` 會編譯 | 修好 ternary 之前就看得到真 INT 幀 | 前提是 Cut 2 的 B 控制器與 Cut 5 的論文 app 模式都做好了；entry 是控制器寫的、不是 NDTwin，所以 T4 與 PF-T 都量不到，只量 CH6 與通用格 |
| (d) 照 (a) 的六步，但跳過第 3 步（不加那兩筆） | 【推論】pre-flight 全部 PASS（只剩 lpm entries）；Cut 5 之後通用格能 live | `tb_int_source` 是空的（default `nop`，`include/int_source.p4:67-83`），不插 INT ⇒ CH6 沒東西可量，也碰不到 ternary |

---

## 10. 讀了什麼

- **r1、r2**：見 `DESIGN-r2.md` §10。
- **r3 另外讀了**：
  - 判官 r2 全文；
  - `heartbeat_drop_check.py:14-22,36-42`；
  - `faults.sh:13-21,52-70,86-90`；
  - `qdisc_snapshot.sh:1-15`；
  - `drive_exercise.py:90-94,3018-3028`；
  - `main.py:1288-1305`；
  - `p4_client.py:1655-1664`；
  - `ndt:3220-3223`；
  - int-v1 的 `runtime_cmds/s1.sh:1-10` 與 `int.p4:38-46`；
  - fabric bmv2 的 `grep -c -a priority-queues`（結果 1）。
- **r4 另外讀了**：判官 r3 全文；`p4_testbed_topo.py:34-38`；`ndtwin-lab:244-245,312,1665`；`stack.sh:11,19,1087`；`ndt:56,1774-1778` 與它呼叫的腳本 grep；int-v1 的 `utils/Makefile:6`、三份 `linear-topo/s*-runtime.json`、`include/fwd.p4:41-66`、`include/int_source.p4:115-116`。
- **仍然沒讀**：
  - `rule_journal.py`、sudoers、`faults.sh` 的還原段、tutorials 的 `p4runtime_lib`、`REPORT-int-v1.md`；
  - v1model 的 parser reject 語意，只採判官的說法並標為推論。

---

## 11. 修訂紀錄

### 11.1 r1 → r2

逐條表（57 條）見 `DESIGN-r2.md` §11，這裡不重抄。

### 11.2 r2 → r3

判官 r2 的每一條我都對碼驗過，**全部採納、沒有反駁**。其中「以刪代修」的條目，處理方式寫明了刪什麼。

| ID | 判官的發現（等級） | r3 怎麼處理 | 證據 |
|---|---|---|---|
| K01 | CH7 的身份會被 CH2 那一列滿足（MINOR） | CH7 改用 0x1236；鍵加上 `dst_mac`，並要求 `samples` 在窗內增加 | `SFlowType.hpp:587-589`、`FlowLinkUsageCollector.cpp:1139-1141` |
| K02 | 0x88B5 的丟法放錯位置；drop check 的覆蓋範圍沒講（MINOR） | 改成 ingress 第一句 `mark_to_drop`＋`exit`；寫明 drop check 只驗 default action | `heartbeat_drop_check.py:36-41` |
| K03 | CP4 沒有心跳前提（MINOR） | 加上 `usable` 前提 | `main.py:1290-1304` |
| K04 | TP1 的 oracle 沒有主機（MINOR） | fabric oracle 加上 namespace 裡的 IP 與 MAC | §2.1 |
| K05 | J27 的假紅（MAJOR） | 併入 K09 | — |
| K06 | L596 的措辭把預期結果說成失敗（MINOR） | 改為「FWD 必須 rc 1、三個真 package 必須 rc 0、其他任何結果才是 PROBE-BROKEN」 | §5.2-④ |
| K07 | 預測範圍沒有「未判」（MINOR） | 加上未判欄 | §5.1 |
| K08 | N 的優先序衝突：K1、R1、T3、C1；L240 與 L342 互相矛盾（MAJOR） | 定下判定順序（結構性答案先於 oracle，§2.1）；**拿掉 N**，改成 Q5 讓你選；矛盾隨之消失；Q5(b) 寫明 N 若保留要宣告 session 7 | §2.1、Q5 |
| K09 | 只靠 wire 下的假紅：TTL1、CS2、CS3、T2、R1、CP3、CH9、PL1 的打戳、L2（MAJOR） | **以刪代修**：NDTwin 那一半一律改用 thrift 或 NDTwin 自己的觀測面判；程式行為改成五個自檢（失敗＝PROBE-BROKEN）；刪掉 CS2、CS3、R1、CP3、CH9、C3 與 PL1 的打戳；T2 改用 thrift；L2 改為預期 PROBE-BROKEN。沒有採用 S0 的 bmv2 行為 oracle，因為那要多一套跑 entries 的 harness | §2.1、§2.3 |
| K10 | test_collect 的 stub 沒有封死（MAJOR） | 單一注入的 `Runner` 與 `Config`；PATH 上放一碰就失敗的 stub 加 tripwire；lab 埠連線攔截並斷言沒碰到 | `faults.sh:54-56,60,68`、`ndt:3222` |
| K11 | Q1 灌流量會干擾心跳（MINOR） | TP2 排在前、Q1 排在最後，跑完查 `missing_directions` | §2.3 |
| K12 | S0 執行 bmv2 `--help` 要用不同的 argv[0]（MINOR） | 改成 `grep -a` binary 的字串，不執行它 | §1.1 |
| K13 | teardown 與 recover 的漏洞（MINOR） | 先停 sniffer 與 B 控制器；recover 先確認現場是自己的；qdisc 前後快照比對；`LAB_STATE.json` 記 pid | `drive_exercise.py:3018-3027`、`faults.sh:15-20` |
| K14 | hc_null 的清點規則沒算 0x88B5（MINOR） | N 拿掉，此條不再適用 | — |
| K15 | PL1 被排除在 N 之外（MINOR） | N 拿掉、PL1 的打戳也拿掉 | — |
| K16 | 計數兜不起來（MINOR） | 重算 | §2.3 |
| K17 | L4 與 V3 重複（MINOR） | 合併成一次 telemetry-none | §2.3 |
| K18 | 論文 app 被迫 external 時，沒人裝它的 entries（MINOR） | 明講 | §6 |
| K19 | L690 引 RULINGS 沒標轉述（MINOR） | 補標【轉述】 | §7.5 |
| K20 | Q1 的建議偷偷替你排了搬家；「Cut 1 不受影響」是錯的（MAJOR） | 改為建議 (a)；寫明 (b) 的真實代價；§8 照 (a) 對齊 | `drive_exercise.py:92` |
| K21 | Q2 的範圍沒有未判（MINOR） | 補上 | Q2 |
| K22 | Q3「varbit 由 CH9 涵蓋」說法不對（MINOR） | 改為「只確認 p4c／bmv2 吃得下，不成格」 | Q3 |
| K23 | Q4(b) 說「Cut 2 不可能有紅」是錯的（MAJOR） | 重寫：(b) 會有 T8、R2、Q2、CH4 的紅 | Q4 |
| K24 | Q5 的好處取決於 N 的修法；頻率與範圍兩個軸混在一題（MINOR／MAJOR） | 改題為「要不要 N」，單一軸 | Q5 |
| K25 | Q6 的「同一版」包含 HEAD 與同事的未提交檔，好處兌現不了（MAJOR） | 只對「動 lab 的那一面」設閘；受測系統只記錄 | Q6 |
| K26 | Q7：工具不存在、語意沒定、漏了 s1.sh:7、T4 的標籤錯、選項不互斥、少了手寫選項（MAJOR） | 重寫為四個互斥選項；寫明工具不存在；補上 s1.sh:7、don't-care 與 priority 語意、port 9090；標籤改為 PF-T 的 live 版 | `s1.sh:2-21`、`int.p4:42-43`、`p4_client.py:1655-1662` |

- **計數**：26 條，全部採納，0 條反駁。
- **行數**：r2 是 898 行，r3 是 825 行。

### 11.3 r3 → r4（限定範圍）

**範圍**：只修決策表依賴的項目，加上判官 r3 的四個設計 MAJOR（A–D）；可以等 Cut 1 的 MINOR 列在 §12。

- 每一條都先對碼驗過；判官引的位置全部成立。
- 驗過的位置：
  - `p4_client.py:780-786`；
  - `p4_testbed_topo.py:34-38`、`ndtwin-lab:312,1665`；
  - `stack.sh:19`、`ndt:56`；
  - int-v1 的 `utils/Makefile:6`、`linear-topo/s1-runtime.json:3`、`include/fwd.p4:64-66`、`include/int_source.p4:116`；
  - `convert.py:361-370`、`preflight.py:881-908`。

| ID | 判官 r3 的發現（等級） | r4 怎麼處理 | 證據 |
|---|---|---|---|
| L01 | Q5：拿掉 N 之後，thrift 讀的格仍有路徑會假綠；(b) 在 r3 下做不出來（MAJOR） | §2.1 新增「同窗負讀」規則，§2.3 的 T2、T3、M1、M2、C1 都寫上負讀；「oracle 讀不到」的 fixture 擴到 static 格；Q5(a) 的代價寫明只剩 K3；Q5(b) 改寫為「要照 r3 新寫一張 N 表」，並寫出真實代價 | §2.1、§2.3、§5.2-①、Q5 |
| L02 | Q6：動 lab 的那一面不完整（MAJOR） | 補上 `p4_proxy/mininet/**`、`run_external_controller.py`、`convert.py`、`stack.sh`、`heartbeat_drop_check.py`、`preflight.py`、`cpu_probe.py`、`orphans_verdict.sh`；proxy_agent 與 kernel 被排除在外，這一點寫成 (a) 的代價 | `ndtwin-lab:312,1665`、`p4_testbed_topo.py:34-38`、`ndt:56`、`stack.sh:19` |
| L03 | A：CP2 的 409 在判定順序下永遠綠不了（MAJOR） | 第 1 步只收「NDTwin 做不到」的答案；預期中的拒絕（CP2 的 409、K1-neg 與 T3-neg 的 404）算及格；加 fixture | §2.1、CP2 那一行 |
| L04 | B：T2 分不出 runtime default 與編譯時的 default（MAJOR） | s2 的 runtime default `stamp(0x2A)` 與編譯時的 `stamp(0)` 不同；拿 s3 做負讀 | T2 那一行 |
| L05 | C：C1 讀錯了 thrift 物件（MAJOR） | 先 `mirroring_get 7` 讀出 mgid，再 `mc_dump` 那個 group，預期 {p1} | `p4_client.py:780-786` |
| L06 | D：gate 格的缺陷會讓整輪 PROBE-BROKEN；L652 的「或」沒定（MAJOR） | 規則 D：gate 格不是 GREEN ⇒ 依賴的格 NOT RUN 並寫明原因，整輪仍可發佈；gate 都綠才判 PROBE-BROKEN；§7.6 不再寫「或」 | §2.1、§7.6、§5.2-① |
| L07 | Q2 的範圍算錯（MINOR，決策表要的） | core 做得到 6–10；full 做不到 3–4 以上；註明每組加起來是 16 | §5.1、Q2 |
| L08 | Q4(b) 的 Cut 2 紅色清單錯（MINOR，決策表要的） | 改成只有 T8、R2 | Q4 |
| L09 | Q7(a) 沒改 p4info 路徑（MINOR，決策表要的） | 三份都改；寫明預期唯一 FAIL 的那一列 | `linear-topo/s1-runtime.json:3`、`preflight.py:226-232,881-908` |
| L10 | Q7(d) 說 pre-flight 會過是錯的（MINOR） | (d) 改為「只改路徑」，並標推論 | 同上 |
| L11 | Q7(c) 的前提沒寫（MINOR） | 寫明要先有 Cut 2 的 B 與 Cut 5 的論文 app 模式 | Q7 |
| L12 | Q7「修好之後直接轉 live」沒標推論（MINOR） | 補【推論】 | Q7 |
| L13 | Q7 的 (a) 與 (c) 不互斥（MINOR） | (c) 改為「(a) 加上 external live」，四個選項成為互斥的計畫 | Q7 |
| L14 | Q7(b) 的「port 換算」不適用（MINOR） | 註明輸出是 runtime JSON，port 換算不適用 | Q7 |
| L15 | §0 與 §4.4 的時間不一致（MINOR） | 改成一致的 19–22 分鐘 | §0 |
| L16 | Cut 2 的看過紅用到了 Cut 3 的格（MINOR） | 看過紅按 Cut 拆開；Cut 2 只跑 K1、TTL1 | §5.2-④、§8 |
| L17 | 「可以等 Cut 1」的那批 MINOR | **本輪不做**，列在 §12 | §12 |

- **計數**：
  - 採納 16 條（L01–L16），其中 L01 包含判官 §2 的負讀清單；
  - 依指示延後 1 組（L17，§12 列了 12 項）；
  - 反駁 0 條。

### 11.4 r4 → r5（只改 §9 的三題）

判官對 r4 做了限定範圍的複審：A–D 與決策表之前要修的 MINOR 都已關閉，Q1–Q4 成立。剩下三題，每一點我都先對碼驗過，引用全部成立：

- `ndt:3569`；
- `ndtwin-lab:99,233-241,312,1665-1666`；
- `ntg_bmv2_topo.py:51-52,57-58,95,111,127`；
- `convert.py:504-508`；
- int-v1 的 `int.p4:5-9`、`include/int_source.p4:68-72`；
- `preflight.py:1136-1142,1190-1216,1232-1237`（`--no-compile` 存在）；
- `p4_testbed_topo.py:217-218`。

| ID | 判官的發現（等級） | r5 怎麼處理 | 證據 |
|---|---|---|---|
| N01 | Q6：動 lab 的那一面漏了以 root 執行的碼——NTG repo、ntg-env、系統 Mininet、helper 的設定檔（MAJOR） | **閘門反過來**：只列「允許不同」的（proxy_agent、kernel、tests、`doc/**/*.md` 與 `doc/audit/**/*.tsv`），其餘全部要相同，含 NTG repo、三個 venv、系統 Mininet、helper 與 `/etc/ndtwin-lab.conf`、二進位。「探測器、`ndt`、helper 都不執行 tests 與 doc 文字檔」這個推論寫進 (a) 的代價。後果那一行改成和閘門一致 | `ndt:3569`、`ndtwin-lab:99,233-241,312,1665-1666`、`ntg_bmv2_topo.py:51-52,57-58,95,111,127` |
| N02 | Q7：預期的唯一 FAIL 列寫錯了——編譯也會 FAIL，而且 ternary 檢查報的是 2 個 problem（MAJOR） | (a) 改成把 `include/` 抄進 package（不用 `--no-compile`，理由寫在 Q7）；預期改成「只有 entries 那一列 FAIL，2 problem(s)，src_addr 與 dst_addr」；(c)、(d)、後果一併改 | `convert.py:504-508`、`int.p4:5-9`、`preflight.py:218-234,1136-1142,1190-1216`、`ndt:2064-2077` |
| N03 | Q5：照 L205 自己的規則，「只剩 K3」是錯的（決策表之前要修） | T4–T7、C2、MT1–MT3、R3 都加上「寫入前不在」；K2 加非零前提；PL2 拿掉 thrift 那一半，改看控制器的仲裁回覆；T1 的負讀改成明確的「不在」；Q5 (a) 的代價與 (b) 的最後一句重寫；§12 第 7 項同步。建議不變——這些格今天都是紅的 | `p4_testbed_topo.py:217-218` |

- **計數**：3 條，全部採納，0 條反駁。

### 11.5 r5 → r6（最後的精確修正）

每一點都先對碼驗過，引用全部成立：

- `p4_testbed_topo.py:1201-1211`；
- `link_telemetry.py:818-821`；
- `psample_sflow_emitter.py:56-65`；
- `sflow_emitter.py:63-71`（只用標準函式庫）；
- `ntg_bmv2_topo.py:100`；
- `convert.py:422-429,495-497,516-521,605-610`；
- `preflight.py:1088-1093`。

| ID | 發現（等級） | r6 怎麼處理 | 證據 |
|---|---|---|---|
| P01 | Q6：`proxy_agent/sflow_emitter.py` 會被 root 執行（MAJOR） | 移到必須相同那一邊；(a) 的好處與代價改成都成立。另照指示做了一次 grep：`p4_proxy/mininet/*.py` 的非標準函式庫 import 與 `sys.path` 修改、`ndtwin-lab` 的 `$KERNEL_DIR/{src,build,p4_proxy/proxy_agent}` 參照；沒有找到其他從 root 路徑碰到 `proxy_agent/` 或 `src/` 的檔 | `p4_testbed_topo.py:1201-1211`、`link_telemetry.py:818-821`、`psample_sflow_emitter.py:56-65` |
| P02 | Q6：好處的範圍寫得太大；閘門沒涵蓋的沒有寫出來（MINOR） | 好處限定在閘門指紋涵蓋的範圍。OS 工具（tmux、tc、ip、ethtool、sudo）與 NTG repo 的每一個檔（含 `NTG.yaml`）各用一行收進指紋；`__pycache__` 與其他 OS 檔案寫成代價；後果那一行補上 doc 的 md／tsv | `ntg_bmv2_topo.py:100` |
| P03 | Q7：步驟順序 convert 不允許；編譯 PASS 沒標推論；(c) 的前提沒寫（MINOR） | 改成六步：編譯 → 改路徑 → 寫兩筆 → convert → 抄 `include/` → pre-flight；編譯 PASS 標【推論】；(c) 寫明 external 的 package 不帶 entries，而且要有 `mycontroller.py` 替身 | `convert.py:422-429,495-497,516-521,605-610`、`preflight.py:1088-1093` |
| P04 | Q5：CP4 少了「剪線前不指 p5」的明確負讀（MINOR） | 補上 | CP4 那一行 |

- **計數**：4 條，全部採納，0 條反駁。

---

## 12. 延到 Cut 1 的（判官 r3 的 MINOR，本輪依指示不做）

1. **SC-count**：精確等於 sent 時，上游掉包會誤觸。改為和 s2 ingress 的 netdev 增量比，或要求收端零掉包。
2. **SC-reg**：「≠0」接受任何值。改為 marker 選定的非零值。
3. **SC-qstamp**：斷言 sender 送的確實是 `id=0`，免得旗標是 sender 自己設的。
4. **SC-ttl**：h4→h6 有 2 跳與 4 跳兩條路。跳數改從 thrift 讀到的 lpm 路徑算，不從 TP1 的拓樸算。
5. **mutant 的 p4info 必須逐位元相同**：S0 斷言它的 sha，例如 NO_QSTAMP 不能拿掉 `q_stamp` 表。
6. **M8 的 fixture**：改用 0x1236、但 MAC 對錯或 samples 沒增加的那一列。
7. **K3**：改為依賴 SC-count，免得 0＝0 綠。r5 補完寫入前負讀（T4–T7、C2、MT1–MT3、R3）、K2 的非零前提、PL2 與 T1 的修正之後，這是 Q5(a) 已知唯一還開著的路徑。
8. **P4**：收到 packet-in 算 GREEN 還是 PARTIAL(b)，要定下來。
9. **埠攔截**：
   - 改包 `socket.socket.connect`；
   - 涵蓋 `::1` 與 `localhost`；
   - 在測試裡 stub 掉 `grpc`；
   - `Config` 要帶 HTTP client 物件，不只是 URL。
10. **finally**：
    - `ndt down` 失敗就不 release；
    - qdisc 不一致不阻擋 down、還原與 release，只有 `recover.sh` 會在這裡停。
11. **recover.sh**：claim 已經過期、`app_package_override` 仍指向這個 run 時，以同一個 owner 重新 claim 再收拾。
12. **`qdisc_before` 的時機**：改在 up 之後、下 netem 之前寫進 `LAB_STATE.json`。


---

## 13. Q3(b) 的新格（added in Cut 1 for Q3(b)，未經審查）

> **以下每一列都是 added in Cut 1 for Q3(b)**：決策者 2026-10-03 對 Q3 選了 (b)，不是本稿建議的 (a)。
> r6 只為 (b) 估了價（約多 10 格、lab 多約 4 分鐘），沒有寫格。這一節由 Cut 1 的實作補上，
> **是設計，要審；不是已審的內容**。程式碼：`tools/p4_health/cells/table.py` 裡 `q3b=True` 的列；
> 預測：`expected_today.tsv` 裡 `added=cut1-q3b` 的列。

- **規則照舊**：§2.1 的判定順序、繞過 NDTwin 的 oracle、每個 thrift 相符的 GREEN 配同窗負讀、規則 D；
  NDTwin 沒有 route 的就是 structural 答案。
- ~~**rollup**：core 仍是 16 維。full 從 16 維變成 **22 維**：16 維加下面六個新鍵。~~ **r2 (Cut 1 review)**：撤回。core 與 full 維持 16 維；六個新鍵是第三組 rollup `q3b`（§5.1、§14.2）。
- **構造都編進同一支 `hc_main.p4`**（S0 證明編得過，見 SUMMARY-cut1.md），不另開第二支程式。

| 新鍵（added in Cut 1 for Q3(b)） | 格 | scope／種類 | GREEN（NDTwin 那一半） | RED（歸因） | oracle |
|---|---|---|---|---|---|
| `action_profile` | AP1 action profile | ext／active | 負讀：寫入前 `act_prof_dump` 沒有這個 member。NDTwin 寫 member 與指向它的 entry；寫入後 `act_prof_dump` 有 member，`table_dump` 的 entry 指向它 | **今天預測**：沒有 route；writer 只建直接 action 的 EXACT／LPM（`p4_client.py:133,1204-1208`）（`structural`＋`bmv2`） | thrift；B |
| | AS1 action selector | ext／active | 同 AP1，對象是 group（`act_prof_dump` 的 GROUPS） | 今天同上 | 同上 |
| `idle_timeout` | IT1 | ext／active | NDTwin 寫一筆帶 idle timeout 的 entry（`table_dump` 顯示 `timeout is …ms`），entry 老化後 NDTwin 把 IdleTimeoutNotification 報出來 | **今天預測**：POST 沒有 idle timeout 欄位；stream 只處理 packet 與 arbitration（`p4_client.py:526-551`）（`structural`＋`bmv2`：B 收到 notification） | thrift；B |
| `value_set` | VS1 | ext／active | 負讀：寫入前 `pvs_get` 沒有這個值。NDTwin 寫 ValueSetEntry；寫入後 `pvs_get` 有 | **今天預測**：沒有 route（`structural`＋`bmv2`） | thrift `pvs_get`（唯讀；`pvs_add` 會讓 stock bmv2 abort，見 SUMMARY）；B |
| `recirculate` | RC1（依賴 SC-recirc） | ext／active | 程式對 dport 40091 resubmit 一次、recirculate 一次。twin 只算一次：G1 成立、鏈路位元組＝netdev、流表身份正確 | 位元組被重複計算，或身份丟失（`structural`；netdev 是證據） | netdev＋sender argv |
| `hash_random` | HR1 hash | ext／active | s1 以 5-tuple 的 hash 在 p4／p5 兩條上行之間選。twin 有用量的上行＝netdev 有位元組的上行 | 不一致（`structural`） | netdev |
| | HR2 random | ext／active | 前提：netdev 顯示兩條上行都有位元組（否則 NOT RUN）。twin 兩條都有用量 | twin 只看到一條（`structural`） | netdev |
| `header_union` | HU1（依賴 SC-union） | ext／active | `header_union l3alt_t { ipv6_t v6; alt6_t x; }`，0x86DD／0x1238 選成員。G1，加上側表一列：ethertype 0x86DD、MAC 對＝這對 host、`samples` 窗內增加 → PARTIAL(a)；流表也有 IPv6 身份 → GREEN | 連側表那一列都沒有 | netdev |
| `custom_headers`（既有鍵） | VB1 varbit | ext／active | **NOT RUN by design**：varbit 尾段在線上就是 UDP payload，twin 從不解析到 L4 之後，所以 NDTwin 那一半與 CH6 相同；p4c／bmv2 吃得下由 S0 的編譯與離線 probe 證明，那不是 NDTwin 的一半 | — | — |

**新自檢（added in Cut 1 for Q3(b)）**：

| 自檢 | 內容 | 依賴 |
|---|---|---|
| SC-recirc | 收到的 RC1 marker，diffserv 帶 0x04（resubmit）與 0x08（recirculate） | SC-fwd |
| SC-union | 收到的 IPv6 marker，hop limit＝64−跳數 | SC-fwd、TP1 |

**歸屬 Cut**：AP1、AS1、IT1、VS1 需要 B 的歸因，排在 Cut 2；RC1、HR1、HR2、HU1 要流量與 G1，排在 Cut 3。

> **r2 (Cut 1 review)**：上表的 IT1、VS1、RC1、HR1、HR2、HU1、VB1 以及 AS1 的 oracle 都改了，改過的列整理在 §14.2，以 §14.2 為準；上表留作 r1 的紀錄。


---

## 14. r2 (Cut 1 review)：審查後改的設計（未經審查）

> 這一節的每一條都是 **r2 (Cut 1 review)**：Cut 1 的審查判 FIX，決策者對 MAJ-9、MAJ-10 下了裁示，下面是照做後的設計。
> **是設計，要審**。程式碼：`tools/p4_health/cells/{verdict,table}.py`、`lab_round.py`、`recover.sh`；
> 預測：`expected_today.tsv` 裡 basis 以「r2 (Cut 1 review)」開頭的列。

### 14.1 判定順序與對照（MAJ-1、MAJ-2、MAJ-3）

- **0. 答案讀不到 → NOT RUN**：observer 在 proxy 或 kernel 沒回 2xx JSON 時，交出 `answer=None`。舊規則下，PL1 會判成假紅（「s1 reports pipeline None」），M1 會判成假綠（applied＝recorded＝None）。
- **0b. 對照決定 K1／T3**：K1-neg、T3-neg 先判。對照沒觀測到 → K1、T3 是 NOT RUN；對照答錯 → PROBE-BROKEN。`health.json` 加一個 `controls` 欄位。
- **4b. 每格寫明它需要的讀數**（`need`：`a:<key>`、`o:<key>`）。缺一個就 NOT RUN。
  - 比較函式只對已經讀到的值下判斷。
  - 例子：TP1 的 fabric oracle 是空的 → NOT RUN；T1、PL1 的 expect 沒涵蓋 s1–s4 → PROBE-BROKEN；HR1 要恰好一條上行。
- **G1 沒讀全**（on_path、主路徑積分、off-path 最大值缺任一）→ NOT RUN。G1 讀全但不成立 → RED。
- ~~**取樣**：身份格的窗裡，link telemetry 一個樣本都沒抽到（`sampled`＝emitter 的計數）→ NOT RUN（§2.3「刺激量」那條）。~~ **r3 (Cut 1 review)** 撤回，改見 §14.6：「沒有樣本」不准由 NDTwin 自己的 emitter 計數決定。

### 14.2 Q3(b) 的格（取代 §13 的對應列）

| 鍵 | 格 | 改了什麼 |
|---|---|---|
| `custom_headers` | VB1 varbit | **改成 CH3 的 alias**（同 CP1＝T1）。理由：NDTwin 必須解析穿過的 varbit 是 IPv4 options（`ipv4_opt_t`，`varbit<320>`）。CH3 的 marker 帶著 options，CH3 的 oracle 就是 options 後面的 5-tuple，另開一格只會是同樣的幀、同一個 oracle。UDP 之後的 varbit 尾段仍編進程式，S0 證明 p4c／bmv2 吃得下。不再有「NOT RUN by design」 |
| `recirculate` | RC1 | ~~**改成 V1 的 alias**~~（**r3 (Cut 1 review)** 撤回，改見 §14.6）。理由：每個 package 都宣告 `telemetry.source=link`，twin 在幀進埠的時候取樣（`link_telemetry.py:312,329-338`），resubmit 與 recirculate 的那一趟不進任何埠，所以 NDTwin 在 recirculate 這一維的那一半就是 V1。SC-recirc 仍是 S0 的程式自檢，不再有依賴它的格 |
| `hash_random` | HR1 hash | 用**單一 5-tuple** 的流。每條上行讀兩個等長的窗：安靜窗（只有心跳與 telemetry）與流量窗。某條上行「承載」＝流量窗位元組減安靜窗位元組 ≥ 送出位元組的 0.2。前提：netdev 顯示恰好一條承載，否則 NOT RUN。twin 依同一規則讀自己的 link usage：承載集合相同 → GREEN，不同 → RED | **r4 (Cut 1 follow-ups)**：前提再加一條——那一條承載的上行必須是沒整形的 s1-eth4（HR1 把整個 800 kbit/s 送在同一條上，高於 s1-eth5 的 0.5 Mbit/s），否則 NOT RUN；刺激量改 24000 幀，見 §14.6、§14.7。
| | HR2 random | 同樣的兩個窗與規則。前提：netdev 顯示兩條都承載，否則 NOT RUN。twin 的承載集合相同 → GREEN | **r4 (Cut 1 follow-ups)**：刺激量 24000 幀（假 RED 約 2.6e-6），見 §14.6。
| `idle_timeout` | IT1 | oracle 改成 thrift 的 `Life: <since hit>ms since hit, timeout is <t>ms`。加上**同窗負讀**：寫入前 `table_dump` 沒有這一筆。前提：since hit > timeout（entry 真的在交換機上老化了），否則 NOT RUN。thrift 的 timeout ≠ 要求的值 → RED；老化了但 NDTwin 沒報 → RED；有報 → GREEN。今天仍是 structural RED：沒有欄位、沒有 notification 出口 | **r4 (Cut 1 follow-ups)**：`reported_after_s` 與 `watched_s` 的編碼先驗，不合法 → PROBE-BROKEN（§2.1、§14.7）。
| `value_set` | VS1 | **在拋棄式 `simple_switch_grpc` 上試過 ValueSetEntry**：stock 與 fabric 的 fast build 兩支都試了，pcap 模式、argv[0] `ndt-hc-vstrial-bmv2`、gRPC 埠 29650 起。Write 回 UNIMPLEMENTED（「ValueSet writes are not supported yet」），Read 也是 UNIMPLEMENTED，兩支交換機都沒死。⇒ Cut 2 在 fabric 上寫 ValueSetEntry **不會**弄死交換機，但 bmv2 這一半的歸因經 P4Runtime 永遠成立不了；thrift 的 `pvs_add` 又會讓 stock bmv2 abort。所以 VS1 今天預測 **UNATTRIBUTED**，value_set 這一維在 q3b rollup 是未判。B 的這一項歸因要改成「記錄 UNIMPLEMENTED」，不當作成功 |
| `action_profile` | AS1 | oracle 改成 entry 指向 **group**（`points_to_group`）；AP1 指向 member |
| `header_union` | HU1 | **兩個成員都要判**。前提：側表的 key 數 ≤ 1000，否則 NOT RUN（上限 1024，`FlowLinkUsageCollector.hpp:740-747`）。0x1238 成員是非 IP，它的 NDTwin 那一半只有側表（同 CH7 的規則），沒有那一列 → RED。IPv6 成員：有流表身份 → GREEN；只有側表 → PARTIAL(a)。自檢 SC-union 的跳數改從 thrift 讀到的 `v6_host` entries 走 | **r4 (Cut 1 follow-ups)**：IPv6 成員的 `flow_identity` 也列進必要的巢狀讀數（缺鍵 NOT RUN；`False` 照判），見 §14.6。

### 14.3 rollup（MAJ-10）

- 三組：core（16 維、core 格）、full（16 維、core＋ext 格）、q3b（6 維、Q3(b) 的格）。
- 三組都在終端機表、`health.json`、`00_table.tsv` 裡並列。
- 預測的 rollup：core 10／3／3／0，full 6／7／3／0，q3b 2／1／2／1。

### 14.4 當機收拾（MAJ-5、MAJ-6）

見 §4.5 第 2 項與第 3' 項的 r2 註記：
- 「是這個 run 的」改用 owner、claim 沒過期、override、ndt 自己會寫的 note 判斷；
- 只在 claim 是自己的、或沒有 owner，而且沒有量測時才重新 claim；
- 行程以 pid＋start time＋marker 認；
- teardown 在每個改共用狀態的步驟之前重讀 claim。

### 14.5 其他（MINOR，有決定的）

- **SC-count**：拿掉 netdev 那種比法。介面計數包含心跳的幀，不可能等於 marker 數。只留「收端零掉包」那一種，有掉包就不判（NOT RUN）。
- **PF-T 的 static 歸因**：證據是拋棄式 stock bmv2 經 thrift 收下並 dump 回一筆 ternary entry。這和 PF-T 列寫的「同 T4 的 bmv2」（B 經 P4Runtime）不是同一條路，已揭露；Cut 2 的 B 會補上 P4Runtime 那一條。
- **CS1**：仍列為 gate 格，但沒有任何依賴邊。這不一致留給設計審查決定，表是 row-driven，加一條邊只改一行。


### 14.6 r3 (Cut 1 review)：第二次審查之後改的（未經審查）

> 這一節每一條都是 **r3 (Cut 1 review)**：Cut 1 第二次審查判 MERGE AFTER FIXES，下面三個 MAJOR 加上決策者對 alias 的裁示，照做後的設計。**是設計，要審。**

- **取樣的下限（NEW-A）**：
  - 「刺激太小、抽不到樣本」的 NOT RUN，只看 **sender 自己回報的送出數**：
    - link telemetry 取樣 1/256，下限定為期望樣本數 ≥ 19；
    - 換算成送出幀數：19 × 256 ＝ **4864 幀**；
    - 期望 19 個樣本時，一個都抽不到的機率約 6e-9。
  - 低於下限：該格在步驟 3 判 NOT RUN。
  - 達到下限：twin 什麼都沒看到就是 **RED**。emitter 壞了是 NDTwin 的錯，不是運氣。
  - NDTwin 自己 emitter 的計數完全不參與這個判斷。
  - telemetry-none 那一次因此照設計得到 V1、CH1、CH7 都是 RED。這一點有一個測試，把 telemetry-none 的觀測送進真的格子檢查。
  - HU1 的兩個成員各自要過下限（`sent`、`sent_x`）。
- **「從沒發生」的編碼（NEW-B）**：
  - 計時讀數用一個**值**表示「整個窗都盯著、事情沒發生」：`never`，另外附 `watched_s`。
    - 用在 TP2／TP4 的 `down_after_s`、CP4 的 `rerouted_after_s`、IT1 的 `reported_after_s`。
    - `watched_s` 小於期限 → NOT RUN（沒盯滿）。
    - `never` 加上盯滿 → RED。
    - 鍵本身不在 → 讀數沒取到（步驟 4b）→ NOT RUN。
  - CP4 的 `port_after_cut` 多一個值 `gone`：剪線後 s1 的 thrift dump 裡沒有那一筆 → RED。
  - `rerouted_after_s` 與 `watched_s` 都列進 CP4 的 `need`，和其他鍵一致。
- **`down-done`（NEW-C）**：
  - `lab_round` 在 `ndt down` 成功之後寫 phase `down-done`。之後若 claim 掉了，phase 仍是 `down-done`，另外記 `claim_lost`。
  - `recover.sh` 在 `down-done` 下：
    - 先用 `ndt status` 確認 `bmv2 switches` 與 `host/switch` 都是 0，否則停（rc 4）；
    - ~~跳過第 3–5 步（sniffer、netem、qdisc 比對、down）~~ **r4 (Cut 1 follow-ups)**：跳過第 4–5 步（netem、qdisc 比對、down）；第 3 步（停行程）照做，見 §4.5 與 §14.7；
    - 直接還原 knob、release。
    - **r4 (Cut 1 follow-ups)**：過期的 claim 是自己的時，也會重新 claim（見 §4.5 的 r4 註記與 §14.7）。
- **RC1（決策者裁示）**：
  - 改成真的格：把 V1 的 G1 檢查用在 **RC1 自己的 marker 流**上（dport 40091，程式會 resubmit 一次、recirculate 一次）。
  - 自檢是 SC-recirc，也是它的依賴，所以 SC-recirc 有了依賴它的格（MINOR 8）。
  - 預測 GREEN（推論）。
- **VB1＝CH3 維持 alias。**
  - 輸出上，alias 那一列的歸因欄寫「ALIAS of CH3」。
  - 某一維**所有**被計數的格都是 alias 時，rollup 標出「rests only on an alias: CP1=T1」這樣的字樣（`alias_only`）。
  - `health.json` 另有 `aliases` 欄。
- **對照找不到 route（MINOR 3，決定）**：
  - endpoint 本身不在 openapi 時，對照判 NOT RUN（沒有東西可問）；K1／T3 在步驟 1 判 RED「no route」；整輪仍可發佈。
  - 格自己的答案若聲稱有 route，而對照說沒有 → 讀數不一致 → PROBE-BROKEN。
  - **r4 (Cut 1 follow-ups)**：這個決定在 r3 只寫在格與判定函式裡，觀測器從來沒有設過 `route`，所以真的缺 route 時，FastAPI 自己的 404 讓對照判 PROBE-BROKEN，K1 跟著壞，不是這裡寫的 RED「no route」。現在 `observe_counter` 與 `observe_counter_control` 都讀 openapi 並設 `answer.route`（`ROUTE_PREFIXES` 加了 K1／K2／K3／K1-neg／T3／T3-neg）；openapi 讀不到時**不設** `route`（讀不到不等於缺 route）。T3 與 T3-neg 目前沒有觀測器（Cut 2 才寫），只有 `ROUTE_PREFIXES` 先備好。
- **HR 的刺激量與順序（MINOR 4）**：
  - ~~刺激量：20000 幀、每幀 64 B、總速率 800 kbit/s。每一半的期望樣本數約 39。公平硬幣讓其中一半低於 CARRY_SHARE 的機率小於 1e-5。~~ **r4 (Cut 1 follow-ups)**：這個「小於 1e-5」不成立（見下面與 §14.7），刺激量改成 24000 幀：
    - 24000 幀、每幀 64 B、總速率 800 kbit/s，15.4 s。HR2 分到 s1-eth5 的那一半仍是 400 kbit/s，低於 0.5 Mbit/s 的整形。
    - 門檻是**絕對的**：`CARRY_SHARE × sender 的 flow_bytes`，也就是 `CARRY_SHARE × 幀數 / 256` 個樣本（24000 幀是 18.75，所以一半要有 19 個樣本）。
    - 把樣本當 Poisson：HR2 每一半約 Poisson(46.9)，少於 19 個的機率約 1.3e-6，任一半少於的機率約 2.6e-6，低於 1e-5。（20000 幀時是每半 9.9e-6、任一半 2.0e-5，所以原來的說法不成立。）
    - 假設：每個樣本記入 256 × 該幀的位元組；安靜窗的雜訊算 0。
  - 順序：TP2 → HR1／HR2 → Q1（Q1 仍是最後一個）。**r4 (Cut 1 follow-ups)**：`table.ORDER` 目前**沒有任何東西讀它**——Cut 1 沒有 active 格的排程器，Cut 3 的排程器必須消費它；這裡只是寫下來的約定，不是已經被執行的事實（§14.7）。
- **其他**：
  - IT1 的報告期限是 entry 老化後 10 s（MINOR 5）。
  - 探針那一方給的輸入（目標速率、宣告的埠、marker 欄位）若是空的 → PROBE-BROKEN（MINOR 1）。
  - HU1 巢狀的讀數缺了 → NOT RUN（MINOR 2）。
    - **r4 (Cut 1 follow-ups)**：巢狀的鍵清單補上 `v6.flow_identity`；「讀了、沒有流表身份」是 `False`，仍然判（PARTIAL(a)）；只有鍵缺才是 NOT RUN。
  - kill 失敗的行程留在 LAB_STATE 裡（MINOR 6）。
    - **r4 (Cut 1 follow-ups)**：kill 失敗現在也記進 `rec["problems"]`，那一輪不算 complete（r3 只留在 LAB_STATE，那一輪仍讀作完整）。
  - `recover.sh` 判斷探測器是否還活著時，用 pid 加 start time（MINOR 6）。
  - `recover.sh` 的 measuring 檢查讀不到時當成忙碌，不放行（MINOR 6）。
    - **r4 (Cut 1 follow-ups)**：輸出裡沒有 `measuring` 或 `orphaned` 其中一列，也當成忙碌。


### 14.7 r4 (Cut 1 follow-ups)：第三次審查留下的 MINOR 與一項衛生（未經審查）

> 這一節每一條都是 **r4 (Cut 1 follow-ups)**。第三次審查判 MERGE，留下十個 MINOR；本輪全做，另加一項衛生（第 11 項）。**是設計，要審。** 分支 `fix/p4-health-cut1-followups`，從 trunk `73cff685` 開。

1. **recover.sh 在 `down-done` 的重新 claim**：`ndt down` 會刪 `app_package_override`（`ndt:1597-1601`），所以原來的「override 等於 package」條件在這個 phase 永遠不成立，過期的 claim 會被誤判成「現場不是這個 run 的」（rc 3），而那個 run 已經 down 完。現在用 `override_ours`；phase `released` 另外排除。見 §4.5。
   - **r5 (Cut 1 follow-ups)** 收窄上面這句：不是「`override_ours`」一律成立，而是 override 等於 package，或 override 為空 ∧ phase 是 `down-done` ∧ 過期的 claim 檔是自己的 owner；其他 phase 維持 r3 的 rc 3。`down-done` 的 fabric 檢查先於任何寫入。phase `released` 只做第 3 步（rc 0／7），見 §4.5。kill 失敗的流程以 rc 7 結束。
   - r5 取代 r4 在這裡的「`released` 另外排除」。
2. **`down-done` 保留停行程這一步**：kill 不需要 fabric；kill 失敗的行程是留給這一次重試的。lab_round 的 teardown 也把 kill 失敗記進 `rec["problems"]`，那一輪不算 complete。
3. **HR 的界**：門檻是絕對的，樣本當 Poisson。24000 幀時任一半不夠的機率約 2.6e-6（見 §14.6）。HR1 的 5-tuple 要落在**沒整形的**上行（`table.HR1_UPLINK` ＝ s1-eth4）：HR1 把整個 800 kbit/s 送在同一條上，高於 s1-eth5 的 500 kbit/s 整形。選 5-tuple 是 Cut 3 刺激端的事（S0 已經能為兩條上行各找一個，`probe.log:32`）；格的前提 `hr_pre(1)` 保證選錯時是 NOT RUN，不是一個判定。
4. **K1／T3 的 `route`**：觀測器現在設 `answer.route`，見 §14.6 的 MINOR 3。
5. **HU1 的 `v6.flow_identity`**：列進巢狀必要鍵。
6. **計時讀數的編碼要驗證**：見 §2.1 的 r4 註記。CP4 的 watch 長度改在 `gone` 之前檢查：一條在還沒盯滿期限的時候被讀成 `gone` 的路由，是 NOT RUN，不是 RED。
7. **觀測器契約**：「讀了、沒有」是 `False`／`0`，不是 `None`。見 §2.1 的 r4 註記與 `table.IDENT` 的註解。
8. **`measuring_now`**：必須有 `measuring` 或 `orphaned` 其中一列。見 §4.5。
9. **舊碼的身分**：任何舊碼對新碼的 log，表頭都記舊碼的 git tree sha、檔案的 blob sha 與副本的 sha256（本輪的紅燈 log 也是）。
10. **`ORDER`**：沒有任何東西消費它。排程器是 Cut 3 的；這裡不發明一個。`table.py` 的註解與一個測試（`test_order_has_no_consumer_yet_and_the_comment_says_so`）都寫明這一點：真的有東西開始讀它的時候，這個測試會紅，逼著改註解與本節。
11. **衛生——公開檔案不引用私有紀錄**：`expected_today.tsv` 與 `tools/p4_health` 會進公開的 main。CH4 的 basis 原本引的 `RULINGS-1001.md`（和 CH3 的 `REPORT.md`）是私有紀錄；改成引碼本身：`hc_main.p4` 把 shim 放在 IPv4 與 UDP 之間（`:87-88`、`:249`、`:254-260`），kernel 讀 L4 的位置由 IPv4 header 長度算出、而且只在 protocol 是 TCP／UDP 時才讀 port（`SFlowType.hpp:364,369,386,390-391`），所以 protocol 0xFD 的幀 key 是 protocol 253、port 0。一個測試掃這兩處，不允許再出現 rulings／intake／judge／report 檔名。**沒動的**：`expected_today.tsv` 裡還有 `GAP-2b` 的引用（C1、R2、P4、TTL1、TP4），那是 `doc/audit` 底下的 .md，同樣不在公開 main 上；這不在本輪的範圍，留給決定者。
12. **r6 (Cut 1 follow-ups r6)：這一輪的身分是這一輪自己的**（細節與理由在 §4.5 第 2 項的 r6 註記）：
    - 每一輪的 package 是 run 目錄裡的副本；`LabRound` 拒絕 run 目錄以外的 `package_dir`，`recover.sh` 也要求 `package` 在 run 目錄裡。Cut 1 沒有 `lab` 的驅動程式（Cut 2 才有），所以「把 S0 建好的 package 複製進 run 目錄」是 Cut 2 驅動程式要做的事；Cut 1 只能擋住不照做的情況。
    - `LAB_STATE.claim_expires`：claim 成功後立刻記；`recover.sh` 在 live 與過期兩個分支都要求相等。過期分支從此不再接手「檔案不見」的 claim（沒有東西可對，rc 3）。`recover.sh` 重新 claim 後把新的 `expires` 寫回。
    - `recover.sh` 對缺欄位的 state 檔 rc 2（見 §4.5）。
    - `recover.sh` 第 9 行的「先證明現場還是探測器的」，現在的依據是上面兩樣；剩下沒證明的寫在 §4.5 與該檔表頭。
    - `claim-unverified` 是新的 phase：`ndt claim` 回 0、claim 檔卻不顯示是自己的，不 up、不 release。
13. **r7 (Cut 1 follow-ups r7)**：第 12 項上線前的審查找到的三件事，詳見 §4.5 第 2 項的 r7 註記。
    - F1：knob 的讀法和 fixture 的格式（對真的 `ndt` 是假綠）。
    - F4：`recover.sh` 自己的 `ndt down` 之後記 phase。
    - F2：knob 不在時的 live claim 只認這一輪自己的 note 或 `ndt down` 的 note；`.overrides` 裡有我們的 `expires` 就不動。
    - 順帶：`ndt down` 之後再讀一次 claim、claim 檔不見與沒記到 `claim_expires` 的訊息、殘餘風險的措辭（同一個結束秒）、`LabRound` 的路徑只解析一次、`expires` 的判斷。
    - 沒做：每輪自己的 owner 或 claim 的 nonce（會關掉整個「同 owner」類，要在 Cut 2 的驅動程式裡做）。
14. **r8 (Cut 1 follow-ups r8)**：重新審查找到的兩個 `recover.sh` 收尾的舊洞，都因為 stub 不像 `ndt` 而一直是假綠；詳見 §4.5 第 2 項的 r8 註記。
    - N1：knob 不在時先問 `ndt status`，沒有 fabric 就跳過第 4–5 步；`ndt down` rc 3 算做完。
    - N2：`recover.sh` 自己重新 claim 的那一個 claim，release 用 `--force`（原因印出來）；rc 6 的訊息不再叫人把 baseline 值寫回去。
    - 規則：每一個修法所依賴的 stub 行為都必須來自 `ndt`／`qdisc_snapshot.sh` 的真實程式，並在旁邊註明行號。
    - 沒做：`knobs_match_snapshot` 的條件沒有變異體——第 6 步成功之後它必然成立，沒有測試能讓它不成立。
