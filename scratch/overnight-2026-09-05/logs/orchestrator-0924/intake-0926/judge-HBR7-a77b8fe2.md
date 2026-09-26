# 第七輪裁決（`fix/hb-spike-r7-0926`，`4bc1201b` → `a77b8fe2`，2 檔 +633 −26）

（fable-judge 同一位判官的限定複審最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿，此處保留裁定、要點與 findings 原文。）

一句話：**r7 對 09-26 首次 live 的 teardown 修法是對的、完整的、fail-closed，且對真 `ndt` 忠實**——`retract_measuring` 走的正是 ndt 自己在拒絕訊息裡指的路（`ndt claim <mins>` 重宣告、不用 `--force`），`spike_release` 只在 down 答 0／3 後放手，其餘一律留 claim、印指令；12 個新 oldcode 列每列都紅在自己的檢查上。**但 PART=all 的 live run 會絆在一個本輪之外、self-test 看不見的舊 bug 上：spike 的 `CLAIM_MINUTES=180` 預設是死碼，實際 lease 是 `_common.sh` 的 45 分鐘（live log 已證實 `for 45m`），而 detect＋26 臂的 census 依檔頭自己的估算要 56-82 分鐘 ⇒ claim 會在 census 中途過期。** 一行修好。**合併裁決：MERGE AFTER FIXES**（finding 1 blocking，其餘 note）。r7 的 teardown 碼本身不需要改。

要點：(1) `retract_measuring` → `reclaim` → 真 `cmd_claim`（ndt:748-772，無 in_flight 檢查、無 lease 上限）→ `claim_take`（:774-863，`measuring=` 取自該命令環境 :824-826，重錄 baseline :849）；之後 `measuring_declared`（:956-961）為空 ⇒ T2d guard（:4984-4993）不再拒。`ndt claim` 會拒的情況（外人活 claim、lock 逾 10 s、readback 被蓋）都走到 fail-closed。假 ndt 在情境依賴的每一點都對得上真碼。(2) 沒有任何路徑會在 down 非 0／3 後 release；但 census 臂 down 被拒後 `continue`，下一臂 `ndt up p4 --app` 對完好同尺寸 fabric 只「already up … reusing」（up_p4 :3293-3311，不比 package）⇒ 之後的列可能量錯 pipeline。(3) knob 復原後再 re-claim 兩分支都安全。(4) trap 內沒有裸 `return`。(5) 12 個新 oldcode 列全部有效。(6) 修好 finding 1 後 PART=all 可以 live。

## Findings
1. **[blocking]** `CLAIM_MINUTES` 的 180 預設是死碼：`source "$LIVE_P1/_common.sh"`（spike :104）先執行 `_common.sh:37` 的 `: "${CLAIM_MINUTES:=45}"`，spike :127 的 `: "${CLAIM_MINUTES:=180}"` 永遠不生效；live log :39「for 45m」證實。`claim_minutes` 只保留剩餘、不延長 ⇒ census 中途過期。self-test 看不見（driver 自己寫 `CLAIM_MINUTES=180`）。修法：把 `: "${CLAIM_MINUTES:=180}"` 移到 :104 之前，並加 source-read 檢查（sourcing 後必須是 180，反向 red-first）。臨時止血：啟動時明給 `CLAIM_MINUTES=180`——但碼要修。
2. **[note，強烈建議段 S 前做]** census 臂的 down 非 0／3 之後不該再建下一臂（:600、:647-648 之後 `continue`）；一行 `return`（或旗標讓後續臂記 `skipped`）；假 ndt 加 `up` 回 `already up` 的情境即可 red-first。
3. **[note]** `keep_claim` 的 rc 1 分支未被情境覆蓋（假 ndt 加 `verify-fails` 旗標）。
4. **[note]** claim 過期／被外人接手的 teardown 未被情境覆蓋（`reclaim` 失敗 → down 5 → 「under THEIR claim now」分支；過期無人接手時 down 過、release 前 re-claim 成功）。
5. **[note]** 假 ndt 的 `up` 從不拒絕、`down` 沒有「另一個 down 在跑」的 5（無情境依賴）。
6. **[note]** 兩份 rerun 裁決時未收尾（orchestrator 其後確認：oldcode rc 0；selfcheck 見 rerun log）。
7. **[note]** 既有未修：`spike_finish :349` 的訊息名不到介面；r5 finding 6／7 仍開。
