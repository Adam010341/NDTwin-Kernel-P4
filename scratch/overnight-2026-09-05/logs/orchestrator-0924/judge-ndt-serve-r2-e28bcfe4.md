<!-- opus-judge a7fa9c5b0f0db265e second pass on feat/ndt-serve-0924 e4589399..e28bcfe4; extracted verbatim by orchestrator-0924 2026-09-24 -->

# ndt serve 第二輪審查：`e4589399..e28bcfe4`

## 裁定：READY AFTER FIXES

第一份報告的 9 項都已修好，證據也對得上。只看第一刀加修正輪，可以直接交給 Adam。

擋住這次的是 cells 的新碼，有兩件事：
- 直接 `run` 一個需要 lab 的格子時，沒有 claim 前置條件。加上 ndt 的 OVS 缺陷，這條路能在別人的 claim 底下建 fabric，而且之後還原不掉。
- 其中一格會改寫 `host_count_override`，報告沒寫。

這兩件再加上報告裡幾條不實或分錯的宣稱，修好就能交。

這次我只讀碼和 raw，沒有執行任何東西，也沒有用 git。所以 `e28bcfe4` 上受測檔的雜湊是否等於 `final-5c07acf3/sha256.txt`，我無法驗證，併入前要用 `sha256sum` 對一次。

檔案位置：
- 程式與報告：`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-0924/`
- raw：`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ndt-serve-0924/`（子目錄 `final-5c07acf3/`、`live-fixes-20260924T2249/`、`live-cells-20260924T2224/`，以及 `fixes-red-037e915f.log`）
- 格子腳本：`/home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/live_cells/`

## 一、第一份報告逐項

| # | 項目 | 狀態 | 證據 |
|---|---|---|---|
| 1 | `GET ?check=1` 有副作用、不需要 token | FIXED | 見表下說明 |
| 2 | 既有變異閘門、錨點、head | FIXED，附但書 | honesty 67 條 0 倖存；manual_rc_table 10 條 0 倖存，對照組照規定倖存。兩者驗的 ndt sha 都是 `c98f8f26`，等於 `sha256.txt:7`。錨點在 5c07acf3 和 e28bcfe4 都是 116/116。但書：`check_gate_anchors.at-e28bcfe4.log` 沒有 head／時間檔頭；e28bcfe4 的雜湊沒有對過 |
| 3 | demo 的 busy 探針 | FIXED | `demo_sequence.py:138` 改成不帶 token 的 `GET /health`；M60 抓到；`b/10` 的 busy 指向那個 up job |
| 4 | 讀取輸出不是逐位元組 | FIXED | `jobs.py:223` 新增 ReadLog（保留 500 筆），加上 `/reads/<id>/log/*`；M48 抓到 |
| 5 | rc 表出處、`status.check` rc 1 的句子 | FIXED | `verbs.py:241` 新增 RC_SOURCE，`RcProvenance` 拿真 ndt 對照。我抽查 19 個引用行號，全部吻合。M57–M59、M61 抓到。`cells.run` 表不在出處檢查範圍內 |
| 6 | symlink 漂移 | FIXED | `serve.py:157,441,641,656` 都改用 `ndt_real`；`/health` 回報 `ndt_drift`（`:346-358`）；M49 抓到 |
| 7 | 逾時路徑沒跑過、可能卡死 | FIXED（限 run_read） | `serve.py:171-187` 加了 PIPE_GRACE；舊碼實測卡 25 s（`fixes-red:235`）；M50–M52 抓到。同樣的形狀還留在 cells.py（新發現 4） |
| 8 | 四個會倖存的變異 | FIXED | M53–M56 抓到（`final mutate_ndt_serve.log:59-62`） |
| 9 | 資訊類四項 | 依裁定列為限制 | REPORT §4.4 |
| — | 第一份的證據缺口 | FIXED 或已降級 | `01-listen-and-token.txt`；`99-after.txt` 的 token grep 為 0；26、23、全樹 meta-gate 都有 log；第一輪無存檔的項目已標 UNDER-EVIDENCED |
| — | 建議的 live 非零 rc | PARTIAL | rc 2（`a/`）和 rc 5（P4，`a2/`）用真 ndt 釘到；rc 3 沒釘到，原因是 stale 的 `app_viz.pid`，報告有寫 |

