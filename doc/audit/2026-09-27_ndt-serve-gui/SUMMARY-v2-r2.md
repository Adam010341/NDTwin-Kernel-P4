# ndt serve GUI v2 — 第二輪交付（回應 judge-NDTSERVE-GUI-V2-6c82b9f8）

[Co-developed with claude code -- Adam]

- **DELIVERED**：`feat/ndt-serve-gui-v2-0927` `189e89a0`。第 4 節表格前五列的閘門和套件都在 **`3b6e533c`** 上跑；`189e89a0` 只多了這份 SUMMARY（`evidence-r2-3b6e533c.log` 末段有 `git diff --stat`）。
- **例外**（判官 r2 的 N5）：
  - G-N7 的紅燈先行（`gn7-red-first-r2.log`）跑在 `0fde4678` 加上當時還沒 commit 的測試檔；
  - `evidence-r2-3b6e533c.log` 在 15:34 寫下首行之後，又追加過兩段（`189e89a0` 的 diff-stat、`d452d111` 的 merge-tree）；
  - 合併樹的 log 只靠檔名綁定樹 id。
- **189e89a0 之後的修正**（判官 r2 的 MERGE AFTER FIXES）都在本檔第 1、2 節直接改正；最終結果等 Adam 的兩項裁定後重跑。
- **只在分支上**：沒有併、沒有推，沒用 sudo，沒動 lab。
- **第一輪的 SUMMARY**（`SUMMARY-v2.md`）原樣保留。它和本檔不一致的地方，以本檔為準，第 2 節逐條列出。
- **標記**：OBSERVED＝本輪在 `3b6e533c` 上實際跑過，log 會印出 head。INFERRED＝推論、讀碼得出，或沒有在這顆 head 上跑過。
- **raw**：除非另外註明，log 都在 `scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2/`。

## 1. 要 orchestrator 決定的

1. **探測算不算「輕」**（判官的發現 1，請轉問 Adam）。
   - 🔴 **10-01 更正（第三輪）**：這一點原本寫的 strace 數字（221 個程序、7 次 `sudo`、一輪 287 個）不成立：ptrace 底下 setuid 失效，每次 `sudo` 都立刻失敗，root 那側什麼都沒跑。改用不經 ptrace 的量法（`/proc/stat` 程序數減等長閒置窗口、sudo 經記錄 shim、各 7 次；`live-probe-cost/RESULTS.md`）：
     - 一次探測（plain `ndt status`）：閒置 448 個 task、8 次 `sudo`；量測中（P4 4 hosts、kernel 開著、iperf3 在跑）564 個 task、6 次 `sudo`，外加一次 `GET /ndt/get_graph_data`（約 6 ms）。
     - 一輪完整讀取（`ndt status`＋`ndt apps status`）：閒置 596 個 task、10 次 `sudo`；量測中 719 個 task、8 次 `sudo`、一次 graph 請求。
   - Adam 10-01 依這些數字裁定改用**更輕的探測**（RULINGS-1001 表單 7）：第三輪的 `ndt status --measuring`，只讀 claim 的 measuring= 和程序表。閒置時量得約 12 個 task、0.14 秒、0 次 `sudo`、0 次 curl（`live-probe-cost-r3/`）。細節見 `SUMMARY-v2-r3.md`。
   - 空檔恢復的效果不變：量測沒有 declared 時，探測落在兩段量測之間的空檔就會恢復每 10 秒一次，下一段量測開始後可能有一輪完整讀取（719 個 task、8 次 `sudo`、一次 graph 請求）落在量測裡；有 declared 就一直暫停。
2. **SCOPE-v2 的公開內容**：我選**改寫**（`e74d0a63`），只寫 ndt serve 自己要求托管它的 app 做什麼。這條分支怎麼併進 trunk（squash，或重做分支歷史），等 Adam 決定；細節在 orchestrator 的 intake 紀錄，不寫在這裡。
3. **trunk 又往前了**：我開始這一輪時是 `584905d8`，不是你說的 `da10d3a3`。
   - 對 `da10d3a3`、`584905d8`、`d452d111` 做 `merge-tree --write-tree`，都沒有衝突（rc 0）。
   - `da10d3a3..trunk` 裡只有 `571fa6fd`（ndt 的時鐘修正）動到 ndt serve 的檔案：ndt 本身多了 36 行，ndt serve 這邊跟著改 RC_SOURCE 的行號、lock probe 的引用，以及 M61／M64／M65 的錨點（`evidence-571fa6fd.log`）。
   - 寫這份 SUMMARY 時，trunk 又前進到 `d452d111`：多了 3 顆 commit，都只動 `tests/shell` 裡其他工具的檢查，沒碰 ndt serve，也沒碰 ndt。合併後的樹 `3a186b15` 上，四個 Python 套件（3.12 和 3.8）和主閘門全綠（第 4 節）。

