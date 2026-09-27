# SUMMARY：三支過時的 suite（b1 start_bg 輪替、b2 gate exit-code、b3 L1 scoring 的 group C）

- **分支**：`fix/stale-suites-0927`，從 trunk `8746c1bc` 開出。
- **Worktree**：`scratch/overnight-2026-09-05/wt-stale-suites-0927`。
- **Head**：`1d5180ce827f22dc6b8e4dfdd94757c23d697528`，共 8 個 commit（§7）。後 4 個是 judge「MERGE AFTER FIXES on d2a9d641」的修正輪（§0）。
- 與 trunk `c34a643a` 的 `git merge-tree` 乾淨；與 (a) `fix/probe-suites-stub-0927`（修正輪後的 `f9c59a44`）沒有共用的檔案（§4 在合併後的樹上實跑）。
- 沒 push、沒 merge、沒 sudo、沒碰 lab、沒碰主 checkout、沒碰 CI 環境。
- 每一次執行都走 guard（`JOBS=1 LOCK_WAIT=10800`），nolab shim 在 PATH 最前面，driver 一律從唯讀的凍結副本執行，tripwire 放在最後。
- 沒有把 `doc/audit/2026-08-20_sampling-rate-and-cpu/raw/` 解除忽略，也沒有 commit 其中的任何東西；測試執行時不從 audit-raw 抓資料。

[Co-developed with claude code -- Adam]

## 0. 修正輪（judge-STALE-d2a9d641：B1、N1–N5；`07b99f18`、`bec286bb`、`9c22b0d2`、`1d5180ce`）

**B1：規則 (2) 看不到同一行的 exit——「至少和舊的一樣有鑑別力」原本不成立**
- 我原本在 §3.2、§3.3 和 suite 註解（:219-221）寫：規則 (2) 保住了舊檢查要抓的「只剩失敗路徑的 `...; exit 1`」；新 group C「至少和舊的一樣有鑑別力」。**這兩句只在表裡那兩支 suite 上被證明過，對語料整體不成立。**
- 原因：規則 (2) 只找「之後某一行的**行首**」`exit`；renderer 一行只渲染第一個 print。一行寫完的失敗分支和 `|| { …; exit 1; }` 都看不到。
- 修法（`07b99f18`）：
  - 一行切成多個指令（在引號、`$( )`、`$(( ))` 以外的 `; && || | &`），**每個** echo／printf 都渲染。
  - **(2a)**：一個會計分的 print，如果同一行在它之後、經由 `;` 或 `&&`、有 `exit <非零>`，它就在失敗路徑上，不能當「最後一個」。如果每個會計分的 print 都是這種，這支就判紅。
  - **(2b)**：原本的「之後某行行首的裸 exit」保留。
- red first（OBSERVED，`redfirst_stalefix.stale3-<sha8>.log`；只看目標 suite 那一條 C）：

  | judge 的反例 | d2a9d641 | HEAD | HEAD 紅的理由 |
  |---|---|---|---|
  | M1 套在 test_faults_topo_pid.sh:442 | ok（放過） | FAILED | same line，最後在 441 |
  | M1 套在 test_ndtwin_lab_config.sh:293 | ok | FAILED | same line，最後在 292 |
  | 刪掉 test_ndt_down_stops_only_ours.sh:245 | ok | FAILED | same line，最後在 225 |
  | 弄壞 test_mutate_gate_dead_mutant.sh:299 | ok | **ok** | 已知限制（見下） |
  | M0 語料不變 | 63／63 綠 | **63／63 綠** | — |

- 🔴 **已知限制，這次不修**：summary 後面接裸的 `exit` 或 `exit $FAIL`（test_mutate_gate_dead_mutant.sh 的 SELFTEST_INNER 分支：`echo "Ran ..."`，然後 `(( FAIL == 0 )); exit`）。這是綠路徑的寫法，會不會跑到最後取決於值、不是文字，靜態規則分不出來。這支 suite 真正的最後 summary 如果不見了，group C 仍會把那個分支的 summary 當成綠路徑那一條。suite 註解裡已寫明。
- mutation gate 新增兩個語料 mutant，都要被 (2a) 以名稱殺掉：topo_pid 的綠 summary 改掉、down_stops 的最後 summary 刪掉。
- **我自己的中間缺陷，交付前由 red first 抓到（`1d5180ce`）**：第一版切指令時，把 `summary() { printf ...; }`、`done_() { echo ...; }` 的第一個字當成函式頭，沒認出裡面的 print。結果在 `9c22b0d2` 上 M0 紅了 3 支：test_ndt_ovs_topo_script 和兩支 test_run_layers_*（`redfirst_stalefix.stale3-9c22b0d2.log`，rc 1）。修成先跳過 `name() {`／`name () {`／`function name {`，和舊的邊界 regex 一樣；M0 回到 63／63。

