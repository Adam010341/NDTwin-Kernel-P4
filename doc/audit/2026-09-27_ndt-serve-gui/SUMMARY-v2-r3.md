# ndt serve GUI v2 — 第三輪交付（更輕的探測、被中斷的閘門、r2 剩下的清單；含第四輪的修正）

[Co-developed with claude code -- Adam]

- **程式的 head**：`feat/ndt-serve-gui-v2-0927` `73889e54`。這份 SUMMARY 由 orchestrator commit 在它之上。
- **正式閘門**（第 5 節）：
  - 頁面套件和頁面閘門在 `0170df28` 上跑。之後頁面和頁面閘門都沒動過。
  - 其餘在 `73889e54` 上跑。
  - 兩次都是 porcelain 0，跑的期間沒有改檔。
- **trunk 合併**：功能分支和 trunk 已經不能乾淨合併（第 3.3 節）。解好的 merge commit 是 `3e8148ab`，放在本機分支 `feat/ndt-serve-gui-v2-0927-r4-merge-1e350bf2`。功能分支本身沒動。
- **範圍**：沒有併進 trunk、沒有 push、沒用 sudo、沒 claim、沒開 fabric。
- **標記**：OBSERVED＝本輪實際跑過，引用的 log 會印出 head 或 commit。INFERRED＝推論、計算，或沒有在這顆 head 上跑。
- **raw**：`L/`＝`scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2/`。過程筆記在 `L/r3-notes.log`。

## 1. Adam 的裁定：探測只問「有沒有人在量測」（RULINGS-1001 表單 7）

### 1.1 做了什麼

**ndt：`ndt status --measuring`**
- 只印 plain status 回答這個問題的那幾列：`declared`、`measuring`；沒有 fabric 時改印 `orphaned`。
- `cmd_status` 裡原本那 34 行，原封不動移進 `status_measuring_rows`（`ndt:6682-6717`）。plain status 和 `--measuring` 都呼叫它，兩邊不會答得不一樣。
- 它只用 `measuring_declared`、`in_flight`、`mn_count`、`claim_field`，也就是只讀 claim 檔和 `ps`。
- `--measuring` 在 `cmd_status` 的最前面就 return（`ndt:6720-6726`），rc 一律是 0。
- `ndt help` 改成 `status [--check | --measuring]`，並加了一段說明。

**serve：`GET /measuring`**
- 執行 `ndt status --measuring`。
- 回應的 `measuring`、`declared`、`measuring_is_nothing` 和 `/lab` 用同一段 `measuring_fields` 讀；沒有 `claim` 欄。
- 要 token，佔一個讀取槽，有逾時。
- verbs 加了 `ARGV_STATUS_MEASURING` 和 rc 表 `status.measuring`。RC_SOURCE 的出處是 help 片語和 `ndt:6725`。

**頁面**
- 量測中暫停時，探測只讀 `/measuring`（`readProbe`），不改任何分頁。
- 「上次讀取」永遠是最後一次完整讀取的時間；暫停時旁邊另外顯示「上次探測」。
- 探測讀到沒在量測、也沒有 declared，就恢復每 10 秒一次的完整讀取。
- 探測失敗或逾時時，「上次探測」照樣更新。這一點 orchestrator 延到下一次 GUI 交付處理。

**不變的保證**：loopback、token、CSP、不設 cookie、`preview:true`、claim-first。

### 1.2 釘住它的測試（每一條都看過紅）

`tests/shell/test_ndt_status_measuring.sh`，102 個 check，用 8 種 fixture 狀態：只有 declared、只有 in_flight、兩者都有、兩者都無、claim 過期、別人的 claim、orphaned、兩個 driver。

**答案和 plain status 相同**
- 每種狀態都比兩件事：
  - 輸出是 plain status 裡連續的一段，三列的值都相同；
  - 這幾列寫的內容本身是對的。
