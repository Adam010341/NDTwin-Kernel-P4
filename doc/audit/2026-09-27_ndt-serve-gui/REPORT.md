# ndt serve GUI 第一刀 — 報告

[Co-developed with claude code -- Adam]

- 分支：`feat/ndt-serve-gui-0927`，從 trunk＝main `b005bf50` 開；worktree 在 `scratch/overnight-2026-09-05/wt-ndt-serve-gui-0927`。**沒有併進 trunk，也沒有推任何遠端。**
- 依據：
  - Adam 09-27 13:2x 的 Q2（頁面由 ndt serve 自己在 `/` 提供）和 Q3（token 用一次性 URL `#fragment` 交給頁面，只放記憶體）；
  - 範圍草案 `SCOPE.md`（`bfffefa0`），以及 9/25 orchestrator 的核准與修改（`logs/orchestrator-0924/intake-0926/RULINGS-0927-ndtserve-gui-scope.md`）。
- **本報告對應的程式碼 head：`cb1b42d7`**（報告本身是其後的一個 commit）。raw 在 `scratch/overnight-2026-09-05/logs/ndt-serve-gui-0927/`，下文簡稱 `LOGS/`；scratch 被 `.gitignore` 擋著，不在分支上。
- 這一刀**沒有用到 lab**：伺服器端全部對 stub ndt 測，瀏覽器實測也是對 stub 伺服器。真的 ndt 只被 RcProvenance 讀過（不執行）；`ndt help` 和 `ndt serve url` 有被執行過。

---

## 1. 要你裁的

1. **併不併。** 我建議：判官審完、沒有必修，就可以併。改動範圍：
   - `tools/ndt_serve/serve.py` +約 330 行；`verbs.py` 3 行（`DEFAULT_CLAIM_MINUTES` 常數）；
   - 新的靜態頁 `tools/ndt_serve/static/`（HTML 124、JS 約 615、CSS 50 行）；
   - `ndt` 本體只改 help，加 3 行；
   - 其餘是測試、閘門和文件。
2. **job log 的輪詢**（orchestrator 15:4x 暫定裁定：可以，但有條件，驗收判官可推翻）。
   - 現況：D 區打開一個正在跑的 job 時，頁面每 2 秒讀一次它的 log。只讀檔案，不跑 ndt，不碰 lab。
   - 裁定的條件是「job 結束、job 畫面關掉、頁面被隱藏時都要停」。**交件時（`cb1b42d7`）的現況，逐條對照**（讀碼，`app.js` 的 `openJob`）：

     | 條件 | 現況 |
     |---|---|
     | job 結束時停 | ✅ 成立：state 不是 `running` 就 return |
     | job 畫面關掉時停 | ⚠️ 部分成立：打開另一個 job 時舊的迴圈會停（`watching` 換掉）；但**畫面沒有「關閉」按鈕**，所以沒辦法單純關掉 |
     | 頁面被隱藏時停 | ❌ 不成立：沒有檢查 `document.visibilityState`。分頁在背景時照樣輪詢（Chrome 只會替背景分頁的計時器降頻，不會停） |

   - **orchestrator 要求收件前補上，已補在 `cf053502`**：
     - job 畫面加了 Close 按鈕，`closeJob()` 會把 `watching` 設成 null，並把畫面藏起來；
     - 每次 sleep 之後都會 `await whileHidden()`：頁面在前景就馬上往下走，被隱藏時要等 `visibilitychange` 變回可見才繼續；等完之後會再確認自己是不是還在被看的那一個。
     - 順手修掉一個 Close 讓它變容易踩到的邊角：原本 `watching` 存的是 job id。關掉畫面後 2 秒內又打開同一個 job，舊迴圈醒來會以為自己還在被看，和新迴圈一起跑，log 就重複附加兩次。現在 `watching` 存的是「這一次打開」，關閉或重開都會換掉它。
   - 紅燈先行：兩條新的 PageLint 對 `cb1b42d7` 的頁面是紅的（`LOGS/close-hidden-cf053502/red-first-on-cb1b42d7.log`）。另外加了 6 個 G 變異：G37、G37b、G37c 對應 Close，G38、G38b 對應隱藏時停止，G39 對應以 job id 為鍵。閘門總數變成 144。
   - 三條件的現況（`cf053502`）：job 結束時停 ✅、畫面關閉時停 ✅、頁面隱藏時停 ✅。**這是讀碼加 PageLint 的結論，沒有在瀏覽器裡實際點過 Close，也沒有實際切到背景看過。**
