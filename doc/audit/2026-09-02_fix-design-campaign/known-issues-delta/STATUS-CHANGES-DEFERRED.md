# 被擋下的狀態變更（**沒有**進 `KNOWN-ISSUES.mechanism.diff`）

**依據**：Adam 2026-09-02 裁決——**狀態變更（OPEN／RESOLVED／翻案／拆條）一律延到
C++ 分支編譯並過各自的變異閘之後**（對帳簿 `## Adam 裁決 14:2x` 第 4 點）。

**本檔的用途**：批次編譯那一輪跑完之後，這就是「該改哪些狀態行」的清單。
**每一項都寫了要拿什麼證據才解鎖**——不要用「分支存在」或「測試綠」當解鎖條件，
那是 [[existence-is-not-wiring]] 與「沒看過紅不算交付」兩條的形狀。

**共 25 項。** 分支／commit 一律引對帳簿 `LEDGER.md` 或對應的 fix-design 檔。

---

## 🔄 2026-09-02 19:0x 之後的處置（本檔從「待辦」變成「對照表」）

Adam 19:0x 裁決 ＋ 批次過閘之後，這 25 項已經分流。**本檔的列號就是 `KNOWN-ISSUES.status.diff`
每個 hunk 的標籤**（`@@ … @@ #n …`），所以要丟哪一列就丟哪一個 hunk。

| 去向 | 列 |
|---|---|
| 🔄 **已寫進 `KNOWN-ISSUES.rulings.diff`**（Adam 直接裁的，不等閘門） | **#21 F-4 翻案**、**#24 A-2 的 Ryu vendoring**、§G-2 row 02／05 的例外、六條 `NEW-*` 的正式編號 |
| 🟢 **已寫進 `KNOWN-ISSUES.status.diff`，等整合報告確認後套用** | #1 F-1、#2 C-3、#8 A-9（kernel 側）、#13 B-3（只有揭露那一半）、#14 B-2b＋B-4、#15 B-x、#16 F-6、#17／#18 F-8、#19 F-13、#20 F-14＋F-16、#22 F-15、#23 A-2 item 3、#25 A-4e 標題 |
| ⏳ **仍 OPEN，各自留了一行「待 live 驗證佇列」**（也在 status.diff 裡，但不是翻面） | #3 A-4d、#5 A-4c、#7 A-8、#4 A-4g（示範後開單）、#11／#12 B-1 拆條、#10 B-2② |
| 🔴 **佔位、可丟**（閘門 rc=2 baseline 紅，且守衛因跨分支互動判紅） | #6 A-4f |

⚠️ **下面的原始清單保留不動**，因為每一列的「解鎖需要什麼」仍然是驗收那一列的判準——
**翻面之後回頭查「當初說要什麼證據」的人，讀的是這一份。**