## 2. 推翻／更正第一輪的說法

| 第一輪 | 更正 | 依據 |
|---|---|---|
| 「照 §11 的裁定做」、「沒有擋住交付的題目」 | **錯了**。Adam 09-28 的 Q6（`RULINGS-0928-afternoon.md:16`）要的是量測中暫停後每 60 秒自動探測一次，我做成了只能手動恢復。這條裁定當時沒有轉給我，但交付不對就是不對。這一輪已實作（第 3 節）。 | 判官的發現 1 |
| 「Python 3.12 和 3.8 全綠」 | **3.12 那一半是錯的**：`python3` 在這台機器上是 miniconda 的 **3.13.13**。這一輪明確指定 `/usr/bin/python3.12`（3.12.3）和 ryu-env 的 `python3.8`（3.8.20），閘門會把直譯器印在 log 裡。 | `which -a python3` |
| 「app.js 是一行的 bundle」 | 51 行、291,374 bytes | `evidence-r2-3b6e533c.log` |
| 「web/src 約 3,360 行」 | 34 個檔、3,189 行（TS/TSX 是 32 個檔、2,866 行） | 同上 |
| 「每分鐘約 1,700 個程序、12 次 ndt、24 個請求」 | 那是**上限**。上一次讀完才排下一次，一次讀取約 1.2 秒，所以實際約每分鐘 5.4 輪：約 1,550 個程序，其中約 49 次 `sudo`（每輪 7＋2）。這些都是 lab 閒置時量的數字。第二輪原本寫「38 次」，漏算了 `ndt apps status` 的 2 次。🔴 10-01：這一列的 1,550 和 49 也是 strace 的數字，已被 §1.1 的更正推翻（量得閒置一輪 596 個 task、10 次 `sudo`）。 | 判官的發現 9；r2 的 N3 |
| G58c「抓到安裝時跑了 install script」 | 說過頭了。它只抓得到「manifest 寫的建置指令不同」。真的跑了 install script 的建置，寫出來的 BUILD.json 一模一樣，這要靠 rebuild 閘門。標籤已改。 | 判官的發現 5 |
| G-N7 的紅燈「token 會送給子程序」 | 第一輪的紅燈其實失敗在錯誤訊息那個斷言上。這一輪把斷言順序對調、重跑，現在失敗在 token 上，見第 4 節。 | 判官的發現 6 |
| 「CSP 計數器有效，但分不出是誰數的」 | X1（inline script 在解析 HTML 時就被擋）只可能是 buffered observer 數到的。listener 這條路徑是這一輪的 X2 才證明的。 | 判官的發現 7 |
| 頁面閘門的結果綁在 `6c82b9f8` | 第一輪的頁面閘門其實跑在 `2156786b` 加上兩個未 commit 的檔上，SUMMARY 沒講。這一輪第 4 節表格前五列都在乾淨的 `3b6e533c` 上跑（porcelain 0）；例外見檔首。 | 判官的發現 2 |

## 3. 這一輪改了什麼

| commit | 內容 |
|---|---|
| `b7ad9d7b` | **Q6 探測**。量測中暫停、頁面可見時，每 60 秒只 `GET /lab`（`readLab`），讀到沒在量測、也沒有 declared，就回到每 10 秒自動更新；頁面在背景時，tick 和探測都不讀；回到前景時只重新排探測，60 秒後才讀。附帶：重建 bundle；更新手冊 §9、README、zh.json；SourceLint 釘住探測和每個確認請求的 `preview` |
| `0fde4678` | serve.py 的註解改成「四個頁面檔」（判官的發現 10） |
| `ae2e4002` | 伺服器端：任何回應都不設 cookie（新案例）；G-N7 案例改成先看子程序收到什麼 |
| `53146b25` | 主閘門：探測 G59–G59f、preview G60–G60c、cookie G61、manifest 多出一個檔 G58d／G58e、G58c 改標籤。兩支閘門都自己印 head、porcelain、日期、直譯器，最後一行印 rc；主閘門可用 `PYTHON` 指定直譯器 |
| `e74d0a63` | SCOPE-v2 的公開內容改寫（第 1 節第 2 點） |
| `8be10b42`、`3b6e533c` | 瀏覽器套件與頁面閘門（opus worker 寫，我複查並 commit）：探測、沒有 claim 的 Up／Down、apps 對話框、打字確認、cookie／IndexedDB／CSP listener 的陽性對照、量測中按「立即更新」；兩支都自己印出處；已知的等價變異也跑，而且必須維持綠 |

