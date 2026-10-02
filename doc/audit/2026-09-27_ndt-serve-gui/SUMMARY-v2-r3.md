# ndt serve GUI v2 — 第三輪交付（更輕的探測、被中斷的閘門，以及 r2 沒做完的清單）

[Co-developed with claude code -- Adam]

- **程式的 head**：`feat/ndt-serve-gui-v2-0927` `0170df28`。第 4 節的正式閘門都在這顆 head 上跑，porcelain 0，跑的期間沒有改檔。這份 SUMMARY 由 orchestrator commit 在它上面，是唯一多出來的 commit。
- **trunk 合併**：功能分支和 trunk 已經不能乾淨合併（第 3.3 節）。解好衝突的 merge commit 是 `1ee0089f`，放在本機分支 `feat/ndt-serve-gui-v2-0927-r3-merge-1e350bf2`，功能分支本身沒動。
- **範圍**：沒有併進 trunk、沒有 push、沒用 sudo、沒 claim、沒開 fabric。
- **標記**：OBSERVED＝這一輪實際跑過，引用的 log 印得出 head 或 commit。INFERRED＝推論、計算，或沒有在這顆 head 上跑過。
- **raw**：`L/`＝`scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2/`。過程筆記在 `L/r3-notes.log`。

## 1. Adam 的裁定：探測只問「有沒有人在量測」（RULINGS-1001 表單 7）

### 1.1 做了什麼

**ndt：新增 `ndt status --measuring`**
- 只印 plain status 裡回答這個問題的那幾列：`declared`，以及 `measuring`；沒有 fabric 時則是 `orphaned`。
- 原本 `cmd_status` 裡的那 34 行，原封不動移進 `status_measuring_rows`（`ndt:6682-6717`）。plain status 和 `--measuring` 都呼叫它，所以兩者不會答得不一樣。
- 這個函式只用 `measuring_declared`、`in_flight`、`mn_count`，也就是只讀 claim 檔和 `ps`。
- `--measuring` 在 `cmd_status` 一開頭就 return（`ndt:6721-6726`），rc 一律是 0。
- `ndt help` 改成 `status [--check | --measuring]`，並附一段說明。

**serve：新增 `GET /measuring`**
- 執行 `ndt status --measuring`。
- `measuring`、`declared`、`measuring_is_nothing` 和 `/lab` 用同一段 `measuring_fields` 讀；回應裡沒有 `claim`。
- 要 token、佔一個讀取槽、有逾時。
- verbs 加了 `ARGV_STATUS_MEASURING` 和 rc 表 `status.measuring`；RC_SOURCE 引用 help 片語和 `ndt:6725`。

**頁面**
- 量測中暫停時，探測只讀 `/measuring`（`readProbe`），不改任何分頁。
- 「上次讀取」一直是最後一次完整讀取的時間；暫停時旁邊另外顯示「上次探測」。
- 探測讀到沒在量測、也沒有 declared，就恢復每 10 秒一次的完整讀取。

**沒有改的保證**：loopback、token、CSP、不設 cookie、`preview:true`、claim-first。

### 1.2 釘住它的測試（每一條都看過紅）

