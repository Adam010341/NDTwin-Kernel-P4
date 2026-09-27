（opus-judge 最後回覆，orchestrator 2026-09-27 存檔）

# JUDGE GUI-fcd4f69a

**讀取範圍**：我只讀了你指定的材料，另外抽查了分支的 worktree 和報告引用到的檔案。沒有讀其他 audit／handoff 文件，沒有用 git 歷史，也沒有執行任何東西。
- branch ref `.git/refs/heads/feat/ndt-serve-gui-0927` 指向 `fcd4f69a032e…`。
- 我拿 worktree 裡的 serve.py、app.js 和三個測試檔比對過 PATCH，內容一致。但我沒辦法跑 `git status`，所以 worktree 是否乾淨屬於【推】。

**縮寫**
- WT = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-0927`
- LOGS = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ndt-serve-gui-0927`
- PATCH = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/gui/diff-b005bf50..fcd4f69a.patch`
- RULINGS = `…/intake-0926/RULINGS-0927-ndtserve-gui-scope.md`
- 行號：`serve.py:n`、`app.js:n`、`gui:n`（`tests/python/test_ndt_serve_gui.py`）、`page:n`（`tests/browser/test_ndt_serve_page.py`）、`ndt:n` 都是 WT 裡的檔案行號。
- `REPORT:n` 是 REPORT.md 的第 n 行，等於 PATCH 的第 n+6 行。變異錨點引 PATCH 行號。

---

## Verdict：MERGE AFTER FIXES

- **成立的部分**：頁面路徑的安全設計（nonce、Host／Origin、CSP、0600、tty 分流）和 dry_run 設計，讀碼都成立。裁定 6 讀碼成立，log 裡的數字也大多對得上。
- **要修的部分**：apps start／stop 的「claim first」只有頁面這一道防線，違反這次審查的紅線。要補上後端檢查，或取得明確豁免。

## Blockers

**B1：apps start／stop 的 own-claim 要求只存在於頁面，後端一道都沒有。**【讀】

- **伺服器沒有檢查。**
  - `confirm_policy` 對 `apps.start`／`apps.stop` 回 `("plain", True)`（serve.py:380-381），頁面據此停用 Confirm（app.js:242）。
  - 但 `w_app`（serve.py:683-685）→ `_start`（:687-690）→ `_spawn`，呼叫時沒有帶 `precheck`（:692-710）。
  - 對照 cells run：它在 slot 內跑 `_require_own_claim`（:774, :776-798）。
- **ndt 也沒有檢查。**
  - `cmd_apps`（ndt:10341-10480）和 `app_start`（ndt:8889-8974）都沒有 `foreign_claim`，也沒有 `in_flight`。
  - energy／sim 直接跑 `sudo -n "$LAB" "$name-start"`（ndt:8919）。`ndtwin-lab` 的 `energy-start)`、`sim-start)`（ndtwin-lab:1749、1764）也沒有 claim 檢查。
  - 對照其他動作，後端都會拒絕：up 回 rc 5（`guard_up_lab_free`，ndt:996-1041）、down 回 rc 5（ndt:5044-5081）、claim 會拒（`claim_take`，ndt:776-788）、release 會拒（ndt:865-872）。
- **這個分支新增的文字把它說成有後端把關：**
  - README：「All of this is a guard in the page -- ndt and this server still decide.」（PATCH:2280-2281）
  - `confirm_policy` 的 docstring（serve.py:376-377）。
  - RULINGS:13 的前提「ndt/server still decide」，對 apps 不成立。
- **性質**：API 層的這個缺口從第一刀就存在，本刀沒有讓後端變差。但本刀把它變成瀏覽器裡一鍵可達，文件又寫成有後端把關。SCOPE §2 自己把 apps 列為「會改 lab：是」。
- **修法（三擇一）**
  - (a) `w_app` 改走 `_spawn(..., precheck=self._require_own_claim)`，並補一個測試例和一個具名變異。可以順便比照 down，對 measuring／declared 也拒絕。
  - (b) 這一刀先把 apps start／stop 從頁面拿掉。
  - (c) 由 Adam／orchestrator 明確豁免 apps，並改正上面那兩句文字。
- **【跑】重現方式**：用 GuiServe 起 stub 伺服器，`s.behave(status={"stdout": "lab\n  claim          orch-0924 -- 12m left (until 23:40:00)\n  measuring      nothing\n"})`，再 `s.post("/apps/sim/start")`。
  - 現況預期：回 202，且 `s.calls()` 裡有 `["apps","sim"]`。
  - 修好之後預期：回 409 `claim`，stub 沒有被呼叫。

---

## 逐項裁定

### 1. 頁面路徑的安全

**1a. token 不出現在 URL、log、storage、cookie 或 HTML：成立。**【讀】
- URL：啟動時和 `/session/new` 產生的 URL 都只放 nonce（serve.py:184-185、:615、:1226）。token 在 app.js 只出現三處（:25、:36 header、:156）。G5 caught。
- log：access log 只記 request line（serve.py:421-422），fragment 不會送到伺服器；stdout 只印 token 檔的路徑（:1222）。
- storage、cookie：PageLint（gui:696-702）加 G15／G15b 擋靜態寫法；瀏覽器端的 G13 擋繞過 lint 的寫法（page:251-258）。
- 唯一例外是 `ndt serve url` 會把帶 nonce 的 URL 印到 stdout，不分是不是 tty（見 G-N11）。那是 nonce，不是 token。

**1b. nonce：成立。**【讀】
- 一次性：`del` 在 `return` 之前，過期的也會刪（serve.py:212）。
- 有 TTL：deadline 用 monotonic 時間（:203、:213）。
- 常數時間比較：`hmac.compare_digest`（:211）。
- 同時最多 8 個（:202）。
- G6、G7、G32 都 caught（close-hidden gate.log:109、110、115）。

**1c. /session 的 Origin 檢查與靜態檔前的 Host 檢查：成立。我找不到讓別的本機 origin 或 DNS-rebinding 頁拿到 token 的路。**【讀+推】
- Host 檢查：`_check_host` 在任何路徑之前執行（serve.py:443 在靜態檔的 :446 之前）。它只收單一 Host，而且必須是 `127.0.0.1:<port>` 或 `localhost:<port>`（:470-475）。rebinding 頁送的 Host 是攻擊者的網域，所以回 403。G4 caught。
- Origin 檢查：Origin 必須存在，且等於 `"http://"+Host`（:600-602）。key 放在 query 回 400（:598）。body 必須剛好是 `{"nonce": …}`，而且是 JSON（:603-606）。
- 別的本機 origin（例如 :1313）：Origin 對不上所以 403；JSON POST 需要 preflight，而伺服器對 OPTIONS 回 405、不發 ACAO（:406-407、:527-537）。
- 本機其他使用者可以偽造 Origin，但拿不到 nonce：檔案 0600、目錄 0700（:131-136、:157-168）。
- 同源下沒有可被注入的 HTML：所有回應都是 JSON 或 text/plain，帶 nosniff 和 `default-src 'none'`（:425-438）。

**1d. CSP 禁止 inline script，頁面也沒有：成立。**【讀】
- CSP 沒有任何 `unsafe-*`（serve.py:85-90），而且加在每一個回應上（:432-433）。
- index.html 只有 `<script src="/app.js" defer>`（index.html:10），沒有 inline handler 或 style。
- app.js:271 的 `go.onclick = …` 是用 JS 指定函式，不是 inline，CSP 不會擋。
- G29、G29b caught。

**1e. `url_command` 的 /proc 檢查：對它要防的情境大致健全，失敗時都是不送 token（fail-closed）。有三個但書。**【讀+推】
- 只看 IPv4：只讀 `/proc/net/tcp`（:225）。伺服器只綁 127.0.0.1，所以範圍是對的。dual-stack 的冒充者只會出現在 tcp6 → 找不到 → 不送 token。
- byte order：`"0100007F:%04X"`（:222）是 little-endian 主機上的印法。在 big-endian 主機上永遠比不到，結果是 `url` 永遠拒絕：不會洩漏，只是功能壞掉。
- pid race：
  - pid 被別的使用者重用：讀不到 `/proc/<pid>/fd` → 判定 False（:230-232）。
  - pid 被同一使用者重用：同一使用者本來就讀得到 token 檔，不構成越權。
  - 檢查（:257）到連線（:260-263）之間有 TOCTOU 窗口：伺服器剛好在這時死掉、別人剛好綁上同一 port，token 就會送出去。窗口極小。
- 測試只涵蓋「pid 活著但不是 port 的持有者」（gui:366-403，G18）。pid 已死、位址過濾、LISTEN 狀態過濾這三種情況都沒有測試例（G-N7）。

**1f. serve.json 與 url 檔是 0600，url 檔只在 stdout 不是 tty 時寫：成立。**【讀】
- 兩個檔都用 `write_private` 寫（serve.py:157-168、:1210-1211、:1231-1232）。
- 只在非 tty 時寫 url 檔（:1227-1233）。
- 測試 gui:208-224、gui:226-250；G19、G31 caught。

### 2. dry_run 的設計

**2a. dry_run 能不能 spawn、寫檔、建 raw 目錄或記下 verdict：都不能。**【讀】
- `_check_write` 只對 `DRY_RUN_OK` 裡的 route 取出 `dry_run`，並要求它是 bool（serve.py:501-504）。
- `_spawn` 在進 `SLOT`、precheck 和 `store.start` 之前就 raise（:697-698）。
- cell run 在 `makedirs` 和 `_need_confirmation` 之前 raise（:766-771）。
- walk 的唯讀步驟在 `_do_step` 之前 raise（:914-915）。claim、run、release 步驟在 `_spawn` 裡 raise，所以 `g.save`（:917）不會被執行。`DryRun` 不是 `HttpError`，:950 的 except 接不到它。
- verdict 會被 `set(body) - {"verdict","note"}` 擋下（:971-973）。

**2b. DRY_RUN_OK 以外的 POST 全部拒收 dry_run：成立。**【讀】
- 12 條 POST route 裡有 5 條不在 `DRY_RUN_OK`（:1073-1106），各自都會拒收：
  - guided create：由 `cell_run_body` 擋（verbs.py:116-118）。
  - verdict：由 :971 擋。
  - abort：由 `no_fields` 擋。
  - session：由 :605 擋。
  - session/new：由 `no_fields`（:614）擋。
- 有測試：gui:304-305、gui:606-618。

**2c. `confirm_policy` 和 SCOPE §2、ndt 的一致性**
- 和 SCOPE §2 的表與 §2.4 的清單逐列一致。頁面另外加一條規則：measuring 不是 nothing、或有 declared 時，升級成打字確認（app.js:258）。
- 和 ndt 的後端防線比對：apps 不一致，見 **B1**。

**2d. UI-only 的防線**
- 只有 apps（B1）。
- up／down 在「沒有 claim」時頁面會擋、ndt 不擋。這是頁面比 ndt 嚴格（ndt 的規則是沒有 claim 就算空閒，ndt:354-355），不是唯一防線的問題。

### 3. 裁定 6（不准定期跑 ndt status）

**3a. 計時器和迴圈清單**（我 grep 了整個 app.js）【讀】
- `sleep` 是 setTimeout 的包裝（app.js:123），只在 :433 用到。
- `openJob` 的 `for(;;)`（:412-436）每一輪只做三件事：`GET /jobs/<id>`、`GET …/log/stdout?offset=`、`GET …/log/stderr?offset=`。
  - 伺服器端這幾個請求只讀檔（serve.py:630-664；cells.py:221-230 不開子行程）。
  - job 結束時各叫一次 `loadJobs`／`openWalk`，也只讀檔。
- `whileHidden` 的 listener（:125-136）只是讓 promise resolve。
- 沒有 setInterval、requestAnimationFrame，也沒有「切回分頁就重新整理」。

**3b. /lab 只在使用者動作時跑：成立。**【讀】
- 只有三個觸發點：打開頁面時一次（:632 → :600-601 → :168）、按 Refresh（:626）、每次打開確認 dialog（:218）。
- walkthrough 的 stub 呼叫紀錄裡，`status` 只出現在動作發生的時間點。

**3c. 三個停止條件：讀碼都成立。**【讀】
- job 結束：:428-432。
- 關掉畫面：closeJob 設定 `watching=null`（:439-442）；迴圈在 :414、:422、:435 三處檢查後 return。
- 頁面隱藏：每次 sleep 之後 `await whileHidden()`（:433-434）。隱藏時已經發出去的那一輪會讀完，所以延遲最多一輪。

**3d. `const mine = {}` 修掉 close+reopen 的雙迴圈：成立。**【讀】
- 每次打開都建一個新物件（:405-406），用物件同一性判斷。
- 舊迴圈在途的 GET 回來之後，會先檢查再 append（:414、:422）。

**3e. 測試有沒有真的執行停止條件：沒有。**【讀】
- PageLint 那兩例（gui:727-760）只對原始碼做字串和 regex 比對，沒有執行迴圈。
- 瀏覽器套件從來不開 job、不關畫面、也不切到背景。
- **job 結束那一條連拼寫都沒有被 pin 住。**把 app.js:428 改成 `if (false)` 的變異會存活（G-N1）。
- 唯一的執行期證據是附帶的：walkthrough 的 request log 顯示 job 結束後輪詢兩次就停（stub_serve.requests.log:13-20、29-35、41-47、61-69）。但那是 e4f7c036 的舊 app.js。

### 4. 測試

**4a. G 系列**
- close-hidden gate.log:99-149 實際有 **51** 條，全部 caught。
- 每一個 PageLint 例都至少有一個變異。
- GUI 的 37 例裡，有 2 例沒有任何變異（G-N8）。
- 主閘門的 `report()` 只看 FAIL／ERROR，不看原因（mutate_ndt_serve.sh:114）。G6、G7、G8b、G8c、G20、G21、G28、G36 都是以 `j["error"]` 的 KeyError 陣亡。我逐條追過，都是因為被測的性質失守，但閘門本身分不出這個差別（G-N9）。

**4b. 頁面閘門**
- G12、G13、G14、P1、P2 在 cb1b42d7 和 cf053502 都 caught。
- 這個閘門會要求輸出裡出現指名的原因（PATCH:2087），baseline 也拒收 skip（PATCH:2110-2114）。成立。
- 例外：G13 那一例裡，「token 不在 DOM」「token 不在 profile 檔」這兩個斷言（page:259-261）從來沒看過紅。

**4c. 抽 5 個變異驗證**【讀】

| 變異（PATCH 行） | 指名的測試例 | 我追出來的死因 | 判定 |
|---|---|---|---|
| G8b（1686-1690） | Session.test_the_key_is_traded_only_from_this_very_origin | 在 gui:284-287 的迴圈第 4 個 origin（`http://localhost:p` 配 Host 127.0.0.1:p）被變異接受，回 200 帶 token，接著 gui:287 取 `j["error"]` 時 KeyError | 理由正確（以 ERROR 形式陣亡） |
| G22b（1836-1843） | DryRunCells.test_a_cell_dry_run_makes_nothing_and_asks_nothing | lab_cell 和 offline_cell 都通過；H4 的預覽被 `_need_confirmation` 回 400，在 gui:595 失敗 | 正確 |
| G26b（1784-1788） | Lab.test_meta_is_the_servers_own_tables | /meta 仍回 30，但 `POST /claim {}` 的 argv 變成 `claim 60`，在 gui:517 失敗 | 正確 |
| G38b（1933-1937） | PageLint.test_a_hidden_page_does_not_poll_a_jobs_log | gui:747 找不到那行 early-return | 正確，但只是拼寫層級 |
| G39（1939-1943） | 同上 | gui:755 通過，gui:759 的 `const mine = \{\};` 比對不到 | 正確；語意上確實就是雙迴圈那個 bug |

