# 出貨前清單：任何要離開這台機器的 VM 映像／tarball

**適用對象**：`.ova`／`.vmdk`／`.qcow2`／tarball——**任何會被下載、分享連結、或交給別人的成品**。
不論它是要公開、要給一個人、還是只是搬到另一台機器。

**為什麼是清單而不是一條規則**：2026-08-31 同一套匯出程序，**在兩個不同的產物上各出了一次事**，
而兩次的具體症狀完全不同。**開一張票寫「加 `fstrim`」，下一次會漏掉別的東西**——
根因是那套程序**沒有出貨前檢查**，不是少了某一個步驟（auditor 2026-08-31 裁）。

| 出事的產物 | 症狀 | 為什麼沒被擋下 |
|---|---|---|
| P4/BMv2 demo VM 的 `.ova` | **整包 `.git` 跟著走**，裡面有 77 個 EuroP4 雙盲投稿物件（含 `abstract.tex`） | 物件從沒簽出 ⇒ **`ls`／`find`／`grep -r`／`git status` 四個全報乾淨**（它們檢查的都是工作樹） |
| 已公開的 `NDTwin-Testbed-20260831`（17.9 GB） | **約 40 GB 是刪掉但沒 discard 的區塊，佔成品 57%** | 沒有人比對過「成品大小」與「檔案系統實際用量」 |

[Co-developed with claude code -- Adam]

---

## 三項必做（每一項都要留下輸出）

### ① 歷史：`.git` 要嘛刪掉，要嘛查過——**而且要帶陽性對照**

```bash
# 找出所有物件庫（含 worktree/submodule 用的 .git 檔、以及路徑裡沒有 .git 的 bare repo）
find <mount> -xdev -name .git -print
find <mount> -xdev -path '*objects*' -name '*.pack' -print

# 對每一個：問物件庫，不要問工作樹
git -C <repo> rev-list --objects --all | grep -E '<你不想帶走的名字>'
git -C <repo> config --get-regexp 'remote\..*\.url'    # 私有 repo 可能 clone 成不起眼的名字
git -C <repo> fsck --unreachable                        # 刪掉沒 gc 的分支就是這個形狀
```

🔴 **`git status` 不算數。** 它與 `ls`／`find`／`grep -r` **不是四個獨立證據**——四個檢查的都是工作樹。

🔴 **陽性對照是這一項的一半**：證明你的管線**抓得到東西**（對一個已知含有目標字串的 repo 跑一次，
看到非零命中），否則「0 命中」與「管線壞了」長得一模一樣。
刪 `.git` 重打包之後同理：**抽樣驗它消失了，並用對照組驗同一支管線仍然找得到別的東西**。

⚠️ **不要用 `| head -N`**：08-31 差點從一份被截斷的清單讀出「沒有私有 material」（那個 repo 有 953 筆比對）。

### ② 空間：`fstrim`，而且要驗它生效了

```bash
# guest 內，關機前
sudo fstrim -av
```

### ③ 對帳：**成品大小 vs 檔案系統實際用量**

```bash
df -h /            # guest 內：實際用掉多少
du -sh /           #
qemu-img info <img> | grep -E 'virtual size|disk size'
# OVF 的話讀 populatedSize
```

**差額過大就是還沒 trim。** 08-31 那顆：`df`／`du` 說 30 GB，已配置 70.6 GB ⇒ **40 GB 是空氣**。
🔑 **這一項是 ② 的驗收，不是重複**：`fstrim` 回 0 不代表區塊真的被釋放
（**驗狀態不驗 rc**，本 repo 反覆踩過的形狀）。

---

## 🔑 最便宜的那一步不在清單上：**先問「它到底需要什麼」**

08-31 同一天的正面例（mainDev 的 E 輪）：要在遠端 guest 裡 build kernel，
它沒有送 **2.3 GB 的整棵樹**，而是先確認 build 只需要
`CMakeLists.txt` ＋ `include/` ＋ `src/` ＋ `tests/`，**送了約 3 MB**。

⇒ **`.git`、`doc/`、`p4_proxy/`、投稿包根本沒有出發。**

> **不必洗的東西，也不必驗它洗乾淨了。**

⚠️ 但「我查過 CMakeLists」與「它真的建得起來」是兩個宣稱 ⇒ **縮減過的內容要有一次成功的 build 當陽性對照**
（build 失敗會告訴你少了什麼，那是便宜的失敗）。

---

## 出貨後：**大小與內容都要能被外人重新查證**

- **公開與否只能打公開 URL 驗**（未認證請求），tracking ref／頁面文字都不算數。
- **連結是指標**：Drive file ID 換內容不換 ID ⇒ **版本控制裡看不到檔案被換過**。
  ⇒ 宣稱「下載頁現在給的是 X」要對 URL 發未認證請求，不要看改那行的 commit。
- 成品的 `sha256` 要公布，**並由第二方獨立對帳一次**（08-31 H-14 就是這樣驗的）。

## 相關

- 佔用與暴露規定：[audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md](audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md)
  §3 **R4**（共用帳號的暴露窗）與 **R4a**（`.git` 夾帶未簽出的歷史）。
  🔑 **R4 管「停留期間誰看得到」，本清單管「之後誰永久拿得到」——判準不同，通過前者不代表通過後者。**