- 紅燈：拿 `59e3ba1f` 的 ndt 跑，11 個失敗、rc 1（`L/ndt-measuring-red-first-r3.log:478-479`）。

**「不用 sudo、不打 kernel、不查 OVS／bmv2」分四層**。第三輪只靠 PATH 黑名單，第四輪的判官指出 ndt 自己的 `port_open`（bash `/dev/tcp`，`ndt:148`）、python3 urllib、絕對路徑都繞得過去，所以補了後三層：
- **a. 黑名單**：15 個 PATH shim（sudo、curl、OVS、bmv2……），8 種狀態下記錄都必須是空的。對照組：plain status 經過同樣的 shim，確實會記到 sudo。
- **b. 白名單 PATH**：PATH 上只放 `--measuring` 需要的 cat、cut、date、dirname、head、readlink、sed、wc 和 ps shim（10-02 在空 PATH 上逐一找出）。export 一個 `command_not_found_handle`，它要別的指令就記下來。8 種狀態都要記錄為空。對照組：plain status 在同一個 PATH 上會被記到要更多指令。
- **c. 網路**：在自己的 network namespace（`unshare -rn`）裡，127.0.0.1:8000、:8080、:8081 上的 listener 數 `--measuring` 跑的期間有幾條連線，8 種狀態都必須是 0。對照組：同樣方式跑 bash `/dev/tcp` 和 python3 urllib，都會被數到。
  - 沒有 namespace、而且 port 被佔時，這一條是 FAILED，不是通過。
  - 這台機器走的是 namespace；「沒有 namespace 時改用 host 上空著的 port」那條路沒有實際跑過（INFERRED）。
- **d. 靜態**：從 `status_measuring_rows` 出發，能到的函式必須剛好是那五個；其中任何一個都不能出現 `/dev/tcp`、`/dev/udp`，也不能用絕對路徑跑指令。

**ndt 端的變異閘門**：`tests/shell/mutate_ndt_status_measuring.sh`，19 個，全抓到（`L/ndt-measuring-gate-r4-73889e54.log:38`）。
- L1：退回完整報告。
- L2、L3：兩邊各留一份副本。
- L4、L5、L5b：PATH 上的 sudo、kernel 請求、bmv2 查詢。
- L6：rc。
- L7–L12：答案。
- L13：help。
- L14：`port_open 8000`。
- L14b：直接寫 `/dev/tcp`。
- L15：python3 urllib GET。
- L16：`/usr/bin/ovs-vsctl list-br`。為了不讓閘門自己發出 sudo，用它代替 `/usr/bin/sudo -n true`；靜態檢查看的是文字，兩者抓法一樣。
- L16b：`/usr/bin/curl` 打 :8000。

**第三輪的漏洞實際示範**（`L/pin-hole-r4.log`）：同樣 5 個繞過的變異，第三輪的測試（`51f61eea`）全是綠的（79/0），第四輪的測試每個都紅。

**serve 和頁面**
- serve：測試是 `test_ndt_serve_gui.py` 新增 3 個案例、擴充 2 個。主閘門 G62–G62h 全抓到（`L/main-gate-r4-py312-73889e54.log`）。
- 頁面靜態檢查：SourceLint，加上 G59 系列和 G59g、G59h。
- 頁面瀏覽器：`Refresh.test_a_measuring_pause_probes_measuring_alone`，頁面閘門的 Q1–Q5、Q4b、Q12（`L/page-gate-r3-0170df28.log`）。

### 1.3 動 ndt 之後跟著搬的錨點

`cmd_status` 的判定之前多了 23 行，下方每一列都要跟著改：
- **RC_SOURCE**：status.check 7086／7091／7095；status 7097；apps.start 8918／8922／8995；apps.stop 10436／10439／10442；apps.status 10369；status.measuring 6725。
- **lock probe**：9439-9454。
- **主閘門**：M61、M63（8922，替換成 8462）、M64、M65。
- **註解**：serve.py、verbs.py 的註解。
- **不用動的**：`claim_line` 沒改，G49 和 ClaimFormProvenance 不受影響。