**4d. 測試隔離：成立。**【讀】
- 測試裡沒有固定 port：`--port 0`（test_ndt_serve.py:125）、`bind(0)`（gui:369），只有手動 walkthrough 用了 18765。
- 在 guard 外：瀏覽器套件會 skip（page:155-156），頁面閘門以 exit 2 拒跑（mutate_ndt_serve_page.sh:56-60）。
- 主閘門和 GUI 套件不起 Chrome，不需要 guard。

**4e. CI 上的 skip：不會多出 CI 問題群。**【讀】
- L1 lane 只收集 `tests/python/test_*.py` 和 `tests/shell/test_*.sh`（step3b.extracted.sh:15），CI 也只跑這個 lane（.github/workflows/ci.yml:97）。`tests/browser/` 根本不會被收集。
- 沒有 Chrome 時，外層 decorator 的 `NO_CHROME` 原因會蓋過內層（page:70-72、155-156）。這條路徑從沒實際跑過（G-N15），但因為 lane 不收集，影響是零。

**4f. TMPDIR 已知問題：分支沒有讓它變好或變差。**【讀】
- test_ndt_serve.py 在這個分支只改了 :1166-1177 那一例（改名）。
- :610-616 的測試、:103 的 mkdtemp、`MAX_NOTE_CHARS` 都沒動。新增的套件也沒有把路徑塞進 note。