3. **確認強度的表放在伺服器，不放頁面**（偏離 SCOPE §2 的寫法，§2 第 1 點）。**orchestrator 15:4x 已追認**，理由是該拒絕的本來就是伺服器；列為經追認的 SCOPE 偏離。
4. **P4 的 `--app` 套件目錄**，這一刀的頁面沒有提供輸入欄位。API 本來就支援（`{"plane":"p4","app":"<dir>"}`）。要不要在頁面上開放，排下一刀。
5. **下一刀：用 DevTools protocol 把點擊行為自動化**（裁定 5）。這一刀的點擊行為是在瀏覽器裡實際操作驗證的（§4.3），還不能重跑。

## 2. 推翻／更正

1. **偏離 SCOPE（orchestrator 15:4x 已追認）：確認強度由伺服器給。**
   - SCOPE §2 的強度表（一般確認或打字確認、要不要先 claim）原本要寫在頁面裡。實作時我把它放進 `serve.confirm_policy()`，由 `dry_run` 的回答帶出 `confirm`（`typed`／`plain`）和 `needs_own_claim`。
   - 頁面只加一條規則：measuring 不是 `nothing`、或有 `declared` 列時，一律升級成打字確認。
   - 理由：
     - 這樣頁面裡沒有任何表；
     - 強度可以用 Python 測（G27、G27b），不必靠瀏覽器；
     - 跟「argv 只在 verbs.py 組」同一個道理。
2. **偏離 SCOPE：`/lab` 多回了東西。**
   - 多了 `declared` 列（claim 宣告的 `measuring=`，ndt:6760）。這一列在的時候，dialog 也升級成打字確認。
   - 多了整份 plain status 的讀取結果，所以 A 區直接用 `/lab`，不再另外打 `/status`。重新整理一次只跑一次 `ndt status`。
3. **SCOPE 沒寫、我加的：`serve.json` 與「port 的主人」檢查。**
   - 問題：`ndt serve url` 要知道 port，所以伺服器啟動時在 token 旁邊寫一份 0600 的 `serve.json`（port、pid、owner）。可是伺服器死了之後，這個檔還在。
   - 風險：之後別的程序（包括別的使用者）綁上同一個 port，`url` 就會把 token 送給它。
   - 做法：`url` 先從 `/proc` 確認 serve.json 記的那個 pid 真的持有那個 port 的 LISTEN socket（`/proc/net/tcp` 的 inode 在它的 fd 裡），確認了才送 token。
   - 驗證：測試 `test_url_sends_the_token_only_to_the_pid_that_holds_the_port` 加上變異 G18。
4. **SCOPE 沒寫、我加的：所有回應都帶 CSP、X-Frame-Options、Referrer-Policy。** SCOPE 只要求靜態檔帶；我改成加在 `_send`，連 API 的 JSON 回應也帶。
5. **dry_run 預設拒收。**
   - 只有會 spawn job 的寫入接受 `dry_run`：up、down、claim、release、apps、cells run、walk next。
   - 其他 POST（walk 建立、verdict、abort、session/new）一律把它當成未知欄位回 400。
   - 原因：這些端點本身就只寫檔、不 spawn。若照單全收，`{"verdict":"green","dry_run":true}` 會**真的**記下判定。變異 G21 就是這個情境。
6. **dry_run 停在確認之前。**
   - 會寫共用狀態的格子（H4），預覽時不需要先帶 `confirm_shared_state_write`，因為 dialog 就是讓你勾確認的地方。
   - 真的跑的時候，沒帶這個欄位照樣回 400。變異 G22b 就是把順序換回來。
7. **自己的失誤：preview 工具啟動了你的網站伺服器。**
   - 經過：14:1x 我在 worktree 裡寫了 `.claude/launch.json`，接著呼叫 `preview_start`。但這個工具讀的是**主 checkout** 的 `.claude/launch.json`，所以啟動的是你的 `ndtwin-website`（hugo，port 1313）。
   - 處置：幾秒內我就用 `preview_stop` 停掉了，事後 1313 上沒有 listener。
   - 之後我想把 stub 的設定加進你那份 `launch.json`，被權限分類器擋下（理由是持久化設定）。我沒有再試。你那份檔案內容沒變（我讀過確認）。
   - 最後的做法：stub 伺服器照測試的方式用 `setsid` 起，瀏覽器面板只開它的 URL；結束後按 pid 停掉，停之前比對過 cmdline。
   - orchestrator 15:4x：已記錄，不需要處理（你那份 launch.json 沒變）。
