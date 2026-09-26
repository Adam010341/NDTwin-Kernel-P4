# ndt serve 併入審查：post-r2（`e28bcfe4..1a1944ea`），併入樹 `48209682`

（opus-judge 最後回覆，orchestrator 2026-09-26 存檔；內容照交件。orchestrator 附註：finding 1〔blocking〕已由 orchestrator 以
逐 commit 掃描處理——`secret-scan.NDTSERVE-per-commit.log`：18 個非 merge commit，憑證樣式每個都帶 3/3 對照組、隱私樣式另有 3/3
對照組，全部 0 命中；1027e53a 為併入 trunk 68ace017 的 merge，內容已公開。）

## 裁定：MERGE AFTER FIXES

- 碼可以併。r2 的新發現 1、2、4 已關閉。3 的後半已關閉，前半依 r2 的許可延到下一刀，README 有揭露。
- 19 個 `RC_SOURCE` 錨點我在合併後的 ndt 逐條讀過。每條都落在對的函式、對的敘述上，rc 的意思也對。已知陷阱 8315 也確認了。
- 併入樹的 ndt 相對 trunk 只多 11 行 serve。這一點是推論，理由在第四節。
- 兩組 log 我全部判讀了：peer 在 `1a1944ea` 跑的一組，orchestrator 在 `48209682` 跑的 9 支。每支都以 `rc=0` 收尾，沒有一支是還沒跑完、無法判讀的。7 個受測檔的 sha256 在兩個 head 上完全相同，ndt 都是 `7ecd2f12…`。
- **唯一的 blocking 是推之前的公開性檢查**：secret-scan 只掃了 tree diff，沒有逐 commit 掃分支歷史。其餘 12 條都是 note，其中第 2、4、5 條建議併入前順手修。

方法限制：全程唯讀，沒有執行任何東西，也沒有用 git。trunk 的 ndt 是拿主 checkout 的工作樹代替的，這是未提交的觀測；session 開頭的 git status 沒有把它列為 modified。REPORT／REPORT-cells 只做定點 grep 或讀指定行，目的是核對 r2 必修 3 和公開性，沒有通讀。

---

## 一、r2 新發現 1–4 是否由 8f2fbb5b 關閉

| r2 | 問題 | 現況 | 判定 | 證據 |
|---|---|---|---|---|
| 1 | 直接 run 需要 lab 的格子，沒有 claim 前置 | `_spawn_cell_run` 把 `_require_own_claim` 當 precheck 交給 `_spawn`（serve.py:508-530）。它在 `with SLOT:` 內、busy 檢查之後，讀 `ndt status` 的 claim 行；不是 `yours` 就回 409 `claim` | **關閉**，但書見第 2、5 條 | C17、C18 在兩次閘門都是 caught。r2-red log:50-57 顯示舊碼的結果是 `KeyError: 'error'`，也就是沒擋下來，直接回了 job |
| 2 | H4 會改寫 knob，報告沒寫 | `WRITES_SHARED_STATE`（cells.py:44-57）；`/cells` 多了 `writes_shared_state`；run 和 guided 都要帶 `{"confirm_shared_state_write": true}`，否則 400；run 步的 look_at 會點名；REPORT-cells:34-36 已揭露 | **關閉** | C20、C21、C22 caught；SharedStateRegistry 拿真 grid 對照 |
| 3 | walk 以 owner 為單位；B 的 run 不重查 claim | 後半：run 步在槽位內重讀 claim，被拒就 blocked（serve.py:674-684）。前半延後，README:113-114 有寫。status 步仍然恆為 ok | **部分關閉**（r2 允許延後） | C19 caught |
| 4 | cells.py 用 `subprocess.run(timeout=60)` | 改成 Popen、`os.killpg(p.pid, SIGKILL)`、PIPE_GRACE，回 `(rc, out, err, timed_out)`（cells.py:125-152）。`--list` 逾時回 503，judge 逾時回 `timed_out: true`，逾時秒數等於 `--read-timeout` | **逾時部分關閉**；讀取併發上限仍然沒有 | C23 caught（舊碼等了 20.09 s，r2-red:92）；C24 caught |

