# NDTwin-Kernel 大規模測試與外部框架研究報告

日期：2026-08-13
性質：唯讀研究報告。本任務不寫程式、不改 repo、不碰 live 環境、不安裝任何套件。
所有外部工具僅建議，附版本與來源查證方式。

**全文標記慣例**：
- 【來源】＝外部來源或 repo 內文件明文寫的東西，附出處。
- 【推論】＝我根據來源對本專案意義的推論，可被實測推翻。
- 「未驗證」＝讀不到原文或未能實測確認的宣稱。

**本報告的輸入**：
- repo 文件：`doc/2026-08-07_testing_tools_overview.md`、`doc/2026-07-28_test_coverage_gaps.md`、
  `doc/2026-08-10_p4_manual_test_runbook.md`（含 §6h 故障注入節）、`doc/2026-07-27_p4_bmv2_support_plan.md`、
  `doc/2026-07-30_full_test_runbook.md`
- commit `d7bf52f`（flow-rate 精確度階梯量測）與近期 fix 線（`034da18`、`a72a168`、`b966f45`）
- 2026-08-12/13 整夜測試輪的四條教訓（任務簡報提供）

---

## 1. 故障模型目錄（Fault Model Catalog）

昨晚整夜輪的核心結論——最高價值的缺陷全部來自沒被腳本涵蓋的**故障形狀**，不是來自
跑更多次既有測試——直接指向這一節：先把故障空間列成表，才知道測試該往哪裡加。

分類軸：故障落在哪個平面（鏈路 / 節點 / 控制 / 輸入 / 資源 / 注入工具自身）。
「已涵蓋？」的判準是**有可重複的腳本或 runbook 步驟＋明確 pass/fail 判準**，
不是「有人手動做過一次」。

### 1.1 鏈路平面

| # | 故障類型 | 已涵蓋？ | 證據 | 缺口 | 最小注入方法（既有能力） |
|---|---|---|---|---|---|
| L-1 | 雙向鏈路斷線 | ✅ 有 runbook 步驟＋判準 | `2026-08-10_p4_manual_test_runbook.md` §6h＋「正確的故障注入方式」節：2026-08-10 端到端實測，ping 中斷 ~15 s 自癒、9.67% loss、規則層讀回確認繞路；`test_link_watchdog.py` 鎖定 `{(5,4),(10,1)}` 場景 | 只在 1–2 條特定鏈路上驗過；40 條邊沒有參數化掃描 | `tc netem loss 100%` 兩端（sudoers 已授權 `s[0-9]*-eth[0-9]*`） |
| L-2 | **單向鏈路斷線**（非對稱） | ⚠️ 修復已落（`034da18` route around half-dead links）但**無測試類別** | 昨晚教訓 #1：單端 netem loss 100% → 路由重算對「圖不對稱是穩態」無防禦 → 永久黑洞 | 沒有任何腳本或 runbook 步驟涵蓋「只斷一個方向」；`reroutable_down_endpoints()` 的反向檢查（2026-08-13 修）恰好依賴「反向也 down」——單向故障正是它的邊界 | 單端 `tc netem loss 100%`（只下一邊）；判準：canary ping、`all_destination_paths` 數、且**兩個方向的 down 回報各自斷言** |
| L-3 | 部分丟包（5–30%） | ❌ | 無任何提及 | gray failure：beacon 偶爾通過所以偵測不觸發，但 rate 估計與 failover 判斷都在歪的資料上跑 | `tc netem loss 30%`（sudoers 的 `netem *` 萬用字元已涵蓋） |
| L-4 | 延遲 / 抖動 / 重排 | ❌ | 無 | beacon timeout=15 s 對延遲的容忍邊界未知；重排對 sFlow flow sample 序列的影響未知 | `tc netem delay 100ms 50ms`、`tc netem reorder 25%`（同上已授權） |
| L-5 | 鏈路 flapping（快速斷/復循環） | ❌ | 無 | watchdog 15 s timeout × topology poll「前 90 秒 5 s、之後 30 s」換檔（runbook §6 記載）之間的互動從未測過；換檔行為本身是 [[prove-the-writer-by-cadence]] 實測過的機制 | `tc netem add/del` 迴圈，週期分別取 <15 s、15–30 s、>30 s 三檔 |

### 1.2 節點平面（switch）

| # | 故障類型 | 已涵蓋？ | 證據 | 缺口 | 最小注入方法 |
|---|---|---|---|---|---|
| N-1 | switch process 死亡 | ⚠️ 部分 | 電源關閉路徑（Phase 7）已 live 驗證；但「非預期 kill -9」與「優雅關閉」是不同故障 | kill -9 bmv2 mid-traffic 後：twin 多快判 down？流量繞路嗎？孤兒 process 問題（helper 開的 bmv2 活過 `mn -c`）已知但無測試 | `pkill -x simple_switch_g`（注意 comm 15 字元截斷）；或 kill by pid |
| N-2 | switch **半死**（process 活著、packet-in 停擺） | ⚠️ 意外涵蓋 | `ifconfig down` 的副作用正是這型：runbook §6 開頭記載「gRPC 沒斷、beacon 照送，但收到的封包不再上 CPU」→ 鄰居假報 | 從來沒有人**刻意**注入這型。它是 runbook 裡的「陷阱」，該重新定性為「一種故障類型的正確注入器」 | `ifconfig <iface> down`（NOPASSWD 已有）——bmv2 限定；OVS 不受此影響（2026-08-11 實測） |
| N-3 | switch 電源關/開 + readopt | ✅ | Phase 7 完成（`2026-07-27_p4_bmv2_support_plan.md` Phase 7 節）；`a72a168` 拒絕 readopt 未曾授權 mastership 的 switch | manifest 生命週期：bmv2 活過 `mn -c` 後 manifest 被刪、helper 定址不到（已知未解） | 電源 helper（免密碼） |
| N-4 | switch process 暫停（SIGSTOP：活著但不回應） | ❌ | 無 | liveness 判定的已知盲區：`pgrep`/`os.kill` 都會判 alive。證據式 liveness 三態理論上該判 stalled——**沒驗過** | `kill -STOP <pid>` / `kill -CONT <pid>`（自有 process 免 sudo） |

### 1.3 控制平面

| # | 故障類型 | 已涵蓋？ | 證據 | 缺口 | 最小注入方法 |
|---|---|---|---|---|---|
| C-1 | controller（Ryu/proxy）kill / restart | ⚠️ 部分 | /stats/flow wedge 的三道門已關（防護存在），但 root cause 至今未證明；`2026-07-30_full_test_runbook.md` 有 kill 步驟 | `2026-07-28_test_coverage_gaps.md` §8 待辦 4 明列未做：「**殺掉控制器後下規則，kernel 要回報失敗而不是回 200**」（該文件稱這步「最有價值也最容易做」）。路由策略是 curl fire-and-forget，很可能真的回 200 | kill by pid → `install_flow_entry` → 斷言非 200＋log 檢查 |
| C-2 | 雙 controller mastership 相撞 | ⚠️ 修復已落、**無常態測試** | 昨晚教訓 #2：清表＋寫入全拒＋回報 success；`a72a168` 修 readopt 面；`b966f45` 把 LiveSwitchTest 改 opt-in | 沒有測試會啟動第二個 controller instance 製造衝突；「寫入被拒但回報 success」這型（silent failure）值得抽象成一類 | 起第二個 proxy 指向同一台 bmv2（gRPC election id 較高者贏——P4Runtime 規格行為） |
| C-3 | kernel 自身 restart 中途恢復 | ❌ | 無 | topology snapshot 是一次性的（host edge 教訓 2026-08-11 更正）：kernel 重啟後對「重啟前發生的變化」的追趕行為未定義未測 | kill kernel → 期間斷一條鏈路 → 重啟 → L2 斷言圖狀態 |
| C-4 | kernel↔Ryu/proxy 之間的 HTTP 慢/斷 | ❌ | `2026-07-28_test_coverage_gaps.md` §2.3：HTTP server 是 `io_context{1}` 單執行緒，任何慢 handler 阻塞全部請求；對 Ryu 的同步 curl 是已點名的風險 | L2/L3 序列發請求，永遠不會遇到；沒有工具能對「kernel 對外的同步呼叫」注入延遲 | 見 §3.3 Toxiproxy（插在 kernel↔Ryu 之間注入 latency/timeout/reset_peer） |