**N4：renderer 算不出來時「壞得看得見」**
- `$(( ))` 求值失敗（`09`、空的 `$(( ))`、除以零）、含 `**`，或 renderer 超過 30 秒，都會讓 render_prints 印出原因並以非零結束。group C 對那支 suite 回報 `instrument failed`，絕不會讀成 zero 或只剩前半的 print。
- 輸出改成跑完才一次寫出，所以不會有半套結果。
- red first（OBSERVED）：把 test_faults.sh 的綠 summary 換成三種寫法——
  - `$((PASS + 09))`：d2a9d641 讀成「只在失敗路徑上（314 行後接裸 exit）」。它 crash 在 317 行，只剩前半的 print，**紅了，但理由是錯的**。HEAD：`instrument failed … leading zeros …`。
  - `$(( ))`：同上；HEAD：`instrument failed … invalid syntax`。
  - `$((PASS**PASS**PASS))`：d2a9d641 什麼都沒讀到；HEAD：`instrument failed … '**'`。
- mutation gate 新增語料 mutant：`$((PASS + 09))`，必須以 `instrument failed` 被殺。
- 多行字串（引號在同一行內沒有收起來）不算「一行的 print」，照舊略過，不算 instrument failure。

**N1：round.env 清掉 `NDT_SAMPLING_RAW_DIR`**（`bec286bb`）
- red first（OBSERVED）：先 export 這個變數、再 source round.env，看 `plot_figures.RAW`——
  - d2a9d641：指向繼承來的目錄（E round 會安靜地判別處的 cell）；
  - HEAD：是 round 自己的 `raw/`。
- suite 在 source round.env **之後**才 export，所以不受影響：test_gate_exit_code_not_tee 8/0。另外也跑了會 source round.env 的 test_log_suffix_idempotent（§6）。

**N2：not_tee 斷言讀到的是 fixture**（case 1b）
- red first（OBSERVED）：在一棵**有真實 raw**（從 audit-raw 讀進 temp dir）的樹上，把 suite 的覆寫弄壞——
  - d2a9d641：7/0 綠。gate 讀的是真實 trace，**空洞地綠**。
  - HEAD：紅在 case 1b，讀到 `ratio=0.9656`。
  - HEAD、覆寫正常：8/0 綠，真實 raw 在旁邊，讀到的仍是 fixture。

**N3：fixture 完全合成；主 checkout 的 sha 有 log 了**
- fixture 第一列原本抄到真實 trace 的 `t`、`tx`（1787658157.534、3302）。現在 `t` 從 1700000000.0 起、計數器從 0 起，每列平移同樣的量，所以 ratio 不變（1.0000）。README 已寫明。
- sha256（OBSERVED）：audit-raw 與主 checkout（唯讀）的 `t008_poll_twin.jsonl` 都是 `295ab0d46ea830bcf039eb4fab02461b2268527e0a92b8138347d05edcae1d07`。

**N5：b1 的刪除帳**（`9c22b0d2`，只改註解）：見 §1。

## 1. b1 — test_start_bg_log_rotation（`e8bf8e1d`）

**缺陷**：這支 suite 斷言的是兩代 `.prev`／`.prev2` 輪替。O-4（`74c811df`，09-06）刻意把它換成五代時間戳記＋`NDT_LOG_KEEP`，契約由 test_stack_log_rotation.sh 負責測：3A–3D 在 :84-122，3E／3F 在 :144-162（同一秒內重啟兩次、start_bg 真的有呼叫 rotator）。原本只寫了 84-122，不完整。

**歷史（OBSERVED，不是推論）**：08-31 版本的 suite（`8e7e3b00`）
- 對 `74c811df^` 的 stack.sh：rc 0，13 條全過；
- 對 `74c811df` 的 stack.sh：rc 1，13 條中紅 6 條。
- 所以「從 O-4 起就紅」是實跑出來的，不是從日期推的。

