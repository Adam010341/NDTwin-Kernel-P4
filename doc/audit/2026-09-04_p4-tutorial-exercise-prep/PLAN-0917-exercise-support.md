# PLAN-0917 — 讓 NDTwin kernel／proxy 支援 p4lang/tutorials 全部 13 支 exercise：改法方案（等 Adam 點頭才動手）

session「9/17 orchestrator」2026-09-17 寫；基底 trunk `70615ec5`。材料：本目錄 `GAP-ANALYSIS.md`（合成）、
`GAP-1-exercise-requirements.md`（需求側）、`GAP-2-ndtwin-p4-capabilities.md`（供給側）、`COMPILE-MATRIX.txt`、
`DRIVER.md`＋`drive_exercise.py`＋`runs/`（09-08 Adam 以 root 在 **tutorials 自己的 harness** 上跑的 4 份 raw）。

[Co-developed with claude code -- Adam]

## 0. 證據等級（不可混用）

- GAP 系列的每一條 gap 都是【讀碼推導】（09-08）。**本檔 09-17 新做的只有一件事：逐處 `grep` 確認那些寫死點在
  trunk `70615ec5` 還在**——行號有漂（`Mininet()` 662→852、json_path 360→361／624→806、election_id 234→255），
  機制與後果**沒有**被實跑驗證。唯一【跑過】的是 2026-08-13 的 mastership 實測（GAP-ANALYSIS §5-②）。
- 09-08 那 4 次 `drive_exercise.py` 實跑證明的是「exercise 的預期行為」與「driver 能用」；**在 NDTwin fabric 上 0/13**。

## 1. 先要裁的：「支援所有 exercise」是哪一檔

| 檔位 | 內容 | 代價 |
|---|---|---|
| **L1** | 13 支在 NDTwin fabric 上 **skeleton 紅／solution 綠**（`drive_exercise.py` 判定，與 09-08 tutorials harness 的 raw 對得上） | §3 前兩階段 |
| **L2（建議對教授用這個）** | L1 ＋ IPv4 的 7 支（basic／qos／ecn／firewall／load_balance／p4runtime／multicast 的 ARP 半）twin 觀測得到（既有口徑）；6 支自訂標頭（basic_tunnel／calc／source_routing／link_monitor／mri／flowcache）**明標「轉得動、分身盲」** | §3 三階段 |
| **L3** | L2 ＋ 擴 `FlowKey` 與 C++ 解析器讓 6 支也可觀測（GAP-ANALYSIS G6-B，~250 行） | 動已發表的量測口徑、契約測試 `test_GoldenFixture.cpp`／`test_SFlowEmitterRoundtrip.cpp` |

## 2. 三條路（建議路線 2）

| 路線 | 做法 | 對 baseline（Adam 說的 baseline＝`28b8b13` 那套框架、今天的 P4 路徑）的影響 | 代價 |
|---|---|---|---|
| **2「profile 旁掛」（建議）** | 新增一個 profile 層；**沒給 profile ＝ 今天的寫死值逐位元組不變**；exercise 走 `ndt up p4 --exercise <name>` | 無 profile 下行為相同 ⇒ **有紅綠可守**（§5） | 多一層抽象；既有寫死點各改成「讀 profile、否則今天的值」一行 |
| 1「就地通用化」 | 四處寫死直接改成讀 manifest，NDTwin 自己的 fabric 變成一份 manifest | baseline 路徑本身被改寫；P4 側所有測試／閘門跟著動 | 終態最乾淨，回歸面最大 |
| 3「只當觀測者」 | exercise 在 tutorials 自己的 Mininet 跑，proxy 以唯讀模式掛上去看（G3 候選 B） | 幾乎零 | ~60 行；但 6 支全盲、kernel 不參與控制——對教授只能說「看得到」不能說「支援」；適合當階段一的墊腳石 |

## 3. 路線 2 的檔案級改動（行號＝trunk `70615ec5`，09-17 grep 過）

