---
name: packaging-a-filesystem-ships-the-invisible
description: 打包檔案系統會帶走「所有正常檢查都看不到」的兩類東西——沒被簽出的 .git 物件、與刪掉沒 discard 的區塊；出貨前的檢查是 git rev-list --objects --all 加 fstrim，而且要帶陽性對照
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 46992009-fcf0-4ceb-955d-f16e090060c5
  modified: 2026-08-31T10:36:21.303Z
---

08-31：P4 demo VM 的 `.ova` 差一步就把 **EuroP4 雙盲投稿包**傳上 Google Drive。
auditor 問「image 裡的源碼是 clone 還是工作樹打包」，答案是**兩個都不是——工作樹的 `.git` 整包坐進去了**。

**Why:** 打包一個檔案系統，會帶走兩類「看起來不存在」的東西，而**所有正常的檢查工具都會說乾淨**。
「看起來不存在」與「不在成品裡」是兩回事。

## 兩類，同一個形狀

| | 症狀 | 唯一看得見它的東西 | 實測 |
|---|---|---|---|
| ① **沒被簽出的 `.git` 物件** | `ls`／`find`／`grep -r`／`git status` **全部回報乾淨** | `git rev-list --objects --all` | 77 個物件，含 `abstract.tex`／`refs.bib`／`NOTES.md`／`figs/` |
| ② **刪掉但沒 discard 的區塊** | `df`／`du` 說 30 GB | `populatedSize`／qcow2 實際大小 | 成品 70.6 GB ⇒ **40 GB 是幽靈，佔 57%** |

①的四個工具**不是四個獨立證據**——它們檢查的是同一個東西（工作樹）。
②那 40 GB 讓「少跑一次 `fstrim`」從衛生問題變成**可量化成本**：使用者多下載 8 GB。

## 出貨前的檢查

```
git rev-list --objects --all | grep -i <關鍵字>     # 帶陽性對照
fstrim -av                                          # 然後看成品有沒有變小
```

## 五條做法，每一條都是踩到才學到的

1. **證明「取得得到」而不只是「存在」。** 我實際 `git cat-file -s` 拉出 1147 bytes，
   那一步讓這件事不能被辯成「理論風險」。
2. **不要相信 `rm`。** unlink 不覆寫，`qemu-img convert` 照抄已配置區塊 ⇒ 刪掉的 packfile 會被
   複製進 `.ova` 並且救得回來。**刪之前先從被刪的檔案內部取簽名位元組**，重建後拿它證明真的沒了。
3. **取樣要取檔案，不要取映像上的偏移量。** 我第一版在 qcow2 命中點附近取樣，抓到
   `t-Using: rust-hyper-rustls (= 0.24.2-2)`——**apt metadata**。qcow2 偏移量不會待在同一個檔案裡。
4. **陰性對照不會跟著方法轉移到新的受測物。** 那組 packfile 樣本只對同一個 repo 的後代有效；
   指向另一顆裝著別的 repo 的 image，**每個樣本都落空、腳本印 CLEAN，跟真陰性一模一樣**。
   🔑 **剛剛才成功的工具最難放下。**
5. **殘留照實報。** `fstrim` 49 GiB ＋填零＋再 `fstrim` 14 GiB 之後，仍有 `packed-refs` 前 200 bytes
   卡在活檔案的 slack 裡（填零與 discard 都碰不到）。「大致清乾淨」不是可出貨的性質。

## 母片是產線，不是事故

`disk.qcow2`（39.5 GB、12 顆快照）**12/12 樣本命中、分佈在三個偏移群**。
🔑 **一顆髒的產物是一次事故，一片髒的母片是一條產線**——之後每一顆從那條快照鏈做出來的 VM 都繼承它。
⇒ 母體清單要把**母片與快照鏈單獨列一格**。

## How to apply

要離開這台機器的任何映像／容器／tarball／快照／備份，出貨前跑上面兩個檢查，**而且先證明搜尋
找得到東西**——零命中與搜尋壞掉長得一模一樣。與 [[local-git-refs-cannot-tell-you-what-is-public]]
的「untrack ≠ 歷史乾淨」是同一個形狀換了媒介；閘門本身要 force-red 見
[[failures-that-report-success]]；對照的擺法見 [[controls-decide-what-you-learn]]。