### 5. 碰不碰 lab

- **新測試和閘門碰不到 lab。**【讀】
  - 新檔裡沒有 sudo、curl、:8000、:8081（page:96 的 `8000` 是 `--virtual-time-budget`）。
  - lab 動詞一律打到 stub（test_ndt_serve.py:40-79、:124-127）。
  - walkthrough 只打到 stub：stub_ndt_calls.jsonl 每一筆的 cwd 都是 `stub-serve-tree/repo`。
- **真的 ndt 有被執行，但只跑三個非 lab 的指令**：`help`（test_ndt_serve.py:1037、gui:419-422）、`serve --help`（test_ndt_serve.py:1161）、`serve url`（gui:358-363，HOME 指向暫存目錄）。
  - 閘門會把真的 ndt 複製進每個 mutant 目錄再執行（mutate_ndt_serve.sh:68-70）。
  - `serve url` 走的 top-level 路徑和既有的 `ndt help` 測試相同，所以不碰 lab【推】。
- **L1 那兩輪在 guard 外跑了全部既有的 kernel-side 套件**（G-N16）。
- **guard 外那次 `chrome --version` 無害。**【推】`--version` 印出版本就結束，不會起整個瀏覽器行程樹。那次的紀錄在 page-suite-guard.log:1-2。

### 7. 範圍外或有風險的改動

- **ndt 的 3 行**：插在 ndt:11010-11012。
  - 驗證（test_ndt_serve.py 的 RcProvenance）pin 住的 RC_SOURCE 行號錨點，最大到 ndt:10419（verbs.py:272-284）。README 和 serve.py 裡引用的 ndt 行號最大是 9431。全部都在插入點之前，**一行都沒被推動**。【讀】
  - 主 checkout（trunk 工作樹，這是未提交的觀測）的 verbs.py 錨點，以及 ndt:10720、:11009，都和分支的 base 相同。所以合併後也不會移動。
- **405 的 Allow 標頭**：現在列出實際允許的方法（serve.py:462-463）。API 客戶端看得到這個變化，但無害。
- **靜態檔變成啟動的必要條件**：沒有 static/ 目錄時伺服器拒絕啟動（:171-181）。
- **serve.json 和 url 檔在關閉時不刪**：過期的檔案由 1e 的 /proc 檢查兜住。
- **serve.py docstring 的紅線 2 已過時**：它仍寫「every request but GET /health carries the token」（serve.py:18-19），但現在三個靜態 GET 和 `POST /session` 都不帶 token（G-N17）。

