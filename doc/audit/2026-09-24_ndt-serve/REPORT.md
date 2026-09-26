# ndt serve 第一刀 — 報告（含判官修正輪）

[Co-developed with claude code -- Adam]

- 分支：`feat/ndt-serve-0924`（base trunk `fd7382a3`），worktree 在 `scratch/overnight-2026-09-05/wt-ndt-serve-0924`。**沒有併進 trunk，也沒有推任何遠端。**
- **09-26 併入時補註（下文不改）**：本報告引用的 ndt 行號都是 09-24 那份 ndt（blob `3273df8b`＝base trunk `fd7382a3` 的版本），早於 trunk `68ace017`（OVS 平面的 claim 修正）；§1 第 7 題、§2、§4.3 第 4 列、§4.4、§4.5 第 4 項說的「OVS 的 `up` 不擋別人的 claim（也不擋進行中的量測）」自 `68ace017` 起已不成立——併入後的 ndt:4248，`up_ovs` 呼叫 `guard_up_lab_free`。
- **本報告對應的程式碼 head 是 `490513fe`**：判官第二輪的修正在 `8f2fbb5b`；`3638ebd3` 改了測試和閘門，`490513fe` 把 listen backlog 提高到 64（§2「第二輪修正時我自己的失誤」）。
  - opus-judge 第一輪審的是 `e4589399`，裁定 READY AFTER FIXES（修完就能交）；修正輪的 commit 是 `c836cff0` 和 `5c07acf3`。
  - 第二輪審的是 `e4589399..e28bcfe4`，同樣 READY AFTER FIXES：第一輪的 9 項全部 FIXED，擋下來的是 cells 新碼；修正在 `8f2fbb5b`。
  - orchestrator 核對過：`e28bcfe4` 上 10 個受測檔的 sha256 和 `final-5c07acf3/sha256.txt` 逐一相同。
  - 判官全文在 orchestrator 那邊的 `logs/orchestrator-0924/judge-ndt-serve-e4589399.md` 和 `judge-ndt-serve-r2-e28bcfe4.md`。
- 工單：同目錄的 `TICKET.md`。第二張單（live_cells 入口加逐步引導）另寫在 `REPORT-cells.md`。
- live 分兩輪，時間都是 +08:00：
  - 第一輪 22:01:24–22:05:2x（§5.1–5.3）；
  - 修正輪 22:49:18–22:53:40（§5.4）。
- raw 在 `scratch/overnight-2026-09-05/logs/ndt-serve-0924/`，下文簡稱 `LOGS/`。scratch 被 `.gitignore` 擋著，所以 raw 不在分支上；歸檔的事見 §1 第 6 題。

---

## 1. 要你裁的

1. **併不併。** 我建議：判官把 `e4589399..5c07acf3`（修正輪加第二張單）審完、沒有新的必修，就可以併。改動範圍：
   - `tools/ndt_serve/`，全部是新檔；
   - `ndt` 本體只加 11 行，一個 `serve)` 分派和一段 help；
   - 其餘是測試和文件。
2. **下一刀的 GUI 放在哪裡。** 我建議 (a)：
   - (a) **由 ndt serve 自己從 `/` 提供靜態頁面**，跟 API 同源，「不開 CORS」這條紅線就能原樣保住。
   - (b) **放進 `~/Web-GUI`**：它是跨源的，等於要把第一刀刻意關掉的門打開。
3. **網頁怎麼拿到 token。** 修正輪之後，**除了 `/health`，所有 GET 也都要 token**，所以網頁連讀狀態都得先有 token。候選做法：
   - `ndt serve` 啟動時印出一條一次性 URL，token 放在 `#fragment` 裡（fragment 不會送到伺服器）；
   - 或者用 `SameSite=Strict` 加 `HttpOnly` 的 cookie，再配合自訂 header。

   第一刀兩種都沒做。
4. **P4 主機數。** 現在只開放 4 和 128；`ndt` 本身接受任何 4 的倍數。
5. **claim 上限。** 240 分鐘是我訂的保守值。另外 `NDT_MEASURING`、`NDT_EXCLUSIVE_CPU` 兩個旗標還沒開放。
6. **raw 的歸檔**（orchestrator 的裁定）：跟著「併不併」一起決定。你核准併入時，raw 一起進 audit-raw；在那之前一律留在 scratch，不推。
7. **🔴 ndt 本體的缺陷：OVS 平面的 `up` 不擋別人的 claim，也不擋進行中的量測**（§2 第一段）。orchestrator 已經另開修正工單，會以按鈕的形式出現在你那邊。我沒有動 ndt。
8. **排進下一刀的兩件事**（判官第二輪提出，orchestrator 裁定下一刀再做）：
   - **walk 的 claim 和 release 是以 owner 為單位，不是以 walk 為單位。** 如果你原本就 claim 著在做事，開一條 walk 會覆寫你的 claim（連 round baseline 一起重記），walk 結束時的 release 也會把它放掉。
   - **walk 的 status 步驟形同不擋。** plain status 永遠回 0，所以這一步一定會「過」。walk 真正的關卡是 claim 步驟，以及 run 步驟開跑前重讀的那一次 claim（`8f2fbb5b`）。

