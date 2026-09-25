# 第四輪裁決（head `01ff8368` → `e1245b40`，只動 spike）

一句話：**R3-1～R3-4 全部 CLOSED**，這次的關法是對的——三個 watch 情境、detect、session 讀取都改在**新的** `bash -euo pipefail` 行程裡用 `declare -f` 帶原文跑，紅燈有看到（`4861a458`／`5c882c9f`／oldcode 副本），綠燈兩份（worker、你的 rerun）。worker 的裸呼叫稽核與我逐行重讀的結果一致。**合併裁決：MERGE**（helper＋tests 自 `b22e88ed` 未動，sha `6a558fe4`；spike 剩下的是排段 S 前的 note，不擋）。

## R3-1～R3-4

| # | 裁決 | 一行證據 |
|---|---|---|
| R3-1 裸 `watch_hit` 在 `set -e` 下中止乾淨臂 | **CLOSED** | head `:291-292` 兩次補讀都是 `watch_hit … \|\| true`；乾淨窗口情境改在新行程跑（`:611-620`），紅燈 `spike_selftest.red.p4hb-4861a458.log:54`「rc 1 … the process died」，綠燈 `…e1245b40.log:54`，oldcode 副本再紅 `…oldcode…log:21` |
| R3-2 自測的真 sudo | **CLOSED** | `:552-561` opt-in `SELFTEST_PROBE_SUDO=1`、`/usr/bin/timeout 15`、絕對路徑、預設印中性行；預設 log `:51`「NOT run (opt-in)」、probe log `:51-52` rc 0、你的 rerun `:46` 同；SUMMARY 第四輪首段揭露（`:496`） |
| R3-3 INFERRED 標記 | **CLOSED** | 檔頭 `:81-83` 把事實（`ping_loss` 以任意參數跑 mnexec，`_common.sh:572-576`）與推論（授權因此不限參數，(INFERRED)）分開；自測註解 `:519`「(INFERRED)」；ok 行 `:557` 只說探針證明了什麼（`mnexec -a 1 true`） |
| R3-4 session 讀取可能在 `-e` 下中止 | **CLOSED** | `wait_session` `:254-262`（20×0.25 s，讀不到回 1 不印）；census `:409-415` `if ! session=$(…)` ⇒ FAIL 列、停心跳、`nd_down`、`continue`；驅動 `:664-681` 在 `set -e` 行程裡驗兩種結果；正向那顆紅燈 `red…4861a458.log:56`「got 'NONE'」（負向那顆 worker 明說沒紅過） |

## 四個問題

**(a) oldcode 證據是否成立？成立。** 工具是 `scratchpad/hb/oldcode.sh`（30 行，我讀了）：把 head 的 spike 複製到**同一個目錄**（`$D/.S_heartbeat_spike.oldcode-$$.sh`，所以 `SPIKE_DIR`／`LIVE_P1` 解析相同），用 Python 把三行改回舊樣、`assert count == n`（1＋2 處），印出 diff（log `:7-17`），再跑**副本自己的** `--self-test`——副本的 `declare -f` 傾印的是副本的函式（裸 `watch_hit`、裸 `return`），也就是新驅動跑舊碼；判定要求 rc≠0、🔴 恰好 2 個、且正是那兩行；EXIT trap 刪副本（11:46:08 的綠燈 log `# status:` 為空，一致）；經 guarded_build、第一行全 sha。detect 那條紅線帶著「driver said: … 0/8 directions heard」——證明驅動已越過 `set -u` 走到 judge 那行才死，紅是 detect 自己的；`5c882c9f` 那次「nothing written」沒有驅動文字，確實無效，worker 揭露正確。可重現：diff 在 log 裡，任何人套回三行再跑 `--self-test` 即得。唯一缺口：工具本身只在 session scratchpad（R4-4）。

