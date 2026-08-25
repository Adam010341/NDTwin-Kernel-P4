# 環的修法驗證 — 兩條邊都切過了，兩次都沒破環

[Co-developed with claude code -- Adam]

**結論：`d1d973d` 和 `72fbae6` 都已對真靶驗證過，兩個都不能防止環。§5-P 的「理論上切任一條邊
環就無法閉合」被實測推翻。這是負面結果，但它是硬的。**

## 這輪為什麼終於做得成

§5-P 從一開始就要這一輪，但缺陷連續 24 小時召不出來（session 0 前 50 次開機零個環）。
`2026-08-25_host-learning-curve` 在 uptime ~18h 時 quiet 臂 wedge 4/4，靶回來了。

## 結果（4 對 8 次交錯，quiet-only，router 凍結在 `d19020b1`）

| # | defaults | async（`ASYNC=1`） |
|---|---|---|
| 1 | **RING-WEDGE** 411s | HEALTHY 58s |
| 2 | HEALTHY 60s | HEALTHY 56s |
| 3 | HEALTHY 58s | **RING-WEDGE** 411s |
| 4 | HEALTHY 58s | **RING-WEDGE** 411s |
| | **1 / 4 wedge** | **2 / 4 wedge** |

三次 wedge 的簽名一致：`411s`、`hosts=-1`（端點死掉）、`graph=288 / 288 down`（全部邊 down，
不是 settle 迴歸的 256）、`entered` 截斷在 2–3/10 而 `statechange` 維持 10/10。

**跑前跑後 router sha 都是 `d19020b1a1dcf932`**——這輪沒有重演「跑到一半改受測物」。

## 🔑 這輪的邏輯是不對稱的，這是它還能有結論的原因

比數被污染了：基線在 18.0h 是 **4/4** wedge，這輪 defaults 只有 **1/4**。靶在跑的中途衰退。
按檔頭**事前寫死**的第三條規則，這代表**乾淨的 boot 一律不可歸因**——async 那兩次乾淨
**不能**算 `72fbae6` 的功勞，因為 defaults 自己也乾淨。

**但反例那一側不受影響：**

> 如果 `72fbae6` 能防止環，那麼在旗標生效的情況下就**不可能** wedge。

`async_p3` 和 `async_p4` **都 wedge 了，而且兩次的 `banner=1` 都斷言通過**（旗標確實進到 Ryu，
不是那種「量到基線還以為修法無效」的失敗）。**兩個獨立反例，與基礎率無關。**

⇒ **「async 有效」測不出來（靶爛了）；「async 無效」已證實。**

⚠️ **不要把 2/4 vs 1/4 讀成「async 更糟」。** n=4 對 n=4，這個差距毫無統計意義。可以說的只有
「沒有任何證據顯示它有幫助」。

## 另一半在跑之前就免費拿到了

`d1d973d` 的逾時**在曲線輪那四次 wedge 裡各觸發約 41 次**
（`grep -c "host-table read did not answer"`，41/40/40/40）。它完全照設計運作——gate 的
`get_all_host()` 不再永久掛住——**而 boot 照樣 wedge**。live dump 自洽：被卡的族群裡
**沒有 gate 的 greenlet**，正因為 `d1d973d` 把它放出來了。

⚠️ 審查 session 一度回報「timeout warning 零筆」並據此推論「`d1d973d` 沒上場」。那是
false negative：他們 grep 的是**變數名** `HOST_QUERY_TIMEOUT`，而它在訊息裡被內插成 `5.0`，
**那個字串永遠不會出現在 log 裡**。已撤回。「上場了但不足夠」和「沒被驗到」在報告裡是兩個
完全不同的句子。

## 兩個修法的最終狀態 — 以及 combo 其實已經測過了

🔑 **2026-08-25 補記：「兩個修法齊開」這一輪不必再排，因為它已經跑完了。**

`d1d973d` 的逾時**自該 commit 起就是預設開啟**，router 又凍結在含它的 `d19020b1`。所以
**async 臂本來就是「兩個一起」**——不是只有 `72fbae6`。逐檔驗證：

