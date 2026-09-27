# JUDGE QUEUED-bbb9fd41

**判決：MERGE**（沒有 BLOCKING）

- 交付的每一個 FIX，按原 judge 描述的形狀都已關閉。queued3 的 red first 都有 b005bf50 與 HEAD 並排的原文，紅的理由也對。
- 沒找到新的 group C 規則在現有語料上造成偽綠。lib_e.sh 的 `unset` 和 sudo_surface.sh 的純註解改動都站得住。
- 兩件事要處理，但都不擋這個分支：
  - Q-N1：本交付自己的 queued2 tripwire 揭露一個 trunk 既有的漏洞，要另開 ticket。SUMMARY 的 lab 帳也漏了這一筆。
  - Q-N2：本分支自己造成三處過時的行號引用。建議合併時順手修，只動三行註解。

**範圍**
- 全程唯讀：沒有執行任何東西，沒有用 git。
- 讀了：SUMMARY、diff（28 檔）、worktree 現況（抽查的檔案與 patch 一致）、全部 `*.queued3-bbb9fd41.log`、`.kept/`、`scripts-queued3-bbb9fd41/`、driver 總輸出（scratchpad `queued/logs/gates_queued3.run.txt`）。
- queued／queued2 的 log 只用來查標記和 tripwire。
- 兩份 judge 檔只當 NOTE 的規格讀；PROBE-SUITES-STUB-SUMMARY.md 只 grep 了 §5 的 NOTE 定義行。

**路徑縮寫**
- WT＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927`，其中 ts＝WT/tests/shell。
- L＝ts/test_l1_shell_scoring.sh；MP＝ts/mutate_probe_stubs.sh；LIB＝ts/lib_probe_stub.sh；SS＝WT/tools/test_workflow/sudo_surface.sh。
- G＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910`，沒寫 tag 的 log 都是 queued3。
- RF＝G/redfirst_queued.queued3-bbb9fd41.log；K＝它的 `.kept/`。
- S＝工人的 QUEUED-NOTES-SUMMARY.md。

---

## BLOCKING

無。

---

## 逐 NOTE 表

