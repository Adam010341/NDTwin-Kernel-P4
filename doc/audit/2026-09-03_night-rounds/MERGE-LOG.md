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
