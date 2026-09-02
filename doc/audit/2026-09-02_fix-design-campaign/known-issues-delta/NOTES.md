# `KNOWN-ISSUES.mechanism.diff` 的推導與但書

**產生時間**：2026-09-02。**基底**：`git show HEAD:doc/KNOWN-ISSUES.md`，取檔當下 HEAD ＝ **`fc9ef81a`**（1853 行）。
⚠️ **本輪工作期間 trunk 前進到 `c05e4988`**（別的 session 在推）。已重查：`doc/KNOWN-ISSUES.md` 的 blob **沒有變**，
本 diff 對新 HEAD 的 `patch --dry-run -p0` 一樣 **rc=0**，且本文引用的 `run_ab.sh`／`lib_e.sh` 行號在新 HEAD 上也仍然成立。
🔴 **但這是點取樣不是租約**：那個檔案有四個寫者，**套用之前務必重跑一次 dry-run**。

**🆕 第二批（同日稍晚）**：`A-2.md`／`A-4e.md`／`A-7.md` 三份晚到的 findings 已併入同一份 diff。
重跑時 HEAD 已是 **`06bc60ac`**；`doc/KNOWN-ISSUES.md` 的 blob **仍然沒有變**，dry-run 一樣 rc=0。
**輸入**：`fix-designs/` 的 18 份（16 個 `.md` ＋ F-1 的四份 `.txt` 附件）＋ `LEDGER.md`。
**授權邊界**：本輪對 repo **唯讀**，一個檔案都沒有動；輸出全部在本目錄。

## 0. 三個一句話的結果

| | |
|---|---|
| 既有條目／區塊被改動 | **16 處**（涵蓋 24 條具名缺陷：§A 八條——A-2／A-4c／A-4d／A-4e／A-4f／A-7／A-8／A-9；§B 四條；§C 表八列；§G-2 兩列；兩則儀器缺陷） |
| 新條目 | **6 條**（全部帶 `NEW-` 臨時編號，最終編號由 auditor 指派） |
| 被擋下、寫進 `STATUS-CHANGES-DEFERRED.md` 的狀態變更 | **25 項**（＋2 項請 Adam 明示的邊界情形） |
| `patch --dry-run -p0` | **rc=0**（另已實套一次並 `cmp` 確認結果與 `edited.md` 逐位元組相同） |
| diff 規模 | **21 個 hunk**、＋694／−17 行（1853 → **2530**）。17 個 `-` 全部是被我改寫的同一行，**沒有刪掉任何既有宣稱** |

🔴 **規模自陳**：加了 677 淨行到一份 1853 行的檔案（＋37%）。派工單列的 16 個必辦項目
（第 16 項自己就有 9 個子項）＋ 6 條新缺陷，平均每個事實約 5 行。
**如果 auditor 覺得太多，最先該砍的是 §C 那一節裡 F-6 的「三種數法」與 F-13 的六格矩陣**
——那兩段的資訊在 fix-design 檔裡有完整版，這裡只需要指過去。

## 1. Adam 裁決的執行方式

**裁決**：狀態變更（OPEN／RESOLVED／翻案／拆條）一律延到 C++ 分支編譯並過變異閘之後。

我照這樣切：

- **進 diff 的**：機制敘述被推翻或不完整的、漂掉的行號、漏掉的格子／路徑／站點、沒人記過的新缺陷。
- **不進 diff 的**：任何狀態行、任何 `🟢 RESOLVED`／`OPEN` 標記的變動、**以及會改變一格既有措辭
  所宣稱的事實的編輯**（見下一點）。
- **唯一的例外**：`NEW-NDT-SAMPLE-RATE` 標成「已修」。理由是派工單明列的：
  它是**不需編譯的 shell**，而且**紅→綠與變異閘 3/3 都是 auditor 自己跑的**（`f2836fc3`，已在基底裡）。

### 🔴 一個我沒有照字面做、但有意識地處理的地方

派工單第 8 項寫「F-8 的『暫態』措辭變更 → DEFERRED」。
我**沒有動 §C 表 F-8 那一格**（照裁決），但那樣會產生本文件自己記過兩次的失效：
**更正被歸檔到讀者不會經過的位置**——先被讀到的是表格，而更正在表格下面。

⇒ 折衷：**在表格正下方加了一行純指路的字**（不改任何一格的宣稱），
明寫「F-8 那格的『暫態』只對曾經有過流量的邊成立、格子本輪刻意沒改、必須往下讀」。
**如果 auditor 認為連這一行都算措辭變更，刪掉它就是**：它是 diff 裡最容易單獨移除的一段。

## 2. 逐項：改了什麼、用什麼可信度

> 標籤：**親自讀過**＝有人開檔讀了碼／**實測**＝跑過並有 rc／**讀碼推論**＝從碼推出來的後果。
> 「auditor 重跑」＝ `LEDGER.md` 裡記為「我重跑／我親讀」的那些。
> **我沒有把任何一級往上調。** 只跑過的東西才標「實測」，而本輪我自己跑的只有 `sed`／`grep`／`git show`／`diff`
> ——那些我一律寫成「本文覆核」並附在句尾。

