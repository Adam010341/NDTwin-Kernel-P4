# ndt serve GUI v2 — 第一次交付

[Co-developed with claude code -- Adam]

- **分支**：`feat/ndt-serve-gui-v2-0927`，從 trunk `fed37cff` 開，worktree `scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927`。
  **只放在分支上，沒有併、沒有推。** 交付的 head 寫在送給 orchestrator 的訊息裡；這份檔是那一串裡的最後一個 commit。
- **和現在的 trunk**：對 `da10d3a3` 做 `git merge-tree --write-tree` 沒有衝突（rc 0）。從 `fed37cff` 到現在，trunk 沒有動過 ndt serve 的任何檔案。
- **依據**：SCOPE-v2（`0d7f6ce8`）§9 的第一次交付，以及 orchestrator 對 §11 六題的裁定。
- **raw**：除非另外註明，log 都在 `scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2/`。

## 1. 要 orchestrator 裁的

沒有擋住交付的題目。下面兩點請過目：

1. **「先 claim」在瀏覽器裡只用 Up 驅動**。apps start/stop 和 cell run 也帶 `needs_own_claim`，但瀏覽器沒有逐一點過，靠的是伺服器端的案例，由主閘門的變異看過紅：
   - apps：`AppsNeedYourClaim`，G41；
   - cells：`CellsRun.test_lab_cell_run_needs_your_claim`，C17、C18；
   - walk：`GuidedWalk.test_walk_run_rechecks_the_claim`。

   要不要在第二次交付補上瀏覽器端的案例？
2. **PR 的 diff 會很大**：`fed37cff..head` 共 61 個以上的檔案、約 +8,600 行。大宗是：
   - `web/package-lock.json`，2,914 行；
   - `static/app.js`，290 KB、一行的 bundle；
   - `web/src` 約 3,360 行。

   我逐檔看過清單，沒有夾帶 `node_modules` 或 `dist`。`web/.gitignore` 照 repo 裡另外 35 個 `.gitignore` 的前例，用 `add -f` 加進來，因為根目錄的 `.gitignore` 會把它忽略。

## 2. 推翻／更正

- **前端 worker 自報的建置結果，現在複查過了。** 之前我標的是「未複查」。
  - `test_ndt_serve_web.py`：16/16，Python 3.12 和 3.8（ryu-env）都綠。
  - rebuild 閘門：從乾淨的 `npm ci` 重建，五個檔和 commit 進來的**逐 byte 相同**。`BUILD.json` 的 sha 是 `781369038a8e…`，`app.js` 是 `db950b46…`（`rebuild-gate-1001.log`）。
- **CSP 計數器有效。** 前端 worker 說它沒驗證 Chrome 153 會不會把 csp-violation 交給 `ReportingObserver`。頁面閘門的 X1 在建好的 `index.html` 裡插一段 inline script，`data-csp-violations` 讀到 1，案例變紅（`verify-page-gate-1001.log:79`）。所以計數器真的會數；但是 listener 還是 observer 數到的，沒有分開量。
- **一個等價變異**：只拿掉 `cancelRef.current?.focus()`，案例照樣綠（`page-gate-v2-focus-equivalent-1001.log`）。推測是 `showModal()` 本來就把焦點放在第一個可聚焦的元素，也就是 Cancel。所以 C6 改成把焦點移到 Confirm。這不是頁面的 bug。

## 3. 交付

**Commits**：

| commit | 內容 |
|---|---|
| `f3a20447` | 伺服器：`--webgui-url`、`ndt serve url` 先連線再驗對方（G-N7）、OWN_CLAIM 對 ndt 的 pin 測試 |
| `6d5621ab` | `tests/browser/cdp_pipe.py`：只用標準庫的 DevTools 驅動 |
| `b46048c5` | `tools/ndt_serve/web/`：React 19、Vite 6、Tailwind 3.4、i18next；npm 加 lockfile，版本鎖死 |
| `5732a5d9` | `static/`：建好的頁面和手冊；伺服器白名單加 `/manual.html`；`test_ndt_serve_web.py`；拿掉舊的 PageLint |
| `ad40d7fd`、`2156786b` | 主閘門：頁面的變異改去改 TS 原始碼和建好的檔 |
| `2f944781` | `tests/shell/rebuild_ndt_serve_web.sh`：重建後逐 byte 比對 |
| `9bdde370` | README |
| `cde49366` | `tests/browser/test_ndt_serve_page.py`：改用 DevTools 驅動，25 個案例 |
| `1986a6a9` | `tests/shell/mutate_ndt_serve_page.sh`：每個 mutant 重建一次，31 個變異 |