### 3.1 新增（純加法，不動既有路徑）
- `p4_proxy/proxy_agent/profile.py`：一個 dataclass＋loader。欄位：`topology_file`、`pipelines{dpid: (p4info, json)}`、
  `entries[]`（表名／match／action／params／is_default，per-dpid）、`host_commands{host: [...]}`（default gw、靜態 ARP）、
  `election_id`、`cpu_port`、`grpc_base`／`device_id_map`、`link_shaping`(bool)、以及**要跳過的既有開機步驟**
  （`install_initial_routes`、clone session 250、LLDP beacon）。**`load(None)` 回傳今天的寫死值。**
- `tools/p4_exercise/convert.py`：tutorials 的 `topology.json`（hosts／switches／links `sX-pN`）＋`sX-runtime.json`
  → NDTwin 拓樸 JSON（`nodes[]`/`edges[]`，schema 見 GAP-2 §topology）＋profile。純函式、有單元測試（skeleton／solution 各一組 fixture）。
- `p4_proxy/proxy_agent/api_routes.py`＋`p4_client.py`：
  - `POST /p4/table_entry`（G5）：`{dpid, table, match{field: v | [v, prefix_len]}, action, params{}, is_default}`；**只 exact＋lpm**；
    表名／欄位名／action 名／位寬一律向 p4info 查（重用 `_get_table_id` 那組 `:459-481`）；`is_default` 走 `is_default_action`。
  - `POST /p4/multicast_group`（G8）：與 `write_clone_session()`（`:338`）對稱的 `multicast_group_entry`。
  - `GET /p4/counter/{name}`（G7）：重用 `read_egress_counter()` 三態契約。
  - 第二個 clone session 呼叫點（G9a）：`write_clone_session(session_id, egress_port)` 本來就是參數。
- `sflow_emitter.py`：packet-in metadata id 開機從 p4info `controller_packet_metadata` **按名字**解析（G1）；
  **自檢：對 `ndtwin_switch.p4info.txt` 必須解出 reason/ingress_port/egress_port/frame_length/sampling_rate＝1..5，否則拒絕啟動**
  ——這條自檢就是 G1 的紅綠格。
- `tools/test_workflow/ndt`：`up p4 --exercise <name>`（讀 `~/tutorials/exercises/<name>`，經 convert 產 profile）；
  `stale_pipeline`／`sample_rate` 對非 ndtwin pipeline 回 `n/a (exercise profile)` 而不是 `unknown`。
- `drive_exercise.py`：`--fabric ndtwin`（bring-up 改走 `ndt up p4 --exercise`，判定步驟不變）。

### 3.2 改讀點（每處一行，`profile.x if profile else <今天的值>`）
| 檔:行 | 今天 | 改成 |
|---|---|---|
| `proxy_agent/main.py:185-186` | `p4_src/build/ndtwin_switch.{p4info.txt,json}` | `profile.pipelines[dpid]`（G4，per-dpid） |
| `proxy_agent/main.py:113-120` | 主機位置四等分公式 `1+(i-1)//(N//4)` | `topo_from_json.host_links()`（G2-A） |
| `proxy_agent/main.py:154` | `DEFAULT_SWITCH_DPIDS = tuple(range(1, 11))` | 由拓樸檔推導（G2-B） |
| `mininet/p4_testbed_topo.py:361`／`:806`、`ntg_bmv2_topo.py:67` | json 路徑抄本 | 同一個 helper |
| `mininet/p4_testbed_topo.py:852` | `Mininet(topo=topo, controller=None, autoSetMacs=True)` | profile 帶 `link_shaping` 才加 `link=TCLink`＋`bw`（G2-C；**只在 exercise fabric 開**） |
| `mininet/p4_testbed_topo.py:274`、`p4_client.py:34`、`ndtwin_switch.p4:45` | CPU port 255 三份抄本 | profile.cpu_port（G9b；flowcache 要 510） |
| `p4_client.py:255-256`／`:343`／`:433`／`:870` | election_id 寫死 `(0,1)` | 參數（G3）；**預設值要不要抬高由 Adam 裁**——抬高＝改 baseline 行為，要用 `p4_proxy/reference/p4runtime_mastership_probe.py` 前後對照 |
| `mininet/grpc_ports.py:48` | `GRPC_PORT_BASE = 30050`、device_id＝dpid | profile 可覆寫成 tutorials 的 `50051+i`／`dev i-1`（G3 位址對齊；p4runtime／flowcache 的 `mycontroller.py` 寫死） |