| 釘什麼 | 測試 | 紅燈 |
|---|---|---|
| 答案和 plain status 相同。8 種 fixture：只有 declared、只有 in_flight、兩者都有、兩者都無、claim 過期、別人的 claim、orphaned、兩個 driver。每種都檢查兩件事：輸出是 plain status 裡連續的一段且三列的值相同，以及那幾列寫的內容本身是對的 | `tests/shell/test_ndt_status_measuring.sh`，79 個 check | 對 `59e3ba1f` 的 ndt 跑，11 個失敗、rc 1（`L/ndt-measuring-red-first-r3.log:478-479`） |
| 不用 sudo、curl，不查 OVS／bmv2。PATH 上放 15 個記錄後拒絕的 shim，8 種狀態跑下來紀錄必須是空的。對照組：plain status 經過同一組 shim，要記到 sudo | 同上 | 舊的 `--measuring` 會掉進完整報告，記到 sudo |
| ndt 端的變異：L1 退回完整報告；L2、L3 兩邊各留一份副本；L4／L5／L5b 在共用路徑上加 sudo、kernel 請求、bmv2 查詢；L6 改 rc；L7–L12 改答案；L13 改 help | `tests/shell/mutate_ndt_status_measuring.sh`，14 個變異 | 14 個全抓到（`L/ndt-measuring-gate-r3-0170df28.log:32`） |
| serve：真的跑 `--measuring`、讀法和 `/lab` 相同、逾時不算讀到、要 token、rc 表和出處 | `test_ndt_serve_gui.py` 新增 3 個案例、擴充 2 個 | G62–G62h（`L/main-gate-r3-py312-0170df28.log:201-208`） |
| 頁面靜態檢查：只讀 `/measuring`、不寫分頁 | SourceLint | G59 系列，加上 G59g、G59h（`:173-174`） |
| 頁面（真的瀏覽器）：66 秒內 `/measuring` 剛好多一次、其他四個是 0；stub 只看到一次 `status --measuring`；「上次讀取」不變 | `Refresh.test_a_measuring_pause_probes_measuring_alone` | 頁面閘門 Q1–Q5、Q4b、Q12（`L/page-gate-r3-0170df28.log`） |

### 1.3 動 ndt 之後跟著搬的錨點

`cmd_status` 的判定之前多了 23 行，下方每一列都往後移。每一條都依函式加文字重新定位：
- **RC_SOURCE**：status.check 7086／7091／7095、status 7097、apps.start 8918／8922／8995、apps.stop 10436／10439／10442、apps.status 10369、status.measuring 6725。
- **lock probe**：9439-9454（README、serve.py、test_ndt_serve.py）。
- **主閘門的變異**：M61＝10369；M63＝8922，替換成 8462；M64＝9439-9454；M65＝9439-9443。
- **註解**：serve.py 和 verbs.py 的註解跟著改。
- **不用動**：`claim_line` 的 printf 沒有改，所以 G49 和 ClaimFormProvenance 都不用動。

我自己的重構一度弄壞 G11、G11b、G24、G25 的錨點（MISSING:3，`L/anchors-all-r3-51087860.log`），修好後 amend 成 `c4247ca2`。

最終錨點：主閘門 ok(170)、頁面閘門 ok(44)、measuring 閘門 ok(12)、honesty ok(67)；所有閘門 123/123（`L/anchors-r3-0170df28.log`）。

## 2. 成本：新探測和舊探測

**量法**和 RESULTS.md 相同：`/proc/stat` 的程序數差，減掉等長的閒置窗口；7 次取中位數；sudo、curl 走記錄用的 shim；不用 strace。腳本是 `L/live-probe-cost-r3/run.sh`。

**條件**：
- 量測前後 lab 都閒置：claim none、measuring nothing、0 bmv2、0 mininet、:8000 沒開（`00-header.log:4-15`）。
- 新 ndt 的 sha256 是 `408310c7…`，就是 `c4247ca2` 的 blob。之後 ndt 沒再改過。

| | 淨 task | 牆鐘 | sudo | kernel 請求 | 出處 |
|---|---|---|---|---|---|
| 新 `--measuring`，閒置 | **12**（9–24） | 0.139 s | **0** | **0** | OBSERVED `10-*.log:8`、`11-*` |
| 新，有 declared（用 sandbox 的 claim 檔） | 17（17–26） | 0.154 s | 0 | 0 | OBSERVED `20-*.log:8`、`21-*` |
| 新，量測中 | 沒量 | | 0 | 0 | INFERRED：讀程式碼，只多一次 `mn_count` 的 ps 和三次 printf；0 sudo、0 curl 由 fixture 測試釘住 |
| 舊 plain status，量測中 | 564（524–595） | 1.58 s | 6 | 1（約 6 ms） | RESULTS.md:27-30 |
| 舊，閒置（RESULTS.md） | 448（445–450） | 1.07 s | 8 | 0 | RESULTS.md:27-29 |
| 舊，閒置（本輪重量） | 397（384–429） | 2.204 s | 7 | 0 | OBSERVED `30-*.log:8`、`31-*` |

