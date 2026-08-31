# PREREG — F-5 細格重量輪（幽靈可見性的收官量測；v0.1 草稿）

[Co-developed with claude code -- Adam]

**狀態**：v0.1＝auditor 起草；**設計者＝auditor 本人 ⇒ 蓋章找第二雙眼**（Adam 過目、或
reviewer 線代審——利益迴避照舊）。**凍結（v1.0）前不得接觸任何量測資料。**
**裁決鏈**：ledger §D F-5「證據基礎鬆動、待重裁」→ TR-3（窗是時鐘）→ T-11-A 落地
（`91e7743`）→ Adam 08-31 表單裁「再開一輪量測」。

## 1. 問題（三問、兩顆 binary）

08-18 的「30 分鐘 0 次自然發作」用 10 秒格量一個本週證實只有 2–3 秒的窗——靈敏度
不成立。本輪在**正確的解析度**上把 F-5 的證據基礎一次量完：

- **Q1（修復在負載下守不守，post-T-11 binary）**：有流量、細格點下，N 次 install 是否
  **零幽靈**；並把「合法規則的 request-shape 可見窗」從 n=1（7.4 s）量成分布（n≥20、雙臂）。
- **Q2（舊世界到底多常見，pre-T-11 binary `a40e04ce`）**：同格點下幽靈可見窗的實測分布
  ——08-18 那格量不到的東西，這次量到，F-5 重裁的最後一塊材料。
- **Q3（刻意觸發上界，pre-T-11）**：install/list 交錯緊打的對抗臂——「意外的案例會低估
  故意的案例」那課的正面執行；只報上界、不外推自然率。

## 2. 儀器（FINDING-06 的課先吃進設計）

- **每個格點雙儀器同刻取樣**：kernel 視圖（`GET /ndt/get_switch_openflow_table_entries`）
  ＋南向直讀（P4＝proxy 讀表；OVS＝Ryu `/stats/flow`）——「可見」與「已編程」逐點分開量，
  儀器不再把自己的上游刷新週期量成發現。
- 格點＝t ∈ {0, 0.25, 0.5, 1, 1.5, 2, 3, 5, 8, 12} s（對數化細格；0.25 s 起因 T-11 力紅
  實測幻影 t=0.005 s 已現、t=1.274 s 已消）。
- 取樣器自身＝已註冊共變量（輪詢也是負載）：sampler 行程的 CPU 佔用隨 raw 存檔。
- 結構指紋（4 欄／無 counters／呼叫端字彙）＝**偵測判準**，逐點記錄；不作任何過濾用途。

## 3. 臂與判定規則（規則先凍——C1）

- 兩臂 fabric：P4 4-host 與 OVS（同 T-4/批次工作點）；流量＝chaos `traffic.sh` 模式
  背景 mesh＋30 s 一條新 pair churn（同 TR PREREG §2，offered rate 走 datapath 記錄）。
- 每格 N＝**30 次 install**（churn 驅動＋顯式 POST 混合；序列先凍：交錯 dst、不重複）。
- **R1（紅色條款）**：post-T-11 binary 出現**任一**幽靈（視圖有、南向同刻無、且帶結構
  指紋）⇒ 修復回歸 FINDING，本輪停在該證據上、不續跑 Q3。
- **R2**：可見窗分布以 per-arm 中位數＋全距報；**不登記跨臂比值**、不與 10.7 s 快取週期
  作因果宣稱以外的換算（週期是機制、分布是量測，兩者對得上是驗證、對不上是發現）。
- **R3**：Q2 的自然率重算＝以實測窗分布×08-18 的取樣參數回推當時靈敏度（重算那個
  「80%/次」），**只修正靈敏度註記，不改 08-18 的觀測本身**。
- **R4**：Q3 上界以「每百次交錯操作的命中數」報；任何方向如實報。
- 🔴 **凍結後不加 rep、不加格點、不加臂救任何結果**（C5）；n 只能凍結前改。

## 4. 環境（C3／C4）

- 本機 lab：`NDT_OWNER` claim＋`NDT_EXCLUSIVE_CPU=1`＋窗內全 repo 禁 commit/build/VM
  （條款照 TR-5 note 格式進 claim，**係註冊條款不是備忘**）；**不疊 9/03 準備窗**，
  排程以 Adam 優先。
- 兩顆 binary 各記 sha256＋`ldd`＋`readelf -d` RUNPATH＋identifying strings；換裝
  （pre/post-T-11）之間 fabric 全拆重起、binary 換裝雙向複驗（批次的做法）。
- kernel tree 釘凍結時 tip；量測窗內主樹不得有行為相關未 commit 改動（`ndt status`
  的 code 欄為準）。

## 5. Riders（同一 claim 窗順跑，各自獨立判定）

- **A-1 arm3 重跑**：沉澱後、確認 up 的交換機上重複 power-on ×2 ⇒ 200／無行程變動／
  count 不變＝I1/I5 成立（上次 INCONCLUSIVE 的正確工作點）；並補 ping-through 子句。
- **A-2 §5.3**：僅當 sudoers 放行 iptables（Adam 裁決在途）；否則維持 SKIPPED 記錄。
- Riders 失敗不污染主問（獨立報）。

## 6. 措辭紅線

- F-5 的重裁**仍是 Adam 的**：本輪只交材料（Q1 守／Q2 分布／Q3 上界），PREREG 不預埋
  任何「應裁 X」的句子。
- 「不可歸因」不越「已翻盤」；VM／機器層語言不適用（本輪單機）。

## 7. 修訂記錄

- v0.1（08-31）：auditor 起草；五條件自套（C1 規則先凍、C2 不登記跨臂/跨週期換算、
  C3 binary 身分含 RUNPATH、C4 機器共變量條款、C5 凍結後不加）。
  【TBD】×3：①install 序列逐字（dst 清單）②sampler 實作（腳本檔、量測指令進檔不手打）
  ③Q3 交錯操作的精確節奏。