8. **L1 lane 的直譯器是 Python 3.8.20（ryu-env），不是我平常測試用的那個。** 新 suite 在 3.8 下也是 35/35 綠（§4.1）。
9. **頁面測試由 opus worker 寫**（`d6f4b5a9`，我在 commit 前讀過全文）。它自己揭露了一件事：14:12:07 在 guard **外**跑過一次 `/opt/google/chrome/chrome --version`，目的是把版本號（153.0.8010.36）記進 log 標頭。這個指令會馬上回傳、不會開瀏覽器，但當下沒有查程序清單。除此之外，所有啟動 Chrome 的動作都在 guard 內。

## 3. 交付

| 項目 | 位置 |
|---|---|
| 伺服器 | `tools/ndt_serve/serve.py` |
| 靜態頁 | `tools/ndt_serve/static/{index.html,app.js,app.css}` |
| `ndt help` 的 `serve url` | `tools/test_workflow/ndt` |
| 伺服器端與頁面靜態檢查 | `tests/python/test_ndt_serve_gui.py`（37 例；交件時是 35 例，`cf053502` 加了 2 例） |
| 頁面（headless Chrome） | `tests/browser/test_ndt_serve_page.py`（5 例） |
| 閘門 | `tests/shell/mutate_ndt_serve.sh`（G 系列 53 條，總數 144；交件時 47／138，`cf053502` 加了 G37–G39 共 6 條）；`tests/shell/mutate_ndt_serve_page.sh`（5 條：G12–G14，加上兩個拒絕案例的紅燈先行 P1、P2 條） |
| 文件 | `tools/ndt_serve/README.md` 的「The page」一節和 API 表 |

**新的端點**：
- `GET /api/v1/lab`、`GET /api/v1/meta`；
- `POST /api/v1/session`（不需要 token，Origin 必須是這個 origin）；
- `POST /api/v1/session/new`；
- 寫入端點的 `{"dry_run": true}`；
- `serve.py url`（`ndt serve url`）。

**頁面做的事**（全部是英文標籤，裁定 2）：
- 載入時：清掉 fragment，用 nonce 換 token，接著讀 `/meta`、`/lab`、`/health`、`/jobs`。**載入時不寫入任何東西。**
- 每一次寫入都經過同一個 dialog：
  - 重讀 `/lab`；
  - 顯示伺服器 dry_run 回來的 argv、claim 列、measuring 列（`nothing` 也顯示）、槽位；
  - 預設焦點在 Cancel；按 Enter 不會確認；Confirm 按一次就停用；
  - 需要自己的 claim 時，claim 不是你的 → Confirm 停用，並顯示「claim first」；
  - up、down、需要 lab 的 cell → 打字確認；measuring 不是 `nothing` → 一律打字確認；
  - 寫共用狀態的 cell → 要勾確認框。

## 4. 細節

### 4.1 測試與閘門（跑過）

| 項目 | binary／tree | 結果 | log |
|---|---|---|---|
| `test_ndt_serve.py` | cb1b42d7 | 74/74 OK（56 s） | `LOGS/final-cb1b42d7/` |
| `test_ndt_serve_cells.py` | cb1b42d7 | 35/35 OK（32 s） | 同上 |
| `test_ndt_serve_gui.py` | cb1b42d7 | 35/35 OK（17 s）；Python 3.8.20（lane 的直譯器）下同樣 35/35 | 同上 |
| `tests/browser/test_ndt_serve_page.py`（guard 內） | cb1b42d7 | 5/5 OK（8.5 s）。這是頁面閘門的 baseline；它測的 16 個檔 sha256 和 `cb1b42d7` 的 blob 逐一相同。另外 worker 在 `e4f7c036` 加上舊版 app.js 時也單獨跑過一次，同樣 5/5。**排 guard 鎖等了約 45 分鐘**，因為別的 session 的閘門佔著鎖 | 同上 |
| 同上（guard 外） | cb1b42d7 | 5/5 SKIP，寫出 guard 的原因；rc 0 | 同上 |
| `mutate_ndt_serve.sh` | cb1b42d7 | 138 條變異，0 條倖存（314 s）；受測檔在跑的過程中沒有變動 | 同上 |
| `mutate_ndt_serve_page.sh`（guard 內） | cb1b42d7 | 5 條變異，0 條倖存。每一條都是指名的那一例、因為指名的原因變紅，Chrome 當掉不算數；受測檔沒有變動。事後掃 `/proc`，殘留程序 0、殘留暫存目錄 0 | 同上 |
| `check_gate_anchors.py b005bf50 cb1b42d7` | — | HEAD 122/122；兩個 rev 243/244（頁面閘門在 trunk 上 absent） | 同上 |
| `check_process_by_name.py`、`check_test_tmpdirs.py`（整棵樹） | cb1b42d7 | process_by_name：338 個檔、0 處；tmpdirs：371 個檔、0 處（trunk 同樣是 0 和 0） | 同上 |

