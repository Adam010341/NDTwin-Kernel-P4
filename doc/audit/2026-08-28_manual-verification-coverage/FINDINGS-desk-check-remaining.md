# Desk-check — the manual pages nobody had run (5 full + 3 spot-checked)

**2026-08-30. READ, NOT EXECUTED — every finding below.** Overall strength is one tier below
the three executed FINDINGS files in this directory. No fabric, no sudo, no GUI, no HTTP was
issued. "The code says X" ≠ "running it does X".

Produced by a dispatched desk-check agent (worktree branch `audit/desk-check-remaining-manual-pages`,
HEAD `b20b8ae`); the agent's environment blocked writing report files, so the auditor placed this
file from the agent's delivered content, verbatim in substance.

Provenance discipline: every kernel line number was re-verified on `b20b8ae` by printing the line
(`awk 'NR==n'`); referenced files were `cmp`-verified byte-identical to the dev tree. The agent's
initial worktree base was `f5db629` (upstream fork, no `p4_proxy//tools//tests/`) — everything was
re-verified after re-basing. A parallel sweep reported fabricated-value lines at `:853/:455`,
which on `b20b8ae` are different code; the real sites are `:944/:1545/:1622/:1807`. **Only
personally-opened citations are included**; the three spot-checked pages carry gaps rather than
unverified citations.

Pages: Developer Manual — AI Model Training and Inference / Application Examples /
Application structure / Simulation Platform / NTG. User Manual — WebGUI / TrafficVisualizer /
Operate a Physical (Hardware) Network.

**28 findings** (Tier1 blocks-the-reader 4 / Tier2 misleads 10 / Tier3 minor 10), plus 16 claims
verified correct and 12 items not desk-checkable.

[Co-developed with claude code -- Adam]

---

## Tier 1 — 讀者會卡住

**T1-1 kernel 啟動指令跑不完，頁面沒提會反問兩題**
Physical:58 `sudo -E bin/ndtwin_kernel --loglevel info`，且 :18 稱「Terminals 1 through 2 in the
exact order」。`main.cpp:161-264` 要求 `--mode` 與 `--ai/--no-ai`：TTY 下 `:203`、`:256` 各問一題；
非 TTY 時 `:207`/`:260` 經 `:188` 印錯誤後 `exit(2)`。→ 終端機前停在無預告提示符，腳本裡直接
rc=2。**與 `FINDINGS-T3-user-manual.md` 的 M-4 同家族第二例**（此頁 2 題，實體模式跳過拓樸題）。

**T1-2 `/ndt/acquire_lock` 必填欄位頁面完全沒寫**
AppStructure:160、§5.3(:154-164) 只給方法+路徑。`LockManager.hpp:105-106` 要求 `type`，合法值僅
`:43-45` 三個；缺少時 `HttpSession.cpp:1924`→`:1940` 回 400。兩個真實呼叫端都送了：
`Energy-Saving-App/src/app/http.cpp:425`、`Traffic-engineering-App.py:71`。→ 照頁面寫的第一版必拿 400。

**T1-3 NFS 目錄慣例錯（深度 2 vs 實際 5，`case_id` 是目錄不是檔名）**
Simulation:87-88 `/srv/nfs/sim/<app_id>/<case_id>.json`。實際
`Simulation-Platform-Manager/include/settings/sim_server.hpp:36-44` =
`nfs_mnt_dir/app_id/simulator/version/case_id/input_file_path`，`:18` 掛載點 `/mnt/nfs/sim`。
kernel 註解佐證 `ApplicationManager.hpp:151`。

**T1-4 `inputfile` 說是完整路徑，實為最後一段；給絕對路徑會被靜默改寫**
Simulation:108/:118。`include/types/sim_server.hpp:35-36` 把收到的值接到五層之後。加乘：
`fs::path::operator/` 右邊絕對時**丟棄左邊整串**，故範例值原封不動變回
`/srv/nfs/sim/1/case_123.json`，而模擬器主機掛在 `/mnt/nfs/sim` → 檔案不存在，且該路徑在
kernel 主機上明明是對的，極難自診。