| boot | timeout warning | async banner | 結果 |
|---|---|---|---|
| `async_p3` | **40** | **1** | RING-WEDGE |
| `async_p4` | **40** | **1** | RING-WEDGE |

**兩個修法同時作用、同時可證（各自有自己的 log 證據），兩次都 wedge。**

因此正確的狀態表是這樣，而不是我原本寫的那樣：

| 組態 | 內容 | 怎麼驗的 | 結果 |
|---|---|---|---|
| timeout 單獨 | `d1d973d`（async 當時預設關） | 逾時每次 wedge 觸發 ~40–41 次 | **不足夠** |
| **timeout ＋ async（＝combo）** | 兩個齊開 | timeout 40 次 ＋ banner=1，仍 wedge ×2 | **不足夠** |
| async 單獨 | — | **從未測過，也測不了**：timeout 自 `d1d973d` 起就是預設，要單獨測 async 得先把 timeout revert 掉 | — |

⚠️ 我先前寫「`72fbae6` 上場了、不足夠」**措辭不精確**——被驗的一直是 combo，不是 async 單獨。
結論方向不變（環活過了所有測過的組態），但「哪個組態被測了」必須說對。

⇒ **環活過 timeout 單獨、也活過 timeout＋async。已知的修法組合全部用盡。**
反例邏輯照舊適用：兩次 wedge 時兩個修法都可證在作用，**與基礎率無關**。

## 那條沒被算進去的邊

三份 dump 的 frame 分佈（時間點不同，不可直接互比）：

| 取樣點 | `_events_sem.acquire` | `reply_q.get()` |
|---|---|---|
| 曲線輪 watcher，boot 後 104s | 12 | 51 |
| 本輪，boot 完成時（411s） | 49 / 74 / 85 | 63 / 38 / 27 |

`reply_q.get()` 那一族全部落在 **`ryu/base/app_manager.py:279`**，是
`return req.reply_q.get()`——**無逾時的 request-reply，在 Ryu 自己的 library 裡**。
形狀跟 `d1d973d` 在我們這側綁掉的那個一模一樣，但在上游，**我們改不到**。

**假說（未驗）**：環的邊不只四條，而 `app_manager.py:279` 是我們一直沒算進去的那條。任何
`send_request` 進到已飽和的 app 都會繼承一個無界等待，而那正好包含每一個 REST 呼叫者——
這也解釋了為什麼端點回 **HTTP 000** 而不是空 body。**先讀碼再寫機制，不要拿這段當定論。**

## 下一步建議

1. ~~兩個修法一起開~~ **已經測過了**（見上）——async 臂本來就是 combo，wedge 2/4。
   **不要再為它排一輪。** 已知修法用盡；下一步必須是新的機制工作，不是重測舊組合。
   最有希望的入口是 `app_manager.py:279` 那條（先讀碼）。
2. **靶會腐化，而且不是照 uptime 單調變化——這條殺掉我自己在曲線輪報告裡的框架。**

   | 輪次 | uptime | boot_id | wedge 率 |
   |---|---|---|---|
   | 曲線輪 | **17.48 h** | `b8b44406…` | quiet **4/4** |
   | 本輪 | **18.43 h** | `b8b44406…`（同一個） | defaults **1/4** |

   **同一個 boot session，uptime 增加約一小時，wedge 率從 4/4 掉到 1/4。**
   ⇒ 「uptime 越久越容易 wedge」**不成立**；「reboot 會清掉它」也裝不下這個形狀
   （中間沒有 reboot）。曲線輪報告寫的「uptime 是唯一還站著的共變量」要降級成：
   **reboot 邊界的相關仍在（session −1 @67h 是 6/10，session 0 前 50 次開機零環），
   但 session 內部非單調，機制未知。**

   實務結論：**下一輪要先量當下的 defaults 率再談任何歸因**，而且要快——一小時就能掉一半。
   由審查 session 指出（他們引的「~21h」有誤，實際是 17.48→18.43，**差距更短、腐化更快**）。
3. **翻 async 預設的理由不得升級。** 本輪沒有給出「破環」的證據，反而給了兩個反例。措辭上限
   仍是「閒置條件下開機時間 26s vs 52s ×10」。
