# ndt serve GUI 第一刀 — 範圍草案（寫程式之前給 orchestrator 審）

[Co-developed with claude code -- Adam]

- **依據**
  - Adam 09-27 13:2x 用表單裁定：
    - Q2：GUI 由 ndt serve 自己在 `/` 提供；
    - Q3：token 經由啟動時印出的一次性 URL `#fragment` 交給頁面，只放在記憶體裡，讀完就把網址清掉，不用 cookie。
  - 第一刀工單 §1：「瀏覽器開 localhost 就是入口」。
  - `doc/audit/2026-09-24_ndt-serve/REPORT.md` §4.5 第 1 項。
- **分支**：`feat/ndt-serve-gui-0927`，從 trunk＝main `b005bf50` 開。**只放在分支上，不併、不推。**
- **orchestrator 已接受的條件**：
  - 靜態頁加最少量的 JS，不裝 Node；
  - 同源、不開 CORS、token 只放在記憶體；
  - 交件前跑兩套 `test_ndt_serve` 和閘門。
- **lab**：這一刀不需要 lab。頁面要驗的東西都可以用 stub ndt 驗，讀取真的 ndt 也只用 plain status。如果需要 lab，會先問 orchestrator。

---

## 1. 做什麼

一個單頁應用，由 `GET /` 提供，分成五區。

| 區 | 內容 | 用到的 API |
|---|---|---|
| **A. Lab 狀態** | claim 列和 measuring 列**原文照登**；「claim 是你的」標記；`ndt status` 完整輸出放在 `<pre>`；`/health` 的 `ndt_drift` 警告；手動重新整理，另有「分頁可見時每 30 秒自動更新」 | `GET /api/v1/lab`（新）、`/status`、`/health` |
| **B. Lab 動作** | claim（分鐘數、note）、release、up（平面和主機數，選項由伺服器提供）、down | `POST /claim`、`/release`、`/up`、`/down` |
| **C. Apps** | 清單（名稱由伺服器提供，旁邊附 `ndt apps status` 原文），每個 app 有 start 和 stop | `GET /apps`、`POST /apps/<n>/start\|stop` |
| **D. Jobs** | 列表；每個 job 顯示 state、rc、依 `rc_class` 上色、meaning 原文、argv；即時 log（用 offset 輪詢）；目前槽位被哪個 job 佔著 | `GET /jobs`、`/jobs/<id>?wait=`、`/jobs/<id>/log/*` |
| **E. Cells 與 walk** | 格子清單和預期判決；old/new 的 ASSERT 表格和 raw 檔連結；run（附確認，寫共用狀態的格子要勾確認）；walk 的步驟列表、每一步的 look_at、next、verdict（green／red 加 note）、abort | `/cells…`、`/guided…` |

**這一刀不做**：
- 拓樸編輯；
- `--force`（已同意不開放）；
- claim 的 `NDT_MEASURING`／`NDT_EXCLUSIVE_CPU` 旗標；
- 多人使用；
- 外觀打磨；
- 取消 job。

## 2. 會改變 lab 狀態的動作，與防誤觸

| 動作 | 會改 lab | 確認強度 |
|---|---|---|
| claim | 是（claim 檔） | 一般確認 |
| release | 是 | 一般確認 |
| up | 是 | **打字確認**（要輸入 `up`） |
| down | 是 | **打字確認**（要輸入 `down`） |
| apps start／stop | 是 | 一般確認 |
| cells run（需要 lab 的格子） | 是 | **打字確認**；寫共用狀態的格子另外要勾「我知道它會改寫 …」（等同 `confirm_shared_state_write`） |
| cells run（`requires none` 的格子） | 否 | 一般確認 |
| walk next | 可能（它的 claim、run、release 步驟會 spawn job） | 依「當前這一步」決定強度，同上 |
| walk verdict／abort | 否（只寫 walk 檔） | verdict 要選 green 或 red；abort 要一般確認 |

每一次寫入之前，頁面都會做下面這幾件事：

