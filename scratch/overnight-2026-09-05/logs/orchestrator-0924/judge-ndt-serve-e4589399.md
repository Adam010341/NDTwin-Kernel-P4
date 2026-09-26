<!-- opus-judge a7fa9c5b0f0db265e on feat/ndt-serve-0924 @ e4589399; extracted verbatim from the agent transcript by orchestrator-0924 2026-09-24 -->

# ndt serve 第一刀：證據審查（`feat/ndt-serve-0924`，head `e4589399`）

**裁定：READY AFTER FIXES**

這次審查我只讀了程式碼和 raw，沒有執行任何東西，也沒有用 git。

核心設計站得住：只綁 127.0.0.1、有 Host 檢查、寫入必帶 token、argv 走白名單、rc 原樣回傳且 5 不會被蓋掉、單一槽加落地 job、全程不用 pkill。擋住併入的有三件事：
- **紅線 2 被打破。** `GET /status?check=1` 會讓 ndt 對 kernel 發 POST，而這個 GET 不需要 token。
- **工單 §3.8 還沒有證據。** 工單要求「既有變異閘門維持綠」，目前拿不出來。
- **幾條「跑過」的宣稱在 raw 裡找不到。**

路徑：
- 程式與報告在 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-0924/`：`tools/ndt_serve/{serve,verbs,jobs,runner,demo_sequence}.py`、`tools/test_workflow/ndt`、`tests/python/test_ndt_serve.py`、`doc/audit/2026-09-24_ndt-serve/REPORT.md`
- raw 在 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ndt-serve-0924/`，live 部分在其下的 `live-20260924T2201/`
- 對照用的主 checkout：`/home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt`

## 發現（依嚴重度）

**1.【中｜紅線 2 違反】`GET /api/v1/status?check=1` 有副作用，而且不需要 token**
- **路徑：**
  - serve.py:305-307 把 `check=1` 接到 `ndt status --check`。GET 只過 `_check_host`（serve.py:231），不過 `_check_write`。
  - ndt:6429-6432 → `status_residue_row` → kernel 開著時 → ndt:9240-9241 連打三次 `lock_probe` → ndt:8846-8847 `POST /ndt/acquire_lock {"ttl":0}`。
  - ndt 自己在 ndt:8832-8843 寫明「There is no read-only way to ask … it is still a POST … Its one side effect: … reclaims that dead lease」。
- **失敗情境：**
  - lab up 時，Adam 瀏覽器裡任何一個分頁反覆載入 `<img src="http://127.0.0.1:8765/api/v1/status?check=1">`。瀏覽器送的 Host 就是 `127.0.0.1:8765`，Host 檢查放行；GET 不查 token、不查 Origin。
  - 每載入一次，就對 kernel 發三個 acquire POST、讀一次 flow table，並用 adam 的帳號跑 `sudo -n` 探針（sudo_surface.sh:172-183）。
  - 攻擊者讀不到回應，但副作用已經發生，而且可能正好落在別人的量測窗裡。
- **測試為什麼沒抓到：**
  - test_ndt_serve.py:368-376 只驗 GET 叫了哪幾個 argv，沒驗那些 argv 本身有沒有副作用。
  - live 也沒踩到：修正後那次 `--check` 跑的時候 kernel 是關的（after-fix/status-check.json：`:8000 is closed`）。
- **建議修法（保守）：** `check=1` 必須帶 `X-NDT-Token`；或除了 `/health` 以外所有 GET 都要 token，順便擋掉盲打 GET 的 DoS（`?wait=600` 會綁住執行緒，而執行緒數沒有上限）。要配測試和具名變異。

**2.【中｜證據】工單 §3.8「既有變異閘門維持綠」沒有證據，錨點「116 ok」也沒有 raw**
- **錨點：** check_gate_anchors.d02689aa.log:6-8 只有 `mutate_ndt_serve.sh ok(40)`、`1/1 cells ok`，對應不到 REPORT.md:48 的「其他 115 支…也都 ok」。
  - ok(40) 對 42 個變異不是矛盾：M2/M3/M4 共用同一個錨點。
