# NDTwin — 已知未修缺陷

**缺陷清單的普查基準日：2026-08-19**　　涵蓋到 kernel `04b8933`＋分支 `fix/flow-rate-divide-by-zero`

**2026-08-29 增補（只動了兩處，其餘條目仍是 08-19 的普查結果、未重驗）**：
① **§F 新增 `F-bmv2`** —— 08-28/29 四張工單（②封包大小／①＋①b build 比值／③流數）收案後的
實測天花板，並退役 §F 舊的無出處數字；
② **§D 的 F-17 標記為「前提已被推翻、待重裁」**（更正全文在 §C 表下）。

**2026-08-30 對帳（基準 `1208d22`）**：一次**只修衰減、不重排**的普查對帳。
每一條的碼都重新 grep 過，狀態行標了日期與 commit。改動集中在四處：
① **B-2 拆成兩半** —— 隱式代入 `routing_lock` 那一族已修（`4ee086f`＋`87d272f`），
**過期續約與無 owner 兩條原始問題都沒修**，所以拆而不關；
② **B-3 的回覆形狀已變**（`aabe605`，08-20 就修了、清單漏標十天），但**寫入零筆照舊**，
且**兩個分支都回 200 `success`**，看狀態碼的呼叫端仍然分不出來；
③ **§C／§D 的 `F-4` 加了消歧註** —— 08-18 那個目錄裡有**兩套各自編號的 F-n**，
本週 R-5 說「F-4 已修」指的**不是**這裡這一條；
④ **§G 新增 T-4 輪的儀器缺陷區塊**（FINDING-01…05）。
🔴 **本輪沒有跑任何東西**（量測窗開著），所有判斷都是讀碼；標「實測」的一律是引用他人已跑的結果。

🔴 **引用本文件任何舊條目前務必重查現況** —— 實測衰減**不均勻**（見文末〈完整性邊界〉：
agy Tier 1 六條全修、Tier 2 十三條還在十一條）。**清單上寫著的不等於今天還在。**

📌 **已登記的待辦：把整份文件依四張工單重排。**
Adam 2026-08-29 裁定**延後**，理由是當時三個 session 在同一個 worktree 上寫，
大範圍重排的合併風險不成比例。**觸發條件＝poster 定稿。**
本輪交付的是有界版（新增 §F-bmv2 ＋ 退役 §F 舊數字 ＋ F-17 的兩次更正），
**排序軸仍是原本的「示範或正常操作會不會踩到」，沒有改。**

這份文件的排序軸是**「示範或正常操作會不會踩到」**，不是嚴重度。一個會靜默給出錯誤數字
的缺陷可能永遠不會在台上發作，而一個只是外觀問題的缺陷可能第一分鐘就出現。

每一條都標了**失效方向**，這比嚴重度標籤有用：

- **樂觀** = 壞掉時說健康（twin 最危險的方向，因為抓故障就是它存在的理由）
- **悲觀** = 健康時說壞掉
- **靜默** = 兩邊都沒有記錄

證據檔在 `doc/audit/<日期>_<主題>/`。標「實測」的是跑出來的，標「讀碼」的是推論。

---

## A. 正常操作就會發作 —— 示範前務必知道

### A-1 🔴 關機後馬上開機 = 回報成功但什麼都沒做

- **狀態**：~~報告前不改碼，用操作繞過（2026-08-19 裁定）~~ ⇒ 2026-08-30 Adam 改裁「修」⇒
  **修法已落（`98e890a`，2026-08-31 併入）並過變異閘**（A-1 五顆全殺、對照顆 13 輪全綠、46/46）。
  **live 配方 2026-08-31 已跑**（`2026-08-31_live-recipes/`）：arm1 窗內 power-on **PASS**
  （2.160 s、count 9→10、kernel.log 有真實 `switch s1 -> on` 行——不是 0.01 s 假成功）、
  arm2 sleep-20 對照 **PASS**（3.046 s；第一輪誤判是取樣太早的儀器假象，隔離重跑正名）；
  ⚠️ arm3（I1/I5 重複 power-on）**INCONCLUSIVE**——量測當下交換機是關的，而不變式是關於
  開著的交換機，觀測不具鑑別力；連同 ping 子句排入 F-5 新輪重跑。**arm3 綠前不改 RESOLVED。**
  （原配方三缺陷已更正入 §5：port 8081→8000、`switch_ip`→`ip`、pgrep 15 字元截斷儀器。）
  落地前 15 秒繞法仍有效於未帶此修的 build。
  **本條在該檔 §4 的變異測試跑綠之前不得改標 RESOLVED**（A-3 就是修好後被掛 OPEN 八天的反例）
- **平面**：P4
- **失效方向**：樂觀 ＋ 靜默
- **會發生什麼**：`POST /ndt/set_switches_power_state?action=on` 回 **200 `{"Success"}`、0.01 秒**，
  bmv2 行程數不動、沒有 readopt、交換機**永久維持死亡**。同時 `power=ON`、`is_up=True`、
  8/8 邊 up、**100% 封包遺失**。
- **機制**：`powerOff` 標 vertex down → 約 1 秒後 1 Hz liveness worker 在死掉的交換機上把它
  **翻回 up**（`p4LivenessFor` 對 2 秒內的舊 `probe_ok` 回 Up，之後在 LLDP beacon 未超過
  `kLldpFreshSeconds = 12` 前回 Unknown）→ `P4PowerStrategy::powerOn:45-50` 第一行：
  ```cpp
  if (topoMonitor->getVertexIsUp(node))
  {
      // Already up: nothing to do, and reporting success is accurate.
      return OpResult::success();
  }
  ```
  那句「reporting success is accurate」在 vertex 說謊時不成立。檔案自己的註解預測過這會發生在
  **重試**上；實際上**第一次呼叫**就會。
- **窗口**：關機後約 **10 秒**
- **🔑 繞法（零成本）**：**關機後等 15 秒再開機**，或先確認 `get_graph_data` 的
  `is_up=false` 再送 `action=on`
- **為什麼排第一**：人手動示範「關掉再打開」就是幾秒內完成，**正好落在窗口裡**，
  而電源管理是 Phase 7 的招牌功能
- **證據**：實測，`scratch/phase2/FINDINGS.md` E2。用有鑑別力的第二次呼叫證明——
  graph 沉澱到 `is_up=false` 後送**完全相同**的 POST，花 1.27 秒、行程 9→10、轉發全復原

### A-2 🔴 topology poll 可以永久阻塞，而且沒有任何東西會發現

- **狀態**：**kernel 側修法已落（`687de6c`）、過變異閘（2026-08-31：A-2 五顆全殺、46/46），
  且 §5.3 live 已於 2026-08-31 15:21–15:25 跑過並通過**——
  三個 curl 加 `--connect-timeout 2 --max-time 5`（兩旗標對兩種實測故障：131 秒 IPv6 黑洞
  與 Ryu wedge）、`-s`→`-sS`、每輪一行邊沿觸發 WARN＋恢復 INFO。
  - **live 量到的**（binary `build/bin/ndtwin_kernel` sha256 `e3bad23c…f1b94`／md5
    `5f2e701e…a858`，`strings` 驗出兩條修法字串各 1 次，**無 RUNPATH**⇒走預設載入路徑；
    fabric＝`ndt up ovs4`）：`iptables -I INPUT -p tcp --dport 8080 -j DROP` 期間
    **四個 poll pass 只發一行 WARN**，elapsed **6.024s**（有界，不是 733 秒），
    kernel 執行緒數不變、行程續活；拆掉規則後**恰好一行**
    `topology poll answered again after 4 silent pass(es), in 0.628s`。
    「四個 pass」有兩個互相獨立的證人：`/proc` 掃 curl 子行程（t≈4/40/76/112s）
    與恢復行自己的計數器——**少了前者，「只發一行」與「執行緒死在第一輪」分不開**。
    `-sS` 也驗到了：`curl: (28) Failed to connect to localhost port 8080 after 2001 ms`
    進了 log。raw＝`doc/audit/2026-08-31_live-recipes/raw/{drive_a2_wedge.sh,a2_wedge.log,
    a2_kernel.log}`。
  - 🔴 **明列未覆蓋範圍（三項，不要讀成「A-2 已修」）**：
    1. **`--max-time 5` 那一支未經 live**。iptables DROP 丟的是 SYN ⇒ 永遠走
       `--connect-timeout`；要打到 `--max-time` 需要「accept 之後不回」的 controller，
       授權的那條規則做不出來。目前**只有單元變異閘 M10**。
       ⇒ 補法**不需要 sudo**：停掉 Ryu，用十行 python listener 佔住 `:8080`、accept 後不寫。
       配方＝`doc/audit/2026-08-31_live-recipes/rider_a2-max-time.md`，**掛在下一個 fabric 窗**。
    2. 🔴 **Ryu 那端的成因沒有被移除——但本項原本指的檔案、行號、函式全部不對，
       2026-09-02 重寫**（原文：「`intelligent_router.py:304` 的 `get_link()` 仍會永久阻塞，
       兄弟 `get_switch`（`:284-288`）有 20 秒有界重試，它沒有」）。三件事：
       - **`intelligent_router.py` 的 `get_link` 早就有界了，而且比本條被寫下來還早六天。**
         `cce9c5db`（2026-08-25，是 `687de6c`（08-31）與 `4cbec52d` 的共同祖先）把兩個讀都包進
         `_bounded_topo_read`（`:878-907`，`hub.Timeout`＋WARN＋`return None`）：
         `get_switch` 在 `:978-980`、`get_link` 在 **`:1007-1009`**，上限
         `TOPO_QUERY_TIMEOUT_S=5`／`TOPO_DEADLINE_S=20`（`:227-228`），
         逾時走 `:1010` 起的 abort 分支，整個 rebuild 也移出 event loop（`_topology_worker`，`:944-966`）。
         ⇒ **「兄弟有界、它沒有」在寫下的當天就已經是假的**。原文引的 `:284-288`／`:304`
         在 `4cbec52d` 是 **SIGUSR2 greenlet dump 的註解**（`:304` 是 `import gc`），差約 700 行。
         🔑 **教訓：引行號會腐爛，引函式名＋commit。**〔實測，本文以 `git show 4cbec52d:` 逐行覆核〕
       - 🔴 **而且那個函式從來就不在 kernel 的 poll 路徑上。**
         kernel 打的 `/v1.0/topology/{switches,hosts,links}` 由 **stock `ryu.app.rest_topology`** 提供
         （`tools/test_workflow/stack.sh:719-720` 的啟動列與 `:706-708` 的註解都明載），
         `intelligent_router.py` 只服務 `/ryu_server/all_destination_paths`。
         ⇒ **這正好解釋本條自己記到的那個現象**（見下方機制節）：「三個 topology 端點全 000、
         **同一個行程**的 `all_destination_paths` 0.2 ms 回答」——**本來就是兩個 app，一點都不矛盾。**〔親自讀過〕
       - **真正還沒動的無界讀在 stock 套件裡**（ryu 4.34，不在本 repo）：
         `ryu/app/rest_topology.py:97-103`／`:105-111`／`:113-119` 三個 handler 直接呼叫
         `get_switch`／`get_link`／`get_host`，經 `ryu/topology/api.py:29-31` 走到
         `ryu/base/app_manager.py:279` 的 `req.reply_q.get()`，**無 timeout**。
         WSGI greenlet 停在寫出任何位元組**之前** ⇒ accept-then-stall ⇒ HTTP 000。
         ⇒ **真實世界那次打到的是 `--max-time`，不是 `--connect-timeout`**（與 item 1 相關）。〔親自讀過〕
       ⇒ **結論方向不變**：kernel 側的修法只讓症狀有界並發聲，**並沒有移除成因**；
       只是要修的是 stock 套件那三個 handler，不是 `intelligent_router.py`。
       - 🔄 **落地方式已裁（Adam，2026-09-02 19:0x）：把有界的副本 vendor 進 repo，
         `stack.sh` 改載入自家那份，不再依賴 stock 套件。**
         路徑定為 **`tools/ryu_apps/rest_topology_bounded.py`**；三個 handler 各包
         `hub.Timeout(3s)`，逾時回 **HTTP 503 ＋空 body**。
         🔑 **body 必須是空的**：`utils::execCommand` 是裸 `popen`、只收 stdout、**丟掉 exit status**
         ⇒ HTTP status code **根本到不了 kernel**；5xx 帶 body 會被判成「答了」並丟進 `json::parse`
         ——**比 wedge 更糟**。3 秒必須 < kernel 的 `--max-time 5`：**先放棄的那一邊才有機會解釋。**
         ⚠️ **vendor 的理由不是偏好**：stock 套件檔**重裝就還原、clone 也拿不到**，
         修在那裡等於修在一個不受版控的地方。
       - 🔴 **live 載入尚未驗，本條因此不關**：要改的那一行是
         `tools/test_workflow/stack.sh:720`（現在是 `… '$RYU_APP' ryu.app.rest_topology ryu.app.ofctl_rest`）。
         **`tools/ryu_apps/` 在寫下本行時 trunk 上還不存在**（vendoring 由 A-2 分支做，整合後才會出現）
         ⇒ **「Ryu 真的載入的是我們那份」需要一次 `ndt up ovs4` 才成立**，已進**待 live 驗證佇列**。
         🔑 **這正是本文件反覆記的形狀**：碼在 repo 裡 ≠ 跑起來的行程載入的是它。
    3. 🟢 **「部分套用」已裁決並落地（2026-09-02，`05edac65`；變異閘 9/9 全殺、整合樹 build 0 error、**ctest 870/870**）：
       維持套用拿到的那一半，但要說出來。**
       **刻意不改成 all-or-nothing**，三條理由：①三個寫入者只寫 `true` 從不寫 `false`（見下）
       ⇒ 部分套用製造不出「down」；②本條的失效方向是悲觀＋靜默，而丟掉已經拿到的那一半
       是**再往悲觀推一步**；③沒有 transaction 可以 roll back——`updateSwitches` 早就在
       `m_graphMutex` 底下改完圖了，真原子性要 shadow graph ＋ swap。
       **改的是可觀測性**：一輪被分類成 `Complete`／`Partial`／`Silent`（初值 `NotYetPolled`），
       `lastPollRoundKind()` 可讀，轉為 partial 時邊沿觸發**一行**帶穩定 token
       **`topology-round-partial`** 的 WARN。
       🔴 **一顆 declared survivor 要另外收**：「`pollControlPlaneTopology` 有沒有真的呼叫新記帳」
       不在變異射程內（呼叫點夾在三個 live curl 之間）⇒ 收法是只 stall **一個**端點，
       `grep -c 'topology-round-partial' kernel.log` 期望**恰好 1**。**進待 live 驗證佇列。**
       〔原狀態：未處理——「一輪裡 switches 有回答而 links 沒有，仍然會把拿到的那半套上去
       （三個 update 各自對空 body 早退）；這是修法前就有的行為，`687de6c` 刻意沒改」〕
       📌 **敘述正確，但漏了一件會讓結論翻面的事（2026-09-02 補）**：
       **這三個寫入者是嚴格單調向上的。** `updateSwitches`（`:588`）／`updateHosts`（`:675`）／
       `updateLinks`（`:838`）只寫 `= true`（`:639-640`／`:721-722`／`:761-762`／`:801-802`／`:936-937`），
       整個檔案沒有 `remove_edge`／`remove_vertex`／`clear_vertex`；`= false` 只出現在
       ①靜態載入的初始化（`:243-244`／`:318-319`）②明確 setter（`:1817`／`:1825`／`:1866`／`:1873`／
       `:2334`／`:2384`／`:2411`／`:2421`），**poll 一條都不走**。
       ⇒ **一輪部分套用不可能製造出一個「down」，它只可能「沒能把某個 down 抬起來」。**
       ⇒ 所以「改成 all-or-nothing」是**往悲觀再推一步**：實測的 wedge 正是
       「`/links` 卡而 `/switches` 健康」，丟掉 switches 那半會讓 twin **永遠不再學到任何交換機是活的**。〔親自讀過〕
       🔴 **而且 `""` 與 `[]` 必須保持是兩種不同的答案**：`utils::execCommand` 丟掉 exit status，
       逾時給 `""`、真的沒有 link 給 `"[]"`（兩個位元組），**而 OVS 每次開機在 LLDP 完成前都回 `[]`**。
       三個早退的判準是 `empty()`（`:591`／`:678`／`:841`），**不是「沒有元素」**——
       把它收緊成後者就是一台假警報產生器。〔親自讀過〕
  ⇒ **本條不是 RESOLVED，也不是「kernel 側已修」四個字就能結案**：
  live 成立的只有「三個 curl 會結束」與「結束不了會說出來」這兩件事。配方＝
  `doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md` §5.3（該節的
  「elapsed ~15s」判準已於本輪更正為 ~6s——**原判準會讓一個正常運作的修法被判 FAIL**，
  屬 **A-8** 那一族；判準要跟著故障注入手法走，換注入就要重推期望值）。
  〔修前存證（2026-08-30 ledger 讀碼重驗於 `1208d22`）：`include/utils/Utils.hpp:543-568`
  裸 `popen()` 無 timeout、三個 curl（`TopologyAndFlowMonitor.cpp:472/485/498`）無
  `--max-time`；且已收窄＝那三個是 kernel 僅存的無界 curl，其餘南向全有界
  （`HttpRoutingStrategyBase.cpp:82`、`FlowLinkUsageCollector.cpp:2496`、
  `DeviceConfigurationAndPowerManager.cpp:820/835/848`、`P4PowerStrategy.cpp:82`）〕
- **平面**：OVS（機制在 kernel，P4 走不同路徑）
- **失效方向**：悲觀 ＋ 靜默（**零 log**）
- **會發生什麼**：twin 顯示**全部 40 條 link down、10 台交換機 `enabled=false`**，
  而 fabric 一路正常轉發（0% 遺失）。**不重啟永遠不會恢復。**
- **機制**：`pollControlPlaneTopology` 經 `utils::execCommand`
  （`include/utils/Utils.hpp:543-568`）呼叫 curl——**裸 `popen()` 沒有 timeout，
  curl 也沒有 `--max-time`**。一個沒反應的 controller 就能讓那條執行緒死到行程結束：
  沒有重試、沒有 watchdog、**一行 log 都沒有**。
  實測抓到一個 curl 子行程**活了 733 秒**，跟 kernel 同一秒啟動，是它嘗試的第一次 poll。
  兄弟路徑 `fetchOpenFlowTablesInternal` 有 0.5 秒的可疑門檻並會警告；這條什麼都沒有。
- **Ryu 那端**（🔄 **2026-09-02 更正，原文指錯檔案**——原文寫的是
  「`intelligent_router.py:304` 的 `get_link()` 永久阻塞，兄弟 `get_switch`（`:284-288`）有 20 秒有界重試」，
  **那兩個行號在 `4cbec52d` 是 SIGUSR2 greenlet dump 的註解，而該檔的兩個讀 `cce9c5db`（08-25）就都綁好了**；
  詳見上方狀態行 item 2）：
  無界的是 **stock `ryu.app.rest_topology`** 的三個 handler
  （`ryu/app/rest_topology.py:97-119` → `ryu/topology/api.py:29-31` →
  `ryu/base/app_manager.py:279` 的 `req.reply_q.get()`，無 timeout），
  而那才是 kernel 打的 `/v1.0/topology/*`（`tools/test_workflow/stack.sh:719-720`）。
  三個 `/v1.0/topology/*` 全回 HTTP 000，而**同一個行程**的
  `/ryu_server/all_destination_paths` 在 0.2 ms 內回答——
  🔑 **原文把這當成「Ryu 還活著不能當證據」的反直覺現象，其實它有更平凡的解釋：
  那是兩個不同的 app，一個卡住另一個不卡本來就正常。**
  「『Ryu 還活著』不能當證據」這個結論仍然成立，只是理由換了。〔親自讀過〕
- **指紋**：`up=true, enabled=false` 在實務上就是「liveness 跑了、poll 沒跑」的指紋。
  ⚠️ **但機制敘述要精確**：`isEnabled` 有**三個**寫入者，不是一個——
  ① topology poll（`TopologyAndFlowMonitor.cpp:566/648/688/728/863` 設 true）
  ② `inform_switch_entered` 經 `setVertexEnable()`（`HttpSession.cpp:1173`）
  ③ 1 Hz liveness worker 在 ping 不通時 `setVertexDisable()`
  （`DeviceConfigurationAndPowerManager.cpp:694-695`）
  所以這個指紋成立需要**兩個條件同時滿足**：poll 卡住**而且** `inform_switch_entered` 也沒送到。
  觀察到的那次兩者都成立（Ryu wedge 了所以它也沒推），結論沒錯但推導不完整。
  最初的「poll 是唯一寫入者」是 `grep 'isEnabled = '` 漏掉 setter 造成的
  （見 memory `grep-endpoints-misses-concatenation`）。
- **🔑 繞法（一行檢查，建議寫進 runbook）**：
  ```bash
  curl -s -o /dev/null --max-time 3 -w '%{http_code}\n' http://localhost:8080/v1.0/topology/switches
  ```
  回 `000` 就是卡住了，**而且 kernel 必須在 Ryu 之後重啟**
- **證據**：實測，`scratch/phase2/FINDINGS.md` PRIORITY 節。Adam 自己在 Visualizer 看到
  `enable: no, status: up` 而觸發的調查

### A-3 流量停止後 top-k 還在報舊速率約 15 秒

- **狀態**：🟢 **RESOLVED（2026-08-20，`aabe605`）。2026-08-28 讀碼確認並更正本條目。**
  這個條目在修好之後仍被標成 OPEN 過 8 天，期間還被編輯過，**沒有人回頭改狀態**。
- **平面**：兩者
- **失效方向**（當時）：樂觀（顯示不存在的負載）
- **曾經發生什麼**：iperf3 結束後 5 秒、10 秒，top-k 還在送**位元完全相同**的
  20.3 Mbps / 10496 pps，同一個物件裡的 `_in_the_last_sec` 卻是 `0`
- **機制**：`31b357a6`（2026-07-27）的除零守衛改成 `continue` 而**沒有清除**，
  於是 `estimated_*_in_the_proceeding_1sec_timeslot` 沿用舊值；
  `getTopKFlowInfoJson` 正好用那個欄位排序（現行 `FlowLinkUsageCollector.cpp:2339-2344`）。
- **修法**：`aabe605` 把清除加回來（現行 `:1911-1913`），並在原地留下為什麼的說明：
  ```cpp
  if (!rates.hasActiveHops)
  {
      // ... the divide-by-zero is already prevented by `hasActiveHops` itself, and
      // writing 0 divides by nothing. What to report *after* the guard was a separate
      // choice, and carrying the old value forward was the wrong one.
      info.estimatedFlowSendingRatePeriodically = 0;
      info.estimatedPacketSendingRatePeriodically = 0;
      info.isElephantFlowPeriodically = false;
      continue;
  }
  ```
- 🔴 **分支歸屬更正（2026-08-28）。** 本條目原本被引用來支持
  「**baseline 保留陳舊速率、本分支歸零**」——**那是反的**。
  `origin/main` 的對應處一直都清除，逐字為：
  ```cpp
  if (hopsCounter == 0)
  {
      // No active hop in this interval, so explicitly clear periodic rates.
      info.estimatedFlowSendingRatePeriodically = 0;
      info.estimatedPacketSendingRatePeriodically = 0;
      continue;
  }
  ```
  （`git show origin/main:src/ndt_core/collection/FlowLinkUsageCollector.cpp` 的 1453-1459 行）
  且兩邊的判準等價：`computeEstimatedRates` 在 `hopsCounter <= 0` 時回
  `hasActiveHops == false`（`include/common_types/SFlowType.hpp:446-449`）。
  ⇒ **保留是本分支自己引入、又自己修掉的，從來不是 baseline 的性質。**
  受影響的下游見 `doc/audit/2026-08-27_flow-table-idle-tail/NEXT.md` 的更正段。
- ⚠️ **仍然開著的殘留屬於 B-x，不屬於這裡**：修好之後死流的速率是 **0**，
  但那條流**還是會被列出來 15 秒**。「報舊速率」已修，「還在名單上」沒修。
- 📌 本條目原先引的行號 `:1773-1778`／`:2167-2172` 實際指向 rate-loop 的除錯日誌與
  immediate 路徑的 elephant 旗標，**都不是它描述的東西**。行號會腐爛，引用前要重查。
- **證據**：當時實測 `scratch/phase2/FINDINGS.md` E9；本次更正為讀碼，未重跑

### A-4 OVS 4-host cell 完全沒有遙測

- **狀態**：OPEN（**環境／拓撲問題，不是 kernel 缺陷**）
- **平面**：OVS，**只有 4-host cell**
- **失效方向**：靜默（0 與「閒置」無法區分）
- **會發生什麼**：實測 50.00 Mbps 負載下，`get_detected_flow_data` 回 `[]`、
  所有邊 `link_bandwidth_usage_bps = 0`、`get_average_link_usage` 回 `0.0`
  且 `"status":"success"`。同一顆 kernel 在 P4 上報 2 條流、55.8 Mbps。
- **機制**：`tools/test_workflow/ovs_4host_topo.py`（178 行，全讀過）**沒有任何 sFlow 設定**。
  兩個平面的遙測都只從 UDP 6343 的 sFlow datagram 來。
- **⚠️ 128-host 拓撲有設定**（`testbed_topo.py` 的 `enable_sflow`），實測正常——
  見 `doc/audit/2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md`
- **🔑 繞法**：**示範遙測一律用 128-host 拓撲**
- **證據**：實測，`scratch/phase2/FINDINGS.md` E7A/E7B

#### A-4b ⚠️ 推論：Energy-Saving-App 在這座 cell 上會把交換機關光且不會恢復

**這是讀碼推論，尚未實測**——E10 被環境擋住（`/mnt/nfs/app` 不是掛載點、app binary 沒建），
所以沒有人真的跑過。但如果要在 4-host cell 上示範節能，這條必須先驗證。

決策路徑（`Energy-Saving-App/src/app/energy_saving_app.cpp:911-928`）：

```cpp
std::optional<double> avgLinkUtilization = group_avg_link_utilization(g, group);
if(!avgLinkUtilization.has_value()){ continue; }        // 群組裡沒有 up+enabled 的邊 → 不動
if(*avgLinkUtilization <= LOW_WATER_MARK){              // 0.40
    easy_disable_switch(g, json2sim, group);
}else if(*avgLinkUtilization >= HIGH_WATER_MARK){       // 0.60
    easy_enable_switch(g, json2sim, group);
}
```

`nullopt` 的條件是**邊的狀態**，不是流量為零。4-host cell 上邊是 up+enabled 的（40/40），
所以函式回傳 **0.0** 而不是 nullopt → `0.0 <= 0.40` 成立 → **關機觸發**。
而利用率永遠碰不到 0.60（完全沒有遙測），所以**永遠不會再開回來**。

**預期行為是單調關機直到沒得關，不是「不動作」。**

⚠️ **不要把這條跟 F-17 混為一談**：F-17 是 kernel 端 `get_average_link_usage`
只平均忙碌鏈路；這條走的是 app 自己的 `group_avg_link_utilization`，從 graph 資料算，
兩者是不同的函式。🔑 **2026-08-29 確認這個區分不只是形式上的**：F-17 那個端點
**在 ESA 裡零呼叫端**，所以它根本碰不到這條決策路徑（見 §C 的 F-17 二次更正）。
**A-4b 從來不依賴 F-17，而它才是真的關機風險。**

#### 🔴 A-4b 的機制已從實作確認（2026-08-29，讀碼，未實跑）

`group_avg_link_utilization`（`Energy-Saving-App/src/common/types.cpp:396`）：

| 行 | 做什麼 | 為什麼要命 |
|---|---|---|
| `:410` | `if (g[*ei].isUp == true && g[*ei].isEnabled == true)` | **分母收「所有 up+enabled 的邊」，完全不篩忙碌** ——**與 kernel 的 `getAvgLinkUsage` 正好相反** |
| `:412-413` | `utilizationSum += …; edgeCount++;` | 沒流量的邊貢獻 0 到分子、貢獻 1 到分母 |
| `:423-425` | `if (edgeCount == 0) return std::nullopt;` | **只有「一條 up+enabled 的邊都沒有」才回 `nullopt`** |
| `:427` | `return utilizationSum / (edgeCount * 100.0);` | 邊活著但沒流量 ⇒ **回 `0.0`，不是 `nullopt`** |

⇒ `0.0 <= LOW_WATER_MARK`（**0.40**，`Energy-Saving-App/include/app/settings.hpp:7`）⇒ **關機**，
而利用率永遠碰不到 `HIGH_WATER_MARK`（**0.6**，同檔 `:6`）⇒ **不會再開回來**。

📎 **哪些既有程序會製造這個條件**：三份操作手冊都提醒「同一台交換機底下的 host 互打，
`get_average_link_usage` 永遠是 0.0」——**那個網路狀態（交換機間邊都活著但沒有流量）
正好就是本條的觸發條件**。⚠️ **但那三份手冊都不啟動 Energy-Saving-App**
（2026-08-29 實查：兩份零次提及、OVS 那份唯一一次在講別的端點），
所以**對照著那些手冊操作不會發作**；會發作的是**把同樣的網路狀態帶到 ESA 有在跑的環境**。
手冊：`doc/2026-07-30_full_test_runbook.md` §1d（完整版）、
`doc/2026-07-29_p4_status_and_test_guide.md`、`doc/2026-08-10_ovs_manual_test_runbook.md`。

📌 那個 `!has_value()` 分支的註解記著一個**已修**的除零：邊數為 0 時算出 `inf`，
而 `inf >= HIGH_WATER_MARK` 會把整組**開回來**。同一個地方已經踩過一次。

### A-4c 🔴 P4 proxy 重啟會靜默摧毀 bring-up 以來安裝的每一條規則

- **狀態**：**OPEN。** ⏳ **待 live 驗證佇列**：誠實改動 (a) 已實作在 `fix/a4c-proxy-restart-honesty`
  （`05976e27`，75 tests 綠／倒回四個 proxy 產品檔即 rc=1 errors=21，auditor 重跑），
  但 🔴 **新欄位（`boot_id`＋per-switch `table_generation`）目前沒有任何 kernel 讀者——有寫者沒讀者**
  ⇒ **接線之前不算修**（[[existence-is-not-wiring]]）。回填那一半也還沒做。
- **平面**：P4
- **失效方向**：樂觀 ＋ **零警告**
- **會發生什麼**：重啟 P4 proxy（**bmv2 沒有重啟**）之後，bring-up 以來安裝的**每一條規則都消失**，
  而 twin 回報**完整健康恢復**：40/40 邊、10/10 up、**一行警告都沒有**
- **為什麼排在 A 節**：不需要注入任何故障。**重啟 proxy 是正常運維動作**——除錯、改設定、
  升級都會做。而且 twin 事後看起來完全正常，所以沒有人會知道規則不見了
- **驗證方式**：用 P4Runtime 直接讀真實交換機表比對，不是看 kernel 快取
- 📌 **機制與觸發面補正（2026-09-02 fix-design 對帳，讀於 `4cbec52d`）**——原文的結論不變，
  但**三句話要改**：
  - **那把刀是 `set_forwarding_pipeline_config()`**：重啟時對每一台**無條件**呼叫
    （`p4_proxy/proxy_agent/main.py:197`，迴圈在 `:193-201`），語意是 `VERIFY_AND_COMMIT`
    ⇒ 清空所有表。不是 bmv2 重啟造成的。〔親自讀過〕
  - 🔴 **「每一條都消失」要加限定**：bring-up 形狀的 LPM 規則會被 `install_initial_routes`
    重算回來，**所以事後數規則條數看起來不像全滅**；永久消失的是「bring-up 以來的 delta」
    ——app 的改寫、app 的刪除、**以及全部的 5-tuple 規則**。〔親自讀過〕
  - 🔴 **同一條摧毀路徑不需要重啟 proxy**：`POST /p4/readopt/{dpid}` 會清掉那一台。
    **原文的觸發條件寫窄了。**〔親自讀過〕
  - **「一行警告都沒有」的原因比原文寫的更難修**：不是警告被吞掉，是 **kernel 沒有任何 intent store**
    ——沒有可以拿來比對的意圖存底。而 `Classifier::updateFromQueriedTables`
    （`src/ndt_core/collection/Classifier.cpp:1333`）對「switch 不在陣列裡」是**不 bump epoch、不掃、不動**
    ⇒ **缺席的交換機的舊規則無限期存活，且讀取時分辨不出陳舊與新鮮**（只有 epoch、沒有 timestamp）。
    這是刻意的保守設計（Ryu wedge 情境下是對的），**在 proxy 重啟情境下剛好完全相反**。〔親自讀過〕
- **證據**：實測，`scratch/round4/FINDINGS-round4.md` 實驗 4「Bug D」；
  上面那組機制補正＝2026-09-02 讀碼（`4cbec52d`），Python 契約測試 75 顆綠／倒回四個
  `proxy_agent` 產品檔即 rc=1、errors=21〔實測，auditor 重跑〕，**C++ 側未編譯**

### A-4d 🔴 P4 上「裝一條規則然後刪掉」會把目的地打成黑洞

- **狀態**：**OPEN。** ⏳ **待 live 驗證佇列**：修法在 `fix/a-4d-delete-restores-p4-route`
  （`a1a4a295`），Python 變異閘由 auditor 重跑（HEAD 綠 rc=0／倒回 `topology_manager.py` 即 rc=1、
  6 顆中 3 紅 3 控制組綠）。**C++ 無改動。**
  🔴 **缺的是 live**：§6.2 的配方（含三組負控制）要證明「裝一條再刪掉之後，表上還在而且回到 P0」——
  **這條的判準必須讀真表，不是讀 kernel 快取。**
- **平面**：P4（**OVS 上同樣兩個呼叫是安全的**）
- **失效方向**：災難性但**吵**（ping 100% loss，看得出來）
- **會發生什麼**：`install_flow_entry` 然後 `delete_flow_entry` 同一條 → **目的地完全不通**。
  實測 tx 計數器：裝上後 100% 流量移到新埠，刪掉後 **0 MB、ping 100% 遺失**
- **機制**：`ipv4_lpm` **每個 prefix 只有一筆**，所以 install **覆寫**了控制面的路由，
  delete 又把它撤掉——原本的路由沒有回來。proxy 自己的註解
  講了「每個 prefix 一筆」這個前提，**但漏了這個後果**
- 📌 **行號更正（2026-08-30，`1208d22`）**：原文引的 `api_routes.py:190-204`
  **現在指向不相干的碼**（`_flowentry_body` 的 JSON 解碼守衛）。
  那段前提註解已移到 **`api_routes.py:253-255`**；delete 路徑在
  `topology_manager.py:813-821`（刪完 `pop` 掉紀錄就結束，**沒有任何還原邏輯**），
  而 `topology_manager.py:683-685` 的 docstring 現在明寫了
  「OVS 是 priority 100 疊在 10 上、這裡是取代該目的地唯一的一筆」——**前提寫得更清楚了，後果仍然沒寫**。
  ⇒ **機制與結論不變，只有引用位置要換。**
  🔴 **又漂了（2026-09-02，`4cbec52d`）**：現行正確位置是——前提註解在
  `topology_manager.py:806-810`（`route_flow` docstring）、`api_routes.py:249-257`
  （`delete_flow_entry` docstring）；delete 路徑在 `topology_manager.py:910-955`，
  `pop` 在 `:954`。〔親自讀過〕
- 📌 **機制補正三點（2026-09-02 fix-design 對帳）**：
  - **「install 覆寫控制面路由」是怎麼發生的**：install 與 delete 寫**同一個 `dst/32` LPM key**，
    而 P4Runtime 的 INSERT 對既有 key 是**失敗不是覆寫**——是 `p4_client.py:855-857` 的
    **MODIFY 回退**把控制面那一筆蓋掉的。原文只寫了結果，沒寫這一步。〔親自讀過〕
  - 🔴 **default action 是 `send_to_cpu()` 不是 `drop()`**：黑洞掉的流量**全部灌進 CPU port**。
    這在 bmv2 上有代價（見 §F-bmv2 的天花板與 CPU 路徑），**原文沒提**。〔親自讀過〕
  - ⚠️ **失效方向要收窄成「只有資料面吵，控制面是啞的」**：ping 100% loss 看得見，
    但 proxy 的 `unroute_flow` 回 `True`、REST 回 `{"status":"success"}`，
    而 `_installed_routes` 被 `pop` 之後 twin 也不再宣稱有這條路由
    ⇒ **twin 不說謊，但也不會有任何警告**。「吵」是網路吵，不是系統吵。〔親自讀過〕
- ⚠️ **相鄰缺陷（讀碼發現，無實測、不在原始回報範圍）**：install 走 5-tuple、delete 只送 `nw_dst`
  時，delete 會落到 `else` 分支去刪掉 `ipv4_lpm` 那筆它從沒裝過的控制面路由，
  而 5-tuple 規則原封留著 ⇒ **黑洞更難查（表上還有一筆規則在）**。
  分支條件 `needs_five_tuple`（`topology_manager.py:331-341`），install 在 `:869`、delete 在 `:936`。〔讀碼推論〕
- **🔑 為什麼排在 A 節**：**一個會自己清理的 app 就會觸發它。** TE app 遷移完流量後刪掉
  自己的規則是完全正常的行為
- 📌 **同一條 P4 install 路徑上的另一個缺陷見 §A-4g**（`BLOCK_HOST` 根本沒裝上卻回 success）
  ——本條講「裝上又刪掉之後黑洞」，那條講「從來沒裝上」。
- **證據**：實測雙平面對照，`scratch/round6/FINDINGS-round6.md`；
  上面的機制補正＝2026-09-02 讀碼（`4cbec52d`），修法分支的 Python 變異閘由 auditor 重跑
  （HEAD 綠 rc=0；倒回 `proxy_agent/topology_manager.py` 即 red rc=1、6 顆中 3 紅 3 控制組綠）〔實測，auditor 重跑〕

### A-4e 🟢 `modify_flow_entry` 忽略 `priority`，會改到別人的規則而且傷害存活（已修）

- **狀態**：🟢 **RESOLVED（2026-08-31）**——修法 `c46c51e`＋變異閘（四顆全殺、46/46）＋
  **live 雙驗**：§3.3 阻斷檢查對活 Ryu 回 **200**（路由存在，07-29 指南清單過時）；§5.2 讀回
  真表＝prio-100 規則 `OUTPUT:1→3` 而 prio-10 規則**原封**（`duration_sec` 連續 8.0→16.0，
  被重寫會歸零——正是「同一筆、counters 沒動」那把尺）。
- **平面**：兩者共用同一份 C++（🔄 08-30 更正：`P4RoutingStrategy` 沒有 override `modifyAnEntry`，
  分岔在 proxy 端只服務 `modify`——修法因此帶 `strictModifyPath()` override 保 P4 不變 404）
  ⚠️ **08-30 讀碼更正：「P4 走不同路徑」只在 proxy 那一端成立。**
  `P4RoutingStrategy` **沒有** override `modifyAnEntry`，所以 **C++ 這一段兩個平面共用同一份碼**；
  分岔點在 proxy——它自己會從 body 讀 `priority`（`topology_manager.py` `modify_flow`），
  而且**只服務 `/stats/flowentry/modify`、沒有 `modify_strict` 路由**。
  ⇒ 無條件改送 strict 會讓**每一次 P4 modify 變成 404**，而因為 flow 路徑是非同步的，
  呼叫端仍會拿到 200 `queued`，**看不見**
- **失效方向**：靜默 ＋ **不可逆**
- **會發生什麼**：改自己的 priority-100 規則，結果**改到 router 的 priority-10 規則**
  （確認是同一條——`duration`/`n_packets` 沒變），搬走 32 MB 流量，
  **而且刪掉自己的規則之後傷害還在**
- **機制**（同一個檔案、相隔 40 行，一個做對一個做錯）：
  ```cpp
  // HttpRoutingStrategyBase.cpp:158-164  —— 正確
  if (priority == -1) return post("/stats/flowentry/delete", ...);          // 非 strict
  body["priority"] = priority;
  return post("/stats/flowentry/delete_strict", ...);                        // strict

  // HttpRoutingStrategyBase.cpp:195-201  —— 錯
  body["priority"] = priority;                    // 設了…
  return post("/stats/flowentry/modify", ...);    // …但送非 strict，Ryu 不用它比對
  ```
  🔄 **上面那段是「修前」的碼，行號今天指不到它了（2026-09-02 覆核，`4cbec52d`）。**
  **原文不刪**（它是「為什麼要這樣修」的唯一記載），但引用前要知道兩件事：
  - `HttpRoutingStrategyBase.cpp:195-201` **現在是 `json body; body["dpid"] = …` 與那段修法註解的開頭**，
    錯的碼已經不在那裡。**已出貨的形狀在 `:222-228`**：
    `if (priority == -1) return post("/stats/flowentry/modify", …);` 否則
    `body["priority"] = priority; return post(strictModifyPath(), …);`
    ——base 的 `strictModifyPath()` 回 `"/stats/flowentry/modify_strict"`（`:236-239`），
    P4 override 回 `"/stats/flowentry/modify"`（`P4RoutingStrategy.hpp:60`）。〔實測，本文以 `git show 4cbec52d:` 覆核〕
  - **狀態行寫的「§3.3 阻斷檢查對活 Ryu 回 200」現在可以靜態結案**：
    `ryu/app/ofctl_rest.py` 註冊 `POST /stats/flowentry/{cmd}`，
    `lib/ofctl_v1_3.py` 把 `modify_strict` 映到 `OFPFC_MODIFY_STRICT`
    ⇒ **07-29 那份指南的路由清單只是不完整**，不需要再靠 live 200 當證據。〔轉述 A-4e fix-design，本文未逐行覆核 ofctl_rest 的行號〕
- 🔴 **本條的變異閘不在 `tests/shell/`，而且現況不可重跑（2026-09-02）**：
  狀態行寫的「變異閘（四顆全殺）」指的是
  `doc/audit/2026-08-30_known-issues-wave/11b_mutation-harness/mutations.py` 的 **M6–M9**，
  **不是** `tests/shell/mutate_*.sh`——base 的六支 `mutate_*.sh` 對
  `modify_strict`／`strictModifyPath`／`modifyAnEntry` **全部 0 命中**。
  而那支 harness 有兩個寫死路徑：`mutations.py:13` 與 `run_one.sh:19` 把
  `W` 釘在**另一個 agent 的 worktree**（`.claude/worktrees/agent-a2c2a6601f812a7eb`，**今天仍然存在
  且是別的 session 在寫的共用 checkout**）⇒ 從任何別的 checkout 重跑會**變異一棵樹、編譯另一棵**；
  `driver.sh:5` 的 `S=` 指向一個 session-local scratchpad，**今天已經不存在**，
  而 `:10` 用 `bash "$S/run_one.sh"` 執行它 ⇒ **committed 的 driver 今天跑不起來。**
  🔑 **這是「閘門存在」與「閘門可重跑」的差別**，登記在此免得下一輪以為重跑過。〔實測，本文以 `git show 4cbec52d:` ＋ `ls` 覆核；`driver.sh` 的 `S=` 在 **`:5`** 不是 fix-design 寫的 `:6`〕
- 🔄 **標題的 🔴 已於 2026-09-02 改成 🟢（Adam）**，原本它與狀態行的 `🟢 RESOLVED` 互相矛盾。
  **這是一致性修正，不是新的狀態判定**——狀態自 2026-08-31 起就是 RESOLVED。
- **`modify_flow_entry` 是唯一從沒被任何測試輪呼叫過的寫入動詞**，所以四輪都沒發現
- **證據**：實測 ＋ 原始碼比對（我獨立 grep 驗證過這個不對稱），`scratch/round6/`；
  上面的行號與閘門覆核＝2026-09-02 讀碼（`4cbec52d`），**未編譯、未重跑該閘**

### A-4f 🔴 電源循環會失去 bridge 的 sFlow 紀錄 → 該鏈路遙測永久歸零

- **狀態**：**OPEN。** ⏳ **待閘門重跑＋live 驗證佇列**（本列本輪刻意**不翻**）：
  分支 `e9993f9f` build ok、ctest 全綠，但 🔴 **變異閘 rc=2「baseline 紅」**——
  同一組 case 在 ctest 下是綠的，所以那是**閘門自己的判紅邏輯或 filter 裡別的 case**，尚未定位。
  而且它新加的兩個 shell 站點（`sudo ifconfig …`／`sudo ovs-vsctl … create sflow …`）
  **被 B-2b 的守衛判紅**（跨分支互動、守衛照設計推定有罪），正在改成 `execArgv`。
  ⇒ **閘門重跑綠之前不翻**；另依賴 sudoers 允許 `ovs-vsctl get bridge`／`list sflow`，
  否則修法會安靜地降級成只回報。
- **平面**：OVS
- **失效方向**：靜默（**0 bps 與「閒置」無法區分**）
- **會發生什麼**：電源循環後，**s3→s8 鏈路在實際承載 103 Mbps 時讀值恰好 0 bps**；
  手動補回 sFlow 紀錄後讀到 106–148 Mbps
- ⚠️ **機制比預測的窄**：**去樣本化的那台交換機是「進來的邊」變暗，不是出去的邊**
- **🔑 與 A-4b 疊加**（**08-29 更正歸屬：原文寫的是「與 F-17 疊加」，機制掛錯了**）：
  這條鏈路讀 0 bps 會進到 graph，而 Energy-App 的關機決策讀的是它**自己**從 graph 算的
  `group_avg_link_utilization`（A-4b 的路徑），**不是** F-17 的 `get_average_link_usage` 端點
  （那個端點的 client 在 app 裡零呼叫點——見 §C 表下的二次更正）。
  ⇒ **結論不變、機制換人**：**電源循環過的交換機會讓自己更容易再被關掉**，
  但要走 A-4b 的路徑講，不要引用 F-17
- **與 §F 的 qdisc 遺失是同一族**：`powerOff` 存了 port 清單，但既沒存 qdisc 也沒存 sFlow 紀錄
- 📌 **file:line 與四點補正（2026-09-02 fix-design 對帳，讀於 `4cbec52d`）**：
  - **刀在 `OVSPowerStrategy.cpp:171` 的 `sudo ovs-vsctl del-br`**。它一次帶走三樣，
    **只有第一樣被存起來**：port 清單（`:157-166`，已修）／**bridge 的 `sflow` 欄與它指向的紀錄**
    ／**與 bridge 同名的 internal port 上的管理 IP（agent 位址）**。
    `powerOn`（`:97-112`：add-br／add-port／ifconfig up／set-controller）**兩者都不重建**。〔親自讀過〕
  - 🔑 **只補 sFlow 紀錄不夠**：`agent=s3` 而 `s3` 沒有 IPv4 位址時，OVS 決定不出 agent 位址
    ⇒ 樣本進得來也歸不了戶。**斷言必須驗「樣本回來了」，不能只驗指令 rc=0。**〔讀碼推論〕
  - **P4 早就做了對應的事**：`/p4/readopt/{dpid}`（`P4PowerStrategy.cpp:104-121`）。
    ⇒ **本條的修法不是新發明，是把 P4 那半邊補到 OVS。** 差別在後果的音量：
    P4 掉的是 clone session ⇒ 不能轉發（吵）；OVS 掉的是 sFlow ⇒ 照常轉發只是量不到（靜默）。〔親自讀過〕
  - 🔴 **為什麼沒有人會注意到（本條的第二半，原文沒寫）**：`m_counterReports` **從來不被 erase**
    （全 repo 無 `m_counterReports.erase`）⇒ 去樣本化之後那個 key 每秒被重算成
    `usage=0`／`utilization=0`，**與「真的閒置」、「kernel 剛啟動還沒收到樣本」位元相同**；
    `EdgeProperties` 整個結構沒有 last-update 時間戳。而下游
    `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2829`）在 `:2866` 的
    `if (g[e].linkBandwidthUsage != 0 && …)` **把 0 的邊整條跳過**——不是算成 0，是**不進分母**。〔親自讀過〕
- 🔴 **會電源循環交換機的 round 腳本共四個位置，`90_restore.sh` 最危險**（全 `doc/audit/` 掃過）：
  `2026-08-30_live-full-stack-round/harness/25_apps_energy.sh`（跑過兩次；OVS 臂關 0 台⇒既有資料未被污染，
  **下一次 OVS 臂會**）、同目錄 **`90_restore.sh`**、`2026-08-28_chaos-harness/harness/actions.py`
  的 `_c01_*`（**從沒活跑過**）、以及 `invariants.py:78-90 inv01_powercycle_latency`（**其實構不到電源碼**：
  送 GET 且帶 `dpid=`，兩者都不成立 ⇒ 無影響）。
  **`90_restore.sh` 最危險的理由**：它的驗收條件是節點與邊的計數（`:203-211`），
  **A-4f 之下這些計數全部會回來——唯一沒回來的東西剛好是它不看的那個**；
  而 `:224` 已經對 F-7a／htb 印 `bad`，**sFlow 不在那段文字裡**，
  讀那行的人會以為「已知的殘留只有 shaping」。`README.md:81` 還把 `power-on` 寫成 OVS 的「便宜路線」。
  ✅ **`ndt down && ndt up` 的完整重建不受影響**（會重跑 `testbed_topo.py`）。〔親自讀過〕
- **證據**：實測，`scratch/round6/FINDINGS-round6.md` X1；
  上面的補正＝2026-09-02 讀碼（`4cbec52d`），修法分支 Python 13 紅→綠、4/4 mutant〔agent 實測，auditor 未重跑〕，
  **C++ 11 個測試 UNVERIFIED（未編譯）**

#### A-4g ⚠️ `BLOCK_HOST`：P4 上完全不生效，而且**兩個平面都無條件回 `success`**

> **編號 2026-09-02 定案**（原臨時編號 `NEW-BLOCK_HOST`）。放在 A-4 家族的末位，
> 因為它與 **A-4d** 是同一條 P4 install 路徑；A-4d 講「刪掉之後黑洞」，本條講「根本沒裝上還說成功」。
> Adam 2026-09-02 裁：**示範沒有這個動作 ⇒ 開單排後**；狀態仍 OPEN。

- **狀態**：**OPEN。** ⏳ **已開單、排在示範之後**（Adam 2026-09-02 裁：示範沒有 block-host 動作）。
  **證據級別仍是讀碼推論、未實跑**——要升級成實測需在 P4 上送一次 `BLOCK_HOST` 並讀回真表。
- **平面**：P4
- **失效方向**：樂觀 ＋ 主動誤導（回覆說做了）
- **機制**（兩端都讀過，**未執行**）：kernel 端 `IntentTranslator.cpp:728` 把 `actions` 建成
  **空的 `json::array()`**，match 只有 `eth_type`＋`ipv4_src`（`:725-726`）、**沒有 `ipv4_dst`**；
  proxy 端 `p4_proxy/proxy_agent/topology_manager.py:880-882` 是
  `if not ipv4_dst: print("Unsupported match criteria (needs nw_dst)"); return False`。
  kernel 的 `try` 只接 exception，**`False` 不會變成錯誤** ⇒ 印「Blocked host」、
  回 `{"status":"success"}`。〔讀碼推論；兩端由 auditor 親自開檔確認，未實跑〕
- 🔴 **同一個站點的第二個缺陷，比上面那個更廣（2026-09-02 由 A-7 那條線獨立撞到）**：
  `IntentTranslator.cpp:733` 的 `installAnEntry(...)` 是一個**裸述句——回傳的 `OpResult` 被整個丟掉**，
  然後 `:739` **無條件**回 `{"status": "success", "message": "Host … blocked."}`。
  🔑 **這與上面那條的差別要講清楚**：上面那條是「這個請求在 P4 上做不到」，
  **這一條是「南向不論回什麼都會被講成成功」**——就算 proxy 回錯、就算交換機拒絕、
  就算 OVS 平面上規則真的被拒，答案都一樣。⇒ **兩個平面都成立，不只 P4。**
  對照組就在同一個檔案裡：`:364`（install）／`:394`（modify）／`:417`（delete）
  三個直呼**都包在 `flowReply(...)` 裡**，會把結果講出來；**只有 `:733` 沒有。**
  〔讀碼推論，未實跑；行號本文以 `git show 4cbec52d:` 覆核〕
- ℹ️ **這四個直呼同時也是 A-7 的計數缺口**：它們**繞過 `FlowDispatcher`**
  （`enqueue` 全 kernel 只有 `HttpSession.cpp:1145` 一個呼叫點）
  ⇒ **`/ndt/get_flow_dispatch_status` 數不到 Intent Translator 下的任何一筆寫入**。見 A-7。
- **為什麼記下來**：示範若有 block-host 動作，那就是台上穿幫——**回覆與真的擋掉了長得一樣**。

### A-5 ~~每次 kernel 重啟都會截斷前一輪的 log~~ —— **已修（2026-08-30 更正）**

- **狀態**：🟢 **RESOLVED（2026-08-31，全鏈收齊）**——主機制 `b2e5b04`；深度 2 增強 `8e7e3b0`
  ＋變異閘（M-6 殺且四條 depth-1 舊檢查全綠、M-7 恰 6 紅）＋**三世代 live PASS**：兩次重啟後
  `.prev2` 首行與跑到一半即時擷取的 era-1 首行 `cmp` **逐位元組相同**、種入的 era-0 誘餌被
  逐出＝深度確實封頂 3、無 `.prev3`。
  ⚠️ **本條在 `b2e5b04` 之後仍被留成 OPEN，2026-08-30 才發現**——
  派工單據此指示去修 `src/utils/Logger.cpp`，那裡**本來就是 append**
  （`basic_file_sink_mt("netdt.log", /*truncate=*/false)`），**假設整個是錯的**
- **平面**：兩者
- **真正的機制（原文沒寫對）**：截斷不在 kernel 裡，在 **launcher 的 `>` 重導**——
  `stack.sh` 的 `start_bg`。`doc/2026-08-14_cross-component-integration-matrix.md:170` 早就寫對了。
  kernel 的 log 走 stdout，`--logfile`／`netdt.log` **stack.sh 從來沒傳過**，是死路徑
- **已修**：`b2e5b04` 把 `>` 前面加上 `mv -f "$log" "$log.prev"`，
  三個 log（`kernel.log`／`p4_proxy.log`／`ryu.log`）都走同一個 `start_bg`，全部涵蓋；
  測試 `tests/shell/test_start_bg_log_rotation.sh`
- **🔴 殘留（2026-08-30 補修）**：一代不夠。A-2 的繞法就是「重啟 kernel」，
  症狀復發你會再重啟一次——**第二次重啟把「有證據的那一代」換成「什麼都沒有的那一代」**，
  正好是本條講的示範情境。已改成 **深度 2**（`.prev` → `.prev2`），磁碟仍有界
- **🔑 繞法（仍然適用於超過兩代）**：連續重啟三次以上，還是要把 log 複製到別處
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`（舊輪次掃描，機制寫錯）；
  修法與複驗 `doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md`

### A-6 ~~P4 proxy 每次啟動都宣告「這輪毀了」~~ —— **已修（2026-08-30 更正）**

- **狀態**：🏁 **已修，本條原文已過期**。
  ⚠️ 與 A-5 同型：`11789e0` 修掉之後**本條仍被留成 OPEN**，2026-08-30 才發現
- **平面**：P4
- **原本會發生什麼**：proxy 在**每次**啟動時印出「the graph will stay partly disabled … for the
  rest」之類的訊息。那是假的——`inform_switch_entered` 會重試而且會成功。
  台下看到這行會以為系統壞了
- **已修**：`11789e0`（`p4_proxy/proxy_agent/main.py:259-279`）。三件事一起做了：
  1. 訊息**變成有條件的**——`if not not_entered` 走「全部認可」那支
  2. 剩下那支改寫成啟動當下**真正知道的事**：
     「normal when the kernel starts after the proxy … retrying the push in the background」，
     並指名 kernel 的 topology poll 自己就會 enable（`TopologyAndFlowMonitor.cpp:566`）
  3. 補上一個**有界的背景重試**，讓訊息講的「會自己好」真的成立
  原始碼註解自己記著這條的來歷：**2026-08-15 的 overnight audit 相信了那句話，誤診了一個健康的 era**
- **⚠️ 本條的另一半沒修、也不在本輪範圍**：`cleanupAppFolder` 仍會噴
  **17 條敘述後果為假的警告** ＋ **9 個裸的 sudo 密碼提示打到 stderr**（未複驗，沿用原記載）
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`；
  複驗 `doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md`

### A-7 排隊寫入的失敗對所有 API 都不可見

- **狀態**：🟢 **RESOLVED（2026-08-31）**——`DispatchOutcomeLog`＋`GET /ndt/get_flow_dispatch_status`
  （`2016d4c`／`636f9ab`），變異閘 M11 為首全數通過，**live P5 六項全中**（壞 port ⇒ `failed`+1、
  `recent_failures` 帶 dpid/priority/match；合法規則對照 ⇒ `succeeded`+1 其餘不動）、M15 淘汰算術閉合。
  ⚠️ 兩個語意邊界（實測）：`dispatched` 只數**經兩個 dispatch API** 的請求（開機編程對它隱形）；
  「southbound 說 ok」≠「表與請求一致」（FINDING-07：priority 落地恆 0）。
  〔歷史：曾裁延到報告後、列簡報 Page 35 誠實未解清單〕
- 📌 **上面「兩個語意邊界」那兩句，2026-09-02 各修一處（讀於 `4cbec52d`）**：
  - **是四個 route 不是兩個**：`install_flow_entry`（`HttpSession.cpp:186`）、
    `delete_flow_entry`（`:190`）、`modify_flow_entry`（`:194`）與合併端點
    `install_flow_entries_modify_flow_entries_and_delete_flow_entries`（`:223`），
    全部匯入 `processFlowBatch`；而 `dispatcher().enqueue` **全 kernel 只有 `:1145` 一個呼叫點**，
    `dispatched_` 只在 `DispatchOutcomeLog.hpp:101` 遞增、只被 `Controller.cpp:59` 呼叫。〔親自讀過〕
  - 🔴 **「開機編程對它隱形」是結構性的，不是漏接**：兩種 fabric 的開機編程都在**別的行程**
    ——OVS 是 Ryu app 的 `intelligent_router.py:1569 install_all_pair_paths`，bmv2 是 proxy 的
    `topology_manager.py:1008 install_initial_routes`——**kernel 內沒有任何 in-process 路徑數得到它們**。
    ⇒ 加一個 `boot_installed`／`boot_failed` 桶會**終其行程一生讀 0**，那是假承諾不是缺口。
    kernel 內**確實**繞過 dispatcher 的是 `IntentTranslator` 的四個直呼
    （`IntentTranslator.cpp:364`／`:394`／`:417`／`:733`）。〔親自讀過〕
  - 🔴 **FINDING-07 的「priority 落地恆 0」是對的觀測、錯的機制**：priority **每一跳都存活**
    ——`HttpSession.cpp:915` `j.priority = entry.value("priority", 0)` →
    `Controller.cpp:33` → `HttpRoutingStrategyBase.cpp:176` `body["priority"] = priority` →
    `api_routes.py:230-231` `data.get("priority")` → `p4_client.py:708` `entry.priority = int(priority)`
    **逐字寫入**（`P4RoutingStrategy` 沒有 override `installAnEntry`，兩平面送同一份 body）。
    它只在 **dst-only** 的 match 上消失：`topology_manager.py:880-897` 把那種請求送進
    `insert_ipv4_route(ipv4_dst, 32, …)`，而 `ipv4_lpm`（`p4_proxy/p4_src/ndtwin_switch.p4:350-352`）
    是單鍵 LPM 表、**根本沒有 priority 欄**，次序由 prefix length 決定。
    ⇒ **不是被某一層丟掉，是在目的地無法表示**；那個 `0` 是欄位缺席被算成預設值。
    ⇒ **「southbound 說 ok ≠ 表與請求一致」這句要改成講這件事**：
    端點收下一個 `priority`、把規則送進一張用不到它的表、然後回 `success` 什麼都不說——
    **答案對於請求為真，對於後果為假。** repo 內可修的就是這一句話。〔親自讀過〕
  - ℹ️ **契約覆蓋**：`/ndt/get_flow_dispatch_status` 在
    `tools/contract_test/components.py:33`，**而 `spec.py` 裡 0 命中** ⇒ 端點有登記、**無形狀斷言**
    （與 F-13 六端點同型，見 §C）。〔親自讀過〕
- **平面**：兩者
- **失效方向**：（修前）樂觀 ＋ 靜默
- **會發生什麼（修前）**：契約測試套件**全綠**，而同時 `kernel.log` 寫著 `dispatched install failed`。
  沒有任何 API 表面暴露那個失敗——**log 且只對失敗寫**（08-31 對帳：失敗行 261 vs `failed=261`
  一致；成功行 0 vs `succeeded=1`）
- **與 B-1 的關係**：B-1 是「拒絕沒被記錄」，這條是「失敗被記錄了但沒有 API 讀得到」——
  同一個斷鏈的兩端
- ⚠️ **2026-08-30 讀碼重驗：多了一個計數器，但斷鏈沒有接上（狀態不變）。**
  `aabe605` 為 `FlowDispatcher` 在 `stop()` 之後被丟掉的 job 加了計數與一次性警告
  （`include/ndt_core/routing_management/FlowDispatcher.hpp:116` 的 `droppedAfterStop()`、
  `:135` 的 `droppedAfterStop_`）。**但 `droppedAfterStop()` 在 `src/ndt_core/http/` 底下零個呼叫端**
  ——證據存在於行程記憶體裡，**仍然沒有任何 API 表面讀得到它**。
  ⇒ 本條的宣稱逐字照舊成立；這是 [[existence-is-not-wiring]] 的形狀，
  **「加了計數器」不等於「暴露了失敗」**。
  🔴 **上面這一段在 `4cbec52d` 已經不成立，而它失效的方式比「過期」更值得記（2026-09-02 覆核）**：
  `src/ndt_core/http/HttpSession.cpp:669` 就是它的呼叫端
  （`{"dropped_after_stop", m_controller->dispatcher().droppedAfterStop()}`），
  隨 **`636f9ab`** 落地——**正是本條狀態行自己引用的兩顆 commit 之一**。
  ⏱️ **時間軸要看清楚，因為它決定這是誰的錯**：
  這段註記**明白宣告自己的基準是 `1208d22`（2026-08-30 20:11）**，
  而**對著那個基準它完全正確**——`1208d22` 上 `src/ndt_core/http/` 沒有任何 `droppedAfterStop` 命中，
  `/ndt/get_flow_dispatch_status` 也還不存在。接線在 **2 小時後**落地（`636f9ab`，08-30 22:18），
  而這段文字是在 **13 小時後**才被寫進本檔（`1c8828b6`，08-31 11:25）**而沒有重讀一次**。
  ⇒ 🔑 **教訓不是「⚠️ 子註記會活過它的條目」，是「宣告了基準的讀碼是誠實的，
  但把它 commit 進一份活文件之前沒有重讀，就會讓它在落地的那一刻就是假的」。**
  ⇒ 「加了計數器不等於暴露了失敗」這個**通則**照舊成立，
  **但這個實例已經接上了**，不要再拿它當「還沒接線」的例子。〔實測，本文以 `git grep`／`git log` 覆核〕
  ⚠️ **殘留的缺口是另一個，而且是真的**：`dropped_after_stop` 公布了，`running_`
  （`FlowDispatcher.hpp:132`）**沒有，也沒有任何 accessor**。而這個計數器只有在 `stop()`
  之後才可能離開 0（兩個 `enqueue` 多載都只在 `!running_` 時呼叫 `noteDropped_`）
  ⇒ **端點對兩種相反的狀態公布同一個 `0`**：①活著、沒丟過＝健康；
  ②**已經停了、之後沒人 enqueue**——而此時 `POST /ndt/install_flow_entry` 仍然回 `200 {"status":"queued"}`。
  **A-7 自己的失效形狀，在為了揭露它而蓋的那個表面上又出現了一次。**〔親自讀過〕
  ⚠️ 另註：`aabe605` 補的是 **stop() 之後丟棄**那一種，本條原本引的
  `dispatched install failed` 是**另一種**失敗，兩者不要混為一談。
- **證據**：`scratch/phase2/DEFECT-INVENTORY.md`

### A-8 三個測試工具在系統正確運作時變紅

- **狀態**：**OPEN。** ⏳ **待 live 驗證佇列**：修法在 `fb68ef1d`（三態輸出：down+ON＝failure、
  down+OFF＝`ACCOUNTED-FOR`、讀不到＝`TOOL-PRECONDITION-FAILED` exit 3），
  22＋113 綠、倒回三個工具檔 ⇒ rc=1、15 紅 4 錯（auditor 重跑）。
  🔴 **缺的是一輪 live R-5**：`40_r5_p4.sh:324`／`50_r5_ovs.sh:219` 用**字面 grep**
  （`switch(es) not up`／`BROKEN`）判 A-8 在不在 ⇒ **新路徑不可以出現這些字**，
  這件事只有真的跑一輪才成立。另 exit code 3 對 CI 的語意待 Adam 定。
  〔以下為 2026-08-30 的實跑重驗，仍然是本條成立的證據：〕**2026-08-30 實跑重驗仍然成立**（T-4 輪 R-5，kernel `89c1754`）：
  契約套件對著一座 Energy-App **正確**降級過的網路，報了 8 行 `switch(es) not up` ＋ 1 行 `BROKEN`，
  而那 20 條 down 的邊每一條都連著一台已關機的交換機——**孿生的帳是對的，抱怨的是套件**。
  正本 `doc/audit/2026-08-30_live-full-stack-round/R5-result-both-arms.md`（該檔的 **F-2** 列）。
  ⚠️ **那份檔案裡的 `F-2` 就是本條**；不要跟 §C 表的 `F-2`（不存在）或 subagent 那套編號混用，見 §C 表下的消歧註
- **平面**：兩者
- **失效方向**：悲觀
- **會發生什麼**：Energy-Saving-App **正確地**關掉一台交換機時，L2 契約測試、L3 契約測試、
  log allowlist 三個工具同時turn紅
- **為什麼重要**：一個在系統正確時變紅的測試套件，會訓練它的讀者**忽略紅色**
- 📌 **三個工具點名（2026-09-02 fix-design 對帳，讀於 `4cbec52d`）**——正文逐字仍然成立，
  補上「是哪三個檔、哪一行」：
  1. **L2 API 契約**：`tools/contract_test/spec.py:161 inv_all_switches_up`／
     `:186 inv_edges_enabled`（兩個都掛在 `get_graph_data` 上，`:381-382`）。〔親自讀過〕
  2. **L3 元件契約**：`tools/contract_test/l3_component_check.py`——它**不自己重算不變量**，
     直接 import L2 的 `check_endpoint` 並把 L2 的判決扇出到元件；`BROKEN` 這個字產生在 `:270`。
     ⇒ **L3 的紅是 L2 的紅的下游，一個假紅會扇出成「6 個元件會壞」。**〔親自讀過〕
  3. **log allowlist**：`tools/contract_test/check_logs.py:240-246`（WARN 分支）＋
     `warning_allowlist.txt` 缺的那一條。被判紅的那行來自
     `DeviceConfigurationAndPowerManager.cpp:1130-1139`，**而那一行正是 kernel 行為正確的證明**。〔親自讀過〕
- 🔴 **08-18 建議的修法是死的（本輪推翻）**：那個建議是「用 `admin_disabled` 區分」，
  但 `admin_disabled` 標的是 **Intent Translator 的 `DisableSwitch`／`EnableSwitch`**，
  不是 power app——`GraphTypes.hpp:198` 逐字寫著它由 DisableSwitch/EnableSwitch 設定、
  「Discovery must never touch it」，寫入點只有 `TopologyAndFlowMonitor.cpp:2412`／`:2422`／`:2452`／`:2462`。
  ⇒ **關機的交換機這個欄位是 false，判準拿不到任何資訊**；要 key 的是
  `/ndt/get_switches_power_state`。〔親自讀過（欄位語意由本文 sed 覆核）；agent 另有實測 false〕
- ⚠️ **本條與 A-2 狀態行那句「判準要跟著故障注入手法走」不是同一族**：
  A-8 **不是**判準過期，是**判準少了一個值**——把「系統壞了」與「工具沒辦法判斷」壓進同一個輸出。
  前者要改**輸出的值域**，後者只要重推期望值。〔讀碼推論〕
- **證據**：實測，`doc/audit/2026-08-18_live-full-stack-round/` F-2 / N-9；
  上面的點名＝2026-09-02 讀碼（`4cbec52d`），修法分支由 auditor 重跑
  （22＋113 綠、selftest 綠；倒回 `spec.py`／`check_logs.py`／`l3_component_check.py` ⇒ rc=1、15 紅 4 錯）〔實測，auditor 重跑〕

### A-9 🔴 Energy-App 每 300 秒放掉 `routing_lock` 又在一秒內搶回去 —— polling livelock（TR-5 三臂 0 台被關的原因）

> 🔄 **標題 2026-09-02 由 Adam 改（原題：拿了 `routing_lock` 就永遠不放）。**
> 舊標題**字面不成立**——租約會到期；但**可觀測上成立**，因為唯一在等這把鎖的 app 以 1 Hz 重試，
> 到期後一秒內就重新拿走。改標題是為了讓修法不要被「反正 TTL 會到期」帶偏：**到期救不了它。**
> 舊題保留在括號裡，因為 TR-5 的報告與工單都用那個字串引用本條。

- **狀態**：🟢 **kernel 側 RESOLVED（2026-09-02，`3dfa51cc`）；app 側仍 OPEN。**
  變異閘 **23/23 全殺**（三支 delegate rc=0），build ok、ctest 全綠，整合樹 build 0 error、**ctest 870/870**。
  修法＝租約帶 `leaseId`、到期由「條件」改成「事件」（釋放與續約都要對得上持有者）。
  🔴 **兩件事沒有跟著關掉，不要一起讀成已修**：
  ① **app 側八條 acquire 後不 release 的出口**（含完全沒有 release 的 `easy_enable_switch()`）
  在 **Energy-Saving-App repo**，本輪沒有動，**等 Adam 裁跨 repo 改動**；
  ② **B-2 的第②條（無 owner）仍 OPEN**——A-9 的 `leaseId` 就是它要的 token，
  但 `setRequireLeaseId()` **預設關、而且沒有接線**（[[existence-is-not-wiring]]）。
  〔原狀態：OPEN（2026-08-30 TR-5 發現＝FINDING-08；三臂重現：P4、OVS、乾淨重跑臂一致）〕
- **平面**：兩者（缺陷在 Energy-Saving-App 的呼叫序）
- **機制**：兩個 `release_lock` 呼叫都在「需要 Simulation-Platform-Manager 的模擬往返」後面；
  該往返不可達時 app 對 423 以 1 Hz 空轉滿 **300 秒 TTL**——比 241 秒的 energy watch 還長，
  於是 watch 只數到重試；**鎖活過 `energy-stop`**。
- **會發生什麼**：示範時 Energy-App 第一輪就把自己廢掉，0 台交換機被關；之後任何**去 `acquire`**
  `routing_lock` 的請求都吃 423 直到 TTL 到期。
  🔴 **這句話 2026-09-02 改過口徑，原文寫的是「任何要 `routing_lock` 的操作」——那是錯的。**
  **kernel 從不檢查這把鎖**：`m_lockManager` 全庫只被三個 lock handler 用到
  （`HttpSession.cpp:2043` acquire／`:2096` renew／`:2160` unlock），
  `set_switches_power_state` 等寫入路徑**完全不受鎖影響**。
  ⇒ **因果鏈整條跑在 app 自己的門閂上**：app 拿不到鎖就 `continue`，決策迴圈一次都沒跑，
  於是 0 台被關。**不是「kernel 因為鎖被持有而拒絕關機」。**〔親自讀過〕
- 📌 **機制更正：鎖是有到期的，缺陷是「到期是條件不是事件」（2026-09-02，讀於 `4cbec52d`）**：
  - `acquireLock` **會**比時間（`include/ndt_core/lock_management/LockManager.hpp:210`
    `if (state.isLocked && now < state.expiryTime)`）；`renew` 自 2026-09-01（B-2①）起也會（`:304`）。
    **但 `isLocked` 只有 `unlock()` 與 `acquireLock()` 會清，到期不清**——而且
    `:286-289` 的註解說明那是**刻意**的。
  - ⇒ 死租約上 `unlock()` 回 **true**、`/ndt/release_lock` 回 **200 `released`**，
    **與真的釋放位元相同**；而一個晚到的 release 會清掉**新持有者**的旗標。〔親自讀過〕
  - ⇒ 舊標題「永遠不放」字面不成立、**可觀測上成立**（09-02 已據此改題，見上方框）：租約 T+300 到期，
    app 的 1 Hz 重試在 T+300±1 秒重新取得 ⇒ 對任何第三方，這把鎖的可取用窗**每 300 秒一次、寬度 <1 秒**。
    **這是 polling livelock 不是死結，修法不能只靠「反正 TTL 會到期」。**〔讀碼推論〕
- 🔴 **app 側（唯讀）**：acquire 之後有**八條出口不 release**，`easy_enable_switch()`
  **完全沒有 release**。⇒ 本條不是「兩個 release 排在模擬往返後面」一句話講得完的。〔親自讀過（Energy-Saving-App，未執行）〕
- **繞法**：`POST /ndt/release_lock {"type":"routing_lock"}` 手動清鎖。
- **真修**：動 Energy-Saving-App repo（等 Adam 裁）；週四 demo 用繞法。
- **證據**：`doc/audit/2026-08-30_live-traffic-round/`（TR-5 三臂：0 台被關、acquire_lock
  183/188/183；`776c91e`／`ec515ce`）；上面的機制更正＝2026-09-02 讀碼（`4cbec52d`），
  **C++ 修法分支 UNVERIFIED（沒編譯、沒看過紅也沒看過綠）**
  ⚠️ **本則引用的 `LockManager.hpp:210`／`:304` 是本文親自 `sed` 覆核的；
  fix-design 與對帳簿寫的 `:203`／`:305` 各差 7 行與 1 行**（`:203` 是 `lock_guard` 那行）。
  §B-2 的狀態行早就寫對了 `:210`。

---

### A-10 🔴 `/ndt/delete_group_entry` 在 OVS 上是無聲的 no-op，而且會永久洩漏 group id

- **狀態**：OPEN（2026-09-03 夜巡第一輪確認）。未修。
- **平面**：OVS（P4 未測同一配方）
- **失效方向**：樂觀 ＋ 靜默
- **會發生什麼**：`POST /ndt/delete_group_entry` 回 **200 `{"outcome":"deleted"}`**，
  而 group 還在交換機上——`duration_sec` 繼續累加、buckets 一個都沒動。
  用**同一個 id** 再裝一次會被 409 拒絕「已存在」⇒ **那個 id 從此拿不回來**。
- **機制（未定位到行）**：kernel log 對這件事**一行都沒有**（5 次 `handleDeleteGroupEntry`、
  0 條刪除失敗）。而 API 自己的說明叫呼叫者「去 kernel log 看每一筆的結果」——
  **它指向一個空的地方**。⇒「說刪掉了」與「真的刪掉了」在**所有**可觀測管道上長得一樣。
- **繞法**：刪除後不要相信 `outcome`，改用 `ovs-ofctl dump-groups` 直接讀交換機；
  id 用過就當作已消耗，不要重用。
- **證據**：`doc/audit/2026-09-03_night-rounds/round1-ovs/21_delete_group_meter_says_deleted_but_persists.log`

### A-11 🔴 失敗的 `ndt up ovs4` 不會回滾 —— 留下一個沒有大腦的網路

- **狀態**：OPEN（2026-09-03 夜巡第一輪確認）。未修。
- **平面**：OVS
- **失效方向**：靜默（使用者以為什麼都沒發生）
- **會發生什麼**：`ndt up ovs4` 失敗之後，Ryu（`:8080`／`:6633`／`:6653`）、tmux 的 topo
  session、**15 個行程與 36 條 veth 的整個資料平面全部留著**，而**沒有 kernel**。
  下一步做什麼都會踩到它。
- **機制**：`:8000` 被佔用的檢查在 `stack.sh` 的 **[3/3]**，也就是**在 fabric 已經建好之後**。
  檢查的位置決定了失敗時留下什麼。
- **繞法**：`ndt up` 失敗後**一定要跑 `ndt down`** 再重試——對照組 log 顯示
  `ndt down` 之後才真的乾淨。
- **證據**：`.../round1-ovs/02_ndt_up_failure_leaves_fabric_running.log`
  （對照：`.../round1-ovs/03_*` 顯示 `ndt down` 之後清乾淨）

### A-12 🔴 `ovs4` 拓樸完全沒有配置 sFlow ⇒ 分身看到的流量結構性為零

- **狀態**：OPEN（2026-09-03 夜巡第一輪確認）。未修。
- **平面**：**只有 `ovs4`。** `ndt up ovs`（128 主機）走 NTG 的 `testbed_topo.py`，**有** sFlow。
- **失效方向**：靜默；而且錯的方向是「把沒問到說成很閒」
- **會發生什麼**：十座 bridge 的 `sflow` 欄全是 `[]`，而 kernel 照常在 `:6343` 聽。
  ⇒ 流速率與鏈路使用率**結構性為零**，`/ndt/get_average_link_usage` 回
  `{"avg_link_usage":0.0,"status":"success"}`——**`status` 是關於請求，不是關於答案**。
- **機制（歸屬明確）**：`tools/test_workflow/ovs_4host_topo.py` 有 **0** 個 sFlow 參照；
  參考拓樸 `testbed_topo.py` 在 `:105` 定義 `enable_sflow()`、在 `:202` 呼叫它。
- **繞法**：在 `ovs4` 上不要引用任何流量或使用率數字；要量測請用 `ndt up ovs`。
- **證據**：`.../round1-ovs/11_sflow_state_on_ovs.log`、`12_*`
  （對照：同一份 log 裡有 3000 封包／0% loss 的**真流**，數字前後都是 0.0）

### A-13 🔴 kernel 關機時 abort，而文件描述的那條乾淨關機路徑**從來沒有被執行過**

- **狀態**：修法在分支 `fix/b5-kernel-shutdown`，**未併入**（2026-09-02 B-5）。
- **平面**：兩者
- **失效方向**：崩潰 ＋ 靜默（沒有人看得出來）
- **會發生什麼**：SIGINT 之下 **7/7 次 exit 134**（`std::terminate`）；修法後 7/7 exit 0。
- **機制**：`DeviceConfigurationAndPowerManager::start()` 開**三**條 thread，`stop()` 只 join **兩**條
  ⇒ 解構一條 joinable 的 `std::thread` ⇒ `std::terminate`。gdb backtrace 對得到 offset。
- 🔴 **更重要的第二半**：**`ndt down` 送的是 SIGTERM，而 kernel 只註冊 SIGINT**
  ⇒ 那條「乾淨關機」在正式路徑上**從未跑過**，行程一直是被硬殺的。
  ⇒ 修好 abort **不會**讓 `ndt down` 走上那條路；SIGTERM handler 是另一件事。
- **證據**：`doc/audit/2026-09-02_live-round/raw/D2_b5_kernel_exit.log` ＋ B-5 報告

### A-14 🔴 `ndt` 有兩個 `sudo -n` 不在手冊教的 sudoers 規則裡 ⇒ 一道守衛永不觸發

- **狀態**：OPEN。**🔴 這一條是手冊線的 desk check，未在需要密碼的機器上實跑**——
  引用時必須連這句一起引。
- **平面**：兩者
- **失效方向**：靜默；而且其中一處的誤判方向是「把量不到說成一句具體的失敗」
- **會發生什麼**：`ndt:1177`（`ovs-vsctl list-br`）與 `ndt:1206`（`mnexec`）兩個 `sudo -n`
  不在 User Manual 教的 sudoers 規則裡。權限被拒 ⇒ `ovs_bridge_count` **靜靜回 0**
  ⇒ **`ndt up p4` 的「底下有活的 OVS fabric 就拒絕」守衛永不觸發**，
  會**靜靜拆掉別人的 fabric**。另一處把「沒權限問」翻成
  `h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding` 這句**具體斷言**。
- 🔑 **為什麼四輪 usertest 都看不見它**：tester VM 有**全域免密碼 sudo**
  ⇒ **儀器把缺陷遮住了**。這是 [test-environment-masks-the-defect] 的實例。
- **繞法**：在按手冊設定 sudoers 的機器上，先手動確認這兩條指令不會提示密碼。
- **證據**：手冊線 desk check（未實跑）

## B. 需要特定操作才會踩到

### B-1 被交換機拒絕的規則，twin 當成存在的來服務（幽靈規則）

- **狀態**：**OPEN，且建議拆成 B-1a（P4）／B-1b（OVS）——⏳ 拆條與翻面都在待 live 驗證佇列。**
  🔴 **拆之前要先把「OVS 上過濾器不生效」從讀碼變成觀測**：那條推論（Ryu 200 空 body ⇒
  `OpResult::success` ⇒ token 蓋章 ⇒ 幽靈照樣被服務出去）**沒有在 OVS 上實跑過**。
  配方＝送一條會被交換機拒絕的規則，看它有沒有出現在表視圖裡。
  ⚠️ **在那之前不要把 🟢 那一列讀成兩個平面都修了**，見本條下方的 2026-09-02 覆核。
  〔原狀態：OPEN（2026-08-18 裁定報告前不修）。〕
  **2026-08-30 實跑重驗：兩個平面都仍然發作，而且機制第一次被指認出來**
  （T-4 輪 R-5／FINDING-03，文件 commit `2bfb958`，kernel `89c1754`）。
  **機制**：kernel 的**流表視圖**把一個**已排隊但尚未編程**的請求當成流表列服務出去，
  剝掉了真實流表列會帶的每一個統計欄位。
  指紋有鑑別力且兩平面一致：該筆只有 4 個欄位（其餘 41 筆有 13 個）、
  `actions` 是**物件**（`{"port":999,"type":"OUTPUT"}`）而不是字串（`"OUTPUT:3"`）、
  match 用的是**請求自己的詞彙**（`eth_type`/`ipv4_dst`）而不是 OpenFlow 的（`dl_type`/`nw_dst`）。
  ⇒ **回音在 kernel 的表格視圖，不在任一資料面的寫入路徑。**
  🔑 **API 本身是誠實的**：它回 `{"status":"queued","accepted":1,...}` 並且真的只是排隊了；
  **過度宣稱的是表格視圖**。
  ⚠️ **不要用它解釋本條原本記的 7.2–8.2 秒**：FINDING-03 量到的窗口在 t=2（P4）／t=3（OVS）就沒了，
  該檔**明文不宣稱**這和 08-18 量到的 ~8 秒是同一個現象（「同一個指紋，與舊時長的關係未知」）。
  ⚠️ **08-18 說「P4 上這個窗口不存在」是錯的**，原因是取樣格的**第一格就在 t=2**、已經在事件之後；
  **這不是資料錯，是格子沒對準**。
  📌 修法工單 **T-11**（`doc/2026-08-30_manual-verification-report.md:96`）。
  🔴 **本行原本寫「狀態＝已開、修法待裁」，那在寫下的當天之後就過期了**——
  T-11-A 已於 2026-08-31 落地並經 live 雙向驗證，**證據就在本條目下方 23 行**（見 🟢 那一列）。
  過期文字於 2026-08-31 夜由 auditor 移除。**狀態以下方那一列為準，不以本行為準。**
  ⇒ 這是本文件第二次出現同型：**更正被歸檔到讀者不會經過的位置**（此處是同一條目的下半，
  先被讀到的是上半）。同日另一例在 `doc/audit/2026-08-30_ovs-flowcount-control/FINDINGS.md:189`
  ——懸案「機制未定位」的更正落成一個新檔，原文六小時未被指過去，害一條線從頭重推一遍。
  **T-11 這個編號不在 FINDING-03 檔內**，引用時要引工單表那一行
- **平面**：**兩者**，但誠實程度不同
- **失效方向**：樂觀 ＋ **OVS 上完全靜默**
- **四個格子**（實測，2026-08-19）：

  | | 不帶 `ip_proto` 的 `tcp_dst` | 帶 `ip_proto` |
  |---|---|---|
  | **OVS** | kernel 200、Ryu 200、**兩邊 log 零錯誤行**、規則從沒到達交換機 | 立刻裝上 |
  | **P4** | proxy 400 指名欄位、kernel `[warning]`+`[error]`、proxy `Refusing rule`，POST 後 8 ms | **一樣 400**（`ipv4_lpm` 也不收） |

- **幽靈窗口**：兩個平面都有。P4 上實測 **7.2–8.2 秒**（1 秒解析度），到下次 poll 為止
- **🔑 kernel 回應文字「per-entry outcomes are reported in the kernel log」
  在 P4 上為真、在 OVS 上為假**
- **根因（OVS）**：`Controller.cpp:55` 靠「在 200 body 裡找錯誤」偵測失敗；
  P4 proxy 會放一個進去，Ryu 的 fire-and-forget `/stats/flowentry/add` 做不到
- **⚠️ 這在三週前就被預測過**：`doc/2026-07-28_test_coverage_gaps.md` §8 待辦 4 猜對了原因
  （"curl fire-and-forget"），08-13 的 fault catalogue C-1 引用它並稱之為
  「最有價值也最容易做」
- **副作用**：服務出去的表格**混用兩套 match key 詞彙**——poll 來的是 `dl_type`/`nw_dst`，
  樂觀 append 來的是 `eth_type`/`ipv4_dst`
- **證據**：實測，`doc/audit/2026-08-18_live-full-stack-round/` F-5/F-5b（OVS）
  ＋ `scratch/phase2/FINDINGS.md` E6（四格對照）
- 🟢 **kernel 視圖那一半已修（T-11-A `91e7743`，2026-08-31 live 力紅力綠雙向驗證）**：
  表列只報南向已確認的列（token provenance），pre-T-11 binary 幻影 t=0.005s 現／T-11 binary
  25 秒全程不現。**兩個明界**：①已確認列在下一次 poll 前（實測 **7.4 秒**）仍帶請求 priority
  與呼叫端字彙——FINDING-07 地盤，不在本修範圍；②**只 token 了 install**——被拒的
  modify/delete 仍反向污染快取（少報、≤10.7s poll 自癒），已登記鏡像票（週四後）。
- 🔴 **2026-09-02 覆核：上面那一列少了三個明界，其中一個會吃掉整個修**（讀於 `4cbec52d`）：
  1. 🔴 **平面限定沒有寫**——**在 OVS 上這個過濾器對「被交換機拒絕的規則」沒有作用。**
     過濾器的判準是 `DispatchOutcomeLog::isProgrammed(token)`，token 只在
     `Controller.cpp:59` 的 `result.ok == true` 時蓋上；而 `result.ok` 來自
     `HttpRoutingStrategyBase::post()`，它走完 `status==0` 與非 2xx 兩個閘之後，
     **只剩「body 裡有沒有 `{"status":"error"}`」這一個判別**——該檔 `:116-117` 的註解
     逐字寫著「Ryu does not, but the P4 proxy agent does」。⇒ Ryu 的 fire-and-forget 200
     ⇒ `ok=true` ⇒ 蓋 token ⇒ **幽靈照樣被服務出去**。
     **它擋得住「還沒送到」與「南向明確回報失敗」，擋不住「南向謊報成功」。**
     ⚠️ 本條上方明寫「平面：**兩者**」，而 🟢 那一列沒有帶平面限定
     ⇒ **讀者會把一個 P4-only 的修讀成兩個平面都修了**。〔讀碼推論，**未在 OVS 上實跑**〕
  2. **改的是視圖，不是狀態**：過濾點在**唯一的共同讀出口**
     （`DeviceConfigurationAndPowerManager.cpp:1975`，全 repo `m_cachedOpenFlowTables` 只五處、
     沒有繞過過濾器的讀取路徑）——對**今天存在的**消費者，幽靈真的不見了。
     **但被拒的列仍留在快取裡**，而 `updateOpenFlowTables` 的 `modifyOne`（`:2134-2155`）與
     `deleteOne`（`:2158-2170`）**直接走原始陣列、不看 token**
     ⇒ 那 ~10.7 秒內進來的 modify/delete **可以命中一條從未被編程的幽靈列**
     （modify 就地改它然後 `break`，delete 把它移除）。**嚴重度未量。**〔讀碼推論〕
  3. **`stripUnprogrammedEntries` 的回傳值被丟掉**（`:1975`），
     而它的 docstring 明寫「@return How many rows were withheld, so a caller can log or assert on it」
     ⇒ **沒有任何地方看得出「視圖正在扣住東西」**；predicate 沒接上時的預設是「扣住每一列」，
     那個狀態從外面完全看不出來。〔親自讀過〕
  📌 **附帶的儀器發現**：隨 `91e7743` 附的 `tests/test_PendingEntryFilter.cpp` 8 顆 gtest
  只 include 兩個標頭、直接呼叫純函式 `stripUnprogrammedEntries(tables, pred)`，
  **從不構造 `DeviceConfigurationAndPowerManager`、不呼叫 `getOpenFlowTables()`、不碰 `HttpSession`**
  ⇒ 三個接線點（`DCAPM.cpp:1975`、`main.cpp:389`、`HttpSession.cpp:1155-1162`）
  **拆掉任何一個，那 8 顆照樣綠**。工單的 T1–T5 變異全部錨在那顆純函式內部，
  **接線不在任何變異的射程內**。〔讀碼推論〕
  ✅ **這個缺口已被補上並由 auditor 重跑**：`b19045b0` 的接線測試改成剝掉註解／字面量／`#if 0`
  之後再比對，auditor 的 M4（把 `DCAPM.cpp:1975` 整行註解掉）⇒ **rc=1、16 顆中 3 紅**；
  唯一存活的 M9（predicate 恆真）是語意層、由 gtest T4 守。
  〔實測，auditor 重跑〕⚠️ **對帳簿較早那則「它的變異宣稱我沒重現」已被同簿後續取代，以本行為準。**

### B-2 鎖在兩種平常情況下不提供互斥

- **狀態**：**OPEN——①已修（2026-09-01），②原封不動**。🔴 **兩條要分開讀，本條不得整條關掉。**
  ①「續約已過期的鎖」已修並過變異閘（六顆全殺、678/678 綠），詳見下方 ① 的 🏁 段；
  ②「任何人可以釋放／續約任何人的鎖」**沒有動**——它需要 `LockState` 長出 owner 欄位，
  是跨 repo 的協定改動。**①只擋住「租約已經死了」那一格**：租約還活著的時候，
  一個沒持有它的 client 仍然續得動別人的鎖。
  ⚠️ **所以「B-2 修了」這句話在本輪之後仍然是錯的**，它只對一半成立。
  🔴 **本條在 08-30 被拆過一次**：這一週動到鎖端點的兩顆 commit
  （`4ee086f`＋`87d272f`）修的是**第三族**問題——「請求沒指名鎖，卻被代入 `routing_lock`」，
  那一族已收在 **B-2d**。**它們沒有碰下面這兩條。**
  ⚠️ **所以看到「acquire_lock 三個缺陷已修」不要順手把本條關掉**，兩件事只是共用同一個端點。
- **平面**：兩者（純 kernel）
- **失效方向**：靜默（兩邊都回 200）
- **兩個獨立問題**：
  1. **續約一個已過期的鎖回 200**（契約寫 412）。`LockManager::renew` 只檢查 map entry
     存在且 `isLocked` 為真，**從不比較 `now < expiryTime`**；而 `isLocked` 只有 `unlock()`
     或 `acquireLock()` 會清掉，**過期不會清**。
     實測的有鑑別力變體：一個**什麼都沒持有**的 client 把**別人的**鎖從 3 秒延長到 120 秒，
     並把第三方鎖在門外。
     ✅ **2026-08-30 逐行重驗仍然成立**：`include/ndt_core/lock_management/LockManager.hpp:256-271`
     的 `renew()` 判斷式逐字是
     `if (m_locks.find(type) == m_locks.end() || !m_locks[type].isLocked)`——**沒有任何時間比較**。
     🔑 **對照組就在同一個檔案裡**：`acquireLock()`（`:210`）寫的是
     `if (state.isLocked && now < state.expiryTime)`，**它比了**。
     ⇒ **這不是「整個類別都沒有到期概念」，是 renew 這一支漏掉**，所以修法很窄。
     🏁 **已修（2026-09-01，Adam 線裁「先做 1+2」）。** `renew()` 的判斷式補上第三個子句
     `|| now >= it->second.expiryTime`，與 `acquireLock` 用同一個比較。變異閘
     `tests/shell/mutate_lock_renew_expiry.sh`：**六顆全殺**（拿掉比較／比較反向／回 true 不寫入／
     不看 `isLocked`／renew 憑空建鎖／handler 把 412 回成 200），`survivors=0`，
     全套 gtest 678/678。
     🔴 **修這條的過程中發現：本 repo 的測試套件把這個缺陷釘成了「預期行為」。**
     `tests/test_LockManager.cpp` 有一顆綠的 `RenewingAnExpiredLockPutsItBackInForce`，
     理由寫著「renew 存在就是為了讓超過自己 TTL 的長操作續命」——那句話涵蓋的是**持有者自己晚了**，
     不涵蓋 renew 只收鎖名不收持有者這件事。**「測試全綠」在修法前後都成立**，
     所以判斷套件釘的是修法還是缺陷，只有變異跑得出來。已連同原始理由一起寫進該檔檔頭，
     不刪除（理由比結論活得久）。
     ⚠️ **五顆端點測試的鑑別力被這個修法拿掉了，已重做**：它們用 `acquireLock(name, 0)`
     （已過期）當 setup，靠「之後還 acquire 得到」判斷「租約沒有被延長」——修法之後
     洩漏進來的 renew 也會被拒，兩種情形同一個答案。改成用**活著的**鎖，判準換成回覆
     （洩漏＝200 `"status":"renewed"`，正確＝400）。
     ⚠️ **`tools/contract_test/spec.py` 現在有一個真的時間相依**：`LOCK_TTL = 5`，
     acquire→renew 之間若超過 5 秒，`renew_lock` 會拿到 412。修法前那一格會靜靜地通過。
     本輪沒有改 `spec.py`（相鄰兩個 HTTP 呼叫隔 5 秒不合理），**但這是新的 flake 面**。
  2. **任何人可以釋放任何人的鎖**。`LockState` **沒有 owner 欄位**，`unlock()` 為呼叫者清鎖。
     真正的持有者只會從下一次失敗的 renew 得知自己被踢出臨界區。
     ✅ **2026-08-30 逐行重驗仍然成立**：`LockManager.hpp:18-21` 的 `LockState`
     只有 `isLocked` 與 `expiryTime` **兩個欄位**，仍然沒有 owner／token；
     `unlock()`（`:236-251`）只認鎖的**名字**，不認**誰**在呼叫。
     ⚠️ `unlock()` 這一週確實改過（`1145372` 讓它回 bool、釋放沒人持有的鎖改回 412），
     **但那是「有沒有被持有」，不是「被誰持有」**——**擁有權的洞原封不動**。
     ⏳ **2026-09-02 補：token 已經存在，但沒有接線 ⇒ 本條仍 OPEN。**
     A-9 的修法（`3dfa51cc`，變異閘 23/23）帶進了 `leaseId`，**那正是②要的 owner token**；
     但 `setRequireLeaseId()` **預設關、而且沒有任何呼叫端**。
     🔑 **所以「A-9 修好了」不蘊涵「B-2② 修好了」**——這是 [[existence-is-not-wiring]] 在同一週的第二個實例。
     解鎖條件＝接線 ＋ 跨 repo 的協定改動（`LockState` 要長出 owner 欄位，七個姊妹 app 都會看到）。
- **實際影響**：Energy-App 與 TE-App 都取同一把 `routing_lock`，各自 6 次/分鐘。
  任何超過 TTL 的持有都開啟「兩個 app 都以為自己擁有網路」的窗口
- **⚠️ 更大的脈絡**：這條擋住了整個併發控制的路——見 memory
  `ndtwin-cannot-do-either-concurrency-control`
- **證據**：實測，`scratch/phase2/FINDINGS.md` E3/E4；round-2 的 F-11 是同一族

### B-2d 三個鎖端點會把「沒指名鎖」的請求代入 `routing_lock` —— 從 B-2 拆出

- **狀態**：🟢 **RESOLVED（2026-08-30，`4ee086f`＋`87d272f`）。** 2026-08-30 讀碼確認。
  **本條是 08-30 對帳時從 B-2 拆出來的**：它與 B-2 共用端點但**是不同的缺陷**，
  而且**只有它被修了**——把它跟 B-2 綁在同一條裡，會讓 B-2 看起來像是修好了。
- **平面**：兩者（純 kernel）
- **失效方向**（當時）：靜默 ＋ **主動誤導**（回覆裡指名一把呼叫端從沒提過的鎖）
- **曾經發生什麼**：`/ndt/acquire_lock`、`/ndt/renew_lock`、`/ndt/release_lock` 三個端點各自
  在行內解析、**先把預設值指派好**，再用 `catch (...)` 吞掉解析錯誤往下走。於是
  **①body 不是 JSON、②JSON 裡沒有 `type`、③`type` 指名一把不存在的鎖**，
  三種完全不同的情況**全部落到 `routing_lock`**——那正是序列化真實交換機寫入的那把鎖。
  🔑 **最傷的不是亂碼那一種**：一個持有 `power_lock` 的 app 不帶 body 送 renew，
  **延長的是別人的 routing 租約**，自己被回 200 `"renewed"`，
  而它自己的租約**一秒沒有被延到**。release 同理，**兩把鎖同時錯、任何地方都沒有錯誤訊息**。
- **修法**：抽出**單一**解析接縫 `LockManager::parseRequest`
  （`include/ndt_core/lock_management/LockManager.hpp:102-147`）＋
  單一訊息表 `describeError`（`:162-184`），三個端點共用
  （`src/ndt_core/http/HttpSession.cpp:1924`／`:1978`／`:2038`）。
  **什麼都不再預設**：`type` 沒指名就是 400、**而且不碰任何鎖**；
  `ttl` 仍然有預設，理由寫在碼裡——**它是時長不是標的，弄錯不會讓請求作用到別的東西上**。
  狀態碼也分開了：**request 錯 = 400**（acquire 舊碼回 423、renew/release 回 412），
  **狀態錯才是 423／412**——「你該重試」與「你的請求是錯的」不再共用一個碼。
- 🔑 **修法自己做了呼叫端普查才拿掉 fallback**：三個 release 呼叫端
  （`Energy-Saving-App/src/app/http.cpp:461`、`Traffic-engineering-App.py:85`、
  chaos harness `probes.py:206`）與契約測試**全都明送 `type`**
  ⇒ **那個「文件說 body 可選」的預設，沒有任何使用者**。
- ⚠️ **本條 RESOLVED 不擴及 B-2 的兩條**（過期續約、無 owner）——見 B-2 的狀態行
- **證據**：讀碼（2026-08-30，基準 `1208d22`），**本輪未實跑**；
  修法 commit 訊息記載 08-29 曾以狀態判準實跑驗過 acquire 那一支
  （`"{this is not json` 回 `{"status":"locked","type":"routing_lock"}`、第二個 client 隨即取不到鎖）

### B-2b 🔴 一個單引號讓 kernel 指控一個健康的元件 —— 而且訊息與真實故障無法區分

- **狀態**：🟢 **RESOLVED（2026-09-02，`051faf12`）**——`utils::execArgv`（fork+execvp、**不經 shell**）
  取代裸 `popen`，全部站點一次掃完（Adam 08-31 裁「全部站點掃完才合」），並加零殘留 grep 守衛；
  `OpResult::notSent`(500) 與 `unreachable`(502) 分家，兩個從來沒有 timeout 的 curl 也補上了。
  build ok、ctest 全綠、整合樹 build 0 error、**ctest 870/870**；Python 守衛紅→綠由 auditor 跑過。
  🔑 **整合時這個守衛先紅了一次，而那是它做對了事**：`test_shell_command_construction.py` 抓到
  **A-4f 分支新加的兩個 shell 站點**（`OVSPowerStrategy.cpp` 的 `sudo ifconfig …`／`sudo ovs-vsctl … create sflow …`
  ＋一個 read-back `popen`）——跨分支互動，守衛照設計推定有罪。A-4f 那兩處已在整合分支改成 `execArgv`
  （`b6bdb5b2`，含新的 `executeArgvCommand` 縫與雙份 double），守衛在 `36d832f5` 上 **7/7 綠**（auditor 重跑）。
  站點清單剩下的正是分類表列的四個（1 `std::system`、1 `popen`、2 `executeSystemCommand(cmd)`，全非請求可控）。
  〔原狀態：OPEN。**round 4 新發現**，是 B-4（模擬案例引號）的第三個實例〕
- **平面**：兩者
- **失效方向**：靜默 ＋ **主動誤導診斷**
- **會發生什麼**：`HttpRoutingStrategyBase::post` 把 `body.dump()` 內插進 shell 的單引號裡沒有
  跳脫（原始碼註解自承）。match 裡有一個 `'` → **`/bin/sh` 語法錯誤 → curl 從沒執行** →
  `splitBodyAndStatus` 拿到 status 0 → kernel 回報：

  ```
  no response from <component> at <url> within 5s
  ```

  **它指控一個它根本沒有連過的健康元件。**
- **🔑 這條真正的傷害不是它會壞，是它會把除錯的人送去錯的地方。**
  round 4 同時測了「控制器真的掛掉」的情況（實驗 5），得到**一模一樣的訊息**——
  所以出事時 log 無法區分「我的請求壞了」和「對方掛了」
- **實務觸發**：TE app 目前只送數字與 IP，所以不會自然發作。但輸入檔路徑、device name、
  intent 文字這些欄位都可能含引號

#### 🔴🔴 2026-08-28 增補：**上面整條只分析了「意外」的引號。「故意」的引號嚴重度差一個級別**

本條原本的結論是**診斷被誤導**（可用性 ＋ 誤指健康元件）。那是一個**不小心**打進引號的人會遇到的事。
一個**故意**送引號的人得到的不是語法錯誤，是**命令執行**：

```
單引號讓字串「壞掉」  →  單引號讓字串「結束」，後面接的是命令
{"...": "x'; <command>; echo '"}      ← json::dump() 不跳脫 ' ⇒ 原樣進 /bin/sh
```

**完整的鏈是既有的，本條自己就寫了其中一段**（「match 裡有一個 `'`」＝北向送的 match 值會走到這裡）：

| # | 環節 | 依據 |
|---|---|---|
| 1 | 北向 API 監聽 **`0.0.0.0`，不是 localhost** | `ControllerAndOtherEventHandler.cpp:90`：`tcp::endpoint{tcp::v4(), NDT_PORT}` |
| 2 | 北向送的 match 值會流進南向 body | **本條自己的例子** |
| 3 | `body.dump()` 內插進單引號，`json::dump()` 不跳脫 `'` | `HttpRoutingStrategyBase.cpp:76-84`（原始碼註解自承） |
| 4 | `utils::execCommand` 用**裸 `popen()`** ⇒ 經過 `/bin/sh -c` | 本檔 §A 已記載 |

⇒ **能連到 port 8000 的人，可以用 kernel 的身分執行命令。** 共 **14 個南向 curl 呼叫點**共用這個構造；
`SimulationRequestManager.cpp:118-125` 是第二個已確認的入口，其註解同樣自承。

⚠️ **「14」這個數字重數不出來（2026-08-30，`1208d22`）—— 結論不動，但引用前要知道。**
本輪逐一追執行器重數，得到 **11 個**走 `utils::execCommand` 的 curl 構造點：
`TopologyAndFlowMonitor.cpp:472/485/498`、`HttpRoutingStrategyBase.cpp:82`、
`SimulationRequestManager.cpp:124` 與 `:150`、`FlowLinkUsageCollector.cpp:2496`、
`DeviceConfigurationAndPowerManager.cpp:222/820/835/848`。
第 12 個（`P4PowerStrategy.cpp:82`）走的是 `executeSystemCommand`（`std::system`）**不是** `execCommand`
——**同樣經過 `/bin/sh -c`，所以暴露面相同，但不屬於這個計數**。
**原文那個 14 是用什麼母體數的，本輪查不出來**（一個可能是 `HttpRoutingStrategyBase.cpp:82`
被展開成它服務的 10 個 `post()` 動詞，那樣會得到 20，也不是 14；**這是推測不是結論**）。
🔑 **這不影響本條的任何判斷**：漏洞成立與否取決於**構造存在**，不取決於它有幾份；
**「不要在單一呼叫點加跳脫」的修法規則照舊**，只是那句話涵蓋的是 11（＋1）個地方而不是 14 個。

⚠️ **`validateRequestBody()` 只檢查形狀，不是修補**——`SimulationRequestManager.cpp:115-121` 的註解
明文這樣寫，這裡重述是因為「有驗證函式」很容易被讀成「有防護」。

🔑 **為什麼它被低估了一整個級別，這比漏洞本身更值得記：**
本條的「實務觸發」寫的是「**目前只送數字與 IP，所以不會自然發作**」——
**那是一句關於「意外」的話，卻被拿來給整條定級。**
**「不會自然發作」不等於「不會發作」**：自然發作的機率由正常使用決定，
**故意發作的機率由有沒有人想這麼做決定**，兩者無關。
⇒ **凡是分析「這個壞掉的輸入會怎樣」的條目，都要再問一遍「有人故意送這個輸入會怎樣」。**

**修法不變、優先級改變**：仍然是「一次做完、所有呼叫點、改用 argv 執行器」（見上面兩處註解，
它們都明說不要零星修補）。**不要在單一呼叫點加跳脫**——那會讓其餘的看起來已經被處理過
（原文寫「13 個」，依上面的重數應為 10 個＋走 `std::system` 的那 1 個）。

📌 **本增補由 DeepSeek 在設計 chaos harness 的行動面時獨立指出**，審查員逐項複驗：
四個環節全部親自看過原始碼確認。**它找到的不是新缺陷，是一個既有條目沒有寫完的那一半。**

#### 📌 2026-09-02 fix-design 對帳：一個根、三個站點，外加四件條目沒記的事（讀於 `4cbec52d`）

- **嚴重度定名**：**未認證遠端命令執行（RCE）**。北向 `ControllerAndOtherEventHandler.cpp:90`
  `tcp::endpoint{tcp::v4(), NDT_PORT}`＝綁 `0.0.0.0`；`HttpSession.cpp` 內 grep `Authorization`
  只命中 CORS 白名單（`:127`），**沒有任何驗證**。〔親自讀過（auditor 覆核兩處）〕
- **一個根三個站點**：`HttpRoutingStrategyBase.cpp:82-84`、
  `SimulationRequestManager.cpp:124-125`（B-4）與 `:150-151`（`onSimulationResult`）。〔親自讀過〕
- 🔴 **① 條目沒記：`app_register` 的 `simulation_completed_url` 落在雙引號裡，`$(...)` 一個引號都不需要。**
  取值在 `HttpSession.cpp:1489`、存進 `ApplicationManager` 在 `:1492`，之後被內插進
  `SimulationRequestManager.cpp:150` 的 `curl -s -X POST \"" << apiUrl << "\"`。
  **雙引號內 `$(...)` 與反引號仍會被 shell 展開** ⇒ **任何「拒絕 `'`」的輸入過濾都擋不住它**
  ——而那正是最可能被順手加上的那種修法。
  ⇒ **這是「不要零星加跳脫」這條既有規則的獨立證據**：零星修法會照著已知字元表做，而這條不在表上。〔讀碼推論〕
- 🔴 **② 條目沒記：兩個成因在同一行合流的確切位置。**
  `splitBodyAndStatus`（`HttpRoutingStrategyBase.cpp:19-30`）在找不到狀態行時
  `return {output, 0}`——**「curl 從沒被 exec」與「curl 跑了但連不上（`%{http_code}` = 000）」
  產生位元相同的 `status == 0`**（`:17` 的註解自承後者），
  然後 `:91-95` 把兩者一起判成 `no response from … within 5s`。
  🔑 **鑑別資訊存在但被丟掉**：`pclose` 的 rc（sh 語法錯誤＝2）足以分辨，
  而 `execCommand` 只把它印到 cerr（`Utils.hpp:558-566`）。
  ⇒ **誠實的修法必須把 rc 帶回呼叫端，不是只換一個訊息字串。**〔親自讀過〕
- 🔴 **③ 條目沒記：`HttpSession.cpp:1363` 的 202 body 是手工串接的 JSON**
  （`std::string("{\"status\":\"") + resp + "\"}"`，`resp` 是 curl 的原始輸出、未跳脫）
  ⇒ 模擬伺服器只要回一個含 `"` 或換行的 body，**kernel 自己的 202 回應就是壞掉的 JSON**。
  同族還有 `IntentTranslator.cpp` 的 22 處手工 JSON，**而同一個檔 `:235-265` 已經有用
  `json{...}.dump()` 做對的寫法** ⇒ 不是「還沒學會」，是**已有正確做法但沒被貫徹**。〔親自讀過〕
- 🔴 **④ 條目沒記：`ApplicationManager::buildExportsPurgeCommand`（`:202-220`）做了 BRE 跳脫
  （`.*[]^$\/`）但沒有做 shell 跳脫**，而結果被放進 `'…'` 裡；`'` 不在那份表上。
  **今天不可從請求觸發**（`folder` 由 `int appId` 組成），但它是這一族最好的教學範例：
  **「有跳脫」不等於「跳脫了會被解讀的那一層」。**〔親自讀過〕
- ⚠️ **上面「11 個」「14 個」兩個計數都對不回來，行號也全數漂移**：
  本輪逐一追執行器得到 **`utils::execCommand` 呼叫點 19 個**；
  條目列的 `TopologyAndFlowMonitor.cpp:472/485/498` 現在只對應**一個**構造點（`:475`，執行在 `:493`）、
  `FlowLinkUsageCollector.cpp:2496` ⇒ `:2524`、`DeviceConfigurationAndPowerManager.cpp:222/820/835/848`
  ⇒ `:225`／`:823`／`:838`／`:851`；走 `std::system` 的 `P4PowerStrategy.cpp` 是 **3 處**（`:83`／`:121`／`:190`）
  不是條目寫的 1 處。**一個可否證的假說**：`DeviceConfigurationAndPowerManager.cpp` 的 `execCommand`
  呼叫點**恰好 14 個**，而該檔 `:579` 註解寫「13 snmpget/snmpwalk sites」＋relay 1 個。
  🔑 **結論不動**：漏洞成立與否取決於**構造存在**，不取決於它有幾份；
  ⇒ **本輪起改為給可重跑的指令，不給數字。**〔親自讀過〕
- ℹ️ **目錄名更正**：條目寫 `event_handler/`，實際路徑是 `src/ndt_core/event_handling/`。〔親自讀過〕
- ✅ **Python proxy 不在這一族裡**：`proxy_agent/` 底下 `subprocess|os.system|shell=True|popen|
  check_output|Popen` **零命中**，`api_routes.py` 全程 FastAPI＋`JSONResponse`。〔親自讀過〕
- ⚠️ **本節全部是讀碼（2026-08-31／09-02，基準 `4cbec52d`）**：沒有建置、沒有執行 kernel、
  沒有發送任何請求。修法分支的 Python 測試由 auditor 重跑（4 綠 rc=0；倒回
  `HttpRoutingStrategyBase.cpp` ⇒ rc=1、2 紅）〔實測，auditor 重跑〕；**C++ 側 UNVERIFIED**。
- **證據**：實測雙平面對照，`scratch/round4/FINDINGS-round4.md` 實驗 2 ＋ 實驗 5

### B-2c P4 proxy 對 CIDR 形式的 `ipv4_dst` 回 500（未處理的 `OSError`）

- **狀態**：🟢 **RESOLVED（2026-08-31）**——修法＋變異閘（M-1〜M-5 全殺、49/49＋8/8）＋
  **live 四驗全 PASS**：CIDR ⇒ 400、body 引呼叫端原字串 `"10.0.0.5/32"`（剝去完整出現後
  **零個裸替換值**）、含「No rule was installed」；accept-path 對照 200；B-2c-b（數值欄位仍
  500）照註冊仍開、只記錄未修。round 4 發現；2026-08-30 讀碼重驗（`1208d22`）
- **平面**：P4
- **失效方向**：吵（500），但錯誤沒有說明原因
- **機制**：`route_flow` 寫死 `/32`，然後把呼叫者給的值直接丟進 `inet_aton`——
  值本身若已是 CIDR 形式（`10.0.0.5/32`）就丟出未捕捉的 `OSError`
- 📌 **現行位置（本輪補上，原文沒有給行號）**：寫死 `/32` 在
  `p4_proxy/proxy_agent/topology_manager.py:767`，值從 `:717` 的
  `match_dict.get("nw_dst") or match_dict.get("ipv4_dst")` 原樣傳進來；
  `inet_aton` 在 `p4_proxy/proxy_agent/p4_client.py:819`，**且落在 `try:` 之外**
  （該 `try` 從 `:836` 才開始、只捕 `grpc.RpcError`）。delete 路徑同形（`p4_client.py:899`）。
  上游沒有任何一層會轉譯它：`api_routes.py:229-235` 只捕 `UnsupportedMatchError`、
  `_flowentry_body`（`:186-198`）只捕 `ValueError`，而
  `unsupported_match_fields` 驗的是**欄位名不是值**
- **把 kernel 排除在外也能重現**（直接打 proxy）
- **🔑 2026-08-30 增補：本條的觸發面比原文寫的寬，而且 repo 內就有生產者。**
  原文讀起來像「要有人手動送一個怪值」。實際上：
  - `unsupported_match_fields` 驗的是**欄位名**，不是**值** ⇒ `nw_dst` 是合法欄位，直接放行
  - **三個動詞都中**：`route_flow`／`unroute_flow`／`modify_flow`，
    分別落在 `p4_client.py:819`／`:899`／`:948` 的同一個 `inet_aton`
  - **來源側也中**：5-tuple 路徑的 `_encode_5tuple_value`（`p4_client.py:687`）
    對 `nw_src`／`ipv4_src` 走同一個 `inet_aton` ⇒ 只修目的端會**看起來修好了**
  - **🔴 repo 內就有生產者**：`IntentTranslator.cpp:359-362` 把驗證代理的 `ipv4_dst`
    原樣複製成 `nw_dst`，而 `validation_agent_prompt.txt:113` **明文告訴模型 CIDR 是允許的答案**
    ⇒ 這不是只有手打 curl 才碰得到
- **修法**：在 `topology_manager.py` 加 `check_match_values()`，三個動詞各呼叫一次，
  丟 `MalformedMatchValueError(UnsupportedMatchError)` ⇒ 走 `api_routes` **既有**的 catch 變 400。
  **用 `socket.inet_aton` 自己當判準**（不自己寫更嚴的 parser），所以不會新拒絕今天會動的輸入
- **⚠️ 未涵蓋（同族，另計）**：flow_5tuple 的**數值欄位**
  （`in_port`／`ip_proto`／`tp_src`／`tp_dst` 等）走的是 `int(value).to_bytes(width)`，
  非數字字串仍 `ValueError`、超出範圍仍 `OverflowError`，**兩者都還是 500**。
  本輪刻意不一起修（改動面會擴到編碼寬度表，量測窗內無法驗），**登記待裁**
- **⚠️ 跨 repo 契約**：500→400 對北向是**可見的變更**。`HttpSession.cpp:735-758` 把 4xx/5xx
  原樣穿透，所以 `/ndt/install_flow_entry` 在 P4 模式下的回應會從 500 變 400。
  in-repo 確認無人期待 500（`tools/contract_test/spec.py` 唯二的 `expect_status=[200,500]`
  是 `/ndt/historical_logging`，與此無關；南向 `HttpRoutingStrategyBase.cpp:103` 對 400/500 行為完全相同）。
  **七個 cross-repo caller 未檢查**，清單見證據檔
- **證據**：實測，`scratch/round4/FINDINGS-round4.md` 實驗 2 附帶發現；
  修法與預註冊 `doc/audit/2026-08-30_known-issues-wave/10_seatbelt-evidence.md`

### B-3 historical logging 回 200「已啟用」，但一列都不會寫

- **狀態**：🟢 **揭露 RESOLVED（2026-09-02，`fix/b3-historical-logging-honest-reply` 三顆 commit）；
  🔴 本體仍 OPEN——MININET 下依然一列都不寫。**
  變異閘 **10/10 全殺**，整合樹 build 0 error、**ctest 870/870**。
  修的是「兩個分支在 wire 上分不出來」：`status` 改成可分辨（`not_applicable`）＋穩定的 `reason` token，
  維持 200（`spec.py:789` 鎖 `[200,500]`，08-31 對活 kernel 驗過 51/51，所以不走 501/409）。
  🔴 **三顆 commit 必須一起落**：少了 allowlist 那顆，`check_logs.py` 對**每一次** MININET run 都會變紅。
  ⇒ **這一條的「已修」只涵蓋誠實度，不涵蓋功能。**
  〔原狀態：**OPEN，但回覆已經會講實話了——本條的措辭在 08-20 就過期，清單漏標十天。**〕
  🟢 **揭露部分 RESOLVED（2026-08-20，`aabe605`）**，2026-08-30 讀碼確認並更正本條目
  （T-4 輪 R-1 實跑觀察到現行形狀）。
  🔴 **沒有 RESOLVED 的是本體**：MININET 下**仍然一列都不會寫**，
  修的是「回覆不再謊稱有在錄」，不是「開始錄」。
  🔑 **可判斷的欄位是 `recording`，不是 `status`**（兩分支都回 200 "success"）——
  契約自 2026-08-31 起強制斷言它（`spec.py` required `recording: Bool`，對活 kernel 51/51 驗過）；
  網站 API 頁與 `doc/2026-01-02_ndt_api.md` §39 同步載明三種 shape。
- **平面**：兩者
- **失效方向**：靜默 → **現在是「誠實但仍不可由狀態碼分辨」**（見下）
- **會發生什麼（現行，`1208d22`）**：`POST /ndt/historical_logging?state=enable` 回
  **200**，body 是
  `{"status":"success","recording":false,"message":"Historical data logging is enabled, but this deployment does not record: the recorder is only started outside MININET mode, so no rows will be written."}`
  （`src/ndt_core/http/HttpSession.cpp:1801-1810`，判準是
  `include/ndt_core/data_management/HistoricalDataManager.hpp:107` 的
  `canRecord() { return m_mode != utils::DeploymentMode::MININET; }`）。
  **零筆寫入這件事沒有變**，變的是它現在會說出來。
- 🔴 **新的殘留缺陷，比舊的窄但沒有消失**：**兩個分支都回 200 且都是 `"status":"success"`**
  （`HttpSession.cpp:1804` 與 `:1813`），**只有 `recording` 與 `message` 兩個欄位不同**。
  ⇒ **看狀態碼的呼叫端、或看 `status` 欄位的呼叫端，仍然分不出
  「已經在錄」與「這個部署根本錄不了」**——而**後者是本專案每一次實跑都會走到的那一支**。
  ⚠️ **而且這個端點在 Developer Manual 上沒有任何條目**（41 條 route 裡 12 條無文件之一）
  ⇒ **呼叫端兩邊都拿不到訊號：wire 上分不出來，手冊裡查不到**。
  正本 `doc/audit/2026-08-30_live-full-stack-round/FINDINGS-T6-developer-manual-api-page.md`
  （補文件已開工單 **T-13**）
- **曾經發生什麼（修法前）**：回 200 "Historical data logging has been enabled."，然後**零筆寫入**，
  kernel log 裡**從來沒有** `HistoricalDataManager started.`
- **機制（本體，未修）**：`HistoricalDataManager::start()` 在 MININET 模式直接 return，
  而 `writeSnapshot` 只從 `run()` 呼叫——那條執行緒從沒啟動。REST 端點只翻旗標。
  `stack.sh` 永遠用 `--mode mininet` 啟動 kernel。
  ```cpp
  if (m_running.exchange(true) or m_mode == utils::DeploymentMode::MININET)
  {
      // Already running
      return;
  ```
  ⚠️ 註解只描述了條件的**前半**。「MININET 模式下這個元件根本不啟動」這件事
  在原始碼裡沒有任何一個字說明，讀的人會以為早退只是因為重複呼叫。
  📌 **這半句已經不成立了**：`HttpSession.cpp:1794-1800` 現在把整件事寫在 handler 的註解裡，
  並且說明**為什麼仍然回 200**——「旗標真的設了，需要被講出來的是後果」。
  **早退本身沒改**，改的是有沒有人把它寫下來。
- 📌 **機制補正三點（2026-09-02 fix-design 對帳，讀於 `4cbec52d`）**：
  - **早退在 `src/ndt_core/data_management/HistoricalDataManager.cpp:51`**，
    而 🔴 **`or` 是左到右求值 ⇒ `m_running.exchange(true)` 在 MININET 下照樣執行**
    ⇒ **物件被標成 `m_running == true`，背後卻沒有執行緒**。
    任何未來想拿這個旗標問「錄製器在跑嗎」的碼都會拿到「在跑」——
    **跟端點說的是同一個謊，只是低一層**；所以**不能直接把 `m_running` 曝出去當 liveness**。〔親自讀過〕
  - 🔴 **`canRecord()` 是模式謂詞，不是存活謂詞**：TESTBED 下沒人呼叫 `start()`、
    或 `OUTPUT_DIR`（`hpp:49` 寫死 `/home/of-controller-sflow-collector/LinkData`，
    **本機 root 所有而 kernel 非特權**）拒絕每一次寫入時，`canRecord()` 一樣回 true、
    端點一樣回 `recording:true`，而寫入零筆。**同一個病在 TESTBED 那半邊沒被治。**〔親自讀過〕
  - `m_loggingEnabled` 預設 **true**（`hpp:113`）⇒ `?state=enable` 在新起的 kernel 上本來就是 no-op。〔親自讀過〕
  - ℹ️ **行號漂移**：條目引的 `HttpSession.cpp:1801-1810`（基準 `1208d22`）在 `4cbec52d` 是
    **`:1905-1913`**，兩個 `"status":"success"` 分支在 `:1908` 與 `:1917`；`canRecord()` 仍在 `hpp:107`。〔親自讀過〕
  - 📌 **回 200 這件事有一個共同根**，見 §C 的 **C-2**：
    `buildResponse()` 以 `status::ok` 建構，**沒設狀態碼就是 200**。
- **實測排除了替代解釋**：不是「輸出目錄不可寫」——**根本沒有嘗試寫入**
- **證據**：修法前實測，`scratch/phase2/FINDINGS.md` E5；
  現行形狀＝2026-08-30 讀碼（`1208d22`）＋ T-4 輪 R-1 的實跑觀察。
  ⚠️ **R-1 這一輪自己判定為 UNTESTABLE**（`PRE-ROUND-R1-determination.md`：
  七個 repo 掃過，**沒有任何消費端呼叫這個端點**，所以「沒有人壞掉」不能當成「修法安全」的證據）
  🔴 **另一份宣稱是儀器假象，不要引用**：chaos harness 的 `_c07` 控制組記的
  「The control reproduces B-3 … It verified true」（`2026-08-28_chaos-harness/05_first-live-run.md:203`）
  **是 404 造出來的**——見文末儀器缺陷區的 **G-3**。

### B-4 模擬案例：任一欄位含單引號 → 回 202 但請求從沒送出

- **狀態**：🟢 **RESOLVED（2026-09-02，`051faf12`，與 B-2b 同一次修法）**——同一個 `execArgv`
  執行器涵蓋這裡的兩處內插（`SimulationRequestManager.cpp:124-125`／`:150-151`），
  202 改成等模擬伺服器回答之後才送，`HttpSession.cpp:1363` 的手工串接 JSON 也一併改用函式庫。
  ⚠️ **與 B-2b 共用同一個未關的尾巴**（整合樹上守衛因 A-4f 的新站點而紅），見 B-2b 的狀態列。
  〔原狀態：OPEN（程式碼註解已自承）。2026-08-30 讀碼重驗仍然成立（`1208d22`）：
  內插逐字在 `SimulationRequestManager.cpp:124-125`，同一個檔案裡還有第二處同形的（`:150-151`），
  而 `:118-122` 的註解仍然寫著「不要在這裡零星加消毒」〕
- **平面**：兩者
- **失效方向**：靜默
- **會發生什麼**：`received_a_simulation_case` 的欄位含 `'` → API 回
  **`202 {"status":""}`**，請求**從沒離開 kernel**，log 裡是 `sh: 1: Syntax error`
- **機制**：`handleReceivedSimulationCase` 只驗形狀，然後
  `SimulationRequestManager.cpp:115-133` 把原始 body **字串內插**進
  `curl ... -d '<body>'` 的 shell 指令，並把指令印出的東西當成 202 的 status 回傳。
  輸入檔路徑本來就可能含引號——那正是那個欄位的用途。
- **證據**：實測，`scratch/phase2/FINDINGS.md` E12

### B-5 🔴 kernel 每一次正常關機都以 `terminate called without an active exception` 收尾（abort，不是 exit）

- **狀態**：**OPEN。** 2026-09-02 由 run-01 的 auditor 補驗在 **VM 上讀 log 實證**；
  **尚未在 Adam 這台機器上重現**——本條的證據全部來自
  `nslab:~/ndtwin-vm-usertest-01-sonnet/`（run-01 結束時的狀態）。
  🔴 **所以「每一次」的定義域是那台 VM 的四次關機，不是「所有部署」。**
  修法排在示範之後、已開單。
  ⏳ auditor 今晚的整機一輪會在**每一次 `ndt down`** 抓 kernel 的 exit code 與 log 末五行，
  那一輪才會把「Adam 這台也一樣」變成觀測。
- **平面**：兩者（在 `main` 的關機路徑上，與資料面無關）
- **失效方向**：**對人是靜默**（示範上看不見，關機序列該印的都印了）、
  **對程式是主動誤導**——**任何讀 exit code 的 harness 都會把一次乾淨的關機讀成失敗**。
- **現象（實測，讀 log；行號本文以 `git show HEAD:` 逐一覆核）**：
  kernel 印完 `main.cpp:430` 的 `All subsystems stopped. Exiting.` 之後**還會再印三行**
  （`ControllerAndOtherEventHandler.cpp:102 already stopped`／`ApplicationManager.cpp:266 cleanupNFS`／
  `FlowLinkUsageCollector.cpp:580 Collector Stops`），**然後才是那一行 abort**。
  ⇒ 🔑 **最後一行 log 不是 `Exiting.`，是 `Collector Stops`**——
  查的時候不要只看 `Exiting.` 就以為它之後什麼都沒發生。
  四份 log 全中，一次不漏：
  `logs/av2_kernel_1.log:208`（共 208 行）／`logs/av2_kernel_2.log:45`（共 45 行）／
  `logs/av_kernel_1.log:209`／`logs/av_kernel_2.log:45`，全在 `doc/audit/2026-09-02_manual-usertest/run-01-sonnet/auditor-verification/`。
  tester 自己那一輪的 `kernel_p4.log` 同句（**轉述 README，本文未開該檔**）。
- **機制**：**未定位。** `terminate called without an active exception` 是 libstdc++ 在
  **沒有在處理例外時**呼叫 `std::terminate` 印的，最常見的兩個成因是
  **①一個仍 joinable 的 `std::thread` 被解構**、**②解構子拋例外**。
  ⇒ **本條沒有指認是哪一個，也沒有指認是哪個物件**；上面那三行 log 只說明它發生在
  collector 停掉之後，**縮小了範圍但沒有定位**。〔讀碼推論〕
- 🔴 **exit code 是 134 這件事是推論，不是量到的——寫清楚免得被引用成觀測**：
  abort ⇒ `SIGABRT` ⇒ shell 記 `128+6=134`，這條推理成立，
  **但補驗那一輪沒有記下 kernel 的 exit code**（該目錄裡唯二的 `EXIT=` 都是 127，
  而且是 tmux pane 重現腳本的，與 kernel 無關）。⇒ **今晚那一輪要補的就是這個數字。**
- **為什麼值得單獨開一條而不是併進別條**：本文件已經有一整族「失敗回報成功」的條目，
  **這一條是反方向的——成功回報失敗**。它不會讓任何人在台上看到問題，
  但它會讓每一支「跑完檢查 rc」的腳本得到錯的答案，而那正是 §G 那些儀器缺陷的養分。
- **證據**：`doc/audit/2026-09-02_manual-usertest/run-01-sonnet/auditor-verification/` 的 `logs/av*_kernel_*.log`（實測，讀 log）；出處：該目錄的 `README.md`（trunk `01e642e8`；auditor 裁定在該檔 `:39`）。
  ⚠️ **本條未在 Adam 的機器上重現、未定位到具體物件、exit code 未量。**

### B-6 🔴 用 API 宣告的 link failure 會被 30 秒的拓樸輪詢靜默撤銷（可見壽命上界 30 s）

- **狀態**：**OPEN。** 2026-09-04 夜巡實測（5/5 重現，機制定案）。
  **Adam 2026-09-05 裁定語意：宣告應該優先，這是缺陷**——不是「輪詢比較準」的設計取捨。
  修法單 **W8**（`W8-link-failure-declaration-must-win.md`，2026-09-05 開，**只開不修**；
  三個選項尚未拍板）。🔴 **W8 寫在 09-05 夜巡 session 的 scratch 裡，`scratch/` 不進版控**
  ⇒ 這份單子不在 repo，引用前先向該 session 要。
  文件側已落：`doc/2026-01-02_ndt_api.md` §1／§2 已從「事實描述」改寫成「已知缺陷、待修」。
- **平面**：兩者（缺陷在 kernel 的拓樸輪詢，與資料面無關；實測跑在 OVS 10-switch）
- **失效方向**：**樂觀 ＋ 靜默**——被宣告成壞掉的東西回報成健康，而且沒有任何 log 記錄這次翻轉
- **會發生什麼**：`POST /ndt/link_failure_detected` 回 **200**，雙向邊在 0.02 s 內變 `isUp=false`；
  **≤30 s 後那條邊自己變回 `isUp=true`**，而 `/ndt/link_recovery_detected` 從來沒有被呼叫。
  `kernel.log` 只有 `handleLinkFailure] link failed on 1:1 -> 5:1` 那行，**沒有對應的 recovered 行**
  ⇒ **宣告被推翻，而唯一的證據是「圖自己變了」。**
- **機制**：拓樸輪詢對 Ryu `/v1.0/topology/links` 回報的每一條 link **無條件**設 `isUp = true`
  （`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1791-1795`，`updateLinks`，函式起點 `:1695`），
  **整個輪詢沒有任何 `isUp = false` 分支**——它只能把 link 抬起來，不能放下去。
  週期在 `:3195-3197`：**起動後 90 s 內 5 s 一次，之後 30 s 一次**（`kOnceConverged = 30s`）。
  🔑 **這段碼自己寫下了它依賴的不變式，而那條不變式只對「真實」故障成立**（`:3146-3150`）：
  *"a poll can fill in what was missed but cannot resurrect an edge the push path correctly took
  down"* ——它成立是因為 **Ryu 會把斷掉的 link 從清單裡拿掉**。用 API 宣告的故障沒有斷線背書，
  Ryu 照樣列出那條 link，於是輪詢把它復活。**不變式沒有錯，是它的前提沒有被寫進條件裡。**
- **窗口**：宣告後 **0–30 s 均勻分布，上界 30 s**（起動後 90 s 內是 0–5 s）。
  實測翻回時刻每次緊跟輪詢後 ≈0.6 s；先前一輪量到的 0.457／9.454／18.453 s
  **是同一個 30 s 輪詢在不同相位被撞到，不是三種行為**。
- 🔑 **對照組（真斷鏈不受影響——這是把缺陷定位出來的那一組，不是免責條款）**：
  `tc netem loss 100%` 兩端一起下，Ryu 自己的 watchdog POST 這兩個端點、**而且** Ryu 把該 link
  從 `/v1.0/topology/links` 拿掉 ⇒ 輪詢沒有東西可以復活。
  netem 上線後 **13.3 s 可見 DOWN、60 s 後仍 DOWN**；netem 撤掉後 **1.0 s 回 UP**。
  ⇒ 輪詢只能表達「我同意控制面看到的」，所以它撐住被觀測到的故障、推翻被宣告的故障。
- 🔴 **影響面**：**任何用 `/ndt/link_failure_detected` 注入故障、然後量超過幾秒的實驗，
  在後半段的注入條件不成立**——而端點回 200、文件先前沒寫這件事。
  這一條接到「注入後必須斷言注入成功」那條紀律上：要在**整個**量測窗內從 `/ndt/get_graph_data`
  重讀邊的狀態，不能只信那個 200。**chaos harness 若走這條路徑注入鏈路故障，同一句話適用。**
- **繞法**：改用 `tc netem`（真斷）注入；或把量測窗壓進單一輪詢週期內並在窗尾複查邊狀態。
  ⚠️ **不要用 `ifconfig down`**（專案硬規矩：會弄壞整台交換機）。
- **證據**：實測，`scratch/overnight-2026-09-04/rounds/03-R2-concurrency.md` §3-2（R2-B）；
  raw `scratch/overnight-2026-09-04/logs/r2-20-linkfail-probe.log`（宣告臂，5 trial 逐字）與
  `logs/r2-21-netem-control.log`（netem 對照臂）。同一現象較早的一輪記在
  `scratch/overnight-2026-09-04/FINDINGS-CANDIDATES.md` **OV-4**（3/5、相位猜 ≈9 s，**已被 R2-B 取代**）。
  🔴 **上列 raw 全在 `scratch/`，不在版控**——引用前先確認那個 session 的目錄還在。
  機制行號由 2026-09-05 本次登記時**開檔覆核**於 trunk `4088b237`，不是抄 finding 的偏移量。

### B-7 `set_switches_power_state` 對不存在的 IP 回 500，而同一個 IP 的 GET 回 404

- **狀態**：**在 trunk 上 OPEN。修法在分支 `integrate/2026-09-03-auditor-merge` 的
  `f8dbad66`（工單 W6），未併入**（查於 2026-09-05，trunk `4088b237`：
  `git merge-base --is-ancestor f8dbad66 HEAD` 為否）。登記理由見 B-8 之後那一段。
- **平面**：兩者
- **失效方向**：**悲觀 ＋ 誤導**——客戶端錯誤被報成伺服器故障
- **會發生什麼**：`POST /ndt/set_switches_power_state?ip=203.0.113.9&action=off` →
  **`500 {"error":"Failed to change switch power state"}`**，而 `GET /ndt/get_switches_power_state`
  對**同一個位址**回 **404**、`action=sideways` 回 **400**。一個位址、兩個端點、兩種判決。
- **機制**：handler 把下游**所有**失敗原因塌縮成一個 `bool`
  （`src/ndt_core/http/HttpSession.cpp` 的 `handleSetSwitchesPowerState`），
  而「這個 IP 不是我認得的交換機」與「繼電器不接受」在那個 bool 裡沒有差別——
  後者旁邊還有四條**真的是 500** 的 `return false`。GET 那側走例外，
  拿到 `Unknown switch IP` 就回 404。
- **W6 之後的行為**（`f8dbad66`，**尚未在 trunk**）：新增
  `DeviceConfigurationAndPowerManager::knowsSwitchIp`（就是 GET 那側自己的查找，依模式分岔），
  handler 在問 manager **之前**先問它，未知 IP 回 **`404 {"error":"Unknown switch IP"}`**、
  與 GET 同一句；**真正的電源失敗仍然是 500**（鑑別力測試 `ARealPowerFailureIsStillA500`）。
- **證據**：實測 2026-09-04，`scratch/overnight-2026-09-04/FINDINGS-CANDIDATES.md` **OV-2**；
  raw `scratch/overnight-2026-09-04/logs/ovs128-02b-sweep2.log:62-63`（POST 500）、`:24`（GET 404）。
  🔴 **raw 在 `scratch/`，不在版控。** 修法側的紀錄在該分支的
  `doc/audit/2026-09-04_fix-unknown-identifier/FIX-UNKNOWN-IDENTIFIER.md`（**同樣不在 trunk**）。

### B-8 兩個 POST 讀取端點對不存在的 dpid 回 200 與零 —— 「不存在」與「零」不可分辨

- **狀態**：**在 trunk 上 OPEN。修法在分支 `integrate/2026-09-03-auditor-merge` 的
  `f8dbad66`（工單 W6，與 B-7 同一顆），未併入**（查於 2026-09-05，trunk `4088b237`）。
- **平面**：兩者
- **失效方向**：**靜默**——不存在的交換機被報成「有，但沒有流量」
- **會發生什麼**：`POST /ndt/get_num_of_flows_passing_a_switch` `{"dpid":424242}` →
  **`200 {"status":"success","num_of_flows":0}`**；
  `POST /ndt/get_total_input_traffic_load_passing_a_switch` 同型（`..._bps: 0`）。
  ⇒ **與「一台真的存在但沒有流量的交換機」的回應完全相同。**
  對照：`/ndt/install_flow_entry` 對**同一個 dpid** 回 404。
- **機制**：**根本沒有一個查找會失敗**——`dpid` 只被當成邊掃描裡的比較運算元，
  不存在的 dpid 誰都不匹配，累加器停在初值並被當成答案回出去。
  這是「算得出來不等於機制」的教科書實例。
- **W6 之後的行為**（`f8dbad66`，**尚未在 trunk**）：兩個 handler 在掃描之前各加一次
  `TopologyAndFlowMonitor::getSwitchKind(dpid).has_value()`（`install_flow_entry`
  對同一個問題早就在用的那支 validator），不成立回 **404**，措辭沿用既有的 unknown-dpid 契約：
  `{"status":"error","error":"unknown dpid","unknown_dpids":[<dpid>],"detail":"these dpids are not
  switches in the loaded topology; check the dpid, or that the topology file matches the running
  network"}`。🔴 **W6 把兩支既有測試的期望值從 200 改成 404**
  （`TotalInputTrafficLoadWithADpidStillAnswers200`／`NumOfFlowsWithADpidStillAnswers200`，
  空圖 ＋ `{"dpid":1}`），並新增對照 `AKnownButIdleSwitchStillAnswersZero`
  （**真的存在但閒置的 dpid 仍然是 200 ＋ 0**）——**零與不存在，這才第一次可分辨**。
- **證據**：實測 2026-09-04，`scratch/overnight-2026-09-04/FINDINGS-CANDIDATES.md` **OV-3**；
  raw `scratch/overnight-2026-09-04/logs/ovs128-02b-sweep2.log:38-42`。
  🔴 **raw 在 `scratch/`，不在版控。**

> ### 為什麼 B-7／B-8 照樣登記，即使修法已經寫好（2026-09-05）
>
> 一份叫「已知**未修**缺陷」的清單要不要收一條「已經修好、但修法還在別的分支上」的缺陷？
> **本文件已經自己答過兩次，兩次都是收**：
>
> | 條目 | 狀態行 |
> |---|---|
> | **A-13** | 「修法在分支 `fix/b5-kernel-shutdown`，**未併入**」 |
> | **G-11** | 「OPEN（2026-09-02 live round 實測）。相關修法在 `fix/g6-ndt-apps-liveness`（未併）」 |
>
> ⇒ **慣例＝條目照登、狀態維持 OPEN、把分支與 commit 寫在狀態行上。** B-7／B-8 照此辦理。
>
> 三條支持的理由，都是本文件自己的規矩：
> ① **F-1** 已經立過那條線——「翻面的條件是**跑著的那顆 kernel 裡有這個修法**，不是 repo 裡有」。
> 修法在一條**還沒併進 trunk** 的分支上，比「repo 裡有」還要遠一步。
> ② **A-1** 寫著「變異測試跑綠之前不得改標 RESOLVED」，並點名 **A-3 是修好之後被掛 OPEN 八天的反例**
> ——兩個方向的錯都要避免。**現在登記、標 OPEN、指到那顆 commit**，同時避開兩者。
> ③ 這兩個代號原本只活在一份 scratch 的 `FINDINGS-CANDIDATES.md` 裡；不編號進來，
> 之後別處引用會另起代號、兩邊對不上（**§C 那兩套撞號的 F-n 就是這樣長出來的**）。
>
> 🔴 **W6 併進 trunk 之後要回來改這兩條的狀態行**，並照 A-1 的規矩：
> 變異閘（`tests/shell/mutate_unknown_identifier_is_not_zero.sh`）在 trunk 上跑綠之前不改 RESOLVED。
>
> **本次沒有登記的**：09-04 夜巡 `FINDINGS-CANDIDATES.md` 裡的其他候選
> （**OV-1**，以及 S-n／T-n／P4-n 各族）——那些不在 Adam 09-05 的裁決範圍內，本次不代為判斷。
> ⚠️ 該檔的 `OV-n` **只編到 OV-4**（`recon/fixplan.md` §0.1 寫成「OV-1…OV-6」是筆誤，
> 2026-09-05 開檔查證）。

### B-9 🔴 OVS：一次 `set_switches_power_state` off→on 永久切斷該交換機底下的所有主機，而四種儀器都回報健康

- **狀態**：**OPEN。** 2026-09-05 夜巡 R4 實測（128 台 OVS，兩次獨立重現＋三組對照）。
  Adam 2026-09-05 18:0x 裁定：**登記、開單、儀器側先擋住**。
  修法單 **W9**（`W9-ovs-power-cycle-keeps-port-mapping.md`，2026-09-05 開，**只開不修**；
  兩個方向尚未拍板）。🔴 **W9 寫在 09-05 夜巡 session 的 scratch 裡，`scratch/` 不進版控**
  ⇒ 這份單子不在 repo，引用前先向該 session 要。
  儀器側已落：`scratch/overnight-2026-09-05/sweep.py` 的 s4 power off/on 改成**預設不做**
  （要跑帶 `SWEEP_POWER_CYCLE=1`）——這只擋住夜巡自己的 sweep，**產品端點沒有改**。
- **平面**：**只有 OVS。P4 不受影響**（對照見下）
- **失效方向**：**樂觀 ＋ 靜默**——資料面全斷，控制面四種檢查全綠，沒有任何 log 記錄這次重排
- **會發生什麼**：`POST /ndt/set_switches_power_state?ip=<葉節點>&action=off` 再 `action=on`，
  兩次都回 **200 `{"<ip>":"Success"}`**，`ovs-vsctl br-exists` rc=0，Ryu 說那台的流表列數
  **跟 cycle 前一模一樣（130）**——而**那台底下的每一台主機從此 100% loss，直到整個 fabric 重建**。
  128 台的 fabric 上一次 cycle 打死 32 台（s1–s4 各掛 32 台）。
- 🔴 **四種儀器同時說健康**（`logs/r4-20-twin-view-of-dead-leaves.log`，此時 64/128 台主機是死的）：
  ```
    node s3  dpid=3 reachable=True admin_state=on
    dpid 3 edges=34 is_up_true=34 admin_disabled=0
    path 10.0.0.1 -> 10.0.0.65   : {"...","status":"success","switch_count":5}
    ndt status --check rc: 0
    10 switches (10 up, 10 enabled), 128 hosts, 288 edges
  ```
  ⇒ `reachable`／`is_up`／`get_path_switch_count`／`ndt status --check` **四種全部通過**。
- **重現步驟**（逐字照 R4-1；跑在 kernel `4c9e0be1`／helper `6685d3a9`／trunk `68c1dde4`）：
  ```bash
  export NDT_OWNER=overnight-0905
  tools/test_workflow/ndt up ovs            # 128 hosts / 10 switches
  H1=$(ps -eo pid,args | awk '$NF=="mininet:h1"{print $1;exit}')
  H65=$(ps -eo pid,args | awk '$NF=="mininet:h65"{print $1;exit}')
  # 對照組：s3 底下的 h65 現在是通的
  sudo -n mnexec -a "$H1"  ping -c 4 -W 1 10.0.0.65   # 0% loss
  sudo -n mnexec -a "$H65" ping -c 4 -W 1 10.0.0.66   # 0% loss
  # 動作：官方端點，一次 off 一次 on
  curl -s -X POST "http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.13&action=off"
  sleep 5
  curl -s -X POST "http://localhost:8000/ndt/set_switches_power_state?ip=192.168.123.13&action=on"
  sleep 15
  # 實驗組：同樣兩條 ping
  sudo -n mnexec -a "$H1"  ping -c 5 -W 1 10.0.0.65   # 100% loss
  sudo -n mnexec -a "$H65" ping -c 5 -W 1 10.0.0.66   # 100% loss
  ```
- 🔑 **機制——兩個來源各自對，但只在「bridge 從來沒被重建過」時彼此相等**
  （行號由 2026-09-05 本次登記時**開檔覆核**於 trunk `cff98191`，不是抄 finding 的偏移量）：
  - **ofport 號來自 `add-port` 的插入順序，而順序來自 `ovs-vsctl list-ports`（字典序）**：
    power-off 在 `src/ndt_core/power_management/OVSPowerStrategy.cpp:661` 用 `executeListPorts`
    （`:51-54`，`sudo ovs-vsctl list-ports <br>`）抓下當時的 port 名單，`:703`
    `setMininetBridgePorts` 存進 `bridgeConnectedPortsForMininet`
    （`include/common_types/GraphTypes.hpp:397`），然後 `:708` `del-br`。
    power-on 在 **`:471-478`** 照那個順序一條一條 `sudo ovs-vsctl add-port <br> <port>`，
    **沒有帶 `ofport_request`**（全檔零個實例）⇒ OVS 按插入順序發 ofport 1…N。
    `ovs-vsctl list-ports` 的輸出是**字典序**，於是 `sN-eth10` 排在 `sN-eth2` 前面，
    重建後 **port 2 = `sN-eth10`**。
  - **流表裡的 port 號來自靜態拓樸 JSON 的 `src_interface`，與交換機無關**：
    `intelligent_router.py:1432`（switch↔switch）與 `:1429`（switch→host）建圖時
    `port=edge.get("src_interface")`；重灌路徑 `:814`
    `install_all_pair_paths(self._active_net())`（`:703` `_active_net` 在有靜態拓樸檔時回
    `static_net`）→ `:1639` `out_port = edge["port"]`／`:1550`
    `get_host_port` 回 `net[switch][host]["port"]` → `:1663` `OFPActionOutput(out_port)`。
    **重灌完全不讀交換機現在的 portdesc。**
  - ⇒ 設計時的 `sN-ethM` ↔ port M 恆等映射被**寫死在 JSON 那一側**，而交換機那一側在重建後
    改成字典序。**兩邊都沒有錯，錯的是沒有人負責讓它們對齊。**
- **為什麼四種檢查看不到**：`get_switch_openflow_table_entries`／Ryu 只**數列數與動作**，
  而 port 重排**不改列數（130＝130）、不改動作的 port 號、不改 port 總數（34＝34）**——
  唯一變的是「那個號碼接到哪一條線」，沒有任何端點報這件事
  （`logs/r4-19-portdesc-mechanism.log`：dpid 1 未 cycle＝`(1,'s1-eth1'),(2,'s1-eth2')…`；
  dpid 3 已 cycle＝`(1,'s3-eth1'),(2,'s3-eth10'),(3,'s3-eth11')…`）。
- 🔑 **三組對照組（缺陷是這樣被定位出來的，不是免責條款）**：
  ① **同一個 fabric、沒被 cycle 過的 s1／s2**：`h1 -> 10.0.0.2/…/96` 全 0% loss
  （`logs/r4-12/13-*.log`）——邊界正好落在 96／97 之間；
  ② **全新 fabric、一次 cycle 都沒下過**：`ndt up ovs` 之後 128 台全通，含第一輪死掉的
  97/100/128（`logs/r4b-02-control-nopowercycle.log`）⇒ 死因是 power cycle，不是 `ndt up ovs`、
  不是規模、不是 h97+ 那批主機；
  ③ 🔴 **P4 平面免疫**：同一支 sweep、同一個端點、同一台 s4，P4 128 跑完之後 **128 台全通**
  （`logs/r4p4-10-scale-reads.log`）。bmv2 用**明確的 `-i N@sN-ethN`** 建立 port 對應
  （`/tmp/ndtwin_p4_switches.json` 的 `argv`），重啟不重排。
  ⇒ **這是 OVS 平面獨有的缺陷，根因是 bridge 重建後 port 的加入順序，不是「power cycle 這個概念」。**
- 🔴 **影響面**：
  - **任何關開交換機的 app 或實驗**——energy-saving app 的省電動作走的就是這個端點；
  - **`sweep.py` 對 s4 做的那一下**：09-05 夜巡每個上 OVS 128 的角色，**從 arm_up 結束那一刻起
    手上就有 1/4 的 fabric 是死的，而 `ndt status --check` 說一切正常**。該輪 `traffic.sh` 四對
    iperf3 有三對落在 s4，跑滿 120 s 傳了 **0 byte**，取樣行照印
    ⇒ **R4-1 之後的 OVS 流量數字全部作廢**；
  - 這一條接到「注入後必須斷言注入成功」那條紀律上：power cycle 之後要**重讀 portdesc 並與
    流表的 OUTPUT port 對帳**，不能只信那個 200，也不能只數列數。
- **繞法**：**不要在量測期間 power cycle OVS 交換機**；非做不可就在 `on` 之後整個 fabric 重建
  （`ndt down` ＋ `ndt up ovs`），或自行以 ping 矩陣驗證該交換機底下的主機仍然可達
  ——**四種既有檢查都不能當作驗證**。
- **對帳舊結果**：
  - FINDINGS **#67**（「power cycle 弄丟操作者裝的規則且不還原」）的**加強版**——不是弄丟規則，
    是**把轉送全部指到錯的線**，而且**列數對得上**所以「數列數」式檢查看不到；
  - FINDINGS **#42**（128 對 ping 全 100% loss、banner 照印 OK）的**更新**：不是全滅，是
    **剛好被 cycle 過的那台底下的主機**全滅，其餘正常 ⇒ **#42 的「全部」口徑要改成
    「被 power cycle 過的葉節點底下的那些」，該條要重量**（W9 影響面已列）。
  - 🟠 上列兩條歷史條目**本次未開 FINDINGS 原文核對**（R4 角色與本次登記者都只讀轉述）。
- **證據**：**實測 2026-09-05 夜巡 R4**，`scratch/overnight-2026-09-05/rounds/04-R4-scale.md` **R4-1**；
  raw 在 `scratch/overnight-2026-09-05/logs/`：`r4-17-s3-control.log`（對照臂逐字）、
  `r4-18-s3-powercycle.log`（處理臂逐字）、`r4-19-portdesc-mechanism.log`（機制）、
  `r4-20-twin-view-of-dead-leaves.log`（四種儀器）、`r4-12/13-*.log`（同 fabric 對照）、
  `r4b-02-control-nopowercycle.log`（全新 fabric 對照）、`r4p4-10-scale-reads.log`（P4 對照）。
  🔴 **上列 raw 全在 `scratch/`，不在版控**——引用前先確認那個 session 的目錄還在。
  ⚠️ **可信度分級**：資料面與端點的數字是 **R4 角色實測（🟢 對他）**；
  **本條登記者沒有複驗任何一次 live 重現（🟠 轉述）**，只有上面「機制」那一段的 file:line
  是登記者自己開檔查證的（🟢）。**兩者不要混用。**

---

### B-10 🔴 替交換機取個名字，`ndt status --check` 就說「有人動了拓樸檔」

- **狀態**：**OPEN（登記於 2026-09-06）。修法在分支 `fix/w10-nickname-overlay` 上，未併 trunk。**
  照本檔 B-7／B-8 前面那段自己立的慣例（條目照登、狀態維持 OPEN、分支寫在狀態行上），
  以及 **A-1 的規矩：變異閘在 trunk 上跑綠之前不得改 RESOLVED**。
  🔴 **「修好了」對外要先問修在哪個 ref**：這是一條沒併進 trunk 的分支，
  比「repo 裡有」還要遠一步（F-1 立的那條線）。
- **平面**：**兩者**（跟著 `activeTopologyPath()` 走，不是平面的性質）
- **失效方向**：**誤導**——紅字本身是真的，但它說的是一件使用者沒做過的事
- **會發生什麼**：`POST /ndt/modify_nickname`（或 `modify_device_name`）成功之後，
  `ndt status --check` 回 **rc=1**，紅在第 5 列：
  ```
     topology file  sha256 a1446055a12d    != 2266c69cbcd3   CHANGED SINCE up
     - topology file: … has been edited since the ndt up that loaded it; the kernel pulls once and never retries
  ```
  使用者做的是一件完全正常的事（替交換機取名），做完之後「我的環境還可信嗎」這個問句回紅，
  而紅字說的是「**有人動了拓樸檔**」。**比 09-04 的 3998 行安靜，但誤導性更高。**
- **機制**：kernel 把新名字寫回 `setting/<model>.json`；`ndt status --check` 第 5 列比的是
  那個檔的 **sha256**（`tools/test_workflow/ndt` 的 `check_up_target`）。sha256 不數行
  ⇒ **只要 kernel 還寫那個檔，「只改一行」與「`--check` 綠」就不可能同時成立。**
- 🔴 **這一條是 W5（OV-1）的下半場，不是 W5 沒修好**。W5（09-04）把 diff 從 3998 行降到 1 行，
  那一步是對的；09-05 夜巡量出「1 行照樣紅」，**推翻的是 09-04 工單裡「`--check` 會轉綠」那個推論**。
- **兩個對照組**（09-05 R0，證明這是 `--check` 在正常工作、不是它壞了）：
  ① 改過去又改回來 ⇒ 檔案 byte-identical、`--check` rc=0
  ⇒ **紅的原因就是 byte 差異本身**；
  ② 一個與 nickname 完全無關的寫者（R3 改頻寬）拿到**一字不差的同一句話**。
- **修法（分支上）**：Adam 2026-09-05 18:1x 裁 overlay ——
  名字寫到 `setting/` 以外（`.test_run/nickname_overlay/<model>.names.json`）、
  `--check` **指名但不比**、kernel 載入拓樸的最後一步疊回圖上；**模型檔從此對 kernel 唯讀**。
  單子 W10，文件 `doc/audit/2026-09-06_fix-nickname-overlay/FIX-NICKNAME-OVERLAY.md`，
  閘門 `tests/shell/mutate_nickname_overlay.sh`。
  ⚠️ **`ndt status --check` 沒有在真的 lab 上轉綠過**——分支上的證據是 gtest 與離線 fixture 測試，
  **live 補一刀還沒做**。
- **可信度**：紅字與兩個對照組是 09-05 夜巡 R0 的實測（🟠 對本條登記者，我沒複驗）；
  機制那一段的 file:line 與 09-06 的修法是登記者自己開檔查證與實作的（🟢）。**兩者不要混用。**

---

> ### 🔴 B-11／B-12 之前：這兩條的 FINDINGS 編號**撞號了**（登記於 2026-09-07）
>
> 09-05 夜巡把這兩條叫做 **#90／#91**（兩條修法分支的 commit 訊息、兩份 FIX 文件、
> `W3-3b-SUMMARY.md`／`W15-SUMMARY.md` 都是這個號）。
> **但 `doc/audit/2026-09-03_night-rounds/FINDINGS-COVERAGE.md:236` 的 `#90`
> 已經是另一件事**：「四個外部 app 從沒對著活的 kernel 用過」（⭕ UNASSIGNED，09-04 14:0x），
> 而且 `HANDOFF-2026-09-04.md:43`、`WORK-ITEMS.md:175`、`QUESTIONS-FOR-ADAM.md:130`、
> `APPS-CHECKLIST-2026-09-04.md:8` 四份文件都在用那個號。**那份表到 #90 為止，沒有 #91。**
>
> ⇒ **「#90」現在指兩件不同的事，而 09-05 那一套是後來的。**
> 這正是本檔 B-7／B-8 那段警告過的失效（「不編號進來，之後別處引用會另起代號、兩邊對不上——
> §C 那兩套撞號的 F-n 就是這樣長出來的」），這次是反過來：**同一個號被兩件事用。**
>
> **本檔的處理**：條目用**本檔自己的代號 `B-11`／`B-12`**，不用 `#n`；
> 底下每一次提到 `#90`／`#91` 都寫成「**09-05 夜巡的 #90**」。**編號本身要 Adam 裁**
> （改哪一套、還是兩套並存各自加前綴）——在他裁之前，**不要把這兩條寫成「就是 #90／#91」**。
>
> `B-10` 是 **W10 的 nickname overlay**（登記在分支 `fix/w10-nickname-overlay` 上，尚未併進 trunk）
> ⇒ **本次刻意跳過 B-10，把號留給它。**

---

### B-11 🔴 拓樸檔可以宣告一台**沒有位址**的 host，kernel 收下，並以 `('h9', [])` 對外服務

> 09-05 夜巡的 **#90**（見上面那則撞號說明）。W3 門 3b（碼與閘門裡叫 **door 3d**）。

- **狀態**：**在 trunk 上 OPEN。修法在分支 `fix/w3-door3b-host-empty-ip` 的 `b1471cbe`
  （分支 tip `72ffd4dd`，工單 W3-3b），未併入**（查於 2026-09-07，trunk `1536ff17`）。
  照 B-7／B-8 前面那段自己立的慣例（條目照登、狀態維持 **OPEN**、分支與 commit 寫在狀態行上），
  以及 **A-1 的規矩：變異閘在 trunk 上跑綠之前不得改 RESOLVED**。
  🔴 **「已經修好了」對外要先問修在哪個 ref**——這是一條沒併進 trunk 的分支。
- **平面**：兩者（載入器的事，與資料面無關）
- **失效方向**：**靜默**——整份檔案被完整收下，log 一個字都沒有
- **會發生什麼**：拓樸檔裡多一台 `"ip": []` 的 host（不必被任何 edge 指到），
  kernel **完整載入**（`nodes 15`、`edges 40`）、`Server Listening on port 8000`、
  `Collector Starts Up` 全部照常，`get_graph_data` 把它序列化成 **`"ip":[]`**，
  `get_static_topology_json` 也照樣回。**沒有任何 `[error]`／`[critical]`。**
  ⚠️ 打九支唯讀端點**不會讓 kernel 崩**（SIGSEGV 0），解不出路徑的回 404 ＋錯誤訊息
  ——**所以它不是崩潰缺陷，是「不變式沒有被守住」的缺陷**。
- **機制**：`validateStaticTopologyJson` 的 node 迴圈裡，空 `ip` 的條件寫成
  **`vertexType == VertexType::SWITCH && addresses.empty()`** ⇒ **只擋 switch，不擋 host**
  （碼裡逐字標著 `// ---- #89 door 3b: a switch with no management address ----`，
  `TopologyAndFlowMonitor.cpp:215`）。而「空 ip ＋被 edge 以位址指名」那條路**結構上走不通**
  （沒有位址就沒有 edge 指得到它，#61 的 edge 門先擋），所以**可達的形狀只有一種：多一台沒有位址的 host**。
  〔親自讀過（09-05／09-06 兩個 session 各自開檔）〕
- **代價**：`ip.front()` 的呼叫點（W2／#88 盤點的那七處，其中五處在 host 側產線走得到）
  的前提就是「host 至少有一個位址」。**門關上讓檔案層乾淨，但 Ryu 發現路徑加進來的 host 仍可能無位址**
  ⇒ 那五處對它們**仍然是裸的**（W3-3b SUMMARY §8 第 2 題，Adam 尚未裁）。
- **分支上的行為**（`b1471cbe`，**尚未在 trunk**）：`vertexType == HOST` 且 `ip` **缺／非陣列／空陣列**
  ⇒ 在**第一個 `add_vertex` 之前** throw，`num_vertices == 0`，訊息指名該台 host：
  `host "h9" declares an empty "ip" array; every host needs at least one address…`。
  🔴 **這條修法反轉了一支既有的綠測試**（`AHostWithNoAddressIsStillAllowed`
  → `AHostWithNoAddressIsRefusedAtLoad`）：舊註解寫著「拒絕它會拒絕掉每一份列了 host 的拓樸」，
  而**那是關於出貨檔的事實主張，已被證偽**（十三份出貨檔、每台 host 都有位址；`tools/make_topology.py:130`
  也一定給一個）。**要不要留這個反轉，Adam 尚未裁**（W3-3b SUMMARY §8 第 1 題）。
- **證據**：🟢 **live 兩次，同一批六個壞檔、同一種餵法（直呼二進位、`timeout 14`；rc=124＝收下、rc=1＝拒絕）**。
  - **BEFORE**（trunk `862c4bf8`）：`scratch/overnight-2026-09-05/rounds/05-R0b-postmerge2.md` §2.1 表列 **a**
    ——「收下 rc=124，零訊息」；同檔 §2.2 是那九支端點的逐字回應。
    raw `scratch/overnight-2026-09-05/logs/r0b2-w3-r3-topo-a-host-empty-ip.log`、`r0b2-w2-probes.log`。
  - **AFTER**（分支二進位 `2cab764b69509ef1`）：同目錄 `rounds/07-LIVE-branch-checks.md` **lw3** 表列 a
    ——**REFUSED rc=1**；raw `logs/lw3-w3-r3-topo-a-host-empty-ip.log`。
    **陽性對照在同一顆二進位上**：餵出貨的 `StaticNetworkTopologyOVS_10Switches_4Hosts.json` ⇒ rc=124、活過 14 s
    ⇒ **不是「拒絕一切」**（`logs/lw3-w3-control-good-ovs4.log`）。
  🔴 **上列 raw 與 round 筆記全在 `scratch/`，不在版控**——引用前先確認那個 session 的目錄還在。
  ⚠️ **可信度**：上面的 live 數字是 R0b／lw3 兩個角色實測（🟢 對他們）；
  **本條登記者沒有複驗任何一次 live 重現（🟠 轉述）**，只有「機制」那一段與分支 commit 的內容
  是登記者自己開檔查證的（🟢）。**兩者不要混用。**
- **契約測試看不看得到？** **看不到，而且結構上看不到。**
  `inv_graph_matches_topology` 比的是「圖 vs 它被交到手上的那份拓樸檔」——kernel 忠實地照著壞檔服務時，
  兩邊依定義一致。2026-09-07 給那支不變量加的 per-node 身分比對
  （分支 `fix/contract-per-node-identity`）**沒有改變這一點**，並且有一支測試把這件事釘死。
  ⇒ **關這扇門的只有載入器。**

### B-12 🔴 拓樸檔可以宣告一個 kernel 不認得的 `brand_name`，被靜默對映成 HARDWARE 收下

> 09-05 夜巡的 **#91**（見上面那則撞號說明）。碼與閘門裡叫 **door 3e**。

- **狀態**：**在 trunk 上 OPEN。修法在分支 `fix/w15-unknown-brand-rejected` 的 `008de16d`
  （分支 tip `8b3ebe49`，工單 W15），未併入**（查於 2026-09-07，trunk `1536ff17`）。
  🔴 **那條分支的 base 是 `fix/w3-door3b-host-empty-ip` 的 tip `72ffd4dd`，不是 trunk
  ⇒ 合併順序：先 B-11 那一支，再這一支。**
  同 B-11：狀態維持 **OPEN**，A-1 的規矩（閘門在 trunk 上跑綠之前不改 RESOLVED）。
- **平面**：兩者
- **失效方向**：**語氣拒絕、行為放行**——log 印一行 `[error]`，然後整份檔案照樣載入
- **會發生什麼**：把某台 switch 的 `brand_name` 打成 `NOT_A_REAL_KIND`，
  kernel **完整載入**（`nodes 14`、`edges 40`）、開 :8000。
  `switchKindFromBrandName` 對不認得的字串 **fallback 成 HARDWARE**，
  於是那台機器走到 `validateDataPlaneHomogeneity`，印出一句**指錯原因**的訊息，
  建議使用者去設 `ALLOW_MIXED_DATAPLANE`——而使用者真正做的事只是**打錯一個字**。
- **機制**：兩段各自合理、合起來變成靜默 fallback。
  ① `include/common_types/GraphTypes.hpp:96-107` 的 `switchKindFromBrandName`
  對未知 brand **回 HARDWARE**（沒有第三種答案，也不 throw——同一個檔案 `:110-114` 的
  `switch_kind` 解析器對打錯的值是 throw 的，**兩個欄位的嚴格度不一樣**）；
  ② `validateDataPlaneHomogeneity` 在 `parseStaticTopologyFile` 的**最後一行**才跑
  （`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:881`），
  而且**它的回傳值沒有人接**——那一行逐字就是 `validateDataPlaneHomogeneity(AppConfig::ALLOW_MIXED_DATAPLANE);`，
  而宣告是 `bool …(bool) const`（`TopologyAndFlowMonitor.hpp:372`）⇒ **它只是印，不是擋**（見下 BUG-17）。
  〔🟢 上面每一個 file:line 都是本條登記者在 trunk `1536ff17` 上開檔核對的；
  分支上的行為是核對 commit 內容（🟢），**兩邊都沒有重跑**〕
- 🔴 **同一個位置還有一條沒修的**（09-05 夜巡記為 **BUG-17**，Adam 已裁「開單，連兩份文件一起改」，
  **本次不代為登記**）：`validateDataPlaneHomogeneity` 的回傳值被丟棄
  ⇒ **真正的混平面檔案至今仍然是「印 `[error]` 然後照樣起來」**，
  而 `doc/2026-07-29_p4_status_and_test_guide.md:76` 寫著「拓撲裡 switch 種類不一致會**直接 fatal**
  並列出是哪些 dpid」、`doc/2026-07-27_p4_bmv2_support_plan.md:213` 寫著「**直接以致命錯誤中止**」
  ——**那兩句是假的**（🟢 兩行都是本條登記者開檔逐字核對的；W15 SUMMARY §6 另外點名了一份
  `architecture.md`，**這棵樹裡沒有那個檔名**，本條不轉述它）。W15 的修法只是讓**打錯的 brand** 到不了那條路。
- **分支上的行為**（`008de16d`，**尚未在 trunk**）：node 迴圈裡（door 3a 之後、3b 之前）
  對 `vertexType == SWITCH` 檢查 `brand_name`：缺／非字串／不在清單 ⇒ 在**第一個 `add_vertex` 之前**拒絕，
  訊息指名該值＋列出全部合法值（`OVS`／`BMv2`／`HPE5520`／`BrocadeICX6610`／`BrocadeICX7250`）＋
  說明後果＋說新機型要加在哪兩個地方。
  🔴 **代價（刻意的取捨）**：拿一台這個 codebase 沒有電源／遙測路徑的交換機（Cisco、Arista…）的人，
  **必須改一行 C++ 才能載入拓樸**。Adam 09-06 已裁 **W15 續單：有明確 `switch_kind` 就豁免**
  （⚠️ 與該 agent 的建議相反），並要求把「這種機器的電源／遙測預設行為＝沒人管」寫進圖與手冊
  ——**續單尚未做**，所以現在分支上的門是無條件的。
  🔴 **合法 brand 清單目前有兩份真相**（`.cpp` 的清單 ＋ `GraphTypes.hpp` 的 mapping ＋ 電源管理器六處字串比較），
  靠一支絆線測試綁在一起；要不要單一來源 Adam 已裁「(a) 現狀＋絆線；(b) 搬進 `GraphTypes.hpp` 另排」。
- **證據**：🟢 **live 兩次**，與 B-11 同一批六個壞檔、同一輪。
  - **BEFORE**（trunk `862c4bf8`）：`rounds/05-R0b-postmerge2.md` §2.1 表列 **c**——「收下 rc=124，訊息指錯原因」；
    raw `logs/r0b2-w3-r3-topo-c-bad-switch-kind.log`。
  - **AFTER**（分支二進位 `2cab764b69509ef1`）：`rounds/07-LIVE-branch-checks.md` **lw3** 表列 c
    ——**REFUSED rc=1**，訊息逐字列出五個合法值；raw `logs/lw3-w3-r3-topo-c-bad-switch-kind.log`。
    陽性對照同 B-11（`logs/lw3-w3-control-good-ovs4.log`）。
  🔴 **raw 全在 `scratch/`，不在版控。**
  ⚠️ **可信度**：live 數字是 R0b／lw3 實測（🟢 對他們）、**本條登記者未複驗（🟠 轉述）**；
  「機制」與分支內容是登記者開檔查證（🟢）。**不要混用。**
- **契約測試看不看得到？** 同 B-11：**看不到，結構上看不到**（`GRAPH_NODE["brand_name"] = Str()` 是
  **輸出**契約，任何字串都合法；而圖與檔一致時 `inv_graph_matches_topology` 沒有話說）。

---

## B-x. `/ndt/get_detected_flow_data` 包含已經結束的流（churn 下約 92%）

- **狀態**：🟢 **RESOLVED（2026-09-02，`7d678ed0`）**——端點與 top-k 都加上三態存活性
  （`active`／`idle`／`ended`）與可過濾的母體；**不是布林**，因為那 92% 幾乎全部是 `idle` 不是 `ended`，
  寫成「排除 ended」會通過 review 卻幾乎什麼都不移除。
  變異閘 **7/7 全殺**、ctest 47/47、整合樹 build 0 error、**ctest 870/870**。
  🔑 **#7（鬆掉的 `starts_with`）是以 signal 11 crash 被分類抓到的**，不是斷言紅——
  閘門把「崩潰」與「存活」分開報，所以它沒有被讀成通過。
  ⚠️ 修法**完全不動速率欄位**（那是 A-3 的地盤，早就修好了）；本條修的是**母體**。

**2026-08-27 實測。** 完整記錄：[`doc/audit/2026-08-27_flow-table-idle-tail/PREREG.md`](audit/2026-08-27_flow-table-idle-tail/PREREG.md)（工單 W）。

`FLOW_IDLE_TIMEOUT = 15000 ms`：一條流停止送封包之後，**仍留在流表 15 秒**。
在 churn 工作點（1.6 條新流/秒）實測：

| 當下真的在送封包 | 端點列出 | 比值 |
|---:|---:|---:|
| 4.7 | 63.0 | **13.3×** |

⇒ **端點回報的「流」約 92% 已經結束**，而**回傳的紀錄沒有任何欄位表達這件事**。

🔴 **有 repo 外的消費者**：`~/Energy-Saving-App/src/app/energy_saving_app.cpp:741`
把它整包餵進 `json2sim["flowDataList"]`。**是否據以做關機決策：未讀，未宣稱。**

**繞法**：需要「當下併發流數」的呼叫端，不能直接數這個端點的長度。
**倍率 ≈ `1 + 15 × 新流速率 / 平均併發`**，長流下趨近 1，**短流／高 churn 下最壞**。

⚠️ **保留 15 秒可能是刻意的**（避免短流一閃即逝）。**缺陷在於端點沒有把它表達出來，不在保留本身。**

**2026-08-28：規格揭露查核已完成**（[`03_spec-disclosure-check.md`](audit/2026-08-27_flow-table-idle-tail/03_spec-disclosure-check.md)）。
判定規則事前寫在 `NEXT.md:25-30`，結果落在「**沒寫**」那一支 ⇒ 上面的措辭維持不變。查核同時定出兩件事：

- 🔴 **文件不只是沒說，是說了相反的話。** §4 稱這個端點回傳 “all **active** flows”
  （`doc/2026-01-02_ndt_api.md:358`）。所以這不是「規格沉默、實作自由發揮」，
  是**規格做了宣稱而實作牴觸它**——可被引用來反駁 twin 讀數的等級。
- 🔴 **同一個母體涵蓋兩個端點。** `get_detected_top_k_flow_data` 的
  `getTopKFlowInfoJson` 直接呼叫 `getFlowInfoJson()`（`FlowLinkUsageCollector.cpp:2336`），
  而後者走訪整張 `m_flowInfoTable` **無存活性過濾**（`:2291-2327`）；文件 2395 行用了字面相同的
  “Top-K **active** flows”。**與既有的 top-k 殘影條目是不同的缺陷**：那條是速率**數值**沿用舊值，
  這條是**母體**——速率全部正確歸零，那 92% 仍然會被列出來。
- ✅ **修法契約相容**：`Obj` 的 `strict` 預設 False（`tools/contract_test/schema.py:129-138`），
  新增一個存活性欄位不會讓契約測試變紅，不必先改契約。
- **2026-08-30 讀碼重驗（`1208d22`）：整條照舊，沒有一項被修掉。**
  `FLOW_IDLE_TIMEOUT 15000` 仍在 `include/ndt_core/collection/FlowLinkUsageCollector.hpp:35`；
  `getFlowInfoJson` 仍然無條件走訪整張表（迴圈 `:2296-2326`，**沒有任何 predicate**）；
  `getTopKFlowInfoJson` 仍是 `min(k, size)` 不過濾（`:2347`）；預設 `k = 50` 仍在
  `HttpSession.cpp:589`。
  🔴 **最重要的一項也照舊：回傳的紀錄裡仍然沒有任何存活性欄位**
  （`:2298-2323` 建出來的欄位是 src/dst ip、port、protocol、四個速率、
  `first_sampled_time`、`latest_sampled_time`、`path`）——
  `latest_sampled_time` 是**唯一**的間接線索，而它是**格式化過的字串不是旗標**。
  📌 行號小幅漂移：原文的 `:2291-2327` 現在是 **`:2290-2329`**（函式體）。

### B-x 的排序後果——**一個被提出的加乘效應，實測不成立**

有人提出：top-k 用 `estimated_packet_rate_in_the_proceeding_1sec_timeslot` 排序
（`FlowLinkUsageCollector.cpp:2339-2344`，兩個分支都一樣），
而死流會在該欄位保留舊速率 ⇒ **死流會贏過活流搶進前 K 名**。

🔴 **這個加乘在兩個分支上都不成立，因為前提已經不對了。**

| | 死流的 `_in_the_proceeding_1sec_timeslot` |
|---|---|
| `origin/main` | **0**（一直都清除，`FLUC:1453-1459`） |
| 本分支（現行） | **0**（`aabe605` 修回清除，`:1911-1913`） |
| 本分支（`31b357a6`…`aabe605` 之間） | 保留舊值 ⇐ **A-3 的那個窗口，已關閉** |

⇒ 死流在兩個分支上都排到**最底**，不會擠掉活流。

⚠️ **但母體問題仍然成立，而且它自己就夠難看**：`getTopKFlowInfoJson` 取
`min(k, size)` 且**不過濾**（`:2347`）。預設 `k = 50`（`HttpSession.cpp:589`），
churn 工作點只有 **4.7** 條流真的在送封包
⇒ **回傳的 50 筆裡約 45 筆是速率 0 的死流**。清單不是被死流「灌到前面」，是**被屍體填滿**。

🔑 這條的教訓是**兩個缺陷可以看起來相乘而實際不相乘**：
A-3（數值）與 B-x（母體）確實會在 top-k 相遇，但 A-3 已經修掉，所以相遇的只剩一邊。
**在把兩個缺陷相乘之前，先確認兩個都還活著。**

#### 📌 2026-09-02 fix-design 對帳：92% 的可轉移形式，以及「idle 不是 ended」（讀於 `4cbec52d`）

- ✅ **92% 是實測，不是估算**，出處鏈完整：預註冊 `2026-08-27_flow-table-idle-tail/PREREG.md`
  （commit `59d58fb`）／原始讀出 `2026-08-27_1khz-path-recompute/preflight_*`（commit `8c9e841`）／
  揭露查核 `03_spec-disclosure-check.md`（`07408c6`）。
  讀數＝churn 1.6 條新流/秒下 `mean expected_alive 4.7` vs `mean api_flows 63.0` ⇒ 13.3×；
  **最低比值 2.25，39 個樣本沒有一個低於 1**（膨脹在每一個樣本裡，不是尾巴效應）。〔實測，引用他人已跑〕
- 🔴 **但 92% 是單一工作點，引用時必須帶條件。可轉移的是模型不是數字**：
  `膨脹倍率 ≈ 1 + FLOW_IDLE_TIMEOUT(秒) × 新流速率 / 平均併發`。長流趨近 1、短流／高 churn 發散。
- 🔴 **`:821` 那個加乘效應本輪也**沒有**重新主張**：前提（死流保留舊速率）已被 `aabe605` 修掉
  （`FlowLinkUsageCollector.cpp:1911-1913` 在 `!rates.hasActiveHops` 分支明文歸零，本輪確認仍在），
  且 2026-08-28 兩臂各 170 次輪詢、**3040 次觀察的 dead-AND-nonzero 都是 0**。
  ✅ **實測成立的是另一件事、而且更糟**：死流排序鍵是 0 **照樣占住前 10 名**
  ——median 4/10（base）與 2/10（branch）——因為**同時活著的流不到 10 條**。
  **不是「贏過」是「填滿」，修速率欄位修不掉。**〔實測，引用他人已跑〕
- 🔴 **修法設計上最容易踩的一腳（記下來，因為它會通過 review）**：那 92% **幾乎全部是 `idle`
  不是 `ended`**——一條流「停止送封包」與「被移出流表」是兩件事。
  ⇒ **把過濾寫成布林「排除 ended」會通過 review，卻幾乎什麼都不會移除。**
  可用的是三態 `active`／`idle`／`ended`。〔讀碼推論〕
- ℹ️ **行號較 08-30 那份再漂移約 −1 到 +30 行**（四項照舊成立）：
  `FLOW_IDLE_TIMEOUT 15000` 在 `FlowLinkUsageCollector.hpp:35`、`getFlowInfoJson` 迴圈 `:2296` 無 predicate、
  `getTopKFlowInfoJson` `min(k,size)` 在 `:2375`。
  🔴 **而「預設 `k = 50` 在 `HttpSession.cpp:589`」這個引用本身是錯的**（本條與 §B-x 上文各出現一次）：
  `:589` 是那個 handler 的 log 行，`int k = 50;` 實際在 **`:594`**。〔實測，本文以 `sed` 覆核〕
- ⚠️ **C++ 修法分支 UNVERIFIED（未編譯；且有一個 case 在修法前會 segfault 中斷 gtest）。**


### B-x 的反向：一條**完全送達**的流會從預設窗口消失，而界線的單位是 **pps 不是 bit/s**

> **狀態**：🔴 **OPEN**（2026-09-03 夜間第四輪實測）。B-x 修的是「死流被列出來」；
> 這一條是**同一個端點的反方向**——活流沒被列出來。**碼沒有動，本次只改文件口徑**
> （API 文件 §4／§26／§30、兩份 manual runbook 已改；**修法是另一個工作項目**）。
> **失效方向：悲觀**（送得好好的被說成不在）——但**對「用不存在來判斷閒置」的消費端而言是樂觀的**：
> 它會把一條活流讀成一條可以關掉的路徑。
> **原始資料**：`doc/audit/2026-09-03_night-rounds/round4-traffic-measurement/06_lead4_rate_sweep.log`、
> `07b_sweepB_analysis.log`；總表第 52 條。

一條流、每格 30 次每秒查詢、**線上逐位元組零丟失**（iperf3 自報 `0/N (0%)`）、
1400 B frame、3 跳、取樣 1/256。格內數字＝30 次裡看得到它幾次：

| 送出 @1400 B | pps | 預設（無參數） | `?liveness=all` | `get_num_of_flows_passing_a_switch` |
|---|---:|---:|---:|---:|
| 5 Mbit/s | 446 | 30/30 | 30/30 | 30/30 |
| 2 Mbit/s | 179 | 30/30 | 30/30 | 21/30 |
| 1 Mbit/s | 89 | 26/30 | 30/30 | 17/30 |
| 250 kbit/s | 22 | **16/30** | 30/30 | 6/30 |
| 60 kbit/s | 5 | 9/30 | 28/30 | 2/30 |
| 30 kbit/s | 3 | 3/30 | 13/30 | 0/30 |

- **~89 pps** 預設窗口開始漏；🔴 **~22 pps 預設窗口跨過一半**（此時 `?liveness=all` 仍 30/30）；
  **~5 pps** 連 15 秒保留表也開始漏；**~3 pps 以下**三窗口一起說「不在」。
  （十個檔位的完整表在 API 文件 §4；最下兩列是 Poisson 雜訊，不要讀出趨勢。）
- 🔴 **三欄是三個窗口**：預設＝`kFlowActiveWindowMs`（3 s）、`?liveness=all`＝整張保留表
  （`FLOW_IDLE_TIMEOUT` 15 s）、`get_num_of_flows_passing_a_switch`＝每條邊的 flow set，
  條目 **2 s** 就被 `flushEdgeFlowLoop` 清掉 ⇒ 最窄、最先漏。〔親自讀過〕
  **`?liveness=retained` 沒有量**；依定義夾在中間。
- 🔴 **鎖死頻寬只縮封包，可見度會動**：同樣 1 Mbit/s、同樣 0% 丟失，
  payload 1400→100 B（封包數 14×）時 2 秒那欄 **0.70→1.00** ⇒
  **每一條界線都是封包率的界線，換 frame size 整體位移最多 14×。
  只用 Mbit/s 講、不講 frame size，是不可轉移的講法。**
- ⚠️ **與 §A-4（`ovs4` 上 50 Mbps 也回 `[]`）不是同一件事**：那裡是拓樸完全沒設 sFlow、
  50 Mbps ≈ 4460 pps 遠在本條界線之上。兩者都會讓端點回空，機制不同，不要互相引用。
- 對照組：12 個安靜格三窗口全 0/8（12/12）；從未送出的誘餌 key 在 456 次查詢中 100% 讀為不存在。

## C. 靜默的正確性問題（不影響示範，影響可信度）

🔄 **2026-09-02：本表十列裡有七列已翻成已修**（F-14／F-16／F-8／F-1／F-13／F-6／F-15，
各自的變異閘見該列尾），**表頭這句話因此只對剩下的三列成立**（F-4 已翻案改修但碼另計、F-17 裁定不修、F-9 是解析度限制）。
**已修的列刻意留在表內不搬走**——搬走會讓「這條曾經在這張表上」查不到，而那正是重複發現的來源。

這些原本是 2026-08-18 那輪 subagent 找到的 18 條中仍然開著的部分。**都需要注入故障或特定條件**，
所以不會在示範中自己發作，但它們決定了「twin 說的話能不能信」。

> ### 🔴 引用 `F-n` 之前先確認是哪一套編號（2026-08-30 消歧）
>
> **`doc/audit/2026-08-18_live-full-stack-round/` 這個目錄裡有兩套各自從 F-1 編起的發現，
> 而且它們在 F-1…F-6 全面撞號。** 本表用的是**其中一套**：
>
> | 檔案 | 誰寫的 | 本文件哪裡用它 |
> |---|---|---|
> | `subagent-round2-FINDINGS.md`（18 條） | subagent | **本表（§C）全部**、§D 的 `F-4` |
> | `live-findings-2026-08-18-ovs.md`（F-1…F-7） | 審查員自己 | **A-8**（該檔的 `F-2`）、**B-1**／§D 的 `F-5`（該檔的 `F-5`） |
>
> **撞號實例，看一眼就知道為什麼要寫這一段**：
>
> | 編號 | subagent 那套（＝本表） | 審查員那套 |
> |---|---|---|
> | `F-1` | cpu/mem 回傳位元組相同 | punt 規則被誤診成缺失的拓撲鏈路 |
> | `F-2` | 單向鏈路故障誤報反向 | 契約套件與 Energy-App 不能共存（＝**A-8**） |
> | `F-3` | `ecmp_groups` 是靜態檔案虛構 | 契約 schema 與文件的 `-1` 哨兵牴觸 |
> | `F-4` | **死鏈路被復活成 `is_up=true`（＝本表這一列）** | **`04b8933` 留下的過期註解** |
> | `F-5` | 無控制器的交換機仍報 `is_up: true` | **幽靈規則（＝B-1）** |
>
> 🔴 **2026-08-30 這一週的 R-5 重驗跑的是「審查員那套」**，它的結論是
> **`F-3` FIXED、`F-4` FIXED、`F-2` STILL PRESENT、`F-5` STILL PRESENT**。
> ⇒ **那兩個 FIXED 與本表這一列的 `F-4` 無關**，也不對應本文件的任何條目
> （兩者都是 `tools/contract_test/spec.py` 的契約測試問題，**從來沒有被收進本清單**）。
> **本表的 `F-4` 本輪沒有被重驗，維持 OPEN。**
> ⚠️ **這正是最容易把一條還開著的缺陷誤標成已修的路徑**：兩套編號、同一個目錄、同一週的報告。

| # | 缺陷 | 平面 | 方向 |
|---|---|---|---|
| **F-4** | 死掉的交換機間鏈路**每次 poll 都被復活成 `is_up=true`**——`updateHosts` 只憑 IP 相符就把邊標 up，而交換機自己的管理 IP 被 Ryu 當成 host 學到 | OVS | 樂觀 |
| **F-17** | `get_average_link_usage` **只平均忙碌的鏈路**（分子分母都只算非零邊）。**round 4 量化：8/32 條邊忙碌時，只算忙碌邊的平均 0.11 vs 真實 0.027，正好 4.0×**。🔴 **08-29 更正：原文寫的「這是 Energy-App 關機決策的輸入」與「標頭文件寫的是另一個公式」兩句都是錯的**——見表下 | 兩者 | 樂觀（有負載時高估 4.0×）；**失效方向的完整敘述見表下** |
| 🏁 **F-14** | **host 永遠不會被標成 down**——沒有任何程式路徑可以做到。發現之後 `is_up` 是常數 `true`。<br>🟢 **已修（2026-09-02，`6db478ca`，與 F-16／F-4 同一次）**：改從 switch 三態 liveness **推導**——連續 2 個 poll 讀不到就把邊與其下的 host 標 down 並帶 `down_reason`，恢復時不主動標 up。**刻意不用「這輪沒被報到」的對帳式**，因為那在 host 上永遠不會觸發（Ryu `HostState` 無 timeout、P4 圖 append-only）。變異閘 **16/16 全殺**（含 1000 次不隔離、`continue` 解除武裝、被否決的修法各一顆），ctest 9/9，整合樹 ctest 870/870 | 兩者 | 樂觀 |
| 🏁 **F-16** | 交換機死掉時**只有交換機間的邊被標 down**，它面向 host 的邊維持 up，所以被孤立的 host 看起來還連著。<br>🟢 **已修（`6db478ca`，同上）。** ⚠️ 遲滯 `kMissesBeforeIsolating = 2` ⇒ 收斂後最壞 **60 秒**才把孤立的 host 標 down；那是刻意的，留成一行可改 | 兩者 | 樂觀 |
| 🏁 **F-8** | `left_link_bandwidth_bps` 在第一次取樣前**寫死 1 Gbit/s**，所以每條 10 Gbit/s 核心鏈路只宣告十分之一的餘裕。🔑 **與「容量夾制」同根**：`link_bandwidth` 這個**模型宣告值**滲進量測欄位的**第二種方式**——F-8 拿它當**初始值**，夾制拿它當**上限**（見 `doc/audit/2026-08-27_capacity-clamp/FINDING.md`）。**兩條並列不合併。**<br>🔴 **這個錯值在有流量的邊上是暫態；在從未有流量的邊上是永久**（措辭更正 2026-09-02 定案，**格內文字 2026-09-03 依 `STATUS-CHANGES-DEFERRED.md` #18 改寫**）。MININET 的 counter-sample 分支在 `FlowLinkUsageCollector.cpp:1102-1107` 直接 `continue`，所以**一條從來沒有流量的邊永遠不會被更新**——它不會等到真資料。夾制那一半（持久、只在超載時觸發）不變。〔原文存查：「F-8 是暫態、會被真資料取代」，**只對曾經有過流量的邊成立**〕<br>🟢 **已修（2026-09-02，`28a9b550`）**：宣告容量本來就讀進來了（`TopologyAndFlowMonitor.cpp:320`）只是寫給了旁邊那個欄位，修法是**接線**不是新資料源；並加 `left_link_bandwidth_source` 讓那 272 條「巧合正確」的邊與 16 條真的錯的邊**第一次可以分辨**。變異閘 **4/4 全殺**，ctest 全綠，整合樹 ctest 870/870 | 兩者 | 樂觀 |
| 🏁 **F-1** | `get_cpu_utilization` 與 `get_memory_utilization` **回傳位元組完全相同的內容**——同一個 `10 + hash(ip) % 50` 運算式；三個裝置健康指標都是交換機 IP 的常數函數。<br>🟢 **已修（2026-09-02，`65c5cdb1`）**：MININET 下**四個**捏造點（含條目原本漏掉的 `:1810 getSingleSwitchCpuReport`）一律改回檔案自己既有的哨兵 `-1`；**零 schema 變更**（`spec.py` 早就是 `Num(min=-1,max=100)`）。變異閘 **9/9 全殺**（M8 是宣告過的 expected-survivor，另計），ctest 全綠，整合樹 ctest 870/870。<br>🔴 **`ndt status` 那句「fabricated」提示要等部署才翻**：提示翻面的條件是**跑著的那顆 kernel 裡有這個修法**，不是 repo 裡有。⇒ **在部署同一顆 commit 之前，台上仍然要用「Mininet 模式下未實作」這個口徑** | 兩者 | 合成 |
| 🏁 **F-13** | 🔴 **敘述更正（2026-09-02）：不只是「對不存在的做 modify/delete」，是 6 端點 × {存在,不存在} 的十二格裡有六格錯，而十二格的回應完全相同**——除了 modify/delete 打不存在的那四格，**還有 install 打已存在的那兩格**（`OFPGMFC_GROUP_EXISTS`／`OFPMMFC_METER_EXISTS`，交換機**保留原本那筆**，呼叫端拿到 200 後會以為載送它流量的 buckets 是自己下的，方向更糟）。**六個端點裡也沒有任何 get**，呼叫端連事後自己核對的管道都沒有。<br>🟢 **已修（2026-09-02，`10ca8852`）**：改成送出前先查存在性，變異閘 **5/5 全殺**，ctest 全綠，整合樹 ctest 870/870。⚠️ pre-check 引進的 TOCTOU **只縮窗不關窗**，修法自己標了。<br>〔原敘述：對不存在的 group / meter 做 modify/delete 回 200 "modified"/"deleted" 且什麼都沒改。6 個端點零契約覆蓋。⚠️ **08-30 更正機制、結論不變**：那個 200 現在是**從 Ryu 轉述**的，不是 kernel 自己捏的——kernel 已改成傳遞真實結果（`HttpSession.cpp:804-805` 的 `respondToOpResult`，`7856efc`），但**整條路徑上沒有任何存在性檢查**，請求原樣轉給 Ryu（`HttpRoutingStrategyBase.cpp:219-220`），而 Ryu 對不存在的 group 回 200 空 body，`post()` 只在非 2xx 或 body 內含 `{"status":"error"}` 時才判失敗（`:104`／`:118-125`）。⇒ **使用者看到的行為一模一樣**；`7856efc` 早於 08-18 的量測，所以當時量到的就是現在這個機制。<br>🔄 **08-30 sweep 補精度**：六端點**路由有登記**（`tools/contract_test/components.py:36-41` 全在、mapped POST），缺的是**回應形狀斷言**（components.py 以外 grep `group_entry` 零命中）——「零契約覆蓋」精確講是「**登記而無形狀斷言**」（`recording` 是同型第二例、已修；此六端點仍待）〕 | OVS | 靜默 |
| 🏁 **F-6** | 讀取流表失敗的交換機**被從 `get_switch_openflow_table_entries` 刪除**，而四處程式碼註解承諾「保留前一份表格」。<br>🟢 **已修（2026-09-02，`d50f63f2`）**：選「保留最後一份＋標記」（`stale_since`／`stale_polls`／`last_error`），而不是靜靜省略；`isUp==false` 那一條**刻意不 carry**。變異閘 **7/7 全殺**、ctest 20/20、整合樹 ctest 870/870。<br>🔑 **這個閘門的第一輪值得記**：7 顆裡有 2 顆**因為 mutant 自己編不過而被計為 SURVIVED**（改 header 的變異觸發 `-Wunused-variable`）——**編不過就是存活，不是警告**；改寫成編得過之後才全殺。<br>⚠️ 已知副作用：`inv_tables_non_empty` 對新的 `never_read` 狀態會變紅，要一起決定 | 兩者 | 靜默 |
| **F-9** | 鏈路使用量量化到取樣粒度（1/256 × frame length × 8），所以低於約 3 Mbit/s 的鏈路**讀成一個量子的整數倍**（⚠️ 原文寫「讀成 0 或一個量子」，**「讀成 0」那半未被觀察到**，見下） | OVS | 解析度限制 |
| **F-15** | bmv2 gRPC port 配在 kernel 的 ephemeral range 內，所以交換機**隨機開不起來**，而錯誤訊息指向錯的原因。⚠️ **08-30 重驗：分兩半，只有一半還在**。配置缺陷照舊（`p4_proxy/mininet/p4_testbed_topo.py:365` 的 `grpc_port=50050+i` ⇒ 50051–50060，落在預設 `32768-60999` 內）；但**「訊息指向錯的原因」已部分緩解**——`failure_reason()`（`:308-338`）現在會讀 bmv2 自己的 log，並在 `:331-332` 回報「gRPC port {} 已被占用，多半是前一輪殘留的 `simple_switch_grpc`」。**log 還在的時候診斷是對的**。<br>🟢 **已修（2026-09-02，`fix/f15-grpc-port-block`）**：port block 由 50050 改成 **30050**（30051–60，在預設 ephemeral range 之下），單一來源 `grpc_ports.py`，開跑前對 `/proc` 做 pre-flight，partial fabric 改 fatal。Python **31 綠**，**~20 處文件與 5 支手跑 probe 已同批改號**（Adam 08-31 裁「文件與 probe 同一次合併改完」；歷史 audit 記錄不改、列為 historical）。<br>🔴 **條目原本引用的守衛 `ASSERT FAIL: bmv2 did not all start` 在 repo 裡不存在**（那是 08-18 審查員自己的 harness）——**本清單讀起來像是有把關，實際上沒有**；新的 pre-flight 才是第一個真的關卡。<br>⚠️ **示範機仍要先 `cat /proc/sys/net/ipv4/ip_local_port_range` 確認**：換號防的是預設範圍，不是任意設定 | P4 | 環境 |

🔴 **這張表有五列的機制敘述在 2026-09-02 被補正或部分推翻，更正在本表下方的
〈📌 2026-09-02 fix-design 對帳：§C 表八列的機制補正〉一節**（F-1／F-4／F-6／F-8／F-13／F-14／F-16／F-15）。
**其中 F-8 那格的「暫態、會被真資料取代」已於 2026-09-03 依
`doc/audit/2026-09-02_fix-design-campaign/known-issues-delta/STATUS-CHANGES-DEFERRED.md` #18
改寫成「有流量的邊上是暫態；從未有流量的邊上是永久」**——
🔑 這一段原本寫著「格子裡的字本輪刻意沒有改，所以讀到那一格的人必須往下讀那一節」，
那句在 `fe76c67b` 把更正寫進格子的同時就過期了；留著它會讓下一個讀者以為那一格還沒修，
**而「一條過期的『還沒修』會害人重做已經做完的事」正是本文件自己在 G-2 記過的形狀**。

> 🚩 **§D 連帶檢查（2026-09-03，只標記、未改動 §D）**
> #18 與 `findings/F-8.md:388`（Q2）都警告這次措辭改動會牽動 **§D 裡以「反正會被真資料蓋掉」
> 為理由的那一族裁定**。逐格讀過 **§D 五列**（`A-1 / A-2 / A-3`、`5-tuple 下發`、`F-5（＝B-1）`、
> `F-4`、`F-17`）與 **§D-2 的唯一一項**（LLDP beacon 間隔）：
> **沒有任何一列以「暫態／會被真資料覆蓋」作為它寫下來的理由**，
> 五列的理由分別是「報告前凍結產品碼」「排序、無消費端」「發作率證據基礎鬆動」
> 「翻案改修」「零活消費端＋修分母會翻面」。
> ⇒ **#18 擔心的連帶不成立，§D 不需要因為 F-8 這次改字而重裁**；本行是那次檢查的紀錄，
> 不是裁定。**§D 的任何實際改動仍然是 Adam 的。**

> ### 🔴 F-17 的兩次更正，方向相反 —— 兩次都要讀完再引用
>
> **第一次（round 4 實測，仍然成立的部分）**：先前記載的失效方向「保守（少關機，不會誤關）」
> **是錯的**。round 4 量到**「保守」這個性質在閒置時消失**：沒有忙碌邊時這個端點回 **0.0**。
> 所以它**有負載時高估 4.0×、閒置時歸零**——**端點的讀值本身是雙向失效的**，這一半照舊成立。
>
> **第二次（2026-08-29 更正，把第一次的結論收窄）**：round 4 接著推論
> 「0.0 落在 Energy-App 的 `LOW_WATER_MARK = 0.40` 之下 → 觸發關機」。
> 🔴 **那條因果鏈需要一條不存在的接線。**
>
> | 查了什麼 | 結果 |
> |---|---|
> | `Energy-Saving-App` 有沒有這個端點的 client | ✅ **有**：`src/app/http.cpp:393` 定義 `get_average_link_usage()`，打 `/ndt/get_average_link_usage`；`include/app/http.hpp:34` 宣告 |
> | 那個 client 有沒有**被呼叫** | 🔴 **零個呼叫點**（全 repo grep，扣掉定義與宣告後為空） |
> | 關機決策實際讀什麼 | `energy_saving_app.cpp:926` 的 `avgLinkUtilization` 來自 **`group_avg_link_utilization(g, group)`**（`include/common/types.hpp:215`），**從 Graph 自己算**，不經過這個端點 |
>
> ⇒ **F-17 不是 Energy-App 關機決策的輸入。** 這正是 [[existence-is-not-wiring]] 的形狀：
> **端點的 client 存在、被宣告、被文件記載，但沒有人呼叫它。**
>
> **所以下面這些要分開**：
> - 🔴 **不再成立**：「F-17 會害 Energy-App 關光交換機」。它碰不到那條決策路徑。
> - ✅ **照舊成立**：端點讀值有負載時高估 4.0×、閒置時歸零（**這是 twin 可信度的缺陷**）。
> - ✅ **照舊成立，而且它才是真的關機風險**：**A-4b** —— app **自己的**
>   `group_avg_link_utilization` 在邊 up+enabled 但沒有量到流量時回 0.0 → `0.0 <= 0.40` → 關機。
>   **那條推論完全不依賴 F-17**，`:168` 從一開始就寫著兩者是不同的函式。
> - ⚠️ **零呼叫點不等於可以安全地改**：`/ndt/` 是跨 repo 契約、七個姊妹應用在用，
>   而這個端點的 client 已經寫好放在那裡（見 [[no-in-repo-callers-is-not-dead-code]]）。
>
> 📌 **產品碼裡的那兩個引用點：早在 2026-08-29 就由 Adam 自己處理掉了**（`c7c9b155`，
> **是 HEAD 的祖先**，commit 訊息逐字：「comment-only: state why the Energy-Saving-App premise
> was wrong, not just drop it」）。這一段原本寫著「還有第五個引用點……本輪沒有動產品碼，已另行
> 回報」——**那句 2026-09-02 寫下時就已經過期九天，2026-09-03 重查後改寫**。
> 🔴 **而且處理方式是「說明為什麼錯」不是「刪掉」，那是裁定的一部分，不要把它當成沒修完**：
> `include/ndt_core/http/HttpSession.hpp:664-675`（原 `:592`，**行號已動**）與
> `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3240-3248` 兩處都把舊句子**引號括起來留著**，
> 底下寫明前提為假、證據在哪、以及 ESA 的 client 宣告了卻零呼叫。
> commit 訊息給的理由是**「a reason outlives the conclusion it justified and deleting the
> sentence would let the next reader derive it again」**。
> ⇒ **全 repo 現在唯一還出現「Energy-Saving-App reads」字串的地方，就是那個被標明為已撤回的引文。**
> **把它刪掉會反過來推翻這個決定。**〔實測，2026-09-03 逐字重查兩個檔案與 `c7c9b155`〕
>
> 🏁 **對 §D 裁定的影響：已重裁完畢（Adam，2026-08-29）。**
> 原理由（失效方向保守）被 round 4 推翻、而 round 4 推出的「0.0 → 觸發關機」也被本次更正推翻
> ⇒ **那條裁定原本唯一的書面依據已經沒了**。重裁的結果是**結論不變（不修）、理由整組換掉**，
> 換成「零個活的消費端／修分母會讓失效方向翻面／修分母構不到閒置回 0.0」三條。
> **細節見 §D 的 F-17 那格與 `doc/audit/2026-08-29_f17-fix-impact/FINDINGS.md`。**

**F-1 在示範上的風險最高、工程嚴重度最低。** 台下有人點兩台交換機看到同一個數字，
或問一句「CPU 哪來的」，那是零防守的。**要嘛不上台，要嘛明講「Mininet 模式下未實作」。**

證據：`doc/audit/2026-08-18_live-full-stack-round/subagent-round2-FINDINGS.md`（904 行）

### 📌 2026-09-02 fix-design 對帳：§C 表八列的機制補正（讀於 `4cbec52d`）

> **只補機制、行號與漏掉的格子；狀態一律不動**（Adam 09-02 裁：狀態變更等 C++ 編譯＋過變異閘）。
> 每一句都帶可信度標籤。**本表的 `F-n` 是 subagent 那套編號**，見表上的消歧註。

- **F-1（cpu／mem 位元組相同）**：本體逐字成立，但**條目漏了第四個捏造點**——
  `DeviceConfigurationAndPowerManager.cpp:1810 getSingleSwitchCpuReport()`，
  Intent Translator 的「單台裝置」路徑（唯一呼叫者 `IntentTranslator.cpp:447`）。
  另三處是 `:947`（memory）／`:1548`（cpu）／`:1625`（temperature）。
  ⇒ **照著條目修的人會漏掉「s3 的 CPU 是多少？」這條問句路徑。**〔親自讀過〕
  條目也沒說 **`-1` 早就是這個檔案自己的 unknown 慣例**——三個函式的 `!isUp` 分支都寫 `-1`
  （memory `:936-940`、cpu `:1537-1541`、temperature `:1599-1613`；三者的 SNMP 失敗路徑也都以
  `int x = -1` 起始）**且契約與文件兩端都已經在消費它**
  （`tools/contract_test/spec.py:502`（cpu）／`:507`（mem）是 `Num(min=-1, max=100)`；
  `doc/2026-01-02_ndt_api.md:1640` 逐字寫著 down 的交換機三個端點一律回 `-1`）
  ⇒ 「修法要發明什麼值」看起來像未解問題，其實不是。〔親自讀過〕
  ⚠️ **`% 50` 五十個桶、十台交換機撞號 ≈ 60%（生日問題）** ⇒
  「台下點兩台看到同一個數字」**是過半數的情形**，不是小機率事件。〔讀碼推論，未實測〕
- **F-4（死鏈路被復活）**：敘述逐字成立，**根因可以指名了**——
  `updateHosts` 的兩條邊查找**只比對 IP、不比對 dpid**
  （`TopologyAndFlowMonitor.cpp:758` 走 `findEdgeByHostIp`（`:1679`，掃全部的邊、回傳第一條 `srcIp`
  含這個 IP 的邊，**不檢查 `srcDpid == 0`**）、`:797` 走 `findEdgeBySrcAndDstIp`（`:1779`，同樣不檢查））；
  而 MAC 對不上時 **`:724-729` 的 else 分支只 WARN、沒有 `continue`**，直接往下做 IP 比對。
  用實際拓撲檔證實選中的是誰：交換機 IP 是 `192.168.123.11..20`、邊陣列前段全是 switch–switch
  ⇒ `findEdgeByHostIp(192.168.123.11)` 回傳的是 **edges[0]，s1→s5 的交換機間鏈路**。〔親自讀過〕
  🔴 **這一項會決定修法能不能成立**：**任何「用『這一輪沒被報到』推 down」的對帳式修法，在 host 上永遠不會觸發**
  ——Ryu 的 `HostState`（`ryu/topology/switches.py:190-200`）是 `setdefault` 學習表、**沒有 timeout**，
  P4 proxy 的圖**是 append-only**（`topology_manager.py:539` 逐字寫著沒有人呼叫 `remove_node`/`remove_edge`）。
  **看起來修了，但那條路一次都不會走到。**〔親自讀過（Ryu 由 auditor 自本機原始碼覆核）〕
- **F-14 ＋ F-16（host 永不 down／host-facing 邊永不 down）**：敘述逐字成立，
  **共同根第一次寫得出來**：**發現路徑是單調的，只往 up 寫**——
  `updateSwitches`（`:639-640`）、`updateHosts`（`:721-722` host 頂點／`:761-762` host 邊／
  `:801-802` 交換機側的邊）、`updateLinks`（`:936-937`）
  **五處賦值全部是 `= true`，發現路徑上沒有任何一處寫 `false`**。
  而唯一能寫 `false` 的三條路（電源致動、switch liveness 迴圈、`/ndt/link_failed` API）
  **定義域都不含 host 頂點或 host-facing 邊**：`setVertexDown` 的四個生產呼叫端
  全部先過 `vertexType == SWITCH`（判斷式在 `DeviceConfigurationAndPowerManager.cpp:683`，
  `:781-802` 把「不碰 host」寫成刻意設計）；`setEdgeDown` 只有 `HttpSession.cpp:433`／`:462`
  兩個呼叫端，而它們的定位鍵是**兩個 dpid**（`:426`／`:437`）而 **host 的 dpid 是 0**。
  ⇒ **圖是「歷來看過的一切的聯集」，不是「現在被報到的東西的交集」。**〔親自讀過〕
  🔴 **口徑更正兩件（本文以 `grep -n 'isUp *= *true'` 逐一覆核，實測）**：
  ① **是「五處」不是 fix-design 與對帳簿寫的「六處」**——該檔的 `isUp = true` 共 10 個命中，
  扣掉 `:920`（**已註解掉**）、`:1834`／`:1842`（`setEdgeUp` helper）、`:2341`（`setVertexUp`）、
  `:2118`（註解文字），發現路徑剩下的正好是上面五處。
  ② **「`false` 零處」講的是發現路徑**：全庫 `isUp = false` 有五處
  （靜態載入 `:243`／`:318`、`setEdgeDown` `:1817`／`:1825`、`setVertexDown` `:2334`），
  **對帳簿壓縮成的「`false` 零處」單獨引用會過強。**
- **F-6（讀取失敗的交換機被刪除）**：「四處註解承諾保留」成立（＝**四個 skip path**），
  但**機制要改寫**：`continue` 的語意**不是「保留前一份」，是「這一輪不產生這台交換機」**
  （`DeviceConfigurationAndPowerManager.cpp:1022` 每輪從空陣列開始，
  `:1083`／`:1111`／`:1141`／`:1158` 四個 `continue`，`:1893` `m_cachedOpenFlowTables = std::move(newTables)`
  **整份取代**）。**四處註解描述的是一個從來沒有被寫出來的合併步驟——不是註解過期，是註解描述了一個不存在的機制。**〔親自讀過〕
  🔑 **最強的一條佐證：twin 的另一半早就照那個承諾實作了。**
  `Classifier::updateFromQueriedTables`（`src/ndt_core/collection/Classifier.cpp:1333`）是**逐 dpid upsert**，
  陣列裡沒有的 dpid **保留前一份表格** ⇒ **同一輪 poll，兩個子系統對同一台交換機給出不同答案**
  （Classifier 仍拿 dpid 3 的規則算路徑，而 `get_switch_openflow_table_entries` 說 dpid 3 不存在），
  **而這個分歧沒有任何地方會報出來。**〔親自讀過〕
  ℹ️ **三種數法不要互相打架**：**4 個 skip path**（＝條目說的「四處」）／**9 個地點**
  （4 skip path ＋ 3 處標頭 ＋ 2 個測試檔）／**12 個宣稱文字**。
  🔴 其中兩個在**測試檔的說明**裡（`tests/test_FlowStatsTimeout.cpp:206`、
  `tests/test_RequestDeadlines.cpp:126`）——**那兩位作者相信自己在測一個保留舊表的系統**，
  他們測到的是裁決正確，裁決之後的「保留」從來沒有人測過。**這就是它活這麼久的原因。**〔親自讀過〕
- **F-8（`left_link_bandwidth_bps` 寫死 1 Gbit/s）**：🔴 **條目的一半被推翻。**
  - **「暫態、會被真資料取代」只對「曾經有過流量」的邊成立。**
    MININET 模式下 counter-sample 分支在 `FlowLinkUsageCollector.cpp:1102-1107` 直接 `continue`
    （在 `:1120` 碰 `m_counterReports` 之前就跳掉）⇒ **一條從來沒有流量的邊永遠不會有 map 條目**
    ⇒ `updateLinkInfoLeftLinkBandwidth`（`TopologyAndFlowMonitor.cpp:1189`）**永遠不會為它跑**
    ⇒ `leftBandwidthFromFlowSample` **永久停在 1 Gbit/s，不是暫態**。〔親自讀過〕
  - **宣告容量其實讀進來了，只是寫給了旁邊那個欄位**：
    `TopologyAndFlowMonitor.cpp:320` `ep.linkBandwidth = edgeJson.at("link_bandwidth_bps")`、
    `:321` `ep.leftBandwidth = ep.linkBandwidth`（TESTBED 用的欄位），
    而 MININET 回報的是 `leftBandwidthFromFlowSample`（`HttpSession.cpp:558-560` 的三元判斷）
    ——**它從頭到尾沒有被寫，留著 `GraphTypes.hpp:376` 的類別內初始值**。
    ⇒ **修法是接線，不是新增資料來源。**〔親自讀過〕
  - **量化（讀碼＋讀拓撲 JSON，未執行）**：128-host 拓撲 288 條有向邊，
    **16 條匯聚↔核心宣告 10 G 而報 1 G（每條少報 9 G）**，其餘 **272 條「巧合正確」**
    ——正確的理由是哨兵剛好等於宣告值，**不是量到了、也不是讀了拓撲，而且沒有任何欄位能分辨這兩者**。
    全 fabric 少報 144/432 Gbit/s ＝ 33.3%。〔讀碼推論，未實測〕
    🔑 **這正是文末〈哨兵值會製造空洞的通過〉那一則的形狀。**
- **F-13（對不存在的 group/meter 回 200）**：⚠️ **敘述少了兩格，而少掉的那兩格方向更糟。**
  6 個端點 × {目標存在, 目標不存在} ＝ **12 格，回應完全相同（同狀態碼、同 body、
  body 裡沒有任何欄位隨輸入改變），其中 6 格是錯的**：
  modify/delete 對**不存在**的四格（`OFPGMFC_UNKNOWN_GROUP`／`OFPMMFC_UNKNOWN_METER`／兩個靜默 no-op），
  **外加 install 對已存在的兩格**（`OFPGMFC_GROUP_EXISTS`／`OFPMMFC_METER_EXISTS`
  ——交換機**保留原本那筆**，呼叫端拿到 200 之後會以為載送它流量的 buckets 是自己下的）。〔讀碼推論〕
  🔴 **追加：六個端點裡沒有任何 get。** `grep -i "group\|meter" HttpSession.cpp` 只命中那六條 POST；
  Ryu 的 `/stats/groupdesc/<dpid>`、`/stats/meterconfig/<dpid>` **沒有經 `/ndt/` 對外開放**
  ⇒ **呼叫端連事後自己去核對的管道都沒有**（對照：`rejected-requests-can-still-act`
  那次是靠 proxy 這條獨立通道讀回交換機表才抓到的）。〔親自讀過〕
  **Ryu 那一端沒東西可判**：`ofctl_v1_3.py:1151` 只 `send_msg`（無 barrier、不等回覆），
  `ofctl_rest.py:276-277` 呼叫完立刻 `Response(status=200)` 空 body。
  ⇒ **先查存在性是唯一辦法**（TOCTOU 只縮窗不關窗）。〔親自讀過（auditor 自本機 Ryu 原始碼覆核）〕
  ℹ️ **四個引用有三個行號漂了**：`respondToOpResult` 在 `HttpSession.cpp:783-823`
  （條目引的 `:804-805` 落在 502 分支中間）；「原樣轉給 Ryu」在
  `HttpRoutingStrategyBase.cpp:243-277`（條目引的 `:219-221` 是 `modifyAnEntry` 的註解，與 group/meter 無關）；
  `tools/contract_test/components.py` 是 **`:40-45`**（條目寫 `:36-41`）。
  ✅ `post()` 的 `:104`／`:118-125` 兩個都還對。〔親自讀過〕
- **F-15（bmv2 gRPC port 落在 ephemeral range）**：配置缺陷照舊，**但條目少記三件事**：
  - **本機實查（2026-09-02）**：`/proc/sys/net/ipv4/ip_local_port_range` ＝ **32768 60999**
    ⇒ **50051–50060 十個全部在範圍內**。〔實測，auditor 重跑〕
  - **寫死的 50050 有兩份**：`p4_proxy/mininet/p4_testbed_topo.py:365` 的 `grpc_port=50050+i`，
    **以及 proxy 端 `p4_proxy/proxy_agent/main.py:92` 的 `DEFAULT_GRPC_PORT_BASE = 50050`**
    ——**條目完全沒提第二份**，只改一份會讓 proxy 連錯人。〔親自讀過〕
  - 🔴 **第二個缺陷：兩支 bring-up 偵測到失敗仍 `exit 0` 繼續。**
    `p4_testbed_topo.py:624-646` 印完 `WARNING: N of M BMv2 switches did NOT come up.`
    之後**照樣 `CLI(net)`**；`ntg_bmv2_topo.py:116-134` 同形且更糟（印完「不要在半套 fabric 上打流量」
    就直接進流量產生器）。外層 `stack.sh:726-731` 只做互動式 `prompt_for_mininet`，
    `grep -n "ndtwin_p4_switches\|manifest\|BMv2" stack.sh` ⇒ **零命中**。〔親自讀過〕
  - 🔴 **更正一個被記進本清單的守衛：它不存在。** 08-18 的原始 finding 寫
    「The bring-up script's own guard caught it (`ASSERT FAIL: bmv2 did not all start`)」，
    而全 repo 搜 `did not all start` **只命中那份 findings 自己**
    ⇒ **那是當時審查員自己臨時寫的 harness，不是專案資產。**
    **本清單讀起來像是有把關，實際上沒有。**〔實測，auditor 覆核；本文亦以 `grep -rn` 重跑確認〕
  - ⚠️ `failure_reason()` 的緩解**方向仍偏**：`:331` 寫「多半是前一輪殘留的 `simple_switch_grpc`」，
    而 08-18 觀測到的真因是 **ephemeral 搶佔、沒有殘留** ⇒ 從「沒說」變成「說了一個錯的最可能原因」。〔讀碼推論〕

### C-2 ⚠️ 「沒做事卻回 200」這一族的共同根：回應是以 `status::ok` 建構的

> **編號 2026-09-02 定案**（原臨時編號 `NEW-HTTP-200-DEFAULT`；Adam 裁：**歸 §C**——
> 它是一個**設計性質**，不是示範看得到的缺陷）。
> 這不是一條新缺陷的發現，是 **F-13／B-3／B-4 三條各自被獨立記錄的東西其實共用一個構造**。
> 🔴 **`C-1` 刻意留空**：本檔 §B-1 已經引用了「08-13 fault catalogue 的 `C-1`」，
> 佔用同一個字串會製造出**第三套撞號的編號**——這正是 §C 開頭那則消歧註在講的事。

- **平面**：兩者（純 kernel）
- **機制**：`HttpSession::buildResponse()`（`src/ndt_core/http/HttpSession.cpp:117-120`）
  以 `http::status::ok` 建構回應物件 ⇒ **任何沒有明確呼叫 `res.result(...)` 的 handler，一律回 200。**
  「回 200」因此**不是任何一個 handler 的決定，是預設值**。〔親自讀過（auditor grep 確認）〕
- **為什麼值得單獨記**：三條條目各自寫了「它回 200」，讀起來像三個獨立的疏忽；
  實際上**任何新加的 handler 只要忘記設狀態碼就自動長出同一個缺陷**。
  ⇒ **審查新 handler 時要問的是「它有沒有設 `res.result()`」，不是「它回了幾」。**〔讀碼推論〕

### C-3 ⚠️ 溫度迴圈在過濾頂點型別**之前**就 `front()` ⇒ 空 vector 即 UB

> **編號 2026-09-02 定案**（原臨時編號 `NEW-DCAPM-TEMP-FRONT`）。與 §C 表的 **F-1** 是同一個檔、同一族。

- **狀態**：🏁 **碼已修（2026-09-02，`922e3935`，落在 F-1 那條分支上），但守衛只驗形狀、從沒看過紅。**
  修法＝把 `vp.ip.front()` 移到型別過濾之後（`else if` 鏈變成單純的 `if`，行為不變——第一個分支一定 `continue`）。
  🔴 **為什麼守衛不算數，寫清楚免得被讀成「有測試釘住」**：這是 **UB**，而**這個 build 沒有
  `-D_GLIBCXX_ASSERTIONS`／`-D_GLIBCXX_DEBUG`**（`tests/shell/mutate_f1_mininet_health_metrics.sh:24`
  與 `:208` 自己寫著這件事）⇒ 把修法變異回去**不會可靠地變紅**，那顆變異只能被計為 survivor。
  ⇒ 現有的 `AVertexWithNoIpIsSkippedRatherThanDereferenced` **驗的是形狀（有沒有先過濾）不是行為**。
  **要真正釘住它，得先在 Debug build 打開 `_GLIBCXX_ASSERTIONS`**——那是
  `doc/audit/2026-08-09_memory-safety-ci-plan.md:682` 已經建議、但沒做的事。
  🔴 **修法自己點名了一個沒修的殘留**：**一台沒有管理 IP 的 SWITCH 仍然會在下一個分支 fault，三個函式都是。**
  那是另一個問題（「沒有管理 IP 的交換機該回報什麼」），**刻意留成可見的，而不是用猜的答案蓋掉**。

- **平面**：兩者（MININET／TESTBED 都會走到）
- **失效方向**：未定義行為（可能是靜默錯值，也可能是當場崩潰）
- **機制**：`DeviceConfigurationAndPowerManager.cpp:1594`
  `std::string ip_str = utils::ipToString(vp.ip.front());` 出現在
  `:1595-1598` 的 `if (vp.vertexType != VertexType::SWITCH) { continue; }` **之前**。
  **同一個檔案的另外兩個同型迴圈都是先過濾再取**：memory 在 `:918`、cpu 在 `:1519`。
  ⇒ 任何 `ip` 為空的頂點（例如沒有位址的 host 條目）會對空 vector 呼叫 `front()`。〔親自讀過（auditor 親讀確認）〕
- **修法**：一行搬位。**但要編譯**，歸入批次編譯那一輪。

### 🔴 F-9 的範圍更正（2026-08-27）

原文說低於約 3 Mbit/s 的鏈路「**讀成 0** 或一個量子」。**「讀成 0」那半沒有被觀察到。**

| 來源 | 觀察 |
|---|---|
| `8/27 auditor` | **62 條 host 邊全部低於 3 Mbit/s，而無一讀 0** |
| 本次獨立複驗（OVS、`raw_n/N1d_moderate/rows.json`） | **55 條有負載的邊（veth > 1 MB），讀 0 的有 0 條**；最小的非零 twin 讀值 = 291,442 B ≈ **2.33 Mbit/視窗**，正落在 3 Mbit 以下那個區間 |

⇒ **量化本身是真的**（存在一個地板、讀值是量子的整數倍），
但**「低於門檻就掉到 0」不是這個缺陷的行為**。

🔑 **為什麼這個更正重要而不是雞蛋裡挑骨頭**：
「讀成 0」意味著**一條有流量的鏈路會在分身上看起來是閒置的**——那是**可見性的缺口**；
「讀成一個量子」只是**精度不足**。**兩者對維運的意義完全不同**，
而原文的措辭會讓讀的人準備防守一個不存在的失效模式。

⚠️ **未宣稱**：這兩份觀察都在**有流量**的邊上取得。
**完全沒有流量的邊讀什麼，本次沒有量**，所以不排除「真正閒置 ⇒ 0」——
那本來就是正確行為，與本條無關。

---

### C-4 🔴 B-1 的幽靈規則過濾器沒有覆蓋 OVS 的寫入路徑

- **狀態**：OPEN（2026-09-03 夜巡第一輪確認）。**08-31 判定「已修」的東西只在一個平面成立。**
- **平面**：OVS（P4 上同一份配方是乾淨的）
- **失效方向**：樂觀 ＋ 靜默
- **會發生什麼**：OVS 上 kernel 在 **t=0.257 s** 就送出快取列——形狀是**呼叫端的 `ipv4_dst` 詞彙、
  沒有計數器**——並持續約 **1.0 s**；真正輪詢回來的列 **t=13.4 s** 才到。
  同一份配方在 P4 上是 `first_sighting=never`。
- **機制**：B-1 的過濾器擋的是讀取路徑，不是 OVS 的寫入路徑。
- 🔑 **這一條的形狀值得單獨記住**：一個修法在**它被驗證的那個平面**成立，
  不表示在另一個平面成立；而原本的驗證在結構上不可能發現這件事。
- **證據**：`.../round1-ovs/22_x5_b1_phantom_window_ovs.log`。
  **含陽性對照**：合法的 port-2 規則有**同樣的**幽靈形狀 ⇒ 那一列是快取，不是合法性判定。
  探測解析度 0.25 s vs 約 1.0 s 的窗 ⇒ 排除「探測太慢」。

### C-4b 🔴 `get_switch_openflow_table_entries` 在 delete 之後繼續回報**已經不在交換機上**的規則 9.61 s

> **與 C-4 的關係**：C-4 承認的是 **install 那一半**（規則已下發、視圖刻意扣留，kernel.log 有寫）。
> **這一條是 delete 那一半**：規則**已經不在交換機上**，而 §5 繼續說它在。**兩邊方向相反、成因不同，
> 但落在同一個視圖上** ⇒ Adam 2026-09-05 grill 第五輪裁定：**併進 C-4 的修法一起處理**
> （delete 也走 withholding，讓兩個方向對稱），不另開單。

- **狀態**：**OPEN。** 2026-09-05 夜巡 R6 實測（install 方向 2/2、delete 方向 2/2），2026-09-06 登記。
  文件側已落（2026-09-06，**只改文件、行為不動**）：`doc/2026-01-02_ndt_api.md` §5 加上兩個方向的
  落後值與「不要拿它當即時 read-back」，並新增一節
  〈Closed-loop apps: how long until a change is visible〉。
- **平面**：**OVS 實測。P4 沒量**（R6 整輪跑在 OVS 10-switch／4-host）
- **失效方向**：**樂觀 ＋ 靜默**——一條交換機已經丟掉的規則被回報成還在，而回應裡沒有任何欄位
  說這份資料有多新
- **會發生什麼**（逐字，`logs/r6-29-s5-stale-after-delete.log`；t=0 是 `POST /ndt/delete_flow_entry`
  回 200 的瞬間，取樣 0.5 s）：
  ```
  === install a throwaway rule and wait until BOTH views show it ===
    both views agree: ryu=True s5=True
  === now DELETE it, and watch how long manual-s5 keeps reporting it ===
    POST delete_flow_entry -> HTTP 200
     t+  0.00s ryu=True s5=True
    +  0.51s  Ryu: rule GONE (the switch really lost it)
     t+  3.04s ryu=False s5=True
     t+  6.07s ryu=False s5=True
     t+  9.11s ryu=False s5=True
    + 10.12s  manual s5: rule GONE
  === ryu_gone_at=0.5058937072753906 s5_gone_at=10.120249032974243 STALE WINDOW = 9.61s
  ```
- 🔑 **對照組（缺陷是這樣被定位出來的，不是免責條款）**：
  ① **同一支探針的 install 方向**（`logs/r6-28-s5-withhold.log`）：
  `ryu_visible_at=0.406  s5_visible_at=3.656  gap=3.25s` ⇒ **兩個方向都會說謊，但長度差 3 倍**；
  ② **Ryu `/stats/flow/<dpid>` 是交換機那一側的真相**，兩個方向都在 0.4–0.5 s 內就對了
  ⇒ 排除「交換機自己慢」，落後的是視圖不是資料面；
  ③ **kernel.log 對 install 方向有話說、對 delete 方向一個字都沒有**——
  `logs/r6-91-kernel.log` 有 **8 次**這一行（逐字，已去除色碼）：
  ```
  [Controller.cpp:100 operator()] 1 of 1 dispatched flow entries for dpid 1 were accepted by the
  control plane, but this plane's acceptance is not evidence the switch programmed them -- it
  answers before the switch adjudicates. They are withheld from get_switch_openflow_table_entries
  until a poll observes them (KNOWN-ISSUES C-4).
  ```
  而全檔 grep `stale`／`no longer on the switch`／`removed` 的 5 個命中**全部**是
  `ApplicationManager.cpp cleanupStaleEntries` 的 NFS 目錄清理，**與流表無關**
  ⇒ **delete 那一側連 log 都沒有承認。**
- **機制**：🟠 **未開檔查證。** 本條登記者這一輪只動文件、**沒有讀 `src/`**；
  可觀測的形狀是「視圖直到下一次輪詢把它清掉為止都還留著那一列」，
  與 C-4 的「刻意扣留」**不是同一個成因**（扣留是主動不給，這裡是被動沒更新）。
  要寫進修法單之前必須有人開檔確認 §5 的 delete 路徑是否真的沒有對應的失效處理。
- 🔴 **影響面**：
  - **一支社群 app 刪完規則立刻驗，會讀到「沒刪掉」**，於是重刪；
    而 §10 對「什麼都沒刪到」也回 **200**、與真的刪掉逐字相同（見 `doc/2026-01-02_ndt_api.md` §10
    2026-09-06 新增的那一段），**兩件事疊起來就是一個沒有任何錯誤訊號的重試迴圈**；
  - R6 那支需求驅動的 app 輪詢週期是 **5 s**，**install（3.66 s）與 delete（10.12 s）兩個方向
    都落在錯誤區間內**；
  - 這一條接到「注入後必須斷言注入成功」那條紀律上：**§5 不能當作「規則已生效／已移除」的斷言**，
    要斷言就讀交換機那一側（控制器 REST），或等到 §30 的 `path` 換掉（6–7 s）。
- **繞法**：不要拿 §5 做即時 read-back；輪詢週期拉到 ≥ 15 s，或改用 §30 `get_detected_top_k_flow_data`
  的 `path` 確認。時序表在 `doc/2026-01-02_ndt_api.md`〈Closed-loop apps: how long until a change
  is visible〉。
- **修法方向**（Adam 裁定：併進 C-4）：delete 也走 withholding——寫入路徑在刪除成功後把該列
  從視圖裡拿掉並標記為「等 poll 確認」，讓兩個方向的語意對稱。**今晚只登記，不改行為。**
- **證據**：**實測 2026-09-05 夜巡 R6**，`scratch/overnight-2026-09-05/rounds/02-R6-appdev.md` **K-2**；
  raw 在 `scratch/overnight-2026-09-05/logs/`：`r6-29-s5-stale-after-delete.log`（delete 臂逐字）、
  `r6-28-s5-withhold.log`（install 臂對照）、`r6-91-kernel.log`（kernel.log 保存本）、
  `r6-17-install-reroute.log`／`r6-25-delete-reroute.log`（同一輪的收斂時序）。
  🔴 **上列 raw 全在 `scratch/`，不在版控**——引用前先確認那個 session 的目錄還在。
  ⚠️ **可信度分級**：時間數字與逐字輸出是 **R6 角色實測（🟢 對他）**；
  **本條登記者沒有複驗任何一次 live 重現（🟠 轉述）**，只有上面對 `r6-91-kernel.log` 的兩次 grep
  是登記者自己跑的（🟢）。**兩者不要混用。**

## D. 已明確裁定不修（含理由）

| 缺陷 | 裁定 | 理由 |
|---|---|---|
| **A-1 / A-2 / A-3** | 報告前不改碼，改用操作繞過 | 產品碼在報告前凍結（Adam 裁定）。A-1 的修法要碰 `powerOn` 的冪等語意，那個早退是**故意**的；報告前改錯比 bug 本身更糟 |
| **5-tuple 下發** | 報告後再修 | **不是缺陷，是排序**。P4 pipeline **有** `flow_5tuple` ternary 表且已接進 pipeline 排在 LPM 之前；proxy 的 `route_flow` 沒接；**而 TE app 自己也只送 `ipv4_dst`**（`# TODO: Change to match 5-tuple in HPE`）。三層一致，沒有消費端今天需要它。目前的 400 是**修法**——它取代了「接受 5-tuple 但實際裝成整個目的地的規則、priority 讀回 0」的靜默降級。詳見 memory `single-flow-precision-gap` |
| **F-5（幽靈規則）**<br>（＝審查員那套編號，本文件的 **B-1**） | 2026-08-18 不修。🔴 **2026-08-30：裁定的證據基礎鬆動，待重裁** | 原理由：30 分鐘真實負載下 **0 次自然發作**（177 取樣、期間 37 次寫入、5 次電源變動、15 輪 TE 遷移）。量測靈敏度約 80%/次，所以是「發作率低」不是「零」。<br>🔴 **2026-08-30 的問題：那 177 個取樣是 10 秒一格**（`measure_f5_frequency.sh` 的 `INTERVAL="${1:-10}"`，`f5_frequency.log` 檔頭逐字寫著 `interval=10s duration=30min`），**而同一週 FINDING-03 量到的窗口在 t=2（P4）／t=3（OVS）就消失了**。<br>⇒ **「靈敏度約 80%/次」是照 ~8 秒的窗口算的；若窗口其實是 2–3 秒，10 秒格的靈敏度遠低於此，「0 次」就幾乎不構成證據。**<br>⚠️ **但不要把話講死**：FINDING-03 **明文不宣稱**它量到的短窗與 08-18 的 ~8 秒是同一個現象（「同一個指紋，與舊時長的關係未知」），而且它是在**沒有流量**的網路上量的。<br>⇒ **兩種可能都還開著**：①窗口本來就短、08-18 的 8 秒另有原因；②有流量時窗口會變長。**本輪不裁，交 Adam**；要裁之前該補的是**同一格點下、有流量的重量**，不是再多取樣。<br>📌 機制已指認（FINDING-03）＋工單 **T-11** 已開，見 B-1。<br>🏁 **08-31 補：要求的「同格點、有流量重量」已跑**（TR-3）＝**窗是時鐘不是負載**（表視圖快取 10 s 刷新；FINDING-06 更正 `51b3e84`＝blindness not delay——規則多半立即編程、最長 ~10.7 s 不可見）；且 **T-11-A（`91e7743`）已把幻影整個移出視圖**（08-31 live 力紅力綠雙向驗證）。**重裁材料齊備，裁決仍留 Adam**（F-5 是否解鎖併發控制前置） |
| **F-4**<br>（＝subagent 那套編號，＝§C 表那一列） | 2026-08-18 不修；**🔄 2026-09-02 翻案（Adam）** | 🔄 **本格 2026-09-02 由 Adam 翻案：改為修，併入 F-14／F-16 的推導式修法**——不走「這一輪沒被報到就標 down」的對帳式，而是**從 switch 的三態 liveness 推導**：連續 2 個 poll 讀不到 ⇒ 把它的邊與其下的 host 標 down 並帶 `down_reason`，恢復時不主動標 up。機制、兩邊的論證與三道守衛見 **§C 表下〈2026-09-02 fix-design 對帳〉的 F-4 那段**與 §C 的 F-14／F-16 兩列。<br>🔑 **翻案的理由不是「原裁定的事實錯了」，是它衡量「窄」的前提換了**：08-18 判斷觸發條件窄的時候，F-14／F-16 還沒有被放進同一張表。三條並排之後，F-4 不是一個孤立的誤判，而是**同一條單調發現路徑的第三個出口**——前兩個保證「沒有東西會往 down 走」，第三個保證「就算有東西走了 down，下一個 poll 也會把它推回來」。<br>⚠️ **而且「窄」在示範上不成立**：subagent 那輪的觸發動作是「切斷 s10 的 controller」——**那正是故障示範會做的事**。窄不等於不會在台上發生，它等於**只在你要示範故障時才發生**。<br>🔴 **若日後要改回不修，三道守衛必須一起 revert**：只留 F-14／F-16 會讓 `reconcileDerivedLiveness` 每 poll 把邊標下去、`updateHosts` 又用假 host 條目把其中一條標上來——**兩個機制在同一條邊上打架，只因 reconcile 跑在後面才看起來沒事**。<br>〔原裁定存查：2026-08-18 不修。理由是「機制讀碼確認，但報告裡『permanent and built in』那句被實跑推翻——我那輪 0 次，subagent 那輪 18 次（在它切斷 s10 controller 之後），觸發條件比原報告說的窄」。⚠️ 08-30 補的消歧註仍然成立：**那一週 R-5 報的「F-4 FIXED」不是這一條**（那是審查員那套的 F-4＝過期註解）——見 §C 表上的消歧註。〕 |
| **F-17** | **不修**。原裁定 **2026-08-18**；**2026-08-29 由 Adam 重裁，結論不變、理由整組換掉**（舊理由已死，見下） | **今天生效的三條理由**（全部出自 `doc/audit/2026-08-29_f17-fix-impact/FINDINGS.md` 的實查）：<br>**①「零個活的消費端」** —— 七個兄弟 repo（`tools/test_workflow/components.env` 的 `*_DIR`）逐一掃過，只有 ESA 寫過 client（`src/app/http.cpp:393`）而**沒有人呼叫它**；`Traffic-Engineering-App` 會拼接 base URL，另做了一次逐端點檢查。<br>**② 修分母會讓失效方向翻面，不是消失** —— 膨脹倍率 `f ≈ 可用邊/忙碌邊`，**決策只在真值落 `(0.40/f, 0.40]` 時改變，而在那個區間裡是「現行不關機 → 修法後關機」**。8/32 忙碌 ⇒ 區間 `(0.10, 0.40]`。在 round 4 自己的工作點（0.11 vs 0.027）**兩邊都關機，修了毫無差別**。<br>**③ 修分母構不到最常被引用的那個症狀** —— 閒置時現行走 `return 0`、修法後走 `sum(0)/N`，**輸出相同**。要讓「真的閒置」與「量不到」可區分得改回傳型別 ＝ **`/ndt/` 跨 repo 契約變更**。<br>⚠️ **這不表示 F-17 不重要，兩件事要分開**：**端點讀值的缺陷照舊成立**（有負載高估 **4.0×**、閒置歸零，機制仍是「分子分母都只算非零邊」）——那是 **twin 可信度**問題，只是**它今天不驅動任何決策**。<br>⚠️ **零呼叫端不是可以改回傳的許可**：ESA 的 client 已經寫好，接一行就會用到。<br>🗄️ **舊理由存查**：08-18 原裁定的**唯一**書面理由是「失效方向保守（少關機，不會誤關）」，已被 round 4 推翻（讀值是雙向失效）；而 round 4 由此推出的「0.0 → Energy-App 關機」也不成立（接線不存在，見 §C 表下）。**這條裁定換過理由，結論才留下來。** |

---

## D-2. 報告後待辦（不是缺陷，是待評估的調整）

### 縮短 LLDP beacon 間隔以加快故障偵測

- **狀態**：待評估。**報告後做，而且要做成實驗不是直接改**
- **提出**：Adam 2026-08-19

**現況的常數**（`p4_proxy/proxy_agent/topology_manager.py:137,155,158`）：

```python
LLDP_BEACON_INTERVAL_S   = 5
LINK_BEACON_TIMEOUT_S    = 3 * LLDP_BEACON_INTERVAL_S   # = 15，衍生
LINK_WATCHDOG_INTERVAL_S = LLDP_BEACON_INTERVAL_S       # = 5，衍生
```

timeout 與 watchdog 間隔**都是衍生的**，所以改一個常數三個一起動——這是便宜的部分。

**⚠️「收斂」是兩個數字，只有一個會改善**：

| | 現況 | 縮短 LLDP 後 |
|---|---|---|
| 偵測「這條鏈路死了」 | 實測 10.7–14 s | **會變短** |
| 修正「反向其實還活著」 | **0–30 s** | **不變**——由 `kOnceConverged = 30s` 的 poll 相位決定 |

`handleLinkFailure` 對單向故障也把**雙向**標 down，而只有 topology poll 會修正
（round 4 E8 確立）。所以在意「GUI 多久反應」→ 改 LLDP 有效；在意「拓撲圖多久才正確」
→ 要動 `kOnceConverged`。

**主要風險是誤判鏈路死亡**，而 `topology_manager.py:147-150` 的註解自己論證過為什麼那比慢更糟：
一次 interval 的容忍度會讓「掃描剛好落在 beacon 之前」就報故障，而
**會抖動的鏈路報告比慢的更糟**——每一次都讓 kernel 拆掉那條邊、從 BFS 移除、重算全域路徑。
這台機器讓風險是真的：bmv2 是 `-O0` debug build，模擬器**共用系統時鐘與 CPU**（見 §F）。

**隱藏成本**：`kLldpFreshSeconds = 12.0` 是 **C++ 常數**
（`DeviceConfigurationAndPowerManager.hpp:259`）。beacon 從 5 降到 2.5，那個窗口就從容忍
2.4 個 beacon 變成 4.8 個——**交換機存活判斷相對變得更不敏感**。維持同樣容忍比例要改 C++ 重編。

🔑 **先解決一個疑點再調參**：註解寫「偵測需要 15 到 20 秒」，**round 4 實測 10.7–14 秒**，
比文件快 5 秒。這代表我們對偵測時序的模型還沒對上——調完會不知道是什麼在動。

**建議的實驗設計**（改一行 Python，跑既有的鏈路故障實驗）：
掃 beacon = 5 / 3 / 2 / 1 秒，每個值量**偵測時間**與**誤判次數**。
**誤判率才是決定值不值得的數字**，不是偵測時間——因為偵測時間必然會降，
而誤判的代價是全域路徑重算。至少要跑到能區分「零誤判」和「低誤判」的樣本數。

---

## E. 已修，但形狀容易復發

不是待辦，是**審查時要問的問題**。完整討論在 memory 的形狀家族。

- **「該取代卻只能新增」**（7 個實例）—— 每個 ingest 都要問：**舊資料什麼時候消失？**
  → memory `replace-vs-add-bug-shape`
- **「被拒絕的請求仍然做了事」**（3 面）——
  ① 回 400 但真的裝上（`install_flow_entry` 缺 priority，**已修**）
  ② 回 200 queued 但被拒絕（B-1，開著）
  ③ 回 200 Success 但完全沒動作（A-1，開著）
  → memory `rejected-requests-can-still-act`
- **`/stats/flow` wedge**（三道門全部關上）—— 核心教訓：**失敗比逾時快**，
  所以任何基於延遲的守衛對「快速失敗」結構性失明
  → memory `ryu-flow-stats-wedge`
- 🆕 **「守衛擺在傷害已經造成之後的那條路徑上」**（2026-08-30 新增，缺陷 **P-1**，已修 `a7ab17d`）——
  第二個 proxy 實例對著一個**已被占用**的 port 啟動時，uvicorn 會**先跑完 ASGI lifespan 再 bind**
  ⇒ startup 已經開了 gRPC channel、推了 pipeline config、裝了轉發規則，
  **然後才拿到 `[Errno 98] address already in use`**。
  實測：**10 次 `Setting Forwarding Pipeline Config...`、LLDP discovery 起來、link watchdog 種好**，
  全部發生在錯誤之前——**兩個 agent 同時寫同一座 bmv2 fabric**。
  **修法不是加檢查，是把 bind 提前**：`claim_listen_socket()`
  （`p4_proxy/proxy_agent/main.py:361-398`）在 `Server.run` 之前搶下 socket，
  失敗就 `sys.exit(1)`，並且**把 socket 交給 uvicorn 而不是關掉重綁**——關掉重綁會把這個競態再開一次。
  🔑 **要問的問題**：**這個守衛跑的時候，它要防的事情已經發生了嗎？**
  「bind 失敗處理器」聽起來是對的地方，但在這個框架裡它**結構性地太晚**。
  ⚠️ **本條沒有對應的舊條目**——這個缺陷從來沒有進過本清單，08-30 對帳時才補記形狀。

---

## E-2. 潛伏：一個旗標之遙的靜默故障

### 🏁 ~~`getTopKFlowInfoJson` 對同一個 `std::shared_mutex` 遞迴取 shared lock~~ —— **已修（2026-09-01）**

- **狀態**：🏁 **已修（2026-09-01，Adam 線裁「先做 1+2」）。以下問題描述保留原文不動。**
  修法是**刪掉外層那一行**——外面本來就沒有東西要保護：`getFlowInfoJson()` 回的是新造的
  json 陣列，底下每一行都只碰那份區域副本。順帶把 📌 那段的 `std::sort` 移出臨界區。
  變異閘 `tests/shell/mutate_topk_recursive_lock.sh`：**五顆全殺**、`survivors=0`，全套 678/678。
  🔴 **這種修法（刪除）最難設閘**：什麼新東西都沒有跑起來，修法前綠、修法後也綠。
  而且**死結在這台機器上構不出來**（glibc 預設 reader-preferring，就是它一直沒咬人的原因）
  ⇒ 任何「會不會卡死」的執行期測試對修法前後同一個答案，**零鑑別力**。
  所以拆成兩半：結構性質由 `tests/shell/test_topk_no_recursive_shared_lock.sh` 讀原始碼守
  （把那行加回去就會紅），行為性質（k 的邊界、欄位名兩邊一致）由
  `tests/test_TopKFlowInfoLocking.cpp` 守——**這個函式在此之前一顆測試都沒有**。
  ⚠️ **順手量到一件本條沒寫的事**：排序的比較子拿的是 `const nlohmann::json&`，
  所以 `a["…"]` 走的是 **const `operator[]`**——它**不插入也不丟例外**，是
  `JSON_ASSERT(找得到)`，即 **`abort()`**；而 Release 帶 `-DNDEBUG`（`CMakeLists.txt:76`）
  時那個 assert 被編掉，變成解參考一個 past-the-end 迭代器。
  ⇒ **發射端與比較子的欄位名一旦不一致，不是某個端點回 500，是整個行程倒掉或 UB。**
  這是變異跑出來的：第一版把斷言寫在呼叫**之後**，行程在更早的 case 就 abort 了，
  於是那顆變異被報成 SURVIVED——**abort 掉的 binary 和全綠的 binary，對一個
  grep `[  FAILED  ]` 來說長得一模一樣。**
- 〔原狀態：**潛伏**。依 C++ 標準是**未定義行為**，但在目前的執行環境下**不會卡死**，
  所以**不宣稱它是活的缺陷**。列在這裡是因為變成缺陷的條件是具名且可驗的。〕
- **碼**：`FlowLinkUsageCollector.cpp:2335` 取 `shared_lock(m_flowInfoTableMutex)`，
  下一行 `:2336` 呼叫的 `getFlowInfoJson()` **對同一個 mutex 再取一次**（`:2293`）。
  `m_flowInfoTableMutex` 是 `std::shared_mutex`（`FlowLinkUsageCollector.hpp:387`），
  同一個 mutex 上有 **5 個 writer** 取 `unique_lock`（`:1486 :1822 :2109 :2272 :2924`）。
- **為什麼現在不咬人**：glibc 的 `pthread_rwlock` 預設是 `PTHREAD_RWLOCK_PREFER_READER_NP`，
  reader 不會為等待中的 writer 讓路，所以同執行緒遞迴 rdlock 會成功。
- 🔴 **會變成缺陷的條件（具名、可測）**：
  1. rwlock 種類改成 writer 優先（`PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP`），或
  2. libstdc++ 換成 condvar 版的 `shared_mutex` 實作（未定義 `_GLIBCXX_USE_PTHREAD_RWLOCK_T` 時）
  ⇒ 兩者之一成立時，**writer 卡在兩次 shared 取得之間就會自我死鎖**。
- 🔑 **一旦卡死就是整顆 API 卡死，不是一個端點**：北向 API 一次只服務一個請求
  （見 memory `northbound-api-serialises`），所以一條卡住的處理執行緒會佔住整個伺服器。
- **修法**：把 `getFlowInfoJson` 的鎖抽出來（拆成一個不取鎖的內部版本，
  由兩個呼叫端各自取一次），不要靠底層 rwlock 的偏好設定。
  🔄 **09-01 更正：實際落地的修法比這個窄，而且不需要拆函式。** 外層那一行**直接刪掉**即可——
  `getTopKFlowInfoJson` 從頭到尾沒有讀任何成員，它拿到的是 `getFlowInfoJson()` 回的區域副本。
  **不要照上面那句去拆一個 `…Locked()` 內部版本**：那會多一個函式、多一條要維護的鎖規約，
  換到的東西是零。
- 📌 **順帶**：`getTopKFlowInfoJson` 在持有 shared lock 的情況下對整個 JSON 陣列做
  `std::sort`（`:2339-2352`），臨界區長度與流表大小成 O(n log n)。這與死鎖無關，
  但它讓上面那個窗口變寬。
- **證據**：讀碼（2026-08-28）。**未實測**，也沒有已知的觸發紀錄。


### sFlow batching 的老化清掃只在有樣本進來時跑 ⇒ **整個 fabric 同時安靜下來，尾巴留在記憶體裡**

- **狀態**：**潛伏**。旗標是 `NDTWIN_SFLOW_BATCH`，**生產預設 1 ＝ batching 關閉 ⇒ 目前不咬人**。
  truncate／merge 若採用（工單 D/E/F 在評估）就會咬。
- **機制**：`sflow_emitter.py` 的老化 sweep 掛在 `emit()` 裡
  ——**只有樣本進來時才會檢查別的 dpid 有沒有過期**。若整個 fabric 同時安靜，
  沒有任何 `emit()` 被呼叫 ⇒ **每台交換機最後一批部分樣本留在記憶體裡直到 `close()`**。
- 🔴 **緩解措施存在，而且它自己寫下了需求，但沒有呼叫者**：`flush()` 的 docstring 明寫
  *"a caller running the emitter for long periods should call it on a timer as well"*，
  而 `main.py` **只在 `close()` 呼叫它，沒有任何 timer**。
  ⇒ [[existence-is-not-wiring]] 的變體：**不是「有呼叫點沒定義」，是「有定義零呼叫者」，
  而且需求是這段碼自己寫下的。**
- **本輪不修**（修它是行為改變，要有量測支撐），**改為用測試釘住現況**：
  `tests/python/test_sflow_emitter_batching.py::QuietFabricTailIsPinnedNotFixed`
  斷言「整個 fabric 安靜時尾巴仍在 `_pending` 裡」⇒ **未來要修，必須來這裡把斷言改掉，
  不能不知不覺地修掉。**
- **影響量級**：每台交換機最多 `batch_size - 1` 個樣本。batch=8 時＝10 台 × 7 ＝ 70 個樣本
  停在最後一次安靜之後，直到下一次流量或關機。
- **要修的話的形狀**：`main.py` 起一個 timer 週期呼叫 `flush()`，週期 ≤ `batch_max_delay_s`。


### OVS 電源開機把交換機指向 `6633`，目前能通是**巧合**

- **狀態**：**不是缺陷**（實測驗證），但是**潛伏風險**
- **兩個獨立模型（DeepSeek、Muse Spark）都把這條列為 CRITICAL，實測是它們錯了。**
  `OVSPowerStrategy.cpp:112` 執行 `set-controller <sw> tcp:127.0.0.1:6633`，而拓撲檔設
  `CONTROLLER_PORT = 6653`。實測電源循環後：`target: tcp:127.0.0.1:6633` **且
  `is_connected: true`**，撐過兩分鐘；鄰居維持 6653；datapath-id 存活。
  鑑別對照（指向死埠 16633）得到 `is_connected: false, state=BACKOFF`，證明欄位有鑑別力。
- **為什麼能通** —— Ryu 自己的原始碼（`ryu/controller/controller.py:127-135`）：
  ```python
  if not CONF.ofp_tcp_listen_port and not CONF.ofp_ssl_listen_port:
      self.ofp_tcp_listen_port = ofproto_common.OFP_TCP_PORT      # 6653
      # For the backward compatibility, we spawn a server loop
      # listening on the old OpenFlow listen port 6633.
      hub.spawn(self.server_loop, ofproto_common.OFP_TCP_PORT_OLD, ...)   # 6633
  else:
      self.ofp_tcp_listen_port = CONF.ofp_tcp_listen_port          # 只綁這一個
  ```
- 🔴 **`else` 那條分支就是風險**：只要有人在 `ryu-manager` 加上 `--ofp-tcp-listen-port`，
  6633 就不再綁定，而 `powerOn` **不檢查 `is_connected`** 就回 Success →
  每一台電源循環過的交換機被靜默孤立
- **這個事實 repo 裡一個字都沒有**，只寫在 Ryu 的原始碼裡。任何只讀本專案的人都推不出來——
  **這正是讀原始碼的模型會高估缺陷的原因**
- **證據**：實測 ＋ Ryu 原始碼，`scratch/round4/FINDINGS-round4.md` 實驗 1

### OVS `powerOn` 的 `&&` 短路（precondition 目前構不到）

`run("add-br <sw> && set bridge <sw> other-config:datapath-id=...")` —— `add-br` 對已存在的
bridge 會 exit 1，於是 **datapath-id 永遠不會被設**。round 4 實際製造了 ovsdb 競用
（24 個並行 worker，powerOn 從 0.16s 拉長到 3.5s），**零次 ovs-vsctl 失敗**，s7 完全復原。
所以判 REFUTED as tested，但**短路本身是真的且已被示範**——記為潛伏，precondition 不可達。

---

## F. 環境與測試床限制（不是缺陷，但會被誤判成缺陷）

- **Mininet 靜靜忽略 `bw>1000`**（`link.py:238`），所以 128-host 拓撲宣告 10 Gbps 的
  **16 條核心鏈路從未被整形**。實測 htb 144/160，缺的 16 個逐字就是那 16 條。
- **10 Gbps 在這個拓撲裡是算術上構不到的**——每台接取交換機只有 2 條 1 Gbps 上行，
  所以單條核心鏈路上限約 2 Gbps。**換多快的機器都一樣。**
- **電源循環會掉整形，但只有 4 個介面**（144 → 140），而且**對端不受影響**＝效果是**單向的**。
  `OVSPowerStrategy::powerOff` 存了 port 清單但沒存 qdisc。
  ⚠️ **這條更正過**：最初報告成「20 個介面、雙向」，那是把「從未整形的 16 個」
  誤算進去的巧合。
- **bmv2 天花板 —— 2026-08-28/29 四張工單已量過，見下面的 §F-bmv2。**
  **量測型實驗必須記錄用的是哪顆 binary**，否則「速率估計錯了」的結論可能只是丟包的假象。
  🔴 **並且必須記錄 frame size** —— 工單 ② 證明不記錄就是 16× 的歧義。
  舊的無出處數字已退役，理由見 §F-bmv2 最後一段。
- **sFlow 取樣誤差有理論地板**：95% 信賴下 ≈ `196 × √(1/c)`，c = 樣本數。
  **±5% @ 1 秒窗在 bmv2 上不可能**，不是生成器的問題。
  已實測驗證跨 430× 窗長與 10× 負載範圍，見
  `doc/audit/2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md`

### F-bmv2. bmv2 轉發天花板 —— 四張工單的實測結果（2026-08-28／29 收案）

**正本是三個 audit 目錄的 `FINDINGS*.md`，下表是索引不是取代。**
每張工單的 `FINDINGS` 都有一節「What this licenses」明列**不准**由它推出什麼；
引用前讀那一節。

| 工單 | 問題 | 結果 | 正本 |
|---|---|---|---|
| **②** 封包大小 | 天花板是 pps 還是 bps？ | ✅ **pps**。兩個註冊比值都落在 H1 | `doc/audit/2026-08-28_packet-size-sweep/FINDINGS.md` |
| **①** build 比值 | 12× 是 build 的功勞還是路徑的？ | 🔴 **裁不了** —— 梯子在 fast 之前先用完，R ≥ 8.0 是全部量到的 | `doc/audit/2026-08-28_single-switch-build-ratio/FINDINGS.md` |
| **①b** 重跑 | 同上，梯頂改由停止規則決定 | ✅ **R = 8.0 ⇒ H2**，四臂全部因 loss 而停 | 同目錄 `FINDINGS-1b.md` |
| **③** 流數 | 容量隨流數怎麼變？ | ✅ **每流最高乾淨速率兩臂各自單調下降**；🔴 註冊的放棄判準觸發 | `doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md` |

**② —— 天花板是 pps，不是 bps。**
六臂鏡像 `64 256 1024 | 1024 256 64`，單流 h1→h65（s1→s3），**fast build**，128-host P4，kernel `a40e04ce`。
**是 frame size 不是 payload**（iperf3 `-l` 22 / 214 / 982，frame = payload + 42）：

| frame | 乾淨 kpps | 同一批資料換成 Mbit/s |
|---|---|---|
| 64 B | 16.0 | **8.2** |
| 256 B | 20.0 | **41.0** |
| 1024 B | 16.0 | **131.1** |

⇒ **pps 只變 1.25×，bit rate 變 16.0×。** 最強的支持不是這三格本身，而是
**六臂全部在同一階（110 kpps）截斷**，而截斷規則只看 loss、**對 frame size 全盲**。
🔴 **所以「bmv2 大約跑得到 N Mbps」這種句子不是不精確，是 16 倍的歧義。**
⚠️ 解析度只有 **±1 階**；② **不授權**任何關於其他 build／流數／fabric 的敘述。

**①／①b —— 12× 有一部分不是 build 的功勞。**
單跳 h1→h2 on s1、1400 B payload（＝1442 B frame）、**控制平面保持活著**、每臂一個 fabric 世代：

| build | 最高乾淨 | 梯子停在 | 為什麼停 |
|---|---|---|---|
| stock（`EventLogger` 24 個，sha `327fa7d1`） | **45 Mbit/s** | 160 M | 飽和規則 |
| fast（`EventLogger` 0 個，sha `3ff54b5c`） | **360 Mbit/s** | 810 M | 飽和規則 |

**R = 360 / 45 = 8.0 ⇒ H2**：**報告的 12× 有一部分來自三跳路徑與其上的控制平面，不是編譯旗標。**
主張要收窄成「**沿三跳生產路徑 12×**」，而論文必須講明是哪一個。

🔴 **但 H2 不是無條件成立**：一階量到的是「loss ≤ 0.5% 的最高階」，真正的零損點落在該階與下一階之間
⇒ stock ∈ [45, 70)、fast ∈ [360, 540) ⇒ **R ∈ (5.14, 12.0)，而 H1/H2 的邊界 9 就在區間內**。
🔑 **複製救不了這件事** —— 十臂零散布只證明「階」是穩的，
對「真值在階內哪裡」零資訊，因為不確定性是**量化**不是雜訊。
膝蓋形狀內插收窄到 **≈7.8**（**更深進 H2**，也就是離比較好講的 H1 更遠），
但那是**佐證不是量測**，而且**沒有為此再跑更細的梯子**（因為答案不順眼就重量，正是本專案反對的做法）。
⇒ **決策規則缺一支「區間跨過邊界 ⇒ 報不可分辨」，任何未來的比值輪都要先註冊那一支。**

🔴 **差額（8.0 vs 12）是路徑還是控制平面 —— 這是 ① `AMENDMENT-1 §8.2` 開跑前就註冊的另一輪，
本輪與本文件都不得推論。**

📌 換成 pps 是**算術換算不是量測**：45 / 360 Mbit/s @ 1442 B frame ＝ **3.90 / 31.21 kpps**，
**繼承上面同一個量化區間**。⚠️ **不要拿它跟 ② 的 kpps 對帳** —— 跳數、frame size、build 覆蓋範圍都不同，
而 ② 明文不授權跨 build 的敘述。

**③ —— 容量是流數的函數，而且不要用比值講。**
同一路徑類別上的每流最高乾淨速率（≤ 0.5% loss）：

| n（流數） | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| **arm a**（M/flow） | 160 | 110 | 30 | 5 | 2 |
| **arm b**（M/flow） | 240 | 110 | 45 | 8 | 1 |

⇒ **兩臂各自獨立單調下降**，而這個宣稱**不需要任何比值**。
🔴 **「16 流塌陷 3.3×」已撤回且不重算** —— 分子是坐在**平台**上的無損門檻、分母是坐在**膝蓋**上的飽和點，
**兩邊不是同一種量，換任何數字進去病都還在**。新口徑不要用「塌陷」這個詞。
🔴 **註冊的放棄判準觸發**（n=2 兩臂皆 220，註冊區間 95–150），兩個註冊模型判死 —— **殺死一個模型是結果**。
③ **不授權**任何 n=1 與 n=16 之間的比值。

**⇒ 之後任何 bmv2 量測型實驗的最低紀錄要求**：
① 哪一顆 binary（**用 `nm -DC <路徑> | grep -c EventLogger`：0 = fast、24 = stock**，
不要用 mtime 也不要用 PATH 上那顆）、② **frame size 還是 payload**、③ 跳數與路徑類別、
④ 流數、⑤ 控制平面是死是活。**缺任何一項，數字就不能跨輪比較。**

#### 已退役的舊 bmv2 天花板敘述（保留供追溯，**不要再引用**）

原文（§F，2026-08-19 前）：

> stock（`-O0`＋全 logging）約 **40 Mbps / 3.6k pps**；
> `-O3`（`/usr/local/bmv2-fast`）約 **47 kpps / 726 Mbps TCP**。

**為什麼退役 —— 三個理由，其中第三個是自我否證的：**

1. **repo 內查無出處** —— 全 repo `grep` 這四個數字，只命中本檔自己。沒有 audit 目錄、
   沒有原始資料、沒有指名 binary。
2. **它用 Mbps 陳述容量而不講 frame size** —— 正是工單 ② 指認的 **16× 歧義**。
3. 🔴 **fast 那一對自己不自洽**：726 Mbit/s ÷ 47 kpps = **15,447 bit ＝ 1,931 B/frame**，
   **高於標準 MTU frame（1,514 B）**，所以這兩個數字不可能來自標準 MTU 下的**同一次**量測。
   （對照組：stock 那一對隱含 **1,389 B/frame**，落在合理範圍 ⇒ 問題出在 fast 那一對，
   不是出在我的算法。）

⚠️ **沒有被推翻的是方向**：fast build 確實比 stock 快很多，這一點四張工單全部支持。
被退役的是**那四個數值本身、以及由它們算出的任何比值**
（舊數字給的是 Mbps 18.15× / pps 13.06×，兩者互不相等，也都不是實測的 8.0×）。

---

## G. 操作陷阱（會製造假的測試結果）

- 🔴 **任何活過自己 pidfile 的 app，在每一個 `ndt` 介面上同時是隱形且殺不掉的**（2026-08-31
  live 實證）：前一 session 的 TE-App 崩潰迴圈灌了 **100 MB log**（`UnboundLocalError`），
  而 `ndt status`＝`apps none running`、`ndt apps`＝`te -`、**`ndt apps stop te` 回
  rc 0「te not running」**——`app_stop` 只看 `.test_run/pids/app_te.pid`，pidfile 沒了就全盲。
  📦 **那份 100 MB log 已依 Adam 裁定刪除**（08-31，釋出 96.2 MiB）；刪除前的有界證據包
  ＝`doc/audit/2026-08-31_live-recipes/app_te_log_evidence.txt`（14 KB，含原檔 sha256
  `9df3e225…`、逐時直方圖、方法在同目錄 `analyse_app_te_log.py`）。**引用這條的數字請引證據包，
  不要再引已刪除的 log。** 證據包同時更正／收窄了三件事：
  ① 🔴 **「20h32m」不是這份 log 給的**——檔案本身跨 **20h38m39s**、崩潰迴圈跨 **20h07m02s**，
  兩個都不是 20h32m，而 20h32m 這個數字在 repo 裡沒有任何 raw 支撐（形狀像是發現當下的
  `ps` etime 讀數，但沒人記下來，證據包**不替它湊**）。
  ② 🔴 **迴圈不是從頭就有**——前面有 **31m37s 完全乾淨**，第一個例外在 `15:39:10.273`，
  觸發點是 `:8000` 第一次 connection refused。
  ③ 🔑 **這次事件裡它其實沒裝成任何流表規則**——全檔 123,420 條 ERROR **全部**是
  `localhost:8000 connection refused`，整段 20h07m 它一次都沒接到活的 kernel。
  下一行那句「孤兒會裝流表規則」是**風險**（乾淨的那 31 分鐘它確實在跟 kernel 講話），
  不是這次的已發生事實。
  「崩潰迴圈」與「100 MB」則被證據包**確認**：61,710 個**同一種** `UnboundLocalError`、
  穩定 3600 次／小時，全程只有三段約 135 秒的停頓。
  📏 **「這份 log 能不能刪」的判準（08-31 兩次刪除各學到一半，寫成規則）**：
  分界**不是**「它有沒有支撐宣稱」——同一天刪的兩份**都有**。分界是**證據的保存狀態**：
  | 問 | `app_te.log` | `app_viz.log` |
  |---|---|---|
  | 有沒有支撐已發表宣稱 | 有（§G 三個詞） | 有（FINDING-02＋maven 共變數） |
  | 關鍵事實抽出來了嗎 | ❌ 只有 184 byte 的**身分**節錄，**節奏從沒被抽過** | ✅ 當輪就刻意抽成 `covariate_maven_build.txt` |
  | 有沒有等價副本 | ❌ 全世界一份 | ✅ **逐 byte 相同**的副本＋`artifact-baseline.txt` 記著 sha |
  | ⇒ 刪之前要做什麼 | **現做有界證據包** | 不用（但**副本當時不在任何 object store**⇒補進 `audit-raw f9f30c0`） |
  🔴 **查「有沒有被引用」時 grep 範圍要涵蓋 `raw/` 的 `.txt`／`.jsonl` 與 `harness/` 的 `.sh`**——
  只查 `--include="*.md" doc/` 會得到「零引用」的錯誤結論（08-31 我就是這樣答錯 `app_viz.log` 的）。
  這種孤兒會裝流表規則，kernel 一起來就污染量測。正解＝`/proc` 驗身分後按 PID 停。
  🔄 **08-31 修法已落，狀態＝過了單元變異閘、live 未驗（不是 RESOLVED）**：
  `ndt` 加了三態 `app_probe`（`running`／`not-running`／**`pidfile-lost-but-alive`**）、
  `app_scan_pids`（`ps` 只當候選索引、`/proc` 才是判準）、`app_kill_pid`（前後都用
  `pid_is_app` 不用 `kill -0`），並接到 `apps stop`／`apps status`／`status`／`down`
  四個入口；新子命令 **`ndt apps orphans`**（找到孤兒 exit 1）＝量測開跑前的檢查。
  測試 `tests/shell/test_ndt_app_orphans.sh`（52 checks），**七個變異全部看過紅**
  （含「掃描根本不執行」那一支，用來擋「因為沒東西所以通過」）。
  🟢 **live 已補（2026-08-31 15:25–15:30，`ndt up ovs4`）**：養了一隻真的 TE-App
  （mode 2，20 秒內 log 長 5→53 行＝確實在工作），拿走 pidfile 後——
  **修法前的 `c10ac7c` 版本原樣重現壞行為**（`te not running`／rc 0／行程還活著），
  而現行版四個介面全部正確（`apps orphans` rc 1、`apps status` ＝ `ORPHAN`、
  `status --check` 列 `untracked te(...)`、`apps stop te` 印三態訊息並真的停掉）；
  額外一輪 `ndt down` 也把孤兒收掉了（`stopping it by pid`＋`REAPED BY DOWN`）。
  raw＝audit-raw `243e7e7`（`w2_` 前綴）；配方與實測紀錄
  ＝`doc/audit/2026-08-31_live-recipes/rider_app-orphan-stop.md`。
  🔴 **那份配方自己有三個缺陷，已就地更正**，其中一個與 A-1 的 R3 同型：
  控制組原本放 `/tmp`，而 `ndt` 用 `$HERE/../..` 推 `REPO` ⇒ 在 `/tmp` 解成 `/`，
  舊碼於是印出預期的 `te not running` **是因為路徑錯、不是因為缺陷在**——
  **舊碼就算是好的也照樣「通過」**。已改放 `.test_run/ctl/`（gitignore 內、且剛好第二層），
  並新增「先證明控制組看得見那隻 app」的前置步驟。

- 🔴 **`ndt apps stop` 的優雅停止路徑，對 TE-App 在生產上從來沒有作用過**
  （2026-08-31，讀碼＋live 兩面確認）。`app_kill_pid` 先送 SIGTERM、給 5 秒窗
  （10×0.5s，每次用 `pid_is_app` 驗身分）、逾時才 `SIGKILL`。
  但 **`Traffic-engineering-App.py` 一個 signal handler 都沒裝**——
  `signal` 只出現在 `:29` 的 import，全檔零使用 ⇒ SIGTERM 走 **Python 預設處置＝立即結束**。
  **這不是測試缺口，是一個關於生產行為的事實**：那支 app 沒有任何清理機會，
  它正在裝的流表規則會停在半途，而 `apps stop` 回報的 `ok` 只證明行程沒了。
  🔑 順帶推翻配方寫的「多執行緒所以可能不會馬上死」：mode 2 根本不起 listener 執行緒
  （實測 `Threads: 1`），而且**執行緒數與這件事無關**——沒有 handler，幾條執行緒都一樣立刻死。
  ⇒ 要驗 TERM 窗／KILL 回退那段碼，需要一支**自己 trap 住 TERM 不理**的五行 fixture；
  **不要為了測試去改 TE-App 的生產碼**。
  🔑 修的過程順手抓到兩個同源缺陷：① 舊 `app_stop` 對 pidfile 裡的 pid **不驗身分就 `kill`**
  ⇒ pid 被回收就打到路人（本機 `.test_run/pids/app_viz.pid` 從 08-30 起就指著死 pid）；
  ② `ndt down` 的 app 迴圈也用 `app_running` 當閘 ⇒ **最需要停的那隻正好被跳過**。
  🪞 第一版 `app_scan_pids` 用「flatten 後 substring」比對，**當場自我匹配**：
  `bash -c '<提到 app 名字的腳本>'` 整段腳本是一個 argv 元素，掃描器自己的每個 fork 都命中
  （`$$`／`$PPID` 擋不住，fork 有新 pid）。改成**逐 argv 元素比對**（等於 sig 或以 `/sig` 結尾）。
  順帶：TE 的崩因是 `get_graph_data_api_call` 在 except 後 `return graph_data`（未賦值）——
  **Traffic-Engineering-App repo 的缺陷**，excerpt 在 `2026-08-31_live-recipes/te-crashloop-excerpt.txt`。
- 🔴 **「把掃描寫進 script 檔就不會自我匹配」這句話不完整——真正決定的是「在哪一道命令裡執行」**
  （2026-08-31 實測，同一輪內連續踩兩次）。`/proc` 掃描器如果把搜尋字串放在**自己的 cmdline**
  上就會數到自己。已知的解法是「寫進 script 檔」，但那只保護**掃描器自己**：
  - 用 heredoc **在同一道命令裡**產生並執行那支腳本 ⇒ **父 shell 的 cmdline 仍然帶著整段
    heredoc 內容**（含 pattern），掃描照樣多數一個。實測讀數 1，真值 0。
  - 把同一支腳本改成**單獨一道命令**執行（`bash /path/scan.sh`，那一行沒有別的東西）
    ⇒ 讀數 0。**腳本沒改一個字，只換了誰是父行程。**
  🔑 判準不是「命令有沒有寫進檔案」，而是**「從我的行程往上，有沒有任何一個祖先的 cmdline
  含有 pattern」**。⇒ 產生腳本與執行腳本要拆成兩道命令；pattern 一律放腳本內的變數。
  🔑 這也是為什麼「兩個讀數不一致」要先當**儀器發現**：08-31 早上那一輪也是同一個偏移
  （inline 讀 1、真值 0），當時歸因成「inline vs 檔案」，**歸因只對了一半**。

- 🔴 **`git commit -- <path>` 保護的是「不同檔案」，兩個寫者改同一個檔時它一點保護都沒有**
  （2026-08-31 實測；「兩個寫者一個 worktree」的新一式）。共用 worktree 的既定紀律是
  `git commit -m "..." -- <paths>`，那擋得住「把別人的檔一起 commit 進來」，
  但 `-- <path>` 是**按路徑切，不是按 hunk 切**：它送出的是那個檔案**當下工作區的全部內容**。
  於是同一個 `doc/KNOWN-ISSUES.md` 上兩個 session 併行編輯時，實際發生的是——
  **我的 A-2 改動被對方的 commit `e5eae74` 捲走，對方的 virtiofsd 段被我的 `6fd8a4d` 捲走**。
  🔑 **沒有掉資料，但歸屬交叉了，而且完全無聲**：兩邊的 `git commit` 都回 rc 0，
  兩邊的內容事後查都在檔案裡，只有 `git log -S` 問得出來是誰的 commit 帶進來的。
  ⇒ 三條慣例（不設鎖——鎖會腐爛，而且四個寫者沒人會去讀它）：
  ① **傷害來自 dirty 窗口的長度，不是並行本身** ⇒ 改完 `KNOWN-ISSUES.md` 立刻 commit，
  不要讓它跨一個長操作（例如一整個 fabric 窗）留在 dirty；
  ② commit 之後**驗自己的改動在自己的 commit 裡**：`git show <sha> -- doc/KNOWN-ISSUES.md`；
  ③ 引用「某條是誰寫的」時用 `git log -S '<字串>' -- <path>`，**不要用 `%an`**（零資訊）。
  🔴 **同一天第二次，而且是在寫下上面那三條之後發生的：①「立刻 commit」是必要條件，
  不是充分條件。** 08-31 15:46–15:48 我把上面這幾條寫進本檔，兩分鐘內就下 commit，
  **仍然整批被別的 session 的 `3920180` 捲走**——我的 `git commit` 回 rc 1
  「no changes added to commit」，因為工作區已經沒有差異了。
  🔑 **窗口是「第一次 Edit 到 commit」之間的整段時間，不是「我有沒有拖延」**：
  四個寫者時，兩分鐘也輸得掉。⇒ 真正把窗關掉的做法是**編輯與 commit 放進同一道命令**
  （腳本改檔案、緊接著 `git commit -- <path>`），把窗壓到次秒級。
  這條記錄本身就是那樣寫進去的。

- 🔴 **raw 歸檔的守衛是單向的：它擋錯的目的地，沒有任何東西檢查對的目的地發生過**
  （2026-08-31 普查）。
  🔑 **缺口是沉默不是假話——這 15 輪沒有一輪宣稱過自己歸檔了，而且沒有任何地方記錄過
  某輪是否「決定不歸檔」，連意圖都查不到。**
  底下的清單會過期，這個結構不會：**我們的守衛只會對「做錯的事」出聲，不會對「沒做的事」出聲。**
  `tools/githooks/pre-commit` 只做一件事——工作分支上出現 raw 就擋（`:32` 是
  `[[ "$branch" == "audit-raw" ]] && exit 0`）。🔑 **它只在你 commit 的那一刻才有機會說話，
  而「缺席」不觸發任何事件**⇒ 這是「**保護的失效時機與它要防的事件重合**」
  （見 [[failures-that-report-success]]）的又一個實例：**忘記歸檔的那一輪，正好就是
  永遠不會讓 hook 執行到的那一輪。** 要補的不是更嚴的 hook，是一個**在輪次收官時
  主動去問「這輪的 raw 在哪」的檢查**——沒有事件可以掛，就得自己排一個。
  所以 `doc/2026-08-29_bmv2-performance-study.md:219` 那句「raw 一律進 `audit-raw` 分支
  （**pre-commit hook 強制**）」**高估了守衛**：hook 保證的是「raw 不會出現在工作分支」，
  **不是**「raw 已經進了 audit-raw」。
  📊 **普查結果（08-31）：兩個明講過的宣稱都是真的。**
  - ✅ `12_auditor-rulings.md:38`「raw 18 檔＋TE excerpt＋drive_ovs.log 落 audit-raw `d62ff34`」
    ——**逐項對上**：`2026-08-31_live-recipes/raw/` 在 audit-raw 上正好 **18 檔**，
    加 `te-crashloop-excerpt.txt` 共 19，`drive_ovs_a4e_a2.sh` 在列。
    （🪞 我一度把這句讀成在講 08-30 那輪而報成「對不上」——**是我讀錯章節，那句話沒有錯**。
    `audit-raw f9f30c0` 的 commit message 帶著這個誤讀，未推送但不重寫；以本行為準。）
  - ✅ `2026-08-29_europ4-poster-review/smoke/SMOKE-RESULT.md:5`「raw 歸檔＝audit-raw `e19595d`」
    ——commit 存在、是 audit-raw 祖先、該筆加入 **36 檔**，與磁碟相符。
  - 🔴 **但有 15 輪的 raw 不在任何 object store，合計 533.2 MiB**（讀數時 audit-raw 尖端
    ＝`243e7e7`；**這是點取樣不是租約**，輪次還在跑，要用就當場重跑下面那段）。
    其中 **8 輪一個檔都沒有**，扣掉當天還在跑的兩輪（`2026-08-31_f5-fine-grid-round`、
    `2026-08-31_sampling-ceiling-after-merge`）是 **6 輪歷史全缺**：
    `2026-08-25_sampling-rounds`（**1458 檔**）、`2026-08-27_p4guide-v10-tty`、
    `2026-08-27_telemetry-blindness`、`2026-08-28_baseline-architecture-drift`、
    `2026-08-28_bmv2-literature-review`、`2026-08-28_wire-consumer-compat`。
    檔數最大＝`2026-08-28_QM-mirrored-block` 1942 檔；位元組最大＝
    `2026-08-25_large-scale-concurrent` 1187 檔／452.5 MiB
    （`Q_T64/`、`P_Qp/`、`P_Q/`… 是**每臂的證據目錄**，不是 scratch）。
    💰 **成本不是 533 MiB**：文字壓縮率極高，實測 zlib 後約 **32.8 MiB（6.1%）**，
    而其中 **26.2 MiB 全在 `large-scale-concurrent` 一輪**——
    **其餘 14 輪加起來只有約 6.6 MiB**。權衡要用這兩個數字，不要用 533。
    🏁 **08-31 已補完（Adam 線裁「15 輪全補、不分批」）**：13 輪、4899 檔落
    `audit-raw c83d7fe..ad91acc`（**一輪一個 commit**，方便逐輪追）。
    含 `large-scale-concurrent`——**主張已撤回的輪次仍然要補**，因為
    **撤回紀錄本身需要證據**：沒有 raw，下一個人無法判斷當初是量錯了還是解釋錯了，
    而那正是撤回文件唯一要回答的問題。
    驗收＝每輪抽最大的一個檔做 `git cat-file blob | sha256sum` 對磁碟，**13/13 相符**；
    audit-raw 6588→11487 blobs、**移除 0／修改 0**。
    ⏸️ **`2026-08-31` 那兩輪沒補，是刻意的**：檔案在動手前十分鐘內還在被寫。
    **把一個正在被 append 的 log 的半截快照存成「該輪的證據」，比不存更糟**；
    收官時由該輪自己的 session 落檔（`live-recipes` 在 `243e7e7` 就是這樣自己補的）。
    ⚠️ **這 15 輪沒有一輪宣稱過自己歸檔了**，所以這是「紀律沒被執行」不是「宣稱不實」；
    而且**沒有任何地方記錄過某輪是否「決定不歸檔」**——連意圖都查不到，這才是最難補的部分。
  🔬 **重跑這份普查（唯讀，可直接貼）**：
  ```bash
  for r in doc/audit/*/; do
    d=0; g=0
    # 🔴 一輪可以有**好幾個** raw* 目錄，必須全部加總。第一版寫成
    # `find ... -name 'raw*' | head -1`，於是 `2026-08-25_sampling-rounds` 只數到 raw_n、
    # 漏掉 raw_h 與 raw_gil（420 → 實際 1458），`QM-mirrored-block` 196 → 1942。
    # `.gitignore:60` 的 pathspec 之所以是 `raw*` 而不是 `raw/`，就是因為有一輪寫進 raw_n/。
    while read -r rd; do
      # 🔴 必須排除 .gitignore：每個 raw/ 都有一個「工作分支上追蹤、audit-raw 上沒有」的
      # keeper（.gitignore:61 的 `!doc/audit/*/raw*/.gitignore`）。不排除的話 20 個健康的
      # 輪次會各報「少 1 檔」——一個由儀器自己製造出來的缺陷。
      d=$((d + $(find "$rd" -type f ! -name '.gitignore' | wc -l)))
      g=$((g + $(git ls-tree -r --name-only audit-raw -- "$rd" 2>/dev/null | wc -l)))
    done < <(find "$r" -type d -name 'raw*' 2>/dev/null)
    [ "$d" = "$g" ] || printf '%-46s disk=%-6s audit-raw=%-6s\n' "$(basename "$r")" "$d" "$g"
  done
  ```
- 🔑 **發現自己的儀器有 bug 時，先問「它偏向哪一邊」——然後真的去查，不要用感覺答。**
  2026-08-31 一個 session 內我自己寫的三個儀器各壞一次，**三個都是「比較短的那種寫法」**：
  | # | 儀器 | 省事的寫法 | 正確的寫法 | 它偏哪邊 |
  |---|---|---|---|---|
  | 1 | `app_scan_pids` | argv **子字串**比對 | **逐 argv 元素** | 🔺**多報**：在零個 TE 的機器上報 2 隻（掃描器自我匹配） |
  | 2 | 測試的 fixture 註冊 | 陣列（在 command substitution 的 subshell 裡） | 檔案 | ⬛**看不見**：trap 一隻都沒回收，而測試**照樣全綠** |
  | 3 | raw 普查 | `find … \| head -1` | 迴圈加總所有 `raw*` | 🔻**少報**：420 vs 實際 1458 |
  🔴 **我第一次把這三個總結成「全部讓發現變小」，一條一條查完發現那是錯的**——只有 ②③ 是，
  ① 反而多報。**能站得住的共同點不是方向，是「我每次都挑了比較短的寫法」**，
  而短的寫法會倒向**當下比較好講的那一邊**：②③ 少算讓問題看起來不存在，
  ①多算讓我的新工具看起來很靈敏。**三次都對我有利，這不是運氣。**
  ⇒ 判準寫成可執行的：**改儀器之前先寫下「如果這裡壞了，數字會往哪邊跑」，再去驗那一邊。**
  （這條本身就是示範：連「三個同方向」這個觀察，都得逐條驗過才准寫下來。）
- 🔴 **`rm` 一個大檔不會還你空間——VM 的 `virtiofsd` 把它按住了**（2026-08-31 實測）：刪掉
  `app_viz.log` 之後 `du` 少了 17.4 MiB 而 **`df` 一個 byte 都沒回來**。原因＝這個 repo 被
  virtio-fs 掛進 qemu VM，`virtiofsd` 對 guest 碰過的每個檔案留著 fd，**檔名沒了、blocks 還在**。
  當下全機 **606.2 MiB 的已刪除檔案仍佔著 `/`，其中 511.9 MiB 是 `virtiofsd` 按住的**
  （`build/bin/test_routing_strategy` 162.3 MiB、`build/bin/ndtwin_kernel` 68.9 MiB、
  `build/lib/*.a` 約 230 MiB——**全都是早就 `rm` 過的舊 build 產物**）。
  🔑 **這是「VM 對 `ndt status` 隱形」的第二面：它對磁碟簿記也隱形**——`du` 與 `df` 會給你
  兩個相反的答案，而兩個都不是錯的。**空間見底時先查 `/proc/*/fd` 找 deleted 檔，不要再刪東西**
  （再刪也不會回來）。回收方式＝關掉／重開那個 VM，**不是 `kill virtiofsd`**（那是別人的 VM）。
  **量法（唯讀、可直接貼，08-31 實跑過；與獨立寫的 python 版逐數字對過帳）**：

  ```bash
  ROOTDEV=$(stat -c %d /)
  for d in /proc/[0-9]*; do
    c=$(cat "$d/comm" 2>/dev/null) || continue
    for f in "$d"/fd/*; do
      t=$(readlink "$f" 2>/dev/null) || continue
      case "$t" in *' (deleted)') ;; *) continue ;; esac
      # 這一行是關鍵：不濾掉 memfd/socket/pipe 會算出 40 GB，
      # 而那是共享記憶體不是磁碟——67 倍的假警報。
      case "$t" in /memfd:*|/dev/*|anon_inode:*|socket:*|pipe:*) continue ;; esac
      read -r dev sz < <(stat -Lc '%d %s' "$f" 2>/dev/null) || continue
      [ "$dev" = "$ROOTDEV" ] || continue     # 只算 / 上的，別把別的 fs 算進來
      printf '%s\t%s\t%s\n' "$sz" "$c" "${t% (deleted)}"
    done
  done 2>/dev/null | sort -rn > /tmp/delfd.tsv
  awk -F'\t' '{t+=$1; p[$2]+=$1} END {printf "TOTAL %.1f MiB in %d fds\n", t/1048576, NR;
    for (k in p) printf "  %-16s %8.1f MiB\n", k, p[k]/1048576}' /tmp/delfd.tsv | sort -k2 -rn | head -6
  head -5 /tmp/delfd.tsv | awk -F'\t' '{printf "  %8.1f MiB  %-12s %s\n", $1/1048576, $2, $3}'
  ```

  08-31 的輸出＝`TOTAL 606.2 MiB in 450 fds`／`virtiofsd 511.9 MiB`。
  🔑 **不要用 `pgrep -f`／`pkill -f` 找或殺這些持有者**，也不要 kill `virtiofsd`——
  **回收的唯一正解是關掉那個 VM，而那台 VM 是別人的。**
  🔑 **操作推論（比機制本身更常用到）：在這台機器上，「先展開再刪掉」是一個會單向消耗磁碟的
  動作。** 任何「解壓／checkout／複製出來看一眼再刪」的流程，刪的那一步可能不會還你空間，
  於是淨效果只有消耗。08-31 因此**沒有**用 `git worktree add /tmp/rawwt audit-raw`
  （會攤開 514 MiB／6330 個 blob）補檔，改用 plumbing 直接寫 object store——
  `read-tree` → `add -f` → `write-tree` → `commit-tree` → `update-ref`（帶舊值做 compare-and-swap），
  **不動工作區、不動 HEAD、不攤任何檔案到磁碟**，共用 worktree 上還有別的 session 在工作。
- 🔴 **`ndtwin-lab cleanup` 可能殺掉呼叫它的 shell**（內部跑 `mn -c`）。單獨一行跑。
  ⚠️ **本則講的是 `mn -c` 內部的 `pkill -9 -f`；`cleanup` 自己還另外寫了四行 `pkill -f`，見 §G-9。**
  🔄 08-30 收窄（sweep 實讀 `/usr/lib/python3/dist-packages/mininet/clean.py:29/:37/:66`）：
  機制＝`pkill -9 -f`，**argv 對上 pattern 才殺**——`sudo mn -c` 的 shell 不匹配
  `"sudo mnexec"`；命令列帶 topo 腳本名的 driver 會匹配 killprocs。「一定殺」比碼支持的強。
- 🔴 **`cleanup` 不會停掉 topo 的 tmux session**。殘留的 session 讓拓撲拒絕啟動，
  而 `topo-out` 還在印**上一輪**的 pane ——驅動腳本會把屍體讀成活的。
  **正確順序：`stack.sh down` → `topo-stop` → `cleanup`。
  `sudo ndtwin-lab status` 才是誠實的存活檢查。**
  ⚠️ **`sudo` 這兩個字是 08-30 補上的，不是可選的**（`0b6db9e`）：
  `tools/test_workflow/ndtwin-lab:86` 現在對**每一個動詞（含 `status`）**擋非 root 呼叫。
  🔑 **這一改反而讓上面那句話變成真的**——在它之前，非 root 的 `status` 會走
  `:218` 的 `$TMUX list-sessions 2>/dev/null || echo "no lab sessions"`，
  **把 tmux 開不了 socket 的錯誤吞掉、印出一個很有自信的「no lab sessions」**。
  ⇒ **那正是本節在講的失效形狀，而它就長在本節推薦的那個指令上。**
- 🔴 **`pkill -f` 會匹配你自己 shell 的命令列**並殺掉它。用 `pkill -x` 或 PID。
- 🔴 **`until ! pgrep -f 'foo'` 永遠不會結束**——`pgrep -f` 匹配迴圈自己。加 bracket：`'fo[o]'`。
- 🔴 **裸 `sudo -n kill` 無授權，而且失敗是靜默的** → 無聲 no-op 實驗看起來像結果。
  走 `sudo -n mnexec -a 1 kill`，並且**永遠斷言注入成功**後才下結論。
- **`read -p` 的提示在 stdin 是 FIFO 時不會送出**，等提示的驅動腳本必定逾時；
  逾時後 stack.sh 會繼續前進、**在空 fabric 上啟動 proxy**。
- **`ifconfig down` 在 bmv2 上會關掉整台交換機**，不是一條鏈路。用 `tc netem`。
- **bmv2 行程會活過 `mn -c`** 變成孤兒佔住 gRPC port。

### G-2. 整機 harness 與 `ndt` 的五個儀器缺陷（T-4 輪，2026-08-30）

**正本 `doc/audit/2026-08-30_live-full-stack-round/`，每條一個 `FINDING-0n_*.md`。**
🔑 **五條裡有四條是儀器自己的缺陷，只有一條是系統的**——
**新工具第一次實跑，找到的幾乎都是工具自己的問題**，這一輪逐字重演了那個規律。

| # | 缺陷 | 現況 |
|---|---|---|
| **01** | 🔴 **`ndt` 的「model matches fabric」比的是模型和模型，從來不讀 fabric** —— `$hosts` 來自 kernel graph、`$want_hosts` 來自餵給 kernel 的拓撲 JSON，**兩邊同源**。實測它在一座 **128 host** 的 fabric 上印出 `ok model matches fabric: 4 hosts` | 🟢 **已修**（`eae75da`，工單 T-8）。現在第三個量來自 fabric：`fabric_host_count()` 從 `ps` 數 host namespace（`tools/test_workflow/ndt:747-758`）。🔑 **「讀不到」判紅不判綠**——`fabric_host_count` 回 0 代表**讀數失敗**，而舊碼等於對每個值都走那一支 |
| **02** | R-3 收斂表四個數字有三個量的是 **harness 自己的時間**；`port_holder` 看不到 root 擁有的 listener | 🏁 **已修**（`cd440488`，**是本文件基底的祖先**；T-9／T-10）。算術改成 `mark_start()`＋配對當下讀 `date +%s`，新欄位 `own` 才是 app 自己的收斂；`port_holder` 改三態，`LISTENER-OWNER-HIDDEN` 走 skip 不走 pass。**紅綠與變異閘由 auditor 重跑**：34/34 綠、12/12 變異全殺、倒回 `lib.sh` ⇒ 12/34 紅。<br>⚠️ **殘餘（設計上的，非 bug）**：這支 harness **序列**啟動 app，`since_T0` 那一欄**永遠**量的是 harness 的排程 |
| **03** | **唯一一條關於系統的**：kernel 把**排隊未編程**的請求當流表列服務出去，**兩個 fabric 都是**；08-18 之所以沒看到，是因為它的取樣格**第一格就在 t=2** | 見 **B-1**；工單 **T-11**（修法待裁） |
| **04** | **兩條還原路徑都不還原**；`--rebuild` 把 fabric 拆掉就停住 | 已開工單 **T-10**；危險路徑已加勿執行註解 |
| **05** | 一個註冊為 240 秒的窗口實際跑了 **474 秒**；一面**永遠亮著**的 banner | 🏁 **已修**（`cd440488`；T-10）。窗口改成 deadline 驅動（`25_apps_energy.sh:204-227`）⇒ **危險方向（安靜地變短）已封死**；banner 改成 gate 在腳本自己算出來的 `POWERED_OFF` 上。同一次 auditor 重跑涵蓋。<br>🟢 **殘餘也已修（2026-09-03 對帳，碼在此之前就進來了）**：`assert_window_span` 已實作（`doc/audit/2026-08-30_live-full-stack-round/harness/lib.sh`，函式在 `fe76c67b` 上是 `:497`、今天 HEAD 上是 `:556`——**引用前重查行號**）並在 `25_apps_energy.sh:233` 被呼叫，把 `registered/actual/overrun` 變成一條**會紅**的斷言（UNDERRUN／OVERRUN 兩個方向都 `bad`），且每一條路徑都寫出 `${label}_span.tsv`，所以註冊值第一次進了 artefact。`tests/shell/test_harness_instruments.sh` 34/34、`mutate_harness_instruments.sh` 12/12 全殺。⚠️ **仍未 live 跑過**：`25_apps_energy.sh` 是 `2026-09-02_live-round/CHECKPOINT.md` 的 T-20，NOT RUN。⚠️ 另註：240 是腳本字面量（`:204`），**不是預註冊參數**（`grep '240' PREREG.md` 無命中） |

🔴 **row 02 與 row 05 的「現況」欄已經過期（2026-09-02 對帳）——碼早就修了，這一格沒跟上。**
`git merge-base --is-ancestor cd440488 HEAD` ⇒ **rc=0**：commit `cd440488`
（"T-10/FINDING-02: the convergence table measured the harness, and a blind port probe"）
**是本文件基底的祖先**，row 02 的兩個缺陷與 row 05 的兩個缺陷**碼層面都已經在基底裡修好了**。
⚠️ **有一對同內容不同 hash 的雙胞胎**（`e2098033`／`cd440488`、`842cab2e`／`a824b230`），
**只有後者在祖先鏈上**（`e2098033` ⇒ rc=1）——**引用 commit hash 前先確認是哪一顆在你的分支上。**
🔄 **2026-09-02 19:0x Adam 裁決：這兩列的狀態格給例外、標「已修」**（比照 §G-4 的 `ndt sample_rate`——**同樣是不需編譯的 shell，而且紅綠與變異閘都是 auditor 自己跑的**），上面兩格已改；**殘餘另列，不隨狀態一起關掉**。下面三件事是那次對帳的細節：

- ✅ **row 02 的算術已修**：`20_apps_lifecycle.sh:151 mark_start()` 記下 harness 啟動每個 app 的時刻，
  `:261`／`:315` 在配對當下讀 `date +%s`（`T0 + i` 已消失），`:346` 的新欄位 `own`
  ＝ `T_APP[a] − T_START[a]` 才是 app 自己的收斂，`:357` 印一行叫人讀 `own` 不要讀 `since_T0`。
  ⚠️ **殘餘是設計上的**：這支 harness **序列**啟動 app，`since_T0` 那一欄**永遠**量的是 harness 的排程
  ——原本的 `+5 s`／`+1 s` 真值其實是 **≈+229 s／≈+231 s**（誤差 46× 與 231×）。〔親自讀過〕
- ✅ **`port_holder` 的失效機制指認出來了，而且不是「讀不到 `/proc`」**：非 root 跑 `ss -lptnH`
  對別人擁有的 socket **仍會印出 LISTEN 行，只是省略 `users:((…pid=N…))` 欄位**
  ⇒ `out` 非空（提早返回不觸發）⇒ `grep -oE 'pid=[0-9]+'` 抓不到 ⇒ **回空字串**
  ⇒ 每一個呼叫端把它讀成「沒有人在聽」。**「讀不到」被印得跟「沒東西」一模一樣。**
  修後是三態（`""`＝FREE／`<pid>`／**`LISTENER-OWNER-HIDDEN`**），
  `assert_port_is` 對第三態走 **skip（UNTESTABLE）不是 pass**；12 個呼叫端逐一查過沒有被三態打壞。〔親自讀過〕
- 🟢 **row 05 的殘餘也已經修了——這一格 2026-09-03 才跟上（原文寫「真正還沒修的殘餘」）。**
  舊敘述是對的：`:224` 曾經只是 `info`（`info()` 不計入 `CHECKS`／`FAILS`、不寫 `verdicts.jsonl`），
  兩個數字被印出來卻沒有判決。**現在 `25_apps_energy.sh:233` 呼叫 `assert_window_span`**
  （`harness/lib.sh`，`fe76c67b` 上 `:497`、今天 HEAD 上 `:556`——**行號會動，引用前重查**），
  UNDERRUN 與 OVERRUN 兩個方向都走 `bad`，預設容忍 30 s；註冊值、實跑值與 overrun
  **每條路徑都寫進 `${label}_span.tsv`**，所以「窗有沒有被遵守」第一次可以從 raw/ 讀出來。
  `tests/shell/test_harness_instruments.sh` 34/34、`mutate_harness_instruments.sh` 12/12 全殺。
  ⚠️ **但它從來沒有 live 跑過**：`25_apps_energy.sh` 是 `2026-09-02_live-round/CHECKPOINT.md`
  的 **T-20，NOT RUN** ⇒ 這條斷言目前只在單元測試與變異閘裡執行過。
  ⚠️ 另外 **240 這個數字是腳本字面量（`:204`），不是預註冊參數**——`grep '240' PREREG.md` 無命中，
  這一半仍然開著。
  🔑 **「用迭代次數冒充時間」在這個 harness 裡是房子的風格，不是一次手滑**（FINDING-05 的窗口、
  FINDING-02 的 viz 與 te，三次）——`assert_window_span` 是第一個擋得住那個風格的東西。
  🔑 **而這一格自己過期了九天，正是它記載的那個形狀的反方向**：
  **一條過期的「還沒修」會害下一個人重做已經做完的事。**〔實測，2026-09-03 逐項重查〕
- 🟢 **「一行永久回歸測試都沒有留下」也已經不成立了（2026-09-03 重跑那個 grep）**：
  當時 `grep -rlnE 'port_holder|PORT_HOLDER_HIDDEN|r3_convergence|WATCH_ACTUAL|mark_start' tests/ tools/`
  是**無命中**，而今天同一條 grep（加上 `assert_window_span`）命中
  `tests/shell/test_harness_instruments.sh`、`mutate_harness_instruments.sh`、
  `tests/shell/test_preflight_instrument_self_failures.sh`、`mutate_preflight_instrument_self_failures.sh`。
  ⇒ 上面那句「碼是對的，而沒有任何東西守著它」在寫下的當天為真，**今天不再為真**：
  把 `port_holder` 改回兩態、把 `while` 改回 `for i in $(seq …)`，現在都會有東西變紅。
  ⚠️ **守到的仍然只是被抽出來的那幾個函式**——整支 harness 的 live 行為不在任何測試的射程內。
  〔實測，2026-09-03 重跑〕
  ⚠️ 修法分支由 auditor 重跑：34/34 綠、變異 12/12 殺、倒回 `lib.sh` ⇒ 12/34 紅。〔實測，auditor 重跑〕

🔴 **引用這一輪任何數字之前先讀兩件事**：
① **那一輪的網路沒有流量**（R-2 的 1800 個取樣裡 `flows` 全部是 `[]`），
**這一個條件同時弱化了三個結果**——R-2 不可能失敗、F-1 沒有發作、F-5 的窗口沒有競爭對手。
**下一輪最該補的是流量，不是更多取樣也不是更細的格子。**
② **那一輪的量測窗內有十次 `agy` 執行，全部是審查員自己起的**
（`CONTAMINATION-agy-runs-i-started-myself.md`）。

---

### G-6 🔴 `ndt apps sim`／`energy` 印「started」並回 rc 0，而那個 app 可能已經死了

- **狀態**：**已知、未修**（2026-09-02 登記；今天的手動 user test run-01 實地踩到）。
  出處：`doc/audit/2026-09-02_manual-usertest/run-01-sonnet/RECONCILIATION.md` §6（trunk `5da71c74`）。
- **平面**：兩者（是工具缺陷，不是 kernel 缺陷）
- **失效方向**：樂觀 ＋ 靜默——**「失敗回報成功」那一族的又一個實例**
- **機制**（讀碼，行號本文以 `git show HEAD:` 覆核於 trunk）：
  - `tools/test_workflow/ndt:1928-1929` 兩行**只看 `sudo -n "$LAB" …-start` 的 rc**：
    `energy) sudo -n "$LAB" energy-start >/dev/null && ok "energy started (tmux: energy)"`（`sim` 同形）。
  - 而 `tools/test_workflow/ndtwin-lab` 的 `energy-start`（`:158-162`）／`sim-start`（`:173-`）是
    **`tmux new-session -d …` 後面直接 `echo`**——`tmux new-session -d` 只要 session 建得起來就回 0，
    **裡面那支程式秒死也一樣**。⇒ 兩層加起來：**沒有任何一層問過「它還活著嗎」。**
- 🔑 **對照組就在同一個檔案裡，而且是對的**：`app_spawn`（`ndt:1893-1909`）起完之後
  `sleep 1` 再 `kill -0`（`:1902`），死了就印
  `<name> exited immediately -- see .test_run/logs/app_<name>.log` 並把 log 尾三行印出來、**回 1**。
  ⚠️ **走 `app_spawn` 的是 `nsr`（`:1932`）、`viz`（`:1938`）與 `te`（`:1942`）三個**——
  **只有 `energy` 與 `sim` 繞過它**。（口徑更正：不是「只有 nsr 誠實」。）
- 🔴 **停止那一側同樣說謊，而且更直接（2026-09-02 補驗實測）**：
  `ndt apps stop all` 對**從來沒起來過**的 sim／energy 印
  **`ok energy stopped`／`ok sim stopped`、rc 0**
  （raw：`auditor-verification/c_stop_all.txt`）。
  🔑 **同一份輸出裡就有對照組**：同一次呼叫對 `nsr`／`viz`／`te` 印的是
  **`nsr not running`／`viz not running`／`te not running`**——
  **走 pidfile／`app_probe` 那條路的三個誠實，走 tmux 那條路的兩個說謊。**
  ⇒ 這不是「訊息不好」，是**同一個指令的五個目標裡有兩個給了相反的答案**。
- 🔴 **停止側的碼比啟動側更糟一級**：`ndt:1958-1959` 是
  `energy) sudo -n "$LAB" energy-stop >/dev/null 2>&1; ok "energy stopped" ;;`（`sim` 同形）
  ——注意那是 **`;` 不是 `&&`**：**rc 連看都沒看**（啟動側 `:1928-1929` 至少還用了 `&&`）。
  而且 `>/dev/null 2>&1` **丟掉的正是誠實的那句話**：`ndtwin-lab` 的 `energy-stop`（`:163-168`）
  在沒有 session 時印的是 **`no energy session`** 然後 `exit 0`。
  ⇒ **下層說了實話，上層把它丟掉再蓋上一句假話。**〔實測（README §(c) 額外＋`c_stop_all.txt`）＋讀碼〕
- **修法**：`energy`／`sim` 比照 `app_spawn` 的形狀，**啟動側與停止側要一起改**
  （只改一側會留下「起得來報得準、停得掉報不準」的半修）。
  ⚠️ 它們是 root tmux session，
  所以存活檢查要在 `ndtwin-lab` 那一端做（`session_running` ＋ pane 內容或 pid），
  不能只在 `ndt` 這一端補——**否則補的是回報，不是判斷**。
- ⚠️ **本條的證據是 user test 實地踩到的行為 ＋ 讀碼**；`app_spawn` 那顆 `kill -0` 本身也值得一提：
  同一個檔案的 `:1639-1677` 花了一整段論證 `kill -0` 對**停止**路徑是錯的工具（EPERM、pid 回收），
  改用 `pid_is_app`；**啟動路徑這一顆還是 `kill -0`**。對「秒死」這個問題它夠用，但不要當成同一級的檢查。

### G-7 🔴 `ndtwin-lab` 寫死了一個人的絕對路徑，而且**是刻意不可覆寫的** ⇒ 換一台機器就整個 fabric 起不來

- **狀態**：**已知、未修**（2026-09-02 登記）。出處：`doc/audit/2026-09-02_manual-usertest/run-01-sonnet/RECONCILIATION.md` §6（trunk `5da71c74`）。
- **平面**：兩者
- **失效方向**：悲觀 ＋ **診斷指向錯的地方**（`ndt` 說 fabric 不對，真因是路徑不存在）
- **機制**：`tools/test_workflow/ndtwin-lab` **`:51`／`:53`／`:55`／`:56`** 寫死
  `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel`、`NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python`、
  `ENERGY_DIR=/home/adam/Energy-Saving-App`、`SIM_DIR=/home/adam/Simulation-Platform-Manager`；
  `ovs-topo-start`（**`:143-144`**）另外**逐字**跑 `/home/adam/Network-Traffic-Generator/testbed_topo.py`，
  `topo-start`（`:99-100`）跑 `"$NTG_PY" "$BRIDGE"`。
  ⇒ 在別人的 checkout／別的使用者底下，**root tmux pane 秒死**（pane 最後一行是
  `No such file or directory`），而 `ndt up` 只會在 300 秒後說
  **`fabric has 0 hosts, expected 128`**（P4 那邊是 `0/10 switches, manifest missing`）。
  🔑 **手冊那條「開三個終端機」的路徑會動**——因為它不經過這支腳本。
- 🔴 **不要用 env 覆寫來修，那是被實測否決過的**：檔頭 `:26-35` 逐字寫著
  「KERNEL_DIR IS HARDCODED, AND DELIBERATELY NOT OVERRIDABLE. READ THIS BEFORE "FIXING" IT.」，
  理由是 08-30 的 **FINDING-01**：那次 `KERNEL_DIR` 被 export 之後，`ndt`／`stack.sh`／`components.env`
  讀新樹而這支腳本讀主樹 ⇒ **fabric 128、model 4、每一項結構檢查全綠**。
  ⇒ **修法＝安裝期設定檔**（例如 `/etc/ndtwin-lab.conf`，由安裝步驟寫入；
  沒有設定檔或缺 key 就**明確 die 並印出缺哪一項**），**維持「不吃呼叫端 env」的原意**。
- 🔴 **改 repo 那份不會生效，要重裝**：sudoers NOPASSWD 放行的是 **`/usr/local/sbin/ndtwin-lab`**
  （root 擁有；本文覆核**與 trunk HEAD 的 repo 副本 byte-identical**）。
  **手冊的安裝步驟必須含這一步**，否則「我改好了可是行為沒變」會變成下一個人的一小時。
- ⚠️ **行號口徑**：出處檔 §6 寫的是 `ndtwin-lab:26-31`——那是**說明用的檔頭註解區**（`:26-35`），
  **真正的賦值在 `:51-56`**。引用時用後者。〔實測，本文以 `git show HEAD:` 覆核〕
- 🔴 **同一家族還有兩處，而且它們不在 `ndtwin-lab` 裡——修完這支腳本並不會修好它們**
  （2026-09-02 run-01 補驗順帶查到；tester 在 VM 上為了讓東西跑起來，**兩處都動手改過**）：
  1. **Ryu app 的靜態拓樸預設路徑**：`intelligent_router.py:36-38`
     `Path(os.environ.get("NDTWIN_RYU_TOPO_FILE", "/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"))`。
     **比 `ndtwin-lab` 那一族軟**——它**可以**用 `NDTWIN_RYU_TOPO_FILE` 覆寫；
     🔑 **但「可覆寫」對一個照著手冊走的人等於「不可覆寫」，因為手冊沒說要設它，
     而預設值指向的是另一個人的家目錄。** 失效時 Ryu 拿不到拓樸，症狀往下游跑。〔實測，本文覆核〕
  2. 🔴 **`p4_proxy/mininet/bmv2_binary_override` —— 一個 *repo 追蹤* 的檔，內容是 Adam 這台的路徑**
     `/usr/local/bmv2-fast/bin/simple_switch_grpc`。
     **而且它的「沒有 fallback」是刻意設計，不是疏忽**：檔案自己的註解逐字寫著
     「There is NO fallback: delete this file, or comment out every line, and the topology
     REFUSES to start rather than picking a binary for you」，理由是
     **兩個 build 的 `--version` 一模一樣而吞吐量差約 10 倍**——
     **靜靜選一個就是「一個看起來很合理的錯數字」**。
     實作在 `p4_proxy/mininet/p4_testbed_topo.py:180-203`，四種情況各自 raise：
     檔不在（`:184-189`，訊息裡就寫著 "This file is tracked and must name the simple_switch_grpc to run"）／
     全部被註解掉（`:193-197`）／不是絕對路徑（`:199-200`）／指到的不是可執行檔（`:202-203`）。
     ⇒ 🔑 **這一條的結論與另外兩處相反：不要把它改成有 fallback。**
     **要改的是安裝流程——手冊（或 install script）必須寫這個檔**，
     否則新機器上 P4 拓樸會**正確地拒絕啟動**，而使用者不知道要寫什麼。
     〔實測，本文以 `git ls-tree`／`git show HEAD:` 覆核追蹤狀態與四個 raise〕
  ⚠️ **出處檔說 tester 在 VM 上把這兩處改成了 `/home/ndt`／`/usr/local/bin/`**，
  **那是未提交的修改、trunk 至今仍是 `/home/adam`**；引用時不要把 tester 的本機修改讀成 repo 狀態。

### G-8 ⚠️ User Manual 只建 `ndt` 的 symlink ⇒ `ndtwin-lab` 缺席時，`ndt up` 失敗而且不說為什麼

- **狀態**：**已知、未修**（2026-09-02 登記）。出處：`doc/audit/2026-09-02_manual-usertest/run-01-sonnet/RECONCILIATION.md` §6（trunk `5da71c74`）。
- **失效方向**：靜默（**工具 fail-open，手冊缺一步**）
- **機制**：手冊的安裝段只把 `ndt` 連進 PATH，沒有提 `ndtwin-lab`（它還必須裝到
  `/usr/local/sbin/` 並配 sudoers，見 §G-7）。`ndt` 呼叫 `sudo -n "$LAB" …` 拿到的失敗
  **不會被翻譯成「這個工具沒裝」**，使用者看到的是 fabric 起不來。
- 🔑 **兩邊都要修，而且分屬不同 repo**：**文件那一半在 website repo**（安裝步驟補 `ndtwin-lab`）；
  **工具那一半在本 repo**——`ndt` 應該在用它之前先確認它存在且可執行，
  **並說出「缺的是什麼、要裝到哪裡」**。⇒ 只補文件會留下同一個 fail-open。

### G-9 🔴 `ndtwin-lab cleanup` 自己呼叫了四次 `pkill -f` —— 專案硬規矩被寫在 lab 工具裡

- **狀態**：**已知、未修**（2026-09-02 登記）。出處：`doc/audit/2026-09-02_manual-usertest/run-01-sonnet/RECONCILIATION.md` §6（trunk `5da71c74`）。
- **機制**：`tools/test_workflow/ndtwin-lab` 的 `cleanup` 分支裡，
  **`:131`／`:132`／`:133`／`:135` 四行都是 `pkill -f`**——
  `ntg_bmv2_topo.py`、`p4_testbed_topo.py`、`"Network-Traffic-Generator/testbed_topo.py"`、
  `simple_switch_grpc`（`:134` 夾著 `mn -c`）。〔實測，本文以 `git show HEAD:` 覆核；
  出處檔 §6 寫的 `:132-136` 差一行〕
- 🔴 **這與上面那條「`cleanup` 可能殺掉呼叫它的 shell」不是同一件事，兩條要一起讀**：
  那一條講的是 **`mn -c` 內部**的 `pkill -9 -f`（`mininet/clean.py`），
  **本條講的是 `ndtwin-lab` 自己寫的四行**。⇒ 就算 mininet 那邊哪天改乾淨了，這四行還在。
- 🔑 **為什麼值得單獨記**：CLAUDE.md 的規矩是「**永不 `pkill -f`／`pgrep -f` 殺程序**」，
  而 `-f` 比對整條 argv ⇒ **任何指令列提到那些字串的行程都是目標**，
  包含只是 `grep` 它、`tail` 一個檔名有它的檔、或用編輯器打開它的那個 shell。
  這與文末〈同一個字串 `iperf3`〉那一則是**同一個形狀，只是換了字串**。
- **修法候選**：改成 **tmux session／pid 檔定向殺**——這支腳本自己就在管 tmux session
  （`session_running`），要殺的東西幾乎都在它自己起的 session 裡，
  **它有精確的把手卻用了模糊的**。

---

### G-10 🔴 `testbed_topo.py` 的內建自我檢測 128 對 ping 全部失敗，而結尾 banner 照印三個 `OK`

- **狀態**：**已知、未修**（2026-09-03 登記）。出處：`doc/audit/2026-09-02_manual-usertest/run-04-sonnet/`（run-04 BUG-2）與 `doc/audit/2026-09-02_manual-usertest/prep5-ovs-without-p4/REPORT.md` §F3（A-8）。
- **現象**：`sudo python3 testbed_topo.py` 內建的自我檢測對 128 對主機各發一次 ping，
  **128 對全部回報 `1 packets transmitted, 0 received, 100% packet loss`**，
  而它結尾仍然印出
  `Host internet: OK | sFlow reachability: OK | Switch identification: OK`。
- **機制**：那三個 `OK` 是**字串常數，與 ping 結果沒有任何關聯**
  （`testbed_topo.py:142-149`／`:245-246`）；而那批 ping 是在**路徑還在安裝的期間**跑的。
- **反證**：收斂**之後**手動 ping 同一對主機是 **4/4、0% loss**
  （A-8：`h1→h2` avg 0.155 ms、`h1→h100` avg 0.387 ms）。⇒ 網路沒問題，**是自我檢測在說謊**。
- 🔑 **為什麼可以跳過「再驗一輪」直接登記**：**兩個獨立觀測**——
  run-04（sonnet，一台裝過 §6 的機器）與 A-8（prep5，一台**從沒見過 P4**、
  且 `testbed_topo.py` 是不同版本的機器）**各重現一次**，run-04 那次還在兩次獨立重啟＋
  NTG 自己那份副本上都重現。**兩台不同機器、兩份不同的碼、同一個假成功**
  ⇒ 它不是環境造成的，是那段程式本身。**這句寫在這裡，是為了讓後面的人知道
  我們沒有省略驗證步驟，而是已經有兩個獨立來源。**
- ⚠️ **為什麼歸在 G 區（會製造假的測試結果）而不是 B 區**：讀者不會因為它而失敗，
  但會因為它而**相信一個假的結論**——先看到 128 個 `100% packet loss` 會以為 fabric 壞了而去 debug
  不存在的問題，看到結尾三個 `OK` 又會以為沒事。**同一次執行同時給出兩個互相矛盾的訊號，
  而兩個都不是真的。**
- **修法候選**：banner 三欄各自由對應的檢測結果算出來；ping 那批延到路徑安裝完成之後再跑，
  或明講它跑在收斂前、結果不可用。

---

### G-11 🔴 `ndt apps stop` 只殺 bash wrapper —— 三個存活通道一起說謊，而且會汙染別人的數字

- **狀態**：OPEN（2026-09-02 live round 實測）。相關修法在 `fix/g6-ndt-apps-liveness`（未併）。
- **平面**：兩者
- **失效方向**：靜默 ＋ **會製造假的測試結果**
- **會發生什麼**：`ndt apps stop` 之後，viz 的 **JVM 活了 1 小時 54 分、111% CPU、875 MB log**，
  而 **`ndt status`／`ndt apps orphans`／teardown log 三個通道全部說它沒在跑**。
- **機制**：停止的對象是 bash wrapper，不是 wrapper 生出來的 JVM；三個存活檢查查的都是 wrapper。
- 🔴 **後果不只是沒停下來**：它**汙染了 09-02 live round 從 C27（21:44）之後的所有量測**——
  一個 111% CPU 的孤兒在旁邊跑，而每一個檢查都說機器是空的。
- **繞法**：`ndt apps stop` 之後用 `ps -eo pid,comm` 確認沒有 `java`／預期外的長命行程；
  不要拿三個通道之一當證據。
- **證據**：`doc/audit/2026-09-02_live-round/ADDENDUM-01-viz-orphan-contamination.md`

---

### G-12 🔴 一支死掉的 app 留下的**流表規則與鎖**，沒有任何「這台 lab 乾淨嗎」的指令會告訴你

> **與 G-11 的分工**：G-11 是**行程**沒被停掉而三個通道都說停了。
> **這一條相反——行程真的死了，死得乾乾淨淨，但它改過的網路狀態留在原地**，
> 而 `ndt apps orphans` 與 `ndt status --check` 兩個都回綠。

- **狀態**：**OPEN。** 2026-09-05 夜巡 R6 實測（1/1），2026-09-06 登記。
  Adam 2026-09-05 grill 第五輪裁定：**`ndt apps stop`／`ndt apps orphans` 要把該 app 裝的規則
  列出來，但不自動刪**——工單 **W16**（2026-09-05 開，**只開不修**）。
  🔴 **W16 寫在 09-05 夜巡 session 的 scratch 裡，`scratch/` 不進版控**
  ⇒ 這份單子不在 repo，引用前先向該 session 要。
- **平面**：**OVS 實測**（P4 未量）
- **失效方向**：**靜默 ＋ 會製造假的乾淨**——每一個既有的乾淨度檢查都通過，而網路上留著別人的規則
- **會發生什麼**：一支拿了鎖、裝了規則、然後被 `kill -TERM` 的 app（R6 的 `r6_crash_app.py`，
  pid 從 pidfile 取得、指名殺，**沒有用 `pkill -f`**）留下：
  - **規則還在**：s2 上 `pri=96`、`["OUTPUT:2"]` 1 條；
  - **鎖還被死掉的 app 握著**：`acquire_lock graph_lock` 回 **423**
    `{"detail":"lock \"graph_lock\" is held by another client; retry after its TTL","error":"Lock acquisition failed","held_by_lease":4,"retry_after_s":30}`；
  - **`ndt apps orphans` 回 `ok  no untracked app processes` rc=0**；
  - **`ndt status --check` rc=0**。
- 🔑 **對照組（缺陷是這樣被定位出來的）**：`ndt apps orphans` 在**行程還活著**時抓得到
  ——**它看的是行程，不是行程留下的狀態**。（同一件事的反面：09-05 夜巡的 `LAB-RULES.md` 硬規則 10
  記著它會把別的 worktree 的 test fixture 行程算成孤兒。🔴 那份檔在 `scratch/`，不在版控。）
  ⇒ 這不是 orphans 壞了，是**沒有任何一支工具負責回答「網路上還有誰的殘留」**。
- **兩種殘留的自癒能力不一樣**：
  - **鎖會自癒**：TTL 到期後可被接管，且接管者拿到 `reclaimed_expired_lease: true`，有紀錄；
  - 🔴 **規則不會**：沒有 TTL、沒有 owner 欄位、沒有任何清理路徑。**它會一直在那裡轉發流量。**
- 🔴 **影響面**：
  - **對開源社群的 app 生態**：一支崩潰的社群 app 會把整座 fabric 留在一個沒人知道被改過的狀態，
    而下一個使用者跑遍所有既有檢查都是綠的；
  - **對夜巡與量測**：「lab 是乾淨的」這句話目前沒有任何指令支撐得起來
    ——`--check` 比的是 dataplane／host 數／graph edges／拓樸檔 sha，**流表不在它的比對範圍內**
    （`logs/r6-21-check-with-rule.log`：手上握著 `routing_lock`、s1 上有 `pri=99` 改道規則時，
    `check: ok`，沒有任何一列反映這兩件事）。
- **繞法**：把「乾淨」自己定義出來並自己驗——收尾前逐台掃控制器的 flow stats，
  比對 baseline 的 priority 清單（R6 用的就是這個：s1..s10 掃 priority 92–99 → 0 條，
  s1／s2 的完整清單回到 `[0, 10, 10, 10, 10, 65535]`）；鎖則逐把 acquire 一次確認拿得到。
  **不要拿 `ndt apps orphans` 或 `ndt status --check` 當殘留檢查。**
- ⚠️ **沒測到的（R6 自己聲明）**：`ndt down` 會不會清掉這些規則、`ndt up` 會不會繼承，
  **本輪沒測**——角色腳本要求收尾前把規則刪光，與「讓規則活著穿過 `ndt down`」互斥。
  補測成本很低：裝一條標記規則 → `ndt down` → `ndt up` → 查該 priority 還在不在。
- **證據**：**實測 2026-09-05 夜巡 R6**，`scratch/overnight-2026-09-05/rounds/02-R6-appdev.md` **K-3**；
  raw `scratch/overnight-2026-09-05/logs/r6-23-crashapp.log`（逐字：pid 104678、
  `graph_lock` lease 4 ttl=45、s2 `pri=96` install 的 200 body、`now hanging on purpose`）、
  `logs/r6-21-check-with-rule.log`（`--check` 在有規則＋有鎖時 `check: ok`）。
  🔴 **raw 在 `scratch/`，不在版控**——引用前先確認那個 session 的目錄還在。
  ⚠️ **可信度分級**：🟠 **殺掉之後那三行**（規則還在／423 held_by_lease=4／orphans ok）
  **是 R6 的 console 輸出，沒有 tee 成獨立檔，本條登記者也沒有重跑**；
  上面列的兩個 raw 檔涵蓋的是**殺之前的設置**與 **`--check` 的盲點**。
  🟢／🟠 不要混用；要把這條寫進 W16 的驗收條件之前，先重跑一次並存檔。

## 證據索引

| 輪次 | 位置 | 內容 |
|---|---|---|
| 2026-08-19 phase-2 | `scratch/phase2/FINDINGS.md`（1717 行） | 12 個實驗、10 CONFIRMED / 6 REFUTED；計畫在 `PLAN.md`（DeepSeek 盲寫） |
| 2026-08-18 live | `doc/audit/2026-08-18_live-full-stack-round/` | 我 8 條 ＋ subagent 18 條（重疊僅 1 條）＋ sFlow 準確度報告與原始資料 |
| 較早輪次彙整 | `scratch/phase2/DEFECT-INVENTORY.md`（~870 行） | 九輪（07-30 → 08-18）掃描，**92 條已驗證**：64 OPEN、6 明確不修、22 可能已修（列為有爭議而非丟棄） |
| 較早輪次原始 | `doc/audit/`（約 40 個日期目錄） | 見 `doc/audit/README.md` |

## 這份文件的完整性邊界（誠實聲明）

- **舊發現約三分之二仍然為真**（pre-08-12：33 條裡 21 條；含 08-12 那輪則 51 條裡 31 條）。
  衰減**不均勻**，而且模式很銳利：**agy Tier 1 的 6 條全部已修，Tier 2 的 13 條裡 11 條還在（85%）**。
  **嚴重度驅動了修復，其他什麼都沒有。** → 引用任何舊的 Tier 1 清單前務必重查；Tier 2 可近乎照搬。
- 🔴 **328 份 agy review 裡有 213 份從未被分類**（98 HIGH + 113 MEDIUM），
  而且那份分類文件自承它的抽取腳本不可靠。**這是庫存缺口，不是缺陷**，
  但它界定了這份文件能誠實宣稱的完整度上限。
- **一條需要重新裁決而不只是更新狀態**：agy 0211（readopt 部分失敗被 200 吞掉）在 08-17 的
  triage 裡被標為可能與「completion handle」的結論矛盾，並明確指示不要繼承任一答案。
  目前列為 OPEN 且有爭議。
- ⚠️ **一條被掃描列為缺陷、但實際上不是**：「per-link 利用率在定速流量下擺盪 ±40%」
  **是取樣理論的地板，不是缺陷**——`196 × √(1/c)`，已跨 430× 窗長與 10× 負載實測驗證。
  見 `doc/audit/2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md`。
  GUI 上看得到擺盪是真的，但那是**儀器的解析度**，修不掉。

### 2026-08-30 對帳這一輪自己的邊界

- **做了什麼**：§A–§G 逐條把碼重新 grep 一次，對照本週落地的修法。
  **21 條動過**（8 條改狀態或拆分、13 條加日期註記或更正引用），**0 條刪除**。
- 🔴 **這一輪一行都沒有跑。** 量測窗開著，所有判斷都是**讀碼**。
  凡是標「實測」的，一律是引用**別人已經跑完**的結果（T-4 輪 R-5／R-1），不是本輪產生的。
  ⇒ **需要實跑才能定的問題，本輪一律留在 OPEN 並標 ⚠️**，沒有一條靠推論結案。
- ⚠️ **沒有覆蓋到的**：§A 的 A-5／A-6（log 截斷、proxy 啟動訊息）**本輪沒有重驗**；
  §G 除了 `ndtwin-lab` 那兩條之外，其餘都是**外部工具**的行為，讀本 repo 的碼驗不了。
- 🔴 **一個引用陷阱已在 §C 表上補了消歧註，但它的成因沒有被修掉**：
  `doc/audit/2026-08-18_live-full-stack-round/` 裡**兩套 F-n 編號同時存在且撞號**。
  **真正的修法是把其中一套重新編號**，那超出本輪範圍（會動到所有引用點）。
  在那之前，**每一次引用 `F-n` 都要指名是哪一個檔案**。
- ⚠️ **commit sha 對不上的情況會再發生**：本週幾顆修法 commit 在本文件寫下的 sha
  （`4ee086f`／`87d272f`／`a7ab17d`）與交接訊息裡流傳的 sha
  （`dff87f9`／`db02d45`／`e29424e`）**內容相同但 sha 不同**（rebase 造成，`git patch-id` 逐一對過）。
  **本文件一律寫「在 `1208d22` 這條歷史上真的存在」的那顆**；
  引用時若 `git show` 不到，先試 `git log --oneline -S <關鍵字> -- <檔案>` 再說它不存在。

## ✅ 已驗證為正確的核心行為（2026-08-19 round 6）

**「透過 kernel API 裝上的流規則會真的改變轉發嗎？」——四輪從沒驗證過，現在驗了：會，兩個平面都會。**

用 `/proc/net/dev` 的 tx-byte 差（獨立於孿生與交換機表）、規則強迫走**另一個**埠、
三個狀態（裝前／裝後／刪後）、定速流所以整批流量必須移動：

| 平面 | 裝前 | 裝後 | 刪後 |
|---|---|---|---|
| OVS 128-host | 100% 走 s1-eth2 | **100% 走 s1-eth1** | 回到 s1-eth2 ✅ |
| P4 bmv2 | 100% 走 s1-eth2 | **100% 走 s1-eth1** | 🔴 黑洞（見 A-4d） |

**位元對位元的同一個量**，不是比例。資料面切換次秒級，孿生的 `path` 約 3–5 秒跟上。

⚠️ **量路徑變化不要用 `get_path_switch_count`**——OVS 三個狀態它都回 5。
有鑑別力的欄位是 `get_detected_flow_data` 的 `path`。

## 三條對本文件既有敘述的更正（round 6）

1. **128-host 拓撲是 32 條交換機間鏈路 / 288 條邊**，不是 40。（40 是 4-host cell。）
2. **電源循環的 qdisc 遺失在 4-host cell 是 2 個介面**，128-host 是 4 個——
   差別是另兩個面向 10 G 核心鏈路，**Mininet 從來沒整形過它們**（見 §F）。
3. 🔑 **`up=false, en=true` 是關機交換機的正常穩態**，所以
   **「兩個旗標不一致」本身不能當故障訊號**。這收窄了 A-2 指紋的適用範圍——
   A-2 的指紋是特定的 `up=true, en=false`，不是「任何不一致」。

**REFUTED 的紀錄同樣有價值**，別重測：E1（OVS 電源循環後流表**會**重裝）、
E-H3（8 種畸形 dpid 全部正確拒絕、graph diff 空）、`get_openflow_capacity`、
`get_static_topology_json`、批次端點的混合 dpid 誠實度、
E8（雙平面的鏈路故障/恢復都正常，過度回報窗口是 0–30 秒取決於相位）、
E9（top-k 成員/排序/速率全對，`bps ÷ pps` 分毫不差）、E11（`--no-ai` 防護正常）。

### `measure.sh` 內含專案硬規矩禁用的 `pkill -f`，而四輪結果錨在這支儀器上 ⇒ **改它與不改它都有代價**

- **狀態**：**登記的陷阱，不是修票**。2026-08-31 auditor 裁「本輪不改」，理由見下。
- **位置**：`doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh:45-46`（前置清場）與
  **`:99`**（收尾；🔄 **原文寫 `:96`，2026-09-02 覆核為 `:99`，三份 copy 皆同**）：
  `sudo -n mnexec -a "$H33" pkill -f iperf3`。
- 🔴 **「三份 copy 只差輸出目錄一行」也不對，是三行**（2026-09-02 逐份 `diff`）：
  08-20 與 09-01 差 `:25`／`:59`／`:86`，09-01 與 09-02 才只差 `:25`；
  而 **09-02 那份的 `:59`／`:86` 指向的是 09-01 的** `netdev_only.py` 與 `slim_client_json.sh`。
  ⇒ **「逐位元組同一支儀器」這個前提要按 copy 逐對檢查，不能一句帶過。**〔實測，本文重跑 `diff`〕
- 🔴 **它真的會打到別人**：該檔自己的註解寫明 mininet host 共用 root PID namespace
  ——「Hosts share the root PID namespace, **which is why a plain pkill reaches them at all**」
  ⇒ `pkill -f iperf3` 的作用域是整台機器，不是那個 namespace。
  另一個 session 的 iperf3 會被它殺掉，而且**被殺的那一方看到的是自己的量測莫名中斷**。
- 🔴 **CLAUDE.md 的規矩是絕對的**：「永不 `pkill -f`／`pgrep -f` 殺程序」，
  [[destructive-shell-traps]] 記著已經第七次自傷。**專案禁用的動詞，就寫在一支被多輪依賴的儀器裡。**
- **兩難本身才是要登記的東西**：
  - **改它** ⇒ 與 08-20／08-25 D 輪的存檔格**不再是逐位元組同一支儀器**。
    E 輪 §6 的「同 fabric、同 binary 才逐格比」建立在同儀器上；改了就只能比方向。
  - **不改它** ⇒ 總有一天它會殺到別人的 iperf3，而且失敗的形狀是**別人的資料無聲少一段**。
- **目前的緩解（E 輪 08-31 落地，不改 `measure.sh`）**：呼叫端在交棒之前先確認
  **沒有任何不是本輪起的 iperf3**，有就中止該格；列舉用 `ps -eo pid=,comm=` 精確比對 `comm`，
  **不用 `pgrep -f`**（`-f` 的樣式比對永遠會匹配到搜尋命令自己）。
  見 `doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh:foreign_iperf3_guard`。
  ⚠️ **這只保護「呼叫端有檢查」的那些輪**。任何直接跑 `measure.sh` 的人不受保護。
- **要修的話的形狀**：把清場改成「讀 `/proc`、按 PID、只殺本輪記錄下來的那些」，
  並同時給 `measure.sh` 一個版本標記，讓「改版前／改版後」的格永遠分得開
  ——否則修完之後，新舊格會長得一樣而不可比。

### 🔴 同一個字串 `iperf3`，一支**殺**提到它的、一支**赦免**叫它的——而兩支互不知情

- **狀態**：**已知、未修**（2026-09-01，E 輪 72 格跑完後登記）。**上一則的對稱另一半，兩則必須一起讀。**
- **位置**：
  - 殺：`measure.sh:45-46,96` 的 `pkill -f iperf3`（上一則）——`-f` 比對**完整指令列** ⇒
    **任何指令列提到這個字串的行程都是目標**，包括只是 grep 它、tail 一個檔名有它的檔、
    或用編輯器打開它的那個 shell。
  - 赦免：`doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py:66-73` 的
    `FABRIC_PREFIXES` **含 `"iperf3"`**，而 `_is_fabric()`（`:163`）是
    `comm.startswith(FABRIC_PREFIXES)` ⇒ **任何 comm 以它開頭的外來行程被算成「我們的」**，
    直接離開 `foreign_cores` 的統計。
- 🔑 **一個字串、兩個相反的失效模式，都不需要任何人不小心**：
  一支把不相干的行程當成目標，一支把不相干的行程當成自己人。
- 🔴 **它們不知道彼此存在**：本輪已經有 `foreign_iperf3_guard`（`lib_e.sh:278`，三處呼叫）
  在每格開始前擋外來的 iperf3——**專案為其中一個方向做了守衛，另一個方向的洞留在另一個檔裡。**
  ⚠️ 而那個守衛是**開跑前**的一次檢查：**窗中途才出現**的同名行程，會被 `_is_fabric` 歸成自己人。
  🔑 **這與下一則的「壽命盲」是同一條時間軸上的兩個洞**：守衛只看窗**之前**，
  CPU 閘門的差分只看**兩端都在**的行程 ⇒ **窗內起訖的東西，兩支都看不到。兩則要互相指。**
- **怎麼找這一類（比修這一則重要）**：不是讀單支碼，是**對字面常數做全域搜尋，看它被幾種語意用過**。
  同族：`ratio_gate.py:157` 的 `return 0 if verdict=="GREEN" else 1`（**一個值兼「判定」與「執行成敗」**）、
  以及 `comm` 15 字元截斷（同一個名字在 `ps`／`pgrep`／`/proc` 三處有三種長度）。
  ⇒ **通則：一個值或字串在跨越模組邊界時語意會漂移，而漂移不會有人報錯。**
- **修法的形狀**：判別一律走 `/proc/<pid>/exe`（行程設不了它），比對**錨定**（前綴或精確，永不子字串），
  而 `mine`/`foreign` 的歸屬用 **pid 是否在本輪的 fabric manifest 裡**，comm 只當交叉檢查。
- 🔴 **`94e3c4b6`（09-01 壽命修法）沒有碰這個豁免，但改變了它的可達性。**
  兩個 call site 的順序是**相反的**：ladder cell 是**閘門先、`measure.sh` 後**
  （`run_e.sh:136` → `:137`），G5b 是 **`measure.sh` 先、閘門後**（`gates_e.sh:430` → `:433`）。
  ⇒ **修法前**，ladder 的自家 iperf3 在 snapshot A 之後才誕生，被 `:176` 的
  `if pid not in a: continue` 丟掉，**`FABRIC_PREFIXES` 裡的 `"iperf3"` 在 ladder 路徑上是死碼**，
  豁免只在 G5b 承重。**修法後**窗內誕生的行程全額計入，
  ⇒ **豁免在 ladder 路徑上第一次真正生效**：自家的 iperf3 正確歸戶，
  **而任何窗中途冒出來的外來 iperf3 也一起被歸成 `mine` 並印在 `ours` 欄**——
  從「無聲丟棄」變成「主動誤標」。🔑 **洞沒有變大，但變得容易走到，而且留下的痕跡更像證據。**〔親自讀過〕
- 🔴 **`gates_e.sh:433` 的 `--exempt-pid "$load_pid"` 豁免的是 `measure.sh` 那層 shell，不是 iperf3。**
  `$!` 取的是被 `&` 背景化的 `measure.sh`；client 是它的孫輩，server 還因 `--daemon` 雙 fork 脫離。
  ⇒ **既有的 pid 豁免機制沒有在做讀者以為它在做的事**，G5b 之所以綠，唯一支撐仍是名字豁免。
  ⚠️ **因此「把 `"iperf3"` 從 `FABRIC_PREFIXES` 拿掉」在兩個版本上都會停掉整輪**
  （舊版停 G5b，新版連 ladder 一起停）。**順序是：先有 manifest，才談拿掉名字。**〔親自讀過〕
- 🔴 **`gates_e.sh:432` 的 `sleep 20` 是一個 20 秒的窗，不是競態**：
  在這 20 秒內出現的外來 iperf3 **撐過了 `measure.sh:45-46` 的前置清場**，
  進 snapshot A、被名字赦免、被印成 `ours`，然後在 90 秒後被 `:99` 的收尾 kill 殺掉。
  **閘門 GREEN、G5b 記 PASS、對方資料無聲少一段，而三份存檔都說一切正常。**〔讀碼推論〕
- 🔴 **守衛自己就是那把刀的靶。** `lib_e.sh:435` 是
  `pids=$(ps -eo pid=,comm= | awk '$2=="iperf3"{printf "%s ", $1}')`——**那支 `awk` 的 argv 裡就有 `iperf3`**，
  所以 `pkill -f iperf3` 殺得到它。而 `lib_e.sh` 只有 `set -u`，**沒有 `set -e`、沒有 `pipefail`**
  ⇒ awk 被殺 ⇒ `pids` 空 ⇒ `:436` 為假 ⇒ **`return 0`，回報「乾淨」**。
  **守衛被摧毀的瞬間說的是可以繼續。** 兩個 session 併發時可達，而那正是本則的前提。
  **修法**：把比較留在 shell 內（`while read` ＋ `[[ "$_comm" == iperf3 ]]`），
  不要交給 argv 帶著字串的子行程。〔親自讀過；行號本文於 HEAD 與 `4cbec52d` 兩處覆核，皆為 `:435`〕
- **關聯**：上一則（`measure.sh` 的兩難）、[[destructive-shell-traps]]、
  [[grep-endpoints-misses-concatenation]]、[[prove-the-writer-by-cadence]]（硬識別碼 ＞ 內容特徵）。

### 🔴 CPU 汙染閘門有三個洞，其中一個讓「全部由短命行程造成的汙染」讀起來像安靜

- **狀態**：🏁 **碼落地、變異閘過、live 待驗**（2026-09-02，`94e3c4b6`）。三段分開讀，**不標「已修」也不標「未修」**（Adam 09-02 裁決：live 待驗的東西進獨立佇列）：
  - **碼落地**：三個洞一起關——壽命盲＝從 `/proc/<pid>/stat` 起始時刻回推、窗內起的行程**全額計入**；截切改成**只管列印不管加總**；身分改成 `(pid, starttime)`（`comm` 是核心會改寫的標籤，改名的 kworker 不是回收的 pid）。`foreign_cores` 改名 **`foreign_cores_attributable`**、新增 **`unattributed_cores`**（busy − 所有能指名的，是**上界不是歸屬**，永不折進總量）與 **`suspect`**；`UNACCOUNTED-SHORT-LIVED` 那一行**每次都印**，含零。suspect 刻意**不是第四個 exit code**。
  - **變異閘過**：`tests/shell/mutate_cpu_gate_lifetime.sh` **11/11** 全抓（22 顆 unittest，fixture procfs 樹；起始時刻的欄位索引另對真 `/proc` 驗過，fixture 不能跟錯的 parser 互相同意）；接線的 `mutate_cell_gate_suspect_wiring.sh` **6/6**（12 個 case）。🔑 兩支 harness 都把「變異沒套上」「測試根本沒跑」與「存活」**分開報**——第二支第一次跑就靠這個抓到 harness 自己的錯（perl 替換字串漏了擷取群組、把 `lib_e.sh` 弄壞、測試在 source 就死、被讀成 SURVIVED）。
  - **配對驗收已在實機跑過**（`cpu_gate.lifetime-acceptance.log`：648 個短命子行程、約 3.6 核）：舊閘 **excess 0.007 GREEN**；新閘 GREEN 但 **suspect=true unattributed=3.635**。`acceptance.sh` 現在從 git 拉修法前版本 `6a28e81d`，其 sha256 `897b8996…` **與 log 記的一致**。
  - **接線**：`lib_e.sh:cell_cpu_gate_finish` 讀 `suspect`／`unattributed_cores`；suspect 的格、以及 **record 裡根本沒有 `suspect` 欄位的格**（＝舊版閘門寫的、從沒看過的），都記進 `cell_cpu/SUSPECT_CELLS`，**不 abort**。缺一個警告不等於乾淨——那是哨兵值那條的形狀。
  - 🔴 **live 待驗，原因**：接線只在單元測試與變異閘下執行過。E 輪 72 格已收工、F5 未開跑，**沒有任何活的輪次跑過這條接線**；下一個用 `lib_e.sh` 的活輪次才是第一次。⚠️ 而 E 輪報告引用的 72 格 gate 判讀**是舊閘門給的**——那些 GREEN 沒有 `suspect` 欄位，依上面的規則全部是 UNKNOWN，不是 quiet。
  - 🗄️ 原狀態：「已知、未修（2026-09-01）。E 輪 72 格全程依賴這支閘門，且它的判讀已寫進該輪報告的口徑。」——後半句照舊成立，見上一點。
- **位置**：`doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py`。
- **三個洞**（按嚴重度）：
  1. 🔴 **壽命盲**（`:176` `if pid not in a: continue`）：閘門取前後兩張 `/proc` 快照做差分，
     **窗中途才啟動的行程沒有前值 ⇒ 直接跳過，連 `foreign_cores` 的加總都進不去**（不是只從條列拿掉）。
     ⇒ **一格全部由短命 `bash`/`awk`/`sed`／反覆 `qemu-img` 造成的汙染，讀起來與安靜的格子完全一樣。**
     碼自己的註解是誠實的（`no baseline, cannot attribute`）——**缺陷在下游把它當「總量」用。**
  2. **截切**（`:181` `cores <= 0.005`）：大量各自很小的行程一起消失，對同一種形狀加乘。
  3. **前綴赦免**（`:163`）：見上一則。
- 🔑 **壽命盲與偵測地板是正交的兩件事，報告必須兩句都寫**：
  地板是**大小**問題（≲0.95 核看不見）、壽命盲是**時間**問題（**窗內起訖者不論多大都貢獻 0**）。
  **只寫地板，讀者會以為「夠大就會被抓到」——不會。**
- 🔴 **而缺口的大小本身沒有被記錄，事後補不回來**：`excluded_midwindow` 這個數字對已跑完的格子
  不存在，快照沒留。**報告要明寫「這個量沒有被記錄」，空白會被讀成零。**
- **修法的形狀**：中途啟動的行程從 `/proc/<pid>/stat` 第 22 欄（起始時刻）回推歸屬；
  真的做不到時**輸出一個 `UNACCOUNTED-SHORT-LIVED` 計數，而且它要能讓那一格變 suspect**
  ——一個被跳過的行程**不可以**印得跟「沒有行程」一樣。並把 `foreign_cores` 改名成
  `foreign_cores_attributable`、附 `excluded_midwindow=N`：**把界限帶進值裡，因為名字會旅行、註解不會。**
- **關聯**：[[failures-that-report-success]]、[[verify-the-purpose-not-the-mechanism]]、
  [[controls-decide-what-you-learn]]。

### 🔴 兩個守衛**在最需要它們的時候**失效：E-P4 的 fail-open，與中止時銷毀自己的現場

- **狀態**：🏁 **兩者皆已修（2026-09-01 下午，`6c75bc3c`）。** 以下的問題描述保留原文不動，
  因為它是**為什麼要這樣修**的唯一記載；只有這一行狀態換過。
  - (a) `run_e.sh:203` 改成 `case "$(ep4_verdict "$pv" "$v")"`，夥伴列缺失走 `MISSING-PARTNER`
    分支**中止**而不是靜靜略過；判定本身抽成 `lib_e.sh:ep4_verdict` 才測得到。
  - (b) `lib_e.sh:185` 的 `abort()` 在 `restore_production` **之前**呼叫
    `preserve_abort_evidence`（`:125`）落盤 pane。⚠️ **修法用 `ndtwin-lab topo-out` 而不是
    本條原本開的藥方 `tmux capture-pane`**——後者要 root，`sudo tmux` 會要密碼，
    在它唯一存在的那個情境（半夜無人的中止路徑）會無聲失敗。
  - 變異閘：六顆變異、六顆被**以它命名的那一格**殺掉、零存活。
  - ⚠️ 本條在 09-01 下午一度停在「已知、未修」而修法早已推上去——**一個過期的「未修」
    會讓人重做已經做完的事**，與過期的「已修」同樣危險，方向相反。
- **(a) E-P4 停跑規則的 `-n "$pv"` 會 fail-open**
  （`doc/audit/2026-08-31_sampling-ceiling-after-merge/run_e.sh:186`）：
  `[[ -n "$pv" && "$pv" != *SATURATED* && "$v" == *SATURATED* ]]`。
  夥伴列在 `cells.tsv` 裡找不到時，**條件為假、規則靜靜地不適用，且不印任何東西**。
  E 輪 leg 1 曾在 25/48 中止 ⇒ **若當時直接開 leg 2，四階中的三階沒有夥伴列，
  那條「凍結的」安全規則會對它們無聲失效。** 靠的是開跑前一個腳本外的 24 列檢查擋下來。
  🔑 **形狀**：**為了讓檢查安全而加的子句，正是讓它變空洞的那一句**（同 `n > 0 &&`）。
- **(b) 中止路徑銷毀唯一寫著失敗原因的地方**
  （`lib_e.sh:72-77` 的 `abort()` → `restore_production` → `teardown`）：
  topology 跑在 tmux session 裡，**它對自己啟動失敗說的每一句話都只在那個 pane，不進 `$LOG`**。
  E 輪 02:10:58 的 `fabric short of 10` 因此**永遠查不出原因**。
  🔴 **而清理是正確的動作**——它把 production kernel 與 P4 常數放回去了。
  **不是「做錯了什麼」，是兩個都正確的動作順序錯了。**
  🔑 **更尖的一點**：保住現場的分支**已經存在**（`FORCED_ABORT` ⇒ 不跑 restore、fabric 留著），
  但它**接在「注入的測試」那一半**——而注入的中止原因是已知的（是我們選的），
  **真的中止的原因才是所有人在找的東西。**
- **修法的形狀**：(a) 夥伴列缺失要**大聲失敗**而不是靜靜略過；(b) `abort()` 在 `restore_production`
  之前先 `tmux capture-pane -p -S -` 落盤到 `$ROUND/raw/`，或讓 `topo-start` 直接 tee 到檔案。
  **保留診斷與還原生產狀態不衝突，現在的碼只是沒有把兩者分開。**
- **關聯**：[[failures-that-report-success]]、[[evidence-must-outlive-the-handoff]]、
  [[injections-must-assert-their-own-success]]。

### 🟡 生產線在跑的那顆 kernel 的重建配方，現在補回了大半——缺的那半是**原始碼狀態**

> 🏁 **2026-09-01 中午更新，標題與狀態都換過。** 原標題是「全機**唯一沒有重建配方**的 binary，
> 而它只有兩份、都在同一顆碟上」，兩個宣稱**都已不準**：份數是三不是二（第三份 08-31 20:40
> 就存在了，本則寫的時候沒查到），而建置設定**一直在那顆 binary 裡面**，沒人打開看。
> 下面的原文逐條保留並標註，因為推翻它的理由比結論有用。

- **狀態**：**兩件修法都已落地**（provenance 已寫、離碟副本已推），**但不是 RESOLVED**——
  「怎麼再造一顆一樣的」仍然答不出來，只是問題從「什麼都不知道」縮成「不知道是哪個 source 狀態」。
- 🔑 **本則自己示範了一次「沒去找就當作找不到」**：原文寫「沒有重建配方」，而那顆 binary
  **not stripped、帶 debug_info**，`DW_AT_producer` 存著編譯器對自己那次呼叫的紀錄：
  `GNU C++23 13.3.0 -mtune=generic -march=x86-64 -g -O0 -std=c++23 …`，`DW_AT_comp_dir`
  指著 build 目錄。**「查不到」與「沒查」在紀錄上長得一模一樣**，而這則當時寫的是前者。
- **事實（2026-09-01 中午重查）**：
  - `e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94` 磁碟上**三份**（原文寫兩份）：
    `build/bin/ndtwin_kernel`（活的那顆，且 `sudo -n mnexec sha256sum /proc/<pid>/exe` 確認
    **正在跑的行程也是它**）、`.test_run/binaries/e-round/ndtwin_kernel.production-backup`、
    以及 `~/ndtwin-artifacts/production-kernel/ndtwin_kernel.production-2026-08-31`（附自己的 README）。
  - 🔴 **三份仍然全在 `dev=66309`**（`/dev/nvme0n1p5` 掛在 `/`），而**這台機器沒有第二顆實體碟**
    ——`/media/adam/Windows-SSD` 是同一顆 NVMe 的另一個分割區。**三份仍然等於一次磁碟故障**，
    且該碟 09-01 是 **92% 滿**。⇒ 原文「零冗餘」的結論**成立，份數錯了不影響它**。
  - 三份都被 `.gitignore` 排除，**兩條不同的規則各蓋一份**（`:9` `build/`、`:21` `.test_run/`），
    `git ls-files .test_run/` ⇒ **0 個檔在版控裡**。
  - 🔴 **而它們住的兩個目錄，正是任何人清磁碟時最先刪的兩個**：`build/`（重編就有）與
    `.test_run/`（看起來像暫存）。**不是「有兩份所以還好」，是兩份都在慣例上可拋的位置。**
  - 🔴 **它沒有 `.provenance` 檔。** 同一個目錄裡，本輪為了**丟棄用的**兩個實驗臂
    （`recompute-1khz` / `recompute-1hz`）各有一份**建置期**寫下的完整 provenance：
    commit、source 檔 sha、編譯器版本、`CMAKE_BUILD_TYPE`、旗標、gtest 結果、`readelf -d` 的 RUNPATH。
  - `.test_run/binaries/` 裡更早的三顆（`3367d0e9`／`ab2d7ed1`／`a40e04ce`）的 provenance
    依那些檔自己的說明是**事後補寫的，且只能記 `commit=UNKNOWN`**。
- 🔑 **倒過來的優先序**：**為了丟棄而建的臂有完整配方，生產線上跑的那顆沒有。**
  「哪一顆在跑」答得出來（sha 對得到），「**怎麼再造一顆一樣的**」答不出來。
- 🔑 **這條同時解釋了一條一直只有結論沒有理由的規矩**：專案常設「**不要清 `.test_run/`**」。
  理由就在這裡——**那個目錄裝著每一個實驗臂的 binary，而且整個不在版控**（原文寫「production kernel
  的**唯一**備份」，09-01 中午起不再是唯一：`~/ndtwin-artifacts/` 有一份、`audit-raw` 有一份離碟的。
  ⚠️ **規矩不因此放寬**——實驗臂的 binary 仍然只有這一個地方有）。
  ⚠️ **規矩存在、理由沒有被寫下來** ⇒ 任何不知道理由的人都可能因為「那看起來像暫存目錄」而清掉它。
- **本輪的依賴有多深**：E 輪 72 格每一次 `restore_production`（`lib_e.sh:760`）都是
  `cp "$KBIN_BACKUP" "$KBIN"`。**七小時的實驗、兩次中止後的還原，全部靠這一份同碟副本。**
  它沒出事，但**沒出事不是設計**。
- **修法的形狀**（兩件，缺一不可）：
  1. **補一份 provenance**——若真的重建不出來，**那份檔案就寫「無法重建」與已知的一切**
     （sha、size、`readelf -d`、觀察到的行為）。**一個查不到的答案要留下痕跡，否則下一個人會以為沒人找過。**
  2. **弄一份離開這顆碟的副本**。`audit-raw` 今晚剛好示範了同一件事：
     **沒推的東西在別的地方不存在**——E 輪有一條 §6 對帳因為舊 raw 只在未推的 `audit-raw` 而做不成。
- 🏁 **兩件都做完了（2026-09-01 中午）**：
  1. `.test_run/binaries/e-round/ndtwin_kernel.production-backup.provenance`
     ——**三種證據強度分節寫**，因為它們不可互換：
     **MEASURED**（從 binary 自己讀出來的：sha、build-id、`DW_AT_producer` 的完整旗標、
     `comp_dir`、無 RUNPATH）／**RECOVERED**（從 `build/` 讀的：`CMakeCache.txt` 的
     `CMAKE_BUILD_TYPE=Debug`、`build.ninja` 的 target 旗標／defines／includes／連結線
     ——但 `build/` 是可變目錄，若它被重生過這一節就在描述另一次建置）／
     **INFERRED**（時鐘算術：建置視窗 11:33:05–11:33:48、當時 HEAD＝`9df0a1c`）。
  2. `audit-raw` `3687892`：`ndtwin_kernel.production-backup.gz`（`gzip -9n`，22.3 MB）
     ＋ provenance ＋ 分支 README 的適用範圍修訂。**驗收條件是把分支上的 blob 解壓回來
     sha256 對磁碟原檔**，不是「push 成功」。
- 🔴 **還沒關上的那一半，寫清楚免得被讀成已解決**：
  - **原始碼狀態不可考。** DWARF 5 的 line table **沒有帶 source MD5**（File Name Table 只有
    Dir／Name 兩欄，已查），所以**無法從 binary 反推 source**。
  - `head_at_build_time=9df0a1c` **是推論不是 provenance**：**HEAD 不等於工作樹**，而這是
    **共用 worktree**，11:33 當下 `src/` 有未提交修改是「可能」而不是「不太可能」，且現在追不回來。
  - **從沒試過 byte-for-byte 重建**，而且**不該用顯而易見的方法試**——那會覆蓋
    `build/bin/ndtwin_kernel`，也就是活的生產 binary。要試就 build 到別的目錄。
- **關聯**：[[benchmark-must-name-the-binary-it-measured]]（指認量到的 binary ≠ 能再造它）、
  [[packaging-a-filesystem-ships-the-invisible]]、[[evidence-must-outlive-the-handoff]]。

### G-3 🔴 chaos harness 的 B-3 控制組打的兩條路由都不存在 ⇒ 「重現了」是 404 造的

> **編號 2026-09-02 定案**（原臨時編號 `NEW-CHAOS-C07`）。這一則要與 §B 的 **B-3** 互相指。

- **狀態**：**已知、未修**（2026-09-02 登記）。**碼沒有被動過。**
- **位置**：`doc/audit/2026-08-28_chaos-harness/harness/actions.py` 的 `_c07`：
  `:275` POST `/ndt/set_historical_logging`、`:281` GET `/ndt/get_historical_data`、
  `:293` 的 undo 再 POST 一次前者。
- **機制**：kernel 只有 `POST /ndt/historical_logging`（路由在 `src/ndt_core/http/HttpSession.cpp:289`，
  且 `state` 是 **query 參數、body 被忽略**）。
  **那兩個名字在 `src/`／`include/` 是 0 命中**（只出現在兩行舊名註解裡）
  ⇒ 未匹配的 target 走 `handleNotFound` ⇒ **404 `{"error":"Not Found"}`**。
  而 `probes.py` 的 `api_get` **刻意丟棄狀態碼**（該函式 docstring 自己寫明）
  ⇒ `d = {"error":"Not Found"}` ⇒ `d.get("rows", [])` ⇒ `rows == 0`
  ⇒ 判定 **「none written, B-3 reproduced」**。
  ⇒ 🔴 **這個控制組不論 B-3 修好與否都回 True，鑑別力為零。**
  〔親自讀過（auditor grep 確認兩條路由 0 命中）；**未執行 harness**〕
- 🔴 **受影響的既有宣稱**：`2026-08-28_chaos-harness/05_first-live-run.md:203` 的
  「The control reproduces B-3 … It verified true」**是這個假象，不是 B-3 的證據**。
  （`H-9` 記的是另一件事——控制與 INV-07 配錯對；**兩件獨立，H-9 沒有涵蓋這一件**。）
- 🔑 **形狀**：**丟棄狀態碼的探針 ＋ 「數到 0 就算重現」的判準 ＝ 一個永遠會通過的控制組。**
  與文末〈哨兵值〉那一則同族：**「讀不到」與「答案是 0」產生同一個結論。**

### G-4 🏁 `ndt status` 的 `sample rate` 欄對「取樣被關掉」是盲的 —— **已修**

> **編號 2026-09-02 定案**（原臨時編號 `NEW-NDT-SAMPLE-RATE`）。
> ⚠️ **它是機制批改那一輪唯一可以標「已修」的**：**不需編譯的 shell**，而且**紅→綠與變異閘都由 auditor 自己跑過**。
> §G-2 的 row 02／05 後來依同一條理由獲得例外（Adam 19:0x）。

- **狀態**：🏁 **已修（2026-09-02，trunk `f2836fc3`，已推 lab）。**
- **修前的機制**：`tools/test_workflow/ndt` 的 `sample_rate()`（`4cbec52d` 的 `:444-445`）
  只取 compiled JSON 裡 rng 的**上界**（`int(hi[1],16)+1`）
  ⇒ **下界被改成 1（＝取樣完全關閉）時照樣印 `1/256`**。
  而它的兄弟 `stale_pipeline()` 只抓「live fabric 下重編」這一個方向，
  **抓不到「還原了原始碼但沒重編」**（JSON 比 manifest 舊 ⇒ 回傳 false）。
  ⇒ **`ndt status` 正是操作者用來回答「lab 回到生產狀態了嗎」的指令，而它對最該擋的那一種還原失敗回答「1/256」。**
  〔親自讀過（auditor 親讀）〕
- **修法**：`sample_rate()` 改讀**兩個界**、新增 `rate_label()`（`:549`）與
  `source_ahead_of_build()`（`:540`）、`cmd_status` 兩個新 problem，四個印出點改用 label。
  **取樣關掉時值改成文字**（設計裁量：故意讓任何做 `1/N` 算術的 parser 大聲壞；
  repo 內查無 parser ⇒ 風險 0，四個消費端 `:579`／`:596`／`:1293`／`:1296` 全是印出、無算術無比較）。
- **證據**：紅（`ndt.old`）rc=1（lo=1 印 256）／綠 rc=0 6/6／**變異閘 3/3 全抓**、baseline byte-identical；
  測試 `tests/shell/test_ndt_sample_rate_reads_both_bounds.sh`＋
  `tests/shell/mutate_ndt_sample_rate_reads_both_bounds.sh`。以 atomic rename 換檔
  （另一 session 執行中的 `ndt` 不受影響）。〔實測，auditor 重跑〕

### G-5 🔴 還原路徑有十二份各自為政的抄本，而沒有任何一份驗到編譯產物

> **編號 2026-09-02 定案**（原臨時編號 `NEW-P4-RESTORE-COPIES`）。**狀態：已知、未修。**

- **共用 helper 不存在**：`grep -rn -iE "restore_production|restore_p4|assert_restore" tools/ p4_proxy/`
  ⇒ **無輸出**。`lib_e.sh` 是唯一被 `source` 共用的檔，但**它只服務 E 輪**。
  ⇒ **改一份不會修好其他份。**〔親自讀過〕
- **十二份 `compile_at`（sed ＋ p4c）**：九個同名函式
  （`2026-08-20…/matrix.sh:60`、`2026-08-25_sampling-rounds/{run_c.sh:42,ctl_c.sh:47,gate_d.sh:69,
  ladder_ext.sh:73,wall_f.sh:66,gil_g.sh:57,h_probe.sh:51}`、`2026-09-01_cpu-matrix-1hz/matrix_1hz.sh:65`）
  ＋ `2026-08-31_sampling-ceiling-after-merge/lib_e.sh:800`（**唯一會 `abort` 的**）
  ＋ `2026-09-02_recompute-paired-ab/run_ab.sh` 的 `p4_compile()`
  ＋ `2026-08-25_sampling-rounds/run_e8.sh:36-38`（inline，無函式）。〔親自讀過〕
  ⚠️ **`run_ab.sh` 的行號本週已經動過**：fix-design 讀的是 `4cbec52d`（`restore_all():54`／
  `p4_compile():118`），而在本文件的基底 `fc9ef81a` 上是 **`restore_all():65-111`／`p4_compile():143`**
  （`fc9ef81a` 動了 trap）。**引用前重查。**〔實測，本文以 `git show` 逐一覆核〕
- 🔴 **共同的盲點：斷言查的是原始碼，不是編譯產物。**
  `lib_e.sh:904` 只驗 `.p4` 的 `SAMPLE_RATE=256`，而它對 compiled JSON 只驗
  **`"op":"truncate"` 存在**——**truncate op 在每一個 rate、以及取樣關閉的 build 裡都在**
  ⇒ **對本輪真正動的那個軸零鑑別力**。`run_f5.sh:287/:294` 同形。
  ⇒ 印出來的「source and compiled JSON agree」**不是那個函式建立的事實**。〔親自讀過〕
- 🔴 **`lib_e.sh:931` 的 `RUN cp -f "$KBIN_BACKUP" "$KBIN"` 終局正確是意外，不是設計**：
  它在 `:934 teardown` **之前**跑，即 stack 還活著；`RUN`（`:211`）只是 `"$@"`，**呼叫端沒讀 rc**。
  `cp -f` 碰到 ETXTBSY 會**unlink 目的檔再建新檔** ⇒ **磁碟上的檔案變對、跑著的行程仍是實驗臂**
  （從已 unlink 的 inode 執行），靠下一行 `teardown` 把它殺掉才收尾正確。
  而 `:932` 印的 sha **量的是檔案不是行程**。
  ⇒ **修法：對調 `cp`／`teardown`、讀 `cp` 的 rc、斷言 compiled JSON 的 rate 與 rng 兩個界。**
  〔親自讀過（auditor 親讀）〕
  ✅ **正確範本已經存在，不必發明**：`run_ab.sh` 的 `restore_all()`（**`fc9ef81a` 上是 `:65-111`**：
  先 `stack.sh down` 再動 binary、`if p4_compile` 讀 rc、`if ! cp` 讀 `cp` 的 rc、
  `sha256sum "$KBIN"` 比對硬編碼的 `PROD_SHA`）、
  `2026-08-25_large-scale-concurrent/restart_kernel.sh:11,72`
  （`:11` 逐字寫著「acceptance test here is not "the command ran" -- it is the sha256 of
  `/proc/<newpid>/exe`」，`:72` 真的去讀）。〔實測，本文覆核〕
- ✅ **`run_e8` 的曝險窗已經查過，結論是「查了、沒有」不是「沒去找」**：
  窗＝2026-08-26 **02:18:34**（`run_e8.log:48` ABORT，當時 `SAMPLE_RATE = 8`＝32× 生產值、
  且該腳本**明寫不還原**）→ **02:59:00**（`wall_f.log:1` 開跑並先重編），約 40 分鐘。
  掃 `lab/audit-raw` 的 `doc/audit/2026-08-25_sampling-rounds/` **1458 個檔**、三種時間樣式
  （`^\[02:(18-59):`／ISO `2026-08-26[T ]02:(18-59)`、`08-26 02:`／epoch `1787681914..1787684340`）
  ⇒ **三種都 0 命中**。⚠️ **盲點寫下來**：不帶任何時間戳的 raw 檔不在這三種樣式的覆蓋內，未逐檔開。
  🔑 **沒有資料落在窗內是查出來的結果，但沒被咬到靠的仍是運氣不是還原。**〔實測，auditor 重跑〕
- ⚠️ **仍未關閉**：`audit-raw` 分支**內容**沒讀 ⇒ 08-26 窗未完全排除；
  `zero_cell.sh` 09-02 00:23 當下的 compiled JSON 狀態**永久不可考**。

### 哨兵值會製造**空洞的通過**：兩個「讀不到」彼此相等 ⇒ 首尾對帳成功

- **狀態**：**通則，已在 2026-08-31 的兩支新量測腳本上實際發生並修好**。登記在此是因為它
  不屬於任何一輪——它是一種寫法的性質。
- **形狀**：一個函式在失敗時回傳哨兵字串（`NO-KERNEL-PROCESS`、`UNREADABLE`、`N/A`、`""`），
  呼叫端拿它做**相等比較**（首尾括號、前後對帳、A/B 比值）。
  🔴 **兩個哨兵值彼此相等** ⇒ 一個**從頭到尾都讀不到**的量測，比較會「成功」。
  失效方向是最壞的那個：**完全沒有資料** 與 **資料完全一致** 產生同一個結論。
- **實例（08-31，E 與 F-5 的 binary 身分括號）**：
  ```bash
  running_kernel_sha() { ... || echo "UNREADABLE"; }
  sha_open=$(running_kernel_sha);  # ... 量測 ...
  sha_close=$(running_kernel_sha)
  [[ "$sha_open" == "$sha_close" ]] || abort   # ← 兩邊都 UNREADABLE 時通過
  ```
  🔑 **寫這段的人，在同一份檔案裡寫了「讀不到 ≠ 通過」的警語。** 知道規則不等於套用規則。
- **修法（兩層，缺一不可）**：
  1. **形狀檢查**：比較之前先斷言值長得像一個答案（`[[ "$v" =~ ^[0-9a-f]{64}$ ]]`）。
     形狀不對 ⇒ **中止**，不是通過、也不是警告。
  2. 🔴 **判準看輸出，不看 exit code**：讓檢查印出
     `verdict=MATCH|MISMATCH|UNREADABLE`，呼叫端 grep `verdict=MATCH`。
     **`exit 0` 表示「跑完了」，不表示「答案是對的」**——而「檢查根本沒跑到」也會 exit 0。
- **怎麼找出既有的實例**：找「回傳哨兵字串的函式」與「拿它的回傳值做 `==` / `!=`」的組合。
  同族還有：`grep -c` 回 0（沒命中）與真的是 0 個不可分辨；
  空陣列的平均；以及任何「兩邊都缺席 ⇒ 差為零 ⇒ 判定通過」的比值。
- **關聯**：[[failures-that-report-success]]（第 N 個機制）、
  [[injections-must-assert-their-own-success]]、
  [[verify-the-purpose-not-the-mechanism]]（每個閘門要 force-red **也要** force-green）。

### 量測腳本的 log 後綴會**疊加**：`run_f5.dryrun.selftest.dryrun.log`

- **狀態**：🏁 **已修（2026-09-01 中午，兩輪一起）。** 解凍理由：E 輪 72/72 已收工、F5 尚未開跑
  （動手前自驗：三支腳本各 **0 個行程**在跑；⚠️ 第一次用 `ps | grep -c` 讀到 3，那是**我自己的
  指令列在自我匹配**——計數不能用，要列出來看）。**F5 一開跑儀器就凍結，這是唯一的窗。**
  <br>原狀態：「已知、未修（2026-08-31，穩定優先）。目前只是難看；疊到第三層就會開始撞名。」
- **機制**（三件事湊起來，單獨看都合理）：
  1. `round.env` **`export LOG=`** ⇒ 子行程**繼承**父行程的 `LOG`；
  2. `run_f5.sh` 在 `DRY_RUN=1` 時做 `LOG="${LOG%.log}.dryrun.log"`；
  3. 模式派發時再做 `LOG="${LOG%.log}.<mode>.log"`。
  ⇒ 父行程 `selftest`（dry）得到 `run_f5.dryrun.selftest.log`，
  它**再 spawn 一個 `arm` 子行程**，子行程繼承那個**已經加過後綴**的值並**再加一次**
  ⇒ `run_f5.dryrun.selftest.dryrun.log`。**後綴的層數＝行程巢狀的層數。**
- 🔑 **為什麼會發生**：後綴邏輯假設它拿到的是**原始**檔名，而 `export` 讓它拿到的是
  **上一層的成品**。**冪等性沒有被檢查過**——`f(f(x)) ≠ f(x)`。
- **修法的形狀**（不要只是把 `export` 拿掉，那會讓子行程寫回同一個檔）：
  由 `round.env` 匯出一個**不變的** `LOG_BASE`，各行程一律從 `LOG_BASE` **重新**推導自己的
  `LOG`，而不是修改繼承來的值。這樣後綴就對巢狀免疫。
- **影響範圍**：`run_f5.sh`（已觀察到）。`run_e.sh`／`gates_e.sh` 同樣 `export LOG` 且同樣有
  dryrun 後綴，**但目前沒有 spawn 子行程的模式會再套一次**——`gates_e.sh` 的矩陣**確實**
  spawn `run_e.sh`，所以**同一個形狀在 E 也具備條件**，只是還沒產生撞名的檔名。
  ⇒ **修的時候兩輪一起修。**
- 🏁 **落地的形狀（09-01）**：`round.env` 匯出**不變的 `LOG_BASE`**（E＝`run_e.log`、F5＝`run_f5.log`），
  每支腳本用 `derive_log <base> <suffix>…` **從 base 重新推導**，不再對繼承來的 `LOG` 動手。
  `derive_log` 是**純函式**（base 進、名字出、不讀全域）⇒ 巢狀構不到它。
  寫自己檔案的 `gates_e.sh` 在 source `lib_e.sh` 之前先設自己的 `LOG_BASE`。
  🔑 **另加一道斷言而不是只靠慣例**：`assert_log_is_derived` 在 `DRY_RUN=1` 而 `LOG` 不含
  `.dryrun.` 時（或反向）**exit 2**——因為「每個呼叫端都要記得推導」是慣例，
  **而沒人檢查的慣例正是原缺陷活下來的方式**。
  測試 `tests/shell/test_log_suffix_idempotent.sh`（15 格，含逐字重現
  `run_f5.dryrun.selftest.dryrun.log` 的巢狀情境）＋變異閘 6 個變異零存活。
  🔴 **變異閘抓到的兩個洞都在測試裡**：①測試 shell 沒有 `LOG`，所以「改讀 `$LOG`」那個變異**是惰性的**
  ——fixture 重現的是一個**該缺陷不可能存在的環境**；②case 9 只 grep 訊息**沒檢查 rc**，
  於是把 `exit 2` 換成 `:` 照樣綠（**「警告但繼續」正是 `lib_e.sh` 前言明文禁止的**）。
