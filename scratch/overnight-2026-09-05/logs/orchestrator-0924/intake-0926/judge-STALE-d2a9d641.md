# judge-STALE-d2a9d641 (fix/stale-suites-0927 @d2a9d641)

**判決：MERGE AFTER FIXES**（必修一項：B1。其餘都是 NOTE）

b1 和 b2 的證據站得住。b3 的 baseline 拒絕、以及「runtime scorer 把 12 支都讀對」也站得住。

問題在 b3 的核心宣稱「新的 group C 至少和舊的一樣有鑑別力」。這句話只在表裡那兩支 suite 上被證明過。我照原始碼推：語料裡至少有四支 suite，舊檢查抓得到 M1 型缺陷，新檢查抓不到。mutation gate 的四個語料 mutant，全都是新規則本來就抓得到的形狀。修法小，而且 red first 現成。

以下所有結論都是讀檔得來，我沒有執行任何東西。沒讀 judge-SGE-d271f5b8.md；RULINGS 只讀了 b1–b3 那幾列（:12-15）。

路徑縮寫：
- S＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/STALE-SUITES-SUMMARY.md
- P＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/stale/diff-8746c1bc..d2a9d641.patch
- WT＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-stale-suites-0927（其中 tests/shell 簡寫為 ts）
- G＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910（未另註者都是 `*.stale-d2a9d641.log`）
- CI＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926

---

## BLOCKING

### B1：規則 (2) 看不到同一行的 exit，「至少一樣有鑑別力」被語料本身反駁

**判定**
- S:75 的一般宣稱：CONTRADICTED。
- S:73 和程式註解 WT/ts/test_l1_shell_scoring.sh:219-221 都說，規則 (2) 保住了「只剩失敗路徑的 `...; exit 1`」這種形狀：UNTESTED，而且照讀碼推並不成立。

**機制**
- :293 的 awk 只找「last 之後的行」、而且是「行首」的 `exit [1-9]`【讀】。
- 所以下面這些都看不到：同一行的 `…; exit 1; fi`、`|| { …; exit 1; }`、`exit $FAIL`、不帶數字的 `exit`【推】。
- 另外，:258 用 `re.finditer` 配貪婪的 `(.*)$`，一行只會渲染第一個 print【推】。

**反例**

這四支在 8746c1bc 都不在被舊檢查判紅的 12 支裡（G/diag_b3…log:11-22；WT 的 diag_b3.sh:19-21）【讀】。也就是說，舊檢查對它們本來是有鑑別力的。

1. **ts/test_faults_topo_pid.sh:441-442**
   - 失敗路徑寫成一行：`if (( FAIL > 0 )); then echo "Ran …"; exit 1; fi`【讀】。
   - 把 442 換成 `echo "everything is fine"`，也就是 gate 的 M1。
   - 新 C：last＝441，全檔沒有任何行首 `exit [1-9]`（Grep 計數沒有列出此檔）→ nonzero → 綠。
   - 舊 C：取最後一個 `^ *echo "…"`，也就是 442 → zero → 紅【推】。
2. **ts/test_ndtwin_lab_config.sh:292-293**：同一形狀【讀】，結論相同【推】。
3. **ts/test_ndt_down_stops_only_ours.sh:120-121、225**
   - 寫法是 `|| { echo "Ran 1 checks, 1 failed"; exit 1; }`，該行第一個 print 就是 summary，所以會計分【讀】。
   - 把 245 弄壞或刪掉 → last＝225，全檔沒有行首 exit → 綠【推】。
   - 連 M2（兩個 summary 都拿掉）都會放過。
4. **ts/test_mutate_gate_dead_mutant.sh:277-278**
   - 這是 SELFTEST_INNER 分支的 summary，後面接的是 `(( FAIL == 0 )); exit`，exit 不帶數字【讀】。
   - 把 299 弄壞 → last＝277 → 綠【推】。

**報告的證據只涵蓋兩支**
- test_faults 的 exit 是獨立一行（ts/test_faults.sh:313-316）；另一支是 test_stack_log_rotation（G/redfirst_stale…log:50-60）【讀】。
- M4 的構造讓 `exit 1` 獨立成一行（P:403-404）【讀】。同樣語意的一行寫法 `[[ … ]] && { printf …; exit 1; }` 會存活【推】。

**最小修法**
1. 若一個計分的 print 在同一行、在它之後還有 `exit <非零>`，就把它當成失敗路徑，不能當 last。
2. 加一個一行形狀的語料 mutant，例如把 M1 套在 ts/test_faults_topo_pid.sh:442。
   - 先在 d2a9d641 看到它 SURVIVED，這就是 red first。
   - 修完後它要變 KILLED，而且 M0 全語料仍是 63/63 綠。
