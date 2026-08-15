# bmv2 ~170 Mbps 的成因與解方(2026-08-15 調查報告)

> Adam 委託:「詳細的 codebase 審查 + online search,找出 bmv2 效能瓶頸的可能原因與解決方案」。
> 裁決範圍:報告+重建配方,**不動現役 bmv2**(它是所有 live 測試的共用基礎)。
> 證據底稿:`doc/audit/2026-08-15_bmv2-source-analysis.md`(source subagent 全文,
> file:line 級引註);本文是策展版。

## 一句話答案

**~170 Mbps 不是 bmv2 的天花板,是「這一顆 build」的天花板**:現裝的 `simple_switch_grpc`
以 **`-O0` 無最佳化**編譯、且**全部 debug logging 巨集與 nanomsg event logger 都保留**——
p4-guide 安裝腳本的預設(`config.log:7` 原文:`./configure --with-pi --with-thrift …
'CXXFLAGS=-O0 -g'`,出處 `p4-guide/bin/build-behavioral-model.sh:84`)。

## 成因三層(由可修到不可修)

**第 1 層:部署層(主導,重編即解)**
- `-O0`:每個 P4 欄位都是 GMP `Bignum`,經 ~180 個本該 inline 掉的小 accessor 存取——
  `-O0` 下每個都是真函式呼叫。這一項放大以下所有成本。
- logging 巨集保留:**每次查表**(`match_units.cpp:783`,而且上游把便宜版註解掉、
  出貨昂貴版)、**每次命中**(`match_tables.cpp:116`,還持著表鎖做)、**每個 parser 狀態**
  都在做 `ostringstream` 格式化——然後丟進 **null sink**。
  ⚠️ 關鍵:`--log-level off`/不開 `--log-console` **救不回來**——巨集展開成真呼叫,
  參數在 spdlog 檢查等級前就求值;唯一解是編譯期拿掉(`--disable-logging-macros`)。
- elogger 保留:每包多次 struct 填充+虛擬呼叫送進 dummy transport。
- `assert()` 活著(無 `-DNDEBUG`)。

**第 2 層:結構層(重編不解,要動上游原始碼)**
- **單一 RX 線程**對全部 port `select()`,每個 ready port 每次喚醒**只收一包**
  (`bmi_port.c:150-169`);底層 libpcap `pcap_next_ex` 逐包+immediate mode(無批次)。
- **單一 ingress 線程**吃下全部解析+ingress match-action;egress 固定 4 線程
  (`static constexpr`,無 runtime 旋鈕)。每包跨三段 mutex+condvar 佇列交接。
- PHV pool 全域鎖(每包兩次 lock/unlock)、每包多次字串鍵 hash 查 PHV 欄位。

**第 3 層:已排除的嫌疑(查過,不是它們)**
- **不是限速設定**:egress `queue_rate_pps` 預設 0=不限速(`queueing.h:815,694-699`)。
- **不是我們的啟動參數**:topo 沒開 `--log-console`(註解掉)、無 `--pcap`、無 `--nanolog`
  ——四個會更糟的 runtime 旋鈕全部乾淨,runtime 端無免費午餐可撿。
- **不是 1/256 clone 取樣**:clone 需整包重解析,但攤提 <1%,別追。

## 數字對帳(⚠️ 注意出處欄——寫本報告時抓到一個出處錯誤)

| 數字 | 值 | 出處 |
|---|---|---|
| `simple_switch_grpc` 吞吐 | **~170 Mbps** | **文獻值**:Chen/Hu/Jin, SIGSIM-PADS '23(他們的 build 條件未載明);⚠️ 本機實測(下節)顯示它**不描述本機任一顆 build** |
| `simple_switch`(非 grpc)中位 | ~1047 Mbps | 同論文 |
| 官方建議組態實測 | ~917 Mbps 中位 | 上游 `docs/performance.md`(`-O3 --disable-logging-macros --disable-elogger`) |
| 本機 OVS 對照 | **980 Mbps** | **本機實測** 2026-08-15,同 iperf,受 TCLink 1G 整形壓制 |