| NOTE | 工人處置 | 處置對嗎 | 證據判定與落點 |
|---|---|---|---|
| STALE R1-N1 RAW_DIR 無聲轉向 | NO-OP，殘留走 R2-C | 對 | round.env:32 已 unset【讀】。lib 外的讀者見 Q-N10 |
| R1-N2 case 3 沒資料也綠 | FIX | 對 | SUPPORTED：RF:47-54、K/n2_head_empty.out:11-13【讀】 |
| R1-N3 fixture 首列／sha | NO-OP | 對 | 前一輪 judge R2 已判 SUPPORTED【讀】 |
| R1-N4 大括號計數殘項 | DOC | 可接受，理由偏弱（Q-N12） | 寫在 L:260-262【讀】。「語料掃描」沒有 log：UNDER-EVIDENCED |
| R1-N5 刪除帳 | NO-OP | 對 | 前一輪 R2 已判 SUPPORTED |
| R1-N6 CI 群組數 | NO-OP，仍開放 | 對 | 要真的 CI run 才能驗；S §6 有列 |
| R1-N7 round.env 碰主 checkout | DOC | 對，修法在未授權的 round.env | not_tee:39-44【讀】。S 引的「見 §3 觀測」不存在；我用 Glob 確認主 checkout 的 `.test_run/binaries/e-round` 與 `…/raw` 都在，`mkdir -p` 確實是 no-op【讀】 |
| R2-A（優先項） | FIX | 對 | 缺陷已除，SUPPORTED：RF:13、:14、:16、:30；G/mutate_l1:40。殘留見 Q-N3 |
| R2-B | FIX | 對 | SUPPORTED：RF:17-18。新產生的偽綠方向見 Q-N4 |
| R2-C | FIX | 對 | SUPPORTED：RF:34-44；not_tee:86-95；G/mutate_gate_exit_code:18 |
| R2-D | NO-OP，在 S §5 更正並重跑 | 對 | 我核對過：S §5 引的行號正確（log_suffix:189-190、:201、:211；cell_gate:62）【讀】；兩支都重跑 13/0、0 survivor |
| R2-E | DOC | 對 | 寫在 L:266-270；arith 在 L:318-319 讓含 `/` 的式子直接回 9【讀】 |
| R2-F | FIX | 對 | SUPPORTED：RF:21、:22、:28。殘留見 Q-N4 |
| R2-G | FIX | 對 | SUPPORTED：RF:23、:25。殘留：導向檔案的「呼叫行」沒管（Q-N3） |
| R2-H | FIX | 對 | SUPPORTED：RF:26。殘留見 Q-N4 |
| R2-I | FIX | 對 | SUPPORTED：mutate_gate_exit_code:19；mutate_l1:43-57。R2、R17 沒有常駐 mutant（Q-N5） |
| R2-J | DOC | 可接受 | 理由只駁倒「天真的 regex」（Q-N12）。:331-332 引號內確有 `<<`【讀】；「見 §3 觀測」不存在 |
| PSTUB N1 | DOC | 對 | 寫在 LIB:17-22 |
| N3 | FIX | 對 | SUPPORTED：RF:76-80；MP:115-116；mutate_probe_stubs:22、:25-35 |
| N4 | FIX | 對 | SUPPORTED：mutate_probe_stubs:19-22；RF:111-117；K/n4_C1、C2、C3.out |
| N6 | FIX | 對 | SUPPORTED：LIB:126-131；RF:56-64；mutate_probe_stubs:34-35 |
| N7 | DOC | 可接受 | 寫在 LIB:59-63 |
| N8 | DOC（OPEN） | 揭露誠實，但這是把真缺口延後，沒有 ticket 編號 | 寫在 MP 檔頭（diff:496-501） |
| N9 | NO-OP（repo） | 對 | driver 已經每個 gate 各設 NOLAB_SUITE（scripts-queued3/gates_queued.sh:43），tripwire 那一行因此能歸屬 |
| a | DOC | 對 | cell_gate:45-52；honesty:62-72。`sudo()` 在 :316、:383、:399 回 1，:1336 回 0【讀】 |
| b | DOC | 對 | MP:67-70 |
| c | FIX＋DOC | 對 | SUPPORTED：RF:82-92；MP:71-79 |
| d | FIX | 對 | SUPPORTED：RF:66-74；MP:251-271 |
| e | FIX | 對 | SUPPORTED：RF:94-102；K/e_drift_HEAD.out:10、:18 |
| f | DOC | 對 | LIB:32-34 |
| g | NO-OP | 對 | LIB:19 早已列出 curl :8000 |
| h＝第 3 項 | 只改註解 | 對 | 逐 hunk 核過都是註解（§7）。過時的行號引用見 Q-N2 |

---

## 1. Triage 的結論

- **處置本身**：沒有一列判錯。我也沒找到「在語料上已知會判錯的缺陷」被藏進 DOC 或 NO-OP。
- **理由偏弱的兩個 DOC**（Q-N12）：
  - R1-N4：大括號計數。
  - R2-J：heredoc。
  - 兩者都只證明了「天真的修法更糟」，沒有證明「沿用 `commands()` 已有的引號追蹤」不可行。
- **真缺口延後**：PSTUB N8 如實標為 OPEN，但 S 只寫「另開 ticket」，沒有編號。
- **DOC 的落點**：每個 DOC 都寫進了讀者會讀到的 suite、lib 或 gate 檔頭。D、g 的更正只在 S §5，那是 scratch 報告，可以接受。

---

## 2. 每個 FIX

### 在原定義上已關閉

red first 都在 queued3，b005bf50 與 HEAD 並排，理由正確【讀】：

