# ndt serve GUI v2 — 範圍草案（寫程式之前給 orchestrator 審）

[Co-developed with claude code -- Adam]

- **依據**：
  - Adam 09-27 ~21:1x 用過 trunk `f186ce98` 的頁面後寫了 8 點，並用表單裁了兩題：R1 換成 Web-GUI 的技術棧、留在 ndt serve 裡面；R2 每 10 秒自動更新，並在特定情況暫停。全文在 `logs/orchestrator-0924/intake-0926/RULINGS-0927-ndtserve-gui-v2.md`。
  - Adam 的 R3（同一份裁定檔，後來補上）：長期來看，ndt serve 和 Web-GUI 會變成同一個 app。這一版不合併，但要做成搬得動的，見 §10。
  - orchestrator 的工單（a）–（j）。
- **分支**：`feat/ndt-serve-gui-v2-0927`，從 trunk `fed37cff` 開，worktree 在 `scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927`。**只放在分支上，不併、不推。**
- **lab**：這一刀不需要 lab；§6 有一項測量要不要做，請 orchestrator 決定。
- **參考來源**：`~/Web-GUI`（ndtwin-lab/Web-GUI，HEAD `f63a55ce7d3a75736e23aca202606f3a1fd447b1`，Apache-2.0）只讀、不改、不發 PR。下面引用的行號都是那個 HEAD 的；調查報告出自一個唯讀的 Explore agent。

---

## 0. 先更正兩個前提

1. **Node 不在 conda env 裡。** 這台機器的 Node 是 `~/.local/node`（v24.20.0，npm 11.19.0），也是網站建置在用的那一份（見記憶 ndtwin-website-repo-and-build）。三個 conda env（ntg、ryu、te）都沒有 Node。工單寫的「conda env as before」並沒有前例，下面一律用 `~/.local/node`。
2. **Web-GUI 可以直接抄的元件很少。** 它的 `components/common/` 只有 `LoadingSpinner`、`ErrorBoundary`、`BandwidthDisplay` 三個（`src/components/common/`）。沒有 Tabs、Modal、Tooltip、Badge，也沒有複製到剪貼簿的程式碼；tooltip 用的是原生 `title=`，一共 58 處。
   - 所以「照它的元件」實際上是**照它的樣式與寫法重寫**。能整檔拿來用的只有 `LoadingSpinner` 和 `ErrorBoundary`。
   - 它還有幾樣這裡**不能照抄**：
     - `react-draggable` 拖曳時會插入 `<style>`，違反 `style-src 'self'`；
     - `LLM.ts` 會連外；
     - `useLanguage.ts:10` 會寫 localStorage；
     - API base URL 是跨源的。

## 1.（a）版面

**上方列**，從左到右：
- 標題 ndt serve；owner；session 狀態；
- 自動更新狀態：顯示「每 10 秒」，暫停時顯示「已暫停（量測中）」或「已暫停（頁面在背景）」；
- 「立即更新」按鈕；
- 「開啟 Web-GUI」按鈕：預設 `http://localhost:3000`，這是 Web-GUI 在這台機器上的 Docker port（它的 `Dockerfile:24-25`、`docker-compose.yml:52-53`）。在新分頁打開，帶 `rel="noopener noreferrer"`；
- 「使用手冊」按鈕：在新分頁打開相對路徑 `./manual.html`。

Web-GUI 沒有全域的上方列，這裡照它 `AvailabilityStatus.tsx:~236-255` 的 header 寫：一個 h1、一個 badge、一個 ghost button。

**五個分頁**：照 `LinkFlowInformation.tsx:463-480` 的分段切換寫，選中的樣式用 `Sidebar.tsx:132-171` 的 `border-[#1976d2] bg-white`。