**出處更正**:此前文件與簡報素材把 170M 寫成「本機實測」——它其實是文獻值經記憶轉述後
被誤當成量測(memory `bmv2-scale-ceiling-…` 的原始出處本來就標著論文)。本機的實錘只有
兩件:**build 是 -O0+全 logging**(config.log 原文)、**OVS 同機可到 980M**。本機 bmv2
飽和點多少,**要量了才知道**——依 [[arithmetic-that-fits-is-not-the-mechanism]] 紀律不預測,
重建驗證計劃第一步就是「舊 build 先量本機基線」,屆時 170 這個文獻值同時接受檢驗。

## 本機飽和實測(2026-08-15,A/B 兩輪,`4b339f2` 的 override seam)

**方法**:`ndtwin-lab topo-start` 起 10-switch fabric(4 hosts、offloads off)+ `stack.sh up p4`
全 stack(pipeline/routes 由 proxy 推、kernel 輪詢與 sFlow clone 照常=生產態);iperf3 經
`mnexec` 走 **h1→h2 的 3-hop 路徑(s1→s5→s2)**;兩輪跑一字不差的同一腳本,唯一差異=
`bmv2_binary_override` 檔(輪 2 指 `/usr/local/bmv2-fast`,`/proc/<pid>/maps` 實證零 stock 庫
映射)。UDP ramp 1400B×10s/點;loss 為 iperf3 server 端回報。

| 量 | stock(-O0+logging) | bmv2-fast(-O3, no logging) | 倍率 |
|---|---|---|---|
| UDP 零損點(1400B) | 25 Mbps(50M 起 15.7% loss) | 300 Mbps(0.17% loss) | **12×** |
| UDP delivered 天花板 | **~40-42 Mbps**(50→300M offered 全壓平在此) | **~460-530 Mbps**(knee 300→400M;700M offered 時 528) | **~12-13×** |
| TCP 單流 goodput | 24.2 Mbps | 431.0 Mbps | **17.8×** |
| TCP 8 平行流合計 | 24.2 Mbps(平行完全不救) | 435.7 Mbps | 18× |
| 64B 小包 delivered | **~3,619 pps** | **~50,786 pps** | **14×** |
| 閒置 RTT(3 hops) | 9.1 ms | 2.8 ms | 3.3× |
| loopback 對照(h1→h1) | 42.4 Gbps | 63.5 Gbps | (host 從不是瓶頸) |

**機制(量出來的,不是推的)**:
- **天花板是 pps 不是 bps**——stock 輪 1400B 平台 ~3.66k pps ≈ 64B 實測 3.62k pps,包長無關;
  每包固定成本主導,正是第 1 層(-O0+logging 巨集)的預測形狀。
- **丟包全發生在第一台 on-path switch 進程內部**:100M burst 實測 h1 送 89,296 →
  `s1-eth3` RX 89,296(介面層零丟、packet-socket 計數零動)→ `s1-eth1` TX 僅 33,456;
  下游 s5/s2 對倖存流量零損。丟點在 bmv2 的 input buffer,**介面計數器看不見它**
  ——對「用 counter 對帳」的任何邏輯是個地雷。
- **飽和時 on-path 三台各燒 ~165% CPU**(多執行緒分攤),off-path 七台 <1%,CPU-bound 坐實。
  ⚠️ 途中一度量到「全部 ~0.5%」——那是假象(前一測 server 未釋放、負載根本沒跑),
  差點又犯 [[arithmetic-that-fits-is-not-the-mechanism]];用 `ip -s link` 前後快照+同步
  pidstat 才拿到真值。
- **170 Mbps 文獻值不描述本機任一顆 build**:stock 比它低 4×、fast 比它高 ~3×(且我們量的
  是 3-hop 路徑不是單 switch)。引用它只能當「量級提示」,不能當本機事實。

**對上層邏輯的含意**:拓撲宣告 1 Gbps 時,P4 側單流利用率上限從 ~4%(stock,比先前
寫的 17% 更糟)升到 ~43-53%(fast)。TE 的 70% 壅塞門檻在 stock 上物理不可觸發;
fast 上單流仍差一截,但多流共享 uplink 時已進入可能範圍——TE-on-P4 的實驗從「不可能」
變成「要設計」。