1. **重新讀一次 `GET /api/v1/lab`（新端點）**，不沿用畫面上舊的內容。它執行 plain `ndt status`，回傳：
   - `claim`：claim 那一列的原文；
   - `measuring`：measuring 那一列的原文；
   - `claim_is_yours`：伺服器用既有的 `OWN_CLAIM` 做 fullmatch 的結果；
   - `busy`：目前佔著槽位的 job；
   - `read`：這次讀取的 id，原始位元組查得到。
2. **跳出確認視窗**，裡面放：
   - claim 和 measuring 兩列原文；
   - `claim_is_yours` 為否時，顯示紅色警告；
   - **ndt 實際會執行的 argv**：由伺服器用 `dry_run` 算出來（見 §4），頁面自己不組 argv。
3. **防誤觸的細節**：
   - 預設焦點放在「取消」；
   - 按 Enter 不會確認；
   - 按下確認後按鈕立刻停用，防止連點；即使連點，伺服器的槽位也會回 409。
4. **`claim_is_yours` 為否時**：up、down、apps、需要 lab 的 cells run，確認鍵會停用，並提示「先 claim」。這只是介面層的防呆，最後由 ndt 和伺服器決定：OVS 和 P4 的 up 都會對別人的 claim 回 rc 5（trunk 已修），cells run 伺服器那邊也有 claim 前置檢查。
5. **measuring 不是 `nothing` 時**，一律升級成打字確認，並把 measuring 原文放在最上面。
6. **GET 永遠不寫入**：伺服器端本來就是寫入只接受 POST；頁面端所有寫入都走同一個 `post()` 函式，測試會檢查這一點（§5）。

## 3. token 流程（Q3 的實作）

**建議做法：fragment 裡放的是「一次性 nonce」，不是長期 token。**

1. 啟動時，伺服器產生一個 nonce：隨機、只能用一次、10 分鐘過期。
2. **stdout 是終端機時**，印出 `http://127.0.0.1:<port>/#k=<nonce>`；**不是終端機時**（例如被導向到 log 檔），把 URL 寫進 `~/.config/ndt-serve/url`（權限 0600），終端只印出這個路徑。
   - 理由：我們自己的 live log（`serve.out`）就會把 stdout 整份存下來。
3. 頁面載入時：
   - 讀取 `location.hash`；
   - **立刻**用 `history.replaceState` 把 fragment 從網址裡拿掉；
   - `POST /api/v1/session {"nonce": …}` 換到 token。這個請求要求 Origin 存在而且同源，Content-Type 必須是 JSON。
4. nonce **用一次就作廢**，第二次用回 403，過期也回 403。
5. token 只放在 JS 閉包裡的一個變數。**絕不寫進** `localStorage`、`sessionStorage`、cookie，也不寫進 DOM。
6. 重新整理頁面，token 就沒了。要重新打開時，執行 `ndt serve url`（新子命令）：它讀 0600 的 token 檔，帶 token 呼叫 `POST /api/v1/session/new` 產生新的 nonce，再印出新 URL。

**為什麼不直接把長期 token 放進 fragment？** 瀏覽器可能在 `replaceState` 之前，就把完整網址記進歷史紀錄或網址列的自動完成。放一次性 nonce 的話，就算被記下來也已經沒用；fragment 本身也不會送到伺服器，所以伺服器的 log 和 Referer 裡都不會有它。→ 決策清單第 1 題。

## 4. 頁面「讀來做判斷」vs「只顯示」——rc 表只有一個來源

| 類別 | 項目 |
|---|---|
| **頁面讀來決定畫面狀態的** | `rc_class`（決定顏色）、`job.state`、`busy`、`claim_is_yours`、`writes_shared_state`、cell 的 `requires`、walk 的 `current`／`blocked`／`done`、每一步的 `state`；up 的選項、claim 分鐘上限、app 名稱來自 **`GET /api/v1/meta`（新）**，它直接輸出 `verbs.UP_HOSTS`、`verbs.MAX_CLAIM_MINUTES` 和 ndt 的 `APP_NAMES` |
| **只原文顯示、頁面絕不解析的** | ndt 的 stdout／stderr、claim 列、measuring 列、`meaning`、`look_at`、CELLS.md 的預期判決、ASSERT 的 detail。**一律用 `textContent`，不用 `innerHTML`** |
| **頁面裡絕對沒有的** | rc 表、argv 的組法、對 ndt 文字的任何解析 |