- **換算**（INFERRED）：量測中每分鐘一次的探測，從 564 個 task、6 次 sudo、1 次 kernel 請求，降到約 12–20 個 task、0 次 sudo、0 次請求。
- **和 RESULTS.md 對帳**：同一個 ndt（sha `81c1326a…`），閒置的舊探測這次量到 397 個 task、7 次 sudo、2.2 秒；RESULTS.md 是 448 個、8 次、1.07 秒。原因沒追。這不影響新舊的比較。
- **空檔恢復**的行為不變：量測沒有 declared 時，空檔裡會有一輪完整讀取（719 個 task、8 次 sudo、1 次 graph 請求，RESULTS.md:32-34）。有 declared 就一直保持暫停。

## 3. r2 沒做完的清單

### 3.1 改用實測的數字

- **README 自動更新那一節**（原 183-189 行）：
  - 閒置一輪 596 個 task、10 次 sudo；量測中一輪 719 個、8 次，外加 1 次 graph 請求；
  - 新探測的成本；
  - 空檔恢復的行為。
- **README 其他**：測試數改成 39／18／198，加上 ndt 的測試和閘門；頁面閘門改成直接跑，不再包 guard。
- **手冊 §9**：同上，並重建 bundle（`a6d443c0`）。
- **SUMMARY-v2-r2**：§1.1 和 §2 那一列標成「被推翻」（`23e9b76f`）。

### 3.2 G-N7 在最終程式上先看紅

`L/gn7-red-first-r3-23e9b76f.log`：head 是 `23e9b76f`，porcelain 0，python 3.12.3，測試檔在 `c4247ca2`。之後 serve 的程式沒有再改過。
- **old**（`git show fed37cff…:tools/ndt_serve/serve.py`）：失敗在 token 斷言上，子程序收到 198 bytes，裡面有 `X-NDT-Token`，rc 1。
- **g48**：同樣失敗，rc 1。
- **now**：OK，rc 0。

### 3.3 合併樹：🔴 不再乾淨

**衝突**（OBSERVED）：
- `git merge-tree --write-tree trunk <head>` 回 rc 1，trunk 是 `d452d111` 和 `1e350bf2` 時都一樣。
- 衝突在 5 個檔：`test_ndt_serve.py`、`mutate_ndt_serve.sh`、`README.md`、`serve.py`、`verbs.py`，全部是 ndt 行號的引用：trunk 的 `571fa6fd` 改過同一批引用，這條分支又改了一次。
- ndt 本身自動合併成功。
- 帶著衝突的樹 `812dacd3` 是紅的（`L/merged-812dacd3-*.log`）。

**解法**：
- 對著合併後的 ndt 重算引用：lock probe 9452-9467；apps.stop 10472／10475／10478；apps.status 10405；M61、M64、M65 跟著改。
- 用私有 index 寫出 tree，再用 `commit-tree` 做成 merge commit。工作目錄沒有動。

**`1ee0089f`**：
- parents 是 trunk `1e350bf2` 和 `0170df28`，tree `f2522f6a`。
- trunk 從 `d452d111` 以來只動了 `tests/shell`，ndt 沒動。合併後的 ndt 和上一顆候選 `8dfe18a4` 逐 byte 相同，那 4 個引用檔也相同；`mutate_ndt_serve.sh` 只多了閘門的修正。
- `merge-tree trunk 1ee0089f` 回 rc 0。

**在 `1ee0089f` 上跑**（`L/merged-commit-run-r3.sh`，每個 log 都印出 commit、parents、tree、archive 指令、目錄、rc；OBSERVED）：
- 四個套件：3.12、3.8 都是 18／75／39／35，全部 OK；
- 主閘門：兩個直譯器都是 198／0；
- ndt 測試 79／0，閘門 14／0；
- 錨點 4／4、129／129。
- log：`L/mergedc-1ee0089f-*.log`。

`8dfe18a4`（對 `d452d111` 的那一顆）已被 `1ee0089f` 取代。

