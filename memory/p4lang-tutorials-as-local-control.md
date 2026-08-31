---
name: p4lang-tutorials-as-local-control
description: "p4lang/tutorials 已 clone 在 ~/tutorials；它的價值是當對照組與第三方 client，不是當測試案例"
metadata:
  type: reference
---

`~/tutorials`（p4lang/tutorials，12+ exercises）。2026-08-13 實際用過，價值排序：

1. **覆蓋率的對照組（已用，有結論）**：拿它的 `.p4` 跑我們的 `p4_coverage_gate.sh`，
   證明了「不可達的原因不是有 clone，而是分支條件讀 `instance_type`」——
   `basic.p4`（無 clone）100%、`flowcache/solution`（**有 clone**）也 100%，
   因為它的 egress 條件讀 `egress_port`（求解器可自由選）。我們讀 `instance_type`
   （只有 clone 真的發生才會設）所以 85.2%。**這推翻了我們原本較粗的說法**，
   已改寫進 `doc/2026-07-27_p4_bmv2_support_plan.md`。
2. **第三方 P4Runtime client**（`utils/p4runtime_lib/`）：要回報 bmv2 缺陷時，
   用它重現可排除「是我們的 client 的問題」。⚠️ **2026-08-13 試過會卡住**：
   它的 `MasterArbitrationUpdate()` 等回應，而 bmv2 對重複 election id 是直接殺 stream
   → 永遠等不到。要繞過它的 stream 封裝手寫低階 gRPC。
   另注意它需要 `p4.tmp`，我們的 venv 沒有——用 `/home/adam/p4dev-python-venv/bin/python`。
3. **工具鏈的已知良好對照**：bmv2/p4c 出問題時，`basic.p4` 能一分鐘分辨是我們的程式壞了
   還是工具鏈壞了。
4. exercise 的 `.p4` 是**未填空的骨架**（編不過），完整版在各自的 `solution/`。

**不建議**：拿 exercise 的拓撲測 twin——2–4 台的教學拓撲、與我們的 topology JSON 不相容，
而 twin 測的是 kernel 的狀態邏輯，跟 P4 程式本身關係不大。

相關：[[p4testgen-cannot-reach-clone-path]]、[[bmv2-scale-ceiling-and-sflow-sample-math]]。
