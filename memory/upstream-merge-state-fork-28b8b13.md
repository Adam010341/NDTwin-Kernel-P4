---
name: upstream-merge-state-fork-28b8b13
description: "跟上游 ndtwin-lab/NDTwin-Kernel 的分岔點是 28b8b13；上游只多一個 commit，但它砸在 FlowLinkUsageCollector.cpp 上，實測合併只有那一個檔衝突、10 個 hunk"
metadata:
  node_type: memory
  type: project
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-13T02:31:15.072Z
---

2026-08-12 實測（`git merge-tree` + 臨時 worktree 真的合一遍，已清除，主樹沒動）。

## 地形

```
28b8b13  "Add files via upload" (2026-04-20)   ← 共同祖先，就是 baseline
   ├─ origin/main  8b61cdc "Add sharding" (patty, 2026-08-03)   ← 上游只多這 1 個
   └─ 我們         269 個 commit（含 6 個 merge）
```

- `origin` = `ndtwin-lab/NDTwin-Kernel`（上游）
- `p4` = `Adam010341/NDTwin-Kernel-P4`（Adam 的 fork，**所有工作都在這**）
- `git rev-list --left-right --count origin/main...fix/flow-rate-divide-by-zero` → **1 / 269**

**Adam 以為「上游沒動過」，但上游動過。** patty 8/3 推的 `Add sharding` 改 5 個檔案
（+483/−273），其中 **4 個我們也改過**。

## 實測衝突：只有一個檔

| 檔案 | 我們 | 上游 | 結果 |
|---|---|---|---|
| `src/ndt_core/collection/FlowLinkUsageCollector.cpp` | 854+/213−（29 commit） | 430+/236− | ❌ **10 個衝突 hunk** |
| `include/ndt_core/collection/FlowLinkUsageCollector.hpp` | 157+/11− | 27+/12− | ✅ 自動合 |
| `include/common_types/SFlowType.hpp` | 270+/0− | 1+/0− | ✅ 自動合 |
| `src/utils/Logger.cpp` | 5+/0− | 1+/1− | ✅ 自動合 |

10 個 hunk 約 402 行 / 全檔 3093 行。

## 真正的難處不是解衝突

10 個 hunk 落在我們熟到不能再熟的檔案裡，機械上不難。**難的是沒人讀過 patty 那 666 行
想達成什麼**——「sharding」的語意 diff 看不出來。只顧保住我們這側，等於默默把她的改動吃掉。

**建議順序**：(1) 先讀懂 `8b61cdc` 在做什麼並寫成分析；(2) 跟 patty 確認她是否還在動；
(3) 越早合越好，那個檔兩邊都在長。

**2026-08-13 複查（B1 agent，有真的 `git fetch origin`）**：`origin/main` 仍= `8b61cdc`，
分岔後上游仍只多這 1 個 commit。我方側自此又 +7（修復輪，head `d2a609a`），
`FlowLinkUsageCollector.cpp` 本輪**沒動**，衝突量測應仍有效（未重量）。
**仍未驗證**：上游有沒有 main 以外的分支。

## 2026-08-13 晚：patty 答了三題中的兩題，合併已裁決延後

**Adam 裁決：合併延到報告（2026-09-03）之後。** 理由是風險不對稱——報告完全不依賴合併，
而 hunk #15 解錯會靜默 revert 掉 SIGFPE 守衛，上檔則是沒有上檔。原本三個「該早點合」的理由
逐條被削弱：回推是另一件事、上游三個月才動一次（增長不對稱）、type 5 對我們無用（見下）。

**patty 的回答（Adam 口頭轉述）**：

1. **那些 `// TODO` 停掉的東西「是為了發 paper 的時候把效能衝上去，所以實際上是可以用的」。**
   → 這一題本來就能翻轉合併策略，現在有答案了:**保留我們這邊啟用的版本**，
   「take theirs」會把能跑的 thread 關掉。
2. **sample type 5 是為了 P4 新增的**，她說「p4 switch 只能生成那種格式的 flow sample」。

**第 2 點我查證過它的意思**（讀 `8b61cdc` 的 parser 與我們的 emitter，2026-08-13）：
type 5 **根本不是 sFlow**，是 40 bytes 的扁平定長 struct，裝的是**已解析好的** 5-tuple
（`+8` in/outPort、`+12` samplingRate、`+16` etherType、`+20` frameLength/protocol、
`+24/+28` src/dstIp、`+32` frag、`+34` tcpFlag、`+36/+38` src/dstPort），
沒有原始封包、沒有巢狀 XDR record。意思是 **P4 pipeline 直接吐遙測時做不出完整的 sFlow v5**
（巢狀 XDR ＋ 內嵌 raw Ethernet frame），但吐得出定長 header——那些欄位本來就在 metadata 裡。

⚠️ **我們沒有這個限制，因為架構不同**：bmv2 clone 到 CPU port → proxy 收 packet-in →
**proxy 用 Python 合成真正的 sFlow v5**（`sflow_emitter.py:78` `SAMPLE_TYPE_FLOW = 1`，
含 extended_switch 1001 ＋ raw header record）。她是 switch 直送、我們是 proxy 代送。
**合併影響**：我們的 collector 只認 1/2/3/4，type 5 是純新增的 `else if`，不衝突、低風險；
但它**沒有邊界檢查**（固定 offset 一路讀到 `+38`，不驗 `sampleLen` 也不驗 buffer 長度）——
收進來就用 `tests/fuzz/fuzz_sflow.cpp` 打它。

**第 3 題（`hopsCounter` 閒置歸零的取捨）已不必問**：Adam 與 `8/13 mainDev` 討論後裁決
「作為 bug 是小問題，跳過」。

相關：[[ndtwin-current-state]]、[[push-commits-to-github]]、
[[worktree-agents-branch-from-origin-main]]（同一個 remote 混淆的另一個後果）。