| FIX | b005bf50 | HEAD | 理由對嗎 |
|---|---|---|---|
| A | RF:13 topo 刪 :305 後 `nonzero`（空洞地綠）；r01 RF:14、r03 RF:16、r17 RF:30 都是 `nonzero` | `fail(call)`／`fail(body)`／`fail(call)` | 對：HEAD 的 actual 點名 call／body 規則 |
| B | RF:17-18 `fail(2a)`（偽紅） | `nonzero` | 對 |
| F | RF:21、:22、:28 `zero` | `nonzero` | 對 |
| G | RF:23 `nonzero`；RF:25 `nonzero` | `zero`；`fail(2a)` | 對 |
| H | RF:26 `nonzero` | `fail(2a)` | 對 |
| C | K/c_suite_lib-base.out:1-3：`expected: unset / actual: /inherited/raw` | RF:43 `ok case 6 … (9 passed, 0 failed)` | 對 |
| R1-N2 | K/n2_base_empty.out:10：case 3 綠，而 case 1、1b、2、4 同時是紅的 | RF:51：`reported-success \| gate rc 2 \| …verdict=UNRUNNABLE` | 對 |
| N6 | RF:57-60：rc 0，suite 照綠 | RF:61、:63 紅在 `the tc/ovs-vsctl on PATH is`；K/n6_head_P10.out:2-19 其餘全綠、只有 closing check 紅 | 對 |
| d | RF:67-70 `(the contract held)` | RF:71、:73 點名破口 | 對 |
| N3 | RF:77 `caught … actual: 13 tc qdisc show` | RF:79 `SURVIVED (…not on "sudo ovs-vsctl list-br"…)` | 對 |
| c | RF:84、:86 rc 2 | RF:88、:90 rc 2，並點名 P4 | FIX 的部分只有「點名 P4」 |
| e | RF:95：lib 錨點 0；356d4e4e 時 rc 0 | K/e_drift_HEAD.out:10 `x0`、:18 `MISSING:1` | 對 |
| N4 | — | RF:112、:114、:116：三份被弄壞的 gate 副本都在指名的控制組 rc 2 拒絕 | 對 |

### 殘留的變體（都不是本分支引入，除非另註）

- **A**：一個函式的所有行首呼叫都不見時，它的 print 退回定義行、算綠路徑（Q-N3）。
- **B（本分支引入）**：失敗分支裡「`&&` 接在非 print 指令後面的 exit」現在讀成條件式，也就是偽綠方向（Q-N4）。
- **F**：一行函式裡 `{ case … in 0) echo` 認不出來；`function f {` 不進 func_of。
- **G**：print 函式的「呼叫行」導向檔案時沒有排除。
- **H（`;;` 那半是本分支引入）**：一行寫成 `… ;; esac; exit 1` 或 `…; else …; fi; exit 1` 時，會停在 `;;` 或 `else`，看不到後面一定會跑的 exit（Q-N4）。
- **C**：lib_e.sh 之外直接 import plot_figures 的讀者仍可被無聲轉向（Q-N10）。
- **d**：契約裡 sudo 和 tc 的 `type -P` 檢查從沒看過紅，只有 ovs-vsctl 那一條有 T3（Q-N5）。
- **N3**：why 只取第一行 actual，而且用子字串比對。方向是 fail-loud 或極窄的誤判，可以不管。

---

## 3. test_l1_shell_scoring 的 group C 與 group R

### 3.1 五支真實 suite 的讀法

HEAD 的讀法按 L:431-480、:509-541【推】：

| suite | 失敗路徑的寫法 | HEAD 讀未突變的檔 | 拿掉綠 summary 後，HEAD 怎麼判 | 同一突變在 b005bf50 |
|---|---|---|---|---|
| test_ndt_ovs_topo_script.sh | :36、:51 是 `\|\| {…; exit N; }`；:46 函式；:70 `summary; exit 1`；:305 `summary` | 36→2a、46→305/0、51→2a；判 nonzero | 刪 :305：46→70/call，fpline=70，判 fail(call) | nonzero（空洞） |
| test_faults_topo_pid.sh | :36 grouped；:441 一行 if | 36→2a、441→2a、442→0 | :442 弄壞：fpline=441，判 fail(2a) | 同樣 fail(2a) |
| test_ndt_down_stops_only_ours.sh | :40、:44、:120、:121、:225 都是 grouped | 全部 2a，245→0 | 刪 :245：fpline=225，判 fail(2a) | 同樣 |
| test_mutate_gate_dead_mutant.sh | :277 echo，:278 `(( FAIL == 0 )); exit` | 277→0、299→0 | 刪 :299：last=277，後面沒有行首 exit，判 nonzero（偽綠，已申報） | 同樣 |
| test_run_layers_asks_kernel.sh | :43 `done_(){…; exit $?; }`；:47-49 多行失敗分支 | 43→229/0（`exit $?` 屬 other）、48→0 | 刪 :229：沒有呼叫，43→43/0、48→0，last=48，(2b) 在 :49 → 紅 | 同樣 |

