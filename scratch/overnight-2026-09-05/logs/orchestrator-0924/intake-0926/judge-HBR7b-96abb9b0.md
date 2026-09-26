# 第 7b 輪裁決（`fix/hb-spike-r7-0926`，`a77b8fe2` → `96abb9b0`，2 檔 +314 −13）

（fable-judge 同一位判官的限定複審最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿。orchestrator 附註：判官當時未見的
oldcode／selfcheck rerun 其後皆 rc 0——oldcode 31 列全 ok，selfcheck 10/10。）

一句話：**r7 的兩個修法都落在 live 路徑上、都對；「讀回每個預設」的自測方法正確且 fail-closed；七個舊列新增的期望行全是新情境對舊形的合理後果（`20870ce0` 的 13 條 PROBLEM 全是「未列名的紅」，沒有一條「該紅沒紅」），不是掩蓋回歸。合併裁決：MERGE。** 在 `NDT_OWNER=orch-0926` 明給、`CLAIM_MINUTES` 不另設（現在有效預設 180）的前提下，**PART=all 可以 live**；findings 全是 note。建議第一次 PART=all 不要設 `CENSUS_EVEN_IF_RED`。

## Findings（全部 note）
1. `NDT_OWNER` 未給時會以 `live-p1` 取 claim（`_common.sh:35`）；spike 在 source 之前加一行拒跑即可；本次 live 已明給。
2. rc 3 在五站點的記帳不一致（no-link 與量測臂對 3 記 fail，hb-fails 與 no-pid 站點不記）；續行決定一致。
3. STOP＋被拒的 down：STOP 分支的 `return` 先於 `census_skip_rest` ⇒ 其餘臂沒有 `skipped` 列（純表格完整性）。
4. 讀回檢查只涵蓋 `: "${VAR:=…}"` 形；`_common.sh` 自己的預設不在視野。
5. census 的 live 未知未變：sniffer 的 mnexec 授權（INFERRED）、每臂建置時間、`CENSUS_EVEN_IF_RED` 的 reuse 情況。
6. oldcode／selfcheck rerun 當時未見（其後 rc 0）。