### 1.4 輸入平面

| # | 故障類型 | 已涵蓋？ | 證據 | 缺口 | 最小注入方法 |
|---|---|---|---|---|---|
| I-1 | 畸形 sFlow datagram | ⚠️ 大幅改善 | bounds check 已補＋`SFlowParsingFixture` 17 測試＋ASan 驗證（`2026-07-28_test_coverage_gaps.md` §0 更新表） | 手寫的 17 個 case 是**已想到的**畸形；沒想到的形狀沒有系統性探索（歷史上這個 parser 出過 heap overflow） | libFuzzer harness，seed corpus 用 `tests/fixtures/` 的 **31 個真實抓包 .bin**（見建議 R-1） |
| I-2 | sFlow 取樣率 0 / 除零 | ✅ | 本分支 `fix/flow-rate-divide-by-zero` 本體；`test_EstimatedRates.cpp` 8 個 SIGFPE 迴歸 | — | — |
| I-3 | sFlow UDP 佇列滿載丟棄 | ❌ | `2026-07-28_test_coverage_gaps.md` §5.1 點名（`m_q.size() >= m_capacity` 的丟棄行為） | 滿載時 twin 的 rate 估計靜默偏低——與 drift 量測（§2.3）直接相關 | 灌高 pps 合成 sFlow（不需真流量，直接對 :6343 發 UDP——**注意紀律：不碰 live port，此為建議非執行**） |
| I-4 | 北向 HTTP 畸形輸入 | ⚠️ 部分 | L2 錯誤路徑 7 個 case | HTTP 協定層零測試（方法錯置、OPTIONS/CORS、超大 body、keep-alive；`2026-07-28_test_coverage_gaps.md` §2.2） | Hypothesis 對 schema 反向生成（見建議 R-3） |
| I-5 | 北向併發 / head-of-line blocking | ❌ | `2026-07-28_test_coverage_gaps.md` §2.3 全節 | 實際部署形態（GUI+Visualizer+NSR 同時輪詢＋app 下規則）沒有任何一層重現 | 並行 curl 打慢端點（溫度/SNMP）＋量測其他端點延遲 |

### 1.5 資源平面

| # | 故障類型 | 已涵蓋？ | 證據 | 缺口 | 最小注入方法 |
|---|---|---|---|---|---|
| RS-1 | RSS / thread 洩漏 | ❌ 工具不存在 | `2026-07-28_test_coverage_gaps.md` §5.3：文件寫了四項判定標準（RSS 成長 <10%/10min、thread 穩定、exit code、無 crash），「**這四項一項都沒有實作**」；crash 偵測後來補上了，洩漏偵測仍無 | 兩個已修的 bug（`m_ifIndexToOfportMap` 無上限、`m_flushEdgeFlowLoop` 沒 join）如果回歸，今天一樣抓不到 | soak run＋週期取樣 `/proc/<pid>/status` 的 VmRSS/Threads（純讀，零依賴）；per-thread CPU 取樣法已在 idle-spin 調查用過 |
| RS-2 | CPU 飢餓（bmv2 之間互搶） | ❌ | 無 | 規模化（§2）時 bmv2 全 CPU-bound，「switch 慢」與「switch 死」的判定邊界未測 | `taskset`/`cpulimit` 限縮單台 bmv2（免 sudo 對自有 process） |
| RS-3 | 時鐘偏移 | ❌ | 無；`FLOW_RECORD` 時間欄位連格式都沒驗（`2026-07-28_test_coverage_gaps.md` §3） | twin 的時間戳一致性 | 不建議動系統時鐘（會污染整個環境）；優先級低，先補時間欄位的 L2 不變量即可 |

### 1.6 注入工具自身（元故障）

| # | 故障類型 | 已涵蓋？ | 證據 | 缺口 | 最小防護方法 |
|---|---|---|---|---|---|
| M-1 | 注入工具 side effect 汙染實驗 | ✅ **已有工具**（研究中途更正） | 昨晚教訓 #3：`tc qdisc add root` 靜默替換 Mininet TCLink 的 htb → 假證據。**`tools/test_workflow/qdisc_snapshot.sh` 已經存在**（檔頭記載正是 2026-08-13 那輪的產物）：`save` 存全介面 qdisc 樹、`diff` 對任何漂移 exit 1 | 缺的不是工具，是**強制使用**：它還沒被 `run_layers.sh` 或任何 runbook 步驟包住，得靠人記得手動包在注入輪外面 | 把 `save`/`diff` 變成 L5 注入 harness 的固定前後置（見建議 R-2），而不是可選步驟 |
| M-2 | 錯的注入器製造錯的故障 | ✅ 已文件化 | runbook §6：`ifconfig down` vs `tc netem` 對照表（5 筆假報 vs 2 筆零假報） | 已重新定性於 N-2：ifconfig down 不是壞工具，是**另一型故障**的注入器 | — |

【推論】這張表最大的訊號：**「修復已落但無測試類別」出現三次**（L-2、C-2、部分 C-1）。
昨晚抓到的 bug 修掉了，但下次同型故障（別條邊的單向斷、別種 mastership 競態）沒有東西守。
建議清單（§4）的第一優先順位就從這裡來。

---

## 2. 任務 A：大規模測試方式

### 2.1 拓撲規模化

#### bmv2 的實際天花板