3. 更正 S:73、S:75 和 :219-221 的說法。
4. 「exit 不帶數字」那一種，如果這次不處理，就寫進已知限制。

---

## 1. (b1)

### 舊 13 條逐條對照
- **#1 rotated to .prev、#2 .prev holds…**
  - 對應新 #1/#2（ts/test_start_bg_log_rotation.sh:62-63）。
  - test_stack_log_rotation 也有：3A（:84-93）、3F（:152-162）【讀】。
- **#3 current log fresh**：對應新 #3（:64），而且更嚴格；只有這支 suite 在測【讀】。
- **#4 first start、#5 empty**：對應新 :72、:82。只有這支在測，不在 84-122 範圍內【讀】。
- **#6、#9、#10**（三次 start_bg 在一秒內，看代的順序）
  - 現在只剩組合覆蓋：3F（一次 start_bg 呼叫一次 rotate_log）加 3E（同一秒兩次 rotate_log 不互蓋，:144-150）。
  - 兩者都在 84-122 之外【讀】。
- **#7、#11**（最新的一代在 live log）：由新 #3 覆蓋【讀】。
- **#8**（兩代時還沒有 .prev2）：由新 #1「exactly one」覆蓋【讀】。
- **#12**（有界）：由 3B :101、3C 覆蓋【讀】。
- **#13**（最舊的被丟掉）：由 3B :105 覆蓋【讀】。

**結論**
- 沒有仍然需要的契約斷言遺失【推】。
- 但 S:15 和 suite 註解 :16 引用的「84-122」不完整。取代舊的多次重啟那幾條的，是 :144-162 的 3E/3F。這是 NOTE。

### 其他判定
- **S1/S2：SUPPORTED。**
  - 兩個都殺在指名的 check 上（G/mutate_stack_log_rotation…log:20-21）【讀】。
  - report_bg 同時要求 rc≠0、且輸出含 `FAILED   <指名 check>`（ts/mutate_stack_log_rotation.sh:61-72）【讀】。
  - 兩支 suite 的 baseline 都綠（log:9-11）【讀】。
- **「O-4 以前綠、O-4 起紅」是否實跑：SUPPORTED。**
  - G/redfirst_stale…log:15-18。
  - kept 的 b1_hist_74c811dfp.out 是 13/13；b1_hist_74c811df.out 紅 6 條，全是 .prev/.prev2【讀】。
  - 腳本對每個 rev 都用 `git archive <rev> tools/test_workflow`（G/scripts-stale-d2a9d641/redfirst_stale.sh:33-41）【讀】。
- **刪除帳：數字 CONTRADICTED。**
  - S:23 和 suite 註解 :16-18 都說「六條刪除不補，另外三條也刪」。
  - 實際是 13→5：
    - 刪掉 8 條：紅的 #6/#9/#10/#13，綠的 #7/#8/#11/#12。
    - 紅的 #1/#2 是改成時間戳記後保留，不是「不補」【讀】。
- **有兩條從沒看過紅（NOTE）。**
  - #3：S2 底下 `>` 截斷後 live log 仍是新時期內容，所以照綠。
  - #4：對不存在的檔案 mv 會失敗（WT/tools/test_workflow/stack.sh:507），所以任何 start_bg 的 mutant 都殺不到它；S:33 自己也承認【推】。

---

## 2. (b2)

### NDT_SAMPLING_RAW_DIR
- **沒設的時候行為不變：SUPPORTED。**
  - `os.environ.get(...) or os.path.join(HERE,"raw")`（WT/doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py:49）。沒設或設成空字串，都回到原本的 raw/【讀】。
- **在 import 時讀：是。**
  - 它是模組層常數。cell_verdict.py:35 和 ratio_gate.py:53 都用 `from plot_figures import RAW` 綁定【讀】。
- **會不會外洩：從 suite 往上不會；但往下沒有任何防線。**
  - 這支 suite 在 :73 export，只影響它自己的子行程【推】。
  - 反過來，只要誰的 shell 裡設了這個變數，下列讀者都會被無聲地轉到別的目錄：
    - live E round 的 cell_verdict 和 ratio_gate；
    - `--make-forcered` 會把 forced cell 寫進 RAW（ratio_gate.py:101-128）；
    - plot_ladder_rates；
    - wall_f.sh 裡的 cpu_stats。
  - 同時 measure.sh 仍寫死寫進 08-20 的 raw/（lib_e.sh:1301-1302），於是「量到的 cell」和「被判的 cell」可以不是同一份。
  - gate 的輸出不印 RAW 路徑（ratio_gate.py:143-150；cell_verdict.py:99-110）；round.env 既不 unset 也不拒絕【讀】。
  - 列為 NOTE。建議隨 B1 一起加一行 `unset NDT_SAMPLING_RAW_DIR` 到 round.env：suite 在 :66 source round.env，到 :73 才 export，所以不會被這行破壞【推】。