**依你的裁決改成**：
- 13 條變 5 條（帳目依 judge N5 更正；我原本寫「六條刪除不補，另外三條也刪」，數字不對）：
  - **刪 8 條，不補**，都在兩個多次重啟的格子裡：紅的 #6、#9、#10、#13（`.prev`／`.prev2` 裡的舊時期、最舊的被丟掉）；綠的 #8、#12（「還沒有 .prev2／.prev3」，只因為不再產生 .prev 才綠）；綠的 #7、#11（最新時期在 live log 裡，新的 #3 仍然斷言這件事）。輪替契約只在 test_stack_log_rotation 講一次。
  - **#1、#2 保留並改目標**：從 `.prev` 改成那一個時間戳記世代。它們原本是紅的六條裡的兩條，不是「不補」。
  - **#3、#4、#5 保留**：#3 更嚴格（查內容，不只查存在），#4、#5 改用時間戳記檔名。
- 留下的是只有這支 suite 在測的東西：start_bg 自己的決定（`stack.sh:559-560`，`[[ -s "$log" ]]`），目標改成時間戳記的檔名，共 5 條：
  - 非空的 log 會被輪替，而且剛好產生一個時間戳記世代；
  - 那個世代裝的是上一個時期的內容；
  - live log 只有新時期的內容；
  - 第一次啟動不產生世代；
  - 空的 log 不輪替。
- suite 吃 `STACK_UNDER_TEST`；`mutate_stack_log_rotation.sh` 用兩個新 mutant 對它跑：
  - **S1**：start_bg 用 `-e` 取代 `-s`（空 log 也輪替）；
  - **S2**：start_bg 從不輪替。
- 「第一次啟動」不是另一條路徑：沒有 log 時 `-s` 為假，與空 log 相同，而 `rotate_log` 對不存在的檔案什麼也不做，所以不另設 mutant（gate 裡有註解）。

## 2. b2 — test_gate_exit_code_not_tee（`c17b83cf`）

**缺陷**：suite 把 ratio_gate.py 指向 `t008_poll`，並聲稱那一格「在版本控制裡」。**它不在**：`doc/audit/2026-08-20_sampling-rate-and-cpu/raw/` 自己忽略自己，原始資料在 audit-raw orphan 分支上。所以在每一個 worktree、clone 和 CI checkout 裡，gate 都讀到 NO-DATA，回 UNRUNNABLE rc 2：
- case 1、case 4 紅；
- **case 2（最關鍵、期望 rc 2 的那一條）綠，但理由是錯的。**

在 8746c1bc 實跑觀察到，case 2 的 gate 當時說的是：`GATE ratio cell=t008_poll verdict=UNRUNNABLE (no ratio -- NO-DATA) rc=2`，而 suite 把這行丟掉了。

**修正**：
- `tests/shell/fixtures/gate_exit_code_not_tee/`：一份**最小的合成 t008_poll**。
  - 形狀取自真實 trace（從 audit-raw 讀進 temp dir 推出來，**沒有複製**）；
  - gate 只讀一條邊（s5-eth2），讀值是編的，ratio 1.000；
  - `client.json` 只放 verdict 會讀的那一個欄位，也就是真實那一格的 loss。
- `plot_figures.RAW` 讀 `NDT_SAMPLING_RAW_DIR`；沒設的話仍是檔案旁邊的 `raw/`，和以前一樣。suite 把 fixture 複製到自己的 temp dir，再指過去。
- case 2 現在同時斷言 rc **和** gate 的判定行（`FORCE-TEST FAILED: expected RED, got GREEN.`），所以 UNRUNNABLE 永遠過不了它。header 的錯誤說法已更正。

**fixture 與真實 trace 走同一條路徑（OBSERVED）**：兩者都是 `verdict=GREEN mark=DATAPLANE-HURT`，都經過 ratio（真實 0.9656、fixture 1.0000），都不是 UNRUNNABLE。兩邊只跑了 `--expect green`；case 2 真正呼叫的 `--expect red` 沒有對真實 trace 跑過。audit-raw 與主 checkout 的 sha256 見 §0 N3（原本這裡說「相同」但沒有 log，現在有了）。