| 分頁 | 內容 | 自動更新 |
|---|---|---|
| **實驗室** | 狀態卡，照 `DeviceInformation.tsx:226-305` 那種 `flex justify-between` 的列：claim、measuring、declared 三列原文；「claim 是你的」標記；槽位；上次讀取的時間。另有 `ndt status` 全文（可展開）和 ndt_drift 警告 | 是（`/lab`、`/health`） |
| **操作** | claim／release、up／down。每一區上方一行說明 | 否（寫入一律經過確認視窗） |
| **Apps** | 表格，照 `FlowTablePanel.tsx:186-212` 的 sticky header 和 `hover:bg-blue-50`：app 名稱、start、stop，下面放 `ndt apps status` 原文 | 是（`/apps`） |
| **工作紀錄** | job 表：短 id、種類、狀態、rc、rc_class badge、meaning。點開後是 job 面板：有 Close 按鈕，log 每 2 秒增量讀取，照 v1 已裁定的三個停止條件 | 列表跟著自動更新；log 只在打開的 job 還在跑時讀 |
| **驗證格** | 格子表，每格一行說明；四個按鈕改名並附說明（見下）；walk 面板 | 否 |

**第 8 點：四個按鈕的新名字**。字串都放在 `zh.json`，每個按鈕旁邊有一行說明，滑過去會顯示完整說明：

| 舊 | 新（zh） | 說明（取自裁定檔） |
|---|---|---|
| old | 修前紀錄 | 修好之前的紀錄，應該是紅的 |
| new | 修好當晚 | 修好那一晚第一次變綠的紀錄 |
| run | 現在重跑 | 現在在 lab 上重跑這一格；需要 lab 的格子要先 claim |
| walk | 逐步驗證 | 帶你走一遍：修前 → 修好當晚 → claim → 重跑 → 對照 → 你的判定 |

**第 4 點：每區、每格的說明**：
- 所有字串都放在 `ndtServe.*` 這個命名空間底下（§10），所以下面的 key 前面實際上都有 `ndtServe.`。
- 每一區的說明寫在 `zh.json` 的 `section.*.explain`。
- 每一格的說明寫在 `zh.json` 的 `cells.<name>.what`，由我從 CELLS.md 和 fixture 的 PROVENANCE 寫成一行中文。缺這個 key 時，退回顯示 CELLS.md 的 expected 原文，所以 grid 多了新格也不會壞。

**第 1 點：短 id** `<ShortId>`：
- 顯示前 8 個字。滑過去用原生 `title` 顯示完整 id，和 Web-GUI 的做法一樣。
- 點一下就用 `navigator.clipboard.writeText` 複製。127.0.0.1 算安全情境，使用者點擊時不會跳權限詢問。複製之後出現「已複製」，1.5 秒後消失。
- job id 和 walk id 前面是時間戳，截前 8 碼會截到日期（例如 `20260927`），反而分不出來。所以短 id 改取**後 6 碼的亂數，加上 HHMM**，例如 `0621·a8a334`。這是顯示規則，由 `ShortId` 一處決定，完整 id 永遠 hover 看得到、點一下就能複製。**需要 orchestrator 同意這個偏離**，見 §11 決策 4。

**要寫的元件**（樣式都照 Web-GUI 的配色）：
- `TabBar`、`StatusRows`、`DataTable`、`Badge`、`ShortId`、`Explain`；
- `ConfirmDialog`：照 `SwitchFlowTable.tsx:623-657` 的 `DeleteDialog`，加上打字確認的輸入框；
- `LoadingSpinner`、`ErrorBoundary`：直接用 Web-GUI 的兩個檔，附出處。

**配色**：主色 `#1976d2`、強調色 `#FF7F50`、背景 `bg-gray-100`、白卡片、邊框 `#e0e0e0`；系統字型、沒有暗色模式，都和 Web-GUI 相同。rc_class 的顏色延續 v1：`refused` 和 `dirty` 用兩種不同的顏色。

