# fable-judge scoped round 2 on feat/p4-heartbeat-0925 9fbedc39..b22e88ed

# 第二輪裁決（head `9fbedc39` → `b22e88ed`）

## 裁決：MERGE

helper＋tests 這半我的每一條發現都被**真的關掉**（不是宣稱）：紅燈 log、變異 38/38＋18/18、anchors 117/117 都對得上。spike 這半：#1、#11 關了；**#2 沒關**（用的探針正是這個 repo 自己量過「在這台機器上零鑑別力」的那支），但它的後果只是「白用一個 lab 時段」而不是損害，且合併本身不會執行 spike ⇒ 不擋合併，**擋段 S 的排程**（R2-1）。若 orchestrator 偏好單一乾淨狀態，可讀成「MERGE AFTER FIXES（只有 R2-1）」。

先更正我自己：**+1059 是我算錯**，worker 的 numstat `1053 1` 是對的。hunk 標頭 `@@ -566,6 +566,1053 @@` 的 1053 是新側總跨度（含 6 行 context），新增行是 1047；加第二 hunk +5、第三 hunk +1/−1 ⇒ +1053／−1。第一輪 diff 第 2341–3387 行的 `+` 行數也是 1047，可自行核對。

## (1) 逐條：關了沒有

| 我的 # | 狀態 | 證據（verified against a file，除非另註） |
|---|---|---|
| #1 spike 第二次 `ndt down` 回 3 ⇒ FAIL | **關了** | `S_heartbeat_spike.sh` 的 `spike_ndt`／`nd_up`／`nd_down`／`FABRIC_UP`（diff 126-162, 240-251）；自測真的走 `spike_finish → _common.sh finish()`＋stub ndt，三格結果見 `spike_selftest.p4hb-b22e88ed.log:43-45`；紅燈 `round2_tests.red.p4hb-fb4243e2.log:25` 正是第一輪我預測的那行 `FAIL S_heartbeat -- 'ndt down' exited 3` |
| #2 tc 權限預檢 | **沒關**（見 R2-1） | `precheck_tc` 用 `sudo -n -l tc …`（diff 212-230）；`tools/test_workflow/sudo_surface.sh:37-49` 09-03 實測：這台帳號有 `(ALL : ALL) ALL` 藍色規則，`sudo -n -l -- <cmd>` 對任何指令回 0，而 `sudo -n <cmd>` 回「a password is required」——「`-l` 答的是『可不可以跑』，不是『不用密碼跑得起來嗎』」。自測把 `sudo` stub 成 shell function（diff 476-485），所以驗的是接線，驗不到 sudo 語意 |
| #3/#5 helper 拒 NDTwin pipeline | **關了** | `plan()` 在 dead-switch 檢查之前 `if own: raise Refusal(...)`（diff 1156-1163）；測試「one switch of four」紅燈 `red:9` → 綠 `…b22e88ed.log:124`；變異 `ndtwin-pipeline-accepted` 被點名顆抓到（`mutate…b22e88ed.log:43`） |
| #4 設定檔閘門 stop/status | **關了**（照 Adam (b)） | `lab_conf_gate` 加 `heartbeat)` 臂、`start`／空／未知子動詞 `die`（diff 1073-1084）；dispatch `lab_conf_gate "${1:-}" "${2:-}"`（diff 1174）；G-7 suite +7 顆，紅燈輪紅 3（stop、status、dispatch 文字釘，`red:13-15`），59→66 全綠；`mutate_g7` 新 3 個都被點名抓到（`…g7…log:25-27`） |
| #6 `bmv2_alive` 看 uid | **關了** | real/effective uid 都須等於 expect_uid（diff 1131-1147）；夾具 `write_proc(owner=uid+4242)` 紅燈 `red:8` → 綠；變異 `bmv2-uid-unchecked` 抓到 |
| #7 算術注入＋標頭措辭 | **關了** | 垃圾清單加 `a[$(touch …pwned5)]`、直接問 `hb_is_daemon 'a[$(…pwned6)]'`（diff 1003-1021）；變異 `is-daemon-arithmetic-first`（把 `(( pid > 1 ))` 挪到 regex 前）被抓到；標頭改成只宣稱正向那顆看過紅（diff 1094-1099） |
| #9 競爭分支、KILL 後備 | **關了** | 兩顆競爭檢查（diff 966-978）、三顆 stubborn daemon 檢查（diff 987-1001，log 第 76 行真的有 `Killed`）；紅燈輪本來就綠（既有行為，worker 明講），看過紅靠三個變異 `race-branch-dropped`／`kill-fallback-dropped`／`kill-path-leaves-pidfile`（`mutate…log:45-47`） |
| #10 變異閘門依賴環境 | **關了** | 閘門標頭註明（diff 860-864）——我要的就是文件化 |
| #11 census 命中即停 | **關了**（殘餘見 R2-2、R2-3） | `hb_sniff.py` 首幀／stop file 即退（diff 624-687），socketpair 自測（`spike_selftest…log:36-37`）；`watch_sniffers`（diff 278-297）；替身 sniffer 自測 `log:50-51`；紅燈 `red:19-23,30` |
| #8 sudo 下的 dispatch 未執行 | 本質上仍開 | worker §2.4 明列；§2.5 給了裝後三步驗證（INFERRED 期望值），我同意那三步 |

