# judge-LP1C-c03130fe (fix/live-p1-common-5e-nolab-0927 @c03130fe, base 3f8c2abf)

# 判決：MERGE AFTER FIXES

- **Lab 安全面：路徑已封，沒有 BLOCKING。** 5e 與 13 noctrl 改用 zz 主機名。STUBS 補上 sudo、mnexec、iperf、iperf3 的函數 stub。PATH 最前面的 shim 接得住 `command`、env 與子行程發出的呼叫。section 14 會把漏網的呼叫判紅。red-first 成立，M42／M43 成立，數字對得上。
- **有一項要在 merge 前修（F1，不是安全問題）。** 新加的假 `ps` 把假主機列在**真的行程表後面**。只要真 fabric（有 h2）在跑，`host_pid h2` 就會拿到真 pid，section 14 的第二個對照因此假紅。這正好就是 Q7 要做的事：live 07 跑著，同時 worker 跑離線閘門。
  - 如果 orchestrator 接受「live 07 期間本 suite 紅是預期的」，照現況 merge 在安全上沒問題。
- **報告有一處跟它自己的 log 相反。** SUMMARY 說 check_gate_anchors 讀不到檔案形式的 anchor，但它的 log 是 `ok(46)`。結論不受影響，敘述要改。
- 沒執行任何東西，也沒用 git。讀取範圍：
  - worktree 的檔案、gate logs、scripts，以及 sweep 放在 scratchpad 的 raw。
  - `/proc/sys/kernel/pid_max` 與 `/usr/local/sbin/ndtwin-lab`，都是唯讀。
  - SUMMARY §1 引用的 `P4-HB-FOLLOWUPS-R2-SUMMARY.md` 依規則沒讀。

