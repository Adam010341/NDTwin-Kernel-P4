# 交接筆記（2026-07-29 收尾）

[Co-developed with claude code -- Adam]

這份是「還沒歸檔的東西」清單。已經歸檔的請直接看：

| 內容 | 在哪 |
|---|---|
| 各 Phase 進度、Phase 6 入手點 | [p4_bmv2_support_plan.md](p4_bmv2_support_plan.md) 開頭的「目前進度」 |
| 測試流程、實測數據、通過標準 | [p4_status_and_test_guide.md](p4_status_and_test_guide.md) |
| 環境陷阱（sudo、pgrep、清理、順序） | [environment_gotchas.md](environment_gotchas.md) |
| OVS↔P4 的 170 個已接受差異＋原因 | [../tools/contract_test/baseline_diff_allowlist.txt](../tools/contract_test/baseline_diff_allowlist.txt) |
| 每個 bug 的完整分析 | git log（commit message 寫得很詳細，`3acad16`..`02c4913`）|

---

## 下一步：Phase 6

計畫在 `p4_bmv2_support_plan.md`。**先讀那裡的「Phase 6 的具體入手點」**（5 條實測發現）。

核心事實：`GET /ndt/inform_switch_entered` 是**唯一**會把 `isEnabled` 設成 true 的東西，
proxy 完全沒呼叫它。連帶 `path=[]`、速率 0、link usage 0。
**telemetry 資料已經進到 kernel 了，缺的是把它掛到圖上。**

⚠️ **開始 Phase 6 之前**：`EventBus::emit()` 有一個確認過但目前休眠的 deadlock
（持有 `shared_lock` 時同步呼叫 handler）。全專案目前**沒有任何** `registerHandler()` 呼叫，
所以踩不到；但 Phase 6 接第一個 handler 的那一刻它就活了。修法（已討論、未套用）：在持鎖區間內把
handler vector 複製出來、放鎖後再呼叫。

---

## 還沒歸檔 / 未解決的事

### 1. ~~kernel 閒置時燒 100% CPU~~ ✅ 已解決（2026-07-30，commit `d79979e`）

原因是 `FlowLinkUsageCollector::run()` 的 `POLL_TIMEOUT_MS = 0`。**0 的意思是「立刻返回」，不是
「不設逾時」**（`-1` 才是阻塞），所以沒流量時迴圈是 `poll` → `ret==0` → `continue` → `poll`，
純忙等。而它上面的註解寫「poll without timeout」，讓這個錯看起來像刻意的。

| | CPU |
|---|---|
| 修正前 | `run` thread 100.9%、process 101% |
| 修正後 | process **1.7%** |

功能無損：灌 7 個 fixture → `rx=7 app_drop=0 addressed=8`、解析出 5 筆 flow。

**過程中值得記的一點**：我原本懷疑的兩個一秒迴圈
（`calAvgFlowSendingRatesPeriodically` 和 `pingWorker`）實測是 **1.9% 和 ~0%** —— 兩個都很合理
（都每秒印 log、`pingWorker` 還每次深拷貝整張圖 + shell 出去跑 `ovs-vsctl`），但**兩個都猜錯**。
是靠 `/proc/PID/task/*/stat` 的 per-thread 取樣定位的，不是靠讀程式碼。

### 1b. ~~Web GUI 全部節點紅色（`is_up: 0`）~~ ✅ 已解決（2026-07-30，commit `6b3dc0c`）

`pingWorker` 裡兩個**互相獨立**的 bug，任何一個單獨存在都還能撐：

1. `ovs-vsctl list-br` **失敗**和**成功但回報沒有 bridge** 分不出來 —— 兩者都是空 vector，
   迴圈讀成「全部 down」，而且 `pclose` 的 exit status 從來沒檢查。所以**掉一次呼叫就把整個
   fabric 標成死的**。實際看到兩個原因：setsid 起的 process 沒有 controlling terminal 導致 sudo
   要密碼、以及 100 Mbps 灌流量時指令變慢。
2. 那個分支**只會呼叫 `setVertexDown`**。查到 bridge 存在時只印 log 不動圖，所以「down」是永久的
   —— 除非 Ryu 剛好重連並重新宣告該 switch，否則沒有任何東西能把它拉回來。

