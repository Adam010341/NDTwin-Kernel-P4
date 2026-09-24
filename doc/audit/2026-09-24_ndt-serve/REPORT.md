# ndt serve 第一刀 — 報告

[Co-developed with claude code -- Adam]

- 分支：`feat/ndt-serve-0924`（base trunk `fd7382a3`），worktree `scratch/overnight-2026-09-05/wt-ndt-serve-0924`。**沒有併進 trunk，也沒有推任何遠端。**
- 工單：同目錄的 `TICKET.md`。承辦：session「ndt serve」。
- 寫於 2026-09-24 22:1x；live 在 22:01–22:05 跑。
- raw 放在 `scratch/overnight-2026-09-05/logs/ndt-serve-0924/`，下文簡稱 `LOGS/`。scratch 被 `.gitignore` 擋著，所以 raw 不在分支上；要不要歸檔進 audit-raw 見 §1 第 6 題。

---

## 1. 要你裁的

1. **併不併。** 分支 head 見 §3 最後一列。我的建議是 opus-judge 審過之後就併：改動只有 `tools/ndt_serve/`（新檔）、`ndt` 本體加 11 行（一個 `serve)` 分派、一段 help），加上測試和文件。
2. **下一刀 GUI 放在哪裡。** 兩個選項，我建議 (a)：
   - (a) **由 ndt serve 自己從 `/` 供應靜態頁**，跟 API 同源。「不開 CORS」這條紅線原樣保住；token 的遞送方式另見第 3 題。
   - (b) **放進 `~/Web-GUI`**，它有自己的 dev server，所以是跨源。這樣就得開一份 CORS 白名單，並把 token 交給另一個源——等於第一刀刻意關掉的門要打開。
3. **網頁怎麼拿到 token。** 瀏覽器讀不到 `~/.config/ndt-serve/token`。候選做法：
   - `ndt serve` 啟動時印一條一次性 URL，token 放在 `#fragment` 裡（fragment 不會送上伺服器，頁面讀到後存進 `sessionStorage`）；
   - 或者設一個 `SameSite=Strict`、`HttpOnly` 的 cookie，再保留自訂 header 的要求（雙重 submit）。

   這會牽動 CSRF 的設計，所以留給你裁；第一刀沒有做任何一種。
4. **P4 主機數的列舉。** 目前只開放 4 和 128，這兩個是這台量過的。`ndt` 本身接受任何 4 的倍數。要放寬嗎？
5. **claim 上限 240 分鐘**是我訂的保守值，`ndt` 本身沒有上限。另外，`NDT_MEASURING`（宣告正在量測）和 `NDT_EXCLUSIVE_CPU` 兩個旗標，API 還沒有開。要開嗎？
6. **raw 的歸檔。** 要不要把 `LOGS/` 歸進 audit-raw（那是 orchestrator 管的分支）？我沒有自己動它。

（你在本 session 已經裁過的一題記在 §4.6，不用再裁。）

## 2. 推翻／更正

- **live 推翻了我自己的一個宣稱。**
  - 第一版的 rc 表只有一張 `status`，所以不帶 `--check` 的 `ndt status` 回 0 時，旁邊會寫「all compared fields match」。
  - 但 plain `ndt status` 無論看到什麼都回 0（`cmd_status` 最後一行是 `return 0`），只有 `--check` 才會回 0／1／3。
  - live 的三次 status 回應都印出了這句話，其中兩次是在一個**根本沒有 baseline** 的 lab 上。證據：`LOGS/live-20260924T2201/api/02-status-before.http`、`14-…`、`33-…`，這幾份保留的是修正前的文字。
  - 修正（`d02689aa`）：拆成 `status`（rc_class 為 `report`，不下判決）和 `status.check`（0／1／3）兩張表。新測試先對上一顆 commit 的檔案跑出紅，再轉綠；變異 M41 也會抓到它。修正後重啟再問一次，結果在 `LOGS/live-20260924T2201/after-fix/status*.json`。
  - ⚠️ **離線的 51 條測試抓不到這一條**，因為 stub 對 status 回什麼 rc 是測試自己訂的。這正是那句「stub 自己的規格就是缺陷」的形狀。