r2 的「併入前必修」：第 3 項（更正 CONTRADICTED 的宣稱）抽查已更正——f023b388、「網路那一半沒查」、「唯一 killpg」改成「兩處」、M45/M48/M52/M57/M58/M61 的分類（REPORT.md:171-175，8+7+5=20）；還殘留一處：REPORT.md:283 的標題仍寫 22:49:21，但 :14 和 :286 已改成 22:49:18。第 4 項（核對 `e28bcfe4` 的雜湊）已被取代：`final-1a1944ea/sha256.txt` 和兩次閘門的「files under test unchanged」列出的 7 個 sha 完全一致。

## 二、第 1 題的四個具體問題

**(a) `_require_own_claim` 持有 SLOT 時跑 `ndt status`：可以接受。** 不會死鎖：唯一的巢狀順序是 `g.lock`（guided next）→ `SLOT` → `READ_SLOTS`；`run_read` 不拿 SLOT，`_spawn` 不拿 g.lock。代價是 `with SLOT:` 沒有逾時，precheck 期間所有寫入 handler 卡在這把鎖上、各佔一個連線名額：典型約 1 秒（09-24 walk 的 status `duration_s` 0.964），最壞約 100 秒（read-queue-wait 30 + read-timeout 60 + 2×PIPE_GRACE 5）。docstring「本服務的其他 job 動不了它」成立。小問題：`r is None` 的意思是「30 秒內拿不到讀取名額」，錯誤訊息卻寫「ndt status did not answer」。

**(b) `claim_of` 的 regex 與 ndt 的輸出：吻合。** ndt 全檔只有 ndt:6573 `printf '  %-14s %s\n' "claim" "$cl"` 印 claim 列；`^  claim\s+(.*?)\s*$` 取到的就是 `claim_line`（ndt:5664-5681）的值；`prev claim`、`override` 和縮排續行不會命中；09-24 真實輸出與測試 stub 格式一致。問題在判斷式：`startswith("yours")` 是前綴比對（第 2 條）。

**(c) grid 的逾時／killpg 路徑：正確。** 與 `run_read` 同形；不保留 partial output、沒有讀取名額上限。邊角：`run_argv → get → list` 逾時時的 `CellError` 沒經 `_cell` 轉換，會變 500。

**(d) guided 的 run 步只接住 `claim` 錯誤：可以接受。** 409 busy 與 400 confirm 直接往外丟，walk 不被 save，`next` 可重試、狀態不壞；只有 `claim` 記成 blocked 並寫原因。邊角見第 8 條。

## 三、19 個錨點（合併後的 ndt，逐條讀碼）

| kind | 行 | 所在函式／分支 | 那一行做什麼 | 對應 RC_TABLE 的意思 |
|---|---|---|---|---|
| status.check | 6939 / 6944 / 6948 | `cmd_status`（6548–6951）的 `--check` 分支 | `utrc==3` / problems 空 / problems 非空 | 3 沒比、0 ok、1 dirty ✓ |
| status | 6950 | `cmd_status` 最後一行，在 `--check` 分支外 | `return 0` | plain status 恆為 0 ✓ |
| claim | 753 / 762 | `cmd_claim`（748–772） | NDT_OWNER 空 / minutes 不合法 | 2 usage ✓ |
| claim | 787 / 860 / 862 | `claim_take`（774–863） | 外人 claim / readback 不符 / `ok "lab claimed by`（隱式 0） | 1、1、0 ✓ |
| release | 866 / 871 / 899 | `cmd_release`（865–946） | 沒有 claim / 外人 claim / knob 偏離 round baseline | 0、1、1 ✓ |
| apps.start | 8771 / 8775 / 8848 | `app_start`（8765–8850） | 已在跑 / pidfile-lost-but-alive / unknown app | 0、1、1 ✓ |
| apps.stop | 10289 / 10292 / 10295 | `cmd_apps`（10217–10356）的 `stop)` | `n_fail>0` / `n_stopped==0` / 其餘 | 1、2、0 ✓ |
| apps.status | 10222 | `cmd_apps` 的 `""\|status)` | `[[ $sub == status ]] && return 0` | 0 ✓ |

