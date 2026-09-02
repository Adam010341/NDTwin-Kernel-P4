# Finding — a tester that stops looks exactly like a manual with nothing left to report

**Raised 2026-09-03, A-7 campaign（本線＋09-01 auditor 兩條線各自撞到同一形狀）。**
正本放這裡而不是記憶，因為 auditor 那條線已經有一份記憶條目，避免第二次重複。

## 形狀

**Tester 因為對自己的執行環境抱持錯誤信念而停手，而停手在記錄上看起來像「做完了」或
「沒有更多問題」。**

這是一個關於**儀器**的缺陷，但它的痕跡落在**被測物**的成績單上。沒有人會去懷疑一件
沒有出現的事情，所以它不會被自動發現——只會被當成「這一輪沒有更多 friction」。

## 今晚的兩種面貌

| 面貌 | 錯誤信念 | 實際 | 在記錄上長什麼樣 |
|---|---|---|---|
| **等一個不存在的完成通知**（本線：haiku ×4、sonnet ×1） | 「我把 build 丟到背景了，它完成時會有通知叫醒我」 | `setsid` 丟進 **guest** 的行程不是 harness 追蹤的對象；harness 啟動的是一個**已經返回的 ssh**。沒有東西會來 | 回合乾淨地結束、JOURNAL 停在某一節、CHECKLIST 大量 PENDING ⇒ 讀起來像「跑到這裡就沒問題了」 |
| **死於用量上限**（auditor 線：兩個 agent；本線：run-03 的 opus） | —（外部中止） | 整輪的判定留在腦子裡沒落盤 | 同上，而且**更像**完成：run-03 的 §6.1 甚至在它死後 53 分鐘成功了 |

## 為什麼「重申規則」修不好它

模板的規則 1 從 run-03 起就寫著「**Ending your turn is stopping**」，而 sonnet 仍然停了。
規則講的是**應該怎麼做**，而 tester 的問題是**它相信的世界不是它所在的世界**——
它的信念在自己的 harness 裡是對的（`run_in_background` 的 Bash 工作確實會通知它），
只是不適用於「透過 ssh 在另一台機器上 detach 的行程」。

⇒ 有效的改法是**點破那個信念**，不是重申那條規則：

> 🔴 A process you detached inside the VM is not a background task of yours, and it cannot wake
> you. Your tooling tracks work *it* started; what it started here was an `ssh` that has already
> returned. — 模板 `24bda48a`，sha `a19b5e7165bf1d55`，run-05 起生效

## 對「一次通關」判準的影響

🔑 **任何一輪的「沒有更多 friction」都要先排除「tester 只是停了」。**

具體要求，寫進之後每一輪的收案程序：

1. **成績單只算 tester 親眼觀測到的**。機器完成但 tester 沒看到，記成兩格
   （「機器完成／tester 未觀測」），不寫 PASS 也不寫沒測到——run-03 的 §6.1 就是這樣記的。
2. **收案時必須明寫涵蓋邊界**：停在第幾步、後面哪些章節根本沒被走到。
   `CHECKLIST.md` 若 mtime 早於後段工作，它就**不是成績單**（run-03：149/187 仍 PENDING）。
3. **一輪的 friction 統計要附上中止原因**。零 friction 3 若伴隨提早中止，那是「沒量到」
   不是「沒發生」。

## 同族

同一晚的另外兩個「儀器決定了結果，而結果看起來像被測物的性質」：

- **測試環境的方便遮住缺陷**：tester VM 的全域免密碼 sudo 讓 `ndt` 的兩個 `sudo -n` 缺陷
  在四輪裡完全隱形（見 `run-03-opus/RECONCILIATION.md` 與 auditor 的 `fix/ndt-sudo-surface`）。
- **公開快照落後 trunk**：naive-user 測到的碼不是我們在修的碼，於是每輪重現同一批已修缺陷。

三者的共同結構相同：**我們為了讓量測進行而做的安排，改變了量測的結果**。

[Co-developed with claude code -- Adam]