- **mutate_ndt_honesty：** d02689aa 的 log 有基線 345 綠、50 行 caught，但沒有結尾的總數行，也就是還沒跑完。報告說有「67 個」變異，無從核對。
- **mutate_manual_rc_table：** 完全沒有 log。
- **失敗情境：** 依「116 ok」併進去，但某支既有閘門其實被這 +11 行弄成 NOAPPLY。
  - 我讀碼查過：新增的字串在 base ndt 裡都不存在，插入點附近也沒有任何閘門的錨點，風險低。但這是讀出來的，不是跑出來的。
- **head 對不上：** 報告沒有寫出自己的 head（REPORT.md:54）。所有閘門證據都是 d02689aa 的；需要確認 e4589399 上五個受測檔的 sha256 和 mutate_ndt_serve.d02689aa.log:48-52 一致。

**3.【中低】demo driver 的「無害」探針其實是一個帶 token 的真 `POST /down`**
- demo_sequence.py:9-11 寫「none of which can change anything」，但 :126-130 的 busy 探針帶的是有效 token。
- **失敗情境：** `up` 秒退（例如 rc 1「a Mininet already running」）時，槽已經空了，探針就變成在自己 claim 底下的一次真 `ndt down`，ndt 的 guard 不會擋。
- 這次沒出事，只是因為 up 跑了 9.5 s。這支檔會跟著併進去。

**4.【低｜薄殼】唯讀呼叫的輸出不是逐位元組，也沒有保留**
- serve.py:166-167 用 `decode("utf-8","replace")` 塞進 JSON，而且不落地。工單 §3.4 要求「stdout 和 stderr 全文保留、可以查詢」。
- 報告說的「300 KB 逐位元組」只驗到 job log（test_ndt_serve.py:519-530）。
- **失敗情境：** ndt 用 `cut -c1-72` 按位元組截 claim note（ndt:5207，另外 6189、6204 也有）。中文 note 被切在多位元組字元中間，API 回傳 U+FFFD，而且事後查不回原文。

**5.【低】rc 表的出處宣稱有一部分不實，`status.check` rc 1 的句子太窄**
- **出處：** verbs.py:15-18、README.md:70-71、REPORT.md:127 都說 rc 表抄自 `ndt help`。但 help 裡沒有 claim／release／apps start／apps stop／apps status 的 rc（ndt:10309-10341），這五張表是從程式碼讀來的。
- **rc 1 的句子：** verbs.py:185 寫「a compared field does not match」。實際上 cmd_status 只要 `problems[]` 非空就回 1（ndt:6493-6495），原因可能是別人持有 claim（6128）、量測進行中（6211）、netem（6355）、sudo 被拒（6368）。
- **失敗情境：** GUI 顯示「欄位不符」，實際原因卻是 lab 被別人 claim 走。

**6.【低】symlink 被改指時，job 的出處紀錄會說謊**
- serve.py:371-373 執行的是 `cfg.ndt`（symlink 路徑），記錄的卻是啟動時 `cfg.ndt_real` 的 sha；cwd 和 app 清單也都在啟動時定死（:443-444）。
- **失敗情境：** 伺服器跑著時，有人把 `~/.local/bin/ndt` 改指到某個 worktree。之後的 job 跑的是 worktree 的 ndt，紀錄卻寫主 checkout 的 sha。
- **建議：** 改成直接 exec `cfg.ndt_real`。

**7.【低｜未測】讀取逾時的路徑從沒被執行過，而且可能卡死**
- serve.py:149-159。M33 和 test_ndt_serve.py:678-688 都只是靜態檢查。
- **失敗情境：** `killpg` 之後 `communicate()` 會等管線 EOF。如果有以 root 身分跑的 `sudo -n` 子程序還握著管線，這條 handler 就永遠卡住，READ_SLOTS 那一格也放不掉。兩次之後，所有 GET status 都要等 30 s 然後回 503。
- 報告 §4.4 說「超過就回 503」，實際上是先等 30 s 才回（serve.py:141）。