| # | 條目 | 提議的變更 | 出自 | 解鎖需要什麼 |
|---|---|---|---|---|
| 1 | **§C 表 F-1** | OPEN → RESOLVED | `F-1.md` §8 Q1／Q2（**agent 自己也建議先不標**） | 分支 `fix/f-1-mininet-health-metrics` @ `316703e7`。Python 6 顆已由 auditor 重跑紅／綠。🔴 **C++ `tests/test_SimulatedDeviceMetrics.cpp` 8 個 `TEST_F` NOT COMPILED、never seen red** ⇒ 要**編譯** ＋ `tests/shell/mutate_f1_mininet_health_metrics.sh` 的 M1–M7＋C1 全殺（**M5「更好的假值」若存活＝套件釘的是舊公式不是性質**） |
| 2 | **NEW-DCAPM-TEMP-FRONT**（`:1594` UB） | 開單並修（一行搬位） | `LEDGER.md`「F-1 順手 UB」 | **編譯** ＋ 一顆在 `ip` 為空的頂點上會紅的測試。目前只有讀碼確認、未執行 |
| 3 | **A-4d** | OPEN → RESOLVED | `A-4d.md` | 分支 `fix/a-4d-delete-restores-p4-route` @ `a1a4a295`。Python 變異閘 auditor 已重跑（6 顆 3 紅、3 控制組綠）。⇒ 要 **§6.2 的 live 驗證（含三組負控制）**：裝→刪之後表上還在且回到 P0 |
| 4 | **NEW-BLOCK_HOST** | 開獨立單、排在示範之後 | `A-4d.md` §7 Q4；**Adam 09-02 已裁「示範沒有此動作 ⇒ 開單排後」** | 目前是**兩端讀碼、未執行**。要升級成實測需在 P4 上送一次 BLOCK_HOST 並讀回真表 |
| 5 | **A-4c** | OPEN → 「誠實改動已落、回填未做」 | `A-4c.md` §7 Q4 | 分支 `fix/a4c-proxy-restart-honesty` @ `05976e27`；75 tests auditor 已重跑（綠 rc=0／倒回四檔 rc=1 errors=21）。🔴 **解鎖的關鍵不是測試**：新欄位（`boot_id`＋per-switch `table_generation`）**目前沒有任何 kernel 讀者**——有寫者沒讀者 ⇒ **要先接線**，再編譯、再過閘 |
| 6 | **A-4f** | OPEN → RESOLVED | `A-4f.md` §7 | 分支 `fix/a-4f-sflow-lost-on-power-cycle` @ `f0fb29e8`。Python 13 紅→綠、4/4 mutant（**agent 跑的，auditor 未重跑**）；**C++ 11 個測試 UNVERIFIED**。⇒ 編譯＋閘 ＋ **先查 sudoers 是否允許 `ovs-vsctl get bridge`／`list sflow`**（否則修法安靜地半殘）＋ live 驗「樣本真的回來了」而不是「指令 rc=0」 |
| 7 | **A-8** | OPEN → RESOLVED | `A-8.md` §7 問題 3 | pin `a7849…` @ `fb68ef1d`；22＋113 綠、倒回三檔 15 紅 4 錯（auditor 重跑）。⇒ **live R5 一輪**：`40_r5_p4.sh:324`／`50_r5_ovs.sh:219` 是字面 grep（`switch(es) not up`／`BROKEN`），新路徑不可出現這些字 ＋ Adam 定 exit code 3 對 CI 的語意 |
| 8 | **A-9** | OPEN → RESOLVED（kernel 側） | `A-9.md` §7 | 分支 `fix/a-9-lock-lease` 3 commits。🔴 **UNVERIFIED：沒看過紅也沒看過綠**，只跑過 23/23 mutation-target 唯一性 ＋ `bash -n`。⇒ 編譯＋變異閘。**app 側是跨 repo，另外裁** |
| 9 | **A-9 的標題** | 「永遠不放」→「放了 300 秒又立刻搶回去（polling livelock）」 | `A-9.md` §2.0 | Adam 裁決。**改標題＝改這份文件的引用鍵**，屬「拆條／改編號」那一族，不是機制補正 |
| 10 | **B-2 ②**（無 owner） | 維持 OPEN（**不要因為 A-9 的 `leaseId` 而順手關掉**） | `A-9.md` B2／B7 | A-9 的 `leaseId` 就是②要的 token，但 `setRequireLeaseId()` **預設關、而且沒有接線** ⇒ ②仍 OPEN。解鎖＝接線 ＋ 跨 repo 協定改動 |
| 11 | **B-1** | **拆成 B-1a（P4，RESOLVED）／B-1b（OVS，OPEN）** | `B-1-VERIFY.md` §7 選項三（agent 的建議） | 🔴 「OVS 上過濾器不生效」目前是**讀碼推論、沒有在 OVS 上實跑**。要拆條之前先把它變成觀測（一次 OVS live：送一條會被交換機拒的規則，看它有沒有被服務出去） |
| 12 | **§D 的 F-5 重裁** | 受 #11 影響，一併重看 | `B-1-VERIFY.md` §7 末 | 等 #11 的 OVS 實測。**F-5 是否解鎖併發控制前置，是 Adam 的題** |
| 13 | **B-3** | OPEN → 「揭露 RESOLVED、本體仍未修」（`status` 變成可分辨） | `B-3.md` §8 | 分支 `fix/b3-historical-logging-honest-reply`，**三顆 commit 要一起落**（`626084bb` seam+tests／`8a1dcbdd` 行為／`3f04b99e` allowlist——少了第三顆，`check_logs.py` 對每個 MININET run 都會變紅）。**NOT COMPILED、never seen red** ⇒ 編譯 ＋ `tests/shell/mutate_b3_historical_logging.sh`（9 個 C++ 變異＋1 控制＋1 已實跑的 allowlist 變異）全殺 |
| 14 | **B-2b ＋ B-4** | OPEN → RESOLVED | `B-2b-B-4.md` §7 Q4 | pin `a6f97…` @ `8084c6fc`；Python 4 綠／倒回 2 紅（auditor 重跑）；**C++ UNVERIFIED**。🔴 **Adam 09-02 已裁：全部站點掃完才合**（19 個 `execCommand` ＋ 22 處手工 JSON ＋ 2 處）⇒ 掃完 ＋ 零殘留 grep 守衛 ＋ 編譯 ＋ 閘 |
| 15 | **B-x** | OPEN → RESOLVED | `B-x.md` §7 Q1／Q5 | 分支 `fix/bx-flow-liveness` @ `58aa5569`；**C++ UNVERIFIED，且有一個 case 在修法前會 segfault 中斷 gtest**（所以「紅」要看得出是斷言紅不是崩潰）。⇒ 編譯＋閘 ＋ Adam 裁 Q1（端點預設要不要真的只回 active）與 Q5（三個新欄位在契約裡 optional 還是 required） |
| 16 | **§C 表 F-6** | OPEN → RESOLVED | `F-6.md` §8 | pin `a8c31…` @ `4a004db7`；**C++ UNVERIFIED**（演算法以 Python 轉寫 40 斷言＋6 mutant 全殺，**那只證明演算法不證明 C++**）。⇒ 編譯＋閘 ＋ 決定不變式 `inv_tables_non_empty` 怎麼處理新的 `never_read` 狀態（**已知會變紅**） |
| 17 | **§C 表 F-8（狀態）** | OPEN → RESOLVED | `F-8.md` §8 | 分支 `fix/F-8-declared-link-capacity` @ `53f7957a`；**C++ UNVERIFIED**，Python 契約 auditor 未重跑。⇒ 編譯＋閘 |
| 18 | **§C 表 F-8（措辭）** | 那一格的「**F-8 是暫態、會被真資料取代**」→「**在有流量的邊上是暫態；在從未有流量的邊上是永久**」 | `F-8.md` §2.4 | 🔴 **這一改會連帶影響 §D 那一族「反正會被真資料蓋掉」的裁定理由**，所以它不是純文字修飾。⇒ 與 #17 同批，並回頭檢查 §D。**diff 裡只在表格下加了一行指路，沒有動那一格。** |
| 19 | **§C 表 F-13** | ①OPEN → RESOLVED；②該列敘述從「對**不存在的** group/meter 做 modify/delete」擴寫成「**6×2 十二格、六格錯**（含 install-on-existing 兩格）」 | `F-13.md` §7 | `fix/f13-group-meter-existence` @ `3ce21cc5`（🔴 agent 原本在 detached HEAD 上 commit，已由 auditor pin）；30 個 gtest **未編譯**。⇒ 編譯＋閘 ＋ Adam 裁 pre-check 引進的 TOCTOU race（只縮窗不關窗） |
| 20 | **§C 表 F-14 ＋ F-16** | OPEN → RESOLVED | `F-14-F-16-F-4.md` §8 | 分支 `fix/optimistic-topology-reporting-f14-f16-f4` @ `21712f3b`；7 個測試（含 2 個負控制）**UNVERIFIED**。⇒ 編譯＋閘 ＋ §7.3 的 live 配方（含負控制）＋ Adam 裁 Q2（`kMissesBeforeIsolating = 2` 帶來的 60 秒）與 Q4（`is_up==false` 用在 host 上的語意） |
| 21 | 🔴 **§D 的 F-4「2026-08-18 不修」** | **翻案**（agent 建議 (a)：翻案並併入 F-14/F-16 的修法） | `F-14-F-16-F-4.md` §3 ＋ §8 Q1；`LEDGER.md`「**建議翻案 F-4 的 08-18『不修』**，留 Adam」 | **這一項的解鎖條件不是編譯，是 Adam 的裁決。** 兩邊的論證都寫在 `F-14-F-16-F-4.md` §3。⚠️ agent 自陳**沒有重驗 F-4 的發作率**（不准跑 Mininet），第 3 點論證是引用 08-18 的記述不是新觀測。<br>⚠️ 若裁「維持不修」，**必須把 F-4 的三道守衛 revert 掉**——否則 `reconcileDerivedLiveness` 與 `updateHosts` 會在同一條邊上打架，只因執行順序才看起來沒事 |
| 22 | **§C 表 F-15** | OPEN → RESOLVED（port block 50050 → 30050） | `F-15.md` §8 | `fix/f15-grpc-port-block` @ `858ebda2`；27 綠／把 base 翻回 50050 得 rc=1、4 紅（auditor 重跑）。🔴 **Adam 09-02 已裁：接受換號，文件與 probe 同一次合併改完**（~20 處文件＋5 支手跑 probe 仍寫 50051；歷史 audit 記錄不改、列為 historical）⇒ 全部改完 ＋ 一次 live bring-up |
| 23 | **A-2 的 item 3**（「部分套用」未處理） | 「未處理」→「已裁決並落地（`05edac65`）：維持套用拿到的那一半，但把一輪分類為 `Complete`／`Partial`／`Silent` 並邊沿觸發一行帶 `topology-round-partial` token 的 WARN」 | `A-2.md` §3.1／§8 | commit `05edac65`（5 檔 +929／−0），**已 commit、未 push、未編譯、未見紅**。閘＝`tests/shell/mutate_a2_poll_round.sh`（9 顆計入＋1 顆 declared＋1 顆負控制），**會編譯，本輪未跑**。⇒ 編譯＋跑閘。<br>⚠️ **declared survivor 要單獨收**：「`pollControlPlaneTopology` 有沒有真的呼叫新記帳」不在變異射程內（呼叫點夾在三個 live curl 之間）——收法是只 stall **一個**端點，`grep -c 'topology-round-partial' kernel.log` 期望**恰好 1** |
| 24 | **A-2 的 item 2**（Ryu 側成因） | 「Ryu 那端完全沒動」→「成因仍在，但在 **stock 套件**裡；patch 已備妥」 | `A-2.md` §3.4／§8 | Ryu patch（`A-2_ryu_rest_topology_bounded.patch`，三個 handler 各包 `hub.Timeout(3s)` ⇒ **HTTP 503 ＋空 body**）：`patch -p1 --dry-run` exit 0、Python 測試**紅→綠都實際跑過**。🔴 **但未落地、未 live，而且落地方式要 Adam 裁**——那是 stock 套件檔，**重裝就還原、clone 也拿不到**；建議 vendor 進 repo 並改 `stack.sh:720` 的 app 名字。<br>🔑 **body 必須是空的**：`utils::execCommand` 是裸 `popen`、只收 stdout、**丟掉 exit status**，HTTP status code 根本到不了 kernel；5xx 帶 body 會被判成「答了」並丟進 `json::parse`——**比 wedge 更糟**。3 秒必須 < kernel 的 `--max-time 5` |
| 25 | **A-4e 的標題標記** | `### A-4e 🔴 …` → `🟢 …（已修）` | `A-4e.md` §A.5 | **純一致性修正**：狀態行早就是 `🟢 RESOLVED（2026-08-31）`，標題的 🔴 與它矛盾。<br>⚠️ **我判不出這算不算裁決所說的「狀態變更」**——它不改變任何狀態，只是讓一條 entry 不再自我矛盾。**diff 裡只加了一行「以狀態行為準」的註**，標記沒動。⇒ 請 Adam 一句話決定 |

