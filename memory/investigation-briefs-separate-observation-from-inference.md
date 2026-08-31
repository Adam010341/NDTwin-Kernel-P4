---
name: investigation-briefs-separate-observation-from-inference
description: "When dispatching an investigation, put only raw observations under \"facts\" — my interpretation of them belongs in a separate, clearly-labelled section, or investigators inherit my error"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b955baee-a646-4fe6-9986-df69b65478e6
  modified: 2026-08-30T14:51:49.229Z
---

On 2026-08-10 I dispatched two independent investigations (Opus 5 via the Explore agent, DeepSeek
via `deepseek-agent`) into why breaking one bmv2 interface killed traffic that "never touches"
the affected switch. I wrote the brief myself and put this under a heading called **"Facts (all
measured today)"**:

> `h1 -> h2 : s1 -> s6 -> s2  (does NOT pass through s5)`

That was not a measured fact. It was my **inference from a one-directional reading** of
`all_destination_paths`. The reverse path `h2 -> h1` is `2 -> 5 -> 1` and goes straight through s5.
Ping needs both directions, so the "control group" I had built the whole conclusion on was never a
control at all.

**Opus 5 caught it** by independently resolving s2's port 1 against `p4_testbed_topo.py` and the
live rule. **DeepSeek did not** — it took the labelled "fact" at face value and spent its entire
run constructing an elaborate cross-switch propagation theory to explain something that had never
happened, ending at "cannot be determined from static analysis". Its reasoning was sound; its
premise was mine and it was wrong.

I *had* written "do not assume the conclusion in doc §6h is correct" — but the false premise was
not in the conclusion, it was in the evidence section, where nothing invited doubt.

**Why:** an investigator can only question what is marked as questionable. Anything under "facts"
is load-bearing and will be built on. This is the same failure as [[deepseek-cli-for-grunt-work]]'s
"its mistakes are almost always my prompt", one level up: not missing context this time, but
*contaminated* context.

**How to apply:** in any investigation brief, keep three sections apart —
1. **Raw observations**: the literal command and its literal output. `curl ... returned N paths`,
   not `h1->h2 does not pass through s5`.
2. **My interpretation**: explicitly labelled as mine and as unverified.
3. **What I want checked**: including, by name, the premises in section 2.

And when a derived claim is load-bearing, state how it was derived so the investigator can redo it.
Dispatching more than one investigator is what saved this; they disagreed, and the disagreement was
the signal. Related: [[live-runs-find-what-tests-cannot]], [[cited-line-numbers-are-not-evidence]].

## 🔴 08-29：同一形狀，但這次污染的是**我自己寫進正式文件的欄位**

修 `KNOWN-ISSUES.md` §D 的 F-17 那格時，我在「理由」欄寫下：

> 前提被否證不等於結論被否證（**修法成本、報告前凍結產品碼**等其他理由未經檢驗）

**那兩個理由是我猜的。** 後來查證：F-17 那列**從頭到尾只有一條書面理由**（「失效方向保守」），
而「報告前凍結產品碼」寫在**別的一列**（A-1/A-2/A-3）。

⇒ 差別很大：我的寫法讀起來像「還有其他理由撐著，所以先別急」，
**事實是「唯一的書面依據已經沒了」**。**我的推測讓一個已經站不住的裁定看起來還站得住。**

🔑 **這次沒有第二個調查員來反駁我** —— 上面那次是靠兩個 investigator 意見不合才抓到的。
這次是**我自己兩小時後回頭查證才發現**。⇒ **「派兩個人」不是唯一的防線，
「凡是我沒查過的原因，一律寫成問句而不是清單」才是能單人執行的那條。**

📌 具體改法：寫「其他理由未經檢驗」時，**要嘛列出查到的、要嘛寫「我沒有查其他理由」**，
**不要舉例**。舉例會讓讀者以為那是清單的樣本，而不是我的想像。

## 🔴 08-29 鏡像面：上游送來的**更正**也會夾帶已被推翻的東西

同一天，`8/29 auditor` 送來一條更正，說我把兩個 0.0 判成「不同機制」是錯的——**那半完全正確**，
我確實漏看了兩個 clause 累加同一個計數器。**但它接著寫的後果**
（「同一個 0.0 餵給 Energy-App 會把交換機關掉」）**把我們前一輪剛查證推翻的接線又接了回來**。

⇒ **收到更正時要逐句分開判，不能因為前半經得起查就整條照收。**
若我照單全收，那三份 runbook 會變成同一個錯誤前提的第八到第十個引用點——
**更正動作本身會製造新的引用點**，這是撤回工作特有的風險
（見 [[disclosure-is-not-downgrading]] 的「引用點五種」，這一輪實際數到七）。

## 🆕 08-30：適用域擴到**派工單與跨 session 轉發**——hedge 要跟著主張過每一跳

同一晚兩例、同一形狀的兩半（mainDev 指認）：
① 我對 Adam 標「機制推測（待驗）」的 FINDING-07 假說，**轉發進派工單時變成直述句**
（「API 收了一個 exact-match 表結構上編不進去的 priority 欄」）——.p4 一讀就推翻。
② 「ndtwin-lab 拒絕 KERNEL_DIR」在轉述中被讀成待驗前提——前提其實**成立**（root wrapper
`tools/test_workflow/ndtwin-lab:26-51` 寫死＋大寫註解），但派工單沒帶出處與位置，
收件人查了另一個檔（components.env `:=` 接受 override）得到相反結論、正確地拒寫。
**兩次都是收件人把前提當前提查才沒出事。**
⇒ **規約（08-30 起）**：派工單裡的每個機制宣稱標三態之一——「**親驗**（附 file:line）／
**記憶**（附記憶檔名，收件人自驗）／**推測**（待驗）」。與 903 模板警告 3
「限定詞跟著數字走」同一條規則，適用域＝所有跨 session 文字。