**授權紀錄**：`tools/ndt_serve/web/THIRD_PARTY.md` 逐一列出抄了哪個檔、照了哪個寫法，來源都是 Web-GUI 的 `f63a55ce` 加上路徑與行號，並附 Apache-2.0 全文的連結。Web-GUI 沒有 NOTICE 檔，它的 `ndtwin-license-header.txt` 也沒有任何檔案實際使用；我們照 Apache-2.0 第 4 條保留出處。

## 2.（b）建置

**原始碼放在 `tools/ndt_serve/web/`**：
- `package.json`、`package-lock.json`、`vite.config.ts`；
- `tsconfig.json`、`tailwind.config.js`、`postcss.config.js`；
- `index.html`、`src/**`；
- `manual/zh.md`、`scripts/build-manual.mjs`；
- 一個本地 `.gitignore`（`node_modules/`、`dist/`）。

**輸出**到 `tools/ndt_serve/static/`（會 commit），只有這五個檔：`index.html`、`app.js`、`app.css`、`manual.html`、`BUILD.json`。
- 用 `rollupOptions` 把檔名固定：`entryFileNames: 'app.js'`、`assetFileNames: 'app.css'`；
- `base: './'`：`index.html` 用相對路徑（`./app.js`、`./app.css`）引用資源，頁面不假設自己掛在 `/` 底下（§10）；
- 不拆 chunk：`inlineDynamicImports: true`、`cssCodeSplit: false`。
- 這樣伺服器「路徑只查表、不拼接目錄」的白名單原則保得住：從三個檔變成四個頁面檔（多了 `/manual.html`），再加上不對外服務的 `BUILD.json`。

**`BUILD.json`**：把 bundle 綁到原始碼：

```json
{"toolchain": {"node": "v24.20.0", "npm": "11.19.0"},
 "command": "npm ci --ignore-scripts && npm run build",
 "source": {"web/package.json": "<sha256>", "web/src/App.tsx": "<sha256>", ...},
 "bundle": {"index.html": "<sha256>", "app.js": "<sha256>", "app.css": "<sha256>", "manual.html": "<sha256>"}}
```

**CI 端的檢查，不需要 Node**（Python，放在 `tests/python/test_ndt_serve_web.py`）：
1. `web/` 底下 git 追蹤的每一個檔，都要在 `BUILD.json` 的 `source` 裡，而且 sha256 相同；`source` 裡也不能有多出來的檔；
2. `static/` 的每一個檔，都要在 `bundle` 裡，而且 sha256 相同；
3. bundle 的衛生檢查（見 §4）。

- 這樣可以證明「commit 進來的 bundle，就是 `BUILD.json` 說它由這一份原始碼建出來的那一個」。原始碼改了卻沒重建，CI 會紅。
- **但它證明不了「真的由這份原始碼建得出來」**：有人手改 bundle 再重算 sha，這一關擋不住。要靠下面的本機閘門。

**本機的 rebuild-and-compare 閘門**：`tests/shell/rebuild_ndt_serve_web.sh`，需要 Node，一律在 guard 內跑。
- 把 `web/` 複製到暫存目錄 → `npm ci --ignore-scripts` → `npm run build` 輸出到暫存目錄 → 和 commit 進來的 `static/` 逐 byte 比對。
- node 或 npm 的版本和 `BUILD.json` 不同時，拒跑（exit 2）。
- 前提是 Vite 在同一份 lockfile、同一版 Node 下的輸出是決定性的。實作第一步就先驗這件事：連續建兩次，比較輸出。

## 3.（c）依賴

全部**鎖到確切版本**（package.json 裡不寫 `^`），`package-lock.json` 帶 sha512 integrity。版本盡量對齊 Web-GUI lockfile 實際鎖住的版本：