- **live 也抓到一個小的排序錯。** 同一秒建立的 job，列表順序由隨機後綴決定，所以 claim 排到了它前面那個 `up` 的後面。已改成照 `created_at` 排序（同一顆 `d02689aa`，M42）。
- **我自己的一個工具失誤，失敗在安全的那一邊。** 停 live 伺服器前，我用 `grep -q` 比對 `/proc/<pid>/cmdline` 來確認身分。這台的 `grep` 是 ugrep，對 NUL 分隔的內容會回 1，所以第一次的 SIGTERM **根本沒送出去**，重啟也因此被 flock 擋下。改用 `grep -a` 之後正常。這件事不影響交付，但如果之後有人照抄同樣的防護寫法，要知道這一點。

## 3. 交付

| 項目 | 內容 | 狀態 |
|---|---|---|
| 服務 | `tools/ndt_serve/{serve,verbs,jobs,runner}.py`，純標準庫，不必安裝任何東西 | ✅ |
| 入口 | `ndt serve`：在 `ndt` 加一個 `serve)` 分派，exec 同一棵樹的 serve.py；`ndt help` 已列出 | ✅ |
| 單元測試 | `tests/python/test_ndt_serve.py`：**51 條**，stub ndt，不碰 lab，約 28 秒 | ✅ 綠 |
| 變異閘門 | `tests/shell/mutate_ndt_serve.sh`：**42 個具名變異，42 個被抓到，0 個倖存**；原檔 sha 前後不變 | ✅ `LOGS/mutate_ndt_serve.d02689aa.log` |
| 錨點 | `check_gate_anchors.py HEAD`：本閘門 ok；**其他 115 支既有閘門**在含本分支 `ndt` 改動的 HEAD 上也都 ok | ✅ |
| 既有 ndt 測試 | `test_ndt_honesty.sh` 345／345、`test_manual_rc_table.sh` 26／26、`test_ndt_up_target.sh` 23／23 | ✅ 實跑 |
| 既有 ndt 變異閘門 | 兩支會讀 `ndt help` 的閘門，在本分支 `d02689aa` 上實跑：`mutate_ndt_honesty.sh` 67 個變異 0 倖存；`mutate_manual_rc_table.sh` 10 個變異 0 倖存，1 個對照組照規定保持綠。兩支都是 rc 0 | ✅ `LOGS/mutate_ndt_honesty.d02689aa.log`、`LOGS/mutate_manual_rc_table.d02689aa.log` |
| 靜態 meta-gate | `check_process_by_name.py` 全樹 0 個命中；`check_test_tmpdirs.py` 0 | ✅ |
| live demo | 全程走 API，owner `ndt-serve-0924`，OVS 4：11 步全部 rc 0；直打 `ndt` 的對照組 11 步也全部 rc 0，**逐步一致**（§5.2） | ✅ |
| 文件 | `tools/ndt_serve/README.md`（API 一覽、curl、rc_class 表）；本報告 | ✅ |
| head | 見 SendMessage 那一行，或 `git log -1 feat/ndt-serve-0924` | — |

## 4. 細節

### 4.1 做了什麼

**本機 HTTP 服務，只聽 `127.0.0.1`，單人使用，不登入。** 路由如下：

- `/api/v1/` 底下放 API；
- 其他路徑一律回 404，並附一句說明：這些位置保留給下一刀的 Web-GUI 靜態檔。

**讀取（GET）只跑唯讀動詞，並且當場回應。** 會呼叫的只有 `ndt status`、`ndt status --check`、`ndt apps status`，回應裡附 rc 和完整的 stdout／stderr。

**寫入（POST）一律變成 job。**

- 動詞：`claim`、`release`、`up`、`down`、`apps/<name>/start|stop`。
- POST 立刻回 202 和 job id。
- 同一時間只能有一個 job；有 job 在跑時，其他 POST 回 409，並指明是哪一個 job 佔著。

