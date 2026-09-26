# TICKET-ndt-serve（第一刀）

09-24 21:5x 由 9/24 ochestrator 開單。需求是 Adam 用互動表單裁的，四題都選了建議項。
承辦：session「ndt serve」。Adam 可以直接跟這個 session 對話；orchestrator 只負責開單和收件審查。

## 0. 為什麼要做

Adam 的原話（09-24）：「未來有沒有辦法把 NDTwin 直接變成一個桌面 app？讓它成為 NDTwin 唯一一個入口？」
他列了三個痛點：
1. 調整拓樸圖很麻煩；
2. 要手動在 mininet 輸入指令，或直接打 NDTwin 的 API，很麻煩；
3. 要手動用指令打開一堆 app，很麻煩。

orchestrator 當時建議分三步：
- 先做 `ndt serve`：一個本機 HTTP 服務，把 `ndt` 的 up/down/status/claim 和 app 起停包起來；
- 再在 Web-GUI 上加 Lab 控制、App 啟動器、拓樸編輯器；
- 外殼（Tauri/Electron）放最後，而且可能用不到。

## 1. 需求（Adam 09-24 21:4x 裁定）

| 題目 | 裁定 |
|---|---|
| 使用對象 | **先給 Adam 自己用**。只綁 127.0.0.1、單人、不做帳號登入。 |
| 第一刀範圍 | 解決**痛點 2＋3，只做後端**。用 HTTP API 包 `ndt` 的 up/down/status/claim/release，再加 `apps` 的起停和清單。畫面放下一刀。痛點 1（拓樸編輯）不在本刀。 |
| 交付門檻 | **只放分支，附 live demo 和報告，Adam 看過才併、才推**。不併 trunk，**不推任何遠端**：`p4` 和 `lab` 兩個本體都是公開 repo。 |
| 終局形態 | **瀏覽器開 localhost 就是入口**。之後由 ndt serve 同時提供 API 和 Web-GUI。本刀不做 GUI，但路由要預留位子：例如 API 放在 `/api/v1/...`，`/` 留給之後的靜態檔。 |

## 2. 環境事實（orchestrator 09-24 實查）

- **`ndt` 本體**：`tools/test_workflow/ndt`（bash，約 10k 行）。`~/.local/bin/ndt` 是指向**主 checkout** 那份的 symlink。
  - 動詞以 `ndt help` 為準：
    - `up [ovs|4|ovs4|p4 [N]|p4 --app <dir>]`
    - `down [--deep]`
    - `status [--check]`
    - `clean`、`check`
    - `apps [names]`：沒給參數又在終端機上時，會進互動挑選器 ⇒ 服務端要給名字
    - `claim [min] [note]`、`release`
  - **exit code 的語意照原樣保留**，細節見 `ndt help`：
    - 0：成功
    - 1：量到了，但結果是髒的
    - 5：guard 拒絕，**什麼都沒建**
    - 2：用法錯誤
  - 🔴 5 不能被當成一般失敗蓋掉。
- **root 權限**：ndt 內部呼叫 `sudo /usr/local/sbin/ndtwin-lab`（NOPASSWD），外加 ovs-vsctl／mnexec／限定形狀的 tc。
  - ndt serve 以 adam 身分執行。
  - **不需要、也不准**新增 sudo 規則或 root 程式。agent 沒有這個授權，Adam 睡了。
- **`ndtwin-lab` 只認一棵樹**。`ndt up` 會檢查「這一份是不是同一棵樹」，兩個 checkout 混用的情況會被拒絕。
  ⇒ 服務碼可以放在你的 worktree，但 **live 時實際執行的 `ndt` 要用 `~/.local/bin/ndt`，也就是主 checkout 那份**。建議把路徑做成可設定。
- **每一個 `ndt` 指令都要帶 `NDT_OWNER`。** 動 lab 之前先 claim；想知道有沒有實驗在跑，看 `ndt status` 的 `measuring` 欄。
  - 🔴 `measuring nothing` 只是當下那一刻的取樣，`until X` 只是上限，**兩個都不是租約**。
- **主 checkout 的 `p4_proxy/mininet/host_count_override` 有一個未提交的值 `4`**，不是我們改的，不要碰。
  - `ndt up p4 N` 和 `--app` 都會改寫它。
  - live demo 只用不會讓它離開 4 的動詞：`ndt up 4`（OVS 4 hosts）或 `ndt up p4 4`。
  - 跑之前、跑之後都用 `git diff` 看一次這個檔。
- **這台筆電的限制**：
  - 編 C++ 會被 systemd-oomd 殺掉，連 Adam 的 app 一起。本刀不該需要任何 build。
  - `/` 只剩約 2.4 GB：**不要裝 Node 或大套件**。Python 優先用標準庫（`http.server`＋`threading`／`subprocess`）；真的要 pip，先確認 venv 在哪、裝多大。
- **Web-GUI**：`~/Web-GUI`，目前在 `main`，另有一個未推的本機分支 `draft/p4-capabilities-0924`。本刀**不碰**，`.env` 和 `NDTwin-Kernel.code-workspace` 也不碰。

## 3. 設計紅線

每一條都要有**看過紅**的測試和具名變異。