## 2. 推翻／更正

### 修正輪 live 抓到的 ndt 缺陷（不是 ndt serve 的；orchestrator 已讀碼確認）

- **現象**：在別人持有有效 claim 時打 `ndt up 4`（OVS），它**不會拒絕**，照樣把 fabric 建起來，並回 rc 0。
- **跟文件的落差**：`ndt help` 說 up 的 rc 5 包含「the lab is claimed by somebody else」，但這句只對 P4 平面成立。
- **原因**（讀碼）：`up_p4` 在 ndt:3057 會檢查 `foreign_claim`（別人的 claim），在 3063 檢查 `in_flight`（進行中的量測）；`up_ovs`（ndt:4047–4318）和上層的 `up)` 分派（ndt:10055）**兩項都沒有**。所以「量測進行中」在 OVS 平面同樣擋不住。
- **ndt 其實看見了別人的 claim**：`a/up-under-a-foreign-claim.stdout` 第 5–9 行有「the live claim belongs to ndt-serve-0924-foreign」，出自 `claim_note_up`（ndt:4146）。它只警告 claim note 沒有更新，然後照樣往下建。
- **cells 的直接 run 也受影響**（判官第二輪新發現 1）：直接 `POST /cells/<需要 lab 的格>/run`，原本只檢查 token 和槽位。在別人的 claim 下，這條路能把 fabric 建起來，而 run_cells 還原時的 `down` 會被 ndt 以 rc 5 擋下，fabric 就留在那裡。
  - 修正（`8f2fbb5b`）：直接 run 和 walk 的 run 步驟，都在持有槽位鎖時先讀 `ndt status` 的 claim 行，必須是 `yours` 才開跑，否則回 409。
- **時間軸**（raw 在 `LOGS/live-fixes-20260924T2249/a/` 和 `a-cleanup/`）：

  | 時間 | 事件 |
  |---|---|
  | 22:49:45 | owner `ndt-serve-0924-foreign` 直接下 ndt claim 5 分鐘。當下 `/status` 的 claim 欄是「ndt-serve-0924-foreign -- 5m left」（`a/18-…`） |
  | 22:49:46 | API 送出 `POST /up {"plane":"ovs","hosts":4}`，owner `ndt-serve-0924` 執行 `ndt up 4`，8.5 秒後 `up. ready`，rc 0（`a/19`、`a/20`、`a/up-under-a-foreign-claim.stdout`） |
  | 22:49:55 | 外人的 claim 被 release（`a/foreign-release.*`）；`/status` 顯示 claim none（`a/23`） |
  | 22:49:55–22:50:24 | **fabric 起著、沒有任何人持有 claim，約 29 秒**。在這之前，fabric 已經在外人的 claim 底下存在了約 9 秒 |
  | 22:50:24 | 我用 owner `ndt-serve-0924` claim，接著 `down`（15.0 秒，rc 0）、`release`（22:50:39）（`a-cleanup/`） |
  | 22:50:39 | 經 API 查 status：claim none（`a-cleanup/13-status-after.http`）。22:50:41 我在終端又直接查了一次，內容相同，但那次**沒有存檔** |

- ⚠️ 我在 22:5x 傳給 orchestrator 的訊息寫成「53 秒處於無人持有 claim」，這句不精確。53 秒是 fabric 從開始建到拆完的總存活時間；真正無人持有 claim 的是約 29 秒。
- **rc 表不改**：表上的 5 是 ndt 宣稱的語意，OVS 平面目前沒有兌現。這一點寫在 §4.4。
- **rc 5 改在 P4 平面釘**：22:52:16，在外人的 claim 下送 `POST /up {"plane":"p4"}`（刻意不帶 hosts，連「把 knob 改寫成同一個值」這一步都免了），回 **rc 5 refused**，訊息是 `XX the lab is claimed by ndt-serve-0924-foreign`。什麼都沒建，knob 的 diff 前後逐位元組相同（`LOGS/live-fixes-20260924T2249/a2/`）。
- **rc 3 在 live 上沒有釘到。** lab 已經 down 時打 `down`，回的是 rc 0：主 checkout 的 `.test_run/pids/app_viz.pid` 是一個舊檔，ndt 把它當成有 registry entry，也就是還有東西要收（`a/down-on-a-down-lab.stdout` 第 3 行）。這符合 ndt 對 3 的定義。那個檔不是我的，我沒碰，也沒有用別的方式去湊出 rc 3。rc 3 只在 stub 上驗過。

### 判官（審 `e4589399`）推翻我的宣稱，已修