| 用途 | 套件 | 版本 | 備註 |
|---|---|---|---|
| runtime | react、react-dom | 19.1.0 | Web-GUI `pnpm-lock.yaml:1501` |
| runtime | i18next | 25.3.2 | 同上 :1128 |
| runtime | react-i18next | 15.6.1 | Web-GUI package.json |
| dev | vite | 6.3.5 | 同上 :1667 |
| dev | @vitejs/plugin-react | 4.4.1 | production build 不會注入任何 inline script（見 §4） |
| dev | typescript | 5.8.3 | |
| dev | tailwindcss、postcss、autoprefixer | 3.4.17、8.5.6、10.4.21 | Web-GUI 用的是 Tailwind v3 加 PostCSS |
| dev | @types/react、@types/react-dom | 19.1.2 | |
| dev（手冊） | marked | 建置前才定版 | 建置時把 Markdown 轉成 HTML；它沒有任何相依套件 |

**Web-GUI 有、這裡刻意不拿的**，各自的原因：
- axios：它 import 了但沒用到；
- react-router(-dom)：分頁用 state 切換就夠，而且 URL 的 fragment 是一次性 key 在用的；
- react-icons：只需要幾個圖示，用 inline SVG 元件；
- zod、echarts、cytoscape、openai、dotenv：用不到；
- react-draggable：會注入 `<style>`；
- i18next-browser-languagedetector：會寫 localStorage；
- eslint 全套：這一刀不加，型別檢查交給 `tsc --noEmit`，放進 `npm run build`。

**套件管理用 npm，不用 Web-GUI 的 pnpm**：npm 本來就隨 Node 附帶，少一個工具就少一個版本要釘（§11 決策 1）。

**供應鏈**：
- 執行時不從網路載入任何東西：CSP 本來就只允許 `'self'`，也沒有 CDN、沒有網路字型；
- 建置時只在 `npm ci` 那一步連 npm registry，而且用 `--ignore-scripts`，不跑任何 postinstall。esbuild 的平台 binary 是 optionalDependency，照理不需要 postinstall，實作時實測確認。

## 4.（d）CSP

**Vite production 的輸出**：`index.html` 裡只有外部的 `<script type="module" crossorigin src="./app.js">` 和 `<link rel="stylesheet" crossorigin href="./app.css">`（`base: './'`）。

**會破壞 CSP 的來源，逐項處理**：

| 來源 | 會不會 | 做法 |
|---|---|---|
| modulepreload polyfill | Vite 把它放在 entry JS 裡，不是 inline | 保險起見仍關掉：`build.modulePreload: {polyfill: false}` |
| react-refresh preamble | 只有 dev server 會有 inline script | production 不會出現 |
| 元件的 `style={{…}}` | React 走 CSSOM 設定，CSP 不擋 | 我們一律用 Tailwind class；原始碼 lint 禁止 `style={`，這一刀不需要它 |
| CSS | 抽成單一個 `app.css` | `cssCodeSplit: false` |
| i18next | 資源是 bundle 進來的 JSON，不會 fetch | — |
| eval／new Function | React production 和 i18next 都沒有 | bundle lint 會 grep 確認 |

**執行期的證明**：
- 頁面在 `main.tsx` 註冊 `securitypolicyviolation` 事件，把次數寫進 `<body data-csp-violations>`，瀏覽器測試斷言它是 0。
- 陽性對照：頁面閘門在 index.html 塞一段 inline script，那一例必須變紅。

## 5.（e）測試：現有的保證怎麼在重寫後保住

**headless Chrome 的驅動改成 DevTools protocol**。09-27 在 guard 內做過實驗（`cdp_spike.py`，Chrome 153）：
- 只用 Python 標準庫，走 `--remote-debugging-pipe`（fd 3／4，以 NUL 分隔的 JSON），就能：建分頁、執行 JS 讀 DOM、送出點擊和按鍵；
- **建立第二個分頁時，第一個分頁的 `document.visibilityState` 真的會變成 `hidden`**，所以「頁面在背景時暫停」可以用真的 Chrome 行為來測，不用在頁面裡偽造；
- 事後殘留的程序是 0。

這正是 v1 裁定 5 說「下一刀要做」的 DevTools 自動化，而且不需要 websocket。驅動寫在 `tests/browser/cdp_pipe.py`，大約 150 行。

