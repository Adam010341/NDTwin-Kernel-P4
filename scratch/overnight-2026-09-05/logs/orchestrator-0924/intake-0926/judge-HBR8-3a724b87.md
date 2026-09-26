# 第八輪裁決（`fix/hb-spike-r8-0926`，`580767a8` → `3a724b87`，3 檔 +1532 −66）

（fable-judge 同一位判官的限定複審最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿。orchestrator 附註：判官當時未見的
oldcode／selfcheck rerun 其後皆 rc 0——oldcode 40 列＋control 全 ok，selfcheck 10/10。）

一句話：**去相位鎖的做法在 live 路徑上是對的**——random 是「任意固定相位＋U[0,P) 偏移 mod P」所以均勻，sweep 錨在報告的 `last_heard_mono`（不看排程），φ 每 cycle 用 `t0 − cut_lh_mono` 實量並附 CLOCK_MONOTONIC 絕對值；報告層級 `up_rpt_s` 對得上 helper 的寫檔規則（`REPORT_MIN_INTERVAL_S = 0.5`，live 首份報告 written − last_heard = 0.50058 s）；兩個對照能紅、不會留 netem；覆蓋門檻的機率算對；模擬 daemon 對 `run_daemon` 的寫檔時序忠實、`HB_WATCH_SIM` 在 claim 前就被拒；9 個 oldcode 列各紅在自己的檢查上；r7／7b 的 teardown 碼一行未動、情境以 CONTROLS=1 全綠。**合併裁決：MERGE。** 依提議順序 live（sweep×10，再 random×20，`NDT_OWNER` 明給）**可以跑**；findings 全是 note。

## Findings（全部 note）
1. sweep 的 `SWEEP_WORST_MAX_S=0.25` 在忙碌機器上可能給出誠實的 FAIL（`the sweep never cut within 0.25 s of a heard frame`）；看 `cut_tc_a_s`／`cut_tc_b_s` 判斷是 tc 慢還是機器忙。
2. random n=10 的合計誤報 ≈ 0.5%（cut、restore 各 0.26%）；n=20 可忽略；seed 有記錄可重跑。
3. sweep「每個 cut 落在計畫偏移」是模擬專屬的 5 ms 斷言；live 會有 0.02–0.06 s 系統性偏差（只印、不 FAIL）。
4. 對照 (b) 的方向語意（egress netem 不擋進入 s1-eth3 的幀）是本輪 INFERRED 的核心；若 live BAD，先當 fabric／daemon 的發現處理。
5. `period-check` 讀一次報告、不重試（風險低）。
6. SUMMARY 逐檔行數增量與 diff 的 +1532 −66 對不上，以 `git diff --stat` 為準。
7. 既有未修：`NDT_OWNER` 未給時以 `live-p1` claim；`spike_finish` 空清單訊息；`CENSUS_EVEN_IF_RED=1` 的 reuse；census 期間無 `measuring=`。
8. oldcode／selfcheck rerun 當時未見（其後 rc 0）。