1. **「GET 只跑唯讀動詞」是錯的。**
   - `GET /status?check=1` 會執行 `ndt status --check`，而它的 lock 探針會對 kernel 發三次 `POST /ndt/acquire_lock`（ndt:8832–8847，ndt 自己的註解也寫「it is still a POST」）。當時這個 GET 不需要 token，所以任何分頁放一個 `<img>` 就能觸發。
   - **修正**（`c836cff0`，orchestrator 裁定）：除了 `/health`，所有 GET 都要 token，Origin 也照寫入的方式檢查。另外：
     - `?wait=` 上限 300 秒；
     - 長等待同時最多 4 個（`--max-waiters`）；
     - 連線同時最多 32 條（`--max-connections`），超過的立刻回 503。
   - **live 修正輪**：lab 起著的時候，沒帶 token 的 `check=1` 回 403；帶 token 的回 200、rc 0，輸出寫著「the locks WERE checked: 0 held」，證明功能還在（`b/14`、`b/15`）。
2. **demo 的 busy 探針其實是一個帶 token 的真 `POST /down`。** 如果 `up` 秒退，這個探針就等於真的跑了一次 `ndt down`。已改成 `GET /health` 看槽位；docstring 裡「none of which can change anything」這句也拿掉了。
3. **唯讀呼叫的輸出沒有逐位元組保留。** 現在每次讀取都會把原始 bytes 落檔，可以用 `GET /reads/<id>/log/…` 取回，保留最近 500 筆。原因：ndt 用 `cut -c1-72` 按位元組截 claim note，中文可能被切在字元中間。
4. **rc 表出處的說法部分不實。** 只有 `up`、`down`、`status --check` 寫在 `ndt help` 裡；其餘六張表是讀碼得來的。
   - 現在 `verbs.RC_SOURCE` 逐一附上出處：help 的原句，或 ndt 的行號加上該行必須含的字串。測試 `RcProvenance` 會拿真的 ndt 去對。
   - `status.check` rc 1 的句子改成「ndt 回報至少一個 problem（欄位不符、別人持有 claim、量測進行中、netem、sudo 被拒等）」。
5. **symlink 被改指時，紀錄會說謊。** 現在一律執行啟動時解析出來的那個檔（`cfg.ndt_real`）；symlink 被改指、或檔案被改，`/health` 會用 `ndt_drift` 報出來。
6. **讀取逾時的路徑從沒執行過，而且可能卡死。** 現在 killpg 之後，管線最多再等 `PIPE_GRACE_S`（5 秒）。
   - 在舊碼上實測：同樣的情境下，舊碼卡了 25 秒，這是紅燈（`LOGS/fixes-red-037e915f.log`）。
   - ⚠️ 當時只修了 `serve.run_read`。cells 的 `Grid._run` 還是 `subprocess.run(timeout=60)`：逾時時只殺子程序本身，接著無上限地等管線，`TimeoutExpired` 也沒被接住，會變成 500（判官第二輪新發現 4）。`8f2fbb5b` 已經改成同樣的做法（新 session、killpg、PIPE_GRACE、結構化逾時）。靜態掃描也新增一條：不准再出現 `subprocess.run(timeout=…)`。
   - 「超過就 503」這句原本不實，實際是**先等最多 30 秒（`--read-queue-wait`）才回 503**，現在有測試。
7. **報告數字不一致。** 以下各項已修正或降級：
   - 錨點的「115／116 ok」原本沒有 raw，現在在程式碼 head 上跑了完整的 `check_gate_anchors`，全檔 log 見 §3。
   - 「掃四個服務檔」寫錯了，當時是 5 個，現在是 6 個。
   - **第一輪的「三次 git diff」只有兩次存了檔**（`00-before.txt`、`99-after.txt`），API 組之後那次只印在終端 → UNDER-EVIDENCED。
   - **「開跑前查過兩次 lab」只有一次存了檔**（`api/02-status-before.http`）→ UNDER-EVIDENCED。
   - **22:04:54–55 那兩次 status 是舊伺服器回的**，因為 ugrep 讓 SIGTERM 沒送出去（`serve.err` 第 35–36 行）。回應內容沒存，而且它們給的是修正前的語意；存下來的 `after-fix/` 是 22:05 新伺服器回的。
   - **「伺服器重啟後列出前一個伺服器的 6 個 job」的回應沒存**，只印在終端 → UNDER-EVIDENCED。修正輪的 `/jobs` 回應則存了（`a/25-jobs.http`、`b/36-jobs.http`）。
   - **第一輪的 `ss`、token stat、token grep 都沒有 raw** → UNDER-EVIDENCED。修正輪補存了（`live-fixes-20260924T2249/01-listen-and-token.txt`、`99-after.txt`）。
   - 「跑過」欄裡屬於讀碼推論的項目，都已經移到 §4.3 的「只讀過」欄。