| 保證 | 新的表達方式 | 紅燈（具名變異） |
|---|---|---|
| token 不在 DOM、localStorage、profile | CDP 讀 `document.documentElement.outerHTML`、`localStorage`、`sessionStorage`、`document.cookie`、`indexedDB.databases()`；profile 目錄下所有檔以 UTF-8 和 UTF-16LE 搜 token | 把 token 寫進 `data-*`（DOM）；把 token 寫進 IndexedDB（只會出現在 profile 檔，storage hook 看不到）：這是判官 G-N8 要的兩個陽性對照 |
| 只 POST 一次 `/session` | 伺服器 log 裡剛好一筆 `POST /api/v1/session`；原始碼 lint：交換 session 只准出現在 `src/api/session.ts`，而且只有一次呼叫 | 在 session 模組多塞一個 POST（G-N10：CI 端的 lint 也要看得到） |
| fragment 被清掉 | CDP 讀 `location.href`，裡面不能有 `#` | 拿掉 `history.replaceState` |
| 輪詢在隱藏、量測中、關閉時停 | CDP 加上真的時間（約 25 秒）或 virtual time，數伺服器 log 裡的 `/lab`、`/apps`、`/jobs/<id>/log` 次數：可見且 measuring 是 nothing → ≥2 次；stub 回 measuring iperf3 → 第一次之後 0 次；開第二個分頁讓它 hidden → 0 次，切回來後恢復；按 job 面板的 Close → log 讀取停止 | 各拿掉一個條件（對應 v1 的 G38、G37、G40，加上新的 measuring 條件） |
| 載入時不寫入 | 伺服器 log 只有 GET 加上一筆 `POST /session`；stub 只收到 `status` 和 `apps status` | 載入時就 release（v1 的 G14） |
| 確認強度來自 confirm_policy | CDP 實際點擊：Up → 有打字框，打出 `up` 之前 Confirm 是 disabled；claim 是別人的 → 顯示「先 claim」；量測中 → 升級成打字確認；Claim → 沒有打字框；焦點在 Cancel；按 Enter 不會確認；連點兩下只 POST 一次 | 把伺服器的 confirm_policy 改成 plain；頁面不看 `needs_own_claim` |
| dry_run 預覽 | dialog 上的 argv 文字，要等於 log 裡那筆 dry_run POST 回來的 argv；真的 POST 一定在 dry_run 之後 | 頁面自己組 argv；不先 dry_run 就送出 |
| CSP 不被破壞 | `data-csp-violations` 等於 0 | index.html 插一段 inline script |

**PageLint** 會隨著手寫的 app.js 一起消失，改成兩層，都用 Python、CI 都能跑：
- **SourceLint**：讀 `web/src/**/*.ts(x)`，規則照搬到 TS：
  - 不准出現 storage API、`dangerouslySetInnerHTML`、`innerHTML`、`eval`、`new Function`、`style={`；
  - `fetch(` 和 `X-NDT-Token` 只准在 `src/api/client.ts`；
  - `post(` 只准在 `ConfirmDialog` 裡呼叫；
  - `"POST"` 只准在 client 和 session 兩處；
  - job 輪詢的三個停止條件，在 `useJobLog.ts` 的寫法要被釘住。
- **BundleLint**：讀 `static/`：
  - HTML 裡只有那兩個外部標籤，沒有 inline 的 script、style 或 handler；
  - JS 裡沒有 `eval(`、`new Function`；
  - 檔案清單要等於 `BUILD.json` 的 `bundle`。

**headless Chrome 閘門**（`mutate_ndt_serve_page.sh`）：變異改成改 TSX 原始碼，所以每個 mutant 都要重建一次，也就是要有 Node。這支閘門只在本機的 guard 內跑，CI 靠 SourceLint、BundleLint 和 manifest。