### 3.3 Kernel（C++）——前兩階段**不動**，第三階段只動一處
- `src/ndt_core/collection/FlowLinkUsageCollector.cpp:1296-1314`：L4 port／ICMP 讀固定字組位移 `data[index+24]`，全檔無 `ihl`
  ⇒ 改讀 `ihl` 決定偏移（G6-A'；**ihl==5 時位元組相同，既有流量結果不變**）＋非 IPv4 樣本計數（今天 `:1266` 靜默 `continue`）。
  這是修錯誤不是擴功能；mri 今天會被**讀錯**而不是讀不到。

### 3.4 profile 下要跳過的既有開機步驟——每一步跳過都要在 `GET /p4/switch_state` 揭露
`install_initial_routes`（BFS `/32` 灌 `MyIngress.ipv4_lpm`——12/13 支沒有這張表）、clone session 250（exercise 的 pipeline 沒有
`SAMPLE_SESSION`）、LLDP beacon（packet-out 用的 metadata 名字對不上就跳過）。**原則：跳過≠靜默**，狀態端點要說「這台在 exercise
profile 下沒有遙測」，否則就是 GAP-ANALYSIS §5-① 那種「報零不報錯」。

🆕 **09-18（TICKET-P2-F，live 量到才知道的）：跳過的清單還要往上傳一層——`external` 模式下
`ndt up` 的 `N up`／`N enabled` 是讀數，不是閘。** 那個模式不推 pipeline，探針對沒程式的 bmv2 回
`FAILED_PRECONDITION`，twin 自己的 liveness 政策因此判它 Down；唯一會把 isUp 寫成 true 的是 proxy 的
`inform_switch_entered` 背景重試，而 kernel 的 pingWorker 一秒後又寫回 false。所以那兩個數字量到的是
一場競賽——`live-p1/03` 印過 `3 up`，同一支腳本一秒後的 `ndt status` 是 `0 up, 3 enabled`。
閘改成「模型宣告的每台都在 `switch_state` 裡、而且探針**被回答了**」；**「這些交換機該是 up」這件事，
要等練習自己的控制器載入 pipeline 之後才斷言**（03 用控制器 log 解析出的集合對帳）。

## 4. 階段、解鎖、怎麼驗

| 階段 | 做什麼 | 解鎖 | 驗證（skeleton 紅／solution 綠＝天然 mutation 對） |
|---|---|---|---|
| **一** | profile 骨架＋G2-A/B（拓樸讀檔）＋G3（election_id＋位址）＋G1（metadata 按名字）＋convert.py | 拓樸與共存 | ① 無 profile：§5 全綠；② `--exercise basic`（pod-topo）在 NDTwin **自己的** pipeline＋自己的路由下 `pingall` 0%（證拓樸路徑）；③ `p4runtime` 的 `mycontroller.py` 與 proxy 共存不清表（mastership probe 當斷言）。⚠️ **更正 GAP-ANALYSIS §6 階段一的「basic 雙向」**：skeleton 方向要關掉 NDTwin 自動灌路由才做得出來，那是 G5／3.4 的事 ⇒ 真正的雙向在階段二 |
| **二** | G4（per-dpid pipeline，A' 兩步：先收抄本、再 per-dpid）＋G5（`/p4/table_entry`＋default_action）＋3.4 的跳過開關 | **+9 支**資料面（qos／ecn／mri／firewall／basic_tunnel／source_routing／calc／link_monitor／load_balance）＋basic 雙向 | 順序：`basic` 雙向 → `source_routing`（0 entry，只驗資料面）→ `firewall`（**s1 與 s2–s4 兩份 p4info 同時在線**）→ `link_monitor`（default-only 表、每台 swid 不同） |
| **三** | G2-C（TCLink）＋G6-A'（`ihl`）＋G7＋G8＋G9a/b | **+3 支**（ecn／mri 判定成立、multicast、flowcache）⇒ 13/13 | `ecn`（tos `0x1`→`0x3`）、`mri`（swtrace 序列）、`multicast`（h1/h2/h3 通、**h4 不通**）、`flowcache`（控制器起來前後） |