| # | 條目 | 加了什麼 | 主要可信度 |
|---|---|---|---|
| 1 | **F-1**（§C 表）| 第四個捏造點 `:1810 getSingleSwitchCpuReport`（唯一呼叫者 `IntentTranslator.cpp:447`）；`-1` 早就是本檔慣例且契約／文件兩端都在消費；`% 50` 撞號 ≈60% | 親自讀過＋讀碼推論 |
| 2 | **NEW-DCAPM-TEMP-FRONT** | `:1594` 溫度迴圈在型別過濾前 `vp.ip.front()`；對照 `:918`／`:1519` 是先過濾再取 | 親自讀過（auditor 親讀；本文 `sed` 覆核） |
| 3 | **A-4d** | MODIFY 回退才是「覆寫」的真機制；default action ＝ `send_to_cpu` 不是 drop；「吵」只在資料面；行號又漂；install 走 5-tuple／delete 走 LPM 的相鄰缺陷 | 親自讀過（相鄰缺陷＝讀碼推論） |
| 4 | **NEW-BLOCK_HOST** | P4 模式下空 `actions`＋無 `ipv4_dst` ⇒ proxy `return False` ⇒ kernel 印成功回 200 | 讀碼推論（兩端 auditor 親讀，未執行） |
| 5 | **B-3** | `HistoricalDataManager.cpp:51` 的 `or` 左運算元 ⇒ 「running 但無執行緒」；`canRecord()` 是模式謂詞不是存活謂詞；`m_loggingEnabled` 預設 true；行號 `:1801-1810`→`:1905-1913` | 親自讀過 |
| 6 | **NEW-HTTP-200-DEFAULT** | `buildResponse()` 以 `status::ok` 建構 ⇒ 沒設狀態碼就是 200；F-13／B-3／B-4 共同根 | 親自讀過（auditor grep 確認） |
| 7 | **NEW-CHAOS-C07** | `_c07` 打的兩條路由不存在、`api_get` 丟棄狀態碼 ⇒ 控制組鑑別力為零；`05_first-live-run.md:203` 的「verified true」是假象 | 親自讀過（未跑 harness） |
| 8 | **F-13**（§C 表）| 6×2 十二格、**六格錯**（含 install-on-existing 兩格，方向更糟）；**六端點沒有任何 get**；Ryu `ofctl_v1_3.py:1151` 只 `send_msg`；四個引用三個行號漂了 | 讀碼推論＋親自讀過 |
| 9 | **F-6**（§C 表）| `continue` ＝「這輪不產生」不是「保留」；`:1022` 空陣列起頭、`:1893` 整份取代；`Classifier` 早就是逐 dpid upsert ⇒ 兩子系統同輪不同答；三種數法（4 skip path／9 地點／12 宣稱文字），其中兩個在測試檔說明裡 | 親自讀過 |
| 10 | **F-14／F-16／F-4**（§C 表）| 發現路徑五處 `= true`、零處 `false`；三條 down 路徑定義域都不含 host；F-4 根因＝只比 IP 不比 dpid＋`:724-729` 無 `continue`；**對帳式修法在 host 上永遠不觸發** | 親自讀過 |
| 11 | **B-x** | 92% 的出處鏈與**單一工作點**但書＋可轉移的公式；`:821` 加乘明確不再主張；🔴 **92% 幾乎全是 `idle` 不是 `ended`**（布林過濾會通過 review 卻幾乎不移除任何東西） | 實測（引用他人已跑）＋讀碼推論 |
| 12 | **F-8**（§C 表）| **推翻一半**：從未有流量的邊是永久錯不是暫態（`FLUC:1102-1107`）；宣告容量有讀（`TAFM:320`）只是寫錯欄位；16 條少報 9 G、**272 條「巧合正確」且無欄位可分辨** | 親自讀過（量化＝讀碼推論） |
| 13 | **F-15**（§C 表）| 本機 `ip_local_port_range` 32768–60999 ⇒ 10/10 在內；**第二份寫死的 50050 在 `proxy_agent/main.py:92`**；兩支 bring-up 偵測到失敗仍 `exit 0`；🔴 **被引用的守衛 `ASSERT FAIL: bmv2 did not all start` repo 裡不存在** | 實測（auditor＋本文重跑）＋親自讀過 |
| 14 | **A-8** | 三個工具點名到行；🔴 08-18 建議的 `admin_disabled` 修法是死的（那個欄位標的是 DisableSwitch）；本條不是「判準過期」是「判準少一個值」 | 親自讀過 |
| 15 | **A-9** | 鎖**有**到期（`:210`／`:304`），缺陷是到期是條件不是事件、`isLocked` 不清；**kernel 從不檢查 `routing_lock`** ⇒ 「任何要 routing_lock 的操作」改成「任何 acquire」；app 側八條出口不 release | 親自讀過 |
| 16 | **A-4c** | `set_forwarding_pipeline_config()` ＝ `VERIFY_AND_COMMIT`；bring-up 形狀 LPM 會回來 ⇒ **數規則條數會誤導**；`readopt` 也會清一台；kernel 無 intent store；`Classifier` 對缺席 switch 無限期保留 | 親自讀過 |
| 17 | **A-4f** | `del-br` 一次帶走三樣只存一樣；`powerOn:97-112` 兩樣都不重建；P4 `readopt` 已做等價事；`m_counterReports` 永不 erase ⇒ 0 與 idle 位元相同；`getAvgLinkUsage:2866` 跳過零邊；四支 round 腳本、`90_restore.sh` 最危險 | 親自讀過 |
| 18 | **B-2b／B-4** | 未認證 RCE 定名；一根三站點；🔴 `app_register` 的 URL 走**雙引號** ⇒ `$(...)` 不需要引號；`splitBodyAndStatus` 兩個成因一個判決；`:1363` 手串 JSON；`ApplicationManager` 跳錯層；11／14 兩個計數都對不回來（實際 `execCommand` 19 個） | 親自讀過 |
| 19 | **B-1** | 🔴 **OVS 上過濾器不生效**（Ryu 200 空 body ⇒ token 蓋章）；改的是視圖不是狀態（`modifyOne`／`deleteOne` 走原始陣列）；回傳的 withheld 計數被丟掉；8 顆 gtest 對接線是瞎的，**而該缺口已由 `b19045b0` 補上並經 auditor 重跑** | 讀碼推論＋實測（auditor 重跑） |
| 20 | **§G-2 row 02／05** | `cd440488` 是基底祖先 ⇒ 兩列的「已開工單」過期；`port_holder` 的真機制是 `ss` 省略 `users:` 欄位；🔴 真正未修的是「註冊窗與實跑窗從未被比較」（`:224` 只是 `info`）；🔴 **修法一行永久回歸測試都沒留** | 親自讀過＋實測（auditor 重跑） |
| 21 | **`measure.sh` 兩難 ＋ iperf3 兩則** | `:96`→`:99`；三份 copy 差三行不是一行且 09-02 那份指向 09-01 的 helper；`94e3c4b6` 讓名字豁免從 ladder 上的死碼變成活的（誤標成 `ours`）；`gates_e.sh:433` 豁免的是 shell 不是 iperf3；`:432` 的 `sleep 20` 是窗不是競態；🔴 **守衛自己的 `awk` 是 `pkill -f iperf3` 的靶 ⇒ `return 0` fail-open** | 親自讀過＋實測（本文重跑 `diff`） |
| 22 | **NEW-NDT-SAMPLE-RATE** | `sample_rate()` 只讀上界 ⇒ 取樣關掉照印 1/256；**已修 `f2836fc3`**，紅綠＋變異閘 3/3 | 實測（auditor 重跑） |
| 23 | **NEW-P4-RESTORE-COPIES** | 無共用 helper、12 份 `compile_at`；斷言查原始碼不查產物、`"op":"truncate"` 零鑑別力；`lib_e.sh:931` 的 `cp -f` 終局正確是 ETXTBSY unlink 的意外；run_e8 40 分鐘曝險窗**已查、1458 檔三種樣式 0 命中** | 親自讀過＋實測（auditor 重跑） |
| 24 | **A-2 item 2**（狀態行的「未覆蓋範圍」） | 🔴 整項重寫：`intelligent_router.py` 的兩個讀 `cce9c5db`（08-25）就都有界了、比本條被寫下來早六天；原引的 `:284-288`／`:304` 是 SIGUSR2 greenlet dump 的註解，差約 700 行；**而且那個函式從來不在 kernel 的 poll 路徑上**（poll 打的是 stock `ryu.app.rest_topology`，`stack.sh:719-720`）；真正的無界讀在 `ryu/app/rest_topology.py:97-119` → `app_manager.py:279`。結論方向（成因沒被移除）不變 | 實測（本文逐行 `git show 4cbec52d:` 覆核）＋親自讀過 |
| 25 | **A-2 機制節的「Ryu 那端」** | 同一個過期引用在同一條 entry 裡出現第二次；一併更正，並指出「三個 topology 端點全 000 而 `all_destination_paths` 0.2 ms 回答」有一個平凡解釋（**兩個不同的 app**），結論保留、理由換掉 | 親自讀過 |
| 26 | **A-2 item 3** | 敘述本身正確，補上讓結論翻面的那件事：三個寫入者**嚴格單調向上**（只寫 `true`、無任何 remove）⇒ 部分套用製造不出 down，只會沒抬起來 ⇒ 改成 all-or-nothing 是**往悲觀再推一步**；另補 `""` 與 `[]` 不可合併（OVS 開機時 LLDP 未完成就是回 `[]`） | 親自讀過 |
| 27 | **A-4e** | ①`:195-201` 已不是那段錯碼（現在是 `json body;` ＋修法註解開頭），出貨形狀在 `:222-228`／`:236-239`／`P4RoutingStrategy.hpp:60`；②🔴 **變異閘不在 `tests/shell/`**（六支 `mutate_*.sh` 對三個 A-4e 符號全 0 命中），在 `11b_mutation-harness` 的 M6–M9，**且 `mutations.py:13`／`run_one.sh:19` 寫死別人的 worktree、`driver.sh:5` 的 `S=` 指向已不存在的 scratchpad ⇒ 現況不可重跑**；③標題 🔴 與狀態 🟢 矛盾（只加註，不改標記） | 實測（`git show`＋`ls` 覆核） |
| 28 | **A-7 的 ⚠️ 08-30 註記** | 🔴 該註記在 `4cbec52d` 已不成立：`HttpSession.cpp:669` 就是它的呼叫端，隨 `636f9ab` 落地——**正是狀態行自己引的兩顆 commit 之一**。並補上殘留缺口：`running_`（`FlowDispatcher.hpp:132`）沒有 accessor ⇒ `dropped_after_stop` 的 `0` 對「活著沒丟過」與「已經停了」是同一個值 | 實測（`git grep`／`git log` 覆核）＋親自讀過 |
| 29 | **A-7 的兩個語意邊界** | 「兩個 dispatch API」→**四個 route**（`:186`／`:190`／`:194`／`:223`，`enqueue` 全 kernel 只有 `:1145`）；「開機編程隱形」是**結構性的**（兩種 fabric 都在別的行程）⇒ 不要加永遠讀 0 的桶；🔴 **FINDING-07 的「priority 落地恆 0」是對的觀測、錯的機制**——priority 每一跳都存活到 `p4_client.py:708`，只在 dst-only 路徑落進沒有 priority 欄的 `ipv4_lpm`（`ndtwin_switch.p4:350-352`）⇒ **不是丟失，是不可表示** | 親自讀過 |
| 30 | **NEW-BLOCK_HOST**（擴寫，非新條目） | A-7 撞到的 `IntentTranslator.cpp:733` **丟棄 `OpResult` 並無條件回 success**，與我第一批寫的 BLOCK_HOST 是**同一個呼叫站點**⇒ 併入而不是另開一條。對照組在同檔 `:364`／`:394`／`:417`（都包在 `flowReply(...)` 裡）。另註明這四個直呼同時是 A-7 的計數缺口 | 讀碼推論（行號本文覆核） |