## Tier 2 — 照做「成功」但拿到錯的東西

**T2-1 實體頁從沒說要選 `[2] Remote Testbed`，選錯拿到捏造值**（全頁無 `mode`/`testbed` 字樣）。
`DeviceConfigurationAndPowerManager.cpp:1542-1545` cpu = `10 + hash%50`、`:941-944` memory 同款、
`:1619-1622` temp = `25+hash%25`；對照組真量測在 `:1811`/`:1823` 的 `snmpget -v2c -c public`。
→ 數字合理且每台穩定不變，**無任何跡象**顯示與硬體無關。

**T2-2「隨便打字串就會停用 LLM」是錯的**。Physical:53-55。`LLMAgent.cpp:27` 讀 env，`:35` 只判
`nullptr`，無合法性檢查；亂字串讓 `main.cpp:344` 照樣建出 IntentTranslator。→ 前半成立、
**後半不成立**，功能是啟用的，失敗推遲到打 OpenAI 時。真正開關 `--no-ai`(`main.cpp:134-136`)
頁面沒寫；若選 `[2]` 則該 `export` 全無作用。

**T2-3 預設鎖 TTL 是 5 秒，頁面把 renew 寫成 optional**。AppStructure:161、:99、:100 vs
`LockManager.hpp:27` `DEFAULT_TTL_SECONDS = 5`。兩個真實 app 都送 `ttl:300`（60 倍）。→ 一輪模擬
不可能 5 秒內完成，鎖自己過期，:99/:100 兩句保證皆不成立，且 app 不會收到通知。

**T2-4 `release_lock`/`renew_lock` 缺 `type` 時靜默改成 `routing_lock`**。
`HttpSession.cpp:1988-1989`、`:2035` + `LockManager.hpp:28`；renew 的 body 解析包在空 catch
(`:2004` 附近)。→ 拿了 `power_lock` 的 app 照頁面（無 body）release，會釋放**沒持有過的**
`routing_lock`，自己的鎖仍被持有，**兩邊都回 200**。
⚠️ **這是程式缺陷不只是文件缺陷，而且 T-7（`dff87f9`）只修了 `acquire_lock`，此兩端點仍在。**
修之前必須先掃七個 sibling repo 確認呼叫端在 release/renew 時送不送 `type` —— acquire 的掃描
結果不能沿用。

**T2-5「Application Lock」不存在，鎖是資源層級且全域**。AppStructure §3.3(:95-100)。
`LockManager.hpp:33` 的 map 全 process 一份、與 `app_id` 無關。→ 兩 app 各拿
`graph_lock`/`routing_lock` 互不排斥，:100 保證不成立；同 app 兩實例反而互卡。

**T2-6「Payload from NDTwin」不是 NDTwin 定的**。Simulation:131-140。
`SimulationRequestManager.cpp:150-151` 原樣 `-d '<body>'` 轉發，kernel 只要求 `app_id` 是字串
(`HttpSession.cpp:1273`)。→ 契約其實跟模擬器簽，換模擬器就 KeyError。

**T2-7 `outputfile` 真實檔名是固定的 `output`（無副檔名）**。`sim_server.hpp:24` + `:46-53`；
app 端 `app.hpp:56`/`:27`。→ 依 `<case_id>_result.json` 撈永遠撈不到。

**T2-8 註冊回傳 `app_id` 是數字，派送時必須是字串**。`HttpSession.cpp:1391`（int→number）vs
`SimulationRequestManager.cpp:46-50`+`:86`+`:90`。→ 最自然的寫法（直接轉手）會 400；頁面兩個
範例(:75 `1`、:117 `"1"`)剛好把陷阱編碼進去卻沒說。