### fixture 與真實 trace
- **走同一條 gate 路徑：SUPPORTED。**
  - 兩者都是 `verdict=GREEN mark=DATAPLANE-HURT`，都經過 ratio，都不是 UNRUNNABLE（G/redfirst_stale…log:31-41）【讀】。
  - fixture 的 panel 統計是退化的：distinct=2、spread=0。但 verdict()（cell_verdict.py:71-96）和 check()（ratio_gate.py:143-170）都不以這些值分支【讀】。
  - 小缺口：兩邊只跑了 `--expect green`（redfirst_stale.sh:71-74）。case 2 實際呼叫的 `--expect red` 沒有對真實 trace 跑過；由 GREEN 可推得結果【推】。
- **case 2 沒資料時紅、有 fixture 時綠：SUPPORTED。**
  - 空 fixture 的 kept 輸出 b2_head_nofixture.out:4-6，actual 是 `2 | …verdict=UNRUNNABLE`；b2_head.out:2 是綠【讀】。
  - 第一次 predict_ci 裡 gate 跑不起來，case 2 的 actual 是 `2 | `，照樣判紅（predict_ci.stale-d2a9d641.kept/not_tee.this-laptop.log:4-6）【讀】。
- **「8746c1bc 時 gate 說 UNRUNNABLE rc 2」：SUPPORTED（log:24-25）。**
  - 實際是用 HEAD 的 ratio_gate 加 `env -u` 跑的（redfirst_stale.sh:52-54）。這條 import 鏈上 diff 只改了 :49，所以等價【推】。
- **CI 仍然 SKIP 的紀錄：SUPPORTED，而且誠實。**
  - S:53-56 引的字句，與 CI/ci-36273687560-gcc.raw.log:6786-6787 一致【讀】。
  - 裁決書自己的理由是「SKIP 會讓 CI 永遠不跑它」（CI/RULINGS-0927-suites.md:14）。這個目的仍未達成，只是 SKIP 的原因從缺資料換成缺 PY_PLOT；S:176 已寫明【讀】。
- **「sha 與主 checkout 那份相同」（S:51）：UNDER-EVIDENCED。**
  - G/ 裡只有 audit-raw 那份的 sha（redfirst log:30）【讀】。
- **「是做出來的，不是複製的」：大致 SUPPORTED。**
  - 但 fixture 第一列的 t=1787658157.534 和 tx=3302，與主 checkout 真實 trace 第一列完全相同。對照 P:57 與 /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_twin.jsonl:1【讀】。
  - README 只揭露了 lost_percent 取自真實 cell。這是 NOTE。
- **封閉性沒有被斷言（NOTE）。**
  - 主 checkout 有 raw/t008_poll_*【讀】。
  - 如果覆寫失效，gate 會退回讀真實 trace（ratio 0.9656，仍是 GREEN），七條照綠。沒有任何一條確認讀到的是 fixture（例如 ratio=1.0000）【推】。
- **case 3 沒資料也是綠（NOTE）。** 同樣是「理由錯的綠」（b2_head_nofixture.out:7）【讀】。

---

## 3. (b3)

### runtime scorer 12 支都讀對：SUPPORTED
- 每支 scorer 的 ran 都等於 log 裡 ok＋FAILED 的條數，沒有 MISREAD（G/diag_b3…log:10-24；12 份完整 log 都保留）【讀】。
- 但書：test_build_guard 那一跑是紅的（37/15）。它的 FAIL-RC 只由 rc 決定（l1_unit_tests.sh:132），綠路徑的 summary 沒有在 runtime 看過。不過 37＝22＋15，至少證明 summary 被正確解析了【讀】。

### render_prints 是否健全
- **eval**
  - 允許字元限制在 `[0-9+\-* ()]`，可防注入（:252）【讀】。
  - 但沒有 try/except：`09`、`$(( ))` 會讓整支 Python 以 SyntaxError 中止；`**` 也在允許字元內【推】。
  - :289 不看 render_prints 的 exit status，stderr 也沒收。所以「儀器壞了」會被讀成 zero 或半套結果【讀＋推】。這正好違反 l1_unit_tests.sh:152-158 自己記下的教訓。NOTE。