**我自己跑過的結果**（瀏覽器和 npm 一律在 guard 內）：

| 項目 | 結果 | log |
|---|---|---|
| `test_ndt_serve_web.py` / `test_ndt_serve.py` / `_gui.py` / `_cells.py` | 16 / 75 / 35 / 35，全綠（3.12 和 3.8） | `verify-suites-1001.log`、`verify-suites-py38-1001.log`、`suites-final-1001.log` |
| 主閘門 `mutate_ndt_serve.sh` | **176 個變異，0 個存活**（head `1986a6a9`）；受測檔案從頭到尾沒變 | `main-gate-final-1001.log` |
| 頁面套件 | 25 個案例全綠，112.9 s；5 個類別的 Chrome 殘留都是 0 | `verify-page-1001.log` |
| 頁面閘門 | **31 個變異，0 個存活**，450 s。baseline 2：沒改過的副本重建後就是 commit 進來的 `static/`，逐 byte 相同 | `verify-page-gate-1001.log` |
| rebuild 閘門 | OK，逐 byte 相同 | `rebuild-gate-1001.log` |
| 錨點檢查 | 主閘門 ok(154)，頁面閘門 ok(27) | `anchors-final-1001.log` |

頁面套件和頁面閘門是 opus worker 寫的。上表是我自己在 guard 內重跑的結果，worker 自己那一輪記在 `page-suite-v2-1001.log` 和 `page-gate-v2-1001.log`。

## 4. SCOPE-v2 §5 每一項的紅燈先行

- **瀏覽器那一欄**：`verify-page-gate-1001.log` 裡每個變異的 caught 行號，是我自己跑的那一輪。
- **原始碼與 bundle 那一欄**：主閘門的 G 變異，由 `test_ndt_serve_web.py` 抓（`main-gate-final-1001.log`）。

| §5 的保證 | 瀏覽器（變異：行） | 原始碼與 bundle（G） |
|---|---|---|
| token 不在 DOM | T1 把 token 寫進 `<body data-t>`：43 | — |
| token 不在 storage、cookie、`indexedDB.databases()` | T3 寫進 sessionStorage：51；T4 在 localStorage 記分頁：55 | G15 sessionStorage、G15b cookie、G15e test hook 寫入 storage |
| token 不在 profile（判官 G-N8 要的陽性對照） | T2 寫進 IndexedDB，只有掃 profile 檔才看得到（`Default/IndexedDB/…/000003.log`）：47 | G15d 開 IndexedDB |
| 只 POST 一次 `/session`（G-N10） | S1 在 session 模組多交換一次：59 | G51 session 模組多 POST 一筆、G16b 繞過 `post()` 直接 `call()` |
| fragment 被清掉 | F1 拿掉 `replaceState`：63 | G52 拿掉、G52b 換完 token 才清 |
| 載入時不寫入 | L1 一載入就 release：75 | G17 在對話框外 `post()`、G16 第二個 fetch、G16c beacon |
| 確認強度來自 `confirm_policy` | C1 伺服器改成 plain：83；C5 頁面不看 `confirm`：87；C4 claim 被要求打字：105 | （伺服器端：`gui:DryRun.test_the_dialogs_strength_is_the_servers`，既有的 G 變異） |
| claim 不是你的 → 先 claim | C2 頁面不看 `needs_own_claim`：91；C2b 伺服器不回 `own_claim`：94 | — |
| 量測中或已宣告 → 升級成打字確認 | C3 不看 measuring：97；C3b 不看 declared：101 | — |
| 焦點在 Cancel、Enter 不確認、連點只送一次 | C6：109；C7：113；C8：117（log 是 200、202、409） | — |
| dry_run 預覽 | D1 頁面自己組 argv：121；D2 不先 dry_run：125 | — |
| 輪詢：可見且閒置時會讀 | R0 計時器沒裝上：129 | G54d setInterval、G54e 改成 2 秒 |
| 輪詢：隱藏時停、回來會恢復 | R1 拿掉三處隱藏檢查：133；R1b 回來不讀：137 | G54、G54b |
| 輪詢：量測中停、已宣告停 | R2 `arm()` 不暫停：141；R2a 不看 measuring：145；R2b 不看 declared：149 | G53、G53b、G54c 回到前景時無視量測中 |
| job log：Close、結束、隱藏時停 | R3：153；R4：157；R5：161 | G37、G40、G38、G38b、G39 |
| CSP 不被破壞 | X1 inline script，計數器讀到 1：79 | G29 inline handler、G29b inline script、G29c 外部來源、G57 eval、G57b CSS @import、G57c 手冊有 script、G15c `dangerouslySetInnerHTML`、G15f inline style、G55 不數違規 |
| （v1 留下的）用過的 key、沒有 key | P1：67；P2：71 | — |