**T2-9 Application Examples 兩個 app 語言寫反**。頁面 :17 ESA=Python、:32 TE=C++。實際：ESA 有
`Makefile`/`src/`/`include/`/`.cpp` 測試、`*.py` 零命中 → **C++**；TE 只有
`Traffic-engineering-App.py`、`*.cpp/hpp/h` 零命中 → **Python**。旁證 `LockManager.hpp:80-81`
點名「Energy-Saving-App http.cpp:425」。→ 找 C++ 範例的人被送去 Python repo。

**T2-10 Web GUI 的 NDTwin Assistant 整節在頁面自己教的啟動方式下是死的**。WebGUI:142-196
（五種 prompt、55 行、7 張圖）全節未提需要金鑰或 AI 模式。`Web-GUI/src/components/llm/LLM.ts:8`
+`:21` 拼出 `/ndt/intent_translator/text`（字串拼接，單一路徑 grep 抓不到）；
`HttpSession.cpp:1414-1421` 在 translator 為 null 時回 **503**，而它只在 `main.cpp:344` 成立時
存在。→ 選 `[2]` 或 `--no-ai` 則全部 503；照 T2-2 填亂金鑰則改成呼叫 OpenAI 時失敗。

## Tier 3 — 較輕

- **T3-1** Physical:16 要讀者準備 `testbed_topo.py`，但它 `:4-9` 匯入 mininet.*、`:15 HOST_NUM=128`，
  `components.env` 命名為 `OVS_TOPO_SCRIPT`，**頁面無任何指令用到它**。
- **T3-2** Physical:15/:16 兩個連結都指向**模擬環境**安裝頁；安裝手冊的實體頁才有 `:211`
  Step 4.2 `AppConfig.hpp` 與 `:358-373` Step 5.5 SNMP（正對應
  `DeviceConfigurationAndPowerManager.cpp:1811/1823`）。→ 順著頁面連結走永遠到不了硬體前置。
- **T3-3** Physical:3-6 的 frontmatter 承諾交換機 OpenFlow/sFlow 設定與依賴清單，96 行本文一項
  都沒有；該段與安裝手冊同名頁**逐字相同**（複製貼上）。Hugo 會輸出成頁面摘要/meta description。
- **T3-4** Physical:80-86 驗證步驟把「有資料」與「空清單」都寫成預期 → **沒有鑑別力，永遠不會紅**；
  且全頁未叫讀者把 sFlow 指向 `SFLOW_PORT=6343`。
- **T3-5** `intelligent_router.py:56` 的 `is_mininet` 註解寫「False: physical testbed」但 `:602`
  無條件覆寫（`:42-55` 檔頭自承）。→ 實體讀者會合理地去改而全無效果。🔴 **文件面條目，程式面
  Adam 已裁「兩份都不動」，不要重開**。
- **T3-6** Simulation:57 說 "unique app_id"，但 `ApplicationManager.cpp:35` + `:58` 註解自承
  `m_nextAppId` 在記憶體、重啟從 1 開始。
- **T3-7** Simulation:155 忠實轉載 `HttpSession.cpp:1368` 的 `'appName'`，而實際欄位是
  `app_name`(`:1365`)；`:1380` 的 `'simulationCompletedUrl'` 同型且頁面只轉載了兩者之一。
- **T3-8** Visualizer:391 的 `NDT_API_URL` 宣稱**正確**（`NetworkTopologyApp.java:295`/`:297`），
  但 repo 根目錄的 `config.properties` 自稱主要途徑，而
  `grep -rn "config.properties\|ndt.api.url" src --include=*.java` **零命中** → 那是個**沒有讀者
  的設定檔**，改了無效果，頁面未提故無警告。
- **T3-9** WebGUI:37 只說 Device Name 上限 4 字；`DeviceInformation.tsx:125-132` 與 `:134-141`
  **兩者都是 `>4`**，Nickname 第 5 字被靜默丟棄並顯示未預告的錯誤。