我自己的重構一度弄壞了 G11、G11b、G24、G25 的錨點（`L/anchors-all-r3-51087860.log`），修好後 amend 成 `c4247ca2`。

最終錨點（`L/anchors-r4-73889e54.log`）：主閘門 ok(170)、頁面閘門 ok(44)、measuring ok(12)、honesty ok(67)；所有閘門 123/123。

## 2. 成本：新探測和舊探測

**量法**和 RESULTS.md 一樣：
- `/proc/stat` 程序數的差，減掉等長的閒置窗口；
- 7 次取中位數；
- sudo、curl 走記錄 shim；
- 不用 strace。

腳本：`L/live-probe-cost-r3/run.sh`。量測前後 lab 都閒置（`00-header.log:4-15`）。新 ndt 的 sha256 是 `408310c7…`；從這次量測到現在，ndt 沒再改過。

| | 淨 task | 牆鐘 | sudo | kernel 請求 | 出處 |
|---|---|---|---|---|---|
| 新 `--measuring`，閒置 | **12**（9–24） | 0.139 s | **0** | **0** | OBSERVED `10-*.log:8`、`11-*` |
| 新，有 declared（sandbox 的 claim 檔） | 17（17–26） | 0.154 s | 0 | 0 | OBSERVED `20-*.log:8`、`21-*` |
| 新，量測中 | 沒量 | | 0 | 0 | INFERRED：看程式碼只多一次 `mn_count` 的 ps 和三次 printf；0 sudo、0 連線由測試的四層在 fixture 下釘住 |
| 舊 plain status，量測中 | 564（524–595） | 1.58 s | 6 | 1（約 6 ms） | RESULTS.md:27-30 |
| 舊，閒置（RESULTS.md） | 448（445–450） | 1.07 s | 8 | 0 | RESULTS.md:27-29 |
| 舊，閒置（本輪重量） | 397（384–429） | 2.204 s | 7 | 0 | OBSERVED `30-*.log:8`、`31-*` |

**換算**（INFERRED）：量測中每分鐘一次的探測，從 564 個 task、6 次 sudo、1 次 kernel 請求，降到約 12–20 個 task、0、0。

**兩次閒置量測為什麼不同**：用的是同一個 ndt（`81c1326a…`），差別在 lab 的狀態。
- RESULTS.md 的閒置那次在 16:57:19。當時 `.test_run/up.target` 還留著 09-30 的舊紀錄：16:57:02 的 plain status 還印出完整的 up target 比對（`live-probe-cost/00-pre-status.txt:44-52`）。那段比對多呼叫一次 `ovs-vsctl list-br`（`11-idle-sudo-status.log:8`），所以是 8 次 sudo，task 也比較多。
- 這筆紀錄在 17:11:35 被 `ndt down` 清掉（`57-pre-vs-after.diff:24-29`）。19:55 重量時已經沒有它，每次 7 次 sudo（`live-probe-cost-r3/31-old-idle-sudo.log`）。
- 19:55 時機器也比較忙：閒置窗口有 63–99 個 fork（`30-old-idle-forks.log`），先前那次是 0–14（`10-idle-forks.log`）。牆鐘 2.2 秒、範圍比較寬，都是這個原因。
- README 的「閒置一輪 596 個 task、10 次 sudo」，是留著舊 up.target 時的數字。
- 這些差別不影響新舊探測的比較。

**空檔恢復**：量測沒有 declared 時，兩段量測之間的空檔裡可能有一輪完整讀取（719 個 task、8 次 sudo、一次 graph 請求，RESULTS.md:32-34）。有 declared 就一直暫停。

## 3. r2 剩下的清單

### 3.1 數字改用實測值