**收件前追加的修正 `cf053502`**（orchestrator 15:4x 要求：只重跑受影響的閘門，再加 check_gate_anchors）：

| 項目 | 結果 | log |
|---|---|---|
| 兩條新 PageLint 對 `cb1b42d7` 的頁面 | **紅**（2 failures），紅燈先行 | `LOGS/close-hidden-cf053502/red-first-on-cb1b42d7.log` |
| `mutate_ndt_serve.sh` | 144 條變異，0 條倖存（310 s）；baseline 三套測試都綠；11 個受測檔的 sha256 和 `cf053502` 的 blob 逐一相同 | `LOGS/close-hidden-cf053502/gate.log` |
| `mutate_ndt_serve_page.sh`（guard 內） | 5 條變異，0 條倖存；baseline 5/5；16 個受測檔的 sha256 和 `cf053502` 逐一相同 | `LOGS/close-hidden-cf053502/page-gate.log` |
| `test_ndt_serve_gui.py`，Python 3.8.20 | 37/37 OK | `LOGS/close-hidden-cf053502/test_ndt_serve_gui.py38.log` |
| `check_gate_anchors.py HEAD` | 122/122 | `LOGS/close-hidden-anchors.log` |

L1 lane 的 step 3b 沒有重跑。`cf053502` 在 lane 範圍裡只動到 `test_ndt_serve_gui.py`，而且它在 lane 的直譯器下是 37/37。

- 紅燈先行：
  - 每個 G 變異都讓它指名的那一例變紅（閘門 log 裡逐行列出）；
  - `test_ndt_help_lists_serve_url` 在 help 還沒寫之前是紅的；
  - `test_root_is_reserved_for_the_gui` 在頁面上線後如預期變紅，改成 `test_outside_the_api_there_is_only_the_page`，M39 跟著改名。

### 4.2 L1 lane：CI 的問題群數不會增加

- **做法**：CI 的 L1 lane（`tools/test_workflow/l1_unit_tests.sh`）要先有編好的 C++ 測試 binary 才會往下跑。在這台筆電上編 kernel 有被 oomd 殺的風險，而且這一刀根本沒碰 C++，所以我**只跑 lane 的 step 3b**（kernel-side Python 和 shell 測試）。
  - 程式碼是在執行當下從**各自那棵樹**的 `l1_unit_tests.sh` 原文擷取出來的，用它自己的 `shell_summary`、`l1_lane_verdict` 評分；
  - 兩棵樹擷取到的 step 3b 原文 sha256 相同（`c931643995be92dd`）；
  - 驅動腳本是 `LOGS/final-cb1b42d7/l1_kernel_section.sh`（整輪收尾則是 `final_runs.sh`）；擷取出來的原文存在各自 log 目錄的 `step3b.extracted.sh`。
- **比較**：同一台機器、同一個直譯器（lane 挑的 ryu-env Python 3.8.20），兩棵乾淨的 detached worktree：

  | tree | problem groups | 耗時 | log |
  |---|---|---|---|
  | trunk `b005bf50` | 12 | 655 s | `LOGS/l1-step3b-trunk-b005bf50/lane.out` |
  | 分支 `cb1b42d7` | **12** | 680 s | `LOGS/final-cb1b42d7/l1-step3b/lane.out` |

- **逐檔判定**：兩邊的 diff 只有一行，就是分支多了 `test_ndt_serve_gui.py PASS 35 ran and passed`。其餘 102 個檔的判定完全相同。
  - 這 12 個本機的問題群（5 個 chaos、check_gate_anchors 的 2 個 skip、grpc_port_block、l3_dispatch_drift、ovs4_sflow、sflow_stats_endpoint、live_p1_common、mutate_gate_dead_mutant）都是 trunk 原本就有的。
  - 它們跟 CI 的 12 組不是同一批，因為本機環境不同，數字相同只是巧合。這裡能證明的是：**這一刀沒有讓任何一個檔的判定改變。**