**輪 2 功能冒煙(上游警告此組態過不了全部 p4c 測試,先驗再信)**:pipeline push+route
install 全成、graph 10/10 up+enabled+40 edges、12/12 全對 ping 通。未跑完整 L1/CI
against fast build——它只由 override 檔選用、預設路徑照舊 stock,風險受控。
原始 JSON 與 per-switch 證據:session scratchpad `results_round1_stock/`、
`results_round2_fast/`、`droploc/`(session 結束即失效;關鍵數字已全數載於本節)。

## 深挖輪補充(2026-08-15 晚,usage 刷新後)

**fast build 飽和機制(perf 實測,31,717 樣本,s1@700M)**:
- **沒有單執行緒牆**:四條 bmv2 worker 各吃 16-36% 一顆核、合計 ≈100%,主執行緒與
  gRPC 執行緒全閒。天花板不是「一顆核撞滿」,是**每包關鍵路徑跨多段 thread 交接的
  總成本**。
- **cycle 去向=資料表示層**(單一函式無一超過 ~5%,千刀萬剮型):GMP 大數
  (`__gmpz_init_set/import/export/and` 合計 ~10%+)、字串鍵 hashtable 查 PHV 欄位
  (`_Map_base::at`/`find`/`_Hash_bytes` ~9%+)、malloc/free churn(~9-12%)、
  `Field::export_bytes`、`Expression::eval_`。與本報告第 2/3 層的源碼分析完全吻合——
  **configure 旗標已榨完,再上去是上游架構工程**。
- **丟包位置與 stock 輪同構**:700M 下 s1 收 624,963、轉出 437,301,~99% 損失在第一台
  switch 的 input buffer;下游每跳僅 ~0.2%。介面計數器與 packet-socket 計數兩層全零。

**⭐ 新缺陷:sFlow clone 取樣存在 ~0.8 clone/s 的硬頂(兩顆 build 都有,非 fast 回歸)**
- 實測(s1,同窗口 Δ`egress_port_counter[255]`/Δ`[1]`,20 秒窗):
  | 流量 | 實得 clone | 規格 1/256 應得 |
  |---|---|---|
  | 20M/1786pps(fast) | 8 | 140 |
  | 20M/1786pps(stock) | 16 | 140 |
  | 5M/446pps(stock) | **16** | 35 |
  5M 與 20M **絕對數相同**——不是機率性 under-fire,是**時間性定額 ~0.8/s**。
  模型:`實得 ≈ min(pps/256, ~0.8/s)`,cap 只在 >~200pps 時綁住。
- **已排除**:P4 源碼正確(`ndtwin_switch.p4:384` uniform [0,255]==0、每個非 CPU 包都過)、
  編譯 JSON 忠實(`modify_field_rng_uniform 0x0000-0x00ff`)、非 fast 回歸(stock 同病)。
  cap 出現在 switch 自己的 egress counter=瓶頸在 bmv2 內部 ingress-clone→CPU-port
  egress 之間,不在 proxy 之後。
- **與歷史觀察對帳**:8/12「5pps 下 51.2s 才一顆、觀察窗多半空」=cap 不綁、照規格;
  8/13「ping 要 ~500pps 才穩定產生 sample」=撞 cap 後恆 ~0.8/s 的樣子。三天觀察一個模型收齊。
- **對 twin 的影響(⚠️ 2026-08-15 深夜改寫——初版「恆常低報 ~9×」過度簡化,經
  8/15 mainDev 的反例快照與 kernel 源碼仲裁後拆成兩軌)**:
  - **flow 速率點估計:可以讀到近真值。** kernel 是天真 ×samplingRate
    (`FlowLinkUsageCollector.cpp:1674` `Δbytes×8×256`)**但帶零閘門**:`hopsCounter`
    只數該秒有樣本的 hop(`:1701`),無樣本的秒被排除在 hop 平均外而非拉低它。
    單樣本量子=1470B×8×256≈**3.01 Mbps**;clone 若叢發(數顆同秒抵達),該秒估計
    ≈真值。**mainDev 實測佐證**:08-14 stock、20M UDP,`get_detected_flow_data` 回
    22.30 Mbps(+11%)——7-8 顆同秒即得此值。代價是**更新稀疏、變異巨大、叢發間
    讀到 0/舊值**。
  - **link 用量與一切時間積分量:系統性低報成立。** `m_counterReports`
    (`:1426-1428`)對每顆樣本連續累積 `bytes×256`,窗口總量=實得樣本數×3.01Mb
    ——cap 之下窗口積分恆等比縮水(1786pps 時 ~9×)。
  - flow **存在**偵測不受影響(樣本有在到、`twin_audit` 零矛盾)。
  - 與「測謊器不做速率對帳」的既有裁決一致,但根因現在有名字了。