**主閘門**：v1 那些 PageLint 相關的 G 變異（G15–G17、G29、G37–G40），改寫成改 TS 原始碼、由 SourceLint 抓。這些不需要重建，照樣在主閘門裡跑。

每一項都要重新看過紅，也就是具名變異要 caught。

## 6.（f）自動更新的負載

**一次 tick（每 10 秒）送出的請求**：

| 請求 | 伺服器做什麼 |
|---|---|
| `GET /lab` | 1 次 plain `ndt status` |
| `GET /apps` | 1 次 `ndt apps status` |
| `GET /health` | 不跑任何程序 |
| `GET /jobs` | 不跑任何程序（只讀檔） |

- **可見、閒置時**：每分鐘 **24 個 HTTP 請求、12 次 ndt 呼叫**。
- **暫停時**：0 個請求、0 次 ndt。
- 前一輪還沒回來，下一輪就不開始，不會疊加；伺服器端本來就只有 2 個讀取名額（`READ_SLOTS`）。

**「一次 ndt 呼叫會起多少個程序」還沒量過**：
- `cmd_status` 406 行、`cmd_apps` 140 行，裡面有大量 `$(…)` 和管線，靠讀碼數不準。第一刀 live 記到的讀取耗時大約 1 秒。
- 提議：用 `strace -f -e trace=execve -c` 對主 checkout 的 plain `ndt status` 和 `ndt apps status` 各量一次。這兩個都是唯讀、不 claim，就是頁面每 10 秒本來就會做的事。**但它會執行真的 ndt，所以要 orchestrator 點頭**（§11 決策 3）；沒點頭就不量，數字標成「未量」。

**暫停規則**：暫停與否由伺服器算好的欄位決定，頁面不解析任何 ndt 文字。
- **量測中**：`/lab` 回來的 `measuring_is_nothing` 是 false，或 `declared` 不是 null → 停止自動更新，上方列顯示「已暫停（量測中）」。
  - 麻煩在於：停掉之後，頁面就不會再讀 `/lab`，也就不會知道量測結束了。
  - 我的建議：暫停期間只靠手動按「立即更新」恢復，上方列直接寫出這一點。另一個選項是暫停時每 60 秒試讀一次（§11 決策 2）。
- **頁面在背景**：`visibilitychange` 變成 hidden → 停止；回到前景時立即更新一次，然後恢復計時。
- **手動更新**永遠可以按，就算在暫停中也可以；按了只跑一次，不會自己恢復計時。

## 7.（g）手冊

- **原始檔**：`tools/ndt_serve/web/manual/zh.md`，中文。英文的 README 維持原本 API 參考的角色。
- **產生方式**：建置時由 `scripts/build-manual.mjs` 用 marked 轉成 `static/manual.html`，樣式用 `app.css`。沒有 JS；CSP 照樣套用；和頁面檔一樣不需要 token、不執行任何東西。伺服器的白名單多一條 `/manual.html`。
- **大綱**：
  1. 這是什麼（本機、只給你一個人用、不碰網路）
  2. 啟動與打開頁面（一次性網址、`ndt serve url`、reload 就要重拿網址）
  3. 畫面導覽（上方列、五個分頁、短 id）
  4. 實驗室分頁：claim、measuring、declared 三列怎麼讀
  5. 操作分頁與確認視窗（打字確認、「先 claim」、誰在擋什麼）
  6. Apps 分頁（為什麼要先 claim）
  7. 工作紀錄分頁（job、log、Close）
  8. 驗證格分頁：修前紀錄、修好當晚、現在重跑、逐步驗證，以及你的判定
  9. 自動更新與暫停
  10. 常見的回應碼（409 claim、busy、refused 和 dirty 的差別）
  11. 安全上它保證什麼、不保證什麼
  12. 開啟 Web-GUI

## 8.（h）工具鏈