第 1 項的碼上確認：
- `serve.py:272-273`：除了 `r_health`，所有 GET 都先過 `_check_read`（token 加 Origin）。
- `r_health` 不起任何子程序。HEAD／OPTIONS 沒有路由，回 405。
- cells 的 GET 只會跑兩種東西：
  - `run_cells.sh --list`，它對每格跑 `meta`，而 `meta` 只是 printf（`_cell_lib.sh:148`）；
  - `<cell>.sh judge <fixture>`。11 格裡所有 ndt／curl／sudo 呼叫都在 `cell_observe` 或只被 observe 呼叫的 helper 裡，`cell_judge` 裡一個都沒有。
- 所以任何 GET 都跑不到 `status --check`。它只剩兩條路：token 門後的 `?check=1`，以及 POST job。後者包括 stale_app 格 observe 的 `:168`，和 run_cells 還原時的 `apps orphans` lock 探針。
- 證據：M43–M47 抓到；live `b/14` 回 403，`b/15` 回 200 且輸出寫著「locks WERE checked」。

## 二、新發現（依嚴重度）

**1.【中】直接 `POST /cells/<需 lab 的格>/run` 沒有 claim 前置條件，加上 OVS 缺陷，會在別人的 claim 下建 fabric，而且還原不掉**
- 路徑：
  - `serve.py:493-504` 只檢查 token 和槽位；
  - `run_cells.sh:213-234` 沒有任何 claim 檢查；
  - 例如 `up_target_names_a_readable_model.sh:39` 跑 `ndt up ovs 4`，而 up_ovs 不擋別人的 claim；
  - 還原時的 `ndt down` 在別人的 claim 下回 5（`ndt:4564`），於是 run_cells 報 RESTORE-FAIL（`run_cells.sh:163`），job 回 rc 2 `harness`。
- 情境：orch 持有 lab、fabric 正好在兩臂之間 down 著，這時 Adam 在 GUI 按某個 ovs4 格子的 run。fabric 會在 orch 的 claim 下建起來，還原被擋，fabric 就留在那裡。
- walk 不受影響：它的 claim 步驟在 lab 被別人持有時回 rc 1 並停住（C10）。README 只寫了「Claim first」。REPORT-cells 是在缺陷被發現之前寫的，REPORT §2 也沒有把兩者連起來。
- 建議（保守）：需要 lab 的格子只准走 walk；或者 run 之前讀 `ndt status` 的 claim 行，必須是 `yours`。這是讀 ndt 的輸出，不算重寫 ndt 的邏輯。要配一個具名變異。

**2.【中低】`up_refuses_a_model_of_another_network` 會改寫 `host_count_override`，報告沒寫**
- 這格的 observe（該檔 `:61-80`）先把 knob 寫成 128 當作前提，再跑 `NDT_TOPO=<128 模型> ndt up p4 4`，最後逐位元組寫回原值。所以透過 API（run 或 walk）跑它，就會碰到工單 §2 明說「不要碰」的那個檔。
- 情境：observe 在 `:64` 到 `:79` 之間被外力殺掉（這台的 systemd-oomd 就會）。knob 停在 128，下一次 `ndt up p4` 會建 128 台；walk 的 release 也會因為 knob 變了被 ndt 拒絕（`ndt:885-895`）。
- REPORT-cells §1 第 3 題只說「有沒有副作用只讀過碼」，沒有點名這個寫入。建議寫進報告和這格的 look_at，或者 API 對這一格要求明確確認。

