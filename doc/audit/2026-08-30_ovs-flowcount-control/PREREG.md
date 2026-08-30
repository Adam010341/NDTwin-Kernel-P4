# PREREG——OvS 同梯對照臂（C3 的「對照平面」半邊）

**建立日 2026-08-30（開跑前註冊；commit 時間戳＝註冊證明）。**
委託：Adam 08-30「加大力度」裁示，選項一。執行：`8/29 poster-reviewer`（本 session）。
**這是什麼**：③（bmv2 流數×容量）的 OvS 對照——同一把梯、同 path-class 規則、對照平面
as-configured。**這不是什麼**：不是 ③ 的完整重跑（3 格非 5 格）；不是 shaping 歸因輪
（jitter PREREG B 仍未跑）；**smoke-grade 對照臂，結論以「對照」口徑陳述**。

## 1. 問題（先於資料寫死）

固定 leaf-spine 拓樸、同一 host 對、全部 n 條流綁同一目的（port 區分）、×1.5 同梯下：
**OvS（production-grade kernel datapath）的每流最高乾淨速率是否隨 n 下降？**
bmv2 側已收案：160/110/30/5/2 與 240/110/45/8/1（兩臂各自單調，7 階跨度）。

## 2. 設計

- **平面**：`ndt up ovs`（Ryu＋OVS kernel datapath＋ndtwin kernel）＝對照平面的
  as-configured 狀態。**host 數 64**（OVS 拓樸最大值；P4 側是 128——已知差異 #1）。
- **host 對**：h1（s1）→ **h33**（s3）——與 ③ 的 h1→h65 同構：兩份拓樸 JSON 是同一張
  leaf-spine 圖（BFS 驗過，s1→s3 最短路徑＝**5 switch／6 links**），h33 是 s3 上第一個 host。
- **格**：n ∈ {1, 4, 16}（③ 網格的兩端＋中點）；**每格 2 臂**，交錯鏡像
  `n1_a n4_a n16_a | n16_b n4_b n1_b`。
- **梯**：per-flow ×1.5，`1 2 3 5 8 12 20 30 45 70 110 160 240 360 540 810 1215`
  （前 13 階＝③ 原梯逐字；240 以上為延伸段，①b「梯頂交停止規則」先例）。
  每格實際頂＝min(發送端 gate 上限, 表尾)；停止規則＝連兩階 loss>25%（同 ③）。
- **shaping——主臂全部「無 shaping」**：as-configured 的 htb（host 接取＋leaf trunk 全
  `bw=1000`）會在 n×rung>1G 時**自己製造每流下降**——n=16×70M=1.12G 就撞頂。
  ⇒ 開跑前把 `testbed_topo.py` 的全部 `bw=` 拿掉（jitter `03_ovs_PREREG.md` B 臂註冊過、
  從未跑；spine 的 `bw=10000` 本來就被 Mininet 靜默忽略）。patch diff 與前後 sha256 入 raw，
  跑完 byte-exact 還原。
- **陽性對照（shaped n=16 一臂）**：還原 shaping 後重開 fabric，跑 n=16 一臂。
  **預測（先寫死）**：per-flow 乾淨階 ≤45（62.5M＝1G/16 落在 45 與 70 之間，70 應 dirty）。
  **若 shaped 臂沒讀出這個帽子，本輪的讀出鏈看不見真實存在的上限 ⇒ 整輪只准報
  instrument-invalid。**（「閘門要先發火」紀律——這臂就是本輪讀出鏈的發火測試。）

## 3. 發送端 gate（先於任何 OvS 臂，過與不過都記錄）

fabric 起來後、任何臂之前：h1 網namespace 內 loopback（不經 OvS datapath）
n∈{1,4,16} 條並行 1400B UDP 流各 3 reps，取合計送達中位。
**每格的允許梯頂＝最大的 rung 使 n×rung ≤ loopback_agg(n)/5**（② 的 5× 規則）。
高於此的階不跑；若某格的最高乾淨階＝該格 gate 頂 ⇒ 該格**右截尾**，只准報
「≥ 該階（generator-gated）」。

## 4. 讀值（每臂全收）

1. iperf3 逐流 `sum_sent`/`sum_received`（沿 ③ runner；`-1` 哨兵語義不變）。
2. **全 10 台 switch 的 `/proc/net/dev`** 前後快照（③ 只抄 s1/s3）——OvS/Ryu 若按
   5-tuple ECMP，port 區分的 n 流**可能散在中段** ⇒ flows/switch 不再 by construction，
   **實測散佈入報告**（已知差異 #2；散的方向＝降低中段每台負載＝**偏向「不降」**，
   方向入報告）。
