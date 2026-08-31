# PREREG C4 — Whippersnapper artifact 兩 build 重跑（v0.2）

**狀態**：v0.2＝**auditor 章已蓋（2026-08-31：結構 PASS＋C1–C5 落點逐一驗訖）**。
升 v1.0 的唯一剩餘閘＝三處【TBD】依定案程序落定（container base 與 bmv2 樹屬機械定案、
落定即記；**primary 清單那處定案後回 auditor 快核**——「跑後不得增刪」的清單是本 prereg
最載重的一行，多一雙眼）。定案過程允許安裝與列舉（偵察），**不得跑任何量測**。
**凍結（v1.0）前不得接觸任何量測資料**。
凍結前修訂照 [[prereg-amendment-before-data]] 三條件。標【TBD】處必須在凍結前定案。
**裁決鏈**：完整性波 64_ §3-C4 → Adam 08-31 表單開 C4 → 66_ 清查 → Adam 圈定 Whippersnapper。

## 1. 問題

Whippersnapper（Dang et al., SOSR 2017；artifact＝github.com/usi-systems/p4benchmark）
的已發表 bmv2 量測，在其 artifact 自帶的兩個 configure 行之間會移動多少？

- **Arm S（as-released）**：`./configure`（artifact `install_bmv2.sh` 生效行——無 flag 預設）。
- **Arm F（their commented line）**：`./configure --disable-logging-macros --disable-elogger
  CXXFLAGS=-O3`（同檔被註解掉的那行）。
- 🔑 兩臂**都出自他們自己的檔案**——treatment 不是我們發明的，是他們寫下又註解掉的。
- 🔑 Arm F ≈ bmv2 官方 documented performance config、**不含**我們的三支自加 flags
  ⇒ 本實驗同時是「documented-flags-only 效應」在第三個 codebase 世代（2017 P4_14 era）
  的獨立數據點，與 B1 消融臂互補。

## 2. 環境（凍結前補齊【TBD】）

- Period container：base image【TBD：Ubuntu 14.04 或 16.04，依 artifact README/install 腳本
  依賴實測定】；P4_14 工具鏈照 artifact 自己的 install 腳本；thrift 0.9.3、python2 照舊。
- Host：nslab qemu VM（16C/16G）為主（⚠️ `/dev/kvm` ACL 登出即失、群組才算數）；
  若 fallback 本機：**必須 `NDT_OWNER` claim＋`NDT_EXCLUSIVE_CPU=1`、且不得與 Adam 的
  週四（9/03）準備窗重疊**（Adam 排程優先——本句係註冊條款，不是備忘）。
  **何者執行都在報告裡揭露完整層疊（bare/VM/container）**。
- **Container 新鮮度**：每個 rep 用**全新 container instance**（同一 image digest 起）；
  若任何步驟迫使共用 instance，明列為 limitation（warm thrift/cache 會跨臂）。
- bmv2 版本＝artifact install 腳本抓到的那顆【TBD：執行時記 commit；若腳本抓 master
  會拿到 2026 樹——**與 2017 論文用樹不同須揭露**；可選釘 2017-era tag 為敏感度臂】。
- Binary identity：兩臂各記 sha256＋symbol signature（沿 study 的 binary-identity 紀律）
  ＋**`ldd` 輸出與 RUNPATH（`readelf -d`）快照**——載入哪些 .so 由 RUNPATH 決定、不由
  環境變數（08-30 實測課），這一行把「量到哪顆」封死；container image digest 一併記。

## 3. 量測與登記結果

- **Primary**：artifact pipeline 原樣輸出的 headline 量測【TBD：裝起來後列舉其預設
  benchmark set——預期為 parse/latency 類（論文頭條＝parse 1 header 11.2 ms）；
  凍結前把「哪幾個數字算 primary」白紙黑字列出，跑後不得增刪】。
- **Registered outcome（方向＋級別，不登記點值）**：
  - H-C4a：**判定規則先凍、值後算（auditor C1(b) 案）**＝Arm F 的 primary 中位落在
    **交錯 S 跑（n=3）的全距之外**、且方向為快 ⇒ 成立。**雙重用途明寫**：S 跑同時
    供 primary 讀值與散布全距——因判定「規則」凍結於任何資料之前，門檻不由受審資料
    事後導出，無循環。
  - H-C4b（null）：F 中位落在 S 全距之內 ⇒ 如實報「此管線的量測對 build 不敏感（在
    其自身噪聲解析度內）」。
  - **n 的辯護（62_ #8 邏輯）**：n=3＋全距對**方向級**結論足夠——加 rep 降低誤判率、
    不改變噪聲解析度這個瓶頸；🔴 **凍結後不得加 rep 救顯著性**（本地版「不准為救比值
    加梯階」），n 只能在凍結前修訂。
  - 任一方向都是可發表結果；**abandon 條款**：artifact 在 period container 內裝不起來
    （逐步驟記錄失敗點）⇒ 報「重跑不可行＋失敗點」，不改靶不硬修。
- **每臂重複**：≥3 次完整 pipeline 跑，交錯（S,F,S,F,…），报中位數與全距。

## 4. 措辭紅線（登記於此、寫作時不可越）

- **跨代碼庫可比性免責（confirmatory 範圍條款，auditor C2）**：本註冊只裁
  「documented config 是否使**這條** pipeline 的量測移動超出其自身噪聲」；
  **不登記**與 8.0×／12×（study ①）的任何倍率可比性——跨代碼庫倍率比較一律標
  **事後探索**。方向相符＝什麼都還沒得到。
- 結果**無論方向**都如實報（含 null 與裝不起來）。
- 「不可歸因」不越「已翻盤」：即便效應巨大，寫法＝「其發表數字在其 artifact 自帶的
  兩個組態間相差 X」，**不寫**「其結論錯誤」。
- 不聯絡作者（C3 未開）；引用其 install 腳本時 pin repo commit＋逐字引（含註解行原文）。
- 對 0/12 編碼的關係照 66_：編碼單位＝論文全文，不因本實驗改動；擴寫揭露 artifact 層 nuance。

## 5. 與其他軌的關係

- 補 PAM #10「延遲量類零證據」缺口（本實驗 primary 即延遲類）。
- 與 B1（本機/nslab flags 消融）互為 documented-config 效應的跨代碼庫複證。
- 產出落 `doc/audit/2026-08-31_completeness-experiments/C4-whippersnapper/`（raw＋log＋
  container recipe 全存——不重蹈 pilot「raw not retained」）。

## 6. 修訂記錄

- v0.1（08-31）：初稿（reviewer 線起草）。
- v0.2（08-31，**資料接觸前**）：套用 auditor 覆核五條件——C1＝判定規則凍結（(b) 案、
  雙重用途明寫）；C2＝跨代碼庫免責條款；C3＝ldd／RUNPATH 快照；C4＝機器與共變量條款
  （nslab kvm 註記＋本機 fallback＝claim＋NDT_EXCLUSIVE_CPU=1＋不疊週四窗）；
  C5＝每 rep 全新 container＋凍結後不加 rep。v0.1 的四處【TBD】剩**三**處仍開放
  （散布估法那處由 C1 的判定規則定案收掉）、凍結前定。
- v0.2-stamped（08-31，auditor）：結構章＋C1–C5 落點驗訖章；升 v1.0 閘＝三 TBD 落定
  （primary 清單定案回 auditor 快核）。

[Co-developed with claude code -- Adam]