路由也對：`argv_app` 送 `apps <name>` → cmd_apps 的 `*)` → `app_start`；`apps stop <name>` 進 `stop)`。陷阱已確認：合併後 ndt:8315 是 `proc_checkout`（8252–8316）裡的 `return 1`。19/19 等於 NDT-OVS-SUMMARY §2 下半表，也和 renumber log 的函式對照表一致。**但 RcProvenance（test_ndt_serve.py:1050-1057）只驗 needle 和 rc 集合**：把 8775 改回 8315 這個變異會倖存；renumber log 的 RED 段只停在第一個失敗（6486），證明不了每個舊錨點都會紅（第 3 條）。

## 四、併入樹 ndt 的 11 行

位置：dispatch 10591–10596，help 10881–10885。「恰好 11 行」的依據（推論）：`diff-NDTSERVE-1a1944ea.full.patch:5416-5442` ndt 相對 base 只有兩個 hunk、合計 +11、無刪除；兩份 mutate log 在 `1a1944ea` 與 `48209682` 報的 ndt sha 都是 `7ecd2f12…`；主 checkout 的 trunk ndt 10904 行、合併後 10915 行；`ntg)` 在 10590、help 的 `release` 在 10874，與 patch 的 base 行號相同；抽查 12 個函式起始行兩邊相同；`Co-developed` 計數差 1。字面上的 `git diff 14554090 48209682 -- tools/test_workflow/ndt` 輸出沒有存檔。健全性：`HERE` 用 `readlink -f`（ndt:53）；`--ndt "$HERE/ndt"` 在 `"$@"` 前，argparse 取最後一個，註解屬實；ndt 無全域 trap，`exec` 不跳過收尾；heredoc 沒新增 `$` 或 backtick，test_ndt_up_target 23/0。help 文字不完整見第 7 條。

## 五、過期的註解

在合併後的 ndt 上**正確**：verbs.py:207-209 的 6946-6948、6576、6806、6819；verbs.py:249；serve.py:22 的 `ndt:9292-9307`；serve.py:521 與 test_ndt_serve_cells.py:101 的 `ndt:5664`；test_ndt_serve.py:418。NDT-OVS-SUMMARY.md:158 預告 verbs.py:207 與 :248-249 會過期——已在 `1a1944ea` 處理，那句預告本身現在過期。

**錯的：**
- `tools/ndt_serve/README.md:60` 寫 `(ndt:8832-8847)`，現在落在 `app_start` 的 `te)` 分支；應改 9292-9307。
- `serve.py:509-511`「ndt's OVS `up` does not refuse under a foreign claim」——合併後 up_ovs 在 ndt:4248 呼叫 `guard_up_lab_free`，help（ndt:10890）也寫兩個平面都回 rc 5。同一句也在 `test_ndt_serve_cells.py:277`。
- `serve.py:29-30`（紅線 6）與 `test_ndt_serve.py:931` 仍說只有一處送訊號，但 cells.py:139 現在也有 killpg；REPORT §4.3 第 6 列已改「兩處」，碼裡 docstring 沒跟。
- `verbs.py:208`「a declared measurement (6662)」——6662 是 `in_flight` 的程序掃描；`declared` 那列（6638-6640）不算 problem。行號對、標籤錯，先前就存在。
- REPORT.md 引用的 ndt 行號都是 09-24 版、沒標版本也沒提 68ace017（:47-48 的 3057/3063/4047–4318/10055/4146、:70 的 8832–8847、:111 的 6497）；§4.3 第 4 列還寫「OVS 平面的 rc 5 由 ndt 本身失約」。併進 trunk 後會和已修好的 ndt 放在一起，而 ndt:969 反過來引用這份 REPORT §2。

以上都不會導致有害操作；README:60 與 serve.py:510 最容易誤導讀者。

## 六、公開性

對最終樹的 13 個分支檔＋ndt 的 11 行做模式 grep，沒有私人資訊：IPv4 只有 127.0.0.1、0.0.0.0；`/home/`、email、`nslab|dorm_lab|tailscale|server[1-8]|cc2|gw`、MAC、`passw|secret|api_key|PRIVATE KEY`、40 字元以上 token 樣字串全部 0 命中；TICKET.md:44 提到的 `ndtwin-lab` NOPASSWD 在 ndt:55 本來就公開。orchestrator 的 secret-scan 有兩個缺口：它是 tree diff（`git diff --shortstat` 形狀，逐檔加總 14 檔 5348 行一致），沒有逐 commit 掃分支歷史，也沒列出 pattern。