## 3. 🔴 findings／LEDGER 之間、或它們與碼之間對不上的地方（全部以碼為準）

**規則**：LEDGER 與 findings 衝突時 LEDGER 勝；**兩者都與碼衝突時，碼勝，而且我把差異寫進 diff。**
下面每一條我都用 `sed -n`／`grep -n` 對 HEAD（`fc9ef81a`）親自覆核過。

1. 🔴 **`LockManager.hpp:203` 是錯的，正確是 `:210`。**
   A-9 的 fix-design **與 LEDGER 都寫 `:203`**（「鎖**有**到期（`LockManager.hpp:203`）」）。
   實際 `:203` 是 `std::lock_guard<std::mutex> lock(m_mutex);`；
   `if (state.isLocked && now < state.expiryTime)` 在 **`:210`**。
   renew 的第三個子句是 **`:304`** 不是 findings 寫的 `:305`。
   🔑 **而 KNOWN-ISSUES 的 §B-2 早就寫對了 `:210`** ⇒ 照 LEDGER 抄會把一個對的數字改成錯的。
   diff 裡用 `:210`／`:304`，並明寫兩份來源各差 7 行與 1 行。
2. 🔴 **「`isUp = true` 六處」對不上：發現路徑實際是五處。**
   F-14 的 fix-design 列了 `:637-638`／`:720-721`／`:760-761`／`:796-797`／`:932-933`
   ——**列了五個位置卻寫「六處」**，而 LEDGER 再壓縮成「`isUp` 賦 `true` 六處、`false` 零處」。
   `grep -n 'isUp *= *true'` 在該檔 10 個命中，扣掉 `:920`（**已被註解掉**）、
   `:1834`／`:1842`（`setEdgeUp`）、`:2341`（`setVertexUp`）、`:2118`（註解文字）之後
   剩 **`:639`／`:721`／`:761`／`:801`／`:936` 五處**（findings 的行號另外全部偏 2–5 行）。
   而「`false` 零處」**只對發現路徑成立**——全庫有五處（`:243`／`:318`／`:1817`／`:1825`／`:2334`）。
   ⇒ diff 裡寫「五處」並把兩個口徑分開講。**LEDGER 那句話單獨引用會過強。**
