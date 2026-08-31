---
name: smoke-the-accept-path-not-just-refusals
description: 只 smoke 拒絕路徑的驗證，對「守衛完全壞掉」的程式碼照樣全綠——接受路徑要用擬真主體實測（Phase 7 helper 的 comm 截斷 bug）
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-27T13:57:32.241Z
---

Phase 7 寫 root helper 時，我對 `off` 做了八條拒絕路徑的 smoke（壞 manifest、PID 重用、
注入字元…全部正確拒絕），然後就繼續往下走。但 `EXPECTED_COMM = "simple_switch_grpc"`
比對的是 `/proc/<pid>/comm`——**上限 15 字元**（`simple_switch_g`），所以接受路徑永遠
走不到：helper 對真的 bmv2 會 100% 拒絕。而 runbook §80 明文警告過這個陷阱
（`pgrep -x` 同款），我在寫新程式碼時照樣踩進去。

**Why：** 拒絕路徑的測試對「守衛條件寫錯方向」是盲的——一個把所有東西都拒絕的守衛，
會讓全部拒絕測試通過。只有接受路徑能證明守衛「放對的進來」。

**How to apply：**
- Smoke 一個守衛時，接受路徑至少一條，而且主體要擬真：這次是
  `cp /bin/sleep simple_switch_grpc` 再執行，讓 comm 真的變成截斷形，才逼出 bug。
- 文件裡已記載的陷阱不是「已處理」，是「要在每段新程式碼裡重新檢查」的 checklist 項。
- Subagent 後來的測試把這課變成永久測試：用 `exec -a` 冒名者和 `simple_switch_gui`
  前綴混淆各釘一條。相關：[[mutation-gate-for-tests]]（同樣的哲學：沒看過它通過
  該通過的，不算驗證）、[[p4-orphan-switches-and-manifest-lifetime]]；helper 的驗收清單
  （`sudo -n` 免密碼、用法錯誤 exit 2、manifest 不存在 exit 1）在
  `doc/2026-08-11_phase7_power_mechanism_design.md`。

## 🔴 2026-08-28 鏡像面：**「拒絕」路徑可以真跑，「放行」路徑不行**

`開機手冊` 加了一個守衛（開 VM 前檢查 `lab.claim` 的 `exclusive_cpu`），然後測它。
測「應該放行」那一支時，`vm.sh start` 走到 `rm -f "$MONITOR"`，
**刪掉了一台正在暫停中的 VM 的 monitor socket** ⇒ 那台 VM 救不回來，只能砍掉重跑，
一整輪安裝實驗作廢。

> **守衛的「正確運作」親手製造了它要防的傷害。**

🔑 **不對稱在哪裡：**

| 路徑 | 它的副作用 | 能不能直接真跑來驗 |
|---|---|---|
| **拒絕** | **就是「沒有副作用」** | ✅ 可以 |
| **放行** | **真的去做那件事** | 🔴 **不行** |

⇒ **用同一種方法測兩支，就是在真的做那件事。**
修法：被守衛保護的那個動作要有 **dry-run**，讓放行路徑可以在不觸發後果的情況下被驗。

## 🪞 而這是本檔既有那條的**另一面，而他沒認出來**

本檔原本記的是：**八條拒絕路徑全綠，而接受路徑對真實輸入 100% 拒絕**（＝只測了拒絕）。
今天這條是：**測了接受路徑，而測的動作本身造成了傷害**。

**同一枚硬幣，而兩面長得不像**——這說明了為什麼記過還是會再踩。
⇒ 兩面要一起記：**接受路徑必須被驗，而且不能用「直接跑一次」來驗。**

📌 附帶一個難診斷的機制：**unix socket 的名字在建立時綁定，刪掉再建不會綁回去。**
VM 仍在一個**沒有名字的 inode** 上 listen，`cont` 永遠送不到。
**不是「檔案不見了」，是「檔案還在但已經不是同一個東西」**——比刪掉更難看出來。

📌 同日他還做對一件相關的判斷：守衛原本寫成「只要有 claim 就擋」，他**主動改鬆**，
理由是「**過嚴的守衛我會每次加參數繞過，它就等於不存在**」。
⇒ **一個總是被繞過的守衛比沒有守衛更糟**，因為它讓所有人以為那件事被擋住了。
與 [[verify-the-purpose-not-the-mechanism]] 的「宣稱自己防住某個失敗的守衛，
會讓所有人不再去查那個失敗」是同一條。

📌 **2026-08-28 收尾：那個 dry-run 修法已經驗證過了，而且是用真實的 claim。**
`vm.sh` 加了 `VM_DRY_RUN=1`（跑完所有檢查、停在建立/刪除/啟動任何東西之前）。
鄰居 session 剛好把 `lab.claim` 設成 `exclusive_cpu=yes`，於是兩支都驗到：

| 路徑 | 結果 |
|---|---|
| 拒絕 | exit=1、印出對方的 note、持有 disk image 的行程 **0 → 0** |
| 放行 | `VM_ACK_EXCLUSIVE_CPU=yes` 通過守衛後停在 DRY RUN，**什麼都沒建立、沒刪除、沒啟動** |

🔑 **放行路徑在不執行副作用的情況下被驗證** —— 這正是本節要的那件事，現在有實例了。
⚠️ 附帶：第一次想驗時 VM 正在跑，`vm.sh start` 在「already running」就提前結束，**兩個測試都回 0 而什麼都沒測到**。
**一個和它宣稱在測的東西無關的綠燈** —— 要看輸出，不要看 exit code。