## 七、宣稱判定

| 宣稱 | 判定 |
|---|---|
| 8f2fbb5b 讓 lab 格只在自己的 claim 下跑，且在槽位內重讀 | SUPPORTED（但書：前綴比對，第 2 條） |
| shared-state 格要確認；grid 呼叫比照 run_read 逾時 | SUPPORTED |
| listen backlog 64（490513fe） | 機制 SUPPORTED（M62、`ss`）；「1/10 會被 reset」在給我的證據裡沒有 raw |
| 1a1944ea 逐列重編；orchestrator 的三項自查 | SUPPORTED |
| ndt 的 diff 恰好是 11 行 serve | SUPPORTED（推論，第四節） |
| peer 在 1a1944ea 的結果：72/72、32/32、86/0、119/119、345/0、23/0、26/0、0、0、leftover 0 | SUPPORTED |
| orchestrator 在 48209682 的 9 支 log | SUPPORTED，全部可判讀 |
| secret-scan 0 命中、對照組 3/3 | 對 tree diff SUPPORTED；對 commit 歷史 **UNDER-EVIDENCED** |
| REPORT-cells §5.1「讀不到 → 409」 | **UNDER-EVIDENCED**：沒有測試，也沒有變異 |
| REPORT-cells §5.2「C17/C18 舊碼回 202」 | **UNDER-EVIDENCED**：raw 是 `KeyError: 'error'`，202 是推出來的 |
| serve.py:510、:29-30 和兩個 test docstring 的說法 | **CONTRADICTED**（第五節） |
| 兩條綠 walk 作為 post-r2 碼的 live 證據 | **UNTESTED**（第八節） |

## 八、兩條 walk 與 cell 2

綠 verdict 本身有證據：兩筆都是 green（09-26 08:01:39、08:03:08 +08，早於 orchestrator 08:06 的 rerun）；note「4 red->green」「8 red->green」與各自 compare 一致；兩次 run 都是 `ndt=3273df8b`、kernel `be70b5dd…`、09-24 22:25。**但兩條 walk 是 8f2fbb5b 之前的服務碼建的**，claim 重讀與 confirm 沒有 live 證據：JSON 沒有 `confirmed_shared_state_write`；run 步 look_at 沒有「開跑前服務會再讀一次…」；存下來的 JSON 在 verdict 之後仍寫 `done: false`、verdict 步仍 `pending`（serve.py:707-715 先 save 才 derive）。

cell 2 在合併後的 ndt 上，同樣條件下觀測大概不變：當時自己持有 claim、lab 閒置、measuring nothing；新守衛對自己的 claim 放行（ndt:694）；up.target 欄位格式沒變（ndt:586-588）；restore 新出現的 rc 3，run_cells.sh 本來就接受 0|3（:161-170）；walk 1 的 help 片語：要出現的兩句在 ndt:10780 與 10907，不該出現的兩句 0 命中。重跑時可能不同：OVS 現在也套 `in_flight`（任何 argv 含 matrix.sh／measure.sh／cpu_probe.py 的程序 ⇒ rc 5，`h4nl_up_rc_is_0` 會紅）；restore 的 `ndt down` 現在會刪 stale app pidfile 並寫 window 檔。以上是推論，沒有實跑。

## 九、我會跑、但證據裡沒有人跑過的測試

1. 變異：apps.start 的 8775 改回 8315——預測倖存，正是 RcProvenance 看不到的地方。
2. 單元：外人 claim 行寫成 `yours-x -- 12m left (…)`，應回 409，目前會回 202。
3. 單元＋變異：precheck 的 `r is None`（讀取名額用滿）與逾時分支，應回 409 `claim`。
4. 併發：precheck 很慢時同時送 POST /down 與 guided next，量延遲、確認無死鎖。
5. 舊 walk：一條 8f2fbb5b 之前建立的 H4 walk 走到 run 步會怎樣。
6. live：在 48209682 上重跑 walk 2，外加一次沒有 claim 的直接 run（預期 409），各約佔 lab 30 秒。
7. CI：`l1_unit_tests.sh:449` glob `tests/python/test_*.py`，兩個新套件第一次 push 就進公開 CI（python 3.12、ubuntu-24.04），目前沒有任何 CI 形狀的執行紀錄。
8. 逐 commit 掃描：`git log -p 68ace017..1a1944ea`，並印出 pattern 清單。