3. 🔴 **`HttpSession.cpp:589` ≠ `k = 50`。**
   這個引用在 KNOWN-ISSUES 裡出現兩次（B-x 本體與 `:821` 那一節），B-x 的 fix-design 照抄。
   `:589` 是那個 handler 的 log 行；`int k = 50;` 在 **`:594`**。diff 裡把它點出來。
4. 🔴 **`measure.sh` 的收尾 `pkill` 是 `:99` 不是 `:96`**（三份 copy 皆同）。
   這個是 IPERF3 的 fix-design 自己抓到的，我重跑確認。
5. ⚠️ **「三份 `measure.sh` 只差輸出目錄一行」不成立**：08-20 ↔ 09-01 差 `:25`／`:59`／`:86` **三行**，
   09-01 ↔ 09-02 才只差 `:25`；且 09-02 那份的 `:59`／`:86` 指向 **09-01 的** helper。
   （本文自己跑 `diff` 得到，findings 亦同結論。）
6. ⚠️ **`compile_at` 的「12 份」與「9 份」不是矛盾**：9 個同名函式 ＋ `lib_e.sh:800`
   ＋ `run_ab.sh` 的 `p4_compile()` ＋ `run_e8.sh:36-38` 的 inline ＝ 12。
   LEDGER 給 12、fix-design 給 9 再列出另外三個。diff 裡把拆法寫出來，免得下一個人以為兩份數字打架。
7. 🔴 **`run_ab.sh` 的行號在 `4cbec52d` 與基底 `fc9ef81a` 之間動過**：
   `restore_all()` `:54`→**`:65-111`**、`p4_compile()` `:118`（findings 寫 `:119`）→**`:143`**。
   `fc9ef81a` 就是動 trap 的那一顆。diff 裡用基底的行號並註明。
8. ⚠️ **LEDGER 的 B-1 有兩則，後一則取代前一則。**
   `## B-1-VERIFY` 那則寫「**它的變異宣稱我沒重現**」（把 `:1975` 註解掉，測試仍綠）；
   而檔尾的 `## 續做回報 13:2x–13:3x` 寫 `b19045b0` 之後 **M4 重跑 rc=1、16 顆 3 紅**。
   ⇒ **我用後一則**，並在 diff 裡明寫「前一則已被同簿後續取代，以此為準」。
9. ⚠️ **`check_logs.py:240`**：LEDGER 與 fix-design 都給 `:240`，實際 WARN 分支起於 `:241`
   （`:240` 是空行）。我保留 findings 的**區間** `:240-246`，因為區間是對的。
10. ⚠️ **`proxy_agent/main.py:189-201`**：那是註解＋迴圈的**區間**；
    `set_forwarding_pipeline_config()` 的呼叫在 **`:197`**，迴圈起於 `:193`。diff 用 `:197`／`:193-201`。