兩個加起來：**一次抖動就讓整張圖在那一輪之後全黑**。

修法是把判斷抽成有測試的三態 policy（`ovsLivenessFor`），`Unknown` **不動圖** ——
「判斷不出來」不能報成「死了」。失敗的 log 改成 edge-triggered（`FailureRun`）：這個查詢
1 Hz 在跑，每次都印就是當初 3596 行 sudo 錯誤把 log 埋掉的原因。

實機驗證（**故意不開 Ryu**，這樣 `pingWorker` 是唯一能動圖的東西）：

| 動作 | 結果 |
|---|---|
| 沒有 bridge | `up=0/10` |
| 建 s1–s10 | 3 秒內 `up=10/10` |
| `del-br s3` | `up=9/10`，只有 s3 掉（不是整片） |
| `add-br s3` | `up=10/10` —— **這個轉換在修好之前不可能發生** |

**過程中值得記的一點**：第一次實機驗證看到 `up=0/10`，我以為修錯了。真正的原因是**根本沒有
data plane 在跑** —— 下面第 5 節當時寫著「Mininet 還開著」，但那是舊資訊。`pgrep -f
"testbed_topo.py"` 還騙了我一次：它匹配到**我自己的 shell**（`-f` 的老問題，
environment_gotchas 裡記過）。教訓：**信任 live 測試之前先確認環境真的存在**，而且這個文件的
環境狀態一過期就會反過來誤導人。

### 1c. 2026-07-30 手動測試回報的 9 項異常 —— 結案狀態

OVS 模式、`iperf -u -b 100M` 灌流量時觀察到的。分類與處置：

| # | 現象 | 判定 | 處置 |
|---|---|---|---|
| 1 | 鍊路使用率為零 | **不是 bug** —— `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2245`）刻意排除所有接到 host 的邊，而 h1/h2 都在 s1 底下 | 已實測釐清（`6996062`）。**我原本歸咎 Ryu 猝死，那個歸因是錯的** |
| 2 | `src_ip: 16777226` 看起來很怪 | **不是 bug** —— 那是 `in_addr::s_addr`，network order，正是 10.0.0.1 | 文件講清楚（`0e84234`）。**我先前說「文件錯了」是我判斷錯誤** |
| 3 | flow table 是空的 | **不是 bug** —— 實測 10 台各 130 條 | 我給的指令多加了 `?dpid=1`，那個端點是精確比對 target，加參數就 404（`6996062`）|
| 4 | `get_num_of_flows_passing_a_switch` → Not Found | **我給錯指令**，那是 POST + JSON body | — |
| 5 | 資源與電源 output 很怪 | **真 bug**：`power_consumed` 是 [0, 2⁶⁰) 的亂數 = 1.9×10¹⁴ 瓦，而且每次輪詢重骰 | 已修（`0e84234`），30–150 W 且穩定 |
| 6 | 鎖是 Not Found | **我給錯指令** + 合法值沒寫在文件裡 | 文件補上 `routing_lock`/`graph_lock`/`power_lock`（`0e84234`） |
| 7 | install entry 後查詢是空的 | 同 #3，同一個錯指令 | 同上 |
| 8 | ping 100% packet loss | **不是 bug** —— 你在灌 100M UDP，s1-eth3 已過 594 萬封包，ICMP 被餓死是預期的 | 重測請用 `-b 10M` |
| 9 | web-gui 全部節點紅色 | **真 bug**（兩個），見第 1b 節 | 已修（`6b3dc0c`） |

**最終結果：真 bug 只有 2 個**（#5、#9），都修了並實機驗證過。**3 個是我給錯指令**
（#4、#6、以及 #3/#7 共用的那個 `?dpid=1`）。其餘是條件沒滿足，不是壞掉。

⚠️ 我一度把 #1/#3/#7 全部歸咎於「Ryu 在 13:57:00 猝死」。**那個歸因是錯的** —— 真正的原因平凡得多
（流量兩端同一台交換機、以及我給錯指令）。Ryu 確實死過一次而且**死因至今未確定**
（log 突然中斷、沒有 traceback、沒有 OOM 紀錄），那件事本身還沒結案，但它不是這三項的原因。
教訓：看到一個顯眼的故障就把手邊所有症狀掛上去，會蓋掉真正的原因。