【來源】bmv2 官方 performance 文件（[behavioral-model/docs/performance.md](https://github.com/p4lang/behavioral-model/blob/main/docs/performance.md)）：
- 「bmv2 is not meant to be a production-grade software switch」。
- 官方 benchmark：單台 simple_switch 中位數吞吐約 **1,047 Mbps ≈ 80,000 pps**（AWS c4.2xlarge）。
- 影響因素：P4 程式複雜度、build flags（建議 `-O3` ＋ `--disable-logging-macros --disable-elogger`）、
  ternary table entry 數、flow cache。

【來源】Chen, Hu & Jin, *Enhancing Fidelity of P4-Based Network Emulation with a Lightweight
Virtual Time System*（SIGSIM-PADS '23，[DOI 10.1145/3573900.3591120](https://dl.acm.org/doi/10.1145/3573900.3591120)；
本報告讀的是 [NSF 公開版全文](https://par.nsf.gov/servlets/purl/10426812)）。這是目前找到
對「多台 bmv2 in Mininet」最完整的實測：
- **16 台 linear** 拓撲、1 ms 延遲：Mininet-BMv2 在鏈路頻寬 <100 Mbps 時貼近 line rate，
  **約 130 Mbps 飽和**；同機 OVS 可到 30 Gbps。
- `simple_switch_grpc`（我們用的 target）**最大約 170 Mbps**；`simple_switch` 最高可到 ~1 Gbps。
  各 target 差異大（40 Mbps 到 1 Gbps）。
- **開啟 tracing 再砍最多 30.7%** 吞吐。
- 規模曲線（linear、500 Mbps 鏈路）：4 台 = 495.6 Mbps（99.12% 達標）；
  **超過 64 台顯著劣化**；256 台 = 87.6 Mbps（**只剩 17.5%**），且變異數隨規模上升。
- 256 台 ring、每對 host 期望 1000 Mbps：實測全部掉到 ~212 Mbps。
- 根因：所有 container 共享同一顆系統時鐘與 CPU，資源超訂後 container 感知的時間
  反映的是 host 的序列化排程，不是網路行為——**temporal fidelity 崩壞**。
- 他們的解法（virtual time / TDF）能把 256 台的誤差從 91.4% 壓到 9.8%，但要改 Linux kernel
  （`task_struct`＋`gettimeofday`），對我們是不可能導入的等級（見 §5 不建議清單）。

【推論】對本專案的意義：
1. 我們的 P4 testbed（10 台）落在論文的「安全區」（<64 台、鏈路負載低）。
   擴到 **fat-tree k=4（20 台 switch）仍在安全區；k=8（80 台）已進入 fidelity 崩壞區**。
2. 更重要的含意在 drift 量測（§2.3）：bmv2 的 temporal fidelity 誤差會**混進**
   「twin vs ground truth」的偏差裡。規模化之前要先量 **emulator noise floor**——
   同一場景跑 N 次、twin 不動，看 ground truth 自己的變異數多大。超過這個底噪的偏差
   才能歸給 twin。
3. per-switch 閒置 RSS/CPU 沒找到可引用的公開數字（**未驗證**）。但這正好是我們自己
   一小時內量得出來的：現有 10 台的 `/proc/<pid>/status`（VmRSS、Threads）＋
   per-thread CPU 取樣（idle-spin 調查用過的方法）→ 外插到 20/80 台。
   注意 bmv2 曾有 idle polling 吃 CPU 的歷史，閒置成本不是零。
4. veth 數量本身在現代 kernel 不是硬限制（**未驗證**——沒找到明確上限文件）；
   實際先撞到的是下一段的 neighbor table 與 fd 限制。

#### OVS/Mininet 大拓撲的已知陷阱

【來源】[Mininet issue #220](https://github.com/mininet/mininet/issues/220)：600 台 switch 時
`--arp` 失敗——**Linux 的 ARP/neighbor table 是全系統上限**（`net.ipv4.neigh.default.gc_thresh2=4096`
仍會溢出）。我們 OVS 側 128 host 全網互 ping 時的 neighbor 條目數 = host² 級，
scale host 數之前要先調 `gc_thresh1/2/3`。
【來源】VT-BMv2 論文引 Mininet 原始論文：commodity laptop 可到 **4096 hosts**——
host 數不是瓶頸，**per-packet 經過 userspace 的 switch 才是**（OVS kernel datapath 沒這問題，
bmv2 全程 userspace）。
【來源】大型 flat L2 的 ARP broadcast 放大是文獻反覆記載的問題（例：
[LazyCtrl, arXiv:1504.02609](https://arxiv.org/pdf/1504.02609)）；controller 集中處理
flow arrival 與統計收集是規模瓶頸。
【推論】我們的對應風險不是 OVS 本身，是 **Ryu 單體**：128 host 已經在跑，
scale 到 512+ host 時 packet-in 風暴會先打垮 Ryu（/stats/flow wedge 的歷史說明它對
慢速失敗的耐受性差）。另外 `2026-07-30_full_test_runbook.md` 記載 kernel 啟動時自跑 128 台平行 ping
自我測試——host 數翻倍時這一步的時間與誤報率要重新驗。

### 2.2 流量規模化

#### 取樣 1/256 之下，多少流量才有統計意義

【來源】sFlow 官方取樣理論（[sflow.org Packet Sampling Basics](https://sflow.org/packetSamplingBasics/index.htm)、
[InMon sFlow Accuracy and Billing](https://inmon.com/pdf/sFlowBilling.pdf)）：
95% 信賴下 **誤差% ≈ 196 × √(1/c)**，c = 落在該類別的樣本數。誤差只跟樣本數有關，
與網路總流量無關。Worked examples：c=1000 → 約 6%；
[c≈1500 → 5%](https://blog.sflow.com/2009/05/scalability-and-accuracy-of-packet.html)。

換算到我們的 P4 側（1/256、1470-byte datagram，沿用 `d7bf52f` 的量測條件；
一個樣本代表 256×1470×8 ≈ **3.01 Mbit**）：

| 目標誤差（95% CI） | 需要樣本 c | 需要封包數 c×256 | 1 秒窗需要 | 10 秒窗需要 |
|---|---|---|---|---|
| ±20% | ~96 | ~24.6k pkts | 24.6 kpps ≈ 290 Mbps | 2.5 kpps ≈ 29 Mbps |
| ±10% | ~384 | ~98.3k pkts | 98 kpps（**超過 bmv2 的 80 kpps 天花板**） | 9.8 kpps ≈ 116 Mbps |
| ±5% | ~1537 | ~393k pkts | 不可能 | 39 kpps ≈ 463 Mbps（超過多台 bmv2 實測飽和點） |

【推論】三個結論：
1. **在 bmv2 上，「加大流量」永遠買不到 ±5%@1s**——生成器不是瓶頸，bmv2 是。
   這不是要修的問題，是要寫進規格的物理限制。
2. `d7bf52f` 的發現與取樣理論完全互洽：25 Mbps 時 1 秒窗只有 ~8 個樣本，
   理論單讀誤差 196√(1/8) ≈ 69%，但**取中位數後落在 1–2%**。所以正確的回歸指標
   是「N 次讀值的中位數」，不是單讀——`d7bf52f` 已經做對了，該做的是把它變成
   自動化門檻（見 §2.3 與建議 R-5）。
3. 我們**控制 P4 側的 sFlow 合成器**——這是 OVS 使用者沒有的自由。要更高統計品質，
   改 emitter 的取樣分母（1/64、1/16）比加流量便宜得多；代價是 proxy CPU，
   值得先量一輪「分母 vs proxy CPU」曲線再定案。

#### 產生器的適用場景

| 工具 | 【來源】能力 | 【推論】對我們 |
|---|---|---|
| iperf3 | 吞吐/jitter 基本盤（[NetPilot 比較](https://www.netpilot.io/blog/network-traffic-generator-lab-testing)） | ✅ 續用。UDP 模式 `-b <rate> -l 1470` 可精確控制 pps，讓「預期樣本數」可算——這是 d7bf52f 方法的直接延伸 |
| TRex | DPDK-based，可到 200 Gbps、百萬 flow（[NetDev 論文](https://netdevconf.info/0x14/pub/papers/9/0x14-paper9-talk-paper.pdf)） | ❌ 完全錯位：bmv2 80 kpps 天花板下，DPDK 級產生器毫無用武之地，且需要可綁 DPDK 的介面。見 §5 不建議清單 |
| scapy | 封包精雕；效能 <100–1000 pps 級（[vBNG 實測](https://zstas.github.io/trex/pppoe/vbng/2020/07/24/trex.html)） | ✅ 但用途是**畸形封包與協定邊角**（fuzz corpus 種子、非 IPv4 etherType、分片），不是流量規模 |
| hping3 | TCP flag 級構造/flood | ⚠️ 與 scapy 重疊，只在需要高速 SYN 類場景才有差異；暫不需要 |

### 2.3 長時間 soak 與 drift 量測

#### 我們已有的起點

repo 內的先行者是 commit `d7bf52f`（2026-08-11）：單流五階 ladder（1/5/10/25/50 Mbps），
twin 中位數對 iperf 自身記帳，發現 ≥25 Mbps 中位數在 2% 內、<10 Mbps 單讀可錯數倍，
且誤差不是雜訊而是**可計算的量化階梯**（1 樣本 = 3.01 Mbit）。這已經是 drift 量測的
正確形狀——缺的是「隨時間重複」與「自動化門檻」。

【來源】旁證：Wang & Lin（JNCA 2026，Adam 本機已有 PDF：
`~/Documents/NDTwin documentation/1-s2.0-S1084804525002826-main.pdf`，
[DOI 10.1016/j.jnca.2025.104385](https://doi.org/10.1016/j.jnca.2025.104385)）開篇即指出
sFlow 取樣式監測「many small flows may go undetected and the estimated flow data …
can significantly deviate from their ground truth」——小流量偏差是取樣式監測的
結構性問題，不是我們的實作 bug。

#### 方法論：drift 怎麼量

【推論】（組合通用 SPC 做法與我們既有能力）：

1. **ground truth 的來源**：我們有三個，精度遞增：
   iperf 自身記帳（d7bf52f 用的）；OVS `ovs-ofctl dump-ports` 的精確 counter；
   bmv2 經 P4Runtime 讀回的 counter（runbook §6h 已用 `read_table_entries()` 讀回規則，
   同一條路可讀 counter）。**counter 是不取樣的**，所以 counter 差分 ÷ 窗長 = 該窗的真值。
2. **配對讀取**：每窗（建議 10 s）同時取 twin 的 `estimated_flow_sending_rate_bps`
   與 counter 差分，記 `(twin, truth, t)` 三元組落檔——發現一產生就落檔，中斷不丟資料。
3. **指標**：每小時聚合一次「N 窗中位數比值」與 IQR，**按流量階分層**（1/5/10/25/50 Mbps
   各自一條線）——因為 d7bf52f 證明誤差結構隨流量階不同。
4. **門檻怎麼設**：理論下限先算出來——窗長 T、速率 R 下期望樣本數
   c = R×T / 3.01 Mbit，95% 理論誤差 = 196×√(1/c)（§2.2 的公式）。
   **回歸門檻必須 ≥ 理論下限**，否則測試天生 flaky。建議：
   `門檻(R,T) = max(1.5 × 理論誤差, 2%)`，其中 2% 來自 d7bf52f 實測的高速率天花板。
5. **drift 判定**：中位數比值連續 k 小時單向偏移才算 drift（區分 drift 與噪音）。
   標準做法是 EWMA/CUSUM 控制圖（【來源】[NIST/SEMATECH e-Handbook,
   EWMA control charts](https://www.itl.nist.gov/div898/handbook/pmc/section3/pmc324.htm)），
   但第一版用「連續 3 個小時聚合值出界」這種笨判準就夠了。
6. **soak 同時要量資源**（§1.5 RS-1 的缺口）：每 60 s 讀
   `/proc/<pid>/status` 的 VmRSS/Threads，門檻直接用 `2026-07-27_testing_workflow.md` 已寫好
   但從未實作的四項判定（RSS 10 分鐘成長 <10%、thread 穩定）。兩個已修的洩漏 bug
   就是這型——工具存在的話它們當年就會被抓到。

**emulator noise floor 前置**（§2.1 推論 2）：正式 soak 前，同一場景不改任何東西連跑
3 輪，取 truth 自身的輪間變異——之後所有「twin 偏差」都要先扣掉這個底噪才能歸因。
bmv2 的 temporal fidelity 在負載下會自己劣化（VT-BMv2 論文），不先量底噪，
soak 會把模擬器的謊算到 twin 頭上。

### 2.4 孿生保真度（fidelity）驗證：別人怎麼證明「twin 沒說謊」

#### 標準與學術做法

- 【來源】[ITU-T Y.3090（2022-02）](https://www.itu.int/rec/T-REC-Y.3090-202202-I)
  「Digital twin network – Requirements and architecture」：定義 DTN 為物理網路的虛擬
  表徵、三層架構（物理網路層／孿生層／應用層），並要求「real-time interactive mapping」。
  fidelity 只有定性描述（資料越全越準、還原度越高）。
  【推論】標準提供的是詞彙與架構分層，**沒有可執行的驗證程序**——不用花更多時間讀標準來
  找測試方法，我們 L4 的「OVS 當規格」已經比標準具體。
- 【來源】ns-3 對照實作驗證的典型做法：把模擬器的協定實作跟真實 Linux stack 對跑
  （[ns-3 emulation 與 hardware testbed 對照](https://www.researchgate.net/publication/261259149_Ns-3_emulation_on_ORBIT_testbed)）。
  MPTCP fidelity 研究（[Sensors 2020, PMC7766202](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7766202/)）
  的結論尤其有參考價值：**ns-3 只在特定條件下貼合硬體實測**（long-lived flows、
  無共享瓶頸）。
  【推論】fidelity 是**分域成立的**，不是一個布林值。我們自己的數據長一樣的形狀
  （≥25 Mbps 準、<10 Mbps 量化誤差主導）。正確的交付物是一張「**信任域地圖**」
  （哪個流量階、哪個窗長、哪種故障下 twin 可信到 ±多少），不是一句「twin 是準的」。
- 【來源】Hardware-in-the-loop emulation testbed（[WSC 2017](https://dl.acm.org/doi/abs/10.5555/3242181.3242209)）：
  用真硬體對照驗證模擬環境，再拿驗證過的模擬環境跑大規模實驗。
  【推論】我們的同構做法已經存在：**OVS 路徑就是我們的「hardware」**——
  `compare_baseline.py` 用 known-good OVS 行為當 P4 規格，正是 HIL 的精神。
  這條路線不需要新工具，需要的是把 L4 從「shape+facts」延伸到「數值信任域」（見上）。
- 【來源】前沿（**未驗證**，只讀摘要）：[Aether（arXiv 2604.18233）](https://arxiv.org/pdf/2604.18233)
  用 agentic AI＋digital twin 做網路驗證；[學習式模擬器增強（arXiv 2311.12745）](https://arxiv.org/pdf/2311.12745)
  用 ML 縮小 sim-to-real gap。均屬研究階段，不建議導入。

#### 對我們最實用的一條：真值抽查（truth spot-check）

【推論】綜合上面與我們自己的歷史（9 個 bug 有 8 個來自 live 實跑）：
「twin 沒說謊」最強的實務驗證不是更精的模型，是**讓 twin 的每一類宣稱都有一個
counter 級的驗證器**，並在 soak 中隨機抽查：

| twin 的宣稱 | counter 級驗證器（都已存在或一步之遙） |
|---|---|
| 「這條 link 速率是 X」 | OVS/bmv2 port counter 差分（§2.3） |
| 「這對 host 互通」 | canary ping **雙向**（runbook 已記載單向陷阱） |
| 「這條 path 是 A-B-C」 | 逐台讀 flow table 回來對（runbook §6h 已做過一次，`read_table_entries()`） |
| 「這條 link down」 | 對端 RX counter 是否凍結（runbook §6h 已用過：197539 → 197539） |
| 「edges_up = 38/40」 | netem qdisc 現況清點（`tc qdisc show` 的注入帳本，§1.6 M-1） |

昨晚教訓 #1 的黑洞之所以致命，正是「twin 說路徑存在、data plane 說不存在」——
truth spot-check 把這類謊言變成例行抓捕，而不是整夜輪的意外收穫。

#### iperf mesh 編排模式

【推論】（此段無單一外部來源，是通用做法對映到我們的拓撲）：
- **全網 full-mesh**（N×(N-1) 對）在 128 host 上是 16k 條 flow——會先量到 Ryu 與
  kernel 的 flow 管理極限，不是 data plane。這本身是一個有價值的測試，但要**當成
  控制平面壓力測試來設計**，不要當流量測試。
- 溫和且可重複的替代：**permutation matrix rounds**——每輪每台 host 恰好一收一發
  （128 條 flow），輪與輪之間換排列。壓力均勻、無 incast、每輪的預期樣本數可算。
- P4 側 4 host 沒有 mesh 可言；規模化流量測試天然屬於 OVS 側，P4 側維持
  單流 ladder（d7bf52f 形式）即可。

---

## 3. 任務 B：外部測試框架/模板評估

每項回答三個問題：**解決我們哪個缺口？導入成本？跟哪一層對接？**
判準嚴格——我們已有 L0–L4＋mutation gate，只有補到真缺口的才值得。

### 3.1 SDN 專用

#### STS（SDN Troubleshooting System）— ❌ 不適合
- 【來源】[ucb-sts/sts](https://github.com/ucb-sts/sts)：把 controller 失敗的事件序列
  自動縮成「minimal causal sequence」（delta debugging 推廣到分散式系統）。**Python 2.7＋PyQt4**，
  無近期活動，23 open issues／0 PR，明顯停止維護。只支援 OpenFlow 1.0＋POX。
- 【推論】它的**理念**恰好命中我們最痛的一類 bug（controller restart 觸發 /stats/flow wedge，
  root cause 未明）：把「哪個最小事件序列重現 bug」自動化。但工具本身 Py2＋POX，
  跟我們 Ryu＋自寫 proxy＋C++ kernel 完全不對接，導入＝重寫。
  **可借的是概念不是程式**：我們自己的 delta debugging 可以是一支腳本，
  對已知會 wedge 的操作序列做二分縮減。列入「概念採用」而非「工具導入」。

#### DELTA / BEADS — ❌ 不適合（現在）
- 【來源】[DELTA](https://www.researchgate.net/publication/316913281_DELTA_A_Security_Assessment_Framework_for_Software-Defined_Networks)：
  blackbox fuzzing SDN controller 的北向/南向介面，重放已知攻擊＋發現新的。
  [BEADS](https://arxiv.org/pdf/2210.15469)：遵循 OpenFlow 協定的 fuzzing，
  產生能穿過 parsing 層的畸形控制訊息。
- 【推論】兩者是**安全評估**取向（攻擊面），我們現階段缺的是**功能故障模型**（§1）不是
  攻擊面。BEADS「遵循協定的畸形訊息」概念與我們的 sFlow fuzz（I-1）同源，但它針對
  OpenFlow controller，不是 sFlow datagram。列入「以後做安全評估時再看」。

#### OFTest / PTF（Packet Test Framework）— ✅ **強烈推薦（P4 dataplane 單元層）**
- 【來源】[p4lang/ptf](https://github.com/p4lang/ptf)：從 OFTest 衍生的 dataplane 測試框架。
  模式＝「在 in-port 送封包 → 驗 out-port 收到什麼」。Python 3.10+、scapy 2.5.0（或內附
  bf_pktpy）、需要 root、需要 veth。bmv2 是其主要範例平台，active（175★）。
- **解決哪個缺口**：我們**完全沒有 dataplane 級的自動化 pipeline 測試**。目前驗 P4 行為
  靠 L4 的 OVS 對照（端到端、需完整 stack）。PTF 補的是中間層：**單台 bmv2、
  給定 table 狀態、一個封包進、驗轉發決定**——不需要 kernel、不需要 Ryu、不需要 128 host。
- **導入成本**：低-中。bmv2 的 veth harness 我們已在跑（P4 testbed 存在）；PTF 走
  P4Runtime 對 `simple_switch_grpc` 下表、送封包。**紀律注意**：需 `pip install ptf scapy`
  ——本任務不安裝，僅建議，附版本查證：`ptf` 版本自行 `pip index versions ptf` 查，
  scapy pin `2.5.0`。
- **對接哪一層**：**新的 L1.5**，介於 C++ 單元（L1）與端到端對照（L4）之間。
  它回答 L4 答不了的「這條 table rule 到底把封包送去哪」而不必起整個 stack。

### 3.2 P4 專用

#### P4Testgen — ✅ **推薦（P4 pipeline 迴歸的自動 oracle）**
- 【來源】[P4Testgen（SIGCOMM'23）](https://dl.acm.org/doi/10.1145/3603269.3604834)、
  [arXiv 2211.15300](https://arxiv.org/pdf/2211.15300)、
  [p4c/backends/p4tools/modules/testgen](https://github.com/p4lang/p4c/tree/main/backends/p4tools/modules/testgen)：
  對 P4 程式做 symbolic execution，覆蓋每一條可達語句，SMT 解出
  (input packet, output packet, control-plane config) 三件組，輸出 **STF/PTF/protobuf** 格式。
  支援 **v1model.p4 on bmv2**（正是我們的架構）。用 taint tracking＋concolic 處理 checksum/hash
  等 extern。**幾個月內在 bmv2/Tofino 成熟工具鏈找到 25 個 bug**。
- **解決哪個缺口**：我們的 P4 pipeline（`p4c-bm2-ss` 編的 `.p4`）**沒有窮舉式的分支覆蓋
  測試**。手寫測試只覆蓋想到的路徑。P4Testgen 自動產生覆蓋每條可達語句的測試。
- **導入成本**：中。它隨 p4c 一起（`p4testgen` binary），輸出 PTF → 正好餵給上面的 PTF harness。
  一次性投入產出一整套迴歸種子。**建議與 PTF 綁定導入**（P4Testgen 生成、PTF 執行）。
- **對接哪一層**：餵 L1.5（PTF）。也是**改 P4 pipeline 時的迴歸網**——改 `.p4` 後
  重生成、重跑，行為漂移立刻現形。

#### P4Runtime conformance / Stratum bmv2 測試模式 — ⚠️ 部分適合
- 【來源】p4testgen 可輸出 P4Runtime protobuf 訊息（見上）；Stratum 用 PTF 做 bmv2 測試。
- 【推論】我們的南向不是標準 P4Runtime stack，是**自寫 Python proxy 模仿 Ryu 北向＋自合成 sFlow**。
  完整 P4Runtime conformance suite 驗的是「你的 P4Runtime server 合不合規」——我們沒有標準
  P4Runtime server 面向 kernel，所以整套 conformance 錯位。**但** proxy 對 bmv2 下表**是**走
  P4Runtime gRPC，那一段可以用 conformance 的**子集**驗（table write/read 的語意）。
  優先級低於 PTF＋P4Testgen。

### 3.3 故障注入 / Chaos

#### Jepsen nemesis 目錄 — ✅ **概念採用（工具不導入）**
- 【來源】[jepsen.nemesis](https://jepsen-io.github.io/jepsen/jepsen.nemesis.html)、
  [tutorial 05-nemesis](https://github.com/jepsen-io/jepsen/blob/main/doc/tutorial/05-nemesis.md)。
  fault primitive 目錄：
  - **partition-halves / partition-random-halves / partition-random-node**：對稱切網
  - **partition-majorities-ring / bridge**：**非對稱／單向連通**（← 直接對映我們的 L-2 單向斷鏈！）
  - **hammer-time**：SIGSTOP/SIGCONT 暫停 process（← 對映 N-4 switch 暫停）
  - **clock-scrambler**：亂跳時鐘（← RS-3）
  - **bitflip / truncate-file**：檔案位元錯誤／截斷（← I-1 sFlow 截斷 datagram 的同型）
  - partitioner（自訂 grudge）、compose、noop
  - 網路故障底層就是**用 tc 調介面＋機率性丟訊息**——與我們 §1 的 netem 注入同一個機制。
- **解決哪個缺口**：Jepsen 是 Clojure/JVM，測分散式資料庫，**工具本身完全不適合**我們。
  但它的 **nemesis 目錄就是一份經過實戰的故障類型清單**——這正是任務簡報說的
  「即使工具不適用，故障類型清單本身就是我們要的」。§1 的故障模型目錄已經把
  bridge（單向）、hammer-time（暫停）、clock-scrambler（時鐘）、bitflip（截斷）
  對映進去了。
- **導入成本**：零（只採用清單）。
- **對接哪一層**：新的 **L5 故障注入層**（§5 建議 R-2）。

#### Pumba — ⚠️ 清單有用、工具不適用
- 【來源】[alexei-led/pumba](https://github.com/alexei-led/pumba)：Docker/containerd/Podman
  的 chaos。netem 子命令：**delay / loss / duplicate / corrupt / rate**；
  容器生命週期：kill/stop/pause/rm/restart；`iptables loss`（egress＋**ingress**，
  ← ingress 版正是單向故障）；`stress`（CPU/mem/IO）。
- **解決哪個缺口**：故障**類型清單**再次有用（duplicate、corrupt、rate 我們 §1.1 的
  L-3/L-4 已涵蓋方向）。但 Pumba 對 **Docker 容器**動手，我們是 **Mininet veth ＋ 裸 process**，
  不是容器——工具不適用。
- 【推論】唯一可借的新招：`iptables loss` 的 **ingress** 方向。我們的 netem 是 egress
  佇列丟包，要製造「只斷入向」的乾淨單向故障，`iptables -A INPUT` 比 netem 更精確。
  這是實作 L-2 時的一個具體技術選項（**紀律**：需 sudoers 授權 iptables，目前只授權了 tc，
  屬於建議非執行）。
- **對接哪一層**：概念餵 L5。

#### Toxiproxy — ✅ **推薦（對接 C-4 的 kernel↔Ryu HTTP 故障）**
- 【來源】[Shopify/toxiproxy](https://github.com/Shopify/toxiproxy) v2.x：單一 Go binary 的
  **TCP proxy**，經 HTTP API 注入 toxic。toxic 清單：latency（含 jitter）、down、
  bandwidth、slow_close、timeout、reset_peer（TCP RST）、slicer、limit_data、packet_loss。
- **解決哪個缺口**：C-4「kernel 對 Ryu 的同步 curl 會阻塞單執行緒 HTTP server」
  （`2026-07-28_test_coverage_gaps.md` §2.3）目前**無工具能注入這型延遲**。Toxiproxy 插在
  kernel↔Ryu 之間，`latency`/`timeout`/`reset_peer` 直接製造「Ryu 慢/斷」，
  觀察 kernel 單執行緒 io_context 的 head-of-line blocking。
- **導入成本**：低。單 binary、無侵入（改 kernel 的 Ryu endpoint 指到 proxy port 即可）。
  **紀律**：需下載 binary（建議非執行；附來源
  [releases](https://github.com/Shopify/toxiproxy/releases)，用前核 checksum）。
- **對接哪一層**：L5 的控制平面子類；也能驗 C-1（proxy 慢→下規則行為）。

### 3.4 Property-based（Hypothesis）— ✅ **推薦（拓撲不變量與 REST）**
- 【來源】[Hypothesis](https://github.com/HypothesisWorks/hypothesis/)，PyPI 現版
  **6.165.5（2026-08-12）**，維護活躍（DRMacIver/tybug/Zac-HD），Python ≥3.10。
- **解決哪個缺口**：`2026-07-28_test_coverage_gaps.md` §3 指出**不變量太寬鬆**（`edges_up ≤ edges_total`
  這類全域性質沒被系統性驗）、§2.2 HTTP 協定層零測試。Hypothesis 對這兩者都對症：
  - **拓撲不變量**：對任意事件序列（下規則／斷鏈／恢復的排列組合）產生後，
    斷言 `edges_up ≤ edges_total`、`path 端點 ∈ nodes`、`path 無迴圈`、
    `sum(per-switch flows) == total flows`。這些是 stateful property，
    Hypothesis 的 `RuleBasedStateMachine` 正是為此設計。
  - **REST schema 反向**：對 `/ndt/*` 的輸入用 strategy 生成畸形值，斷言「不 500」。
- **導入成本**：低。純 Python、零系統依賴、可離線。**紀律**：`pip install hypothesis`
  （建議非執行，pin `6.165.5` 或當時最新，來源 PyPI 官方——注意本專案吃過搶注套件的虧，
  `hypothesis` 名稱正牌無爭議但仍應核 publisher）。
- **對接哪一層**：**L2 增強**（REST property）＋ **L3/L4 增強**（拓撲不變量作為 stateful model）。
  與既有 mutation gate 完美契合：property 測試也要能親眼看它紅過。

### 3.5 Fuzzing（libFuzzer / AFL++）— ✅ **強烈推薦（sFlow parser）**
- 【來源】libFuzzer 是 LLVM 內建的 in-process coverage-guided fuzzer；AFL++ 是社群主力
  分支。兩者都與 ASan 協同（我們**已有 ASan 建置**，`sanitizer-and-ci-setup-gotchas`）。
- **解決哪個缺口**：I-1。sFlow UDP 是**唯一的第二輸入面**，歷史上出過 heap overflow，
  bounds check 補了但只覆蓋**手想到的**畸形（`2026-07-28_test_coverage_gaps.md` §5.1 稱「最大的空白」）。
  Fuzzer 系統性地探索 parser 的輸入空間。
- **關鍵優勢**：我們有 **31 個真實抓包 `.bin`**（`tests/fixtures/`）——**現成的 seed corpus**，
  這是多數專案 fuzzing 起步最缺的東西。parser 是純函式式的 datagram 解析
  （`FlowLinkUsageCollector.cpp:683` 起），libFuzzer 的 `LLVMFuzzerTestOneInput(data, size)`
  幾乎是為它量身訂做。
- **導入成本**：中。要寫一個薄 harness 把 `data/size` 餵進 parser 進入點，
  用 `clang -fsanitize=fuzzer,address` 編。**不需要新套件**（libFuzzer 隨 clang），
  這點對「不裝套件」紀律特別友善。
- **對接哪一層**：**新的 L1-fuzz**，掛在既有 ASan 建置上；CI 可跑固定時長（例 5 分鐘/次）。
  找到的 crash 直接變成 `test_SFlowParsing.cpp` 的迴歸 case。



---

## 4. 建議清單（按 價值/成本 排序）

排序原則：先補「昨晚證明會出真 bug、而且修完沒有東西守」的缺口，再補「已知空白但尚未咬過人」的。

| # | 項目 | 價值 | 成本 | 要裝東西嗎 | 對接層級 |
|---|---|---|---|---|---|
| **R-4** | **P4Testgen 覆蓋閘門** | ★★★ | **零**（已實測跑通） | ❌ 已裝 | L0（閘門）／L1.5（PTF 需裝） |
| R-1 | sFlow libFuzzer harness | ★★★ | 低-中 | ❌ clang 內附 | 新 L1-fuzz |
| R-2 | L5 故障注入層 | ★★★ | 中 | ❌ | 新 L5 |
| R-3 | Hypothesis 拓撲不變量 | ★★☆ | 低 | ✅ hypothesis | L2/L3 增強 |
| R-5 | Soak ＋ drift 量測 | ★★☆ | 中-高（需長時 live） | ❌ | 新 L6 |

**如果只做一件事**：跑 R-4 的那一行指令——零安裝、7 分鐘、已證實會產出一個發現。
**如果只做一週**：R-4 閘門 ＋ R-2 的第一型故障（單向斷鏈）。

---

### R-1 ★★★ sFlow parser 的 libFuzzer harness

**為什麼排第一**：唯一同時滿足四個條件的項目——(a) 是唯一沒被系統性覆蓋的輸入面
（`2026-07-28_test_coverage_gaps.md` §5.1 稱「最大的空白」）；(b) 歷史上真的出過 heap overflow；
(c) **seed corpus 已經存在**（`tests/fixtures/` 實測 **31 個** `.bin` 真實抓包，
其中已有 `emitted_tcp_truncated.bin` 這種畸形種子）；(d) **不需要安裝任何套件**
——libFuzzer 隨 clang 內附，ASan 建置已存在。

**接點已確認**：`FlowLinkUsageCollector::handlePacket(char* buffer, size_t len)`
（`src/ndt_core/collection/FlowLinkUsageCollector.cpp:915`，2026-08-13 實測行號）
簽名就是 `(buffer, len)`——與 `LLVMFuzzerTestOneInput(const uint8_t*, size_t)` 一對一。
另有 `reportMalformedDatagram(size_t len, const char* reason)`（:1606），
表示 parser 已經有明確的「拒絕」路徑，fuzzer 的預期結果是**乾淨拒絕而非 crash**，
oracle 很清楚。

**第一步指令**（研究報告只給指令，本任務不執行）：

```bash
ls tests/fixtures/*.bin | wc -l && grep -n "handlePacket" include/ndt_core/collection/FlowLinkUsageCollector.hpp
```

**預期第一個產出**：一支約 20 行的 `tests/fuzz/fuzz_sflow.cpp`，
`clang++ -g -O1 -fsanitize=fuzzer,address` 編出 binary，
用 `tests/fixtures/` 當 seed corpus 跑 60 秒。**第一個產出的判準不是「沒 crash」，
而是「coverage 有在漲」**——若 corpus 立刻飽和，代表 harness 沒真的走進 parser
（這是 [[existence-is-not-wiring]] 的 fuzzing 版本，要先證明它會失敗：
故意把一個 bounds check 註解掉，確認 fuzzer 幾秒內抓到，才算 harness 有效）。

**對接層級**：新增 **L1-fuzz**，掛在既有 ASan 建置。找到的每個 crash → 迴歸進
`test_SFlowParsing.cpp`。

---

### R-2 ★★★ L5：故障注入層（把昨晚的四個故障形狀變成可重跑的目錄）

**為什麼排這裡**：§1 表格裡「修復已落但無測試類別」出現三次（L-2 單向斷鏈、
C-2 mastership 相撞、C-1 部分）。昨晚抓到的 bug 修掉了，**下次同型故障沒有東西守**。
這是本報告最重要的一條——它直接回應「我們缺的是系統性的故障模型目錄」。

**設計要點**（三個，都來自我們自己的教訓，不是外部框架）：
1. **故障目錄是資料不是程式**：一個 `faults.txt`（沿用專案既有的
   `LEVEL | regex | 理由` 三欄格式哲學）列出 §1 的每一型；harness 讀它逐項執行。
   這樣新故障型是加一行，不是改程式。
2. **每輪強制 qdisc 前後置**：`qdisc_snapshot.sh save` → 注入 → 還原 →
   `qdisc_snapshot.sh diff`，**diff 不為空就整輪作廢**。工具已存在（§1.6 M-1），
   缺的是強制。這把昨晚教訓 #3（假證據）擋在源頭。
3. **判準用雙向 canary**：runbook 已記載「單看一個方向不能判斷互通」——
   每個故障的 pass/fail 都要雙向 ping ＋ `all_destination_paths` 數 ＋
   對端 counter 凍結三者交叉（§2.4 的 truth spot-check 表）。

**第一步指令**：

```bash
sed -n '1,20p' tools/test_workflow/qdisc_snapshot.sh && grep -rn "netem" doc/2026-08-10_p4_manual_test_runbook.md | head
```

**預期第一個產出**：`faults.txt` 的**第一型只寫 L-2 單向斷鏈**（單端 netem），
外加一支 30 行的 runner 把「snapshot → 注入 → 等 20 s → 三項判準 → 還原 → diff」
串起來。預期它**第一次跑就紅**——因為單向故障正是昨晚黑洞的成因，
`034da18` 修的是重算路徑，但「圖不對稱是穩態」這件事值得再驗一次
（**若第一次跑就綠，要先懷疑注入沒生效**，用 `tc qdisc show` 與對端 RX counter 自證）。

**對接層級**：**新的 L5**，在 L4 之後（需完整 stack）。可被 `run_layers.sh` 加一個
`faults <mode>` 子命令。

---

### R-3 ★★☆ Hypothesis 拓撲不變量（stateful property）

**為什麼排這裡**：成本極低（純 Python、無系統依賴），而 `2026-07-28_test_coverage_gaps.md` §3
整節都在講「不變量太寬鬆」。它與 R-2 是互補的：R-2 注入**我們想到的**故障，
Hypothesis 產生**我們沒想到的事件序列**。

**最有價值的三條 property**（都不需要 live 流量，只要 running stack）：
- `edges_up ≤ edges_total`（任何事件序列後）
- `path 的每個端點 ∈ nodes`、`path 無重複節點`（抓迴圈；目前只有
  `FORBID | Exceed 100 hop` 這條 log 規則當安全網）
- `admin_disabled ∧ is_enabled` 恆為假（runbook §7 已寫出這條，但今天**空洞成立**；
  Phase 7 電源管理完成後它才有內容——正是現在該接上的時機）

**第一步指令**：

```bash
python3 -c "import hypothesis, sys; print(hypothesis.__version__, sys.executable)"
```

（先確認 venv 裡**有沒有**——若無，pin `hypothesis==6.165.5`，來源 PyPI 官方，
核 publisher 為 DRMacIver/tybug/Zac-HD。本任務不安裝。
⚠️ 用 venv 直譯器，conda 的 python3 缺套件會給出假綠燈。）

**預期第一個產出**：一支 `RuleBasedStateMachine`，rule 是
{下規則, 斷鏈, 恢復, 電源開關}，invariant 是上述三條。
**驗收照既有規矩走 mutation gate**：把 kernel 的 `edges_up` 計算改成不扣 down 的邊，
property 必須紅。

**對接層級**：**L2/L3 增強**（跑在既有 contract test 旁邊，共用 `spec.py` 的 endpoint 知識）。

---

### R-4 ★★★ P4Testgen + PTF（P4 dataplane 的 L1.5）— **已實測驗證，排序上調**

> 🟢 **這條在研究過程中從「推薦」升級為「已驗證可行」**。報告初稿把它排第四、成本評「中」，
> 理由是「要先確認 p4testgen 有沒有隨 p4c 出貨」。**實測結果：已經裝好了**
> （`/usr/local/bin/p4testgen`，2026-08-13 實測），clang 18.1.3 也在。
> 於是我直接對我們的 `.p4` 跑了一輪——**零安裝、唯讀、輸出只寫 scratchpad**。
> 下面全部是實測數字，不是推論。

**實測指令與結果**（`p4_proxy/p4_src/ndtwin_switch.p4`，482 行）：

```bash
p4testgen --target bmv2 --arch v1model --max-tests 0 \
  --track-coverage STATEMENTS --only-covering-tests --print-coverage \
  --test-backend PTF --out-dir /tmp/p4tg ndtwin_switch.p4
```

| 實測項 | 結果 |
|---|---|
| 收斂後語句覆蓋 | **85.2%（46/54 nodes）** |
| 需要幾個測試 | **10 個**（`--only-covering-tests` 過濾後；未過濾時 53 個路徑） |
| 執行時間 | 7 分鐘內收斂（exit 0） |
| 產出 | 一支可直接跑的 PTF 測試檔（`ndtwin_switch.py`） |
| 對照：不過濾、只取 20 個測試 | 只有 44.4%（24/54）——**`--only-covering-tests` 是關鍵旗標** |

#### 🔴 第一輪就有發現：8 個永遠覆蓋不到的節點全部是 sFlow 取樣路徑

收斂後未覆蓋的 8 個節點**不是隨機分佈**，它們是連續的一整塊，
`ndtwin_switch.p4:414–421`——egress 裡處理 `BMV2_INSTANCE_TYPE_INGRESS_CLONE` 的分支，
也就是**替 clone 出來的取樣封包組裝 `packet_in` 標頭**那一段
（`reason = PKTIN_REASON_SAMPLE`、`sampling_rate = SAMPLE_RATE`）。

【推論】原因與後果：
- **原因**：取樣走的是 ingress 的 `clone_preserving_field_list(CloneType.I2E, ...)`（:389），
  clone 出來的封包是**另一次 egress 執行**。P4Testgen 的符號執行走的是單一封包的路徑，
  不模型化 clone 產生的第二條路徑，所以那個分支對它永遠不可達。
- **後果（這才是重點）**：**P4 側 sFlow 合成的那段程式碼，自動測試生成原理上碰不到。**
  它只能靠 live 跑驗證。這正好給 [[live-runs-find-what-tests-cannot]] 一個機制層級的解釋——
  不是我們沒去寫測試，是這一段**結構上就在自動化的射程外**。
- **直接可行動**：這 8 行的唯一守護者現在是 live run 與
  `test_SFlowEmitterRoundtrip.cpp` 的跨語言 round-trip。改動 `.p4` 的取樣區塊時，
  **不能靠 P4Testgen 迴歸網接住**，必須手動走 runbook 的流量驗證。
  這件事值得寫進 `2026-07-27_p4_bmv2_support_plan.md`。

**剩下的成本**：只剩 PTF 執行器（`pip install ptf scapy`——venv 實測**兩者皆無**）。
P4Testgen 這半邊零成本已經可用；即使**完全不裝 PTF**，
`--assert-min-coverage` 也能單獨當 CI 閘門（P4 改動後覆蓋率跌破 0.85 就失敗）。

**第一步指令**（現在就能跑，零安裝）：

```bash
p4testgen --target bmv2 --arch v1model --max-tests 0 --track-coverage STATEMENTS --only-covering-tests --print-coverage --test-backend PTF --out-dir /tmp/p4tg p4_proxy/p4_src/ndtwin_switch.p4
```

**預期第一個產出**：85.2% 的基線數字 ＋ 那 8 行未覆蓋清單。把 0.85 定為
`--assert-min-coverage` 門檻，`.p4` 一改就知道有沒有新增不可達的程式碼。

**對接層級**：**新的 L1.5**（單台 bmv2，不需 kernel/Ryu/完整 stack）。
覆蓋率閘門那半邊甚至可以掛在 **L0**——它只需要 `.p4` 檔，連 bmv2 都不用起。

---

### R-5 ★★☆ Soak + drift 量測（把 d7bf52f 從一次性量測變成回歸門檻）

**為什麼排這裡**：價值高（同時補 RS-1 資源洩漏缺口與 twin fidelity），
但需要長時間 live 環境，且要先做 noise floor 前置，所以排最後。

**三件事一次做完**（同一個 soak run 就能收三種資料）：
1. **drift**：每 10 s 記 `(twin rate, counter 差分, t)`，按流量階分層（§2.3）
2. **資源**：每 60 s 記 `/proc/<pid>/status` 的 VmRSS/Threads
   ——補上 `2026-07-27_testing_workflow.md` 寫了四年、**一項都沒實作**的判定標準
3. **log**：既有 `check_logs.py` 全程掛著

**門檻的算法已經有了**（§2.3 第 4 點）：`門檻(R,T) = max(1.5 × 196√(1/c), 2%)`，
其中 `c = R×T / 3.01 Mbit`。這讓門檻**有理論依據而非拍腦袋**，也天然避免 flaky。

**第一步指令**：

```bash
git show d7bf52f --stat && grep -rn "VmRSS\|Threads" tools/ | head
```

（第二段的預期輸出是**空的**——證實 §1.5 RS-1「工具不存在」仍然成立。
若有輸出，代表這一條已被別的 session 做掉了，先讀再說。）

**預期第一個產出**：一輪 3×15 分鐘的 **noise floor** 量測（twin 不動、
同場景重跑），得出 ground truth 自身的輪間變異。**這個數字是後續所有 drift 判斷的地板**
——沒有它，bmv2 自己的 temporal fidelity 劣化（§2.1，256 台時誤差達 91.4%）
會被算到 twin 頭上。

**對接層級**：**新的 L6 soak**，或作為 L5 的長時模式。

---

## 5. 不建議清單（看過但不適合，附一句話理由）

| 工具/方法 | 一句話理由 |
|---|---|
| **TRex** | bmv2 天花板 80 kpps／`simple_switch_grpc` 約 170 Mbps，DPDK 級產生器（200 Gbps）差三個數量級，且需綁定 DPDK 介面——iperf3 就夠了 |
| **STS** | Python 2.7＋PyQt4＋只支援 POX/OpenFlow 1.0，無維護；理念（minimal causal sequence）值得借，程式不能用 |
| **DELTA / BEADS** | 安全評估取向（攻擊面 fuzzing），我們現在缺的是功能故障模型；等做安全評估再回來看 |
| **Pumba** | 對 Docker/containerd 容器動手，我們是 Mininet veth ＋ 裸 process；**故障類型清單已採用**，工具不導 |
| **Jepsen（工具本體）** | Clojure/JVM、為分散式資料庫的線性化驗證而生；**nemesis 目錄已採用**，框架不導 |
| **VT-BMv2（virtual time）** | 要改 Linux kernel（`task_struct` ＋ `gettimeofday`）；我們 10 台 switch 遠在 fidelity 崩壞點（64 台）之下，用不上 |
| **完整 P4Runtime conformance suite** | 驗的是「你的 P4Runtime server 合不合規」；我們沒有面向 kernel 的標準 P4Runtime server（是自寫 proxy 模仿 Ryu 北向），整套錯位——只有 table write/read 子集有意義 |
| **ITU-T Y.3090** | 提供 DTN 的詞彙與三層架構，fidelity 只有定性描述、無可執行驗證程序；我們 L4 的「OVS 當規格」已經比它具體 |
| **hping3** | 與 scapy 能力重疊，在我們的 pps 區間沒有差異化價值 |
| **ns-3 對照建模** | 要為我們的拓撲重建一套模型才能對照，成本遠高於「用 OVS 路徑當 known-good」——我們已經有更便宜的 HIL 同構做法 |
| **Aether / 學習式模擬器增強** | 研究階段（2026 arXiv，僅讀摘要，**未驗證**），無穩定實作可導入 |
| **AFL++（相對於 libFuzzer）** | 需額外安裝；libFuzzer 隨 clang 內附且 ASan 建置已存在——同樣效果、零安裝，先用 libFuzzer |

---

## 6. 這份報告本身的限制

- **未驗證**：per-switch bmv2 閒置 RSS/CPU 的公開數字沒找到；veth 數量上限沒找到明確文件。
  兩者都建議自己量（§2.1 推論 3），一小時內可得。
- **未驗證**：Aether（arXiv 2604.18233）與學習式模擬器增強（arXiv 2311.12745）只讀了
  摘要層級，未讀全文。
- ~~**未驗證**：p4testgen 是否已隨本機 p4c 出貨~~ → **已驗證：有**（`/usr/local/bin/p4testgen`）。
  依報告自訂的判準，R-4 已從 ★★☆ 上調為 ★★★ 並實測出 85.2% 覆蓋基線與一個發現，見 §4 R-4。
- **研究中途的自我更正一則**：§1.6 M-1 初稿寫「沒有注入前存檔／還原後比對的機制」，
  實際 `tools/test_workflow/qdisc_snapshot.sh` 已經存在（昨晚那輪的產物）。
  已更正為「工具已有、缺的是強制使用」。記錄下來是因為它再次示範了
  「引用前先打開它」——連寫缺口報告的人都會憑印象宣告缺口。
- 本報告全程唯讀：未安裝任何套件、未修改 repo、未碰任何 localhost port、未開 issue/PR。

---

*[Co-developed with claude code -- Adam]*