- **Node**：`~/.local/node`，v24.20.0，npm 11.19.0，版本記在 `BUILD.json`。
- **所有建置和測試都走 guard**：`JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh …`，每個步驟各自拿一次鎖：`npm ci`、`npm run build`、頁面套件、頁面閘門、rebuild 閘門。
- **node_modules 永不 commit**，由 `web/.gitignore` 擋。commit 一律列到檔案；新增的整批檔案 commit 前要讀過 `git diff --stat`，確認沒有夾帶 node_modules 或 dist。
- **網路**：只有第一次 `npm ci` 需要連 npm registry，之後用 `~/.npm` 的快取。
- **磁碟**：09-27 晚上 `/` 只剩 3.8 GB（97%）。
  - 預估：`web/node_modules` 大約 150–250 MB，`~/.npm` 的快取差不多大；rebuild 閘門重跑 `npm ci` 時，暫存目錄還要再一份。
  - 規則：每次建置前先看 `df`，可用空間少於 1 GB 就不建、直接回報；暫存目錄在閘門結束時刪掉。
- **commit 訊息**照 CLAUDE.md（Adam 09-27）：一行主旨，加幾句說明改了什麼、為什麼；不加 `Co-Authored-By`、不加標記行，也不寫判官或裁定的編號。程式碼檔案裡仍然標 `[Co-developed with claude code -- Adam]`。

## 9.（i）估計與切法

**第一次交付**，也就是這條分支核准之後要做的：
- **伺服器**：
  - `/manual.html` 加進白名單；
  - `--webgui-url`（預設 `http://localhost:3000`），經由 `/meta` 交給頁面。按鈕的網址「可設定」是用伺服器參數，不存在瀏覽器裡，見決策 5；
  - **G-N7**：先連線，再從 `/proc` 確認「連到的那一端的 socket」屬於 serve.json 的 pid，才送 token。紅燈先行用 fork 的情境：父程序 listen、子程序 accept。舊邏輯只看 listener，會把 token 送給子程序；新邏輯會拒絕；
  - **OWN_CLAIM pin 測試**：從 ndt 找出 `claim_line()` 函式內 own form 的那一行 printf（用「所在函式＋原文」定位，避免 8315 那種陷阱），用 bash 的 `printf` 以範例值實際印出來，再用 `OWN_CLAIM.fullmatch`。紅燈：改 ndt 的 printf，或放寬 OWN_CLAIM。ndt 行數不變。
- **頁面**：五個分頁、`zh.json`、短 id、每區每格的說明、改名的四個按鈕、確認視窗、自動更新與暫停、Web-GUI 按鈕、手冊 v1。
- **測試**：SourceLint、BundleLint、BUILD.json、CDP 驅動的頁面套件和頁面閘門、改寫過的主閘門、rebuild 閘門；§5 每一項都要看過紅。

**第二次交付**：
- 英文字串表加語言切換（上線時才做，不用改程式）；
- 手冊加截圖、潤稿；
- walk 面板的細節；
- 每格說明逐格校對。

**規模估計**：
- web 原始碼約 1,500–2,000 行 TS／TSX；
- 手冊約 300 行；
- 伺服器 +80 行（不含 G-N7，它另外約 +40 行）；
- 測試約 +700 行，其中 CDP 驅動約 150 行。
- 時間大半會花在排 guard 鎖上。這一晚的經驗是：排一次 37 到 88 分鐘。

## 10.（j）搬進 Web-GUI 的可攜性（Adam R3）

**這一版不合併**：拓樸和流量仍然留在 Web-GUI，用按鈕過去。但 v2 要做成日後搬得動的，具體做法如下：