工作量（GAP-ANALYSIS【估】）：一 ~140 行、二 ~330、三 ~205；convert.py／driver 後端／測試另計。**ecn／mri 在 G2-C 之前不進閘門**（qdepth 恆 0 ＝ 假綠）。
🏁 階段二之後 tutorials 就能當 NDTwin 的回歸測試：`drive_exercise.py` exit 0/1/2 ＋ 兩向預期輸出 ⇒ 看得到紅。

## 5. 守 baseline 的方法（每階段結束都跑）
1. 無 profile 下：既有 P4 側 pytest／`tests/shell` 閘門、09-12 的 `merged_checks.sh` 六項全綠。
2. `ndt up p4 4` 後 `GET /p4/switch_state`、`get_graph_data`、`--tag ndt` live cells 與 09-12 的紀錄**逐格同**（binary sha 前兩階段不變）。
3. election_id 若改預設值：`p4runtime_mastership_probe.py` 改前／改後各跑一次，三情境結果附 raw。
4. 每個 gap 的修法自帶一格紅：G1 自檢對錯 p4info 要拒啟；G5 對不存在的表名要 4xx 且不寫；G3 冒名者要被 `PERMISSION_DENIED`。

## 6. 風險與未決（要裁或要記）
- **`/p4/table_entry` 繞過 `rule_journal`**（`topology_manager.py:949-976` 只認 install/delete 的 flow 語意）⇒ proxy 重啟後 exercise 灌的規則靜默消失——本 repo 最常見的缺陷形狀。選項：(a) 階段二先明標「不 journal、重啟即失」並在 `switch_state` 揭露；(b) 一起補 journal（+~60 行）。
- **election_id 預設值**：抬高＝所有既有 P4 fabric 行為改變（雖然只在有外部控制器時可觀測）。
- **G2-C 會改變排隊行為**，與 bmv2 天花板那四張工單的數字不可跨比 ⇒ 只在 exercise fabric 開，`ndt status` 要印出來。
- **bmv2 單佇列下 `enq/deq_qdepth` 是否有值**：GAP-ANALYSIS 沒讀 bmv2 原始碼，【不確定】；階段三跑 ecn 前先拿 tutorials harness 的 raw 對。
- **thrift 9090**：tutorials 的 s1 固定要 9090（09-04 被 dashboard 佔）；NDTwin 用 9091–9100，走 `--exercise` 時 thrift port 由 NDTwin 配、不撞。
- **flowcache skeleton 編不過**是作業本身（COMPILE-MATRIX），driver 的 skeleton 方向對它＝「編譯失敗」才是紅。
- **（09-17 工單 B 挖到）單交換機 exercise（`calc`：`switches: ['s1']`）會被 `topo_from_json.switch_links()` 的
  「model declares no inter-switch links」擋下**——reader 的既有行為；階段二要支援它就得放寬那條（零鏈路的合法情境＝一台交換機）。
- **（09-17 工單 B 挖到）bmv2 json 的 sha 不是穩定識別碼**：`p4c-bm2-ss` 把 `source_info` 的**絕對路徑**寫進 json，同一份 `.p4` 換目錄編就換 sha；
  **p4info 的 sha 才穩定**（同檔兩次 `9213871cee36bd93`）⇒ 「同一份程式」對帳用 p4info sha，benchmark 指認 binary 時 bmv2 json 要另附編譯目錄。
- **（09-17 工單 B）entries 的 pre-flight 是對 exercise 自帶的 p4info 驗（package 自洽），不是對現在跑的 `ndtwin_switch` 驗**——後者要等 G4；
  這是 orchestrator 確認過的解讀。

## 7. 執行方式
- 每階段一張工單派 **opus** 在獨立 worktree 做；orchestrator 只寫單、讀 SUMMARY、fable-judge、逐 hunk 讀 diff、推。
- 要 sudo 的步驟（`ndt up`、`drive_exercise.py`）貼指令給 Adam 跑，證據從 `runs/` 讀。
- 編 C++（只有階段三）走 `tools/build_guard/guarded_build.sh`、`JOBS=1`、`LOCK_WAIT=10800`。
- 小 bug（DOC-6／NDT-12）照 Adam 09-17 指示排後。

