# 階段四驗收用：5 個「自帶 .p4」的公開 P4 application 候選

[Co-developed with claude code -- Adam]

對應 `PLAN-0917-exercise-support.md` §8.5 階段四「拿 2–3 篇論文的 app 當驗收（Adam 挑）」。
能力維度用 `GAP-1-exercise-requirements.md` §1 那 16 個英文鍵，gap 代號用 `GAP-ANALYSIS.md` §3 的 G1–G9。

## 0. 怎麼讀

- **本輪一個封包都沒送、一支都沒編過。** 所有主張都來自讀公開 repo 的檔案內容。
- 【repo 讀過】＝我開過該檔（README／`.p4`／`topology.json`／`Makefile`／控制器腳本）並引它的內容。**除非另標，全部是這一級。**
- 【論文/轉述】＝只從 README 或摘要轉述，我沒讀到對應的碼。
- 日期取 GitHub API 的 last-commit（不是 `pushed_at`，那會被 fork 活動汙染）。
- 「阻擋的 gap」只列**今天做不到**的；G4（`pipeline_load` 任意化）與 G2（拓樸）五支全要，下面不重複寫。

---

## 1. 候選 A — ONTAS（bmv2 / P4_16 版）

- **論文**：Hyojoon Kim & Jennifer Rexford, *ONTAS: Flexible and Scalable Online Network Traffic Anonymization System*，NAI workshop @ SIGCOMM 2019。一句話：在交換機上線速把 MAC／IP 標頭做可設定的去識別化（雜湊、遮罩、保留 OUI），邊轉發邊匿名。
- **repo**：`github.com/Princeton-Cabernet/p4-projects`，子目錄 `ONTAS/bmv2_p4_16/`
- **授權**：Apache-2.0（該子目錄自帶 `LICENSE`；**repo 根目錄沒有 license**）
- **最後提交**：`ONTAS` 路徑 2020-07-01；repo 本身 2024-11-03
- **target**：P4_16 ＋ v1model（`#include <v1model.p4>`、`V1Switch(...)`）。`src/Makefile` 寫死 **`BMV2_SWITCH_EXE = simple_switch_grpc`** ＋ `--p4runtime-files` ⇒ **正是 NDTwin 今天的 target**。Tofino 版是隔壁 `ONTAS/tofino_p4_14/`，bmv2 這份完全不含它。⚠️ `src/includes/` 下 `p4anony_actions.p4`／`_fieldlists.p4`／`_parser.p4` 是 P4_14 遺留，但 `p4anony.p4` 只 `#include "includes/p4anony_headers.p4"` ⇒ 不進編譯。
- **它帶什麼**：`src/topology.json`（h1—s1—h2）、`src/s1-runtime.json`（P4Runtime 格式、開機灌的匿名政策）、`utils/` 一整份 tutorials 支援碼（`run_exercise.py` ＋ `p4runtime_lib`）、`smallFlows.pcap`。**沒有外部控制器**；驗證＝h1 `tcpreplay` 打 pcap、h2 `tcpdump` 與原始 trace 比對（README 有步驟，**沒有腳本**，要我們自己包）。
- **阻擋的 gap**：G5（`tables`）——而且**要 ternary**（`anony_srcip_tb`／`anony_dstip_tb` 對 IP 做 ternary），落在 PLAN §8.4 排到階段四的 generic writer；G6（觀測面：外層是 VLAN 0x8100 才輪到 IPv4，今天整包丟）。
- **為什麼選它給教授**：它的封裝形狀跟 NDTwin 今天吃的一模一樣，只差一個 ternary writer——是「BYO .p4 真的成立」最便宜的一次證明。
- **難度**：★☆☆☆☆

## 2. 候選 B — HashPipe（非官方 P4_16 重寫）