- **T3-10** AI/ML 頁 :54（1 小時）vs :91（10 分鐘）vs :60（168 小時）自我矛盾；`pybind11` 在
  kernel `src/`+`include/`、兩個 app repo **全零命中**，`LSTNet` 在兩 app 也零命中 → `:50` 起的
  「A Complete Example」無隨附實作可對照。附帶 `:283` 的 `your_c/c++.exe` 是 Windows 副檔名而
  平台是 Ubuntu。

## 無法 desk-check（12 項，不猜）

需實跑：① T1-1 兩題實際長相與順序 ② T2-1 選 `[1]` 後 GUI 實際顯示 ③ 所有 400/503 是否真發生
（T1-2/T2-8/T2-10）④ T1-3/T1-4 實際失敗訊息 ⑤ Physical:36「wait seconds」實際時長
（`intelligent_router.py:197` `NDTWIN_RYU_SETTLE_S` 預設 40 是**上界**非固定等待，且三頁手冊都
沒提這個環境變數）⑥ WebGUI/Visualizer 一切純 UI 行為（按鈕順序、面板、拖曳存檔、播放速度、
快照載入）⑦ WebGUI Expression Filter 實際文法（未讀到 parser）。

碼裡查不到／不在本機：⑧ Examples:9,24 的 status/version badge 無來源可對 ⑨ Examples:19,33 與
Simulation:173 的 GitHub 連結可達性（**本輪刻意未發任何對外請求**）⑩ AI/ML:73 的 Python 版本
（描述使用者自己的訓練環境，repo 無對應 requirements）⑪ NTG:700-708 flow type 表、:476-489
`_parse_duration`、:265-273 `SenderReq` ⑫ Visualizer 的 Fat-Tree 佈局、播放速度陣列、350MB、
截圖資產齊全度。⑪⑫ 屬未複核批次，**留給第二輪**。

## 核對為正確的 16 條（避免下一輪重做）

`--loglevel info` 合法(`Logger.cpp:35`/`:44`)；`/ndt/get_detected_flow_data` 存在(`:157`→`:575`)；
`all-destination paths installed` 確實會印(`intelligent_router.py:1257`/`:1460`)；`app_register`
的 request/response 形狀(`HttpSession.cpp:1365`/`:1376`/`:1391`)；註冊會建
`/srv/nfs/sim/<app_id>`(`ApplicationManager.cpp:40`→`:51`，`main.cpp:361`)；派送五個必填欄位且
皆 string(`SimulationRequestManager.cpp:46-50`+`:86`)；`received_a_simulation_case`/`app_register`
/`renew_lock`/`release_lock` 路由皆存在(`HttpSession.cpp:239`/`256`/`306`/`310`)；`NDT_API_URL`
有被讀且預設正確；Device Name 4 字上限；NTG 的 `command_line` 進入點(`:257`，實際標註是 `str`
非 `Optional[str]`)、`ConcateCompleter`(`:63`)、inventory key `Mininet_Testbed`/`Hardware_Testbed`
(`:301`/`:322`)、**「加新指令」食譜的 dispatch 形狀正確**(`:427` 內確為 `cmd, *args = parts` 後接
`if cmd == 'exit':` 串鏈)、callback `_on_flow_finished`(`:491`)。

## 建議（非結論）

1. T1-1 與 T2-1 **要一起修**：只補「選 [2]」而不補「會被問問題」，讀者仍卡在提示符。
2. T2-3/T2-4/T2-5 **同一個根**：§5.3 缺 request body 規格。補一張含 `type`（三合法值、必填）與
   `ttl`（預設 5 秒、範例 app 用 300）的表，四條一起解決。
3. T3-4 建議換成有鑑別力的驗證：拿掉「空清單也算通過」，並在前面補一步設定交換機 sFlow 指向
   `SFLOW_PORT`。