## (2) spike 細節

**a. `spike_ndt` 的 3→0 與 `FABRIC_UP`：能不能藏住真的 teardown 失敗？不能。**
- verified `tools/test_workflow/ndt:4923-4932`：`down_verdict="$down_rc"`，只有在 `down_rc == 0` **且** `DOWN_SUBJECT` 為空時才改成 3。也就是 rc 3 由建構保證「每一步 teardown 都跑了、`verify clean` 過了、而且一開始就沒東西在跑」。teardown 失敗 ⇒ `down_rc ≠ 0` ⇒ 原樣回傳 ⇒ `spike_ndt` 只攔 `down` 且 `rc==3 && FABRIC_UP==0` ⇒ 其他一律穿透 ⇒ `finish()` 照 `fail`。
- `FABRIC_UP` 帳：`nd_up` 先設 1 再跑；`nd_down` 只在 0／3 清 0。inline `nd_down` 回 3 的路徑（起過 fabric 卻說沒東西）在 detect（`(( d == 0 )) || fail`）與 census 正常臂（`(( rc == 0 )) || fail`）都已判 FAIL，之後 finish 再把 3 映成 0 不會翻案——`fail` 只記第一個理由、不會被清掉（`_common.sh:71`）。
- 唯一被抹掉的資訊是「measured nothing」這個區別，而且只在 spike 自己已經收掉 fabric 時。`release` 走真 ndt（`spike_ndt` 只攔 `down`）。自測三格（0/3→PASS、1/3→FAIL、1/0→PASS）真的經過 `finish()`，不是 mock。✓

**b. `precheck_tc` 的 `sudo -n -l`：不回答「這條指令能不用密碼跑嗎」。**
- sudo 的 `-l <cmd> [args]` 語意是「政策允不允許這個使用者跑這條（含參數比對）」，回 1 只在不允許；它不區分 NOPASSWD。若帳號另有要密碼的藍色規則，`-n -l` 對任何指令都回 0——這正是 `sudo_surface.sh:37-49` 在這台機器上量到的（sudo 1.9.15p5）。repo 裡 `_common.sh:93-98` 卻寫「`sudo -n -l <cmd>` 恰在免密碼時回 0」，兩處互相矛盾；worker 的註解只引了 faults.sh 與 _common.sh，沒引 sudo_surface.sh。預檢的正確性因此押在一個 repo 自己都說不清的 sudoers 事實上。
- 有鑑別力的問法是 sudo_surface.sh 自己定的：**真的跑一條同形狀的無害指令、看 rc、stderr 只用來措辭**。`precheck_tc` 的 `elif` 分支（`run_tc qdisc show dev lo` 實跑）就是這種，但只有在覆寫 `FAULTS_TC` 時才走到。
- **`FAULTS_TC='sudo -n mnexec -a 1 tc'` 安全且正確嗎？是，但屬 inferred**：本機沒有 `mnexec.c` 可查（glob 無結果）。依 Mininet 的 mnexec：`-a <pid>` 是 `setns` 到該 pid 的 net ns（新版也附 mnt ns），不進 pid ns；pid 1 的 net/mnt ns 就是 root 的，交換機 veth 都在 root netns（`_common.sh:697-699` 也如此陳述）⇒ 效果與 `sudo tc` 相同，沒有多出來的能力；mnexec 的授權是 `require_root` 已驗過的那條（`_common.sh:96-97`），而 `dataplane_ok`／`ping_loss` 本來就以任意參數跑 `sudo -n mnexec -a <pid> …`（`_common.sh:572-576`）⇒ 參數不受限（inferred）。`faults.sh:316-318` 自己也把它當 shaped 介面的逃生路。`revert_link_loss`／`show_qdisc` 都走 `FAULTS_TC` ⇒ 覆寫後全程一致。
- 結論：**把 mnexec 路線設成 spike 的預設**（在 source `faults.sh` 之前 `: "${FAULTS_TC:=sudo -n mnexec -a 1 tc}"`），預檢自然落到實跑分支，`sudo -n tc` 降為覆寫選項。這樣不需要知道 sudoers 到底長怎樣。