- **論文**：Sivaraman, Narayana, Rottenstreich, Muthukrishnan, Rexford, *Heavy-Hitter Detection Entirely in the Data Plane*，SOSR 2017。一句話：用固定級數的雜湊管線逐級擠掉較小的流，只在資料面留下 top-k 重流，控制面完全不介入。
- **repo**：`github.com/khooi8913/p4-hashpipe`（README 自稱 unofficial 實作）
- **授權**：🔴 **沒有 LICENSE 檔**（API `license: null`）⇒ 法律上是「保留所有權利」。當對外驗收素材前要先問作者或改內部用。
- **最後提交**：2020-06-05
- **target**：P4_16 ＋ v1model；`src/Makefile` ＝ **`simple_switch_grpc`**。無 Tofino 成分。
- **它帶什麼**：`src/topology.json`（h1—s1—h2，含靜態 ARP commands）、`src/s1-runtime.json`（`"table_entries": []` **是空的**）、`utils/` 整份 tutorials 支援碼。**沒有 send/receive.py、沒有任何驗證腳本。**
- **關鍵形狀**：`table ip_forward` 用 **`const entries`**（1→forward(2)、2→forward(1)）⇒ `control_plane_mode` ＝③**完全不需要控制面**，跟 `calc` 同型。統計狀態全在 `register`（`HP_INIT` 巨集開一排），資料面自讀自寫。
- **阻擋的 gap**：**beyond ——「從控制面讀 register」**。`p4runtime_lib` 沒有 register API（GAP-1 §1 已記），要走 thrift `simple_switch_CLI register_read`；不讀 register 就**看不到這支跑對沒有**。
- **為什麼選它給教授**：最便宜的「真論文」驗收——一筆 table entry 都不用寫，整支只考 `pipeline_load` ＋ 資料面狀態。而它逼出的 register 讀取通道，是所有 sketch／measurement 類論文的共同需求。
- **難度**：★★☆☆☆（P4 側最簡單，但要補 register 通道＋自己寫驗證）

## 3. 候選 C — INT v1.0 on bmv2（niloysh/int-v1）

- **論文**：P4.org *In-band Network Telemetry (INT) Dataplane Specification* v1.0 的實作（原始構想＝Kim et al., SIGCOMM 2015 的 INT demo）。一句話：每跳把 switch id／佇列深度／時間戳塞進通過的封包，端點一次讀出整條路徑的逐跳狀態。
- **repo**：`github.com/niloysh/int-v1`
- **授權**：MIT
- **最後提交**：2023-04-09
- **target**：P4_16 ＋ v1model。無 Tofino 成分。（`int_source.p4` 的結構與 GEANT 那份同源。）
- **它帶什麼**：`linear-topo/` 與 `triangle-topo/` **兩份** `topology.json` ＋ `sX-runtime.json`（P4Runtime，開機灌）、`send.py`／`receive.py`（scapy，**可判 pass**）、`runtime_cmds/s1.sh`（thrift `simple_switch_CLI table_add`，寫 **ternary ＋ priority** 的 `tb_int_source`）。無外部控制器。
- **阻擋的 gap**：G5（**ternary ＋ priority** writer，beyond 階段二範圍）；G6——而且是 GAP-ANALYSIS §2b 講的 **mri 那個「看得見但讀錯」**的更糟版本：INT 把 shim 插在 IPv4 與 UDP 之間並改 `ipv4.len`／`udp.length_`，NDTwin 用固定字組位移讀 L4 port（`FlowLinkUsageCollector.cpp:1299-1300`）會讀到 INT 欄位當 port。
- **為什麼選它給教授**：「網路數位分身 × 遙測」是教授最可能點名的交集，而它天然是 **NDTwin 自己遙測路線 A／B 的對照組**——app 自報的逐跳資料可以跟 twin 的鏈路使用率互相對帳。
- **難度**：★★★☆☆

## 4. 候選 D — GEANT int-platforms（INT v0.4 / v1.0，bmv2 ＋ Tofino）

- **論文**：不是單篇論文的 artifact，是 GÉANT GN4-3 專案的 INT 參考實作（檔頭作者：Damian Parniewicz (PSNC)、Damu Ding (FBK)）。【論文/轉述】對應到哪一篇我沒查證。
- **repo**：`github.com/GEANT-DataPlaneProgramming/int-platforms`
- **授權**：Apache-2.0（檔頭逐檔都有）
- **最後提交**：2022-10-20
- **target**：P4_16。⚠️ **同一份 `.p4` 用 `#ifdef BMV2 / #elif TOFINO` 同時支援 v1model 與 tna** ⇒ 有 Tofino 成分，但被前處理器隔開，編 bmv2 不受影響（**不是 Tofino-only，不用淘汰**）。bmv2 路徑走 **p4lang/p4app（Docker）**，不是 tutorials 的 `run_exercise.py`。
- **它帶什麼**：`p4src/int_v0.4/`（README 自稱最成熟）與 `int_v1.0/`；`platforms/bmv2-mininet/int.p4app/` 裡有 `topo.py`／`topo.txt`（3 台交換機）、`commands/commands{1,2,3}.txt`（thrift）、`host/` 下 send／receive／流量產生器、`utils/int_collector_influx.py`（**收集端寫 InfluxDB**）、以及 vendored 的整棵 Mininet。
- **阻擋的 gap**：G5（**大量 ternary**：`tb_forward` 對 MAC、`tb_int_source` 四欄、`tb_int_inst_0003/0407` 對 instruction_mask）；**G9a**——`int_sink.p4:34` 是 `clone3(CloneType.I2E, INT_REPORT_MIRROR_SESSION_ID, meta)` 且 **session id ＝ 1 由 CLI 建**，NDTwin 今天寫死 250；G6。外加**環境成本**：Docker ＋ p4app ＋ InfluxDB 三件外掛。
- **為什麼選它給教授**：唯一一份同時活在 bmv2 與 Tofino 的 INT 參考碼——拿它驗收，順手證明 package 格式沒有綁死 bmv2-only 的寫法。
- **難度**：★★★★☆（P4 不難，外掛環境最貴）