**job 的執行方式：**

- 伺服器用 `setsid` 起一個 runner；runner 再把 `ndt` 起在另一個新 session 裡。
- 為什麼分兩層：`ndt up`／`down` 殺過呼叫它的那個 shell（08-29，exit 144）。在這個架構裡，runner 就是那個呼叫者。
- stdout 和 stderr 直接寫進檔案，不接管線，所以伺服器死掉也不會引發 SIGPIPE。
- `ndt` 結束後，runner 寫出 `exit.json`。

**job 的狀態每次都從磁碟加上 `/proc` 重新推導，共四種：**

| 狀態 | 意思 |
|---|---|
| `running` | runner 還活著 |
| `finished` | 有 `exit.json`，rc 已記錄 |
| `orphaned` | runner 死了，但 `ndt` 還在跑；仍然佔著 job 槽 |
| `lost` | runner 和 `ndt` 都結束了，沒有人記下 rc |

判斷程序「活著」用的是 (pid, starttime)，並排除 zombie。

**身分：**

- 啟動時用 `--owner` 指定（或讀 `$NDT_OWNER`）；
- 每一次 `ndt` 呼叫都帶這個 `NDT_OWNER`；
- 啟動 shell 裡繼承來的其他 `NDT_*` 變數全部丟掉，以免一個遺留的 `NDT_TOPO` 默默改變之後每一個請求的行為。

### 4.2 怎麼啟動、API 一覽、curl

見 `tools/ndt_serve/README.md`，這裡不重複。最短路徑：

```bash
python3 tools/ndt_serve/serve.py --owner adam --ndt ~/.local/bin/ndt   # 現在（trunk 還沒有 serve 動詞）
ndt serve --owner adam                                                 # 併進 trunk 之後
```

### 4.3 每條紅線的證據

**「跑過」和「讀碼／規格推得」分兩欄，不混在一起。**「單元」指 stub 上的實跑，「live」指真的 lab。

