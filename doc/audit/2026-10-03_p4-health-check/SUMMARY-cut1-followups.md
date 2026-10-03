# P4 健檢 Cut 1 後續（第 3 次審查的 10 個 MINOR 加一項衛生）：交付摘要

[Co-developed with claude code -- Adam]

- **分支**：`fix/p4-health-cut1-followups`，從 trunk `73cff685` 開。
- **head**：`4861d965`。六個 commit：
  - `a6a41dd9` recover.sh（第 1、2、8 項）
  - `968340a4` lab_round 的 kill 失敗（第 2 項）
  - `7d85619b` observer 的 route（第 4 項）
  - `2ee04294` table.py（第 3、5、6、7、10 項）
  - `1e4c100b` expected_today.tsv 與掃描測試（第 11 項）
  - `4861d965` 設計稿副本（標「r4 (Cut 1 follow-ups)」：§2.1、§4.5、§14.2、§14.6，新增 §14.7）
- **沒做**：lab、`ndt up`／`claim`、Mininet、sudo、C++ build、push。唯一起的 bmv2 是 S0 的拋棄式那顆。
- **LOG** 指 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut1/r4/`。每份 log 第一行是 commit（`probe.log` 第一行是 HEAD）。
- **舊碼的身分**（第 9 項）：每份 `items/*.OLD_red.log` 的表頭第 2–9 行記了舊碼（`git archive 73cff685 tools/p4_health` 的副本）：git tree `0eb56ed99736`、recover.sh 的 blob `ee473dd4`、副本的 sha256 `85000933…`，並確認副本與 git tree 逐檔一致。第 11 項另記舊 tsv 的 blob `a97e6b7f` 與 sha256。

## 1. 觀測到的（OBSERVED，都在 4861d965）

| 檢查 | 結果 | log（LOG 底下） |
|---|---|---|
| S0 | rc 0；49/49 ok；COMPLETE | `s0.run.log:4`、`s0-final/probe.log:1,51` |
| cells | 97 tests OK（Python 3.8.20、3.12.3、3.13.13） | `test_cells.py*.log` |
| collect（封死） | 57 tests OK（同上三版）；seal 報告：57 個測試都檢查過，tripwire／網路／spawn／真實檔案變動都是 0 | `test_collect.hermetic.py*.log`、`seal_report.green.py*.json` |
| recover | 58 checks，0 failed（三版） | `test_recover.py*.log` |
| H1–H4 | 全部紅（rc 1） | `test_collect.nonhermetic.H*.log`、`seal_report.H*.json` |
| mutation gate | **153 個突變（舊 130＋新 23），0 存活**；只改註解的負對照維持綠；原檔 byte-identical | `mutate_p4_health.log:940-941` |
| check_test_tmpdirs | 414 個檔，0 個 | `check_test_tmpdirs.log:3` |
| check_gate_anchors HEAD | 本 gate ok(151)；全部 rc 0 | `check_gate_anchors.*.log` |
| test_l1_shell_scoring | 163 checks，0 failed | `test_l1_shell_scoring.log:187` |

## 2. 逐項處理（紅＝舊碼，綠＝新碼；log 在 `LOG/items/`，diff 在 `LOG/hunks/`）

| # | 做了什麼 | 紅 | 綠 | mutant |
|---|---|---|---|---|
| 1 | recover.sh 在 `down-done` 對自己過期的 claim 重新 claim：條件改用 `override_ours`（`ndt down` 刪了 override）。另外 `released` 不重新 claim（這是我加的，否則收完的 run 會被重新 claim 後 rc 4） | `item01_02_08.recover.OLD_red.log:53-55` | `…NEW_green.log:83` | R4-1a、R4-1b |
| 2 | `down-done` 保留停行程這一步（在確認沒有 fabric 之後）；kill 失敗寫進 `rec["problems"]`，那一輪不算 complete | recover：`OLD_red.log:64`；lab_round：`item02.collect.OLD_red.log:14-29` | `item02.collect.NEW_green.log:14-17` | R4-2a、2b、2c |
| 3 | HR：模型改成對絕對門檻（`CARRY_SHARE × flow_bytes`）的 Poisson；刺激量 20000 → 24000 幀（15.4 s），任一半不夠的機率 2.6e-6（原 1.98e-5）；HR1 的前提再加「承載的上行必須是沒整形的 s1-eth4」，否則 NOT RUN | `cells.test_hr_stimulus_size_and_order.OLD_red.log:21`；`cells.test_hr1_is_pinned….OLD_red.log:21` | 同名 NEW_green | R4-3a、3b、3c |
| 4 | `observe_counter`、`observe_counter_control` 設 `answer.route`；openapi 讀不到時不設。測試把 FastAPI 預設 404 送過兩個 observer 與真的格：K1 RED「no route」 | `item04.collect.OLD_red.log:21`（PROBE-BROKEN） | `item04.collect.NEW_green.log:14-17` | R4-4a、4b、4c |
| 5 | HU1 巢狀必要鍵加 `v6.flow_identity`（缺鍵 NOT RUN；`False` 照判） | `cells.test_hu1s_nested….OLD_red.log:14,20` | NEW_green | R4-5 |
| 6 | `timing_problem`：負數、非正本的 `Never`／`NEVER`、布林、大於自己 `watched_s` 的數字、不合法的 `watched_s`（超出你列的三種）→ PROBE-BROKEN；CP4 的 watch 檢查移到 `GONE` 之前 | `cells.test_malformed_timed….OLD_red.log`（36 個子測試紅）；`cells.test_a_route_read_as_gone….OLD_red.log:21` | NEW_green | R4-6a 到 6i |
| 7 | 觀測器契約（「讀了、沒有」是 False／0，不是 None）寫進 `table.IDENT` 的註解與 §2.1、§14.7 | — | — | 無（純文件） |
| 8 | `measuring_now` 必須有 `measuring` 或 `orphaned` 一列，否則當忙碌 | `OLD_red.log:68-69` | NEW_green | R4-8a、8b |
| 9 | 見上面「舊碼的身分」 | — | — | — |
| 10 | `table.ORDER` 沒有任何東西消費；註解與 §14.6、§14.7 都明寫，沒發明排程器；測試在有東西開始讀它時會紅 | `cells.test_order_has_no_consumer….OLD_red.log:21` | NEW_green | 無（沒有判定碼） |
| 11 | CH4 的 basis 改引 `hc_main.p4:87-88,249,254-260`、`frames.py:135-138` 與 kernel 的 `SFlowType.hpp:364,369,386,390-391`；CH3 的 basis 原本引「relayed … REPORT.md」，改引 `hc_main.p4:86,240-241`、`SFlowType.hpp:353,369`；兩列標 r4。測試掃 tsv 與 `tools/p4_health`，不許再有私有紀錄的檔名 | `item11.cells.OLD_red.log:19-33` | `item11.cells.NEW_green.log:14-17` | 無（資料檔） |

## 3. 推論的（INFERRED）與要決定的

1. HR 的 2.6e-6 是在「Poisson、每個樣本記入 256×該幀位元組、安靜窗雜訊 0」的假設下算的，沒有 live 量過。
2. HR1 的 5-tuple 要落在 s1-eth4 是 Cut 3 刺激端的事（S0 已經能為兩條上行各找一個）；格的前提只保證選錯時是 NOT RUN。
3. T3、T3-neg 目前沒有 observer（Cut 2 才寫），只備了 `ROUTE_PREFIXES`。
4. `expected_today.tsv` 還有 `GAP-2b` 的引用（C1、R2、P4、TTL1、TP4）。那是 `doc/audit` 底下的 .md，同樣不在公開 main 上；不在本輪範圍，留給決定者。
5. 第 3 輪的 `SUMMARY-cut1.md` 第 64、81 行的「< 1e-5」與 20000 幀，已被本摘要取代。
6. 沒跑 L1 lane 評分模擬（不在本輪 gate 清單）。

## 4. 給設計審查的

DESIGN.md 的 §14.7 與各處標「r4 (Cut 1 follow-ups)」的列：recover 的 `down-done` 重新 claim 與 `released` 例外、HR 的絕對門檻與 24000 幀、HR1 的上行前提、計時編碼的驗證、`route` 進 observer、觀測器契約、`ORDER` 尚無消費者、公開檔案不引私有紀錄。
