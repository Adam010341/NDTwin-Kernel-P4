---
name: local-git-refs-cannot-tell-you-what-is-public
description: "🔴 `git push p4` 會發佈到一個公開 repo,而 `p4/main` 反映的是私有的那個——remote 的 fetch URL 與兩個 push URL 指向不同 repo,可見性不同。看本地 ref、看 `git remote -v`、看 `pushedAt` 都答不出「這是不是公開的」;只有 `gh repo view --json visibility` 或對公開 URL 打未認證請求才算數"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 98474226-21c6-4d5b-8379-a0bc282b8d80
  modified: 2026-08-31T09:10:47.386Z
---

2026-08-28。三個 session（我、`8/28 mainDev`、`8/27 auditor`）在同一天內
**各自對「這個 repo 是不是公開的」下了錯誤的斷言**，而那是一個一行指令就能查的事實。

## 這台機器上的實際配置

```
origin  fetch/push  git@github.com:ndtwin-lab/NDTwin-Kernel.git       PUBLIC   ← 上游 baseline,不要 push
lab     fetch/push  git@github.com:ndtwin-lab/NDTwin-Kernel-P4.git    PUBLIC
p4      fetch       git@github.com:Adam010341/NDTwin-Kernel-P4.git    PRIVATE
p4      push (1/2)  git@github.com:Adam010341/NDTwin-Kernel-P4.git    PRIVATE
p4      push (2/2)  git@github.com:ndtwin-lab/NDTwin-Kernel-P4.git    PUBLIC   ← ⚠️
```

🔴 **`git push p4` 會把東西發佈到一個公開 repo，而 `p4/main` 這個 remote-tracking ref
反映的是那個私有的。** 兩者永遠不會不一致到讓你發現——**它們追蹤的根本是不同的 repo。**

## 三種答不出這個問題的方法（當天各被用過一次）

| 用了什麼 | 為什麼答不出 |
|---|---|
| `git remote -v` | 只給 URL,不給可見性。**URL 長得一模一樣** |
| `git ls-remote` / 本地 ref | 用你的 SSH key 認證 ⇒ 私有 repo 也會成功 ⇒ **成功不代表公開** |
| `gh repo view --json pushedAt` | 那是**最後一次 push 的時間**,不是 visibility 變更時間。有人拿它宣稱「已公開三小時」,**而 GitHub 根本不透過 API 給 visibility 的變更時間** |

## 唯二算數的做法

```bash
gh repo view <owner>/<repo> --json name,visibility,isPrivate,defaultBranchRef
curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/<owner>/<repo>   # 200=公開 404=不是
```

**第二個是決定性的**,因為它不帶你的憑證 —— **它問的正是「陌生人看得到嗎」**,
而那才是「公開」的定義。第一個會被你自己的權限污染。

## 🔑 更一般的形狀

**「我推上去了」與「它是公開的」是兩個獨立事實,而 git 只知道第一個。**
當天的失誤鏈：

1. 我回報「main 已建好並同步到兩個 remote」—— **完全正確**
2. 另一個 session 讀成「還沒公開,所以 push 是安全的」—— **加了一個 git 沒說的前提**
3. 審查員據此下了「不要 push」的指示 —— **擋在一個已經發生過的動作上**
4. 然後改成「閘門在 visibility」—— **那時已經 public 了**

⇒ 🔑 **擋錯地方比不擋更糟：它讓所有人以為那件事被擋住了。**
（審查員原話,他自己更正的。同一條也適用於守衛與測試。）

⇒ **對不可逆的對外動作,不要對可查的事實下指示——先查。** 一行指令的成本,
遠低於「以為擋住了」的成本。

## 🆕 08-29 同一族第二式：**`git status` 乾淨 ≠ 這個檔沒被改過**

⚠️ **這一節的通則成立，但我原本掛在它下面的實例是錯的，已更正（見本節末）。**