- **函式呼叫的 effective line**
  - 只認同一行的 `name() {` 寫法（:233）【讀】。
  - :238 把字串和 regex 裡的大括號也算進去。例如 :255 是 1 個 `{` 對 2 個 `}`，render_prints 自己的函式範圍在 :255 就被判定提前結束【推】。
  - 呼叫必須在行首、而且不在任何函式裡（:246）；`|| f`、`trap`、由另一個函式呼叫，都會退回函式定義那一行【讀】。
  - 這些多半造成偽紅，不是偽綠。NOTE。
- **shlex／regex**
  - 註解不剝除、`$(echo …)` 也被當成 print【推】。
  - 目前語料裡沒有 usage()、heredoc 或註解形狀的 summary：我搜了 summary 形狀的 echo/printf，125 筆全是真 summary、guard 或 SELFTEST 分支【讀】。
  - 所以偽綠的實際來源就是 B1 那一類，不是 usage()。
- check 名稱「on its green path」（:296）宣稱了靜態檢查確立不了的事。NOTE。

### 鑑別力
- 表中六列：SUPPORTED（redfirst log:50-60）【讀】。
- 「拿掉規則 (2)」那一臂，是把 :293 換成 `bare=""`（redfirst_stale.sh:107-113）【讀】，確實證明 M1/M4 是規則 (2) 抓的。
- 一般宣稱不成立，見 B1。

### baseline 拒絕：SUPPORTED，red first 成立
- 8746c1bc 自己的 gate 在 8746c1bc 樹上：rc 0，14 killed，全部空洞。
- HEAD 的 gate 在同一棵樹上：rc 2，`refused … (12 check(s))`（redfirst log:46-49）【讀】。
- 實作見 P:334-341。HEAD 上 baseline 是綠的，17/17 全殺，四個語料 mutant 都殺在指定的 check 與規則上（G/mutate_l1_shell_scoring…log:9-10、32-37）【讀】。

---

## 4. CI 預測

- **合併後的樹上，三支 suite 的結果：SUPPORTED（本機觀察）。**
  - G/predict_ci.stale2-d2a9d641.log:9-22【讀】：
    - merge-tree 兩邊都乾淨，三邊改動的檔案（1/8/9）不重疊；
    - start_bg PASS 5；l1 PASS 96；
    - not_tee 沒有 PY_PLOT 時 FAIL-SKIP，有 PY_PLOT 時 PASS。
- **「CI 群組會消失，14→12」：UNDER-EVIDENCED，是推論。**
  - 沒有實際 CI run；CI 的 python3 是推的（S:130 自己標了）。
  - 基準 14 組在現在的 trunk 上成立：CI/ci-36279411773-gcc.raw.log:125 是 c34a643a、:6885 是 14 組【讀】。
  - (a) 會不會讓其他群組增減沒有量；trunk 的 L1 還列著 live_p1_common、manual_no_stale、mutate_gate_dead_mutant、ndt_ovs_topo_script（:6779-6837）【讀＋推】。
  - mutation gate、check_gate_anchors、check_test_tmpdirs 都沒在合併後的樹上跑（predict_ci.sh:44-47）【讀】。

---

## 5. 數字

**全部對得上【讀】**

| 項目 | 數字 | 出處 |
|---|---|---|
| test_l1_shell_scoring | 96/0（33＋C 群 63） | log:120 |
| mutate_l1_shell_scoring | 17/0（6＋4＋3＋4） | log:37 |
| mutate_stack_log_rotation | 9/0 | log:24 |
| test_gate_exit_code_not_tee | 7/0 | log:17 |
| test_start_bg_log_rotation | 5/0 | log:15 |
| mutate_gate_exit_code | 4/0 | log:21 |
| check_gate_anchors | 120/120 | log:135 |
| nolab_tripwire（兩份） | 0 | 兩份 log:21 |
| test_stack_log_rotation | 23/0 | log:45 |

- **不一致的地方**：只有 b1 的刪除帳（見 §1）。
- **看似不一致、其實不是**：mutate_stack_log_rotation 有 9 個 mutation，但 anchors 只有 ok(7)（anchors log:122）。M1、S1、S2 用的是同一段 anchor（ts/mutate_stack_log_rotation.sh:108-111、176-179、185-188），應是去重【推】。

---

## NOTE（不擋合併）