---

## 報告宣稱對照表

| # | REPORT 位置 | 宣稱 | 證據 | 判定 |
|---|---|---|---|---|
| 1 | :9 | 程式碼 head 是 cb1b42d7 | REPORT:31-36、122-128 自己寫了交付的是 cf053502 | **CONTRADICTED**（內部矛盾） |
| 2 | :10 | 沒用到 lab；真的 ndt 只跑了 help 和 serve url | 見第 5 節；小誤差：RcProvenance 其實也執行了 `ndt help` | SUPPORTED |
| 3 | :23-29 | cb1b42d7 的三條件現況 | red-first-on-cb1b42d7.log:17、28 | SUPPORTED |
| 4 | :31-35 | cf053502 的修正；紅燈先行 2 例；加 6 個變異，總數 144 | app.js:404-442；red-first log:2-4；close-hidden gate.log:144-149、164 | SUPPORTED |
| 5 | :36 | 三條件都 ✅（讀碼＋PageLint） | 讀碼成立；但 PageLint 不執行行為，job 結束那條沒被 pin | 讀碼 SUPPORTED；測試面 **UNDER-EVIDENCED** |
| 6 | :43-52、:58-65 | 強度表放伺服器；/lab 多回 declared；所有回應帶安全標頭；dry_run 預設拒收；dry_run 停在確認之前 | 第 1、2 節 | SUPPORTED |
| 7 | :53-57 | serve.json 加 /proc 持有者檢查 | gui:366-403、G18 | SUPPORTED（但書見 1e） |
| 8 | :66-71 | hugo 事件；事後 1313 無 listener | 只有自述，沒有 raw | **UNDER-EVIDENCED**（裁定 (3) 已收） |
| 9 | :72 | lane 用的是 3.8.20；套件在 3.8 下也綠 | SUMMARY.txt:4 證明 3.8 下綠；lane.out 沒有記錄直譯器 | 後半 SUPPORTED；前半 **UNDER-EVIDENCED** |
| 10 | :73 | 在 guard 外跑過 `chrome --version` | page-suite-guard.log:1-2（實際路徑是 `google-chrome`） | SUPPORTED |
| 11 | :82-84 | G 系列 53 條、總數 144；交件時 47／138 | gate log 實際是 51／45；144／138 正確 | 總數 SUPPORTED；G 數 **CONTRADICTED** |
| 12 | :110-112 | 74/74；cells 35/35；gui 35/35（含 3.8） | final-cb1b42d7/SUMMARY.txt:1-4；兩份 lane.out:39-41 | SUPPORTED |
| 13 | :113 | cb1b42d7 在 guard 內 5/5；16 個檔的 sha 相同 | page-gate.log:6、20-35 和 sha256.txt 對得上 | SUPPORTED |
| 13b | :113 | 「worker 在 e4f7c036 另外單獨跑過一次」 | page-suite-guard.log:1 寫的是 head 5281c2e1、app.js 96455231 | **CONTRADICTED**（commit id 不符） |
| 14 | :114 | guard 外 5/5 SKIP | page-suite-noguard.log:1-10 | SUPPORTED |
| 15 | :115-117 | 138/0；頁面閘門 5/0；anchors 122/122、243/244 | gate.log:146-158；page-gate.log:37；page-leftovers.log；gate-anchors.head.log:129；gate-anchors.log:88、131 | SUPPORTED |
| 16 | :118 | process_by_name 338 檔 0 處、tmpdirs 371 檔 0 處，涵蓋「整棵樹」 | 數字對得上 process-by-name.log:2、test-tmpdirs.log:1；但 process_by_name 的掃描範圍不含 tests/browser/ 和 tools/ndt_serve/（check_process_by_name.py:150、156-167） | 數字 SUPPORTED；「整棵樹」**UNDER-EVIDENCED** |
| 17 | :124-128 | cf053502：紅燈先行、144/0、頁面閘門 5/0、3.8 下 37/37、anchors 122/122 | close-hidden 目錄下各 log；anchors log 沒記 sha，ok(130)＝124+6 相符 | SUPPORTED；和 blob 的 sha 相等要【跑】 |
| 18 | :133-135 | 每個 G 變異都讓指名例變紅；help 寫好前那例是紅的；舊 root 例變紅 | 第一句有 gate log；後兩句沒有 raw（G34、M39 目前 caught，可當替代證據） | SUPPORTED／**UNDER-EVIDENCED** |
| 19 | :139-142 | 只跑 step 3b；原文 sha `c931643995be92dd`；驅動是 final_runs.sh | 兩份 lane.out 第 1 行；但 final_runs.sh:16 那次失敗了（SUMMARY.txt:7） | 前半 SUPPORTED；驅動鏈 **UNDER-EVIDENCED** |
| 20 | :145-152 | 12 對 12（655 s／680 s）；只差一行；其餘 102 檔相同 | trunk lane.out:137-138、branch lane.out:138-139；我逐行比過 | SUPPORTED |
| 21 | :153、:156-159 | lane 的 glob 範圍；gui 在 lane 下不 skip；step 0 | step3b.extracted.sh:15；branch lane.out:40 | SUPPORTED |
| 22 | :155 | 沒有 Chrome 時也一樣 SKIP | 只跑過「有 Chrome、沒 guard」那條路徑 | **UNTESTED**（影響為零） |
| 23 | :160 | CI 還會是 12 組（推論） | RULINGS:19 要求在合併後的樹上量，沒有量 | **UNDER-EVIDENCED** |
| 24 | :164-178 | 瀏覽器實測 B0–B6 | WALKTHROUGH.md:5、13-24 和伺服器 log 對得上，但點的是 e4f7c036（app.js 96455231），不是交付的 bae43421 | 對舊檔 SUPPORTED；對交付檔 **UNDER-EVIDENCED** |
| 25 | :180 | 截圖在對話紀錄裡 | 不在 LOGS 裡 | **UNDER-EVIDENCED** |

---

## NOTEs