**結論【推】**
- 在現有語料上，新規則沒有把任何一支從紅翻成綠。唯一的差異是 topo 從空洞地綠變成紅，正是 NOTE A 的修法。
- 我 grep 過語料：summary 形狀的 print 後面同一行的 exit，一律是 `; exit N`；沒有 `&&`、pipe、檔案導向、case pattern 的形狀【讀】。所以 B、F、G、H 的改動在語料上都不起作用。
- run_layers 刪掉 `done_` 後會紅，靠的是 :47-49 那段多行失敗分支。換成一行寫法的 suite 就會是 Q-N3 的偽綠。
- 全語料 63 支的「舊 vs 新」鑑別矩陣沒有人跑過【跑】（見文末）。

### 3.2 bbb9fd41 的 fpline 修正與 r17

- **修正是對的【推】**：L:521-524 取 effective line 最大的失敗列，和 `last` 的取法一致；同一行時取後讀到的。
  - 這只改「點名哪條理由」，不改紅或綠：只要有任何綠列，fpline 就不會被使用。
- **r17 是真的釘子【推】**：舊邏輯下讀到的順序是「6/call（由定義行 :2 讀到）」再「4/2a」，所以會報 `(the last at line 4)`；新邏輯報 line 6／call。
- **對這個 bug 看過紅的證據**：
  - 「修正前紅、修正後綠」是在 NOTE A 的語料 mutant 上看到的：queued2 G/mutate_l1_shell_scoring.queued2-01da86bc.log:40 以錯的理由 SURVIVED；queued3 :40 為對的理由 KILLED【讀】。
  - R17 本身從沒對這個 bug 看過紅。RF:30 的紅是 b005bf50 根本沒有 call 規則造成的。
  - gate 裡也沒有「把 `(( n >= fpline ))` 改回無條件」的 mutant（Q-N5）。

### 3.3 S §6 的已知限制：誠實，但不完整

- **漏列 1：函式完全沒有被看到的呼叫**。L:478-479 會退回定義行、判綠，是偽綠方向。L:264-265 只寫了「不在行首的呼叫看不到」，沒寫方向，也沒寫「完全沒呼叫」這種情況（Q-N3）。
- **漏列 2：B、H 新產生的偽綠形狀**，見 Q-N4。
- **漏列 3**：`function f {` 不在 func_of 裡；導向檔案的呼叫行沒有排除。
- **標題說法不對**：L:247 說「each a shape the corpus does not have today」，但它底下列的 SELFTEST_INNER（dead_mutant:275-279）和大括號範圍移動（兩支 suite）本來就在語料裡。準確的說法是「今天的語料上都不會改變判定」。

---

## 4. 三個 mutation gate

### 4.1 數字

- mutate_l1：36/36。
- mutate_probe_stubs：14/0，另有 C1–C3 三個控制組 ok。
- mutate_gate_exit_code：6/0。
- 以上【讀】各 log 的末行。

### 4.2 「每一條都殺在指名的 check、為指名的規則」

- 只對 23/36 成立：8 個語料 mutant 加 15 個規則 mutant。
- 另外 13 個 driver 突變（mutate_l1:14-30）沒有指名 check，任何紅都算殺。這些是既有的，但 S §2、§3 說「每一條都印出指名的 check 與理由」：CONTRADICTED【讀】（Q-N7）。

### 4.3 抽五個 mutant 驗「為對的理由被殺」

1. **NOTE A 語料 mutant**（mutate_l1:245-247）：
   - 殺在 `C test_ndt_ovs_topo_script.sh`，理由 `every call of which…`（log:40）。
   - trace：70 是最大的失敗列，規則是 call【推】。在 queued2 它為錯的理由存活，證明 because 欄真的有鑑別力【讀】。
2. **`ok = calls`**：
   - R1 紅，理由是 `nonzero`（log:48）。
   - trace：calls=[5] 全被當成 ok，得 (5,"0")；(2b) 後面沒有 exit，所以 nonzero【推】。
   - 同時 R17 也紅，所以是「2 check(s) red」。
3. **拿掉 `;;` 條件**：
   - R15 紅，理由是 2a（log:56）。
   - trace：`*) exit 1` 經 strip_head 變成必然的 exit【推】。
4. **P10**：
   - caught 在 `the tc on PATH is`（mutate_probe_stubs:34）。這個字串只有新加的 LIB:127 會產生。
   - K/n6_head_P10.out:2-19 其他 18 條全綠【讀】。