### 第二輪修正時我自己的兩個失誤（已修，照實記）

- **我的測試漏程序。** 閘門裡 M40 拿掉 flock 之後，`test_second_server_on_the_same_state_refuses` 裡的第二個伺服器會成功啟動，而這條測試原本只關第一個。結果**每跑一次閘門就留下一個伺服器**，23:2x 時累積了 7 個，最早的活了 86 分鐘；加上我中途停掉的那一輪留下的 1 個，共 8 個。
  - 危害：它們只聽 127.0.0.1 的隨機 port，token 所在的暫存目錄也已經刪掉，所以沒有造成實際影響。
  - 清理：我逐一核對 cmdline 之後，按 pid 送 SIGTERM，全部停掉，事後確認是 0 個。
  - 修正（`3638ebd3`）：那條測試現在會一併關掉第二個伺服器；測試模組結束時，也會用它自己記下的 Popen 收掉任何被遺漏的伺服器，並在 stderr 點名。
  - 最終閘門跑完之後，另外存了一份殘留程序的清單：`final-490513fe/leftover-processes.txt`。
- **最終重跑時抓到的真缺陷：listen backlog 只有 5。**
  - 在 `3638ebd3` 上的最終重跑，並發測試失敗了一次：20 條同時的 POST 裡，有 1 條被 RST（`ConnectionResetError`）。重跑 10 次重現 1 次。
  - 原因：`socketserver` 預設的 listen backlog 是 5（`ss` 的 Send-Q 也顯示 5；第一輪 live 的 `ss` 就是 `LISTEN 0 5`）。一波超過 backlog 的連線，會在 `accept()` 之前就被 kernel 丟掉或重設。
  - 修正（`490513fe`）：backlog 提高到 64。另加一條確定性的測試直接讀 Send-Q，舊碼上是紅（`5 not greater than or equal to 64`），並配變異 M62。修正後並發測試連跑 20 次，0 失敗（`LOGS/r2-red-backlog-3638ebd3.log`）。
- **`8f2fbb5b` 那一輪閘門作廢。** 那一輪 `check_gate_anchors` 回報 C6 的錨點 MISSING：w_cell_run 改成讀 `cell_run_body` 之後，錨點裡的那段文字已經不存在。那一輪閘門跑到一半，被我停掉，不算證據。錨點已在 `3638ebd3` 跟著改好。

### 第一輪 live 推翻的（先前就已修正）

- **plain `ndt status` 一律回 0**（ndt:6497），只有 `--check` 才回 0／1／3。我原本在旁邊標「all compared fields match」，是錯的。已拆成兩張表（`d02689aa`、M41）。
- **同一秒建立的 job，順序是亂的**（M42）。
- **ugrep 對 NUL 分隔的內容，`grep -q` 會回 1**，所以第一次的 SIGTERM 沒送出去（失敗在安全的那一邊）。之後一律改用 `grep -a`。

## 3. 交付

程式碼 head `490513fe` 的 log 在 `LOGS/final-490513fe/`（`final-8f2fbb5b/` 是作廢的那一輪；`final-3638ebd3/` 那一輪有一條並發測試失敗，後來查出是 backlog 的問題，見 §2）；`5c07acf3` 的那批在 `LOGS/final-5c07acf3/`。兩個目錄各有一份 `sha256.txt` 記下受測檔的雜湊。既有 ndt 測試（26、23、345）只在 `5c07acf3` 上跑；`tools/test_workflow/ndt` 從那之後沒有改動（sha256 仍是 `c98f8f26…`，見兩份 `sha256.txt`）。

| 項目 | 結果 | log |
|---|---|---|
| 單元測試 | `test_ndt_serve.py` **72 條**（多了 backlog 那條）；`test_ndt_serve_cells.py` **32 條**（第二輪多 7 條）；結果見 §4.7 | `final-490513fe/test_ndt_serve*.log` |
| 本服務的變異閘門 | **86 個具名變異**（M1–M62、C1–C24），結果見 §4.7；受測檔 sha 前後不變 | `final-490513fe/mutate_ndt_serve.log` |
| 錨點 | `check_gate_anchors.py HEAD`，**全部閘門**跑完，存全檔 | `final-490513fe/check_gate_anchors.log` |
| 既有 ndt 測試 | `test_manual_rc_table.sh`、`test_ndt_up_target.sh`、`test_ndt_honesty.sh` 都在 `5c07acf3` 上重跑 | `final-5c07acf3/test_*.log` |
| 既有 ndt 變異閘門 | `mutate_ndt_honesty.sh` 67/67、`mutate_manual_rc_table.sh` 10/10（對照組保持綠），都在 `d02689aa` 上跑。**`tools/test_workflow/ndt` 的 sha256 在 `d02689aa` 和 `5c07acf3` 都是 `c98f8f26ae7e71ad…`**；ports.sh、sudo_surface.sh、components.env、兩支閘門和它們的測試、手冊，在這段期間都沒有改動，所以那兩份 log 沿用 | `mutate_ndt_honesty.d02689aa.log`、`mutate_manual_rc_table.d02689aa.log` |
| 靜態 meta-gate | 全樹跑 `check_process_by_name.py`、`check_test_tmpdirs.py` | `final-5c07acf3/check_*.log` |
| 修正的紅燈 | 修正輪的新測試先在 `037e915f` 上跑出紅（分類見 §4.3）；第二輪的新測試先在 `e28bcfe4` 上跑出紅（分類見 `REPORT-cells.md` §5） | `fixes-red-037e915f.log`、`r2-red-e28bcfe4.log` |
| live 第一輪 | 全程走 API 共 11 步，和直打 `ndt` 的對照組逐步一致 | `live-20260924T2201/` |
| live 修正輪 | 真 ndt 上釘到 rc 2 和 rc 5；rc 3 **沒釘到**；lab 起著時，沒帶 token 的 `check=1` 回 403，帶 token 的回 200 且探針有跑；OVS 缺陷已記錄並善後 | `live-fixes-20260924T2249/` |