| 問題 | 錯的儀器 | 對的儀器 |
|---|---|---|
| 這個檔被改過嗎 | `git status <path>` | **`git log --oneline <base>..HEAD -- <path>`** |
| 這個 commit 公開了嗎 | 本地 ref／`git remote -v` | `gh repo view --json visibility`／未認證 `curl` |
| 有東西沒推嗎 | `git status` | `git log --all --not --remotes` |

🔑 **共同形狀：這三個指令都會給你一個乾淨、明確、看起來像答案的輸出，而它們回答的是別的問題。**
**「乾淨」在 git 裡幾乎永遠是關於工作區的，不是關於歷史的。**

📌 這條狀態檔自己 08-20 就記過一次（§5-K：「交接節裡的『未完成』項目要用 `git log -- <path>` 驗，
不要照抄」）。上面那張表本身仍然成立、仍然值得照做。

### 🔴 但我原本寫在這裡的實例是錯的 —— 更正（08-29）

我原本寫：`8/29 auditor` 用 `git status` 判定三份 runbook「未被修改 ⇒ 沒有造成損害」，
而我早就改過了 ⇒ 結論是「他用錯儀器」。**他反駁了，而他是對的。**
時間戳：`f351aea` **13:30:17** → `4126cc4` **13:38:47** —— **他跑檢查時 `4126cc4` 還不存在**，
所以對那一刻而言 `git status` 問的正是對的問題、答案也正確。

**真正的錯是時序，不是儀器**：他在**自己那道已經作廢的命令還在飛的時候**就宣告「沒有損害」。
他在同一封信裡作廢了命令，**但我已經先執行了**——跨 session 訊息是排隊的。
⇒ **他拿一個「此刻為真」的觀測，去結論一件尚未落地的事。**

🔑 **所以正確的判準不是換一個 git 指令，是「我下的指令有沒有全部回收」**
—— **收回一道命令之前，任何損害評估都無效。**
**正本＝[[rescinded-orders-invalidate-damage-assessment]]**（`8/29 auditor` 開的獨立檔；
[[draft-outward-facing-artifacts-first]] §可操作三條的第 1 條有三行摘要指過去）。
**不要在這裡展開第三份。**

📌 **這件事本身的教訓**：我把一個**時序問題**誤診成**工具問題**，
還把它寫進記憶當成通則的實例。**通則是對的，但它不是這件事的原因**
——[[arithmetic-that-fits-is-not-the-mechanism]]：**吻合的解釋不等於機制。**

相關：[[push-commits-to-github]]（`git push p4` 自動推兩邊——**現在知道其中一邊是公開的**）、
[[draft-outward-facing-artifacts-first]]（GitHub 沒有「先送再收回」）、
[[process-liveness-checks-lie-in-two-ways]]（同一族：儀器回答的不是你問的問題）。

🔴 08-29 第三式：**「還沒推」的記憶比「乾淨」更會過期**。我拿 State 帳本的舊節
（§14-12「16 commit 未推」）勸 auditor「先不要推」——實際上 §14-13 已取代它、
我的三個 commit 幾小時前就公開（未認證 curl 200），連我擔心的 rescue 分支名都
從未被推（裁定的做法是快轉 fix/ 分支）。⇒ 對「公開了沒」發言前：
未認證 curl 當場驗＋確認引用的帳本節是最新入口——**同一份檔案裡，被取代的節
跟現行的節長得一樣**（＝「被作廢的檔案跟有效的長得一樣」的節版）。

## 🔴 08-30 第四式：**untrack ≠ 歷史乾淨；tip 的乾淨答不出「push 會送什麼」**

雙盲投稿的 poster bundle 要留在本地。演進了三步，**每一步都以為完成了**：

| 步驟 | 做了什麼 | 實際效果 |
|---|---|---|
| `fbf9cce` | 只加了 6 行 `.gitignore`，commit message 卻寫 *"a future push cannot resurrect it"* | ❌ **假的**——gitignore 對**已追蹤**檔案無效，22 個檔仍在 tree |
| 補刀 commit | `git rm -r --cached` ＋ **無 pathspec** commit | ✅ tip 乾淨了（`ls-files`=0、`check-ignore` rc=0、磁碟 5+13 檔還在） |
| 我複驗 | `git rev-list --objects HEAD --not --remotes \| grep europ4` | 🔴 **仍有 9 個 poster 物件會被送出去** |