5. **T2**：
   - caught 在 `sudo -n true was not recorded by the stub`（:40）。只有 MP:265 會產生這句。
   - b005bf50 的契約在同一個突變下照樣成立（K/d_base_T2.out 為空）【讀】。
6. **（加碼）mutation 5**（mutate_gate_exit_code.sh:128）：
   - 刪掉的就是 lib_e.sh:50 那一行。
   - 殺的判準要求 `FAILED   case 6`（:79）；base lib 下 actual 是 `/inherited/raw`【讀】。

### 4.4 紅 baseline 必須被拒絕

- **mutate_l1**：L:60-66 會 exit 2。前一輪 judge 已經看過它紅【讀】。
- **mutate_gate_exit_code**：:96-103 在 `grep '0 failed'` 失敗時判 harness fault。
  - 這是子字串比對，「10 failed」也會通過；以目前 9 條 check 碰不到，是 NOTE。
  - 本輪沒有觀測到它拒絕：UNTESTED。
- **mutate_probe_stubs**：MP:125-130 的迴圈看到 refused 就 exit 2。
  - baseline_rule 的兩個分支都看過觸發：C1，以及 n4_C1.out:11。
  - 但迴圈本身的 exit 2 沒看過。S 說「N4 那一行就是看到它 rc 2」，那一行是控制組的拒絕，不是 baseline 的拒絕：UNDER-EVIDENCED【讀】。

---

## 5. PSTUB N3 與 e

- **N3：SUPPORTED**
  - b005bf50 的 P1–P7 呼叫 report() 時沒帶第 4 個參數，所以紅在別的呼叫上也算 caught。RF 的 base 臂用同樣的呼叫方式重現了：RF:77。
  - HEAD 的 P1–P7 都帶上被拿掉的那一項（MP:191-209），mutant_rule 在 :115-116 判 SURVIVED（RF:79）。
  - C3 每次跑都觸發這個分支（mutate_probe_stubs:22）；把 C3 弄壞時 gate 會拒絕（K/n4_C3.out:13）【讀】。
- **e：SUPPORTED**
  - HEAD 的 T1–T3 經 `mutant()` 帶具名的 `$LIB`（MP:291-296）。
  - K/e_anchors_HEAD.out:9-11 有三條 lib 錨點，anchors 為 `ok(11)`（G/check_gate_anchors:115）。
  - 拿 356d4e4e 的檔案去數，T1 錨點是 `x0`，結果 MISSING（K/e_drift_HEAD.out:10、:18-25）；b005bf50 的 gate 在同樣檔案上照樣 ok(7)（K/e_drift_b005bf50.out:13）【讀】。

---

## 6. lib_e.sh 的 `unset NDT_SAMPLING_RAW_DIR`

- **會不會弄壞合法設定了它的真實 round：不會【讀】**
  - 整個 WT 只有 plot_figures.py:49 讀這個變數；只有 not_tee:84、:92 設它（grep）。
  - round.env:32 早就無條件 unset。本分支只是把「ROUND 已設、跳過 round.env」那條路補上：gates_e.sh:37/41、run_e.sh:37/41、build_1khz_binary.sh:43/46。
  - lib_e.sh 在 source 時沒有別的副作用：頂層只有指派和函式定義，:35-100。
  - 沒有任何腳本 pin lib_e.sh 的 sha。
- **test seam 還能不能用：能【讀】**
  - not_tee 在 :80 source lib_e.sh，:84 才 export。
  - case 1b 斷言 `ratio=1.0000` 並且是綠的（G/test_gate_exit_code_not_tee:12），證明 seam 真的讀到 fixture。
  - ratio_gate.py:47-53 以自己所在的相對路徑 import plot_figures，所以 mutation 6 改到的正是被讀的那份【讀】。
- **小瑕疵**
  - unset 是無聲的。
  - 模擬用的是指令序列（RF:94-100），不是 `gates_e.sh` 的 DRY_RUN（Q-N10）。

---

## 7. sudo_surface.sh

- **只改註解：SUPPORTED【讀】**。diff 的四個 hunk（:51-73、:129-130、:150-154、:196-197），每一條 `+`／`-` 行都以 `#` 開頭。
- **新註解和程式碼一致【讀】**
  - ndt_sudo_probe 在 SS:194-198：capture 失敗後，`ndt_sudo_refused` 認得就回 1，否則回 0。
  - 它的答案決定 ndt:6938-6947 的 sudo grants 行和 problems。
  - dataplane_ok（ndt:6094-6100）、sflow_why（ndt:6237-6243）的判定取自 rc，字句只選措辭。
  - guard_no_live_ovs（ndt:6031-6040）的判定取自 rc。