- **N1**：NDT_SAMPLING_RAW_DIR 設了就無聲轉向（§2）。建議在 round.env 裡 unset，或覆寫時把 RAW 印出來。
- **N2**：not_tee 沒斷言讀到的是 fixture；case 3 沒資料也綠（§2）。
- **N3**：fixture 第一列的 t/tx 取自真實 trace，README 沒揭露；「與主 checkout 同 sha」沒有 log（§2）。
- **N4**：render_prints 的 eval 沒有例外處理、允許 `**`、Python 中止不可見；函式範圍的大括號計數會錯；註解沒剝除（§3）。
- **N5**：b1 的刪除帳；「84-122」引用不完整；#3、#4 沒看過紅（§1）。
- **N6**：CI 群組數是推論，合併後要對 CI 輸出（§4）。
- **N7**：既有行為，不是這次引入的。not_tee 會 source round.env，而 round.env 寫死 KERNEL_DIR，並在主 checkout 底下 `mkdir -p` 兩個目錄（round.env:13-14、58、66）【讀】。多半是 no-op，但從 worktree 跑也會碰到主 checkout 的路徑。

---

## 我會跑、而報告沒跑的

1. B1 的四個反例，舊／新／修後三臂並排：
   - M1 套在 ts/test_faults_topo_pid.sh:442；
   - M1 套在 ts/test_ndtwin_lab_config.sh:293；
   - 刪掉 ts/test_ndt_down_stops_only_ours.sh:245；
   - 弄壞 ts/test_mutate_gate_dead_mutant.sh:299。
2. 全語料 63 支，每支都做「把最後一個 summary 弄壞」和「刪掉」，出一張完整的舊 vs 新鑑別矩陣，而不是只看兩支。
3. 給 render_prints 的對抗 fixture，並確認 Python 中止時會被呈現：
   - `$((PASS + 09))`、`$(( ))`、`$((PASS**PASS**PASS))`（加 timeout）；
   - 註解裡的 `then echo "Ran 5 checks, 0 failed"`；
   - `x=$(echo "Ran …")`；
   - 同一行兩個 echo；
   - `function f {`、`trap summary EXIT`。
4. 在有 raw/ 的樹拷貝上讓覆寫失效，確認 not_tee 仍綠；再加上 ratio=1.0000 的斷言，看它變紅。
5. export NDT_SAMPLING_RAW_DIR 之後 source round.env，在 sandbox 裡跑 `ratio_gate.py --check` 和 `--make-forcered`，看它怎麼轉向、寫到哪裡。
6. 對真實 trace 跑 `--expect red`，也就是 case 2 實際的呼叫。
7. 在合併後的樹（c34a643a＋A＋B）上跑 check_gate_anchors、check_test_tmpdirs.py 和三個 mutation gate；最好跑整條 L1 lane 直接數群組，而不是從三支 suite 推。
8. 算主 checkout 那份 t008_poll_twin.jsonl 的 sha256，對照 audit-raw 的 295ab0d4…。
9. 做能讓 start_bg #3、#4 變紅的 mutant，例如 rotate_log 對不存在的 log 仍 touch 出一代。
10. 合併後實際跑一次 CI。

---
Orchestrator 09-27: fix round B1 (one-line/grouped exit, all prints per line, red-first mutants on test_faults_topo_pid:442 and test_ndt_down_stops_only_ours:245; SELFTEST_INNER+bare exit shape = known limitation) + N4 fail-closed renderer + N1 round.env unset + N2 fixture-read assertion + N3 disclosure/sha + N5 accounting; N6,N7 queued.


---

# Round 2 -- scoped re-review of 1d5180ce

**判決：MERGE**（沒有 BLOCKING）

B1、N1–N5 都按原定義關了；N4 的 fail-closed 是真的；N1 修到一半（只在 source 時生效）。有一個同類的新缺口（下面 NOTE A），建議合併前順手修掉或寫進已知限制，但它不擋合併：舊檢查在那支 suite 上本來就是紅的，所以相對舊檢查沒有退步。

我只讀檔，沒執行任何東西，沒用 git。

路徑縮寫：
- S＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/STALE-SUITES-SUMMARY.md
- D＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/stale/diff-d2a9d641..1d5180ce.patch
- L＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-stale-suites-0927/tests/shell/test_l1_shell_scoring.sh（worktree 內容與 D 一致）
- ts＝同一個 worktree 的 tests/shell
- G＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910，log 檔名都是 `*.stale3-1d5180ce.log`
- R＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/stale

**你的 d32738b0 重跑**：我讀了 R/rerun-summary.d32738b0.txt:1-4【讀】。目前只有兩樣東西：
- trunk 的紅臂，三支都如預期是紅的：start_bg 13 條紅 6、not_tee 5 過 2 紅、l1 96 條紅 12。
- test_apps_stop_kills_the_group 72/0。

