---
name: existence-is-not-wiring
description: "Twice in two days I called a feature done because the code existed. Grep for the call site, not the definition — and a call site in source is still not a call reached at run time"
metadata:
  node_type: feedback
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-29T05:33:28.682Z
---

Two instances, two days, same root error — **taking the existence of code as evidence that it runs.**

1. **Phase 6's link-failure notification.** I marked it complete because `KernelNotifier` defines `link_failure()` and `link_recovery()` and `test_kernel_notifier.py` exercises both. Nothing in the proxy ever calls either. `_last_lldp_from` is updated on each beacon and reported as `last_lldp_age_s`, but never compared against a timeout to declare a link down. The feature does not exist; only its client does.
2. **`/ndt/disable_switch`.** Two places in the contract tooling said Energy-Saving-App's call 404s at run time and the app swallows it. The call is genuinely in the source at `src/app/http.cpp:269` and the kernel genuinely never registered the endpoint — but that function has **zero call sites**, and the live path uses `/ndt/set_switches_power_state`. "Energy saving has never switched a switch off" did not follow.

3. **Tests can have the same hole, and mutation is what exposes it.** I added `push_destination_paths` and called it from the watchdog loop. Every one of the 48 tests invoked the method *directly*, so deleting the call from the loop left the whole suite green. Fixed by extracting `run_watchdog_pass` — the loop body as a callable seam, leaving the thread with nothing but its wait — and asserting through that. Anything whose only home is inside a `while` loop with a multi-second sleep is untested by default.

Note these are the same error at three strengths, which is why the earlier ones did not inoculate me: (1) a *definition* is not a *call site*; (2) a *call site* is not a *call reached at run time*; (3) a *tested unit* is not a *tested wiring*.

**Why:** both feel verified. In (1) there was even a passing test — of the client, which proves the client works and says nothing about whether anything invokes it. A green test on a component is easily mistaken for a green feature.

**How to apply:** when claiming a feature works, grep for the **call site**, excluding tests:
`grep -rE "\.method_name\(" <src> --include=*.py | grep -v /tests/`. If the only hits are the definition and its own unit test, the feature is not wired up. For the stronger claim that it *runs*, you need a call-graph check or a live observation — static grep is a superset of what executes. And when a status table says an item is done, verify before repeating it: doing that on this project's phase table found three wrong cells in two days. Related: [[mutation-gate-for-tests]] — same principle, one level down: a test existing is not a test that can fail.

🆕 **08-25 新實例（sFlow datagram merge）**：`p4_proxy/proxy_agent/sflow_emitter.py` 的
`build_datagram()` 從第一版就支援多 sample、**而且有一個三-sample 的測試在跑**，但唯一的
production 呼叫者 `emit()`（`:302`）永遠傳 `[sample]`。**能力存在＋測試存在＋零 production 使用者**，
而且 docstring 明寫「kernel 兩種都吃」＝當初就決定不接。工單見 [[sflow-truncate-merge-status]]。

---

## 🪞 08-27 的鏡像面：**看寫入點不等於看到約束**

本條講「grep 到呼叫點不等於它有定義／有被接上」。08-27 的容量夾制給出**相反方向**的同一個錯誤：

`TopologyAndFlowMonitor.cpp:1057` 的
```cpp
edgeProps.linkBandwidthUsage = interfaceSpeed - leftOut;
```
**看起來完全乾淨、沒有任何夾制**。但 `leftOut` 是**傳入參數**，而真正的夾制在
**呼叫者** `FlowLinkUsageCollector.cpp:1162-1163`：
```cpp
leftIn  = (avgIn  > interfaceSpeed) ? 0 : (interfaceSpeed - avgIn);
leftOut = (avgOut > interfaceSpeed) ? 0 : (interfaceSpeed - avgOut);
```

🔑 **約束可以住在呼叫鏈的任何一層，而 grep 寫入點只看得到最後一層。**
⇒ 先前的共識是「flow-sample 路徑會夾、計數器路徑不夾」——**錯的**，
追到參數來源之後是**四個寫入點全夾**（含計數器路徑的**反向**，`:1162`）。

**驗收問句**：**「這個值是在這裡算出來的，還是傳進來的？」**
傳進來的就還沒追完。

---

## 🆕 08-28：**這個錯誤已經被寫進我們自己的 docstring,並且拿來當改動的理由**

`include/ndt_core/http/HttpSession.hpp` 的 docblock 寫平均鏈路使用率：

> 「This figure is what Energy-Saving-App reads, so a header that teaches the superseded
> predicate is a header that misdescribes the input to **another component's decisions**.」

查證：ESA 確實有 `get_average_link_usage()`（`src/app/http.cpp:393`，宣告在 `include/app/http.hpp:34`），
**而全 repo 零呼叫端**——扣掉宣告、定義與它自己的一行 log，grep `get_average_link_usage` /
`getAverageLinkUsage` / `avg_link_usage` 命中為零。