- **README 自動更新一節**：閒置一輪 596／10、量測中 719／8 加一次 graph 請求、新探測的成本、空檔恢復。
- **README 其他**：測試數 39／18／198，列出 ndt 的測試和閘門；頁面閘門改成直接跑。
- **手冊 §9**：同上，並重建 bundle（`a6d443c0`）。
- **SUMMARY-v2-r2**：§1.1 和 §2 那一列標為被推翻（`23e9b76f`）。

### 3.2 G-N7 先看紅

`L/gn7-red-first-r3-23e9b76f.log`：head `23e9b76f`、porcelain 0、python 3.12.3。之後 serve 的程式沒有改過。
- **old**（`fed37cff` 的 serve.py）：失敗在 token 斷言，子程序收到 198 bytes，含 `X-NDT-Token`，rc 1。
- **g48**：同樣失敗，rc 1。
- **now**：OK，rc 0。

### 3.3 合併：🔴 不能乾淨合併

**merge-tree 的 rc**：都是指令輸出，見 `L/mergedc-3e8148ab-merge-tree.log`。
- `git merge-tree --write-tree trunk 73889e54`（trunk `1e350bf2`）：rc=1（第 19 行）。
  - 衝突在 5 個檔：`test_ndt_serve.py`、`mutate_ndt_serve.sh`、`README.md`、`serve.py`、`verbs.py`，全部是 ndt 行號的引用。trunk 的 `571fa6fd` 改過同一批，這條分支又改了一次。
  - ndt 本身自動合併成功。
- 同一份 log 裡，`git merge-tree --write-tree trunk 3e8148ab`：rc=0（第 22 行）。
- 更早 `d452d111` 那次的衝突樹 `812dacd3` 是紅的（`L/merged-812dacd3-*.log`）。

**解法**：
- 對著合併後的 ndt 重算引用：lock probe 9452-9467；apps.stop 10472／10475／10478；apps.status 10405；M61、M64、M65 跟著改。
- `mutate_ndt_serve.sh` 裡 trunk 那句過時的註解「10346 -> 10382」，補上這條分支多加的 23 行。
- 用私有 index 寫出 tree，再用 `commit-tree` 做出 `3e8148ab`：parents 是 `1e350bf2` 和 `73889e54`，tree 是 `dcdc2380`。
- 四個引用檔和上一顆候選 `1ee0089f` 逐 byte 相同。

**在 `3e8148ab` 上跑（OBSERVED）**：腳本 `L/merged-commit-run-r4.sh`。每個 log 都印 commit、parents、tree、`git archive <mc> | tar`（整棵樹）、目錄，每一步都印 rc。

| 項目 | 結果 | log |
|---|---|---|
| 四個套件，3.12 和 3.8 | 18／75／39／35 OK | `mergedc-3e8148ab-suites-py312.log`、`-py38.log` |
| 主閘門，3.12 和 3.8 | 198／0 | `mergedc-3e8148ab-main-gate-py312.log:280`、`-py38.log:280` |
| measuring 測試、閘門 | 102／0、19／0 | `mergedc-3e8148ab-measuring-test.log:119`、`-measuring-gate.log:41` |
| status_check 閘門 | 24／0（trunk 那一版有 24 個變異） | `mergedc-3e8148ab-status-check-gate.log:38` |
| honesty 閘門 | 67／0 | `mergedc-3e8148ab-honesty-gate.log:81` |
| residue_row、lab_handoff 測試 | 27／0、19／19 | `mergedc-3e8148ab-residue-row-test.log:47`、`-lab-handoff-test.log:30` |
| 錨點 | 4／4、129／129 | `mergedc-3e8148ab-anchors.log` |
| 頁面套件（從抽出來的樹跑，guard 內） | 32 個 OK，619.051 s，殘留 0 | `mergedc-3e8148ab-page-suite.log:67` |

**沒在合併樹上跑的**：
- 頁面閘門、rebuild 閘門；
- round_baseline、sudo_surface 兩個閘門；
- G-N7。

**被取代的候選**：`8dfe18a4`、`1ee0089f`。

**注意**：這份 SUMMARY commit 之後，分支 head 就比 `3e8148ab` 的第二個 parent 多一顆，合併時要重做一次。