**c. `watch_sniffers`＋stop file：會不會留下 sniffer、或命中時心跳沒停？不會，兩個殘餘是精度不是安全。**
- sniffer 的壽命有三道上限，與 stop file 無關：自己的 `seconds`（`hb_sniff.py`）、外層 `/usr/bin/timeout $((SNIFF_S+10))`、以及 census 在判定前 `wait` 全部 pid（diff 393）。INT/EXIT 半途離開時子 shell 沒被明殺，但 ≤30 s 自退，且 `ndt down` 拆掉 namespace 後 socket 即錯。⇒ 沒有任何路徑讓 sniffer 無限存活。
- 心跳停止有三條獨立路：`watch_sniffers` 命中即 `sp_hb_stop`（直接呼叫、不在 `$( )` 裡，`HB_STARTED=0` 回得到主 shell ✓）；臂尾 `census-verdict` 為 STOP 時 `(( HB_STARTED )) && sp_hb_stop`；`spike_finish`。報告快照在停之前拷（diff 287），事後 `[[ -s ]] || cp` 不覆蓋 ✓。sniff JSON 由 operator shell 的重導寫入 `$dir`（root mount ns），`first-hit` 讀得到，與 sniffer 的 mount ns 無關 ✓；半寫檔 `ValueError` 跳過 ✓；`error` JSON 不算命中，走 BAD 而非 OK ✓。
- 殘餘 R2-2：迴圈順序是「first-hit → 全退了嗎 → 逾時」，若 sniffer 在 first-hit 讀完之後、running 檢查之前退出，這一輪直接 `return 0`、`WATCH_HIT` 空 ⇒ 命中由臂尾的 `census-verdict` 補抓（仍 STOP、仍停心跳），只是不是「立刻」。修法一行：`(( running )) || { WATCH_HIT="$(first-hit)"; ...; return 0; }` 再讀一次。
- 殘餘 R2-3：stop file 對 mnexec 內 sniffer 的可見性取決於 host 是否共用 mount ns——worker 自己標 INFERRED；看不見時 sniffer 也只跑到自己的首幀或 `SNIFF_S`，有界。

## (3) 兩項爭議

- **numstat**：worker 對，我錯，理由如上。到第二輪 head 的 `1092 2` 我沒有 git 不能重算，與 diff 內容量級相符（helper 又加約 40 行、改 1 行）。
- **`test_apps_residue.sh` 那兩顆紅——同意「時間相依、與本分支無關」，證據：**
  1. 兩輪 diff 的檔案清單（第一輪：spike 四支、`mutate_ndtwin_lab_heartbeat.sh`、`test_ndtwin_lab_heartbeat.sh`、`ndtwin-lab`；第二輪：spike 三支、`mutate_g7…`、`mutate_ndtwin_lab_heartbeat.sh`、`test_ndtwin_lab_config.sh`、`test_ndtwin_lab_heartbeat.sh`、`ndtwin-lab`）都不含 `test_apps_residue.sh`／`ndt`／`stack.sh`／`ports.sh`；該 suite 不 source `ndtwin-lab`（grep 只在註解裡提到，`lab_kernel_dir` 是 stub，`test_apps_residue.sh:136-141`）。
  2. 紅的兩顆（`test_apps_residue.sh:335,337`）拿一個剛起的活程序當夾具，斷言輸出含「installed 0s ago」——牆鐘一到兩秒內的比較；同檔 `:323-325` 自己記錄過同一夾具「被一兩秒的 wall clock 排除掉」的前科。
  3. 同 head 5/5 綠（`apps_residue_rerun2…log:12-17`）；第一輪兩次 `helper_suites` 都綠（`…9fbedc39.log:12`、`…32a25b23.log:12`）；紅的那次是與其他閘門併跑時。
  4. `rerun` 那份 `# rc=1` 是腳本尾端 `grep FAILED` 無匹配的 rc，內容五次皆 rc=0，`rerun2` 修正後 rc=0——log 內容相符。