**3.【低】walk 的 claim／release 以 owner 為單位，不是以 walk 為單位**
- `serve.py:640-642,655-656`：claim 步驟跑 `ndt claim 30`，同一個 owner 會覆寫既有的 claim 並重記 round baseline；release 步驟跑 `ndt release`。
- 情境：
  - Adam 本來就 claim 著在做事，這時開一條 walk。walk 結束時會把他原本的 claim 一起放掉。
  - 兩個分頁各開一條需要 lab 的 walk。A 跑完 release 之後，B 的 run 步驟不會重新確認 claim，會在沒有 claim 的情況下驅動 lab。
- 另外，`status` 步驟的判定是 `ok = rc == 0`（`:639`），但 plain status 恆回 0（`ndt:6497`），所以這一步永遠不會擋。walk 真正的關卡只有 claim 步驟。

**4.【低】cells.py 沒有套用第 7 項的修正**
- `cells.py:108-111` 用 `subprocess.run(timeout=60)`。逾時時它只 kill 子程序本身（不是整個 group），然後無上限地等管線 EOF；也沒有 READ_SLOTS；`TimeoutExpired` 沒有被接住，會變成 500。
- 情境：某個 `meta` 或 `judge` 卡住，handler 就一直掛著，佔住一個連線名額。風險低，但做法跟 run_read 不一致。
- 連帶影響：REPORT §4.3 第 6 列寫「整個服務唯一送訊號的地方是 killpg」，現在不成立了。對象仍是自己的 pid，所以紅線 6 沒破，但這句宣稱是錯的；AST 測試也看不到這種隱式的 kill。

**5.【低｜證據】紅燈的兩類分法有錯也有漏（對照 `fixes-red-037e915f.log`）**
- 新增的 20 條測試在舊碼上：15 條紅，其中 8 條是有意義的紅、7 條是舊碼不認得新介面；另外 5 條在舊碼上本來就綠。
- 分錯：
  - M45 被歸成「不認得新參數」，但舊碼的紅是 `404 != 400`（`:188-194`）。舊碼的上限是 600，301 被接受——這是行為上的紅，也就是有意義的紅。
  - M48 被寫成「有意義的紅」，但舊碼的紅是 `KeyError: 'read'`（`:133-140`），也就是缺新欄位，跟「不認得新參數」同一類。
- 沒有歸類：
  - M52：舊碼不認得 `--read-queue-wait`（不認得新參數類）；
  - M57、M58、M61：三條都是 `AttributeError: RC_SOURCE`（不認得新介面類）；
  - M59、M60：有意義的紅；
  - M53、M56：舊碼上是綠，紅燈只來自變異。

**6.【低｜證據】零星不準**
- REPORT-cells 說還原時「網路那一半沒查，是 run_cells 的設計」。實際上 `2-verdict-predown.txt` 有讀到 `network=0/0/0`、`stack=whole-up`，只是 flow table 是空的，沒有鑑別力；而 run_cells 的設計本來就是在 down 之前先問網路那一半。
- REPORT-cells 第 13 行寫「第一刀審查停在 f023b388」，跟 REPORT 第 6 行的 `e4589399` 矛盾。
- REPORT §5.4 說「22:49:21 存在 00-before.txt」，但檔頭時間是 22:49:18。
- 時間軸裡「22:50:41 直接查 status」沒有存檔；有存檔的是 22:50:39 經 API 的那一次（`a-cleanup/13`），內容一致。
- `up_ovs` 實際在 4318 才結束，報告寫 4313。
- cells 的 live 是在 GET 加 token 之前跑的（`walk.py` 的 GET 不帶 token），所以 cells GET 的 token 閘門只有單元測試的證據。