### 3.4 r2 判官的測試 4–6，對新的探測

| # | 案例 | 紅燈 |
|---|---|---|
| 4 | `Refresh.test_shown_again_while_measuring_probes_once_60_s_later` | Q8、Q8b |
| 5 | `Refresh.test_a_declared_pause_is_resumed_by_the_probe` | Q9 |
| 6 | `ProbeTimeout.test_a_probe_that_times_out_keeps_the_pause_and_the_next_one_ends_it` | Q10 |

都在 `L/page-gate-r3-0170df28.log` 裡。

## 4. 被中斷的閘門不再印出 rc=0（`0170df28`，第四輪補強）

**問題**：主閘門、頁面閘門、rebuild 閘門、measuring 閘門被 SIGTERM 停掉時，最後一行是 EXIT trap 印的 `rc=0`，看起來像通過。rebuild 閘門的 trap 在 `guarded … > ci.log` 裡觸發，那一行寫進 ci.log，接著 ci.log 又被 trap 自己刪掉。

**現在的做法**：
- 攔 TERM、INT、HUP，以 143、130、129 結束；
- 沒走到判定那一行，就印 `INCOMPLETE: … -- not a verdict`，而且不回 0；
- 結尾的那幾行寫到閘門啟動時的 stdout（fd 7）；
- 第四輪起，主閘門、measuring 閘門、rebuild 閘門開頭都會印出自己的 sha256。

**先紅後綠**（OBSERVED）：
- **舊程式**（`23e9b76f`）：三支閘門 exit 143，但最後一行是 `rc=0`；rebuild 閘門什麼都沒印（`L/killed-old-*.log`）。
- **新程式**：四支都印 INCOMPLETE 加 `rc=143`（`L/killed-new-*.log`）。

**第四輪在 `73889e54` 上補的**（`L/kill-midrun-r4.sh`，`L/killed-r4-*.log`）：
- INT：measuring 閘門 exit 130，加 INCOMPLETE。
  - 第一次試 INT 被忽略了：非互動 shell 用 `&` 起的程序，一開始就忽略 SIGINT，bash 無法攔一個進來時就被忽略的訊號。launcher 改成先把 INT 恢復成預設再 exec。
  - 那次的 log 保留為 `killed-r4-int-measuring-gate.IGNORED-launcher.log`。
- TERM：主閘門、rebuild 閘門、頁面閘門（baseline 1 跑到 60 秒時）都是 143 加 INCOMPLETE。
- 殺掉之後掃 /tmp 和 /proc：閘門自己建的暫存目錄都不在了，也沒有任何程序的 cmdline 或 cwd 還指著它們。
- 其他路徑：
  - 正常結束：measuring 閘門 rc=0；
  - 拒跑：頁面閘門加 `ONLY=no-such-label`，印 REFUSED、INCOMPLETE、rc=2（`L/page-gate-r3-refusal-path.log`）。

## 5. 最終一輪

全部 OBSERVED。每個 log 都只由它的指令寫入，開頭印 head、porcelain、日期、直譯器。