- **G-N1**：停止條件的測試只到拼寫層級。建議加一條 PageLint pin 住 app.js:428，再配一個變異 G40（把 `state !== "running"` 換成 `false`）。行為層的測試留給下一刀的 DevTools 自動化。
- **G-N2**：G 系列的數字 53／47 和實際的 51／45 不符。
- **G-N3**：B 表沒有標出是哪一版 binary。9a6eb7f1 和 cf053502 改過的 confirmThen 與 openJob，都沒有在瀏覽器裡點過。
- **G-N4**：SUMMARY.txt:7 記的是 L1 失敗的那次（KERNEL_DIR 未設）。現存的 branch lane.out 是一次沒留下指令的重跑，直譯器也沒有記錄。
- **G-N5**：合併後的樹（5dc7fc9a 加本分支）的 lane 沒量，要在 intake 時補跑。
- **G-N6**：check_process_by_name 的掃描範圍不含 tests/browser/。讀碼看，瀏覽器測試只對自己建立的 process group 發訊號（page:198、203、214），性質是成立的，只是這道元閘門沒蓋到。
- **G-N7**：`listener_owned_by` 的三個但書：TOCTOU 窗口（可以改成先 `connect()`，驗過對方再送 request）、只適用 little-endian、有三個分支沒測。
- **G-N8**：`test_ndt_serve_url_is_the_same_command`（gui:358）和 `test_url_with_no_server_says_so`（gui:405）沒有任何變異。G13 裡的 DOM 和 profile 斷言沒看過紅。
- **G-N9**：主閘門不檢查陣亡原因，被 KeyError 打死的變異在閘門眼中和其他失敗一樣。
- **G-N10**：PageLint 允許 openSession 裡出現 `call("POST", …)`（gui:717）。塞在這裡的寫入只有 guard 內的 G14 看得到，CI 看不到。
- **G-N11**：`ndt serve url` 不管是不是 tty 都把 URL 印出來（serve.py:276）。啟動時那條「log 會留下 stdout」的原則沒有套用到這裡。風險有界：一次性、600 秒內有效。
- **G-N12**：walk next 的預覽和真正送出沒有綁定同一步，body 是 `{}`。如果另一個分頁在中間推進了 walk，確認的會是另一步。多人使用不在本刀範圍。
- **G-N13**：chrome --version 無害（見第 5 節）。
- **G-N14**：TMPDIR 那個已知問題，分支是中性的。
- **G-N15**：`NO_CHROME` 那條 skip 路徑從沒實際跑過。
- **G-N16**：L1 那兩輪在 guard 外跑了既有套件，其中有讀真機狀態的例子（l1_kernel_test_ndtwin_lab_heartbeat.log:129-130，讀本機的 veth）。都是唯讀、也是既有的 CI 內容，但報告說「沒碰 lab」時沒有涵蓋到它們。
- **G-N17**：serve.py:18-19 的紅線 2 文字要更新，把 `/`、`/app.js`、`/app.css` 和 `POST /session` 這幾個不帶 token 的例外寫進去。

## 我會跑、但報告沒跑的測試【跑】

1. 在副本裡把 app.js:428 改成 `if (false) {`，再跑 `NDT_SERVE_UNDER_TEST=<copy> python3 tests/python/test_ndt_serve_gui.py PageLint`。預期全綠，證明 job 結束那條有缺口。
2. B1 的重現（見上）。
3. 把 serve.py:228 的 `cols[1] == want and ` 刪掉，跑 UrlCommand 的 G18 那一例，預期會存活。再補一個「serve.json 裡的 pid 已經死了」的測試例。
4. `env PATH=/nonexistent /usr/bin/python3 tests/browser/test_ndt_serve_page.py -v`，預期 5 個 skip，原因寫的是 `NO_CHROME`。
5. 合併後的樹上跑 step 3b：`git worktree add --detach <tmp>/m 5dc7fc9a`，接著 `git -C <tmp>/m merge --no-commit fcd4f69a`。用 LOGS/final-cb1b42d7/l1_kernel_section.sh 分別對合併後的樹和乾淨的 5dc7fc9a 各跑一次再比對。
6. `cd WT; git diff --stat cf053502 fcd4f69a`，預期只有 REPORT.md。然後逐檔跑 `git show cf053502:<f> | sha256sum`，和 close-hidden gate.log:152-162 比對。
7. 用預設的 python3 跑 GUI 套件，確認 `Ran 37`。
8. 在頁面閘門加兩個陽性對照：`hook("t", token)`，以及繞過 lint 寫進 localStorage 的寫法。用來確認 page:259-261 那幾個斷言真的會紅。

## 報告內部的數字不一致

1. G 系列：REPORT:84 寫 53／47，但 gate log 是 51／45。
2. REPORT:9 寫程式碼 head 是 cb1b42d7，但 REPORT:31-36、122-128 寫的是 cf053502。
3. REPORT:113 寫 e4f7c036，但 log 是 5281c2e1。另外 page-gate.log:1 的標頭寫 app.js `96455231`，而同一個檔的第 28 行實測的是 `542770f0`：標頭是在排 guard 鎖之前寫的，之後檔案被改過。
4. REPORT:145-148 寫 680 s、12 組，但 SUMMARY.txt:7 記錄的是 rc=1、0 s。
5. REPORT:73 寫 `/opt/google/chrome/chrome`，但 log 是 `/opt/google/chrome/google-chrome`。
6. REPORT:18 寫「JS 約 615 行」，但交付的 app.js 是 638 行。



---

# JUDGE GUI-8c3047c7 (scoped re-review)

**範圍**：只審三樣東西。
- DELTA 的 6 個檔。app.js 和 index.html 沒動，兩道閘門列出的這兩檔 sha 也和 cf053502 相同。
- JF 目錄下的 log。
- WT 裡的檔案：branch ref 讀 `.git/refs/heads/feat/ndt-serve-gui-0927` 確認是 `8c3047c7…`；trunk ref 讀 `.git/refs/heads/trunk` 確認是 `7746832e…`。

我沒有執行任何東西，也沒有用 git 歷史。

