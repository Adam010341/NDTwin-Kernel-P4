# NDTwin P4 官網手冊驗證報告（給教授簡報用的彙整）

[Co-developed with claude code -- Adam]

**2026-08-30 彙整（`8/29 auditor`）。** 涵蓋 2026-08-28 〜 08-30 的手冊驗證線（工單 T-1〜T-7b、
整機輪 T-4、API 頁 T-6）。每一條結論都標注證據等級；本檔只做彙整，**數字與逐步紀錄的正本
是各 FINDINGS 檔**（索引在文末）。

## 0. 一句話

**照官網安裝手冊從零裝起來的機器，裝得起來、跑得起來、五個 app 接得上**；過程中抓到的
手冊缺陷（會擋住讀者的三個）已修，程式缺陷兩個已修、一個修好待合併；沒驗到的部分
（fast build、128-host、GUI 頁、硬體頁）照實列出，沒有假裝覆蓋。

## 1. 驗證方法（兩級證據，不混用）

- **親自執行**：乾淨室 VM（4 vCPU，從未裝過任何 NDTwin 元件）逐行照手冊做，指令逐字
  貼、不腦補；harness 先自測（force-red）再上場。
- **讀過未執行**：無法在 VM 執行的頁（GUI、硬體、未安裝工具），逐頁對 source 核對，
  明確標「讀過未執行」，強度嚴格低於前者。

## 2. 安裝手冊（Installation Manual）——親自執行

| 範圍 | 結果 |
|---|---|
| §1–§5（環境、依賴、取源、編譯） | ✅ 兩輪全過 |
| §6.0–§6.6（P4/bmv2 環境、起 fabric） | ✅ 整段逐行過，31 步 0 非零 rc |
| T-2「裝完會動」 | ✅ 12/12 pingall、paths=12——裝出來的 fabric 真的轉發 |
| §6.7（fast build） | ⬜ **未跑**（照實標） |
| 128-host 例子 | ⬜ **未測** |

**抓到並已修的手冊缺陷**（kernel `89c1754`＋website `cd684ba`，push 凍結中待批次）：

- **M-3**：手冊教讀者 grep `ECONNREFUSED`，軟體實際輸出 `Connection refused`／`[Errno 111]`
  ——照手冊查會查到「沒有錯誤」。
- **M-4**：Terminal 3 的指令是互動式的，會問三個手冊隻字未提的問題（環境／拓撲／AI），
  且手冊的 `export OPENAI_API_KEY` 說法暗示不會問。已補答案（1,1,2）與旗標寫法。
- **M-5**：「等 ~60 秒」實測 ~80 秒（單機單次，不宣稱通例）；安全寫法是「等訊息出現」。
- **M-1**（Ubuntu Server 相關）：**仍開著**，見正本。

## 3. 「裝完之後可以正常運行」——整機輪 T-4（親自執行）

基線：kernel `89c1754`（與註冊基線 `faffdbe` 源碼逐 byte 相同，空 diff 驗證）；binary 用
行為特徵反向指認（不是憑 PATH 或 mtime）。預註冊（PREREG＋賽前修正）先於任何資料。

- **stack 收斂 `T_stack` = 16 s**（P4、真時鐘）。
- **Energy-App 完整走一輪**：7 檢查 0 失敗；關 3 台交換機、20 條邊下線，**每條下線的邊
  都連著一台被關掉的交換機**——分身的帳是一致的。
- **08-18 舊發現逐條重驗（R-5，兩臂）**：F-3 **已修**（實測證實）、F-4 **已修**（實測證實）、
  F-2 **仍在**（與 08-18 相同）、F-1 本輪構不到（P4 無對應機制，照第三分支記）、
  F-5 **仍在且機制這次指認出來了**（見下）、F-5b **差分完整**（唯一需要兩臂的檢查）。
- **新發現 FINDING-03（系統缺陷，兩個 fabric 都有）**：kernel 的流表檢視會把「已排隊、
  尚未編程」的請求當成表格列服務出去，只在 t=0 可見。08-18 報「no phantom」是因為取樣
  第一格在 t=2——已經在事件之後。已開工單（T-11）。
- 誠實限制一：整輪跑在**安靜網路**上，這一個條件同時削弱三個結果（R-2 幾乎不可證偽、
  F-1 打不到、F-5 的窗無競爭）；下一輪已註冊的最有價值改動＝加流量。