**沒在合併樹上跑的**：頁面套件。trunk 沒碰 `web/` 和 `static/`（INFERRED）。

### 3.4 r2 判官的測試 4–6，對著新的探測

| # | 案例 | 紅燈 |
|---|---|---|
| 4 | `Refresh.test_shown_again_while_measuring_probes_once_60_s_later`：顯示回來後 54 秒內什麼都不讀，66 秒內剛好一次 `/measuring`，沒有 tick | Q8：一顯示就探測；Q8b：顯示後不再排探測 |
| 5 | `Refresh.test_a_declared_pause_is_resumed_by_the_probe`：只有 declared 的暫停，由一次 `/measuring` 結束，接著一次 tick | Q9：把 null 當成 declaration |
| 6 | `ProbeTimeout.test_a_probe_that_times_out_keeps_the_pause_and_the_next_one_ends_it`：`--read-timeout 3`；探測先印出 `measuring nothing` 再卡住，被逾時砍掉。之後 12 秒內沒有 tick、仍是暫停；下一次正常回答的探測才結束暫停，探測計數是 2 | Q10：頁面自己解析那一列 |

三列的紅燈都在 `L/page-gate-r3-0170df28.log` 裡，也在先跑的 ONLY 那一輪裡（`L/page-gate-r3-dev-probe-only.log:86-101`）。

開發時另外抓到兩個測試本身的錯，修好了：立即更新的期望值把 `/measuring` 也算了進去；逾時案例恢復時，`/lab` 的 stub 還是 MEASURING。

## 4. 被中斷的閘門不再印出 rc=0（`0170df28`）

**問題**：前一次最終一輪磁碟不夠時，我用 SIGTERM 停掉頁面閘門，它的最後一行是 `rc=0`。那只是 EXIT trap 在 SIGTERM 後印出的 `$?`，不是判定，卻會被看成過了。

**有這個問題的閘門**：主閘門、頁面閘門、rebuild 閘門、measuring 閘門，四支都有。rebuild 閘門還有第二個問題：trap 在 `guarded … > ci.log` 裡觸發，`rc` 那一行寫進了 ci.log，而 trap 接著就把 ci.log 刪了。

**現在的做法**：
- 攔 TERM／INT／HUP，以 143／130／129 結束；
- 沒走到判定那一行，就印 `INCOMPLETE: … -- not a verdict`，而且絕不會回 0；
- 結尾的那幾行寫到閘門啟動時的 stdout（fd 7）。

**先紅後綠**（OBSERVED，`L/kill-midrun-r3.sh` 在跑到一半時，對閘門自己的 process group 送 SIGTERM）：
- 舊程式（`23e9b76f`）：主閘門、measuring 閘門、頁面閘門的 exit status 都是 143，但最後一行是 `rc=0`；rebuild 閘門既沒有 rc 行，也沒有 INCOMPLETE（`L/killed-old-*.log`）。
- 新程式：四支都以 `INCOMPLETE: stopped by SIGTERM before its verdict -- not a verdict` 加 `rc=143` 結束，process group 裡沒有殘留（`L/killed-new-*.log`；log 裡印的閘門 sha256 和 commit 進去的檔案相同）。
- 正常路徑：measuring 閘門完整跑完，14／0，rc=0（`L/ndt-measuring-gate-r3-trapfix-dev.log`）。
- 拒跑路徑：頁面閘門 `ONLY=no-such-label` 印出 REFUSED，接著 INCOMPLETE、rc=2（`L/page-gate-r3-refusal-path.log`）。

## 5. 最終一輪（`0170df28`，porcelain 0）

全部是 OBSERVED。每個 log 都只由它的指令寫入，開頭印出 head、porcelain、日期、直譯器。順序、起訖時間、rc 在 `L/final-run-r3-C-0170df28.log` 和 `L/final-run-r3-B-0170df28.log`。