🔴 **CI 裡它仍然會 SKIP，這個 CI 群組會留著**：
- CI run 36273687560（3db3b9a8）的 L1 lane 寫的是：`test_gate_exit_code_not_tee.sh FAIL 1 skip(s)`，原因行是 `SKIP: PY_PLOT (/home/adam/miniconda3/bin/python3) is not present; the gate cannot be invoked`。
- 那是 PY_PLOT 不存在造成的，與 b2 修的缺陷無關；這一輪依你的指示**不碰 CI 環境**，所以合併後這一組仍在 14 組裡。
- §4 在合併後的樹上把 PY_PLOT 指向不存在的路徑實跑，lane 的判定是 FAIL-SKIP，與今天的 CI 一致；用這台筆電的 PY_PLOT 則是 PASS。

## 3. b3 — test_l1_shell_scoring 的 group C（`36178199`、`d2a9d641`）

### 3.1 哪一邊錯了（OBSERVED）

group C 紅了 12 支 suite。我把這 12 支都在 guard 裡真的跑了一次，每份 log 完整保留，並用 lane 自己的 `shell_summary`＋SKIP 計數＋`l1_lane_verdict`（`NDTWIN_L1_LIB_ONLY=1` source 進來）去評分：
- **12 支全部讀對**：scorer 的 ran 等於 log 裡 ok＋FAILED 的條數，綠的跑判 PASS、紅的跑判失敗。
- test_build_guard 在這條分支上是紅的（37 條紅 15），那是 d271f5b8 已修的 gate 環境問題，scorer 也照實判了 FAIL-RC。
- 所以錯的是靜態啟發式：它拿原始碼裡**最後一個** `echo "..."` 當 summary。但 lane 讀的是整份 log、最後一個 summary 為準。summary 後面接的 trailer、heredoc、定義在下面的函式裡的訊息、用 printf 印的 summary、從函式裡印的 summary，都讓啟發式誤判。

### 3.2 新的 group C

（修正輪後的版本見 §0 B1、N4；以下是 d2a9d641 的版本，保留作對照。）
- **規則 (1)**：原始碼裡每一個 echo 和 printf 都渲染出來，用 lane 自己的 shell_summary 評分，至少要有一行能評出分數。
  - printf 的 `%d`／`%s` 從它自己的參數填；名字含 fail／bad 的計數器當 0，其餘當 9；`$((PASS + FAIL))` 會真的算。
  - 用 shlex（punctuation_chars）在第一個未加引號的 `;&|<>` 切斷，只取那一條指令的字。**（實際上一行只渲染第一個 print，judge B1。）**
- **規則 (2)**：最後一行能評分的輸出之後，不可以有裸的 `exit <非零>`。函式裡的輸出算在該函式最後一次被呼叫的那一行（test_run_layers_* 的 `done_()` 就是這種）。
  - ~~這條保住了舊檢查原本要抓的東西~~：**只保住了多行的寫法**（exit 自己一行）。一行寫完的 `...; exit 1; fi` 和 `|| { ...; exit 1; }` 它看不到；修正見 §0 B1。

### 3.3 鑑別力（d2a9d641 時的宣稱與證據；🔴 一般宣稱被 judge 的四個反例推翻，見 §0 B1）

同一份語料、同樣四個語料 mutant，把舊的（8746c1bc）、新的、以及拿掉規則 (2) 的新版並排跑，只讀目標 suite 那一條 C：

| mutant | 目標 suite | 舊 | 新 | 新但沒有規則 (2) |
|---|---|---|---|---|
| M0 無 | test_faults | ok | ok | ok |
| M0 無 | test_stack_log_rotation（printf） | **FAILED** | ok | ok |
| M1 綠路徑 summary 拿掉（剩失敗路徑的＋裸 exit） | test_faults | FAILED | FAILED | **ok** |
| M2 兩個 summary 都拿掉 | test_faults | FAILED | FAILED | FAILED |
| M3 printf summary 改成讀不懂的字 | test_stack_log_rotation | FAILED | FAILED | FAILED |
| M4 printf summary 移到失敗路徑（＋裸 exit） | test_stack_log_rotation | FAILED | FAILED | **ok** |

「鑑別」＝未突變時綠、突變後紅：
- 舊的只鑑別 M1、M2。它在 printf suite 上未突變就已經紅了，所以對 M3、M4 沒有鑑別力。
- 新的四個全部鑑別。
- 拿掉規則 (2) 就漏掉 M1 和 M4，所以抓到它們的正是裸 exit 那條規則。
- 🔴 這張表只涵蓋 test_faults 和 test_stack_log_rotation 兩支，而兩支的 exit 都自己一行。我據此寫「至少和舊的一樣有鑑別力」，那是把兩支的結果推廣到整個語料；judge 找到四支反例。§0 B1 的表是修正後的結果。