**8.【低｜變異覆蓋缺口】42 個變異都是真的，但以下變異會倖存**
下面四處的程式本身都正確，缺的是「看過紅」：
- 拿掉 `with SLOT:`（serve.py:367）：沒有並發測試，:562-570 是依序打的。
- 拿掉 `os.chmod(d,0o700)`（serve.py:103）：只測了全新目錄的情況。
- 把 `commonpath` 換成 `startswith`（verbs.py:95）：沒有 `packages2` 這類前綴相同的兄弟目錄案例。
- 拿掉 zombie 排除（jobs.py:51）。

**9.【資訊】**
- absolute-form 請求目標會照 path 路由（serve.py:232）。瀏覽器送不出這種請求，不構成繞過。
- 405 回應的 `Allow` 寫死成 `GET, POST`（serve.py:239）。
- 用不同 `--state-dir` 起的兩個伺服器各有一個槽，互相看不到。
- runner.py:78-88：「ndt 已經起來、runner.json 還沒寫」的窗口裡若 runner 被殺，job 會變成 `lost`，槽也就被放掉。
- raw 只放在被 ignore 的 scratch 裡。CLAUDE.md 規定 raw 進 audit-raw 不可協商，報告把它留成 §1 Q6，併入前要先有結論。

## 守住的紅線（一行一條）
- **綁定：** serve.py:52,457 寫死 127.0.0.1；M1 讀 /proc/net/tcp(6) 看過紅。
- **Host：** serve.py:246-251 精確比對、不分大小寫；缺 Host、重複、錯 port、`[::1]`、尾點都回 403。M2–M4 看過紅；live 04-probe 回 403。
- **不開 CORS：** 服務碼裡沒有 `Access-Control`；OPTIONS 回 405 且不帶 ACAO。M5 看過紅；整份 raw 0 命中。
- **寫入 token：** 每個 `w_*` 第一行就是 `_check_write`（serve.py:345-363），用 `hmac.compare_digest`（:256），並檢查 Origin 和 JSON。M6/M7/M10/M11 看過紅；7 個帶 token 的請求在 raw 裡都已遮蔽。
- **token 檔：** O_EXCL|O_NOFOLLOW＋fchmod 0600＋rename，目錄 chmod 0700 並驗 uid，bind 成功之後才寫（serve.py:98-130,460）。
- **白名單：** argv 只由 verbs.py 組成 list；未知欄位回 400，所以 `--deep`/`--force` 無路可達；app 名稱讀自 ndt 的 `APP_NAMES`；`--app` 走 realpath＋commonpath。M13–M21 看過紅。
- **不加 sudo：** 服務碼和 +11 行裡都沒有 sudo。
- **rc：** 原始整數原樣回傳，每個動詞一張表，表外的 rc 標 `unknown`，5 從未被折成一般失敗（verbs.py:212-222）。M22–M24 看過紅。
- **live 修正是對的：** plain `status` 在 ndt:6497 一律 `return 0`；`--check` 在 :6486、:6491、:6495 分別回 3/0/1。
- **Jobs：** 「查槽＋開 job」包在同一把 `SLOT` 鎖裡（serve.py:367-374）；`start` 回傳前 spawn.json 已經寫好；runner 和 ndt 各自一個 session；狀態由 (pid, starttime) 加 /proc 推導；同一個 state 目錄靠 flock 擋第二個實例。M26–M32、M40、M42 看過紅；live 10-probe 回 409。
- **不用 pkill：** 唯一送訊號的地方是 serve.py:156 對自己 Popen 出來的程序做 `killpg(p.pid)`。
- **NDT_OWNER：** 只在啟動時設一次（serve.py:88-95），沒有任何請求路徑碰得到 env。M34–M36 看過紅；live 顯示 `claim yours`。
- **ndt +11 行：** 只新增，沒改。一個 `serve)` 分派（ndt:10100-10105）加 5 行 help（:10342-10346）。
  - 和主 checkout 的 ndt:10092-10099、10333-10335 比對，既有動詞和它們的 help 一字未改。
  - heredoc 裡沒有反引號，也沒有 `$(`。