- **不精確之處（Q-N11）**
  - ovs_bridge_count（ndt:5999-6005）根本不用分類器。
  - guard_no_live_ovs 的措辭其實是經過 ndt_sudo_probe 選的。
  - ovs_sample_rate（ndt:2177-2180）也是只看 rc 的呼叫端，但沒列進去。
- **`sorry, you must have a tty` 會被讀成 granted：SUPPORTED**
  - 【讀】SS:160-168 的五種字句都不是它的子字串，於是落到 :198 `return 0`。
  - 工人實跑也看到了：RF:107；K/h_probe.out:3（假 sudo，不 exec 任何東西）。
- **`sudo: mnexec: command not found` 對不上第五種樣式**：`*"sudo: command not found"*`（:166）要求字面一致。SUPPORTED【讀】。

---

## 8. Lab 接觸

- **queued3 的那一行**
  - 是 `redfirst_queued queued3 ovs-vsctl list-br`（scripts-queued3/tripwire.log:1）【讀】。
  - 來源是 b005bf50 的 stub_contract 無條件執行 `ovs-vsctl list-br`（diff:770 被刪的那一行）。T3 沒寫出 ovs stub，呼叫就落到 driver 的 shim。
  - shim 只放行 ` show `、` list ` 等唯讀形式，`list-br` 不符合，所以被拒絕、rc 1、沒有 exec（make_shims.sh:48-53）。
  - 非特權，也不算 lab 呼叫；nolab_tripwire:21-22 判 0 次 lab 呼叫。
  - HEAD 的契約只在 `type -P` 就是 stub 時才執行（MP:267-270）。
- **新 fixture 或新測試不可能碰到 lab【讀】**
  - fixture 是 100644 權限，只被 Python 讀、從不執行。
  - case 6 只 source lib_e.sh，沒有副作用。
  - P10、P11 擋在前面的那支腳本不 exec 任何東西。
  - HEAD 的契約不碰不是 stub 的指令。
  - C1–C3 和既有的 P8、P4、P7 是同一種形狀。
- **但 S 的 lab 帳不完整**：queued2 的 tripwire 另有 8 行 `test_apps_stop_kills_the_group queued2 sudo -n /usr/local/sbin/ndtwin-lab status`（scripts-queued2-01da86bc/tripwire.log:2-9）【讀】。全部被 shim 拒絕，所以沒有實際碰到 lab，但 S 完全沒提。成因與風險見 Q-N1。

---

## 9. 數字對帳

**對得上的【讀】**
- 113＝33＋R 17＋C 63（test_l1:142；R 在 :59-75，C 在 :78-140）。
- 36/36；9/0；6/0；14/0。
- 各 suite：72／19／104／346／7／13／30／12／11／12；各 gate：13／22／67／35(+3,+16)／3／14／7／6／7／6。
- anchors 121/121，其中 ok(34)／ok(11)／ok(6)／ok(13)。
- tripwire 0；driver `GATES-QUEUED3 … ALL-AS-EXPECTED`，outer rc 0（gates_queued3.run.txt:35-37）。

**不一致或無據的地方**
- S §3「queued2 的 redfirst 有 4 個 BAD 是 harness 的錯」：log 裡 harness 造成的 BAD 有 7 行（redfirst queued2:44、48、50、54、98、101、102），另有 1 行是真缺陷（:14）。CONTRADICTED。
- S §3「由 .kept 看得出程式行為相同」：e 段在 queued2 的輸出是 usage error（queued2.kept/e_anchors_HEAD.out:1-5），支持不了這句。
- S §2、§3「每一條都印出指名的 check 與理由」：CONTRADICTED，見 §4.2。
- S §0 兩處「見 §3 觀測」（R1-N7、R2-J）：§3 沒有這些觀測，是懸空引用。
- S §0 R1-N4 的「語料掃描」：沒有 log。
- 「385（含 17 個新 fixture）」：log 只有 385 這個數。
- devbatch1「16 條 R 全部 instrument failed」：log 只有 16 行 FAILED，沒有 actual 行。紅：SUPPORTED；理由：UNDER-EVIDENCED。
- S §1a 寫「16 個 fixture」：那是 46ff44ce 時的數，HEAD 有 17 個。