## 4. 結果（OBSERVED，全部在 `3b6e533c` 上，porcelain 0）

前五列的 log 只由指令自己寫（`cmd > log 2>&1`），首行是閘門或套件自己印的 head、porcelain、日期和直譯器（rebuild 閘門不印直譯器，它用 Node）。其他幾列的情況：
- 錨點 log 的首行，是我寫下的指令說明；
- evidence log 後來追加過；
- 合併樹的 log 只有直譯器，沒有日期、目錄和 rc。

最終重跑時，這三種都會改成自己印出處。

| 項目 | 結果 | log |
|---|---|---|
| 主閘門，`/usr/bin/python3.12` 3.12.3 | **188 個變異，0 個存活**，rc=0。baseline 75／35／36／18 個案例全綠（serve／cells／gui／web） | `main-gate-r2-py312-3b6e533c.log` |
| 主閘門，ryu-env `python3.8` 3.8.20 | **188 個變異，0 個存活**，rc=0。baseline 一樣是 75／35／36／18 全綠 | `main-gate-r2-py38-3b6e533c.log` |
| rebuild 閘門 | 從乾淨的 `npm ci` 重建，五個檔逐 byte 相同（`BUILD.json` `081d5b8c…`、`app.js` `10859125…`），rc=0 | `rebuild-gate-r2-3b6e533c.log` |
| 瀏覽器頁面套件（opus worker 跑的正式那一輪，guard 內） | **29 個案例全綠**，332.7 s；5 個類別的 Chrome 殘留都是 0；之後沒有程序還指著 34 個暫存目錄。直譯器是 miniconda 3.13.13：這個套件不在 CI 裡 | `page-suite-v2-r2-1001.log` |
| 瀏覽器頁面閘門（同上） | **48 個變異，0 個存活**；3 個已知的等價變異維持綠，0 個被推翻。baseline 2：沒改過的副本重建後，五個檔逐 byte 相同。1,377 s，51 次 Chrome 執行殘留都是 0，rc=0 | `page-gate-v2-r2-1001.log` |
| 錨點檢查（`3b6e533c`，c0＝`3b6e533c`） | 主閘門 ok(162)，頁面閘門 ok(39)，rc=0。ok(n) 數的是不重複的錨點，所以比變異數少 | `anchors-r2-3b6e533c.log` |
| merge-tree、diff-stat、ls-tree、ndt 行數 | 對 `da10d3a3`、`584905d8`、`d452d111` 都沒有衝突；`node_modules`／`dist` 0 個；ndt 在 `fed37cff` 和 `3b6e533c` 都是 11,042 行，`git diff` 是空的 | `evidence-r2-3b6e533c.log` |
| 合併後的樹 `3a186b15`（trunk `d452d111` 加 `3b6e533c`） | 取出 `git merge-tree --write-tree trunk 3b6e533c` 寫出的樹來跑：四個 Python 套件在 3.12.3 和 3.8.20 下都全綠（18／75／36／35）；主閘門（3.12）188 個變異、0 個存活，rc=0。合併樹不是 git repo，所以閘門的 head 和 porcelain 兩行印不出來；樹的 id 寫在檔名上，產生它的指令和結果在 evidence log | `merged-3a186b15-*.log` |

我自己複查了 worker 那兩份 log 的首行、總數和最後一行，和它的回報一致。開發階段跑過的那幾輪（`*-dev*-1001.log`）只是過程，不算數。

## 5. 判官「我會跑的測試」逐項對照