| 項目 | r2（`3b6e533c`） | 最終 | log |
|---|---|---|---|
| 主閘門，python3.12 3.12.3 | 188／0；baseline 75／35／36／18 | `73889e54`：**198／0**，rc 0；baseline 75／35／39／18 | `main-gate-r4-py312-73889e54.log:273-274` |
| 主閘門，ryu-env 3.8.20 | 188／0 | `73889e54`：**198／0**，rc 0 | `main-gate-r4-py38-73889e54.log:273-274` |
| 四個套件，3.12 和 3.8 | 75／35／36／18 | `0170df28`：75／35／39／18，各自 rc 0（之後這些套件和它們測的程式都沒改） | `suites-r3-py312-0170df28.log`、`-py38-…` |
| 頁面套件 | 29 | `0170df28`：**32 個 OK**，617.823 s，殘留 0 | `page-suite-r3-0170df28.log:56` |
| 頁面閘門（完整） | **48／0**，3 個等價變異 | `0170df28`：**58／0**；E1、Q7a、Q7b 維持綠；61 次執行殘留都是 0；rc 0 | `page-gate-r3-0170df28.log:292-293` |
| rebuild 閘門 | 5 個檔逐 byte 相同 | `73889e54`：從乾淨的 `npm ci` 重建，5 個檔逐 byte 相同 | `rebuild-gate-r4-73889e54.log` |
| 錨點 | ok(162)／**ok(39)** | `73889e54`：ok(170)／ok(44)／measuring ok(12)／honesty ok(67)；所有閘門 123/123 | `anchors-r4-73889e54.log` |
| measuring 測試、閘門 | （新） | `73889e54`：102／0、19／0 | `ndt-measuring-test-r4-…:117`、`-gate-r4-…:38` |
| honesty、status_check、round_baseline、sudo_surface 閘門；lab_handoff、residue_row 測試 | — | `23e9b76f`：67／0、20／0、26／0、14／0；19／19、27／0。ndt 和這些測試之後都沒改；honesty 和 status_check 在合併樹上又跑了一次（第 3.3 節） | `*-r3-23e9b76f.log` |
| G-N7 | `0fde4678` 加上未 commit 的檔 | old 紅、g48 紅、now 綠 | `gn7-red-first-r3-23e9b76f.log` |

**兩次頁面套件的秒數一模一樣**：獨立跑的頁面套件和頁面閘門的 baseline 1，都是 `Ran 32 tests in 617.823s`。兩次是先後分開跑的：
- 頁面套件的 log 開頭時間是 02:53:49，03:04:07 結束；
- 頁面閘門 03:04:07 開始，baseline 1 含等鎖共 1,938 s。

時間沒有重疊，所以秒數相同只是巧合。這個套件大約 600 秒都是固定的即時等待，各次只差 615.0–619.1 秒。合併樹上那次是 619.051 s。

頁面閘門花了 22,315 s，大部分在等 build guard 的鎖，另一個 session 的閘門佔著它。

## 6. commit

| commit | 內容 |
|---|---|
| `c4247ca2` | ndt `--measuring`、`status_measuring_rows`；serve 的 `/measuring`、`measuring_fields`；verbs；行號引用；shell 測試和閘門；G62–G62h；修好 G11、G11b、G24、G25 的錨點 |
| `a6d443c0` | 頁面探測改讀 `/measuring`、加「上次探測」；SourceLint、G59g、G59h；瀏覽器案例和測試 4–6；頁面閘門 Q4b、Q8、Q8b、Q9、Q10、Q12；README、手冊 §9、bundle |
| `23e9b76f` | 更正 SUMMARY-v2-r2 §1.1 |
| `0170df28` | 四支閘門被中斷時不會以 rc=0 結束 |
| `51f61eea` | SUMMARY-v2-r3（orchestrator commit） |
| `73889e54` | 讓 `--measuring` 的「不打網路」規則不只靠 PATH 把關（第 1.2 節）；三支閘門印出自己的 sha256 |
| （這份更正） | SUMMARY-v2-r3.md |
| `3e8148ab`（不在功能分支上） | 和 trunk `1e350bf2` 的合併 |

## 7. 已知、沒有處理

- 新探測在量測中狀態下的成本沒有量，因為不能開 fabric。
- 探測失敗或逾時時「上次探測」照樣更新：延到下一次 GUI 交付。
- 網路那一層「沒有 namespace 時改用 host 上空著的 port」的退路，在這台機器上沒有實際跑過。
- trunk 合併：要不要用 `3e8148ab`（commit SUMMARY 之後要重做），由 orchestrator 決定；`8dfe18a4`、`1ee0089f` 的分支可以刪。
- HANDOFF §6 的開放題目沒動：G-N9、SLOT 沒有上限、SCOPE-v2 §9。