mutation gate 裡的四個語料 mutant 現在不只指定哪一條 check 要紅，還指定**是哪一條規則**抓到的：check 的 `actual:` 行必須含 `zero:`（規則 1）或 `followed by a bare exit at line`（規則 2），否則算 SURVIVED。M4（summary 後接裸 exit 的 printf 變體）是 `d2a9d641` 新增的。

### 3.4 🔴 gate 本身的缺陷：`mutate_l1_shell_scoring.sh` 沒有 baseline

- 舊的 gate 沒有 baseline。只要 suite 變紅就算 KILLED。
- 所以從 group C 變紅那天起，這裡每一個「KILLED」都是被本來就在的紅殺掉的，**gate 一直在過、卻什麼也沒證明**。
- red first（OBSERVED）：
  - 在 8746c1bc 的樹裡，8746c1bc 自己的 gate：**rc 0**，`14 mutation(s): 14 killed, 0 survived`，而 suite 未突變就已經紅了 12 條。
  - 同一棵樹裡，HEAD 的 gate：**rc 2**，`refused: the suite is RED with no mutation (12 check(s)) -- mutations prove nothing`。
- 修正（`36178199`）：先跑一次未突變的 suite，紅就以 rc 2 拒絕，再開始任何 mutation。

## 4. CI 預測（在合併後的樹上實跑，`predict_ci`）

**修正輪重跑（OBSERVED，`predict_ci.stale3-1d5180ce.log`）**：trunk `c34a643a`＋(a) 修正輪後的 `f9c59a44`＋本分支 `1d5180ce`。兩邊 merge-tree 都乾淨，三邊改動的檔案（1／8／10）不重疊。
- start_bg PASS 5/0；l1_shell_scoring PASS 96/0（語料含 (a) 改過的六支，新的 group C 對它們是綠的）；
- not_tee：沒有 PY_PLOT 時 FAIL-SKIP，這台筆電 PASS 8/0。

以下是 d2a9d641 那一輪的原文。

**做法**：trunk `c34a643a`＋(a) `356d4e4e`＋本分支 HEAD。
- 三邊自 8746c1bc 起改動的檔案互不重疊；兩條分支各自與 c34a643a 的 `git merge-tree` 都乾淨。所以「每個改過的檔案取自它那一邊」就是合併結果。
- 在這棵樹上跑三支 suite，用合併後的 lane 自己的 scorer 評分。

**結果（OBSERVED，`predict_ci.stale2-d2a9d641.log`，四份 log 保留在 `.kept/`）**：

| suite | rc | ran／failed／skips | lane 判定 |
|---|---|---|---|
| test_start_bg_log_rotation | 0 | 5／0／0 | PASS |
| test_l1_shell_scoring | 0 | 96／0／0 | PASS |
| test_gate_exit_code_not_tee，PY_PLOT 指向不存在的路徑（CI 的情況） | 0 | 0／0／1 | FAIL-SKIP |
| test_gate_exit_code_not_tee，這台筆電的 PY_PLOT | 0 | 7／0／0 | PASS |

**儀器的缺陷（我自己的，已修）**：第一次 predict_ci（`predict_ci.stale-d2a9d641.log`，rc 1）只 archive 了一份路徑清單，漏了 ratio_gate.py 會 import 的 `doc/audit/2026-08-25_sampling-rounds/cell_verdict.py`。於是用筆電 PY_PLOT 的那一格 gate 回 rc 2，not_tee 紅了 3 條。那是儀器的原因，不是那棵樹的問題。
- 改成 archive 整棵樹後，在 `stale2` 單獨重跑 predict_ci 和它自己的 tripwire（0）。
- 失敗的那份 log 保留著。
- 附帶看到的（OBSERVED）：那一格 case 2 的 actual 是 `2 | `（沒有 FORCE-TEST 行），被新的 case 2 判紅。也就是說，gate 跑不起來時，case 2 不會再被 rc 2 騙過。

**預測**：
- **test_start_bg_log_rotation 的 CI 群組會消失。**
  - CI 今天是 `FAIL (exit 1, ran=13)`，紅的正是那六條 `.prev`（CI 的失敗清單裡看得到）。
  - 新 suite 只 source stack.sh、用 mktemp 的 temp dir 和 `sleep 0.2`，沒有 CI 缺的東西（讀原始碼得知）。