- **路由預留：** `/api/v1` 以外的路徑都回 404 並附說明（serve.py:234-235），M39 看過紅。
- **工單：** 分支裡的 TICKET.md 和 orchestrator 原件逐行一致。

## 報告宣稱對照
| 宣稱（出處） | 判定 | 依據／缺什麼 |
|---|---|---|
| 單元 51/51（REPORT:46） | SUPPORTED | 我在檔內數到 51 個 test；gate 基線為 `OK`（mutate log:2） |
| 變異 42/42、0 倖存、sha 不變（:47） | SUPPORTED（d02689aa） | log:4-54 每條都是具名案例變紅，且有未變異的基線對照；對 head e4589399 則 UNDER-EVIDENCED |
| 錨點：其他 115 支 ok（:48，摘要寫 116） | UNDER-EVIDENCED | raw 只有 1/1 格 |
| honesty 345/345（:49） | SUPPORTED | mutate_ndt_honesty log:2 |
| manual_rc_table 26/26、up_target 23/23「實跑」（:49） | UNDER-EVIDENCED | 沒有 log |
| 兩支既有變異閘門在 d02689aa 上實跑中（:50） | UNDER-EVIDENCED | honesty 沒跑完、「67」無從核對；manual_rc_table 沒有 log |
| check_process_by_name 全樹 0、tmpdirs 0（:51） | UNDER-EVIDENCED | 沒有 raw；單元測試只掃 5 個服務檔 |
| live 11 步 rc 全 0，與直打逐步一致（:52、§5.2） | SUPPORTED | summary.json、各 .http、direct/summary.tsv、關鍵行一致；其中 5 步的動詞本來就恆回 0（ndt:6497、9747），有鑑別力的只有 6 步 |
| host_count_override 前後都是 4（§5.1） | SUPPORTED | 00-before.txt:6-12、99-after.txt:2-8 |
| 「三次」git diff（:170） | UNDER-EVIDENCED | API 組之後那次沒有存檔 |
| 開跑前查過兩次 lab（:166） | UNDER-EVIDENCED | 只存了 02-status-before |
| ndt sha cb134ccc、HEAD fd7382a3（:167） | SUPPORTED | 00-before.txt:3-5、01-health |
| up 有 10 switches／forwards／sFlow 10/10（:188） | SUPPORTED | api/up.stdout:18-21 |
| 三個探針都沒改變任何東西（:189） | SUPPORTED（僅限本次） | 34-jobs 只有 6 個 job；探針設計本身不安全，見發現 3 |
| plain status 誤判，兩次在沒有 baseline 的 lab 上（§2） | SUPPORTED | 02／14／33 的第 21-22 行 |
| 修正後 plain→report、check→3（:35） | SUPPORTED | after-fix/*.json、serve2.err:1-2；serve2 的程式沒有 hash |
| 新測試先對上一顆 commit 跑紅（:35） | UNDER-EVIDENCED | 沒有那次紅的 raw；等價證據是 M41 看過紅（log:29） |
| 同秒建立的 job 排序錯（:37） | SUPPORTED | 34-jobs.http 裡 claim（:112）排在 up（:140）前面；M42 看過紅 |
| ugrep 讓 SIGTERM 沒送出（:38） | UNDER-EVIDENCED | 沒有 raw；serve.err:35-36 的時序與此相容 |
| live `ss` 只有 127.0.0.1（:112） | UNDER-EVIDENCED | 沒有 ss 輸出 |
| preflight 與「所有回應」都沒有 ACAO（:112） | SUPPORTED | 讀碼加 3 個抽樣；「所有回應」是讀碼推論，卻放在「跑過」欄 |
| live token 0600/0700、用 token grep raw 0 命中（:113） | UNDER-EVIDENCED | 沒有 stat／grep 輸出；「7 個請求已遮蔽」則 SUPPORTED |
| GET 只跑唯讀動詞（:65、README） | CONTRADICTED | ndt:8832-8847 |
| 紅線 3 單元／live argv（:114） | SUPPORTED | 測試、M13–M21、summary.json |
| 輸出全文保留（:115） | job 部分 SUPPORTED，GET 部分 CONTRADICTED | serve.py:166-167 |
| 重啟後列出前一個伺服器的 6 個 job（:116） | UNDER-EVIDENCED | serve2.err:3 只有請求紀錄，回應沒存 |
| 掃「四個」服務檔、唯一訊號是 killpg（:117） | SUPPORTED（靜態） | 實掃 5 個檔；逾時路徑在單元測試裡也沒跑過 |
| 紅線 7（:118） | SUPPORTED | 14-status-after-up.http |
| verb smoke：sha c98f8f26、SIGTERM 能停（:119） | SUPPORTED | smoke 檔 :3、:7；沒有記下啟動指令 |
| rc 表抄自 `ndt help`（:127） | CONTRADICTED（部分） | 見發現 5 |
| 超過兩個唯讀呼叫就回 503（:128） | UNDER-EVIDENCED | 實際先等 30 s，而且沒有測試 |
| 40 條 rules-in-window 是 fabric 自己的規則（:151） | SUPPORTED | nsr-stop.stderr：10 個 dpid × 4 個 nw_dst，兩組都是 40 |

## 報告內部的數字不一致
- 錨點：報告寫 115／116，raw 是 1/1。
- 報告說掃「四個服務檔」，實際掃了 5 個。
- 報告說 git diff 看了「三次」、開跑前查了「兩次」，但存檔各少一份。
- 報告說 rc 表抄自 help，但 help 只涵蓋其中幾個動詞。
- honesty 閘門：報告說「67 個」變異；log 只有 50 行、沒有結尾；檔內 `report "M…` 只出現 39 處。
- 報告說超過就「回 503」，程式實際先等 30 s。
- 時間範圍：報告開頭寫 live 在 22:01–22:05，§5.1 寫到 22:03:26。
  - 差額是之後的修正後重驗。
  - 其中 22:04:54-55 那兩次是舊伺服器回的（serve.err:35-36），沒有存檔，報告也沒提。

## 我會跑、報告沒跑的測試
1. **live 上的非零 rc（不需要建任何東西）：**
   - 用另一個 owner 先 claim，再 `POST /up`，預期 rc 5 `refused`；
   - lab 已經 down 時 `POST /down`，預期 rc 3；
   - nsr 沒在跑時 `POST /apps/nsr/stop`，預期 rc 2。
   
   這樣能把每個動詞的 rc 表釘在真 ndt 上，stub 做不到這件事。
2. **lab up 時打 `GET /status?check=1`：** 確認 acquire 探針真的發生；修好之後補「沒帶 token 的 check=1 被拒」的測試和變異。
3. **並發 `POST /up`：** 20 條同時打，應該恰好一個 202；再加一個「拿掉 `with SLOT:`」的變異。
4. **token 目錄：** 預先建一個 0777 的目錄、一個 0644 的舊 token、umask 設 000，啟動後應該分別是 0700 和 0600。
5. **`--app` 前綴：** `packages2/x` 應該回 400。
6. **Host 變體：** `[::1]`、`localhost.`、兩個 Host 標頭、absolute-form 請求目標，把結果記下來。
7. **逾時路徑：** 設 `--read-timeout 1` 並讓 stub 睡過頭，應回 `timeout`、process group 消失、READ_SLOT 放回；另外補一個 503 的案例。
8. **既有閘門：** 在 e4589399 上跑完整的 `check_gate_anchors`、兩支既有 mutate、manual_rc_table、up_target，log 全部存檔，並核對五個檔的 sha256。
9. **補存 live 證據：** `ss -ltnp`、token 的 `stat`、用 token grep raw 的結果、serve2 的 `/jobs` 回應、兩組之間的那次 `git diff`。
10. **重跑 demo：** 修好 demo 探針後重跑；併入之後，再用 `ndt serve` 動詞驅動一次真 lab。

## 我無法驗證的
- 有沒有推遠端、commit 是否逐檔列出、第一個 commit 是否是工單：這些都需要 git，本次禁用。
- §4.6 說 Adam 已裁定「live_cells 接著做在同一條分支」：沒有任何 artifact 可查。如果屬實，審查應該釘在 `e4589399`。