1. **只聽本機**：只綁 `127.0.0.1`（可以加 `::1`）；`Host` 標頭不是 `127.0.0.1:<port>` 或 `localhost:<port>` 就拒絕，防 DNS rebinding；**不開 CORS**。
2. **防 CSRF**：Adam 瀏覽器裡的任何網頁都能對 localhost 發請求。所以會改變狀態的請求一律要帶 token：
   - token 在啟動時產生，存在 `~/.config/ndt-serve/token`，權限 0600；
   - 放在自訂 header 裡，這樣就不是瀏覽器的 simple request；
   - 讀取型的 GET 也不能有副作用。
3. **白名單**：
   - 只呼叫 `ndt` 的固定動詞；
   - 參數逐一驗證：平面和主機數用列舉值；`--app <dir>` 要 realpath 之後落在允許的根目錄底下；app 名稱要出自 ndt 自己的清單；
   - **一律用 argv list，不經 shell**。
4. **薄殼**：行為全部走 `ndt`，不在服務端重寫 ndt 的邏輯；exit code 原樣回傳並附上語意；stdout 和 stderr 全文保留、可以查詢。
5. **長工作**：`up`／`down` 要跑好幾分鐘。
   - 做成非同步 job：有 job id 和狀態，log 用串流或輪詢都可以；
   - **同一時間只允許一個會改變狀態的 job**：服務端自己要有鎖，ndt 本身的 guard 也還在；
   - 子程序用 `setsid` 起，這樣服務掛了 job 不會跟著死；job 記錄寫到檔案，服務重啟後還查得回來。
6. 🔴 **永不 `pkill -f`／`pgrep -f`。** 如果要做取消，只能對自己記錄下來的 pid／pgid 送訊號。第一刀可以不做取消。
7. **身分**：`NDT_OWNER` 在服務啟動時設定（例如 `--owner adam`），之後每個 ndt 呼叫都帶它；claim 和 release 開成 API。
8. **入口**：可以做成 `ndt serve` 動詞（exec 一個 Python 服務），也可以做成獨立的 `tools/ndt_serve/`，你決定。但 `ndt help` 要列出它，而 ndt 既有的 help 和變異閘門要維持綠。
9. AI 參與的碼都要標 `[Co-developed with claude code -- Adam]`。code 和 commit message 用英文，給 Adam 的報告用中文。

## 4. 驗收

- **單元測試**：把 ndt stub 掉，§3 每條紅線都要有測試，外加一個 mutation gate。**沒看過紅就不算交付。**
- **live demo**（claim 之後做，owner 用 `ndt-serve-0924`）：
  - 全程走 API：`status → claim → up（4 或 p4 4）→ status → apps 起一支唯讀 app（例如 nsr）→ 停掉它 → down → release`。
  - 每一步的 HTTP 請求和回應全文，連同 ndt 的輸出，都放進 `scratch/overnight-2026-09-05/logs/ndt-serve-0924/`。
  - 同一個序列直接打 `ndt` 再跑一次，作為對照。
- **報告**：寫在你分支上的 `doc/audit/2026-09-24_ndt-serve/REPORT.md`，用四段式。內容：
  - 做了什麼；
  - API 一覽，附 curl 範例；
  - 怎麼啟動；
  - 每條紅線的證據，標明是實際跑過的還是只讀過碼的，兩者不要混在一起；
  - 沒做的事和已知限制；
  - **給 Adam 的決策清單**：下一刀的 GUI、拓樸編輯，以及要給外部使用者用時得補什麼。

## 5. 流程

- **worktree 與分支**：worktree 用 `scratch/overnight-2026-09-05/wt-ndt-serve-0924`，分支 `feat/ndt-serve-0924`，base 是當下的 trunk（`fd7382a3` 或更新）。第一個 commit 先把本工單放進 `doc/audit/2026-09-24_ndt-serve/TICKET.md`。
- **commit 規則**：一律 `git commit -m ... -- <列到檔案>`。**目錄不算明確路徑。**
- **委派**：要派 subagent 就明寫 opus（`opus-worker`）；純機械的活可以交給 deepseek。
- **共用 lab**：orchestrator（`NDT_OWNER=orch-0924`）今晚也要用 lab，要跑 roles 驗收 L1–L6、`06_thirteen` 26 臂和 `01`。
  - 每次 claim ≤30 分鐘，做完立刻 release。
  - 看到 lab 被 `orch-0924` 佔著就等，不要搶，也不要用 `--deep` 或 `--force`。我這邊也會照同樣的規矩。
- **完成或卡住時**：
  - 在你自己的 session 裡寫給 Adam 的報告；他醒來會直接看你那邊。
  - 同時 SendMessage 給「9/24 ochestrator」，一行摘要加 head sha。我會派 opus-judge 審，併不併由 Adam 看過再決定。
- **碰到設計取捨**：選保守的那個，把它寫進報告的決策清單。不要替 Adam 猜大方向，也不要叫醒他。
- **開工前**：先讀 `CLAUDE.md`，以及 memory `MEMORY.md` 最上面的紅線，特別是 oomd、共用 worktree、公開遠端、`pkill` 這幾條。

[Co-developed with claude code -- Adam]