**路徑縮寫**
- WT = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-0927`
- JF = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ndt-serve-gui-0927/judge-fixes`
- DELTA = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/gui/diff-fcd4f69a..8c3047c7.patch`
- 行號都是 WT 裡現行檔案的行號：`serve.py`；`gui` 指 `tests/python/test_ndt_serve_gui.py`；`ts` 指 `tests/python/test_ndt_serve.py`；`app.js`、`ndt`、`README`、`REPORT` 同理。

## Verdict：MERGE

- B1 已關閉。
- 上一輪列的不一致，全部已更正或照實揭露。
- 第 7 題的數字全部對得上 log。
- 剩下的只有 NOTE。另建議 intake 在合併 commit 上補跑一次 `check_gate_anchors`（G2-N5）。

## 剩餘 blockers

無。

---

## 1. B1 是否關閉：是

**修法本身**【讀】
- `w_app` 把 `precheck=self._require_own_claim` 交給 `_start`（serve.py:690-696），`_start` 再傳給 `_spawn`（:698-699）。
- `_spawn` 在 `with SLOT:` 裡的順序是：先查 busy，再跑 precheck，最後才 spawn（:710-720）。

**別人的、沒有、已過期、`yours-x` 的 claim 都回 409**【讀】
- `_require_own_claim` 用 `OWN_CLAIM.fullmatch` 比對 claim 列（:808-811）。這四種都不是 ndt 的 own form，所以回 409 `claim`，並把 claim 原文放在 `claim` 欄。
- 測試在 gui:563-580，四種 claim 各打 start 和 stop：
  - 每一次都斷言 `(409, "claim", <原文>)`（gui:569）。
  - 全部打完後，stub 收到的 argv 只有 `("status",)`，而且沒有任何 job（gui:573-575）。
  - 陽性對照：換成自己的 claim 後，start／stop 都回 202，argv 也正確（gui:576-580）。
  - Python 3.8 下綠（JF/test_ndt_serve_gui.py38.log:1）。
- 「完全沒有 claim 列」和「status 逾時或拿不到 read slot」這兩種，沒有 apps 專屬的測試例。但它們走的是和 lab cell 同一個函式（serve.py:797-807），C27／C28 在 cells 那邊有覆蓋（JF/gate.log:93-94）。

**預覽（dry_run）仍然不需要 claim：這樣是對的。**【讀】
- `_spawn` 在進 SLOT 之前就對 dry_run raise（:708-709）。所以預覽不跑 precheck、不跑 `ndt status`、不 spawn、也不寫檔。
- 預覽的回應帶 `needs_own_claim: true`（gui:572）。頁面據此顯示「claim first」並停用 Confirm（app.js:242，本輪沒動）。真正送出時，伺服器會在 slot 內重讀一次 claim。
- 如果預覽也要求 claim：在別人的 claim 下，dialog 就看不到 argv；每開一次 dialog 還會多跑一次 `ndt status`；卻換不到任何安全上的好處。
- 這一點已被既有測試釘住：`DryRun.setUp` 設了自己的 claim（gui:599），七個預覽之後仍斷言 `calls() == []`（gui:613）。要是 precheck 被挪到 dry_run 判斷之前，這裡會多出一次 `status` 而變紅。

**紅燈先行**【讀】
- JF/b1-red-first.log:2-18：新測試例對 fcd4f69a 的 serve.py 跑，第一個情境（別人的 claim、`/apps/sim/start`）就拿到 `(202, None, None)`，spawn 出來的 job argv 是 stub ndt。
- 紅的理由正確。log 的行號是中間版本的，見 G2-N4。

**G41 在指名的例上被抓**（JF/gate.log:150）【讀】
- 主閘門不檢查死因。但 G41 的變異（DELTA:414-419，把 `precheck=` 拿掉）在語意上就等於 fcd4f69a 的 `w_app`。所以它的死因就是 b1-red-first.log 裡那個 202。

**還有沒有別的路能不經 precheck 就到 `ndt apps`：沒有。**【讀】
- `ndt apps <name>` 和 `ndt apps stop <name>` 的 argv 只由 `verbs.argv_app`（verbs.py:153-161）產生，而它只在 `w_app` 裡被呼叫。
- 伺服器裡執行 ndt 的地方只有兩處：
  - `run_read`（serve.py:302），只跑 `status` 和 `apps status`；
  - `_spawn`，呼叫者只有 `_start`、`_spawn_cell_run`，以及 walk 的 claim／release 步驟（serve.py:955、979）。
- `GET /apps` 跑的是 `ndt apps status`（verbs.py:169）。ndt 在 `status` 子命令印完狀態就 return（ndt:10344-10346），是唯讀的。
- guided walk 的步驟裡沒有 apps。它的 run 步驟走 `_spawn_cell_run`，lab cell 會經過 precheck（serve.py:785）。
- cell 的 argv 永遠是 `run_cells.sh --cell … --raw-root …`（cells.py:217-219）。grid 裡的腳本只呼叫唯讀的 `ndt apps orphans`（run_cells.sh:126、133；stale_app_pidfile_does_not_frame_the_fabric.sh:165；half_stack_is_not_clean.sh:39），沒有任何 start 或 stop。
- `demo_sequence.py` 走 API，而且會先 claim，claim 沒拿到就停（demo_sequence.py:128-132）。不受影響。
- `POST /down` 會停掉 app（ndt:5176-5194），但那是在 ndt 自己的守衛之後（ndt:5044-5117）。見 G2-N7。

**文字已改正**【讀】
- README 的 API 表（README:53-54）、「Behind the page, who refuses」那一段（README:171-174）、`confirm_policy` 的 docstring（serve.py:381-384）、`_require_own_claim` 的 docstring（:788-791），都改成了正確的分工。
- 分支裡已經找不到「ndt and this server still decide」。
- SCOPE.md:70 還寫著「最後由 ndt 和伺服器決定」。那是核准時的草案原文；修正之後，這句對 apps 反而成立了。

## 2. 改了 stub claim 的五處，以及 Identity 的 7：都沒有削弱原本的斷言【讀】

- **數量說明**：實際是 ts 裡 4 個測試方法，加上 GUI 套件的 `DryRun.setUp`。REPORT 寫「第一刀 5 例」不精確（G2-N3）。
- **`test_app_name_must_be_one_of_ndts`**（ts:594-601）：壞名字回 400／404、以及 `calls() == []`（ts:598），都在設 claim **之前**斷言。所以它現在還多釘住一件事：白名單在 precheck 之前，壞名字連 `status` 都不會跑。
- **`test_app_names_come_from_ndt_itself`**（ts:603-613）：`nsr` 回 400 也在設 claim 之前。
- **`test_each_verb_reads_its_own_rc_table`**（ts:661-665）：`behave` 是一次寫入整份行為設定（原本的三個 key 加上 status），rc 表的斷言沒變。
- **`Identity`**（ts:961-975）：呼叫數從 6 變 7，多出來的是 precheck 那次 `status`。owner 的集合斷言現在也涵蓋了這次呼叫，是加強，不是削弱。
- **斷言整串 stub 呼叫序列的測試，一個都沒改，而且都還成立。**
  - `test_second_write_is_refused_while_one_runs`（ts:785-793）：在 up 佔住 slot 時送 `POST /apps/nsr/start`，斷言 `(409, "busy", first)`，且 `calls() == [["up","4"]]`。
    - 因為 busy 檢查在 precheck 之前（serve.py:711-715），這一例現在還順帶釘住了這個順序。順序若反過來，會多出一次 `status`，錯誤碼也會變成 `claim`。
  - `Csrf` 的 WRITES 例（ts:349、387-397）和 `test_up_refuses_unknown_fields`（ts:546-551）在 token 或白名單就被擋下，`calls() == []` 照舊成立。
- **baseline**：三套 baseline 都綠（JF/gate.log:2-4）。合併後的 lane 裡，test_ndt_serve.py 仍是 PASS 74。

## 3. G-N1／G40：釘在對的那一行【讀】

- 新測試例（gui:804-811）只在 `openJob` 的範圍裡找 `if (r.json.job.state !== "running") { … }`，並要求：
  - 這個分支以 `return;` 結尾；
  - 它出現在 `await sleep(2000);` 之前。
- 這正是 app.js:428-432。G40 的錨點（DELTA:421-425）也只命中這一行。
- 紅燈證據：
  - 補測試之前，PageLint 7 例全綠，也就是 G40 存活（JF/g40-survives-before.log:2-13）。
  - 補測試之後，在「the log loop does not stop when the job ends」這句變紅（JF/g40-red-after.log:5、15-18）。
  - 閘門也抓到（JF/gate.log:151）。
- 它仍然是拼寫層級的檢查，不是行為測試。照裁定，行為測試留給 DevTools 那一刀。

## 4. G-N7：更正我上一輪的預期；G44 成立

**更正**：我上一輪說「拿掉位址過濾 `cols[1] == want` 的變異會存活」。**這是錯的。**【讀】
- 拿掉位址加 port 的過濾之後，`inodes` 會收進 `/proc/net/tcp` 裡**所有** LISTEN 狀態的 socket（serve.py:231）。
- G18 那一例的 serve.json 寫的是**還活著的伺服器 pid**（gui:407）。這個 pid 在它自己的 port 上本來就有一個 LISTEN socket。
- 所以 `listener_owned_by` 回 True（:236-239），token 就被送到了陌生人的 port。
- 結果 stderr 寫的是「did not answer: Remote end closed connection without response」，不是預期的「is not the process listening」（JF/addr-filter-before.log:5、9-15；那次用的是 fcd4f69a 的測試檔，所以行號是 396）。閘門也抓到（JF/gate.log:152）。
- 我當時漏看了一件事：serve.json 指名的那個 pid，本身就在別的 port 上聽。

**同一句裡的 LISTEN 狀態過濾（`cols[3] == "0A"`）**：我仍預期拿掉它的變異會存活。【推，沒跑】
- G18 例、pid 已死例、正向例，都分辨不出有沒有這個過濾。
- 它的安全價值很低：換成另一個使用者的行程時，`/proc/<pid>/fd` 本來就讀不到，fd 檢查已經擋住了。見 G2-N1。

**G44：成立。**【讀】
- 變異內容（DELTA:433-443）：pid 已經不在時，改成「只要那個 port 上有人在聽就信任」。
- 結果：新測試例（gui:416-431）裡 token 被送到陌生人那裡，stderr 裡沒有「is not the process listening」，所以變紅（JF/gate.log:153）。死因正確。
- 防假綠：新例先 `wait()` 把子行程收掉，再斷言 `/proc/<pid>` 已不存在（gui:420-423），避免 pid 立刻被重用。

## 5. G-N8（G45、G46）與 G-N17（紅線文字）

**G45**（DELTA:445-449）【讀＋推】
- 變異讓 `ndt serve` 明確拒收 `url`。於是 `ndt serve url` 回 rc 2，而 `test_ndt_serve_url_is_the_same_command` 的 `check_url_answer` 要求 rc 0，所以變紅（JF/gate.log:154）。
- 這個變異有點刻意，但它證明的正是：`url` 沒傳到 serve.py 時，這一例會紅。
- 比較自然的退化（例如丟掉 `"$@"`）也會讓 serve.py 改去啟動伺服器，在 `s.env` 沒有 owner 時 exit 2，一樣會紅。

**G46**（DELTA:451-455）【讀】
- 變異：找不到 serve.json 時，改成猜 `{"port": 8765, "pid": 1}`。
- 在非 root 下讀不到 `/proc/1/fd`，於是以「is not the process listening」退出。rc 仍非 0、stdout 仍是空的，只是訊息不再是「no running server's files」。
- 所以 `test_url_with_no_server_says_so` 在訊息的斷言上變紅（JF/gate.log:155）。這一例要保證的本來就是「把狀況說清楚」，所以紅的理由正確。
- 非 root 下這個變異不會真的連到 8765。

**G-N17**【讀】
- serve.py:18-28 現在列出了不帶 token 的例外：`GET /health`、三個靜態檔（它們不執行任何東西），以及 `POST /session`（用一次性 key，而且**要求** Origin 是同一個 origin）。
- 這和程式碼一致。

## 6. REPORT 的更正，逐條對照

| 我上一輪列的不一致 | 新文字在哪 | 判定 |
|---|---|---|
| G 系列寫 53／47，實際 51／45 | REPORT:126；README:205 | 已更正 |
| 程式碼 head 寫成 cb1b42d7 | REPORT:9（寫 475b1036，並列出 cb1b42d7 → cf053502 → 475b1036 的演進） | 已更正 |
| 寫 e4f7c036，log 是 5281c2e1 | REPORT:155 | 已更正。同一條的後半（page-gate.log 的標頭）沒提到，見 G2-N6 |
| L1 寫 680 s／12 組，但 SUMMARY.txt:7 記的是失敗 | REPORT:200-204 | 已照實揭露。原因寫的是「`git worktree add … \| head -1` 吃到 SIGPIPE，worktree 沒建起來」，這和 l1_kernel_section.sh 第 11 行 KERNEL_DIR unbound 的錯誤相符（worktree 不在 → source 失敗 → KERNEL_DIR 沒被設）【推】 |
| chrome 的路徑 | REPORT:115 | 已更正 |
| JS 寫約 615，實際 638 | REPORT:58 | 已更正 |
| gui 寫 17 s，實際 16.5 s | REPORT:154 沒改 | 可忽略 |

上一輪宣稱對照表裡的其他項目也都處理了：
- 真的 ndt 跑了哪幾個指令：REPORT:10-12。
- lane 的直譯器當時沒有記錄：REPORT:112-114。
- 「整棵樹」改成「各自的預設掃描範圍」，並引用 page-static-checks.log（REPORT:160）。我讀過那份 log：兩個頁面檔跑 check_process_by_name 的結果是 0，另外還有陰性對照。
- 紅燈先行當時沒存 raw：REPORT:192。
- NO_CHROME 那條路徑這次實際跑了：REPORT:184。
- 合併後的樹也量了：REPORT:186、223。
- 瀏覽器實測點的是哪一版 binary：REPORT:229-232。
- 截圖沒存進 LOGS：REPORT:247。
- hugo 事件只有自述：REPORT:257。

新文字裡有兩處小的措辭問題，見 G2-N2、G2-N3。

## 7. 數字對帳：全部對得上

| 數字 | 對應的 log | 判定 |
|---|---|---|
| 150 條變異、0 倖存（340 s）；其中 G 系列 57、其他 93 | JF/gate.log:170；JF/SUMMARY.txt:3；G 開頭的 caught 行共 57 行 | 對 |
| gui 套件 40/40，Python 3.8.20 | JF/test_ndt_serve_gui.py38.log:43-45 | 對。版本號不在這份 log 裡：run_judge_fixes.sh:12 用的是 ryu-env 的 python，而 lane.out 記錄這個直譯器是 3.8.20【推】 |
| 頁面閘門 5/0，baseline 5/5，head 475b1036 | JF/page-gate.log:1、5、36 | 對 |
| NO_CHROME 5/5 skip | JF/page-suite-no-chrome.log:1-10；5 例寫的都是 NO_CHROME 的原因 | 對 |
| anchors 122/122（主閘門 ok(135)、頁面閘門 ok(4)） | JF/gate-anchors.head.log:86-87、129 | 對。這份 log 沒記是哪個 sha |
| L1：乾淨的 7746832e 是 12 組，合併後也是 12 組，只差 `test_ndt_serve_gui.py PASS 40` | l1-trunk-7746832e/lane.out:136、138；l1-merged-7746832e+475b1036/lane.out:40、137、139；l1-verdict-diff.txt:1-2；merge.log；merged-status.txt（14 個路徑）；JF/SUMMARY.txt:6-10（669 s／701 s；兩邊的直譯器都是 3.8.20；step 3b 原文的 sha 都是 `c931643995be92dd`） | 對。trunk ref 確實是 7746832e |

- 注意：l1-verdict-diff 只比「檔名加判定」，不比跑了幾例。「PASS 40」是我從 lane.out:40 看到的。
- 【跑】有兩件事我驗證不了：
  - 兩道閘門說「受測檔的 sha 和 475b1036 的 blob 逐一相同」；
  - 8c3047c7 相對 475b1036 只改了 REPORT。
  - 能確認的是：兩道閘門共用的檔案 sha 彼此一致。要驗證可以跑 `git -C WT diff --stat 475b1036 8c3047c7`（預期只有 REPORT.md），再逐檔 `git show 475b1036:<f> | sha256sum`，拿去對 JF/gate.log:158-168 和 JF/page-gate.log:19-34。

---

## New NOTEs

- **G2-N1**：G43 的更正見第 4 節。狀態過濾那一半，我仍推斷變異會存活，但價值很低。建議不補測試，只在 REPORT §4.4 記一句就好。
- **G2-N2**：REPORT:21 寫「這是判官的重現」。判官只給了重現步驟，沒有執行；真正跑過的是你的 b1-red-first.log。措辭問題。
- **G2-N3**：REPORT:24 寫「第一刀有 5 例」。實際是 ts 的 4 個測試方法（ts:599、610、662、964），加上 gui 的 `DryRun.setUp`（gui:599）。措辭問題。
- **G2-N4**：b1-red-first.log（行號 541）和 g40-red-after.log（行號 781），用的是 UrlCommand 重構之前的中間版測試檔，比現行的 gui:569／809 少 28 行；兩份 log 的標頭也沒記測試檔的 sha。斷言文字和交付版一致，只是出處鏈少了一環。以後紅燈先行的 log，請把測試檔的 sha 寫進標頭。
- **G2-N5**：trunk 7746832e 也改過 `ndt`（merge.log:1「Auto-merging tools/test_workflow/ndt」）。
  - 合併後的樹上只跑了 L1 step 3b。兩道閘門和 `check_gate_anchors` 都只在分支樹上跑過，而 CI 的 step 0 是對合併 commit 跑 `check_gate_anchors.py HEAD`。
  - 目前的跡象都說沒問題：合併後 test_ndt_serve.py（含 RcProvenance）仍是 PASS 74；主 checkout 的 ndt:10720 和 :11009 沒動（這是未提交的觀測）。
  - 【跑】建議 intake 在 scratch worktree 裡把合併 commit 起來，跑 `python3 tests/shell/check_gate_anchors.py HEAD`，預期 122/122。
- **G2-N6**：上一輪不一致第 3 條的後半沒處理：final-cb1b42d7/page-gate.log:1 的標頭寫 app.js 是 96455231，但實際測到的是 542770f0（同一檔 :28）。原因是標頭在排 guard 鎖之前就寫了。不影響結論，只是標頭會誤導讀的人。
- **G2-N7**：別把「apps 只能在自己的 claim 下停」讀得太字面。【讀】
  - `POST /down` 會經 `cmd_down` 停掉 app（ndt:5176-5194），它只受 ndt 自己的守衛管（別人的 claim、declared、有量測在跑）。
  - claim 是 none 或已過期時，ndt 照「沒有 claim 就是空閒」放行（ndt:354-355）；頁面在這裡比 ndt 嚴。
  - 這和我上一輪 2d 的判斷一致，不構成 blocker。README 那段可以補一句「down 也會停 app」。
- **G2-N8**：B1 修正的副作用。【讀】
  - apps 的 start／stop 現在會在 SLOT 裡跑一次 `ndt status`。
  - 最久可能佔住 slot：read_timeout 60 s，或拿不到 read slot 時等 30 s 後回 409。
  - 這和 lab cell 的 run 是同一個取捨，而且只在使用者按下時發生，不是定期的，所以和裁定 6 相容。
- **G2-N9**：G42 這個編號在閘門、測試、REPORT、LOGS 裡都找不到。如果是試過、倖存後刪掉的變異，請在 REPORT 註明；如果只是跳號，說一聲就好。
- **G2-N10**（紀錄，這輪沒被選入）：
  - G13 那一例的 DOM 和 profile 斷言仍然沒看過紅，頁面閘門還是 5 條。
  - PageLint 仍允許 `openSession` 裡出現 `call("POST", …)`（原 G-N10）。