- argv 的預覽：寫入端點加上 `{"dry_run": true}`，伺服器照原本的路徑驗證 token、Origin、body，由 `verbs.py` 產生 argv，**但不 spawn**，直接回 `{"argv": […]}`。這樣 argv 的組法只存在於 `verbs.py` 一處。
- `rc_class` 的配色：`refused` 和 `dirty` 是兩種不同的顏色，`nothing`、`report`、`skip` 則用灰階。

## 5. 伺服器端的最小改動

1. **靜態檔**：
   - `GET /`（對應 `index.html`）、`/app.js`、`/app.css`，**這三個固定檔名**，放在 `tools/ndt_serve/static/`。
   - 不需要 token，也不會執行任何東西。Host 檢查照樣套用（它本來就套用在所有路徑上）。
   - 回應標頭：
     - `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`
     - `X-Frame-Options: DENY`、`Referrer-Policy: no-referrer`、`Cache-Control: no-store`、`X-Content-Type-Options: nosniff`
   - 因為 CSP 擋掉了 inline script，JS 一定放在獨立的 `app.js`。
   - 其他路徑維持現在的 404 加 `GUI_NOTE`。
2. **新端點**：
   - `POST /api/v1/session`（用 nonce 換 token，不需要 token header，但 Origin 必須存在而且同源）；
   - `POST /api/v1/session/new`（需要 token，產生新的 nonce）；
   - `GET /api/v1/lab`、`GET /api/v1/meta`（都需要 token）。
3. **dry_run**：所有 POST 寫入端點都接受 `dry_run`（加進 verbs 的白名單欄位）。
4. **啟動與 CLI**：啟動時印出或寫出 URL；新增 `serve.py url` 子命令，並在 `ndt help` 的 serve 段落加一行說明。
5. **估計規模**：伺服器端約 +150 行；靜態檔（HTML、JS、CSS）約 400–600 行；測試約 +350 行。

## 6. 測試計畫（每條都紅燈先行，每條配具名變異，G 系列）

**伺服器端（Python unittest，沿用現有的 stub ndt）**

| 性質 | 測試 | 變異 |
|---|---|---|
| 靜態檔不執行 ndt、不需要 token | `/`、`/app.js`、`/app.css` 沒帶 token 也回 200；stub 一次都沒被呼叫；其他路徑回 404；`/../`、`/static/../serve.py` 回 404 | G1：靜態路由去執行 `ndt status` |
| 靜態檔的安全標頭 | CSP、XFO、Referrer-Policy 三個標頭都在 | G2：拿掉 CSP；G3：拿掉 `frame-ancestors`／XFO |
| Host 檢查也套用在靜態檔 | 外來的 Host 打 `/` 回 403 | G4：靜態路由不做 Host 檢查 |
| 印出的 URL 裡沒有長期 token | 解析啟動輸出，確認 token 字串不在裡面；非終端機時 URL 寫進 0600 檔 | G5：URL 改成放 token |
| nonce 只能用一次 | 第一次 200，第二次 403；過期 403 | G6：用完不作廢；G7：不檢查過期 |
| nonce 交換要求同源 | 缺 Origin 回 403、外來 Origin 回 403、nonce 放在 query 被拒 | G8：不檢查 Origin |
| GET 永遠不寫入 | 既有測試延伸到 `/`、`/lab`、`/meta`：只會執行唯讀動詞；寫入路徑用 GET 回 405 | G9：`/lab` 改跑 `status --check` |
| dry_run 不 spawn | job 數量不變、stub 沒被呼叫；argv 與實跑時相同 | G10：dry_run 照樣 spawn |
| `/lab` 的 claim 判斷 | 重用 `OWN_CLAIM` 的案例，含 `yours-x`、`none`、`EXPIRED` | G11：改成 `startswith` |