原因：untrack 只改**當前 tree**。未推區間裡 `fbf9cce` 之前**每一顆 commit 的 tree 都還有 22 個檔**。
**push 送的是可達物件，不是 tip 的 tree。** ⇒ 解凍後推，branch tip 的 checkout 乾淨，
但任何人 `git show <舊sha>:<path>` 拿得回整包。

🔑 **問題／儀器對照表再加一列：**

| 問題 | 錯的儀器 | 對的儀器 |
|---|---|---|
| **這個 push 會送出什麼** | `git ls-files`／`git ls-tree HEAD` | **`git rev-list --objects HEAD --not --remotes`** |
| **這個映像／壓縮檔會帶走什麼** | `ls`／`find`／`grep -r`／`git status` | **`git rev-list --objects --all`（帶陽性對照）＋ `fstrim`** |

## 🔴 08-31 第五式：**打包一個檔案系統，就會打包它的 `.git`**——而所有正常檢查都說乾淨

一顆要上 Google Drive 的 `.ova` 裡，**工作樹的 `.git` 整包在內**：77 個物件，含雙盲投稿的
`abstract.tex`／`refs.bib`／`make_figs.py`／`figs/`。**那些檔從來沒被簽出** ⇒
`ls`／`find`／`grep -r`／`git status` **全部乾淨**，只有 `git rev-list --objects --all` 看得見，
而且實測 `git cat-file` 真的拉得出內容（**可取得，不是理論風險**）。

⇒ **出貨前的檢查有兩件，它們是同一個機制的兩面：**
1. **從沒被簽出的 `.git` 物件** ——`git rev-list --objects --all`，**必帶陽性對照**
   （零命中與搜尋壞掉長得一模一樣）；
2. **刪掉但沒 discard 的區塊** ——`df`／`du` 說 30 GB 而成品 70.6 GB，
   **差額 40 GB ＝成品的 57%**，少跑一次 `fstrim` 的代價是 8 GB 的下載。

🔑 **共同形狀：「看起來不存在」與「不在成品裡」是兩回事。**
🔑 **母片與快照鏈要單獨列一格**——**一顆髒的產物是一次事故，一片會被沿用的映像是一條產線。**
🔑 **一個方法的陽性對照不會跟著方法轉移到新的受測物**：用 A repo 的 packfile 樣本去掃 B repo，
**零命中是假陰性，而它長得跟真答案一模一樣**（在方法剛成功過的時候放棄它最難）。
⚠️ 鑑識時**唯讀掛載、不要開機**——開機會引入三個承重未知數，其中一個是
**「它第一次開機會往我正要檢查的磁碟寫什麼」**（＝量測不得改變被量測的東西）。

⚠️ `git ls-files` 沒有壞，它回答的是**「tip 追蹤了什麼」**——那是個好問題，只是不是這個問題。
**同一族第四次**：乾淨、明確、看起來像答案的輸出，回答的是別的問題。

📌 **`fbf9cce` 那顆的教訓另有一層**：auditor 事後找到機制——他 `git rm -r --cached` 之後用
**`git commit -- <paths>`** 收尾，而 **pathspec commit 提交的是那些路徑的工作樹**，
把 staged 的刪除蓋掉了。⇒ **`git commit -- <paths>` 保護 index 不被別人的檔汙染，
但它也會覆蓋你自己 staged 的刪除。** 兩個性質同源，一個有用一個會咬人。

**修法（改寫未推歷史）是 Adam 的 poster 裁決範圍，我只報未動。**
⚠️ 公開側 `cb25da8` 是否有同樣問題**我沒查**，不要當成我驗過的。

## 🔴 08-31：**`origin` 不是我們的 repo**（推之前先看這條，省一次困惑）