- **Chrome 不在的時候 lane 怎麼讀**：
  - lane 只 glob `tests/python/test_*.py` 和 `tests/shell/test_*.sh`，所以 `tests/browser/` 完全不在它的範圍裡（上表的逐檔清單可以查）；
  - 頁面測試在 guard 外 5/5 都是 SKIP，會寫出原因（`LOGS/final-cb1b42d7/page-suite-noguard.log`）；CI 沒有 Chrome，結果也一樣是 SKIP，而且 lane 根本不會跑到它；
  - 新的 `test_ndt_serve_gui.py` 不需要 Chrome、不會 skip，在 lane 的直譯器（Python 3.8.20）下是 35/35 PASS。
- **lane 的 step 0（gate anchors，檢查 HEAD）**：`check_gate_anchors.py HEAD` 在 `cb1b42d7` 是 122/122（trunk 的 121 個閘門，加上新的頁面閘門）。
  - 兩個 rev 一起檢查時是 243/244，那一格是頁面閘門在 `b005bf50`「absent」，是預期中的結果。
  - log：`LOGS/final-cb1b42d7/gate-anchors*.log`。
- **CI 的推論**（沒有實際跑過）：CI 那 12 組的組成跟 `tests/python` 的逐檔判定有關。這一刀只新增了一個在 3.8 下綠、不會 skip 的檔，所以預期 CI 還是 12。這是推論，要等 orchestrator 併入後的 CI 實跑才算數。

### 4.3 瀏覽器實測（跑過，瀏覽器；和單元測試分開）

- 地點：Claude app 的瀏覽器面板。
- 伺服器：stub 伺服器，監聽 `127.0.0.1:18765`；用的是測試自己的 stub ndt 和 stub grid，HOME 是私有的，token 是測試用的。
- 逐列紀錄在 `LOGS/browser-pane-walkthrough/WALKTHROUGH.md`，伺服器端的請求 log、stub 呼叫紀錄、job 的 request 都在同一個目錄。

| # | 驗了什麼 | 結果 |
|---|---|---|
| B0 | 用一次性 URL 打開頁面 | 網址列只剩 `http://127.0.0.1:18765/`；session ok；storage 和 cookie 都是空的 |
| B1 | Up（claim 是你的） | argv 是伺服器給的 `ndt up 4`；焦點在 Cancel；要打 `up`；打之前 Confirm 是停用的 |
| B1b | 把焦點移到 Confirm 後按 Enter | 沒有送出，job 數是 0 |
| B1c | 連點兩下 Confirm | `POST /up` 只收到一次 202，stub 只收到一次 `up 4` |
| B2 | Down（claim 是別人的） | 顯示「claim first」；打了 `down` 之後 Confirm 仍然停用；伺服器只收到 dry run |
| B3 | Claim（measuring 是 iperf3） | 升級成打字確認 `claim`，measuring 原文標成警示色 |
| B4 | Claim（measuring 是 nothing） | measuring 列照樣顯示 `nothing`；不用打字；按一下得到 202 |
| B5 | H4 cell 的 run | 要打 `run`，也要勾確認框；勾了才能按；送出的 job body 帶 `confirm_shared_state_write: true` |
| B6 | offline_cell 的 walk，一路走到 verdict | 每一步都經過 dialog；最後記下 green |

- **截圖**只有 B0 和 B1 兩張，在 session 的對話紀錄裡。之後瀏覽器面板被收起來，截到的都是舊畫面，不算證據。其餘各列以 DOM 讀值和伺服器 log 為證。
- **這次實測找到、已修的一個小問題**：walk 在唯讀步驟時，dialog 的「ndt runs」那一格是空的，只有下面的 note 說明原因。修正在 `9a6eb7f1`：那一格改成寫「no ndt job」。
- 驗證方式：修正後重跑了 PageLint 和頁面測試。**這一格沒有在瀏覽器裡重新點過。**

### 4.4 這一刀沒做的

- 取消 job；
- P4 的 `--app` 欄位；
- 用 DevTools protocol 自動化點擊；
- 外觀打磨；
- 多人使用。