**7.【資訊，給 ndt 修正單】**
- up_ovs 其實看見了別人的 claim，只警告就照建：`a/up-under-a-foreign-claim.stdout:5-9` 有「the live claim belongs to ndt-serve-0924-foreign」，出自 `claim_note_up`（`ndt:4146`）。
- `release` 用的是 `mv`（`ndt:915`），而 rename 會保留 mtime，所以「superseded」顯示的是那張 claim 的寫入時間，不是 release 的時間。例如 `a/23` 在 22:49:55 顯示「superseded 22:49:45」。報告的時間軸用的是 driver 的序列，這是對的。

## 三、cells／引導模式，照紅線逐條
- **本機與 token**：成立。cells、guided、reads 的 GET 都在 `_check_read` 之後；所有 POST 第一行都是 `_check_write`（`:494,596,602,659,678`）。C6 抓到。
- **cell id 與路徑穿越**：成立。名稱要符合 `cells.py:34` 的格式，而且必須出現在 `--list` 裡（`:134-141`）；`old|new` 由路由列舉；`safe_file` 用 realpath 加 commonpath，並拒絕絕對路徑和 NUL（`:201-209`）。C1、C3 抓到。
- **argv、shell、sudo**：成立。全部用 argv list（`:170-172`）；服務碼沒有 sudo；格子自己的 `sudo -n tc` 用的是既有授權。
- **薄殼與 rc**：成立。`rc` 是 run_cells.sh 的原值；rc 0 再依 `CELL:` 行分成 pass／skip，1 是 fail，2 是 harness（`serve.py:506-515`）。C5、C8 抓到。
- **共用 job 槽**：成立。`_spawn_cell_run` 走 `_spawn`。C4 抓到。
- **run 之後就放掉 lab、verdict 留給 Adam**：成立。`guided_steps` 的順序是 run → release → compare → verdict（`cells.py:258-262`）；`next` 走到 verdict 會回 409 `yours`；還原失敗時不會 release（`_step_ok`）。C11、C13、C16 抓到。
- **共用狀態**：唯一 live 走完的 ovs4 格，前後 knob 都是 4、claim 是 none（`99-after.txt`）。風險在另外兩處：直接 run 需要 lab 的格子（新發現 1），以及未跑過的 H4 格會寫 knob（新發現 2）。
- **「11 格 old 全 FAIL、失敗集合＝EXPECTED-FAILS；new 全 PASS」**：SUPPORTED。11 個 `-old.json` 都是 FAIL、rc 1、`failing_matches_expected: true`，`ok:false` 的條數是 7、1、8、8、3、12、7、4、6、6、5，和表一致；11 個 `-new.json` 都是 PASS、rc 0。報告也自己註明這是「重判存檔」，不是今天重跑。

## 四、OVS 缺陷的時間軸（第 3 題）
- **raw 和報告一致。**
  - up job 從 22:49:46.4 開始，22:49:54.85 結束，rc 0（`a/20`）。
  - 22:49:55 的 `a/23`：claim none，但 topo present、15 個 host/switch。
  - 22:50:24 cleanup 先 claim 再 down，15.04 s 後完成，約 22:50:39。
- **換算：**
  - fabric 存活約 53 秒；
  - 其中約 29 秒（22:49:55 到 22:50:24）沒有任何人持有 claim；
  - 在外人的 claim 底下約 9 秒。
- **讀碼一致：**
  - `foreign_claim` 只出現在 `ndt:3057`（up_p4）、`4564`（down）和 claim／release；
  - `in_flight` 只出現在 `3063`、`4630`、`6191`、`6559`；
  - 兩者都不在 up_ovs（`4047-4318`）裡。
- **報告沒有把它寫成 ndt serve 的缺陷**（REPORT §2 標題、§4.4）。
- **少寫了三處：**
  - cells 的直接 run 會受影響（新發現 1）；
  - ndt 其實偵測到了別人的 claim，只是繼續往下建（新發現 7）；
  - §1 第 7 題只提到 claim，但「量測進行中」同樣沒擋。這點 §2 的「原因」那一行有寫。