疊合樹上的三支 stale suite、三個 mutation gate、anchors 還沒有 log，所以我沒有判讀它們。

---

## 1. B1 是否關閉：按原定義，關了

### 四個反例
SUPPORTED。
- 三個在 d2a9d641 會放過的反例，HEAD 都以 (2a) 的理由判紅，分別停在 441、292、225（G/redfirst_stalefix…log:10-19）【讀】。
- dead_mutant 在 HEAD 仍放過，已寫進 L:233-237 的已知限制（log:20-22）【讀】。
- M0 語料不變時 63/63 全綠（log:24-26）【讀】。
- topo_pid 和 down_stops 兩個反例已成為常駐 gate mutant，都以 `exit <non-zero> after it on the same line` 被殺（G/mutate_l1_shell_scoring…log:36-37）【讀】。
- 中間版本的缺陷（9c22b0d2 上 M0 紅了 3 支）有 log（G/redfirst_stalefix.stale3-9c22b0d2.log:25-26）【讀】。

### commands()（L:289-336）
- **引號、`$(`、`(`、`)`、反引號的追蹤**：巢狀是對的。例如 `"…$(echo "b")…"`，以及單引號在雙引號裡當字面字元（L:293-323）【推】。
- **`$((`**：遇到第一個 `))` 就 pop（L:310），所以 `$((a*(b+c)))` 會早一個字元出棧。對切指令沒有影響【推】。
- **`${…}` 沒有追蹤**：沒加引號的 `${x//;/}` 會被切開。很少見【推】。
- **`#` 註解切斷**（L:326）：只在頂層、而且在指令開頭或空白之後才切，行為正確【推】。heredoc 內容仍被當成程式碼掃描（潛在問題，見 NOTE J）。
- **運算子**（L:328-333）：`&&`、`||`、`;;`、`;`、`|`、`&` 會切。`2>&1`、`>&2`、`&>` 不會切，正確。`|&` 被當成 `&`，無害。`;;` 被當成 `;`，理論上 (2a) 的掃描能跨進下一個 case 分支；但 case 分支裡的 print 本來就認不出來，實務上無害【推】。

### print_words()（L:349-364）
- `name() {`、`name () {`、`function name {`、`function name() {` 四種函式頭都處理了【讀】。
- LEAD 字（if/then/else/elif/do/while/until/!/{/time）和 `(` 前綴都會剝掉【讀】。
- 缺口：
  - `name(){ echo …; }`（`{` 前沒有空格）整個是一個字，認不出來。d2a9d641 的舊 regex `[;&|{(]\s*echo` 反而抓得到【推】。
  - case 分支的 `a) echo …` 認不出來【推】。
  - 這兩種都是偽紅方向，語料目前沒有（M0 63/63）。

### ends_block（L:368-370，在 L:381 使用）
- 遇到 fi/done/esac/}/)/else/elif 和 `)` 開頭的字就停。對 `if …; then echo …; exit 1; fi`、`if …; else …; fi` 的一行寫法、以及 `|| { …; exit 1; }`，停的位置都對【推】。
- `{ echo "Ran…"; }; exit 1` 會在 `}` 停得太早，那個 exit 看不到。很少見【推】。

### 真正綠路徑的 summary 會不會被 (2a) 誤判成失敗路徑

你點名的三種都不會【推】：
- `echo "Ran …" && exit 0`：is_exit_nonzero 只認 `[1-9][0-9]*`（L:367），exit 0 不算。
- `echo …; exit $FAIL`：`$FAIL` 不是字面數字，不算。
- `echo "Ran …" || exit 1`：遇到 `||` 掃描就停（L:381）。

但有兩種會誤判成偽紅【推】：
- `echo "Ran …"; (( FAIL )) && exit 1`
- `echo "Ran …"; [[ $FAIL -eq 0 ]] && exit 0; exit 1`

原因是 L:380-385 接受中間隔了一個條件指令的 `&&`，也會繼續掃過 `exit 0`。語料目前沒有這兩種寫法（M0 63/63）。見 NOTE B。

### 同一類的殘留缺口（NOTE A，最值得處理）
- **機制**：(2a) 是在 print 的「定義行」計算的（L:378-385）。effective line 只替換了行號（L:401），呼叫點那一行的 `; exit 1` 從來沒被看過【讀】。
- **反例**：ts/test_ndt_ovs_topo_script.sh
  - :46 定義 `summary() { printf '\nRan …' …; }`；
  - :70 是 `    summary; exit 1`；
  - :305 是最後的 `summary`；
  - 全檔沒有任何行首的 `exit [1-9]`【讀】。
  - 刪掉 :305 之後：effective 變成 70，failure＝0，(2b) 看的是 70 之後的行，也沒有 exit → group C 綠。但綠跑已經不印 summary，lane 會判 NO-TESTS-RAN【推】。
