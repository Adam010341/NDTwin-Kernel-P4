---
name: p4testgen-cannot-reach-clone-path
description: p4testgen 已裝在本機且對我們的 .p4 收斂到 85.2%；剩下的 8 行全是 sFlow clone 取樣路徑，符號執行結構上不可達
metadata: 
  node_type: memory
  type: project
  originSessionId: e3afba73-abd2-47e7-a371-fe86741876c3
  modified: 2026-08-13T02:48:30.747Z
---

`/usr/local/bin/p4testgen` **已經裝好**（隨 p4c 出貨，2026-08-13 實測，clang 18.1.3 也在）。
對 `p4_proxy/p4_src/ndtwin_switch.p4`（482 行）實測：

```bash
p4testgen --target bmv2 --arch v1model --max-tests 0 \
  --track-coverage STATEMENTS --only-covering-tests --print-coverage \
  --test-backend PTF --out-dir /tmp/p4tg ndtwin_switch.p4
```

7 分鐘內收斂到 **85.2%（46/54 nodes），只需 10 個測試**。
⚠️ `--only-covering-tests` 是關鍵旗標：不加它、只取 20 個測試時只有 44.4%。

**未覆蓋的 8 個節點不是隨機分佈**，是連續一整塊：`ndtwin_switch.p4:414–421`，
egress 裡 `BMV2_INSTANCE_TYPE_INGRESS_CLONE` 分支替 clone 出來的取樣封包組裝
`packet_in` 標頭那段（`reason = PKTIN_REASON_SAMPLE`、`sampling_rate = SAMPLE_RATE`）。

**Why**：取樣走 ingress 的 `clone_preserving_field_list(CloneType.I2E, ...)`（:389），
clone 出來的是**另一次 egress 執行**。P4Testgen 的符號執行走單一封包路徑，
不模型化 clone 產生的第二條路徑 —— 所以那個分支對它**原理上永遠不可達**，
不是測試沒寫夠。這給 [[live-runs-find-what-tests-cannot]] 一個機制層級的解釋。

**How to apply**：
- 改 `.p4` 的**取樣區塊**時，P4Testgen 迴歸網接不住，必須手動走 runbook 的流量驗證；
  那 8 行現在的唯一守護者是 live run ＋ `test_SFlowEmitterRoundtrip.cpp` 的跨語言 round-trip。
- 改 `.p4` 的**其他區塊**可以用 `--assert-min-coverage 0.85` 當 CI 閘門，
  零安裝、連 bmv2 都不用起（只吃 `.p4` 檔），適合掛在 L0。
- 要跑產出的 PTF 測試才需要 `pip install ptf scapy`（venv 實測兩者皆無）。

完整脈絡見 `doc/audit/2026-08-13_advanced-testing-research/REPORT.md` §4 R-4。

## 更正：不可達的原因是**分支條件**，不是「有 clone」（2026-08-13，跨程式驗證）

原本的說法「clone 是第二次 egress 執行、符號執行不模型化」方向對但太粗——它暗示任何用 clone
的程式都會有不可達區塊，**那是錯的**。拿 p4lang/tutorials 當對照組實測：

| 程式 | clone？ | egress 分支條件 | 覆蓋 |
|---|---|---|---|
| `basic.p4` | 無 | — | 100%（3/3） |
| `flowcache/solution` | **有** | `egress_port == CPU_PORT` | **100%**（35/35，連 clone 呼叫本身都覆蓋到） |
| `ndtwin_switch.p4` | 有 | `instance_type == BMV2_INSTANCE_TYPE_INGRESS_CLONE`（:406） | 85.2% |

真正的原因：求解器能自由選 `egress_port` 這種一般 metadata，但不會去模型化
「clone 產生了第二個封包、而它的 `instance_type` 被 bmv2 設成 1」。

**我們不能改用 flowcache 的寫法換覆蓋率**：我們的取樣 clone 與主動 `send_to_cpu` 的封包
egress_port 都是 CPU_PORT，`instance_type` 是唯一能區分的依據。已記為有意識的取捨。

**已做成閘門**：`tools/test_workflow/p4_coverage_gate.sh`——盯未覆蓋清單的**形狀**而非只看數字，
清單變長＝新增了自動測試永遠碰不到的程式碼，會擋下來要求 `--update-baseline`。
只在 `.p4` 的 hash 變動時真跑（否則 14ms），所以掛在 `local_ci.sh` 裡不會拖慢。
