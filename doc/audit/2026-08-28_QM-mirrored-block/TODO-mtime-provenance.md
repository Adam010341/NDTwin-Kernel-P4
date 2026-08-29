# 待辦：這一輪的三份文件對「mtime 能不能當 build 證據」立場不一致

**建立 2026-08-29，`8/29 mainDev`（外部觀察者）。**
🔴 **我不是這個目錄的主人，所以只登記、沒有代改任何一個檔。**
`8/29 auditor` 裁定：寫成待辦交給檔案的主人。

## 觀察到的不一致

| 檔案 | 立場 |
|---|---|
| [plot_deck_903_round2.py:317-318](plot_deck_903_round2.py) | **用 mtime 當 provenance 證據**：「`bmv2_binary_override`（mtime 08-22）指名 fast build、binary 自己（mtime 08-15）更早、之後都沒被動過」 |
| [PREREG.md:204](../2026-08-28_single-switch-build-ratio/PREREG.md) | 拿 mtime 當 build 證據**就是**「the mtime error in another costume」 |
| [FINDINGS.md:411](FINDINGS.md) | 註解「明確禁止用 mtime 推」（08-26 00:34 是建置或複製時間） |

## ⚠️ 我的判讀：「錯誤」這個描述可能過重

上一手的交接把這件事記成「provenance mtime **複製貼上錯誤**」。**我讀完不同意那個定性**：

`plot_deck_903_round2.py` 那段 docstring **自己就把證據強度降級標成 "provenance by
CONFIGURATION"**，明講該次 run **沒有** hash 它啟動的 binary、`measure_bmv2_capacity.sh`
也沒記錄（並對比旁邊 08-25 的腳本都有 sha256），而且**明確拒絕**「用 throughput 反推 build」
因為那是循環論證。

⇒ **那是已揭露的弱證據，不是偽裝成強證據的東西。** 我也**沒有看到複製貼上的痕跡**。

## 真正的問題是什麼

不是那段 docstring 說謊，而是**同一輪的三份文件對同一個方法學問題給了三種強度的答案**，
而讀者不會同時讀到三份。**要修的是立場，不是那一段文字。**

## 給主人的問題（我沒有答案）

1. `PREREG`／`FINDINGS` 的禁令是**絕對禁止**，還是**禁止當唯一證據、允許當佐證**？
2. 若是後者，`plot_deck_903_round2.py` 那段就是合規的，需要的只是**在它旁邊指到那條禁令**。
3. 若是前者，那段的 provenance 就得換一種寫法（或誠實標成「無法指認」）。

📌 **相關**：[[benchmark-must-name-the-binary-it-measured]]（「mtime 連下界都給不了」）。
本輪未驗證那條記憶與這三份文件之間有沒有進一步的落差。

**[Co-developed with claude code -- Adam]**