## 8. 09-17 Adam 裁決後的更新：路線 2、L3，而 exercise 只是階段目標

Adam 09-17 原話（轉述）：「路線 2、L3。讓 NDTwin 能夠支援 exercise 只是一個階段性目標；現在有非常多篇關於 P4 application 的論文，
教授最終的願景是讓 NDTwin 能夠輕鬆支援所有 P4 application（也就是它只要帶著自己的 `.p4` 檔進來就可以用 NDTwin 來模擬）。」

這句話改變三件事：

### 8.1 「profile」升級成「P4 app package」，tutorials 只是 13 個實例
package ＝ `{ .p4 或已編好的 json+p4info（每台可不同）, topology.json, runtime entries 或自帶控制器, host_commands, 選配 header hints }`。
`convert.py` 從 tutorials 格式產 package；論文的 app 直接手寫 package。`ndt up p4 --app <dir>`（`--exercise` 只是它的糖）。
**pre-flight**（使用者自己可跑、不需 root）：p4c 編得過、p4info 解析得出、topology 過 schema、entries 的表名／欄位名／位寬全部對得上 p4info——
對不上就在起 fabric 之前拒絕，而不是起來後靜默零分。

### 8.2 遙測來源是真正的分岔（要裁，決定階段一做不做 G1）
今天的遙測靠 `ndtwin_switch.p4` 合作：ingress `clone(250)` → egress 補 `packet_in` → proxy 合成 sFlow。**任意 `.p4` 不會帶這段** ⇒ 兩條路：

| | A「合作式」：提供 `ndtwin_telemetry.p4` 讓 app 作者 `#include`＋一行 `apply` | B「鏈路級」：在每個交換機埠的 veth 上用 Linux `tc … action sample`（psample）取樣，一支小 emitter 轉成 sFlow v5 送 6343 |
|---|---|---|
| 對 app 的要求 | 要改它的 `.p4`（一行 include、一行 apply；egress 要有我們的 header emission） | **零**——`.p4` 一個字不動 |
| kernel 改動 | 無（同今天的合成 sFlow） | **無**——kernel 本來就吃 sFlow v5（OVS 路徑就是這樣） |
| proxy 改動 | G1（metadata 按名字）＋ clone session 建立要跟 app 的 session id | 新 emitter（psample → sFlow，含 veth→(dpid,port) 對映）；proxy 不再需要 clone session／packet_in 通道做遙測 |
| 對 bmv2 的負載 | 每 1/256 包多一次 clone＋CPU port 上送（今天的成本） | bmv2 零成本；取樣在 host kernel |
| 可比性 | 與 09-x 所有 bmv2 天花板量測同口徑 | **新口徑**——天花板那四張工單要重量一次才可跨比 |
| 證據 | 今天在跑 | 【未驗】：這台 kernel（7.0）的 `act_sample`／psample 可用性、取樣率與 ifindex 對映都沒試過 |

**建議：B 當 BYO 的正式路，A 保留給 `ndtwin_switch.p4` baseline**（兩者可並存，`ndt status` 印出這個 fabric 的遙測來源）。
理由：教授的願景是「帶 `.p4` 就能用」，A 對每一篇論文的 app 都要動它的程式，而且 egress 結構不同時 include 不一定插得進去；B 完全與程式無關。
代價：一次新口徑的重量測。
**09-17 Adam 回應**：問兩者在效能／實作難度上的 tradeoff、要不要兩個都做來測、教授會想看比較圖 ⇒ **兩個都做**，同一個 fabric 上量三組
（無遙測／A／B）：轉發 pps 天花板 vs offered load、取樣率誤差（對 iperf bytes）、bmv2 與 host／emitter CPU；**對帳舊結果**＝bmv2 12×、pps 天花板、
「遙測成本固定不是每樣本」那三條（見記憶 index 00）。圖只留軸與數值，方法與但書寫旁邊文件。哪個當 BYO 預設，用量到的數字裁。
⇒ **G1 仍要做（A 需要它）**，但排在 B 的 emitter 之後不擋階段一；**階段 0 加一個 30 分鐘的 spike**：
純 veth pair（不起 NDTwin）上 `tc qdisc add clsact` ＋ `tc filter … action sample rate 256 group 1`，python psample listener 數 `ping`／`iperf` 期間的樣本數——
要 sudo，指令貼給 Adam 跑；結果決定 B 可不可行，再開階段一工單。