- **為什麼不擋合併**：舊檢查在這支本來就紅（G/diag_b3.stale-d2a9d641.log:17）【讀】，所以不是相對舊檢查的退步。
- **但**：L:233-237 只把 SELFTEST_INNER 寫成已知限制，這個形狀沒有申報。

---

## 2. fail-closed 是真的：SUPPORTED

- InstrumentError 會以 `sys.exit(3)` 結束（L:389-398）【讀】。
- 輸出在最後一次寫出（L:371、:402），中途失敗不會有半套結果【讀】。
- 任何非零 rc（3、Python 的 1、timeout 的 124、找不到 python3 的 127）都會回報 `instrument failed`，然後直接 `continue`，不讀輸出（L:407-412）【讀】。
- 有 30 秒 timeout（L:246）；`**` 會被拒絕（L:276-277）【讀】。
- `09` mutant：在 gate 裡以 `because 'instrument failed'` 被殺（G/mutate_l1_shell_scoring…log:38）【讀】。red first：d2a9d641 把它讀成「只在失敗路徑上」，理由是錯的；HEAD 讀成 `rc 3 … leading zeros`（G/redfirst_stalefix…log:28-31）【讀】。
- **說法不精確**：L:238-239 和 S:37 都寫「除以零」會觸發 instrument failed。但 `/` 不在允許的字元集（L:279），所以任何除法都會安靜地回 "9"，根本不會進 eval【推】。
- 引號沒收起來的行照舊安靜略過，不算 instrument failure；這是設計，L:241-242 有寫明【讀】。

---

## 3. N1、N2、N3（和 N5）

### N1：部分關閉
- **修了什麼**：round.env:32 無條件 `unset NDT_SAMPLING_RAW_DIR`（D:9-15）【讀】。red first：先 export 再 source，d2a9d641 指向繼承來的目錄，HEAD 指向 round 自己的 raw/（G/redfirst_stalefix…log:40-44）【讀】。
- **不會弄壞 E round 或其他 source round.env 的程式**：
  - 整個 worktree 只有 plot_figures.py:49 讀這個變數【讀】（grep）。unset 後 RAW 回到預設，也就是 round 本來要讀的目錄。
  - 沒有任何腳本檢查 round.env 的 sha【讀】（grep）。
  - not_tee 在 :67 source round.env，:74 才 export，所以照綠 8/0（G/test_gate_exit_code_not_tee…log:18）【讀】。
- **殘留的路徑**：
  - gates_e.sh:37、run_e.sh:37、build_1khz_binary.sh:43 都是 `[[ -n "${ROUND:-}" ]] || . round.env`【讀】。
  - 所以操作者如果先 source 過 round.env、之後才 export 這個變數，這三支就不會再 source round.env，unset 根本沒跑【推】。
  - lib_e.sh 是無條件 source 的（gates_e.sh:41、run_e.sh:41），把 unset 或拒絕放在那裡才完整。
- **SUMMARY 引錯了 suite**：
  - S:50、S:226 說 test_log_suffix_idempotent 會 source round.env。實際上它只 grep round.env（ts/test_log_suffix_idempotent.sh:187-190），source 的是 lib_e.sh（:199-201、:209-211）【讀】。
  - 真正會 source round.env 的另一支是 ts/test_cell_gate_suspect_wiring.sh:49【讀】。這一輪沒有重跑它。
  - 讀碼推斷它不用這個變數，所以不受影響【推】。你的重跑清單有它（R/rerun-ab2.frozen.sh:27），但 d32738b0 的 log 還沒出來。

### N2：SUPPORTED
- case 1b 斷言 `ratio=1.0000`（D:612-619）【讀】。
- red first：在有真實 raw 的樹上把 suite 的 export 改掉，d2a9d641 是 7/0 空洞地綠，HEAD 紅在 1b（讀到 0.9656）；覆寫正常時 8/0（G/redfirst_stalefix…log:45-52；腳本 :107-113）【讀】。

### N3：SUPPORTED
- 256 列全部重生：t 從 1700000000.0 起，tx 從 0 起（D:304-559）【讀】。
- 主 checkout 與 audit-raw 的 sha 都是 295ab0d4…，已有 log（log:56-58）【讀】。
- 小瑕疵：red first 那條「no row」的檢查其實只看第一列（redfirst_stalefix.sh:134）；不過 diff 本身證明了每一列都換了。

