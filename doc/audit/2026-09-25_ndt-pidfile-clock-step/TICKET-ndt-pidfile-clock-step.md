# TICKET-ndt-pidfile-clock-step — 時鐘往前調超過 2 秒，健康 stack 的 pidfile 會被當成「號碼被回收」

[Co-developed with claude code -- Adam]

- 發單：orchestrator「9/24 ochestrator」，2026-09-25。來源：opus-judge 審 `fix/ndt-ovs-claim-0925`（`e1420df2`）的第 2 點（should-fix）。
  判官全文：`scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925/judge-OVS-r2-e1420df2.md`，(b) 段。
- **不擋 OVS claim 那張單合併**（判官的裁定），但那張單讓這條規則多影響了 `status --check` 和 `ndt down` 刪檔，所以單獨開。
- **狀態：還沒派工、還沒排程。**

## 1. 事實（判官讀碼推得，沒有實測；接手的人自己再核）

- 規則：`stack.sh` 的 `stop_one` 會比對程序啟動時間（`btime + starttime/HZ`）和 pidfile 的 mtime，程序比檔案晚超過 2 秒啟動，就判定號碼被回收、拒絕送訊號。
  OVS claim 那張單（F2／F8）把同一條規則搬進 `ndt` 的 `pidfile_judge` 和 `stack_pidfile_row`。
- **推論出的失效情境**：
  - 單純 suspend／resume 不會觸發：starttime 以 boottime 計、含 suspend，btime 前後不變。
  - 會觸發的是 resume 後或開機後第一次 NTP 把時鐘往前調（或手動 `date -s`）：每往前調 Δ，btime 就加 Δ，算出來的啟動時間跟著晚 Δ，pidfile 的 mtime 卻不變。
  - 累積往前調超過約 2 秒後，健康 lab 的 `kernel.pid`／`ryu.pid`／`p4_proxy.pid` 會被判成回收：
    - 有 baseline 時 `status --check` 變 rc 1；
    - `clean`／`down` 不再把這個檔當成要處理的對象（subject）；
    - `down` 會刪掉 pidfile；
    - 在那之前 `stop_one` 已經拒絕停這個程序 ⇒ kernel 繼續跑、卻沒有任何紀錄，下一次 teardown 會把它當外人。
- `stop_one` 那一半在 OVS 單之前就存在：「lab 沒被停掉」是既有問題，OVS 單加上的是「連紀錄都刪掉」。
- **範圍**：app 的 `app_*.pid` 不受影響。它的身分先用 argv 簽名比對（`ndt` 約 :4781），比中就是 live，輪不到時間檢查；不要把修改擴大到 app。
- **kernel 行為的前提也是推論**：「starttime 以 boottime 計、suspend 前後 btime 不變」沒有實測。接手的人先在這台機器上唯讀驗證：resume 前後、NTP 校時前後各讀一次 `/proc/stat` 的 btime。

## 2. 要做的

1. **身分改用和時鐘無關的依據**（判官建議）：
   - stack 的 `<name>.pid` 記的是 `supervise.sh`，它不 exec、會一直活著，argv 裡有 `$PID_DIR/<name>` 這個元素（`stack.sh:579`；`supervise.sh:3,48`）⇒ 先比 argv。
   - `.child.pid`：**不能拿 `stack.sh` 寫下的 `<name>.cmd`（`stack.sh:587-588`）逐字比**（判官第三輪更正了自己 r2 的建議）。
     `.cmd` 記的是包裝指令：以 kernel 為例是 `bash -c "export …; cd … && exec ./bin/ndtwin_kernel …"`（`stack.sh:1118-1119`）；而 `/proc` 看到的是 exec 之後的 argv。
     兩條可行的路：在記錄的指令裡找 exec 之後的 argv；或 `.child.pid` 不做這項比對，它是否有效由 supervisor 那個檔推出來。
   - **`stack.sh:584` 那條路徑沒有 supervise.sh**：那裡記的 pid 就是元件本身，argv 裡沒有 `$PID_DIR/<name>`，要另外處理。
   - 只有身分比對不出結論時，才輪到啟動時間。
2. `stack.sh` 的 `stop_one` 和 `ndt` 的 `pidfile_judge`／`stack_pidfile_row` **一起改、用同一個判準**，不要一邊一種。
3. **先查證有沒有發生過**：grep 過去的 teardown log，找 `stop_one` 的 `refusing to stop … started Ns AFTER`。有的話列出日期與當時的時鐘事件。
4. **手冊 `doc/2026-08-17_testing-manual.md` 約 :522-523 說過頭了**（OVS 單第三輪加的）：它說 `--check` 翻成 1「是新規則，不是 lab 壞了」。
   可是真的回收代表某個有登記的元件已經不在，另一種可能是本單的時鐘誤判。改成「先看 problems 那一行」，並指向本單。
   改之前先確認手冊的變異閘門（`mutate_manual_rc_table`、`mutate_manual_no_stale_in_progress`）錨定的句子。

## 3. 驗收

- 離線，紅燈先行（分開 commit）：
  - 用 fixture 模擬時鐘往前調：btime 可注入，或把 pidfile mtime 倒填。
  - 健康 stack 的 pidfile 仍判 live、`down` 不刪、`--check` 不變紅。
  - 真正被回收的號碼仍判 stale（對照組）。
- 具名變異：身分檢查拿掉、只看時間，要變紅。
- 既有 `test_ndt_ovs_claim`、`test_ndt_up_down_robust`、stack.sh 相關測試全綠。

## 4. 紀律

同 `doc/audit/2026-09-25_p4-heartbeat/TICKET-P4-heartbeat.md` §3。