§3 的閘門數字，以 `LOGS/final-5c07acf3/` 裡 log 的結尾行為準；§4.7 列出當時讀到的結尾行。

## 4. 細節

### 4.1 做了什麼

**本機 HTTP 服務**：只聽 `127.0.0.1`，單人使用，不登入。`/api/v1/` 放 API，其他路徑一律 404，並說明這些位置保留給 Web-GUI。

**除了 `/health`，每個請求都要帶 token**（`X-NDT-Token`），Origin 若有就必須同源；POST 另外要求 JSON body。

**讀取**：
- `ndt status [--check]`、`ndt apps status` 直接在請求中執行；
- 同時最多兩個，第三個先等最多 30 秒再回 503；
- 逾時就 killpg，自己那個 group 以外的程序握住管線，也最多再等 5 秒；
- 輸出按位元組落檔，可以用 id 查回。

**寫入**：
- 每次寫入是一個 job，只有一個槽，POST 立刻回 202；
- runner 用 setsid 起，runner 再把 `ndt` 起在另一個新 session 裡，stdout、stderr 直接寫檔；
- job 的狀態每次都從磁碟和 `/proc` 推導，共四種：`running`／`finished`／`orphaned`／`lost`。

**執行的是啟動時解析出來的 ndt**：每一個 job 和讀取都記下 sha；`/health` 會報出漂移。

**身分**：`--owner` 設定一次，之後每個 ndt 呼叫都帶它；繼承來的 `NDT_*` 全部丟掉。

### 4.2 怎麼啟動、API

見 `tools/ndt_serve/README.md`。

```bash
python3 tools/ndt_serve/serve.py --owner adam --ndt ~/.local/bin/ndt   # 現在
ndt serve --owner adam                                                 # 併進 trunk 之後
```

### 4.3 每條紅線的證據

「單元」指 stub 上的實跑，「live」指真的 lab。**只讀過碼的內容只放在最後一欄。**

**修正輪新測試在舊碼（`037e915f`）上的結果，依判官第二輪新發現 5 重新分類**（`LOGS/fixes-red-037e915f.log`）。表裡各列括號中的「舊碼上是…」以這張表為準：

| 類別 | 條數 | 變異 |
|---|---|---|
| 有意義的紅（舊碼的**行為**錯了） | 8 | M43（兩條：讀取不需要 token、`check=1` 不需要 token）、M44（跨源讀取）、M45（舊碼的上限是 600，301 被接受：`404 != 400`）、M49、M50、M59、M60 |
| 舊碼不認得新介面（新參數、新欄位、新屬性） | 7 | M46、M47、M52（新參數）；M48（新欄位 `read`：`KeyError: 'read'`）；M57、M58、M61（新屬性 `RC_SOURCE`） |
| 舊碼上本來就綠，紅燈只能靠變異證明 | 5 | M51、M53、M54、M55、M56 |