| # | 紅線 | 跑過（單元） | 跑過（live） | 只讀過碼或規格、未實測 |
|---|---|---|---|---|
| 1 | 只聽本機、檢查 Host、不開 CORS | `/proc/net/tcp` 上只有 `0100007F`，tcp6 上沒有；外來 Host、缺 Host、錯 port 都回 403；preflight 和所有回應都沒有 `Access-Control-*`。M1–M5 | `ss` 顯示只有 `127.0.0.1:8765`；Host 為 `rebind.attacker.test` 時回 403（`04-probe-foreign-host.http`） | 沒有綁 `::1`，這是刻意的選擇 |
| 2 | 防 CSRF：token、自訂 header、JSON、Origin | token 檔 0600、目錄 0700、每次啟動都換新；沒帶或帶錯 token、token 放在 query、跨源 Origin（包括 `null`）、表單型 Content-Type 都被拒，而且拒絕時 stub **一次都沒被呼叫**；GET 打寫入路徑回 405。M6–M12 | 沒帶 token 的 POST 回 403（`03-probe-no-token.http`）；正式路徑上 token 檔 0600、目錄 0700；存檔裡 7 個帶 token 的請求都被遮成 `<token>`；拿當時仍在檔案裡的 token（第二次啟動寫的那個）grep 全部 raw，0 筆命中。第一次啟動的 token 已被覆蓋，沒辦法拿來 grep；它沒有外洩的依據是 driver 的程式碼只會寫 `<token>` | **沒有用真的瀏覽器測過。**「自訂 header 會觸發 preflight，而這個伺服器永遠不回應 preflight」這句話是依 Fetch 規格推得的，測試只驗證了伺服器這一側 |
| 3 | 白名單、argv list、不經 shell | 六種 `up` 形式逐字對上 argv；列舉範圍外的值、未知欄位（`deep`、`force`、`telemetry`）都回 400；`--app` 取 realpath 後必須落在允許的根目錄內（含 symlink 逃逸）；app 名稱取自 ndt 自己的 `APP_NAMES`；claim note 裡的 `$(touch …)` 和反引號原樣抵達 argv，標記檔沒有被建立；AST 掃描確認沒有 shell。M13–M21 | job 紀錄裡的 argv：`up 4`、`apps nsr`、`apps stop nsr`、`down`、`release`、`claim 30 <note>` | `--app` 在 live 沒有跑過 |
| 4 | 薄殼：rc 原樣傳回、輸出全文保留 | rc 5 是 `refused`、rc 1 是 `dirty`，兩者不同；每個動詞各自一張 rc 表（`apps stop` 的 2 是 `nothing`，不是 usage）；未知 rc 標 `unknown`；300 KB 含非 UTF-8 的輸出逐位元組取回，分段讀取也一致；plain status 不下判決。M22–M25、M41 | 11 步的 rc 和直打完全一致（§5.2）；live 抓到 plain status 的語意錯並已修正（§2） | **live 沒有看過 rc 5**：lab 空著，guard 沒有機會拒絕。rc 5 只在 stub 上驗過 |
| 5 | 長工作：非同步、單一槽、setsid、落地存檔 | POST 在 1.5 秒內回 `running`；第二個寫入回 409，且 stub 只被呼叫一次；對伺服器的整個 process group 送 SIGKILL 之後，`ndt` 照樣跑完，重啟後讀回 rc；重啟後仍認得還在跑的 job；runner 和 `ndt` 各自在不同 session；orphaned 仍佔著槽；lost 不被當成 finished；同一秒建立的 job 依建立時間排序。M26–M32、M42 | `up` 執行中打 `down` 回 409（`10-probe-busy-while-up.http`）；伺服器重啟後列出了前一個伺服器的 6 個 job | **沒有在真的 `up` 進行中殺掉伺服器**：那會讓共用 lab 的狀態變得不確定，所以保守地只在 stub 上做 |
| 6 | 永不 `pkill -f`／`pgrep -f` | 用 repo 正本的 `check_process_by_name.py` 掃四個服務檔：0 個命中；整個服務裡唯一送出的訊號是 `os.killpg(p.pid, …)`，對象是自己用 `start_new_session` 建立、並記下 pid 的 group。M33 | — | 這條 timeout 路徑在 live 沒有被觸發過 |
| 7 | 身分 | 每一次呼叫都帶 `NDT_OWNER=<owner>`；繼承來的 `NDT_TOPO`、`NDT_MEASURING`、`NDT_OWNER` 都被丟掉；沒有 owner、或 owner 格式不合，就拒絕啟動，也不寫 token。M34–M36 | `status-after-up` 顯示 `claim yours -- 30m left`，owner 是 `ndt-serve-0924` | — |
| 8 | 入口、help、路由預留 | `ndt help` 列出 serve；`ndt serve --help` 真的 exec 到這個伺服器；`/`、`/index.html` 都回 404 並附說明；同一個 state 目錄的第二個實例拒絕啟動，**也不會覆寫**正在跑的那個的 token。M37–M40 | worktree 的 `ndt serve --owner verb-smoke --port 0` 真的起了伺服器，`/health` 顯示它驅動的是同一棵樹的 ndt（sha `c98f8f26`），SIGTERM 能停（`LOGS/ndt-serve-verb-smoke.txt`）。這一次沒有碰 lab | **沒有用 `ndt serve` 驅動過真的 lab**：主 checkout 是 trunk，還沒有這個動詞，所以 live demo 是直接跑 `python3 tools/ndt_serve/serve.py --ndt ~/.local/bin/ndt` |

### 4.4 沒做的事、已知限制