---

## NOTE

- **Q-N1（最優先，trunk 既有，另開 ticket）：被 TERM 之後，stub 被刪掉，suite 卻照跑**
  - 【讀】test_apps_stop_kills_the_group.sh 的結構：
    - :71、:82 把 stub 裝在 TMPROOT 裡；
    - :187-202 的 cleanup 會 `rm -rf "$TMPROOT"`，然後 `return 0`；
    - :204 是 `trap cleanup_fixtures EXIT INT TERM`。
  - 【讀】test_ndt_app_orphans.sh:75、:86、:120-123 是同一個形狀。
  - 【推】後果：收到 TERM 或 INT 時，trap 刪掉 stub 之後不會 exit，suite 繼續往下跑，之後的 `sudo` 就落到 PATH 上的下一支。
    - queued2 那次是 shim，所以 8 行都被拒絕，而且 closing check 事後才紅在 `NO STUB`（queued2 log:148-150）。
    - 離開 nolab driver，在有 ndtwin-lab NOPASSWD 的機器上（本機就是），這些呼叫會帶著 root 真的去問 lab。
  - 【推】因此有兩處註解不成立：
    - LIB:2-3 的「no call it makes can reach root」。
    - LIB:122 的「probe_stub_install never ran」歸因錯誤：它跑過，只是 stub 被刪了。
  - 本分支沒有引入這個問題。但 S 的「沒碰 lab」和 tripwire 帳要補上這 8 行。
- **Q-N2（本分支引入，建議合併時修）：過時的行號引用**
  - 註解加了行，sudo_surface.sh 的行號因此整體下移。
  - LIB:27、:78 引 `sudo_surface.sh:179-182`，實際已移到 :194-198。
  - LIB:41 引 `:176-177`，實際已移到 :191-192。
  - WT/doc/KNOWN-ISSUES.md:4706 引 `:88`，實際已移到 :100。
  - 【讀】改成寫函式名，或更新行號。
- **Q-N3（NOTE A 殘留，【推】）：函式完全沒有被看到的呼叫**
  - 這時會退回定義行並算綠（L:478-479）。
  - 一支 suite 的 summary 函式只有最後那一個呼叫，而其他失敗路徑都寫成一行時，刪掉那個呼叫就是偽綠。今天的語料裡沒有單一編輯就會碰到的例子。
  - 建議：函式名在自己的本體之外完全沒出現，就判紅（「defined, never called」）。這樣不會誤傷 `trap summary EXIT` 或 `|| summary`，因為它們的名字還在。
- **Q-N4（B、H 帶來的新偽綠形狀，語料都沒有，【推】）**
  - 失敗分支裡的 `…; cleanup && exit 1` 現在會被讀成條件式。L:230 寫「after a test」，但程式實際上是「接在任何不是 echo／printf／tee／true／: 的指令之後」（L:430、:465-466）。
  - 一行寫法的 `…;; esac; exit 1` 會停在 `;;`（L:436-437），看不到後面的 exit。
  - L:247 的標題說法也要改，見 §3.3。
- **Q-N5（mutation 覆蓋的缺口）**
  - R2、R17 沒有常駐 mutant。
  - 契約裡 sudo 和 tc 的 `type -P` 檢查從沒看過紅。
  - mutate_probe_stubs baseline 迴圈的 exit 2，以及 mutate_gate_exit_code 對紅 baseline 的拒絕，本輪都沒有觀測到。
- **Q-N6：case 6 在 CI 上的紅看不到**
  - 【讀】not_tee 在 :101-104 印 SKIP 之後 `exit 0`，lane 在 l1_unit_tests.sh:505 統計 SKIP 行，判定成 FAIL-SKIP（:133）。所以 case 6 紅了，CI 的判定也不會變。
  - S 說「CI 也跑得到」：跑得到是真的，但它不能獨自讓 CI 變紅。建議 SKIP 分支改成 `exit $(( FAIL > 0 ))`。
