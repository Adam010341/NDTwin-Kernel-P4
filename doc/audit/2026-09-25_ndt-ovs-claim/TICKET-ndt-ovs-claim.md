# TICKET-ndt-ovs-claim — OVS 的 `ndt up` 要像 P4 一樣尊重別人的 claim；過期 pidfile 要被認出來

[Co-developed with claude code -- Adam]

- 發單：orchestrator「9/24 ochestrator」，2026-09-25；base＝trunk HEAD。
- **Adam 09-25 裁決**：OVS 版 `ndt up` 遇到他人 claim（或量測在跑）**跟 P4 一樣拒絕、回 5**，另給**明確的強制旗標**；「pid 已不存在＝過期 pidfile」的規則併進本單。

## 1. 事實（OBSERVED，給你起點，自己再核）

- `up_p4`（`tools/test_workflow/ndt` 約 :3057）自 09-12 起遇到別人的 claim 回 rc 5；`up_ovs`（約 :4047–4318）沒有 foreign_claim／in_flight 檢查，只印警告就建 fabric。
  09-24 ndt serve 的 live 實測：fabric 在無人持有 claim 的狀態下活了 29 秒（`doc/audit/2026-09-24_ndt-serve/REPORT.md`）。`ndt help` 說「up 在 lab 被別人 claim 時回 5」在 OVS 不成立。
- 過期 pidfile：`.test_run/pids/app_viz.pid`（09-14 留下、pid 已不存在）讓「lab 已 down 再 down」拿不到文件說的 rc 3（已由 orchestrator 手動刪除；本單要讓 ndt 自己認得這種情況）。

## 2. 要做的

1. OVS `up` 的前置檢查與 P4 **共用同一段**（不要複製一份）：他人 claim ⇒ rc 5、量測在跑 ⇒ 照 P4 的既有語意；拒絕時不得留下任何半建好的東西。
2. 強制旗標：若 P4 已有覆寫旗標，OVS 用同一個；若沒有，兩邊一起加同一個，語意一致，使用時寫進 claim 的紀錄檔（誰、何時、覆寫了誰）。`ndt help` 與錯誤訊息講實話。
3. 過期 pidfile：pid 不存在（且 pgid 無程序）⇒ 視為過期：`status` 標出來、`down` 清掉並照文件回 rc（lab 已 down ⇒ 3）。比對程序身分用 pid＋cmdline，**不准 `pkill -f`／`pgrep -f`**。
4. rc 與輸出的改變列成一張表放 SUMMARY（ndt serve 包著 `ndt`，orchestrator 會轉告它）。

## 3. 驗收

- 離線：`tests/shell/` 的 ndt 測試紅燈先行（分開 commit）；具名變異（至少：拿掉 OVS 的 claim 檢查、覆寫旗標不寫紀錄、過期判定改成只看檔案存在）0 survived；既有 ndt／lab 測試全綠；log 在 `logs/gates-0910/*.ndtovs-*.log`。
- live（併進 trunk 後 orchestrator 做；你備好步驟清單）：他人 claim 下 `ndt up ovs` ⇒ rc 5、無 fabric；加旗標 ⇒ 建成、紀錄寫入；down 兩次 ⇒ 第二次 rc 3；人工放一個死 pid 的 pidfile ⇒ status 標過期、down 清掉。

## 4. 紀律

同 `doc/audit/2026-09-25_p4-heartbeat/TICKET-P4-heartbeat.md` §3（worktree、`commit -- <檔案>`、不 push／merge、guard、lab 只在給時段時用、不叫 Adam 做事）。
交件：`scratch/overnight-2026-09-05/hunt-0911/fix/NDT-OVS-SUMMARY.md`。
