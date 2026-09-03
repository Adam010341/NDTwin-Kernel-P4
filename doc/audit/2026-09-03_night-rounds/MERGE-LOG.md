# 合併日誌 — 2026-09-03 下午

Adam 14:xx：「不會（看 18 份 diff），怎麼合併你自己決定。」這份是每一支的裁決與證據。
**只合併進 trunk；不推。** push 的阻擋（P4-public 的用途與內容）另案。

[Co-developed with claude code -- Adam]

## 套用的規則

併：有變異閘，且（auditor 重跑過 或 agent 的 raw log 進了 repo），且合併乾淨或衝突已理解並解開。
等：C++ 半邊沒編過（靠這次整合第一次編）、或依賴一支還沒併的。
每一支 `--no-ff`，一支一個 merge commit，可以整支 revert。

## 順序與裁決

| # | 分支 | 裁決 | 理由 / 衝突 / 事後動作 |
|---|---|---|---|
| 1 | `docs/known-issues-batch1` | ✅ 併 | 純文件；Adam 說不看 diff ⇒ 依規則進。乾淨 |
| 2 | `fix/deterministic-path-tiebreak` | ✅ 併 | 5 變異 0 存活（auditor 重跑）。乾淨 |
| 3 | `fix/p4-priority-not-silently-dropped` | ✅ 併 | 7 變異 0 存活（auditor 重跑，含 cherry-pick 後）。501 取代假成功是正確性不是行為裁量。乾淨 |
| 4 | `fix/l9-make-topology-stdout-json` | ✅ 併 | 見 `BRANCHES-FOR-REVIEW.md`。乾淨 |
| 5 | `fix/g7-ndtwin-lab-config` | ✅ 併 | 59 checks＋閘門；乾淨（先於 g9 進，所以衝突落在 g9 那一步） |
| 6 | `fix/g9-cleanup-no-pkill-f` | ✅ 併，**解了 3 檔衝突** | `ndtwin-lab` 兩塊：第一塊兩份同義註解取 G-9；第二塊是相鄰（sweep 函式 vs `lab_conf_gate`），兩者都留，順序 sweep→sourced-return→gate→case。`NEXT.md`／`RATIONALE.md` 兩份文件撞名，全留。**合併後重跑**：G-7 59/59、G-9 29/29、兩閘門全捕 |
| 7 | `fix/g6-ndt-apps-liveness` | ✅ 併 | 只撞 `NEXT.md`／`RATIONALE.md`（日誌檔，全留）。**它帶回 #50 的形狀一處**（`app_wait_stopped`），下一步補 |
| 8 | `fix/redirection-order` | ✅ 併 ＋ 補 g6 那行 | 合併後那行改回 `2>/dev/null <`，閘門加 M2b 專門守它。26 checks、17/0 |
| 9 | `fix/ports-that-block-restart` | ✅ 併 | 9/9（auditor 重跑三次）。乾淨 |
| 10 | `fix/ndt-sudo-surface` | ✅ 併，**解 `ndt` 衝突** | 與 ports 相鄰（兩張表各自 `source`），兩邊都留。33 checks、14/14 |
| 11 | `fix/ndt-up-defaults-to-ovs` | ✅ 併 | Adam 裁的行為變更。23 checks、8/8 |
| — | **合併修復** | 🔑 **五個「各自為真、合起來為假」的 harness 假設，沒有一條是碼的缺陷** | (1) redirection 錨點 `cut -c1-90` 因 g6 多一站點而不唯一 → 每站點自己的錨＋M2b；(2) sudo 抽取器把 g6 註解裡的 `sudo -n ndtwin-lab` 當新命令 → 字面拼法對到 `lab` 列；(3) ports／sudo／(5) up-target 三個閘門只複製「ndt＋自己的表」，合併後 ndt 要 `source` 兩張 → 各補對方的表，up-target 的測試把前置條件具名（之前是 sourced `exit 2` 被 `>/dev/null` 吞掉、整套靜默死亡）；(4) redirection 靜態守衛**用行號**讀 `ndt:894`，合併後那行到 954，守衛讀到註解照樣綠、M14 存活 → 內容錨定＋逐站點檢查＋斷言數量。修完：7 套 shell 套件全綠（18／33／23／26／59／29／52），閘門 17/0、9/0、14/0、8/0 |