---

## 🟡 三項邊界情形，請 Adam 明示

1. **§G-2 的 row 02 與 row 05**：「已開工單 T-9／T-10」→「碼已修（`cd440488`，**是本文件基底的祖先**）
   ＋ 殘餘＝註冊窗與實跑窗從未被比較」。
   分支 `ndt-harness-t9-t10-instruments` @ `b4059384`，34/34 綠、變異 12/12 殺、
   倒回 `lib.sh` ⇒ 12/34 紅（**auditor 重跑**）。
   🔑 **這是 shell、不需要編譯，證據強度與獲准標「已修」的 `ndt sample_rate` 那條完全相同。**
   **我沒有改狀態格，只在表下加了事實說明**——因為裁決的字面涵蓋「狀態變更」而沒有分平面。
   ⇒ **建議 Adam 比照 `NEW-NDT-SAMPLE-RATE` 給一個明示例外。**
   ⚠️ 另註：`ndt-harness-t9-t10-instruments` 分支**自己改了 `doc/KNOWN-ISSUES.md` 4 行**
   （對帳簿記載），**合併前要看，否則會與本 diff 撞在同一個檔上**。

2. **六條 `NEW-*` 新條目的最終編號與擺放位置**（`NEW-BLOCK_HOST`／`NEW-HTTP-200-DEFAULT`／
   `NEW-DCAPM-TEMP-FRONT`／`NEW-CHAOS-C07`／`NEW-NDT-SAMPLE-RATE`／`NEW-P4-RESTORE-COPIES`）。
   我按「讀者會在哪裡找它」擺，不是按嚴重度。
   🔴 **`NEW-HTTP-200-DEFAULT` 我最沒把握**（見 `NOTES.md` §6.3）：它目前在 §B 的 B-3 之前，
   但它其實是一條**跨全部 route 的設計性質**，可能該進 §C 或 §G。

