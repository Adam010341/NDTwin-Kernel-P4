# 第三輪裁決（head `b22e88ed` → `01ff8368`，只動 spike）

一句話：**R2-1 CLOSED、R2-4 CLOSED、R2-2 NOT CLOSED**——補讀的邏輯對了，但它以一個裸的 `watch_hit` 呼叫引進了 `set -e` 回歸：census 每一個「沒有主機看到幀」的乾淨臂都會讓整支 spike 在 `watch_sniffers` 裡中止。自測看不到，因為整個 `self_test` 跑在 errexit 被忽略的語境裡。helper 未動（diff 只含 `S_heartbeat_spike.sh`），合併裁決不變；段 S **排程前**要再修一行。

## 三項

**R2-1（tc 路線）— CLOSED。**
證據：`S_heartbeat_spike.sh:85` 在 `:87` source `faults.sh` 之前 `: "${FAULTS_TC:=sudo -n mnexec -a 1 tc}"`，`faults.sh:88` `${FAULTS_TC:-sudo -n tc}` 保留既有值；`precheck_tc`（`:182-198`）改成**實跑** `run_tc qdisc show dev lo` 看 rc，`-l` 已消失（自測 `:512-516` 斷言錄到的 sudo 呼叫沒有 `-l`；紅燈 `spike_selftest.red.p4hb-0849c0e2.log:46,49` 顯示舊行為）；mnexec 授權由一次真呼叫證明，worker log `:51` 與 orchestrator rerun `:46` 都是 `rc 0`。
殘餘：「mnexec 授權不限參數」仍是 INFERRED（見 (d)）；不影響 CLOSED，因為執行期預檢證明的就是 `mnexec -a 1 tc qdisc show dev lo` 這個精確形狀，只剩 `add … netem` 的 tc 參數差異未實證，worker 已明寫。

**R2-2（最後一個 sniffer 的命中）— NOT CLOSED（回歸 R3-1）。**
補讀本身正確：`:273` 全部退出後、`:274` 逾時後各再 `watch_hit` 一次；命中路徑紅→綠（`red…log:56` `'none 1'` → `…01ff8368.log:56`）。但 `watch_hit` 沒命中時 `return 1`（`:252`），而 `:273` `if (( ! running )); then watch_hit "$dir" "$stopf"; return 0; fi` 把它放在 then-body 當裸命令——不在 `&&/||`、不在 `if` 條件、沒有 `!`——`set -e` 生效時 shell 直接退出。生效鏈：`:62`／`:90` `set -euo pipefail`；`:638-639` `census` 在 `if … then` 的 body 裡；`:403` `watch_sniffers` 裸呼叫；`:273`。後果：PART=census／all 的第一個乾淨臂（§H.6 預測每一臂都乾淨）⇒ 腳本 rc 1 ⇒ trap `spike_finish` 收尾 ⇒ 最後一行 `FAIL S_heartbeat -- the script exited 1 before its own verdict`，census 表永遠產不出來；detect 不受影響（不用 `watch_sniffers`）。sniffer 不會殘留（走到 `:273` 表示全退了），心跳由 trap 停 ⇒ 是「跑不完」不是「傷 lab」。
自測為何看不到：`:585` `self_test && exit 0 || exit 1` 把 `self_test` 放在 `&&` 串的第一個位置 ⇒ 依 bash 語意其內部所有函式與子 shell 都忽略 `-e`，連內部再 `set -e` 也無效；`:562-567` 的乾淨對照組因此通過，真跑會死。同一類缺陷 `_common.sh:213-224` 記過一次（`finish()` 在 `-e` 下半途被殺）。
修：`:273`／`:274` 改 `watch_hit "$dir" "$stopf" || true`；自測的三個 watch 情境改在**新的** bash 行程裡跑才看得到紅，例如 `bash -euo pipefail -c "$(declare -f watch_sniffers watch_hit child_running sp_hb_stop); WATCH=…; HB_REPORT=…; watch_sniffers …"`（`declare -f` 把函式原文帶過去；不能靠子 shell 裡 `set -e`）。

**R2-4（SUMMARY 數字）— CLOSED。**
證據：SUMMARY `:416-418`：`mutate_g7` 改為「17 caught＋1 control SURVIVED，`ok(18)` 是含 control 的錨數」；紅燈 spike 自測改為「10 個 🔴（2＋2＋6）＋2 行 `SELF-TEST FAIL`」——與我第二輪讀到的兩份 log 相符。

## 四個問題

**(a) 預設路線是否真的穿過 faults.sh？是。** verified：`:85` 先設、`:87` 才 source；`faults.sh:88` 用 `:-` 不覆蓋非空值。spike 用到的每一個 tc 出口：`run_tc`（`faults.sh:119`）← spike `cut_link:286`、`precheck_tc:186`、`faults.sh` `revert_link_loss:351,354`（spike 經 `restore_link:290` 與 `spike_finish:161` 呼叫）；`show_qdisc`（`faults.sh:164`）← `netem_attach_point:258`（經 `cut_link:283`）、`netem_delete_point:364`（經 `revert_link_loss`）、spike `no_netem_on_cut:293`。`inject_link_loss:308` 與 `FAULTS_KILL` spike 不用。唯一不走 `FAULTS_TC` 的是 `qdisc_snapshot.sh`（`:24` `${QDISC_SNAPSHOT_TC:-tc} qdisc show`）——唯讀、不需 root，本來就該獨立。`${FAULTS_TC} "$@"` 未加引號展開成 6 個字，字串裡無 glob。環境覆寫：`:=` 尊重、`:84` 記下來源、自測遇到環境值會紅（`:494-495`），確保驗的是預設。附帶：`faults.sh:53-57` 說 08-17 用 `sudo -n -l` 確認 tc 四條授權「已解決」——那正是 `sudo_surface.sh:37-49`（09-03）證明零鑑別力的探針；mnexec 預設繞開了這個不可靠的前提，是對的方向。