- 誠實限制二：執行者在量測窗內的 commit 觸發了背景審查工具（現已停用），**帶自我污染
  紀錄**（`CONTAMINATION-agy-runs-i-started-myself.md`）——時間敏感的量各自標注，
  `T_stack` 與 app 收斂段驗證乾淨；受污染的比較類發現（FINDING-05 的 P4/OVS 不對稱）
  已由執行者**自行下修為觀察**，不作宣稱。

**程式缺陷（安裝手冊線上抓到、已修）**：

- **P-1**：第二個 proxy 實例會在發現 port 被占**之前**先連交換機、寫規則——已修
  （`e29424e`：先佔 socket 再啟動，無 TOCTOU）。
- **acquire_lock 三缺陷**：畸形 body 照樣拿鎖、缺 `type` 靜默替換、錯誤訊息混淆——已修
  （`dff87f9`，拒絕路徑與放行路徑兩支都 live 驗過）。
- **release/renew 同族缺陷（T-7b）**：已修好、mutation gate 全套通過（635/635），
  **待 auditor 親驗後合併**（`5e878ec`）。

## 4. User Manual（部分親自執行）

- 主流程頁（OVS operate，Terminals 1–3）✅ 跑過；M-4/M-5 出自這裡。
- **te（Traffic-Engineering）在 documented 路徑上起不來**：`ask_mode()` 的 `input()` 無
  EOF 防護，非互動環境直接死；pty 下正常。app 缺陷，不是手冊錯，但讀者會踩到。
- NSR／Simulation Platform 頁可執行、**尚未跑**；NTG 頁需先裝 NTG；WebGUI／
  TrafficVisualizer 頁 GUI-only、硬體頁需實機——皆「讀過未執行」。

## 5. Developer Manual——API 頁 T-6（親自執行）＋桌面核對

- **文件化的 29 個端點：全部存在、方法全部正確、零缺陷**（探針先做陽性對照，parser
  缺陷自抓自修後 41/41 route 可見）。
- **但 kernel 有 41 條 route，12 條沒有文件（29% 的 HTTP 表面）**——含
  `/ndt/intent_translator/text`（**出貨的 Web-GUI 正在呼叫**）與 `/ndt/historical_logging`；
  其餘十條是 group/meter 兩個成套家族＝兩個功能出貨沒補文件。已開一張文件票（T-13）。
- 桌面核對（讀過未執行）另records：app 語言寫反（ESA 是 C++、TE 是 Python）、WebGUI
  Assistant 章節教的功能現況必回 503、lock API 頁未寫 `type` 必填（待 T-7b 合併後與
  repo 內 API 文件一起同步到網站）。

## 6. 為這條線開出的後續工單

| 票 | 內容 | 狀態 |
|---|---|---|
| T-8 | `ndt` 的 `model matches fabric` 永不可能失敗（模型比模型）＋related 三項 | 已開，待修 |
| T-10 | 整機 harness 五項缺陷（時鐘、port 檢查、還原鏈等） | 已開，待修；危險路徑已加勿執行注釋 |
| T-11 | kernel：排隊未編程請求被當流表列服務（FINDING-03） | 已開，修法待裁 |
| T-12 | Energy 在 P4/OVS 行為不對稱（觀察票，閘在儀器修復＋有流量輪後） | 已開 |
| T-13 | 12 條無文件 route 補進 DM API 頁 | 已開 |

## 7. 正本索引

- 安裝 §1–§6＋T-2＋P-1：`doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-section6-and-T2.md`
- T-3（User Manual 首篇）：同目錄 `FINDINGS-T3-user-manual.md`
- 桌面核對 28 條：同目錄 `FINDINGS-desk-check-remaining.md`
- T-4 整機輪：`doc/audit/2026-08-30_live-full-stack-round/`（PREREG、FINDING-01〜05、
  R2/R5 結果、BASELINE-PROVENANCE）
- T-6（API 頁）：同目錄 `FINDINGS-T6-developer-manual-api-page.md`
- 修復證據：`doc/audit/2026-08-28_chaos-harness/07_fix-evidence.md`（P-1＋acquire）；
  T-7b 的 `08_t7b-evidence.md` **仍在 `t7b-release-renew` 分支（`5e878ec`）**，合併後
  才會出現在同目錄——引用時注意。
- 安裝 §1–§5 兩輪與 T-5 修復：`doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-sections-1-5.md`、`FINDINGS-T5-fixes.md`
