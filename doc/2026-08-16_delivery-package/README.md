# 投遞包(2026-08-16 定稿)——給 Adam

三份乾淨交付檔,內部前言與內部注全數移除、待補項已補。**你要做的只剩過目與轉交。**

| 檔案 | 給誰 | 內容 |
|---|---|---|
| `ntg-report.md` | NTG 維護者 | 三條缺陷(#1 已照你 08-16 裁決定稿為 docs/UX 回報,含調查更正註腳;#2 空桶崩潰;#3 不可重入) |
| `bmv2-manual-entry.md` | patty(docs 站) | bmv2 效能 build 手冊條目(英文正文;SIGSIM-PADS '23 篇名已查證補齊——Chen/Hu/Jin, DOI 10.1145/3573900.3591120,170 Mbps 數字已核對原文 p.4) |
| `docs-errata.md` | patty(docs 站) | 勘誤三條:Ryu 6653、testbed_topo 直譯器、端點 41 vs 29(41=今日對 dispatcher 實數) |

與原稿的差異(除刪內部前言外,僅三處):
1. manual-entry 的 References 補上完整篇名+DOI;正文引用處加註「16-switch linear
   topology」(依原文 Figure 3,避免被讀成單機通用值)。
2. errata 第 3 條從判官的「~40」升級為實數 **41**(counting 方法寫在檔內)。
3. ntg-report 附錄拿掉我方內部 commit hash(外部讀者不可解)。

原始稿(含內部前言)仍在 `doc/2026-08-15_ntg-upstream-report-draft.md` 與
`doc/2026-08-15_bmv2-performance-build-public-manual-draft.md`,未動。

**不在此包、已裁決的**:clone 疊加(proxy 重啟×warm fabric)的 bmv2/PI 上游材料
雖已達 upstream-grade(raw client 五相重現+report=
`doc/audit/2026-08-16_clone-stacking-raw-repro.md`+probe=
`p4_proxy/reference/clone_stack_probe.py`),**你 2026-08-17 裁決不投遞、只歸檔**——
issue 稿(`doc/2026-08-16_p4lang-clone-stacking-issue-draft.md`)已標記不投,
三處引用同步。我方本身不受影響(settle pair `79e4f69` 已修並 live 驗證)。
**所以本包三檔就是全部要轉交的東西,對象只有 NTG 維護者與 patty。**

[Co-developed with claude code -- Adam]