**頁面端（headless Chrome，已確認可用）**

- 做法：
  - 由 Python 測試啟動 stub 伺服器，接著執行 `google-chrome --headless=new --user-data-dir=<暫存目錄> --virtual-time-budget=… --dump-dom <URL#k=nonce>`；
  - 用拋棄式的 profile，不碰 Adam 的 Chrome 設定；
  - 測試結束後確認沒有殘留的 Chrome 程序。
- 09-27 實測過可行：JS 會執行、讀得到 fragment、`replaceState` 之後網址裡沒有 fragment，事後殘留程序是 0。

| 性質 | 測試 | 變異 |
|---|---|---|
| fragment 被清掉 | 頁面在測試模式下，把 `location.href` 寫進一個 hook 元素；斷言裡面沒有 `#`，而且伺服器收到了 nonce 交換的請求 | G12：拿掉 `replaceState` |
| token 不進 storage | hook 列出 `localStorage`、`sessionStorage` 的 key 和 `document.cookie`，斷言三者都是空的 | G13：token 寫進 `sessionStorage` |
| 載入頁面不會寫入 | 載入頁面之後，stub 只收到唯讀呼叫，沒有任何寫入 | G14：載入時自動執行一個寫入 |

**頁面端的靜態檢查**（Python 讀 `app.js`）：

- 不准出現 `localStorage`、`sessionStorage`、`document.cookie`、`eval`、`innerHTML`；
- `fetch(` 只能出現在 `get()` 和 `post()` 兩個函式裡；
- `X-NDT-Token` 只能在一處設定；
- 每一次 `post(` 呼叫，都必須透過 `confirmThen(`（確認視窗的回呼）。

對應的變異是 G15–G17。

**確認視窗的行為**（實際點擊、預設焦點、打字確認、claim 不是自己的時候確認鍵停用）：`--dump-dom` 沒辦法模擬點擊，所以由我在 app 內建瀏覽器實際操作，附截圖；報告裡這部分會標成「跑過（瀏覽器）」，跟單元測試分欄。要做到可重跑，需要 DevTools protocol 那一類更重的工具。→ 決策清單第 5 題。

## 7. 交付

- 程式、測試、閘門都放在分支上；交件前跑兩套既有測試、新測試、`mutate_ndt_serve.sh`（加上 G 系列）、`check_gate_anchors`、兩支靜態 meta-gate。
- 報告：`doc/audit/2026-09-27_ndt-serve-gui/REPORT.md`，四段式。截圖照 CLAUDE.md 的規矩：圖上只留少量必要的字。
- 收件照 orchestrator 的流程：讀 diff、掃秘密字串、判官。

## 8. 決策清單

1. **fragment 裡放什麼？** 我建議放一次性 nonce，用它去換 token（§3）；另一個選項是直接放長期 token，比較簡單，但可能被瀏覽器的歷史紀錄記下來。
2. **介面語言？** 我建議中文標籤，程式碼和 API 維持英文；另一個選項是全英文。
3. **claim 不是自己的時候，要不要停用 up、down 等動作的確認鍵？** 我建議停用，並提示「先 claim」。這只是介面防呆，最後仍由 ndt 決定。
4. **要不要做 `dry_run` 預覽 argv？** 我建議要，讓 argv 的組法只存在 verbs.py 一處。
5. **確認視窗的點擊行為，怎麼驗？** 這一刀用瀏覽器實際操作加截圖；如果要做到可重跑，下一刀引入 DevTools protocol，但只用 Python 標準庫來寫。
6. **自動重新整理？** 我建議只在分頁可見時每 30 秒一次（每次會執行一次 plain `ndt status`，約 0.7 秒，受伺服器的讀取名額限制）；另一個選項是只做手動。
