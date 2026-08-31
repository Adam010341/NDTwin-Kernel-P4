# 本機 fabric 排隊帳（08-31 起；跨線共用，誰要用誰先讀）

**為什麼有這張表**：本機 fabric 同時有三線想用（reviewer 的 B3／documented-only 補臂、
auditor 的 E 輪、C4 的 fallback），而 nslab 尚未通。**claim 工具是真實來源，本表是意圖**
——動手當下仍須 `ndtwin-lab status` 重讀（[[lab-claim-handoff-protocol]]：讀數是點取樣
不是租約）。

## 優先序（高→低）

| # | 佔用者 | 內容 | 何時 | 條款 |
|---|---|---|---|---|
| 0 | **Adam** | 9/03 報告準備（含可能的 deck 產檔、圖重渲） | 即日–09-03 | **絕對優先**；PREREG-C4/B 皆有「不疊週四準備窗」條款 |
| 1 | auditor | **E 輪**（batching `a3bb761`＋1 kHz→1 Hz `2f57ba5` 落地後，取樣天花板重量） | 待 Adam 一個詞 | 兩顆 08-27 落地、其後該目錄無新檔＝洞成立（我方複核日期屬實） |
| 2 | reviewer | **B3** pinning/DVFS 對照（125U 混核）＋**本機 documented-only 補臂**（嚴格解 study ① hedge） | E 輪之後 | 各自 mini-prereg，未起草；兩支可併一張（同 fabric、同單跳、只差 build/pin 維度） |
| 3 | reviewer | C4 量測 **fallback** | 僅當 VPN 長期不通 | PREREG-C4 §2：claim＋`NDT_EXCLUSIVE_CPU=1`＋不疊週四窗 |

## 規則

- **一次一個佔用者**：本機 fabric 不併行跑兩線的量測（併行 session 自己就是共變量，
  ≈1 核——[[vm-on-this-machine-is-invisible-to-ndt-status]]）。
- **C4 install 偵察（docker，不碰 fabric）不佔本表的窗**，但它會吃 CPU ⇒ **不得與任何
  量測輪重疊**；輪要開跑前先確認 docker build 已收工。
- nslab 通了之後：B 輪整個移遠端，本表只剩 0/1/2（C4 fallback 自動撤回）。
- 交接寫 handoff、release 要留字條（既有規矩，不重述）。

[Co-developed with claude code -- Adam]