## 5. 候選 E — ETH Zürich p4-learning（家族，當廣度體檢用）

- **來源**：⚠️ **不是論文 artifact，是 ETH Zürich 課程教材**（Advanced Topics in Communication Networks），實作的是已發表的演算法：Count-Min Sketch（Cormode & Muthukrishnan 2005）、bloom-filter heavy hitter、INT、flowlet／congestion-aware LB（CONGA／HULA 家族）。**對教授要照這個口徑講，不要說成「某篇論文的 app」。**
- **repo**：`github.com/nsg-ethz/p4-learning`（＋執行框架 `nsg-ethz/p4-utils`）
- **授權**：GPL-3.0（`p4-utils` 是 GPL-2.0）——只當外部驗收素材、不併進 NDTwin repo 就沒問題。
- **最後提交**：2023-10-09（`p4-utils` 2024-07-09）
- **target**：P4_16 ＋ v1model ＋ bmv2。⚠️ **不吃 tutorials 那套**：拓樸是 p4-utils 的 `network.py`／`p4app.json`，交換機用 `addP4Switch`（＝ **`simple_switch` ＋ thrift**），控制面走 `SimpleSwitchThriftAPI`（`table_add`／`register_read`／`register_reset`／`get_custom_crc_calcs`）。p4-utils **也有** `addP4RuntimeSwitch` 與 `sswitch_p4runtime_API.py`（即 `simple_switch_grpc`），但這批練習沒用到。
- **它帶什麼**：12 支 exercises ＋ 29 支 examples；每支有 `p4app.json`＋`network.py`（ex10 用 **`net.setBwAll(10)` 逐鏈路整形**）、`sX-commands.txt`（thrift）、`send.py`／`receive.py`、部分自帶外部控制器（`cm-sketch-controller.py`、`routing-controller.py`，靠 `net.execScript()` 開機拉起）、以及 `solution/`。
- **阻擋的 gap**（取整個家族的聯集）：G5、G7、G8（`examples/multicast`）、G9a（`examples/copy_to_cpu`）、G2 的**逐鏈路整形**，外加 **beyond：thrift 控制通道、register 讀寫、自訂 CRC 參數、digest（`examples/digest_messages`、`04-L2_Learning`）、meter（`examples/meter`——13 支 exercise 全樹 0 需求的維度，在這裡出現第一個實例）、recirculate／resubmit**。
- **為什麼選它給教授**：它是唯一能一次把「NDTwin 還缺哪些維度」全部照出來的家族。**當廣度體檢用，不當第一個驗收。**
- **難度**：★★★★★（整套控制面／拓樸框架要換）；但只挑單支 `.p4` 重新打包成 NDTwin package 的話 ★★☆☆☆

---

## 6. 16 維需求矩陣（✔＝需要、—＝不需要、?＝我沒讀到能斷定的碼）