| # | 判官的項目 | 這一輪 | 證據 |
|---|---|---|---|
| 1 | 瀏覽器端的 Q6 探測，加頁面閘門的變異 | `Refresh.test_a_measuring_pause_probes_the_lab_alone`：66 秒內只多讀一次 `/lab`，沒有 apps／health／jobs；改成閒置後會恢復。`..._reads_nothing_while_hidden`：隱藏 68 秒，0 次讀取。變異 Q1–Q7 | `page-gate-v2-r2-1001.log`：Q1 在 204 行、Q2 208、Q3 212、Q4 216、Q5 220、Q6 224、Q7 228（`lab 2 != 1`）；Q7a 232、Q7b 234 是等價變異，維持綠。SourceLint 那一層：G59–G59f |
| 2 | 瀏覽器端沒有 claim 的 Up／Down，加「只擋別人的 claim」的變異 | `Confirm.test_no_claim_puts_claim_first`（`claim none` 和完全沒有 claim 列兩種）；變異 CF1、CF2 | CF1 在 120 行（完全沒有 claim 列那一半）、CF2 在 123 行（`claim none` 那一半） |
| 3 | 一個 apps 或 cell 的對話框，加 `preview:false` 的變異 | `Confirm.test_an_app_start_shows_the_dry_run_and_claim_first`；瀏覽器變異 A1；SourceLint 變異 G60／G60b／G60c | A1 在 126 行；argv 是從 Chrome 的 Network 紀錄讀到的 dry run 回答（`[ndt, "apps", "energy"]`） |
| 4 | 打字確認的變異 | W1 任何文字、W2 字首、W3 以那個字開頭 | W1 在 130 行、W2 134、W3 138；案例也會打 `upx` |
| 5 | cookie、`indexedDB.databases()` 的陽性對照；關掉 observer 的執行期 CSP 違規 | T5、T6、X2 | T5 在 70 行、T6 74、X2 102（關掉 observer 後，執行期的 `setAttribute("style")` 讓計數讀到 `'1'`） |
| 6 | 伺服器端：沒有回應設 cookie | `Page.test_no_answer_sets_a_cookie`，變異 G61 | 主閘門 log |
| 7 | 在最終的樹上，用明確指定的 3.12 和 3.8 跑 Python 套件 | 第 4 節 | log 首行有直譯器 |
| 8 | 舊的 `url_command`，token 斷言放第一個 | `gn7-red-first-r2.log`：`fed37cff` 版的 serve.py 和 G48 變異兩種情況，都失敗在 token；子程序收到 198 bytes，含 `X-NDT-Token`。現在的 serve.py 是綠的 | OBSERVED，但跑在 `0fde4678` 加上未 commit 的測試檔，不是 `3b6e533c`；最終重跑時會在交付的 head 上重做 |
| 9 | 雜湊清單對 head、merge-tree、diff-stat、ls-tree | 這一輪的 log 都由閘門自己印 head；`evidence-r2-3b6e533c.log` | OBSERVED |
| 10 | static/ 和 web/ 多出一個檔的變異 | G58d、G58e | 主閘門 log |

第一輪「看過紅但沒有具名變異」的子保證（判官的發現 7），現在都有了：
- 打字確認：W1–W3；
- cookie／IndexedDB：T5、T6；
- CSP listener：X2；
- 量測中按「立即更新」不會恢復：R6；
- manifest 多出一個檔：G58d、G58e。

## 6. 已知、沒有處理（INFERRED，沒有在瀏覽器裡跑）

- 「量測中回到前景後，探測會重新排上」：沒有獨立的瀏覽器案例，要多等 60 秒。SourceLint 釘了 `onVisibility` 的寫法，主閘門的 G54c 抓得到。
- apps 只驅動 start，沒有驅動 stop。「沒有 claim」只測了 `claim none` 和完全沒有 claim 列兩種，`EXPIRED … -- treated as free` 這種寫法沒測；伺服器端對 cells 和 apps 的過期 claim 有案例。
- Q7a、Q7b 是**等價變異**：arm() 和 probe() 的兩個隱藏檢查互相撐著，只拿掉一個，行為不變。頁面閘門會跑這兩個，要求它們維持綠；兩個一起拿掉的 Q7 會變紅。靜態那一層，G59c 和 G59d 各自抓得到。
- `testhooks.ts` 會出現在正式的 bundle 裡，把 `document.cookie` 複製進 DOM。cookie 只依 host 區分、不分 port，所以 127.0.0.1 上的其他服務設的 cookie，也會出現在 `document.cookie`，被複製進 DOM。G61 釘住的只是 ndt serve 自己不設 cookie。token 不在 cookie 裡，所以這對 token 無害（判官 r2 的 N8）。
- `/lab` 讀取逾時時，`measuring_is_nothing` 是 false，自動更新會停在「量測中」。現在探測每 60 秒會再讀一次，讀到正常回應就自己恢復，判官的發現 1 提到的情況因此改善。

## 7. 怎麼重跑

```bash
PYTHON=/usr/bin/python3.12 bash tests/shell/mutate_ndt_serve.sh
PYTHON=$HOME/miniconda3/envs/ryu-env/bin/python3.8 bash tests/shell/mutate_ndt_serve.sh
bash tests/shell/rebuild_ndt_serve_web.sh
JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh python3 tests/browser/test_ndt_serve_page.py
bash tests/shell/mutate_ndt_serve_page.sh
```