**(b) 驅動有沒有把真路徑用到的東西都帶進去？有，對所測性質沒有會讓它「誤過」的差異。**
- watch 驅動（`:575-591`）：`declare -f watch_sniffers watch_hit child_running`＋真的 `WATCH`（hb_watch.py）＋不存在的 `HB_REPORT`（`cp … || true`）＋stub `sp_hb_stop`（`echo stopped > "$1"; HB_STARTED=0`，rc 契約與真的 `sudo … || true; HB_STARTED=0` 相同：永遠 0）。兩個函式引用的每個名字（`child_running`、`watch_hit`、`sp_hb_stop`、`WATCH`、`HB_REPORT`、`date`、`sleep`、`cp`）都在；`WATCH_HIT=""`、`HB_STARTED=1` 與真跑相同。呼叫點形狀：真跑 `:429` 是 `census`（在 `if` body 裡）內的裸呼叫，驅動 `:588` 是 `set -e` 腳本裡的裸呼叫——errexit 語境等價。
- detect 驅動（`:633-660`）：`declare -f detect judge note fail bad say` 傾印的是自測 shell 裡**當下的**定義＝spike 自己的 `judge`（`:94-98`）與 `_common.sh` 的 `note`／`fail`／`bad`／`say`（`say` 是 _common 那份，faults.sh 的已被蓋掉——與真跑同一 source 順序）。`VERDICT_RC=0; VERDICT_WHY=""`＝`_common.sh:41-42` 的初值。stub 只換掉碰 lab 的步驟（`prepare`／`nd_up`／`sp_hb_start`／`sp_hb_stop`／`nd_down`／`now`）與 hb_watch 程式（假的 `all-heard` 回「BAD 0/8」）；`RUN`、`HB_REPORT`、`CUT_DIRS`、`BEACON_S`、`TIMEOUT_S`、`CYCLES` 都給了。呼叫點 `[[ "all" == detect || "all" == all ]] && detect` 重現 `:740`（detect 是 `&&` 串最後一個指令 ⇒ 內部 errexit 生效）。到 `:338` 為止 detect 觸碰的東西全覆蓋；`QDISC_TOOL`／`cut_link`／`restore_link`／`no_netem_on_cut` 在 `:338` 之後、此情境到不了（刻意）。檢查同時要求 `wrc==0`、`survived VERDICT_RC=1`、驅動輸出含 judge 那行 ⇒ 真的 `judge → fail` 路徑跑過且 detect 之後回 0；舊碼同驅動會死（oldcode log）⇒ 有鑑別力。找不到任何 stub／預設值差異能讓驅動過而真路徑失敗。

**(c) 意外的真路徑執行與腳本順序是否一致？一致，而且 `no venv` 之前碰不到任何有副作用的東西。** 不帶 `--self-test` 地 `source` ⇒ 跳過 `:687-689`，走 `:692-699`：PART／CYCLES 檢查、`mkdir -p "$RUN"`（唯一副作用：一個空的 `spike/runs/<UTC>_S_heartbeat` 葉目錄）、`trap`、banner、`[[ -x "$NDT" ]]`（worktree 有 ndt ⇒ 過）、`[[ -x "$PY" ]] || die`（`:699`，worktree 無 `p4_proxy/venv` ⇒ rc 2）。之前的 source 只定義函式（兩支檔案自述如此）。碰不到 `require_root`（`:701`）、第一個 sudo（`:713`）、`precheck_tc`（`:717`）、`require_free_lab`（`:732`，唯一的 `ndt status`）、旋鈕（`:733-734`）、`take_claim`（`:739`）。trap 進 `finish`：`CLAIMED=0` ⇒ 不 `ndt down`、不 release，`rmdir "$RUN"` 拿掉空葉子、印 `REFUSED`、exit 2——與 worker 說的「finish 印 REFUSED」相符；`rmdir` 不會拿掉空的父目錄 `spike/runs/`，與「留下一個空 runs/ 目錄、已刪」相符。與你查到的（無他人 claim、heartbeat status rc 3）一致。附註：因為是 `source`，`set -euo pipefail` 與 EXIT trap 裝進了 worker 的 debug shell、`die` 退出的是那個 shell——無 lab 影響，只解釋了「它就停在那裡」。