實測（`gh repo view --json viewerPermission,visibility`）：
| remote | repo | 權限 | 可見性 |
|---|---|---|---|
| `origin` | `ndtwin-lab/NDTwin-Kernel` | **READ** | PUBLIC |
| `lab` | `ndtwin-lab/NDTwin-Kernel-P4` | **ADMIN** | PRIVATE |
⇒ **`git push origin …` 一定失敗**（`Permission ... denied to Adam010341`），那不是憑證壞掉，
是那個 remote 本來就是上游。我們推的是 **`lab`**。
🔑 **CLAUDE.md 的「diff 暴漲先查」在 08-31 立刻付了本錢**：push 前掃 `git rev-list --objects
<remote-tip>..HEAD` ⇒ 抓到整個投稿包在範圍內（38 物件）。查證後定性＝**既有的私有狀態、
非新洩漏**（poster 首 commit `9c8c0e6` 是昨晚已推的 `09c9b03` 的祖先），lab `main` 是乾淨系。
**Adam 裁：推新 ref `work/rescue-0831`、`main` 保持乾淨系錨點**（已推、sha 驗過）。
⇒ 通則：**push 前掃描要對「這一發實際會送出的物件集」跑**，不是對 `git status`；
而掃到東西時第一步是**定性（新的還是既有的？哪個 ref 已經有了？）**，不是急著改歷史。

## 🔴 08-31 第五式：**這一族不只是 git 的事——頁面是指標，指標答不出「另一端現在是什麼」**

網站上的 demo VM 下載連結。我斷言「那是 P4 之前的、二月那顆」，依據兩項：

| 我看的 | 它其實回答了什麼 |
|---|---|
| 頁面的元件清單（Kernel/Ryu/Mininet，零個 P4） | **頁面**現在寫什麼 |
| `git log -S<file-id> -- content/` ⇒ `1efc7b1`（xxxPatty, 2026-02-13） | **連結**最後一次被編輯是什麼時候 |

**兩項都不是關於那個檔案的。** 實測（抓下載的前 1 MB，OVA 規格把 `.ovf` 放在 tar 第一個成員）：
`last-modified` = **當天 11:29 CST**、17.9 GB、內部名 `NDTwin-Testbed-20260831`、
`Generated by VMware ovftool 5.0.0` 時間戳 **同日 11:18:39**。
⇒ **檔案在幾小時前被換掉，而網站不需要任何 commit**——連結是 Drive file ID，
**換內容不換 ID，所以版本控制裡永遠看不到這件事發生過。**

🔑 **問題／儀器對照表再加一列，而且這一列跨出了 git：**

| 問題 | 錯的儀器 | 對的儀器 |
|---|---|---|
| **這個下載連結現在給的是什麼** | 頁面文字／改那行的 commit | **對 URL 發未認證請求**（`curl -I` 看 `content-length`／`last-modified`；大檔用 Range 抓開頭讀 metadata） |

**與本檔第一節同構**：那裡是「未認證 curl 才問得出『陌生人看得到嗎』」，
這裡是「未認證 curl 才問得出『陌生人拿到的是什麼』」。
⇒ 通則：**對任何「我們控制的頁面指向外部資源」的宣稱，權威永遠在資源那一端。**
🔑 而且這一族在同一個 session 內連犯兩次（另一次見
[[install-manual-clean-room-test]] 的 `/mnt/win`：`mountpoint` 回 false 就結論「構不到」，
而那顆磁碟掛在別的地方）——**兩次都是「用一個關於指標的觀測，去斷言目標的狀態」。**

## 🔴 08-31 第六式：**工作樹乾淨 ≠ 打包出去的東西乾淨**——四個檢查其實是同一個檢查

要掛官網公開下載頁的 P4/BMv2 demo VM `.ova`，上傳前的內容查核閘（auditor 要求的）
在 image 的 `.git` 裡撈到 **77 個 EuroP4 投稿包物件，含 `abstract.tex`**。
**那些物件沒有被簽出**，所以：

