# 今晨修法分支一覽（每支一頁）

2026-09-03 上午 10:00–11:00 那批。基準：`trunk` = `3b321bb7`。
[Co-developed with claude code -- Adam]

這是 `BRANCHES-FOR-REVIEW.md` 的**續篇，不是取代**。那份寫的是夜巡之前就存在的六支
（G-9／B-5／G-7／G-6／flow-rate／L-9），這份寫的是**今晨針對夜巡findings 派出的修法**。
兩批要分開裁：那六支動的是工具與關機語意，這批動的是**孿生體自己的行為**。

---

## 讀之前先知道的四件事

**1. 🔴 有一條分支被三個 agent 疊在一起了，這是我的疏失造成的。**
共用工作樹的 HEAD 被其中一支 agent 用 `git checkout -b` 移到 `fix/ports-that-block-restart`，
之後兩個 agent 的 commit 就落在那裡。現況：

```
fix/ports-that-block-restart == fix/p4-priority-not-silently-dropped == 9d64a36a
  9d64a36a  P4 plane: refuse a priority the table cannot honour     ← 第 4 支的
  62a3aea8  FIX-PORT-TABLE: record that stack.sh's changes are NOT in the commit
  a8b0e1e5  Ports that block a bring-up: one declarative table      ← 第 2 支的
  b93a7a3f  Night rounds: one review page per unmerged fix/* branch ← 文件，該進 trunk
```

**沒有東西遺失，但兩支分支現在是同一個指標。** 併 ports 會連 priority 一起帶進去，反之亦然。
拆法寫在最後一節，需要你點頭才動（要動到已 checkout 的分支）。

**2. 這批的閘門，有三支是我自己重跑過的，不是採信作者。**
（見 `AUDITOR-VERIFICATION.md`。）上一批六支我做不到這件事——那六支只有 B-5 把 raw log
commit 進 repo。**這一批的差別是閘門腳本本身可以在乾淨 worktree 裡重跑**，我就重跑了（四支落盤的全部重跑過）。
每一頁第 3 節標明「作者宣稱」還是「auditor 重跑」。

**3. 這批沒有一支起過 fabric。** 實驗室整晚在跑測試輪，修法全部在離線／單元層完成。
每一頁第 6 節都寫了「這支沒有被真實資料驗過什麼」。**這不是加分項的缺席，是合併條件的缺席。**

**4. 風險分級照你的裁決**：純正確性可直接進 trunk，改變對外行為的留分支。
每一頁第 2 節開頭用 🔴 標出**改變行為**的那一條；沒有 🔴 的表示我認為它是純正確性。

---
---

# 1／7 — `fix/deterministic-path-tiebreak`

1 commit（`966734be`）｜base `3b321bb7`（＝目前 trunk）｜動 `p4_proxy/proxy_agent/{ryu_topology,topology_manager}.py`

## 1. 一句話

等長最短路徑的選擇，從「`nx.shortest_path` 回哪條就哪條」（＝`nx.DiGraph` 的插入順序）
改成取 `(目的地, 本節點, 候選下一跳)` 的 BLAKE2b 摘要最小者——固定雜湊的目的地式 ECMP。

## 2. 🔴 行為變更前後對照

**🔴 這支修的是夜巡的第一號 finding：8 次相同指令、相同拓樸的 bring-up 產生 4 種不同的
全網路由表**，而 `/ndt/get_path_switch_count` 逐位元相同（所以沒有人看得出來）。

| 情境 | 修法前 | 修法後 |
|---|---|---|
| 同一份拓樸連起 8 次 | 4 種不同的全網路由表 | 同一張表 |
| 哪條等長路徑被選 | 十條 gRPC 執行緒的到達順序決定 | 拓樸的純函數 |
| 換一台機器／換 Python 版本 | 可能又不一樣 | 相同（`hashlib`，不是加鹽的 `hash()`） |

**兩個設計決定，作者有量測支撐、我認為都成立：**

- **鍵不含來源。** `ipv4_lpm` 每個 (switch, 目的 IP) 只有一條規則；把來源放進鍵，
  公布的路徑就會與交換機自己裝的規則不一致——**實測 22 個 hop 不符**。
- **用雜湊而不是「取最小 dpid」。** 後者一樣確定，但會讓 **s6/s8/s9 完全不承載**
  （24 條規則全壓在 s5/s7/s10）。確定性不該用拓樸的一半換。

