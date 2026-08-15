# 無記憶驗收的三方複判(2026-08-15 深夜)

> 對 `2026-08-15_fresh-acceptance-report.md` 的獨立審計。三個判官互盲平行:
> **DeepSeek v4-pro**(effort max,只看報告文本)、**Fable 5 判官**(worktree 隔離無記憶,
> 可讀源碼 spot-check)、**Muse Spark 1.2 contributor**(reasoning_effort xhigh,只看報告
> 文本;Adam 裁決全文可送——「本來就是開源專案」)。原始輸出:DeepSeek/Muse 全文在
> session scratchpad(關鍵結論已載本檔),Fable 判官全文見本檔末節連結說明。

## 三方收斂(所有判官一致)

- **全部數字重算通過**:GCD 量子 3,051,520=256×1490×8、±40.7%/+77.9% spread、
  per-flow 五筆誤差、TTL/switch_count——三方各自獨立重算,零分歧。
- **兩個 FAIL 是實錘**:3c 最後一跳歸因缺失(系統性、3 對 host 雙方向)、3h CPU/記憶體
  凍結佔位值。可直接動工不必複驗。
- **PASS 都是窄走廊**:單速率(~20M)、單拓撲、N=3 同形路徑、單故障 N=1、寫入端點全未測。
  報告行文比證據自信一格(「exactly correct」「genuinely trustworthy」)。
- **D4 過度宣稱**:「29 端點 confirmed correct」只驗了 ~8-10 個。
- **頭號補測**(三方排序一致):並發流下的對帳(NTG 59 流 vs veth 計數器)>寫入路徑>
  多速率點>第二種故障型態。

## 各判官獨有貢獻(盲點測試的實際收益)

**DeepSeek**(外族、文本):
- ⭐ 抓到 **IP 整數是 little-endian 重讀**(16777226=0x0100000A),標準 big-endian 下
  等式不成立——報告的「5-tuple correct」證據 as written 是錯的,並暗示 twin 的 IP
  表示 endianness 非標準(與甲類 src_ip 題直接相關)。
- 66-byte 位元組總數不一致(115,762,930 vs 115,762,864)。
- 從 ⌊k·quantum/3⌋ 型態推出 flow 端點可能是 3 秒窗。

**Fable 判官**(同族無記憶、有源碼)——唯一能對源碼查證的,產出最重:
- ⭐⭐ **報告頭號建議的理由被源碼反駁**:`getAvgLinkUsage`
  (TopologyAndFlowMonitor.cpp:2703-2753)排除 host 邊+只平均非零邊 → 3c 缺陷
  **碰不到 get_average_link_usage、傷不到 Energy app**。真受害者=get_graph_data 的
  per-edge 消費者。(Muse 與驗收員都照單接受了原主張——兩個 evidence-only 判官
  共享盲點,正是設三判官要抓的。)
- 3c 機制定位:usage 按取樣 ingress port 記給上游邊(FlowLinkUsageCollector.cpp:
  1763-1791),host 不跑取樣器 → switch→host 邊結構性拿不到 credit。
- 3h 機制:`10+hash(ip)%50`(CPU/記憶體是兩個重複公式的獨立欄位,每 10 秒重算、
  決定性相同——報告猜「同欄位、啟動一次」皆不準,但可觀察主張全對);
  溫度公式 `25+hash%25` 連 modular 對帳都吻合。
- ⭐ **漏掉的發現**:kernel dispatcher 實有 **~40 條 /ndt/ 路徑 vs 手冊宣稱 29**——
  手冊少記了約一打端點,報告的「No discrepancy」反而遮蔽了這件事。
- 8080 一次性失敗 root-cause 為良性(首次 fetch 在 switch kinds 載入前走 Ryu 預設
  port,5s 重試就對了;`:2256`/`:509-521`)。
- 3f 的「59 vs 10=語意差」與報告自己的 t+0 flows=0 矛盾;double-counting 未排除。
- host 側介面編號跨端點不一致(path 記 `(h2,0)`、edge 記 `dst_interface:1`)。

**Muse Spark**(第三票、文本):
- D1-D3 全數降級為 UNDER-EVIDENCED——「手冊沒寫」類主張全是轉述、無手冊原文引用
  (Fable 自己抓了官方站 TOC 把 D1 升回 SUPPORTED,但 Muse 對報告文本的判定成立)。
- 寫入路徑風險的表述最直白:「silent no-op or dangerous actuation」。
- 與 DeepSeek 同捕 66-byte 不一致與 endianness(判為系統自洽但非標準、報告未標注)。

## 對本 repo 的可行動輸出

1. **3c 修復票**(真 bug,機制已定位):最後一跳歸因;修復時以 get_graph_data per-edge
   消費者為受害面敘事,不要寫 Energy app。
2. **3h 處置票**:佔位值要嘛做真要嘛文件明標 synthetic(hash 公式已知)。
3. **NTG banner 修復**(我方 bridge,一行):`ntg_bmv2_topo.py` 的提示改成
   `flow --config <絕對路徑>`(正確語法就寫在同檔 :25 的 header 裡)。
4. **手冊 errata +1**:kernel 實際端點數 ~40 vs 文件 29(隨既有 errata 包投遞)。
5. **src_ip endianness**:併入甲類 src_ip 題的下輪覆核(「維持整數」裁決的前提可能
   要補「而且是 LE 重讀的整數」)。
6. 補測排序照三方共識:並發對帳 > 寫入路徑 > 多速率 > 故障矩陣。

## 與 clone-cap 撤回案的交叉

驗收員 3d 的量子倍數(~6.7 樣本/s=規格)是推翻「clone cap」的第一塊獨立證據;
最終判別實驗與撤回見 `doc/2026-08-15_bmv2-performance-report.md`(`0590e00`)。
一晚之內:無記憶驗收員修正了有記憶 orchestrator 的錯誤結論,有源碼的判官修正了
無源碼判官們的共享盲點——這套分層就是為此而設。