11. ⚠️ **A-9 標題「永遠不放」**：fix-design 說字面不成立、可觀測上成立。
    **我沒有改標題**（標題是這份文件的錨點與引用鍵），只在內文加了 polling livelock 的說明。
    改標題屬「拆條／改編號」那一族 ⇒ 進 DEFERRED 清單。
12. ℹ️ **`ndt sample_rate()` 的行號兩邊都不算錯**：`4cbec52d` 上函式頭在 `:444`、
    LEDGER／findings 引的 `:445` 是它裡面讀 `hi[1]` 那行。基底上該函式已改寫（`:452`），
    diff 因此以「修前＝`4cbec52d:444-445`／修後＝基底」兩邊分開寫。
13. ⚠️ **F-6 的「四處」有三種數法**（4 skip path／9 地點／12 宣稱文字），
    fix-design 的 commit message 用的是第二種。條目寫的「四處」＝skip path，**成立**。
    我把三種都寫進去，因為只寫一個數字下一個人一定會覺得對不上。
14. 🔴 **A-7 fix-design 的時間軸講反了，而正確的版本教訓不同。**
    它寫「the note was written 08-30, the wiring landed 08-31」。實際：
    接線 `636f9ab` 是 **2026-08-30 22:18**，而那段註記是 **2026-08-31 11:25** 才被
    `1c8828b6` 寫進本檔——**接線在前，註記在後 13 小時。**
    🔑 **但更重要的是我另外查到的一件事，兩份來源都沒說**：那段註記**明白宣告基準是 `1208d22`**
    （08-30 20:11），而**對著那個基準它完全正確**——我查過 `1208d22` 上
    `src/ndt_core/http/` 沒有任何 `droppedAfterStop` 命中、`/ndt/get_flow_dispatch_status` 也不存在。
    ⇒ 教訓不是「⚠️ 註記活過它的條目」，是「**宣告了基準的讀碼是誠實的，
    但 commit 進一份活文件前沒有重讀，它在落地那一刻就是假的**」。diff 用的是這個版本。
15. ⚠️ **`driver.sh` 的 `S=` 在 `:5`，不是協調訊息與 A-4e fix-design 寫的 `:6`**（`:6` 是空行）；
    而它是用 **`bash "$S/run_one.sh"`（`:10`）** 執行，不是 `source`。
    實務後果相同（committed 的 driver 今天跑不起來，那個 scratchpad 已不存在），但引用要用對的行與動詞。
16. ⚠️ **A-2 fix-design 的 `= false` 清單少列了三處**（`:2407`／`:2411`／`:2421`，adminDisable 那一支）。
    **不影響它的結論**——那三處同樣是明確 setter、poll 不走——但「全部 `= false` 都在這裡」這句話
    如果被下一個人拿去做窮舉，會漏掉它們。diff 裡列的是我 `grep` 出來的完整集合。

## 4. 我沒有覆核、只能轉述的（可信度上限）

這些**不在這台機器的 repo 裡**，或本輪禁跑，我一律照抄來源的可信度、沒有升級：

- **Ryu 原始碼**（`ofctl_v1_3.py:1151`、`ofctl_rest.py:276-277`、`ryu/topology/switches.py:190-200`）
  ——LEDGER 記為 auditor 從本機 Ryu 原始碼親自確認，**我沒有再開一次**。
- **Energy-Saving-App** 的八條不 release 的出口與 `easy_enable_switch()`——A-9 的 agent 讀的，**我沒開那個 repo**。
- **Web-GUI `DeviceInformation.tsx`** 的 `-1` 分支——F-1 的 fix-design 自陳「他 repo，本 worktree 讀不到」，
  只有 `DeviceConfigurationAndPowerManager.cpp:930` 上方的註解間接佐證。
  🔴 **Network-Traffic-Visualizer 完全沒有 `-1` 處理的證據，而且 repo 不在這台機器**——
  這件事我**沒有**寫進 diff（它是示範裁決不是缺陷機制），但 auditor 要記得它還開著。
- **所有 live 讀數**（08-18 的 F-2/N-9、08-27 的 92%、08-28 的 3040 次觀察、08-30 的 TR-5）
  ——一律標成「實測，引用他人已跑」。
- **`tests/python/test_cpu_gate_lifetime.py`**（隨 `94e3c4b6` 進基底）——IPERF3 的 agent 自陳沒讀、沒跑；
  我也沒有。**所以 diff 裡沒有任何一句宣稱 `cpu_gate.py` 的改動不會弄紅它。**

## 5. 沒有進 diff 的東西（刻意）

- **全部狀態變更** ⇒ `STATUS-CHANGES-DEFERRED.md`（25 項 ＋ 2 項邊界情形）。
- **§C 表 F-8 那一格的「暫態」字樣**（見 §1 的處理方式）。
- **`IPERF3-CONFLICT.patches/` 與 `RESTORE-SWEEP.patches/` 底下的 diff**——
  那些**從未被套用**，是提案。KNOWN-ISSUES 記缺陷不記未套用的提案。
- **`cpu_gate.py` 三個洞那一則**——`94e3c4b6` 已經把它改寫成「碼落地、變異閘過、live 待驗」，
  IPERF3 的 fix-design 明說本題專屬的內容該進 `:1634` 那一則、**`94e3c4b6` 沒有動它**。我照做。
- **`ndtwin_kernel` 重建配方那一則**——本輪 18 份 findings 沒有一份碰它。

## 6. 給 auditor 的三個「我最不確定」

1. **§C 表 F-8 那一格與我加的更正互相矛盾，而讀者先讀到表格。**
   我用一行指路字折衷（§1）。**如果那一行被判定為越權，刪掉它** ——
   但那樣就會留下一個**表格說暫態、下面說永久**的檔案，而且不會有人被指過去。這一題該由 Adam 拍。