⇒ **本條的第 (1) 級（定義 ≠ 呼叫點）不只發生在我判斷功能完成的時候，
也發生在「我為一個改動寫理由」的時候**——而理由比結論活得久，還會被下游引用。

🔑 **判準要跟著改動走**：宣稱「X 消費者讀這個欄位」時，
**要指到那個讀取點的呼叫端**，不是指到讀取的那一行。
「有一個會讀它的函式」和「有東西在讀它」中間差一個 [[no-in-repo-callers-is-not-dead-code]]。
（那條的但書在這裡也成立：這是 ESA 內部的 C++ 函式、不是 REST 端點，
所以「repo 外有人呼叫」的可能性遠低於端點的情形。）

實例出處：[[baseline-drift-audit-2026-08-28]]。

## 🔴 08-29：**同一件事我又獨立查了一次 —— 因為文件與記憶從沒對過帳**

08-29 我照派工修 `KNOWN-ISSUES.md` 的 F-17，整條改動建立在
「端點回 0.0 → `LOW_WATER_MARK` → Energy-App 關機」上。**commit 之後**，post-commit hook 的
agy 複審回了一個 HIGH 說那條接線不存在；我自己重查消費端 repo，**結論與 08-28 這一節逐字相同**。

🔑 **重點不是我查對了，是這件事 08-28 就已經有結論、寫在記憶裡，而我沒用上。**

| 載體 | 08-29 當下說什麼 |
|---|---|
| 記憶（本檔＋[[baseline-drift-audit-2026-08-28]]） | ✅ 零呼叫端，「ESA reads this」不成立 |
| `KNOWN-ISSUES.md` F-17 列 | 🔴 「**這是 Energy-App 關機決策的輸入**」 |
| `KNOWN-ISSUES.md` A-4b 註記（`:168`） | ✅ 「兩者是不同的函式」——**同一份檔案自己打自己** |
| `HttpSession.hpp:592`／`TopologyAndFlowMonitor.cpp:2767` | 🔴 仍寫著 ESA reads this |

⇒ **兩條可操作的**：
1. **記憶不是只拿來跟 repo 對帳的，記憶之間、記憶與文件之間也要對。**
   我讀了 `:168`（正確的那半）還是沒接起來，因為我在「執行派工」不是在「重建事實」。
   **接到一份指定前提的派工時，先問「這個前提在別處有沒有相反的記載」。**
2. **一份文件內部互相矛盾時，不會有人發現** —— `:168` 與 F-17 列並存了至少十一天。
   矛盾不在同一頁上就等於不存在。**grep 的是關鍵詞，不是命題。**

📌 副產品：**這次是 hook 的自動複審抓到的，不是人**。而它的行號全錯（引 `:74/:84/:100`，
真實位置 `:515/:597`）⇒ [[cited-line-numbers-are-not-evidence]] 照舊成立，
**但「行號錯」不等於「宣稱錯」**——實質要自己查，兩件事分開判。

---

## 🆕 2026-08-31（同一天第三次）：**一個寫者、零個讀者**——而它是為了修一個缺陷才被加上的

F-5 輪的還原保護：中止路徑不還原 ⇒ 補了 EXIT trap，寫一個
`raw/LAB-NOT-RESTORED` marker，設計說「中途不致命，**帶著 marker 交出 lab 才致命**」。

我只查了一件事：**誰讀那個 marker？**

```
/usr/local/sbin/ndtwin-lab   LAB-NOT-RESTORED → 0
全 repo（排除 worktree）      → 只有三行「寫」＋ 一行 PREREG 描述意圖
```

⇒ **那個「致命的」情況在碼裡不存在。** 中途不致命（照設計），release 時也不致命
（因為沒人看）⇒ 整個保護＝**往磁碟寫一個沒有程式會打開的檔案**。

🔴 **而它比它取代的東西弱**：原本至少 `restore` 是人做得到的動作；
現在多了一個沒人讀的檔案，**反而看起來像加了保護**。

🔑 **判準（一句話就查得完）**：任何「落 marker／設旗標／寫狀態檔」的保護，
**先 grep 讀者，再看寫者**。寫者一定寫得很漂亮（有時戳、有 `>&2`、有 `mkdir -p`），
**讀者不存在時完全不會發出聲音**。

### 配套缺陷：文件寫的補救方式，碼上做不到
同一份設計說「`run_f5.sh restore` 是清 marker 的方式」，但 `rm -f "$marker"`
**只存在於 trap 內部**，而 `restore` 子指令沒掛 trap ⇒ 修好之後 marker 永遠留著。
⇒ 就算補上讀者，也會變成**永遠變不回綠的警告**，而那種警告會被學會忽略
（見 [[failures-that-report-success]] 的 08-30 鏡像面）。

### 修法的通則：**把檢查放在受害者那一側**
要保護的是「下一輪」⇒ 讓**下一輪的 preflight** 拒絕在 marker 存在時開跑。
比「要求污染源記得宣告」可靠，而且不必動全機共用的工具（動它要資源主人裁）。