**確定 vs 均衡的衝突只有一種**：靜態均衡不衝突（仍是拓樸的純函數）；**負載自適應**均衡
會把不可重現性原封不動放回去。作者取確定性，理由寫在 `FIX-PATH-DETERMINISM.md`。

## 3. 閘門證據

**auditor 重跑，不是作者宣稱**：`tests/shell/mutate_path_determinism.sh`
→ baseline 10 tests 綠，**5 mutations, 0 survived**，rc=0，事後 baseline byte-identical。
每個變異紅的是**腳本指名的那一支**測試（M1→`test_every_host_pair_is_insertion_order_independent`、
M3→`test_no_switch_on_a_shortest_path_is_left_dark`、M5→`test_same_answer_under_different_hash_seeds`…），
不是「有東西紅了」。

測試裡有**對照組**：同樣 120 種插入順序下，原始 BFS **必須**不穩定——否則儀器沒有鑑別力。
閘門斷言「確定」，不斷言「走 s7」（不把今天的答案釘死）。
作者記錄首輪有 2 支 survived（門檻太鬆），已修正並如實寫進文件。

## 4. 合併順序與衝突

- base 就是目前 trunk，**可直接 fast-forward**。
- 與這批其他分支**無檔案交集**；與上一批六支也沒有。
- 🟠 **這支的三個執行檔改動現在就躺在共用工作樹裡（未提交）**，內容與分支相同。
  也就是說**今晨之後在共用工作樹跑的任何 p4_proxy 測試，跑的都是改過的選路**。
  併入後這件事自動消失；不併的話要記得清掉。

## 5. 回退方式

單一 commit，`git revert` 即可。無資料格式改變，無安裝檔改變。

## 6. 未處理（作者原話）

> 沒有起 fabric，沒有 live 十次 bring-up 的確認——文件裡標為 NOT-DONE，沒有宣稱。

⇒ **閘門證明的是「選路是拓樸的純函數」，不是「真的 bring-up 現在一致了」。**
那個確認需要實驗室，是合併條件不是加分項。

> `get_path_switch_count` 這支分支完全沒碰。

爆炸半徑作者盤過（非測試碼 6 處、測試/contract 5 處含 `spec.py:916`、2 個 allowlist、
3 條 CHANGELOG），傾向「可選附加欄位＋同一 commit 釘住 spec」，但三個盲點未解，
**結論留給你裁**。

---
---

# 2／7 — `fix/ports-that-block-restart`

2 commits（`a8b0e1e5`、`62a3aea8`）｜🔴 分支上另有兩個別人的 commit（見前言第 1 點）
｜動 `tools/test_workflow/{ndt,ndtwin-lab,ovs_4host_topo.py}` ＋新增 `ports.sh`

## 1. 一句話

「哪些 port 會擋住下一次 bring-up」這件知識，從**四段註解**變成**一張被讀取的表**
（`tools/test_workflow/ports.sh`，`spec|proto|plane|owner|consequence`，9 列）。

## 2. 行為變更前後對照

夜巡有**五輪**撞到同一個形狀：殘留檢查只覆蓋好命名的三個 port（`8000/8080/8081`），
不覆蓋真正擋住下一次 bring-up 的那些。

| 情境 | 修法前 | 修法後 |
|---|---|---|
| 有東西佔著 `:30051`（bmv2 gRPC） | `ndt clean` 綠 | 紅，並印 `residue: python3 pid … holding :30051 (tcp)` ＋ owner ＋ 後果 |
| 有東西佔著 `:6343`（sFlow，**UDP**） | 綠——**而且就算當初列了它也看不到** | 紅 |
| `ndt up` 打在活著的 stack 上 | — | preflight **只警告不硬失敗**（`:8000`／`:6343` 由自己的 kernel 持有，硬失敗會廢掉 reuse 路徑） |

**第二個獨立成因，先前沒有人指出**：`port_open` 只講 TCP、`ss -ltnpH` 也只看 TCP
⇒ sFlow 的 UDP `:6343` **在舊探針下不可見**。所以 `proto` 是**欄位**，不是假設。

**exit code 未動**（`cmd_clean` 仍 0/1，沒有第三態）——這是與 G-6 三態分支唯一的接觸面。

## 3. 閘門證據

**auditor 重跑**：`tests/shell/mutate_ports_that_block_restart.sh`
→ baseline 18 checks 0 failed，**9 mutations, 0 survived**，事後 `ports.sh` 與 `ndt` byte-identical。

