---
name: grpc-global-subchannel-pool-inherits-backoff
description: grpc-python 預設用 process 全域 subchannel pool，全新的 channel 會繼承同位址舊 channel 累積的重連 backoff；而且不認得的 channel option 會被安靜忽略
metadata:
  node_type: memory
  type: reference
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-27T13:57:29.371Z
---

2026-08-12，Phase 7 powerOn「關越久越開不回來」的真兇。

**事實一：subchannel pool 是 process 全域的，以目標位址為 key。** 所以
`grpc.insecure_channel(addr)` 建出來的**全新** channel，會拿到前一個 channel 留在那個位址上的
subchannel——**連同它累積的重連 backoff**（預設 initial 1s、乘 1.6、上限 120s）。

受控實測（grpc 1.82.1，對關閉的 port 猛連 90 秒後啟動真的 server，量新 channel 到 READY，
同位址同 process 同時刻）：

| channel | time to READY |
|---|---|
| `options=[("grpc.use_local_subchannel_pool", 1)]` | **0.00s** |
| 沒帶 option | **32.56s** |

在這個 repo 的形狀：bmv2 關掉之後 liveness prober **每 2 秒**探它一次，關 4 分鐘 ≈ 120 次失敗
把 backoff 推向上限；readopt 現建的全新 client 直接繼承，於是對一個**明明在聽、手動 TCP 連得上**
的 port 回 `UNAVAILABLE ... Connection refused`。修法是 `grpc.use_local_subchannel_pool=1`
（`949fcba`）。這裡零代價——每台 switch 各有位址，正常只有一個活 client，唯一發生過的共用
就是「死掉的 client 和它的替代品」。

**事實二（更陰險）：gRPC 會安靜忽略它不認得的 channel option。** 名稱打錯 → 不報錯、不警告、
option 就是沒生效。所以測試要**釘死字面字串**，而且要跑「名稱打錯」這個 mutant。
驗證名稱真實存在的方法：`strings` 掃 grpc 的 C-core，看得到 `grpc.use_local_subchannel_pool`
就在 `local_subchannel_pool.cc` 旁邊。

**衍生教訓：關機不是中性動作。** 「off 再 on」當復原步驟看起來很自然，實際上是**替 backoff 加碼**；
真正有效的是等它衰減（直接重打 readopt）。文件寫的復原步驟沒實跑過就是沒驗證過——
見 [[live-runs-find-what-tests-cannot]]。

相關：[[prove-the-writer-by-cadence]]（這條也是用受控實驗證的，不是讀程式碼）、
[[p4-orphan-switches-and-manifest-lifetime]]；Phase 7 的設計與 live 驗收全文在
`doc/2026-08-11_phase7_power_mechanism_design.md`。