- **test_l1_shell_scoring 的 CI 群組會消失。**
  - CI 今天是 `FAIL (exit 1, ran=96)`，紅的是 group C 的舊啟發式。
  - 新的 group C 需要 `python3`。CI 的 L1 lane 已經在跑 tests/python 的 unittest，所以 python3 在（INFERRED：我沒有另外查 CI image 的 python 版本；renderer 只用標準庫的 re 和 shlex）。
  - 它讀的是合併後的語料，也就是 (a) 改過的六支；合併後的樹上它是綠的。
- **test_gate_exit_code_not_tee 的 CI 群組會留著**（PY_PLOT 不存在 → SKIP → FAIL 1 skip(s)），理由見 §2。
- 14 組預計剩 12 組。前提是合併時沒有其他變動讓別的群組增減；你合併後我可以對 CI 的輸出。
- judge 的 N6（這是推論，不是觀測）成立：
  - 沒有實際跑 CI；CI 的 python3 是推的。
  - (a) 會不會讓其他群組增減，沒有量。
  - mutation gate、check_gate_anchors、check_test_tmpdirs 都沒有在合併後的樹上跑。
  - 這次只多做了一件事：predict_ci 在含 (a) 修正輪的合併樹上重跑（見上）。

## 5. red first 總覽（OBSERVED，`redfirst_stale.stale-<sha8>.log`；修正輪的見 §0 與 `redfirst_stalefix.stale3-1d5180ce.log`）

- b1：8746c1bc 紅 6 條（全是 `.prev`／`.prev2`），HEAD `Ran 5 checks, all passed`；歷史對照見 §1。
- b2：這個 worktree 沒有 raw 檔。
  - 8746c1bc 紅 case 1、4，case 2 綠但理由錯（UNRUNNABLE rc 2）。
  - HEAD 綠。
  - HEAD 把 fixture 目錄清空，case 2 就變紅，並說 gate 是 UNRUNNABLE。
- b3：8746c1bc group C 紅 12 支、HEAD 綠 63 支；gate 的 baseline 缺陷與新舊鑑別力比較見 §3。

## 6. 閘門

全部經 guard，nolab shim 在最前面，driver 從凍結副本執行。log 在 `logs/gates-0910/<gate>.<tag>-<sha8>.log`，第一行是完整 sha，最後一行是 `# rc=`。

**修正輪，head `1d5180ce`（`stale3`）**

| gate | rc | 結果 |
|---|---|---|
| test_l1_shell_scoring | 0 | Ran 96 checks, 0 failed（M0：group C 63/63 綠） |
| redfirst_stalefix | 0 | 見 §0：B1 四個反例、M0、N4 三種、N1、N2、N3 |
| test_start_bg_log_rotation | 0 | Ran 5 checks, all passed |
| test_stack_log_rotation | 0 | Ran 23 checks, 0 failed |
| mutate_stack_log_rotation | 0 | 9 mutations, 0 survived |
| test_gate_exit_code_not_tee | 0 | 8 passed, 0 failed（多了 case 1b） |
| mutate_gate_exit_code | 0 | 4 mutations, 0 survived |
| test_log_suffix_idempotent | 0 | 30 passed, 0 failed（它 source round.env） |
| mutate_l1_shell_scoring | 0 | baseline 綠；20 mutation(s): 20 killed；三個新語料 mutant 各自殺在指定的 check 與規則上（兩個 same line、一個 instrument failed） |
| predict_ci | 0 | 見 §4 |
| check_gate_anchors | 0 | 120/120 cells ok |
| nolab_tripwire | 0 | **0 lab call(s)**，shim log 全檔 0 行（我自己讀過） |

- 不算數的一輪：`stale3-9c22b0d2` 的 redfirst_stalefix rc 1，抓到我的中間缺陷（M0 紅 3 支，見 §0 B1）。之後的 gate 還在等鎖時我就停了 driver，test_start_bg_log_rotation 那份 log 沒有 rc 行。

**d2a9d641 那一輪（`stale`、`stale2`）**