- **沒有取消功能**（第一刀可以不做）。將來要做，只能對 `runner.json` 裡記下的 `ndt_pgid` 送訊號。
- **沒有串流**：log 用 `offset` 輪詢，job 用 `?wait=` 長輪詢。
- **沒有開放的 ndt 功能**：`clean`、`check`、`ntg`、`apps orphans`、`apps trim`、`up --telemetry`、`down --deep`／`--force`、`release --force`，以及 claim 的 `NDT_MEASURING`／`NDT_EXCLUSIVE_CPU`。其中 `--deep` 和 `--force` 是刻意擋掉的，送過來會回 400。
- **「單人」靠的是 token，不是 loopback。** 同一台機器上的其他使用者連得到這個 port：他們沒有 token，所以寫不了，但 GET（例如 status）讀得到。對這台個人筆電可以接受，要給外部使用者就得補（§4.5）。
- **rc 表是從 `fd7382a3` 的 `ndt help` 抄來的。** 如果 `ndt` 之後改了 rc 的語意，這張表會開始說謊，而目前沒有測試把它釘在 `ndt help` 上。`test_manual_rc_table.sh` 對手冊做的正是這件事，下一刀值得照樣做一條。
- **同時最多兩個唯讀呼叫**，超過就回 503。這是為了防止 GUI 高頻輪詢時同時開出一堆 `ndt status`。
- **job 目錄不會自動清理**，會一直長大。
- **zombie 視窗。** runner 若在沒寫 `exit.json` 的情況下死掉，被 reaper（每秒一次）收掉之前，它都還是伺服器的 zombie，而 `alive()` 已經把 zombie 排除，所以不會誤判成活著。但如果 reaper thread 本身停了，這一點就沒有別的防護。
- **live 只跑了 OVS 4。** P4 和 `--app` 只在 stub 上驗過；工單允許 4 或 p4 4 擇一。
- **本 session 沒有 `TaskCreate` 工具**，所以進度沒有進 task list，都寫在這份報告和 SendMessage 裡。

### 4.5 給 Adam 的決策清單（下一刀以後）

1. **GUI（下一刀）**：放在哪裡、token 怎麼遞送，見 §1 的第 2、3 題。畫面最少要有：lab 狀態卡（claim、measuring、fabric）、up／down／claim／release 按鈕、app 啟停清單、job 列表加即時 log。另外，`rc_class` 的配色**不能**把 `refused` 和 `dirty` 畫成同一個紅色。
2. **手動驗證入口（你已裁定，§4.6）**：live_cells 12 格＋逐步引導模式，排在第一刀之後、同一條分支上。待定的細節：
   - 引導步驟由誰寫、寫在哪裡。我建議每一格旁邊放一份 `STEPS.md`，逐步寫「要做什麼、要看哪裡、綠長什麼樣」；
   - 跑格子會佔 lab，所以要走跟 up／down 同一個 job 槽，並自動 claim 和 release。
3. **拓樸編輯（痛點 1）**：不在第一刀。需要先裁的是：編輯的對象是拓樸模型 JSON（`topo_from_json.py` 讀的那份）還是 app 套件；以及存檔後是不是一律要求重新 `up`。
4. **要給外部使用者用時得補的東西：**
   - 每個人各自的身分驗證（取代單一 token）；
   - 如果不再只聽 loopback，就要 TLS；
   - 多人同時要用 lab 時的仲裁——claim 只是約定，不是鎖，`ndt help` 自己也這樣寫；
   - 稽核日誌（誰在什麼時候做了什麼）；
   - 速率限制；
   - IPv6；
   - 把 rc 表釘在 `ndt help` 上的測試；
   - 打包成 systemd user unit；
   - job 目錄的保留期限。
5. **一個觀察，不是本刀的缺陷：`ndt apps stop nsr` 報出 40 條 rules-in-window。** nsr 是唯讀 app，這 40 條其實是 fabric 自己的轉發規則，只因為建立時間落在 nsr 的時間窗內就被算上（G-12：「suspected by time only」）。API 組和直打組都是 40，所以這是 `ndt` 本身的行為。但 GUI 如果把它畫成「app 留下了 40 條規則」，就會誤導使用者，呈現方式要想好。

### 4.6 本 session 的裁決紀錄