### 8.3 L3 對「任意程式」的實際意思（不是「解析每一種自訂標頭」）
- **鏈路使用率**（bytes/秒）與程式無關，B 模式下 13/13 與任何 app 都 100% 可觀測。
- **流身份**（`FlowKey`）只能好到「twin 認得的標頭」：外層或**第一個找得到的** IPv4／IPv6 五元組；找不到 IP 就退到
  `(src_mac, dst_mac, ethertype)` 的 L2 身份——自訂標頭是不透明的，但**不再被整包丟掉**（今天 `FlowLinkUsageCollector.cpp:1266`）。
  這是 GAP-ANALYSIS G6-B 那 ~250 行的正確範圍：加 L2 身份＋IPv6＋`ihl`，**不是**替 0x1234／0x812 各寫 parser。
- package 可帶 `header hints`（例：`0x1234 = SourceRoute stack, 每項 2 bytes, bos 位元結尾`）讓 twin 跳過自訂層找內層 IPv4——
  選配、階段四以後、每支 exercise 一條 hint 就能把 6 支「分身盲」翻成可見。
- 契約測試 `test_GoldenFixture.cpp`／`test_SFlowEmitterRoundtrip.cpp` 與已發表量測的 IPv4 口徑**維持不變**（新身份只對今天被丟掉的樣本生效）。

### 8.4 G5 的最終範圍
exercise 只要 exact＋lpm；**論文 app 會用 ternary／range／optional**（ACL、range match 一類）⇒ 階段二先做 exact＋lpm（GAP-ANALYSIS A'），
階段四升成 p4info 驅動的 generic writer（GAP-2 候選 B，~400 行），match kind 由 p4info 的 `match_type` 決定；
`rule_journal` 要在階段二就決定（§6 第一條），不然階段四會再撞一次。
**09-17 更正（`PAPER-APPS-CANDIDATES.md` 的結果）**：5 個公開原始碼的論文 app 候選裡 **4/5 要 ternary＋priority**（G6 觀測面同為 4/5）——
「ternary 在 13 支 exercise 裡 0 次」只對 exercise 成立，跨進論文 app 就是多數 ⇒ generic writer **提前到階段二末**（至少 `POST /p4/table_entry`
的 body 與 journal 形狀從第一天就帶 `match_type`／`priority`，exact＋lpm 先實作、ternary 留 501 而不是缺欄位）。

### 8.5 階段表重排（取代 §4）
| 階段 | 做什麼 | 驗證 |
|---|---|---|
| **0** | 遙測 spike（8.2）；package 格式草稿一頁 | psample 樣本數 ≠ 0 且與 `ping -c` 次數同量級 |
| **一** | package 骨架＋pre-flight＋G2＋G3（＋G1 只在選 A 時） | 無 package＝§5 全綠；`--app basic`（pod-topo）在 NDTwin 自己的 pipeline 下 `pingall` 0%；p4runtime 共存 |
| **二** | G4＋G5(exact+lpm)＋跳過開關＋rule_journal 裁決 | basic 雙向 → source_routing → firewall（兩份 p4info）→ link_monitor（default-only 表） |
| **三** | 遙測 B（emitter＋veth 對映）＋G6-B（L2 身份／IPv6／`ihl`）＋G2-C＋G7＋G8＋G9a/b | 13/13 兩向；**通用格**：任一 app 下 `iperf h1→hN` ⇒ 路徑上每條鏈路使用率 ≠ 0、非路徑＝0（與程式無關、可進閘門） |
| **四（BYO）** | generic writer（ternary/range）、header hints、package 文件＋手冊、**拿 2–3 篇論文的 app 當驗收**（Adam 挑） | 每篇 app：pre-flight 過、起得來、它自己的驗證腳本綠、twin 的鏈路使用率與它的 iperf 對得上 |