| # | 紅線 | 跑過（單元，含修正輪的紅燈來源） | 跑過（live） | 只讀過碼或規格、未實測 |
|---|---|---|---|---|
| 1 | 只聽本機、檢查 Host、不開 CORS | `/proc/net/tcp` 上只有 `0100007F`；外來 Host、缺 Host、錯 port 都回 403；preflight 和三個抽樣回應都沒有 `Access-Control-*`（M1–M5） | 修正輪 `ss -ltnpH` 只有 `127.0.0.1:8765`（`01-listen-and-token.txt`）；外來 Host 回 403（兩輪的 `04-probe-foreign-host`） | 「**所有**回應都不帶 ACAO」靠的是服務碼裡沒有 `Access-Control` 這個字串；沒綁 `::1` |
| 2 | 防 CSRF | 寫入沒 token 回 403，錯 token、token 放 query、跨源、表單型請求也都擋下（M6–M12）；**修正輪**：讀取沒 token 回 403，含 `check=1`（M43，舊碼上是有意義的紅）；跨源讀取回 403（M44，同上）；既有的 0777 目錄加 umask 000，啟動後仍收緊成 0700／0600（M54，舊碼上是綠，紅燈來自變異） | 沒 token 的 POST 回 403；**lab 起著時，沒 token 的 `check=1` 回 403、帶 token 的回 200**（`b/14`、`b/15`）；token 檔 0600、目錄 0700（修正輪的 stat）；用 token grep 全部 raw，**0 筆命中**（`99-after.txt`） | **沒用真的瀏覽器測過**，preflight 的部分是依 Fetch 規格推得的 |
| 3 | 白名單、argv、不經 shell | M13–M21；**修正輪**：`packages2/x` 這種前綴相同的兄弟目錄會回 400（M55，舊碼上是綠，紅燈來自變異） | job 紀錄裡的 argv：`up 4`、`up p4`、`apps nsr`、`apps stop nsr`、`down`、`release`、`claim …` | `--app` 沒在 live 跑過 |
| 4 | 薄殼 | rc 5 是 refused、rc 1 是 dirty；每個動詞一張表；未知 rc 標 unknown；job log 逐位元組（M22–M25、M41）；**修正輪**：讀取輸出逐位元組（M48，舊碼上的紅只是不認得新欄位 `read`；有意義的紅來自變異）；rc 表的出處對得上真 ndt（M57、M58、M61）；`check` rc 1 的句子（M59） | **rc 5（P4）、rc 2 用真 ndt 釘到**；rc 0 各步和第一輪的對照組一致 | **rc 3 在 live 沒釘到**（app_viz.pid 舊檔）；**OVS 平面的 rc 5 由 ndt 本身失約**（§2） |
| 5 | 長工作 | M26–M32、M42；**修正輪**：20 條並發 POST 恰好一個 202（M53）、zombie 不算活著（M56），這兩條在舊碼上是綠，紅燈來自變異；`?wait=` 上限（M45，舊碼上是有意義的紅：舊上限 600，301 被接受）；長等待數上限（M46）、連線數上限（M47），這兩條舊碼的紅只是不認得新參數，有意義的紅來自變異 | 兩輪各有一次「`up` 執行中看槽位」（第一輪 409；修正輪改用 `GET /health`，看到 busy） | 沒有在真的 `up` 進行中殺掉伺服器 |
| 6 | 永不 pkill -f | 用 repo 正本的 `check_process_by_name.py` 掃 6 個服務檔（M33）；**修正輪**：逾時路徑**實跑**，stub 睡過頭 → 回 timeout、process group 消失、讀取名額放回（M51，舊碼上就是綠，因為這條路徑本來就能用，紅燈來自拿掉 killpg 的變異）；管線被 group 外的程序握住時，不會卡死（M50，舊碼上是有意義的紅：卡了 25 秒）；503 前會等待（M52）；**第二輪**：judge 逾時會被停掉（C23，舊碼上是有意義的紅：等了 20 秒），靜態掃描不准 `subprocess.run(timeout=…)`（C24，舊碼上是有意義的紅：`cells.py:109`） | — | 送訊號的地方有兩處，`serve.run_read` 和 `cells.Grid._run`，都是對自己建立並記下 pid 的 group 做 killpg（讀碼加 AST 測試）。🔴 `e28bcfe4` 以前，這一欄寫「唯一」是**錯的**：`cells.py` 的 `subprocess.run(timeout=)` 在逾時時會隱式殺掉子程序本身。對象仍是自己的 pid，所以紅線 6 沒破 |
| 7 | 身分 | M34–M36；**修正輪**：執行的是啟動時解析出來的 ndt，`/health` 會報漂移（M49，舊碼上是有意義的紅） | `claim yours`；所有 job 的 owner 都是 `ndt-serve-0924`，外人探針的 owner 則是另一個 | — |
| 8 | 入口 | M37–M40 | worktree 的 `ndt serve` 真的起了伺服器（`ndt-serve-verb-smoke.txt`，**沒有記下啟動指令**：當時是 `setsid tools/test_workflow/ndt serve --owner verb-smoke --port 0 --state-dir <tmp> --token-file <tmp>`，這一行是事後補寫的） | 沒用 `ndt serve` 驅動過真 lab |
| — | demo 探針 | DemoProbes 用 AST 檢查：每個探針都是 GET 或不帶 token（M60） | 修正輪 demo 的四個探針：403、403、busy、403 | — |

### 4.4 沒做的事、已知限制