## 五、報告宣稱判定

| 宣稱 | 判定 | 依據 |
|---|---|---|
| §3 的 71/71、25/25、77/0、錨點 116/116、26/23/345、全樹 meta-gate | SUPPORTED | `final-5c07acf3/*.log` 的結尾行和 §4.7 逐字相符 |
| 既有變異閘門沿用 d02689aa 的 log | SUPPORTED | ndt sha 在兩個 head 上相同 |
| 程式碼 head 是 5c07acf3（交件的是 e28bcfe4） | UNDER-EVIDENCED | 雜湊沒有對過 |
| §2 判官第 1–6 項都已修 | SUPPORTED | 見第一節表格 |
| §2 OVS 缺陷的現象、原因、時間軸、53／29／9 秒 | SUPPORTED | `a/18-23`、`a-cleanup/`、ndt 原始碼 |
| §2 rc 5 在 P4 平面釘到、knob 不變 | SUPPORTED | `a2/summary.json` rc 5；stderr；前後 knob diff 相同 |
| §2 rc 3 沒釘到（stale app_viz.pid） | SUPPORTED | `a/down-on-a-down-lab.stdout:3` |
| 時間軸「22:50:41 直接查 status」 | UNDER-EVIDENCED | 沒有存檔；22:50:39 的 API 那次內容一致 |
| §4.3 各列紅燈的舊碼分類 | CONTRADICTED（部分） | 新發現 5 |
| §4.3「唯一送訊號的地方是 killpg」 | CONTRADICTED | `cells.py:109-110` |
| §4.3 live 欄（ss、stat、grep 0、`b/10`、`b/14-15`） | SUPPORTED | `01-listen-and-token.txt`、`99-after.txt:12-13` |
| §5.4「22:49:21 存在 00-before.txt」 | CONTRADICTED（小） | 檔頭是 22:49:18 |
| REPORT-cells 的 11 格表 | SUPPORTED | `offline/*.json` |
| 兩條 walk 分別 4、8 條紅轉綠，still_red 為空，CELL: PASS | SUPPORTED | `walk-*.log`、`judge.txt` |
| 還原：down 0、clean 0、orphans CLEAN | SUPPORTED | `3-down.rc`、`4-clean.rc`、`6-verdict-postclean.txt` |
| 「網路那一半沒查，是 run_cells 的設計」 | CONTRADICTED | `2-verdict-predown.txt` |
| lab 佔用約 30 秒，結束後 claim none、knob 4 | SUPPORTED | `serve.err`、`99-after.txt` |
| 「開跑前 claim none、measuring nothing」 | SUPPORTED（弱） | 只在 walk 的 status 步驟（`08-GET:236`），`00-before.txt` 裡沒有 |
| 58/0 與 116 ok（在 940c1233） | SUPPORTED | 兩份 940c1233 的 log |
| C16「新測試先在 727d4b00 上跑出紅」 | UNDER-EVIDENCED | 沒有那次紅的 raw；C16 在 final 閘門被抓到，可視為等價證據 |
| 「22 次判定，lab 的 claim 沒被動到」 | UNDER-EVIDENCED | 那 22 次前後沒有 claim 讀數；讀碼支持 |
| idle 兩格「副作用只讀過碼」 | UNDER-EVIDENCED（漏寫） | 沒點名 knob 寫入 |
| 「第一刀審查停在 f023b388」 | CONTRADICTED | REPORT:6 寫的是 `e4589399` |

**併入前必修：**
1. 新發現 1：擋住直接 run 需要 lab 的格子，或要求 claim 是 `yours`，並配具名變異。
2. 新發現 2：揭露 H4 格會改寫 knob，或要求明確確認。
3. 更正第五節裡判定為 CONTRADICTED 的宣稱。
4. 在 `e28bcfe4` 上對 `sha256.txt` 核對雜湊。

新發現 3、4 可以排進下一刀。