- **stock 側的間接反證與調和(8/15 mainDev 提供)**:08-14/08-15 兩筆 kernel 估計
  量級全對(22.3M/33.2M 級)——在零閘門+叢發模型下與 clone cap **不矛盾**(見上),
  不需要假設「stock 當時沒 cap」。惟叢發性本身尚未直接量測(我方只有窗口總數,
  無到達間隔),列入下輪驗證。
- **fast build 額外嫌疑(mainDev 自首,尚未檢驗)**:`build_bmv2_fast.sh` 在官方配方
  外多了 `-DNDEBUG -march=native -fno-semantic-interposition` 三支旗標——但 **cap 在
  無這些旗標的 stock 上同樣出現**,故三旗標非 cap 主因;它們仍可能解釋 fast(8/20s)
  與 stock(16/20s)的 2× 差(該差亦可能只是小樣本 Poisson 噪聲)。
- **下一步(root cause 在 bmv2/PI 源碼層,下輪)**:①讀 simple_switch_grpc 的 clone→
  CPU-port→PI packet-in 路徑找節流點 ②量 clone 到達間隔(判叢發)+tcpdump :6343
  對帳 emitter 端+proxy 加 packet-in 計數器 ③純官方配方重編 fast-vanilla A/B 三旗標
  ④**取樣比率 A/B 進驗證計劃**:任何新 bmv2 build 在信任其數字前,除功能測試外必量
  `Δcounter[255]/Δcounter[1]`(本節的 20 秒窗方法)——此前驗證計劃只寫功能測試,
  是個漏。是否回報上游待根因(Adam 已裁決:先查根因)。

## 解方

**主解:`tools/test_workflow/build_bmv2_fast.sh`**——照官方組態重建到**獨立 prefix**
`/usr/local/bmv2-fast`(現役 `/usr/local` 完全不動,兩套可並存切換)。腳本檔頭有五條
必讀決策點,最重要三條:
1. 上游自己警告此組態「不能通過全部 p4c 測試」——重建後**先重跑我們的 P4 功能測試**再信數字;
2. 共享庫陷阱:不設 `LD_LIBRARY_PATH` 會**默默混跑**新舊庫;裝完**不可 ldconfig**;
3. 換 binary 後,文件與簡報裡的 170 Mbps 全部變歷史值,要標注是哪顆 build 量的。

**驗證計劃**(重建當天照做):固定 workload 基線 → 換 fast binary 重測 → 若增益不如預期,
`py-spy`/`perf` 經 mnexec 掛上去看時間是否已從字串格式化移到 RX loop——是的話就撞到
第 2 層結構牆,configure 旗標到此為止。

**明確不做的**:不動 `/usr/local` 現役安裝(Adam 裁決)、不改 bmv2 原始碼(第 2 層是
上游工程)、不追 clone 取樣路徑(<1%)。

## 對現有文件/簡報的影響

- 簡報 template Page 29 的吞吐對照**已補注**:170M 是本機 debug build 的數字,
  非 bmv2 天花板;附重建配方指引。
- 記憶 `bmv2-scale-ceiling-and-sflow-sample-math` 的 >64 台 fidelity 天花板**不受影響**
  (取樣誤差地板與 build 無關);per-switch 吞吐數字在重建後要更新。

## Sources

- [p4lang/behavioral-model docs/performance.md](https://github.com/p4lang/behavioral-model/blob/main/docs/performance.md)(官方效能文件與建議組態)
- [p4lang/behavioral-model README](https://github.com/p4lang/behavioral-model/blob/main/README.md)(--disable-logging-macros 說明)
- [behavioral-model issue #823](https://github.com/p4lang/behavioral-model/issues/823)(效能測試落包討論)
- 本機證據:`/home/adam/P4_Source_Code/behavioral-model/config.log:7`、
  `p4-guide/bin/build-behavioral-model.sh:84-92`(引文見 audit 版全文)