- **ndt 的缺陷，不是本服務的**：OVS 平面的 `up` 在別人持有 claim 時不會回 5（§2）。ndt serve 照原樣把 ndt 的 rc 傳回；rc 表寫的是 ndt 宣稱的語意。修正工單由 orchestrator 開。
- **rc 3 在 live 上沒釘到**：lab 已 down 時，主 checkout 有一個舊的 `app_viz.pid`。
- **沒有取消、沒有串流**；另外有些 ndt 功能沒有開放：`clean`、`check`、`ntg`、`apps orphans／trim`、`--telemetry`、`--deep`、`--force`（其中 deep 和 force 會回 400）。
- **「單人」靠的是 token。** 修正輪之後，讀取也要 token，所以同機的其他使用者連讀都讀不到；`/health` 是唯一的例外，它不執行任何東西。
- **讀取輸出只保留最近 500 筆**；job、cells-raw、guided 則會一直長大。
- **管線被 group 外的程序握住時**，逾時之後的輸出會丟掉，回應裡的 `note` 會說明。取部分輸出用的是 CPython 的私有屬性 `_fileobj2output`，取不到時就回空的。
- **orchestrator 裁定可以不做的四項**（判官的建議）：
  - absolute-form 的請求目標會照 path 路由，但瀏覽器送不出這種請求；
  - 405 回應的 `Allow` 寫死成 `GET, POST`；
  - 用不同 `--state-dir` 起的兩個伺服器，各有自己的槽，互相看不到；
  - runner 在「ndt 已經起來、runner.json 還沒寫」這個極短的窗口裡被殺的話，job 會變成 `lost`，槽也跟著放掉。
- **live 只跑了 OVS 4 和 P4 的拒絕路徑**；P4 的完整 up 和 `--app` 只在 stub 上驗過。
- **本 session 沒有 `TaskCreate` 工具**，進度都寫在報告和 SendMessage 裡。

### 4.5 給 Adam 的決策清單（下一刀以後）

1. **GUI**：見 §1 的第 2、3 題。畫面最少要有：lab 狀態卡、四個 lab 動詞、app 清單、job 和 log。`rc_class` 的配色**不能**把 `refused` 和 `dirty` 畫成同一個紅色。
2. **手動驗證入口**：已經做完，見 `REPORT-cells.md`。
3. **拓樸編輯**：要先決定編輯的對象（模型 JSON 還是 app 套件），以及存檔之後是不是一律要求重新 `up`。
4. **要給外部使用者用時得補的東西**：每人各自的身分驗證；不再只聽 loopback 就要 TLS；lab 的仲裁（claim 不是鎖，而且 OVS 的 `up` 目前連 claim 都不看）；稽核日誌；IPv6；打包成 systemd user unit；保留期限。
5. **觀察**：`apps stop nsr` 報出的 40 條 rules-in-window，其實是 fabric 自己的規則，只因為時間落在 nsr 的窗內就被算進去（G-12）。GUI 要避免把它畫成「app 留下了 40 條規則」。

### 4.6 本 session 的裁決紀錄

- **09-24 21:4x，Adam 用表單裁定**：做 live_cells 格子（我在表單上寫成 12 格，實際是 11 格）加逐步引導，排在第一刀交件後接著做，同一條分支。目的是讓他能快速親眼驗證 AI 的工作成果，「這樣我才不會心虛」。沒選的兩項是「唯讀證據瀏覽」和「包 39 支 live_*.sh」。
- **orchestrator 的裁定**（轉自判官結論）：
  - 除了 `/health`，所有 GET 都要 token；
  - 判官提的四項建議可以不做，列入已知限制；
  - raw 跟著併入的決定一起處理；
  - ndt 本體不要動，另開工單。

### 4.7 閘門結尾行

`490513fe`（最終程式碼 head）的結尾行放在本節最後。下面這張表是 `LOGS/final-5c07acf3/` 裡每份 log 的最後判定行，逐字照抄（22:5x 讀取）：

| log | 結尾 |
|---|---|
| `test_ndt_serve.log` | Ran 71 tests in 49.518s / OK / rc=0 |
| `test_ndt_serve_cells.log` | Ran 25 tests in 10.668s / OK / rc=0 |
| `mutate_ndt_serve.log` | 77 mutation(s), 0 survivor(s) / rc=0 |
| `check_gate_anchors.log` | 116/116 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL) / rc=0 |
| `test_manual_rc_table.log` | 26 passed, 0 failed / rc=0 |
| `test_ndt_up_target.log` | Ran 23 checks, 0 failed / rc=0 |
| `test_ndt_honesty.log` | Ran 345 checks, 0 failed / rc=0 |
| `check_process_by_name.log` | check_process_by_name: 316 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale / rc=0 |
| `check_test_tmpdirs.log` | check_test_tmpdirs: 350 file(s) scanned, 0 fixed temp paths / rc=0 |

**`490513fe`（最終程式碼 head）**，`LOGS/final-490513fe/`，23:39 讀取：