### N5：SUPPORTED
帳目：刪 8 條、#1/#2 改目標保留、#3–#5 保留，8＋2＋3＝13（D:879-892；S:74-77）【讀】。

---

## 4. 有沒有改到或弄壞別的

- **只動了 7 個檔**（D 的 diff 標頭）【讀】：round.env、README、fixture、mutate_l1、not_tee、test_l1，以及 start_bg（只改註解）。
- **閘門全部對得上**【讀】：

| gate | 結果 |
|---|---|
| test_l1_shell_scoring | 96/0（log:120） |
| mutate_l1_shell_scoring | 20/20 |
| test_start_bg_log_rotation | 5/0 |
| test_stack_log_rotation | 23/0 |
| mutate_stack_log_rotation | 9/0 |
| test_gate_exit_code_not_tee | 8/0 |
| mutate_gate_exit_code | 4/0 |
| test_log_suffix_idempotent | 30/0 |
| check_gate_anchors | 120/120 |
| predict_ci（c34a643a＋f9c59a44＋1d5180ce） | start_bg PASS、l1 PASS、not_tee 無 PY_PLOT 時 FAIL-SKIP、筆電 PASS（log:9-22） |
| nolab_tripwire | 0 |

- anchors 那一行 mutate_l1 是 ok(19)，但有 20 個 mutation。原因是 `09` mutant 用的 anchor 和 M1 相同（test_faults.sh 的綠 summary），被去重了（13＋6）【推】。
- **新依賴**：group C 現在用到 `timeout`（coreutils），CI 上應該有【推】。
- **沒重跑的**：test_cell_gate_suspect_wiring；gates_e.sh／run_e.sh 的 DRY_RUN。

---

## BLOCKING

無。

## NOTE

- **A**：函式印的 summary，(2a) 算在定義行，不算在呼叫行（ts/test_ndt_ovs_topo_script.sh:46/70/305）。建議合併前二選一：
  - 修：當 effective(n)≠n 時，改用呼叫行的指令來算 (2a)，再加一個「刪掉 :305」的 mutant，先在 1d5180ce 看它存活，修完看它被殺；
  - 或：在 L:233-237 申報為第二個已知限制。
- **B**：`; cond && exit N`、`; … && exit 0; exit 1` 會偽紅。修法：只認經由 `;`、或 print 後直接 `&&` 到達的 exit，而且遇到任何 exit 就停。
- **C**：N1 的殘留路徑（ROUND 已設定時跳過 round.env）。建議在 lib_e.sh 也 unset 或拒絕。
- **D**：S:50、S:226 引錯 suite；test_cell_gate_suspect_wiring 沒重跑。
- **E**：「除以零」的說法不精確（L:238-239、S:37）。
- **F**：`name(){`（無空格）的一行函式、case 分支裡的 print 都認不出來。潛在偽紅，其中 `name(){` 那種比舊 regex 還窄。
- **G**：重導向或 pipe 出去的 print 仍被當成印進 log（`echo "Ran…" > file`）；`… | tee log; exit 1` 也不算失敗路徑。這是既有的潛在偽綠，語料目前沒有。
- **H**：`{ echo …; }; exit 1` 會停在 `}`。潛在偽綠，很少見。
- **I**：case 1b、(2a) 的 `&&` 直接鏈、`||` 中止這幾條，都只有 red first，沒有常駐的 gate mutant。
- **J**：heredoc 內容仍被當成程式碼掃描。潛在問題，語料目前沒有。

## 我會跑、而報告沒跑的

1. 刪掉 ts/test_ndt_ovs_topo_script.sh:305，確認 group C 在 1d5180ce 仍是綠的（NOTE A）。
2. 兩個 (2a) 偽紅 fixture：`echo "Ran 5 checks, 0 failed"; (( FAIL )) && exit 1`，以及 `…; [[ $FAIL -eq 0 ]] && exit 0; exit 1`。
3. 當失敗分支 summary 的幾種寫法：`echo "Ran …" | tee -a log; exit 1`、`{ echo "Ran …"; }; exit 1`、`name(){ echo "Ran …"; }`。
4. N1 殘留路徑：先 source round.env、再 export、再以 DRY_RUN 跑 gates_e.sh，看它讀的是哪個目錄。
5. 在 1d5180ce 上重跑 test_cell_gate_suspect_wiring 和它的 gate；gates_e.sh／run_e.sh 的 DRY_RUN。
6. 等 d32738b0 的重跑跑完，逐項對照 stale3 的結果。