**這把閘門的鑑別力是刻意建立在原本三個 port 之外的**，腳本自己寫著：
「沒有一個變異能被佔住 `:8000/:8080/:8081` 抓到——這正是重點，先前那次鑑別力檢查
就是用 `:8081` 驗的，那是壞版本本來就覆蓋的三個之一，所以它**不可能失敗**。」
M4（忽略 proto、退回 TCP-only）**只有在 UDP port 上才觀察得到**；
M8 由「free port 必須安靜」的對照組抓到。每次注入**先斷言注入成功**再斷言工具反應。

🔴 **我在複驗時抓到一個瑕疵**：`mutate_ports_that_block_restart.sh` 與
`test_ports_that_block_restart.sh` **commit 成 `100644`（沒有執行位元）**，
照其他閘門的叫法直接執行會 `Permission denied`，只能用 `bash` 明喊。
姊妹分支的 `mutate_path_determinism.sh` 是 `100755`。合併前 `git update-index --chmod=+x`。

## 4. 合併順序與衝突

- 🔴 **這條分支現在也指著 priority 的 commit**（前言第 1 點）。
- 與 **G-7／G-9 同檔 `tools/test_workflow/ndtwin-lab`**（本支只改 6 行註解，`:141/152`）。
  任務單寫的 `:337/348` 不存在——`ndtwin-lab` 只有 226 行。
- 🟠 **`tools/test_workflow/stack.sh` 的三處修改沒有進 commit**：作者開工前該檔已有
  **別人未提交的 177 行**（supervise/report_exit）。列到檔案擋不住同檔別人的 hunk
  ⇒ 作者選擇留在工作樹。**那三處修改目前是未提交的觀測，不在任何分支上。**

## 5. 回退方式

兩個 commit 可分別 revert。`ports.sh` 是新檔，revert 即消失。已安裝的
`/usr/local/sbin/ndtwin-lab` 沒被動過。

## 6. 未處理（作者原話）

> `ndt status` 仍自帶 `:8000/:8081/:8080` 三個字面值（顯示非閘門，同一形狀）。
> `--deep` 殺傷範圍從 3 個 port 擴到 20 個（已加拒絕 self／`$PPID`／自己 pgid，**但未實機驗證**）。
> `ndt_port_open` 回傳 2（無 `ss` 的機器）被當 not-clean，本機有 `ss`，**該路徑未被實機走過**。

`:8001`（energy）沒有收進表——repo 內無宣告，只有一次觀測。**「只觀測過一次」不足以進表**是對的。

---
---

# 3／7 — `fix/topology-load-fails-before-listen`

1 commit（`896f6674`）｜base `128bfc6b`（**不是目前 trunk**）｜動 `src/main.cpp`、
`TopologyAndFlowMonitor.{hpp,cpp}`、`tools/make_topology.py`

## 1. 一句話

拓樸載入改成**同步、在任何 acceptor 存在之前**完成，失敗就指名是哪一筆壞掉並 `EXIT_FAILURE`；
產生器拒絕超過 252 台主機，而不是靜靜截斷。

## 2. 🔴 行為變更前後對照

| 情境 | 修法前 | 修法後 |
|---|---|---|
| 拓樸檔有壞 IP（`10.0.0.256`） | 執行緒裡 throw ⇒ `abort()`，port 已經開了 | 開 port 之前失敗，訊息指名 `node #256 "h256" ip=… Invalid IP address` |
| `make_topology.py --hosts 300` | **rc 0**，靜靜給你 252 台 | **rc 1**，訊息說明第四個 octet 停在 254 |
| 🔴 **拓樸檔不見／讀不到** | 空圖開機，kernel 照樣起來 | **拒絕啟動** |

**最後一列是唯一需要你裁的**：作者自己標成「不是純正確性」。空圖開機到底是不是一個
有人依賴的行為（例如某個 demo 或某支測試先起 kernel 再灌拓樸），我沒有查。

## 3. 閘門證據

- 作者宣稱：`RefusesToEmitInvalidAddresses` **先看過紅**（未修的產生器上 3/5 紅）。
  **5 mutations, 1 survived** — M4（刪掉節點位址迴圈）存活，因為測試的 fixture 同時
  也毒化了邊，邊的迴圈先殺掉它。**作者如實記錄，沒有粉飾**。