### 2. L2 契約還有 6 個 FAIL（全部既有，與 P4 無關）

帶流量的 OVS 迴歸跑到 **30/36**。剩下的：

| 項目 | 原因 |
|---|---|
| `get_graph_data`（254 條 host edge down）| static ARP → Ryu 學不到 host IP → `updateHosts` 跳過 127 台。詳見計畫書 Phase 6 入手點第 1 條 |
| `install_flow_entry__unknown_dpid` → 200 | Phase 2 的 propagation 缺口：kernel **有**正確拒絕並記 WARN，只是 `OpResult` 沒反映到 HTTP status |
| `get_path_switch_count__bad_ip` → 500 | `Invalid IP address` 例外沒接 |
| `inform_switch_entered__bad_dpid` → 500 | `std::stoull` 沒包 try |
| `received_a_simulation_case` ×2 → 202 | 收到爛 JSON 也回 202 |

後三類是同一個模式：**輸入驗證缺口讓例外變成 500**。可以一起修，但會動到共用的 `HttpSession`。

### 3. 刻意延後的技術債

- **shell injection**：每條南向指令都是 `popen("curl … -d '" + json.dump() + "'")`，
  `nlohmann::json::dump()` 不會 escape 單引號，而 JSON 來自未認證的 REST body 和 LLM 輸出。
  3 個檔案共 22 處。**你說過要先跟其他人討論再處理。**
- **P4 parser 沒檢查 IHL**、**分片封包繞過 L4 規則**：Mininet 環境不會觸發，修要動 pipeline。
- **`send_to_cpu` 沒有 rate limiter**：任何 controller-based learning switch 的通病，OVS 那側也一樣。

### 4. 沒驗證成功的東西

- **P4 的 direct counter / per-port counter**：讀不到。`simple_switch_CLI` 需要 `thrift` 的
  Python binding，兩個 interpreter 都沒裝（見 environment_gotchas）。要驗證得先 `pip install thrift`。
- **`P4RoutingStrategy` 實際下規則的完整路徑**：每一段都有單元測試，但 curl → proxy → P4Runtime
  整條沒對活的 switch 跑過。
- **PI 對重複 clone session 回什麼 status code**：`write_clone_session()` 的 `ALREADY_EXISTS` →
  `MODIFY` fallback 從來沒在實機上被觸發驗證過。曾經看到一次失敗但 `details()` 是空字串所以無法判斷
  （已改成連 `code().name` 一起印）。要驗證的話：對活的 switch 連續寫兩次同一個 session。

### 5. 未清理的執行環境狀態

> ⚠️ 這一節**很容易過期**，而過期的環境狀態比沒有還糟 —— 它讓 live 測試的結果無法解讀
> （見第 1b 節的教訓）。改動之後請順手更新，或者直接用下面的指令現場確認，不要相信這裡寫的。

現場確認（2026-07-30 覆核過）：

```bash
pgrep -x ndtwin_kernel; pgrep -x simple_switch_g      # 空 = 沒在跑
#                        ^^^ 只到 15 字元：comm 欄位上限，寫全名永遠匹配不到
pgrep -af "[t]estbed_topo.py"                          # 中括號避免匹配到自己的 shell
sudo ovs-vsctl list-br                                 # 空 = 沒有 OVS bridge
ss -ltn '( sport = 8000 or sport = 8080 or sport = 8081 )'
```

- **2026-07-30 稍晚覆核：整組 OVS stack 正在跑** —— kernel、Ryu、OVS Mininet（10 台 bridge）都在，
  `:8000`/`:8080` 有人聽。我起的 iperf 已全部收掉。
  （這一節在同一天內已經過期兩次了，所以請一律用上面的指令現場確認。）
- 要重新開始測試就照 `doc/p4_status_and_test_guide.md` 走。收尾用
  `sudo mn -c && pkill -x simple_switch_g`（`-x` 而不是 `-f`，而且名稱只到 15 字元）。
- `.test_run/baseline/{ovs,p4}` 兩份基準都是**在正確設定下、有流量時**抓的，可以信任。
  Phase 6 做完之後會產生大量預期差異，屆時 allowlist 裡標了「Phase 6」的項目應該變成 unused
  —— 那正是它們該消失的訊號。
