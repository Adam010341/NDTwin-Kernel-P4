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
| `simple_switch_grpc` 吞吐 | **~170 Mbps** | **文獻值**:Chen/Hu/Jin, SIGSIM-PADS '23(他們的 build 條件未載明);**本機從未做過飽和實測** |
| `simple_switch`(非 grpc)中位 | ~1047 Mbps | 同論文 |
| 官方建議組態實測 | ~917 Mbps 中位 | 上游 `docs/performance.md`(`-O3 --disable-logging-macros --disable-elogger`) |
| 本機 OVS 對照 | **980 Mbps** | **本機實測** 2026-08-15,同 iperf,受 TCLink 1G 整形壓制 |

**出處更正**:此前文件與簡報素材把 170M 寫成「本機實測」——它其實是文獻值經記憶轉述後
被誤當成量測(memory `bmv2-scale-ceiling-…` 的原始出處本來就標著論文)。本機的實錘只有
兩件:**build 是 -O0+全 logging**(config.log 原文)、**OVS 同機可到 980M**。本機 bmv2
飽和點多少,**要量了才知道**——依 [[arithmetic-that-fits-is-not-the-mechanism]] 紀律不預測,
重建驗證計劃第一步就是「舊 build 先量本機基線」,屆時 170 這個文獻值同時接受檢驗。

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