2. **「五處 `isUp = true`」是我自己 `grep` 出來的，與 fix-design 和 LEDGER 都不同。**
   我相信 `grep` 的結果（`:920` 確實是註解掉的），但**如果 F-14 的 agent 是把某個
   `isEnabled = true` 或別的檔的賦值也算進去，那「六」可能有它自己的母體**。
   ⇒ 併分支前請那個 agent 說清楚它數的是什麼。
3. **`NEW-HTTP-200-DEFAULT` 該不該是一條「缺陷」。**
   `buildResponse()` 用 `status::ok` 當預設是常見且合理的設計；把它列成缺陷，可能會被讀成
   「要改預設值」，而那會一次動到四十幾條 route。
   我寫的是「**審查新 handler 時要問的是它有沒有設 `res.result()`**」，
   但**它到底該進 §C（靜默正確性）還是進 §G（陷阱），我判不出來**——目前放在 §B 的 B-3 前面。

### 第二批補充的兩個「不確定」

4. **A-4e 標題的 🔴 我沒有改。** 狀態行早就是 `🟢 RESOLVED`，標題與它矛盾；
   改它**不改變任何狀態**，只是讓 entry 不再自我矛盾。但它動的是一個狀態標記，
   而裁決的字面涵蓋「狀態標記」。**我選了保守：只加一行「以狀態行為準」的註。**
   ⇒ 這是三個邊界情形之一（見 `STATUS-CHANGES-DEFERRED.md` #25），請 Adam 一句話決定。
5. **`IntentTranslator.cpp:733` 我沒有另開新條目**，而是併進 `NEW-BLOCK_HOST`——
   交辦說「add as a NEW entry」，但我覆核後發現**那是同一個呼叫站點**
   （`:728`／`:733`／`:739` 在同一段 `try` 裡），另開會造成兩套編號指同一個地方。
   ⇒ 理由與拆條的條件寫在 `STATUS-CHANGES-DEFERRED.md` 的邊界情形 3。

### 第二批：我唯一沒能自己確認的引用

- **`ryu/app/ofctl_rest.py:686-689`／`:425-431`／`:147` 與 `lib/ofctl_v1_3.py:1049-1071`**
  （A-4e 用來把「`modify_strict` 路由存在」從 live 200 改成靜態結案的那組）。
  我**確認了結論的方向**——`modify_strict` 這條路徑在裝好的 ryu 4.34 裡確實存在，
  而且我在第一批已經逐行讀過同一個檔的 `ofctl_v1_3.py:1151`——
  但**這一組行號我沒有逐行 `sed` 覆核**。diff 裡那一句因此標成〔轉述 A-4e fix-design〕，
  沒有標成親自讀過。其餘第二批的每一個 file:line 都是我自己 `git show 4cbec52d:` ＋ `sed` 看過的。

---

# 第三波（Adam 19:0x 四項裁決）＋ 第四波（user-test §G）

**四份 diff，必須依序套用**，每一份的 `patch --dry-run -p0` 都對「前一份已套用」的檔案 rc=0：

| 檔 | 內容 | hunks | ±行 | 套用順序 |
|---|---|---|---|---|
| `KNOWN-ISSUES.mechanism.diff` | 機制／行號／漏掉的格子＋6 條新條目 | 21 | +694／−17 | 1（對 HEAD 的 `doc/KNOWN-ISSUES.md`）|
| `KNOWN-ISSUES.rulings.diff` | Adam 19:0x 的四項裁決＋`NEW-*` 正式編號 | 15 | +84／−60 | 2 |
| `KNOWN-ISSUES.status.diff` | **過閘分支的狀態翻面（條件式，逐 hunk 可丟）** | 23 | +119／−27 | 3（**等整合報告確認後才套**）|
| `KNOWN-ISSUES.usertest.diff` | user test run-01 的四條 §G 工具／安裝缺陷 | 2 | +84／−1 | 3 或 4（**與 status 互不相干，兩種順序都驗過 rc=0**）|

中間檔 `rulings.md`／`status.md`／`usertest.md` 留著，方便逐份 `cmp`。

## `NEW-*` → 正式編號對照（第三波定案）

| 臨時編號 | 正式編號 | 落在哪 | 為什麼是這個號 |
|---|---|---|---|
| `NEW-BLOCK_HOST` | **A-4g** | §A，**移到 A-4f 之後**（原本夾在 A-4d／A-4e 之間） | A-4b…A-4f 的字母順序＝文件順序，插在中間會破壞它。已在 A-4d 留一行指過去 |
| `NEW-HTTP-200-DEFAULT` | **C-2** | **從 §B 移進 §C**（Adam 裁：設計性質，不是示範看得到的缺陷） | 見下 🔴 |
| `NEW-DCAPM-TEMP-FRONT` | **C-3** | §C，原位 | 與 §C 表的 F-1 同檔同族 |
| `NEW-CHAOS-C07` | **G-3** | 文末儀器缺陷區，原位 | |
| `NEW-NDT-SAMPLE-RATE` | **G-4** | 文末儀器缺陷區，原位 | |
| `NEW-P4-RESTORE-COPIES` | **G-5** | 文末儀器缺陷區，原位 | |
| （第四波新增） | **G-6／G-7／G-8／G-9** | §G，接在 G-2 之後 | user test 的工具／安裝缺陷 |