- **auditor 重跑**：`tests/python/test_make_topology.py` **29 tests OK**（當腳本跑、
  用 `unittest` 收集都一樣）；`--hosts 300` → rc=1 且訊息成立；對照組 `--hosts 8` → rc=0，
  仍然完整產出。**兩個方向都驗了。**

🔴 **C++ 那一半從未編譯、從未執行。** `build-topoload/` 不存在，冷編 `-j2` 塞不進時間窗
（剩 ~4 GB）。作者**沒有宣稱它會編過**。因此**排序的閘門（載入失敗時斷言沒有任何 port 被 bind，
加上好拓樸的對照組斷言確實 bind 了）沒有寫**——它需要 binary。

⇒ **這支的 C++ 半邊要當設計看，不是交付。**

## 4. 合併順序與衝突

- base 是 `128bfc6b`，比目前 trunk 舊 ⇒ 需要 rebase。
- 🔴 **與 D15 同檔同區**：D15 把 `run()` 裡同樣那三行搬走。作者刻意不碰 `start()`
  並讓 loader 冪等以求兩者可組合，但**預期 `run()` 有文字衝突**。**先併 D15，再 rebase 這支。**

## 5. 回退方式

單一 commit。但注意：revert 會同時退掉產生器的拒絕與 C++ 的排序，兩者在同一個 commit 裡。

## 6. 未處理

C++ 半邊未編未跑（上述）。`run()` 現在是 `try/catch` 包 `runLoop()`——那個執行緒原本
**一個 catch 都沒有**，這正是 throw 會變成 `abort()` 的原因。這個改動本身沒有測試。

---
---

# 4／7 — `fix/p4-priority-not-silently-dropped`

1 commit（`9d64a36a`）｜🔴 指標與 ports 分支相同（見前言第 1 點）｜動 `p4_proxy/proxy_agent/api_routes.py`

## 1. 一句話

帶著 `ipv4_lpm` 無法履行的 `priority` 的 **`delete_strict`／`modify`**，現在回
**501 ＋ `outcome: "unsupported_on_p4"`**，而不是回 success 之後刪掉一條呼叫者沒有指名的規則。
**`add` 維持既有的揭露，沒有改。**

## 2. 🔴 行為變更前後對照

**分界的理由（我認為這是這支最值得讀的一段）：`priority` 是兩個意思。**

- **安裝時它是「優先序」**：規則被寫進去、會轉發。T-15 Option 0／2026-08-30 §1.2 已裁
  這裡用揭露處理，作者**沒有推翻既有裁決**。
- **刪除／修改時它是「身分」**：它指認**哪一條** entry。而 `ipv4_lpm` 上**每個 priority
  都指到同一條** ⇒ 777／999 打中的是呼叫者從未指名的那條規則。
  **揭露修不了這個**——揭露是在規則已經消失之後才被讀到的。

**為什麼是 501 不是 400**：請求本身是合法的 OpenFlow。400 會把過錯歸給呼叫者，
而 `OpResult::notSent` 存在的目的正是要停止這種錯置。

**拒絕寫在 proxy（`api_routes.py`）不寫在 kernel**：只有 proxy 知道一個 match 會編到哪張表
（`needs_five_tuple`）；把它複製進 kernel 就是 A-7 註解警告的那種漂移。**沒有動 C++。**

## 3. 閘門證據

- **auditor 重跑**：`tests/shell/mutate_p4_priority_refusal.sh` **7 mutations, 0 survived**，rc=0，
  事後 `api_routes.py` byte-identical，每個變異紅的都是腳本指名的那支。
  **先看過紅**：6 支紅（3 FAIL、3 ERROR），**raw log 有 commit 進 repo**
  （`doc/audit/2026-09-03_night-rounds/priority-refusal/red-before-fix.log`）。
  ⇒ **這是今晨四支裡唯一把 red-before 原始輸出留在 repo 裡的**。
- 雙向：1–3 證明它會觸發，4–7 證明它**不會**對 kernel 那條無 priority 的 delete、
  `makeModifyJob` 的 priority 0、−1 sentinel、五元組 match 誤觸發。
- 這把閘門的設計是**刻意一半一半**的：1–3 證明它會觸發，**4–7 證明它不會誤觸發**。
  一個「什麼都拒絕」的實作可以滿足單向閘門，然後把 fabric 弄死——這把擋得住。