**BUILD.json 與重建**：
- 主閘門抓三種情況：G58 原始碼改了沒重建、G58b 手改 bundle、G58c 裝套件時跑了 install script。
- 手改 bundle、**同時重算 manifest** 這一招，CI 的 manifest 檢查擋不住：7 個案例照樣全綠，`rebuild-gate-red-first-1001.log` 第 1 段。這正是 rebuild 閘門要補的洞。
- rebuild 閘門自己的紅燈：手改 bundle 時抓到差異（rc 1，第 2 段）；Node 版本不符時拒跑（rc 2，第 3 段）。

## 5. §9 的其他項目

| 項目 | 紅燈先行 | 閘門 |
|---|---|---|
| `/manual.html` 加進白名單 | `manual-route-red-first.log`：`f3a20447` 的 serve.py 上，案例是紅的 | — |
| `--webgui-url`（預設 `http://localhost:3000`，經 `/meta` 交給頁面） | `webgui-url-red-first.log`：2 個案例紅 | G47 什麼網址都收，`javascript:` 也收 |
| G-N7：連到的那一端要是 serve.json 的 pid accept 的 | `gn7-red-first.log`：fork 情境在舊邏輯下是紅的（只看 listener 的話，token 會送給子程序） | G48 |
| OWN_CLAIM 對 ndt `claim_line()` 的 pin（ndt 行數沒變） | — | G49 改 ndt 的 printf、G50 規則太窄、G50b 規則太寬 |
| strace 量測（裁定 3，量一次） | `strace/summary.json`：plain `ndt status` 約 221 個程序、53 次 execve、1.2 s；`ndt apps status` 66 個、18 次、0.47 s | — |

**自動更新的實際負載**：
- 每 10 秒一輪，每輪約 287 個程序。
- 頁面可見、閒置時，**每分鐘約 1,700 個程序**、12 次 ndt 呼叫、24 個 HTTP 請求。暫停時都是 0。
- 量測中會自動暫停，所以這份負載不會落在量測期間。

**頁面的外觀和文字**沒有獨立的自動驗證：五個分頁、zh.json、短 id、每格說明、改名的按鈕、Web-GUI 按鈕、手冊 v1。這些是前端 worker 做的，它的冒煙測試 69/0（`web-smoke-2.log`）是它自己跑的。上面的頁面套件涵蓋了行為，沒有涵蓋字面。**這一部分要 Adam 親眼看。**

## 6. 已知、沒有處理

- `/lab` 的讀取逾時時，伺服器回 `measuring_is_nothing: false`，自動更新就停在「量測中」。這是偏安全的方向，但橫幅文字會誤導。手冊寫了「逾時那一次不算讀到」。
- Chrome 在 TMPDIR 太長時啟動不了（SingletonSocket 的路徑超過 107 bytes）。頁面套件現在會先拒跑並說明原因，頁面閘門的 mutant 目錄也改成編號，縮短路徑。
- Chrome 每次啟動都會留下約 24 KB 的 url_fetcher 暫存目錄。現在放在測試類別自己的暫存目錄裡，會跟著一起刪掉。
- 照 SCOPE §9，第二次交付才做：英文字串表與語言切換、手冊截圖與潤稿、walk 面板的細節、逐格校對說明。
- 另開分支再做：G-N9（`mutate_ndt_serve.sh` 的 reason 字串），以及 SLOT 等待上限的設計備忘。

## 7. 怎麼重跑

```bash
python3 tests/python/test_ndt_serve_web.py
bash tests/shell/mutate_ndt_serve.sh
bash tests/shell/rebuild_ndt_serve_web.sh
JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh python3 tests/browser/test_ndt_serve_page.py
bash tests/shell/mutate_ndt_serve_page.sh
```

- rebuild 閘門和頁面閘門會自己對每次建置、每次開 Chrome 各呼叫一次 guard。
- 這兩支都要 Node v24.20.0 / npm 11.19.0（放在 `~/.local/node`），而且 `web/node_modules` 要先裝好。