🔴 **`C-1` 我刻意留空，這件事要 auditor 知道**：本檔 §B-1 已經引用了「08-13 fault catalogue 的 `C-1`」
（`grep -n 'C-1'` 在 base 只有那一個命中）。把新條目叫 `C-1` 會在同一份檔案裡造出**第三套撞號的編號**，
而 §C 開頭那則消歧註正是在講兩套 `F-n` 撞號的代價。⇒ 從 `C-2` 起編。**如果 auditor 認為這太保守，改回 C-1 只要動兩個字串。**

⚠️ **`G-3`／`G-4`／`G-5` 住在文末的儀器缺陷區，不在 §G 標題底下**（那一區本來就沒有編號）。
我用 `G-` 前綴是因為它們是同一族（操作／儀器陷阱）。**如果 auditor 要另立一個區段字母，這三個號改起來很便宜。**

## 第三波：我做了什麼、以及一個做不到的要求

- **四項裁決全部落在 `rulings.diff`**：F-4 翻案（§D 那格，原裁定與 08-30 的消歧註都存查，並寫下
  「若日後改回不修，三道守衛必須一起 revert」）；§G-2 row 02／05 標已修＋殘餘另列（`assert_window_span`）；
  A-9 改題並保留舊題在括號裡（**同時改掉了文內唯一一處引用舊標題的句子**——
  `grep '永遠不放'` 在改前有兩處，改後兩處都指向新框）；A-2 item 2 補上 vendoring 裁決。
- 🔴 **「每一列自己一個 hunk」有一段做不到，我用零上下文 hunk 繞過去了。**
  §C 表的 F-14／F-16／F-8／F-1／F-13／F-6 是**連續的行**，而 unified diff 無法把相鄰的變更切成不同 hunk
  ——中間沒有未變更的行可以當邊界。
  ⇒ 我把那一段改成**逐列的零上下文 hunk**（每列都是 1 行換 1 行、**行數中性**，所以行號不會漂），
  並在每個 `@@` 後面標上延後清單的列號。**實測過可丟**：拿掉 `#1 F-1` 那個 hunk 之後
  `patch --dry-run` 仍 rc=0，F-1 保持原樣而其餘六列照翻。
  其餘 17 個 hunk 是正常的 `-U2` 上下文（`-U3` 會把 A-4e 的註記與 A-4f 的佔位 hunk 併在一起，
  那會讓 **#6 A-4f 這個「要能丟」的佔位** 丟不掉，所以降到 `-U2`）。
- **A-4f 依交辦留成佔位、不翻**：它的閘門 **rc=2「baseline 紅」**（`e9993f9f`），
  而且它新加的兩個 shell 站點**被 B-2b 的守衛判紅**。兩件事都寫進那個 hunk 了。
- 🔴 **B-2b／B-4 翻成 RESOLVED，但我在同一個 hunk 裡寫下「它自己的守衛此刻在整合樹上是紅的」**
  ——那是 A-4f 的新站點造成的跨分支互動，守衛照設計推定有罪。
  **在守衛回綠之前不要對外宣稱引號家族已清乾淨。** 這一句是我加的，不在交辦清單裡；
  少了它，這一列會變成本文件反覆警告的那種「綠得比證據多」的狀態行。

## 第四波：user-test 的四條 §G

出處一律引 `doc/audit/2026-09-02_manual-usertest/run-01-sonnet/RECONCILIATION.md` **§6**
（**已 `grep -n '^## 6'` 確認存在**，trunk `5da71c74`，`git merge-base --is-ancestor` 過）。
四條的每一個 file:line 我都用 `git show HEAD:<file> | sed -n` 自己看過。

🔴 **三處交辦（或出處檔）的引用與碼對不上，diff 用的是我覆核的版本**：

1. **`ndtwin-lab` 的寫死路徑在 `:51`／`:53`／`:55`／`:56`，不是 `:26-31`。**
   `:26-35` 是那段「DELIBERATELY NOT OVERRIDABLE」的檔頭註解。出處檔 §6 寫的是 `:26-31`。
   （`ovs-topo-start:143-144` 則**逐字吻合**，`topo-start:99-100` 也是。）
2. **`cleanup` 的四個 `pkill -f` 在 `:131`／`:132`／`:133`／`:135`**（`:134` 夾著 `mn -c`），
   不是 `:132-136`。四個的數目正確。
3. 🔴 **「只有 `nsr` 走 `app_spawn`」不成立**：`app_spawn` 的呼叫點是
   **`nsr`（`:1932`）、`viz`（`:1938`）、`te`（`:1942`）三個**，
   **繞過它的只有 `energy` 與 `sim`**。diff 裡明寫了這個口徑更正。
   ＋ 一個附註：`app_spawn` 的存活檢查確實是 `kill -0`（`:1902`），
   而同一個檔案 `:1639-1677` 花了一整段論證 `kill -0` 對**停止**路徑是錯的工具（EPERM、pid 回收）
   並改用 `pid_is_app`——**啟動路徑這一顆還是 `kill -0`**。我把這個不對稱寫進去，但沒有把它講成缺陷。

✅ **我自己另外確認的兩件事**（不是轉述）：
`/usr/local/sbin/ndtwin-lab` 存在、root 擁有、**`cmp` 與 trunk HEAD 的 repo 副本 byte-identical**；
以及 `energy-start`（`:158-162`）／`sim-start`（`:173-`）確實是 `tmux new-session -d … ; echo`。

## 第四波我**不能**確認的

- **G-8 的文件那一半**：User Manual／Installation Manual 在 **website repo，不在這台機器**。
  ⇒ 那一條我**沒有寫任何手冊的行號或逐字內容**，只寫了「手冊只建 `ndt` 的 symlink、沒提 `ndtwin-lab`」
  這個由出處檔轉述的事實，並把文件那一半明確標成 website repo 的責任。
