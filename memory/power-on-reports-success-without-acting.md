---
name: power-on-reports-success-without-acting
description: P4 的 set_switches_power_state action=on 在關機後約 10 秒內回 200 Success 但什麼都沒做——因為 liveness worker 在死掉的交換機上把 vertex 翻回 up，powerOn 第一行就 return success
metadata: 
  node_type: memory
  type: project
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-31T06:15:59.314Z
---

2026-08-19 phase-2 實測（E2）。**這是「示範時最可能當場發作」的一條**，因為人手動示範「關掉再打開」就是幾秒內完成，正好落在窗口裡。

## 現象

`POST /ndt/set_switches_power_state?ip=...&action=on` 回 **200 `{"Success"}`、0.01 秒、然後什麼都沒做**：
bmv2 行程數停在 9、沒有 relaunch、沒有 readopt、交換機永久死亡。
同時 `power=ON`、`s5_up=True`、8/8 邊 up、**100% 封包遺失**。

## 機制（完全是內部自造的，不是外部失敗）

1. `powerOff` 把 vertex 標 down
2. **約 1 秒後** 1 Hz 的 liveness worker 在一台已經死掉的交換機上把它翻回 up——
   `p4LivenessFor` 對 2 秒內的舊 `probe_ok` 回 Up，之後在 LLDP beacon 還沒超過
   `kLldpFreshSeconds = 12` 前回 Unknown
3. `P4PowerStrategy::powerOn:45-50` 開頭就是：
   ```cpp
   if (topoMonitor->getVertexIsUp(node))
   {
       // Already up: nothing to do, and reporting success is accurate.
       return OpResult::success();
   }
   ```

⚠️ 那句註解「reporting success is accurate」在 vertex 說謊時就不成立。
檔案自己的註解預測過這件事會發生在**重試**上；實際上**第一次呼叫**就會。

## 證明方式值得學（有鑑別力的第二次呼叫）

等 graph 沉澱到 `is_up=false` 之後，送**完全相同**的 POST → 花 **1.27 秒**、行程 9→10、
轉發完全恢復。同一個請求、同一個目標，只有時間點不同 → 排除「請求本身有問題」。

## 繞法（零程式碼成本）

**關機後等 ~15 秒再開機**，或先確認 `get_graph_data` 的 `is_up=false` 再送 on。
示範前務必照這個節奏走。

## 這是 [[rejected-requests-can-still-act]] 的第三面

- 第一面：回 400 但真的做了（`install_flow_entry` 缺 priority）
- 第二面：回 200 queued 但被交換機拒絕（幽靈規則）
- **第三面（本條）：回 200 Success 但完全沒動作**

共同教訓：**API 的狀態碼與世界的狀態是兩個獨立變數，測任何一個都要回頭看另一個。**

相關：[[phase2-round-2026-08-19]]、[[p4-orphan-switches-and-manifest-lifetime]]。

## 🔄 08-30 深夜：08-19「不修、用繞法」的裁定被推翻——修復在途

Adam 在 KNOWN-ISSUES 修繕表單勾選「demo 行為修復」包＝**重裁 A-1 改修**（KNOWN-ISSUES A-1
即本條）。修復 agent（bundle 2、branch `fix-demo-behavior`）已在寫：方向＝powerOn 對真實
行程/bridge 狀態驗證後才宣告成功（「沒報錯的動作不等於發生過的動作」）。⚠️ 量測窗內只寫碼，
build/test/審查/合併在有流量輪窗開之後——**在合併落地前，上面的 15 秒繞法仍然有效、示範仍要照走**。

## 🏁 08-31：修法已落並過閘，但**還沒 RESOLVED**（差一個工作點）

`98e890a`（併入 `9df0a1c`）＝兩問守衛（圖說 up **且** 本策略 15 秒內沒關過它才跳過 helper）；
15 秒＝`kLldpFreshSeconds`(12)＋一個 worker tick，**就是繞法那個數字搬進碼裡**。窗在 helper-on
成功時關（502 路徑要能再跑）。變異閘 A-1 五顆全殺、對照顆 13 輪全綠、46/46。
live：**arm1（sleep 3）PASS**＝2.160 s、行程 9→10、kernel.log 有真的 `switch s1 -> on`；
**arm2（sleep 20）PASS**＝3.046 s（首輪誤判是取樣太早的儀器假象，隔離重跑正名）。
🔴 **arm3（重複 power-on 的 I1/I5）INCONCLUSIVE——量測當下交換機是關的**，而不變式是關於
**開著**的交換機 ⇒ 觀測同時相容於「不變式成立」與「原缺陷仍在」，**零鑑別力**。
⇒ 依 bundle 自訂條款（live 綠前不改 RESOLVED），**本條仍非 RESOLVED**；arm3 與 ping-through
子句排進 F-5 細格輪的 riders。**未帶此修的 build 上，15 秒繞法仍有效。**
⚠️ 原 live 配方三個缺陷已更正（`11_behavior-evidence.md` §5）：port `8081`→**`8000`**（`/ndt/*`
是 kernel 不是 proxy）、參數 `switch_ip`→**`ip`**、以及 `pgrep -c simple_switch_grpc`
**19 字元 vs comm 15 字元上限 ⇒ 在活 fabric 上恆回 0**、baseline 0→after 0 讀成「回到 baseline」
＝**任何行為都 PASS**。用 `ps -eo comm= | grep -c '^simple_switch'`。
