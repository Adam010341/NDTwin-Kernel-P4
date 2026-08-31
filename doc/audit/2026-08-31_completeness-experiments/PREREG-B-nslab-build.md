# PREREG B — nslab 四臂 build 實驗（B2 第二機複製＋B1 flags 消融合一；v0.2）

**狀態**：v0.2-stamped＝**auditor 章已蓋（2026-08-31：結構 PASS＋R1–R3 落點逐一驗訖）**；
四處【TBD】皆機械核對類——**落定即自升 v1.0**（修訂記錄記明何時何人落定）；
【TBD】全屬機械核對——**落定即自升 v1.0、修訂記錄記明**（auditor 裁，毋須 C4 式
primary 快核閘）；**凍結前不得接觸任何量測資料**（偵察＝裝環境、
驗 kvm、smoke 拓樸可起，不產生任何效能數字）。
**裁決鏈**：完整性波 64_ §2-B1/B2 → Adam 08-31 表單「B 級全開、用遠端 VM 不搶實驗室」。

## 1. 問題（兩問合一 fabric）

在第二台機器（nslab qemu VM）上，沿 study ① 的單跳設計：

- **Q-B2（複製）**：stock→full-fast 的 build 混淆是否再現（**只問方向與 rung 級距，
  不轉移機器 1 的比值**——懷疑派 #2 規格）。
- **Q-B1（消融）**：documented-config 與 full-fast 之間、以及 -g -O2（專案預設）與兩端
  之間，在 rung 解析度下是否可分辨——解 study 現文的 hedge（"provided the three flags
  we added do not slow the build"）在機器 2 的版本。

## 2. 臂定義（四 build × 各 2 臂＝8 臂）

同一 behavioral-model tree（**釘 `f0b7d201`，與 study ① 同**）：

| 臂 | configure |
|---|---|
| A stock | p4-guide installer 逐字（`--with-pi --with-thrift 'CXXFLAGS=-O0 -g'`、logging macros＋elogger 開） |
| B default | 專案預設 `./configure`（＝`-g -O2`，study 已在乾淨樹驗過） |
| C documented | `-O3 --disable-logging-macros --disable-elogger`（官方文件建議、無自加 flags） |
| D full-fast | C ＋ `-DNDEBUG -march=native -fno-semantic-interposition`（study 的 fast） |

- 交錯序（先凍）：A1 B1 C1 D1 A2 B2 C2 D2；**每臂 fabric 全重啟**（builds swap——
  study ① 慣例；auditor C5 的 fabric 版新鮮度）。
- Binary identity（auditor C3）：每臂 sha256＋bidirectional symbol signature（沿 study，
  含 negative control）＋ `ldd`＋`readelf -d` RUNPATH 快照；`-march=native` 在 VM 內的
  實際展開一併存。

## 3. 量測與判定規則（規則先凍、值後算——auditor C1）

- 拓樸＝單跳、控制面活著（與 study ① 同構）；工作點＝1400 B payload（1442 B frame）UDP。
- 梯階＝study 的 ×1.5 rungs：1,2,3,5,8,12,20,30,45,70,110,160,240,360（＋540/810 stop
  rule）Mbit/s【TBD-verify：凍結前對 `21_`/`22_` FINDINGS 逐字核對 rungs、stop rule，**並將 Arm A 的 stock configure 行一併逐字核對**（auditor R3，同一批動作）】。
- Clean＝loss ≤0.5% on 3-rep medians（同 study）；每臂讀出＝最高 clean rung。
- **判定規則（全部先凍）**：
  - R-B2：兩 D 臂讀值皆嚴格高於兩 A 臂 ⇒「混淆在機器 2 存在」成立；報 rung 級距
    （quantisation interval 照 study 規則），**不換算、不與機器 1 比值比較**。
  - R-B1a（C vs D）：兩 D 臂皆嚴格高於兩 C 臂 ⇒「三支自加 flags 在機器 2 買到 ≥1 rung」；
    兩 C 臂皆嚴格高於兩 D 臂 ⇒「自加 flags 在機器 2 反而變慢」（**兩向都登記、都可發表**）；
    其餘 ⇒「rung 解析度內不可分辨」＝以保守方向解 study hedge（自加 flags 效應 ≤1 rung）。
  - R-B1b（B vs A、C vs B）：同構規則（兩臂嚴格序＝可分辨，否則不可分辨）。
  - 🔴 凍結後**不加 rep、不加臂、不加梯階救任何結果**（auditor C5／「不准為救比值加梯階」）；
    n 與臂數只能凍結前修訂。