3. `tc -s qdisc` 前後（同時是「shaping 已拿掉／已還原」的斷言——patch 生效驗證）。
4. 收端 `/proc/net/snmp` Udp（`RcvbufErrors`＝收端行程極限指認——n=16 時 h33 上 16 個
   iperf3 server，收端可能先於 OvS 到頂；bmv2 的 ③ 同構造（h65 上 n 個 server），
   **同構造＝可比**，但哪臂被收端限住要指認）。
5. 負載：`/proc/stat` 差分（busy fraction＋**softirq 獨立欄**——OvS 轉發在 kernel
   softirq，行程歸因構不到；**本輪沒有已驗證的外來負載偵測器，照 ③ 揭露**）。

## 5. 儀器與 provenance

- runner ＝ ③ `run_flowcount_arm.sh` 的改造版 `run_ovs_arm.sh`。**功能性修改全列**：
  (a) host 對參數化（h1→h33）；(b) provenance 段換 OVS（`ovs-vsctl --version`、
  `modinfo openvswitch`、bridge 數、Ryu 行程與 :8080、拓樸 JSON sha256、
  `testbed_topo.py` 當下 sha256＝shaping 狀態的指認）；(c) `snap()` 擴到全 switch；
  (d) 負載取樣加 softirq 欄。**梯／clean 判定／3-rep 中位／頂階確認／飽和停止邏輯
  逐字不動。** diff 對 ③ 原檔入 raw。
- 量測窗內不 commit；lab claim 全程持有；期間任何外部 commit/agy 照 auditor 的
  per-PID 差分法量化記錄。

## 6. 預測與每種結局的意義（先寫死）

| 結局 | 判準 | 預寫意義 |
|---|---|---|
| **H-A 不降** | n=16 的每流最高乾淨階與 n=1 差 ≤1 階（或兩者皆右截尾於各自 gate 頂） | 對照恢復全額：poster 的 open-control 句可改為「an OvS control on the same ladder did not decline within the instrument's range」＋差異揭露 |
| **H-B 降** | n=16 比 n=1 低 ≥2 階 | **對照翻面是結果不是失敗**：C3 改寫成「both planes decline; bmv2 by 7 rungs, OvS by X」；poster 維持 open-control 句或加對稱句，由 Adam 裁 |
| **H-C 儀器界定** | ≥2 格右截尾或被收端指認 | 報 instrument-bounded；poster 不動 |
| 陽性對照失火 | shaped n=16 讀不出 ~62M 帽 | **整輪 instrument-invalid，不得引用任何主臂數字** |

差 1 階＝解析度內（③ 的規矩）；「X 階」以梯序數之差計。
**放棄判準**：fabric 三次起不來、或 gate 量測本身 NO_MEASUREMENT ⇒ 棄跑，報告原因。

## 7. 與 ③ 的已知差異（誠實清單，寫在跑之前）

1. host 數 64 vs 128（OVS 拓樸上限）。
2. 置放構造：P4 側 dst-based 路由 ⇒ n 流同路徑 by construction；OvS 側 ECMP 行為
   未知 ⇒ 實測散佈代替 by construction。
3. 3 格非 5 格；無 shaped 全網格。
4. 控制平面：Ryu（reactive/學習）vs proxy（推 ipv4_dst）——「對照平面 as-configured」
   本來就是 C3 的框（帶對照平面，不是帶相同平面）。
5. CPU 歸因構不到 kernel datapath（softirq 記錄代替）。
6. smoke-grade：每格 2 臂、未做 8 臂鏡像。

---

## AMENDMENT-1（2026-08-30 13:44；零資料——第一次開機就被 ndt 拒絕，無任何封包送出）

**改什麼**：§2 的「host 數 64、host 對 h1→h33」改為 **host 數 128、host 對 h1→h65**。
**為什麼**：註冊時我從 `setting/` 的 OVS 模型 JSON（最大 64Hosts）推斷 fabric 上限＝64——
**推錯了**：那些是 kernel 的靜態模型檔，fabric 建造器是 `testbed_topo.py`（HOST_NUM=128），
`ndt up ovs` 只接受 128（或 ovs4）。ndt 在任何資料產生前拒絕（`raw/ndt_up_unshaped.log`）。
**方向**：128／h1→h65 ＝ **與 ③ 完全同 host 數、同 host 對**——嚴格更接近本 PREREG
自己宣稱的「同置放」意圖；已知差異 #1（64 vs 128）**整條刪除**。
h65 於 OVS 側同掛 s3（`testbed_topo.py:83`：hosts[64..95]→s3）。
修正案三條件檢查：零資料 ✅／只引既有資訊（ndt 的拒絕訊息＋建造器源碼）✅／
只收緊（向註冊意圖靠攏）✅。

[Co-developed with claude code -- Adam]