路徑縮寫：
- WT＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-live-p1-common-nolab-0927`
- test＝WT/tests/shell/test_live_p1_common.sh
- mut＝WT/tests/shell/mutate_live_p1_common.sh
- common＝WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh
- ndt＝WT/tools/test_workflow/ndt
- G＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`
- SW＝`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp/nolab_sweep_all_c03130fe`
- SUMMARY＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/LIVE-P1-COMMON-NOLAB-SUMMARY.md`

---

## BLOCKING（lab 安全）
無。

## 必修（merge 前；不是安全問題）

### F1　假 fabric 蓋不過真 fabric，section 14 對照在真 fabric 下假紅
- 【讀】假 `ps` 先執行 `/usr/bin/ps "$@"` 印出真表（test:86），之後才印四列假主機（test:88-107）。
- 【讀】`host_pid` 讀到第一筆 `${args##* } == mininet:hN` 就 return（ndt:6058-6060）。
- 【推】live 07（pod-topo，h1..h4）跑著時，真的 `mininet:h2` 那列排在前面。section 14 第二條（test:1065-1066，期望 `4194392`）拿到真 pid，判 FAILED。
  - 09-26 事故本身就證明 `ps` 看得到真 fabric 的 host shell。
- 【推】mutate gate 的 baseline 會因此紅，輸出 `refused: baseline is not green` 並 exit 2（mut:70-74）。
- 不碰 lab：HEAD 裡唯一用 h 名問 `host_pid` 的就是這條對照，輸出只拿去比對。
- 為什麼要在 merge 前修：
  - 這正是 test:580-585 那段註解自己批評的形狀：結果取決於別人有沒有開 fabric。
  - 紅的是 section 14，最容易被誤讀成「又碰到 lab 了」。
- 建議修法：假 shim **先印假列**，再 `exec /usr/bin/ps "$@"`。
  - 這樣 h1..h4 永遠對應到 pid_max 以上、不存在的 pid。
  - 將來若有格子退回 h 名，拿到的也是打不到的 pid，比現在更安全。
- 修完要重跑 test、mutate、redfirst，並跑一次下面第 1 項的 decoy。

## 報告更正（不擋 merge）

### C1　check_gate_anchors 的敘述與它自己的 log 相反
- SUMMARY:138 說「這個檢查器讀不到 `mutate_live_p1_common` 用檔案存放的 anchor」。
- 【讀】G/check_gate_anchors.lp1cnolab-c03130fe.log:73 是 `mutate_live_p1_common.sh ok(46)`。
- 【讀】WT/tests/shell/check_gate_anchors.py:892-960（pass 1.6）讀的正是 `cat > "$A/<name>.old" <<'EOF'` 這種形狀，而 `ok(%d)` 印的是 anchor 數（:1405）。
- 【推】46＝42 個 mutation＋4 個控制組，所以 M42／M43 的 anchor 在 c03130fe 已被靜態計數，而且唯一。實際證據比報告說的還強。

## NOTEs

- **N1　mutation gate 裡，mutant 的 `host_pid` 根本不存在。**
  - 【讀】mutant 是 `$BK/<name>/_common.sh`，BK 放在 TMPDIR 底下（mut:42、51-53；gate log:3 的 TMPDIR＝…/scratchpad/tmp）。
  - 【讀】common:27 從這裡往上四層，得到 REPO＝`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-…`。那裡沒有 `tools/test_workflow/ndt`（我 glob 過）。
  - 【推】所以每個 mutant 的 `source "$NDT"` 都靜默失敗，`host_pid` 未定義，pid 永遠是空的。
  - section 14 對照讀的是 REAL_REPO 的 ndt，所以照樣綠。在 gate 裡，它證明的是一支 mutant 根本不會呼叫的 `host_pid`。
  - M42／M43 的 kill 不依賴 `host_pid`，結論不受影響。這是 gate 本來的性質（意外地讓 mutant 更安全），不是這次引入的。
- **N2　M43 是被多重條件同時殺掉的**，細節見 Q3。
- **N3　tripwire_b 的「0」只涵蓋 driver 本身。**
  - 【讀】driver 設 `NOLAB_LOG=tripwire.log`（gates_lp1c2.sh:32）。
  - 但 redfirst 的 `at()` 每段都改寫 NOLAB_LOG（scripts-…-b/redfirst_lp1c.sh:26），sweep 每支 suite 也改寫（nolab_sweep.sh:25）。
  - 同一批的 redfirst stage 1 其實記了 4 條被拒的 sudo，只是寫在別的檔。
  - 兩個 tripwire.log 都是空檔（我讀過）。
- **N4　sweep 的 B 輪只假了 `ps` 這一個通道**，細節見 Q7 的 R3。
- **N5　sweep 掃的是 3f8c2abf 的 63 支 suite**，不是 b2eeb71d 加本分支的樹。
- **N6　raw 沒歸檔。** §4 表格和四支 rc 1 失敗原因的唯一證據，是 SW 底下每支 suite 的 `.calls`／`.out`。它們只在 /tmp scratchpad，沒跟 gate log 放在一起，而 /tmp 是揮發的。建議複製到 G 旁邊，符合「raw 進 audit-raw」。
- **N7　假 `ps` 不管 `-p`／`-C` 過濾。**
  - 【讀】test:88-93 只要 `-o` 裡有 args 就加四列，所以 `ps -o args= -p X` 也會多出四列。
  - 本 suite 沒有這種呼叫；外部 shim 也一樣（make_shims.sh:56-86）。將來加格子要注意。

---

## Q1　有沒有封住路徑？有

**link_usage_round 呼叫的是哪個 `host_pid`：**
- 【讀】是 ndt 的。common:1135-1136 在子 shell 裡 `source "$NDT"` 後呼叫 `host_pid`；NDT＝`$REPO/tools/test_workflow/ndt`（common:28）。
- 【讀】live-p1/ 目錄裡沒有任何 `host_pid()` 定義。

**這支 `host_pid` 怎麼找行程：**
- 【讀】ndt:6060 是 `ps -eo pid=,args=`，走 PATH 上的 `ps`。不是絕對路徑 `/usr/bin/ps`，也不是 pgrep 或直接讀 /proc。所以 suite 的假 fabric（test:84-111）確實是它讀到的東西。

**section 14 的對照查的是不是真正要緊的那一支：**
- 【讀】一般跑的時候，COMMON 就是真檔（test:42-43），REAL_REPO（test:40-41）和 REPO 指向同一個 checkout，所以是同一支 `host_pid`，是要緊的那支。
- 在 mutation gate 裡不是（N1）。

**_common.sh 裡所有能走到 sudo、mnexec、iperf、ping 的函數：**
- 【讀】`require_root`（89-97）、`require_free_lab`、`take_claim`、`finish`、`run_verify_p4`、`pingall_via_ndt`、`ping_loss`、`pingall_loss`、`link_usage_round`。
- 【讀】test 只呼叫其中兩個：
  - `link_usage_round`：test:577、592、606、609、612、999、1048。
  - `finish`：section 10，而且 NDT 換成了 stub（test:784）。
- 【讀】`tc` 和 `ip netns` 在 _common.sh 裡是 0 筆。

**HEAD 裡每一條 link_usage_round 都在 sudo 之前停下：**
- 【讀】pkg1host 停在 common:1092-1095（src==dst）。
- 【讀】to-zz9 停在 1085-1087。
- 【讀】no-ns、to-zz2、default 停在 1137-1140。
- 【讀】slowpkg 停在 1124-1128。
- 【讀】noctrl 停在 1102-1108（4194399 大於 pid_max）。
- 【讀】對應的 rc 見 test log:112-121、178-193。

**防線：**
- 第 2 層：函數 stub（test:177-180）。
- 第 3 層：PATH shim（test:76-83）。
- 第 4 層：section 14 的兩條檢查（test:1067-1069）。
- 【讀】_common.sh 裡唯一的絕對路徑 `/usr/bin/mnexec` 在 97 行，只是 `sudo -n -l` 的參數，而且不在呼叫圖上。

**剩下用 h 名的 package：**

| package | 用在 | 會不會走到 host_pid 或 lab |
|---|---|---|
| PKG3（h1..h3） | test:313、317、321、324、336 | 不會。只經過 `model_switch_dpids`／`assert_probe_ok_follows_set`，都是 python／jqp（common:346-352、467-489） |
| PKG4 | test:314、331 | 不會，路徑同上。另外它的主機是 **h1..h3**，不是題目說的 h1..h4（mkpkg 固定 `for h in (1, 2, 3)`，test:282-284） |
| pkg1host（h1） | test:572-579 | 不會。在 host_pid 之前就回 rc 1 |
| ecnpkg／fastpkg 的 package.json | test:922-930 | 不會。只進 `link_usage_window` |
| 各 graph fixture | — | 不會。只是 curl stub 回傳的 JSON |

- 唯一剩下以 h 名問 `host_pid` 的，是 section 14 對照本身（h2），也就是 F1。

## Q2　Red first：成立

**Stage 1（trunk 的 suite）：**
- 【讀】redfirst_lp1c_b log:10-19：外部 shim 記到恰好 4 條（`uniq -c` 各 1）。pid 4194391／2／3 是外部假主機（make_shims.sh:72-75）。suite 自己回報 `Ran 163 checks, 0 failed (rc 0)`。
- 【推】4 條＝5e 的 to-h2 和 default 各一對 server／client。
  - trunk 的 5e 只有 `has`，沒有 rc 斷言（diff:153-157）。
  - noctrl 因為 999999 不存在而走 NOT RUN。
- 【推】stage 1 是 trunk 的 test 檔配 HEAD 的 _common.sh；diff 沒動 _common.sh，所以等價。

**Stage 2（124a7f3c）：**
- 【讀】b log:20-29：這一段 `NOLAB_FAKE_FABRIC=0`，只靠 suite 自己的假 fabric。
- 結果 rc 1，`Ran 166 checks, 1 failed`。唯一的 FAILED 是 section 14 的 PATH 檢查，而且逐條列出那 4 條呼叫。兩個對照 ok，外部 shim 0 筆。

**第一版 `redfirst_lp1c` 為什麼 rc 1：**
- 【讀】第一版在 final/redfirst_lp1c.sh:51 用 `grep -qF "  ok       $c"`，也就是 ok 後面固定 7 格空白。
- 【讀】兩個對照的標籤本身以兩個空格開頭（test:1064-1065），印出來 ok 後面是 9 格，所以比不到。
- 【讀】-b 版在 :53 改成「在 ok 行的任何位置比對標籤」。
- 【讀】SHA256SUMS 顯示兩版只有 redfirst_lp1c.sh 不同，make_shims、nolab_sweep 和所有 shim 的雜湊都一樣。
- 【讀】第一版 log 的其他每一行都跟 -b 版相同，而且 log:25 已經判定「exactly one check failed, and it is section 14's」。
- 小修飾：SUMMARY:60 說 log「顯示」對照是 ok 的。實際上 log 沒印出對照的 ok 行，這是從「唯一紅的是那一條，總數 166」推出來的。

**redfirst_lp1c_b 自己站得住嗎：** 站得住。同一個 sha、同一組 shim，三段完整重跑，rc 0。

## Q3　M42／M43

**anchor 唯一：**
- 【讀】M42 那一行在 _common.sh 只出現一次（common:1137）。M43 的 anchor 是 1137-1142 連續六行，同樣唯一。
- 【讀】applier 要求出現次數＝1（mut:60-62、83-86），log 顯示兩者都是 caught。C1 的 `ok(46)` 也靜態確認了。

**M42：成立。**
- 【讀】指名的兩條都紅（mut log:268-269）。
- 【讀】其他紅的只有 no-ns 那格兩條，加上第二條 rc-2（log:270-274），全是「拿掉 namespace 拒絕」的直接後果。
- 【讀】check_fires 要求跑完同樣的 169 條（mut:92-96），所以不是中途崩潰造成的紅。

**M43：**
- 【讀】指名的 PATH 檢查紅了（log:276）。但因為 M43 也包含 `if false`，M42 的全部 killer 也都紅了（log:277-282）。
- 【推】所以 M43 證明了 PATH 檢查「會紅」，但**沒有**證明「只有 PATH 守衛抓得到」：拿掉 PATH 守衛，它照樣被殺。PATH 守衛的獨有價值，其實是由 red-first stage 2 證明的。

**總數：**
- 【讀】caught 共 42 行，是 M1–M43；M25 是刻意不存在（mut:560-564）。
- 【讀】C1–C4 四個控制組都保持綠（mut log:79-80、283-284），總結行在 log:287。

## Q4　source ndt 有沒有副作用：沒有

- 【讀】ndt 第 0 欄的 bash 敘述只有這些：
  - 51 `set -uo pipefail`
  - 64 `source ports.sh`
  - 73-79 讀 sudo_surface.sh（讀不到就 `exit 2`）
  - 92 `export TERM`
  - 94-98 設定顏色
  - 9655 `declare -A`
- 【讀】被 source 時在 10658-10660 `return 0`，後面的 dispatch 不會跑。
- 【讀】帶命令替換的 top-level 指派只有 HERE／REPO（53-54）。
- 【讀】ports.sh:50 和 sudo_surface.sh:85、118 的 top-level 只有 `$(cat <<'TABLE'…)` 與函數定義。
- 所以不會寫 `.test_run/`、不會 claim、不會碰 lab、不會跑 dispatch。
  - `set -u` 和 TERM 只活在那個 `$(…)` 子 shell 裡。
  - 讀不到 sudo_surface 的話，`exit 2` 只結束子 shell，對照拿到空字串而判紅（fail closed）。

**$REAL_REPO 解析到哪個 checkout：**
- 是被執行的那個 test 檔所在的 checkout。
  - 在 worktree 跑就是 worktree。本次所有 gate 的 cwd 都是 worktree（log:3），redfirst 的複本也放在 worktree 旁邊。
  - 在主 checkout 跑就是主 checkout。
- 【推】merge 之後會 source 合併樹的 ndt。b2eeb71d 有沒有改到 `host_pid` 我沒核，建議在 test merge 上重跑。

## Q5　假 ps

**假 pid 打不到任何行程：**
- 【讀】`pid_max`＝4194304（`/proc/sys/kernel/pid_max`）。
- 假行的 pid、ppid、pgid、sid 是 4194391..4194394（test:99），noctrl 用 4194399。全部 ≥ pid_max，對它們發 signal 只會得到 ESRCH。

**會不會改變別的格子的斷言：不會。**
- 【讀】本 suite 裡 `ps` 唯一的消費者是 `host_pid`。_common.sh 裡的 ps、pgrep、pkill 只出現在註解；test 裡的 ps 只出現在 shim 本身。
- 【讀】沒有以 pgid 殺東西的清理，也沒有數行程的格子。
- 【讀】`kill` 只出現在三處：
  - `finish` 裡，但 section 10 的 `CTRL_PID=""`（test:785）；
  - link_usage_round 殺自己的 `$!`（common:1143、1154）；
  - noctrl 的 `kill -0 4194399`。
- mutate gate 本身跑在 suite 的 PATH 之外，不受影響。

**有沒有路徑會把真 pid 當成 mininet:hN 印出來：有。**
- 真表先印（F1）。在 HEAD 裡，這只會影響 section 14 的對照。

## Q6　唯讀探測

**status／topo-out 確實唯讀：**
- 【讀】ndtwin-lab:1825-1831 的 `status` 做的是：
  - 印 config；
  - `tmux -L ndtwinlab list-sessions`；
  - `sweep_count`（sweep_find 435-465，只讀 `ps` 和 `/proc/<pid>/cmdline`，不發 signal）；
  - `ps | awk` 數 mininet 行程。
- 【讀】1678-1681 的 `topo-out` 是 `has-session` 之後 `capture-pane -p`。
- 【讀】lab_conf_gate（280-306）只印訊息，而且 status 在它的唯讀白名單上。
- 【讀】實際經 sudo 執行的 `/usr/local/sbin/ndtwin-lab`，同樣這幾行逐字相同。

**mnexec -a 1 true 無害：**
- 【讀】三個探測就是 sudo_surface.sh:86-88 表上列的「harmless probe」（`ndt_sudo_probe`，172-183）。
- 【推】`mnexec -a 1 true`＝以 root 進入 init 的 namespace 跑 `true`，不改狀態、不送封包；`ovs-vsctl list-br` 是唯讀查詢。

**raw 與 SUMMARY 表格對得上：**
- 【讀】SW 底下的 `.calls` 與 SUMMARY 的表一致：handoff 是 status 52、list-br 26、mnexec 13，合計 91。
- 表格漏了 `tc qdisc show` ×13。它是唯讀形式，被 shim 放行給**真的** tc（make_shims.sh:43-51）。

**SUMMARY 的兩個小錯：**
- 「都經由 ndt 發出」不完全對：cell_gate 的 `topo-out 400` 來自 lib_e.sh:133（位於 WT/doc/audit/2026-08-31_sampling-ceiling-after-merge/）。
- FORCED_ABORT 列了 4 處，實際有 6 處（還有 :119、:125），全部帶 `FORCED_ABORT=1`。lib_e.sh:199-204 的說法正確。

**判斷：當 NOTE 可以，不擋。** 但要說清楚：
- sweep 只跑過「探測被拒」那一支。
- 【讀】真 lab 在跑且沒有 shim 時，`lab_session`（ndt:1375-1379）會回真，下游有會動 lab 的程式碼：
  - `app_stop` 的 energy|sim 分支會跑 `sudo -n $LAB <name>-stop`（ndt:9015-9034）；
  - topo-stop 和 cleanup 在 ndt:3078、3082、5258、5271。
- 這 6 支在「探測成功」時會不會走到那裡，沒有人驗過。所以讓它們安全的是 shim 強制令，不是「探測唯讀」。
- 建議 follow-up：給這 6 支 suite 內建 PATH sudo stub（worker 已提出，待你裁決）。

## Q7　merge 後可以跑 live 07 嗎

**可以，條件如下：**
- 所有 worker 的 PATH 最前面是 nolab shim，並加上 `env -u SELFTEST_PROBE_SUDO -u NDT_MEASURING`。
- 沒有 worker 在 live 07 所用的那個 checkout 裡跑 suite。
- 最好先修 F1。

**殘餘風險：**
- **R1**：F1。本 suite 會紅，mutate gate 會 refuse。
- **R2**：PATH shim 看不見的通道。
  - 絕對路徑執行檔。
  - bash `/dev/tcp` 連線：ndt:148、ports.sh:100、stack.sh:732。
  - Python urllib：ndt:7147、7294、7336。
  - builtin `kill`。這一項最要注意：Mininet host shell 是 root 的，一般使用者打不到；但 ndt 以 adam 身分起的 kernel、proxy、apps 與 worker 同 uid。這類 signal sweep 完全記錄不到，因為假 pid 只會得到 ESRCH。
- **R3**：B 輪只假了 `ps`。真 fabric 還有 tmux session、/proc/net/dev 裡的 veth、在 :8000／:8081 聽的服務、OVS bridge。「B 輪沒比 A 輪多呼叫」只證明了 ps 這個通道（SUMMARY:76）。
- **R4**：120 個 mutate_*.sh 沒做動態掃描。
- **R5**：沒在合併樹上掃過（N5）。
- **R6**：四支 suite 在 shim 加 guard 下兩輪都 rc 1，兩輪都 0 次 lab 呼叫（sweep log:13、20、24、68）。

  | suite | 紅在哪 | 原因 |
  |---|---|---|
  | build_guard | 15 條，全是「期望 -j2、實得 -j1」（SW/A/test_build_guard.sh.out） | 【推】guard 的 JOBS=1 被這支 suite 讀到，是閘門環境的產物 |
  | l1_shell_scoring | 12 條，全在 group C，靜態讀其他 suite 的最後一行 | 【推】與 shim 無關 |
  | gate_exit_code_not_tee | case 1 得 rc 2、case 4 得 0 | 輸出在 :77 被丟到 /dev/null，看不出 |
  | start_bg_log_rotation | `.prev` 輪替沒發生 | 輸出在 :50 被丟掉，看不出 |

  風險在於：強制 shim 的環境下它們永遠紅，真的回歸會被蓋掉。
- **R7**：sweep 不記錄寫進 checkout 的檔案（`.test_run/`、各種 knob）。【推】

---

## 逐條判定（SUMMARY）

| 位置 | 判定 | 說明 |
|---|---|---|
| §1 缺陷描述 | SUPPORTED | diff 與 red-first stage 1 都對得上 |
| §1 noctrl 的第二條路徑 | SUPPORTED（讀碼） | 沒有實跑，只讀了程式碼 |
| §2 守衛機制 | SUPPORTED | |
| §2「host_pid 看到的是假的 h2」 | 部分 CONTRADICTED | 只在沒有真 fabric 時成立（F1） |
| §2 修正內容 | SUPPORTED | |
| §2 M42 | SUPPORTED | |
| §2 M43 | 「會紅」SUPPORTED；「只有 PATH 守衛看得到」UNDER-EVIDENCED | |
| §3 red-first 與第一版 harness 錯誤 | SUPPORTED | |
| §4「B ≤ A」 | 對 ps 通道 SUPPORTED；對 fabric 整體 UNDER-EVIDENCED | 見 R3 |
| §4 表格 | SUPPORTED | 靠 raw 檔成立，gate log 本身沒有；漏了 tc |
| §4 status／topo-out 唯讀 | SUPPORTED | |
| §4「都經由 ndt 發出」 | 部分 CONTRADICTED | topo-out 來自 lib_e.sh |
| §4 apps_stop 只打自己的 fixture | UNDER-EVIDENCED | worker 已自標 INFERRED |
| §4 四支 rc 1 且沒碰 lab | SUPPORTED | |
| §4 mutate_*.sh 沒掃 | UNTESTED | worker 已承認 |
| §5 本 suite 的靜態 grep | SUPPORTED | |
| §5「全部 suite 都沒有繞過 tripwire 的路徑」 | UNDER-EVIDENCED | 見 R2 |
| §6 test／mutate／redfirst_b／sweep | SUPPORTED | |
| §6 check_gate_anchors 的理由 | CONTRADICTED | 見 C1 |
| §6 tripwire_b | 在 driver 範圍內 SUPPORTED | 見 N3 |
| §6 第一個 driver 死在第 49 行 | SUPPORTED | -final 沒有 sweep／tripwire 的 log |

## 數字對帳
- **163／166／169**：
  - 【讀】HEAD log 逐節相加：4+7+20+17+55+13+11+13+17+8+4＝169。
  - diff 新增 2＋4＝6 條，169−6＝163，對得上 trunk。
  - 【推】166＝163＋3。124a7f3c 本身我沒讀。
- **mutation**：42 個 mutation、0 存活；4 個控制組、0 紅，對。`ok(46)` 等於 42＋4。
- **閘門**：120 格，對。
- **sweep**：63 列，對；6 支 suite 的各項計數都與 raw 相符，對。
- **不一致處**：
  - C1。
  - tripwire_b 的「0」的範圍（N3）。
  - 表格漏了 `tc qdisc show`。
  - FORCED_ABORT 列了 4 處，實際 6 處。
  - 題目說 PKG4 的主機是 h1..h4，實際是 h1..h3。

## what I would run that the report did not
1. **F1 的 decoy。** 起一個 argv 結尾是 `mininet:h2` 的無權限行程，例如 `(exec -a "bash --norc -is mininet:h2" sleep 120) &`，事後用它自己的 pid 收掉。
   - 用 HEAD 跑 suite，應該看到 section 14 第二條紅。
   - 修完再跑，應該是綠的。
   - 再用 124a7f3c 跑一次，確認交給 sudo 的是假 pid，不是 decoy 的 pid。
2. **測修正本身的 test 端 mutation。** 在 HEAD 的 test 裡把 5e 改回 `$PKG3`：預期 stub 檢查和 rc-2 紅，PATH 檢查保持綠。現有 gate 只變異 _common.sh，PKGZ 這個修正本身沒有 gate。
3. **M44。** 保留 rc 2，但在 `return 2` 之前插入 `command sudo -n true`：預期只有 PATH 檢查紅。
4. **修正 mutant 的目錄深度。** 讓 mutant 放在與 live-p1 相同的相對深度，使它們真的能 source 到 ndt，再重跑 M42／M43。
5. **會「回答」的 sudo shim。** status 回傳假 session、rc 0，list-br 回一個 bridge，並記錄 6 支探測 suite 在「lab 看起來是活的」時，接著會發出哪些動詞。
6. **在 test merge 上重跑。** 以 b2eeb71d＋c03130fe 重跑全部 gate 與 sweep。
7. **動態掃描 mutate_*.sh。** 至少掃會 source ndt、lib_e.sh、stack.sh 的那幾支。
8. **查清四支 rc 1 的原因。**
   - build_guard 不帶 JOBS=1 跑；
   - l1_shell_scoring 在 trunk 上、不帶 shim 跑；
   - 另外兩支不丟輸出再跑一次。
9. **補 PATH tripwire 看不到的部分。** 用 `strace -f -e trace=kill,tgkill,connect` 看每支 suite 的 signal 與連線。
10. **歸檔 raw。** 把 SW 下的 `.calls`／`.out` 複製到 G 旁邊。


---

# Round 2 -- scoped re-review of be2ad2d2 (12fc0683 F1, be2ad2d2 M44/T1/T2)

# 判決：MERGE

- **BLOCKING：無。必修：無。**
- 本判決依據兩部分：worker 在 be2ad2d2 上的閘門 log，以及我對 test merge 樹的逐行讀碼。
  - 【讀】test merge 的 worktree `wt-hbw-intake-0926` 裡，ndt 的 `host_pid`（ndt:6055-6062）與被 source 時的 return（10658-10660）都和本分支一字不差。
  - 【讀】test:87-119 的新 ps shim 也已經在 test merge 裡。
- **orchestrator 在 d3683aeb 上的重跑，我寫完時還沒有結果。**
  - 【讀】`rerun-redfirst_f1.d3683aeb.log` 只有第 1-4 行的 header（20:35:40Z 開始），沒有任何 stage 輸出，也沒有 `# rc=`。
  - 【讀】`rerun-summary.d3683aeb.txt` 是空檔。
  - redfirst（lp1c）、test、mutate 在 d3683aeb 上的 log 都還不存在。這些結果我**沒讀到**。
  - 請以你們自己的重跑結果作為最後確認。
- 另外更正我上一輪的建議：我寫的 decoy `exec -a "bash --norc -is mininet:h2" sleep 120`，argv 最後一個字是 `120`，`host_pid` 根本比不到。worker 沒照做是對的（SUMMARY:170）。

縮寫：
- test＝WT/tests/shell/test_live_p1_common.sh
- mut＝WT/tests/shell/mutate_live_p1_common.sh
- G＝logs/gates-0910
- WT＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-live-p1-common-nolab-0927`

---

## Q1　12fc0683 有沒有關掉 F1：有

**host_pid 那一種呼叫：假列一定排在最前面。**
- 【讀】`host_pid` 只發一種 ps 呼叫：`ps -eo pid=,args=`（ndt:6060）。
- 【讀】shim 對這種呼叫的處理：
  - 解析出 `spec=",pid=,args="`（test:92-97）；
  - 因為含 `args`，不走直接放行（test:98）；
  - 兩欄都帶 `=`，所以判定 `headerless=1`（test:115-116）；
  - 先執行 `fake`（test:100-114），再 `exec /usr/bin/ps "$@"`（test:117-119）。
- 所以四列假主機一定排在任何真列之前。`host_pid` 讀到第一個相符就 return，永遠拿到 4194391..4194394 其中之一。
- 【讀】`host_pid` 沒有第二種 ps 呼叫。

**rc 有保留。**
- 【推】兩個 `exec` 分支（test:98、119）的結束碼就是 ps 自己的。
- 【讀】有 header 的分支用 `real="$(…)"; rc=$?`（test:121），最後 `exit $rc`（test:125）。

**header 判斷的邊角情況（host_pid 都用不到，列為 NOTE-A）：**
- (a) **`x=TEXT`（非空的自訂 header），例如 `-o pid=PID,args=`。**
  - 【推】因為每欄都帶 `=`，shim 把它判成沒有 header。但 procps 遇到非空的自訂 header 會印出 header 行。
  - 結果是 header 排在四列假主機**之後**。會跳過第一行的讀法，會丟掉假的 h1，並把 header 當成資料。
- (b) **`--no-headers`、`--no-heading` 或 BSD 的 `h`，搭配不帶 `=` 的欄位。**
  - 【推】這會被判成有 header，但 `head -1`（test:122）拿到的其實是**第一筆真列**，所以真列排在假列前面。
  - 用 `-e` 時第一筆是 pid 1。但加上 `-p`／`-C` 之類的篩選時，第一筆可能就是真的 Mininet host。
- (c) **真表輸出為空。**
  - 【推】`printf '%s\n' ""` 會先印出一行空白。
- (d) **`--format`、BSD 的 `o`，或 `-eopid=,args=` 這種寫法。**
  - 【推】這些不會被解析，直接放行，完全不會加假列。
- 【讀】這個 suite 裡 ps 唯一的使用者就是 `host_pid`，所以以上情況都不影響本 suite。

## Q2　decoy red first：證明了它所宣稱的

**decoy 的 argv 符合 host_pid 的比對規則。**
- 【讀】decoy 是 `( exec -a "bash --norc -is" /usr/bin/python3 -I -c '…sleep(120)' mininet:h2 ) &`（redfirst_f1.sh:25）。
- 【推】它的 args 以空白接起來後，最後一個字是 `mininet:h2`，符合 ndt:6059 的 `${args##* } == mininet:h2`。
- 【讀】腳本另外做了兩層驗證：
  - 起來後讀 `/proc/$DECOY/cmdline` 確認（:27-29）；
  - 每次跑 suite 之前，用**真的** `host_pid h2` 確認拿到的就是 decoy（:34-36）。
- 【讀】四次執行都記錄「decoy pid N；host_pid h2 = N」（redfirst_f1 log:11、18、22、25）。這是最直接的證據。
- 【讀】driver 設 `NOLAB_FAKE_FABRIC=0`（gates_lp1c3.sh:32），所以外部的 ps 只是原樣放行。

**無特權，而且有收掉。**
- 【讀】decoy 由腳本自己起，沒有經過 sudo。
- 【讀】每次執行後都用它自己的 pid `kill` 再 `wait`（:31、39）；EXIT trap 也會再收一次（:15-16）。
- 【推】`$!` 就是 exec 之後的 python 的 pid；它本身有 120 s 的上限，所以即使被 SIGKILL 最多也只殘留 120 s。

**三段（stage 3 跑兩次）：**
1. 【讀】c03130fe 加 decoy：**只有** section 14 的對照紅，expected [4194392]、actual [797841]，actual 就是 decoy 的 pid（log:10-16）。這是 F1 的紅。
2. 【讀】HEAD 加 decoy：169 條、0 失敗，對照 ok（log:17-20）。
3. 【讀】124a7f3c（5e 還在用 h 名）：
   - 原樣執行時，h2 server 的呼叫收到的是 **decoy 的 pid 800890**（log:23-24）。
   - 把 HEAD 的 ps 移植進去後，收到的是 4194392／4194391／4194393，從來不是 decoy（log:26-28）。
   - 「守衛的 sudo」指的是 suite 自己的 PATH shim：只記錄、拒絕，沒有對 decoy 執行任何東西。
4. 【讀】副本已刪（log:29）；worktree 的 tests/shell 裡沒有殘留的 `.redfirst-*`、`.mutant-*`（我 glob 過）。

**一個小缺口：** decoy 只在跑之前驗證過存活，跑完沒有再驗。
- 【推】suite 大約 4 s（sweep log:26 的 `0/4`），遠低於 120 s 上限。而且 stage 1 和 stage 3 的原樣執行都看到了 decoy，所以 stage 2 與 stage 3 移植版的「ok／從來不是 decoy」應該不是 decoy 已死造成的空泛結果。
- 建議在 `decoy_down` 之前加一行 `kill -0` 確認。

## Q3　M44 與 check_fires_only：有強制「只有 PATH 檢查紅」

**「只紅指名那條」是真的被強制：**
- 【讀】`others` 取的是**所有** `^  FAILED` 行，去掉前綴後逐字比對指名的 label（mut:143-145）。
- 【讀】只有當 `others` 為空、指名的都紅、rc≠0、而且跑完的條數等於 baseline 時，才算 caught（mut:137-146）。
- 【推】`check`、`has`、`hasnt` 以及 test:44 的提前退出，印出來的失敗行都是同一個 `  FAILED   ` 前綴；suite 中途死掉則會讓條數不符，被判 SURVIVED。所以沒有漏網的紅。

**`command sudo -n true` 確實繞過函數 stub、打到 PATH shim：**
- 【推】bash 的 `command` 會略過函數查找，所以會找到 PATH 上的 `$NOLAB/bin/sudo`（test:128 把它放在 PATH 最前面）。這次呼叫只會記在 `$NOLAB/calls`，不會進 `stub_lab.log`；而且 `return 2` 保留了。
- 【讀】mutate log:283-284 是 `caught … (exactly the named check(s) went red)`，只有「NOTHING reached for sudo, mnexec or iperf past a stub」這一條紅，stub 檢查和 rc-2 都是綠。這就是實證。
- 【讀】anchor 唯一：`ok(47)` 裡包含 m44 那一對。
- 就算萬一打到真的 sudo，`sudo -n true` 也是 no-op。

## Q4　T1／T2（.told／.tnew）

**anchor 唯一。**
- 【讀】test:623（to-zz2）與 test:626（default）各只出現一次。
- 【讀】runtime 的 applier 會數出現次數，不等於 1 就判 SURVIVED（diff:63-79）。

**旁邊的副本：正常情況一定會刪；被 SIGKILL 時不會。**
- 【讀】bash -n 失敗時刪（mut:185），跑完立刻刪（mut:187），anchor 失敗時根本不會寫出檔案。
- 【讀】EXIT trap 會刪掉 `.mutant-*-test_live_p1_common.sh`（mut:44）。
- 【推】遇到 SIGINT、SIGTERM、SIGHUP 時也會刪：非互動 bash 只要設了 EXIT trap，就會攔截這些終止訊號並先執行 trap。
- 遇到 SIGKILL、OOM kill 則不會刪，細節見 NOTE-D。

**它們避開 pass 1.6 的理由：成立。**
- 【讀】`CASE_FILE_RE` 要求檔名以 `\.(old|new)$` 結尾（check_gate_anchors.py:901），`.told`／`.tnew` 對不上。
- 【讀】整個 gate 只取一個 applier，也就是第一個 body 同時含 `.old` 與 `.new` 的函數，即 `mutant()`，它的檔案是 _common.sh（:925-926）。所以所有 `.old` anchor 都會拿去 _common.sh 裡數（:956-960）。
- 【推】如果 T1／T2 用 `.old`，就會在 _common.sh 裡數到 0 次，被判 MISSING，checker 會紅。

**失去靜態檢查可以接受，列為 NOTE-C。**
- runtime applier 是 fail closed 的：anchor 過期會判 SURVIVED，gate 會紅，不會產生假綠。
- 但 checker 的格子只顯示 `ok(47)`，完全看不出這個 gate 還有 2 個它看不見的 anchor。這違反它自己「無法檢查 ≠ 檢查過且沒問題」的原則（check_gate_anchors.py:37-46）。
- 目前只有 SUMMARY:192 有揭露。建議 follow-up：
  - 讓 pass 1.6 依副檔名對應 applier（`.told` 對應 `check_fires_test`／`$TEST`）；或
  - 至少把 `.told` 列為 UNPARSED。

**T1／T2 的內容與安全性：**
- 【讀】它們跑的是真的 _common.sh（沒有設 `COMMON_UNDER_TEST`）。
- 【推】所以 `host_pid` 有定義，確實從假 fabric 拿到 fake pid，接著在函數 stub 被記錄。
- 【讀】mutate log:285-296 顯示紅的是 rc-2、stub 檢查、目的地文字三條，PATH 檢查保持綠，與上面的推論一致。
- 【推】即使 live 07 正在跑，因為假列排在前面，T1／T2 拿到的也是 fake pid；再加上 stub 與 PATH shim，是安全的。

## Q5　數字

- 【讀】caught 共 45 行，SURVIVED 0 行（mutate log）。
  - 45＝M1–M44 扣掉 M25 共 43 個，加 T1、T2。
- 【讀】控制組 C1–C4 都保持綠（log:79-80、297-298）；總結行在 log:301。
- 【讀】`ok(47)`（anchors log:73）＝43 個 _common mutation＋4 個控制組，T1／T2 不在其中，與 Q4 一致；120/120 格，0 個 NOT CHECKED（:135）。
- 【讀】仍是 169 條（test log:201；mutate baseline log:10）。delta diff 沒有新增任何 check。
- 【讀】_common.sh 的 sha256 沒變（36c3689b…，log:300）。
- 【讀】redfirst_lp1c_f1 與 -b 版結果相同（163、166、169），腳本 hash 也相同（5c6f042a）。
- 【讀】tripwire_f1 為 0 行。
- 【讀】N6 的 raw：285 檔＝284 個檔＋SHA256SUMS，與 SUMMARY:198 的「284 個檔」相符。

## Q6　先前的 NOTE 有沒有因為這輪改變

| 項目 | 本輪之後 |
|---|---|
| R1／F1 | **已解決**（Q1、Q2） |
| N1（mutant 裡 host_pid 未定義） | 沒修（SUMMARY:151-153 已承認）；T1／T2 已經走過真的 host_pid 加假 fabric 這條路，**部分補上** |
| N2（M43 被多重條件殺掉） | **已由 M44 解決** |
| N3（tripwire 只涵蓋 driver） | 文件已註明（SUMMARY:141、209）；行為沒變 |
| N4／R3（B 輪只假了 ps） | 沒變，另見 NOTE-E |
| N5／R5（沒在合併樹上掃） | 沒變；d3683aeb 的重跑不包含 63 支 sweep |
| N6（raw 沒歸檔） | **已解決** |
| N7（假列不看 `-p`） | 沒變；而且現在假列排在前面，對 `ps -o args= -p X | head -1` 這種讀法影響更大。本 suite 仍然沒有這種呼叫 |
| R2、R4、R6 | 沒變 |
| R7（檔案狀態碰撞） | 沒變；另外多了暫存副本的問題（NOTE-D） |
| C1 與上輪的小錯 | 已就地更正（SUMMARY:84、91、94、138）。【讀】lib_e.sh:133-134 確認 topo-out 與 status 都來自那裡 |

---

## NOTEs（都不擋 merge）

- **NOTE-A** header 判斷的邊角情況（Q1 的 a–d）。
- **NOTE-B decoy 會干擾 lab 工具。**
  - 【讀】decoy 的 argv 以 `mininet:h2` 結尾，所以會被 ndt 的 `mn_count`／`fabric_host_count` 算進去（ndt:126-146）。受影響的地方包括：
    - `ndt down` 的清場驗證（:5018）；
    - `ndt up` 的 model／fabric 主機數比對（:4276）；
    - rollback（:3098）；
    - `ndtwin-lab status` 的 mininet 計數（ndtwin-lab:1830）。
  - `mn -c` 也會把它 SIGKILL 掉。
  - 所以 **redfirst_f1 不可以和任何 live 的 up／down／status 重疊**，包括你們現在跑的 d3683aeb 重跑：必須在 live 07 開始前跑完，decoy 也要收乾淨。
- **NOTE-C** T1／T2 的 anchor 在 check_gate_anchors 的格子裡看不到（Q4）。
- **NOTE-D 副本在 SIGKILL 時會殘留。**
  - 【讀】.gitignore 沒有排除 `.mutant-*` 或 `.redfirst-*`。
  - 副本檔名是固定的，同一個 checkout 裡同時跑兩份這個 gate，會互相刪掉對方的副本（fail closed）。
  - 【讀】你們的 rerun 在結束時只檢查 `.redfirst-*`（rerun-lp1c-f1.frozen.sh:24），`--untracked-files=no`（:25）也看不到 `.mutant-*`。建議把 `.mutant-*` 加進檢查。
- **NOTE-E 外部 make_shims.sh 的 ps 仍然是假列在後。**
  - 【讀】ps 與 make_shims.sh 的 hash 都沒變（SHA256SUMS）。
  - 【讀】sweep 在有真 fabric 時會拒跑（nolab_sweep.sh:19），所以 sweep 沒問題。
  - 但 redfirst_lp1c 的 stage 1 沒有這個拒跑：若有 fabric 在跑，會把真 pid 交給外部 shim。雖然會被拒絕，但該 stage 會判 BAD。它同樣必須在 live 07 之前跑。
- **NOTE-F** red-first 只在跑前確認 decoy 存活（Q2）。