| gate | rc | 結果 |
|---|---|---|
| redfirst_stale | 0 | b1、b2、b3 在 8746c1bc 紅、HEAD 綠；歷史對照、gate baseline、鑑別力表都在裡面 |
| test_start_bg_log_rotation | 0 | Ran 5 checks, all passed |
| test_stack_log_rotation | 0 | Ran 23 checks, 0 failed |
| mutate_stack_log_rotation | 0 | 9 mutations, 0 survived（含 S1、S2 各自殺在自己那一條） |
| test_gate_exit_code_not_tee | 0 | 7 passed, 0 failed |
| mutate_gate_exit_code | 0 | 4 mutations, 0 survived |
| test_l1_shell_scoring | 0 | Ran 96 checks, 0 failed |
| mutate_l1_shell_scoring | 0 | baseline 綠；17 mutation(s): 17 killed, 0 survived；四個語料 mutant 各自殺在指定的 check 與規則上 |
| diag_b3 | 0 | 12 支全部讀對；它自己的 shim 記錄並拒絕了 2 次 `sudo -n ovs-vsctl list-br`（test_ndt_honesty 的，見 `diag_b3.stale-d2a9d641.kept/calls`） |
| predict_ci | **1** | 儀器缺陷（路徑清單漏了一個模組），見 §4；保留 |
| check_gate_anchors | 0 | 120/120 cells ok |
| nolab_tripwire | 0 | **0 lab call(s)**，shim log 全檔 0 行 |
| predict_ci（stale2） | 0 | 見 §4 |
| nolab_tripwire（stale2） | 0 | **0 lab call(s)** |

我自己讀過兩份 tripwire 的 log 和它們讀的 shim log。上一輪 diag_b3 那 2 次 list-br 進了 driver 的 tripwire；這一輪它們留在 diag_b3 自己的 shim 裡，driver 的 tripwire 是 0。

## 7. Commits（`8746c1bc..1d5180ce`）

- `e8bf8e1d` start_bg rotation tests: keep start_bg's own decision, drop the contract another suite owns
- `c17b83cf` gate exit-code tests: a hermetic synthetic t008_poll, and case 2 asserts the verdict too
- `36178199` L1 scoring tests: group C reads what the lane reads; its mutation gate needs a green baseline
- `d2a9d641` L1 scoring gate: each corpus mutant names the rule that must catch it; a bare-exit mutant on the printf suite
- `07b99f18` L1 scoring group C: a summary with an exit after it on its own line is a failure path; every print rendered; fail closed
- `bec286bb` gate exit-code tests: case 1b asserts the fixture was read; a fully synthetic fixture; round.env clears the override
- `9c22b0d2` start_bg rotation tests: the deletion accounting, exact; the contract cite includes 3E/3F
- `1d5180ce` L1 scoring group C: a print that opens a one-line function body is a print

## 8. 開放項目

- test_gate_exit_code_not_tee 在 CI 仍 SKIP。要讓它在 CI 跑，得在 CI 提供一個裝了 matplotlib 的 PY_PLOT（ratio_gate.py 經 cell_verdict → plot_ladder_rates 會 import matplotlib，讀原始碼得知），那是 CI 環境的事，這一輪不做。
- group C 讀的是原始碼，不是執行結果。由變數或 heredoc 組出來的 summary 它讀不到；目前 63 支每一支都至少有一行它讀得到的 summary，所以沒被這個限制絆到。真正的保證仍然是 lane 在執行時讀 log，group C 只是語料的早期警報。
- **已知限制**（§0 B1）：summary 後接裸的 `exit`／`exit $FAIL`（SELFTEST_INNER 形狀）。靜態規則分不出來，這次不修。
- judge 排隊的 NOTE：
  - N6：CI 群組數仍是推論，見 §4。
  - N7：not_tee 會 source round.env，而 round.env 寫死 `KERNEL_DIR` 並在主 checkout 底下 `mkdir -p`；從 worktree 跑也會碰到主 checkout 的路徑。既有行為，這次沒動。
- judge 提到、這次沒做的：
  - start_bg #3、#4 從沒看過紅；
  - case 3 沒資料也綠；
  - render_prints 的函式範圍用大括號計數，字串和 regex 裡的大括號也會被算進去；
  - 註解沒剝乾淨、`$(echo …)` 的處理（現在切指令時不會把 `$( )` 裡面的東西當成 print）。
- diag_b3 用它自己的拒絕型 shim。test_ndt_honesty 的兩次 `sudo ovs-vsctl list-br` 被它記錄並拒絕，留在 `diag_b3.stale-<sha8>.kept/calls`，不再進 driver 的 tripwire。那兩次呼叫本身由 (a) 的 stub 解決。

DELIVERED 1d5180ce827f22dc6b8e4dfdd94757c23d697528