- **「user test 實地踩到」的行為本身**：我沒有跑 user test，也沒有跑 `ndt`／`ndtwin-lab` 任何一個動詞
  （本輪對 repo 唯讀、且不碰 lab）。G-6／G-7 的行為敘述是**出處檔的實測 ＋ 我的讀碼**，
  兩者在條目裡分開標了。

---

# 第五波 `KNOWN-ISSUES.usertest2.diff`（run-01 補驗 4(a)(b)(c)）

**3 個 hunk、+78／−2。** 出處＝`doc/audit/2026-09-02_manual-usertest/run-01-sonnet/auditor-verification/README.md`
（**已 `git ls-tree` 確認存在**；`01e642e8` 已 `git merge-base --is-ancestor` 過，auditor 的裁定在該檔 `:39`）。
基底＝`usertest.md`（機制＋裁決＋第四波），**與 `status.diff` 互不相干**：
五種順序都驗過 rc=0，包含 **status 整份丟掉**與 **status 擺最後**（實際情況：它要等整合報告），
以及丟掉 `#1 F-1` 那個 hunk 之後再套四份，仍 rc=0。

| hunk | 內容 |
|---|---|
| `@@ -1141` | **新條目 B-5**（kernel 關機路徑 abort） |
| `@@ -2131` | **G-6 擴寫**：`ndt apps stop all` 對沒起來的 app 也印 ok |
| `@@ -2163` | **G-7 擴寫**：`intelligent_router.py` 與 `bmv2_binary_override` 兩個同族站點 |

## 我自己覆核出來、與交辦敘述不同的四點（diff 用覆核版）

1. 🔴 **`134` 是推論，不是量到的。** 交辦寫「exits 134 instead of 0」。
   我把整個 `auditor-verification/` grep 過：**唯二的 `EXIT=` 都是 `127`**，而且是 tmux pane
   重現腳本的，**與 kernel 無關**；那一輪**沒有記下 kernel 的 exit code**。
   `abort ⇒ SIGABRT ⇒ 128+6=134` 的推理成立，但它是推理。
   ⇒ B-5 把它明確標成推論，並指出**今晚那一輪要補的就是這個數字**。
   （這正是本條目自己在講的病：**一個沒被量到的數字被當成觀測引用**。）
2. 🔴 **abort 不是緊接在 `All subsystems stopped. Exiting.` 之後。**
   交辦寫「after printing `All subsystems stopped. Exiting.`」——方向對，但**中間還有三行**：
   `Exiting.` 在 `main.cpp:430`，之後還印 `ControllerAndOtherEventHandler.cpp:102 already stopped`、
   `ApplicationManager.cpp:266 cleanupNFS`、`FlowLinkUsageCollector.cpp:580 Collector Stops`，
   **然後**才是 abort。⇒ **最後一行 log 是 `Collector Stops` 不是 `Exiting.`**，
   而這件事會影響下一個人往哪裡找。已寫進條目。
3. ✅ **交辦給的兩個行號一字不差，而且我另外找到第三、第四份**：
   `av2_kernel_1.log:208`（共 208 行）、`av2_kernel_2.log:45`（共 45 行）都正確；
   **另有 `av_kernel_1.log:209` 與 `av_kernel_2.log:45`**（第一次跑的那兩份）也同句
   ⇒ **四份 log 全中、一次不漏**，比「兩份」強。
   tester 的 `kernel_p4.log` 我**沒有開**（README 轉述），已標〔轉述〕。
4. 🔴 **`p4_testbed_topo.py:56` 不是拒絕的地方。** `:55-56` 只是
   `BINARY_OVERRIDE_PATH = os.path.join(...)` 的續行；**真正的拒絕在 `:180-203`**，
   四個 raise 各管一種情況（檔不在 `:184-189`／全被註解掉 `:193-197`／非絕對路徑 `:199-200`／
   不是可執行檔 `:202-203`）。已用覆核版。

## 兩件我覺得比交辦敘述更值得寫進去的

- **`ndt apps stop all` 那一列，同一份輸出裡就有對照組**：`nsr`／`viz`／`te` 印的是
  `not running`（誠實），`energy`／`sim` 印的是 `ok … stopped`（假的）。
  ⇒ 不是「訊息不好」，是**同一個指令的五個目標裡有兩個給了相反的答案**。
- **停止側的碼比啟動側更糟一級**：`ndt:1958-1959` 用的是 **`;` 不是 `&&`** ⇒ **rc 連看都沒看**
  （啟動側 `:1928-1929` 至少用了 `&&`）；而 `>/dev/null 2>&1` **丟掉的正是誠實的那句話**
  ——`ndtwin-lab:163-168` 在沒有 session 時印的是 `no energy session`。
  **下層說了實話，上層把它丟掉再蓋上一句假話。**

## 第五波的可信度邊界

- **B-5 全部的證據來自那台 VM**（`nslab:~/ndtwin-vm-usertest-01-sonnet/`），
  **沒有在 Adam 這台重現**——條目第一行就寫了，「每一次」的定義域是那台 VM 的四次關機。
- **機制未定位**：`joinable std::thread` 被解構 vs 解構子拋例外，**兩個都只是最常見的成因**，
  本條**沒有指認是哪一個、也沒有指認是哪個物件**；三行 log 只縮小了範圍。
- **我沒有跑任何東西**：本波一樣是 `git show`／`git ls-tree`／`grep`／`sed` 唯讀覆核，
  沒有開 VM、沒有跑 `ndt`、沒有碰 lab。