3. **A-7 的 `IntentTranslator.cpp:733` 該不該是自己的一條新條目。**
   協調者交辦時說「add as a NEW entry」。我**沒有另開一條**，而是併進了第一批寫的
   **`NEW-BLOCK_HOST`**——因為經覆核**那是同一個呼叫站點**（`:728` 空 `actions`／
   `:733` 丟掉 `OpResult`／`:739` 無條件 success 是同一段 `try` 裡的三行）。
   另開一條會製造這份文件自己警告過的**兩套編號指同一個地方**。
   ⇒ 如果 auditor 仍要兩條（理由可以是「一條講 P4 不生效、一條講兩平面都謊報成功」，
   那確實是兩個不同的失效方向），**拆的時候要在兩條裡互相指**。

---

## 🆕 第五波新增的一項（`KNOWN-ISSUES.usertest2.diff`）

| # | 條目 | 狀態 | 解鎖需要什麼 |
|---|---|---|---|
| 26 | **B-5**（kernel 關機路徑 abort） | **OPEN**，修法排在示範之後、已開單 | ① **在 Adam 這台重現**（目前只有 run-01 VM 的四份 log）；② **量到 exit code**——`134` 目前是推論，補驗那一輪沒記；auditor 今晚整機一輪每次 `ndt down` 抓 exit code ＋ log 末五行；③ **定位到物件**（joinable `std::thread` 被解構 vs 解構子拋例外，兩者都還沒被排除） |

⚠️ **G-6／G-7 的擴寫不是新狀態**，兩條本來就是「已知、未修」，第五波只是把
`ndt apps stop all` 與另外兩個同族站點補進去。