**(b) 那一次真 sudo 是否無害且有界？無害是；有界在實務上是、在構造上不是。** `:525` `/usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true`：三個絕對路徑，含斜線的命令字 bash 不查函式也不查 PATH ⇒ `sudo()` stub 攔不到 ✓；`-a 1` 進 pid 1 的 net（新版 mnexec 連 mnt）ns＝root 的，等於不動；`true` 什麼都不做；`-n` 不會停下來問密碼。沒有 `timeout` 包住——只有異常 sudo 設定（遠端 NSS／PAM）才會卡，建議加 `timeout 15` 讓它在構造上有界。拒絕時印紅不判過 ✓（`:527-529`）。**紀律面**：工單 §3 寫 worker 的 sudo 只能經已裝的 `ndtwin-lab`；這是另一個 binary。效果無害、且 worker 揭露「共呼叫兩次、無其他 sudo」（SUMMARY `:376`）。但從此每一次 `--self-test`（含閘門、含別台機器）都會發一次 sudo；要不要接受是 orchestrator／Adam 的事，我建議至少放在 opt-in（例如 `SELFTEST_PROBE_SUDO=1`）或在 SUMMARY 首段明寫「自測含一次真 sudo」，不要只在文末。

**(c) R2-2 的替身是否重現了競態窗口而非別條路？是。** 替身 `child_running`（`:573`）在回答「已退出」的同時寫入命中檔 ⇒ 第一次 `watch_hit`（`:268`）讀不到、存活檢查說全退了、只有 `:273` 的再讀能看到——這正是「寫入落在讀取之後、存活判定之前」的順序，而且是最緊的版本。真實世界的順序保證成立：JSON 由 operator shell 的重導在 sniffer 退出前寫完、子 shell 才消失，所以「行程已不在 ⇒ 檔案已完整」，半寫檔的情形被排除。舊碼對同一替身回 `'none 1'`（red log `:56`）、新碼回 `hZ 0`——替身有鑑別力。只是它驗的是命中路徑；乾淨路徑（R3-1）正好是自測語境看不到的那條。

**(d) 「mnexec 授權不限參數」是否在每個依賴處都標 INFERRED？不是，兩處漏標。** 有標：`precheck_tc` 註解 `:179-180`（「INFERRED from ping_loss's use; not read from sudoers」）、SUMMARY `:421`（並誠實寫「要到段 S 第一刀才會實證」）。**沒標**：檔頭 `:80-81`「under the mnexec grant … ping_loss already uses with arbitrary arguments」——ping_loss 的用法是讀 `_common.sh:572-576` 可證的事實，但「因此授權允許任意參數」是推論，這裡沒說；自測註解 `:492-493`「which the mnexec grant covers whatever its arguments」——直接當事實寫。`die` 訊息 `:614-616` 不依賴這個推論 ✓。ok 行 `:528`「the mnexec grant the default route needs is there」略超：探針證明的是 `-a 1 /usr/bin/true`，路線需要的是 `-a 1 tc …`；不過執行期 `:186` 隨後就實跑 `tc qdisc show` 形狀，只剩 `add … netem` 未證。推論本身合理：repo 裡 `mnexec -a <pid> ping …`／`true`／`timeout … python3 …` 都以任意參數跑過（06/07 live 26/26），一條只放 `show` 不放 `add` 的 sudoers 樣式不合常理。修：`:80-81`、`:492-493` 各加「(INFERRED)」，`:528` 改成「the mnexec grant is usable without a password (probe: `-a 1 true`)」。

## 新發現

**R3-1 [should-fix，段 S 排程前必修；不擋合併]** 上文 R2-2：`:273-274` 裸 `watch_hit` 在 `set -e` 下中止 census 的每個乾淨臂；修法與可看紅的自測構造如上。

**R3-2 [note]** 自測的一次真 sudo（(b)）：無害、已揭露、但偏離工單 §3 字面；建議 opt-in 或 `timeout`，並在 SUMMARY 首段揭露。

**R3-3 [note] 標記缺口**（(d)）：`:80-81`、`:492-493`、`:528` 三處措辭。

**R3-4 [note，既有非本輪]** `census:389` `session="$(hb_watch session …)"` 在 `-e` 下若報告檔尚未出現會中止；`heartbeat start` 回 0 時 daemon 已寫 pidfile、報告緊接其後，窗口極小；加 `|| die` 或重試更穩。

## 核對

- 三份 log 第 1 行都是完整 sha（`0849c0e2…`、`01ff8368…`、rerun 標頭 `01ff8368…`）；紅燈輪 3 個 🔴 與 commit 訊息一致；綠燈輪與 rerun 0 紅、`SPIKE SELF-TEST PASS`、evidence 行 rc 0。
- diff 只動 `S_heartbeat_spike.sh` ⇒ helper sha 未變的說法與檔案相符（sha 值本身沿用第二輪，未另有 log）。
- verified：以上所有行號皆對照 head 全文（`wt-p4-heartbeat-0925/doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`）、`faults.sh:40-75,88,119,164,256-374`、`qdisc_snapshot.sh:18-24`、主 checkout `sudo_surface.sh:37-49`、`_common.sh:71,213-224,572-576`。inferred：`mnexec -a 1` 的 namespace 語意（本機無 `mnexec.c`）、sudo `-n` 不會阻塞、bash 的 errexit 例外規則（依手冊，未在此機執行驗證）。