## 4. 合併順序與衝突

- 🔴 指標與 ports 分支相同，要先拆（見末節）。
- 動 `api_routes.py`，與 tie-break 動的 `topology_manager.py`／`ryu_topology.py` 不同檔。

## 5. 回退方式

單一 commit，純 Python，`git revert` 即可。

## 6. 未處理（作者原話）

> **安裝路徑要不要也拒絕？** 我留成揭露。**mutation 7 會在有人靜默放寬它時變紅。**

> **不是現在做的建議：Option B，延到 Phase 4** — 把「只指定目的地卻帶 priority」的規則
> 導進既有的三元 `flow_5tuple` 表，而不是給 `ipv4_lpm` 加 priority。
> 爆炸半徑全是 Python，但真正的代價是 `_installed_routes`／`render_destination_paths`
> 要長出「一個目的地可以有多條規則」的概念——**那是孿生體的資料模型改動，
> 在量測窗口裡太危險。**

> 未實機驗證（實驗室被別人持有）：501 穿過 kernel 到 `/ndt/` 呼叫端的路徑是**讀原始碼**得到的，不是量到的。

---
---

# 5／7 — `fix/d15-dataplane-kind-race`

1 commit（`75c2b526`）｜base `128bfc6b`（**不是目前 trunk**）｜動 `TopologyAndFlowMonitor.{hpp,cpp}`
＋新增 `tests/test_DataPlaneKindOrdering.cpp`

## 1. 一句話

`start()` 改成**在生出任何執行緒之前、在呼叫者的執行緒上**完成靜態拓樸載入；
而 `refreshDataPlaneKind()` **拒絕**從還沒載入的拓樸推導結論——「還不知道」不再等於「不是 bmv2」。

## 2. 🔴 行為變更前後對照

這支修的是夜巡第 3 號 finding：`refreshDataPlaneKind()` 比拓樸載入早約 1 ms、而且**只算一次**
⇒ bmv2 的 liveness 路徑**從不執行**，出貨拓樸檔上 **0/44 勝**。

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `start()` 回傳時 | 拓樸可能還沒載入（載入在生出來的那條執行緒上） | 一定載入完（`isStaticTopologyLoaded()` 為真） |
| 太早取得的判定 | **被 latch 住**，整個 process 生命期都錯 | 不記為 determined；`dataPlaneIsBmv2()` 在使用點重新推導 |
| 7.8 KB 以上的拓樸檔 | bmv2 liveness 0/44 | 作者**預測**修好（未量測） |

**這不是「把載入變快」**——作者明確寫了那是排序修法。這點與夜巡的量測一致：
60 次冷啟動**稍後**都印 `All-bmv2 topology`，輸的是時序不是拓樸。

## 3. 🔴 閘門證據 — 沒有

**`0 mutations, gate SURVIVOR — NOT DELIVERED`，作者自己這樣寫。**
`tests/test_DataPlaneKindOrdering.cpp` 四支測試寫好了，**從未編譯、從未執行**：
冷編 `-j2` 超過十分鐘，撞到時間上限。**因此這段 C++ 從來沒有被編譯器看過。**

閘門的設計本身是好的（斷言**排序**不斷言結果，fixture 刻意用 **310 B 級**的單交換機拓樸
——那正是壞版本會**贏**的尺寸，所以不能靠運氣過），五個變異各自指名該紅的測試，
其中第 5 個是**預期存活並且應該被記成存活**的對照。**但這些全部沒有跑過。**

**auditor 已把冷編排進獨立 systemd unit**（`-j2`、`MemoryMax=5G`、獨立 build 目錄、乾淨 worktree），
結果補在 `AUDITOR-VERIFICATION.md`。**在那之前，這支分支不該被合併。**

## 4. 合併順序與衝突

- base 比 trunk 舊，需要 rebase。
- 🔴 **與 `fix/topology-load-fails-before-listen` 同檔同區**（兩支都搬 `run()` 開頭那三行）。
  **先併 D15，再 rebase topoload。**
- D15 動 `start()`，topoload 動 `loadStaticTopology()` 並刻意保持冪等以求可組合。

## 5. 回退方式

單一 commit。無資料格式改變。

## 6. 未處理（作者原話）

