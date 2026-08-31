---
name: draft-outward-facing-artifacts-first
description: 對外產出（GitHub issue、PR、寄出去的東西）先寫成本機草稿等 Adam 點頭，不要先送出後告知
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 576681dc-6a95-4e35-b020-de395c7eea6d
  modified: 2026-08-30T11:48:18.799Z
---

2026-08-21 Adam 裁決。我在 `ndtwin-lab/NDTwin-Website` **沒問就開了兩個 issue**
（#43 #44），事後才報告。他的回覆：**寫成本機草稿，等他點頭才送。**

**Why:** GitHub **沒有「只有我看得到」的 issue**——private repo 的 issue 對每個有權限的
協作者都可見，開出去的那一刻就已經對外了。close 只是狀態，不會隱藏，還多送一次通知；
**永久刪除要 admin/maintain**，我只有 pull，做不到（而且永久刪資料本來就不該我代做）。
所以「先送出、不對再收回」這條路**在 GitHub 上根本不存在**。

更根本的理由是**我當時的判斷還沒站穩**：同一天我對 Ryu port 那條寫進 memory 的「修正」
後來被 live 實測整個推翻（見 [[ndtwin-official-docs-site]]）。如果那條也開成 issue，
就會是拿錯的東西去要求別人改一份本來就對的文件。**文件類發現尤其要先 live 驗過再送。**

**How to apply:**
- issue／PR／對外訊息 → 先寫 `scratchpad` 或分支裡的草稿檔，把內容給他看，**他點頭才送**。
- 已經送出去的，誠實講「已經對外了，沒有回溯的隱私」，不要說得像可以收回。
- 送之前先問：這條的證據是**實測**還是**讀原始碼推的**？後者先去驗。

相關：[[cited-line-numbers-are-not-evidence]]、[[reproducible-is-not-mechanism]]、
[[model-hypotheses-saturated]]（讀原始碼會系統性高估缺陷）、[[push-commits-to-github]]。

## 🔴🔴 2026-08-28：**我對兩個 session 下了「不要 push」，而那時已經 push 且公開三小時**

`ndtwin-lab/NDTwin-Kernel-P4` 在 **08-28 10:47:45 就已經是 PUBLIC**。
我在 11:0x 指示兩個 session「commit 在本地安全，push 不安全」。
**我給的是假的安全感，而且是以審查員的身分給的**——我的指示是他們的判準來源。

## 🔑 根因：**`p4` remote 的 fetch URL 與 push URL 指向不同的 repo**

```
p4  fetch = Adam010341/NDTwin-Kernel-P4   (PRIVATE)
p4  push  = Adam010341/NDTwin-Kernel-P4   (PRIVATE)
p4  push  = ndtwin-lab/NDTwin-Kernel-P4   (PUBLIC)   ← 第二個 push URL
```

⇒ **`git push p4` 會發佈到公開 repo，而 `p4/main` 反映的是私有 repo。**
⇒ 🔴 **不管多仔細看 tracking ref，都看不到公開狀態。這是設計上的盲區，不是誰粗心。**

**唯一可靠的做法：直接對公開 URL 打 `git ls-remote`，或 `gh repo view <repo> --json visibility`。**
（記憶裡原本那條「`git push p4` 自動推兩邊」是對的——**但沒有記「其中一邊是公開的」。**）

## 實際範圍（我親自數的，不是轉述）

| | |
|---|---|
| `main`／`fix` 樹 | **999** 檔（`doc/audit/` **563**） |
| 🔴 **`audit-raw` 分支** | **2,743 檔，2,742 個是 raw dump** |

⚠️ **`audit-raw` 是一條專門用來裝 raw dump 的分支**——`.gitignore:60` 擋 `doc/audit/*/raw*/*`
不讓它進 `main`，**而有人開了一條分支繞過它，那條分支也是公開的。**
**只檢查 `main` 會漏掉四分之三的量。**

## ✅ 可操作的三條

1. > **在給別人「不要做 X」的指示之前，先確認 X 還沒發生。**（`mainDev` 的措辭）
   ⇒ **擋錯地方比不擋更糟**，因為它讓所有人停止查證。
   🆕 **08-29 鏡像面**：**收回一道命令之後，在確認它已經被全部回收之前，任何損害評估都無效。**
   與本檔開頭「我推上去了 ≠ 它是公開的」同型——**「我已經撤回」與「它沒有發生」是兩個獨立事實**。
   ⇒ 全文、時間戳與誤診經過在 [[rescinded-orders-invalidate-damage-assessment]]（**正本在那裡，不要在這裡展開第二份**）。
2. **檢查「什麼是公開的」只能打公開 URL。** tracking ref、本地 branch、`git log` 全部不算數。
3. 🔴 **清理／稽核範圍要列出 remote 上的每一條分支**（`git ls-remote`），不要只看 `main`。

## 📌 補救選項的排序（供之後參考）

| | 改寫歷史 | **轉回 private → 整理 → 再 public** |
|---|---|---|
| 停止進一步曝光 | ✅ | ✅ |
| **保留所有 sha** | 🔴 否 | ✅ |
| 投影片／報告／`.provenance` 的引用 | 🔴 **全斷** | ✅ 不受影響 |
| 可逆 | 🔴 否 | ✅ |

🔑 **為了移除「使用者名稱」而讓整條證據鏈斷掉，代價明顯不成比例。**
⚠️ 已被 clone／索引的救不回來——**但那對兩個選項都一樣，所以它不是選項之間的差異。**
⚠️ **而如果公開是 Adam 自己裁的，「轉回 private」就是撤銷他的決定** ⇒ 更不能由我們發動。
（後記：08-30 Adam 親裁走了右欄——兩個 P4 repo 轉私有到過審，未認證 404 三方驗訖。）

## 🆕 08-30（poster R2/R3）：**對外稿的風格裁量權＝外部非 Claude 模型＋Adam，Claude 只做宣稱安全審**

Adam 明示的分工（reviewer 轉述＋實跑一整輪）：對外文字要改風格／語氣／用詞時，
**建議由外部非 Claude 模型出**（本輪＝deepseek v4 pro/flash＋muse spark＋gemini 3.1 pro 四家），
Claude 的角色只有**宣稱安全審**——數字、hedge、技術詞、紅線子句不准動，逐條標
接受／指定安全版本／交裁量／VETO。理由：**自家模型風格太像，不當風格裁判**。
實跑管線＝同一份乾淨萃取 prompt × 四家 → 合併單（55_ 形式）→ 照單落稿 →
獨立驗收（紅線必存掃＋禁語雙向掃＋[[verify-against-known-good-output]] 檔尾的數字多重集守恆）。
之後對外文字修訂照這條管線走，不要讓 Claude 自己提風格替代文。