| 鍵 | A ONTAS | B HashPipe | C int-v1 | D GEANT INT | E p4-learning（聯集） |
|---|---|---|---|---|---|
| `pipeline_load` | ✔ 單一 | ✔ 單一 | ✔ 單一 | ✔ 單一 | ✔ 每台可不同 |
| `tables` | ✔ exact ＋ **ternary** | — **const entries** | ✔ lpm ＋ **ternary＋priority** | ✔ **大量 ternary** | ✔ exact/lpm/**ternary** |
| `pre_multicast` | — | — | — | — | ✔（`examples/multicast`） |
| `pre_clone` | — | — | ? | ✔ **session id＝1** | ✔（`copy_to_cpu`） |
| `counters` | — | — | ✔ direct（控制面讀?） | ? | ✔（`examples/counter`） |
| `meters` | — | — | — | — | ✔（`examples/meter`） |
| `registers` | — | ✔ **控制面要讀** | — | ✔ 僅資料面 | ✔ **控制面要讀寫** |
| `digest` | — | — | — | — | ✔（`digest_messages`） |
| `packet_io` | — | — | — | — | ✔（`copy_to_cpu`） |
| `custom_headers` | ✔ VLAN 0x8100 | — 純 IPv4 | ✔ INT shim 改 `ipv4.len` | ✔ | ✔ |
| `queue_metadata` | — | — | ✔ | ✔ | ✔（`multiqueueing`、ex10） |
| `checksum` | ✔ update | ✔ update | ✔ update | ✔ | ✔（`verify_checksum`） |
| `ttl_or_hop` | — | — | ✔ `remaining_hop_cnt` | ✔ | ✔ |
| `topology` | ✔ 1sw2h | ✔ 1sw2h | ✔ 兩種 | ✔ 3sw | ✔ **要 bw 整形** |
| `control_plane_mode` | ① 開機 runtime json | ③ **無** | ① ＋ thrift | ② thrift ＋ collector | ② thrift ＋ 外部控制器 |
| `verification` | pcap replay ＋ tcpdump 比對（無腳本） | **repo 沒附** | `send.py`／`receive.py` | InfluxDB ＋ scapy 計數 | `send/receive.py` ＋ pickle 對帳 |

## 7. 查過但淘汰／不推的（附理由，避免下次重查）

- **NetCache**（`netx-repo/netcache-p4`，SOSP 2017）／**NetChain**（`netx-repo/netchain-p4`，NSDI 2018）：🔴 **P4_14**（`control ingress { apply(ipv4_route); }`、`register x { width: 16; }`），而且 `mininet/run_demo.sh` 用的是已停更的 `p4c-bm` 編譯器與 Python 2。**淘汰。**（兩者確實有 Mininet 目錄與控制器，形狀很吸引人——這條路我確認過走不通，不要再回來。）
- **PRECISION／ConQuest／BeauCoup／HyperLogLog／RTT／SipHash**（`Princeton-Cabernet/p4-projects`）：目錄名就是 `-tofino`，**Tofino-only**。**淘汰。**（同一個 repo 裡只有 `ONTAS/bmv2_p4_16` 與 `AES.p4app` 是 bmv2。）
- **Elastic Sketch**（`BlockLiu/ElasticSketchCode`）：P4 部分只有 `src/P4_cpu_implementation/{elastic.p4, Elephant_part_4.h}`，**沒有拓樸、沒有控制器、沒有測試**，且 repo 無 license。**淘汰。**
- **SilkRoad**（SIGCOMM 2017）：GitHub 搜尋 `silkroad p4 load balancer` **0 筆**，找不到官方公開實作。**淘汰。**
- **Sonata**（`Sonata-Princeton/SONATA-DEV`，SIGCOMM 2018）：還活著（最後提交 2021-02-24）但無 license，而且它是「查詢編譯器 ＋ Spark streaming ＋ dataplane driver」一整套系統，不是一支可以 BYO 的 `.p4`。**不推當階段四驗收**，若教授特別想要再單獨評估。
- **HULA**（`Hyunsuk-Bang/HULA`）：4 星、無 license、2023-05-18。原始 HULA（SOSR 2016）沒有官方公開 repo。**不推**；congestion-aware LB 這一類用候選 E 的 `10-Congestion_Aware_Load_Balancing` 代替。

## 8. 我會挑哪三個，以及最該先建的是什麼

**挑 A（ONTAS）＋ B（HashPipe）＋ C（int-v1）。**

理由：這三支的封裝形狀**跟 tutorials 一模一樣**（`topology.json` ＋ `sX-runtime.json` ＋ `utils/run_exercise.py` ＋ `p4runtime_lib`），而且 A 與 B 的 `Makefile` 直接寫 `simple_switch_grpc` ⇒ 階段一～三做完，它們幾乎是「把目錄丟進 `ndt up p4 --app <dir>`」就該動。三支各壓一個**不同**的新維度，不重複：A ＝ ternary ＋ VLAN 觀測、B ＝ 零控制面 ＋ 控制面讀 register、C ＝ ternary＋priority ＋ 變長／被插入的 IPv4 觀測。

⚠️ **B 沒有授權檔**。如果 Adam 不想拿無 license 的碼當對外驗收，第三名換 **D（GEANT int-platforms，Apache-2.0）**——代價是要多扛 Docker ＋ p4app ＋ InfluxDB，而且 D 與 C 同屬 INT、覆蓋的維度會重疊。

**最常出現、最該先建的 gap**：把五支全要的 G4／G2 撇開不算，**`tables` 的 ternary（＋priority）寫入，5 支裡有 4 支要**（A／C／D／E），G6 觀測面同樣 4/5。

🔴 **這一條直接推翻 PLAN §8.4 的排序。** GAP-ANALYSIS §2b 判「ternary／range 在 13 支 exercise 裡一次都沒出現」因此把 generic writer 排到階段四——那個統計只對 tutorials 成立；**一跨進論文 app，ternary 從 0/13 變成 4/5**。建議把 p4info 驅動的 generic writer 從階段四**提前到階段二末**，或至少在階段二的 `rule_journal` 裁決裡預留 `match_type` 欄位，否則階段四會像 §8.4 自己警告的那樣再撞一次。