| 檢查 | 回答 |
|---|---|
| `ls` / `find` / `grep -r` / `git status` | **四個全報乾淨** |

🔑 **四個「獨立確認」不是四個證據——它們檢查的是同一個東西（工作樹）。**
這跟本檔第一節的「untrack ≠ 歷史乾淨」是**同一個形狀換了媒介**：那次是 repo 的公開歷史，
這次是 VM image 裡夾帶的 `.git`。⇒ 通則：**打包的單位是目錄，而 `.git` 在目錄裡。**

| 問題 | 錯的儀器 | 對的儀器 |
|---|---|---|
| **這個 image／tarball 送出去會夾帶什麼** | `ls`／`find`／`grep -r`／`git status`（全是工作樹） | 刪掉 `.git`，或 `git rev-list --objects --all` |

🔑 **處置也做對了、值得抄**：刪 `.git` 重打包之後**帶對照組驗**——
packfile 11/11 樣本消失、**對照組 12/12 仍找得到** ⇒ **抓得到東西的管線才有資格報「沒有」**
（同 [[grep-endpoints-misses-concatenation]] 的陽性對照規矩）。污染的舊檔**改名**成
`…-CONTAMINATED-DO-NOT-SHIP.ova` 而不是靠記得——**危險的檔案要自己喊出自己是什麼。**

⚠️ **另一半沒有被這道閘涵蓋，別讀成全過**：那顆 `.ova` 洗掉的是**投稿包**，
它照樣裝著一個 **PRIVATE repo 的完整原始碼**，而下一步是公開下載頁。
**「暫存窗乾淨」與「這東西該不該公開」是兩個問題**，前者答對不代表後者問過
（規定 §3 R4 的範圍註記＋§6-10）。

# 🆕 第六式（08-31）：媒介再換一次——**映像檔**

「untrack ≠ 歷史乾淨」的第三個載體。前兩個是 repo 本身與 Drive 頁面，這個是 **VM 映像**：

一顆 `.ova` 裡的 `.git` 帶著 77 個 EuroP4 投稿包物件，**而工作樹裡一個都沒簽出**
⇒ `ls`／`find`／`grep -r`／`git status` **全部回報乾淨**。看得見它的只有 `git rev-list --objects --all`。

🔑 **同一條規則、第三種媒介**：**「我看不到它」從來不等於「它不在裡面」。**
判準也一樣不變——要斷言「公開的是什麼」，只有**打那個公開介面**算數：
這次用的是**未認證** `curl` 打 GitHub API（殘留 SHA 全回 **422**、對照組回 **200**）
以及**未認證下載 Drive 檔重算雜湊**。

完整做法在 [[packaging-a-filesystem-ships-the-invisible]]。

## 第七式：**用未認證 curl 打下載連結，比我以為的便宜得多**

08-31 我曾在記憶裡寫「要查 Drive 檔是不是公開，**得用 Adam 的瀏覽器身分或另一個帳號**，
所以我沒查」。**那是把它想得太難。** 實際上：

```bash
curl -sL "https://drive.usercontent.google.com/download?id=<ID>&export=download" \
  | grep -oE '<span class="uc-name-size"><a[^>]*>[^<]*</a>\s*\([^)]*\)'
```

不帶任何 cookie／帳號。回得出檔名與大小 ⇒ **公開**；限制存取會回登入導向。
這一招當場解掉一個被標成「未解決衝突、不要照任何一份行動」的問題，
而且順帶量出**檔案大小**⇒ 認得出線上那顆是哪一版（2.3G 是舊的、2.6G 才是新的）。

🔑 **「我沒查，因為那需要 X」要先確認真的需要 X。** 我為此讓一個安全相關的未知狀態
多懸了幾小時，而查它只需要一次 `curl`。

⚠️ 副作用見 [[install-manual-clean-room-test]]：**整份下載**會燒掉 Drive 的檔案配額，
把連結對所有人關掉約一天；**range 請求（`-r 0-4095`）不會**，而且足以認出檔案身分。