> **四列回歸表全部 UNRUN**（fabric 從未起，`ndt up` 從未執行）。文件裡的是**預測**，不是觀測：
> (1) *形狀改變* — `isUp` 仍然承載兩個意思；(2) *存活* — early return 沒動，只是 staleness 收窄；
> (3) **沒有處理** — `TopologyAndFlowMonitor.cpp:768-772` 無條件寫 `isUp=true` 是**第二個獨立缺陷**，
> 我沒有碰，也不宣稱；(4) *預測消失* — 這支針對的那一列。

> **先跑第 4 列** — `grep -c 'GET /p4/switch_state'` 必須是每秒約 1 次，否則其他列都不可解讀。

---
---

# 6／7 — `fix/telemetry-health-visible`

1 commit（`c7f78c58`）｜base `2168dcb9`（＝目前 trunk）｜動 `FlowLinkUsageCollector.{hpp,cpp}`、
`HttpSession.{hpp,cpp}`、`tests/CMakeLists.txt`＋新增 `tests/test_TelemetryHealth.cpp`

## 1. 一句話

🔴 **這支不是 agent 交付的，是我從一個死掉的 agent 手上撿回來的。**
「Surface telemetry health」在 10:23 被 stall watchdog 收掉，**沒有 commit、沒有分支**，
東西全部躺在共用工作樹裡。這個 commit 只做一件事：把它搬到不會被別人的
`git commit -- <目錄>` 掃走的地方。**我沒有寫它、沒有編它、沒有跑它的閘門。**

修法本身（作者自述）：把一個 `telemetry_health` 物件在**一個地方**建構
（`FlowLinkUsageCollector::ingestHealthJson()`），掛在
`get_detected_flow_data` 的每一列、`get_average_link_usage`、以及新的 `get_sflow_stats` 上。

## 2. 🔴 行為變更前後對照

這支對的是夜巡第 2 件的**「看不見」那一半**：四個 sFlow 丟棄計數器**在 kernel 供應的
105 個 JSON key 裡一個都到不了**，唯一的讀者是一行 log。

| 情境 | 修法前 | 修法後（作者宣稱） |
|---|---|---|
| 654,709 datagram/s 下 socket 丟 72.5% | 每個 endpoint 200 `success`，`avg_link_usage` 反向上升 | 同一個回應裡帶 `status: severe_loss` 與 `loss_fraction` |
| 問「這次量測可不可用」 | 沒有任何欄位回答 | `offered_in_window` ＝ samples ＋ socket drops ＋ app drops，**與速率同窗口**，比例可自行重算 |
| `GET /ndt/get_sflow_stats` | 404 | 200，回同一個物件 |

**設計上我認為對的一點**：欄位放在資料旁邊，而不是只開一個端點——
「計數器早就存在而且早就是對的，失敗的是**讀它是一個可以不做的獨立動作**」。

**代價作者也寫明了**：每一列 flow 大約多 200 bytes，而且**每列重複**
（因為 `get_detected_flow_data` 回的是裸陣列，沒有信封可以放單一份）。三個回應形狀改變。

## 3. 🔴 閘門證據 — 沒有

`tests/test_TelemetryHealth.cpp` 存在，**從未編譯、從未執行，沒有任何記錄結果**。
**auditor 已把冷編排進佇列**（獨立 systemd unit，排在 D15 那次後面），結果補在 `AUDITOR-VERIFICATION.md`。

## 4. 合併順序與衝突

- base 是目前 trunk，可 fast-forward。
- 🔴 **我刻意漏掉了一段。** 共用工作樹的 `HttpSession.cpp` 裡有**第三個 hunk 不屬於這支**
  （`handleGetGraphData` 裡的 `result["topology_round"] = pollRoundJson()`），
  那是**當時還在跑的另一支 agent 的在途編輯**。整檔提交會把活人的修改帶進一個沒有描述它的 commit
  ⇒ 這條分支帶的是**三段取二**的過濾 patch。
- 同理 `tests/CMakeLists.txt` 當時疊了三個 agent 的條目，這裡**只有 telemetry 那一條**。

## 5. 回退方式

單一 commit。但它改三個回應形狀 ⇒ 退掉之後任何已經開始讀 `telemetry_health` 的消費者會看不到欄位。

## 6. 未處理

**全部。** 這支從來沒有被編譯器看過。接手的人第一件事是編它。
作者的完整自述在 `doc/audit/2026-09-03_night-rounds/FIX-TELEMETRY-HEALTH.md`，
**每一條宣稱都未經查證**。

---
---