| 要求 | 做法 |
|---|---|
| 技術棧和主版本相同 | react 19.1、vite 6.3、tailwind 3.4、i18next 25.3、TypeScript 5.8，逐一對齊 Web-GUI lockfile 實際鎖住的版本（§3） |
| API 呼叫只在一處，base 可以設定 | 所有請求都經過 `src/api/client.ts`：`fetch(` 和 token 標頭只准出現在這裡，由 SourceLint 釘住。base 在建置時由 `VITE_NDT_SERVE_API_BASE` 決定，預設是相對路徑 `./api/v1`；搬進 Web-GUI 時只改這個設定 |
| i18n 的 key 有命名空間 | 全部放在 `ndtServe.*` 底下，namespace 是 `translation`，和 Web-GUI 的 `messages/en.json` 同一種結構：它的頂層分組是 common、navigation 等等。搬過去時整塊 `ndtServe` 併進它的 messages 檔就行 |
| Tailwind 設定相容 | 和 Web-GUI 一樣是 `theme.extend: {}`，配色用 arbitrary value（`text-[#1976d2]`），不自訂 theme key；`content` 的 glob 只指到自己的 `src`。兩邊都用 preflight |
| 不假設頁面掛在 `/` | Vite 用 `base: './'`；手冊連結寫相對路徑 `./manual.html`；不讀 `location.pathname` 來做決定；分頁用 state 切換、不寫 URL，唯一會碰 URL 的是一次性 key 那段 fragment 處理，而它只呼叫 `history.replaceState(null, "", location.pathname + location.search)`，本來就不管掛在哪 |
| 元件不佔用全域 | 不改 `document.title` 以外的全域狀態；沒有全域 CSS，只有 Tailwind；根元件是 `<NdtServeApp/>`，自己的 `main.tsx` 只負責把它掛上去 |

**真的要搬進 Web-GUI 時，得改的東西**（只列出來，不設計）：
1. **路由**：Web-GUI 用 react-router 7 的 `BrowserRouter`（`App.tsx:73`）。`<NdtServeApp/>` 要掛成它的一個 route，分頁可能要改成 nested route。
2. **認證和 token 的交接**：現在「fragment 裡的一次性 key 換 token」建立在頁面和 API 同源的前提上。
   - 掛進另一個 app 之後，頁面和 ndt serve 不再同源。ndt serve 不送 CORS 標頭（紅線），所以要由那個 app 的後端代理，或另做同源的安排；這是另一份設計，還沒排程。
3. **CSP**：「沒有 inline、只有 `'self'`」這個保證來自 ndt serve 自己送的標頭。搬過去之後，要由提供頁面的那一端送同樣的標頭，這個保證才還在。
4. **i18n**：Web-GUI 把語言寫死成 `lng: 'en'`（`i18n.ts:15`），而且沒有 zh 的資源。
5. **儲存**：Web-GUI 的 `useLanguage.ts:10` 會寫 localStorage。「token 不落地」的 SourceLint 規則要限定在我們自己的目錄。
6. **建置**：Web-GUI 用 pnpm，Docker 裡是 Node 18。原始碼搬過去之後要用它的 lockfile 重新解版本；BUILD.json 和 rebuild 閘門在那邊不適用。
7. **測試**：CDP 頁面套件假設頁面是由 ndt serve 提供的，要改指到新的來源。

## 11. 要 orchestrator 裁的

1. **套件管理**：npm 加 package-lock（我建議），還是照 Web-GUI 用 pnpm？
2. **量測中暫停後怎麼恢復**：只靠手動「立即更新」（我建議），還是暫停期間每 60 秒試讀一次？
3. **要不要對主 checkout 的 plain `ndt status` 和 `ndt apps status` 各跑一次 strace 量程序數**？兩個都唯讀、不 claim。我建議要，量完就知道每分鐘實際多少程序。
4. **短 id 的顯示規則**：時間戳型的 id 截前 8 碼等於日期。我建議顯示 `HHMM·後 6 碼`，完整 id hover 看、點一下複製。或者照字面取前 8 碼？
5. **Web-GUI 網址怎麼設定**：用 `ndt serve --webgui-url`（我建議，瀏覽器不存任何東西），還是在頁面上可以改、但不存（重新整理就回到預設）？
6. **這一刀要不要順便加 eslint**：我建議不加，用 `tsc --noEmit` 加 SourceLint 就夠。