**(d) 還有沒有正常結果會在 `set -e` 下結束 run？沒有。** 我逐行重讀 `detect`（`:316-372`）、`census`（`:375-446`）、run 區塊（`:692-745`）：每條正常結果分支都以 `return 0`、`continue`、`case` 臂、或回 0 的 `fail`／`note` 收尾（`fail` 最後一個指令是 `bad` → printf → 0，`_common.sh:71`；`:320/325/329/441` 的裸 `return` 因此回 0）；所有正常路徑可回非 0 的函式（`nd_up`、`nd_down`、`sp_hb_start`、`wait_session`、`watch_hit`、`child_running`、`cut_link`、`restore_link`、`no_netem_on_cut`、`netem_attach_point`、`precheck_tc`、`consts`、`host_pid`）都在 `&&`／`||`／`if`／`!` 裡；`watch_sniffers`、`census`、`detect` 本身現在永遠回 0；`:740` 在 PART=census 時 `[[ ]]` 假、`&&` 串豁免。剩下的只有**儀器**失敗（非正常結果）：(i) `hb_watch all-heard`／`others-up`（`:334`、`:350`）用裸 `load()`（不像 `wait-*`／`first-hit`／`census-verdict` 有 try/except），報告檔不存在才會死——`start` 回 0 加上前面的 `wait-heard` 之後實務上到不了，且 daemon 以 `os.replace` 原子換檔；(ii) `:743` `column … | sed` 在 pipefail 下，機器沒裝 `column`（bsdextrautils）會把做完的 census 變成「exited 127 before its own verdict」。兩者都是 note。

## worker 的裸呼叫稽核

與我的結果一致（SUMMARY `:513-523`）。兩處小不精確：「`hb_watch` … 回 0」對 `all-heard`／`others-up` 只在報告存在時成立（上文 (d)(i)）；`< <(model_hosts …)` 沒列，但其狀態由構造被忽略。沒有漏掉任何會在正常結果下結束 run 的地方。

## 新發現（本輪 diff 沒有弄壞任何東西；以下全是 note）

- **R4-1 [note]** `wait_session` 不檢查 `status == "running"`（或 `pid`＝剛起的 daemon）：若 `start` 回 0 的瞬間檔案仍是上一臂的「stopped」報告，會把舊 session 交給 sniffer。窗口是微秒級（daemon 寫完 pidfile 緊接著寫報告），影響只及 payload 啟發式——ethertype 規則與 `first-hit` 不用 session。修：只接受 `status == running` 的報告。
- **R4-2 [note，第一輪就存在]** `:347` `cut_link || break`：第二端 `tc add` 失敗時，CUT_A 的 netem 只由 EXIT trap 在 `nd_down` 拆掉 veth **之後**才試著移除 ⇒ `revert_link_loss` 回「cannot locate」⇒ 多一條誤導的 `fail`。無殘留（veth 已不在）。修：`cut_link || { restore_link || true; break; }`。
- **R4-3 [note]** `:743` 加 `|| true`（上文 (d)(ii)）。
- **R4-4 [note]** oldcode 工具只在 session scratchpad；log 保存了效果（三行 diff＋紅線）但沒保存方法。若要證據方法活過 scratchpad，把 `oldcode.sh` 放進 `spike/` 或 `gates-0910/`。
- **R4-5 [note]** detect 驅動沒定義 `QDISC_TOOL`：此情境到不了 `:339` 所以無妨，但未來加「OK」情境會像 `5c882c9f` 那樣死於驅動自己的 `set -u`；現在就補上。

## 核對

- 五份 worker log 與 rerun 第一行都是完整 sha；`4861a458` 2 紅（clean window、session）、`5c882c9f` 3 紅（＋detect，該紅無效已揭露）、`e1245b40` 0 紅 PASS、probe rc 0、oldcode「exactly the two checks」rc 0；rerun 0 紅、「NOT run (opt-in)」、helper sha `6a558fe4`。
- verified：所有行號對照 head `e1245b40` 全文（`wt-p4-heartbeat-0925/doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`）、`oldcode.sh`、`_common.sh:41-42,71`；inferred：bash errexit 例外規則（手冊）、`mnexec -a 1` 語意（本機無原始碼）。