- **Q-N7**：S 的數字與措辭錯誤，全部列在 §9 和 §4.2。
- **Q-N8：queued2 的 log 沒有在檔內標記**
  - 17 份 queued2 log 只有 test_apps_stop 一份標了 ABORTED。
  - redfirst（rc 1）、mutate_l1（35/1）等其餘 16 份，檔內沒有「probe／superseded」字樣，只有 S 裡提到。
  - queued（77448f70）有標 ABORTED，其 tripwire 為空【讀】。
- **Q-N9：mutate_gate_exit_code 會就地改寫另一個 round 的 plot_figures.py**
  - 它改的是 working tree 裡的檔（:45-47、:134），不是 sandbox 副本。
  - 被 kill -9 時突變會留在磁碟上。以這次的突變內容，對正式量測在行為上等價，但範圍確實比以前大了。
- **Q-N10：NOTE C 的殘留**
  - unset 是無聲的。一個刻意設定的值被丟掉時，沒有任何訊息。
  - wall_f.sh（08-25 round）、plot_ladder_rates 直接執行時仍會被轉向。
  - 建議在 plot_figures 被覆寫時把 RAW 印到 stderr，也就是前一輪 N1 提過的另一個選項。
- **Q-N11**：sudo_surface.sh 新註解列舉的呼叫端不夠精確，見 §7。
- **Q-N12**
  - R1-N4、R2-J 的 DOC 理由只排除了天真的修法。
  - PSTUB N8 需要一個真的 ticket 編號。
- **Q-N13（外觀）**
  - L:201 的 group C 標題現在印在 group R 前面，下面是空的（test_l1 log:56-58）。
  - RF:96 在 HEAD 那一行抓到的是明細行，不是 ok(11)。

---

## 我會跑、而報告沒跑的

1. **全語料 63 支，b005bf50 對 HEAD 的鑑別矩陣**：每支都做「弄壞最後一個綠 summary」和「刪掉它」；函式型 summary 的 suite 再加「刪掉全部呼叫」。列出所有紅翻綠的情況。
2. **兩個新 mutant**：
   - 把 L:522 改回 `fpline="$n"; fprule="$rule"`，預期 R17 紅，actual 是 `(the last at line 4)`。
   - 把 L:477 改成 `ok = []`，預期 R2 紅。
3. **新增殘留形狀的 fixture，先看它們判綠**：
   - 一個從沒被呼叫的 summary 函式；
   - `then summary; exit 1` 的一行寫法；
   - `then echo "Ran…"; cleanup && exit 1; fi`；
   - `case … in *) echo "Ran…" ;; esac; exit 1`。
4. **用真的腳本驗 NOTE C**：`. round.env; export NDT_SAMPLING_RAW_DIR=/x; DRY_RUN=1 bash gates_e.sh`，確認 cell_verdict 和 ratio_gate 讀的是 round 自己的 raw。
5. **驗 Q-N6**：沒有 PY_PLOT、並且拿掉 lib_e.sh:50 的情況下跑 not_tee，確認 rc 0，lane 判 FAIL-SKIP。
6. **驗 Q-N1**：在「PATH 上第二支 sudo 是紀錄器」的環境下，stub 裝好之後對 apps_stop、app_orphans 的 process group 送 SIGTERM，數紀錄器收到幾行。修好 trap（`exit 143`／`exit 130`）之後，要求 0 行。
7. **紅 baseline 的拒絕**：讓一支 suite 非漏出地變紅，mutate_probe_stubs 應該 rc 2；讓 not_tee 變紅，mutate_gate_exit_code 應該 rc 2。
8. **契約 mutant**：sudo stub 沒寫出來、tc stub 沒寫出來各一個，契約都必須點名。
9. **合併後實際跑一次 CI。**

---

## 相關檔案

- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/QUEUED-NOTES-SUMMARY.md`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/queued/diff-7746832e..bbb9fd41.patch`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/tests/shell/test_l1_shell_scoring.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/tests/shell/mutate_probe_stubs.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/tests/shell/lib_probe_stub.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/tests/shell/test_gate_exit_code_not_tee.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/tests/shell/test_apps_stop_kills_the_group.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/tests/shell/test_ndt_app_orphans.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/tools/test_workflow/sudo_surface.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-notes-0927/doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/redfirst_queued.queued3-bbb9fd41.log`（以及 `.kept/`）
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-queued2-01da86bc/tripwire.log`
- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/test_apps_stop_kills_the_group.queued2-01da86bc.log`