- 陽性對照：per-process CPU gate 沿 study（**先讓它發火一次才信**）。
- **Sender gate（公式先凍、校準只填常數——auditor R1）**：
  - 判定式（v1.0 即存在）：令 G＝VM 內 sender→sink **直測天花板**；凡 rung X 滿足
    **G < 5×X ⇒ 該 rung 及以上的讀值標 sender-limited、不入 clean 判定**（5× 門檻沿
    study ② 的 sender-gate 要求；精確錨點【TBD-verify：凍結時 pin 到
    `23_FINDINGS_packet-size.md` 的 gate 節行號】）。
  - 校準時序與防火牆：凍結後、正式臂之前跑；**校準路徑 sender→sink 直連、不經過任何
    受測 build 的 binary**（不洩漏臂的性能包絡）；校準產出只有常數 G、只餵判定式、
    不入 primary。

## 4. 環境（auditor C4）

- **nslab qemu VM 專屬**（16C/16G、snapshot `fresh` 起；⚠️ `/dev/kvm` ACL 登出即失、
  群組才算數——開工先驗）；**本實驗不設本機 fallback**（本機的 documented-only 補臂
  ＝另一張小 prereg，見 §6）。
- 完整層疊揭露：bare nslab → qemu/KVM VM → Mininet veth【TBD：VM 環境 manifest——
  iperf3 版本、kernel、mininet 版本、CPU model，bootstrap 時落定】。
- **Pinning／governor＝凍結決策、非記錄（auditor R2）**：裁定＝**不 pin vCPU、governor
  照 VM 預設不動**——與 study ①（機器 1 無 pinning、無定頻）同 protocol，複製忠實度
  優先；pinning 敏感度屬 B3（本機、另立 prereg）。qemu 參數＝`~/ndtwin-vm.sh` 預設
  （VM_CPUS=16、VM_MEM=16384），實際值進 manifest。
- **nslab 獨占條款**：跑臂期間 nslab 上不開任何其他重活——nslab 無 claim 工具，
  **本句即其 claim**。
- P4 程式＝study ① 同一顆＋同 p4c【TBD：凍結時逐字記名＋p4c 版本＋JSON hash——
  順手補 AEC 抓的論文缺口】。
- 每臂 fabric 重啟＝新鮮度；VM 不 snapshot-rollback 中途（8 臂一氣跑完、中斷則整輪作廢
  重跑並記錄）。

## 5. 措辭紅線

- **跨機器可比性免責（auditor C2 同構）**：本註冊只裁「機器 2 上各 build 對是否可分辨
  ＋方向」；**不登記**與機器 1 的 8.0×/12× 的倍率可比性；跨機器倍率並列一律標事後探索。
  方向相符＝什麼都還沒得到。
- 結果無論方向如實報（含「VM 環境撐不起 clean baseline」的 abandon 路徑：報不可行＋
  失敗點）。
- VM 層＝正式限制條款：所有結論措辭綁「on this VM」，不寫裸的「on a second machine」。

## 6. 與其他軌的關係

- R-B1a 的「不可分辨」結果＝以機器 2 證據**收窄** study hedge，不改機器 1 條文。
- 本機 documented-only 補臂（嚴格解機器 1 hedge 用）＝另一張 mini-prereg，等本機空檔
  ＋不疊 9/03 窗；與本實驗互引。
- C4（Whippersnapper）的 Arm F＝本實驗 Arm C 的 2017 代碼庫遠親——三處數據點
  （機器 1 上界、機器 2 消融、2017 管線）合讀時一律標事後探索。
- 產出落 `doc/audit/2026-08-31_completeness-experiments/B-nslab-build/`（raw＋log＋
  env manifest 全存）。

## 7. 修訂記錄

- v0.1（08-31）：初稿（reviewer 線起草；auditor 五條件 C1–C5 預套——C1 判定規則全數
  先凍、C2 跨機器免責、C3 ldd/RUNPATH、C4 環境條款、C5 新鮮度＋凍結後不加）。
  【TBD】×4：rungs 對 21_/22_ 核對、VM manifest、P4 程式/p4c 逐字記名、sender gate
  的 VM 校準程序。
- v0.2（08-31，**資料接觸前**）：auditor 覆核（結構 PASS）三騎士條款落地——
  R1＝sender gate 公式先凍（G<5×X ⇒ sender-limited；校準 sender→sink 直連繞開受測物、
  只填常數 G、不入 primary；②錨點行號列入 TBD-verify）；R2＝pinning/governor 凍結裁定
  ＝不 pin、不動 governor（與 study ① 同 protocol；敏感度歸 B3）；R3＝Arm A stock
  configure 行併入 TBD-verify 同批。另補 nslab 獨占條款（無 claim 工具、條款即 claim）。
  流程（auditor 裁）：TBD 全屬機械核對，落定即自升 v1.0。

[Co-developed with claude code -- Adam]