| 項目 | r2（`3b6e533c`） | r3（`0170df28`） | log |
|---|---|---|---|
| 主閘門，python3.12 3.12.3 | 188／0；baseline 75／35／36／18 | **198／0**，rc 0；baseline 75／35／**39**／18 | `main-gate-r3-py312-0170df28.log:272-273` |
| 主閘門，ryu-env 3.8.20 | 188／0 | **198／0**，rc 0 | `main-gate-r3-py38-0170df28.log:272-273` |
| 四個套件，3.12 和 3.8 | 75／35／36／18 | 75／35／39／18，各自 rc 0 | `suites-r3-py312-…`、`suites-r3-py38-…` |
| 頁面套件（guard 內，miniconda 3.13.13，Chrome 153） | 29 個案例 | **32 個 OK**，617.8 s；6 個類別的殘留都是 0 | `page-suite-r3-0170df28.log` |
| 頁面閘門（完整） | 52／0；3 個等價變異 | **58／0**；E1、Q7a、Q7b 維持綠，0 個被推翻；baseline 2 的 5 個檔逐 byte 相同；61 次執行的殘留都是 0；rc 0；22,315 s，大部分在等 build guard 的鎖（另一個 session 的閘門佔著） | `page-gate-r3-0170df28.log:46-54,292-293` |
| rebuild 閘門 | 5 個檔逐 byte 相同 | 從乾淨的 `npm ci` 重建，**5 個檔逐 byte 相同**，rc 0 | `rebuild-gate-r3-0170df28.log:11-12` |
| 錨點 | ok(162)／ok(42) | ok(170)／ok(44)／ok(12)／honesty ok(67)；全部 123／123 | `anchors-r3-0170df28.log` |
| ndt measuring 測試／閘門 | （新） | 79／0；14／0 | `ndt-measuring-test-r3-0170df28.log:92`、`ndt-measuring-gate-r3-0170df28.log:32` |
| ndt honesty／status_check／round_baseline／sudo_surface 閘門；lab_handoff、residue_row 測試 | — | 67／0、20／0、26／0、14／0；19／19、27／0 | `*-r3-23e9b76f.log`（從 `23e9b76f` 到 `0170df28`，ndt 和這些測試都沒有改，只改了 serve 的四支閘門） |
| G-N7 先看紅 | `0fde4678` 加上未 commit 的檔 | old 紅、g48 紅、now 綠 | `gn7-red-first-r3-23e9b76f.log` |
| 合併樹 | 乾淨（`3a186b15`） | 有衝突；`1ee0089f` 全綠 | `merged-812dacd3-*`、`mergedc-1ee0089f-*` |

## 6. commit

| commit | 內容 |
|---|---|
| `c4247ca2` | ndt `--measuring` 和 `status_measuring_rows`；serve 的 `/measuring` 和 `measuring_fields`；verbs；行號引用；新的 shell 測試和閘門；G62–G62h；修好 G11、G11b、G24、G25 的錨點 |
| `a6d443c0` | 頁面探測改讀 `/measuring`，加上「上次探測」；SourceLint，加 G59g、G59h；瀏覽器案例和測試 4–6；頁面閘門加 Q4b、Q8、Q8b、Q9、Q10、Q12；README、手冊 §9、bundle |
| `23e9b76f` | 更正 SUMMARY-v2-r2 §1.1 的數字 |
| `0170df28` | 四支 ndt serve 閘門：被中斷時不會以 rc=0 結束 |
| （這份） | SUMMARY-v2-r3.md |
| `1ee0089f`（不在功能分支上） | 和 trunk `1e350bf2` 的合併 |

## 7. 已知、沒有處理

**沒量、沒追的**
- 新探測在量測中狀態下的成本沒有量，因為不能開 fabric（第 2 節）。
- 閒置時的舊探測，重量的結果和 RESULTS.md 對不上，原因沒追。

**要 orchestrator 決定的**
- 用不用 `1ee0089f` 來併 trunk；Adam 的規則是 `--no-ff`。
- `8dfe18a4` 那個分支可以刪掉。

**不在這張工單裡、沒動的**
- HANDOFF §6 的開放題目：G-N9、SLOT 沒有上限、SCOPE-v2 §9。
