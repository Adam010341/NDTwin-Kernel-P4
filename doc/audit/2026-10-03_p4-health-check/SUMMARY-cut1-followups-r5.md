# P4 健檢 Cut 1 後續：第 4 次審查（MERGE AFTER FIXES）的處理

[Co-developed with claude code -- Adam]

- **head**：`3d4fe49a`，疊在 `28a793b6`（`4861d965`＋摘要）之上，三個程式碼 commit 加一個 mutant 修正：
  - `46bfb90f` recover.sh 收窄重新 claim、released 只停行程（修正 1、2、3）
  - `90c19693` GAP-2b 與設計稿引用的出處說明（修正 4）
  - `9ba2bc06` 設計稿副本（§4.5、§14.7，標「r5 (Cut 1 follow-ups)」）
  - `3d4fe49a` R4-1a mutant 改成真的 false
- **LOG** 指 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut1/r5/`。每份 log 第一行是 commit。
- 舊碼的身分（紅燈 log 的表頭第 2–9 行）：`4861d965` 的 `tools/p4_health`，git tree `9263eb24`、recover.sh blob `7e60793c`、副本 sha256 `c4ad1e32…`；綠燈對照用 `73cff685`。

## 1. 觀測到的（OBSERVED，都在 3d4fe49a）

| 檢查 | 結果 | log（LOG 底下） |
|---|---|---|
| S0 | rc 0；COMPLETE | `s0.run.log:4`、`s0-final/probe.log:51` |
| recover | 72 checks，0 failed（Python 3.8.20、3.12.3、3.13.13） | `test_recover.py*.log:93` |
| cells | 98 tests OK（三版） | `test_cells.py*.log` |
| collect（封死） | 57 tests OK（三版）；seal 報告全 0 | `test_collect.hermetic.py*.log`、`seal_report.green.py*.json` |
| H1–H4 | 全部紅（rc 1） | `test_collect.nonhermetic.H*.log` |
| mutation gate | **158 個突變，0 存活**；負對照綠；原檔 byte-identical | `mutate_p4_health.log:967,970,971` |
| check_gate_anchors HEAD／check_test_tmpdirs／test_l1_shell_scoring | ok(154)／414 個檔 0 個／163 checks 0 failed | 各自的 log |

## 2. 逐項處理

| # | 處理 | 紅（舊碼 4861d965） | 綠 | mutant |
|---|---|---|---|---|
| 1a | 重新 claim 只在 `"$ov" == "$PKG"`，或「override 為空 ∧ phase 是 `down-done` ∧ 過期的 claim 檔是自己的 owner」時做；teardown、down-failed、claim-lost 一律 rc 3、什麼都不寫（同 `73cff685`） | `items/fix1-3.recover.OLD4861d965_red.log:71-74` | `items/fix1-3.recover.NEW_green.log:100`；`73cff685` 上案例 1–4 為綠（`items/fix1.recover.OLD73cff685.log:71-74`） | R4-1a、R5-1a、R5-1b |
| 1b | `down-done` 的 `ndt status` 確認沒有 fabric，先於 claim 分支的任何寫入；fabric 還在 → rc 4，`ndt claim` 不會被呼叫 | `…red.log:75` | NEW_green | R5-1c |
| 2 | phase `released` 只做第 3 步（認得出身分的 kill）：不 claim、不動 knob／netem、不 `ndt down`；全部停掉 rc 0，有 kill 失敗 rc 7。已 release 的 run 目錄不能再對後來一輪的 fabric 跑第 4–5 步 | `…red.log:79,81,82,83,84` | NEW_green | R5-2a、R5-2b |
| 3 | 不論 phase，第 3 步有 kill 失敗時，流程做完以 rc 7 結束，不印「done」 | `…red.log:86,88` | NEW_green | R5-3 |
| 4 | `expected_today.tsv` 表頭加一行：GAP-2b 與 DESIGN.md 的完整路徑，在 trunk 分支、不在 main；`table.py` 的 `p4()` 上方同樣一行；TP4 的「GAP-2b judged it red」改為「found it red」；掃描測試改名並把 docstring 寫成只檢查那幾個紀錄檔名；新增測試釘住表頭那行 | `items/fix4.cells.OLD4861d965_red.log:25` | `items/fix4.cells.NEW_green.log:19-22` | 無（資料檔） |
| d | DESIGN §4.5 與 §14.7 寫明收窄後的規則，標「r5 (Cut 1 follow-ups)」 | — | — | — |

## 3. 備註

1. 第一次完整 mutation gate（9ba2bc06）抓到 R4-1a 存活：它把子句換成裸的 `false`，在 `[[ ]]` 裡那是非空字串、等於 true。改成 `( 1 -eq 0 )` 之後，連同其他六個新 mutant 都逐一確認被點名的檢查抓到，再在最終 head 全部重跑。
2. 審查「可以等」的第 5–8 項（`watched_s` 的實際經過時間、HR 每樣本位元組數的 live 查證、探測器自己 `ndt down` 當掉的 phase、released 的訊息措辭）本輪沒動。
