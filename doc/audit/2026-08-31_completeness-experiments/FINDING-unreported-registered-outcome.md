# 🔴 一條預註冊的結局從未被回報——而註冊原文寫死「兩個都要照結果回報」

**發現者**＝A6 prereg-ledger agent；**我方逐字複驗**（08-31）。agent 的節號記法有出入
（它寫 §7.4.1／§7.4.2），**但內容完全正確**。

## 註冊原文（`doc/audit/2026-08-28_packet-size-sweep/PREREG.md:174-188`）

> Both are **secondary observations**. Neither may adjust any interval, threshold or prediction
> in §4, and **both are reported whichever way they come out**.
>
> 1. **③'s n=1 against 08-15's fast-side figure.** ③ measured n=1 clean to **≥240 Mbit/flow** …
>    08-15 puts bmv2-fast's UDP zero-loss point at **300 Mbps**, also 3 hops. **Agreement to
>    better than a factor of 1.5 ⇒ the fast side is reproducible.**
>    🔑 **Consequence for ①** … if ① lands in H2 (R < 9), **the stock-side 25 Mbps is the more
>    likely suspect, not the fast side.** This does not change any of ①'s registered intervals.
> 2. **②'s 1024 B point against ③'s n=1.** …

## 回報狀況：一報一漏

| 項 | 回報了嗎 | 憑據 |
|---|---|---|
| 第 2 項（1024 B 對 ③ n=1，第四個點） | ✅ **有** | `FINDINGS.md:55-57`，明寫「registered in AMENDMENT-1 §7.4.2 *before* this round」、**ratio 1.12** |
| **第 1 項（fast 側是否可重現）** | 🔴 **沒有** | 字串 `fast side is reproducible` 在**全 `doc/` 樹只命中 PREREG.md:181 一次**；②FINDINGS、study、poster-package 全零命中 |

## 判準已達成，而且結論對我們有利——這正是它更該被報的理由

- 240（③ arm b 下界）對 300（08-15）＝ **1.25×**，**優於註冊的 1.5× 門檻** ⇒ 依註冊語義
  **「fast 側可重現」成立**。
- ① **確實落在 H2**（R=8.0 < 9；母版原文 "By the preregistered rule (R<9), part of the
  production-path ratio is not the compiler flags"）。
- ⇒ **註冊的下游後果因此觸發**：三跳 12× 與單跳 8.0× 的落差，**可疑的是 stock 側那個
  25 Mbps，不是 fast 側**——因為 fast 側的分子已被獨立重現。

🔑 **方向很重要**：漏報的這一條**會讓論文更強**（它把「差額去哪了」從全然未知收窄到
一個端點）。所以這**不是**自利的隱瞞——但正因如此，它證明了預註冊的價值不靠動機，
靠制度：**該報的就得報，不管報出來對誰有利。**

⚠️ **不與母版現有的克制衝突**：母版說 path length vs live control plane「兩個變數都不歸因」
——那是**變數軸**；本條講的是**pilot 比值的哪一個端點不可靠**，是正交的觀察，
且註冊明寫「does not change any of ①'s registered intervals」。

## 建議（裁決權在 auditor／Adam）

1. **補報**：在 ② 的 FINDINGS 追加一節（不改原文），照結果寫「第 1 項達成 1.25×、判準
   1.5× ⇒ 成立」，並記明**補報日期與漏報事實**（不是靜靜補上）。
2. **母版**：擴寫時把這條放進 ① 的討論——它是預註冊的、不是事後想到的，**這一點要寫出來**。
3. **同族掃描**：另兩條「書面上從未裁決」的（③ 的 H3、OvS 的 H-C）一併查——
   agent 已列出兩種讀法、未選邊。

## 這是今天 A 軌的第三個自我發現

`1,500×` 缺算式／package 的 `10_` 停在更正前／**本條**。三個都不是外人指出來的，
是**把材料逐格攤開重排**時掉出來的 ⇒ [[verify-against-known-good-output]] 的
「抄錄一遍是找 provenance 洞最便宜的方法」再獲一例。

[Co-developed with claude code -- Adam]