- **09-24 21:4x，你用表單裁定手動驗證入口：**
  - 做 **live_cells 12 格**，並加 **逐步引導模式**；
  - 排在**第一刀交件後緊接著做**，同一條分支；
  - 目的（你的原話）：讓你能快速親眼看到、驗證 AI 的工作成果，「這樣我才不會心虛」。
- **沒選的兩項：**「證據瀏覽（唯讀）」和「包 39 支 live_*.sh」。

## 5. live demo

### 5.1 條件

- **時間**：2026-09-24 22:01:24–22:03:26（+08:00）。
- **lab**：開跑前查過兩次，claim 都是 none、measuring 都是 nothing；前一個 claim 是 orch-0924 的，21:15 已被取代。
- **被驅動的 `ndt`**：`~/.local/bin/ndt`，指向主 checkout 的 `tools/test_workflow/ndt`，sha256 `cb134ccc7af9577a…`。主 checkout 的 HEAD 是 `fd7382a3`。
- **服務碼**：分支 `a139bceb`（修正前）。22:05 修正後重驗 status 的那個伺服器，跑的是 `a139bceb` 加上未提交的 status 修正，也就是 `d02689aa` 裡 verbs.py／serve.py 的部分；jobs.py 的排序修正是在那之後才寫的。
- **owner**：`ndt-serve-0924`。claim 兩次，每次 30 分鐘；API 組和直打組各自以 release 收尾。
- **`host_count_override`**：開跑前、API 組之後、直打組之後都用 `git diff` 看過，三次都是同一個未提交的 `-128 +4`，**沒有被動到**（`LOGS/live-20260924T2201/00-before.txt`、`99-after.txt`）。

### 5.2 API 組 vs 直打 `ndt` 組（`LOGS/live-20260924T2201/compare.md`）

| 步驟 | API rc | 直打 rc | API 關鍵行 | 直打關鍵行 | API 秒 | 直打秒 |
|---|---|---|---|---|---|---|
| status-before | 0 | 0 | claim none | claim none |  | 1.1 |
| claim | 0 | 0 |  |  | 0.1 | 0.1 |
| up (`up 4`) | 0 | 0 | `up. ready` | `up. ready` | 9.5 | 8.5 |
| status-after-up | 0 | 0 | claim yours -- 30m left | claim yours -- 30m left |  | 1.3 |
| apps-before | 0 | 0 | nsr - | nsr - |  | 0.4 |
| nsr-start | 0 | 0 | `ok  nsr started` | `ok  nsr started` | 1.1 | 1.1 |
| apps-while-nsr | 0 | 0 | nsr running | nsr running |  | 0.5 |
| nsr-stop | 0 | 0 | tally 40 rules-in-window | tally 40 rules-in-window | 6.9 | 6.9 |
| down | 0 | 0 | `clean` | `clean` | 15.0 | 15.0 |
| release | 0 | 0 |  |  | 0.0 | 0.0 |
| status-after | 0 | 0 | claim none | claim none |  | 1.0 |

- API 組的 `up` 不只 rc 為 0，輸出裡也有：`kernel: 10 switches up+enabled`、`data plane: h1 -> 10.0.0.2 forwards`（真的送了封包）、`sFlow: 10/10 bridges sampling`（`api/up.stdout`）。
- 夾帶的三個探針結果：沒帶 token 回 403、外來 Host 回 403、`up` 執行中的第二個寫入回 409。三個都沒有改變任何東西。

### 5.3 raw 一覽（`LOGS/live-20260924T2201/`）

| 檔案 | 內容 |
|---|---|
| `api/NN-*.http` | 每一個請求和回應的全文（token 已遮蔽） |
| `api/<step>.stdout` 與 `.stderr` | 每個 job 透過 API 取回的原始輸出 |
| `api/summary.json` | 每一步的摘要 |
| `direct/NN-*.stdout`、`.stderr` 與 `summary.tsv` | 對照組 |
| `direct/run_direct.sh` | 對照組的腳本 |
| `after-fix/` | 修正後重驗的 status |
| `serve*.out`、`serve*.err` | 伺服器自己的 log |