## 發現（第二輪）

**R2-1 [should-fix，排段 S 時段前必修；不擋合併]** `precheck_tc` 的 `sudo -n -l` 探針在這台機器上零鑑別力。位置 `S_heartbeat_spike.sh`（diff 212-230）；證據 `tools/test_workflow/sudo_surface.sh:37-49`；後果＝第一輪 #2 原封不動（claim、建 fabric、起心跳後在第一刀 `sudo -n tc … a password is required` 才失敗；無損害，白用時段）。修：預設 `FAULTS_TC` 改 mnexec 路線（上文 b），或改成實跑 `sudo -n tc qdisc show dev s1-eth3` 並以 stderr 區分「sudo 拒絕」與 tc 的「Cannot find device」。自測要用真的 `sudo -n`（不 stub）跑一次 `mnexec -a 1 true` 之類的無害形狀，rc 才是證據。

**R2-2 [note]** `watch_sniffers` 一輪的漏窗（上文 c）。

**R2-3 [note]** stop file 的 mount-ns 可見性未量，已揭露；有界。

**R2-4 [note] 數字**：SUMMARY §2.3「`mutate_g7` 18 個 `caught by`」——log 是 17 個 caught＋1 control（`ok(18)` 是含 control 的錨數）；「spike 自測 12 紅」——紅燈 log 是 10 個 🔴（2＋2＋6）加兩行 `SELF-TEST FAIL`。其餘（196/0、196/2、66/0、66/3、38/0、117/117、ok(39)、ok(18)、suites 2 red）與 log 逐一相符；七支 `p4hb-b22e88ed` log 第 1 行都是完整 sha，紅燈 log 第 1 行是 `fb4243e2…` 全 sha。

**R2-5 [note]** 拒 NDTwin pipeline 的判準是 argv 裡第一個 `.json` 的 basename＝`ndtwin_switch.json`：同名的外來程式會被誤拒（無害），NDTwin 程式換名編譯會漏過；W 端 `ndt` 的 `pipeline_is_ndtwin`（比對解析後路徑）仍是第二道。可接受。

**R2-6 [note] 給 Adam 的新 sha `6a558fe4…` 這輪沒有 log 背書**（第一輪有 `installed_helper_sha` log，這輪只有 `helper_suites` 的紅說「不等於已裝的」）。orchestrator 併進 trunk 後自己 `sha256sum tools/test_workflow/ndtwin-lab` 再轉給 Adam——他裝的是 trunk 那份，數字也該來自那份。

**R2-7 [note] 仍未執行（worker §2.4 已列，我同意）**：sudo 下的 dispatch（含新的 `"${2:-}"`）、真 veth 上 BPF／OUTGOING／netem、root 在 `/run` 的 daemon、真 sniffer 的 stop file、operator 的 tc 授權實況、段 S 全部。裝好後的三步驗證（無 fabric `status`⇒3、無 fabric `start`⇒1 點名 topo session、NDTwin fabric 上 `start`⇒1 點名 `ndtwin_switch.json`）是把前兩項從讀碼變成證據的最便宜方法。

主要檔案：`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925/hb-9fbedc39..b22e88ed.diff`、`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/{test_ndtwin_lab_heartbeat,mutate_ndtwin_lab_heartbeat,mutate_g7_ndtwin_lab_config,check_gate_anchors,spike_selftest,helper_suites,apps_residue_rerun2}.p4hb-b22e88ed.log`、`.../gates-0910/round2_tests.red.p4hb-fb4243e2.log`、`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-heartbeat-0925/tools/test_workflow/sudo_surface.sh:37-49`、`.../wt-p4-heartbeat-0925/tools/test_workflow/ndt:4923-4932`、`.../wt-p4-heartbeat-0925/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh:71,93-98,239-246,572-576`、`.../wt-p4-heartbeat-0925/tests/shell/test_apps_residue.sh:323-337`。