| log | 結尾 |
|---|---|
| `test_ndt_serve.log` | Ran 72 tests in 49.635s / OK / rc=0 |
| `test_ndt_serve_cells.log` | Ran 32 tests in 14.202s / OK / rc=0 |
| `mutate_ndt_serve.log` | 86 mutation(s), 0 survivor(s) / rc=0 |
| `check_gate_anchors.log` | 116/116 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL) / rc=0 |
| `check_process_by_name.log` | check_process_by_name: 316 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale / rc=0 |
| `check_test_tmpdirs.log` | check_test_tmpdirs: 350 file(s) scanned, 0 fixed temp paths / rc=0 |
| `leftover-processes.txt` | count=0 |


## 5. live

### 5.1 第一輪的條件（22:01:24–22:05:2x）

- **被驅動的 ndt**：`~/.local/bin/ndt`，指向主 checkout，sha256 `cb134ccc7af9577a…`，HEAD `fd7382a3`。
- **服務碼**：`a139bceb`。22:05 的修正後重驗，跑的是 `a139bceb` 加上未提交的 status 修正。
- **owner**：`ndt-serve-0924`。claim 兩次，每次 30 分鐘；API 組和直打組各自以 release 收尾。
- **`host_count_override`**：開跑前、結束後都存了 `git diff`，兩次都是未提交的 `-128 +4`（`00-before.txt`、`99-after.txt`）。API 組之後其實還看了第三次，但只印在終端、沒有存檔。
- **22:04:54–55**：兩次 status 由還沒停掉的舊伺服器回應，沒有存檔（§2 第 7 項）。

### 5.2 第一輪：API 組 vs 直打 `ndt` 組（`LOGS/live-20260924T2201/compare.md`）

| 步驟 | API rc | 直打 rc | API 關鍵行 | 直打關鍵行 |
|---|---|---|---|---|
| status-before | 0 | 0 | claim none | claim none |
| claim | 0 | 0 | | |
| up (`up 4`) | 0 | 0 | `up. ready` | `up. ready` |
| status-after-up | 0 | 0 | claim yours | claim yours |
| apps-before | 0 | 0 | nsr - | nsr - |
| nsr-start | 0 | 0 | `ok  nsr started` | `ok  nsr started` |
| apps-while-nsr | 0 | 0 | nsr running | nsr running |
| nsr-stop | 0 | 0 | tally 40 | tally 40 |
| down | 0 | 0 | `clean` | `clean` |
| release | 0 | 0 | | |
| status-after | 0 | 0 | claim none | claim none |

⚠️ 判官指出：其中 5 步的動詞本來就恆回 0（plain status 和 apps status），有鑑別力的只有 6 步。非零 rc 要看 §5.4。

### 5.3 第一輪 raw

`api/NN-*.http`（token 已遮蔽）、`api/<step>.stdout/.stderr`、`direct/`、`after-fix/`、`serve*.err`。

### 5.4 修正輪（22:49:18–22:53:40，程式碼 `c836cff0`；demo 那處改動之後 commit 成 `5c07acf3`）

- **條件**：
  - 開跑前查了三次：22:48:57 只印在終端，22:49:18 存在 `00-before.txt`（檔頭時間），22:49:40 只印在終端；三次都是 claim none、measuring nothing；
  - owner `ndt-serve-0924`，外人探針用 `ndt-serve-0924-foreign`；
  - 事前通知了 orchestrator，它回覆 lab 可以先用；
  - 結束時 claim none、topo absent，knob 仍是 `-128 +4`（`99-after.txt`）。
- **(a) 非零 rc**（`a/`）：
  - claim 15 分鐘，rc 0；
  - `down`（lab 已經 down）：**rc 0，不是 3**（原因見 §2）；
  - `apps stop nsr`（nsr 沒在跑）：**rc 2，nothing**；
  - release，rc 0；
  - 外人 claim 之後打 OVS `up`：rc 0，fabric 建了起來，這就是那個缺陷，善後見 §2。
- **(a2) rc 5**（`a2/`）：外人 claim 之後打 `up p4`，**rc 5 refused**，什麼都沒建，knob 不變；外人 claim 前後的 claim 欄都存了。
- **(b) demo 重跑**（`b/`）：
  - 四個探針：沒帶 token 的 POST 回 403；外來 Host 回 403；`up` 執行中看 `/health`，busy 指向那個 up job；沒帶 token 的 `check=1` 回 403。
  - 帶 token 的 `check=1` 回 200、rc 0，「the locks WERE checked: 0 held」。
  - `up 4`、nsr 起停、`down`、release 都是 rc 0。
- **raw 補齊**：
  - `01-listen-and-token.txt`：`ss -ltnpH` 和 token、目錄的 stat；
  - `99-after.txt`：用 token grep 全部 raw，0 筆命中；
  - `a/25-jobs.http`、`b/36-jobs.http`：`/jobs` 的回應。