## 十、內部數字不一致

REPORT.md:283 寫 22:49:21，:14 與 :286 寫 22:49:18；REPORT-cells §5.3 引用的閘門仍是 `final-490513fe`，最終 head 的閘門是 `final-1a1944ea`。不算矛盾：check_gate_anchors 對 86 個變異報 `ok(81)`（自 e28bcfe4 起就是 72 對 77，固定差 5，計數單位不同）；+414/−56、14 檔/5348 行、72/32/86 全部核對一致。

---

## 十一、結論（編號）

1. **【blocking，推之前做】** 補一次逐 commit 的公開性掃描：同一掃描器跑 `git log -p 68ace017..1a1944ea`，log 印出 pattern 清單與對照組；0 命中再推。最終樹我查過是乾淨的，缺的是分支中途的 commit。
2. **【note，建議併入前修】** serve.py:528 `if not (line or "").startswith("yours"):`，owner 名以 yours 開頭的外人 claim 會通過。ndt:6575 的 `yours*` 有同樣歧義，但 ndt 的 up/down 守衛用 `foreign_claim` 精確比對，只有 serve 這層會被騙。後果：`half_stack_is_not_clean` 不檢查 up 的 rc，會照樣對 `.test_run/pids/kernel.pid` 送 SIGTERM。修法：`startswith("yours -- ")`，補一條測試與一條變異。
3. **【note】** RcProvenance 只驗 needle，陷阱變異會倖存。建議 `RC_SOURCE` 帶函式名、測試驗外層函式，再加一條「回退舊行號」的變異。
4. **【note，建議併入前修】** 修正第五節的過期註解：README:60、serve.py:29-30 與 :509-511、兩個 test docstring、verbs.py:208 的標籤、REPORT 的版本標記與 22:49:21。
5. **【note】** precheck 的「讀不到」分支沒有測試也沒有變異；`r is None` 時錯誤訊息的原因說錯。
6. **【note】** SLOT 等待沒有上限，最壞約 100 秒且佔連線名額。建議 `SLOT.acquire(timeout=…)` 回 503，或至少寫進 README。
7. **【note】** `ndt help` 的 serve 段三處不完整：「Every write carries the token」沒說讀取也要 token；沒提 cells／guided（這些 POST 會跑 netem、kill -TERM、改 knob）；token 路徑沒考慮 `XDG_CONFIG_HOME`。
8. **【note】** walk 邊角：8f2fbb5b 之前建立的 H4 walk 走到 run 步永遠回 400（`next` 帶不進確認欄位）；被拒的 run 每次留一個空的 `cells-raw/<cell>-<hex>`；grid 在 `run_argv` 逾時變 500；存下來的 walk JSON 顯示 `done:false`。
9. **【note】** post-r2 的碼沒有任何 live 證據。建議在 48209682 上重跑 walk 2，外加一次沒有 claim 的直接 run。
10. **【note】** 新套件會進公開 CI，但沒做過 CI 形狀的執行；裡面有計時型測試與 `ss` 相依。
11. **【note】** NoPatternKill 被放寬：現在只檢查「只出現 `os.killpg` 一種呼叫且同檔含標準字串」，新增一個對別的 pid 的 `os.killpg(...)` 不會被抓；隱式 kill 掃描只看同一行的 `subprocess.run(... timeout=)`，看不到多行呼叫與 `check_output`／`call` 帶 `timeout=`。目前的碼是乾淨的。
12. **【note，屬 trunk 的 live_cells】** 共用狀態登記表只涵蓋 4 個 knob 檔名；不在表上的：stale_app 格在 `.test_run/pids/` 種 pidfile（EXIT trap 清，SIGKILL 不觸發）、兩個 netem 格、half_stack 的 kill。
13. **【note】** r2 允許延後的項目：grid 的讀取併發上限、walk 的 owner 語意、status 步不擋。owner 語意已在 README 揭露，另兩項在文件中沒找到標記。
